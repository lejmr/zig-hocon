from pydantic import BaseModel


class Database(BaseModel):
    host: str
    pool: int


class Service(BaseModel):
    name: str
    port: int
    plugins: list[str]
    db: Database
    url: str


class Settings(BaseModel):
    service: Service
