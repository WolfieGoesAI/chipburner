import re, sys, collections
x = open(sys.argv[1], encoding='utf-8', errors='replace').read()
x = re.sub(r'<!--.*?-->', '', x, flags=re.S)
# sections: <database type="..."> ... </database>
out = []
for m in re.finditer(r'<database\s+type="([^"]+)"(.*?)</database', x, flags=re.S):
    dbtype, body = m.group(1), m.group(2)
    if dbtype not in ("INFOIC",): continue
    fam = collections.OrderedDict()
    mfr = None
    for t in re.finditer(r'<manufacturer\s+name="([^"]*)"|<ic\s+(.*?)/>', body, flags=re.S):
        if t.group(1) is not None: mfr = t.group(1); continue
        a = t.group(2)
        ty = re.search(r'\btype="(\d+)"', a); nm = re.search(r'\bname="([^"]+)"', a)
        if not ty or not nm or ty.group(1) != "2": continue
        for n in nm.group(1).split(','):
            n = n.strip().split('@')[0]
            key = (mfr or "?")
            fam.setdefault(key, set()).add(n)
    for k, v in fam.items():
        v = sorted(v)
        # group by prefix letters+digits head
        pre = collections.Counter(re.match(r'[A-Z]+\d{0,2}', s.upper()).group(0) if re.match(r'[A-Z]+\d{0,2}', s.upper()) else s for s in v)
        out.append(f"{dbtype} | {k}: {len(v)} | " + ", ".join(f"{p}({c})" for p, c in pre.most_common(14)) + " | e.g. " + ", ".join(v[:6]))
print("\n".join(out))
