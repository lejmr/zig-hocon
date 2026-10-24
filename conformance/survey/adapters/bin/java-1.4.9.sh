#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# the repo oracle (typesafe/config 1.4.9 via tools/oracle/hocon-java), with stdout forced to UTF-8 (run.sh env -i drops the locale on Linux)
PATH=$A/javashim:$PATH exec $ROOT/conformance/adapters/oracle.sh hocon-java "$@"
