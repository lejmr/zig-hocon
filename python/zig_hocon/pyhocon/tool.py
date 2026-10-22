"""pyhocon's command line, ``python -m zig_hocon.pyhocon.tool``: a file, or
stdin, as JSON, HOCON, YAML or a .properties file. zig-hocon's own is
``python -m zig_hocon``.

Changed from pyhocon's tool.py (Apache-2.0, LICENSE in this directory):
its options, over this module's converter."""

import argparse
import logging
from collections.abc import Sequence

from .converter import HOCONConverter

__all__ = ["HOCONConverter", "main"]

LOG_FORMAT = "%(asctime)s %(levelname)s: %(message)s"


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="pyhocon tool")
    parser.add_argument("-i", "--input", help="input file")
    parser.add_argument("-o", "--output", help="output file")
    parser.add_argument("-c", "--compact", action="store_true", default=False, help="compact format")
    parser.add_argument("-f", "--format", help="output format: json, properties, yaml or hocon", default="json")
    parser.add_argument("-n", "--indent", help="indentation step (default is 2)", default=2, type=int)
    parser.add_argument("-v", "--verbosity", action="count", default=0, help="increase output verbosity")
    args = parser.parse_args(argv)
    if args.verbosity:
        handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter(LOG_FORMAT))
        logging.getLogger().addHandler(handler)
        logging.getLogger().setLevel({1: logging.ERROR, 2: logging.INFO}.get(args.verbosity, logging.DEBUG))
    HOCONConverter.convert_from_file(args.input, args.output, args.format.lower(), args.indent, args.compact)


if __name__ == "__main__":  # pragma: no cover
    main()
