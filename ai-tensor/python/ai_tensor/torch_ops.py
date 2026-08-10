# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
High-level PyTorch helpers for island-class INT8 GEMM (sim backend).

Does **not** require a custom libtorch extension: uses ``ai_tensor.Device`` and
torch tensors on CPU. Suitable for validating ABI + reference compute before RTL GEMM.
"""

from __future__ import annotations

from typing import Optional, Tuple

from .device import Device

try:
    import torch
except ImportError as e:  # pragma: no cover
    raise ImportError("ai_tensor.torch_ops requires PyTorch") from e


def gemm_s8(
    a: "torch.Tensor",
    b: "torch.Tensor",
    *,
    device: Optional[Device] = None,
    ticket: int = 1,
) -> Tuple["torch.Tensor", dict]:
    """
    INT8 matmul via ai-tensor sim: ``C[m,n] = A[m,k] @ B[k,n]`` with i32 accum.

    Parameters
    ----------
    a, b:
        2-D CPU tensors. Converted to int8 (truncate) if needed.
    ticket:
        Software ticket written into the completion word / poll path.

    Returns
    -------
    c:
        int32 tensor ``[m, n]``
    meta:
        ``ticket``, ``status``, ``backend``
    """
    if a.dim() != 2 or b.dim() != 2:
        raise ValueError("a and b must be 2-D")
    if a.shape[1] != b.shape[0]:
        raise ValueError(f"shape mismatch {tuple(a.shape)} @ {tuple(b.shape)}")

    a_i = a.detach().to(dtype=torch.int8, device="cpu").contiguous()
    b_i = b.detach().to(dtype=torch.int8, device="cpu").contiguous()
    m, k = a_i.shape
    k2, n = b_i.shape
    assert k == k2

    dev = device or Device("sim")
    c_list, tix, status = dev.gemm_s8(
        int(m),
        int(n),
        int(k),
        a_i.reshape(-1).tolist(),
        b_i.reshape(-1).tolist(),
        ticket=ticket,
    )
    if status != 0:
        raise RuntimeError(f"ai-tensor gemm failed status={status}")

    c = torch.tensor(c_list, dtype=torch.int32).reshape(m, n)
    meta = {"ticket": tix, "status": status, "backend": dev.backend}
    return c, meta


def check_close_to_torch(
    a: "torch.Tensor",
    b: "torch.Tensor",
    *,
    device: Optional[Device] = None,
) -> dict:
    """Compare sim island path to torch int32 matmul of int8 operands."""
    c_ait, meta = gemm_s8(a, b, device=device)
    a_i = a.detach().to(dtype=torch.int8, device="cpu").to(torch.int32)
    b_i = b.detach().to(dtype=torch.int8, device="cpu").to(torch.int32)
    c_ref = a_i @ b_i
    ok = torch.equal(c_ait, c_ref)
    return {
        "match": bool(ok),
        "max_abs_diff": int((c_ait - c_ref).abs().max().item()) if c_ait.numel() else 0,
        **meta,
    }
