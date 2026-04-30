from datetime import datetime
from uuid import UUID

from sqlalchemy import DateTime, Enum, ForeignKey, String, Text, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB, UUID as PG_UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, created_at_col, uuid_pk
from app.schemas.enums import LinkStatus, SourcePlatform


class Link(Base):
    __tablename__ = "links"
    __table_args__ = (
        UniqueConstraint("user_id", "canonical_url", name="uq_links_user_canonical"),
    )

    id: Mapped[UUID] = uuid_pk()
    user_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    source_url: Mapped[str] = mapped_column(Text, nullable=False)
    canonical_url: Mapped[str] = mapped_column(Text, nullable=False)
    source_platform: Mapped[SourcePlatform] = mapped_column(
        Enum(SourcePlatform, name="source_platform_enum"),
        nullable=False,
        default=SourcePlatform.web,
    )

    title: Mapped[str | None] = mapped_column(Text, nullable=True)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    author: Mapped[str | None] = mapped_column(String(256), nullable=True)
    thumbnail_s3_key: Mapped[str | None] = mapped_column(String(512), nullable=True)
    raw_metadata: Mapped[dict | None] = mapped_column(JSONB, nullable=True)

    status: Mapped[LinkStatus] = mapped_column(
        Enum(LinkStatus, name="link_status_enum"),
        nullable=False,
        default=LinkStatus.pending,
    )

    ingested_at: Mapped[datetime] = created_at_col()
    enriched_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
