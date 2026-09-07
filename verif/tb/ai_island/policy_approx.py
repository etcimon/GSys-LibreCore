#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S0 of the approximate-compute plan: measure the ACCURACY side before any RTL
# exists, because if the error is unacceptable the rest of the plan is void.
#
# Two levers are measured separately, because they buy different things and an
# earlier revision of the plan conflated them:
#
#   1. FORMAT NARROWING (fewer bytes per element) reduces k_bytes, and k_bytes is
#      what the measured lane rule says a dot can use.  Each halving therefore
#      doubles the groups a fixed array can host -> it buys CONCURRENCY.
#   2. APPROXIMATE MULTIPLIERS at a fixed format (mantissa truncation, Mitchell
#      logarithmic multiply) do NOT change the stored element width, so they buy
#      no lanes at all -> they buy MULTIPLIER AREA AND DEPTH only.
#
# Both are reported against the same exact reference, so the two ratios are not
# mixed up.  Accumulation is exact (float64) in every candidate: the whole
# premise is "approximate the products, accumulate exactly".
#
# Operands are real tensors from a pinned model, taken through a real forward
# pass, because an all-ones fixture has no cancellation and no dynamic range and
# would flatter every approximation.  The error metric here is tile-level and is
# a PROXY: it is not a perplexity or model-quality claim.
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys

TILE_M = 8
TILE_N = 8
TILE_K = 16  # the shipped MaxDim, which is what bounds per-tile k


def revision_arg(value):
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise argparse.ArgumentTypeError("revision must be an immutable 40-hex commit SHA")
    return value


def snapshot_dir(cache_dir, model_id, revision):
    path = (Path(cache_dir).absolute() / ("models--" + model_id.replace("/", "--"))
            / "snapshots" / revision)
    if not path.is_dir():
        raise SystemExit("pinned snapshot missing (no download is attempted): " + str(path))
    return path


def collect_operands(snapshot, revision, prompt, max_layers):
    """Real (activation, weight) pairs from a real forward pass.

    The activation is the genuine input to a Linear, so operand A carries real
    dynamic range and sign structure rather than a synthetic distribution.
    """
    import torch
    from transformers import AutoConfig, AutoModelForCausalLM, AutoTokenizer

    common = {"local_files_only": True, "trust_remote_code": False, "revision": revision}
    AutoConfig.from_pretrained(str(snapshot), **common)
    tokenizer = AutoTokenizer.from_pretrained(str(snapshot), **common)
    model = AutoModelForCausalLM.from_pretrained(str(snapshot), torch_dtype=torch.float32, **common)
    model.eval()

    captured = []

    def hook(name):
        def fn(_module, args, _out):
            if len(captured) < max_layers and args and args[0] is not None:
                act = args[0].detach().reshape(-1, args[0].shape[-1]).to(torch.float64)
                weight = _module.weight.detach().to(torch.float64)
                if act.shape[0] >= TILE_M and act.shape[1] >= TILE_K and weight.shape[0] >= TILE_N:
                    captured.append((name, act, weight))
        return fn

    handles = [module.register_forward_hook(hook(name))
               for name, module in model.named_modules()
               if module.__class__.__name__ == "Linear"]
    with torch.no_grad():
        model(**tokenizer(prompt, return_tensors="pt"))
    for handle in handles:
        handle.remove()
    if not captured:
        raise SystemExit("no Linear operands captured; the fixture would be synthetic")
    return captured


def tiles(captured, count):
    """(A, B) float64 tile pairs shaped (TILE_M, TILE_K) x (TILE_K, TILE_N)."""
    out = []
    for name, act, weight in captured:
        for step in range(count):
            r = (step * TILE_M) % (act.shape[0] - TILE_M + 1)
            c = (step * TILE_K) % (act.shape[1] - TILE_K + 1)
            o = (step * TILE_N) % (weight.shape[0] - TILE_N + 1)
            a = act[r:r + TILE_M, c:c + TILE_K]
            b = weight[o:o + TILE_N, c:c + TILE_K].transpose(0, 1)
            if a.abs().sum().item() > 0 and b.abs().sum().item() > 0:
                out.append((name, a, b))
    return out


# ---------------------------------------------------------------- lever 1
def quantize_format(t, fmt):
    """Round operands to a storage format. This is what changes k_bytes."""
    import torch
    if fmt == "FP32":
        return t.to(torch.float32).to(torch.float64)
    if fmt == "BF16":
        return t.to(torch.bfloat16).to(torch.float64)
    if fmt == "FP16":
        return t.to(torch.float16).to(torch.float64)
    if fmt in ("FP8_E4M3", "FP8_E5M2"):
        dtype = torch.float8_e4m3fn if fmt == "FP8_E4M3" else torch.float8_e5m2
        scale = t.abs().max()
        if scale == 0:
            return t.clone()
        # Per-tile scaling, which is what any real FP8 path does; without it FP8
        # would be measured on its raw exponent range and look far worse.
        return (t / scale).to(dtype).to(torch.float64) * scale
    if fmt in ("INT8", "INT4"):
        levels = 127 if fmt == "INT8" else 7
        scale = t.abs().max() / levels
        if scale == 0:
            return t.clone()
        return torch.clamp(torch.round(t / scale), -levels - 1, levels) * scale
    raise SystemExit("unknown format " + fmt)


# ---------------------------------------------------------------- lever 2
def truncate_mantissa(t, keep):
    """Keep `keep` mantissa bits of an FP32 operand: a cheaper multiplier, same width."""
    import torch
    if not isinstance(keep, int) or not 0 <= keep <= 23:
        raise ValueError("retained mantissa bits must be in [0,23]")
    bits = t.to(torch.float32).contiguous().view(torch.int32)
    mask = -1 << (23 - keep)
    return (bits & mask).view(torch.float32).to(torch.float64)


def mitchell_product(a, b):
    """Mitchell logarithmic multiply: exponent add plus a linear mantissa term.

    (1+ma) * (1+mb) ~= 1 + ma + mb, the classic analog-like approximation. This
    replaces a multiplier array with an adder, at a known ~ -11% worst-case
    per-product error.
    """
    import torch
    sign = torch.sign(a) * torch.sign(b)
    aa, ab = a.abs(), b.abs()
    ea, eb = torch.floor(torch.log2(aa)), torch.floor(torch.log2(ab))
    ma, mb = aa / torch.pow(2.0, ea) - 1.0, ab / torch.pow(2.0, eb) - 1.0
    approx = torch.pow(2.0, ea + eb) * (1.0 + ma + mb)
    return torch.where((aa == 0) | (ab == 0), torch.zeros_like(approx), sign * approx)


def rel_error(candidate, reference):
    difference = candidate - reference
    num = difference.norm().item()
    den = reference.norm().item()
    if not math.isfinite(num) or not math.isfinite(den):
        return math.inf
    return num / den if den else (math.inf if difference.any().item() else 0.0)


# The RTL bound is eps * kappa, so validating it needs the same kappa the RTL
# would be handed.  Two definitions, matching the two bound kinds:
#   relative kinds:   kappa = sum|a_i b_i| / |sum a_i b_i|
#   full-scale kinds: kappa = K * max|a| * max|b| / |sum a_i b_i|
# Both are per-output-element; the tile value is the worst element, because the
# bound has to hold for every element, not on average.
def kappa_relative(a, b):
    """Per-element worst case, and the Frobenius-matched aggregate.

    The per-element worst case is the mathematically strict figure, but it is
    dominated by any single output element whose exact value nearly cancels, and
    it therefore saturates. The Frobenius ratio is the figure that matches the
    Frobenius error metric it will be compared against - a bound and its
    observation have to be taken at the same granularity or the comparison is
    meaningless.
    """
    import torch
    products = a.unsqueeze(2) * b.unsqueeze(0)          # (M, K, N)
    abs_sum = products.abs().sum(dim=1)
    exact_signed = products.sum(dim=1)
    exact = exact_signed.abs()
    if not torch.isfinite(abs_sum).all() or not torch.isfinite(exact).all():
        return math.inf, math.inf
    ratio = torch.where(exact > 0, abs_sum / exact, torch.full_like(exact, math.inf))
    den = exact_signed.norm().item()
    num = abs_sum.norm().item()
    frob = num / den if den > 0 and math.isfinite(den) and math.isfinite(num) else math.inf
    return ratio.max().item(), frob


def kappa_fullscale(a, b):
    import torch
    k = a.shape[1]
    scale = float(k) * a.abs().max().item() * b.abs().max().item()
    exact = (a @ b)
    if not math.isfinite(scale) or not torch.isfinite(exact).all():
        return math.inf, math.inf
    ratio = torch.where(exact.abs() > 0, scale / exact.abs(), torch.full_like(exact, math.inf))
    elements = float(exact.numel()) ** 0.5
    den = exact.norm().item()
    frob = elements * scale / den if den > 0 and math.isfinite(den) else math.inf
    return ratio.max().item(), frob


# ------------------------------------------------------- moving-window model
# g6lc_ai_pe_dot_float.sv is BLOCK FLOATING POINT per reduction step: it picks
# `block_exp` from that step's lanes only, aligns every product to it, reduces
# them in a 640-bit integer accumulator (FP_DOT_MAXW=640) and rounds ONCE, in
# bfp_mant_exp_to_fp32.  g6lc_ai_gemm_seq.sv then folds each step's FP32 result
# into an FP32 accumulator with fp32_add, and `sum_first_q` makes the first fold
# a plain copy.  So a K-element dot has W = ceil(K/mac_step) windows and
# 2*W - 1 rounding sites, not K, and INTRA-window cancellation is free because
# the integer reduction is exact.
PE_LANES = 8
FORMAT_BYTES = {"FP32": 4, "BF16": 2, "FP16": 2, "FP8_E4M3": 1, "FP8_E5M2": 1, "INT8": 1}


def candidate_format(label):
    """Storage format a candidate's operands sit in; the approximate
    multipliers are FP32-resident, which is the point of lever 2."""
    return label if label in FORMAT_BYTES or label == "INT4" else "FP32"


def mac_step(fmt, lanes=PE_LANES):
    """Elements one reduction step covers, mirroring g6lc_ai_gemm_seq.sv:
    `mac_step = (fmt==INT4) ? 2*PeLanes : PeLanes/bytes_per_element`."""
    if fmt == "INT4":
        return 2 * lanes
    return max(1, lanes // FORMAT_BYTES.get(fmt, 4))


def rounding_sites(windows):
    """2*W - 1: one block-floating round per window, one FP32 accumulator add
    per window after the first."""
    return 2 * windows - 1 if isinstance(windows, int) and windows >= 1 else None


WINDOWED_EXACTNESS = (
    "float64 partial sums are a PROXY for the RTL's exact 640-bit integer reduction. The RTL "
    "reduction is exact and float64 is not, so a window's partial sum measured here can itself be "
    "rounded; the windowed kappa is therefore a sample proxy, not the exact block-floating value. "
    "The RTL is additionally exact only while a window's product-exponent spread fits FP_DOT_MAXW: "
    "fp_dot_product_aligned zeroes a product whose shift reaches 640, which this proxy does not model."
)


def windowed_kappa_ratio(window_l1, running_l1, result_magnitude):
    """(sum_w |s_w| + sum_w |A_w|) / |R|, clamped UP to the single-rounding case.

    Returns (value, clamped).  A value below 1 would claim a bound tighter than
    one exact rounding of the result, which is not sound, so it is raised to 1
    and the clamp is reported rather than silently accepted.
    """
    for value in (window_l1, running_l1, result_magnitude):
        if not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            return math.inf, False
    if result_magnitude <= 0:
        return math.inf, False
    ratio = (window_l1 + running_l1) / result_magnitude
    if not math.isfinite(ratio):
        return math.inf, False
    return (1.0, True) if ratio < 1.0 else (ratio, False)


def kappa_windowed(a, b, window):
    """Moving-window kappa for the block-floating reduction.

    The K dimension is split into windows of `window` elements.  s_w is window
    w's partial sum and A_w the running accumulator after folding it, so the
    FIRST-ORDER error of the RTL's 2*W-1 roundings is bounded by
    eps * (sum_w |s_w| + sum_{w>1} |A_w|).  Unlike the per-element kappa this
    charges nothing for cancellation INSIDE a window, because the RTL reduces a
    window exactly; it does charge for cancellation ACROSS windows, which is
    where the FP32 accumulator really does lose bits.

    The sum over A_w deliberately includes w=1, whose accumulator fold is a
    plain copy in the RTL, so the kappa carries one |R|-sized slack term that
    the neglected O(eps^2) cross-terms have to be paid out of.  That slack is
    not a proof of second-order safety: it is a margin, and it is one reason
    this stays a sample proxy.

    Reported per-element-worst and Frobenius-matched, like the other helpers,
    because a bound and its observation have to share a granularity.
    """
    import torch
    if not isinstance(window, int) or window < 1 or a.shape[1] < 1:
        return {"element_worst": math.inf, "frobenius": math.inf, "window": window,
                "windows": None, "rounding_sites": None, "clamped": False,
                "status": "invalid_window", "exactness": WINDOWED_EXACTNESS}
    k = a.shape[1]
    step = min(window, k)
    windows = -(-k // step)
    products = a.unsqueeze(2) * b.unsqueeze(0)          # (M, K, N)
    accumulator = torch.zeros_like(products[:, 0, :])
    window_l1 = torch.zeros_like(accumulator)
    running_l1 = torch.zeros_like(accumulator)
    for start in range(0, k, step):
        partial = products[:, start:start + step, :].sum(dim=1)
        accumulator = accumulator + partial
        window_l1 = window_l1 + partial.abs()
        running_l1 = running_l1 + accumulator.abs()
    finite = (torch.isfinite(products).all() and torch.isfinite(window_l1).all()
              and torch.isfinite(running_l1).all() and torch.isfinite(accumulator).all())
    if not finite:
        return {"element_worst": math.inf, "frobenius": math.inf, "window": step,
                "windows": windows, "rounding_sites": rounding_sites(windows),
                "clamped": False, "status": "nonfinite_or_undefined_metric",
                "exactness": WINDOWED_EXACTNESS}
    magnitude = accumulator.abs()
    total = window_l1 + running_l1
    ratio = torch.where(magnitude > 0, total / magnitude, torch.full_like(magnitude, math.inf))
    clamped = bool((torch.isfinite(ratio) & (ratio < 1.0)).any().item())
    ratio = torch.clamp(ratio, min=1.0)
    frobenius, frobenius_clamped = windowed_kappa_ratio(
        window_l1.norm().item(), running_l1.norm().item(), accumulator.norm().item())
    return {"element_worst": ratio.max().item(), "frobenius": frobenius,
            "window": step, "windows": windows, "rounding_sites": rounding_sites(windows),
            "clamped": clamped or frobenius_clamped, "status": "sample_proxy",
            "exactness": WINDOWED_EXACTNESS}


# The windowed kappa is the sound multiplier for an error injected AT a window
# boundary - the block-floating result rounding and the FP32 accumulator add.
# Every candidate in ANALYTIC_EPS_PPM injects its error per PRODUCT instead:
# operand storage rounding, mantissa truncation and Mitchell all perturb
# a_i*b_i BEFORE the exact integer reduction, and INT8/INT4 quantise the
# operands outright.  Substituting the windowed kappa for the element kappa
# there would discard the intra-window cancellation that a per-product
# perturbation genuinely does amplify, so for those candidates the windowed
# bound is reported as a DIAGNOSTIC and never used to admit anything.
PER_PRODUCT_SITE = (
    "epsilon is injected per PRODUCT (operand quantisation / approximate multiplier), before the "
    "exact integer reduction, so the windowed kappa is NOT a sound multiplier for it: a window whose "
    "products cancel still amplifies a per-product perturbation. Reported as a diagnostic only."
)
PER_WINDOW_SITE = (
    "epsilon is injected at a window boundary (block-floating result rounding or FP32 accumulator "
    "add), which is exactly what the windowed kappa multiplies."
)


def windowed_error_site(label):
    return "per_product" if label in ANALYTIC_EPS_PPM else "per_window"


# Smallest positive subnormal of each target format. IEEE round-to-nearest with
# gradual underflow gives |fl(x)-x| <= u|x| + eta/2, so a MIXED bound covers the
# subnormal and flush-to-zero cases a pure relative epsilon cannot describe.
FORMAT_ETA = {"FP32": 2.0 ** -149, "BF16": 2.0 ** -133, "FP16": 2.0 ** -24,
              "FP8_E4M3": 2.0 ** -9, "FP8_E5M2": 2.0 ** -16}


def abs_floor_ppm(fmt, reference_scale, terms=1):
    """The eta/2 absolute floor of `fmt`, in ppm of `reference_scale`, rounded UP.

    This ADDS a term to the bound; it tightens nothing.  That is what makes it
    sound where the pure relative bound was simply inapplicable.
    `reference_scale` is the amplification-adjusted reference magnitude: the
    caller divides the tile reference by whatever multiplies the floor on its
    way to the output, so this helper only converts an absolute floor to ppm.
    """
    eta = FORMAT_ETA.get(fmt)
    if eta is None or not isinstance(terms, int) or terms < 1:
        return BOUND_SENTINEL_PPM
    if not isinstance(reference_scale, (int, float)) or isinstance(reference_scale, bool):
        return BOUND_SENTINEL_PPM
    scale = float(reference_scale)
    if not math.isfinite(scale) or scale <= 0:
        return BOUND_SENTINEL_PPM
    floor_num, floor_den = (eta / 2.0).as_integer_ratio()
    scale_num, scale_den = scale.as_integer_ratio()
    numerator = 1_000_000 * terms * floor_num * scale_den
    denominator = floor_den * scale_num
    quantized = -(-numerator // denominator)
    return quantized if quantized <= 1_000_000 else BOUND_SENTINEL_PPM


def tile_abs_floor_ppm(label, a, b, windows):
    """Frobenius-matched absolute floor of one tile, in ppm of ||A@B||.

    Each operand's conversion floor is amplified by the OPPOSITE operand's
    row/column L1 norm on its way to an output element, and the reduction adds
    one FP32 half-subnormal per rounding site.  Terms are summed after being
    rounded up individually, and the triangle inequality on the Frobenius norms
    keeps the sum on the conservative side.
    """
    import torch
    if not isinstance(windows, int) or windows < 1:
        return BOUND_SENTINEL_PPM
    reference = (a @ b).norm().item()
    if not math.isfinite(reference) or reference <= 0:
        return BOUND_SENTINEL_PPM
    rows, cols = a.shape[0], b.shape[1]
    # INT8/INT4 have no subnormal conversion floor to add: their absolute
    # quantisation error is already the whole of the FULL-kind epsilon.
    fmt = candidate_format(label) if label not in ("INT8", "INT4") else None
    terms = []
    if fmt is not None:
        scale_a = a.abs().max().item() if label.startswith("FP8") else 1.0
        scale_b = b.abs().max().item() if label.startswith("FP8") else 1.0
        amplification = (scale_a * b.abs().sum(dim=0).norm().item() * rows ** 0.5,
                         scale_b * a.abs().sum(dim=1).norm().item() * cols ** 0.5)
        for amplifier in amplification:
            if math.isfinite(amplifier) and amplifier > 0:
                terms.append(abs_floor_ppm(fmt, reference / amplifier))
    terms.append(abs_floor_ppm("FP32", reference / (rows * cols) ** 0.5,
                               rounding_sites(windows)))
    return total_bound_ppm(*terms)


# Analytic per-product bounds in ppm, mirroring va_turbo_arith in
# g6lc_ai_policy_pkg.sv.  Kept as literals so a divergence between the RTL table
# and the measurement is visible as a mismatch rather than hidden by a shared
# helper computing both sides from one formula.
ANALYTIC_EPS_PPM = {
    "FP16": (977, "rel"), "BF16": (7828, "rel"),
    "FP8_E4M3": (128907, "rel"), "FP8_E5M2": (265625, "rel"),
    # Corrected: the earlier 7,887 / 147,908 were understated against the exact
    # 7,889.52 / 147,959.18 and were therefore unsound. These are the values the
    # RTL's two-step ceiling actually produces at worst-case flatness.
    "INT8": (7892, "full"), "INT4": (147961, "full"),
    "mantissa_truncated:10": (1953, "rel"), "mantissa_truncated:8": (7798, "rel"),
    "mantissa_truncated:6": (31006, "rel"), "mantissa_truncated:4": (121094, "rel"),
    "mantissa_truncated:2": (437500, "rel"),
    "mitchell_logarithmic": (250000, "rel"),
}


# Mirror of va_turbo_budget_ppm: geometric ladder, 100 ppm doubling per step,
# saturating at 100%. Level 0 is off.
def budget_ppm(level):
    return 0 if level == 0 else min(1_000_000, 100 << (level - 1))


def level_for(ppm):
    """Smallest level whose budget covers `ppm`, or None if nothing does."""
    if ppm is None or not math.isfinite(ppm) or not 0 <= ppm <= 1_000_000:
        return None
    for level in range(1, 16):
        if budget_ppm(level) >= ppm:
            return level
    return None


BOUND_SENTINEL_PPM = 0xfffff
ROUND_EPS_PPM = (
    1250000, 562500, 265625, 128907, 63477, 31495, 15687, 7828,
    3911, 1955, 977, 489, 245, 123, 62, 31, 16, 8, 4, 2, 1, 1, 1, 1,
)


def round_eps_ppm(bits):
    if not isinstance(bits, int) or not 0 <= bits <= 23:
        return BOUND_SENTINEL_PPM
    return ROUND_EPS_PPM[bits] if ROUND_EPS_PPM[bits] <= 1_000_000 else BOUND_SENTINEL_PPM


def trunc_eps_ppm(bits):
    if not isinstance(bits, int) or not 0 <= bits <= 23:
        return BOUND_SENTINEL_PPM
    denominator = 1 << (2 * bits)
    numerator = 1_000_000 * ((2 << bits) - 1)
    return (numerator + denominator - 1) // denominator


def fullscale_eps_ppm(levels, flatness):
    if levels not in (7, 127) or not math.isfinite(flatness) or not 0 <= flatness <= 2:
        return math.inf
    return 1_000_000 * (flatness / (2 * levels) + 1 / (4 * levels * levels))


def q8_ceil(value, maximum):
    if value is None or not math.isfinite(value) or value < 0:
        return None
    numerator, denominator = value.as_integer_ratio()
    quantized = (numerator * 256 + denominator - 1) // denominator
    return quantized if quantized <= maximum else None


def quant_eps_ppm(levels, flat_q8):
    if levels not in (7, 127) or not isinstance(flat_q8, int) or not 0 <= flat_q8 <= 1023:
        return BOUND_SENTINEL_PPM
    per_unit, constant = (3938, 16) if levels == 127 else (71429, 5103)
    return (per_unit * flat_q8 + 255) // 256 + constant


def bound_ppm(eps_ppm, kappa_q8):
    if (not isinstance(eps_ppm, int) or not 0 <= eps_ppm <= 1_000_000
            or not isinstance(kappa_q8, int) or not 256 <= kappa_q8 <= 65535):
        return BOUND_SENTINEL_PPM
    scaled = (eps_ppm * kappa_q8 + 255) // 256
    return scaled if scaled <= 1_000_000 else BOUND_SENTINEL_PPM


def windowed_bound_ppm(eps_ppm, kappa_window_q8, windows):
    """bound_ppm's composition against the windowed kappa.

    `windows` is a consistency guard, not a multiplier: kappa_windowed already
    sums over every window, so the count is inside the kappa.  An implausible
    count fails closed rather than producing a bound nobody can trace back to a
    window layout.
    """
    if not isinstance(windows, int) or isinstance(windows, bool) or windows < 1:
        return BOUND_SENTINEL_PPM
    return bound_ppm(eps_ppm, kappa_window_q8)


def total_bound_ppm(*terms):
    """Sum ppm terms; any invalid or over-budget term fails the whole sum closed."""
    total = 0
    for term in terms:
        if (not isinstance(term, int) or isinstance(term, bool)
                or not 0 <= term <= 1_000_000):
            return BOUND_SENTINEL_PPM
        total += term
    return total if total <= 1_000_000 else BOUND_SENTINEL_PPM


def report_json(report):
    nonfinite = []

    def clean(value, path):
        if isinstance(value, float) and not math.isfinite(value):
            nonfinite.append({"path": path, "status": "undefined" if math.isnan(value) else "infinite"})
            return None
        if isinstance(value, dict):
            return {key: clean(item, path + "/" + str(key)) for key, item in value.items()}
        if isinstance(value, (list, tuple)):
            return [clean(item, path + "/" + str(index)) for index, item in enumerate(value)]
        return value

    result = clean(report, "")
    result["serialization_status"] = "nonfinite_values_replaced_with_null" if nonfinite else "finite"
    result["nonfinite_fields"] = nonfinite
    return json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n"


# Premise failures the mixed relative+absolute bound covers: every one of them
# is an UNDERFLOW-side event, where |fl(x)-x| <= u|x| + eta/2 still holds under
# gradual underflow (and holds trivially when |x| < eta/2 flushes to zero).
# Overflow, non-finite operands and unmodeled input rounding stay fatal, because
# no additive floor describes them.
ABSOLUTE_FLOOR_COVERS = (
    "below_normal_conversion_domain", "subnormal_conversion_result",
    "below_normal_fp32_domain", "below_normal_host_domain",
    "host_product_underflow",
)


def candidate_premises(label, tile_set):
    import torch
    failures = []
    formats = {"FP32": torch.float32, "FP16": torch.float16, "BF16": torch.bfloat16,
               "FP8_E4M3": torch.float8_e4m3fn, "FP8_E5M2": torch.float8_e5m2}
    for index, (_, a, b) in enumerate(tile_set):
        for side, operand in (("A", a), ("B", b)):
            prefix = "tile%d:%s:" % (index, side)
            if not torch.isfinite(operand).all():
                failures.append(prefix + "nonfinite_operand")
                continue
            if label in formats:
                dtype = formats[label]
                target_input = operand
                if label.startswith("FP8"):
                    scale = operand.abs().max().item()
                    target_input = operand / scale if scale else operand
                limits = torch.finfo(dtype)
                nonzero = operand != 0
                if not torch.all((~nonzero) | (target_input.abs() >= limits.tiny)):
                    failures.append(prefix + "below_normal_conversion_domain")
                if not torch.all(target_input.abs() <= limits.max):
                    failures.append(prefix + "above_finite_conversion_domain")
                converted = target_input.to(dtype).to(torch.float64)
                if not torch.isfinite(converted).all():
                    failures.append(prefix + "nonfinite_conversion_result")
                elif not torch.all((~nonzero) | (converted.abs() >= limits.tiny)):
                    failures.append(prefix + "subnormal_conversion_result")
            elif label.startswith("mantissa_truncated:"):
                native = operand.to(torch.float32).to(torch.float64)
                if not torch.equal(native, operand):
                    failures.append(prefix + "fp32_input_rounding_not_modeled")
                if not torch.isfinite(native).all():
                    failures.append(prefix + "nonfinite_fp32_conversion_result")
                elif not torch.all((operand == 0)
                                   | (native.abs() >= torch.finfo(torch.float32).tiny)):
                    failures.append(prefix + "below_normal_fp32_domain")
            elif label in ("INT8", "INT4"):
                levels = 127 if label == "INT8" else 7
                maximum = operand.abs().max().item()
                scale = maximum / levels
                if maximum and (not math.isfinite(scale) or scale < torch.finfo(torch.float64).tiny):
                    failures.append(prefix + "invalid_or_subnormal_quantization_scale")
            elif label == "mitchell_logarithmic":
                if not torch.all((operand == 0) | (operand.abs() >= torch.finfo(torch.float64).tiny)):
                    failures.append(prefix + "below_normal_host_domain")
            else:
                failures.append(prefix + "unknown_arithmetic")
        products = a.unsqueeze(2) * b.unsqueeze(0)
        nonzero_products = (a.unsqueeze(2) != 0) & (b.unsqueeze(0) != 0)
        if not torch.isfinite(products).all():
            failures.append("tile%d:host_product_overflow" % index)
        elif not torch.all((~nonzero_products)
                           | (products.abs() >= torch.finfo(torch.float64).tiny)):
            failures.append("tile%d:host_product_underflow" % index)
        if not torch.isfinite(a @ b).all():
            failures.append("tile%d:nonfinite_float64_reference_proxy" % index)
    if not tile_set:
        failures.append("no_samples")
    covered = [f for f in failures if f.split(":")[-1] in ABSOLUTE_FLOOR_COVERS]
    fatal = [f for f in failures if f not in covered]
    return {"satisfied": not failures, "failures": failures,
            "absolute_floor_satisfied": not fatal,
            "absolute_floor_failures": fatal,
            "absolute_floor_covered": covered,
            "qualification": "Sample finite-normal conversion domain (zeros allowed); subnormal, underflow and overflow cases are not covered. Truncation additionally requires FP32-representable inputs. Float64 scaling/products/accumulation are proxies; RTL FP32 accumulation is not modeled.",
            "absolute_floor_qualification": "Same sample, with the underflow side of the domain admitted because the mixed bound ADDS an eta/2 absolute term: gradual underflow keeps |fl(x)-x| <= u|x| + eta/2, and a value below eta/2 flushes to zero within that same floor. Overflow, non-finite operands, unmodeled FP32 input rounding and invalid integer scales remain fatal."}


def validate_bounds(report, tile_set):
    """Check the analytic bound is not exceeded by the observed per-tile error.

    A violation means the RTL bound is UNSOUND and must be widened; slack means
    it is conservative and how much budget tuning could reclaim.
    """
    if not tile_set:
        raise ValueError("bound validation requires at least one tile")
    rows = []
    observed = {}
    for row in report["format_narrowing"]:
        observed[row["format"]] = row["rel_error_max"]
    for row in report["approximate_multiplier"]:
        label = row["topology"] + (":%d" % row["mantissa_bits_kept"]
                                   if "mantissa_bits_kept" in row else "")
        observed[label] = row["rel_error_max"]

    # Operand flatness fa = sum|a| / (K*max|a|), which the RTL uses to tighten
    # the FULL-kind bound. The worst case it falls back to is fa + fb = 2.
    def flatness(a, b):
        k = a.shape[1]
        fa = a.abs().sum(dim=1).max().item() / (k * a.abs().max().item()) if a.abs().max() > 0 else 1.0
        fb = b.abs().sum(dim=0).max().item() / (k * b.abs().max().item()) if b.abs().max() > 0 else 1.0
        return fa + fb

    flat_values = [flatness(a, b) for _, a, b in tile_set]
    flat_worst = max(flat_values) if all(math.isfinite(f) for f in flat_values) else math.inf
    flat_q8 = q8_ceil(flat_worst, 1023)
    flat_valid = flat_q8 is not None and 0 < flat_q8 <= 512
    flat_q8 = flat_q8 if flat_valid else 512
    rel_stats = [kappa_relative(a, b) for _, a, b in tile_set]
    full_stats = [kappa_fullscale(a, b) for _, a, b in tile_set]
    kappa_rel_element = max(s[0] for s in rel_stats)
    kappa_full_element = max(s[0] for s in full_stats)
    kappa_rel_frob = max(s[1] for s in rel_stats)
    kappa_full_frob = max(s[1] for s in full_stats)

    windowed_cache = {}

    def windowed_stats(window):
        if window not in windowed_cache:
            windowed_cache[window] = [kappa_windowed(a, b, window) for _, a, b in tile_set]
        return windowed_cache[window]

    k_worst = max(a.shape[1] for _, a, b in tile_set)
    sweep_windows = sorted({1, 2, 4, PE_LANES, 2 * PE_LANES, k_worst})
    for label, (eps_ppm, kind) in sorted(ANALYTIC_EPS_PPM.items()):
        if label not in observed:
            continue
        kappa = kappa_rel_frob if kind == "rel" else kappa_full_frob
        strict = kappa_rel_element if kind == "rel" else kappa_full_element
        # FULL kinds scale with measured flatness; REL kinds do not.
        levels = 127 if label == "INT8" else 7
        eps_used = fullscale_eps_ppm(levels, flat_worst) if kind == "full" else eps_ppm
        rtl_eps = quant_eps_ppm(levels, flat_q8) if kind == "full" else eps_ppm
        matched_ppm = eps_used * kappa
        strict_ppm = eps_used * strict
        observed_ppm = observed[label] * 1e6
        kappa_q8 = q8_ceil(kappa, 65535)
        strict_q8 = q8_ceil(strict, 65535)
        premises = candidate_premises(label, tile_set)
        comparable = (premises["satisfied"] and math.isfinite(matched_ppm)
                      and math.isfinite(observed_ppm) and observed_ppm >= 0)
        empirical_holds = observed_ppm <= matched_ppm if comparable else None
        rtl_matched = bound_ppm(rtl_eps, kappa_q8) if premises["satisfied"] else BOUND_SENTINEL_PPM
        rtl_strict = bound_ppm(rtl_eps, strict_q8) if premises["satisfied"] else BOUND_SENTINEL_PPM
        admissible = (comparable and matched_ppm <= 1_000_000
                      and rtl_matched <= 1_000_000 and empirical_holds)

        # --- moving-window model, on the same sample and the same granularity
        window = min(mac_step(candidate_format(label)), k_worst)
        stats = windowed_stats(window)
        kappa_win = max(s["frobenius"] for s in stats)
        kappa_win_element = max(s["element_worst"] for s in stats)
        windows = max(s["windows"] or 0 for s in stats)
        kappa_win_q8 = q8_ceil(kappa_win, 65535)
        floor_ppm = max(tile_abs_floor_ppm(label, a, b, s["windows"])
                        for (_, a, b), s in zip(tile_set, stats))
        floor_satisfied = premises["absolute_floor_satisfied"]
        bound_windowed = (windowed_bound_ppm(rtl_eps, kappa_win_q8, windows)
                          if floor_satisfied else BOUND_SENTINEL_PPM)
        bound_total = total_bound_ppm(bound_windowed, floor_ppm)
        # The sound composition: the candidate's per-product epsilon keeps the
        # per-product kappa, and only the reduction's own FP32 roundings get the
        # windowed kappa. This ADDS the accumulation term the older report said
        # was "not modeled", so it is looser than rtl_matched, never tighter.
        rtl_matched_mixed = (bound_ppm(rtl_eps, kappa_q8)
                             if floor_satisfied else BOUND_SENTINEL_PPM)
        accumulation = (windowed_bound_ppm(round_eps_ppm(23), kappa_win_q8, windows)
                        if floor_satisfied else BOUND_SENTINEL_PPM)
        bound_sound = total_bound_ppm(rtl_matched_mixed, accumulation, floor_ppm)
        # The same composition at every swept window size, so the window
        # sensitivity of the bound is visible rather than asserted.
        bound_sweep = []
        for swept in sweep_windows:
            swept_stats = windowed_stats(swept)
            swept_kappa = max(s["frobenius"] for s in swept_stats)
            swept_q8 = q8_ceil(swept_kappa, 65535)
            swept_windows = max(s["windows"] or 0 for s in swept_stats)
            swept_floor = max(tile_abs_floor_ppm(label, a, b, s["windows"])
                              for (_, a, b), s in zip(tile_set, swept_stats))
            swept_bound = (windowed_bound_ppm(rtl_eps, swept_q8, swept_windows)
                           if floor_satisfied else BOUND_SENTINEL_PPM)
            bound_sweep.append({
                "window": swept, "windows": swept_windows,
                "rounding_sites": rounding_sites(swept_windows),
                "kappa_windowed": swept_kappa,
                "bound_windowed_ppm": swept_bound,
                "abs_floor_ppm": swept_floor,
                "bound_total_ppm": total_bound_ppm(swept_bound, swept_floor),
            })
        site = windowed_error_site(label)
        mixed_comparable = (floor_satisfied and math.isfinite(observed_ppm)
                            and observed_ppm >= 0 and kappa_win_q8 is not None)
        holds_windowed = (observed_ppm <= bound_total
                          if mixed_comparable and bound_total <= 1_000_000 else None)
        holds_sound = (observed_ppm <= bound_sound
                       if mixed_comparable and bound_sound <= 1_000_000 else None)
        mixed_admissible = bool(mixed_comparable and bound_sound <= 1_000_000 and holds_sound)
        if not floor_satisfied:
            status_windowed = "unqualified_arithmetic_premises"
        elif not mixed_comparable:
            status_windowed = ("kappa_windowed_q8_unrepresentable" if kappa_win_q8 is None
                               else "nonfinite_or_undefined_metric")
        elif bound_sound > 1_000_000:
            status_windowed = "above_maximum_budget"
        elif not holds_sound:
            status_windowed = "sample_bound_violation"
        else:
            status_windowed = "sample_qualified"
        if not premises["satisfied"]:
            status = "unqualified_arithmetic_premises"
        elif not comparable:
            status = "nonfinite_or_undefined_metric"
        elif kappa_q8 is None:
            status = "kappa_q8_unrepresentable"
        elif rtl_matched > 1_000_000:
            status = "above_maximum_budget"
        elif not empirical_holds:
            status = "sample_bound_violation"
        else:
            status = "sample_qualified"
        rows.append({
            "candidate": label, "bound_kind": kind, "eps_ppm": eps_ppm,
            "eps_after_flatness_ppm": eps_used, "rtl_eps_ppm": rtl_eps,
            "flatness_q8": flat_q8 if kind == "full" else None,
            "kappa_frobenius": kappa, "kappa_element_worst": strict,
            "kappa_frobenius_q8": kappa_q8, "kappa_element_worst_q8": strict_q8,
            "matched_bound_ppm": matched_ppm,
            "element_worst_bound_ppm": strict_ppm,
            "rtl_matched_bound_ppm": rtl_matched,
            "rtl_element_worst_bound_ppm": rtl_strict,
            "observed_max_ppm": observed_ppm,
            "holds": empirical_holds, "empirical_holds": empirical_holds,
            "universal_proof": False,
            "premises_satisfied": premises["satisfied"],
            "premise_failures": premises["failures"],
            "premise_qualification": premises["qualification"],
            "analytic_admissible": admissible, "status": status,
            "slack_factor": (matched_ppm / observed_ppm) if comparable and observed_ppm > 0 else None,
            "element_bound_vacuous": not math.isfinite(strict_ppm) or strict_ppm > 1_000_000.0,
            # The tuning output: the level a caller must authorise under the
            # analytic bound, versus the level the observed error would need if
            # the bound were tight. The gap is what a tighter derivation buys.
            "level_needed_analytic": level_for(rtl_matched) if admissible else None,
            "level_needed_analytic_raw": level_for(matched_ppm) if comparable else None,
            "level_needed_observed": level_for(observed_ppm),
            # moving-window model
            "window": window, "windows": windows,
            "rounding_sites": rounding_sites(windows),
            "kappa_windowed": kappa_win,
            "kappa_windowed_element_worst": kappa_win_element,
            "kappa_windowed_q8": kappa_win_q8,
            "kappa_windowed_clamped": any(s["clamped"] for s in stats),
            "kappa_element": strict,
            "bound_windowed_ppm": bound_windowed,
            "abs_floor_ppm": floor_ppm,
            "bound_total_ppm": bound_total,
            "accumulation_bound_ppm": accumulation,
            "bound_sound_total_ppm": bound_sound,
            "windowed_error_site": site,
            "windowed_model_applies": site == "per_window",
            "windowed_model_qualification": PER_WINDOW_SITE if site == "per_window" else PER_PRODUCT_SITE,
            "mixed_premises_satisfied": floor_satisfied,
            "mixed_premise_failures": premises["absolute_floor_failures"],
            "mixed_premises_covered_by_floor": premises["absolute_floor_covered"],
            "mixed_premise_qualification": premises["absolute_floor_qualification"],
            "empirical_holds_windowed": holds_windowed,
            "empirical_holds_sound_total": holds_sound,
            "level_needed_windowed": level_for(bound_total) if holds_windowed else None,
            "level_needed_sound_total": level_for(bound_sound) if mixed_admissible else None,
            "mixed_admissible": mixed_admissible,
            "status_windowed": status_windowed,
            "windowed_bound_sweep": bound_sweep,
            "windowed_exactness": stats[0]["exactness"],
        })
    sweep = []
    for swept in sweep_windows:
        swept_stats = windowed_stats(swept)
        swept_kappa = max(s["frobenius"] for s in swept_stats)
        swept_windows = max(s["windows"] or 0 for s in swept_stats)
        sweep.append({
            "window": swept, "windows": swept_windows,
            "rounding_sites": rounding_sites(swept_windows),
            "kappa_windowed_frobenius": swept_kappa,
            "kappa_windowed_element_worst": max(s["element_worst"] for s in swept_stats),
            "kappa_windowed_q8": q8_ceil(swept_kappa, 65535),
            "clamped": any(s["clamped"] for s in swept_stats),
        })
    return {
        "schema_version": 3,
        "flatness_worst": flat_worst, "flatness_q8": flat_q8,
        "flatness_q8_status": "upward_quantized" if flat_valid else "fallback_to_worst_case",
        "bound_sentinel_ppm": BOUND_SENTINEL_PPM, "maximum_budget_ppm": 1_000_000,
        "universal_proof": False,
        "kappa_relative_element_worst": kappa_rel_element,
        "kappa_fullscale_element_worst": kappa_full_element,
        "kappa_relative_frobenius": kappa_rel_frob,
        "kappa_fullscale_frobenius": kappa_full_frob,
        "pe_lanes_assumed": PE_LANES,
        "windowed_sweep": sweep,
        "windowed_exactness": WINDOWED_EXACTNESS,
        "entries": rows,
        "unsound": [r["candidate"] for r in rows if r["empirical_holds"] is False],
        "unqualified": [r["candidate"] for r in rows if r["empirical_holds"] is None],
        "vacuous_at_element_granularity": [r["candidate"] for r in rows
                                           if r["element_bound_vacuous"]],
        "unsound_windowed": [r["candidate"] for r in rows
                             if r["empirical_holds_sound_total"] is False],
        # Not a tuning matter: these are candidates whose MEASURED error already
        # exceeds the naive windowed composition, which is the empirical proof
        # that a per-product epsilon cannot be charged once per window.
        "windowed_diagnostic_violations": [r["candidate"] for r in rows
                                           if r["empirical_holds_windowed"] is False],
        "qualified_by_absolute_floor": [r["candidate"] for r in rows
                                        if r["mixed_admissible"] and not r["analytic_admissible"]],
        "windowed_bound_diagnostic_only": [r["candidate"] for r in rows
                                           if not r["windowed_model_applies"]],
        "field_semantics": {
            "matched_bound_ppm": "Unclipped mathematical-formula bound evaluated with float64-reference proxy statistics; FULL first and constant terms are separate.",
            "rtl_matched_bound_ppm": "Integer-ceiled eps times upward-Q8 Frobenius kappa, or 1048575 for invalid/unrepresentable/over-budget bounds. This is a Frobenius-matched helper result, not a per-element RTL guarantee.",
            "rtl_element_worst_bound_ppm": "Integer-ceiled bound using upward-Q8 worst-element kappa; cancellation or unrepresentable metadata fails closed to 1048575.",
            "level_needed_analytic": "Smallest budget level covering the sample-qualified Q8 matched bound; null for failed premises, violations, invalid metadata or bounds above 100%.",
            "holds": "Compatibility alias for empirical_holds: sample comparison only; null when unqualified. Never a universal arithmetic proof.",
            "unsound": "Compatibility list of sample bound violations under checked premises, not a proof that RTL arithmetic is unsound.",
            "kappa_windowed": "(sum_w |s_w| + sum_w |A_w|) / |R| over windows of `window` elements, Frobenius-matched, clamped up to 1. Charges nothing for cancellation inside a window because the RTL reduces a window exactly in a 640-bit integer accumulator; charges for cancellation across windows, which the FP32 accumulator really does suffer.",
            "bound_windowed_ppm": "rtl_eps composed with the windowed kappa. SOUND ONLY where windowed_error_site is per_window; for every candidate in this table the site is per_product, so this column is a DIAGNOSTIC showing what the bound would be if the epsilon were injected at the window boundary instead of at each product.",
            "abs_floor_ppm": "Upward-rounded eta/2 absolute floor, summed over the two operand conversions and the 2*windows-1 reduction rounding sites, expressed in ppm of the Frobenius reference. Purely ADDITIVE: it makes the mixed bound applicable to subnormal and flush-to-zero operands, and tightens nothing.",
            "bound_total_ppm": "bound_windowed_ppm + abs_floor_ppm, i.e. the windowed model as requested. Inherits bound_windowed_ppm's per_product caveat.",
            "bound_sound_total_ppm": "The composition this report admits on: the candidate's per-product epsilon against the per-product Frobenius kappa, PLUS the FP32 reduction roundings against the windowed kappa, PLUS the absolute floor. Strictly looser than rtl_matched_bound_ppm because it adds the accumulation and floor terms rtl_matched_bound_ppm omitted.",
            "level_needed_windowed": "Smallest budget level covering bound_total_ppm; carries the same per_product caveat and is not an admission.",
            "level_needed_sound_total": "Smallest budget level covering bound_sound_total_ppm; this is the level a caller must actually authorise.",
        },
        "note": ("Bound and observation must share a granularity. Mathematical bounds are not clipped "
                 "to 100%; values above the maximum budget are inadmissible. Zero-reference cancellation "
                 "has infinite or undefined kappa, never zero. Global-max full scale and max row/column "
                 "sums use a consistent conservative normalization. Sample empirical holds and float64 "
                 "proxy statistics do not prove universal arithmetic safety or RTL FP32 accumulation. "
                 "The moving-window model matches the RTL's block-floating reduction (W=ceil(K/mac_step) "
                 "windows, 2W-1 roundings, exact integer reduction inside a window) and is therefore the "
                 "right multiplier for the reduction's OWN roundings, which this report now adds. It is "
                 "NOT a licence to charge a per-product epsilon once per window: every candidate here "
                 "perturbs the products before the reduction, so the per-product kappa stays in the "
                 "admitted bound and the windowed column is a diagnostic."),
    }


def evaluate(tile_set):
    """Exact float64 reference; every candidate accumulates exactly."""
    import torch
    if not tile_set:
        raise ValueError("accuracy evaluation requires at least one tile")
    formats = ("FP32", "BF16", "FP16", "FP8_E4M3", "FP8_E5M2", "INT8", "INT4")
    k_bytes = {"FP32": 64, "BF16": 32, "FP16": 32, "FP8_E4M3": 16, "FP8_E5M2": 16,
               "INT8": 16, "INT4": 8}
    report = {"tiles": len(tile_set), "tile_shape": [TILE_M, TILE_N, TILE_K],
              "reference": "float64-reference proxy, not a mathematical exact result",
              "accumulation": "float64 in every candidate; RTL FP32 accumulation not modeled",
              "universal_proof": False,
              "format_narrowing": [], "approximate_multiplier": []}
    refs = [(a @ b) for _, a, b in tile_set]

    for fmt in formats:
        errs = [rel_error(quantize_format(a, fmt) @ quantize_format(b, fmt), ref)
                for (_, a, b), ref in zip(tile_set, refs)]
        errs.sort()
        kb = k_bytes[fmt]
        report["format_narrowing"].append({
            "format": fmt, "k_bytes_at_k16": kb,
            "groups_at_32_lanes": (32 // kb) if kb <= 32 else 0,
            "groups_at_64_lanes": 64 // kb,
            "rel_error_median": errs[len(errs) // 2],
            "rel_error_p95": errs[min(len(errs) - 1, int(0.95 * len(errs)))],
            "rel_error_max": errs[-1],
        })

    for keep in (10, 8, 6, 4, 2):
        errs = [rel_error(truncate_mantissa(a, keep) @ truncate_mantissa(b, keep), ref)
                for (_, a, b), ref in zip(tile_set, refs)]
        errs.sort()
        report["approximate_multiplier"].append({
            "topology": "mantissa_truncated", "mantissa_bits_kept": keep,
            "buys": "multiplier area and depth only; k_bytes and concurrency unchanged",
            "rel_error_median": errs[len(errs) // 2],
            "rel_error_p95": errs[min(len(errs) - 1, int(0.95 * len(errs)))],
            "rel_error_max": errs[-1],
        })

    errs = []
    for (_, a, b), ref in zip(tile_set, refs):
        prod = mitchell_product(a.unsqueeze(2), b.unsqueeze(0)).sum(dim=1)
        errs.append(rel_error(prod, ref))
    errs.sort()
    report["approximate_multiplier"].append({
        "topology": "mitchell_logarithmic",
        "buys": "replaces the multiplier array with an adder; concurrency unchanged",
        "rel_error_median": errs[len(errs) // 2],
        "rel_error_p95": errs[min(len(errs) - 1, int(0.95 * len(errs)))],
        "rel_error_max": errs[-1],
    })
    for row in report["format_narrowing"] + report["approximate_multiplier"]:
        row["status"] = ("finite_sample_errors" if math.isfinite(row["rel_error_max"])
                         else "nonfinite_or_undefined_error")
    return report


# V/A-Turbo heuristic bank.  Entries are DERIVED from the S0 measurements rather
# than invented: each is a (precision_class, groups_log2) pair carrying its own
# measured error, and an entry is admitted only if that error is inside the
# caller's budget.  The bank is what the 3-bit sub-code indexes per group, so a
# bank of 8 covers one sub-code word and 32 covers four groups' worth.
PRECISION_CLASS = {"FP32": 0, "FP16": 1, "INT8": 2}


def emit_bank(report, entries, budget_percent, lanes):
    """Rank measured (precision, groups) options by gain per unit error.

    Refuses anything outside the budget, and refuses precision classes S0 found
    dominated, so the bank cannot silently contain a topology the accuracy study
    already rejected.
    """
    rows = []
    for row in report["format_narrowing"]:
        fmt = row["format"]
        if fmt not in PRECISION_CLASS:
            continue  # BF16/FP8/INT4 are dominated on measured error; see S0.
        groups = (lanes // row["k_bytes_at_k16"]) if row["k_bytes_at_k16"] <= lanes else 0
        if groups < 1:
            continue
        err = row["rel_error_p95"] * 100.0
        if (not math.isfinite(err) or err < 0 or err > budget_percent
                or not math.isfinite(row.get("rel_error_max", row["rel_error_p95"]))):
            continue
        rows.append({
            "precision_class": fmt, "precision_code": PRECISION_CLASS[fmt],
            "groups": groups, "groups_log2": max(0, groups.bit_length() - 1),
            "rel_error_p95_percent": err,
            "concurrency_gain": groups,
            "gain_per_percent_error": (groups / err) if err > 0 else None,
            "measured": True,
        })
    rows.sort(key=lambda r: (-(r["gain_per_percent_error"] or float("inf")), r["precision_code"]))
    bank = rows[:entries]
    # A short bank is reported as short.  Padding it with invented topologies to
    # reach 8 or 32 would be exactly the "stub that looks like a capability"
    # failure the licensing/verification rules warn about.
    return {
        "bank_size_requested": entries, "bank_size_admitted": len(bank),
        "evidence": "empirical_p95_only_no_analytic_admission", "universal_proof": False,
        "lanes_assumed": lanes, "error_budget_percent": budget_percent,
        "entries": bank,
        "unpadded": "A bank shorter than requested is reported short; entries are never invented to fill it",
        "excluded_by_measurement": ["BF16 (10x the FP16 error at identical k_bytes)",
                                    "FP8 E4M3/E5M2 (3.3x/6.5x the INT8 error at identical k_bytes)",
                                    "INT4 (~25% tile error)",
                                    "mantissa truncation and Mitchell (buy no concurrency; S0 lever 2)"],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="S0 accuracy study for AI-island approximate compute (host-only, no RTL)")
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--revision", required=True, type=revision_arg)
    parser.add_argument("--prompt", default="The GSys LibreCore AI island computes a matrix product.")
    parser.add_argument("--layers", type=int, default=6)
    parser.add_argument("--tiles-per-layer", type=int, default=8)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--emit-bank", type=int, metavar="N",
                        help="also emit a V/A-Turbo heuristic bank of up to N measured entries (8..32)")
    parser.add_argument("--error-budget-percent", type=float, default=2.0,
                        help="admit a bank entry only if its measured p95 tile error is within this")
    parser.add_argument("--bank-lanes", type=int, default=64,
                        help="provisioned lanes the bank's group counts assume")
    args = parser.parse_args(argv)
    if args.out and args.out.suffix.lower() != ".json":
        parser.error("report output must be JSON")
    if args.emit_bank is not None and not 8 <= args.emit_bank <= 32:
        parser.error("--emit-bank must be in [8,32]: 8 fills one 3-bit sub-code word, 32 covers four")
    if not 0.0 < args.error_budget_percent <= 100.0:
        parser.error("--error-budget-percent must be in (0,100]")
    if args.bank_lanes not in (8, 16, 32, 64, 128, 256):
        parser.error("--bank-lanes must be a supported power-of-two lane count")
    if not 1 <= args.layers <= 64 or not 1 <= args.tiles_per_layer <= 256:
        parser.error("layers and tiles-per-layer must be small positive counts")

    os.environ["HF_HOME"] = str(args.cache_dir.absolute().parent)
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    snapshot = snapshot_dir(args.cache_dir, args.model_id, args.revision)
    captured = collect_operands(snapshot, args.revision, args.prompt, args.layers)
    tile_set = tiles(captured, args.tiles_per_layer)
    report = evaluate(tile_set)
    report["source"] = {"model_id": args.model_id, "revision": args.revision,
                        "prompt_sha256": hashlib.sha256(args.prompt.encode()).hexdigest(),
                        "modules": sorted({name for name, _, _ in tile_set})}
    report["limitations"] = [
        "Tile-level relative Frobenius error is a PROXY; it is not a perplexity or model-quality claim.",
        "Operands are real activations and weights from one pinned model and one prompt, not a workload distribution.",
        "Format narrowing is the only lever that changes k_bytes and therefore concurrency; the approximate multipliers buy area and depth at unchanged concurrency.",
        "Per-tile scaling is applied for FP8/INT8/INT4, which is what a real path does; without it those formats would measure far worse.",
        "Float64 products, scaling and accumulation are host proxies, not mathematical exact results; RTL FP32 accumulation is not modeled.",
        "Finite normal conversion premises are checked on samples only; subnormal conversion/underflow/overflow is not covered by relative epsilon formulas.",
        "Empirical holds on these tiles is not a universal arithmetic proof; mathematical bounds above 100% remain unclipped and cannot fit any budget.",
        "The moving-window kappa models the RTL's block-floating reduction (exact inside a window, 2W-1 roundings overall) with float64 partial sums, which are themselves rounded; it is a proxy for the exact 640-bit reduction, and it does not model the alignment shift being dropped when a window's exponent spread reaches FP_DOT_MAXW.",
        "The windowed kappa is only a sound multiplier for an epsilon injected AT a window boundary. Every candidate measured here perturbs the products before the reduction, so its per-product kappa is kept in the admitted bound and the windowed column is reported as a diagnostic.",
        "The eta/2 absolute floor is additive and makes the mixed bound applicable to subnormal and flush-to-zero conversions; it does not cover overflow, non-finite operands or integer scales that themselves underflow.",
    ]
    report["bound_validation"] = validate_bounds(report, tile_set)
    if args.emit_bank is not None:
        report["va_turbo_bank"] = emit_bank(report, args.emit_bank,
                                            args.error_budget_percent, args.bank_lanes)
    text = report_json(report)
    if args.out:
        args.out.write_text(text, encoding="utf-8")
    print("S0 ACCURACY STUDY  tiles=%d  shape=%dx%dx%d  reference=float64-reference proxy"
          % (report["tiles"], TILE_M, TILE_N, TILE_K))
    print("\nLever 1 - format narrowing (changes k_bytes, buys concurrency):")
    print("  %-10s %-8s %-7s %-7s %-11s %-11s %s"
          % ("format", "k_bytes", "g@32", "g@64", "err median", "err p95", "err max"))
    for row in report["format_narrowing"]:
        print("  %-10s %-8d %-7s %-7d %-11.3e %-11.3e %.3e"
              % (row["format"], row["k_bytes_at_k16"],
                 row["groups_at_32_lanes"] or ">32", row["groups_at_64_lanes"],
                 row["rel_error_median"], row["rel_error_p95"], row["rel_error_max"]))
    print("\nLever 2 - approximate multipliers (area/depth only, concurrency unchanged):")
    for row in report["approximate_multiplier"]:
        label = row["topology"] + (":%d" % row["mantissa_bits_kept"] if "mantissa_bits_kept" in row else "")
        print("  %-26s err median %-11.3e p95 %-11.3e max %.3e"
              % (label, row["rel_error_median"], row["rel_error_p95"], row["rel_error_max"]))
    if "va_turbo_bank" in report:
        bank = report["va_turbo_bank"]
        print("\nV/A-Turbo bank: %d of %d requested admitted at <=%.2f%% error, %d lanes"
              % (bank["bank_size_admitted"], bank["bank_size_requested"],
                 bank["error_budget_percent"], bank["lanes_assumed"]))
        for i, row in enumerate(bank["entries"]):
            print("  [%d] precision=%-5s code=%d groups=%d (log2=%d) err=%.4f%% gain/%%err=%s"
                  % (i, row["precision_class"], row["precision_code"], row["groups"],
                     row["groups_log2"], row["rel_error_p95_percent"],
                     ("%.1f" % row["gain_per_percent_error"]) if row["gain_per_percent_error"] else "inf"))
        for line in bank["excluded_by_measurement"]:
            print("  excluded: " + line)
    bounds = report["bound_validation"]
    print("\nSample analytic bound comparison (not a universal proof; RTL FP32 accumulation not modeled):")
    print("  kappa per-element worst: relative %.1f, full-scale %.1f  -> bounds are not clipped"
          % (bounds["kappa_relative_element_worst"], bounds["kappa_fullscale_element_worst"]))
    print("  kappa Frobenius-matched: relative %.3f, full-scale %.3f  -> comparable to the metric"
          % (bounds["kappa_relative_frobenius"], bounds["kappa_fullscale_frobenius"]))
    print("  operand flatness fa+fb: %.3f of a worst case 2.0; upward Q8=%d (FULL first term only)"
          % (bounds["flatness_worst"], bounds["flatness_q8"]))
    print("  %-24s %-6s %-10s %-12s %-12s %-6s %-7s %s"
          % ("candidate", "kind", "eps ppm", "bound ppm", "observed", "slack",
             "lvl req", "lvl if tight"))
    for row in bounds["entries"]:
        print("  %-24s %-6s %-10d %-12.0f %-12.0f %-6s %-7s %s%s"
              % (row["candidate"], row["bound_kind"], row["eps_ppm"],
                 row["matched_bound_ppm"], row["observed_max_ppm"],
                 ("%.1fx" % row["slack_factor"]) if row["slack_factor"] else "-",
                 str(row["level_needed_analytic"] or "none"),
                 str(row["level_needed_observed"] or "none"),
                 "   " + row["status"]))
        print("    Q8/RTL helper matched=%d element=%d ppm; empirical_holds=%s"
              % (row["rtl_matched_bound_ppm"], row["rtl_element_worst_bound_ppm"], row["empirical_holds"]))
    print("\nMoving-window (block-floating) model at PeLanes=%d: W=ceil(K/mac_step) windows,"
          % bounds["pe_lanes_assumed"])
    print("  2W-1 roundings, exact 640-bit integer reduction inside a window.")
    print("  %-24s %-4s %-3s %-10s %-9s %-11s %-11s %-8s %-11s %-11s %s"
          % ("candidate", "win", "W", "kappa_elem", "kappa_win", "elem ppm",
             "window ppm", "floor", "total ppm", "measured", "lvl elem/win/sound"))
    for row in bounds["entries"]:
        print("  %-24s %-4d %-3d %-10.3g %-9.3g %-11d %-11d %-8d %-11d %-11.0f %s/%s/%s%s"
              % (row["candidate"], row["window"], row["windows"],
                 row["kappa_element"], row["kappa_windowed"],
                 row["rtl_matched_bound_ppm"], row["bound_windowed_ppm"],
                 row["abs_floor_ppm"], row["bound_total_ppm"], row["observed_max_ppm"],
                 str(row["level_needed_analytic"] or "none"),
                 str(row["level_needed_windowed"] or "none"),
                 str(row["level_needed_sound_total"] or "none"),
                 "   " + row["status_windowed"]))
        print("    sound total (per-product eps x per-product kappa + reduction eps x windowed kappa"
              " + floor) = %d ppm; holds=%s; %s"
              % (row["bound_sound_total_ppm"], row["empirical_holds_sound_total"],
                 row["windowed_error_site"]))
        print("    windowed bound by window size: "
              + "  ".join("w=%d(W=%d) %d ppm lvl %s" % (
                  entry["window"], entry["windows"], entry["bound_total_ppm"],
                  str(level_for(entry["bound_total_ppm"]) or "none"))
                  for entry in row["windowed_bound_sweep"]))
    print("  kappa_windowed sweep (Frobenius-matched, worst tile):")
    for entry in bounds["windowed_sweep"]:
        print("    window=%-3d W=%-3d sites=%-3s kappa=%-12.4g q8=%-6s clamped=%s"
              % (entry["window"], entry["windows"], str(entry["rounding_sites"]),
                 entry["kappa_windowed_frobenius"], str(entry["kappa_windowed_q8"]),
                 entry["clamped"]))
    if bounds["qualified_by_absolute_floor"]:
        print("  QUALIFIED by the added eta/2 absolute floor (previously refused on premises): "
              + ", ".join(bounds["qualified_by_absolute_floor"]))
    if bounds["windowed_bound_diagnostic_only"]:
        print("  windowed bound is DIAGNOSTIC ONLY for %d of %d candidates: their epsilon is injected "
              "per PRODUCT, before the exact reduction, so the windowed kappa would drop real "
              "intra-window cancellation."
              % (len(bounds["windowed_bound_diagnostic_only"]), len(bounds["entries"])))
    if bounds["windowed_diagnostic_violations"]:
        print("  MEASURED ERROR EXCEEDS THE NAIVE WINDOWED BOUND for: "
              + ", ".join(bounds["windowed_diagnostic_violations"])
              + " -- the per-product epsilon demonstrably cannot be charged once per window")
    if bounds["unsound_windowed"]:
        print("  SAMPLE VIOLATIONS OF THE SOUND WINDOWED TOTAL: " + ", ".join(bounds["unsound_windowed"]))
    if bounds["unsound"]:
        print("  SAMPLE BOUND VIOLATIONS (investigate model and premises): " + ", ".join(bounds["unsound"]))
    if bounds["unqualified"]:
        print("  UNQUALIFIED (no empirical bound conclusion): " + ", ".join(bounds["unqualified"]))
    if bounds["vacuous_at_element_granularity"]:
        print("  Inadmissible at per-element granularity (nonfinite or above 100%): "
              + str(len(bounds["vacuous_at_element_granularity"])) + " of "
              + str(len(bounds["entries"])) + " candidates")
    print("\nTile Frobenius error is a proxy, not a model-quality result.")
    if args.out:
        print("artifact: " + str(args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
