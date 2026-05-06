from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, HTTPException, Response, status
from sqlalchemy import delete, select

from app.deps import CurrentUser, IngestUser, SessionDep
from app.models import Category, Link, LinkCategory
from app.schemas.enums import AssignedBy
from app.schemas.link import CategoryRef, LinkCreate, LinkOut, LinkUpdate
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
    user: IngestUser,
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
        raise HTTPException(status_code=404, detail="Link not found")
    return await _to_out(session, link)


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
