#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""T6b-4b sbcommit leaf: per-hart commit heads over the shared scoreboard ring."""
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

    for name in ['config_pkg.sv', 'g6lc64_smt2_config_pkg.sv', 'riscv_pkg.sv',
                 'ariane_pkg.sv', 'g6lc_sb_keep.sv', 'g6lc_core_types.svh',
                 'scoreboard.sv', 'commit_stage.sv', 'tb_g6lc_sbcommit.sv']:
        dest = source / name
        shutil.copy2(pick(name), dest)
        if not name.endswith('.svh'):
            inputs.append(str(dest))
        hashes[name] = digest(dest)
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    # No -Werror-UNOPTFLAT: the scoreboard's issue_pointer/commit_pointer
    # vectors have a pre-existing intra-vector dependence (next = prev + 1)
    # that Verilator flags but converges on; the rtl-audit runner likewise
    # only enforces it on the memdep leaf.
    verilator = ['verilator', '--binary', '--timing', '--assert', '--threads', '1',
                 '-Wno-fatal', '-DG6LC_FETCH_B',
                 '-I' + str(source), '--top-module', 'tb_g6lc_sbcommit']
    builds = [('model', [])]
    # Mutant: popcount free accounting — a committed hole aliases as
    # allocatable space and dispatch overwrites a live slot (SBC_NO_OVERWRITE).
    builds.append(('model-mut', ['-DG6LC_MUT_SB_POPCOUNT_FREE']))
    for mdir, extra in builds:
        command = verilator + extra + ['--Mdir', str(out / mdir), '-o', 'sbcommit',
                                       *inputs]
        (out / f'command-{mdir}.json').write_text(json.dumps(command, indent=2))
        with (out / f'build-{mdir}.log').open('w') as log:
            build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                   timeout=240)
        if build.returncode:
            print((out / f'build-{mdir}.log').read_text()[-6000:])
            raise RuntimeError(f'sbcommit leaf build failed ({mdir})')
    passes = []
    for s in range(7):
        passes.append((str(out / 'model/sbcommit'), [f'+scenario={s}'],
                       f'sim-s{s}.log',
                       lambda rc, text, s=s: rc == 0 and
                       f'scenario={s}' in text and 'RTL_REVIEW_PASS' in text))
    # The mutation must trip the no-overwrite guard in scenario 1.
    passes.append((str(out / 'model-mut/sbcommit'), ['+scenario=1'],
                   'sim-mutant.log',
                   lambda rc, text: rc != 0 and 'SBC_NO_OVERWRITE' in text))
    for binary, args_extra, log_name, matched in passes:
        run = subprocess.run([binary, *args_extra], capture_output=True, text=True,
                             timeout=30)
        text = run.stdout + run.stderr
        (out / log_name).write_text(text)
        print(text)
        if not matched(run.returncode, text):
            raise RuntimeError(f'sbcommit leaf test failed: {log_name}')
    print('SBCOMMIT_LEAF_PASS scenarios=7 mutant=SBC_NO_OVERWRITE')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
