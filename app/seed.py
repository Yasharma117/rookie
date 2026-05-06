"""Idempotent seed: ensures the dev user exists.

Categories are no longer created here — they come from the onboarding flow
(POST /v1/onboarding). Run with:  uv run python -m app.seed
"""
import asyncio
from uuid import UUID

from sqlalchemy import select

from app.config import settings
from app.db import AsyncSessionLocal
from app.models import User


async def seed() -> None:
    async with AsyncSessionLocal() as session:
        user_id = UUID(settings.dev_user_id)
        user = (
            await session.execute(select(User).where(User.id == user_id))
        ).scalar_one_or_none()

        if user is None:
            user = User(id=user_id, api_key=settings.dev_user_api_key, email="dev@local")
            session.add(user)
            print(f"created dev user {user_id} (not yet onboarded)")
        elif user.api_key != settings.dev_user_api_key:
            user.api_key = settings.dev_user_api_key
            print(f"updated api_key for {user_id}")

        await session.commit()
        print("seed complete")


if __name__ == "__main__":
    asyncio.run(seed())
