#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""rvfi_memcheck — program-order memory oracle over a single-hart RVFI trace.

For every retired load the expected value is the last retired store to each of
its bytes (program order) or, for never-stored bytes, the ELF image loaded into
DRAM (zero outside the image).  A mismatch names the first instruction whose
value the memory system got wrong, independent of any ISS.  Single hart, no
DMA, DRAM only (MMIO/CLINT loads are skipped).  AMOs are checked as loads and
then applied as stores; sc applies only on success (rd == 0).

usage: rvfi_memcheck.py <trace_rvfi_hart_00.dasm> <fw_payload.elf> [--max N] [--all]
       [--watch=HEXADDR] [--stop-retire=N] [--walk=VA:ROOTPPN] [--progress=N]

The trace path may be a FIFO: `mkfifo trace_rvfi_hart_00.dasm` in the run
directory, start the oracle (python3 -u ... --progress=10000000), then the
simulator -- the oracle then runs live against a kernel boot without the trace
ever touching the disk (tee into zstd on the way if a replayable copy is wanted).
"""
import struct
import sys

DRAM_LO, DRAM_HI = 0x80000000, 0x90000000
# Linux/Sv39 static windows (single kernel, no KASLR): the kernel image and the
# linear map are folded onto their physical addresses so a store through one
# alias is seen by a load through the other; every other virtual address
# (vmalloc, fixmap, user) is its own key -- never-stored bytes there read as 0
# and a mismatch against them is reported as image/zero-source (vmalloc pages
# are not zeroed by the allocator, so those are hints, not evidence).
KIMG_VA, KIMG_PA, KIMG_LEN = 0xffffffff80000000, 0x80200000, 0x40000000
LINEAR_VA, LINEAR_PA, LINEAR_LEN = 0xffffffd800000000, 0x80000000, 0x10000000
VA_FLOOR = 0xffffffc000000000


def fold(addr):
    if KIMG_VA <= addr < KIMG_VA + KIMG_LEN:
        return addr - KIMG_VA + KIMG_PA, 'pa'
    if LINEAR_VA <= addr < LINEAR_VA + LINEAR_LEN:
        return addr - LINEAR_VA + LINEAR_PA, 'pa'
    if DRAM_LO <= addr < DRAM_HI:
        return addr, 'pa'
    if addr >= VA_FLOOR:
        return addr, 'va'
    return addr, 'mmio'


def load_elf(path):
    """{paddr: bytes} per PT_LOAD segment (memsz zero-filled)."""
    segs = []
    with open(path, 'rb') as f:
        e = f.read()
    assert e[:4] == b'\x7fELF' and e[4] == 2, 'ELF64 expected'
    phoff = struct.unpack_from('<Q', e, 0x20)[0]
    phentsize, phnum = struct.unpack_from('<HH', e, 0x36)
    for i in range(phnum):
        o = phoff + i * phentsize
        p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz = struct.unpack_from('<IIQQQQQ', e, o)
        if p_type != 1 or p_memsz == 0:
            continue
        data = e[p_offset:p_offset + p_filesz] + b'\0' * (p_memsz - p_filesz)
        segs.append((p_paddr, data))
    return segs


class Mem:
    """Stored bytes live in 4 KiB pages (data + known bitmap) instead of a
    per-byte dict: a Linux boot stores ~10^8 distinct bytes, which is ~10 GB as
    dict entries and ~1 GB as pages, and the live (FIFO-fed) oracle has to hold
    that for the whole run."""
    def __init__(self, segs):
        self.segs = segs
        self.pages = {}             # page number -> (bytearray data, bytearray known)

    def init_byte(self, a):
        for base, data in self.segs:
            if base <= a < base + len(data):
                return data[a - base]
        return 0

    def known(self, a):
        p = self.pages.get(a >> 12)
        return p is not None and p[1][a & 0xFFF] != 0

    def any_known(self, a, n):
        return any(self.known(a + i) for i in range(n))

    def read(self, a, n):
        v = 0
        for i in range(n):
            p = self.pages.get((a + i) >> 12)
            o = (a + i) & 0xFFF
            b = p[0][o] if p is not None and p[1][o] else self.init_byte(a + i)
            v |= b << (8 * i)
        return v

    def write(self, a, n, v):
        for i in range(n):
            pn = (a + i) >> 12
            p = self.pages.get(pn)
            if p is None:
                p = (bytearray(4096), bytearray(4096))
                self.pages[pn] = p
            o = (a + i) & 0xFFF
            p[0][o] = (v >> (8 * i)) & 0xFF
            p[1][o] = 1


def decode(insn):
    """-> (kind, size, signed) kind in {'L','S','A','SC','LR',None}."""
    if insn & 3 != 3:                       # compressed
        op = insn & 3
        f3 = (insn >> 13) & 7
        if op == 0:
            if f3 == 2: return ('L', 4, True)     # c.lw
            if f3 == 3: return ('L', 8, False)    # c.ld
            if f3 == 6: return ('S', 4, False)    # c.sw
            if f3 == 7: return ('S', 8, False)    # c.sd
            if f3 == 1: return ('L', 8, False)    # c.fld
            if f3 == 5: return ('S', 8, False)    # c.fsd
            return (None, 0, False)
        if op == 2:
            if f3 == 2: return ('L', 4, True)     # c.lwsp
            if f3 == 3: return ('L', 8, False)    # c.ldsp
            if f3 == 6: return ('S', 4, False)    # c.swsp
            if f3 == 7: return ('S', 8, False)    # c.sdsp
            if f3 == 1: return ('L', 8, False)    # c.fldsp
            if f3 == 5: return ('S', 8, False)    # c.fsdsp
        return (None, 0, False)
    opc = insn & 0x7F
    f3 = (insn >> 12) & 7
    if opc == 0x03:                          # loads
        size = 1 << (f3 & 3)
        return ('L', size, f3 < 4)
    if opc == 0x07:                          # fp loads
        return ('L', 1 << (f3 & 3), False)
    if opc == 0x23 or opc == 0x27:           # stores / fp stores
        return ('S', 1 << (f3 & 3), False)
    if opc == 0x2F:                          # AMO
        f5 = insn >> 27
        size = 1 << (f3 & 3)
        if f5 == 0x02: return ('LR', size, f3 == 2)
        if f5 == 0x03: return ('SC', size, False)
        return ('A', size, f3 == 2)
    return (None, 0, False)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    maxn = None
    for a in sys.argv[1:]:
        if a.startswith('--max'):
            maxn = int(a.split('=')[1])
    report_all = '--all' in sys.argv
    watch = None
    stop_retire = None
    progress = 0
    walks = []
    for a in sys.argv[1:]:
        if a.startswith('--watch='):
            watch = int(a.split('=')[1], 16)
        elif a.startswith('--stop-retire='):
            stop_retire = int(a.split('=')[1])
        elif a.startswith('--progress='):
            # live (FIFO-fed) runs: one flushed status line every N retirements
            progress = int(a.split('=')[1])
        elif a.startswith('--walk='):
            # --walk=VA:ROOTPPN  Sv39 walk over the model memory at --stop-retire
            va, root = a.split('=')[1].split(':')
            walks.append((int(va, 16), int(root, 16)))
    trace, elf = args[0], args[1]
    mem = Mem(load_elf(elf))
    n = 0
    loads = stores = amos = skipped = 0
    mism = 0
    unknown = 0
    retire = 0
    lineno = 0
    with open(trace, 'r', errors='replace') as f:
        for line in f:
            lineno += 1
            if line.startswith('core'):
                retire += 1
                if stop_retire is not None and retire >= stop_retire:
                    break
                if progress and retire % progress == 0:
                    print(f"progress retire={retire} loads={loads} stores={stores} mismatches={mism} stored-mismatches={mism - unknown} pages={len(mem.pages)}", flush=True)
                continue
            if not (line and line[0] in '0123' and line[1] == ' ') or ' mem ' not in line:
                continue
            t = line.split()
            if len(t) < 3 or 'mem' not in t:
                continue
            n += 1
            if maxn and n > maxn:
                break
            try:
                pc = int(t[1], 16)
                insn = int(t[2][3:-1], 16)
            except ValueError:
                continue
            kind, size, signed = decode(insn)
            if kind is None:
                continue
            mi = t.index('mem')
            addr = int(t[mi + 1], 16)
            wdata = int(t[mi + 2], 16) if mi + 2 < len(t) else None
            rdval = None
            # register write "x N 0x..." or "xN 0x..."
            for k in range(3, mi):
                if t[k].startswith('x') and k + 1 < mi:
                    try:
                        rdval = int(t[k + 1], 16) if t[k] != 'x' else int(t[k + 2], 16)
                    except (ValueError, IndexError):
                        rdval = None
                    break
            addr, space = fold(addr)
            if space == 'mmio':
                skipped += 1
                continue
            if watch is not None and addr <= watch < addr + max(size, 1):
                print(f"  watch memop {n} retire {retire}: pc=0x{pc:x} insn=0x{insn:x} {kind}{size} addr=0x{addr:x} rd={rdval} wdata={wdata} model_before=0x{mem.read(addr, size):x}")
            if kind in ('L', 'LR', 'A'):
                if rdval is None:
                    skipped += 1
                else:
                    if space == 'va' and not mem.any_known(addr, size):
                        loads += 1
                        continue   # never-stored vmalloc/user bytes: no oracle value
                    exp = mem.read(addr, size)
                    got = rdval & ((1 << (8 * size)) - 1) if size < 8 else rdval
                    if signed and size < 8 and (exp >> (8 * size - 1)) & 1:
                        exp_full = exp | (~((1 << (8 * size)) - 1) & ((1 << 64) - 1))
                    else:
                        exp_full = exp
                    got_full = rdval & ((1 << 64) - 1)
                    if size < 8:
                        ok = (got == exp) and (exp_full == got_full or not signed and got_full == exp)
                    else:
                        ok = got_full == exp
                    if not ok:
                        # distinguish never-stored (image/zero) from stored bytes
                        src = 'stored' if mem.any_known(addr, size) else 'image/zero'
                        mism += 1
                        if src != 'stored':
                            unknown += 1
                        if report_all or mism <= 20 or src == 'stored':
                            print(f"MISMATCH #{mism} memop {n} retire {retire} line {lineno}: pc=0x{pc:x} insn=0x{insn:08x} {kind}{size} addr=0x{addr:x} got=0x{got_full:x} exp=0x{exp_full:x} src={src}", flush=True)
                    loads += 1
                if kind == 'A' and wdata is not None:
                    mem.write(addr, size, wdata)
                    amos += 1
            elif kind == 'S':
                if wdata is not None:
                    mem.write(addr, size, wdata)
                    stores += 1
            elif kind == 'SC':
                if wdata is not None and rdval == 0:
                    mem.write(addr, size, wdata)
                    stores += 1
    for va, root in walks:
        pt = root << 12
        print(f"walk VA=0x{va:x} root=0x{pt:x} at retire {retire}:")
        for lvl in (2, 1, 0):
            idx = (va >> (12 + 9 * lvl)) & 0x1ff
            pa = pt + idx * 8
            pte = mem.read(pa, 8)
            src = 'stored' if mem.any_known(pa, 8) else 'image/zero'
            flags = ''.join(c if (pte >> b) & 1 else '-' for b, c in enumerate('VRWXUGAD'))
            print(f"  L{lvl} idx=0x{idx:x} pte@0x{pa:x} = 0x{pte:016x} [{flags}] ppn=0x{pte >> 10:x} ({src})")
            if not pte & 1 or pte & 0xe:
                break
            pt = (pte >> 10) << 12
    print(f"checked loads={loads} stores={stores} amos={amos} skipped(mmio/no-rd)={skipped} mismatches={mism} (of which image/zero-source={unknown})")


if __name__ == '__main__':
    main()
