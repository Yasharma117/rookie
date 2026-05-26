from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, HTTPException, Response, status
from sqlalchemy import select

from app.deps import CurrentUser, SessionDep
from app.models import IngestToken
from app.schemas.ingest_token import (
    IngestTokenCreate,
    IngestTokenCreated,
    IngestTokenOut,
)
from app.services.ingest_token import generate

router = APIRouter(prefix="/v1/ingest-tokens", tags=["ingest-tokens"])


@router.post(
    "", status_code=status.HTTP_201_CREATED, response_model=IngestTokenCreated
)
async def create_ingest_token(
    payload: IngestTokenCreate,
    user: CurrentUser,
    session: SessionDep,
) -> IngestTokenCreated:
    raw, token_hash = generate()
    row = IngestToken(
        user_id=user.id,
        token_hash=token_hash,
        channel=payload.channel,
        device_label=payload.device_label,
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)

    return IngestTokenCreated(
        id=row.id,
        token=raw,
        channel=row.channel,
        device_label=row.device_label,
        created_at=row.created_at,
    )


@router.get("", response_model=list[IngestTokenOut])
async def list_ingest_tokens(
    user: CurrentUser, session: SessionDep
) -> list[IngestToken]:
    rows = (
        await session.execute(
            select(IngestToken)
            .where(IngestToken.user_id == user.id)
            .order_by(IngestToken.created_at.desc())
        )
    ).scalars().all()
    return list(rows)


@router.delete("/{token_id}", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_ingest_token(
    token_id: UUID, user: CurrentUser, session: SessionDep
) -> Response:
    row = (
        await session.execute(
            select(IngestToken).where(
                IngestToken.id == token_id, IngestToken.user_id == user.id
            )
        )
    ).scalar_one_or_none()
    if row is None:
        raise HTTPException(status_code=404, detail="Ingest token not found")
    if row.revoked_at is None:
        row.revoked_at = datetime.now(UTC)
        await session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
