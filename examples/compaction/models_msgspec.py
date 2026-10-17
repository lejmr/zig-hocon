import msgspec


class Database(msgspec.Struct):
    host: str
    pool: int


class Service(msgspec.Struct):
    name: str
    port: int
    plugins: list[str]
    db: Database
    url: str


class Settings(msgspec.Struct):
    service: Service
