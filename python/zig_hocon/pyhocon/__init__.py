"""pyhocon's API over zig-hocon: its modules, names and arguments as
pyhocon 0.3.63 has them, so that moving over is a change of import::

    from zig_hocon.pyhocon import ConfigFactory

    conf = ConfigFactory.parse_file("app.conf")
    conf.get("db.pool")
    conf.put("db.host", "db.example.org")

What a document means is the spec's, as ``zig_hocon`` reads it: where
pyhocon reads it otherwise, python/MIGRATING.md says how.

This module follows pyhocon, Copyright 2014 Francois Dang Ngoc, under the
Apache License 2.0: the files that are changed from its code say so, and
LICENSE in this directory is pyhocon's. zig-hocon is not part of the pyhocon
project; the rest of zig-hocon is BSD-3-Clause.
"""

from .config_parser import ConfigFactory, ConfigParser, ConfigSubstitutionException
from .config_tree import (
    ConfigInclude,
    ConfigList,
    ConfigSubstitution,
    ConfigTree,
    ConfigUnquotedString,
    ConfigValues,
    UndefinedKey,
)
from .converter import HOCONConverter
from .exceptions import ConfigException, ConfigMissingException, ConfigWrongTypeException

__all__ = [
    "ConfigException",
    "ConfigFactory",
    "ConfigInclude",
    "ConfigList",
    "ConfigMissingException",
    "ConfigParser",
    "ConfigSubstitution",
    "ConfigSubstitutionException",
    "ConfigTree",
    "ConfigUnquotedString",
    "ConfigValues",
    "ConfigWrongTypeException",
    "HOCONConverter",
    "UndefinedKey",
]
