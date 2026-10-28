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
    assert "≈ timeout   pyhocon " in out and "delta(seconds=" in out and " → zig-hocon '30s'" in out
    assert 'the same through conf.get_duration("db.timeout")' in out
    assert "≠ size   pyhocon 24 → zig-hocon '0024'" in out
    assert 'conf.get_int("db.pool.size"): zig-hocon error (InvalidCharacter)' in out
    assert 'conf.get_int("db.\\"a.b\\""): zig-hocon error (InvalidCharacter)' in out
    assert "≠ tags   pyhocon [1, 2, 3, 4] → zig-hocon [1, 2, [3, 4]]" in out
    assert "+= appends one element" in out
    assert "  l\n    ≠ [1]   pyhocon 1 → zig-hocon '01'" in out
    assert "≠ t   pyhocon 'b   c' → zig-hocon 'b\\tc'" in out
    assert "prod.conf   6 differences\n6 differences in 1 file.\npyhocon → zig-hocon · ≠ reads differently" in out


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
    assert "2 differences in 2 files.\n" in out


def test_a_key_only_one_has(tmp_path, capsys):
    (tmp_path / "plain").write_text("p = 1\no { k = 1 }")
    (tmp_path / "a.conf").write_text('include "plain"')
    (tmp_path / "plain.conf").write_text("q = 2")
    code, out = run(capsys, tmp_path / "a.conf")
    assert "≠ p   pyhocon 1 → zig-hocon (none)" in out and "≠ o   pyhocon {'k': 1} → zig-hocon (none)" in out and "≠ q   pyhocon (none) → zig-hocon 2" in out


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
        assert code == 1 and 'conf.get_duration("m"): zig-hocon error (UnknownUnit)' in out
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
    assert "b.conf   same\n1 difference in 1 file.\n" in out


# the reading process, here in a thread for its lines to count
def test_the_reading_process(tmp_path):
    import multiprocessing
    import threading

    (tmp_path / "a.conf").write_text('a = 0042\nb { s = "08", n = null, t = owl }')
    (tmp_path / "b.conf").write_text("a {} {b: 1}")
    conn, child = multiprocessing.Pipe()
    worker = threading.Thread(target=migrate._read_with_pyhocon, args=(child,), daemon=True)
    worker.start()
    conn.send((str(tmp_path / "a.conf"), [], False))
    lenient = {"b.s": {"get_int": 8, "get_float": 8.0}, "b.n": {"get_string": None}}
    assert conn.poll(30) and conn.recv() == (({"a": 42, "b": {"s": "08", "n": None, "t": "owl"}}, lenient), None)
    conn.send((str(tmp_path / "b.conf"), [], False))
    assert conn.poll(30)
    value, error = conn.recv()
    assert value is None and "Exception" in error, error
    # over a fallback, as a loader merges them
    (tmp_path / "ref.conf").write_text("host = a\nport = 1")
    (tmp_path / "c.conf").write_text("host = b")
    conn.send((str(tmp_path / "c.conf"), [str(tmp_path / "ref.conf")], False))
    assert conn.poll(30) and conn.recv()[0][0] == {"host": "b", "port": 1}
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
    assert pyhocon.read(tmp_path / "a.conf") == (({"a": 1}, {}), None)
    pyhocon.process.kill()
    pyhocon.process.join()
    assert pyhocon.read(tmp_path / "a.conf") == (None, "pyhocon's process ended on it")
    pyhocon.close()
    assert pyhocon.read(tmp_path / "a.conf") == (({"a": 1}, {}), None)
    pyhocon.close()


# an include in a comment is none: the file it names is checked on its own
def test_an_include_in_a_comment(tmp_path, capsys):
    (tmp_path / "a.conf").write_text('# include "extra.conf"\n// include "extra.conf"\na = 1\nb { include "inner.conf" }')
    (tmp_path / "extra.conf").write_text("b = 0012")
    (tmp_path / "inner.conf").write_text("c = 1")
    code, out = run(capsys, tmp_path)
    assert code == 1 and "extra.conf   1 difference" in out and "inner.conf" not in out


# an env file as a shell or docker writes it: export, and quoted values
def test_an_env_file_with_export_and_quotes(tmp_path, monkeypatch, capsys):
    (tmp_path / "a.conf").write_text("a = ${OWL}\nb = ${BAT}\nc = ${MOTH}")
    (tmp_path / "env").write_text("export OWL=hoot\nBAT=\"flap flap\"\n  export MOTH='dust'\n")
    for key in ("OWL", "BAT", "MOTH"):
        monkeypatch.delenv(key, raising=False)
    code, out = run(capsys, tmp_path / "a.conf", "--env-file", tmp_path / "env")
    assert code == 0
    import os

    assert (os.environ["OWL"], os.environ["BAT"], os.environ["MOTH"]) == ("hoot", "flap flap", "dust")


# the same number, which get_string reads as written
def test_a_number_get_string_reads_otherwise(tmp_path, capsys):
    (tmp_path / "a.conf").write_text("version = 1.10\nn = 7\nl = [1.10]")
    code, out = run(capsys, tmp_path / "a.conf")
    assert code == 1
    assert 'conf.get_string("version"): pyhocon "1.1" → zig-hocon "1.10"' in out
    assert "≠ n " not in out and "1 difference in 1 file.\n" in out


# later wins: a later env file over an earlier one, --env over both
def test_env_files_later_wins(tmp_path, monkeypatch, capsys):
    import os

    (tmp_path / "a.conf").write_text("a = ${OWL}")
    (tmp_path / "base.env").write_text("OWL=hoot\nBAT=flap\n")
    (tmp_path / "prod.env").write_text("OWL=screech\n")
    monkeypatch.delenv("OWL", raising=False)
    monkeypatch.delenv("BAT", raising=False)
    run(capsys, tmp_path / "a.conf", "--env-file", tmp_path / "base.env", "--env-file", tmp_path / "prod.env")
    assert (os.environ["OWL"], os.environ["BAT"]) == ("screech", "flap")
    run(capsys, tmp_path / "a.conf", "--env-file", tmp_path / "base.env", "--env-file", tmp_path / "prod.env", "--env", "OWL=whoo")
    assert os.environ["OWL"] == "whoo"


# the same text or null, which pyhocon's getters read and these do not: from
# the environment "08" and " 4" as numbers, "True" as a bool, and null as None
def test_what_pyhocon_s_getters_read_in_text(tmp_path, monkeypatch, capsys):
    (tmp_path / "a.conf").write_text('pool = ${POOL}\nworkers = ${WORKERS}\nbeta = ${BETA}\npassword = null\nname = "owl"\nport = "5432"\nok = yes')
    for key, value in {"POOL": "08", "WORKERS": " 4", "BETA": "True"}.items():
        monkeypatch.setenv(key, value)
    code, out = run(capsys, tmp_path / "a.conf")
    assert code == 1
    assert 'conf.get_int("pool"): pyhocon 8 → zig-hocon error (InvalidCharacter)' in out
    assert 'conf.get_int("workers"): pyhocon 4 → zig-hocon error (InvalidCharacter)' in out
    assert 'conf.get_bool("beta"): pyhocon True → zig-hocon error' in out
    assert 'conf.get_string("password"): pyhocon None → zig-hocon error (Missing)' in out
    assert "≠ pool   '08' in both" in out
    assert "≠ name" not in out and "≠ port" not in out and "≠ ok" not in out
    assert "4 differences in 1 file.\n" in out


# nothing compared is no green either: each file fails in both
def test_every_file_fails_in_both(tmp_path, capsys):
    (tmp_path / "a.conf").write_text("a = ${NOT_SET_HERE_EITHER}")
    assert migrate.main([str(tmp_path)]) == 2
    assert "no config could be compared" in capsys.readouterr().err


# a config the loader merges in code, conf.with_fallback(reference): read
# alone pyhocon fails on its += (its bug), and says how to read it as the
# loader does; with --fallback both read it over the reference, which is not
# checked on its own
def test_a_config_over_a_fallback(tmp_path, capsys):
    (tmp_path / "conf").mkdir()
    (tmp_path / "reference.conf").write_text('plugins = [auth]\nhost = a\nurl = "db://"${host}\n')
    (tmp_path / "conf" / "prod.conf").write_text("plugins += [metrics]\nhost = b\n")
    (tmp_path / "one.conf").write_text("plugins = [auth]\nplugins += metrics\n")
    code, out = run(capsys, tmp_path / "one.conf")
    assert "AttributeError" in out and "--fallback reads them as it does" in out
    code, out = run(capsys, tmp_path / "conf", "--fallback", tmp_path / "reference.conf")
    assert code == 1
    assert "≠ plugins   pyhocon ['auth', 'metrics'] → zig-hocon ['auth', ['metrics']]" in out
    assert "+= appends one element" in out and "url" not in out
    code, out = run(capsys, tmp_path, "--fallback", tmp_path / "reference.conf", "--all")
    assert "reference.conf   " not in out and "= host, url" in out
    assert migrate.main([str(tmp_path / "conf"), "--fallback", str(tmp_path / "nowhere.conf")]) == 2
    # with --fallback given, pyhocon's += failure is the one-element form
    (tmp_path / "conf" / "prod.conf").write_text("plugins += metrics\n")
    code, out = run(capsys, tmp_path / "conf", "--fallback", tmp_path / "reference.conf")
    assert "--before main has it read the config" in out and "--fallback reads them" not in out


# --getters: a value another type that a getter reads the same is no
# difference, for code that reads only through the getters
def test_getters_only(tmp_path, capsys):
    (tmp_path / "a.conf").write_text("t = 30s\nn = 1")
    assert run(capsys, tmp_path / "a.conf")[0] == 1
    code, out = run(capsys, tmp_path / "a.conf", "--getters")
    assert code == 0 and "≈ t" not in out and out.endswith("0 differences in 0 files.\n")
    code, out = run(capsys, tmp_path / "a.conf", "--getters", "--all")
    assert "= t, n" in out


# --accept: a difference reviewed is shown, and no difference; a path names
# a value, a list element or everything below it
def test_accepted_differences(tmp_path, capsys):
    (tmp_path / "a.conf").write_text("mode = 0640\ndb { pool = 0010, port = 0005 }\ntags = [a, 01]\nother = 007")
    assert run(capsys, tmp_path / "a.conf")[0] == 1
    code, out = run(capsys, tmp_path / "a.conf", "--accept", "mode", "--accept", "db", "--accept", "tags[1]", "--accept", "other")
    assert code == 0, out
    assert "≠ mode   pyhocon 640 → zig-hocon '0640'   (accepted)" in out
    assert "≠ pool   pyhocon 10 → zig-hocon '0010'   (accepted)" in out
    assert out.endswith("0 differences in 0 files.\n")
    code, out = run(capsys, tmp_path / "a.conf", "--accept", "db.pool", "--accept", "mode", "--accept", "tags", "--accept", "oth")
    assert code == 1 and "2 differences in 1 file.\n" in out


# --resolve-each: a loader that resolves each file before with_fallback keeps
# the old host in url; over resolve=False, and on zig_hocon, url follows it
def test_a_loader_that_resolves_each_file(tmp_path, capsys):
    (tmp_path / "reference.conf").write_text('host = a\nurl = "db://"${host}\n')
    (tmp_path / "prod.conf").write_text("host = b\n")
    code, out = run(capsys, tmp_path / "prod.conf", "--fallback", tmp_path / "reference.conf")
    assert code == 0
    code, out = run(capsys, tmp_path / "prod.conf", "--fallback", tmp_path / "reference.conf", "--resolve-each")
    assert code == 1 and "≠ url   pyhocon 'db://a' → zig-hocon 'db://b'" in out


# --before REV: pyhocon reads the configs as git has them at REV, zig_hocon as
# they are now, so a config rewritten for zig_hocon is checked against the one
# pyhocon read
def test_before_and_after(tmp_path, monkeypatch, capsys):
    import shutil
    import subprocess

    if shutil.which("git") is None:
        pytest.skip("no git here (the Alpine image of the musl wheels' tests)")

    def git(*args):
        subprocess.run(["git", *args], cwd=tmp_path, check=True, capture_output=True)

    git("init", "-q")
    (tmp_path / "app.conf").write_text("plugins = [auth]\nplugins += [metrics]\n")
    git("add", ".")
    git("-c", "user.name=owl", "-c", "user.email=owl@example.org", "commit", "-q", "-m", "the night shift")
    (tmp_path / "app.conf").write_text("plugins = [auth]\nplugins = ${plugins} [metrics]\n")
    monkeypatch.chdir(tmp_path)
    assert run(capsys, "app.conf")[0] == 0
    code, out = run(capsys, "app.conf", "--before", "HEAD")
    assert code == 0 and out.endswith("app.conf   same\n0 differences in 0 files.\n")
    (tmp_path / "app.conf").write_text("plugins = [auth]\nplugins += [metrics]\n")
    assert run(capsys, "app.conf", "--before", "HEAD")[0] == 1
    assert migrate.main(["app.conf", "--before", "no-such-rev"]) == 2
    assert "--before no-such-rev" in capsys.readouterr().err


# --color: pyhocon's side red, zig-hocon's green, as a diff has them; never
# on a pipe unless asked, and not with NO_COLOR
def test_colours(tmp_path, monkeypatch, capsys):
    (tmp_path / "a.conf").write_text("n = 01")
    code, out = run(capsys, tmp_path / "a.conf", "--color", "always")
    assert "\033[31m1\033[0m → \033[32m'01'\033[0m" in out
    assert "\033[31mpyhocon\033[0m → \033[32mzig-hocon\033[0m · " in out
    assert "\033[" not in run(capsys, tmp_path / "a.conf")[1]
    monkeypatch.setattr(sys.stdout, "isatty", lambda: True, raising=False)
    monkeypatch.setenv("NO_COLOR", "1")
    assert "\033[" not in run(capsys, tmp_path / "a.conf")[1]


# pip install zig-hocon puts zig-hocon-migrate on the path: the same check
def test_the_command(tmp_path, capsys):
    import importlib.metadata

    (tmp_path / "a.conf").write_text("n = 01")
    monkey = sys.argv
    try:
        sys.argv = ["zig-hocon-migrate", str(tmp_path / "a.conf")]
        assert migrate.cli() == 1
    finally:
        sys.argv = monkey
    assert "≠ n" in capsys.readouterr().out
    try:
        dist = importlib.metadata.distribution("zig-hocon")
    except importlib.metadata.PackageNotFoundError:
        return
    # python/ on the path, perhaps with an egg-info pip left there, is no install
    if "site-packages" in str(dist.locate_file("zig_hocon")):
        assert [(e.name, e.value) for e in dist.entry_points if e.group == "console_scripts"] == [("zig-hocon-migrate", "zig_hocon.migrate:cli")]
