"""Read a JaCoCo report of typesafe/config running this suite; say what is left.

    python3 java-coverage.py coverage/                 # table + coverage/uncovered.txt
    python3 java-coverage.py coverage/ --probe p.xml   # lines a candidate newly reaches

The number that matters is the *reachable* one. A .conf file handed to the
parser and resolved can only ever drive the tokenizer, the two parsers, paths,
values, resolution and includes. It cannot call the Java API (typed getters,
Map/List views, document editing, serialization, beans, classpath loading),
and it cannot trip the library's own bug guards. Those are listed below and
left out of the denominator; the whole-library figure is printed too, so the
scope is visible rather than hidden.
"""

import pathlib
import re
import sys
import xml.etree.ElementTree as ET

# the classes a parse+resolve can reach at all
SCOPE = """
Tokenizer Tokens Token TokenType ConfigDocumentParser ConfigParser PathParser Path PathBuilder
AbstractConfigNodeValue ConfigNodeSimpleValue ConfigNodeSingleToken ConfigNodeComment
ConfigNodeField ConfigNodeInclude ConfigNodeConcatenation ConfigNodeArray
AbstractConfigValue AbstractConfigObject SimpleConfigObject SimpleConfigList
ConfigString ConfigInt ConfigLong ConfigDouble ConfigNumber ConfigBoolean ConfigNull
ConfigConcatenation ConfigDelayedMerge ConfigDelayedMergeObject ConfigReference SubstitutionExpression
ResolveContext ResolveSource ResolveMemos ResolveResult ResolveStatus MemoKey BadMap
SimpleIncluder SimpleIncludeContext ConfigIncludeKind PropertiesParser ConfigImplUtil
""".split()

# methods that exist for the Java API, not for parsing: Map/List views, value
# identity, builders, rendering with options, serialization, document editing.
# Matched against "Class.method(descriptor" so a name can be pinned to a class
# or to one overload.
API_METHODS = re.compile(r"""^(
    \w+\.(equals|hashCode|toString|canEqual|unwrapped|writeReplace)\(|
    \w+\.(withOnlyKey|withOnlyPath|withOnlyPathOrNull|withoutKey|withoutPath|withValue|atKey|atPath|toFallbackValue)\(|
    \w+\.(render(?!JsonString)\w*|indent|appendHiddenEnvVariableValue|valueType|transformToString)\(|
    \w+\.(containsKey|containsValue|entrySet|keySet|values|contains|containsAll|indexOf|lastIndexOf)\(|
    \w+\.(iterator|listIterator|wrapListIterator|subList|toArray|isEmpty|size|get)\(|
    SimpleConfigList\.(hasNext|next|hasPrevious|nextIndex|previous|previousIndex)\(|
    \w+\.(add|addAll|clear|put|putAll|remove|removeAll|retainAll|set|weAreImmutable)\(|
    PathParser\.(parsePath|parsePathNode|speculativeFastParsePath|looksUnsafeForFastParser|fastPathBuild)\(|
    Path\.(newKey|newPath|startsWith|subPath\(II)\(?|
    \w+\.(hasDescendant\w*|peekPath|reverse|asValueResult|withParseable|depth|longValue|doubleValue|intValueRangeChecked|isWhole|mapEquals|mapHash|newNode)\(|
    ConfigImplUtil\.(joinPath|splitPath|toCamelCase|envVariableAsProperty|underscoreMappings|readOrigin|writeOrigin|urlToFile|extractInitializerError|unicodeTrim)\(|
    PropertiesParser\.(fromPathMap\(Lcom/typesafe/config/ConfigOrigin;Ljava/util/Map;\)|fromStringMap\()|
    PathParser\.parsePathExpression\(Ljava/util/Iterator;Lcom/typesafe/config/ConfigOrigin;Ljava/lang/String;\)|
    ConfigNodeInclude\.children\(|Tokens\.(newInt|tokenText)\(|\w+\.tokenText\(|Token\.tokenType\(|SimpleIncluder\.makeFull\(|
    Tokens\.(isProblem|getProblem\w*|what|message|suggestQuotes|cause)\(|Tokens\.(newValue|<init>)\(Lcom/typesafe/config/impl/AbstractConfigValue;\)|
    Tokenizer\.hasNext\(|SubstitutionExpression\.changeListExpansion\(|SimpleConfigList\.<init>\(Lcom/typesafe/config/impl/SimpleConfigList;Ljava/util/|
    ResolveSource\.rootMustBeObj\(|SimpleConfigObject\.empty\(\)|
    ConfigDocumentParser\.(parseValue\(Ljava/util/Iterator|parseSingleValue\()|
    \w+\.(tokens|replaceValue)\(|
    SimpleIncluder\.(includeURL\w*|includeResource\w*|withFallback|makeIncluder)\(|
    Tokenizer\.render\(|
    \w+\.(lambda\$\w+|<clinit>)\(
)""", re.X)

# nested classes that only the API instantiates
API_CLASSES = re.compile(r"SimpleIncluder\$Proxy$|SimpleConfigObject\$RenderComparator$")

# the implicit constructor of a class nobody instantiates (all-static classes)
CLASS_LINE = re.compile(r"^(final |public |abstract )*class \w+")

# lines that no input can reach: guards against the library's own bugs, the
# trace facility (a system property), and unresolved-value accessors
DIAGNOSTIC = re.compile(
    r"BugOrBroken|notResolved\(\)|NotResolved\(|ConfigImpl\.trace|trace[A-Za-z]*Enabled|"
    r"UnsupportedOperationException|\bthrow e;|catch\s*\(\s*(Runtime)?Exception|unexpected checked exception|"
    r"catch \(IOException|catch \(NotPossibleToResolve|getAllowUnresolved|"
    r"^\s*\}\s*$|"
    r"return (Integer|Long|Double)\.toString\(value\)"  # originalText is null only for API-made values
)


# Lines a .conf file cannot reach, each with the reason. They stay in the
# report under their own heading so the claim can be checked, and the script
# complains if one of them is ever covered. Line numbers are for 1.4.9.
UNREACHED = {
    "AbstractConfigObject.java": [
        ((66, 67), "a NotResolved from a peek needs an unresolved delayed-merge object after a restricted resolve; the resolver resolves the path first"),
        ((168,), "a merge whose every layer is an empty resolved object is never delayed, so the origins never all get skipped")],
    "AbstractConfigValue.java": [
        ((95, 98), "a container losing its only child during resolution; delayed merges only sit under objects, whose replaceChild never empties them"),
        ((171, 172), "a resolved non-object reaches withFallback only after ignoresFallbacks() returned true, which returns early")],
    "BadMap.java": [((135,), "the table of primes runs out past a billion entries")],
    "ConfigConcatenation.java": [
        ((149,), "a piece that is itself a concatenation; the parser flattens them and a resolved piece is never one"),
        ((171,), "concatenate() with no pieces; the parser builds a concatenation only from two or more values"),
        ((240, 241, 242, 244), "a concatenation is never a parent container: pushParent(this) is commented out in resolveSubstitutions")],
    "ConfigDelayedMerge.java": [
        ((190, 191), "NotResolved inside allKeysShadowed; see AbstractConfigObject 66"),
        ((234,), "replaceChild emptying the stack; see AbstractConfigValue 95"),
        ((266,), "withOrigin on a delayed merge; comments attach to the values before they are merged")],
    "ConfigDelayedMergeObject.java": [
        ((46,), "withOrigin on a delayed merge object; see ConfigDelayedMerge 266"),
        ((74,), "replaceChild emptying the stack; see AbstractConfigValue 95"),
        ((276,), "a delayed-merge object nested in another's stack; stacks are consolidated on construction")],
    "ConfigDocumentParser.java": [
        ((176,), "consolidateValues never sees whitespace before the first value; nextTokenCollectingWhitespace has consumed it"),
        ((216, 223), "the previousFieldName wording: lastPath is declared but never assigned")],
    "ConfigImplUtil.java": [((292,), "syntaxFromExtension(null); every parseable has a name")],
    "ConfigNodeArray.java": [((9,), "the one-argument constructor serves the document-editing API")],
    "ConfigNodeField.java": [((80,), "a field node always has a value node, so the loop returns before its end")],
    "ConfigNodeInclude.java": [((44,), "the parser rejects an include without a name before building the node")],
    "ConfigParser.java": [
        ((120,), "every node type is handled above"),
        ((183, 187, 188), "a syntactically valid url() fetches the URL; the suite hosts none"),
        ((339, 342), "JSON duplicate keys are rejected by the document parser first (line 498)")],
    "Path.java": [
        ((25, 26, 27, 29, 30), "the varargs constructor with several elements is only used by joinPath (API)"),
        ((37,), "the Path(List) constructor has no caller in the library outside the API")],
    "PathParser.java": [((193,), "an unquoted key token in JSON flavor; JSON keys are always quoted")],
    "PropertiesParser.java": [((126, 127, 162, 165), "branches for maps built by the API (non-properties, non-string values); a .properties file yields strings with convertedFromProperties=true")],
    "ResolveSource.java": [
        ((66,), "NotResolved from findInObject; see AbstractConfigObject 66"),
        ((200,), "resetParents with no parents; a delayed merge always has its container pushed first"),
        ((213, 214, 220, 222, 234), "replace() when the container chain ends or a parent stops being a container; with a SimpleConfigObject root and merges only under objects the chain keeps its containers"),
        ((244, 273), "old == replacement: a remainder is always a fresh value"),
        ((256, 258, 259, 279, 280), "the root replaced or emptied; a parsed root is always a SimpleConfigObject")],
    "SimpleConfigList.java": [
        ((68,), "replaceChild emptying the list; see AbstractConfigValue 95"),
        ((121,), "modify with a null status is the allowUnresolved API path"),
        ((124,), "an unresolved list whose children all resolve to themselves"),
        ((154,), "a list resolved restricted to a child path; lookups stop before descending into a list")],
    "SimpleConfigObject.java": [
        ((192,), "withFallbacksIgnored on an object already ignoring fallbacks; withFallback returns early for it"),
        ((655,), "empty(null origin) is the API's emptyObject(null)")],
    "SimpleIncludeContext.java": [((39,), "an include context without a parseable is only made by the API")],
    "SimpleIncluder.java": [
        ((47, 97), "an application-supplied fallback includer"),
        ((155, 156), "relativeTo returns null only for an including file without a directory; the runner passes absolute paths")],
    "SubstitutionExpression.java": [((33,), "changePath with the same path; relativization always prepends")],
    "Tokenizer.java": [((185,), "startOfComment at end of input; callers test for it first")],
}
UNREACHED_LINES = {f: {n: why for lines, why in rows for n in lines} for f, rows in UNREACHED.items()}


def continues(prev):
    """A statement spread over several lines: JaCoCo counts each of them."""
    p = prev.rstrip()
    return p and not p.endswith((";", "{", "}"))


def load(xml, src):
    """{sourcefile: {line: (covered, excluded_reason)}}, plus method names per line."""
    root = ET.parse(xml).getroot()
    files = {}
    for pkg in root.iter("package"):
        pdir = pkg.get("name")
        # method start lines, from every class (nested ones included) of a source file
        starts = {}
        for cls in pkg.iter("class"):
            sf = cls.get("sourcefilename")
            api_class = bool(API_CLASSES.search(cls.get("name")))
            outer = cls.get("name").rsplit("/", 1)[-1].split("$")[0]
            for m in cls.iter("method"):
                key = f"{outer}.{m.get('name')}{m.get('desc')}"
                starts.setdefault(sf, []).append((int(m.get("line")), key, api_class))
        for sf in pkg.iter("sourcefile"):
            name = sf.get("name")
            if name[:-5] not in SCOPE:
                continue
            source = (src / pdir / name).read_text().splitlines()
            ms = sorted(starts.get(name, []))
            lines, prev_excluded, prev_text, block = {}, False, "", None
            for l in sf.iter("line"):
                nr, covered = int(l.get("nr")), int(l.get("ci")) > 0
                text = source[nr - 1]
                indent = len(text) - len(text.lstrip())
                if block is not None and indent <= block:
                    block = None
                method = next((m for m in reversed(ms) if m[0] <= nr), (0, "?(", False))
                reason = None
                if method[2] or API_METHODS.match(method[1]):
                    reason = "api"
                elif nr in UNREACHED_LINES.get(name, {}):
                    reason = "unreached"
                elif CLASS_LINE.match(text):
                    reason = "diagnostic"
                elif block is not None or DIAGNOSTIC.search(text) or (prev_excluded == "diagnostic" and continues(prev_text)):
                    reason = "diagnostic"
                    if text.rstrip().endswith("{") and block is None:
                        block = indent
                lines[nr] = (covered, reason, method[1].split("(")[0].split(".")[-1], text)
                prev_excluded, prev_text = reason, text
            files[name] = lines
    return files


def main(argv):
    out = pathlib.Path(argv[0])
    src = out / "src"
    files = load(out / "report.xml", src)

    if len(argv) > 2 and argv[1] == "--probe":
        probe = load(pathlib.Path(argv[2]), src)
        hits = 0
        for name, lines in files.items():
            for nr, (covered, reason, method, text) in lines.items():
                if not covered and reason is None and probe[name][nr][0]:
                    print(f"{name[:-5]}.{method}:{nr}  {text.strip()}")
                    hits += 1
        print(f"\n{hits} reachable lines newly covered")
        return

    report, table, listed, stale = [], [], [], []
    tot = {"cov": 0, "reach": 0, "api": 0, "diag": 0, "unreached": 0}
    for name in sorted(files):
        lines = files[name]
        reach = [(nr, v) for nr, v in lines.items() if v[1] is None]
        cov = sum(1 for _, v in reach if v[0])
        api = sum(1 for v in lines.values() if v[1] == "api")
        diag = sum(1 for v in lines.values() if v[1] == "diagnostic")
        unreached = [(nr, v) for nr, v in lines.items() if v[1] == "unreached"]
        stale += [f"{name[:-5]}:{nr}" for nr, v in unreached if v[0]]
        tot["cov"] += cov; tot["reach"] += len(reach); tot["api"] += api; tot["diag"] += diag
        tot["unreached"] += len(unreached)
        pct = 100 * cov / len(reach) if reach else 100.0
        table.append(f"{name[:-5]:28} {cov:4}/{len(reach):<4} {pct:5.1f}%   api {api:3}  diagnostic {diag:3}  unreached {len(unreached):2}")
        gaps = [(nr, v) for nr, v in reach if not v[0]]
        if gaps:
            report.append(f"## {name[:-5]}  ({len(gaps)} reachable lines missed)")
            for nr, (_, _, method, text) in gaps:
                report.append(f"{nr:5}  {method:32} {text.rstrip()}")
            report.append("")
        for nr, (_, _, method, text) in unreached:
            listed.append(f"{name[:-5]}:{nr:<5} {text.strip()[:70]:70}  -- {UNREACHED_LINES[name][nr]}")
    report += ["## listed as unreachable from a .conf file (see UNREACHED in java-coverage.py)", ""] + listed
    (out / "uncovered.txt").write_text("\n".join(report) + "\n")
    print("\n".join(table))
    print(f"\n{'reachable':28} {tot['cov']:4}/{tot['reach']:<4} {100 * tot['cov'] / tot['reach']:5.1f}%"
          f"   excluded: api {tot['api']}, diagnostic {tot['diag']}, listed unreachable {tot['unreached']}")
    if stale:
        print("listed as unreachable but covered, fix UNREACHED: " + ", ".join(stale))

    # the whole library, so the scope above is a visible choice
    root = ET.parse(out / "report.xml").getroot()
    c = next(x for x in root.findall("counter") if x.get("type") == "LINE")
    mi, ci = int(c.get("missed")), int(c.get("covered"))
    print(f"{'whole library':28} {ci:4}/{mi + ci:<4} {100 * ci / (mi + ci):5.1f}%")


if __name__ == "__main__":
    main(sys.argv[1:])
