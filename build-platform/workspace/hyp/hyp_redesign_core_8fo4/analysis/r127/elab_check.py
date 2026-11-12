# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Compare two Verilator --xml-only dumps of the hyp8 core: the elaborated cell
set (instance paths), and the HypCfg constant plus the staging localparams of
the modules that read it. Used to show a profile-threading edit changed no
hierarchy and which staging each subtree elaborates.

  python elab_check.py <a.xml> [<b.xml>]
"""
import re
import sys

WATCH = ("TLB_STAGED", "PDEC", "STLB_DLY", "LU_EXPEND")


def read(p):
    xml = open(p, encoding="utf-8", errors="replace").read().replace("&apos;", "'")
    cells = set(re.findall(r'<cell [^>]*?hier="([^"]+)"', xml))
    prof, watch = {}, {}
    for m in re.finditer(r'<module [^>]*?name="([^"]+)"[^>]*?origName="([^"]+)"[^>]*>', xml):
        body = xml[m.end():xml.find("</module>", m.end())]
        hc = re.search(r'<var [^>]*?name="HypCfg"[^>]*?>\s*<const [^>]*?name="([^"]+)"', body)
        if hc:
            prof.setdefault(hc.group(1), set()).add(m.group(2))
        for w in WATCH:
            v = re.search(r'<var [^>]*?name="%s"[^>]*?>\s*<const [^>]*?name="([^"]+)"' % w, body)
            if v:
                watch[f"{m.group(2)}.{w}"] = v.group(1)
    return cells, prof, watch


def main():
    a = read(sys.argv[1])
    print(f"A cells={len(a[0])} profiles={len(a[1])}")
    for k, v in a[1].items():
        print(f"  profile ...{k[-18:]} modules={len(v)} e.g. {sorted(v)[:6]}")
    print("  " + " ".join(f"{k}={v}" for k, v in sorted(a[2].items())))
    if len(sys.argv) > 2:
        b = read(sys.argv[2])
        print(f"B cells={len(b[0])} profiles={len(b[1])}")
        print("  " + " ".join(f"{k}={v}" for k, v in sorted(b[2].items())))
        print(f"cells only in A: {sorted(a[0] - b[0])[:8]}  only in B: {sorted(b[0] - a[0])[:8]}")
        print("CELL SETS IDENTICAL" if a[0] == b[0] else "CELL SETS DIFFER")


if __name__ == "__main__":
    main()
