"""The getters on one document at a time: what each gives, and what it
raises. The conversions are the Zig library's (src/capi.zig has the same
table in Zig); these check they reach Python intact."""

import datetime
import gc
import threading

import pytest

import zig_hocon
from zig_hocon import (
    KEEP,
    ConfigException,
    ConfigFactory,
    ConfigMissingException,
    ConfigWrongTypeException,
    Period,
)


def get(src, method, path):
    return getattr(ConfigFactory.parse_string(src, env=None), method)(path)


# java ✓ · pyhocon ⚠️ (get_int truncates 1.5, get_string("a") on null is None,
# no durations, sizes or periods) · spec ✓ (automatic type conversions, units)
@pytest.mark.parametrize(
    "src, method, path, want",
    [
        ("a = 5", "get_int", "a", 5),
        ('a = "5"', "get_int", "a", 5),
        ("a = -3", "get_int", "a", -3),
        ("a = 9223372036854775807", "get_int", "a", 9223372036854775807),
        ("a = 1.5", "get_float", "a", 1.5),
        ('a = "5"', "get_float", "a", 5.0),
        ("a = yes", "get_bool", "a", True),
        ("a = off", "get_bool", "a", False),
        ("a = the owl ate the router", "get_string", "a", "the owl ate the router"),
        ("a = 1e3", "get_string", "a", "1e3"),
        ("a = true", "get_string", "a", "true"),
        ('a = ""', "get_string", "a", ""),
        ('a = "café 🦆"', "get_string", "a", "café 🦆"),
        # A surrogate on its own is no UTF-8; Python has it as it was written.
        (r'a = "\ud83d"', "get_string", "a", "\ud83d"),
        ("a = 10s", "get_duration", "a", datetime.timedelta(seconds=10)),
        ("a = 2 minutes", "get_duration", "a", datetime.timedelta(minutes=2)),
        ("a = 3", "get_duration", "a", datetime.timedelta(milliseconds=3)),
        ("a = 1500ns", "get_duration", "a", datetime.timedelta(microseconds=2)),
        ("a = -1.5s", "get_duration", "a", datetime.timedelta(seconds=-1.5)),
        ("a = 512MB", "get_bytes", "a", 512_000_000),
        ('a = "1.5 GiB"', "get_bytes", "a", 1_610_612_736),
        ("a = 3", "get_bytes", "a", 3),
        ("a = 3mo", "get_period", "a", Period(years=0, months=3, days=0)),
        ("a = 2w", "get_period", "a", Period(years=0, months=0, days=14)),
        ("a = 1y", "get_period", "a", Period(years=1, months=0, days=0)),
        ("db { host = burrow.example }", "get_string", "db.host", "burrow.example"),
        ('a { "b.c" = dot }', "get_string", 'a."b.c"', "dot"),
    ],
)
def test_getter(src, method, path, want):
    got = get(src, method, path)
    assert got == want
    assert type(got) is type(want)


# java ✓ (WrongType, Null is a Missing, BadPath; ⚠️ getInt truncates 1.5) ·
# pyhocon ⚠️ · spec ✓
@pytest.mark.parametrize(
    "src, method, path, error",
    [
        ("a = 1.5", "get_int", "a", ConfigWrongTypeException),
        ("a = 1e3", "get_int", "a", ConfigWrongTypeException),
        ("a = 9223372036854775808", "get_int", "a", ConfigWrongTypeException),
        ("a = true", "get_int", "a", ConfigWrongTypeException),
        # JSON numbers only (spec L1238); java ⚠️ reads "+5", pyhocon ⚠️ also 1_000.
        ("a = 1_000", "get_int", "a", ConfigWrongTypeException),
        ('a = "+5"', "get_int", "a", ConfigWrongTypeException),
        ('a = "0x10"', "get_float", "a", ConfigWrongTypeException),
        ('a = "5"', "get_bool", "a", ConfigWrongTypeException),
        ("a = [1, 2]", "get_string", "a", ConfigWrongTypeException),
        ("a { b = 1 }", "get_string", "a", ConfigWrongTypeException),
        ("a = 10 parsecs", "get_duration", "a", ConfigWrongTypeException),
        ("a = 10s", "get_bytes", "a", ConfigWrongTypeException),
        ("a = 1.5", "get_period", "a", ConfigWrongTypeException),
        ("a = [1]", "get_config", "a", ConfigWrongTypeException),
        ("a = 5", "get_string", "a.b", ConfigWrongTypeException),
        ("a = null", "get_string", "a", ConfigMissingException),
        ("a = null", "get_config", "a", ConfigMissingException),
        ("a = null", "get_string", "a.b", ConfigMissingException),
        ("a = 1", "get_string", "b", ConfigMissingException),
        ("a = 1", "get_string", "a..b", ConfigException),
    ],
)
def test_getter_refuses(src, method, path, error):
    with pytest.raises(error):
        get(src, method, path)


# A value that does not convert is shown where it is written, as a parse
# error is: what the getter wanted, the line, a caret. java ✓ (WrongType, same
# path and line) · pyhocon ⚠️ (no place) · spec –
def test_messages():
    conf = ConfigFactory.parse_string("db { pool = eight }", env=None)
    with pytest.raises(ConfigWrongTypeException) as e:
        conf.get_int("db.pool")
    assert str(e.value) == "1:13: InvalidCharacter at db.pool: expected i64\ndb { pool = eight }\n            ^"
    assert (e.value.name, e.value.line, e.value.column) == ("InvalidCharacter", 1, 13)
    with pytest.raises(ConfigWrongTypeException, match=r"^1:1: TypeMismatch at the document: expected i64"):
        conf.get_int("")
    # A path that ends before it gets there has no value to point at.
    with pytest.raises(ConfigWrongTypeException, match=r"^db.pool.size is not an int$"):
        conf.get_int("db.pool.size")
    # pyhocon's message, and a KeyError for code that catches that.
    with pytest.raises(KeyError, match="No configuration setting found for key db.host"):
        conf.get_string("db.host")
    with pytest.raises(ConfigException, match=r"not a path: 'db\.\.pool'"):
        conf.get_int("db..pool")


# pyhocon ✓ (default=), java – (no defaults on getters; hasPath is false
# for a path through a scalar or a list)
def test_default_is_for_missing_only():
    conf = ConfigFactory.parse_string("a = 1\nn = null\nl = [1]", env=None)
    assert conf.get_int("b", 42) == 42
    assert conf.get_string("n", "the cat sat on the keyboard") == "the cat sat on the keyboard"
    assert conf.get_config("nope", None) is None
    assert conf.get_int("a", 42) == 1
    # Nothing is at a path that runs through a scalar or a list.
    assert conf.get_int("a.b", 7) == 7
    assert conf.get_int("l.b", 7) == 7
    assert conf.get_config("a.b", None) is None
    with pytest.raises(ConfigWrongTypeException):
        conf.get_int("l", 42)
    with pytest.raises(ConfigWrongTypeException, match=r"^3:6: TypeMismatch at l: expected object"):
        conf.get_config("l", None)
    with pytest.raises(ConfigWrongTypeException):
        conf.get_int("a.b")
    # An object that waits for a variable is there, and no int.
    kept = ConfigFactory.parse_string("o { p = ${MOOD} }", env=KEEP)
    with pytest.raises(ConfigWrongTypeException):
        kept.get_int("o", 42)


# Whitespace around a path is no part of it, in a subtree too. java ✓ (8, 1)
# · pyhocon ⚠️ (splits at every dot) · spec ✓ (path expressions)
def test_get_config_path_whitespace():
    conf = ConfigFactory.parse_string('a { x = 1, "x.y" { z = 8 } }', env=None)
    assert conf.get_config(" a ").get_int("x") == 1
    assert conf.get_config("a\n").get_int(" x\t") == 1
    assert conf.get_config("a").get_int(' "x.y".z ') == 8
    assert conf.get_config(" a ").get_config(' "x.y" ').as_dict() == {"z": 8}
    with pytest.raises(ConfigException, match="not a path"):
        conf.get_config("a").get_int("  ")


# C ends a string at a 0: a path with one inside would be another path. As
# open() and os.stat() have it, that is a ValueError. java – (a Java string
# carries a 0; a C-only concern) · pyhocon ⚠️ (ConfigMissingException: no key
# has that name) · spec –
def test_nul_in_a_path():
    conf = ConfigFactory.parse_string("x = 1\ny { z = 2 }", env=None)
    for call in [
        lambda: conf.get_int("x\0nope"),
        lambda: conf.get_config("y\0nope"),
        lambda: conf.get_config("y").get_int("z\0"),
        lambda: ConfigFactory.parse_string("a = ${X}", env={"X": "the\0end"}),
    ]:
        with pytest.raises(ValueError, match="embedded null byte"):
            call()


# java ✓ (getConfig) · pyhocon ✓ · spec –: a subtree reads its own paths, and
# keeps the document alive when the tree it came from is gone.
def test_get_config():
    db = ConfigFactory.parse_string("db { host = burrow, pool { size = 4 } }\nport = 80", env=None).get_config("db")
    gc.collect()
    assert db.get_string("host") == "burrow"
    assert db.get_config("pool").get_int("size") == 4
    assert db.as_dict() == {"host": "burrow", "pool": {"size": 4}}
    assert db.to_hocon() == "host = burrow\npool {\n  size = 4\n}\n"
    with pytest.raises(ConfigMissingException, match="db.port"):
        db.get_int("port")
    assert db.get_config("").get_string("host") == "burrow"


def test_to_json_is_bytes():
    conf = ConfigFactory.parse_string("a { b = [1, x], t = 30s }", env=None)
    assert conf.to_json() == b'{"a":{"b":[1,"x"],"t":"30s"}}'
    assert conf.get_config("a").to_json() == b'{"b":[1,"x"],"t":"30s"}'


# java ⚠️ prints it · spec –: JSON as std.json writes it stops at 256 levels.
def test_too_deep_for_json():
    conf = ConfigFactory.parse_string("a = " + "[" * 300 + "]" * 300, env=None)
    with pytest.raises(ConfigException, match="256"):
        conf.as_dict()
    assert conf.to_hocon().startswith("a = [\n  [\n    [")


# The same rules as hocon.Duration and hocon.Size, for values a program has
# in hand (a pydantic validator, a msgspec dec_hook): a ValueError when the
# text is none, so those report it as a validation error.
def test_parse_duration_and_bytes():
    assert zig_hocon.parse_duration("30s") == datetime.timedelta(seconds=30)
    assert zig_hocon.parse_duration("1.5 hours") == datetime.timedelta(minutes=90)
    assert zig_hocon.parse_duration(250) == datetime.timedelta(milliseconds=250)
    assert zig_hocon.parse_bytes("512MB") == 512_000_000
    assert zig_hocon.parse_bytes("1 KiB") == 1024
    assert zig_hocon.parse_bytes(7) == 7
    for bad in ["30 parsecs", "", "a = 1", '"', "30s\nb = 1"]:
        with pytest.raises(ValueError, match="not a duration"):
            zig_hocon.parse_duration(bad)
    with pytest.raises(ValueError, match="not a size"):
        zig_hocon.parse_bytes("10s")
    for bad in [None, True, [1]]:
        with pytest.raises(TypeError):
            zig_hocon.parse_duration(bad)


# ctypes lets go of the GIL during a call, so parses on threads run at once:
# each has its own memory and its own I/O.
def test_threads():
    errors = []

    def work(i):
        try:
            for _ in range(50):
                conf = ConfigFactory.parse_string(f"n = {i}\nm = ${{n}}", env={"X": str(i)})
                assert conf.get_int("m") == i
        except Exception as e:  # noqa: BLE001 — reported below
            errors.append(e)

    threads = [threading.Thread(target=work, args=(i,)) for i in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == []


# One document read from many threads, as a web app reads its config: a getter
# that fails leaves why on the document, and each thread gets its own why.
def test_threads_share_a_document():
    conf = ConfigFactory.parse_string("a = eight\nb { c = nine }", env=None)
    db = conf.get_config("b")
    wrong = []

    def work(get, want):
        for _ in range(3000):
            try:
                get()
            except Exception as e:  # noqa: BLE001 — one torn apart is no ConfigException
                if not str(e).startswith(want):
                    wrong.append(f"{type(e).__name__}: {e}")
                    return

    calls = [
        (lambda: conf.get_int("a"), "1:5: InvalidCharacter at a: expected i64"),
        (lambda: db.get_int("c"), "2:9: InvalidCharacter at b.c: expected i64"),
        (lambda: conf.get_bool("nope"), "No configuration setting found for key nope"),
        (lambda: conf.get_int("a", 1), "1:5: InvalidCharacter at a: expected i64"),
    ]
    threads = [threading.Thread(target=work, args=c) for c in calls * 2]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert wrong == []
