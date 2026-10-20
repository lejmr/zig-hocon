"""pyhocon's ``HOCONConverter``: a ConfigTree as JSON, HOCON, YAML or a
.properties file, in pyhocon's layout to the character."""

import datetime
import json
import re
import sys
from typing import Any

from .config_parser import ConfigFactory, Path
from .config_tree import ConfigTree

__all__ = ["HOCONConverter"]


def _ms(value: datetime.timedelta) -> str:
    """A timedelta put in a tree, as pyhocon writes it: milliseconds."""
    return str(int(value.total_seconds() * 1000))


def _hocon_duration(value: datetime.timedelta) -> str:
    if value.days > 0:
        return f"{value.days} days"
    if value.seconds > 0:
        return f"{value.seconds} seconds"
    if value.microseconds > 0:
        return f"{value.microseconds} microseconds"
    return "0 seconds"


def _scalar(value: Any) -> str:
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    return str(value)


class HOCONConverter:
    """Writes a ConfigTree out, as pyhocon's converter."""

    _ESCAPES = {"\b": r"\b", "\t": r"\t", "\n": r"\n", "\f": r"\f", "\r": r"\r", '"': r"\"", "\\": r"\\"}

    @classmethod
    def to_json(cls, config: Any, compact: bool = False, indent: int = 2, level: int = 0) -> str:
        """JSON, ``indent`` spaces a level. ``compact`` is pyhocon's and
        changes nothing."""
        pad, inner = " " * (level * indent), " " * ((level + 1) * indent)
        if isinstance(config, ConfigTree):
            if not config:
                return "{}"
            fields = (f'{inner}"{key.strip(chr(34))}": {cls.to_json(item, compact, indent, level + 1)}' for key, item in config.items())
            return "{\n" + ",\n".join(fields) + f"\n{pad}}}"
        if isinstance(config, list):
            if not config:
                return "[]"
            return "[\n" + ",\n".join(f"{inner}{cls.to_json(item, compact, indent, level + 1)}" for item in config) + f"\n{pad}]"
        if isinstance(config, datetime.timedelta):
            return _ms(config)
        if isinstance(config, str):
            return json.dumps(config, ensure_ascii=False)
        return _scalar(config)

    @classmethod
    def to_hocon(cls, config: Any, compact: bool = False, indent: int = 2, level: int = 0) -> str:
        """HOCON, ``indent`` spaces a level; ``compact`` writes an object of
        one key as a path, ``a.b.c = 1``."""
        if isinstance(config, ConfigTree):
            if not config:
                return "{}"
            fields = []
            for key, item in config.items():
                full_key = key
                while compact and isinstance(item, ConfigTree) and len(item) == 1:
                    key, item = next(iter(item.items()))
                    full_key += "." + key
                sign = "" if isinstance(item, dict) else " ="
                fields.append(f"{' ' * (level * indent)}{full_key}{sign} {cls.to_hocon(item, compact, indent, level + 1)}")
            body = "\n".join(fields)
            # the root has no braces
            return body if level == 0 else "{\n" + body + f"\n{' ' * ((level - 1) * indent)}}}"
        if isinstance(config, list):
            if not config:
                return "[]"
            items = "\n".join(f"{' ' * (level * indent)}{cls.to_hocon(item, compact, indent, level + 1)}" for item in config)
            return "[\n" + items + f"\n{' ' * ((level - 1) * indent)}]"
        if isinstance(config, str):
            if "\n" in config and len(config) > 1:
                return f'"""{config}"""'
            return '"' + cls._escape_string(config) + '"'
        if isinstance(config, datetime.timedelta):
            return _hocon_duration(config)
        return _scalar(config)

    @classmethod
    def to_yaml(cls, config: Any, compact: bool = False, indent: int = 2, level: int = 0) -> str:
        """YAML, ``indent`` spaces a level; a ``null`` in a list is left out.
        ``compact`` is pyhocon's and changes nothing."""
        pad = " " * (level * indent)
        if isinstance(config, ConfigTree):
            if not config:
                return ""
            fields = "\n".join(f"{pad}{key.strip(chr(34))}: {cls.to_yaml(item, compact, indent, level + 1)}" for key, item in config.items())
            return ("\n" if level > 0 else "") + fields
        if isinstance(config, list):
            items = [item for item in config if item is not None]
            if not items:
                return "[]"
            return "\n" + "\n".join(f"{pad}- {cls.to_yaml(item, compact, indent, level + 1)}" for item in items)
        if isinstance(config, datetime.timedelta):
            return _ms(config)
        if isinstance(config, str):
            lines = config.split("\n")
            if len(lines) == 1:
                return config
            return "|\n" + "\n".join(line.rjust(level * indent, " ") for line in lines)
        return _scalar(config)

    @classmethod
    def to_properties(cls, config: Any, compact: bool = False, indent: int = 2, key_stack: list[str] | None = None) -> str:
        """A .properties file: ``a.b = 1``, a list's items as ``a.0``;
        ``null`` left out. ``compact`` and ``indent`` are pyhocon's and
        change nothing."""
        keys = [key.strip('"') for key in key_stack or []]
        if isinstance(config, ConfigTree):
            lines = [cls.to_properties(item, compact, indent, keys + [key]) for key, item in config.items() if item is not None]
        elif isinstance(config, list):
            lines = [cls.to_properties(item, compact, indent, keys + [str(i)]) for i, item in enumerate(config) if item is not None]
        elif config is None:
            lines = []
        elif isinstance(config, datetime.timedelta):
            lines = [".".join(keys) + " = " + _ms(config)]
        elif isinstance(config, str):
            escaped = config.replace("=", "\\=").replace("!", "\\!").replace("#", "\\#").replace("\n", "\\\n")
            lines = [".".join(keys) + " = " + escaped]
        else:
            lines = [".".join(keys) + " = " + _scalar(config)]
        return "\n".join(line for line in lines if line)

    @classmethod
    def convert(cls, config: Any, output_format: str = "json", indent: int = 2, compact: bool = False) -> str:
        """``config`` in ``output_format``: ``json``, ``properties``,
        ``yaml`` or ``hocon``."""
        if output_format == "json":
            return cls.to_json(config, compact, indent)
        if output_format == "properties":
            return cls.to_properties(config, compact, indent)
        if output_format == "yaml":
            return cls.to_yaml(config, compact, indent)
        if output_format == "hocon":
            return cls.to_hocon(config, compact, indent)
        raise Exception(f"Invalid format '{output_format}'. Format must be 'json', 'properties', 'yaml' or 'hocon'")

    @classmethod
    def convert_from_file(
        cls, input_file: Path | None = None, output_file: Path | None = None, output_format: str = "json", indent: int = 2, compact: bool = False
    ) -> None:
        """Reads ``input_file`` (stdin without one) and writes it in
        ``output_format`` to ``output_file`` (stdout without one)."""
        config = ConfigFactory.parse_string(sys.stdin.read()) if input_file is None else ConfigFactory.parse_file(input_file)
        res = cls.convert(config, output_format, indent, compact)
        if output_file is None:
            print(res)
        else:
            with open(output_file, "w") as fd:
                fd.write(res)

    @classmethod
    def _escape_string(cls, string: str) -> str:
        return re.sub(r'[\x00-\x1F"\\]', lambda m: cls._ESCAPES.get(m.group(0)) or rf"\u{ord(m.group(0)):04x}", string)
