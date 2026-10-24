import json,sys
def load(f):
    d={}
    for line in open(f,encoding='utf-8',errors='replace'):
        line=line.rstrip('\n')
        if '\t' not in line: continue
        p,r=line.split('\t',1); d[p]=r
    return d
J=load('java.tsv'); Z=load('zig.tsv')
inline=json.load(open('inline.json'))
def norm(r):
    if r.startswith('ERROR'): return 'ERR'
    try: return json.loads(r)
    except Exception: return 'BADJSON:'+r[:80]
cats={'both_ok_same':0,'both_err':0,'diff_value':[], 'zig_err_java_ok':[], 'zig_ok_java_err':[]}
for p in J:
    j,z=norm(J[p]),norm(Z.get(p,'ERROR missing'))
    if j=='ERR' and z=='ERR': cats['both_err']+=1
    elif j==z: cats['both_ok_same']+=1
    elif z=='ERR': cats['zig_err_java_ok'].append(p)
    elif j=='ERR': cats['zig_ok_java_err'].append(p)
    else: cats['diff_value'].append(p)
for k,v in cats.items(): print(k, v if isinstance(v,int) else len(v))
json.dump({k:v for k,v in cats.items() if isinstance(v,list)}, open('diffs.json','w'), indent=1)
