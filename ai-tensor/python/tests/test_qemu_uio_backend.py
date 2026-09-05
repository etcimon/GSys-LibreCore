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

    def __init__(self, dma: FakeDma, *, acc_tile: int = 256, queues: int = 2):
        self.dma = dma
        self.acc_tile = acc_tile
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
        self._install_caps()

    # -- capability window ---------------------------------------------------
    def _install_caps(self) -> None:
        lg = self.acc_tile.bit_length() - 1
        block = (
            (lg << qu.CAP_BLOCK_M_SHIFT)
            | (lg << qu.CAP_BLOCK_N_SHIFT)
            | (lg << qu.CAP_BLOCK_K_SHIFT)
        )
        for off, val in [
            (qu.CAP_VERSION, 1),
            (qu.CAP_DTYPE_MASK, 1),
            (qu.CAP_CLUSTERS, 1 | (1 << 16)),
            (qu.CAP_MACS_CYCLE, 256),
            (qu.CAP_CLOCK_KHZ, 1_000_000),
            (qu.CAP_SRAM_BYTES, 2 << 20),
            (qu.CAP_BLOCK_MNK, block),
            (qu.CAP_DRAM_GBPS, 8),
            (qu.CAP_QUEUES, self.queues | (64 << 16)),
            (qu.CAP_NOC_WIDTH, 64),
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
            self._run(value & 0xFF)
            return
        if qu.MMIO_QUEUE0 <= offset < qu.MMIO_DESC:
            struct.pack_into("<I", self.regs, offset, value)
            rel = offset - qu.MMIO_QUEUE0
            qid, field = divmod(rel, qu.QUEUE_STRIDE)
            if field == qu.QUEUE_PERM:
                q = qu.MMIO_QUEUE0 + qid * qu.QUEUE_STRIDE
                lo = struct.unpack_from("<I", self.regs, q + qu.QUEUE_BASE_LO)[0]
                hi = struct.unpack_from("<I", self.regs, q + qu.QUEUE_BASE_HI)[0]
                llo = struct.unpack_from("<I", self.regs, q + qu.QUEUE_LIMIT_LO)[0]
                lhi = struct.unpack_from("<I", self.regs, q + qu.QUEUE_LIMIT_HI)[0]
                self.regions[qid] = (lo | (hi << 32), llo | (lhi << 32), value)
            return
        struct.pack_into("<I", self.regs, offset, value)

    # -- the engine ----------------------------------------------------------
    def _run(self, qid: int) -> None:
        self.ticket += 1
        if not self.enabled:
            self.last_status = 6  # ST_DISABLED
            self.done_sticky = True
            return
        d = struct.unpack_from("<HHIIIIIQQQQQ", self.regs, qu.MMIO_DESC)
        version, op, _flags, m, n, k, ld_ab, pa, pb, pc, _ps, pdone = d
        if version != 2:
            self.last_status = 2
        elif op != 1:
            self.last_status = 3
        elif not (0 < m <= self.acc_tile and 0 < n <= self.acc_tile and 0 < k <= self.acc_tile):
            self.last_status = 1  # ST_ERR, matching the engine's ST_CHK
        elif not self._admitted(qid, [pa, pb, pc, pdone]):
            self.last_status = 4  # ST_BAD_PTR
        else:
            lda, ldb = ld_ab & 0xFFFF, ld_ab >> 16
            from ai_tensor.numfmt import gemm_native, layout
            fmt = (_flags >> 20) & 7
            try:
                _, _, na, nb, _ = layout(m, n, k, fmt, lda, ldb)
                a = self.dma.read(pa - self.dma.base, na)
                b = self.dma.read(pb - self.dma.base, nb)
                out = gemm_native(a, b, m, n, k, fmt, lda, ldb, self.read32(qu.CAP_DTYPE_MASK))
                self.dma.write(pc - self.dma.base, out)
                self.last_status = 0
            except ValueError:
                self.last_status = 8
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
