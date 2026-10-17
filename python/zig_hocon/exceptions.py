"""What the library refuses, as pyhocon names it (``pyhocon.exceptions``)."""

import os
from typing import TypeVar

from ._capi import Error

__all__ = [
    "ConfigException",
    "ConfigMissingException",
    "ConfigParseException",
    "ConfigSubstitutionException",
    "ConfigWrongTypeException",
]


class ConfigException(Exception):
    """Anything the library refuses. ``name`` is the error's own name
    (``Unresolved``, ``UnexpectedToken``); an error in a file also has
    ``file``, ``line``, ``column`` (1-based, in characters) and
    ``source_line``, and its message shows the line with a caret under the
    column."""

    def __init__(
        self,
        message: str,
        name: str | None = None,
        file: str | None = None,
        line: int | None = None,
        column: int | None = None,
        source_line: str | None = None,
    ) -> None:
        super().__init__(message)
        self.name = name
        self.file = file
        self.line = line
        self.column = column
        self.source_line = source_line

    # KeyError, a base of ConfigMissingException, would print the message quoted.
    def __str__(self) -> str:
        return str(self.args[0])


class ConfigParseException(ConfigException):
    """The text is not valid HOCON, or an include failed."""


class ConfigSubstitutionException(ConfigException):
    """A ``${…}`` with no value or in a cycle; or one that is still there,
    read with ``resolve=False`` or ``env=KEEP``, where a value is needed."""


class ConfigMissingException(ConfigException, KeyError):
    """Nothing at the path, or ``null`` there."""


class ConfigWrongTypeException(ConfigException, ValueError):
    """The value is there and is not what was asked for. A ValueError too, so
    pydantic and msgspec report it as a validation error."""


_E = TypeVar("_E", bound=ConfigException)


def name_of(err: Error) -> str:
    """The error's name; static in the library, there whenever it failed."""
    return (err.name or b"").decode()


def placed(cls: type[_E], err: Error, said: str) -> _E:
    """``cls`` for an error with a place: `app.conf:7:12: <said>`, the line,
    and a caret under the column."""
    file = os.fsdecode(err.file or b"")
    source_line = (err.source_line or b"").decode("utf-8", "replace")
    # As the CLI prints it: a tab or a control character would move the text
    # and leave the caret behind, so each is one space.
    shown = "".join(" " if c < " " or c == "\x7f" else c for c in source_line)
    where = f"{file}:" if file else ""
    message = f"{where}{err.line}:{err.column}: {said}\n{shown}\n{' ' * (err.column - 1)}^"
    return cls(message, name=name_of(err), file=file, line=err.line, column=err.column, source_line=source_line)
