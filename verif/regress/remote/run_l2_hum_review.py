#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Hit-under-miss review for g6lc_l2_top: builds the dedicated concurrent-reader
# bench, runs the contract scenarios plus their injected-error controls, and
# records the raw same-line / different-line measurements.
#
# REVIEW_L2_HUM_BASELINE=<dir> overlays pre-change g6lc_l2_top.sv /
# g6lc_l2_mshr.sv so the measurement control is a matched build.

import hashlib, json, os, re, shutil, subprocess, sys
from pathlib import Path

NAMES = ['axi_pkg.sv', 'tc_sram.sv', 'g6lc_l2_pkg.sv', 'g6lc_l2_tag.sv',
         'g6lc_l2_data.sv', 'g6lc_l2_mshr.sv', 'g6lc_l2_top.sv',
         # compiled with -DL2TB_STATIC: contributes g6lc_l2_tb_pkg only
         'tb_g6lc_l2.sv', 'tb_g6lc_l2_hum.sv']

# scenario -> expected-failure token for the injected-error control
CONTRACT = {0: 'HUM_DATA', 1: 'HUM_DATA', 2: 'HUM_DATA', 3: 'HUM_DATA',
            4: 'HUM_DATA', 5: None, 6: None}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir(parents=True, exist_ok=True)

    baseline = os.environ.get('REVIEW_L2_HUM_BASELINE')
    for name in NAMES:
        origin = data / name
        if baseline and name in ('g6lc_l2_top.sv', 'g6lc_l2_mshr.sv'):
            origin = data / ('base_' + name)
            assert origin.exists(), origin
        shutil.copy2(origin, source / name)
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
                      '-DL2TB_STATIC',
                      '--top-module', 'tb_g6lc_l2_hum', '--Mdir', str(model),
                      '-o', 'hum-test', *rtl]),
        ('build', ['make', '-C', str(model), '-f', 'Vtb_g6lc_l2_hum.mk', '-j4',
                   'VERILATOR_ROOT=' + str(runtime)]),
    ]
    for label, cmd in build:
        with (out / f'{label}.log').open('w') as log:
            rc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT).returncode
        assert rc == 0, label

    exe = model / 'hum-test'
    results, metrics = [], {}
    # On the pre-change build the merge path does not exist, so the engagement
    # contract must visibly fail; only the measurements are comparable.
    plan = ([(0, 'HUM_NOT_ENGAGED'), (5, None), (6, None)] if baseline
            else [(s, None) for s in sorted(CONTRACT)])
    for scenario, positive_error in plan:
        trials = [(False, positive_error)]
        if not baseline and CONTRACT[scenario]:
            trials.append((True, CONTRACT[scenario]))
        for negative, expected in trials:
            cmd = [str(exe), f'+scenario={scenario}'] + (['+oracle_negative'] if negative else [])
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            text = p.stdout + p.stderr
            (out / f'scenario-{scenario}-negative-{int(negative)}.log').write_text(text)
            if expected:
                matched = p.returncode != 0 and expected in text and 'RTL_REVIEW_PASS' not in text
            else:
                matched = p.returncode == 0 and text.count('RTL_REVIEW_PASS') == 1 and '%Error' not in text
                hit = re.search(r'HUM_METRICS scenario=(\d+) cycles=(\d+) dram_ar=(\d+) '
                                r'fills=(\d+) merges=(\d+) responses=(\d+)', text)
                assert hit, f'missing metrics for scenario {scenario}'
                metrics[scenario] = {
                    'cycles': int(hit.group(2)), 'dramAr': int(hit.group(3)),
                    'fills': int(hit.group(4)), 'merges': int(hit.group(5)),
                    'responses': int(hit.group(6)),
                }
            results.append({'scenario': scenario, 'negative': negative,
                            'expectedError': expected, 'rc': p.returncode,
                            'matched': matched,
                            'executableSha256': digest(exe),
                            'strictQualification': False})
            (out / 'results.json').write_text(json.dumps(results, indent=2))
            assert matched, (scenario, negative)

    (out / 'metrics.json').write_text(json.dumps({
        'role': 'baseline' if baseline else 'candidate',
        'sameLine': metrics.get(5),
        'differentLine': metrics.get(6),
        'contract': {str(k): v for k, v in metrics.items()},
    }, indent=2))
    assert all(digest(source / n) == json.loads((out / 'sources.json').read_text())[n]
               for n in NAMES)
    return 0


if __name__ == '__main__':
    sys.exit(main())
