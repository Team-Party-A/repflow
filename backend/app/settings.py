import os

from pydantic import BaseModel, ConfigDict, Field, SecretStr
from sqlalchemy import URL


class DatabaseSettings(BaseModel):
    model_config = ConfigDict(hide_input_in_errors=True)

    host: str = Field(default="db", min_length=1)
    port: int = Field(default=5432, ge=1, le=65535)
    name: str = Field(default="repflow", min_length=1)
    user: str = Field(default="repflow", min_length=1)
    password: SecretStr = Field(min_length=1)

    @classmethod
    def from_environment(cls):
        return cls(
            host=os.environ.get("DB_HOST", "db"),
            port=os.environ.get("DB_PORT", "5432"),
            name=os.environ.get("DB_NAME", "repflow"),
            user=os.environ.get("DB_USER", "repflow"),
            password=os.environ.get("DB_PASSWORD", ""),
        )

    @property
    def url(self) -> URL:
        return URL.create(
            "postgresql+psycopg",
            username=self.user,
            password=self.password.get_secret_value(),
            host=self.host,
            port=self.port,
            database=self.name,
        )
