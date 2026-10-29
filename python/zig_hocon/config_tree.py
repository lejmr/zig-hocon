"""A parsed document and the getters on it, as pyhocon's ``ConfigTree``."""

import ctypes
import datetime
import json
import threading
from collections.abc import Callable, Sequence
from typing import Any, NamedTuple, TypeVar, overload

from . import _capi
from ._capi import lib
from .exceptions import (
    ConfigException,
    ConfigMissingException,
    ConfigSubstitutionException,
    ConfigWrongTypeException,
    name_of,
    placed,
)

__all__ = ["ConfigTree"]

_T = TypeVar("_T")


class Doc:
    """A parsed document, freed with the last ConfigTree that reads it.

    hocon.h has one thread at a time on a document, and a call that fails
    leaves why on it until the next one fails: a call and the reading of its
    error hold ``lock``, so the trees of one document can be shared between
    threads."""

    def __init__(self, handle: int) -> None:
        self.handle = handle
        self.lock = threading.Lock()

    # The function is bound now: at interpreter exit the module's globals may
    # be gone before this runs.
    def __del__(self, _free: Callable[[int], None] = lib.hocon_free) -> None:
        _free(self.handle)


class _NoDefault:
    """What a getter's ``default`` is when none is given."""


_NO_DEFAULT: Any = _NoDefault()

# HOCON's whitespace, which a path may have around it: Python's own but U+0085,
# and the BOM. Held to the library's by python/tests/test_capi.py.
BLANK = "\t\n\v\f\r\x1c\x1d\x1e\x1f \xa0                　﻿"


def _path_bytes(full: str) -> bytes:
    """A path for C."""
    return _capi.c_string(full.encode("utf-8", "surrogatepass"))


def _timedelta(ns: int) -> datetime.timedelta:
    seconds, rest = divmod(ns, 1_000_000_000)
    return datetime.timedelta(seconds=seconds, microseconds=rest / 1000)


class Period(NamedTuple):
    """A calendar period, as ``hocon.Period`` and ``java.time.Period`` have
    it: months and years have no fixed length, so no timedelta holds one.
    ``relativedelta(**period._asdict())`` gives dateutil's."""

    years: int
    months: int
    days: int


class ConfigTree:
    """A document, or an object in one (``get_config``). A path is written as
    in the file, ``db.host`` or ``a."b.c"``; ``""`` is this tree itself.
    The values stay in the Zig library until a getter asks for one.

    ``default``, when given, is what a getter gives where there is nothing,
    or ``null``. The trees of one document can be read from many threads."""

    def __init__(self, doc: Doc, prefix: str) -> None:
        self._doc = doc
        self._prefix = prefix

    # A tree is read only, so a copy is the tree itself: copy.deepcopy(conf)
    # in code from pyhocon works, where it failed on the library's handle.
    def __copy__(self) -> "ConfigTree":
        return self

    def __deepcopy__(self, memo: dict[int, Any]) -> "ConfigTree":
        return self

    def _full(self, path: str) -> str:
        """``path`` from the root. Whitespace around a path is no part of it,
        and joined to the prefix it would be inside a key."""
        if not self._prefix:
            return path
        if not path:
            return self._prefix
        return f"{self._prefix.strip(BLANK)}.{path.strip(BLANK)}"

    def _get(self, getter: Callable[..., int], path: str, outs: Sequence[Any], what: str, default: Any) -> tuple[bool, Any]:
        """Calls ``getter`` into ``outs``: (True, None) when it gives a value,
        (False, default) when there is none and a default."""
        full = self._full(path)
        with self._doc.lock:
            code = getter(self._doc.handle, _path_bytes(full), *[ctypes.byref(o) for o in outs])
            found = None
            if code == _capi.WRONG_TYPE and getter is not lib.hocon_get_string:
                found = self._text(full)
                if found is None:
                    # no text there, an object or a list: the getter again, for
                    # its error, which that call put aside
                    code = getter(self._doc.handle, _path_bytes(full), *[ctypes.byref(o) for o in outs])
            error = self._error(code, full, what)
        if error is None:
            return True, None
        if found is not None:
            # What was read, as a ${…} from the environment does not show it:
            # a note, which a traceback prints (Python 3.11+), while str(error)
            # stays the message it was.
            setattr(error, "__notes__", [*getattr(error, "__notes__", ()), f"found {found!r}"])
        # A path through a scalar or a list (`a.b` with `a = 5`) is the wrong
        # type to a getter, WrongType, and has nothing at it: java's hasPath
        # is false, pyhocon gives the default. A value that does not convert
        # fails with an error of its own (TypeMismatch, InvalidCharacter…).
        if default is not _NO_DEFAULT and (code == _capi.MISSING or error.name == "WrongType"):
            return False, default
        raise error

    def _text(self, full: str) -> str | None:
        """The text at ``full`` as written, for an error to show what it
        read: ``"08"`` from the environment; None for an object or a list."""
        ptr, size = ctypes.c_void_p(), ctypes.c_size_t()
        if lib.hocon_get_string(self._doc.handle, _path_bytes(full), ctypes.byref(ptr), ctypes.byref(size)) != _capi.OK:
            return None
        return ctypes.string_at(ptr, size.value).decode("utf-8", "surrogatepass") if size.value else ""

    def _error(self, code: int, full: str, what: str) -> ConfigException | None:
        """The exception for ``code``, which a call on ``full`` just returned;
        None for none. Read before any other call on the document, which
        would say why it failed instead."""
        if code == _capi.OK:
            return None
        err = lib.hocon_last_error(self._doc.handle).contents
        name = name_of(err)
        shown = full or "the document"
        # A value that does not convert, or a `${…}` that waits, where it is
        # written: `app.conf:3:8: InvalidCharacter at db.pool: expected i64`.
        if err.line and code in (_capi.WRONG_TYPE, _capi.SUBSTITUTION):
            said = f"{name} at {shown}" + (f": expected {err.expected.decode()}" if err.expected else "")
            cls = ConfigWrongTypeException if code == _capi.WRONG_TYPE else ConfigSubstitutionException
            return placed(cls, err, said)
        if code == _capi.MISSING:
            return ConfigMissingException(f"No configuration setting found for key {full}", name=name)
        if code == _capi.WRONG_TYPE:
            return ConfigWrongTypeException(f"{shown} is not {what}", name=name)
        if code == _capi.SUBSTITUTION:
            return ConfigSubstitutionException(
                f"{shown} is not resolved: it was read with resolve=False or env=KEEP, and a ${{…}} is still in it; "
                "to_hocon() of the whole document writes it as it is",
                name=name,
            )
        if code == _capi.BAD_PATH:
            return ConfigException(f"not a path: {full!r}", name=name)
        if code == _capi.TOO_DEEP:
            return ConfigException(f"{shown} is more than 256 levels deep, deeper than JSON is written", name=name)
        # ponytail: no test runs the library out of memory, nor gives it a NULL.
        return ConfigException(f"{shown}: failed (out of memory?)", name=name)  # pragma: no cover

    def _write(self, writer: Callable[..., int | None], what: str) -> bytes:
        """This tree as ``writer`` writes it."""
        code = ctypes.c_int()
        with self._doc.lock:
            ptr = writer(self._doc.handle, _path_bytes(self._prefix), ctypes.byref(code))
            error = self._error(code.value, self._prefix, what)
        if error is not None:
            raise error
        assert ptr is not None  # there whenever the code is OK
        try:
            return ctypes.string_at(ptr)
        finally:
            lib.hocon_free_string(ptr)

    @overload
    def get_string(self, path: str) -> str: ...
    @overload
    def get_string(self, path: str, default: _T) -> str | _T: ...
    def get_string(self, path: str, default: Any = _NO_DEFAULT) -> Any:
        """Text, also of a number or a boolean as written (``1e3``, ``yes``)."""
        ptr, size = ctypes.c_void_p(), ctypes.c_size_t()
        found, value = self._get(lib.hocon_get_string, path, [ptr, size], "a string", default)
        if not found:
            return value
        return ctypes.string_at(ptr, size.value).decode("utf-8", "surrogatepass") if size.value else ""

    @overload
    def get_int(self, path: str) -> int: ...
    @overload
    def get_int(self, path: str, default: _T) -> int | _T: ...
    def get_int(self, path: str, default: Any = _NO_DEFAULT) -> Any:
        """A whole number, also from text (``"5"``); ``1.5`` is none."""
        out = ctypes.c_int64()
        found, value = self._get(lib.hocon_get_int, path, [out], "an int", default)
        return out.value if found else value

    @overload
    def get_float(self, path: str) -> float: ...
    @overload
    def get_float(self, path: str, default: _T) -> float | _T: ...
    def get_float(self, path: str, default: Any = _NO_DEFAULT) -> Any:
        out = ctypes.c_double()
        found, value = self._get(lib.hocon_get_float, path, [out], "a float", default)
        return out.value if found else value

    @overload
    def get_bool(self, path: str) -> bool: ...
    @overload
    def get_bool(self, path: str, default: _T) -> bool | _T: ...
    def get_bool(self, path: str, default: Any = _NO_DEFAULT) -> Any:
        """``true``/``yes``/``on`` and ``false``/``no``/``off``."""
        out = ctypes.c_bool()
        found, value = self._get(lib.hocon_get_bool, path, [out], "a bool", default)
        return out.value if found else value

    @overload
    def get_duration(self, path: str) -> datetime.timedelta: ...
    @overload
    def get_duration(self, path: str, default: _T) -> datetime.timedelta | _T: ...
    def get_duration(self, path: str, default: Any = _NO_DEFAULT) -> Any:
        """``30s``, ``2 minutes``; a number alone is milliseconds. A timedelta,
        to the nearest microsecond, of up to 292 years: nanoseconds in an
        int64, as C has them. Past that ConfigWrongTypeException, named
        Overflow."""
        out = ctypes.c_int64()
        found, value = self._get(lib.hocon_get_duration_ns, path, [out], "a duration", default)
        if not found:
            return value
        # C saturates there (c/hocon.h), which would be a wrong timedelta.
        # ponytail: exactly 2^63-1 ns is refused with them, nobody writes it
        if out.value == 2**63 - 1:
            raise ConfigWrongTypeException(f"{self._full(path)} is past 292 years, the longest duration an int64 of nanoseconds holds", name="Overflow")
        return _timedelta(out.value)

    @overload
    def get_bytes(self, path: str) -> int: ...
    @overload
    def get_bytes(self, path: str, default: _T) -> int | _T: ...
    def get_bytes(self, path: str, default: Any = _NO_DEFAULT) -> Any:
        """``512MB``, ``1.5 GiB``; a number alone is bytes."""
        out = ctypes.c_uint64()
        found, value = self._get(lib.hocon_get_bytes, path, [out], "a size in bytes", default)
        return out.value if found else value

    @overload
    def get_period(self, path: str) -> Period: ...
    @overload
    def get_period(self, path: str, default: _T) -> Period | _T: ...
    def get_period(self, path: str, default: Any = _NO_DEFAULT) -> Any:
        """``3mo``, ``2w``, ``1y``; a number alone is days. A ``Period`` of
        ``years``, ``months`` and ``days`` (weeks are days)."""
        years, months, days = ctypes.c_int32(), ctypes.c_int32(), ctypes.c_int32()
        found, value = self._get(lib.hocon_get_period, path, [years, months, days], "a period", default)
        return Period(years.value, months.value, days.value) if found else value

    @overload
    def get_config(self, path: str) -> "ConfigTree": ...
    @overload
    def get_config(self, path: str, default: _T) -> "ConfigTree | _T": ...
    def get_config(self, path: str, default: Any = _NO_DEFAULT) -> Any:
        """The object at ``path``, as a ConfigTree of its own."""
        found, value = self._get(lib.hocon_get_config, path, [], "an object", default)
        return ConfigTree(self._doc, self._full(path)) if found else value

    def to_json(self) -> bytes:
        """Compact JSON, as bytes: ``msgspec.json.decode`` takes them as they
        are. Durations and sizes are the text they are written as, ``"30s"``."""
        return self._write(lib.hocon_to_json, "JSON")

    def as_dict(self) -> dict[str, Any]:
        """The tree as dicts, lists and scalars, by way of JSON."""
        tree: dict[str, Any] = json.loads(self.to_json())
        return tree

    def to_hocon(self) -> str:
        """The tree as HOCON text. Read with ``env=KEEP`` that is everything
        resolved but the variables, one file to deploy; with
        ``resolve=False`` it is the document as written. A subtree with a
        ``${…}`` still in it is a ConfigSubstitutionException: the ``${…}``
        is the root's, and the subtree's text alone would read it wrong."""
        return self._write(lib.hocon_to_hocon, "HOCON").decode("utf-8", "surrogatepass")
