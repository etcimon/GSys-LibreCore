#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    inputs = []
    hashes = {}
    for name in ['config_pkg.sv', 'g6lc64_smt2_config_pkg.sv', 'riscv_pkg.sv',
                 'ariane_pkg.sv', 'controller.sv', 'tb_g6lc_ctrl.sv']:
        dest = source / name
        shutil.copy2(data / name, dest)
        inputs.append(str(dest))
        hashes[name] = digest(dest)
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    verilator = ['verilator', '--binary', '--timing', '--assert', '--threads', '1',
                 '-Wno-fatal', '-Werror-LATCH', '-Werror-UNOPTFLAT', '-DG6LC_FETCH_B',
                 '--top-module', 'tb_g6lc_ctrl']
    builds = [('model', [])]
    # Mutant build: the review-only define restores the degraded switch
    # override — the eret&&switch scenario must fail with CTRL_SWITCH_ERET.
    builds.append(('model-mut', ['-DG6LC_MUT_CTRL_SWITCH_DEGRADES']))
    for mdir, extra in builds:
        command = verilator + extra + ['--Mdir', str(out / mdir), '-o', 'ctrl-test', *inputs]
        (out / f'command-{mdir}.json').write_text(json.dumps(command, indent=2))
        with (out / f'build-{mdir}.log').open('w') as log:
            build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        if build.returncode:
            print((out / f'build-{mdir}.log').read_text()[-6000:])
            raise RuntimeError(f'controller leaf build failed ({mdir})')
    passes = [
        (str(out / 'model/ctrl-test'), [], 'sim-positive.log',
         lambda rc, text: rc == 0 and text.count('CTRL_BANK_PASS') == 1),
        # Inverted expectation: a correct build must flag CTRL_SWITCH_ERET.
        (str(out / 'model/ctrl-test'), ['+oracle_negative'], 'sim-negative.log',
         lambda rc, text: rc != 0 and 'CTRL_SWITCH_ERET' in text),
        # G6LC_MUT_CTRL_SWITCH_DEGRADES restores the old override — the same
        # scenario fails on a normal run.
        (str(out / 'model-mut/ctrl-test'), [], 'sim-mutant.log',
         lambda rc, text: rc != 0 and 'CTRL_SWITCH_ERET' in text)]
    for binary, args_extra, log_name, matched in passes:
        run = subprocess.run([binary, *args_extra], capture_output=True, text=True, timeout=30)
        text = run.stdout + run.stderr
        (out / log_name).write_text(text)
        print(text)
        if not matched(run.returncode, text):
            raise RuntimeError('controller leaf test failed')
    # Synth smoke: the guard must not add latches or an empty cone.
    wrapper = source / 'ctrl_synth.sv'
    wrapper.write_text('''module ctrl_synth(
  input logic clk_i, rst_ni, eret_i, ex_valid_i, smt_switch_i, flush_csr_i,
  input logic fence_i_i, fence_i, sfence_vma_i, hfence_vvma_i, hfence_gvma_i,
  input logic flush_commit_i, flush_acc_i, set_debug_pc_i,
  output logic flush_id_o, flush_ex_o, flush_if_o, flush_unissued_instr_o
);
  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64; c.VLEN = 64; c.NrHarts = 2; c.NrCommitPorts = 2;
    return c;
  endfunction
  typedef struct packed {
    logic valid; logic [63:0] pc; logic [63:0] target_address;
    logic is_mispredict; logic is_taken; ariane_pkg::cf_t cf_type;
    logic hart_id; logic ckpt_restore; logic [7:0] trans_id;
  } bp_resolve_t;
  controller #(.CVA6Cfg(cfg()), .bp_resolve_t(bp_resolve_t)) dut (
    .v_i(1\'b0), .set_pc_commit_o(), .flush_bp_o(), .flush_icache_o(),
    .flush_dcache_o(), .flush_dcache_ack_i(1\'b0), .flush_tlb_o(),
    .flush_tlb_vvma_o(), .flush_tlb_gvma_o(), .halt_csr_i(1\'b0),
    .halt_acc_i(1\'b0), .halt_frontend_o(), .halt_o(),
    .resolved_branch_i(\'0), .replay_i(1\'b0), .mem_replay_pc_o(), .*
  );
endmodule
''')
    script = out / 'synth.ys'
    script.write_text('read_slang --std 1800-2017 -DG6LC_FETCH_B --top ctrl_synth '
                      + ' '.join(str(source / n) for n in ('config_pkg.sv',
                                                         'g6lc64_smt2_config_pkg.sv',
                                                         'riscv_pkg.sv',
                                                         'ariane_pkg.sv', 'controller.sv',
                                                         wrapper.name))
                      + '\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n'
                      + f'write_json {out}/synth.json\n')
    with (out / 'synth.log').open('w') as log:
        rc = subprocess.run(['/opt/testharness/toolchains/formal/bin/yosys', '-s', str(script)],
                            stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
    if rc:
        raise RuntimeError('controller synthesis failed')
    cells = json.loads((out / 'synth.json').read_text())['modules']['ctrl_synth']['cells']
    if not cells or any('latch' in c['type'].lower() for c in cells.values()):
        raise RuntimeError('empty controller or latch')
    (out / 'synth-summary.json').write_text(json.dumps({'cells': len(cells), 'latches': 0, 'scc': 0}))


if __name__ == '__main__':
    main()
