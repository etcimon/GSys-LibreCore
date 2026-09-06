import argparse
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, replace
from functools import lru_cache
import hashlib
from itertools import product
import json
import math
from pathlib import Path
import re


SCHEMA = "g6lc.policy-capture.v1"
FORMAT_NAMES = {0: "INT8", 1: "INT4", 3: "FP8_E4M3", 4: "FP8_E5M2", 5: "FP16", 6: "BF16", 7: "FP32"}
BITS_LOG2 = (3, 2, 3, 3, 3, 4, 4, 5)
DTYPE_FORMATS = {"int8": 0, "int4": 1, "float8_e4m3fn": 3, "float8_e5m2": 4,
                 "float16": 5, "bfloat16": 6, "float32": 7}
REPLAY_MAX_BYTES = 256 * 1024
REPLAY_MAX_RECORDS = 1024
FORMAT_SLOTS = 0x67788098
FORMAT_STEPS = 0x11111111
FORMAT_MIN_REDUCTION = 0
DEFAULT_GROUP_SHAPES = 0x4420CA
EVALUATION_CYCLES = 32
SWITCH_CYCLES = 2
MIN_SAVINGS_CYCLES = 2
MIN_GAIN = 2
SHARED_DECISION_CYCLES = 1
MAX_RECORDS = 1_000_000
MAX_DIM = (1 << 31) - 1
LEGAL_SHAPES = tuple((r, c) for r in range(5) for c in range(5 - r))
GROUPS = {0: 0, 3: 1, 5: 2, 6: 3}


def ceil_div(a, b):
    return (a + b - 1) // b


def nibble(word, index):
    return (word >> (4 * index)) & 15


def group_shape(word, group):
    value = (word >> (6 * group)) & 63
    return value >> 3, value & 7


def set_group_shape(word, group, shape):
    if shape not in LEGAL_SHAPES or group not in range(4):
        raise ValueError("illegal group shape")
    return (word & ~(63 << (6 * group))) | ((shape[0] * 8 + shape[1]) << (6 * group))


def service_bytes(value):
    if type(value) is not int or not 1 <= value <= 4096 or value & (value - 1):
        raise ValueError("service bytes must be a power of two in [1,4096]")
    return value


def integer(value, name, low=1, high=MAX_DIM):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"invalid {name}: expected integer in [{low},{high}]")
    return value


def text(value, name):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"invalid {name}")
    return value


def hex_digest(value, length, name):
    if not isinstance(value, str) or re.fullmatch(f"[0-9a-fA-F]{{{length}}}", value) is None:
        raise ValueError(f"invalid {name}")
    return value.lower()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f"nonfinite JSON value: {value}")


def finite_tree(value):
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError("nonfinite JSON number")
    if isinstance(value, dict):
        for child in value.values():
            finite_tree(child)
    elif isinstance(value, list):
        for child in value:
            finite_tree(child)


def strict_json_loads(raw):
    value = json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject_constant)
    finite_tree(value)
    return value


def validate_capture(capture):
    try:
        finite_tree(capture)
        if capture["schema"] != SCHEMA:
            raise ValueError("expected real-model policy-capture.v1 schema")
        source, execution, records = capture["source"], capture["execution"], capture["records"]
        for key in ("model_id", "framework_version", "transformers_version"):
            text(source[key], key)
        hex_digest(source["revision"], 40, "revision")
        for key in ("script_sha256", "config_sha256"):
            hex_digest(source[key], 64, key)
        if source["weights"] != "pretrained" or source["framework"] != "pytorch":
            raise ValueError("only captured pretrained PyTorch models are accepted")
        weights = source["weight_sha256"]
        if not isinstance(weights, dict) or not weights:
            raise ValueError("missing weight fingerprints")
        for name, digest in weights.items():
            text(name, "weight name")
            hex_digest(digest, 64, "weight fingerprint")
        if execution["device"] != "cpu" or execution["input_kind"] != "development-prompt":
            raise ValueError("expected CPU development-prompt capture")
        if execution["finite_logits"] is not True:
            raise ValueError("finite logits must be verified by capture")
        dtype = text(execution["dtype"], "dtype").removeprefix("torch.")
        dtype = {"fp32": "float32", "bf16": "bfloat16"}.get(dtype, dtype)
        if dtype not in DTYPE_FORMATS:
            raise ValueError("unsupported execution dtype")
        hex_digest(execution["prompt_sha256"], 64, "prompt hash")
        integer(execution["prefill_tokens"], "prefill_tokens")
        integer(execution["decode_steps"], "decode_steps", 0)
        if not isinstance(records, list) or not 1 <= len(records) <= MAX_RECORDS:
            raise ValueError("capture must contain 1..1000000 records")
        for position, record in enumerate(records):
            index = integer(record["index"], "index", 0, MAX_RECORDS - 1)
            if index != position:
                raise ValueError("record index must equal list position to preserve capture order")
            if record["phase"] not in ("prefill", "decode"):
                raise ValueError("unsupported phase")
            if record["phase"] == "decode" and execution["decode_steps"] == 0:
                raise ValueError("decode record with zero decode steps")
            text(record["operator"], "operator")
            if not isinstance(record["module"], str):
                raise ValueError("module must be a string")
            m, n, k, batch = (integer(record[key], key) for key in ("m", "n", "k", "batch"))
            fmt = integer(record["numfmt"], "numfmt", 0, 7)
            if fmt not in FORMAT_NAMES:
                raise ValueError("unsupported native format (SP24 is not dense)")
            integer(record["opcode_class"], "opcode_class", 0, 1)
            for operand in ("a", "b"):
                dtype_key = operand + "_dtype"
                if dtype_key in record:
                    operand_dtype = text(record[dtype_key], dtype_key).removeprefix("torch.")
                    if DTYPE_FORMATS.get(operand_dtype) != fmt:
                        raise ValueError(f"{dtype_key} does not match native numfmt")
                shape, stride = record[operand + "_shape"], record[operand + "_stride"]
                if not isinstance(shape, list) or not 2 <= len(shape) <= 16:
                    raise ValueError("invalid operand shape")
                if not isinstance(stride, list) or len(stride) != len(shape):
                    raise ValueError("invalid operand stride")
                for dim in shape:
                    integer(dim, "shape dimension")
                for step in stride:
                    integer(step, "stride", 0, (1 << 63) - 1)
            a, b = record["a_shape"], record["b_shape"]
            orientation = record.get("b_matrix_orientation", "normal")
            linear = record["operator"] == "aten.linear.default"
            if orientation != ("transposed" if linear else "normal") or (linear and (len(b) != 2 or batch != 1)):
                raise ValueError("unsupported matrix operand orientation")
            expected_b = [n, k] if linear else [k, n]
            if a[-1] != k or b[-2:] != expected_b or math.prod(a) != batch * m * k or math.prod(b) != batch * k * n:
                raise ValueError("operand shape/count mismatch")
            sample = record["native_sample_hex"]
            if type(record["sample_valid"]) is not bool or record["exact_zero"] is not False:
                raise ValueError("invalid sample flags; exact-zero extrapolation forbidden")
            if record["sample_valid"]:
                if m * k < 8:
                    raise ValueError("valid sample needs eight A elements within one batch matrix")
                hex_digest(sample, 2 * row_bytes(8, fmt), "native sample")
            elif sample != "":
                raise ValueError("invalid sample must be empty")
        other = capture["other_operators"]
        if not isinstance(other, dict):
            raise ValueError("invalid other_operators")
        for name, count in other.items():
            text(name, "other operator")
            integer(count, "operator count", 0, (1 << 63) - 1)
    except (KeyError, TypeError, AttributeError) as error:
        raise ValueError(f"malformed capture: {error}") from error
    return capture


def load_capture(path):
    raw = Path(path).read_bytes()
    capture = validate_capture(strict_json_loads(raw))
    return capture, {"path": str(path), "capture_sha256": hashlib.sha256(raw).hexdigest(),
                     "source": capture["source"], "execution": capture["execution"]}


def check_disjoint(calibration, held_out):
    def identities(captures):
        models, weights = set(), set()
        for capture in captures:
            models.add(capture["source"]["model_id"].strip().casefold())
            weights.update(value.lower() for value in capture["source"]["weight_sha256"].values())
        return models, weights
    cal_models, cal_weights = identities(calibration)
    test_models, test_weights = identities(held_out)
    if cal_models & test_models or cal_weights & test_weights:
        raise ValueError("calibration/held-out leakage: model_id or weight fingerprint overlaps")


def bucket(dim):
    return 0 if dim <= 1 else 1 if dim <= 8 else 2 if dim <= 64 else 3


def raw_code(m, n, k, opcode_class=0):
    if opcode_class == 1:
        return 4
    if m <= 8 and n >= 9 and k >= 9:
        return 3
    return 1 if bucket(n) > bucket(m) else 2 if bucket(m) > bucket(n) else 0


def aligned_log2(dim, cap):
    return max(level for level in range(cap + 1) if dim % (1 << level) == 0)


def reuse_gain(r, c):
    rows, cols = 1 << r, 1 << c
    return 16 * (2 * rows * cols - rows - cols) // (2 * rows * cols)


@dataclass(frozen=True)
class Topology:
    valid: int = 0
    apply: int = 0
    rows: int = 0
    cols: int = 0
    reduction: int = 0
    slots: int = 0
    bits: int = 0
    gain: int = 0

    def pack(self):
        return (self.valid << 22) | (self.apply << 21) | (self.rows << 18) | (self.cols << 15) | (self.reduction << 11) | (self.slots << 7) | (self.bits << 4) | self.gain


def policy_topology(code, fmt, m, n, k, balance=1, read_bytes=128, min_gain=MIN_GAIN, slots=FORMAT_SLOTS):
    if fmt not in FORMAT_NAMES or min(m, n, k) <= 0 or not 1 <= nibble(slots, fmt) <= 9:
        return Topology()
    s = nibble(slots, fmt)
    base = Topology(valid=1, slots=s, reduction=s, bits=BITS_LOG2[fmt])
    row_cap, col_cap = {0: (2, 2), 1: (1, 3), 2: (3, 1), 3: (0, 4), 4: (2, 2), 5: (1, 2), 6: (2, 2)}.get(code, (0, 0))
    r = min(aligned_log2(m, row_cap), s)
    c = min(aligned_log2(n, col_cap), s - r)
    gain = reuse_gain(r, c)
    rm, cm = aligned_log2(m, 4), aligned_log2(n, 4)
    group = min(rm + cm, 4, s)
    br = min(group // 2, rm)
    bc = group - br
    if bc > cm:
        bc, br = cm, group - cm
    bg = reuse_gain(br, bc)
    if bg > gain or (bg == gain and group > r + c):
        r, c, gain = br, bc, bg
    base_step = (m + n) * row_bytes(min(k, 1 << s), fmt)
    if (code != 7 and (balance != 0 or code == 3) and r + c != 0 and max(m, n) >= 8
            and gain >= min_gain and (k <= (1 << (s - 1)) or base_step >= read_bytes)):
        return replace(base, apply=1, rows=r, cols=c, reduction=s-r-c, gain=gain)
    return base


def row_bytes(elements, fmt):
    return ceil_div(elements * (1 << BITS_LOG2[fmt]), 8)


def native_cost(m, n, k, fmt, topology, read_bytes=128):
    rows, cols, depth = 1 << topology.rows, 1 << topology.cols, 1 << topology.reduction
    if m % rows or n % cols:
        raise ValueError("native cost requires divisible output groups")
    full, tail = divmod(k, depth)
    step = nibble(FORMAT_STEPS, fmt)
    full_service = max(step, ceil_div((rows + cols) * row_bytes(depth, fmt), read_bytes))
    tail_service = max(step, ceil_div((rows + cols) * row_bytes(tail, fmt), read_bytes)) if tail else 0
    return (m // rows) * (n // cols) * (full * full_service + tail_service)


def masked_native_cost(m, n, k, fmt, topology, read_bytes=128):
    def fragments(dim, quantum):
        full, tail = divmod(dim, quantum)
        return ((quantum, full), (tail, int(tail != 0)))

    cycles, macs = 0, 0
    for (r, nr), (c, nc), (d, nd) in product(
            fragments(m, 1 << topology.rows), fragments(n, 1 << topology.cols),
            fragments(k, 1 << topology.reduction)):
        count = nr * nc * nd
        if count:
            cycles += count * max(nibble(FORMAT_STEPS, fmt), ceil_div((r+c) * row_bytes(d, fmt), read_bytes))
            macs += count * r * c * d
    if macs != m*n*k:
        raise ValueError("masked diagnostic lost useful MACs")
    return cycles


def candidate_topology(base, shape):
    r, c = shape
    return replace(base, rows=r, cols=c, reduction=base.slots-r-c, apply=int(r+c != 0), gain=reuse_gain(r, c))


def legal_shape(m, n, base, shape):
    r, c = shape
    return shape in LEGAL_SHAPES and r+c <= base.slots and m % (1 << r) == 0 and n % (1 << c) == 0


@lru_cache(maxsize=65536)
def select_subcode(code, fmt, m, n, k, groups=DEFAULT_GROUP_SHAPES, read_bytes=128):
    base = policy_topology(code, fmt, m, n, k, read_bytes=read_bytes)
    if not base.valid:
        raise ValueError("invalid native topology")
    baseline = native_cost(m, n, k, fmt, base, read_bytes)
    eligible = code in GROUPS and max(m, n, k) <= 256
    costs = [None] * 8
    costs[0] = baseline
    best, winner, selected = baseline, 0, base
    if eligible:
        shapes = [(base.rows, base.cols), (0, 0), (0, 4), (1, 3), (2, 2), (3, 1), (4, 0), group_shape(groups, GROUPS[code])]
        for index, shape in enumerate(shapes[1:], 1):
            if legal_shape(m, n, base, shape):
                candidate = candidate_topology(base, shape)
                cost = native_cost(m, n, k, fmt, candidate, read_bytes)
                costs[index] = cost
                if cost < best:
                    best, winner, selected = cost, index, candidate
        if not (winner and best + SWITCH_CYCLES + EVALUATION_CYCLES + MIN_SAVINGS_CYCLES < baseline):
            winner, selected = 0, base
    modeled = (best + SWITCH_CYCLES if winner else baseline) + (EVALUATION_CYCLES if eligible else 0)
    return {"evaluated": eligible, "subcode": winner, "baseline": baseline, "selected": modeled,
            "baseline_topology": base.pack(), "topology": selected.pack(), "candidate_costs": tuple(costs),
            "rtl_baseline_cycles": baseline if eligible else 0, "rtl_selected_cycles": modeled if eligible else 0}


def axis_tiles(dim):
    full, tail = divmod(dim, 256)
    return ([(256, full)] if full else []) + ([(tail, 1)] if tail else [])


@dataclass(frozen=True, order=True)
class Work:
    model: str
    phase: str
    fmt: int
    code: int
    m: int
    n: int
    k: int

    def macs(self):
        return self.m * self.n * self.k


def tile_captures(captures):
    work, stats = Counter(), Counter()
    for capture in captures:
        validate_capture(capture)
        for record in capture["records"]:
            stats["source_records"] += 1
            m, n, k, batch = (record[key] for key in ("m", "n", "k", "batch"))
            stats["useful_macs"] += m * n * k * batch
            stats["sample_discarded_records"] += int(record["sample_valid"])
            for (tm, mc), (tn, nc), (tk, kc) in product(axis_tiles(m), axis_tiles(n), axis_tiles(k)):
                count = mc * nc * kc * batch
                item = Work(capture["source"]["model_id"], record["phase"], record["numfmt"], raw_code(tm, tn, tk, record["opcode_class"]), tm, tn, tk)
                work[item] += count
                stats["independent_tile_count"] += count
                if len(work) > MAX_RECORDS:
                    raise ValueError("more than 1000000 aggregated tile records")
    if sum(item.macs() * count for item, count in work.items()) != stats["useful_macs"]:
        raise AssertionError("tiling did not conserve useful MACs")
    return work, dict(stats)


def external_traffic(item):
    return (item.m + item.n) * row_bytes(item.k, item.fmt) + 8 * item.m * item.n


def roofline_cycles(item, read_bytes=128, external_bytes=8):
    slots = 1 << nibble(FORMAT_SLOTS, item.fmt)
    minimum_ab = (item.m + item.n) * row_bytes(item.k, item.fmt)
    compute = ceil_div(item.macs() * nibble(FORMAT_STEPS, item.fmt), slots)
    read = ceil_div(minimum_ab, read_bytes)
    return SHARED_DECISION_CYCLES + ceil_div(external_traffic(item), external_bytes) + max(compute, read)


def oracle_cost(item, read_bytes=128):
    base = policy_topology(item.code, item.fmt, item.m, item.n, item.k, read_bytes=read_bytes)
    return min(native_cost(item.m, item.n, item.k, item.fmt, candidate_topology(base, shape), read_bytes)
               for shape in LEGAL_SHAPES if legal_shape(item.m, item.n, base, shape))


def masked_oracle_cost(item, read_bytes=128):
    base = policy_topology(item.code, item.fmt, item.m, item.n, item.k, read_bytes=read_bytes)
    return min(masked_native_cost(item.m, item.n, item.k, item.fmt, candidate_topology(base, shape), read_bytes)
               for shape in LEGAL_SHAPES if sum(shape) <= base.slots)


def fit_groups(calibration_work, read_bytes=128):
    service_bytes(read_bytes)
    groups, objectives = DEFAULT_GROUP_SHAPES, []
    for group in range(4):
        items = [(item, count) for item, count in sorted(calibration_work.items()) if GROUPS.get(item.code) == group]
        current = group_shape(DEFAULT_GROUP_SHAPES, group)
        options = [current] + [shape for shape in LEGAL_SHAPES if shape != current]
        scores = []
        for shape in options:
            params = set_group_shape(groups, group, shape)
            cost = sum(count * select_subcode(item.code, item.fmt, item.m, item.n, item.k, params, read_bytes)["selected"] for item, count in items)
            scores.append((cost, shape))
        best_cost, best_shape = min(scores, key=lambda pair: pair[0])
        groups = set_group_shape(groups, group, best_shape)
        objectives.append({"group": group, "observed_tile_count": sum(count for _, count in items),
                           "shape": list(best_shape), "selected_native_cycles": best_cost,
                           "default_selected_native_cycles": scores[0][0]})
    return groups, objectives


def deltas(baseline_cycles, selected_cycles):
    ratio = baseline_cycles / selected_cycles
    normalized = selected_cycles / baseline_cycles
    return {"normalized_time": normalized, "time_delta_percent": (normalized - 1) * 100,
            "time_reduction_percent": (1 - normalized) * 100, "throughput_ratio": ratio,
            "throughput_delta_percent": (ratio - 1) * 100}


def summarize(totals):
    result = dict(totals)
    baseline = totals["existing_allocator_cycles"]
    macs = totals["useful_macs"]
    result["metrics"] = {}
    for name in ("existing_allocator", "current_default_subcode", "autotuned_subcode", "oracle_diagnostic",
                 "masked_tail_oracle_diagnostic"):
        cycles = totals[name + "_cycles"]
        result["metrics"][name] = {"mac_per_cycle": macs / cycles, **deltas(baseline, cycles)}
    result["autotuned_vs_current_default"] = deltas(totals["current_default_subcode_cycles"], totals["autotuned_subcode_cycles"])
    upper = baseline / totals["roofline_lower_bound_cycles"]
    result["maximum_possible_throughput_ratio"] = upper
    result["maximum_possible_throughput_delta_percent"] = (upper - 1) * 100
    result["target_ratio"] = 6.0
    result["model_feasibility"] = ("impossible_under_fixed_service_assumptions" if upper < 6
                                   else "not_ruled_out_by_bound_not_demonstrated")
    result["modeled_target_met"] = totals["autotuned_subcode_cycles"] * 6 <= baseline
    return result


def report_work(work, groups, read_bytes=128, external_bytes=8):
    total, partitions, codes = Counter(), defaultdict(Counter), defaultdict(Counter)
    for item, count in sorted(work.items()):
        current = select_subcode(item.code, item.fmt, item.m, item.n, item.k, DEFAULT_GROUP_SHAPES, read_bytes)
        tuned = select_subcode(item.code, item.fmt, item.m, item.n, item.k, groups, read_bytes)
        traffic = external_traffic(item)
        fixed = ceil_div(traffic, external_bytes) + SHARED_DECISION_CYCLES
        values = {"independent_tile_count": count, "useful_macs": item.macs() * count,
                  "external_traffic_bytes": traffic * count, "fixed_external_and_decision_cycles": fixed * count,
                  "existing_allocator_cycles": (fixed + current["baseline"]) * count,
                  "current_default_subcode_cycles": (fixed + current["selected"]) * count,
                  "autotuned_subcode_cycles": (fixed + tuned["selected"]) * count,
                  "oracle_diagnostic_cycles": (fixed + oracle_cost(item, read_bytes)) * count,
                  "masked_tail_oracle_diagnostic_cycles": (fixed + masked_oracle_cost(item, read_bytes)) * count,
                  "roofline_lower_bound_cycles": roofline_cycles(item, read_bytes, external_bytes) * count,
                  "evaluated_tile_count": int(tuned["evaluated"]) * count,
                  "improved_vs_gate_off_tile_count": int(tuned["selected"] < current["baseline"]) * count,
                  "regressed_vs_gate_off_tile_count": int(tuned["selected"] > current["baseline"]) * count}
        total.update(values)
        partitions[(item.model, item.phase, item.fmt)].update(values)
        codes[item.code].update(tile_count=count, useful_macs=item.macs() * count,
                               baseline_cycles=(fixed + current["baseline"]) * count)
    return {"total": summarize(total), "raw_policy_usage": [
        {"code": code, "tile_count": codes[code]["tile_count"],
         "tile_share_percent": 100 * codes[code]["tile_count"] / total["independent_tile_count"],
         "useful_mac_share_percent": 100 * codes[code]["useful_macs"] / total["useful_macs"],
         "baseline_cycle_share_percent": 100 * codes[code]["baseline_cycles"] / total["existing_allocator_cycles"]}
        for code in range(8)], "per_model_phase_format": [
        {"model_id": model, "phase": phase, "numfmt": fmt, "format": FORMAT_NAMES[fmt], **summarize(values)}
        for (model, phase, fmt), values in sorted(partitions.items())]}


def replay_cases(work, groups, read_bytes=128):
    cases, improved_seen = [], 0
    for index, (item, count) in enumerate(sorted(work.items())):
        default = select_subcode(item.code, item.fmt, item.m, item.n, item.k, DEFAULT_GROUP_SHAPES, read_bytes)
        tuned = select_subcode(item.code, item.fmt, item.m, item.n, item.k, groups, read_bytes)
        improved = tuned["selected"] < default["selected"] or tuned["selected"] < tuned["baseline"]
        improved_seen += int(improved)
        if index >= 64 and not improved:
            continue
        cases.append({**asdict(item), "numfmt": item.fmt, "opcode_class": int(item.code == 4),
                      "balance": 1, "count": count, "GroupShapeLog2": groups,
                      "baseline": tuned["baseline_topology"], "expected": tuned,
                      "default_expected": default})
    return {"coverage": "sample, not full ordered trace: first 64 aggregate cases plus all improved aggregate cases",
            "aggregate_case_bound": MAX_RECORDS, "improved_aggregate_cases": improved_seen, "cases": cases}


def calibrate(calibration, held_out, read_bytes=128, external_bytes=8):
    service_bytes(read_bytes)
    service_bytes(external_bytes)
    if not calibration or not held_out:
        raise ValueError("nonempty calibration and held-out model sets are required")
    for capture in calibration + held_out:
        validate_capture(capture)
    check_disjoint(calibration, held_out)
    cal_work, cal_stats = tile_captures(calibration)
    groups, objectives = fit_groups(cal_work, read_bytes)
    test_work, test_stats = tile_captures(held_out)
    return {"schema": "g6lc.policy-calibration.v1", "target_ratio": 6.0,
            "target_description": "Aim for +500% MAC/s (6x) at unchanged clock; not a guarantee or live measurement",
            "recommended_enable": False,
            "enable_blockers": ["No live PE integration evidence", "No end-to-end timing proof"],
            "parameters": {"GroupShapeLog2": groups, "GroupShapeLog2_hex": f"0x{groups:06x}",
                           "default_GroupShapeLog2": DEFAULT_GROUP_SHAPES},
            "service_assumptions": {"ReadBytesPerCycle": read_bytes, "ExternalBytesPerCycle": external_bytes,
                "FormatSlotsLog2": FORMAT_SLOTS, "FormatStepCycles": FORMAT_STEPS,
                "FormatMinReductionLog2": FORMAT_MIN_REDUCTION, "EvaluationCycles": EVALUATION_CYCLES,
                "SwitchCycles": SWITCH_CYCLES, "MinSavingsCycles": MIN_SAVINGS_CYCLES,
                "MinGain16ths": MIN_GAIN, "shared_decision_cycles": SHARED_DECISION_CYCLES,
                "accounting": "Serial external service + native service + one shared decision cycle per independent tile; no overlap credit",
                "baseline": "Raw-code topology existing allocator, PolicySubcodeEn gate OFF; balance=1; not full codec hysteresis timing proof",
                "partial_spill": "Independent K tiles each read+write C (8*M*N bytes), same for all paths; no inter-tile reuse credit",
                "sample_discard_reason": "First-eight-A sample is not tile-local proof; all samples ignored even for untiled jobs; no sparse/zero-skip credit",
                "precision": "Native captured formats preserved; no implicit quantization or extrapolated sparsity",
                "hardware_eligibility": "Format slots and service are scheduling-model profiles, not live dtype grants; captures do not authorize hardware execution",
                "prediction": "No successor or prefetch credit",
                "roofline": "Same fixed external traffic + shared decision + max(ceil(useful_MACs*format_step/S_f), ceil(minimum_A_plus_B_bytes/read_bytes)) per tile",
                "oracle": "Diagnostic all legal output shapes per tile, free selection without evaluation/switch cost; not deployable",
                "masked_tail_oracle": "Exploratory active-lane output tails over all 15 shapes; not supported by current subcode RTL, no bank/port cost or selection overhead; not used for fitting/export or a measured gain",
                "provenance": "Capture schema and hashes validated structurally; self-reported pretrained execution is not cryptographically authenticated"},
            "fitting": {"data": "calibration only; actual multiplicity weighted sum of selected modeled cycles; invariant external/decision costs do not affect minimizer",
                        "tie_break": "Keep current default on ties, then ascending (rows_log2,cols_log2)", "groups": objectives},
            "calibration": {"capture_counts": cal_stats, **report_work(cal_work, groups, read_bytes, external_bytes)},
            "held_out": {"capture_counts": test_stats, **report_work(test_work, groups, read_bytes, external_bytes)},
            "sources": {"calibration": [c["source"] for c in calibration], "held_out": [c["source"] for c in held_out]},
            "rtl_replay": {"calibration": replay_cases(cal_work, groups, read_bytes),
                           "held_out": replay_cases(test_work, groups, read_bytes)}}


def replay_export(report):
    parameters = {key: report["service_assumptions"][key] for key in (
        "ReadBytesPerCycle", "MinSavingsCycles", "SwitchCycles", "FormatStepCycles", "FormatMinReductionLog2")}
    parameters["GroupShapeLog2"] = report["parameters"]["GroupShapeLog2"]
    records, seen, sample_count, weighted_count = [], set(), 0, 0
    split_counts = {}
    for split in ("calibration", "held_out"):
        cases = report["rtl_replay"][split]["cases"]
        split_counts[split] = len(cases)
        for case in cases:
            expected = case["expected"]
            record = {key: case[key] for key in ("m", "n", "k", "numfmt", "code", "balance")}
            record.update(baseline_topology=case["baseline"], subcode=expected["subcode"],
                          selected_topology=expected["topology"], baseline_cycles=expected["rtl_baseline_cycles"],
                          selected_cycles=expected["rtl_selected_cycles"])
            sample_count += 1
            weighted_count += case["count"]
            signature = tuple(record.values())
            if signature not in seen:
                seen.add(signature)
                records.append(record)
                if len(records) > REPLAY_MAX_RECORDS:
                    raise ValueError("closed replay exceeds 1024 distinct records; refusing to truncate")
    if not records:
        raise ValueError("closed replay requires at least one record")
    replay = {"schema": "g6lc.policy-subcode-replay.v1", "parameters": parameters, "records": records}
    raw = (json.dumps(replay, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
    if len(raw) > REPLAY_MAX_BYTES:
        raise ValueError("closed replay exceeds 256 KiB; refusing to truncate")
    coverage = {"description": "Sample, not full ordered trace or weighted benchmark: distinct RTL records from calibration and held-out first-64-plus-improved aggregate samples",
                "sample_aggregate_cases": sample_count, "sample_weighted_tile_count": weighted_count,
                "distinct_replay_records": len(records), "sample_aggregate_cases_by_split": split_counts,
                "duplicate_records_removed": sample_count - len(records), "truncated": False}
    return raw, coverage


def protect_outputs(outputs, sources):
    protected = list(sources) + [Path(__file__)]
    for output in outputs:
        for source in protected:
            if output.resolve() == source.resolve() or (output.exists() and source.exists() and output.samefile(source)):
                raise ValueError("outputs must not alias source files or each other")
        if not output.parent.is_dir() or (output.exists() and not output.is_file()):
            raise ValueError("output must be a file in an existing directory")
        protected.append(output)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Offline captured-model GroupShapeLog2 autotuning; 6x is a target, never a guarantee")
    parser.add_argument("--calibration", nargs="+", required=True, type=Path)
    parser.add_argument("--held-out", nargs="+", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--replay-out", type=Path, help="Optional closed RTL replay sample; fail above 1024 distinct records or 256 KiB")
    parser.add_argument("--read-bytes", type=int, default=128)
    parser.add_argument("--external-bytes", type=int, default=8)
    args = parser.parse_args(argv)
    try:
        outputs = [args.out] + ([args.replay_out] if args.replay_out else [])
        protect_outputs(outputs, args.calibration + args.held_out)
        loaded_cal = [load_capture(path) for path in args.calibration]
        loaded_test = [load_capture(path) for path in args.held_out]
        result = calibrate([value[0] for value in loaded_cal], [value[0] for value in loaded_test], args.read_bytes, args.external_bytes)
        result["capture_provenance"] = {"calibration": [value[1] for value in loaded_cal], "held_out": [value[1] for value in loaded_test]}
        result["calibrator_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        if args.replay_out:
            replay_raw, coverage = replay_export(result)
            result["replay_provenance"] = {"path": str(args.replay_out), "schema": "g6lc.policy-subcode-replay.v1",
                "sha256": hashlib.sha256(replay_raw).hexdigest(), "bytes": len(replay_raw), "coverage": coverage}
        serialized_report = json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n"
        if args.replay_out:
            args.replay_out.write_bytes(replay_raw)
        args.out.write_text(serialized_report, encoding="utf-8")
        for name in ("calibration", "held_out"):
            total = result[name]["total"]
            ratio = total["metrics"]["autotuned_subcode"]["throughput_ratio"]
            print(f"{name}: modeled {ratio:.6f}x gate-OFF throughput; fixed-service upper bound {total['maximum_possible_throughput_ratio']:.6f}x; target 6x: {total['model_feasibility']}")
        print("recommended_enable=false: offline cost model is not live PE/timing evidence")
    except (ValueError, OSError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
