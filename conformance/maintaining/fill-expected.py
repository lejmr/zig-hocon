"""Stage 3: fill `expect` (or `error`) into every sidecar that lacks one.

Reads each conformance case, runs it through tools/oracle/hocon-java, and writes
the oracle's answer back. Never invents a value; a case it cannot feed to the
oracle is reported and left alone.

    python3 conformance/maintaining/fill-expected.py [--check] [<dir>...]

--check writes nothing and exits non-zero if any sidecar is out of date, which
is what CI and the Zig test step should call.
"""

import collections
import json
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import suite

ORACLE = suite.ROOT / "tools" / "oracle" / "hocon-java"


def main(argv):
    check = "--check" in argv
    targets = [a for a in argv if not a.startswith("--")] or ["conformance"]

    cases, metas, orphans = suite.cases()
    if targets != ["conformance"]:
        keep = [i for i, c in enumerate(cases) if any(str(c).startswith(str(suite.ROOT / t)) for t in targets)]
        cases, metas = [cases[i] for i in keep], [metas[i] for i in keep]
    if not cases:
        sys.exit("no cases found")

    def line(case, meta):
        # ask without the resolve prefix first; the loop below decides whether the
        # resolved answer is the one that matters
        return suite.oracle_line(case, dict(meta, resolve=False))

    # cases that need environment variables each get their own oracle process
    # with that environment; everything else goes through one batch
    batch = [(i, c, m) for i, (c, m) in enumerate(zip(cases, metas)) if not m.get("env")]
    plain = [None] * len(cases)
    resolved = [None] * len(cases)
    if batch:
        for (i, _, _), a in zip(batch, suite.ask([ORACLE], [line(c, m) for _, c, m in batch])):
            plain[i] = a
        for (i, _, _), b in zip(batch, suite.ask([ORACLE], ["resolve:" + line(c, m) for _, c, m in batch])):
            resolved[i] = b
    for i, (c, m) in enumerate(zip(cases, metas)):
        if m.get("env"):
            env = dict(os.environ, **{k: str(v) for k, v in m["env"].items()})
            plain[i] = suite.ask([ORACLE], [line(c, m)], env=env)[0]
            resolved[i] = suite.ask([ORACLE], ["resolve:" + line(c, m)], env=env)[0]

    stale = ["{}: no sidecar".format(o.relative_to(suite.ROOT)) for o in orphans]
    stale += ["{}: spec anchor {} is not a heading of HOCON.md".format(p.relative_to(suite.ROOT), ref)
              for p, ref in suite.bad_anchors([c.with_suffix(".json") for c in cases], metas)]
    # a directory is one heading of the spec: every case in it cites the same anchor
    anchors_by_dir = collections.defaultdict(set)
    for c, m in zip(cases, metas):
        anchors_by_dir[suite.section_of(c)].add(m.get("spec", ""))
    stale += ["conformance/suite/{}: cases cite {} different spec anchors: {}".format(
                  d, len(a), ", ".join(sorted(a)))
              for d, a in sorted(anchors_by_dir.items()) if len(a) > 1]
    for case, meta, a, b in zip(cases, metas, plain, resolved):
        side = case.with_suffix(".json")

        # an unresolved substitution renders as a literal ${x}, which is not JSON;
        # += desugars into one too, so ask the output, not the input
        use_resolved = not (a.startswith("ERROR") or suite.is_json(a))
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
            kind, complaint = want["java"], None
            spec_value, java_value = "expect" in want, "java_expect" in want
            if kind == "diverges" and not (spec_value and java_value):
                complaint = "java:diverges means both sides produce a value — one of them does not"
            elif kind == "diverges" and want["expect"] == want["java_expect"]:
                complaint = "java:diverges but the two values are identical"
            elif kind == "unsupported" and not (spec_value and "java_error" in want):
                complaint = "java:unsupported means the spec requires a value java refuses to produce"
            elif kind == "lenient" and not ("error" in want and java_value):
                complaint = "java:lenient means the spec rejects the input and java accepts it"
            elif kind not in ("diverges", "unsupported", "lenient"):
                complaint = "unknown java kind {!r}".format(kind)
            if complaint:
                want["review"] = complaint
            else:
                want.pop("review", None)

        if want == meta:
            continue
        stale.append(str(side.relative_to(suite.ROOT)))
        if not check:
            side.write_text(json.dumps(want, indent=2, ensure_ascii=False) + "\n")

    if stale and (check or orphans):
        print("needs attention:\n  " + "\n  ".join(stale))
        if check:
            return 1
    print("{} cases, {} sidecars {}".format(len(cases), len(stale), "stale" if check else "written"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
