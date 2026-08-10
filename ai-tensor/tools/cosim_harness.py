#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
External cosim adapter for ai-tensor (`AI_TENSOR_COSIM_CMD`).

Package crates stay independent of monorepo paths: this script is the only
optional bridge. Invoke via:

  export AI_TENSOR_COSIM_CMD="python3 tools/cosim_harness.py"
  cargo run -p ai-tensor-cli -- golden-check

JSON-on-stdin protocol (one object per process):

  {"ping": true}
      -> stdout: pong ok=1 harness=cosim_harness.py

  {"op":"gemm_s8","m":M,"n":N,"k":K,"a":[i8...],"b":[i8...], "name":"..."}
      optional "c_expect":[i32...] — if present, mismatch exits non-zero
      -> stdout: status=0 c_hex=<little-endian i32 bytes as hex> name=...

  {"op":"suite"}
      -> dual oracle: pure-Python ref goldens (+ cargo golden-check if cargo present)
      -> stdout: suite_ok count=N

  {"op":"rtl_smoke"}  (or any job with AI_TENSOR_RUN_RTL=1)
      -> soft probe for monorepo Variane/AI soak scripts; never required for CI
      -> stdout: rtl_smoke=skip|ok reason=...

Env:
  AI_TENSOR_DIR     package root (default: parent of tools/)
  AI_TENSOR_RUN_RTL=1  enable optional monorepo RTL probe on suite/rtl_smoke
  AI_TENSOR_MONOREPO   override monorepo root for RTL probe
"""
from __future__ import annotations

import json
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(os.environ.get("AI_TENSOR_DIR", Path(__file__).resolve().parents[1]))

# Keep in lockstep with crates/ai-tensor-rt/src/cosim.rs builtin_goldens + auto-tile note.
BUILTIN = [
    {
        "name": "2x2_manual",
        "m": 2,
        "n": 2,
        "k": 2,
        "a": [1, 2, 3, 4],
        "b": [5, 6, 7, 8],
        "c": [19, 22, 43, 50],
    },
    {
        "name": "1x1",
        "m": 1,
        "n": 1,
        "k": 1,
        "a": [7],
        "b": [-3],
        "c": [-21],
    },
    {
        "name": "3x2x4_ones",
        "m": 3,
        "n": 2,
        "k": 4,
        "a": [1] * 12,
        "b": [1] * 8,
        "c": [4, 4, 4, 4, 4, 4],
    },
    {
        "name": "2x3x2_mixed",
        "m": 2,
        "n": 3,
        "k": 2,
        "a": [1, -1, 2, 0],
        "b": [3, 4, 5, -2, 1, 0],
        "c": [5, 3, 5, 6, 8, 10],
    },
]


def log(msg: str) -> None:
    print(f"[cosim_harness] {msg}", file=sys.stderr)


def gemm_s8(m: int, n: int, k: int, a: list[int], b: list[int]) -> list[int]:
    """Row-major INT8×INT8 → i32 reference (same contract as sim compute_ref)."""
    if len(a) < m * k or len(b) < k * n:
        raise ValueError(f"buffer sizes a={len(a)} b={len(b)} need m*k={m*k} k*n={k*n}")
    c = [0] * (m * n)
    for i in range(m):
        for j in range(n):
            acc = 0
            for t in range(k):
                acc += int(a[i * k + t]) * int(b[t * n + j])
            c[i * n + j] = acc
    return c


def c_to_hex(c: list[int]) -> str:
    return "".join(struct.pack("<i", int(x)).hex() for x in c)


def handle_ping(_job: dict) -> int:
    print("pong ok=1 harness=cosim_harness.py")
    return 0


def handle_gemm(job: dict) -> int:
    m = int(job["m"])
    n = int(job["n"])
    k = int(job["k"])
    name = str(job.get("name", "gemm"))
    a = [int(x) for x in job["a"]]
    b = [int(x) for x in job["b"]]
    got = gemm_s8(m, n, k, a, b)
    exp = job.get("c_expect") or job.get("c")
    if exp is not None:
        exp_i = [int(x) for x in exp]
        if got != exp_i:
            print(f"status=1 name={name} mismatch got={got} exp={exp_i}", file=sys.stderr)
            print(f"status=1 c_hex={c_to_hex(got)} name={name}")
            return 1
    print(f"status=0 c_hex={c_to_hex(got)} name={name}")
    return 0


def handle_suite(_job: dict) -> int:
    n_ok = 0
    for g in BUILTIN:
        got = gemm_s8(g["m"], g["n"], g["k"], g["a"], g["b"])
        if got != g["c"]:
            log(f"FAIL {g['name']}: got={got} exp={g['c']}")
            print(f"suite_fail name={g['name']}")
            return 1
        n_ok += 1
    # Prefer cargo dual-oracle (sim + SoftIsland) when available.
    cargo = shutil.which("cargo")
    if cargo:
        log("cargo golden-check (sim+SoftIsland dual oracle)")
        # Avoid re-entry: clear AI_TENSOR_COSIM_CMD for nested golden-check.
        env = os.environ.copy()
        env.pop("AI_TENSOR_COSIM_CMD", None)
        r = subprocess.run(
            [cargo, "run", "-q", "-p", "ai-tensor-cli", "--", "golden-check"],
            cwd=str(ROOT),
            env=env,
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            log(r.stdout)
            log(r.stderr)
            print(f"suite_fail cargo_rc={r.returncode}")
            return 1
        for line in (r.stdout or "").splitlines():
            if line.strip():
                log(line.strip())
    else:
        log("cargo missing — pure-Python oracle only")
    if os.environ.get("AI_TENSOR_RUN_RTL", "").strip() in ("1", "true", "yes"):
        rtl_rc = rtl_smoke_probe()
        if rtl_rc != 0:
            print(f"suite_ok count={n_ok} rtl_smoke=fail")
            return rtl_rc
        print(f"suite_ok count={n_ok} rtl_smoke=probed")
    else:
        print(f"suite_ok count={n_ok}")
    return 0


def monorepo_root() -> Path | None:
    if env := os.environ.get("AI_TENSOR_MONOREPO"):
        p = Path(env)
        return p if p.is_dir() else None
    # package may sit as monorepo/ai-tensor
    cand = ROOT.parent
    markers = (
        cand / "monorepo-soak" / "run-ai-tensor.sh",
        cand / "corev_apu" / "ai_island",
        cand / "architecture" / "ai-matrix",
    )
    if any(m.exists() for m in markers):
        return cand
    return None


def rtl_smoke_probe() -> int:
    """Soft probe only — never rebuilds Verilator unless a known smoke script is opted-in."""
    mono = monorepo_root()
    if mono is None:
        print("rtl_smoke=skip reason=no_monorepo")
        return 0
    island = mono / "corev_apu" / "ai_island" / "README.md"
    spawn = mono / "monorepo-soak" / "run-ai-tensor.sh"
    trail = mono / "monorepo-soak" / "run-trail-suite.sh"
    parts = [
        f"monorepo={mono}",
        f"island_readme={'ok' if island.is_file() else 'missing'}",
        f"spawn={'ok' if spawn.is_file() else 'missing'}",
        f"trail_suite={'ok' if trail.is_file() else 'missing'}",
    ]
    # Optional hard smoke: only if AI_TENSOR_RTL_CMD is set (user owns long TB rebuilds).
    rtl_cmd = os.environ.get("AI_TENSOR_RTL_CMD", "").strip()
    if rtl_cmd:
        log(f"AI_TENSOR_RTL_CMD={rtl_cmd!r}")
        r = subprocess.run(["sh", "-c", rtl_cmd], cwd=str(mono))
        if r.returncode != 0:
            print("rtl_smoke=fail " + " ".join(parts))
            return r.returncode
        print("rtl_smoke=ok " + " ".join(parts))
        return 0
    print("rtl_smoke=skip reason=no_AI_TENSOR_RTL_CMD " + " ".join(parts))
    return 0


def handle_rtl_smoke(_job: dict) -> int:
    return rtl_smoke_probe()


def main() -> int:
    raw = sys.stdin.read().strip()
    if not raw:
        # No stdin → treat as suite (handy for `python tools/cosim_harness.py`)
        job: dict = {"op": "suite"}
    else:
        try:
            job = json.loads(raw)
        except json.JSONDecodeError as e:
            print(f"bad_json: {e}", file=sys.stderr)
            return 2
    if not isinstance(job, dict):
        print("bad_job: need JSON object", file=sys.stderr)
        return 2

    if job.get("ping") is True or job.get("op") == "ping":
        return handle_ping(job)
    op = str(job.get("op", "")).lower()
    if op in ("suite", "golden", "goldens"):
        return handle_suite(job)
    if op in ("rtl_smoke", "rtl"):
        return handle_rtl_smoke(job)
    if op in ("gemm_s8", "gemm", "") and ("m" in job and "a" in job and "b" in job):
        return handle_gemm(job)
    if op == "gemm_s8" or op == "gemm":
        print("gemm needs m,n,k,a,b", file=sys.stderr)
        return 2
    # Default: unknown with ping-like keys already handled
    print(f"unknown_op={op or job}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
