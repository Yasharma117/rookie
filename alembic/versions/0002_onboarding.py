"""onboarding: users.onboarded_at + categories.catalog_slug

Revision ID: 0002_onboarding
Revises: 0001_initial
Create Date: 2026-05-07
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0002_onboarding"
down_revision: str | None = "0001_initial"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "users",
        sa.Column("onboarded_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "categories",
        sa.Column("catalog_slug", sa.String(64), nullable=True),
    )
    op.create_index(
        "ix_categories_user_catalog", "categories", ["user_id", "catalog_slug"]
    )


def downgrade() -> None:
    op.drop_index("ix_categories_user_catalog", table_name="categories")
    op.drop_column("categories", "catalog_slug")
    op.drop_column("users", "onboarded_at")
