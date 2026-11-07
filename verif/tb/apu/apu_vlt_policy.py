#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Shared compiler PGO recipe and bounded RTL-unroll policy."""
import hashlib
import json
from pathlib import Path
import sys

PGO_INPUTS = ('apu_vlt_policy.py', 'apu_verilator_pgo.py',
              'verilator-pgo-cxx.sh', 'vlt_pgo_train.sv')
UNROLL_COUNT = 256
UNROLL_STMTS = 131072


def unroll_flags():
    return ['--unroll-count', str(UNROLL_COUNT),
            '--unroll-stmts', str(UNROLL_STMTS), '--stats']


def recipe_id():
    root = Path(__file__).parent
    files = [(name, hashlib.sha256((root / name).read_bytes()).hexdigest())
             for name in PGO_INPUTS]
    return hashlib.sha256(json.dumps(files, separators=(',', ':')).encode()).hexdigest()


def validate_receipt(home):
    home = Path(home)
    try:
        report = json.loads((home / 'pgo.json').read_text())
        binary = home / 'bin/verilator_bin'
        return (report['schemaVersion'] == 1 and report['mode'] == 'profile-use'
                and report['recipeSha256'] == recipe_id()
                and report['sourceId'] == (home / 'source.id').read_text()
                and report['binarySha256'] == hashlib.sha256(binary.read_bytes()).hexdigest()
                and type(report['profileCount']) is int and report['profileCount'] > 0
                and report['trainingThreads'] == [1, 2]
                and report['unrollFlags'] == unroll_flags()
                and len(report['unrolledLoops']) == 2
                and all(type(n) is int and n > 0 for n in report['unrolledLoops'])
                and report['profileUseReturnCode'] == 0)
    except (OSError, ValueError, KeyError, TypeError):
        return False


if __name__ == '__main__':
    if len(sys.argv) == 2 and sys.argv[1] == '--flags':
        print('\n'.join(unroll_flags()))
    elif len(sys.argv) == 3 and sys.argv[1] == '--check':
        sys.exit(0 if validate_receipt(sys.argv[2]) else 1)
    elif len(sys.argv) == 2 and sys.argv[1] == '--recipe':
        print(recipe_id())
    else:
        sys.exit(2)
