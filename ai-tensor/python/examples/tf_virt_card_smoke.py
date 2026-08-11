#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
TensorFlow smoke through virtual PCIe AI board (virt-ai-pcie / virt-card).

  cd ai-tensor
  PYTHONPATH=python:tools python python/examples/tf_virt_card_smoke.py
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
    p.add_argument("--tcp", action="store_true")
    p.add_argument("--virt-mode", default=None, choices=("auto", "local", "tcp"))
    args = p.parse_args()
    mode = "tcp" if args.tcp else (args.virt_mode or "auto")
    os.environ["AI_TENSOR_BOARD_ID"] = args.board
    os.environ["AI_TENSOR_BACKEND"] = "virt-card"

    try:
        import tensorflow as tf
    except ImportError:
        print("skip tf_virt_card_smoke (tensorflow not installed)")
        return 0

    from ai_tensor.device import Device
    from ai_tensor.tf_ops import check_close_to_tf, gemm_s8

    with Device.from_board(args.board, virt_mode=mode) as dev:
        a = tf.constant([[1, 2], [3, 4]], dtype=tf.int8)
        b = tf.constant([[5, 6], [7, 8]], dtype=tf.int8)
        c, meta = gemm_s8(a, b, device=dev, ticket=1)
        print(
            f"backend={meta.get('backend')} board={meta.get('board_id')} c=\n{c.numpy()}"
        )
        assert int(c[0, 0]) == 19
        rep = check_close_to_tf(a, b, device=dev)
        assert rep["match"], rep
    print("tf_virt_card_smoke: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
