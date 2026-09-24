#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""T6b-4b ROB leaf: transaction-id keyed frees keep occupancy exact."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir(exist_ok=True)
    inputs = []
    hashes = {}
    def pick(name):
        matches = list(data.rglob(name))
        if not matches:
            raise FileNotFoundError(name)
        # Reused run dirs can carry stale top-level copies beside the pushed
        # payload subdirectory; prefer the nested path deterministically.
        return max(matches, key=lambda p: len(p.parts))
    for name in ['g6lc_rob.sv', 'tb_g6lc_rob.sv']:
        dest = source / name
        shutil.copy2(pick(name), dest)
        inputs.append(str(dest))
        hashes[name] = digest(dest)
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    verilator = ['verilator', '--binary', '--timing', '--assert', '--threads', '1',
                 '-Wno-fatal', '-Werror-UNOPTFLAT',
                 '--top-module', 'tb_g6lc_rob']
    builds = [('model', [])]
    # Mutant: positional head+r frees — out-of-order tid frees drift count.
    builds.append(('model-mut', ['-DG6LC_MUT_ROB_POSITIONAL_FREE']))
    for mdir, extra in builds:
        command = verilator + extra + ['--Mdir', str(out / mdir), '-o', 'rob',
                                       *inputs]
        (out / f'command-{mdir}.json').write_text(json.dumps(command, indent=2))
        with (out / f'build-{mdir}.log').open('w') as log:
            build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                   timeout=180)
        if build.returncode:
            print((out / f'build-{mdir}.log').read_text()[-6000:])
            raise RuntimeError(f'rob leaf build failed ({mdir})')
    passes = [
        (str(out / 'model/rob'), ['+scenario=0'], 'sim-s0.log',
         lambda rc, text: rc == 0 and 'ROB_TID_FREE' in text),
        (str(out / 'model/rob'), ['+scenario=1'], 'sim-s1.log',
         lambda rc, text: rc == 0 and 'RTL_REVIEW_PASS' in text),
        # Positional-free mutation drifts under out-of-order frees.
        (str(out / 'model-mut/rob'), ['+scenario=0'], 'sim-mutant.log',
         lambda rc, text: rc != 0 and 'ROB_' in text)]
    for binary, args_extra, log_name, matched in passes:
        run = subprocess.run([binary, *args_extra], capture_output=True, text=True,
                             timeout=30)
        text = run.stdout + run.stderr
        (out / log_name).write_text(text)
        print(text)
        if not matched(run.returncode, text):
            raise RuntimeError(f'rob leaf test failed: {log_name}')
    print('ROB_LEAF_PASS scenarios=2 mutant=ROB_POSITIONAL_FREE')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
