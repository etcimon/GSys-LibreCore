"""Directed issue-order contract with matched source and oracle fault controls.

Copyright (c) 2026 Etienne Cimon
SPDX-License-Identifier: MIT
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    names = ['config_pkg.sv', 'g6lc64_smt2_config_pkg.sv', 'riscv_pkg.sv',
             'ariane_pkg.sv', 'g6lc_sb_keep.sv', 'g6lc_issue_barrier.sv',
             'g6lc_core_types.svh', 'tb_g6lc_rtl_review.sv']
    for name in names:
        shutil.copy2(data / name, source / name)
    before = os.environ.get('ISSUE_ORDER_BEFORE') == '1'
    fault = os.environ.get('ISSUE_ORDER_FAULT') == '1'
    if before and fault:
        raise ValueError('choose before or fault, not both')
    if fault:
        path = source / 'g6lc_issue_barrier.sv'
        text = path.read_text()
        new = '            if (o < p &&\n                issue_valid_sb_i[o] &&\n                issue_instr_sb_i[o].hart_id == issue_instr_sb_i[p].hart_id &&\n                is_addi_sp(issue_instr_sb_i[o])) begin'
        old = '            if (o != p &&\n                issue_valid_sb_i[o] &&\n                issue_instr_sb_i[o].hart_id == issue_instr_sb_i[p].hart_id &&\n                is_addi_sp(issue_instr_sb_i[o]) &&\n                issue_instr_sb_i[o].pc < issue_instr_sb_i[p].pc) begin'
        if text.count(new) != 1:
            raise RuntimeError('issue-order mutation site changed')
        path.write_text(text.replace(new, old))
    hashes = {name: digest(source / name) for name in names}
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    runtime = Path(os.environ['VERILATOR_ROOT'])
    header = runtime / 'include/verilated_funcs.h'
    if digest(header) != 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166':
        raise RuntimeError('unqualified simulation runtime')
    top = 'tb_g6lc_review_issue_order'
    results = []
    for ports, harts in ((2, 2), (2, 1), (4, 2)):
        work = out / f'p{ports}-h{harts}'
        work.mkdir()
        cmd = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1',
               '-Wno-fatal', '-Werror-LATCH', '-Werror-UNOPTFLAT', '+define+G6LC_FETCH_B',
               '-I' + str(source), '--top-module', top, f'-GNP={ports}', f'-GHARTS={harts}',
               '--Mdir', str(work), '-o', 'issue-order',
               *[str(source / name) for name in names if not name.endswith('.svh')]]
        for label, command in [('verilate', cmd), ('build', ['make', '-C', str(work),
                '-f', f'V{top}.mk', '-j4', 'VERILATOR_ROOT=' + str(runtime)])]:
            (work / (label + '.json')).write_text(json.dumps(command))
            with (work / (label + '.log')).open('w') as log:
                rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
            if rc:
                raise RuntimeError(f'{label} failed: {work}')
        dependencies = '\n'.join(p.read_text(errors='replace') for p in work.glob('*.d'))
        if str(header) not in dependencies:
            raise RuntimeError('runtime not present in compiler dependencies')
        exe = work / 'issue-order'
        trials = [(s, False) for s in range(6)]
        if not (before or fault):
            trials += [(s, True) for s in range(6)]
        for scenario, negative in trials:
            expected_failure = negative or ((before or fault) and scenario in (0, 1))
            command = [str(exe), f'+scenario={scenario}'] + (['+oracle_negative'] if negative else [])
            log_path = work / f's{scenario}-negative{int(negative)}.log'
            with log_path.open('w') as log:
                rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=15).returncode
            text = log_path.read_text(errors='replace')
            matched = (rc != 0 and 'ISSUE_PROGRAM_ORDER' in text) if expected_failure else (
                rc == 0 and 'RTL_REVIEW_PASS issue_order' in text)
            results.append({'ports': ports, 'harts': harts, 'scenario': scenario, 'negative': negative,
                            'expectedFailure': expected_failure, 'rc': rc, 'matched': matched,
                            'executableSha256': digest(exe)})
            (out / 'results.json').write_text(json.dumps(results, indent=2))
            if not matched:
                raise RuntimeError(f'unexpected result: {results[-1]} {text}')
    if os.environ.get('ISSUE_ORDER_SYNTH') == '1':
        bench = (source / 'tb_g6lc_rtl_review.sv').read_text()
        types = bench.split('module tb_g6lc_review_issue_order;', 1)[1].split('  logic clk=', 1)[0]
        types = types.replace('parameter int NP=2, HARTS=2;', 'localparam int NP=2, HARTS=2;')
        wrapper = source / 'issue_order_synth.sv'
        wrapper.write_text('package issue_order_synth_pkg;\n' + types + '''endpackage
module issue_order_synth_top
  import issue_order_synth_pkg::*;
(
  input logic clk_i, rst_ni, flush_i, flush_unissued_instr_i,
  input logic [NP-1:0] issue_valid_sb_i, issue_ack_iro_i, decoded_instr_valid_i,
  input sbe_t [NP-1:0] issue_instr_sb_i, decoded_instr_i,
  input logic resolve_branch_i,
  input resolve_t resolved_branch_i,
  input logic [1:0] commit_ack_i,
  input sbe_t [1:0] commit_instr_i,
  input logic g1fh_csr_a0_i, g1fh_hart_i,
  output logic [NP-1:0] issue_valid_o
);
  g6lc_issue_barrier #(.CVA6Cfg(C), .scoreboard_entry_t(sbe_t),
                      .bp_resolve_t(resolve_t)) dut (.*);
endmodule
''')
        rtl = [str(source / name) for name in names if name.endswith('.sv') and not name.startswith('tb_')]
        script = out / 'synth.ys'
        script.write_text('read_slang --std 1800-2017 -DG6LC_FETCH_B --top issue_order_synth_top '
                          + ' '.join(rtl + [str(wrapper)]) + '\n'
                          + 'hierarchy -check -top issue_order_synth_top\nproc\nflatten\nopt\ncheck -assert\nstat\n'
                          + 'write_json ' + str(out / 'netlist.json') + '\n')
        with (out / 'synth.log').open('w') as log:
            rc = subprocess.run(['/opt/testharness/toolchains/formal/bin/yosys', '-s', str(script)],
                                stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
        if rc:
            raise RuntimeError('issue-order synthesis failed')
        cells = json.loads((out / 'netlist.json').read_text())['modules']['issue_order_synth_top']['cells']
        if not cells or any('latch' in cell['type'].lower() for cell in cells.values()):
            raise RuntimeError('empty netlist or inferred latch')
        (out / 'synthesis.json').write_text(json.dumps({'cells': len(cells), 'latches': 0, 'rc': rc,
                                                      'scope': 'two-port two-hart live-port leaf only'}))
    print(f'ISSUE_ORDER_REVIEW matched={len(results)} before={before} fault={fault}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
