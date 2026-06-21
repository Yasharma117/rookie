"""FastAPI application factory.

Changes from v0:
- lifespan context manager with startup drain for stale pending links
- Structured JSON request logging middleware with X-Request-ID propagation
- slowapi rate limiting on write endpoints
"""
import asyncio
import contextlib
import logging
import time
import uuid
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta

from fastapi import FastAPI, Request
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address
from sqlalchemy import select

from app.api import categories as categories_api
from app.api import ingest_tokens as ingest_tokens_api
from app.api import links as links_api
from app.api import onboarding as onboarding_api
from app.config import settings
from app.db import AsyncSessionLocal, heartbeat, warm_pool
from app.models import Link
from app.schemas.enums import LinkStatus
from app.services.enrichment import MAX_ENRICH_ATTEMPTS, enrich_link

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Rate limiter (in-memory for dev, pass REDIS_URL for prod multi-instance)
# ---------------------------------------------------------------------------
limiter = Limiter(key_func=get_remote_address)


# ---------------------------------------------------------------------------
# Startup drain — re-queue links stuck pending from a previous server run
# ---------------------------------------------------------------------------

async def _drain_stale_pending() -> None:
    cutoff = datetime.now(UTC) - timedelta(seconds=30)
    async with AsyncSessionLocal() as session:
        ids = (
            await session.execute(
                select(Link.id).where(
                    Link.status == LinkStatus.pending,
                    Link.ingested_at < cutoff,
                    Link.enrich_attempts < MAX_ENRICH_ATTEMPTS,
                )
            )
        ).scalars().all()

    if ids:
        logger.info(
            '"event":"startup_drain","count":%d,"msg":"re-queuing stale pending links"',
            len(ids),
        )
        for link_id in ids:
            asyncio.create_task(enrich_link(link_id))


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Warm the DB pool first so the first request isn't a multi-second cold
    # connect, then keep it warm (and Neon awake) with a background heartbeat.
    await warm_pool()
    hb_task = asyncio.create_task(heartbeat())
    await _drain_stale_pending()
    try:
        yield
    finally:
        hb_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await hb_task


# ---------------------------------------------------------------------------
# Application factory
# ---------------------------------------------------------------------------

def create_app() -> FastAPI:
    logging.basicConfig(
        level=logging.INFO,
        format='{"ts":"%(asctime)s","level":"%(levelname)s","name":"%(name)s","msg":%(message)s}',
    )

    app = FastAPI(title="Rookie API", version="0.1.0", lifespan=lifespan)

    # Attach rate limiter
    app.state.limiter = limiter
    app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

    # ---------------------------------------------------------------------------
    # Request logging middleware — structured JSON, X-Request-ID propagation
    # ---------------------------------------------------------------------------
    @app.middleware("http")
    async def request_logging(request: Request, call_next):
        req_id = request.headers.get("X-Request-ID", str(uuid.uuid4())[:8])
        t0 = time.monotonic()
        response = await call_next(request)
        ms = int((time.monotonic() - t0) * 1000)
        logger.info(
            '"event":"request","path":"%s","method":"%s","status":%d,"ms":%d,"req_id":"%s"',
            request.url.path,
            request.method,
            response.status_code,
            ms,
            req_id,
        )
        response.headers["X-Request-ID"] = req_id
        return response

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok", "env": settings.app_env}

    app.include_router(onboarding_api.router)
    app.include_router(links_api.router)
    app.include_router(categories_api.router)
    app.include_router(ingest_tokens_api.router)
    return app


app = create_app()
