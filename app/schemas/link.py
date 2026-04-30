from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, HttpUrl

from app.schemas.enums import LinkStatus, SourcePlatform


class LinkCreate(BaseModel):
    url: HttpUrl


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
    thumbnail_url: str | None
    ingested_at: datetime
    enriched_at: datetime | None
    categories: list[CategoryRef] = []
