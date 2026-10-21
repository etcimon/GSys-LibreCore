#!/usr/bin/env python3
"""Structural pass: instantiation port match, provider uniqueness, UTF-8.
Text-only; no lint/elab/sim."""
import os, re, pathlib

_HYP = pathlib.Path(os.environ.get("HYP_ROOT") or
                    pathlib.Path(__file__).resolve().parents[2])
TREES = [_HYP / "hyp_redesign_core_8fo4", _HYP / "hyp_redesign_corev_apu_8fo4"]
sv_files = []
for t in TREES:
    sv_files += [p for p in t.rglob("*.sv") if ".git" not in p.parts]
sv_files += [p for p in TREES[0].rglob("*.svh")]

CMT = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)
def strip(txt): return CMT.sub(" ", txt)

def balanced(s, i):
    d = 0
    for k in range(i, len(s)):
        c = s[k]
        if c == "(": d += 1
        elif c == ")":
            d -= 1
            if d == 0: return k
    return -1

def split_top(s):
    out, d, last = [], 0, 0
    for i, c in enumerate(s):
        if c in "([{": d += 1
        elif c in ")]}": d -= 1
        elif c == "," and d == 0:
            out.append(s[last:i]); last = i + 1
    out.append(s[last:])
    return out

mod_ports, mod_file = {}, {}
MOD = re.compile(r"\bmodule\s+([A-Za-z_]\w*)")
DIRECT = re.compile(r"\b(?:input|output|inout)\b")
IDENT = re.compile(r"[A-Za-z_]\w*")

utf8_bad = []
unparsed = []
for f in sv_files:
    try:
        txt = f.read_text(encoding="utf-8", errors="strict")
    except UnicodeDecodeError as e:
        utf8_bad.append((str(f), str(e))); continue
    t = strip(txt)
    for m in MOD.finditer(t):
        name = m.group(1)
        ok = False
        # skip optional `import pkg::*;` clause(s) before the header parens
        p = m.end()
        while True:
            mm = re.match(r"[ \t\n]*import\b", t[p:])
            if not mm: break
            p = t.find(";", p + mm.end())
            if p < 0: break
            p += 1
        semi = t.find(";", p)
        po = t.find("(", p)
        if po < 0 or (semi >= 0 and semi < po):
            unparsed.append((name, str(f)))
            mod_file.setdefault(name, []).append(str(f))
            continue
        h = t.find("#", p, po)
        if h != -1:
            e = balanced(t, po)
            if e < 0:
                unparsed.append((name, str(f)))
                mod_file.setdefault(name, []).append(str(f))
                continue
            semi = t.find(";", e)   # ';' inside param defaults (struct packed) must not abort
            po = t.find("(", e)
            if po < 0 or (semi >= 0 and semi < po):
                unparsed.append((name, str(f)))
                mod_file.setdefault(name, []).append(str(f))
                continue
        pe = balanced(t, po)
        if pe < 0:
            unparsed.append((name, str(f)))
            mod_file.setdefault(name, []).append(str(f))
            continue
        ports = set()
        for item in split_top(t[po+1:pe]):
            it = item.strip()
            has_dir = DIRECT.search(it) is not None
            if not has_dir:
                # bare continuation of a shared direction decl (input a, b, c)
                # or an interface-typed port (AXI_BUS.Slave slave)
                pass
            # cut at the first '=' at bracket depth 0 (a default value);
            # '=' inside [...]/(...) ranges doesn't count
            d = 0; cut = len(it)
            for i2, c in enumerate(it):
                if c in "([{": d += 1
                elif c in ")]}": d -= 1
                elif c == "=" and d == 0:
                    if it[max(0, i2-1)] in "<>!": continue
                    if i2 + 1 < len(it) and it[i2+1] == "=": continue
                    cut = i2; break
            it = it[:cut]
            # strip unpacked dimensions after the port name
            while True:
                m2 = re.search(r"\[[^\]]*\]\s*$", it)
                if not m2: break
                it = it[:m2.start()]
            ids = IDENT.findall(it)
            ids = [x for x in ids if x not in ("input","output","inout","wire","logic","reg","tri","var","signed","unsigned","ref")]
            if ids:
                ports.add(ids[-1])
        mod_ports[name] = ports
        mod_file.setdefault(name, []).append(str(f))

print(f"modules declared: {len(mod_ports)}")
print("note: modules with unparsed headers are skipped in the port check")
dup = {n: fs for n, fs in mod_file.items() if len(fs) > 1}
cross = {n: fs for n, fs in dup.items()
         if not all("hyp_redesign_core_8fo4" in x or "hyp_redesign_corev_apu_8fo4" in x for x in fs)}
print(f"duplicate module names (cross-tree vendor mirrors are expected): {len(dup)}")

KW = set("""module endmodule if else begin end always_ff always_comb always_latch always
assign function task for while case casex casez unique priority return typedef import
package interface program generate assert assume cover property sequence initial final
localparam parameter let expect wait fork join join_any join_none disable posedge negedge
or and not input output inout logic wire reg signed unsigned int integer real time bit
byte shortint longint shortreal chandle string event enum struct union endcase endfor
endfunction endtask endpackage endinterface endprogram endgenerate endproperty endsequence
do forever repeat automatic static const ref this super new null void tagged rand randcase
randsequence bins binsof illegal_bins ignore_bins cross with inside dist matches solve
before throughout within intersect first_match iff implies checker endchecker config
endconfig primitive endprimitive table endtable specify endspecify specparam covergroup
endgroup coverpoint option type_option genvar alias modport use wildcard extern pure
context virtual protected local static extends implements constraint dist soft order
foreach endchecker union packed typedef enum""".split())

LINE = re.compile(r"(?m)^[ \t]*([A-Za-z_]\w*)[ \t]*")
checked = 0
missing = {}
bad = []
for f in sv_files:
    try:
        txt = f.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    t = strip(txt)
    # candidate lines: start with an identifier
    for m in LINE.finditer(t):
        mod = m.group(1)
        if mod in KW or mod.startswith("end"):
            continue
        p = m.end()
        # skip whitespace
        while p < len(t) and t[p] in " \t\n":
            p += 1
        if p >= len(t):
            continue
        if t[p] == "#":
            # parameter block
            pp = t.find("(", p)
            if pp < 0 or t[p+1:pp].strip() not in ("", "("):
                continue
            e = balanced(t, pp)
            if e < 0: continue
            q = e + 1
            while q < len(t) and t[q] in " \t\n": q += 1
            mm = re.match(r"([A-Za-z_]\w*)[ \t\n]*\(", t[q:])
            if not mm: continue
            body_start = q + mm.end() - 1
        else:
            mm = re.match(r"([A-Za-z_]\w*)[ \t\n]*\(", t[p:])
            if not mm: continue
            body_start = p + mm.end() - 1
        # must open with .port(
        e2 = balanced(t, body_start)
        if e2 < 0: continue
        body = t[body_start+1:e2]
        if not re.match(r"\s*\.[A-Za-z_]\w*\s*\(", body):
            continue
        if mod not in mod_ports:
            missing.setdefault(mod, set()).add(str(f))
            continue
        checked += 1
        conns = set()
        for item in split_top(body):
            mm = re.match(r"\s*\.([A-Za-z_]\w*)", item)
            if mm:
                conns.add(mm.group(1))
        unknown = conns - mod_ports[mod]
        if unknown and mod_ports[mod]:
            bad.append((mod, sorted(unknown), str(f)))

print(f"instantiations checked: {checked}")
print(f"unknown-module instantiations: {sum(len(v) for v in missing.values())} ({len(missing)} distinct)")
for mod, fs in sorted(missing.items()):
    print(f"  UNKNOWN {mod}: {len(fs)} file(s), e.g. {sorted(fs)[0]}")
print(f"bad named ports: {len(bad)}")
for mod, unk, f in bad[:80]:
    print(f"  BADPORT {mod}: {unk} in {f}")
print(f"utf-8 failures: {len(utf8_bad)}")
for f_, e in utf8_bad[:10]:
    print("  UTF8", f_, e)
print(f"unparsed module headers (skipped in port check): {len(unparsed)}")
for n, f_ in unparsed[:30]:
    print("  UNPARSED", n, f_)


# keep tools/ free of compiled bytecode (the identity grep covers every
# file type — *.pyc embeds the original source tokens)
def _cleanup_pycache():
    import pathlib as _pl
    import shutil as _sh
    _d = _pl.Path(__file__).resolve().parent
    _sh.rmtree(_d / "__pycache__", ignore_errors=True)
    for _f in _d.glob("*.pyc"):
        try:
            _f.unlink()
        except OSError:
            pass


_cleanup_pycache()
