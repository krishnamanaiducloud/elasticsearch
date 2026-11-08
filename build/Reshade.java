// Re-shade a bundle jar: replace the classes it took from upstream jars with the same classes from newer releases,
// relocated the way maven-shade and Gradle Shadow relocate them (class references, class-name string constants,
// service files), and leave every other entry of the bundle unchanged.
//
//   java -cp <asm jars> Reshade.java reshade <bundle.jar> <out.jar> <relocations> <roots> <upstream.jar>...
//   java -cp <asm jars> Reshade.java compare <a.jar> <b.jar>
//
// relocations  comma-separated from=to internal-name prefixes, e.g. com/fasterxml/jackson=shaded/parquet/com/fasterxml/jackson
// roots        comma-separated unrelocated prefixes owned by the upstream jars, e.g. com/fasterxml/jackson/core/
//
// The bundle keeps the same selection of upstream classes it had (a minimized bundle stays minimized): every upstream
// class whose relocated name was in the bundle, plus every upstream class those classes reference. Multi-release
// variants follow their base class, and the relocated module descriptor is taken from the upstream jar with the same
// module name. Upstream resources replace the bundle's copy of the same path (pom.properties, services, ...); the
// bundle's own LICENSE, NOTICE and DEPENDENCIES files are kept.
// "compare" prints every difference between two jars, comparing classes by their ASM text form.
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.regex.*;
import java.util.zip.*;
import org.objectweb.asm.*;
import org.objectweb.asm.commons.*;
import org.objectweb.asm.util.*;

public class Reshade {
  record Rule(String from, String to) {}
  static final List<Rule> RULES = new ArrayList<>();
  static final Pattern CLASS_PATTERN = Pattern.compile("(\\[*)?L(.+);");
  static final Pattern VERSIONED = Pattern.compile("^META-INF/versions/(\\d+)/(.*)$");
  static final Pattern LEGAL = Pattern.compile("^META-INF/(LICENSE|NOTICE|DEPENDENCIES)[^/]*$"); // the bundle's own
  static final long TIME = 315532800000L + 86400000L; // 1980-01-02, a valid DOS timestamp

  static String relocatePath(String p) {
    for (Rule r : RULES) {
      if (p.startsWith(r.from)) return r.to + p.substring(r.from.length());
      if (p.startsWith("/" + r.from)) return "/" + r.to + p.substring(r.from.length() + 1);
    }
    return null;
  }

  static String relocateDotted(String c) { // a dotted class name, as shade's canRelocateClass/relocateClass
    if (c.indexOf('/') >= 0) return null;
    String p = relocatePath(c.replace('.', '/'));
    return p == null ? null : p.replace('/', '.');
  }

  static final class ShadeRemapper extends Remapper {
    ShadeRemapper() { super(Opcodes.ASM9); }
    @Override public String map(String name) {
      String prefix = "", suffix = "", n = name;
      Matcher m = CLASS_PATTERN.matcher(n);
      if (m.matches()) { prefix = (m.group(1) == null ? "" : m.group(1)) + "L"; suffix = ";"; n = m.group(2); }
      String r = relocatePath(n);
      return r == null ? name : prefix + r + suffix;
    }
    @Override public Object mapValue(Object value) {
      if (value instanceof String s) {
        String prefix = "", suffix = "", n = s;
        Matcher m = CLASS_PATTERN.matcher(n);
        if (m.matches()) { prefix = (m.group(1) == null ? "" : m.group(1)) + "L"; suffix = ";"; n = m.group(2); }
        String r = relocateDotted(n);
        if (r == null) r = relocatePath(n);
        return r == null ? s : prefix + r + suffix;
      }
      return super.mapValue(value);
    }
  }

  static LinkedHashMap<String, byte[]> read(Path jar) throws IOException {
    LinkedHashMap<String, byte[]> m = new LinkedHashMap<>();
    try (ZipInputStream z = new ZipInputStream(new BufferedInputStream(Files.newInputStream(jar)))) {
      for (ZipEntry e; (e = z.getNextEntry()) != null; ) m.put(e.getName(), e.isDirectory() ? null : z.readAllBytes());
    }
    return m;
  }

  static String base(String path) { Matcher m = VERSIONED.matcher(path); return m.matches() ? m.group(2) : path; }
  static String versionPrefix(String path) { Matcher m = VERSIONED.matcher(path); return m.matches() ? "META-INF/versions/" + m.group(1) + "/" : ""; }
  static boolean under(String path, List<String> roots) { for (String r : roots) if (path.startsWith(r)) return true; return false; }

  static String moduleName(byte[] b) {
    String[] name = new String[1];
    new ClassReader(b).accept(new ClassVisitor(Opcodes.ASM9) {
      @Override public ModuleVisitor visitModule(String n, int access, String version) { name[0] = n; return null; }
    }, ClassReader.SKIP_CODE);
    return name[0];
  }

  static Set<String> references(byte[] b) { // internal names a class refers to
    Set<String> refs = new HashSet<>();
    Remapper rec = new Remapper(Opcodes.ASM9) {
      @Override public String map(String n) { refs.add(n); return n; }
    };
    new ClassReader(b).accept(new ClassRemapper(new ClassWriter(0), rec), 0);
    return refs;
  }

  static byte[] remap(byte[] b) {
    ClassReader r = new ClassReader(b);
    ClassWriter w = new ClassWriter(0);
    r.accept(new ClassRemapper(w, new ShadeRemapper()), 0);
    return w.toByteArray();
  }

  static byte[] relocateServiceFile(byte[] b) {
    StringBuilder out = new StringBuilder();
    for (String line : new String(b, java.nio.charset.StandardCharsets.UTF_8).split("\n", -1)) {
      String t = line.strip();
      String r = t.isEmpty() || t.startsWith("#") ? null : relocateDotted(t);
      out.append(r == null ? line : line.replace(t, r)).append('\n');
    }
    out.setLength(out.length() - 1);
    return out.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
  }

  static void reshade(Path bundle, Path out, String relocations, String rootsArg, List<Path> upstream) throws IOException {
    for (String r : relocations.split(",")) { String[] p = r.split("=", 2); RULES.add(new Rule(p[0], p[1])); }
    List<String> roots = Arrays.asList(rootsArg.split(","));
    List<String> relRoots = roots.stream().map(r -> Objects.requireNonNull(relocatePath(r), "root not relocated: " + r)).toList();
    LinkedHashMap<String, byte[]> orig = read(bundle);

    // upstream entries (first jar providing a path wins, as in a shade build), module descriptors kept per module name
    LinkedHashMap<String, byte[]> up = new LinkedHashMap<>();
    Map<String, byte[]> descriptors = new HashMap<>();
    for (Path j : upstream) for (var e : read(j).entrySet()) {
      if (e.getValue() == null) continue;
      if (base(e.getKey()).equals("module-info.class")) { descriptors.putIfAbsent(moduleName(e.getValue()), e.getValue()); continue; }
      up.putIfAbsent(e.getKey(), e.getValue());
    }

    // what the bundle had from the upstream packages (relocated, base names) and its module descriptor
    Set<String> had = new HashSet<>();
    List<String> removed = new ArrayList<>();
    for (String p : orig.keySet()) if (under(base(p), relRoots)) { removed.add(p); if (p.endsWith(".class")) had.add(base(p)); }

    // selection: upstream base classes the bundle had, closed over references within the upstream packages
    Deque<String> work = new ArrayDeque<>();
    Set<String> sel = new TreeSet<>();
    for (String p : up.keySet()) if (p.endsWith(".class") && VERSIONED.matcher(p).matches() == false && under(p, roots)
        && had.contains(relocatePath(p))) { sel.add(p); work.add(p); }
    while (!work.isEmpty()) {
      for (String ref : references(up.get(work.pop()))) {
        String p = ref + ".class";
        if (under(p, roots) && up.containsKey(p) && sel.add(p)) work.add(p);
      }
    }

    LinkedHashMap<String, byte[]> res = new LinkedHashMap<>();
    for (var e : orig.entrySet()) if (!removed.contains(e.getKey()) || e.getValue() == null) res.put(e.getKey(), e.getValue());
    // relocated classes, then multi-release variants of selected classes
    TreeMap<String, byte[]> added = new TreeMap<>();
    for (String p : sel) added.put(relocatePath(p), remap(up.get(p)));
    for (String p : up.keySet()) {
      String vp = versionPrefix(p);
      if (!vp.isEmpty() && p.endsWith(".class") && sel.contains(base(p))) added.put(vp + relocatePath(base(p)), remap(up.get(p)));
    }
    // module descriptors the bundle carried: same module name from the upstream jars
    for (String p : orig.keySet()) {
      if (!base(p).equals("module-info.class") || orig.get(p) == null) continue;
      String mn = moduleName(orig.get(p));
      byte[] d = descriptors.get(mn);
      if (d == null) { System.out.println("kept    " + p + " (module " + mn + " is not from the upstream jars)"); continue; }
      res.put(p, remap(d));
      System.out.println("module  " + p + ": " + mn + " from upstream");
    }
    // resources: upstream copies replace the bundle's copy of the same (relocated) path
    int resources = 0;
    for (var e : up.entrySet()) {
      String p = e.getKey();
      if (p.endsWith(".class") || p.equals("META-INF/MANIFEST.MF") || LEGAL.matcher(p).matches()) continue;
      String target = p;
      byte[] content = e.getValue();
      if (p.startsWith("META-INF/services/")) {
        String svc = p.substring("META-INF/services/".length());
        String r = relocateDotted(svc);
        target = "META-INF/services/" + (r == null ? svc : r);
        content = relocateServiceFile(content);
      }
      if (orig.containsKey(target) && orig.get(target) != null) {
        if (!Arrays.equals(orig.get(target), content)) { res.put(target, content); resources++; System.out.println("resource " + target); }
      }
    }
    // directory entries for new packages
    Set<String> dirs = new TreeSet<>();
    for (String p : added.keySet()) for (int i = p.indexOf('/'); i > 0; i = p.indexOf('/', i + 1)) dirs.add(p.substring(0, i + 1));
    for (String d : dirs) if (!res.containsKey(d)) res.put(d, null);
    for (var e : added.entrySet()) res.put(e.getKey(), e.getValue());

    try (ZipOutputStream z = new ZipOutputStream(new BufferedOutputStream(Files.newOutputStream(out)))) {
      for (var e : res.entrySet()) {
        ZipEntry ze = new ZipEntry(e.getKey());
        ze.setTime(TIME);
        z.putNextEntry(ze);
        if (e.getValue() != null) z.write(e.getValue());
        z.closeEntry();
      }
    }
    Set<String> now = new HashSet<>();
    for (String p : sel) now.add(relocatePath(p));
    List<String> dropped = had.stream().filter(h -> !now.contains(h)).sorted().toList();
    long notTaken = up.keySet().stream().filter(p -> p.endsWith(".class") && !VERSIONED.matcher(p).matches() && under(p, roots) && !sel.contains(p)).count();
    System.out.printf("reshade %s: %d upstream classes (bundle had %d), %d multi-release variants, %d resources replaced%n",
        bundle.getFileName(), sel.size(), had.size(), added.size() - sel.size(), resources);
    System.out.printf("        %d classes of the upstream packages not in the selection, %d the bundle had are gone%n", notTaken, dropped.size());
    for (String d : dropped) System.out.println("gone    " + d);
  }

  static String text(byte[] b) {
    StringWriter s = new StringWriter();
    new ClassReader(b).accept(new TraceClassVisitor(new PrintWriter(s)), 0);
    return s.toString();
  }

  static int compare(Path a, Path b) throws IOException {
    var x = read(a);
    var y = read(b);
    int diffs = 0;
    TreeSet<String> all = new TreeSet<>(x.keySet());
    all.addAll(y.keySet());
    for (String p : all) {
      byte[] u = x.get(p), v = y.get(p);
      boolean inX = x.containsKey(p), inY = y.containsKey(p);
      if (!inX || !inY) { if (!p.endsWith("/")) { diffs++; System.out.println((inX ? "only in first:  " : "only in second: ") + p); } continue; }
      if (u == null || v == null) continue;
      if (Arrays.equals(u, v)) continue;
      if (p.endsWith(".class")) {
        String tu = text(u), tv = text(v);
        if (tu.equals(tv)) continue;
        diffs++;
        String[] lu = tu.split("\n"), lv = tv.split("\n");
        int i = 0;
        while (i < Math.min(lu.length, lv.length) && lu[i].equals(lv[i])) i++;
        System.out.println("class differs:  " + p + "\n    first:  " + (i < lu.length ? lu[i].strip() : "<end>") + "\n    second: " + (i < lv.length ? lv[i].strip() : "<end>"));
      } else { diffs++; System.out.println("resource differs: " + p); }
    }
    System.out.println(diffs == 0 ? "compare: identical" : "compare: " + diffs + " differences");
    return diffs;
  }

  public static void main(String[] a) throws IOException {
    switch (a[0]) {
      case "reshade" -> {
        List<Path> ups = new ArrayList<>();
        for (int i = 5; i < a.length; i++) ups.add(Path.of(a[i]));
        reshade(Path.of(a[1]), Path.of(a[2]), a[3], a[4], ups);
      }
      case "compare" -> System.exit(compare(Path.of(a[1]), Path.of(a[2])) == 0 ? 0 : 1);
      default -> throw new IllegalArgumentException(a[0]);
    }
  }
}
