#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""gen_dmprog.py — emit the g6lc_apu_shwave Determinant/MatrixInverse
micro-program (include/g6lc_apu_dmprog.svh).

The shwave DM engine is a tiny stored-program sequencer stepped from
W_DMS.  Each 30-bit instruction is

    {op[4:0], dst[6:0], sa[5:0], sb[5:0], sc[5:0]}

Source id space:

    0..15   dtm flat (staged matrix element m[c][r] = id c*4+r,
            plus scratch temps not covered by the operand set)
    16..27  t0..t2 scalar temps (16 + t*4; comp 0 only)
    28..43  dres result words (inverse cofactors)
    60      fp32 1.0    61  fp32 0.0

Destination id space:

    0..15   dtm flat
    16..27  t0..t2 scalar temps
    28..43  dres result words
    44..47  wb[0..3]  (the determinant writes 44 = wb comp 0)

ops: 0 HALT, 1 MUL(a*b), 2 MULN((-a)*b), 3 ADD(b+c), 4 SUB(b-c),
     5 FMA(a*b+c), 6 FMAN((-a)*b+c), 7 DIV(a/b), 8 MOV(a) —
all scalar per lane (the engine runs with ncomp=1).

The generator mirrors spirv_model.py's detn()/matinv() op ordering
*exactly* — plain fmul/fadd/fsub/fdiv, no fused ops, column-major:

    det2 = fsub(fmul(m00,m11), fmul(m01,m10))
    detN = fmul(m[0][0], minor(0,0));
           acc = fsub(acc, fmul(m[j][0], minor(0,j)))  for odd j
           acc = fadd(acc, fmul(m[j][0], minor(0,j)))  for even j
    inv  = fdiv(1, detn(m));
           inv[r][i] = fmul(sgn * minor(i, r), invdet)

usage: gen_dmprog.py > ../include/g6lc_apu_dmprog.svh
       gen_dmprog.py --check   # freshness gate: exit 1 on drift
                               # (wired as the run-apu-regress.sh unit
                               # suite `shwave-dmprog`)
"""

OPS = dict(HALT=0, MUL=1, MULN=2, ADD=3, SUB=4, FMA=5, FMAN=6,
           DIV=7, MOV=8)

T0 = 16                          # flat ids of the scalar temps t0..t2
DRES = 28                        # dres flat base
WB0 = 44                         # wb comp0 destination
ONE, ZERO = 60, 61               # source-space constants


def emit(prog, op, dst, sa=0, sb=0, sc=0):
    prog.append((OPS[op] << 25) | (dst << 18) | (sa << 12) |
                (sb << 6) | sc)


class Gen:
    def __init__(self, prog, elems):
        self.prog = prog
        # temp pool: t0..t2 flat ids then any dtm id outside the live
        # matrix-element set (elements stay read-only for the whole op)
        self.pool = [i for i in range(16, 28)]
        self.pool += [i for i in range(16) if i not in elems]

    def alloc(self):
        if not self.pool:
            raise AssertionError('temp overflow')
        return self.pool.pop(0)

    def release(self, t):
        if t >= 16 or t not in self.pool:
            self.pool.insert(0, t)

    def det_prog(self, elems, n):
        """elems[c][r] = flat source id of m[c][r]; returns the temp id
        holding det (comp0 scalar)."""
        if n == 1:
            return elems[0][0]
        if n == 2:
            t0 = self.alloc()
            t1 = self.alloc()
            emit(self.prog, 'MUL', t0, elems[0][0], elems[1][1])
            emit(self.prog, 'MUL', t1, elems[0][1], elems[1][0])
            emit(self.prog, 'SUB', t0, 0, t0, t1)      # t0 = t0 - t1
            self.release(t1)
            return t0
        acc = None
        for j in range(n):
            sub = [[elems[c][r] for c in range(n) if c != j]
                   for r in range(n) if r != 0]
            sg = [[sub[r][c] for r in range(n - 1)]
                  for c in range(n - 1)]               # [col][row]
            mj = self.det_prog(sg, n - 1)
            t = self.alloc()
            emit(self.prog, 'MUL', t, elems[j][0], mj)
            self.release(mj)
            if acc is None:
                acc = t
            else:
                emit(self.prog, 'SUB' if j & 1 else 'ADD',
                     acc, 0, acc, t)                   # acc = acc -/+ t
                self.release(t)
        return acc

    def det(self, n):
        elems = [[c * 4 + r for r in range(n)] for c in range(n)]
        d = self.det_prog(elems, n)
        emit(self.prog, 'MOV', WB0, d)
        emit(self.prog, 'HALT', 0)

    def inv(self, n):
        elems = [[c * 4 + r for r in range(n)] for c in range(n)]
        d = self.det_prog(elems, n)                # det in temp d
        iv = self.alloc()
        emit(self.prog, 'DIV', iv, ONE, d)         # iv = 1/det
        self.release(d)
        for i in range(n):                         # inverse column i
            for r in range(n):                     # inverse row r
                if n == 2:
                    cof = elems[1 - r][1 - i]
                else:
                    sub = [[elems[c][rr] for c in range(n) if c != r]
                           for rr in range(n) if rr != i]
                    sg = [[sub[r2][c2] for r2 in range(n - 1)]
                          for c2 in range(n - 1)]
                    cof = self.det_prog(sg, n - 1)
                op = 'MULN' if (i + r) & 1 else 'MUL'
                emit(self.prog, op, DRES + i * 4 + r, cof, iv)
                if n > 2:
                    self.release(cof)
        emit(self.prog, 'HALT', 0)


def build():
    prog = []
    bases = {}
    for n in (2, 3, 4):
        bases[f'DET{n}'] = len(prog)
        g = Gen(prog, {c * 4 + r for c in range(n) for r in range(n)})
        g.det(n)
        prog = g.prog
    for n in (2, 3, 4):
        bases[f'INV{n}'] = len(prog)
        g = Gen(prog, {c * 4 + r for c in range(n) for r in range(n)})
        g.inv(n)
        prog = g.prog
    out = []
    out.append('// GENERATED by tools/shader/gen_dmprog.py — do not'
               ' edit')
    out.append('// Determinant/MatrixInverse micro-program for the'
               ' shwave DM engine; mirrors spirv_model.py'
               ' detn()/matinv().')
    for k in sorted(bases, key=lambda k: bases[k]):
        out.append(f'localparam int DM_{k} = {bases[k]};')
    out.append(f'localparam int DMN = {len(prog)};')
    out.append("localparam logic [29:0] DM_PROG [DMN] = '{")
    for i, w in enumerate(prog):
        c = ',' if i + 1 < len(prog) else ''
        out.append(f"    30'h{w:08X}{c}   // [{i}]")
    out.append('};')
    return '\n'.join(out) + '\n'


def main():
    import pathlib
    import sys
    text = build()
    if '--check' in sys.argv[1:]:
        svh = (pathlib.Path(__file__).resolve().parent.parent.parent /
               'include' / 'g6lc_apu_dmprog.svh')
        if not svh.exists() or svh.read_text() != text:
            print(f'FAIL {svh}: stale g6lc_apu_dmprog.svh — regen with'
                  f' tools/shader/gen_dmprog.py')
            return 1
        print(f'PASS {svh.name}: fresh ({text.count(chr(10))} lines)')
        return 0
    sys.stdout.write(text)
    return 0


if __name__ == '__main__':
    import sys
    sys.exit(main())
