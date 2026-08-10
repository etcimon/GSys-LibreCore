# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
High-level TensorFlow helpers for island-class INT8 GEMM (M6 first slice).

Uses ``ai_tensor.Device`` — same Desc64 path as PyTorch. Does **not** link
TF C++ custom ops yet; optional ``tensorflow`` import for tensor I/O only.
TF headers never enter Rust crates (KD0).
"""

from __future__ import annotations

from typing import Any, List, Optional, Sequence, Tuple, Union

from .device import Device

try:
    import tensorflow as tf  # type: ignore
except ImportError as e:  # pragma: no cover
    raise ImportError(
        "ai_tensor.tf_ops requires TensorFlow (pip install tensorflow) "
        "or use ai_tensor.Device / numpy path without this module"
    ) from e


def _to_int8_list(x: Any) -> Tuple[List[int], int, int]:
    """Return flat int8 list and (rows, cols) for a 2-D tensor/array."""
    t = tf.convert_to_tensor(x)
    if t.shape.rank != 2:
        raise ValueError("operands must be 2-D")
    t = tf.cast(t, tf.int8)
    m = int(t.shape[0])
    n = int(t.shape[1])
    flat = [int(v) for v in t.numpy().reshape(-1).tolist()]
    return flat, m, n


def gemm_s8(
    a: Any,
    b: Any,
    *,
    device: Optional[Device] = None,
    ticket: int = 1,
    auto_tile: bool = True,
    backend: str = "sim",
) -> Tuple[Any, dict]:
    """
    INT8 matmul: ``C[m,n] = A[m,k] @ B[k,n]`` with i32 accum.

    Returns ``(c_tf_int32, meta)``.
    """
    a8, m, k = _to_int8_list(a)
    b8, k2, n = _to_int8_list(b)
    if k != k2:
        raise ValueError(f"shape mismatch ({m},{k}) @ ({k2},{n})")

    dev = device or Device(backend)
    c_list, tix, status, meta = dev.gemm_s8(
        m, n, k, a8, b8, ticket=ticket, auto_tile=auto_tile
    )
    if status != 0:
        raise RuntimeError(f"ai-tensor gemm failed status={status}")

    c = tf.constant(c_list, dtype=tf.int32)
    c = tf.reshape(c, (m, n))
    meta = {
        **meta,
        "ticket": tix,
        "status": status,
        "backend": dev.backend,
        "framework": "tensorflow",
    }
    return c, meta


def check_close_to_tf(
    a: Any,
    b: Any,
    *,
    device: Optional[Device] = None,
    backend: str = "sim",
    auto_tile: bool = True,
) -> dict:
    """Compare island path to TF int32 matmul of int8 operands."""
    c_ait, meta = gemm_s8(
        a, b, device=device, backend=backend, auto_tile=auto_tile
    )
    a_i = tf.cast(tf.convert_to_tensor(a), tf.int32)
    b_i = tf.cast(tf.convert_to_tensor(b), tf.int32)
    c_ref = tf.matmul(a_i, b_i)
    diff = tf.abs(c_ait - c_ref)
    ok = bool(tf.reduce_all(tf.equal(c_ait, c_ref)).numpy())
    max_abs = int(tf.reduce_max(diff).numpy()) if int(tf.size(c_ait)) else 0
    return {"match": ok, "max_abs_diff": max_abs, **meta}


def gemm_s8_numpy(
    a: Sequence[Sequence[int]],
    b: Sequence[Sequence[int]],
    *,
    device: Optional[Device] = None,
    ticket: int = 1,
    auto_tile: bool = True,
    backend: str = "sim",
) -> Tuple[List[List[int]], dict]:
    """
    Framework-free 2-D list path (no TF import required by callers who
    import this function only after checking — prefer ``Device.gemm_s8``).
    """
    m = len(a)
    k = len(a[0]) if m else 0
    k2 = len(b)
    n = len(b[0]) if k2 else 0
    if k != k2:
        raise ValueError("inner dims mismatch")
    a_flat = [int(x) for row in a for x in row]
    b_flat = [int(x) for row in b for x in row]
    dev = device or Device(backend)
    c_list, tix, status, meta = dev.gemm_s8(
        m, n, k, a_flat, b_flat, ticket=ticket, auto_tile=auto_tile
    )
    if status != 0:
        raise RuntimeError(f"status={status}")
    c2d = [c_list[i * n : (i + 1) * n] for i in range(m)]
    return c2d, {**meta, "ticket": tix, "status": status}
