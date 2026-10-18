"""How much of src/ is written by hand, part by part, for a release's notes.

    python3 tools/authorship.py [<ref>]

`git blame` over the lines that are not empty, each counted by who wrote the
commit it comes from: a commit with Claude as co-author is AI's, any other the
maintainer's. Moved code stays its author's: blame follows lines across files
and commits (-M, -C -C -C), skips the commits that only moved code (MOVES), and
the lines those commits added themselves, imports and the like, count for
neither. Only code: the `test` blocks are left out, most of them written
with AI and committed by hand, which git cannot tell. Its last row is the
conformance suite's score against the spec. Prints the paragraph and the table
CHANGELOG.md has under 0.1.0 to 0.4.0.
"""

import re
import subprocess
import sys

ref = sys.argv[1] if len(sys.argv) > 1 else "HEAD"

# The first commit of the tokenizer carries a co-author, the code in it is the
# maintainer's.
HAND = {"b005782"}

# Commits that only moved code into other files.
MOVES = ["e74fadb", "bd8e062"]

# A file belongs to the first part one of its prefixes starts. table.zig is a
# test helper, in no part.
PARTS = [
    ("Tokenizer", ["src/Tokenizer.zig"]),
    ("AST", ["src/Ast.zig", "src/Key.zig", "src/utils/"]),
    ("Value", ["src/Value", "src/Include.zig"]),
    ("Config", ["src/Config.zig", "src/units/"]),
    ("API and CLI", ["src/root.zig", "src/main.zig", "src/check.zig", "src/capi.zig", "src/stringify.zig", "src/Diagnostics.zig"]),
]


def git(*args, check=True):
    result = subprocess.run(["git", *args], capture_output=True, text=True)
    if check:
        result.check_returncode()
    return result.stdout if result.returncode == 0 else None


ai = set()
for line in git("log", ref, "--format=%H %(trailers:key=Co-Authored-By,valueonly,separator=;)").splitlines():
    sha, _, coauthors = line.partition(" ")
    if "Claude" in coauthors and sha[:7] not in HAND:
        ai.add(sha)
moves = {git("rev-parse", sha).strip() for sha in MOVES if git("merge-base", "--is-ancestor", sha, ref, check=False) == ""}
ignore = [arg for sha in moves for arg in ("--ignore-rev", sha)]

counts = {name: [0, 0] for name, _ in PARTS}  # [hand, ai]
for path in git("ls-tree", "-r", "--name-only", ref, "src").split():
    part = next((name for name, prefixes in PARTS if path.endswith(".zig") and path.startswith(tuple(prefixes))), None)
    if part is None:
        continue
    sha, in_test = None, False
    for line in git("blame", "-w", "-M", "-C", "-C", "-C", *ignore, "--line-porcelain", ref, "--", path).splitlines():
        if re.match(r"[0-9a-f]{40} ", line):
            sha = line[:40]
        elif line.startswith("\t"):
            text = line[1:]
            # zig fmt closes a top-level block with `}` alone in the first column.
            in_test = in_test or re.match(r"test\b", text) is not None
            if text.strip() and not in_test and sha not in moves:
                counts[part][sha in ai] += 1
            if text == "}":
                in_test = False


def share(hand, by_ai):
    return f"{round(100 * hand / (hand + by_ai))} %"


total = [sum(c[0] for c in counts.values()), sum(c[1] for c in counts.values())]
print("How much of the code in `src/` is written by hand, the rest with AI,")
print("counted with `git blame` over the lines that are not empty, by who wrote")
print("the commit each line comes from; moved code stays its author's. The tests")
print("are left out: most of them are written with AI.")
print()
print("| | share |")
print("|---|---|")
for name, _ in PARTS:
    print(f"| {name} | {share(*counts[name])} |")
print(f"| all of `src/` | {share(*total)} of {sum(total)} lines |")
# The suite's score against the spec, as the README's generated table has it.
passed, cases = re.search(r"^\| zig-hocon .*? \| \d+% \((\d+)/(\d+)\)", git("show", f"{ref}:README.md"), re.M).groups()
print(f"| conformance to the spec | {share(int(passed), int(cases) - int(passed))} ({passed} of {cases} tests) |")
