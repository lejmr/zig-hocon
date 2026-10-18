"""Files on disk, as a service reads its configuration: shared defaults at the
bottom, a leaf per environment on top, includes, overrides, `+=`, variables —
in every mode of `env` and `resolve` — and errors with their place."""

import pytest

from zig_hocon import (
    KEEP,
    ConfigException,
    ConfigFactory,
    ConfigParseException,
    ConfigSubstitutionException,
    ConfigWrongTypeException,
)

DEFAULTS = """\
app {
  name = grumpy wombat
  port = 8080
  timeout = 30s
  cache = 512MB
  plugins = [auth]
  db { host = localhost, pool = 4 }
}
"""

PROD = """\
include "../defaults.conf"
app.port = 443
app.port = ${?PORT}
app.plugins += metrics
app.db.host = ${DB_HOST}
app.url = "https://"${app.db.host}":"${app.port}"/burrow"
"""

STAGING = """\
include "../defaults.conf"
app {
  name = sleepy wombat
  db.pool = 1
}
"""


@pytest.fixture
def conf_dir(tmp_path):
    (tmp_path / "prod").mkdir()
    (tmp_path / "staging").mkdir()
    (tmp_path / "defaults.conf").write_text(DEFAULTS)
    (tmp_path / "prod" / "app.conf").write_text(PROD)
    (tmp_path / "staging" / "app.conf").write_text(STAGING)
    return tmp_path


def prod_dict(port, host):
    return {
        "app": {
            "name": "grumpy wombat",
            "port": port,
            "timeout": "30s",
            "cache": "512MB",
            "plugins": ["auth", "metrics"],
            "db": {"host": host, "pool": 4},
            "url": f"https://{host}:{port}/burrow",
        }
    }


# java ✓ (same JSON for both leaves) · pyhocon ⚠️ fails on `+=` onto an
# included list · spec ✓
def test_layers(conf_dir):
    prod = ConfigFactory.parse_file(conf_dir / "prod" / "app.conf", env={"DB_HOST": "db.example"})
    assert prod.as_dict() == prod_dict(443, "db.example")
    assert prod.get_int("app.port") == 443
    assert prod.get_duration("app.timeout").total_seconds() == 30
    assert prod.get_bytes("app.cache") == 512_000_000

    staging = ConfigFactory.parse_file(str(conf_dir / "staging" / "app.conf"), env=None)
    assert staging.get_string("app.name") == "sleepy wombat"
    assert staging.get_config("app.db").as_dict() == {"host": "localhost", "pool": 1}


# The default is os.environ, read when the parse starts — as pyhocon.
# java ✓ (its own process environment) · pyhocon ✓ · spec ✓
def test_env_default_is_os_environ(conf_dir, monkeypatch):
    path = conf_dir / "prod" / "app.conf"
    monkeypatch.setenv("DB_HOST", "from.the.process")
    monkeypatch.setenv("PORT", "9443")
    assert ConfigFactory.parse_file(path).as_dict() == prod_dict("9443", "from.the.process")
    monkeypatch.setenv("DB_HOST", "changed.since")
    monkeypatch.delenv("PORT")
    assert ConfigFactory.parse_file(path).as_dict() == prod_dict(443, "changed.since")


# A dict is all there is: nothing of os.environ gets in. Zig and java ✓ ·
# pyhocon – (os.environ only)
def test_env_dict(conf_dir, monkeypatch):
    monkeypatch.setenv("DB_HOST", "from.the.process")
    conf = ConfigFactory.parse_file(conf_dir / "prod" / "app.conf", env={"DB_HOST": "db.example", "PORT": "9443"})
    assert conf.as_dict() == prod_dict("9443", "db.example")
    with pytest.raises(ConfigSubstitutionException):
        ConfigFactory.parse_file(conf_dir / "prod" / "app.conf", env={})
    # An entry no `${…}` can name is skipped, as hocon.h does with one in
    # `environ`: Windows has `=C:=C:\\` there.
    odd = {"": "nameless", "=C:": "C:\\burrow", "A=B": "c", "DB_HOST": "db.example"}
    assert ConfigFactory.parse_file(conf_dir / "prod" / "app.conf", env=odd).get_int("app.port") == 443
    # os.environb's bytes as they are, a name or a value not UTF-8 too.
    raw = {b"DB_HOST": b"db.example", "PORT": b"\xff9443"}
    assert ConfigFactory.parse_file(conf_dir / "prod" / "app.conf", env=raw).get_string("app.port") == "\ufffd9443"
    with pytest.raises(TypeError, match="env 'PORT': expected str or bytes, not int"):
        ConfigFactory.parse_file(conf_dir / "prod" / "app.conf", env={"PORT": 8080})
    with pytest.raises(TypeError, match="env: expected a mapping"):
        ConfigFactory.parse_file(conf_dir / "prod" / "app.conf", env=[("PORT", "8080")])


# None: no fallback at all, `${?PORT}` leaves the default, `${DB_HOST}` is an
# error at its `${`. java ✓ (with an empty environment) · spec ✓
def test_env_none(conf_dir, monkeypatch):
    monkeypatch.setenv("DB_HOST", "from.the.process")
    path = conf_dir / "prod" / "app.conf"
    with pytest.raises(ConfigSubstitutionException) as e:
        ConfigFactory.parse_file(path, env=None)
    assert str(e.value) == f"{path}:5:15: Unresolved\napp.db.host = ${{DB_HOST}}\n              ^"
    assert (e.value.file, e.value.line, e.value.column) == (str(path), 5, 15)
    assert ConfigFactory.parse_file(conf_dir / "staging" / "app.conf", env=None).get_int("app.port") == 8080


# KEEP: everything but the variables is worked out, and `to_hocon()` is one
# file with no include left in it. Read where it runs, with the variables
# there, it is what the original is with them. Zig only; java ✓ reads both
# files to the same JSON.
def test_keep_compacts_to_one_file(conf_dir):
    kept = ConfigFactory.parse_file(conf_dir / "prod" / "app.conf", env=KEEP)
    assert repr(KEEP) == "zig_hocon.KEEP"
    text = kept.to_hocon()
    assert "include" not in text
    assert "port = ${?PORT}" in text
    assert "host = ${DB_HOST}" in text
    assert kept.get_string("app.name") == "grumpy wombat"
    with pytest.raises(ConfigSubstitutionException, match="to_hocon"):
        kept.as_dict()
    with pytest.raises(ConfigSubstitutionException):
        kept.get_int("app.port")
    # Below the root a `${…}` is the root's: the subtree's text alone would
    # look it up in the subtree.
    with pytest.raises(ConfigSubstitutionException):
        kept.get_config("app").to_hocon()

    deployed = conf_dir / "deployed.conf"
    deployed.write_text(text)
    for env in [{"DB_HOST": "db.example", "PORT": "9443"}, {"DB_HOST": "db.example"}]:
        now = ConfigFactory.parse_file(conf_dir / "prod" / "app.conf", env=env).as_dict()
        assert ConfigFactory.parse_file(deployed, env=env).as_dict() == now


# A getter's error points into the file the value is written in, an
# included one too; a `${…}` that waits, at its `${`. java ✓ (WrongType at
# defaults.conf: 7) · pyhocon ⚠️ (no place) · spec –
def test_getter_errors_with_place(conf_dir):
    (conf_dir / "defaults.conf").write_text(DEFAULTS.replace("pool = 4", "pool = four"))
    prod = ConfigFactory.parse_file(conf_dir / "prod" / "app.conf", env={"DB_HOST": "db.example"})
    with pytest.raises(ConfigWrongTypeException) as e:
        prod.get_int("app.db.pool")
    assert str(e.value) == (
        f"{conf_dir / 'prod'}/../defaults.conf:7:33: InvalidCharacter at app.db.pool: expected i64\n"
        "  db { host = localhost, pool = four }\n"
        "                                ^"
    )
    with pytest.raises(ConfigWrongTypeException, match=r"at app\.db\.pool: expected i64"):
        prod.get_config("app").get_config("db").get_int("pool")

    tree = ConfigFactory.parse_file(conf_dir / "prod" / "app.conf", resolve=False)
    with pytest.raises(ConfigSubstitutionException) as e:
        tree.get_string("app.db.host")
    assert str(e.value).endswith(":5:15: Unresolved at app.db.host\napp.db.host = ${DB_HOST}\n              ^")


# resolve=False: the document as written, includes merged in, every `${…}`
# still there — also the ones the file could answer. java ✓ (parse without
# resolve(), render) · pyhocon ✓ (resolve=False) · spec ✓
def test_resolve_false(conf_dir):
    tree = ConfigFactory.parse_file(conf_dir / "prod" / "app.conf", resolve=False)
    text = tree.to_hocon()
    assert '"https://"${app.db.host}":"${app.port}"/burrow"' in text
    assert tree.get_string("app.name") == "grumpy wombat"
    with pytest.raises(ConfigSubstitutionException, match="the document is not resolved"):
        tree.as_dict()
    with pytest.raises(ConfigSubstitutionException):
        tree.get_string("app.url")
    # Read again, resolved, it is the original.
    again = ConfigFactory.parse_string(text, env={"DB_HOST": "db.example"})
    assert again.as_dict() == prod_dict(443, "db.example")


# A string with a directory to include from (pyhocon's basedir).
def test_parse_string_with_basedir(conf_dir):
    conf = ConfigFactory.parse_string('include "defaults.conf"\napp.port = 1', basedir=conf_dir, env=None)
    assert conf.get_int("app.port") == 1
    assert conf.get_string("app.db.host") == "localhost"
    with pytest.raises(ConfigParseException, match="IncludeNeedsFile"):
        ConfigFactory.parse_string('include "defaults.conf"', env=None)


# C ends a string at a 0: a file name with one inside would name another file.
# As open() has it, that is a ValueError. java – (a Java string carries a 0; a
# C-only concern) · pyhocon ✓ (open() raises it) · spec –
def test_nul_in_a_file_name(conf_dir):
    with pytest.raises(ValueError, match="embedded null byte"):
        ConfigFactory.parse_file(f"{conf_dir}/defaults.conf\0.nope", env=None)
    with pytest.raises(ValueError, match="embedded null byte"):
        ConfigFactory.parse_string('include "defaults.conf"', basedir=f"{conf_dir}\0/else", env=None)


# The place of an error, as the CLI prints it: the file as named, line and
# column, the line, a caret. In an included file, that file. java ✓ (same
# lines) · pyhocon ✓ · spec –
def test_errors_with_place(tmp_path, monkeypatch):
    (tmp_path / "app.conf").write_text("name = grumpy wombat\nport = 80 [1]\n")
    (tmp_path / "prod.conf").write_text('name = grumpy wombat\ninclude "conf.d/limits.conf"\n')
    (tmp_path / "conf.d").mkdir()
    (tmp_path / "conf.d" / "limits.conf").write_text("max = 10\nburst = ${max} ${unknown}\n")

    monkeypatch.chdir(tmp_path)
    with pytest.raises(ConfigParseException) as e:
        ConfigFactory.parse_file("app.conf")
    assert str(e.value) == "app.conf:2:11: UnsupportedConcatenation\nport = 80 [1]\n          ^"
    assert e.value.name == "UnsupportedConcatenation"
    assert e.value.source_line == "port = 80 [1]"

    with pytest.raises(ConfigSubstitutionException) as e:
        ConfigFactory.parse_file("prod.conf")
    assert str(e.value) == "conf.d/limits.conf:2:16: Unresolved\nburst = ${max} ${unknown}\n               ^"

    # A tab moves no caret: it prints as one space.
    with pytest.raises(ConfigParseException) as e:
        ConfigFactory.parse_string("a {\n\tb = [1] {}\n}")
    assert str(e.value) == "2:10: UnsupportedConcatenation\n b = [1] {}\n         ^"

    for path in ["no/such/burrow.conf", b"no/such/burrow.conf"]:
        with pytest.raises(ConfigException) as e:
            ConfigFactory.parse_file(path)
        assert str(e.value) == "no/such/burrow.conf: FileNotFound"
        assert e.value.line is None
    with pytest.raises(ConfigException) as e:
        ConfigFactory.parse_file("")
    assert str(e.value) == "'': FileNotFound"
