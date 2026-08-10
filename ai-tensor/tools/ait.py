#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# ait.py — package CLI for ai-tensor (setup / doctor / test / golden / cosim / check).

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "tools" / "cosim_harness.py"


def log(msg: str) -> None:
    print(f"[ait] {msg}")


def run(cmd: list[str], *, cwd: Path | None = None, check: bool = True, env: dict | None = None) -> int:
    log("+ " + " ".join(cmd))
    r = subprocess.run(cmd, cwd=str(cwd or ROOT), env=env)
    if check and r.returncode != 0:
        sys.exit(r.returncode)
    return r.returncode


def default_cosim_cmd() -> str:
    # Prefer package venv python if present, else current interpreter.
    py = sys.executable
    return f"{py} {HARNESS}"


def cmd_doctor(_: argparse.Namespace) -> None:
    log(f"root={ROOT}")
    cargo = shutil.which("cargo")
    log(f"cargo={cargo or 'MISSING'}")
    log(f"python={sys.executable} {sys.version.split()[0]}")
    profile = ROOT / "profiles" / "sim-v0.toml"
    log(f"profile_sim_v0={'ok' if profile.is_file() else 'MISSING'}")
    log(f"cosim_harness={'ok' if HARNESS.is_file() else 'MISSING'}")
    bad = []
    for p in ROOT.joinpath("crates").rglob("Cargo.toml"):
        text = p.read_text(encoding="utf-8", errors="replace")
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


def cmd_test(ns: argparse.Namespace) -> None:
    cargo = shutil.which("cargo")
    if not cargo:
        log("ERROR: cargo not on PATH (install Rust or use contained setup later)")
        sys.exit(1)
    run([sys.executable, str(ROOT / "tools" / "check_independence.py")])
    run([cargo, "test", "--workspace", "--exclude", "ai-tensor-py"])
    run([cargo, "test", "-p", "ai-tensor-abi"])
    run([cargo, "test", "-p", "ai-tensor-ir"])
    run([cargo, "test", "-p", "ai-tensor-rt"])
    run([cargo, "build", "-p", "ai-tensor-cli"])
    # Offline dual-oracle goldens (sim + SoftIsland); optional external harness
    env = os.environ.copy()
    if ns.with_harness and "AI_TENSOR_COSIM_CMD" not in env:
        env["AI_TENSOR_COSIM_CMD"] = default_cosim_cmd()
        log(f"AI_TENSOR_COSIM_CMD={env['AI_TENSOR_COSIM_CMD']}")
    run([cargo, "run", "-q", "-p", "ai-tensor-cli", "--", "golden-check"], env=env)
    run([cargo, "run", "-q", "-p", "ai-tensor-cli", "--", "queue-soak", "--backend", "sim"])
    # Python smoke + goldens (no torch/tf required)
    env_py = os.environ.copy()
    env_py["PYTHONPATH"] = str(ROOT / "python") + os.pathsep + env_py.get("PYTHONPATH", "")
    log("+ python -m ai_tensor")
    r = subprocess.run([sys.executable, "-m", "ai_tensor"], cwd=str(ROOT), env=env_py)
    if r.returncode != 0:
        sys.exit(r.returncode)
    log("+ python golden suite")
    r = subprocess.run(
        [
            sys.executable,
            "-c",
            "from ai_tensor import run_golden_suite; print('py_golden', run_golden_suite())",
        ],
        cwd=str(ROOT),
        env=env_py,
    )
    if r.returncode != 0:
        sys.exit(r.returncode)
    hdr = ROOT / "include" / "ai_tensor.h"
    if hdr.is_file():
        log(f"c_abi_header=ok path={hdr}")
    else:
        log("ERROR: missing include/ai_tensor.h")
        sys.exit(1)
    try:
        import numpy  # noqa: F401

        log("+ numpy_island_smoke")
        r = subprocess.run(
            [sys.executable, str(ROOT / "python" / "examples" / "numpy_island_smoke.py")],
            cwd=str(ROOT),
            env=env_py,
        )
        if r.returncode != 0:
            sys.exit(r.returncode)
    except ImportError:
        log("skip numpy smoke (numpy not installed)")
    try:
        import torch  # noqa: F401

        log("+ torch_island_smoke")
        r = subprocess.run(
            [sys.executable, str(ROOT / "python" / "examples" / "torch_island_smoke.py")],
            cwd=str(ROOT),
            env=env_py,
        )
        if r.returncode != 0:
            sys.exit(r.returncode)
    except ImportError:
        log("skip torch smoke (torch not installed)")
    try:
        import tensorflow  # noqa: F401

        log("+ tf_island_smoke")
        r = subprocess.run(
            [sys.executable, str(ROOT / "python" / "examples" / "tf_island_smoke.py")],
            cwd=str(ROOT),
            env=env_py,
        )
        if r.returncode != 0:
            sys.exit(r.returncode)
    except ImportError:
        log("skip tf smoke (tensorflow not installed)")
    log("test: ok")


def cmd_golden(ns: argparse.Namespace) -> None:
    cargo = shutil.which("cargo")
    if not cargo:
        sys.exit("cargo required")
    env = os.environ.copy()
    if ns.with_harness and "AI_TENSOR_COSIM_CMD" not in env:
        env["AI_TENSOR_COSIM_CMD"] = default_cosim_cmd()
    run([cargo, "run", "-q", "-p", "ai-tensor-cli", "--", "golden-check"], env=env)


def cmd_cosim(ns: argparse.Namespace) -> None:
    """Run package harness suite (+ optional RTL probe)."""
    if not HARNESS.is_file():
        log(f"ERROR: missing {HARNESS}")
        sys.exit(1)
    env = os.environ.copy()
    if ns.rtl:
        env["AI_TENSOR_RUN_RTL"] = "1"
    # Direct harness suite (pure-Python + cargo dual-oracle)
    log("+ cosim_harness suite")
    r = subprocess.run(
        [sys.executable, str(HARNESS)],
        input='{"op":"suite"}\n',
        text=True,
        cwd=str(ROOT),
        env=env,
    )
    if r.returncode != 0:
        sys.exit(r.returncode)
    # Also exercise CLI path with AI_TENSOR_COSIM_CMD set (ping + gemm job)
    cargo = shutil.which("cargo")
    if cargo:
        env["AI_TENSOR_COSIM_CMD"] = default_cosim_cmd()
        # Nested golden-check must not re-enter suite via harness cargo call:
        # harness handles suite itself; here we only want ping+job via CLI.
        run([cargo, "run", "-q", "-p", "ai-tensor-cli", "--", "golden-check"], env=env)
    log("cosim: ok")


def cmd_check_independence(_: argparse.Namespace) -> None:
    run([sys.executable, str(ROOT / "tools" / "check_independence.py")])
    cabi = ROOT / "tools" / "check_c_abi.py"
    if cabi.is_file():
        run([sys.executable, str(cabi)])


def cmd_build_native(_: argparse.Namespace) -> None:
    cargo = shutil.which("cargo")
    if not cargo:
        sys.exit("cargo required")
    run([cargo, "build", "-p", "ai-tensor-py", "--release"])
    for p in (ROOT / "target" / "release").glob("*ai_tensor_native*"):
        log(f"native_artifact={p}")


def main() -> None:
    ap = argparse.ArgumentParser(prog="ait")
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("doctor", help="toolchain + independence").set_defaults(func=cmd_doctor)
    p_test = sp.add_parser("test", help="cargo tests + golden-check + python smoke")
    p_test.add_argument(
        "--with-harness",
        action="store_true",
        default=True,
        help="set AI_TENSOR_COSIM_CMD to tools/cosim_harness.py (default on)",
    )
    p_test.add_argument(
        "--no-harness",
        action="store_true",
        help="offline goldens only (no external cosim process)",
    )
    p_test.set_defaults(func=cmd_test)
    p_golden = sp.add_parser("golden", help="run offline goldens (+ optional harness)")
    p_golden.add_argument("--no-harness", action="store_true")
    p_golden.set_defaults(func=cmd_golden, with_harness=True)
    p_cosim = sp.add_parser(
        "cosim",
        help="run cosim_harness suite + CLI external checks",
    )
    p_cosim.add_argument(
        "--rtl",
        action="store_true",
        help="set AI_TENSOR_RUN_RTL=1 (soft monorepo probe; AI_TENSOR_RTL_HARD=1 for live TB)",
    )
    p_cosim.set_defaults(func=cmd_cosim)
    sp.add_parser("queue-soak", help="CLI multi-queue + WaitPolicy soak").set_defaults(
        func=lambda _: (
            run(
                [
                    shutil.which("cargo") or "cargo",
                    "run",
                    "-q",
                    "-p",
                    "ai-tensor-cli",
                    "--",
                    "queue-soak",
                    "--backend",
                    "sim",
                ]
            ),
            run(
                [
                    shutil.which("cargo") or "cargo",
                    "run",
                    "-q",
                    "-p",
                    "ai-tensor-cli",
                    "--",
                    "queue-soak",
                    "--backend",
                    "mmio",
                ]
            ),
        )
    )
    sp.add_parser("rtl", help="lab RTL soft/hard smoke (tools/rtl_smoke.py)").set_defaults(
        func=lambda _: run([sys.executable, str(ROOT / "tools" / "rtl_smoke.py")])
    )
    sp.add_parser("check-independence", help="KD0 path-dep gate").set_defaults(
        func=cmd_check_independence
    )
    sp.add_parser("build-native", help="build PyO3 cdylib").set_defaults(func=cmd_build_native)
    ns = ap.parse_args()
    if getattr(ns, "no_harness", False):
        ns.with_harness = False
    ns.func(ns)


if __name__ == "__main__":
    main()
