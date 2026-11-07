#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Offline two-pass compiler PGO in a private, retained build attempt."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from apu_vlt_policy import recipe_id, unroll_flags


def run(command, cwd, env, log, timeout):
    with log.open('w') as output:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            rc = process.wait(timeout=timeout)
        except BaseException:
            # Only this invocation's new process group, never a name-based kill.
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
    if rc:
        raise RuntimeError(f'command exit {rc}; see {log}')


def prepare_runtime(src, build):
    # Preserve configure-generated headers/makefiles, never overlay stale
    # generated files from a developer's source checkout.
    for source in (src / 'include').rglob('*'):
        target = build / 'include' / source.relative_to(src / 'include')
        if source.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        elif not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    for name in ('verilator', 'verilator_includer'):
        target = build / 'bin' / name
        shutil.copy2(src / 'bin' / name, target)
        target.chmod(target.stat().st_mode | 0o100)


def build_pgo(src, home, jobs):
    scripts = Path(__file__).parent
    recipe = recipe_id()
    source_id = (home / 'source.pending').read_text()
    cxx = shutil.which('g++')
    if cxx is None:
        raise RuntimeError('PGO requires GCC g++')
    version = subprocess.check_output([cxx, '--version'], text=True, timeout=10)
    if 'Free Software Foundation' not in version:
        raise RuntimeError('PGO requires GCC/gcov, not a Clang-compatible driver')
    attempt = Path(tempfile.mkdtemp(prefix='pgo-build-', dir=home))
    if any(c.isspace() for c in str(attempt)):
        raise ValueError('GNU Make compiler build paths cannot contain whitespace')
    build = attempt / 'build'
    build.mkdir()
    (attempt / 'profile').mkdir()
    (attempt / 'compiler').write_text(str(Path(cxx).resolve()))
    (attempt / 'phase').write_text('generate')
    wrapper = attempt / 'cxx.sh'
    shutil.copy2(scripts / 'verilator-pgo-cxx.sh', wrapper)
    wrapper.chmod(0o755)
    env = dict(os.environ, CXX=str(wrapper), CXXFLAGS='-O3', LDFLAGS='',
               CCACHE_DISABLE='1', OBJCACHE='')
    env.pop('VERILATOR_ROOT', None)
    env.pop('VERILATOR_NO_OPT_BUILD', None)
    # This compiler fork permits environment overrides after command-line flags.
    env.update(VERILATOR_UNROLL_COUNT='256', VERILATOR_UNROLL_STMTS='131072',
               VERILATOR_UNROLL_ROLL_NARROW='0')
    deadline = time.monotonic() + int(env.get('APU_TOOL_SETUP_TIMEOUT', '1200'))

    def execute(command, cwd, name, limit=None):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(command, 0)
        run(command, cwd, env, attempt / name,
            min(remaining, limit) if limit else remaining)

    execute(['autoconf', '-o', str(build / 'configure')], src, 'autoconf.log')
    execute(['bash', str(build / 'configure'), '--srcdir=' + str(src),
             '--prefix=' + str(home / 'install')], build, 'configure.log')
    make = ['make', '-C', str(build / 'src'), '-j', str(jobs), 'OBJCACHE=']
    execute([*make, 'opt'], build, 'generate.log')
    prepare_runtime(src, build)
    env['VERILATOR_ROOT'] = str(build)
    loops = []
    for threads in (1, 2):
        out = attempt / f'train-{threads}'
        execute([str(build / 'bin/verilator'), '--cc', '--timing', '--assert',
                 '-Wall', '--threads', str(threads), *unroll_flags(),
                 '--top-module', 'vlt_pgo_train', '--Mdir', str(out),
                 str(scripts / 'vlt_pgo_train.sv')],
                scripts, f'train-{threads}.log', limit=60)
        stats = (out / 'Vvlt_pgo_train__stats.txt').read_text()
        match = re.search(r'Unrolled Loops[^0-9\n]*([0-9]+)', stats)
        if not match or int(match[1]) <= 0:
            raise RuntimeError(f'no measured loop unrolling in training: {out}')
        loops.append(int(match[1]))
    profiles = [p for p in (attempt / 'profile').rglob('*.gcda') if p.stat().st_size]
    for name in ('Verilator', 'V3Unroll', 'V3Order', 'V3SplitVar'):
        if not any(name in p.name for p in profiles):
            raise RuntimeError(f'missing compiler training profile: {name}')
    (attempt / 'phase').write_text('use')
    # Same object paths, forced recompilation, no clean/distclean/deletion.
    execute([*make, '-B', 'opt'], build, 'use.log')
    if recipe != recipe_id():
        raise RuntimeError('PGO recipe changed during build; receipt not published')
    use_log = (attempt / 'use.log').read_text(errors='replace')
    if 'PGO-CXX phase=use' not in use_log:
        raise RuntimeError('profile-use compiler invocations not observed')
    (home / 'bin').mkdir(exist_ok=True)
    shutil.copytree(build / 'include', home / 'include', dirs_exist_ok=True)
    for name in ('verilator_bin', 'verilator', 'verilator_includer'):
        shutil.copy2(build / 'bin' / name, home / 'bin' / name)
    report = {
        'schemaVersion': 1, 'mode': 'profile-use', 'recipeSha256': recipe,
        'sourceId': source_id, 'compiler': version.strip(),
        'binarySha256': hashlib.sha256((home / 'bin/verilator_bin').read_bytes()).hexdigest(),
        'profileCount': len(profiles), 'trainingThreads': [1, 2],
        'unrollFlags': unroll_flags(), 'unrolledLoops': loops,
        'profileUseReturnCode': 0, 'attempt': str(attempt),
        'missingProfileWarnings': use_log.count('warning:') if 'missing-profile' in use_log else 0,
        'simulatorPgo': False,
    }
    pending = home / 'pgo.pending.json'
    pending.write_text(json.dumps(report, indent=2) + '\n')
    pending.replace(home / 'pgo.json')
    print(f'COMPILER PGO OK profiles={len(profiles)} loops={loops} receipt={home / "pgo.json"}')


if __name__ == '__main__':
    # Propagate the outer timeout into cleanup of our private subprocess group.
    signal.signal(signal.SIGTERM, lambda _signum, _frame: sys.exit(124))
    parser = argparse.ArgumentParser()
    parser.add_argument('--src', type=Path, required=True)
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--jobs', type=int, required=True)
    args = parser.parse_args()
    try:
        if args.jobs <= 0:
            raise ValueError('jobs must be positive')
        build_pgo(args.src.resolve(), args.home.resolve(), args.jobs)
    except subprocess.TimeoutExpired as error:
        print(f'BLOCKED: PGO setup/training timeout: {error}', flush=True)
        raise SystemExit(124)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'BLOCKED: PGO compiler build: {error}', flush=True)
        raise SystemExit(3)
