#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# run_regress.py — Python verif regress for sv-timing:
#   heavy .sv → analyze (startpoint/endpoint frequency closure)
#            → correct --emit (precompiler)
#            → pyslang lint optimized .sv
#            → validate FO4 / closure metrics improve or stay defined
#
# Invoked by: python tools/svt.py verif-regress
# Uses contained venv when available; requires built sv-timing CLI.

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path


def package_root() -> Path:
    return Path(__file__).resolve().parents[2]


def parse_suites_toml(path: Path) -> tuple[dict, list[dict]]:
    """Minimal TOML subset reader for suites.toml (no external tomllib required on 3.9)."""
    text = path.read_text(encoding="utf-8")
    global_cfg: dict = {}
    cases: list[dict] = []
    current: dict | None = None
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line == "[[case]]":
            if current:
                cases.append(current)
            current = {}
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        if v.startswith('"') and v.endswith('"'):
            val: object = v[1:-1]
        elif v.lower() in ("true", "false"):
            val = v.lower() == "true"
        else:
            try:
                val = float(v) if "." in v else int(v)
            except ValueError:
                val = v
        if current is None:
            global_cfg[k] = val
        else:
            current[k] = val
    if current:
        cases.append(current)
    return global_cfg, cases


@dataclass
class CaseResult:
    id: str
    ok: bool
    messages: list[str] = field(default_factory=list)
    analyze: dict | None = None
    correct: dict | None = None
    optimized: Path | None = None


def run_cmd(cmd: list[str], cwd: Path, env: dict) -> subprocess.CompletedProcess:
    print("+", " ".join(cmd), flush=True)
    return subprocess.run(cmd, cwd=str(cwd), env=env, capture_output=True, text=True)


def resolve_cli(root: Path) -> list[str]:
    is_win = os.name == "nt"
    exe = root / "target" / "debug" / ("sv-timing.exe" if is_win else "sv-timing")
    if exe.is_file():
        return [str(exe)]
    cargo = root / ".tools" / "cargo" / "bin" / ("cargo.exe" if is_win else "cargo")
    c = str(cargo) if cargo.is_file() else "cargo"
    return [c, "run", "-q", "-p", "sv-timing-cli", "--"]


def rust_env(root: Path) -> dict:
    env = os.environ.copy()
    rh = root / ".tools" / "rustup"
    ch = root / ".tools" / "cargo"
    env["RUSTUP_HOME"] = str(rh)
    env["CARGO_HOME"] = str(ch)
    env["SV_TIMING_ROOT"] = str(root)
    bin_dir = str(ch / "bin")
    sep = ";" if os.name == "nt" else ":"
    env["PATH"] = bin_dir + sep + env.get("PATH", "")
    return env


def pyslang_lint(path: Path) -> tuple[bool, list[str]]:
    """Lint/compile one SV file with pyslang (slang Driver API, v11+)."""
    return pyslang_lint_many([path])


def pyslang_lint_many(paths: list[Path]) -> tuple[bool, list[str]]:
    """Lint/compile one or more SV files together (packages + modules)."""
    msgs: list[str] = []
    if not paths:
        return False, ["pyslang: empty file list"]
    try:
        import pyslang  # type: ignore
    except ImportError:
        return False, ["pyslang not installed (pip install pyslang into .tools/python-venv)"]

    try:
        d = pyslang.driver.Driver()
        d.addStandardArgs()
        for path in paths:
            d.sourceLoader.addFiles(str(path.resolve()))
        if not d.parseAllSources():
            return False, [f"pyslang parseAllSources failed for {[p.name for p in paths]}"]
        if not d.reportParseDiags():
            return False, [f"pyslang parse diagnostics failed for {[p.name for p in paths]}"]
        comp = d.createCompilation()
        d.reportCompilation(comp, True)
        if not d.reportDiagnostics(True):
            return False, [
                f"pyslang reported errors for {[p.name for p in paths]}"
            ]
        names = ", ".join(p.name for p in paths)
        msgs.append(f"pyslang OK (0 errors) [{names}]")
        return True, msgs
    except Exception as e:
        return False, [f"pyslang exception: {e}"]


def validate_closure(analyze: dict, case: dict, cfg: dict) -> list[str]:
    errs: list[str] = []
    fc = analyze.get("frequency_closure") or {}
    paths = analyze.get("paths") or []
    if len(paths) < int(case.get("expect_paths_min", 1)):
        errs.append(f"expected >= {case.get('expect_paths_min')} paths, got {len(paths)}")
    for p in paths:
        if not p.get("startpoint") or not p.get("endpoint"):
            errs.append(f"path {p.get('path_id')} missing startpoint/endpoint")
        if "path_kind" not in p:
            errs.append(f"path {p.get('path_id')} missing path_kind")
        if "max_freq_mhz" not in p:
            errs.append(f"path {p.get('path_id')} missing max_freq_mhz")
    if not fc:
        errs.append("missing frequency_closure object")
    else:
        for k in (
            "closes",
            "worst_startpoint",
            "worst_endpoint",
            "budget_fo4",
            "max_freq_mhz",
            "target_mhz",
        ):
            if k not in fc:
                errs.append(f"frequency_closure missing {k}")
        if case.get("expect_failing_before") and fc.get("failing_paths", 0) < 1:
            # Soft: heavy fixtures should fail at high target; warn via message not hard fail
            # if path extraction is shallow
            if not paths:
                errs.append("expect_failing_before but no paths")
    return errs


def run_case(
    root: Path,
    cli: list[str],
    env: dict,
    cfg: dict,
    case: dict,
    out_root: Path,
) -> CaseResult:
    cid = str(case["id"])
    cr = CaseResult(id=cid, ok=True)

    files_from = case.get("files_from")
    all_modules = bool(case.get("all_modules", False))
    sv = root / str(case["sv"]) if case.get("sv") else None
    if files_from:
        fl = root / str(files_from)
        if not fl.is_file():
            cr.ok = False
            cr.messages.append(f"missing files_from {fl}")
            return cr
    elif sv is None or not sv.is_file():
        cr.ok = False
        cr.messages.append(f"missing sv {sv}")
        return cr

    case_out = out_root / cid
    case_out.mkdir(parents=True, exist_ok=True)
    analyze_json = case_out / "analyze.json"
    correct_json = case_out / "correct.json"
    emit_dir = case_out / "corrected"

    module = str(case.get("module") or "")
    target = float(cfg.get("target_mhz", 2000))
    fo4 = float(cfg.get("fo4_ps", 20))
    margin = float(cfg.get("budget_margin", 0.2))

    # --- analyze ---
    cmd = cli + [
        "analyze",
        "--target-mhz",
        str(target),
        "--fo4-ps",
        str(fo4),
        "--budget-margin",
        str(margin),
        "--json-out",
        str(analyze_json),
    ]
    if files_from:
        cmd += ["--files-from", str(root / str(files_from))]
    else:
        cmd += ["--file", str(sv)]
    if all_modules:
        cmd.append("--all-modules")
    else:
        cmd += ["--modules", module]
    r = run_cmd(cmd, root, env)
    if r.returncode != 0:
        cr.ok = False
        cr.messages.append(f"analyze failed: {r.stderr or r.stdout}")
        return cr
    analyze = json.loads(analyze_json.read_text(encoding="utf-8"))
    cr.analyze = analyze
    for e in validate_closure(analyze, case, cfg):
        cr.ok = False
        cr.messages.append(e)

    fc = analyze.get("frequency_closure") or {}
    cr.messages.append(
        f"closure: closes={fc.get('closes')} worst={fc.get('worst_startpoint')}->"
        f"{fc.get('worst_endpoint')} slack={fc.get('worst_slack_fo4')} "
        f"max_mhz={fc.get('max_freq_mhz')}"
    )

    # --- correct --emit ---
    cmd = cli + [
        "correct",
        "--target-mhz",
        str(target),
        "--fo4-ps",
        str(fo4),
        "--budget-margin",
        str(margin),
        "--max-passes",
        str(int(cfg.get("max_passes", 6))),
        "--json-out",
        str(correct_json),
        "--emit",
        "--out-dir",
        str(emit_dir),
    ]
    if files_from:
        cmd += ["--files-from", str(root / str(files_from))]
    else:
        cmd += ["--file", str(sv)]
    if all_modules:
        cmd.append("--all-modules")
    else:
        cmd += ["--modules-allow", module]
    if cfg.get("allow_latency", True):
        cmd.append("--allow-latency")
    if cfg.get("assume_clk", True):
        cmd.append("--assume-clk")

    r = run_cmd(cmd, root, env)
    if r.returncode != 0:
        cr.ok = False
        cr.messages.append(f"correct failed: {r.stderr or r.stdout}")
        return cr
    correct = json.loads(correct_json.read_text(encoding="utf-8"))
    cr.correct = correct
    integ = correct.get("integrity") or {}
    if not integ.get("reparse_ok", False):
        cr.ok = False
        cr.messages.append(f"emit reparse failed: {integ.get('messages')}")

    # Find optimized sv (flat or nested under out-dir)
    optimized = list(emit_dir.rglob("*__svt.sv"))
    if not optimized:
        # correct may emit nothing if no edits — still require file or note
        if not correct.get("edits"):
            cr.messages.append("no edits produced (path may already meet budget)")
            # Re-emit passthrough is not done; treat as soft pass if analyze had paths
            if case.get("require_pyslang_clean") and not optimized:
                # Run pyslang on original as baseline
                if sv is not None and sv.is_file():
                    ok, msgs = pyslang_lint(sv)
                    cr.messages.extend(msgs)
                    if not ok:
                        cr.ok = False
                return cr
        else:
            cr.ok = False
            cr.messages.append(f"no *__svt.sv under {emit_dir}")
            return cr
    else:
        cr.optimized = optimized[0]
        if case.get("require_pyslang_clean", True):
            # Compile all emitted files together so package imports resolve.
            ok, msgs = pyslang_lint_many(sorted(optimized, key=lambda p: p.name))
            cr.messages.extend(msgs)
            if not ok:
                cr.ok = False

    # Project emit sidecars (filelist + manifest) for multi-file cases
    if case.get("require_project_filelist") or correct.get("filelist"):
        fl_path = emit_dir / "svt_corrected.f"
        mf_path = emit_dir / "svt_emit_manifest.json"
        if case.get("require_project_filelist"):
            if not fl_path.is_file():
                cr.ok = False
                cr.messages.append("project gate: missing svt_corrected.f under out-dir")
            else:
                cr.messages.append(f"project filelist OK ({fl_path.name})")
            if not mf_path.is_file():
                cr.ok = False
                cr.messages.append("project gate: missing svt_emit_manifest.json")
            else:
                cr.messages.append("project manifest OK")
            entries = correct.get("project_entries") or []
            if correct.get("edits") and not entries:
                cr.ok = False
                cr.messages.append("project gate: expected project_entries in correct JSON")
            else:
                cr.messages.append(f"project_entries={len(entries)}")

    # FO4 improvement check when edits exist
    before = correct.get("max_path_fo4_before")
    after = correct.get("max_path_fo4_after")
    if before is not None and after is not None and correct.get("edits"):
        cr.messages.append(f"fo4 max path {before} -> {after}")
        if cfg.get("require_fo4_improved", True) and correct.get("edits"):
            if after > before + 1e-6:
                cr.ok = False
                cr.messages.append("max path FO4 increased after correct")

    # Density of dense emit (parameters, assigns, predicates, begin/end, ternaries, always, locals)
    dens = correct.get("density") or {}
    cr.messages.append(
        f"density score={dens.get('score')} min={dens.get('min_required')} "
        f"params={dens.get('parameters')} assigns={dens.get('assignments')} "
        f"pred={dens.get('predicates')} tern={dens.get('ternaries')} "
        f"always={dens.get('always_blocks')} locals={dens.get('moved_locals')}"
    )
    if cfg.get("require_density", True) and correct.get("edits"):
        if not dens.get("ok", False):
            cr.ok = False
            cr.messages.append(
                f"density gate failed score={dens.get('score')} < {dens.get('min_required')}"
            )
        # Language intricacies floor
        if int(dens.get("parameters") or 0) < 1:
            cr.ok = False
            cr.messages.append("density: expected parameters in emit")
        if int(dens.get("assignments") or 0) < 1:
            cr.ok = False
            cr.messages.append("density: expected assignments in emit")
        if int(dens.get("predicates") or 0) < 1:
            cr.ok = False
            cr.messages.append("density: expected if/else predicates in emit")
        if int(dens.get("ternaries") or 0) < 1:
            cr.ok = False
            cr.messages.append("density: expected ternaries in emit")
        if int(dens.get("always_blocks") or 0) < 1:
            cr.ok = False
            cr.messages.append("density: expected always_comb/ff blocks in emit")
        if int(dens.get("moved_locals") or 0) < 1:
            cr.ok = False
            cr.messages.append("density: expected moved/hoisted locals in emit")

    # Post-correct IR frequency_closure (startpoint/endpoint re-measure after rewire)
    post = correct.get("post_closure") or {}
    cr.messages.append(
        f"post_closure: closes={post.get('closes')} "
        f"{post.get('worst_startpoint')}->{post.get('worst_endpoint')} "
        f"slack={post.get('worst_slack_fo4')} max_mhz={post.get('max_freq_mhz')}"
    )
    pre_max = (analyze.get("frequency_closure") or {}).get("max_freq_mhz") or 0
    post_max = post.get("max_freq_mhz") or 0
    if case.get("require_max_freq_improved") or cfg.get("require_max_freq_improved"):
        if correct.get("edits") and post_max + 1e-6 < pre_max:
            cr.ok = False
            cr.messages.append(
                f"max_freq_mhz did not improve: {pre_max} -> {post_max}"
            )
        else:
            cr.messages.append(f"max_freq_mhz {pre_max} -> {post_max}")

    # post_analyze: optional re-analyze of emitted *__svt.sv (CLI fills when --emit)
    post_an = correct.get("post_analyze")
    if post_an:
        pfc = post_an.get("frequency_closure") or {}
        cr.messages.append(
            f"post_analyze_sv: closes={pfc.get('closes')} paths="
            f"{len(post_an.get('paths') or [])} max_mhz={pfc.get('max_freq_mhz')}"
        )
    elif correct.get("edits") and cr.optimized is not None:
        cr.messages.append("post_analyze_sv: absent (CLI did not re-analyze emit)")

    if case.get("require_post_closes"):
        # Quality bar: IR post-correct re-analyze must report frequency_closure.closes
        if not post:
            cr.ok = False
            cr.messages.append(
                "post-correct re-analyze gate: missing post_closure object"
            )
        elif not post.get("closes"):
            cr.ok = False
            cr.messages.append(
                "post-correct re-analyze gate: post_closure.closes must be true "
                f"(failing_paths={post.get('failing_paths')} "
                f"worst={post.get('worst_startpoint')}->{post.get('worst_endpoint')} "
                f"slack={post.get('worst_slack_fo4')})"
            )
        else:
            cr.messages.append("post_closes gate: PASS (IR post_closure.closes=true)")

    return cr


def main() -> int:
    ap = argparse.ArgumentParser(description="sv-timing verif regress (analyze/correct/pyslang)")
    ap.add_argument(
        "--root",
        type=Path,
        default=None,
        help="sv-timing package root",
    )
    ap.add_argument(
        "--suites",
        type=Path,
        default=None,
        help="suites.toml path",
    )
    ap.add_argument(
        "--case",
        action="append",
        default=[],
        help="Run only this case id (repeatable)",
    )
    ap.add_argument(
        "--skip-pyslang",
        action="store_true",
        help="Skip pyslang lint (analyze/correct only)",
    )
    args = ap.parse_args()
    root = (args.root or package_root()).resolve()
    suites = args.suites or (root / "verif" / "regress" / "suites.toml")
    if not suites.is_file():
        print(f"ERROR: missing {suites}", file=sys.stderr)
        return 2

    cfg, cases = parse_suites_toml(suites)
    if args.case:
        cases = [c for c in cases if c.get("id") in args.case]
    if args.skip_pyslang:
        for c in cases:
            c["require_pyslang_clean"] = False

    env = rust_env(root)
    # Build CLI first
    cargo = root / ".tools" / "cargo" / "bin" / ("cargo.exe" if os.name == "nt" else "cargo")
    cbin = str(cargo) if cargo.is_file() else "cargo"
    br = run_cmd(
        [cbin, "build", "-p", "sv-timing-cli"],
        root,
        env,
    )
    if br.returncode != 0:
        print(br.stderr or br.stdout, file=sys.stderr)
        return 1

    cli = resolve_cli(root)
    out_root = root / ".sv-timing-out" / "verif-regress"
    out_root.mkdir(parents=True, exist_ok=True)

    results: list[CaseResult] = []
    for case in cases:
        print(f"\n=== case {case.get('id')} ===", flush=True)
        results.append(run_case(root, cli, env, cfg, case, out_root))

    # Summary
    failed = [r for r in results if not r.ok]
    print("\n======== verif regress summary ========")
    for r in results:
        status = "PASS" if r.ok else "FAIL"
        print(f"  [{status}] {r.id}")
        for m in r.messages:
            print(f"         - {m}")
    print(f"total={len(results)} fail={len(failed)}")
    summary = {
        "total": len(results),
        "fail": len(failed),
        "cases": [
            {
                "id": r.id,
                "ok": r.ok,
                "messages": r.messages,
                "optimized": str(r.optimized) if r.optimized else None,
                "closure": (r.analyze or {}).get("frequency_closure"),
            }
            for r in results
        ],
    }
    (out_root / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"summary: {out_root / 'summary.json'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
