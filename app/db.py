import asyncio
import logging
from collections.abc import AsyncIterator

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.config import settings

logger = logging.getLogger(__name__)

# Pool tuned to keep connections WARM. Establishing a fresh connection to a
# remote Neon instance costs seconds (TLS + SCRAM auth over the wire, plus a
# possible compute wake), whereas a reused connection is ~1 round-trip. So we
# hold a small persistent pool and refresh it rarely.
# When pointed at Neon's POOLED endpoint (host contains "-pooler"), PgBouncer
# runs in transaction mode and can't use server-side prepared statements, so
# asyncpg's statement cache must be disabled. Detected automatically so a
# one-line DATABASE_URL host change ("ep-xxx" -> "ep-xxx-pooler") just works.
_is_pooled = "-pooler" in settings.database_url
_connect_args = {"statement_cache_size": 0} if _is_pooled else {}

engine = create_async_engine(
    settings.database_url,
    echo=False,
    future=True,
    pool_pre_ping=True,      # validate on checkout (cheap on a warm conn)
    pool_size=5,             # persistent warm connections
    max_overflow=5,          # burst headroom
    pool_recycle=1800,       # recycle after 30 min, not 5
    pool_timeout=30,
    connect_args=_connect_args,
)

AsyncSessionLocal = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)


async def get_session() -> AsyncIterator[AsyncSession]:
    async with AsyncSessionLocal() as session:
        yield session


async def warm_pool() -> None:
    """Open + validate a connection at startup so the first real request
    doesn't pay the multi-second cold-connect cost."""
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        logger.info('"event":"db_warm_ok"')
    except Exception as exc:
        logger.warning('"event":"db_warm_fail","error":"%s"', exc)


async def heartbeat(interval_seconds: int = 60) -> None:
    """Periodic SELECT 1 that (a) keeps a pooled connection alive so it isn't
    dropped as idle, and (b) prevents Neon from autosuspending its compute —
    which is what causes the occasional ~7s cold spikes. Runs until cancelled."""
    while True:
        try:
            await asyncio.sleep(interval_seconds)
            async with engine.connect() as conn:
                await conn.execute(text("SELECT 1"))
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.warning('"event":"db_heartbeat_fail","error":"%s"', exc)
