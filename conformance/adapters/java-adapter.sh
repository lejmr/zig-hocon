#!/bin/sh
# HOCON conformance suite adapter for any config jar: set CONFIG_JAR to a
# typesafe/config or sconfig jar, then run `java-adapter.sh file.conf`.
# Output: the resolved config as compact JSON (exit 0) or a reject (exit 1).
set -e
: "${CONFIG_JAR:?usage: CONFIG_JAR=/path/to/config.jar $0 file.conf}"
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cache=${CONFIG_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/hocon-java-adapter}/$(printf '%s' "$CONFIG_JAR" | tr -c 'A-Za-z0-9._-' '_' | cut -c 1-96)
mkdir -p "$cache"
main="$cache/main"
if [ ! -f "$main" ] || [ "$dir/Adapter.java" -nt "$main" ] || [ "$dir/AdapterSconfig.java" -nt "$main" ]; then
    rm -f "$main"
    if javac -cp "$CONFIG_JAR" -d "$cache" "$dir/Adapter.java" 2>/dev/null; then
        echo Adapter > "$main"
    else
        echo AdapterSconfig > "$main"
        javac -cp "$CONFIG_JAR" -d "$cache" "$dir/AdapterSconfig.java"
    fi
fi
exec java -cp "$cache:$CONFIG_JAR" "$(cat "$main")" "$@"
