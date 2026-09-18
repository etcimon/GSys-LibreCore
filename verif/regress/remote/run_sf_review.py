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
    for name in NAMES:
        (source / name).write_bytes((data / name).read_bytes())

    if fault:
        path = source / 'g6lc_snoop_filter.sv'
        text = path.read_text()
        old = "            mem_d[al_idx].present               = install_present;"
        new = "            mem_d[al_idx].present               = '0;"
        assert text.count(old) == 1, 'fault injection site changed'
        path.write_text(text.replace(old, new))

    (out / 'sources.json').write_text(json.dumps(
        {n: digest(source / n) for n in NAMES}, indent=2))

    runtime_info = json.loads(Path(
        '/opt/testharness/runs/review-cacheability-pair-20260916/output/runtime.json').read_text())
    runtime = Path(runtime_info['privateRoot'])
    assert digest(runtime / 'include/verilated_funcs.h') == \
        'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    (out / 'runtime.json').write_text(json.dumps(runtime_info, indent=2))

    top = 'tb_g6lc_snoop_filter'
    rtl = [str(source / n) for n in NAMES]
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
    results = []
    for entry in plan:
        scenario, positive_error = entry[0], entry[1]
        trials = [(False, positive_error)]
        # The negative trial inflates the oracle so a correct filter cannot
        # satisfy it. The bench then reports PASS only because it CAUGHT the
        # injected error; if it found nothing it fatals with
        # SF_NEGATIVE_NOT_DETECTED and this trial fails.
        if not fault and entry[2]:
            trials.append((True, 'SF_NEGATIVE_CAUGHT'))
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
    print(f'SF REVIEW OK records={len(results)} fault={fault}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
