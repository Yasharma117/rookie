"""Link endpoints.

Changes from v0:
- POST returns 202 (new) or 200 (duplicate) — not always 202
- PATCH accepts note + remind_at
- GET / supports category_id, status, platform, q filters and cursor pagination
- GET /{id} returns Retry-After: 2 while status=pending
"""
import base64
import json as _json
import logging
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, HTTPException, Response, status
from fastapi.responses import JSONResponse
from sqlalchemy import delete, select

from app.deps import CurrentUser, IngestUser, SessionDep
from app.models import Category, Link, LinkCategory
from app.schemas.enums import AssignedBy, LinkStatus, SourcePlatform
from app.schemas.link import CategoryRef, LinkCreate, LinkListOut, LinkOut, LinkUpdate
from app.services import storage
from app.services.enrichment import enrich_link
from app.services.url_normalizer import canonicalize, detect_platform

router = APIRouter(prefix="/v1/links", tags=["links"])
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Cursor helpers for keyset pagination
# ---------------------------------------------------------------------------

def _encode_cursor(ingested_at: datetime, link_id: UUID) -> str:
    raw = _json.dumps({"t": ingested_at.isoformat(), "id": str(link_id)})
    return base64.urlsafe_b64encode(raw.encode()).decode()


def _decode_cursor(cursor: str) -> tuple[datetime, UUID]:
    raw = _json.loads(base64.urlsafe_b64decode(cursor.encode()))
    return datetime.fromisoformat(raw["t"]), UUID(raw["id"])


# ---------------------------------------------------------------------------
# Internal helper: build a LinkOut from a Link ORM row
# ---------------------------------------------------------------------------

async def _to_out(session, link: Link) -> LinkOut:
    cat_rows = (
        await session.execute(
            select(LinkCategory.confidence, Category.id, Category.name)
            .join(Category, Category.id == LinkCategory.category_id)
            .where(LinkCategory.link_id == link.id)
        )
    ).all()
    return LinkOut(
        id=link.id,
        source_url=link.source_url,
        canonical_url=link.canonical_url,
        source_platform=link.source_platform,
        status=link.status,
        title=link.title,
        description=link.description,
        author=link.author,
        note=link.note,
        remind_at=link.remind_at,
        thumbnail_url=storage.public_url(link.thumbnail_s3_key),
        ingested_at=link.ingested_at,
        enriched_at=link.enriched_at,
        categories=[
            CategoryRef(id=cid, name=name, confidence=conf)
            for conf, cid, name in cat_rows
        ],
    )


# ---------------------------------------------------------------------------
# POST /v1/links  — ingest a new URL
# ---------------------------------------------------------------------------

@router.post("", response_model=LinkOut)
async def create_link(
    payload: LinkCreate,
    background: BackgroundTasks,
    user: IngestUser,
    session: SessionDep,
) -> JSONResponse:
    """
    201-style semantic via HTTP status codes:
    - 200  duplicate URL already in the user's library
    - 202  new link accepted; enrichment running in background
    """
    source_url = str(payload.url)
    canonical = await canonicalize(source_url)
    platform = detect_platform(canonical)

    existing = (
        await session.execute(
            select(Link).where(Link.user_id == user.id, Link.canonical_url == canonical)
        )
    ).scalar_one_or_none()

    if existing is not None:
        out = await _to_out(session, existing)
        return JSONResponse(content=out.model_dump(mode="json"), status_code=200)

    link = Link(
        user_id=user.id,
        source_url=source_url,
        canonical_url=canonical,
        source_platform=platform,
    )
    session.add(link)
    await session.commit()
    await session.refresh(link)

    background.add_task(enrich_link, link.id)
    out = await _to_out(session, link)
    return JSONResponse(content=out.model_dump(mode="json"), status_code=202)


# ---------------------------------------------------------------------------
# GET /v1/links  — list / filter / paginate
# ---------------------------------------------------------------------------

@router.get("", response_model=LinkListOut)
async def list_links(
    user: CurrentUser,
    session: SessionDep,
    limit: int = 50,
    # Keyset cursor (preferred) — pass next_cursor from previous response
    cursor: str | None = None,
    # Legacy offset — kept for backwards compat with existing iOS builds
    offset: int = 0,
    # Filters
    category_id: UUID | None = None,
    status: LinkStatus | None = None,
    platform: SourcePlatform | None = None,
    q: str | None = None,
) -> LinkListOut:
    """
    Returns a paginated list of links. Supports optional filters and cursor-based pagination.

    For new clients: use `cursor` from `next_cursor` in the response.
    For legacy clients: use `offset` (less efficient at high page counts).
    """
    safe_limit = min(limit, 200)

    stmt = (
        select(Link)
        .where(Link.user_id == user.id)
        .order_by(Link.ingested_at.desc(), Link.id.desc())
    )

    # Apply keyset cursor (takes priority over offset)
    if cursor:
        try:
            at, cid = _decode_cursor(cursor)
            stmt = stmt.where(
                (Link.ingested_at < at)
                | ((Link.ingested_at == at) & (Link.id < cid))
            )
        except Exception as exc:
            raise HTTPException(status_code=400, detail="Invalid cursor") from exc
    else:
        stmt = stmt.offset(offset)

    # Apply filters
    if category_id is not None:
        stmt = stmt.join(
            LinkCategory, LinkCategory.link_id == Link.id
        ).where(LinkCategory.category_id == category_id)
    if status is not None:
        stmt = stmt.where(Link.status == status)
    if platform is not None:
        stmt = stmt.where(Link.source_platform == platform)
    if q is not None:
        pattern = f"%{q}%"
        stmt = stmt.where(
            Link.title.ilike(pattern) | Link.description.ilike(pattern)
        )

    rows = (await session.execute(stmt.limit(safe_limit))).scalars().all()
    items = [await _to_out(session, link) for link in rows]

    next_cursor = (
        _encode_cursor(rows[-1].ingested_at, rows[-1].id)
        if len(rows) == safe_limit
        else None
    )
    return LinkListOut(items=items, next_cursor=next_cursor)


# ---------------------------------------------------------------------------
# GET /v1/links/{link_id}  — fetch single link (used for enrichment polling)
# ---------------------------------------------------------------------------

@router.get("/{link_id}", response_model=LinkOut)
async def get_link(
    link_id: UUID,
    user: CurrentUser,
    session: SessionDep,
    response: Response,
) -> LinkOut:
    link = (
        await session.execute(
            select(Link).where(Link.id == link_id, Link.user_id == user.id)
        )
    ).scalar_one_or_none()
    if link is None:
        raise HTTPException(status_code=404, detail="Link not found")

    # Guide the iOS polling loop — poll again in 2 seconds while still enriching
    if link.status == LinkStatus.pending:
        response.headers["Retry-After"] = "2"

    return await _to_out(session, link)


# ---------------------------------------------------------------------------
# PATCH /v1/links/{link_id}  — update editable fields
# ---------------------------------------------------------------------------

@router.patch("/{link_id}", response_model=LinkOut)
async def update_link(
    link_id: UUID,
    payload: LinkUpdate,
    user: CurrentUser,
    session: SessionDep,
) -> LinkOut:
    link = (
        await session.execute(
            select(Link).where(Link.id == link_id, Link.user_id == user.id)
        )
    ).scalar_one_or_none()
    if link is None:
        raise HTTPException(status_code=404, detail="Link not found")

    if payload.title is not None:
        link.title = payload.title
    if payload.description is not None:
        link.description = payload.description
    if payload.note is not None:
        link.note = payload.note
    if payload.remind_at is not None:
        link.remind_at = payload.remind_at

    if payload.category_ids is not None:
        unique_ids = list(dict.fromkeys(payload.category_ids))

        owned = set(
            (
                await session.execute(
                    select(Category.id).where(
                        Category.user_id == user.id, Category.id.in_(unique_ids)
                    )
                )
            ).scalars()
        )
        invalid = [str(cid) for cid in unique_ids if cid not in owned]
        if invalid:
            raise HTTPException(
                status_code=400,
                detail=f"Category id(s) not found for this user: {', '.join(invalid)}",
            )

        await session.execute(
            delete(LinkCategory).where(LinkCategory.link_id == link.id)
        )
        for cid in unique_ids:
            session.add(
                LinkCategory(
                    link_id=link.id,
                    category_id=cid,
                    confidence=None,
                    assigned_by=AssignedBy.user,
                )
            )

    await session.commit()
    await session.refresh(link)
    return await _to_out(session, link)


# ---------------------------------------------------------------------------
# DELETE /v1/links/{link_id}
# ---------------------------------------------------------------------------

@router.delete("/{link_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_link(
    link_id: UUID, user: CurrentUser, session: SessionDep
) -> Response:
    result = await session.execute(
        delete(Link).where(Link.id == link_id, Link.user_id == user.id)
    )
    if result.rowcount == 0:
        raise HTTPException(status_code=404, detail="Link not found")
    await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
