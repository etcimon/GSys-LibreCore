#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""gen_vn_tables.py — generate the VnDec micro-program package.

Reads the pinned venus-protocol registry (specs/venus-protocol: vk.xml +
VK_EXT_command_serialization.xml + VK_MESA_venus_protocol.xml), the checked-in
command set (vn_command_set.txt) and device profile (vn_device_profile.toml),
and emits:

  corev_apu/apu/include/g6lc_apu_vn_pkg.sv   decode/reply ROMs and tables
  corev_apu/apu/tools/g6lc_apu_vn_tables.md  human-readable per-command map

Pin validation: Mesa 26.0.8 vendored headers (banner git-307d2d0b, not
public) regenerate identically from this pin except the `types_chain.h`
strict-aliasing cast of upstream 70991d4; wire format identical (log:
build-platform/workspace/build/apu-vn/pin-validate.log).

Other baseline for later (do not check out): Ubuntu 24.04 / Mesa 24.0.x
vendored headers carry banner `git-bfa3ebfb` (vk.xml 1.3.269, wire format 1);
the matching public venus-protocol commit is
bfa3ebfbb3e8c5894accc9c81c323a24f2a89b17.

Decode micro-ops follow architecture/uncore/apu-vulkan-engine.md §4.  The
`a`/`b` operand encodings chosen here:

  U32    a=imm slot | 0xFF discard        b=-
  U64    a=q slot | 0xFF discard          b=-
  HANDLE a={q[4:0], role[2:0]}            b=kind
  PTR    a=pres slot | 0xFF               b=body ops to skip when pres==0
  STYPE  a=-                              b=constidx of expected sType
  PNEXT  a=-                              b=chain-table index (word offset in
                                            APU_VN_CHAIN)
  ARRAY  a=cnt slot                       b=arrmeta index {bound};
                                            cnt==0 skips to matching ENDARR
  ENDARR a=-                              b=-
  BLOB   a=blob slot                      b=blobmeta index
                                            {elem_bytes[7:0],max_words[31:8]}
  FLAGS  a=imm slot | 0xFF                b=constidx of allow mask
  SKIPW  a=-                              b=word count
  CHECK  a=imm slot                       b=constidx of expected value
  OBJ    a=-                              b=kind this command allocs/retires
  END    a=replyprog id                   b=-
  RET    a=-                              b=-   ends a chain-body program

Reply ops (APU_VN_REPLY_ROM):

  RTYPE   emit u32 command type
  RRESULT emit u32 VkResult (from executor)
  RU32    a=src                           emit u32 from src; b=src index
                                            (IMM/Q/CNT/CONST/EXEC)
  RU64    a=src                           emit u64 (2 words) from src; b=idx
  RHANDLE a=q slot                        emit q[a] verbatim (u64)
  RPTR    a=pres slot                     emit u64 pres; skip b ops if pres==0
  RCONST  b={profidx[15:0],words[15:0]}   copy profile words
  RCHAIN  b=chain-table index             replay recorded pNext chain headers,
                                          then run reply bodies in reverse
  RBLOB   a=blob slot                     emit u64 recorded count + words
  REXBUF  a={idx[4:0],src[2:0]}           emit u64 count + bytes from executor
  REND    end of reply program
  RRET    end of reply chain-body program
  REXEC   a=src, b=n                    emit n words from executor
                                            staging
"""

import sys
import tomllib
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TOOLS = Path(__file__).resolve().parent
VN_DIR = REPO / 'specs' / 'venus-protocol'

if not (VN_DIR / 'vkxml.py').exists():
    sys.exit('specs/venus-protocol is not initialized '
             '(git submodule update --init -- specs/venus-protocol)')
sys.path.insert(0, str(VN_DIR))

import vkxml          # noqa: E402
import vn_protocol    # noqa: E402

VN_PIN = '9fa07f3cf7810df293abe0ff6a96032192f960d3'

DEC_OPS = {'U32': 1, 'U64': 2, 'HANDLE': 3, 'PTR': 4, 'STYPE': 5, 'PNEXT': 6,
           'ARRAY': 7, 'ENDARR': 8, 'BLOB': 9, 'FLAGS': 10, 'SKIPW': 11,
           'CHECK': 12, 'OBJ': 13, 'END': 14, 'RET': 15}
REP_OPS = {'RTYPE': 1, 'RRESULT': 2, 'RU32': 3, 'RU64': 4, 'RHANDLE': 5,
           'RPTR': 6, 'RCONST': 7, 'RCHAIN': 8, 'RBLOB': 9, 'REXBUF': 10,
           'REND': 11, 'RRET': 12, 'REXEC': 13}
SRC = {'IMM': 0, 'Q': 1, 'CNT': 2, 'CONST': 3, 'EXEC': 4}
ROLES = {'LOOKUP': 0, 'NEW': 1, 'RETIRE': 2, 'OPTIONAL': 3}

MAX_Q, MAX_IMM, MAX_CNT, MAX_PRES, MAX_BLOB, MAX_CHAIN = 8, 16, 4, 8, 2, 8
MAX_LOOP_DEPTH = 2
DISCARD = 0xFF
Q_SCRATCH, PRES_SCRATCH = 7, 7

# bitmask typedefs that carry a profile flag mask
MASKED_FLAGS = ('VkBufferUsageFlags', 'VkImageUsageFlags')


class Unfit(Exception):
    """A command cannot be expressed within the slot rules."""


class Model:
    def __init__(self, profile):
        self.profile = profile
        reg = vkxml.VkRegistry.parse(
            VN_DIR / 'xmls' / 'vk.xml',
            [VN_DIR / 'xmls' / 'VK_EXT_command_serialization.xml',
             VN_DIR / 'xmls' / 'VK_MESA_venus_protocol.xml'])
        self.gen = vn_protocol.Gen(False, reg)
        # Gen deep-copies the registry and prunes p_next to the supported
        # extension set; use its copy so type identity is consistent.
        self.reg = self.gen.reg
        self.stype_values = self.enum_ints('VkStructureType')
        self.api_consts = self._api_consts()

        self.consts = []          # u32 pool
        self.const_idx = {}
        self.arr_meta = []
        self.blob_meta = []
        self.chain_list = []      # flat tables, see emit_chain_table()
        self.chain_tabs = {}      # key -> word offset in APU_VN_CHAIN
        self.progs = {}           # ('body',name,partial) -> op list
        self.cmd_progs = {}       # cmd name -> op list
        self.reply_progs = {}     # key -> reply op list
        self.reply_ids = {}       # cmd name -> replyprog id
        self.kind_names = ['NONE']
        self.kind_of = {}
        self.cmd_info = {}
        self.profile_words_pool = []
        self.profile_words_idx = {}

    # ---- registry helpers ---------------------------------------------------

    def enum_ints(self, name):
        ty = self.reg.type_table.get(name)
        if ty is None or ty.enums is None:
            return {}
        out = {}
        for k, v in ty.enums.values.items():
            try:
                out[k] = int(str(v), 0)
            except ValueError:
                pass
        return out

    def _api_consts(self):
        """VK_MAX_* / VK_*_SIZE style constants -> int.  vkxml skips
        <enums type="constants"> groups, so parse them here."""
        import xml.etree.ElementTree as ET
        out = {}
        for xf in ('vk.xml', 'VK_EXT_command_serialization.xml',
                   'VK_MESA_venus_protocol.xml'):
            root = ET.parse(VN_DIR / 'xmls' / xf).getroot()
            for enums in root.iterfind('enums'):
                for e in enums.iterfind('enum'):
                    try:
                        k, v = vkxml.VkEnums._parse_enum(e)
                        out[k] = int(str(v), 0)
                    except (ValueError, AssertionError, KeyError):
                        pass
        for ty in self.reg.type_table.values():
            if ty.category == ty.ENUM and ty.enums is not None:
                for k, v in ty.enums.values.items():
                    try:
                        out[k] = int(str(v), 0)
                    except ValueError:
                        pass
        return out

    def enum_int(self, enum_name, key):
        return self.enum_ints(enum_name)[key]

    def const_int(self, name):
        return self.api_consts[name]

    def core_le_11(self, ty):
        for feat in self.reg.features:
            if ty in feat.types:
                return feat.number in ('1.0', '1.1')
        return False

    def const(self, val):
        val &= 0xFFFFFFFF
        if val not in self.const_idx:
            self.const_idx[val] = len(self.consts)
            self.consts.append(val)
        return self.const_idx[val]

    def arr_meta_idx(self, bound):
        bound &= 0xFFFFFF
        if bound not in self.arr_meta:
            self.arr_meta.append(bound)
        return self.arr_meta.index(bound)

    def blob_meta_idx(self, elem_bytes, max_words):
        meta = (elem_bytes & 0xFF) | ((max_words & 0xFFFFFF) << 8)
        if meta not in self.blob_meta:
            self.blob_meta.append(meta)
        return self.blob_meta.index(meta)

    def kind(self, ty_name):
        if ty_name not in self.kind_of:
            self.kind_of[ty_name] = len(self.kind_names)
            self.kind_names.append(ty_name)
        return self.kind_of[ty_name]

    def scalar_bytes(self, base):
        cat = base.category
        if cat == vkxml.VkType.HANDLE:
            return 8
        if cat == vkxml.VkType.ENUM:
            return 8 if base.enums.bitwidth == 64 else 4
        if cat == vkxml.VkType.BITMASK:
            return self.scalar_bytes(base.typedef)
        if cat == vkxml.VkType.BASETYPE:
            if base.typedef:
                return self.scalar_bytes(base.typedef)
            return 4
        if cat == vkxml.VkType.DEFAULT:
            if base.name == 'char':
                return 1
            if base.name == 'size_t':
                return 8
            return vn_protocol.Gen.PRIMITIVE_TYPES.get(base.name, 4)
        return 0

    def struct_len_targets(self, ty):
        """Members emitted fully inside a _partial encoder: len vars that
        another member's len_names points at, except when that member is a
        static array (Mesa _get_variable_validity gates on
        'wa_require_static_len' -- e.g. VkPhysicalDeviceMemoryProperties
        skips memoryTypeCount but still sends all memoryTypes[])."""
        targets = set()
        for var in ty.variables:
            if 'wa_require_static_len' in var.attrs:
                continue
            for ln in var.attrs.get('len_names', []):
                if not ln:
                    continue
                found = ty.find_variables(ln)
                if found:
                    targets.add(found[-1].name)
        return targets

    def partial_emit(self, ty, var):
        """Per-member validity of a _partial encoder, mirroring
        vn_protocol.py:_get_variable_validity for struct_is_partial:
        len targets are VALID (full emit), HANDLE/STRUCT members are
        PARTIAL (recursive partial emit), everything else is INVALID
        (skipped)."""
        if var.name in ('sType', 'pNext'):
            return 'full'
        if var.name in self.struct_len_targets(ty):
            return 'full'
        if var.ty.base.category in (vkxml.VkType.HANDLE,
                                    vkxml.VkType.STRUCT):
            return 'partial'
        return None

    def flag_mask_const(self, base):
        masks = self.profile.get('flag_masks', {})
        if base.name not in MASKED_FLAGS or base.name not in masks:
            return None
        enum_name = base.requires.name if base.requires else None
        vals = self.enum_ints(enum_name) if enum_name else {}
        prefix = {'VkBufferUsageFlags': 'VK_BUFFER_USAGE_',
                  'VkImageUsageFlags': 'VK_IMAGE_USAGE_'}[base.name]
        mask = 0
        for part in masks[base.name].split('|'):
            key = prefix + part + '_BIT'
            if key not in vals:
                raise Unfit('unknown flag %s for %s' % (key, base.name))
            mask |= vals[key]
        return self.const(mask)

    def array_bound(self, elem_base, member_name):
        b = self.profile.get('bounds', {})
        return int(b.get(elem_base.name, b.get(member_name,
                                             b.get('default', 256))))

    def blob_bound(self, member_name):
        return int(self.profile.get('blob_bounds', {}).get(
            member_name, self.profile.get('blob_bounds', {}).get(
                'default', 1048576)))

    # ---- program emission ---------------------------------------------------

    def _alloc(self, what):
        """Persistent-scope slot allocation; raises Unfit on overflow."""
        m = {'q': MAX_Q, 'imm': MAX_IMM, 'pres': MAX_PRES,
             'blob': MAX_BLOB}[what]
        cur = self.slot_cnt[what]
        if cur >= m:
            raise Unfit('%s slots exhausted (>%d)' % (what, m))
        self.slot_cnt[what] = cur + 1
        return cur

    def q_slot(self, scope):
        return Q_SCRATCH if scope else self._alloc('q')

    def imm_slot(self, scope):
        return DISCARD if scope else self._alloc('imm')

    def pres_slot(self, scope):
        return PRES_SCRATCH if scope else self._alloc('pres')

    def blob_slot(self, scope):
        if scope:
            self._scratch_blob ^= 1
            return self._scratch_blob
        return self._alloc('blob')

    def cnt_slot(self, scope):
        """Lowest cnt slot not live.  Top-level array counts stay live to
        the end of the command (record); element-scoped counts are freed at
        ENDARR."""
        for i in range(MAX_CNT):
            if i not in self.cnt_live:
                self.cnt_live.add(i)
                self.cnt_stack.append((i, bool(scope)))
                return i
        raise Unfit('cnt slots exhausted (loop nesting too deep)')

    def cnt_endarr(self):
        slot, scratch = self.cnt_stack.pop()
        if scratch:
            self.cnt_live.discard(slot)

    def emit(self, op, a=0, b=0, note=''):
        self.prog.append([op, a, b, note])

    def emit_scalar(self, var, scope):
        base = var.ty.base
        size = self.scalar_bytes(base)
        if base.category == vkxml.VkType.BITMASK and size == 4:
            mc = self.flag_mask_const(base)
            if mc is not None:
                self.emit('FLAGS', self.imm_slot(scope), mc, var.name)
                return
        if size == 4:
            self.emit('U32', self.imm_slot(scope), 0, var.name)
        elif size == 8:
            self.emit('U64', self.q_slot(scope), 0, var.name)
        else:
            raise Unfit('scalar %s has odd size %d' % (var.name, size))

    def obj_tail(self, cmd):
        for pre in ('vkDestroy', 'vkFree'):
            if cmd.startswith(pre):
                return cmd[len(pre):]
        return ''

    def retired_kind_name(self, cmd):
        """Handle type a Destroy/Free command retires, or None."""
        if cmd.startswith('vkDestroy'):
            return 'Vk' + cmd[len('vkDestroy'):]
        return {'vkFreeMemory': 'VkDeviceMemory',
                'vkFreeCommandBuffers': 'VkCommandBuffer',
                'vkFreeDescriptorSets': 'VkDescriptorSet'}.get(cmd)

    def emit_handle(self, var, scope, out):
        base = var.ty.base
        role = 'LOOKUP'
        if out:
            role = 'NEW'
        elif base.name == self.retired_kind_name(self.cur_cmd):
            role = 'RETIRE'
        elif var.is_optional():
            role = 'OPTIONAL'
        slot = self.q_slot(scope)
        self.emit('HANDLE', (slot << 3) | ROLES[role],
                  self.kind(base.name), '%s:%s' % (var.name, role))
        return slot

    def emit_member(self, parent, var, scope, partial):
        base = var.ty.base
        name = var.name
        cat = base.category

        if name == 'sType' and parent.s_type:
            self.emit('STYPE', 0,
                      self.const(self.stype_values[parent.s_type]), 'sType')
            return
        if var.is_p_next():
            self.emit('PNEXT', 0, self.chain_tbl(parent, partial), 'pNext')
            return

        if var.is_dynamic_array() or var.is_blob():
            # array of C strings: outer count + per-element blob
            if cat == vkxml.VkType.DEFAULT and base.name == 'char' and \
                    var.ty.indirection_depth() >= 2:
                cnt = self.cnt_slot(scope)
                self.emit('ARRAY', cnt,
                          self.arr_meta_idx(self.array_bound(base, name)),
                          name)
                self.emit('BLOB', self.blob_slot(True),
                          self.blob_meta_idx(1,
                                             (self.blob_bound(name) + 3) // 4),
                          name + '[]')
                self.emit('ENDARR')
                self.cnt_endarr()
                return
            # out blob (vkGetQueryPoolResults::pData): the wire carries
            # only the u64 byte count, no payload (Mesa
            # vn_encode_vkGetQueryPoolResults).  elem_bytes=0 records the
            # count position without consuming words.
            if var.is_blob() and 'var_out' in var.attrs:
                slot = self.blob_slot(scope)
                self.emit('BLOB', slot,
                          self.blob_meta_idx(
                              0, (self.blob_bound(name) + 3) // 4),
                          name)
                if not scope:
                    self.blob_map[name] = slot
                return
            # scalar/blob array: raw recording
            if var.is_blob() or var.has_c_string() or cat in (
                    base.DEFAULT, base.BASETYPE, base.ENUM, base.BITMASK,
                    base.HANDLE) or cat == vkxml.VkType.FUNCPOINTER:
                eb = 1 if (var.is_blob() or base.name in ('char', 'void')) \
                    else self.scalar_bytes(base)
                slot = self.blob_slot(scope)
                self.emit('BLOB', slot,
                          self.blob_meta_idx(eb,
                                             (self.blob_bound(name) + 3) // 4),
                          name)
                if not scope:
                    self.blob_map[name] = slot
                return
            # struct/union array.  Past MAX_LOOP_DEPTH, fixed-size elements
            # are recorded verbatim as a blob instead of being walked.
            if self.depth >= MAX_LOOP_DEPTH:
                n = self.struct_words(base)
                if n is None:
                    raise Unfit('loop depth > %d and element %s is not '
                                'fixed-size' % (MAX_LOOP_DEPTH, base.name))
                slot = self.blob_slot(scope)
                self.emit('BLOB', slot,
                          self.blob_meta_idx(
                              n * 4, (self.blob_bound(name) + 3) // 4),
                          name)
                if not scope:
                    self.blob_map[name] = slot
                return
            cnt = self.cnt_slot(scope)
            self.emit('ARRAY', cnt,
                      self.arr_meta_idx(self.array_bound(base, name)), name)
            if not scope:
                self.persist_cnt.append((cnt, name))
            self.depth += 1
            elem_partial = 'var_out' in var.attrs or partial
            self.emit_struct(base, True, elem_partial)
            self.depth -= 1
            self.emit('ENDARR')
            self.cnt_endarr()
            return

        if var.ty.is_static_array():
            dim_s = var.ty.static_array_size()
            try:
                dim = int(str(dim_s), 0)
            except ValueError:
                dim = self.const_int(dim_s)
            # every static array is preceded by vn_encode_array_size(dim)
            # on the wire; scalar payloads are recorded as a blob
            if cat not in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
                eb = self.scalar_bytes(base)
                slot = self.blob_slot(scope)
                self.emit('BLOB', slot,
                          self.blob_meta_idx(eb, (dim * eb + 3) // 4),
                          name)
                if not scope:
                    self.blob_map[name] = slot
                return
            if self.depth >= MAX_LOOP_DEPTH:
                n = self.struct_words(base)
                if n is None:
                    raise Unfit('loop depth > %d and static element %s is '
                                'not fixed-size' % (MAX_LOOP_DEPTH,
                                                    base.name))
                slot = self.blob_slot(scope)
                self.emit('BLOB', slot,
                          self.blob_meta_idx(n * 4, (dim * n + 3) // 4),
                          name)
                if not scope:
                    self.blob_map[name] = slot
                return
            cnt = self.cnt_slot(scope)
            self.emit('ARRAY', cnt, self.arr_meta_idx(dim), name)
            if not scope:
                self.persist_cnt.append((cnt, name))
            self.depth += 1
            self.emit_struct(base, True, partial)
            self.depth -= 1
            self.emit('ENDARR')
            self.cnt_endarr()
            return

        if var.ty.is_pointer():
            pres = self.pres_slot(scope)
            if not scope:
                self.pres_map[name] = pres
            if not self.gen.is_serializable(base):
                self.emit('PTR', pres, 0, name)   # presence only
                return
            mark = len(self.prog)
            self.emit('PTR', pres, 0, name)
            # vn_protocol.py validity model: non-const pointers are 'var_out';
            # a var_out that also appears in another var's len_names is
            # in/out ('var_in' names the array it counts).  Mesa encodes
            # the pointee for in and in/out params (pPhysicalDeviceCount in
            # vkEnumeratePhysicalDevices sends presence + u32 value); a
            # pure-out scalar sends presence only (pApiVersion in
            # vkEnumerateInstanceVersion).  Out handles still send their
            # current id; out structs are partial-encoded.
            out = 'var_out' in var.attrs
            inout = out and 'var_in' in var.attrs
            if cat == vkxml.VkType.HANDLE:
                slot = self.emit_handle(var, scope, out)
                if out and not scope:
                    self.q_map[name] = slot
            elif cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
                self.emit_struct(base, scope, partial or (out and not inout))
            elif inout or not out:
                self.emit_scalar(var, scope)
            # else: pure-out scalar/blob -> presence word only
            self.prog[mark][2] = len(self.prog) - mark - 1
            return

        # plain member
        if cat == vkxml.VkType.HANDLE:
            self.emit_handle(var, scope, 'var_out' in var.attrs)
            return
        if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
            self.emit_struct(base, scope, partial)
            return
        # feature-request bools: validated against the profile allow-mask
        # and discarded rather than consuming an imm slot
        if base.name == 'VkBool32' and parent.name.endswith('Features'):
            allowed = 1 if self.profile.get('features', {}).get(
                name, False) else 0
            self.emit('FLAGS', DISCARD, self.const(allowed), name)
            return
        self.emit_scalar(var, scope)

    def emit_struct(self, ty, scope, partial):
        if ty.category == ty.UNION:
            tag = vn_protocol.Gen.UNION_DEFAULT_TAGS.get(ty.name)
            if tag is None:
                raise Unfit('union %s has no default tag' % ty.name)
            # Mesa emits a u32 default-tag word before the union member
            # (vn_encode_VkClearColorValue: `static const uint32_t tag`)
            self.emit('CHECK', DISCARD, self.const(tag),
                      '%s tag %d' % (ty.name, tag))
            var = ty.variables[tag]
            self.emit_member(ty, var, scope, partial)
            return
        for var in ty.variables:
            if partial:
                mode = self.partial_emit(ty, var)
                if mode is None:
                    continue
                # sType/pNext keep the parent's partial context (the
                # chain table variant is keyed on it); 'full' members
                # emit fully, 'partial' members recursively
                self.emit_member(
                    ty, var, scope,
                    partial if var.name in ('sType', 'pNext')
                    else mode == 'partial')
                continue
            self.emit_member(ty, var, scope, partial)

    # ---- chain tables and body programs -------------------------------------

    def chain_tbl(self, parent, partial):
        key = ('dec', parent.name, bool(partial))
        if key in self.chain_tabs:
            return self.chain_tabs[key]
        tbl = len(self.chain_list)
        self.chain_tabs[key] = tbl
        entries = []           # (stype, ('body',name,partial))
        self.chain_list.append({'key': key, 'entries': entries})
        for nty in parent.p_next:
            if not self.gen.is_serializable(nty) or not self.core_le_11(nty):
                continue
            st = self.stype_values.get(nty.s_type)
            if st is None:
                continue
            pkey = ('body', nty.name, bool(partial))
            if pkey not in self.progs:
                self.progs[pkey] = None
                self.progs[pkey] = self.build_body_prog(nty, partial)
            entries.append((st, pkey))
        return tbl

    def build_body_prog(self, ty, partial):
        """Chain-node program: PNEXT continuation + members + RET."""
        saved = (self.prog, self.slot_cnt, self.depth,
                 self._scratch_blob, self.cnt_live, self.cnt_stack)
        self.prog = []
        self.slot_cnt = {'q': 0, 'imm': 0, 'pres': 0, 'blob': 0}
        self.depth = 1          # scratch scope semantics
        self._scratch_blob = 0
        self.cnt_live = set(self.cnt_live)   # outer counts stay live
        self.cnt_stack = []
        # no PNEXT op here: a chain node's own pNext is the chain
        # continuation consumed by the parent's PNEXT op, not part of
        # the body (Mesa _pnext: pres,stype pairs forward, then bodies
        # in reverse order)
        for var in ty.variables:
            if var.name in ('sType', 'pNext'):
                continue
            if partial:
                mode = self.partial_emit(ty, var)
                if mode is None:
                    continue
                self.emit_member(ty, var, True, mode == 'partial')
                continue
            self.emit_member(ty, var, True, partial)
        self.emit('RET')
        prog = self.prog
        (self.prog, self.slot_cnt, self.depth,
         self._scratch_blob, self.cnt_live, self.cnt_stack) = saved
        return prog

    # ---- command program ----------------------------------------------------

    def build_command(self, name):
        ty = next(t for t in
                  self.gen.supported_types[vkxml.VkType.COMMAND]
                  if t.name == name)
        self.cur_cmd = name
        self.prog = []
        self.slot_cnt = {'q': 0, 'imm': 0, 'pres': 0, 'blob': 0}
        self.depth = 0
        self._scratch_blob = 0
        self.cnt_live = set()
        self.cnt_stack = []
        self.persist_cnt = []
        self.pres_map = {}
        self.q_map = {}
        self.blob_map = {}
        for var in ty.variables:
            self.emit_member(ty, var, False, False)
        # OBJ: the object kind this command allocates/retires, if any
        obj_kind = None
        tail = self.retired_kind_name(name)
        for var in ty.variables:
            b = var.ty.base
            if b.category != vkxml.VkType.HANDLE:
                continue
            if 'var_out' in var.attrs:
                obj_kind = self.kind(b.name)
            elif tail and b.name == tail:
                obj_kind = self.kind(b.name)
        if obj_kind is not None:
            self.emit('OBJ', 0, obj_kind, '')
        reply_id = self.build_reply(ty)
        self.emit('END', reply_id, 0, '')
        self.cmd_progs[name] = self.prog
        self.cmd_info[name] = {
            'type_name': ty.attrs.get('c_type'),
            'type_id': self.enum_int('VkCommandTypeEXT',
                                     ty.attrs['c_type']),
            'prog': self.prog,
            'reply_id': reply_id,
            'slots': {k: self.slot_cnt[k] for k in self.slot_cnt},
            'cnt': [n for _, n in []],
        }
        return self.prog

    # ---- reply --------------------------------------------------------------

    def build_reply(self, ty):
        if not ty.ret and not any('var_out' in v.attrs
                                  for v in ty.variables):
            return 0
        ops = [['RTYPE', 0, 0, ty.name]]
        if ty.ret:
            ops.append(['RRESULT', 0, 0, ''])
        for var in ty.variables:
            if 'var_out' not in var.attrs:
                continue
            ops.extend(self.reply_var(var))
        ops.append(['REND', 0, 0, ''])
        key = ('reply', ty.name)
        self.reply_progs[key] = ops
        rid = len([k for k in self.reply_ids.values() if k]) + 1
        self.reply_ids[ty.name] = rid
        return rid

    def reply_var(self, var):
        base = var.ty.base
        cat = base.category
        ops = []
        if var.is_dynamic_array() or var.is_blob():
            if cat == vkxml.VkType.HANDLE:
                ops.append(['RBLOB', self.blob_map.get(var.name, 0), 0,
                            var.name])
            else:
                ops.append(['REXBUF', SRC['EXEC'], 0, var.name])
            return ops
        if var.ty.is_pointer():
            pres = self.pres_map.get(var.name, 0)
            ops.append(['RPTR', pres, 0, var.name])
            mark = len(ops) - 1
            if cat == vkxml.VkType.HANDLE:
                ops.append(['RHANDLE', self.q_map.get(var.name, 0), 0,
                            var.name])
            elif cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
                if base.s_type:
                    ops.append(['RU32', SRC['CONST'],
                                self.const(self.stype_values[base.s_type]),
                                'sType'])
                if any(v.is_p_next() for v in base.variables):
                    ops.append(['RCHAIN', 0, self.rchain_tbl(base),
                                var.name])
                ops.extend(self.reply_body(base))
            else:
                size = self.scalar_bytes(base)
                ops.append(['RU64' if size == 8 else 'RU32',
                            SRC['EXEC'], 0, var.name])
            ops[mark][2] = len(ops) - mark - 1
            return ops
        size = self.scalar_bytes(base)
        ops.append(['RU64' if size == 8 else 'RU32', SRC['EXEC'], 0,
                    var.name])
        return ops

    def reply_body(self, ty):
        """Body of a reply out-struct: RCONST profile block or REXEC."""
        words = self.profile_words(ty)
        if words is not None:
            idx = self.profile_block(words)
            return [['RCONST', 0, (idx | (len(words) << 16)), ty.name]]
        n = self.struct_words(ty)
        if n is None:
            n = 0
        return [['REXEC', SRC['EXEC'], n, ty.name]]

    def rchain_tbl(self, ty):
        key = ('rep', ty.name)
        if key in self.chain_tabs:
            return self.chain_tabs[key]
        tbl = len(self.chain_list)
        self.chain_tabs[key] = tbl
        entries = []
        self.chain_list.append({'key': key, 'entries': entries})
        for nty in ty.p_next:
            if not self.gen.is_serializable(nty) or not self.core_le_11(nty):
                continue
            st = self.stype_values.get(nty.s_type)
            if st is None:
                continue
            pkey = ('rbody', nty.name)
            if pkey not in self.reply_progs:
                ops = []
                if any(v.is_p_next() for v in nty.variables):
                    ops.append(['RCHAIN', 0, self.rchain_tbl(nty),
                                nty.name])
                ops.extend(self.reply_body(nty))
                ops.append(['RRET', 0, 0, ''])
                self.reply_progs[pkey] = ops
            entries.append((st, pkey))
        return tbl

    # ---- static word counting / profile blocks -------------------------------

    def struct_words(self, ty, depth=0):
        if ty.category == ty.UNION:
            tag = vn_protocol.Gen.UNION_DEFAULT_TAGS.get(ty.name)
            if tag is None:
                return None
            n = self.member_words(ty, ty.variables[tag], depth + 1)
            return None if n is None else n + 1
        if depth > 6:
            return None
        words = 0
        for var in ty.variables:
            if var.name in ('sType', 'pNext'):
                continue
            n = self.member_words(ty, var, depth + 1)
            if n is None:
                return None
            words += n
        return words

    def member_words(self, parent, var, depth):
        base = var.ty.base
        cat = base.category
        if var.is_dynamic_array() or var.is_blob() or var.ty.is_pointer():
            return None
        if var.ty.is_static_array():
            dim_s = var.ty.static_array_size()
            try:
                dim = int(str(dim_s), 0)
            except ValueError:
                dim = self.const_int(dim_s)
            if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
                n = self.struct_words(base, depth)
                return None if n is None else n * dim
            sz = self.scalar_bytes(base)
            return (dim * sz + 3) // 4
        if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
            return self.struct_words(base, depth)
        sz = self.scalar_bytes(base)
        return (sz + 3) // 4 if sz else 1

    def profile_block(self, words):
        key = tuple(words)
        if key not in self.profile_words_idx:
            self.profile_words_idx[key] = len(self.profile_words_pool)
            self.profile_words_pool.extend(words)
        return self.profile_words_idx[key]

    def profile_words(self, ty):
        p = self.profile
        name = ty.name
        if name == 'VkPhysicalDeviceFeatures':
            feats = p.get('features', {})
            return [1 if feats.get(v.name, False) else 0
                    for v in ty.variables]
        if name == 'VkPhysicalDeviceLimits':
            lim = p.get('limits', {})
            out = []
            for v in ty.variables:
                val = lim.get(v.name, 0)
                if v.ty.is_static_array():
                    dim_s = v.ty.static_array_size()
                    try:
                        dim = int(str(dim_s), 0)
                    except ValueError:
                        dim = self.const_int(dim_s)
                    seq = val if isinstance(val, list) else [0] * dim
                    seq = (seq + [0] * dim)[:dim]
                    out += [self.num_word(v.ty.base, x) for x in seq]
                else:
                    out.append(self.num_word(v.ty.base, val))
            return out
        if name == 'VkPhysicalDeviceSparseProperties':
            return [0] * 5
        if name == 'VkPhysicalDeviceMemoryProperties':
            mem = p.get('memory', {})
            mpf = self.enum_ints('VkMemoryPropertyFlagBits')
            mhf = self.enum_ints('VkMemoryHeapFlagBits')
            def mp(v):
                r = 0
                for t in v.split('|'):
                    r |= mpf['VK_MEMORY_PROPERTY_' + t + '_BIT']
                return r
            def mh(v):
                r = 0
                for t in v.split('|'):
                    r |= mhf['VK_MEMORY_HEAP_' + t + '_BIT']
                return r
            words = [2,
                     mp(mem.get('type0_flags', 'DEVICE_LOCAL')), 0,
                     mp(mem.get('type1_flags',
                                'HOST_VISIBLE|HOST_COHERENT')), 0]
            words += [0, 0] * 30
            words += [1]
            size = int(mem.get('heap0_size', 0))
            words += [size & 0xFFFFFFFF, (size >> 32) & 0xFFFFFFFF,
                      mh('DEVICE_LOCAL')]
            words += [0, 0, 0] * 15
            return words
        if name == 'VkQueueFamilyProperties':
            q = p.get('queue_family0', {})
            qf = self.enum_ints('VkQueueFlagBits')
            v = 0
            for t in str(q.get('queueFlags', '')).split('|'):
                v |= qf['VK_QUEUE_' + t + '_BIT']
            g = q.get('minImageTransferGranularity', [0, 0, 0])
            return [v, int(q.get('queueCount', 0)),
                    int(q.get('timestampValidBits', 0)),
                    int(g[0]), int(g[1]), int(g[2])]
        if name == 'VkPhysicalDeviceProperties':
            d = p.get('device', {})
            ver = str(d.get('apiVersion', '0.0.0')).split('.')
            api = (int(ver[0]) << 29) | (int(ver[1]) << 22) | int(ver[2])
            dt = self.enum_ints('VkPhysicalDeviceType')
            words = [api, int(d.get('driverVersion', 0)),
                     int(d.get('vendorID', 0)), int(d.get('deviceID', 0)),
                     dt['VK_PHYSICAL_DEVICE_TYPE_' +
                        str(d.get('deviceType', 'OTHER'))]]
            nm = str(d.get('deviceName', '')).encode()[:255]
            nm += b'\0' * (256 - len(nm))
            for i in range(0, 256, 4):
                words.append(int.from_bytes(nm[i:i + 4], 'little'))
            words += [0] * 4
            words += self.profile_words(
                self.reg.type_table['VkPhysicalDeviceLimits'])
            words += self.profile_words(
                self.reg.type_table['VkPhysicalDeviceSparseProperties'])
            return words
        # all-bool feature structs (chained onto *Features2): all-zero block
        members = [v for v in ty.variables
                   if v.name not in ('sType', 'pNext')]
        if members and all(v.ty.base.name == 'VkBool32' for v in members):
            n = self.struct_words(ty)
            if n is not None:
                return [0] * n
        return None

    def num_word(self, base, val):
        if base.name == 'float':
            import struct as _s
            return int.from_bytes(_s.pack('<f', float(val)), 'little')
        return int(val) & 0xFFFFFFFF

    # ---- driver ---------------------------------------------------------------

    def read_command_set(self, path):
        names = []
        for line in open(path, encoding='utf-8').read().splitlines():
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            names.append(line)
        return names

    def run(self, cmd_names):
        supported = {t.name: t for t in
                     self.gen.supported_types[vkxml.VkType.COMMAND]}
        unfit = {}
        for name in cmd_names:
            if name not in supported:
                unfit[name] = 'not a supported Venus command'
                continue
            if not self.gen.is_serializable(supported[name]):
                unfit[name] = 'not serializable on the Venus wire'
                continue
            try:
                self.build_command(name)
            except Unfit as e:
                unfit[name] = str(e)
            except Exception as e:  # keep diagnosing the whole set
                unfit[name] = 'error: %r' % e
        return unfit

    # ---- ROM assembly ---------------------------------------------------------

    def assemble(self):
        """Lay out programs; returns dict of SV-ready tables."""
        dec = []          # (op,a,b,note)
        mpc_of_prog = {}
        # body programs first (order of discovery), then commands in set order
        for key, prog in self.progs.items():
            if prog is None:
                raise RuntimeError('unbuilt body program %r' % key)
            mpc_of_prog[key] = len(dec)
            dec.extend(prog)
        entry_of_cmd = {}
        for name, prog in self.cmd_progs.items():
            entry_of_cmd[name] = len(dec)
            dec.extend(prog)
        # reply ROM
        rep = []
        mpc_of_rep = {}
        for key, ops in self.reply_progs.items():
            mpc_of_rep[key] = len(rep)
            rep.extend(ops)
        # chain words: pairs {stype,mpc} then a 0 terminator per table
        chain = []
        tbl_off = {}
        for i, tbl in enumerate(self.chain_list):
            tbl_off[i] = len(chain)
            for st, pkey in tbl['entries']:
                target = mpc_of_rep[pkey] if pkey[0] == 'rbody' \
                    else mpc_of_prog[pkey]
                chain.append(st | (target << 32))
            chain.append(0)
        # PNEXT/RCHAIN operands were emitted as table-list indices; patch
        # them to word offsets into APU_VN_CHAIN
        for prog in list(self.progs.values()) + \
                list(self.cmd_progs.values()):
            for op in prog:
                if op[0] == 'PNEXT':
                    op[2] = tbl_off[op[2]]
        for ops in self.reply_progs.values():
            for op in ops:
                if op[0] == 'RCHAIN':
                    op[2] = tbl_off[op[2]]
        return {'dec': dec, 'rep': rep, 'chain': chain,
                'tbl_off': tbl_off,
                'mpc_of_prog': mpc_of_prog, 'mpc_of_rep': mpc_of_rep,
                'entry_of_cmd': entry_of_cmd}


def enc_word(op, a, b):
    return (op << 40) | ((a & 0xFF) << 32) | (b & 0xFFFFFFFF)


def emit_sv(model, asm, profile):
    dec = asm['dec']
    rep = asm['rep']
    chain = asm['chain']
    lines = []
    A = lines.append

    def arr(width, name, size_expr, words, fmt):
        if not words:
            A('  localparam logic [%d:0] %s %s = \'{default: \'0};'
              % (width - 1, name, size_expr))
            return
        A('  localparam logic [%d:0] %s %s = \'{' % (width - 1, name,
                                                    size_expr))
        body = [fmt(w) for w in words]
        for i in range(0, len(body), 4):
            row = body[i:i + 4]
            comma = ',' if i + 4 < len(body) else ''
            A('    ' + ', '.join(row) + comma)
        A('  };')

    A('// Copyright 2026 Etienne Cimon')
    A('// SPDX-License-Identifier: CERN-OHL-S-2.0 OR '
      'LicenseRef-GSys-Commercial')
    A('// GENERATED by corev_apu/apu/tools/gen_vn_tables.py from')
    A('// venus-protocol %s (vk.xml %s). Do not edit.'
      % (VN_PIN, model.reg.vk_xml_version))
    A('// Mesa 26.0.8 vendored headers (banner git-307d2d0b, not public)')
    A('// regenerate identically from this pin except the types_chain.h')
    A('// strict-aliasing cast of upstream 70991d4; wire format identical')
    A('// (log: build-platform/workspace/build/apu-vn/pin-validate.log).')
    A('')
    A('package g6lc_apu_vn_pkg;')
    A('')
    A('  localparam string APU_VN_VKXML = "%s";' % model.reg.vk_xml_version)
    A('')
    # command type params
    for name, info in model.cmd_info.items():
        pname = 'APU_VN_TYPE_' + model.reg.upper_name(name) + '_EXT'
        A('  localparam int %s = %d;' % (pname, info['type_id']))
    A('')
    # kind enum
    A('  typedef enum logic [7:0] {')
    kinds = ['APU_VN_KIND_NONE = 0']
    for i, kn in enumerate(model.kind_names[1:], 1):
        kinds.append('APU_VN_KIND_%s = %d'
                     % (model.reg.upper_name(kn), i))
    for i, k in enumerate(kinds):
        A('    %s%s' % (k, ',' if i < len(kinds) - 1 else ''))
    A('  } apu_vn_kind_e;')
    A('')
    # decode entry table
    max_type = model.reg.max_vk_command_type_value
    A('  localparam int APU_VN_DEC_TYPE_MAX = %d;' % max_type)
    type_to_cmd = {i['type_id']: n for n, i in model.cmd_info.items()}
    entries = []
    for t in range(max_type + 1):
        if t in type_to_cmd:
            entries.append("16'h%04X" % asm['entry_of_cmd'][type_to_cmd[t]])
        else:
            entries.append("16'hFFFF")
    arr(16, 'APU_VN_DEC_ENTRY', '[0:APU_VN_DEC_TYPE_MAX]',
        entries, lambda w: w)
    A('')
    # decode ROM
    A('  localparam int APU_VN_DEC_ROM_WORDS = %d;' % len(dec))
    dec_words = []
    dec_notes = []
    for op, a, b, note in dec:
        dec_words.append(enc_word(DEC_OPS[op], a, b))
        dec_notes.append('%s a=%d b=0x%X %s' % (op, a, b, note))
    if dec_words:
        A('  localparam logic [47:0] APU_VN_DEC_ROM '
          '[0:APU_VN_DEC_ROM_WORDS-1] = \'{')
        for i, w in enumerate(dec_words):
            comma = ',' if i < len(dec_words) - 1 else ''
            A("    48'h%012X%s // %s" % (w, comma, dec_notes[i]))
        A('  };')
    A('')
    # reply entry + ROM
    max_rep = max(model.reply_ids.values()) if model.reply_ids else 0
    A('  localparam int APU_VN_REPLY_PROG_MAX = %d;' % max_rep)
    rep_entries = ["16'hFFFF"] * (max_rep + 1)
    for cmd, rid in model.reply_ids.items():
        rep_entries[rid] = "16'h%04X" % asm['mpc_of_rep'][('reply', cmd)]
    arr(16, 'APU_VN_REPLY_ENTRY', '[0:APU_VN_REPLY_PROG_MAX]',
        rep_entries, lambda w: w)
    A('')
    A('  localparam int APU_VN_REPLY_ROM_WORDS = %d;' % len(rep))
    if rep:
        A('  localparam logic [47:0] APU_VN_REPLY_ROM '
          '[0:APU_VN_REPLY_ROM_WORDS-1] = \'{')
        for i, w in enumerate(rep):
            op, a, b, note = w
            comma = ',' if i < len(rep) - 1 else ''
            A("    48'h%012X%s // %s a=%d b=0x%X %s"
              % (enc_word(REP_OPS[op], a, b), comma, op, a, b, note))
        A('  };')
    else:
        A("  localparam logic [47:0] APU_VN_REPLY_ROM "
          "[0:APU_VN_REPLY_ROM_WORDS-1] = '{default: '0};")
    A('')
    # chain table: word = {mpc[47:32], stype[31:0]}
    A('  localparam int APU_VN_CHAIN_WORDS = %d;' % len(chain))
    if chain:
        A('  localparam logic [47:0] APU_VN_CHAIN '
          '[0:APU_VN_CHAIN_WORDS-1] = \'{')
        for i, w in enumerate(chain):
            comma = ',' if i < len(chain) - 1 else ''
            if w == 0:
                A("    48'h0%s // terminator" % comma)
            else:
                st = w & 0xFFFFFFFF
                mpc = (w >> 32) & 0xFFFF
                A("    48'h%012X%s // sType=%d mpc=%d" % (w, comma, st,
                                                          mpc))
        A('  };')
    A('')
    A('  localparam int APU_VN_CONST_WORDS = %d;' % len(model.consts))
    arr(32, 'APU_VN_CONST', '[0:APU_VN_CONST_WORDS-1]',
        model.consts, lambda w: "32'h%08X" % w)
    A('')
    A('  localparam int APU_VN_ARRMETA_WORDS = %d;' % len(model.arr_meta))
    arr(24, 'APU_VN_ARRMETA', '[0:APU_VN_ARRMETA_WORDS-1]',
        model.arr_meta, lambda w: "24'h%06X" % w)
    A('')
    A('  localparam int APU_VN_BLOBMETA_WORDS = %d;'
      % len(model.blob_meta))
    arr(32, 'APU_VN_BLOBMETA', '[0:APU_VN_BLOBMETA_WORDS-1]',
        model.blob_meta, lambda w: "32'h%08X" % w)
    A('')
    A('  localparam int APU_VN_PROFILE_WORDS = %d;'
      % len(model.profile_words_pool))
    arr(32, 'APU_VN_PROFILE', '[0:APU_VN_PROFILE_WORDS-1]',
        model.profile_words_pool, lambda w: "32'h%08X" % w)
    A('')
    # decode fault classes and the decoded-operation record
    A('  typedef enum logic [3:0] {')
    A('    APU_VN_FAULT_NONE = 0,')
    A('    APU_VN_FAULT_UNKNOWN_TYPE = 1,')
    A('    APU_VN_FAULT_STYPE = 2,')
    A('    APU_VN_FAULT_PNEXT = 3,')
    A('    APU_VN_FAULT_FLAGS = 4,')
    A('    APU_VN_FAULT_BOUND = 5,')
    A('    APU_VN_FAULT_HANDLE_ZERO = 6,')
    A('    APU_VN_FAULT_LOOP = 7,')
    A('    APU_VN_FAULT_ROM = 8')
    A('  } apu_vn_fault_e;')
    A('')
    A('  typedef enum logic [2:0] {')
    A('    APU_VN_ROLE_LOOKUP = 0,')
    A('    APU_VN_ROLE_NEW = 1,')
    A('    APU_VN_ROLE_RETIRE = 2,')
    A('    APU_VN_ROLE_OPTIONAL = 3')
    A('  } apu_vn_role_e;')
    A('')
    A('  typedef struct packed {')
    A('    logic [15:0] off;')
    A('    logic [16:0] words;')
    A('  } apu_vn_blob_t;')
    A('')
    A('  typedef struct {')
    A('    logic [31:0] cmd_type;')
    A('    logic [31:0] cmd_flags;')
    A('    logic [63:0] q [8];')
    A('    logic [5:0]  qkind [8];')
    A('    logic [2:0]  qrole [8];')
    A('    logic [7:0]  qv;')
    A('    logic [31:0] imm [16];')
    A('    logic [15:0] immv;')
    A('    logic [31:0] cnt [4];')
    A('    apu_vn_blob_t blob [2];')
    A('    logic [7:0]  pres;')
    A('    logic [7:0]  chain [8];')
    A('    logic [3:0]  chain_n;')
    A('    logic [5:0]  obj_kind;')
    A('    logic [7:0]  reply_prog;')
    A('    logic [15:0] words;')
    A('    apu_vn_fault_e fault;')
    A('    logic [15:0] fault_word;')
    A('    logic [31:0] fault_val;')
    A('  } apu_vn_op_t;')
    A('')
    A('endpackage')
    A('')
    return '\n'.join(lines)


def emit_md(model, asm, unfit):
    out = []
    A = out.append
    A('# g6lc_apu_vn_pkg generated tables')
    A('')
    A('Generated by `corev_apu/apu/tools/gen_vn_tables.py` from '
      'specs/venus-protocol `%s` (vk.xml %s).  Do not edit.'
      % (VN_PIN, model.reg.vk_xml_version))
    A('')
    A('Mesa 26.0.8 vendored headers (banner git-307d2d0b, not public) '
      'regenerate identically from this pin except the `types_chain.h` '
      'strict-aliasing cast of upstream 70991d4; wire format identical '
      '(log: `build-platform/workspace/build/apu-vn/pin-validate.log`).')
    A('')
    A('Decode ROM %d words; reply ROM %d words; chain table %d words; '
      'const pool %d words; profile %d words.'
      % (len(asm['dec']), len(asm['rep']), len(asm['chain']),
         len(model.consts), len(model.profile_words_pool)))
    A('')
    A('## Slot map legend')
    A('')
    A('- `q[i]` = u64/handle slot; `imm[i]` = u32 slot; `cnt[i]` = array '
      'count; `pres[i]` = pointer-presence bit; `blob[i]` = {offset,words}; '
      '`0xFF`/q7/pres7 = discard or in-element scratch (executor re-walks '
      'the stream for element data).')
    A('- `RET` ends a chain-body (pNext node) program and returns to the '
      'caller program; `END` ends a command program and selects the reply.')
    A('- `CHECK` reads one word and faults (`STYPE` class) unless it equals '
      'the constant; unions carry a u32 default-tag word checked this way '
      '(Mesa emits `vn_encode_uint32_t(&tag)` before the default member).')
    A('- `PTR` on an in/out scalar (a `var_out` that is also a `var_in` '
      'len-target, e.g. `vkEnumeratePhysicalDevices::pPhysicalDeviceCount`) '
      'is followed by the pointee program; a pure-out scalar is presence '
      'only (`vkEnumerateInstanceVersion::pApiVersion`).')
    A('- `BLOB` on an out blob (`vkGetQueryPoolResults::pData`) has '
      'elem_bytes=0: only the u64 byte count is consumed, no payload.')
    A('')
    A('## `.exp` expected-record format')
    A('')
    A('`verif/tb/apu/vn_vectors/*.exp` is `$readmemh`-able: one 32-bit '
      'hex word per line, **78 words per instance**: a 2-word header '
      '`{cs_base, cs_len}` (word offset of the instance\'s type word in '
      '`.hex`, and its word length) followed by a fixed 76-word '
      '`apu_vn_op_t` record:')
    A('')
    A('| word | field |')
    A('|---|---|')
    A('| 0 | cmd_type |')
    A('| 1 | cmd_flags |')
    A('| 2-17 | q[0..7] (lo,hi) |')
    A('| 18-25 | qkind[0..7] |')
    A('| 26-33 | qrole[0..7] |')
    A('| 34 | qv |')
    A('| 35-50 | imm[0..15] |')
    A('| 51 | immv |')
    A('| 52-55 | cnt[0..3] |')
    A('| 56-59 | blob0.off, blob0.words, blob1.off, blob1.words |')
    A('| 60 | pres |')
    A('| 61-68 | chain[0..7] (APU_VN_CHAIN word index of the matched pair) |')
    A('| 69 | chain_n |')
    A('| 70 | obj_kind |')
    A('| 71 | reply_prog |')
    A('| 72 | words (consumed incl. type+flags) |')
    A('| 73 | fault |')
    A('| 74 | fault_word |')
    A('| 75 | fault_val |')
    A('')
    A('The record stream ends with a 2-word `FFFFFFFF FFFFFFFF` sentinel '
      'in the `cs_base`/`cs_len` slots so a testbench can detect end of '
      'file without knowing the instance count.')
    A('')
    A('Fault enum: 0 NONE, 1 UNKNOWN_TYPE, 2 STYPE, 3 PNEXT, 4 FLAGS, '
      '5 BOUND (incl. truncated stream and count above bound), '
      '6 HANDLE_ZERO, 7 LOOP, 8 ROM.')
    A('')
    A('## Mesa differential harness')
    A('')
    A('`corev_apu/apu/tools/vn_mesa_diff/vn_mesa_diff.py` re-encodes the '
      'same randomized instances with Mesa\'s vendored C encoders and '
      'compares word-for-word against `vn_golden.py`:')
    A('')
    A('```sh')
    A('python corev_apu/apu/tools/vn_mesa_diff/vn_mesa_diff.py \\')
    A('    --mesa-dir build-platform/workspace/build/apu-vn/mesa-vendored \\')
    A('    --vk-include build-platform/workspace/build/apu-vn/vk-include \\')
    A('    --out-dir build-platform/workspace/build/apu-vn/diff \\')
    A('    --seed 1')
    A('```')
    A('')
    A('The harness compiles with WSL `/usr/bin/gcc` (the Windows host has '
      'no C toolchain) against Mesa\'s 37 vendored headers plus the pin\'s '
      '`include/vulkan` + `include/vk_video` headers fetched to scratch '
      '(the submodule sparse checkout is intentionally not widened), '
      'using stub `vn_cs.h`/`vn_ring.h` (ids = handle values, Vulkan 1.1 '
      '+ all extensions advertised).  Result at last run: **480/480 '
      'instances byte-identical** (seeds 1 and 2, 4 instances/command).')
    A('')
    A('## Per-command maps')
    A('')
    for name, info in model.cmd_info.items():
        prog = info['prog']
        mpc = asm['entry_of_cmd'][name]
        A('### %s — type %d, mpc %d..%d, reply %d'
          % (name, info['type_id'], mpc, mpc + len(prog) - 1,
             info['reply_id']))
        A('')
        A('| op | a | b | note |')
        A('|---|---|---|---|')
        for op, a, b, note in prog:
            A('| %s | %s | 0x%X | %s |' % (op, a, b, note))
        A('')
    if unfit:
        A('## Commands that did not fit')
        A('')
        for name, why in unfit.items():
            A('- `%s`: %s' % (name, why))
        A('')
    return '\n'.join(out)


def main():
    profile_path = TOOLS / 'vn_device_profile.toml'
    profile = tomllib.loads(profile_path.read_text(encoding='utf-8'))
    model = Model(profile)
    names = model.read_command_set(TOOLS / 'vn_command_set.txt')
    unfit = model.run(names)
    asm = model.assemble()
    # fix PNEXT/RPTR table operands now that offsets are known
    # (chain tbl indices were stored as list indices; recompute word offsets)
    sv = emit_sv(model, asm, profile)
    out = REPO / 'corev_apu' / 'apu' / 'include' / 'g6lc_apu_vn_pkg.sv'
    out.write_text(sv, encoding='utf-8')
    md = emit_md(model, asm, unfit)
    (TOOLS / 'g6lc_apu_vn_tables.md').write_text(md, encoding='utf-8')
    print('commands: %d, unfit: %d' % (len(model.cmd_progs), len(unfit)))
    for n, why in unfit.items():
        print('  UNFIT %s: %s' % (n, why))
    print('dec ROM %d words, reply ROM %d words, chain %d words, '
          'const %d, profile %d' %
          (len(asm['dec']), len(asm['rep']), len(asm['chain']),
           len(model.consts), len(model.profile_words_pool)))


if __name__ == '__main__':
    main()
