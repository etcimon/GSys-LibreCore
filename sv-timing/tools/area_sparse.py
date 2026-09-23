#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Opt-in area tag check for three existing sparse profiles.
# Writes area-report.json under the package out directory. Does not check
# that file in, and does not treat an area number as a golden.

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
_PKG = _TOOLS.parent

PROFILES = (
    {
        "id": "sparse_ex",
        "flist": "verif/sv-timing-tests/flists/sparse_ex_units.f",
        "modules": ["alu", "mult", "multiplier", "serdiv", "branch_unit"],
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
    },
    {
        "id": "sparse_ooo_issue",
        "flist": "verif/sv-timing-tests/flists/sparse_ooo_issue.f",
        "modules": [
            "g6lc_iq",
            "g6lc_lsq",
            "g6lc_memdep",
            "g6lc_rename",
            "g6lc_prf",
            "g6lc_rob",
            "g6lc_ooo_dispatch",
        ],
    },
)

PARAM_MAP = "verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json"
PRF_BITS = 48 * 64


def find_monorepo_root(pkg: Path) -> Path | None:
    env = os.environ.get("SVT_MONOREPO_ROOT", "").strip()
    if env:
        root = Path(env).expanduser().resolve()
        if (root / "core").is_dir():
            return root
    cur = pkg.resolve()
    for _ in range(5):
        parent = cur.parent if cur.name == "sv-timing" else cur
        if (parent / "core").is_dir() and (parent / "sv-timing").is_dir():
            return parent
        if cur.parent == cur:
            break
        cur = cur.parent
    return None


def _storage_bits(tags: list[str]) -> int | None:
    for tag in tags:
        if tag.startswith("storage_bits="):
            return int(tag.split("=", 1)[1])
    return None


def _index_tree(rows: list | None, found: dict | None = None) -> dict:
    found = found if found is not None else {}
    for row in rows or []:
        name = row.get("name")
        if name and name not in found:
            found[name] = row
        _index_tree(row.get("children"), found)
    return found


def check_report(profile_id: str, report: dict) -> list[str]:
    """Tag checks only. This function does not read exclusive_au."""
    errors: list[str] = []
    tree = _index_tree(report.get("tree"))
    if profile_id == "sparse_ooo_issue":
        prf = tree.get("g6lc_prf")
        if prf is None:
            errors.append("g6lc_prf row missing")
        else:
            tags = prf.get("tags", [])
            bits = _storage_bits(tags)
            if "storage_unrecorded" not in tags and bits != PRF_BITS:
                errors.append("g6lc_prf storage is neither unrecorded nor 48 by 64 bits")
        rob = tree.get("g6lc_rob")
        if rob is None:
            errors.append("g6lc_rob row missing")
        else:
            tags = rob.get("tags", [])
            if "storage_width_unresolved" not in tags and "storage_unrecorded" not in tags:
                errors.append("g6lc_rob storage tag missing")
    elif profile_id == "sparse_ex":
        blob = json.dumps(report)
        for name in ("i_cpop_count", "i_clz_64b", "i_clz_32b"):
            if f"opaque_child={name}" not in blob:
                errors.append(f"missing opaque child {name}")
        serdiv = tree.get("serdiv")
        if serdiv is None or serdiv.get("perf_basis") != "multicycle_only":
            errors.append("serdiv basis is not multicycle_only")
        classes = [
            item.get("class")
            for item in report.get("path_classes", [])
            if item.get("module") == "alu"
        ]
        if not any(kind in ("exclusive_case_mux", "exclusive_if_chain") for kind in classes):
            errors.append("alu path class was not kept")
    elif profile_id == "sparse_issue_lsu":
        scoreboard = tree.get("scoreboard")
        if scoreboard is None or "generate_unresolved" not in scoreboard.get("tags", []):
            errors.append("scoreboard generate tag missing")
    else:
        errors.append(f"unknown profile {profile_id}")
    return errors


def _self_check() -> int:
    ooo = {
        "tree": [
            {"name": "g6lc_prf", "tags": ["storage_unrecorded"], "perf_basis": "node_depth"},
            {
                "name": "g6lc_rob",
                "tags": ["storage_width_unresolved"],
                "perf_basis": "node_depth",
            },
        ],
        "path_classes": [],
    }
    if check_report("sparse_ooo_issue", ooo):
        print("self-check failed on unrecorded storage", file=sys.stderr)
        return 1
    ooo["tree"][0]["tags"] = [f"storage_bits={PRF_BITS}"]
    if check_report("sparse_ooo_issue", ooo):
        print("self-check failed on bit product", file=sys.stderr)
        return 1
    ex = {
        "tree": [{"name": "serdiv", "tags": [], "perf_basis": "multicycle_only"}],
        "path_classes": [{"module": "alu", "class": "exclusive_case_mux"}],
    }
    text = json.dumps(ex)
    text = text  # names are asserted on the object below
    ex_blob = {
        "tree": ex["tree"],
        "path_classes": ex["path_classes"],
        "tags_blob": [
            "opaque_child=i_cpop_count",
            "opaque_child=i_clz_64b",
            "opaque_child=i_clz_32b",
        ],
    }
    # The checker searches the serialized report, so put the tags on a row.
    ex_blob["tree"].append(
        {
            "name": "ex_parent",
            "tags": ex_blob.pop("tags_blob"),
            "perf_basis": "primary_path",
        }
    )
    if check_report("sparse_ex", ex_blob):
        print("self-check failed on sparse_ex", file=sys.stderr)
        return 1
    issue = {
        "tree": [
            {"name": "scoreboard", "tags": ["generate_unresolved"], "perf_basis": "primary_path"}
        ]
    }
    if check_report("sparse_issue_lsu", issue):
        print("self-check failed on scoreboard", file=sys.stderr)
        return 1
    if not check_report("sparse_issue_lsu", {"tree": [{"name": "scoreboard", "tags": []}]}):
        print("self-check accepted a missing generate tag", file=sys.stderr)
        return 1
    print("area-sparse self-check ok")
    return 0


def _sv_timing_argv(pkg: Path, args: list[str]) -> list[str]:
    cargo = os.environ.get("CARGO", "cargo")
    return [cargo, "run", "-q", "-p", "sv-timing-cli", "--", *args]


def soak_out_root(root: Path) -> Path:
    host = root / "build-platform"
    if host.is_dir():
        return host / "workspace" / "build" / "sv-timing" / "monorepo-soak"
    return _PKG / ".sv-timing-out" / "monorepo-soak"


def run_profiles(root: Path, target_mhz: str) -> int:
    out_root = soak_out_root(root)
    param_map = root / PARAM_MAP
    failed = 0
    for profile in PROFILES:
        flist = root / profile["flist"]
        if not flist.is_file():
            print(f"missing flist {flist}", file=sys.stderr)
            failed += 1
            continue
        out_dir = out_root / profile["id"]
        out_dir.mkdir(parents=True, exist_ok=True)
        report_path = out_dir / "area-report.json"
        argv = _sv_timing_argv(
            _PKG,
            [
                "area",
                "--files-from",
                str(flist),
                "--modules",
                ",".join(profile["modules"]),
                "--param-map",
                str(param_map),
                "--target-mhz",
                target_mhz,
                "--allow-parse-errors",
                "--json-out",
                str(report_path),
            ],
        )
        proc = subprocess.run(argv, cwd=str(_PKG), check=False)
        if proc.returncode != 0 or not report_path.is_file():
            print(f"{profile['id']} area command failed", file=sys.stderr)
            failed += 1
            continue
        report = json.loads(report_path.read_text(encoding="utf-8"))
        errors = check_report(profile["id"], report)
        if errors:
            print(f"{profile['id']}: " + "; ".join(errors), file=sys.stderr)
            failed += 1
        else:
            print(f"{profile['id']} tags ok")
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Opt-in sparse area tag check")
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--target-mhz", default="1000")
    args = parser.parse_args(argv)
    if args.self_check or not args.run:
        code = _self_check()
        if code != 0 or not args.run:
            return code
    root = find_monorepo_root(_PKG)
    if root is None:
        print("monorepo root not found; pass SVT_MONOREPO_ROOT", file=sys.stderr)
        return 2
    return run_profiles(root, args.target_mhz)


if __name__ == "__main__":
    raise SystemExit(main())
