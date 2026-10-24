import json,glob,os
serious=['java-1.4.9','lightbend-main','sconfig','ruby-hocon','cpp-hocon','go.hocon','rs.hocon','ts.hocon','py.hocon','hocon2','hocon-rs','akkadotnet-hocon','gurkankaymak-hocon','pyhocon','mockersf-hocon','emqx-hocon','pulse-pyhocon','pushcorn-hocon-parser']
serious=[s for s in serious if os.path.getsize('results/spec/'+s+'.json')>0]
data={i:json.load(open('results/spec/'+i+'.json')) for i in serious+['zig-hocon']}
cases=sorted(data['zig-hocon']['cases'])
rows=[]
for c in cases:
    v={i:data[i]['cases'].get(c) for i in serious}
    np=sum(1 for x in v.values() if x=='pass')
    rows.append((np,c,[i for i in serious if v[i]=='pass']))
rows.sort()
for np,c,ps in rows[:40]:
    print(f"{np:2}/{len(serious)} {c}  pass: {','.join(p[:9] for p in ps)}")
