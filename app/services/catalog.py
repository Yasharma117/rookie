"""Fixed catalog of categories shown during onboarding.

20 picker entries + Other (auto-included on every user, hidden from picker).
The `description` field is fed to the LLM classifier as a category hint.
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class CatalogEntry:
    slug: str
    name: str
    emoji: str
    color: str
    description: str


CATALOG: list[CatalogEntry] = [
    CatalogEntry("jobs", "Jobs", "💼", "#2563eb",
                 "Job postings, hiring announcements, recruiter posts, career listings."),
    CatalogEntry("travel", "Travel", "✈️", "#16a34a",
                 "Trip ideas, travel guides, places to visit, hotels, flights, itineraries."),
    CatalogEntry("reading", "Reading", "📚", "#9333ea",
                 "Long-form articles, blog posts, essays, books, newsletters."),
    CatalogEntry("entertainment", "Entertainment", "🎬", "#db2777",
                 "Movies, TV shows, music videos, comedy, celebrity content, songs."),
    CatalogEntry("cooking", "Cooking", "🍳", "#ea580c",
                 "Recipes, cooking techniques, food videos, restaurants, ingredients."),
    CatalogEntry("fitness", "Fitness", "💪", "#dc2626",
                 "Workouts, exercise routines, gym, running, yoga, nutrition for fitness."),
    CatalogEntry("shopping", "Shopping", "🛍️", "#f59e0b",
                 "Products to buy, deals, fashion, gear, gift ideas."),
    CatalogEntry("tech", "Tech", "💻", "#0891b2",
                 "Software engineering, programming, dev tools, frameworks, gadgets."),
    CatalogEntry("design", "Design", "🎨", "#c026d3",
                 "UI/UX, graphic design, typography, branding, illustration."),
    CatalogEntry("productivity", "Productivity", "⚡", "#eab308",
                 "Workflows, tools, systems, time management, habit building."),
    CatalogEntry("finance", "Finance", "💰", "#15803d",
                 "Personal finance, investing, markets, money management, business news."),
    CatalogEntry("music", "Music", "🎵", "#7c3aed",
                 "Songs, albums, artists, playlists, music recommendations."),
    CatalogEntry("art", "Art", "🖼️", "#be185d",
                 "Visual art, painting, sculpture, gallery exhibits, art history."),
    CatalogEntry("photography", "Photography", "📷", "#475569",
                 "Photography tips, gear, photo collections, photographers' work."),
    CatalogEntry("gaming", "Gaming", "🎮", "#7c2d12",
                 "Video games, game reviews, esports, streaming, game industry."),
    CatalogEntry("sports", "Sports", "⚽", "#059669",
                 "Sports news, highlights, scores, athletes, sports analysis."),
    CatalogEntry("education", "Education", "🎓", "#1d4ed8",
                 "Tutorials, courses, lectures, study guides, how-to learning content."),
    CatalogEntry("science", "Science", "🔬", "#0d9488",
                 "Scientific research, discoveries, explanations, physics, biology, space."),
    CatalogEntry("news", "News", "📰", "#525252",
                 "Current events, breaking news, journalism, world affairs, politics."),
    CatalogEntry("lifestyle", "Lifestyle", "🌿", "#84cc16",
                 "Wellness, mindfulness, home, relationships, personal stories, lifestyle tips."),
]

OTHER = CatalogEntry(
    "other", "Other", "📦", "#64748b",
    "Catch-all for links that don't fit any other category."
)

CATALOG_BY_SLUG = {entry.slug: entry for entry in CATALOG}


def is_valid_slug(slug: str) -> bool:
    return slug in CATALOG_BY_SLUG


def description_for_slug(slug: str | None) -> str | None:
    if slug is None:
        return None
    if slug == OTHER.slug:
        return OTHER.description
    entry = CATALOG_BY_SLUG.get(slug)
    return entry.description if entry else None
