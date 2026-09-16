#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def main():
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    inputs = []
    hashes = {}
    for name in ['config_pkg.sv', 'g6lc_smt_pc_bank.sv', 'tb_g6lc_restart.sv']:
        dest = source / name
        shutil.copy2(data / name, dest)
        inputs.append(str(dest))
        hashes[name] = hashlib.sha256(dest.read_bytes()).hexdigest()
    command = ['bash', '-c', '. /opt/testharness/env.sh; exec verilator "$@"', 'restart', '--binary', '--timing', '--assert', '--threads', '1', '-Wno-fatal', '-DG6LC_FETCH_B', '--top-module', 'tb_g6lc_restart', '--Mdir', str(out / 'model'), '-o', 'restart-test', *inputs]
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))
    (out / 'command.json').write_text(json.dumps(command, indent=2))
    with (out / 'build.log').open('w') as log:
        build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    if build.returncode:
        print((out / 'build.log').read_text()[-6000:])
        raise RuntimeError('restart bank build failed')
    run = subprocess.run([str(out / 'model/restart-test')], capture_output=True, text=True, timeout=30)
    text = run.stdout + run.stderr
    (out / 'sim.log').write_text(text)
    print(text)
    if run.returncode != 0 or text.count('RESTART_BANK_PASS') != 1:
        raise RuntimeError('restart bank test failed')


if __name__ == '__main__':
    main()
