"""Idempotent seed: ensures the dev user + the 5 default categories exist.

Run with:  uv run python -m app.seed
"""
import asyncio
from uuid import UUID

from sqlalchemy import select

from app.config import settings
from app.db import AsyncSessionLocal
from app.models import Category, User

DEFAULT_CATEGORIES: list[tuple[str, str | None]] = [
    ("Jobs", "#2563eb"),
    ("Travel", "#16a34a"),
    ("Reading", "#9333ea"),
    ("Entertainment", "#db2777"),
    ("Other", "#64748b"),
]


async def seed() -> None:
    async with AsyncSessionLocal() as session:
        user_id = UUID(settings.dev_user_id)
        user = (
            await session.execute(select(User).where(User.id == user_id))
        ).scalar_one_or_none()

        if user is None:
            user = User(id=user_id, api_key=settings.dev_user_api_key, email="dev@local")
            session.add(user)
            await session.flush()
            print(f"created dev user {user_id}")
        else:
            if user.api_key != settings.dev_user_api_key:
                user.api_key = settings.dev_user_api_key
                print(f"updated api_key for {user_id}")

        existing = {
            row.name
            for row in (
                await session.execute(select(Category).where(Category.user_id == user_id))
            ).scalars()
        }
        for name, color in DEFAULT_CATEGORIES:
            if name not in existing:
                session.add(Category(user_id=user_id, name=name, color=color))
                print(f"  + category {name}")

        await session.commit()
        print("seed complete")


if __name__ == "__main__":
    asyncio.run(seed())
