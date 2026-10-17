"""The service's settings as pydantic models."""

from typing import Literal

from pydantic import BaseModel


class Database(BaseModel):
    host: str
    port: int
    pool: int


class Service(BaseModel):
    name: str
    port: int
    log_level: Literal["debug", "info", "warn", "error"]
    plugins: list[str]
    db: Database


class Settings(BaseModel):
    service: Service
