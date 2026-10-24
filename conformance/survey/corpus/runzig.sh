#!/bin/sh
p="$1"
cd "$(dirname "$p")"
out=$(timeout 10 /tmp/zh-main/zig-out/bin/hocon --json "$p" 2>/tmp/zigerr.$$); st=$?
if [ $st -eq 0 ]; then printf '%s\t%s\n' "$p" "$out"; else printf '%s\tERROR(%s) %s\n' "$p" "$st" "$(head -c 200 /tmp/zigerr.$$ | tr '\n\t' '  ')"; fi
rm -f /tmp/zigerr.$$
