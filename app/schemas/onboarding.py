from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.category import CategoryOut


class CatalogEntryOut(BaseModel):
    slug: str
    name: str
    emoji: str
    color: str
    description: str


class OnboardingRequest(BaseModel):
    slugs: list[str] = Field(min_length=1, max_length=20)


class OnboardingResponse(BaseModel):
    onboarded_at: datetime
    categories: list[CategoryOut]


class MeResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    email: str | None
    onboarded: bool
    onboarded_at: datetime | None
    created_at: datetime
