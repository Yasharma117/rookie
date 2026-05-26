import os
from collections.abc import AsyncIterator
from unittest.mock import AsyncMock, patch

import pytest

DB_FILE = "test_temp.db"

# 1. Set environment variables BEFORE importing any app modules
os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{DB_FILE}"
os.environ["S3_ENDPOINT_URL"] = "http://localhost:9000"
os.environ["S3_ACCESS_KEY"] = "mock_key"
os.environ["S3_SECRET_KEY"] = "mock_secret"
os.environ["S3_BUCKET"] = "mock_bucket"
os.environ["DEV_USER_API_KEY"] = "mock_dev_api_key"
os.environ["DEV_USER_ID"] = "00000000-0000-0000-0000-000000000001"

# 2. Start the global mock for enrich_link before app import
enrich_link_patcher = patch("app.services.enrichment.enrich_link", new_callable=AsyncMock)
mock_enrich_link = enrich_link_patcher.start()

from httpx import ASGITransport, AsyncClient  # noqa: E402
from sqlalchemy.dialects.postgresql import JSONB  # noqa: E402
from sqlalchemy.dialects.postgresql import UUID as PG_UUID  # noqa: E402
from sqlalchemy.ext.asyncio import (  # noqa: E402
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.ext.compiler import compiles  # noqa: E402

from app.db import get_session  # noqa: E402
from app.main import app  # noqa: E402
from app.models.base import Base  # noqa: E402


# 3. Register SQLite compilers for PostgreSQL-specific types
@compiles(PG_UUID, "sqlite")
def compile_pg_uuid_sqlite(element, compiler, **kw):
    return "CHAR(36)"

@compiles(JSONB, "sqlite")
def compile_jsonb_sqlite(element, compiler, **kw):
    return "JSON"

# Create a single engine and session maker for tests
test_engine = create_async_engine(f"sqlite+aiosqlite:///{DB_FILE}", echo=False)
TestingSessionLocal = async_sessionmaker(
    test_engine, expire_on_commit=False, class_=AsyncSession
)

@pytest.fixture(scope="session")
def anyio_backend():
    return "asyncio"

@pytest.fixture(scope="session", autouse=True)
async def cleanup_db_file():
    if os.path.exists(DB_FILE):
        try:
            os.remove(DB_FILE)
        except OSError:
            pass
    yield
    await test_engine.dispose()
    enrich_link_patcher.stop()
    if os.path.exists(DB_FILE):
        try:
            os.remove(DB_FILE)
        except OSError:
            pass

@pytest.fixture(autouse=True)
async def setup_db():
    # Create the schema in the SQLite DB
    async with test_engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield
    async with test_engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)

@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:
    async with TestingSessionLocal() as session:
        yield session

@pytest.fixture
async def client(db_session: AsyncSession) -> AsyncIterator[AsyncClient]:
    # Set up dependency override for get_session
    async def override_get_session():
        yield db_session

    app.dependency_overrides[get_session] = override_get_session
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c
    app.dependency_overrides.clear()
