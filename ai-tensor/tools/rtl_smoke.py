#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
Package-local RTL smoke entry for AI_TENSOR_RTL_CMD.

Discovers monorepo (parent of ai-tensor or AI_TENSOR_MONOREPO) and runs
monorepo-soak/run-ai-tensor-rtl.sh. Soft by default; hard when AI_TENSOR_RTL_HARD=1.
Never imports monorepo crates.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(os.environ.get("AI_TENSOR_DIR", Path(__file__).resolve().parents[1]))


def monorepo() -> Path | None:
    if env := os.environ.get("AI_TENSOR_MONOREPO"):
        p = Path(env)
        return p if p.is_dir() else None
    cand = ROOT.parent
    if (cand / "monorepo-soak" / "run-ai-tensor-rtl.sh").is_file():
        return cand
    if (cand / "verif" / "regress" / "ai-matrix-veri.sh").is_file():
        return cand
    return None


def main() -> int:
    mono = monorepo()
    if mono is None:
        print("rtl_smoke=skip reason=no_monorepo")
        return 0
    script = mono / "monorepo-soak" / "run-ai-tensor-rtl.sh"
    if not script.is_file():
        print(f"rtl_smoke=skip reason=no_script monorepo={mono}")
        return 0
    env = os.environ.copy()
    env["AI_TENSOR_MONOREPO"] = str(mono)
    env["AI_TENSOR_DIR"] = str(ROOT)
    print(f"[rtl_smoke] + bash {script}", file=sys.stderr)
    r = subprocess.run(["bash", str(script)], cwd=str(mono), env=env)
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
