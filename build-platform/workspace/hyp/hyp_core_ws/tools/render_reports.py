# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""Render hyp8 Phase-0 reports from an sv-timing `correct` JSON.

Usage:
    python tools/render_reports.py <emit-dir> [--top <module>] [--tag core]

<emit-dir> is under the provenance workspace (hyp8-src/emit). Report tables
go to hyp8-src/reports (they may carry upstream names); the cut-ledger goes
to this tree's analysis/ and is written with renamed module/file names so the
tree stays identity-free.
"""
import json
import math
import os
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rename import apply_rename, rename_ident, rename_path  # noqa: E402

SRC_ROOT = Path(os.environ.get("HYP8_SRC_ROOT")
                or Path(__file__).resolve().parents[5])
WS = Path(__file__).resolve().parent.parent              # hyp_core_ws/
PROV = SRC_ROOT / "build-platform" / "workspace" / "build" / "sv-timing" \
    / "hyp8-src"
REPORTS = PROV / "reports"
ANALYSIS = WS / "analysis"
ADJUSTED = PROV / "inputs" / "adjusted-fo4.json"

BUDGET = 8.0


def tier_of(d: float) -> str:
    if d <= BUDGET:
        return "COPY"
    if d <= 16:
        return "T3"
    if d <= 32:
        return "T2"
    return "T1"


def load_adjusted() -> dict:
    if not ADJUSTED.exists():
        return {}
    doc = json.loads(ADJUSTED.read_text(encoding="utf-8"))
    rows = doc.get("modules", doc if isinstance(doc, list) else [])
    return {r["module"]: r for r in rows}


def emit_to_source(manifest_path: Path) -> dict:
    """normalized emit_rel (path under corrected/) -> repo-rel source path."""
    out = {}
    if manifest_path.exists():
        man = json.loads(manifest_path.read_text("utf-8"))
        prefix = str(SRC_ROOT).replace("\\", "/") + "/"
        for e in man.get("entries", []):
            er = e["emit_rel"].replace("\\", "/")
            src = e["source"].replace("\\", "/")
            if src.startswith(prefix):
                src = src[len(prefix):]
            out[er] = src
    return out


def norm_emit_rel(file_field: str) -> str:
    f = (file_field or "").replace("\\", "/")
    m = re.search(r"corrected/(.*)$", f)
    return m.group(1) if m else f


def strip_repo_prefix(p: str) -> str:
    p = (p or "").replace("\\", "/")
    pref = str(SRC_ROOT).replace("\\", "/") + "/"
    return p[len(pref):] if p.startswith(pref) else p


def detect_top(correct: dict) -> str | None:
    """The single elaborated root: a requested module that is never a child."""
    pa = correct["post_analyze"]
    children = set()
    for m in pa.get("modules", []):
        for inst in m.get("instances") or []:
            ct = inst.get("child_type") or inst.get("child_module")
            if ct:
                children.add(ct)
    roots = [n for n in (pa.get("modules_requested") or [])
             if n not in children]
    return roots[0] if len(roots) == 1 else None


def module_stats(correct: dict, top: str, emit_dir: Path,
                 extra_roots=()):
    pa = correct["post_analyze"]
    modules = pa.get("modules", [])
    e2s = emit_to_source(emit_dir / "corrected" / "svt_emit_manifest.json")

    # instantiated = the emit's elaborated module set: modules_requested ==
    # all modules minus frequency_closure.uninstantiated_modules (the tool's
    # own elaboration — syntactic child_type reachability over-counts
    # generate-dead branches). For the closure emit additionally intersect
    # with transitive reachability from `top`.
    requested = set(pa.get("modules_requested") or [])
    if not requested:
        requested = {m["name"] for m in modules} - set(
            pa.get("frequency_closure", {}).get("uninstantiated_modules")
            or [])
    childmap = defaultdict(set)
    for m in modules:
        for inst in m.get("instances") or []:
            ct = inst.get("child_type") or inst.get("child_module")
            if ct:
                childmap[m["name"]].add(ct)
    seen = set()
    # extra_roots: additional cone seeds whose names live in the emit but
    # hang under a *new* parent the emit predates (e.g. g6lc_soc's
    # peripheral children — the emit has no g6lc_soc node).
    stack = [top] + list(extra_roots)
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        stack.extend(childmap.get(n, ()))
    reachable = requested & seen if top in seen else requested

    per_mod_paths = defaultdict(list)
    for p in pa.get("paths", []):
        if not p.get("multi_cycle"):
            per_mod_paths[p.get("module_id")].append(p)

    adjusted = load_adjusted()
    rows = []
    for m in modules:
        name = m["name"]
        src_file = e2s.get(norm_emit_rel(m.get("file", "")),
                           strip_repo_prefix(m.get("file", "")))
        paths = per_mod_paths.get(m.get("id"), [])
        worst = None
        best_cal = None
        for p in paths:
            tf = p.get("total_fo4") or 0.0
            if worst is None or tf > (worst.get("total_fo4") or 0.0):
                worst = p
            cf = p.get("calibrated_fo4")
            if cf is not None and (best_cal is None or cf > best_cal):
                best_cal = cf
        structural = (worst or {}).get("total_fo4") or 0.0
        adj_row = adjusted.get(name)
        if adj_row and adj_row.get("source") == "measured":
            d = adj_row["adjusted_fo4"]
            basis = "adjusted"
        elif best_cal is not None:
            d = best_cal
            basis = "calibrated"
        else:
            d = structural
            basis = "structural"
        failing = sum(
            1 for p in paths
            if (p.get("closes") is False) or ((p.get("slack_fo4") or 0.0) < 0))
        rows.append({
            "name": name,
            "file": src_file,
            "worst": worst,
            "structural": structural,
            "calibrated": best_cal,
            "adjusted": (adj_row or {}).get("adjusted_fo4"),
            "adjusted_source": (adj_row or {}).get("source"),
            "D": d,
            "basis": basis,
            "tier": tier_of(d),
            "failing": failing,
            "npaths": len(paths),
            "instantiated": name in reachable,
        })
    rows.sort(key=lambda r: (-r["D"], r["name"]))
    return rows, reachable, pa


def fmt(x, nd=1):
    return f"{x:.{nd}f}" if isinstance(x, (int, float)) else "-"


def write_board(rows, pa, top, tag, outdir: Path):
    counts = Counter(r["tier"] for r in rows if r["instantiated"])
    ninst = sum(1 for r in rows if r["instantiated"])
    banner = (pa.get("banner") or "").strip().splitlines()
    run_id = banner[0] if banner else "?"
    lines = [
        f"# board.md — {tag} module board at the {fmt(BUDGET,0)}-FO4 budget",
        "",
        f"- run: `{run_id}`",
        f"- budget: {fmt(pa.get('budget_fo4'))} FO4 "
        f"(target {pa.get('target_mhz')} MHz, fo4_ps {pa.get('fo4_ps')}, "
        f"margin {pa.get('budget_margin')}); hyp8 deciding budget = "
        f"{fmt(BUDGET,0)} FO4",
        f"- top (instantiation root): `{top}` — {ninst} instantiated / "
        f"{len(rows)} analyzed modules",
        f"- tier counts (instantiated only): "
        + ", ".join(f"{t}={counts.get(t,0)}" for t in ("COPY", "T3", "T2",
                                                      "T1")),
        "- D = adjusted (measured board) else calibrated else structural; "
        "multi_cycle paths excluded; NOT-IN-HYP8 = outside the elaborated, "
        "top-reachable set",
        "",
        "| module | tier | D | basis | structural | calibrated | adjusted "
        "| dep_path | failing | npaths |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        name = r["name"] if r["instantiated"] \
            else f"{r['name']} (NOT-IN-HYP8)"
        w = r["worst"] or {}
        se = (f"{w.get('path_kind','-')}: {w.get('startpoint','?')} -> "
              f"{w.get('endpoint','?')}")
        if len(se) > 130:
            se = se[:127] + "..."
        lines.append(
            f"| {name} | {r['tier']} | {fmt(r['D'])} | {r['basis']} "
            f"| {fmt(r['structural'])} | {fmt(r['calibrated'])} "
            f"| {fmt(r['adjusted'])} | {se} | {r['failing']} | "
            f"{r['npaths']} |")
    (outdir / f"board{'.'+tag if tag!='core' else ''}.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8")


def tbl(headers, rows_iter):
    out = ["| " + " | ".join(headers) + " |",
           "|" + "---|" * len(headers)]
    for r in rows_iter:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return out


def write_bottlenecks(correct, tag, outdir: Path):
    items = correct.get("bottlenecks")
    lines = [f"# bottlenecks.md — {tag} staged-net caller waits", ""]
    if items is None:
        lines.append("_no bottlenecks array in correct.json_")
    elif not items:
        lines.append("_empty — derives from applied InsertReg edits; none "
                     "applied under --contracts-only_")
    for b in items or []:
        lines += [
            f"## {b.get('module')} :: {b.get('net')} "
            f"(+{b.get('added_cycles')} cycles via {b.get('via')})",
            "",
            f"- verdict: {b.get('verdict')}",
            f"- port: {b.get('port')}  stages: "
            f"{', '.join(b.get('stages') or [])}  "
            f"replicable: {b.get('replicable')}",
            "",
        ]
        callers = b.get("callers") or []
        if callers:
            lines += tbl(
                ["caller module", "instance", "caller", "kind",
                 "wait_cycles", "line", "bubble"],
                ([c.get("module"), c.get("instance"), c.get("caller"),
                  c.get("kind"), c.get("wait_cycles"), c.get("line"),
                  c.get("bubble")] for c in callers))
        absorbed = b.get("absorbed") or []
        if absorbed:
            lines += ["", "**absorbed:**", ""] + tbl(
                ["caller module", "instance", "caller", "kind",
                 "wait_cycles", "line", "bubble"],
                ([c.get("module"), c.get("instance"), c.get("caller"),
                  c.get("kind"), c.get("wait_cycles"), c.get("line"),
                  c.get("bubble")] for c in absorbed))
        lines.append("")
    (outdir / f"bottlenecks{'.'+tag if tag!='core' else ''}.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8")


def write_carry_over(correct, tag, outdir: Path):
    items = correct.get("carry_over")
    lines = [f"# carry_over.md — {tag} emitted-stage carry-over", ""]
    if items is None:
        lines.append("_no carry_over array in correct.json_")
    elif not items:
        lines.append("_empty — derives from applied InsertReg edits; none "
                     "applied under --contracts-only_")
    for c in items or []:
        lines += [
            f"## {c.get('module')} :: {c.get('net')} -> port {c.get('port')}",
            "",
            f"- stage: {c.get('stage')}  verdict: {c.get('verdict')}",
            "",
        ]
        for cons in c.get("consumers") or []:
            lines += [
                f"### consumer {cons.get('parent')} :: "
                f"{cons.get('instance')} ({cons.get('actual')})",
                f"- feeds_back: {cons.get('feeds_back')}  "
                f"propagates_up: {cons.get('propagates_up')}",
                "",
            ]
            readers = cons.get("readers") or []
            if readers:
                lines += tbl(
                    ["reader lhs", "line", "kind"],
                    ([r.get("lhs"), r.get("line"), r.get("kind")]
                     for r in readers))
                lines.append("")
    (outdir / f"carry_over{'.'+tag if tag!='core' else ''}.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8")


def write_propagation(correct, tag, outdir: Path):
    items = correct.get("propagation")
    lines = [f"# propagation.md — {tag} retime/adaptation plans", ""]
    if items is None:
        lines.append("_no propagation array in correct.json_")
    elif not items:
        lines.append("_empty — derives from applied InsertReg edits; none "
                     "applied under --contracts-only_")
    for p in items or []:
        lines += [
            f"## {p.get('module')} :: {p.get('port')}",
            "",
            f"- verdict: {p.get('verdict')}  valid: {p.get('valid')}  "
            f"retimable: {p.get('retimable')}",
            f"- moved_registers: "
            f"{', '.join(p.get('moved_registers') or [])}",
            "",
        ]
        steps = p.get("steps") or []
        if steps:
            lines += tbl(
                ["module", "net", "action", "depth", "balance", "guards"],
                ([s.get("module"), s.get("net"), s.get("action"),
                  s.get("depth"), ", ".join(s.get("balance") or []),
                  ", ".join(s.get("guards") or [])] for s in steps))
            lines.append("")
    (outdir / f"propagation{'.'+tag if tag!='core' else ''}.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8")


def write_cut_surface(correct, tag, outdir: Path):
    items = correct.get("cut_surface")
    lines = [f"# cut_surface.md — {tag} procedural-loop surfaces", ""]
    if not items:
        lines.append("_no cut_surface array in correct.json_")
    else:
        lines += tbl(
            ["module", "var", "lines", "worst_fo4", "loop_carried",
             "indexed_writes", "outside_writers", "block_locals", "verdict"],
            ([s.get("module"), s.get("var"),
              f"{s.get('start_line')}-{s.get('end_line')}",
              fmt(s.get("worst_fo4")),
              ", ".join(s.get("loop_carried") or []),
              ", ".join(s.get("indexed_writes") or []),
              ", ".join(s.get("outside_writers") or []),
              ", ".join(s.get("block_locals") or []),
              s.get("verdict")] for s in items))
    (outdir / f"cut_surface{'.'+tag if tag!='core' else ''}.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8")


def write_refusals(emit_dir: Path, tag, outdir: Path):
    trace = emit_dir / "algo-trace.jsonl"
    lines = [f"# refusals.md — {tag} refused corrections", ""]
    if not trace.exists():
        lines.append("_no algo-trace.jsonl_")
    else:
        by_mod_reason = defaultdict(list)
        details = defaultdict(list)
        for ln in trace.read_text(
                encoding="utf-8", errors="replace").splitlines():
            try:
                e = json.loads(ln)
            except json.JSONDecodeError:
                continue
            k = e.get("kind", "")
            if k == "refuse":
                by_mod_reason[(e.get("module", "?"),
                               e.get("reason", "?"))].append(e)
            elif k.startswith("pipe_contract.refuse"):
                key = (e.get("module", "?"), "pipe_contract.refuse")
                by_mod_reason[key].append(e)
                if e.get("detail"):
                    details[key].append(f"line {e.get('line')}: {e['detail']}")
        lines += tbl(
            ["module", "reason", "count", "examples"],
            ([m, r, len(v),
              "; ".join(sorted(set(details.get((m, r), []))))[:300]
              or "; ".join(sorted({
                  f"{x.get('edit_kind','?')}/{x.get('opp','?')}"
                  f"@{x.get('reloc','?')}" for x in v}))[:300]]
             for (m, r), v in sorted(
                 by_mod_reason.items(),
                 key=lambda kv: (-len(kv[1]), kv[0]))))
    (outdir / f"refusals{'.'+tag if tag!='core' else ''}.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8")


def write_cut_ledger(rows, top, tag):
    """In-tree ledger — module names and source paths renamed (identity-free)."""
    rtop = rename_ident(top)
    lines = [
        f"# cut-ledger.md — {tag} initial redesign ledger at "
        f"{fmt(BUDGET,0)} FO4",
        "",
        "Every instantiated module: REDESIGN-T1/T2/T3 or COPY. "
        f"Modules outside the elaborated set rooted at `{rtop}` are "
        "COPY-NOT-INSTANTIATED. Module names and paths are the hyp names. "
        "min_cuts_est = ceil(D/8) - 1 — the naive stage count a budget-fit "
        "cut would need; record the count actually used in the analysis.",
        "",
        "| module | decision | D | basis | min_cuts_est | source file |",
        "|---|---|---|---|---|---|",
    ]
    for r in rows:
        if not r["instantiated"]:
            decision = "COPY-NOT-INSTANTIATED"
        elif r["tier"] == "COPY":
            decision = "COPY"
        else:
            decision = f"REDESIGN-{r['tier']}"
        min_cuts = max(0, math.ceil(r["D"] / BUDGET) - 1)
        lines.append(
            f"| {rename_ident(r['name'])} | {decision} | {fmt(r['D'])} "
            f"| {r['basis']} | {min_cuts} | {rename_path(r['file'])} |")
    (ANALYSIS / f"cut-ledger{'.'+tag if tag!='core' else ''}.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8")


def run(emit_dir: Path, top: str, tag: str, outdir: Path,
        extra_roots=(), root_label=None):
    correct = json.loads((emit_dir / "correct.json").read_text("utf-8"))
    rows, reachable, pa = module_stats(correct, top, emit_dir, extra_roots)
    shown = root_label or top
    write_board(rows, pa, shown, tag, outdir)
    write_bottlenecks(correct, tag, outdir)
    write_carry_over(correct, tag, outdir)
    write_propagation(correct, tag, outdir)
    write_cut_surface(correct, tag, outdir)
    write_refusals(emit_dir, tag, outdir)
    write_cut_ledger(rows, shown, tag)
    return rows


def main(argv):
    emit_dir = Path(argv[1])
    top = None
    tag = "core"
    outdir = REPORTS
    args = argv[2:]
    i = 0
    extra_roots = []
    root_label = None
    while i < len(args):
        if args[i] == "--top":
            top = args[i + 1]; i += 2
        elif args[i] == "--tag":
            tag = args[i + 1]; i += 2
        elif args[i] == "--outdir":
            outdir = Path(args[i + 1]); i += 2
        elif args[i] == "--extra-roots":
            extra_roots = [s for s in args[i + 1].split(",") if s]; i += 2
        elif args[i] == "--root-label":
            root_label = args[i + 1]; i += 2
        else:
            i += 1
    outdir.mkdir(parents=True, exist_ok=True)
    ANALYSIS.mkdir(parents=True, exist_ok=True)
    if top is None:
        correct = json.loads(
            (emit_dir / "correct.json").read_text("utf-8"))
        top = detect_top(correct)
        if top is None:
            print("top is ambiguous — pass --top", file=sys.stderr)
            return 2
    rows = run(emit_dir, top, tag, outdir, extra_roots, root_label)
    counts = Counter(r["tier"] for r in rows if r["instantiated"])
    print(f"{tag}: top={root_label or top} "
          f"instantiated={sum(1 for r in rows if r['instantiated'])} "
          f"COPY={counts.get('COPY',0)} T3={counts.get('T3',0)} "
          f"T2={counts.get('T2',0)} T1={counts.get('T1',0)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))


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
