"""SPDX-FileCopyrightText: 2026 Etienne Cimon
SPDX-License-Identifier: MIT
"""

import argparse
from collections import Counter
from dataclasses import asdict, dataclass
from fractions import Fraction
import hashlib
from itertools import product
import json
import math
from pathlib import Path

import policy_calibration as calibration


SCHEMA = "g6lc.policy-motifs.v1"
FEEDBACK_SCHEMA = "g6lc.policy-motif-feedback.v1"
TEMPLATE_SCHEMA = "g6lc.policy-motif-template.v1"
RANK_FIELDS = ("predicted_net_gain_cycles", "baseline_cycle_weight", "useful_mac_weight", "observed_support")
GROUP_NAMES = ("bulk", "wide", "tall", "decode", "attention", "routed", "sparse", "movement")
FIXED_SHAPES = {1: (0, 0), 2: (0, 4), 3: (1, 3), 4: (2, 2), 5: (3, 1), 6: (4, 0)}
EPILOGUES = {"aten.add.Tensor": "add", "aten.mul.Tensor": "mul", "aten.gelu.default": "gelu",
             "aten.silu.default": "silu", "aten.layer_norm.default": "layer_norm",
             "aten.native_layer_norm.default": "layer_norm"}
GATHERS = {"aten.gather.default", "aten.index.Tensor", "aten.index_select.default", "aten.take.default"}
TAXES = ("lookup", "switch", "mispredict", "topology")


@dataclass(frozen=True)
class Settings:
    Window: int = 16
    Warmup: int = 8
    HoldWindows: int = 2
    Cooldown: int = 2
    MaxMotifs: int = 32
    MinRealizedGain16ths: int = 8
    MaxGainSpread16ths: int = 8

    def __post_init__(self):
        calibration.integer(self.Window, "Window", 2, 256)
        calibration.integer(self.Warmup, "Warmup", 1, self.Window)
        calibration.integer(self.HoldWindows, "HoldWindows", 1, 256)
        calibration.integer(self.Cooldown, "Cooldown", 0, 256)
        calibration.integer(self.MaxMotifs, "MaxMotifs", 1, 32)
        calibration.integer(self.MinRealizedGain16ths, "MinRealizedGain16ths", 1, 16)
        calibration.integer(self.MaxGainSpread16ths, "MaxGainSpread16ths", 0, 16)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     allow_nan=False).encode("utf-8")).hexdigest()


def profile():
    return {"ReadBytesPerCycle": 128, "ExternalBytesPerCycle": 8,
            "FormatSlotsLog2": calibration.FORMAT_SLOTS, "FormatStepCycles": calibration.FORMAT_STEPS,
            "FormatMinReductionLog2": calibration.FORMAT_MIN_REDUCTION,
            "EvaluationCycles": calibration.EVALUATION_CYCLES, "SwitchCycles": calibration.SWITCH_CYCLES,
            "MinSavingsCycles": calibration.MIN_SAVINGS_CYCLES, "MinGain16ths": calibration.MIN_GAIN,
            "SharedDecisionCycles": calibration.SHARED_DECISION_CYCLES,
            "accounting": "independent_tiles_serial_external_and_native_no_overlap_no_zero_skip"}


def ordered_events(capture):
    walk = capture.get("operator_walk")
    if walk is None:
        return None
    if not isinstance(walk, list) or not len(capture["records"]) <= len(walk) <= calibration.MAX_RECORDS:
        raise ValueError("invalid operator_walk length")
    matrices = 0
    others = Counter()
    try:
        for index, event in enumerate(walk):
            if calibration.integer(event["index"], "operator index", 0) != index:
                raise ValueError("operator_walk must preserve contiguous order")
            calibration.text(event["operator"], "operator")
            if not isinstance(event["module"], str):
                raise ValueError("operator module must be a string")
            if event["kind"] == "matrix":
                if calibration.integer(event["matrix_index"], "matrix_index", 0) != matrices:
                    raise ValueError("operator_walk matrix order mismatch")
                record = capture["records"][matrices]
                if any(event[key] != record[key] for key in ("operator", "module")):
                    raise ValueError("operator_walk matrix correlation mismatch")
                matrices += 1
            elif event["kind"] == "other" and "matrix_index" not in event:
                others[event["operator"]] += 1
            else:
                raise ValueError("invalid operator_walk kind or matrix_index")
        if matrices != len(capture["records"]) or others != Counter(capture["other_operators"]):
            raise ValueError("operator_walk must cover matrix and aggregate other operators exactly")
    except (KeyError, IndexError, TypeError) as error:
        raise ValueError(f"malformed operator_walk: {error}") from error
    return walk


def record_feature(record, previous=None):
    shape = [record[key] for key in ("m", "n", "k", "batch")]
    same_format = previous is not None and previous["numfmt"] == record["numfmt"]
    continuous = same_format and all(previous[key] == record[key] for key in ("m", "n", "k", "batch"))
    reuse = "unknown"
    if same_format:
        reuse_a = all(previous[key] == record[key] for key in ("a_shape", "a_stride"))
        reuse_b = all(previous[key] == record[key] for key in ("b_shape", "b_stride"))
        reuse = "both" if reuse_a and reuse_b else "a" if reuse_a else "b" if reuse_b else "neither"
    semantic = record.get("semantic_metadata", {})
    routed = (isinstance(semantic, dict) and semantic.get("routed") is True
              and isinstance(semantic.get("routing_id"), str) and bool(semantic["routing_id"].strip())
              and isinstance(semantic.get("expert_id"), str) and bool(semantic["expert_id"].strip()))
    return {"buckets": [calibration.bucket(dim) for dim in shape[:3]], "shape": shape,
            "dtype": calibration.FORMAT_NAMES[record["numfmt"]], "numfmt": record["numfmt"],
            "opcode": record["opcode_class"], "operator": record["operator"], "module": record["module"],
            "phase": record["phase"], "epoch": record.get("epoch", 0),
            "groupcode": calibration.raw_code(*shape[:3], record["opcode_class"]),
            "shape_continuity": bool(continuous), "reuse_axis_hypothesis": reuse,
            "operand_layout": {key: record[key] for key in ("a_shape", "b_shape", "a_stride", "b_stride")},
            "b_matrix_orientation": record.get("b_matrix_orientation", "normal"),
            "routed_metadata": semantic if routed else None}


def recognize(records, events, settings=Settings(), previous=None):
    if not 1 <= len(records) <= settings.Window:
        raise ValueError("recognition window outside bound")
    features = [record_feature(record, records[i-1] if i else previous) for i, record in enumerate(records)]
    previous_feature = record_feature(previous) if previous is not None else None
    transitions = ([previous_feature] if previous_feature is not None else []) + features
    ngrams = []
    for width in (2, 3, 4):
        tokens = [(f["groupcode"], f["operator"], f["numfmt"], f["phase"]) for f in features]
        counts = Counter(tuple(tokens[i:i+width]) for i in range(len(tokens)-width+1))
        ngrams.extend({"tokens": [list(token) for token in gram], "support": count}
                      for gram, count in sorted(counts.items()) if count >= 2)
    linear_count = sum(f["operator"] in ("aten.linear.default", "aten.mm.default", "aten.addmm.default")
                       and f["opcode"] == 0 for f in features)
    attention_count = sum(f["opcode"] == 1 for f in features)
    transition = any(a["phase"] == "prefill" and b["phase"] == "decode" for a, b in zip(transitions, transitions[1:]))
    routed = any(a["routed_metadata"] is not None and b["routed_metadata"] is not None
                 and a["routed_metadata"]["routing_id"] == b["routed_metadata"]["routing_id"]
                 for a, b in zip(transitions, transitions[1:]))
    epilogues, gathers, selects, event_count = [], set(), 0, 0
    event_hash = hashlib.sha256()
    if events is not None:
        last_matrix, cluster = None, []
        for event in events:
            event_count += 1
            event_hash.update(bytes.fromhex(digest({key: event[key] for key in ("operator", "module", "kind")})))
            if event["kind"] == "matrix":
                if cluster and len(epilogues) < settings.Window:
                    epilogues.append(cluster)
                last_matrix, cluster = event["operator"], []
            else:
                name = event["operator"]
                if last_matrix and name in EPILOGUES:
                    if len(cluster) < settings.Window:
                        cluster.append(EPILOGUES[name])
                else:
                    if cluster and len(epilogues) < settings.Window:
                        epilogues.append(cluster)
                    last_matrix, cluster = None, []
                if name in GATHERS:
                    gathers.add(name)
                selects += int(name == "aten.select.int")
        if cluster and len(epilogues) < settings.Window:
            epilogues.append(cluster)
    kinds = {"low_level_buckets": "observed", "recurring_group_operator_ngrams": "observed" if ngrams else "not_observed",
             "prefill_to_decode": "observed" if transition else "not_observed",
             "repeated_linear": "hypothesis" if linear_count >= 2 else "not_observed",
             "repeated_attention": "hypothesis" if attention_count >= 2 else "not_observed",
             "routed_burst": "explicit_metadata_hypothesis" if routed else "uncaptured",
             "epilogue_cluster": "ordered_operator_hypothesis" if epilogues else "not_observed",
             "irregular_gather": "ordered_operator_hypothesis" if gathers else "not_observed"}
    event_features = None if events is None else {"sha256": event_hash.hexdigest(), "event_count": event_count}
    signature = digest({"schema": SCHEMA, "settings": asdict(settings), "features": features,
                        "previous_feature": previous_feature, "events": event_features})
    return {"signature": signature, "features": features, "previous_feature": previous_feature,
            "kinds": kinds, "recurring_ngrams": ngrams,
            "epilogue_kinds": epilogues, "gather_operators": sorted(gathers), "selection_view_count": selects,
            "ordered_event_fingerprint": event_features,
            "ordered_nonmatrix_observed": events is not None,
            "recognition_confidence": {"basis": "ordered_capture_structure_not_code_or_performance_proof",
                                       "recurrence_count": sum(row["support"] for row in ngrams),
                                       "reuse": "matching_shapes_and_strides_not_tensor_identity",
                                       "gather": "operator_family_only_no_index_values_or_irregularity_proof"}}


def matrix_family(feature):
    if feature["opcode"] == 1:
        return "attention_matrix_hypothesis"
    if feature["operator"] in ("aten.linear.default", "aten.mm.default", "aten.addmm.default"):
        return "linear_matrix_hypothesis"
    if feature["operator"] in ("aten.bmm.default", "aten.baddbmm.default", "aten.matmul.default"):
        return "batched_matrix"
    return "unclassified_matrix"


def structural_template(recognition, code):
    calibration.integer(code, "groupcode", 0, 7)
    sequence = []
    for feature in recognition["features"]:
        axes = [calibration.axis_tiles(dim) for dim in feature["shape"][:3]]
        tile_codes = {calibration.raw_code(m, n, k, feature["opcode"])
                      for (m, _), (n, _), (k, _) in product(*axes)}
        if code not in tile_codes:
            continue
        token = {"numfmt": feature["numfmt"], "phase": feature["phase"],
                 "source_raw_group": feature["groupcode"], "buckets": feature["buckets"],
                 "rc_residue_mod16": [dim % 16 for dim in feature["shape"][:2]],
                 "matrix_family": matrix_family(feature), "reuse_axis_hypothesis": feature["reuse_axis_hypothesis"],
                 "explicit_routed_metadata": feature["routed_metadata"] is not None}
        if not sequence or token != sequence[-1]:
            sequence.append(token)
    if not sequence:
        raise ValueError("template group does not occur in the window")
    template = {"schema": TEMPLATE_SCHEMA, "groupcode": code, "collapsed_sequence": sequence}
    return {"template_key": digest(template), "template": template}


def windows(capture, settings):
    walk = ordered_events(capture)
    positions = [event["index"] for event in walk if event["kind"] == "matrix"] if walk is not None else []
    records = capture["records"]
    for start in range(0, len(records), settings.Window):
        end = min(start + settings.Window, len(records))
        events = None if walk is None else walk[(positions[start] if start else 0):(positions[end] if end < len(records) else len(walk))]
        yield start, records[start:end], recognize(records[start:end], events, settings, records[start-1] if start else None)


def window_work(capture, records):
    local = {**capture, "records": [{**record, "index": index} for index, record in enumerate(records)]}
    return calibration.tile_captures([local])[0]


def candidate_shape(code, subcode, base, groups):
    calibration.integer(code, "groupcode", 0, 7)
    calibration.integer(subcode, "subcode", 0, 7)
    if subcode == 0:
        return base.rows, base.cols
    if code not in calibration.GROUPS:
        raise ValueError("fabric unsupported group requires baseline subcode 0")
    return calibration.group_shape(groups, calibration.GROUPS[code]) if subcode == 7 else FIXED_SHAPES[subcode]


def model_candidates(work, code, groups):
    items = [(item, count) for item, count in sorted(work.items()) if item.code == code]
    if not items:
        raise ValueError("empty model window group")
    candidates = {}
    for subcode in (range(8) if code in calibration.GROUPS else (0,)):
        baseline, selected, rows = 0, 0, []
        for item, count in items:
            result = calibration.select_subcode(code, item.fmt, item.m, item.n, item.k, groups)
            native = result["candidate_costs"][subcode]
            if native is None:
                break
            base = calibration.policy_topology(code, item.fmt, item.m, item.n, item.k)
            topology = base if subcode == 0 else calibration.candidate_topology(base, candidate_shape(code, subcode, base, groups))
            fixed = calibration.ceil_div(calibration.external_traffic(item), 8) + calibration.SHARED_DECISION_CYCLES
            overhead = calibration.EVALUATION_CYCLES + calibration.SWITCH_CYCLES if subcode else 0
            baseline += count * (fixed + result["baseline"])
            selected += count * (fixed + native + overhead)
            rows.append({"work": asdict(item), "count": count, "baseline": base.pack(), "candidate": topology.pack()})
        else:
            candidates[subcode] = {"subcode": subcode, "baseline_cycles": baseline, "candidate_cycles": selected,
                                   "predicted_net_cycles": baseline-selected,
                                   "baseline_topology_sha256": digest([{**r, "candidate": r["baseline"]} for r in rows]),
                                   "candidate_topology_sha256": digest(rows)}
    winner = min(candidates, key=lambda sub: (candidates[sub]["candidate_cycles"], sub))
    if candidates[winner]["predicted_net_cycles"] <= sum(count for _, count in items) * calibration.MIN_SAVINGS_CYCLES:
        winner = 0
    return {"winner": winner, "candidates": candidates}


def context_for(capture, capture_hash, start, records, recognition, work, code, groups, settings):
    group_work = [{"work": asdict(item), "count": count} for item, count in sorted(work.items()) if item.code == code]
    formats = sorted({row["work"]["fmt"] for row in group_work})
    phases = sorted({record["phase"] for record in records})
    epochs = sorted({digest(record.get("epoch", 0)) for record in records})
    stable = len(formats) == len(phases) == len(epochs) == len({r["numfmt"] for r in records}) == 1
    return {"capture_sha256": capture_hash, "window_index": start // settings.Window, "start_index": start,
            "groupcode": code, "numfmt": formats[0] if len(formats) == 1 else None,
            "record_count": len(records), "complete_window": len(records) == settings.Window,
            "stable_context": stable, "epoch": digest([capture_hash, formats, phases, epochs, groups]),
            "profile": digest(profile()), "work_signature": digest(group_work),
            "useful_macs": sum(row["count"] * row["work"]["m"] * row["work"]["n"] * row["work"]["k"] for row in group_work),
            "feature_hash": digest({"recognition": recognition["signature"], "work": group_work,
                                    "GroupShapeLog2": groups, "groupcode": code, "profile": profile()})}


def rank_templates(entries, capacity):
    calibration.integer(capacity, "MaxMotifs", 1, 32)
    return sorted(entries, key=lambda entry: tuple(-entry[field] for field in RANK_FIELDS) + (entry["template_key"],))[:capacity]


def fit_template_catalog(captures, capture_hashes, groups, settings):
    pool, exact_signatures = {}, set()
    for capture, capture_hash in zip(captures, capture_hashes):
        for start, records, recognition in windows(capture, settings):
            exact_signatures.add(recognition["signature"])
            work = window_work(capture, records)
            for code in sorted({item.code for item in work}):
                template = structural_template(recognition, code)
                key = template["template_key"]
                if key not in pool:
                    if len(pool) >= calibration.MAX_RECORDS:
                        raise ValueError("calibration template candidate bound exceeded; refusing to truncate ranking")
                    pool[key] = {**template, "signature": key, "observed_groupcodes": [code],
                                 **dict.fromkeys(RANK_FIELDS, 0), "capture_sha256": set(), "context": [],
                                 "hint_gain": Counter(), "hint_support": Counter()}
                entry = pool[key]
                context = context_for(capture, capture_hash, start, records, recognition, work, code, groups, settings)
                model = model_candidates(work, code, groups)
                winner = model["winner"] if context["stable_context"] and context["complete_window"] else 0
                gain = model["candidates"][winner]["predicted_net_cycles"]
                entry["predicted_net_gain_cycles"] += gain
                entry["baseline_cycle_weight"] += model["candidates"][0]["baseline_cycles"]
                entry["useful_mac_weight"] += context["useful_macs"]
                entry["observed_support"] += 1
                entry["capture_sha256"].add(capture_hash)
                entry["hint_gain"][winner] += gain
                entry["hint_support"][winner] += 1
                entry["context"].append({"capture_sha256": capture_hash, "start_index": start,
                    "record_count": len(records), "model_id": capture["source"]["model_id"],
                    "exact_signature": recognition["signature"], "feature_hash": context["feature_hash"]})
                entry["context"] = sorted(entry["context"], key=lambda row: (row["capture_sha256"], row["start_index"]))[:4]
    admitted = rank_templates(pool.values(), settings.MaxMotifs)
    summary = {"schema": TEMPLATE_SCHEMA, "fitted_on": "calibration_only", "capacity": settings.MaxMotifs,
               "observed_templates": len(pool), "admitted_templates": len(admitted),
               "excluded_templates": len(pool)-len(admitted), "candidate_bound": calibration.MAX_RECORDS,
               "ranking": ["descending_" + field for field in RANK_FIELDS] + ["ascending_template_key"],
               "quota": "none", "score_kind": "fixed_service_modeled_opportunity_not_measured_gain",
               "coverage": {field: {"observed": sum(entry[field] for entry in pool.values()),
                                     "admitted": sum(entry[field] for entry in admitted)} for field in RANK_FIELDS}}
    library = {}
    for rank, entry in enumerate(admitted, 1):
        gains, support = entry.pop("hint_gain"), entry.pop("hint_support")
        entry.update(rank=rank, anticipated_subcode=min(support, key=lambda sub: (-gains[sub], -support[sub], sub)),
                     capture_sha256=sorted(entry["capture_sha256"]),
                     calibration_hint_support={str(sub): {"winning_windows": count, "modeled_net_gain_cycles": gains[sub]}
                                               for sub, count in sorted(support.items())},
                     presetGroupShapeLog2=groups, compatibility_proven=False, performance_qualified=False)
        library[entry["template_key"]] = entry
    return library, summary, exact_signatures


def template_proposal(work, code, groups, entry):
    if entry is not None and (entry["template"]["groupcode"] != code or entry["presetGroupShapeLog2"] != groups):
        raise ValueError("template group or parameter profile mismatch")
    model = model_candidates(work, code, groups)
    hint = entry["anticipated_subcode"] if entry is not None else None
    candidate = model["candidates"].get(hint)
    status = ("template_miss" if entry is None else "baseline_only_hint" if hint == 0
              else "illegal_full_shape" if candidate is None
              else "confirmed_by_exact_model" if hint == model["winner"]
              else "rejected_by_exact_cost")
    model["template_hint"] = {"anticipated_subcode": hint, "status": status,
                              "template_match_is_topology_proof": False, "evaluation_cycles_saved_claimed": 0}
    return model


def template_coverage(counts):
    result = dict(counts)
    result["misses"] = counts["group_windows"] - counts["hits"]
    result["hit_rate"] = counts["hits"] / counts["group_windows"] if counts["group_windows"] else 0
    result["useful_mac_coverage"] = counts["hit_useful_macs"] / counts["useful_macs"] if counts["useful_macs"] else 0
    return result


def number(value, name, positive=False):
    if (type(value) not in (int, float) or not 0 <= value <= (1 << 63)-1
            or not math.isfinite(value) or (positive and value == 0)):
        raise ValueError(f"invalid {name}")
    return value


class EvidenceLedger:
    def __init__(self):
        self.pairs = set()
        self.sources = set()

    def validate(self, evidence, context, candidate):
        try:
            calibration.finite_tree(evidence)
            kind = evidence["evidence_kind"]
            if kind not in ("measured", "synthetic", "modeled"):
                raise ValueError("unsupported evidence kind")
            if evidence["measurement_scope"] != "array-useful-mac-counter":
                raise ValueError("not actual array MAC/cycle scope; seconds are not RTL cycles")
            if kind == "measured" and evidence["externally_provided"] is not True:
                raise ValueError("measured evidence must be externally provided")
            for key in ("capture_sha256", "window_index", "groupcode", "numfmt", "epoch", "profile",
                        "work_signature", "useful_macs", "feature_hash"):
                if type(evidence[key]) is not type(context[key]) or evidence[key] != context[key]:
                    raise ValueError(f"stale or mismatched {key}")
            if type(evidence["subcode"]) is not int or evidence["subcode"] != candidate["subcode"]:
                raise ValueError("candidate subcode mismatch")
            if evidence["mispredict"] is not False:
                raise ValueError("mispredict")
            pair = calibration.text(evidence["pair_id"], "pair_id")
            base, selected = evidence["baseline"], evidence["candidate"]
            sources = [calibration.text(row["source_id"], "source_id") for row in (base, selected)]
            if pair in self.pairs or sources[0] == sources[1] or self.sources.intersection(sources):
                raise ValueError("duplicate pair or source identity")
            for name, row in (("baseline", base), ("candidate", selected)):
                for key in ("numfmt", "useful_macs", "work_signature", "epoch", "profile"):
                    if type(row[key]) is not type(context[key]) or row[key] != context[key]:
                        raise ValueError(f"paired {name} {key} mismatch")
                if row["topology_sha256"] != candidate[name + "_topology_sha256"]:
                    raise ValueError("topology mismatch")
                calibration.integer(row["cycles"], "actual cycles", 1, (1 << 63)-1)
                calibration.text(row["clock_id"], "clock_id")
                if "seconds" in row:
                    raise ValueError("seconds are not RTL cycles")
            if base["clock_id"] != selected["clock_id"]:
                raise ValueError("clock domain mismatch")
            frequency = None
            if "frequency_hz" in base or "frequency_hz" in selected:
                frequency = number(base["frequency_hz"], "frequency_hz", True)
                if number(selected["frequency_hz"], "frequency_hz", True) != frequency:
                    raise ValueError("paired frequency mismatch")
            taxes = evidence["tax_cycles"]
            if set(taxes) != set(TAXES):
                raise ValueError("all lookup/switch/mispredict/topology taxes must be explicit")
            tax = sum(number(taxes[key], key) for key in TAXES)
            net_cycles = base["cycles"] - selected["cycles"] - tax
            result = {"evidence_kind": kind, "pair_id": pair, "source_ids": sources,
                      "baseline_cycles": base["cycles"], "candidate_cycles": selected["cycles"],
                      "tax_cycles": dict(taxes), "net_cycles": net_cycles,
                      "baseline_mac_per_cycle": context["useful_macs"] / base["cycles"],
                      "candidate_net_mac_per_cycle": context["useful_macs"] / (selected["cycles"] + tax),
                      "clock_id": base["clock_id"], "frequency_hz": frequency, "cryptographically_verified": False}
            if frequency is not None:
                result["baseline_mac_per_second"] = result["baseline_mac_per_cycle"] * frequency
                result["candidate_net_mac_per_second"] = result["candidate_net_mac_per_cycle"] * frequency
            self.pairs.add(pair)
            self.sources.update(sources)
            return result
        except (KeyError, TypeError, AttributeError) as error:
            raise ValueError(f"malformed paired evidence: {error}") from error


def saving_fraction(measured):
    net = measured["baseline_cycles"] - measured["candidate_cycles"]
    net -= sum(Fraction(tax) for tax in measured["tax_cycles"].values())
    return {"numerator": net.numerator, "denominator": net.denominator * measured["baseline_cycles"]}


def saving_bounds(measurements):
    lower = upper = measurements[0]["saving_fraction"]
    for measured in measurements[1:]:
        value = measured["saving_fraction"]
        if value["numerator"] * lower["denominator"] < lower["numerator"] * value["denominator"]:
            lower = value
        if value["numerator"] * upper["denominator"] > upper["numerator"] * value["denominator"]:
            upper = value
    return lower, upper


class WindowController:
    def __init__(self, settings=Settings(), ledger=None):
        self.settings = settings
        self.ledger = ledger if ledger is not None else EvidenceLedger()
        self.epoch = None
        self.binding = None
        self.evidence_clock = None
        self.last_window = None
        self.observed = 0
        self.cooldown = 0
        self.retained = 0
        self.pending = None
        self.streak = []
        self.commit_kind = None
        self.last_hash = None
        self.cached = None
        self.evaluations = 0

    def drop(self):
        self.retained, self.pending, self.commit_kind = 0, None, None
        self.streak = []
        self.cooldown = self.settings.Cooldown

    def step(self, context, factory, evidence=None):
        event = {key: context[key] for key in ("capture_sha256", "window_index", "groupcode", "feature_hash", "epoch")}
        event.update(action="observe", reason=None, proposal_evaluated=False, committed_subcode=0,
                     simulated_subcode=0, performance_qualified=False, measured=None)
        binding = tuple(context[key] for key in ("epoch", "profile", "numfmt", "groupcode", "capture_sha256"))
        changed = self.binding is not None and binding != self.binding
        gap = self.last_window is not None and context["window_index"] != self.last_window + 1
        warming = self.observed < self.settings.Warmup
        if changed or gap:
            self.observed = 0
            warming = True
            self.last_hash, self.cached, self.evidence_clock = None, None, None
        self.binding = binding
        self.epoch, self.last_window = context["epoch"], context["window_index"]
        self.observed += context["record_count"]
        if changed or gap or not context["stable_context"] or not context["complete_window"]:
            self.drop()
            event.update(action="reject", reason="context_change_or_gap_or_partial_window")
            return event
        if context["feature_hash"] != self.last_hash:
            self.cached = factory()
            self.last_hash = context["feature_hash"]
            self.evaluations += 1
            event["proposal_evaluated"] = True
        target = self.retained or self.cached["winner"]
        candidate = self.cached["candidates"].get(target)
        event.update(proposed_subcode=target, modeled_candidate=candidate,
                     predicted_net_cycles=candidate["predicted_net_cycles"] if candidate else None)
        if "template_hint" in self.cached:
            event["template_hint"] = self.cached["template_hint"]
        if (candidate is None or type(target) is not int or not 1 <= target <= 7
                or context["groupcode"] not in calibration.GROUPS or candidate["predicted_net_cycles"] <= 0):
            self.drop()
            event.update(action="reject", reason="no_legal_positive_modeled_candidate")
            return event
        measured = None
        if evidence is not None:
            try:
                measured = self.ledger.validate(evidence, context, candidate)
                event["measured"] = measured
                saving = measured["saving_fraction"] = saving_fraction(measured)
                event["predicted_saving_fraction"] = {"numerator": candidate["predicted_net_cycles"],
                                                       "denominator": candidate["baseline_cycles"]}
                if saving["numerator"] <= 0:
                    raise ValueError("signed_regression_or_tax_exhausted_gain")
                if (16 * saving["numerator"] * candidate["baseline_cycles"]
                        < self.settings.MinRealizedGain16ths * candidate["predicted_net_cycles"] * saving["denominator"]):
                    raise ValueError("realized_gain_below_threshold")
                clock = (measured["clock_id"], measured["frequency_hz"])
                changed_clock = self.evidence_clock is not None and clock != self.evidence_clock
                self.evidence_clock = clock
                if changed_clock:
                    raise ValueError("clock_or_frequency_epoch_change")
            except ValueError as error:
                self.drop()
                event.update(action="reject", reason=str(error))
                return event
        if self.cooldown:
            self.cooldown -= 1
            event.update(action="cooldown", reason="rejected_window_holdoff")
            return event
        if warming:
            self.pending, self.streak = None, []
            event.update(action="warmup", reason="warmup_never_qualifies_itself")
            return event
        if measured is None:
            was_retained = bool(self.retained)
            self.drop()
            if not was_retained:
                self.cooldown = 0
            event.update(action="reject" if was_retained else "observe", reason="no_paired_actual_evidence")
            return event
        identity = (target, measured["evidence_kind"])
        if self.retained and self.commit_kind != measured["evidence_kind"]:
            self.drop()
            event.update(action="reject", reason="evidence_kind_change")
            return event
        if self.pending != identity:
            self.pending, self.streak = identity, []
        self.streak.append(measured)
        self.streak = self.streak[-self.settings.HoldWindows:]
        lower, upper = saving_bounds(self.streak)
        event["consistent_saving_range"] = {"minimum": lower, "maximum": upper}
        if (16 * upper["numerator"] * lower["denominator"]
                > (16 + self.settings.MaxGainSpread16ths) * lower["numerator"] * upper["denominator"]):
            self.drop()
            event.update(action="reject", reason="unstable_measured_gain")
            return event
        if len(self.streak) >= self.settings.HoldWindows:
            self.retained, self.commit_kind = identity
            real = self.commit_kind == "measured"
            event.update(action="host_commit" if real else "simulated_commit", performance_qualified=real,
                         committed_subcode=target if real else 0, simulated_subcode=0 if real else target,
                         consistent_pair_ids=[row["pair_id"] for row in self.streak])
        else:
            event["action"] = "hold"
        return event


def feedback_index(feedback):
    if feedback is None:
        return {}
    if not isinstance(feedback, dict) or feedback.get("schema") != FEEDBACK_SCHEMA:
        raise ValueError("invalid feedback schema")
    rows = feedback.get("windows")
    if not isinstance(rows, list) or len(rows) > calibration.MAX_RECORDS:
        raise ValueError("invalid feedback windows")
    result = {}
    try:
        for row in rows:
            key = (calibration.hex_digest(row["capture_sha256"], 64, "capture_sha256"),
                   calibration.integer(row["start_index"], "start_index", 0),
                   calibration.integer(row["groupcode"], "groupcode", 0, 7))
            if key in result:
                raise ValueError("duplicate feedback window")
            if not isinstance(row["evidence"], dict):
                raise ValueError("invalid window evidence")
            result[key] = row["evidence"]
    except (KeyError, TypeError) as error:
        raise ValueError(f"malformed feedback: {error}") from error
    return result


def nested_codebook(groups, objectives, motifs):
    result = {}
    for code in range(8):
        entries = {}
        for subcode in (range(8) if code in calibration.GROUPS else (0,)):
            related = [motif for motif in motifs if code in motif["observed_groupcodes"]]
            shape = (calibration.group_shape(groups, calibration.GROUPS[code]) if subcode == 7
                     else FIXED_SHAPES.get(subcode))
            entries[str(subcode)] = {"groupcode": code, "subcode": subcode, "group_subword": (code << 3) | subcode,
                "tunable": subcode == 7, "shape_log2": list(shape) if shape else None,
                "motif_signatures": [motif["signature"] for motif in related],
                "signature_kind": TEMPLATE_SCHEMA, "template_keys": [motif["template_key"] for motif in related],
                "observed_support": sum(motif["observed_support"] for motif in related),
                "context": [{"signature": motif["signature"], "examples": motif["context"]} for motif in related],
                "capture_sha256": sorted({h for motif in related for h in motif["capture_sha256"]}),
                "presetGroupShapeLog2": groups, "zero_skip_authorized": False}
        result[str(code)] = {"groupcode": code, "name": GROUP_NAMES[code],
                             "fabric_subcode_supported": code in calibration.GROUPS, "subcodes": entries}
    return {"GroupShapeLog2": groups, "default_GroupShapeLog2": calibration.DEFAULT_GROUP_SHAPES,
            "presetGroupShapeLog2": groups, "fitting": objectives, "groups": result}


def analyze(calibration_captures, held_out, feedback=None, settings=Settings(), capture_hashes=None):
    if not calibration_captures or not held_out:
        raise ValueError("nonempty calibration and held-out captures required")
    for capture in calibration_captures + held_out:
        calibration.validate_capture(capture)
        ordered_events(capture)
    calibration.check_disjoint(calibration_captures, held_out)
    cal_work, _ = calibration.tile_captures(calibration_captures)
    groups, objectives = calibration.fit_groups(cal_work)
    splits = {"calibration": calibration_captures, "held_out": held_out}
    hashes = capture_hashes if capture_hashes is not None else {name: [digest(c) for c in captures] for name, captures in splits.items()}
    for name, captures in splits.items():
        if len(hashes[name]) != len(captures):
            raise ValueError("capture hash count mismatch")
        for value in hashes[name]:
            calibration.hex_digest(value, 64, "capture_sha256")
    if len(set(h for values in hashes.values() for h in values)) != sum(map(len, hashes.values())):
        raise ValueError("duplicate captures")
    supplied, used = feedback_index(feedback), set()
    library, catalog, exact_signatures = fit_template_catalog(calibration_captures, hashes["calibration"], groups, settings)
    ledger, reports, claims = EvidenceLedger(), {}, []
    for split, captures in splits.items():
        trace, recognition_windows, kinds, modeled = [], [], Counter(), Counter()
        coverage, per_group, hints = Counter(), {}, Counter()
        seen_templates, hit_templates = set(), set()
        matched, window_count, partial_coverage, any_hit, all_hit, evaluations = 0, 0, 0, 0, 0, 0
        for capture, capture_hash in zip(captures, hashes[split]):
            controllers = {}
            for start, records, recognition in windows(capture, settings):
                window_count += 1
                matched += int(recognition["signature"] in exact_signatures)
                recognition_windows.append({"capture_sha256": capture_hash, "model_id": capture["source"]["model_id"],
                                            "start_index": start, **recognition})
                work = window_work(capture, records)
                codes = sorted({item.code for item in work})
                kinds.update(name + ":" + status for name, status in recognition["kinds"].items())
                window_hits = 0
                for code in codes:
                    template_key = structural_template(recognition, code)["template_key"]
                    entry = library.get(template_key)
                    hit = entry is not None
                    window_hits += int(hit)
                    seen_templates.add(template_key)
                    if hit:
                        hit_templates.add(template_key)
                    context = context_for(capture, capture_hash, start, records, recognition, work, code, groups, settings)
                    counts = {"group_windows": 1, "hits": int(hit), "useful_macs": context["useful_macs"],
                              "hit_useful_macs": context["useful_macs"] if hit else 0}
                    coverage.update(counts)
                    per_group.setdefault(code, Counter()).update(counts)
                    controller = controllers.setdefault(code, WindowController(settings, ledger))
                    key = (capture_hash, start, code)
                    evidence = supplied.get(key)
                    if evidence is not None:
                        used.add(key)
                    event = controller.step(context, lambda: template_proposal(work, code, groups, entry), evidence)
                    event.update(evidence_context=context, template_key=template_key, template_match=hit,
                                 exact_signature=recognition["signature"])
                    hints[event.get("template_hint", {}).get("status", "not_evaluated_context_guard")] += 1
                    trace.append(event)
                    if event.get("predicted_net_cycles") is not None:
                        modeled["predicted_net_cycles_over_proposals"] += event["predicted_net_cycles"]
                    if event["performance_qualified"]:
                        claims.append({"split": split, **event})
                any_hit += int(window_hits > 0)
                all_hit += int(window_hits == len(codes))
                partial_coverage += int(window_hits != len(codes))
            evaluations += sum(controller.evaluations for controller in controllers.values())
        reports[split] = {"window_count": window_count, "recognition_status_counts": dict(kinds),
                         "recognition_windows": recognition_windows,
                         "calibration_signature_matches": matched if split == "held_out" else None,
                         "bounded_library_overflow_windows": partial_coverage if split == "calibration" else 0,
                         "template_coverage": {**template_coverage(coverage), "windows_with_any_hit": any_hit,
                             "fully_covered_windows": all_hit, "unique_observed_templates": len(seen_templates),
                             "unique_matched_templates": len(hit_templates), "hint_validation": dict(hints),
                             "per_group": {str(code): template_coverage(counts) for code, counts in sorted(per_group.items())}},
                         "proposal_evaluations": evaluations, "modeled_only": dict(modeled), "control_trace": trace}
    if set(supplied) != used:
        raise ValueError("feedback refers to an unknown capture/window/group")
    return {"schema": SCHEMA, "settings": asdict(settings), "recommended_enable": False,
            "automatic_production_promotion": False, "parameters": nested_codebook(groups, objectives, list(library.values())),
            "motifs": list(library.values()), "template_catalog": catalog,
            "parameter_profiles": {"presetGroupShapeLog2": [groups], "service_profile_sha256": digest(profile())},
            "service_assumptions": profile(), "capture_hashes": hashes,
            "capture_hash_basis": "supplied_raw_file_sha256" if capture_hashes is not None else "canonical_parsed_json_sha256",
            "reports": reports, "externally_reported_measured_claims": claims,
            "performance_qualified_claim_count": len(claims),
            "measurement_status": "externally_reported_unverified" if claims else "no_admitted_actual_array_timing",
            "feedback_authentication": "Structural validation only; self-reported feedback is not cryptographic proof",
            "feedback_contract": {"schema": FEEDBACK_SCHEMA, "rows": "windows",
                "routing_keys": ["capture_sha256", "start_index", "groupcode"], "payload": "evidence",
                "kinds": ["measured", "synthetic", "modeled"], "scope": "array-useful-mac-counter",
                "binding": "Match evidence_context fields and modeled_candidate subcode/topology hashes exactly",
                "paired_paths": ["baseline", "candidate"], "pair_fields": ["source_id", "numfmt", "useful_macs",
                    "work_signature", "epoch", "profile", "topology_sha256", "cycles", "clock_id"],
                "identities": "Globally unique pair_id and distinct one-use baseline/candidate source_id",
                "tax_cycles": list(TAXES), "tax_units": "same matched cycle domain as both measured paths",
                "tax_accounting": "Additional cycles not already included in candidate.cycles; use zero for penalties already present in measured elapsed cycles",
                "additional_required": "mispredict=false; measured requires externally_provided=true",
                "realized_gain_requirement": "measured_net/measured_baseline >= (MinRealizedGain16ths/16)*(predicted_net/predicted_baseline)",
                "window_spread_requirement": "maximum normalized saving <= minimum normalized saving*(1+MaxGainSpread16ths/16) over the consecutive HoldWindows history",
                "gain_comparison": "Inclusive boundaries using exact integer cross-products; decoded fractional taxes represented exactly; raw net cycles are not compared between windows",
                "frequency": "Optional frequency_hz on both paired paths, finite, positive and identical",
                "no_evidence_rule": "Never synthesize timing from CPU capture durations or metadata samples"},
            "design_limitations": [
                "Host-only parameters and diagnostics; no SV source generation, group/mux/array redesign, or ISA/config change",
                "Only candidate 7 shape is fitted; fixed candidates 0..6 and unsupported-group baseline 0 are immutable",
                "Window-wide bank-candidate comparison is host control diagnostics, not replay of per-tile RTL selector hysteresis",
                "Calibration-only fixed-service fit; held-out data and feedback never tune parameters or motif signatures",
                "At most MaxMotifs per-group structural templates admitted by calibration-only modeled opportunity ranking, never first arrival or equal quotas",
                "Template identity uses native format, phase, source raw group, shape buckets, R/C residues modulo 16, canonical matrix family and reuse-axis run collapse",
                "Model IDs, module paths, literal operators and exact dimensions are excluded from templates but retained by exact feature hashes and provenance",
                "Templates supply calibration-derived subcode hints only; full-shape bank legality/cost and exact evidence bindings remain mandatory",
                "Template hits are structural recognition coverage, not compatible-topology proof, avoided evaluation cycles or measured gains",
                "Collapsed group projections can alias different counts, strides, dimensions, sequence boundaries and operand semantics; exact guards must not be replaced",
                "Calibration ranking scores valid complete-window predicted savings, then baseline cycle weight, useful MAC weight, support and stable template key",
                "Full window recognition and cross-boundary context remain reported independently of the ranked template catalog",
                "Legacy bounded_library_overflow_windows counts calibration windows missing any admitted group template; template_coverage reports group-window hits/misses",
                "One prior matrix record detects boundary transitions; the matrix warmup window remains bounded",
                "Other-event signatures stream over every correlated event; epilogue examples and lengths are capped at Window",
                "Absolute positions and ignored sample values are not motif features; complete ordered scheduling context is hashed",
                "External numeric tax/frequency fields are bounded to finite nonnegative values no greater than 2^63-1",
                "Window warmup and positive consecutive paired evidence are mandatory; synthetic/model commits never count as real",
                "Consecutive windows require sufficient normalized realized savings and bounded normalized spread, not just matching positive signs",
                "Realized-gain and spread settings are host admission controls, never fitted on calibration or held-out data; fixed codebook profiles are unchanged",
                "Saving-fraction numerator/denominator pairs drive exact gates even when fractional-tax net_cycles display is rounded",
                "Bounded gain consistency is not statistical significance, a confidence interval or automatic production promotion",
                "MAC/cycle is cycle normalized; MAC/s requires explicit matching paired frequency and clock domain",
                "No real array timing exists in ordinary CPU framework captures; capture wall seconds are not RTL cycles",
                "Exact operator sequence is structural observation, not model-class identification, dataflow/code proof or gain",
                "Repeated mm/linear and opcode-1 attention are hypotheses; no fabricated model families or routing from module names",
                "Routed bursts require semantic_metadata.routed=true plus string routing_id/expert_id on adjacent records",
                "Current opcode-0/1 matrix captures without routing metadata leave routed motifs uncaptured and group defaults unchanged",
                "Aggregate other_operators cannot prove order; epilogues/gathers need complete correlated operator_walk",
                "An epilogue cluster is a matrix immediately followed by one or more known epilogue operators; adjacency is not fusion proof",
                "Gather/index operator families suggest irregular access but do not prove index distribution; select.int is a view",
                "A shape/stride reuse axis is a hypothesis, never tensor-identity, cache-residency or inter-tile reuse credit",
                "Mixed phase/format/epoch and partial windows cannot qualify control; context change/gap rolls back to baseline",
                "Native samples are discarded; noisy or zero metadata never authorizes sparse policy or zero skip",
                "Explicit tax fields and topology hashes fail closed but externally supplied counters remain unauthenticated",
                "No production enable recommendation, live PE integration, timing closure, power/area or end-to-end speedup proof"]}


def main(argv=None):
    parser = argparse.ArgumentParser(description="GSys LibreCore bounded host motif parameters; never automatic production enable")
    parser.add_argument("--calibration", type=Path, nargs="+", required=True)
    parser.add_argument("--held-out", type=Path, nargs="+", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--feedback", type=Path)
    for flag, default in (("window", 16), ("warmup", 8), ("hold-windows", 2), ("cooldown", 2), ("max-motifs", 32),
                          ("min-realized-gain16ths", 8), ("max-gain-spread16ths", 8)):
        parser.add_argument("--" + flag, type=int, default=default)
    args = parser.parse_args(argv)
    try:
        sources = args.calibration + args.held_out + [Path(__file__), Path(__file__).with_name("test_policy_motifs.py")]
        if args.feedback:
            sources.append(args.feedback)
        if args.out.suffix.lower() != ".json":
            raise ValueError("report output must be JSON, never SV source")
        calibration.protect_outputs([args.out], sources)
        settings = Settings(args.window, args.warmup, args.hold_windows, args.cooldown, args.max_motifs,
                            MinRealizedGain16ths=args.min_realized_gain16ths, MaxGainSpread16ths=args.max_gain_spread16ths)
        loaded = {name: [calibration.load_capture(path) for path in paths]
                  for name, paths in (("calibration", args.calibration), ("held_out", args.held_out))}
        feedback = calibration.strict_json_loads(args.feedback.read_bytes()) if args.feedback else None
        hashes = {name: [provenance["capture_sha256"] for _, provenance in rows] for name, rows in loaded.items()}
        result = analyze([row[0] for row in loaded["calibration"]], [row[0] for row in loaded["held_out"]],
                         feedback, settings, hashes)
        result["capture_provenance"] = {name: [row[1] for row in rows] for name, rows in loaded.items()}
        result["host_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        result["calibrator_sha256"] = hashlib.sha256(Path(calibration.__file__).read_bytes()).hexdigest()
        if args.feedback:
            result["feedback_sha256"] = hashlib.sha256(args.feedback.read_bytes()).hexdigest()
        args.out.write_text(json.dumps(result, sort_keys=True, indent=2, allow_nan=False) + "\n", encoding="utf-8")
        print(f"motifs={len(result['motifs'])}/{result['template_catalog']['observed_templates']}; GroupShapeLog2=0x{result['parameters']['GroupShapeLog2']:06x}; admitted_actual_claims={result['performance_qualified_claim_count']}; recommended_enable=false")
        for split, report in result["reports"].items():
            coverage = report["template_coverage"]
            print(f"{split}: structural template hits={coverage['hits']}/{coverage['group_windows']}; misses={coverage['misses']}; unique matches={coverage['unique_matched_templates']}/{coverage['unique_observed_templates']}; useful-MAC coverage={coverage['useful_mac_coverage']:.6f}")
        print("CPU capture durations are not actual array timing; synthetic/model evidence is not measured performance")
    except (ValueError, OSError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
