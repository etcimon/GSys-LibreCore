#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""NumPy smoke (skip if numpy not installed)."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python"))

try:
    import numpy as np
except ImportError:
    print("skip numpy_island_smoke (numpy not installed)")
    sys.exit(0)

from ai_tensor.numpy_ops import check_close_to_numpy, gemm_s8


def main() -> None:
    a = np.array([[1, 2], [3, 4]], dtype=np.int8)
    b = np.array([[5, 6], [7, 8]], dtype=np.int8)
    c, meta = gemm_s8(a, b)
    print(f"backend={meta.get('backend')} c=\n{c} tiles={meta.get('tiles')}")
    assert c.shape == (2, 2)
    assert int(c[0, 0]) == 19
    r = check_close_to_numpy(a, b)
    assert r["match"], r
    print("numpy_island_smoke: ok")


if __name__ == "__main__":
    main()
