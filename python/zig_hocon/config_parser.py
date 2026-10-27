"""Reading a document, as pyhocon's ``ConfigFactory``: from a file or from
text, with ``env`` and ``resolve`` saying how far it is worked out."""

import ctypes
import datetime
import os
from collections.abc import Callable, Mapping, Sequence
from typing import Any

from . import _capi
from ._capi import lib
from .config_tree import ConfigTree, Doc
from .exceptions import ConfigException, ConfigParseException, ConfigSubstitutionException, name_of, placed

__all__ = ["KEEP", "ConfigFactory"]


class _Keep:
    def __repr__(self) -> str:
        return "zig_hocon.KEEP"


KEEP = _Keep()
"""``env=KEEP``: a substitution the document cannot answer stays in it, for
``to_hocon()`` to write out and the machine it runs on to resolve."""

Path = str | bytes | os.PathLike[str] | os.PathLike[bytes]
"""A file name, as open() takes it."""

Env = Mapping[str, str | bytes] | Mapping[bytes, str | bytes] | _Keep | None
"""Where ``${NAME}`` looks when NAME is not in the document (``ConfigFactory``)."""

Timeout = datetime.timedelta | float | None
"""How long one fetch of an http(s) include may take: a timedelta, or
seconds; None is 30 s (``ConfigFactory``)."""


def _env_bytes(text: str | bytes, key: str | bytes) -> bytes:
    # os.environ decodes what is not UTF-8 with surrogateescape; this gives the
    # bytes back.
    if isinstance(text, str):
        return text.encode("utf-8", "surrogateescape")
    if isinstance(text, bytes):
        return text
    raise TypeError(f"env {key!r}: expected str or bytes, not {type(text).__name__}")


def _milliseconds(timeout: Timeout) -> int:
    """``http_timeout`` as hocon.h has it: 0 for the default, else 1 ms to
    what a uint32_t holds, 49 days."""
    if timeout is None:
        return 0
    ms = round((timeout.total_seconds() if isinstance(timeout, datetime.timedelta) else float(timeout)) * 1000)
    if not 1 <= ms <= 0xFFFFFFFF:
        raise ValueError(f"http_timeout: expected 1 ms to 49 days, not {timeout!r}")
    return ms


def _options(env: Env, resolve: bool, include_dir: Path | None = None, http_timeout: Timeout = None) -> tuple[_capi.Options, object]:
    """The options, and what has to live as long as they are used."""
    opts = _capi.Options(size=ctypes.sizeof(_capi.Options), resolve=bool(resolve), http_timeout_ms=_milliseconds(http_timeout))
    entries = None
    if env is KEEP:
        opts.env = _capi.ENV_KEEP
    elif env is None:
        opts.env = _capi.ENV_NONE
    elif isinstance(env, Mapping):
        lines = []
        for key, value in env.items():
            k, v = _env_bytes(key, key), _env_bytes(value, key)
            # No `${…}` can name it (Windows has `=C:=C:\` in its environment):
            # skipped, as hocon.h skips it in `environ`.
            if not k or b"=" in k:
                continue
            lines.append(_capi.c_string(k + b"=" + v))
        entries = (ctypes.c_char_p * (len(lines) + 1))(*lines, None)
        opts.env = _capi.ENV_MAP
        opts.env_vars = ctypes.cast(entries, ctypes.POINTER(ctypes.c_char_p))
    else:
        raise TypeError(f"env: expected a mapping, None or KEEP, not {type(env).__name__}")
    if include_dir is not None:
        opts.include_dir = _capi.c_string(os.fsencode(include_dir))
    return opts, entries


def _parse(
    parse: Callable[..., int | None], args: Sequence[Any], env: Env, resolve: bool, include_dir: Path | None, http_timeout: Timeout, given: str | None
) -> ConfigTree:
    opts, _entries = _options(env, resolve, include_dir, http_timeout)
    err = _capi.Error()
    handle = parse(*args, ctypes.byref(opts), ctypes.byref(err))
    if handle:
        return ConfigTree(Doc(handle), "")
    try:
        raise _parse_error(err, given)
    finally:
        lib.hocon_error_free(ctypes.byref(err))


def _parse_error(err: _capi.Error, given: str | None) -> ConfigException:
    """`app.conf:7:12: Unresolved`, the line, and a caret under the column."""
    name = name_of(err)
    cls = {_capi.PARSE: ConfigParseException, _capi.SUBSTITUTION: ConfigSubstitutionException}.get(err.code, ConfigException)
    if not err.line:
        # An empty file name is shown as '' so the message still names it.
        return cls(f"{given or repr(given)}: {name}" if given is not None else name, name=name)
    return placed(cls, err, name)


class ConfigFactory:
    """Reads a document. ``env`` is where ``${NAME}`` looks when NAME is not
    in it: ``os.environ`` (the default, as pyhocon), any mapping of names to
    values, ``None`` for nowhere, or ``KEEP`` to leave it in the document.
    ``resolve=False`` reads it with every ``${…}`` as written.
    ``http_timeout`` is how long one fetch of an http(s) include may take, a
    timedelta or seconds, 30 s by default; longer is a ConfigParseException
    named ``IncludeTimeout``."""

    @staticmethod
    def parse_file(path: Path, *, env: Env = os.environ, resolve: bool = True, http_timeout: Timeout = None) -> ConfigTree:
        """The file at ``path``; its includes are found next to it."""
        return _parse(lib.hocon_parse_file, [_capi.c_string(os.fsencode(path))], env, resolve, None, http_timeout, os.fsdecode(path))

    @staticmethod
    def parse_string(
        content: str | bytes, *, basedir: Path | None = None, env: Env = os.environ, resolve: bool = True, http_timeout: Timeout = None
    ) -> ConfigTree:
        """HOCON text; an include in it is found in ``basedir``, and without
        one is an error."""
        # Bytes or text only: bytes(0) would be an empty buffer, and parse.
        data = content.encode("utf-8", "surrogatepass") if isinstance(content, str) else bytes(memoryview(content))
        return _parse(lib.hocon_parse_string, [data, len(data)], env, resolve, basedir, http_timeout, None)
