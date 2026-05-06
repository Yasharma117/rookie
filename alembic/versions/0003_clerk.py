"""clerk auth: users.clerk_user_id + relax api_key NOT NULL

Revision ID: 0003_clerk
Revises: 0002_onboarding
Create Date: 2026-05-07
"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0003_clerk"
down_revision: str | None = "0002_onboarding"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "users",
        sa.Column("clerk_user_id", sa.String(128), nullable=True),
    )
    op.create_unique_constraint("uq_users_clerk_user_id", "users", ["clerk_user_id"])
    op.alter_column("users", "api_key", existing_type=sa.String(128), nullable=True)


def downgrade() -> None:
    op.alter_column("users", "api_key", existing_type=sa.String(128), nullable=False)
    op.drop_constraint("uq_users_clerk_user_id", "users", type_="unique")
    op.drop_column("users", "clerk_user_id")
