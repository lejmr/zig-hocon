import sys, pulse_pyhocon as p
try:
    c = p.parse_file(sys.argv[1])
    print(p.HOCONConverter.to_json(c))
except Exception as e:
    sys.stderr.write("ERROR: %s: %s\n" % (type(e).__name__, e)); sys.exit(1)
