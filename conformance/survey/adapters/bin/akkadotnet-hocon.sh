#!/bin/sh
A=$(cd "$(dirname "$0")/.." && pwd)   # conformance/survey/adapters; artifacts are built in place
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)   # the repository
TOOLS=${TOOLS:-/tmp/tools}  IMPL=${IMPL:-/tmp/impl}   # toolchains, upstream clones
# adapter: akkadotnet/HOCON (NuGet Hocon 2.0.4)
[ "${1:-}" = "--version" ] && { echo "Hocon (akkadotnet) 2.0.4"; exit 0; }
DOTNET_ROOT=$TOOLS/dotnet DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 exec timeout 30 $TOOLS/dotnet/dotnet $A/dotnet/out/HoconAdapter.dll "$1"
