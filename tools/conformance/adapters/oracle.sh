#!/bin/sh
# Adapter: makes any of the reference oracles satisfy the run.sh contract.
#
#   tools/conformance/run.sh --spec -- tools/conformance/adapters/oracle.sh hocon-java
#   tools/conformance/run.sh --spec -- tools/conformance/adapters/oracle.sh hocon-py
#   tools/conformance/run.sh --java -- tools/conformance/adapters/oracle.sh hocon-py
#   tools/conformance/run.sh --spec -- tools/conformance/adapters/oracle.sh \
#       rust-oracle/target/release/rust-oracle
#
# run.sh appends the case file to whatever command it is given, so the oracle
# name rides along as an ordinary argument. The name is a path under
# tools/oracle/.
#
# An adapter is about this long. Yours does the same for your parser: take a
# path, print compact JSON, exit non-zero when you reject the input.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ORACLE="$HERE/../../oracle/$1"
shift

[ -x "$ORACLE" ] || { echo "no oracle at $ORACLE" >&2; exit 2; }
[ "${1:-}" = "--version" ] && exec "$ORACLE" --version

# the oracles speak one escaped case per line, so fold the file into one
line=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import suite; print("resolve:" + suite.encode(open(sys.argv[2]).read()))' "$HERE/.." "$1")

out=$(printf '%s\n' "$line" | "$ORACLE")
case "$out" in ERROR*) printf '%s\n' "$out" >&2; exit 1 ;; esac
printf '%s\n' "$out"
