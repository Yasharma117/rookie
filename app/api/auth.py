"""Sign in with Apple → ingest-token exchange.

The iOS app posts the Apple identity token it received from
ASAuthorizationAppleIDCredential. We verify it against Apple's JWKS,
find-or-create the user, and mint an ingest token which the app stores in
the keychain and sends as X-API-Key on every request thereafter.
"""
from uuid import UUID

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import select

from app.deps import SessionDep
from app.models import IngestToken, User
from app.schemas.enums import IngestChannel
from app.services import apple_auth
from app.services.ingest_token import generate

router = APIRouter(prefix="/v1/auth", tags=["auth"])


class ExchangeRequest(BaseModel):
    apple_jwt: str
    device_label: str | None = Field(default=None, max_length=128)


class ExchangeResponse(BaseModel):
    token: str
    user_id: UUID
    onboarded: bool


@router.post("/exchange", response_model=ExchangeResponse)
async def exchange(payload: ExchangeRequest, session: SessionDep) -> ExchangeResponse:
    try:
        claims = apple_auth.verify_identity_token(payload.apple_jwt)
    except apple_auth.AppleAuthError as e:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid Apple token: {e}",
        ) from e

    # Apple subs live in the clerk_user_id column with an "apple:" prefix so
    # v0 ships without a schema migration; Clerk ids ("user_…") can't collide.
    external_id = f"apple:{claims['sub']}"
    user = (
        await session.execute(select(User).where(User.clerk_user_id == external_id))
    ).scalar_one_or_none()
    if user is None:
        email = claims.get("email")
        if email:
            # Apple only sends email on first authorization; guard the unique
            # constraint in case the address already belongs to another row.
            taken = (
                await session.execute(select(User.id).where(User.email == email))
            ).scalar_one_or_none()
            if taken is not None:
                email = None
        user = User(clerk_user_id=external_id, email=email)
        session.add(user)
        await session.flush()

    raw, token_hash = generate()
    session.add(
        IngestToken(
            user_id=user.id,
            token_hash=token_hash,
            channel=IngestChannel.share_sheet,
            device_label=payload.device_label or "iOS app",
        )
    )
    await session.commit()

    return ExchangeResponse(
        token=raw, user_id=user.id, onboarded=user.onboarded_at is not None
    )
