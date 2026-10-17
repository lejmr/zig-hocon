from dataclasses import dataclass


@dataclass
class Database:
    host: str
    pool: int


@dataclass
class Service:
    name: str
    port: int
    plugins: list[str]
    db: Database
    url: str


@dataclass
class Settings:
    service: Service
