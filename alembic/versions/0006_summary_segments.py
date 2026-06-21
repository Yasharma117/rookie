"""summary_segments: structured article summary for the iOS ArticleCard

Revision ID: 0006_summary_segments
Revises: 0005_link_fields
Create Date: 2026-06-02
"""
import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision = "0006_summary_segments"
down_revision = "0005_link_fields"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # summary_segments: ordered list of {text, emphasis: 1|2|3|null}.
    # Exactly 3 segments are emphasized; the rest are connective grammar.
    # Populated by the summarizer service only when an extracted article body
    # qualifies as long-form (≥ ARTICLE_MIN_WORDS).
    op.add_column(
        "links",
        sa.Column("summary_segments", JSONB, nullable=True),
    )


def downgrade() -> None:
    op.drop_column("links", "summary_segments")
