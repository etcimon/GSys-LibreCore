"""WT tag-response ownership regression, independent of firmware addresses.

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


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    names = ['verilator_config.vlt', 'config_pkg.sv', 'g6lc64_smt2_config_pkg.sv', 'riscv_pkg.sv', 'ariane_pkg.sv',
             'wt_cache_pkg.sv', 'cf_math_pkg.sv', 'lzc.sv', 'rr_arb_tree.sv', 'cva6_fifo_v3.sv',
             'wt_dcache_wbuffer.sv', 'g6lc_core_types.svh', 'tb_g6lc_rtl_review.sv']
    paths = {n: source / ('vendor/' + n if n in ('cf_math_pkg.sv', 'lzc.sv', 'rr_arb_tree.sv') else n)
             for n in names}
    for name in names:
        paths[name].parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(data / name, paths[name])
    control = os.environ.get('WT_TAG_COMPILER_CONTROL')
    if control:
        name = 'counter-split.vlt'
        names.insert(1, name)
        paths[name] = source / name
        shutil.copy2(control, paths[name])
    before = os.environ.get('WT_TAG_BEFORE') == '1'
    fault = os.environ.get('WT_TAG_FAULT') == '1'
    if before and fault:
        raise ValueError('before and fault are separate arms')
    if fault:
        path = source / 'wt_dcache_wbuffer.sv'
        text = path.read_text()
        fixed = 'assign rd_tag_o     = check_en_q ? rd_tag_q : fixup_rd_tag;'
        original = 'assign rd_tag_o     = (|tocheck) ? rd_tag_q : fixup_rd_tag;'
        if text.count(fixed) != 1:
            raise RuntimeError('WT tag mutation site changed')
        path.write_text(text.replace(fixed, original))
    (out / 'sources.json').write_text(json.dumps({str(paths[n].relative_to(source)): sha(paths[n]) for n in names}, indent=2))
    runtime = Path(os.environ['VERILATOR_ROOT'])
    header = runtime / 'include/verilated_funcs.h'
    if sha(header) != 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166':
        raise RuntimeError('unqualified simulation runtime')
    top = 'tb_g6lc_review_wt_tag'
    if os.environ.get('WT_TAG_FORMAL', '1') == '1':
        bench = (source / 'tb_g6lc_rtl_review.sv').read_text()
        prefix = 'module tb_g6lc_review_wt_tag;' + bench.split('module tb_g6lc_review_wt_tag;', 1)[1].split('  task automatic cycle(', 1)[0]
        prefix = prefix.replace('module tb_g6lc_review_wt_tag;', 'module wt_tag_formal(input logic clk, output logic saw_tail=0);')
        prefix = prefix.replace('logic clk=0, rst_n=0, empty;', 'logic rst_n, empty;')
        driver = '''
  logic [4:0] step=0;
  always_comb begin
    rst_n = step != 0;
    request='0;
    request.address_tag=TAG_A;
    request.address_index=12'h128;
    request.data_req=step == 1;
    request.data_be='1;
    request.data_wdata=64'hcab51234;
    rd_ack=1;
  end
  always @(posedge clk) begin
    if (step < 20) step <= step+1'b1;
    if (!rst_n) begin
      previous_read <= 0;
      previous_tag <= TAG_A;
      saw_tail <= 0;
    end else begin
      if (previous_read) assert ((rd_tag ^ @NEG@) == previous_tag);
      if (previous_read && previous_tag == TAG_A && !rd_req) saw_tail <= 1;
      if (rd_req && rd_ack) assert (rd_index == 8'h12 || rd_index == 0);
      previous_read <= rd_req && rd_ack;
      previous_tag <= rd_index == 8'h12 ? TAG_A : '0;
    end
  end
endmodule
'''
        records = []
        for depth in (0, 2, 4):
            for negative in ([False] if before or fault else [False, True]):
                label = f'd{depth}-negative{int(negative)}'
                harness = source / (label + '.sv')
                harness.write_text(prefix.replace('parameter int FIXUP=2;', f'parameter int FIXUP={depth};')
                                   + driver.replace('@NEG@', "44'd1" if negative else "44'd0"))
                rtl = [str(paths[n]) for n in names if n.endswith('.sv') and not n.startswith('tb_')]
                script = out / (label + '.ys')
                script.write_text('read_slang --std 1800-2017 -DG6LC_FETCH_B -DVERILATOR --top wt_tag_formal '
                                  + ' '.join(rtl + [str(harness)]) + '\n'
                                  + 'prep -top wt_tag_formal\nflatten\nasync2sync\nchformal -lower\nmemory_map\nopt\n'
                                  + f'write_rtlil {out}/{label}.il\n'
                                  + f'sat -seq 12 -prove-asserts -verify -show-ports -show rd_tag -show rd_index -show previous_read -show previous_tag -show dut.check_en_q -dump_vcd {out}/{label}.vcd\n')
                with (out / (label + '.log')).open('w') as log:
                    rc = subprocess.run(['/opt/testharness/toolchains/formal/bin/yosys', '-s', str(script)],
                                        stdout=log, stderr=subprocess.STDOUT, timeout=120).returncode
                text = (out / (label + '.log')).read_text()
                expect_failure = before or fault or negative
                matched = (rc != 0 and 'model found: FAIL!' in text) if expect_failure else (
                    rc == 0 and 'no model found: SUCCESS!' in text)
                records.append({'depth': depth, 'negative': negative, 'expectedFailure': expect_failure,
                                'rc': rc, 'matched': matched})
                (out / 'formal-results.json').write_text(json.dumps(records, indent=2))
                if not matched:
                    raise RuntimeError(f'formal outcome mismatch: {label}')
                if not expect_failure:
                    cover = f'read_rtlil {out}/{label}.il\nchformal -assert -remove\nsat -seq 12 -prove saw_tail 0 -prove-skip 11 -verify -show-ports\n'
                    with (out / (label + '-cover.log')).open('w') as log:
                        cr = subprocess.run(['/opt/testharness/toolchains/formal/bin/yosys', '-p', cover],
                                            stdout=log, stderr=subprocess.STDOUT, timeout=120).returncode
                    if cr == 0 or 'model found: FAIL!' not in (out / (label + '-cover.log')).read_text():
                        raise RuntimeError('last-response handoff was not reached')
        print(f'WT_TAG_FORMAL matched={len(records)} before={before} fault={fault}')
        return 0
    results = []
    for depth in (0, 2, 4):
        work = out / f'd{depth}'
        work.mkdir()
        cmd = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1',
               '-Wno-fatal', '-Werror-LATCH', '-Werror-UNOPTFLAT', '+define+G6LC_FETCH_B',
               '-I' + str(source), '--top-module', top, f'-GFIXUP={depth}',
               '--Mdir', str(work), '-o', 'wt-tag',
               *[str(paths[n]) for n in names if not n.endswith('.svh')]]
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
        exe = work / 'wt-tag'
        scenarios = [0, 1] if depth else [0]
        for scenario in scenarios:
            for negative in ([False] if before or fault else [False, True]):
                command = [str(exe), f'+scenario={scenario}'] + (['+oracle_negative'] if negative else [])
                log_path = work / f's{scenario}-negative{int(negative)}.log'
                with log_path.open('w') as log:
                    rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=15).returncode
                text = log_path.read_text(errors='replace')
                expected_failure = before or fault or negative
                matched = (rc != 0 and 'WT_TAG_OWNER' in text) if expected_failure else (
                    rc == 0 and 'RTL_REVIEW_PASS wt_tag' in text)
                results.append({'depth': depth, 'scenario': scenario, 'negative': negative,
                                'expectedFailure': expected_failure, 'rc': rc, 'matched': matched,
                                'executableSha256': sha(exe)})
                (out / 'results.json').write_text(json.dumps(results, indent=2))
                if not matched:
                    raise RuntimeError(f'unexpected outcome: {results[-1]} {text}')
    print(f'WT_TAG_REVIEW matched={len(results)} before={before} fault={fault}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
