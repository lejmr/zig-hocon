#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: ekrich/sconfig 2.1.0 (Scala port of typesafe/config)
[ "${1:-}" = "--version" ] && { echo "sconfig 2.1.0"; exit 0; }
exec timeout 30 java -cp "$A/sconfig/scala-collection-compat_3-2.13.0.jar:$A/sconfig/scala-library-3.9.0.jar:$A/sconfig/scala3-library_3-3.9.0.jar:$A/sconfig/sconfig_3-2.1.0.jar:$A/sconfig" SconfigAdapter "$1"
