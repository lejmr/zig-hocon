import org.ekrich.config.*;
import java.io.File;
// adapter: ekrich/sconfig — run.sh contract (path in, compact JSON out, non-zero on rejection)
public class SconfigAdapter {
    public static void main(String[] a) {
        try {
            Config c = ConfigFactory.parseFile(new File(a[0])).resolve();
            new java.io.PrintStream(new java.io.FileOutputStream(java.io.FileDescriptor.out), true, "UTF-8").println(c.root().render(ConfigRenderOptions.concise()));
        } catch (Throwable e) {
            System.err.println("ERROR " + e.getClass().getSimpleName() + ": " + e.getMessage());
            System.exit(1);
        }
    }
}
