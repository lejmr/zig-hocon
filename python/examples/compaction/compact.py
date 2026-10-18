"""Compacts a leaf into one file to deploy:

    python compact.py conf/prod/app.conf build/prod.conf

Read with env=KEEP, the leaf is worked out — includes, overrides, `+=`,
every substitution the files answer — and only what waits for the machine's
environment stays as written: `${?PORT}`, `${DB_HOST}`. to_hocon() writes
that as one file with no include in it. Where it runs, the service reads it
with its environment, as it would have read the leaf.
"""

import pathlib
import sys

import zig_hocon


def compact(leaf, out):
    conf = zig_hocon.ConfigFactory.parse_file(leaf, env=zig_hocon.KEEP)
    pathlib.Path(out).write_text(conf.to_hocon(), encoding="utf-8")


if __name__ == "__main__":
    compact(sys.argv[1], sys.argv[2])
