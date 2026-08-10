#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
High-level PyTorch smoke against ai-tensor **sim** (island ABI + ref compute).

  cd ai-tensor
  PYTHONPATH=python python python/examples/torch_island_smoke.py

Optional: build native sim for parity with Rust:
  cargo build -p ai-tensor-py --release
  # then put target/release on PYTHONPATH / copy .so next to package
"""

from __future__ import annotations

import sys
from pathlib import Path

# Allow running from repo without install
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

import torch
from ai_tensor.torch_ops import check_close_to_torch, gemm_s8


def main() -> None:
    torch.manual_seed(0)
    m, n, k = 8, 8, 16
    a = torch.randint(-8, 8, (m, k), dtype=torch.int8)
    b = torch.randint(-8, 8, (k, n), dtype=torch.int8)

    c, meta = gemm_s8(a, b, ticket=42)
    print(f"backend={meta['backend']} ticket={meta['ticket']} status={meta['status']}")
    print(f"c shape={tuple(c.shape)} c[0,:4]={c[0, :4].tolist()}")

    rep = check_close_to_torch(a, b)
    print(f"match_torch_mm={rep['match']} max_abs_diff={rep['max_abs_diff']}")
    if not rep["match"]:
        sys.exit(1)
    print("torch_island_smoke: PASS")


if __name__ == "__main__":
    main()
