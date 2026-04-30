from fastapi import FastAPI

from app.api import categories as categories_api
from app.api import links as links_api
from app.config import settings


def create_app() -> FastAPI:
    app = FastAPI(title="Rookie API", version="0.1.0")

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok", "env": settings.app_env}

    app.include_router(links_api.router)
    app.include_router(categories_api.router)
    return app


app = create_app()
