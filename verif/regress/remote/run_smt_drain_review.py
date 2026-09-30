"""Coarse-grained SMT handoff protocol and fault controls.

Copyright (c) 2026 Etienne Cimon
SPDX-License-Identifier: MIT
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    names = ['config_pkg.sv', 'g6lc64_smt2_config_pkg.sv', 'riscv_pkg.sv', 'ariane_pkg.sv',
             'g6lc_thread_select.sv', 'g6lc_core_types.svh', 'rvfi_types.svh',
             'tb_g6lc_rtl_review.sv']
    for name in names:
        shutil.copy2(data / name, source / name)
    fault = os.environ.get('SMT_DRAIN_FAULT') == '1'
    if fault:
        path = source / 'g6lc_thread_select.sv'
        text = path.read_text()
        needle = 'do_switch = drain_ready_i && hart_ready_i[drain_peer_q]'
        if text.count(needle) != 1:
            raise RuntimeError('drain fault site changed')
        path.write_text(text.replace(needle, 'do_switch = hart_ready_i[drain_peer_q]'))
    (out / 'sources.json').write_text(json.dumps({n: hashlib.sha256((source / n).read_bytes()).hexdigest()
                                                 for n in names}, indent=2))
    runtime = os.environ['VERILATOR_ROOT']
    header = Path(runtime) / 'include/verilated_funcs.h'
    if hashlib.sha256(header.read_bytes()).hexdigest() != 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166':
        raise RuntimeError('unqualified simulation runtime')
    top = 'tb_g6lc_review_smt_drain'
    results = []
    for harts, quantum in ((1, 1), (2, 1), (4, 1), (2, 128)):
        work = out / f'h{harts}-q{quantum}'
        work.mkdir()
        commands = [
            ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1',
             '-Wno-fatal', '-Werror-LATCH', '-Werror-UNOPTFLAT', '+define+G6LC_FETCH_B',
             '-I' + str(source), '--top-module', top, f'-GNH={harts}', f'-GQUANTUM={quantum}', '--Mdir', str(work),
             '-o', 'drain', *[str(source / n) for n in names if n.endswith('.sv')]],
            ['make', '-C', str(work), '-f', f'V{top}.mk', '-j4', 'VERILATOR_ROOT=' + runtime]]
        for index, command in enumerate(commands):
            with (work / f'build{index}.log').open('w') as log:
                rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
            if rc:
                raise RuntimeError(f'drain build failed: {work}')
        dependencies = '\n'.join(p.read_text(errors='replace') for p in work.glob('*.d'))
        if str(header) not in dependencies:
            raise RuntimeError('runtime absent from compiler dependencies')
        for scenario in (0, 1):
            for negative in ([False] if fault else [False, True]):
                command = [str(work / 'drain'), f'+scenario={scenario}'] + (['+oracle_negative'] if negative else [])
                log_path = work / f's{scenario}-negative{int(negative)}.log'
                with log_path.open('w') as log:
                    rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=15).returncode
                text = log_path.read_text()
                failed = negative or (fault and harts > 1)
                matched = (rc != 0 and ('SMT_DRAIN_ORACLE' if negative else 'SMT_DRAIN_EARLY') in text) if failed else (
                    rc == 0 and 'RTL_REVIEW_PASS smt_drain' in text)
                results.append({'harts': harts, 'quantum': quantum, 'scenario': scenario, 'negative': negative,
                                'fault': fault, 'rc': rc, 'matched': matched})
                (out / 'results.json').write_text(json.dumps(results, indent=2))
                if not matched:
                    raise RuntimeError(str(results[-1]) + text)
    # N1c bounded drain: resident hart that never commits gets forced; the
    # SMT_DRAIN_NOFORCE build drops the force and must hit SMT_DFORCE_TIMEOUT
    # instead of completing the drain.
    if not fault:
        top_f = 'tb_g6lc_review_smt_drainforce'
        noforce = os.environ.get('SMT_DRAIN_NOFORCE') == '1'
        work = out / 'drainforce'
        work.mkdir()
        defines = ['+define+G6LC_FETCH_B'] + (
            ['+define+G6LC_MUT_DRAIN_NOFORCE'] if noforce else [])
        commands = [
            ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1',
             '-Wno-fatal', '-Werror-LATCH', '-Werror-UNOPTFLAT', *defines,
             '-I' + str(source), '--top-module', top_f, '-GNH=2', '-GFORCE=8',
             '--Mdir', str(work), '-o', 'drainforce',
             *[str(source / n) for n in names if n.endswith('.sv')]],
            ['make', '-C', str(work), '-f', f'V{top_f}.mk', '-j4', 'VERILATOR_ROOT=' + runtime]]
        for index, command in enumerate(commands):
            with (work / f'fbuild{index}.log').open('w') as log:
                rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
            if rc:
                raise RuntimeError(f'drainforce build failed: {work}')
        for scenario in (0, 1, 2):
            log_path = work / f'fs{scenario}.log'
            with log_path.open('w') as log:
                rc = subprocess.run([str(work / 'drainforce'), f'+scenario={scenario}'],
                                    stdout=log, stderr=subprocess.STDOUT, timeout=15).returncode
            text = log_path.read_text()
            matched = (rc != 0 and 'SMT_DFORCE_TIMEOUT' in text) if noforce else (
                rc == 0 and 'RTL_REVIEW_PASS smt_drainforce' in text)
            results.append({'kind': 'drainforce', 'harts': 2, 'scenario': scenario,
                            'noforce': noforce, 'rc': rc, 'matched': matched})
            (out / 'results.json').write_text(json.dumps(results, indent=2))
            if not matched:
                raise RuntimeError(str(results[-1]) + text)
    if not fault:
        wrapper = source / 'smt_drain_synth.sv'
        wrapper.write_text('''module smt_drain_synth(
  input logic clk_i, rst_ni, fetch_fire_i, issue_fire_i, flush_i, hold_i,
  input logic drain_ready_i, commit_i, drain_killable_i, head_wfi_i, head_plain_i,
  input logic [cva6_config_pkg::cva6_cfg.VLEN-1:0] head_pc_i,
  input logic id_uniss_i, iq_valid_i, t0_imm_i, trap_hold_i,
  input logic [cva6_config_pkg::cva6_cfg.NrHarts-1:0] hart_ready_i, hart_dmiss_i, hart_imiss_i, hart_block_i, pause_hint_i,
  output logic [$clog2(cva6_config_pkg::cva6_cfg.NrHarts)-1:0] active_hart_o,
  output logic switch_o, quiesce_o, t0_extra_o, switch_on_miss_o, switch_on_quantum_o, switch_on_starve_o,
  output logic drain_force_o, drain_force_wfi_o, drain_forced_o,
  output logic [cva6_config_pkg::cva6_cfg.VLEN-1:0] drain_force_pc_o
);
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.VLEN=cva6_config_pkg::cva6_cfg.VLEN;
    c.XLEN=cva6_config_pkg::cva6_cfg.XLEN;
    c.NrHarts=cva6_config_pkg::cva6_cfg.NrHarts;
    c.SmtPolicy=cva6_config_pkg::cva6_cfg.SmtPolicy;
    c.SmtFetchQuantum=cva6_config_pkg::cva6_cfg.SmtFetchQuantum;
    c.SmtStarveLimit=cva6_config_pkg::cva6_cfg.SmtStarveLimit;
    c.SmtDrainedHandoff=cva6_config_pkg::cva6_cfg.SmtDrainedHandoff;
    c.SmtDrainForceCycles=cva6_config_pkg::cva6_cfg.SmtDrainForceCycles;
    c.ZihintpauseEn=cva6_config_pkg::cva6_cfg.ZihintpauseEn;
    return c;
  endfunction
  g6lc_thread_select #(.CVA6Cfg(configuration())) dut (.*);
endmodule
''')
        script = out / 'synth.ys'
        script.write_text('read_slang --std 1800-2017 -DG6LC_FETCH_B --top smt_drain_synth '
                          + ' '.join(str(source / n) for n in ('config_pkg.sv', 'g6lc64_smt2_config_pkg.sv',
                                                              'g6lc_thread_select.sv', wrapper.name))
                          + '\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n'
                          + f'write_json {out}/synth.json\n')
        with (out / 'synth.log').open('w') as log:
            rc = subprocess.run(['/opt/testharness/toolchains/formal/bin/yosys', '-s', str(script)],
                                stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
        if rc:
            raise RuntimeError('live-port scheduler synthesis failed')
        cells = json.loads((out / 'synth.json').read_text())['modules']['smt_drain_synth']['cells']
        if not cells or any('latch' in c['type'].lower() for c in cells.values()):
            raise RuntimeError('empty scheduler or inferred latch')
        (out / 'synth-summary.json').write_text(json.dumps({'cells': len(cells), 'latches': 0, 'scc': 0}))
    print(f'SMT_DRAIN_REVIEW matched={len(results)} fault={fault}')


if __name__ == '__main__':
    main()
