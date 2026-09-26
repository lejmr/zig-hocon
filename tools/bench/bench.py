"""pyhocon side of tools/bench/run.sh: time to parse each file.

    python bench.py <file>...

Prints `<file>\t<median ns>\t<runs>\t<first ns>` per file: the first run on its
own, then runs until a second has passed and at least three are in. A first run
over 30 s is reported alone rather than repeated.
"""
import statistics
import sys
import time

from pyhocon import ConfigFactory

for path in sys.argv[1:]:
    text = open(path).read()
    times = []
    while len(times) < 3 or sum(times) < 1e9:
        start = time.perf_counter_ns()
        ConfigFactory.parse_string(text)
        times.append(time.perf_counter_ns() - start)
        if times[0] > 30e9:
            break
    print("{}\t{}\t{}\t{}".format(path, int(statistics.median(times)), len(times), times[0]), flush=True)
