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

    def test_mac_step_mirrors_the_sequencer(self):
        for fmt, step in (("INT8", 8), ("FP8_E4M3", 8), ("FP8_E5M2", 8), ("FP16", 4),
                          ("BF16", 4), ("FP32", 2), ("INT4", 16)):
            with self.subTest(fmt=fmt):
                self.assertEqual(policy.mac_step(fmt), step)
        self.assertEqual(policy.mac_step("mitchell_logarithmic"), 2)
        self.assertEqual(policy.mac_step("INT4", 4), 8)
        self.assertEqual(policy.mac_step("FP32", 4), 1)
        for windows, sites in ((1, 1), (2, 3), (4, 7), (16, 31)):
            self.assertEqual(policy.rounding_sites(windows), sites)
        self.assertIsNone(policy.rounding_sites(0))

    def test_windowed_kappa_clamped_up_to_the_single_rounding_case(self):
        value, clamped = policy.windowed_kappa_ratio(.5, .4, 1.)
        self.assertEqual((value, clamped), (1., True))
        value, clamped = policy.windowed_kappa_ratio(1., 1., 1.)
        self.assertEqual((value, clamped), (2., False))
        for args in ((1., 1., 0.), (1., 1., -1.), (math.inf, 1., 1.),
                     (math.nan, 1., 1.), (-1., 1., 1.), (1., 1., math.nan)):
            with self.subTest(args=args):
                self.assertEqual(policy.windowed_kappa_ratio(*args), (math.inf, False))

    def test_windowed_composition_independent_rational(self):
        for eps in (1, 977, 7828, 265625):
            for kappa_q8 in (256, 512, 779, 4382, 65535):
                for windows in (1, 2, 16):
                    with self.subTest(eps=eps, kappa_q8=kappa_q8, windows=windows):
                        expected = ceil_fraction(Fraction(eps * kappa_q8, 256))
                        encoded = expected if expected <= 1_000_000 else 0xfffff
                        self.assertEqual(policy.windowed_bound_ppm(eps, kappa_q8, windows),
                                         encoded)
        # The window count is a guard, never a multiplier: the kappa already
        # sums over every window.
        self.assertEqual(policy.windowed_bound_ppm(977, 512, 1),
                         policy.windowed_bound_ppm(977, 512, 64))
        for windows in (0, -1, None, 1.0, True):
            with self.subTest(windows=windows):
                self.assertEqual(policy.windowed_bound_ppm(977, 512, windows), 0xfffff)
        for eps, kappa_q8 in ((0xfffff, 512), (977, 255), (977, 65536), (977, None)):
            with self.subTest(eps=eps, kappa_q8=kappa_q8):
                self.assertEqual(policy.windowed_bound_ppm(eps, kappa_q8, 2), 0xfffff)

    def test_absolute_floor_is_rounded_up_and_fails_closed(self):
        for fmt, eta in (("FP32", Fraction(1, 2 ** 149)), ("FP16", Fraction(1, 2 ** 24)),
                         ("BF16", Fraction(1, 2 ** 133)),
                         ("FP8_E4M3", Fraction(1, 2 ** 9)), ("FP8_E5M2", Fraction(1, 2 ** 16))):
            for scale in (1.0, 3.5, 1e-3, 2.0 ** -20):
                for terms in (1, 3, 31):
                    with self.subTest(fmt=fmt, scale=scale, terms=terms):
                        expected = ceil_fraction(1_000_000 * terms * eta / 2
                                                 / Fraction(scale))
                        encoded = expected if expected <= 1_000_000 else 0xfffff
                        self.assertEqual(policy.abs_floor_ppm(fmt, scale, terms), encoded)
        self.assertEqual(policy.abs_floor_ppm("FP16", 2.0 ** -24), 500000)
        self.assertEqual(policy.abs_floor_ppm("FP16", 2.0 ** -25), 1_000_000)
        self.assertEqual(policy.abs_floor_ppm("FP16", 2.0 ** -26), 0xfffff)
        for fmt, scale, terms in (("INT8", 1.0, 1), ("unknown", 1.0, 1), ("FP16", 0.0, 1),
                                  ("FP16", -1.0, 1), ("FP16", math.inf, 1),
                                  ("FP16", math.nan, 1), ("FP16", 1.0, 0),
                                  ("FP16", 1.0, None), ("FP16", None, 1), ("FP16", True, 1)):
            with self.subTest(fmt=fmt, scale=scale, terms=terms):
                self.assertEqual(policy.abs_floor_ppm(fmt, scale, terms), 0xfffff)

    def test_absolute_floor_never_rounds_a_term_down(self):
        # 1e6 * eta/2 / scale is deliberately non-integral here.
        scale = 3.0
        exact = 1_000_000 * Fraction(1, 2 ** 25) / Fraction(scale)
        self.assertNotEqual(exact.denominator, 1)
        self.assertEqual(policy.abs_floor_ppm("FP16", scale), ceil_fraction(exact))
        self.assertGreater(policy.abs_floor_ppm("FP16", scale), exact)

    def test_total_bound_sums_and_fails_closed(self):
        self.assertEqual(policy.total_bound_ppm(1, 2, 3), 6)
        self.assertEqual(policy.total_bound_ppm(), 0)
        self.assertEqual(policy.total_bound_ppm(1_000_000, 0), 1_000_000)
        for terms in ((1_000_000, 1), (0xfffff,), (1, None), (1, -1), (1, 1.0), (1, True)):
            with self.subTest(terms=terms):
                self.assertEqual(policy.total_bound_ppm(*terms), 0xfffff)


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

    def test_single_window_is_two_and_window_one_is_the_worst_case(self):
        _, a, b = self.tile([[1, -2, 3, -4, 5, .5, -.25, 8]],
                            [[1], [1], [1], [1], [1], [1], [1], [1]])[0]
        k = a.shape[1]
        single = policy.kappa_windowed(a, b, k)
        self.assertEqual(single["windows"], 1)
        self.assertEqual(single["rounding_sites"], 1)
        # One window: s_1 = A_1 = R, so the kappa is exactly the two roundings
        # the RTL still performs, and no more.
        self.assertAlmostEqual(single["frobenius"], 2.0)
        self.assertAlmostEqual(single["element_worst"], 2.0)
        # A window wider than K cannot invent windows.
        self.assertEqual(policy.kappa_windowed(a, b, k + 5)["windows"], 1)
        finest = policy.kappa_windowed(a, b, 1)
        self.assertEqual(finest["windows"], k)
        for window in (1, 2, 4, k):
            coarser = policy.kappa_windowed(a, b, window)
            with self.subTest(window=window):
                self.assertGreaterEqual(finest["frobenius"], coarser["frobenius"])
                self.assertGreaterEqual(finest["element_worst"], coarser["element_worst"])
        self.assertGreaterEqual(policy.kappa_windowed(a, b, 2)["frobenius"],
                                policy.kappa_windowed(a, b, 4)["frobenius"])
        self.assertGreaterEqual(policy.kappa_windowed(a, b, 4)["frobenius"],
                                single["frobenius"])

    def test_windowed_kappa_does_not_charge_intra_window_cancellation(self):
        # Products +8, -7.99, +8, -7.99: the element kappa charges the whole
        # cancellation, the windowed kappa charges none of it inside a window.
        _, a, b = self.tile([[8, 7.99, 8, 7.99]], [[1], [-1], [1], [-1]])[0]
        element = policy.kappa_relative(a, b)[0]
        windowed = policy.kappa_windowed(a, b, 4)
        self.assertGreater(element, 1000)
        self.assertLess(windowed["frobenius"], element)
        self.assertAlmostEqual(windowed["frobenius"], 2.0)
        self.assertLess(policy.kappa_windowed(a, b, 2)["frobenius"], element)
        # Cancellation ACROSS windows is still charged, so window=1 is not free.
        self.assertGreater(policy.kappa_windowed(a, b, 1)["frobenius"],
                           windowed["frobenius"])

    def test_full_cancellation_is_infinite_in_both_kappas(self):
        _, a, b = self.tile([[1, 1]], [[1], [-1]])[0]
        self.assertEqual(policy.kappa_relative(a, b), (math.inf, math.inf))
        for window in (1, 2, 4):
            windowed = policy.kappa_windowed(a, b, window)
            with self.subTest(window=window):
                self.assertEqual(windowed["frobenius"], math.inf)
                self.assertEqual(windowed["element_worst"], math.inf)
                self.assertFalse(windowed["clamped"])
        self.assertIn("proxy", policy.kappa_windowed(a, b, 2)["exactness"])

    def test_windowed_kappa_reports_a_clamp_it_cannot_reach_by_construction(self):
        _, a, b = self.tile([[1, 2]], [[1], [1]])[0]
        # sum_w|s_w| >= |R| and sum_w|A_w| >= |A_W| = |R|, so the tensor path is
        # >= 2 and the clamp is unreachable; the flag must still be truthful if
        # the scalar composition ever does clamp.
        self.assertGreaterEqual(policy.kappa_windowed(a, b, 1)["frobenius"], 2.0)
        self.assertFalse(policy.kappa_windowed(a, b, 1)["clamped"])
        with mock.patch.object(policy, "windowed_kappa_ratio", return_value=(1.0, True)):
            clamped = policy.kappa_windowed(a, b, 1)
        self.assertTrue(clamped["clamped"])
        self.assertEqual(clamped["frobenius"], 1.0)

    def test_windowed_kappa_rejects_invalid_windows_and_nonfinite_tiles(self):
        _, a, b = self.tile([[1, 1]], [[1], [1]])[0]
        for window in (0, -1, None, 2.0):
            with self.subTest(window=window):
                bad = policy.kappa_windowed(a, b, window)
                self.assertEqual(bad["status"], "invalid_window")
                self.assertEqual(bad["frobenius"], math.inf)
                self.assertIsNone(bad["windows"])
        _, big_a, big_b = self.tile([[1e200, 1e200]], [[1e200], [1e200]])[0]
        overflowed = policy.kappa_windowed(big_a, big_b, 1)
        self.assertEqual(overflowed["status"], "nonfinite_or_undefined_metric")
        self.assertEqual(overflowed["frobenius"], math.inf)

    def test_absolute_floor_admits_subnormal_fp16_and_fp8_fixtures(self):
        for fmt, value in (("FP16", 2 ** -25), ("FP8_E4M3", 2 ** -12),
                           ("FP8_E5M2", 2 ** -20)):
            with self.subTest(fmt=fmt):
                tiles = self.tile([[1, value]], [[1], [1]])
                row = self.validation(tiles, fmt)["entries"][0]
                # The pure relative bound refuses this outright ...
                self.assertFalse(row["premises_satisfied"])
                self.assertEqual(row["status"], "unqualified_arithmetic_premises")
                self.assertEqual(row["rtl_matched_bound_ppm"], 0xfffff)
                self.assertIsNone(row["level_needed_analytic"])
                # ... and the ADDED eta/2 term makes it admissible.
                self.assertTrue(row["mixed_premises_satisfied"])
                self.assertTrue(row["mixed_premises_covered_by_floor"])
                self.assertEqual(row["mixed_premise_failures"], [])
                self.assertGreater(row["abs_floor_ppm"], 0)
                self.assertLessEqual(row["bound_sound_total_ppm"], 1_000_000)
                self.assertTrue(row["mixed_admissible"])
                self.assertIsNotNone(row["level_needed_sound_total"])
                self.assertEqual(row["status_windowed"], "sample_qualified")
                self.assertFalse(row["universal_proof"])

    def test_absolute_floor_does_not_excuse_overflow_or_nonfinite(self):
        for value in (65536, math.inf, math.nan):
            with self.subTest(value=value):
                row = self.validation(self.tile([[value]], [[1]]), "FP16")["entries"][0]
                self.assertFalse(row["mixed_premises_satisfied"])
                self.assertTrue(row["mixed_premise_failures"])
                self.assertFalse(row["mixed_admissible"])
                self.assertIsNone(row["level_needed_sound_total"])
                self.assertEqual(row["bound_sound_total_ppm"], 0xfffff)
                self.assertEqual(row["status_windowed"], "unqualified_arithmetic_premises")

    def test_windowed_bound_is_diagnostic_for_per_product_epsilon(self):
        # A per-product epsilon charged once per window is not merely unproven,
        # it is violated: the tile cancels inside its single window.
        tiles = self.tile([[8, 7.99]], [[1], [-1]])
        _, a, b = tiles[0]
        error = policy.rel_error(policy.quantize_format(a, "INT8")
                                 @ policy.quantize_format(b, "INT8"), a @ b)
        row = self.validation(tiles, "INT8", error=error)["entries"][0]
        self.assertEqual(row["windowed_error_site"], "per_product")
        self.assertFalse(row["windowed_model_applies"])
        self.assertIn("per PRODUCT", row["windowed_model_qualification"])
        self.assertAlmostEqual(row["kappa_windowed"], 2.0)
        self.assertGreater(row["kappa_element"], row["kappa_windowed"])
        self.assertGreater(row["observed_max_ppm"], row["bound_total_ppm"])
        self.assertFalse(row["empirical_holds_windowed"])
        self.assertIsNone(row["level_needed_windowed"])
        self.assertFalse(row["mixed_admissible"])

    def test_sound_total_only_adds_terms_and_holds_for_everything_admitted(self):
        tiles = self.tile([[8, .2, -.1, .03], [.01, 2, .5, -.4]],
                          [[4, .002], [.1, .7], [-.3, .05], [.9, -.6]])
        report = policy.evaluate(tiles)
        bounds = policy.validate_bounds(report, tiles)
        admitted = [row for row in bounds["entries"] if row["mixed_admissible"]]
        self.assertTrue(admitted)
        for row in admitted:
            with self.subTest(candidate=row["candidate"]):
                # A violated bound on an admitted candidate is a hard failure.
                self.assertTrue(row["empirical_holds_sound_total"])
                self.assertLessEqual(row["observed_max_ppm"], row["bound_sound_total_ppm"])
                self.assertLessEqual(row["bound_sound_total_ppm"], 1_000_000)
                self.assertIsNotNone(row["level_needed_sound_total"])
                self.assertFalse(row["universal_proof"])
                # The sound total ADDS the reduction and floor terms, so it can
                # never be tighter than the bound that omitted them.
                if row["premises_satisfied"]:
                    self.assertGreaterEqual(row["bound_sound_total_ppm"],
                                            row["rtl_matched_bound_ppm"])
                    self.assertGreaterEqual(row["level_needed_sound_total"],
                                            row["level_needed_analytic"])
        self.assertEqual(bounds["unsound_windowed"], [])
        self.assertEqual(bounds["schema_version"], 3)
        self.assertEqual(bounds["pe_lanes_assumed"], policy.PE_LANES)
        self.assertEqual(len(bounds["windowed_bound_diagnostic_only"]),
                         len(bounds["entries"]))
        json.loads(policy.report_json(bounds), parse_constant=lambda value: self.fail(value))

    def test_windowed_sweep_is_monotone_in_window_size(self):
        tiles = self.tile([[8, .2, -.1, .03, 1, -2, .5, .25]],
                          [[4], [.1], [-.3], [.9], [1], [1], [-1], [.5]])
        bounds = policy.validate_bounds(
            {"format_narrowing": [{"format": "INT8", "rel_error_max": 0}],
             "approximate_multiplier": []}, tiles)
        sweep = bounds["windowed_sweep"]
        self.assertEqual([entry["window"] for entry in sweep], [1, 2, 4, 8, 16])
        self.assertEqual([entry["windows"] for entry in sweep], [8, 4, 2, 1, 1])
        self.assertEqual([entry["rounding_sites"] for entry in sweep], [15, 7, 3, 1, 1])
        values = [entry["kappa_windowed_frobenius"] for entry in sweep]
        self.assertEqual(values, sorted(values, reverse=True))
        self.assertAlmostEqual(values[-1], 2.0)
        self.assertFalse(any(entry["clamped"] for entry in sweep))
        row = bounds["entries"][0]
        per_candidate = row["windowed_bound_sweep"]
        self.assertEqual([entry["window"] for entry in per_candidate],
                         [entry["window"] for entry in sweep])
        bounds_by_window = [entry["bound_total_ppm"] for entry in per_candidate]
        self.assertEqual(bounds_by_window, sorted(bounds_by_window, reverse=True))
        at_eight = next(e for e in per_candidate if e["window"] == policy.PE_LANES)
        self.assertEqual(at_eight["bound_total_ppm"], row["bound_total_ppm"])
        self.assertEqual(at_eight["rounding_sites"], 1)

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
