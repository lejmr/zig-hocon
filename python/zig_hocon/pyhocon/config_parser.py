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
from .config_tree import ConfigInclude, ConfigList, ConfigQuotedString, ConfigSubstitution, ConfigTree, ConfigUnquotedString, ConfigValues, NoneValue, quoted

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


def _tree(pairs: list[tuple[str, Any]]) -> ConfigTree:
    return ConfigTree((quoted(k), v) for k, v in pairs)


def _resolved(doc: _core_tree.ConfigTree) -> ConfigTree:
    value = json.loads(doc.to_json(), object_pairs_hook=_tree)
    if isinstance(value, list):
        # a document that is a list, as pyhocon gives it; typed as the
        # object a document nearly always is
        return cast(ConfigTree, ConfigList(value))
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


# pyhocon's include of a file in an installed package, which HOCON has not.
_PACKAGE = re.compile(r'(include\s+(?:required\(\s*)?)package\(\s*("(?:[^"\\]|\\.)*")\s*\)')


def _packages(text: str) -> str:
    """``text`` with ``include package("pkg:file.conf")`` naming the file by its
    path in the installed package, for libhocon to include as any file."""
    # ponytail: only in the text read here, not in a file it includes; that
    # would need the file rewritten, or an include hook in libhocon.
    return _PACKAGE.sub(lambda m: m.group(1) + json.dumps(ConfigParser.resolve_package_path(json.loads(m.group(2)))), text)


class ConfigFactory:
    """Reads a document, as pyhocon's ``ConfigFactory``. ``${NAME}`` that is
    not in the document is looked up in ``os.environ``.

    How: libhocon parses and resolves the text, and its JSON becomes a
    ConfigTree, each value with the type the spec gives it: a text stays
    text, quoted or not, from an environment variable too. ``_call`` gives
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
        text = _packages(content)
        # A UTF-8 file as written is read again by libhocon, for its name in an error.
        if text == content and codecs.lookup(encoding).name == "utf-8":
            return _read(lambda r: _core.ConfigFactory.parse_file(filename, resolve=r), resolve, unresolved_value)
        return _read(lambda r: _core.ConfigFactory.parse_string(text, basedir=basedir, resolve=r), resolve, unresolved_value)

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
        # it has no directory: libhocon refuses an include in it
        return _read(lambda r: _core.ConfigFactory.parse_string(content, resolve=r), resolve, unresolved_value)

    @classmethod
    def parse_string(cls, content: str, basedir: Path | None = None, resolve: bool = True, unresolved_value: Any = DEFAULT_SUBSTITUTION) -> ConfigTree:
        """HOCON text; an include in it is found in ``basedir``, by default
        the working directory, as pyhocon finds it."""
        where = os.getcwd() if basedir is None else basedir
        return _read(lambda r: _core.ConfigFactory.parse_string(_packages(content), basedir=where, resolve=r), resolve, unresolved_value)

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
