from uuid import UUID

from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.deps import CurrentUser, SessionDep
from app.models import Category
from app.schemas.category import CategoryCreate, CategoryOut, CategoryUpdate

router = APIRouter(prefix="/v1/categories", tags=["categories"])


@router.get("", response_model=list[CategoryOut])
async def list_categories(user: CurrentUser, session: SessionDep) -> list[Category]:
    rows = (
        await session.execute(
            select(Category).where(Category.user_id == user.id).order_by(Category.name)
        )
    ).scalars().all()
    return list(rows)


@router.post("", status_code=status.HTTP_201_CREATED, response_model=CategoryOut)
async def create_category(
    payload: CategoryCreate, user: CurrentUser, session: SessionDep
) -> Category:
    cat = Category(user_id=user.id, name=payload.name, color=payload.color)
    session.add(cat)
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise HTTPException(status_code=409, detail="Category name already exists")
    await session.refresh(cat)
    return cat


@router.patch("/{category_id}", response_model=CategoryOut)
async def update_category(
    category_id: UUID,
    payload: CategoryUpdate,
    user: CurrentUser,
    session: SessionDep,
) -> Category:
    cat = (
        await session.execute(
            select(Category).where(Category.id == category_id, Category.user_id == user.id)
        )
    ).scalar_one_or_none()
    if cat is None:
        raise HTTPException(status_code=404, detail="Category not found")

    if payload.name is not None:
        cat.name = payload.name
    if payload.color is not None:
        cat.color = payload.color

    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise HTTPException(status_code=409, detail="Category name already exists")
    await session.refresh(cat)
    return cat
