#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Response-ownership review for g6lc_axi_2to1_mux (core/Ara AXI mux).
#
# REVIEW_MUX_FAULT=1 restores the original release condition, which returned the
# arbiter to IDLE whenever no request was momentarily valid — without regard to
# responses still owed. That must reproduce the misrouted response.

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

NAMES = ['g6lc_axi_2to1_mux.sv', 'tb_g6lc_l2.sv', 'tb_g6lc_axi_2to1_mux.sv']


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

    fault = os.environ.get('REVIEW_MUX_FAULT') == '1'
    for name in NAMES:
        (source / name).write_bytes((data / name).read_bytes())

    if fault:
        path = source / 'g6lc_axi_2to1_mux.sv'
        text = path.read_text()
        # Both release conditions revert to the original form: no outstanding
        # accounting, only "nothing valid this cycle".
        for slv in ('slv0', 'slv1'):
            old = (f"        if (!{slv}_req_i.ar_valid && !{slv}_req_i.aw_valid &&\n"
                   f"            !{slv}_req_i.w_valid && !rd_out_q && !wr_out_q)\n"
                   f"          state_d = IDLE;")
            new = (f"        if (!{slv}_req_i.ar_valid && !{slv}_req_i.aw_valid &&\n"
                   f"            !{slv}_req_i.w_valid && !mst_resp_i.r_valid && !mst_resp_i.b_valid)\n"
                   f"          state_d = IDLE;")
            assert text.count(old) == 1, f'fault injection site changed ({slv})'
            text = text.replace(old, new)
        path.write_text(text)

    (out / 'sources.json').write_text(json.dumps(
        {n: digest(source / n) for n in NAMES}, indent=2))

    # Same private, corrected runtime the cache reviews bind to, with the same
    # digest assertion: the root-owned tree is not readable here, and pinning the
    # header keeps every review's build on one known runtime.
    runtime_info = json.loads(Path(
        '/opt/testharness/runs/review-cacheability-pair-20260916/output/runtime.json').read_text())
    runtime = Path(runtime_info['privateRoot'])
    assert digest(runtime / 'include/verilated_funcs.h') == \
        'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    (out / 'runtime.json').write_text(json.dumps(runtime_info, indent=2))
    top = 'tb_g6lc_axi_2to1_mux'
    rtl = [str(source / n) for n in NAMES]
    command = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert',
               '--threads', '1', '-Wno-fatal', '-Wno-TIMESCALEMOD',
               '-Werror-LATCH', '-Werror-UNOPTFLAT',
               '-DL2TB_STATIC', '--top-module', top,
               '--Mdir', str(model), '-o', 'mux-test', *rtl]
    for label, cmd in (('verilate', command),
                       ('build', ['make', '-C', str(model), '-f', f'V{top}.mk',
                                  '-j4', 'VERILATOR_ROOT=' + str(runtime)])):
        (out / f'{label}-command.json').write_text(json.dumps(cmd, indent=2))
        with (out / f'{label}.log').open('w') as log:
            rc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT,
                                timeout=900).returncode
        assert rc == 0, label

    exe = model / 'mux-test'
    plan = [(0, 'MUX_ERRORS')] if fault else [(0, None), (1, None), (2, None)]
    results = []
    for scenario, positive_error in plan:
        trials = [(False, positive_error)]
        if not fault:
            # The negative trial flips the OBSERVED response id, so a correct DUT
            # must fail the routing comparison. Expecting MUX_NEGATIVE_CAUGHT proves
            # the comparison is what detects a misroute. The previous expectation,
            # MUX_NEGATIVE_NOT_DETECTED, only proved the harness complains when asked
            # to find an error that was never injected.
            trials.append((True, 'MUX_NEGATIVE_CAUGHT'))
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
    print(f'MUX REVIEW OK records={len(results)} fault={fault}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
