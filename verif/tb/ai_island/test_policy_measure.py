"""SPDX-FileCopyrightText: 2026 Etienne Cimon
SPDX-License-Identifier: MIT
"""

from fractions import Fraction
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import policy_measure as measure


C16 = "0000001000000010"
FP16_C = "4180000041800000"
FORMATS = (0, 1, 3, 4, 5, 6, 7)


def run(fmt, ar, cycles, m=2, n=2, k=16, pmu=None, r_beats=8, w_beats=2, c0=None, c1=None):
    golden = C16 if fmt in (0, 1) else FP16_C
    return ("MEASURE fmt=%d ar=%d m=%d n=%d k=%d macs=%d cycles=%d pmu_cycles=%d "
            "r_beats=%d w_beats=%d c0=%s c1=%s"
            % (fmt, ar, m, n, k, m * n * k, cycles, pmu if pmu is not None else cycles - 1,
               r_beats, w_beats, c0 or golden, c1 or golden))


def begin(ar_max=2, schema=measure.SCHEMA, source=measure.CYCLE_SOURCE, nch=1, dpf=0, dram_class=0,
          tb="tb_g6lc_ai_gemm_backend"):
    return ("MEASURE_BEGIN schema=%s tb=%s cycle_source=%s class=%d nch=%d dpf=%d ar_max=%d"
            % (schema, tb, source, dram_class, nch, dpf, ar_max))


def end(runs, ar_max=2, formats=7):
    return "MEASURE_END runs=%d formats=%d ar_max=%d" % (runs, formats, ar_max)


def block(cycles, ar_max=2, formats=FORMATS, **kwargs):
    """One sweep block: `cycles` maps ar -> completion cycles, same for every format."""
    lines = [begin(ar_max=ar_max, **kwargs)]
    lines += [run(fmt, ar, cycles[ar]) for fmt in formats for ar in range(1, ar_max + 1)]
    lines.append(end(len(formats) * ar_max, ar_max=ar_max, formats=len(formats)))
    return lines


def log(*blocks, noise=True):
    lines = ["[nch-from-env] class=0 channels=1"] if noise else []
    for entry in blocks:
        lines += entry
    if noise:
        lines.append("PASS g6lc_ai_gemm_backend class=0 nch=1 ar=42 cycles=900 r=0/0 goldenC=16")
    return ("\n".join(lines) + "\n").encode("utf-8")


class ParsingTests(unittest.TestCase):
    def test_parses_blocks_records_and_ignores_other_output(self):
        blocks, records = measure.parse_log(log(block({1: 200, 2: 190})).decode())
        self.assertEqual(len(blocks), 1)
        self.assertEqual(blocks[0], {"index": 0, "tb": "tb_g6lc_ai_gemm_backend", "dram_class": 0,
                                    "channels": 1, "dot_pipe_float": False, "ar_max": 2,
                                    "repeat": 0, "runs": 14})
        self.assertEqual(len(records), 14)
        first = records[0]
        self.assertEqual((first["block"], first["numfmt"], first["numfmt_name"], first["ar_max"]),
                         (0, 0, "INT8", 1))
        self.assertEqual((first["m"], first["n"], first["k"], first["useful_macs"]), (2, 2, 16, 64))
        self.assertEqual((first["cycles"], first["pmu_cycles"], first["r_beats"], first["w_beats"]),
                         (200, 199, 8, 2))
        self.assertEqual(first["result_digest"], measure.digest(C16, C16))

    def test_multiple_blocks_are_repeated_observations(self):
        blocks, records = measure.parse_log(log(block({1: 200, 2: 190}),
                                                block({1: 300, 2: 280}, nch=2, dpf=1)).decode())
        self.assertEqual([entry["index"] for entry in blocks], [0, 1])
        self.assertEqual((blocks[1]["channels"], blocks[1]["dot_pipe_float"]), (2, True))
        self.assertEqual(len(records), 28)
        table = measure.per_format(records, 1)
        self.assertEqual(table[0]["blocks"], [0, 1])
        self.assertEqual(len(table[0]["depths"][2]), 2)

    def test_deeper_ar_max_sweep(self):
        cycles = {ar: 200 - 10 * ar for ar in range(1, 9)}
        blocks, records = measure.parse_log(log(block(cycles, ar_max=8)).decode())
        self.assertEqual(blocks[0]["ar_max"], 8)
        self.assertEqual(len(records), 56)


class RejectionTests(unittest.TestCase):
    def reject(self, raw, needle=None):
        with self.assertRaises(ValueError) as caught:
            measure.parse_log(raw.decode() if isinstance(raw, bytes) else raw)
        if needle:
            self.assertIn(needle, str(caught.exception))

    def test_missing_and_wrong_schema(self):
        lines = block({1: 200, 2: 190})
        self.reject(log(lines[1:]), "outside a sweep block")
        self.reject(log(block({1: 200, 2: 190}, schema="g6lc.policy-motifs.v1")), "expected schema")

    def test_no_measure_lines_at_all(self):
        self.reject(b"PASS g6lc_ai_gemm_backend\n", "no sweep block")

    def test_cycles_must_come_from_the_rtl_counter(self):
        self.reject(log(block({1: 200, 2: 190}, source="tb_timeout_budget")),
                    "must come from the RTL free-running counter")

    def test_duplicate_pair(self):
        lines = block({1: 200, 2: 190})
        lines.insert(2, run(0, 1, 205))
        lines[-1] = end(15, formats=7)
        self.reject(log(lines), "duplicate (numfmt, ar_max)")

    def test_missing_ar_value(self):
        lines = [line for line in block({1: 200, 2: 190}) if not line.startswith("MEASURE fmt=5 ar=2")]
        lines[-1] = end(13, formats=7)
        self.reject(log(lines), "missing ar values [2]")

    def test_nonpositive_cycles(self):
        for field, needle in (("cycles=190", "nonpositive cycles"), ("pmu_cycles=189", "nonpositive pmu_cycles")):
            raw = log(block({1: 200, 2: 190})).decode().replace(field, field.split("=")[0] + "=0", 1)
            self.reject(raw, needle)

    def test_zero_macs_and_inconsistent_macs(self):
        self.reject(log([begin(), run(0, 1, 200, m=0), end(1)]), "m must be positive")
        raw = log(block({1: 200, 2: 190})).decode().replace("macs=64", "macs=0", 1)
        self.reject(raw, "zero useful MACs")
        raw = log(block({1: 200, 2: 190})).decode().replace("macs=64", "macs=63", 1)
        self.reject(raw, "exactly m*n*k")

    def test_zero_beats(self):
        for field, needle in (("r_beats=8", "read nothing"), ("w_beats=2", "wrote no C")):
            raw = log(block({1: 200, 2: 190})).decode().replace(field, field.split("=")[0] + "=0", 1)
            self.reject(raw, needle)

    def test_result_digest_mismatch_is_a_failure(self):
        lines = block({1: 200, 2: 190})
        lines[2] = run(0, 2, 190, c0="0000001000000011")
        self.reject(log(lines), "AR depth changed the arithmetic")

    def test_unknown_format(self):
        self.reject(log([begin(), run(2, 1, 200), run(2, 2, 190), end(2)]), "unknown numeric format 2")
        self.reject(log([begin(), run(8, 1, 200), run(8, 2, 190), end(2)]), "unknown numeric format 8")

    def test_shape_must_not_change_within_a_format(self):
        lines = block({1: 200, 2: 190})
        lines[2] = run(0, 2, 190, k=8)
        self.reject(log(lines), "two different shapes")

    def test_structural_faults(self):
        self.reject(log([begin(), run(0, 1, 200), run(0, 2, 190)]), "unterminated sweep block")
        self.reject(log([begin(), begin()]), "inside an open sweep block")
        self.reject(log([end(0)]), "without MEASURE_BEGIN")
        self.reject(log(block({1: 200, 2: 190})).decode().replace("runs=14", "runs=13"),
                    "MEASURE_END runs=13")
        self.reject(log(block({1: 200, 2: 190})).decode().replace("MEASURE_END runs=14 formats=7 ar_max=2",
                                                                 "MEASURE_END runs=14 formats=7 ar_max=3"),
                    "ar_max disagrees")
        self.reject(log([begin(), run(0, 1, 200) + " extra=1", end(1)]), "unrecognised MEASURE line")
        self.reject(log([begin(ar_max=9)]), "block ar_max must be in [1,8]")
        self.reject(log([begin(), run(0, 3, 200), end(1)]), "outside the block's")

    def test_one_artifact_covers_one_testbench(self):
        self.reject(log(block({1: 200, 2: 190}), block({1: 200, 2: 190}, tb="tb_other")),
                    "one testbench only")

    def test_build_rejects_bad_inputs(self):
        good = log(block({1: 200, 2: 190}))
        for raw in (b"", "not bytes", b"x" * (measure.MAX_LOG_BYTES + 1)):
            with self.assertRaises(ValueError):
                measure.build(raw, "5.008")
        for version in ("", "  ", "5", "v5.008", "5.008-rc1", 5.008, None):
            with self.assertRaises(ValueError):
                measure.build(good, version)


class ArithmeticTests(unittest.TestCase):
    def test_exact_rational_rates_and_paired_deltas(self):
        _, records = measure.parse_log(log(block({1: 200, 2: 190})).decode())
        table = measure.paired_deltas(records, 1)
        self.assertEqual(table[(0, 0, 1)], (Fraction(64, 200), Fraction(0)))
        self.assertEqual(table[(0, 0, 2)], (Fraction(64, 190), Fraction(10, 190)))
        self.assertEqual(measure.scaled(Fraction(10, 190) * 100), 5263)
        self.assertEqual(measure.percent(Fraction(10, 190)), "+5.263%")
        self.assertEqual(measure.percent(Fraction(-1, 200)), "-0.500%")
        self.assertEqual(measure.percent(Fraction(0)), "+0.000%")

    def test_missing_reference_and_illegal_reference(self):
        _, records = measure.parse_log(log(block({1: 200, 2: 190})).decode())
        with self.assertRaises(ValueError):
            measure.paired_deltas(records, 3)
        for reference in (0, 9, "1", 1.0):
            with self.assertRaises(ValueError):
                measure.paired_deltas(records, reference)


class RecommendationTests(unittest.TestCase):
    def build(self, *blocks, **kwargs):
        return measure.build(log(*blocks), "5.008", **kwargs)

    def test_null_result_when_deltas_are_zero(self):
        result = self.build(block({1: 200, 2: 200}))
        self.assertFalse(result["recommendation"]["recommended_change"])
        for entry in result["recommendation"]["per_format"].values():
            self.assertIsNone(entry["recommended_ar"])
            self.assertEqual(entry["best_ar"], 1)
            self.assertIn("no depth clears", entry["reason"])

    def test_null_result_when_deltas_are_negative(self):
        result = self.build(block({1: 200, 2: 220}))
        self.assertFalse(result["recommendation"]["recommended_change"])
        entry = result["recommendation"]["per_format"]["INT8"]
        self.assertIsNone(entry["prefetch_depth"])
        self.assertEqual(entry["best_ar"], 1)
        self.assertEqual(entry["minimum_delta_percent"]["2"], "-9.091%")

    def test_recommends_a_depth_that_wins_in_every_observation(self):
        result = self.build(block({1: 200, 2: 150}), block({1: 300, 2: 240}, nch=2))
        recommendation = result["recommendation"]
        self.assertTrue(recommendation["recommended_change"])
        entry = recommendation["per_format"]["FP32"]
        self.assertEqual((entry["recommended_ar"], entry["prefetch_depth"], entry["observations"]), (2, 2, 2))
        self.assertIn("in all 2 observation(s)", entry["reason"])

    def test_refuses_when_one_observation_disagrees(self):
        result = self.build(block({1: 200, 2: 150}), block({1: 200, 2: 205}, nch=2))
        entry = result["recommendation"]["per_format"]["INT8"]
        self.assertFalse(result["recommendation"]["recommended_change"])
        self.assertIsNone(entry["recommended_ar"])
        self.assertEqual(entry["minimum_delta_percent"]["2"], "-2.439%")

    def test_threshold_boundary_is_inclusive(self):
        # ar=2 at 200 cycles vs ar=1 at 202 -> exactly +1/100 MAC/cycle improvement.
        blocks = block({1: 202, 2: 200})
        exact = Fraction(202 - 200, 200)
        self.assertEqual(exact, Fraction(1, 100))
        accepted = self.build(blocks, min_improvement=exact)
        self.assertTrue(accepted["recommendation"]["recommended_change"])
        self.assertEqual(accepted["recommendation"]["per_format"]["INT8"]["recommended_ar"], 2)
        refused = self.build(blocks, min_improvement=exact + Fraction(1, 10**9))
        self.assertFalse(refused["recommendation"]["recommended_change"])

    def test_threshold_must_be_a_positive_fraction(self):
        _, records = measure.parse_log(log(block({1: 200, 2: 150})).decode())
        table = measure.per_format(records, 1)
        for threshold in (Fraction(0), Fraction(-1, 100), 0.01, "1/100", None):
            with self.assertRaises(ValueError):
                measure.recommend(table, 1, threshold)

    def test_deterministic_tie_break_picks_the_shallowest_depth(self):
        cycles = {1: 200, 2: 150, 3: 150, 4: 150}
        result = self.build(block(cycles, ar_max=4))
        entry = result["recommendation"]["per_format"]["INT8"]
        self.assertEqual((entry["recommended_ar"], entry["best_ar"]), (2, 2))
        repeated = self.build(block(cycles, ar_max=4))
        self.assertEqual(json.dumps(repeated["recommendation"], sort_keys=True),
                         json.dumps(result["recommendation"], sort_keys=True))

    def test_reference_ar_is_configurable(self):
        result = self.build(block({1: 200, 2: 150}), reference_ar=2)
        entry = result["recommendation"]["per_format"]["INT8"]
        self.assertEqual(result["equivalence"]["reference_ar"], 2)
        self.assertEqual(entry["minimum_delta_percent"]["1"], "-25.000%")
        self.assertIsNone(entry["recommended_ar"])


class ProjectionTests(unittest.TestCase):
    def test_refuses_mac_per_second_without_a_declared_frequency(self):
        _, records = measure.parse_log(log(block({1: 200, 2: 190})).decode())
        with self.assertRaises(ValueError) as caught:
            measure.mac_per_second(records, None)
        self.assertIn("MAC/s refused", str(caught.exception))
        for frequency in (0, -1, 1.0, "1000", True):
            with self.assertRaises(ValueError):
                measure.mac_per_second(records, frequency)
        artifact = measure.build(log(block({1: 200, 2: 190})), "5.008")
        self.assertNotIn("mac_per_second_projection", artifact)
        self.assertIn("not emitted", measure.summary(artifact))

    def test_projection_is_labelled_and_never_a_measurement(self):
        artifact = measure.build(log(block({1: 200, 2: 190})), "5.008", frequency_hz=10**9)
        projection = artifact["mac_per_second_projection"]
        self.assertEqual(projection["kind"], "projection_from_simulated_cycles_at_declared_clock")
        self.assertEqual(projection["declared_clock_hz"], 10**9)
        self.assertFalse(projection["silicon_measured"] or projection["wall_clock_measured"])
        self.assertEqual(projection["per_record"][0]["mac_per_second"], str(Fraction(64, 200) * 10**9))
        self.assertIn("projection", projection["note"])
        self.assertNotIn("measured throughput", projection["note"])


class ArtifactTests(unittest.TestCase):
    def test_artifact_shape_and_honest_framing(self):
        raw = log(block({1: 200, 2: 190}))
        artifact = measure.build(raw, "5.008")
        self.assertEqual(artifact["schema"], measure.SCHEMA)
        self.assertEqual(artifact["harness"], {"tb": "tb_g6lc_ai_gemm_backend",
                                              "verilator_version": "5.008",
                                              "log_sha256": hashlib.sha256(raw).hexdigest()})
        self.assertEqual(artifact["environment"], {"simulator": "verilator",
                         "note": "RTL simulation cycles for one TB memory model; not silicon"})
        self.assertEqual(artifact["clock"], {"silicon_measured": False, "wall_clock_measured": False})
        self.assertEqual(artifact["equivalence"]["checked"], True)
        self.assertEqual(artifact["equivalence"]["digests_matched"], True)
        self.assertTrue(artifact["throughput"]["measured"])
        self.assertEqual(len(artifact["limitations"]), 6)
        self.assertTrue(any("not silicon" in line for line in artifact["limitations"]))
        self.assertEqual(artifact["recommendation"]["consumer"], measure.CONSUMER)
        json.dumps(artifact, allow_nan=False)

    def test_single_depth_sweep_cannot_claim_equivalence_coverage(self):
        artifact = measure.build(log(block({1: 200}, ar_max=1)), "5.008")
        self.assertFalse(artifact["equivalence"]["checked"])
        self.assertFalse(artifact["recommendation"]["recommended_change"])


class OutputProtectionTests(unittest.TestCase):
    def test_refuses_to_write_over_a_source_file(self):
        source = Path(measure.__file__).resolve()
        with self.assertRaises(ValueError):
            measure.protect_outputs(source, [source])
        with self.assertRaises(ValueError):
            measure.protect_outputs(source.with_name("policy_calibration.py"), [source])

    def test_requires_json_and_the_workspace_build_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            outside = Path(directory) / "artifact.json"
            self.assertEqual(measure.protect_outputs(outside, []), outside)
            with self.assertRaises(ValueError):
                measure.protect_outputs(Path(directory) / "artifact.sv", [])
        root = measure.repo_root()
        with self.assertRaises(ValueError):
            measure.protect_outputs(root / "verif/tb/ai_island/artifact.json", [])
        allowed = root / "build-platform/workspace/build/artifact.json"
        self.assertEqual(measure.protect_outputs(allowed, []), allowed)


class CommandLineTests(unittest.TestCase):
    def test_writes_artifact_and_prints_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            log_path = Path(directory) / "gemm.log"
            out = Path(directory) / "policy-measure.json"
            log_path.write_bytes(log(block({1: 200, 2: 190}), block({1: 300, 2: 280}, nch=2)))
            self.assertEqual(measure.main(["--log", str(log_path), "--verilator-version", "5.008",
                                           "--out", str(out), "--min-improvement", "1/100"]), 0)
            artifact = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(artifact["schema"], measure.SCHEMA)
            self.assertEqual(len(artifact["blocks"]), 2)
            self.assertTrue(artifact["recommendation"]["recommended_change"])

    def test_cli_errors_are_reported_not_raised(self):
        with tempfile.TemporaryDirectory() as directory:
            log_path = Path(directory) / "gemm.log"
            log_path.write_bytes(b"PASS nothing here\n")
            with self.assertRaises(SystemExit):
                measure.main(["--log", str(log_path), "--verilator-version", "5.008",
                              "--out", str(Path(directory) / "a.json")])


if __name__ == "__main__":
    unittest.main()
