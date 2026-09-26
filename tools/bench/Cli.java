// typesafe/config as a command, for the end-to-end timings in tools/bench/run.sh:
// the same job as `hocon <file>` — read, parse, resolve, print compact JSON.
//
//   javac -cp config.jar -d <dir> Cli.java && java -cp config.jar:<dir> Cli <file>
import com.typesafe.config.ConfigFactory;
import com.typesafe.config.ConfigRenderOptions;
import java.io.File;

public class Cli {
    public static void main(String[] args) {
        System.out.println(ConfigFactory.parseFile(new File(args[0])).resolve().root()
                .render(ConfigRenderOptions.concise()));
    }
}
