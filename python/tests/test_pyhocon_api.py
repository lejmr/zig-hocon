"""zig_hocon.pyhocon: pyhocon 0.3.63's API over libhocon. Each group says
where it differs from pyhocon; pyhocon ✓ is the same result, checked
against pyhocon 0.3.63 itself."""

import copy
import datetime
import logging
import pathlib
import pickle
import sys
from collections import OrderedDict

import pytest

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
from zig_hocon.pyhocon import config_parser, config_tree, converter, exceptions, tool
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
    for name in ["ConfigFactory", "ConfigParser", "ConfigTree", "ConfigList", "UndefinedKey", "HOCONConverter", "ConfigInclude",
                 "ConfigSubstitution", "ConfigUnquotedString", "ConfigValues", "ConfigException", "ConfigMissingException",
                 "ConfigWrongTypeException", "ConfigSubstitutionException"]:
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
    c = conf("db.port = 6543\nurl = ${db.host}\":\"${db.port}", resolve=False)
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
    assert c.with_fallback(ConfigTree()).get("wait") == 2000
    c.put("owl", object())
    with pytest.raises(TypeError, match="object is not a HOCON value"):
        c.with_fallback(ConfigTree())


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
    with pytest.raises(exceptions.ConfigParseException) as e:
        conf("a = {")
    assert type(e.value) is exceptions.ConfigParseException


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
