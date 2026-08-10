# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
NumPy-first GEMM helpers (framework-free). Same Device / Desc64 path as torch/tf.

Requires optional ``numpy``. Without numpy, use ``Device.gemm_s8`` with lists.
"""

from __future__ import annotations

from typing import Any, Optional, Tuple, Union

from .device import Device

try:
    import numpy as np
except ImportError as e:  # pragma: no cover
    raise ImportError("ai_tensor.numpy_ops requires numpy") from e


ArrayLike = Union["np.ndarray", Any]


def gemm_s8(
    a: ArrayLike,
    b: ArrayLike,
    *,
    device: Optional[Device] = None,
    ticket: int = 1,
    auto_tile: bool = True,
    backend: str = "sim",
) -> Tuple["np.ndarray", dict]:
    """
    INT8 matmul via island stack: ``C = A @ B`` with int32 accum.

    ``a``, ``b`` are converted to int8 C-contiguous arrays.
    """
    a8 = np.asarray(a, dtype=np.int8)
    b8 = np.asarray(b, dtype=np.int8)
    if a8.ndim != 2 or b8.ndim != 2:
        raise ValueError("a and b must be 2-D")
    if a8.shape[1] != b8.shape[0]:
        raise ValueError(f"shape mismatch {a8.shape} @ {b8.shape}")
    m, k = int(a8.shape[0]), int(a8.shape[1])
    n = int(b8.shape[1])
    dev = device or Device(backend)
    c_list, tix, status, meta = dev.gemm_s8(
        m,
        n,
        k,
        a8.reshape(-1).tolist(),
        b8.reshape(-1).tolist(),
        ticket=ticket,
        auto_tile=auto_tile,
    )
    if status != 0:
        raise RuntimeError(f"ai-tensor gemm failed status={status}")
    c = np.asarray(c_list, dtype=np.int32).reshape(m, n)
    meta = {**meta, "ticket": tix, "status": status, "backend": dev.backend, "framework": "numpy"}
    return c, meta


def check_close_to_numpy(
    a: ArrayLike,
    b: ArrayLike,
    *,
    device: Optional[Device] = None,
    backend: str = "sim",
    auto_tile: bool = True,
) -> dict:
    """Compare island path to numpy int32 matmul of int8 operands."""
    c_ait, meta = gemm_s8(a, b, device=device, backend=backend, auto_tile=auto_tile)
    a_i = np.asarray(a, dtype=np.int8).astype(np.int32)
    b_i = np.asarray(b, dtype=np.int8).astype(np.int32)
    c_ref = a_i @ b_i
    ok = bool(np.array_equal(c_ait, c_ref))
    max_abs = int(np.max(np.abs(c_ait - c_ref))) if c_ait.size else 0
    return {"match": ok, "max_abs_diff": max_abs, **meta}
