#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Detached PGO build of the tools/verilator fork, trained on a hyp8
closure (testharness_proxy.py py --data <closure>).

  TH_DATA_DIR      closure from build_closure.py --mc (manifest.json verified)
  TH_OUT_DIR       launch record (launch.json) and the installer log
  VLT_SRC          fork checkout on the builder (default the pgo-src tree)
  VLT_PREFIX       install prefix (default verilator-v5.008-g6lc-pgo)
  VLT_PIN          expected fork commit; the checkout must already be there
  JOBS             make -j for both compiler builds

The installer runs in its own session (nohup/setsid semantics) so the ssh
channel can close; poll TH_OUT_DIR/install.log and TH_OUT_DIR/exit-code.

VLT_PGO_MODE=verilate instead runs one synchronous verilate-only harness
build with an existing prefix (VLT_HOME, default the qualified fork) at
HYP8_THREADS (4) for HYP8_TARGET (g6lc64_hyp8_mc) and prints the split /
unroll / MTask census -- the check that the threaded build really gets
unroll-before-split with split_var targets."""
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import time


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def verilate(root, out):
    home = os.environ.get('VLT_HOME', '/opt/testharness/toolchains/verilator-v5.008-g6lc')
    vroot = f'{home}/runtime' if Path(f'{home}/runtime').is_dir() else f'{home}/share/verilator'
    mdir = out / 'mdir'
    env = dict(os.environ, CVA6_REPO_DIR=str(root), VERILATOR_FLAVOUR='g6lc',
               VLT_HOME=home, VERILATOR_ROOT=vroot,
               SOFT_LADDER_BUILD_TARGET=os.environ.get('HYP8_TARGET', 'g6lc64_hyp8_mc'),
               SOFT_LADDER_VERILATOR_THREADS=os.environ.get('HYP8_THREADS', '4'),
               SOFT_LADDER_VERLIB=str(mdir), HYP8_BUILD_VERILATE_ONLY='1')
    t0 = time.time()
    ru0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    with (out / 'harness.log').open('w') as fh:
        rc = subprocess.run(['bash', 'verif/regress/remote/hyp8/hyp8-build-harness.sh', 'hyp8'],
                            cwd=str(root), env=env, stdout=fh, stderr=subprocess.STDOUT).returncode
    ru1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = {'userSeconds': round(ru1.ru_utime - ru0.ru_utime, 1),
           'sysSeconds': round(ru1.ru_stime - ru0.ru_stime, 1),
           'maxRssMiB': round(ru1.ru_maxrss / 1024, 1)}
    stats = mdir / 'Vg6lc_testharness__stats.txt'
    keep = ('SplitVar', 'Unroll', 'MTask', 'Threads', 'Optimizations, Split', 'Scheduling')
    census = [l.rstrip() for l in stats.read_text(errors='replace').splitlines()
              if any(k in l for k in keep)] if stats.is_file() else []
    build_log = (mdir / 'build.log').read_text(errors='replace') if (mdir / 'build.log').is_file() else ''
    record = {'rc': rc, 'seconds': round(time.time() - t0, 1), **cpu, 'vltHome': home,
              'verilatorBinSha256': digest(f'{home}/bin/verilator_bin'),
              'target': env['SOFT_LADDER_BUILD_TARGET'],
              'threads': env['SOFT_LADDER_VERILATOR_THREADS'],
              'splitVarRefusals': build_log.count('%Warning-SPLITVAR'),
              'unoptflat': build_log.count('UNOPTFLAT'),
              'userError': build_log.count('%Warning-USERERROR'),
              'census': census}
    (out / 'verilate.json').write_text(json.dumps(record, indent=2))
    print((out / 'harness.log').read_text(errors='replace')[-4000:])
    print('HYP8_MT_VERILATE ' + json.dumps(record))
    return rc


def build(root, out):
    """VLT_PGO_MODE=build: full harness build (verilate + C++), detached.
    Poll TH_OUT_DIR/build.log and TH_OUT_DIR/exit-code; the model lands in
    TH_OUT_DIR/mdir/Variane_testharness."""
    home = os.environ.get('VLT_HOME', '/opt/testharness/toolchains/verilator-v5.008-g6lc')
    vroot = f'{home}/runtime' if Path(f'{home}/runtime').is_dir() else f'{home}/share/verilator'
    env = dict(os.environ, CVA6_REPO_DIR=str(root), VERILATOR_FLAVOUR='g6lc',
               VLT_HOME=home, VERILATOR_ROOT=vroot,
               SOFT_LADDER_BUILD_TARGET=os.environ.get('HYP8_TARGET', 'g6lc64_hyp8_mc'),
               SOFT_LADDER_VERILATOR_THREADS=os.environ.get('HYP8_THREADS', '4'),
               SOFT_LADDER_BUILD_JOBS=os.environ.get('JOBS', '4'),
               SOFT_LADDER_VERLIB=str(out / 'mdir'),
               SPIKE_INSTALL_DIR=os.environ.get('SPIKE_INSTALL_DIR', '/opt/testharness/toolchains/spike'),
               RISCV=os.environ.get('RISCV', '/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3'))
    log, rc_file = out / 'build.log', out / 'exit-code'
    cmd = ['bash', '-c', f'bash verif/regress/remote/hyp8/hyp8-build-harness.sh hyp8 > {log} 2>&1; echo $? > {rc_file}']
    proc = subprocess.Popen(cmd, env=env, cwd=str(root), stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    record = {'pid': proc.pid, 'mode': 'build', 'vltHome': home,
              'verilatorBinSha256': digest(f'{home}/bin/verilator_bin'),
              'target': env['SOFT_LADDER_BUILD_TARGET'],
              'threads': env['SOFT_LADDER_VERILATOR_THREADS'],
              'jobs': env['SOFT_LADDER_BUILD_JOBS'], 'closure': str(root),
              'log': str(log), 'exitCodeFile': str(rc_file)}
    (out / 'launch.json').write_text(json.dumps(record, indent=2))
    print('HYP8_BUILD_LAUNCHED ' + json.dumps(record))
    return 0


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    roots = [m.parent for m in data.rglob('manifest.json')]
    assert len(roots) == 1, f'expected one closure manifest, found {len(roots)}'
    root = roots[0]
    files = json.loads((root / 'manifest.json').read_text())['files']
    bad = [rel for rel, sha in files.items()
           if not (root / rel).is_file() or digest(root / rel) != sha]
    assert not bad, f'closure hash mismatch: {bad[:5]}'

    if os.environ.get('VLT_PGO_MODE') == 'verilate':
        return verilate(root, out)
    if os.environ.get('VLT_PGO_MODE') == 'build':
        return build(root, out)

    src = os.environ.get('VLT_SRC', '/opt/testharness/src/verilator-g6lc-pgo-src')
    prefix = os.environ.get('VLT_PREFIX',
                            '/opt/testharness/toolchains/verilator-v5.008-g6lc-pgo')
    pin = os.environ.get('VLT_PIN', '')
    head = subprocess.run(['git', '-C', src, 'rev-parse', 'HEAD'],
                          capture_output=True, text=True).stdout.strip()
    if pin:
        assert head.startswith(pin), f'{src} is at {head}, expected {pin}'
    dirty = subprocess.run(['git', '-C', src, 'status', '--porcelain',
                            '--untracked-files=no'],
                           capture_output=True, text=True).stdout.strip()
    assert not dirty, f'{src} has tracked modifications:\n{dirty}'

    env = dict(os.environ, REPO_ROOT=str(root), VLT_SRC=src, VLT_PREFIX=prefix,
               VLT_PIN=head, VLT_PGO='1', JOBS=os.environ.get('JOBS', '6'))
    script = root / 'build-platform/scripts/install-verilator-g6lc.sh'
    log = out / 'install.log'
    rc_file = out / 'exit-code'
    cmd = ['bash', '-c',
           f'bash {script} > {log} 2>&1; echo $? > {rc_file}']
    proc = subprocess.Popen(cmd, env=env, cwd=str(root),
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True)
    record = {'pid': proc.pid, 'started': time.strftime('%Y-%m-%dT%H:%M:%S'),
              'closure': str(root), 'closureFiles': len(files),
              'manifestSha256': digest(root / 'manifest.json'),
              'installerSha256': digest(script),
              'src': src, 'srcHead': head, 'prefix': prefix,
              'jobs': env['JOBS'], 'log': str(log), 'exitCodeFile': str(rc_file)}
    (out / 'launch.json').write_text(json.dumps(record, indent=2))
    print('VLT_PGO_LAUNCHED ' + json.dumps(record))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
