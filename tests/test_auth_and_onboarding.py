"""End-to-end v0 auth story: Apple exchange → ingest token → onboarding."""

import pytest
from sqlalchemy import select

from app.config import settings
from app.models import IngestToken, User
from app.services import apple_auth

APPLE_SUB = "001234.fake-apple-sub.5678"


@pytest.fixture
def fake_apple(monkeypatch):
    def _verify(token: str) -> dict:
        if token != "good-apple-jwt":
            raise apple_auth.AppleAuthError("bad signature")
        return {"sub": APPLE_SUB, "email": "apple-user@example.com"}

    monkeypatch.setattr(apple_auth, "verify_identity_token", _verify)


@pytest.mark.anyio
async def test_exchange_rejects_invalid_apple_token(client, fake_apple):
    r = await client.post("/v1/auth/exchange", json={"apple_jwt": "tampered"})
    assert r.status_code == 401


@pytest.mark.anyio
async def test_exchange_creates_user_and_mints_token(client, db_session, fake_apple):
    r = await client.post(
        "/v1/auth/exchange",
        json={"apple_jwt": "good-apple-jwt", "device_label": "iPhone 15"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["token"].startswith("rk_ingest_")
    assert body["onboarded"] is False

    user = (
        await db_session.execute(
            select(User).where(User.clerk_user_id == f"apple:{APPLE_SUB}")
        )
    ).scalar_one()
    assert user.email == "apple-user@example.com"
    assert str(user.id) == body["user_id"]

    tokens = (
        await db_session.execute(
            select(IngestToken).where(IngestToken.user_id == user.id)
        )
    ).scalars().all()
    assert len(tokens) == 1
    assert tokens[0].device_label == "iPhone 15"


@pytest.mark.anyio
async def test_exchange_is_idempotent_per_apple_sub(client, db_session, fake_apple):
    r1 = await client.post("/v1/auth/exchange", json={"apple_jwt": "good-apple-jwt"})
    r2 = await client.post("/v1/auth/exchange", json={"apple_jwt": "good-apple-jwt"})
    assert r1.json()["user_id"] == r2.json()["user_id"]
    # ...but each sign-in mints a fresh token (one per device/session)
    assert r1.json()["token"] != r2.json()["token"]


@pytest.mark.anyio
async def test_ingest_token_authenticates_app_endpoints(client, fake_apple):
    """The minted token must work as X-API-Key on read endpoints, /me,
    onboarding, and link ingestion — the app's full surface."""
    token = (
        await client.post("/v1/auth/exchange", json={"apple_jwt": "good-apple-jwt"})
    ).json()["token"]
    headers = {"X-API-Key": token}

    me = await client.get("/v1/me", headers=headers)
    assert me.status_code == 200
    assert me.json()["onboarded"] is False

    catalog = await client.get("/v1/onboarding/catalog")
    assert catalog.status_code == 200
    slugs = [e["slug"] for e in catalog.json()]
    assert "jobs" in slugs

    done = await client.post(
        "/v1/onboarding", headers=headers, json={"slugs": ["jobs", "travel"]}
    )
    assert done.status_code == 200
    names = {c["name"] for c in done.json()["categories"]}
    assert names == {"Jobs", "Travel", "Other"}

    me2 = await client.get("/v1/me", headers=headers)
    assert me2.json()["onboarded"] is True

    cats = await client.get("/v1/categories", headers=headers)
    assert cats.status_code == 200

    saved = await client.post(
        "/v1/links", headers=headers, json={"url": "https://example.com/a"}
    )
    assert saved.status_code in (200, 201, 202)

    links = await client.get("/v1/links", headers=headers)
    assert links.status_code == 200
    assert len(links.json()["items"]) == 1


@pytest.mark.anyio
async def test_garbage_api_key_still_rejected(client):
    r = await client.get("/v1/me", headers={"X-API-Key": "rk_ingest_not_real"})
    assert r.status_code == 401
    r = await client.get("/v1/me", headers={"X-API-Key": "nonsense"})
    assert r.status_code == 401


@pytest.mark.anyio
async def test_admin_enrich_requires_secret(client, monkeypatch):
    # Disabled when no secret configured
    monkeypatch.setattr(settings, "admin_secret", "")
    r = await client.post("/v1/admin/enrich", headers={"X-Admin-Secret": ""})
    assert r.status_code == 401

    monkeypatch.setattr(settings, "admin_secret", "s3cret")
    r = await client.post("/v1/admin/enrich", headers={"X-Admin-Secret": "wrong"})
    assert r.status_code == 401

    r = await client.post("/v1/admin/enrich", headers={"X-Admin-Secret": "s3cret"})
    assert r.status_code == 200
    assert "enriched" in r.json()
