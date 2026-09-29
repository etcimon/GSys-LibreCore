# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Named VA panels: the host cut, and that the default path still uses the cap box."""

import unittest

from ai_tensor.device import (
    Caps,
    Device,
    choose_va_blocking,
    exact_reuse_for_call,
    gemm_s8,
    high_level_fields,
    run_va_turbo_test_s8,
)
from ai_tensor.policy import FLAG_REUSE_A, FLAG_REUSE_B
from ai_tensor.va_turbo import DOC_INT8_PPM


class TestVaPanels(unittest.TestCase):
    def test_chooser_matches_the_named_shapes(self) -> None:
        cap = (1024, 512, 512)
        self.assertEqual(choose_va_blocking(1024, 128, 512, *cap, 512), (1024, 128, 512))
        self.assertEqual(choose_va_blocking(512, 256, 16, *cap, 512), (512, 256, 512))
        self.assertEqual(choose_va_blocking(1024, 256, 512, *cap, 512), (512, 256, 512))
        self.assertEqual(choose_va_blocking(1024, 129, 512, *cap, 512), (1024, 128, 512))
        self.assertEqual(choose_va_blocking(100, 100, 8, *cap, 512), (512, 512, 512))
        self.assertEqual(choose_va_blocking(4, 4, 4, 2, 2, 2, 512), (2, 2, 2))

    def test_high_level_reuse_follows_the_directed_shape(self) -> None:
        live = Caps()
        directed = Caps(acc_tile_m=1024, acc_tile_n=512, acc_tile_k=16, macs_per_cycle=8)
        self.assertFalse(exact_reuse_for_call(live, 1, 256, 256))
        self.assertFalse(exact_reuse_for_call(directed, 1, 256, 256))
        self.assertTrue(exact_reuse_for_call(directed, 1, 600, 8))
        self.assertTrue(exact_reuse_for_call(directed, 16, 8, 8))
        self.assertFalse(exact_reuse_for_call(live, 16, 8, 8))
        self.assertFalse(exact_reuse_for_call(directed, 8, 8, 16))
        live_fields = high_level_fields(live, 1, 256, 256, False)
        self.assertTrue(live_fields["shape_reuse_b"])
        self.assertFalse(live_fields["exact_reuse"])
        self.assertEqual(live_fields["carried_bytes"], 8)
        self.assertFalse(live_fields["port_promoted"])
        self.assertTrue(live_fields["fed"])
        self.assertEqual(live_fields["reuse_blocked"], "live-caps")
        self.assertEqual(
            live_fields["promotion_missing"],
            [
                "concurrency_measured:failed",
                "held_out_pair:absent",
                "gain_threshold_recorded:absent",
                "beyond_tile_proxy:absent",
            ],
        )
        self.assertEqual(
            high_level_fields(directed, 8, 8, 16, False)["reuse_blocked"],
            "shape",
        )
        self.assertIsNone(high_level_fields(directed, 1, 256, 256, True)["reuse_blocked"])
        self.assertEqual(
            high_level_fields(directed, 1, 256, 256, False, native=True)["reuse_blocked"],
            "native-call",
        )
        oversized = high_level_fields(Caps(macs_per_cycle=4096, clusters=8), 8, 8, 16, False)
        self.assertFalse(oversized["fed"])
        self.assertFalse(oversized["port_promoted"])

    def test_torch_gemm_reuses_only_on_the_directed_decode(self) -> None:
        try:
            import torch
            from ai_tensor.torch_ops import gemm_s8 as torch_gemm
        except ImportError:
            self.skipTest("torch is not installed")
        directed = Device(
            "sim",
            caps=Caps(acc_tile_m=1024, acc_tile_n=512, acc_tile_k=16, macs_per_cycle=8),
        )
        live = Device("sim", caps=Caps())
        a = torch.ones(1, 8, dtype=torch.int8)
        b = torch.ones(8, 600, dtype=torch.int8)
        c_dir, meta_dir = torch_gemm(a, b, device=directed)
        c_live, meta_live = torch_gemm(a, b, device=live)
        self.assertTrue(meta_dir["exact_reuse"])
        self.assertEqual(meta_dir["applied_level"], 0)
        self.assertFalse(meta_dir["read_a"])
        self.assertTrue(torch.equal(c_dir, torch.full((1, 600), 8, dtype=torch.int32)))
        self.assertFalse(meta_live["exact_reuse"])
        self.assertEqual(meta_live["applied_level"], 0)
        self.assertTrue(meta_dir["shape_reuse_b"])
        self.assertFalse(meta_dir["shape_reuse_a"])
        self.assertTrue(meta_dir["hit_a"])
        self.assertFalse(meta_dir["hit_b"])
        self.assertIsNone(meta_dir["reuse_blocked"])
        self.assertFalse(meta_live["hit_a"])
        self.assertEqual(meta_live["reuse_blocked"], "live-caps")
        self.assertFalse(meta_dir["port_promoted"])
        self.assertEqual(meta_dir["carried_bytes"], 8)
        self.assertTrue(meta_dir["fed"])
        self.assertTrue(meta_live["fed"])
        self.assertFalse(meta_live["port_promoted"])
        self.assertTrue(torch.equal(c_live, c_dir))
        a_m = torch.ones(16, 8, dtype=torch.int8)
        b_m = torch.ones(8, 8, dtype=torch.int8)
        c_b, meta_b = torch_gemm(a_m, b_m, device=directed)
        c_b_live, meta_b_live = torch_gemm(a_m, b_m, device=live)
        self.assertTrue(meta_b["exact_reuse"])
        self.assertTrue(meta_b["hit_b"])
        self.assertFalse(meta_b["hit_a"])
        self.assertTrue(torch.equal(c_b, torch.full((16, 8), 8, dtype=torch.int32)))
        self.assertFalse(meta_b_live["exact_reuse"])
        self.assertFalse(meta_b_live["hit_b"])
        self.assertTrue(torch.equal(c_b_live, c_b))

    def test_torch_gemm_refuses_a_named_recipe(self) -> None:
        try:
            import torch
            from ai_tensor.torch_ops import gemm_s8 as torch_gemm
        except ImportError:
            self.skipTest("torch is not installed")
        a = torch.ones(2, 2, dtype=torch.int8)
        b = torch.ones(2, 2, dtype=torch.int8)
        c, meta = torch_gemm(a, b)
        self.assertFalse(meta["exact_reuse"])
        self.assertEqual(meta["applied_level"], 0)
        self.assertTrue(torch.equal(c, torch.full((2, 2), 2, dtype=torch.int32)))
        with self.assertRaises(NotImplementedError):
            torch_gemm(a, b, recipe="convert-fp16")

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


class TestVaTurboDirectedSchedule(unittest.TestCase):
    def _caps(self) -> Caps:
        return Caps(acc_tile_m=1024, acc_tile_n=512, acc_tile_k=16, macs_per_cycle=8)

    def test_live_tile_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            run_va_turbo_test_s8(16, 8, 8, [1] * (16 * 8), [1] * (8 * 8), Caps())

    def test_m_split_skips_b_and_keeps_eights(self) -> None:
        got = run_va_turbo_test_s8(16, 8, 8, [1] * (16 * 8), [1] * (8 * 8), self._caps())
        self.assertEqual(got["flags"][1] & FLAG_REUSE_B, FLAG_REUSE_B)
        self.assertEqual(got["flags"][1] & FLAG_REUSE_A, 0)
        self.assertTrue(got["read_a"])
        self.assertFalse(got["read_b"])
        self.assertTrue(got["reuse_enabled"])
        self.assertEqual(got["c"], [8] * (16 * 8))

    def test_k_split_reads_both_and_keeps_sixteens(self) -> None:
        got = run_va_turbo_test_s8(8, 8, 16, [1] * (8 * 16), [1] * (16 * 8), self._caps())
        self.assertEqual(got["flags"][1] & (FLAG_REUSE_A | FLAG_REUSE_B), 0)
        self.assertTrue(got["read_a"])
        self.assertTrue(got["read_b"])
        self.assertFalse(got["reuse_enabled"])
        self.assertEqual(got["c"], [16] * (8 * 8))

    def test_n_split_skips_a_and_keeps_eights(self) -> None:
        got = run_va_turbo_test_s8(8, 16, 8, [1] * (8 * 8), [1] * (8 * 16), self._caps())
        self.assertEqual(got["flags"][1] & FLAG_REUSE_A, FLAG_REUSE_A)
        self.assertEqual(got["flags"][1] & FLAG_REUSE_B, 0)
        self.assertFalse(got["read_a"])
        self.assertTrue(got["read_b"])
        self.assertTrue(got["reuse_enabled"])
        self.assertEqual(got["c"], [8] * (8 * 16))

    def test_level_nine_matches_level_zero(self) -> None:
        caps = self._caps()
        a = [1] * (8 * 8)
        b = [1] * (8 * 8)
        with self.assertRaises(ValueError):
            run_va_turbo_test_s8(8, 8, 8, a, b, caps, level=8, measured_ppm=DOC_INT8_PPM)
        exact = run_va_turbo_test_s8(8, 8, 8, a, b, caps, level=0)
        level9 = run_va_turbo_test_s8(8, 8, 8, a, b, caps, level=9, measured_ppm=DOC_INT8_PPM)
        self.assertEqual(level9["requested_level"], 9)
        self.assertEqual(level9["applied_level"], 0)
        self.assertEqual(level9["flags"], exact["flags"])
        self.assertEqual(level9["c"], exact["c"])
        self.assertEqual(level9["c"], [8] * (8 * 8))


class TestVirtCardDirectedSchedule(unittest.TestCase):
    def _directed(self):
        from ai_tensor.virt_card import VirtCardCaps, VirtCardSession

        caps = VirtCardCaps(
            acc_tile_m=1024,
            acc_tile_n=512,
            acc_tile_k=16,
            macs_per_cycle=8,
        )
        return VirtCardSession(mode="local", caps=caps)

    def test_default_card_refuses_the_schedule(self) -> None:
        from ai_tensor.virt_card import VirtCardCaps, VirtCardSession

        with VirtCardSession(mode="local", caps=VirtCardCaps()) as live:
            self.assertFalse(live.reports_directed_tile())
            with self.assertRaises(ValueError):
                live.run_va_turbo_test_s8(16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))

    def test_m_split_skips_b_and_keeps_eights(self) -> None:
        with self._directed() as card:
            self.assertTrue(card.reports_directed_tile())
            got = card.run_va_turbo_test_s8(16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))
        self.assertEqual(got["flags"][1] & FLAG_REUSE_B, FLAG_REUSE_B)
        self.assertEqual(got["flags"][1] & FLAG_REUSE_A, 0)
        self.assertTrue(got["read_a"])
        self.assertFalse(got["read_b"])
        self.assertTrue(got["hit_b"])
        self.assertFalse(got["hit_a"])
        self.assertTrue(got["reuse_enabled"])
        self.assertEqual(got["applied_level"], 0)
        self.assertEqual(got["c"], [8] * (16 * 8))

    def test_k_split_reads_both_and_keeps_sixteens(self) -> None:
        with self._directed() as card:
            got = card.run_va_turbo_test_s8(8, 8, 16, [1] * (8 * 16), [1] * (16 * 8))
        self.assertEqual(got["flags"][1] & (FLAG_REUSE_A | FLAG_REUSE_B), 0)
        self.assertTrue(got["read_a"])
        self.assertTrue(got["read_b"])
        self.assertFalse(got["reuse_enabled"])
        self.assertEqual(got["c"], [16] * (8 * 8))

    def test_n_split_skips_a_and_keeps_eights(self) -> None:
        with self._directed() as card:
            got = card.run_va_turbo_test_s8(8, 16, 8, [1] * (8 * 8), [1] * (8 * 16))
        self.assertEqual(got["flags"][1] & FLAG_REUSE_A, FLAG_REUSE_A)
        self.assertFalse(got["read_a"])
        self.assertTrue(got["read_b"])
        self.assertTrue(got["hit_a"])
        self.assertTrue(got["reuse_enabled"])
        self.assertEqual(got["c"], [8] * (8 * 16))

    def test_high_level_uses_the_directed_card_and_not_the_default(self) -> None:
        from ai_tensor.device import run_high_level_s8
        from ai_tensor.virt_card import VirtCardCaps, VirtCardSession

        with self._directed() as card:
            directed = Device("virt-card", session=card)
            c, meta = run_high_level_s8(directed, 16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))
        self.assertTrue(meta["exact_reuse"])
        self.assertEqual(meta["applied_level"], 0)
        self.assertTrue(meta["hit_b"])
        self.assertFalse(meta["hit_a"])
        self.assertIsNone(meta["reuse_blocked"])
        self.assertFalse(meta["port_promoted"])
        self.assertEqual(meta["carried_bytes"], 8)
        self.assertTrue(meta["fed"])
        self.assertEqual(c, [8] * (16 * 8))

        with VirtCardSession(mode="local", caps=VirtCardCaps()) as live:
            dev = Device("virt-card", session=live)
            c_live, meta_live = run_high_level_s8(
                dev, 16, 8, 8, [1] * (16 * 8), [1] * (8 * 8)
            )
        self.assertFalse(meta_live["exact_reuse"])
        self.assertEqual(meta_live["reuse_blocked"], "shape")
        self.assertFalse(meta_live["hit_b"])
        self.assertEqual(c_live, c)

        with self._directed() as card:
            directed = Device("virt-card", session=card)
            c_a, meta_a = run_high_level_s8(directed, 1, 600, 8, [1] * 8, [1] * (8 * 600))
        self.assertTrue(meta_a["exact_reuse"])
        self.assertTrue(meta_a["hit_a"])
        self.assertFalse(meta_a["hit_b"])
        self.assertEqual(meta_a["applied_level"], 0)
        self.assertEqual(c_a, [8] * 600)
        with VirtCardSession(mode="local", caps=VirtCardCaps()) as live:
            dev = Device("virt-card", session=live)
            c_decode, meta_decode = run_high_level_s8(dev, 1, 600, 8, [1] * 8, [1] * (8 * 600))
        self.assertFalse(meta_decode["exact_reuse"])
        self.assertEqual(meta_decode["reuse_blocked"], "live-caps")
        self.assertFalse(meta_decode["hit_a"])
        self.assertEqual(c_decode, c_a)

    def test_tcp_agent_follows_the_card_cap(self) -> None:
        import os
        import time

        from ai_tensor.device import run_high_level_s8
        from ai_tensor.virt_card import VirtCardCaps, VirtCardSession
        from virt_ai_card.card_agent import CardAgent

        saved = {
            key: os.environ.pop(key, None)
            for key in ("AI_TENSOR_VIRT_HOST", "AI_TENSOR_VIRT_PORT")
        }
        try:
            with VirtCardSession(mode="tcp", caps=VirtCardCaps()) as live:
                self.assertFalse(live.reports_directed_tile())
                self.assertEqual(live.caps.macs_per_cycle, 512)
                with self.assertRaises(ValueError):
                    live.run_va_turbo_test_s8(16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))

            directed_caps = VirtCardCaps(
                acc_tile_m=1024,
                acc_tile_n=512,
                acc_tile_k=16,
                macs_per_cycle=8,
            )
            with VirtCardSession(mode="tcp", caps=directed_caps) as card:
                self.assertTrue(card.reports_directed_tile())
                dev = Device("virt-card", session=card)
                c, meta = run_high_level_s8(dev, 16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))
                self.assertTrue(meta["exact_reuse"])
                self.assertTrue(meta["hit_b"])
                self.assertFalse(meta["hit_a"])
                self.assertEqual(meta["applied_level"], 0)
                self.assertEqual(c, [8] * (16 * 8))
                k_split = card.run_va_turbo_test_s8(8, 8, 16, [1] * (8 * 16), [1] * (16 * 8))
                self.assertFalse(k_split["reuse_enabled"])
                self.assertTrue(k_split["read_a"])
                self.assertTrue(k_split["read_b"])
                self.assertEqual(k_split["flags"][1] & (FLAG_REUSE_A | FLAG_REUSE_B), 0)
                self.assertEqual(k_split["c"], [16] * (8 * 8))

            agent = CardAgent(port=0)
            host, port = agent.start()
            time.sleep(0.05)
            try:
                asked = VirtCardCaps(
                    acc_tile_m=1024,
                    acc_tile_n=512,
                    acc_tile_k=16,
                    macs_per_cycle=8,
                )
                with VirtCardSession(mode="tcp", host=host, port=port, caps=asked) as remote:
                    self.assertEqual(remote.caps.macs_per_cycle, 512)
                    self.assertEqual(remote.caps.acc_tile_k, 512)
                    self.assertFalse(remote.reports_directed_tile())
                    with self.assertRaises(ValueError):
                        remote.run_va_turbo_test_s8(16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))
                    product, _, status = remote.gemm_s8(2, 2, 2, [1, 2, 3, 4], [5, 6, 7, 8])
                    self.assertEqual(status, 0)
                    self.assertEqual(product, [19, 22, 43, 50])
            finally:
                agent.stop()
        finally:
            for key, value in saved.items():
                if value is not None:
                    os.environ[key] = value


def _load_native():
    try:
        import ai_tensor_native
    except ImportError:
        return None
    if not hasattr(ai_tensor_native, "Mmio"):
        return None
    probe = ai_tensor_native.Mmio()
    if not hasattr(probe, "reports_directed_tile"):
        return None
    return ai_tensor_native


class TestPythonAutoDirectedSchedule(unittest.TestCase):
    def test_auto_reuses_only_when_a_tile_skips(self) -> None:
        directed = Device(
            "sim",
            caps=Caps(acc_tile_m=1024, acc_tile_n=512, acc_tile_k=16, macs_per_cycle=8),
        )
        c, ticket, status, meta = directed.gemm_s8(
            16, 8, 8, [1] * (16 * 8), [1] * (8 * 8), ticket=5
        )
        self.assertEqual(status, 0)
        self.assertEqual(meta["tiles"], 2)
        self.assertTrue(meta["auto_tile"])
        self.assertTrue(meta["exact_reuse"])
        self.assertTrue(meta["hit_b"])
        self.assertFalse(meta["hit_a"])
        self.assertFalse(meta["read_b"])
        self.assertEqual(meta["applied_level"], 0)
        self.assertEqual(ticket, 6)
        self.assertEqual(c, [8] * (16 * 8))

        c, ticket, status, meta = directed.gemm_s8(
            8, 8, 16, [1] * (8 * 16), [1] * (16 * 8), ticket=9
        )
        self.assertEqual(status, 0)
        self.assertEqual(meta["tiles"], 1)
        self.assertFalse(meta["auto_tile"])
        self.assertNotIn("exact_reuse", meta)
        self.assertEqual(ticket, 9)
        self.assertEqual(c, [16] * (8 * 8))

        c, ticket, status, meta = directed.gemm_s8(
            8, 16, 8, [1] * (8 * 8), [1] * (8 * 16), ticket=4
        )
        self.assertEqual(status, 0)
        self.assertEqual(meta["tiles"], 2)
        self.assertTrue(meta["exact_reuse"])
        self.assertTrue(meta["hit_a"])
        self.assertFalse(meta["read_a"])
        self.assertEqual(ticket, 5)
        self.assertEqual(c, [8] * (8 * 16))

        live = Device("sim", caps=Caps())
        c, ticket, status, meta = live.gemm_s8(
            16, 8, 8, [1] * (16 * 8), [1] * (8 * 8), ticket=3
        )
        self.assertEqual(status, 0)
        self.assertEqual(meta["tiles"], 1)
        self.assertFalse(meta["auto_tile"])
        self.assertNotIn("exact_reuse", meta)
        self.assertEqual(ticket, 3)
        self.assertEqual(c, [8] * (16 * 8))

    def test_high_level_uses_the_same_auto_schedule(self) -> None:
        from ai_tensor.device import run_high_level_s8

        directed = Device(
            "sim",
            caps=Caps(acc_tile_m=1024, acc_tile_n=512, acc_tile_k=16, macs_per_cycle=8),
        )
        c, meta = run_high_level_s8(
            directed, 16, 8, 8, [1] * (16 * 8), [1] * (8 * 8), ticket=5
        )
        self.assertEqual(meta["ticket"], 6)
        self.assertEqual(meta["tiles"], 2)
        self.assertEqual(meta["status"], 0)
        self.assertTrue(meta["exact_reuse"])
        self.assertTrue(meta["hit_b"])
        self.assertFalse(meta["hit_a"])
        self.assertFalse(meta["read_b"])
        self.assertIsNone(meta["reuse_blocked"])
        self.assertEqual(meta["applied_level"], 0)
        self.assertEqual(c, [8] * (16 * 8))

        _, meta_k = run_high_level_s8(
            directed, 8, 8, 16, [1] * (8 * 16), [1] * (16 * 8), ticket=9
        )
        self.assertEqual(meta_k["ticket"], 9)
        self.assertEqual(meta_k["tiles"], 1)
        self.assertFalse(meta_k["exact_reuse"])
        self.assertEqual(meta_k["reuse_blocked"], "shape")


class TestNativeSoftIslandSchedule(unittest.TestCase):
    def setUp(self) -> None:
        self.native = _load_native()
        if self.native is None:
            self.skipTest("ai_tensor_native.Mmio has no directed schedule")

    def test_the_default_island_refuses_and_an_override_does_not_enable_reuse(self) -> None:
        from ai_tensor.device import Caps, run_high_level_s8

        island = self.native.Mmio()
        self.assertFalse(island.reports_directed_tile())
        with self.assertRaises(Exception):
            island.run_va_turbo_test_s8(16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))
        dev = Device("mmio")
        dev._caps = Caps(acc_tile_m=1024, acc_tile_n=512, acc_tile_k=16, macs_per_cycle=8)
        c, meta = run_high_level_s8(dev, 16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))
        self.assertFalse(dev._dev.reports_directed_tile())
        self.assertFalse(meta["exact_reuse"])
        self.assertFalse(meta["hit_b"])
        self.assertEqual(meta["applied_level"], 0)
        self.assertEqual(c, [8] * (16 * 8))

    def test_a_directed_island_skips_only_when_a_tile_does(self) -> None:
        from ai_tensor.device import Caps, run_high_level_s8
        from ai_tensor.policy import FLAG_REUSE_A, FLAG_REUSE_B

        directed_caps = Caps(acc_tile_m=1024, acc_tile_n=512, acc_tile_k=16, macs_per_cycle=8)
        dev = Device("mmio", caps=directed_caps)
        self.assertTrue(dev._dev.reports_directed_tile())
        c, meta = run_high_level_s8(dev, 16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))
        self.assertTrue(meta["exact_reuse"])
        self.assertTrue(meta["hit_b"])
        self.assertFalse(meta["hit_a"])
        self.assertEqual(meta["applied_level"], 0)
        self.assertEqual(c, [8] * (16 * 8))
        k_split = dev._dev.run_va_turbo_test_s8(8, 8, 16, [1] * (8 * 16), [1] * (16 * 8))
        self.assertFalse(k_split["reuse_enabled"])
        self.assertEqual(k_split["flags"][1] & (FLAG_REUSE_A | FLAG_REUSE_B), 0)
        self.assertTrue(k_split["read_a"])
        self.assertTrue(k_split["read_b"])
        self.assertEqual(list(k_split["c"]), [16] * (8 * 8))


class TestNativeSimSchedule(unittest.TestCase):
    def setUp(self) -> None:
        self.native = _load_native()
        if self.native is None or not hasattr(self.native.Sim(), "reports_directed_tile"):
            self.skipTest("ai_tensor_native.Sim has no directed schedule")

    def test_the_default_sim_refuses_and_an_override_does_not_enable_reuse(self) -> None:
        from ai_tensor.device import Caps, run_high_level_s8

        sim = self.native.Sim()
        self.assertFalse(sim.reports_directed_tile())
        with self.assertRaises(Exception):
            sim.run_va_turbo_test_s8(16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))
        dev = Device("sim")
        dev._caps = Caps(acc_tile_m=1024, acc_tile_n=512, acc_tile_k=16, macs_per_cycle=8)
        c, meta = run_high_level_s8(dev, 16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))
        self.assertFalse(dev._dev.reports_directed_tile())
        self.assertFalse(meta["exact_reuse"])
        self.assertFalse(meta["hit_b"])
        self.assertEqual(c, [8] * (16 * 8))

    def test_a_directed_sim_skips_only_when_a_tile_does(self) -> None:
        from ai_tensor.device import Caps, run_high_level_s8
        from ai_tensor.policy import FLAG_REUSE_A, FLAG_REUSE_B

        directed_caps = Caps(acc_tile_m=1024, acc_tile_n=512, acc_tile_k=16, macs_per_cycle=8)
        dev = Device("sim", caps=directed_caps)
        self.assertEqual(dev.backend, "sim-native")
        self.assertTrue(dev._dev.reports_directed_tile())
        c, meta = run_high_level_s8(dev, 16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))
        self.assertTrue(meta["exact_reuse"])
        self.assertTrue(meta["hit_b"])
        self.assertFalse(meta["hit_a"])
        self.assertEqual(meta["applied_level"], 0)
        self.assertEqual(c, [8] * (16 * 8))
        k_split = dev._dev.run_va_turbo_test_s8(8, 8, 16, [1] * (8 * 16), [1] * (16 * 8))
        self.assertFalse(k_split["reuse_enabled"])
        self.assertEqual(k_split["flags"][1] & (FLAG_REUSE_A | FLAG_REUSE_B), 0)
        self.assertTrue(k_split["read_a"])
        self.assertTrue(k_split["read_b"])
        self.assertEqual(list(k_split["c"]), [16] * (8 * 8))


if __name__ == "__main__":
    unittest.main()
