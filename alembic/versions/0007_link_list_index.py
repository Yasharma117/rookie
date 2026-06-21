"""link_list_index: composite index to back the keyset list query

Revision ID: 0007_link_list_index
Revises: 0006_summary_segments
Create Date: 2026-06-18
"""
import sqlalchemy as sa
from alembic import op

revision = "0007_link_list_index"
down_revision = "0006_summary_segments"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Backs `WHERE user_id = ? ORDER BY ingested_at DESC, id DESC` used by
    # GET /v1/links keyset pagination.
    # (The batched category lookup `WHERE link_id IN (...)` is already served
    # by link_categories' composite PK whose leading column is link_id.)
    op.create_index(
        "ix_links_user_ingested_id",
        "links",
        ["user_id", sa.text("ingested_at DESC"), sa.text("id DESC")],
    )


def downgrade() -> None:
    op.drop_index("ix_links_user_ingested_id", table_name="links")
