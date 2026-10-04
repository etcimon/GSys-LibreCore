#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""vn_mesa_diff.py — differential test of vn_golden.py against Mesa's C encoders.

Generates the same randomized command instances as vn_golden.py (shared
ArgGen + ArgModel), emits `harness_gen.c` which constructs the exact Vulkan
argument structs and calls Mesa's generated `vn_encode_vk*` functions,
compiles it with gcc (local if found, else WSL /usr/bin/gcc — the Windows
host has no C toolchain), runs it, and compares the encoded wire words with
the golden encoder's words for every instance.

Usage:
    python vn_mesa_diff.py --mesa-dir <mesa-vendored> --vk-include <dir> --seed 1

Dumps `instances.json` (concrete argument values incl. null pointers, array
lengths, strings, handle ids, pNext chains), `harness_gen.c`, `harness.hex`
(Mesa's output) and `diff.log` into --out-dir.
"""

import argparse
import json
import random
import re
import shutil
import struct
import subprocess
import sys
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import gen_vn_tables as G  # noqa: E402
import vn_golden as V  # noqa: E402
import vkxml  # noqa: E402
import vn_protocol  # noqa: E402  (path added by gen_vn_tables)

REPO = G.REPO


APU_TOOLS = HERE.parent


def load_model():
    profile = tomllib.loads(
        (APU_TOOLS / 'vn_device_profile.toml').read_text(encoding='utf-8'))
    model = G.Model(profile)
    names = model.read_command_set(APU_TOOLS / 'vn_command_set.txt')
    unfit = model.run(names)
    if unfit:
        print('unfit commands:', unfit, file=sys.stderr)
    model, asm = V.build_assembly(model)
    model._asm = asm
    enc = V.Enc(model)
    commands = {t.name: t for t in
                model.gen.supported_types[vkxml.VkType.COMMAND]}
    types = {t.name: t
             for cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION,
                         vkxml.VkType.COMMAND)
             for t in model.gen.supported_types[cat]}
    return model, enc, types, commands, names


def gen_instances(seed, per_cmd, command_set, commands, model, enc):
    rng = random.Random(seed)
    insts = []
    for name in command_set:
        ty = commands[name]
        for i in range(per_cmd):
            gen = V.ArgGen(model, rng)
            args = gen.gen_command(name)
            words = enc.command(ty, args)
            insts.append({'cmd': name, 'i': i, 'targs': args,
                          'jargs': V.to_jsonable(args),
                          'words': ['%08x' % w for w in words],
                          'seg': list(enc.seg)})
    return insts


def cstr(s):
    return '"%s"' % s.replace('\\', '\\\\').replace('"', '\\"')


class CEmit:
    """Emit C declarations + initializers for one command instance."""

    def __init__(self, model, types):
        self.m = model
        self.types = types
        self.decls = []
        self.n = 0
        self.writable = False   # reply-decode: out args must be non-const
        self.cmdvars = {}

    def _const(self, cond):
        return '' if self.writable else ('const ' if cond else '')

    def fresh(self, hint):
        self.n += 1
        return 'v_%s_%d' % (hint, self.n)

    def scalar_lit(self, base, val):
        name = base.name
        cat = base.category
        val = 0 if val is None else val
        if cat == vkxml.VkType.HANDLE:
            return '(%s)(uintptr_t)0x%Xull' % (name, val & 0xFFFFFFFFFFFFFFFF)
        if cat in (vkxml.VkType.ENUM, vkxml.VkType.BITMASK):
            return '(%s)0x%Xu' % (name, val & 0xFFFFFFFF)
        if name == 'float':
            bits = val if isinstance(val, int) else \
                struct.unpack('<I', struct.pack('<f', val))[0]
            return '((union{uint32_t u;float f;}){.u=0x%08Xu}).f' % bits
        if name == 'double':
            bits = val if isinstance(val, int) else \
                struct.unpack('<Q', struct.pack('<d', val))[0]
            return '((union{uint64_t u;double f;}){.u=0x%08Xull}).f' % bits
        if self.m.scalar_bytes(base) == 8:
            return '0x%Xull' % (val & 0xFFFFFFFFFFFFFFFF)
        return '0x%Xu' % (val & 0xFFFFFFFF)

    def array_einit(self, var, e):
        """Initializer for one element of a dynamic/static array."""
        base = var.ty.base
        cat = base.category
        if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
            return self.struct_init(base, e)
        if base.name == 'char' and isinstance(e, int):
            return '%d' % e
        return self.scalar_lit(base, e)

    def dyn_array(self, var, elems):
        """Declare a static array var for a pointer/array param or member;
        returns the var name (a pointer-compatible expression) or 'NULL'."""
        if elems is None or len(elems) == 0:
            return 'NULL'
        base = var.ty.base
        if var.is_blob():
            const = self._const(var.ty.is_const_pointer())
            name = self.fresh('blob')
            self.decls.append('%suint8_t %s[%d] = {%s};'
                              % (const, name, len(elems),
                                 ','.join('0x%02X' % (b & 0xFF)
                                          for b in elems)))
            return name
        if var.ty.indirection_depth() >= 2:
            # const char* const * — array of C strings
            name = self.fresh('strs')
            self.decls.append('const char *%s[%d] = {%s};'
                              % (name, len(elems),
                                 ','.join(cstr(s) for s in elems)))
            return name
        if var.has_c_string():
            return cstr(elems if isinstance(elems, str)
                        else bytes(elems).decode())
        const = self._const(var.ty.is_const_pointer())
        if isinstance(elems, str):
            elems = list(elems.encode())
        name = self.fresh('arr')
        inits = ','.join(self.array_einit(var, e) for e in elems)
        self.decls.append('%s%s %s[%d] = {%s};'
                          % (const, base.name, name, len(elems), inits))
        return name

    def chain_init(self, chain):
        """Emit pNext node decls (in stream order); returns 'NULL' or '&node0'."""
        if not chain:
            return 'NULL'
        names = [self.fresh('pn') for _ in chain]
        for i in reversed(range(len(chain))):
            node = chain[i]
            ty = node['_ty'] if isinstance(node.get('_ty'), vkxml.VkType) \
                else self.types[node['_ty']]
            parts = ['.sType=%s' % node.get('sType', ty.s_type)]
            nxt = ('&%s' % names[i + 1]) if i + 1 < len(chain) else 'NULL'
            parts.append('.pNext=(const void*)%s' % nxt)
            for var in ty.variables:
                if var.name in ('sType', 'pNext'):
                    continue
                parts.append('.%s=%s'
                             % (var.name,
                                self.member_init(ty, var, node.get(var.name))))
            self.decls.append('%s%s %s = {%s};'
                              % (self._const(True), ty.name, names[i],
                                 ','.join(parts)))
        return '&%s' % names[0]

    def member_init(self, parent_ty, var, val):
        """Initializer expression for a struct member (inside braces)."""
        base = var.ty.base
        cat = base.category
        if var.ty.is_static_array():
            if isinstance(val, str):
                if base.name == 'char':
                    return cstr(val)
                val = list(val.encode())
            return '{%s}' % ','.join(
                self.array_einit(var, e) for e in (val or []))
        if var.is_dynamic_array() or var.is_blob():
            return self.dyn_array(var, val)
        if var.ty.is_pointer():
            if val is None or not self.m.gen.is_serializable(base):
                return 'NULL'
            const = self._const(var.ty.is_const_pointer())
            name = self.fresh('p')
            if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
                self.decls.append('%s%s %s = %s;'
                                  % (const, base.name, name,
                                     self.struct_init(base, val)))
            else:
                self.decls.append('%s%s %s = %s;'
                                  % (const, base.name, name,
                                     self.scalar_lit(base, val)))
            return '&%s' % name
        if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
            return self.struct_init(base, val)
        return self.scalar_lit(base, val)

    def struct_init(self, ty, obj):
        obj = obj or {}
        if ty.category == vkxml.VkType.UNION:
            tag = vn_protocol.Gen.UNION_DEFAULT_TAGS[ty.name]
            var = ty.variables[tag]
            return '{.%s=%s}' % (var.name,
                                 self.member_init(ty, var, obj.get(var.name)))
        parts = []
        for var in ty.variables:
            if var.name == 'sType':
                if ty.s_type:
                    parts.append('.sType=%s' % obj.get('sType', ty.s_type))
                continue
            if var.name == 'pNext':
                parts.append('.pNext=(const void*)%s'
                             % self.chain_init(obj.get('pNext')))
                continue
            parts.append('.%s=%s'
                         % (var.name,
                            self.member_init(ty, var, obj.get(var.name))))
        return '{%s}' % ','.join(parts)

    def command_call(self, ty, args):
        """Returns (decls, call_stmt) for vn_encode_<cmd>."""
        self.decls = []
        arg_exprs = []
        for var in ty.variables:
            val = args.get(var.name)
            if var.ty.is_pointer():
                expr = self.dyn_array(var, val) \
                    if (var.is_dynamic_array() or var.is_blob()) \
                    else self.ptr_arg(var, val)
            else:
                expr = self.member_init(ty, var, val)
            arg_exprs.append(expr)
        call = 'vn_encode_%s(&enc, (VkCommandFlagsEXT)0%s%s);' \
            % (ty.name, ', ' if arg_exprs else '', ', '.join(arg_exprs))
        return list(self.decls), call

    def ptr_arg(self, var, val):
        """Initializer for a non-dynamic pointer command argument."""
        base = var.ty.base
        cat = base.category
        if val is None or not self.m.gen.is_serializable(base):
            return 'NULL'
        if var.has_c_string():
            return cstr(val if isinstance(val, str) else bytes(val).decode())
        const = self._const(var.ty.is_const_pointer())
        name = self.fresh('p')
        if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
            self.decls.append('%s%s %s = %s;'
                              % (const, base.name, name,
                                 self.struct_init(base, val)))
        elif cat == vkxml.VkType.HANDLE:
            self.decls.append('%s%s %s = %s;'
                              % (const, base.name, name,
                                 self.scalar_lit(base, val)))
        else:
            self.decls.append('%s%s %s = %s;'
                              % (const, base.name, name,
                                 self.scalar_lit(base, val)))
        return '&%s' % name

    # ---- reply decode/re-encode (vn_decode_vkX_reply) -----------------------

    def command_reply_call(self, ty, args):
        """Decls + the vn_decode_<cmd>_reply call."""
        self.decls = []
        self.arg_expr = {}
        arg_exprs = []
        for var in ty.variables:
            val = args.get(var.name)
            if var.ty.is_pointer():
                expr = self.dyn_array(var, val) \
                    if (var.is_dynamic_array() or var.is_blob()) \
                    else self.ptr_arg(var, val)
            else:
                expr = self.member_init(ty, var, val)
            self.arg_expr[var.name] = expr
            arg_exprs.append(expr)
        if ty.ret:
            call = 'VkResult ret = vn_decode_%s_reply(&dec%s%s);' \
                % (ty.name, ', ' if arg_exprs else '',
                   ', '.join(arg_exprs))
        else:
            call = 'vn_decode_%s_reply(&dec%s%s); ' \
                   'VkResult ret = VK_SUCCESS;' \
                % (ty.name, ', ' if arg_exprs else '',
                   ', '.join(arg_exprs))
        return list(self.decls), call

    def len_expr(self, var):
        """C expr for the element count of an out array member."""
        e = var.attrs['len_names'][0]
        if '->' in e:
            head, rest = e.split('->', 1)
            he = self.arg_expr.get(head, head)
            return '0' if he == 'NULL' else '(%s)->%s' % (he, rest)
        v = self.cmdvars.get(e)
        if v is not None and v.ty.is_pointer():
            x = self.arg_expr.get(e, e)
            return '0' if x == 'NULL' else '(%s ? *%s : 0)' % (x, x)
        return self.arg_expr.get(e, e)

    def reenc_member(self, var, m, out, depth):
        """Re-encode one member value; m is a C lvalue for it."""
        base = var.ty.base
        cat = base.category
        if var.ty.is_static_array():
            dim = str(var.ty.static_array_size())
            out.append('vn_encode_array_size(&enc2, %s);' % dim)
            if cat in (vkxml.VkType.STRUCT, vkxml.VkType.UNION):
                out.append('for (uint32_t _i = 0; _i < (%s); _i++) {'
                           % dim)
                if cat == vkxml.VkType.UNION:
                    self.reenc_union(base, '(&(%s)[_i])' % m, out,
                                     depth + 1)
                else:
                    self.reenc_members(base, '(&(%s)[_i])' % m, out,
                                       depth + 1)
                out.append('}')
            elif base.name == 'char':
                out.append('vn_encode_char_array(&enc2, %s, %s);'
                           % (m, dim))
            elif base.name == 'uint8_t':
                out.append('vn_encode_uint8_t_array(&enc2, %s, %s);'
                           % (m, dim))
            else:
                en = 'VkFlags' if cat == vkxml.VkType.BITMASK \
                    else base.name
                out.append('for (uint32_t _i = 0; _i < (%s); _i++) '
                           'vn_encode_%s(&enc2, &(%s)[_i]);'
                           % (dim, en, m))
        elif cat == vkxml.VkType.UNION:
            self.reenc_union(base, '(&(%s))' % m, out, depth + 1)
        elif cat == vkxml.VkType.STRUCT:
            self.reenc_members(base, '(&(%s))' % m, out, depth + 1)
        else:
            en = 'VkFlags' if cat == vkxml.VkType.BITMASK \
                else base.name
            out.append('vn_encode_%s(&enc2, &(%s));' % (en, m))

    def reenc_union(self, base, xa, out, depth):
        tag = vn_protocol.Gen.UNION_DEFAULT_TAGS.get(base.name)
        if tag is None:
            n = self.m.struct_words(base) or 0
            out.append('vn_encode_blob_array(&enc2, %s, %d);'
                       % (xa, n * 4))
            return
        out.append('vn_encode_uint32_t(&enc2, &(const uint32_t){%d});'
                   % tag)
        self.reenc_member(base.variables[tag],
                          '(%s)->%s' % (xa, base.variables[tag].name),
                          out, depth)

    def reenc_members(self, ty, xa, out, depth=0):
        """Member-level re-encode mirroring vn_decode_<ty> member order;
        sType/pNext are handled by the caller (chain structure)."""
        for var in ty.variables:
            if var.name in ('sType', 'pNext'):
                continue
            self.reenc_member(var, '(%s)->%s' % (xa, var.name), out,
                              depth)

    def reenc_outstruct(self, base, x, out, depth):
        """Re-encode a decoded out-struct: sType + flat pNext chain
        (headers forward, bodies in reverse, matching Mesa's
        vn_encode_<ty>_pnext_partial order) + member body."""
        if base.s_type:
            out.append('vn_encode_VkStructureType(&enc2, '
                       '&(%s)->sType);' % x)
        if base.s_type and any(v.is_p_next() for v in base.variables):
            cands = [nty for nty in base.p_next
                     if self.m.gen.is_serializable(nty)
                     and self.m.core_le_11(nty)
                     and nty.s_type in self.m.stype_values]
            out.append('{ const VkBaseOutStructure *_pns[16]; '
                       'uint32_t _pnn = 0;')
            out.append('for (const VkBaseOutStructure *_p = '
                       '(const void *)(%s)->pNext; _p && _pnn < 16; '
                       '_p = _p->pNext) _pns[_pnn++] = _p;' % x)
            out.append('for (uint32_t _i = 0; _i < _pnn; _i++) { '
                       'vn_encode_simple_pointer(&enc2, _pns[_i]); '
                       'vn_encode_VkStructureType(&enc2, '
                       '&_pns[_i]->sType); }')
            out.append('vn_encode_simple_pointer(&enc2, NULL);')
            out.append('while (_pnn--) switch '
                       '((int32_t)_pns[_pnn]->sType) {')
            for nty in cands:
                st = self.m.stype_values[nty.s_type]
                out.append('case %d: { const %s *_q = '
                           '(const %s *)(const void *)_pns[_pnn];'
                           % (st, nty.name, nty.name))
                self.reenc_members(nty, '_q', out, depth + 1)
                out.append('} break;')
            out.append('default: break; } }')
        self.reenc_members(base, x, out, depth)

    def reply_reenc(self, ty):
        """C lines re-encoding every decoded out param, mirroring the
        reply layout (presence word + body / array_size + elements)."""
        out = []
        for var in ty.variables:
            if 'var_out' not in var.attrs:
                continue
            n = self.arg_expr[var.name]
            base = var.ty.base
            if var.is_blob():
                cnt = self.len_expr(var)
                out.append('vn_encode_array_size(&enc2, %s ? '
                           '(size_t)(%s) : 0);' % (n, cnt))
                out.append('if (%s) vn_encode_blob_array(&enc2, %s, %s);'
                           % (n, n, cnt))
            elif var.is_dynamic_array():
                cnt = self.len_expr(var)
                if n == 'NULL':
                    out.append('vn_encode_array_size(&enc2, 0);')
                    continue
                out.append('vn_encode_array_size(&enc2, %s ? '
                           '(size_t)(%s) : 0);' % (n, cnt))
                if base.category in (vkxml.VkType.STRUCT,
                                     vkxml.VkType.UNION):
                    out.append('if (%s) for (uint32_t _i = 0; _i < (%s); '
                               '_i++) {' % (n, cnt))
                    if base.category == vkxml.VkType.UNION:
                        self.reenc_union(base, '(&(%s)[_i])' % n, out, 0)
                    else:
                        self.reenc_outstruct(base, '(&(%s)[_i])' % n,
                                             out, 0)
                    out.append('}')
                else:
                    en = 'VkFlags' if base.category == \
                        vkxml.VkType.BITMASK else base.name
                    out.append('if (%s) for (uint32_t _i = 0; _i < '
                               '(%s); _i++) vn_encode_%s(&enc2, '
                               '&(%s)[_i]);' % (n, cnt, en, n))
            else:
                if base.category == vkxml.VkType.STRUCT:
                    if n == 'NULL':
                        out.append('vn_encode_simple_pointer(&enc2, '
                                   'NULL);')
                        continue
                    out.append('if (vn_encode_simple_pointer(&enc2, '
                               '%s)) {' % n)
                    self.reenc_outstruct(base, n, out, 0)
                    out.append('}')
                elif base.category == vkxml.VkType.UNION:
                    if n == 'NULL':
                        out.append('vn_encode_simple_pointer(&enc2, '
                                   'NULL);')
                        continue
                    out.append('if (vn_encode_simple_pointer(&enc2, '
                               '%s)) {' % n)
                    self.reenc_union(base, n, out, 0)
                    out.append('}')
                else:
                    out.append('if (vn_encode_simple_pointer(&enc2, '
                               '%s)) vn_encode_%s(&enc2, %s);'
                               % (n, base.name, n))
        return out


PREAMBLE = '''\
/* Generated by vn_mesa_diff.py. */
#include <stdio.h>
#include <string.h>
#include "vn_cs.h"
#include "vn_ring.h"
#include "vn_protocol_driver.h"

static void
dump(struct vn_cs_encoder *enc, const char *cmd, int i)
{
   size_t k;
   printf("// %s %d\\n", cmd, i);
   for (k = 0; k + 4 <= enc->len; k += 4) {
      uint32_t w;
      memcpy(&w, enc->buf + k, 4);
      printf("%08X\\n", w);
   }
   if (enc->len % 4)
      printf("// misaligned %zu\\n", enc->len);
   printf("// end\\n");
}

int
main(void)
{
   static uint8_t buf[8u << 20];
   struct vn_cs_encoder enc;
'''


def emit_harness(insts, commands, model, types):
    lines = [PREAMBLE]
    for inst in insts:
        name = inst['cmd']
        ty = commands[name]
        em = CEmit(model, types)
        decls, call = em.command_call(ty, inst['targs'])
        lines.append('   {\n')
        for d in decls:
            lines.append('      %s\n' % d)
        lines.append('      enc.buf = buf; enc.len = 0; enc.cap = sizeof(buf);\n')
        lines.append('      %s\n' % call)
        lines.append('      dump(&enc, "%s", %d);\n' % (name, inst['i']))
        lines.append('   }\n')
    lines.append('   return 0;\n}\n')
    return ''.join(lines)


REPLY_PREAMBLE = '''\
/* Generated by vn_mesa_diff.py --reply. */
#include <stdio.h>
#include <string.h>
#include "vn_cs.h"
#include "vn_ring.h"
#include "vn_protocol_driver.h"

uint64_t vn_hid_log[256];
uint32_t vn_hid_log_n;

static void
dump(struct vn_cs_encoder *enc, const char *cmd, int i)
{
   size_t k;
   printf("// %s %d\\n", cmd, i);
   for (k = 0; k + 4 <= enc->len; k += 4) {
      uint32_t w;
      memcpy(&w, enc->buf + k, 4);
      printf("%08X\\n", w);
   }
   printf("// end\\n");
}

int
main(void)
{
   static uint8_t buf[8u << 20];
   struct vn_cs_encoder enc2;
   struct vn_cs_decoder dec;
'''


def emit_reply_harness(insts, commands, model, types):
    lines = [REPLY_PREAMBLE]
    for inst in insts:
        name = inst['cmd']
        ty = commands[name]
        em = CEmit(model, types)
        em.writable = True
        em.cmdvars = {v.name: v for v in ty.variables}
        decls, call = em.command_reply_call(ty, inst['targs'])
        rep = inst['rep']
        lines.append('   {\n')
        for d in decls:
            lines.append('      %s\n' % d)
        lines.append('      static const uint32_t rep[] = {%s};\n'
                     % ','.join('0x%08Xu' % w for w in rep))
        lines.append('      dec.buf = (const uint8_t *)rep; '
                     'dec.len = sizeof(rep); dec.pos = 0; '
                     'dec.fatal = false;\n')
        lines.append('      vn_hid_log_n = 0;\n')
        lines.append('      enc2.buf = buf; enc2.len = 0; '
                     'enc2.cap = sizeof(buf);\n')
        lines.append('      %s\n' % call)
        lines.append('      printf("R %%s %%d %%08X %%d %%d\\n", "%s", '
                     '%d, (uint32_t)ret, (int)dec.pos, '
                     'dec.fatal ? 1 : 0);\n' % (name, inst['i']))
        for line in em.reply_reenc(ty):
            lines.append('      %s\n' % line)
        lines.append('      dump(&enc2, "%s", %d);\n'
                     % (name, inst['i']))
        lines.append('   }\n')
    lines.append('   return 0;\n}\n')
    return ''.join(lines)


def parse_reply_output(text):
    """-> list of {'cmd','i','ret','pos','fatal','words'}."""
    insts = []
    cur = None
    pending = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('R '):
            p = line.split()
            pending = {'cmd': p[1], 'i': int(p[2]),
                       'ret': int(p[3], 16), 'pos': int(p[4]),
                       'fatal': int(p[5])}
        elif line.startswith('// '):
            parts = line[3:].split()
            if parts and parts[0] == 'end':
                if cur:
                    insts.append(cur)
                    cur = None
            elif pending is not None:
                cur = dict(pending)
                cur['words'] = []
                pending = None
        elif re.fullmatch(r'[0-9a-fA-F]{8}', line) and cur is not None:
            cur['words'].append(int(line, 16))
    return insts


def reply_diff(a, model, enc, types, commands, mesa_dir, vk_dir):
    """Decode golden reply streams with Mesa's vn_decode_vkX_reply and
    re-encode the decoded out params; compare with the golden bytes."""
    asm = model._asm
    sim = V.Sim(model, asm)
    rep_sim = V.ReplySim(model, asm)
    if a.session:
        # Mesa-decode the generated session's golden replies: rebuild the
        # session with the same seed and feed its replying instances to
        # the reply harness below.
        rng = random.Random(int(a.session[1]))
        gen = V.ArgGen(model, rng)
        cmds, _fm = V.build_session(model, asm, sim, rep_sim, enc, gen,
                                    rng)
        insts = []
        for c in cmds:
            out = c['out']
            if out['rep']:
                insts.append({'cmd': c['name'], 'i': len(insts),
                              'targs': c['args'], 'rep': out['rep'],
                              'result': out['result'], 'ty': c['ty'],
                              'exec_w': []})
        print('session %s: %d commands, %d replying'
              % (a.session[0], len(cmds), len(insts)))
    else:
        rng = random.Random(a.seed)
        insts = []
        for cmd in model.cmd_progs:
            info = model.cmd_info[cmd]
            if not info['reply_id']:
                continue
            ty = commands[cmd]
            for i in range(a.per_cmd):
                g = V.ArgGen(model, rng)
                args = g.gen_command(cmd)
                args['_flags'] = 1   # VK_COMMAND_GENERATE_REPLY_BIT_EXT
                if i == 1:
                    # NULL-out arm: only params vk.xml marks optional at
                    # the top pointer level may legally be NULL; forcing
                    # a required out NULL produces an invalid call Mesa's
                    # decoder handles differently (expected array_size 0)
                    ov = next((v.name for v in ty.variables
                               if 'var_out' in v.attrs
                               and (v.attrs.get('optional') or ['false'])[0]
                               == 'true'), None)
                    if ov:
                        args[ov] = None
                if cmd == 'vkGetQueryPoolResults':
                    args['dataSize'] = rng.randint(0, 16)
                    args['pData'] = rng.randbytes(args['dataSize'])
                words = enc.command(ty, args)
                rec = sim.run(words)
                if rec['fault']:
                    continue
                result = rng.getrandbits(32)
                exec_w, rep = V.gen_reply_exec(
                    model, asm, rep_sim, cmd, ty, words, rec, result, rng)
                insts.append({'cmd': cmd, 'i': i, 'targs': args,
                              'rep': rep, 'result': result, 'ty': ty,
                              'exec_w': exec_w})
    print('reply instances: %d' % len(insts))

    c_text = emit_reply_harness(insts, commands, model, types)
    c_path = a.out_dir / 'harness_reply_gen.c'
    c_path.write_text(c_text)
    print('wrote %s (%d lines)' % (c_path, c_text.count('\n')))

    mode, gcc = find_gcc()
    if not gcc:
        print('FATAL: no gcc (local PATH or WSL) found')
        return 2
    print('gcc: %s (%s)' % (gcc, mode))
    exe_path = a.out_dir / ('harness_reply.exe'
                            if mode == 'local' else 'harness_reply')
    r = compile_harness(mode, gcc, c_path, exe_path, mesa_dir, vk_dir,
                        HERE)
    (a.out_dir / 'compile_reply.log').write_text(r.stdout + r.stderr)
    if r.returncode != 0:
        print('COMPILE FAILED — see %s' % (a.out_dir / 'compile_reply.log'))
        print((r.stdout + r.stderr)[-4000:])
        return 2
    r = run_harness(mode, exe_path)
    (a.out_dir / 'harness_reply.hex').write_text(r.stdout)
    if r.returncode != 0:
        print('HARNESS RUN FAILED rc=%d' % r.returncode)
        print(r.stderr[-2000:])
        print(r.stdout[-2000:])
        return 2
    mesa_insts = parse_reply_output(r.stdout)
    print('mesa reply instances parsed: %d' % len(mesa_insts))

    per_cmd = {}
    fails = []
    for gi, mi in zip(insts, mesa_insts):
        name = gi['cmd']
        per_cmd.setdefault(name, [0, 0])
        ty = gi['ty']
        prefix = 1 + (1 if ty.ret else 0)
        exp = gi['rep'][prefix:]
        prob = []
        if mi['cmd'] != name or mi['i'] != gi['i']:
            prob.append('order')
        if ty.ret and mi['ret'] != gi['result']:
            prob.append('ret %08X!=%08X' % (mi['ret'], gi['result']))
        if mi['pos'] != len(gi['rep']) * 4:
            prob.append('pos %d!=%d' % (mi['pos'], len(gi['rep']) * 4))
        if mi['fatal']:
            prob.append('fatal')
        if mi['words'] != exp:
            k = next((k for k in range(max(len(exp), len(mi['words'])))
                      if k >= len(exp) or k >= len(mi['words'])
                      or exp[k] != mi['words'][k]), -1)
            prob.append('reenc word %d golden=%s mesa=%s'
                        % (k,
                           '%08X' % exp[k] if k < len(exp) else '-',
                           '%08X' % mi['words'][k]
                           if k < len(mi['words']) else '-'))
        if prob:
            per_cmd[name][1] += 1
            fails.append((name, gi['i'], prob))
        else:
            per_cmd[name][0] += 1
    npass = sum(v[0] for v in per_cmd.values())
    nfail = sum(v[1] for v in per_cmd.values())
    for name in sorted(per_cmd):
        p, f = per_cmd[name]
        if f:
            print('FAIL %s %d/%d' % (name, p, p + f))
    for name, i, prob in fails[:20]:
        print('  %s #%d: %s' % (name, i, '; '.join(prob)))
    print('reply differential: %d pass, %d fail of %d'
          % (npass, nfail, npass + nfail))
    (a.out_dir / 'reply_diff.log').write_text(
        '\n'.join('%s #%d: %s' % (n, i, '; '.join(p))
                  for n, i, p in fails) + '\n')
    return 1 if nfail else 0


def wsl_path(p):
    p = str(p).replace('\\', '/')
    if len(p) > 1 and p[1] == ':':
        return '/mnt/%s/%s' % (p[0].lower(), p[2:].lstrip('/'))
    return p


def find_gcc():
    gcc = shutil.which('gcc')
    if gcc:
        return ('local', gcc)
    try:
        out = subprocess.run(['wsl', '-e', 'bash', '-lc', 'command -v gcc'],
                             capture_output=True, text=True, timeout=30)
        if out.returncode == 0 and out.stdout.strip():
            return ('wsl', out.stdout.strip().split('\n')[-1])
    except (FileNotFoundError, subprocess.SubprocessError):
        pass
    return (None, None)


def compile_harness(mode, gcc, c_path, exe_path, mesa_dir, vk_dir, stub_dir):
    includes = [stub_dir, mesa_dir, vk_dir]
    args = ['-O0', '-std=c11', '-fmax-errors=80', '-Wno-unused',
            '-Wno-unused-variable', '-Wno-unused-but-set-variable']
    args += ['-I%s' % i for i in includes]
    if mode == 'local':
        cmd = [gcc] + args + [str(c_path), '-o', str(exe_path)]
    else:
        cmd = ['wsl', '-e', gcc] + \
            [a if not a.startswith('-I') else '-I' + wsl_path(a[2:])
             for a in args] + \
            [wsl_path(c_path), '-o', wsl_path(exe_path)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    return r


def run_harness(mode, exe_path):
    if mode == 'local':
        cmd = [str(exe_path)]
    else:
        cmd = ['wsl', '-e', wsl_path(exe_path)]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=600)


def parse_mesa_output(text):
    """-> list of {'cmd','i','words'} preserving order."""
    insts = []
    cur = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('// '):
            parts = line[3:].split()
            if parts and parts[0] == 'end':
                if cur:
                    insts.append(cur)
                    cur = None
            elif len(parts) >= 2 and parts[-1].isdigit():
                cur = {'cmd': parts[0], 'i': int(parts[1]), 'words': []}
            else:
                if cur is not None:
                    cur.setdefault('notes', []).append(line)
        elif re.fullmatch(r'[0-9a-fA-F]{8}', line) and cur is not None:
            cur['words'].append(line.lower())
    return insts


def seg_owner(inst, word_idx):
    """Name the member that produced word `word_idx`: the last seg entry
    whose start word is <= word_idx."""
    owner = '(header)'
    for start, path in inst['seg']:
        if start <= word_idx:
            owner = path
        else:
            break
    return owner


def mesa_line_for(mesa_dir, cmd, seg_name):
    """Best-effort: find the generated-header line responsible for the
    diverging member, for the report."""
    leaf = seg_name.split('.')[-1]
    leaf = re.sub(r'\[\d+\]', '', leaf)
    leaf = re.sub(r'^[a-zA-Z]+(?=[A-Z])', '', leaf) or leaf
    hdr = mesa_dir / 'vn_protocol_driver.h'
    cands = sorted(mesa_dir.glob('vn_protocol_driver*.h'),
                   key=lambda p: (p.name != 'vn_protocol_driver.h', p.name))
    enc_sig = 'vn_encode_%s(' % cmd
    for p in cands:
        try:
            lines = p.read_text(errors='replace').splitlines()
        except OSError:
            continue
        in_cmd = False
        for n, l in enumerate(lines, 1):
            if enc_sig in l and 'inline void' in l:
                in_cmd = True
            elif in_cmd and 'inline void' in l:
                in_cmd = False
            if in_cmd and (leaf in l):
                return '%s:%d: %s' % (p.name, n, l.strip())
    # fallback: pointee type
    tyname = None
    m = re.search(r'([A-Z][A-Za-z0-9_]+)$', seg_name)
    if m:
        tyname = m.group(1)
    for p in cands:
        try:
            lines = p.read_text(errors='replace').splitlines()
        except OSError:
            continue
        in_cmd = False
        for n, l in enumerate(lines, 1):
            if enc_sig in l and 'inline void' in l:
                in_cmd = True
            elif in_cmd and 'inline void' in l:
                in_cmd = False
            if in_cmd and tyname and tyname in l:
                return '%s:%d: %s' % (p.name, n, l.strip())
    return '(not located)'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mesa-dir', type=Path, required=True)
    ap.add_argument('--vk-include', type=Path, required=True)
    ap.add_argument('--out-dir', type=Path, required=True)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--per-cmd', type=int, default=4)
    ap.add_argument('--command-set', type=Path, default=None)
    ap.add_argument('--keep-exe', action='store_true')
    ap.add_argument('--reply', action='store_true',
                    help='reply differential: Mesa vn_decode_vkX_reply '
                         'on golden reply bytes + re-encode compare')
    ap.add_argument('--session', nargs=2, metavar=('NAME', 'SEED'),
                    help='with --reply: decode the generated session\'s '
                         'replies instead of random instances')
    a = ap.parse_args()

    a.out_dir.mkdir(parents=True, exist_ok=True)
    mesa_dir = a.mesa_dir.resolve()
    vk_dir = a.vk_include.resolve()

    model, enc, types, commands, command_set = load_model()
    if a.command_set:
        command_set = model.read_command_set(a.command_set)

    if a.reply:
        return reply_diff(a, model, enc, types, commands, mesa_dir,
                          vk_dir)

    print('commands: %d, instances: %d'
          % (len(command_set), len(command_set) * a.per_cmd))
    insts = gen_instances(a.seed, a.per_cmd, command_set, commands, model, enc)

    jpath = a.out_dir / 'instances.json'
    jinsts = [{'cmd': i['cmd'], 'i': i['i'], 'args': i['jargs'],
               'words': i['words']} for i in insts]
    jpath.write_text(json.dumps({'seed': a.seed, 'instances': jinsts},
                                indent=1))
    print('wrote %s' % jpath)

    c_text = emit_harness(insts, commands, model, types)
    c_path = a.out_dir / 'harness_gen.c'
    c_path.write_text(c_text)
    print('wrote %s (%d lines)' % (c_path, c_text.count('\n')))

    mode, gcc = find_gcc()
    if not gcc:
        print('FATAL: no gcc (local PATH or WSL) found')
        return 2
    print('gcc: %s (%s)' % (gcc, mode))

    exe_path = a.out_dir / ('harness.exe' if mode == 'local' else 'harness')
    r = compile_harness(mode, gcc, c_path, exe_path, mesa_dir, vk_dir, HERE)
    (a.out_dir / 'compile.log').write_text(r.stdout + r.stderr)
    if r.returncode != 0:
        print('COMPILE FAILED — see %s' % (a.out_dir / 'compile.log'))
        print((r.stdout + r.stderr)[-4000:])
        return 2
    print('compiled %s' % exe_path)

    r = run_harness(mode, exe_path)
    (a.out_dir / 'harness.hex').write_text(r.stdout)
    if r.returncode != 0:
        print('HARNESS RUN FAILED rc=%d' % r.returncode)
        print(r.stderr[-2000:])
        return 2

    mesa_insts = parse_mesa_output(r.stdout)
    print('mesa instances parsed: %d' % len(mesa_insts))

    log = []
    per_cmd = {}
    fails = []
    if len(mesa_insts) != len(insts):
        log.append('FATAL: instance count mismatch: golden %d mesa %d'
                   % (len(insts), len(mesa_insts)))
    for gi, mi in zip(insts, mesa_insts):
        name = gi['cmd']
        per_cmd.setdefault(name, [0, 0])
        gw, mw = gi['words'], mi['words']
        if gw == mw and gi['cmd'] == mi['cmd'] and gi['i'] == mi['i']:
            per_cmd[name][0] += 1
            continue
        per_cmd[name][1] += 1
        k = next((k for k in range(max(len(gw), len(mw)))
                  if k >= len(gw) or k >= len(mw) or gw[k] != mw[k]), -1)
        seg = seg_owner(gi, k)
        g = gw[k] if k < len(gw) else '<missing>'
        m = mw[k] if k < len(mw) else '<missing>'
        line = mesa_line_for(mesa_dir, name, seg)
        fails.append((name, gi['i'], k, g, m, seg, line))
        log.append('FAIL %s #%d word %d: golden=%s mesa=%s member=%s\n'
                   '     mesa: %s' % (name, gi['i'], k, g, m, seg, line))

    npass = sum(v[0] for v in per_cmd.values())
    nfail = sum(v[1] for v in per_cmd.values())
    bad_cmds = [c for c, v in per_cmd.items() if v[1]]
    log.append('')
    for c in command_set:
        v = per_cmd.get(c, [0, 0])
        log.append('%-50s %s %d/%d'
                   % (c, 'PASS' if not v[1] else 'FAIL', v[0], v[0] + v[1]))
    log.append('')
    log.append('total: %d pass, %d fail; commands failing: %s'
               % (npass, nfail, ', '.join(bad_cmds) or 'none'))
    (a.out_dir / 'diff.log').write_text('\n'.join(log) + '\n')
    print('\n'.join(log[-len(command_set) - 4:]))
    return 1 if nfail else 0


if __name__ == '__main__':
    sys.exit(main())
