"""pyhocon's exceptions, which are zig_hocon's: one ``except`` catches
either module's."""

from ..exceptions import (
    ConfigException,
    ConfigMissingException,
    ConfigParseException,
    ConfigSubstitutionException,
    ConfigWrongTypeException,
)

__all__ = [
    "ConfigException",
    "ConfigMissingException",
    "ConfigParseException",
    "ConfigSubstitutionException",
    "ConfigWrongTypeException",
]
