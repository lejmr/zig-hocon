"""pyhocon's ``ConfigFactory`` and ``ConfigParser``, with its arguments. The
document is read by libhocon, as ``zig_hocon.ConfigFactory`` reads it, and
handed over as a ConfigTree of Python's own values.

Changed from pyhocon's config_parser.py (Apache-2.0, LICENSE in this
directory): its arguments and messages over libhocon's parser."""

import codecs
import contextlib
import errno
import functools
import importlib
import importlib.util
import json
import logging
import os
import re
import socket
import urllib.error
import urllib.request
from collections.abc import Callable, Mapping
from typing import Any, Literal, TypeVar, cast, overload

from .. import config_parser as _core
from .. import config_tree as _core_tree
from ..exceptions import ConfigException, ConfigMissingException, ConfigParseException, ConfigSubstitutionException, ConfigWrongTypeException
from ._source import Rewrite
from .config_tree import ConfigInclude, ConfigList, ConfigQuotedString, ConfigSubstitution, ConfigTree, ConfigUnquotedString, ConfigValues, NoneValue, quoted
from .period_parser import duration

# with the names pyhocon's module has from where it imports them
__all__ = [
    "DEFAULT_SUBSTITUTION",
    "MANDATORY_SUBSTITUTION",
    "NO_SUBSTITUTION",
    "STR_SUBSTITUTION",
    "ConfigFactory",
    "ConfigInclude",
    "ConfigMissingException",
    "ConfigParser",
    "ConfigQuotedString",
    "ConfigSubstitution",
    "ConfigSubstitutionException",
    "ConfigUnquotedString",
    "ConfigValues",
    "NoneValue",
]

logger = logging.getLogger(__name__)

Path = str | os.PathLike[str]
"""A file name."""


# pyhocon's `unresolved_value`: what a ${…} with no value becomes.
class DEFAULT_SUBSTITUTION:
    """An error (the default)."""


class MANDATORY_SUBSTITUTION:
    """An error."""


class NO_SUBSTITUTION:
    """Nothing yet: the document stays unresolved, as with resolve=False."""


class STR_SUBSTITUTION:
    """Its own text, ``"${x}"``. Not supported here."""


class IncludeNotFoundError(ConfigParseException, FileNotFoundError):
    """A ``required(…)`` include that is not there: an OSError too, as
    pyhocon raises it."""


# libhocon's errors that pyhocon raises as another class
_AS_PYHOCON: dict[str, type[ConfigException]] = {
    "UnsupportedConcatenation": ConfigWrongTypeException,
    "IncludeNotFound": IncludeNotFoundError,
}

_T = TypeVar("_T")

# A number by pyhocon's grammar, and one by JSON's: libhocon reads a text
# of the first that is not the second (0024, .54) as text, pyhocon as the
# number. One JSON has is quoted in the document, and stays text.
_PYHOCON_NUMBER = re.compile(r"-?(\d*\.\d+|\d+(\.\d+)?)([eE][+-]?\d+)?")
_JSON_NUMBER = re.compile(r"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?")


@functools.cache
def _syntax_error() -> type[ConfigParseException]:
    """The class of a syntax error. With pyparsing installed, as it is beside
    pyhocon, it is pyparsing's ParseException and ParseSyntaxException too,
    which pyhocon raises, so an ``except`` written for pyhocon catches it.
    pyparsing is no dependency of zig-hocon, so the class is made here, once,
    when it is first needed. ``line`` stays zig_hocon's line number;
    ``lineno`` and ``col`` give it under pyparsing's names."""
    try:
        pp = importlib.import_module("pyparsing")
    except ImportError:
        return ConfigParseException

    def init(self: Any, message: str) -> None:
        ConfigParseException.__init__(self, message)
        # pyparsing's own __init__ takes the message for the parsed text
        self.args, self.pstr, self.loc, self.msg = (message,), "", 0, message

    namespace = {"__init__": init, "__module__": __name__, "lineno": property(lambda self: self.line), "col": property(lambda self: self.column)}
    return cast(type[ConfigParseException], type("ConfigParseException", (ConfigParseException, pp.ParseException, pp.ParseSyntaxException), namespace))


def _call(read: Callable[[], _T]) -> _T:
    """``read()``, its error in pyhocon's class."""
    try:
        return read()
    except ConfigException as e:
        cls = _AS_PYHOCON.get(e.name or "")
        if cls is None and type(e) is ConfigParseException and "Include" not in (e.name or ""):
            cls = _syntax_error()
        if cls is None or cls is ConfigParseException:
            raise
        # the message alone: OSError takes more arguments as errno and strerror
        err = cls(str(e))
        err.name, err.file, err.line, err.column, err.source_line = e.name, e.file, e.line, e.column, e.source_line
        if isinstance(err, OSError):
            err.errno, err.strerror = errno.ENOENT, os.strerror(errno.ENOENT)
        raise err from None


def _typed(value: Any) -> Any:
    """A value from libhocon's JSON as pyhocon has it: ``30s`` a duration,
    ``0024`` the number 24."""
    if isinstance(value, str):
        if _PYHOCON_NUMBER.fullmatch(value) and not _JSON_NUMBER.fullmatch(value):
            return int(value) if value.lstrip("-").isdigit() else float(value)
        return duration(value)
    if isinstance(value, list):
        return [_typed(v) for v in value]
    return value


def _tree(pairs: list[tuple[str, Any]]) -> ConfigTree:
    return ConfigTree((quoted(k), _typed(v)) for k, v in pairs)


def _resolved(doc: _core_tree.ConfigTree) -> ConfigTree:
    value = json.loads(doc.to_json(), object_pairs_hook=_tree)
    if isinstance(value, list):
        # a document that is a list, as pyhocon gives it; typed as the
        # object a document nearly always is
        return cast(ConfigTree, ConfigList(_typed(value)))
    value.root = True
    return cast(ConfigTree, value)


def as_written(text: str) -> ConfigTree:
    """A document read with resolve=False, from its text: its values when
    it resolves alone, else empty and unresolved; the text kept for
    with_fallback() and resolve_substitutions() to finish."""
    try:
        tree = _call(lambda: _resolved(_core.ConfigFactory.parse_string(text)))
    except ConfigSubstitutionException:
        tree = ConfigTree(root=True)
        tree._unresolved = True
    tree._as_written = text
    return tree


def _read(parse: Callable[[bool], _core_tree.ConfigTree], resolve: bool, unresolved_value: Any) -> ConfigTree:
    """The document ``parse`` reads, resolved or not, as a ConfigTree."""
    if unresolved_value is NO_SUBSTITUTION:
        resolve = False
    elif unresolved_value is not DEFAULT_SUBSTITUTION and unresolved_value is not MANDATORY_SUBSTITUTION:
        raise NotImplementedError("unresolved_value: only DEFAULT_SUBSTITUTION, MANDATORY_SUBSTITUTION and NO_SUBSTITUTION")
    if resolve:
        return _call(lambda: _resolved(parse(True)))
    return as_written(_call(lambda: parse(False).to_hocon()))


def _rewrite(includes: bool = True) -> contextlib.closing[Rewrite]:
    return contextlib.closing(Rewrite(ConfigParser.resolve_package_path, includes))


class ConfigFactory:
    """Reads a document, as pyhocon's ``ConfigFactory``. ``${NAME}`` that is
    not in the document is looked up in ``os.environ``.

    How: Rewrite (``_source.py``) writes pyhocon's syntax the spec's way,
    libhocon parses and resolves the text, and its JSON becomes a
    ConfigTree, each value with pyhocon's type (``_typed``). ``_call`` gives
    an error pyhocon's class."""

    @overload
    @classmethod
    def parse_file(cls, filename: Path, encoding: str = ..., required: Literal[True] = ..., resolve: bool = ..., unresolved_value: Any = ...) -> ConfigTree: ...
    @overload
    @classmethod
    def parse_file(cls, filename: Path, encoding: str, required: bool, resolve: bool = ..., unresolved_value: Any = ...) -> ConfigTree | list[Any]: ...
    @overload
    @classmethod
    def parse_file(cls, filename: Path, encoding: str = ..., *, required: bool, resolve: bool = ..., unresolved_value: Any = ...) -> ConfigTree | list[Any]: ...
    @classmethod
    def parse_file(
        cls, filename: Path, encoding: str = "utf-8", required: bool = True, resolve: bool = True, unresolved_value: Any = DEFAULT_SUBSTITUTION
    ) -> ConfigTree | list[Any]:
        """The file at ``filename``, in ``encoding``; its includes are found
        next to it. A file that cannot be read is an OSError, or with
        ``required=False`` a warning and an empty list."""
        try:
            with open(filename, encoding=encoding) as fd:
                content = fd.read()
        except OSError:
            if required:
                raise
            logger.warning("Cannot include file %s. File does not exist or cannot be read.", filename)
            return []
        basedir = os.path.dirname(filename)
        with _rewrite() as rewrite:
            # A UTF-8 file is read again by libhocon, for its name in an error.
            if codecs.lookup(encoding).name == "utf-8":
                path = rewrite.file(os.fspath(filename), content)
                return rewrite.read(lambda: _read(lambda r: _core.ConfigFactory.parse_file(path, resolve=r), resolve, unresolved_value))
            text = rewrite.text(content, basedir)
            return rewrite.read(lambda: _read(lambda r: _core.ConfigFactory.parse_string(text, basedir=basedir, resolve=r), resolve, unresolved_value))

    @overload
    @classmethod
    def parse_URL(
        cls, url: str, timeout: float | None = ..., resolve: bool = ..., required: Literal[False] = ..., unresolved_value: Any = ...
    ) -> ConfigTree | list[Any]: ...
    @overload
    @classmethod
    def parse_URL(cls, url: str, timeout: float | None, resolve: bool, required: Literal[True], unresolved_value: Any = ...) -> ConfigTree: ...
    @overload
    @classmethod
    def parse_URL(cls, url: str, timeout: float | None = ..., resolve: bool = ..., *, required: Literal[True], unresolved_value: Any = ...) -> ConfigTree: ...
    @classmethod
    def parse_URL(
        cls, url: str, timeout: float | None = None, resolve: bool = True, required: bool = False, unresolved_value: Any = DEFAULT_SUBSTITUTION
    ) -> ConfigTree | list[Any]:
        """The document at ``url``. ``timeout`` in seconds, by default
        ``socket.getdefaulttimeout()``. One that cannot be fetched is a
        warning and an empty list, or with ``required=True`` the urllib
        error. An include in it is an error: it has no directory."""
        try:
            with contextlib.closing(urllib.request.urlopen(url, timeout=socket.getdefaulttimeout() if timeout is None else timeout)) as fd:
                content = fd.read().decode("utf-8")
        except urllib.error.URLError:
            logger.warning("Cannot include url %s. Resource is inaccessible.", url)
            if required:
                raise
            return []
        # it has no directory: its includes are libhocon's, which refuses them
        with _rewrite(includes=False) as rewrite:
            text = rewrite.text(content, None)
            return _read(lambda r: _core.ConfigFactory.parse_string(text, resolve=r), resolve, unresolved_value)

    @classmethod
    def parse_string(cls, content: str, basedir: Path | None = None, resolve: bool = True, unresolved_value: Any = DEFAULT_SUBSTITUTION) -> ConfigTree:
        """HOCON text; an include in it is found in ``basedir``, by default
        the working directory, as pyhocon finds it."""
        where = os.getcwd() if basedir is None else basedir
        with _rewrite() as rewrite:
            text = rewrite.text(content, None if basedir is None else os.fspath(basedir))
            return rewrite.read(lambda: _read(lambda r: _core.ConfigFactory.parse_string(text, basedir=where, resolve=r), resolve, unresolved_value))

    @classmethod
    def from_dict(cls, dictionary: Mapping[str, Any], root: bool = False) -> Any:
        """``dictionary`` as a ConfigTree, its dicts too; a key is a path,
        so ``{"a.b": 1}`` is ``a { b = 1 }``."""

        def tree(value: Any) -> Any:
            if isinstance(value, Mapping):
                res = ConfigTree(root=root)
                for key, child in value.items():
                    res.put(key, tree(child))
                return res
            if isinstance(value, list):
                return [tree(v) for v in value]
            return value

        return tree(dictionary)


class ConfigParser:
    """pyhocon's parser, which ConfigFactory calls."""

    @classmethod
    def parse(cls, content: str, basedir: Path | None = None, resolve: bool = True, unresolved_value: Any = DEFAULT_SUBSTITUTION) -> ConfigTree:
        """``ConfigFactory.parse_string``."""
        return ConfigFactory.parse_string(content, basedir, resolve, unresolved_value)

    @classmethod
    def resolve_package_path(cls, package_path: str) -> str:
        """``"my_package:foo/bar.conf"`` as the path of ``foo/bar.conf`` in
        the installed package ``my_package``. ValueError without the
        ``:``, ImportError for a package that is not there or a file it does
        not have, as pyhocon."""
        if ":" not in package_path:
            raise ValueError("Expected format is 'PACKAGE:PATH'")
        package, path = package_path.split(":", 1)
        spec = importlib.util.find_spec(package)
        if spec is None or not spec.submodule_search_locations:
            raise ImportError(f"No module named {package!r}")
        for directory in spec.submodule_search_locations:
            if os.path.exists(os.path.join(directory, path)):
                return os.path.join(directory, path)
        raise ImportError(f"Can't find {path} in package:{package}")

    @classmethod
    def resolve_substitutions(cls, config: ConfigTree, accept_unresolved: bool = False) -> bool:
        """Resolves a tree read with ``resolve=False``, in place; a ${…}
        with no value is a ConfigSubstitutionException, or with
        ``accept_unresolved=True`` stays. True when one stays."""
        if config._as_written is None:
            return False
        try:
            text = config._as_written
            tree = _call(lambda: _resolved(_core.ConfigFactory.parse_string(text)))
        except ConfigSubstitutionException:
            if accept_unresolved:
                return True
            raise
        config.clear()
        config.update(tree.items())
        config._as_written = None
        config._unresolved = False
        return False
