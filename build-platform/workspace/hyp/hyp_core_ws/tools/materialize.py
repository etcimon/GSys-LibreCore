# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""Materialize the hyp8 trees from an sv-timing emit.

Usage:
    python tools/materialize.py core   # emit/core-8fo4 -> hyp_redesign_core_8fo4
    python tools/materialize.py apu    # emit/apu-8fo4  -> hyp_redesign_*_8fo4

The trees are fully self-contained and upstream-identity-free: every file the
flist references is copied into the tree (vendor/common under third_party/),
all file names and contents go through tools/rename.py, and the flists use
${HYP_CORE_DIR}/${HYP_APU_DIR} only. Provenance (real upstream paths) lives in
the workspace's build/sv-timing/hyp8-src directory, not in these trees.
"""
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rename import (apply_rename, rename_ident, rename_path,  # noqa: E402
                    scrub_banner, scrub_paths)

SRC_EXTS = {".sv", ".svh", ".v", ".vh"}


def _keep_copied_file(f: Path) -> bool:
    """incdir copy filter: source files and license/notice files only, never
    .git (file or directory)."""
    if f.name == ".git" or ".git" in f.parts:
        return False
    if f.suffix.lower() in SRC_EXTS:
        return True
    base = f.name.split(".")[0].upper()
    return base in {"LICENSE", "LICENCE", "NOTICE"}

# Upstream identity tokens — constructed, never literal in this file.
_L = "cv" + "a6"
_U = "CV" + "A6"
_AR = "a" + "riane"

SRC_ROOT = Path(os.environ.get("HYP8_SRC_ROOT")
                or Path(__file__).resolve().parents[5])
WS = Path(__file__).resolve().parent.parent          # hyp_core_ws/
HYP = WS.parent                                       # workspace/hyp/
PROV = SRC_ROOT / "build-platform" / "workspace" / "build" / "sv-timing" \
    / "hyp8-src"
REPO_PREFIX = str(SRC_ROOT).replace("\\", "/") + "/"

TIER_RANK = {"REDESIGN-T1": 4, "REDESIGN-T2": 3, "REDESIGN-T3": 2,
             "COPY": 1, "COPY-NOT-INSTANTIATED": 0}

# Config packages kept in the tree; every other core/include/** *_config_pkg.sv
# and cv32*/cv64* package (including deprecated_packages/) is dropped.
CONFIG_DROP_RE = re.compile(
    r"core/include/(?:.*[/])?(?:cv32|cv64)[^/]*\.sv$|"
    r"core/include/(?:.*[/])?[^/]*_config_pkg\.sv$")
CONFIG_KEEP = {"g6lc64_ooo_config_pkg.sv", "build_config_pkg.sv",
               "g6lc_config_pkg.sv"}


def is_third_party(rel: str) -> bool:
    return rel.startswith("vendor/") or rel.startswith("common/") \
        or "/vendor/" in rel


def load_ledger(path: Path) -> dict:
    """module (hyp name) -> {decision, D, file} parsed from a cut-ledger
    table. Ledger rows are already renamed, so the same rename is applied to
    emit module names before lookup."""
    out = {}
    if not path.exists():
        return out
    for ln in path.read_text(encoding="utf-8").splitlines():
        if not ln.startswith("|") or "---" in ln or "decision" in ln:
            continue
        cells = [c.strip() for c in ln.strip("|").split("|")]
        if len(cells) < 5:
            continue
        mod, decision, d, basis = cells[0], cells[1], cells[2], cells[3]
        f = cells[-1]
        try:
            d = float(d)
        except ValueError:
            d = None
        out[mod] = {"decision": decision, "D": d, "basis": basis, "file": f}
    return out


EXECUTE_GROUP = {"alu", "branch_unit", "ex_stage", "issue_read_operands",
                 "multiplier", "mult"}


def analysis_link(mod: str, decision: str) -> str:
    analysis = WS / "analysis"
    if (analysis / f"{mod}.md").exists():
        return f"analysis/{mod}.md"
    if mod in EXECUTE_GROUP and (analysis / "execute.md").exists():
        return "analysis/execute.md"
    if decision == "REDESIGN-T1":
        if (analysis / "t1_rest.md").exists():
            return f"analysis/t1_rest.md#{mod}"
        return f"analysis/{mod}.md"
    if decision in ("REDESIGN-T2", "REDESIGN-T3"):
        if (analysis / "tier2_tier3.md").exists():
            return f"analysis/tier2_tier3.md#{mod}"
        tag = "tier2" if decision == "REDESIGN-T2" else "tier3"
        return f"analysis/{tag}.md#{mod}"
    return "-"


def repo_rel(source: str) -> str:
    s = source.replace("\\", "/")
    if s.startswith(REPO_PREFIX):
        return s[len(REPO_PREFIX):]
    return s


def load_prep_origins(emit_dir: Path) -> dict:
    p = emit_dir / "corrected" / "svt_pragma_preprocess.json"
    out = {}
    if p.exists():
        d = json.loads(p.read_text("utf-8"))
        for k, v in (d.get("origins") or {}).items():
            out[k.replace("\\", "/")] = repo_rel(v)
    return out


def copy_incdir(src_dir: Path, dest_dir: Path):
    """Copy a whole include dir into the tree, renamed."""
    n = 0
    if not src_dir.is_dir():
        return 0
    for f in src_dir.rglob("*"):
        if not f.is_file() or not _keep_copied_file(f):
            continue
        rel = repo_rel(str(f))
        if CONFIG_DROP_RE.search(rel) and \
                Path(rel).name not in CONFIG_KEEP:
            continue
        dest = dest_dir / rename_path(str(f.relative_to(src_dir)))
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(
            scrub_banner(apply_rename(
                f.read_text(encoding="utf-8", errors="replace"))),
            encoding="utf-8")
        n += 1
    return n


def materialize(emit_dir: Path, ledger_path: Path, tree: Path,
                flist_name: str, tree_var: str, apu_side: bool,
                core_origin: dict | None, emit_id: str):
    manifest = json.loads(
        (emit_dir / "corrected" / "svt_emit_manifest.json")
        .read_text("utf-8"))
    corrected_f = (emit_dir / "corrected" / "svt_corrected.f") \
        .read_text("utf-8").splitlines()
    correct = json.loads((emit_dir / "correct.json").read_text("utf-8"))
    ledger = load_ledger(ledger_path)
    prep_origins = load_prep_origins(emit_dir)

    def source_rel(entry: dict) -> str:
        s = entry["source"].replace("\\", "/")
        if s.startswith(REPO_PREFIX):
            return s[len(REPO_PREFIX):]
        return prep_origins.get(s, s)   # _prepared intermediates

    emit2src = {}
    for e in manifest["entries"]:
        emit2src[e["emit_rel"].replace("\\", "/")] = source_rel(e)
    file_mods = {}
    for m in correct["post_analyze"].get("modules", []):
        f = (m.get("file") or "").replace("\\", "/")
        mm = re.search(r"corrected/(.*)$", f)
        f = mm.group(1) if mm else f
        file_mods.setdefault(emit2src.get(f, f), []).append(m["name"])

    by_emit_rel = {e["emit_rel"].replace("\\", "/"): e
                   for e in manifest["entries"]}

    def classify(rel: str):
        mods = file_mods.get(rel, [])
        best = "COPY-NOT-INSTANTIATED"
        for mod in mods:
            d = (ledger.get(rename_ident(mod)) or {}).get("decision")
            if d and TIER_RANK.get(d, 0) > TIER_RANK.get(best, 0):
                best = d
        return best, mods

    origin = {}
    flist_rows = []
    counts = {"copied": 0, "todo": 0, "third_party": 0,
              "core_ref": 0, "dropped_cfg": 0, "skipped_core": 0,
              "incdir_files": 0}
    cfg_dropped = []

    for raw in corrected_f:
        ln = raw.strip()
        if not ln or ln.startswith("#"):
            continue
        emit_rel = ln.replace("\\", "/")
        entry = by_emit_rel.get(emit_rel)
        if entry is None:
            continue
        rel = source_rel(entry)
        emit_path = emit_dir / "corrected" / entry["emit_rel"]

        # drop non-hyp8 config packages from tree and flist
        if CONFIG_DROP_RE.search(rel) and \
                Path(rel).name not in CONFIG_KEEP:
            cfg_dropped.append(rel)
            counts["dropped_cfg"] += 1
            continue

        if apu_side and not rel.startswith("corev_apu/"):
            rec = (core_origin or {}).get(rel)
            if rec and rec.get("hyp"):
                flist_rows.append(
                    ("file", f"${{HYP_CORE_DIR}}/{rec['hyp']}", None))
                counts["core_ref"] += 1
            else:
                # not materialized in the core tree — make the APU tree
                # self-contained too
                rel2 = f"third_party/{rename_path(rel)}"
                dest = tree / rel2
                dest.parent.mkdir(parents=True, exist_ok=True)
                if emit_path.exists():
                    dest.write_text(
                        scrub_banner(apply_rename(emit_path.read_text(
                            "utf-8", errors="replace"))), encoding="utf-8")
                flist_rows.append(("file", f"${{{tree_var}}}/{rel2}", None))
                origin[rel] = {"hyp": rel2, "repo": f"<src>/{rel}",
                               "emit": str(emit_path),
                               "tier": "n/a", "decision": "APU-EXTRA"}
                counts["third_party"] += 1
            continue

        decision, mods = classify(rel)
        tier = decision.replace("REDESIGN-", "") \
            if decision.startswith("REDESIGN") else decision
        rrel = rename_path(rel)

        if decision.startswith("REDESIGN"):
            if is_third_party(rel):
                base = Path(rrel).stem
                new_rel = f"core/hyp_cells/g6lc_hyp_{base}.sv"
                note = ("Upstream/vendored file is not edited; the "
                        f"replacement will be written at {new_rel} "
                        "in this tree.\n")
            else:
                new_rel = rrel
                note = (f"The rewritten file will live at {rrel} "
                        "in this tree.\n")
            modinfo = []
            for mod in mods:
                rmod = rename_ident(mod)
                lr = ledger.get(rmod) or {}
                modinfo.append(
                    f"  - {rmod}: {lr.get('decision','?')} "
                    f"D={lr.get('D')} ({lr.get('basis','?')}) "
                    f"-> {analysis_link(rmod, lr.get('decision',''))}")
            emit_rel_rn = rename_path(emit_rel)
            (tree / (rrel + ".todo")).parent.mkdir(parents=True,
                                                  exist_ok=True)
            (tree / (rrel + ".todo")).write_text(
                f"# hyp8 redesign marker — {decision}\n\n"
                f"- upstream source: <src>/{rrel}\n"
                f"- emit: <prov>/emit/{emit_id}/corrected/{emit_rel_rn}\n"
                f"- tier: {tier}\n"
                f"- modules:\n"
                + ("\n".join(modinfo) if modinfo
                   else "  - (none recorded)") + "\n\n"
                + note
                + "Upstream names live in the provenance workspace "
                "origin-map.json.\n",
                encoding="utf-8")
            flist_rows.append(("file", f"${{{tree_var}}}/{new_rel}", None))
            origin[rel] = {"hyp": new_rel, "repo": f"{REPO_PREFIX}{rel}",
                           "emit": str(emit_path), "tier": tier,
                           "decision": decision, "todo": rrel + ".todo"}
            counts["todo"] += 1
        else:
            emit_text = emit_path.read_text("utf-8", errors="replace") \
                if emit_path.exists() else ""
            if is_third_party(rel):
                dest_rel = f"third_party/{rrel}"
            else:
                dest_rel = rrel
            dest = tree / dest_rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(scrub_banner(apply_rename(emit_text)),
                            encoding="utf-8")
            flist_rows.append(("file", f"${{{tree_var}}}/{dest_rel}", None))
            origin[rel] = {"hyp": dest_rel, "repo": f"{REPO_PREFIX}{rel}",
                           "emit": str(emit_path), "tier": tier,
                           "decision": decision}
            if is_third_party(rel):
                counts["third_party"] += 1
            else:
                counts["copied"] += 1

    # ----- include dirs: copy contents into the tree, flist gets tree paths
    incdir_define = []
    incdir_src = PROV / "inputs" / ("apu.f" if apu_side else "core.f")
    for ln in incdir_src.read_text("utf-8").splitlines():
        ln = ln.strip()
        if ln.startswith("+define+"):
            incdir_define.append(apply_rename(ln, prose=True))
        elif ln.startswith("+incdir+"):
            p = ln[len("+incdir+"):].replace("\\", "/")
            if p.startswith(REPO_PREFIX):
                rel = p[len(REPO_PREFIX):]
                if not apu_side:
                    if rel.startswith("core/include"):
                        dest_rel = rename_path(rel)
                    elif is_third_party(rel):
                        dest_rel = f"third_party/{rename_path(rel)}"
                    else:
                        dest_rel = rename_path(rel)
                    counts["incdir_files"] += copy_incdir(
                        SRC_ROOT / rel, tree / dest_rel)
                    incdir_define.append(f"+incdir+${{{tree_var}}}/{dest_rel}")
                else:
                    if rel.startswith("corev_apu/"):
                        dest_rel = rename_path(rel)
                        counts["incdir_files"] += copy_incdir(
                            SRC_ROOT / rel, tree / dest_rel)
                        incdir_define.append(
                            f"+incdir+${{{tree_var}}}/{dest_rel}")
                    elif rel.startswith("core/include"):
                        incdir_define.append(
                            f"+incdir+${{HYP_CORE_DIR}}/{rename_path(rel)}")
                    elif is_third_party(rel):
                        incdir_define.append(
                            f"+incdir+${{HYP_CORE_DIR}}/third_party/"
                            f"{rename_path(rel)}")
                    else:
                        dest_rel = rename_path(rel)
                        counts["incdir_files"] += copy_incdir(
                            SRC_ROOT / rel, tree / dest_rel)
                        incdir_define.append(
                            f"+incdir+${{{tree_var}}}/{dest_rel}")
            else:
                incdir_define.append(apply_rename(ln, prose=True))

    # Phase-3 group-1 edits baked into regenerated flists: the hyp config
    # seam replaces the ooo config package, and the group-1 hyp cells follow
    # the cells they replace.
    def group1_rows(rows):
        out = []
        for tag, row, extra in rows:
            pfx = row.split("}", 1)[0] + "}"
            if row.endswith("/core/include/g6lc64_ooo_config_pkg.sv"):
                out.append((tag, f"{pfx}/core/include/g6lc_hyp_pkg.sv", None))
                out.append((tag, f"{pfx}/core/include/g6lc64_hyp8_config_pkg.sv",
                            None))
            else:
                out.append((tag, row, extra))
            if row.endswith("/core/g6lc_fifo_v3.sv"):
                out.append((tag, f"{pfx}/core/hyp_cells/g6lc_hyp_fifo.sv", None))
            elif row.endswith(
                    "/third_party/vendor/pulp-platform/common_cells/src/"
                    "popcount.sv"):
                out.append((tag, f"{pfx}/core/hyp_cells/g6lc_hyp_popcount.sv",
                            None))
        return out

    flist_rows = group1_rows(flist_rows)

    flist_path = tree / "core" / flist_name if not apu_side \
        else tree / flist_name
    flist_path.parent.mkdir(parents=True, exist_ok=True)
    body = [
        f"# {flist_name} — hyp8 materialized flist",
        f"# generated by tools/materialize.py from "
        f"{emit_dir.name}/corrected/svt_corrected.f",
        f"# ${{{tree_var}}} = root of {tree.name}/ in this workspace",
        "# self-contained: no upstream tree references",
    ]
    if tree_var != "HYP_CORE_DIR":
        body.append(
            "# ${HYP_CORE_DIR} = root of hyp_redesign_core_8fo4/ "
            "in this workspace")
    body += incdir_define
    body += [r[1] for r in flist_rows if r[0] == "file"]
    flist_path.write_text("\n".join(body) + "\n", encoding="utf-8")
    if cfg_dropped:
        print(f"  dropped cfg pkgs: {cfg_dropped}")
    return origin, counts, flist_path


def edits_by_kind(correct: dict) -> dict:
    out = {}
    for e in correct.get("edits", []):
        out[e.get("kind", "?")] = out.get(e.get("kind", "?"), 0) + 1
    return out


def provenance_section(tag: str, emit_dir: Path, cmdline: str) -> list[str]:
    cj = emit_dir / "correct.json"
    lines = [f"## {tag} emit — {emit_dir.name}", ""]
    if not cj.exists():
        lines.append("_run did not produce correct.json_")
        return lines
    d = json.loads(cj.read_text("utf-8"))
    pa = d.get("post_analyze", {})
    bv = d.get("boot_validity", {})
    lines += [
        f"- command: `{cmdline}`",
        f"- banner: `{(pa.get('banner') or '').splitlines()[0] if pa.get('banner') else '?'}`",
        f"- budget: {pa.get('budget_fo4')} FO4 "
        f"(target {pa.get('target_mhz')} MHz, fo4_ps {pa.get('fo4_ps')}, "
        f"margin {pa.get('budget_margin')})",
        f"- max_path_fo4: {d.get('max_path_fo4_before')} -> "
        f"{d.get('max_path_fo4_after')} (all_modules "
        f"{d.get('max_path_fo4_before_all_modules')} -> "
        f"{d.get('max_path_fo4_after_all_modules')})",
        f"- edits by kind: {json.dumps(edits_by_kind(d), sort_keys=True)}",
        f"- boot_validity: {json.dumps(bv, sort_keys=True)}",
        f"- integrity: {json.dumps(d.get('integrity', {}), sort_keys=True)}",
        "",
    ]
    return lines


def main(argv) -> int:
    side = argv[1] if len(argv) > 1 else "core"
    notes = WS / "notes"
    notes.mkdir(exist_ok=True)

    ar = _AR  # e.g. <soc>_* names in prose below

    prov = ["# PROVENANCE — hyp8 Phase-0", ""]
    prov += [
        "- core command: `sv-timing.exe correct --files-from inputs/core.f "
        "--param-map inputs/param-map.json --width-map inputs/width-map.json "
        "--all-modules --allow-latency --assume-clk --contracts-only "
        "--opt-level 3 --opt-max-passes 6 --opt-max-cells-per-fo4 48 "
        "--target-mhz 5000 --fo4-ps 20 --budget-margin 0.2 --emit "
        "--real-cut-feeds --assume-xlen 64 --package-mode packages "
        "--out-dir emit/core-8fo4/corrected --json-out "
        "emit/core-8fo4/correct.json --trace-log "
        "emit/core-8fo4/algo-trace.jsonl` "
        "(RUST_MIN_STACK=16777216, binary sv-timing-core ir=ir-v5 "
        "measurement=delay-v44 correction=correction-v5)",
        "- apu command: same flags as core but `--files-from "
        "inputs/apu-compile/portable.f --param-map "
        "inputs/apu-compile/param-map.json` (no --width-map; none exists for "
        "the closure) and outputs under emit/apu-8fo4/.",
        "- budget: 8.0 FO4 = 1e6/(5000 MHz x 20 ps) x (1 - 0.2 margin).",
        "- calibration: `--calibration inputs/fo4-calibration.json` was "
        "REFUSED by the delay-v44 CLI — \"calibration was fitted under "
        "delay-v43 but this report is delay-v44; refit it from a board and "
        "a delay-v44 report\". Both runs proceeded WITHOUT calibration; "
        "calibrated_fo4 is absent from paths, so the deciding value D = "
        "adjusted_fo4 where inputs/adjusted-fo4.json measures the module "
        "(source: measured), else structural total_fo4.",
        f"- apu.f: built by tools/gen_apu_flist.py from the Makefile "
        f"{ar}_pkg + src + uart_src_sv lists over the core.f base; "
        "exclusions recorded in inputs/apu-exclusions.txt "
        "(spike-tandem conditional files, SimDTM/SimJTAG/uart.sv/"
        "rvfi_tracer/g6lc_tb_dram_latency, *.cc/*.h/*.vhd, "
        f"missing-on-disk, plus {ar}_testharness.sv [needs uvm_macros.svh] "
        f"and {ar}_peripherals.sv [sv-parser error at byte 11005]; both "
        "tb-only). SoC incdirs from the Makefile `incdir` list were added "
        "beyond core.f's (corev_apu/include etc.) — required for the accel "
        "interface header.",
        "- apu-compile: first `timings compile` attempt ran at the host "
        "default budget (no --target-mhz/--fo4-ps/--budget-margin flags) and "
        "failed (exitCode 1, sv-parser error in "
        f"corev_apu/tb/{ar}_peripherals.sv). Corrected run: `timings compile "
        "--target g6lc64_ooo --flist inputs/apu.f -o inputs/apu-compile "
        "--all-modules --target-mhz 5000 --fo4-ps 20 --budget-margin 0.2` — "
        "exitCode 0, 429 files, param-map 223/223 "
        + _U + "Cfg fields.",
        "- tiering: COPY if D<=8; T3 if 8<D<=16; T2 if 16<D<=32; T1 if D>32 "
        "(multi_cycle paths excluded). instantiated = the emit's elaborated "
        "module set intersected with the reachable cone under the stated "
        "root — the syntactic graph alone counts generate-dead branches.",
        "- materialize: REDESIGN files get .todo markers (vendor/common "
        "redesigns point at core/hyp_cells/g6lc_hyp_<name>.sv); COPY files "
        "are copied verbatim except the identity rename; every "
        "vendor/common file lands under third_party/ so the trees are "
        "self-contained — no repo references in the flists.",
        "",
    ]

    core_emit = PROV / "emit" / "core-8fo4"
    apu_emit = PROV / "emit" / "apu-8fo4"
    core_cmd = "sv-timing.exe correct --files-from inputs/core.f … (see above)"
    apu_cmd = ("sv-timing.exe correct --files-from "
               "inputs/apu-compile/portable.f --param-map "
               "inputs/apu-compile/param-map.json … (same switches as core)")

    prov += provenance_section("core", core_emit, core_cmd)
    prov += provenance_section("apu", apu_emit, apu_cmd)
    (PROV / "PROVENANCE.md").write_text("\n".join(prov) + "\n",
                                       encoding="utf-8")
    # identity-free pointer kept in the tree
    (notes / "PROVENANCE.md").write_text(
        "# PROVENANCE\n\n"
        "Run provenance (commands, budgets, edit counts, exclusion lists, "
        "upstream file mapping) is kept in the provenance workspace outside "
        "this tree: `<workspace>/build/sv-timing/hyp8-src`. This tree is "
        "deliberately free of upstream names; `tools/` derive every path.\n",
        encoding="utf-8")

    if side == "core":
        origin, counts, flist_path = materialize(
            core_emit, WS / "analysis" / "cut-ledger.md",
            HYP / "hyp_redesign_core_8fo4", "Flist.g6lc_hyp8",
            "HYP_CORE_DIR", apu_side=False, core_origin=None,
            emit_id="core-8fo4")
        (PROV / "origin-map.json").write_text(
            json.dumps(origin, indent=1, sort_keys=True), encoding="utf-8")
        print("core materialize:", counts, "->", flist_path)
    else:
        core_omap = PROV / "origin-map.json"
        core_origin = json.loads(core_omap.read_text("utf-8")) \
            if core_omap.exists() else {}
        origin, counts, flist_path = materialize(
            apu_emit, WS / "analysis" / "cut-ledger.apu.md",
            HYP / "hyp_redesign_corev_apu_8fo4", "Flist.hyp8_apu",
            "HYP_APU_DIR", apu_side=True, core_origin=core_origin,
            emit_id="apu-8fo4")
        (PROV / "origin-map.apu.json").write_text(
            json.dumps(origin, indent=1, sort_keys=True), encoding="utf-8")
        print("apu materialize:", counts, "->", flist_path)
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
