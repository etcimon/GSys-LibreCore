#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded triangle rasterizer producing FS-in records; no FS/ROP/descriptor admission."""
import math
import struct
from dataclasses import dataclass

from shader.spirv_scan import EM, Scanner
from vn_graphics_fetch import ATTR_STRIDE, MAX_RECORDS
from vn_graphics_pshade import BATCH_MAX, FragmentShade, FragmentShadeRuntime

RECORD_STRIDE = ATTR_STRIDE       # FS-in records share the 9-slot stride
MAX_FRAGMENTS = 1 << 15           # covered pixels per raster operation
PIXEL_QUANTUM = 1 << 14           # pixel-center tests per cooperative turn
TRIANGLE_LIST = 3


def _f32(value):
    """Round-trip through binary32 (mirrors vn_golden)."""
    return struct.unpack('<f', struct.pack('<f', value))[0]


def _f2i_rne(value):
    """fpnew F2I round-to-nearest-even on an f32-rounded value."""
    f = math.floor(value)
    d = value - f
    if d > 0.5 or (d == 0.5 and f & 1):
        return f + 1
    return f


@dataclass(frozen=True)
class Raster:
    """One TRIANGLE_LIST raster stage over VS-out records.

    `vary` is the immutable 144-byte-per-vertex VS-out image (Position at
    slot 0, varyings at 16*(1+loc)).  `count` is the vertex record count;
    primitives are consecutive triples in record order (indexed draws are
    already expanded by fetch).  `viewport` = (x, y, w, h, minz, maxz)
    floats; `scissor` = (x, y, w, h) ints; `flat`/`nopersp` are 8-bit
    varying-location masks.  `front_ccw`/`cull` mirror the pipeline state
    (cull: 0 none, 1 front, 2 back).  Primitives are assumed inside the
    view volume (bounded profile: no clip-plane generation)."""
    vary: bytes
    viewport: tuple
    scissor: tuple
    count: int
    flat: int = 0
    nopersp: int = 0
    front_ccw: int = 1
    cull: int = 0

    @property
    def size(self):
        return len(self.vary) + min(
            MAX_FRAGMENTS, self.scissor[2] * self.scissor[3]
        ) * RECORD_STRIDE


class RasterRuntime:
    def __init__(self, executor, context, operation):
        if (not isinstance(operation, Raster) or
                type(operation.vary) is not bytes or
                len(operation.vary) % RECORD_STRIDE or
                type(operation.count) is not int or
                not 3 <= operation.count <= MAX_RECORDS or
                operation.count * RECORD_STRIDE != len(operation.vary) or
                type(operation.viewport) is not tuple or
                len(operation.viewport) != 6 or
                any(type(v) is not float or not math.isfinite(v)
                    for v in operation.viewport) or
                operation.viewport[2] <= 0.0 or
                operation.viewport[3] <= 0.0 or
                type(operation.scissor) is not tuple or
                len(operation.scissor) != 4 or
                any(type(v) is not int or v < 0 for v in operation.scissor) or
                not 0 < operation.scissor[2] <= 4096 or
                not 0 < operation.scissor[3] <= 4096 or
                type(operation.flat) is not int or
                not 0 <= operation.flat < 256 or
                type(operation.nopersp) is not int or
                not 0 <= operation.nopersp < 256 or
                operation.front_ccw not in (0, 1) or
                operation.cull not in (0, 1, 2, 3)):
            raise ValueError('raster operation exceeds native profile')
        if operation.count % 3:
            raise ValueError('raster vertex count is not triangle-aligned')
        self.executor, self.context, self.operation = executor, context, operation
        # raster output is internally generated records: no memory owners
        self.owners = {}
        self.records = bytearray()
        self.fragments = self.triangles = self.culled = 0
        self.degenerate = self.robust = self.tests = self.steps = 0
        self.fronts = []
        self.cursor = 0
        self.emit_ctx = None
        self.max_fragments = min(
            MAX_FRAGMENTS, operation.scissor[2] * operation.scissor[3])
        self.done = False
        self.last_turn = 0

    def _tri(self, t):
        """Screen-space setup for triangle t; mirrors vn_golden coverage."""
        op = self.operation
        vp = op.viewport
        vphw, vphh = _f32(vp[2] * 0.5), _f32(vp[3] * 0.5)
        fma = getattr(math, 'fma', lambda a, b, c: a * b + c)
        verts, clip = [], []
        base = t * 3 * RECORD_STRIDE
        for k in range(3):
            rec = op.vary[base + k * RECORD_STRIDE:
                          base + (k + 1) * RECORD_STRIDE]
            x, y, z, w = struct.unpack_from('<4f', rec, 0)
            if not (math.isfinite(x) and math.isfinite(y) and
                    math.isfinite(z) and math.isfinite(w)) or w <= 0.0:
                return None
            rcp = _f32(1.0 / _f32(w))
            nx, ny = _f32(_f32(x) * rcp), _f32(_f32(y) * rcp)
            sx = _f32(fma(_f32(nx + 1.0), vphw, _f32(vp[0])))
            sy = _f32(fma(_f32(ny + 1.0), vphh, _f32(vp[1])))
            verts.append((_f2i_rne(_f32(sx * 256.0)),
                          _f2i_rne(_f32(sy * 256.0))))
            clip.append((nx, ny, _f32(_f32(z) * rcp), _f32(w)))
        vx = [v[0] for v in verts]
        vy = [v[1] for v in verts]
        area = ((vx[1] - vx[0]) * (vy[2] - vy[0])
                - (vx[2] - vx[0]) * (vy[1] - vy[0]))
        if area == 0:
            return None
        front = (area < 0) == bool(op.front_ccw)
        if (front and op.cull & 1) or (not front and op.cull & 2):
            return 'culled'
        self.fronts.append(front)
        if area < 0:
            vx[1], vx[2] = vx[2], vx[1]
            vy[1], vy[2] = vy[2], vy[1]
            clip[1], clip[2] = clip[2], clip[1]
        edges = []
        for k in range(3):
            a, b = (k + 1) % 3, (k + 2) % 3
            edges.append((vx[a], vy[a], vx[b] - vx[a], vy[b] - vy[a],
                          vy[a] > vy[b] or
                          (vy[a] == vy[b] and vx[a] < vx[b])))
        # coverable domain: viewport rect intersected with the scissor
        vp = op.viewport
        x_lo = max(op.scissor[0], int(math.floor(vp[0])))
        x_hi = min(op.scissor[0] + op.scissor[2],
                   int(math.ceil(vp[0] + vp[2])))
        y_lo = max(op.scissor[1], int(math.floor(vp[1])))
        y_hi = min(op.scissor[1] + op.scissor[3],
                   int(math.ceil(vp[1] + vp[3])))
        return vx, vy, edges, clip, x_lo, y_lo, x_hi, y_hi

    def _begin_emit(self, t, tri):
        vx, vy, edges, clip, x_lo, y_lo, x_hi, y_hi = tri
        # start at the pixel containing the triangle's left/top edges
        px = max(x_lo, min(vx) // 256)
        py = max(y_lo, min(vy) // 256)
        return {'t': t, 'px': px, 'py': py, 'x_start': px,
                'x_hi': min(x_hi, max(vx) // 256 + 1),
                'y_hi': min(y_hi, max(vy) // 256 + 1),
                'vx': vx, 'vy': vy, 'edges': edges, 'clip': clip}

    def _pixel(self, ctx, px, py):
        op = self.operation
        cpx, cpy = px * 256 + 128, py * 256 + 128
        es = []
        for (ex, ey, edx, edy, tl) in ctx['edges']:
            e = edx * (cpy - ey) - edy * (cpx - ex)
            if e < 0 or (e == 0 and not tl):
                return None
            es.append(e)
        total = es[0] + es[1] + es[2]
        if total <= 0:
            return None
        lam = [e / total for e in es]
        clip = ctx['clip']
        den = sum(lam[k] / clip[k][3] for k in range(3))
        if den == 0.0:
            self.robust += 1
            return None
        vp = op.viewport
        z_ndc = sum(lam[k] * clip[k][2] for k in range(3))
        z_win = _f32(vp[4] + z_ndc * (vp[5] - vp[4]))
        rec = bytearray(RECORD_STRIDE)
        struct.pack_into('<4f', rec, 0, _f32(px + 0.5), _f32(py + 0.5),
                         z_win, _f32(den))
        vary = op.vary
        t3 = ctx['t'] * 3 * RECORD_STRIDE
        for loc in range(8):
            slot = loc + 1
            off = slot * 16
            if op.flat >> loc & 1:
                struct.pack_into('<4I', rec, off,
                                 *struct.unpack_from('<4I', vary, t3 + off))
                continue
            persp = not (op.nopersp >> loc & 1)
            for c in range(4):
                co = t3 + off + c * 4
                if persp:
                    val = sum(lam[k] * struct.unpack_from('<f', vary,
                                    co + k * RECORD_STRIDE)[0] /
                              clip[k][3] for k in range(3)) / den
                else:
                    val = sum(lam[k] * struct.unpack_from('<f', vary,
                                    co + k * RECORD_STRIDE)[0]
                              for k in range(3))
                struct.pack_into('<f', rec, off + c * 4, _f32(val))
        return bytes(rec)

    def advance(self, budget):
        self.last_turn = 0
        tests = 0
        try:
            if self.done:
                return 0
            ntri = self.operation.count // 3
            while not self.done:
                if self.emit_ctx is None:
                    if self.cursor >= ntri:
                        self.done = True
                        break
                    tri = self._tri(self.cursor)
                    self.cursor += 1
                    self.triangles += 1
                    if tri is None:
                        self.degenerate += 1
                        continue
                    if tri == 'culled':
                        self.culled += 1
                        continue
                    self.emit_ctx = self._begin_emit(self.cursor - 1, tri)
                ctx = self.emit_ctx
                while tests < PIXEL_QUANTUM and not self.done:
                    if ctx['py'] >= ctx['y_hi']:
                        self.emit_ctx = None
                        self.steps += 1
                        break
                    rec = self._pixel(ctx, ctx['px'], ctx['py'])
                    self.tests += 1
                    tests += 1
                    ctx['px'] += 1
                    if ctx['px'] >= ctx['x_hi']:
                        ctx['px'] = ctx['x_start']
                        ctx['py'] += 1
                    if rec is not None:
                        if len(self.records) // RECORD_STRIDE >= \
                                self.max_fragments:
                            raise ValueError(
                                'raster fragment budget exhausted')
                        self.records += rec
                        self.fragments += 1
                if tests >= PIXEL_QUANTUM:
                    break
            self.last_turn = tests
            return tests
        except (IndexError, struct.error, OverflowError,
                ZeroDivisionError) as error:
            raise ValueError('raster failed: ' + str(error)) from error

    @property
    def memory(self):
        class _Used:
            pass
        view = _Used()
        view.used = self.last_turn
        return view


@dataclass(frozen=True)
class RasterShade:
    """Rasterize VS-out records then fragment-shade the generated FS-in
    image inside one executor operation.

    Raster fields mirror `Raster`; `code`/`push`/`batch` mirror
    `FragmentShade`.  Helper-invocation lanes are not generated by the
    bounded rasterizer, so `helpers` is always zero.  When the fragment
    module consumes the FrontFacing builtin, all emitted primitives must
    share one facing or the operation faults — per-fragment facing is not
    representable in the current work-record ABI."""
    vary: bytes
    viewport: tuple
    scissor: tuple
    count: int
    code: tuple
    push: tuple = ()
    batch: int = BATCH_MAX
    flat: int = 0
    nopersp: int = 0
    front_ccw: int = 1
    cull: int = 0

    @property
    def size(self):
        return (len(self.vary) +
                min(MAX_FRAGMENTS, self.scissor[2] * self.scissor[3]) *
                RECORD_STRIDE +
                len(self.code) * 4 + len(self.push) * 4 +
                MAX_FRAGMENTS * RECORD_STRIDE)


class RasterShadeRuntime:
    def __init__(self, executor, context, operation):
        if not isinstance(operation, RasterShade):
            raise ValueError('raster shade operation exceeds native profile')
        self.executor, self.context, self.operation = executor, context, operation
        self.raster = RasterRuntime(executor, context, Raster(
            operation.vary, operation.viewport, operation.scissor,
            operation.count, operation.flat, operation.nopersp,
            operation.front_ccw, operation.cull))
        code, push = operation.code, operation.push
        if (not isinstance(code, tuple) or not 5 <= len(code) <= 4096 or
                code[0] != 0x07230203 or
                not isinstance(push, tuple) or len(push) > 32 or
                any(type(w) is not int or not 0 <= w < 1 << 32
                    for w in push) or
                type(operation.batch) is not int or
                not 0 < operation.batch <= BATCH_MAX):
            raise ValueError('raster shade fragment stage exceeds profile')
        try:
            scan = Scanner(list(code)).scan()
        except Exception as error:
            raise ValueError('raster shade scan failed: ' + str(error)) from error
        if scan.em != EM['FRAGMENT']:
            raise ValueError('raster shade requires a fragment execution model')
        for row in scan.decor.values():
            if row.get('binding') is not None or row.get('set') is not None:
                raise ValueError('raster shade descriptor bindings are not admitted')
        self.uses_front = any(
            v.get('storage') == 1 and v.get('builtin') == 17
            for v in scan.vars.values())
        self.owners = dict(self.raster.owners)
        self.fs = None
        self.done = False
        self.last_turn = 0

    def advance(self, budget):
        self.last_turn = 0
        try:
            if self.fs is None:
                used = self.raster.advance(budget)
                self.last_turn = used
                if not self.raster.done:
                    return used
                if not self.raster.records:
                    # culled/degenerate input: no fragments to shade
                    self.done = True
                    return used
                if self.uses_front and len(set(self.raster.fronts)) > 1:
                    raise ValueError(
                        'mixed front-facing exceeds native profile')
                front = self.raster.fronts[0] if self.raster.fronts else 0
                fsop = FragmentShade(bytes(self.raster.records),
                                     self.operation.code,
                                     self.operation.push,
                                     self.operation.batch, 0, front)
                self.fs = FragmentShadeRuntime(
                    self.executor, self.context, fsop)
            used = self.fs.advance(budget)
            self.last_turn = used
            if self.fs.done:
                self.done = True
            return used
        except (IndexError, AssertionError, RecursionError,
                ZeroDivisionError, OverflowError, struct.error) as error:
            raise ValueError('raster shade failed: ' + str(error)) from error

    @property
    def memory(self):
        class _Used:
            pass
        view = _Used()
        view.used = self.last_turn
        return view
