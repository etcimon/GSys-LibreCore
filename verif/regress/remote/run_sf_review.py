#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Sharer-set soundness review for g6lc_snoop_filter.
#
# The hub computes a write's invalidation targets as `sf_present & ~(1<<writer)`,
# so an under-reported sharer keeps a stale line. This checks the module's own
# stated contract: over-report freely, never under-report.
#
# REVIEW_SF_FAULT=1 restores the original install-on-conflict behaviour (fresh
# entry claims only the allocating core), which must reproduce the lost sharer.

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

# g6lc_snoop_filter imports config_pkg; the same minimal package prefix the
# existing coherence-leaf reviews use (run_inval_review.py) is sufficient.
NAMES = ['config_pkg.sv', 'g6lc_coherence_pkg.sv', 'g6lc_snoop_filter.sv',
         'tb_g6lc_snoop_filter.sv']


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    run = Path(os.environ.get('TH_RUN_DIR', '.')).resolve()
    data = Path(os.environ.get('TH_DATA_DIR', run / 'data')).resolve()
    out = Path(os.environ.get('TH_OUT_DIR', run / 'output')).resolve()
    source = out / 'source'
    model = out / 'model'
    for d in (source, model):
        d.mkdir(parents=True, exist_ok=True)

    fault = os.environ.get('REVIEW_SF_FAULT') == '1'
    signature = os.environ.get('REVIEW_SF_SIGNATURE') == '1'
    names = ['tc_sram.sv', 'g6lc_ooo_snoop_filter.sv', 'tb_g6lc_ooo_snoop_filter.sv'] if signature else NAMES
    area = signature and os.environ.get('REVIEW_SF_AREA') == '1'
    formal = signature and os.environ.get('REVIEW_SF_FORMAL') == '1'
    if formal:
        names.insert(0, 'tb_g6lc_ooo_snoop_props.sv')
    if area:
        names[:0] = ['config_pkg.sv', 'g6lc_coherence_pkg.sv', 'g6lc_snoop_filter.sv']
    for name in names:
        (source / name).write_bytes((data / name).read_bytes())

    if fault:
        path = source / ('g6lc_ooo_snoop_filter.sv' if signature else 'g6lc_snoop_filter.sv')
        text = path.read_text()
        old = "      byte_enable[alloc_core_i] = 1'b1;" if signature else "            mem_d[al_idx].present               = install_present;"
        new = "      byte_enable[alloc_core_i] = 1'b0;" if signature else "            mem_d[al_idx].present               = '0;"
        assert text.count(old) == 1, 'fault injection site changed'
        path.write_text(text.replace(old, new))

    (out / 'sources.json').write_text(json.dumps(
        {n: digest(source / n) for n in names}, indent=2))

    runtime_info = json.loads(Path(
        '/opt/testharness/runs/review-cacheability-pair-20260916/output/runtime.json').read_text())
    runtime = Path(runtime_info['privateRoot'])
    assert digest(runtime / 'include/verilated_funcs.h') == \
        'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    (out / 'runtime.json').write_text(json.dumps(runtime_info, indent=2))

    top = 'tb_g6lc_ooo_snoop_filter' if signature else 'tb_g6lc_snoop_filter'
    rtl = [str(source / n) for n in names]
    command = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert',
               '--threads', '1', '-Wno-fatal', '-Wno-TIMESCALEMOD',
               '-Werror-LATCH', '-Werror-UNOPTFLAT',
               '--top-module', top, '--Mdir', str(model), '-o', 'sf-test', *rtl]
    for label, cmd in (('verilate', command),
                       ('build', ['make', '-C', str(model), '-f', f'V{top}.mk',
                                  '-j4', 'VERILATOR_ROOT=' + str(runtime)])):
        (out / f'{label}-command.json').write_text(json.dumps(cmd, indent=2))
        with (out / f'{label}.log').open('w') as log:
            rc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT,
                                timeout=900).returncode
        assert rc == 0, label

    exe = model / 'sf-test'
    # Scenario 2 has no write check, so it carries no injected-oracle trial.
    plan = ([(0, 'SF_ERRORS')] if fault
            else [(0, None, True), (1, None, True), (2, None, False)])
    if signature:
        plan = [(0, 'SIG_SHARER_LOST')] if fault else [(0, None, True)]
    results = []
    for entry in plan:
        scenario, positive_error = entry[0], entry[1]
        trials = [(False, positive_error)]
        # The negative trial inflates the oracle so a correct filter cannot
        # satisfy it. The bench then reports PASS only because it CAUGHT the
        # injected error; if it found nothing it fatals with
        # SF_NEGATIVE_NOT_DETECTED and this trial fails.
        if not fault and entry[2]:
            trials.append((True, 'SIG_SHARER_LOST' if signature else 'SF_NEGATIVE_CAUGHT'))
        for negative, expected in trials:
            cmd = [str(exe), f'+scenario={scenario}']
            if negative:
                cmd.append('+oracle_negative')
            log = out / f'scenario-{scenario}-negative-{int(negative)}.log'
            with log.open('w') as fh:
                p = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT,
                                   timeout=300)
            text = log.read_text(errors='replace')
            if expected is None:
                matched = p.returncode == 0 and 'RTL_REVIEW_PASS' in text
            else:
                matched = p.returncode != 0 and expected in text
            results.append({'scenario': scenario, 'negative': negative,
                            'rtlFault': fault, 'expectedError': expected,
                            'rc': p.returncode, 'matched': matched,
                            'executableSha256': digest(exe)})
            (out / 'results.json').write_text(json.dumps(results, indent=2))
            assert matched, (scenario, negative, expected)
    if formal:
        proofs = []
        for negative in (0, 1):
            label = f'formal-negative{negative}'
            rtl = ' '.join(str(source / n) for n in names[:-1])
            script = (f'read_slang --top g6lc_ooo_snoop_props -GNEGATIVE={negative} {rtl}; '
                      'prep -top g6lc_ooo_snoop_props; flatten; async2sync; chformal -lower; '
                      'memory_map; opt -full; dffunmap; opt_clean; '
                      f'write_rtlil {out}/{label}.il; '
                      f'sat -seq 10 -prove-asserts -verify -show-ports -dump_vcd {out}/{label}.vcd')
            with (out / f'{label}.log').open('w') as log:
                rc = subprocess.run(['yosys', '-p', script], stdout=log,
                                    stderr=subprocess.STDOUT, timeout=180).returncode
            text = (out / f'{label}.log').read_text()
            matched = (rc != 0 and 'model found: FAIL!' in text) if negative else \
                (rc == 0 and 'no model found: SUCCESS!' in text and 'Import proof for assert' in text)
            proofs.append({'negative': bool(negative), 'depth': 10, 'rc': rc, 'matched': matched})
            (out / 'formal-results.json').write_text(json.dumps(proofs, indent=2))
            assert matched, label
        script = (f'read_rtlil {out}/formal-negative0.il; chformal -assert -remove; '
                  f'sat -seq 12 -prove saw_conflict_o 0 -prove-skip 11 -verify '
                  f'-show-ports -dump_vcd {out}/formal-cover.vcd')
        with (out / 'formal-cover.log').open('w') as log:
            rc = subprocess.run(['yosys', '-p', script], stdout=log,
                                stderr=subprocess.STDOUT, timeout=180).returncode
        assert rc != 0 and 'model found: FAIL!' in (out / 'formal-cover.log').read_text()
    if area:
        assert not fault
        areas = []
        for cores, entries in ((2, 128), (4, 256)):
            for role in ('tagged', 'signature'):
                label = f'{role}-n{cores}-e{entries}'
                wrapper = source / f'{label}.sv'
                head = '// Copyright (c) 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n'
                body = f'''module leaf(input logic clk_i,rst_ni,av,lv,
input logic [63:0] aa,la,input logic [{(cores-1).bit_length()-1}:0] ac,
output logic [{cores-1}:0] present,output logic ready,ar,lr,rv);
'''
                if role == 'signature':
                    body += f'''g6lc_ooo_snoop_filter #(.NR_CORES({cores}),.NR_ENTRIES({entries}),.LINE_BYTES(16)) dut(
.clk_i,.rst_ni,.alloc_valid_i(av),.alloc_addr_i(aa),.alloc_core_i(ac),.alloc_ready_o(ar),
.lookup_valid_i(lv),.lookup_addr_i(la),.lookup_ready_o(lr),.result_valid_o(rv),.present_o(present),.ready_o(ready));
'''
                else:
                    body += f'''assign ready=1'b1; assign ar=1'b1; assign lr=1'b1; assign rv=lv;
g6lc_snoop_filter #(.NR_CORES({cores}),.NR_ENTRIES({entries}),.LINE_BYTES(16)) dut(
.clk_i,.rst_ni,.alloc_valid_i(av),.alloc_addr_i(aa),.alloc_core_i(ac),
.clear_valid_i(1'b0),.clear_addr_i('0),.clear_core_i('0),.clear_all_i(1'b0),
.lookup_valid_i(lv),.lookup_addr_i(la),.present_o(present),.lookup_hit_o(),.overapprox_o());
'''
                wrapper.write_text(head + body + 'endmodule\n')
                netlist = out / f'{label}.json'
                script = ('read_slang --top leaf ' + ' '.join(str(source / n) for n in names[:-1]) +
                          f' {wrapper}; synth -top leaf -flatten; check -assert; '
                          f'select -assert-none t:*dlatch* t:*DLATCH*; write_json {netlist}')
                with (out / f'{label}.log').open('w') as log:
                    rc = subprocess.run(['yosys', '-p', script], stdout=log,
                                        stderr=subprocess.STDOUT, timeout=600).returncode
                assert rc == 0, label
                cells = json.loads(netlist.read_text())['modules']['leaf']['cells']
                kinds = [cell['type'] for cell in cells.values() if cell['type'] != '$scopeinfo']
                areas.append({'role': role, 'cores': cores, 'entries': entries,
                              'genericCells': len(kinds),
                              'sequentialCells': sum('DFF' in kind for kind in kinds),
                              'physicalArea': None, 'latencyEquivalent': False,
                              'logicalSignatureBits': cores * entries if role == 'signature' else None,
                              'sramPortStorageBits': entries * 32 * ((cores + 3) // 4)
                              if role == 'signature' else None})
                (out / 'area.json').write_text(json.dumps(areas, indent=2))
    print(f'SF REVIEW OK records={len(results)} fault={fault}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
