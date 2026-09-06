"""SPDX-FileCopyrightText: 2026 Etienne Cimon
SPDX-License-Identifier: MIT
"""

from collections import Counter
from copy import deepcopy
import json
from pathlib import Path
import random
import tempfile
import unittest
from unittest.mock import Mock, patch

import policy_calibration as calibration
import policy_motifs as motifs
from test_policy_calibration import capture


def walk(count=48, model="calibration-fixture", weight="a", m=64, n=64, k=48, fmt=7):
    value = capture(model, weight, m=m, n=n, k=k, fmt=fmt)
    value["records"] = [{**deepcopy(value["records"][0]), "index": i} for i in range(count)]
    return value


def bundle():
    return {"winner": 7, "candidates": {subcode: {"subcode": subcode,
        "baseline_cycles": 1000, "candidate_cycles": 800 if subcode else 1000,
        "predicted_net_cycles": 200 if subcode else 0,
        "baseline_topology_sha256": "a"*64, "candidate_topology_sha256": str(subcode)*64}
        for subcode in (0, 1, 7)}}


def context(index=0, **changes):
    return {"capture_sha256": "c"*64, "window_index": index, "start_index": 16*index,
            "groupcode": 0, "numfmt": 7, "record_count": 16, "complete_window": True,
            "stable_context": True, "epoch": "e"*64, "profile": motifs.digest(motifs.profile()),
            "work_signature": "f"*64, "useful_macs": 1000, "feature_hash": "d"*64, **changes}


def evidence(ctx, candidate=None, kind="measured", pair=None):
    chosen = candidate if candidate is not None else bundle()["candidates"][7]
    pair = pair if pair is not None else "fixture-" + str(ctx["window_index"])
    common = {key: ctx[key] for key in ("numfmt", "useful_macs", "work_signature", "epoch", "profile")}
    return {**{key: ctx[key] for key in ("capture_sha256", "window_index", "groupcode", "numfmt", "epoch",
                                       "profile", "work_signature", "useful_macs", "feature_hash")},
            "evidence_kind": kind, "measurement_scope": "array-useful-mac-counter", "externally_provided": True,
            "pair_id": pair, "subcode": chosen["subcode"], "mispredict": False,
            "baseline": {**common, "source_id": pair + "-base", "cycles": 1000, "clock_id": "fixture-array",
                         "topology_sha256": chosen["baseline_topology_sha256"]},
            "candidate": {**common, "source_id": pair + "-candidate", "cycles": 800, "clock_id": "fixture-array",
                          "topology_sha256": chosen["candidate_topology_sha256"]},
            "tax_cycles": {key: 2 for key in motifs.TAXES}}


class RecognitionTests(unittest.TestCase):
    def test_default_bounds(self):
        self.assertEqual(motifs.asdict(motifs.Settings()),
                         {"Window": 16, "Warmup": 8, "HoldWindows": 2, "Cooldown": 2, "MaxMotifs": 32,
                          "MinRealizedGain16ths": 8, "MaxGainSpread16ths": 8})
        for kwargs in ({"Window": 1}, {"Window": 257}, {"Warmup": 0}, {"Warmup": 17},
                       {"HoldWindows": 0}, {"Cooldown": -1}, {"MaxMotifs": 33}, {"Window": True},
                       {"MinRealizedGain16ths": 0}, {"MinRealizedGain16ths": 17}, {"MinRealizedGain16ths": True},
                       {"MinRealizedGain16ths": 8.0}, {"MaxGainSpread16ths": -1}, {"MaxGainSpread16ths": 17},
                       {"MaxGainSpread16ths": False}, {"MaxGainSpread16ths": 8.0}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                motifs.Settings(**kwargs)

    def test_ordered_buckets_continuity_reuse_ngrams(self):
        value = walk(16)
        result = motifs.recognize(value["records"], None)
        self.assertEqual(result["features"][0]["buckets"], [2, 2, 2])
        self.assertFalse(result["features"][0]["shape_continuity"])
        self.assertTrue(result["features"][1]["shape_continuity"])
        self.assertEqual(result["features"][1]["reuse_axis_hypothesis"], "both")
        self.assertEqual(result["kinds"]["repeated_linear"], "hypothesis")
        self.assertTrue(result["recurring_ngrams"])
        self.assertEqual(result["signature"], motifs.recognize(deepcopy(value["records"]), None)["signature"])

    def test_mixed_prefill_decode_attention_transition_not_model_class(self):
        value = walk(16)
        for i, record in enumerate(value["records"]):
            record["phase"] = "prefill" if i < 8 else "decode"
            record["opcode_class"] = i % 2
        result = motifs.recognize(value["records"], None)
        self.assertEqual(result["kinds"]["prefill_to_decode"], "observed")
        self.assertEqual(result["kinds"]["repeated_attention"], "hypothesis")
        self.assertEqual(result["kinds"]["routed_burst"], "uncaptured")
        self.assertNotIn("model_class", result)

    def test_boundary_transition_and_prior_context_are_hashed(self):
        value = walk(32)
        for record in value["records"][16:]:
            record["phase"] = "decode"
        found = list(motifs.windows(value, motifs.Settings()))
        self.assertEqual(found[1][2]["kinds"]["prefill_to_decode"], "observed")
        self.assertIsNotNone(found[1][2]["previous_feature"])
        old = found[1][2]["signature"]
        value["records"][15]["module"] = "changed-context"
        self.assertNotEqual(old, list(motifs.windows(value, motifs.Settings()))[1][2]["signature"])

    def test_bounded_other_summaries_hash_all_events(self):
        records = walk(2)["records"]
        events = [{"kind": "matrix", "operator": "aten.mm.default", "module": "layer"}]
        events += [{"kind": "other", "operator": "aten.add.Tensor", "module": "layer"} for _ in range(1000)]
        found = motifs.recognize(records, events)
        self.assertEqual(len(found["epilogue_kinds"][0]), 16)
        self.assertEqual(found["ordered_event_fingerprint"]["event_count"], 1001)
        events[-1]["module"] = "changed-tail"
        self.assertNotEqual(found["signature"], motifs.recognize(records, events)["signature"])

    def test_samples_never_become_sparse_or_zero_proof(self):
        value = walk(16)
        baseline = motifs.recognize(value["records"], None)
        rng = random.Random(67)
        for record in value["records"]:
            record["native_sample_hex"] = "".join(rng.choice("00000000000001ff") for _ in range(64))
            record["module"] = "routed.experts.sparse"
        noisy = motifs.recognize(value["records"], None)
        self.assertTrue(all(f["groupcode"] == 0 for f in noisy["features"]))
        self.assertEqual(noisy["kinds"]["routed_burst"], "uncaptured")
        for record in value["records"]:
            record["module"] = "layer"
        self.assertEqual(baseline["signature"], motifs.recognize(value["records"], None)["signature"])
        value["records"][0]["exact_zero"] = True
        with self.assertRaises(ValueError):
            calibration.validate_capture(value)

    def test_complete_signature_changes_on_relevant_inputs(self):
        value = walk(16)
        original = motifs.recognize(value["records"], None)["signature"]
        for key, change in (("numfmt", 6), ("opcode_class", 1), ("phase", "decode"), ("epoch", 2),
                            ("module", "other"), ("operator", "aten.addmm.default"), ("a_stride", [1, 64]),
                            ("m", 63), ("n", 63), ("k", 47), ("batch", 2)):
            changed = deepcopy(value["records"])
            changed[1][key] = change
            with self.subTest(key=key):
                self.assertNotEqual(original, motifs.recognize(changed, None)["signature"])
        self.assertNotEqual(original, motifs.recognize(value["records"], None, motifs.Settings(Warmup=4))["signature"])

    def test_routed_only_with_explicit_semantics_still_frozen_group(self):
        records = walk(16)["records"]
        for i, record in enumerate(records):
            record["semantic_metadata"] = {"routed": True, "routing_id": "fixture-route", "expert_id": str(i % 2)}
        result = motifs.recognize(records, None)
        self.assertEqual(result["kinds"]["routed_burst"], "explicit_metadata_hypothesis")
        self.assertEqual({f["groupcode"] for f in result["features"]}, {0})
        for record in records:
            del record["semantic_metadata"]["expert_id"]
        self.assertEqual(motifs.recognize(records, None)["kinds"]["routed_burst"], "uncaptured")

    def operator_capture(self):
        value = walk(2)
        operators = ("aten.add.Tensor", "aten.silu.default", "aten.gather.default", "aten.select.int",
                     "aten.addmm.default", "aten.index_put.default")
        value["other_operators"] = dict(Counter(operators))
        value["operator_walk"] = [{"index": 0, "kind": "matrix", "operator": "aten.mm.default", "module": "layer", "matrix_index": 0}]
        value["operator_walk"].extend({"index": i+1, "kind": "other", "operator": name, "module": "layer"}
                                      for i, name in enumerate(operators))
        value["operator_walk"].append({"index": 7, "kind": "matrix", "operator": "aten.mm.default", "module": "layer", "matrix_index": 1})
        return value

    def test_aggregate_others_do_not_prove_order(self):
        value = self.operator_capture()
        result = motifs.recognize(value["records"], None)
        self.assertEqual(result["kinds"]["epilogue_cluster"], "not_observed")
        self.assertEqual(result["kinds"]["irregular_gather"], "not_observed")
        ordered = motifs.recognize(value["records"], motifs.ordered_events(value))
        self.assertEqual(ordered["epilogue_kinds"], [["add", "silu"]])
        self.assertEqual(ordered["gather_operators"], ["aten.gather.default"])
        self.assertEqual(ordered["selection_view_count"], 1)
        self.assertNotEqual(result["signature"], ordered["signature"])

    def test_bad_operator_walk_correlations_fail_closed(self):
        mutations = ((0, "matrix_index", 1), (0, "operator", "aten.bmm.default"), (0, "module", "wrong"),
                     (1, "index", 8), (1, "matrix_index", 1), (1, "kind", "unknown"))
        for index, key, change in mutations:
            value = self.operator_capture()
            value["operator_walk"][index][key] = change
            with self.subTest(key=key), self.assertRaises(ValueError):
                motifs.ordered_events(value)
        value = self.operator_capture()
        value["other_operators"]["aten.add.Tensor"] += 1
        with self.assertRaises(ValueError):
            motifs.ordered_events(value)

    def test_non_epilogue_breaks_cluster_and_select_is_view(self):
        value = self.operator_capture()
        events = motifs.ordered_events(value)
        events[2]["operator"] = "aten.select.int"
        events[3]["operator"] = "aten.index_put.default"
        result = motifs.recognize(value["records"], events)
        self.assertEqual(result["epilogue_kinds"], [["add"]])
        self.assertEqual(result["gather_operators"], [])


def describe_template(value, code=0):
    settings = motifs.Settings()
    start, records, recognition = next(motifs.windows(value, settings))
    work = motifs.window_work(value, records)
    ctx = motifs.context_for(value, motifs.digest(value), start, records, recognition, work, code,
                             calibration.DEFAULT_GROUP_SHAPES, settings)
    return motifs.structural_template(recognition, code), recognition, ctx, work


class StructuralTemplateTests(unittest.TestCase):
    def test_model_and_layer_renaming_preserves_template_not_exact_guard(self):
        original = walk(16)
        changed = deepcopy(original)
        changed["source"]["model_id"] = "renamed-fixture"
        for record in changed["records"]:
            record["module"] = "different.layer.427.path"
        first, recognition, ctx, _ = describe_template(original)
        second, other_recognition, other_ctx, _ = describe_template(changed)
        self.assertEqual(first, second)
        self.assertNotEqual(recognition["signature"], other_recognition["signature"])
        self.assertNotEqual(ctx["feature_hash"], other_ctx["feature_hash"])
        changed = deepcopy(original)
        changed["source"]["model_id"] = "only-model-renamed"
        self.assertEqual(first, describe_template(changed)[0])
        self.assertNotEqual(ctx["feature_hash"], describe_template(changed)[2]["feature_hash"])
        serialized = json.dumps(first)
        self.assertNotIn("calibration-fixture", serialized)
        self.assertNotIn("layer", serialized)
        self.assertNotIn("aten.mm", serialized)

    def test_canonical_matrix_families_and_attention_remain_distinct(self):
        original = walk(16)
        linear = deepcopy(original)
        for record in linear["records"]:
            record.update(operator="aten.linear.default", b_matrix_orientation="transposed",
                          b_shape=[record["n"], record["k"]], b_stride=[record["k"], 1])
        calibration.validate_capture(linear)
        self.assertEqual(describe_template(original)[0], describe_template(linear)[0])
        self.assertNotEqual(describe_template(original)[2]["feature_hash"], describe_template(linear)[2]["feature_hash"])
        attention = deepcopy(original)
        for record in attention["records"]:
            record["opcode_class"] = 1
        template = describe_template(attention, 4)[0]
        self.assertNotEqual(describe_template(original)[0]["template_key"], template["template_key"])
        self.assertEqual(template["template"]["collapsed_sequence"][0]["matrix_family"], "attention_matrix_hypothesis")

    def test_native_format_not_execution_label_controls_template(self):
        first = walk(16)
        changed_label = deepcopy(first)
        changed_label["execution"]["dtype"] = "bf16"
        self.assertEqual(describe_template(first)[0], describe_template(changed_label)[0])
        native_bf16 = walk(16, fmt=6)
        self.assertNotEqual(describe_template(first)[0], describe_template(native_bf16)[0])

    def test_group_projection_tracks_frozen_tile_groups_and_phase(self):
        value = walk(16, m=32, n=257, k=48)
        first, _, _, work = describe_template(value, 1)
        tail = describe_template(value, 2)[0]
        self.assertEqual({item.code for item in work}, {1, 2})
        self.assertNotEqual(first["template_key"], tail["template_key"])
        self.assertEqual(first["template"]["collapsed_sequence"][0]["source_raw_group"], 1)
        self.assertEqual(tail["template"]["groupcode"], 2)
        for record in value["records"]:
            record["phase"] = "decode"
        self.assertNotEqual(first["template_key"], describe_template(value, 1)[0]["template_key"])
        with self.assertRaises(ValueError):
            describe_template(value, 5)

    def test_bucket_residue_and_stride_aliases_require_exact_feedback(self):
        original = walk(16, m=32, n=32, k=48)
        larger = walk(16, m=48, n=48, k=48)
        stride_changed = deepcopy(original)
        for record in stride_changed["records"]:
            record["a_stride"] = [1, 32]
        template, _, original_ctx, _ = describe_template(original)
        for value in (larger, stride_changed):
            other_template, _, ctx, work = describe_template(value)
            self.assertEqual(template, other_template)
            self.assertNotEqual(original_ctx["feature_hash"], ctx["feature_hash"])
            model = motifs.model_candidates(work, 0, calibration.DEFAULT_GROUP_SHAPES)
            candidate = model["candidates"][model["winner"]]
            stale = evidence(ctx, candidate)
            stale["feature_hash"] = original_ctx["feature_hash"]
            with self.assertRaisesRegex(ValueError, "feature_hash"):
                motifs.EvidenceLedger().validate(stale, ctx, candidate)
        self.assertEqual(original_ctx["work_signature"], describe_template(stride_changed)[2]["work_signature"])
        different_residue = walk(16, m=33, n=32, k=48)
        self.assertNotEqual(template, describe_template(different_residue)[0])

    def test_template_hint_cannot_bypass_full_shape_cost_or_profile(self):
        entry = {"anticipated_subcode": 4, "template": {"groupcode": 0},
                 "presetGroupShapeLog2": calibration.DEFAULT_GROUP_SHAPES}
        for m, n, k, expected in ((3, 3, 48, "illegal_full_shape"), (64, 64, 48, "rejected_by_exact_cost"),
                                  (4, 4, 127, "confirmed_by_exact_model")):
            work = Counter({calibration.Work("fixture", "prefill", 7, 0, m, n, k): 1})
            checked = motifs.template_proposal(work, 0, calibration.DEFAULT_GROUP_SHAPES, entry)
            self.assertEqual(checked["template_hint"]["status"], expected)
            self.assertEqual(checked["winner"], motifs.model_candidates(work, 0, calibration.DEFAULT_GROUP_SHAPES)["winner"])
            self.assertEqual(checked["template_hint"]["evaluation_cycles_saved_claimed"], 0)
        for invalid in ({**entry, "template": {"groupcode": 3}}, {**entry, "presetGroupShapeLog2": 0}):
            with self.assertRaises(ValueError):
                motifs.template_proposal(work, 0, calibration.DEFAULT_GROUP_SHAPES, invalid)

    def test_template_hit_does_not_silence_a_changed_exact_guard(self):
        controller, factory = motifs.WindowController(), Mock(side_effect=bundle)
        for i, feature_hash in enumerate(("d"*64, "a"*64, "a"*64)):
            ctx = context(i, feature_hash=feature_hash, template_key="same-structural-template")
            event = controller.step(ctx, factory, evidence(ctx, kind="synthetic"))
            self.assertEqual(event["proposal_evaluated"], i < 2)
            self.assertFalse(event["performance_qualified"])
        self.assertEqual(factory.call_count, 2)

    def test_ranking_priority_stable_ties_and_capacity_are_not_arrival_order(self):
        scores = [(1, 0, 0, 0), (0, 999, 999, 999), (1, 1, 0, 0), (1, 1, 1, 0), (1, 1, 1, 1), (1, 1, 1, 1)]
        entries = [{"template_key": f"{i:064x}", **dict(zip(motifs.RANK_FIELDS, score))} for i, score in enumerate(scores)]
        before = deepcopy(entries)
        ranked = motifs.rank_templates(entries, 32)
        self.assertEqual([row["template_key"] for row in ranked], [entries[i]["template_key"] for i in (4, 5, 3, 2, 0, 1)])
        self.assertEqual(ranked, motifs.rank_templates(reversed(entries), 32))
        self.assertEqual(motifs.rank_templates(entries, 1), ranked[:1])
        self.assertEqual(entries, before)

    def test_ranking_uses_calibration_opportunity_before_baseline_weight(self):
        bulk = walk(model="bulk-fixture", weight="a")
        opportunity = walk(16, model="opportunity-fixture", weight="c", m=4, n=4, k=127)
        held = walk(model="held-fixture", weight="b")
        settings = motifs.Settings(MaxMotifs=1)
        first = motifs.analyze([bulk, opportunity], [held], settings=settings)
        reverse = motifs.analyze([opportunity, bulk], [held], settings=settings)
        self.assertGreater(first["motifs"][0]["predicted_net_gain_cycles"], 0)
        self.assertEqual(first["motifs"][0]["context"][0]["model_id"], "opportunity-fixture")
        self.assertEqual(first["parameters"], reverse["parameters"])
        self.assertEqual(first["motifs"], reverse["motifs"])
        self.assertEqual(first["template_catalog"], reverse["template_catalog"])
        changed = motifs.analyze([bulk, opportunity], [walk(model="new-held", weight="d", m=512, n=512, k=511)], settings=settings)
        for field in ("parameters", "motifs", "template_catalog", "parameter_profiles"):
            self.assertEqual(first[field], changed[field])
        self.assertEqual(changed["template_catalog"]["capacity"], 1)

    def test_template_hits_are_reported_without_exact_or_measured_claims(self):
        cal, held = walk(), walk(model="held-fixture", weight="b")
        for record in held["records"]:
            record["module"] = "held.layer.99"
        report = motifs.analyze([cal], [held])
        coverage = report["reports"]["held_out"]["template_coverage"]
        self.assertEqual((coverage["group_windows"], coverage["hits"], coverage["misses"]), (3, 3, 0))
        self.assertEqual(coverage["useful_mac_coverage"], 1)
        self.assertEqual(report["reports"]["held_out"]["calibration_signature_matches"], 0)
        self.assertEqual(len(report["reports"]["held_out"]["recognition_windows"]), 3)
        self.assertEqual(report["performance_qualified_claim_count"], 0)
        self.assertFalse(report["recommended_enable"])
        self.assertTrue(all(not entry["compatibility_proven"] for entry in report["motifs"]))


class ParameterTests(unittest.TestCase):
    def test_forced_group_and_subcode_are_nested_and_frozen(self):
        groups = motifs.nested_codebook(calibration.DEFAULT_GROUP_SHAPES, [], [])
        for code in range(8):
            subs = groups["groups"][str(code)]["subcodes"]
            self.assertEqual(set(subs), set(map(str, range(8))) if code in calibration.GROUPS else {"0"})
            base = calibration.policy_topology(code, 7, 64, 64, 48)
            for sub, entry in subs.items():
                self.assertEqual(entry["group_subword"] >> 3, code)
                self.assertEqual(entry["group_subword"] & 7, int(sub))
                self.assertEqual(entry["tunable"], sub == "7")
                self.assertFalse(entry["zero_skip_authorized"])
                self.assertIn(motifs.candidate_shape(code, int(sub), base, calibration.DEFAULT_GROUP_SHAPES), calibration.LEGAL_SHAPES)
            if code not in calibration.GROUPS:
                with self.assertRaises(ValueError):
                    motifs.candidate_shape(code, 7, base, calibration.DEFAULT_GROUP_SHAPES)
        for code, sub in ((8, 0), (0, 8), (True, 1), (0, -1)):
            with self.assertRaises(ValueError):
                motifs.candidate_shape(code, sub, base, calibration.DEFAULT_GROUP_SHAPES)

    def test_candidates_use_existing_physics_and_legal_shapes(self):
        for code in range(8):
            work = Counter({calibration.Work("fixture", "prefill", 7, code, 64, 64, 48): 2})
            result = motifs.model_candidates(work, code, calibration.DEFAULT_GROUP_SHAPES)
            expected = calibration.select_subcode(code, 7, 64, 64, 48)
            item = next(iter(work))
            fixed = calibration.ceil_div(calibration.external_traffic(item), 8) + calibration.SHARED_DECISION_CYCLES
            for subcode, row in result["candidates"].items():
                overhead = calibration.EVALUATION_CYCLES + calibration.SWITCH_CYCLES if subcode else 0
                self.assertEqual(row["candidate_cycles"], 2*(fixed + expected["candidate_costs"][subcode] + overhead))
        work = Counter({calibration.Work("fixture", "prefill", 7, 0, 3, 3, 48): 1})
        self.assertEqual(set(motifs.model_candidates(work, 0, calibration.DEFAULT_GROUP_SHAPES)["candidates"]), {0, 1})

    def test_purity_fit_disjoint_defaults_and_no_admitted_claims(self):
        cal, held = walk(), walk(model="held-fixture", weight="b")
        before = deepcopy([cal, held])
        with patch.object(calibration, "fit_groups", wraps=calibration.fit_groups) as fit:
            first = motifs.analyze([cal], [held])
            self.assertEqual(fit.call_count, 1)
            self.assertEqual({item.model for item in fit.call_args.args[0]}, {"calibration-fixture"})
        second = motifs.analyze([cal], [walk(model="different-fixture", weight="c", m=1, n=256, k=127)])
        self.assertEqual([cal, held], before)
        self.assertEqual(first["parameters"], second["parameters"])
        self.assertEqual(first["motifs"], second["motifs"])
        self.assertFalse(first["recommended_enable"])
        self.assertEqual(first["externally_reported_measured_claims"], [])
        self.assertEqual(first["measurement_status"], "no_admitted_actual_array_timing")
        for group in (1, 2, 3):
            self.assertEqual(calibration.group_shape(first["parameters"]["GroupShapeLog2"], group),
                             calibration.group_shape(calibration.DEFAULT_GROUP_SHAPES, group))
        json.dumps(first, allow_nan=False)

    def test_train_heldout_leakage_uses_calibration_check(self):
        for held in (walk(model="CALIBRATION-FIXTURE", weight="b"), walk(model="held-fixture", weight="a")):
            with patch.object(calibration, "fit_groups") as fit, self.assertRaisesRegex(ValueError, "leakage"):
                motifs.analyze([walk()], [held])
            fit.assert_not_called()

    def test_motif_library_bounded_and_deterministic(self):
        cal = walk(64)
        for record in cal["records"]:
            record["module"] = str(record["index"] // 16)
        held = walk(model="held-fixture", weight="b")
        settings = motifs.Settings(MaxMotifs=1)
        first = motifs.analyze([cal], [held], settings=settings)
        self.assertEqual(len(first["motifs"]), 1)
        self.assertEqual(first["template_catalog"]["observed_templates"], 2)
        self.assertEqual(first["reports"]["calibration"]["bounded_library_overflow_windows"], 1)
        self.assertEqual(first["reports"]["calibration"]["template_coverage"]["hits"], 3)
        self.assertEqual(first, motifs.analyze([cal], [held], settings=settings))

    def test_mixed_format_phase_and_epoch_context(self):
        value = walk(16)
        for key, changed in (("numfmt", 6), ("phase", "decode"), ("epoch", "new")):
            records = deepcopy(value["records"])
            records[-1][key] = changed
            work = Counter({calibration.Work("fixture", "prefill", record["numfmt"], 0, 64, 64, 48): 1 for record in records})
            recognition = motifs.recognize(records, None)
            ctx = motifs.context_for(value, motifs.digest(value), 0, records, recognition, work, 0,
                                     calibration.DEFAULT_GROUP_SHAPES, motifs.Settings())
            self.assertFalse(ctx["stable_context"])


def measured_saving(ctx, baseline, net, candidate=None, kind="measured", pair=None):
    value = evidence(ctx, candidate, kind, pair)
    value["baseline"]["cycles"] = baseline
    value["candidate"]["cycles"] = baseline - net - sum(value["tax_cycles"].values())
    return value


class NormalizedGainTests(unittest.TestCase):
    def test_same_sign_insufficient_realized_gain_rejects_and_cools_down(self):
        controller = motifs.WindowController()
        controller.step(context(0), bundle, evidence(context(0)))
        ctx = context(1)
        event = controller.step(ctx, bundle, measured_saving(ctx, 1000, 99))
        self.assertEqual(event["action"], "reject")
        self.assertEqual(event["reason"], "realized_gain_below_threshold")
        self.assertEqual(controller.streak, [])
        self.assertEqual(controller.cooldown, 2)
        self.assertEqual(controller.retained, 0)

    def test_realized_exact_boundary_uses_each_own_baseline(self):
        for baseline, net, accepted in ((1000, 100, True), (10000, 999, False), (10000, 1000, True)):
            controller = motifs.WindowController()
            for i in range(3):
                ctx = context(i)
                event = controller.step(ctx, bundle, measured_saving(ctx, baseline, net))
            with self.subTest(baseline=baseline, net=net):
                self.assertEqual(event["action"], "host_commit" if accepted else "reject")
                self.assertEqual(event["performance_qualified"], accepted)

    def test_realized_boundary_is_exact_above_float_integer_precision(self):
        baseline, limit = 1 << 60, 1 << 58
        model = bundle()
        model["candidates"][7].update(baseline_cycles=baseline, candidate_cycles=baseline//2,
                                       predicted_net_cycles=baseline//2)
        for net, accepted in ((limit, True), (limit-1, False)):
            controller = motifs.WindowController()
            ctx = context()
            event = controller.step(ctx, lambda: model, measured_saving(ctx, baseline, net, model["candidates"][7]))
            self.assertEqual(event["action"], "warmup" if accepted else "reject")

    def test_fractional_additional_tax_cannot_round_up_realized_gain(self):
        baseline, limit = 1 << 60, 1 << 58
        model = bundle()
        model["candidates"][7].update(baseline_cycles=baseline, candidate_cycles=baseline//2,
                                       predicted_net_cycles=baseline//2)
        ctx = context()
        value = evidence(ctx, model["candidates"][7])
        value["baseline"]["cycles"] = baseline
        value["candidate"]["cycles"] = baseline-limit
        value["tax_cycles"] = {key: 0.125 for key in motifs.TAXES}
        event = motifs.WindowController().step(ctx, lambda: model, value)
        self.assertEqual(event["reason"], "realized_gain_below_threshold")

    def test_spread_cross_products_preserve_single_cycle_difference(self):
        controller = motifs.WindowController()
        for i, net in enumerate((1 << 57, 1 << 57, 3*(1 << 56)+1)):
            ctx = context(i)
            event = controller.step(ctx, bundle, measured_saving(ctx, 1 << 60, net))
        self.assertEqual(event["reason"], "unstable_measured_gain")

    def test_positive_spread_beyond_bound_rolls_back_committed_window(self):
        controller = motifs.WindowController()
        for i in range(4):
            ctx = context(i)
            event = controller.step(ctx, bundle, measured_saving(ctx, 1000, 301 if i == 3 else 200))
            if i == 2:
                self.assertEqual(event["action"], "host_commit")
        self.assertEqual(event["action"], "reject")
        self.assertEqual(event["reason"], "unstable_measured_gain")
        self.assertEqual(controller.retained, 0)
        self.assertEqual(controller.streak, [])
        self.assertEqual(controller.cooldown, 2)
        ctx = context(4)
        self.assertEqual(controller.step(ctx, bundle, measured_saving(ctx, 1000, 200))["action"], "cooldown")
        self.assertEqual(controller.streak, [])

    def test_spread_exact_boundary_is_allowed(self):
        controller = motifs.WindowController()
        for i, net in enumerate((200, 200, 300, 200)):
            ctx = context(i)
            event = controller.step(ctx, bundle, measured_saving(ctx, 1000, net))
        self.assertEqual(event["action"], "host_commit")
        bounds = event["consistent_saving_range"]
        self.assertEqual(bounds["minimum"]["numerator"] * 1000, bounds["minimum"]["denominator"] * 200)
        self.assertEqual(bounds["maximum"]["numerator"] * 1000, bounds["maximum"]["denominator"] * 300)
        self.assertNotIn("minimum_consistent_net_cycles", event)

    def test_configured_spread_endpoints_enforce_inclusive_boundaries(self):
        for spread in (0, 8, 16):
            limit = 256*(16+spread)//16
            for final_net, accepted in ((limit, True), (limit+1, False)):
                controller = motifs.WindowController(motifs.Settings(MaxGainSpread16ths=spread))
                for i, net in enumerate((256, 256, final_net)):
                    ctx = context(i)
                    event = controller.step(ctx, bundle, measured_saving(ctx, 1024, net))
                with self.subTest(spread=spread, final_net=final_net):
                    self.assertEqual(event["action"], "host_commit" if accepted else "reject")

    def test_equal_percent_different_work_and_cycles_accepts_zero_spread(self):
        for kind in ("measured", "synthetic", "modeled"):
            controller = motifs.WindowController(motifs.Settings(MaxGainSpread16ths=0))
            for i, scale in enumerate((1, 1000, 3)):
                model = bundle()
                model["candidates"][7].update(baseline_cycles=500*scale, candidate_cycles=400*scale,
                                               predicted_net_cycles=100*scale)
                ctx = context(i, useful_macs=1000*scale, work_signature=f"{scale:064x}", feature_hash=f"{i:064x}")
                event = controller.step(ctx, lambda: model,
                    measured_saving(ctx, 4000*scale, 800*scale, model["candidates"][7], kind))
            self.assertEqual(event["action"], "host_commit" if kind == "measured" else "simulated_commit")
            self.assertEqual(event["performance_qualified"], kind == "measured")
            self.assertEqual(len(controller.streak), 2)

    def test_replayed_pair_cannot_increase_consistent_window_count(self):
        controller = motifs.WindowController()
        for i in range(3):
            ctx = context(i)
            pair = "replayed" if i else "warmup"
            event = controller.step(ctx, bundle, measured_saving(ctx, 1000, 200, pair=pair))
        self.assertEqual(event["action"], "reject")
        self.assertIn("duplicate", event["reason"])
        self.assertEqual(controller.streak, [])
        self.assertEqual(controller.retained, 0)
        self.assertEqual(len(controller.ledger.pairs), 2)

    def test_gain_setting_bounds_and_nondefault_thresholds(self):
        for field, values in (("MinRealizedGain16ths", (0, 17, True, 8.0)),
                              ("MaxGainSpread16ths", (-1, 17, False, 8.0))):
            for value in values:
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    motifs.Settings(**{field: value})
        for minimum in (1, 8, 16):
            settings = motifs.Settings(MinRealizedGain16ths=minimum, MaxGainSpread16ths=16)
            for net, accepted in ((100*minimum, True), (100*minimum-1, False)):
                controller = motifs.WindowController(settings)
                ctx = context()
                event = controller.step(ctx, bundle, measured_saving(ctx, 8000, net))
                self.assertEqual(event["action"], "warmup" if accepted else "reject")

    def test_gain_controls_do_not_retune_codebook_profiles(self):
        cal, held = walk(), walk(model="held-fixture", weight="b")
        first = motifs.analyze([cal], [held])
        second = motifs.analyze([cal], [held], settings=motifs.Settings(MinRealizedGain16ths=16, MaxGainSpread16ths=0))
        self.assertEqual(first["parameter_profiles"], second["parameter_profiles"])
        self.assertEqual(first["parameters"]["GroupShapeLog2"], second["parameters"]["GroupShapeLog2"])
        self.assertEqual(first["parameters"]["fitting"], second["parameters"]["fitting"])
        self.assertEqual(first["template_catalog"], second["template_catalog"])
        self.assertEqual(first["externally_reported_measured_claims"], [])
        self.assertIn("Additional cycles not already included", second["feedback_contract"]["tax_accounting"])
        self.assertFalse(second["recommended_enable"])
        self.assertFalse(second["automatic_production_promotion"])


class ControllerTests(unittest.TestCase):
    def test_warmup_consecutive_measured_commit_and_silence(self):
        controller, factory = motifs.WindowController(), Mock(side_effect=bundle)
        actions = []
        for i in range(5):
            ctx = context(i)
            event = controller.step(ctx, factory, evidence(ctx))
            actions.append(event["action"])
        self.assertEqual(actions, ["warmup", "hold", "host_commit", "host_commit", "host_commit"])
        self.assertEqual(factory.call_count, 1)
        self.assertEqual(controller.evaluations, 1)
        self.assertEqual(event["committed_subcode"], 7)
        self.assertEqual(event["measured"]["net_cycles"], 192)
        self.assertIsNone(event["measured"]["frequency_hz"])
        self.assertNotIn("candidate_net_mac_per_second", event["measured"])

    def test_model_only_never_self_approves(self):
        controller = motifs.WindowController()
        for i in range(12):
            event = controller.step(context(i), bundle)
            self.assertFalse(event["performance_qualified"])
            self.assertEqual(event["committed_subcode"], 0)
        self.assertEqual(controller.retained, 0)

    def test_synthetic_and_modeled_control_cannot_qualify(self):
        for kind in ("synthetic", "modeled"):
            controller = motifs.WindowController()
            for i in range(4):
                ctx = context(i)
                event = controller.step(ctx, bundle, evidence(ctx, kind=kind))
                self.assertFalse(event["performance_qualified"])
                self.assertEqual(event["committed_subcode"], 0)
            self.assertEqual(event["action"], "simulated_commit")
            ctx = context(4)
            changed = controller.step(ctx, bundle, evidence(ctx))
            self.assertEqual(changed["action"], "reject")
            self.assertEqual(changed["reason"], "evidence_kind_change")

    def test_window_rollback_cooldown_and_readmission(self):
        controller = motifs.WindowController()
        actions = []
        for i in range(8):
            ctx = context(i)
            measured = evidence(ctx)
            if i == 3:
                measured["candidate"]["cycles"] = 1100
            event = controller.step(ctx, bundle, measured)
            actions.append(event["action"])
            if 3 <= i <= 6:
                self.assertEqual(event["committed_subcode"], 0)
        self.assertEqual(actions, ["warmup", "hold", "host_commit", "reject", "cooldown", "cooldown", "hold", "host_commit"])

    def test_hysteresis_retains_committed_candidate_until_rejection(self):
        controller = motifs.WindowController()
        for i in range(3):
            ctx = context(i)
            controller.step(ctx, bundle, evidence(ctx))
        changed = bundle()
        changed["winner"] = 1
        ctx = context(3, feature_hash="9"*64)
        event = controller.step(ctx, lambda: changed, evidence(ctx))
        self.assertEqual(event["committed_subcode"], 7)
        self.assertEqual(event["proposed_subcode"], 7)
        self.assertEqual(controller.evaluations, 2)
        ctx = context(4, feature_hash="9"*64)
        bad = evidence(ctx)
        bad["mispredict"] = True
        self.assertEqual(controller.step(ctx, bundle, bad)["action"], "reject")
        self.assertEqual(controller.retained, 0)

    def test_context_change_gap_partial_and_missing_evidence_drop(self):
        for changes in ({"epoch": "new"}, {"numfmt": 6}, {"profile": "new-profile"}, {"groupcode": 3},
                        {"stable_context": False}, {"complete_window": False}, {"window_index": 8}):
            controller = motifs.WindowController()
            for i in range(3):
                ctx = context(i)
                controller.step(ctx, bundle, evidence(ctx))
            event = controller.step(context(3, **changes), bundle)
            self.assertEqual(event["action"], "reject")
            self.assertEqual(controller.retained, 0)
        controller = motifs.WindowController()
        for i in range(3):
            ctx = context(i)
            controller.step(ctx, bundle, evidence(ctx))
        self.assertEqual(controller.step(context(3), bundle)["action"], "reject")

    def test_missing_window_breaks_consistency(self):
        controller = motifs.WindowController(motifs.Settings(Cooldown=0))
        for i in range(5):
            ctx = context(i)
            event = controller.step(ctx, bundle, None if i == 2 else evidence(ctx))
            self.assertEqual(event["performance_qualified"], i == 4)

    def test_invalid_and_stale_evidence_fail_closed(self):
        changes = [("profile", "wrong"), ("numfmt", 6), ("window_index", 9), ("epoch", "old"),
                   ("work_signature", "wrong"), ("useful_macs", 999), ("feature_hash", "wrong"),
                   ("subcode", 1), ("groupcode", 5), ("mispredict", True), ("externally_provided", False),
                   ("measurement_scope", "cpu-wall-time"), ("evidence_kind", "native-capture")]
        for key, change in changes:
            controller = motifs.WindowController()
            ctx = context()
            invalid = evidence(ctx)
            invalid[key] = change
            with self.subTest(key=key):
                self.assertEqual(controller.step(ctx, bundle, invalid)["action"], "reject")

    def test_pair_mismatch_topology_clock_and_tax(self):
        for key, change in (("numfmt", 6), ("useful_macs", 900), ("work_signature", "other"),
                            ("topology_sha256", "wrong"), ("clock_id", "cpu"), ("cycles", 0),
                            ("cycles", 1.0), ("cycles", True), ("seconds", 0.00001)):
            ctx = context()
            invalid = evidence(ctx)
            invalid["candidate"][key] = change
            with self.subTest(key=key), self.assertRaises(ValueError):
                motifs.EvidenceLedger().validate(invalid, ctx, bundle()["candidates"][7])
        for taxes in ({"lookup": 0}, {key: -1 for key in motifs.TAXES}, {key: float("nan") for key in motifs.TAXES}):
            ctx = context()
            invalid = evidence(ctx)
            invalid["tax_cycles"] = taxes
            self.assertEqual(motifs.WindowController().step(ctx, bundle, invalid)["action"], "reject")
        ctx = context()
        invalid = evidence(ctx)
        invalid["tax_cycles"]["topology"] = 300
        self.assertEqual(motifs.WindowController().step(ctx, bundle, invalid)["reason"], "signed_regression_or_tax_exhausted_gain")

    def test_forced_unsupported_control_and_numeric_overflow_fail_closed(self):
        for code in (1, 2, 4, 7):
            ctx = context(groupcode=code)
            result = motifs.WindowController().step(ctx, bundle, evidence(ctx))
            self.assertEqual(result["action"], "reject")
        for value in (10**400, 1e308, float("inf"), -1, True):
            ctx = context()
            invalid = evidence(ctx)
            invalid["tax_cycles"]["lookup"] = value
            self.assertEqual(motifs.WindowController().step(ctx, bundle, invalid)["action"], "reject")

    def test_clock_frequency_change_between_windows_resets_qualification(self):
        controller = motifs.WindowController()
        for i in range(4):
            ctx = context(i)
            value = evidence(ctx)
            value["baseline"]["frequency_hz"] = 1000 if i < 3 else 2000
            value["candidate"]["frequency_hz"] = value["baseline"]["frequency_hz"]
            result = controller.step(ctx, bundle, value)
        self.assertEqual(result["action"], "reject")
        self.assertEqual(result["reason"], "clock_or_frequency_epoch_change")
        self.assertEqual(controller.retained, 0)

    def test_positive_measured_gain_cannot_override_negative_model(self):
        model = bundle()
        model["candidates"][7]["predicted_net_cycles"] = -1
        ctx = context()
        result = motifs.WindowController().step(ctx, lambda: model, evidence(ctx))
        self.assertEqual(result["action"], "reject")
        self.assertFalse(result["performance_qualified"])

    def test_duplicate_pairs_sources_and_frequency(self):
        ledger = motifs.EvidenceLedger()
        ctx = context()
        value = evidence(ctx)
        ledger.validate(value, ctx, bundle()["candidates"][7])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            ledger.validate(value, ctx, bundle()["candidates"][7])
        value["pair_id"] = "renamed"
        with self.assertRaisesRegex(ValueError, "duplicate"):
            ledger.validate(value, ctx, bundle()["candidates"][7])
        value = evidence(ctx)
        value["baseline"]["frequency_hz"] = 1000
        value["candidate"]["frequency_hz"] = 1000
        measured = motifs.EvidenceLedger().validate(value, ctx, bundle()["candidates"][7])
        self.assertEqual(measured["baseline_mac_per_second"], 1000)
        for invalid in (0, -1, 2000, float("inf"), True):
            value["candidate"]["frequency_hz"] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                motifs.EvidenceLedger().validate(value, ctx, bundle()["candidates"][7])


class PipelineTests(unittest.TestCase):
    def test_feedback_never_fits_and_claims_separate(self):
        cal = walk(m=4, n=4, k=127)
        held = walk(model="held-fixture", weight="b", m=4, n=4, k=127)
        original = motifs.analyze([cal], [held])
        rows = []
        for split in ("calibration", "held_out"):
            for index, event in enumerate(original["reports"][split]["control_trace"]):
                ctx = event["evidence_context"]
                records = (cal if split == "calibration" else held)["records"][ctx["start_index"]:ctx["start_index"]+16]
                work = motifs.window_work(cal if split == "calibration" else held, records)
                candidates = motifs.model_candidates(work, ctx["groupcode"], original["parameters"]["GroupShapeLog2"])
                chosen = candidates["candidates"][candidates["winner"]]
                rows.append({"capture_sha256": ctx["capture_sha256"], "start_index": ctx["start_index"],
                             "groupcode": ctx["groupcode"], "evidence": evidence(ctx, chosen,
                                 "synthetic" if split == "calibration" else "measured", split+str(index))})
        report = motifs.analyze([cal], [held], {"schema": motifs.FEEDBACK_SCHEMA, "windows": rows})
        self.assertEqual(original["parameters"], report["parameters"])
        self.assertFalse(report["recommended_enable"])
        self.assertEqual(report["performance_qualified_claim_count"], 1)
        self.assertEqual(report["externally_reported_measured_claims"][0]["split"], "held_out")
        self.assertFalse(report["automatic_production_promotion"])

    def test_unknown_and_duplicate_feedback_routes_rejected(self):
        row = {"capture_sha256": "1"*64, "start_index": 0, "groupcode": 0, "evidence": {}}
        with self.assertRaisesRegex(ValueError, "duplicate"):
            motifs.feedback_index({"schema": motifs.FEEDBACK_SCHEMA, "windows": [row, row]})
        with self.assertRaisesRegex(ValueError, "unknown"):
            motifs.analyze([walk()], [walk(model="held-fixture", weight="b")],
                           {"schema": motifs.FEEDBACK_SCHEMA, "windows": [row]})

    def test_cli_roundtrip_and_source_protection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cal, held, output = root/"cal.json", root/"held.json", root/"out.json"
            cal.write_text(json.dumps(walk()), encoding="utf-8")
            held.write_text(json.dumps(walk(model="held-fixture", weight="b")), encoding="utf-8")
            args = ["--calibration", str(cal), "--held-out", str(held), "--out", str(output)]
            self.assertEqual(motifs.main(args), 0)
            report = calibration.strict_json_loads(output.read_bytes())
            self.assertFalse(report["recommended_enable"])
            self.assertIn("calibrator_sha256", report)
            self.assertEqual(report["settings"]["MinRealizedGain16ths"], 8)
            self.assertEqual(report["settings"]["MaxGainSpread16ths"], 8)
            self.assertEqual(motifs.main(args + ["--min-realized-gain16ths", "16", "--max-gain-spread16ths", "0"]), 0)
            configured = calibration.strict_json_loads(output.read_bytes())
            self.assertEqual(configured["settings"]["MinRealizedGain16ths"], 16)
            self.assertEqual(configured["settings"]["MaxGainSpread16ths"], 0)
            self.assertEqual(report["parameter_profiles"], configured["parameter_profiles"])
            for target in (cal, root/"output.sv"):
                with self.assertRaises(SystemExit):
                    motifs.main(args[:-1]+[str(target)])


if __name__ == "__main__":
    unittest.main()
