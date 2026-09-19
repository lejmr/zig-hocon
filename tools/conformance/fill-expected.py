"""Stage 3: fill `expect` (or `error`) into every sidecar that lacks one.

Reads each conformance case, runs it through tools/oracle/hocon-java, and writes
the oracle's answer back. Never invents a value; a case it cannot feed to the
oracle is reported and left alone.

    python3 tools/conformance/fill-expected.py [--check] [<dir>...]

--check writes nothing and exits non-zero if any sidecar is out of date, which
is what CI and the Zig test step should call.
"""

import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
ORACLE = ROOT / "tools" / "oracle" / "hocon-java"


def encode(src):
    # the wrappers drop blank input lines, so an empty document has to travel as
    # whitespace — same parse, and it keeps one line in == one line out
    # ponytail: only empty-vs-whitespace is affected; fix the wrappers if a case
    # ever needs to distinguish them
    if not src.strip():
        src = " " + src.lstrip("\n")
    # the oracle protocol is one case per line, with \n \t \" escaped
    return src.replace("\\", "\\\\").replace("\t", "\\t").replace('"', '\\"').replace("\n", "\\n")


def is_json(s):
    try:
        json.loads(s)
        return True
    except json.JSONDecodeError:
        return False


def ask(lines):
    out = subprocess.run(
        [str(ORACLE)], input="\n".join(lines) + "\n",
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    if len(out) != len(lines):
        sys.exit("oracle returned {} lines for {} cases".format(len(out), len(lines)))
    return out


def main(argv):
    check = "--check" in argv
    targets = [a for a in argv if not a.startswith("--")] or ["conformance"]

    cases = sorted(p for t in targets for p in (ROOT / t).rglob("*.conf"))
    if not cases:
        sys.exit("no cases found")

    srcs = [c.read_text() for c in cases]
    plain = ask([encode(s) for s in srcs])
    # a case with a substitution is also asked resolved; the two answers together
    # say whether resolution is what the case is actually about
    resolved = ask(["resolve:" + encode(s) for s in srcs])

    stale = []
    for case, src, a, b in zip(cases, srcs, plain, resolved):
        side = case.with_suffix(".json")
        if not side.exists():
            stale.append("{}: no sidecar".format(side.relative_to(ROOT)))
            continue
        meta = json.loads(side.read_text())

        # an unresolved substitution renders as a literal ${x}, which is not JSON;
        # += desugars into one too, so ask the output, not the input
        use_resolved = not (a.startswith("ERROR") or is_json(a))
        answer = b if use_resolved else a
        want = dict(meta)
        if "java" in meta:
            # a divergent row: `expect` is the spec's answer and belongs to stage 5,
            # the oracle only gets to say what it does next to it
            want.pop("java_expect", None)
            want.pop("java_error", None)
            if answer.startswith("ERROR"):
                want["java_error"] = answer[len("ERROR "):].split(":", 1)[0]
            else:
                want["java_expect"] = json.loads(answer)
        elif answer.startswith("ERROR"):
            # the oracle refusing an input does not say whether the input is illegal
            # per spec or merely unimplemented — only a reader of the spec can tell
            if "error" not in meta:
                want["review"] = "oracle rejected this — illegal per spec, or unsupported by java?"
            want.pop("expect", None)
            want["error"] = answer[len("ERROR "):].split(":", 1)[0]
        else:
            want.pop("error", None)
            want["expect"] = json.loads(answer)
        if use_resolved:
            want["resolve"] = True

        # a declared divergence that does not actually diverge is a half-finished
        # judgement, not a row — send it back to a human rather than score it
        if "java" in want:
            spec_side = (want.get("expect"), want.get("error"))
            java_side = (want.get("java_expect"), want.get("java_error"))
            if spec_side == java_side:
                want["review"] = ("marked java:{} but expect is exactly what java does — "
                                  "what does the spec require instead?".format(want["java"]))
            elif want["java"] == "unsupported" and "java_expect" in want:
                want["review"] = ("marked java:unsupported but java produces a value — "
                                  "this looks like java:diverges")
            else:
                want.pop("review", None)

        if want == meta:
            continue
        stale.append(str(side.relative_to(ROOT)))
        if not check:
            side.write_text(json.dumps(want, indent=2, ensure_ascii=False) + "\n")

    if check and stale:
        print("out of date:\n  " + "\n  ".join(stale))
        return 1
    print("{} cases, {} sidecars {}".format(len(cases), len(stale), "stale" if check else "written"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
