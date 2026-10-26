#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""hyp8 smoke runner: execute every tohost-bearing ELF an integration run
compiled (output/inputs/*.elf) on that run's isolated model, one at a time.

  HYP8_INT_TAG   the integration run tag (default hyp8-integration-r68c)
  HYP8_MAX_CYCLES per-test cycle budget (default 400000)
  HYP8_PLUSARGS  extra plusargs (space separated)
  HYP8_ONLY      run only the named test (rvfi .dasm traces land in the output dir)

Verdict rule (H3): a pass is the harness's positive `*** SUCCESS ***` line
AND a real tohost write recorded in results.json's `tohostPlusarg` path
(the ELF declared tohost at 0x80001000 and the run was launched with it).
A budget-out writes no verdict and is reported as `wedged`, never as pass.
"""
import json
import os
import re
import subprocess
from pathlib import Path

RUNS = Path('/opt/testharness/runs')


def main():
    out = Path(os.environ['TH_OUT_DIR'])
    tag = os.environ.get('HYP8_INT_TAG', 'hyp8-integration-r68c')
    budget = int(os.environ.get('HYP8_MAX_CYCLES', '400000'))
    extra = os.environ.get('HYP8_PLUSARGS', '').split()
    intdir = RUNS / tag / 'output'
    results = json.loads((intdir / 'results.json').read_text())
    model = intdir / 'model' / 'Variane_testharness'
    assert model.is_file(), f'model missing: {model}'
    summary = {'intTag': tag, 'modelSha256': results['build'].get('modelSha256'),
               'tests': {}}
    rc_all = 0
    only = os.environ.get('HYP8_ONLY')
    for name, entry in results['inputs'].items():
        if not isinstance(entry, dict) or 'tohostPlusarg' not in entry:
            continue
        if only and name != only:
            continue
        elf = intdir / 'inputs' / f'{name}.elf'
        log = out / f'{name}.log'
        cmd = [str(model), entry['tohostPlusarg'], '+debug_disable',
               f'+max-cycles={budget}', *extra, str(elf)]
        with log.open('w') as fh:
            p = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT,
                               cwd=out, timeout=3600)
        text = log.read_text(errors='replace')
        verdict = [l for l in text.splitlines() if '***' in l]
        m = re.search(r'\*\*\* SUCCESS \*\*\*.*after (\d+) cycles', text)
        fail = re.search(r'\*\*\* FAILED \*\*\*.*tohost = (\S+)', text)
        state = 'pass' if m else ('fail' if fail else 'wedged')
        summary['tests'][name] = {'rc': p.returncode, 'state': state,
                                  'cycles': int(m.group(1)) if m else None,
                                  'verdict': verdict[-1:] , 'log': log.name}
        if state != 'pass':
            rc_all = 1
        print(f'{name}: {state} cycles={summary["tests"][name]["cycles"]} rc={p.returncode}')
    (out / 'smokes-results.json').write_text(json.dumps(summary, indent=2))
    return rc_all


if __name__ == '__main__':
    raise SystemExit(main())
