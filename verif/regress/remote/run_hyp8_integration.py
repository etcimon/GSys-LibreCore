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
import signal
import subprocess

# HYP8_RUNTIME_DIR / HYP8_RUNTIME_DIGEST: VERILATOR_ROOT for lint and build.
# Default the pinned private runtime; a tools/verilator fork prefix supplies
# its own runtime/ (fork headers + verilator_bin, install-verilator-g6lc.sh),
# whose verilated_funcs.h digest must then be named explicitly.
RUNTIME = Path(os.environ.get(
    'HYP8_RUNTIME_DIR', '/opt/testharness/runs/review-private-runtime-20260915/runtime'))
RUNTIME_DIGEST = os.environ.get(
    'HYP8_RUNTIME_DIGEST', 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166')
# HYP8_VERILATOR_DIR: alternative verilator prefix (e.g. the PGO build of the
# tools/verilator fork from install-verilator-g6lc.sh VLT_PGO=1). The binary
# identity is recorded either way (verilatorBinSha256), so a switch is a new
# instrument on record, never a silent flag.
VERILATOR_DIR = os.environ.get('HYP8_VERILATOR_DIR', '/opt/testharness/src/verilator-causal')
VERILATOR = f'{VERILATOR_DIR}/bin/verilator'
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
TEST_DIR = 'verif/tests/custom'
TESTS = [
    ('h34_shift_dep', f'{TEST_DIR}/hyp8_h34_shift_dep.S', '80001000'),
    ('h33_st_fwd', f'{TEST_DIR}/hyp8_h33_st_fwd.S', '80001000'),
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
    # r68 F14 discriminator: plain sd vs sc.d at the addr[8:6] != 0 offset
    # class; distinct fail codes name the owning path.
    ('hyp8_f14_store_offset', 'verif/tests/custom/hyp8_f14_store_offset.S',
     '80001000'),
    # r100 issue 6: sub-word store/load shapes around byte 7 of an aligned
    # dword (Linux 6.6.93 on r107: `earlyco=sbi`, kallsyms names cut at 7).
    ('hyp8_h35_subword', 'verif/tests/custom/hyp8_h35_subword.S',
     '80001000'),
    # General regression for the memory-replay hypothesis investigated
    # during issue 6; passed on the affected baseline.
    ('hyp8_h36_strlen_replay', 'verif/tests/custom/hyp8_h36_strlen_replay.S',
     '80001000'),
    # r100 issue 6: older store with a late (load-produced) address writes
    # byte 7 under a younger byte-walk strlen -- the memory-order replay
    # must precede any younger retire.
    ('hyp8_h37_ldst_viol_strlen',
     'verif/tests/custom/hyp8_h37_ldst_viol_strlen.S', '80001000'),
    ('hyp8_h38_zbb_zero',
     'verif/tests/custom/hyp8_h38_zbb_zero.S', '80001000'),
    # Liveness of a plain store between LR and SC (and LR without SC): the
    # B1 LR->SC window wedged `lr; sd; sc` under in-order issue.
    ('hyp8_lrsc_store',
     'verif/tests/custom/hyp8_lrsc_store.S', '80001000'),
    # r127: translated loads/stores in S-mode under Sv39 (one identity
    # gigapage). The only smoke that reaches the ITLB/DTLB/PTW.
    ('hyp8_sv39_load', 'verif/tests/custom/hyp8_sv39_load.S', '80001000'),
    # r127: Zkn known-answer test (every RV64 AES/SHA instruction of the AES
    # functional unit, checksum from Spike). The only smoke that issues to
    # that unit.
    ('hyp8_zkn_kat', 'verif/tests/custom/hyp8_zkn_kat.S', '80001000'),
    # rfix131a: speculative loads stay off the bus outside idempotent memory --
    # the OpenSBI MPRV window and a wrong-path device-space load, the two
    # patterns behind the witness's 18,131 AXI DECERR reads. Graded on the
    # log as well (run_hyp8_smokes.py: no `Response Errored`, no UART read).
    ('hyp8_spec_bus_clean', 'verif/tests/custom/hyp8_spec_bus_clean.S',
     '80001000'),
    # rfix131a: nothing runs under a stale privilege / translation context --
    # the firmware's sbi_get_insn MPRV window and its trap-exit mret, the
    # patterns behind ~21k of the witness's 29k [ptw-err] records. No page
    # fault is architectural in it: graded on the log (no [ptw-err], no
    # [mmu-ife], no `Response Errored`).
    ('hyp8_ctx_switch_clean', 'verif/tests/custom/hyp8_ctx_switch_clean.S',
     '80001000'),
    # rfix131a: right-path device loads/stores (CLINT) interleaved with
    # memory traffic -- the non-idempotent load path (commit-head issue,
    # hand-back and refetch) that the PMA declaration makes live.
    ('hyp8_dev_load', 'verif/tests/custom/hyp8_dev_load.S', '80001000'),
    # rfix131a-03: wrong-path loads with a null / garbage base under Sv39
    # request no page-table walk (log grade: no [ptw-err], no [mmu-ife]).
    ('hyp8_spec_walk_clean', 'verif/tests/custom/hyp8_spec_walk_clean.S',
     '80001000'),
    # rfix131a multi-core: every hart -- secondary release by IPI, LR/SC and
    # AMO on shared counters, coherent private slots. NHARTS comes from
    # HYP8_TEST_DEFINES (default 1: a plain single-hart smoke).
    ('hyp8_smp_lrsc', 'verif/tests/custom/hyp8_smp_lrsc.S', '80001000'),
    # rfix131a-04: U-mode traps into an S-mode handler (ecall and illegal
    # instruction): no fetch is evaluated under the context it was not
    # issued in (log grade: no [mmu-ife], no [ptw-err]).
    ('hyp8_trap_entry_clean', 'verif/tests/custom/hyp8_trap_entry_clean.S',
     '80001000'),
    # rfix131a-09: nothing behind a mispredicted branch retires -- minstret
    # is exact and fflags takes no wrong-path flag.
    ('hyp8_ghost_commit', 'verif/tests/custom/hyp8_ghost_commit.S',
     '80001000'),
]
LINK_LD = 'verif/tests/custom/common/link_verilator.ld'
GCC_FLAGS = ['-march=rv64imafdc_zicsr_zifencei', '-mabi=lp64d',
             '-mcmodel=medany', '-O2', '-nostdlib', '-nostartfiles']
# what a resume overlay may replace (never RTL, flists or the testbench)
RESUME_OVERLAY_PREFIXES = ('verif/regress/remote/hyp8/hyp8-build-harness.sh',
                           'verif/tests/custom/')
GUARD_PATTERN = r'[/]Variane_testharness( |$)|[s]oft-ladder'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(cmd, log, env=None, cwd=None, timeout=None, append=False):
    """Run in its own process group; a timeout takes the whole group down.

    The 8-hart verilation outlived a 6 h budget as an orphan for five more
    hours (rfix131a): killing only the direct child leaves verilator_bin or
    make running against a run that was already reported as failed.
    """
    with open(log, 'a' if append else 'w') as fh:
        p = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT,
                             env=env, cwd=cwd, start_new_session=True)
        try:
            return p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(p.pid, sig)
                except ProcessLookupError:
                    break
                try:
                    p.wait(timeout=20)
                    break
                except subprocess.TimeoutExpired:
                    continue
            fh.write(f'\n[run] timed out after {timeout} s; process group killed\n')
            return 124


def census(log):
    counts = {}
    text = Path(log).read_text(errors='replace')
    for m in re.finditer(r'%(Warning|Error)-([A-Z]+)', text):
        key = f'%{m.group(1)}-{m.group(2)}'
        counts[key] = counts.get(key, 0) + 1
    counts['%Error'] = len(re.findall(r'%Error(?!-)', text))
    return counts


def lint_failed(rc, warnings):
    """Tool failures and RTL $error are fatal; other diagnostics need review."""
    return (rc != 0 or warnings.get('%Error', 0) != 0
            or warnings.get('%Warning-USERERROR', 0) != 0)


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    # HYP8_RESUME_TAG: continue the build of an earlier run in place (its
    # hash-verified source and its completed verilation), instead of paying
    # for the verilation again. The data closure of a resume is an overlay
    # restricted to runner tooling and test sources: anything that feeds the
    # generated C++ would make the reused model stale and is refused.
    resume_tag = os.environ.get('HYP8_RESUME_TAG')
    report_out = out
    if resume_tag:
        out = Path('/opt/testharness/runs') / resume_tag / 'output'
        assert (out / 'source').is_dir(), f'no source closure in {out}'
        assert (out / 'model' / 'Vg6lc_testharness__verFiles.dat').is_file(), \
            f'no completed verilation in {out}/model'
    src = out / 'source'
    inputs = out / 'inputs'
    inputs.mkdir(parents=True, exist_ok=True)
    results = {'status': 'started', 'lint': {}, 'guard': {},
               'build': {}, 'inputs': {}}
    if resume_tag:
        results['resumedFrom'] = resume_tag

    def publish():
        text = json.dumps(results, indent=2)
        (out / 'results.json').write_text(text)
        if report_out != out:
            (report_out / 'results.json').write_text(text)

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
    if resume_tag:
        foreign = [rel for rel in staged
                   if not rel.startswith(RESUME_OVERLAY_PREFIXES)]
        if foreign:
            results['status'] = 'resume_overlay_rejected'
            results['rejected'] = foreign
            publish()
            raise SystemExit('resume overlay touches model sources: '
                             + ', '.join(foreign[:8]))
        results['resumeOverlay'] = sorted(staged)
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
        publish()
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
    # The perl driver execs $VERILATOR_ROOT/bin/verilator_bin when present:
    # record that binary too, so the executed instrument is never ambiguous.
    rt_bin = RUNTIME / 'bin/verilator_bin'
    if rt_bin.is_file():
        results['runtimeBinSha256'] = digest(rt_bin)
    results['runtimeVerilatedFuncsSha256'] = digest(RUNTIME / 'include/verilated_funcs.h')
    # Compiler-PGO evidence: install-verilator-g6lc.sh with VLT_PGO=1 installs
    # the instrumented pass-1 prefix at <prefix>.pgo-train beside the profile-use
    # <prefix>. Its presence marks a PGO-built verilator_bin; a plain fork or
    # src checkout has no such sibling. Recorded (not gated) so a toolchain
    # switch is always a new instrument on record.
    results['compilerPgo'] = Path(f'{VERILATOR_DIR}.pgo-train').is_dir()
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
        if resume_tag:
            # the resumed run linted this same source; its logs are the record
            assert log.is_file(), f'resumed run has no {log.name}'
            results['lint'][name] = {'rc': 0, 'warnings': census(log),
                                     'log': f'lint-{name}.log',
                                     'rcSource': 'resumed run log census'}
            continue
        cmd = [VERILATOR, '--lint-only', '--no-timing', '--assert',
               *defs, '-Wall', *WARN_POLICY,
               '--top-module', 'g6lc_testharness',
               '-f', ('verif/regress/remote/hyp8/Flist.hyp8_mc_sim'
                      if name == 'mc' else FLIST), 'verilator_config.vlt']
        (out / f'command-lint-{name}.json').write_text(json.dumps(cmd, indent=2))
        # HYP8_LINT_TIMEOUT: the mc (8-hart SoC) flist elaborates far longer than
        # the scalar/smt2 flists and can exceed the 1200 s default on a loaded
        # host; allow an operator override without changing the default gate.
        lint_timeout = int(os.environ.get('HYP8_LINT_TIMEOUT', '1200'))
        rc = run(cmd, log, env=env, cwd=src, timeout=lint_timeout)
        results['lint'][name] = {'rc': rc, 'warnings': census(log),
                                 'log': f'lint-{name}.log'}
    if any(lint_failed(entry['rc'], entry['warnings'])
           for entry in results['lint'].values()):
        results['status'] = 'lint_failed'
        publish()
        raise SystemExit('full-top lint failed; see lint-*.log')

    if os.environ.get('HYP8_LINT_ONLY'):
        results['status'] = 'lint_only'
        publish()
        (out / 'summary.txt').write_text('hyp8-integration: lint_only\n')
        return 0

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
                     'limits': {'buildJobs': int(os.environ.get('HYP8_BUILD_JOBS', '2')), 'verilatorThreads': 1}},
    }
    if procs and not allow:
        results['status'] = 'build_blocked_by_overlap'
    else:
        # --- 5. isolated scalar build --------------------------------------
        build_env = dict(env,
                         SOFT_LADDER_BUILD_TARGET=os.environ.get('HYP8_BUILD_TARGET', 'g6lc64_hyp8'),
                         SOFT_LADDER_VERLIB=str(out / 'model'),
                         SOFT_LADDER_BUILD_JOBS=os.environ.get('HYP8_BUILD_JOBS', '2'),
                         SOFT_LADDER_VERILATOR_THREADS=os.environ.get('HYP8_VERILATOR_THREADS', '1'),
                         # g6lc fork is the required default for hyp8 remote
                         # builds: it carries the split_var/unroll-before-split
                         # fixes the mc model needs. pinned remains available
                         # only as an explicit HYP8_VERILATOR_FLAVOUR=pinned A/B.
                         VERILATOR_FLAVOUR=os.environ.get('HYP8_VERILATOR_FLAVOUR', 'g6lc'),
                         VLT_HOME=VERILATOR_DIR,
                         VERILATOR_INSTALL_DIR=VERILATOR_DIR,
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
                 'VERILATOR_INSTALL_DIR', 'VERILATOR_ROOT', 'VLT_HOME',
                 'SPIKE_INSTALL_DIR', 'RISCV')} | {
                 k: v for k, v in build_env.items() if k.startswith('HYP8_BUILD_')}},
            indent=2))
        # HYP8_BUILD_TIMEOUT: the 8-hart mc2 model needs >7200 s at -j2 (r69:
        # the runner timed out while the orphaned make kept compiling).
        if resume_tag:
            build_env['HYP8_BUILD_RESUME'] = '1'
        rc = run(cmd, out / 'build-harness.log', env=build_env, cwd=src,
                 timeout=int(os.environ.get('HYP8_BUILD_TIMEOUT', '7200')),
                 append=bool(resume_tag))
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
            # simulation PGO evidence: profiles applied by phase 2 (0 = none)
            'simPgoProfiles': len(list((out / 'model' / 'pgo').rglob('*.gcda'))),
            # 'instrumented' = phase 1 of the simulation PGO only: the model
            # is functionally final but not yet rebuilt with its profile
            'simPgoStage': build_env.get('HYP8_BUILD_PGO_STAGE', 'full'),
            # simPgoApplied: a -fprofile-use rebuild actually consumed profiles.
            # 'full'/'use' stages must leave .gcda; 'instrumented' is phase-1
            # only (0 expected until runs write them); 'verilate' has no model.
            'simPgoApplied': (
                len(list((out / 'model' / 'pgo').rglob('*.gcda'))) > 0
                if build_env.get('HYP8_BUILD_PGO_STAGE', 'full') in ('full', 'use')
                else build_env.get('HYP8_BUILD_PGO_STAGE', 'full') == 'instrumented'),
        }
        results['status'] = 'build_complete' if (rc == 0 and model.is_file()) \
            else 'build_failed'
        if (rc == 0 and build_env.get('HYP8_BUILD_PGO_STAGE') == 'verilate'
                and (out / 'model' / 'Vg6lc_testharness__verFiles.dat').is_file()):
            # stage 1 of a staged build: generated C++ only, no model yet
            results['status'] = 'verilated'

    # --- 6. bounded test inputs (assembled fresh, never a copied elf) -----
    gcc = f'{RISCV}/bin/riscv-none-elf-gcc'
    nm = f'{RISCV}/bin/riscv-none-elf-nm'
    results['inputs']['gccSha256'] = digest(Path(gcc))
    tohost_bad = []
    for name, src_rel, tohost_addr in TESTS:
        s = src / src_rel
        if not s.is_file():
            # an older closure (A/B builds of an earlier tree) predates the
            # program: recorded, not assembled
            results['inputs'].setdefault('absent', []).append(name)
            continue
        elf = inputs / f'{name}.elf'
        # HYP8_TEST_DEFINES: preprocessor defines for the test sources of a
        # target (e.g. NHARTS=8 for the multi-core model)
        test_defs = [f'-D{d}' for d in os.environ.get('HYP8_TEST_DEFINES', '').split()]
        rc = run([gcc, *GCC_FLAGS, *test_defs, '-T', str(src / LINK_LD),
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
        publish()
        raise SystemExit('tohost-bearing input failed validation: '
                         + '; '.join(tohost_bad))

    publish()
    summary = (f"hyp8-integration: {results['status']} "
               f"lint(scalar rc={results['lint']['scalar']['rc']} "
               f"smt2 rc={results['lint']['smt2']['rc']})")
    (out / 'summary.txt').write_text(summary + '\n')
    if report_out != out:
        (report_out / 'summary.txt').write_text(summary + '\n')
        shutil.copy2(out / 'build-harness.log', report_out / 'build-harness.log')
    print(summary)
    # blocked is a recorded decision state, not a run failure; lint/build
    # failures keep a nonzero rc so the proxy surfaces them as failed runs
    return 0 if results['status'] in ('build_blocked_by_overlap',
                                      'build_complete', 'verilated') else 1


if __name__ == '__main__':
    raise SystemExit(main())
