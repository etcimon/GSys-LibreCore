# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
PyTorch module-level offload for the AI island: ``nn.Linear`` -> island GEMM.

This is the first framework surface that runs a *model's* own layers through the
device path instead of copying tensors into a standalone helper:

* ``AiTensorLinear`` wraps an existing ``nn.Linear``. The weight ``[out, in]`` is
  already the island's native k-major ``B[n][k]`` layout, so it is packed **once** at
  construction (prepacked weights), never per call.
* Every forward flattens the activations to ``[M, K]``, splits M/N/K into AccTile
  blocks, submits each block with ``Device.gemm_native`` and reassembles the result.
  Integer blocks accumulate exactly across K; float formats keep the island's ordered
  FP32 reduction and therefore refuse a K-split (that is a contract, not a limitation
  to paper over).
* Anything the island cannot execute falls back to ``torch`` **explicitly**: the
  fallback is counted and the reason recorded in ``OffloadStats``. A silent fallback
  would make "the model ran on the island" unfalsifiable.
* ``replace_linear`` swaps the ``nn.Linear`` modules of a whole model (Transformers,
  Diffusers or plain ``nn.Module``) and returns the swap report.

Evidence boundary: with the ``sim`` / ``software-reference-v2`` / ``mmio`` backends
this is **virtual** execution of the published descriptor contract. Only the
``qemu-uio`` backend against a real island produces hardware evidence, and even then
the numbers are those of that island's geometry, not of any silicon.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Tuple

from .c_abi import AI_FMT_FP8_E4M3, AI_FMT_FP8_E5M2, AI_FMT_INT, NUMFMT_NAMES, numfmt_of_dtype
from .device import Caps, Device
from .numfmt import FP8_GEOMETRY, encode_fp8

try:
    import torch
    from torch import nn
except ImportError as e:  # pragma: no cover
    raise ImportError("ai_tensor.torch_backend requires PyTorch") from e


# ----------------------------------------------------------------------------- bytes


def _tensor_bytes(t: "torch.Tensor") -> bytes:
    """Little-endian element bytes of a contiguous CPU tensor (no per-element Python)."""
    t = t.detach().contiguous().cpu()
    flat = t.view(torch.uint8).reshape(-1)
    try:
        return flat.numpy().tobytes()
    except (RuntimeError, ImportError):  # numpy unavailable
        return bytes(flat.tolist())


def _bytes_tensor(raw: bytes, dtype: "torch.dtype", shape: Tuple[int, ...]) -> "torch.Tensor":
    return torch.frombuffer(bytearray(raw), dtype=dtype).clone().reshape(shape)


# ---------------------------------------------------------------------------- policy


@dataclass
class OffloadStats:
    """What actually ran where. Read this before believing any offload claim."""

    offloaded_calls: int = 0
    offloaded_blocks: int = 0
    fallback_calls: int = 0
    fallback_reasons: Dict[str, int] = field(default_factory=dict)

    def fallback(self, reason: str) -> None:
        self.fallback_calls += 1
        self.fallback_reasons[reason] = self.fallback_reasons.get(reason, 0) + 1

    def as_dict(self) -> Dict[str, object]:
        return {
            "offloaded_calls": self.offloaded_calls,
            "offloaded_blocks": self.offloaded_blocks,
            "fallback_calls": self.fallback_calls,
            "fallback_reasons": dict(self.fallback_reasons),
        }


def _blocks(total: int, step: int) -> Iterable[Tuple[int, int]]:
    for start in range(0, total, step):
        yield start, min(step, total - start)


def _fmt_granted(numfmt: int, caps: Caps) -> bool:
    return bool(caps.dtype_mask & (1 << numfmt))


# ---------------------------------------------------------------------------- module


class AiTensorLinear(nn.Module):
    """``nn.Linear`` whose matmul runs on the island (see module docstring).

    ``quant``:
      * ``"none"``: operands in the layer's own float dtype (fp32/bf16/fp16 as granted).
      * ``"int8-dynamic"``: symmetric INT8 weights per (output channel, K group) at
        construction, symmetric INT8 activations per (row, K group) at call time, exact
        i32 accumulation on the island per K group, dequantized and summed in fp32.
        ``group_k`` (default 128, always <= AccTile K) is the K-group length; it is also
        the island K block, so the finer scales cost no extra device work beyond the
        K-split. This is a *quantization* of the layer: the result differs from the float
        layer by the quantization error and callers own the quality budget.
      * ``"fp8-e4m3"`` / ``"fp8-e5m2"``: the same per-(row, K-group) / per-(channel,
        K-group) scheme with FP8 codes (scale maps the group max onto the format's
        largest finite value; round-to-nearest-even; saturating). The island multiplies
        the raw FP8 pairs and accumulates in f32 per K group; the host applies the two
        group scales and sums the groups in f32. One byte per element like INT8, but a
        floating point range inside the group.
      * ``"bf16"`` / ``"fp16"``: weights cast once to that format, activations cast per
        call, island BF16/FP16 multiply with the ordered FP32 accumulation (K-chained
        through accmode 01 when K exceeds the tile). Two bytes per element, no scales: a
        *precision* recipe rather than a quantization one.
    """

    QUANT_MODES = ("none", "int8-dynamic", "fp8-e4m3", "fp8-e5m2", "bf16", "fp16")
    _CAST_MODES = {"bf16": torch.bfloat16, "fp16": torch.float16}
    _QUANT_FMT = {"int8-dynamic": AI_FMT_INT, "fp8-e4m3": AI_FMT_FP8_E4M3, "fp8-e5m2": AI_FMT_FP8_E5M2}

    def __init__(
        self,
        linear: nn.Linear,
        device: Device,
        *,
        quant: str = "none",
        allow_fallback: bool = True,
        stats: Optional[OffloadStats] = None,
        group_k: int = 128,
    ):
        super().__init__()
        if quant not in self.QUANT_MODES:
            raise ValueError(f"unknown quant mode {quant!r}")
        if group_k <= 0:
            raise ValueError("group_k must be positive")
        self.in_features = linear.in_features
        self.out_features = linear.out_features
        self.device_ = device
        self.caps: Caps = device.caps()
        self.quant = quant
        self.allow_fallback = allow_fallback
        self.stats = stats if stats is not None else OffloadStats()
        self.bias = None if linear.bias is None else nn.Parameter(linear.bias.detach().clone(), requires_grad=False)
        # Kept for the explicit fallback path only; not used when the island executes.
        self.weight = nn.Parameter(linear.weight.detach().clone(), requires_grad=False)
        self.compute_dtype = linear.weight.dtype

        w = linear.weight.detach().cpu()
        if quant in self._CAST_MODES:
            w = w.to(self._CAST_MODES[quant])
            self.compute_dtype = w.dtype
        # K block for one island job. Parts that publish operand bank bytes (flat panel
        # mapping) take the whole row while the m x n panels fit the banks -- one job and
        # one resident key for a 256 x 1024 INT8 weight panel; legacy parts box at AccTileK.
        self.k_block = self._k_block(w)
        self.group_k = min(group_k, self.k_block)
        if quant != "none" and quant not in self._CAST_MODES:
            # Per-(channel, K-group) scales: quantize each K group of each row alone.
            self.numfmt = self._QUANT_FMT[quant]
            q, self.w_scale = self._quantize_groups(w.to(torch.float32))
            self._w_i8 = q
            self._w_bytes = _tensor_bytes(q)
        else:
            self.numfmt = numfmt_of_dtype(w.dtype)
            self.w_scale = None
            self._w_i8 = None
            self._w_bytes = _tensor_bytes(w)
        self._row_bytes = self.in_features * (1 if self._w_i8 is not None else w.element_size())
        self._w_elem_bytes = 1 if self._w_i8 is not None else w.element_size()
        self._w_cast = w if quant in self._CAST_MODES else None

    def _k_block(self, w: "torch.Tensor") -> int:
        caps = self.caps
        if not caps.flat_panels:
            return caps.acc_tile_k
        elem_bytes = 1 if self.quant not in ("none", *self._CAST_MODES) else w.element_size()
        n_tile = min(self.out_features, caps.acc_tile_n)
        # M is the activation row count, unknown until forward; the B bank (weights) is
        # the binding one for GEMV/decode and A rows are boxed by AccTileM, so size the
        # block for a full AccTileM x n_tile panel pair.
        k = caps.max_k(caps.acc_tile_m, n_tile, elem_bytes)
        return max(1, min(k, self.in_features)) if k else caps.acc_tile_k

    def _quantize_groups(self, x32: "torch.Tensor"):
        """Per-(row, K-group) symmetric quantization of ``x32[rows, K]`` into the layer's
        code format. Returns ``(codes[rows, K] (int8 or uint8), scales[rows, groups] f32)``."""
        rows, k = x32.shape
        if self.numfmt == AI_FMT_INT:
            qmax, dtype = 127.0, torch.int8
        else:
            qmax, dtype = FP8_GEOMETRY[self.numfmt][4], torch.uint8
        codes = torch.empty((rows, k), dtype=dtype)
        scales = []
        for t0, tk in _blocks(k, self.group_k):
            blk = x32[:, t0:t0 + tk]
            sc = blk.abs().amax(dim=1).clamp_min(1e-12) / qmax
            scaled = blk / sc[:, None]
            if self.numfmt == AI_FMT_INT:
                codes[:, t0:t0 + tk] = torch.round(scaled).clamp(-127, 127).to(torch.int8)
            else:
                codes[:, t0:t0 + tk] = torch.from_numpy(
                    encode_fp8(scaled.numpy(), self.numfmt).reshape(rows, tk).copy())
            scales.append(sc)
        return codes, torch.stack(scales, dim=1)

    # -- helpers ---------------------------------------------------------------

    def _refusal(self, m: int) -> Optional[str]:
        caps = self.caps
        if not _fmt_granted(self.numfmt, caps):
            return f"numfmt {NUMFMT_NAMES[self.numfmt]} not granted by dtype_mask {caps.dtype_mask:#x}"
        if self.in_features > self.k_block and self.numfmt >= 2 and not caps.accumulate:
            return ("K exceeds AccTile; ordered FP K-splitting needs the accumulate grant "
                    "(CAP_ACCMODE), which this device does not publish")
        return None

    def _b_block(self, j0: int, tn: int, t0: int, tk: int) -> bytes:
        # Native B is k-major: row j holds K contiguous elements. A [tn x tk] block is
        # tn row slices; when tk == K the rows are contiguous and no copy is needed.
        if t0 == 0 and tk == self.in_features:
            return self._w_bytes[j0 * self._row_bytes:(j0 + tn) * self._row_bytes]
        src = self._w_i8 if self._w_i8 is not None else (
            self._w_cast if self._w_cast is not None else self.weight.detach().cpu())
        return _tensor_bytes(src[j0:j0 + tn, t0:t0 + tk])

    def _island_matmul(self, a2: "torch.Tensor", a_scale: Optional["torch.Tensor"] = None) -> "torch.Tensor":
        """``a2[M,K] @ W^T`` on the island, block by block.

        Float formats return f32 ``[M,N]`` from one K block. INT8 runs one island block per
        K group and, given ``a_scale[M, groups]``, dequantizes each i32 block with its own
        activation/weight group scales before the fp32 sum (returns f32); without scales it
        returns the exact i32 sum.
        """
        caps = self.caps
        m, k = a2.shape
        n = self.out_features
        integer = self.numfmt < 2
        grouped = a_scale is not None
        out_dtype = torch.float32 if (grouped or not integer) else torch.int32
        out = torch.zeros((m, n), dtype=out_dtype)
        # Ungrouped float K blocks chain through accmode 01: the device seeds each block's
        # ordered reduction from the previous block's C, so the result equals one long
        # ordered reduction bit for bit (no host-side float re-summation). Grouped
        # (quantized) layers run one block per K group and dequantize each on the host.
        # Ungrouped float jobs take the largest K the banks admit for THIS m (decode m=1
        # is bound by the B bank alone); grouped jobs are one job per K group.
        k_block = self.k_block
        if not (integer or grouped) and caps.flat_panels:
            k_block = caps.max_k(min(m, caps.acc_tile_m), min(n, caps.acc_tile_n), self._w_elem_bytes) or k_block
        k_steps = list(_blocks(k, self.group_k if (integer or grouped) else k_block))
        ticket = 1
        for i0, tm in _blocks(m, caps.acc_tile_m):
            for j0, tn in _blocks(n, caps.acc_tile_n):
                acc = None
                seed = None
                for g, (t0, tk) in enumerate(k_steps):
                    a_blk = _tensor_bytes(a2[i0:i0 + tm, t0:t0 + tk])
                    b_blk = self._b_block(j0, tn, t0, tk)
                    raw = self.device_.gemm_native(a_blk, b_blk, tm, tn, tk, self.numfmt, ticket=ticket,
                                                   c_init=seed)
                    ticket = (ticket + 1) & 0x7FFFFF or 1
                    self.stats.offloaded_blocks += 1
                    if not integer and not grouped:
                        seed = raw  # next float block accumulates onto this C
                        acc = _bytes_tensor(raw, torch.float32, (tm, tn))
                        continue
                    blk = _bytes_tensor(raw, torch.int32 if integer else torch.float32, (tm, tn))
                    if grouped:
                        blk = blk.to(torch.float32) * a_scale[i0:i0 + tm, g][:, None] * self.w_scale[j0:j0 + tn, g][None, :]
                    acc = blk if acc is None else acc + blk
                out[i0:i0 + tm, j0:j0 + tn] = acc
        return out

    # -- forward ---------------------------------------------------------------

    def forward(self, x: "torch.Tensor") -> "torch.Tensor":
        lead = x.shape[:-1]
        a2 = x.reshape(-1, self.in_features)
        reason = self._refusal(a2.shape[0])
        if self.quant in self._CAST_MODES:
            a2 = a2.to(self.compute_dtype)
        if reason is None and self.quant in ("none", *self._CAST_MODES) and a2.dtype != self.compute_dtype:
            reason = f"activation dtype {a2.dtype} differs from the prepacked weight dtype {self.compute_dtype}"
        if reason is not None:
            if not self.allow_fallback:
                raise RuntimeError(f"island refused: {reason}")
            self.stats.fallback(reason)
            return nn.functional.linear(x, self.weight, self.bias)

        if self.quant != "none" and self.quant not in self._CAST_MODES:
            a_codes, a_scale = self._quantize_groups(a2.detach().to(torch.float32).cpu())
            y = self._island_matmul(a_codes, a_scale).to(x.dtype)
        else:
            y = self._island_matmul(a2.detach().cpu())
            y = y.to(x.dtype)
        if self.bias is not None:
            y = y + self.bias.to(y.dtype)
        self.stats.offloaded_calls += 1
        return y.reshape(*lead, self.out_features)

    def weight_bytes(self) -> int:
        """Bytes of B the island reads for one full pass of this layer (the B-load-bound
        quantity of the live geometry), excluding scales."""
        return len(self._w_bytes)

    def extra_repr(self) -> str:
        return (f"in_features={self.in_features}, out_features={self.out_features}, "
                f"numfmt={NUMFMT_NAMES[self.numfmt]}, quant={self.quant}, backend={self.device_.backend}")


class AiTensorConv2d(nn.Module):
    """``nn.Conv2d`` (groups=1) lowered to an island GEMM through im2col.

    The kernel ``[out, in, kh, kw]`` flattens to native ``B[n=out][k=in*kh*kw]``, so it
    reuses ``AiTensorLinear`` unchanged (prepacked once). Activations go through
    ``F.unfold`` to ``[batch*positions, k]``. Grouped convolutions fall back explicitly.
    """

    def __init__(self, conv: nn.Conv2d, device: Device, *, quant: str = "none",
                 allow_fallback: bool = True, stats: Optional[OffloadStats] = None, group_k: int = 128):
        super().__init__()
        self.conv_ref = conv  # explicit fallback path
        self.kernel_size = conv.kernel_size
        self.stride, self.padding, self.dilation, self.groups = conv.stride, conv.padding, conv.dilation, conv.groups
        lin = nn.Linear(conv.in_channels // conv.groups * conv.kernel_size[0] * conv.kernel_size[1],
                        conv.out_channels, bias=conv.bias is not None, dtype=conv.weight.dtype)
        with torch.no_grad():
            lin.weight.copy_(conv.weight.reshape(conv.out_channels, -1))
            if conv.bias is not None:
                lin.bias.copy_(conv.bias)
        self.linear = AiTensorLinear(lin, device, quant=quant, allow_fallback=allow_fallback, stats=stats,
                                     group_k=group_k)
        self.stats = self.linear.stats

    def forward(self, x: "torch.Tensor") -> "torch.Tensor":
        if self.groups != 1 or isinstance(self.padding, str):
            if not self.linear.allow_fallback:
                raise RuntimeError("island refused: grouped or string-padded conv2d")
            self.stats.fallback("grouped or string-padded conv2d")
            return self.conv_ref(x)
        b, _, h, w = x.shape
        cols = nn.functional.unfold(x, self.kernel_size, dilation=self.dilation,
                                    padding=self.padding, stride=self.stride)  # [b, k, L]
        L = cols.shape[-1]
        a2 = cols.transpose(1, 2).reshape(b * L, -1)
        y = self.linear(a2).reshape(b, L, -1).transpose(1, 2)  # [b, out, L]
        oh = (h + 2 * self.padding[0] - self.dilation[0] * (self.kernel_size[0] - 1) - 1) // self.stride[0] + 1
        ow = (w + 2 * self.padding[1] - self.dilation[1] * (self.kernel_size[1] - 1) - 1) // self.stride[1] + 1
        return y.reshape(b, -1, oh, ow)


# ----------------------------------------------------------------------- model swap


def _as_linear(module: nn.Module) -> Optional[nn.Linear]:
    """View a linear-like module as ``nn.Linear`` (weight ``[out, in]``).

    Transformers' GPT-2 family uses ``Conv1D`` with a transposed ``[in, out]`` weight; it
    is the same GEMM with B pre-transposed, so it is folded here once rather than taught
    to the device path.
    """
    if isinstance(module, nn.Linear):
        return module
    if type(module).__name__ == "Conv1D" and hasattr(module, "nf") and module.weight.dim() == 2:
        w = module.weight.detach()
        lin = nn.Linear(w.shape[0], w.shape[1], bias=getattr(module, "bias", None) is not None, dtype=w.dtype)
        with torch.no_grad():
            lin.weight.copy_(w.t())
            if lin.bias is not None:
                lin.bias.copy_(module.bias.detach())
        return lin
    return None


@dataclass
class SwapReport:
    replaced: List[str]
    skipped: Dict[str, str]
    stats: OffloadStats

    def as_dict(self) -> Dict[str, object]:
        return {"replaced": list(self.replaced), "skipped": dict(self.skipped), "stats": self.stats.as_dict()}


def replace_linear(
    model: nn.Module,
    device: Device,
    *,
    quant: str = "none",
    allow_fallback: bool = True,
    min_in_features: int = 1,
    skip: Iterable[str] = (),
    conv2d: bool = False,
    group_k: int = 128,
) -> SwapReport:
    """Replace every ``nn.Linear`` (and, with ``conv2d=True``, every groups=1
    ``nn.Conv2d``) under ``model`` with its island module, in place.

    Modules whose dtype has no island format, or whose name is in ``skip``, are left
    alone and reported. All replaced layers share one ``OffloadStats`` so a model-level
    offload ratio can be read after inference.
    """
    stats = OffloadStats()
    replaced: List[str] = []
    skipped: Dict[str, str] = {}
    skip_set = set(skip)
    for name, module in list(model.named_modules()):
        for child_name, child in list(module.named_children()):
            full = f"{name}.{child_name}" if name else child_name
            is_conv = conv2d and isinstance(child, nn.Conv2d) and child.groups == 1
            if isinstance(child, (AiTensorLinear, AiTensorConv2d)):
                continue
            as_lin = None if is_conv else _as_linear(child)
            if not (as_lin is not None or is_conv):
                continue
            if full in skip_set:
                skipped[full] = "skipped by caller"
                continue
            src = child if is_conv else as_lin
            k_in = src.in_channels * src.kernel_size[0] * src.kernel_size[1] if is_conv else src.in_features
            if k_in < min_in_features:
                skipped[full] = f"in_features {k_in} < {min_in_features}"
                continue
            try:
                if quant == "none":
                    numfmt_of_dtype(src.weight.dtype)
            except ValueError as e:
                skipped[full] = str(e)
                continue
            cls = AiTensorConv2d if is_conv else AiTensorLinear
            setattr(module, child_name, cls(src, device, quant=quant, allow_fallback=allow_fallback, stats=stats,
                                            group_k=group_k))
            replaced.append(full)
    return SwapReport(replaced=replaced, skipped=skipped, stats=stats)


# ------------------------------------------------------------- torch custom operator

_OP_REGISTERED = False


def register_custom_op(device: Optional[Device] = None) -> bool:
    """Register ``torch.ops.ai_tensor.gemm(a, b_kmajor) -> Tensor`` when torch supports it.

    ``b_kmajor`` is ``[N, K]`` (the ``nn.Linear`` weight layout). Returns False on torch
    builds without ``torch.library.custom_op``; callers then use ``AiTensorLinear``.
    """
    global _OP_REGISTERED
    if _OP_REGISTERED:
        return True
    custom_op = getattr(getattr(torch, "library", None), "custom_op", None)
    if custom_op is None:
        return False
    dev = device or Device("sim")

    @custom_op("ai_tensor::gemm", mutates_args=())
    def gemm(a: torch.Tensor, b_kmajor: torch.Tensor) -> torch.Tensor:
        lin = nn.Linear(b_kmajor.shape[1], b_kmajor.shape[0], bias=False, dtype=b_kmajor.dtype)
        with torch.no_grad():
            lin.weight.copy_(b_kmajor)
        return AiTensorLinear(lin, dev, allow_fallback=False)(a)

    @gemm.register_fake
    def _(a: torch.Tensor, b_kmajor: torch.Tensor) -> torch.Tensor:
        return a.new_empty((*a.shape[:-1], b_kmajor.shape[0]))

    _OP_REGISTERED = True
    return True
