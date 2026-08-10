#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# ait.py — package CLI for ai-tensor (setup / doctor / test / check).

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def log(msg: str) -> None:
    print(f"[ait] {msg}")


def run(cmd: list[str], *, cwd: Path | None = None, check: bool = True) -> int:
    log("+ " + " ".join(cmd))
    r = subprocess.run(cmd, cwd=str(cwd or ROOT))
    if check and r.returncode != 0:
        sys.exit(r.returncode)
    return r.returncode


def cmd_doctor(_: argparse.Namespace) -> None:
    log(f"root={ROOT}")
    cargo = shutil.which("cargo")
    log(f"cargo={cargo or 'MISSING'}")
    log(f"python={sys.executable} {sys.version.split()[0]}")
    profile = ROOT / "profiles" / "sim-v0.toml"
    log(f"profile_sim_v0={'ok' if profile.is_file() else 'MISSING'}")
    # independence: no path deps outside package
    bad = []
    for p in ROOT.joinpath("crates").rglob("Cargo.toml"):
        text = p.read_text(encoding="utf-8", errors="replace")
        if "../.." in text and "path" in text:
            # allow workspace relative only under ai-tensor
            pass
        if "build-platform" in text or "corev_apu" in text:
            bad.append(str(p))
    if bad:
        log("ERROR: monorepo path deps: " + ", ".join(bad))
        sys.exit(1)
    log("independence: ok (no monorepo path strings in crate manifests)")
    if cargo:
        r = subprocess.run(
            [cargo, "metadata", "--no-deps", "--format-version", "1"],
            cwd=str(ROOT),
            capture_output=True,
            text=True,
        )
        log(f"cargo_metadata_rc={r.returncode}")


def cmd_test(_: argparse.Namespace) -> None:
    cargo = shutil.which("cargo")
    if not cargo:
        log("ERROR: cargo not on PATH (install Rust or use contained setup later)")
        sys.exit(1)
    run([cargo, "test", "--workspace", "--exclude", "ai-tensor-py"])
    # py crate often needs special link flags; test rlib parts via workspace exclude
    run([cargo, "test", "-p", "ai-tensor-abi"])
    run([cargo, "test", "-p", "ai-tensor-ir"])
    run([cargo, "test", "-p", "ai-tensor-rt"])
    run([cargo, "build", "-p", "ai-tensor-cli"])
    # Python smoke (no torch required)
    env = os.environ.copy()
    env["PYTHONPATH"] = str(ROOT / "python") + os.pathsep + env.get("PYTHONPATH", "")
    log("+ python -m ai_tensor")
    r = subprocess.run([sys.executable, "-m", "ai_tensor"], cwd=str(ROOT), env=env)
    if r.returncode != 0:
        sys.exit(r.returncode)
    # Optional torch
    try:
        import torch  # noqa: F401

        log("+ torch_island_smoke")
        r = subprocess.run(
            [sys.executable, str(ROOT / "python" / "examples" / "torch_island_smoke.py")],
            cwd=str(ROOT),
            env=env,
        )
        if r.returncode != 0:
            sys.exit(r.returncode)
    except ImportError:
        log("skip torch smoke (torch not installed)")
    log("test: ok")


def cmd_check_independence(_: argparse.Namespace) -> None:
    run([sys.executable, str(ROOT / "tools" / "check_independence.py")])


def cmd_build_native(_: argparse.Namespace) -> None:
    cargo = shutil.which("cargo")
    if not cargo:
        sys.exit("cargo required")
    run([cargo, "build", "-p", "ai-tensor-py", "--release"])
    # Hint where the .so/.pyd landed
    for p in (ROOT / "target" / "release").glob("*ai_tensor_native*"):
        log(f"native_artifact={p}")


def main() -> None:
    ap = argparse.ArgumentParser(prog="ait")
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("doctor", help="toolchain + independence").set_defaults(func=cmd_doctor)
    sp.add_parser("test", help="cargo tests + python smoke").set_defaults(func=cmd_test)
    sp.add_parser("check-independence", help="alias doctor independence").set_defaults(
        func=cmd_check_independence
    )
    sp.add_parser("build-native", help="build PyO3 cdylib").set_defaults(func=cmd_build_native)
    ns = ap.parse_args()
    ns.func(ns)


if __name__ == "__main__":
    main()
