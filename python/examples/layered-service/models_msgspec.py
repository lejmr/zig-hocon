"""The service's settings as msgspec Structs."""

from typing import Literal

import msgspec


class Database(msgspec.Struct):
    host: str
    port: int
    pool: int


class Service(msgspec.Struct):
    name: str
    port: int
    log_level: Literal["debug", "info", "warn", "error"]
    plugins: list[str]
    db: Database


class Settings(msgspec.Struct):
    service: Service
