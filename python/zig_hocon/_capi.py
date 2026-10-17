"""libhocon through ctypes: the library next to this file, the structs and
codes of include/hocon.h, and the types of its functions. Kept to hocon.h by
python/tests/test_capi.py."""

import ctypes
import os
import sys
from typing import Any

# The codes of hocon.h.
OK, PARSE, SUBSTITUTION, MISSING, WRONG_TYPE, IO, BAD_PATH, TOO_DEEP, OTHER = range(9)
ENV_PROCESS, ENV_NONE, ENV_MAP, ENV_KEEP = range(4)


class Options(ctypes.Structure):
    """``hocon_options``."""

    env: int
    env_vars: "ctypes._Pointer[ctypes.c_char_p] | None"
    resolve: bool
    include_dir: bytes | None
    _fields_ = [
        ("env", ctypes.c_int),
        ("env_vars", ctypes.POINTER(ctypes.c_char_p)),
        ("resolve", ctypes.c_bool),
        ("include_dir", ctypes.c_char_p),
    ]


class Error(ctypes.Structure):
    """``hocon_error``."""

    code: int
    name: bytes | None
    file: bytes | None
    line: int
    column: int
    source_line: bytes | None
    key_path: bytes | None
    expected: bytes | None
    _fields_ = [
        ("code", ctypes.c_int),
        ("name", ctypes.c_char_p),
        ("file", ctypes.c_char_p),
        ("line", ctypes.c_size_t),
        ("column", ctypes.c_size_t),
        ("source_line", ctypes.c_char_p),
        ("key_path", ctypes.c_char_p),
        ("expected", ctypes.c_char_p),
    ]


def _load() -> ctypes.CDLL:
    name = {"darwin": "libhocon.dylib", "win32": "hocon.dll"}.get(sys.platform, "libhocon.so")
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    try:
        return ctypes.CDLL(path)
    except OSError as e:
        raise ImportError(f"zig_hocon: cannot load {path} ({e}); `zig build python` puts it there") from e


lib = _load()
_doc, _path = ctypes.c_void_p, ctypes.c_char_p
lib.hocon_parse_file.argtypes = [ctypes.c_char_p, ctypes.POINTER(Options), ctypes.POINTER(Error)]
lib.hocon_parse_file.restype = _doc
lib.hocon_parse_string.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(Options), ctypes.POINTER(Error)]
lib.hocon_parse_string.restype = _doc
# Each getter, and the types of its out parameters.
_getters: list[tuple[str, list[Any]]] = [
    ("int", [ctypes.c_int64]),
    ("float", [ctypes.c_double]),
    ("bool", [ctypes.c_bool]),
    ("string", [ctypes.c_void_p, ctypes.c_size_t]),
    ("duration_ns", [ctypes.c_int64]),
    ("bytes", [ctypes.c_uint64]),
    ("period", [ctypes.c_int32] * 3),
]
for _name, _out in _getters:
    _getter = getattr(lib, "hocon_get_" + _name)
    _getter.argtypes = [_doc, _path] + [ctypes.POINTER(t) for t in _out]
    _getter.restype = ctypes.c_int
lib.hocon_get_config.argtypes = [_doc, _path]
lib.hocon_get_config.restype = ctypes.c_int
# A void pointer, not c_char_p: ctypes would copy the text and lose the
# pointer that hocon_free_string needs.
for _writer in (lib.hocon_to_json, lib.hocon_to_hocon):
    _writer.argtypes = [_doc, _path, ctypes.POINTER(ctypes.c_int)]
    _writer.restype = ctypes.c_void_p
lib.hocon_free_string.argtypes = [ctypes.c_void_p]
lib.hocon_free_string.restype = None
lib.hocon_error_free.argtypes = [ctypes.POINTER(Error)]
lib.hocon_error_free.restype = None
lib.hocon_free.argtypes = [_doc]
lib.hocon_free.restype = None
lib.hocon_last_error.argtypes = [_doc]
lib.hocon_last_error.restype = ctypes.POINTER(Error)


def c_string(data: bytes) -> bytes:
    """``data`` for C, which ends a string at its first 0: with one inside, it
    would be another path or name, so that is a ValueError, as for open()."""
    if b"\0" in data:
        raise ValueError("embedded null byte")
    return data
