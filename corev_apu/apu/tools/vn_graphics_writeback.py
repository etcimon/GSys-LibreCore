#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded fragment writeback to one or more colour attachments plus an
optional float32/D24S8 late-z depth-stencil attachment and an optional
bounded UNORM8 RGBA/BGRA blend.  `extras` carries additional MRT targets
written atomically per fragment under the single shared depth/stencil/
bounds/logicOp gate; `blend_extra` gives each extra its own per-attachment
blend state so every target blends against its own stored dst."""
import math
import struct
from dataclasses import dataclass

import vn_golden
from vn_graphics_fetch import ATTR_STRIDE
from vn_graphics_raster import MAX_FRAGMENTS

WRITE_QUANTUM = 4096            # fragment writes per cooperative turn


def _depth_pass(op, frag, stored):
    """VkCompareOp depth test: fragment passes when frag <op> stored."""
    if op == 0:
        return False                     # NEVER
    if op == 1:
        return frag < stored             # LESS
    if op == 2:
        return frag == stored            # EQUAL
    if op == 3:
        return frag <= stored            # LESS_OR_EQUAL
    if op == 4:
        return frag > stored             # GREATER
    if op == 5:
        return frag != stored            # NOT_EQUAL
    if op == 6:
        return frag >= stored            # GREATER_OR_EQUAL
    return True                          # ALWAYS (7)


# blend dst decode: the stored UNORM8 byte dequantizes as u8*K255 where
# K255 is the fp32 constant 0x3B808081 (~1/255), matching the RTL oracle.
_BLEND_K255 = struct.unpack('<f', struct.pack('<I', 0x3B808081))[0]


def _f32(x):
    """Round a Python float to the nearest fp32 value (RTL f32 domain)."""
    return struct.unpack('<f', struct.pack('<f', x))[0]


def _blend_factor(f, c, sv, dv, konst):
    """VkBlendFactor `f` evaluated for channel `c` (0..3).  `sv`/`dv` are
    the fp32 src/dst component vectors, `konst` the four fp32 blend
    constants.  Mirrors the RTL blend oracle: colour/alpha constants read
    per-channel konst[c]; ONE_MINUS factors complement the base."""
    if f == 0:
        return 0.0                        # ZERO
    if f == 1:
        return 1.0                        # ONE
    if f in (2, 3):
        b = sv[c]                         # SRC_COLOR / 1M_SRC_COLOR
    elif f in (4, 5):
        b = dv[c]                         # DST_COLOR / 1M_DST_COLOR
    elif f in (6, 7):
        b = sv[3]                         # SRC_ALPHA / 1M_SRC_ALPHA
    elif f in (8, 9):
        b = dv[3]                         # DST_ALPHA / 1M_DST_ALPHA
    elif f == 14:
        # SRC_ALPHA_SATURATE: colour channels min(srcA, 1-dstA); the alpha
        # channel itself blends with factor 1.
        return 1.0 if c == 3 else _f32(min(sv[3], _f32(1.0 - dv[3])))
    else:
        b = konst[c]                      # CONSTANT_* / 1M_CONSTANT_*
    return _f32(1.0 - b) if f in (3, 5, 7, 9, 11, 13) else b


def _blend_op(op, a, b):
    """VkBlendOp on the two fp32 products; MIN/MAX compare in f32."""
    if op == 0:
        return _f32(a + b)                # ADD
    if op == 1:
        return _f32(a - b)                # SUBTRACT
    if op == 2:
        return _f32(b - a)                # REVERSE_SUBTRACT
    if op == 3:
        return a if a < b else b          # MIN
    return a if b < a else b              # MAX


def _lop(op, s, d):
    """VkLogicOp `op` (CLEAR..SET, 0..14) on the UNORM8 src/dst bytes —
    the 16-case table mirrors the RTL rast.sv f_lop exactly."""
    return ((0x00, s & d, s & (~d & 0xFF), s, (~s & 0xFF) & d,
             d, s ^ d, s | d, (~(s | d)) & 0xFF, (~(s ^ d)) & 0xFF,
             (~d) & 0xFF, s | (~d & 0xFF), (~s & 0xFF) | d,
             (~(s & d)) & 0xFF, 0xFF)[op])


def _stencil_op(op, old, ref, wmask):
    """VkStencilOp `op` (KEEP..DECR_WRAP, 0..7) evaluated on the full `old`
    stencil byte against `ref`, then the writeMask selects per-bit between
    the old byte and the op result — f_sop's (oldb&~mask)|(n&mask)."""
    if op == 0:
        res = old                            # KEEP
    elif op == 1:
        res = 0                              # ZERO
    elif op == 2:
        res = ref                            # REPLACE
    elif op == 3:
        res = 0xFF if old == 0xFF else old + 1   # INCR_SAT
    elif op == 4:
        res = 0 if old == 0 else old - 1        # DECR_SAT
    elif op == 5:
        res = (~old) & 0xFF                  # INVERT
    elif op == 6:
        res = (old + 1) & 0xFF               # INCR_WRAP
    else:
        res = (old - 1) & 0xFF               # DECR_WRAP
    return (old & (0xFF ^ wmask)) | (res & wmask)


def _pack_ds(stencil, depth_u24):
    """Pack a D24S8 word {stencil[31:24], depth_unorm24[23:0]}."""
    return ((stencil & 0xFF) << 24) | (depth_u24 & 0xFFFFFF)


def _parse_blend(b, fmt):
    """Validate an 11-field VkPipelineColorBlendAttachmentState blend
    tuple for device format `fmt` and return the runtime 8-tuple
    (srcColor, dstColor, colorOp, srcAlpha, dstAlpha, alphaOp, writeMask,
    konst) with konst unpacked to fp32.  Bounded to the UNORM8 four-
    component outputs (device fmt 2 / fmt 4)."""
    if (not isinstance(b, tuple) or len(b) != 11 or
            any(type(x) is not int or not 0 <= x <= 14 for x in b[:2]) or
            any(type(x) is not int or not 0 <= x <= 4
                for x in (b[2], b[5])) or
            any(type(x) is not int or not 0 <= x <= 14 for x in b[3:5]) or
            type(b[6]) is not int or not 0 <= b[6] <= 15 or
            any(type(k) is not int or not 0 <= k <= 0xFFFFFFFF
                for k in b[7:11])):
        raise ValueError('writeback blend exceeds native profile')
    if fmt not in (2, 4):
        raise ValueError('writeback blend format exceeds native profile')
    konst = tuple(struct.unpack('<f', struct.pack('<I', k))[0]
                  for k in b[7:11])
    return (b[0], b[1], b[2], b[3], b[4], b[5], b[6], konst)


@dataclass(frozen=True)
class Writeback:
    """ROP stage: FS-in FragCoord records + FS-out color records -> one
    color attachment.  `inputs`/`colors` are immutable 144-byte record
    images of equal `count`; `owner`/`offset`/`pitch`/`width`/`height`
    describe the destination span and `fmt` the device format id.
    `location` selects the FS-out color slot (0..7).

    `depth` is an optional late-z depth test: when not None it is a
    `(owner, offset, pitch, compare_op, write_enable)` tuple describing a
    float32 depth attachment sharing the colour `width`/`height`.  Each
    covered fragment's window-space `z_win` (record offset 8) is compared
    against the stored depth; a failing compare drops BOTH the colour and
    depth writes, a passing compare writes colour unconditionally and
    depth only when `write_enable`.  `compare_op` is the VkCompareOp
    code (0 NEVER .. 7 ALWAYS).

    `blend` is an optional bounded blend for the single UNORM8 RGBA/BGRA
    (device fmt 2 / fmt 4) colour output: `(srcColorFactor, dstColorFactor,
    colorOp, srcAlphaFactor, dstAlphaFactor, alphaOp, writeMask, k0, k1,
    k2, k3)` where the factors are raw VkBlendFactor codes (0..14), the
    ops are VkBlendOp (0..4) and k0..k3 the fp32 blendConstants words.
    Each passing fragment reads the stored dst texel (dequantized as
    u8*K255), evaluates the colour factors on channels 0..2 and the alpha
    factors on channel 3, applies the blend op and gates channels by
    writeMask — matching the RTL blend oracle.

    `write_mask` is the standalone colourWriteMask gate applied when no
    blend is present (`blend is None`): a 4-bit mask (VkColorComponentFlag
    R=1,G=2,B=4,A=8) where a clear bit keeps the stored dst byte for that
    logical channel.  Bounded to the same UNORM8 four-component outputs
    (device fmt 2 / fmt 4) as blend so the byte merge reuses `cmap`;
    `15` keeps the unmasked write-through fast path with no dst read.

    `logic_op` is an optional VkLogicOp code (0..14 CLEAR..SET) replacing
    the colour result when set: per-channel `f_lop` on the UNORM8 src/dst
    byte encodings via `cmap`, bounded to the same device fmt 2 / fmt 4
    outputs.  It takes precedence over `blend`/`write_mask` upstream
    (blendEnable is enforced 0), matching the RTL logicOp oracle."""
    inputs: bytes
    colors: bytes
    count: int
    owner: object
    offset: int
    pitch: int
    width: int
    height: int
    fmt: int
    location: int = 0
    depth: object = None
    blend: object = None
    write_mask: int = 15
    logic_op: object = None
    # optional depth-bounds window (minDepthBounds, maxDepthBounds) as a
    # pair of fp32 floats: a covered fragment whose window-space depth
    # falls outside [min, max] is discarded before colour/depth write.
    # Independent of `depth` (the compare test); None disables it.
    bounds: object = None
    # optional MRT extra colour targets: a tuple of
    # (owner, offset, pitch, fmt, location, write_mask) entries, one per
    # additional active subpass attachment beyond the primary.  Every
    # target shares the single late-z depth test/bounds/logicOp gate, so a
    # fragment either writes all attachments or none — the only ordering
    # that keeps the shared depth buffer consistent.  Per-attachment blend
    # rides on `blend_extra` (each target blends against its own dst).
    extras: tuple = ()
    # depth-stencil storage format: 12 = D32_SFLOAT float32 depth (the
    # existing path); 14 = D24S8 packed {stencil[31:24], depth_unorm24[23:0]}
    # where depth is a 24-bit unorm and the high byte is the stencil.  Only
    # meaningful when `depth` is set.
    depth_fmt: int = 12
    # optional bounded stencil state for a fmt-14 depth-stencil attachment:
    # (failOp, passOp, depthFailOp, compareOp, compareMask, writeMask,
    # reference) — the selected face's VkStencilOpState plus the pipeline
    # stencil compare/write masks and reference.  Stencil compare runs
    # before the depth test; a fail applies failOp and discards the
    # fragment, a depth-fail applies depthFailOp and discards, and a pass
    # applies passOp then writes colour + depth.  None keeps depth-only.
    stencil: object = None
    # per-attachment blend states for MRT extras, aligned with `extras`:
    # each entry is None (blendEnable=0) or the same 11-tuple as `blend`.
    # Lets every colour attachment blend against its own stored dst under
    # the shared late-z/bounds/logicOp gate.  None keeps extras unblended.
    blend_extra: object = None

    @property
    def size(self):
        return (len(self.inputs) + len(self.colors) +
                self.height * self.pitch +
                sum(self.height * e[2] for e in self.extras))


class WritebackRuntime:
    def __init__(self, executor, context, operation):
        if (not isinstance(operation, Writeback) or
                type(operation.inputs) is not bytes or
                type(operation.colors) is not bytes or
                not operation.inputs or
                len(operation.inputs) != len(operation.colors) or
                len(operation.inputs) % ATTR_STRIDE or
                type(operation.count) is not int or
                not 0 < operation.count <= MAX_FRAGMENTS or
                operation.count * ATTR_STRIDE != len(operation.inputs) or
                type(operation.offset) is not int or operation.offset < 0 or
                type(operation.pitch) is not int or
                not 0 < operation.pitch <= 1 << 22 or
                type(operation.width) is not int or
                not 0 < operation.width <= 4096 or
                type(operation.height) is not int or
                not 0 < operation.height <= 4096 or
                type(operation.fmt) is not int or
                not 0 <= operation.fmt < 16 or
                type(operation.location) is not int or
                not 0 <= operation.location < 8 or
                type(operation.write_mask) is not int or
                not 0 <= operation.write_mask <= 15):
            raise ValueError('writeback operation exceeds native profile')
        self.executor, self.context, self.operation = executor, context, operation
        model = executor.execution.model
        _names, _v2d, bpp, _attr = model.img_fmt_tables()
        if not bpp[operation.fmt]:
            raise ValueError('writeback format has no bytes-per-pixel')
        self.bpp = bpp[operation.fmt]
        span = ((operation.height - 1) * operation.pitch +
                operation.width * self.bpp)
        self.base = executor._extent(context, operation.owner,
                                     operation.offset, span)
        self.owners = {id(operation.owner): operation.owner}
        self.dbase = self.dpitch = self.dop = self.dwrite = None
        if operation.depth is not None:
            d = operation.depth
            if (not isinstance(d, tuple) or len(d) != 5 or
                    type(d[1]) is not int or d[1] < 0 or
                    type(d[2]) is not int or
                    not 0 < d[2] <= 1 << 22 or
                    type(d[3]) is not int or not 0 <= d[3] <= 7 or
                    type(d[4]) is not int or d[4] not in (0, 1) or
                    d[2] < operation.width * 4):
                raise ValueError('writeback depth exceeds native profile')
            dspan = ((operation.height - 1) * d[2] +
                     operation.width * 4)
            self.dbase = executor._extent(context, d[0], d[1], dspan)
            self.dpitch = d[2]
            self.dop = d[3]
            self.dwrite = d[4]
            self.owners[id(d[0])] = d[0]
        # depth-stencil format + optional stencil ops.  fmt 14 (D24S8) is the
        # packed path; fmt 12 keeps the float32 D32 path.  Stencil requires a
        # fmt-14 attachment and the packed word's stencil byte.
        self.depth_fmt = operation.depth_fmt
        self.stencil = None
        if self.depth_fmt not in (12, 14):
            raise ValueError('writeback depth format exceeds profile')
        if operation.stencil is not None:
            s = operation.stencil
            if (self.dbase is None or self.depth_fmt != 14 or
                    not isinstance(s, tuple) or len(s) != 7 or
                    any(type(v) is not int for v in s) or
                    not 0 <= s[0] <= 7 or not 0 <= s[1] <= 7 or
                    not 0 <= s[2] <= 7 or not 0 <= s[3] <= 7 or
                    not 0 <= s[4] <= 0xFF or not 0 <= s[5] <= 0xFF or
                    not 0 <= s[6] <= 0xFF):
                raise ValueError('writeback stencil exceeds profile')
            self.stencil = s
        elif self.depth_fmt == 14 and self.dbase is None:
            raise ValueError('writeback stencil format needs depth')
        self.blend = None
        if operation.blend is not None:
            self.blend = _parse_blend(operation.blend, operation.fmt)
        # standalone colourWriteMask (blendEnable=0): a clear mask bit keeps
        # the stored dst byte for that logical channel.  The byte merge
        # needs the UNORM8 component map, so it is bounded to the same
        # device fmt 2 / fmt 4 outputs as blend; 15 keeps the fast path.
        self.wmask = operation.write_mask
        if (self.blend is None and self.wmask != 15 and
                operation.fmt not in (2, 4)):
            raise ValueError('writeback write-mask format exceeds profile')
        # bounded logicOp: the f_lop byte table needs the UNORM8 component
        # map, so it is bounded to the same device fmt 2 / fmt 4 outputs.
        self.logic_op = operation.logic_op
        if self.logic_op is not None and (
                type(self.logic_op) is not int or
                not 0 <= self.logic_op <= 14 or
                operation.fmt not in (2, 4)):
            raise ValueError('writeback logicOp exceeds native profile')
        # component c -> texel byte position (BGRA swaps comps 0/2),
        # mirroring img_clear_texel's `cj` selection; shared by the blend
        # dst decode and the standalone mask merge.
        self.cmap = None
        if operation.fmt in (2, 4):
            at = self.executor.execution.model.img_fmt_tables()[3][
                operation.fmt]
            self.cmap = tuple(2 - c if (at & 0x40 and c < 3) else c
                              for c in range(4))
        # bounded depth-bounds window: (minDepthBounds, maxDepthBounds)
        # fp32 pair; a covered fragment outside [min, max] is dropped.
        self.bounds = None
        if operation.bounds is not None:
            b = operation.bounds
            if (not isinstance(b, tuple) or len(b) != 2 or
                    any(type(v) is not float or not math.isfinite(v)
                        for v in b) or not b[0] <= b[1]):
                raise ValueError('writeback depth bounds exceeds profile')
            self.bounds = b
        # per-attachment blend for the MRT extras, aligned with `extras`:
        # each entry is None (blendEnable=0) or an 11-tuple parsed against
        # that target's own device format.
        xblends = ()
        if operation.blend_extra is not None:
            if (not isinstance(operation.blend_extra, tuple) or
                    len(operation.blend_extra) != len(operation.extras)):
                raise ValueError('writeback extra blend exceeds profile')
            xblends = tuple(
                _parse_blend(b, e[3]) if b is not None else None
                for b, e in zip(operation.blend_extra, operation.extras))
        # MRT targets: index 0 is the primary attachment (with its blend /
        # writeMask / cmap already resolved above); each extra contributes
        # (base, pitch, bpp, fmt, loc_off, cmap, wmask) for the shared
        # per-fragment colour write.  The depth/bounds/logicOp gate stays
        # single and shared, so all attachments observe identical coverage.
        self.targets = [(self.base, operation.pitch, self.bpp,
                         operation.fmt, operation.location * 16,
                         self.cmap, self.wmask, self.blend)]
        for xi, e in enumerate(operation.extras):
            if (not isinstance(e, tuple) or len(e) != 6 or
                    type(e[1]) is not int or e[1] < 0 or
                    type(e[2]) is not int or
                    not 0 < e[2] <= 1 << 22 or
                    type(e[3]) is not int or not 0 <= e[3] < 16 or
                    type(e[4]) is not int or not 0 <= e[4] < 8 or
                    type(e[5]) is not int or not 0 <= e[5] <= 15):
                raise ValueError('writeback extra target exceeds profile')
            xowner, xoffset, xpitch, xfmt, xloc, xwmask = e
            xbpp = bpp[xfmt]
            if not xbpp:
                raise ValueError('writeback extra format has no bytes-per-pixel')
            xtblend = xblends[xi] if xi < len(xblends) else None
            if (xtblend is None and xwmask != 15 and xfmt not in (2, 4)):
                raise ValueError('writeback extra write-mask format exceeds profile')
            if (self.logic_op is not None and xfmt not in (2, 4)):
                raise ValueError('writeback extra logicOp format exceeds profile')
            if xtblend is not None and xfmt not in (2, 4):
                raise ValueError('writeback extra blend format exceeds profile')
            xspan = ((operation.height - 1) * xpitch +
                     operation.width * xbpp)
            xbase = executor._extent(context, xowner, xoffset, xspan)
            xcmap = None
            if xfmt in (2, 4):
                at = model.img_fmt_tables()[3][xfmt]
                xcmap = tuple(2 - c if (at & 0x40 and c < 3) else c
                              for c in range(4))
            self.targets.append((xbase, xpitch, xbpp, xfmt, xloc * 16,
                                 xcmap, xwmask, xtblend))
            self.owners[id(xowner)] = xowner
        self.cursor = self.written = self.dropped = self.steps = 0
        self.done = False
        self.last_turn = 0
        self.golden = executor.execution.golden

    def advance(self, budget):
        self.last_turn = 0
        written = 0
        try:
            if self.done:
                return 0
            op = self.operation
            memory = self.executor.execution.state.aperture
            quantum = self.cursor + WRITE_QUANTUM
            end = min(quantum, op.count)
            while self.cursor < end:
                if not self.executor._live(self.context):
                    raise KeyError('writeback context retired during work')
                i = self.cursor * ATTR_STRIDE
                fx, fy = struct.unpack_from('<2f', op.inputs, i)
                px, py = int(fx), int(fy)
                self.cursor += 1
                self.steps += 1
                if (fx < 0.0 or fy < 0.0 or
                        not (0 <= px < op.width and 0 <= py < op.height)):
                    self.dropped += 1
                    continue
                daddr = z_win = ds_word = None
                if self.bounds is not None or self.dbase is not None:
                    # window-space z_win (record offset 8) feeds both the
                    # depth-bounds window and the late-z depth compare.
                    z_win = struct.unpack_from('<f', op.inputs, i + 8)[0]
                if (self.bounds is not None and
                        not self.bounds[0] <= z_win <= self.bounds[1]):
                    # depth-bounds reject: window depth outside [min,max]
                    # drops the colour and any depth write for this frag.
                    self.dropped += 1
                    continue
                if struct.unpack_from('<I', op.colors, i + 132)[0] & 1:
                    # FS-out slot-8 flags bit0: an fs_late module marked
                    # this lane dead via OpKill/TerminateInvocation or
                    # DemoteToHelperInvocation — the fragment writes no
                    # colour, depth or stencil on any target.
                    self.dropped += 1
                    continue
                if self.dbase is not None:
                    daddr = self.dbase + py * self.dpitch + px * 4
                    if self.depth_fmt == 14:
                        # packed D24S8 {stencil[31:24], depth_unorm24[23:0]}:
                        # stencil compare runs before the depth test; a
                        # stencil fail applies failOp and a depth fail
                        # applies depthFailOp — both discard the fragment
                        # (no colour, no depth write) but still commit the
                        # updated stencil byte with the stored depth kept.
                        word = int.from_bytes(memory.read(daddr, 4),
                                              'little')
                        dst_u24 = word & 0xFFFFFF
                        st_old = (word >> 24) & 0xFF
                        z_u24 = vn_golden.cl_f32_u24(
                            struct.unpack('<I', struct.pack('<f',
                                                             z_win))[0])
                        dpass = _depth_pass(self.dop, z_u24, dst_u24)
                        if self.stencil is not None:
                            fail_op, pass_op, dfail_op, cmp_op, cmask, \
                                wmask, ref = self.stencil
                            if not _depth_pass(cmp_op, st_old & cmask,
                                               ref & cmask):
                                memory.write(daddr, struct.pack(
                                    '<I', _pack_ds(
                                        _stencil_op(fail_op, st_old, ref,
                                                    wmask), dst_u24)))
                                self.dropped += 1
                                continue
                            if not dpass:
                                memory.write(daddr, struct.pack(
                                    '<I', _pack_ds(
                                        _stencil_op(dfail_op, st_old, ref,
                                                    wmask), dst_u24)))
                                self.dropped += 1
                                continue
                            ds_word = _pack_ds(
                                _stencil_op(pass_op, st_old, ref, wmask),
                                z_u24 if self.dwrite else dst_u24)
                        else:
                            if not dpass:
                                self.dropped += 1
                                continue
                            # depth-only on fmt14: the stencil byte is
                            # preserved; depth commits only when enabled.
                            if self.dwrite:
                                ds_word = _pack_ds(st_old, z_u24)
                    else:
                        # late-z: window-space z_win vs the stored float32
                        # depth; a failing compare drops both writes.
                        stored = struct.unpack('<f', memory.read(daddr,
                                                                 4))[0]
                        if not _depth_pass(self.dop, z_win, stored):
                            self.dropped += 1
                            continue
                # MRT: write every active colour attachment for this
                # fragment under the single shared depth/bounds gate —
                # the only ordering that keeps the late-z depth buffer
                # consistent (a second sequential pass would re-test
                # against depth the first pass already updated).
                for tbase, tpitch, tbpp, tfmt, tloff, tcmap, twmask, \
                        tblend in self.targets:
                    words = struct.unpack_from('<4I', op.colors,
                                               i + tloff)
                    caddr = tbase + py * tpitch + px * tbpp
                    if self.logic_op is not None:
                        self._logic_write(memory, caddr, words,
                                          tcmap, twmask)
                    elif tblend is not None:
                        self._blend_write(memory, caddr, words,
                                          tblend, tcmap)
                    else:
                        texel = vn_golden.img_clear_texel(
                            self.executor.execution.model, tfmt, words)
                        if twmask != 15:
                            dst = memory.read(caddr, tbpp)
                            texel = self._mask_merge(texel, dst,
                                                     tcmap, twmask)
                        memory.write(caddr, texel)
                if self.depth_fmt == 14:
                    if ds_word is not None:
                        memory.write(daddr, struct.pack('<I', ds_word))
                elif self.dwrite:
                    memory.write(daddr, struct.pack('<f', z_win))
                self.written += 1
                written += 1
            if self.cursor >= op.count:
                self.done = True
            self.last_turn = written
            return written
        except (IndexError, struct.error, OverflowError,
                ZeroDivisionError, OSError) as error:
            raise ValueError('writeback failed: ' + str(error)) from error

    def _blend_write(self, memory, caddr, words, blend, cmap):
        """Bounded UNORM8 RGBA/BGRA blend for one covered fragment on one
        attachment.  Reads the stored dst texel (dequantized u8*K255),
        evaluates colour factors on channels 0..2 and alpha factors on
        channel 3, applies the blend op and keeps the dst byte on
        writeMask-clear channels.  `blend`/`cmap` are the target's own."""
        sf, df, cop, saf, daf, aop, mask, konst = blend
        dst = memory.read(caddr, 4)
        # dv[c] is logical component c dequantized from its texel byte;
        # cmap handles the BGRA byte permutation.
        dv = [_f32(dst[cmap[c]] * _BLEND_K255) for c in range(4)]
        sv = [struct.unpack('<f', struct.pack('<I', w))[0]
              for w in words]
        out = bytearray(4)
        for c in range(4):
            if c < 3:
                s_f, d_f, bop = sf, df, cop
            else:
                s_f, d_f, bop = saf, daf, aop
            sfv = _blend_factor(s_f, c, sv, dv, konst)
            dfv = _blend_factor(d_f, c, sv, dv, konst)
            res = _blend_op(bop, _f32(sv[c] * sfv), _f32(dv[c] * dfv))
            p = cmap[c]
            if (mask >> c) & 1:
                out[p] = vn_golden.cl_f32_u8(
                    struct.unpack('<I', struct.pack('<f', res))[0])
            else:
                out[p] = dst[p]
        memory.write(caddr, bytes(out))

    def _mask_merge(self, texel, dst, cmap, wmask):
        """Standalone colourWriteMask merge for one covered fragment.
        `texel` is the packed src output of img_clear_texel and `dst` the
        stored bpp-byte texel; a clear mask bit keeps the dst byte at the
        logical channel's cmap position (BGRA-aware)."""
        out = bytearray(texel)
        for c in range(4):
            if not (wmask >> c) & 1:
                out[cmap[c]] = dst[cmap[c]]
        return bytes(out)

    def _logic_write(self, memory, caddr, words, cmap, wmask):
        """Bounded logicOp for one covered fragment: per-channel f_lop on
        the UNORM8 src/dst byte encodings (cmap handles BGRA), with the
        standalone writeMask gating each channel's dst byte."""
        dst = memory.read(caddr, 4)
        out = bytearray(4)
        for c in range(4):
            p = cmap[c]
            if (wmask >> c) & 1:
                out[p] = _lop(self.logic_op,
                              vn_golden.cl_f32_u8(words[c]), dst[p])
            else:
                out[p] = dst[p]
        memory.write(caddr, bytes(out))

    @property
    def memory(self):
        class _Used:
            pass
        view = _Used()
        view.used = self.last_turn
        return view
