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
    physical = os.environ.get('REVIEW_SB_PHYSICAL') == '1'
    mutation = os.environ.get('REVIEW_SB_PHYS_MUTATION')
    if mutation:
        assert physical
        path = source / 'scoreboard.sv'
        text = path.read_text()
        old, new = {
            'pending': ('(phys_pending_i[commit_sel_slot[i]] ||', "(1'b0 ||"),
            'mod': ('(phys_mod_i && mem_q[commit_sel_slot[i]].sbe.fu', "(1'b0 && mem_q[commit_sel_slot[i]].sbe.fu"),
        }[mutation]
        assert text.count(old) == 1, 'retirement mutation site changed'
        path.write_text(text.replace(old, new))
        hashes['scoreboard-original.sv'] = hashes['scoreboard.sv']
        hashes['scoreboard.sv'] = digest(path)
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    assert digest(runtime / 'include/verilated_funcs.h') == 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    env = dict(os.environ, VERILATOR_ROOT=str(runtime), VPATH=str(runtime / 'include'))
    # No -Werror-UNOPTFLAT: the scoreboard's issue_pointer/commit_pointer
    # vectors have a pre-existing intra-vector dependence (next = prev + 1)
    # that Verilator flags but converges on; the rtl-audit runner likewise
    # only enforces it on the memdep leaf.
    verilator = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1',
                 '-Wno-fatal', '-Werror-LATCH', '-DG6LC_FETCH_B',
                 '-I' + str(source), '--top-module', 'tb_g6lc_sbcommit']
    builds = [('model', [])]
    # Mutant: popcount free accounting — a committed hole aliases as
    # allocatable space and dispatch overwrites a live slot (SBC_NO_OVERWRITE).
    builds.append(('model-mut', ['-DG6LC_MUT_SB_POPCOUNT_FREE']))
    if physical:
        builds = [('model', ['-GPHYS=1'])]
    for mdir, extra in builds:
        command = verilator + extra + ['--Mdir', str(out / mdir), '-o', 'sbcommit',
                                       *inputs]
        (out / f'command-{mdir}.json').write_text(json.dumps(command, indent=2))
        with (out / f'build-{mdir}.log').open('w') as log:
            build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                   env=env, timeout=240)
            assert build.returncode == 0, f'Verilator failed: {mdir}'
            build = subprocess.run(['make', '-C', str(out / mdir), '-f', 'Vtb_g6lc_sbcommit.mk', '-j4'],
                                   stdout=log, stderr=subprocess.STDOUT, env=env, timeout=240)
        if build.returncode:
            print((out / f'build-{mdir}.log').read_text()[-6000:])
            raise RuntimeError(f'sbcommit leaf build failed ({mdir})')
        deps = '\n'.join(path.read_text() for path in (out / mdir).glob('*.d'))
        assert str(runtime / 'include/verilated_funcs.h') in deps, 'compiled runtime mismatch'
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
    if physical:
        passes = []
        codes = {7: 'SBC_PHYS_PENDING', 8: 'SBC_PHYS_EXCEPTION',
                 9: 'SBC_PHYS_PROGRESS', 10: 'SBC_PHYS_TWO_HARTS'}
        cases = [7 if mutation == 'pending' else 9] if mutation else list(codes)
        for scenario in cases:
            for negative in ([False] if mutation else [False, True]):
                error = ('SBC_PHYS_PENDING' if mutation == 'pending' else 'SBC_PHYS_MOD') if mutation else codes[scenario] if negative else None
                passes.append((str(out / 'model/sbcommit'), [f'+scenario={scenario}'] +
                               (['+oracle_negative'] if negative else []),
                               f'sim-s{scenario}-negative{int(negative)}.log',
                               lambda rc, text, error=error: (rc != 0 and error in text and 'RTL_REVIEW_PASS' not in text)
                               if error else (rc == 0 and text.count('RTL_REVIEW_PASS') == 1 and '%Error' not in text)))
    results = []
    for binary, args_extra, log_name, matched in passes:
        run = subprocess.run([binary, *args_extra], capture_output=True, text=True,
                             timeout=30)
        text = run.stdout + run.stderr
        (out / log_name).write_text(text)
        print(text)
        outcome = matched(run.returncode, text)
        results.append({'log': log_name, 'rc': run.returncode, 'matched': outcome,
                        'modelSha256': digest(Path(binary)), 'physical': physical,
                        'mutation': mutation})
        (out / 'results.json').write_text(json.dumps(results, indent=2))
        if not outcome:
            raise RuntimeError(f'sbcommit leaf test failed: {log_name}')
    print(f'SBCOMMIT_LEAF_PASS records={len(results)} physical={physical} mutation={mutation}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
