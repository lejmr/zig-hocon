import org.ekrich.config.Config;
import org.ekrich.config.ConfigException;
import org.ekrich.config.ConfigFactory;
import org.ekrich.config.ConfigRenderOptions;

import java.io.File;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;

/**
 * Same adapter as Adapter.java, for sconfig (org.ekrich.config) instead of
 * typesafe/config (com.typesafe.config): the API matches, the imports do not.
 * java-adapter.sh falls back to this file when the jar on the classpath does
 * not provide com.typesafe.config.
 */
public final class AdapterSconfig {

    private AdapterSconfig() {
    }

    public static void main(String[] args) {
        if (args.length != 1) {
            System.err.println("usage: AdapterSconfig <file.conf | path/to/main.conf>");
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

    // Same transport fix as Adapter.java: an unpaired surrogate cannot cross a
    // charset, so it travels as its backslash-u escape.
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
