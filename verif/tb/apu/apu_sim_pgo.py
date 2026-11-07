#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Auto-provision profile-use simulator images in immutable, keyed attempts."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import re
import uuid

import apu_source_manifest
from apu_sim_training import option, training_passed, training_plan
from apu_verilator_pgo import run
from apu_vlt_policy import unroll_flags

HERE = Path(__file__).parent


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def budget(name, default):
    value = os.environ.get(name, str(default))
    if not value.isdecimal() or int(value) <= 0:
        raise ValueError(f'{name} must be positive seconds')
    return int(value)


def source_state(root):
    files = None
    if os.environ.get('APU_SOURCE_FILES'):
        files = Path(os.environ['APU_SOURCE_FILES']).read_text().splitlines()
    result = apu_source_manifest.manifest(root, 'dev', None, files=files)
    identity = result['sourceSha256']
    expected = os.environ.get('APU_SIM_SOURCE_ID')
    if expected and identity != expected:
        raise ValueError('source snapshot identity mismatch; no cached image is eligible')
    return identity


def recipe_id():
    names = ('apu_sim_pgo.py', 'apu_sim_training.py', 'apu-verilator.sh',
             'verilator-pgo-cxx.sh')
    return hashlib.sha256(json.dumps([(name, sha(HERE / name)) for name in names]).encode()).hexdigest()


def canonical(value, root, mdir):
    return value.replace(str(mdir), '@model@').replace(str(root), '@source@')


def request(root, compiler, arguments, mdir, plan):
    inputs = set(plan['files'])
    for value in arguments:
        if value.startswith(('-', '+')):
            continue
        path = Path(value)
        if path.is_file():
            inputs.add(str(path))
    inputs = [(canonical(name, root, mdir), sha(name)) for name in sorted(inputs)]
    root_binary = Path(os.environ.get('VERILATOR_ROOT', '')) / 'bin/verilator_bin'
    binary = root_binary if root_binary.is_file() else Path(compiler)
    source_id = Path(os.environ.get('VERILATOR_ROOT', '')) / 'source.id'
    cxx = shutil.which('g++')
    if not cxx:
        raise ValueError('simulator PGO requires GCC g++ (not installed automatically)')
    if not shutil.which('make'):
        raise ValueError('simulator PGO requires make (not installed automatically)')
    version = subprocess.check_output([cxx, '--version'], text=True, timeout=10)
    if 'Free Software Foundation' not in version:
        raise ValueError('simulator PGO requires GCC/gcov')
    controls = ('TARGET_CFG', 'HPDCACHE_DIR', 'VERILATOR_UNROLL_COUNT',
                'VERILATOR_UNROLL_STMTS', 'VERILATOR_UNROLL_ROLL_NARROW',
                'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS')
    build_env = {name: hashlib.sha256(os.environ.get(name, '').encode()).hexdigest()
                 for name in controls}
    return {
        'sourceSha256': source_state(root), 'recipeSha256': recipe_id(),
        'compilerBinarySha256': sha(binary), 'cxx': str(Path(cxx).resolve()),
        'compilerSourceIdSha256': sha(source_id) if source_id.is_file() else None,
        'launcherSha256': sha(compiler),
        'cxxSha256': sha(cxx), 'cxxVersion': version.strip(),
        'arguments': [canonical(a, root, mdir) for a in arguments],
        'training': {k: canonical(json.dumps(v, sort_keys=True), root, mdir)
                     for k, v in plan.items()},
        'trainingInputs': inputs, 'optFast': '-O3', 'optSlow': '-O2',
        'buildEnvironmentSha256': build_env,
    }


def receipt_valid(report, identity):
    try:
        binary = Path(report['binary'])
        return (report['schemaVersion'] == 1 and report['mode'] == 'profile-use'
                and report['requestSha256'] == identity
                and identity == hashlib.sha256(
                    json.dumps(report['request'], sort_keys=True).encode()).hexdigest()
                and type(report['profileCount']) is int and report['profileCount'] > 0
                and report['profileUseReturnCode'] == 0
                and report['trainingPassed'] is True
                and binary.is_file() and report['binarySha256'] == sha(binary))
    except (KeyError, OSError, TypeError, ValueError):
        return False


def publish(report, identity, mdir, executable):
    # Readers bind the immutable binary from this per-run receipt, not the
    # compatibility symlink another invocation might subsequently replace.
    mdir.mkdir(parents=True, exist_ok=True)
    alias = mdir / executable
    temporary = mdir / ('.pgo-link-' + uuid.uuid4().hex)
    temporary.symlink_to(report['binary'])
    temporary.replace(alias)
    evidence = os.environ.get('APU_SIM_RECEIPT_DIR')
    target = (Path(evidence) / (report['top'] + '-' + identity + '.json')
              if evidence else mdir / 'simulator-pgo.json')
    target.parent.mkdir(parents=True, exist_ok=True)
    data = dict(report, runSourceRoot=os.environ.get('CVA6_REPO_DIR'))
    pending = target.with_suffix('.pending-' + str(os.getpid()))
    pending.write_text(json.dumps(data, indent=2) + '\n')
    pending.replace(target)
    # Keep the image binding next to the conventional executable as well.
    binding = mdir / 'simulator-pgo.json'
    if binding != target:
        local = binding.with_suffix('.pending-' + str(os.getpid()))
        local.write_text(json.dumps(data, indent=2) + '\n')
        local.replace(binding)
    print(f'SIMULATOR PGO READY mode=profile-use binary={report["binary"]} receipt={target}')


def verilate_only(arguments, build):
    result = []
    skip = False
    for argument in arguments:
        if skip:
            skip = False
            continue
        if argument in ('--binary', '--build'):
            continue
        if argument in ('-Mdir', '--Mdir'):
            skip = True
            continue
        if argument.startswith(('-Mdir=', '--Mdir=')):
            continue
        result.append(argument)
    if '--binary' in arguments:
        result.extend(['--cc', '--exe', '--main'])
        if '--timing' not in arguments and '--no-timing' not in arguments:
            result.append('--timing')
    return [*result, '--Mdir', str(build)]


def provision(compiler, arguments):
    root = Path(os.environ.get('CVA6_REPO_DIR', HERE.parents[2])).resolve()
    top = option(arguments, '--top-module')
    if not top:
        raise ValueError('simulator PGO requires an explicit --top-module')
    mdir = Path(option(arguments, '-Mdir', '--Mdir', default='obj_dir')).resolve()
    prefix = option(arguments, '--prefix', default='V' + top)
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', prefix):
        raise ValueError('invalid generated model prefix')
    executable = option(arguments, '-o', default=prefix)
    if Path(executable).name != executable or executable in ('', '.', '..'):
        raise ValueError('simulator output must be a plain filename')
    plan = training_plan(root, top, arguments, mdir)
    for value in [*arguments, *(os.environ.get(k, '') for k in
                                ('CXXFLAGS', 'CPPFLAGS', 'LDFLAGS'))]:
        if '-fprofile-' in value or '-fno-profile-' in value:
            raise ValueError('simulator profile flags are managed by the PGO driver')
    description = request(root, compiler, arguments, mdir, plan)
    identity = hashlib.sha256(json.dumps(description, sort_keys=True).encode()).hexdigest()
    base_cache = os.environ.get('APU_BUILD_CACHE',
                 str(Path(os.environ.get('XDG_CACHE_HOME', str(Path.home() / '.cache'))) /
                     'librecore/apu'))
    cache = Path(os.environ.get('APU_SIM_PGO_CACHE', str(Path(base_cache) / 'simulator-pgo')))
    home = cache / identity
    home.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + budget('APU_SIM_PGO_TIMEOUT', 1800)
    with (home / 'build.lock').open('a') as lock:
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired('simulator PGO lock', 0)
                time.sleep(.1)
        report_path = home / 'receipt.json'
        try:
            report = json.loads(report_path.read_text())
        except (OSError, ValueError):
            report = {}
        if receipt_valid(report, identity):
            if description != request(root, compiler, arguments, mdir, plan):
                raise ValueError('source/tool inputs changed while waiting for cache lock')
            publish(report, identity, mdir, executable)
            return
        if os.environ.get('APU_AUTO_INSTALL', '1') != '1':
            raise ValueError('profile-use simulator missing/stale; APU_AUTO_INSTALL=0')
        attempt = Path(tempfile.mkdtemp(prefix='attempt-', dir=home))
        build = attempt / 'model'
        (attempt / 'profile').mkdir()
        (attempt / 'phase').write_text('generate')
        (attempt / 'compiler').write_text(description['cxx'])
        wrapper = attempt / 'cxx.sh'
        shutil.copy2(HERE / 'verilator-pgo-cxx.sh', wrapper)
        wrapper.chmod(0o755)
        env = dict(os.environ, CCACHE_DISABLE='1', OBJCACHE='')
        for name in ('GCOV_PREFIX', 'GCOV_PREFIX_STRIP', 'GCOV_ERROR_FILE'):
            env.pop(name, None)

        def execute(command, cwd, name, limit):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, 0)
            run(command, cwd, env, attempt / name, min(limit, remaining))

        build_wait = budget('APU_SIM_BUILD_TIMEOUT', 600)
        execute([compiler, *verilate_only(arguments, build)], Path.cwd(),
                'verilate.log', build_wait)
        make = ['make', '-C', str(build), '-f', prefix + '.mk',
                '-j', str(budget('APU_BUILD_JOBS', 4)), '-B', 'OBJCACHE=',
                'CXX=' + str(wrapper), 'LINK=' + str(wrapper),
                'OPT_FAST=-O3', 'OPT_SLOW=-O2', 'OPT_GLOBAL=-O2']
        execute(make, build, 'generate.log', build_wait)
        image = build / executable
        train_logs = []
        for index, argv in enumerate(plan['cases']):
            name = f'train-{index}.log'
            execute([str(image), *argv], plan['cwd'], name,
                    budget('APU_SIM_TRAIN_TIMEOUT', 60))
            text = (attempt / name).read_text(errors='replace')
            if not training_passed(text, plan['expect']):
                raise ValueError(f'simulator training incomplete/failed: {attempt / name}')
            train_logs.append(name)
        profiles = [p for p in (attempt / 'profile').rglob('*.gcda') if p.stat().st_size]
        if not any(prefix in p.name for p in profiles):
            raise ValueError('training produced no generated-model gcov profile')
        (attempt / 'phase').write_text('use')
        execute(make, build, 'use.log', build_wait)
        use_log = (attempt / 'use.log').read_text(errors='replace')
        if 'PGO-CXX phase=use' not in use_log:
            raise ValueError('no observed native simulator profile-use compilation')
        # Never publish a cache entry from a moving implementation worktree.
        if description != request(root, compiler, arguments, mdir, plan):
            raise ValueError('source/tool/training inputs changed during PGO setup')
        logs = ('verilate.log', 'generate.log', *train_logs, 'use.log')
        report = {
            'schemaVersion': 1, 'mode': 'profile-use', 'top': top,
            'requestSha256': identity, 'request': description,
            'binary': str(image), 'binarySha256': sha(image),
            'profileCount': len(profiles), 'profileUseReturnCode': 0,
            'trainingPassed': True, 'trainingIsValidation': False,
            'buildSourceRoot': str(root),
            'logs': {name: {'path': str(attempt / name), 'sha256': sha(attempt / name)}
                     for name in logs},
        }
        pending = home / ('receipt.pending-' + str(os.getpid()))
        pending.write_text(json.dumps(report, indent=2) + '\n')
        pending.replace(report_path)
        publish(report, identity, mdir, executable)


def main():
    signal.signal(signal.SIGTERM, lambda _signal, _frame: sys.exit(124))
    compiler = shutil.which(os.environ.get('APU_REAL_VERILATOR', ''))
    if not compiler:
        raise ValueError('real repository compiler binding missing')
    arguments = sys.argv[1:]
    mode = os.environ.get('APU_SIM_PGO', '1')
    if mode not in ('0', '1'):
        raise ValueError('APU_SIM_PGO must be 0 or 1')
    if mode == '0' or not any(flag in arguments for flag in ('--binary', '--build')):
        os.execvpe(compiler, [compiler, *arguments], os.environ)
    provision(compiler, [*arguments, *unroll_flags()])


if __name__ == '__main__':
    try:
        main()
    except subprocess.TimeoutExpired as error:
        print(f'INCOMPLETE: simulator PGO timeout: {error}', file=sys.stderr)
        sys.exit(124)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'BLOCKED: simulator PGO: {error}', file=sys.stderr)
        sys.exit(3)
