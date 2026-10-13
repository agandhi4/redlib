"""Settings: every environment variable the server reads is declared here.

.env.example mirrors this class; an undeclared key in a .env file fails startup.
"""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="forbid")

    database_url: str = "postgresql+asyncpg://__NAME__@localhost:5432/__NAME__"
    # Baked into the image by the build (ARG -> ENV); never set in compose. Reported by
    # /health/ready and the boot log line (observability.md, Release Identity).
    app_version: str = "dev"
    log_level: str = "INFO"
