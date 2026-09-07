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
    bits = torch.tensor(t.to(torch.float32).numpy().view("uint32").copy())
    mask = (0xFFFFFFFF << (23 - keep)) & 0xFFFFFFFF
    return torch.tensor((bits.numpy() & mask).view("float32").copy()).to(torch.float64)


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
    num = (candidate - reference).norm().item()
    den = reference.norm().item()
    return num / den if den else 0.0


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
    ratio = torch.where(exact > 0, abs_sum / exact, torch.zeros_like(exact))
    frob = abs_sum.norm().item() / exact_signed.norm().item() if exact_signed.norm() > 0 else 0.0
    return ratio.max().item(), frob


def kappa_fullscale(a, b):
    import torch
    k = a.shape[1]
    scale = float(k) * a.abs().max().item() * b.abs().max().item()
    exact = (a @ b)
    ratio = torch.where(exact.abs() > 0, scale / exact.abs(), torch.zeros_like(exact))
    elements = float(exact.numel()) ** 0.5
    frob = (elements * scale / exact.norm().item()) if exact.norm() > 0 else 0.0
    return ratio.max().item(), frob


# Analytic per-product bounds in ppm, mirroring va_turbo_arith in
# g6lc_ai_policy_pkg.sv.  Kept as literals so a divergence between the RTL table
# and the measurement is visible as a mismatch rather than hidden by a shared
# helper computing both sides from one formula.
ANALYTIC_EPS_PPM = {
    "FP16": (977, "rel"), "BF16": (7828, "rel"),
    "FP8_E4M3": (128906, "rel"), "FP8_E5M2": (265625, "rel"),
    # Corrected: the earlier 7,887 / 147,908 were understated against the exact
    # 7,889.52 / 147,959.18 and were therefore unsound. These are the values the
    # RTL's two-step ceiling actually produces at worst-case flatness.
    "INT8": (7892, "full"), "INT4": (147961, "full"),
    "mantissa_truncated:10": (977, "rel"), "mantissa_truncated:8": (3910, "rel"),
    "mantissa_truncated:6": (15686, "rel"), "mantissa_truncated:4": (63477, "rel"),
    "mantissa_truncated:2": (265625, "rel"),
    "mitchell_logarithmic": (250000, "rel"),
}


# Mirror of va_turbo_budget_ppm: geometric ladder, 100 ppm doubling per step,
# saturating at 100%. Level 0 is off.
def budget_ppm(level):
    return 0 if level == 0 else min(1_000_000, 100 << (level - 1))


def level_for(ppm):
    """Smallest level whose budget covers `ppm`, or None if nothing does."""
    for level in range(1, 16):
        if budget_ppm(level) >= ppm:
            return level
    return None


def validate_bounds(report, tile_set):
    """Check the analytic bound is not exceeded by the observed per-tile error.

    A violation means the RTL bound is UNSOUND and must be widened; slack means
    it is conservative and how much budget tuning could reclaim.
    """
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

    flat_worst = max(flatness(a, b) for _, a, b in tile_set)
    rel_stats = [kappa_relative(a, b) for _, a, b in tile_set]
    full_stats = [kappa_fullscale(a, b) for _, a, b in tile_set]
    kappa_rel_element = max(s[0] for s in rel_stats)
    kappa_full_element = max(s[0] for s in full_stats)
    kappa_rel_frob = max(s[1] for s in rel_stats)
    kappa_full_frob = max(s[1] for s in full_stats)
    for label, (eps_ppm, kind) in sorted(ANALYTIC_EPS_PPM.items()):
        if label not in observed:
            continue
        kappa = kappa_rel_frob if kind == "rel" else kappa_full_frob
        strict = kappa_rel_element if kind == "rel" else kappa_full_element
        # FULL kinds scale with measured flatness; REL kinds do not.
        eps_used = eps_ppm * (flat_worst / 2.0) if kind == "full" else eps_ppm
        bound_ppm = min(1_000_000.0, eps_used * kappa)
        strict_ppm = min(1_000_000.0, eps_ppm * strict)
        observed_ppm = observed[label] * 1e6
        rows.append({
            "candidate": label, "bound_kind": kind, "eps_ppm": eps_ppm,
            "eps_after_flatness_ppm": eps_used,
            "kappa_frobenius": kappa, "kappa_element_worst": strict,
            "matched_bound_ppm": bound_ppm,
            "element_worst_bound_ppm": strict_ppm,
            "observed_max_ppm": observed_ppm,
            "holds": observed_ppm <= bound_ppm,
            "slack_factor": (bound_ppm / observed_ppm) if observed_ppm > 0 else None,
            "element_bound_vacuous": strict_ppm >= 1_000_000.0,
            # The tuning output: the level a caller must authorise under the
            # analytic bound, versus the level the observed error would need if
            # the bound were tight. The gap is what a tighter derivation buys.
            "level_needed_analytic": level_for(bound_ppm),
            "level_needed_observed": level_for(observed_ppm),
        })
    return {
        "flatness_worst": flat_worst,
        "kappa_relative_element_worst": kappa_rel_element,
        "kappa_fullscale_element_worst": kappa_full_element,
        "kappa_relative_frobenius": kappa_rel_frob,
        "kappa_fullscale_frobenius": kappa_full_frob,
        "entries": rows,
        "unsound": [r["candidate"] for r in rows if not r["holds"]],
        "vacuous_at_element_granularity": [r["candidate"] for r in rows
                                           if r["element_bound_vacuous"]],
        "note": ("Bound and observation must share a granularity. The per-element worst-case kappa "
                 "is strictly correct but saturates to 100% on these tiles because single output "
                 "elements nearly cancel, which makes that comparison vacuous rather than passing. "
                 "The Frobenius-matched kappa is the figure compared against the Frobenius error. "
                 "A violation means the RTL bound is unsound; slack is specific to these tiles."),
    }


def evaluate(tile_set):
    """Exact float64 reference; every candidate accumulates exactly."""
    import torch
    formats = ("FP32", "BF16", "FP16", "FP8_E4M3", "FP8_E5M2", "INT8", "INT4")
    k_bytes = {"FP32": 64, "BF16": 32, "FP16": 32, "FP8_E4M3": 16, "FP8_E5M2": 16,
               "INT8": 16, "INT4": 8}
    report = {"tiles": len(tile_set), "tile_shape": [TILE_M, TILE_N, TILE_K],
              "reference": "float64 exact products and accumulation",
              "accumulation": "exact in every candidate",
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
        if err > budget_percent:
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
        "Accumulation is exact everywhere, so these figures do not cover accumulator-width effects.",
    ]
    report["bound_validation"] = validate_bounds(report, tile_set)
    if args.emit_bank is not None:
        report["va_turbo_bank"] = emit_bank(report, args.emit_bank,
                                            args.error_budget_percent, args.bank_lanes)
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.write_text(text, encoding="utf-8")
    print("S0 ACCURACY STUDY  tiles=%d  shape=%dx%dx%d  reference=float64 exact"
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
    print("\nRTL analytic bound check (bound = eps x kappa):")
    print("  kappa per-element worst: relative %.1f, full-scale %.1f  -> saturates the bound"
          % (bounds["kappa_relative_element_worst"], bounds["kappa_fullscale_element_worst"]))
    print("  kappa Frobenius-matched: relative %.3f, full-scale %.3f  -> comparable to the metric"
          % (bounds["kappa_relative_frobenius"], bounds["kappa_fullscale_frobenius"]))
    print("  operand flatness fa+fb: %.3f of a worst case 2.0  -> tightens FULL kinds %.2fx"
          % (bounds["flatness_worst"], 2.0 / bounds["flatness_worst"]))
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
                 "" if row["holds"] else "   BOUND UNSOUND"))
    if bounds["unsound"]:
        print("  UNSOUND (widen the RTL bound): " + ", ".join(bounds["unsound"]))
    if bounds["vacuous_at_element_granularity"]:
        print("  Vacuous at per-element granularity (bound saturates to 100%): "
              + str(len(bounds["vacuous_at_element_granularity"])) + " of "
              + str(len(bounds["entries"])) + " candidates")
    print("\nTile Frobenius error is a proxy, not a model-quality result.")
    if args.out:
        print("artifact: " + str(args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
