#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""vn_golden.py — golden Venus-wire encoder + VnDec ROM simulator.

Encodes a Vulkan command exactly like Mesa's generated vn_encode_vk* driver
code (venus-protocol wire format 1), simulates the generated
APU_VN_DEC_ROM micro-program over the stream, and emits the expected
`apu_vn_op_t` record the RTL must produce.

Modes:
  --selftest            encode+decode round-trip for every command in the set
  --vectors NAME SEED   emit verif/tb/apu/vn_vectors/NAME.hex / .exp
  --print NAME          encode one random instance and dump the record

Record layout (what the RTL writes back, one .exp line per command):
  fields are hex words separated by spaces:
    type flags reply_prog fault | q0..q7 | imm0..imm15 | cnt0..cnt3
    | blob0_off blob0_words blob1_off blob1_words | pres | chain entries
      (stype.mpc pairs, '-' if none) | obj_kind
"""

import argparse
import os
import random
import struct
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_vn_tables as G   # noqa: E402

import vkxml               # noqa: E402  (added to sys.path by gen_vn_tables)
import vn_protocol         # noqa: E402

REPO = G.REPO
VEC_DIR = REPO / 'verif' / 'tb' / 'apu' / 'vn_vectors'

# fault codes reported in the record's `fault` field (apu_vn_fault_e)
FAULT = {'NONE': 0, 'UNKNOWN_TYPE': 1, 'STYPE': 2, 'PNEXT': 3, 'FLAGS': 4,
         'BOUND': 5, 'HANDLE_ZERO': 6, 'LOOP': 7, 'ROM': 8}

# fixed-width .exp record: 77 record words + 256-word payload region,
# layout documented in g6lc_apu_vn_tables.md
# ("`.exp` expected-record format")
EXP_WORDS = 77
EXP_PAY = 256


class Enc:
    """Golden wire encoder (Mesa vn_encode_* semantics)."""

    def __init__(self, model):
        self.m = model
        self.buf = bytearray()
        self.seg = []       # (word_index, member path) for diagnostics

    def u32(self, v):
        self.buf += struct.pack('<I', v & 0xFFFFFFFF)

    def u64(self, v):
        self.buf += struct.pack('<Q', v & 0xFFFFFFFFFFFFFFFF)

    def words(self):
        assert len(self.buf) % 4 == 0
        return list(struct.unpack('<%dI' % (len(self.buf) // 4), self.buf))

    # ---- type-level primitives ---------------------------------------------

    def scalar(self, base, val):
        n = self.m.scalar_bytes(base)
        if n == 8:
            self.u64(val if val is not None else 0)
        elif n == 4:
            self.u32(val if val is not None else 0)
        elif n == 1:
            b = bytes(val) if isinstance(val, (bytes, bytearray)) else \
                bytes([val or 0])
            pad = (4 - len(b) % 4) % 4
            self.buf += b + b'\0' * pad
        else:
            raise ValueError('scalar size %d' % n)

    def struct(self, ty, obj, partial, path=''):
        """Full or partial struct body; obj is a dict member->value."""
        if obj is None:
            obj = {}
        if ty.category == vkxml.VkType.UNION:
            tag = vn_protocol.Gen.UNION_DEFAULT_TAGS[ty.name]
            # Mesa emits the u32 default-tag word before the member
            self.u32(tag)
            var = ty.variables[tag]
            self.member(ty, var, obj.get(var.name), partial,
                        path + ty.name + '.')
            return
        for var in ty.variables:
            if var.name == 'sType' and ty.s_type:
                self.u32(self.m.stype_values[ty.s_type])
                continue
            if var.is_p_next():
                self.pnext(obj.get('pNext', []), partial,
                           path + ty.name + '.')
                continue
            if partial:
                mode = self.m.partial_emit(ty, var)
                if mode is None:
                    continue
                self.member(ty, var, obj.get(var.name), mode == 'partial',
                            path + ty.name + '.')
                continue
            self.member(ty, var, obj.get(var.name), partial,
                        path + ty.name + '.')

    def pnext(self, chain, partial=False, path=''):
        """chain: list of dicts {'sType': type-name-or-int, ...members};
        chained node bodies follow the parent's partial/full variant."""
        chain = chain or []
        for node in chain:
            self.u64(1)
            st = node.get('sType')
            if isinstance(st, str) and st.startswith('VK_'):
                self.u32(self.m.stype_values[st])
            else:
                self.u32(self.m.stype_values[node['_ty'].s_type])
        self.u64(0)
        for node in reversed(chain):
            # Mesa _pnext emits headers forward then node bodies in
            # reverse order; a node's own pNext is the chain
            # continuation, not part of its body
            ty = node['_ty']
            for var in ty.variables:
                if var.name in ('sType', 'pNext'):
                    continue
                if partial:
                    mode = self.m.partial_emit(ty, var)
                    if mode is None:
                        continue
                    self.member(ty, var, node.get(var.name),
                                mode == 'partial', path)
                    continue
                self.member(ty, var, node.get(var.name), partial, path)

    def member(self, parent, var, val, partial, path=''):
        self.seg.append((len(self.buf) // 4, path + var.name))
        base = var.ty.base
        cat = base.category
        if var.is_dynamic_array() or var.is_blob():
            elems = val or []
            if cat == vkxml.VkType.DEFAULT and base.name == 'char' and \
                    var.ty.indirection_depth() >= 2:
                # array of C strings: count = strlen+1 (includes NUL)
                self.u64(len(elems))
                for s in elems:
                    b = s.encode() if isinstance(s, str) else bytes(s)
                    self.u64(len(b) + 1)
                    self.scalar(base, b + b'\0')
                return
            if var.is_blob():
                # void* blob: count is a BYTE count (e.g. pData/dataSize);
                # an out blob (vkGetQueryPoolResults::pData) sends the
                # count only, no payload
                if isinstance(elems, str):
                    elems = elems.encode()
                elif not isinstance(elems, (bytes, bytearray)):
                    elems = bytes(elems)
                self.u64(len(elems))
                if 'var_out' in var.attrs:
                    return
                pad = (4 - len(elems) % 4) % 4
                self.buf += bytes(elems) + b'\0' * pad
                return
            if var.has_c_string() or cat in (
                    vkxml.VkType.DEFAULT, vkxml.VkType.BASETYPE,
                    vkxml.VkType.ENUM, vkxml.VkType.BITMASK,
                    vkxml.VkType.HANDLE):
                if isinstance(elems, str):
                    elems = elems.encode()
                if isinstance(elems, (bytes, bytearray)):
                    # C string: count = strlen+1, payload includes NUL
                    if var.has_c_string() and base.name == 'char':
                        self.u64(len(elems) + 1)
                        self.scalar(base, bytes(elems) + b'\0')
                    else:
                        self.u64(len(elems))
                        self.scalar(base, elems)
                else:
                    self.u64(len(elems))
                    for e in elems:
                        self.scalar(base, e)
                return
            # struct/union array
            self.u64(len(elems))
            epartial = 'var_out' in var.attrs or partial
            for e in elems:
                self.struct(base, e, epartial, path + var.name + '.')
            return
        if var.ty.is_static_array():
            dim_s = var.ty.static_array_size()
            try:
                dim = int(str(dim_s), 0)
            except ValueError:
                dim = self.m.const_int(dim_s)
            # every static array is preceded by vn_encode_array_size(dim)
            self.u64(dim)
            if self.m.scalar_bytes(base) == 1:
                # byte arrays are packed (vn_encode_char_array): dim
                # bytes padded to 4, no per-element words
                if isinstance(val, str):
                    raw = val.encode()
                elif isinstance(val, (bytes, bytearray)):
                    raw = bytes(val)
                elif isinstance(val, (list, tuple)):
                    raw = bytes(v & 0xFF for v in val)
                else:
                    raw = b''
                raw = (raw + b'\0' * dim)[:dim]
                pad = (4 - dim % 4) % 4
                self.buf += raw + b'\0' * pad
                return
            seq = val if isinstance(val, (list, tuple)) else [val] * dim
            seq = (list(seq) + [0] * dim)[:dim]
            for x in seq:
                if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
                    self.struct(base, x if isinstance(x, dict) else {},
                                partial, path + var.name + '.')
                else:
                    self.scalar(base, x)
            return
        if var.ty.is_pointer():
            out = 'var_out' in var.attrs
            inout = out and 'var_in' in var.attrs
            if val is None:
                self.u64(0)
                return
            self.u64(1)
            if not self.m.gen.is_serializable(base):
                return                       # presence only (e.g. pAllocator)
            if cat == vkxml.VkType.HANDLE:
                self.u64(val if isinstance(val, int) else 0)
            elif cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
                self.struct(base, val, (out and not inout) or partial,
                            path + var.name + '.')
            elif inout or not out:
                # in/out scalar (e.g. pPhysicalDeviceCount): value follows
                # the presence word; a pure-out scalar is presence only
                self.scalar(base, val)
            return
        if cat == vkxml.VkType.HANDLE:
            self.u64(val or 0)
            return
        if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
            self.struct(base, val, partial, path + var.name + '.')
            return
        self.scalar(base, val)

    def command(self, ty, args):
        args = args or {}
        self.buf = bytearray()
        self.seg = [(0, ty.name + '.$header')]
        self.u32(self.m.enum_int('VkCommandTypeEXT', ty.attrs['c_type']))
        self.u32(args.get('_flags', 0))
        for var in ty.variables:
            self.member(ty, var, args.get(var.name), False,
                        ty.name + '.')
        return self.words()


# ---------------------------------------------------------------------------
# decode-ROM simulation
# ---------------------------------------------------------------------------

class Reader:
    def __init__(self, words):
        self.words = words
        self.pos = 0

    def rd32(self):
        if self.pos >= len(self.words):
            raise FaultErr(FAULT['BOUND'], self.pos, 0)
        w = self.words[self.pos]
        self.pos += 1
        return w

    def rd64(self):
        return self.rd32() | (self.rd32() << 32)

    def skip(self, n):
        if self.pos + n > len(self.words):
            raise FaultErr(FAULT['BOUND'], self.pos, 0)
        self.pos += n


class Sim:
    def __init__(self, model, asm):
        self.m = model
        self.asm = asm
        self.chain = asm['chain']
        self.trace = None      # if a list: records (mpc, op, startpos)

    def chain_lookup(self, tbl_off, stype):
        i = tbl_off
        while self.chain[i] != 0:
            if (self.chain[i] & 0xFFFFFFFF) == stype:
                return (self.chain[i] >> 32) & 0xFFFF, i
            i += 1
        return None, None

    def run(self, words, want_trace=False):
        rec = {'type': None, 'flags': None, 'reply_prog': 0,
               'fault': FAULT['NONE'], 'fault_word': 0, 'fault_val': 0,
               'words': 0, 'fault_mpc': -1,
               'q': [0] * 8, 'kind': [0] * 8, 'role': [0] * 8, 'qv': 0,
               'imm': [0] * 16, 'immv': 0, 'cnt': [0] * 4,
               'blob': [(0, 0), (0, 0)], 'pres': [0] * 8,
               'chain': [], 'obj_kind': 0, 'pay': []}
        if want_trace:
            self.trace = []
        else:
            self.trace = None
        if len(words) < 2:
            rec['fault'] = FAULT['BOUND']
            rec['fault_word'] = len(words)
            rec['words'] = len(words)
            return rec
        rec['type'] = words[0]
        rec['flags'] = words[1]
        entry = self.asm['dec_entry'].get(rec['type'])
        if entry is None:
            rec['fault'] = FAULT['UNKNOWN_TYPE']
            rec['fault_val'] = rec['type']
            rec['words'] = 2
            return rec
        r = Reader(words)
        r.pos = 2
        loops = []          # [remaining, body_mpc]
        try:
            self.exec_prog(entry, rec, r, loops)
        except FaultErr as e:
            rec['fault'] = e.code
            rec['fault_word'] = e.word
            rec['fault_val'] = e.val
            rec['fault_mpc'] = e.mpc
            rec['words'] = r.pos
            return rec
        except IndexError:
            rec['fault'] = FAULT['ROM']
            rec['words'] = r.pos
            return rec
        rec['words'] = r.pos
        return rec

    def exec_prog(self, mpc, rec, r, loops):
        """Execute a micro-program until END (command) or RET (chain body)."""
        dec = self.asm['dec_ops']
        while True:
            if mpc >= len(dec):
                raise FaultErr(FAULT['ROM'], r.pos, mpc)
            op, a, b, note, keep = dec[mpc]
            if self.trace is not None:
                self.trace.append((mpc, op, r.pos))
            cur = mpc
            mpc += 1
            if op == 'END':
                rec['reply_prog'] = a
                return
            if op == 'RET':
                return
            if op == 'PNEXT':
                bodies = []
                while True:
                    pr = r.rd64()
                    if pr == 0:
                        break
                    st = r.rd32()
                    target, idx = self.chain_lookup(b, st)
                    if target is None:
                        raise FaultErr(FAULT['PNEXT'], r.pos - 1, st)
                    if len(rec['chain']) >= G.MAX_CHAIN:
                        raise FaultErr(FAULT['BOUND'], r.pos - 1, st)
                    rec['chain'].append((st, idx))
                    bodies.append(target)
                for t in reversed(bodies):
                    self.exec_prog(t, rec, r, loops)
                continue
            if op == 'ARRAY':
                cnt = r.rd64()
                bound = self.m.arr_meta[b]
                if cnt > bound:
                    raise FaultErr(FAULT['BOUND'], r.pos - 2,
                                   cnt & 0xFFFFFFFF)
                rec['cnt'][a] = cnt
                if cnt == 0:
                    # skip the element program: scan to matching ENDARR
                    depth = 1
                    while depth:
                        if mpc >= len(dec):
                            raise FaultErr(FAULT['ROM'], r.pos, mpc)
                        o2 = dec[mpc][0]
                        if o2 == 'ARRAY':
                            depth += 1
                        elif o2 == 'ENDARR':
                            depth -= 1
                        mpc += 1
                else:
                    if len(loops) >= G.MAX_LOOP_DEPTH:
                        raise FaultErr(FAULT['LOOP'], r.pos - 2, cnt)
                    loops.append([cnt, mpc])
                continue
            if op == 'ENDARR':
                if not loops:
                    raise FaultErr(FAULT['ROM'], r.pos, cur)
                cnt, body = loops[-1]
                cnt -= 1
                if cnt > 0:
                    loops[-1][0] = cnt
                    mpc = body
                else:
                    loops.pop()
                continue
            mpc = self.exec_simple(op, a, b, rec, r, cur, mpc, keep)

    def exec_simple(self, op, a, b, rec, r, cur, mpc, keep=0):
        # §7b: a[7] is the KEEP bit on U32/U64/HANDLE/BLOB/PTR; the slot
        # field is a[6:0] and the discard marker is 0x7F.
        a7 = a & 0x7F
        if op == 'U32':
            w = r.rd32()
            if a7 != G.DISCARD7:
                rec['imm'][a7] = w
                rec['immv'] |= 1 << a7
            if keep:
                rec['pay'].append(w)
        elif op == 'U64':
            w = r.rd64()
            if a7 != G.DISCARD7:
                rec['q'][a7] = w
                rec['qv'] |= 1 << a7
            if keep:
                rec['pay'] += [w & 0xFFFFFFFF, (w >> 32) & 0xFFFFFFFF]
        elif op == 'HANDLE':
            w = r.rd64()
            slot = (a7 >> 3) & 0x1F
            role = a7 & 7
            if w == 0 and role not in (G.ROLES['NEW'], G.ROLES['OPTIONAL']):
                raise FaultErr(FAULT['HANDLE_ZERO'], r.pos - 2, w)
            if slot != G.DISCARD7:
                rec['q'][slot] = w
                rec['kind'][slot] = b
                rec['role'][slot] = role
                rec['qv'] |= 1 << slot
            if keep:
                rec['pay'] += [w & 0xFFFFFFFF, (w >> 32) & 0xFFFFFFFF]
        elif op == 'PTR':
            w = r.rd64()
            if a7 != G.DISCARD7:
                rec['pres'][a7] = 1 if w else 0
            if keep:
                rec['pay'].append(1 if w else 0)
            if not w:
                mpc += b
        elif op == 'STYPE':
            w = r.rd32()
            if w != self.m.consts[b]:
                raise FaultErr(FAULT['STYPE'], r.pos - 1, w)
        elif op == 'BLOB':
            cnt = r.rd64()
            meta = self.m.blob_meta[b]
            eb, maxw = meta & 0xFF, (meta >> 8) & 0xFFFFFF
            wn = (cnt * eb + 3) // 4
            if wn > maxw:
                raise FaultErr(FAULT['BOUND'], r.pos - 2, cnt & 0xFFFFFFFF)
            if r.pos + wn > len(r.words):
                raise FaultErr(FAULT['BOUND'], r.pos, cnt & 0xFFFFFFFF)
            rec['blob'][a7] = (r.pos, min(wn, 0x1FFFF))
            if keep:
                rec['pay'] += r.words[r.pos:r.pos + wn]
            r.pos += wn
        elif op == 'FLAGS':
            w = r.rd32()
            if w & ~self.m.consts[b] & 0xFFFFFFFF:
                raise FaultErr(FAULT['FLAGS'], r.pos - 1, w)
            if a != G.DISCARD:
                rec['imm'][a] = w
                rec['immv'] |= 1 << a
        elif op == 'SKIPW':
            r.skip(b)
        elif op == 'CHECK':
            w = r.rd32()
            if w != self.m.consts[b]:
                raise FaultErr(FAULT['STYPE'], r.pos - 1, w)
            if a != G.DISCARD:
                rec['imm'][a] = w
                rec['immv'] |= 1 << a
        elif op == 'OBJ':
            rec['obj_kind'] = b
        else:
            raise FaultErr(FAULT['ROM'], r.pos, cur)
        return mpc


class FaultErr(Exception):
    def __init__(self, code, word=0, val=0, mpc=-1):
        super().__init__(code)
        self.code = code
        self.word = word
        self.val = val
        self.mpc = mpc


class ExecCursor:
    """Sequential EXEC word source for run_reply (4b)."""

    def __init__(self, words):
        self.w = words
        self.pos = 0

    def __call__(self, mpc, n, op, a, b, note):
        ws = self.w[self.pos:self.pos + n]
        self.pos += n
        return ws


class ReplySim:
    """Golden reply builder: executes APU_VN_REPLY_ROM per design doc 4b
    given (decoded op record, VkResult, exec-word source)."""

    def __init__(self, model, asm):
        self.m = model
        self.asm = asm
        self.chain = asm['chain']
        self.rep = asm['rep']

    def rep_entry(self, rid):
        return self.asm['rep_entry'][rid]

    def chain_lookup(self, tbl_off, stype):
        i = tbl_off
        while self.chain[i] != 0:
            if (self.chain[i] & 0xFFFFFFFF) == stype:
                return (self.chain[i] >> 32) & 0xFFFF, i
            i += 1
        return None, None

    def run(self, cs_words, rec, result, exec_src, null_mask=None):
        """-> reply word list.  exec_src(mpc, n, op, a, b, note) -> n words.
        Returns [] for a faulted decode or a command with no reply."""
        if rec['fault'] or not rec['reply_prog']:
            return []
        null_mask = null_mask or set()
        out = []
        cpos = [0]          # rec['chain'] cursor

        def u32(v):
            out.append(v & 0xFFFFFFFF)

        def u64(v):
            out.extend([v & 0xFFFFFFFF, (v >> 32) & 0xFFFFFFFF])

        def run_prog(mpc):
            while True:
                op, a, b, note = self.rep[mpc]
                mpc += 1
                if op in ('REND', 'RRET'):
                    return
                if op == 'RTYPE':
                    u32(rec['type'])
                elif op == 'RRESULT':
                    u32(result)
                elif op in ('RU32', 'RU64'):
                    if a == G.SRC['IMM']:
                        v = rec['imm'][b]
                    elif a == G.SRC['Q']:
                        v = rec['q'][b]
                    elif a == G.SRC['CNT']:
                        v = rec['cnt'][b]
                    elif a == G.SRC['CONST']:
                        v = self.m.consts[b]
                    else:
                        ws = exec_src(mpc - 1,
                                      2 if op == 'RU64' else 1,
                                      op, a, b, note)
                        v = ws[0] | ((ws[1] << 32) if len(ws) > 1 else 0)
                    if op == 'RU32':
                        u32(v)
                    else:
                        u64(v)
                elif op == 'RHANDLE':
                    u64(rec['q'][a])
                elif op == 'RPTR':
                    emit = 1 if rec['pres'][a] else 0
                    u64(emit)
                    if not emit:
                        mpc += b
                elif op == 'RCONST':
                    idx = b & 0xFFFF
                    n = (b >> 16) & 0xFFFF
                    out.extend(self.m.profile_words_pool[idx:idx + n])
                elif op == 'RCHAIN':
                    # headers forward, bodies in reverse order: emit the
                    # next recorded node's header then run its body,
                    # whose own RCHAIN continues the chain; the last
                    # body emits the u64(0) terminator.  op.chain[] is a
                    # flat record of every PNEXT node in the command --
                    # request-side nodes too -- so nodes whose sType is
                    # not in this reply table are skipped (Mesa echoes
                    # only the out-struct's declared chain).
                    tgt = None
                    while cpos[0] < len(rec['chain']):
                        st, _idx = rec['chain'][cpos[0]]
                        cpos[0] += 1
                        tgt, _ = self.chain_lookup(b, st)
                        if tgt is not None:
                            break
                    if tgt is None:
                        u64(0)
                    else:
                        u64(1)
                        u32(st)
                        run_prog(tgt)
                elif op == 'RBLOB':
                    off, wn = rec['blob'][a]
                    cnt = cs_words[off - 2] | (cs_words[off - 1] << 32)
                    u64(cnt)
                    # §7b/5a-ii: rep_null_mask zeroes each masked
                    # element's two id words (VK_NULL_HANDLE echo)
                    for j in range(wn):
                        out.append(
                            0 if (j >> 1) in null_mask
                            else cs_words[off + j])
                elif op == 'REXBUF':
                    cnt = exec_src(mpc - 1, 1, op, a, b, note)[0]
                    u64(cnt)
                    n = (cnt * max(b, 1) + 3) // 4
                    out.extend(exec_src(mpc - 1, n, op, a, b, note))
                elif op == 'REXEC':
                    out.extend(exec_src(mpc - 1, b, op, a, b, note))
                else:
                    raise FaultErr(FAULT['ROM'], 0, mpc)

        run_prog(self.rep_entry(rec['reply_prog']))
        return out


# ---------------------------------------------------------------------------
# random argument generation
# ---------------------------------------------------------------------------

class ArgGen:
    def __init__(self, model, rng):
        self.m = model
        self.rng = rng
        self.handles = {}

    def rand_scalar(self, base):
        n = self.m.scalar_bytes(base)
        if cat_bitmask(base) and base.name in G.MASKED_FLAGS:
            mask = self.m.profile.get('flag_masks', {}).get(base.name)
            if mask:
                enum_name = base.requires.name if base.requires else None
                vals = self.m.enum_ints(enum_name)
                prefix = {'VkBufferUsageFlags': 'VK_BUFFER_USAGE_',
                          'VkImageUsageFlags': 'VK_IMAGE_USAGE_'}[base.name]
                v = 0
                for p in mask.split('|'):
                    v |= vals[prefix + p + '_BIT']
                return self.rng.randint(0, v) & v
        bits = n * 8
        return self.rng.getrandbits(min(bits, 32)) if n <= 4 else \
            self.rng.getrandbits(40) or 1

    def gen_member(self, parent, var, depth, partial=False):
        base = var.ty.base
        cat = base.category
        if var.name == 'sType':
            return None
        if var.is_p_next():
            return [] if self.rng.random() < 0.8 or depth > 1 else \
                self.gen_chain(parent)
        if var.is_dynamic_array() or var.is_blob():
            bound = self.m.array_bound(base, var.name) if cat in (
                vkxml.VkType.STRUCT, vkxml.VkType.UNION) else \
                min(8, self.m.blob_bound(var.name) // 4)
            n = self.rng.randint(0, min(int(bound), 4))
            return self.gen_elems(var, n, depth)
        if var.ty.is_static_array():
            dim_s = var.ty.static_array_size()
            try:
                dim = int(str(dim_s), 0)
            except ValueError:
                dim = self.m.const_int(dim_s)
            if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
                return [self.gen_struct(base, depth + 1)
                        for _ in range(min(dim, 2))]
            if self.m.scalar_bytes(base) == 1:
                return 's%d' % self.rng.randint(0, 999)
            return [self.rand_scalar(base) for _ in range(dim)]
        if var.ty.is_pointer():
            if self.rng.random() < 0.2:
                return None
            if not self.m.gen.is_serializable(base):
                return None
            out = 'var_out' in var.attrs
            if cat == vkxml.VkType.HANDLE:
                return self.rng.getrandbits(40) | 1
            if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
                return self.gen_struct(base, depth + 1, out)
            return self.rand_scalar(base)
        if cat == vkxml.VkType.HANDLE:
            return self.rng.getrandbits(40) | 1
        if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
            return self.gen_struct(base, depth + 1)
        if base.name == 'VkBool32':
            return self.rng.choice([0, 1]) \
                if self.m.profile.get('features', {}).get(
                    var.name, False) or not parent.name.endswith('Features') \
                else 0
        return self.rand_scalar(base)

    def gen_chain(self, parent):
        out = []
        for nty in parent.p_next:
            if not self.m.gen.is_serializable(nty) or \
                    not self.m.core_le_11(nty):
                continue
            if self.rng.random() < 0.3:
                out.append(self.gen_struct(nty, 2))
        return out[:2]

    def gen_elems(self, var, n, depth):
        """n elements of a dynamic array (or the blob/string payload)."""
        base = var.ty.base
        cat = base.category
        if cat == vkxml.VkType.DEFAULT and base.name == 'char' and \
                var.ty.indirection_depth() >= 2:
            return ['ext%d_%d' % (self.rng.randint(0, 999), i)
                    for i in range(n)]
        if var.is_blob():
            return self.rng.randbytes(n)
        if var.has_c_string():
            return 'str%d' % self.rng.randint(0, 999)
        if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
            return [self.gen_struct(base, depth + 1,
                                    'var_out' in var.attrs)
                    for _ in range(n)]
        return [self.rand_scalar(base) for _ in range(n)]

    # ---- len/condition coupling ---------------------------------------------
    # vk.xml `len` expressions tie an array's wire count to another member
    # (e.g. pCode <- codeSize/4, pSubmits <- submitCount,
    # pCommandBuffers <- pAllocateInfo->commandBufferCount).  Mesa encodes
    # `count` elements read from that member, so generated instances must
    # agree: pass 1 sets simple count members from the generated length,
    # pass 2 resizes every array to the evaluated count.

    def eval_len(self, expr, obj):
        import ast
        e = expr.strip().replace('->', '.')
        try:
            tree = ast.parse(e, mode='eval')
        except SyntaxError:
            return None

        def ev(node):
            if isinstance(node, ast.Expression):
                return ev(node.body)
            if isinstance(node, ast.Constant):
                return node.value if isinstance(node.value, int) else None
            if isinstance(node, ast.Name):
                # may be a count (int) or a parent struct (dict) for
                # 'parent->member' expressions
                return obj.get(node.id)
            if isinstance(node, ast.Attribute):
                base = ev(node.value)
                if isinstance(base, dict):
                    v = base.get(node.attr)
                    return v if isinstance(v, int) else None
                return None
            if isinstance(node, ast.BinOp):
                l, rr = ev(node.left), ev(node.right)
                if l is None or rr is None:
                    return None
                if isinstance(node.op, ast.Add):
                    return l + rr
                if isinstance(node.op, ast.Sub):
                    return l - rr
                if isinstance(node.op, ast.Mult):
                    return l * rr
                if isinstance(node.op, (ast.Div, ast.FloorDiv)):
                    return l // rr if rr else None
                return None
            if isinstance(node, ast.UnaryOp) and \
                    isinstance(node.op, ast.USub):
                v = ev(node.operand)
                return -v if v is not None else None
            return None

        return ev(tree)

    def _resolve_name(self, name, obj):
        """'(a->b)' -> (container_dict, key) or None."""
        parts = name.split('->')
        cur = obj
        for p in parts[:-1]:
            cur = cur.get(p)
            if not isinstance(cur, dict):
                return None
        if parts[-1] in cur:
            return cur, parts[-1]
        return None

    def invert_len(self, expr, obj, n):
        """Set the count member so that eval_len(expr) == n; returns True
        when the expr was invertible."""
        import re
        e = expr.strip()
        m = re.fullmatch(r'(\w+)', e)
        if m:
            if m.group(1) in obj:
                obj[m.group(1)] = n
                return True
            return False
        m = re.fullmatch(r'(\w+)->(\w+)\s*(?:/\s*(\d+))?', e)
        if m:
            a, b, k = m.group(1), m.group(2), m.group(3)
            sub = obj.get(a)
            if isinstance(sub, dict) and b in sub:
                sub[b] = n * (int(k) if k else 1)
                return True
            return False
        # general single-name solve (e.g. '(rasterizationSamples + 31)/32'):
        # the expr is monotonic in its one identifier, so probe upward for
        # the smallest value whose evaluation equals n
        idents = [x for x in re.findall(r'[A-Za-z_]\w*(?:->[A-Za-z_]\w*)*', e)
                  if x not in ('latexmath',)]
        if len(idents) == 1:
            res = self._resolve_name(idents[0], obj)
            if res:
                cont, key = res
                save = cont[key]
                for v in range(0, 8192):
                    cont[key] = v
                    got = self.eval_len(e, obj)
                    if got is not None and got >= n:
                        if got == n:
                            return True
                        break
                cont[key] = save
        return False

    def eval_cond(self, cond, obj):
        """IGNORABLE_LIST conditions, e.g.
        'val->sharingMode == VK_SHARING_MODE_CONCURRENT'."""
        import re
        e = cond.replace('val->', '').replace('val.', '')

        def rep(m):
            name = m.group(0)
            if name in self.m.api_consts:
                return str(self.m.api_consts[name])
            v = obj.get(name)
            return str(v) if isinstance(v, int) else name

        e2 = re.sub(r'\b[A-Za-z_]\w*\b', rep, e)
        e2 = e2.replace('&&', ' and ').replace('||', ' or ')
        e2 = re.sub(r'!(?!=)', ' not ', e2)
        try:
            return bool(eval(e2, {'__builtins__': {}}, {}))
        except Exception:
            return True

    def _invert_targets(self, expr, obj, n):
        """Like invert_len but returns [(container_dict, key, value)]
        without mutating; used to gather all arrays' requirements on a
        shared count member."""
        import re
        e = expr.strip()
        m = re.fullmatch(r'(\w+)', e)
        if m:
            if m.group(1) in obj:
                return [(obj, m.group(1), n)]
            return []
        m = re.fullmatch(r'(\w+)->(\w+)\s*(?:/\s*(\d+))?', e)
        if m:
            a, b, k = m.group(1), m.group(2), m.group(3)
            sub = obj.get(a)
            if isinstance(sub, dict) and b in sub:
                return [(sub, b, n * (int(k) if k else 1))]
            return []
        idents = [x for x in re.findall(r'[A-Za-z_]\w*(?:->[A-Za-z_]\w*)*',
                                        e) if x not in ('latexmath',)]
        if len(idents) == 1:
            res = self._resolve_name(idents[0], obj)
            if res:
                cont, key = res
                save = cont[key]
                for v in range(0, 8192):
                    cont[key] = v
                    got = self.eval_len(e, obj)
                    if got is not None and got >= n:
                        cont[key] = save
                        if got == n:
                            return [(cont, key, v)]
                        return []
                cont[key] = save
        return []

    def _null_parent(self, expr, obj):
        """True when a '<name>->member' length expression's parent
        argument is absent/None -- Mesa emits array_size(0) then
        (vn_encode_vkAllocateCommandBuffers reads
        'pAllocateInfo ? pAllocateInfo->commandBufferCount : 0')."""
        import re
        for name in re.findall(r'(\w+)\s*->', expr):
            v = obj.get(name)
            if v is None:
                return True
            if isinstance(v, dict) and self._null_parent(
                    expr[expr.index('->') + 2:], v):
                return True
        return False

    def fix_lens(self, ty, obj, _depth=0):
        """Reconcile count members and array lengths across the whole
        argument tree.  Several arrays may share one count member
        (e.g. vkAllocateDescriptorSets: pDescriptorSets via
        'pAllocateInfo->descriptorSetCount' and the nested pSetLayouts
        via 'descriptorSetCount'); gather every demand globally, assign
        each count the max, then resize -- iterate to a fixpoint."""
        changed = True
        it = 0
        while changed and it < 8:
            it += 1
            changed = False
            for t, d in self._iter_structs(ty, obj):
                changed |= self._fix_conditions(t, d)
            wants = {}
            for t, d in self._iter_structs(ty, obj):
                for var in t.variables:
                    if not (var.is_dynamic_array() or var.is_blob()):
                        continue
                    val = d.get(var.name)
                    n = len(val) if val is not None else 0
                    for expr in var.attrs.get('len_exprs', []):
                        if expr == 'null-terminated':
                            continue
                        for cont, key, want in self._invert_targets(
                                expr, d, n):
                            wants.setdefault((id(cont), key), []).append(
                                (cont, want))
            for (cid, key), vs in wants.items():
                cont = vs[0][0]
                m = max(w for _, w in vs)
                if cont.get(key) != m:
                    cont[key] = m
                    changed = True
            for t, d in self._iter_structs(ty, obj):
                changed |= self._resize_arrays(t, d)
        return changed

    def _iter_structs(self, ty, obj, depth=0):
        """Yield (type, dict) for obj and every nested struct instance:
        pointer targets, array elements, value members, pNext nodes."""
        if depth > 6 or not isinstance(obj, dict):
            return
        yield ty, obj
        for var in ty.variables:
            v = obj.get(var.name)
            if isinstance(v, dict) and \
                    isinstance(v.get('_ty'), vkxml.VkType):
                yield from self._iter_structs(v['_ty'], v, depth + 1)
            elif isinstance(v, (list, tuple)):
                for e in v:
                    if isinstance(e, dict) and \
                            isinstance(e.get('_ty'), vkxml.VkType):
                        yield from self._iter_structs(e['_ty'], e,
                                                      depth + 1)

    def _fix_conditions(self, ty, obj):
        """IGNORABLE_LIST conditions: array not on the wire when false."""
        changed = False
        for var in ty.variables:
            if not (var.is_dynamic_array() or var.is_blob()):
                continue
            cond = var.attrs.get('condition')
            if cond is not None and not self.eval_cond(cond, obj):
                if len(obj.get(var.name) or []) != 0:
                    obj[var.name] = [] if not var.is_blob() else b''
                    changed = True
        return changed

    def _resize_arrays(self, ty, obj):
        """pass 2 for one level: resize arrays to the evaluated count;
        a length expression whose parent pointer is None counts as 0
        on the wire (Mesa reads 'ptr ? ptr->count : 0')."""
        changed = False
        arrs = [v for v in ty.variables
                if v.is_dynamic_array() or v.is_blob()]
        # pass 2: resize arrays to the evaluated count; a length
        # expression whose parent pointer is None counts as 0 on the
        # wire (Mesa reads 'ptr ? ptr->count : 0')
        for var in arrs:
            for expr in var.attrs.get('len_exprs', []):
                if expr == 'null-terminated':
                    continue
                n = self.eval_len(expr, obj)
                if n is None:
                    if self._null_parent(expr, obj):
                        n = 0
                    else:
                        continue
                base = var.ty.base
                cat = base.category
                bound = self.m.array_bound(base, var.name) if cat in (
                    vkxml.VkType.STRUCT, vkxml.VkType.UNION) else \
                    self.m.blob_bound(var.name)
                n = max(0, min(int(bound), n))
                cur = obj.get(var.name)
                curlen = len(cur) if cur is not None else 0
                if curlen == n:
                    continue
                changed = True
                if isinstance(cur, str):
                    obj[var.name] = (cur + 'x' * n)[:n]
                elif isinstance(cur, (bytes, bytearray)):
                    cur = bytes(cur)
                    obj[var.name] = cur[:n] if curlen > n else \
                        cur + self.rng.randbytes(n - curlen)
                else:
                    cur = list(cur or [])
                    if curlen > n:
                        obj[var.name] = cur[:n]
                    else:
                        obj[var.name] = cur + self.gen_elems(
                            var, n - curlen, 0)
                break   # first numeric len expr wins
        return changed

    def gen_struct(self, ty, depth=0, partial=False):
        if ty.category == vkxml.VkType.UNION:
            tag = vn_protocol.Gen.UNION_DEFAULT_TAGS[ty.name]
            var = ty.variables[tag]
            return {var.name: self.gen_member(ty, var, depth)}
        obj = {'_ty': ty}
        if ty.s_type:
            obj['sType'] = ty.s_type
        for var in ty.variables:
            if var.name == 'sType':
                continue
            obj[var.name] = self.gen_member(ty, var, depth)
        self.fix_lens(ty, obj)
        return obj

    def gen_command(self, cmd_name):
        ty = next(t for t in
                  self.m.gen.supported_types[vkxml.VkType.COMMAND]
                  if t.name == cmd_name)
        args = {}
        for var in ty.variables:
            args[var.name] = self.gen_member(ty, var, 0)
        self.fix_lens(ty, args)
        return args


def cat_bitmask(base):
    return base.category == vkxml.VkType.BITMASK


# ---------------------------------------------------------------------------
# record formatting
# ---------------------------------------------------------------------------

def rec_words(rec):
    """apu_vn_op_t as 76 u32 words (see g6lc_apu_vn_tables.md)."""
    w = [(rec['type'] or 0) & 0xFFFFFFFF,
         (rec['flags'] or 0) & 0xFFFFFFFF]
    for q in rec['q']:
        w += [q & 0xFFFFFFFF, (q >> 32) & 0xFFFFFFFF]
    w += [k & 0x3F for k in rec['kind']]
    w += [rl & 7 for rl in rec['role']]
    w += [rec['qv'] & 0xFF]
    w += [i & 0xFFFFFFFF for i in rec['imm']]
    w += [rec['immv'] & 0xFFFF]
    w += [c & 0xFFFFFFFF for c in rec['cnt']]
    w += [rec['blob'][0][0] & 0xFFFF, rec['blob'][0][1] & 0x1FFFF,
          rec['blob'][1][0] & 0xFFFF, rec['blob'][1][1] & 0x1FFFF]
    pres = 0
    for i, p in enumerate(rec['pres']):
        if p:
            pres |= 1 << i
    w += [pres]
    chain = [i & 0xFF for _, i in rec['chain']][:8]
    chain += [0] * (8 - len(chain))
    w += chain
    w += [len(rec['chain']) & 0xF, rec['obj_kind'] & 0x3F,
          rec['reply_prog'] & 0xFF, rec['words'] & 0xFFFF,
          rec['fault'] & 0xF, rec['fault_word'] & 0xFFFF,
          rec['fault_val'] & 0xFFFFFFFF]
    w += [len(rec['pay']) & 0xFFFF]
    assert len(rec['pay']) <= EXP_PAY, \
        'payload %d exceeds .exp region %d' % (len(rec['pay']), EXP_PAY)
    w += [x & 0xFFFFFFFF for x in rec['pay']]
    w += [0] * (EXP_WORDS + EXP_PAY - len(w))
    assert len(w) == EXP_WORDS + EXP_PAY, len(w)
    return w


def fmt_rec(rec):
    chain = ','.join('%d.%d' % (s, t) for s, t in rec['chain']) or '-'
    return ('%d %d %d %d w=%d fw=%d fv=%X | %s | %s | %s | %s | %s | %s | %d'
            % (rec['type'], rec['flags'], rec['reply_prog'], rec['fault'],
               rec['words'], rec['fault_word'], rec['fault_val'],
               ' '.join('%X' % q for q in rec['q']),
               ' '.join('%X' % i for i in rec['imm']),
               ' '.join('%X' % c for c in rec['cnt']),
               ' '.join('%X.%X' % b for b in rec['blob']),
               ' '.join('%X' % p for p in rec['pres']),
               chain, rec['obj_kind']))


def to_jsonable(v):
    if isinstance(v, dict):
        out = {k: to_jsonable(x) for k, x in v.items() if k != '_ty'}
        if '_ty' in v:
            out['_ty'] = v['_ty'].name
        return out
    if isinstance(v, (bytes, bytearray)):
        return {'$bytes': bytes(v).hex()}
    if isinstance(v, (list, tuple)):
        return [to_jsonable(x) for x in v]
    return v


def mutate_words(model, asm, sim, cmd_name, words, rng):
    """One mutated stream.  Uses the decode trace to target a specific
    fault class; returns (words, mutation-name) or (None, None)."""
    kind = rng.choice(['type', 'stype', 'pnext', 'flags', 'trunc',
                       'handle', 'bound'])
    w = list(words)
    sim.run(words, want_trace=True)
    tr = sim.trace or []
    dec = asm['dec_ops']

    if kind == 'type':
        w[0] = 0xFFFF
        return w, 'type'
    if kind == 'trunc':
        if len(w) <= 4:
            return None, None
        return w[:rng.randint(2, len(w) - 1)], 'trunc'
    if kind == 'stype':
        for mpc, op, pos in tr:
            if op == 'STYPE':
                w[pos] = (w[pos] ^ 0x00FFFFFF) | 0x80000000
                return w, 'stype'
        return None, None
    if kind == 'flags':
        for mpc, op, pos in tr:
            if op == 'FLAGS':
                mask = model.consts[dec[mpc][2]]
                w[pos] = (w[pos] | (~mask)) & 0xFFFFFFFF
                if w[pos] & ~mask & 0xFFFFFFFF:
                    return w, 'flags'
        return None, None
    if kind == 'handle':
        for mpc, op, pos in tr:
            if op == 'HANDLE':
                role = dec[mpc][1] & 7
                if role == G.ROLES['LOOKUP']:
                    w[pos] = 0
                    w[pos + 1] = 0
                    return w, 'handle'
        return None, None
    if kind == 'bound':
        for mpc, op, pos in tr:
            if op == 'ARRAY':
                bound = model.arr_meta[dec[mpc][2]]
                w[pos] = (bound + 1) & 0xFFFFFFFF
                w[pos + 1] = 0
                return w, 'bound'
            if op == 'BLOB':
                meta = model.blob_meta[dec[mpc][2]]
                eb = meta & 0xFF
                maxw = (meta >> 8) & 0xFFFFFF
                cnt = ((maxw + 1) * 4 + eb - 1) // eb
                w[pos] = cnt & 0xFFFFFFFF
                w[pos + 1] = 0
                return w, 'bound'
        return None, None
    if kind == 'pnext':
        for mpc, op, pos in tr:
            if op == 'PNEXT' and pos + 2 < len(w):
                # terminator presence word -> make it look like a chain
                # entry with an unknown sType
                if w[pos] == 0 and w[pos + 1] == 0:
                    w[pos] = 1
                    w[pos + 1] = 0
                # existing chain / injected header: corrupt sType
                w[pos + 2] = 0xFEEDFACE
                return w, 'pnext'
        return None, None
    return None, None


def build_assembly(model):
    asm = model.assemble()
    # decode entry: type -> mpc
    dec_entry = {}
    type_to_cmd = {i['type_id']: n for n, i in model.cmd_info.items()}
    for t, n in type_to_cmd.items():
        dec_entry[t] = asm['entry_of_cmd'][n]
    asm['dec_entry'] = dec_entry
    asm['dec_ops'] = asm['dec']
    # reply entry: reply prog id -> reply ROM mpc
    asm['rep_entry'] = {rid: asm['mpc_of_rep'][('reply', n)]
                        for n, rid in model.reply_ids.items()}
    return model, asm


def member_skeleton(model, var, off, consts):
    """Mark required-constant positions (u64 array_size markers, union
    default tags) inside a reply struct body's word layout; mirrors
    member_words() in the generator."""
    base = var.ty.base
    cat = base.category
    if var.ty.is_static_array():
        dim_s = var.ty.static_array_size()
        try:
            dim = int(str(dim_s), 0)
        except ValueError:
            dim = model.const_int(dim_s)
        consts[off] = dim & 0xFFFFFFFF
        consts[off + 1] = (dim >> 32) & 0xFFFFFFFF
        off += 2
        if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
            for _ in range(dim):
                off = struct_skeleton(model, base, off, consts)
        else:
            sz = model.scalar_bytes(base)
            off += (dim * sz + 3) // 4
        return off
    if cat == vkxml.VkType.UNION:
        tag = vn_protocol.Gen.UNION_DEFAULT_TAGS.get(base.name)
        if tag is None:
            return off + (model.struct_words(base) or 0)
        consts[off] = tag
        return member_skeleton(model, base.variables[tag], off + 1,
                               consts)
    if cat == vkxml.VkType.STRUCT:
        return struct_skeleton(model, base, off, consts)
    sz = model.scalar_bytes(base)
    return off + ((sz + 3) // 4 if sz else 1)


def struct_skeleton(model, ty, off, consts):
    for var in ty.variables:
        if var.name in ('sType', 'pNext'):
            continue
        off = member_skeleton(model, var, off, consts)
    return off


def gen_reply_exec(model, asm, rep_sim, cmd, ty, cs_words, rec, result,
                   rng):
    """-> (exec_words, reply_words) for one decoded instance.

    EXEC values are generated coherently: a count output equals the
    count of the array op that follows it on the wire (Mesa's
    vn_decode_array_size sets fatal when the wire size != expected).
    Array wire counts themselves come from the request's recorded
    element/byte count (the count u64 immediately before the blob
    payload in the CS)."""
    info = model.cmd_info[cmd]
    prog = model.reply_progs[('reply', cmd)]
    base_mpc = rep_sim.rep_entry(info['reply_id'])
    rexbuf = {}              # rep mpc -> (count, elem base, elem bytes, consts)
    rexec = {}               # rep mpc -> {word off: const value}
    val_of = {}              # rep mpc -> u64 value for EXEC src
    arr = []                 # (prog idx, wire element count)
    for i, (op, a, b, note) in enumerate(prog):
        if op == 'RBLOB':
            off = rec['blob'][a][0]
            cnt = cs_words[off - 2] | (cs_words[off - 1] << 32)
            arr.append((i, cnt))
        elif op == 'REXBUF':
            var = next(v for v in ty.variables if v.name == note)
            elem = var.ty.base
            slot = info['blob_map'].get(note)
            cnt = 0
            if slot is not None:
                off = rec['blob'][slot][0]
                cnt = cs_words[off - 2] | (cs_words[off - 1] << 32)
            eb = max(b, 1)
            cnt = min(cnt, max(1, 256 // eb))
            arr.append((i, cnt))
            ec = {}
            if eb % 4 == 0 and elem is not None \
                    and elem.category in (vkxml.VkType.STRUCT,
                                          vkxml.VkType.UNION):
                struct_skeleton(model, elem, 0, ec)
            rexbuf[base_mpc + i] = (cnt, elem, eb, ec)
        elif op == 'REXEC':
            ec = {}
            ety = model.reg.type_table.get(note)
            if ety is not None:
                struct_skeleton(model, ety, 0, ec)
            rexec[base_mpc + i] = ec
    for i, (op, a, b, note) in enumerate(prog):
        if op in ('RU32', 'RU64') and a == G.SRC['EXEC'] \
                and note.endswith('Count'):
            val_of[base_mpc + i] = \
                next((c for j, c in arr if j > i), 0)
    exec_w = []

    def rexbuf_payload(cnt, elem, eb, ec):
        if eb % 4 == 0:
            if elem is not None and getattr(elem, 's_type', None):
                # chainable element: sType + NULL pNext u64 + body
                st = model.stype_values[elem.s_type]
                body = eb // 4 - 3
                w = []
                for _ in range(cnt):
                    ew = [st, 0, 0] + \
                        [rng.getrandbits(32) for _ in range(body)]
                    for pos, v in ec.items():
                        ew[3 + pos] = v & 0xFFFFFFFF
                    w += ew
                return w
            w = [rng.getrandbits(32) for _ in range(cnt * eb // 4)]
            ew = eb // 4
            for i in range(cnt):
                for pos, v in ec.items():
                    w[i * ew + pos] = v & 0xFFFFFFFF
            return w
        raw = rng.randbytes(cnt * eb)
        return [int.from_bytes(raw[i * 4:(i + 1) * 4].ljust(4, b'\0'),
                               'little')
                for i in range((cnt * eb + 3) // 4)]

    def supply(mpc, n, op, a, b, note):
        if op == 'REXBUF':
            cnt, elem, eb, ec = rexbuf[mpc]
            w = [cnt & 0xFFFFFFFF] if n == 1 else \
                rexbuf_payload(cnt, elem, eb, ec)
        elif mpc in val_of:
            w = [val_of[mpc] & 0xFFFFFFFF]
            if n > 1:
                w.append((val_of[mpc] >> 32) & 0xFFFFFFFF)
            w += [rng.getrandbits(32) for _ in range(n - len(w))]
        else:
            w = [rng.getrandbits(32) for _ in range(n)]
        if op == 'REXEC':
            ec = rexec.get(mpc)
            if ec is None:
                ety = model.reg.type_table.get(note)
                ec = {}
                if ety is not None:
                    struct_skeleton(model, ety, 0, ec)
                rexec[mpc] = ec
            for pos, v in ec.items():
                if pos < len(w):
                    w[pos] = v & 0xFFFFFFFF
        exec_w.extend(w)
        return w

    rep = rep_sim.run(cs_words, rec, result, supply)
    return exec_w, rep


# ---------------------------------------------------------------------------
# session vectors: a Python mirror of g6lc_apu_vnfront (§4c/§6)
# ---------------------------------------------------------------------------
#
# The session stream exercises one instance -> physical-device queries ->
# device -> queue -> memory/buffer -> shader -> layouts/pipeline ->
# descriptors -> command pool -> allocate -> begin -> bind/dispatch -> end
# -> submit -> waits -> reverse destroys ordering, then the five negative
# arms of the design doc, each after a full reset.  FrontModel replicates
# the sequencer's ObjTab/CmdRec/cmdexec-visible semantics so the .exp can
# carry per-command expected {result, reply, live count, record, work}.
#
# .exp record (386 words + FFFFFFFF FFFFFFFF sentinel):
#   0   cs_base            1   cs_len (words)
#   2   cmd_type           3   flags: bit0 has_reply, bit1 has_record,
#                          bit2 has_work, bit3 reset_before
#   4   expected result    5   expected rep_words
#   6   expected ObjTab live count after the command
#   7   expected fault
#   8..23   expected appended record (16 words, rec[32*i +: 32])
#   24  n_work             25..32 work ctypes (max 8)
#   33  n_rep              34..385 reply words (max 352)

VK_OK = 0
VK_NOT_READY = 1
VK_ERR_OOM = 0xFFFFFFFE
VK_ERR_LOST = 0xFFFFFFFC
VK_ERR_FEATURE = 0xFFFFFFF8
VK_ERR_UNKNOWN = 0xFFFFFFF3

CB_REC, CB_EXEC, CB_PEND, CB_INV = 1, 2, 4, 8

KIND = {}      # filled from the model
SESSION_EXP_N = 386
SESSION_MAX_REP = 352

# §7b geometry (defaults; --paywords overrides the ObjPay size)
PAY_WORDS = 16384
PAY_CHUNK = 64
PAY_STAGE = 1024
PAY_PER_BUF = 256
APU_VN_FAULT_PAYLOAD = 9
# §7b/5a-ii: pipelines keep no ObjPay extent — the staged payload is
# consumed at creation and the object carries {slot, layout} in aux.
PAY_KINDS = ('VkDescriptorSetLayout', 'VkPipelineLayout',
             'VkDescriptorSet')
# §7b/5a-ii: kinds whose retire needs a pre-LOOKUP for the aux extent
# (ShaderCore slot for modules/pipelines, vgpages for device memory)
AUXRET_KINDS = ('VkShaderModule', 'VkPipeline', 'VkDeviceMemory')
SH_SLOTS = 8
VGP_PAGES = 256
VGP_PAGE = 4096

# commit prediction for vkCreateComputePipelines: the 4a commit
# scanner mirrors g6lc_apu_shmod 1:1 (Fault -> VK_ERROR_UNKNOWN)
sys.path.insert(0, os.path.join(os.path.dirname(
    os.path.abspath(__file__)), 'shader'))
import spirv_scan                                   # noqa: E402
import spirv_model                                  # noqa: E402


def spv_words(name):
    """Raw little-endian words of a 4a shader-corpus module."""
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     'shader', 'corpus', name + '.spv')
    with open(p, 'rb') as f:
        data = f.read()
    return list(struct.unpack('<%dI' % (len(data) // 4), data))


# session module: smallest corpus vector (~2k cycles/dispatch); any
# 4a-committable module works -- the dispatch is only required to
# issue, run and complete on the real ShaderCore
SPV_SESSION = spv_words('bufcopy')
SPV_SESSION_B = len(SPV_SESSION) * 4


class FrontModel:
    """Mirror of g6lc_apu_vnfront's externally visible state."""

    SLOTS = 256
    CB_BUFS = 16
    FENCES = 16

    def __init__(self, model, asm, pay_words=PAY_WORDS):
        self.m = model
        self.asm = asm
        self.pay_words = pay_words
        self.reset()

    def reset(self):
        self.ent = [None] * self.SLOTS
        self.gens = [0] * self.SLOTS
        self.idmap = {}
        self.live_cnt = 0
        self.ctx = 0
        self.cb_alloc = [0] * self.CB_BUFS
        self.cb_pool = [0] * self.CB_BUFS
        self.cb_hnd = [0] * self.CB_BUFS
        # executor fence arena: vkCreateFence claims an index into
        # aux[7:0]; ObjTab slots are global, not per-kind
        self.falloc = [0] * self.FENCES
        self.recs = [[] for _ in range(self.CB_BUFS)]
        self.rec_state = [0] * self.CB_BUFS   # 0 none,1 recording,2 sealed
        self.pushed = 0
        self.fence_sig = 0
        self.fence_lost = 0
        self.outstanding = []                  # (fence_slot, pin slots)
        self.work_hold = False                 # TB: gate work_ready_i
        # §7b/5a-ii: ShaderCore slot manager + module code shadow
        self.sh_slots = [0] * SH_SLOTS         # users count per slot
        self.sh_code = {}                      # slot -> pCode words
        # §7b/5a-ii: aperture pages.  `self.ap` may be bound to a
        # TransportModel so vgctl blobs and device memory share one
        # allocator; standalone runs use this bitmap.
        self.ap = None
        self.pg_pages = [0] * VGP_PAGES
        # §7b: ObjPay mirror -- chunk bitmap (first-fit like the RTL)
        # plus a sparse content image for the .pay expectations
        self.pay_used = [0] * (self.pay_words // PAY_CHUNK)
        self.pay = {}                          # addr -> word
        # cmdrec per-buffer payload arenas
        self.pay_top = [0] * self.CB_BUFS
        self.pay_arena = [dict() for _ in range(self.CB_BUFS)]

    # ---- ObjTab -------------------------------------------------------------
    def resolve(self, idv, kind):
        """-> (status, slot, entry).  Mirrors res_start: handle form iff
        id[63:32]==0."""
        if idv == 0:
            return 'MISS', -1, None
        if idv < (1 << 32):
            slot, gen = idv & 0xFFFF, (idv >> 16) & 0xFFFF
            if slot >= self.SLOTS:
                return 'GEN', -1, None
            e = self.ent[slot]
            if e is None or e['gen'] != gen:
                return 'GEN', -1, None
            if kind and e['kind'] != kind:
                return 'KIND', slot, e
            return 'OK', slot, e
        s = self.idmap.get(idv)
        if s is None:
            return 'MISS', -1, None
        e = self.ent[s]
        if e is None:
            return 'MISS', -1, None
        if kind and e['kind'] != kind:
            return 'KIND', s, e
        return 'OK', s, e

    def alloc(self, idv, kind, parent_h):
        if idv in self.idmap and self.ent[self.idmap[idv]] is not None:
            return 'DUP', 0, -1
        slot = next((i for i, e in enumerate(self.ent) if e is None), -1)
        if slot < 0:
            return 'FULL', 0, -1
        par = -1
        if parent_h:
            st, ps, _pe = self.resolve(parent_h, 0)
            if st != 'OK':
                return 'PARENT_MISS', 0, -1
            par = ps
        g = self.gens[slot] + 1
        if g > 0xFFFF:
            g = 1
        self.gens[slot] = g
        self.ent[slot] = {'id': idv, 'kind': kind, 'gen': g,
                          'parent': par, 'refcnt': 0, 'pins': 0,
                          'state': 0, 'aux': 0, 'ctx': self.ctx,
                          'size': 0, 'bind_mem': -1, 'bind_off': 0}
        self.idmap[idv] = slot
        self.live_cnt += 1
        if par >= 0:
            self.ent[par]['refcnt'] += 1
        return 'OK', (g << 16) | slot, slot

    def retire(self, idv, kind):
        st, s, e = self.resolve(idv, kind)
        if st != 'OK':
            return st, s
        if e['pins']:
            return 'PINNED', s
        if e['refcnt']:
            return 'BUSY_CHILDREN', s
        if e['parent'] >= 0 and self.ent[e['parent']] is not None:
            self.ent[e['parent']]['refcnt'] -= 1
        self.ent[s] = None
        self.idmap.pop(e['id'], None)
        self.live_cnt -= 1
        return 'OK', s

    def setstate(self, h, mask, value):
        st, s, e = self.resolve(h, 0)
        if st != 'OK':
            return st, s
        e['state'] = (e['state'] & ~mask) | (value & mask)
        return 'OK', s

    def setaux(self, h, mask, value):
        st, s, e = self.resolve(h, 0)
        if st != 'OK':
            return st, s
        e['aux'] = (e['aux'] & ~mask) | (value & mask)
        return 'OK', s

    # ---- §7b: ObjPay mirror -------------------------------------------------
    def setauxhi(self, h, value32):
        """aux[63:32] = {base[15:0], words[15:0]}."""
        st, s, e = self.resolve(h, 0)
        if st != 'OK':
            return st, s
        e['aux'] = (e['aux'] & 0xFFFFFFFF) | \
            ((value32 & 0xFFFFFFFF) << 32)
        return 'OK', s

    def pay_alloc(self, words):
        """First-fit over PAY_CHUNK-word chunks -> base or None."""
        if words == 0:
            return 0
        nch = (words + PAY_CHUNK - 1) // PAY_CHUNK
        if nch > len(self.pay_used):
            return None
        run = start = 0
        for i, u in enumerate(self.pay_used):
            if u == 0:
                if run == 0:
                    start = i
                run += 1
                if run == nch:
                    for j in range(start, start + nch):
                        self.pay_used[j] = 1
                    return start * PAY_CHUNK
            else:
                run = 0
        return None

    def pay_free(self, base, words):
        if not words:
            return
        for j in range(base // PAY_CHUNK,
                       base // PAY_CHUNK +
                       (words + PAY_CHUNK - 1) // PAY_CHUNK):
            self.pay_used[j] = 0

    def pay_free_of(self, e):
        """Free an entry's aux[63:32] = {base,words} extent."""
        w = (e['aux'] >> 32) & 0xFFFF
        b = (e['aux'] >> 48) & 0xFFFF
        if w:
            self.pay_free(b, w)

    def arena_append(self, cbuf, words):
        """cmdrec payload arena bump-alloc -> base or None (PAY_FULL)."""
        top = self.pay_top[cbuf]
        if top + len(words) > PAY_PER_BUF:
            return None
        for i, w in enumerate(words):
            self.pay_arena[cbuf][top + i] = w & 0xFFFFFFFF
        self.pay_top[cbuf] += len(words)
        return top

    # ---- §7b/5a-ii: ShaderCore slot manager + aperture pages ---------
    def sm_alloc(self):
        for i, u in enumerate(self.sh_slots):
            if u == 0:
                self.sh_slots[i] = 1
                return i
        return None

    def sm_ref(self, slot):
        self.sh_slots[slot] += 1

    def sm_unref(self, slot):
        self.sh_slots[slot] -= 1
        if self.sh_slots[slot] == 0:
            self.sh_code.pop(slot, None)

    def sh_commit_ok(self, slot):
        """spirv_scan mirror of the g6lc_apu_shmod commit scan."""
        try:
            spirv_scan.Scanner(list(self.sh_code.get(slot, []))).scan()
            return True
        except spirv_scan.Fault:
            return False

    def pg_alloc(self, nbytes):
        """vgpages first-fit ALLOC -> window-relative byte base."""
        pages = (nbytes + VGP_PAGE - 1) // VGP_PAGE
        if self.ap is not None:
            base_w = self.ap.ap_alloc(nbytes)
            return None if base_w < 0 else base_w * 4
        run = start = 0
        for i, u in enumerate(self.pg_pages):
            if u == 0:
                if run == 0:
                    start = i
                run += 1
                if run == pages:
                    for j in range(start, start + pages):
                        self.pg_pages[j] = 1
                    return start * VGP_PAGE
            else:
                run = 0
        return None

    def pg_free(self, byte_base, nbytes):
        if self.ap is not None:
            self.ap.ap_free(byte_base // 4, nbytes)
            return
        b = byte_base // VGP_PAGE
        for j in range(b, b + (nbytes + VGP_PAGE - 1) // VGP_PAGE):
            self.pg_pages[j] = 0

    def _disp_assembly_lost(self, session, aux):
        """§7b/5a-ii: replay one command buffer's records the way
        cmdexec does at submit; True -> DEVICE_LOST on the fence."""
        T = session['T']
        bound = 0
        dset = [0] * 4
        nbinds = 0
        for r in self.recs[aux]:
            ct = r['ctype']
            # generic per-record handle resolve (cmdexec StResReq)
            for i in range(4):
                h = r['handle'][i]
                if h:
                    st, _s, _e = self.resolve(h, r['kind'][i])
                    if st != 'OK':
                        return True
            if ct == T['vkCmdBindPipeline']:
                bound = r['handle'][0]
            elif ct == T['vkCmdBindDescriptorSets']:
                abase = r['imm'][7] & 0xFFFF
                fs = r['imm'][1] & 0xFFFF
                nset = r['imm'][2] & 0xFFFF
                for i in range(max(0, min(nset, 4 - fs))):
                    dset[fs + i] = self.pay_arena[aux].get(abase + i, 0)
            elif ct == T['vkCmdDispatch']:
                if bound == 0:
                    return True
                st, _s, _e = self.resolve(bound, KIND['VkPipeline'])
                if st != 'OK':
                    return True
                for dh in dset:
                    if dh == 0:
                        continue
                    st, _ds, de = self.resolve(
                        dh, KIND['VkDescriptorSet'])
                    if st != 'OK':
                        return True
                    base = (de['aux'] >> 48) & 0xFFFF
                    nw = (de['aux'] >> 32) & 0xFFFF
                    for j in range(nw // 4):
                        if nbinds >= 16:
                            return True
                        w3 = self.pay.get(base + j * 4 + 3, 0)
                        if w3 & 0x80000000:
                            return True
                        bh = self.pay.get(base + j * 4, 0)
                        if bh == 0:
                            return True
                        bst, bs, be = self.resolve(
                            bh, KIND['VkBuffer'])
                        if bst != 'OK':
                            return True
                        ms = be.get('bind_mem', -1)
                        if ms < 0 or ms >= self.SLOTS \
                                or self.ent[ms] is None:
                            return True
                        nbinds += 1
            elif ct == T.get('vkCmdDispatchIndirect', -1):
                # issues on the work port -> shcore UNSUPPORTED -> lost
                return True
        return False

    def reset_ctx(self, ctx=0):
        """-> (retired, pinned remaining)."""
        ret = pin = 0
        pk = tuple(KIND[k] for k in PAY_KINDS)
        for s, e in enumerate(self.ent):
            if e is None or e['ctx'] != ctx:
                continue
            if e['pins']:
                pin += 1
                continue
            # §7b/5a-ii: release aux-held resources the same way the
            # RETIRE arm does
            if e['kind'] in (KIND['VkShaderModule'], KIND['VkPipeline']):
                self.sm_unref(e['aux'] & 7)
            elif e['kind'] == KIND['VkDeviceMemory']:
                self.pg_free((e['aux'] >> 32) & 0xFFFFFFFF, e['size'])
            if e['kind'] in pk and (e['aux'] >> 32):
                self.pay_free((e['aux'] >> 48) & 0xFFFF,
                              (e['aux'] >> 32) & 0xFFFF)
            self.ent[s] = None
            self.idmap.pop(e['id'], None)
            self.live_cnt -= 1
            ret += 1
        return ret, pin

    # ---- front step ----------------------------------------------------------
    def _err(self, status):
        return VK_ERR_OOM if status in ('FULL',) else VK_ERR_UNKNOWN

    def _lu_slots(self, rec):
        return [i for i in range(8)
                if rec['qv'] >> i & 1 and rec['kind'][i]
                and rec['role'][i] in (0, 3)]

    def step(self, name, ty, words, rec, rep_sim, session):
        """-> dict(result, rep, record, work, fault).  `session` carries
        the CS layout (words list) for RBLOB echo."""
        info = self.m.cmd_info[name]
        act = info['act']
        cls = act['class']
        out = {'result': VK_OK, 'rep': [], 'record': None,
               'work': [], 'fault': rec['fault'],
               'payw': [], 'arenaw': [], 'null_mask': set()}
        ew = list(self.m.profile_words_pool[:64])
        ew += [0] * (64 - len(ew))
        if rec['fault']:
            out['result'] = VK_ERR_UNKNOWN
            self._reply(out, words, rec, rep_sim, info, ew)
            return out
        if len(rec['pay']) > PAY_STAGE:
            # §7b: payload staging overflow is a decode-class fault
            out['result'] = VK_ERR_UNKNOWN
            out['fault'] = APU_VN_FAULT_PAYLOAD
            return out
        if cls == 'UNSUPPORTED':
            out['result'] = VK_ERR_FEATURE
            return out
        # resolve pass (vnfront StResolve/StResCpl)
        hnd = [0] * 8
        lu = []
        for i in self._lu_slots(rec):
            if not rec['q'][i]:
                continue
            st, s, e = self.resolve(rec['q'][i], rec['kind'][i])
            if st != 'OK':
                out['result'] = VK_ERR_UNKNOWN
                self._reply(out, words, rec, rep_sim, info, ew)
                return out
            hnd[i] = (e['gen'] << 16) | s
            lu.append(i)

        def ent_of(i):
            st, _s, e = self.resolve(hnd[i], 0)
            return e

        ct = rec['type']
        obj_kind = act['obj_kind'] or 0

        def blob_ids(slot):
            off, wn = rec['blob'][slot]
            ids = []
            for i in range(wn // 2):
                ids.append(words[off + 2 * i] |
                           (words[off + 2 * i + 1] << 32))
            return ids

        if cls in ('NOP_OK', 'MAP'):
            pass

        elif cls == 'UPDATE':
            # §7b: vkUpdateDescriptorSets walks the staged writes --
            # per write {dstSet(2), dstBinding, dstArrayElement,
            # descriptorCount, descriptorType}, then per buffer info
            # {buffer(2), offset(2), range(2)} for types 6/7
            if ct == session['T']['vkUpdateDescriptorSets'] \
                    and rec['imm'][0] != 0:
                stg = 0
                pay = rec['pay']
                for _wi in range(rec['imm'][0] & 0xFFFF):
                    dst = pay[stg] | (pay[stg + 1] << 32)
                    dstb, dcnt, dtype = (pay[stg + 2], pay[stg + 4],
                                         pay[stg + 5])
                    stg += 6
                    st, ds, de = self.resolve(
                        dst, KIND['VkDescriptorSet'])
                    if st != 'OK':
                        out['result'] = VK_ERR_UNKNOWN
                        break
                    dset_base = (de['aux'] >> 48) & 0xFFFF
                    dset_words = (de['aux'] >> 32) & 0xFFFF
                    nbind = dset_words >> 2
                    for j in range(dcnt & 0xFFFF):
                        if dtype not in (6, 7):
                            idx = (dstb + j) & 0xFFFF \
                                if dstb + j < nbind else \
                                (nbind - 1) & 0xFFFF
                            entw = (0, 0, 0, dtype | 0x80000000)
                        else:
                            buf = pay[stg] | (pay[stg + 1] << 32)
                            off_lo, rng_lo = pay[stg + 2], pay[stg + 4]
                            stg += 6
                            bst, bs, _be = self.resolve(
                                buf, KIND['VkBuffer'])
                            if dstb + j >= nbind:
                                idx = (nbind - 1) & 0xFFFF
                                entw = (0, 0, 0, dtype | 0x80000000)
                            else:
                                idx = (dstb + j) & 0xFFFF
                                hndl = ((self.ent[bs]['gen'] << 16) | bs) \
                                    if bst == 'OK' else 0
                                w3 = dtype if bst == 'OK' \
                                    else dtype | 0x80000000
                                entw = (hndl, off_lo, rng_lo, w3)
                        if dset_words:
                            for k, w in enumerate(entw):
                                a = dset_base + idx * 4 + k
                                w &= 0xFFFFFFFF
                                self.pay[a] = w
                                out['payw'].append((a, w))
                    if out['result'] != VK_OK:
                        break

        elif cls == 'QUERY':
            ek = self.exec_kind(ct)
            if ek == 'BUFREQ':
                e = ent_of(lu[1] if len(lu) > 1 else lu[0])
                sz = (e['aux'] & 0xFFFFFF00)
                ew[0], ew[1] = sz & 0xFFFFFFFF, (sz >> 32) & 0xFFFFFFFF
                ew[2], ew[3], ew[4] = 256, 0, 3
            elif ek == 'IMGREQ':
                e = ent_of(lu[1] if len(lu) > 1 else lu[0])
                sz = (e['aux'] >> 8) << 12
                ew[0], ew[1] = sz & 0xFFFFFFFF, (sz >> 32) & 0xFFFFFFFF
                ew[2], ew[3], ew[4] = 4096, 0, 3
            elif ek == 'ENUMPD':
                ew[0] = 1
                ids = blob_ids(0)
                if rec['imm'][0] and len(ids) >= 1:
                    par = hnd[act['parent_q']] \
                        if act['parent_q'] != 7 else 0
                    st, _h, _s = self.alloc(ids[0],
                                            KIND['VkPhysicalDevice'], par)
                    if st != 'OK':
                        out['result'] = self._err(st)
            elif ek == 'ENUMEXT':
                ew[0] = ew[1] = 0
            elif ek == 'MRES':
                # vkGetMemoryResourcePropertiesMESA: memoryTypeBits = 3
                ew[0] = 3

        elif cls == 'ALLOC':
            new = next((i for i in range(8)
                        if rec['qv'] >> i & 1 and rec['role'][i] == 1), -1)
            par = hnd[act['parent_q']] if act['parent_q'] != 7 else 0
            if new >= 0:
                # executor fence index -> aux[7:0] (arena-free check
                # happens before the ObjTab alloc, mirroring the front)
                fidx = -1
                if obj_kind == KIND['VkFence']:
                    fidx = next((i for i in range(self.FENCES)
                                 if not self.falloc[i]), -1)
                if obj_kind == KIND['VkFence'] and fidx < 0:
                    out['result'] = VK_ERR_OOM
                elif obj_kind in (KIND['VkDescriptorSetLayout'],
                                  KIND['VkPipelineLayout']):
                    # §7b: layout objects take an ObjPay extent BEFORE
                    # the ObjTab alloc; FULL -> OOM, object not created
                    pn = 1 if obj_kind == KIND['VkDescriptorSetLayout'] \
                        else 2
                    nw = len(rec['pay']) + pn
                    pbase = self.pay_alloc(nw)
                    if pbase is None:
                        out['result'] = VK_ERR_OOM
                    else:
                        st, h, slot = self.alloc(rec['q'][new], obj_kind,
                                                 par)
                        if st != 'OK':
                            self.pay_free(pbase, nw)
                            out['result'] = self._err(st)
                        else:
                            prep = rec['imm'][1:1 + pn]
                            for i, w in enumerate(prep + list(rec['pay'])):
                                w &= 0xFFFFFFFF
                                self.pay[pbase + i] = w
                                out['payw'].append((pbase + i, w))
                            self.setauxhi(h, (pbase << 16) | nw)
                elif obj_kind == KIND['VkShaderModule']:
                    # §7b/5a-ii: sm ALLOC -> stream blob[0] (pCode) into
                    # the slot's staging -> ObjTab ALLOC ->
                    # aux[2:0]=slot, aux[31:16]=nwords
                    sh = self.sm_alloc()
                    if sh is None:
                        out['result'] = VK_ERR_OOM
                    else:
                        st, h, slot = self.alloc(rec['q'][new], obj_kind,
                                                 par)
                        if st != 'OK':
                            self.sm_unref(sh)
                            out['result'] = self._err(st)
                        else:
                            off, wn = rec['blob'][0]
                            self.sh_code[sh] = [
                                w & 0xFFFFFFFF
                                for w in words[off:off + wn]]
                            self.setaux(h, 0xFFFF0007,
                                        ((wn & 0xFFFF) << 16) | sh)
                elif obj_kind == KIND['VkDeviceMemory']:
                    # §7b/5a-ii: vgpages ALLOC(size) before the object;
                    # aux[63:32] = page base.  FULL -> OOM, no object
                    ds = next((i for i in range(8)
                               if rec['qv'] >> i & 1
                               and not rec['kind'][i]), -1)
                    msz = rec['q'][ds] if ds >= 0 else 0
                    pg = self.pg_alloc(msz)
                    if pg is None:
                        out['result'] = VK_ERR_OOM
                    else:
                        st, h, slot = self.alloc(rec['q'][new], obj_kind,
                                                 par)
                        if st != 'OK':
                            self.pg_free(pg, msz)
                            out['result'] = self._err(st)
                        else:
                            self.ent[h & 0xFFFF]['size'] = msz
                            self.setauxhi(h, pg)
                else:
                    st, h, slot = self.alloc(rec['q'][new], obj_kind, par)
                    if st != 'OK':
                        out['result'] = self._err(st)
                    elif obj_kind == KIND['VkFence']:
                        st2, _ = self.setaux(h, 0xFF, fidx)
                        if st2 != 'OK':
                            out['result'] = VK_ERR_UNKNOWN
                        else:
                            self.falloc[fidx] = 1
                    elif ct in (session['T']['vkCreateBuffer'],
                                session['T']['vkCreateImage']):
                        if ct == session['T']['vkCreateBuffer']:
                            ds = next((i for i in range(8)
                                       if rec['qv'] >> i & 1
                                       and not rec['kind'][i]), -1)
                            sz = rec['q'][ds] if ds >= 0 else 0
                            blocks = (sz + 255) >> 8
                            self.ent[h & 0xFFFF]['size'] = sz
                        else:
                            sz = rec['imm'][3] * rec['imm'][4] * 4
                            blocks = (sz + 4095) >> 12
                            self.ent[h & 0xFFFF]['size'] = sz
                        st2, _s2 = self.setaux(h, 0xFFFFFF00,
                                               (blocks & 0xFFFFFF) << 8)
                        if st2 != 'OK':
                            out['result'] = VK_ERR_UNKNOWN
            else:
                slot = (act['flags'] >> 1) & 1
                if obj_kind == KIND['VkDescriptorSet']:
                    # §7b: per set -- staged layout id -> LOOKUP ->
                    # bindingCount from its payload word 0 -> ObjPay
                    # alloc(nbind*4) + zeroed/unsupported entries ->
                    # aux[63:32] = {base,words}
                    for ei, idv in enumerate(blob_ids(slot)):
                        lay = (rec['pay'][2 * ei]
                               | (rec['pay'][2 * ei + 1] << 32))
                        st, ls, le = self.resolve(
                            lay, KIND['VkDescriptorSetLayout'])
                        if st != 'OK':
                            out['result'] = VK_ERR_UNKNOWN
                            break
                        lay_base = (le['aux'] >> 48) & 0xFFFF
                        nbind = self.pay.get(lay_base, 0)
                        nw = nbind * 4
                        pbase = 0
                        if nw:
                            pbase = self.pay_alloc(nw)
                            if pbase is None:
                                out['result'] = VK_ERR_OOM
                                break
                        st, h, s = self.alloc(idv, obj_kind, par)
                        if st != 'OK':
                            if nw:
                                self.pay_free(pbase, nw)
                            out['result'] = self._err(st)
                            break
                        for j in range(nbind):
                            ty = self.pay.get(lay_base + 1 + j * 4 + 1, 0)
                            cnt = self.pay.get(
                                lay_base + 1 + j * 4 + 2, 0)
                            w3 = 0x80000000 if (cnt > 1 or
                                                ty not in (6, 7)) else 0
                            for k, w in enumerate((0, 0, 0, w3)):
                                a = pbase + j * 4 + k
                                self.pay[a] = w
                                out['payw'].append((a, w))
                        self.setauxhi(h, (pbase << 16) | nw)
                elif obj_kind == KIND['VkPipeline']:
                    # §7b/5a-ii: the staged payload is consumed per
                    # element {module id(2), spec presence(1), layout
                    # id(2)}; spec/module/layout miss/commit fault ->
                    # VK_ERROR_UNKNOWN + VK_NULL_HANDLE echo; the object
                    # keeps aux[2:0]=slot, aux[63:32]=layout handle
                    for ei, idv in enumerate(blob_ids(slot)):
                        pay = rec['pay']
                        spec = pay[5 * ei + 2] if 5 * ei + 2 < len(pay) \
                            else 1
                        if spec:
                            out['result'] = VK_ERR_UNKNOWN
                            out['null_mask'].add(ei)
                            continue
                        mid = pay[5 * ei] | (pay[5 * ei + 1] << 32)
                        mst, _ms, me = self.resolve(
                            mid, KIND['VkShaderModule'])
                        if mst != 'OK':
                            out['result'] = VK_ERR_UNKNOWN
                            out['null_mask'].add(ei)
                            continue
                        mslot = me['aux'] & 7
                        lid = pay[5 * ei + 3] | (pay[5 * ei + 4] << 32)
                        lst, ls, le = self.resolve(
                            lid, KIND['VkPipelineLayout'])
                        if lst != 'OK':
                            out['result'] = VK_ERR_UNKNOWN
                            out['null_mask'].add(ei)
                            continue
                        if not self.sh_commit_ok(mslot):
                            out['result'] = VK_ERR_UNKNOWN
                            out['null_mask'].add(ei)
                            continue
                        self.sm_ref(mslot)
                        st, h, s = self.alloc(idv, obj_kind, par)
                        if st != 'OK':
                            self.sm_unref(mslot)
                            out['result'] = self._err(st)
                            out['null_mask'].add(ei)
                            continue
                        self.setaux(h, 0x7, mslot)
                        self.setauxhi(h, (le['gen'] << 16) | ls)
                else:
                    for idv in blob_ids(slot):
                        free = next((i for i in range(self.CB_BUFS)
                                     if not self.cb_alloc[i]), -1)
                        if obj_kind == KIND['VkCommandBuffer'] \
                                and free < 0:
                            out['result'] = VK_ERR_OOM
                            break
                        st, h, s = self.alloc(idv, obj_kind, par)
                        if st != 'OK':
                            out['result'] = self._err(st)
                            break
                        if obj_kind == KIND['VkCommandBuffer']:
                            st2, _ = self.setaux(h, 0xFF, free)
                            if st2 != 'OK':
                                out['result'] = VK_ERR_UNKNOWN
                                break
                            self.cb_alloc[free] = 1
                            self.cb_hnd[free] = h
                            self.cb_pool[free] = hnd[lu[1]] \
                                if len(lu) > 1 else 0

        elif cls == 'RETIRE':
            rt = next((i for i in range(8)
                       if rec['qv'] >> i & 1 and rec['role'][i] == 2), -1)
            ids = ([rec['q'][rt]] if rt >= 0 else blob_ids(0))
            pk = tuple(KIND[k] for k in PAY_KINDS)
            ar = tuple(KIND[k] for k in AUXRET_KINDS)
            for idv in ids:
                aux = 0
                aux_full = 0
                e_sz = 0
                pay_b = pay_w = 0
                if obj_kind in (KIND['VkCommandBuffer'], KIND['VkFence']):
                    st, s, e = self.resolve(idv, obj_kind)
                    if st != 'OK':
                        out['result'] = VK_ERR_UNKNOWN
                        break
                    aux = e['aux'] & 0xFF
                elif obj_kind in ar:
                    # §7b/5a-ii: aux carries the ShaderCore slot
                    # (modules, pipelines) or the aperture page base
                    # (device memory) -- released after the RETIRE
                    st, s, e = self.resolve(idv, obj_kind)
                    if st != 'OK':
                        out['result'] = VK_ERR_UNKNOWN
                        break
                    aux_full = e['aux']
                    e_sz = e['size']
                elif obj_kind in pk:
                    # §7b: payload kinds take the same pre-LOOKUP; the
                    # extent in aux[63:32] is freed after the RETIRE
                    st, s, e = self.resolve(idv, obj_kind)
                    if st != 'OK':
                        out['result'] = VK_ERR_UNKNOWN
                        break
                    pay_w = (e['aux'] >> 32) & 0xFFFF
                    pay_b = (e['aux'] >> 48) & 0xFFFF
                st, s = self.retire(idv, obj_kind)
                if st != 'OK':
                    out['result'] = self._err(st)
                    break
                if pay_w:
                    self.pay_free(pay_b, pay_w)
                if obj_kind == KIND['VkCommandBuffer'] \
                        and aux < self.CB_BUFS:
                    self.cb_alloc[aux] = 0
                    self.cb_pool[aux] = 0
                    self.cb_hnd[aux] = 0
                elif obj_kind == KIND['VkFence'] and aux < self.FENCES:
                    self.falloc[aux] = 0
                elif obj_kind == KIND['VkShaderModule']:
                    self.sm_unref(aux_full & 7)
                elif obj_kind == KIND['VkPipeline']:
                    self.sm_unref(aux_full & 7)
                elif obj_kind == KIND['VkDeviceMemory']:
                    self.pg_free((aux_full >> 32) & 0xFFFFFFFF, e_sz)

        elif cls == 'BIND':
            rs, ms = lu[1], lu[2]
            ds = next((i for i in range(8)
                       if rec['qv'] >> i & 1 and not rec['kind'][i]), -1)
            st, _s, e = self.resolve(hnd[rs], 0)
            if st != 'OK':
                out['result'] = VK_ERR_UNKNOWN
            else:
                st2, _s2, me = self.resolve(hnd[ms], 0)
                off = rec['q'][ds] if ds >= 0 else 0
                # §7b: memoryOffset + resource size past the memory's
                # extent is invalid usage -> refused
                if st2 != 'OK' or off + e['size'] > me['size']:
                    out['result'] = VK_ERR_UNKNOWN
                else:
                    e['bind_mem'] = _s2
                    e['bind_off'] = off

        elif cls in ('CB_BEGIN', 'CB_END', 'CB_RESET', 'RECORD'):
            cb_q = act['cb_q']
            e = ent_of(cb_q)
            aux = e['aux'] & 0xFF
            if cls == 'CB_BEGIN':
                if e['state'] != 0:
                    out['result'] = VK_ERR_UNKNOWN
                else:
                    self.rec_state[aux] = 1
                    self.recs[aux] = []
                    # cmdrec BEGIN clears the payload arena bump ptr
                    self.pay_top[aux] = 0
                    self.pay_arena[aux] = {}
                    self.setstate(hnd[cb_q], 0xF, CB_REC)
            elif cls == 'CB_END':
                if not (e['state'] & CB_REC):
                    out['result'] = VK_ERR_UNKNOWN
                else:
                    self.rec_state[aux] = 2
                    self.setstate(hnd[cb_q], 0xF, CB_EXEC)
            elif cls == 'CB_RESET':
                self.rec_state[aux] = 0
                self.recs[aux] = []
                # cmdrec RESET frees the payload arena too
                self.pay_top[aux] = 0
                self.pay_arena[aux] = {}
                self.setstate(hnd[cb_q], 0xF, 0)
            else:
                # §7b: pValues over 128 B joins the INVALID path
                if not (e['state'] & CB_REC) or \
                        (e['state'] & (CB_INV | CB_PEND)) or \
                        (ct == session['T']['vkCmdPushConstants']
                         and rec['imm'][2] > 128):
                    out['result'] = VK_ERR_UNKNOWN
                    self.setstate(hnd[cb_q], 0xF, CB_INV)
                else:
                    rh = [0] * 4
                    rk = [0] * 4
                    rhi = 0
                    for i in range(8):
                        if i == cb_q or i not in self._lu_slots(rec) \
                                or not rec['q'][i] or rhi == 4:
                            continue
                        rh[rhi] = hnd[i]
                        rk[rhi] = rec['kind'][i]
                        rhi += 1
                    if ct in (session['T']['vkCmdBindDescriptorSets'],
                              session['T']['vkCmdBindVertexBuffers']) \
                            and rec['blob'][0][1] >= 2 and rhi < 4:
                        k = (KIND['VkDescriptorSet']
                             if ct ==
                             session['T']['vkCmdBindDescriptorSets']
                             else KIND['VkBuffer'])
                        st, s, be = self.resolve(blob_ids(0)[0], k)
                        if st == 'OK':
                            rh[rhi] = (be['gen'] << 16) | s
                            rk[rhi] = be['kind']
                            rhi += 1
                    recd = {'ctype': ct, 'flags': rec['flags'],
                            'handle': rh, 'kind': rk,
                            'imm': list(rec['imm'][:8]), 'spare': 0}
                    # §7b: BindDS streams resolved set handles then the
                    # dynamic offsets; PushConstants streams the staged
                    # words verbatim -- both through the pay arena
                    pwords = []
                    if ct == session['T']['vkCmdBindDescriptorSets']:
                        nset = rec['imm'][2] & 0xFFFF
                        ndyn = rec['imm'][3] & 0xFFFF
                        for i in range(nset):
                            sid = rec['pay'][2 * i] | \
                                (rec['pay'][2 * i + 1] << 32)
                            bst, bs, be = self.resolve(
                                sid, KIND['VkDescriptorSet'])
                            pwords.append(
                                (be['gen'] << 16) | bs
                                if bst == 'OK' else 0)
                        for i in range(ndyn):
                            pwords.append(
                                rec['pay'][nset * 2 + i] & 0xFFFFFFFF)
                    elif ct == session['T']['vkCmdPushConstants']:
                        pwords = [w & 0xFFFFFFFF for w in rec['pay']]
                    if pwords:
                        abase = self.arena_append(aux, pwords)
                        if abase is None:
                            # PAY_FULL: the record is dropped, the
                            # buffer goes INVALID
                            out['result'] = VK_ERR_UNKNOWN
                            self.setstate(hnd[cb_q], 0xF, CB_INV)
                        else:
                            for i, w in enumerate(pwords):
                                out['arenaw'].append(
                                    (aux, abase + i, w))
                    if out['result'] == VK_OK:
                        self.recs[aux].append(recd)
                        out['record'] = recd

        elif cls == 'SUBMIT':
            fs = next((i for i in range(8)
                       if rec['qv'] >> i & 1 and rec['role'][i] == 3
                       and rec['q'][i]), -1)
            fslot = -1
            if fs >= 0:
                fe = ent_of(fs)
                if fe is not None and (fe['aux'] & 0xFF) < self.FENCES:
                    fslot = fe['aux'] & 0xFF
            cbs = []
            pins = []
            ok = True
            for idv in blob_ids(1):
                st, s, e = self.resolve(idv, KIND['VkCommandBuffer'])
                if st != 'OK' or not (e['state'] & CB_EXEC) or \
                        (e['aux'] & 0xFF) >= self.CB_BUFS or \
                        len(cbs) == 4:
                    out['result'] = VK_ERR_UNKNOWN
                    ok = False
                    break
                cbs.append((s, e, e['aux'] & 0xFF))
            if ok:
                if not cbs:
                    out['result'] = VK_ERR_UNKNOWN
                else:
                    self.pushed += 1
                    work = []
                    lost_any = False
                    for s, e, aux in cbs:
                        e['state'] = CB_PEND
                        pins.append(s)
                        # §7b/5a-ii: replay the buffer's records the
                        # way cmdexec does; a failed assembly marks the
                        # submission lost and no work is issued
                        lost = self._disp_assembly_lost(session, aux)
                        lost_any |= lost
                        if not lost:
                            for r in self.recs[aux]:
                                if self.is_work(r['ctype']):
                                    work.append(r['ctype'])
                        # PIN via cmdexec (at submit)
                        e['pins'] += 1
                    out['work'] = work
                    self.outstanding.append((fslot, cbs, lost_any))
                    # pins are held by the executor until completion;
                    # the TB must not retire them out from under the
                    # front (deterministic PINNED arm)
                    self.work_hold = True
            # (work list also covers pins for the pinned-destroy arm)

        elif cls == 'WAIT':
            wt = {session['T']['vkDeviceWaitIdle']: 'idle',
                  session['T']['vkQueueWaitIdle']: 'idle',
                  session['T']['vkWaitForFences']: 'wait',
                  session['T']['vkResetFences']: 'clr',
                  session['T']['vkGetFenceStatus']: 'stat'}[ct]
            if wt in ('idle', 'wait'):
                # model: the executor finishes all outstanding work by
                # the time the wait completes
                for fslot, cbs, lost in self.outstanding:
                    for s, e, _aux in cbs:
                        e['pins'] -= 1
                    if fslot >= 0:
                        self.fence_sig |= 1 << fslot
                        if lost:
                            self.fence_lost |= 1 << fslot
                self.outstanding = []
                if wt == 'wait':
                    mask = 0
                    for idv in blob_ids(0):
                        st, s, e = self.resolve(idv, KIND['VkFence'])
                        if st != 'OK' or (e['aux'] & 0xFF) >= self.FENCES:
                            out['result'] = VK_ERR_UNKNOWN
                            break
                        mask |= 1 << (e['aux'] & 0xFF)
                    else:
                        if self.fence_lost & mask:
                            out['result'] = VK_ERR_LOST
                        elif ((self.fence_sig & mask) == mask
                              if rec['imm'][1]
                              else (self.fence_sig & mask)):
                            out['result'] = VK_OK
                        else:
                            out['result'] = VK_NOT_READY
            elif wt == 'clr':
                for idv in blob_ids(0):
                    st, s, e = self.resolve(idv, KIND['VkFence'])
                    if st != 'OK' or (e['aux'] & 0xFF) >= self.FENCES:
                        out['result'] = VK_ERR_UNKNOWN
                        break
                    self.fence_sig &= ~(1 << (e['aux'] & 0xFF))
            else:
                fs = lu[1]
                fe = ent_of(fs)
                s = fe['aux'] & 0xFF if fe is not None else 0xFF
                if s >= self.FENCES:
                    out['result'] = VK_ERR_UNKNOWN
                elif self.fence_lost >> s & 1:
                    out['result'] = VK_ERR_LOST
                else:
                    out['result'] = (VK_OK if self.fence_sig >> s & 1
                                     else VK_NOT_READY)

        elif cls == 'POOL_RESET':
            par = hnd[act['parent_q']] if act['parent_q'] != 7 else 0
            for i in range(self.CB_BUFS):
                if self.cb_alloc[i] and self.cb_pool[i] == par:
                    self.rec_state[i] = 0
                    self.recs[i] = []
                    self.setstate(self.cb_hnd[i], 0xF, 0)

        # gate the TB work port from a successful submit until the
        # first WAIT command, so command-buffer pins stay held for the
        # duration a negative arm may probe them
        out['gate'] = self.work_hold and cls != 'WAIT'
        if cls == 'WAIT':
            self.work_hold = False
        self._reply(out, words, rec, rep_sim, info, ew)
        return out

    def _reply(self, out, words, rec, rep_sim, info, ew):
        if rec['fault'] or not info['reply_id'] or \
                not (rec['flags'] & 1) or not (info['act']['flags'] & 1):
            out['rep'] = []
            return
        pos = [0]

        def supply(mpc, n, op, a, b, note):
            w = ew[pos[0]:pos[0] + n]
            w += [0] * (n - len(w))
            pos[0] += n
            return w
        out['rep'] = rep_sim.run(words, rec, out['result'], supply,
                                 null_mask=out['null_mask'])

    def exec_kind(self, ct):
        T = self.m.cmd_info
        nm = {v['type_id']: k for k, v in T.items()}
        name = nm.get(ct, '')
        if 'GetBufferMemoryRequirements' in name:
            return 'BUFREQ'
        if 'GetImageMemoryRequirements' in name:
            return 'IMGREQ'
        if name == 'vkEnumeratePhysicalDevices':
            return 'ENUMPD'
        if name == 'vkEnumerateDeviceExtensionProperties':
            return 'ENUMEXT'
        if name == 'vkGetMemoryResourcePropertiesMESA':
            return 'MRES'
        return 'NONE'

    def is_work(self, ct):
        nm = {v['type_id']: k for k, v in self.m.cmd_info.items()}
        name = nm.get(ct, '')
        return name.startswith('vkCmd') and \
            any(name.startswith('vkCmd' + p) for p in
                ('Draw', 'Dispatch', 'Copy', 'Fill', 'Update',
                 'Clear', 'Blit', 'Resolve', 'ExecuteCommands'))


def sess_rec_words(recd):
    """apu_cmdrec_rec_t -> 16 words, word i = bits [32*i +: 32]."""
    v = recd['spare']
    for i in range(8):
        v |= (recd['imm'][i] & 0xFFFFFFFF) << (32 + 32 * i)
    for i in range(4):
        v |= (recd['kind'][i] & 0xFF) << (288 + 8 * i)
    for i in range(4):
        v |= (recd['handle'][i] & 0xFFFFFFFF) << (320 + 32 * i)
    v |= (recd['flags'] & 0xFFFFFFFF) << 448
    v |= (recd['ctype'] & 0xFFFFFFFF) << 480
    return [(v >> (32 * i)) & 0xFFFFFFFF for i in range(16)]


def build_session(model, asm, sim, rep_sim, enc, gen, rng,
                  pay_words=PAY_WORDS, kind='main'):
    """-> (steps, instances).  Each step: {name, words, out, reset}."""
    m = model
    fm = FrontModel(model, asm, pay_words=pay_words)
    T = {n: i['type_id'] for n, i in m.cmd_info.items()}
    for t in m.reg.type_table.values():
        if t.category == vkxml.VkType.HANDLE:
            KIND[t.name] = m.kind(t.name)

    ses = {'T': T}
    cmds = []
    nid = [0x1000_0000_0000]

    def newid():
        nid[0] += 0x1000_0001
        return nid[0]

    def struct(tyname, **kw):
        ty = m.reg.type_table[tyname]
        d = gen.gen_struct(ty)
        d.update(kw)
        return d

    def cmd(name, reset=False, **over):
        ty = next(t for t in
                  m.gen.supported_types[vkxml.VkType.COMMAND]
                  if t.name == name)
        a = gen.gen_command(name)
        a.update(over)
        if m.cmd_info[name]['act']['flags'] & 1:
            a['_flags'] = 1
        if reset:
            fm.reset()
        words = enc.command(ty, a)
        rec = sim.run(words)
        out = fm.step(name, ty, words, rec, rep_sim, ses)
        cmds.append({'name': name, 'ty': ty, 'args': a, 'words': words,
                     'rec': rec, 'out': out, 'reset': reset,
                     'live': fm.live_cnt})
        return out

    I = {k: newid() for k in
         ('inst', 'pd', 'dev', 'queue', 'mem', 'buf', 'img', 'sm', 'dsl',
          'pl', 'pipe', 'dp', 'ds', 'ds2', 'cp', 'cb', 'fen')}

    if kind == 'payfull':
        # §7b ObjPay-FULL arm.  VkDescriptorSetLayoutBinding is bound-
        # capped at 64 elements, so a single layout can stage at most
        # 1+4*64 = 257 words (5 chunks).  At --paywords 512 (8 chunks):
        # dsl_a takes 5, dsl_b needs 5 with only 3 free -> OOM, dsl_c
        # (2 chunks) still fits and proves the allocator keeps working.
        if pay_words != 512:
            raise SystemExit('--payfull-session expects --paywords 512')
        P = {k: newid() for k in ('inst', 'pd', 'dev', 'dla', 'dlb',
                                  'dlc')}
        cmd('vkCreateInstance', pInstance=P['inst'])
        cmd('vkEnumeratePhysicalDevices', instance=P['inst'],
            pPhysicalDeviceCount=1, pPhysicalDevices=[P['pd']])
        cmd('vkCreateDevice', physicalDevice=P['pd'],
            pCreateInfo=struct('VkDeviceCreateInfo'), pDevice=P['dev'])

        def dsl_ci(n):
            return struct(
                'VkDescriptorSetLayoutCreateInfo', bindingCount=n,
                pBindings=[struct('VkDescriptorSetLayoutBinding',
                                  binding=i & 0x3F, descriptorType=7,
                                  descriptorCount=1, stageFlags=0x20,
                                  pImmutableSamplers=[])
                           for i in range(n)])

        cmd('vkCreateDescriptorSetLayout', device=P['dev'],
            pCreateInfo=dsl_ci(64), pSetLayout=P['dla'])
        cmd('vkCreateDescriptorSetLayout', device=P['dev'],
            pCreateInfo=dsl_ci(64), pSetLayout=P['dlb'])
        cmd('vkCreateDescriptorSetLayout', device=P['dev'],
            pCreateInfo=dsl_ci(24), pSetLayout=P['dlc'])
        cmd('vkDestroyDescriptorSetLayout', device=P['dev'],
            descriptorSetLayout=P['dlc'])
        cmd('vkDestroyDescriptorSetLayout', device=P['dev'],
            descriptorSetLayout=P['dla'])
        cmd('vkDestroyDescriptorSetLayout', device=P['dev'],
            descriptorSetLayout=P['dlb'])
        cmd('vkDestroyDevice', device=P['dev'])
        cmd('vkDestroyInstance', instance=P['inst'])
        return cmds, fm

    # ---------------- positive session ------------------------------------
    cmd('vkCreateInstance', pInstance=I['inst'])
    cmd('vkEnumeratePhysicalDevices', instance=I['inst'],
        pPhysicalDeviceCount=1, pPhysicalDevices=[I['pd']])
    cmd('vkGetPhysicalDeviceProperties', physicalDevice=I['pd'],
        pProperties=struct('VkPhysicalDeviceProperties'))
    cmd('vkGetPhysicalDeviceProperties2', physicalDevice=I['pd'],
        pProperties=struct('VkPhysicalDeviceProperties2',
                           pNext=[struct('VkPhysicalDeviceSubgroup'
                                         'Properties')]))
    cmd('vkGetPhysicalDeviceFeatures2', physicalDevice=I['pd'],
        pFeatures=struct('VkPhysicalDeviceFeatures2',
                         pNext=[struct('VkPhysicalDeviceMultiview'
                                       'Features')]))
    cmd('vkGetPhysicalDeviceMemoryProperties2', physicalDevice=I['pd'],
        pMemoryProperties=struct('VkPhysicalDeviceMemoryProperties2'))
    cmd('vkEnumerateDeviceExtensionProperties', physicalDevice=I['pd'],
        pLayerName=None, pPropertyCount=0, pProperties=[])
    cmd('vkCreateDevice', physicalDevice=I['pd'],
        pCreateInfo=struct(
            'VkDeviceCreateInfo',
            queueCreateInfoCount=1,
            pQueueCreateInfos=[struct(
                'VkDeviceQueueCreateInfo', queueFamilyIndex=0,
                queueCount=1, pQueuePriorities=[0x3F800000])],
            pEnabledFeatures=None,
            enabledExtensionCount=0, ppEnabledExtensionNames=[],
            enabledLayerCount=0, ppEnabledLayerNames=[]),
        pDevice=I['dev'])
    cmd('vkGetDeviceQueue', device=I['dev'], queueFamilyIndex=0,
        queueIndex=0, pQueue=I['queue'])
    cmd('vkAllocateMemory', device=I['dev'],
        pAllocateInfo=struct('VkMemoryAllocateInfo',
                             allocationSize=0x40000,
                             memoryTypeIndex=1),
        pMemory=I['mem'])
    cmd('vkCreateBuffer', device=I['dev'],
        pCreateInfo=struct('VkBufferCreateInfo', size=4096,
                           usage=0x60 | 0x01, sharingMode=0,
                           queueFamilyIndexCount=0,
                           pQueueFamilyIndices=[]),
        pBuffer=I['buf'])
    cmd('vkGetBufferMemoryRequirements', device=I['dev'], buffer=I['buf'],
        pMemoryRequirements=struct('VkMemoryRequirements'))
    cmd('vkBindBufferMemory', device=I['dev'], buffer=I['buf'],
        memory=I['mem'], memoryOffset=0)
    cmd('vkCreateImage', device=I['dev'],
        pCreateInfo=struct('VkImageCreateInfo', imageType=0,
                           format=37,     # R8G8B8A8_UNORM
                           extent=struct('VkExtent3D', width=64,
                                         height=64, depth=1),
                           mipLevels=1, arrayLayers=1, samples=1,
                           tiling=0, usage=0x02 | 0x08,
                           sharingMode=0, queueFamilyIndexCount=0,
                           pQueueFamilyIndices=[], initialLayout=0),
        pImage=I['img'])
    cmd('vkGetImageMemoryRequirements', device=I['dev'], image=I['img'],
        pMemoryRequirements=struct('VkMemoryRequirements'))
    cmd('vkBindImageMemory', device=I['dev'], image=I['img'],
        memory=I['mem'], memoryOffset=0x10000)
    cmd('vkCreateShaderModule', device=I['dev'],
        pCreateInfo=struct('VkShaderModuleCreateInfo',
                           codeSize=SPV_SESSION_B,
                           pCode=SPV_SESSION),
        pShaderModule=I['sm'])
    cmd('vkCreateDescriptorSetLayout', device=I['dev'],
        pCreateInfo=struct(
            'VkDescriptorSetLayoutCreateInfo', bindingCount=3,
            pBindings=[struct(
                'VkDescriptorSetLayoutBinding', binding=0,
                descriptorType=7,     # STORAGE_BUFFER
                descriptorCount=1, stageFlags=0x20,
                pImmutableSamplers=[]),
                struct(
                'VkDescriptorSetLayoutBinding', binding=1,
                descriptorType=6,     # UNIFORM_BUFFER, count>1
                descriptorCount=2, stageFlags=0x20,
                pImmutableSamplers=[]),
                struct(
                'VkDescriptorSetLayoutBinding', binding=2,
                descriptorType=1,     # COMBINED_IMAGE_SAMPLER (unsup)
                descriptorCount=1, stageFlags=0x20,
                pImmutableSamplers=[])]),
        pSetLayout=I['dsl'])
    cmd('vkCreatePipelineLayout', device=I['dev'],
        pCreateInfo=struct('VkPipelineLayoutCreateInfo',
                           setLayoutCount=1, pSetLayouts=[I['dsl']],
                           pushConstantRangeCount=1,
                           pPushConstantRanges=[struct(
                               'VkPushConstantRange', stageFlags=0x20,
                               offset=0, size=16)]),
        pPipelineLayout=I['pl'])
    cmd('vkCreateComputePipelines', device=I['dev'], pipelineCache=0,
        createInfoCount=1,
        pCreateInfos=[struct(
            'VkComputePipelineCreateInfo',
            stage=struct('VkPipelineShaderStageCreateInfo',
                         stage=0x20, module=I['sm'], pName='main',
                         pSpecializationInfo=None),
            layout=I['pl'], basePipelineHandle=0,
            basePipelineIndex=0)],
        pPipelines=[I['pipe']])
    cmd('vkCreateDescriptorPool', device=I['dev'],
        pCreateInfo=struct('VkDescriptorPoolCreateInfo', maxSets=2,
                           poolSizeCount=1,
                           pPoolSizes=[struct('VkDescriptorPoolSize',
                                              type=7,
                                              descriptorCount=3)]),
        pDescriptorPool=I['dp'])
    cmd('vkAllocateDescriptorSets', device=I['dev'],
        pAllocateInfo=struct('VkDescriptorSetAllocateInfo',
                             descriptorPool=I['dp'],
                             descriptorSetCount=2,
                             pSetLayouts=[I['dsl'], I['dsl']]),
        pDescriptorSets=[I['ds'], I['ds2']])
    cmd('vkUpdateDescriptorSets', device=I['dev'],
        descriptorWriteCount=2,
        pDescriptorWrites=[struct(
            'VkWriteDescriptorSet', dstSet=I['ds'], dstBinding=0,
            dstArrayElement=0, descriptorCount=1, descriptorType=7,
            pImageInfo=[], pTexelBufferView=[],
            pBufferInfo=[struct('VkDescriptorBufferInfo',
                                buffer=I['buf'], offset=0,
                                range=4096)]),
            struct(
            'VkWriteDescriptorSet', dstSet=I['ds2'], dstBinding=0,
            dstArrayElement=0, descriptorCount=1, descriptorType=6,
            pImageInfo=[], pTexelBufferView=[],
            pBufferInfo=[struct('VkDescriptorBufferInfo',
                                buffer=I['buf'], offset=256,
                                range=128)])],
        descriptorCopyCount=0, pDescriptorCopies=[])
    cmd('vkCreateCommandPool', device=I['dev'],
        pCreateInfo=struct('VkCommandPoolCreateInfo',
                           queueFamilyIndex=0),
        pCommandPool=I['cp'])
    cmd('vkAllocateCommandBuffers', device=I['dev'],
        pAllocateInfo=struct('VkCommandBufferAllocateInfo',
                             commandPool=I['cp'], level=0,
                             commandBufferCount=1),
        pCommandBuffers=[I['cb']])
    cmd('vkBeginCommandBuffer', commandBuffer=I['cb'],
        pBeginInfo=struct('VkCommandBufferBeginInfo', flags=0,
                          pInheritanceInfo=None))
    cmd('vkCmdBindPipeline', commandBuffer=I['cb'],
        pipelineBindPoint=1, pipeline=I['pipe'])
    cmd('vkCmdBindDescriptorSets', commandBuffer=I['cb'],
        pipelineBindPoint=1, layout=I['pl'], firstSet=0,
        descriptorSetCount=2, pDescriptorSets=[I['ds'], I['ds2']],
        dynamicOffsetCount=1, pDynamicOffsets=[0x40])
    cmd('vkCmdPushConstants', commandBuffer=I['cb'], layout=I['pl'],
        stageFlags=0x20, offset=0, size=16,
        pValues=b'\x2a\x00\x00\x00\x2b\x00\x00\x00'
                b'\x2c\x00\x00\x00\x2d\x00\x00\x00')
    cmd('vkCmdDispatch', commandBuffer=I['cb'],
        groupCountX=1, groupCountY=1, groupCountZ=1)
    cmd('vkEndCommandBuffer', commandBuffer=I['cb'])
    cmd('vkCreateFence', device=I['dev'],
        pCreateInfo=struct('VkFenceCreateInfo', flags=0),
        pFence=I['fen'])
    cmd('vkQueueSubmit', queue=I['queue'], submitCount=1,
        pSubmits=[struct('VkSubmitInfo', waitSemaphoreCount=0,
                         pWaitSemaphores=[], pWaitDstStageMask=[],
                         commandBufferCount=1,
                         pCommandBuffers=[I['cb']],
                         signalSemaphoreCount=0,
                         pSignalSemaphores=[])],
        fence=I['fen'])
    cmd('vkDeviceWaitIdle', device=I['dev'])
    cmd('vkWaitForFences', device=I['dev'], fenceCount=1,
        pFences=[I['fen']], waitAll=1, timeout=0xFFFFFFFFFFFFFFFF)
    cmd('vkGetFenceStatus', device=I['dev'], fence=I['fen'])
    # destroys in reverse creation order
    cmd('vkDestroyFence', device=I['dev'], fence=I['fen'])
    cmd('vkFreeCommandBuffers', device=I['dev'], commandPool=I['cp'],
        commandBufferCount=1, pCommandBuffers=[I['cb']])
    cmd('vkDestroyCommandPool', device=I['dev'], commandPool=I['cp'])
    cmd('vkFreeDescriptorSets', device=I['dev'], descriptorPool=I['dp'],
        descriptorSetCount=2, pDescriptorSets=[I['ds'], I['ds2']])
    cmd('vkDestroyDescriptorPool', device=I['dev'],
        descriptorPool=I['dp'])
    cmd('vkDestroyPipeline', device=I['dev'], pipeline=I['pipe'])
    cmd('vkDestroyPipelineLayout', device=I['dev'],
        pipelineLayout=I['pl'])
    cmd('vkDestroyDescriptorSetLayout', device=I['dev'],
        descriptorSetLayout=I['dsl'])
    cmd('vkDestroyShaderModule', device=I['dev'], shaderModule=I['sm'])
    cmd('vkDestroyImage', device=I['dev'], image=I['img'])
    cmd('vkDestroyBuffer', device=I['dev'], buffer=I['buf'])
    cmd('vkFreeMemory', device=I['dev'], memory=I['mem'])
    cmd('vkDestroyDevice', device=I['dev'])
    cmd('vkDestroyInstance', instance=I['inst'])

    # ---------------- negative arm 1: vkCmd* before begin -------------------
    A = {k: newid() for k in ('inst', 'pd', 'dev', 'cp', 'cb')}
    cmd('vkCreateInstance', reset=True, pInstance=A['inst'])
    cmd('vkEnumeratePhysicalDevices', instance=A['inst'],
        pPhysicalDeviceCount=1, pPhysicalDevices=[A['pd']])
    cmd('vkCreateDevice', physicalDevice=A['pd'],
        pCreateInfo=struct('VkDeviceCreateInfo'), pDevice=A['dev'])
    cmd('vkCreateCommandPool', device=A['dev'],
        pCreateInfo=struct('VkCommandPoolCreateInfo',
                           queueFamilyIndex=0),
        pCommandPool=A['cp'])
    cmd('vkAllocateCommandBuffers', device=A['dev'],
        pAllocateInfo=struct('VkCommandBufferAllocateInfo',
                             commandPool=A['cp'], level=0,
                             commandBufferCount=1),
        pCommandBuffers=[A['cb']])
    cmd('vkCmdDispatch', commandBuffer=A['cb'],
        groupCountX=1, groupCountY=1, groupCountZ=1)
    cmd('vkFreeCommandBuffers', device=A['dev'], commandPool=A['cp'],
        commandBufferCount=1, pCommandBuffers=[A['cb']])
    cmd('vkDestroyCommandPool', device=A['dev'], commandPool=A['cp'])
    cmd('vkDestroyDevice', device=A['dev'])
    cmd('vkDestroyInstance', instance=A['inst'])

    # ---------------- negative arm 2: submit of unsealed buffer -------------
    B = {k: newid() for k in ('inst', 'pd', 'dev', 'queue', 'cp', 'cb')}
    cmd('vkCreateInstance', reset=True, pInstance=B['inst'])
    cmd('vkEnumeratePhysicalDevices', instance=B['inst'],
        pPhysicalDeviceCount=1, pPhysicalDevices=[B['pd']])
    cmd('vkCreateDevice', physicalDevice=B['pd'],
        pCreateInfo=struct('VkDeviceCreateInfo'), pDevice=B['dev'])
    cmd('vkGetDeviceQueue', device=B['dev'], queueFamilyIndex=0,
        queueIndex=0, pQueue=B['queue'])
    cmd('vkCreateCommandPool', device=B['dev'],
        pCreateInfo=struct('VkCommandPoolCreateInfo',
                           queueFamilyIndex=0),
        pCommandPool=B['cp'])
    cmd('vkAllocateCommandBuffers', device=B['dev'],
        pAllocateInfo=struct('VkCommandBufferAllocateInfo',
                             commandPool=B['cp'], level=0,
                             commandBufferCount=1),
        pCommandBuffers=[B['cb']])
    cmd('vkBeginCommandBuffer', commandBuffer=B['cb'],
        pBeginInfo=struct('VkCommandBufferBeginInfo', flags=0,
                          pInheritanceInfo=None))
    cmd('vkQueueSubmit', queue=B['queue'], submitCount=1,
        pSubmits=[struct('VkSubmitInfo', waitSemaphoreCount=0,
                         pWaitSemaphores=[], pWaitDstStageMask=[],
                         commandBufferCount=1,
                         pCommandBuffers=[B['cb']],
                         signalSemaphoreCount=0,
                         pSignalSemaphores=[])],
        fence=0)
    cmd('vkFreeCommandBuffers', device=B['dev'], commandPool=B['cp'],
        commandBufferCount=1, pCommandBuffers=[B['cb']])
    cmd('vkDestroyCommandPool', device=B['dev'], commandPool=B['cp'])
    cmd('vkDestroyDevice', device=B['dev'])
    cmd('vkDestroyInstance', instance=B['inst'])

    # --------------- negative arm 3: destroy of pinned buffer ---------------
    # §7b/5a-ii: a dispatch only reaches the work port when a live
    # pipeline is bound, so the arm creates its own module+pipeline;
    # the gated work port then keeps the submission pinned
    C = {k: newid() for k in ('inst', 'pd', 'dev', 'queue', 'sm', 'pl',
                              'pipe', 'cp', 'cb')}
    cmd('vkCreateInstance', reset=True, pInstance=C['inst'])
    cmd('vkEnumeratePhysicalDevices', instance=C['inst'],
        pPhysicalDeviceCount=1, pPhysicalDevices=[C['pd']])
    cmd('vkCreateDevice', physicalDevice=C['pd'],
        pCreateInfo=struct('VkDeviceCreateInfo'), pDevice=C['dev'])
    cmd('vkGetDeviceQueue', device=C['dev'], queueFamilyIndex=0,
        queueIndex=0, pQueue=C['queue'])
    cmd('vkCreateShaderModule', device=C['dev'],
        pCreateInfo=struct('VkShaderModuleCreateInfo',
                           codeSize=SPV_SESSION_B,
                           pCode=SPV_SESSION),
        pShaderModule=C['sm'])
    cmd('vkCreatePipelineLayout', device=C['dev'],
        pCreateInfo=struct('VkPipelineLayoutCreateInfo',
                           setLayoutCount=0, pSetLayouts=[],
                           pushConstantRangeCount=0,
                           pPushConstantRanges=[]),
        pPipelineLayout=C['pl'])
    cmd('vkCreateComputePipelines', device=C['dev'], pipelineCache=0,
        createInfoCount=1,
        pCreateInfos=[struct(
            'VkComputePipelineCreateInfo',
            stage=struct('VkPipelineShaderStageCreateInfo',
                         stage=0x20, module=C['sm'], pName='main',
                         pSpecializationInfo=None),
            layout=C['pl'], basePipelineHandle=0,
            basePipelineIndex=0)],
        pPipelines=[C['pipe']])
    cmd('vkCreateCommandPool', device=C['dev'],
        pCreateInfo=struct('VkCommandPoolCreateInfo',
                           queueFamilyIndex=0),
        pCommandPool=C['cp'])
    cmd('vkAllocateCommandBuffers', device=C['dev'],
        pAllocateInfo=struct('VkCommandBufferAllocateInfo',
                             commandPool=C['cp'], level=0,
                             commandBufferCount=1),
        pCommandBuffers=[C['cb']])
    cmd('vkBeginCommandBuffer', commandBuffer=C['cb'],
        pBeginInfo=struct('VkCommandBufferBeginInfo', flags=0,
                          pInheritanceInfo=None))
    cmd('vkCmdBindPipeline', commandBuffer=C['cb'],
        pipelineBindPoint=1, pipeline=C['pipe'])
    cmd('vkCmdDispatch', commandBuffer=C['cb'],
        groupCountX=1, groupCountY=1, groupCountZ=1)
    cmd('vkEndCommandBuffer', commandBuffer=C['cb'])
    cmd('vkQueueSubmit', queue=C['queue'], submitCount=1,
        pSubmits=[struct('VkSubmitInfo', waitSemaphoreCount=0,
                         pWaitSemaphores=[], pWaitDstStageMask=[],
                         commandBufferCount=1,
                         pCommandBuffers=[C['cb']],
                         signalSemaphoreCount=0,
                         pSignalSemaphores=[])],
        fence=0)
    cmd('vkFreeCommandBuffers', device=C['dev'], commandPool=C['cp'],
        commandBufferCount=1, pCommandBuffers=[C['cb']])
    # wait for execution, then the retire succeeds
    cmd('vkDeviceWaitIdle', device=C['dev'])
    cmd('vkFreeCommandBuffers', device=C['dev'], commandPool=C['cp'],
        commandBufferCount=1, pCommandBuffers=[C['cb']])
    cmd('vkDestroyPipeline', device=C['dev'], pipeline=C['pipe'])
    cmd('vkDestroyPipelineLayout', device=C['dev'],
        pipelineLayout=C['pl'])
    cmd('vkDestroyShaderModule', device=C['dev'], shaderModule=C['sm'])
    cmd('vkDestroyCommandPool', device=C['dev'], commandPool=C['cp'])
    cmd('vkDestroyDevice', device=C['dev'])
    cmd('vkDestroyInstance', instance=C['inst'])

    # ------------- negative arm 4: destroy device with children -------------
    D = {k: newid() for k in ('inst', 'pd', 'dev', 'buf')}
    cmd('vkCreateInstance', reset=True, pInstance=D['inst'])
    cmd('vkEnumeratePhysicalDevices', instance=D['inst'],
        pPhysicalDeviceCount=1, pPhysicalDevices=[D['pd']])
    cmd('vkCreateDevice', physicalDevice=D['pd'],
        pCreateInfo=struct('VkDeviceCreateInfo'), pDevice=D['dev'])
    cmd('vkCreateBuffer', device=D['dev'],
        pCreateInfo=struct('VkBufferCreateInfo', size=256,
                           usage=0x01, sharingMode=0,
                           queueFamilyIndexCount=0,
                           pQueueFamilyIndices=[]),
        pBuffer=D['buf'])
    cmd('vkDestroyDevice', device=D['dev'])
    cmd('vkDestroyBuffer', device=D['dev'], buffer=D['buf'])
    cmd('vkDestroyDevice', device=D['dev'])
    cmd('vkDestroyInstance', instance=D['inst'])

    # ------------- negative arm 5: stale handle after destroy ---------------
    E = {k: newid() for k in ('inst', 'pd', 'dev', 'buf')}
    cmd('vkCreateInstance', reset=True, pInstance=E['inst'])
    cmd('vkEnumeratePhysicalDevices', instance=E['inst'],
        pPhysicalDeviceCount=1, pPhysicalDevices=[E['pd']])
    cmd('vkCreateDevice', physicalDevice=E['pd'],
        pCreateInfo=struct('VkDeviceCreateInfo'), pDevice=E['dev'])
    cmd('vkCreateBuffer', device=E['dev'],
        pCreateInfo=struct('VkBufferCreateInfo', size=256,
                           usage=0x01, sharingMode=0,
                           queueFamilyIndexCount=0,
                           pQueueFamilyIndices=[]),
        pBuffer=E['buf'])
    cmd('vkDestroyBuffer', device=E['dev'], buffer=E['buf'])
    cmd('vkGetBufferMemoryRequirements', device=E['dev'], buffer=E['buf'],
        pMemoryRequirements=struct('VkMemoryRequirements'))
    cmd('vkDestroyDevice', device=E['dev'])
    cmd('vkDestroyInstance', instance=E['inst'])

    # ---- §7b helpers for the descriptor/payload arms --------------------
    def dev_prefix(P):
        cmd('vkCreateInstance', reset=True, pInstance=P['inst'])
        cmd('vkEnumeratePhysicalDevices', instance=P['inst'],
            pPhysicalDeviceCount=1, pPhysicalDevices=[P['pd']])
        cmd('vkCreateDevice', physicalDevice=P['pd'],
            pCreateInfo=struct('VkDeviceCreateInfo'), pDevice=P['dev'])

    def dset_prefix(P):
        dev_prefix(P)
        cmd('vkCreateBuffer', device=P['dev'],
            pCreateInfo=struct('VkBufferCreateInfo', size=256,
                               usage=0x60 | 0x01, sharingMode=0,
                               queueFamilyIndexCount=0,
                               pQueueFamilyIndices=[]),
            pBuffer=P['buf'])
        cmd('vkCreateDescriptorSetLayout', device=P['dev'],
            pCreateInfo=struct(
                'VkDescriptorSetLayoutCreateInfo', bindingCount=1,
                pBindings=[struct('VkDescriptorSetLayoutBinding',
                                  binding=0, descriptorType=7,
                                  descriptorCount=1, stageFlags=0x20,
                                  pImmutableSamplers=[])]),
            pSetLayout=P['dsl'])
        cmd('vkCreateDescriptorPool', device=P['dev'],
            pCreateInfo=struct('VkDescriptorPoolCreateInfo', maxSets=1,
                               poolSizeCount=1,
                               pPoolSizes=[struct(
                                   'VkDescriptorPoolSize', type=7,
                                   descriptorCount=1)]),
            pDescriptorPool=P['dp'])
        cmd('vkAllocateDescriptorSets', device=P['dev'],
            pAllocateInfo=struct('VkDescriptorSetAllocateInfo',
                                 descriptorPool=P['dp'],
                                 descriptorSetCount=1,
                                 pSetLayouts=[P['dsl']]),
            pDescriptorSets=[P['ds']])

    def dset_teardown(P, destroy_buf=True):
        cmd('vkFreeDescriptorSets', device=P['dev'],
            descriptorPool=P['dp'], descriptorSetCount=1,
            pDescriptorSets=[P['ds']])
        cmd('vkDestroyDescriptorPool', device=P['dev'],
            descriptorPool=P['dp'])
        cmd('vkDestroyDescriptorSetLayout', device=P['dev'],
            descriptorSetLayout=P['dsl'])
        if destroy_buf:
            cmd('vkDestroyBuffer', device=P['dev'], buffer=P['buf'])
        cmd('vkDestroyDevice', device=P['dev'])
        cmd('vkDestroyInstance', instance=P['inst'])

    # ------- arm 6: update to a destroyed buffer -> unsupported entry ----
    F = {k: newid() for k in ('inst', 'pd', 'dev', 'buf', 'dsl', 'dp',
                              'ds')}
    dset_prefix(F)
    cmd('vkDestroyBuffer', device=F['dev'], buffer=F['buf'])
    cmd('vkUpdateDescriptorSets', device=F['dev'],
        descriptorWriteCount=1,
        pDescriptorWrites=[struct(
            'VkWriteDescriptorSet', dstSet=F['ds'], dstBinding=0,
            dstArrayElement=0, descriptorCount=1, descriptorType=7,
            pImageInfo=[], pTexelBufferView=[],
            pBufferInfo=[struct('VkDescriptorBufferInfo',
                                buffer=F['buf'], offset=0,
                                range=256)])],
        descriptorCopyCount=0, pDescriptorCopies=[])
    dset_teardown(F, destroy_buf=False)

    # ------- arm 7: dstBinding >= nbind -> unsupported entry -------------
    G7 = {k: newid() for k in ('inst', 'pd', 'dev', 'buf', 'dsl', 'dp',
                               'ds')}
    dset_prefix(G7)
    cmd('vkUpdateDescriptorSets', device=G7['dev'],
        descriptorWriteCount=1,
        pDescriptorWrites=[struct(
            'VkWriteDescriptorSet', dstSet=G7['ds'], dstBinding=5,
            dstArrayElement=0, descriptorCount=1, descriptorType=7,
            pImageInfo=[], pTexelBufferView=[],
            pBufferInfo=[struct('VkDescriptorBufferInfo',
                                buffer=G7['buf'], offset=0,
                                range=256)])],
        descriptorCopyCount=0, pDescriptorCopies=[])
    dset_teardown(G7)

    # ------- arm 8: pValues over 128 B -> UNKNOWN + INVALID --------------
    H = {k: newid() for k in ('inst', 'pd', 'dev', 'pl', 'cp', 'cb')}
    dev_prefix(H)
    cmd('vkCreatePipelineLayout', device=H['dev'],
        pCreateInfo=struct('VkPipelineLayoutCreateInfo',
                           setLayoutCount=0, pSetLayouts=[],
                           pushConstantRangeCount=0,
                           pPushConstantRanges=[]),
        pPipelineLayout=H['pl'])
    cmd('vkCreateCommandPool', device=H['dev'],
        pCreateInfo=struct('VkCommandPoolCreateInfo',
                           queueFamilyIndex=0),
        pCommandPool=H['cp'])
    cmd('vkAllocateCommandBuffers', device=H['dev'],
        pAllocateInfo=struct('VkCommandBufferAllocateInfo',
                             commandPool=H['cp'], level=0,
                             commandBufferCount=1),
        pCommandBuffers=[H['cb']])
    cmd('vkBeginCommandBuffer', commandBuffer=H['cb'],
        pBeginInfo=struct('VkCommandBufferBeginInfo', flags=0,
                          pInheritanceInfo=None))
    cmd('vkCmdPushConstants', commandBuffer=H['cb'], layout=H['pl'],
        stageFlags=0x20, offset=0, size=132, pValues=b'\x01' * 132)
    cmd('vkCmdDispatch', commandBuffer=H['cb'],
        groupCountX=1, groupCountY=1, groupCountZ=1)
    cmd('vkFreeCommandBuffers', device=H['dev'], commandPool=H['cp'],
        commandBufferCount=1, pCommandBuffers=[H['cb']])
    cmd('vkDestroyCommandPool', device=H['dev'], commandPool=H['cp'])
    cmd('vkDestroyPipelineLayout', device=H['dev'],
        pipelineLayout=H['pl'])
    cmd('vkDestroyDevice', device=H['dev'])
    cmd('vkDestroyInstance', instance=H['inst'])

    # ------- arm 9: payload staging overflow -> PAYLOAD fault ------------
    # VkDescriptorSetLayoutBinding is bound-capped at 64 elements, so a
    # layout alone can stage at most 256 words.  vkUpdateDescriptorSets
    # stages 5 + 6*descriptorCount words per write (bound: 64 writes x
    # 64 buffer infos); 3 writes x 64 infos = 1167 words > 1024 staged.
    J = {k: newid() for k in ('inst', 'pd', 'dev', 'ds', 'buf')}
    dev_prefix(J)
    cmd('vkUpdateDescriptorSets', device=J['dev'],
        descriptorWriteCount=3,
        pDescriptorWrites=[struct(
            'VkWriteDescriptorSet', dstSet=J['ds'], dstBinding=i,
            dstArrayElement=0, descriptorCount=64, descriptorType=7,
            pImageInfo=[], pTexelBufferView=[],
            pBufferInfo=[struct('VkDescriptorBufferInfo',
                                buffer=J['buf'], offset=4 * k,
                                range=16)
                         for k in range(64)])
            for i in range(3)],
        descriptorCopyCount=0, pDescriptorCopies=[])
    cmd('vkDestroyDevice', device=J['dev'])
    cmd('vkDestroyInstance', instance=J['inst'])

    # ------- arm 10: cmdrec payload arena overflow -> PAY_FULL -----------
    K = {k: newid() for k in ('inst', 'pd', 'dev', 'pl', 'cp', 'cb')}
    dev_prefix(K)
    cmd('vkCreatePipelineLayout', device=K['dev'],
        pCreateInfo=struct('VkPipelineLayoutCreateInfo',
                           setLayoutCount=0, pSetLayouts=[],
                           pushConstantRangeCount=0,
                           pPushConstantRanges=[]),
        pPipelineLayout=K['pl'])
    cmd('vkCreateCommandPool', device=K['dev'],
        pCreateInfo=struct('VkCommandPoolCreateInfo',
                           queueFamilyIndex=0),
        pCommandPool=K['cp'])
    cmd('vkAllocateCommandBuffers', device=K['dev'],
        pAllocateInfo=struct('VkCommandBufferAllocateInfo',
                             commandPool=K['cp'], level=0,
                             commandBufferCount=1),
        pCommandBuffers=[K['cb']])
    cmd('vkBeginCommandBuffer', commandBuffer=K['cb'],
        pBeginInfo=struct('VkCommandBufferBeginInfo', flags=0,
                          pInheritanceInfo=None))
    # 34 staged words each ({offset,size,32 value words}); the 8th
    # append crosses the 256-word arena -> PAY_FULL + INVALID
    for _i in range(8):
        cmd('vkCmdPushConstants', commandBuffer=K['cb'], layout=K['pl'],
            stageFlags=0x20, offset=0, size=128,
            pValues=bytes([_i & 0xFF]) * 128)
    cmd('vkFreeCommandBuffers', device=K['dev'], commandPool=K['cp'],
        commandBufferCount=1, pCommandBuffers=[K['cb']])
    cmd('vkDestroyCommandPool', device=K['dev'], commandPool=K['cp'])
    cmd('vkDestroyPipelineLayout', device=K['dev'],
        pipelineLayout=K['pl'])
    cmd('vkDestroyDevice', device=K['dev'])
    cmd('vkDestroyInstance', instance=K['inst'])

    return cmds, fm


def write_session(name, cmds, fm):
    """Emit ue_sm5_session.hex/.exp and a Mesa-decode instance JSON."""
    hex_lines = []
    exp_lines = []
    base = 0
    insts = []
    for c in cmds:
        words = c['words']
        out = c['out']
        rec = c['rec']
        flags = (1 if out['rep'] else 0) | \
                (2 if out['record'] is not None else 0) | \
                (4 if out['work'] else 0) | (8 if c['reset'] else 0) | \
                (16 if out.get('gate') else 0)
        hex_lines.append('// %s' % c['name'])
        hex_lines += ['%08X' % w for w in words]
        rw = list(out['record'] and sess_rec_words(out['record'])
                  or [0] * 16)
        rep = list(out['rep'][:SESSION_MAX_REP])
        rep += [0] * (SESSION_MAX_REP - len(rep))
        work = list(out['work'][:8]) + [0] * (8 - len(out['work'][:8]))
        exp_lines.append('// %s' % c['name'])
        exp_lines += ['%08X' % base, '%08X' % len(words),
                      '%08X' % rec['type'], '%08X' % flags,
                      '%08X' % (out['result'] & 0xFFFFFFFF),
                      '%08X' % len(out['rep']),
                      '%08X' % c['live'], '%08X' % (out['fault'] & 0xF)]
        exp_lines += ['%08X' % w for w in rw]
        exp_lines += ['%08X' % len(out['work'])]
        exp_lines += ['%08X' % w for w in work]
        exp_lines += ['%08X' % len(out['rep'])]
        exp_lines += ['%08X' % w for w in rep]
        base += len(words)
        if out['rep']:
            insts.append({'cmd': c['name'], 'i': len(insts),
                          'targs': c['args'], 'rep': out['rep'],
                          'result': out['result'], 'ty': c['ty'],
                          'exec_w': []})
    exp_lines.append('// end')
    exp_lines += ['FFFFFFFF', 'FFFFFFFF']
    # §7b: ObjPay / cmdrec-arena write expectations, checked by the TB
    # after the indexed command completes.
    #   tag 1 {tag, rec, n, (addr, word)*n}      -- ObjPay contents
    #   tag 2 {tag, rec, cbuf, n, (idx, word)*n} -- arena contents
    pay_lines = []
    for i, c in enumerate(cmds):
        pw = c['out'].get('payw') or []
        aw = c['out'].get('arenaw') or []
        if pw:
            pay_lines.append('// %s' % c['name'])
            pay_lines += ['%08X' % 1, '%08X' % i, '%08X' % len(pw)]
            for a, w in pw:
                pay_lines += ['%08X' % a, '%08X' % w]
        if aw:
            pay_lines.append('// %s arena' % c['name'])
            pay_lines += ['%08X' % 2, '%08X' % i, '%08X' % aw[0][0],
                          '%08X' % len(aw)]
            for _b, a, w in aw:
                pay_lines += ['%08X' % a, '%08X' % w]
    pay_lines.append('// end')
    pay_lines.append('FFFFFFFF')
    (VEC_DIR / (name + '.hex')).write_text(
        '\n'.join(hex_lines) + '\n', encoding='utf-8')
    (VEC_DIR / (name + '.exp')).write_text(
        '\n'.join(exp_lines) + '\n', encoding='utf-8')
    (VEC_DIR / (name + '.pay')).write_text(
        '\n'.join(pay_lines) + '\n', encoding='utf-8')
    import json as _json
    (VEC_DIR / (name + '.json')).write_text(
        _json.dumps([{'cmd': i['cmd'], 'i': i['i'],
                      'targs': to_jsonable(i['targs']),
                      'rep': i['rep'], 'result': i['result']}
                     for i in insts]), encoding='utf-8')
    return insts


# ---------------------------------------------------------------------------
# §6b transport: virtio-gpu control queue + Venus ring guest-script vectors
# ---------------------------------------------------------------------------

# virtio-gpu UAPI ids (pinned Resolute linux/virtio_gpu.h)
VG_GET_CAPSET_INFO   = 0x0107
VG_GET_CAPSET        = 0x0108
VG_RESOURCE_UNREF    = 0x0102
VG_RESOURCE_CREATE_BLOB = 0x010B
VG_CTX_CREATE        = 0x0200
VG_CTX_DESTROY       = 0x0201
VG_CTX_ATTACH        = 0x0202
VG_CTX_DETACH        = 0x0203
VG_SUBMIT_3D         = 0x0207
VG_MAP_BLOB          = 0x0208
VG_UNMAP_BLOB        = 0x0209
VG_RESP_NODATA       = 0x1100
VG_RESP_CAPSET_INFO  = 0x1102
VG_RESP_CAPSET       = 0x1103
VG_RESP_MAP_INFO     = 0x1106
VG_ERR_UNSPEC        = 0x1200
VG_ERR_RESOURCE      = 0x1203
VG_ERR_CTX           = 0x1204
VG_ERR_PARAM         = 0x1205
VG_FLAG_FENCE        = 0x01
VG_BLOB_HOST3D       = 0x02
VG_BLOB_MAPPABLE     = 0x01
VG_MAP_WC            = 0x03
VG_CAPSET_VENUS      = 4

# tape opcodes (.hex): the TB replays this guest script
TP_END       = 0   # no operands
TP_MEMW      = 1   # [n][addr_lo][addr_hi][w0..]   write guest RAM words
TP_CHAIN     = 2   # [nd][per-desc: alo ahi len dflags]..[flags][flo][fhi][ctx][ridx]
TP_APW       = 3   # [n][ap_off_lo][ap_off_hi][w0..] write aperture words
TP_WAIT_HEAD = 4   # [ring][target_lo][target_hi][timeout]
TP_WAIT_IDLE = 5   # [ring][timeout]   poll ring.status for the IDLE bit
TP_CHECK     = 6   # [what][a0][a1]    consume .exp record(s) (a0,a1 = aux)
TP_DELAY     = 7   # [cycles]          idle the TB clock this long

# CHECK 'what' selectors
CK_HEAD   = 0      # a0=ring
CK_STATUS = 1      # a0=ring
CK_REPLY  = 2      # a0=nwords, a1=aperture byte offset of reply window start
CK_LIVE   = 3
CK_EXTRA  = 4      # a0=ring, a1=extra region byte offset
CK_TAIL   = 5      # a0=ring  (guest-side tail store visible in aperture)
CK_APR    = 6      # a0=nwords, a1=aperture byte offset (Gate 1/2 readback)

# .exp record kinds (8 words each, sentinel FFFFFFFF FFFFFFFF)
EK_RESP   = 1      # {kind, used_len, resp_type, nbody, 0,0,0,0}
EK_BODY   = 2      # {kind, w0, w1, w2, w3, w4, w5, w6}   7 payload words
EK_HEAD   = 3      # {kind, ring, exp_head, 0,0,0,0,0}
EK_STATUS = 4      # {kind, ring, exp_status, 0,0,0,0,0}
EK_REPLY  = 5      # {kind, idx, exp_word, 0,0,0,0,0}
EK_LIVE   = 6      # {kind, exp_live, 0,0,0,0,0,0}
EK_EXTRA  = 7      # {kind, ring, byte_off, exp_word, 0,0,0,0}
EK_FENCE  = 8      # {kind, fence_lo, fence_hi, ring_idx, 0,0,0,0}
EK_TAIL   = 9      # {kind, ring, exp_tail, 0,0,0,0,0}
EK_APRCHK = 10     # {kind, byte_off, model_word, oracle_word, cls} — the
                   # §7a gates at vgtop: Gate 1 aperture==model bit-exact,
                   # Gate 2 aperture vs oracle (cls 0 int/bool exact,
                   # cls 1 float <= 2 ULP)
EK_PAGES  = 11     # {kind, exp_alloc_pages, 0,0,0,0,0} — allocated
                   # aperture pages at a CK_LIVE point (blobs persist;
                   # device-memory pages drain to zero)

# ring status bits (VK_MESA_venus_protocol.xml VkRingStatusFlagsMESA)
RING_IDLE  = 1
RING_FATAL = 2
RING_ALIVE = 4

# aperture geometry (§6b): APU_SHM_BASE window, 4 KiB pages, 1 MiB
APU_SHM_BASE = 0x82000000
AP_PAGE      = 0x1000
AP_WORDS     = 0x40000          # 1 MiB / 4

# guest RAM layout for the script
GREQ  = 0x00004000              # request payload scratch (reused)
GRESP = 0x00010000              # response windows (0x100 stride each)

# the stock ring layout: vn_ring_get_layout(4096, 0) -- Mesa
# vn_ring.c struct layout {alignas(64) u32 head, tail, status; u8 buffer[]}
RING_HEAD_OFF   = 0
RING_TAIL_OFF   = 64
RING_STATUS_OFF = 128
RING_BUF_OFF    = 192


def le64(v):
    return [v & 0xFFFFFFFF, (v >> 32) & 0xFFFFFFFF]


def vg_hdr(ty, flags=0, fence=0, ctx=0, ring_idx=0):
    """virtio_gpu_ctrl_hdr = 24 bytes / 6 words."""
    return [ty, flags, fence & 0xFFFFFFFF, (fence >> 32) & 0xFFFFFFFF,
            ctx, ring_idx]


class TransportModel:
    """Device-side model of vgctl + vnpump + aperture + ObjTab extras.

    Mirrors the §6b engines: control-queue responses, the aperture page
    allocator, the ring table, the reply stream, and the transport
    commands themselves.  `gmem` shadows guest RAM (execbuffers live
    there); `ap` shadows the device aperture (blobs live there).
    """

    def __init__(self, model, asm, sim, rep_sim):
        self.m = model
        self.asm = asm
        self.sim = sim
        self.rep_sim = rep_sim
        self.ap = [0] * AP_WORDS
        self.ap_pages = [0] * (AP_WORDS // (AP_PAGE // 4))
        self.gmem = {}
        self.blobs = {}                   # res_id -> dict
        self.ctxs = {}                    # ctx_id -> dict
        self.rings = [None] * 4
        self.ring_of = {}                 # handle -> slot
        self.reply = None                 # {base_w, size, pos}
        self.rep_log = []                 # (ap_byte_off, words) per reply
        self.exec_log = []                # (name, out) per replying cmd
        self.vq_seqno = 0
        self.stream_err = 0               # execbuf stream error flag
        self.T = {i['type_id']: n for n, i in model.cmd_info.items()}
        self.ACT = {i['type_id']: i['act']['class']
                    for n, i in model.cmd_info.items()}

    # ---- aperture allocator (first-fit, 4 KiB pages) ---------------------
    def ap_alloc(self, size):
        pages = (size + AP_PAGE - 1) // AP_PAGE
        run = 0
        for i, used in enumerate(self.ap_pages):
            run = 0 if used else run + 1
            if run == pages:
                base = (i - pages + 1) * (AP_PAGE // 4)
                for j in range(i - pages + 1, i + 1):
                    self.ap_pages[j] = 1
                return base
        return -1

    def ap_free(self, base_w, size):
        b = base_w // (AP_PAGE // 4)
        for j in range(b, b + (size + AP_PAGE - 1) // AP_PAGE):
            self.ap_pages[j] = 0

    # ---- shared helpers ---------------------------------------------------
    def blob_of(self, rid):
        b = self.blobs.get(rid)
        return b if b is not None and b['mapped'] else None

    def gmem_slice(self, byte_addr, nbytes):
        return [self.gmem.get((byte_addr >> 2) + i, 0)
                for i in range(nbytes // 4)]

    def reply_put(self, rep):
        """Append a front reply at the reply cursor (word writes)."""
        if not rep or self.reply is None:
            return
        base_w = self.reply['base_w'] + (self.reply['pos'] >> 2)
        for i, w in enumerate(rep):
            self.ap[base_w + i] = w
        self.rep_log.append((base_w << 2, list(rep)))
        self.reply['pos'] += len(rep) * 4

    # ---- command-stream executor ------------------------------------------
    def exec_stream(self, get_words, nbytes, fm, ses, log, ctx,
                    ring=None, depth=0):
        """Execute `nbytes` of Venus command stream.  `get_words(off, n)`
        returns n words starting at byte offset `off` inside the stream.
        For rings, `ring` advances head-wise per command; linear streams
        (execbuffers, ExecuteCommandStreams windows) pass ring=None.
        Returns (consumed_bytes, fatal)."""
        pos = 0
        fatal = False
        while pos * 4 < nbytes and not fatal:
            words = get_words(pos, (nbytes - pos * 4) // 4)
            rec = self.sim.run(words)
            name = self.T.get(rec['type'], '?')
            if rec['fault']:
                fatal = True
                break
            cmdw = words[:rec['words']]
            if self.ACT.get(rec['type']) == 'TRANSPORT':
                fatal = self.t_cmd(name, cmdw, rec, fm, ses, log, ctx,
                                   depth)
            else:
                out = fm.step(name, None, cmdw, rec, self.rep_sim, ses)
                self.reply_put(out['rep'])
                if out['rep']:
                    self.exec_log.append((name, out))
            # vn_ring advances head only after the command's reply and
            # side effects complete; a fatal error leaves head at the
            # faulting command
            if fatal:
                break
            pos += rec['words']
            if ring is not None:
                ring['head'] = ring['head0'] + pos * 4
                self.ap[ring['head_base_w']] = ring['head'] & 0xFFFFFFFF
                log.append('ring%d %s head=%d'
                           % (ring['slot'], name, ring['head']))
        return pos * 4, fatal

    def drain_ring(self, ring, fm, ses, log):
        """Consume [head, tail) of one ring (models vnpump's poll)."""
        if ring['fatal']:
            return
        tail = self.ap[ring['tail_base_w']] & 0xFFFFFFFF
        if tail <= ring['head']:
            return
        ring['head0'] = ring['head']
        h0 = ring['head0']
        mask = ring['buf_size'] - 1

        def get(off, n, h0=h0):
            return [self.ap[ring['buf_base_w'] +
                            (((h0 + off * 4 + i * 4) & mask) >> 2)]
                    for i in range(n)]

        _cons, fatal = self.exec_stream(get, tail - ring['head'],
                                        fm, ses, log, ring['ctx'],
                                        ring=ring)
        if fatal:
            ring['fatal'] = True
            self.ap[ring['status_base_w']] |= RING_FATAL
            log.append('ring%d FATAL head=%d'
                       % (ring['slot'], ring['head']))
        ring['idle_count'] = 0

    # ---- transport commands ------------------------------------------------
    def t_cmd(self, name, w, rec, fm, ses, log, ctx, depth):
        """Execute one TRANSPORT command; w = raw command words.
        Returns True on a fatal stream error."""

        def u64(i):
            return w[i] | (w[i + 1] << 32)

        if name == 'vkSetReplyCommandStreamMESA':
            # 0:type 1:flags 2-3:presence64 4:rid 5-6:offset 7-8:size
            rid, off, size = w[4], u64(5), u64(7)
            b = self.blob_of(rid)
            if b is None or off + size > b['size']:
                return True
            self.reply = {'base_w': b['base_w'] + (off >> 2),
                          'size': size, 'pos': 0}
        elif name == 'vkSeekReplyCommandStreamMESA':
            pos = u64(2)
            if self.reply is None or pos > self.reply['size']:
                return True
            self.reply['pos'] = pos
        elif name == 'vkExecuteCommandStreamsMESA':
            if depth:
                return True           # nesting depth 1 only
            n = w[2]
            pos_of = 5 + 5 * n + 2    # streams end + array_size u64
            positions = [u64(pos_of + 2 * i) for i in range(n)]
            for i in range(n):
                s = 5 + 5 * i
                rid, off, size = w[s], u64(s + 1), u64(s + 3)
                b = self.blob_of(rid)
                if b is None or off + size > b['size']:
                    return True
                if self.reply is not None:
                    self.reply['pos'] = positions[i]
                bw = b['base_w'] + (off >> 2)

                def getw(o, nn, bw=bw):
                    return [self.ap[bw + o + j] for j in range(nn)]
                _c, fatal = self.exec_stream(getw, size, fm, ses, log,
                                             ctx, depth=depth + 1)
                if fatal:
                    return True
        elif name == 'vkCreateRingMESA':
            # 0:type 1:flags 2-3:ring 4-5:pres64 6:sType
            # 7..: chain (2 + 4n words), then self fields at 9+4n
            cn = len(rec['chain'])
            f = 9 + 4 * cn
            (flags, rid, off, size, idle, head_o, tail_o, stat_o,
             buf_o, buf_s, ext_o, ext_s) = (
                w[f], w[f + 1], u64(f + 2), u64(f + 4), u64(f + 6),
                u64(f + 8), u64(f + 10), u64(f + 12), u64(f + 14),
                u64(f + 16), u64(f + 18), u64(f + 20))
            handle = u64(2)
            b = self.blob_of(rid)
            if (b is None or handle in self.ring_of
                    or all(r is not None for r in self.rings)
                    or off + size > b['size']
                    or buf_s == 0 or (buf_s & (buf_s - 1))
                    or buf_o + buf_s > size
                    or head_o + 4 > size or tail_o + 4 > size
                    or stat_o + 4 > size
                    or ext_o + ext_s > size):
                return True
            slot = next(i for i, r in enumerate(self.rings) if r is None)
            base_w = b['base_w'] + (off >> 2)
            ring = {'slot': slot, 'handle': handle, 'rid': rid,
                    'ctx': ctx, 'idle_to': idle, 'head': 0,
                    'head_base_w': base_w + (head_o >> 2),
                    'tail_base_w': base_w + (tail_o >> 2),
                    'status_base_w': base_w + (stat_o >> 2),
                    'buf_base_w': base_w + (buf_o >> 2),
                    'buf_size': buf_s,
                    'extra_base_w': base_w + (ext_o >> 2),
                    'extra_size': ext_s, 'fatal': False,
                    'idle_count': 0}
            self.rings[slot] = ring
            self.ring_of[handle] = slot
            # device publishes ALIVE at create (head/tail already 0)
            self.ap[ring['status_base_w']] = RING_ALIVE
        elif name == 'vkDestroyRingMESA':
            handle = u64(2)
            slot = self.ring_of.pop(handle, None)
            if slot is None:
                return True
            self.rings[slot] = None
        elif name == 'vkNotifyRingMESA':
            handle = u64(2)
            slot = self.ring_of.get(handle)
            if slot is None:
                return True
            r = self.rings[slot]
            self.ap[r['status_base_w']] &= ~RING_IDLE
            r['idle_count'] = 0
        elif name == 'vkWriteRingExtraMESA':
            handle, off, val = u64(2), u64(4), w[6]
            slot = self.ring_of.get(handle)
            if slot is None:
                return True
            r = self.rings[slot]
            if off + 4 > r['extra_size']:
                return True
            self.ap[r['extra_base_w'] + (off >> 2)] = val
        elif name == 'vkSubmitVirtqueueSeqnoMESA':
            if u64(4) > self.vq_seqno:
                self.vq_seqno = u64(4)
        elif name == 'vkWaitVirtqueueSeqnoMESA':
            if u64(2) > self.vq_seqno:
                return True            # model: never blocks in fixture
        elif name == 'vkWaitRingSeqnoMESA':
            handle, sq = u64(2), u64(4)
            slot = self.ring_of.get(handle)
            if slot is None or self.rings[slot]['head'] < sq:
                return True
        else:
            return True                # unhandled transport command
        return False


# ---------------------------------------------------------------------------
# guest-script builder (§6b exit scenario) + vector emission
# ---------------------------------------------------------------------------

RING0_H = 0x100          # ring handle values the driver picks
RING1_H = 0x101
RING2_H = 0x102
RING3_H = 0x103

RES_RING0  = 100         # resource ids
RES_REPLY  = 101
RES_RING1  = 102
RES_EXEC   = 103

CTX_ID = 4

RING0_SIZE = RING_BUF_OFF + 2048              # 2240
RING1_SIZE = RING_BUF_OFF + 4096 + 256        # +extra
EXEC_SIZE  = 4096
REPLY_SIZE = 16384
IDLE_TO    = 300                              # idleTimeout cycles


def load_shvec(name):
    """Parse sh_vectors/<name>.{hex,exp} into a compute-session vec.

    Returns {spv, gx, gy, gz, push, binds, inits, outs} where binds is
    a list of {binding, size} and outs a list (in binding order) of
    {ap_off_words, model, oracle, cls, size} for the is_out bindings.
    Commit-fault modules carry commit_fault != 0 and no outputs."""
    shv = REPO / 'verif' / 'tb' / 'apu' / 'sh_vectors'
    hw = [int(l, 16) for l in
          (shv / (name + '.hex')).read_text().split()]
    ew = [int(l, 16) for l in
          (shv / (name + '.exp')).read_text().split()]
    n_spv, n_bind, n_push = hw[0], hw[1], hw[2]
    gx, gy, gz = hw[3], hw[4], hw[5]
    i = 8
    spv = hw[i:i + n_spv]
    i += n_spv
    binds = []
    for _ in range(n_bind):
        st_, bd, sz, _ma = hw[i:i + 4]
        i += 4
        binds.append({'set': st_, 'binding': bd, 'size': sz})
    push = hw[i:i + n_push]
    i += n_push
    inits = []
    for b in binds:
        inits.append(hw[i:i + b['size'] // 4])
        i += b['size'] // 4
    commit_fault = ew[0]
    n_b2 = ew[4]
    j = 5
    ebinds = []
    for _ in range(n_b2):
        bd, sz, _ma, iso = ew[j:j + 4]
        j += 4
        ebinds.append({'binding': bd, 'size': sz, 'is_out': iso})
    outs = []
    if not commit_fault:
        oi = [k for k, b in enumerate(ebinds) if b['is_out']]
        oracle, model_w, cls = [], [], []
        for k in oi:
            oracle.append(ew[j:j + ebinds[k]['size'] // 4])
            j += ebinds[k]['size'] // 4
        for k in oi:
            model_w.append(ew[j:j + ebinds[k]['size'] // 4])
            j += ebinds[k]['size'] // 4
        for k in oi:
            cls.append(ew[j:j + ebinds[k]['size'] // 4])
            j += ebinds[k]['size'] // 4
        for n, k in enumerate(oi):
            outs.append({'bind_idx': k, 'size': ebinds[k]['size'],
                         'oracle': oracle[n], 'model': model_w[n],
                         'cls': cls[n]})
    return {'name': name, 'spv': spv, 'gx': gx, 'gy': gy, 'gz': gz,
            'push': push, 'binds': binds, 'inits': inits,
            'ebinds': ebinds, 'outs': outs,
            'commit_fault': commit_fault}


def build_transport(model, asm, sim, rep_sim, enc, gen, rng,
                    vec=None, variant=''):
    """Build the §6b guest-script tape + .exp records.

    Returns (tape_words, exp_records, doc).  The tape is a self-
    delimiting op stream; .exp records are fixed 8-word expectations
    consumed in order by the TB.  See g6lc_apu_vn_tables.md for the
    op/record formats."""
    tm = TransportModel(model, asm, sim, rep_sim)
    tm.rep_log = []
    fm = FrontModel(model, asm)
    # §7b/5a-ii: device-memory page allocations share the aperture
    # allocator with vgctl blobs (one g6lc_apu_vgpages instance)
    fm.ap = tm
    for t in model.reg.type_table.values():
        if t.category == vkxml.VkType.HANDLE:
            KIND[t.name] = model.kind(t.name)
    ses = {'T': {n: i['type_id'] for n, i in model.cmd_info.items()}}
    capset = list(model.capset_words())
    supported = {t.name: t for t in
                 model.gen.supported_types[vkxml.VkType.COMMAND]}

    tape = []
    exp = []
    doc = {'steps': [], 'log': []}
    log = doc['log']

    def W(*ws):
        tape.extend(ws)

    def rec(k, *v):
        exp.append([k] + list(v) + [0] * (7 - len(v)))

    def note(msg):
        doc['steps'].append(msg)

    def memw(addr, words):
        W(TP_MEMW, len(words), addr & 0xFFFFFFFF,
          (addr >> 32) & 0xFFFFFFFF, *words)
        for i, w in enumerate(words):
            tm.gmem[(addr >> 2) + i] = w

    def apw(off, words):
        W(TP_APW, len(words), off & 0xFFFFFFFF, (off >> 32) & 0xFFFFFFFF,
          *words)
        for i, w in enumerate(words):
            tm.ap[(off >> 2) + i] = w

    resp_n = [0]

    def chain(descs, flags, fence, ctx, ridx, exp_type, exp_body, used):
        W(TP_CHAIN, len(descs))
        for (a, l, wr) in descs:
            W(a & 0xFFFFFFFF, (a >> 32) & 0xFFFFFFFF, l, wr)
        W(flags, fence & 0xFFFFFFFF, (fence >> 32) & 0xFFFFFFFF,
          ctx, ridx)
        rec(EK_RESP, used, exp_type, len(exp_body))
        for w_ in exp_body:
            rec(EK_BODY, w_)
        if flags & VG_FLAG_FENCE:
            rec(EK_FENCE, fence & 0xFFFFFFFF,
                (fence >> 32) & 0xFFFFFFFF, ridx)

    def submit(ty, body, ctx=0, fence=0, ridx=0,
               exp_type=VG_RESP_NODATA, exp_body=None, payload=None,
               used_override=None):
        """One control-queue request.  Response = 6-word hdr + body."""
        exp_body = exp_body or []
        req = vg_hdr(ty, VG_FLAG_FENCE if fence else 0, fence, ctx, ridx)
        req += body
        if payload:
            req += payload
        memw(GREQ, req)
        resp_addr = GRESP + resp_n[0] * 0x100
        resp_n[0] += 1
        resp_words = 6 + len(exp_body)
        used = (len(req) * 4 + resp_words * 4 if used_override is None
                else used_override)
        chain([(GREQ, len(req) * 4, 0), (resp_addr, resp_words * 4, 1)],
              VG_FLAG_FENCE if fence else 0, fence, ctx, ridx,
              exp_type, exp_body, used)

    def vka(name, **args):
        a = gen.gen_command(name)
        a.update(args)
        if model.cmd_info[name]['act']['flags'] & 1:
            a['_flags'] = 1
        return enc.command(supported[name], a), a

    def vk(name, **args):
        return vka(name, **args)[0]

    # ---- ring guest-side ops -------------------------------------------------
    def ring_bind_guest(slot):
        r = tm.rings[slot]
        r['cur'] = 0
        r['blob_byte'] = tm.blobs[r['rid']]['base_w'] << 2

    def ring_put(r, words):
        cur = r['cur']
        off = cur & (r['buf_size'] - 1)
        blob_off = (r['buf_base_w'] << 2) + off
        n = len(words) * 4
        if off + n <= r['buf_size']:
            apw(blob_off, words)
        else:
            s = (r['buf_size'] - off) // 4
            apw(blob_off, words[:s])
            apw(r['buf_base_w'] << 2, words[s:])
        r['cur'] = (cur + n) & 0xFFFFFFFF

    def tail_store(r):
        apw(r['tail_base_w'] << 2, [r['cur'] & 0xFFFFFFFF])

    def check_status(slot):
        r = tm.rings[slot]
        W(TP_CHECK, CK_STATUS, slot, 0)
        rec(EK_STATUS, slot, tm.ap[r['status_base_w']])

    def check_live():
        W(TP_CHECK, CK_LIVE, 0, 0)
        rec(EK_LIVE, fm.live_cnt + len(tm.blobs) + len(tm.ctxs))
        rec(EK_PAGES, sum(tm.ap_pages))

    def check_extra(slot, off):
        r = tm.rings[slot]
        W(TP_CHECK, CK_EXTRA, slot, off)
        rec(EK_EXTRA, slot, off,
            tm.ap[r['extra_base_w'] + (off >> 2)])

    def wait_head(slot):
        r = tm.rings[slot]
        W(TP_WAIT_HEAD, slot, r['head_base_w'] << 2, r['head'], 400000)
        rec(EK_HEAD, slot, r['head'])

    def wait_status(slot, mask, want):
        r = tm.rings[slot]
        W(TP_WAIT_IDLE, slot, r['status_base_w'] << 2, mask, want,
          400000)
        rec(EK_STATUS, slot, tm.ap[r['status_base_w']])

    def wait_idle(slot, want):
        wait_status(slot, RING_IDLE, want)

    def delay(cycles):
        W(TP_DELAY, cycles)
        for rr in tm.rings:
            if rr is None or rr['fatal']:
                continue
            rr['idle_count'] += cycles
            if rr['idle_count'] >= rr['idle_to']:
                tm.ap[rr['status_base_w']] |= RING_IDLE

    def flush_replies():
        for off, rep in tm.rep_log:
            W(TP_CHECK, CK_REPLY, len(rep), off)
            for i, w in enumerate(rep):
                rec(EK_REPLY, i, w)
        tm.rep_log.clear()

    def execbuf(words, ctx=CTX_ID, fence=0):
        """SUBMIT_3D a command stream; the model executes it now."""
        submit(VG_SUBMIT_3D, [len(words) * 4, 0], ctx=ctx, fence=fence,
               exp_type=VG_RESP_NODATA, payload=words)
        base = GREQ + 8 * 4

        def get(o, n, b=base):
            return tm.gmem_slice(b + o * 4, n * 4)
        _c, fatal = tm.exec_stream(get, len(words) * 4, fm, ses, log, ctx)
        return fatal

    # ------------------------------------------------------------------ #
    # Phase A: control-queue init (Mesa virtgpu_init order)                 #
    # ------------------------------------------------------------------ #
    note('A1 GET_CAPSET_INFO idx 0')
    submit(VG_GET_CAPSET_INFO, [0, 0], exp_type=VG_RESP_CAPSET_INFO,
           exp_body=[VG_CAPSET_VENUS, len(capset) * 4, 0, 0])

    note('A2 GET_CAPSET id 4')
    submit(VG_GET_CAPSET, [VG_CAPSET_VENUS, 0],
           exp_type=VG_RESP_CAPSET, exp_body=capset)

    note('A3 CTX_CREATE ctx=4 context_init=4 name=librecore-vn')
    nmb = b'librecore-vn\x00'
    nb = list(nmb) + [0] * (64 - len(nmb))
    name_words = [nb[4 * i] | (nb[4 * i + 1] << 8) | (nb[4 * i + 2] << 16)
                  | (nb[4 * i + 3] << 24) for i in range(16)]
    tm.ctxs[CTX_ID] = {'id': CTX_ID}
    fm.ctx = CTX_ID
    submit(VG_CTX_CREATE, [len(nmb) - 1, VG_CAPSET_VENUS] + name_words,
           ctx=CTX_ID, exp_type=VG_RESP_NODATA)

    def create_blob(rid, size):
        tm.blobs[rid] = {'base_w': tm.ap_alloc(size), 'size': size,
                         'mapped': False, 'ctx': CTX_ID,
                         'mem_backed': False}
        submit(VG_RESOURCE_CREATE_BLOB,
               [rid, VG_BLOB_HOST3D, VG_BLOB_MAPPABLE, 0, 0, 0,
                size & 0xFFFFFFFF, (size >> 32) & 0xFFFFFFFF],
               ctx=CTX_ID, exp_type=VG_RESP_NODATA)

    def create_blob_mem(rid, size, mem_id):
        """§7b/5a-ii: blob_id != 0 -> the resource maps onto the
        VkDeviceMemory aperture extent.  Returns the expected base."""
        mst, _ms, me = fm.resolve(mem_id, KIND['VkDeviceMemory'])
        body = [rid, VG_BLOB_HOST3D, VG_BLOB_MAPPABLE, 0,
                mem_id & 0xFFFFFFFF, (mem_id >> 32) & 0xFFFFFFFF,
                size & 0xFFFFFFFF, (size >> 32) & 0xFFFFFFFF]
        if mst != 'OK':
            submit(VG_RESOURCE_CREATE_BLOB, body, ctx=CTX_ID,
                   exp_type=VG_ERR_RESOURCE)
            return None
        if size > me['size']:
            submit(VG_RESOURCE_CREATE_BLOB, body, ctx=CTX_ID,
                   exp_type=VG_ERR_PARAM)
            return None
        base_b = (me['aux'] >> 32) & 0xFFFFFFFF
        tm.blobs[rid] = {'base_w': base_b >> 2, 'size': me['size'],
                         'mapped': False, 'ctx': CTX_ID,
                         'mem_backed': True}
        submit(VG_RESOURCE_CREATE_BLOB, body, ctx=CTX_ID,
               exp_type=VG_RESP_NODATA)
        return base_b

    def map_blob(rid):
        tm.blobs[rid]['mapped'] = True
        # §7b/5a-ii: MAP_INFO reports the real window-relative offset
        submit(VG_MAP_BLOB, [rid, 0, 0, 0], ctx=CTX_ID,
               exp_type=VG_RESP_MAP_INFO,
               exp_body=[VG_MAP_WC, tm.blobs[rid]['base_w'] << 2])

    note('A4 blobs: ring0 4288, reply 16KiB, ring1 4544(+extra), exec 4KiB')
    # compute sessions carry whole SPIR-V modules in one command; the
    # ring buffer must hold them (8 KiB > 6.3 KiB for math450)
    ring0_sz = RING0_SIZE if vec is None else RING_BUF_OFF + 8192
    create_blob(RES_RING0, ring0_sz)
    create_blob(RES_REPLY, REPLY_SIZE)
    create_blob(RES_RING1, RING1_SIZE)
    create_blob(RES_EXEC, EXEC_SIZE)
    map_blob(RES_RING0)
    map_blob(RES_REPLY)
    map_blob(RES_RING1)
    map_blob(RES_EXEC)

    note('A5 CTX_ATTACH reply blob')
    submit(VG_CTX_ATTACH, [RES_REPLY, 0], ctx=CTX_ID,
           exp_type=VG_RESP_NODATA)

    # guest memsets the ring blobs
    apw(tm.blobs[RES_RING0]['base_w'] << 2, [0] * (ring0_sz // 4))
    apw(tm.blobs[RES_RING1]['base_w'] << 2, [0] * (RING1_SIZE // 4))

    note('A6 SUBMIT_3D[vkCreateRingMESA ring0 + RingMonitorInfo]')
    mon = {'_ty': model.reg.type_table['VkRingMonitorInfoMESA'],
           'sType': 'VK_STRUCTURE_TYPE_RING_MONITOR_INFO_MESA',
           'pNext': [], 'maxReportingPeriodMicroseconds': 1000}
    rc = vk('vkCreateRingMESA', ring=RING0_H,
            pCreateInfo={'_ty': None,
                         'sType': 'VK_STRUCTURE_TYPE_RING_CREATE_INFO_MESA',
                         'pNext': [mon], 'flags': 0,
                         'resourceId': RES_RING0, 'offset': 0,
                         'size': ring0_sz, 'idleTimeout': IDLE_TO,
                         'headOffset': RING_HEAD_OFF,
                         'tailOffset': RING_TAIL_OFF,
                         'statusOffset': RING_STATUS_OFF,
                         'bufferOffset': RING_BUF_OFF,
                         'bufferSize': ring0_sz - RING_BUF_OFF,
                         'extraOffset': ring0_sz,
                         'extraSize': 0})
    assert not execbuf(rc, fence=0x11), 'ring0 create failed in model'
    r0 = tm.rings[tm.ring_of[RING0_H]]
    ring_bind_guest(r0['slot'])
    tm.rep_cursor = 0
    W(TP_CHECK, CK_STATUS, r0['slot'], 0)
    rec(EK_STATUS, r0['slot'], RING_ALIVE)
    check_live()
    note('ring0 created slot=%d' % r0['slot'])

    # ------------------------------------------------------------------ #
    # Phase B': §7b/5a-ii compute session (vec = load_shvec record)        #
    # Three segments through ring0: (A) init through fence create, (B)    #
    # QueueSubmit + waits, (C) reverse-order teardown.  Buffer init data  #
    # goes into the aperture at each memory-backed blob's mapped offset   #
    # between A and B; output readback uses CK_APR/EK_APRCHK gate         #
    # records between B and C.                                            #
    # ------------------------------------------------------------------ #
    if vec is not None:
        def st(tyname, **kw):
            a = gen.gen_struct(model.reg.type_table[tyname])
            a.update(kw)
            return a

        V = {k: 0x4000_0000_1000 + i * 0x1000_0001 for i, k in enumerate(
            ('inst', 'pd', 'dev', 'queue', 'sm', 'dsl', 'pl', 'pipe',
             'dp', 'ds', 'cp', 'cb', 'fen'))}
        n_bind = len(vec['binds'])
        bufs = [0x5000_0000_1000 + i * 0x1000_0001
                for i in range(n_bind)]
        mems = [0x6000_0000_1000 + i * 0x1000_0001
                for i in range(n_bind)]
        RES_BLOB0 = 200                 # memory-blob resource ids
        r = tm.rings[r0['slot']]
        rep_q = []
        batch_no = [0]
        seek_used = [False]

        def compile_cmds(session):
            cw = [(n, k) + vka(n, **k) for n, k in session]
            dry = FrontModel(model, asm)
            dry.ctx = CTX_ID
            sized = []
            for (name, kw, w, a) in cw:
                drec = sim.run(w)
                nb = len(dry.step(name, None, w, drec, rep_sim,
                                  ses)['rep']) * 4
                sized.append((name, kw, w, a, nb))
            return sized

        def run_batches(sized_list):
            # ring bytes per batch must stay under buf_size or the wrap
            # clobbers undrained commands; the reply preamble (SetReply +
            # conditional Seek) counts toward a replying command's cost
            sw4 = len(vk('vkSetReplyCommandStreamMESA',
                         pStream={'_ty': None, 'resourceId': RES_REPLY,
                                  'offset': 0, 'size': 0})) * 4
            sk4 = len(vk('vkSeekReplyCommandStreamMESA',
                         position=0)) * 4
            i, n = 0, len(sized_list)
            while i < n:
                batch = []
                bw = 0
                while i < n:
                    name, kw, w, a, nb = sized_list[i]
                    cost = len(w) * 4
                    if model.cmd_info[name]['act']['flags'] & 1:
                        cost += sw4 + sk4
                    if batch and bw + cost > r['buf_size'] - 128:
                        break
                    batch.append(sized_list[i])
                    bw += cost
                    i += 1
                if batch_no[0] >= 1:
                    delay(IDLE_TO * 2)
                    wait_idle(r['slot'], RING_IDLE)
                for (name, kw, w, a, nb) in batch:
                    replies = bool(model.cmd_info[name]['act']['flags']
                                   & 1)
                    if replies:
                        rep_q.append((name, a))
                        stride = max(512, (nb + 63) & ~63)
                        if not seek_used[0] and batch_no[0] >= 1:
                            stride += 64
                        rp = tm.rep_cursor
                        if rp + stride > REPLY_SIZE:
                            ring_put(r, vk(
                                'vkSeekReplyCommandStreamMESA',
                                position=0))
                            tm.rep_cursor = rp = 0
                        ring_put(r, vk(
                            'vkSetReplyCommandStreamMESA',
                            pStream={'_ty': None,
                                     'resourceId': RES_REPLY,
                                     'offset': rp,
                                     'size': REPLY_SIZE - rp}))
                        if not seek_used[0] and batch_no[0] >= 1:
                            ring_put(r, vk(
                                'vkSeekReplyCommandStreamMESA',
                                position=64))
                            seek_used[0] = True
                    ring_put(r, w)
                    if replies:
                        tm.rep_cursor += stride
                tail_store(r)
                if batch_no[0] >= 1:
                    nf = vk('vkNotifyRingMESA', ring=RING0_H,
                            seqno=r['cur'], flags=0)
                    execbuf(nf)
                tm.drain_ring(r, fm, ses, log)
                wait_head(r['slot'])
                flush_replies()
                batch_no[0] += 1

        # ---- segment A part 1: device + buffers + memory -------------- #
        seg_a1 = [
            ('vkCreateInstance', dict(pInstance=V['inst'])),
            ('vkEnumeratePhysicalDevices', dict(
                instance=V['inst'], pPhysicalDeviceCount=1,
                pPhysicalDevices=[V['pd']])),
            ('vkCreateDevice', dict(
                physicalDevice=V['pd'],
                pCreateInfo=st(
                    'VkDeviceCreateInfo', queueCreateInfoCount=1,
                    pQueueCreateInfos=[st(
                        'VkDeviceQueueCreateInfo', queueFamilyIndex=0,
                        queueCount=1,
                        pQueuePriorities=[0x3F800000])],
                    pEnabledFeatures=None, enabledExtensionCount=0,
                    ppEnabledExtensionNames=[], enabledLayerCount=0,
                    ppEnabledLayerNames=[]),
                pDevice=V['dev'])),
            ('vkGetDeviceQueue', dict(
                device=V['dev'], queueFamilyIndex=0, queueIndex=0,
                pQueue=V['queue'])),
        ]
        for i, b in enumerate(vec['binds']):
            # bindoob: buffer 0's bind overruns its memory -> the
            # §7b BIND arm refuses it (buffer stays unbound -> the
            # submit-time assembly fails -> DEVICE_LOST)
            boff = b['size'] if variant == 'bindoob' and i == 0 else 0
            seg_a1 += [
                ('vkCreateBuffer', dict(
                    device=V['dev'],
                    pCreateInfo=st('VkBufferCreateInfo', size=b['size'],
                                   usage=0x20 | 0x02, sharingMode=0,
                                   queueFamilyIndexCount=0,
                                   pQueueFamilyIndices=[]),
                    pBuffer=bufs[i])),
                ('vkGetBufferMemoryRequirements', dict(
                    device=V['dev'], buffer=bufs[i],
                    pMemoryRequirements=st('VkMemoryRequirements'))),
                ('vkAllocateMemory', dict(
                    device=V['dev'],
                    pAllocateInfo=st('VkMemoryAllocateInfo',
                                     allocationSize=b['size'],
                                     memoryTypeIndex=0),
                    pMemory=mems[i])),
                ('vkBindBufferMemory', dict(
                    device=V['dev'], buffer=bufs[i], memory=mems[i],
                    memoryOffset=boff)),
            ]
        if variant == 'pgfull':
            seg_a1.append(('vkAllocateMemory', dict(
                device=V['dev'],
                pAllocateInfo=st('VkMemoryAllocateInfo',
                                 allocationSize=0x400000,
                                 memoryTypeIndex=0),
                pMemory=0x6000_0000_8000)))
        seg_a1 += [
            ('vkCreateShaderModule', dict(
                device=V['dev'],
                pCreateInfo=st('VkShaderModuleCreateInfo',
                               codeSize=len(vec['spv']) * 4,
                               pCode=vec['spv']),
                pShaderModule=V['sm'])),
            ('vkCreateDescriptorSetLayout', dict(
                device=V['dev'],
                pCreateInfo=st(
                    'VkDescriptorSetLayoutCreateInfo',
                    bindingCount=n_bind,
                    pBindings=[st(
                        'VkDescriptorSetLayoutBinding',
                        binding=b['binding'], descriptorCount=1,
                        descriptorType=(
                            1 if (variant == 'baddesc' and i == 0)
                            else 7),
                        stageFlags=0x20, pImmutableSamplers=[])
                        for i, b in enumerate(vec['binds'])]),
                pSetLayout=V['dsl'])),
            ('vkCreatePipelineLayout', dict(
                device=V['dev'],
                pCreateInfo=st(
                    'VkPipelineLayoutCreateInfo',
                    setLayoutCount=1, pSetLayouts=[V['dsl']],
                    pushConstantRangeCount=1 if vec['push'] else 0,
                    pPushConstantRanges=[st(
                        'VkPushConstantRange', stageFlags=0x20,
                        offset=0, size=len(vec['push']) * 4)]
                    if vec['push'] else []),
                pPipelineLayout=V['pl'])),
            ('vkCreateComputePipelines', dict(
                device=V['dev'], pipelineCache=0, createInfoCount=1,
                pCreateInfos=[st(
                    'VkComputePipelineCreateInfo',
                    stage=st('VkPipelineShaderStageCreateInfo',
                             stage=0x20, module=V['sm'], pName='main',
                             pSpecializationInfo=(
                                 st('VkSpecializationInfo',
                                    mapEntryCount=0, pMapEntries=[],
                                    dataSize=0, pData=[])
                                 if variant == 'spec' else None)),
                    layout=V['pl'], basePipelineHandle=0,
                    basePipelineIndex=0)],
                pPipelines=[V['pipe']])),
        ]
        if variant == 'modgone':
            seg_a1.append(('vkDestroyShaderModule', dict(
                device=V['dev'], shaderModule=V['sm'])))
        note("B' segment A1: device, %d buffers+mems, module, layouts, "
             'pipeline' % n_bind)
        run_batches(compile_cmds(seg_a1))

        pipe_ok = (not vec['commit_fault']) and variant != 'spec'
        if not pipe_ok:
            # pipeline failed -> teardown the A1 objects only
            seg_t = [
                ('vkDestroyPipelineLayout', dict(
                    device=V['dev'], pipelineLayout=V['pl'])),
                ('vkDestroyDescriptorSetLayout', dict(
                    device=V['dev'], descriptorSetLayout=V['dsl'])),
                ('vkDestroyShaderModule', dict(
                    device=V['dev'], shaderModule=V['sm'])),
            ]
            for i in range(n_bind):
                seg_t += [('vkDestroyBuffer', dict(
                    device=V['dev'], buffer=bufs[i])),
                          ('vkFreeMemory', dict(
                              device=V['dev'], memory=mems[i]))]
            seg_t += [('vkDestroyDevice', dict(device=V['dev'])),
                      ('vkDestroyInstance', dict(instance=V['inst']))]
            run_batches(compile_cmds(seg_t))
        else:
            # blob+map per memory (control queue), then guest writes
            # the initial buffer contents at the mapped offset
            blob_base = []
            for i, b in enumerate(vec['binds']):
                base_b = create_blob_mem(RES_BLOB0 + i, b['size'],
                                         mems[i])
                assert base_b is not None, 'memory blob refused'
                blob_base.append(base_b)
                map_blob(RES_BLOB0 + i)
                apw(base_b, vec['inits'][i])
            if variant == 'badmem':
                create_blob_mem(199, 4096, 0xDEADBEEF)

            # ---- segment A part 2: descriptors + cmdbuf + fence ------ #
            seg_a2 = [
                ('vkCreateDescriptorPool', dict(
                    device=V['dev'],
                    pCreateInfo=st('VkDescriptorPoolCreateInfo',
                                   maxSets=1, poolSizeCount=1,
                                   pPoolSizes=[st(
                                       'VkDescriptorPoolSize', type=7,
                                       descriptorCount=n_bind)]),
                    pDescriptorPool=V['dp'])),
                ('vkAllocateDescriptorSets', dict(
                    device=V['dev'],
                    pAllocateInfo=st('VkDescriptorSetAllocateInfo',
                                     descriptorPool=V['dp'],
                                     descriptorSetCount=1,
                                     pSetLayouts=[V['dsl']]),
                    pDescriptorSets=[V['ds']])),
                ('vkUpdateDescriptorSets', dict(
                    device=V['dev'], descriptorWriteCount=n_bind,
                    pDescriptorWrites=[st(
                        'VkWriteDescriptorSet', dstSet=V['ds'],
                        dstBinding=b['binding'], dstArrayElement=0,
                        descriptorCount=1,
                        descriptorType=(
                            1 if (variant == 'baddesc' and i == 0)
                            else 7),
                        pImageInfo=[], pTexelBufferView=[],
                        # descoob: binding 1's descriptor view starts
                        # at +128 with an inflated range — the
                        # §7b assembly clamps it to buffer.size-eoff
                        # = 128 B and the shader's accesses past it
                        # robust out
                        pBufferInfo=[st(
                            'VkDescriptorBufferInfo', buffer=bufs[i],
                            offset=(128 if variant == 'descoob'
                                    and i == 1 else 0),
                            range=(512 if variant == 'descoob'
                                   and i == 1 else b['size']))])
                        for i, b in enumerate(vec['binds'])],
                    descriptorCopyCount=0, pDescriptorCopies=[])),
                ('vkCreateCommandPool', dict(
                    device=V['dev'],
                    pCreateInfo=st('VkCommandPoolCreateInfo',
                                   queueFamilyIndex=0),
                    pCommandPool=V['cp'])),
                ('vkAllocateCommandBuffers', dict(
                    device=V['dev'],
                    pAllocateInfo=st('VkCommandBufferAllocateInfo',
                                     commandPool=V['cp'], level=0,
                                     commandBufferCount=1),
                    pCommandBuffers=[V['cb']])),
                ('vkBeginCommandBuffer', dict(
                    commandBuffer=V['cb'],
                    pBeginInfo=st('VkCommandBufferBeginInfo', flags=0,
                                  pInheritanceInfo=None))),
            ]
            if variant != 'nopipe':
                seg_a2.append(('vkCmdBindPipeline', dict(
                    commandBuffer=V['cb'], pipelineBindPoint=1,
                    pipeline=V['pipe'])))
            seg_a2.append(('vkCmdBindDescriptorSets', dict(
                commandBuffer=V['cb'], pipelineBindPoint=1,
                layout=V['pl'], firstSet=0, descriptorSetCount=1,
                pDescriptorSets=[V['ds']], dynamicOffsetCount=0,
                pDynamicOffsets=[])))
            if vec['push']:
                seg_a2.append(('vkCmdPushConstants', dict(
                    commandBuffer=V['cb'], layout=V['pl'],
                    stageFlags=0x20, offset=0,
                    size=len(vec['push']) * 4,
                    pValues=b''.join(struct.pack('<I', w)
                                     for w in vec['push']))))
            if variant == 'worksink':
                # non-dispatch work record: the record issues on the
                # cmdexec work port — a WorkSink=0 backend answers it
                # UNSUPPORTED one cycle later -> DEVICE_LOST
                seg_a2.append(('vkCmdDispatchIndirect', dict(
                    commandBuffer=V['cb'], buffer=bufs[0], offset=0)))
            else:
                seg_a2.append(('vkCmdDispatch', dict(
                    commandBuffer=V['cb'], groupCountX=vec['gx'],
                    groupCountY=vec['gy'], groupCountZ=vec['gz'])))
            seg_a2 += [
                ('vkEndCommandBuffer', dict(commandBuffer=V['cb'])),
                ('vkCreateFence', dict(
                    device=V['dev'],
                    pCreateInfo=st('VkFenceCreateInfo', flags=0),
                    pFence=V['fen'])),
            ]
            if variant == 'lostbuf':
                # buffer destroyed after UpdateDescriptorSets: the
                # submit-time LOOKUP in dispatch assembly must fail
                seg_a2.append(('vkDestroyBuffer', dict(
                    device=V['dev'], buffer=bufs[0])))
            note("B' segment A2: descriptors, cmdbuf, dispatch, fence")
            run_batches(compile_cmds(seg_a2))

            # ---- segment B: submit + wait ----------------------------- #
            seg_b = [
                ('vkQueueSubmit', dict(
                    queue=V['queue'], submitCount=1,
                    pSubmits=[st(
                        'VkSubmitInfo', waitSemaphoreCount=0,
                        pWaitSemaphores=[], pWaitDstStageMask=[],
                        commandBufferCount=1,
                        pCommandBuffers=[V['cb']],
                        signalSemaphoreCount=0,
                        pSignalSemaphores=[])],
                    fence=V['fen'])),
                ('vkDeviceWaitIdle', dict(device=V['dev'])),
                ('vkWaitForFences', dict(
                    device=V['dev'], fenceCount=1, pFences=[V['fen']],
                    waitAll=1, timeout=0xFFFFFFFFFFFFFFFF)),
                ('vkGetFenceStatus', dict(device=V['dev'],
                                          fence=V['fen'])),
            ]
            note("B' segment B: QueueSubmit + waits")
            run_batches(compile_cmds(seg_b))

            # ---- §7a gates at the aperture ---------------------------- #
            lost = variant in ('lostbuf', 'baddesc', 'nopipe',
                               'bindoob', 'worksink')
            if not lost:
                if variant == 'descoob':
                    # oracle = spirv_model run with binding 1's view
                    # clamped to 128 B at +128 (the §7b assembly's
                    # min(range, size-eoff) result) — no lavapipe
                    # comparison for this vector
                    mw = [len(vec['spv']), len(vec['binds']),
                          len(vec['push']), vec['gx'], vec['gy'],
                          vec['gz'], 0, 0] + list(vec['spv'])
                    for i, b in enumerate(vec['binds']):
                        mw += [b['set'], b['binding'],
                               128 if i == 1 else b['size'],
                               0x8000 + i * 0x2000]
                    mw += list(vec['push'])
                    for i, b in enumerate(vec['binds']):
                        mw += (vec['inits'][i][32:64] if i == 1
                               else list(vec['inits'][i]))
                    cm = spirv_model.Model(mw)
                    cm.run()
                    couts = cm.outputs()
                    ccls = cm.out_classes()
                    doc['note'] = (
                        'descoob: Gate-2 oracle is the spirv_model '
                        'run with binding 1 clamped to 128 B at '
                        '+128 (inflated descriptor range); no '
                        'lavapipe comparison for this vector')
                    for idx in sorted(couts):
                        base_b = blob_base[idx] + \
                            (128 if idx == 1 else 0)
                        W(TP_CHECK, CK_APR, len(couts[idx]), base_b)
                        for j, w in enumerate(couts[idx]):
                            rec(EK_APRCHK, base_b + 4 * j, w, w,
                                1 if ccls[idx][j] == 'f' else 0)
                    note("B' gates: %d output words checked "
                         "(model-only oracle)"
                         % sum(len(w) for w in couts.values()))
                else:
                    for o in vec['outs']:
                        base_b = blob_base[o['bind_idx']]
                        nw = o['size'] // 4
                        W(TP_CHECK, CK_APR, nw, base_b)
                        for j in range(nw):
                            rec(EK_APRCHK, base_b + 4 * j,
                                o['model'][j], o['oracle'][j],
                                o['cls'][j])
                    note("B' gates: %d output words checked"
                         % sum(o['size'] // 4 for o in vec['outs']))
            else:
                note("B' gates: dispatch lost (%s), no readback"
                     % variant)

            # ---- segment C: reverse-order teardown -------------------- #
            seg_c = [
                ('vkDestroyFence', dict(device=V['dev'],
                                        fence=V['fen'])),
                ('vkFreeCommandBuffers', dict(
                    device=V['dev'], commandPool=V['cp'],
                    commandBufferCount=1, pCommandBuffers=[V['cb']])),
                ('vkDestroyCommandPool', dict(
                    device=V['dev'], commandPool=V['cp'])),
                ('vkFreeDescriptorSets', dict(
                    device=V['dev'], descriptorPool=V['dp'],
                    descriptorSetCount=1, pDescriptorSets=[V['ds']])),
                ('vkDestroyDescriptorPool', dict(
                    device=V['dev'], descriptorPool=V['dp'])),
                ('vkDestroyPipeline', dict(
                    device=V['dev'], pipeline=V['pipe'])),
                ('vkDestroyPipelineLayout', dict(
                    device=V['dev'], pipelineLayout=V['pl'])),
                ('vkDestroyDescriptorSetLayout', dict(
                    device=V['dev'], descriptorSetLayout=V['dsl'])),
            ]
            if variant != 'modgone':
                seg_c.append(('vkDestroyShaderModule', dict(
                    device=V['dev'], shaderModule=V['sm'])))
            for i in range(n_bind):
                if variant == 'lostbuf' and i == 0:
                    pass
                else:
                    seg_c.append(('vkDestroyBuffer', dict(
                        device=V['dev'], buffer=bufs[i])))
                seg_c.append(('vkFreeMemory', dict(
                    device=V['dev'], memory=mems[i])))
            seg_c += [('vkDestroyDevice', dict(device=V['dev'])),
                      ('vkDestroyInstance', dict(instance=V['inst']))]
            note("B' segment C: teardown")
            run_batches(compile_cmds(seg_c))

            # memory-backed blobs: unref frees the resource only
            for i in range(n_bind):
                submit(VG_RESOURCE_UNREF, [RES_BLOB0 + i, 0],
                       ctx=CTX_ID, exp_type=VG_RESP_NODATA)
                tm.blobs.pop(RES_BLOB0 + i)

        note('D RESOURCE_UNREF exec blob, CTX_DESTROY ctx=4 -> live 0')
        eb = tm.blobs.pop(RES_EXEC)
        tm.ap_free(eb['base_w'], EXEC_SIZE)
        submit(VG_RESOURCE_UNREF, [RES_EXEC, 0], ctx=CTX_ID,
               exp_type=VG_RESP_NODATA)
        # blob-owned pages drain only through UNREF (CTX_DESTROY does
        # not free them); ring0's blob goes last, after the ring dies
        for rid in (RES_REPLY, RES_RING1):
            b = tm.blobs.pop(rid)
            tm.ap_free(b['base_w'], b['size'])
            submit(VG_RESOURCE_UNREF, [rid, 0], ctx=CTX_ID,
                   exp_type=VG_RESP_NODATA)
        dr0 = vk('vkDestroyRingMESA', ring=RING0_H)
        assert not execbuf(dr0), 'ring0 destroy failed'
        b = tm.blobs.pop(RES_RING0)
        tm.ap_free(b['base_w'], b['size'])
        submit(VG_RESOURCE_UNREF, [RES_RING0, 0], ctx=CTX_ID,
               exp_type=VG_RESP_NODATA)
        submit(VG_CTX_DESTROY, [], ctx=CTX_ID, exp_type=VG_RESP_NODATA)
        tm.blobs.clear()
        tm.ctxs.clear()
        fm.reset_ctx(CTX_ID)
        check_live()
        note('compute teardown complete')

        W(TP_END)
        insts = []
        for (name, a), (_n, out) in zip(rep_q, tm.exec_log):
            assert name == _n, '%s vs %s' % (name, _n)
            insts.append({'cmd': name, 'i': len(insts), 'targs': a,
                          'rep': out['rep'], 'result': out['result'],
                          'ty': supported[name], 'exec_w': []})
        doc['reply_insts'] = insts
        return tape, exp, doc

    # ------------------------------------------------------------------ #
    # Phase B: increment-3 session through ring0                             #
    # ------------------------------------------------------------------ #
    I = {k: 0x4000_0000_1000 + i * 0x1000_0001 for i, k in enumerate(
        ('inst', 'pd', 'dev', 'queue', 'mem', 'buf', 'img', 'sm', 'dsl',
         'pl', 'pipe', 'dp', 'ds', 'cp', 'cb', 'fen'))}

    def st(tyname, **kw):
        a = gen.gen_struct(model.reg.type_table[tyname])
        a.update(kw)
        return a

    session = [
        ('vkCreateInstance', dict(pInstance=I['inst'])),
        ('vkEnumeratePhysicalDevices', dict(
            instance=I['inst'], pPhysicalDeviceCount=1,
            pPhysicalDevices=[I['pd']])),
        ('vkGetPhysicalDeviceProperties', dict(
            physicalDevice=I['pd'],
            pProperties=st('VkPhysicalDeviceProperties'))),
        ('vkGetPhysicalDeviceProperties2', dict(
            physicalDevice=I['pd'],
            pProperties=st('VkPhysicalDeviceProperties2',
                           pNext=[st('VkPhysicalDeviceSubgroup'
                                     'Properties')]))),
        ('vkGetPhysicalDeviceMemoryProperties2', dict(
            physicalDevice=I['pd'],
            pMemoryProperties=st(
                'VkPhysicalDeviceMemoryProperties2'))),
        ('vkCreateDevice', dict(
            physicalDevice=I['pd'],
            pCreateInfo=st(
                'VkDeviceCreateInfo', queueCreateInfoCount=1,
                pQueueCreateInfos=[st(
                    'VkDeviceQueueCreateInfo', queueFamilyIndex=0,
                    queueCount=1, pQueuePriorities=[0x3F800000])],
                pEnabledFeatures=None, enabledExtensionCount=0,
                ppEnabledExtensionNames=[], enabledLayerCount=0,
                ppEnabledLayerNames=[]),
            pDevice=I['dev'])),
        ('vkGetDeviceQueue', dict(
            device=I['dev'], queueFamilyIndex=0, queueIndex=0,
            pQueue=I['queue'])),
        ('vkAllocateMemory', dict(
            device=I['dev'],
            pAllocateInfo=st('VkMemoryAllocateInfo',
                             allocationSize=0x40000,
                             memoryTypeIndex=1),
            pMemory=I['mem'])),
        ('vkCreateBuffer', dict(
            device=I['dev'],
            pCreateInfo=st('VkBufferCreateInfo', size=4096, usage=0x61,
                           sharingMode=0, queueFamilyIndexCount=0,
                           pQueueFamilyIndices=[]),
            pBuffer=I['buf'])),
        ('vkGetBufferMemoryRequirements', dict(
            device=I['dev'], buffer=I['buf'],
            pMemoryRequirements=st('VkMemoryRequirements'))),
        ('vkBindBufferMemory', dict(
            device=I['dev'], buffer=I['buf'], memory=I['mem'],
            memoryOffset=0)),
        ('vkGetMemoryResourcePropertiesMESA', dict(
            device=I['dev'], resourceId=RES_RING0,
            pMemoryResourceProperties=st(
                'VkMemoryResourcePropertiesMESA'))),
        # transport interlude 1: seqno commands on ring0
        ('vkSubmitVirtqueueSeqnoMESA',
         dict(ring=RING0_H, seqno=0x3000)),
        ('vkWaitVirtqueueSeqnoMESA', dict(seqno=0)),
        ('vkWaitRingSeqnoMESA', dict(ring=RING0_H, seqno=0)),
        ('vkCreateShaderModule', dict(
            device=I['dev'],
            pCreateInfo=st('VkShaderModuleCreateInfo',
                           codeSize=SPV_SESSION_B,
                           pCode=SPV_SESSION),
            pShaderModule=I['sm'])),
        ('vkCreateDescriptorSetLayout', dict(
            device=I['dev'],
            pCreateInfo=st(
                'VkDescriptorSetLayoutCreateInfo', bindingCount=1,
                pBindings=[st(
                    'VkDescriptorSetLayoutBinding', binding=0,
                    descriptorType=7, descriptorCount=1,
                    stageFlags=0x20, pImmutableSamplers=[])]),
            pSetLayout=I['dsl'])),
        ('vkCreatePipelineLayout', dict(
            device=I['dev'],
            pCreateInfo=st('VkPipelineLayoutCreateInfo',
                           setLayoutCount=1, pSetLayouts=[I['dsl']],
                           pushConstantRangeCount=0,
                           pPushConstantRanges=[]),
            pPipelineLayout=I['pl'])),
        ('vkCreateComputePipelines', dict(
            device=I['dev'], pipelineCache=0, createInfoCount=1,
            pCreateInfos=[st(
                'VkComputePipelineCreateInfo',
                stage=st('VkPipelineShaderStageCreateInfo',
                         stage=0x20, module=I['sm'], pName='main',
                         pSpecializationInfo=None),
                layout=I['pl'], basePipelineHandle=0,
                basePipelineIndex=0)],
            pPipelines=[I['pipe']])),
        ('vkCreateDescriptorPool', dict(
            device=I['dev'],
            pCreateInfo=st('VkDescriptorPoolCreateInfo', maxSets=1,
                           poolSizeCount=1,
                           pPoolSizes=[st('VkDescriptorPoolSize', type=7,
                                          descriptorCount=1)]),
            pDescriptorPool=I['dp'])),
        ('vkAllocateDescriptorSets', dict(
            device=I['dev'],
            pAllocateInfo=st('VkDescriptorSetAllocateInfo',
                             descriptorPool=I['dp'],
                             descriptorSetCount=1,
                             pSetLayouts=[I['dsl']]),
            pDescriptorSets=[I['ds']])),
        ('vkUpdateDescriptorSets', dict(
            device=I['dev'], descriptorWriteCount=1,
            pDescriptorWrites=[st(
                'VkWriteDescriptorSet', dstSet=I['ds'], dstBinding=0,
                dstArrayElement=0, descriptorCount=1, descriptorType=7,
                pImageInfo=[], pTexelBufferView=[],
                pBufferInfo=[st('VkDescriptorBufferInfo',
                                buffer=I['buf'], offset=0,
                                range=4096)])],
            descriptorCopyCount=0, pDescriptorCopies=[])),
        ('vkCreateCommandPool', dict(
            device=I['dev'],
            pCreateInfo=st('VkCommandPoolCreateInfo',
                           queueFamilyIndex=0),
            pCommandPool=I['cp'])),
        ('vkAllocateCommandBuffers', dict(
            device=I['dev'],
            pAllocateInfo=st('VkCommandBufferAllocateInfo',
                             commandPool=I['cp'], level=0,
                             commandBufferCount=1),
            pCommandBuffers=[I['cb']])),
        ('vkBeginCommandBuffer', dict(
            commandBuffer=I['cb'],
            pBeginInfo=st('VkCommandBufferBeginInfo', flags=0,
                          pInheritanceInfo=None))),
        ('vkCmdBindPipeline', dict(
            commandBuffer=I['cb'], pipelineBindPoint=1,
            pipeline=I['pipe'])),
        ('vkCmdBindDescriptorSets', dict(
            commandBuffer=I['cb'], pipelineBindPoint=1, layout=I['pl'],
            firstSet=0, descriptorSetCount=1, pDescriptorSets=[I['ds']],
            dynamicOffsetCount=0, pDynamicOffsets=[])),
        ('vkCmdDispatch', dict(
            commandBuffer=I['cb'], groupCountX=1, groupCountY=1,
            groupCountZ=1)),
        ('vkEndCommandBuffer', dict(commandBuffer=I['cb'])),
        ('vkCreateFence', dict(
            device=I['dev'],
            pCreateInfo=st('VkFenceCreateInfo', flags=0),
            pFence=I['fen'])),
        ('vkQueueSubmit', dict(
            queue=I['queue'], submitCount=1,
            pSubmits=[st('VkSubmitInfo', waitSemaphoreCount=0,
                         pWaitSemaphores=[], pWaitDstStageMask=[],
                         commandBufferCount=1, pCommandBuffers=[I['cb']],
                         signalSemaphoreCount=0,
                         pSignalSemaphores=[])],
            fence=I['fen'])),
        ('vkDeviceWaitIdle', dict(device=I['dev'])),
        ('vkWaitForFences', dict(
            device=I['dev'], fenceCount=1, pFences=[I['fen']],
            waitAll=1, timeout=0xFFFFFFFFFFFFFFFF)),
        ('vkGetFenceStatus', dict(device=I['dev'], fence=I['fen'])),
    ]
    # teardown happens through the ring too (RETIRE through the transport)
    teardown = [
        ('vkDestroyFence', dict(device=I['dev'], fence=I['fen'])),
        ('vkFreeCommandBuffers', dict(
            device=I['dev'], commandPool=I['cp'], commandBufferCount=1,
            pCommandBuffers=[I['cb']])),
        ('vkDestroyCommandPool', dict(device=I['dev'],
                                      commandPool=I['cp'])),
        ('vkFreeDescriptorSets', dict(
            device=I['dev'], descriptorPool=I['dp'],
            descriptorSetCount=1, pDescriptorSets=[I['ds']])),
        ('vkDestroyDescriptorPool', dict(device=I['dev'],
                                         descriptorPool=I['dp'])),
        ('vkDestroyPipeline', dict(device=I['dev'], pipeline=I['pipe'])),
        ('vkDestroyPipelineLayout', dict(device=I['dev'],
                                         pipelineLayout=I['pl'])),
        ('vkDestroyDescriptorSetLayout', dict(
            device=I['dev'], descriptorSetLayout=I['dsl'])),
        ('vkDestroyShaderModule', dict(device=I['dev'],
                                       shaderModule=I['sm'])),
        ('vkDestroyBuffer', dict(device=I['dev'], buffer=I['buf'])),
        ('vkFreeMemory', dict(device=I['dev'], memory=I['mem'])),
        ('vkDestroyDevice', dict(device=I['dev'])),
        ('vkDestroyInstance', dict(instance=I['inst'])),
    ]
    session = session + teardown

    # ring1: extra region + WriteRingExtra coverage (before batches)
    note('B0 SUBMIT_3D[vkCreateRingMESA ring1 +extra 256]')
    rc1 = vk('vkCreateRingMESA', ring=RING1_H,
             pCreateInfo={'_ty': None,
                          'sType': 'VK_STRUCTURE_TYPE_RING_CREATE_INFO'
                                   '_MESA',
                          'pNext': [mon], 'flags': 0,
                          'resourceId': RES_RING1, 'offset': 0,
                          'size': RING1_SIZE, 'idleTimeout': IDLE_TO,
                          'headOffset': RING_HEAD_OFF,
                          'tailOffset': RING_TAIL_OFF,
                          'statusOffset': RING_STATUS_OFF,
                          'bufferOffset': RING_BUF_OFF, 'bufferSize': 4096,
                          'extraOffset': RING_BUF_OFF + 4096,
                          'extraSize': 256})
    assert not execbuf(rc1), 'ring1 create failed'
    r1 = tm.rings[tm.ring_of[RING1_H]]
    ring_bind_guest(r1['slot'])

    note('B: session through ring0, batches wrap the 4 KiB buffer')
    r = tm.rings[r0['slot']]
    cmds_words = [(n, k) + vka(n, **k) for n, k in session]

    # reply-window sizing: replay the session once on a scratch
    # FrontModel so each SetReply slot covers the command's real reply
    # size — a fixed stride lets the long property replies overwrite
    # the next window (the guest owns the window layout)
    dry = FrontModel(model, asm)
    dry.ctx = CTX_ID
    sized = []
    for (name, kw, w, a) in cmds_words:
        drec = sim.run(w)
        nb = len(dry.step(name, None, w, drec, rep_sim, ses)['rep']) * 4
        sized.append((name, kw, w, a, nb))
    cmds_words = sized

    batch_no = 0
    i = 0
    n = len(cmds_words)
    rep_q = []
    seek_used = False
    while i < n:
        # assemble a batch <= 340 words (guest keeps space headroom)
        batch = []
        bw = 0
        while i < n and bw < 220:
            batch.append(cmds_words[i])
            bw += len(cmds_words[i][2])
            i += 1
        if batch_no >= 1:
            # park the ring, check IDLE, then notify with the submit
            delay(IDLE_TO * 2)
            wait_idle(r['slot'], RING_IDLE)
        for (name, kw, w, a, nb) in batch:
            replies = bool(model.cmd_info[name]['act']['flags'] & 1)
            if replies:
                rep_q.append((name, a))
                stride = max(512, (nb + 63) & ~63)
                if not seek_used and batch_no >= 1:
                    stride += 64     # one explicit SeekReply, below
                rp = tm.rep_cursor
                if rp + stride > REPLY_SIZE:
                    ring_put(r, vk('vkSeekReplyCommandStreamMESA',
                                   position=0))
                    tm.rep_cursor = rp = 0
                ring_put(r, vk('vkSetReplyCommandStreamMESA',
                               pStream={'_ty': None,
                                        'resourceId': RES_REPLY,
                                        'offset': rp,
                                        'size': REPLY_SIZE - rp}))
                if not seek_used and batch_no >= 1:
                    # positive SeekReply coverage: land this reply 64
                    # bytes into its window
                    ring_put(r, vk('vkSeekReplyCommandStreamMESA',
                                   position=64))
                    seek_used = True
            ring_put(r, w)
            if replies:
                tm.rep_cursor += stride
        tail_store(r)
        if batch_no >= 1:
            # driver sees IDLE -> vkNotifyRingMESA via execbuffer
            nf = vk('vkNotifyRingMESA', ring=RING0_H,
                    seqno=r['cur'], flags=0)
            execbuf(nf)
        tm.drain_ring(r, fm, ses, log)
        wait_head(r['slot'])
        flush_replies()
        batch_no += 1

    # WriteRingExtra positive on ring1 (sent through ring0)
    note('B+ WriteRingExtra ring1 offset 0 via ring0')
    ring_put(r, vk('vkWriteRingExtraMESA', ring=RING1_H, offset=0,
                   value=0xDEADBEEF))
    tail_store(r)
    tm.drain_ring(r, fm, ses, log)
    wait_head(r['slot'])
    check_extra(r1['slot'], 0)
    flush_replies()

    # ExecuteCommandStreams positive: two commands in the exec blob
    note('B+ ExecuteCommandStreams via exec blob window')
    sw2 = vk('vkSetReplyCommandStreamMESA',
             pStream={'_ty': None, 'resourceId': RES_REPLY,
                      'offset': tm.rep_cursor,
                      'size': REPLY_SIZE - tm.rep_cursor})
    g2, g2a = vka('vkGetBufferMemoryRequirements', device=I['dev'],
                  buffer=I['buf'],
                  pMemoryRequirements=st('VkMemoryRequirements'))
    rep_q.append(('vkGetBufferMemoryRequirements', g2a))
    exec_stream = sw2 + g2
    apw(tm.blobs[RES_EXEC]['base_w'] << 2, exec_stream)
    exw = vk('vkExecuteCommandStreamsMESA',
             streamCount=1,
             pStreams=[{'_ty': None, 'resourceId': RES_EXEC,
                        'offset': 0, 'size': len(exec_stream) * 4}],
             pReplyPositions=[0],
             dependencyCount=0, pDependencies=[], flags=0)
    ring_put(r, exw)
    tail_store(r)
    tm.drain_ring(r, fm, ses, log)
    wait_head(r['slot'])
    flush_replies()
    tm.rep_cursor += 512
    check_live()

    # ------------------------------------------------------------------ #
    # Phase C: negative arms                                                 #
    # ------------------------------------------------------------------ #
    note('C1 CTX_CREATE context_init=5 -> ERR_INVALID_PARAMETER')
    submit(VG_CTX_CREATE, [4, 5] + name_words, ctx=7,
           exp_type=VG_ERR_PARAM)

    # §7b/5a-ii: blob_id != 0 resolves a VkDeviceMemory object; id 1 is
    # unknown here -> ERR_RID
    note('C2 CREATE_BLOB blob_id=1 unknown mem -> ERR_RID')
    submit(VG_RESOURCE_CREATE_BLOB,
           [200, VG_BLOB_HOST3D, VG_BLOB_MAPPABLE, 0, 1, 0,
            4096, 0], ctx=CTX_ID, exp_type=VG_ERR_RESOURCE)

    note('C3 unknown ctrl type -> ERR_UNSPEC')
    submit(0x0999, [0, 0], exp_type=VG_ERR_UNSPEC)

    note('C4 SUBMIT_3D size > payload -> ERR_UNSPEC')
    # request hdr says size=64 but the desc ends after the 8-word struct
    req = vg_hdr(VG_SUBMIT_3D, 0, 0, CTX_ID, 0) + [64, 0]
    memw(GREQ, req)
    resp_addr = GRESP + resp_n[0] * 0x100
    resp_n[0] += 1
    chain([(GREQ, len(req) * 4, 0), (resp_addr, 24, 1)],
          0, 0, CTX_ID, 0, VG_ERR_UNSPEC, [], len(req) * 4 + 24)

    note('C5 ring2: decode fault -> FATAL, head stops')
    rc2 = vk('vkCreateRingMESA', ring=RING2_H,
             pCreateInfo={'_ty': None,
                          'sType': 'VK_STRUCTURE_TYPE_RING_CREATE_INFO'
                                   '_MESA',
                          'pNext': [mon], 'flags': 0,
                          'resourceId': RES_RING1, 'offset': 0,
                          'size': RING1_SIZE, 'idleTimeout': IDLE_TO,
                          'headOffset': RING_HEAD_OFF,
                          'tailOffset': RING_TAIL_OFF,
                          'statusOffset': RING_STATUS_OFF,
                          'bufferOffset': RING_BUF_OFF, 'bufferSize': 4096,
                          'extraOffset': RING_BUF_OFF + 4096,
                          'extraSize': 256})
    # destroy ring1 first so slot frees for the negative-arm rings
    dr1 = vk('vkDestroyRingMESA', ring=RING1_H)
    assert not execbuf(dr1), 'ring1 destroy failed'
    assert not execbuf(rc2), 'ring2 create failed'
    r2 = tm.rings[tm.ring_of[RING2_H]]
    ring_bind_guest(r2['slot'])
    W(TP_CHECK, CK_STATUS, r2['slot'], 0)
    rec(EK_STATUS, r2['slot'], RING_ALIVE)

    # good command then a corrupt one (bad sType) then a tail command
    good = vk('vkWaitRingSeqnoMESA', ring=RING2_H, seqno=0)
    bad = list(vk('vkGetBufferMemoryRequirements', device=I['dev'],
                  buffer=I['buf'],
                  pMemoryRequirements=st('VkMemoryRequirements')))
    bad[0] = 0x0000DEAD            # unknown command type -> decode fault
    tailcmd = vk('vkWaitRingSeqnoMESA', ring=RING2_H, seqno=0)
    ring_put(r2, good)
    exp_head = len(good) * 4
    ring_put(r2, bad)
    ring_put(r2, tailcmd)
    tail_store(r2)
    tm.drain_ring(r2, fm, ses, log)
    # head must stop at the faulting command; the tape checks are
    # zero-time so wait for the drain to publish head, then FATAL
    wait_head(r2['slot'])
    wait_status(r2['slot'], RING_FATAL, RING_FATAL)
    note('ring2 FATAL head=%d' % r2['head'])

    note('C6 ring3: nested ExecuteCommandStreams -> FATAL')
    dr2 = vk('vkDestroyRingMESA', ring=RING2_H)
    assert not execbuf(dr2), 'ring2 destroy failed'
    rc3 = vk('vkCreateRingMESA', ring=RING3_H,
             pCreateInfo={'_ty': None,
                          'sType': 'VK_STRUCTURE_TYPE_RING_CREATE_INFO'
                                   '_MESA',
                          'pNext': [mon], 'flags': 0,
                          'resourceId': RES_RING1, 'offset': 0,
                          'size': RING1_SIZE, 'idleTimeout': IDLE_TO,
                          'headOffset': RING_HEAD_OFF,
                          'tailOffset': RING_TAIL_OFF,
                          'statusOffset': RING_STATUS_OFF,
                          'bufferOffset': RING_BUF_OFF, 'bufferSize': 4096,
                          'extraOffset': RING_BUF_OFF + 4096,
                          'extraSize': 256})
    assert not execbuf(rc3), 'ring3 create failed'
    r3 = tm.rings[tm.ring_of[RING3_H]]
    ring_bind_guest(r3['slot'])
    # exec blob holds a nested ExecuteCommandStreamsMESA command
    nested = vk('vkExecuteCommandStreamsMESA',
                streamCount=1,
                pStreams=[{'_ty': None, 'resourceId': RES_EXEC,
                           'offset': 0, 'size': 8}],
                pReplyPositions=[0],
                dependencyCount=0, pDependencies=[], flags=0)
    apw(tm.blobs[RES_EXEC]['base_w'] << 2, nested)
    outer = vk('vkExecuteCommandStreamsMESA',
               streamCount=1,
               pStreams=[{'_ty': None, 'resourceId': RES_EXEC,
                          'offset': 0, 'size': len(nested) * 4}],
               pReplyPositions=[0],
               dependencyCount=0, pDependencies=[], flags=0)
    ring_put(r3, outer)
    tail_store(r3)
    tm.drain_ring(r3, fm, ses, log)
    # head never advances (fault at the outer command): wait on the
    # FATAL status bit for the drain to complete, then check head
    wait_status(r3['slot'], RING_FATAL, RING_FATAL)
    W(TP_CHECK, CK_HEAD, r3['slot'], 0)
    rec(EK_HEAD, r3['slot'], 0)
    dr3 = vk('vkDestroyRingMESA', ring=RING3_H)
    assert not execbuf(dr3), 'ring3 destroy failed'
    note('ring3 nested-exec FATAL, destroyed')

    # ------------------------------------------------------------------ #
    # Phase D: teardown                                                      #
    # ------------------------------------------------------------------ #
    note('D RESOURCE_UNREF exec blob, CTX_DESTROY ctx=4 -> live 0')
    eb = tm.blobs.pop(RES_EXEC)
    tm.ap_free(eb['base_w'], EXEC_SIZE)
    submit(VG_RESOURCE_UNREF, [RES_EXEC, 0], ctx=CTX_ID,
           exp_type=VG_RESP_NODATA)
    # blob-owned pages drain only through UNREF (CTX_DESTROY does not
    # free them); ring0's blob goes last, after the ring dies
    for rid in (RES_REPLY, RES_RING1):
        b = tm.blobs.pop(rid)
        tm.ap_free(b['base_w'], b['size'])
        submit(VG_RESOURCE_UNREF, [rid, 0], ctx=CTX_ID,
               exp_type=VG_RESP_NODATA)
    dr0 = vk('vkDestroyRingMESA', ring=RING0_H)
    assert not execbuf(dr0), 'ring0 destroy failed'
    b = tm.blobs.pop(RES_RING0)
    tm.ap_free(b['base_w'], b['size'])
    submit(VG_RESOURCE_UNREF, [RES_RING0, 0], ctx=CTX_ID,
           exp_type=VG_RESP_NODATA)
    submit(VG_CTX_DESTROY, [], ctx=CTX_ID, exp_type=VG_RESP_NODATA)
    # model ctx destroy: RESET_CTX retires every ctx-4 entry
    tm.blobs.clear()
    tm.ctxs.clear()
    fm.reset_ctx(CTX_ID)
    check_live()
    note('teardown complete')

    W(TP_END)
    # pair golden replies with their commands for the Mesa decode harness
    insts = []
    for (name, a), (_n, out) in zip(rep_q, tm.exec_log):
        assert name == _n, '%s vs %s' % (name, _n)
        insts.append({'cmd': name, 'i': len(insts), 'targs': a,
                      'rep': out['rep'], 'result': out['result'],
                      'ty': supported[name], 'exec_w': []})
    doc['reply_insts'] = insts
    assert len(tm.exec_log) == len(rep_q),         'reply pairing: %d != %d' % (len(tm.exec_log), len(rep_q))
    return tape, exp, doc


def write_transport(name, tape, exp, doc):
    """Emit NAME.hex (tape), NAME.exp (8-word records), NAME.json."""
    hex_lines = []
    for i, w in enumerate(tape):
        hex_lines.append('%08X' % w)
    exp_lines = []
    for r in exp:
        exp_lines += ['%08X' % (v & 0xFFFFFFFF) for v in r]
    exp_lines += ['FFFFFFFF', 'FFFFFFFF']
    VEC_DIR.mkdir(parents=True, exist_ok=True)
    (VEC_DIR / (name + '.hex')).write_text(
        '\n'.join(hex_lines) + '\n', encoding='utf-8')
    (VEC_DIR / (name + '.exp')).write_text(
        '\n'.join(exp_lines) + '\n', encoding='utf-8')
    import json as _json
    jdoc = {'steps': doc['steps'], 'log': doc['log'],
            'tape_words': len(tape), 'exp_records': len(exp)}
    if doc.get('note'):
        jdoc['note'] = doc['note']
    (VEC_DIR / (name + '.json')).write_text(
        _json.dumps(jdoc, indent=1), encoding='utf-8')
    print('transport: %d tape words, %d exp records, %d steps'
          % (len(tape), len(exp), len(doc['steps'])))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--vectors', nargs=2, metavar=('NAME', 'SEED'))
    ap.add_argument('--reply-vectors', nargs=2, metavar=('NAME', 'SEED'))
    ap.add_argument('--session', nargs=2, metavar=('NAME', 'SEED'))
    ap.add_argument('--payfull-session', nargs=2,
                    metavar=('NAME', 'SEED'),
                    help='session variant for the ObjPay-FULL arm; '
                         'pair with --paywords N (default 512)')
    ap.add_argument('--paywords', type=int, default=512,
                    help='ObjPay word count modelled by --payfull-session')
    ap.add_argument('--transport', nargs=2, metavar=('NAME', 'SEED'))
    ap.add_argument('--compute-session', nargs=2,
                    metavar=('NAME', 'SHVEC'),
                    help='§7b compute-session transport stream; SHVEC is '
                         'a sh_vectors case name (e.g. bufcopy_1)')
    ap.add_argument('--variant', default='',
                    help='compute-session negative arm: spec, modgone, '
                         'lostbuf, baddesc, nopipe, pgfull, badmem, '
                         'bindoob, descoob, worksink')
    ap.add_argument('--print', dest='print_cmd', metavar='CMD')
    ap.add_argument('--dump-json', metavar='FILE',
                    help='write every generated instance (args+words) as '
                         'JSON for vn_mesa_diff')
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--count', type=int, default=20)
    args = ap.parse_args()

    profile = tomllib.loads(
        (G.TOOLS / 'vn_device_profile.toml').read_text(encoding='utf-8'))
    model = G.Model(profile)
    names = model.read_command_set(G.TOOLS / 'vn_command_set.txt')
    unfit = model.run(names)
    if unfit:
        print('unfit commands:', unfit, file=sys.stderr)
    model, asm = build_assembly(model)
    sim = Sim(model, asm)
    enc = Enc(model)

    supported = {t.name: t for t in
                 model.gen.supported_types[vkxml.VkType.COMMAND]}

    if args.selftest:
        rng = random.Random(0x5EED)
        gen = ArgGen(model, rng)
        ok = fail = 0
        bad = []
        for name in model.cmd_progs:
            ty = supported[name]
            for i in range(4):
                a = gen.gen_command(name)
                words = enc.command(ty, a)
                rec = sim.run(words)
                if rec['fault'] != 0:
                    fail += 1
                    bad.append((name, i, rec['fault'], rec['fault_mpc']))
                elif rec['words'] != len(words):
                    fail += 1
                    bad.append((name, i, 'leftover %d/%d'
                                % (rec['words'], len(words)),
                                rec['fault_mpc']))
                else:
                    ok += 1
        print('selftest: %d ok, %d faults' % (ok, fail))
        for b in bad[:20]:
            print('  fault %s %s fault=%s mpc=%d' % b)
        return 1 if fail else 0

    if args.print_cmd:
        rng = random.Random(1)
        gen = ArgGen(model, rng)
        a = gen.gen_command(args.print_cmd)
        ty = supported[args.print_cmd]
        words = enc.command(ty, a)
        print(' '.join('%08X' % w for w in words))
        print(fmt_rec(sim.run(words)))
        return 0

    if args.dump_json:
        import json as _json
        rng = random.Random(args.seed)
        gen = ArgGen(model, rng)
        insts = []
        for cmd in model.cmd_progs:
            ty = supported[cmd]
            for i in range(args.count):
                a = gen.gen_command(cmd)
                insts.append({'cmd': cmd, 'i': i,
                              'args': to_jsonable(a),
                              'words': enc.command(ty, a)})
        Path(args.dump_json).write_text(
            _json.dumps(insts), encoding='utf-8')
        print('wrote %d instances to %s' % (len(insts), args.dump_json))
        return 0

    if args.vectors:
        name, seed = args.vectors
        rng = random.Random(int(seed))
        gen = ArgGen(model, rng)
        VEC_DIR.mkdir(parents=True, exist_ok=True)
        hex_lines = []
        exp_lines = []
        mut_kinds = ['type', 'stype', 'pnext', 'flags', 'trunc',
                     'handle', 'bound']
        mi = 0
        base = 0

        def emit(tag, words, rec):
            nonlocal base, hex_lines, exp_lines
            hex_lines.append('// %s' % tag)
            hex_lines += ['%08X' % w for w in words]
            exp_lines.append('// %s' % tag)
            exp_lines.append('%08X' % base)
            exp_lines.append('%08X' % len(words))
            exp_lines += ['%08X' % w for w in rec_words(rec)]
            base += len(words)

        order = list(model.cmd_progs)
        for cmd in order:
            ty = supported[cmd]
            for i in range(args.count):
                a = gen.gen_command(cmd)
                words = enc.command(ty, a)
                rec = sim.run(words)
                emit('%s[%d]' % (cmd, i), words, rec)
        # mutations: each kind attempted on successive commands until it
        # produces a fault; three rounds cover the full kind set
        for mk in mut_kinds * 3:
            produced = False
            for _tries in range(len(order) * 2):
                cmd = order[mi % len(order)]
                mi += 1
                ty = supported[cmd]
                a = gen.gen_command(cmd)
                words = enc.command(ty, a)
                save_choice = rng.choice
                rng.choice = lambda seq, _k=mk: _k
                mw, mkk = mutate_words(model, asm, sim, cmd, words, rng)
                rng.choice = save_choice
                if mw is None:
                    continue
                rec = sim.run(mw)
                if rec['fault'] == 0:
                    continue
                emit('MUT %s %s' % (cmd, mkk), mw, rec)
                produced = True
                break
            if not produced:
                print('warning: no %s mutation produced a fault' % mk)
        # sentinel: FFFFFFFF base/len marks the end of the record stream
        exp_lines.append('// end')
        exp_lines += ['FFFFFFFF', 'FFFFFFFF']
        (VEC_DIR / (name + '.hex')).write_text(
            '\n'.join(hex_lines) + '\n', encoding='utf-8')
        (VEC_DIR / (name + '.exp')).write_text(
            '\n'.join(exp_lines) + '\n', encoding='utf-8')
        print('wrote %s vectors to %s' % (name, VEC_DIR))
        return 0

    if args.reply_vectors:
        name, seed = args.reply_vectors
        rng = random.Random(int(seed))
        gen = ArgGen(model, rng)
        rep_sim = ReplySim(model, asm)
        MAX_EXP = 384
        VEC_DIR.mkdir(parents=True, exist_ok=True)
        hex_lines = []
        exp_lines = []
        base = 0

        def emit(tag, words, result, exec_w, rep, rep_len, fault):
            nonlocal base, hex_lines, exp_lines
            hex_lines.append('// %s' % tag)
            hex_lines += ['%08X' % w for w in words]
            rep_base = base + len(words)
            hex_lines += ['%08X' % w for w in rep]
            exp_lines.append('// %s' % tag)
            ew = list(exec_w[:64]) + [0] * (64 - len(exec_w))
            rw = list(rep[:MAX_EXP]) + [0] * (MAX_EXP - len(rep))
            exp_lines += ['%08X' % base, '%08X' % len(words),
                          '%08X' % result, '%08X' % len(exec_w)]
            exp_lines += ['%08X' % w for w in ew]
            exp_lines += ['%08X' % rep_base, '%08X' % rep_len,
                          '%08X' % len(rep)]
            exp_lines += ['%08X' % w for w in rw]
            exp_lines.append('%08X' % fault)
            base += len(words) + len(rep)

        ninst = 0
        for cmd in model.cmd_progs:
            info = model.cmd_info[cmd]
            if not info['reply_id']:
                continue
            ty = supported[cmd]
            for i in range(8):
                a = gen.gen_command(cmd)
                a['_flags'] = 1    # VK_COMMAND_GENERATE_REPLY_BIT_EXT
                if i == 1:
                    # force the first out pointer NULL for RPTR-absent
                    # coverage
                    ov = next((v.name for v in ty.variables
                               if 'var_out' in v.attrs
                               and (v.attrs.get('optional')
                                    or ['false'])[0] == 'true'), None)
                    if ov:
                        a[ov] = None
                if cmd == 'vkGetQueryPoolResults':
                    a['dataSize'] = rng.randint(0, 16)
                    a['pData'] = rng.randbytes(a['dataSize'])
                words = enc.command(ty, a)
                rec = sim.run(words)
                result = rng.getrandbits(32)
                try:
                    exec_w, rep = gen_reply_exec(
                        model, asm, rep_sim, cmd, ty, words, rec,
                        result, rng)
                except FaultErr as e:
                    print('reply fault %s[%d]: %s chain=%r'
                          % (cmd, i, e, rec['chain']))
                    raise
                emit('%s[%d]' % (cmd, i), words, result, exec_w, rep,
                     len(rep), 0)
                ninst += 1
        # overrun fault case: reply window one word short
        cmd = 'vkGetPhysicalDeviceProperties2'
        ty = supported[cmd]
        a = gen.gen_command(cmd)
        a['_flags'] = 1
        words = enc.command(ty, a)
        rec = sim.run(words)
        result = rng.getrandbits(32)
        exec_w, rep = gen_reply_exec(
            model, asm, rep_sim, cmd, ty, words, rec, result, rng)
        emit('OVERRUN %s' % cmd, words, result, exec_w, rep,
             len(rep) - 1, 1)
        ninst += 1
        # GENERATE_REPLY-clear case: a command with no reply program
        cmd = 'vkDestroyInstance'
        ty = supported[cmd]
        a = gen.gen_command(cmd)
        words = enc.command(ty, a)
        rec = sim.run(words)
        emit('NOREPLY %s' % cmd, words, 0, [], [], 8, 0)
        ninst += 1
        exp_lines.append('// end')
        exp_lines += ['FFFFFFFF', 'FFFFFFFF']
        (VEC_DIR / (name + '.hex')).write_text(
            '\n'.join(hex_lines) + '\n', encoding='utf-8')
        (VEC_DIR / (name + '.exp')).write_text(
            '\n'.join(exp_lines) + '\n', encoding='utf-8')
        print('wrote %s reply vectors to %s (%d instances)'
              % (name, VEC_DIR, ninst))
        return 0

    if args.session:
        name, seed = args.session
        rng = random.Random(int(seed))
        gen = ArgGen(model, rng)
        rep_sim = ReplySim(model, asm)
        VEC_DIR.mkdir(parents=True, exist_ok=True)
        cmds, fm = build_session(model, asm, sim, rep_sim, enc, gen, rng)
        insts = write_session(name, cmds, fm)
        nreset = sum(1 for c in cmds if c['reset'])
        nerr = sum(1 for c in cmds if c['out']['result'] != VK_OK)
        print('wrote %s session to %s: %d commands, %d sub-sessions, '
              '%d replying, %d non-OK'
              % (name, VEC_DIR, len(cmds), nreset + 1, len(insts), nerr))
        return 0

    if args.payfull_session:
        name, seed = args.payfull_session
        rng = random.Random(int(seed))
        gen = ArgGen(model, rng)
        rep_sim = ReplySim(model, asm)
        VEC_DIR.mkdir(parents=True, exist_ok=True)
        cmds, fm = build_session(model, asm, sim, rep_sim, enc, gen,
                                 rng, pay_words=args.paywords,
                                 kind='payfull')
        insts = write_session(name, cmds, fm)
        nerr = sum(1 for c in cmds if c['out']['result'] != VK_OK)
        print('wrote %s payfull session to %s: %d commands, '
              '%d non-OK (paywords=%d)'
              % (name, VEC_DIR, len(cmds), nerr, args.paywords))
        return 0

    if args.transport:
        name, seed = args.transport
        rng = random.Random(int(seed))
        gen = ArgGen(model, rng)
        rep_sim = ReplySim(model, asm)
        tape, exp, doc = build_transport(model, asm, sim, rep_sim, enc,
                                         gen, rng)
        write_transport(name, tape, exp, doc)
        return 0

    if args.compute_session:
        name, shvec = args.compute_session
        rng = random.Random(1)
        gen = ArgGen(model, rng)
        rep_sim = ReplySim(model, asm)
        vec = load_shvec(shvec)
        tape, exp, doc = build_transport(model, asm, sim, rep_sim, enc,
                                         gen, rng, vec=vec,
                                         variant=args.variant)
        write_transport(name, tape, exp, doc)
        return 0

    ap.print_help()
    return 0


if __name__ == '__main__':
    sys.exit(main())
