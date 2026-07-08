"""Admin endpoints for background jobs triggered via cron.

Ported from the rookie2 prototype. Disabled entirely unless ADMIN_SECRET is
set in the environment; callers must send a matching X-Admin-Secret header.
"""
import logging
from typing import Annotated

from fastapi import APIRouter, Header, HTTPException, status
from sqlalchemy import select

from app.config import settings
from app.deps import SessionDep
from app.models import Link
from app.schemas.enums import LinkStatus
from app.services.enrichment import MAX_ENRICH_ATTEMPTS, enrich_link

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/v1/admin", tags=["admin"])


@router.post("/enrich", status_code=status.HTTP_200_OK)
async def enrich_pending_links(
    session: SessionDep,
    x_admin_secret: Annotated[str | None, Header(alias="X-Admin-Secret")] = None,
) -> dict[str, int]:
    """Re-run enrichment on up to 10 stuck-pending links. Call via cron."""
    if not settings.admin_secret or x_admin_secret != settings.admin_secret:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Unauthorized"
        )

    ids = (
        await session.execute(
            select(Link.id)
            .where(
                Link.status == LinkStatus.pending,
                Link.enrich_attempts < MAX_ENRICH_ATTEMPTS,
            )
            .limit(10)
        )
    ).scalars().all()

    count = 0
    for link_id in ids:
        try:
            await enrich_link(link_id)
            count += 1
        except Exception as exc:
            logger.warning(
                '"event":"admin_enrich_fail","link_id":"%s","error":"%s"', link_id, exc
            )

    return {"enriched": count}
