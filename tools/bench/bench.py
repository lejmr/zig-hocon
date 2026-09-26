"""pyhocon side of tools/bench/run.sh: median time to parse each file.

    python bench.py <file>...

Prints `<file>\t<median ns>\t<runs>` per file. Runs until a second has passed
and at least three runs are in. A file that takes longer than 60 s once is
reported with that single run, and every bigger file after it is skipped.
"""
import statistics
import sys
import time

from pyhocon import ConfigFactory

too_slow = False
for path in sys.argv[1:]:
    if too_slow:
        print("{}\tskipped\t0".format(path), flush=True)
        continue
    text = open(path).read()
    times = []
    while len(times) < 3 or sum(times) < 1e9:
        start = time.perf_counter_ns()
        ConfigFactory.parse_string(text)
        times.append(time.perf_counter_ns() - start)
        if times[0] > 60e9:
            too_slow = True
            break
    print("{}\t{}\t{}".format(path, int(statistics.median(times)), len(times)), flush=True)
