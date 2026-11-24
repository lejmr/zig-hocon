import com.typesafe.config.Config;
import com.typesafe.config.ConfigException;
import com.typesafe.config.ConfigFactory;
import com.typesafe.config.ConfigRenderOptions;

import java.io.File;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;

/**
 * Adapter for the HOCON conformance suite (lejmr/zig-hocon, conformance/).
 *
 * Usage: java -cp Adapter.class:<config jar> Adapter file.conf
 *
 * Prints the resolved config as compact JSON on stdout and exits 0, or prints
 * the reason on stderr and exits 1 to reject. Relative includes resolve beside
 * the given file; the runner hands over a copy of a directory case's main.conf
 * with @CASE_DIR@ already substituted, so no marker handling is needed here.
 */
public final class Adapter {

    private Adapter() {
    }

    public static void main(String[] args) {
        if (args.length != 1) {
            System.err.println("usage: Adapter <file.conf | path/to/main.conf>");
            System.exit(2);
        }
        try {
            Config config = ConfigFactory.parseFile(new File(args[0])).resolve();
            String rendered = config.root().render(ConfigRenderOptions.concise());
            PrintStream stdout = new PrintStream(System.out, true, StandardCharsets.UTF_8);
            stdout.println(escapeUnpairedSurrogates(rendered));
        } catch (ConfigException e) {
            String message = e.getMessage() == null ? "" : e.getMessage().split("\\n", 2)[0];
            System.err.println(e.getClass().getSimpleName() + ": " + message);
            System.exit(1);
        }
    }

    // The render of a value that holds an unpaired surrogate (JSON allows the
    // escape, HOCON keeps it) is that raw code unit; no charset can carry it,
    // so it is sent as the equivalent backslash-u escape. Valid pairs stay
    // literal.
    static String escapeUnpairedSurrogates(String s) {
        StringBuilder sb = new StringBuilder(s.length());
        int i = 0;
        while (i < s.length()) {
            int codePoint = s.codePointAt(i);
            if (codePoint >= 0xD800 && codePoint <= 0xDFFF) {
                sb.append(String.format("\\u%04x", codePoint));
                i += 1;
            } else {
                sb.appendCodePoint(codePoint);
                i += Character.charCount(codePoint);
            }
        }
        return sb.toString();
    }
}
