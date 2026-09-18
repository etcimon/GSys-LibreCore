#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Review runner for g6lc_inval_retain — the external-invalidation retention on the
# HPDCACHE read-response seam.
#
# Why this is a runner and not a hand-run bench: the overflow path is unreachable
# from software (every full-core test reports backpressured=0, including one written
# to provoke it), so this unit bench is the ONLY place the depth is qualified. A
# check that only exists in a shell history is a check that silently stops running.
#
# Three arms, because a passing bench on its own proves very little:
#   * positive  — scenarios 0/1/2 must pass at DEPTH 1, 2 and 4. DEPTH=1 is the
#                 depth cva6_hpdcache_subsystem actually instantiates, so it is not
#                 optional coverage; 2 and 4 additionally exercise pointer wrap.
#   * negative  — +oracle_negative perturbs the OBSERVED stream, so the conservation
#                 checker itself must fire. This caught a real weakness: the control
#                 was originally inert at DEPTH=1.
#   * REVIEW_RETAIN_FAULT=1 — restores the ORIGINAL defect (`inval_ready_o = 1'b1`,
#                 unconditional acceptance with no room). The bench must catch it, or
#                 it would not have caught the P0 this unit was written to fix.

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

NAMES = ['g6lc_inval_retain.sv', 'tb_g6lc_inval_retain.sv']
DEPTHS = [1, 2, 4]
SCENARIOS = [0, 1, 2]

#  Where each input lives in the repo, so this runner does NOT depend on the
#  review harness's --data upload step. With that dependency it could only be
#  driven through the `remote py` wrapper, which blocks the local CLI for the whole
#  run and needs one round trip per arm; resolving from the repo instead lets both
#  arms run in a single plain-ssh invocation on the builder, where the repo is
#  already synced.
REPO_PATHS = {
    'g6lc_inval_retain.sv': 'core/cache_subsystem/g6lc_inval_retain.sv',
    'tb_g6lc_inval_retain.sv': 'verif/tb/uncore/tb_g6lc_inval_retain.sv',
}


def resolve_input(name, data, repo):
    """Prefer an uploaded copy; otherwise take the file from the repo checkout."""
    staged = data / name
    if staged.is_file():
        return staged
    direct = repo / REPO_PATHS[name]
    if direct.is_file():
        return direct
    raise SystemExit(f'cannot find {name}: looked in {staged} and {direct}')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    run = Path(os.environ.get('TH_RUN_DIR', '.')).resolve()
    data = Path(os.environ.get('TH_DATA_DIR', run / 'data')).resolve()
    repo = Path(os.environ.get('TH_REPO_DIR', Path.cwd())).resolve()
    fault = os.environ.get('REVIEW_RETAIN_FAULT') == '1'
    #  Default the output somewhere writable and arm-specific, so a standalone run
    #  needs no wrapper and the two arms cannot overwrite each other's evidence.
    default_out = Path('/tmp') / ('retain-review-fault' if fault else 'retain-review')
    out = Path(os.environ.get('TH_OUT_DIR', default_out)).resolve()
    source = out / 'source'
    source.mkdir(parents=True, exist_ok=True)

    for name in NAMES:
        (source / name).write_bytes(resolve_input(name, data, repo).read_bytes())

    if fault:
        path = source / 'g6lc_inval_retain.sv'
        text = path.read_text()
        # The original defect: claim readiness unconditionally, so an invalidation
        # arriving with no room is accepted and overwritten instead of held.
        old = '  assign inval_ready_o = ~full;'
        new = '  assign inval_ready_o = 1\'b1;'
        assert text.count(old) == 1, 'fault injection site changed'
        path.write_text(text.replace(old, new))

    (out / 'sources.json').write_text(json.dumps(
        {n: digest(source / n) for n in NAMES}, indent=2))

    ver = subprocess.run(['verilator', '--version'], capture_output=True, text=True)
    (out / 'runtime.json').write_text(json.dumps(
        {'verilator': ver.stdout.strip(), 'fault': fault}, indent=2))

    top = 'tb_g6lc_inval_retain'
    results = []
    for depth in DEPTHS:
        model = out / f'model-d{depth}'
        model.mkdir(parents=True, exist_ok=True)
        verilate = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert',
                    '--threads', '1', '-Wno-fatal', '-Wno-TIMESCALEMOD',
                    '-Werror-LATCH', '-Werror-UNOPTFLAT',
                    f'-GDEPTH={depth}', '--top-module', top,
                    '--Mdir', str(model), '-o', 'retain',
                    *[str(source / n) for n in NAMES]]
        for label, cmd in (('verilate', verilate),
                           ('build', ['make', '-C', str(model), '-f', f'V{top}.mk', '-j4'])):
            log = out / f'{label}-d{depth}.log'
            with log.open('w') as fh:
                rc = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT,
                                    timeout=900).returncode
            assert rc == 0, f'{label} d={depth}: see {log}'

        exe = model / 'retain'
        # Positive trials. In the fault arm the expectation is NOT "every scenario
        # fails": scenario 1 only checks that nothing is injected while the channel
        # is busy, and unconditional readiness does not disturb that, so it passes
        # with the fault present. Demanding otherwise made the runner abort on a
        # correct scenario. A fault control should assert that the SUITE catches the
        # defect, not that every case does, so each scenario is recorded and the
        # requirement is checked across them below.
        trials = [(s, False, None) for s in SCENARIOS]
        # The negative control is meaningful in both arms: it must always fire.
        trials.append((0, True, 'RETAIN_NEGATIVE_CAUGHT'))
        for scenario, negative, expected in trials:
            cmd = [str(exe), f'+scenario={scenario}']
            if negative:
                cmd.append('+oracle_negative')
            log = out / f'd{depth}-s{scenario}-neg{int(negative)}.log'
            with log.open('w') as fh:
                p = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT, timeout=300)
            text = log.read_text(errors='replace')
            #  "Caught" means the defect was reported by EITHER the bench's checkers
            #  or the unit's own assertions. Looking only for RETAIN_ERRORS made a
            #  real detection look like a runner failure: at DEPTH>1 the injected
            #  fault overruns the occupancy bound, so g6lc_inval_retain's own
            #  assertion fires first and the bench never reaches its summary.
            #  Only meaningful for positive trials: the negative control REPORTS
            #  errors by design, so counting it as a "fault detected" would make the
            #  clean arm's results.json read as though the good RTL had faults found
            #  in it.
            reported = p.returncode != 0 and (
                'RETAIN_ERRORS' in text
                or 'RETAIN_LOSS' in text
                or 'RETAIN_SURPLUS' in text
                or 'RETAIN_ORDER' in text
                or 'RETAIN_ACCEPT_COUNT' in text
                or 'g6lc_inval_retain:' in text)
            #  Two distinct notions, conflated once already: `reported` is "errors
            #  came out at all", `detected` is "the injected FAULT was caught". Only
            #  the latter excludes the negative control, which reports by design.
            detected = (not negative) and reported
            if expected is not None:
                #  In the fault arm the unit's assertion can abort the run before the
                #  bench prints its negative-control token, which is a detection, not
                #  a miss — so accept either there.
                matched = p.returncode != 0 and (expected in text or (fault and reported))
            elif fault:
                #  Record; the across-scenario requirement is asserted after the loop.
                matched = True
            else:
                matched = p.returncode == 0 and 'RTL_REVIEW_PASS' in text
            # Scenario 0 must genuinely fill the slot; a run that never back-pressures
            # has not tested the overflow path, whatever its verdict says.
            bp_ok = True
            if expected is None and not fault and scenario == 0:
                bp_ok = 'backpressured=0' not in text
                if not bp_ok:
                    matched = False
            results.append({'depth': depth, 'scenario': scenario, 'negative': negative,
                            'rtlFault': fault, 'expectedError': expected,
                            'rc': p.returncode, 'backPressureSeen': bp_ok,
                            'faultDetected': detected,
                            'matched': matched, 'executableSha256': digest(exe)})
            (out / 'results.json').write_text(json.dumps(results, indent=2))
            assert matched, (depth, scenario, negative, expected)

        if fault:
            #  The defect must be caught at every depth, and specifically by the
            #  conservation/overflow scenario — that is the case it exists for.
            caught = [r for r in results
                      if r['depth'] == depth and not r['negative'] and r['faultDetected']]
            assert caught, f'fault not detected at depth {depth}'
            assert any(r['scenario'] == 0 for r in caught),                 f'fault not detected by the conservation scenario at depth {depth}'

    print(f'RETAIN REVIEW OK records={len(results)} fault={fault}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
