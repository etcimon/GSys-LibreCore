# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Simulator PGO policy/identity tests; no model compilation or SSH."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import apu_sim_pgo as pgo
from apu_sim_training import option, training_passed, training_plan

HERE = Path(__file__).parent


class SimulatorPgoTests(unittest.TestCase):
    def test_runtime_source_identity_invalidates_unchanged_compiler_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compiler = root / 'verilator'
            compiler.write_bytes(b'launcher')
            source_id = root / 'source.id'
            source_id.write_text('first runtime/source identity\n')
            with patch.dict(os.environ, VERILATOR_ROOT=str(root)), \
                    patch.object(pgo, 'source_state', return_value='source'):
                first = pgo.request(root, str(compiler), [], root / 'model', {'files': []})
                source_id.write_text('second runtime/source identity\n')
                second = pgo.request(root, str(compiler), [], root / 'model', {'files': []})
            self.assertEqual(first['compilerBinarySha256'], second['compilerBinarySha256'])
            self.assertNotEqual(first['compilerSourceIdSha256'], second['compilerSourceIdSha256'])

    def test_binary_and_custom_main_keep_generation_not_build(self):
        result = pgo.verilate_only(['--binary', '--assert', '--Mdir', 'old',
                                   '--top-module', 'top', '-o', 'sim'], Path('/new'))
        self.assertNotIn('--binary', result)
        self.assertEqual(result[-2:], ['--Mdir', '/new'])
        self.assertIn('--main', result)
        self.assertIn('--timing', result)
        custom = pgo.verilate_only(['--cc', '--exe', '--build', 'main.cpp',
                                   '-Mdir=old'], Path('/new'))
        self.assertNotIn('--build', custom)
        self.assertNotIn('--main', custom)
        self.assertIn('main.cpp', custom)

    def test_options_and_missing_values(self):
        self.assertEqual(option(['-Mdir=one', '--Mdir', 'two'], '-Mdir', '--Mdir'), 'two')
        with self.assertRaises(ValueError):
            option(['--top-module'], '--top-module')

    def test_training_cannot_pass_from_exit_code_or_zero_checks(self):
        expect = r'^PASS tb\b'
        self.assertTrue(training_passed('PASS tb checks=2\n', expect))
        for text in ('', 'PASS tb checks=0\n', 'FAIL bad\nPASS tb checks=2\n',
                     '%Error abort\nPASS tb checks=2\n', 'PASS other checks=4\n'):
            self.assertFalse(training_passed(text, expect))

    def test_receipt_checks_binary_and_profile_use(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'sim'
            binary.write_bytes(b'profile-use image')
            request = {'sourceSha256': 'source'}
            identity = pgo.hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()
            report = dict(schemaVersion=1, mode='profile-use', requestSha256=identity,
                          request=request,
                          binary=str(binary), binarySha256=pgo.sha(binary),
                          profileCount=1, profileUseReturnCode=0, trainingPassed=True)
            self.assertTrue(pgo.receipt_valid(report, identity))
            self.assertFalse(pgo.receipt_valid(report, 'different'))
            for key, value in (('mode', 'generate'), ('profileCount', 0),
                               ('profileCount', True), ('trainingPassed', False),
                               ('profileUseReturnCode', 1)):
                self.assertFalse(pgo.receipt_valid({**report, key: value}, identity))
            binary.write_bytes(b'replaced')
            self.assertFalse(pgo.receipt_valid(report, identity))

    def test_missing_training_inputs_fail_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(FileNotFoundError):
                training_plan(Path(directory), 'tb_g6lc_apu_vgtop', [], Path(directory))
            with self.assertRaises(ValueError):
                training_plan(Path(directory), 'unknown_service', [], Path(directory))

    def test_source_changes_and_snapshot_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'verif/tb/apu/test.sv'
            source.parent.mkdir(parents=True)
            source.write_text('module one; endmodule\n')
            with patch.dict(os.environ, {}, clear=False):
                os.environ.pop('APU_SIM_SOURCE_ID', None)
                os.environ.pop('APU_SOURCE_FILES', None)
                before = pgo.source_state(root)
                source.write_text('module two; endmodule\n')
                self.assertNotEqual(pgo.source_state(root), before)
                os.environ['APU_SIM_SOURCE_ID'] = before
                with self.assertRaises(ValueError):
                    pgo.source_state(root)

    def test_publish_binds_an_immutable_image_in_per_run_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = root / 'immutable-image'
            image.write_bytes(b'image')
            mdir = root / 'output'
            evidence = root / 'run'
            report = dict(top='tb', binary=str(image), binarySha256=pgo.sha(image))
            with patch.dict(os.environ, APU_SIM_RECEIPT_DIR=str(evidence)):
                pgo.publish(report, 'id', mdir, 'sim')
            self.assertTrue((mdir / 'sim').is_symlink())
            record = json.loads((evidence / 'tb-id.json').read_text())
            self.assertEqual(record['binary'], str(image))
            self.assertEqual(json.loads((mdir / 'simulator-pgo.json').read_text())['binary'],
                             str(image))

    def test_dev_remote_defaults_to_detached_incomplete_not_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            python = Path(directory) / 'python3'
            python.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            python.chmod(0o755)
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'],
                       APU_LEAF_STAGES='dev')
            for key in ('APU_LEAF_DETACH', 'APU_LEAF_TIMEOUT'):
                env.pop(key, None)
            result = subprocess.run(['bash', str(HERE / 'run-apu-remote-leaf.sh')],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 4, result.stderr)
            self.assertIn('--detach', result.stdout)
            self.assertIn('launch only', result.stdout)
            env['APU_LEAF_DETACH'] = '0'
            result = subprocess.run(['bash', str(HERE / 'run-apu-remote-leaf.sh')],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('--detach', result.stdout)


if __name__ == '__main__':
    unittest.main()
