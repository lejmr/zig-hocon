"""help() and an IDE show the signature: the default env is named, not its
variables and their values."""

import inspect
import pydoc

from zig_hocon import ConfigFactory


def test_help_shows_no_environment(monkeypatch, tmp_path):
    monkeypatch.setenv("OWL_SECRET", "the moon is cheese")
    for method in (ConfigFactory.parse_file, ConfigFactory.parse_string):
        assert "the moon is cheese" not in pydoc.render_doc(method)
        assert repr(inspect.signature(method).parameters["env"].default) == "os.environ"
    # and the default still reads the process environment, as it is at the call
    (tmp_path / "a.conf").write_text("secret = ${OWL_SECRET}")
    assert ConfigFactory.parse_file(tmp_path / "a.conf").get_string("secret") == "the moon is cheese"
    monkeypatch.setenv("OWL_SECRET", "and the stars are dice")
    assert ConfigFactory.parse_string("secret = ${OWL_SECRET}").get_string("secret") == "and the stars are dice"
