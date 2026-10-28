"""pyhocon's ``ConfigTree``: the document as an OrderedDict of Python's own
values, read and changed by dotted paths, as pyhocon has it.

Changed from pyhocon's config_tree.py (Apache-2.0, LICENSE in this
directory): its methods, their conversions and messages."""

import copy
import json
import re
from collections import OrderedDict
from typing import TYPE_CHECKING, Any

from ..exceptions import (
    ConfigException,
    ConfigMissingException,
    ConfigSubstitutionException,
    ConfigWrongTypeException,
)

if TYPE_CHECKING:
    from .config_parser import Path

__all__ = [
    "ConfigInclude",
    "ConfigList",
    "ConfigQuotedString",
    "ConfigSubstitution",
    "ConfigTree",
    "ConfigUnquotedString",
    "ConfigValues",
    "NonExistentKey",
    "NoneValue",
    "UndefinedKey",
]


class UndefinedKey:
    """A getter's ``default`` when none is given."""


class NonExistentKey:
    """What ``get`` gives ``__getattr__`` for a name that is no key."""


class NoneValue:
    """``null`` inside pyhocon's parser. Here a ``null`` is None."""


# pyhocon's parser objects, for code that imports them or checks a value
# against them. No value here is one: libhocon reads the document.
class ConfigInclude:
    """pyhocon's ``include`` while it parses."""


class ConfigValues:
    """pyhocon's value that waits for a ``${…}``."""


class ConfigSubstitution:
    """pyhocon's ``${…}`` while it parses."""


class ConfigQuotedString:
    """pyhocon's quoted string while it parses."""


class ConfigUnquotedString(str):
    """pyhocon's unquoted string while it parses."""


class ConfigList(list[Any]):
    """pyhocon's list. A list here is a plain list."""


# A path is cut at these; a key with one in it is kept in quotes, '"a.b"',
# so that a path can name it.
_SPECIAL = "$}[]:=+#`^?!@*&."
_PATH_KEY = re.compile('"[^"]+"|[^' + re.escape(_SPECIAL) + "]+")
_HAS_SPECIAL = re.compile("[" + re.escape(_SPECIAL) + "]").search


def quoted(key: str) -> str:
    """``key`` as a ConfigTree keeps it."""
    return f'"{key}"' if _HAS_SPECIAL(key) else key


class ConfigTree(OrderedDict[str, Any]):
    """A document, or an object in one: an OrderedDict of its keys. ``get``
    and the getters take a path, ``db.host`` or ``a."b.c"``; ``conf.db.host``
    and ``conf["db.host"]`` are ``get`` too. A key with a path character in
    it is kept in quotes: ``"b.c"``. A value is a ConfigTree, a list, text,
    a number, a bool or None, or a duration as pyhocon has it (``30s`` is
    a timedelta); sizes are the text they are written as."""

    KEY_SEP = "."

    def __init__(self, *args: Any, **kwds: Any) -> None:
        self.root = bool(kwds.pop("root", False))
        # A document read with resolve=False: its text, with every ${…} as
        # written, for with_fallback() and resolve_substitutions() to finish;
        # `_unresolved` when it could not be read without them. Private, as a
        # name here hides a key of that name from `conf.name`.
        self._as_written: str | None = None
        self._unresolved = False
        super().__init__(*args, **kwds)

    def _check_resolved(self) -> None:
        if self._unresolved:
            raise ConfigSubstitutionException(
                "the document was read with resolve=False and a ${…} in it has no value yet: "
                "with_fallback() or ConfigParser.resolve_substitutions() gives it one",
                name="Unresolved",
            )

    def _hocon_text(self) -> str:
        """This tree as HOCON text that merges after another's."""
        if self._as_written is not None:
            return self._as_written
        # JSON is HOCON; without its braces it is the fields of the root.
        return json.dumps(self.as_plain_ordered_dict())[1:-1]

    @staticmethod
    def merge_configs(a: "ConfigTree", b: "ConfigTree", copy_trees: bool = False) -> "ConfigTree":
        """``b`` merged into ``a``: an object into an object key by key,
        anything else in place of what was there. ``copy_trees`` merges into
        copies of ``a``'s objects. Gives ``a``."""
        if a._as_written is not None or b._as_written is not None:
            # a document read with resolve=False is its text: the two texts,
            # one after the other, merge as two files do
            from .config_parser import as_written

            merged = as_written(a._hocon_text() + "\n" + b._hocon_text())
            a.clear()
            a.update(merged.items())
            a._as_written, a._unresolved = merged._as_written, merged._unresolved
            return a
        for key, value in b.items():
            mine = OrderedDict.get(a, key)
            if isinstance(mine, ConfigTree) and isinstance(value, ConfigTree):
                if copy_trees:
                    mine = a[key] = mine.copy()
                ConfigTree.merge_configs(mine, value, copy_trees)
            else:
                a[key] = value
        return a

    @staticmethod
    def parse_key(string: str) -> list[str]:
        """``a.b."c.d"`` as ``["a", "b", '"c.d"']``: a key keeps its quotes
        when it needs them."""
        return [key if _HAS_SPECIAL(key) else key.strip('"') for key in _PATH_KEY.findall(string)]

    def _get(self, path: list[str], default: Any = UndefinedKey) -> Any:
        self._check_resolved()
        node: Any = self
        for i, key in enumerate(path):
            if not isinstance(node, ConfigTree):
                if default is UndefinedKey:
                    raise ConfigWrongTypeException(f"{'.'.join(path[:i])} has type {type(node).__name__} rather than dict", name="WrongType")
                return default
            node = OrderedDict.get(node, key, UndefinedKey)
            if node is UndefinedKey:
                if default is UndefinedKey:
                    raise ConfigMissingException(f"No configuration setting found for key {'.'.join(path[: i + 1])}", name="Missing")
                return default
        # a copy, as pyhocon gives it
        return list(node) if isinstance(node, list) else node

    def put(self, key: str, value: Any, append: bool = False) -> None:
        """``value`` at ``key``, the objects on the way made where there are
        none. An object put on an object is merged into it; ``append=True``
        adds a list to the list there."""
        if isinstance(value, NoneValue):
            value = None
        path = self.parse_key(key)
        node = self
        for k in path[:-1]:
            child = OrderedDict.get(node, k)
            if not isinstance(child, ConfigTree):
                child = node[k] = ConfigTree()
            node = child
        last = path[-1]
        before = OrderedDict.get(node, last)
        if isinstance(before, ConfigTree) and isinstance(value, ConfigTree):
            if node.root:
                # the root's object is replaced, not changed: a tree that
                # was taken from it before stays as it was
                node[last] = ConfigTree.merge_configs(ConfigTree.merge_configs(ConfigTree(), before, True), value, True)
            else:
                ConfigTree.merge_configs(before, value)
        elif append and isinstance(before, list):
            node[last] = before + value
        elif append and before is not None:
            raise ConfigWrongTypeException(f"Cannot concatenate the list {key}: {value} to {before} of {type(before).__name__}", name="WrongType")
        else:
            node[last] = value

    def get(self, key: str, default: Any = UndefinedKey) -> Any:  # ty: ignore[invalid-method-override] - a path, as pyhocon has it
        """The value at ``key``; ``default`` when there is none, else
        ConfigMissingException. A list is a copy."""
        return self._get(self.parse_key(key), default)

    def pop(self, key: str, default: Any = UndefinedKey) -> Any:
        """The value at ``key``, taken out of its object; ``default`` when
        there is none, else ConfigMissingException."""
        if default is not UndefinedKey and key not in self:
            return default
        path = self.parse_key(key)
        value = self._get(path)
        del self._get(path[:-1])[path[-1]]
        return value

    def get_string(self, key: str, default: Any = UndefinedKey) -> str | None:
        """``str()`` of the value, a bool as ``true``/``false``; None for
        ``null``."""
        value = self.get(key, default)
        if value is None:
            return None
        return str(value).lower() if isinstance(value, bool) else str(value)

    def get_int(self, key: str, default: Any = UndefinedKey) -> int | None:
        """``int()`` of the value: ``"5"`` is 5 and ``1.5`` is 1. None for
        ``null``."""
        value = self.get(key, default)
        try:
            return int(value) if value is not None else None
        except (TypeError, ValueError):
            raise ConfigException(f"{key} has type '{type(value).__name__}' rather than 'int'", name="WrongType") from None

    def get_float(self, key: str, default: Any = UndefinedKey) -> float | None:
        """``float()`` of the value. None for ``null``."""
        value = self.get(key, default)
        try:
            return float(value) if value is not None else None
        except (TypeError, ValueError):
            raise ConfigException(f"{key} has type '{type(value).__name__}' rather than 'float'", name="WrongType") from None

    def get_bool(self, key: str, default: Any = UndefinedKey) -> bool | None:
        """``true``/``yes``/``on`` and ``false``/``no``/``off``, in any case.
        None for ``null``."""
        text = self.get_string(key, default)
        bools = {"true": True, "yes": True, "on": True, "false": False, "no": False, "off": False}
        if text is None:
            return None
        if text.lower() not in bools:
            raise ConfigException(f"{key} does not translate to a Boolean value", name="WrongType")
        return bools[text.lower()]

    def get_list(self, key: str, default: Any = UndefinedKey) -> list[Any] | None:
        """The list at ``key``. An object with whole-number keys is a list
        too, as the spec has it: in the order of the numbers, the other keys
        left out. None for ``null``."""
        value = self.get(key, default)
        if value is None or isinstance(value, list):
            return value
        if isinstance(value, ConfigTree):
            indexed = sorted(((int(k), v) for k, v in value.items() if k.isascii() and k.isdigit()), key=lambda kv: kv[0])
            if not indexed:
                raise ConfigException(f"{key} does not translate to a list", name="WrongType")
            return [v for _, v in indexed]
        raise ConfigException(f"{key} has type '{type(value).__name__}' rather than 'list'", name="WrongType")

    def get_config(self, key: str, default: Any = UndefinedKey) -> Any:
        """The object at ``key``, the tree itself and not a copy. None for
        ``null``."""
        value = self.get(key, default)
        if value is None or isinstance(value, dict):
            return value
        raise ConfigException(f"{key} has type '{type(value).__name__}' rather than 'config'", name="WrongType")

    def __getitem__(self, item: str) -> Any:
        return self.get(item)

    def __getattr__(self, item: str) -> Any:
        # copy and pickle look for their methods here
        if item.startswith("__"):
            raise AttributeError(item)
        value = self.get(item, NonExistentKey)
        if value is NonExistentKey:
            raise AttributeError(item)
        return value

    def __contains__(self, item: object) -> bool:
        return isinstance(item, str) and self._get(self.parse_key(item), NoneValue) is not NoneValue

    def with_fallback(self, config: "ConfigTree | Path", resolve: bool = True) -> "ConfigTree":
        """A new tree: ``config`` (a tree, or the name of a file) with this
        one over it, merged as two files one after the other, and resolved
        unless ``resolve=False``: a ``${…}`` here can take its value from
        ``config``."""
        from .config_parser import ConfigFactory

        fallback = config if isinstance(config, ConfigTree) else ConfigFactory.parse_file(config, resolve=False)
        # Both resolved: merged here, so a value put() in keeps its type, a
        # timedelta or the text "00123". A ${…} left to resolve needs the text.
        if fallback._as_written is None and self._as_written is None:
            return ConfigTree.merge_configs(copy.deepcopy(fallback), copy.deepcopy(self))
        return ConfigFactory.parse_string(fallback._hocon_text() + "\n" + self._hocon_text(), None, resolve)

    def as_plain_ordered_dict(self) -> "OrderedDict[str, Any]":
        """A deep copy as OrderedDicts and lists, keys without their quotes."""
        self._check_resolved()

        def plain(value: Any) -> Any:
            if isinstance(value, ConfigTree):
                return value.as_plain_ordered_dict()
            if isinstance(value, list):
                return [plain(v) for v in value]
            return value

        return OrderedDict((key.strip('"'), plain(value)) for key, value in self.items())
