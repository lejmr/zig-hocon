// adapter: akkadotnet/HOCON (NuGet Hocon 2.0.4) — run.sh contract (path in, compact JSON out, non-zero on rejection)
using System.Text;
using System.Text.Json.Nodes;
using Hocon;

if (args.Length > 0 && args[0] == "--version") { Console.WriteLine("Hocon (akkadotnet) 2.0.4"); return 0; }
try {
    var path = Path.GetFullPath(args[0]);
    var dir = Path.GetDirectoryName(path)!;
    HoconIncludeCallbackAsync cb = (type, name) => {
        var p = type == HoconCallbackType.File ? Path.Combine(dir, name) : Path.Combine(dir, name);
        return Task.FromResult(File.Exists(p) ? File.ReadAllText(p) : "{}");
    };
    var root = HoconParser.Parse(File.ReadAllText(path, Encoding.UTF8), cb);
    var node = Conv(root.Value);
    var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false));
    stdout.WriteLine(node == null ? "null" : node.ToJsonString());
    stdout.Flush();
    return 0;
} catch (Exception e) {
    Console.Error.WriteLine("ERROR " + e.GetType().Name + ": " + e.Message);
    return 1;
}

static JsonNode? Conv(HoconValue v) {
    if (v == null) return null;
    switch (v.Type) {
        case HoconType.Object: {
            var o = new JsonObject();
            foreach (var kv in v.GetObject()) o[kv.Key] = Conv(kv.Value.Value);
            return o;
        }
        case HoconType.Array: {
            var a = new JsonArray();
            foreach (var x in v.GetArray()) a.Add(Conv(x));
            return a;
        }
        case HoconType.Boolean: return JsonValue.Create(v.GetBoolean());
        case HoconType.Number: return JsonNode.Parse(v.Raw);
        case HoconType.Empty: return null;
        default: {
            if (v.Count == 1 && v[0] is HoconLiteral lit && lit.LiteralType == HoconLiteralType.Null) return null;
            return JsonValue.Create(v.GetString());
        }
    }
}
