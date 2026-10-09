#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""3d-b stage-1 self-test: python client for the RTL bridge server
(bridge_main.cpp + tb_g6lc_apu_bridge.sv).  Speaks the same
length-prefixed unix-socket protocol the QEMU g6lc_apu_bridge device
will: MMIO_RD/MMIO_WR into the guest window, DMA_RD/DMA_WR served from
a sparse python "guest DRAM", IRQ frames level-tracked.

Reproduces software/apu-venus-probe/venus_probe.c exactly: the stock
virtio-mmio/virtio-gpu probe, split-virtqueue descriptor/avail/doorbell/
used/ISR flow, then the vn_golden tapes ue_sm5_transport and
ue_cpos_bufcopy_1 with their .exp records.  The internal checkpoints the
C probe pushed through the DRAM mailbox (EK_FENCE/LIVE/PAGES/EXTRA and
the CK_HEAD/CK_STATUS hierarchy fallbacks) are answered here through
the bridge debug overlay (offsets >= VN_DBG_BASE, served by
bridge_main.cpp from the fixture's observability taps).

VenusOff arm: connect to the -GVenusOff=1 binary and mirror the
sys-venus TB's arm_venusoff — transport-only probe, doorbell, no DMA,
no IRQ.
"""
import argparse
import re
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
VNVEC = ROOT / "verif/tb/apu/vn_vectors"

T_MMIO_RD, T_MMIO_WR = 0x01, 0x02
T_MMIO_RD_R, T_MMIO_WR_R = 0x81, 0x82
T_DMA_RD, T_DMA_WR, T_IRQ = 0x11, 0x12, 0x13
T_DMA_RD_R, T_DMA_WR_R = 0x91, 0x92

VF_NEXT, VF_WRITE = 1, 2

# ---------------------------------------------------------------- map


def load_map(path):
    m = {}
    for line in Path(path).read_text().splitlines():
        g = re.match(r"#define (\w+) 0x([0-9A-Fa-f]+)ULL", line.strip())
        if g:
            m[g.group(1)] = int(g.group(2), 16)
    return m


VN = {}  # filled in main()


# ------------------------------------------------------- guest memory


class Mem:
    """Sparse paged guest DRAM, absolute addresses."""

    PAGE = 1 << 16

    def __init__(self):
        self.p = {}

    def _pg(self, a):
        k = a // self.PAGE
        pg = self.p.get(k)
        if pg is None:
            pg = self.p[k] = bytearray(self.PAGE)
        return pg, a % self.PAGE

    def w(self, a, bs):
        for i, b in enumerate(bs):
            pg, o = self._pg(a + i)
            pg[o] = b

    def r(self, a, n):
        out = bytearray()
        for i in range(n):
            pg, o = self._pg(a + i)
            out.append(pg[o])
        return bytes(out)

    def w32(self, a, v):
        self.w(a, struct.pack("<I", v & 0xFFFFFFFF))

    def w16(self, a, v):
        self.w(a, struct.pack("<H", v & 0xFFFF))

    def r32(self, a):
        return struct.unpack("<I", self.r(a, 4))[0]

    def r16(self, a):
        return struct.unpack("<H", self.r(a, 2))[0]


# ------------------------------------------------------------- client


class Fail(Exception):
    pass


class Client:
    def __init__(self, mem):
        self.s = None
        self.rx = bytearray()
        self.seq = 0
        self.mem = mem
        self.pending = {}          # seq -> reply payload (MMIO)
        self.irq_level = 0
        self.irq_edges = 0
        self.n_dma_rd = 0
        self.n_dma_wr = 0
        self.dma_bytes = 0

    def connect(self, path, tmo=60.0):
        t0 = time.time()
        while True:
            try:
                self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.s.connect(path)
                self.s.setblocking(False)
                return
            except OSError:
                if time.time() - t0 > tmo:
                    raise
                time.sleep(0.05)

    def send(self, typ, seq, pl):
        f = struct.pack("<IBBH", 4 + len(pl), typ, 0, seq) + pl
        self.s.sendall(f)

    # -- incoming request frames from the RTL server -------------------
    def _on_frame(self, typ, seq, pl):
        if typ == T_DMA_RD:
            addr, ln = struct.unpack("<QI", pl[:12])
            data = self.mem.r(addr, ln)
            self.send(T_DMA_RD_R, seq, b"\x00" + data)
            self.n_dma_rd += 1
            self.dma_bytes += ln
        elif typ == T_DMA_WR:
            addr, ln = struct.unpack("<QI", pl[:12])
            data = pl[12:12 + ln]
            strb = pl[12 + ln:12 + ln + (ln + 7) // 8]
            for i in range(ln):
                if strb[i >> 3] & (1 << (i & 7)):
                    self.mem.w(addr + i, data[i:i + 1])
            self.send(T_DMA_WR_R, seq, b"\x00")
            self.n_dma_wr += 1
            self.dma_bytes += ln
        elif typ == T_IRQ:
            lv = pl[0]
            if lv != self.irq_level:
                self.irq_level = lv
                if lv:
                    self.irq_edges += 1
        elif typ in (T_MMIO_RD_R, T_MMIO_WR_R):
            self.pending[seq] = (typ, pl)
        else:
            raise Fail(f"unknown frame type {typ:#x}")

    def pump(self, dur=0.0):
        """Service the socket for dur seconds (at least one recv try)."""
        deadline = time.time() + dur
        while True:
            try:
                b = self.s.recv(1 << 20)
                if not b:
                    raise Fail("server closed socket")
                self.rx += b
            except BlockingIOError:
                pass
            while len(self.rx) >= 4:
                ln = struct.unpack("<I", self.rx[:4])[0]
                if len(self.rx) < 4 + ln:
                    break
                fr = bytes(self.rx[4:4 + ln])
                del self.rx[:4 + ln]
                self._on_frame(fr[0], struct.unpack("<H", fr[2:4])[0],
                               fr[4:])
            if time.time() >= deadline:
                return
            time.sleep(0.0002)

    # -- MMIO into the guest window ------------------------------------
    def mmio_rd(self, off):
        self.seq = (self.seq + 1) & 0xFFFF or 1
        sq = self.seq
        self.send(T_MMIO_RD, sq, struct.pack("<I", off))
        while sq not in self.pending:
            self.pump(0.5)
        typ, pl = self.pending.pop(sq)
        assert typ == T_MMIO_RD_R
        data, err = struct.unpack("<IB", pl[:5])
        if err:
            raise Fail(f"MMIO_RD @{off:#x} err")
        return data

    def mmio_wr(self, off, data, strb=0xF):
        self.seq = (self.seq + 1) & 0xFFFF or 1
        sq = self.seq
        self.send(T_MMIO_WR, sq, struct.pack("<IIB", off, data, strb))
        while sq not in self.pending:
            self.pump(0.5)
        typ, pl = self.pending.pop(sq)
        assert typ == T_MMIO_WR_R
        if pl[0]:
            raise Fail(f"MMIO_WR @{off:#x} err")

    # -- debug overlay ---------------------------------------------------
    def dbg(self, sel):
        base = VN["VN_DBG_BASE"] + sel * 8
        lo = self.mmio_rd(base)
        hi = self.mmio_rd(base + 4)
        return lo | (hi << 32)


# ------------------------------------------------------------- player


class Player:
    def __init__(self, cl, name):
        self.cl = cl
        self.mem = cl.mem
        self.name = name
        self.checks = 0
        self.cases = 0
        self.tape = self._words(VNVEC / f"{name}.hex")
        self.exp = self._words(VNVEC / f"{name}.exp")
        self.tp = 0
        self.ep = 0
        self.head_ap, self.status_ap = self._ring_map()
        # queue pointers persist across sessions (the C probe's globals):
        # the device-side walk pointer is monotonic
        if not hasattr(cl, "vq"):
            cl.vq = {"av_push": [0, 0], "dcur": [0, 0], "uexp": [0, 0]}
        self.av_push = cl.vq["av_push"]
        self.dcur = cl.vq["dcur"]
        self.uexp = cl.vq["uexp"]
        self.pend = None

    @staticmethod
    def _words(path):
        out = []
        for tok in path.read_text().split():
            tok = tok.strip()
            if tok and not tok.startswith("//"):
                out.append(int(tok, 16))
        return out

    def _ring_map(self):
        head, status = {}, {}
        i = 0
        t = self.tape
        while i < len(t):
            op = t[i]; i += 1
            if op == 0:
                break
            if op in (1, 3):
                i += 2 + t[i]
            elif op == 2:
                i += 4 * t[i] + 5
            elif op == 4:
                head[t[i]] = t[i + 1]; i += 4
            elif op == 5:
                status[t[i]] = t[i + 1]; i += 5
            elif op == 6:
                i += 3
            elif op == 7:
                i += 1
            else:
                raise Fail(f"bad tape op {op} @ {i}")
        for s, ad in status.items():
            head.setdefault(s, ad - 128)
        for s, ad in head.items():
            status.setdefault(s, ad + 128)
        return head, status

    def check(self, cond, msg):
        self.checks += 1
        if not cond:
            raise Fail(f"{self.name}: {msg}")

    # guest-window helpers (tape addresses are window-relative offsets)
    def g32(self, off):
        return self.mem.r32(VN["VN_DMA_BASE"] + off)

    def g16(self, off):
        return self.mem.r16(VN["VN_DMA_BASE"] + off)

    def ap32(self, off):
        return self.mem.r32(VN["VN_SHM_BASE"] + off)

    # -- tape stream ----------------------------------------------------
    def ntap(self):
        v = self.tape[self.tp]
        self.tp += 1
        return v

    def nexp(self):
        v = self.exp[self.ep]
        self.ep += 1
        return v

    def rec_kind(self):
        if self.ep + 1 >= len(self.exp):
            return 0
        if self.exp[self.ep] == 0xFFFFFFFF and self.exp[self.ep + 1] == \
                0xFFFFFFFF:
            return 0
        return self.exp[self.ep]

    # -- virtqueues ------------------------------------------------------
    def put_desc(self, q, idx, addr, ln, flags, nxt):
        base = VN["VN_Q0_DESC"] if q == 0 else VN["VN_Q1_DESC"]
        # split-vq descriptor: u64 addr, u32 len, u16 flags, u16 next
        self.mem.w(base + 16 * idx, struct.pack("<QIHH", addr, ln,
                                                flags, nxt))

    def push_avail(self, q, head):
        base = VN["VN_Q0_AVAIL"] if q == 0 else VN["VN_Q1_AVAIL"]
        num = VN["VN_Q0_NUM"] if q == 0 else VN["VN_Q1_NUM"]
        self.mem.w16(base + 4 + 2 * (self.av_push[q] % num), head)
        self.mem.w16(base + 2, (self.av_push[q] + 1) & 0xFFFF)
        self.av_push[q] += 1

    # -- chain submit/expect ---------------------------------------------
    def chain_submit(self):
        nd = self.ntap()
        head = self.dcur[0]
        raddr = None
        for i in range(nd):
            a0, a1, dl, dw = (self.ntap() for _ in range(4))
            a = (a1 << 32) | a0
            self.put_desc(0, (self.dcur[0] + i) % VN["VN_Q0_NUM"],
                          VN["VN_DMA_BASE"] + a, dl,
                          (VF_WRITE if dw else 0) |
                          (VF_NEXT if i + 1 < nd else 0),
                          (self.dcur[0] + i + 1) % VN["VN_Q0_NUM"])
            if dw:
                raddr = a
        self.dcur[0] = (self.dcur[0] + nd) % VN["VN_Q0_NUM"]
        flags = self.ntap()
        fence = self.ntap() | (self.ntap() << 32)
        self.ntap()                          # cx
        ridx = self.ntap()
        self.pend = (head, flags, fence, raddr, ridx)
        self.push_avail(0, head)
        self.cl.mmio_wr(VN["VREG_QUEUE_NOTIFY"], 0)

    def wait_used(self):
        u = VN["VN_Q0_USED"]
        want = (self.uexp[0] + 1) & 0xFFFF
        t0 = time.time()
        while self.mem.r16(u + 2) != want:
            self.cl.pump(0.01)
            if time.time() - t0 > 600:
                raise Fail(f"{self.name}: used.idx timeout (want {want})")
        pos = self.uexp[0] % VN["VN_Q0_NUM"]
        return (self.mem.r32(u + 8 + 8 * pos), self.mem.r32(u + 4 + 8 * pos))

    def chain_expect(self):
        head, flags, fence, raddr, ridx = self.pend
        ulen, uid = self.wait_used()
        # The used.idx write lands in guest memory one publication state
        # (a few DUT cycles) before the used_valid handshake latches
        # irq_status_q; a host-side memory poll can sample INTERRUPT_STATUS
        # inside that window at low sim rates.  Wait for the level —
        # the check still proves the IRQ follows the publication.
        t0 = time.time()
        while True:
            st = self.cl.mmio_rd(VN["VREG_INTERRUPT_STATUS"])
            if st & 1:
                break
            self.cl.pump(0.01)
            if time.time() - t0 > 60:
                raise Fail(f"{self.name}: INTERRUPT_STATUS bit0 "
                           f"(never set after used publish)")
        self.cl.pump(0.01)   # drain the pending T_IRQ edge frame
        self.check(self.cl.irq_level == 1, "irq line high before ack")
        self.cl.mmio_wr(VN["VREG_INTERRUPT_ACK"], 1)
        self.cl.pump(0.02)
        self.check(self.cl.irq_level == 0, "irq line low after ack")
        # EK_RESP {kind, used_len, resp_type, nbody, 0,0,0,0}
        self.check(self.rec_kind() == 1, "EK_RESP kind")
        self.ep += 1
        e_used, e_type, e_nbody = (self.nexp() for _ in range(3))
        self.ep += 4
        self.check(ulen == e_used, f"used_len {ulen:#x} != {e_used:#x}")
        self.check(uid == head, f"used id {uid} != head {head}")
        self.uexp[0] += 1
        if raddr is not None:
            self.check(self.g32(raddr) == e_type,
                       f"resp type {self.g32(raddr):#x} != {e_type:#x}")
            for i in range(e_nbody):
                self.check(self.rec_kind() == 2, "EK_BODY kind")
                self.ep += 1
                self.check(self.g32(raddr + 24 + 4 * i) == self.exp[self.ep],
                           f"resp body[{i}]")
                self.ep += 7
        else:
            self.ep += 8 * e_nbody
        if flags & 1:
            self.check(self.rec_kind() == 8, "EK_FENCE kind")
            self.ep += 1
            # checkpoint: last fence pulse id/ring via debug overlay
            st = self.cl.dbg(3)
            self.check(st & 4, "fence pulse seen")
            self.check(self.cl.dbg(4) == fence,
                       f"fence id {self.cl.dbg(4):#x} != {fence:#x}")
            self.check(self.cl.dbg(5) & 0xFF == ridx,
                       f"fence ring {self.cl.dbg(5):#x} != {ridx}")
            self.ep += 7
        self.cases += 1

    # -- TP_CHECK ----------------------------------------------------------
    @staticmethod
    def ulpd(a, b):
        if a == b:
            return 0
        if (a & 0x7FFFFFFF) == 0 and (b & 0x7FFFFFFF) == 0:
            return 0
        if (a >> 23 & 0xFF) == 0xFF and a & 0x7FFFFF and \
                (b >> 23 & 0xFF) == 0xFF and b & 0x7FFFFF:
            return 0
        if (a >> 31) != (b >> 31):
            return 0x7FFFFFFF
        return abs(a - b)

    def do_check(self):
        what, a0, a1 = self.ntap(), self.ntap(), self.ntap()
        if what == 0:      # CK_HEAD
            self.check(self.rec_kind() == 3 and self.exp[self.ep + 1] == a0,
                       "EK_HEAD")
            ap = self.head_ap.get(a0)
            if ap is None:
                got = self.cl.dbg(16 + a0) & 0xFFFFFFFF
            else:
                got = self.ap32(ap)
            self.check(got == self.exp[self.ep + 2],
                       f"CK_HEAD ring{a0} {got:#x} != {self.exp[self.ep + 2]:#x}")
            self.ep += 8
        elif what == 1:    # CK_STATUS
            self.check(self.rec_kind() == 4 and self.exp[self.ep + 1] == a0,
                       "EK_STATUS")
            exp = self.exp[self.ep + 2]
            ap = self.status_ap.get(a0)
            if ap is None:
                # live tap: the host is slower than the tape player's
                # cycle-locked TB, so the ring may already have drained
                # (IDLE bit set).  The tape's assertion is ALIVE&&!FATAL.
                got = self.cl.dbg(20 + a0) & 0xFFFFFFFF
                self.check(got & ~1 == exp & ~1,
                           f"CK_STATUS ring{a0} tap {got:#x} != {exp:#x}")
            else:
                got = self.ap32(ap)
                self.check(got == exp,
                           f"CK_STATUS ring{a0} got={got:#x} exp={exp:#x}")
            self.ep += 8
        elif what == 2:    # CK_REPLY
            for _ in range(a0):
                self.check(self.rec_kind() == 5, "EK_REPLY kind")
                self.ep += 1
                self.check(self.ap32(a1 + 4 * self.exp[self.ep]) ==
                           self.exp[self.ep + 1], "CK_REPLY word")
                self.ep += 7
        elif what == 3:    # CK_LIVE + EK_PAGES
            self.check(self.rec_kind() == 6, "EK_LIVE kind")
            live = self.cl.dbg(1) & 0xFFFF
            self.check(live == self.exp[self.ep + 1],
                       f"live {live} != {self.exp[self.ep + 1]}")
            self.ep += 8
            self.check(self.rec_kind() == 11, "EK_PAGES kind")
            pages = self.cl.dbg(6)
            self.check(pages == self.exp[self.ep + 1],
                       f"pages {pages} != {self.exp[self.ep + 1]}")
            self.ep += 8
        elif what == 4:    # CK_EXTRA [ring][byte off]
            self.check(self.rec_kind() == 7, "EK_EXTRA kind")
            base_w = self.cl.dbg(24 + a0) & 0x3FFFF
            got = self.ap32(base_w * 4 + a1)
            self.check(got == self.exp[self.ep + 3],
                       f"CK_EXTRA ring{a0} off{a1:#x}")
            self.ep += 8
        elif what == 6:    # CK_APR
            for i in range(a0):
                got = self.ap32(a1 + 4 * i)
                self.check(self.rec_kind() == 10, "EK_APRCHK kind")
                self.check(self.exp[self.ep + 1] == a1 + 4 * i,
                           "EK_APRCHK offset")
                self.check(got == self.exp[self.ep + 2],
                           f"G1 @{a1 + 4 * i:#x} {got:#x} != "
                           f"{self.exp[self.ep + 2]:#x}")
                if self.exp[self.ep + 4] == 0:
                    self.check(got == self.exp[self.ep + 3], "G2i")
                else:
                    self.check(self.ulpd(got, self.exp[self.ep + 3]) <= 2,
                               "G2f")
                self.ep += 8
        else:
            raise Fail(f"unknown CHECK {what}")

    # -- tape --------------------------------------------------------------
    def play(self):
        while True:
            op = self.ntap()
            if op == 0:
                break
            if op == 1:    # TP_MEMW
                n, al = self.ntap(), self.ntap()
                self.ntap()
                base = VN["VN_DMA_BASE"] + al
                for i in range(n):
                    self.mem.w32(base + 4 * i, self.ntap())
            elif op == 2:
                self.chain_submit()
                self.chain_expect()
            elif op == 3:  # TP_APW
                n, al = self.ntap(), self.ntap()
                self.ntap()
                for i in range(n):
                    self.mem.w32(VN["VN_SHM_BASE"] + al + 4 * i,
                                 self.ntap())
            elif op == 4:  # TP_WAIT_HEAD [ring][ap][exp][tmo]
                rg, ad, eh = self.ntap(), self.ntap(), self.ntap()
                tmo = self.ntap()
                t0 = time.time()
                while self.ap32(ad) != eh:
                    self.cl.pump(0.01)
                    if time.time() - t0 > 600:
                        raise Fail(f"WAIT_HEAD ring{rg} timeout")
                self.check(self.rec_kind() == 3 and
                           self.exp[self.ep + 1] == rg and
                           self.exp[self.ep + 2] == eh, "EK_HEAD words")
                self.check(self.cl.dbg(16 + rg) & 0xFFFFFFFF == eh,
                           f"ring_head_o {rg}")
                self.ep += 8
            elif op == 5:  # TP_WAIT_IDLE [ring][ap][mask][want][tmo]
                rg, ad, mask, want = (self.ntap() for _ in range(4))
                tmo = self.ntap()
                t0 = time.time()
                while (self.ap32(ad) & mask) != want:
                    self.cl.pump(0.01)
                    if time.time() - t0 > 600:
                        raise Fail(f"WAIT_IDLE ring{rg} timeout")
                self.check(self.rec_kind() == 4, "EK_STATUS kind")
                # live ring_status_o tap: tolerate the IDLE bit (the
                # ring may drain between the aperture image write and
                # this host-side read — same race class as CK_STATUS)
                self.check((self.cl.dbg(20 + rg) & 0xFFFFFFFE) ==
                           (self.exp[self.ep + 2] & 0xFFFFFFFE),
                           "ring_status_o")
                # the image is live too: after the masked poll fires,
                # a drain can set IDLE before this read lands
                self.check((self.ap32(ad) & ~1) ==
                           (self.exp[self.ep + 2] & ~1),
                           f"aperture status @{ad:#x} "
                           f"got={self.ap32(ad):#x} "
                           f"exp={self.exp[self.ep + 2]:#x} "
                           f"mask={mask:#x} want={want:#x}")
                self.ep += 8
            elif op == 6:
                self.do_check()
            elif op == 7:  # TP_DELAY
                n = self.ntap()
                self.cl.pump(min(max(n / 80000.0, 0.01), 3.0))
            else:
                raise Fail(f"bad tape op {op}")
        # teardown: objpay chunks drained
        self.check(self.cl.dbg(7) == 0, "objpay chunks drained")


# ------------------------------------------------------------- probe


def probe(cl, venus=True):
    n = [0]

    def ck(c, m):
        n[0] += 1
        if not c:
            raise Fail(f"probe: {m}")

    vrd, vwr = cl.mmio_rd, cl.mmio_wr
    ck(vrd(VN["VREG_MAGIC"]) == VN["VN_MAGIC"], "magic")
    ck(vrd(VN["VREG_VERSION"]) == VN["VN_VERSION"], "version")
    ck(vrd(VN["VREG_DEVICE_ID"]) == VN["VN_DEVICE_ID"], "device id")
    ck(vrd(VN["VREG_VENDOR_ID"]) == VN["VN_VENDOR"], "vendor")
    vwr(VN["VREG_STATUS"], 0)
    vwr(VN["VREG_STATUS"], VN["VN_ACKNOWLEDGE"])
    vwr(VN["VREG_STATUS"], VN["VN_ACKNOWLEDGE"] | VN["VN_DRIVER"])
    vwr(VN["VREG_DEVICE_FEAT_SEL"], 0)
    flo = vrd(VN["VREG_DEVICE_FEATURES"])
    vwr(VN["VREG_DEVICE_FEAT_SEL"], 1)
    fhi = vrd(VN["VREG_DEVICE_FEATURES"])
    lo = (1 | (1 << 3) | (1 << 4))
    if venus:
        ck(flo & lo == lo, f"feature lo {flo:#x}")
        ck(fhi & 1 and fhi & (1 << 8), f"feature hi {fhi:#x}")
    else:
        ck(flo & lo == 0, f"off feature lo {flo:#x}")
        ck(fhi & 1 and fhi & (1 << 8), f"off feature hi {fhi:#x}")
    vwr(VN["VREG_DRIVER_FEAT_SEL"], 0)
    vwr(VN["VREG_DRIVER_FEATURES"], flo)
    vwr(VN["VREG_DRIVER_FEAT_SEL"], 1)
    vwr(VN["VREG_DRIVER_FEATURES"], fhi)
    vwr(VN["VREG_STATUS"],
        VN["VN_ACKNOWLEDGE"] | VN["VN_DRIVER"] | VN["VN_FEATURES_OK"])
    ck(vrd(VN["VREG_STATUS"]) & VN["VN_FEATURES_OK"], "features_ok")
    vwr(VN["VREG_SHM_SEL"], 1)
    # §12.3 F5: SHM_LEN publishes the guest-mappable span; the window's
    # private tail holds device-internal descriptor record stores
    for reg, want, m in (("VREG_SHM_LEN_LO", VN["VN_SHM_GUEST_BYTES"] & 0xFFFFFFFF,
                          "shm len lo"),
                         ("VREG_SHM_LEN_HI", VN["VN_SHM_GUEST_BYTES"] >> 32,
                          "shm len hi"),
                         ("VREG_SHM_BASE_LO", VN["VN_SHM_BASE"] & 0xFFFFFFFF,
                          "shm base lo"),
                         ("VREG_SHM_BASE_HI", VN["VN_SHM_BASE"] >> 32,
                          "shm base hi")):
        ck(vrd(VN[reg]) == (want if venus else 0xFFFFFFFF), m)
    vwr(VN["VREG_SHM_SEL"], 0)
    ck(vrd(VN["VREG_SHM_LEN_LO"]) == 0xFFFFFFFF, "shm0 len")
    ck(vrd(VN["VREG_SHM_BASE_LO"]) == 0xFFFFFFFF, "shm0 base")
    ck(vrd(VN["VCFG_NUM_CAPSETS"]) == (VN["VN_NUM_CAPSETS"] if venus else 0),
       "num_capsets")
    ck(vrd(VN["VCFG_NUM_SCANOUTS"]) == 0, "num_scanouts")
    for q, num, dd, aa, uu in ((0, VN["VN_Q0_NUM"], VN["VN_Q0_DESC"],
                               VN["VN_Q0_AVAIL"], VN["VN_Q0_USED"]),
                              (1, VN["VN_Q1_NUM"], VN["VN_Q1_DESC"],
                               VN["VN_Q1_AVAIL"], VN["VN_Q1_USED"])):
        vwr(VN["VREG_QUEUE_SEL"], q)
        ck(vrd(VN["VREG_QUEUE_NUM_MAX"]) >= num, f"queue{q} num_max")
        vwr(VN["VREG_QUEUE_NUM"], num)
        for reg, val in (("VREG_QUEUE_DESC_LO", dd & 0xFFFFFFFF),
                         ("VREG_QUEUE_DESC_HI", dd >> 32),
                         ("VREG_QUEUE_AVAIL_LO", aa & 0xFFFFFFFF),
                         ("VREG_QUEUE_AVAIL_HI", aa >> 32),
                         ("VREG_QUEUE_USED_LO", uu & 0xFFFFFFFF),
                         ("VREG_QUEUE_USED_HI", uu >> 32)):
            vwr(VN[reg], val)
        vwr(VN["VREG_QUEUE_READY"], 1)
    vwr(VN["VREG_STATUS"], VN["VN_ACKNOWLEDGE"] | VN["VN_DRIVER"] |
        VN["VN_FEATURES_OK"] | VN["VN_DRIVER_OK"])
    return n[0]


# ------------------------------------------------------------- driver


def run_server(binary, sock, log):
    lf = open(log, "w")
    p = subprocess.Popen([binary, "--sock", sock, "--stats"],
                         stdout=lf, stderr=lf)
    cl_probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    t0 = time.time()
    while True:
        try:
            cl_probe.connect(sock)
            cl_probe.close()
            break
        except OSError:
            if p.poll() is not None:
                raise Fail(f"server exited early: see {log}")
            if time.time() - t0 > 60:
                raise Fail("server socket timeout")
            time.sleep(0.05)
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", default="/tmp/g6lc-apu-bridge/bridge_map.h")
    ap.add_argument("--server",
                    default="/tmp/g6lc-apu-bridge/obj_venus/apu_bridge")
    ap.add_argument("--server-off",
                    default="/tmp/g6lc-apu-bridge/obj_venusoff/apu_bridge")
    ap.add_argument("--sock", default="/tmp/g6lc-apu-rtl.sock")
    ap.add_argument("--out", default="/tmp/g6lc-apu-bridge")
    ap.add_argument("--arms", default="venus,venusoff")
    a = ap.parse_args()
    global VN
    VN = load_map(a.map)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    checks_total = 0
    ok = True

    if "venus" in a.arms.split(","):
        srv = run_server(a.server, a.sock, out / "server-venus.log")
        try:
            mem = Mem()
            cl = Client(mem)
            cl.connect(a.sock)
            n = probe(cl, venus=True)
            print(f"[venus] probe: {n} checks OK")
            checks_total += n
            for name in ("ue_sm5_transport", "ue_cpos_bufcopy_1"):
                t0 = time.time()
                pl = Player(cl, name)
                pl.play()
                dt = time.time() - t0
                checks_total += pl.checks
                print(f"[venus] {name}: {pl.cases} cases "
                      f"{pl.checks} checks ({dt:.1f}s)")
            mem.w(VN["VN_COOKIE_ADDR"], struct.pack("<Q", VN["PASS_COMPUTE"]))
            print(f"[venus] dma_rd={cl.n_dma_rd} dma_wr={cl.n_dma_wr} "
                  f"bytes={cl.dma_bytes} irq_edges={cl.irq_edges}")
        except Fail as e:
            print(f"FAIL venus: {e}")
            ok = False
        finally:
            srv.terminate()
            srv.wait(timeout=10)

    if "venusoff" in a.arms.split(","):
        srv = run_server(a.server_off, a.sock, out / "server-venusoff.log")
        try:
            mem = Mem()
            cl = Client(mem)
            cl.connect(a.sock)
            n = probe(cl, venus=False)
            checks_total += n
            d0 = cl.n_dma_rd + cl.n_dma_wr
            cl.mmio_wr(VN["VREG_QUEUE_NOTIFY"], 0)
            cl.pump(1.0)
            ck2 = cl.n_dma_rd + cl.n_dma_wr == d0 and cl.irq_level == 0
            if not ck2:
                raise Fail("venusoff: DMA/irq after doorbell")
            checks_total += 2
            print(f"[venusoff] probe+transport: {n + 2} checks OK, "
                  "no DMA, no IRQ")
        except Fail as e:
            print(f"FAIL venusoff: {e}")
            ok = False
        finally:
            srv.terminate()
            srv.wait(timeout=10)

    print(f"[selftest] total checks={checks_total} -> "
          f"{'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
