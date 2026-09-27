"""Writes HOCON files of growing size for tools/bench/run.sh.

    python3 gen.py [--refs] <out-dir> <size-in-bytes>...

Deterministic: the same size always gives the same file. The content is what a
service config looks like — nested objects, dotted keys, arrays, quoted and
unquoted strings, numbers, booleans, comments and a later block that merges into
an earlier one — and nothing zig-hocon cannot do yet: no substitutions, no
includes. The three parsers must agree on every file, and run.sh checks that.

--refs writes the same services with substitutions in them, for measuring
resolve: values taken from a shared `defaults` block, a list and a string built
around a ref, a whole object copied, and a ref into the service before, which
is itself a ref, so they chain.
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
DEFAULTS = """\
defaults {
  timeout = 2.5
  hosts = ["h1.example.org", "h2.example.org", "h3.example.org"]
  retry { attempts = 3, backoff-ms = 200 }
}
"""
REFS_BLOCK = """\
# service {i}
service-{i} {{
  name = "service-{i}"
  enabled = true
  port = {port}
  timeout = ${{defaults.timeout}}
  hosts = ${{defaults.hosts}} ["h4.example.org"]
  tags = [alpha, beta, gamma]
  host = "db-{i}.example.org"
  db {{
    url = "jdbc:postgresql://"${{service-{i}.host}}":5432/app"
    pool.size = 10
    pool.timeout-ms = 3000
  }}
  retry = ${{defaults.retry}}
  upstream = ${{service-{prev}.db.url}}
  description = the dog ate my homework again
  limits {{ cpu = 0.5, memory = 512 }}
}}
"""
OVERRIDE = "service-{i}.db.pool.size = 20\nservice-{i} {{ enabled = false }}\n"


def config(size, refs):
    parts, total, i = ([DEFAULTS], len(DEFAULTS), 0) if refs else ([], 0, 0)
    while total < size:
        block = REFS_BLOCK if refs else BLOCK
        chunk = block.format(i=i, port=8000 + i % 1000, prev=max(i - 1, 0))
        if i % 10 == 9:
            chunk += OVERRIDE.format(i=i - 5)
        parts.append(chunk)
        total += len(chunk)
        i += 1
    return "".join(parts)


if __name__ == "__main__":
    args = sys.argv[1:]
    refs = args[0] == "--refs"
    if refs:
        args = args[1:]
    out = pathlib.Path(args[0])
    out.mkdir(parents=True, exist_ok=True)
    for arg in args[1:]:
        (out / "{}.conf".format(arg)).write_text(config(int(arg), refs))
