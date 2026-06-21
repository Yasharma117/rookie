"""Regression + correctness tests for the performance & caching changes:
- N+1 elimination in GET /v1/links (constant query count)
- batched-category correctness
- ETag / 304 conditional responses on /v1/links and /v1/categories
- POST /v1/links normalizes the URL without any network fetch
- http_cache helper behavior
- enrichment reliability: a summary failure never blocks categorization
"""

import contextlib
from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, Mock, patch
from uuid import uuid4

import pytest
from sqlalchemy import event
from sqlalchemy.engine import Engine

from app.models import Category, Link, LinkCategory, User
from app.schemas.enums import AssignedBy, LinkStatus, SourcePlatform
from app.services.http_cache import _etag_for, conditional_json
from tests.conftest import TestingSessionLocal, enrich_link_patcher

AUTH_HEADERS = {"X-API-Key": "test_api_key"}
TEST_USER_ID = __import__("uuid").UUID("00000000-0000-0000-0000-000000000001")


@pytest.fixture
async def test_user(db_session):
    user = User(
        id=TEST_USER_ID,
        email="test@example.com",
        api_key="test_api_key",
        onboarded_at=datetime.now(UTC),
    )
    db_session.add(user)
    await db_session.commit()
    return user


@pytest.fixture
async def default_categories(db_session, test_user):
    other = Category(id=uuid4(), user_id=test_user.id, name="Other", catalog_slug="other")
    recipes = Category(id=uuid4(), user_id=test_user.id, name="Recipes", catalog_slug="recipes")
    db_session.add_all([other, recipes])
    await db_session.commit()
    return {"other": other, "recipes": recipes}


@contextlib.contextmanager
def count_queries():
    """Count SQL statements executed within the block (canonical recipe:
    listen on the Engine class so it catches the async engine's cursor execs)."""
    box = {"n": 0}

    def _on_exec(conn, cursor, statement, params, context, executemany):
        box["n"] += 1

    event.listen(Engine, "before_cursor_execute", _on_exec)
    try:
        yield box
    finally:
        event.remove(Engine, "before_cursor_execute", _on_exec)


async def _seed_links(db_session, user, categories, count, cats_per_link=2, prefix="a"):
    now = datetime.now(UTC)
    cat_ids = [c.id for c in categories]
    for i in range(count):
        url = f"https://example.com/{prefix}{i}"
        link = Link(
            id=uuid4(),
            user_id=user.id,
            source_url=url,
            canonical_url=url,
            source_platform=SourcePlatform.web,
            title=f"Link {prefix}{i}",
            status=LinkStatus.enriched,
            ingested_at=now - timedelta(minutes=i),
        )
        db_session.add(link)
        await db_session.flush()
        for cid in cat_ids[:cats_per_link]:
            db_session.add(
                LinkCategory(
                    link_id=link.id,
                    category_id=cid,
                    confidence=0.9,
                    assigned_by=AssignedBy.model,
                )
            )
    await db_session.commit()


# --- 1. N+1 query-count invariant -------------------------------------------


@pytest.mark.anyio
async def test_list_links_query_count_is_constant(
    client, db_session, test_user, default_categories
):
    cats = list(default_categories.values())

    await _seed_links(db_session, test_user, cats, count=2, prefix="p1_")
    with count_queries() as small:
        resp = await client.get("/v1/links?limit=200", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    small_n = small["n"]

    # add many more links
    await _seed_links(db_session, test_user, cats, count=23, prefix="p2_")  # 25 total
    with count_queries() as big:
        resp = await client.get("/v1/links?limit=200", headers=AUTH_HEADERS)
    assert resp.status_code == 200
    assert len(resp.json()["items"]) == 25
    big_n = big["n"]

    # The whole point: queries do NOT scale with the number of links.
    assert big_n == small_n, f"N+1 regression: {small_n} (2 links) vs {big_n} (25 links)"
    assert small_n <= 4, f"expected ~3 queries (auth+links+categories), got {small_n}"
    print(f"\n[query-count] 2 links -> {small_n} queries; 25 links -> {big_n} queries")


# --- 2. Batched-category correctness ----------------------------------------


@pytest.mark.anyio
async def test_list_links_categories_grouped_correctly(
    client, db_session, test_user, default_categories
):
    other, recipes = default_categories["other"], default_categories["recipes"]
    now = datetime.now(UTC)

    a = Link(
        id=uuid4(),
        user_id=test_user.id,
        source_url="https://e.com/a",
        canonical_url="https://e.com/a",
        status=LinkStatus.enriched,
        ingested_at=now - timedelta(minutes=1),
    )
    b = Link(
        id=uuid4(),
        user_id=test_user.id,
        source_url="https://e.com/b",
        canonical_url="https://e.com/b",
        status=LinkStatus.enriched,
        ingested_at=now - timedelta(minutes=2),
    )
    c = Link(
        id=uuid4(),
        user_id=test_user.id,
        source_url="https://e.com/c",
        canonical_url="https://e.com/c",
        status=LinkStatus.enriched,
        ingested_at=now - timedelta(minutes=3),
    )
    db_session.add_all([a, b, c])
    await db_session.flush()
    db_session.add_all(
        [
            LinkCategory(
                link_id=a.id, category_id=other.id, confidence=None, assigned_by=AssignedBy.user
            ),
            LinkCategory(
                link_id=a.id, category_id=recipes.id, confidence=None, assigned_by=AssignedBy.user
            ),
            LinkCategory(
                link_id=b.id, category_id=recipes.id, confidence=None, assigned_by=AssignedBy.user
            ),
            # c has no categories
        ]
    )
    await db_session.commit()

    resp = await client.get("/v1/links?limit=200", headers=AUTH_HEADERS)
    items = {i["id"]: i for i in resp.json()["items"]}
    assert {x["name"] for x in items[str(a.id)]["categories"]} == {"Other", "Recipes"}
    assert {x["name"] for x in items[str(b.id)]["categories"]} == {"Recipes"}
    assert items[str(c.id)]["categories"] == []


# --- 3. ETag / 304 on /v1/links ---------------------------------------------


@pytest.mark.anyio
async def test_links_etag_304_and_invalidation(client, db_session, test_user, default_categories):
    await _seed_links(
        db_session, test_user, list(default_categories.values()), count=2, prefix="e1_"
    )

    r1 = await client.get("/v1/links", headers=AUTH_HEADERS)
    assert r1.status_code == 200
    etag = r1.headers["ETag"]
    assert etag

    # Unchanged -> 304, empty body
    r2 = await client.get("/v1/links", headers={**AUTH_HEADERS, "If-None-Match": etag})
    assert r2.status_code == 304
    assert r2.content == b""

    # Data changes -> 200 with a different ETag
    await _seed_links(
        db_session, test_user, list(default_categories.values()), count=1, prefix="e2_"
    )
    r3 = await client.get("/v1/links", headers={**AUTH_HEADERS, "If-None-Match": etag})
    assert r3.status_code == 200
    assert r3.headers["ETag"] != etag


# --- 4. ETag / 304 on /v1/categories ----------------------------------------


@pytest.mark.anyio
async def test_categories_etag_304_and_invalidation(
    client, db_session, test_user, default_categories
):
    r1 = await client.get("/v1/categories", headers=AUTH_HEADERS)
    assert r1.status_code == 200
    etag = r1.headers["ETag"]

    r2 = await client.get("/v1/categories", headers={**AUTH_HEADERS, "If-None-Match": etag})
    assert r2.status_code == 304
    assert r2.content == b""

    # add a category -> ETag changes
    resp_new = await client.post("/v1/categories", json={"name": "Travel"}, headers=AUTH_HEADERS)
    assert resp_new.status_code == 201
    r3 = await client.get("/v1/categories", headers={**AUTH_HEADERS, "If-None-Match": etag})
    assert r3.status_code == 200
    assert r3.headers["ETag"] != etag


# --- 5. POST normalizes without network -------------------------------------


@pytest.mark.anyio
async def test_post_link_normalizes_without_network(client, db_session, test_user):
    spy = Mock()
    # resolve_redirects must NOT be called in the request path anymore.
    with patch("app.services.url_normalizer.resolve_redirects", spy):
        resp = await client.post(
            "/v1/links",
            json={"url": "https://example.com/post/?utm_source=x&ref=y"},
            headers=AUTH_HEADERS,
        )
    assert resp.status_code == 202
    data = resp.json()
    # tracking params stripped, no network resolution
    assert data["canonical_url"] == "https://example.com/post"
    spy.assert_not_called()


# --- 6. http_cache helper unit ----------------------------------------------


def test_etag_for_is_deterministic_and_distinct():
    a = _etag_for({"items": [1, 2, 3]})
    b = _etag_for({"items": [1, 2, 3]})
    c = _etag_for({"items": [1, 2, 4]})
    assert a == b
    assert a != c
    assert a.startswith('"') and a.endswith('"')


def _fake_request(if_none_match: str | None):
    from starlette.requests import Request

    headers = []
    if if_none_match is not None:
        headers.append((b"if-none-match", if_none_match.encode()))
    scope = {"type": "http", "method": "GET", "path": "/", "headers": headers}
    return Request(scope)


def test_conditional_json_304_on_match_else_200():
    payload = {"hello": "world"}
    etag = _etag_for(payload)

    not_modified = conditional_json(_fake_request(etag), payload)
    assert not_modified.status_code == 304

    fresh = conditional_json(_fake_request(None), payload)
    assert fresh.status_code == 200
    assert fresh.headers["ETag"] == etag


# --- 7. Enrichment reliability: summary failure must not block category -----


@pytest.mark.anyio
@pytest.mark.skipif(
    "sqlite" in __import__("os").environ.get("DATABASE_URL", ""),
    reason="enrich_link uses pg_insert(...).on_conflict_do_nothing (Postgres-only); "
    "the SQLite test harness can't compile it. Reliability path verified against the "
    "live Postgres system instead.",
)
async def test_enrichment_summary_failure_does_not_block_category(
    db_session, test_user, default_categories
):
    from app.services.classifier import ClassificationResult
    from app.services.metadata import FetchedMetadata

    other = default_categories["other"]
    link = Link(
        id=uuid4(),
        user_id=test_user.id,
        source_url="https://example.com/article",
        canonical_url="https://example.com/article",
        source_platform=SourcePlatform.web,
        status=LinkStatus.pending,
    )
    db_session.add(link)
    await db_session.commit()
    link_id = link.id

    real_enrich = enrich_link_patcher.get_original()[0]

    fake_meta = FetchedMetadata(
        title="An Article",
        description="desc",
        author=None,
        thumbnail_url=None,
        raw={},
        html="<html>x</html>",
        final_url=None,
    )
    fake_classifier = Mock()
    fake_classifier.classify = AsyncMock(
        return_value=ClassificationResult(category_id=other.id, confidence=1.0, reason="t")
    )
    fake_summarizer = Mock()
    fake_summarizer.summarize = AsyncMock(side_effect=RuntimeError("summarizer down"))

    with (
        patch("app.services.enrichment.AsyncSessionLocal", TestingSessionLocal),
        patch("app.services.enrichment.metadata.fetch_metadata", AsyncMock(return_value=fake_meta)),
        patch(
            "app.services.enrichment.article_body.extract_body", return_value=("word " * 500, 500)
        ),
        patch("app.services.enrichment.get_classifier", return_value=fake_classifier),
        patch("app.services.enrichment.get_summarizer", return_value=fake_summarizer),
    ):
        await real_enrich(link_id)

    # Re-read in a fresh session
    async with TestingSessionLocal() as s:
        refreshed = await s.get(Link, link_id)
        assert refreshed.status == LinkStatus.enriched
        assert refreshed.summary_segments is None
        cats = (
            await s.execute(LinkCategory.__table__.select().where(LinkCategory.link_id == link_id))
        ).all()
        assert len(cats) == 1  # category persisted despite summarizer failure
