import com.typesafe.config.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
public class Batch {
  public static void main(String[] a) throws Exception {
    BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
    PrintStream out = new PrintStream(new FileOutputStream(FileDescriptor.out), true, "UTF-8");
    String p;
    while ((p = in.readLine()) != null) {
      String r;
      try {
        Config c = ConfigFactory.parseFile(new File(p)).resolve();
        r = c.root().render(ConfigRenderOptions.concise());
      } catch (Throwable e) {
        String m = String.valueOf(e.getMessage()); if (m.length() > 300) m = m.substring(0, 300);
        r = "ERROR " + e.getClass().getSimpleName() + ": " + m.replace('\n', ' ');
      }
      out.println(p + "\t" + r);
    }
  }
}
