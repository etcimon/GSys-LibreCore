# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
End-to-end quality: does a recipe's per-tile error compound through a real network?

:mod:`ai_tensor.va_turbo` scores a recipe on **one matmul tile**.  That answers "how much
arithmetic error does this format cost on this operand pair", and it is the wrong unit for
the decision anyone actually makes.  A 9,000 ppm tile error is either irrelevant or fatal at
the output of a twelve-layer stack depending on whether the per-layer perturbations add
coherently, add in quadrature, or are squashed by the normalisations in between — and a
single-tile number cannot distinguish those three.

This module measures the composed quantity.  It builds a **transformer stack in pure torch**
(LayerNorm, fused QKV projection, scaled dot-product attention, output projection, GELU MLP,
residual adds, final norm + token-level logit head), runs it twice, and compares the
**outputs of the whole graph**:

* the **reference** run: every matmul is :func:`ai_tensor.va_turbo.emulate` with the exact
  ``native-fp32`` recipe (float64 accumulation of unmodified FP32 operands, rounded back to
  FP32 — the same accumulation convention :func:`ai_tensor.va_turbo.quality` uses on both
  sides of its comparison);
* the **candidate** run: every matmul is :func:`ai_tensor.va_turbo.emulate` with the chosen
  recipe.  Everything that the island does **not** accelerate — layer norm, softmax, GELU,
  the residual adds, the attention scale, the bias adds — stays in FP32 in both runs, because
  that is the real split: the island computes GEMMs, the host computes the rest.

.. warning::
   **The weights are random.**  There is no trained checkpoint on this host and none is
   downloaded (that would be a new dependency and a network fetch).  Weights come from a
   seeded Xavier/Glorot draw, and the inputs are seeded Gaussians.  Consequently every number
   this module produces is a measurement of **error propagation through a real architecture**,
   and is **NOT** a statement about the accuracy of any trained model.  Top-1 agreement here
   is agreement with the *random network's own* FP32 output, not classification accuracy; KL
   is between two runs of the same random network, not between a model and ground truth.  A
   real checkpoint is still required before any accuracy claim, and this measurement does not
   substitute for one.  It does answer the compounding question, which is architecture-shaped
   rather than checkpoint-shaped.

.. warning::
   Inherited from :mod:`ai_tensor.va_turbo`: **the island RTL has no approximate execution
   consumer.**  Every approximate recipe is ``hardware_execution="emulated-only"`` and every
   report here carries ``executable_on_hardware=False`` for it.  These are predictions of what
   the arithmetic would cost, not measurements of approximate hardware.

Independence (AGENTS.md §1 KD0): nothing here imports from the monorepo, and nothing here is
imported by :mod:`ai_tensor.va_turbo` — that module stays importable, and fully usable, with
this file absent.  ``torch`` is an optional import, as everywhere else in this package; with
no torch installed the module imports and every entry point raises a clear ImportError.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional, Sequence, Tuple

from . import va_turbo as vt
from .va_turbo import Quality, Recipe, get_recipe, score_against_reference

try:  # torch is optional here exactly as in va_turbo / torch_ops.
    import torch
    import torch.nn.functional as F
except ImportError:  # pragma: no cover - exercised by the no-torch CI leg
    torch = None  # type: ignore[assignment]
    F = None  # type: ignore[assignment]

HAVE_TORCH = torch is not None

__all__ = [
    "DEFAULT_DEPTHS",
    "DEFAULT_SWEEP_RECIPES",
    "HAVE_TORCH",
    "RANDOM_WEIGHT_CAVEAT",
    "DepthSweep",
    "GROWTH_LINEAR",
    "GROWTH_SUBLINEAR",
    "GROWTH_SUPERLINEAR",
    "GROWTH_UNDETERMINED",
    "NetConfig",
    "NetQuality",
    "NetReport",
    "NetRun",
    "depth_sweep",
    "evaluate",
    "reference_run",
    "render_depth_table",
    "run",
    "sweep_table",
]

#: One sentence that must travel with every reported number.  Repeated in the docstrings, in
#: ``NetReport.note``, in ``as_dict()`` output and in ``architecture/APPROXIMATION.md``.
RANDOM_WEIGHT_CAVEAT = (
    "RANDOM WEIGHTS (seeded Xavier init), not a trained checkpoint: this measures ERROR "
    "PROPAGATION THROUGH A REAL ARCHITECTURE, not model accuracy. Top-1 agreement is "
    "agreement with this same random network's FP32 output, not classification accuracy. A "
    "real checkpoint is required for an accuracy claim and none is available on this host."
)

#: The accumulation domain of both runs.  float64 is a PROXY for the RTL's exact 640-bit
#: integer block reduction — the same caveat ``va_turbo._emulate_f64`` and
#: ``verif/tb/ai_island/policy_approx.py`` carry.  It is used identically for the reference
#: and the candidate, so the difference between them is the recipe's own arithmetic error and
#: not accumulator noise.  :func:`run` accepts a plain-FP32 ``matmul`` override for callers who
#: want to measure the size of that proxy instead of assuming it.
ACCUMULATION_NOTE = (
    "both runs accumulate every matmul in float64 and round the result to float32 "
    "(va_turbo.emulate's convention); float64 accumulation is a proxy for the RTL's exact "
    "640-bit integer block reduction, applied identically to reference and candidate"
)

DEFAULT_DEPTHS: Tuple[int, ...] = (1, 2, 4, 8, 12)

#: The four recipes the compounding question is actually asked about.  Ordered by increasing
#: aggressiveness, which is the order the monotonicity test checks.
DEFAULT_SWEEP_RECIPES: Tuple[str, ...] = (
    "convert-fp16",
    "convert-int8",
    "convert-fp8-e4m3",
    "convert-int4",
)

GROWTH_SUBLINEAR = "sub-linear"
GROWTH_LINEAR = "linear"
GROWTH_SUPERLINEAR = "super-linear"
GROWTH_UNDETERMINED = "undetermined"

#: Width of the band around exponent 1.0 that is called "linear".  An exponent of 0.5 is what
#: independent per-layer perturbations adding in quadrature would give; 1.0 is coherent
#: accumulation.  The adjective is a convenience — the exponent is the result.
_LINEAR_BAND = 0.15


def _require_torch(what: str):
    if torch is None:  # pragma: no cover - exercised by the no-torch CI leg
        raise ImportError(
            f"ai_tensor.va_turbo_net.{what} requires PyTorch; va_turbo's cycle model, recipe "
            "catalog and ppm ladder do not"
        )
    return torch


# --------------------------------------------------------------------------- configuration


@dataclass(frozen=True)
class NetConfig:
    """Shape and seed of the measured network.  Frozen and hashable, so it keys the cache.

    Depth and width are parameters on purpose: the compounding question is a question about
    depth, and a fixed-size fixture cannot answer it.
    """

    depth: int = 12
    d_model: int = 64
    n_heads: int = 4
    d_ff: int = 256
    seq_len: int = 16
    batch: int = 4
    n_classes: int = 32
    seed: int = 1234
    #: When False the two attention matmuls (Q·Kᵀ and P·V) stay exact FP32 and only the four
    #: weight-matrix products per block are routed through the recipe.  That is what several
    #: real quantised inference stacks do, and the difference between the two settings is
    #: itself a result rather than a tuning knob.
    route_attention: bool = True
    #: LayerNorm epsilon.  FP32, host side, in both runs.
    eps: float = 1e-5

    def __post_init__(self) -> None:
        if self.depth < 1:
            raise ValueError(f"depth must be >= 1, got {self.depth}")
        for name in ("d_model", "n_heads", "d_ff", "seq_len", "batch", "n_classes"):
            if getattr(self, name) < 1:
                raise ValueError(f"{name} must be >= 1, got {getattr(self, name)}")
        if self.d_model % self.n_heads:
            raise ValueError(
                f"d_model {self.d_model} is not divisible by n_heads {self.n_heads}"
            )

    @property
    def d_head(self) -> int:
        return self.d_model // self.n_heads

    def at_depth(self, depth: int) -> "NetConfig":
        """The same network truncated to ``depth`` blocks.

        Block ``i``'s weights are derived from ``(seed, i)`` alone and the head from ``seed``
        alone, so this really is a *prefix*: the depth-``d`` network is the first ``d`` blocks
        of the depth-12 one, and the depth sweep therefore agrees with the per-layer capture
        by construction rather than by coincidence.  A test pins that.
        """
        return NetConfig(**{**self.__dict__, "depth": depth})

    def as_dict(self) -> dict:
        return dict(self.__dict__)


# ------------------------------------------------------------------------ weight synthesis
#
# Determinism is a requirement, so the seeding must not go through Python's `hash()` of a
# string (PYTHONHASHSEED randomises it per process).  FNV-1a over an explicit byte string is
# stable across processes, platforms and Python versions.

_FNV_OFFSET = 0xCBF29CE484222325
_FNV_PRIME = 0x100000001B3
_MASK64 = (1 << 64) - 1


def _derive_seed(seed: int, tag: str, index: int = 0) -> int:
    h = _FNV_OFFSET
    for byte in f"{seed}:{tag}:{index}".encode("utf-8"):
        h = ((h ^ byte) * _FNV_PRIME) & _MASK64
    return h >> 1  # torch wants a non-negative 63-bit seed


def _xavier(rows: int, cols: int, gen) -> "torch.Tensor":
    """Xavier/Glorot normal: std = sqrt(2 / (fan_in + fan_out)).

    A sane, standard scheme — and stated as such everywhere the numbers are reported, because
    a *scheme* is not a *checkpoint*.  What it buys is a network whose activations neither
    explode nor vanish through twelve blocks, so the error that does grow is the recipe's and
    not an initialisation pathology.
    """
    std = math.sqrt(2.0 / (rows + cols))
    return torch.randn(rows, cols, generator=gen, dtype=torch.float32) * std


@dataclass(frozen=True)
class _Block:
    ln1_g: "torch.Tensor"
    ln1_b: "torch.Tensor"
    w_qkv: "torch.Tensor"
    b_qkv: "torch.Tensor"
    w_o: "torch.Tensor"
    b_o: "torch.Tensor"
    ln2_g: "torch.Tensor"
    ln2_b: "torch.Tensor"
    w_1: "torch.Tensor"
    b_1: "torch.Tensor"
    w_2: "torch.Tensor"
    b_2: "torch.Tensor"


@dataclass(frozen=True)
class _Weights:
    blocks: Tuple[_Block, ...]
    ln_f_g: "torch.Tensor"
    ln_f_b: "torch.Tensor"
    w_head: "torch.Tensor"
    b_head: "torch.Tensor"
    x: "torch.Tensor"


def _block_weights(cfg: NetConfig, index: int) -> _Block:
    t = torch
    gen = t.Generator().manual_seed(_derive_seed(cfg.seed, "block", index))
    d, f = cfg.d_model, cfg.d_ff
    return _Block(
        ln1_g=t.ones(d, dtype=t.float32),
        ln1_b=t.zeros(d, dtype=t.float32),
        w_qkv=_xavier(d, 3 * d, gen),
        b_qkv=t.zeros(3 * d, dtype=t.float32),
        w_o=_xavier(d, d, gen),
        b_o=t.zeros(d, dtype=t.float32),
        ln2_g=t.ones(d, dtype=t.float32),
        ln2_b=t.zeros(d, dtype=t.float32),
        w_1=_xavier(d, f, gen),
        b_1=t.zeros(f, dtype=t.float32),
        w_2=_xavier(f, d, gen),
        b_2=t.zeros(d, dtype=t.float32),
    )


_WEIGHT_CACHE: Dict[Tuple, _Weights] = {}


def _weights(cfg: NetConfig) -> _Weights:
    """Weights + input for ``cfg``.  Cached, and *prefix-consistent* across depths."""
    _require_torch("weights")
    t = torch
    # Depth is deliberately excluded from the cache key's identity for the shared parts: the
    # per-block draw depends on the block index only, so two configs differing only in depth
    # share their first min(depth) blocks exactly.
    key = tuple(sorted(cfg.as_dict().items()))
    hit = _WEIGHT_CACHE.get(key)
    if hit is not None:
        return hit
    blocks = tuple(_block_weights(cfg, i) for i in range(cfg.depth))
    gen = t.Generator().manual_seed(_derive_seed(cfg.seed, "head"))
    w_head = _xavier(cfg.d_model, cfg.n_classes, gen)
    gen_x = t.Generator().manual_seed(_derive_seed(cfg.seed, "input"))
    x = t.randn(cfg.batch, cfg.seq_len, cfg.d_model, generator=gen_x, dtype=t.float32)
    w = _Weights(
        blocks=blocks,
        ln_f_g=t.ones(cfg.d_model, dtype=t.float32),
        ln_f_b=t.zeros(cfg.d_model, dtype=t.float32),
        w_head=w_head,
        b_head=t.zeros(cfg.n_classes, dtype=t.float32),
        x=x,
    )
    _WEIGHT_CACHE[key] = w
    return w


# ------------------------------------------------------------------------------ the network

#: A matmul: two 2-D FP32 tensors in, one 2-D FP32 tensor out.  Every GEMM in the network goes
#: through one of these and nothing else does.
MatMul = Callable[["torch.Tensor", "torch.Tensor"], "torch.Tensor"]


def _recipe_matmul(rec: Recipe) -> MatMul:
    return lambda a, b: vt.emulate(a, b, rec)


def _exact_matmul(a, b):
    """Exact FP32 matmul, float64-accumulated — what ``native-fp32`` emulation is."""
    return (a.to(torch.float64) @ b.to(torch.float64)).to(torch.float32)


def _mm2d(x, w, mm: MatMul):
    """``(..., K) @ (K, N)`` with the trailing dims flattened into one 2-D GEMM."""
    lead = x.shape[:-1]
    out = mm(x.reshape(-1, x.shape[-1]), w)
    return out.reshape(*lead, out.shape[-1])


def _bmm(x, y, mm: MatMul):
    """Batched ``(B, M, K) @ (B, K, N)``, one 2-D GEMM per batch element.

    The island's descriptor is a 2-D GEMM, so a batched attention product *is* a loop of
    GEMMs and emulating it as one would quietly change the quantisation granularity.  As
    written, an INT8 scale is per (batch, head) slice — favourable, and stated rather than
    hidden: a single global attention scale would score worse.
    """
    return torch.stack([mm(x[i], y[i]) for i in range(x.shape[0])], dim=0)


def _attention(h, blk: _Block, cfg: NetConfig, mm: MatMul):
    t = torch
    b, s, d = h.shape
    nh, dh = cfg.n_heads, cfg.d_head
    qkv = _mm2d(h, blk.w_qkv, mm) + blk.b_qkv          # routed GEMM, FP32 bias
    q, k, v = qkv.split(d, dim=-1)
    # (B, S, D) -> (B*H, S, Dh); contiguous because emulate() validates 2-D contiguous slices.
    shape = (b, s, nh, dh)
    q = q.reshape(shape).permute(0, 2, 1, 3).reshape(b * nh, s, dh).contiguous()
    k = k.reshape(shape).permute(0, 2, 1, 3).reshape(b * nh, s, dh).contiguous()
    v = v.reshape(shape).permute(0, 2, 1, 3).reshape(b * nh, s, dh).contiguous()
    attn_mm = mm if cfg.route_attention else _exact_matmul
    scores = _bmm(q, k.transpose(1, 2).contiguous(), attn_mm) / math.sqrt(dh)  # FP32 scale
    probs = F.softmax(scores, dim=-1)                                          # FP32 softmax
    ctx = _bmm(probs.contiguous(), v, attn_mm)
    ctx = ctx.reshape(b, nh, s, dh).permute(0, 2, 1, 3).reshape(b, s, d).contiguous()
    return _mm2d(ctx, blk.w_o, mm) + blk.b_o           # routed GEMM, FP32 bias


def _mlp(h, blk: _Block, mm: MatMul):
    inner = F.gelu(_mm2d(h, blk.w_1, mm) + blk.b_1)    # FP32 GELU
    return _mm2d(inner, blk.w_2, mm) + blk.b_2


@dataclass(frozen=True)
class NetRun:
    """One forward pass: the logits, and the logits of every prefix of the stack.

    ``logits_per_depth[i]`` is the head applied to the residual stream after ``i + 1`` blocks,
    through **the same matmul as the rest of the run**.  Because the head and the final norm
    do not depend on depth, ``logits_per_depth[i]`` is bit-identical to the logits of a
    ``depth = i + 1`` network — so the per-layer capture and the depth sweep are the same
    measurement seen two ways, not two measurements that happen to agree.
    """

    recipe: str
    config: NetConfig
    logits: "torch.Tensor"
    logits_per_depth: Tuple["torch.Tensor", ...]
    hidden_per_depth: Tuple["torch.Tensor", ...]

    @property
    def depth(self) -> int:
        return self.config.depth


def run(config: Optional[NetConfig] = None,
        recipe: "Recipe | str" = "native-fp32",
        *, matmul: Optional[MatMul] = None) -> NetRun:
    """Forward the network once, routing every matmul through ``recipe``.

    Every GEMM — QKV projection, Q·Kᵀ, P·V, output projection, both MLP matrices, and the
    logit head — goes through :func:`ai_tensor.va_turbo.emulate`.  LayerNorm, softmax, GELU,
    the attention scale, the residual adds and the bias adds stay FP32, because the island
    accelerates GEMMs and the host computes the rest.

    ``matmul`` overrides the GEMM implementation entirely (the recipe is then only a label).
    It exists so a caller can quantify the float64-accumulation proxy by passing a plain
    ``lambda a, b: a @ b``; it is not part of the measurement path.
    """
    t = _require_torch("run")
    cfg = config or NetConfig()
    rec = get_recipe(recipe)
    mm = matmul if matmul is not None else _recipe_matmul(rec)
    w = _weights(cfg)

    x = w.x
    hidden: List["torch.Tensor"] = []
    logits: List["torch.Tensor"] = []
    for blk in w.blocks:
        x = x + _attention(F.layer_norm(x, (cfg.d_model,), blk.ln1_g, blk.ln1_b, cfg.eps),
                           blk, cfg, mm)                                   # FP32 residual
        x = x + _mlp(F.layer_norm(x, (cfg.d_model,), blk.ln2_g, blk.ln2_b, cfg.eps), blk, mm)
        hidden.append(x)
        head_in = F.layer_norm(x, (cfg.d_model,), w.ln_f_g, w.ln_f_b, cfg.eps)
        logits.append(_mm2d(head_in, w.w_head, mm) + w.b_head)
    return NetRun(
        recipe=rec.name,
        config=cfg,
        logits=logits[-1],
        logits_per_depth=tuple(logits),
        hidden_per_depth=tuple(hidden),
    )


_REFERENCE_CACHE: Dict[Tuple, NetRun] = {}


def reference_run(config: Optional[NetConfig] = None) -> NetRun:
    """The FP32-native reference forward pass, cached per configuration.

    ``native-fp32`` is :mod:`ai_tensor.va_turbo`'s recipe 0 — the exact datapath — so this is
    the same object the tile-level :func:`ai_tensor.va_turbo.quality` scores against, one
    layer up.
    """
    cfg = config or NetConfig()
    key = tuple(sorted(cfg.as_dict().items()))
    hit = _REFERENCE_CACHE.get(key)
    if hit is None:
        hit = run(cfg, "native-fp32")
        _REFERENCE_CACHE[key] = hit
    return hit


# ---------------------------------------------------------------------------------- metrics


@dataclass(frozen=True)
class NetQuality:
    """End-to-end quality at one measurement site, in :class:`Quality`'s vocabulary.

    ``tensor`` is a plain :class:`ai_tensor.va_turbo.Quality` over the logits, so
    ``rel_fro_error`` / ``sqnr_db`` / ``cosine`` / ``ppm`` / ``budget_level`` / ``status``
    mean exactly what they mean one layer down, and the two layers cannot drift apart.  The
    two distribution metrics that only exist at a network output are added beside it.

    Fails closed identically to :class:`Quality`: a nonfinite anywhere gives ``status != None``
    with ``ppm = inf``, ``sqnr_db = -inf``, ``top1_agreement = 0.0`` and ``kl_nats = inf``.  A
    nonfinite is never reported as agreement.
    """

    recipe: str
    depth: int
    tensor: Quality
    #: Fraction of (batch × sequence) positions whose argmax logit matches the reference's.
    #: Agreement with the reference run of the SAME random network — not accuracy.
    top1_agreement: float
    #: KL(reference ‖ candidate) over the softmax of the logits, in nats, averaged over
    #: positions.  Asymmetric on purpose: the reference distribution is the one that weights
    #: the comparison.
    kl_nats: float
    note: str = RANDOM_WEIGHT_CAVEAT

    @property
    def status(self) -> Optional[str]:
        return self.tensor.status

    @property
    def ok(self) -> bool:
        return self.tensor.ok

    @property
    def ppm(self) -> float:
        return self.tensor.ppm

    @property
    def rel_fro_error(self) -> float:
        return self.tensor.rel_fro_error

    @property
    def sqnr_db(self) -> float:
        return self.tensor.sqnr_db

    @property
    def cosine(self) -> float:
        return self.tensor.cosine

    @property
    def budget_level(self) -> Optional[int]:
        return self.tensor.budget_level

    def as_dict(self) -> dict:
        return {
            "recipe": self.recipe,
            "depth": self.depth,
            "rel_fro_error_ppm": self.tensor.ppm,
            "sqnr_db": self.tensor.sqnr_db,
            "cosine": self.tensor.cosine,
            "max_abs_error": self.tensor.max_abs_error,
            "top1_agreement": self.top1_agreement,
            "kl_nats": self.kl_nats,
            "budget_level": self.tensor.budget_level,
            "status": self.tensor.status,
            "note": self.note,
        }


def _failed_net_quality(name: str, depth: int, status: str) -> NetQuality:
    return NetQuality(
        recipe=name,
        depth=depth,
        tensor=vt._fail_closed(name, status),
        top1_agreement=0.0,
        kl_nats=math.inf,
    )


def _distribution_metrics(candidate, reference) -> Tuple[float, float]:
    """Top-1 agreement rate and KL(ref ‖ cand) in nats, over the last (class) axis."""
    t = torch
    ref = reference.to(t.float64).reshape(-1, reference.shape[-1])
    cand = candidate.to(t.float64).reshape(-1, candidate.shape[-1])
    agree = float((ref.argmax(dim=-1) == cand.argmax(dim=-1)).to(t.float64).mean())
    log_p = F.log_softmax(ref, dim=-1)
    log_q = F.log_softmax(cand, dim=-1)
    kl = float((log_p.exp() * (log_p - log_q)).sum(dim=-1).mean())
    return agree, kl


def _score(name: str, depth: int, candidate, reference) -> NetQuality:
    t = torch
    if not bool(t.isfinite(reference).all()):
        return _failed_net_quality(name, depth, "nonfinite_reference")
    if not bool(t.isfinite(candidate).all()):
        return _failed_net_quality(name, depth, "nonfinite_approximation")
    tensor = score_against_reference(candidate, reference, name)
    if not tensor.ok:
        return _failed_net_quality(name, depth, tensor.status or "unknown")
    agree, kl = _distribution_metrics(candidate, reference)
    if not (math.isfinite(agree) and math.isfinite(kl)):
        return _failed_net_quality(name, depth, "nonfinite_distribution_metric")
    return NetQuality(recipe=name, depth=depth, tensor=tensor,
                      top1_agreement=agree, kl_nats=kl)


@dataclass(frozen=True)
class NetReport:
    """End-to-end quality of one recipe on one network, plus the per-depth capture."""

    recipe: str
    config: NetConfig
    #: Metrics at the output of the WHOLE stack.  Identical to ``per_layer[-1]``.
    final: NetQuality
    #: One entry per block, index ``i`` = the head applied after ``i + 1`` blocks.
    per_layer: Tuple[NetQuality, ...]
    #: Residual-stream (hidden state) metrics per block, for the same reason.
    hidden_per_layer: Tuple[Quality, ...]
    executable_on_hardware: bool
    hardware_execution: str
    why: str
    note: str = RANDOM_WEIGHT_CAVEAT
    accumulation: str = ACCUMULATION_NOTE

    @property
    def depth(self) -> int:
        return self.config.depth

    @property
    def ppm(self) -> float:
        return self.final.ppm

    def as_dict(self) -> dict:
        return {
            "recipe": self.recipe,
            "config": self.config.as_dict(),
            "final": self.final.as_dict(),
            "per_layer": [q.as_dict() for q in self.per_layer],
            "hidden_ppm_per_layer": [q.ppm for q in self.hidden_per_layer],
            "executable_on_hardware": self.executable_on_hardware,
            "hardware_execution": self.hardware_execution,
            "why": self.why,
            "note": self.note,
            "accumulation": self.accumulation,
        }


def evaluate(recipe: "Recipe | str", config: Optional[NetConfig] = None) -> NetReport:
    """Run ``recipe`` through the whole network and score it against the FP32 reference.

    Fails closed exactly as :func:`ai_tensor.va_turbo.quality` does: nonfinite logits anywhere
    produce ``status != None`` with ``inf`` error, ``-inf`` SQNR, 0.0 agreement and ``inf`` KL,
    at every affected depth.  A torch build without the recipe's storage dtype is reported as
    ``unsupported_by_torch`` rather than approximated by a nearby dtype.

    The weights are random (:data:`RANDOM_WEIGHT_CAVEAT`).
    """
    _require_torch("evaluate")
    cfg = config or NetConfig()
    rec = get_recipe(recipe)
    ref = reference_run(cfg)
    try:
        cand = run(cfg, rec)
    except NotImplementedError as exc:  # torch build without float8 &c.
        status = f"unsupported_by_torch: {exc}"
        failed = tuple(_failed_net_quality(rec.name, d + 1, status) for d in range(cfg.depth))
        ok, why = vt._execution_verdict(rec, "none")
        return NetReport(
            recipe=rec.name, config=cfg, final=failed[-1], per_layer=failed,
            hidden_per_layer=tuple(vt._fail_closed(rec.name, status) for _ in range(cfg.depth)),
            executable_on_hardware=ok, hardware_execution=rec.hardware_execution, why=why,
        )

    per_layer = tuple(
        _score(rec.name, i + 1, cand.logits_per_depth[i], ref.logits_per_depth[i])
        for i in range(cfg.depth)
    )
    hidden = tuple(
        score_against_reference(cand.hidden_per_depth[i], ref.hidden_per_depth[i], rec.name)
        for i in range(cfg.depth)
    )
    ok, why = vt._execution_verdict(rec, "none")
    return NetReport(
        recipe=rec.name,
        config=cfg,
        final=per_layer[-1],
        per_layer=per_layer,
        hidden_per_layer=hidden,
        executable_on_hardware=ok,
        hardware_execution=rec.hardware_execution,
        why=why,
    )


# ------------------------------------------------------------------------------ depth sweep


def _fit_exponent(depths: Sequence[int], ppms: Sequence[float]) -> Tuple[Optional[float], Optional[float]]:
    """Least-squares slope of ``log(ppm)`` against ``log(depth)``, with its R².

    The slope is the growth exponent ``p`` in ``error ∝ depth^p``: 0.5 is what independent
    per-layer perturbations adding in quadrature give, 1.0 is coherent accumulation, above 1
    means the network amplifies.  Returns ``(None, None)`` when fewer than two usable points
    exist — an exponent from one point is not an exponent.
    """
    xs = [math.log(d) for d, p in zip(depths, ppms) if d > 0 and p > 0 and math.isfinite(p)]
    ys = [math.log(p) for d, p in zip(depths, ppms) if d > 0 and p > 0 and math.isfinite(p)]
    n = len(xs)
    if n < 2:
        return None, None
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0.0:
        return None, None
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    slope = sxy / sxx
    syy = sum((y - my) ** 2 for y in ys)
    r2 = 1.0 if syy == 0.0 else max(0.0, min(1.0, (sxy * sxy) / (sxx * syy)))
    return slope, r2


@dataclass(frozen=True)
class DepthSweep:
    """How one recipe's end-to-end error behaves as the stack gets deeper.

    ``growth_exponent`` is the fitted ``p`` in ``ppm ∝ depth^p`` and is the answer to the
    compounding question; ``growth`` is only an adjective derived from it.  ``ratio_first_last``
    is the raw observed multiple, reported beside the fit so a bad fit is visible.
    """

    recipe: str
    depths: Tuple[int, ...]
    points: Tuple[NetQuality, ...]
    growth_exponent: Optional[float]
    growth_r2: Optional[float]
    growth: str
    ratio_first_last: Optional[float]
    #: ``ppm[i] / ppm[i-1]`` beside ``depth[i] / depth[i-1]``: the local, un-fitted view.
    step_ratios: Tuple[Tuple[int, int, Optional[float], float], ...]
    monotone_in_depth: bool
    config: NetConfig
    note: str = RANDOM_WEIGHT_CAVEAT

    @property
    def ppms(self) -> Tuple[float, ...]:
        return tuple(p.ppm for p in self.points)

    def as_dict(self) -> dict:
        return {
            "recipe": self.recipe,
            "depths": list(self.depths),
            "ppm": list(self.ppms),
            "points": [p.as_dict() for p in self.points],
            "growth_exponent": self.growth_exponent,
            "growth_r2": self.growth_r2,
            "growth": self.growth,
            "ratio_first_last": self.ratio_first_last,
            "monotone_in_depth": self.monotone_in_depth,
            "note": self.note,
        }


def _classify(exponent: Optional[float]) -> str:
    if exponent is None or not math.isfinite(exponent):
        return GROWTH_UNDETERMINED
    if exponent < 1.0 - _LINEAR_BAND:
        return GROWTH_SUBLINEAR
    if exponent > 1.0 + _LINEAR_BAND:
        return GROWTH_SUPERLINEAR
    return GROWTH_LINEAR


def depth_sweep(recipe: "Recipe | str",
                depths: Sequence[int] = DEFAULT_DEPTHS,
                config: Optional[NetConfig] = None) -> DepthSweep:
    """End-to-end error of ``recipe`` at each depth, and the growth exponent that fits them.

    One deep run supplies every depth: block ``i``'s weights depend on ``i`` alone, so the
    depth-``d`` logits are the depth-12 run's ``logits_per_depth[d-1]``.  That makes the sweep
    exact rather than an average over independently drawn networks — the *only* thing changing
    across the row is depth.

    The weights are random (:data:`RANDOM_WEIGHT_CAVEAT`).
    """
    _require_torch("depth_sweep")
    rec = get_recipe(recipe)
    wanted = tuple(int(d) for d in depths)
    if not wanted:
        raise ValueError("depth_sweep needs at least one depth")
    if any(d < 1 for d in wanted):
        raise ValueError(f"depths must all be >= 1, got {wanted}")
    base = config or NetConfig()
    deep = base.at_depth(max(max(wanted), base.depth))
    report = evaluate(rec, deep)
    points = tuple(report.per_layer[d - 1] for d in wanted)

    ppms = [p.ppm for p in points]
    exponent, r2 = _fit_exponent(wanted, ppms)
    finite = [p for p in ppms if math.isfinite(p)]
    ratio = (ppms[-1] / ppms[0]) if (len(ppms) > 1 and ppms[0] > 0 and math.isfinite(ppms[-1])) else None
    steps = tuple(
        (wanted[i - 1], wanted[i],
         (ppms[i] / ppms[i - 1]) if (ppms[i - 1] > 0 and math.isfinite(ppms[i])) else None,
         wanted[i] / wanted[i - 1])
        for i in range(1, len(wanted))
    )
    monotone = len(finite) == len(ppms) and all(
        ppms[i] >= ppms[i - 1] for i in range(1, len(ppms))
    )
    return DepthSweep(
        recipe=rec.name,
        depths=wanted,
        points=points,
        growth_exponent=exponent,
        growth_r2=r2,
        growth=_classify(exponent),
        ratio_first_last=ratio,
        step_ratios=steps,
        monotone_in_depth=monotone,
        config=deep,
    )


def sweep_table(recipes: Sequence["Recipe | str"] = DEFAULT_SWEEP_RECIPES,
                depths: Sequence[int] = DEFAULT_DEPTHS,
                config: Optional[NetConfig] = None) -> Dict[str, DepthSweep]:
    """:func:`depth_sweep` for several recipes, keyed by recipe name and insertion-ordered."""
    return {get_recipe(r).name: depth_sweep(r, depths, config) for r in recipes}


def render_depth_table(sweeps: Dict[str, DepthSweep]) -> str:
    """A Markdown table of end-to-end ppm by recipe × depth, plus the growth exponent.

    Emits the random-weight caveat as the last line, because a table is the artefact most
    likely to be copied out of its context.
    """
    if not sweeps:
        return "(no sweeps)\n"
    depths = next(iter(sweeps.values())).depths
    head = "| recipe | " + " | ".join(f"d={d}" for d in depths) + " | exponent | R2 | d_first->d_last |"
    rule = "|---|" + "--:|" * (len(depths) + 3)
    lines = [head, rule]
    for name, sw in sweeps.items():
        cells = []
        for p in sw.points:
            cells.append("nonfinite" if not p.ok else f"{p.ppm:,.0f}")
        exp = "n/a" if sw.growth_exponent is None else f"{sw.growth_exponent:.3f}"
        r2 = "n/a" if sw.growth_r2 is None else f"{sw.growth_r2:.3f}"
        ratio = "n/a" if sw.ratio_first_last is None else f"{sw.ratio_first_last:.2f}x"
        lines.append(f"| {name} | " + " | ".join(cells) + f" | {exp} | {r2} | {ratio} |")
    lines.append("")
    lines.append(RANDOM_WEIGHT_CAVEAT)
    return "\n".join(lines) + "\n"
