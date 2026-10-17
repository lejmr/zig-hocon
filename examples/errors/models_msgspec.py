import msgspec


class Server(msgspec.Struct):
    host: str
    port: int


class Settings(msgspec.Struct):
    server: Server
