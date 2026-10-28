"""zig_hocon.pyhocon against pyhocon itself, the newest release: each document read by
both, the values and their types the same, and HOCONConverter's output to the
character. Where they differ by design the case is an xfail that says why,
strict, so a difference that goes away shows."""

import datetime

import pytest

pyhocon = pytest.importorskip("pyhocon")
relativedelta = pytest.importorskip("dateutil.relativedelta").relativedelta

import zig_hocon  # noqa: E402
import zig_hocon.pyhocon as compat  # noqa: E402


def differs(text, why):
    return pytest.param(text, marks=pytest.mark.xfail(strict=True, reason=why))


CASES = {
    # scalars
    "numbers": "a = 1\nb = -2\nc = 2.5\nd = 1e3\ne = 0.75",
    "bools and null": "a = true\nb = false\nc = null\nd = yes",
    "unquoted text": "owl = the owl hoots at midnight",
    # text since 0.5.3, as the spec has it; it was an error and an xfail here
    "-Xmx unquoted": "opts = [-Xmx1g]",
    "numbers JSON has not": differs(
        "a = 0024\nb = -0024\nc = 007.5\nd = 01e2\ne = .54\nf = -.5\ng = [00, 1]", "text by the spec, unquoted too; pyhocon reads numbers"
    ),
    "quoted numbers": 'port = "8080"\nratio = "0.5"\nbig = "1e3"',
    "quoted text": 'owl = "hoot, hoot"\nempty = ""',
    "escapes": r'a = "tab\there"' + "\n" + r'b = "quote \" and \\ slash"',
    "multiline text": 'poem = """the owl\nflew home"""',
    "unicode": 'sova = "hú hú"\n"klíč" = ✓',
    # objects and paths
    "nested objects": "burrow { depth = 3, owls { count = 2 } }",
    "dotted paths": "burrow.depth = 3\nburrow.owls.count = 2",
    "quoted keys": '"a.b" = 1\nc { "d.e" = 2 }',
    "objects merge": "a { x = 1 }\na { y = 2 }",
    "later wins": "a = 1\na = 2",
    "object replaced": "a { x = 1 }\na = 2",
    "colon and no separator": "a : 1\nb { c : 2 }",
    "json": '{"owls": [1, 2], "night": {"dark": true}}',
    "comments": "# a comment\na = 1 // another\nb = 2",
    # lists
    "lists": "owls = [hoot, screech, 3, 4.5, true, null]",
    "nested lists": "a = [[1, 2], [3], []]",
    "objects in lists": "a = [{ x = 1 }, { y = 2 }]",
    "lists on lines": "a = [\n  1\n  2\n]",
    "list concatenation": "a = [1, 2] [3]",
    # substitutions
    "substitution": "a = 1\nb = ${a}",
    "substitution of an object": "a { x = 1 }\nb = ${a}",
    "substitution in text": 'name = owl\ngreeting = "hello "${name}" friend"',
    "optional substitution": "a = ${?nope}\nb = 1",
    "self reference append": "a = [1]\na = ${a} [2]",
    # pyhocon's += is x = ${?x} v, as its parser reads it; the spec's appends v
    # as one element, so zig_hocon.pyhocon writes it pyhocon's way
    "+= extends a list": differs("a = [1]\na += [2, 3]", "+= is the spec's, one element appended: [1, [2, 3]]; pyhocon extends the list"),
    "+= onto text": differs("a = abc\na += def\nb += def", "+= onto text is an error by the spec; pyhocon goes on after it with a space"),
    "+= onto an object": differs("a { x = 1 }\na += { y = 2 }\nb += { z = 3 }", "+= onto an object is an error by the spec; pyhocon merges"),
    "object merge by substitution": "base { x = 1 }\nfull = ${base} { y = 2 }",
    "forward reference": "b = ${a}\na = 7",
    "text concatenation": "a = owl\nb = ${a} hoots",
    "number then text": "a = 1 owl\nb = 2.5 owls fly",
    # durations
    "durations": differs("a = 30s\nb = 10 weeks\nc = 3m\nd = 114 ms\ne = 1140000 ns", "a duration is its text by the spec; pyhocon makes one of it unquoted"),
    "months and years": differs("a = 3mo\nb = 2 year", "a duration is its text by the spec; pyhocon makes one of it unquoted"),
    "durations in lists": differs("a = [4 h, 5 ms]", "a duration is its text by the spec; pyhocon makes one of it unquoted"),
    "not durations": "a = 1.5 s\nb = -3 s\nc = 3 monthsx\nd = 5x",
    # errors in both, of their own classes
    "unclosed list": "a = [1, 2",
    "unclosed object": "a { b = 1",
    "missing substitution": "a = ${nope}",
    "substitution cycle": "a = ${b}\nb = ${a}",
    # what the spec reads otherwise
    "+= in an object": differs("a { b { x = [1] } }\na { b { x += [2] } }", "pyhocon loses what x was in a nested object, [2]; here it is [1, 2]"),
    "quoted duration": 'a = "30s"',
    "quoted leading zero": 'zip = "01234"',
    "optional substitution then text": differs("a = ${?nope} 4", 'by the spec it is the text " 4", pyhocon the number 4'),
    "duration then text": differs("a = 5 ms foo", "pyhocon makes '0:00:00.005000foo' of it"),
    "bool then text": differs("a = true love", "pyhocon makes 'Truelove' of it; by the spec it is 'true love'"),
}


def _parse(module, text):
    try:
        return module.ConfigFactory.parse_string(text)
    except Exception:
        return "error"  # pyhocon raises pyparsing's classes, MIGRATING.md has it


def _typed(value):
    """``value`` with the type of each part, as == alone lets 1 == 1.0 == True."""
    if isinstance(value, dict):
        return {k: _typed(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_typed(v) for v in value]
    for t in (bool, int, float, str, datetime.timedelta, relativedelta, type(None)):
        if isinstance(value, t):
            return (t.__name__, value)
    return (type(value).__name__, value)


@pytest.mark.parametrize("text", CASES.values(), ids=CASES.keys())
def test_same_as_pyhocon(text):
    want, got = _parse(pyhocon, text), _parse(compat, text)
    assert _typed(got) == _typed(want)
    if isinstance(want, str):
        return
    for fmt in ["json", "hocon", "yaml", "properties"]:
        assert compat.HOCONConverter.convert(got, fmt) == pyhocon.HOCONConverter.convert(want, fmt), fmt


# What a review found the type guessing broke: a text stays the text pyhocon
# gives, from an environment variable or in quotes, also through with_fallback(),
# and a value put() in keeps its type.
def test_text_keeps_its_leading_zeros_and_units(monkeypatch):
    monkeypatch.setenv("AWS_ACCOUNT_ID", "012345678901")
    monkeypatch.setenv("DB_PASSWORD", "0042")
    text = 'aws.account = ${AWS_ACCOUNT_ID}\ndb.password = ${DB_PASSWORD}\nmode = "0644"\nmem = "512m"\nport = "8080"'
    want, got = pyhocon.ConfigFactory.parse_string(text), compat.ConfigFactory.parse_string(text)
    assert _typed(got) == _typed(want)
    assert got.get_string("aws.account") == "012345678901"
    for module in (pyhocon, compat):
        tree = module.ConfigFactory.parse_string("x = 1")
        tree.put("code", "00123")
        tree.put("wait", datetime.timedelta(seconds=30))
        merged = tree.with_fallback(module.ConfigFactory.parse_string("y = 2"))
        assert _typed(merged.get("code")) == ("str", "00123")
        assert _typed(merged.get("wait")) == ("timedelta", datetime.timedelta(seconds=30))


# pyhocon ✗: get_int and get_float read a number as zig_hocon's do, so a config
# reads the same here as in Zig, C or zig_hocon; pyhocon reads 0024 and -.5
# as numbers, truncates 1.5 for get_int and takes true for 1
def test_number_getters_read_as_zig_hocon():
    values = ['"5"', '"-0"', '"+5"', '" 5 "', '"5."', '"1e3"', '"2.0"', '"NaN"', "0024", "-.5", ".5", "007.5", "01e2"]
    values += ["2.0", "1e3", "1e400", "true", "[1]", "9223372036854775807", "9223372036854775808", "-9223372036854775809"]
    for value in values:
        got, want = compat.ConfigFactory.parse_string(f"a = {value}"), zig_hocon.ConfigFactory.parse_string(f"a = {value}")
        for getter in ("get_int", "get_float"):
            results = []
            for read in (getattr(got, getter), getattr(want, getter)):
                try:
                    results.append(_typed(read("a")))
                except zig_hocon.ConfigWrongTypeException as e:
                    results.append(e.name)
            assert results[0] == results[1], (value, getter, results)
