"""Writes HOCON files of growing size for tools/bench/run.sh.

    python3 gen.py <out-dir> <size-in-bytes>...

Deterministic: the same size always gives the same file. The content is what a
service config looks like — nested objects, dotted keys, arrays, quoted and
unquoted strings, numbers, booleans, comments and a later block that merges into
an earlier one — and nothing zig-hocon cannot do yet: no substitutions, no
includes. The three parsers must agree on every file, and run.sh checks that.
"""
import pathlib
import sys

BLOCK = """\
# service {i}
service-{i} {{
  name = "service-{i}"
  enabled = true
  port = {port}
  timeout = 2.5
  hosts = ["h1.example.org", "h2.example.org", "h3.example.org"]
  tags = [alpha, beta, gamma]
  db {{
    url = "jdbc:postgresql://db-{i}.example.org:5432/app"
    pool.size = 10
    pool.timeout-ms = 3000
  }}
  description = the dog ate my homework again
  limits {{ cpu = 0.5, memory = 512 }}
}}
"""
OVERRIDE = "service-{i}.db.pool.size = 20\nservice-{i} {{ enabled = false }}\n"


def config(size):
    parts, total, i = [], 0, 0
    while total < size:
        chunk = BLOCK.format(i=i, port=8000 + i % 1000)
        if i % 10 == 9:
            chunk += OVERRIDE.format(i=i - 5)
        parts.append(chunk)
        total += len(chunk)
        i += 1
    return "".join(parts)


if __name__ == "__main__":
    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for arg in sys.argv[2:]:
        (out / "{}.conf".format(arg)).write_text(config(int(arg)))
