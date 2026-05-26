from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, HttpUrl

from app.schemas.enums import LinkStatus, SourcePlatform


class LinkCreate(BaseModel):
    url: HttpUrl


class LinkUpdate(BaseModel):
    title: str | None = None
    description: str | None = None
    note: str | None = None
    remind_at: datetime | None = None
    category_ids: list[UUID] | None = None  # if provided, replaces all assignments


class CategoryRef(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    name: str
    confidence: float | None = None


class LinkOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    source_url: str
    canonical_url: str
    source_platform: SourcePlatform
    status: LinkStatus
    title: str | None
    description: str | None
    author: str | None
    note: str | None = None
    remind_at: datetime | None = None
    thumbnail_url: str | None
    ingested_at: datetime
    enriched_at: datetime | None
    categories: list[CategoryRef] = []


class LinkListOut(BaseModel):
    """Paginated link list with opaque keyset cursor for efficient scrolling."""

    items: list[LinkOut]
    next_cursor: str | None = None
