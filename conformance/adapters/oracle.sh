#!/bin/sh
# Adapter: makes any of the reference oracles satisfy the run.sh contract.
#
#   conformance/run.sh --spec -- conformance/adapters/oracle.sh hocon-java
#   conformance/run.sh --spec -- conformance/adapters/oracle.sh hocon-py
#   conformance/run.sh --java -- conformance/adapters/oracle.sh hocon-py
#   conformance/run.sh --spec -- conformance/adapters/oracle.sh \
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
ORACLE="$HERE/../../tools/oracle/$1"
shift

[ -x "$ORACLE" ] || { echo "no oracle at $ORACLE" >&2; exit 2; }
[ "${1:-}" = "--version" ] && exec "$ORACLE" --version

# the oracles speak one escaped case per line, so fold the file into one; a
# directory case is sent by path instead, so its includes resolve beside it
case "$1" in
    */main.conf) line="resolve:file:$(cd "$(dirname "$1")" && pwd)/main.conf" ;;
    *) line=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import suite; print("resolve:" + suite.encode(open(sys.argv[2], newline="").read()))' "$HERE/../maintaining" "$1") ;;
esac

# pyhocon loops forever on some hidden-substitution inputs; a hang counts as a
# rejection. ponytail: perl alarm, since macOS ships no timeout(1)
out=$(printf '%s\n' "$line" | perl -e 'alarm 30; exec @ARGV' "$ORACLE")
case "$out" in ERROR*) printf '%s\n' "$out" >&2; exit 1 ;; esac
printf '%s\n' "$out"
