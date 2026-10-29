"""Values in a program's own hands (a pydantic validator, a msgspec
dec_hook), by the library's rules: durations, periods and sizes as
``hocon.Duration``, ``hocon.Period`` and ``hocon.Size`` read them, and
integers and booleans as ``get_int``, ``get_bool`` and a Zig struct do."""

import datetime
import json

from .config_parser import ConfigFactory
from .config_tree import ConfigTree, Period
from .exceptions import ConfigException, ConfigWrongTypeException

__all__ = ["parse_bool", "parse_bytes", "parse_duration", "parse_int", "parse_period"]


class _NotTextOrNumber(ConfigWrongTypeException, TypeError):
    """A TypeError, as it always was, and a ValueError, which a pydantic
    validator reports as the field's error instead of letting it through."""


def _single(value: str | int | float, what: str) -> ConfigTree:
    """``value`` alone in a document, as ``v``, to be read by the getters."""
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        raise _NotTextOrNumber(f"{what}: expected text or a number, not {type(value).__name__}", name="WrongType")
    return ConfigFactory.parse_string(f"v = {json.dumps(value)}", env=None)


def parse_duration(text: str | int | float) -> datetime.timedelta:
    """``"30s"``, ``"2 minutes"`` or a number of milliseconds as a timedelta,
    by the rules of ``hocon.Duration``, up to 292 years. ConfigWrongTypeException,
    a ValueError, when it is none, named Overflow when it is longer."""
    conf = _single(text, "parse_duration")
    try:
        return conf.get_duration("v")
    except ConfigException as e:
        if e.name == "Overflow":
            raise ConfigWrongTypeException(f"a duration past 292 years, the longest an int64 of nanoseconds holds: {text!r}", name="Overflow") from None
        raise ConfigWrongTypeException(f"not a duration: {text!r}", name="WrongType") from None


def parse_bytes(text: str | int | float) -> int:
    """``"512MB"``, ``"1.5 GiB"`` or a number of bytes as an int, by the rules
    of ``hocon.Size``. ConfigWrongTypeException, a ValueError, when it is none."""
    conf = _single(text, "parse_bytes")
    try:
        return conf.get_bytes("v")
    except ConfigException:
        raise ConfigWrongTypeException(f"not a size in bytes: {text!r}", name="WrongType") from None


def parse_period(text: str | int | float) -> Period:
    """``"3mo"``, ``"2w"`` or a number of days as a ``Period`` of ``years``,
    ``months`` and ``days``, as ``get_period`` gives it, by the rules of
    ``hocon.Period``. ConfigWrongTypeException, a ValueError, when it is none."""
    conf = _single(text, "parse_period")
    try:
        return conf.get_period("v")
    except ConfigException:
        raise ConfigWrongTypeException(f"not a period: {text!r}", name="WrongType") from None


def parse_int(value: str | int) -> int:
    """``"48"`` or 48 as an int, as ``get_int`` and a Zig integer read it:
    ``"08"``, ``"+9000"``, ``"9_000"``, ``" 48"``, ``"1.5"`` and ``True`` are
    none. A lax model takes most of them; this one, as a validator, takes from
    the environment what the Zig side takes. ConfigWrongTypeException, a
    ValueError, when it is none."""
    if not isinstance(value, bool):
        conf = _single(value, "parse_int")
        try:
            return conf.get_int("v")
        except ConfigException:
            pass
    raise ConfigWrongTypeException(f"not an integer: {value!r}", name="WrongType")


def parse_bool(value: str | bool) -> bool:
    """``true``/``yes``/``on`` or ``false``/``no``/``off``, lowercase, or a
    bool, as ``get_bool`` and a Zig ``bool`` read it: ``"True"``, ``"1"`` and
    ``"y"`` are none, which a lax model takes. ConfigWrongTypeException, a
    ValueError, when it is none."""
    if isinstance(value, bool):
        return value
    conf = _single(value, "parse_bool")
    try:
        return conf.get_bool("v")
    except ConfigException:
        raise ConfigWrongTypeException(f"not a boolean: {value!r}", name="WrongType") from None
