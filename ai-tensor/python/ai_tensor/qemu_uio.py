# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
``qemu-uio`` backend: ai-tensor running **inside** a guest Linux, over UIO.

This is the only backend where the guest kernel binding, the device-tree node, the
interrupt path and the userspace runtime are all in the loop at once. ``sim`` and
``virt-card`` exercise the ABI and the contract shape; this exercises the *path*:

    UIO bind -> mmap the g6lc,ai-matrix window -> read CAP -> program the descriptor
    latch -> ring the doorbell -> wait on the IRQ -> claim DONE -> read C

Register offsets and status codes come from :mod:`ai_tensor.device` and
``include/ai_tensor.h``, which are the package's pinned view of the island MMIO
contract. Nothing is invented here.

Two properties are deliberate:

* **Geometry is read from the CAP window, never from the device tree helpers.** That is
  the rule on real hardware too, and it is what lets one binary run against a small and
  a large part. Discovering geometry from a DT property would silently pin the guest to
  one SKU.
* **Operand memory is guest-physical.** The island DMAs `A`/`B`/`C`, so buffers must live
  in a window it can reach. The window is supplied explicitly
  (``AI_TENSOR_DMA_BASE``/``AI_TENSOR_DMA_SIZE``), because guessing a DMA base is the
  same class of error as guessing an MMIO base.

Portability: the mapping and IRQ primitives are isolated behind :class:`MmioWindow` and
:class:`IrqSource` so the submission protocol can be exercised on any host, while the
real path uses ``mmap`` and a blocking ``read`` on ``/dev/uioN``.
"""

from __future__ import annotations

import os
import struct
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Protocol, Sequence, Tuple

from .device import ST_OK, pack_gemm_desc

# --- island MMIO map (byte offsets; mirrors include/ai_tensor.h) --------------
MMIO_CTL = 0x0100
MMIO_STATUS = 0x0104
MMIO_DOORBELL = 0x0108
MMIO_DONE = 0x010C
MMIO_TICKET = 0x0110
MMIO_DSTATUS = 0x0114
MMIO_QUEUE0 = 0x0120
MMIO_DESC = 0x0140
MMIO_PMU_R = 0x0180
MMIO_PMU_W = 0x0184
MMIO_PMU_CY = 0x0188
MMIO_PMU_GBPS = 0x018C

CTL_ENABLE = 1 << 0
CTL_WR_CPL_EN = 1 << 1

# --- capability window (byte offsets; mirrors g6lc_ai_island_cfg_pkg CAP_OFF_*)
CAP_VERSION = 0x00
CAP_CLUSTERS = 0x04
CAP_MACS_CYCLE = 0x08
CAP_CLOCK_KHZ = 0x0C
CAP_SRAM_BYTES = 0x10
CAP_BLOCK_MNK = 0x14
CAP_DRAM_GBPS = 0x18
CAP_QUEUES = 0x1C
CAP_DTYPE_MASK = 0x28
CAP_NOC_WIDTH = 0x3C
CAP_CLUSTER_EN = 0x30

# `block_mnk` packs log2 of each accumulator tile dimension in a nibble.
CAP_BLOCK_M_SHIFT = 0
CAP_BLOCK_N_SHIFT = 4
CAP_BLOCK_K_SHIFT = 8
CAP_BLOCK_FIELD_MASK = 0xF

# Per-queue region programming: base, limit, then permission (the write that commits).
QUEUE_STRIDE = 0x20
QUEUE_BASE_LO = 0x00
QUEUE_BASE_HI = 0x04
QUEUE_LIMIT_LO = 0x08
QUEUE_LIMIT_HI = 0x0C
QUEUE_PERM = 0x10
PERM_R = 1 << 0
PERM_W = 1 << 1

ISLAND_WINDOW_BYTES = 0x1000


class MmioWindow(Protocol):
    """A 32-bit little-endian register window."""

    def read32(self, offset: int) -> int: ...

    def write32(self, offset: int, value: int) -> None: ...


class IrqSource(Protocol):
    """A completion-interrupt source."""

    def enable(self) -> None: ...

    def wait(self, timeout: Optional[float] = None) -> bool:
        """Block until an interrupt arrives. False on timeout."""
        ...


class DmaMemory(Protocol):
    """Guest-physical memory the island can DMA."""

    @property
    def base(self) -> int:
        """Guest-physical address of offset zero."""
        ...

    @property
    def size(self) -> int: ...

    def read(self, offset: int, length: int) -> bytes: ...

    def write(self, offset: int, data: bytes) -> None: ...


@dataclass(frozen=True)
class IslandCaps:
    """Geometry as the capability window reports it."""

    cap_version: int
    clusters: int
    clusters_enabled: int
    macs_per_cycle: int
    clock_khz: int
    sram_bytes: int
    acc_tile_m: int
    acc_tile_n: int
    acc_tile_k: int
    queues: int
    queue_depth: int
    noc_width: int
    dram_gbps: int
    dram_gbps_measured_x1000: int
    dtype_mask: int

    def as_dict(self) -> Dict[str, int]:
        return dict(self.__dict__)


def read_caps(win: MmioWindow) -> IslandCaps:
    """Read the capability window.

    The accumulator tile is *derived* from the packed `block_mnk` word rather than from
    a separate field, because that is the only place the island publishes it — and it is
    the bound every descriptor dimension must respect.
    """
    block = win.read32(CAP_BLOCK_MNK)
    tile = lambda sh: 1 << ((block >> sh) & CAP_BLOCK_FIELD_MASK)  # noqa: E731
    clusters_word = win.read32(CAP_CLUSTERS)
    queues_word = win.read32(CAP_QUEUES)
    dram_word = win.read32(CAP_DRAM_GBPS)
    return IslandCaps(
        cap_version=win.read32(CAP_VERSION) & 0xFFFF,
        clusters=clusters_word & 0xFFFF,
        clusters_enabled=(clusters_word >> 16) & 0xFFFF,
        macs_per_cycle=win.read32(CAP_MACS_CYCLE),
        clock_khz=win.read32(CAP_CLOCK_KHZ),
        sram_bytes=win.read32(CAP_SRAM_BYTES),
        acc_tile_m=tile(CAP_BLOCK_M_SHIFT),
        acc_tile_n=tile(CAP_BLOCK_N_SHIFT),
        acc_tile_k=tile(CAP_BLOCK_K_SHIFT),
        queues=queues_word & 0xFFFF,
        queue_depth=(queues_word >> 16) & 0xFFFF,
        noc_width=win.read32(CAP_NOC_WIDTH),
        dram_gbps=dram_word & 0xFFFF,
        dram_gbps_measured_x1000=(dram_word >> 16) & 0xFFFF,
        dtype_mask=win.read32(CAP_DTYPE_MASK) & 0xFFFF,
    )


class QemuUioSession:
    """One island instance reached through a UIO mapping.

    ``irq`` may be ``None``, in which case completion is detected by polling the status
    register. That is not a shortcut: an island whose interrupt line the device tree does
    not describe genuinely cannot deliver one, and a runtime that blocked forever on a
    wire that does not exist would be worse than one that polls.
    """

    def __init__(
        self,
        window: MmioWindow,
        dma: DmaMemory,
        irq: Optional[IrqSource] = None,
        *,
        timeout: float = 5.0,
    ):
        self.window = window
        self.dma = dma
        self.irq = irq
        self.timeout = timeout
        self.caps = read_caps(window)
        self._ticket = 0
        # Enable the island and the completion-word write. `wr_cpl_en` matters because
        # the completion word is the only in-band signal that names *which* ticket
        # finished; the sticky DONE bit alone cannot say that.
        window.write32(MMIO_CTL, CTL_ENABLE | CTL_WR_CPL_EN)

    # -- region programming ---------------------------------------------------
    def program_region(self, qid: int, base: int, limit: int, perm: int = PERM_R | PERM_W) -> None:
        """Program a queue's ``[base, limit)`` DMA window and permissions.

        The permission write is what commits the region, so it is written last.
        """
        if qid >= max(self.caps.queues, 1):
            raise ValueError(
                f"queue {qid} does not exist; the capability window reports "
                f"{self.caps.queues}"
            )
        off = MMIO_QUEUE0 + qid * QUEUE_STRIDE
        self.window.write32(off + QUEUE_BASE_LO, base & 0xFFFFFFFF)
        self.window.write32(off + QUEUE_BASE_HI, (base >> 32) & 0xFFFFFFFF)
        self.window.write32(off + QUEUE_LIMIT_LO, limit & 0xFFFFFFFF)
        self.window.write32(off + QUEUE_LIMIT_HI, (limit >> 32) & 0xFFFFFFFF)
        self.window.write32(off + QUEUE_PERM, perm)

    # -- submission -----------------------------------------------------------
    def _latch(self, desc: bytes) -> None:
        if len(desc) % 4:
            raise ValueError("the descriptor latch is word-addressed")
        for i in range(0, len(desc), 4):
            (word,) = struct.unpack_from("<I", desc, i)
            self.window.write32(MMIO_DESC + i, word)

    def submit(self, desc: bytes, qid: int = 0) -> int:
        """Latch a descriptor and ring the doorbell. Returns the ticket."""
        from .c_abi import CONTRACT_VERSION
        if len(desc) != 64 or struct.unpack_from('<H', desc)[0] != CONTRACT_VERSION:
            raise ValueError('Desc64 v2 required; v1 B layout is not reinterpreted')
        from .numfmt import check_format
        check_format((struct.unpack_from('<I', desc, 4)[0] >> 20) & 7, self.caps.dtype_mask)
        self._latch(desc)
        self._ticket += 1
        ticket = self._ticket
        if self.irq is not None:
            self.irq.enable()
        # Doorbell: qid in the low byte, ticket above it.
        self.window.write32(MMIO_DOORBELL, (qid & 0xFF) | ((ticket & 0x7FFFFF) << 8))
        return ticket

    def wait(self, timeout: Optional[float] = None) -> int:
        """Wait for the current job and return its status.

        Ordering is the one the RTL requires and an in-guest driver must reproduce:
        observe completion, **claim DONE**, and only then let the interrupt controller be
        completed. Claiming after completing lets a level-set source re-arm immediately.
        """
        budget = self.timeout if timeout is None else timeout
        if self.irq is not None and self.irq.wait(budget):
            status = (self.window.read32(MMIO_STATUS) >> 16) & 0xFFFF
            self.window.write32(MMIO_DONE, 1)
            return status
        # Poll the status register's busy flag.
        deadline_spins = 1_000_000
        for _ in range(deadline_spins):
            st = self.window.read32(MMIO_STATUS)
            if st & 1 == 0:
                self.window.write32(MMIO_DONE, 1)
                return (st >> 16) & 0xFFFF
        raise TimeoutError("island did not complete the job")

    def pmu(self) -> Dict[str, int]:
        """Sticky counters from the last completed job."""
        return {
            "r_beats": self.window.read32(MMIO_PMU_R),
            "w_beats": self.window.read32(MMIO_PMU_W),
            "cycles": self.window.read32(MMIO_PMU_CY),
            "gbps_x1000": self.window.read32(MMIO_PMU_GBPS),
        }

    # -- the one op the engine implements ------------------------------------
    def gemm_s8(
        self,
        m: int,
        n: int,
        k: int,
        a: Sequence[int],
        b: Sequence[int],
        ticket: int = 1,
    ) -> Tuple[List[int], int, int]:
        """Run one INT8 GEMM whose shape already fits the accumulator tile.

        Tiling beyond the tile is the caller's job (``Device.gemm_s8`` does it), because
        the engine rejects an oversize dimension rather than streaming it.
        """
        if min(m, n, k) <= 0 or len(a) < m * k or len(b) < k * n:
            raise ValueError('invalid shape or short S8 operands')
        a_bytes = bytes(int(x) & 255 for x in a)
        b_bytes = bytes(int(b[t * n + j]) & 255 for j in range(n) for t in range(k))
        raw, issued, status = self._gemm_native_result(a_bytes, b_bytes, m, n, k, 0, ticket=ticket)
        return list(struct.unpack('<' + 'i' * (m * n), raw)), issued, status

    def gemm_native(self, a: bytes, b: bytes, m: int, n: int, k: int, numfmt: int,
                    lda=None, ldb=None, *, ticket: int = 1) -> bytes:
        raw, _, status = self._gemm_native_result(a, b, m, n, k, numfmt, lda, ldb, ticket=ticket)
        if status != ST_OK:
            raise RuntimeError(f'native GEMM failed with status {status}')
        return raw

    def _gemm_native_result(self, a, b, m, n, k, numfmt, lda=None, ldb=None, *, ticket=1):
        from .numfmt import validate_buffers
        from .c_abi import numfmt_flags
        a_bytes, b_bytes, lda, ldb, na, nb, c_len = validate_buffers(
            a, b, m, n, k, numfmt, lda, ldb, self.caps.dtype_mask)
        a_bytes, b_bytes = a_bytes[:na], b_bytes[:nb]
        if not (
            m <= self.caps.acc_tile_m
            and n <= self.caps.acc_tile_n
            and k <= self.caps.acc_tile_k
        ):
            raise ValueError(
                f"shape {m}x{n}x{k} exceeds the accumulator tile "
                f"{self.caps.acc_tile_m}x{self.caps.acc_tile_n}x{self.caps.acc_tile_k}; "
                "tile on the host"
            )

        # Lay A, B, C and the completion word out in the DMA window, 64-byte aligned so
        # no operand shares a cache line or a DRAM stripe boundary with another.
        def align(x: int) -> int:
            return (x + 63) & ~63

        a_off = 0
        b_off = align(a_off + len(a_bytes))
        c_off = align(b_off + len(b_bytes))
        done_off = align(c_off + c_len)
        need = done_off + 8
        if need > self.dma.size:
            raise ValueError(
                f"the DMA window holds {self.dma.size} bytes; this job needs {need}"
            )

        if self.dma.base < 0 or self.dma.base + need > (1 << 64):
            raise ValueError('DMA pointer range exceeds u64')
        self.dma.write(a_off, a_bytes)
        self.dma.write(b_off, b_bytes)
        self.dma.write(c_off, b"\x00" * c_len)
        self.dma.write(done_off, b"\x00" * 8)

        base = self.dma.base
        # AI-3: the region must admit every pointer the descriptor names.
        self.program_region(0, base, base + need)
        desc = pack_gemm_desc(
            m,
            n,
            k,
            ptr_a=base + a_off,
            ptr_b=base + b_off,
            ptr_c=base + c_off,
            ptr_done=base + done_off,
            flags=numfmt_flags(numfmt), lda=lda, ldb=ldb,
        )
        issued = self.submit(desc)
        status = self.wait()
        if status != ST_OK:
            return bytes(c_len), issued, status
        raw = self.dma.read(c_off, c_len)
        if len(raw) != c_len:
            raise ValueError('short C32 DMA read')
        return raw, issued, ST_OK

    def as_caps_dict(self) -> Dict[str, Any]:
        d = self.caps.as_dict()
        d["mode"] = "uio"
        return d

    def close(self) -> None:
        """Disable the island so a later run starts from a known state."""
        try:
            self.window.write32(MMIO_CTL, 0)
        except OSError:
            pass


# --- real Linux primitives ---------------------------------------------------


class _MmapWindow:
    """``MmioWindow`` over an ``mmap`` of a UIO map."""

    def __init__(self, path: str, length: int = ISLAND_WINDOW_BYTES, offset: int = 0):
        import mmap

        self._fd = os.open(path, os.O_RDWR | getattr(os, "O_SYNC", 0))
        self._map = mmap.mmap(self._fd, length, offset=offset)

    def read32(self, offset: int) -> int:
        return struct.unpack_from("<I", self._map, offset)[0]

    def write32(self, offset: int, value: int) -> None:
        struct.pack_into("<I", self._map, offset, value & 0xFFFFFFFF)

    def close(self) -> None:
        self._map.close()
        os.close(self._fd)


class _MmapDma:
    """``DmaMemory`` over an ``mmap`` of a guest-physical window."""

    def __init__(self, path: str, base: int, size: int):
        import mmap

        self._base = base
        self._size = size
        self._fd = os.open(path, os.O_RDWR | getattr(os, "O_SYNC", 0))
        self._map = mmap.mmap(self._fd, size, offset=base)

    @property
    def base(self) -> int:
        return self._base

    @property
    def size(self) -> int:
        return self._size

    def read(self, offset: int, length: int) -> bytes:
        return bytes(self._map[offset : offset + length])

    def write(self, offset: int, data: bytes) -> None:
        self._map[offset : offset + len(data)] = data

    def close(self) -> None:
        self._map.close()
        os.close(self._fd)


class _UioIrq:
    """``IrqSource`` over a UIO character device."""

    def __init__(self, path: str):
        self._fd = os.open(path, os.O_RDWR)

    def enable(self) -> None:
        os.write(self._fd, struct.pack("<I", 1))

    def wait(self, timeout: Optional[float] = None) -> bool:
        import select

        r, _, _ = select.select([self._fd], [], [], timeout)
        if not r:
            return False
        os.read(self._fd, 4)
        return True

    def close(self) -> None:
        os.close(self._fd)


def open_from_env(*, timeout: float = 5.0) -> QemuUioSession:
    """Open a session from ``AI_TENSOR_*`` environment variables.

    ``AI_TENSOR_UIO``      UIO device path (default ``/dev/uio0``)
    ``AI_TENSOR_DMA_BASE`` guest-physical base of the operand window (required)
    ``AI_TENSOR_DMA_SIZE`` its size in bytes (default 1 MiB)
    ``AI_TENSOR_DMA_DEV``  backing file for the window (default ``/dev/mem``)

    The DMA base is required rather than defaulted: the island reads and writes those
    addresses, so an invented base would corrupt whatever actually lives there.
    """
    uio = os.environ.get("AI_TENSOR_UIO", "/dev/uio0")
    if uio.startswith("virt://"):
        raise ValueError(
            "AI_TENSOR_UIO names a virtual card ('virt://...'); use backend='virt-card'"
        )
    dma_base = os.environ.get("AI_TENSOR_DMA_BASE", "").strip()
    if not dma_base:
        raise RuntimeError(
            "AI_TENSOR_DMA_BASE is required for the qemu-uio backend: the island DMAs "
            "A/B/C, so the operand window must be a guest-physical range it can reach "
            "(a reserved-memory node, or a range excluded from the kernel's map)"
        )
    base = int(dma_base, 0)
    size = int(os.environ.get("AI_TENSOR_DMA_SIZE", str(1 << 20)), 0)
    dma_dev = os.environ.get("AI_TENSOR_DMA_DEV", "/dev/mem")

    window = _MmapWindow(uio)
    dma = _MmapDma(dma_dev, base, size)
    irq: Optional[IrqSource] = None
    try:
        irq = _UioIrq(uio)
    except OSError:
        irq = None
    return QemuUioSession(window, dma, irq, timeout=timeout)
