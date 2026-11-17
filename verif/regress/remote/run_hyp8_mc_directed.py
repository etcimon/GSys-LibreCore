#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""hyp8 multi-core directed suite: assemble and run the verif/tests/custom/
multicore programs on an already-built hyp8 model (g6lc64_hyp8_mc), one at a
time, grading the same way run_hyp8_smokes.py does.

The multicore/*.S programs are NOT part of the integration TESTS list (they
were written for the ariane review harness); this runner is the hyp8-flavoured
path that gives the SMP model the same directed coverage before the slow
Linux/OpenWrt witness. Sources arrive via --data (TH_DATA_DIR): the
'multicore/' directory of .S files and 'common/link_verilator.ld'.

  HYP8_INT_TAG    integration run tag whose model to run (required)
  HYP8_MC_TESTS   space-separated test names; default = the curated suite
  HYP8_MC_SRC     source dir override (default TH_DATA_DIR/multicore)
  HYP8_MAX_CYCLES per-test cycle budget (default 2000000)
  HYP8_PLUSARGS   extra plusargs (space separated)
  HYP8_TEST_DEFINES  base -D defines for every test (e.g. NHARTS=8)

Verdict rule mirrors run_hyp8_smokes: pass = `*** SUCCESS ***` AND a real
tohost write; FAILED records the tohost code; a budget-out is `wedged`, never
a pass. `oracle_neg` entries expect the deliberate-fail code (the negative
oracle proving the checker discriminates). Log grade flags bus errors, UART
reads, model $errors and (for *_clean names) walk/fetch faults as log_dirty.
"""
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

RUNS = Path('/opt/testharness/runs')
RISCV = '/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3'
GCC_FLAGS = ['-march=rv64imafdc_zicsr_zifencei', '-mabi=lp64d',
             '-mcmodel=medany', '-O2', '-nostdlib', '-nostartfiles']

# (name, source file under the multicore dir, extra -D defines, kind,
#  optional march override)
# kind: 'pass' expects SUCCESS; 'oracle_neg' expects the deliberate fail code
# (recorded, graded oracle_ok when the code is nonzero); 'info' records the
# raw verdict without pass/fail judgement (exploratory probes).
TESTS = [
    # --- SMP bring-up / hart liveness -------------------------------------
    ('mc_boot_sanity',        'mc_boot_sanity.S',        [], 'pass'),
    ('mc_hart1_alive',        'mc_hart1_alive.S',        [], 'pass'),
    ('mc_hart1_store_visible','mc_hart1_store_visible.S', [], 'pass'),
    ('mc_hart1_trap',         'mc_hart1_trap.S',         [], 'oracle_neg'),
    ('mc_smt2_boot_release',  'mc_smt2_boot_release.S',  [], 'pass'),
    ('smt_mixed_probe',       'smt_mixed_probe.S',       [], 'pass'),
    ('mini_ipi_hart1_sp',     'mini_ipi_hart1_sp.S',     [], 'pass'),
    ('mini_wfi_noipi_hart1',  'mini_wfi_noipi_hart1.S',  [], 'pass'),
    # --- shared-line / coherence ------------------------------------------
    ('mc_shared_line_xcore',  'mc_shared_line_coherence.S', ['-DPEER_HART=2'], 'pass'),
    ('mc_shared_line_sibling','mc_shared_line_coherence.S', ['-DPEER_HART=1'], 'pass'),
    ('mc_shared_line_quiet',  'mc_shared_line_quiet.S',   [], 'pass'),
    ('mc_shared_line_resident','mc_shared_line_resident.S', [], 'pass'),
    ('mc_multi_writer_line',  'mc_multi_writer_line.S',   [], 'pass'),
    ('mc_l2_write_read',      'mc_l2_write_read.S',       [], 'pass'),
    ('mc_l3_evict_inclusion','mc_l3_evict_inclusion.S',   [], 'pass'),
    ('mc_l3_stride_scan',     'mc_l3_stride_scan.S',      [], 'pass'),
    ('mc_two_inval_backpressure','mc_two_inval_backpressure.S', [], 'pass'),
    ('mc_store_load_new_line','mc_store_load_new_line.S', [], 'pass'),
    ('mc_cbo_contended',      'mc_cbo_contended.S',       [], 'pass'),
    ('mc_cbo_ewt',            'mc_cbo_ewt.S',             [], 'pass'),
    # --- LR/SC / AMO / atomics --------------------------------------------
    ('mc_lrsc_set_zombie',    'mc_lrsc_set_zombie.S',     [], 'pass'),
    ('mc_cas_lock_handoff',   'mc_cas_lock_handoff.S',    [], 'pass'),
    ('mini_lrsc_d',           'mini_lrsc_d.S',            [], 'pass'),
    ('mini_amocas_d',         'mini_amocas_d.S',          [], 'pass',
     'rv64imafdc_zicsr_zifencei_zacas'),
    ('mini_amoadd_w_spin',    'mini_amoadd_w_spin.S',     [], 'pass'),
    # --- traps / CSR / exceptions ------------------------------------------
    ('mc_csr_prologue',       'mc_csr_prologue.S',        [], 'pass'),
    ('mini_csr_expected_trap','mini_csr_expected_trap.S', [], 'pass'),
    ('mini_csr_pmp_probe',    'mini_csr_pmp_probe.S',     [], 'pass'),
    ('mini_trap_cause',       'mini_trap_cause.S',        [], 'pass'),
    # --- icache / fetch / speculation --------------------------------------
    ('mc_icache_switch_storm','mc_icache_switch_storm.S', [], 'pass'),
    ('mc_inval_bp_stress',    'mc_inval_bp_stress.S',     [], 'pass'),
    ('mini_fetch_redirect_chain','mini_fetch_redirect_chain.S', [], 'pass'),
    # --- PMU ----------------------------------------------------------------
    ('mc_pmu_access',         'mc_pmu_access.S',          [], 'pass'),
    ('mc_pmu_control',        'mc_pmu_control.S',         [], 'pass'),
    ('mc_pmu_l3',             'mc_pmu_l3.S',              [], 'pass'),
]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    out = Path(os.environ['TH_OUT_DIR'])
    tag = os.environ.get('HYP8_INT_TAG')
    assert tag, 'HYP8_INT_TAG required'
    budget = int(os.environ.get('HYP8_MAX_CYCLES', '2000000'))
    extra = os.environ.get('HYP8_PLUSARGS', '').split()
    base_defs = [f'-D{d}' for d in os.environ.get('HYP8_TEST_DEFINES', '').split()]
    data = Path(os.environ.get('TH_DATA_DIR', out / 'data'))
    src_dir = Path(os.environ.get('HYP8_MC_SRC', data / 'multicore'))
    link_ld = Path(os.environ.get('HYP8_MC_LINKLD', data / 'common' / 'link_verilator.ld'))

    intdir = RUNS / tag / 'output'
    results = json.loads((intdir / 'results.json').read_text())
    model = intdir / 'model' / 'Variane_testharness'
    assert model.is_file(), f'model missing: {model}'
    assert results['status'] == 'build_complete' and results['build']['rc'] == 0
    model_sha = digest(model)
    assert model_sha == results['build']['modelSha256'], 'model identity changed'
    assert link_ld.is_file(), f'linker script missing: {link_ld}'

    gcc = f'{RISCV}/bin/riscv-none-elf-gcc'
    nm = f'{RISCV}/bin/riscv-none-elf-nm'
    elf_dir = out / 'elf'
    elf_dir.mkdir(exist_ok=True)

    subset = os.environ.get('HYP8_MC_TESTS', '').split()
    names = {t[0] for t in TESTS}
    selected = [t for t in TESTS if not subset or t[0] in subset]
    missing = [n for n in subset if n not in names]
    assert not missing, f'unknown tests: {missing}'

    summary = {'intTag': tag, 'modelSha256': model_sha,
               'srcDir': str(src_dir), 'tests': {}}
    rc_all = 0
    for entry0 in selected:
        name, src_name, defs, kind = entry0[0], entry0[1], entry0[2], entry0[3]
        march = entry0[4] if len(entry0) > 4 else None
        src = src_dir / src_name
        if not src.is_file():
            summary['tests'][name] = {'state': 'no_source', 'src': src_name}
            print(f'{name}: NO_SOURCE {src}')
            rc_all = 1
            continue
        elf = elf_dir / f'{name}.elf'
        bld = out / f'{name}.gcc.log'
        if march:
            gcc_flags = ['-march=' + march, '-mabi=lp64d']
        else:
            gcc_flags = list(GCC_FLAGS)
        gcc_cmd = [gcc, *gcc_flags, *base_defs, *defs,
                   '-T', str(link_ld), '-o', str(elf), str(src)]
        with bld.open('w') as fh:
            p = subprocess.run(gcc_cmd, stdout=fh, stderr=subprocess.STDOUT,
                               cwd=src_dir, timeout=300)
        entry = {'src': src_name, 'defines': base_defs + defs, 'rc': p.returncode}
        if p.returncode != 0 or not elf.is_file():
            entry['state'] = 'build_fail'
            summary['tests'][name] = entry
            print(f'{name}: BUILD_FAIL rc={p.returncode}')
            rc_all = 1
            continue
        entry['elfSha256'] = digest(elf)
        syms = subprocess.run([nm, '-n', str(elf)], capture_output=True,
                              text=True).stdout
        tohost = [l for l in syms.splitlines() if l.endswith(' tohost')]
        if not tohost:
            entry['state'] = 'no_tohost'
            summary['tests'][name] = entry
            print(f'{name}: NO_TOHOST')
            rc_all = 1
            continue
        entry['tohost'] = '0x' + tohost[0].split()[0]
        log = out / f'{name}.log'
        run_cmd = [str(model), f"+tohost_addr={entry['tohost']}", '+debug_disable',
                   f'+max-cycles={budget}', *extra, str(elf)]
        with log.open('w') as fh:
            p = subprocess.run(run_cmd, stdout=fh, stderr=subprocess.STDOUT,
                               cwd=out, timeout=7200)
        text = log.read_text(errors='replace')
        verdict = [l for l in text.splitlines() if '***' in l]
        m = re.search(r'\*\*\* SUCCESS \*\*\*.*after (\d+) cycles', text)
        fail = re.search(r'\*\*\* FAILED \*\*\*.*tohost = (\S+)', text)
        tohost_val = fail.group(1) if fail else None
        bus_err = len(re.findall(r'Response Errored', text))
        uart_rd = len(re.findall(r'^\[uart-axi-ar\]', text, re.M))
        walk_err = len(re.findall(r'^\[(?:ptw-err|mmu-ife)\]', text, re.M))
        model_err = len(re.findall(r'%Error', text))
        if m:
            state = 'pass'
        elif fail:
            state = 'fail'
        else:
            state = 'wedged'
        if state == 'pass' and (bus_err or uart_rd or model_err):
            state = 'log_dirty'
        # oracle-negative: the deliberate fail code is the discrimination proof
        oracle = ''
        if kind == 'oracle_neg':
            oracle = 'oracle_ok' if (state == 'fail' and tohost_val not in (None, '0')) else 'oracle_bad'
        entry.update({'state': state, 'kind': kind, 'oracle': oracle,
                      'tohostVal': tohost_val, 'cycles': int(m.group(1)) if m else None,
                      'busErrors': bus_err, 'uartReads': uart_rd,
                      'walkErrors': walk_err, 'modelErrors': model_err,
                      'verdict': verdict[-1:] if verdict else [],
                      'log': log.name, 'argv': run_cmd})
        # a pass-kind test that fails/wedges, or an oracle that doesn't
        # discriminate, is a suite failure; info entries never gate.
        bad = (kind == 'pass' and state != 'pass') or \
              (kind == 'oracle_neg' and oracle != 'oracle_ok')
        if bad:
            rc_all = 1
        summary['tests'][name] = entry
        print(f"{name}: {state}{('/' + oracle) if oracle else ''} "
              f"cycles={entry['cycles']} tohost={tohost_val} rc={p.returncode} "
              f"bus_err={bus_err} uart_rd={uart_rd} walk_err={walk_err} model_err={model_err}")
    blob = json.dumps(summary, indent=2)
    (out / 'mc-directed-results.json').write_text(blob)
    # tracedb ingest discovers runs by results-file name; smokes-results.json
    # is the recognised 'smoke' kind, so mirror the summary there too.
    (out / 'smokes-results.json').write_text(blob)
    npass = sum(1 for t in summary['tests'].values() if t.get('state') == 'pass')
    ntot = len(summary['tests'])
    print(f'mc-directed: {npass}/{ntot} pass on {tag}')
    return rc_all


if __name__ == '__main__':
    raise SystemExit(main())
