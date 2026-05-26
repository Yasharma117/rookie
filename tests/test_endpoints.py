from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest

from app.models import Category, Link, LinkCategory, User
from app.schemas.enums import AssignedBy, LinkStatus, SourcePlatform

# Define test user ID and key
TEST_USER_ID = UUID("00000000-0000-0000-0000-000000000001")
AUTH_HEADERS = {"X-API-Key": "test_api_key"}

@pytest.fixture
async def test_user(db_session):
    user = User(
        id=TEST_USER_ID,
        email="test@example.com",
        api_key="test_api_key",
        onboarded_at=datetime.now(UTC)
    )
    db_session.add(user)
    await db_session.commit()
    return user

@pytest.fixture
async def default_categories(db_session, test_user):
    c_other = Category(
        id=uuid4(),
        user_id=test_user.id,
        name="Other",
        catalog_slug="other"
    )
    c_recipes = Category(
        id=uuid4(),
        user_id=test_user.id,
        name="Recipes",
        catalog_slug="recipes"
    )
    db_session.add_all([c_other, c_recipes])
    await db_session.commit()
    return {"other": c_other, "recipes": c_recipes}

@pytest.mark.anyio
async def test_health(client):
    response = await client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"

@pytest.mark.anyio
async def test_create_link_new_and_duplicate(client, db_session, test_user):
    # Test ingesting a new URL
    payload = {"url": "https://example.com/recipe-abc"}
    response = await client.post("/v1/links", json=payload, headers=AUTH_HEADERS)
    assert response.status_code == 202
    data = response.json()
    assert data["source_url"] == "https://example.com/recipe-abc"
    assert data["status"] == "pending"
    assert "id" in data

    # Test ingesting the same URL again (duplicate check)
    response_dup = await client.post("/v1/links", json=payload, headers=AUTH_HEADERS)
    assert response_dup.status_code == 200
    data_dup = response_dup.json()
    assert data_dup["id"] == data["id"]
    assert data_dup["status"] == "pending"

@pytest.mark.anyio
async def test_get_link_polling_header(client, db_session, test_user):
    # Seed a pending link
    link = Link(
        id=uuid4(),
        user_id=test_user.id,
        source_url="https://example.com/pending",
        canonical_url="https://example.com/pending",
        status=LinkStatus.pending
    )
    db_session.add(link)
    await db_session.commit()

    response = await client.get(f"/v1/links/{link.id}", headers=AUTH_HEADERS)
    assert response.status_code == 200
    assert response.headers.get("Retry-After") == "2"

@pytest.mark.anyio
async def test_update_link_note_and_remind_at(client, db_session, test_user, default_categories):
    # Seed a link
    link = Link(
        id=uuid4(),
        user_id=test_user.id,
        source_url="https://example.com/update",
        canonical_url="https://example.com/update",
        status=LinkStatus.pending
    )
    db_session.add(link)
    await db_session.commit()

    remind_time = (datetime.now(UTC) + timedelta(days=1)).isoformat()
    payload = {
        "note": "This is a custom user note.",
        "remind_at": remind_time,
        "category_ids": [str(default_categories["recipes"].id)]
    }
    response = await client.patch(f"/v1/links/{link.id}", json=payload, headers=AUTH_HEADERS)
    assert response.status_code == 200
    data = response.json()
    assert data["note"] == "This is a custom user note."
    assert data["remind_at"] is not None
    assert len(data["categories"]) == 1
    assert data["categories"][0]["name"] == "Recipes"

@pytest.mark.anyio
async def test_delete_category_protection(client, db_session, test_user, default_categories):
    # Trying to delete "Other" should raise 409
    other_id = default_categories["other"].id
    response = await client.delete(f"/v1/categories/{other_id}", headers=AUTH_HEADERS)
    assert response.status_code == 409
    assert "Cannot delete the default 'Other' category" in response.json()["detail"]

    # Deleting custom category "Recipes" should work
    recipes_id = default_categories["recipes"].id
    response_ok = await client.delete(f"/v1/categories/{recipes_id}", headers=AUTH_HEADERS)
    assert response_ok.status_code == 204

@pytest.mark.anyio
async def test_list_links_pagination_and_filters(client, db_session, test_user, default_categories):
    # Seed multiple links with distinct ingested_at times and fields
    now = datetime.now(UTC)
    link1 = Link(
        id=uuid4(),
        user_id=test_user.id,
        source_url="https://youtube.com/watch?v=123",
        canonical_url="https://youtube.com/watch?v=123",
        source_platform=SourcePlatform.youtube,
        title="Python Tutorial",
        description="Learn Python in 10 minutes",
        status=LinkStatus.enriched,
        ingested_at=now - timedelta(minutes=10)
    )
    link2 = Link(
        id=uuid4(),
        user_id=test_user.id,
        source_url="https://example.com/news",
        canonical_url="https://example.com/news",
        source_platform=SourcePlatform.web,
        title="Global News Today",
        description="Latest breaking news",
        status=LinkStatus.enriched,
        ingested_at=now - timedelta(minutes=5)
    )
    db_session.add_all([link1, link2])
    await db_session.commit()

    # Link category association
    lc = LinkCategory(
        link_id=link2.id,
        category_id=default_categories["recipes"].id,
        confidence=0.9,
        assigned_by=AssignedBy.user
    )
    db_session.add(lc)
    await db_session.commit()

    # Test filtering by platform
    resp_plat = await client.get("/v1/links?platform=youtube", headers=AUTH_HEADERS)
    assert resp_plat.status_code == 200
    assert len(resp_plat.json()["items"]) == 1
    assert resp_plat.json()["items"][0]["source_platform"] == "youtube"

    # Test filtering by status
    resp_stat = await client.get("/v1/links?status=enriched", headers=AUTH_HEADERS)
    assert resp_stat.status_code == 200
    assert len(resp_stat.json()["items"]) == 2

    # Test query filter (q)
    resp_q = await client.get("/v1/links?q=News", headers=AUTH_HEADERS)
    assert resp_q.status_code == 200
    assert len(resp_q.json()["items"]) == 1
    assert resp_q.json()["items"][0]["title"] == "Global News Today"

    # Test keyset cursor pagination: limit=1, order is ingested_at DESC
    # Should get link2 first (5 mins ago), then link1 (10 mins ago)
    resp_p1 = await client.get("/v1/links?limit=1", headers=AUTH_HEADERS)
    assert resp_p1.status_code == 200
    p1_data = resp_p1.json()
    assert len(p1_data["items"]) == 1
    assert p1_data["items"][0]["id"] == str(link2.id)
    assert p1_data["next_cursor"] is not None

    # Get next page using cursor with limit larger than remaining items
    cursor = p1_data["next_cursor"]
    resp_p2 = await client.get(f"/v1/links?limit=5&cursor={cursor}", headers=AUTH_HEADERS)
    assert resp_p2.status_code == 200
    p2_data = resp_p2.json()
    assert len(p2_data["items"]) == 1
    assert p2_data["items"][0]["id"] == str(link1.id)
    assert p2_data["next_cursor"] is None
