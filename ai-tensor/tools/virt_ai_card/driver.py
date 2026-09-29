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
REG_REUSE_EPOCH = 0x0F00
# Requested level in bits [3:0]. Applied nibble stays 0. Inside the 4 KiB
# window, kept in side state so a raw pack cannot set the applied nibble.
REG_VA_TURBO_LEVEL = 0x0F04
PMU_VA_TURBO_LEVEL = 0x0F08
REG_VA_TURBO_RECIPE = 0x0F0C
PMU_VA_TURBO_RECIPE = 0x0F10
REG_VA_TURBO_WINDOW = 0x0F14
PMU_VA_TURBO_WINDOW = 0x0F18
FLAG_REUSE_B = 1 << 15
FLAG_REUSE_A = 1 << 23
DESC_END = 0x180
PMU = 0x180
DESC_BYTES = DESC_END - DESC

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

CONTRACT_VERSION = 2
OP_GEMM = 1
ST_OK = 0
ST_ERR = 1
ST_DISABLED = 6
ST_BAD_FMT = 8
ST_BAD_VER = 2
ST_BAD_OP = 3


def completion_post(ticket: int, gemm_status: int, bus_err: bool = False):
    """Same split as ai_tensor.c_abi.completion_post.

    The DMA word keeps the GEMM status. A failed completion beat reports ST_ERR
    on the FIFO and does not rewrite that word.
    """
    word = ((int(gemm_status) & 0xFFFF) << 32) | (int(ticket) & 0xFFFFFFFF)
    fifo = ST_ERR if bus_err else int(gemm_status) & 0xFFFF
    return word, fifo
# isa-encoding.md §7: flags[2] raise IRQ. Matches ingested flags_layout.irq_bit.
FLAG_IRQ = 1 << 2

# Soft path URI used by board.json ai.uioConnectors.island0
DEFAULT_SOFT_PATH = "virt://virt-ai-pcie/island0"
DEFAULT_EVENTFD_PATH = "virt://virt-ai-pcie/island0_irq"


def _log2_tile_pack(m: int = 1024, n: int = 512, k: int = 512) -> int:
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
                acc = (acc + av * bv) & 0xffffffff
            row.append(acc - (1 << 32) if acc & (1 << 31) else acc)
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


class _ReuseDisabled:
    """Stand-in when ``ai_tensor.policy`` is not on the import path.

    Flags are ignored and every operand is read from the staged matrix.
    """

    def __init__(self) -> None:
        self.epoch = 0
        self.last_read_a = True
        self.last_read_b = True

    def set_enabled(self, on: bool) -> None:
        del on

    def bind(self, side: str, flag: bool, key: tuple, data, disjoint: bool = True):
        del side, flag, key, disjoint
        return True, data

    def finish(self, ok: bool) -> None:
        del ok


def _new_reuse():
    try:
        from ai_tensor.policy import OperandReuse
    except ImportError:
        return _ReuseDisabled()
    return OperandReuse()


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
        cap: Optional[dict] = None,
    ) -> None:
        self.path = path
        self.eventfd = eventfd
        self._lock = threading.RLock()
        self._mem = bytearray(MMIO_SIZE)
        # private "DRAM" for BAR4-style tensors (not in 4K window)
        self._dram: dict[str, List[List[int]]] = {}
        self._enable = False
        # Null ptr_done (ABI): no DMA completion-word write until the host sets CTL.wr_cpl_en.
        self._wr_cpl_en = False
        self._irq_bit = 2
        self._queues = 1
        self._busy = False
        self._last_status = 0
        self._last_completion_word = 0
        self._completion_bus_err = False
        self._db_qid = 0
        self._db_ticket = 0
        self._desc_words = [0] * 16
        self._pmu = (0, 0, 0, 0)  # r, w, cycles, gbps_x1000
        self._comp_fifo: List[_Completion] = []
        self._reuse = _new_reuse()
        self._level_req = 0
        self._pmu_level = 0
        self._recipe_req = 0
        self._pmu_recipe = 0
        self._window_valid = False
        self._pmu_window = False
        self._seed_cap(cap)
        self._refresh_done_head()

    def set_reuse_en(self, on: bool) -> None:
        """Exact operand reuse. Off by default, so flags 15 and 23 do not change C."""
        self._reuse.set_enabled(on)

    def reuse_enabled(self) -> bool:
        """Whether exact reuse is enabled. A plan with no skip leaves it off."""
        return bool(self._reuse.enabled)

    def last_read_a(self) -> bool:
        """True when the last GEMM read A. A hit leaves this false."""
        return bool(self._reuse.last_read_a)

    def last_read_b(self) -> bool:
        """True when the last GEMM read B. A hit leaves this false."""
        return bool(self._reuse.last_read_b)

    # -- CAP seed (island_p3-ish; overrides are reported geometry, not timing) --

    def _seed_cap(self, cap: Optional[dict] = None) -> None:
        cap = cap or {}
        if cap.get("irq_bit") is not None:
            self._irq_bit = int(cap["irq_bit"]) & 31
        words = [0] * 11
        words[CAP_VERSION] = int(cap.get("version", 1))
        words[CAP_CLUSTERS] = int(cap.get("clusters", 1))
        words[CAP_MACS] = int(cap.get("macs_per_cycle", cap.get("macs", 512)))
        words[CAP_CLOCK_KHZ] = int(cap.get("clock_khz", 1_000_000))
        words[CAP_SRAM] = int(cap.get("sram_bytes", 8 * 1024 * 1024))
        words[CAP_ACC_TILE] = _log2_tile_pack(
            int(cap.get("acc_tile_m", 1024)),
            int(cap.get("acc_tile_n", 512)),
            int(cap.get("acc_tile_k", 512)),
        )
        words[CAP_DRAM] = int(cap.get("dram_gbps", 400))
        queues = int(cap.get("queues", 1)) & 0xFFFF
        depth = int(cap.get("queue_depth", 8)) & 0xFFFF
        self._queues = queues if queues else 1
        words[CAP_QUEUES] = queues | (depth << 16)
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
        bus_err = self._completion_bus_err
        self._completion_bus_err = False
        word, fifo = completion_post(ticket, status, bus_err)
        self._last_completion_word = word
        self._comp_fifo.append(
            _Completion(ticket=ticket, status=fifo, irq=irq, c_matrix=c_matrix)
        )
        # keep depth modest
        while len(self._comp_fifo) > 8:
            self._comp_fifo.pop(0)
        self._busy = False
        self._last_status = fifo
        self._pack32(STATUS, (fifo << 16) | 0)
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
            if off == REG_REUSE_EPOCH:
                return self._reuse.epoch & 0xFFFFFFFF
            if off == REG_VA_TURBO_LEVEL:
                return self._level_req & 0xF
            if off == PMU_VA_TURBO_LEVEL:
                return self._pmu_level & 0xF
            if off == REG_VA_TURBO_RECIPE:
                return self._recipe_req & 0x1F
            if off == PMU_VA_TURBO_RECIPE:
                return self._pmu_recipe & 0x1F
            if off == REG_VA_TURBO_WINDOW:
                return 1 if self._window_valid else 0
            if off == PMU_VA_TURBO_WINDOW:
                return 1 if self._pmu_window else 0
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
            if off == REG_REUSE_EPOCH:
                self._reuse.epoch = val & 0xFFFFFFFF
                self._window_valid = False
                return
            if off == REG_VA_TURBO_LEVEL:
                self._level_req = val & 0xF
                self._window_valid = False
                return
            if off == REG_VA_TURBO_RECIPE:
                self._recipe_req = val & 0x1F
                self._window_valid = False
                return
            if off == REG_VA_TURBO_WINDOW:
                self._window_valid = (val & 1) != 0
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
        if self._db_qid >= self._queues:
            self._push_completion(self._db_ticket, ST_ERR, False)
            return
        if any(self._desc_words):
            ver = self._desc_words[0] & 0xFFFF
            if ver != CONTRACT_VERSION:
                self._push_completion(self._db_ticket, ST_BAD_VER, False)
                return
            op = (self._desc_words[0] >> 16) & 0xFFFF
            if op not in (0, OP_GEMM):
                self._push_completion(self._db_ticket, ST_BAD_OP, False)
                return
        if self._desc_words[1] & ((7 << 20) | (3 << 8) | (3 << 10) | (3 << 12) | (1 << 14)):
            self._push_completion(self._db_ticket, ST_BAD_FMT, False)
            return
        # High-level path: if A/B stored via gemm_s8 API, use those; else try DESC dims
        a = self._dram.get("A")
        b = self._dram.get("B")
        irq = False
        m = n = k = 0
        if a is not None and b is not None:
            m, k = len(a), len(a[0])
            n = len(b[0]) if b else 0
            if any(self._desc_words):
                m_d, n_d, k_d = self._desc_words[2], self._desc_words[3], self._desc_words[4]
                if (m_d or n_d or k_d) and (m_d, n_d, k_d) != (m, n, k):
                    self._push_completion(self._db_ticket, ST_ERR, False)
                    return
                ld_ab = self._desc_words[5]
                if ld_ab:
                    lda = ld_ab & 0xFFFF
                    ldb = (ld_ab >> 16) & 0xFFFF
                    if (lda, ldb) != (k, k):
                        self._push_completion(self._db_ticket, ST_ERR, False)
                        return
            # FLAG_IRQ from desc flags word if programmed, else default on for soft path
            flag = 1 << self._irq_bit
            flags = self._desc_words[1] if any(self._desc_words) else flag
            irq = (flags & flag) != 0
            # Soft path with eventfd: ensure IRQ so claim discipline is exercised.
            if self.eventfd is not None:
                irq = True
            fmt = (flags >> 20) & 7
            read_a, a_used = self._reuse.bind(
                "a", flags & FLAG_REUSE_A, (1, m, k, k, fmt), a, True
            )
            read_b, b_used = self._reuse.bind(
                "b", flags & FLAG_REUSE_B, (2, n, k, k, fmt), b, True
            )
            try:
                c = int8_gemm(a_used, b_used)
            except Exception:
                self._reuse.finish(False)
                self._push_completion(self._db_ticket, ST_ERR, False)
                return
            self._reuse.finish(True)
            self._pmu_level = self._level_req & 0xF
            self._pmu_recipe = self._recipe_req & 0x1F
            self._pmu_window = self._window_valid
            self._dram["C"] = c
            read_elems = (0 if not read_a else m * k) + (0 if not read_b else k * n)
            self._pmu = (read_elems, m * n, max(m * n, 1), 0)
            self._push_completion(self._db_ticket, ST_OK, irq, c)
            return
        # DESC-only path without staged A/B: complete OK empty (tests without matrices)
        self._push_completion(self._db_ticket, ST_OK, bool(self.eventfd), None)

    # -- high-level GEMM (card agent / smoke) -------------------------------

    def fail_next_completion_bus(self) -> None:
        """The next completion beat fails after the GEMM word is stored."""
        with self._lock:
            self._completion_bus_err = True

    def stage_tensor(self, name: str, matrix: Sequence[Sequence[int]]) -> None:
        """Stage a BAR4 tensor into card DRAM so a later doorbell can consume it."""
        with self._lock:
            self._dram[str(name)] = [list(row) for row in matrix]

    def get_tensor(self, name: str) -> Optional[List[List[int]]]:
        with self._lock:
            t = self._dram.get(str(name))
            if t is None:
                return None
            return [list(row) for row in t]

    def enable(self, on: bool = True) -> None:
        with self._lock:
            self._enable = on
            self._pack32(CTL, (1 if on else 0) | ((1 if self._wr_cpl_en else 0) << 1))

    def load_desc(self, image: bytes) -> None:
        """Copy a packed descriptor image into the existing DESC window (0x140)."""
        with self._lock:
            self._load_desc_unlocked(image)

    def _load_desc_unlocked(self, image: bytes) -> None:
        buf = bytes(image[:DESC_BYTES]).ljust(DESC_BYTES, b"\x00")
        nwords = DESC_BYTES // 4
        words = [0] * nwords
        for i in range(nwords):
            words[i] = int.from_bytes(buf[i * 4 : (i + 1) * 4], "little")
        self._desc_words = words
        for i, w in enumerate(words):
            self._pack32(DESC + i * 4, w)

    def stage_gemm_s8(
        self,
        a: Sequence[Sequence[int]],
        b: Sequence[Sequence[int]],
        *,
        ticket: int = 1,
        irq: bool = True,
        desc: Optional[bytes] = None,
        flags: int = 0,
    ) -> int:
        """Stage A/B, program DESC (packed image or minimal words), ring doorbell."""
        with self._lock:
            self._dram["A"] = [list(row) for row in a]
            self._dram["B"] = [list(row) for row in b]
            m, k = len(a), len(a[0])
            n = len(b[0])
            if desc:
                self._load_desc_unlocked(bytes(desc))
            if desc:
                m_d, n_d, k_d = self._desc_words[2], self._desc_words[3], self._desc_words[4]
                if (m_d or n_d or k_d) and (m_d, n_d, k_d) != (m, n, k):
                    self._push_completion(ticket, ST_ERR, self.eventfd is not None)
                    return ticket
                ld_ab = self._desc_words[5]
                if ld_ab:
                    lda = ld_ab & 0xFFFF
                    ldb = (ld_ab >> 16) & 0xFFFF
                    if (lda, ldb) != (k, k):
                        self._push_completion(ticket, ST_ERR, self.eventfd is not None)
                        return ticket
            else:
                # minimal desc words: version|op, flags, m, n, k
                self._desc_words = [0] * (DESC_BYTES // 4)
                self._desc_words[0] = CONTRACT_VERSION | (OP_GEMM << 16)
                self._desc_words[1] = (1 << self._irq_bit) if irq else 0
                self._desc_words[2] = m
                self._desc_words[3] = n
                self._desc_words[4] = k
                self._desc_words[5] = k | (k << 16)
                for i, w in enumerate(self._desc_words):
                    self._pack32(DESC + i * 4, w)
            reuse_bits = int(flags) & (FLAG_REUSE_A | FLAG_REUSE_B)
            if reuse_bits:
                self._desc_words[1] = (self._desc_words[1] | reuse_bits) & 0xFFFFFFFF
                self._pack32(DESC + 4, self._desc_words[1])
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
        desc: Optional[bytes] = None,
        flags: int = 0,
    ) -> List[List[int]]:
        """
        Stage + doorbell + (optional) eventfd wait + claim DONE.

        Claim order: wait → claim DONE @0x10C → clear eventfd.
        """
        self.stage_gemm_s8(a, b, ticket=ticket, irq=irq, desc=desc, flags=flags)
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
        elif self.eventfd is not None and not self.done_sticky:
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

        if head.status != ST_OK:
            raise RuntimeError(f'GEMM completion status {head.status}')
        if head.c_matrix is not None:
            return head.c_matrix
        c = self._dram.get("C")
        if c is None:
            raise RuntimeError("wait_claim_result: no C matrix")
        return c

    def cap_version(self) -> int:
        return self.read32(CAP_BASE)

    def cap_snapshot(self) -> dict:
        """Reported CAP window. Values are geometry, not a throughput measurement."""
        q = self.read32(CAP_BASE + CAP_QUEUES * 4)
        return {
            "cap_version": self.read32(CAP_BASE + CAP_VERSION * 4),
            "clusters": self.read32(CAP_BASE + CAP_CLUSTERS * 4),
            "macs_per_cycle": self.read32(CAP_BASE + CAP_MACS * 4),
            "clock_khz": self.read32(CAP_BASE + CAP_CLOCK_KHZ * 4),
            "sram_bytes": self.read32(CAP_BASE + CAP_SRAM * 4),
            "acc_tile_m": 1 << (self.read32(CAP_BASE + CAP_ACC_TILE * 4) & 0xF),
            "acc_tile_n": 1 << ((self.read32(CAP_BASE + CAP_ACC_TILE * 4) >> 4) & 0xF),
            "acc_tile_k": 1 << ((self.read32(CAP_BASE + CAP_ACC_TILE * 4) >> 8) & 0xF),
            "dram_gbps": self.read32(CAP_BASE + CAP_DRAM * 4),
            "queues": q & 0xFFFF,
            "queue_depth": (q >> 16) & 0xFFFF,
        }


def soft_path_for_board(boardid: str = "virt-ai-pcie") -> str:
    return f"virt://{boardid}/island0"
