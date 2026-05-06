from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.enums import IngestChannel


class IngestTokenCreate(BaseModel):
    channel: IngestChannel = IngestChannel.share_sheet
    device_label: str | None = Field(default=None, max_length=128)


class IngestTokenCreated(BaseModel):
    """Returned ONCE on creation. The raw token is never re-fetchable."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    token: str  # raw — caller must store now
    channel: IngestChannel
    device_label: str | None
    created_at: datetime


class IngestTokenOut(BaseModel):
    """Listing/management view — no raw token."""

    model_config = ConfigDict(from_attributes=True)

    id: UUID
    channel: IngestChannel
    device_label: str | None
    last_used_at: datetime | None
    created_at: datetime
    revoked_at: datetime | None
