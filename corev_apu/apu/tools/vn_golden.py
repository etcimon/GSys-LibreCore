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
    return model, asm


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--selftest', action='store_true')
    ap.add_argument('--vectors', nargs=2, metavar=('NAME', 'SEED'))
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

    ap.print_help()
    return 0


if __name__ == '__main__':
    sys.exit(main())
