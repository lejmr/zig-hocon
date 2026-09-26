"""End-to-end side of tools/bench/run.sh: wall time of a whole command.

    python3 e2e.py <out-dir> <file>...

Times `hocon <file>`, the two Rust crates as a command, the typesafe/config Cli
and the `pyhocon` tool from
process start to exit, output to /dev/null — start-up, reading, parsing,
printing JSON, everything a user waits for. Writes <out-dir>/e2e-{zig,java,py}.tsv
(and e2e-hocon-rs, e2e-hocon) in the format table.py reads. Each cell is the median of runs until two seconds
have passed and at least five are in; a run over 30 s is kept alone. Sizes are
meant to grow geometrically, so once the last two runs say the next one would
take over two minutes, the rest are skipped for that command.
"""
import os
import statistics
import subprocess
import sys
import time

out, files = sys.argv[1], sys.argv[2:]
java = os.environ.get("JAVA", "java")
jar = "tools/oracle/config-1.4.9.jar"
rust = "tools/bench/rust/target/release/rust-hocon"
commands = {
    "zig": lambda f: ["zig-out/bin/hocon", f],
    "hocon-rs": lambda f: [rust, "hocon-rs", f],
    "hocon": lambda f: [rust, "hocon", f],
    "java": lambda f: [java, "-cp", "{}:{}/classes".format(jar, out), "Cli", f],
    "py": lambda f: ["tools/oracle/venv/bin/pyhocon", "-i", f, "-f", "json"],
}

for name, cmd in commands.items():
    medians = []
    with open(os.path.join(out, "e2e-{}.tsv".format(name)), "w") as tsv:
        for f in files:
            if len(medians) >= 2 and medians[-1] ** 2 / medians[-2] > 120e9:
                tsv.write("{}\tskipped\t0\n".format(f))
                continue
            times = []
            while len(times) < 5 or sum(times) < 2e9:
                start = time.perf_counter_ns()
                subprocess.run(cmd(f), stdout=subprocess.DEVNULL, check=True)
                times.append(time.perf_counter_ns() - start)
                if times[0] > 30e9:
                    break
            medians.append(statistics.median(times))
            tsv.write("{}\t{}\t{}\n".format(f, int(medians[-1]), len(times)))
    print(name + " done", file=sys.stderr)
