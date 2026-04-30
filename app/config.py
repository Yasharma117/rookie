from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file="../.env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    app_env: str = "local"

    database_url: str
    openai_api_key: str
    gemini_api_key: str = ""
    gemini_model: str = "gemini-flash-latest"

    s3_endpoint_url: str
    s3_access_key: str
    s3_secret_key: str
    s3_bucket: str
    s3_region: str = "us-east-1"

    dev_user_api_key: str
    dev_user_id: str


settings = Settings()
