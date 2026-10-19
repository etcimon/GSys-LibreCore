#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""rvfi_alucheck -- register-only oracle over an RVFI trace.

The integer register file is shadowed from the trace's rd writes; for every
retired instruction whose result depends on registers and immediates only
(RV64IMC arithmetic, logic, shifts, lui/auipc, jal/jalr link, mul/div), the
expected rd is recomputed from the shadow state and compared with the value the
core wrote.  Loads, CSR accesses, AMOs, FP and anything else that brings a value
from outside the register file update the shadow and are not checked.  A
mismatch names the first instruction whose datapath result is wrong -- the
complement of rvfi_memcheck (memory values) for the cases where the memory
oracle is clean but the kernel still dies of a garbage pointer.  Control flow
is checked too: every retirement's pc is compared with the pc the previous
instruction predicts from the shadow registers (fall-through, jal/jalr target,
branch outcome); a trap or interrupt line between the two suspends the check,
and sret/mret/ecall/ebreak/wfi predict nothing.

usage: rvfi_alucheck.py <trace.dasm> [--start-retire=N] [--stop-retire=N]
                        [--progress=N] [--max-report=N] [--dump-first=N]

Starting late is fine: a register is checked only once every source register
has been written inside the window (the `known` mask).
"""
import sys

M64 = (1 << 64) - 1


def sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def to64(v):
    return v & M64


def sxw(v):
    return to64(sx(v, 32))


def decode_c(insn):
    """-> (rd, [srcs], fn) for compressed register-only ops, else None.
    fn(regs, pc) -> expected rd value."""
    op = insn & 3
    f3 = (insn >> 13) & 7
    rd = (insn >> 7) & 0x1F
    rs2 = (insn >> 2) & 0x1F
    rdp = 8 + ((insn >> 7) & 7)
    rs2p = 8 + ((insn >> 2) & 7)
    if op == 0:
        if f3 == 0 and insn != 0:                       # c.addi4spn
            imm = (((insn >> 7) & 0xF) << 6) | (((insn >> 11) & 3) << 4) | (((insn >> 5) & 1) << 3) | (((insn >> 6) & 1) << 2)
            return rs2p, [2], lambda r, pc: to64(r[2] + imm)
        return None
    if op == 1:
        if f3 == 0:                                     # c.addi / c.nop
            imm = sx((((insn >> 12) & 1) << 5) | ((insn >> 2) & 0x1F), 6)
            if rd == 0: return None
            return rd, [rd], lambda r, pc: to64(r[rd] + imm)
        if f3 == 1:                                     # c.addiw
            imm = sx((((insn >> 12) & 1) << 5) | ((insn >> 2) & 0x1F), 6)
            if rd == 0: return None
            return rd, [rd], lambda r, pc: sxw(r[rd] + imm)
        if f3 == 2:                                     # c.li
            imm = sx((((insn >> 12) & 1) << 5) | ((insn >> 2) & 0x1F), 6)
            if rd == 0: return None
            return rd, [], lambda r, pc: to64(imm)
        if f3 == 3:
            if rd == 2:                                 # c.addi16sp
                imm = sx((((insn >> 12) & 1) << 9) | (((insn >> 6) & 1) << 4) | (((insn >> 5) & 1) << 6) |
                         (((insn >> 3) & 3) << 7) | (((insn >> 2) & 1) << 5), 10)
                return 2, [2], lambda r, pc: to64(r[2] + imm)
            if rd != 0:                                 # c.lui
                imm = sx((((insn >> 12) & 1) << 17) | (((insn >> 2) & 0x1F) << 12), 18)
                return rd, [], lambda r, pc: to64(imm)
            return None
        if f3 == 4:
            f2 = (insn >> 10) & 3
            sh = (((insn >> 12) & 1) << 5) | ((insn >> 2) & 0x1F)
            if f2 == 0:                                 # c.srli
                return rdp, [rdp], lambda r, pc: r[rdp] >> sh
            if f2 == 1:                                 # c.srai
                return rdp, [rdp], lambda r, pc: to64(sx(r[rdp], 64) >> sh)
            if f2 == 2:                                 # c.andi
                imm = sx(sh, 6)
                return rdp, [rdp], lambda r, pc: to64(r[rdp] & imm)
            g = (insn >> 5) & 3
            if not (insn >> 12) & 1:
                ops = [lambda a, b: to64(a - b), lambda a, b: a ^ b, lambda a, b: a | b, lambda a, b: a & b]
                return rdp, [rdp, rs2p], (lambda f: (lambda r, pc: f(r[rdp], r[rs2p])))(ops[g])
            if g == 0:                                  # c.subw
                return rdp, [rdp, rs2p], lambda r, pc: sxw(r[rdp] - r[rs2p])
            if g == 1:                                  # c.addw
                return rdp, [rdp, rs2p], lambda r, pc: sxw(r[rdp] + r[rs2p])
            return None
        if f3 == 5:                                     # c.j (no rd)
            return None
        return None
    if op == 2:
        if f3 == 0:                                     # c.slli
            sh = (((insn >> 12) & 1) << 5) | ((insn >> 2) & 0x1F)
            if rd == 0: return None
            return rd, [rd], lambda r, pc: to64(r[rd] << sh)
        if f3 == 4:
            if not (insn >> 12) & 1:
                if rs2 != 0 and rd != 0:                # c.mv
                    return rd, [rs2], lambda r, pc: r[rs2]
                return None                             # c.jr
            if rs2 == 0:
                if rd == 0: return None                 # c.ebreak
                return 1, [], lambda r, pc: to64(pc + 2)  # c.jalr: ra = pc + 2
            if rd != 0:                                 # c.add
                return rd, [rd, rs2], lambda r, pc: to64(r[rd] + r[rs2])
        return None
    return None


def mulhu(a, b):
    return (a * b) >> 64


def decode(insn):
    if insn & 3 != 3:
        return decode_c(insn)
    opc = insn & 0x7F
    rd = (insn >> 7) & 0x1F
    f3 = (insn >> 12) & 7
    rs1 = (insn >> 15) & 0x1F
    rs2 = (insn >> 20) & 0x1F
    f7 = insn >> 25
    if rd == 0:
        return None
    if opc == 0x37:                                     # lui
        imm = sx(insn & 0xFFFFF000, 32)
        return rd, [], lambda r, pc: to64(imm)
    if opc == 0x17:                                     # auipc
        imm = sx(insn & 0xFFFFF000, 32)
        return rd, [], lambda r, pc: to64(pc + imm)
    if opc == 0x6F:                                     # jal
        return rd, [], lambda r, pc: to64(pc + 4)
    if opc == 0x67:                                     # jalr
        return rd, [], lambda r, pc: to64(pc + 4)
    if opc == 0x13:                                     # op-imm
        imm = sx(insn >> 20, 12)
        sh = (insn >> 20) & 0x3F
        if f3 == 0: return rd, [rs1], lambda r, pc: to64(r[rs1] + imm)
        if f3 == 2: return rd, [rs1], lambda r, pc: int(sx(r[rs1], 64) < imm)
        if f3 == 3: return rd, [rs1], lambda r, pc: int(r[rs1] < to64(imm))
        if f3 == 4: return rd, [rs1], lambda r, pc: to64(r[rs1] ^ imm)
        if f3 == 6: return rd, [rs1], lambda r, pc: to64(r[rs1] | imm)
        if f3 == 7: return rd, [rs1], lambda r, pc: to64(r[rs1] & imm)
        if f3 == 1 and (f7 >> 1) == 0: return rd, [rs1], lambda r, pc: to64(r[rs1] << sh)
        if f3 == 5 and (f7 >> 1) == 0: return rd, [rs1], lambda r, pc: r[rs1] >> sh
        if f3 == 5 and (f7 >> 1) == 0x10: return rd, [rs1], lambda r, pc: to64(sx(r[rs1], 64) >> sh)
        return None
    if opc == 0x1B:                                     # op-imm-32
        imm = sx(insn >> 20, 12)
        sh = (insn >> 20) & 0x1F
        if f3 == 0: return rd, [rs1], lambda r, pc: sxw(r[rs1] + imm)
        if f3 == 1 and f7 == 0: return rd, [rs1], lambda r, pc: sxw(r[rs1] << sh)
        if f3 == 5 and f7 == 0: return rd, [rs1], lambda r, pc: sxw((r[rs1] & 0xFFFFFFFF) >> sh)
        if f3 == 5 and f7 == 0x20: return rd, [rs1], lambda r, pc: sxw(sx(r[rs1], 32) >> sh)
        return None
    if opc == 0x33:                                     # op
        if f7 == 0:
            ops = {0: lambda a, b: to64(a + b), 1: lambda a, b: to64(a << (b & 63)),
                   2: lambda a, b: int(sx(a, 64) < sx(b, 64)), 3: lambda a, b: int(a < b),
                   4: lambda a, b: a ^ b, 5: lambda a, b: a >> (b & 63), 6: lambda a, b: a | b, 7: lambda a, b: a & b}
        elif f7 == 0x20:
            ops = {0: lambda a, b: to64(a - b), 5: lambda a, b: to64(sx(a, 64) >> (b & 63))}
        elif f7 == 1:
            def div(a, b):
                a, b = sx(a, 64), sx(b, 64)
                if b == 0: return M64
                if a == -(1 << 63) and b == -1: return to64(a)
                q = abs(a) // abs(b)
                return to64(-q if (a < 0) != (b < 0) else q)
            def rem(a, b):
                a, b = sx(a, 64), sx(b, 64)
                if b == 0: return to64(a)
                if a == -(1 << 63) and b == -1: return 0
                q = abs(a) // abs(b)
                q = -q if (a < 0) != (b < 0) else q
                return to64(a - b * q)
            ops = {0: lambda a, b: to64(a * b),
                   1: lambda a, b: to64((sx(a, 64) * sx(b, 64)) >> 64),
                   2: lambda a, b: to64((sx(a, 64) * b) >> 64),
                   3: lambda a, b: mulhu(a, b),
                   4: div,
                   5: lambda a, b: M64 if b == 0 else a // b,
                   6: rem,
                   7: lambda a, b: a if b == 0 else a % b}
        else:
            return None
        if f3 not in ops: return None
        f = ops[f3]
        return rd, [rs1, rs2], lambda r, pc: f(r[rs1], r[rs2])
    if opc == 0x3B:                                     # op-32
        if f7 == 0:
            ops = {0: lambda a, b: sxw(a + b), 1: lambda a, b: sxw(a << (b & 31)),
                   5: lambda a, b: sxw((a & 0xFFFFFFFF) >> (b & 31))}
        elif f7 == 0x20:
            ops = {0: lambda a, b: sxw(a - b), 5: lambda a, b: sxw(sx(a, 32) >> (b & 31))}
        elif f7 == 1:
            def divw(a, b):
                a, b = sx(a, 32), sx(b, 32)
                if b == 0: return M64
                if a == -(1 << 31) and b == -1: return sxw(a)
                q = abs(a) // abs(b)
                return sxw(-q if (a < 0) != (b < 0) else q)
            def remw(a, b):
                a, b = sx(a, 32), sx(b, 32)
                if b == 0: return sxw(a)
                if a == -(1 << 31) and b == -1: return 0
                q = abs(a) // abs(b)
                q = -q if (a < 0) != (b < 0) else q
                return sxw(a - b * q)
            ops = {0: lambda a, b: sxw(a * b), 4: divw,
                   5: lambda a, b: M64 if (b & 0xFFFFFFFF) == 0 else sxw((a & 0xFFFFFFFF) // (b & 0xFFFFFFFF)),
                   6: remw,
                   7: lambda a, b: sxw(a & 0xFFFFFFFF) if (b & 0xFFFFFFFF) == 0 else sxw((a & 0xFFFFFFFF) % (b & 0xFFFFFFFF))}
        else:
            return None
        if f3 not in ops: return None
        f = ops[f3]
        return rd, [rs1, rs2], lambda r, pc: f(r[rs1], r[rs2])
    return None


def next_pc(insn, pc, r, known):
    """-> expected pc of the next retired instruction, or None when it depends
    on state the trace does not carry (sret/mret/ecall/ebreak/wfi) or on an
    unknown register."""
    def ok(x): return x == 0 or (known >> x) & 1
    if insn & 3 != 3:
        op = insn & 3
        f3 = (insn >> 13) & 7
        if op == 1 and f3 == 5:                         # c.j (c.jal is RV32-only; f3 == 1 is c.addiw here)
            imm = sx((((insn >> 12) & 1) << 11) | (((insn >> 8) & 1) << 10) | (((insn >> 9) & 3) << 8) |
                     (((insn >> 6) & 1) << 7) | (((insn >> 7) & 1) << 6) | (((insn >> 2) & 1) << 5) |
                     (((insn >> 11) & 1) << 4) | (((insn >> 3) & 7) << 1), 12)
            return to64(pc + imm)
        if op == 1 and f3 in (6, 7):                    # c.beqz / c.bnez
            rs = 8 + ((insn >> 7) & 7)
            if not ok(rs): return None
            imm = sx((((insn >> 12) & 1) << 8) | (((insn >> 5) & 3) << 6) | (((insn >> 2) & 1) << 5) |
                     (((insn >> 10) & 3) << 3) | (((insn >> 3) & 3) << 1), 9)
            taken = (r[rs] == 0) if f3 == 6 else (r[rs] != 0)
            return to64(pc + imm) if taken else to64(pc + 2)
        if op == 2 and f3 == 4 and ((insn >> 2) & 0x1F) == 0:   # c.jr / c.jalr / c.ebreak
            rs = (insn >> 7) & 0x1F
            if rs == 0: return None                     # c.ebreak
            if not ok(rs): return None
            return r[rs] & ~1 & M64
        return to64(pc + 2)
    opc = insn & 0x7F
    f3 = (insn >> 12) & 7
    rs1 = (insn >> 15) & 0x1F
    rs2 = (insn >> 20) & 0x1F
    if opc == 0x6F:                                     # jal
        imm = sx((((insn >> 31) & 1) << 20) | (((insn >> 12) & 0xFF) << 12) | (((insn >> 20) & 1) << 11) |
                 (((insn >> 21) & 0x3FF) << 1), 21)
        return to64(pc + imm)
    if opc == 0x67:                                     # jalr
        if not ok(rs1): return None
        imm = sx(insn >> 20, 12)
        return to64(r[rs1] + imm) & ~1
    if opc == 0x63:                                     # branches
        if not (ok(rs1) and ok(rs2)): return None
        imm = sx((((insn >> 31) & 1) << 12) | (((insn >> 7) & 1) << 11) | (((insn >> 25) & 0x3F) << 5) |
                 (((insn >> 8) & 0xF) << 1), 13)
        a, b = r[rs1], r[rs2]
        taken = {0: a == b, 1: a != b, 4: sx(a, 64) < sx(b, 64), 5: sx(a, 64) >= sx(b, 64),
                 6: a < b, 7: a >= b}.get(f3)
        if taken is None: return None
        return to64(pc + imm) if taken else to64(pc + 4)
    if opc == 0x73:                                     # system: ecall/ebreak/sret/mret/wfi/csr
        if f3 == 0: return None
        return to64(pc + 4)
    return to64(pc + 4)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    start = stop = None
    progress = 0
    max_report = 20
    dump_first = 0
    for a in sys.argv[1:]:
        if a.startswith('--dump-first='): dump_first = int(a.split('=')[1])
        if a.startswith('--start-retire='): start = int(a.split('=')[1])
        elif a.startswith('--stop-retire='): stop = int(a.split('=')[1])
        elif a.startswith('--progress='): progress = int(a.split('=')[1])
        elif a.startswith('--max-report='): max_report = int(a.split('=')[1])
    regs = {}                 # per hart: list of 32 values
    known = {}                # per hart: 32-bit mask of registers written inside the window
    expect = {}               # per hart: expected pc of the next retirement (control flow)
    hart = 0
    retire = 0
    checked = mism = skipped = 0
    cf_checked = cf_mism = 0
    lineno = 0
    trapped = set()           # harts whose next retirement follows a trap/interrupt line
    prev_insn, prev_pc = {}, {}
    with open(args[0], 'r', errors='replace') as f:
        for line in f:
            lineno += 1
            if line.startswith('core'):
                retire += 1
                if stop is not None and retire >= stop:
                    break
                if progress and retire % progress == 0:
                    print(f"progress retire={retire} checked={checked} mismatches={mism} skipped={skipped} cf_checked={cf_checked} cf_mismatches={cf_mism}", flush=True)
                if 'INTERRUPT' in line:
                    trapped.add(hart)
                try:
                    hart = int(line[4:line.index(':')])
                except ValueError:
                    hart = 0
                continue
            if 'exception @' in line:
                trapped.add(hart)
                continue
            if not (line and line[0] in '0123' and line[1] == ' '):
                continue
            t = line.split()
            if len(t) < 3:
                continue
            try:
                pc = int(t[1], 16)
                insn = int(t[2][3:-1], 16)
            except ValueError:
                continue
            r = regs.setdefault(hart, [0] * 32)
            k = known.setdefault(hart, 0)
            # control flow: this retirement's pc against the previous one's prediction
            if (start is None or retire >= start):
                e = expect.get(hart)
                if e is not None and hart not in trapped:
                    cf_checked += 1
                    if e != pc:
                        cf_mism += 1
                        if cf_mism <= max_report:
                            print(f"CF-MISMATCH #{cf_mism} retire {retire} line {lineno} hart {hart}: pc=0x{pc:x} expected 0x{e:x} (prev insn 0x{prev_insn.get(hart, 0):08x} at 0x{prev_pc.get(hart, 0):x})", flush=True)
            trapped.discard(hart)
            rd_val = None
            rd_num = None
            # the tracer prints `x%d`: `x14 0x..` or, space-padded, `x 5 0x..`
            for i in range(3, len(t) - 1):
                if t[i] == 'x' and i + 2 < len(t) and t[i + 1].isdigit():
                    try:
                        rd_num = int(t[i + 1]); rd_val = int(t[i + 2], 16)
                    except ValueError:
                        rd_val = None
                    break
                if t[i].startswith('x') and len(t[i]) > 1 and t[i][1:].isdigit():
                    try:
                        rd_num = int(t[i][1:]); rd_val = int(t[i + 1], 16)
                    except ValueError:
                        rd_val = None
                    break
            if dump_first > 0 and (start is None or retire >= start):
                dump_first -= 1
                print(f"dump retire={retire} line={lineno}: {line.rstrip()[:120]} -> rd={rd_num} val={rd_val}")
            if start is None or retire >= start:
                d = decode(insn)
                if d is not None and rd_val is not None and ' mem ' not in line:
                    erd, srcs, fn = d
                    if erd == rd_num and all((k >> s) & 1 or s == 0 for s in srcs):
                        exp = fn(r, pc)
                        checked += 1
                        if exp != rd_val:
                            mism += 1
                            if mism <= max_report:
                                print(f"MISMATCH #{mism} retire {retire} line {lineno} hart {hart}: pc=0x{pc:x} insn=0x{insn:08x} x{rd_num} got=0x{rd_val:x} exp=0x{exp:x} srcs={[(s, hex(r[s])) for s in srcs]}", flush=True)
                    else:
                        skipped += 1
            # the next pc is predicted from the state BEFORE this instruction's rd
            # write (jalr ra, lo(ra) reads the auipc value, not the link)
            expect[hart] = next_pc(insn, pc, r, k)
            if rd_num is not None and rd_val is not None and rd_num != 0:
                r[rd_num] = rd_val
                known[hart] = k | (1 << rd_num)
            prev_insn[hart] = insn
            prev_pc[hart] = pc
    print(f"checked={checked} mismatches={mism} skipped={skipped} cf_checked={cf_checked} cf_mismatches={cf_mism} retire={retire}")


if __name__ == '__main__':
    main()
