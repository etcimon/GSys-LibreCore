#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Response-ownership review for g6lc_server_prefetcher: builds the leaf bench,
# runs the ownership scenarios plus their injected-oracle controls, and records
# the raw downstream/upstream AR accounting.
#
# REVIEW_PF_BEFORE=1 selects the pre-change expectation set, so the defects have
# to be reproduced before the repair is accepted.

import hashlib, json, os, re, shutil, subprocess, sys
from pathlib import Path

NAMES = ['axi_pkg.sv', 'tc_sram.sv', 'g6lc_l2_pkg.sv', 'g6lc_l2_tag.sv',
         'g6lc_l2_data.sv', 'g6lc_l2_mshr.sv', 'g6lc_l2_top.sv',
         # compiled with -DL2TB_STATIC: contributes g6lc_l2_tb_pkg only
         'tb_g6lc_l2.sv', 'g6lc_server_prefetcher.sv', 'tb_g6lc_pf.sv']

CONTRACT = {0: 'PF_DATA', 1: 'PF_DATA', 2: 'PF_DATA', 3: 'PF_DATA'}

BEFORE = {0: 'PF_UNEXPECTED_ID', 1: 'PF_UNEXPECTED_ID', 2: 'PF_DEMAND_BLOCKED',
          3: 'PF_ID_COLLIDE'}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir(parents=True, exist_ok=True)
    before = os.environ.get('REVIEW_PF_BEFORE') == '1'

    for name in NAMES:
        shutil.copy2(data / name, source / name)
    (out / 'sources.json').write_text(json.dumps(
        {name: digest(source / name) for name in NAMES}, indent=2))

    runtime_info = json.loads(Path(
        '/opt/testharness/runs/review-cacheability-pair-20260916/output/runtime.json').read_text())
    runtime = Path(runtime_info['privateRoot'])
    assert digest(runtime / 'include/verilated_funcs.h') == \
        'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    (out / 'runtime.json').write_text(json.dumps(runtime_info, indent=2))

    model = out / 'model'
    rtl = [str(source / n) for n in NAMES]
    build = [
        ('verilate', ['verilator', '--cc', '--main', '--exe', '--timing', '--assert',
                      '--threads', '1', '-Wno-fatal', '-Wno-TIMESCALEMOD',
                      '-Werror-LATCH', '-Werror-UNOPTFLAT', '-DL2TB_STATIC',
                      '--top-module', 'tb_g6lc_pf', '--Mdir', str(model),
                      '-o', 'pf-test', *rtl]),
        ('build', ['make', '-C', str(model), '-f', 'Vtb_g6lc_pf.mk', '-j4',
                   'VERILATOR_ROOT=' + str(runtime)]),
    ]
    for label, cmd in build:
        with (out / f'{label}.log').open('w') as log:
            rc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT).returncode
        assert rc == 0, label
    deps = '\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
    assert str(runtime / 'include/verilated_funcs.h') in deps
    assert str(Path(runtime_info['originalRoot']) / 'include/verilated_funcs.h') not in deps

    if os.environ.get('REVIEW_PF_SYNTH') == '1':
        script = ('read_slang ' + ' '.join(str(source / n) for n in NAMES) +
                  ' -DL2TB_STATIC -DL2TB_SYNTH --ignore-initial --ignore-assertions'
                  ' --top g6lc_pf_fixture;'
                  ' hierarchy -check -top g6lc_pf_fixture; proc; opt; check -assert;'
                  ' synth -top g6lc_pf_fixture -noabc; check -assert;'
                  ' select -assert-none t:*dlatch* t:*DLATCH*; scc -expect 0')
        with (out / 'synth-pf.log').open('w') as log:
            rc = subprocess.run(['yosys', '-Q', '-T', '-p', script],
                                stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
        assert rc == 0, 'prefetcher synthesis'

    exe = model / 'pf-test'
    results, metrics = [], {}
    if os.environ.get('REVIEW_PF_DIAGNOSE') == '1':
        seen = {}
        for scenario in sorted(CONTRACT):
            p = subprocess.run([str(exe), f'+scenario={scenario}'],
                               capture_output=True, text=True, timeout=120)
            text = p.stdout + p.stderr
            (out / f'diagnose-{scenario}.log').write_text(text)
            hit = re.search(r'(PF_[A-Z_]+)', text)
            seen[scenario] = {'rc': p.returncode, 'firstToken': hit.group(1) if hit else None}
        (out / 'diagnose.json').write_text(json.dumps(seen, indent=2))
        return 0
    for scenario in sorted(CONTRACT):
        trials = [(False, BEFORE[scenario] if before else None)]
        if not before and CONTRACT[scenario]:
            trials.append((True, CONTRACT[scenario]))
        for neg, expected in trials:
            cmd = [str(exe), f'+scenario={scenario}'] + (['+oracle_negative'] if neg else [])
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            text = p.stdout + p.stderr
            (out / f'scenario-{scenario}-negative-{int(neg)}.log').write_text(text)
            if expected:
                matched = p.returncode != 0 and expected in text and 'RTL_REVIEW_PASS' not in text
            else:
                matched = (p.returncode == 0 and text.count('RTL_REVIEW_PASS') == 1
                           and '%Error' not in text)
                hit = re.search(r'PF_METRICS scenario=(\d+) dn_ar=(\d+) up_ar=(\d+) '
                                r'extra=(\d+) responses=(\d+)', text)
                assert hit, f'missing metrics for scenario {scenario}'
                metrics[scenario] = {'dnAr': int(hit.group(2)), 'upAr': int(hit.group(3)),
                                     'extra': int(hit.group(4)),
                                     'responses': int(hit.group(5))}
            results.append({'scenario': scenario, 'negative': neg, 'before': before,
                            'expectedError': expected, 'rc': p.returncode,
                            'matched': matched, 'executableSha256': digest(exe),
                            'strictQualification': False})
            (out / 'results.json').write_text(json.dumps(results, indent=2))
            assert matched, (scenario, neg)

    (out / 'metrics.json').write_text(json.dumps({
        'role': 'before' if before else 'candidate',
        'contract': {str(k): v for k, v in metrics.items()},
    }, indent=2))
    assert all(digest(source / n) == json.loads((out / 'sources.json').read_text())[n]
               for n in NAMES)
    return 0


if __name__ == '__main__':
    sys.exit(main())
