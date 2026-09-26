// typesafe/config side of tools/bench/run.sh: median time to parse each file.
//
//   java -cp config.jar Bench.java <file>...
//
// Prints `<file>\t<median ns>\t<runs>` per file. Each file gets two seconds of
// warm-up first, so the JIT has compiled the parser before anything is timed;
// then it runs until a second has passed and at least five runs are in.
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
            System.out.println(path + "\t" + times.get(times.size() / 2) + "\t" + times.size());
        }
        if (sink == 42) System.err.println();
    }
}
