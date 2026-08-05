#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# monorepo_soak.py — Opt-in structural FO4 soak against real host RTL trees.
#
# Discovers a monorepo root only at runtime (env or parent layout). Never imports
# monorepo modules into crates. Prefer fixing *this package* when analyze fails;
# RTL edits are the rare path. See architecture/MONOREPO-SOAK.md.

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from flist_expand import expand_filelist, write_portable_f  # noqa: E402


def log(msg: str) -> None:
    print(f"[monorepo-soak] {msg}")


def err(msg: str) -> None:
    print(f"[monorepo-soak] ERROR: {msg}", file=sys.stderr)


def package_root() -> Path:
    return _TOOLS.parent


def find_monorepo_root(pkg: Path) -> Path | None:
    """Locate host tree with a `core/` RTL directory (optional)."""
    for key in ("SVT_MONOREPO_ROOT", "CVA6_REPO_DIR"):
        v = os.environ.get(key, "").strip()
        if v:
            p = Path(v).expanduser().resolve()
            if (p / "core").is_dir():
                return p
    cur = pkg.resolve()
    for _ in range(5):
        parent = cur if cur.name != "sv-timing" else cur.parent
        if (parent / "core").is_dir() and (parent / "sv-timing").is_dir():
            return parent
        if cur.parent == cur:
            break
        cur = cur.parent
    return None


@dataclass
class SoakProfile:
    id: str
    flist: str
    modules: list[str] = field(default_factory=list)
    all_modules: bool = False
    param_map: str | None = None
    target_mhz: float = 1250.0
    fo4_ps: float = 20.0
    assume_clk: bool = True
    soft_missing: bool = True
    notes: str = ""


# Built-in profiles (paths relative to monorepo root). No monorepo type ids here.
DEFAULT_PROFILE_SPECS: list[dict] = [
    {
        "id": "sparse_ex",
        "flist": "verif/sv-timing-tests/flists/sparse_ex_units.f",
        "modules": ["alu", "mult", "multiplier", "serdiv", "branch_unit"],
        "param_map": "verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json",
        "notes": "EX datapath slice (packages + alu/mult/div/branch)",
    },
    {
        "id": "sparse_frontend",
        "flist": "verif/sv-timing-tests/flists/sparse_frontend.f",
        "modules": ["instr_scan", "instr_queue", "g6lc_ftq"],
        "param_map": "verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json",
        "notes": "Frontend FTQ / instr queue slice",
    },
    {
        "id": "sparse_uncore_glue",
        "flist": "verif/sv-timing-tests/flists/sparse_apu_glue.f",
        "modules": ["g6lc_axi_2to1_mux"],
        "param_map": None,
        "soft_missing": True,
        "notes": "Thin corev_apu AXI mux (best-measure uncore; soft-skip if missing)",
    },
    {
        "id": "sparse_g6lc",
        "flist": "verif/sv-timing-tests/flists/sparse_g6lc.f",
        "modules": [
            "g6lc_ftq",
            "g6lc_fdip",
            "g6lc_bp_gshare",
            "g6lc_bp_top",
            "g6lc_freelist",
            "g6lc_rob",
            "g6lc_rename",
            "g6lc_slice_steer",
            "g6lc_hart_state",
            "g6lc_thread_select",
            "g6lc_smt_pc_bank",
            "g6lc_way_predictor",
            "g6lc_rrip_repl",
            "g6lc_axi_2to1_mux",
        ],
        "param_map": "verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json",
        "soft_missing": True,
        "notes": "GSys LibreCore g6lc_* rename set (frontend/OoO/SMT/cache/uncore) for auto-correct",
    },
    {
        "id": "sparse_issue_lsu",
        "flist": "verif/sv-timing-tests/flists/sparse_issue_lsu.f",
        "modules": [
            "issue_read_operands",
            "scoreboard",
            "load_unit",
            "store_unit",
            "store_buffer",
        ],
        "param_map": "verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json",
        "notes": "Issue/scoreboard + LSU units — best-measure FO4 on mid/back-end core",
    },
    {
        "id": "full_core",
        "flist": "verif/sv-timing-tests/flists/full_core.f",
        "modules": [],
        "all_modules": True,
        "param_map": "verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json",
        "soft_missing": True,
        "notes": "Entire core/Flist.cva6 — all modules structural FO4",
    },
    {
        "id": "full_corev_apu",
        "flist": "verif/sv-timing-tests/flists/full_corev_apu.f",
        "modules": [],
        "all_modules": True,
        "param_map": "verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json",
        "soft_missing": True,
        "notes": "Entire corev_apu RTL (excl. tb/test/deprecated) + core packages",
    },
]


def _load_toml(path: Path) -> dict:
    try:
        import tomllib  # py311+
    except ImportError:  # pragma: no cover
        try:
            import tomli as tomllib  # type: ignore
        except ImportError as e:
            raise RuntimeError(f"need Python 3.11+ or tomli to load {path}") from e
    return tomllib.loads(path.read_text(encoding="utf-8"))


def load_profile_toml(path: Path) -> SoakProfile:
    data = _load_toml(path)
    return SoakProfile(
        id=str(data.get("id") or path.stem),
        flist=str(data["flist"]),
        modules=[str(m) for m in data.get("modules", [])],
        all_modules=bool(data.get("all_modules", False)),
        param_map=str(data["param_map"]) if data.get("param_map") else None,
        target_mhz=float(data.get("target_mhz", 1250.0)),
        fo4_ps=float(data.get("fo4_ps", 20.0)),
        assume_clk=bool(data.get("assume_clk", True)),
        soft_missing=bool(data.get("soft_missing", True)),
        notes=str(data.get("notes", "")),
    )


def profiles_from_defaults(repo: Path) -> list[SoakProfile]:
    out: list[SoakProfile] = []
    for spec in DEFAULT_PROFILE_SPECS:
        if not (repo / spec["flist"]).is_file():
            continue
        out.append(
            SoakProfile(
                id=spec["id"],
                flist=spec["flist"],
                modules=list(spec.get("modules") or []),
                all_modules=bool(spec.get("all_modules", False)),
                param_map=spec.get("param_map"),
                soft_missing=bool(spec.get("soft_missing", True)),
                notes=str(spec.get("notes", "")),
            )
        )
    return out


def load_profiles(
    repo: Path,
    *,
    profile_ids: list[str] | None,
    profile_files: list[Path],
) -> list[SoakProfile]:
    profiles: list[SoakProfile] = []
    for pf in profile_files:
        profiles.append(load_profile_toml(pf))
    catalog = repo / "verif" / "sv-timing-tests" / "soak-profiles"
    if catalog.is_dir() and not profile_files:
        for p in sorted(catalog.glob("*.toml")):
            profiles.append(load_profile_toml(p))
    if not profiles:
        profiles = profiles_from_defaults(repo)
    if profile_ids:
        want = set(profile_ids)
        profiles = [p for p in profiles if p.id in want]
    return profiles


def host_portable_path(p: Path | str) -> str:
    """Normalize paths so WSL-produced packages validate on Windows hosts.

    `/mnt/c/Users/...` → `C:/Users/...` for build-platform on Windows.
    """
    s = str(p)
    try:
        s = str(Path(p).resolve())
    except OSError:
        pass
    s = s.replace("\\", "/")
    # WSL drive mounts
    if s.startswith("/mnt/") and len(s) > 6 and s[5].isalpha() and s[6:7] == "/":
        drive = s[5].upper()
        rest = s[7:]
        return f"{drive}:/{rest}"
    return s


def write_filtered_portable(
    expanded_files: list[Path],
    expanded_incdirs: list[Path],
    out_path: Path,
    *,
    soft: bool,
) -> tuple[Path, list[str], list[Path]]:
    """Write portable.f (native paths for this OS CLI) + portable.host.f (Windows form).

    Returns (portable_path, dropped, kept_files).
    """
    kept_files: list[Path] = []
    dropped: list[str] = []
    for p in expanded_files:
        if p.is_file():
            kept_files.append(p)
        else:
            dropped.append(host_portable_path(p))
            if not soft:
                raise FileNotFoundError(str(p))
    out_path.parent.mkdir(parents=True, exist_ok=True)

    def write_variant(path: Path, mapper) -> None:
        lines: list[str] = [
            "# monorepo-soak portable.f (structural FO4 — not STA)",
            "# Prefer fixing sv-timing package when this analyze fails.",
        ]
        for d in expanded_incdirs:
            if d.is_dir():
                lines.append(f"+incdir+{mapper(d)}")
        for f in kept_files:
            lines.append(mapper(f))
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    # Native paths for the OS running cargo (WSL needs /mnt/c/..., not C:/)
    write_variant(out_path, lambda p: str(p.resolve()).replace("\\", "/"))
    # Host-normalized for Windows build-platform validate / Yosys
    host_path = out_path.with_name("portable.host.f")
    write_variant(host_path, host_portable_path)
    return out_path, dropped, kept_files


def cargo_bin(pkg: Path) -> Path | None:
    # Prefer package-contained / CARGO_HOME cargo so monorepo-soak rebuilds *this*
    # workspace (avoid a stale system cargo pointing at another target tree).
    name = "cargo.exe" if sys.platform.startswith("win") else "cargo"
    candidates: list[Path] = []
    cargo_home = os.environ.get("CARGO_HOME")
    if cargo_home:
        candidates.append(Path(cargo_home) / "bin" / name)
    candidates.append(pkg / ".tools" / "cargo" / "bin" / name)
    # Contained rustup may place cargo under toolchain bin as well.
    tools = pkg / ".tools"
    if tools.is_dir():
        for p in tools.rglob(name):
            if p.is_file() and "bin" in p.parts:
                candidates.append(p)
                break
    for cand in candidates:
        if cand.is_file():
            return cand
    which = shutil.which("cargo")
    if which:
        return Path(which)
    return None


def sv_timing_cli_bin(pkg: Path) -> Path | None:
    """Prefer a already-built CLI binary under package target/ (skip cargo run).

    Prefer **release** over debug so monorepo soaks after `cargo build --release`
    actually exercise the optimized binary (debug first used to hide release work).
    """
    names = ("sv-timing.exe", "sv-timing") if sys.platform.startswith("win") else ("sv-timing",)
    for profile in ("release", "debug"):
        for name in names:
            p = pkg / "target" / profile / name
            if p.is_file():
                return p
    return None


def metrics_from_report(json_path: Path) -> dict:
    """Pull FO4 / closure fields from analyze.json or correct.json."""
    out: dict = {"json_out": str(json_path)}
    if not json_path.is_file():
        return out
    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        out["json_error"] = str(e)
        return out
    # correct.json (CorrectResult) shape
    if "max_path_fo4_before" in data or "max_path_fo4_after" in data:
        before = data.get("max_path_fo4_before")
        after = data.get("max_path_fo4_after")
        # All-paths max includes soft multi_cycle atomic mul — not the primary story.
        out["worst_fo4_before"] = before
        out["worst_fo4"] = after if after is not None else before
        if isinstance(before, (int, float)) and isinstance(after, (int, float)):
            out["fo4_delta_all_paths"] = float(after) - float(before)
        pc = data.get("post_closure") or {}
        out["closes"] = pc.get("closes")
        out["max_freq_mhz"] = pc.get("max_freq_mhz")
        # Primary FO4 after correct = post_closure worst (excludes multi_cycle ranking).
        if isinstance(pc.get("worst_path_fo4"), (int, float)):
            out["worst_primary_fo4"] = float(pc["worst_path_fo4"])
            out["worst_fo4_best_measure"] = out["worst_primary_fo4"]
        # Primary before: max fo4_before among edits (the path(s) we actually touched).
        edits = data.get("edits") or []
        edit_befores: list[float] = []
        for e in edits:
            if isinstance(e, dict) and isinstance(e.get("fo4_before"), (int, float)):
                edit_befores.append(float(e["fo4_before"]))
        if edit_befores:
            out["worst_primary_fo4_before"] = max(edit_befores)
        # Prefer primary Δ for dashboard; fall back to all-paths.
        prim_b = out.get("worst_primary_fo4_before")
        prim_a = out.get("worst_primary_fo4")
        if isinstance(prim_b, (int, float)) and isinstance(prim_a, (int, float)):
            out["fo4_delta"] = float(prim_a) - float(prim_b)
            out["fo4_improved"] = out["fo4_delta"] < -0.01
            out["fo4_delta_kind"] = "primary"
        elif isinstance(before, (int, float)) and isinstance(after, (int, float)):
            out["fo4_delta"] = float(after) - float(before)
            out["fo4_improved"] = out["fo4_delta"] < -0.01
            out["fo4_delta_kind"] = "all_paths"
        out["edits"] = len(edits) if isinstance(edits, list) else 0
        out["dry_run"] = data.get("dry_run")
        dens = data.get("density") or {}
        out["density_score"] = dens.get("score")
        # Relocation residual after correct + how many edits cite a relocation option
        rp = data.get("relocation_plan") or {}
        if isinstance(rp, dict) and rp.get("summary"):
            sm = rp["summary"]
            out["reloc_failing_primary"] = sm.get("failing_primary")
            out["reloc_cards"] = sm.get("cards")
            out["reloc_auto_options"] = sm.get("auto_correct_options")
            out["reloc_t3_only"] = sm.get("t3_only_cards")
            out["reloc_patterns"] = sm.get("by_pattern")
        if isinstance(edits, list):
            reloc_edits = 0
            for e in edits:
                if not isinstance(e, dict):
                    continue
                rat = str(e.get("rationale") or "")
                if "relocation" in rat.lower() or rat.startswith("t0_") or "prep_stage" in rat:
                    reloc_edits += 1
            out["reloc_driven_edits"] = reloc_edits
            # Top relocation cards for soak summary. Prefer *primary* patterns
            # (exclusive/bundle/plain) so soft-atomic SRAM/MMU heads do not hide
            # residual control_mvp / alu / csr cones that drive close@budget.
            if isinstance(rp, dict):
                cards = rp.get("cards") or []
                if isinstance(cards, list) and cards:
                    def _card_fo4(c: dict) -> float:
                        for k in ("total_fo4", "adjusted_fo4", "raw_fo4"):
                            v = c.get(k)
                            if isinstance(v, (int, float)):
                                return float(v)
                        return 0.0

                    def _is_primary_card(c: dict) -> bool:
                        pat = str(c.get("pattern") or "").lower()
                        return pat not in (
                            "atomic_op",
                            "multi_cycle",
                            "closed",
                            "unknown",
                        )

                    all_cards = [c for c in cards if isinstance(c, dict)]
                    primary_cards = [c for c in all_cards if _is_primary_card(c)]
                    if primary_cards:
                        top = sorted(primary_cards, key=_card_fo4, reverse=True)[:8]
                        out["reloc_top_bottlenecks"] = [
                            {
                                "path_id": c.get("path_id"),
                                "module": c.get("module"),
                                "pattern": c.get("pattern"),
                                "fo4": _card_fo4(c),
                                "preferred_auto": c.get("preferred_auto"),
                            }
                            for c in top
                        ]
                    else:
                        # Primary closed — do not surface soft-atomic heads as "top".
                        out["reloc_top_bottlenecks"] = []
                        out["reloc_primary_closed"] = True
                    # Absolute worst card (may be soft atomic) for diagnostics.
                    abs_top = sorted(all_cards, key=_card_fo4, reverse=True)[:3]
                    out["reloc_top_absolute"] = [
                        {
                            "path_id": c.get("path_id"),
                            "module": c.get("module"),
                            "pattern": c.get("pattern"),
                            "fo4": _card_fo4(c),
                        }
                        for c in abs_top
                    ]
        integ = data.get("integrity") or {}
        if isinstance(integ, dict):
            # Prefer explicit ok; else derive from reparse_ok + structural_ok.
            # context_soft (define/include gaps on joint) is OK when reparse_ok.
            if "ok" in integ:
                out["integrity_ok"] = integ.get("ok")
            else:
                reparse_ok = integ.get("reparse_ok")
                structural_ok = integ.get("structural_ok")
                if reparse_ok is False or structural_ok is False:
                    out["integrity_ok"] = False
                elif reparse_ok is True and structural_ok is not False:
                    out["integrity_ok"] = True
                else:
                    out["integrity_ok"] = integ.get("ok")
            out["integrity_joint_ok"] = integ.get("joint_ok")
            out["integrity_context_soft"] = integ.get("context_soft")
            out["integrity_soft"] = integ.get("soft")
        else:
            out["integrity_ok"] = integ
        out["schema"] = data.get("schema_version") or data.get("schema")
        return out

    paths = data.get("paths") or data.get("critical_paths") or []
    out["paths"] = len(paths) if isinstance(paths, list) else paths
    fc = data.get("frequency_closure") or {}
    out["closes"] = fc.get("closes")
    out["max_freq_mhz"] = fc.get("max_freq_mhz") or fc.get("estimated_max_freq_mhz")
    worst = None
    if isinstance(paths, list):
        for p in paths:
            if not isinstance(p, dict):
                continue
            t = p.get("total_fo4") or p.get("totalFo4")
            if isinstance(t, (int, float)):
                worst = t if worst is None else max(worst, t)
    out["worst_fo4"] = worst
    mods = data.get("modules") or []
    if isinstance(mods, list):
        out["modules"] = [
            m.get("name") for m in mods if isinstance(m, dict) and m.get("name")
        ]
    out["errors"] = data.get("errors") or data.get("parse_errors") or []
    out["opportunities"] = len(data.get("opportunities") or [])
    out["schema"] = data.get("schema") or data.get("schema_version")
    # Best-measure: primary (non multi_cycle) worst FO4 + path_class / relocation
    pcs = data.get("path_class_summary") or {}
    if isinstance(pcs, dict):
        out["path_class_summary"] = pcs
        out["path_class_adjusted"] = pcs.get("adjusted_paths")
        out["max_raw_fo4"] = pcs.get("max_raw_fo4")
        out["max_adjusted_fo4"] = pcs.get("max_adjusted_fo4")
    rp = data.get("relocation_plan") or {}
    if isinstance(rp, dict) and rp.get("summary"):
        sm = rp["summary"]
        out["reloc_failing_primary"] = sm.get("failing_primary")
        out["reloc_cards"] = sm.get("cards")
        out["reloc_auto_options"] = sm.get("auto_correct_options")
        out["reloc_t3_only"] = sm.get("t3_only_cards")
        out["reloc_patterns"] = sm.get("by_pattern")
    # Primary worst = max total_fo4 among !multi_cycle paths (best measure for single-cycle)
    if isinstance(paths, list):
        prim = None
        for p in paths:
            if not isinstance(p, dict) or p.get("multi_cycle"):
                continue
            t = p.get("total_fo4") or p.get("totalFo4")
            if isinstance(t, (int, float)):
                prim = t if prim is None else max(prim, t)
        if prim is not None:
            out["worst_primary_fo4"] = prim
            # Prefer primary over all-paths worst for "closes" narrative
            out["worst_fo4_best_measure"] = prim
    return out


def common_module_args(profile: SoakProfile) -> list[str]:
    if profile.all_modules or not profile.modules:
        return ["--all-modules"]
    return ["--modules", ",".join(profile.modules)]


def run_svt(
    pkg: Path,
    *,
    subcmd: str,
    portable_f: Path,
    profile: SoakProfile,
    param_map: Path | None,
    env: dict[str, str],
    extra: list[str],
    assume_clk: bool = False,
    use_cache: bool = False,
    cache_path: Path | None = None,
) -> tuple[int, list[str]]:
    cli = sv_timing_cli_bin(pkg)
    common = [
        subcmd,
        "--files-from",
        str(portable_f),
        "--target-mhz",
        str(profile.target_mhz),
        "--fo4-ps",
        str(profile.fo4_ps),
        *common_module_args(profile),
        *extra,
    ]
    # --cache is analyze-only; package-mode + param-map on both
    common.extend(["--package-mode", "packages"])
    if use_cache and cache_path is not None and subcmd == "analyze":
        common.extend(["--cache", str(cache_path)])
    if param_map and param_map.is_file():
        common.extend(["--param-map", str(param_map)])
    # --assume-clk is correct-only
    if assume_clk and subcmd == "correct":
        common.append("--assume-clk")

    if cli is not None:
        argv = [str(cli), *common]
    else:
        cargo = cargo_bin(pkg)
        if not cargo:
            raise RuntimeError("cargo not found; run: python tools/svt.py setup (or use WSL cargo)")
        argv = [
            str(cargo),
            "run",
            "-q",
            "-p",
            "sv-timing-cli",
            "--",
            *common,
        ]
    log("+ " + " ".join(argv))
    proc = subprocess.run(argv, cwd=str(pkg), env=env, check=False)
    return proc.returncode, argv


def run_analyze(
    pkg: Path,
    *,
    portable_f: Path,
    out_dir: Path,
    profile: SoakProfile,
    param_map: Path | None,
    env: dict[str, str],
    opt_level: str | None = None,
    allow_parse_errors: bool = False,
) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    json_out = out_dir / "analyze.json"
    cache = out_dir / "ir.sqlite"
    extra = ["--json-out", str(json_out)]
    if opt_level:
        extra.extend(["--opt-level", str(opt_level)])
    if allow_parse_errors:
        extra.append("--allow-parse-errors")
    code, _ = run_svt(
        pkg,
        subcmd="analyze",
        portable_f=portable_f,
        profile=profile,
        param_map=param_map,
        env=env,
        extra=extra,
        assume_clk=False,
        use_cache=True,
        cache_path=cache,
    )
    result: dict = {
        "profile": profile.id,
        "exit_code": code,
        "portable_f": str(portable_f),
        **metrics_from_report(json_out),
    }
    return result


def run_correct(
    pkg: Path,
    *,
    portable_f: Path,
    out_dir: Path,
    profile: SoakProfile,
    param_map: Path | None,
    env: dict[str, str],
    emit: bool,
    allow_latency: bool,
    opt_level: str | None = None,
    allow_parse_errors: bool = False,
    real_cut_feeds: bool = False,
    emit_balance_mux_rtl: bool = False,
) -> dict:
    """Run auto-correct; optionally emit corrected tree for --from-timing / STA."""
    out_dir.mkdir(parents=True, exist_ok=True)
    json_out = out_dir / "correct.json"
    extra = [
        "--json-out",
        str(json_out),
    ]
    # Prefer -O preset dials; only force max-passes when no opt-level (legacy soak).
    if opt_level:
        extra.extend(["--opt-level", str(opt_level)])
    else:
        extra.extend(["--max-passes", "16"])
    if allow_latency:
        extra.append("--allow-latency")
    if allow_parse_errors:
        extra.append("--allow-parse-errors")
    if emit:
        emit_dir = out_dir / "corrected"
        extra.extend(["--emit", "--out-dir", str(emit_dir)])
        # Optional richer emit (default lean zero-feed FO4 sidecar).
        if real_cut_feeds:
            extra.append("--real-cut-feeds")
        if emit_balance_mux_rtl:
            extra.append("--emit-balance-mux-rtl")
    # dry-run is default when not emitting; do not pass unsupported flags

    code, _ = run_svt(
        pkg,
        subcmd="correct",
        portable_f=portable_f,
        profile=profile,
        param_map=param_map,
        env=env,
        extra=extra,
        assume_clk=profile.assume_clk,
        use_cache=False,
    )
    cm = metrics_from_report(json_out)
    result: dict = {
        "correct_exit": code,
        "emit": emit,
        **{f"correct_{k}": v for k, v in cm.items()},
    }
    # Promote FO4 / closure fields for summary table (prefer primary Δ).
    if cm.get("fo4_delta") is not None:
        result["fo4_delta"] = cm["fo4_delta"]
        result["fo4_improved"] = cm.get("fo4_improved")
        result["fo4_delta_kind"] = cm.get("fo4_delta_kind", "all_paths")
    if cm.get("worst_fo4_before") is not None:
        result["worst_fo4_before"] = cm["worst_fo4_before"]
    if cm.get("worst_fo4") is not None:
        result["worst_fo4_after"] = cm["worst_fo4"]
    if cm.get("worst_primary_fo4") is not None:
        result["worst_primary_fo4_after"] = cm["worst_primary_fo4"]
    if cm.get("worst_primary_fo4_before") is not None:
        result["worst_primary_fo4_before"] = cm["worst_primary_fo4_before"]
    if cm.get("closes") is not None:
        result["closes_after_correct"] = cm["closes"]
    if cm.get("max_freq_mhz") is not None:
        result["max_freq_mhz_after_correct"] = cm["max_freq_mhz"]
    if cm.get("edits") is not None:
        result["edits"] = cm["edits"]
    if cm.get("reloc_failing_primary") is not None:
        result["reloc_failing_primary_after"] = cm["reloc_failing_primary"]
        result["reloc_cards_after"] = cm.get("reloc_cards")
    if cm.get("integrity_ok") is False:
        result["emit_integrity_failed"] = True
    corr = out_dir / "corrected"
    if corr.is_dir():
        result["corrected_dir"] = str(corr)
        for name in ("svt_corrected.f", "svt_emit_manifest.json"):
            p = corr / name
            if p.is_file():
                result[name.replace(".", "_")] = str(p)
    return result


def write_from_timing_package(
    out_dir: Path,
    *,
    profile: SoakProfile,
    repo: Path,
    param_map: Path | None,
    analyze_ok: bool,
    correct_meta: dict | None,
) -> dict:
    """Materialize stamp.json + param-map so build-platform --from-timing validates."""
    import time

    report = out_dir / "correct.json" if (out_dir / "correct.json").is_file() else out_dir / "analyze.json"
    portable = out_dir / "portable.f"
    stamp = {
        "schema": "cva6-timings-stamp.v0",
        "source": "monorepo-soak",
        "profile": profile.id,
        "repo": str(repo).replace("\\", "/"),
        "targetMhz": profile.target_mhz,
        "modules": profile.modules,
        "allModules": profile.all_modules or not profile.modules,
        "command": "monorepo-soak",
        "exitCode": 0 if analyze_ok else 1,
        "mtimeMs": int(time.time() * 1000),
        "portableF": str(portable).replace("\\", "/"),
        "reportJson": str(report).replace("\\", "/") if report.is_file() else None,
        "paramMap": str(param_map).replace("\\", "/") if param_map and param_map.is_file() else None,
        "emitDir": correct_meta.get("corrected_dir") if correct_meta else None,
        "note": "structural FO4 package for --from-timing / sta-handoff; not STA sign-off",
    }
    stamp_path = out_dir / "stamp.json"
    stamp_path.write_text(json.dumps(stamp, indent=2) + "\n", encoding="utf-8")
    if param_map and param_map.is_file():
        dest = out_dir / "param-map.json"
        if not dest.is_file() or dest.resolve() != param_map.resolve():
            dest.write_text(param_map.read_text(encoding="utf-8"), encoding="utf-8")
    # Hand-off recipe for operators / host CI
    recipe = {
        "schema": "cva6-from-timing-handoff-recipe.v0",
        "package": str(out_dir).replace("\\", "/"),
        "disclaimer": "emit is review-only; FO4 not STA; prefer live RTL unless --use-emit reviewed",
        "validate": f"cva6-build timings validate --from-timing {out_dir}",
        "summary": f"cva6-build timings summary --from-timing {out_dir}",
        "sta_handoff_live": (
            f"cva6-build timings sta-handoff --from-timing {out_dir} --try-tools"
        ),
        "sta_handoff_emit": (
            f"cva6-build timings sta-handoff --from-timing {out_dir} "
            f"--use-emit --try-tools"
            if correct_meta and correct_meta.get("corrected_dir")
            else None
        ),
        "lab_with_liberty": (
            "CVA6_LIBERTY=/path/to.lib cva6-build timings sta-handoff "
            f"--from-timing {out_dir} --use-emit --try-tools --no-sta-fixture"
        ),
        "autocorrect_validity_checks": [
            "analyze.json vs correct.json: worst_fo4 / max_freq_mhz / closes",
            "corrected/ re-parseable (CLI integrity) — package gate",
            "sta-handoff S0 seeds from package FO4 ranks",
            "optional S1 Yosys on portable.f vs --use-emit corrected flist",
            "optional S2 OpenSTA + correlate (real liberty); do not retune from fixture",
        ],
    }
    recipe_path = out_dir / "from-timing-recipe.json"
    recipe_path.write_text(json.dumps(recipe, indent=2) + "\n", encoding="utf-8")
    return {
        "stamp": str(stamp_path),
        "recipe": str(recipe_path),
        "from_timing": str(out_dir).replace("\\", "/"),
    }


def try_host_sta_handoff(
    repo: Path,
    package_dir: Path,
    *,
    use_emit: bool,
    try_tools: bool,
) -> dict:
    """Optional: invoke build-platform timings sta-handoff when bun is present."""
    bun = shutil.which("bun")
    bp = repo / "build-platform"
    if not bun or not bp.is_dir():
        return {
            "skipped": True,
            "detail": "bun or build-platform missing — run handoff manually via recipe",
        }
    out = (
        repo
        / "build-platform"
        / "workspace"
        / "build"
        / "sta-handoff"
        / f"soak-{package_dir.name}"
    )
    argv = [
        bun,
        "run",
        "src/cli/index.ts",
        "timings",
        "sta-handoff",
        "--from-timing",
        str(package_dir),
        "--out",
        str(out),
    ]
    if try_tools:
        argv.append("--try-tools")
    if use_emit:
        argv.append("--use-emit")
    # Prefer real STA when liberty set; keep fixture for offline correlate otherwise
    if os.environ.get("CVA6_LIBERTY"):
        argv.append("--no-sta-fixture")
    else:
        argv.append("--inject-sta-fixture")
    log("+ " + " ".join(argv))
    proc = subprocess.run(argv, cwd=str(bp), check=False)
    return {
        "skipped": False,
        "exit_code": proc.returncode,
        "handoff_dir": str(out).replace("\\", "/"),
        "use_emit": use_emit,
    }


def write_summary(path: Path, results: list[dict], *, cycle_note: str) -> None:
    lines = [
        "# Monorepo structural FO4 soak",
        "",
        "> Not STA sign-off. Primary fix target: **sv-timing** package.",
        "> RTL (`core/` / uncore) only when a true logic bug is proven.",
        "> Auto-correct emit is **review-only** — never auto-merge into `core/`.",
        "",
        cycle_note,
        "",
        "| profile | analyze | paths | closes | MHz | primary FO4 | reloc cards | correct | fo4Δ | emit |",
        "|---------|---------|-------|--------|-----|-------------|-------------|---------|------|------|",
    ]
    for r in results:
        notes = []
        if r.get("skipped"):
            notes.append(str(r["skipped"]))
        ce = r.get("correct_exit")
        fo4d = r.get("fo4_delta")
        kind = r.get("fo4_delta_kind")
        if isinstance(fo4d, (int, float)):
            fo4s = f"{fo4d:+.1f}" + ("ᵖ" if kind == "primary" else "")
        else:
            fo4s = "—"
        emit = "yes" if r.get("corrected_dir") else ("dry" if ce is not None else "—")
        # Primary FO4: after-correct when present, else analyze primary.
        prim = r.get("worst_primary_fo4_after")
        if prim is None:
            prim = r.get("worst_primary_fo4")
        if prim is None:
            prim = r.get("worst_fo4_best_measure")
        if prim is None:
            prim = r.get("worst_fo4")
        prim_s = f"{prim:.1f}" if isinstance(prim, (int, float)) else "—"
        # Show analyze→correct primary when both known
        prim_b = r.get("worst_primary_fo4_before")
        if prim_b is None and r.get("worst_primary_fo4") is not None and r.get(
            "worst_primary_fo4_after"
        ) is not None:
            prim_b = r.get("worst_primary_fo4")
        if (
            isinstance(prim_b, (int, float))
            and isinstance(r.get("worst_primary_fo4_after"), (int, float))
        ):
            prim_s = f"{prim_b:.1f}→{r['worst_primary_fo4_after']:.1f}"
        rc = r.get("reloc_cards_after")
        if rc is None:
            rc = r.get("reloc_cards")
        rc_s = str(rc) if rc is not None else "—"
        closes = r.get("closes_after_correct")
        if closes is None:
            closes = r.get("closes")
        mhz = r.get("max_freq_mhz_after_correct")
        if mhz is None:
            mhz = r.get("max_freq_mhz")
        lines.append(
            f"| `{r.get('profile')}` | {r.get('exit_code')} | {r.get('paths', '—')} | "
            f"{closes} | {mhz} | "
            f"{prim_s} | {rc_s} | "
            f"{ce if ce is not None else '—'} | {fo4s} | {emit} |"
        )
        if notes:
            lines.append(f"| | | | | | | | | | {'; '.join(notes)} |")
    # Best-measure / relocation detail
    lines.extend(
        [
            "",
            "## Best-measure FO4 (primary paths)",
            "",
            "Primary = non-`multi_cycle` after path_class (exclusive max, independent-LHS, "
            "atomic soft multi-cycle). Raw sum ghosts are deflated before ranking.",
            "",
        ]
    )
    for r in results:
        if r.get("skipped") or r.get("exit_code") not in (0, None):
            continue
        lines.append(f"### `{r.get('profile')}`")
        lines.append("")
        pcs = r.get("path_class_summary")
        if isinstance(pcs, dict):
            lines.append(f"- path_class: `{pcs.get('counts', pcs)}`")
            if pcs.get("adjusted_paths") is not None:
                lines.append(
                    f"- adjusted_paths={pcs.get('adjusted_paths')} "
                    f"max_raw={pcs.get('max_raw_fo4')} max_adj={pcs.get('max_adjusted_fo4')}"
                )
        if r.get("reloc_failing_primary") is not None:
            lines.append(
                f"- relocation: failing_primary={r.get('reloc_failing_primary')} "
                f"cards={r.get('reloc_cards')} auto_opts={r.get('reloc_auto_options')} "
                f"t3_only={r.get('reloc_t3_only')} patterns=`{r.get('reloc_patterns')}`"
            )
        if r.get("worst_primary_fo4_after") is not None or r.get("closes_after_correct") is not None:
            lines.append(
                f"- after correct: primary_FO4={r.get('worst_primary_fo4_after', '—')} "
                f"closes={r.get('closes_after_correct', '—')} "
                f"MHz={r.get('max_freq_mhz_after_correct', '—')} "
                f"edits={r.get('edits', '—')} "
                f"fo4Δ={r.get('fo4_delta', '—')} ({r.get('fo4_delta_kind', '?')})"
            )
        lines.append("")
    # Autocorrect validity section
    lines.extend(
        [
            "",
            "## Auto-correct → `--from-timing` → OpenSTA validity",
            "",
            "1. **Analyze baseline** FO4 ranks on real sparse modules.",
            "2. **Correct** dry-run or `--emit` (review-only tree under `corrected/`).",
            "3. Compare `worst_fo4` / `max_freq_mhz` / `closes` before vs after (this table).",
            "4. Package is **from-timing ready** when `stamp.json` + `portable.f` + report JSON exist.",
            "5. Host: `timings validate --from-timing <pkg>` then "
            "`timings sta-handoff --from-timing <pkg> [--use-emit] --try-tools`.",
            "6. OpenSTA S1–S2 soft-skip without yosys/liberty; correlate may use offline fixture "
            "only for host self-test — **do not retune fo4-v1 from fixture**.",
            "7. If FO4 improves but STA does not: refuse emit trust; fix transform or package model.",
            "",
            "## Fix priority (coding philosophy §2.8)",
            "",
            "1. **Parser / lower / FO4 / emit bug** → `sv-timing/crates/**` + fixtures.",
            "2. **Param-map / flist incomplete** → soak profile or host flist (not crates).",
            "3. **True RTL timing/logic bug** → rare; `core/` or uncore + full SoC checklist.",
            "",
            "Docs: `sv-timing/architecture/MONOREPO-SOAK.md`, "
            "`architecture/build-platform-opensta-from-timing.md`.",
            "",
        ]
    )
    # Per-profile recipe paths
    recipes = [r for r in results if r.get("recipe") or r.get("from_timing")]
    if recipes:
        lines.extend(["## Packages", ""])
        for r in recipes:
            lines.append(f"- **{r.get('profile')}**: `{r.get('from_timing')}`")
            if r.get("recipe"):
                lines.append(f"  - recipe: `{r['recipe']}`")
            if r.get("sta_handoff"):
                lines.append(f"  - sta-handoff: `{r['sta_handoff']}`")
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description=(
            "Opt-in structural FO4 soak on real monorepo SystemVerilog "
            "(package-first fixes; not STA)"
        ),
    )
    ap.add_argument(
        "--repo",
        default=None,
        help="Monorepo root (default: SVT_MONOREPO_ROOT / CVA6_REPO_DIR / parent of package)",
    )
    ap.add_argument(
        "--profile",
        action="append",
        default=[],
        help="Profile id to run (repeatable). Default: all discovered/builtin",
    )
    ap.add_argument(
        "--target-mhz",
        type=float,
        default=None,
        help="Override profile target_mhz for all runs (e.g. 2000 for 2 GHz scale experiment)",
    )
    ap.add_argument(
        "--fo4-ps",
        type=float,
        default=None,
        help="Override profile fo4_ps (default: keep profile / 20.0)",
    )
    ap.add_argument(
        "--profile-file",
        action="append",
        default=[],
        type=Path,
        help="Extra soak profile TOML (repeatable)",
    )
    ap.add_argument(
        "--out-dir",
        default=None,
        help="Output root for portable.f / analyze.json / soak-summary",
    )
    ap.add_argument("--list", action="store_true", help="List profiles and exit")
    ap.add_argument(
        "--soft-skip-missing-repo",
        action="store_true",
        help="Exit 0 if monorepo root not found (optional CI)",
    )
    ap.add_argument(
        "--correct",
        action="store_true",
        help="Run auto-correct after analyze (dry-run unless --emit)",
    )
    ap.add_argument(
        "--emit",
        action="store_true",
        help="With --correct: emit corrected/ tree (review-only; for --use-emit STA)",
    )
    ap.add_argument(
        "--real-cut-feeds",
        action="store_true",
        help="With --emit: origin RHS cut feeds + continuous rewrite/sinks (richer; default lean)",
    )
    ap.add_argument(
        "--emit-balance-mux-rtl",
        action="store_true",
        help="With --emit: BalanceMux structural snippets + origin RHS rewrite (default credit-only)",
    )
    ap.add_argument(
        "--allow-latency",
        action="store_true",
        help="Pass --allow-latency to correct (multi-cycle cuts)",
    )
    ap.add_argument(
        "--opt-level",
        default=None,
        metavar="LEVEL",
        help="Pass --opt-level to analyze/correct (0|1|2|3|s|z, e.g. 3 for -O3)",
    )
    ap.add_argument(
        "--allow-parse-errors",
        action="store_true",
        help="Pass --allow-parse-errors (skip bad files; report skipped_files)",
    )
    ap.add_argument(
        "--package",
        action="store_true",
        default=True,
        help="Write stamp.json + from-timing-recipe.json (default on)",
    )
    ap.add_argument(
        "--no-package",
        action="store_true",
        help="Skip stamp/recipe materialization",
    )
    ap.add_argument(
        "--sta-handoff",
        action="store_true",
        help="If bun+build-platform present, run timings sta-handoff --from-timing",
    )
    ap.add_argument(
        "--use-emit",
        action="store_true",
        help="With --sta-handoff: pass --use-emit (requires --emit)",
    )
    ap.add_argument(
        "--try-tools",
        action="store_true",
        help="With --sta-handoff: pass --try-tools (Yosys/OpenSTA soft stages)",
    )
    args = ap.parse_args(argv)
    do_package = args.package and not args.no_package
    do_correct = bool(args.correct or args.emit)
    do_emit = bool(args.emit)

    pkg = package_root()
    repo = Path(args.repo).resolve() if args.repo else find_monorepo_root(pkg)
    if repo is None:
        msg = (
            "monorepo root not found (need core/ next to sv-timing/, or "
            "SVT_MONOREPO_ROOT / CVA6_REPO_DIR). Package unit tests do not need this."
        )
        if args.soft_skip_missing_repo:
            log(msg + " — soft-skip")
            return 0
        err(msg)
        return 2

    profiles = load_profiles(
        repo,
        profile_ids=args.profile or None,
        profile_files=list(args.profile_file),
    )
    # Optional frequency / FO4 unit overrides (scale experiments)
    if args.target_mhz is not None:
        for p in profiles:
            p.target_mhz = float(args.target_mhz)
        log(f"override target_mhz={args.target_mhz} on {len(profiles)} profile(s)")
    if args.fo4_ps is not None:
        for p in profiles:
            p.fo4_ps = float(args.fo4_ps)
        log(f"override fo4_ps={args.fo4_ps} on {len(profiles)} profile(s)")
    if args.list:
        for p in profiles:
            print(f"{p.id:20}  {p.flist}  modules={p.modules or 'ALL'}  {p.notes}")
        if not profiles:
            print("(no profiles — monorepo flists missing?)")
        return 0
    if not profiles:
        err("no soak profiles available")
        return 1

    if args.out_dir:
        out_root = Path(args.out_dir)
    elif (repo / "build-platform").is_dir():
        out_root = (
            repo
            / "build-platform"
            / "workspace"
            / "build"
            / "sv-timing"
            / "monorepo-soak"
        )
    else:
        out_root = pkg / ".sv-timing-out" / "monorepo-soak"
    out_root.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    repo_posix = str(repo).replace("\\", "/")
    env["CVA6_REPO_DIR"] = repo_posix
    env["SVT_MONOREPO_ROOT"] = repo_posix
    cargo_home = env.get("CARGO_HOME") or str(pkg / ".tools" / "cargo")
    rustup_home = env.get("RUSTUP_HOME") or str(pkg / ".tools" / "rustup")
    env["CARGO_HOME"] = cargo_home
    env["RUSTUP_HOME"] = rustup_home
    env["PATH"] = str(Path(cargo_home) / "bin") + os.pathsep + env.get("PATH", "")

    results: list[dict] = []
    hard_fail = False

    for prof in profiles:
        log(f"=== profile {prof.id} ===")
        flist_path = Path(prof.flist)
        if not flist_path.is_file():
            flist_path = repo / prof.flist
        if not flist_path.is_file():
            results.append(
                {
                    "profile": prof.id,
                    "exit_code": 0,
                    "skipped": f"flist missing: {prof.flist}",
                }
            )
            log(f"skip {prof.id}: flist missing")
            continue

        prof_out = out_root / prof.id
        prof_out.mkdir(parents=True, exist_ok=True)
        portable = prof_out / "portable.f"

        try:
            expanded = expand_filelist(
                flist_path,
                env={
                    "CVA6_REPO_DIR": repo_posix,
                    "SVT_MONOREPO_ROOT": repo_posix,
                    "REPO": repo_posix,
                    "ROOT": repo_posix,
                },
                cwd=repo,
                strict=False,
            )
            portable, dropped, kept_files = write_filtered_portable(
                expanded.files,
                expanded.incdirs,
                portable,
                soft=prof.soft_missing,
            )
            # Also keep full expand via write_portable_f for debugging
            write_portable_f(
                prof_out / "portable.full.f",
                expanded,
                absolute=True,
                header="# full expand (may list missing files)",
            )
        except Exception as e:  # noqa: BLE001 — surface expand errors per profile
            hard_fail = True
            results.append(
                {"profile": prof.id, "exit_code": 1, "skipped": f"expand failed: {e}"}
            )
            err(f"{prof.id}: expand failed: {e}")
            continue

        if dropped:
            log(f"dropped {len(dropped)} missing source(s) (soft={prof.soft_missing})")

        param_map: Path | None = None
        if prof.param_map:
            pm = Path(prof.param_map)
            if not pm.is_file():
                pm = repo / prof.param_map
            if pm.is_file():
                # Always absolute: run_svt cwd is the sv-timing package, not repo root.
                param_map = pm.resolve()

        if not kept_files:
            results.append(
                {
                    "profile": prof.id,
                    "exit_code": 0,
                    "skipped": "no present sources after filter",
                    "dropped": dropped,
                }
            )
            log(f"skip {prof.id}: no present sources")
            continue

        try:
            r = run_analyze(
                pkg,
                portable_f=portable,
                out_dir=prof_out,
                profile=prof,
                param_map=param_map,
                env=env,
                opt_level=getattr(args, "opt_level", None),
                allow_parse_errors=bool(getattr(args, "allow_parse_errors", False)),
            )
        except RuntimeError as e:
            err(str(e))
            return 1
        r["dropped"] = dropped
        analyze_ok = r.get("exit_code", 1) == 0
        if not analyze_ok:
            hard_fail = True
            log(f"profile {prof.id} FAILED exit={r.get('exit_code')} — fix package first")
        else:
            log(
                f"profile {prof.id} analyze OK paths={r.get('paths')} "
                f"closes={r.get('closes')} "
                f"primary_fo4={r.get('worst_primary_fo4', r.get('worst_fo4'))} "
                f"worst_all={r.get('worst_fo4')}"
            )

        correct_meta: dict | None = None
        if do_correct and analyze_ok:
            try:
                analyze_primary = r.get("worst_primary_fo4")
                correct_meta = run_correct(
                    pkg,
                    portable_f=portable,
                    out_dir=prof_out,
                    profile=prof,
                    param_map=param_map,
                    env=env,
                    emit=do_emit,
                    allow_latency=bool(args.allow_latency),
                    opt_level=getattr(args, "opt_level", None),
                    allow_parse_errors=bool(getattr(args, "allow_parse_errors", False)),
                    real_cut_feeds=bool(getattr(args, "real_cut_feeds", False)),
                    emit_balance_mux_rtl=bool(getattr(args, "emit_balance_mux_rtl", False)),
                )
                r.update(correct_meta)
                # Prefer analyze→correct primary FO4 Δ when both sides known.
                corr_prim = correct_meta.get("worst_primary_fo4_after")
                if corr_prim is None:
                    corr_prim = correct_meta.get("correct_worst_primary_fo4")
                if (
                    isinstance(analyze_primary, (int, float))
                    and isinstance(corr_prim, (int, float))
                ):
                    r["worst_primary_fo4_before"] = float(analyze_primary)
                    r["worst_primary_fo4_after"] = float(corr_prim)
                    r["fo4_delta"] = float(corr_prim) - float(analyze_primary)
                    r["fo4_improved"] = r["fo4_delta"] < -0.01
                    r["fo4_delta_kind"] = "primary"
                if correct_meta.get("closes_after_correct") is not None:
                    r["closes"] = correct_meta["closes_after_correct"]
                if correct_meta.get("max_freq_mhz_after_correct") is not None:
                    r["max_freq_mhz"] = correct_meta["max_freq_mhz_after_correct"]
                if correct_meta.get("correct_exit", 1) != 0:
                    hard_fail = True
                    log(f"profile {prof.id} correct FAILED — fix package first")
                else:
                    log(
                        f"profile {prof.id} correct OK emit={do_emit} "
                        f"primary_fo4={analyze_primary}→{corr_prim} "
                        f"fo4_delta={r.get('fo4_delta')} "
                        f"closes={r.get('closes')}"
                    )
            except RuntimeError as e:
                err(str(e))
                return 1

        if do_package:
            pkg_meta = write_from_timing_package(
                prof_out,
                profile=prof,
                repo=repo,
                param_map=param_map,
                analyze_ok=analyze_ok,
                correct_meta=correct_meta,
            )
            r.update(pkg_meta)
            log(f"from-timing package: {pkg_meta.get('from_timing')}")

        if args.sta_handoff and do_package and analyze_ok:
            hand = try_host_sta_handoff(
                repo,
                prof_out,
                use_emit=bool(args.use_emit and do_emit),
                try_tools=bool(args.try_tools),
            )
            r["sta_handoff"] = hand
            if not hand.get("skipped") and hand.get("exit_code", 1) != 0:
                hard_fail = True
                log(f"sta-handoff failed exit={hand.get('exit_code')}")
            elif hand.get("skipped"):
                log(f"sta-handoff skipped: {hand.get('detail')}")
            else:
                log(f"sta-handoff OK → {hand.get('handoff_dir')}")

        results.append(r)

    summary = out_root / "soak-summary.md"
    flags = []
    if do_correct:
        flags.append("correct" + ("+emit" if do_emit else "+dry"))
    if do_package:
        flags.append("from-timing-pkg")
    if args.sta_handoff:
        flags.append("sta-handoff")
    mhz_note = ""
    if args.target_mhz is not None or args.fo4_ps is not None:
        # Budget FO4 = (1000/MHz)*1000/fo4_ps * (1-margin); margin default 0.2
        tm = float(args.target_mhz) if args.target_mhz is not None else 1250.0
        fp = float(args.fo4_ps) if args.fo4_ps is not None else 20.0
        budget = (1000.0 / tm) * 1000.0 / fp * 0.8
        mhz_note = (
            f"\n- **scale:** target_mhz={tm} fo4_ps={fp} → budget_fo4≈{budget:.1f} "
            f"(margin 0.2; structural FO4 screening only)"
        )
    write_summary(
        summary,
        results,
        cycle_note=(
            f"- **repo:** `{repo}`\n- **out:** `{out_root}`\n"
            f"- **flags:** {', '.join(flags) or 'analyze-only'}"
            f"{mhz_note}"
        ),
    )
    log(f"summary: {summary}")
    (out_root / "soak-summary.json").write_text(
        json.dumps({"repo": str(repo), "results": results}, indent=2) + "\n",
        encoding="utf-8",
    )
    return 1 if hard_fail else 0


if __name__ == "__main__":
    sys.exit(main())
