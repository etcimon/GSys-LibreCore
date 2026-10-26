#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""hyp8 firmware witness launcher: run the frozen OpenSBI(+Linux) ELF on an
integration run's isolated model, DETACHED (setsid), so the proxy session can
return and the run is collected later with `testharness_proxy.py pull`.

  HYP8_INT_TAG    integration run tag (model under its output/model)
  HYP8_FW_SHA256  sha256 of the frozen fw_payload.elf to run (located under
                  /opt/testharness/runs; identity is checked, not assumed)
  HYP8_TOHOST     tohost address of that ELF (nm-derived, e.g. 0x80041730)
  HYP8_MAX_CYCLES budget (default 60000000)
  HYP8_PLUSARGS   extra plusargs

The launch record (witness.json) carries model sha, ELF sha, argv and pid.
A witness is a gate, never a search signal (P1): classify only from its own
positive milestones in run-hyp8.log.
"""
import hashlib
import json
import os
import subprocess
from pathlib import Path

RUNS = Path('/opt/testharness/runs')


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    out = Path(os.environ['TH_OUT_DIR'])
    tag = os.environ['HYP8_INT_TAG']
    want = os.environ['HYP8_FW_SHA256']
    tohost = os.environ['HYP8_TOHOST']
    budget = os.environ.get('HYP8_MAX_CYCLES', '60000000')
    extra = os.environ.get('HYP8_PLUSARGS', '').split()
    intdir = RUNS / tag / 'output'
    model = intdir / 'model' / 'Variane_testharness'
    assert model.is_file(), f'model missing: {model}'
    results = json.loads((intdir / 'results.json').read_text())
    elf = None
    for cand in sorted(RUNS.glob('*/output/**/fw_payload.elf')):
        if sha(cand) == want:
            elf = cand
            break
    assert elf is not None, f'no fw_payload.elf with sha {want} under {RUNS}'
    cmd = [str(model), f'+tohost_addr={tohost}', '+debug_disable',
           f'+max-cycles={budget}', *extra, str(elf)]
    log = out / 'run-hyp8.log'
    p = subprocess.Popen(cmd, stdout=log.open('w'), stderr=subprocess.STDOUT,
                         cwd=out, start_new_session=True)
    (out / 'witness.json').write_text(json.dumps({
        'intTag': tag, 'modelSha256': results['build'].get('modelSha256'),
        'elf': str(elf), 'elfSha256': want, 'argv': cmd, 'pid': p.pid,
        'budget': budget}, indent=2))
    print(f'launched pid={p.pid} model={results["build"].get("modelSha256")} elf={elf}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
