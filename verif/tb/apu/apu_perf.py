#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""APU throughput baseline: collect bench counter lines, diff two captures.

Benches print tagged `key=value` lines (PASS, PASS-COMPUTE, STAT, QSTAT,
PERF <vector>, PERFR). `collect` turns sim logs into one JSON capture;
`diff` compares two captures under the rule of
specs/architecture/performance-area-scalability.md §1: the checked work must
be identical (identity fields), only cycles may move.

  apu_perf.py collect -o new.json rast=/tmp/.../sim.log shwave=.../sim.log
  apu_perf.py diff apu-perf-baseline.json new.json [--tol-pct 0.0]
  apu_perf.py show new.json

Exit codes of `diff`: 0 same work and no cycle regression, 1 work differs or a
run is missing, 2 a cycle total regressed by more than --tol-pct.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SCHEMA = 1
TAGS = ("PASS-COMPUTE", "PASS", "STAT", "QSTAT", "PERFR", "PERFT", "PERFC", "PERFV", "PERFX", "PERF")
KV = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)\b")
# Work that must not change between captures of the same run.
IDENTITY = {
    "pass": ("cases", "checks"),
    "pass_compute": ("g1", "g2", "ulp1", "ulp2", "maxulp"),
    "stat": ("tris", "pixwr"),
    "qstat": None,          # every field
    "perf": ("insns",),     # per vector
}
# Cycle totals a pass is expected to lower; a rise beyond tolerance fails.
CYCLES = {"pass": ("cycles",), "stat": ("busy",)}


def parse_log(path):
    run = {"perf": {}}
    for line in Path(path).read_text(errors="replace").splitlines():
        tag = next((t for t in TAGS if line.startswith(t + " ")), None)
        if tag is None:
            continue
        rest = line[len(tag) + 1:]
        vals = {k: int(v) for k, v in KV.findall(rest)}
        first = rest.split(None, 1)[0] if rest.strip() else ""
        name = first if "=" not in first else ""
        if tag == "PERF":
            key, n = name or "-", 2
            while key in run["perf"]:
                key, n = f"{name}#{n}", n + 1
            run["perf"][key] = vals
        elif tag == "PASS":
            run["pass"] = dict(vals, bench=name)
        else:
            run[tag.lower().replace("-", "_")] = vals
    if not run["perf"]:
        del run["perf"]
    derive(run)
    return run


def derive(run):
    d = {}
    perf = run.get("perf")
    if perf:
        tot = {}
        for rec in perf.values():
            for k, v in rec.items():
                tot[k] = tot.get(k, 0) + v
        d["perf_total"] = tot
        if tot.get("insns"):
            d["cycles_per_insn"] = round(tot["busy"] / tot["insns"], 2)
    stat, perfr = run.get("stat"), run.get("perfr")
    if stat and stat.get("pixwr"):
        d["busy_per_pixel"] = round(stat["busy"] / stat["pixwr"], 1)
    if perfr and stat and stat.get("busy"):
        cls = {k: v for k, v in perfr.items()
               if k not in ("mpw", "mpn", "fpw", "fpn")}
        d["class_sum"] = sum(cls.values())
        d["class_pct"] = {k: round(100.0 * v / stat["busy"], 1)
                          for k, v in cls.items() if v}
        for w, n in (("mpw", "mpn"), ("fpw", "fpn")):
            if perfr.get(n):
                d[f"{w}_per_{n}"] = round(perfr[w] / perfr[n], 2)
    perft, cyc = run.get("perft"), run.get("pass", {}).get("cycles")
    if perft and cyc:
        # device level: share of the session each engine is busy, the idle
        # remainder, and cycles per accepted request on each memory port
        d["engine_pct"] = {k: round(100.0 * perft[k] / cyc, 1)
                           for k in ("any", "ctl", "pump", "exec", "sh",
                                     "rast", "xfer") if perft.get(k)}
        d["idle_pct"] = round(100.0 * (cyc - perft.get("any", 0)) / cyc, 1)
        d["port_req"] = {k[4:]: v for k, v in perft.items()
                         if k.startswith("mpn_") and v}
        d["port_cyc_per_req"] = {
            k[4:]: round(perft["mpw_" + k[4:]] / v, 2)
            for k, v in perft.items() if k.startswith("mpn_") and v}
    perfc = run.get("perfc")
    if perfc:
        # FP0 frame-class counters: per-engine busy as a share of session
        # cycles plus raw per-class cycle counts.  rast's class_pct (from
        # PERFR) is folded in so `frame` is the self-contained stage view.
        cyc = run.get("pass", {}).get("cycles") or 0

        def _pct(b):
            return round(100.0 * b / cyc, 1) if cyc and b is not None else None

        fr = {
            "vnpump": {"busy": perfc.get("pump_b"),
                       "busy_pct": _pct(perfc.get("pump_b")),
                       "decode": perfc.get("pdec"), "exec": perfc.get("pexec"),
                       "poll": perfc.get("ppoll"),
                       "park": perfc.get("ppark"), "xfer": perfc.get("pxfer"),
                       "ctl": perfc.get("pctl")},
            "cmdexec": {"busy": perfc.get("ex_b"),
                        "busy_pct": _pct(perfc.get("ex_b")),
                        "assembly": perfc.get("easm"), "work": perfc.get("ewrk"),
                        "ctl": perfc.get("ectl")},
            "xfer": {"busy": perfc.get("xf_b"),
                     "busy_pct": _pct(perfc.get("xf_b")),
                     "rd": perfc.get("xrd"), "wr": perfc.get("xwr"),
                     "setup": perfc.get("xset")},
        }
        perfx = run.get("perfx")
        if perfx:
            # FP0b/c cmdexec assembly sub-classes: the easm catch-all
            # split by operand-resolve cluster; dispatch assembly is
            # further split into doto (pipe/lay/mod/issue) vs dres
            # (descriptor-set layout/pool/row resolution).
            fr["cmdexec"]["asm"] = {
                "rec": perfx.get("rec"), "doto": perfx.get("doto"),
                "dres": perfx.get("dres"), "draw": perfx.get("draw"),
                "xfer": perfx.get("xfer"), "brp": perfx.get("brp"),
                "evt": perfx.get("evt"), "qry": perfx.get("qry"),
                "other": perfx.get("oth")}
        perfv = run.get("perfv")
        if perfv:
            # FP0 vnfront class counters: the pump StFrontWait/pexec wait
            # decomposed by front-FSM operation class (object-model work).
            fr["vnfront"] = {
                "busy": perfv.get("vf_b"), "busy_pct": _pct(perfv.get("vf_b")),
                "core": perfv.get("core"), "submit": perfv.get("sub"),
                "wait_idle": perfv.get("waidle"), "fence": perfv.get("fence"),
                "objtab": perfv.get("ot"),
                "cmdrec": perfv.get("cr"), "cmdstream": perfv.get("cs"),
                "element": perfv.get("elem"), "bind": perfv.get("bind"),
                "pool": perfv.get("pool"),
                "payload": perfv.get("pay"), "dslayout": perfv.get("dsl"),
                "descset": perfv.get("dset"), "descupd": perfv.get("upd"),
                "shader": perfv.get("sh"), "pipeline": perfv.get("pipe"),
                "retire": perfv.get("ret"), "gpipeline": perfv.get("gp"),
                "image": perfv.get("img"), "query": perfv.get("qry"),
                "other": perfv.get("oth")}
        if "class_pct" in d:
            fr["rast"] = d["class_pct"]
        d["frame"] = fr
    if d:
        run["derived"] = d


def git_head():
    try:
        root = Path(__file__).resolve().parents[3]
        head = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
        return head or "unknown"
    except OSError:
        return "unknown"


def cmd_collect(a):
    runs = {}
    for spec in a.logs:
        name, _, path = spec.partition("=")
        if not path:
            sys.exit(f"collect: expected name=log, got {spec!r}")
        run = parse_log(path)
        if "pass" not in run:
            sys.exit(f"collect: {path}: no PASS line — refusing to record "
                     f"cycles of a run that did not pass")
        runs[name] = run
    out = {"schema": SCHEMA, "head": git_head(), "note": a.note, "runs": runs}
    Path(a.out).write_text(json.dumps(out, indent=1, sort_keys=True) + "\n")
    print(f"wrote {a.out}: {len(runs)} run(s)")


def load(path):
    cap = json.loads(Path(path).read_text())
    if cap.get("schema") != SCHEMA:
        sys.exit(f"{path}: schema {cap.get('schema')} != {SCHEMA}")
    return cap


def identity_diffs(name, b, n):
    out = []
    for sec, keys in IDENTITY.items():
        if sec == "perf":
            bv, nv = b.get("perf", {}), n.get("perf", {})
            if set(bv) != set(nv):
                out.append(f"{name}: perf vectors differ "
                           f"(-{sorted(set(bv) - set(nv))} "
                           f"+{sorted(set(nv) - set(bv))})")
            for vec in sorted(set(bv) & set(nv)):
                for k in keys:
                    if bv[vec].get(k) != nv[vec].get(k):
                        out.append(f"{name}: perf {vec} {k} "
                                   f"{bv[vec].get(k)} -> {nv[vec].get(k)}")
            continue
        bs, ns = b.get(sec), n.get(sec)
        if bs is None and ns is None:
            continue
        if bs is None or ns is None:
            out.append(f"{name}: section {sec} present on one side only")
            continue
        for k in (keys if keys is not None else sorted(set(bs) | set(ns))):
            if bs.get(k) != ns.get(k):
                out.append(f"{name}: {sec}.{k} {bs.get(k)} -> {ns.get(k)}")
    return out


def cmd_diff(a):
    base, new = load(a.base), load(a.new)
    work, regress, rows = [], [], []
    for name in sorted(base["runs"]):
        b, n = base["runs"][name], new["runs"].get(name)
        if n is None:
            if not a.subset:
                work.append(f"{name}: missing from {a.new}")
            continue
        work += identity_diffs(name, b, n)
        for sec, keys in CYCLES.items():
            for k in keys:
                bv, nv = b.get(sec, {}).get(k), n.get(sec, {}).get(k)
                if not bv or nv is None:
                    continue
                pct = 100.0 * (nv - bv) / bv
                rows.append((name, f"{sec}.{k}", bv, nv, pct))
                if pct > a.tol_pct:
                    regress.append(f"{name}: {sec}.{k} +{pct:.2f}%")
        bt = b.get("derived", {}).get("perf_total", {}).get("busy")
        nt = n.get("derived", {}).get("perf_total", {}).get("busy")
        if bt and nt is not None:
            pct = 100.0 * (nt - bt) / bt
            rows.append((name, "perf.busy", bt, nt, pct))
            if pct > a.tol_pct:
                regress.append(f"{name}: perf.busy +{pct:.2f}%")
    for name in sorted(set(new["runs"]) - set(base["runs"])):
        print(f"note: {name} is new (not in base)")
    w = max((len(r[0]) for r in rows), default=4)
    for name, key, bv, nv, pct in rows:
        print(f"{name:<{w}}  {key:<11} {bv:>12} -> {nv:>12}  {pct:+7.2f}%"
              f"  x{bv / nv if nv else 0:.2f}")
    for msg in work:
        print("WORK-DIFF", msg)
    for msg in regress:
        print("REGRESS", msg)
    if work:
        sys.exit(1)
    if regress:
        sys.exit(2)
    print("OK same checked work; no cycle regression")


def cmd_rebase(a):
    """Remove a bench-only constant from the origin's session totals.

    COLD and WARM are two captures of the SAME RTL that differ only in a
    bench setup cost (e.g. the object-table cold-boot sweep the bench now
    preloads away).  For every run present in all three captures the
    per-run delta COLD-WARM is subtracted from ORIGIN's pass.cycles and
    recorded as `bench_adjust`, so the origin stays comparable.  Refuses
    unless COLD and WARM did identical checked work and identical engine
    work (STAT / PERFR / PERF sections equal), i.e. the delta is setup only.
    """
    origin, cold, warm = load(a.origin), load(a.cold), load(a.warm)
    n = 0
    for name, o in sorted(origin["runs"].items()):
        c, w = cold["runs"].get(name), warm["runs"].get(name)
        if c is None or w is None:
            continue
        bad = identity_diffs(name, c, w)
        for sec in ("stat", "perfr", "perf"):
            if c.get(sec) != w.get(sec):
                bad.append(f"{name}: {sec} differs between cold and warm")
        if bad:
            sys.exit("rebase refused:\n  " + "\n  ".join(bad))
        delta = c["pass"]["cycles"] - w["pass"]["cycles"]
        if delta == 0:
            continue
        if not a.min <= delta <= a.max:
            sys.exit(f"rebase refused: {name} delta {delta} outside "
                     f"[{a.min}, {a.max}]")
        o["pass"]["cycles"] -= delta
        o["bench_adjust"] = o.get("bench_adjust", 0) + delta
        derive(o)
        n += 1
        print(f"{name}: origin cycles -{delta} -> {o['pass']['cycles']}")
    origin["note"] = (origin.get("note", "") + " | " + a.note).strip(" |")
    Path(a.out).write_text(json.dumps(origin, indent=1, sort_keys=True) + "\n")
    print(f"wrote {a.out}: {n} run(s) rebased")


def cmd_show(a):
    cap = load(a.capture)
    for name, run in sorted(cap["runs"].items()):
        p = run.get("pass", {})
        print(f"{name}: cases={p.get('cases')} checks={p.get('checks')} "
              f"cycles={p.get('cycles')}")
        for k, v in sorted(run.get("derived", {}).items()):
            print(f"  {k}: {v}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("-o", "--out", required=True)
    c.add_argument("--note", default="")
    c.add_argument("logs", nargs="+", metavar="name=log")
    c.set_defaults(fn=cmd_collect)
    d = sub.add_parser("diff")
    d.add_argument("base")
    d.add_argument("new")
    d.add_argument("--tol-pct", type=float, default=0.0)
    d.add_argument("--subset", action="store_true",
                   help="allow NEW to hold only some of BASE's runs")
    d.set_defaults(fn=cmd_diff)
    r = sub.add_parser("rebase", help=cmd_rebase.__doc__.splitlines()[0])
    r.add_argument("origin")
    r.add_argument("cold")
    r.add_argument("warm")
    r.add_argument("-o", "--out", required=True)
    r.add_argument("--min", type=int, required=True)
    r.add_argument("--max", type=int, required=True)
    r.add_argument("--note", required=True)
    r.set_defaults(fn=cmd_rebase)
    s = sub.add_parser("show")
    s.add_argument("capture")
    s.set_defaults(fn=cmd_show)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
