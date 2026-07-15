from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=(".env", "../.env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_env: str = "local"

    database_url: str
    openai_api_key: str = ""       # optional — used if no gemini/openrouter key
    gemini_api_key: str = ""
    gemini_model: str = "gemini-2.0-flash"   # stable slug; was gemini-flash-latest
    openrouter_api_key: str = ""  # optional — enables multi-model fallback via OpenRouter

    clerk_publishable_key: str = ""
    clerk_secret_key: str = ""
    clerk_issuer: str = ""
    clerk_jwks_url: str = ""

    # Audience for Sign in with Apple identity tokens (the iOS bundle id).
    apple_bundle_id: str = "com.becauseyssaidso.LinkSaver"

    # Shared secret for /v1/admin/* cron endpoints. Empty disables them.
    admin_secret: str = ""

    s3_endpoint_url: str = ""
    s3_access_key: str = ""
    s3_secret_key: str = ""
    s3_bucket: str = ""
    s3_region: str = "us-east-1"
    # Public-serving base URL for stored objects, up to (not including) the key.
    # Needed when the S3 upload endpoint differs from the public-read URL, as with
    # Supabase (.../storage/v1/s3 to write, .../storage/v1/object/public/<bucket>
    # to read). Empty falls back to "<endpoint>/<bucket>" (MinIO/R2-path style).
    s3_public_base_url: str = ""

    dev_user_api_key: str
    dev_user_id: str

    # Keep the DB compute awake with a periodic ping. Defeats Neon autosuspend
    # (avoids cold-start spikes) but BURNS the free-tier compute-hour budget
    # continuously. Leave OFF on the free plan; turn ON only with a paid /
    # always-on database. The iOS client cache already hides cold-start latency,
    # so off-by-default costs the user nothing they perceive.
    db_heartbeat_enabled: bool = False


settings = Settings()
