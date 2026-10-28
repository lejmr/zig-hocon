"""python -m zig_hocon migrate: each config read by pyhocon and zig_hocon, and
what differs shown as the config's tree."""

import importlib.util
import io
import json
import subprocess
import sys
from pathlib import Path

import pytest

pytest.importorskip("pyhocon")

from zig_hocon import migrate  # noqa: E402


@pytest.fixture
def conf(tmp_path):
    (tmp_path / "conf").mkdir()
    (tmp_path / "conf" / "base.conf").write_text('db { host = burrow, timeout = 30s, pool { size = 0024 }, "a.b" = 0042 }\ntags = [1, 2]\nowl { hoot = 1 }\n')
    (tmp_path / "conf" / "prod.conf").write_text('include "base.conf"\ntags += [3, 4]\nregion = ${REGION}\nl = [1, 01]\nt = b\tc\n')
    return tmp_path / "conf"


def run(capsys, *args):
    code = migrate.main([str(a) for a in args])
    return code, capsys.readouterr().out


def test_a_directory_is_its_entry_points(conf, capsys):
    code, out = run(capsys, conf, "--env", "REGION=north")
    assert code == 1
    assert "base.conf" not in out and "owl" not in out
    assert "≈ timeout   pyhocon " in out and "delta(seconds=" in out and "   zig-hocon '30s'" in out
    assert 'the same through conf.get_duration("db.timeout")' in out
    assert "≠ size   pyhocon 24   zig-hocon '0024'" in out
    assert 'conf.get_int("db.pool.size") is an error: InvalidCharacter' in out
    assert 'conf.get_int("db.\\"a.b\\"") is an error: InvalidCharacter' in out
    assert "≠ tags   pyhocon [1, 2, 3, 4]   zig-hocon [1, 2, [3, 4]]" in out
    assert "+= appends one element" in out
    assert "  l\n    ≠ [1]   pyhocon 1   zig-hocon '01'" in out
    assert "≠ t   pyhocon 'b   c'   zig-hocon 'b\\tc'" in out
    assert out.endswith("prod.conf   6 differences\n6 differences in 1 file.\n")


def test_all_checks_the_included_files_and_shows_what_is_the_same(conf, capsys):
    code, out = run(capsys, conf, "--all", "--env", "REGION=north")
    assert code == 1
    assert "base.conf   3 differences" in out
    assert "  = region" in out and "  owl\n    = hoot" in out


def test_the_same_is_exit_0(tmp_path, capsys):
    (tmp_path / "a.conf").write_text("a = 1\nb { c = [true, null, {x = 1}] }")
    code, out = run(capsys, tmp_path / "a.conf")
    assert code == 0
    assert out.endswith("a.conf   same\n0 differences in 0 files.\n")


def test_failures(tmp_path, capsys):
    (tmp_path / "zig.conf").write_text("a..b = 1")
    (tmp_path / "py.conf").write_text("a {} {b: 1}")
    (tmp_path / "both.conf").write_text("a = ${NOPE_NOT_SET}")
    code, out = run(capsys, tmp_path)
    assert code == 1
    assert "! zig-hocon: " in out and "! pyhocon: " in out
    assert "· both fail, which is no difference" in out and "both.conf   both fail" in out
    assert out.endswith("2 differences in 2 files.\n")


def test_a_key_only_one_has(tmp_path, capsys):
    (tmp_path / "plain").write_text("p = 1\no { k = 1 }")
    (tmp_path / "a.conf").write_text('include "plain"')
    (tmp_path / "plain.conf").write_text("q = 2")
    code, out = run(capsys, tmp_path / "a.conf")
    assert "≠ p   pyhocon 1   zig-hocon (none)" in out and "≠ o   pyhocon {'k': 1}   zig-hocon (none)" in out and "≠ q   pyhocon (none)   zig-hocon 2" in out


def test_json_is_the_same_tree(conf, capsys):
    code, out = run(capsys, conf, "--json", "--env", "REGION=north")
    report = json.loads(out)
    assert code == 1 and report["differences"] == 6
    [prod] = report["files"]
    db = prod["tree"]["fields"]["db"]["fields"]
    assert db["timeout"]["kind"] == "≈" and db["timeout"]["zig_hocon"] == "30s"
    assert db["timeout"]["hint"] == 'the same through conf.get_duration("db.timeout")'
    assert db["host"] == {"kind": "=", "value": "burrow"}
    assert prod["tree"]["fields"]["l"]["items"][1]["kind"] == "≠"


def test_environment(tmp_path, capsys):
    (tmp_path / "a.conf").write_text("a = ${OWL}\nb = ${BAT}")
    (tmp_path / "env").write_text("# the night shift\n\nOWL=hoot\n")
    code, out = run(capsys, tmp_path / "a.conf", "--env-file", tmp_path / "env", "--env", "BAT=flap")
    assert code == 0
    assert migrate.main([str(tmp_path / "a.conf"), "--env", "nothing"]) == 2
    assert migrate.main([str(tmp_path / "a.conf"), "--env-file", str(tmp_path / "nowhere")]) == 2
    assert "is no KEY=value" in capsys.readouterr().err


def test_glob(tmp_path, capsys):
    (tmp_path / "a.hocon").write_text("a = 1")
    (tmp_path / "b.conf").write_text("b = 01")
    code, out = run(capsys, tmp_path, "--glob", "*.hocon")
    assert code == 0 and "a.hocon" in out and "b.conf" not in out


# a month: pyhocon with dateutil has a relativedelta, which zig-hocon's
# get_duration has no unit for; without dateutil the text, as zig-hocon
def test_a_duration_of_months(tmp_path, capsys):
    (tmp_path / "a.conf").write_text("m = 1 month")
    code, out = run(capsys, tmp_path / "a.conf")
    if importlib.util.find_spec("dateutil"):
        assert code == 1 and 'conf.get_duration("m") is an error: UnknownUnit' in out
    else:
        assert code == 0


def test_a_getter_that_reads_another_value(monkeypatch):
    class Tree:
        def get_int(self, path):
            return 5

    assert migrate._diff(4, "4", ["a"], Tree())["kind"] == "≠"


def test_without_pyhocon(monkeypatch, capsys):
    def missing(name):
        raise ImportError(name)

    monkeypatch.setattr(migrate.importlib, "import_module", missing)
    assert migrate.main(["a.conf"]) == 2
    assert "no pyhocon here to compare with: pip install pyhocon" in capsys.readouterr().err


def test_python_m(conf):
    run = subprocess.run([sys.executable, "-m", "zig_hocon", "migrate", "--help"], capture_output=True, encoding="utf-8", cwd=Path(migrate.__file__).parents[1])
    assert run.returncode == 0 and "--env-file" in run.stdout and "python -m zig_hocon migrate" in run.stdout


# Windows writes a pipe or a file in its code page, which has no ≈ or ≠
def test_the_marks_into_a_stream_of_another_code_page(tmp_path, monkeypatch):
    (tmp_path / "a.conf").write_text("t = 30s")
    out = io.TextIOWrapper(io.BytesIO(), encoding="cp1252")
    monkeypatch.setattr(sys, "stdout", out)
    assert migrate.main([str(tmp_path / "a.conf")]) == 1
    out.flush()
    assert "≈ t" in out.buffer.getvalue().decode("utf-8")


# pyhocon loops for ever on this one: it is ended, and the next file is read
# by a pyhocon of its own
def test_pyhocon_that_never_answers(tmp_path, monkeypatch, capsys):
    (tmp_path / "a.conf").write_text("x { t = 1\n  x = ${?nope.a.b}\n  b = fox den }\nx = ${?NOT_SET_HERE}\n")
    (tmp_path / "b.conf").write_text("b = 1")
    monkeypatch.setattr(migrate, "_PYHOCON_SECONDS", 2.0)
    code, out = run(capsys, tmp_path)
    assert code == 1
    assert "! pyhocon: no answer in 2 s; pyhocon loops for ever on some configs" in out
    assert out.endswith("b.conf   same\n1 difference in 1 file.\n")


# the reading process, here in a thread for its lines to count
def test_the_reading_process(tmp_path):
    import multiprocessing
    import threading

    (tmp_path / "a.conf").write_text("a = 0042")
    (tmp_path / "b.conf").write_text("a {} {b: 1}")
    conn, child = multiprocessing.Pipe()
    worker = threading.Thread(target=migrate._read_with_pyhocon, args=(child,), daemon=True)
    worker.start()
    conn.send(str(tmp_path / "a.conf"))
    assert conn.poll(30) and conn.recv() == ({"a": 42}, None)
    conn.send(str(tmp_path / "b.conf"))
    assert conn.poll(30)
    value, error = conn.recv()
    assert value is None and "Exception" in error, error
    conn.send(None)
    worker.join(30)
    assert not worker.is_alive()


# nothing checked is no green: exit 2, and why
def test_nothing_to_check(tmp_path, capsys):
    (tmp_path / "a.hocon").write_text("a = 1")
    assert migrate.main([str(tmp_path)]) == 2
    assert "no *.conf file in" in capsys.readouterr().err
    assert migrate.main([str(tmp_path / "nowhere.conf"), str(tmp_path)]) == 2
    assert "no such file or directory: " in capsys.readouterr().err


# pyhocon's process ended under it: that file says so, and the next is read
# by a new one
def test_pyhocon_s_process_ends(tmp_path):
    (tmp_path / "a.conf").write_text("a = 1")
    pyhocon = migrate._Pyhocon()
    assert pyhocon.read(tmp_path / "a.conf") == ({"a": 1}, None)
    pyhocon.process.kill()
    pyhocon.process.join()
    assert pyhocon.read(tmp_path / "a.conf") == (None, "pyhocon's process ended on it")
    pyhocon.close()
    assert pyhocon.read(tmp_path / "a.conf") == ({"a": 1}, None)
    pyhocon.close()
