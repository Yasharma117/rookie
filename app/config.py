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

    s3_endpoint_url: str
    s3_access_key: str
    s3_secret_key: str
    s3_bucket: str
    s3_region: str = "us-east-1"

    dev_user_api_key: str
    dev_user_id: str


settings = Settings()
