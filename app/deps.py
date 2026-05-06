from datetime import datetime, timezone
from typing import Annotated

from fastapi import Depends, Header, HTTPException, status
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_session
from app.models import IngestToken, User
from app.services import clerk
from app.services.ingest_token import hash_token

SessionDep = Annotated[AsyncSession, Depends(get_session)]


async def _user_from_clerk(session: AsyncSession, token: str) -> User:
    try:
        claims = clerk.verify_session_token(token)
    except clerk.ClerkAuthError as e:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid Clerk token: {e}",
        )

    clerk_user_id = claims["sub"]
    user = (
        await session.execute(select(User).where(User.clerk_user_id == clerk_user_id))
    ).scalar_one_or_none()
    if user is None:
        user = User(clerk_user_id=clerk_user_id, email=claims.get("email"))
        session.add(user)
        await session.commit()
        await session.refresh(user)
    return user


async def _user_from_api_key(session: AsyncSession, api_key: str) -> User:
    user = (
        await session.execute(select(User).where(User.api_key == api_key))
    ).scalar_one_or_none()
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid API key"
        )
    return user


async def _user_from_ingest_token(session: AsyncSession, raw_token: str) -> User:
    h = hash_token(raw_token)
    row = (
        await session.execute(
            select(IngestToken, User)
            .join(User, User.id == IngestToken.user_id)
            .where(IngestToken.token_hash == h, IngestToken.revoked_at.is_(None))
        )
    ).first()
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid ingest token"
        )
    token_row, user = row
    await session.execute(
        update(IngestToken)
        .where(IngestToken.id == token_row.id)
        .values(last_used_at=datetime.now(timezone.utc))
    )
    await session.commit()
    return user


async def get_current_user(
    session: SessionDep,
    authorization: Annotated[str | None, Header()] = None,
    x_api_key: Annotated[str | None, Header(alias="X-API-Key")] = None,
) -> User:
    """App-user auth: Clerk Bearer or dev X-API-Key. Rejects ingest tokens."""
    if authorization and authorization.lower().startswith("bearer ") and clerk.is_configured():
        token = authorization.split(" ", 1)[1].strip()
        return await _user_from_clerk(session, token)

    if x_api_key:
        return await _user_from_api_key(session, x_api_key)

    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Missing Authorization (Bearer) or X-API-Key header",
    )


async def get_ingest_user(
    session: SessionDep,
    authorization: Annotated[str | None, Header()] = None,
    x_api_key: Annotated[str | None, Header(alias="X-API-Key")] = None,
    x_ingest_token: Annotated[str | None, Header(alias="X-Ingest-Token")] = None,
) -> User:
    """Write-scoped auth: Clerk Bearer, X-Ingest-Token (share extension), or
    dev X-API-Key. Use this on POST /v1/links."""
    if authorization and authorization.lower().startswith("bearer ") and clerk.is_configured():
        token = authorization.split(" ", 1)[1].strip()
        return await _user_from_clerk(session, token)

    if x_ingest_token:
        return await _user_from_ingest_token(session, x_ingest_token)

    if x_api_key:
        return await _user_from_api_key(session, x_api_key)

    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Missing Authorization (Bearer), X-Ingest-Token, or X-API-Key header",
    )


CurrentUser = Annotated[User, Depends(get_current_user)]
IngestUser = Annotated[User, Depends(get_ingest_user)]
