"""pip install zig-hocon puts ``hocon`` on the path: python -m zig_hocon by
another name, migrate with it."""

import importlib.metadata
import os
import subprocess
import sys

import pytest


def hocon(*args, cwd):
    code = "from zig_hocon.__main__ import hocon; hocon()"
    env = {**os.environ, "PYTHONPATH": os.pathsep.join(sys.path)}
    return subprocess.run([sys.executable, "-c", code, *args], capture_output=True, text=True, cwd=cwd, env=env)


def test_hocon_is_python_m_zig_hocon(tmp_path):
    (tmp_path / "a.conf").write_text("owl = hoot")
    assert hocon("--json", "a.conf", cwd=tmp_path).stdout == '{"owl":"hoot"}\n'
    assert "usage: hocon [-h]" in hocon("--help", cwd=tmp_path).stdout
    assert "usage: hocon migrate" in hocon("migrate", "--help", cwd=tmp_path).stdout


def test_the_command_is_installed():
    try:
        dist = importlib.metadata.distribution("zig-hocon")
    except importlib.metadata.PackageNotFoundError:
        dist = None
    # python/ on the path, perhaps with an egg-info pip left there, is no install
    if dist is None or "site-packages" not in str(dist.locate_file("zig_hocon")):
        pytest.skip("zig-hocon is not installed here, only on the path")
    assert [(e.name, e.value) for e in dist.entry_points if e.group == "console_scripts"] == [("hocon", "zig_hocon.__main__:hocon")]
