"""link_fields: add note, remind_at, enrich_attempts to links table

Revision ID: 0005_link_fields
Revises: 0004_ingest_tokens
Create Date: 2026-05-21
"""
import sqlalchemy as sa
from alembic import op

revision = "0005_link_fields"
down_revision = "0004_ingest_tokens"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # note: user-facing annotation saved from the share sheet
    op.add_column("links", sa.Column("note", sa.Text(), nullable=True))

    # remind_at: iOS polls this field to surface local reminder notifications
    op.add_column(
        "links",
        sa.Column("remind_at", sa.DateTime(timezone=True), nullable=True),
    )

    # enrich_attempts: retry counter — up to MAX_ENRICH_ATTEMPTS before status=failed
    op.add_column(
        "links",
        sa.Column(
            "enrich_attempts",
            sa.Integer(),
            nullable=False,
            server_default="0",
        ),
    )


def downgrade() -> None:
    op.drop_column("links", "enrich_attempts")
    op.drop_column("links", "remind_at")
    op.drop_column("links", "note")
