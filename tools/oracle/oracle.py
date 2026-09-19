"""pyhocon oracle — mirrors Oracle.java's input and output format.

Reads one escaped test case per line on stdin, prints one result line each:
compact JSON, or "ERROR <Class>: <message>". Substitutions stay unresolved
unless the line starts with "resolve:".
"""

import json
import sys

from pyhocon import ConfigFactory
from pyhocon.converter import HOCONConverter


def run(src, resolve, path=None):
    try:
        cfg = (ConfigFactory.parse_file(path, resolve=resolve) if path
               else ConfigFactory.parse_string(src, resolve=resolve))
        # compact, source order — matches ConfigRenderOptions.concise()
        return json.dumps(json.loads(HOCONConverter.to_json(cfg)), separators=(",", ":"))
    except Exception as e:
        # pyparsing dumps its whole grammar into the message; the class name and
        # the first line are the only parts worth diffing against Java.
        msg = " ".join(str(e).split())  # one line out per line in, whatever pyparsing dumps
        if len(msg) > 120:
            msg = msg[:120] + "…"
        return "ERROR {}: {}".format(type(e).__name__, msg)


for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    resolve = line.startswith("resolve:")
    if resolve:
        line = line[len("resolve:"):]
    if line.startswith("file:"):
        # a path, not source: parse in place so includes resolve next to the file
        print(run(None, resolve, path=line[len("file:"):]))
    else:
        print(run(line.encode().decode("unicode_escape"), resolve))
