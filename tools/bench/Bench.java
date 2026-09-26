// typesafe/config side of tools/bench/run.sh: median time to parse each file.
//
//   java -cp config.jar Bench.java <file>...
//
// Prints `<file>\t<median ns>\t<runs>\t<first ns>` per file. The first parse is
// timed on its own, with the JIT still cold; then two seconds of warm-up, so the
// parser is compiled before the median is taken over runs until a second has
// passed and at least five are in.
import com.typesafe.config.ConfigFactory;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;

public class Bench {
    static long sink;

    public static void main(String[] args) throws Exception {
        for (String path : args) {
            String text = Files.readString(Path.of(path));
            long firstStart = System.nanoTime();
            sink += ConfigFactory.parseString(text).resolve().root().size();
            long first = System.nanoTime() - firstStart;
            long warmUntil = System.nanoTime() + 2_000_000_000L;
            while (System.nanoTime() < warmUntil) sink += ConfigFactory.parseString(text).resolve().root().size();

            ArrayList<Long> times = new ArrayList<>();
            long total = 0;
            while (times.size() < 5 || total < 1_000_000_000L) {
                long start = System.nanoTime();
                sink += ConfigFactory.parseString(text).resolve().root().size();
                long t = System.nanoTime() - start;
                times.add(t);
                total += t;
            }
            Collections.sort(times);
            System.out.println(path + "\t" + times.get(times.size() / 2) + "\t" + times.size() + "\t" + first);
        }
        if (sink == 42) System.err.println();
    }
}
