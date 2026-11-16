#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""hyp8 directed-probe runner: assemble named tohost-bearing sources and run
them on an existing integration model, grading the *log* as well as tohost.

A witness boot can pass its UART markers while the model log carries
thousands of bus-error / walk-error records. This runner turns one such
record class into a bounded, isolated test: the source reproduces the
pattern, and the run passes only if it both reaches tohost == 1 and its log
contains no record of the forbidden classes.

  TH_DATA_DIR       holds custom/ (verif/tests/custom, pushed with --data)
  HYP8_INT_TAG      integration run whose model is used (read-only)
  HYP8_PROBES       space-separated source stems (default hyp8_spec_bus_clean)
  HYP8_MAX_CYCLES   per-test budget (default 400000)
  HYP8_PLUSARGS     extra plusargs
  HYP8_PROBE_CLEAN  space-separated regexes that must not match the log
                    (default: 'Response.Errored' '%Error' 'uart-axi-ar')
  HYP8_PROBE_EXPECT_DIRTY=1  invert the log grade: the reproduction is
                    expected to show the records (pre-fix baseline).
"""
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

RUNS = Path('/opt/testharness/runs')
RISCV = '/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3'
GCC_FLAGS = ['-march=rv64imafdc_zicsr_zifencei', '-mabi=lp64d',
             '-mcmodel=medany', '-O2', '-nostdlib', '-nostartfiles']
CLASSES = {
    'axi_r_err': r'R Response Errored',
    'axi_b_err': r'B Response Errored',
    'ptw_err': r'^\[ptw-err\]',
    'mmu_ife': r'^\[mmu-ife\]',
    'hang': r'^\[hang\]',
    'seq_gap': r'^\[seq-gap\]',
    'model_error': r'%Error',
}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    out = Path(os.environ['TH_OUT_DIR'])
    data = Path(os.environ['TH_DATA_DIR']) / 'custom'
    tag = os.environ['HYP8_INT_TAG']
    budget = int(os.environ.get('HYP8_MAX_CYCLES', '400000'))
    extra = os.environ.get('HYP8_PLUSARGS', '').split()
    probes = os.environ.get('HYP8_PROBES', 'hyp8_spec_bus_clean').split()
    clean = os.environ.get('HYP8_PROBE_CLEAN', 'Response.Errored %Error uart-axi-ar').split()
    expect_dirty = os.environ.get('HYP8_PROBE_EXPECT_DIRTY') == '1'
    model = RUNS / tag / 'output' / 'model' / 'Variane_testharness'
    assert model.is_file(), f'model missing: {model}'
    gcc = f'{RISCV}/bin/riscv-none-elf-gcc'
    nm = f'{RISCV}/bin/riscv-none-elf-nm'
    summary = {'intTag': tag, 'modelSha256': digest(model), 'tests': {}}
    rc_all = 0
    for name in probes:
        src = data / f'{name}.S'
        elf = out / f'{name}.elf'
        b = subprocess.run([gcc, *GCC_FLAGS, '-T', str(data / 'common/link_verilator.ld'),
                            '-o', str(elf), str(src)], capture_output=True, text=True)
        if b.returncode != 0:
            summary['tests'][name] = {'state': 'build_failed', 'log': b.stderr[-2000:]}
            print(f'{name}: build_failed\n{b.stderr[-2000:]}')
            rc_all = 1
            continue
        syms = subprocess.run([nm, '-n', str(elf)], capture_output=True, text=True).stdout
        tohost = [l.split()[0] for l in syms.splitlines() if l.endswith(' tohost')]
        assert tohost, f'{name}: no tohost symbol'
        run_dir = out / name
        run_dir.mkdir(exist_ok=True)
        log = out / f'{name}.log'
        cmd = [str(model), f'+tohost_addr=0x{int(tohost[0], 16):x}', '+debug_disable',
               f'+max-cycles={budget}', *extra, str(elf)]
        with log.open('w') as fh:
            p = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT,
                               cwd=run_dir, timeout=3600)
        text = log.read_text(errors='replace')
        m = re.search(r'\*\*\* SUCCESS \*\*\*.*after (\d+) cycles', text)
        fail = re.search(r'\*\*\* FAILED \*\*\*.*tohost = (\S+)', text)
        arch = 'fail' if p.returncode != 0 or fail else ('pass' if m else 'wedged')
        census = {k: len(re.findall(v, text, re.M)) for k, v in CLASSES.items()}
        dirty = {pat: len(re.findall(pat, text)) for pat in clean}
        dirty = {k: v for k, v in dirty.items() if v}
        samples = [l[:200] for l in text.splitlines()
                   if any(re.search(pat, l) for pat in clean)][:8]
        log_ok = bool(dirty) if expect_dirty else not dirty
        state = 'pass' if arch == 'pass' and log_ok else \
            (arch if arch != 'pass' else ('log_clean_unexpected' if expect_dirty else 'log_dirty'))
        summary['tests'][name] = {
            'rc': p.returncode, 'state': state, 'arch': arch,
            'cycles': int(m.group(1)) if m else None,
            'tohost': fail.group(1) if fail else None,
            'census': census, 'forbidden': dirty, 'samples': samples,
            'elfSha256': digest(elf), 'srcSha256': digest(src), 'argv': cmd}
        if state != 'pass':
            rc_all = 1
        print(f'{name}: {state} arch={arch} cycles={summary["tests"][name]["cycles"]} '
              f'census={census} forbidden={dirty}')
        for s in samples:
            print('   ', s)
    (out / 'probe-results.json').write_text(json.dumps(summary, indent=2))
    return rc_all


if __name__ == '__main__':
    raise SystemExit(main())
