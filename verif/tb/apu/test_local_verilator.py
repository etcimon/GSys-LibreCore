#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Local tool selection tests; never builds or invokes a system Verilator."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).with_name('local-verilator.sh')


class LocalToolTests(unittest.TestCase):
    def select(self, home, *, receipt='expected\n', binary=True, jobs='2',
               explicit=False, runtime=True, ensure=False, auto='1'):
        bindir = home / 'bin'
        bindir.mkdir(exist_ok=True)
        launcher = bindir / 'verilator'
        launcher.write_text('#!/bin/sh\necho "Repo test tool"\n')
        launcher.chmod(0o755)
        if runtime:
            (bindir / 'verilator_includer').write_text('runtime')
            (home / 'include').mkdir(exist_ok=True)
            (home / 'include/verilated.h').write_text('runtime')
        if binary:
            (bindir / 'verilator_bin').write_text('repo binary')
            (bindir / 'verilator_bin').chmod(0o755)
        if receipt is not None:
            (home / 'source.id').write_text(receipt)
        env = dict(os.environ, APU_VERILATOR_HOME=str(home),
                   APU_BUILD_JOBS=jobs, APU_AUTO_INSTALL=auto, APU_VERILATOR_PGO='0',
                   APU_SIM_PGO='0')
        env.pop('VERILATOR', None)
        env.pop('VERILATOR_ROOT', None)
        if explicit:
            if receipt is None:
                external = home / 'external-verilator'
                external.write_text(launcher.read_text())
                external.chmod(0o755)
                env['VERILATOR'] = str(external)
            else:
                env['VERILATOR'] = str(launcher)
        select = 'apu_ensure_verilator' if ensure else 'apu_select_verilator'
        return subprocess.run([
            'bash', '-c', 'set -euo pipefail; source "$1"; '
            'apu_verilator_source_id() { printf "expected\\n"; }; '
            'timeout() { echo "unexpected installation" >&2; return 97; }; '
            + select + '; OUT="$2"; apu_record_verilator',
            'test', str(HELPER), str(home)], env=env,
            capture_output=True, text=True)

    def test_launcher_without_binary_never_falls_back(self):
        with tempfile.TemporaryDirectory(prefix='apu tool ') as d:
            result = self.select(Path(d), binary=False)
            self.assertEqual(result.returncode, 2)
            self.assertIn('Build tools/verilator first', result.stderr)

    def test_stale_source_receipt_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(self.select(Path(d), receipt='old\n').returncode, 2)

    def test_matching_source_records_root_and_binary_hash(self):
        with tempfile.TemporaryDirectory(prefix='apu tool ') as d:
            home = Path(d)
            result = self.select(home)
            self.assertEqual(result.returncode, 0, result.stderr)
            text = (home / 'toolchain.txt').read_text()
            self.assertIn('root=' + str(home), text)
            self.assertIn('Repo test tool', text)
            self.assertIn('expected', text)
            self.assertIn('verilator_bin', text)

    def test_explicit_remote_override_is_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.select(Path(d), binary=False, receipt=None,
                                 explicit=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_inherited_repository_selection_keeps_provenance(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            result = self.select(home, explicit=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('verilator_bin', (home / 'toolchain.txt').read_text())

    def test_invalid_parallelism_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(self.select(Path(d), jobs='0').returncode, 2)

    def test_missing_runtime_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(self.select(Path(d), runtime=False).returncode, 2)

    def test_warm_ensure_never_installs(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.select(Path(d), ensure=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_no_auto_install_is_a_tools_blocker(self):
        with tempfile.TemporaryDirectory() as d:
            result = self.select(Path(d), binary=False, ensure=True, auto='0')
            self.assertEqual(result.returncode, 3, result.stderr)

    def test_snapshot_identity_requires_a_digest(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'source.id'
            for value, rc in (('a' * 64, 0), ('invalid', 2)):
                path.write_text(value + '\n')
                result = subprocess.run(
                    ['bash', '-c', 'source "$1"; apu_verilator_source_id',
                     'test', str(HELPER)],
                    env=dict(os.environ, APU_VERILATOR_SOURCE_ID_FILE=str(path)),
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, rc, result.stderr)


if __name__ == '__main__':
    unittest.main()
