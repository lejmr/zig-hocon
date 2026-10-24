#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: py.hocon — run.sh contract (path in, compact JSON out, non-zero on rejection)
[ "${1:-}" = "--version" ] && { echo "hocon-parser 1.14.2 (Python, o3co/py.hocon)"; exit 0; }
exec timeout 30 $A/py-adapters/venv-o3/bin/python $A/py-adapters/adapters/o3co_py_adapter.py "$1"
