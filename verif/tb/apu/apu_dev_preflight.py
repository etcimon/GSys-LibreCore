#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Read-only presence checks; no compiler invocation or vector regeneration."""
from pathlib import Path
import shlex
import sys


def check_inputs(root, sessions):
    root = Path(root)
    seen = set()

    def present(path, directory=False):
        valid = path.is_dir() if directory else path.is_file()
        if not valid:
            raise FileNotFoundError(str(path))

    def flist(path):
        if path in seen:
            return
        present(path)
        seen.add(path)
        lines = iter(path.read_text().splitlines())
        for line in lines:
            words = shlex.split(line.split('//', 1)[0])
            words = [w.replace('${CVA6_REPO_DIR}', str(root)) for w in words]
            if not words:
                continue
            if words[0] in ('-f', '-F'):
                if len(words) != 2:
                    raise ValueError(f'invalid file list line: {line}')
                flist(Path(words[1]))
            else:
                for word in words:
                    if word.startswith('+incdir+'):
                        for directory in word[len('+incdir+'):].split('+'):
                            present(Path(directory), directory=True)
                    elif not word.startswith(('+', '-')):
                        present(Path(word))

    flist(root / 'corev_apu/apu/Flist.apu_vgtop')
    for name in ('tb_apu_mp_mem.sv', 'tb_g6lc_apu_vgtop.sv',
                 'apu_axi.vlt', 'apu_exec.vlt', 'local-verilator.sh',
                 'build-apu-vgtop.sh', 'apu-verilator.sh', 'apu_sim_pgo.py',
                 'apu_sim_training.py', 'verilator-pgo-cxx.sh'):
        present(root / 'verif/tb/apu' / name)
    for session in sessions:
        for suffix in ('.hex', '.exp', '.json'):
            present(root / 'verif/tb/apu/vn_vectors' / (session + suffix))
    return len(seen)


if __name__ == '__main__':
    try:
        count = check_inputs(Path(sys.argv[1]), sys.argv[2:])
        print(f'DEV INPUTS OK filelists={count} sessions={len(sys.argv) - 2}')
    except (OSError, ValueError) as error:
        print(f'BLOCKED: {error}', file=sys.stderr)
        sys.exit(3)
