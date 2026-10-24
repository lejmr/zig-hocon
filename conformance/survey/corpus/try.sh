#!/bin/bash
# usage: try.sh 'hocon text'  -> runs it through several impls
export PATH=/tmp/tools/jdk-21.0.13+9/bin:$PATH
d=$(mktemp -d /tmp/try.XXXX); printf '%b' "$1" > $d/main.conf
z=$(/tmp/zh-main/zig-out/bin/hocon --json $d/main.conf 2>&1 | head -c 300 | tr '\n' ' ')
j=$(echo $d/main.conf | java -cp /tmp/zh-main/tools/oracle/config-1.4.9.jar:/workspace/corpus Batch | cut -f2- | head -c 300)
B=/workspace/conformance-adapters/bin
m=$($B/lightbend-main.sh $d/main.conf 2>&1 | head -c 300 | tr '\n' ' ')
s=$($B/sconfig.sh $d/main.conf 2>&1 | head -c 300 | tr '\n' ' ')
p=$($B/pyhocon.sh $d/main.conf 2>&1 | tr -d '\n ' | head -c 300)
printf 'IN   %q\nzig  %s\nj149 %s\njmain %s\nsconf %s\npyh  %s\n' "$1" "$z" "$j" "$m" "$s" "$p"
rm -rf $d
