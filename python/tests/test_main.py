"""`python -m zig_hocon`, run as a process on files on disk, as the
conformance adapter runs it: the same output and exit codes as the hocon CLI.
java ✓ (same JSON) · spec ✓"""

import os
import subprocess
import sys

import pytest

APP = """\
name = grumpy wombat
port = 8080
port = ${?PORT}
"""

# What Python needs to start, and to find this zig_hocon.
PYTHON = {"SYSTEMROOT": os.environ.get("SYSTEMROOT", ""), "PYTHONPATH": os.pathsep.join(sys.path)}

# The arguments, the environment, the exit code, stdout, stderr's end.
CASES = [
    (["--json", "app.conf"], {}, 0, '{"name":"grumpy wombat","port":8080}\n', ""),
    (["--json", "app.conf"], {"PORT": "9090"}, 0, '{"name":"grumpy wombat","port":"9090"}\n', ""),
    (["--json", "--env=none", "app.conf"], {"PORT": "9090"}, 0, '{"name":"grumpy wombat","port":8080}\n', ""),
    (["app.conf"], {}, 0, "name = grumpy wombat\nport = 8080\n", ""),
    (["--hocon", "--env=keep", "app.conf"], {}, 0, "name = grumpy wombat\nport = 8080\nport = ${?PORT}\n", ""),
    (["--json", "broken.conf"], {}, 1, "", "error: broken.conf:2:11: UnsupportedConcatenation\nport = 80 [1]\n          ^\n"),
    (["--json", "no-such.conf"], {}, 1, "", "error: no-such.conf: FileNotFound\n"),
    (["--json", "--env=keep", "app.conf"], {}, 1, "", "error: the document is not resolved: it was read with resolve=False or env=KEEP, and a ${…} is still in it; to_hocon() of the whole document writes it as it is\n"),
    (["--yaml", "app.conf"], {}, 2, "", "unrecognized arguments: --yaml\n"),
    (["--json", "--hocon", "app.conf"], {}, 2, "", "argument --hocon: not allowed with argument --json\n"),
]


@pytest.mark.parametrize("args, env, code, out, err", CASES)
def test_main(tmp_path, args, env, code, out, err):
    (tmp_path / "app.conf").write_text(APP)
    (tmp_path / "broken.conf").write_text("name = grumpy wombat\nport = 80 [1]\n")
    # Only the environment of the case, and what Python needs to start.
    run = subprocess.run([sys.executable, "-m", "zig_hocon", *args], cwd=tmp_path, env={**env, **PYTHON}, capture_output=True, text=True)
    assert (run.returncode, run.stdout) == (code, out)
    assert run.stderr.endswith(err)


# A stdout that is closed, or a pipe whose reader has gone (`| head -c1`): the
# CLI's error, not a traceback. Closing it takes preexec_fn, which is POSIX only.
@pytest.mark.parametrize("closed", [False, pytest.param(True, marks=pytest.mark.skipif(sys.platform == "win32", reason="POSIX"))])
def test_stdout_breaks(tmp_path, closed):
    # More than a pipe holds, so the write fails whenever the reader goes.
    (tmp_path / "big.conf").write_text("".join(f"wombat{i} = {i}\n" for i in range(20000)))
    args = [sys.executable, "-m", "zig_hocon", "big.conf"]
    if closed:
        run = subprocess.Popen(args, cwd=tmp_path, env=PYTHON, stderr=subprocess.PIPE, text=True, preexec_fn=lambda: os.close(1))
    else:
        run = subprocess.Popen(args, cwd=tmp_path, env=PYTHON, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        run.stdout.close()
    assert (run.wait(), run.stderr.read()) == (1, "error: big.conf: WriteFailed\n")
