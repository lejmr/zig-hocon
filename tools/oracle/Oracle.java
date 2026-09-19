import com.typesafe.config.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * Reference HOCON oracle: reads test cases from stdin, one per line, each line
 * being a Java-style escaped string (\n, \t, \" understood). Prints one result
 * line per case: the concise JSON rendering, or "ERROR <Class>: <message>".
 *
 * Substitutions are NOT resolved unless the case is prefixed with "resolve:".
 * A line prefixed with "file:" is a path instead of source text; the file is
 * parsed in place, so its includes resolve relative to it. Prefixes stack as
 * "resolve:file:<path>".
 */
public class Oracle {
    public static void main(String[] args) throws Exception {
        BufferedReader in = new BufferedReader(
                new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        while ((line = in.readLine()) != null) {
            if (line.isEmpty()) continue;
            boolean resolve = line.startsWith("resolve:");
            if (resolve) line = line.substring("resolve:".length());
            boolean file = line.startsWith("file:");
            if (file) line = line.substring("file:".length());
            System.out.println(file ? runFile(line, resolve) : run(unescape(line), resolve));
        }
    }

    static String run(String src, boolean resolve) {
        try {
            Config c = ConfigFactory.parseString(src);
            if (resolve) c = c.resolve();
            return c.root().render(ConfigRenderOptions.concise());
        } catch (Exception e) {
            String msg = e.getMessage();
            if (msg != null) msg = msg.replace('\n', ' ');
            return "ERROR " + e.getClass().getSimpleName() + ": " + msg;
        }
    }

    static String runFile(String path, boolean resolve) {
        try {
            // strict: a missing non-optional include is an error, as the spec says
            Config c = ConfigFactory.parseFile(new File(path),
                    ConfigParseOptions.defaults().setAllowMissing(false));
            if (resolve) c = c.resolve();
            return c.root().render(ConfigRenderOptions.concise());
        } catch (Exception e) {
            String msg = e.getMessage();
            if (msg != null) msg = msg.replace('\n', ' ');
            return "ERROR " + e.getClass().getSimpleName() + ": " + msg;
        }
    }

    static String unescape(String s) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            if (ch != '\\' || i + 1 >= s.length()) {
                b.append(ch);
                continue;
            }
            char n = s.charAt(++i);
            switch (n) {
                case 'n' -> b.append('\n');
                case 't' -> b.append('\t');
                case 'r' -> b.append('\r');
                case '\\' -> b.append('\\');
                case '"' -> b.append('"');
                default -> b.append('\\').append(n);
            }
        }
        return b.toString();
    }
}
