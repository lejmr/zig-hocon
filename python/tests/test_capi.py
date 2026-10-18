"""What the package writes again by hand, held to where it comes from: the
structs and functions of c/hocon.h, and the whitespace the library
trims around a path. A copy that drifts reads past a struct or calls with a
wrong argument, and nothing else would say so."""

import ctypes
import pathlib
import re
import sys
import unicodedata

import pytest

from zig_hocon import ConfigException, ConfigFactory, _capi

HEADER = (pathlib.Path(__file__).parents[2] / "c" / "hocon.h").read_text()
# Without its comments, which have `;` and `(` in them.
CODE = re.sub(r"/\*.*?\*/", "", HEADER, flags=re.S)

C_TYPES = {
    "int": ctypes.c_int,
    "bool": ctypes.c_bool,
    "size_t": ctypes.c_size_t,
    "uint32_t": ctypes.c_uint32,
    "char *": ctypes.c_char_p,
    "const char *": ctypes.c_char_p,
    "const char *const *": ctypes.POINTER(ctypes.c_char_p),
}


def c_fields(struct):
    body = re.search(rf"typedef struct {struct} \{{(.*?)\}} {struct};", CODE, re.S).group(1)
    fields = []
    for field in filter(str.strip, body.split(";")):
        ctype, name = re.fullmatch(r"(.*?)(\w+)", " ".join(field.split())).groups()
        fields.append((name, C_TYPES[ctype.strip()]))
    return fields


@pytest.mark.parametrize("struct, cls", [("hocon_options", _capi.Options), ("hocon_error", _capi.Error)])
def test_structs_are_the_headers(struct, cls):
    assert [(name, t) for name, t in cls._fields_] == c_fields(struct)


def test_functions_are_the_headers():
    prototypes = re.findall(r"^([\w ]+?\**)\s*(hocon_\w+)\((.*?)\);", CODE, re.M | re.S)
    assert len(prototypes) == 16
    for returns, name, params in prototypes:
        fn = getattr(_capi.lib, name)
        assert fn.argtypes is not None, name
        assert len(fn.argtypes) == len(params.split(",")), name
        # A pointer handed back as ctypes' default int would lose its top half.
        if returns.endswith("*"):
            assert fn.restype not in (None, ctypes.c_int), name
        else:
            assert fn.restype == {"void": None, "int": ctypes.c_int}[returns.strip()], name


def maybe_whitespace():
    """Every character that could be whitespace to someone: Python's, the
    control and format characters, the separators."""
    for c in map(chr, range(1, 0x10000)):
        if not 0xD800 <= ord(c) <= 0xDFFF and (c.isspace() or unicodedata.category(c) in ("Cc", "Cf", "Zs", "Zl", "Zp")):
            yield c


def found(get):
    try:
        get()
        return True
    except ConfigException:
        return False


# Python joins a subtree's path to the path asked for, so it trims what the
# library would: a subtree finds what the whole document finds.
def test_a_subtree_trims_what_the_library_trims():
    conf = ConfigFactory.parse_string("a { x = 1 }", env=None)
    wrong = []
    for c in maybe_whitespace():
        whole = found(lambda: conf.get_int(f"{c}a.x{c}"))
        if whole != found(lambda: conf.get_config("a").get_int(f"{c}x{c}")):
            wrong.append(f"U+{ord(c):04X} after the subtree's path")
        if found(lambda: conf.get_config(f"{c}a{c}")) and not found(lambda: conf.get_config(f"{c}a{c}").get_int("x")):
            wrong.append(f"U+{ord(c):04X} around the subtree's own path")
    assert wrong == []


# The package without its library: `pip install python/` refuses that, a copy
# made by hand does not. The import says how to get one. Asked for another
# platform's library, which is never there.
def test_no_library(monkeypatch):
    monkeypatch.setattr(sys, "platform", "darwin" if sys.platform == "win32" else "win32")
    with pytest.raises(ImportError, match=r"zig_hocon: cannot load .*(hocon\.dll|libhocon\.dylib).*`zig build python` puts it there"):
        _capi._load()
