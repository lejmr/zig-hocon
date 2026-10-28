"""``python -m zig_hocon.migrate conf/``: each config read by pyhocon and by
zig_hocon, with the same environment, and where they differ shown as the
config's tree. ``=`` the same, ``≈`` another type that a getter reads the
same (``as_dict()`` and a model see it), ``≠`` another value, ``!`` one of
them fails. Exit 0 when all is the same, 1 when not, 2 when it cannot run.

A directory is its ``*.conf`` files, without those another one includes:
they are checked through the file that includes them, as they cannot be
read alone. pyhocon is not a dependency; it is imported here."""

import argparse
import datetime
import glob
import importlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

from .config_parser import ConfigFactory
from .config_tree import ConfigTree
from .exceptions import ConfigException

__all__ = ["main"]

_GETTERS = {datetime.timedelta: "get_duration", bool: "get_bool", int: "get_int", float: "get_float", str: "get_string"}
# ponytail: a regular expression, not a parser: an include in a comment counts
# too, and its file is then only checked through the one including it (--all).
_INCLUDE = re.compile(r'include\s+(?:required\(\s*)?(?:file\(\s*)?("(?:[^"\\]|\\.)*")')
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
    """A HOCON path, a key with a path character in quotes."""
    return ".".join(key if _BARE_KEY.fullmatch(key) else json.dumps(key) for key in keys)


def _same(a: Any, b: Any) -> bool:
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(map(_same, a, b))
    return type(a) is type(b) and bool(a == b)


def _flat(items: list[Any]) -> list[Any]:
    return [x for item in items for x in (item if isinstance(item, list) else [item])]


def _diff(old: Any, new: Any, keys: list[Any], tree: ConfigTree) -> dict[str, Any]:
    """The node at ``keys``: an object or a list of nodes, or a value that is
    the same (``=``), the same through a getter (``≈``) or not (``≠``)."""
    if isinstance(old, dict) and isinstance(new, dict):
        fields = {}
        for key in [*old, *(k for k in new if k not in old)]:
            if key in old and key in new:
                fields[key] = _diff(old[key], new[key], [*keys, key], tree)
            else:
                fields[key] = {"kind": "≠", **({"pyhocon": old[key]} if key in old else {}), **({"zig_hocon": new[key]} if key in new else {})}
        return {"kind": "object", "fields": fields}
    if isinstance(old, list) and isinstance(new, list) and len(old) == len(new) and not _same(old, new):
        return {"kind": "list", "items": [_diff(o, n, [*keys, i], tree) for i, (o, n) in enumerate(zip(old, new))]}
    if _same(old, new):
        return {"kind": "=", "value": new}
    node = {"kind": "≠", "pyhocon": old, "zig_hocon": new}
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


def _check(path: Path, pyhocon: Any) -> dict[str, Any]:
    """One file read by both: its tree of nodes, or what each failed with."""
    out: dict[str, Any] = {"path": str(path)}
    old = None
    try:
        old = pyhocon.ConfigFactory.parse_file(str(path)).as_plain_ordered_dict()
    except Exception as e:  # noqa: BLE001 - pyhocon fails with pyparsing's, its own and Python's errors
        out["pyhocon_error"] = f"{type(e).__name__}: {e}"
    try:
        tree = ConfigFactory.parse_file(path)
    except ConfigException as e:
        out["zig_hocon_error"] = str(e)
        return out
    if old is not None:
        out["tree"] = _diff(old, tree.as_dict(), [], tree)
    return out


def _count(node: dict[str, Any]) -> int:
    if node["kind"] == "object":
        return sum(map(_count, node["fields"].values()))
    if node["kind"] == "list":
        return sum(map(_count, node["items"]))
    return int(node["kind"] != "=")


def _differences(result: dict[str, Any]) -> int:
    if "tree" in result:
        return _count(result["tree"])
    return int(("pyhocon_error" in result) != ("zig_hocon_error" in result))


def _show(value: Any) -> str:
    if isinstance(value, dict):
        return "{" + ", ".join(f"{k!r}: {_show(v)}" for k, v in value.items()) + "}"
    if isinstance(value, list):
        return "[" + ", ".join(map(_show, value)) + "]"
    return repr(value)


def _lines(node: dict[str, Any], keys: list[Any], depth: int, every: bool) -> list[str]:
    """The tree as text: an object or list where something differs, and with
    ``every`` what is the same, on one line per object."""
    pad = "  " * depth
    children = node["fields"].items() if node["kind"] == "object" else enumerate(node["items"])
    out, same = [], []
    for key, child in children:
        name = f"[{key}]" if isinstance(key, int) else _path([key])
        if child["kind"] in ("object", "list"):
            below = _lines(child, [*keys, key], depth + 1, every)
            if below:
                out += [pad + name, *below]
        elif child["kind"] == "=":
            same.append(name)
        else:
            old = _show(child["pyhocon"]) if "pyhocon" in child else "(none)"
            new = _show(child["zig_hocon"]) if "zig_hocon" in child else "(none)"
            out.append(f"{pad}{child['kind']} {name}   pyhocon {old}   zig-hocon {new}")
            if "hint" in child:
                out.append(f"{pad}    {child['hint']}")
    if every and same:
        out.insert(0, f"{pad}= {', '.join(same)}")
    return out


def _report(result: dict[str, Any], every: bool) -> list[str]:
    out = [result["path"]]
    errors = [(who, result[f"{key}_error"]) for who, key in (("pyhocon", "pyhocon"), ("zig-hocon", "zig_hocon")) if f"{key}_error" in result]
    if len(errors) == 2:
        out.append("  · both fail, which is no difference")
    for who, error in errors:
        out.append(f"  {'·' if len(errors) == 2 else '!'} {who}: " + error.replace("\n", "\n      "))
    if "tree" in result:
        out += _lines(result["tree"], [], 1, every)
    return out


def _environment(files: list[str], pairs: list[str]) -> None:
    """``KEY=value`` lines and pairs into os.environ, for both readers."""
    for name in files:
        lines = Path(name).read_text(encoding="utf-8").splitlines()
        pairs = [line for line in lines if line.strip() and not line.lstrip().startswith("#")] + pairs
    for pair in pairs:
        key, sep, value = pair.partition("=")
        if not sep:
            raise ValueError(f"zig_hocon.migrate: {pair!r} is no KEY=value")
        os.environ[key.strip()] = value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m zig_hocon.migrate", description=__doc__.split("\n\n")[0] if __doc__ else None)
    parser.add_argument("paths", nargs="+", metavar="PATH", help="a config file, or a directory of them")
    parser.add_argument("--all", action="store_true", help="every file, the included ones too, and what is the same")
    parser.add_argument("--glob", default="*.conf", help="the files of a directory (default *.conf)")
    parser.add_argument("--env-file", action="append", default=[], help="KEY=value lines for the environment of both")
    parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE", help="one variable for both")
    parser.add_argument("--json", action="store_true", help="the result as JSON, the same tree")
    args = parser.parse_args(argv)
    try:
        pyhocon = importlib.import_module("pyhocon")
    except ImportError:
        print("zig_hocon.migrate compares with pyhocon: pip install pyhocon", file=sys.stderr)
        return 2
    try:
        _environment(args.env_file, args.env)
    except (OSError, ValueError) as e:
        print(e, file=sys.stderr)
        return 2
    results = [_check(path, pyhocon) for path in _entry_points(args.paths, args.glob, args.all)]
    total = sum(map(_differences, results))
    if args.json:
        print(json.dumps({"files": results, "differences": total}, default=repr, ensure_ascii=False, indent=2))
    else:
        for result in results:
            print("\n".join(_report(result, args.all)), end="\n\n")
        for result in results:
            n = _differences(result)
            both = "both fail" if {"pyhocon_error", "zig_hocon_error"} <= result.keys() else ""
            print(f"  {result['path']}   {both or (f'{n} difference' + 's' * (n != 1) if n else 'same')}")
        files = sum(1 for r in results if _differences(r))
        print(f"{total} difference{'s' * (total != 1)} in {files} file{'s' * (files != 1)}.")
    return 1 if total else 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
