"""Does every sidecar still say what typesafe/config does today?

    python3 tools/fuzz/audit.py [--version 1.4.9|main] [--json]

Runs each suite case through tools/oracle/hocon-java and compares the answer
with the sidecar's java side: `java_expect` / `java_error` on a divergent row,
`expect` / `error` everywhere else. For `--version main` a row's `java_since`
takes over from the version it names. Prints one line per row that disagrees.
Only the class of an error is compared, never its message.
"""

import json
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "conformance" / "maintaining"))
import suite

ORACLE = suite.ROOT / "tools" / "oracle" / "hocon-java"


def wanted(meta, version):
    """(ok, value-or-error-class) the sidecar claims java gives."""
    since = meta.get("java_since")
    if version != "1.4.9" and since and since.get("version") == "main":
        if "java_expect" in since:
            return True, since["java_expect"]
        if "java_error" in since:
            return False, since["java_error"]
        # nothing recorded: from then on java does what the spec says, and the
        # spec's error is no java class, so only the rejection is compared
        return ("expect" in meta), meta.get("expect")
    if "java_expect" in meta:
        return True, meta["java_expect"]
    if "java_error" in meta:
        return False, meta["java_error"]
    return ("expect" in meta), meta.get("expect", meta.get("error"))


def got(line):
    if line.startswith("ERROR "):
        return False, line[len("ERROR "):].split(":", 1)[0]
    return True, json.loads(line)


def main(argv):
    version = argv[argv.index("--version") + 1] if "--version" in argv else "1.4.9"
    env = dict(os.environ, HOCON_JAVA_VERSION=version)
    cases, metas, _ = suite.cases()
    answers = [None] * len(cases)
    plain = [i for i, m in enumerate(metas) if not m.get("env")]
    for i, a in zip(plain, suite.ask([ORACLE], [suite.oracle_line(cases[i], metas[i]) for i in plain], env=env)):
        answers[i] = a
    for i, m in enumerate(metas):
        if m.get("env"):
            e = dict(env, **{k: str(v) for k, v in m["env"].items()})
            answers[i] = suite.ask([ORACLE], [suite.oracle_line(cases[i], m)], env=e)[0]
    bad = []
    for case, meta, answer in zip(cases, metas, answers):
        w_ok, w = wanted(meta, version)
        g_ok, g = got(answer)
        # a recorded class may carry the ConfigException. prefix
        if w_ok or g_ok:
            same = w_ok == g_ok and w == g
        else:
            same = w is None or str(w).split(".")[-1] == g
        if not same:
            bad.append({"case": suite.key_of(case), "java": meta.get("java"), "sidecar": [w_ok, w], "oracle": answer})
    if "--json" in argv:
        print(json.dumps(bad, ensure_ascii=False, indent=1))
    else:
        for b in bad:
            print("{case} [{java}]\n  sidecar: {sidecar}\n  oracle:  {oracle}".format(**b))
    print("{} of {} rows disagree with typesafe/config {}".format(len(bad), len(cases), version), file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
