"""HOCON for Python, read by zig-hocon.

The parsing, the substitutions and every conversion are the Zig library's
(libhocon, next to this file); this is a thin ctypes layer over its C API
(c/hocon.h). ``ConfigFactory``, the typed getters and the exception names
are pyhocon's; the rest is its own (MIGRATING.md)::

    from zig_hocon import ConfigFactory

    conf = ConfigFactory.parse_file("deploy/prod/app.conf")
    conf.get_int("db.pool")
    conf.as_dict()

The modules are pyhocon's: ``config_parser`` (ConfigFactory), ``config_tree``
(ConfigTree), ``exceptions``; and ``units`` for durations and sizes.
"""

from .config_parser import KEEP, ConfigFactory
from .config_tree import ConfigTree
from .exceptions import (
    ConfigException,
    ConfigMissingException,
    ConfigParseException,
    ConfigSubstitutionException,
    ConfigWrongTypeException,
)
from .units import parse_bytes, parse_duration, parse_period

__all__ = [
    "KEEP",
    "ConfigException",
    "ConfigFactory",
    "ConfigMissingException",
    "ConfigParseException",
    "ConfigSubstitutionException",
    "ConfigTree",
    "ConfigWrongTypeException",
    "parse_bytes",
    "parse_duration",
    "parse_period",
]
