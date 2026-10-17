"""The service's settings as standard library dataclasses. They check no types
and build no nested objects themselves: msgspec.json.decode does both."""

from dataclasses import dataclass
from typing import Literal


@dataclass
class Database:
    host: str
    port: int
    pool: int


@dataclass
class Service:
    name: str
    port: int
    log_level: Literal["debug", "info", "warn", "error"]
    plugins: list[str]
    db: Database


@dataclass
class Settings:
    service: Service
