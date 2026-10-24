import re, os, json, sys, glob, hashlib
OUT='/workspace/corpus/cases'; os.makedirs(OUT, exist_ok=True)
seen={}
def dec_c(s):  # C-like escapes (Scala/Java/Go/Python normal strings)
    out=[];i=0
    while i<len(s):
        c=s[i]
        if c=='\\' and i+1<len(s):
            n=s[i+1]
            m={'n':'\n','t':'\t','r':'\r','"':'"','\\':'\\',"'":"'",'b':'\b','f':'\f','0':'\0'}
            if n in m: out.append(m[n]); i+=2; continue
            if n=='u' and re.match(r'u[0-9a-fA-F]{4}', s[i+1:i+6]): out.append(chr(int(s[i+2:i+6],16))); i+=6; continue
            if n=='x' and re.match(r'x[0-9a-fA-F]{2}', s[i+1:i+4]): out.append(chr(int(s[i+2:i+4],16))); i+=4; continue
            out.append(n); i+=2; continue
        out.append(c); i+=1
    return ''.join(out)
def add(src, origin, kind='?'):
    if len(src)>4000: return
    h=hashlib.sha1(src.encode('utf-8','surrogatepass')).hexdigest()[:12]
    if h in seen: seen[h]['origins'].append(origin); return
    seen[h]={'id':h,'origins':[origin],'kind':kind}
    with open(f'{OUT}/{h}.conf','w',encoding='utf-8',errors='surrogatepass',newline='') as f: f.write(src)
strlit = r'("""(?:.|\n)*?"""(?!")|"(?:[^"\\\n]|\\.)*")'
def scala_lits(text):
    for m in re.finditer(strlit, text):
        s=m.group(1)
        if s.startswith('"""'): v=s[3:-3]
        else: v=dec_c(s[1:-1])
        yield m.start(), v
def lineno(text,pos): return text.count('\n',0,pos)+1
# 1. lightbend TestUtils lists
LB='/tmp/impl/lightbend_config/config/src/test/scala/com/typesafe/config/impl/'
t=open(LB+'TestUtils.scala').read()
for name,kind in [('invalidJsonInvalidConf','invalid'),('validJson','valid'),('validConfInvalidJson','valid')]:
    a=t.index('val '+name); b=min(t.index('\n    protected',a+5), t.index('\n    private',a+5))
    seg=t[a+len('val '+name):b]
    for pos,v in scala_lits(seg):
        add(v, f'lightbend_config/TestUtils.scala#L{lineno(t,a+pos)}', kind)
# 2. calls in scala tests (lightbend, sconfig)
pat=re.compile(r'(parseConfig|parseObject|parseString|parseValue|ConfigFactory\.parseString|resolveWithoutFallbacks|parse)\(\s*'+strlit)
for root,tag in [(LB,'lightbend_config'),('/tmp/impl/ekrich_sconfig/','ekrich_sconfig')]:
    for f in glob.glob(root+'**/*.scala', recursive=True):
        if 'test' not in f: continue
        t=open(f).read()
        for m in pat.finditer(t):
            s=m.group(2); v=s[3:-3] if s.startswith('"""') else dec_c(s[1:-1])
            if re.search(r'stripMargin', t[m.end():m.end()+20]): v=re.sub(r'(?m)^\s*\|','',v)
            add(v, f'{tag}/{os.path.relpath(f,root)}#L{lineno(t,m.start())}')
# 3. pyhocon & forks: ConfigFactory.parse_string( literal
pyl = r'([rbu]*"""(?:.|\n)*?"""|[rbu]*\'\'\'(?:.|\n)*?\'\'\'|[rbu]*"(?:[^"\\\n]|\\.)*"|[rbu]*\'(?:[^\'\\\n]|\\.)*\')'
for root,tag in [('/tmp/impl/chimpler_pyhocon/','chimpler_pyhocon'),('/tmp/impl/myjniak_hocon/','myjniak_hocon')]:
    for f in glob.glob(root+'**/test*.py', recursive=True):
        t=open(f).read()
        for m in re.finditer(r'(parse_string|loads|\.parse)\(\s*'+pyl, t):
            s=m.group(2); pre=re.match(r'[rbu]*',s).group(0); body=s[len(pre):]
            q=3 if body[:3] in ('"""',"'''") else 1
            v=body[q:-q]; 
            if 'r' not in pre: v=dec_c(v)
            add(v, f'{tag}/{os.path.relpath(f,root)}#L{lineno(t,m.start())}')
# 4. .NET akka HOCON: @"..." verbatim strings
for f in glob.glob('/tmp/impl/akkadotnet_HOCON/src/**/*Spec*.cs', recursive=True)+glob.glob('/tmp/impl/akkadotnet_HOCON/src/**/*Test*.cs', recursive=True):
    t=open(f,encoding='utf-8-sig').read()
    for m in re.finditer(r'@"((?:[^"]|"")*)"', t):
        v=m.group(1).replace('""','"')
        if '=' in v or ':' in v or '{' in v: add(v.replace('\r\n','\n'), f'akkadotnet_HOCON/{os.path.relpath(f,"/tmp/impl/akkadotnet_HOCON")}#L{lineno(t,m.start())}')
# 5. Go: backtick strings in *_test.go
for root,tag in [('/tmp/impl/gurkankaymak_hocon/','gurkankaymak_hocon'),('/tmp/impl/go-akka_configuration/','go-akka_configuration')]:
    for f in glob.glob(root+'**/*_test.go', recursive=True):
        t=open(f).read()
        for m in re.finditer(r'(ParseString|parseResource|ParseConfig|NewParser|strings.NewReader)\(\s*(`[^`]*`|"(?:[^"\\\n]|\\.)*")', t):
            s=m.group(2); v=s[1:-1] if s[0]=='`' else dec_c(s[1:-1])
            add(v, f'{tag}/{os.path.relpath(f,root)}#L{lineno(t,m.start())}')
# 6. ruby & cpp ports: string args to parse_config / parse_string / parse_object
for root,tag,gl in [('/tmp/impl/puppetlabs_ruby-hocon/','puppetlabs_ruby-hocon','spec/**/*.rb'),('/tmp/impl/puppetlabs_cpp-hocon/','puppetlabs_cpp-hocon','lib/tests/**/*.cc')]:
    for f in glob.glob(root+gl, recursive=True):
        t=open(f).read()
        for m in re.finditer(r'(parse_config|parse_string|parse_object|parse_value|parse)\(\s*(R"\((?:.|\n)*?\)"|"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\')', t):
            s=m.group(2)
            v=s[3:-2] if s.startswith('R"(') else (dec_c(s[1:-1]) if s[0]=='"' else s[1:-1].replace("\\'","'"))
            add(v, f'{tag}/{os.path.relpath(f,root)}#L{lineno(t,m.start())}')
# 7. file fixtures (root files only; included companions stay beside them -> run in place)
files=[]
for pat_ in ['/tmp/impl/o3co_xx.hocon/testdata/hocon/**/*.conf','/tmp/impl/o3co_xx.hocon/testdata/harvested/**/*.conf',
             '/tmp/impl/lightbend_config/config/src/test/resources/**/*.conf','/tmp/impl/emqx_hocon/sample-configs/**/*.conf',
             '/tmp/impl/emqx_hocon/etc/**/*.conf','/tmp/impl/puppetlabs_ruby-hocon/spec/fixtures/**/*.conf',
             '/tmp/impl/mikai233_hocon-rs/resources/**/*.conf','/tmp/impl/mockersf_hocon.rs/tests/data/**/*.conf',
             '/tmp/impl/chimpler_pyhocon/tests/**/*.conf','/tmp/impl/gurkankaymak_hocon/testdata/**/*.conf','/tmp/impl/akkadotnet_HOCON/**/*.conf',
             '/tmp/impl/josephtzeng_hocon-parser/test/**/*.conf']:
    files+=glob.glob(pat_, recursive=True)
json.dump(sorted(set(files)), open('/workspace/corpus/files.json','w'), indent=0)
json.dump(seen, open('/workspace/corpus/inline.json','w'), indent=0)
print('inline', len(seen), 'files', len(set(files)))
from collections import Counter
print(Counter(o['origins'][0].split('/')[0] for o in seen.values()))
