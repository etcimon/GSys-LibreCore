#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Generic live-port IQ screening; not physical area or STA."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    names = ['config_pkg.sv','g6lc64_smt2_config_pkg.sv','riscv_pkg.sv','ariane_pkg.sv',
             'g6lc_fetch_pkg.sv','cva6_fifo_v3.sv','instr_queue.sv','tb_g6lc_fetch_queue.sv']
    hashes = {}
    for name in names:
        shutil.copy2(data/name, source/name)
        hashes[name] = hashlib.sha256((source/name).read_bytes()).hexdigest()
    bench = (source/'tb_g6lc_fetch_queue.sv').read_text()
    declarations = bench.split('  logic clk =',1)[0].split('module tb_g6lc_fetch_queue;\n',1)[1]
    instance = bench.split('  instr_queue #',1)[1].split('\n  );',1)[0]
    wrapper = '''module g6lc_fetch_queue_synth (
  input logic clk, rst_n, flush,
  input logic hart,
  input logic [3:0][31:0] instr,
  input logic [3:0][63:0] addr,
  input logic [3:0] valid,
  input ariane_pkg::cf_t [3:0] cf,
  input logic [1:0] entry_ready,
  output logic [3:0] consumed,
  output logic ready, replay,
  output logic [63:0] replay_addr,
  output logic [1:0] entry_valid,
  output logic [1023:0] observed_o
);
'''+declarations+'''  entry_t [ISSUE-1:0] entry;
  assign observed_o = 1024'(entry);
  instr_queue #'''+instance+'\n  );\nendmodule\n'
    (source/'fixture.sv').write_text(wrapper)
    inputs = ' '.join(names[:-1] + ['fixture.sv'])
    script = f'read_slang --ignore-assertions --ignore-initial --top g6lc_fetch_queue_synth {inputs}\n'
    script += 'synth -top g6lc_fetch_queue_synth\ncheck -assert\nselect -assert-none t:$_DLATCH_*\nstat\n'
    (source/'screen.ys').write_text(script)
    with (out/'synth.log').open('w') as log:
        proc = subprocess.run(['yosys','-s','screen.ys'],cwd=source,
                              stdout=log,stderr=subprocess.STDOUT,timeout=180)
    (out/'sources.json').write_text(json.dumps(hashes,indent=2))
    print((out/'synth.log').read_text()[-7000:])
    return proc.returncode


if __name__ == '__main__':
    sys.exit(main())
