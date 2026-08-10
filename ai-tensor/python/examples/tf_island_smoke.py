#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Optional TensorFlow smoke (skip if tensorflow not installed)."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python"))

try:
    import tensorflow as tf  # noqa: F401
except ImportError:
    print("skip tf_island_smoke (tensorflow not installed)")
    sys.exit(0)

from ai_tensor.tf_ops import check_close_to_tf, gemm_s8


def main() -> None:
    a = tf.constant([[1, 2], [3, 4]], dtype=tf.int8)
    b = tf.constant([[5, 6], [7, 8]], dtype=tf.int8)
    c, meta = gemm_s8(a, b, ticket=1)
    print(f"backend={meta.get('backend')} c=\n{c.numpy()} meta_tiles={meta.get('tiles')}")
    assert c.shape == (2, 2)
    assert int(c[0, 0]) == 19
    r = check_close_to_tf(a, b)
    assert r["match"], r
    print("tf_island_smoke: ok")


if __name__ == "__main__":
    main()
