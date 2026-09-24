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
                 'ariane_pkg.sv', 'compressed_decoder.sv', 'macro_decoder.sv',
                 'zcmt_decoder.sv', 'cvxif_compressed_if_driver.sv',
                 'decoder.sv', 'id_stage.sv', 'tb_g6lc_idstage.sv']:
        dest = source / name
        shutil.copy2(next(data.rglob(name)), dest)
        inputs.append(str(dest))
        hashes[name] = digest(dest)
    # DPI stub for id_stage's translate_off g6lc_dram_peek64 import.
    stub = source / 'g6lc_dram_peek64_stub.cpp'
    shutil.copy2(next(data.rglob('g6lc_dram_peek64_stub.cpp')), stub)
    inputs.append(str(stub))
    hashes[stub.name] = digest(stub)
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    verilator = ['verilator', '--binary', '--timing', '--assert', '--threads', '1',
                 '-Wno-fatal', '-DG6LC_FETCH_B',
                 '--top-module', 'tb_g6lc_idstage']
    builds = [('model', [])]
    # Mutant build: the review-only define routes every decode lane's
    # interrupt context to the active hart — a resident peer vectors on an
    # interrupt that is not its own.
    builds.append(('model-mut', ['-DG6LC_MUT_DECODE_ACTIVE_IRQ']))
    for mdir, extra in builds:
        command = verilator + extra + ['--Mdir', str(out / mdir), '-o', 'idstage-test', *inputs]
        (out / f'command-{mdir}.json').write_text(json.dumps(command, indent=2))
        with (out / f'build-{mdir}.log').open('w') as log:
            build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=300)
        if build.returncode:
            print((out / f'build-{mdir}.log').read_text()[-6000:])
            raise RuntimeError(f'idstage leaf build failed ({mdir})')
    passes = [
        (str(out / 'model/idstage-test'), [], 'sim-positive.log',
         lambda rc, text: rc == 0 and text.count('IDSTAGE_IRQ_PASS') == 1),
        # Inverted expectation: a correct build must flag DECODE_ACTIVE_IRQ.
        (str(out / 'model/idstage-test'), ['+oracle_negative'], 'sim-negative.log',
         lambda rc, text: rc != 0 and 'DECODE_ACTIVE_IRQ' in text),
        # G6LC_MUT_DECODE_ACTIVE_IRQ restores the active-hart context — the
        # same scenario fails on a normal run.
        (str(out / 'model-mut/idstage-test'), [], 'sim-mutant.log',
         lambda rc, text: rc != 0 and 'DECODE_ACTIVE_IRQ' in text)]
    for binary, args_extra, log_name, matched in passes:
        run = subprocess.run([binary, *args_extra], capture_output=True, text=True, timeout=30)
        text = run.stdout + run.stderr
        (out / log_name).write_text(text)
        print(text)
        if not matched(run.returncode, text):
            raise RuntimeError('idstage leaf test failed')
    # Synth smoke: the per-hart decode context must not add latches.
    wrapper = source / 'idstage_synth.sv'
    wrapper.write_text('''module idstage_synth;
  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64; c.VLEN = 64; c.PLEN = 56; c.GPLEN = 56; c.RVC = 1;
    c.NrHarts = 2; c.NrIssuePorts = 2; c.SuperscalarEn = 1;
    c.NrCommitPorts = 2; c.NrWbPorts = 2;
    c.NR_SB_ENTRIES = 64; c.TRANS_ID_BITS = 6; c.SmtDrainedHandoff = 0;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t CFG = cfg();
  typedef struct packed {
    logic [CFG.XLEN-1:0] mie, mip, mideleg, hideleg;
    logic sie, global_enable;
  } irq_ctrl_t;
  logic [1:0] lane_hart;
  irq_ctrl_t irq_ctrl_i;
  irq_ctrl_t [1:0] irq_ctrl_b_i;
  logic [1:0][1:0] irq_b_i, irq_i;
  logic [1:0] sel0;
  assign lane_hart = 2'b10;
  // The seam under test: per-lane context select.
  assign sel0[0] = |(irq_ctrl_b_i[lane_hart[0]].mip & irq_ctrl_b_i[lane_hart[0]].mie);
  assign sel0[1] = |(irq_b_i[lane_hart[1]]);
endmodule
''')
    script = out / 'synth.ys'
    script.write_text('read_slang --std 1800-2017 -DG6LC_FETCH_B --top idstage_synth '
                      + ' '.join(str(source / n) for n in ('config_pkg.sv',
                                                         'g6lc64_smt2_config_pkg.sv',
                                                         'riscv_pkg.sv',
                                                         'ariane_pkg.sv',
                                                         wrapper.name))
                      + '\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n'
                      + f'write_json {out}/synth.json\n')
    with (out / 'synth.log').open('w') as log:
        rc = subprocess.run(['/opt/testharness/toolchains/formal/bin/yosys', '-s', str(script)],
                            stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
    if rc:
        raise RuntimeError('idstage synthesis failed')
    cells = json.loads((out / 'synth.json').read_text())['modules']['idstage_synth']['cells']
    if cells is None or any('latch' in c['type'].lower() for c in cells.values()):
        raise RuntimeError('empty idstage or latch')
    (out / 'synth-summary.json').write_text(json.dumps({'cells': len(cells or {}), 'latches': 0, 'scc': 0}))


if __name__ == '__main__':
    main()
