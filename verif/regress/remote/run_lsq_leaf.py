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
    source.mkdir(exist_ok=True)
    inputs = []
    hashes = {}
    for name in ['config_pkg.sv', 'g6lc64_smt2_config_pkg.sv', 'riscv_pkg.sv',
                 'ariane_pkg.sv', 'g6lc_ooo_pkg.sv', 'g6lc_lsq.sv',
                 'tb_g6lc_lsq.sv']:
        dest = source / name
        shutil.copy2(next(data.rglob(name)), dest)
        inputs.append(str(dest))
        hashes[name] = digest(dest)
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    verilator = ['verilator', '--binary', '--timing', '--assert', '--threads', '1',
                 '-Wno-fatal', '-Werror-UNOPTFLAT', '-DG6LC_FETCH_B',
                 '--top-module', 'tb_g6lc_lsq']
    builds = [('model', [])]
    # Mutant build: the review-only define drops the LSQ hart tags — every
    # cross-hart isolation scenario must then diverge.
    builds.append(('model-mut', ['-DG6LC_MUT_LSQ_NO_HART']))
    for mdir, extra in builds:
        command = verilator + extra + ['--Mdir', str(out / mdir), '-o', 'lsq-test', *inputs]
        (out / f'command-{mdir}.json').write_text(json.dumps(command, indent=2))
        with (out / f'build-{mdir}.log').open('w') as log:
            build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        if build.returncode:
            print((out / f'build-{mdir}.log').read_text()[-6000:])
            raise RuntimeError(f'lsq leaf build failed ({mdir})')
    passes = [
        (str(out / 'model/lsq-test'), [], 'sim-positive.log',
         lambda rc, text: rc == 0 and text.count('LSQ_HART_PASS') == 1),
        # Inverted expectation: a correct build must flag LSQ_XHART_STALL.
        (str(out / 'model/lsq-test'), ['+oracle_negative'], 'sim-negative.log',
         lambda rc, text: rc != 0 and 'LSQ_XHART_STALL' in text),
        # G6LC_MUT_LSQ_NO_HART drops the hart tags — the same scenario fails
        # on a normal run.
        (str(out / 'model-mut/lsq-test'), [], 'sim-mutant.log',
         lambda rc, text: rc != 0 and 'LSQ_XHART_STALL' in text)]
    for binary, args_extra, log_name, matched in passes:
        run = subprocess.run([binary, *args_extra], capture_output=True, text=True, timeout=30)
        text = run.stdout + run.stderr
        (out / log_name).write_text(text)
        print(text)
        if not matched(run.returncode, text):
            raise RuntimeError('lsq leaf test failed')
    # Synth smoke: hart tagging must not add latches or an empty cone.
    wrapper = source / 'lsq_synth.sv'
    wrapper.write_text('''module lsq_synth(
  input logic clk_i, rst_ni, flush_i,
  input logic [63:0] cancelled_mask_i, sb_live_i,
  input logic [1:0] ld_alloc_i, st_alloc_i,
  input logic [1:0][5:0] alloc_id_i,
  input logic [1:0][0:0] alloc_hart_i,
  input logic [1:0][63:0] alloc_pc_i,
  input logic [1:0] addr_valid_i, addr_is_st_i, st_data_valid_i,
  input logic [1:0][5:0] addr_id_i, st_data_id_i,
  input logic [1:0][55:0] addr_i,
  input logic [1:0][1:0] addr_size_i,
  input logic [1:0][63:0] st_data_i,
  input logic [1:0] complete_valid_i, complete_is_st_i,
  input logic [1:0][5:0] complete_id_i,
  input logic [1:0] commit_st_i,
  input logic [1:0][5:0] commit_id_i,
  input logic [5:0] commit_ptr_i,
  input logic ld_query_i,
  input logic [55:0] ld_query_addr_i,
  input logic [1:0] ld_query_size_i,
  input logic [5:0] ld_query_id_i,
  input logic [0:0] ld_query_hart_i,
  output logic stl_forward_o, stl_stall_o, mem_violation_o, store_pending_o
);
  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64; c.VLEN = 64; c.PLEN = 56; c.NrHarts = 2;
    c.NrCommitPorts = 2; c.NrWbPorts = 2;
    c.NR_SB_ENTRIES = 64; c.TRANS_ID_BITS = 6;
    return c;
  endfunction
  g6lc_lsq #(.CVA6Cfg(cfg())) dut (
    .ld_full_o(), .st_full_o(), .ld_free_o(), .st_free_o(),
    .st_live_mask_o(), .st_unresolved_mask_o(), .st_hart_mask_o(),
    .stl_data_o(), .lsq_busy_o(),
    .mem_violation_id_o(), .mem_violation_pc_o(), .*
  );
endmodule
''')
    script = out / 'synth.ys'
    script.write_text('read_slang --std 1800-2017 -DG6LC_FETCH_B --top lsq_synth '
                      + ' '.join(str(source / n) for n in ('config_pkg.sv',
                                                         'g6lc64_smt2_config_pkg.sv',
                                                         'riscv_pkg.sv',
                                                         'ariane_pkg.sv',
                                                         'g6lc_ooo_pkg.sv',
                                                         'g6lc_lsq.sv',
                                                         wrapper.name))
                      + '\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n'
                      + f'write_json {out}/synth.json\n')
    with (out / 'synth.log').open('w') as log:
        rc = subprocess.run(['/opt/testharness/toolchains/formal/bin/yosys', '-s', str(script)],
                            stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
    if rc:
        raise RuntimeError('lsq synthesis failed')
    cells = json.loads((out / 'synth.json').read_text())['modules']['lsq_synth']['cells']
    if not cells or any('latch' in c['type'].lower() for c in cells.values()):
        raise RuntimeError('empty lsq or latch')
    (out / 'synth-summary.json').write_text(json.dumps({'cells': len(cells), 'latches': 0, 'scc': 0}))


if __name__ == '__main__':
    main()
