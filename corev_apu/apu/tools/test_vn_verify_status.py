# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""The frozen native receipt must not hide unraisable cleanup failures."""
import importlib.util
from pathlib import Path
import unittest


PATH = Path(__file__).resolve().parents[3] / 'verif/tb/apu/apu_native_verify.py'
SPEC = importlib.util.spec_from_file_location('g6lc_native_receipt', PATH)
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class ReceiptTests(unittest.TestCase):
    def test_completed_healthy_cohort_passes(self):
        self.assertEqual(RUNNER.result_status(0, 193, 'Ran 193 tests\nOK\n'), 'PASS')

    def test_empty_or_failed_child_never_passes(self):
        for code, tests in ((0, 0), (1, 193), (-9, 0)):
            self.assertEqual(RUNNER.result_status(code, tests, ''), 'FAIL')

    def test_resource_warning_does_not_hide_behind_zero_return_code(self):
        self.assertEqual(RUNNER.result_status(
            0, 193, 'ResourceWarning: unclosed file\nRan 193 tests\nOK\n'), 'FAIL')

    def test_unraisable_finalizer_failure_never_passes(self):
        self.assertEqual(RUNNER.result_status(
            0, 193, 'Exception ignored in: callback\nRuntimeError: failed\nOK'), 'FAIL')


if __name__ == '__main__':
    unittest.main()
