from collections import Counter
from copy import deepcopy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import tempfile
import unittest
from unittest.mock import patch

import policy_calibration as p


def runner_module():
    path = Path(__file__).resolve().parents[2] / "regress" / "ai-policy-subcode.py"
    spec = importlib.util.spec_from_file_location("policy_subcode_runner", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def capture(model="cal", digest="a", m=64, n=64, k=127, batch=1, fmt=7):
    a, b = ([batch, m, k], [batch, k, n]) if batch != 1 else ([m, k], [k, n])
    astride, bstride = ([m*k, k, 1], [k*n, n, 1]) if batch != 1 else ([k, 1], [n, 1])
    return {"schema": p.SCHEMA,
            "source": {"model_id": model, "revision": "1"*40, "weights": "pretrained", "framework": "pytorch",
                       "framework_version": "2.6", "transformers_version": "4.48", "script_sha256": "2"*64,
                       "weight_sha256": {"model.safetensors": digest*64}, "config_sha256": "3"*64},
            "execution": {"device": "cpu", "dtype": "torch.float32", "input_kind": "development-prompt",
                          "prompt_sha256": "4"*64, "prefill_tokens": 64, "decode_steps": 1, "finite_logits": True},
            "records": [{"index": 0, "phase": "prefill", "operator": "aten.mm.default", "module": "layer",
                         "m": m, "n": n, "k": k, "batch": batch, "numfmt": fmt, "opcode_class": 0,
                         "a_shape": a, "b_shape": b, "a_stride": astride, "b_stride": bstride,
                         "native_sample_hex": "0"*(2 * (1 << p.BITS_LOG2[fmt])) if m*k >= 8 else "",
                         "sample_valid": m*k >= 8, "exact_zero": False}],
            "other_operators": {"aten.add.Tensor": 2}}


def loop_cost(m, n, k, fmt, topology, read_bytes):
    bits = {0: 8, 1: 4, 3: 8, 4: 8, 5: 16, 6: 16, 7: 32}[fmt]
    total = 0
    for row in range(0, m, 2**topology.rows):
        for col in range(0, n, 2**topology.cols):
            for offset in range(0, k, 2**topology.reduction):
                active = min(2**topology.reduction, k-offset)
                bytes_per_row = (active*bits + 7)//8
                needed = (2**topology.rows + 2**topology.cols)*bytes_per_row
                total += max(1, (needed + read_bytes - 1)//read_bytes)
    return total


class TailOpportunityTests(unittest.TestCase):
    def test_opportunity_bounds_and_alignment(self):
        rng = random.Random(500)
        for _ in range(200):
            item = p.Work("fixture", "prefill", rng.choice(tuple(p.FORMAT_NAMES)), 0,
                          rng.randint(1, 256), rng.randint(1, 256), rng.randint(1, 256))
            read = rng.choice((1, 128, 512, 4096))
            fixed = p.ceil_div(p.external_traffic(item), 8) + p.SHARED_DECISION_CYCLES
            masked = p.masked_oracle_cost(item, read)
            aligned = p.oracle_cost(item, read)
            self.assertLessEqual(masked, aligned)
            self.assertGreaterEqual(fixed + masked, p.roofline_cycles(item, read))

    def test_partial_output_groups_match_loop(self):
        for fmt in (0, 1, 3, 4, 5, 6, 7):
            for m, n, k in ((23, 256, 255), (3, 5, 7), (1, 1, 1)):
                base = p.policy_topology(0, fmt, m, n, k)
                t = p.candidate_topology(base, (2, 2))
                expected, macs = 0, 0
                for i in range(0, m, 4):
                    for j in range(0, n, 4):
                        for offset in range(0, k, 1 << t.reduction):
                            r, c, d = min(4, m-i), min(4, n-j), min(1 << t.reduction, k-offset)
                            expected += max(1, p.ceil_div((r+c) * p.row_bytes(d, fmt), 128))
                            macs += r*c*d
                self.assertEqual(macs, m*n*k)
                self.assertEqual(p.masked_native_cost(m, n, k, fmt, t), expected)


class CaptureTests(unittest.TestCase):
    def test_native_linear_weight_orientation(self):
        value = capture(m=3, n=5, k=7)
        record = value["records"][0]
        record.update(operator="aten.linear.default", b_shape=[5, 7], b_stride=[7, 1],
                      b_matrix_orientation="transposed")
        self.assertIs(p.validate_capture(value), value)
        record["b_matrix_orientation"] = "normal"
        with self.assertRaises(ValueError):
            p.validate_capture(value)
        record.update(operator="aten.mm.default", b_matrix_orientation="transposed")
        with self.assertRaises(ValueError):
            p.validate_capture(value)

    def test_capture_cli_dtype_labels(self):
        for dtype in ("fp32", "bf16"):
            value = capture()
            value["execution"]["dtype"] = dtype
            self.assertIs(p.validate_capture(value), value)

    def test_valid_extra_provenance(self):
        value = capture()
        value["source"]["repository_url"] = "https://example.invalid/model"
        self.assertIs(p.validate_capture(value), value)

    def test_duplicate_and_nonfinite(self):
        for raw in ('{"a":1,"a":2}', '{"a":{"x":1,"x":2}}', '{"n":NaN}', '{"n":Infinity}', '{"n":-Infinity}', '{"n":1e999}'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                p.strict_json_loads(raw)

    def test_malformed_capture(self):
        bad = []
        for key, val in (("schema", "synthetic"), ("records", []), ("other_operators", {"add": -1})):
            value = capture()
            value[key] = val
            bad.append(value)
        for key, val in (("m", -1), ("n", 0), ("k", True), ("batch", -2), ("numfmt", 2), ("numfmt", 8),
                         ("opcode_class", 2), ("native_sample_hex", "xyz"), ("sample_valid", 1), ("exact_zero", True),
                         ("a_stride", [-1, 1]), ("a_shape", [64, 1]), ("b_shape", [64, 127]), ("index", 2), ("phase", "train")):
            value = capture()
            value["records"][0][key] = val
            bad.append(value)
        for key, val in (("weights", "random"), ("framework", "synthetic"), ("revision", "main"),
                         ("weight_sha256", {}), ("script_sha256", "bad"), ("config_sha256", "0"*63)):
            value = capture()
            value["source"][key] = val
            bad.append(value)
        for key, val in (("finite_logits", False), ("decode_steps", -1), ("prefill_tokens", 0), ("dtype", "float64")):
            value = capture()
            value["execution"][key] = val
            bad.append(value)
        value = capture()
        value["records"].append(deepcopy(value["records"][0]))
        bad.append(value)
        for value in bad + [None, {}, {"schema": p.SCHEMA, "source": []}]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                p.validate_capture(value)

    def test_native_sample_matches_capture_producer(self):
        import capture_policy_model as producer
        for dtype, fmt, m, k in (("torch.float32", 7, 2, 4), ("torch.bfloat16", 6, 2, 4),
                                 ("torch.float32", 7, 1, 4), ("torch.bfloat16", 6, 1, 4)):
            value = capture(m=m, n=5, k=k, fmt=fmt)
            sample = value["records"][0]["native_sample_hex"]
            value["records"][0] = producer.matrix_record(0, "prefill", "aten.mm.default", "layer",
                [m, k], [k, 5], [k, 1], [5, 1], dtype, dtype, sample)
            self.assertIs(p.validate_capture(value), value)
        for fmt in p.FORMAT_NAMES:
            p.validate_capture(capture(fmt=fmt))
        for sample, valid, m, k in (("0"*64, True, 1, 4), ("0"*64, False, 2, 4),
                                    ("0x" + "0"*64, True, 2, 4), ("", True, 2, 4)):
            value = capture(m=m, k=k)
            value["records"][0].update(native_sample_hex=sample, sample_valid=valid)
            with self.assertRaises(ValueError):
                p.validate_capture(value)
        value = capture(fmt=6)
        value["records"][0]["native_sample_hex"] = "0"*64
        with self.assertRaises(ValueError):
            p.validate_capture(value)
        p.validate_capture(capture(m=1, k=4, batch=16))

    def test_record_order_is_provenance(self):
        value = capture()
        value["records"].append({**value["records"][0], "index": 1})
        p.validate_capture(value)
        value["records"].reverse()
        with self.assertRaises(ValueError):
            p.validate_capture(value)

    def test_operand_dtype_binding_not_global_dtype(self):
        value = capture(fmt=7)
        value["execution"]["dtype"] = "torch.bfloat16"
        value["records"][0].update(a_dtype="torch.float32", b_dtype="torch.float32")
        p.validate_capture(value)
        for dtype in ("torch.bfloat16", "torch.float64", None, 7):
            for operand in ("a_dtype", "b_dtype"):
                wrong = deepcopy(value)
                wrong["records"][0][operand] = dtype
                with self.assertRaises(ValueError):
                    p.validate_capture(wrong)

    def test_split_leakage(self):
        cal = capture()
        for test in (capture("cal", "b"), capture("other", "a"), capture("CAL", "b")):
            with self.assertRaises(ValueError):
                p.calibrate([cal], [test])
        p.check_disjoint([cal], [capture("held", "b")])

    def test_tiling_mac_and_weight_conservation(self):
        value = capture(m=513, n=257, k=511, batch=3, fmt=1)
        work, stats = p.tile_captures([value])
        self.assertEqual(stats["useful_macs"], 513*257*511*3)
        self.assertEqual(stats["independent_tile_count"], 3*2*2*3)
        self.assertEqual(sum(w.macs()*count for w, count in work.items()), stats["useful_macs"])
        self.assertTrue(all(max(w.m, w.n, w.k) <= 256 for w in work))
        self.assertTrue(all(w.fmt == 1 and w.code != 6 for w in work))
        self.assertEqual(stats["sample_discarded_records"], 1)
        changed = deepcopy(value)
        changed["records"][0]["native_sample_hex"] = "f"*len(value["records"][0]["native_sample_hex"])
        self.assertEqual(p.tile_captures([changed]), (work, stats))

    def test_huge_batch_aggregated_exactly(self):
        work, stats = p.tile_captures([capture(m=256, n=256, k=256, batch=1_000_001)])
        self.assertEqual(len(work), 1)
        self.assertEqual(sum(work.values()), 1_000_001)
        self.assertEqual(stats["useful_macs"], 256**3 * 1_000_001)


class NativeTests(unittest.TestCase):
    def test_config_bitdecode(self):
        self.assertEqual([p.nibble(p.FORMAT_SLOTS, f) for f in range(8)], [8, 9, 0, 8, 8, 7, 7, 6])
        self.assertEqual([1 << p.BITS_LOG2[f] for f in range(8)], [8, 4, 8, 8, 8, 16, 16, 32])
        self.assertEqual([p.group_shape(p.DEFAULT_GROUP_SHAPES, g) for g in range(4)], [(1, 2), (0, 3), (0, 2), (2, 1)])
        for group in range(4):
            for shape in p.LEGAL_SHAPES:
                self.assertEqual(p.group_shape(p.set_group_shape(p.DEFAULT_GROUP_SHAPES, group, shape), group), shape)

    def test_raw_encoder_boundaries(self):
        vectors = [(1, 9, 9, 0, 3), (8, 9, 9, 0, 3), (8, 9, 8, 0, 1), (9, 9, 9, 0, 0),
                   (64, 65, 9, 0, 1), (65, 64, 9, 0, 2), (100, 256, 9, 0, 0), (1, 9, 9, 1, 4)]
        for m, n, k, op, expected in vectors:
            self.assertEqual(p.raw_code(m, n, k, op), expected)

    def test_topology_boundary_vectors(self):
        vectors = [(0, 0, 64, 64, 256, 1, 128, (1, 2, 2, 4, 12)),
                   (2, 0, 64, 64, 256, 1, 128, (1, 2, 2, 4, 12)),
                   (0, 1, 64, 64, 255, 1, 128, (1, 2, 2, 5, 12)),
                   (3, 7, 1, 16, 64, 0, 128, (1, 0, 4, 2, 7)),
                   (0, 0, 7, 7, 127, 1, 128, (0, 0, 0, 8, 0)),
                   (0, 0, 8, 8, 129, 1, 4096, (0, 0, 0, 8, 0)),
                   (0, 0, 8, 8, 128, 1, 4096, (1, 2, 2, 4, 12)),
                   (0, 0, 8, 8, 256, 1, 4096, (1, 2, 2, 4, 12)),
                   (0, 0, 64, 64, 256, 0, 128, (0, 0, 0, 8, 0)),
                   (7, 0, 64, 64, 256, 1, 128, (0, 0, 0, 8, 0))]
        for code, fmt, m, n, k, balance, read, expected in vectors:
            t = p.policy_topology(code, fmt, m, n, k, balance, read)
            self.assertEqual((t.apply, t.rows, t.cols, t.reduction, t.gain), expected)
            self.assertEqual(t.rows + t.cols + t.reduction, t.slots)
        self.assertFalse(p.policy_topology(0, 2, 64, 64, 64).valid)
        self.assertFalse(p.policy_topology(0, 0, 0, 64, 64).valid)

    def test_independent_cost_loop(self):
        rng = random.Random(137)
        for _ in range(180):
            fmt = rng.choice(list(p.FORMAT_NAMES))
            r, c = rng.choice(p.LEGAL_SHAPES)
            m, n, k = (1 << r)*rng.randint(1, 3), (1 << c)*rng.randint(1, 3), rng.randint(1, 256)
            base = p.policy_topology(0, fmt, m, n, k)
            candidate = p.candidate_topology(base, (r, c))
            read = rng.choice((1, 8, 128, 4096))
            self.assertEqual(p.native_cost(m, n, k, fmt, candidate, read), loop_cost(m, n, k, fmt, candidate, read))

    def test_odd_int4_tail_row_rounding(self):
        t = p.candidate_topology(p.policy_topology(0, 1, 4, 4, 3), (2, 2))
        self.assertEqual(p.native_cost(4, 4, 3, 1, t, 8), 2)
        self.assertEqual(p.row_bytes(3, 1), 2)
        self.assertEqual(p.native_cost(4, 4, 33, 1, t, 8), 17)

    def test_selection_independent_and_strict_margins(self):
        rng = random.Random(32)
        for _ in range(120):
            code, fmt = rng.choice((0, 3, 5, 6)), rng.choice(list(p.FORMAT_NAMES))
            m, n, k = rng.randrange(1, 33), rng.randrange(1, 65), rng.randrange(1, 257)
            t = p.policy_topology(code, fmt, m, n, k)
            shapes = [(t.rows, t.cols), (0, 0), (0, 4), (1, 3), (2, 2), (3, 1), (4, 0), p.group_shape(p.DEFAULT_GROUP_SHAPES, p.GROUPS[code])]
            costs = [loop_cost(m, n, k, fmt, p.candidate_topology(t, s), 128)
                     if m % (2**s[0]) == 0 and n % (2**s[1]) == 0 else None for s in shapes]
            best = min(i for i in range(8) if costs[i] == min(c for c in costs if c is not None))
            chosen = best if best != 0 and costs[best] + 36 < costs[0] else 0
            actual = p.select_subcode(code, fmt, m, n, k)
            self.assertEqual(actual["subcode"], chosen)
            self.assertEqual(actual["selected"], costs[chosen] + 32 + (2 if chosen else 0))
            self.assertEqual(actual["candidate_costs"], tuple(costs))
        for code in (1, 2, 4, 7):
            actual = p.select_subcode(code, 7, 64, 64, 64)
            self.assertFalse(actual["evaluated"])
            self.assertEqual(actual["selected"], actual["baseline"])
        near_peak = p.select_subcode(0, 0, 64, 64, 256)
        self.assertEqual(near_peak["selected"], near_peak["baseline"] + 32)


class CalibrationTests(unittest.TestCase):
    def test_fit_only_calibration_and_unobserved_defaults(self):
        cal = capture(m=64, n=64, k=48)
        first = p.calibrate([cal], [capture("held", "b", m=1, n=256, k=256)])
        second = p.calibrate([cal], [capture("other", "c", m=513, n=513, k=777)])
        self.assertEqual(first["parameters"], second["parameters"])
        self.assertEqual(first["fitting"], second["fitting"])
        self.assertEqual(first["calibration"], second["calibration"])
        groups = first["parameters"]["GroupShapeLog2"]
        for group in (1, 2, 3):
            self.assertEqual(p.group_shape(groups, group), p.group_shape(p.DEFAULT_GROUP_SHAPES, group))
        self.assertFalse(first["recommended_enable"])

    def test_fit_exact_weighted_objective(self):
        work = Counter({p.Work("cal", "prefill", 7, 0, 64, 64, 48): 13,
                        p.Work("cal", "prefill", 7, 0, 8, 8, 33): 2})
        params, objectives = p.fit_groups(work)
        scores = [sum(count * p.select_subcode(w.code, w.fmt, w.m, w.n, w.k,
                                             p.set_group_shape(p.DEFAULT_GROUP_SHAPES, 0, shape))["selected"]
                      for w, count in work.items()) for shape in p.LEGAL_SHAPES]
        self.assertEqual(objectives[0]["selected_native_cycles"], min(scores))
        self.assertEqual(objectives[0]["observed_tile_count"], 15)

    def test_roofline_and_fixed_spill(self):
        item = p.Work("x", "decode", 1, 3, 1, 16, 255)
        traffic = 17*128 + 8*16
        self.assertEqual(p.external_traffic(item), traffic)
        expected = 1 + (traffic + 7)//8 + max((4080 + 511)//512, (17*128 + 127)//128)
        self.assertEqual(p.roofline_cycles(item), expected)
        work, _ = p.tile_captures([capture(m=256, n=256, k=512)])
        self.assertEqual(sum(p.external_traffic(w)*n for w, n in work.items()), 2*((256+256)*1024 + 8*256*256))
        summary = p.report_work(work, p.DEFAULT_GROUP_SHAPES)
        report = summary["total"]
        self.assertEqual(sum(row["tile_count"] for row in summary["raw_policy_usage"]), report["independent_tile_count"])
        for field in ("tile_share_percent", "useful_mac_share_percent", "baseline_cycle_share_percent"):
            self.assertAlmostEqual(sum(row[field] for row in summary["raw_policy_usage"]), 100)
        self.assertLess(report["maximum_possible_throughput_ratio"], 6)
        self.assertEqual(report["model_feasibility"], "impossible_under_fixed_service_assumptions")
        self.assertLessEqual(report["roofline_lower_bound_cycles"], report["oracle_diagnostic_cycles"])
        self.assertLessEqual(report["oracle_diagnostic_cycles"], report["existing_allocator_cycles"])

    def test_sign_percentage(self):
        gain = p.deltas(600, 100)
        self.assertEqual(gain["throughput_delta_percent"], 500)
        self.assertAlmostEqual(gain["normalized_time"], 1/6)
        self.assertAlmostEqual(gain["time_reduction_percent"], 100*5/6)
        regress = p.deltas(100, 200)
        self.assertEqual(regress["throughput_delta_percent"], -50)
        self.assertEqual(regress["time_delta_percent"], 100)

    def test_service_bounds(self):
        for value in (0, -1, 3, 8192, True):
            with self.assertRaises(ValueError):
                p.service_bytes(value)
        for value in (1, 8, 128, 4096):
            self.assertEqual(p.service_bytes(value), value)

    def test_closed_replay_roundtrip_and_bounds(self):
        report = p.calibrate([capture()], [capture("held", "b")])
        raw, coverage = p.replay_export(report)
        runner = runner_module()
        replay = runner.validate_replay(p.strict_json_loads(raw))
        self.assertEqual(runner.decode_replay(raw), replay)
        self.assertEqual(len(replay["records"]), 1)
        self.assertEqual(coverage["sample_aggregate_cases"], 2)
        self.assertEqual(coverage["distinct_replay_records"], 1)
        self.assertEqual(set(replay["parameters"]), set(runner.REPLAY_PARAMETERS))
        case = report["rtl_replay"]["calibration"]["cases"][0]
        self.assertEqual(replay["records"][0]["baseline_cycles"], case["expected"]["rtl_baseline_cycles"])
        self.assertEqual(replay["records"][0]["selected_cycles"], case["expected"]["rtl_selected_cycles"])
        attention = capture("attention", "c")
        attention["records"][0]["opcode_class"] = 1
        raw, _ = p.replay_export(p.calibrate([capture()], [attention]))
        replay = runner.decode_replay(raw)
        fallback = next(record for record in replay["records"] if record["code"] == 4)
        self.assertEqual((fallback["baseline_cycles"], fallback["selected_cycles"]), (0, 0))
        with patch.object(p, "REPLAY_MAX_BYTES", 1), self.assertRaises(ValueError):
            p.replay_export(report)
        case = report["rtl_replay"]["calibration"]["cases"][0]
        report["rtl_replay"]["calibration"]["cases"] = [
            {**case, "m": i % 256 + 1, "n": i // 256 + 1} for i in range(1025)]
        with self.assertRaises(ValueError):
            p.replay_export(report)

    def test_output_aliases_rejected_without_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            cal, test, output, replay = (Path(directory)/name for name in ("cal.json", "held.json", "out.json", "replay.json"))
            cal.write_text(json.dumps(capture()), encoding="utf-8")
            test.write_text(json.dumps(capture("held", "b")), encoding="utf-8")
            original = cal.read_bytes()
            for report_path, replay_path in ((output, cal), (cal, replay), (output, output),
                                               (output, output.parent / "." / output.name)):
                with self.assertRaises(SystemExit):
                    p.main(["--calibration", str(cal), "--held-out", str(test), "--out", str(report_path), "--replay-out", str(replay_path)])
                self.assertEqual(cal.read_bytes(), original)
                self.assertFalse(output.exists())
            alias = Path(directory)/"hardlink.json"
            try:
                os.link(cal, alias)
            except OSError:
                return
            with self.assertRaises(SystemExit):
                p.main(["--calibration", str(cal), "--held-out", str(test), "--out", str(output), "--replay-out", str(alias)])
            self.assertEqual(cal.read_bytes(), original)
            self.assertFalse(output.exists())

    def test_cli_provenance_and_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            cal, test, output = (Path(directory)/name for name in ("cal.json", "held.json", "out.json"))
            cal.write_text(json.dumps(capture()), encoding="utf-8")
            test.write_text(json.dumps(capture("held", "b")), encoding="utf-8")
            replay_path = Path(directory)/"replay.json"
            self.assertEqual(p.main(["--calibration", str(cal), "--held-out", str(test), "--out", str(output), "--replay-out", str(replay_path)]), 0)
            report = p.strict_json_loads(output.read_text(encoding="utf-8"))
            replay_raw = replay_path.read_bytes()
            runner_module().validate_replay(json.loads(replay_raw))
            self.assertEqual(report["replay_provenance"]["sha256"], hashlib.sha256(replay_raw).hexdigest())
            self.assertEqual(report["replay_provenance"]["coverage"]["distinct_replay_records"], 1)
            self.assertEqual(len(report["capture_provenance"]["calibration"][0]["capture_sha256"]), 64)
            replay = report["rtl_replay"]["calibration"]["cases"][0]
            self.assertEqual(replay["count"], 1)
            self.assertLessEqual(max(replay["m"], replay["n"], replay["k"]), 256)
            self.assertEqual(replay["baseline"], replay["expected"]["baseline_topology"])


if __name__ == "__main__":
    unittest.main()
