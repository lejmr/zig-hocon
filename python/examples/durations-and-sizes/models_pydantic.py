"""Durations and sizes in pydantic: a BeforeValidator turns the text of the
file, "30s" or "512MiB", into a timedelta or an int before pydantic checks
the type. A number alone is milliseconds or bytes, as in HOCON."""

from datetime import timedelta
from typing import Annotated

import zig_hocon
from pydantic import BaseModel, BeforeValidator


# pydantic reports a ValueError at its field, a TypeError (`true`, a list)
# not: parse_duration and parse_bytes raise one for a value of the wrong type.
def duration(value):
    if isinstance(value, timedelta):  # a model's own field, read back
        return value
    try:
        return zig_hocon.parse_duration(value)
    except TypeError as e:
        raise ValueError(e) from None


def size(value):
    try:
        return zig_hocon.parse_bytes(value)
    except TypeError as e:
        raise ValueError(e) from None


Duration = Annotated[timedelta, BeforeValidator(duration)]
Size = Annotated[int, BeforeValidator(size)]


class Http(BaseModel):
    timeout: Duration
    retry_backoff: Duration
    keepalive: Duration
    max_body: Size


class Cache(BaseModel):
    ttl: Duration
    max_size: Size


class Settings(BaseModel):
    http: Http
    cache: Cache
