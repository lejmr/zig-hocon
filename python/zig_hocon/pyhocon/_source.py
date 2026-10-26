"""pyhocon's syntax where the spec reads it otherwise, written the spec's way
before libhocon reads the text: ``x += v`` is ``x = ${?x} v``, as pyhocon's
parser reads it; an include pyhocon finds and libhocon would not names its
file exactly (a glob, ``package(…)``, a file without an extension); an
include in a list is the included list's elements; ``abc\\"d`` unquoted is
``abc"d``. An included file with any of it is written the same way into a
temporary file, which libhocon includes as the spec has it. A text it
cannot follow is left as it is, for libhocon to read or to report."""

import errno
import glob
import json
import os
import pathlib
import re
import shutil
import tempfile
import urllib.parse
import urllib.request
from collections.abc import Callable
from typing import TypeVar

from ..exceptions import ConfigException

_T = TypeVar("_T")

_INCLUDE = re.compile(r'include[ \t]+(?:(required)\([ \t]*)?(?:(file|url|classpath|package)\([ \t]*)?(?=")')
# a number, a boolean or null after +=: pyhocon replaces the value with it,
# the spec appends it; the spec's way is kept
_SCALAR = re.compile(r"[ \t]*(?:-?[0-9][0-9.eE+-]*|true|false|null)[ \t]*(?:$|[\n,}\]#]|//)")
# what ends an unquoted run, besides whitespace and a comment, and what
# the spec forbids in one
_RUN_END = '$"{}[]:=,#'
_FORBIDDEN = "+`^?!@*&"
_EXTENSIONS = (".conf", ".json", ".properties")


class _GiveUp(Exception):
    pass


class Rewrite:
    """One document's rewrite, and the temporary files of the included ones,
    removed by ``close()``. ``includes=False`` leaves every include to
    libhocon."""

    def __init__(self, package_path: Callable[[str], str], includes: bool = True) -> None:
        self.package_path = package_path
        self.includes = includes
        self._tmp: str | None = None
        # a temporary file, as a path and as a URL, and the file it stands for
        self._originals: dict[str, str] = {}

    def close(self) -> None:
        if self._tmp is not None:
            shutil.rmtree(self._tmp, ignore_errors=True)

    def text(self, text: str, basedir: str | None) -> str:
        """``text`` written the spec's way; includes are found in ``basedir``."""
        # most documents have none of it, and are not scanned
        if "+=" not in text and "include" not in text and "\\" not in text:
            return text
        scan = _Scan(self, text, basedir, ())
        try:
            scan.document()
        except _GiveUp:
            return text
        return scan.edited()

    def file(self, path: str, content: str) -> str:
        """The file to read for the one at ``path``: itself, or its text
        written the spec's way in a temporary file."""
        if "+=" not in content and "include" not in content and "\\" not in content:
            return path
        scan = _Scan(self, content, os.path.dirname(path), (os.path.abspath(path),))
        try:
            scan.document()
        except _GiveUp:
            return path
        return self.written(path, scan.edited()) if scan.changed else path

    def written(self, path: str, text: str) -> str:
        """``text`` in a temporary file named as ``path``."""
        if self._tmp is None:
            self._tmp = tempfile.mkdtemp(prefix="zig_hocon-pyhocon-")
        tmp = os.path.join(self._tmp, str(len(self._originals) // 2), os.path.basename(path))
        os.makedirs(os.path.dirname(tmp))
        with open(tmp, "w", encoding="utf-8") as fd:
            fd.write(text)
        self._originals[tmp] = path
        self._originals[pathlib.Path(tmp).as_uri()] = path
        return tmp

    def read(self, parse: Callable[[], _T]) -> _T:
        """``parse()``, an error in a temporary file named by the file it
        stands for."""
        try:
            return parse()
        except ConfigException as e:
            for tmp, path in self._originals.items():
                if e.file is not None and tmp in e.file:
                    e.file = e.file.replace(tmp, path)
                e.args = (str(e.args[0]).replace(tmp, path), *e.args[1:])
            if isinstance(getattr(e, "msg", None), str):
                # pyparsing's copy of the message
                setattr(e, "msg", str(e.args[0]))  # noqa: B010
            raise


class _Scan:
    def __init__(self, rewrite: Rewrite, text: str, basedir: str | None, chain: tuple[str, ...]) -> None:
        self.rewrite = rewrite
        self.text = text
        self.basedir = basedir
        # the files around this text, it the last: one not read where it is
        # names the files it includes absolute
        self.chain = chain
        self.edits: list[tuple[int, int, str]] = []
        # an edit pyhocon's syntax asks for, not only an absolute path
        self.changed = False
        # "list", "braced" or "bare", and what is inside the brackets
        self.root = "bare"
        self.inner = (0, len(text))

    def edit(self, start: int, end: int, new: str, changed: bool = True) -> None:
        self.edits.append((start, end, new))
        self.changed = self.changed or changed

    def edited(self, start: int = 0, end: int | None = None) -> str:
        end = len(self.text) if end is None else end
        out, at = [], start
        # the edits are in order, and all between start and end
        for s, e, new in self.edits:
            out.append(self.text[at:s])
            out.append(new)
            at = e
        out.append(self.text[at:end])
        return "".join(out)

    def comment(self, i: int) -> bool:
        return self.text.startswith(("#", "//"), i)

    def line_end(self, i: int) -> int:
        end = self.text.find("\n", i)
        return len(self.text) if end < 0 else end

    def blank(self, i: int, newlines: bool = True, commas: bool = True) -> int:
        """Past spaces and comments, and newlines and commas when asked."""
        text = self.text
        while i < len(text):
            c = text[i]
            if c in " \t\r﻿" or (newlines and c == "\n") or (commas and c == ","):
                i += 1
            elif self.comment(i):
                i = self.line_end(i)
            else:
                break
        return i

    def string_end(self, i: int) -> int:
        text = self.text
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            if end < 0:
                raise _GiveUp
            end += 3
            while end < len(text) and text[end] == '"':
                end += 1
            return end
        i += 1
        while i < len(text) and text[i] != '"':
            if text[i] == "\n":
                raise _GiveUp
            i += 2 if text[i] == "\\" else 1
        if i >= len(text):
            raise _GiveUp
        return i + 1

    def substitution_end(self, i: int) -> int:
        """Past ``${…}``, a quoted ``}`` in its path too."""
        text = self.text
        i += 2
        while i < len(text) and text[i] != "}":
            if text[i] == "\n":
                raise _GiveUp
            i = self.string_end(i) if text[i] == '"' else i + 1
        if i >= len(text):
            raise _GiveUp
        return i + 1

    def run_end(self, i: int) -> int:
        """Past an unquoted run, its backslash escapes too."""
        text = self.text
        while i < len(text) and not text[i].isspace() and text[i] not in _RUN_END and not self.comment(i):
            i += 2 if text[i] == "\\" else 1
        return min(i, len(text))

    def document(self) -> None:
        i = self.blank(0)
        if self.text.startswith(("{", "["), i):
            self.root = "braced" if self.text[i] == "{" else "list"
            start = i + 1
            i = self.fields(start, "", "}") if self.root == "braced" else self.items(start)
            self.inner = (start, i - 1)
        else:
            i = self.fields(i, "", None)
        if self.blank(i) < len(self.text):
            raise _GiveUp

    def fields(self, i: int, prefix: str | None, close: str | None) -> int:
        """An object's fields up to ``close``; ``prefix`` is its path, None
        in a list."""
        text = self.text
        while True:
            i = self.blank(i)
            if i >= len(text):
                if close is not None:
                    raise _GiveUp
                return i
            if close is not None and text[i] == close:
                return i + 1
            if text[i] in "}]":
                raise _GiveUp
            if _INCLUDE.match(text, i):
                i = self.include(i, in_list=False)
                continue
            start = i
            while i < len(text) and text[i] not in "=:{\n,}#" and not text.startswith(("+=", "//"), i):
                i = self.string_end(i) if text[i] == '"' else i + 1
            key = text[start:i].strip()
            if not key or i >= len(text):
                raise _GiveUp
            if text[i] == "\n":
                # a key, and its object on a line below
                i = self.blank(i, commas=False)
                if not text.startswith("{", i):
                    raise _GiveUp
            path = None if prefix is None else f"{prefix}.{key}" if prefix else key
            if text.startswith("+=", i):
                if path is not None and not _SCALAR.match(text, i + 2):
                    self.edit(i, i + 2, f"= ${{?{path}}}")
                i = self.value(i + 2, path)
            elif text[i] in "=:":
                i = self.value(i + 1, path)
            elif text[i] == "{":
                i = self.value(i, path)
            else:
                raise _GiveUp

    def items(self, i: int) -> int:
        text = self.text
        while True:
            i = self.blank(i)
            if i >= len(text):
                raise _GiveUp
            if text[i] == "]":
                return i + 1
            if _INCLUDE.match(text, i):
                i = self.include(i, in_list=True)
                continue
            i = self.value(i, None)

    def value(self, i: int, path: str | None) -> int:
        """A field's value or a list element, up to the newline, comma or
        bracket after it."""
        text = self.text
        i = self.blank(i, commas=False)
        while True:
            i = self.blank(i, newlines=False, commas=False)
            if i >= len(text) or text[i] in "\n,}]" or self.comment(i):
                return i
            c = text[i]
            if c == "{":
                i = self.fields(i + 1, path, "}")
            elif c == "[":
                i = self.items(i + 1)
            elif c == '"':
                i = self.string_end(i)
            elif text.startswith("${", i):
                i = self.substitution_end(i)
            elif c in _RUN_END:
                raise _GiveUp
            else:
                end = self.run_end(i)
                run = text[i:end]
                if "\\" in run and not any(f in run for f in _FORBIDDEN):
                    try:
                        json.loads(f'"{run}"')
                    except ValueError:
                        raise _GiveUp from None
                    self.edit(i, end, f'"{run}"')
                i = end

    def include(self, i: int, in_list: bool) -> int:
        text = self.text
        m = _INCLUDE.match(text, i)
        assert m is not None
        required, kind = m.group(1), m.group(2)
        end = self.string_end(m.end())
        if text.startswith('"""', m.end()):
            raise _GiveUp
        name: str = json.loads(text[m.end() : end])
        for paren in (kind, required):
            if paren:
                end = self.blank(end, newlines=False, commas=False)
                if not text.startswith(")", end):
                    raise _GiveUp
                end += 1
        remote = kind == "classpath" or kind == "url" and not name.startswith("file:") or kind is None and name.startswith(("http://", "https://"))
        if remote or not self.rewrite.includes:
            # libhocon's; in a list it stays the text it is by the spec
            return end
        if kind == "url" or name.startswith("file:"):
            path = urllib.request.url2pathname(urllib.parse.urlparse(name).path)
        else:
            if kind == "package":
                name = self.rewrite.package_path(name)
            path = name if self.basedir is None else os.path.join(self.basedir, name)
        wildcard = "*" in path or "?" in path
        paths = sorted(glob.glob(path, recursive=True)) if wildcard else [path]
        if in_list:
            elements = self.elements_of(paths, required is not None and not wildcard)
            if not elements:
                # nothing is left, nor the comma after it
                after = self.blank(end, newlines=False, commas=False)
                end = after + 1 if text.startswith(",", after) else end
            self.edit(i, end, elements)
            return end
        parts, rewritten = [], False
        for p in paths:
            if not os.path.isfile(p):
                target = f"file({json.dumps(os.path.abspath(p))})"
            else:
                scan = None if p.endswith((".json", ".properties")) else self.scan_of(p)
                if scan is not None and scan.changed:
                    # pyhocon's syntax in the included file too
                    p = self.rewrite.written(p, scan.edited())
                    rewritten = True
                target = f"url({json.dumps(pathlib.Path(os.path.abspath(p)).as_uri())})"
            parts.append(f"include required({target})" if required else f"include {target}")
        changed = rewritten or kind == "package" or wildcard or os.path.isfile(path) and not path.endswith(_EXTENSIONS)
        if changed or self.chain and kind != "url":
            self.edit(i, end, ", ".join(parts), changed)
        return end

    def scan_of(self, path: str) -> "_Scan | None":
        """The file at ``path`` scanned, None when it cannot be."""
        if os.path.abspath(path) in self.chain:
            raise _GiveUp
        try:
            with open(path, encoding="utf-8") as fd:
                content = fd.read()
        except UnicodeDecodeError:
            return None
        scan = _Scan(self.rewrite, content, os.path.dirname(path), (*self.chain, os.path.abspath(path)))
        try:
            scan.document()
        except _GiveUp:
            return None
        return scan

    def elements_of(self, paths: list[str], required: bool) -> str:
        """The elements of the lists in ``paths``, an object as one."""
        parts = []
        for p in paths:
            if not os.path.isfile(p):
                if required:
                    raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), p)
                continue
            scan = self.scan_of(p)
            if scan is None:
                raise _GiveUp
            if scan.root == "list":
                parts.append(scan.edited(*scan.inner))
            else:
                parts.append(scan.edited() if scan.root == "braced" else "{\n" + scan.edited() + "\n}")
        return "\n" + "\n".join(parts) + "\n" if parts else ""
