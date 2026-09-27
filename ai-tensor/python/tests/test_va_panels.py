# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Named VA panels: the host cut, and that the default path still uses the cap box."""

import unittest

from ai_tensor.device import Caps, Device, choose_va_blocking, gemm_s8


class TestVaPanels(unittest.TestCase):
    def test_chooser_matches_the_named_shapes(self) -> None:
        cap = (1024, 512, 512)
        self.assertEqual(choose_va_blocking(1024, 128, 512, *cap, 512), (1024, 128, 512))
        self.assertEqual(choose_va_blocking(512, 256, 16, *cap, 512), (512, 256, 512))
        self.assertEqual(choose_va_blocking(1024, 256, 512, *cap, 512), (512, 256, 512))
        self.assertEqual(choose_va_blocking(1024, 129, 512, *cap, 512), (1024, 128, 512))
        self.assertEqual(choose_va_blocking(100, 100, 8, *cap, 512), (512, 512, 512))
        self.assertEqual(choose_va_blocking(4, 4, 4, 2, 2, 2, 512), (2, 2, 2))

    def test_default_schedule_keeps_a_fitting_box_as_one_job(self) -> None:
        dev = Device("sim", caps=Caps())
        a = [1] * 1024
        b = [1] * 256
        c, _, status, meta = gemm_s8(1024, 256, 1, a, b, device=dev, va_panels=False)
        self.assertEqual(status, 0)
        self.assertFalse(meta["auto_tile"])
        self.assertEqual(meta["tiles"], 1)
        self.assertEqual(c, [1] * (1024 * 256))

    def test_va_schedule_splits_and_still_matches(self) -> None:
        dev = Device("sim", caps=Caps())
        a = [1] * 1024
        b = [1] * 256
        c, _, status, meta = gemm_s8(1024, 256, 1, a, b, device=dev, va_panels=True)
        self.assertEqual(status, 0)
        self.assertTrue(meta["auto_tile"])
        self.assertEqual(meta["tiles"], 2)
        self.assertEqual(c, [1] * (1024 * 256))


if __name__ == "__main__":
    unittest.main()
