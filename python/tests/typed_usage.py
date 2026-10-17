"""Not run: `zig build test-python` has mypy --strict read it, for the types a
program that uses the package sees. A `type: ignore` here is an error mypy
must find; one it does not find fails too (warn_unused_ignores)."""

import datetime
import os
import pathlib
from typing import Any

from typing_extensions import assert_type

from zig_hocon import KEEP, ConfigFactory, ConfigTree, ConfigWrongTypeException, parse_bytes, parse_duration

conf = ConfigFactory.parse_string("db { pool = 4, timeout = 30s }", env=None)
assert_type(conf, ConfigTree)
assert_type(conf.get_int("db.pool"), int)
assert_type(conf.get_int("db.size", None), int | None)
assert_type(conf.get_int("db.size", 8), int)
assert_type(conf.get_string("db.host", "localhost"), str)
assert_type(conf.get_float("db.ratio"), float)
assert_type(conf.get_bool("db.debug", False), bool)
assert_type(conf.get_duration("db.timeout"), datetime.timedelta)
assert_type(conf.get_bytes("db.cache"), int)
assert_type(conf.get_period("db.keep"), dict[str, int])
assert_type(conf.get_config("db"), ConfigTree)
assert_type(conf.get_config("cache", None), ConfigTree | None)
assert_type(conf.as_dict(), dict[str, Any])
assert_type(conf.to_json(), bytes)
assert_type(conf.to_hocon(), str)
assert_type(parse_duration("30s"), datetime.timedelta)
assert_type(parse_bytes(512), int)

ConfigFactory.parse_file("app.conf")
ConfigFactory.parse_file(pathlib.Path("app.conf"), env=os.environ)
ConfigFactory.parse_file(b"app.conf", env={"PORT": "8080"}, resolve=False)
ConfigFactory.parse_string(b"a = 1", basedir=pathlib.Path("conf"), env=KEEP)

conf.get_int(1)  # type: ignore[call-overload]
ConfigFactory.parse_file("app.conf", env={"PORT": 8080})  # type: ignore[arg-type]
ConfigFactory.parse_file("app.conf", None)  # type: ignore[call-arg]
parse_duration(None)  # type: ignore[arg-type]
error: ValueError = ConfigWrongTypeException("the toaster has opinions")
