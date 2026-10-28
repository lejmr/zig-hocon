"""pyhocon's ``period_parser``: a duration from its text, ``30s`` or
``10 weeks``, as pyhocon reads an unquoted value.

Changed from pyhocon's period_parser.py (Apache-2.0, LICENSE in this
directory): its units, read with a regular expression for pyparsing."""

import datetime
import importlib
import re
from typing import Any

__all__ = ["parse_period", "period"]

# pyhocon's durations: an unquoted `30s` or `10 weeks` is a timedelta, or a
# dateutil relativedelta when dateutil is installed, which months and years
# need. Milliseconds are always a timedelta.
try:
    relativedelta: Any = importlib.import_module("dateutil.relativedelta").relativedelta
except ImportError:  # pragma: no cover - the tests have dateutil and patch it away
    relativedelta = None

_UNITS = {
    "nanoseconds": ["ns", "nano", "nanos", "nanosecond", "nanoseconds"],
    "microseconds": ["us", "micro", "micros", "microsecond", "microseconds"],
    "milliseconds": ["ms", "milli", "millis", "millisecond", "milliseconds"],
    "seconds": ["s", "second", "seconds"],
    "minutes": ["m", "minute", "minutes"],
    "hours": ["h", "hour", "hours"],
    "weeks": ["w", "week", "weeks"],
    "days": ["d", "day", "days"],
}
_DATEUTIL_UNITS = {"months": ["mo", "month", "months"], "years": ["y", "year", "years"]}


def _duration_re(units: dict[str, list[str]]) -> "re.Pattern[str]":
    # the longest spelling first: `ms` before `m`, `mo` before `m`
    names = sorted((n for spellings in units.values() for n in spellings), key=len, reverse=True)
    return re.compile(r"(\d+) *(" + "|".join(names) + ")")


_DURATION = _duration_re(_UNITS)
_DURATION_DATEUTIL = _duration_re(_UNITS | _DATEUTIL_UNITS)
_UNIT_OF = {n: unit for unit, spellings in (_UNITS | _DATEUTIL_UNITS).items() for n in spellings}


def duration(text: str) -> Any:
    """``text`` as pyhocon reads a duration: one when it is a whole number
    and a unit, else ``text``."""
    m = (_DURATION if relativedelta is None else _DURATION_DATEUTIL).fullmatch(text)
    if m is None:
        return text
    value, unit = int(m[1]), _UNIT_OF[m[2]]
    if unit == "nanoseconds":
        value, unit = value // 1000, "microseconds"
    if unit == "milliseconds" or relativedelta is None:
        return datetime.timedelta(**{unit: value})
    return relativedelta(**{unit: value})


def period(period_value: int, period_unit: str) -> Any:
    """``period_value`` of ``period_unit``, ``"seconds"`` or another
    timedelta argument, ``"months"`` and ``"years"`` with dateutil, as
    pyhocon makes it."""
    return duration(f"{period_value} {period_unit}")


def parse_period(content: str) -> Any:
    """``content``, a whole number and a unit, as a duration; ValueError
    for anything else."""
    value = duration(content)
    if value is content:
        raise ValueError(f"{content!r} is not a duration")
    return value
