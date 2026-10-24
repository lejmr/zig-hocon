import sys, json, hocon
try:
    c = hocon.parse_file(sys.argv[1])
    print(json.dumps(c.to_object()))
except Exception as e:
    sys.stderr.write("ERROR: %s: %s\n" % (type(e).__name__, e)); sys.exit(1)
