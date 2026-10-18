"""Durations and sizes in dataclasses, decoded by msgspec: the same Duration,
Size and dec_hook as models_msgspec."""

from dataclasses import dataclass

from models_msgspec import Duration, Size


@dataclass
class Http:
    timeout: Duration
    retry_backoff: Duration
    keepalive: Duration
    max_body: Size


@dataclass
class Cache:
    ttl: Duration
    max_size: Size


@dataclass
class Settings:
    http: Http
    cache: Cache
