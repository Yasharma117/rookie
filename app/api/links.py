from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, status
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from app.deps import CurrentUser, SessionDep
from app.models import Category, Link, LinkCategory
from app.schemas.link import CategoryRef, LinkCreate, LinkOut
from app.services import storage
from app.services.enrichment import enrich_link
from app.services.url_normalizer import canonicalize, detect_platform

router = APIRouter(prefix="/v1/links", tags=["links"])


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
        thumbnail_url=storage.public_url(link.thumbnail_s3_key),
        ingested_at=link.ingested_at,
        enriched_at=link.enriched_at,
        categories=[
            CategoryRef(id=cid, name=name, confidence=conf)
            for conf, cid, name in cat_rows
        ],
    )


@router.post("", status_code=status.HTTP_202_ACCEPTED, response_model=LinkOut)
async def create_link(
    payload: LinkCreate,
    background: BackgroundTasks,
    user: CurrentUser,
    session: SessionDep,
) -> LinkOut:
    source_url = str(payload.url)
    canonical = await canonicalize(source_url)
    platform = detect_platform(canonical)

    existing = (
        await session.execute(
            select(Link).where(
                Link.user_id == user.id, Link.canonical_url == canonical
            )
        )
    ).scalar_one_or_none()
    if existing is not None:
        return await _to_out(session, existing)

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
    return await _to_out(session, link)


@router.get("", response_model=list[LinkOut])
async def list_links(
    user: CurrentUser,
    session: SessionDep,
    limit: int = 50,
    offset: int = 0,
) -> list[LinkOut]:
    rows = (
        await session.execute(
            select(Link)
            .where(Link.user_id == user.id)
            .order_by(Link.ingested_at.desc())
            .limit(min(limit, 200))
            .offset(offset)
        )
    ).scalars().all()
    return [await _to_out(session, link) for link in rows]


@router.get("/{link_id}", response_model=LinkOut)
async def get_link(link_id: UUID, user: CurrentUser, session: SessionDep) -> LinkOut:
    link = (
        await session.execute(
            select(Link).where(Link.id == link_id, Link.user_id == user.id)
        )
    ).scalar_one_or_none()
    if link is None:
        from fastapi import HTTPException
        raise HTTPException(status_code=404, detail="Link not found")
    return await _to_out(session, link)
