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
    recipe: Optional[str] = None,
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
    from .device import run_high_level_s8

    dev = device or Device(backend)
    c_list, meta = run_high_level_s8(
        dev,
        m,
        n,
        k,
        a8.reshape(-1).tolist(),
        b8.reshape(-1).tolist(),
        ticket=ticket,
        auto_tile=auto_tile,
        recipe=recipe,
    )
    c = np.asarray(c_list, dtype=np.int32).reshape(m, n)
    meta = {**meta, "framework": "numpy"}
    return c, meta


def gemm(a: ArrayLike, b: ArrayLike, *, device: Optional[Device] = None,
         backend: str = 'sim', ticket: int = 1) -> Tuple['np.ndarray', dict]:
    from .c_abi import numfmt_of_dtype
    import sys
    a, b = np.asarray(a), np.asarray(b)
    if a.ndim != 2 or b.ndim != 2 or a.shape[1] != b.shape[0]:
        raise ValueError('expected A[m,k] and B[k,n]')
    if a.dtype != b.dtype:
        raise ValueError('native GEMM requires matching operand dtypes')
    if sys.byteorder != 'little' or not a.dtype.isnative or not b.dtype.isnative:
        raise NotImplementedError('native NumPy byte views require little-endian operands')
    fmt = numfmt_of_dtype(a.dtype)
    m, k = a.shape
    n = b.shape[1]
    dev = device or Device(backend)
    raw = dev.gemm_native(np.ascontiguousarray(a).tobytes(), np.ascontiguousarray(b.T).tobytes(),
                          int(m), int(n), int(k), fmt, ticket=ticket)
    from .device import high_level_fields

    out = np.frombuffer(raw, dtype='<i4' if fmt < 2 else '<f4').copy().reshape(m, n)
    return out, {
        "backend": dev.backend,
        "numfmt": fmt,
        "status": 0,
        "ticket": ticket,
        "caps": dev.caps().as_dict(),
        **high_level_fields(dev.caps(), int(m), int(n), int(k), False, native=True),
    }


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
