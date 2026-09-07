# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon

import contextlib
from fractions import Fraction
import io
import json
import math
import unittest
from unittest import mock

import policy_approx as policy

try:
    import torch
except ImportError:
    torch = None


def ceil_fraction(value):
    return -(-value.numerator // value.denominator)


class ScalarNorm:
    def __init__(self, value):
        self.value = value

    def __sub__(self, other):
        return ScalarNorm(self.value - other.value)

    def norm(self):
        return ScalarNorm(abs(self.value))

    def item(self):
        return self.value

    def any(self):
        return ScalarNorm(bool(self.value))


class ArithmeticTests(unittest.TestCase):
    def test_relative_error_zero_reference(self):
        self.assertEqual(policy.rel_error(ScalarNorm(1), ScalarNorm(0)), math.inf)
        self.assertEqual(policy.rel_error(ScalarNorm(0), ScalarNorm(0)), 0)

    def test_rne_all_precisions_independent_rational(self):
        for bits in range(24):
            with self.subTest(bits=bits):
                u = Fraction(1, 2 ** (bits + 1))
                expected = ceil_fraction(1_000_000 * (2 * u + u * u))
                encoded = expected if expected <= 1_000_000 else 0xfffff
                self.assertEqual(policy.ROUND_EPS_PPM[bits], expected)
                self.assertEqual(policy.round_eps_ppm(bits), encoded)
        self.assertEqual(policy.round_eps_ppm(11), 489)
        for bits in (-1, 24, 31):
            self.assertEqual(policy.round_eps_ppm(bits), 0xfffff)

    def test_rne_format_literals(self):
        for fmt, bits in (("FP16", 10), ("BF16", 7), ("FP8_E4M3", 3), ("FP8_E5M2", 2)):
            with self.subTest(fmt=fmt):
                u = Fraction(1, 2 ** (bits + 1))
                self.assertEqual(policy.ANALYTIC_EPS_PPM[fmt][0],
                                 ceil_fraction(1_000_000 * (2 * u + u * u)))

    def test_truncation_all_precisions_independent_rational(self):
        for bits in range(24):
            with self.subTest(bits=bits):
                u = Fraction(1, 2 ** bits)
                expected = ceil_fraction(1_000_000 * (2 * u - u * u))
                self.assertEqual(policy.trunc_eps_ppm(bits), expected)
        for bits in (10, 8, 6, 4, 2):
            u = Fraction(1, 2 ** bits)
            self.assertEqual(policy.ANALYTIC_EPS_PPM["mantissa_truncated:%d" % bits][0],
                             ceil_fraction(1_000_000 * (2 * u - u * u)))

    def test_fullscale_constant_not_scaled(self):
        flat = .9196460738857746
        kappa = 85.68121868438433
        eps = policy.fullscale_eps_ppm(127, flat)
        expected = 1_000_000 * (flat / 254 + 1 / 64516)
        self.assertAlmostEqual(eps, expected)
        self.assertAlmostEqual(eps * kappa, 311550.09449393)
        self.assertGreater(eps, policy.ANALYTIC_EPS_PPM["INT8"][0] * flat / 2)
        self.assertAlmostEqual(policy.fullscale_eps_ppm(7, 0), 1_000_000 / 196)

    def test_integer_quantization_helper_all_flatness_codes(self):
        for levels in (7, 127):
            first = ceil_fraction(Fraction(1_000_000, 2 * levels))
            constant = ceil_fraction(Fraction(1_000_000, 4 * levels * levels))
            for flat_q8 in range(1024):
                with self.subTest(levels=levels, flat_q8=flat_q8):
                    expected = ceil_fraction(Fraction(first * flat_q8, 256)) + constant
                    self.assertEqual(policy.quant_eps_ppm(levels, flat_q8), expected)
        self.assertEqual(policy.quant_eps_ppm(0, 512), 0xfffff)

    def test_q8_metadata_and_integer_ceiling(self):
        flat = policy.q8_ceil(.9196460738857746, 1023)
        kappa = policy.q8_ceil(85.68121868438433, 65535)
        self.assertEqual((flat, kappa), (236, 21935))
        eps = policy.quant_eps_ppm(127, flat)
        self.assertEqual(eps, 3647)
        self.assertEqual(policy.bound_ppm(eps, kappa), 312489)
        self.assertEqual(policy.bound_ppm(977, 257), 981)
        self.assertIsNone(policy.q8_ceil(256, 65535))
        self.assertIsNone(policy.q8_ceil(math.inf, 65535))
        self.assertIsNone(policy.q8_ceil(math.nan, 65535))
        self.assertIsNone(policy.q8_ceil(-1, 65535))
        self.assertEqual(policy.q8_ceil(65535 / 256, 65535), 65535)

    def test_bounds_fail_closed_above_budget(self):
        self.assertEqual(policy.bound_ppm(1_000_000, 256), 1_000_000)
        for eps, kappa in ((1_000_000, 257), (0xfffff, 256), (977, None),
                           (977, 0), (977, 255), (977, 65536)):
            with self.subTest(eps=eps, kappa=kappa):
                self.assertEqual(policy.bound_ppm(eps, kappa), 0xfffff)
        self.assertEqual(policy.budget_ppm(15), 1_000_000)
        for value in (1_000_001, 0xfffff, math.inf, math.nan, None, -1):
            with self.subTest(value=value):
                self.assertIsNone(policy.level_for(value))

    def test_nonfinite_json_is_null_with_status(self):
        original = {"entry": {"bound": math.inf, "error": math.nan}, "values": [-math.inf, 0]}
        text = policy.report_json(original)
        decoded = json.loads(text, parse_constant=lambda value: self.fail(value))
        self.assertIsNone(decoded["entry"]["bound"])
        self.assertIsNone(decoded["entry"]["error"])
        self.assertEqual(decoded["values"], [None, 0])
        self.assertEqual(decoded["serialization_status"], "nonfinite_values_replaced_with_null")
        self.assertEqual(len(decoded["nonfinite_fields"]), 3)
        self.assertTrue(math.isinf(original["entry"]["bound"]))

    def test_bank_rejects_nonfinite_empirical_errors(self):
        for value in (math.inf, math.nan, -1):
            report = {"format_narrowing": [{"format": "INT8", "k_bytes_at_k16": 16,
                                            "rel_error_p95": value}]}
            self.assertEqual(policy.emit_bank(report, 8, 100, 64)["bank_size_admitted"], 0)


@unittest.skipIf(torch is None, "torch not installed in this interpreter")
class TensorTests(unittest.TestCase):
    def tile(self, a, b):
        return [("fixture", torch.tensor(a, dtype=torch.float64),
                 torch.tensor(b, dtype=torch.float64))]

    def validation(self, tiles, fmt="INT8", error=0):
        report = {"format_narrowing": [{"format": fmt, "rel_error_max": error}],
                  "approximate_multiplier": []}
        return policy.validate_bounds(report, tiles)

    def test_cancellation_is_infinite_not_zero(self):
        tiles = self.tile([[1, 1]], [[1], [-1]])
        _, a, b = tiles[0]
        self.assertEqual(policy.kappa_relative(a, b), (math.inf, math.inf))
        self.assertEqual(policy.kappa_fullscale(a, b), (math.inf, math.inf))
        row = self.validation(tiles)["entries"][0]
        self.assertFalse(row["analytic_admissible"])
        self.assertIsNone(row["level_needed_analytic"])
        self.assertEqual(row["rtl_matched_bound_ppm"], 0xfffff)
        self.assertIsNone(row["empirical_holds"])
        self.assertIsNone(json.loads(policy.report_json(row))["matched_bound_ppm"])

    def test_tiny_nonzero_error_against_zero_is_infinite(self):
        candidate = torch.tensor([1e-200, -1e-200], dtype=torch.float64)
        reference = torch.zeros_like(candidate)
        self.assertEqual(policy.rel_error(candidate, reference), math.inf)

    def test_zero_products_have_undefined_kappa(self):
        _, a, b = self.tile([[0, 0]], [[1], [1]])[0]
        self.assertTrue(all(math.isinf(x) for x in policy.kappa_relative(a, b)))
        self.assertTrue(all(math.isinf(x) for x in policy.kappa_fullscale(a, b)))

    def test_bound_above_one_hundred_percent_not_clipped(self):
        row = self.validation(self.tile([[1, 1]], [[1], [-.999]]))["entries"][0]
        self.assertGreater(row["matched_bound_ppm"], 1_000_000)
        self.assertGreater(row["element_worst_bound_ppm"], 1_000_000)
        self.assertIsNone(row["level_needed_analytic"])
        self.assertFalse(row["analytic_admissible"])
        self.assertEqual(row["rtl_matched_bound_ppm"], 0xfffff)

    def test_global_norm_consistent_flatness_is_conservative(self):
        tiles = self.tile([[8, .2, -.1], [.01, 0, 0]], [[4, .002], [.1, 0], [-.3, 0]])
        _, a, b = tiles[0]
        error = policy.rel_error(policy.quantize_format(a, "INT8") @ policy.quantize_format(b, "INT8"), a @ b)
        row = self.validation(tiles, error=error)["entries"][0]
        self.assertTrue(row["empirical_holds"])
        self.assertFalse(row["universal_proof"])
        self.assertGreaterEqual(row["rtl_matched_bound_ppm"], row["matched_bound_ppm"])

    def test_truncation_bound_covers_near_discarded_maximum(self):
        for keep in (10, 8, 6, 4, 2):
            value = 1 + 2 ** -keep - 2 ** -23
            _, a, b = self.tile([[value]], [[value]])[0]
            error = policy.rel_error(policy.truncate_mantissa(a, keep) @ policy.truncate_mantissa(b, keep), a @ b)
            self.assertLessEqual(error * 1_000_000,
                                 policy.ANALYTIC_EPS_PPM["mantissa_truncated:%d" % keep][0])

    def test_conversion_premises_fail_for_subnormal_and_overflow(self):
        for value in (2 ** -25, 65536, math.inf, math.nan):
            with self.subTest(value=value):
                row = self.validation(self.tile([[value]], [[1]]), "FP16")["entries"][0]
                self.assertFalse(row["premises_satisfied"])
                self.assertFalse(row["analytic_admissible"])
                self.assertIsNone(row["level_needed_analytic"])
                self.assertIsNone(row["empirical_holds"])
                self.assertEqual(row["rtl_matched_bound_ppm"], 0xfffff)
                self.assertTrue(row["premise_failures"])

    def test_fullscale_artifact_statistics_end_to_end(self):
        flat = .9196460738857746
        kappa = 85.68121868438433
        tail = flat * 3 / 2 - 1
        tiles = self.tile([[1, tail, 0]], [[1], [tail], [0]])
        with mock.patch.object(policy, "kappa_fullscale", return_value=(kappa, kappa)):
            row = self.validation(tiles)["entries"][0]
        self.assertAlmostEqual(row["matched_bound_ppm"], 311550.09449393)
        self.assertEqual(row["flatness_q8"], 236)
        self.assertEqual(row["kappa_frobenius_q8"], 21935)
        self.assertEqual(row["rtl_eps_ppm"], 3647)
        self.assertEqual(row["rtl_matched_bound_ppm"], 312489)
        self.assertEqual(row["level_needed_analytic"], 13)
        self.assertTrue(row["analytic_admissible"])
        self.assertFalse(row["universal_proof"])

    def test_matched_q8_overflow_fails_even_below_raw_budget(self):
        tiles = self.tile([[1]], [[1]])
        with mock.patch.object(policy, "kappa_relative", return_value=(256, 256)):
            row = self.validation(tiles, "FP16")["entries"][0]
        self.assertEqual(row["matched_bound_ppm"], 977 * 256)
        self.assertIsNone(row["kappa_frobenius_q8"])
        self.assertIsNone(row["level_needed_analytic"])
        self.assertEqual(row["rtl_matched_bound_ppm"], 0xfffff)
        self.assertEqual(row["status"], "kappa_q8_unrepresentable")
        self.assertFalse(row["analytic_admissible"])

    def test_nonfinite_observation_is_unqualified_not_a_pass(self):
        tiles = self.tile([[1]], [[1]])
        row = self.validation(tiles, "FP16", math.inf)["entries"][0]
        self.assertIsNone(row["empirical_holds"])
        self.assertFalse(row["analytic_admissible"])
        self.assertIsNone(row["level_needed_analytic"])
        self.assertIsNone(row["level_needed_observed"])
        self.assertEqual(row["status"], "nonfinite_or_undefined_metric")

    def test_normal_conversion_is_sample_qualified_not_proven(self):
        row = self.validation(self.tile([[1, .5]], [[2], [1]]), "FP16")["entries"][0]
        self.assertTrue(row["premises_satisfied"])
        self.assertTrue(row["empirical_holds"])
        self.assertFalse(row["universal_proof"])

    def test_truncation_rejects_unmodeled_fp32_input_rounding(self):
        tiles = self.tile([[1 + 2 ** -30]], [[1]])
        result = policy.candidate_premises("mantissa_truncated:10", tiles)
        self.assertFalse(result["satisfied"])

    def test_float8_scaled_subnormal_is_not_universally_qualified(self):
        tiles = self.tile([[1, 2 ** -12]], [[1], [1]])
        row = self.validation(tiles, "FP8_E4M3")["entries"][0]
        self.assertFalse(row["premises_satisfied"])

    def test_evaluation_reports_proxy_and_nonfinite_status(self):
        tiles = self.tile([[1, 1]], [[1], [-1]])
        report = policy.evaluate(tiles)
        self.assertIn("proxy", report["reference"])
        self.assertIn("not modeled", report["accumulation"])
        report["bound_validation"] = policy.validate_bounds(report, tiles)
        text = policy.report_json(report)
        json.loads(text, parse_constant=lambda value: self.fail(value))
        self.assertNotIn("Infinity", text)
        self.assertNotIn("NaN", text)

    def test_main_zero_reference_report_is_robust(self):
        tiles = self.tile([[0, 0]], [[1], [1]])
        stream = io.StringIO()
        with mock.patch.object(policy, "snapshot_dir", return_value=None), \
             mock.patch.object(policy, "collect_operands", return_value=[]), \
             mock.patch.object(policy, "tiles", return_value=tiles), \
             mock.patch.object(policy.Path, "write_text") as write_json, \
             contextlib.redirect_stdout(stream):
            result = policy.main(["--cache-dir", ".", "--model-id", "fixture",
                                  "--revision", "0" * 40, "--out", "unused.json"])
        self.assertEqual(result, 0)
        artifact = json.loads(write_json.call_args.args[0], parse_constant=lambda value: self.fail(value))
        self.assertEqual(artifact["serialization_status"], "nonfinite_values_replaced_with_null")
        self.assertIsNone(artifact["bound_validation"]["kappa_relative_frobenius"])
        self.assertIn("proxy", stream.getvalue())
        self.assertNotIn("reference=float64 exact", stream.getvalue())


if __name__ == "__main__":
    unittest.main()
