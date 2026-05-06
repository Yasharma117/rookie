"""ingest_tokens: per-device tokens for share extensions / bots

Revision ID: 0004_ingest_tokens
Revises: 0003_clerk
Create Date: 2026-05-07
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0004_ingest_tokens"
down_revision: str | None = "0003_clerk"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    channel_enum = postgresql.ENUM(
        "share_sheet",
        "telegram",
        "whatsapp",
        "email",
        "web",
        name="ingest_channel_enum",
        create_type=True,
    )

    op.create_table(
        "ingest_tokens",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("token_hash", sa.String(64), nullable=False, unique=True),
        sa.Column("channel", channel_enum, nullable=False),
        sa.Column("device_label", sa.String(128), nullable=True),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_ingest_tokens_user_id", "ingest_tokens", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_ingest_tokens_user_id", table_name="ingest_tokens")
    op.drop_table("ingest_tokens")
    op.execute("DROP TYPE IF EXISTS ingest_channel_enum")
