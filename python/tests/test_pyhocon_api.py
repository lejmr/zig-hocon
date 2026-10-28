"""zig_hocon.pyhocon: pyhocon 0.3.63's API over libhocon. Each group says
where it differs from pyhocon; pyhocon ✓ is the same result, checked
against pyhocon 0.3.63 itself."""

import contextlib
import copy
import datetime
import errno
import logging
import pathlib
import pickle
import sys
from collections import OrderedDict

import pytest
from dateutil.relativedelta import relativedelta

import zig_hocon.pyhocon as pyhocon
from zig_hocon.pyhocon import (
    ConfigException,
    ConfigFactory,
    ConfigList,
    ConfigMissingException,
    ConfigParser,
    ConfigSubstitutionException,
    ConfigTree,
    ConfigWrongTypeException,
    HOCONConverter,
    UndefinedKey,
)
from zig_hocon.pyhocon import config_parser, config_tree, converter, exceptions, period_parser, period_serializer, tool
from zig_hocon.pyhocon.config_parser import (
    MANDATORY_SUBSTITUTION,
    NO_SUBSTITUTION,
    STR_SUBSTITUTION,
    IncludeNotFoundError,
)
from zig_hocon.pyhocon.config_tree import NoneValue

DOC = """
db { host = burrow.example.org, port = 5432, "pool.size" = 4 }
owls = [hoot, screech]
night = true
quiet = null
ratio = 0.75
"""


def conf(text=DOC, **kw):
    return ConfigFactory.parse_string(text, **kw)


# pyhocon ✓: the same names in the same modules
def test_the_modules_are_pyhocon_s():
    for name in [
        "ConfigFactory",
        "ConfigParser",
        "ConfigTree",
        "ConfigList",
        "UndefinedKey",
        "HOCONConverter",
        "ConfigInclude",
        "ConfigSubstitution",
        "ConfigUnquotedString",
        "ConfigValues",
        "ConfigException",
        "ConfigMissingException",
        "ConfigWrongTypeException",
        "ConfigSubstitutionException",
    ]:
        assert hasattr(pyhocon, name)
    assert config_parser.ConfigFactory is ConfigFactory
    assert config_tree.ConfigTree is ConfigTree
    assert converter.HOCONConverter is HOCONConverter is tool.HOCONConverter
    # one except catches either module's
    import zig_hocon

    assert exceptions.ConfigException is zig_hocon.ConfigException


# pyhocon ✓
def test_a_document_is_an_ordered_dict():
    c = conf()
    assert isinstance(c, OrderedDict) and c.root
    assert list(c) == ["db", "owls", "night", "quiet", "ratio"]
    assert c["db"] == {"host": "burrow.example.org", "port": 5432, '"pool.size"': 4}
    assert isinstance(c["db"], ConfigTree) and not c["db"].root


# pyhocon ✓
def test_get_by_path():
    c = conf()
    assert c.get("db.host") == "burrow.example.org"
    assert c["db.port"] == 5432
    assert c.db.port == 5432
    assert c.get('db."pool.size"') == 4
    assert c.get("quiet") is None
    assert c.get("nope", "a default owl") == "a default owl"
    # a list is a copy
    c.get("owls").append("squawk")
    assert c.get("owls") == ["hoot", "screech"]


# pyhocon ✓: the messages too
def test_get_what_is_not_there():
    c = conf()
    with pytest.raises(ConfigMissingException, match="No configuration setting found for key db.user"):
        c.get("db.user")
    with pytest.raises(ConfigWrongTypeException, match="night has type bool rather than dict"):
        c.get("night.owl")
    assert c.get("night.owl", 7) == 7
    with pytest.raises(AttributeError):
        c.nope
    with pytest.raises(AttributeError):
        c.__nope__


# pyhocon ✓
def test_contains():
    c = conf()
    assert "db.host" in c and "quiet" in c
    assert "db.user" not in c and "night.owl" not in c and 5 not in c


# pyhocon ✓
@pytest.mark.parametrize(
    "path, want",
    [("a.b.c", ["a", "b", "c"]), ('a."b.c"', ["a", '"b.c"']), ('"a"', ["a"]), ('a.b."c"', ["a", "b", "c"]), ("a b.c", ["a b", "c"])],
)
def test_parse_key(path, want):
    assert ConfigTree.parse_key(path) == want


# pyhocon ✓ (get_int truncates 1.5, a default goes through the conversion)
@pytest.mark.parametrize(
    "method, path, want",
    [
        ("get_string", "night", "true"),
        ("get_string", "db.port", "5432"),
        ("get_string", "quiet", None),
        ("get_int", "db.port", 5432),
        ("get_int", "ratio", 0),
        ("get_int", "quiet", None),
        ("get_float", "ratio", 0.75),
        ("get_float", "quiet", None),
        ("get_bool", "night", True),
        ("get_bool", "quiet", None),
        ("get_list", "owls", ["hoot", "screech"]),
        ("get_list", "quiet", None),
        ("get_config", "db", {"host": "burrow.example.org", "port": 5432, '"pool.size"': 4}),
        ("get_config", "quiet", None),
    ],
)
def test_getters(method, path, want):
    assert getattr(conf(), method)(path) == want


def test_getters_from_text_and_defaults():
    c = conf('a = "5"\nb = "1.5"\nc = yes\nd = OFF\ne = maybe')
    assert c.get_int("a") == 5 and c.get_float("b") == 1.5
    assert c.get_bool("c") is True and c.get_bool("d") is False
    assert c.get_string("nope", 5) == "5"
    assert c.get_bool("nope", False) is False


@pytest.mark.parametrize(
    "method, path, message",
    [
        ("get_int", "e", "e has type 'str' rather than 'int'"),
        ("get_int", "f", "f has type 'list' rather than 'int'"),
        ("get_float", "e", "e has type 'str' rather than 'float'"),
        ("get_bool", "e", "e does not translate to a Boolean value"),
        ("get_list", "e", "e has type 'str' rather than 'list'"),
        ("get_config", "e", "e has type 'str' rather than 'config'"),
    ],
)
def test_getters_refuse(method, path, message):
    with pytest.raises(ConfigException, match=message):
        getattr(conf("e = maybe\nf = [1]"), method)(path)


# pyhocon ✗: an object with whole-number keys is a list by the spec, in the
# order of the numbers and the other keys left out; pyhocon sorts them as
# text and refuses any other key
def test_get_list_of_numbered_keys():
    c = conf('a { "10" = ten, "2" = two, x = skipped }\nb {}\nc { x = 1 }')
    assert c.get_list("a") == ["two", "ten"]
    for path in ("b", "c"):
        with pytest.raises(ConfigException, match="does not translate to a list"):
            c.get_list(path)


# pyhocon ✓
def test_put():
    c = conf()
    c.put("db.user", "night shift")
    c.put("night.owl", "hoot")  # through a scalar: an object in its place
    c.put("owls", ["squawk"], append=True)
    c.put("new", ["first"], append=True)
    c.put("quiet", NoneValue())
    assert c.get("db.user") == "night shift"
    assert c.get("night") == {"owl": "hoot"}
    assert c.get("owls") == ["hoot", "screech", "squawk"]
    assert c.get("new") == ["first"]
    assert list(c.items())[3] == ("quiet", None)
    with pytest.raises(ConfigWrongTypeException, match="Cannot concatenate the list ratio"):
        c.put("ratio", [1], append=True)


# pyhocon ✓: an object put on an object merges; at the root into a new one,
# so a tree taken before stays as it was
def test_put_merges_objects():
    c = conf()
    before = c["db"]
    c.put("db", ConfigFactory.from_dict({"port": 6543, "tls": True}))
    assert c["db"] == {"host": "burrow.example.org", "port": 6543, '"pool.size"': 4, "tls": True}
    assert before["port"] == 5432
    inner = conf("a { b { c = 1 } }")
    kept = inner.get("a.b")
    inner.put("a.b", ConfigFactory.from_dict({"d": 2}))
    assert kept == {"c": 1, "d": 2}


# pyhocon ✓
def test_pop():
    c = conf()
    assert c.pop("db.port") == 5432
    assert "db.port" not in c
    assert c.pop("owls") == ["hoot", "screech"]
    assert c.pop("nope", "a default owl") == "a default owl"
    with pytest.raises(ConfigMissingException):
        c.pop("nope")


# pyhocon ✓
@pytest.mark.parametrize("copy_trees", [False, True])
def test_merge_configs(copy_trees):
    a = conf("x { y = 1, z = 2 }\nw = 1")
    inner = a["x"]
    merged = ConfigTree.merge_configs(a, conf("x { z = 3 }\nw { v = 1 }"), copy_trees=copy_trees)
    assert merged is a
    assert a == {"x": {"y": 1, "z": 3}, "w": {"v": 1}}
    assert (inner["z"] == 2) is copy_trees


# pyhocon ✓
def test_as_plain_ordered_dict():
    plain = conf('a { "b.c" = [1, { d = 2 }] }').as_plain_ordered_dict()
    assert plain == OrderedDict([("a", OrderedDict([("b.c", [1, OrderedDict([("d", 2)])])]))])
    assert type(plain["a"]["b.c"][1]) is OrderedDict


# pyhocon ✓
def test_copies():
    c = conf()
    for other in (copy.deepcopy(c), c.copy(), pickle.loads(pickle.dumps(c))):
        assert other == c


# pyhocon ✓: the fallback's keys first, as two files one after the other
def test_with_fallback():
    c = conf('db.port = 6543\nurl = ${db.host}":"${db.port}', resolve=False)
    merged = c.with_fallback(conf())
    assert merged.get("url") == "burrow.example.org:6543"
    assert list(merged)[0] == "db"
    assert merged.get("db") == {"host": "burrow.example.org", "port": 6543, '"pool.size"': 4}


def test_with_fallback_a_file(tmp_path):
    (tmp_path / "defaults.conf").write_text("night = false\nmoon = full")
    merged = conf().with_fallback(str(tmp_path / "defaults.conf"))
    assert merged["night"] is True and merged["moon"] == "full"


def test_with_fallback_unresolved():
    merged = conf("a = ${b}", resolve=False).with_fallback(conf("c = 1"), resolve=False)
    with pytest.raises(ConfigSubstitutionException):
        merged.get("a")
    assert ConfigParser.resolve_substitutions(merged, accept_unresolved=True) is True


def test_with_fallback_of_put_values():
    c = ConfigTree()
    c.put("wait", datetime.timedelta(seconds=2))
    assert c.with_fallback(ConfigTree()).get("wait") == datetime.timedelta(seconds=2)
    # resolved trees merge as they are, as in pyhocon: any value stays
    c.put("owl", object())
    assert type(c.with_fallback(ConfigTree()).get("owl")) is object


# pyhocon ✗ unquoted, ✓ quoted: a duration is its text, as the spec reads it;
# zig_hocon.parse_duration converts one. pyhocon makes a relativedelta of the
# unquoted ones. Guessing that here, from libhocon's JSON, where quoted and
# unquoted look the same, made "512m" from a variable 512 minutes.
@pytest.mark.parametrize(
    "text, value",
    [
        ("30s", "30s"),
        ("10 weeks", "10 weeks"),
        ("3m", "3m"),
        ("3mo", "3mo"),
        ("2 year", "2 year"),
        ("1140000 ns", "1140000 ns"),
        ("114 ms", "114 ms"),
        ("5  seconds", "5  seconds"),
        ("[4 h, 5 ms]", ["4 h", "5 ms"]),
        ("{ x = 2 h }", {"x": "2 h"}),
        ("1.5 s", "1.5 s"),
        ("-3 s", "-3 s"),
        ("3 monthsx", "3 monthsx"),
        ("5 ms foo", "5 ms foo"),
        ('"30s"', "30s"),
    ],
)
def test_durations(text, value):
    assert conf("a = " + text)["a"] == value


# pyhocon ✓: without dateutil period_parser gives a timedelta, and months and
# years are no duration
def test_durations_without_dateutil(monkeypatch):
    monkeypatch.setattr(period_parser, "relativedelta", None)
    assert type(period_parser.parse_period("30s")) is datetime.timedelta
    assert period_parser.parse_period("1 d") == datetime.timedelta(days=1)
    with pytest.raises(ValueError):
        period_parser.parse_period("3mo")


# pyhocon ✓: with_fallback() merges resolved trees as they are, as pyhocon
# does, so what put() put in keeps its type, a relativedelta of months and days
# too, and a duration read from the text stays its text
def test_durations_through_with_fallback():
    c = conf("a = 3mo\nb = 30s")
    c.put("e", datetime.timedelta(microseconds=7))
    c.put("f", relativedelta(months=1, days=2))
    merged = c.with_fallback(ConfigTree())
    assert merged == {"a": "3mo", "b": "30s", "e": datetime.timedelta(microseconds=7), "f": relativedelta(months=1, days=2)}


# pyhocon ✓: period_parser and period_serializer, as pyhocon has them;
# pyhocon ⚠️: parse_period of no duration is a ValueError, not pyparsing's
def test_period_modules():
    assert period_parser.period(3, "minutes") == relativedelta(minutes=3)
    assert period_parser.period(5, "milliseconds") == datetime.timedelta(milliseconds=5)
    assert period_parser.parse_period("10 weeks") == relativedelta(days=70)
    assert period_parser.parse_period("1140000 ns") == relativedelta(microseconds=1140)
    with pytest.raises(ValueError, match="'owl' is not a duration"):
        period_parser.parse_period("owl")
    assert period_serializer.relative_delta_to_timedelta(relativedelta(hours=1, months=2)) == datetime.timedelta(hours=1)
    assert period_serializer.is_timedelta_like(relativedelta(days=1)) and not period_serializer.is_timedelta_like(1)


# pyhocon ✓: checked against pyhocon 0.3.63's output
def test_relativedeltas_converted():
    c = ConfigTree()
    for key, value in [
        ("a", relativedelta(hours=7)),
        ("b", relativedelta(minutes=3)),
        ("c", relativedelta(days=12)),
        ("d", relativedelta(months=3)),
        ("e", relativedelta(microseconds=112)),
    ]:
        c.put(key, value)
    assert HOCONConverter.to_hocon(c) == "a = 7 hours\nb = 3 minutes\nc = 12 days\nd = 0 seconds\ne = 112 microseconds"
    assert HOCONConverter.to_json(c) == '{\n  "a": 25200000,\n  "b": 180000,\n  "c": 1036800000,\n  "d": 0,\n  "e": 0\n}'


# pyhocon ⚠️: a value with a ${…} is no ConfigValues here; a document that
# resolves alone has its values, one that does not has none until resolved
def test_resolve_false():
    alone = conf("a = 1\nb = ${a}", resolve=False)
    assert alone == {"a": 1, "b": 1}
    waiting = conf("a = ${nope}", resolve=False)
    assert waiting == {}
    for read in (lambda: waiting.get("a"), lambda: waiting.a, lambda: "a" in waiting, waiting.as_plain_ordered_dict):
        with pytest.raises(ConfigSubstitutionException, match="read with resolve=False"):
            read()


def test_resolve_substitutions():
    c = conf("a = ${b}", resolve=False)
    with pytest.raises(ConfigSubstitutionException):
        ConfigParser.resolve_substitutions(c)
    assert ConfigParser.resolve_substitutions(c, accept_unresolved=True) is True
    merged = ConfigTree.merge_configs(c, conf("b = owl", resolve=False))
    assert merged is c
    assert ConfigParser.resolve_substitutions(c) is False
    assert c == {"a": "owl", "b": "owl"}
    assert ConfigParser.resolve_substitutions(c) is False


def test_unresolved_value():
    assert conf("a = ${nope}", unresolved_value=NO_SUBSTITUTION) == {}
    assert conf("a = 1", unresolved_value=MANDATORY_SUBSTITUTION) == {"a": 1}
    with pytest.raises(NotImplementedError):
        conf("a = ${nope}", unresolved_value=STR_SUBSTITUTION)


# pyhocon ✓: positional arguments, includes from the working directory
def test_parse_string_includes_from_the_working_directory(tmp_path, monkeypatch):
    (tmp_path / "inc.conf").write_text("moon = full")
    monkeypatch.chdir(tmp_path)
    assert ConfigFactory.parse_string('include "inc.conf"\nnight = true') == {"moon": "full", "night": True}
    sub = tmp_path / "sub"
    sub.mkdir()
    (sub / "inc.conf").write_text("moon = new")
    assert ConfigFactory.parse_string('include "inc.conf"', str(sub), True) == {"moon": "new"}
    assert ConfigParser.parse('include "inc.conf"', str(sub)) == {"moon": "new"}


# pyhocon ✓
def test_a_document_that_is_a_list():
    c = conf("[1, 2]")
    assert isinstance(c, ConfigList) and c == [1, 2]


# pyhocon ✓: the classes pyhocon raises
def test_errors_in_pyhocon_s_classes():
    with pytest.raises(ConfigWrongTypeException) as e:
        conf("a = [1] owl")
    assert e.value.name == "UnsupportedConcatenation" and e.value.line == 1
    with pytest.raises(IncludeNotFoundError) as e:
        conf('include required("/nowhere/owl.conf")')
    assert isinstance(e.value, FileNotFoundError) and isinstance(e.value, ConfigException)
    assert e.value.name == "IncludeNotFound" and "IncludeNotFound" in str(e.value)
    # the others as zig_hocon raises them
    with pytest.raises(exceptions.ConfigSubstitutionException) as e:
        conf("x = ${nope}")
    assert type(e.value) is exceptions.ConfigSubstitutionException


# pyhocon ✓: a syntax error is pyparsing's ParseException and
# ParseSyntaxException too, with pyparsing installed, as pyhocon raises it
def test_syntax_errors_are_pyparsing_s():
    pp = pytest.importorskip("pyparsing")
    with pytest.raises(pp.ParseException) as e:
        conf("a = {\n  b = [1,")
    err = e.value
    assert isinstance(err, pp.ParseSyntaxException) and isinstance(err, exceptions.ConfigParseException)
    assert type(err).__name__ == "ConfigParseException" and err.name == "UnexpectedToken"
    assert (err.line, err.column) == (err.lineno, err.col) == (2, 10)
    assert str(err).startswith("2:10: UnexpectedToken") and err.msg == str(err)


def test_syntax_errors_without_pyparsing(monkeypatch):
    monkeypatch.setitem(sys.modules, "pyparsing", None)
    config_parser._syntax_error.cache_clear()
    try:
        with pytest.raises(exceptions.ConfigParseException) as e:
            conf("a = {")
        assert type(e.value) is exceptions.ConfigParseException
    finally:
        config_parser._syntax_error.cache_clear()


def test_parse_file(tmp_path, caplog):
    path = tmp_path / "app.conf"
    path.write_text('include "inc.conf"\nowl = "hoot"')
    (tmp_path / "inc.conf").write_text("moon = full")
    assert ConfigFactory.parse_file(path) == {"moon": "full", "owl": "hoot"}
    (tmp_path / "bad.conf").write_text("a = {")
    with pytest.raises(exceptions.ConfigParseException, match="bad.conf:1"):
        ConfigFactory.parse_file(str(tmp_path / "bad.conf"))
    # another encoding, its includes still next to it
    latin = tmp_path / "latin.conf"
    latin.write_bytes('include "inc.conf"\nowl = "hibou café"'.encode("latin-1"))
    assert ConfigFactory.parse_file(latin, "latin-1") == {"moon": "full", "owl": "hibou café"}
    with pytest.raises(FileNotFoundError):
        ConfigFactory.parse_file(tmp_path / "nope.conf")
    with caplog.at_level(logging.WARNING):
        assert ConfigFactory.parse_file(tmp_path / "nope.conf", required=False) == []
    assert "Cannot include file" in caplog.text


def test_parse_file_resolve_false(tmp_path):
    path = tmp_path / "app.conf"
    path.write_text("a = ${b}")
    c = ConfigFactory.parse_file(path, resolve=False)
    assert c.with_fallback(conf("b = 1")) == {"b": 1, "a": 1}


def test_parse_url(tmp_path, caplog):
    path = tmp_path / "remote.conf"
    path.write_text("owl = hoot")
    assert ConfigFactory.parse_URL(path.as_uri()) == {"owl": "hoot"}
    assert ConfigFactory.parse_URL(path.as_uri(), 5, False, True) == {"owl": "hoot"}
    with caplog.at_level(logging.WARNING):
        assert ConfigFactory.parse_URL("http://127.0.0.1:1/owl.conf", timeout=1) == []
    assert "Cannot include url" in caplog.text
    with pytest.raises(OSError):
        ConfigFactory.parse_URL("http://127.0.0.1:1/owl.conf", timeout=1, required=True)


# pyhocon ✓
def test_from_dict():
    c = ConfigFactory.from_dict({"a.b": 1, "c": [{"d": 2}, 3]}, root=True)
    assert c == {"a": {"b": 1}, "c": [{"d": 2}, 3]}
    assert c.root and isinstance(c["c"][0], ConfigTree)
    assert c.get("a.b") == 1


def test_resolve_package_path():
    assert pathlib.Path(ConfigParser.resolve_package_path("zig_hocon:pyhocon/__init__.py")) == pathlib.Path(pyhocon.__file__)
    with pytest.raises(ValueError, match="PACKAGE:PATH"):
        ConfigParser.resolve_package_path("zig_hocon")
    for missing in ("no_such_owl_package:x.conf", "zig_hocon.units:x.conf"):
        with pytest.raises(ImportError):
            ConfigParser.resolve_package_path(missing)


def test_undefined_key_is_the_default():
    assert ConfigTree.get.__defaults__ == (UndefinedKey,)


CONVERT = conf('''
a = {b: 1}
b = [1, 2, {x = []}, null]
d = placeholder
e = """1
    2"""
f1 = true
f2 = false
h = null
i = {}
"a.b" = 2
j { k { l = 1 } }
m = "x=y!#"
''')
CONVERT.put("d", 'a\tq"x\x01')


# pyhocon ✓: each checked against pyhocon 0.3.63's output to the character
def test_to_json():
    assert HOCONConverter.to_json(CONVERT) == (
        '{\n  "a": {\n    "b": 1\n  },\n  "b": [\n    1,\n    2,\n    {\n      "x": []\n    },\n    null\n  ],\n'
        '  "d": "a\\tq\\"x\\u0001",\n  "e": "1\\n    2",\n  "f1": true,\n  "f2": false,\n  "h": null,\n  "i": {},\n'
        '  "a.b": 2,\n  "j": {\n    "k": {\n      "l": 1\n    }\n  },\n  "m": "x=y!#"\n}'
    )
    assert HOCONConverter.to_json(conf("a = []"), indent=4) == '{\n    "a": []\n}'


def test_to_hocon():
    assert HOCONConverter.to_hocon(CONVERT) == (
        'a {\n  b = 1\n}\nb = [\n  1\n  2\n  {\n    x = []\n  }\n  null\n]\nd = "a\\tq\\"x\\u0001"\ne = """1\n    2"""\n'
        'f1 = true\nf2 = false\nh = null\ni {}\n"a.b" = 2\nj {\n  k {\n    l = 1\n  }\n}\nm = "x=y!#"'
    )
    assert HOCONConverter.to_hocon(conf("j { k { l = 1 } }\nm = 1"), compact=True) == "j.k.l = 1\nm = 1"
    assert HOCONConverter.to_hocon(ConfigTree()) == "{}"


def test_to_yaml():
    assert HOCONConverter.to_yaml(CONVERT) == (
        'a: \n  b: 1\nb: \n  - 1\n  - 2\n  - \n    x: []\nd: a\tq"x\x01\ne: |\n 1\n    2\nf1: true\nf2: false\nh: null\n'
        "i: \na.b: 2\nj: \n  k: \n    l: 1\nm: x=y!#"
    )


def test_to_properties():
    assert HOCONConverter.to_properties(CONVERT) == (
        'a.b = 1\nb.0 = 1\nb.1 = 2\nd = a\tq"x\x01\ne = 1\\\n    2\nf1 = true\nf2 = false\na.b = 2\nj.k.l = 1\nm = x\\=y\\!\\#'
    )
    assert HOCONConverter.to_properties(None) == ""


@pytest.mark.parametrize(
    "td, hocon",
    [
        (datetime.timedelta(days=2), "2 days"),
        (datetime.timedelta(seconds=3), "3 seconds"),
        (datetime.timedelta(microseconds=4), "4 microseconds"),
        (datetime.timedelta(0), "0 seconds"),
    ],
)
def test_timedeltas_put_in_a_tree(td, hocon):
    c = ConfigTree()
    c.put("wait", td)
    ms = str(int(td.total_seconds() * 1000))
    assert HOCONConverter.to_hocon(c) == f"wait = {hocon}"
    assert HOCONConverter.to_json(c) == f'{{\n  "wait": {ms}\n}}'
    assert HOCONConverter.to_yaml(c) == f"wait: {ms}"
    assert HOCONConverter.to_properties(c) == f"wait = {ms}"


def test_convert():
    c = conf("a = 1")
    assert HOCONConverter.convert(c, "json") == '{\n  "a": 1\n}'
    assert HOCONConverter.convert(c, "properties") == "a = 1"
    assert HOCONConverter.convert(c, "yaml") == "a: 1"
    assert HOCONConverter.convert(c, "hocon") == "a = 1"
    with pytest.raises(Exception, match="Invalid format 'toml'"):
        HOCONConverter.convert(c, "toml")


def test_convert_from_file(tmp_path, monkeypatch, capsys):
    (tmp_path / "in.conf").write_text("owl = hoot")
    HOCONConverter.convert_from_file(str(tmp_path / "in.conf"), str(tmp_path / "out.yaml"), "yaml")
    assert (tmp_path / "out.yaml").read_text() == "owl: hoot"
    monkeypatch.setattr(sys, "stdin", __import__("io").StringIO("owl = screech"))
    HOCONConverter.convert_from_file()
    assert capsys.readouterr().out == '{\n  "owl": "screech"\n}\n'


@pytest.mark.parametrize("verbosity", [[], ["-v"], ["-vv"], ["-vvv"]])
def test_tool(tmp_path, verbosity):
    (tmp_path / "in.conf").write_text("a { b = 1 }")
    root = logging.getLogger()
    handlers, level = list(root.handlers), root.level
    try:
        tool.main(["-i", str(tmp_path / "in.conf"), "-o", str(tmp_path / "out"), "-f", "HOCON", "-c", "-n", "4", *verbosity])
    finally:
        root.handlers[:], root.level = handlers, level
    assert (tmp_path / "out").read_text() == "a.b = 1"


# pyhocon ✗: += is the spec's, x = ${?x} [v], one element appended, where
# pyhocon extends a list, goes on after text and merges an object (those two
# an error here). Since the rewrite of pyhocon's syntax is gone (MIGRATING.md).
@pytest.mark.parametrize(
    "text, want",
    [
        ("x = [1, 2]\nx += [3, 4]", {"x": [1, 2, [3, 4]]}),
        ("x += [1]", {"x": [[1]]}),
        ("x = abc\nx += def", ConfigWrongTypeException),
        ("x += def", {"x": ["def"]}),
        ("x { a = 1 }\nx += { b = 2 }", ConfigWrongTypeException),
        ("a { b { x = [1] } }\na { b { x += [2] } }", {"a": {"b": {"x": [1, [2]]}}}),
        ('{ "q.k" = [1], "q.k" += [2] }', {'"q.k"': [1, [2]]}),
        ("a = ${?nope} { x = [1], x += [2] }", {"a": {"x": [1, [2]]}}),
        ('s = """x += [1]"""\nk += [2] # k += [3]', {"s": "x += [1]", "k": [[2]]}),
        ("n = 1e+5\nx = [1] // x += [9]\nx += [2]", {"n": 1e5, "x": [1, [2]]}),
        ("l = [{ x = [1], x += [2] }]", {"l": [{"x": [1, [2]]}]}),
        ("l = [[1], {}, 2]\nx += [1]", {"l": [[1], {}, 2], "x": [[1]]}),
        # a number, a boolean or null is appended; pyhocon puts it in place of the list
        ("x = [1]\nx += 2\ny += true", {"x": [1, 2], "y": [True]}),
        ("a\n{ b = 1 }\nx = [1]\nx += [2]", {"a": {"b": 1}, "x": [1, [2]]}),
        ('"a}b" = 1\nc = ${"a}b"}\nx = [1]\nx += [2]', {'"a}b"': 1, "c": 1, "x": [1, [2]]}),
        # an include in a list is text, by the spec
        ('l = [include "http://example.invalid/x.conf"]\nx = [1]\nx += [2]', {"l": ["include http://example.invalid/x.conf"], "x": [1, [2]]}),
    ],
)
def test_plus_equals_is_the_spec_s(text, want):
    if isinstance(want, type):
        with pytest.raises(want):
            conf(text)
    else:
        assert conf(text) == want


def test_plus_equals_unresolved_with_fallback():
    c = conf("x += [3]", resolve=False).with_fallback(conf("x = [1, 2]"))
    assert c == {"x": [1, 2, [3]]}


# pyhocon ✗: a backslash is forbidden in unquoted text by the spec, ``abc\"d``
# too, where pyhocon reads ``abc"d``; quote it
def test_escapes_in_unquoted_text():
    for text in ['a = abc\\"test', "a = x\\n y", "a = abc\\q", "a = ab\\n!"]:
        with pytest.raises(ConfigException):
            conf(text)


# pyhocon ✓ for package(…) and a glob; pyhocon ✗: a name without an extension
# is a basename (spec), so `include "plain"` does not include the file plain
def test_pyhocon_s_includes(tmp_path, monkeypatch):
    (tmp_path / "d").mkdir()
    (tmp_path / "d" / "a.conf").write_text("x = 1\nl = [1]")
    (tmp_path / "d" / "b.conf").write_text("y = 2\nl += [2]")
    (tmp_path / "plain").write_text("z = 3")
    pkg = tmp_path / "owl_pkg"
    pkg.mkdir()
    (pkg / "__init__.py").write_text("")
    (pkg / "nest.conf").write_text("hoot = true")
    monkeypatch.syspath_prepend(str(tmp_path))
    c = ConfigParser.parse('include "plain"\ninclude package("owl_pkg:nest.conf")', str(tmp_path))
    assert c == {"hoot": True}
    assert conf('a { include file("nowhere") }', basedir=str(tmp_path)) == {"a": {}}
    # pyhocon ✓: a glob includes each file it finds, in sorted order (pyhocon
    # in the file system's); one that finds none is a missing file, nothing,
    # and under required() a FileNotFoundError
    assert conf('include "d/*.conf"', basedir=str(tmp_path)) == {"x": 1, "l": [1, [2]], "y": 2}
    assert conf('a { include "d/*.nothing" }', basedir=str(tmp_path)) == {"a": {}}
    with pytest.raises(FileNotFoundError):
        conf('include required("d/*.nothing")', basedir=str(tmp_path))
    assert ConfigFactory.parse_file(str(tmp_path / "d" / "b.conf")) == {"y": 2, "l": [[2]]}
    (tmp_path / "top.conf").write_text('include "plain"')
    assert ConfigFactory.parse_file(str(tmp_path / "top.conf")) == {}
    # the classpath is libhocon's, and its error no syntax error
    with pytest.raises(ConfigException) as e:
        conf('include classpath("owl.conf")')
    assert type(e.value) is exceptions.ConfigParseException and e.value.name == "UnsupportedInclude"
    with pytest.raises(ImportError):
        conf('include package("no_such_owl_pkg:x.conf")')


# pyhocon ✗: an include in a list is text by the spec, which has includes in
# objects only; pyhocon gives the included list's elements
def test_includes_in_a_list(tmp_path):
    (tmp_path / "one").write_text("[1, 2]")
    (tmp_path / "sub").mkdir()
    (tmp_path / "sub" / "obj.conf").write_text('{ o = 1, include "inner" }')
    (tmp_path / "sub" / "inner").write_text("i = 2")
    (tmp_path / "sub" / "bare.conf").write_text("b = 3")
    url = (tmp_path / "one").as_uri()
    text = f'''l = [
      0, include "one"
      include file("sub/obj.conf"), include "sub/*.conf"
      include url("{url}"), include "missing"
    ]'''
    want = ["include one", "include file(sub/obj.conf)", "include sub/*.conf", f"include url({url})", "include missing"]
    assert conf(text, basedir=str(tmp_path)) == {"l": [0, *want]}
    assert conf('l = [include required("missing")]', basedir=str(tmp_path)) == {"l": ["include required(missing)"]}
    # an http include in a list is left to libhocon, as text
    assert conf('l = [include "http://example.invalid/x.conf"]') == {"l": ["include http://example.invalid/x.conf"]}


def test_rewrite_of_included_files(tmp_path):
    # a cycle of includes, a file not in UTF-8 and one the rewrite cannot
    # follow are libhocon's to read or to report
    (tmp_path / "a.conf").write_text('x += [1]\ninclude "b.conf"')
    (tmp_path / "b.conf").write_text('y += [2]\ninclude "a.conf"')
    with pytest.raises(ConfigException) as e:
        ConfigFactory.parse_file(str(tmp_path / "a.conf"))
    assert e.value.name == "IncludeCycle"
    (tmp_path / "latin.conf").write_bytes(b's = "caf\xe9"')
    (tmp_path / "odd.conf").write_text('q = """x""""\nr = [1')
    with pytest.raises(ConfigException):
        conf('x += [1]\ninclude "latin.conf"', basedir=str(tmp_path))
    with pytest.raises(ConfigException):
        conf('x += [1]\ninclude "odd.conf"', basedir=str(tmp_path))
    assert conf('l = [include "odd.conf"]', basedir=str(tmp_path)) == {"l": ["include odd.conf"]}
    (tmp_path / "quotes.conf").write_text('q = """x""""\nr += [1]')
    assert conf('include "quotes.conf"', basedir=str(tmp_path)) == {"q": 'x"', "r": [[1]]}


# pyhocon ✗: an included file is included as the spec has it: under an object
# its += and ${…} look in that object first; pyhocon gives l = [1] and z = 100
def test_included_files_are_included_by_the_spec(tmp_path):
    (tmp_path / "f.conf").write_text("y = 1\nz = ${y}\nl += [1]")
    (tmp_path / "g.conf").write_text("m += [2]")
    c = ConfigParser.parse('y = 100\nn { l = [0], include "f.conf" }\ninclude "g.conf"', str(tmp_path))
    assert c == {"y": 100, "n": {"l": [0, [1]], "y": 1, "z": 1}, "m": [[2]]}


# an error in an included file names that file, at its own line
def test_errors_in_rewritten_files(tmp_path):
    (tmp_path / "unres.conf").write_text("q = 1\nx = [1]\nx += [2]\nz = ${nope}")
    (tmp_path / "top.conf").write_text('a = 1\nb = 2\ninclude "unres.conf"')
    for name in ["top.conf", "unres.conf"]:
        with pytest.raises(ConfigSubstitutionException) as e:
            ConfigFactory.parse_file(str(tmp_path / name))
        assert e.value.file.endswith("unres.conf") and e.value.line == 4
        assert "zig_hocon-pyhocon-" not in str(e.value)
    (tmp_path / "broken.conf").write_text("x = [1]\nx += [2]\na..b = 1")
    with pytest.raises(exceptions.ConfigParseException) as e:
        conf('include "broken.conf"', basedir=str(tmp_path))
    assert e.value.file.endswith("broken.conf") and "zig_hocon-pyhocon-" not in str(e.value)
    assert getattr(e.value, "msg", str(e.value)) == str(e.value)
    (tmp_path / "two.conf").write_text('include "g1.conf"\ninclude "g2.conf"')
    (tmp_path / "g1.conf").write_text("a += [1]")
    (tmp_path / "g2.conf").write_text("b += [2]")
    assert ConfigFactory.parse_file(str(tmp_path / "two.conf")) == {"a": [[1]], "b": [[2]]}
    (tmp_path / "odd.conf").write_text('x += [1]\na = """open')
    with pytest.raises(ConfigException) as e:
        ConfigFactory.parse_file(str(tmp_path / "odd.conf"))
    assert e.value.file.endswith("odd.conf")


# pyhocon ✓: a missing required include is a FileNotFoundError with errno;
# package() of a file the package does not have is an ImportError
def test_missing_includes(tmp_path):
    with pytest.raises(FileNotFoundError) as e:
        conf('include required("nope.conf")', basedir=str(tmp_path))
    assert e.value.errno == errno.ENOENT and e.value.strerror
    with pytest.raises(ImportError, match="Can't find nope.conf in package:json"):
        conf('include package("json:nope.conf")')


# pyhocon ✗: an include in a list is text by the spec, missing file or not
def test_missing_include_in_a_list(tmp_path):
    assert conf('a = [ include "nope.conf", 1 ]', basedir=str(tmp_path)) == {"a": ["include nope.conf", 1]}
    assert conf('a = [ 1, include "nope.conf" ]', basedir=str(tmp_path)) == {"a": [1, "include nope.conf"]}


# a document from a URL has no directory: libhocon refuses an include in it
def test_parse_url_has_no_include(tmp_path):
    (tmp_path / "doc.conf").write_text("x = [1]\nx += [2]")
    assert ConfigFactory.parse_URL((tmp_path / "doc.conf").as_uri()) == {"x": [1, [2]]}
    (tmp_path / "inc.conf").write_text('include "doc.conf"\nx += [2]')
    with pytest.raises(ConfigException):
        ConfigFactory.parse_URL((tmp_path / "inc.conf").as_uri())


# pyhocon ✓: include package("pkg:file.conf") is the file in the installed
# package, also required(…), in a string and in a file. A package or a file it
# does not have is an ImportError, as in pyhocon.
def test_package_includes(tmp_path, monkeypatch):
    pkg = tmp_path / "owl_pkg"
    pkg.mkdir()
    (pkg / "__init__.py").write_text("")
    (pkg / "nest.conf").write_text("hoot = true")
    monkeypatch.syspath_prepend(str(tmp_path))
    assert conf('include package("owl_pkg:nest.conf")\nz = 3') == {"hoot": True, "z": 3}
    (tmp_path / "top.conf").write_text('include required(package("owl_pkg:nest.conf"))')
    assert ConfigFactory.parse_file(str(tmp_path / "top.conf")) == {"hoot": True}
    with pytest.raises(ImportError):
        conf('include package("no_such_owl_pkg:x.conf")')
    # the classpath is libhocon's, and its error no syntax error
    with pytest.raises(ConfigException) as e:
        conf('include classpath("owl.conf")')
    assert type(e.value) is exceptions.ConfigParseException and e.value.name == "UnsupportedInclude"
