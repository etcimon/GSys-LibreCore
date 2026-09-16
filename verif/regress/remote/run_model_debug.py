#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    out = Path(os.environ['TH_OUT_DIR'])
    records = json.loads(Path(os.environ['DEBUG_RESULTS']).read_text())
    record = next(r for r in records if r['tag'] == os.environ['DEBUG_TAG'] and r['payload'] == os.environ['DEBUG_PAYLOAD'])
    command = record['command']
    assert sha(Path(command[0])) == record['modelSha256']
    assert sha(Path(command[-1])) == record['elfSha256']
    environment = {'PATH': '/usr/bin:/bin', 'CVA6_TRACE_SPEC': '; '.join(record['traceRules'])}
    watch = os.environ.get('DEBUG_WATCH_ENV', '0') == '1'
    results = []
    for trial in ([] if watch else range(2)):
        work = out / f'replay-{trial}'
        work.mkdir()
        with (work / 'sim.log').open('w') as log:
            run = subprocess.run(command, cwd=work, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=240)
        results.append({'trial': trial, 'rc': run.returncode, 'logSha256': sha(work / 'sim.log')})
    debugger = shutil.which('gdb')
    if not debugger:
        raise RuntimeError('gdb is not provisioned')
    instructions = ['set pagination off', 'set disable-randomization off']
    if watch:
        instructions += ['set startup-with-shell off', 'break main', 'run', 'p/x environ', 'x/6gx environ', 'watch -l environ[0]', 'watch -l environ[1]', 'watch -l environ[2]', 'watch -l environ[3]', 'continue', 'bt', 'x/6gx environ', 'x/10i $pc-20', 'info registers rax rbx rcx rdx rsi rdi rbp rsp r8 r9 r10 r11 r12 r13 r14 r15']
    else:
        instructions += ['run', 'bt']
    debug_command = [debugger, '-nx', '--batch', *[arg for instruction in instructions for arg in ('-ex', instruction)], '--args', *command]
    work = out / 'gdb'
    work.mkdir()
    with (out / 'gdb.log').open('w') as log:
        debug = subprocess.run(debug_command, cwd=work, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=240)
    assert sha(Path(command[0])) == record['modelSha256']
    assert sha(Path(command[-1])) == record['elfSha256']
    generated = out / 'generated'
    generated.mkdir()
    model_dir = Path(command[0]).parent
    for path in model_dir.glob('Variane_testharness___024root__*.cpp'):
        if '___eval_initial__TOP(' in path.read_text(errors='replace'):
            shutil.copy2(path, generated / path.name)
    for name in ['Variane_testharness.cpp', 'Variane_testharness.mk', 'Variane_testharness__verFiles.dat']:
        if (model_dir / name).is_file():
            shutil.copy2(model_dir / name, generated / name)
    makefile = (model_dir / 'Variane_testharness.mk').read_text()
    runtime = Path(re.search(r'^VERILATOR_ROOT\s*=\s*(.+)$', makefile, re.M)[1].strip())
    for name in ['verilated_funcs.h', 'verilated.h', 'verilated.mk']:
        shutil.copy2(runtime / 'include' / name, generated / name)
    version = subprocess.check_output([str(runtime / 'verilator_bin'), '--version'], text=True)
    (out / 'generator-version.txt').write_text(version)
    (out / 'debug.json').write_text(json.dumps({'source': record, 'replays': results, 'debugCommand': debug_command, 'debugRc': debug.returncode}, indent=2))
    print(results)
    print((out / 'gdb.log').read_text()[-16000:])


if __name__ == '__main__':
    main()
