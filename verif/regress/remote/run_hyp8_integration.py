#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""hyp8 full-top integration preparation: hash-verified isolated source,
full-top Verilator lint for the scalar and G6LC_HYP8_SMT2 profiles, then a
guarded isolated Verilator library build via hyp8-build-harness.sh.

  TH_DATA_DIR  the prepared repo-relative closure (manifest.json pins every
               copied file's sha256; verified before any tool runs)
  TH_OUT_DIR   isolated outputs: source/, lint-*.log, inputs/, model/

The overlap guard is the same pgrep probe the proxy uses. By default any
remaining Variane_testharness/soft-ladder workload sets status
build_blocked_by_overlap and the script stops after lint. HYP8_ALLOW_OVERLAP=1
is an explicit per-run opt-in matching the proxy's --allow-overlap capacity
policy: existing processes, the capacity query, and the selected limits are
all recorded in results.json either way. No firmware is started here."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

RUNTIME = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
RUNTIME_DIGEST = 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
VERILATOR = '/opt/testharness/src/verilator-causal/bin/verilator'
SPIKE = '/opt/testharness/toolchains/spike'
RISCV = '/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3'

FLIST = 'verif/regress/remote/hyp8/Flist.hyp8_sim'
HARNESS = 'verif/regress/remote/hyp8/hyp8-build-harness.sh'
WARN_POLICY = [
    '-Werror-PINMISSING', '-Werror-IMPLICIT', '-Wno-fatal',
    '-Wno-PINCONNECTEMPTY', '-Wno-ASSIGNDLY', '-Wno-DECLFILENAME',
    '-Wno-UNUSED', '-Wno-UNOPTFLAT', '-Wno-BLKANDNBLK', '-Wno-style',
]
# (name, closure-relative .S path, expected tohost address) triples: the
# harness tests live in the materialized workspace tree, the directed
# architectural program is a tracked verif/tests/custom source. Every test
# here is tohost-bearing (link_verilator.ld places .tohost at 0x80001000):
# the address is declared explicitly AND cross-checked against the built ELF
# via nm, so a run launched without +tohost_addr is a configuration error,
# not a silent liveness-only verdict (a budget-out reads tohost==0 and would
# mask a real 0x101 fail path, e.g. h33).
TEST_DIR = 'build-platform/workspace/build/sv-timing/hyp8-src/tb/tests'
TESTS = [
    ('h34_shift_dep', f'{TEST_DIR}/h34_shift_dep.S', '80001000'),
    ('h33_st_fwd', f'{TEST_DIR}/h33_st_fwd.S', '80001000'),
    ('hyp8_branch_cancel', 'verif/tests/custom/hyp8_branch_cancel.S',
     '80001000'),
    ('hyp8_csr_flush_skip', 'verif/tests/custom/hyp8_csr_flush_skip.S',
     '80001000'),
    ('hyp8_amo_store_order', 'verif/tests/custom/hyp8_amo_store_order.S',
     '80001000'),
    # r68: head-only issue order under OoO readiness (older AMO/LR with a
    # late operand in front of a ready younger AMO/SC/LR). Wedges (budget
    # out) on the pre-r68 g6lc_iq_legal; the kernel-spinlock shape.
    ('hyp8_amo_ready_order', 'verif/tests/custom/hyp8_amo_ready_order.S',
     '80001000'),
]
LINK_LD = 'verif/tests/custom/common/link_verilator.ld'
GCC_FLAGS = ['-march=rv64imafdc_zicsr_zifencei', '-mabi=lp64d',
             '-mcmodel=medany', '-O2', '-nostdlib', '-nostartfiles']
GUARD_PATTERN = r'[/]Variane_testharness( |$)|[s]oft-ladder'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(cmd, log, env=None, cwd=None, timeout=None):
    with open(log, 'w') as fh:
        p = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT,
                           env=env, cwd=cwd, timeout=timeout)
    return p.returncode


def census(log):
    counts = {}
    text = Path(log).read_text(errors='replace')
    for m in re.finditer(r'%(Warning|Error)-([A-Z]+)', text):
        key = f'%{m.group(1)}-{m.group(2)}'
        counts[key] = counts.get(key, 0) + 1
    counts['%Error'] = len(re.findall(r'%Error(?!-)', text))
    return counts


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    src = out / 'source'
    inputs = out / 'inputs'
    inputs.mkdir(parents=True, exist_ok=True)
    results = {'status': 'started', 'lint': {}, 'guard': {},
               'build': {}, 'inputs': {}}

    # --- 1. hash-verified isolated source ---------------------------------
    # the proxy rsyncs a --data dir into data/<dir-name>/, so the closure
    # root is the single subdirectory containing manifest.json
    root = data
    if not (root / 'manifest.json').is_file():
        matches = [d for d in data.iterdir()
                   if d.is_dir() and (d / 'manifest.json').is_file()]
        assert len(matches) == 1, \
            f'expected exactly one closure dir under {data}, got {len(matches)}'
        root = matches[0]
    manifest = json.loads((root / 'manifest.json').read_text())
    staged = manifest['files']
    bad = []
    for rel, sha in staged.items():
        hit = root / rel
        if not hit.is_file() or digest(hit) != sha:
            bad.append(rel)
            continue
        dest = src / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(hit, dest)
    if bad:
        results['status'] = 'input_hash_mismatch'
        results['mismatched'] = bad
        (out / 'results.json').write_text(json.dumps(results, indent=2))
        raise SystemExit(f'input hash verification failed for {len(bad)} files')
    results['sourceFiles'] = len(staged)

    # --- 2. pinned runtime/toolchain identity -----------------------------
    assert digest(RUNTIME / 'include/verilated_funcs.h') == RUNTIME_DIGEST, \
        'private runtime digest mismatch'
    assert Path(VERILATOR).is_file(), 'managed verilator missing'
    for tool in (f'{RISCV}/bin/riscv-none-elf-gcc',
                 f'{RISCV}/bin/riscv-none-elf-nm'):
        assert Path(tool).is_file(), f'pinned toolchain missing: {tool}'
    ver = subprocess.run([VERILATOR, '--version'], capture_output=True,
                         text=True).stdout.strip()
    results['verilator'] = ver
    # Toolchain identity is evidence: hash the actual compiler object and
    # the perl driver, not merely the absolute path/version string.
    verilator_obj = Path(VERILATOR).parent / 'verilator_bin'
    if verilator_obj.is_file():
        results['verilatorBinSha256'] = digest(verilator_obj)
    results['verilatorDriverSha256'] = digest(Path(VERILATOR))
    env = dict(os.environ, CVA6_REPO_DIR=str(src),
               VERILATOR_ROOT=str(RUNTIME),
               VPATH=f'{RUNTIME}/include:{src}',
               SPIKE_INSTALL_DIR=SPIKE, RISCV=RISCV)

    # --- 3. full-top lint, scalar then SMT2 -------------------------------
    lint_profiles = [('scalar', []), ('smt2', ['-DG6LC_HYP8_SMT2'])]
    if os.environ.get('HYP8_LINT_MC'):
        lint_profiles.append(('mc', []))
    for name, defs in lint_profiles:
        log = out / f'lint-{name}.log'
        cmd = [VERILATOR, '--lint-only', '--no-timing', '--assert',
               *defs, '-Wall', *WARN_POLICY,
               '--top-module', 'g6lc_testharness',
               '-f', ('verif/regress/remote/hyp8/Flist.hyp8_mc_sim'
                      if name == 'mc' else FLIST), 'verilator_config.vlt']
        (out / f'command-lint-{name}.json').write_text(json.dumps(cmd, indent=2))
        rc = run(cmd, log, env=env, cwd=src, timeout=1200)
        results['lint'][name] = {'rc': rc, 'warnings': census(log),
                                 'log': f'lint-{name}.log'}
    if any(results['lint'][n]['rc'] != 0 for n in results['lint']):
        results['status'] = 'lint_failed'
        (out / 'results.json').write_text(json.dumps(results, indent=2))
        raise SystemExit('full-top lint failed; see lint-*.log')

    # --- 4. overlap guard + capacity record -------------------------------
    guard = subprocess.run(['pgrep', '-a', '-f', GUARD_PATTERN],
                           capture_output=True, text=True)
    procs = [l for l in guard.stdout.splitlines() if l.strip()]
    nproc = subprocess.run(['nproc'], capture_output=True,
                           text=True).stdout.strip()
    loadavg = ''
    try:
        loadavg = ' '.join(f'{v:.2f}' for v in os.getloadavg())
    except OSError:
        pass
    meminfo = ''
    try:
        for line in Path('/proc/meminfo').read_text().splitlines():
            if line.startswith('MemAvailable'):
                meminfo = line.strip()
    except OSError:
        pass
    allow = os.environ.get('HYP8_ALLOW_OVERLAP') == '1'
    results['guard'] = {
        'query': f"pgrep -a -f '{GUARD_PATTERN}'",
        'processes': procs,
        'allowOverlap': allow,
        'capacity': {'nproc': nproc, 'loadavg': loadavg,
                     'mem': meminfo,
                     'limits': {'buildJobs': 2, 'verilatorThreads': 1}},
    }
    if procs and not allow:
        results['status'] = 'build_blocked_by_overlap'
    else:
        # --- 5. isolated scalar build --------------------------------------
        build_env = dict(env,
                         SOFT_LADDER_BUILD_TARGET=os.environ.get('HYP8_BUILD_TARGET', 'g6lc64_hyp8'),
                         SOFT_LADDER_VERLIB=str(out / 'model'),
                         SOFT_LADDER_BUILD_JOBS='2',
                         SOFT_LADDER_VERILATOR_THREADS='1',
                         VERILATOR_FLAVOUR='pinned',
                         VERILATOR_INSTALL_DIR='/opt/testharness/src/verilator-causal',
                         VERILATOR_ROOT=str(RUNTIME),
                         SPIKE_INSTALL_DIR=SPIKE,
                         RISCV=RISCV)
        cmd = ['bash', HARNESS, 'hyp8']
        (out / 'command-build.json').write_text(json.dumps(
            {'argv': cmd,
             'env': {k: build_env[k] for k in (
                 'CVA6_REPO_DIR', 'SOFT_LADDER_BUILD_TARGET',
                 'SOFT_LADDER_VERLIB', 'SOFT_LADDER_BUILD_JOBS',
                 'SOFT_LADDER_VERILATOR_THREADS', 'VERILATOR_FLAVOUR',
                 'VERILATOR_INSTALL_DIR', 'VERILATOR_ROOT',
                 'SPIKE_INSTALL_DIR', 'RISCV')}}, indent=2))
        rc = run(cmd, out / 'build-harness.log', env=build_env, cwd=src,
                 timeout=7200)
        model = out / 'model' / 'Variane_testharness'
        # Full built-model dependency check, same as the leaf runner: the
        # generated .d files must cite the pinned private runtime header.
        dep_ok = None
        dep_files = list((out / 'model').rglob('*.d'))
        if dep_files:
            dep_text = '\n'.join(f.read_text(errors='replace')
                                 for f in dep_files)
            dep_ok = str(RUNTIME / 'include/verilated_funcs.h') in dep_text
        results['build'] = {
            'rc': rc,
            'modelSha256': digest(model) if model.is_file() else None,
            'runtimeDepFiles': len(dep_files),
            'runtimeDepChecked': dep_ok,
            'warnings': census(out / 'model' / 'build.log')
            if (out / 'model' / 'build.log').is_file() else {},
            'harnessLog': 'build-harness.log',
            'buildLog': 'model/build.log',
        }
        results['status'] = 'build_complete' if (rc == 0 and model.is_file()) \
            else 'build_failed'

    # --- 6. bounded test inputs (assembled fresh, never a copied elf) -----
    gcc = f'{RISCV}/bin/riscv-none-elf-gcc'
    nm = f'{RISCV}/bin/riscv-none-elf-nm'
    results['inputs']['gccSha256'] = digest(Path(gcc))
    tohost_bad = []
    for name, src_rel, tohost_addr in TESTS:
        s = src / src_rel
        elf = inputs / f'{name}.elf'
        rc = run([gcc, *GCC_FLAGS, '-T', str(src / LINK_LD),
                  '-o', str(elf), str(s)],
                 inputs / f'{name}.build.log', env=env, cwd=src, timeout=120)
        entry = {'srcSha256': digest(s), 'rc': rc, 'source': src_rel}
        if rc == 0 and elf.is_file():
            entry['elfSha256'] = digest(elf)
            syms = subprocess.run([nm, '-n', str(elf)], capture_output=True,
                                  text=True).stdout
            tohost = [l for l in syms.splitlines() if l.endswith(' tohost')]
            entry['tohost'] = tohost[0].split()[0] if tohost else None
            # Hard gate: these inputs are tohost-bearing. A missing symbol or
            # an address that drifted from the declared one means a launch
            # without +tohost_addr would silently liveness-grade the run —
            # refuse the input rather than let that happen (fail-loud).
            if entry['tohost'] is None:
                tohost_bad.append(f'{name}: no tohost symbol in ELF')
            elif int(entry['tohost'], 16) != int(tohost_addr, 16):
                tohost_bad.append(
                    f"{name}: tohost at 0x{entry['tohost']} != declared "
                    f"0x{tohost_addr}")
            else:
                # The run recipe a launcher must use; anything else for this
                # input is an error (never classify a budget-out as PASS).
                entry['tohostPlusarg'] = f'+tohost_addr=0x{tohost_addr}'
        results['inputs'][name] = entry
    if tohost_bad:
        results['status'] = 'tohost_missing'
        results['tohostErrors'] = tohost_bad
        (out / 'results.json').write_text(json.dumps(results, indent=2))
        raise SystemExit('tohost-bearing input failed validation: '
                         + '; '.join(tohost_bad))

    (out / 'results.json').write_text(json.dumps(results, indent=2))
    summary = (f"hyp8-integration: {results['status']} "
               f"lint(scalar rc={results['lint']['scalar']['rc']} "
               f"smt2 rc={results['lint']['smt2']['rc']})")
    (out / 'summary.txt').write_text(summary + '\n')
    print(summary)
    # blocked is a recorded decision state, not a run failure; lint/build
    # failures keep a nonzero rc so the proxy surfaces them as failed runs
    return 0 if results['status'] in ('build_blocked_by_overlap',
                                      'build_complete') else 1


if __name__ == '__main__':
    raise SystemExit(main())
