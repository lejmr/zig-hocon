from dataclasses import dataclass


@dataclass
class Server:
    host: str
    port: int


@dataclass
class Settings:
    server: Server
