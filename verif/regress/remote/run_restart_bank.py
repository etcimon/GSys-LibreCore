#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
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
    inputs = []
    hashes = {}
    for name in ['config_pkg.sv', 'g6lc_smt_pc_bank.sv', 'tb_g6lc_restart.sv']:
        dest = source / name
        shutil.copy2(data / name, dest)
        inputs.append(str(dest))
        hashes[name] = hashlib.sha256(dest.read_bytes()).hexdigest()
    fault = os.environ.get('RESTART_BANK_FAULT') == '1'
    if fault:
        path = source / 'g6lc_smt_pc_bank.sv'
        text = path.read_text()
        needle = '        if (redirect_valid_i)\n'
        if text.count(needle) != 1:
            raise RuntimeError('restart mutation site changed')
        text = text.replace(needle, '        if (switch_i && npc_live_valid_i) npc_bank_q[prev_hart_q] <= npc_live_i;\n' + needle)
        path.write_text(text)
        hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    command = ['verilator', '--binary', '--timing', '--assert', '--threads', '1', '-Wno-fatal', '-Werror-LATCH', '-Werror-UNOPTFLAT', '-DG6LC_FETCH_B', '--top-module', 'tb_g6lc_restart', '--Mdir', str(out / 'model'), '-o', 'restart-test', *inputs]
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    (out / 'command.json').write_text(json.dumps(command, indent=2))
    with (out / 'build.log').open('w') as log:
        build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    if build.returncode:
        print((out / 'build.log').read_text()[-6000:])
        raise RuntimeError('restart bank build failed')
    before = os.environ.get('RESTART_BANK_BEFORE') == '1'
    for negative in ([False] if before or fault else [False, True]):
        args = [str(out / 'model/restart-test')] + (['+oracle_negative'] if negative else [])
        run = subprocess.run(args, capture_output=True, text=True, timeout=30)
        text = run.stdout + run.stderr
        (out / f'sim-negative{int(negative)}.log').write_text(text)
        print(text)
        matched = (run.returncode != 0 and 'RESTART_ARCH_PC' in text) if before or fault or negative else (
            run.returncode == 0 and text.count('RESTART_BANK_PASS') == 1)
        if not matched:
            raise RuntimeError('restart bank test failed')
    if not before and not fault:
        wrapper = source / 'pc_bank_synth.sv'
        wrapper.write_text('''module pc_bank_synth(
  input logic clk_i, rst_ni, active_hart_i, switch_i, redirect_valid_i, redirect_hart_i,
  input logic [63:0] boot_addr_i, redirect_pc_i,
  input logic [1:0] retire_valid_i, retire_hart_i,
  input logic [1:0][63:0] retire_pc_i,
  output logic [63:0] npc_restore_o,
  output logic restore_o, outgoing_hart_o
);
  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64; c.VLEN=64; c.NrHarts=2; c.NrCommitPorts=2;
    return c;
  endfunction
  g6lc_smt_pc_bank #(.CVA6Cfg(cfg())) dut (
    .npc_live_i('0),.npc_live_valid_i(1'b0),.npc_alt_i('0),.npc_alt_valid_i(1'b0),.*
  );
endmodule
''')
        script = out / 'synth.ys'
        script.write_text('read_slang --std 1800-2017 -DG6LC_FETCH_B --top pc_bank_synth '
                          + ' '.join(str(source / n) for n in ('config_pkg.sv', 'g6lc_smt_pc_bank.sv', wrapper.name))
                          + '\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n'
                          + f'write_json {out}/synth.json\n')
        with (out / 'synth.log').open('w') as log:
            rc = subprocess.run(['/opt/testharness/toolchains/formal/bin/yosys', '-s', str(script)],
                                stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
        if rc:
            raise RuntimeError('PC bank synthesis failed')
        cells = json.loads((out / 'synth.json').read_text())['modules']['pc_bank_synth']['cells']
        if not cells or any('latch' in c['type'].lower() for c in cells.values()):
            raise RuntimeError('empty PC bank or latch')
        (out / 'synth-summary.json').write_text(json.dumps({'cells': len(cells), 'latches': 0, 'scc': 0}))


if __name__ == '__main__':
    main()
