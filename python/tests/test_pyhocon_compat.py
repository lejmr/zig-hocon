"""zig_hocon.pyhocon against pyhocon itself, the newest release: each document read by
both, the values and their types the same, and HOCONConverter's output to the
character. Where they differ by design the case is an xfail that says why,
strict, so a difference that goes away shows."""

import datetime

import pytest

pyhocon = pytest.importorskip("pyhocon")
relativedelta = pytest.importorskip("dateutil.relativedelta").relativedelta

import zig_hocon.pyhocon as compat  # noqa: E402


def differs(text, why):
    return pytest.param(text, marks=pytest.mark.xfail(strict=True, reason=why))


CASES = {
    # scalars
    "numbers": "a = 1\nb = -2\nc = 2.5\nd = 1e3\ne = 0.75",
    "bools and null": "a = true\nb = false\nc = null\nd = yes",
    "unquoted text": "owl = the owl hoots at midnight",
    "quoted text": 'owl = "hoot, hoot"\nempty = ""',
    "escapes": r'a = "tab\there"' + "\n" + r'b = "quote \" and \\ slash"',
    "multiline text": 'poem = """the owl\nflew home"""',
    "unicode": "sova = \"hú hú\"\n\"klíč\" = ✓",
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
    "object merge by substitution": "base { x = 1 }\nfull = ${base} { y = 2 }",
    "forward reference": "b = ${a}\na = 7",
    "text concatenation": "a = owl\nb = ${a} hoots",
    "number then text": "a = 1 owl\nb = 2.5 owls fly",
    # durations
    "durations": "a = 30s\nb = 10 weeks\nc = 3m\nd = 114 ms\ne = 1140000 ns",
    "months and years": "a = 3mo\nb = 2 year",
    "durations in lists": "a = [4 h, 5 ms]",
    "not durations": "a = 1.5 s\nb = -3 s\nc = 3 monthsx\nd = 5x",
    # errors in both, of their own classes
    "unclosed list": "a = [1, 2",
    "unclosed object": "a { b = 1",
    "missing substitution": "a = ${nope}",
    "substitution cycle": "a = ${b}\nb = ${a}",
    # what the spec reads otherwise
    "quoted duration": differs('a = "30s"', 'a quoted "30s" is a duration here too: libhocon\'s JSON has no quotes left'),
    "+= appends one element": differs("a = [1]\na += [2, 3]", "by the spec += appends the list as one element"),
    "-Xmx unquoted": differs("opts = [-Xmx1g]", "by the spec an unquoted string does not start with -"),
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
