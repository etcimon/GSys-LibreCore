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

# fixed-width .exp record: 76 words, layout documented in
# g6lc_apu_vn_tables.md ("`.exp` expected-record format")
EXP_WORDS = 76


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
               'chain': [], 'obj_kind': 0}
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
            op, a, b, note = dec[mpc]
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
            mpc = self.exec_simple(op, a, b, rec, r, cur, mpc)

    def exec_simple(self, op, a, b, rec, r, cur, mpc):
        if op == 'U32':
            w = r.rd32()
            if a != G.DISCARD:
                rec['imm'][a] = w
                rec['immv'] |= 1 << a
        elif op == 'U64':
            w = r.rd64()
            if a != G.DISCARD:
                rec['q'][a] = w
                rec['qv'] |= 1 << a
        elif op == 'HANDLE':
            w = r.rd64()
            slot = (a >> 3) & 0x1F
            role = a & 7
            if w == 0 and role not in (G.ROLES['NEW'], G.ROLES['OPTIONAL']):
                raise FaultErr(FAULT['HANDLE_ZERO'], r.pos - 2, w)
            if slot != G.DISCARD:
                rec['q'][slot] = w
                rec['kind'][slot] = b
                rec['role'][slot] = role
                rec['qv'] |= 1 << slot
        elif op == 'PTR':
            w = r.rd64()
            if a != G.DISCARD:
                rec['pres'][a] = 1 if w else 0
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
            rec['blob'][a] = (r.pos, min(wn, 0x1FFFF))
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

    def run(self, cs_words, rec, result, exec_src):
        """-> reply word list.  exec_src(mpc, n, op, a, b, note) -> n words.
        Returns [] for a faulted decode or a command with no reply."""
        if rec['fault'] or not rec['reply_prog']:
            return []
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
                    out.extend(cs_words[off:off + wn])
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
    assert len(w) == EXP_WORDS, len(w)
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


class FrontModel:
    """Mirror of g6lc_apu_vnfront's externally visible state."""

    SLOTS = 256
    CB_BUFS = 16

    def __init__(self, model, asm):
        self.m = model
        self.asm = asm
        self.reset()

    def reset(self):
        self.ent = [None] * self.SLOTS
        self.gens = [0] * self.SLOTS
        self.idmap = {}
        self.live_cnt = 0
        self.cb_alloc = [0] * self.CB_BUFS
        self.cb_pool = [0] * self.CB_BUFS
        self.cb_hnd = [0] * self.CB_BUFS
        self.recs = [[] for _ in range(self.CB_BUFS)]
        self.rec_state = [0] * self.CB_BUFS   # 0 none,1 recording,2 sealed
        self.pushed = 0
        self.fence_sig = 0
        self.fence_lost = 0
        self.outstanding = []                  # (fence_slot, pin slots)
        self.work_hold = False                 # TB: gate work_ready_i

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
                          'state': 0, 'aux': 0, 'ctx': 0}
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

    def reset_ctx(self, ctx=0):
        """-> (retired, pinned remaining)."""
        ret = pin = 0
        for s, e in enumerate(self.ent):
            if e is None or e['ctx'] != ctx:
                continue
            if e['pins']:
                pin += 1
                continue
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
               'work': [], 'fault': rec['fault']}
        ew = list(self.m.profile_words_pool[:64])
        ew += [0] * (64 - len(ew))
        if rec['fault']:
            out['result'] = VK_ERR_UNKNOWN
            self._reply(out, words, rec, rep_sim, info, ew)
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

        if cls in ('NOP_OK', 'MAP', 'UPDATE'):
            pass

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

        elif cls == 'ALLOC':
            new = next((i for i in range(8)
                        if rec['qv'] >> i & 1 and rec['role'][i] == 1), -1)
            par = hnd[act['parent_q']] if act['parent_q'] != 7 else 0
            if new >= 0:
                st, h, slot = self.alloc(rec['q'][new], obj_kind, par)
                if st != 'OK':
                    out['result'] = self._err(st)
                elif ct in (session['T']['vkCreateBuffer'],
                            session['T']['vkCreateImage']):
                    if ct == session['T']['vkCreateBuffer']:
                        ds = next((i for i in range(8)
                                   if rec['qv'] >> i & 1
                                   and not rec['kind'][i]), -1)
                        sz = rec['q'][ds] if ds >= 0 else 0
                        blocks = (sz + 255) >> 8
                    else:
                        sz = rec['imm'][3] * rec['imm'][4] * 4
                        blocks = (sz + 4095) >> 12
                    st2, _s2 = self.setaux(h, 0xFFFFFF00,
                                           (blocks & 0xFFFFFF) << 8)
                    if st2 != 'OK':
                        out['result'] = VK_ERR_UNKNOWN
            else:
                slot = (act['flags'] >> 1) & 1
                for idv in blob_ids(slot):
                    free = next((i for i in range(self.CB_BUFS)
                                 if not self.cb_alloc[i]), -1)
                    if obj_kind == KIND['VkCommandBuffer'] and free < 0:
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
            for idv in ids:
                aux = 0
                if obj_kind == KIND['VkCommandBuffer']:
                    st, s, e = self.resolve(idv, obj_kind)
                    if st != 'OK':
                        out['result'] = VK_ERR_UNKNOWN
                        break
                    aux = e['aux'] & 0xFF
                st, s = self.retire(idv, obj_kind)
                if st != 'OK':
                    out['result'] = self._err(st)
                    break
                if obj_kind == KIND['VkCommandBuffer'] \
                        and aux < self.CB_BUFS:
                    self.cb_alloc[aux] = 0
                    self.cb_pool[aux] = 0
                    self.cb_hnd[aux] = 0

        elif cls == 'BIND':
            rs, ms = lu[1], lu[2]
            ds = next((i for i in range(8)
                       if rec['qv'] >> i & 1 and not rec['kind'][i]), -1)
            st, _s, e = self.resolve(hnd[rs], 0)
            if st != 'OK':
                out['result'] = VK_ERR_UNKNOWN
            else:
                st2, _s2, me = self.resolve(hnd[ms], 0)
                if st2 != 'OK':
                    out['result'] = VK_ERR_UNKNOWN
                else:
                    e['bind_mem'] = _s2
                    e['bind_off'] = rec['q'][ds] if ds >= 0 else 0

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
                self.setstate(hnd[cb_q], 0xF, 0)
            else:
                if not (e['state'] & CB_REC) or \
                        (e['state'] & (CB_INV | CB_PEND)):
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
                    self.recs[aux].append(recd)
                    out['record'] = recd

        elif cls == 'SUBMIT':
            fs = next((i for i in range(8)
                       if rec['qv'] >> i & 1 and rec['role'][i] == 3
                       and rec['q'][i]), -1)
            fslot = -1
            if fs >= 0 and hnd[fs] & 0xFFFF < 16:
                fslot = hnd[fs] & 0xFFFF
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
                    for s, e, aux in cbs:
                        e['state'] = CB_PEND
                        pins.append(s)
                        for r in self.recs[aux]:
                            if self.is_work(r['ctype']):
                                work.append(r['ctype'])
                        # PIN via cmdexec (at submit)
                        e['pins'] += 1
                    out['work'] = work
                    self.outstanding.append((fslot, cbs))
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
                for fslot, cbs in self.outstanding:
                    for s, e, _aux in cbs:
                        e['pins'] -= 1
                    if fslot >= 0:
                        self.fence_sig |= 1 << fslot
                self.outstanding = []
                if wt == 'wait':
                    mask = 0
                    for idv in blob_ids(0):
                        st, s, e = self.resolve(idv, KIND['VkFence'])
                        if st != 'OK' or s >= 16:
                            out['result'] = VK_ERR_UNKNOWN
                            break
                        mask |= 1 << s
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
                    if st != 'OK' or s >= 16:
                        out['result'] = VK_ERR_UNKNOWN
                        break
                    self.fence_sig &= ~(1 << s)
            else:
                fs = lu[1]
                s = hnd[fs] & 0xFFFF
                if s >= 16:
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
        out['rep'] = rep_sim.run(words, rec, out['result'], supply)

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


def build_session(model, asm, sim, rep_sim, enc, gen, rng):
    """-> (steps, instances).  Each step: {name, words, out, reset}."""
    m = model
    fm = FrontModel(model, asm)
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
          'pl', 'pipe', 'dp', 'ds', 'cp', 'cb', 'fen')}

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
                             allocationSize=0x100000,
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
        pCreateInfo=struct('VkShaderModuleCreateInfo', codeSize=16,
                           pCode=[0x07230203, 0x00010000, 0, 1]),
        pShaderModule=I['sm'])
    cmd('vkCreateDescriptorSetLayout', device=I['dev'],
        pCreateInfo=struct(
            'VkDescriptorSetLayoutCreateInfo', bindingCount=1,
            pBindings=[struct(
                'VkDescriptorSetLayoutBinding', binding=0,
                descriptorType=7,     # STORAGE_BUFFER
                descriptorCount=1, stageFlags=0x20,
                pImmutableSamplers=[])]),
        pSetLayout=I['dsl'])
    cmd('vkCreatePipelineLayout', device=I['dev'],
        pCreateInfo=struct('VkPipelineLayoutCreateInfo',
                           setLayoutCount=1, pSetLayouts=[I['dsl']],
                           pushConstantRangeCount=0,
                           pPushConstantRanges=[]),
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
        pCreateInfo=struct('VkDescriptorPoolCreateInfo', maxSets=1,
                           poolSizeCount=1,
                           pPoolSizes=[struct('VkDescriptorPoolSize',
                                              type=7,
                                              descriptorCount=1)]),
        pDescriptorPool=I['dp'])
    cmd('vkAllocateDescriptorSets', device=I['dev'],
        pAllocateInfo=struct('VkDescriptorSetAllocateInfo',
                             descriptorPool=I['dp'],
                             descriptorSetCount=1,
                             pSetLayouts=[I['dsl']]),
        pDescriptorSets=[I['ds']])
    cmd('vkUpdateDescriptorSets', device=I['dev'],
        descriptorWriteCount=1,
        pDescriptorWrites=[struct(
            'VkWriteDescriptorSet', dstSet=I['ds'], dstBinding=0,
            dstArrayElement=0, descriptorCount=1, descriptorType=7,
            pImageInfo=[], pTexelBufferView=[],
            pBufferInfo=[struct('VkDescriptorBufferInfo',
                                buffer=I['buf'], offset=0,
                                range=4096)])],
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
        descriptorSetCount=1, pDescriptorSets=[I['ds']],
        dynamicOffsetCount=0, pDynamicOffsets=[])
    cmd('vkCmdPushConstants', commandBuffer=I['cb'], layout=I['pl'],
        stageFlags=0x20, offset=0, size=4, pValues=b'\x2a\x00\x00\x00')
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
        descriptorSetCount=1, pDescriptorSets=[I['ds']])
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
    C = {k: newid() for k in ('inst', 'pd', 'dev', 'queue', 'cp', 'cb')}
    cmd('vkCreateInstance', reset=True, pInstance=C['inst'])
    cmd('vkEnumeratePhysicalDevices', instance=C['inst'],
        pPhysicalDeviceCount=1, pPhysicalDevices=[C['pd']])
    cmd('vkCreateDevice', physicalDevice=C['pd'],
        pCreateInfo=struct('VkDeviceCreateInfo'), pDevice=C['dev'])
    cmd('vkGetDeviceQueue', device=C['dev'], queueFamilyIndex=0,
        queueIndex=0, pQueue=C['queue'])
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
    (VEC_DIR / (name + '.hex')).write_text(
        '\n'.join(hex_lines) + '\n', encoding='utf-8')
    (VEC_DIR / (name + '.exp')).write_text(
        '\n'.join(exp_lines) + '\n', encoding='utf-8')
    import json as _json
    (VEC_DIR / (name + '.json')).write_text(
        _json.dumps([{'cmd': i['cmd'], 'i': i['i'],
                      'targs': to_jsonable(i['targs']),
                      'rep': i['rep'], 'result': i['result']}
                     for i in insts]), encoding='utf-8')
    return insts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--vectors', nargs=2, metavar=('NAME', 'SEED'))
    ap.add_argument('--reply-vectors', nargs=2, metavar=('NAME', 'SEED'))
    ap.add_argument('--session', nargs=2, metavar=('NAME', 'SEED'))
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

    ap.print_help()
    return 0


if __name__ == '__main__':
    sys.exit(main())
