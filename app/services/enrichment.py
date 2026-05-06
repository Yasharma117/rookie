"""Enrichment pipeline: fetch metadata, download thumbnail, classify, persist.

Phase 1: runs synchronously via FastAPI BackgroundTasks. Phase 2 will move
to an arq worker so it survives restarts and gets retries for free.
"""
from datetime import datetime, timezone
from uuid import UUID

import httpx
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import AsyncSessionLocal
from app.models import Category, Link, LinkCategory
from app.schemas.enums import AssignedBy, LinkStatus
from app.services import metadata, storage
from app.services.catalog import description_for_slug
from app.services.classifier import CategoryChoice, get_classifier


async def _user_categories(session: AsyncSession, user_id: UUID) -> list[CategoryChoice]:
    rows = (
        await session.execute(select(Category).where(Category.user_id == user_id))
    ).scalars().all()
    return [
        CategoryChoice(
            id=c.id,
            name=c.name,
            description=description_for_slug(c.catalog_slug),
        )
        for c in rows
    ]


async def enrich_link(link_id: UUID) -> None:
    async with AsyncSessionLocal() as session:
        link = (await session.execute(select(Link).where(Link.id == link_id))).scalar_one_or_none()
        if link is None:
            return

        async with httpx.AsyncClient(
            follow_redirects=True,
            timeout=15.0,
            headers={"User-Agent": metadata.USER_AGENT},
        ) as client:
            try:
                meta = await metadata.fetch_metadata(link.canonical_url, link.source_platform, client)

                link.title = meta.title
                link.description = meta.description
                link.author = meta.author
                link.raw_metadata = meta.raw or None

                if meta.thumbnail_url:
                    thumb = await metadata.download_thumbnail(meta.thumbnail_url, client)
                    if thumb is not None:
                        body, ctype = thumb
                        link.thumbnail_s3_key = await storage.upload_thumbnail(
                            body, ctype, str(link.id)
                        )

                categories = await _user_categories(session, link.user_id)
                if categories:
                    classifier = get_classifier()
                    result = await classifier.classify(
                        title=link.title,
                        description=link.description,
                        source_platform=link.source_platform.value,
                        categories=categories,
                    )
                    stmt = pg_insert(LinkCategory).values(
                        link_id=link.id,
                        category_id=result.category_id,
                        confidence=result.confidence,
                        assigned_by=AssignedBy.model,
                    ).on_conflict_do_nothing(index_elements=["link_id", "category_id"])
                    await session.execute(stmt)
                # If categories is empty (user not onboarded yet) we skip
                # classification — the link still gets enriched metadata.

                link.status = LinkStatus.enriched
                link.enriched_at = datetime.now(timezone.utc)
            except Exception:
                link.status = LinkStatus.failed

            await session.commit()
