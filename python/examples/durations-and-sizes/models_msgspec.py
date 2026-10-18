"""Durations and sizes in msgspec: a field of a type msgspec does not know is
handed to dec_hook. timedelta and int it does know (a timedelta only as ISO
8601, "PT30S"), so the fields have types of their own, Duration and Size."""

from datetime import timedelta

import msgspec
import zig_hocon


class Duration(timedelta):
    """A timedelta that msgspec leaves to dec_hook."""


class Size(int):
    """An int that msgspec leaves to dec_hook."""


def dec_hook(type, value):
    if type is Duration:
        d = zig_hocon.parse_duration(value)
        return Duration(d.days, d.seconds, d.microseconds)
    if type is Size:
        return Size(zig_hocon.parse_bytes(value))
    raise NotImplementedError(type)


class Http(msgspec.Struct):
    timeout: Duration
    retry_backoff: Duration
    keepalive: Duration
    max_body: Size


class Cache(msgspec.Struct):
    ttl: Duration
    max_size: Size


class Settings(msgspec.Struct):
    http: Http
    cache: Cache
