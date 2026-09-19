"""Probe valid NAPOT configuration transitions with existing PMP assertions enabled.

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
    data, out = Path(os.environ['TH_DATA_DIR']), Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    names = ['verilator_config.vlt', 'config_pkg.sv', 'g6lc64_smt2_config_pkg.sv',
             'riscv_pkg.sv', 'cf_math_pkg.sv', 'lzc.sv', 'pmp_entry.sv']
    paths = []
    for name in names:
        dest = source / ('vendor/' + name if name in ('cf_math_pkg.sv', 'lzc.sv') else name)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(data / name, dest)
        paths.append(str(dest))
    if os.environ.get('PMP_SPLIT_COUNTER') == '1':
        control = source / 'split-counter.vlt'
        control.write_text('`verilator_config\nsplit_var -module "lzc" -var "*index_nodes"\n'
                           'split_var -module "lzc" -var "*sel_nodes"\n')
        paths.insert(1, str(control))
    fault = os.environ.get('PMP_TRANSITION_FAULT') == '1'
    if fault:
        path = source / 'pmp_entry.sv'
        text = path.read_text()
        old = "trail_ones} + 3;"
        if text.count(old) != 1:
            raise RuntimeError('PMP mutation site changed')
        path.write_text(text.replace(old, "trail_ones} + 4;"))
    runtime = Path(os.environ['VERILATOR_ROOT'])
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    if digest(runtime / 'include/verilated_funcs.h') != 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166':
        raise RuntimeError('unqualified runtime')
    if os.environ.get('PMP_TRANSITION_FORMAL') == '1':
        records = []
        for width in (32, 56):
            harness = source / f'pmp_match_{width}.sv'
            harness.write_text(f'''// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module pmp_match(input logic [{width-1}:0] addr,
                 input logic [{width-3}:0] config_addr);
  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64; c.VLEN=64; c.PLEN={width};
    return c;
  endfunction
  logic hit, expected;
  pmp_entry #(.CVA6Cfg(cfg())) dut (
    .addr_i(addr),.conf_addr_i(config_addr),.conf_addr_prev_i('0),
    .conf_addr_mode_i(riscv::NAPOT),.match_o(hit));
  logic [{width-1}:3] bits_match;
  for (genvar b=3; b<{width}; b++) begin
    assign bits_match[b]=(&config_addr[b-3:0]) || addr[b] == config_addr[b-2];
  end
  assign expected=&bits_match;
  always_comb assert(hit == expected);
endmodule
''')
            script = out / f'formal-{width}.ys'
            script.write_text('read_slang --std 1800-2017 --top pmp_match '
                              + ' '.join(p for p in paths if p.endswith('.sv')) + ' ' + str(harness)
                              + '\nprep -top pmp_match\nflatten\nchformal -lower\nopt\ncheck -assert\nscc -expect 0\n'
                              + 'sat -prove-asserts -verify -show-ports\n')
            with (out / f'formal-{width}.log').open('w') as log:
                rc = subprocess.run(['/opt/testharness/toolchains/formal/bin/yosys', '-s', str(script)],
                                    stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
            text = (out / f'formal-{width}.log').read_text()
            matched = (rc != 0 and 'model found: FAIL!' in text) if fault else (
                rc == 0 and 'no model found: SUCCESS!' in text)
            records.append({'width': width, 'fault': fault, 'rc': rc, 'matched': matched})
            (out / 'formal-results.json').write_text(json.dumps(records, indent=2))
            if not matched:
                raise RuntimeError('PMP match proof outcome mismatch')
        (out / 'sources.json').write_text(json.dumps({str(p.relative_to(source)): digest(p)
                                                     for p in source.rglob('*') if p.is_file()}, indent=2))
        return
    bench = source / 'tb_pmp_transition.sv'
    bench.write_text('''// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_pmp_transition;
  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c=config_pkg::cva6_cfg_empty;
    c.XLEN=64; c.VLEN=64; c.PLEN=56;
    return c;
  endfunction
  logic [55:0] addr=0;
  logic [53:0] config_addr=0;
  riscv::pmp_addr_mode_t mode=riscv::OFF;
  logic hit;
  bit negative;
  pmp_entry #(.CVA6Cfg(cfg())) dut (
    .addr_i(addr),.conf_addr_i(config_addr),.conf_addr_prev_i(54'b0),
    .conf_addr_mode_i(mode),.match_o(hit));
  initial begin
    negative=$test$plusargs("oracle_negative");
    #5; mode=riscv::NAPOT;
    for (int k=0; k<20; k++) begin
      config_addr=(54'b1 << k)-1'b1;
      addr=0;
      #5;
      if (!(hit ^ negative)) $fatal(1,"PMP_REFERENCE inside k=%0d",k);
      addr=56'b1 << (k+3);
      #5;
      if (hit) $fatal(1,"PMP_REFERENCE outside k=%0d",k);
    end
    $display("PMP_TRANSITION_PASS");
    $finish;
  end
endmodule
''')
    command = ['verilator', '--binary', '--timing', '--assert', '--threads', '1',
               '-Wno-fatal', '-Werror-LATCH', '-Werror-UNOPTFLAT', '--top-module', 'tb_pmp_transition',
               '--Mdir', str(out / 'model'), '-o', 'pmp-transition', *paths, str(bench)]
    (out / 'command.json').write_text(json.dumps(command, indent=2))
    (out / 'sources.json').write_text(json.dumps({str(p.relative_to(source)): digest(p)
                                                 for p in source.rglob('*') if p.is_file()}, indent=2))
    with (out / 'build.log').open('w') as log:
        rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
    if rc:
        raise RuntimeError('PMP transition build failed; assertions and warning policy unchanged')
    records = []
    for negative in ([False] if fault else [False, True]):
        command = [str(out / 'model/pmp-transition')] + (['+oracle_negative'] if negative else [])
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        text = result.stdout + result.stderr
        (out / f'negative{int(negative)}.log').write_text(text)
        matched = (result.returncode != 0 and ('pmp_entry.sv:' if fault else 'PMP_REFERENCE') in text) if fault or negative else (
            result.returncode == 0 and 'PMP_TRANSITION_PASS' in text)
        records.append({'fault': fault, 'negative': negative, 'rc': result.returncode, 'matched': matched})
        (out / 'result.json').write_text(json.dumps(records, indent=2))
        print(text)
        if not matched:
            raise RuntimeError('PMP transition outcome mismatch')


if __name__ == '__main__':
    main()
