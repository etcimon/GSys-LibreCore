#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Full native draw chain: fetch -> vertex shade -> raster -> fragment shade
-> writeback inside one executor operation; buffer (UBO/SSBO) and
image/sampler descriptors are admitted per stage, an optional float32
late-z depth/stencil (D32 + D24S8) test, bounded UNORM8 RGBA/BGRA blend
(single + per-attachment MRT), colourWriteMask, logicOp, texture sampling
and fragment discard/quad derivatives are forwarded to the fragment and
writeback stages."""
import struct
from dataclasses import dataclass

from shader.spirv_scan import EM, SC, Scanner
from vn_graphics_fetch import Fetch, ATTR_STRIDE
from vn_graphics_pshade import BATCH_MAX, FragmentShade, FragmentShadeRuntime
from vn_graphics_raster import (MAX_FRAGMENTS, Raster, RasterRuntime,
                                 RECORD_STRIDE)
from vn_graphics_shade import Shade, ShadeRuntime, resolve_bindings
from vn_graphics_writeback import Writeback, WritebackRuntime


def _fragment_scan(code):
    if (not isinstance(code, tuple) or not 5 <= len(code) <= 4096 or
            code[0] != 0x07230203):
        raise ValueError('draw fragment stage exceeds native profile')
    try:
        scan = Scanner(list(code)).scan()
    except Exception as error:
        raise ValueError('draw fragment scan failed: ' + str(error)) from error
    if scan.em != EM['FRAGMENT']:
        raise ValueError('draw execution requires a fragment execution model')
    for vid, row in scan.decor.items():
        if row.get('binding') is None and row.get('set') is None:
            continue
        var = scan.vars.get(vid)
        storage = var.get('storage') if var else None
        if storage not in (SC['UNIFORM'], SC['SBUF'], SC['UNIFORMCONST']):
            raise ValueError('draw descriptor storage is not admitted')
    return scan


@dataclass(frozen=True)
class DrawExec:
    """One bounded draw: `fetch` supplies vertex records, `vs`/`fs` are the
    stage code tuples, `push` words are shared per stage is not supported --
    `vs_push`/`fs_push` are separate.  Raster fields mirror `Raster`;
    writeback fields mirror `Writeback`."""
    fetch: Fetch
    vs: tuple
    fs: tuple
    viewport: tuple
    scissor: tuple
    owner: object
    offset: int
    pitch: int
    width: int
    height: int
    fmt: int
    vs_push: tuple = ()
    fs_push: tuple = ()
    vs_bindings: tuple = ()
    fs_bindings: tuple = ()
    batch: int = BATCH_MAX
    flat: int = 0
    nopersp: int = 0
    front_ccw: int = 1
    cull: int = 0
    location: int = 0
    # optional late-z depth test: (owner, offset, pitch, compare_op,
    # write_enable) forwarded verbatim to the Writeback stage; None keeps
    # the colour-only profile unchanged.
    depth: object = None
    # optional depth-bounds window (minDepthBounds, maxDepthBounds) as a
    # pair of fp32 floats forwarded verbatim to the Writeback stage;
    # None disables the bounds reject.
    bounds: object = None
    # optional bounded UNORM8 RGBA/BGRA blend forwarded verbatim to the
    # Writeback stage; None keeps the unblended colour-only profile.
    blend: object = None
    # standalone colourWriteMask gate (VkColorComponentFlag bits) applied
    # by writeback when no blend is present; 15 is the unmasked fast path.
    write_mask: int = 15
    # optional bounded VkLogicOp code (0..14) forwarded to writeback; when
    # set it replaces the blend/write-through colour result (blendEnable=0
    # is enforced upstream).  None keeps the blend/mask/direct profile.
    logic_op: object = None
    # rasterizerDiscardEnable: vertex shading still runs but the raster
    # stage yields zero fragment records, so writeback keeps the clear.
    discard: int = 0
    # optional bounded depth bias (constantFactor, clamp, slopeFactor)
    # forwarded to the raster stage, which folds the per-triangle slope
    # term in and adds the result to each fragment's window depth.
    depth_bias: object = None
    # depthClampEnable forwarded to the raster stage: 0 drops fragments
    # whose window depth is outside the viewport range (near/far clip),
    # 1 clamps the window depth into range instead.
    depth_clamp: int = 0
    # polygonMode forwarded to the raster stage: 0 fills triangles, 1
    # rasterizes each triangle edge as a Bresenham segment, 2 emits one
    # fragment per vertex.
    poly_mode: int = 0
    # inputAssembly topology forwarded to the raster stage: 3
    # TRIANGLE_LIST groups vertices by three; 1 LINE_LIST groups them by
    # two and rasterizes each segment's Bresenham coverage.
    topology: int = 3
    # MRT: additional active colour outputs beyond the primary, each a
    # Writeback.extras-shaped (owner, offset, pitch, fmt, location,
    # write_mask) tuple.  They ride on the single Writeback stage so every
    # attachment shares one late-z depth test per fragment; blend stays
    # refused for multi-output (state admits it only for one attachment).
    extra_targets: tuple = ()
    # depth-stencil storage format forwarded to Writeback: 12 = D32_SFLOAT
    # float32 depth, 14 = D24S8 packed {stencil, depth_unorm24}.  Only
    # meaningful when `depth` is set.
    depth_fmt: int = 12
    # optional bounded stencil state (front_ops, back_ops) where each ops
    # tuple is (failOp, passOp, depthFailOp, compareOp, compareMask,
    # writeMask, reference).  The resolved front-facing picks the face at
    # writeback time; None keeps the depth-only path.
    stencil: object = None
    # per-attachment blend states for MRT attachments 1..N-1, aligned with
    # `extra_targets`: each entry is None (blendEnable=0) or the same
    # 11-tuple as `blend`.  Forwarded verbatim to the Writeback extras.
    blend_extra: object = None

    @property
    def size(self):
        fragments = min(MAX_FRAGMENTS, self.scissor[2] * self.scissor[3])
        return (self.fetch.size + len(self.vs) * 4 + len(self.fs) * 4 +
                len(self.vs_push) * 4 + len(self.fs_push) * 4 +
                fragments * RECORD_STRIDE * 2 +
                self.height * self.pitch +
                sum(self.height * t[2] for t in self.extra_targets))


class DrawExecRuntime:
    def __init__(self, executor, context, operation):
        if not isinstance(operation, DrawExec):
            raise ValueError('draw execution exceeds native profile')
        op = operation
        # eager admission probes: each stage validates its own profile
        # before any work is published (vary/record bytes are placeholders)
        self.shade = ShadeRuntime(executor, context,
                                  Shade(op.fetch, op.vs, op.vs_push,
                                        op.batch, op.vs_bindings))
        scan = _fragment_scan(op.fs)
        # eager binding probe: fragment descriptor operands must validate at
        # admission (coverage + storage), matching the vertex stage, before
        # any fetch/shade/raster work is published
        resolve_bindings(executor, context, op.fs_bindings, scan, 'fragment')
        probe_count = {0: 1, 1: 2, 2: 2}.get(op.topology, 3)
        RasterRuntime(executor, context, Raster(
            b'\0' * (probe_count * RECORD_STRIDE), op.viewport, op.scissor,
            probe_count, op.flat, op.nopersp, op.front_ccw, op.cull,
            op.discard, op.depth_bias, op.depth_clamp, op.poly_mode,
            op.topology))
        # single writeback probe: primary + MRT extras validate together so
        # every attachment's fmt/location/write_mask is admitted before any
        # work is published.
        WritebackRuntime(executor, context, Writeback(
            b'\0' * ATTR_STRIDE, b'\0' * ATTR_STRIDE, 1, op.owner,
            op.offset, op.pitch, op.width, op.height, op.fmt,
            op.location, op.depth, op.blend, op.write_mask, op.logic_op,
            op.bounds, extras=op.extra_targets))
        self.executor, self.context, self.operation = executor, context, op
        self.uses_front = any(
            v.get('storage') == 1 and v.get('builtin') == 17
            for v in scan.vars.values())
        self.raster = self.fs = self.wb = None
        self._front = 0
        self._gate = False
        # shade owners (fetch buffers) plus every writeback destination
        # must be pinned at enqueue time, before the first advance
        self.owners = dict(self.shade.owners)
        self.owners[id(op.owner)] = op.owner
        for xowner, _xo, _xp, _xf, _xl, _xw in op.extra_targets:
            self.owners[id(xowner)] = xowner
        if op.depth is not None:
            self.owners[id(op.depth[0])] = op.depth[0]
        self.done = False
        self.last_turn = 0

    def _chain(self):
        """Advance the stage pipeline; construct the next runtime when the
        previous stage completes.  Returns True while work remains."""
        op = self.operation
        if not self.shade.done:
            return True
        if self.raster is None:
            count = self.shade.fetch.records_done
            # fetch.breaks lists the record indices that are restart
            # sentinels (indexed draws with primitiveRestartEnable); the
            # raster assembles primitives break-aware when non-empty.
            restarts = (frozenset(self.shade.fetch.breaks)
                        if self.shade.fetch.breaks else None)
            # instanced draws (instanceCount>1) emit count*instances
            # records; each instance is an independent primitive stream,
            # so the raster resets assembly every `count` records.  The
            # per-instance count is fetch.args[0] (resolved for indirect
            # draws by the time fetch retires).
            fargs = self.shade.fetch.args
            istride = fargs[0] if fargs and fargs[1] > 1 else 0
            self.raster = RasterRuntime(self.executor, self.context,
                                        Raster(bytes(self.shade.vary),
                                               op.viewport, op.scissor,
                                               count, op.flat, op.nopersp,
                                               op.front_ccw, op.cull,
                                               op.discard,
                                               op.depth_bias,
                                               op.depth_clamp,
                                               op.poly_mode,
                                               op.topology, restarts,
                                               istride))
            return True
        if not self.raster.done:
            return True
        if not self.raster.records:
            # culled/degenerate draw: no fragments, nothing left to run
            self.done = True
            return False
        if self.fs is None:
            if self.uses_front and len(set(self.raster.fronts)) > 1:
                raise ValueError(
                    'mixed front-facing exceeds native profile')
            front = self.raster.fronts[0] if self.raster.fronts else 0
            self._front = front
            count = len(self.raster.records) // RECORD_STRIDE
            self.fs = FragmentShadeRuntime(self.executor, self.context,
                                           FragmentShade(
                                               bytes(self.raster.records),
                                               op.fs, op.fs_push,
                                               op.batch, 0, front,
                                               op.fs_bindings))
            return True
        if not self.fs.done:
            return True
        if self.wb is None:
            op = self.operation
            # writeback pairs each FS-in FragCoord with its FS-out colour;
            # the fragment stage may have reordered records into quad order
            # (and grown helper lanes) for derivative shaders, so feed it
            # the same effective record image it consumed.
            count = self.fs.total
            records = self.fs.operation.records
            colors = bytes(self.fs.color)
            # one writeback stage carries the primary attachment plus every
            # MRT extra so all targets share a single late-z depth/stencil
            # test per fragment; extras write under the shared
            # depth/bounds/logicOp gates with their own writeMask and
            # optional per-attachment blend.
            # select the front/back VkStencilOpState face from the resolved
            # front-facing (uniform per draw — mixed facing is refused).
            stencil = None
            if op.stencil is not None:
                stencil = op.stencil[0 if self._front else 1]
            self.wb = WritebackRuntime(self.executor, self.context,
                                       Writeback(
                                           records, colors, count,
                                           op.owner, op.offset, op.pitch,
                                           op.width, op.height, op.fmt,
                                           op.location, op.depth,
                                           op.blend, op.write_mask,
                                           op.logic_op, op.bounds,
                                           extras=op.extra_targets,
                                           depth_fmt=op.depth_fmt,
                                           stencil=stencil,
                                           blend_extra=op.blend_extra))
            return True
        return not self.wb.done

    def advance(self, budget):
        self.last_turn = 0
        try:
            if self.done:
                return 0
            if not self._gate:
                # conditional rendering: the predicate word is re-read
                # once per draw command (the spec's per-command model);
                # a zero word discards the whole draw at its stream
                # position with no stage work published
                self._gate = True
                gate = self.executor.cond.get(id(self.context))
                if gate is not None:
                    addr, inverted = gate
                    word = int.from_bytes(
                        self.executor.execution.state.aperture.read(
                            addr, 4), 'little')
                    if not ((word != 0) ^ bool(inverted)):
                        self.done = True
                        return 0
            while self._chain():
                stage = next((s for s in (self.shade, self.raster,
                                          self.fs)
                              if s is not None and not s.done), None)
                if stage is not None:
                    used = stage.advance(budget)
                    self.last_turn = used
                    if not stage.done:
                        return used
                    continue
                # writeback phase: the single stage drains all attachment
                # targets per fragment under one shared depth test
                if self.wb is not None and not self.wb.done:
                    used = self.wb.advance(budget)
                    self.last_turn = used
                    if not self.wb.done:
                        return used
            self.done = True
            return self.last_turn
        except (IndexError, AssertionError, RecursionError,
                ZeroDivisionError, OverflowError, struct.error) as error:
            raise ValueError('draw execution failed: ' + str(error)) from error

    @property
    def memory(self):
        class _Used:
            pass
        view = _Used()
        view.used = self.last_turn
        return view
