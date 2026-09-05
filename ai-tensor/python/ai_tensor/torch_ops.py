# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
High-level PyTorch helpers for island-class INT8 GEMM.

Uses ``ai_tensor.Device`` (sim or mmio-soft). Auto-tiles when m/n/k exceed AccTile.
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
    auto_tile: bool = True,
    backend: str = "sim",
) -> Tuple["torch.Tensor", dict]:
    """
    INT8 matmul: ``C[m,n] = A[m,k] @ B[k,n]`` with i32 accum.

    Returns ``(c, meta)`` where meta includes ticket, status, backend, caps, pmu, tiles.
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

    dev = device or Device(backend)
    c_list, tix, status, meta = dev.gemm_s8(
        int(m),
        int(n),
        int(k),
        a_i.reshape(-1).tolist(),
        b_i.reshape(-1).tolist(),
        ticket=ticket,
        auto_tile=auto_tile,
    )
    if status != 0:
        raise RuntimeError(f"ai-tensor gemm failed status={status}")

    c = torch.tensor(c_list, dtype=torch.int32).reshape(m, n)
    meta = {
        **meta,
        "ticket": tix,
        "status": status,
        "backend": dev.backend,
    }
    return c, meta


def gemm(a: 'torch.Tensor', b: 'torch.Tensor', *, device: Optional[Device] = None,
         backend: str = 'sim', ticket: int = 1) -> Tuple['torch.Tensor', dict]:
    from .c_abi import numfmt_of_dtype
    import sys
    if sys.byteorder != 'little':
        raise NotImplementedError('native torch byte views require a little-endian host')
    if a.dim() != 2 or b.dim() != 2 or a.shape[1] != b.shape[0]:
        raise ValueError('expected A[m,k] and B[k,n]')
    if a.dtype != b.dtype:
        raise ValueError('native GEMM requires matching operand dtypes')
    fmt = numfmt_of_dtype(a.dtype)
    a_native = a.detach().cpu().contiguous()
    b_native = b.detach().cpu().transpose(0, 1).contiguous()
    a_bytes = bytes(a_native.view(torch.uint8).reshape(-1).tolist())
    b_bytes = bytes(b_native.view(torch.uint8).reshape(-1).tolist())
    m, k = a.shape
    n = b.shape[1]
    dev = device or Device(backend)
    raw = dev.gemm_native(a_bytes, b_bytes, int(m), int(n), int(k), fmt, ticket=ticket)
    dtype = torch.int32 if fmt < 2 else torch.float32
    out = torch.frombuffer(bytearray(raw), dtype=dtype).clone().reshape(m, n)
    return out, {'backend': dev.backend, 'numfmt': fmt, 'status': 0, 'ticket': ticket, 'caps': dev.caps().as_dict()}


def check_close_to_torch(
    a: "torch.Tensor",
    b: "torch.Tensor",
    *,
    device: Optional[Device] = None,
    backend: str = "sim",
    auto_tile: bool = True,
) -> dict:
    """Compare island path to torch int32 matmul of int8 operands."""
    c_ait, meta = gemm_s8(
        a, b, device=device, backend=backend, auto_tile=auto_tile
    )
    a_i = a.detach().to(dtype=torch.int8, device="cpu").to(torch.int32)
    b_i = b.detach().to(dtype=torch.int8, device="cpu").to(torch.int32)
    c_ref = a_i @ b_i
    ok = torch.equal(c_ait, c_ref)
    return {
        "match": bool(ok),
        "max_abs_diff": int((c_ait - c_ref).abs().max().item()) if c_ait.numel() else 0,
        **meta,
    }
