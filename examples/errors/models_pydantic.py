from pydantic import BaseModel


class Server(BaseModel):
    host: str
    port: int


class Settings(BaseModel):
    server: Server
