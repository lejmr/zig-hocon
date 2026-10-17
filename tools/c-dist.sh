#!/bin/sh
# libhocon for C, one zip per platform: the shared library, include/hocon.h,
# the licence and how to build against it. The same seven targets as the
# Python wheels, pinned to the same oldest systems (macOS 13, glibc 2.17).
#
#   tools/c-dist.sh <version> <out dir>
#
# Each zip unpacks into libhocon-<version>-<platform>/ with include/ and lib/
# (bin/ for the Windows DLL, with its import library in lib/).
set -eu
version=$1
out=$(mkdir -p "$2" && cd "$2" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for row in \
    aarch64-macos.13.0:macos-arm64 \
    x86_64-macos.13.0:macos-x86_64 \
    x86_64-linux-gnu.2.17:linux-x86_64-gnu \
    aarch64-linux-gnu.2.17:linux-aarch64-gnu \
    x86_64-linux-musl:linux-x86_64-musl \
    aarch64-linux-musl:linux-aarch64-musl \
    x86_64-windows:windows-x86_64; do
    target=${row%%:*}
    name=libhocon-$version-${row#*:}
    (cd "$root" && zig build lib -Dtarget="$target" -Doptimize=ReleaseSafe -p "$work/$name")
    cp "$root/LICENSE" "$work/$name/"
    cat > "$work/$name/README.txt" <<TXT
libhocon $version, zig-hocon's HOCON parser behind a C ABI.
https://github.com/lejmr/zig-hocon

include/hocon.h is the documentation: parse a file or a string, read values
by path, write a subtree as JSON or HOCON, and errors with file, line and
column. Build against it with

    cc app.c -Iinclude -Llib -lhocon

and put the library where your program finds it at run time (next to it,
on the rpath, or LD_LIBRARY_PATH / DYLD_LIBRARY_PATH / PATH).
TXT
    (cd "$work" && python3 -m zipfile -c "$out/$name.zip" "$name")
    echo "$out/$name.zip"
done
