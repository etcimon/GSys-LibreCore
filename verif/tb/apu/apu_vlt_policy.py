#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Shared compiler PGO recipe and bounded RTL-unroll policy."""
import hashlib
import json
import os
from pathlib import Path
import sys

PGO_INPUTS = ('apu_vlt_policy.py', 'apu_verilator_pgo.py',
              'verilator-pgo-cxx.sh', 'vlt_pgo_train.sv')
UNROLL_COUNT = 256
UNROLL_STMTS = 131072

# Runtime-codegen options forwarded by Verilator to the generated makefile /
# C++ compile.  These are plain Verilator options, so they apply to any
# Verilator (stock or g6lc fork).  -march=native adapts to the build host and
# -DVL_SIMD_PREFER_512 only widens the SIMD tier when __AVX512F__ is defined,
# so the pair is safe on non-AVX-512 hosts.  Set APU_VLT_NO_OPT=1 to opt out.
CXX_FLAGS = '-march=native -DVL_SIMD_PREFER_512 -fno-semantic-interposition'
OPT_MAKEFLAGS = 'OPT_FAST=-O3 OPT_SLOW=-O1 OPT_GLOBAL=-O2'

# Proven Verilator codegen flags (measured on EPYC 4244P / GCC 16.2.0 znver4,
# bit-exact cycles with --assert kept on):
#   --x-initial fast           : skip VL_RAND_RESET init overhead (+4.4%)
#   --inline-mult 500          : keep replicated FPnew/SRAM out-of-line (+3.5%)
#   --output-split-cfuncs 2000 : split mega-NBA funcs for PGO+LTO I1 layout
VLT_CODEGEN_FLAGS = ('--x-initial', 'fast', '--inline-mult', '500',
                     '--output-split-cfuncs', '2000')

# hyp8-style fork passes (clock-skip-sink + opt-in DFG peepholes).  Measured
# 0 hits on --timing APU models (V3ClkSkip bails out on --timing; sentinel DFG
# reports 0 matching candidates), so kept opt-in via APU_VLT_FORK_PASSES=1.
FORK_FLAGS = ('-fclock-skip-sink', '-fdfg-peephole',
              '-fdfg-peephole-pack-byte-plane', '-fdfg-peephole-pack-predicates',
              '-fdfg-peephole-pack-bitwise-mux', '-fdfg-peephole-guard-empty-mask',
              '-fdfg-peephole-fuse-transpose-reductions')
_FORK_MARKERS = (b'clock-skip-sink', b'pack-bitwise-mux', b'fuse-transpose')


def unroll_flags():
    return ['--unroll-count', str(UNROLL_COUNT),
            '--unroll-stmts', str(UNROLL_STMTS), '--stats']


def _verilator_bin():
    cands = []
    root = os.environ.get('VERILATOR_ROOT') or ''
    if root:
        cands.append(os.path.join(root, 'bin', 'verilator_bin'))
    for var in ('APU_REAL_VERILATOR', 'VERILATOR'):
        v = os.environ.get(var) or ''
        if not v:
            continue
        if os.path.basename(v) == 'verilator_bin':
            cands.append(v)
        cands.append(os.path.join(os.path.dirname(v), 'verilator_bin'))
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return ''


def _fork_supports():
    b = _verilator_bin()
    if not b:
        return False
    try:
        with open(b, 'rb') as fh:
            blob = fh.read()
    except OSError:
        return False
    return all(m in blob for m in _FORK_MARKERS)


def perf_flags():
    """Codegen/runtime opts appended after the unroll policy."""
    if os.environ.get('APU_VLT_NO_OPT') == '1':
        return []
    flags = [*VLT_CODEGEN_FLAGS, '-CFLAGS', CXX_FLAGS, '-MAKEFLAGS', OPT_MAKEFLAGS]
    if os.environ.get('APU_VLT_FORK_PASSES') == '1' and _fork_supports():
        flags += list(FORK_FLAGS)
    return flags


def recipe_id():
    root = Path(__file__).parent
    files = [(name, hashlib.sha256((root / name).read_bytes()).hexdigest())
             for name in PGO_INPUTS]
    return hashlib.sha256(json.dumps(files, separators=(',', ':')).encode()).hexdigest()


def validate_receipt(home):
    home = Path(home)
    try:
        report = json.loads((home / 'pgo.json').read_text())
        binary = home / 'bin/verilator_bin'
        return (report['schemaVersion'] == 1 and report['mode'] == 'profile-use'
                and report['recipeSha256'] == recipe_id()
                and report['sourceId'] == (home / 'source.id').read_text()
                and report['binarySha256'] == hashlib.sha256(binary.read_bytes()).hexdigest()
                and type(report['profileCount']) is int and report['profileCount'] > 0
                and report['trainingThreads'] == [1, 2]
                and report['unrollFlags'] == unroll_flags()
                and len(report['unrolledLoops']) == 2
                and all(type(n) is int and n > 0 for n in report['unrolledLoops'])
                and report['profileUseReturnCode'] == 0)
    except (OSError, ValueError, KeyError, TypeError):
        return False


if __name__ == '__main__':
    if len(sys.argv) == 2 and sys.argv[1] == '--flags':
        print('\n'.join(unroll_flags() + perf_flags()))
    elif len(sys.argv) == 3 and sys.argv[1] == '--check':
        sys.exit(0 if validate_receipt(sys.argv[2]) else 1)
    elif len(sys.argv) == 2 and sys.argv[1] == '--recipe':
        print(recipe_id())
    else:
        sys.exit(2)
