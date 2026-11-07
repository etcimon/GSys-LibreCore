# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Optimization receipts/driver flags, without building a compiler or simulator."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import apu_vlt_policy as policy

HERE = Path(__file__).parent


class PgoPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='apu pgo ')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / 'bin').mkdir()
        (self.home / 'include').mkdir()
        (self.home / 'include/verilated.h').touch()
        for name in ('verilator', 'verilator_bin', 'verilator_includer'):
            path = self.home / 'bin' / name
            path.write_text('#!/bin/sh\nexit 0\n')
            path.chmod(0o755)
        (self.home / 'source.id').write_text('expected\n')
        self.report = {
            'schemaVersion': 1, 'mode': 'profile-use',
            'sourceId': 'expected\n', 'recipeSha256': policy.recipe_id(),
            'binarySha256': hashlib.sha256((self.home / 'bin/verilator_bin').read_bytes()).hexdigest(),
            'profileCount': 4, 'trainingThreads': [1, 2],
            'unrollFlags': policy.unroll_flags(), 'unrolledLoops': [3, 3],
            'profileUseReturnCode': 0,
        }

    def publish(self):
        (self.home / 'pgo.json').write_text(json.dumps(self.report))

    def select(self):
        return subprocess.run(
            ['bash', '-c', 'source "$1"; apu_verilator_source_id() { printf "expected\\n"; }; '
             'apu_select_verilator && printf "%s %s %s\\n" "$VERILATOR_UNROLL_COUNT" '
             '"$VERILATOR_UNROLL_STMTS" "$VERILATOR_UNROLL_ROLL_NARROW"',
             'test', str(HERE / 'local-verilator.sh')],
            env=dict(os.environ, APU_VERILATOR_HOME=str(self.home), APU_VERILATOR_PGO='1',
                     APU_SIM_PGO='0',
                     VERILATOR=str(self.home / 'bin/verilator'), VERILATOR_UNROLL_COUNT='1',
                     VERILATOR_UNROLL_ROLL_NARROW='1'),
            capture_output=True, text=True)

    def test_unprofiled_cache_is_not_a_pgo_tool(self):
        self.assertFalse(policy.validate_receipt(self.home))
        self.assertEqual(self.select().returncode, 2)

    def test_cli_does_not_read_new_script_bytes_after_a_long_build(self):
        text = (HERE / 'local-verilator.sh').read_text()
        main = 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then'
        prefix, suffix = text.rsplit(main, 1)
        # Emulate an in-flight entrypoint edit without changing repository code.
        override = ('apu_build_verilator() { '
                    'printf "\\necho unexpected-continuation; exit 99\\n" >> "$0"; }\n')
        script = self.home / 'entrypoint.sh'
        script.write_text(prefix + override + main + suffix)
        result = subprocess.run(['bash', str(script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('unexpected-continuation', result.stdout)

    def test_matching_receipt_and_actual_unroll_overrides(self):
        self.publish()
        self.assertTrue(policy.validate_receipt(self.home))
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '256 131072 0')

    def test_recipe_binary_source_and_training_must_match(self):
        original = dict(self.report)
        for key, value in (
                ('mode', 'generate'), ('recipeSha256', 'bad'), ('sourceId', 'stale'),
                ('binarySha256', 'bad'), ('profileCount', 0), ('profileCount', True),
                ('unrolledLoops', [0, 3]), ('trainingThreads', [1]),
                ('profileUseReturnCode', 1)):
            with self.subTest(key=key, value=value):
                self.report = {**original, key: value}
                self.publish()
                self.assertFalse(policy.validate_receipt(self.home))

    def test_wrapper_instruments_then_uses_same_profile_directory(self):
        wrapper = self.home / 'cxx.sh'
        shutil.copy2(HERE / 'verilator-pgo-cxx.sh', wrapper)
        compiler = self.home / 'fake-gcc'
        compiler.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        compiler.chmod(0o755)
        (self.home / 'compiler').write_text(str(compiler))
        for phase, expected in (('generate', '-fprofile-generate='),
                                ('use', '-fprofile-use=')):
            (self.home / 'phase').write_text(phase)
            result = subprocess.run(['bash', str(wrapper), '-c', 'V3Unroll.cpp'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected + str(self.home / 'profile'), result.stdout)
            probe = subprocess.run(['bash', str(wrapper), 'conftest.cpp'],
                                   capture_output=True, text=True)
            self.assertEqual(probe.stdout.strip(), 'conftest.cpp')
        (self.home / 'phase').write_text('invalid')
        self.assertEqual(subprocess.run(['bash', str(wrapper), '-c', 'test.cpp'],
                                       capture_output=True).returncode, 2)


if __name__ == '__main__':
    unittest.main()
