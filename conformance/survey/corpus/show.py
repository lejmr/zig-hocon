import json,sys,os
d=json.load(open('diffs.json')); inline=json.load(open('inline.json'))
def load(f):
    r={}
    for line in open(f,encoding='utf-8',errors='replace'):
        line=line.rstrip('\n')
        if '\t' in line: p,x=line.split('\t',1); r[p]=x
    return r
J=load('java.tsv'); Z=load('zig.tsv')
cat=sys.argv[1]
for p in d[cat]:
    h=os.path.basename(p)[:-5]
    o=inline[h]['origins'][0] if h in inline else p.replace('/tmp/impl/','')
    try: src=open(p,encoding='utf-8',errors='replace').read()
    except Exception: continue
    print('='*3, h if h in inline else '', o)
    print('  IN :', repr(src[:300]))
    print('  JAV:', J[p][:200]); print('  ZIG:', Z[p][:200])
