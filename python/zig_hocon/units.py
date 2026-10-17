"""Durations and sizes in a program's own hands (a pydantic validator, a
msgspec dec_hook), by the rules of ``hocon.Duration`` and ``hocon.Size``."""

import datetime
import json

from .config_parser import ConfigFactory
from .config_tree import ConfigTree
from .exceptions import ConfigException, ConfigWrongTypeException

__all__ = ["parse_bytes", "parse_duration"]


def _single(value: str | int | float, what: str) -> ConfigTree:
    """``value`` alone in a document, as ``v``, to be read by the getters."""
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        raise TypeError(f"{what}: expected text or a number, not {type(value).__name__}")
    return ConfigFactory.parse_string(f"v = {json.dumps(value)}", env=None)


def parse_duration(text: str | int | float) -> datetime.timedelta:
    """``"30s"``, ``"2 minutes"`` or a number of milliseconds as a timedelta,
    by the rules of ``hocon.Duration``. ConfigWrongTypeException, a
    ValueError, when it is none."""
    try:
        return _single(text, "parse_duration").get_duration("v")
    except ConfigException:
        raise ConfigWrongTypeException(f"not a duration: {text!r}", name="WrongType") from None


def parse_bytes(text: str | int | float) -> int:
    """``"512MB"``, ``"1.5 GiB"`` or a number of bytes as an int, by the rules
    of ``hocon.Size``. ConfigWrongTypeException, a ValueError, when it is none."""
    try:
        return _single(text, "parse_bytes").get_bytes("v")
    except ConfigException:
        raise ConfigWrongTypeException(f"not a size in bytes: {text!r}", name="WrongType") from None
