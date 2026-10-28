"""``python -m zig_hocon migrate conf/``: each config read by pyhocon and by
zig_hocon, with the same environment, and where they differ shown as the
config's tree. ``=`` the same, ``≈`` another type that a getter reads the
same (``as_dict()`` and a model see it), ``≠`` another value, ``!`` one of
them fails. Exit 0 when all is the same, 1 when not, 2 when it cannot run,
as without pyhocon to compare with.

A directory is its ``*.conf`` files, without those another one includes:
they are checked through the file that includes them, as they cannot be
read alone. pyhocon is not a dependency; it is imported here."""

import argparse
import contextlib
import datetime
import glob
import importlib
import io
import json
import logging
import multiprocessing
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from collections.abc import Callable
from multiprocessing.connection import Connection
from pathlib import Path
from typing import Any

from .config_parser import ConfigFactory
from .config_tree import ConfigTree
from .exceptions import ConfigException

__all__ = ["main"]

_GETTERS = {datetime.timedelta: "get_duration", bool: "get_bool", int: "get_int", float: "get_float", str: "get_string"}
# An include where a line or an object starts, so not one in a comment.
# ponytail: a regular expression, not a parser: one on a line of a """ string
# counts too, and its file is then only checked through the one including it.
_INCLUDE = re.compile(r'(?:^|[{,])[ \t]*include\s+(?:required\(\s*)?(?:file\(\s*)?("(?:[^"\\]|\\.)*")', re.MULTILINE)
_BARE_KEY = re.compile(r"[A-Za-z0-9_-]+")
# pyhocon's duration with dateutil installed, as a timedelta from a day it adds to
_EPOCH = datetime.datetime(2000, 1, 1)


def _entry_points(paths: list[str], pattern: str, every: bool) -> list[Path]:
    """The files named, and in each directory its files but those another includes."""
    files: list[Path] = []
    for name in paths:
        path = Path(name)
        if not path.is_dir():
            files.append(path)
            continue
        found = sorted(path.rglob(pattern))
        included: set[Path] = set()
        for f in found:
            for written in _INCLUDE.findall(f.read_text(encoding="utf-8", errors="replace")):
                for ext in ("", ".conf", ".json", ".properties"):
                    included.update(Path(g).resolve() for g in glob.glob(str(f.parent / json.loads(written)) + ext))
        files += [f for f in found if every or f.resolve() not in included]
    return files


def _path(keys: list[Any]) -> str:
    """A HOCON path, a key with a path character in quotes; a list index,
    in what is shown, as ``[2]``."""
    out = ""
    for key in keys:
        if isinstance(key, int):
            out += f"[{key}]"
        else:
            out += ("." if out else "") + (key if _BARE_KEY.fullmatch(key) else json.dumps(key))
    return out


def _accept(node: dict[str, Any], keys: list[Any], accepted: list[str]) -> None:
    """Marks each difference at a path ``accepted`` names, or below one."""
    if node["kind"] == "object":
        for key, child in node["fields"].items():
            _accept(child, [*keys, key], accepted)
    elif node["kind"] == "list":
        for i, child in enumerate(node["items"]):
            _accept(child, [*keys, i], accepted)
    elif node["kind"] != "=":
        path = _path(keys)
        if any(path == a or path.startswith((a + ".", a + "[")) for a in accepted):
            node["accepted"] = True


def _same(a: Any, b: Any) -> bool:
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(map(_same, a, b))
    return type(a) is type(b) and bool(a == b)


def _flat(items: list[Any]) -> list[Any]:
    return [x for item in items for x in (item if isinstance(item, list) else [item])]


def _diff(old: Any, new: Any, keys: list[Any], tree: ConfigTree, lenient: dict[str, Any] | None = None) -> dict[str, Any]:
    """The node at ``keys``: an object or a list of nodes, or a value that is
    the same (``=``), the same through a getter (``≈``) or not (``≠``).
    ``lenient`` has what pyhocon's getters read in its text and nulls."""
    lenient = lenient or {}
    if isinstance(old, dict) and isinstance(new, dict):
        fields = {}
        for key in [*old, *(k for k in new if k not in old)]:
            if key in old and key in new:
                fields[key] = _diff(old[key], new[key], [*keys, key], tree, lenient)
            else:
                fields[key] = {"kind": "≠", **({"pyhocon": old[key]} if key in old else {}), **({"zig_hocon": new[key]} if key in new else {})}
        return {"kind": "object", "fields": fields}
    # a list as long, but that is pyhocon's += of a list, is one difference with the hint below
    plus_equals = isinstance(old, list) and isinstance(new, list) and _same(old, _flat(new)) and not _same(old, new)
    if isinstance(old, list) and isinstance(new, list) and len(old) == len(new) and not _same(old, new) and not plus_equals:
        return {"kind": "list", "items": [_diff(o, n, [*keys, i], tree, lenient) for i, (o, n) in enumerate(zip(old, new))]}
    node = {"kind": "≠", "pyhocon": old, "zig_hocon": new}
    if _same(old, new):
        # the same number, but get_string reads it as written: 1.10, 1e3
        if type(new) in (int, float) and not any(isinstance(k, int) for k in keys):
            text = tree.get_string(_path(keys))
            if text != str(old):
                return {**node, "hint": f'conf.get_string({json.dumps(_path(keys))}) is "{text}", pyhocon\'s "{old}"'}
        # the same text or null, which pyhocon's getters read where these do
        # not: "08" and " 4" as numbers, "True" as a bool, null as None
        read = {} if any(isinstance(k, int) for k in keys) else lenient.get(_path(keys), {})
        misread = [_misread(tree, getter, _path(keys), want) for getter, want in read.items()]
        if any(misread):
            return {**node, "hint": "; ".join(m for m in misread if m)}
        return {"kind": "=", "value": new}
    want = _EPOCH + old - _EPOCH if type(old).__name__ == "relativedelta" else old
    getter = _GETTERS.get(type(want))
    if getter and type(old) is not type(new) and not any(isinstance(k, int) for k in keys):
        call = f"conf.{getter}({json.dumps(_path(keys))})"
        try:
            if _same(want, getattr(tree, getter)(_path(keys))):
                return {**node, "kind": "≈", "hint": f"the same through {call}"}
        except ConfigException as e:
            node["hint"] = f"{call} is an error: {e.name}"
    if isinstance(old, list) and isinstance(new, list) and _same(old, _flat(new)):
        node["hint"] = "+= appends one element, here a list; x = ${x} [...] extends it (MIGRATING.md, Step 3)"
    return node


def _misread(tree: ConfigTree, getter: str, path: str, want: Any) -> str:
    """How zig-hocon's ``getter`` reads ``path`` where pyhocon's reads
    ``want``; empty when alike."""
    call = f"conf.{getter}({json.dumps(path)})"
    try:
        got = getattr(tree, getter)(path)
    except ConfigException as e:
        return f"{call} is an error: {e.name}, pyhocon's {want!r}"
    return "" if _same(want, got) else f"{call} is {got!r}, pyhocon's {want!r}"


def _lenient(tree: Any, plain: dict[str, Any], keys: list[str]) -> dict[str, Any]:
    """In pyhocon's process: what its getters read in each text and each
    null, by path. zig-hocon's read only numbers and booleans as written."""
    out: dict[str, Any] = {}
    for key, value in plain.items():
        path = [*keys, key]
        if isinstance(value, dict):
            out.update(_lenient(tree, value, path))
        elif value is None:
            out[_path(path)] = {"get_string": None}
        elif isinstance(value, str):
            read = {}
            for getter in ("get_int", "get_float", "get_bool"):
                with contextlib.suppress(Exception):
                    read[getter] = getattr(tree, getter)(_path(path))
            if read:
                out[_path(path)] = read
    return out


# How long pyhocon may take for one file.
_PYHOCON_SECONDS = 30.0


def _read_with_pyhocon(conn: Connection) -> None:
    """Reads each path sent, with pyhocon, over its fallbacks as a loader
    does it (``parse_file(…, resolve=False).with_fallback(…)``), and sends
    back its values, or the error; None ends it. Its warnings, an include it
    leaves out, say what the tree shows."""
    logging.disable(logging.WARNING)
    pyhocon = importlib.import_module("pyhocon")
    while (job := conn.recv()) is not None:
        path, fallbacks, each = job
        try:
            tree = pyhocon.ConfigFactory.parse_file(path, resolve=each or not fallbacks)
            for fallback in fallbacks:
                tree = tree.with_fallback(pyhocon.ConfigFactory.parse_file(fallback, resolve=each), resolve=fallback == fallbacks[-1])
            plain = tree.as_plain_ordered_dict()
            conn.send(((plain, _lenient(tree, plain, [])), None))
        except Exception as e:  # noqa: BLE001 - pyhocon fails with pyparsing's, its own and Python's errors
            conn.send((None, f"{type(e).__name__}: {e}"))


class _Pyhocon:
    """pyhocon in a process of its own, ended when it takes too long: it
    loops for ever on some configs, ``x { a = ${?n.a} }`` and then
    ``x = ${?NOT_SET}``."""

    def __init__(self) -> None:
        self.process: Any = None

    def read(self, path: Path, fallbacks: list[str] = [], each: bool = False) -> tuple[Any, str | None]:  # noqa: B006 - read, never changed
        if self.process is None:
            self.conn, child = multiprocessing.Pipe()
            self.process = multiprocessing.get_context("spawn").Process(target=_read_with_pyhocon, args=(child,), daemon=True)
            self.process.start()
            # its end is the process's now: when that ends, so does the pipe
            child.close()
        error = f"no answer in {_PYHOCON_SECONDS:g} s; pyhocon loops for ever on some configs"
        try:
            self.conn.send((str(path), fallbacks, each))
            if self.conn.poll(_PYHOCON_SECONDS):
                result: tuple[Any, str | None] = self.conn.recv()
                return result
        except (EOFError, OSError):
            error = "pyhocon's process ended on it"
        self.process.terminate()
        self.process = None
        return None, error

    def close(self) -> None:
        if self.process is not None:
            self.conn.send(None)
            self.process.join()


def _check(path: Path, pyhocon: _Pyhocon, fallbacks: list[str] = [], each: bool = False, before: Callable[[str], str] = str) -> dict[str, Any]:  # noqa: B006 - read, never changed
    """One file read by both, over its fallbacks: its tree of nodes, or what
    each failed with. zig_hocon reads the fallbacks as includes before the
    file, the last one first: the same merge, done by the parser. pyhocon
    reads each file where ``before`` puts it, and with ``each`` resolves
    each one before the merge."""
    out: dict[str, Any] = {"path": str(path)}
    read, error = pyhocon.read(Path(before(str(path))), [before(f) for f in fallbacks], each)
    if error is not None:
        out["pyhocon_error"] = error + ((_PLUS_ONE if fallbacks else _PLUS_EQUALS) if "'bool' object has no attribute 'count'" in error else "")
    try:
        if fallbacks:
            files = [*reversed(fallbacks), str(path)]
            text = "\n".join(f"include required(file({json.dumps(os.path.abspath(f))}))" for f in files)
            tree = ConfigFactory.parse_string(text, basedir=os.path.dirname(os.path.abspath(path)))
        else:
            tree = ConfigFactory.parse_file(path)
    except ConfigException as e:
        out["zig_hocon_error"] = str(e)
        return out
    if read is not None:
        old, lenient = read
        out["tree"] = _diff(old, tree.as_dict(), [], tree, lenient)
    return out


# pyhocon's own bug, the one a layered config meets first: without
# --fallback, its files read alone; with it, an `x += a` it cannot read.
_PLUS_EQUALS = (
    "\n    pyhocon fails so on `+=` onto a list from another file or object: when your loader"
    " merges the files with with_fallback, --fallback reads them as it does"
)
_PLUS_ONE = (
    "\n    pyhocon fails so on `x += a`, one element onto a list, and over a fallback on"
    " `x = ${x} [a]` too: it cannot read this config. --before main has it read the config"
    " as it is on main, against this one on zig_hocon"
)


def _count(node: dict[str, Any], same_through_getter: bool = False) -> int:
    """The differences in ``node``; ``≈`` not among them when
    ``same_through_getter``, for code that reads through the getters."""
    if node["kind"] == "object":
        return sum(_count(n, same_through_getter) for n in node["fields"].values())
    if node["kind"] == "list":
        return sum(_count(n, same_through_getter) for n in node["items"])
    if node.get("accepted"):
        return 0
    return int(node["kind"] not in (("=", "≈") if same_through_getter else ("=",)))


def _differences(result: dict[str, Any], same_through_getter: bool = False) -> int:
    if "tree" in result:
        return _count(result["tree"], same_through_getter)
    return int(("pyhocon_error" in result) != ("zig_hocon_error" in result))


def _show(value: Any) -> str:
    if isinstance(value, dict):
        return "{" + ", ".join(f"{k!r}: {_show(v)}" for k, v in value.items()) + "}"
    if isinstance(value, list):
        return "[" + ", ".join(map(_show, value)) + "]"
    return repr(value)


def _lines(node: dict[str, Any], keys: list[Any], depth: int, every: bool, getters: bool = False) -> list[str]:
    """The tree as text: an object or list where something differs, and with
    ``every`` what is the same, on one line per object; with ``getters`` a
    ``≈`` is the same."""
    pad = "  " * depth
    children = node["fields"].items() if node["kind"] == "object" else enumerate(node["items"])
    out, same = [], []
    for key, child in children:
        name = f"[{key}]" if isinstance(key, int) else _path([key])
        if child["kind"] in ("object", "list"):
            below = _lines(child, [*keys, key], depth + 1, every, getters)
            if below:
                out += [pad + name, *below]
        elif child["kind"] == "=" or (getters and child["kind"] == "≈"):
            same.append(name)
        else:
            old = _show(child["pyhocon"]) if "pyhocon" in child else "(none)"
            new = _show(child["zig_hocon"]) if "zig_hocon" in child else "(none)"
            accepted = "   (accepted)" if child.get("accepted") else ""
            out.append(f"{pad}{child['kind']} {name}   pyhocon {old}   zig-hocon {new}{accepted}")
            if "hint" in child:
                out.append(f"{pad}    {child['hint']}")
    if every and same:
        out.insert(0, f"{pad}= {', '.join(same)}")
    return out


def _report(result: dict[str, Any], every: bool, getters: bool = False) -> list[str]:
    out = [result["path"]]
    errors = [(who, result[f"{key}_error"]) for who, key in (("pyhocon", "pyhocon"), ("zig-hocon", "zig_hocon")) if f"{key}_error" in result]
    if len(errors) == 2:
        out.append("  · both fail, which is no difference")
    for who, error in errors:
        out.append(f"  {'·' if len(errors) == 2 else '!'} {who}: " + error.replace("\n", "\n      "))
    if "tree" in result:
        out += _lines(result["tree"], [], 1, every, getters)
    return out


def _checkout(rev: str) -> Callable[[str], str]:
    """The files of the git repository here as they are at ``rev``, in a
    directory of their own: where each path is there."""
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    tar = subprocess.run(["git", "-C", top, "archive", "--format=tar", rev], capture_output=True, check=True).stdout
    there = tempfile.mkdtemp(prefix="zig-hocon-migrate-")
    with tarfile.open(fileobj=io.BytesIO(tar)) as files:
        if hasattr(tarfile, "data_filter"):
            files.extractall(there, filter="data")
        else:  # pragma: no cover - a Python before the filter; git's own archive
            files.extractall(there)  # noqa: S202
    top = os.path.realpath(top)
    return lambda path: os.path.join(there, os.path.relpath(os.path.realpath(path), top))


def _unquoted(line: str) -> str:
    key, sep, value = line.partition("=")
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        value = value[1:-1]
    return key + sep + value


def _environment(files: list[str], pairs: list[str]) -> None:
    """``KEY=value`` lines and pairs into os.environ, for both readers. A
    line of a file may begin with ``export`` and quote its value, as a
    shell's or docker's env file does. Later wins: a later file over an
    earlier one, ``--env`` over the files."""
    from_files: list[str] = []
    for name in files:
        lines = [line.strip() for line in Path(name).read_text(encoding="utf-8").splitlines()]
        lines = [line.removeprefix("export ").lstrip() for line in lines if line and not line.startswith("#")]
        from_files += [_unquoted(line) for line in lines]
    for pair in from_files + pairs:
        key, sep, value = pair.partition("=")
        if not sep:
            raise ValueError(f"migrate: {pair!r} is no KEY=value")
        os.environ[key.strip()] = value


def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        # the marks, ≈ ≠ ·, also into a pipe or a file on Windows, whose
        # code page has none of them
        if isinstance(stream, io.TextIOWrapper) and stream.encoding.replace("-", "").lower() != "utf8":
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(prog="python -m zig_hocon migrate", description=__doc__.split("\n\n")[0] if __doc__ else None)
    parser.add_argument("paths", nargs="+", metavar="PATH", help="a config file, or a directory of them")
    parser.add_argument("--all", action="store_true", help="every file, the included ones too, and what is the same")
    parser.add_argument("--glob", default="*.conf", help="the files of a directory (default *.conf)")
    parser.add_argument("--env-file", action="append", default=[], help="KEY=value lines for the environment of both")
    parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE", help="one variable for both")
    parser.add_argument("--json", action="store_true", help="the result as JSON, the same tree")
    parser.add_argument(
        "--fallback",
        action="append",
        default=[],
        metavar="FILE",
        help="read each config over FILE, as conf.with_fallback(FILE) does; again for one under it",
    )
    parser.add_argument("--resolve-each", action="store_true", help="pyhocon resolves each file before the merge, as a loader of parse_file(…) without resolve=False does")
    parser.add_argument("--before", metavar="REV", help="pyhocon reads the configs as they are in git at REV (main), zig_hocon as they are now")
    parser.add_argument("--getters", action="store_true", help="≈ is no difference: for code that reads only through the getters")
    parser.add_argument(
        "--accept",
        action="append",
        default=[],
        metavar="PATH",
        help="a difference at PATH, or below it, is reviewed: shown, and no difference (db.file_mode, tags[2], db)",
    )
    args = parser.parse_args(argv)
    try:
        importlib.import_module("pyhocon")
    except ImportError:
        print("no pyhocon here to compare with: pip install pyhocon, in this environment", file=sys.stderr)
        return 2
    try:
        _environment(args.env_file, args.env)
    except (OSError, ValueError) as e:
        print(e, file=sys.stderr)
        return 2
    # Nothing checked is no green: a path that is not there, or a directory
    # with no file the glob names, is an error.
    missing = [name for name in [*args.paths, *args.fallback] if not os.path.exists(name)]
    if missing:
        print(f"migrate: no such file or directory: {', '.join(missing)}", file=sys.stderr)
        return 2
    # a fallback is read under each config, not on its own
    fallbacks = {os.path.abspath(f) for f in args.fallback}
    entry_points = [p for p in _entry_points(args.paths, args.glob, args.all) if os.path.abspath(p) not in fallbacks]
    if not entry_points:
        print(f"migrate: no {args.glob} file in {', '.join(args.paths)} to check; --glob names others", file=sys.stderr)
        return 2
    try:
        before = _checkout(args.before) if args.before else str
    except (OSError, subprocess.CalledProcessError, tarfile.TarError) as e:
        print(f"migrate: --before {args.before}: {e}", file=sys.stderr)
        return 2
    pyhocon = _Pyhocon()
    try:
        results = [_check(path, pyhocon, args.fallback, args.resolve_each, before) for path in entry_points]
    finally:
        pyhocon.close()
    for result in results:
        if "tree" in result:
            _accept(result["tree"], [], args.accept)
    def differences(result: dict[str, Any]) -> int:
        return _differences(result, args.getters)

    total = sum(map(differences, results))
    compared = any("tree" in r for r in results)
    if not total and not compared:
        print("migrate: no config could be compared: each fails in both; --env-file gives a ${…} its value", file=sys.stderr)
    if args.json:
        print(json.dumps({"files": results, "differences": total}, default=repr, ensure_ascii=False, indent=2))
    else:
        for result in results:
            print("\n".join(_report(result, args.all, args.getters)), end="\n\n")
        for result in results:
            n = differences(result)
            both = "both fail" if {"pyhocon_error", "zig_hocon_error"} <= result.keys() else ""
            print(f"  {result['path']}   {both or (f'{n} difference' + 's' * (n != 1) if n else 'same')}")
        files = sum(1 for r in results if differences(r))
        print(f"{total} difference{'s' * (total != 1)} in {files} file{'s' * (files != 1)}.")
    return 1 if total else 0 if compared else 2

