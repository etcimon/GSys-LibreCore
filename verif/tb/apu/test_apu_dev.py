# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded harness tests using fake tools and simulations, never RTL."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class DevelopmentHarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='apu dev ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tb = self.root / 'verif/tb/apu'
        self.tb.mkdir(parents=True)
        here = Path(__file__).parent
        for name in ('run-apu-dev.sh', 'local-verilator.sh', 'apu_dev_preflight.py',
                     'apu_vlt_policy.py', 'apu-verilator.sh', 'apu_sim_pgo.py',
                     'apu_sim_training.py', 'verilator-pgo-cxx.sh'):
            shutil.copyfile(here / name, self.tb / name)
        flist = self.root / 'corev_apu/apu/Flist.apu_vgtop'
        flist.parent.mkdir(parents=True)
        flist.write_text('// empty fixture\n')
        for name in ('tb_apu_mp_mem.sv', 'tb_g6lc_apu_vgtop.sv',
                     'apu_axi.vlt', 'apu_exec.vlt'):
            (self.tb / name).write_text('// fixture\n')
        self.builder = self.tb / 'build-apu-vgtop.sh'
        self.builder.write_text('echo built > "$APU_VGTOP_OUT/toolchain.txt"\n')
        self.home = self.root / 'tool'
        (self.home / 'bin').mkdir(parents=True)
        (self.home / 'include').mkdir()
        (self.home / 'include/verilated.h').touch()
        (self.home / 'bin/verilator_includer').touch()
        for name in ('verilator', 'verilator_bin'):
            file = self.home / 'bin' / name
            file.write_text('#!/bin/sh\necho "Verilator 5.008"\n')
            file.chmod(0o755)
        self.identity = self.root / 'compiler.id'
        self.identity.write_text('a' * 64 + '\n')
        (self.home / 'source.id').write_text('snapshot-sha256=' + 'a' * 64 + '\n')
        self.out = self.root / 'cache'
        (self.out / 'sim').mkdir(parents=True)
        self.sim = self.out / 'sim/tb_g6lc_apu_vgtop'
        self.sim.write_text('#!/bin/sh\necho "PASS tb_g6lc_apu_vgtop cases=1 checks=2 cycles=3"\n')
        self.sim.chmod(0o755)
        self.vectors = self.tb / 'vn_vectors'
        self.vectors.mkdir()
        for name in ('ue_gpos_tri_1', 'ue_gpos_fsubo_1', 'ue_gpos_fsubocopy_1',
                     'ue_cpos_dcopy_descarr_1', 'ue_cpos_imm_texlod_1',
                     'ue_cpos_imm_copy_1', 'ue_cpos_imm_array_1'):
            for ext in ('.hex', '.exp', '.json'):
                (self.vectors / (name + ext)).write_text('fixture\n')
        self.env = dict(os.environ, APU_VERILATOR_HOME=str(self.home),
                        APU_VERILATOR_SOURCE_ID_FILE=str(self.identity),
                        APU_VGTOP_OUT=str(self.out), APU_AUTO_INSTALL='0',
                        APU_DEV_TEST_TIMEOUT='1', APU_DEV_BUILD_TIMEOUT='1',
                        APU_DEV_COHORT='baseline', APU_VERILATOR_PGO='0', APU_SIM_PGO='0')
        self.env.pop('VERILATOR', None)
        self.env.pop('VERILATOR_ROOT', None)

    def run_harness(self, *args):
        return subprocess.run(['bash', str(self.tb / 'run-apu-dev.sh'), *args],
                              env=self.env, capture_output=True, text=True, timeout=10)

    def test_check_has_no_build_or_log_side_effect(self):
        self.builder.write_text('exit 97\n')
        result = self.run_harness('--check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.out / 'dev.lock').exists())

    def test_missing_oracle_fails_before_build(self):
        (self.vectors / 'ue_gpos_tri_1.exp').unlink()
        result = self.run_harness()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertFalse((self.out / 'toolchain.txt').exists())

    def test_missing_explicit_tool_is_detected_without_build(self):
        self.env['VERILATOR'] = str(self.root / 'absent-verilator')
        self.assertEqual(self.run_harness('--check').returncode, 3)
        self.assertFalse((self.out / 'toolchain.txt').exists())

    def test_small_cohort_records_selection(self):
        result = self.run_harness('--immutable')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len((self.out / 'dev/selected.txt').read_text().splitlines()), 3)

    def test_zero_checked_success_is_not_a_pass(self):
        self.sim.write_text('#!/bin/sh\necho "PASS tb_g6lc_apu_vgtop checks=0"\n')
        self.assertEqual(self.run_harness().returncode, 4)

    def test_failure_diagnostic_overrides_pass(self):
        with self.sim.open('a') as stream:
            stream.write('echo "FAIL wrong output"\n')
        self.assertEqual(self.run_harness().returncode, 1)

    def test_simulator_timeout_is_preserved(self):
        self.sim.write_text('#!/bin/sh\nsleep 5\n')
        self.assertEqual(self.run_harness().returncode, 124)

    def test_build_timeout_is_preserved(self):
        self.builder.write_text('sleep 5\n')
        self.assertEqual(self.run_harness().returncode, 124)

    def test_bad_budget_fails_before_build(self):
        self.env['APU_DEV_TEST_TIMEOUT'] = '0'
        self.assertEqual(self.run_harness().returncode, 2)


if __name__ == '__main__':
    unittest.main()
