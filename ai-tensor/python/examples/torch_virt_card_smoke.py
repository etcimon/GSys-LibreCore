#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
PyTorch smoke through virtual PCIe AI board (virt-ai-pcie / virt-card).

  cd ai-tensor
  PYTHONPATH=python:tools python python/examples/torch_virt_card_smoke.py
  PYTHONPATH=python:tools python python/examples/torch_virt_card_smoke.py --tcp
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python"))
sys.path.insert(0, str(ROOT / "tools"))


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--board", default=os.environ.get("AI_TENSOR_BOARD_ID", "virt-ai-pcie"))
    p.add_argument("--tcp", action="store_true", help="force TCP CardAgent path")
    p.add_argument("--virt-mode", default=None, choices=("auto", "local", "tcp"))
    args = p.parse_args()
    mode = "tcp" if args.tcp else (args.virt_mode or "auto")
    os.environ["AI_TENSOR_BOARD_ID"] = args.board
    os.environ["AI_TENSOR_BACKEND"] = "virt-card"

    try:
        import torch
    except ImportError:
        print("skip torch_virt_card_smoke (torch not installed)")
        return 0

    from ai_tensor.device import Device
    from ai_tensor.torch_ops import check_close_to_torch, gemm_s8

    with Device.from_board(args.board, virt_mode=mode) as dev:
        torch.manual_seed(0)
        a = torch.randint(-8, 8, (8, 16), dtype=torch.int8)
        b = torch.randint(-8, 8, (16, 8), dtype=torch.int8)
        c, meta = gemm_s8(a, b, device=dev, ticket=42)
        print(
            f"backend={meta.get('backend')} board={meta.get('board_id')} "
            f"c.shape={tuple(c.shape)} tiles={meta.get('tiles')}"
        )
        rep = check_close_to_torch(a, b, device=dev)
        print(f"match_torch_mm={rep['match']} max_abs_diff={rep['max_abs_diff']}")
        if not rep["match"]:
            return 1
    print("torch_virt_card_smoke: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
