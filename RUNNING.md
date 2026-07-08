# Running rookie locally

How to bring the backend up from scratch on a fresh checkout.

## Prerequisites

- Python 3.12+
- Docker Desktop (for local Postgres + MinIO — skip if using hosted Neon/R2)
- [uv](https://docs.astral.sh/uv/) — install with `brew install uv`

## One-time setup

### 1. Configure secrets

```bash
cp .env.example .env
```

Required:
- `OPENROUTER_API_KEY` — enables the multi-model classifier waterfall (preferred), **or** `GEMINI_API_KEY` / `OPENAI_API_KEY` as direct fallbacks.
- `DATABASE_URL` — the local docker-compose value works as-is; swap in your Neon URL for hosted.

The Postgres / MinIO / dev-user values in `.env.example` work as-is for local dev.

### 2. Install Python dependencies

```bash
uv sync
```

### 3. Start infrastructure (local mode)

```bash
docker compose up -d
```

This launches:
- Postgres 16 on `localhost:5432` (user/pass/db: `rookie/rookie/rookie`)
- MinIO S3-compatible storage on `localhost:9000` (console at `localhost:9001`, login `minioadmin/minioadmin`)

### 4. Apply database migrations

```bash
uv run alembic upgrade head
```

### 5. Seed the dev user + default categories

```bash
uv run python -m app.seed
```

Idempotent — safe to re-run. Creates one user with the api key from `DEV_USER_API_KEY`.

### 6. Create the MinIO bucket

```bash
uv run python -c "from app.services.storage import ensure_bucket; ensure_bucket()"
```

## Running the API

```bash
uv run uvicorn app.main:app --reload
```

Serves at `http://localhost:8000`. Interactive docs at `http://localhost:8000/docs`.

## Smoke tests

```bash
# 1. Health
curl localhost:8000/health

# 2. List seeded categories
curl localhost:8000/v1/categories -H "X-API-Key: test123" | python3 -m json.tool

# 3. Save a link (returns 202, enrichment runs in background)
curl -X POST localhost:8000/v1/links \
  -H "X-API-Key: test123" -H "Content-Type: application/json" \
  -d '{"url":"https://www.youtube.com/watch?v=Iy-dJwHVX84"}' | python3 -m json.tool

# 4. Wait ~10s, then list links — title, thumbnail, category should be populated
sleep 10
curl localhost:8000/v1/links -H "X-API-Key: test123" | python3 -m json.tool
```

## Auth model (v0)

- **iOS app**: Sign in with Apple → `POST /v1/auth/exchange` verifies the Apple
  identity token, creates the user, and returns an ingest token (`rk_ingest_…`).
  The app sends it as `X-API-Key` on every request.
- **Dev bypass**: `X-API-Key: <DEV_USER_API_KEY>` maps to the seeded dev user.
- **Clerk Bearer** (optional): enabled only when the `CLERK_*` vars are set.

## Admin cron

`POST /v1/admin/enrich` with header `X-Admin-Secret: $ADMIN_SECRET` re-runs
enrichment on up to 10 stuck-pending links. Disabled when `ADMIN_SECRET` is
empty. Point a cron (e.g. the keep-alive GitHub workflow) at it.

## Day-to-day workflow

```bash
docker compose up -d
uv run uvicorn app.main:app --reload

# stop the API:  Ctrl+C
# stop infra:    docker compose stop      (preserves data)
# nuke infra:    docker compose down -v   (drops Postgres + MinIO data)
```

## Common uv commands

```bash
uv sync                                  # install/update deps
uv run pytest                            # run tests
uv run ruff check .                      # lint
uv run mypy app                          # typecheck
uv run alembic revision --autogenerate -m "msg"   # new migration
uv run alembic upgrade head              # apply migrations
```

## Troubleshooting

**`docker: not running`** — open Docker Desktop, wait for the whale icon to settle.

**Link stuck in `pending`** — enrichment crashed silently. Check the uvicorn log;
inspect `links` for `status='failed'`. Or hit `/v1/admin/enrich` to retry.

**`401 Missing X-API-Key`** — every endpoint except `/health`, `/v1/auth/exchange`,
and `/v1/onboarding/catalog` requires auth.

**Classifier always returns "Other" with confidence 0.0** — the LLM call is
failing; check the key/quota for OpenRouter (or Gemini/OpenAI).

**Port already in use** — something else is on 8000/5432/9000. Stop it or change
the port mapping in `docker-compose.yml` and the URLs in `.env`.
