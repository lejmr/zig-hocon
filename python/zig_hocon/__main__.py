"""``python -m zig_hocon [--hocon | --json] [--env=process|none|keep] <file.conf>``
``python -m zig_hocon migrate [--help] <conf/>``

The file resolved, as the ``hocon`` CLI prints it: HOCON by default, or
compact JSON; an error goes to stderr with exit 1. Through this package and
libhocon, so the conformance suite can measure them
(conformance/adapters/zig-hocon-python.sh).
"""

import argparse
import os
import sys

from zig_hocon import KEEP, ConfigException, ConfigFactory

# A file named migrate is ./migrate.
if sys.argv[1:2] == ["migrate"]:
    from zig_hocon.migrate import main

    sys.exit(main(sys.argv[2:]))

parser = argparse.ArgumentParser(prog="python -m zig_hocon", epilog="python -m zig_hocon migrate <conf/> shows how pyhocon and zig-hocon read your configs")
output = parser.add_mutually_exclusive_group()
output.add_argument("--hocon", action="store_true", help="print HOCON (the default)")
output.add_argument("--json", action="store_true", help="print compact JSON")
parser.add_argument("--env", choices=["process", "none", "keep"], default="process")
parser.add_argument("file")
args = parser.parse_args()

try:
    conf = ConfigFactory.parse_file(args.file, env={"process": os.environ, "none": None, "keep": KEEP}[args.env])
    out = conf.to_json() + b"\n" if args.json else conf.to_hocon().encode("utf-8", "surrogatepass")
except ConfigException as e:
    sys.exit(f"error: {e}")

# A closed stdout is None, a pipe whose reader has gone an OSError: the CLI's
# error for both. Python flushes stdout once more at exit; devnull keeps that quiet.
try:
    sys.stdout.buffer.write(out)
    sys.stdout.flush()
except (OSError, AttributeError):
    os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
    sys.exit(f"error: {args.file}: WriteFailed")
