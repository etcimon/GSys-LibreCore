# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
Virtual UIO + eventfd for hostless AI card CI.

Mirrors SoftIsland MMIO discipline (ai-tensor SoftIsland / island_p3):
  CAP @0x00, CTL @0x100, DOORBELL @0x108, DONE @0x10C, TICKET @0x110,
  DSTATUS @0x114, REG0 @0x120, DESC @0x140, PMU @0x180

Claim order (PLIC-8 / board-uio-eventfd.md):
  1. Wait (eventfd / sticky IRQ)
  2. Claim DONE — write 1 @0x10C (pop completion head)
  3. Clear / rearm eventfd
Never rearm while DONE head still holds an IRQ-flagged completion.
"""

from __future__ import annotations

import struct
import threading
from dataclasses import dataclass, field
from typing import List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# MMIO map (island-relative offsets within 4 KiB window)
# ---------------------------------------------------------------------------

MMIO_SIZE = 0x1000

CAP_BASE = 0x000
CTL = 0x100
STATUS = 0x104
DOORBELL = 0x108
DONE = 0x10C
TICKET = 0x110
DSTATUS = 0x114
DESC_PTR_LO = 0x118
DESC_PTR_HI = 0x11C
REG0 = 0x120
DESC = 0x140
PMU = 0x180

# CAP word indices (×4 = offset)
CAP_VERSION = 0
CAP_CLUSTERS = 1
CAP_MACS = 2
CAP_CLOCK_KHZ = 3
CAP_SRAM = 4
CAP_ACC_TILE = 5
CAP_DRAM = 6
CAP_QUEUES = 7
CAP_DTYPE = 10

CONTRACT_VERSION = 1
OP_GEMM = 1
ST_OK = 0
ST_ERR = 1
ST_DISABLED = 2
ST_BAD_OP = 3
FLAG_IRQ = 1 << 0

# Soft path URI used by board.json ai.uioConnectors.island0
DEFAULT_SOFT_PATH = "virt://virt-ai-pcie/island0"
DEFAULT_EVENTFD_PATH = "virt://virt-ai-pcie/island0_irq"


def _log2_tile_pack(m: int = 256, n: int = 256, k: int = 256) -> int:
    """CAP_ACC_TILE: log2(M)|log2(N)<<4|log2(K)<<8."""
    lm = (m.bit_length() - 1) & 0xF
    ln = (n.bit_length() - 1) & 0xF
    lk = (k.bit_length() - 1) & 0xF
    return lm | (ln << 4) | (lk << 8)


def int8_gemm(
    a: Sequence[Sequence[int]],
    b: Sequence[Sequence[int]],
) -> List[List[int]]:
    """Pure-Python INT8 matmul → int32 C (no numpy required)."""
    m = len(a)
    k = len(a[0]) if m else 0
    n = len(b[0]) if b else 0
    if any(len(row) != k for row in a):
        raise ValueError("A rows must share K")
    if len(b) != k:
        raise ValueError("B must have K rows")
    out: List[List[int]] = []
    for i in range(m):
        row: List[int] = []
        for j in range(n):
            acc = 0
            for t in range(k):
                av = int(a[i][t])
                bv = int(b[t][j])
                # force int8 range for realism
                if av < -128 or av > 127 or bv < -128 or bv > 127:
                    raise ValueError("int8 range required")
                acc += av * bv
            row.append(acc)
        out.append(row)
    return out


@dataclass
class _Completion:
    ticket: int
    status: int
    irq: bool
    c_matrix: Optional[List[List[int]]] = None


class VirtualEventFd:
    """
    eventfd-shaped waiter for hostless CI.

    threading.Event + counter mirrors EventFdWait::soft (ai-tensor-rt irq.rs).
    Claim discipline is owned by the caller / VirtualUioDevice.wait_claim_done:
      wait → claim DONE @0x10C → clear (consume counter) / rearm.
    """

    def __init__(self, path: str = DEFAULT_EVENTFD_PATH) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._event = threading.Event()
        self._counter = 0
        self._enabled = True

    def enable(self) -> None:
        with self._lock:
            self._enabled = True

    def disable(self) -> None:
        with self._lock:
            self._enabled = False

    def signal(self, n: int = 1) -> None:
        if n <= 0:
            return
        with self._lock:
            if not self._enabled:
                return
            self._counter += n
            self._event.set()

    def wait(self, timeout: Optional[float] = None) -> int:
        """Block until counter > 0; return and consume one unit (soft eventfd read)."""
        if not self._event.wait(timeout=timeout):
            raise TimeoutError("VirtualEventFd.wait timed out")
        with self._lock:
            if self._counter <= 0:
                self._event.clear()
                raise TimeoutError("VirtualEventFd: spurious wake")
            self._counter -= 1
            n = 1
            if self._counter == 0:
                self._event.clear()
            return n

    def clear(self) -> None:
        """Drain counter and clear event (rearm after DONE claim)."""
        with self._lock:
            self._counter = 0
            self._event.clear()

    @property
    def pending(self) -> int:
        with self._lock:
            return self._counter


class VirtualUioDevice:
    """
    4 KiB MMIO window + SoftIsland-like GEMM on doorbell.

    Soft-sticky path: ``virt://virt-ai-pcie/island0`` (board primaryUio).
    Optional VirtualEventFd is signalled when a completion with FLAG_IRQ lands
    at the FIFO head (level-style: re-arm when next head.irq after claim).
    """

    def __init__(
        self,
        path: str = DEFAULT_SOFT_PATH,
        *,
        eventfd: Optional[VirtualEventFd] = None,
    ) -> None:
        self.path = path
        self.eventfd = eventfd
        self._lock = threading.RLock()
        self._mem = bytearray(MMIO_SIZE)
        # private "DRAM" for BAR4-style tensors (not in 4K window)
        self._dram: dict[str, List[List[int]]] = {}
        self._enable = False
        self._wr_cpl_en = True
        self._busy = False
        self._last_status = 0
        self._db_qid = 0
        self._db_ticket = 0
        self._desc_words = [0] * 16
        self._pmu = (0, 0, 0, 0)  # r, w, cycles, gbps_x1000
        self._comp_fifo: List[_Completion] = []
        self._seed_cap()
        self._refresh_done_head()

    # -- CAP seed (island_p3-ish) -------------------------------------------

    def _seed_cap(self) -> None:
        words = [0] * 11
        words[CAP_VERSION] = CONTRACT_VERSION
        words[CAP_CLUSTERS] = 1
        words[CAP_MACS] = 256
        words[CAP_CLOCK_KHZ] = 1_000_000
        words[CAP_SRAM] = 8 * 1024 * 1024
        words[CAP_ACC_TILE] = _log2_tile_pack(256, 256, 256)
        words[CAP_DRAM] = 400  # nameplate GB/s low half
        words[CAP_QUEUES] = 1 | (8 << 16)  # queues | depth_depth
        words[CAP_DTYPE] = 0x1  # int8
        for i, w in enumerate(words):
            struct.pack_into("<I", self._mem, i * 4, w)

    def _pack32(self, off: int, val: int) -> None:
        struct.pack_into("<I", self._mem, off, val & 0xFFFFFFFF)

    def _unpack32(self, off: int) -> int:
        return struct.unpack_from("<I", self._mem, off)[0]

    # -- FIFO head → DONE sticky + IRQ --------------------------------------

    def _refresh_done_head(self) -> None:
        if self._comp_fifo:
            head = self._comp_fifo[0]
            self._pack32(DONE, 1)
            self._pack32(TICKET, head.ticket)
            self._pack32(DSTATUS, head.status)
            if head.irq and self.eventfd is not None:
                # level-style: signal once when head becomes IRQ-flagged
                if self.eventfd.pending == 0:
                    self.eventfd.signal(1)
        else:
            self._pack32(DONE, 0)
            self._pack32(TICKET, 0)
            self._pack32(DSTATUS, 0)

    def _push_completion(
        self,
        ticket: int,
        status: int,
        irq: bool,
        c_matrix: Optional[List[List[int]]] = None,
    ) -> None:
        self._comp_fifo.append(
            _Completion(ticket=ticket, status=status, irq=irq, c_matrix=c_matrix)
        )
        # keep depth modest
        while len(self._comp_fifo) > 8:
            self._comp_fifo.pop(0)
        self._busy = False
        self._last_status = status
        self._pack32(STATUS, (status << 16) | 0)
        self._refresh_done_head()

    def claim_done(self) -> Optional[_Completion]:
        """Pop CPL FIFO head (DONE write bit0). Claim before clearing eventfd."""
        with self._lock:
            if not self._comp_fifo:
                return None
            head = self._comp_fifo.pop(0)
            self._refresh_done_head()
            return head

    @property
    def irq_pending(self) -> bool:
        with self._lock:
            return bool(self._comp_fifo and self._comp_fifo[0].irq)

    @property
    def done_sticky(self) -> bool:
        with self._lock:
            return bool(self._comp_fifo)

    # -- MMIO ---------------------------------------------------------------

    def read32(self, off: int) -> int:
        with self._lock:
            if off < 0 or off + 4 > MMIO_SIZE or off % 4 != 0:
                return 0
            if off == CTL:
                return (1 if self._enable else 0) | ((1 if self._wr_cpl_en else 0) << 1)
            if off == STATUS:
                return (self._last_status << 16) | (1 if self._busy else 0)
            if off == DOORBELL:
                return (self._db_ticket << 8) | self._db_qid
            if 0x180 <= off < 0x190:
                idx = (off - 0x180) // 4
                return self._pmu[idx] if idx < 4 else 0
            if 0x140 <= off < 0x180:
                return self._desc_words[(off - 0x140) // 4]
            return self._unpack32(off)

    def write32(self, off: int, val: int) -> None:
        with self._lock:
            val &= 0xFFFFFFFF
            if off == CTL:
                self._enable = (val & 1) != 0
                self._wr_cpl_en = ((val >> 1) & 1) != 0
                self._pack32(CTL, val)
                return
            if off == DOORBELL:
                self._doorbell(val)
                return
            if off == DONE:
                if val & 1:
                    self.claim_done()
                return
            if 0x140 <= off < 0x180:
                self._desc_words[(off - 0x140) // 4] = val
                self._pack32(off, val)
                return
            if 0 <= off < MMIO_SIZE and off % 4 == 0:
                self._pack32(off, val)

    def _doorbell(self, val: int) -> None:
        self._db_qid = val & 0xFF
        self._db_ticket = (val >> 8) & 0x007F_FFFF
        self._busy = True
        self._pack32(STATUS, 1)
        if not self._enable:
            self._push_completion(self._db_ticket, ST_DISABLED, False)
            return
        # High-level path: if A/B stored via gemm_s8 API, use those; else try DESC dims
        a = self._dram.get("A")
        b = self._dram.get("B")
        irq = False
        m = n = k = 0
        if a is not None and b is not None:
            m, k = len(a), len(a[0])
            n = len(b[0]) if b else 0
            # FLAG_IRQ from desc flags word if programmed, else default on for soft path
            flags = self._desc_words[1] if any(self._desc_words) else FLAG_IRQ
            irq = (flags & FLAG_IRQ) != 0
            # Soft path with eventfd: ensure IRQ so claim discipline is exercised.
            if self.eventfd is not None:
                irq = True
            try:
                c = int8_gemm(a, b)
                self._dram["C"] = c
                self._pmu = (m * k + k * n, m * n, max(m * n, 1), 0)
                self._push_completion(self._db_ticket, ST_OK, irq, c)
            except Exception:
                self._push_completion(self._db_ticket, ST_ERR, False)
            return
        # DESC-only path without staged A/B: complete OK empty (tests without matrices)
        self._push_completion(self._db_ticket, ST_OK, bool(self.eventfd), None)

    # -- high-level GEMM (card agent / smoke) -------------------------------

    def enable(self, on: bool = True) -> None:
        with self._lock:
            self._enable = on
            self._pack32(CTL, (1 if on else 0) | ((1 if self._wr_cpl_en else 0) << 1))

    def stage_gemm_s8(
        self,
        a: Sequence[Sequence[int]],
        b: Sequence[Sequence[int]],
        *,
        ticket: int = 1,
        irq: bool = True,
    ) -> int:
        """Stage A/B, program minimal DESC, ring doorbell. Returns ticket."""
        with self._lock:
            self._dram["A"] = [list(row) for row in a]
            self._dram["B"] = [list(row) for row in b]
            m, k = len(a), len(a[0])
            n = len(b[0])
            # minimal desc words: version|op, flags, m, n, k
            self._desc_words = [0] * 16
            self._desc_words[0] = CONTRACT_VERSION | (OP_GEMM << 16)
            self._desc_words[1] = FLAG_IRQ if irq else 0
            self._desc_words[2] = m
            self._desc_words[3] = n
            self._desc_words[4] = k
            if not self._enable:
                self.enable(True)
            # doorbell: qid=0 | ticket<<8
            self._doorbell((ticket << 8) | 0)
            return ticket

    def gemm_s8(
        self,
        a: Sequence[Sequence[int]],
        b: Sequence[Sequence[int]],
        *,
        ticket: int = 1,
        irq: bool = True,
        wait: bool = True,
        timeout: float = 2.0,
    ) -> List[List[int]]:
        """
        Stage + doorbell + (optional) eventfd wait + claim DONE.

        Claim order: wait → claim DONE @0x10C → clear eventfd.
        """
        self.stage_gemm_s8(a, b, ticket=ticket, irq=irq)
        if wait:
            return self.wait_claim_result(ticket=ticket, timeout=timeout)
        c = self._dram.get("C")
        if c is None:
            raise RuntimeError("gemm_s8: no result")
        return c

    def wait_claim_result(
        self,
        ticket: Optional[int] = None,
        timeout: float = 2.0,
    ) -> List[List[int]]:
        """PLIC-8 claim discipline: wait IRQ → claim DONE → clear/rearm."""
        if self.eventfd is not None and self.irq_pending:
            # Wait for signal (may already be pending)
            try:
                self.eventfd.wait(timeout=timeout)
            except TimeoutError:
                if not self.done_sticky:
                    raise
        elif self.eventfd is not None:
            self.eventfd.wait(timeout=timeout)

        # Claim DONE before clearing IRQ (document + implement)
        head = self.claim_done()
        if head is None:
            raise TimeoutError("wait_claim_result: no DONE head")
        if ticket is not None and head.ticket != ticket:
            # put back? for multi-ticket caller should poll; keep strict for smoke
            raise RuntimeError(
                f"ticket mismatch: head={head.ticket} expected={ticket}"
            )
        if self.eventfd is not None:
            # clear consumed unit; rearm level if next head.irq
            # (claim_done already refreshed head and may re-signal)
            if not self.irq_pending:
                self.eventfd.clear()
            else:
                # leave pending or re-signal for next waiter
                if self.eventfd.pending == 0:
                    self.eventfd.signal(1)

        if head.c_matrix is not None:
            return head.c_matrix
        c = self._dram.get("C")
        if c is None:
            raise RuntimeError("wait_claim_result: no C matrix")
        return c

    def cap_version(self) -> int:
        return self.read32(CAP_BASE)


def soft_path_for_board(boardid: str = "virt-ai-pcie") -> str:
    return f"virt://{boardid}/island0"
