"""Enrichment pipeline: fetch metadata, download thumbnail, classify, persist.

Phase 1: runs synchronously via FastAPI BackgroundTasks. Phase 2 will move
to an arq worker so it survives restarts and gets retries for free.
"""
import logging
import time
from datetime import UTC, datetime
from uuid import UUID

import httpx
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import AsyncSessionLocal
from app.models import Category, Link, LinkCategory
from app.schemas.enums import AssignedBy, LinkStatus
from app.services import article_body, metadata, storage
from app.services.catalog import description_for_slug
from app.services.classifier import CategoryChoice, get_classifier
from app.services.summarizer import get_summarizer
from app.services.url_normalizer import normalize_url

logger = logging.getLogger(__name__)
MAX_ENRICH_ATTEMPTS = 3


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
    _t0 = time.monotonic()
    async with AsyncSessionLocal() as session:
        link = (
            await session.execute(select(Link).where(Link.id == link_id))
        ).scalar_one_or_none()
        if link is None:
            return

        async with httpx.AsyncClient(
            follow_redirects=True,
            timeout=15.0,
            headers={"User-Agent": metadata.USER_AGENT},
        ) as client:
            try:
                meta = await metadata.fetch_metadata(
                    link.canonical_url, link.source_platform, client
                )

                link.title = meta.title
                link.description = meta.description
                link.author = meta.author
                link.raw_metadata = meta.raw or None

                # The POST path no longer resolves redirects (kept it fast), so
                # recanonicalize here from the final URL after redirects. Guard
                # the unique constraint: if this collides with an existing link
                # for the user, keep the original canonical to avoid a 500.
                if meta.final_url:
                    resolved = normalize_url(meta.final_url)
                    if resolved and resolved != link.canonical_url:
                        link.canonical_url = resolved

                if meta.thumbnail_url:
                    try:
                        thumb = await metadata.download_thumbnail(meta.thumbnail_url, client)
                        if thumb is not None:
                            body, ctype = thumb
                            link.thumbnail_s3_key = await storage.upload_thumbnail(
                                body, ctype, str(link.id)
                            )
                    except Exception as thumb_exc:
                        logger.warning(
                            '"event":"thumbnail_fail","link_id":"%s","error":"%s"',
                            link.id, thumb_exc
                        )

                # ---- Stage 1: classify + commit the category ASAP ----
                # The share sheet only needs the category. Commit it (and the
                # enriched status) before the slower summarization so the user
                # is unblocked the moment the category is known.
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

                link.status = LinkStatus.enriched
                link.enriched_at = datetime.now(UTC)
                await session.commit()
                logger.info(
                    '"event":"enrich_ok","link_id":"%s","ms":%d',
                    link_id, int((time.monotonic() - _t0) * 1000)
                )
            except Exception as exc:
                link.enrich_attempts = (link.enrich_attempts or 0) + 1
                logger.warning(
                    '"event":"enrich_fail","link_id":"%s","attempt":%d,"error":"%s"',
                    link_id, link.enrich_attempts, exc
                )
                if link.enrich_attempts >= MAX_ENRICH_ATTEMPTS:
                    link.status = LinkStatus.failed
                await session.commit()
                return

            # ---- Stage 2: summarize (decoupled) ----
            # Runs after the category is already persisted. A failure here only
            # logs — it never affects the committed category/status.
            try:
                body_text: str | None = None
                if meta.html:
                    body_text, word_count = article_body.extract_body(
                        meta.html, url=link.canonical_url
                    )
                    if not article_body.qualifies_as_article(word_count):
                        body_text = None

                if body_text:
                    summary = await get_summarizer().summarize(
                        title=link.title, article_body=body_text
                    )
                    if summary is not None:
                        link.summary_segments = summary
                        await session.commit()
                        logger.info(
                            '"event":"summary_ok","link_id":"%s","ms":%d',
                            link_id, int((time.monotonic() - _t0) * 1000)
                        )
            except Exception as sum_exc:
                logger.warning(
                    '"event":"summary_fail","link_id":"%s","error":"%s"',
                    link_id, sum_exc
                )
