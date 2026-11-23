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
import shutil
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
    # All-8-hart census: every mhartid stores a flag, hart0 polls all slots.
    # tohost=0x100|mask names the absent harts -> pinpoints a held physical
    # core that the clock-gated cycprog heartbeat cannot see.
    ('mc_all_harts_present',  'mc_all_harts_present.S',  [], 'pass'),
    # SMT-sibling liveness: hart0 parks after flag-store so core0's thread-1
    # (mhartid1) gets the core; hart1 is the census reader. Distinguishes
    # starvation-under-busy-primary from never-activated sibling.
    ('mc_smt_sibling_yield',  'mc_smt_sibling_yield.S',  [], 'pass'),
    # SMT-sibling liveness probe: hart0 runs a register-only delay (no D$
    # poll stalls) then a single census. Separates "hart1 starved by the
    # memory-poll" from "hart1 never eligible" (smt_hart_seen_q/ipi_i[1]).
    ('mc_smt_sibling_both_present','mc_smt_sibling_both_present.S', [], 'pass'),
    # SMT-sibling liveness probe -- ILP variant: hart0 delays with 4 independent
    # counters (backend ILP keeps the IF->ID fetch accept flowing) instead of a
    # serially-dependent countdown that saturates the OoO backend. If hart1 then
    # stores flags[1], the starvation is fetch-quantum freeze under backend
    # pressure, not an eligibility/seen bug.
    ('mc_smt_sibling_ilp',     'mc_smt_sibling_ilp.S',     [], 'pass'),
    ('mini_ipi_hart1_sp',     'mini_ipi_hart1_sp.S',     [], 'pass'),
    ('mini_wfi_noipi_hart1',  'mini_wfi_noipi_hart1.S',  [], 'pass'),
    # Sleep-gate witness (CoreSleepGate=1 builds, e.g. g6lc64_hyp8_mc_sleep):
    # CLINT mtimecmp, Sstc stimecmp and cross-core IPI wakes of fully gated
    # cores, plus permanent gating of parked harts ([sleep] counters).
    # On gate-less models the same program is the functional/RVFI reference.
    ('mc_sleep_gate_wake',   'mc_sleep_gate_wake.S',   [], 'pass'),
    # --- shared-line / coherence ------------------------------------------
    ('mc_shared_line_xcore',  'mc_shared_line_coherence.S', ['-DPEER_HART=2'], 'pass'),
    ('mc_shared_line_sibling','mc_shared_line_coherence.S', ['-DPEER_HART=1'], 'pass'),
    ('mc_shared_line_quiet',  'mc_shared_line_quiet.S',   [], 'pass'),
    ('mc_shared_line_resident','mc_shared_line_resident.S', ['-DPEER_HART=2'], 'pass'),
    ('mc_multi_writer_line',  'mc_multi_writer_line.S',   [], 'pass'),
    ('mc_l2_write_read',      'mc_l2_write_read.S',       [], 'pass'),
    ('mc_l3_evict_inclusion','mc_l3_evict_inclusion.S',   [], 'pass'),
    ('mc_l3_stride_scan',     'mc_l3_stride_scan.S',      [], 'pass'),
    ('mc_two_inval_backpressure','mc_two_inval_backpressure.S', ['-DPEER_HART=2'], 'pass'),
    ('mc_store_load_new_line','mc_store_load_new_line.S', [], 'pass'),
    ('mc_cbo_contended',      'mc_cbo_contended.S',       [], 'pass'),
    ('mc_cbo_ewt',            'mc_cbo_ewt.S',             [], 'pass'),
    ('mc_cbo_zero_probe',     'mc_cbo_zero_probe.S',      [], 'pass'),
    # --- OoO store-queue / speculation / eWT / L2 (isolated coverage) ---------
    # Bare-metal self-checking probes shared with the DI/soft-ladder suites;
    # they pin the same OoO LSQ/WT-dcache/L2-L3 mechanisms the ooo_mem_min
    # STAGE=17..52 cases exercise on g6lc64_ooo_server, on the 8-hart boot part.
    # mini_spo_st_fwd: same-core speculative store->load forward (OoO RAW).
    ('mini_spo_st_fwd',       'mini_spo_st_fwd.S',         [], 'pass'),
    # mini_stq_*: store-queue forwarding/flush under alias, mispredict and an
    # SMT sibling doing store bursts + AMOs (OpenSBI offset_ptr/getprop shapes;
    # I16/I17/I22). mini_stq_alias_jal parks hart1 (shared-SP race otherwise).
    ('mini_stq_alias_jal',    'mini_stq_alias_jal.S',      [], 'pass'),
    ('mini_stq_flush_fwd',    'mini_stq_flush_fwd.S',      [], 'pass'),
    ('mini_stq_press_smt',    'mini_stq_press_smt.S',      [], 'pass'),
    # mc_wrongpath_window: T19 two-hart wrong-path I$ install window (the
    # ooocoh-t18 boot failure shape) on the dual-hart SMT cores.
    ('mc_wrongpath_window',   'mc_wrongpath_window.S',     [], 'pass'),
    # mini_wt_delay_ld: write-through write-around / dropped wr_ack (eWT).
    ('mini_wt_delay_ld',      'mini_wt_delay_ld.S',        [], 'pass'),
    # mini_l2set_stride / mini_l2_hot_scan: L2/L3 set-conflict churn + hot-scan
    # replacement (bisect pair for mc_l3_evict_inclusion).
    ('mini_l2set_stride',     'mini_l2set_stride.S',       [], 'pass'),
    ('mini_l2_hot_scan',      'mini_l2_hot_scan.S',        [], 'pass'),
    # mc_chase / mc_branchy: pointer-chase DRAM/L2/L3 latency chain + branchy
    # speculation pressure (single active hart, peers park). mc_branchy runs
    # two ITER passes at ~19 instr/round; default ITER=65536 needs ~19M cycles
    # on hyp8 (ipc~0.13 under ~50% data-dependent mispredicts) — ITER=4096 keeps
    # ~12k branch outcomes while fitting the standard 1.5-2M suite budget.
    ('mc_chase',              'mc_chase.S',                [], 'pass'),
    ('mc_branchy',            'mc_branchy.S',              ['-DITER=4096'], 'pass'),
    # --- LR/SC / AMO / atomics --------------------------------------------
    ('mc_lrsc_set_zombie',    'mc_lrsc_set_zombie.S',     [], 'pass'),
    ('mini_lrsc_d',           'mini_lrsc_d.S',            [], 'pass'),
    ('mini_amoadd_w_spin',    'mini_amoadd_w_spin.S',     [], 'pass'),
    # Za64rs reservation independence: peer store to a nearby-but-different
    # address (same 64B window) must NOT kill LR.A's reservation (phase 1),
    # while a same-address store MUST (phase 2 control). Needs 2 cores.
    ('mc_za64rs_independence','mc_za64rs_independence.S', [], 'pass'),
    # AMOCAS.D/.W (Zacas) — RFIX-131a-16 CASD rd=0 forced-UC fix coverage on the
    # coherent hpdcache path. All soft-skip (tohost=1) when AMOCAS is illegal,
    # so kind='pass' is correct whether they skip or really run the CAS.
    ('mini_amocas_d',         'mini_amocas_d.S',          [], 'pass'),
    ('zacas_amocas_d',        'zacas_amocas_d.S',         [], 'pass'),
    ('mc_amo_ld_order',       'mc_amo_ld_order.S',        [], 'pass'),
    ('zacas_amocas_w',        'zacas_amocas_w.S',         [], 'pass'),
    ('mc_cas_lock_handoff',   'mc_cas_lock_handoff.S',    [], 'pass'),
    ('mc_spo_cas_stream',     'mc_spo_cas_stream.S',      [], 'pass'),
    # --- FP / multi-port OoO stress -----------------------------------------
    ('mc_fp_alu2_stress',     'mc_fp_alu2_stress.S',      [], 'pass'),
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
    # --- S-mode / virtual memory (OpenWrt-boot SMP coverage) -----------------
    # hyp8_sv39_load proves S-mode SV39 on one hart; these put ALL harts in
    # S-mode under a shared page table and hammer sfence.vma/PTW/AMO — the path
    # a Linux SMP boot exercises and the g6lc_tlb_hit_onehot0 suspect guards.
    ('mc_smode_parallel',     'mc_smode_parallel.S',      [], 'pass'),
    # Real SMP TLB shootdown: hart0 remaps shared page-table entries while the
    # other harts hold stale translations; each must sfence.vma and observe the
    # new mapping. Targets g6lc_tlb_hit_onehot0 / PTW invalidate path.
    ('mc_smode_shootdown',    'mc_smode_shootdown.S',     [], 'pass'),
    # DIAG probe: pt1[] leaf PTEs = sentinel 0x1122334455667788 so the
    # [ptw-err] pte field reveals which physical qword the lvl2 PTW read
    # actually returns (right-addr-wrong-data vs wrong-address).
    ('mc_smode_ptprobe',      'mc_smode_ptprobe.S',       [], 'oracle_neg'),
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
               'nativeTuning': results['build'].get('nativeTuning'),
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
        entry['tohost'] = '0x' + format(int(tohost[0].split()[0], 16), 'x')
        log = out / f'{name}.log'
        # Line-buffer stdout so long tests stream [cycprog]/diagnostics live
        # instead of sitting in a block buffer until exit (see witness runner).
        model_cmd = (['stdbuf', '-oL'] if shutil.which('stdbuf') else []) + [str(model)]
        run_cmd = [*model_cmd, f"+tohost_addr={entry['tohost']}", '+debug_disable',
                   f'+max-cycles={budget}', *extra, str(elf)]
        timed_out = False
        try:
            with log.open('w') as fh:
                p = subprocess.run(run_cmd, stdout=fh, stderr=subprocess.STDOUT,
                                   cwd=out, timeout=7200)
        except subprocess.TimeoutExpired:
            # A wall-clock kill is not a verdict: record it and keep going so
            # one heavy test (e.g. mini_l2_hot_scan) cannot lose the whole
            # suite's results. `final` never ran, so there is no progExit.
            timed_out = True
            p = subprocess.CompletedProcess(run_cmd, 124, '', '')
        text = log.read_text(errors='replace') if log.is_file() else ''
        verdict = [l for l in text.splitlines() if '***' in l]
        m = re.search(r'\*\*\* SUCCESS \*\*\*.*after (\d+) cycles', text)
        fail = re.search(r'\*\*\* FAILED \*\*\*.*tohost = (\S+)', text)
        tohost_val = fail.group(1) if fail else None
        bus_err = len(re.findall(r'Response Errored', text))
        uart_rd = len(re.findall(r'^\[uart-axi-ar\]', text, re.M))
        walk_err = len(re.findall(r'^\[(?:ptw-err|mmu-ife)\]', text, re.M))
        model_err = len(re.findall(r'%Error', text))
        # mc_verdict overlay: a test that ends before the 200k-cycle BOOT_HOLD
        # releases secondary cores is forced to exit 125 even when the ELF
        # itself succeeded. Surface the ELF's real exit code + held/retired
        # masks so a held-125 is not misread as an RTL failure.
        pe = re.search(r'program exit code (\d+)', text)
        hm = re.search(r'HELD:.*held_mask=([01]+)\s+retired_mask=([01]+)', text)
        prog_exit = int(pe.group(1)) if pe else None
        held_mask = hm.group(1) if hm else None
        retired_mask = hm.group(2) if hm else None
        # The model overlays a held(125)/hung(126)/silent(127) exit code on top
        # of a completed primary tohost write; `program exit code` is the ELF's
        # authoritative result (tracer_exit[31:1]). Grade on progExit, not on
        # the overlay banner -- a held-125 with progExit=0 is a pass, while a
        # hung(126)/silent-unheld(127) peer is a real multicore anomaly.
        budget_cap = 'cycle budget reached' in text
        peer_hung = 'stopped retiring' in text        # mc_any_hung -> exit 126
        peer_silent = 'retired no instruction' in text  # non-held silent -> 127
        peer_held = 'still clock-held' in text          # held peers -> 125 (benign)
        peer_bad = peer_hung or peer_silent
        if timed_out:
            state = 'timeout'
        elif budget_cap:
            state = 'wedged'          # +max-cycles cap, no tohost verdict
        elif peer_bad:
            state = 'peer_anomaly'    # ELF may exit 0 but a peer hung/never-ran
        elif prog_exit is not None:
            state = 'pass' if prog_exit == 0 else 'fail'
        elif m:
            state = 'pass'
        elif fail:
            state = 'fail'
        else:
            state = 'wedged'
        if state == 'pass' and (bus_err or uart_rd or model_err):
            state = 'log_dirty'
        # oracle-negative: the deliberate fail code is the discrimination proof.
        # Prefer the ELF's progExit; fall back to the banner tohost value.
        oracle_code = prog_exit
        if oracle_code is None and tohost_val is not None:
            try:
                oracle_code = int(tohost_val)
            except ValueError:
                oracle_code = None
        oracle = ''
        if kind == 'oracle_neg':
            oracle = 'oracle_ok' if (state == 'fail' and oracle_code not in (None, 0)) else 'oracle_bad'
        cyc_m = re.search(r'\*\*\* (?:SUCCESS|FAILED) \*\*\*.*after (\d+) cycles', text)
        cycles = int(cyc_m.group(1)) if cyc_m else None
        entry.update({'state': state, 'kind': kind, 'oracle': oracle,
                      'progExit': prog_exit, 'heldMask': held_mask,
                      'retiredMask': retired_mask, 'peerHeld': peer_held,
                      'tohostVal': tohost_val, 'cycles': cycles,
                      'busErrors': bus_err, 'uartReads': uart_rd,
                      'walkErrors': walk_err, 'modelErrors': model_err,
                      'verdict': verdict[-1:] if verdict else [],
                      'log': log.name, 'argv': run_cmd})
        # a pass-kind test that fails/wedges/anomalies, or an oracle that
        # doesn't discriminate, is a suite failure; info never gates.
        bad = (kind == 'pass' and state != 'pass') or \
              (kind == 'oracle_neg' and oracle != 'oracle_ok')
        if bad:
            rc_all = 1
        summary['tests'][name] = entry
        # Write incrementally: a later crash/kill must not lose earlier verdicts.
        blob = json.dumps(summary, indent=2)
        (out / 'mc-directed-results.json').write_text(blob)
        (out / 'smokes-results.json').write_text(blob)
        print(f"{name}: {state}{('/' + oracle) if oracle else ''} "
              f"cycles={cycles} tohost={tohost_val} progExit={prog_exit} "
              f"rc={p.returncode} "
              f"bus_err={bus_err} uart_rd={uart_rd} walk_err={walk_err} model_err={model_err}",
              flush=True)
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
