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
    """One bounded raster stage over VS-out records.

    `vary` is the immutable 144-byte-per-vertex VS-out image (Position at
    slot 0, varyings at 16*(1+loc)).  `count` is the vertex record count;
    primitives are consecutive `vpp`-tuples in record order (3 for
    TRIANGLE_LIST, 2 for LINE_LIST; LINE_STRIP chains consecutive pairs
    and POINT_LIST emits per-vertex; indexed draws are already expanded by
    fetch).  `viewport` = (x, y, w, h, minz, maxz)
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
    # rasterizerDiscardEnable: 1 counts triangles but emits zero fragment
    # records (vertex shading already ran upstream), so writeback keeps
    # the attachment clear — matching the RTL rdiscard oracle.
    discard: int = 0
    # optional bounded depth bias (constantFactor, clamp, slopeFactor)
    # fp32 triple: per-triangle the raster stage computes
    # const*r + slope*max|dz|/span, signed-clamps it and adds the result
    # to every fragment's window depth (record offset 8), matching the
    # RTL depth-bias sequence.  None keeps depth unbiased.
    depth_bias: object = None
    # depthClampEnable: 0 drops a fragment whose window depth falls
    # outside the viewport depth range (the near/far clip, approximated
    # per-fragment); 1 clamps the window depth into that range and keeps
    # the fragment.  Bounded to 0/1.
    depth_clamp: int = 0
    # polygonMode: 0 fills each triangle; 1 rasterizes the three edges
    # as independent Bresenham segments; 2 emits one fragment per vertex.
    # Bounded to 0..2 (VkPolygonMode FILL/LINE/POINT).
    poly_mode: int = 0
    # inputAssembly topology: 0 POINT_LIST emits one fragment per vertex;
    # 1 LINE_LIST groups records by two into independent Bresenham
    # segments; 2 LINE_STRIP chains consecutive pairs (shared vertex);
    # 3 TRIANGLE_LIST groups them by three; 4 TRIANGLE_STRIP slides a
    # winding-corrected vertex window; 5 TRIANGLE_FAN anchors every
    # triangle at vertex 0.  Line/point primitives are never face-culled
    # and polygonMode does not apply to them.
    topology: int = 3
    # primitive-restart break positions: a collection of record indices
    # (into `vary`) that are restart sentinels rather than vertices,
    # produced by the fetch stage for indexed draws with
    # primitiveRestartEnable.  When non-empty the raster assembles
    # primitives break-aware via an explicit per-primitive vertex-record
    # table; None/empty keeps the contiguous fast path.  Bounded to the
    # indexed-draw profile (non-indexed draws never carry breaks).
    restarts: object = None
    # per-instance record stride for instanced draws (instanceCount>1):
    # the fetch stage emits count*instances records laid out
    # [instance0: stride][instance1: stride]...; each instance is an
    # independent primitive stream, so the break-aware table resets the
    # accumulator at every stride boundary (the boundary record is kept,
    # unlike a restart sentinel which is skipped).  0/None means a
    # single-instance draw and keeps the contiguous fast path.
    instance_stride: int = 0

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
                not 1 <= operation.count <= MAX_RECORDS or
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
                operation.cull not in (0, 1, 2, 3) or
                operation.discard not in (0, 1)):
            raise ValueError('raster operation exceeds native profile')
        if operation.depth_bias is not None and (
                not isinstance(operation.depth_bias, tuple) or
                len(operation.depth_bias) != 3 or
                any(type(v) is not float or not math.isfinite(v)
                    for v in operation.depth_bias)):
            raise ValueError('raster depth bias exceeds native profile')
        if operation.depth_clamp not in (0, 1):
            raise ValueError('raster depth clamp exceeds native profile')
        if operation.poly_mode not in (0, 1, 2):
            raise ValueError('raster polygon mode exceeds native profile')
        if operation.topology not in (0, 1, 2, 3, 4, 5):
            raise ValueError('raster topology exceeds native profile')
        # Record-addressing stride (records advanced per primitive index)
        # and primitive count per topology:
        #   POINT_LIST(0):     1 record/point, count points
        #   LINE_LIST(1):      2 records/segment, count//2 segments
        #   LINE_STRIP(2):     1 record/segment step (consecutive pairs
        #                      share a vertex), count-1 segments
        #   TRIANGLE_LIST(3):  3 records/triangle, count//3 triangles
        #   TRIANGLE_STRIP(4): sliding vertex window, count-2 triangles
        #   TRIANGLE_FAN(5):   anchor vertex 0 + sliding pair, count-2
        topo = operation.topology
        self.vpp = 1 if topo in (0, 2, 4, 5) else 2 if topo == 1 else 3
        # primitive-restart breaks: a collection of vary-record indices
        # that are sentinels rather than vertices (indexed draws only).
        # When present the raster assembles primitives break-aware; the
        # global record count need not be primitive-aligned because each
        # restart-delimited run is grouped independently.
        restarts = operation.restarts
        if restarts is not None and (
                not isinstance(restarts, (set, frozenset, tuple)) or
                any(type(r) is not int or not 0 <= r < operation.count
                    for r in restarts)):
            raise ValueError('raster restart breaks exceed native profile')
        # per-instance record stride for instanced draws: each instance is
        # an independent primitive stream, so the break-aware table resets
        # the accumulator at every stride boundary.  0 keeps single-instance
        # contiguous assembly.  count is always instances*stride, so the
        # stride must divide the record count evenly.
        istride = operation.instance_stride
        if (type(istride) is not int or istride < 0 or
                istride > operation.count or
                (istride and operation.count % istride)):
            raise ValueError('raster instance stride exceeds native profile')
        self.executor, self.context, self.operation = executor, context, operation
        # primitive-alignment rule shared by both paths; for instanced
        # draws it applies to the per-instance record count (each instance
        # assembles independently).  Restart draws legitimately break
        # alignment via sentinels, so the check is skipped for them.
        def aligned(n):
            if topo == 3:
                return n % 3 == 0 and n >= 3
            if topo == 1:
                return n % 2 == 0 and n >= 2
            if topo in (4, 5):
                return n >= 3
            return n >= 1
        if restarts or istride:
            if not restarts and not aligned(istride):
                raise ValueError('raster vertex count is not primitive-aligned')
            self.prim_records = self._build_prims(
                set(restarts or ()), istride)
            self.nprim = len(self.prim_records)
        else:
            self.prim_records = None
            if not aligned(operation.count):
                raise ValueError('raster vertex count is not primitive-aligned')
            self.nprim = (operation.count if topo == 0 else
                          operation.count - 1 if topo == 2 else
                          operation.count - 2 if topo in (4, 5) else
                          operation.count // self.vpp)
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

    def _build_prims(self, breaks, istride=0):
        """Break/instance-aware primitive assembly.  Splits the record
        stream into runs of vertex records: a restart sentinel closes the
        current run and is skipped (not a vertex); an instance boundary —
        every `istride` records — closes the current run but the boundary
        record is kept as the next instance's first vertex.  Each run is
        then grouped into primitives per topology, identical to the
        contiguous map within a run, so no primitive straddles a restart
        or an instance boundary.  Returns a tuple of per-primitive
        vertex-record-index tuples in draw order."""
        count = self.operation.count
        runs, cur = [], []
        for i in range(count):
            if i in breaks:
                if cur:
                    runs.append(cur)
                    cur = []
                continue
            if istride and i and i % istride == 0 and cur:
                runs.append(cur)
                cur = []
            cur.append(i)
        if cur:
            runs.append(cur)
        prims = []
        for run in runs:
            prims.extend(self._run_prims(run))
        return tuple(prims)

    def _run_prims(self, run):
        """Group one break-free run of vertex record indices into
        primitives for the active topology, preserving slot order (strip
        odd primitives swap slots 1/2; fan anchors slot 0)."""
        topo = self.operation.topology
        n = len(run)
        out = []
        if topo == 0:
            out = [(v,) for v in run]
        elif topo == 1:
            out = [(run[k], run[k + 1]) for k in range(0, n - 1, 2)]
        elif topo == 2:
            out = [(run[k], run[k + 1]) for k in range(n - 1)]
        elif topo == 3:
            out = [(run[k], run[k + 1], run[k + 2])
                   for k in range(0, n - 2, 3)]
        elif topo == 4:
            for k in range(n - 2):
                out.append((run[k], run[k + 2], run[k + 1]) if k & 1
                           else (run[k], run[k + 1], run[k + 2]))
        else:  # topo == 5
            out = [(run[0], run[k + 1], run[k + 2]) for k in range(n - 2)]
        return out

    def _vert_offsets(self, t):
        """Byte offsets into op.vary of primitive t's vertex slots.  The
        raster keeps three slot offsets per primitive; slots a path does
        not read are padded with a valid neighbour offset.  With
        primitive-restart breaks the offsets come from the explicit
        per-primitive vertex-record table; otherwise the contiguous
        topology map applies.  POINT_LIST uses one record per point;
        LINE_LIST packs two records per segment; LINE_STRIP slides one
        vertex per segment; TRIANGLE_LIST packs three; TRIANGLE_STRIP
        slides one vertex per primitive and swaps slots 1/2 on odd prims
        to hold winding; TRIANGLE_FAN anchors slot 0 at vertex 0 and
        slides the (t+1, t+2) pair — mirroring the g6lc_apu_rast f_pi
        topology map."""
        rs = RECORD_STRIDE
        if self.prim_records is not None:
            recs = self.prim_records[t]
            idx = list(recs) + [recs[-1]] * (3 - len(recs))
            return tuple(i * rs for i in idx[:3])
        topo = self.operation.topology
        if topo == 0:
            return t * rs, t * rs, t * rs
        if topo in (1, 2):
            base = t * self.vpp * rs
            return base, base + rs, base + rs
        if topo == 3:
            return t * 3 * rs, (t * 3 + 1) * rs, (t * 3 + 2) * rs
        if topo == 4:
            if t & 1:
                return t * rs, (t + 2) * rs, (t + 1) * rs
            return t * rs, (t + 1) * rs, (t + 2) * rs
        return 0, (t + 1) * rs, (t + 2) * rs

    def _tri(self, t):
        """Screen-space setup for triangle t; mirrors vn_golden coverage."""
        op = self.operation
        vp = op.viewport
        vphw, vphh = _f32(vp[2] * 0.5), _f32(vp[3] * 0.5)
        fma = getattr(math, 'fma', lambda a, b, c: a * b + c)
        verts, clip = [], []
        vo = self._vert_offsets(t)
        for k in range(3):
            rec = op.vary[vo[k]:vo[k] + RECORD_STRIDE]
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

    def _line(self, t):
        """Screen-space setup for LINE_LIST segment t; mirrors the vertex
        transform of _tri but groups two records and skips face culling
        (VkPrimitiveTopology line primitives are never culled).  Returns
        the same tuple shape as _tri with a two-element vx/vy/clip and an
        empty edge list; a zero-length segment is degenerate."""
        op = self.operation
        vp = op.viewport
        vphw, vphh = _f32(vp[2] * 0.5), _f32(vp[3] * 0.5)
        fma = getattr(math, 'fma', lambda a, b, c: a * b + c)
        verts, clip = [], []
        vo = self._vert_offsets(t)
        for k in range(2):
            rec = op.vary[vo[k]:vo[k] + RECORD_STRIDE]
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
        if vx[0] == vx[1] and vy[0] == vy[1]:
            return None
        vp = op.viewport
        x_lo = max(op.scissor[0], int(math.floor(vp[0])))
        x_hi = min(op.scissor[0] + op.scissor[2],
                   int(math.ceil(vp[0] + vp[2])))
        y_lo = max(op.scissor[1], int(math.floor(vp[1])))
        y_hi = min(op.scissor[1] + op.scissor[3],
                   int(math.ceil(vp[1] + vp[3])))
        return vx, vy, [], clip, x_lo, y_lo, x_hi, y_hi

    def _point(self, t):
        """Screen-space setup for a POINT_LIST vertex t; mirrors the vertex
        transform of _line over a single record.  Returns the same tuple
        shape with one-element vx/vy/clip; a non-finite or w<=0 vertex is
        degenerate."""
        op = self.operation
        vp = op.viewport
        vphw, vphh = _f32(vp[2] * 0.5), _f32(vp[3] * 0.5)
        fma = getattr(math, 'fma', lambda a, b, c: a * b + c)
        vo = self._vert_offsets(t)
        rec = op.vary[vo[0]:vo[0] + RECORD_STRIDE]
        x, y, z, w = struct.unpack_from('<4f', rec, 0)
        if not (math.isfinite(x) and math.isfinite(y) and
                math.isfinite(z) and math.isfinite(w)) or w <= 0.0:
            return None
        rcp = _f32(1.0 / _f32(w))
        nx, ny = _f32(_f32(x) * rcp), _f32(_f32(y) * rcp)
        sx = _f32(fma(_f32(nx + 1.0), vphw, _f32(vp[0])))
        sy = _f32(fma(_f32(ny + 1.0), vphh, _f32(vp[1])))
        vx = [_f2i_rne(_f32(sx * 256.0))]
        vy = [_f2i_rne(_f32(sy * 256.0))]
        clip = [(nx, ny, _f32(_f32(z) * rcp), _f32(w))]
        vp = op.viewport
        x_lo = max(op.scissor[0], int(math.floor(vp[0])))
        x_hi = min(op.scissor[0] + op.scissor[2],
                   int(math.ceil(vp[0] + vp[2])))
        y_lo = max(op.scissor[1], int(math.floor(vp[1])))
        y_hi = min(op.scissor[1] + op.scissor[3],
                   int(math.ceil(vp[1] + vp[3])))
        return vx, vy, [], clip, x_lo, y_lo, x_hi, y_hi

    def _depth_bias(self, vx, vy, clip):
        """Per-triangle depth bias mirroring the RTL sequence: the
        constant term is constantFactor*r with r=1.0 for the D32 depth
        format, the slope term is slopeFactor * max|dz|/span where dz is
        the largest window-depth edge delta and span the largest edge
        pixel delta (at least 1); the signed clamp bounds the result and
        it is added to every fragment's window depth."""
        const, clamp, slope = self.operation.depth_bias
        vp = self.operation.viewport
        n = len(clip)
        vz = [vp[4] + clip[k][2] * (vp[5] - vp[4]) for k in range(n)]
        px = [v >> 8 for v in vx]
        py = [v >> 8 for v in vy]
        dz = 0.0
        span = 1
        for i in range(n):
            for j in range(i + 1, n):
                dz = max(dz, abs(vz[i] - vz[j]))
                span = max(span, abs(px[i] - px[j]), abs(py[i] - py[j]))
        term = 0.0 if slope == 0.0 else _f32(_f32(dz / span) * slope)
        bias = _f32(_f32(const) + term)
        if clamp > 0.0:
            bias = min(bias, clamp)
        elif clamp < 0.0:
            bias = max(bias, clamp)
        return bias

    def _begin_emit(self, t, tri):
        vx, vy, edges, clip, x_lo, y_lo, x_hi, y_hi = tri
        dbias = (self._depth_bias(vx, vy, clip)
                 if self.operation.depth_bias is not None else 0.0)
        if self.operation.topology == 0:
            # POINT_LIST: one fragment at the vertex's pixel; a=b=0, t=0
            # makes _poly_pixel yield the vertex's own attributes.
            px, py = vx[0] >> 8, vy[0] >> 8
            items = ([(px, py, 0, 0, 0.0)]
                     if x_lo <= px < x_hi and y_lo <= py < y_hi else [])
            return {'poly': items, 'pidx': 0, 'clip': clip, 't': t,
                    'vpp': self.vpp, 'dbias': dbias,
                    'voffs': self._vert_offsets(t)}
        if self.operation.topology in (1, 2):
            # LINE_LIST/LINE_STRIP: the segment v0->v1 rasterizes as one
            # Bresenham; polygonMode does not apply to line primitives.
            items = []
            for px, py in self._bresenham(vx[0] >> 8, vy[0] >> 8,
                                          vx[1] >> 8, vy[1] >> 8):
                if x_lo <= px < x_hi and y_lo <= py < y_hi:
                    items.append((px, py, 0, 1,
                                  self._line_t(vx, vy, 0, 1, px, py)))
            return {'poly': items, 'pidx': 0, 'clip': clip, 't': t,
                    'vpp': self.vpp, 'dbias': dbias,
                    'voffs': self._vert_offsets(t)}
        if self.operation.poly_mode:
            # polygonMode LINE/POINT: precompute the emit items for this
            # triangle's edges/vertices; _poly_pixel builds each record.
            return {'poly': self._poly_items(tri), 'pidx': 0,
                    'clip': clip, 't': t, 'vpp': 3, 'dbias': dbias,
                    'voffs': self._vert_offsets(t)}
        # start at the pixel containing the triangle's left/top edges
        px = max(x_lo, min(vx) // 256)
        py = max(y_lo, min(vy) // 256)
        return {'t': t, 'px': px, 'py': py, 'x_start': px,
                'x_hi': min(x_hi, max(vx) // 256 + 1),
                'y_hi': min(y_hi, max(vy) // 256 + 1),
                'vx': vx, 'vy': vy, 'edges': edges, 'clip': clip,
                'dbias': dbias, 'voffs': self._vert_offsets(t)}

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
        d_lo = vp[4] if vp[4] <= vp[5] else vp[5]
        d_hi = vp[5] if vp[4] <= vp[5] else vp[4]
        if op.depth_clamp == 0:
            # near/far clip: drop fragments whose window depth is outside
            # the viewport depth range — the fragment-level approximation
            # of polygon clipping against the depth planes (the whole-
            # triangle-beyond-range oracle case yields zero records).
            if z_win < d_lo or z_win > d_hi:
                return None
        else:
            # depthClampEnable=1: no clip; the window depth is clamped
            # into the viewport range before bias and the depth stages.
            z_win = _f32(min(max(z_win, d_lo), d_hi))
        if ctx['dbias']:
            # depth bias is added to the window depth before it feeds the
            # bounds window, the late-z compare and the depth write.
            z_win = _f32(z_win + ctx['dbias'])
        rec = bytearray(RECORD_STRIDE)
        struct.pack_into('<4f', rec, 0, _f32(px + 0.5), _f32(py + 0.5),
                         z_win, _f32(den))
        vary = op.vary
        voffs = ctx['voffs']
        for loc in range(8):
            slot = loc + 1
            off = slot * 16
            if op.flat >> loc & 1:
                struct.pack_into('<4I', rec, off,
                                 *struct.unpack_from('<4I', vary,
                                                     voffs[0] + off))
                continue
            persp = not (op.nopersp >> loc & 1)
            for c in range(4):
                if persp:
                    val = sum(lam[k] * struct.unpack_from('<f', vary,
                                    voffs[k] + off + c * 4)[0] /
                              clip[k][3] for k in range(3)) / den
                else:
                    val = sum(lam[k] * struct.unpack_from('<f', vary,
                                    voffs[k] + off + c * 4)[0]
                              for k in range(3))
                struct.pack_into('<f', rec, off + c * 4, _f32(val))
        return bytes(rec)

    def _bresenham(self, x0, y0, x1, y1):
        """Integer Bresenham over pixel coords, inclusive of both
        endpoints — mirrors vn_golden gfx_line_coverage / RTL S_LN_*."""
        ldx, ldy = abs(x0 - x1), abs(y0 - y1)
        xs = 1 if x0 < x1 else -1
        ys = 1 if y0 < y1 else -1
        lerr = ldx - ldy
        lx, ly = x0, y0
        out = []
        while True:
            out.append((lx, ly))
            if lx == x1 and ly == y1:
                break
            e2 = 2 * lerr
            if e2 > -ldy and e2 < ldx:
                lerr += ldx - ldy
                lx += xs
                ly += ys
            elif e2 > -ldy:
                lerr -= ldy
                lx += xs
            else:
                lerr += ldx
                ly += ys
        return out

    def _line_t(self, vx, vy, a, b, px, py):
        """Line parameter t in [0,1] for pixel (px,py) on edge a->b,
        taken along the dominant screen axis in 16.8 fixed units."""
        ax, ay = vx[a], vy[a]
        dx, dy = vx[b] - ax, vy[b] - ay
        fx, fy = px * 256 + 128, py * 256 + 128
        if abs(dx) >= abs(dy) and dx != 0:
            t = (fx - ax) / dx
        elif dy != 0:
            t = (fy - ay) / dy
        else:
            t = 0.0
        return min(1.0, max(0.0, t))

    def _poly_items(self, tri):
        """Emit items (px, py, a, b, t) for polygonMode LINE/POINT.
        LINE walks the three edges v0->v1->v2->v0 as independent
        Bresenhams; POINT emits each vertex's single pixel.  Items are
        pre-filtered to the coverable domain."""
        vx, vy, edges, clip, x_lo, y_lo, x_hi, y_hi = tri
        items = []
        if self.operation.poly_mode == 2:
            for k in range(3):
                px, py = vx[k] >> 8, vy[k] >> 8
                if x_lo <= px < x_hi and y_lo <= py < y_hi:
                    items.append((px, py, k, k, 0.0))
        else:
            for a in range(3):
                b = (a + 1) % 3
                for px, py in self._bresenham(vx[a] >> 8, vy[a] >> 8,
                                              vx[b] >> 8, vy[b] >> 8):
                    if x_lo <= px < x_hi and y_lo <= py < y_hi:
                        items.append((px, py, a, b,
                                      self._line_t(vx, vy, a, b, px, py)))
        return items

    def _poly_pixel(self, ctx, item):
        """Fragment record for one polygonMode LINE/POINT emit item.
        Attributes interpolate between edge endpoints a->b with weights
        (1-t, t) — POINT degenerates to a=b, t=0 so it yields vertex a's
        own attributes.  Depth, clamp and bias mirror the fill path."""
        px, py, a, b, t = item
        op = self.operation
        clip = ctx['clip']
        ca, cb = clip[a], clip[b]
        wa, wb = 1.0 - t, t
        den = wa / ca[3] + wb / cb[3]
        if den == 0.0:
            self.robust += 1
            return None
        vp = op.viewport
        z_ndc = wa * ca[2] + wb * cb[2]
        z_win = _f32(vp[4] + z_ndc * (vp[5] - vp[4]))
        d_lo = vp[4] if vp[4] <= vp[5] else vp[5]
        d_hi = vp[5] if vp[4] <= vp[5] else vp[4]
        if op.depth_clamp == 0:
            if z_win < d_lo or z_win > d_hi:
                return None
        else:
            z_win = _f32(min(max(z_win, d_lo), d_hi))
        if ctx['dbias']:
            z_win = _f32(z_win + ctx['dbias'])
        rec = bytearray(RECORD_STRIDE)
        struct.pack_into('<4f', rec, 0, _f32(px + 0.5), _f32(py + 0.5),
                         z_win, _f32(den))
        vary = op.vary
        voffs = ctx['voffs']
        ba = voffs[a]
        bb = voffs[b]
        for loc in range(8):
            slot = loc + 1
            off = slot * 16
            if op.flat >> loc & 1:
                # flat varying: the segment-start vertex (edge a),
                # matching the oracle's flat-per-segment colour.
                struct.pack_into('<4I', rec, off,
                                 *struct.unpack_from('<4I', vary,
                                                     ba + off))
                continue
            persp = not (op.nopersp >> loc & 1)
            for c in range(4):
                coa, cob = ba + off + c * 4, bb + off + c * 4
                if persp:
                    val = (wa * struct.unpack_from('<f', vary, coa)[0] /
                           ca[3] + wb * struct.unpack_from('<f', vary,
                           cob)[0] / cb[3]) / den
                else:
                    val = (wa * struct.unpack_from('<f', vary, coa)[0] +
                           wb * struct.unpack_from('<f', vary, cob)[0])
                struct.pack_into('<f', rec, off + c * 4, _f32(val))
        return bytes(rec)

    def advance(self, budget):
        self.last_turn = 0
        tests = 0
        try:
            if self.done:
                return 0
            nprim = self.nprim
            while not self.done:
                if self.emit_ctx is None:
                    if self.cursor >= nprim:
                        self.done = True
                        break
                    if self.operation.topology == 0:
                        prim = self._point(self.cursor)
                    elif self.operation.topology in (1, 2):
                        prim = self._line(self.cursor)
                    else:
                        prim = self._tri(self.cursor)
                    self.cursor += 1
                    self.triangles += 1
                    if self.operation.discard:
                        # rasterizerDiscardEnable: the primitive is counted
                        # but discarded before cull/emit — zero fragments.
                        continue
                    if prim is None:
                        self.degenerate += 1
                        continue
                    if prim == 'culled':
                        self.culled += 1
                        continue
                    self.emit_ctx = self._begin_emit(self.cursor - 1, prim)
                ctx = self.emit_ctx
                if 'poly' in ctx:
                    # polygonMode LINE/POINT: drain the precomputed emit
                    # items for this triangle's edges/vertices.
                    while tests < PIXEL_QUANTUM and not self.done:
                        if ctx['pidx'] >= len(ctx['poly']):
                            self.emit_ctx = None
                            self.steps += 1
                            break
                        rec = self._poly_pixel(ctx, ctx['poly'][ctx['pidx']])
                        ctx['pidx'] += 1
                        self.tests += 1
                        tests += 1
                        if rec is not None:
                            if len(self.records) // RECORD_STRIDE >= \
                                    self.max_fragments:
                                raise ValueError(
                                    'raster fragment budget exhausted')
                            self.records += rec
                            self.fragments += 1
                    if tests >= PIXEL_QUANTUM:
                        break
                    continue
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
