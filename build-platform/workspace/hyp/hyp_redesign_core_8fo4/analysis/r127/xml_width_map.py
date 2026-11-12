# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Elaborated packed-net widths from a Verilator --xml-only dump, written as an
sv-timing `--width-map` (schema sv-timing-width-map.v1).

The package's own producer is tools/rtlil_width_map.py over a yosys-slang
RTLIL dump; this is the same contract from the elaborator already used for the
liveness census (elab_hierarchy.sh), so the hyp8 board can resolve the widths
the source text cannot (constant functions, parameter types, struct fields).
Keyed by the base module name; when specializations or generate scopes
disagree the widest net is kept (the conservative direction). Unpacked arrays
are skipped, as the consumer only applies entries to packed declarations.

  python xml_width_map.py <g6lc_core.xml> <out.json>
"""
import json
import re
import sys

BASIC = {"logic": 1, "bit": 1, "reg": 1, "int": 32, "integer": 32, "longint": 64,
         "shortint": 16, "byte": 8, "time": 64}


def const_int(s):
    m = re.search(r"'s?h([0-9a-fA-F_xzXZ]+)", s)
    if m:
        try:
            return int(m.group(1).replace("_", ""), 16)
        except ValueError:
            return None
    try:
        return int(s)
    except ValueError:
        return None


def main():
    xml = open(sys.argv[1], encoding="utf-8", errors="replace").read().replace("&apos;", "'")
    tt = xml[xml.index("<typetable"):]
    types = {}
    for m in re.finditer(r"<(\w+dtype) ([^>]*?)(/>|>)", tt):
        kind, attrs, close = m.group(1), m.group(2), m.group(3)
        a = dict(re.findall(r'(\w+)="([^"]*)"', attrs))
        body = ""
        if close == ">":
            end = tt.index("</" + kind + ">", m.end())
            body = tt[m.end():end]
        types[a.get("id")] = (kind, a, body)
    memo = {}

    def width(tid, depth=0):
        if tid in memo:
            return memo[tid]
        if depth > 40 or tid not in types:
            return None
        kind, a, body = types[tid]
        w = None
        if kind == "basicdtype":
            if "left" in a and "right" in a:
                w = abs(int(a["left"]) - int(a["right"])) + 1
            else:
                w = BASIC.get(a.get("name"))
        elif kind in ("refdtype", "enumdtype", "paramtypedtype"):
            w = width(a.get("sub_dtype_id"), depth + 1)
        elif kind == "packarraydtype":
            cs = [const_int(c) for c in re.findall(r'<const [^>]*?name="([^"]+)"', body)[:2]]
            sub = width(a.get("sub_dtype_id"), depth + 1)
            if len(cs) == 2 and None not in cs and sub:
                w = (abs(cs[0] - cs[1]) + 1) * sub
        elif kind in ("structdtype", "uniondtype"):
            ms = [width(x, depth + 1) for x in re.findall(r'<memberdtype [^>]*?sub_dtype_id="(\d+)"', body)]
            if ms and None not in ms:
                w = sum(ms) if kind == "structdtype" else max(ms)
        memo[tid] = w
        return w

    out = {}
    nvar = 0
    for m in re.finditer(r'<module [^>]*?name="([^"]+)"[^>]*?origName="([^"]+)"[^>]*>', xml):
        end = xml.find("</module>", m.end())
        nets = out.setdefault(m.group(2), {})
        for v in re.finditer(r'<var [^>]*?name="([^"]+)"[^>]*?dtype_id="(\d+)"[^>]*?>', xml[m.end():end]):
            tag = v.group(0)
            if 'param="true"' in tag or 'localparam="true"' in tag:
                continue
            name = re.search(r'origName="([^"]+)"', tag)
            name = (name.group(1) if name else v.group(1)).split(".")[-1]
            w = width(v.group(2))
            if w and 0 < w <= 1 << 20:
                nets[name] = max(nets.get(name, 0), w)
                nvar += 1
    out = {k: v for k, v in out.items() if v}
    json.dump({"schema": "sv-timing-width-map.v1", "source": "verilator --xml-only " + sys.argv[1],
               "modules": out}, open(sys.argv[2], "w", encoding="utf-8", newline="\n"), indent=0)
    print(f"modules={len(out)} nets={sum(len(v) for v in out.values())} vars_seen={nvar}")


if __name__ == "__main__":
    main()
