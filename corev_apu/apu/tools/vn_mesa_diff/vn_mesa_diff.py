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
            const = 'const ' if var.ty.is_const_pointer() else ''
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
        const = 'const ' if var.ty.is_const_pointer() else ''
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
            self.decls.append('const %s %s = {%s};'
                              % (ty.name, names[i], ','.join(parts)))
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
            const = 'const ' if var.ty.is_const_pointer() else ''
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
        const = 'const ' if var.ty.is_const_pointer() else ''
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
    a = ap.parse_args()

    a.out_dir.mkdir(parents=True, exist_ok=True)
    mesa_dir = a.mesa_dir.resolve()
    vk_dir = a.vk_include.resolve()

    model, enc, types, commands, command_set = load_model()
    if a.command_set:
        command_set = model.read_command_set(a.command_set)

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
