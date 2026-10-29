"""A getter that cannot read a value notes what it read: a ${…} from the
environment shows only its name where it is written. The message stays as
it was; the note is what a traceback prints under it (Python 3.11+)."""

import traceback

import pytest

from zig_hocon import ConfigFactory, ConfigWrongTypeException


def test_the_value_read_is_noted(monkeypatch):
    monkeypatch.setenv("OWL_POOL", "08")
    conf = ConfigFactory.parse_string("db { pool = ${?OWL_POOL}, nest = { a = 1 } }\nawake = True\nquiet = \"\"")
    for getter, path, note in [("get_int", "db.pool", "found '08'"), ("get_bool", "awake", "found 'True'"), ("get_int", "quiet", "found ''")]:
        with pytest.raises(ConfigWrongTypeException) as e:
            getattr(conf, getter)(path)
        assert e.value.__notes__ == [note]
        assert "found" not in str(e.value)
    # an object has no text to show: the getter's error alone
    with pytest.raises(ConfigWrongTypeException) as e:
        conf.get_int("db.nest")
    assert not hasattr(e.value, "__notes__")
    assert str(e.value).splitlines()[0].endswith("TypeMismatch at db.nest: expected i64")


def test_a_traceback_shows_the_note(monkeypatch):
    monkeypatch.setenv("OWL_POOL", "08")
    conf = ConfigFactory.parse_string("pool = ${?OWL_POOL}")
    try:
        conf.get_int("pool")
    except ConfigWrongTypeException as e:
        shown = "".join(traceback.format_exception(e))
    import sys

    if sys.version_info >= (3, 11):
        assert "found '08'" in shown
