from datetime import UTC, datetime

from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from app.deps import CurrentUser, SessionDep
from app.models import Category
from app.schemas.category import CategoryOut
from app.schemas.onboarding import (
    CatalogEntryOut,
    MeResponse,
    OnboardingRequest,
    OnboardingResponse,
)
from app.services.catalog import CATALOG, CATALOG_BY_SLUG, OTHER

router = APIRouter(prefix="/v1", tags=["onboarding"])


@router.get("/onboarding/catalog", response_model=list[CatalogEntryOut])
async def get_catalog() -> list[CatalogEntryOut]:
    return [
        CatalogEntryOut(
            slug=e.slug, name=e.name, emoji=e.emoji, color=e.color, description=e.description
        )
        for e in CATALOG
    ]


@router.post(
    "/onboarding",
    response_model=OnboardingResponse,
    status_code=status.HTTP_200_OK,
)
async def complete_onboarding(
    payload: OnboardingRequest,
    user: CurrentUser,
    session: SessionDep,
) -> OnboardingResponse:
    if user.onboarded_at is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="Already onboarded"
        )

    unknown = [s for s in payload.slugs if s not in CATALOG_BY_SLUG]
    if unknown:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unknown catalog slug(s): {', '.join(unknown)}",
        )

    chosen_slugs = list(dict.fromkeys(payload.slugs))  # dedupe, preserve order
    chosen_entries = [CATALOG_BY_SLUG[s] for s in chosen_slugs] + [OTHER]

    rows = [
        {
            "user_id": user.id,
            "name": e.name,
            "color": e.color,
            "catalog_slug": e.slug,
        }
        for e in chosen_entries
    ]

    stmt = (
        pg_insert(Category)
        .values(rows)
        .on_conflict_do_nothing(constraint="uq_categories_user_name")
    )
    await session.execute(stmt)

    user.onboarded_at = datetime.now(UTC)
    await session.commit()

    cats = (
        await session.execute(
            select(Category)
            .where(Category.user_id == user.id)
            .order_by(Category.created_at)
        )
    ).scalars().all()

    return OnboardingResponse(
        onboarded_at=user.onboarded_at,
        categories=[CategoryOut.model_validate(c, from_attributes=True) for c in cats],
    )


@router.get("/me", response_model=MeResponse)
async def me(user: CurrentUser) -> MeResponse:
    return MeResponse(
        id=user.id,
        email=user.email,
        onboarded=user.onboarded_at is not None,
        onboarded_at=user.onboarded_at,
        created_at=user.created_at,
    )
