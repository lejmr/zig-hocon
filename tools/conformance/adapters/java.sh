#!/bin/sh
# Reference adapter: makes typesafe/config satisfy the run.sh contract.
#
# An adapter should be about this long. Yours does the same for your parser:
# take a path, print compact JSON, exit non-zero when you reject the input.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
DIR=$(cd "$HERE/../../.." && pwd)

[ "${1:-}" = "--version" ] && exec "$DIR/tools/oracle/hocon-java" --version

# the oracle speaks one escaped case per line, so fold the file into one
line=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import suite; print("resolve:" + suite.encode(open(sys.argv[2]).read()))' "$HERE/.." "$1")

out=$(printf '%s\n' "$line" | "$DIR/tools/oracle/hocon-java")
case "$out" in ERROR*) printf '%s\n' "$out" >&2; exit 1 ;; esac
printf '%s\n' "$out"
