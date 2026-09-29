# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
Protocol tests for the ``qemu-uio`` backend.

The backend's job is a *sequence of register accesses*, and that sequence is what a real
guest gets wrong: latching a descriptor and never ringing the bell, claiming DONE after
completing the interrupt controller, discovering geometry from the device tree instead of
the capability window. All of that is testable without a guest, so it is tested here
rather than only in a lab.

The fake island below implements the register map from ``include/ai_tensor.h`` and the
INT8 golden. It is deliberately strict: it refuses work when the island is disabled, when
no region admits the pointers, or when a dimension exceeds the accumulator tile, because
a permissive fake would let a broken driver pass.

Run: ``PYTHONPATH=python python python/tests/test_qemu_uio_backend.py``
"""

from __future__ import annotations

import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "python"))

from ai_tensor import qemu_uio as qu  # noqa: E402
from ai_tensor.device import Device  # noqa: E402

DMA_BASE = 0x9000_0000
DMA_SIZE = 1 << 16


class FakeDma:
    """Guest-physical operand memory."""

    def __init__(self, base: int = DMA_BASE, size: int = DMA_SIZE):
        self._base = base
        self._buf = bytearray(size)

    @property
    def base(self) -> int:
        return self._base

    @property
    def size(self) -> int:
        return len(self._buf)

    def read(self, offset: int, length: int) -> bytes:
        return bytes(self._buf[offset : offset + length])

    def write(self, offset: int, data: bytes) -> None:
        self._buf[offset : offset + len(data)] = data


class FakeIsland:
    """A register-accurate island that actually multiplies."""

    def __init__(
        self,
        dma: FakeDma,
        *,
        acc_tile: int = 256,
        acc_tile_m: int | None = None,
        acc_tile_n: int | None = None,
        acc_tile_k: int | None = None,
        macs: int = 256,
        queues: int = 2,
        accumulate: bool = False,
    ):
        self.dma = dma
        self.accumulate = accumulate
        self.acc_tile = acc_tile
        self.acc_tile_m = acc_tile if acc_tile_m is None else acc_tile_m
        self.acc_tile_n = acc_tile if acc_tile_n is None else acc_tile_n
        self.acc_tile_k = acc_tile if acc_tile_k is None else acc_tile_k
        self.macs = macs
        self.queues = queues
        self.regs = bytearray(qu.ISLAND_WINDOW_BYTES)
        self.enabled = False
        self.wr_cpl_en = False
        self.last_status = 0
        self.busy = False
        self.done_sticky = False
        self.irq_pending = False
        self.ticket = 0
        self.trace: list[tuple[str, int, int]] = []
        self.regions: dict[int, tuple[int, int, int]] = {}
        from ai_tensor.policy import OperandReuse

        self._reuse = OperandReuse()
        self._reuse.set_enabled(self._is_directed())
        self._last_read_a = True
        self._last_read_b = True
        self._install_caps()

    def _is_directed(self) -> bool:
        """The directed test window stands for AiCfgVaTurboTest, where VaTurboEn is 1."""
        from ai_tensor.device import VA_TURBO_TEST_MACS, VA_TURBO_TEST_TILE

        return self.macs == VA_TURBO_TEST_MACS and (
            self.acc_tile_m,
            self.acc_tile_n,
            self.acc_tile_k,
        ) == VA_TURBO_TEST_TILE

    def last_read_a(self) -> bool:
        return self._last_read_a

    def last_read_b(self) -> bool:
        return self._last_read_b

    # -- capability window ---------------------------------------------------
    def _install_caps(self) -> None:
        def lg(n: int) -> int:
            return (n.bit_length() - 1) & 0xF

        block = (
            (lg(self.acc_tile_m) << qu.CAP_BLOCK_M_SHIFT)
            | (lg(self.acc_tile_n) << qu.CAP_BLOCK_N_SHIFT)
            | (lg(self.acc_tile_k) << qu.CAP_BLOCK_K_SHIFT)
        )
        for off, val in [
            (qu.CAP_VERSION, 1),
            (qu.CAP_DTYPE_MASK, 1),
            (qu.CAP_CLUSTERS, 1 | (1 << 16)),
            (qu.CAP_MACS_CYCLE, self.macs),
            (qu.CAP_CLOCK_KHZ, 1_000_000),
            (qu.CAP_SRAM_BYTES, 2 << 20),
            (qu.CAP_BLOCK_MNK, block),
            (qu.CAP_DRAM_GBPS, 8),
            (qu.CAP_QUEUES, self.queues | (64 << 16)),
            (qu.CAP_NOC_WIDTH, 64),
            (qu.abi.CAP_ACCMODE, qu.abi.CAP_ACCMODE_ACCUMULATE if self.accumulate else 0),
        ]:
            struct.pack_into("<I", self.regs, off, val)

    # -- MmioWindow ----------------------------------------------------------
    def read32(self, offset: int) -> int:
        self.trace.append(("r", offset, 0))
        if offset == qu.MMIO_STATUS:
            return (1 if self.busy else 0) | (self.last_status << 16)
        if offset == qu.MMIO_DONE:
            return 1 if self.done_sticky else 0
        if offset == qu.MMIO_TICKET:
            return self.ticket
        if offset == qu.MMIO_DSTATUS:
            return self.last_status
        if offset == qu.MMIO_CTL:
            return (1 if self.enabled else 0) | (2 if self.wr_cpl_en else 0)
        return struct.unpack_from("<I", self.regs, offset)[0]

    def write32(self, offset: int, value: int) -> None:
        self.trace.append(("w", offset, value))
        if offset == qu.MMIO_CTL:
            self.enabled = bool(value & qu.CTL_ENABLE)
            self.wr_cpl_en = bool(value & qu.CTL_WR_CPL_EN)
            return
        if offset == qu.MMIO_DONE:
            if value & 1:
                self.done_sticky = False
                self.irq_pending = False
            return
        if offset == qu.MMIO_DOORBELL:
            self._run(value & 0xFF, (value >> 8) & 0x7FFFFF)
            return
        if 0x120 <= offset < 0x140 or 0x1A0 <= offset < 0x1A0 + (self.queues - 1) * 0x20:
            struct.pack_into("<I", self.regs, offset, value)
            if offset < 0x140:
                qid, field, q = 0, offset - 0x120, 0x120
            else:
                qid, field = divmod(offset - 0x1A0, 0x20)
                qid += 1
                q = 0x1A0 + (qid - 1) * 0x20
            if field == qu.QUEUE_PERM:
                lo = struct.unpack_from("<I", self.regs, q + qu.QUEUE_BASE_LO)[0]
                hi = struct.unpack_from("<I", self.regs, q + qu.QUEUE_BASE_HI)[0]
                llo = struct.unpack_from("<I", self.regs, q + qu.QUEUE_LIMIT_LO)[0]
                lhi = struct.unpack_from("<I", self.regs, q + qu.QUEUE_LIMIT_HI)[0]
                self.regions[qid] = (lo | (hi << 32), llo | (lhi << 32), value)
            return
        struct.pack_into("<I", self.regs, offset, value)

    # -- the engine ----------------------------------------------------------
    def _run(self, qid: int, ticket: int) -> None:
        self.ticket = ticket
        if not self.enabled:
            self.last_status = 6  # ST_DISABLED
            self.done_sticky = True
            return
        d = struct.unpack_from("<HHIIIIIQQQQQ", self.regs, qu.MMIO_DESC)
        version, op, flags, m, n, k, ld_ab, pa, pb, pc, _ps, pdone = d
        if version != 2:
            self.last_status = 2
        elif op != 1:
            self.last_status = 3
        elif not (
            0 < m <= self.acc_tile_m and 0 < n <= self.acc_tile_n and 0 < k <= self.acc_tile_k
        ):
            self.last_status = 1  # ST_ERR, matching the engine's ST_CHK
        elif not self._admitted(qid, [pa, pb, pc, pdone]):
            self.last_status = 4  # ST_BAD_PTR
        else:
            lda, ldb = ld_ab & 0xFFFF, ld_ab >> 16
            from ai_tensor.numfmt import gemm_native, layout
            from ai_tensor.policy import FLAG_REUSE_A, FLAG_REUSE_B

            fmt = (flags >> 20) & 7
            accmode = (flags >> 10) & 3
            try:
                if accmode > 1 or (accmode == 1 and not self.accumulate):
                    raise ValueError("ST_BAD_FMT: accmode")
                _, _, na, nb, c_len = layout(m, n, k, fmt, lda, ldb)
                seed = self.dma.read(pc - self.dma.base, c_len) if accmode == 1 else None
                a = self.dma.read(pa - self.dma.base, na)
                b = self.dma.read(pb - self.dma.base, nb)
                _, a = self._reuse.bind(
                    "a", flags & FLAG_REUSE_A, (pa, m, k, lda, fmt), a, True
                )
                _, b = self._reuse.bind(
                    "b", flags & FLAG_REUSE_B, (pb, n, k, ldb, fmt), b, True
                )
                out = gemm_native(a, b, m, n, k, fmt, lda, ldb, self.read32(qu.CAP_DTYPE_MASK),
                                  c_init=seed)
                self._reuse.finish(True)
                self.dma.write(pc - self.dma.base, out)
                self.last_status = 0
            except ValueError:
                self._reuse.finish(False)
                self.last_status = 8
            self._last_read_a = self._reuse.last_read_a
            self._last_read_b = self._reuse.last_read_b
        self.done_sticky = True
        self.irq_pending = True
        if self.wr_cpl_en and pdone:
            word = (self.last_status << 32) | self.ticket
            self.dma.write(pdone - self.dma.base, struct.pack("<Q", word))

    def _admitted(self, qid: int, ptrs: list[int]) -> bool:
        r = self.regions.get(qid)
        if not r:
            return False
        base, limit, perm = r
        if not perm:
            return False
        return all(base <= p < limit for p in ptrs if p)


def session(**kw) -> tuple[qu.QemuUioSession, FakeIsland, FakeDma]:
    dma = FakeDma()
    isl = FakeIsland(dma, **kw)
    return qu.QemuUioSession(isl, dma, irq=None), isl, dma


class TestCapabilityDiscovery(unittest.TestCase):
    def test_geometry_comes_from_the_capability_window(self):
        s, _, _ = session(acc_tile=64)
        self.assertEqual(s.caps.acc_tile_m, 64)
        self.assertEqual(s.caps.acc_tile_n, 64)
        self.assertEqual(s.caps.acc_tile_k, 64)
        self.assertEqual(s.caps.queues, 2)
        self.assertEqual(s.caps.queue_depth, 64)
        self.assertEqual(s.caps.noc_width, 64)

    def test_one_binary_reads_a_different_part_differently(self):
        # The property the capability window exists for: no recompile, no env override.
        small, _, _ = session(acc_tile=16)
        large, _, _ = session(acc_tile=256)
        self.assertEqual(small.caps.acc_tile_k, 16)
        self.assertEqual(large.caps.acc_tile_k, 256)

    def test_opening_a_session_enables_the_island(self):
        _, isl, _ = session()
        self.assertTrue(isl.enabled, "an island left disabled completes ST_DISABLED")
        self.assertTrue(isl.wr_cpl_en, "the completion word names the finished ticket")


class TestSubmissionProtocol(unittest.TestCase):
    def test_native_bytes_preserve_format_and_kmajor_layout(self):
        s, isl, dma = session()
        struct.pack_into('<I', isl.regs, qu.CAP_DTYPE_MASK, 0xfb)
        s.caps = qu.read_caps(isl)
        self.assertEqual(s.caps.dtype_mask, 0xfb)
        a = struct.pack('<3f', 1, 2, 3)
        b = struct.pack('<6f', 4, 5, 6, 7, 8, 9)
        out = s.gemm_native(a, b, 1, 2, 3, 7)
        self.assertEqual(struct.unpack('<2f', out), (32, 50))
        self.assertEqual(dma.read(0, len(a)), a)
        self.assertEqual(dma.read(64, len(b)), b)
        self.assertEqual(struct.unpack_from('<I', isl.regs, qu.MMIO_DESC + 20)[0], 3 | (3 << 16))
        self.assertEqual(struct.unpack_from('<I', isl.regs, qu.MMIO_DESC + 4)[0] >> 20, 7)

    def test_native_invalid_inputs_do_not_write_dma(self):
        s, isl, dma = session()
        before = bytes(dma._buf)
        for fmt in (2, 7):
            with self.assertRaises(ValueError):
                s.gemm_native(bytes(4), bytes(4), 1, 1, 1, fmt)
        with self.assertRaises(ValueError):
            s.gemm_s8(2, 2, 2, [1], [1, 2, 3, 4])
        self.assertEqual(bytes(dma._buf), before)
        self.assertFalse(any(op == 'w' and off == qu.MMIO_DOORBELL for op, off, _ in isl.trace))

    def test_v1_submission_is_refused(self):
        s, _, _ = session()
        desc = bytearray(64)
        struct.pack_into('<H', desc, 0, 1)
        with self.assertRaisesRegex(ValueError, 'v2 required'):
            s.submit(desc)

    def test_gemm_matches_the_int8_golden(self):
        s, _, _ = session()
        a = [1, 2, 3, 4]
        b = [5, 6, 7, 8]
        c, ticket, status = s.gemm_s8(2, 2, 2, a, b)
        self.assertEqual(status, 0)
        self.assertEqual(c, [19, 22, 43, 50])
        self.assertEqual(ticket, 1)

    def test_negative_operands_are_signed(self):
        s, _, _ = session()
        c, _, status = s.gemm_s8(1, 1, 1, [-3], [5])
        self.assertEqual((status, c), (0, [-15]))

    def test_the_region_is_programmed_before_the_doorbell_rings(self):
        s, isl, _ = session()
        s.gemm_s8(2, 2, 2, [1, 2, 3, 4], [5, 6, 7, 8])
        writes = [off for kind, off, _ in isl.trace if kind == "w"]
        perm = qu.MMIO_QUEUE0 + qu.QUEUE_PERM
        self.assertIn(perm, writes, "AI-3 region must be committed")
        self.assertIn(qu.MMIO_DOORBELL, writes)
        self.assertLess(
            writes.index(perm),
            writes.index(qu.MMIO_DOORBELL),
            "a job submitted before its region is admitted returns ST_BAD_PTR",
        )

    def test_the_descriptor_is_latched_before_the_doorbell_rings(self):
        s, isl, _ = session()
        s.gemm_s8(2, 2, 2, [1, 2, 3, 4], [5, 6, 7, 8])
        writes = [off for kind, off, _ in isl.trace if kind == "w"]
        last_desc = max(
            i for i, off in enumerate(writes) if qu.MMIO_DESC <= off < qu.MMIO_DESC + 64
        )
        self.assertLess(last_desc, writes.index(qu.MMIO_DOORBELL))

    def test_done_is_claimed_after_completion_is_observed(self):
        s, isl, _ = session()
        s.gemm_s8(2, 2, 2, [1, 2, 3, 4], [5, 6, 7, 8])
        self.assertFalse(
            isl.done_sticky, "DONE must be claimed or the next job cannot be told apart"
        )
        self.assertFalse(
            isl.irq_pending,
            "the level source must be cleared before the PLIC is completed, "
            "or a level-set re-arms it",
        )

    def test_the_completion_word_names_the_ticket_and_status(self):
        s, _, dma = session()
        s.gemm_s8(2, 2, 2, [1, 2, 3, 4], [5, 6, 7, 8])
        # A, B then C then the completion word, each 64-byte aligned.
        (word,) = struct.unpack("<Q", dma.read(64 + 64 + 64, 8))
        self.assertEqual(word & 0xFFFF_FFFF, 1, "ticket")
        self.assertEqual((word >> 32) & 0xFFFF, 0, "ST_OK")

    def test_pmu_is_read_from_the_sticky_window(self):
        s, isl, _ = session()
        struct.pack_into("<I", isl.regs, qu.MMIO_PMU_CY, 4242)
        self.assertEqual(s.pmu()["cycles"], 4242)


class TestAccumulateMode(unittest.TestCase):
    A = bytes([1, 2, 3, 4])
    B = bytes([5, 7, 6, 8])  # k-major B: rows are output columns

    def test_seed_is_added_when_granted(self):
        s, isl, _ = session(accumulate=True)
        self.assertTrue(s.caps.accumulate)
        first = s.gemm_native(self.A, self.B, 2, 2, 2, 0)
        self.assertEqual(struct.unpack("<4i", first), (19, 22, 43, 50))
        second = s.gemm_native(self.A, self.B, 2, 2, 2, 0, c_init=first)
        self.assertEqual(struct.unpack("<4i", second), (38, 44, 86, 100))
        # The descriptor actually carried accmode 01.
        flags = [v for kind, off, v in isl.trace if kind == "w" and off == qu.MMIO_DESC + 4]
        self.assertEqual((flags[-1] >> 10) & 3, 1)

    def test_ungranted_island_refuses_before_any_traffic(self):
        s, isl, _ = session(accumulate=False)
        self.assertFalse(s.caps.accumulate)
        before = len(isl.trace)
        with self.assertRaisesRegex(ValueError, "not granted"):
            s.gemm_native(self.A, self.B, 2, 2, 2, 0, c_init=bytes(16))
        self.assertEqual(len(isl.trace), before)

    def test_device_facade_routes_accumulate_to_uio(self):
        from ai_tensor.device import Device

        s, _, _ = session(accumulate=True)
        dev = Device("qemu-uio", session=s)
        self.assertTrue(dev.caps().accumulate)
        first = dev.gemm_native(self.A, self.B, 2, 2, 2, 0)
        second = dev.gemm_native(self.A, self.B, 2, 2, 2, 0, c_init=first)
        self.assertEqual(struct.unpack("<4i", second), (38, 44, 86, 100))


class TestRefusals(unittest.TestCase):
    def test_a_shape_beyond_the_tile_is_refused_on_the_host(self):
        # The engine would return an error status; refusing before submission gives the
        # caller a usable message and keeps the tiling decision where it belongs.
        s, _, _ = session(acc_tile=2)
        with self.assertRaises(ValueError) as cm:
            s.gemm_s8(4, 4, 4, [0] * 16, [0] * 16)
        self.assertIn("accumulator tile", str(cm.exception))

    def test_a_job_larger_than_the_dma_window_is_refused(self):
        dma = FakeDma(size=128)
        isl = FakeIsland(dma)
        s = qu.QemuUioSession(isl, dma, irq=None)
        with self.assertRaises(ValueError) as cm:
            s.gemm_s8(8, 8, 8, [1] * 64, [1] * 64)
        self.assertIn("DMA window", str(cm.exception))

    def test_a_disabled_island_reports_its_own_status_code(self):
        s, isl, _ = session()
        isl.enabled = False
        _, _, status = s.gemm_s8(2, 2, 2, [1, 2, 3, 4], [5, 6, 7, 8])
        self.assertEqual(status, 6, "ST_DISABLED")

    def test_a_nonexistent_queue_is_refused(self):
        s, _, _ = session(queues=1)
        with self.assertRaises(ValueError):
            s.program_region(3, DMA_BASE, DMA_BASE + 0x100)

    def test_a_virtual_uio_path_is_not_a_real_one(self):
        old = os.environ.get("AI_TENSOR_UIO")
        os.environ["AI_TENSOR_UIO"] = "virt://virt-ai-pcie/island0"
        try:
            with self.assertRaises(ValueError):
                qu.open_from_env()
        finally:
            if old is None:
                os.environ.pop("AI_TENSOR_UIO", None)
            else:
                os.environ["AI_TENSOR_UIO"] = old

    def test_a_missing_dma_base_is_an_error_not_a_default(self):
        saved = {k: os.environ.get(k) for k in ("AI_TENSOR_UIO", "AI_TENSOR_DMA_BASE")}
        os.environ["AI_TENSOR_UIO"] = "/dev/uio0"
        os.environ.pop("AI_TENSOR_DMA_BASE", None)
        try:
            with self.assertRaises(RuntimeError) as cm:
                qu.open_from_env()
            self.assertIn("AI_TENSOR_DMA_BASE", str(cm.exception))
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


class TestDeviceFacade(unittest.TestCase):
    def test_the_device_selects_and_drives_the_uio_backend(self):
        dma = FakeDma()
        isl = FakeIsland(dma)
        s = qu.QemuUioSession(isl, dma, irq=None)
        dev = Device("qemu-uio", session=s)
        self.assertEqual(dev.backend, "qemu-uio")
        # Caps flow from the window, and `compute_ref` is False: this is a device, not a
        # software reference, so a mismatch is a finding rather than a rounding question.
        self.assertEqual(dev.caps().acc_tile_m, 256)
        self.assertFalse(dev.caps().compute_ref)
        c, _, status, meta = dev.gemm_s8(2, 2, 2, [1, 2, 3, 4], [5, 6, 7, 8])
        self.assertEqual((status, c), (0, [19, 22, 43, 50]))
        self.assertEqual(meta["uio"]["mode"], "uio")
        dev.close()
        self.assertFalse(isl.enabled, "close() must leave the island quiescent")

    def test_the_device_tiles_a_shape_the_island_would_refuse(self):
        # F12: software owns blocking beyond the accumulator tile. This is the path the
        # PyTorch partitioner takes, so it is pinned on the real backend.
        dma = FakeDma()
        isl = FakeIsland(dma, acc_tile=2)
        s = qu.QemuUioSession(isl, dma, irq=None)
        dev = Device("qemu-uio", session=s)
        m = n = k = 4
        a = list(range(1, m * k + 1))
        b = list(range(1, k * n + 1))
        c, _, status, meta = dev.gemm_s8(m, n, k, a, b)
        self.assertEqual(status, 0)
        self.assertTrue(meta["auto_tile"])
        self.assertEqual(meta["tiles"], 8, "2x2x2 blocking of a 4x4x4 shape")
        expect = [
            sum(a[i * k + t] * b[t * n + j] for t in range(k))
            for i in range(m)
            for j in range(n)
        ]
        self.assertEqual(c, expect)


class TestEnvSelection(unittest.TestCase):
    def test_a_real_uio_node_with_a_dma_window_selects_qemu_uio(self):
        from ai_tensor.device import _env_backend_default

        saved = {
            k: os.environ.get(k)
            for k in (
                "AI_TENSOR_BACKEND",
                "AI_TENSOR_BOARD_ID",
                "AI_TENSOR_UIO",
                "AI_TENSOR_DMA_BASE",
            )
        }
        try:
            for k in saved:
                os.environ.pop(k, None)
            os.environ["AI_TENSOR_UIO"] = "/dev/uio0"
            os.environ["AI_TENSOR_DMA_BASE"] = "0x90000000"
            self.assertEqual(_env_backend_default(), "qemu-uio")
            # Without a DMA window there is nothing the island could read, so the
            # in-guest backend is not selected by accident.
            os.environ.pop("AI_TENSOR_DMA_BASE")
            self.assertEqual(_env_backend_default(), "sim")
            # A virtual path still means the host stand-in.
            os.environ["AI_TENSOR_UIO"] = "virt://virt-ai-pcie/island0"
            self.assertEqual(_env_backend_default(), "virt-card")
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


class TestDirectedSchedule(unittest.TestCase):
    def _directed(self):
        return session(acc_tile_m=1024, acc_tile_n=512, acc_tile_k=16, macs=8)

    def test_a_default_window_ignores_the_flag_and_refuses_the_schedule(self) -> None:
        from ai_tensor.policy import FLAG_REUSE_B

        s, isl, _ = session()
        self.assertFalse(s.reports_directed_tile())
        with self.assertRaises(ValueError):
            s.run_va_turbo_test_s8(16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))
        s.gemm_s8(1, 1, 1, [1], [2])
        c, _, status = s.gemm_s8(1, 1, 1, [1], [9], flags=FLAG_REUSE_B)
        self.assertEqual(status, 0)
        self.assertEqual(c, [9])
        self.assertTrue(isl.last_read_b())

    def test_the_directed_window_skips_only_when_a_tile_does(self) -> None:
        from ai_tensor.policy import FLAG_REUSE_A, FLAG_REUSE_B

        s, isl, _ = self._directed()
        self.assertTrue(s.reports_directed_tile())
        s.gemm_s8(1, 1, 1, [1], [2])
        kept, _, status = s.gemm_s8(1, 1, 1, [1], [9], flags=FLAG_REUSE_B)
        self.assertEqual(status, 0)
        self.assertEqual(kept, [2])
        self.assertFalse(isl.last_read_b())

        m_split = s.run_va_turbo_test_s8(16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))
        self.assertEqual(m_split["flags"][1] & FLAG_REUSE_B, FLAG_REUSE_B)
        self.assertEqual(m_split["flags"][1] & FLAG_REUSE_A, 0)
        self.assertTrue(m_split["reuse_enabled"])
        self.assertTrue(m_split["hit_b"])
        self.assertFalse(m_split["hit_a"])
        self.assertTrue(m_split["read_a"])
        self.assertFalse(m_split["read_b"])
        self.assertEqual(m_split["applied_level"], 0)
        self.assertEqual(m_split["c"], [8] * (16 * 8))

        k_split = s.run_va_turbo_test_s8(8, 8, 16, [1] * (8 * 16), [1] * (16 * 8))
        self.assertEqual(k_split["flags"][1] & (FLAG_REUSE_A | FLAG_REUSE_B), 0)
        self.assertFalse(k_split["reuse_enabled"])
        self.assertTrue(k_split["read_a"])
        self.assertTrue(k_split["read_b"])
        self.assertEqual(k_split["c"], [16] * (8 * 8))

    def test_high_level_uses_the_window_and_not_a_caps_override(self) -> None:
        from ai_tensor.device import Caps, run_high_level_s8

        s, _, _ = self._directed()
        dev = Device("qemu-uio", session=s)
        c, meta = run_high_level_s8(dev, 16, 8, 8, [1] * (16 * 8), [1] * (8 * 8))
        self.assertTrue(meta["exact_reuse"])
        self.assertTrue(meta["hit_b"])
        self.assertFalse(meta["hit_a"])
        self.assertEqual(meta["applied_level"], 0)
        self.assertFalse(meta["port_promoted"])
        self.assertEqual(c, [8] * (16 * 8))
        dev.close()

        plain, _, _ = session()
        overridden = Device(
            "qemu-uio",
            session=plain,
            caps=Caps(acc_tile_m=1024, acc_tile_n=512, acc_tile_k=16, macs_per_cycle=8),
        )
        c_live, meta_live = run_high_level_s8(
            overridden, 16, 8, 8, [1] * (16 * 8), [1] * (8 * 8)
        )
        self.assertFalse(meta_live["exact_reuse"])
        self.assertFalse(meta_live["hit_b"])
        self.assertEqual(c_live, c)
        overridden.close()


class TestCompletionOwnership(unittest.TestCase):
    def test_queue_one_region_does_not_overwrite_descriptor(self):
        s, isl, _ = session()
        poison = b"\xa5" * 64
        isl.regs[qu.MMIO_DESC:qu.MMIO_DESC + 64] = poison
        isl.trace.clear()
        s.program_region(1, DMA_BASE, DMA_BASE + 256)
        writes = [(off, value) for op, off, value in isl.trace if op == "w"]
        self.assertEqual([off for off, _ in writes], [0x1A0, 0x1A4, 0x1A8, 0x1AC, 0x1B0])
        self.assertEqual(isl.regs[qu.MMIO_DESC:qu.MMIO_DESC + 64], poison)

    def test_invalid_qids_do_not_touch_registers(self):
        for qid in (-1, 2, 255, 256):
            with self.subTest(qid=qid):
                s, isl, _ = session()
                isl.trace.clear()
                with self.assertRaises(ValueError):
                    s.submit(qu.pack_gemm_desc(1, 1, 1), qid=qid)
                self.assertFalse(any(op == "w" for op, _, _ in isl.trace))
        s, isl, _ = session()
        isl.trace.clear()
        with self.assertRaises(ValueError):
            s.program_region(-1, DMA_BASE, DMA_BASE + 256)
        self.assertFalse(any(op == "w" for op, _, _ in isl.trace))

    def test_idle_without_done_is_not_completion(self):
        s, isl, _ = session()
        s.submit(qu.pack_gemm_desc(1, 1, 1))
        isl.done_sticky = False
        isl.trace.clear()
        with self.assertRaises(TimeoutError):
            s.wait(timeout=0)
        self.assertNotIn(("w", qu.MMIO_DONE, 1), isl.trace)

    def test_wrong_ticket_is_not_claimed(self):
        s, isl, _ = session()
        s.submit(qu.pack_gemm_desc(1, 1, 1))
        isl.ticket = 99
        isl.trace.clear()
        with self.assertRaises(TimeoutError):
            s.wait(timeout=0)
        self.assertTrue(isl.done_sticky)
        self.assertNotIn(("w", qu.MMIO_DONE, 1), isl.trace)

    def test_pending_submission_owns_dma_until_completion(self):
        s, isl, dma = session()
        s.submit(qu.pack_gemm_desc(1, 1, 1))
        before = bytes(dma._buf)
        isl.trace.clear()
        with self.assertRaises(RuntimeError):
            s.gemm_s8(1, 1, 1, [7], [9])
        self.assertEqual(bytes(dma._buf), before)
        self.assertFalse(any(op == "w" for op, _, _ in isl.trace))

    def test_spurious_irq_does_not_prove_completion(self):
        class Irq:
            def enable(self):
                pass

            def wait(self, timeout=None):
                return True

        s, isl, _ = session()
        s.irq = Irq()
        s.submit(qu.pack_gemm_desc(1, 1, 1))
        isl.done_sticky = False
        isl.trace.clear()
        with self.assertRaises(TimeoutError):
            s.wait(timeout=0)
        self.assertNotIn(("w", qu.MMIO_DONE, 1), isl.trace)

    def test_delayed_acceptance_preserves_result_and_claim_order(self):
        class Delayed(FakeIsland):
            pending = None
            reads = 0

            def write32(self, offset, value):
                if offset == qu.MMIO_DOORBELL:
                    self.pending = value
                    self.trace.append(("w", offset, value))
                else:
                    super().write32(offset, value)

            def read32(self, offset):
                if offset == qu.MMIO_DONE and self.pending is not None:
                    self.reads += 1
                    if self.reads == 3:
                        super().write32(qu.MMIO_DOORBELL, self.pending)
                        self.pending = None
                return super().read32(offset)

        dma = FakeDma()
        isl = Delayed(dma)
        s = qu.QemuUioSession(isl, dma)
        c, ticket, status = s.gemm_s8(2, 2, 2, [1, 2, 3, 4], [5, 6, 7, 8])
        self.assertEqual((c, ticket, status), ([19, 22, 43, 50], 1, 0))
        self.assertEqual(isl.reads, 3)
        self.assertEqual(isl.trace.count(("w", qu.MMIO_DONE, 1)), 1)

    def test_irq_request_and_rearm_follow_claim(self):
        s, isl, _ = session()

        class Irq:
            def enable(self):
                isl.trace.append(("irq-enable", 0, 0))

            def wait(self, timeout=None):
                return True

        s.irq = Irq()
        s.gemm_s8(1, 1, 1, [2], [3])
        flags = struct.unpack_from('<I', isl.regs, qu.MMIO_DESC + 4)[0]
        self.assertTrue(flags & (1 << 2))
        self.assertEqual(isl.trace.count(("w", qu.MMIO_DONE, 1)), 1)
        claim = isl.trace.index(("w", qu.MMIO_DONE, 1))
        self.assertIn(("irq-enable", 0, 0), isl.trace[claim + 1:])

    def test_last_wire_ticket_is_preserved(self):
        s, _, _ = session()
        s._ticket = 0x7FFFFE
        c, ticket, status = s.gemm_s8(1, 1, 1, [2], [3])
        self.assertEqual((c, ticket, status), ([6], 0x7FFFFF, 0))

    def test_timeout_preserves_the_pending_request(self):
        s, isl, _ = session()
        issued = s.submit(qu.pack_gemm_desc(1, 1, 1))
        isl.done_sticky = False
        with self.assertRaises(TimeoutError):
            s.wait(timeout=0)
        with self.assertRaises(RuntimeError):
            s.submit(qu.pack_gemm_desc(1, 1, 1))
        isl.ticket = issued
        isl.done_sticky = True
        isl.last_status = 1
        self.assertEqual(s.wait(timeout=0), 1)

    def test_ticket_exhaustion_cannot_reuse_a_wire_identity(self):
        s, isl, _ = session()
        s._ticket = 0x7FFFFF
        isl.trace.clear()
        with self.assertRaises(ValueError):
            s.submit(qu.pack_gemm_desc(1, 1, 1))
        self.assertFalse(any(op == "w" for op, _, _ in isl.trace))


class FakeCommandWindow:
    def __init__(self, depth=2):
        self.regs = {0x90: (depth << 16) | 0x107, 0x1C: 2, 0x100: 3, 0xF20: 0}
        self.depth = depth
        self.commands = []
        self.completions = []
        self.writes = []
        self.mismatch = False

    def read32(self, offset):
        if offset == 0xF38:
            return self.depth - len(self.commands)
        if offset == 0x10C:
            return int(bool(self.completions))
        if offset == 0x110:
            return self.completions[0][0] if self.completions else 0
        if offset == 0x114:
            return self.completions[0][1] if self.completions else 0
        return self.regs.get(offset, 0)

    def write32(self, offset, value):
        self.writes.append((offset, value))
        if offset == 0x10C and value & 1:
            self.completions.pop(0)
            return
        if offset == 0xF20 and value == 0 and (self.commands or self.completions):
            raise RuntimeError("busy mode transition")
        self.regs[offset] = value
        if offset == 0xF34 and value & 1:
            ticket = self.regs[0xF2C]
            code = 2 if not self.regs[0xF20] else (1 if len(self.commands) >= self.depth else 0)
            if code == 0:
                self.commands.append((ticket, self.regs[0xF30], self.regs[0xF24] | self.regs[0xF28] << 32))
            self.regs[0xF3C] = ticket + int(self.mismatch)
            self.regs[0xF40] = code

    def complete(self, status=0):
        ticket, _, _ = self.commands.pop(0)
        self.completions.append((ticket, status))


class TestQueuedMmio(unittest.TestCase):
    def test_requires_advertised_profile_before_writes(self):
        window = FakeCommandWindow()
        window.regs[0x90] = 0
        with self.assertRaises(NotImplementedError):
            qu.QueuedMmioSession(window)
        self.assertEqual(window.writes, [])

    def test_credits_receipts_and_completion_ownership(self):
        window = FakeCommandWindow()
        queue = qu.QueuedMmioSession(window)
        queue.enable()
        a, b, rejected = object(), object(), object()
        self.assertTrue(queue.submit(0x1000, ticket=0xF0000001, lease=a))
        self.assertTrue(queue.submit(0x1040, ticket=0xF0000002, lease=b))
        self.assertFalse(queue.submit(0x1080, ticket=0xF0000003, lease=rejected))
        self.assertEqual(queue.pending_tickets, (0xF0000001, 0xF0000002))
        self.assertEqual(queue.credits, 0)
        with self.assertRaises(RuntimeError):
            queue.disable()
        window.complete(8)
        self.assertEqual(queue.poll(), (0xF0000001, 8))
        window.complete()
        self.assertEqual(queue.poll(), (0xF0000002, 0))
        queue.disable()
        self.assertEqual(window.regs[0xF20], 0)

    def test_timeout_and_foreign_head_do_not_release(self):
        window = FakeCommandWindow()
        queue = qu.QueuedMmioSession(window)
        queue.enable()
        queue.submit(0x1000, ticket=7, lease=object())
        window.completions.append((99, 0))
        self.assertIsNone(queue.poll())
        with self.assertRaises(TimeoutError):
            queue.wait(timeout=0)
        self.assertEqual(queue.pending_tickets, (7,))
        self.assertEqual(window.completions, [(99, 0)])

    def test_ambiguous_receipt_blocks_reuse_until_resolved(self):
        window = FakeCommandWindow()
        queue = qu.QueuedMmioSession(window)
        queue.enable()
        window.mismatch = True
        with self.assertRaises(RuntimeError):
            queue.submit(0x1000, ticket=7, lease=object())
        self.assertEqual(queue.pending_tickets, (7,))
        with self.assertRaises(RuntimeError):
            queue.submit(0x1040, ticket=8, lease=object())
        window.regs[0xF3C] = 7
        self.assertTrue(queue.resolve_submission())
        window.complete()
        self.assertEqual(queue.poll(), (7, 0))
        with self.assertRaises(ValueError):
            queue.submit(0x1080, ticket=7, lease=object())

    def test_full_receipt_allows_retry_without_reusing_accepted_ticket(self):
        window = FakeCommandWindow(depth=1)
        queue = qu.QueuedMmioSession(window)
        queue.enable()
        self.assertTrue(queue.submit(0x1000, ticket=1, lease=object()))
        self.assertFalse(queue.submit(0x1040, ticket=2, lease=object()))
        window.complete()
        self.assertEqual(queue.poll(), (1, 0))
        self.assertTrue(queue.submit(0x1040, ticket=2, lease=object()))

    def test_exception_after_submit_keeps_the_lease(self):
        class FaultyWindow(FakeCommandWindow):
            def write32(self, offset, value):
                super().write32(offset, value)
                if offset == 0xF34:
                    raise OSError("lost acknowledgment")

        window = FaultyWindow()
        queue = qu.QueuedMmioSession(window)
        queue.enable()
        with self.assertRaises(OSError):
            queue.submit(0x1000, ticket=1, lease=object())
        self.assertEqual(queue.pending_tickets, (1,))
        self.assertTrue(queue.resolve_submission())
        window.complete()
        self.assertEqual(queue.poll(), (1, 0))

    def test_invalid_commands_have_no_effect(self):
        window = FakeCommandWindow()
        queue = qu.QueuedMmioSession(window)
        queue.enable()
        before = list(window.writes)
        for pointer, ticket, qid in ((0, 1, 0), (3, 1, 0), (1 << 64, 1, 0),
                                     (0x1000, 1 << 32, 0), (0x1000, 1, 2)):
            with self.subTest(pointer=pointer, ticket=ticket, qid=qid):
                with self.assertRaises(ValueError):
                    queue.submit(pointer, ticket=ticket, qid=qid, lease=object())
        self.assertEqual(before, window.writes)


if __name__ == "__main__":
    unittest.main(verbosity=2)
