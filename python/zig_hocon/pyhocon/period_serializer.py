"""pyhocon's ``period_serializer``: a duration written out, as pyhocon's
HOCONConverter writes it.

Changed from pyhocon's period_serializer.py (Apache-2.0, LICENSE in this
directory): typed."""

import datetime
from typing import Any

from . import period_parser

__all__ = ["is_timedelta_like", "relative_delta_to_timedelta", "timedelta_to_hocon", "timedelta_to_str"]


def is_timedelta_like(config: Any) -> bool:
    """A timedelta, or a dateutil relativedelta."""
    relativedelta = period_parser.relativedelta
    return isinstance(config, datetime.timedelta) or relativedelta is not None and isinstance(config, relativedelta)


def relative_delta_to_timedelta(relative_delta: Any) -> datetime.timedelta:
    """A relativedelta as a timedelta, its months and years left out."""
    r = relative_delta
    return datetime.timedelta(days=r.days, hours=r.hours, minutes=r.minutes, seconds=r.seconds, microseconds=r.microseconds)


def timedelta_to_hocon(config: Any) -> str:
    """A duration in its largest unit, as pyhocon's to_hocon writes it."""
    if not isinstance(config, datetime.timedelta):  # a relativedelta
        if config.hours > 0:
            return f"{config.hours} hours"
        if config.minutes > 0:
            return f"{config.minutes} minutes"
    if config.days > 0:
        return f"{config.days} days"
    if config.seconds > 0:
        return f"{config.seconds} seconds"
    if config.microseconds > 0:
        return f"{config.microseconds} microseconds"
    return "0 seconds"


def timedelta_to_str(config: Any) -> str:
    """A duration in milliseconds, as pyhocon's JSON, YAML and .properties
    write it."""
    if not isinstance(config, datetime.timedelta):
        config = relative_delta_to_timedelta(config)
    return str(int(config.total_seconds() * 1000))
