# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import testharness_proxy as proxy


class SourceProfileVerdictTests(unittest.TestCase):
    def test_requires_supervisor_completion_from_both_harts(self):
        from run_opensbi_source_review import source_passed
        log = '[rvfi_tracer] INFO: Simulation terminated after 800 cycles'
        trace = '\n'.join(f'1 0x80200000 (0x00303023) mem {address:#x} 0x1'
                          for address in (0x80201000, 0x80201080, 0x80201088))
        self.assertTrue(source_passed(0, log, trace, {0: 10, 1: 20}, 0x80201000, 0x80201080))
        failures = [(1, log, trace, {0: 10, 1: 20}),
                    (0, '*** SUCCESS *** after 8000000 cycles', trace, {0: 10, 1: 20}),
                    (0, log, trace.replace('1 0x80200000', '3 0x80200000'), {0: 10, 1: 20}),
                    (0, log, '\n'.join(trace.splitlines()[:2]), {0: 10, 1: 20}),
                    (0, log, trace, {0: 10, 1: 0}),
                    (0, log, trace.replace('0x80201000 0x1', '0x80201000 0x3'), {0: 10, 1: 20})]
        for rc, output, events, counts in failures:
            with self.subTest(rc=rc, output=output, events=events, counts=counts):
                self.assertFalse(source_passed(rc, output, events, counts, 0x80201000, 0x80201080))


class BalanceMetricsTests(unittest.TestCase):
    def fixture(self):
        symbols = {'balance_begin0': 0x100, 'balance_begin1': 0x104,
                   'balance_loop': 0x110, 'balance_xor': 0x114, 'balance_dec': 0x118,
                   'balance_branch': 0x11c, 'balance_loop_end': 0x120,
                   'balance_end0': 0x130, 'balance_end1': 0x134}
        rows = []
        def add(hart, pc):
            rows.append(f'[smt-flow] retire cycle={len(rows) + 1} port=0 id=1 gen={len(rows)} '
                        f'hart={hart} pc={pc:016x} valid=1 drop=0 ex=0')
        add(0, 0x100)
        add(1, 0x104)
        for _ in range(2):
            for h in (0, 1):
                for pc in (0x110, 0x114, 0x118, 0x11c):
                    add(h, pc)
        add(0, 0x130)
        add(1, 0x134)
        return symbols, rows

    def test_checks_both_workers_without_claiming_fairness(self):
        from run_smt2_soak_review import balance_metrics
        symbols, rows = self.fixture()
        report = balance_metrics('\n'.join(rows), symbols, iterations=2)
        self.assertEqual(report['bodyRetirements'], {0: 8, 1: 8})
        self.assertEqual(report['commonRetirementShare'], {0: 0.5, 1: 0.5})
        self.assertFalse(report['boundedFairnessProven'])
        self.assertFalse(report['saturationQualified'])

    def test_rejects_missing_reordered_duplicated_or_wrong_owner_events(self):
        from run_smt2_soak_review import balance_metrics
        symbols, rows = self.fixture()
        mutations = [[], rows[:-1], rows[:2] + rows[3:], rows[:3] + [rows[2]] + rows[3:],
                     [rows[0].replace('hart=0', 'hart=1'), *rows[1:]],
                     rows[:2] + [rows[3], rows[2]] + rows[4:],
                     [rows[0].replace('cycle=1', 'cycle=oops'), *rows[1:]],
                     [r.replace('pc=0000000000000114', 'pc=0000000000000118') for r in rows],
                     [r.replace('hart=1', 'hart=2') for r in rows],
                     [r.replace('valid=1', 'valid=0') for r in rows]]
        for bad in mutations:
            with self.subTest(events=bad[:3]):
                with self.assertRaises(ValueError):
                    balance_metrics('\n'.join(bad), symbols, iterations=2)

    def test_solo_does_not_accept_peer_work(self):
        from run_smt2_soak_review import balance_metrics
        symbols, rows = self.fixture()
        solo = [r for r in rows if 'hart=0 ' in r]
        report = balance_metrics('\n'.join(solo), symbols, active_harts=(0,), iterations=2)
        self.assertEqual(report['activeHarts'], [0])
        with self.assertRaises(ValueError):
            balance_metrics('\n'.join(rows), symbols, active_harts=(0,), iterations=2)


class FetchBSourceBoundaryTests(unittest.TestCase):
    def test_generated_sources_refuse_legacy_inputs(self):
        from run_smt2_soak_review import check_fetch_b_sources
        clean = '/repo/core/fetch_B/frontend.sv /repo/core/smt/g6lc_issue_barrier.sv'
        check_fetch_b_sources(clean)
        check_fetch_b_sources(clean.replace('/', '\\'))
        for path in ('/repo/core/fetch_A/frontend/frontend.sv',
                     '/repo/core/smt_legacy/g6lc_issue_barrier.sv',
                     '/repo/core/Flist.smt_legacy'):
            with self.subTest(path=path):
                with self.assertRaises(RuntimeError):
                    check_fetch_b_sources(clean + ' ' + path)
                with self.assertRaises(RuntimeError):
                    check_fetch_b_sources((clean + ' ' + path).replace('/', '\\'))
        with self.assertRaises(RuntimeError):
            check_fetch_b_sources('/repo/core/smt/g6lc_issue_barrier.sv')

    def test_active_manifests_exclude_legacy_paths(self):
        root = Path(__file__).resolve().parents[3]
        variables = {'CVA6_REPO_DIR': root.as_posix(), 'TARGET_CFG': 'g6lc64_smt2',
                     'HPDCACHE_DIR': (root / 'core/cache_subsystem/hpdcache').as_posix()}
        visited = set()
        sources = []

        def visit(path):
            path = path.resolve()
            if path in visited:
                return
            visited.add(path)
            for raw in path.read_text(encoding='utf-8').splitlines():
                line = raw.split('//', 1)[0].strip()
                if not line:
                    continue
                for key, value in variables.items():
                    line = line.replace('${' + key + '}', value)
                self.assertNotRegex(line, r'(?:^|/)(?:fetch_A|smt_legacy)(?:/|$)')
                self.assertNotIn('Flist.smt_legacy', line)
                if line.startswith(('-f ', '-F ')):
                    nested = Path(line[3:].strip())
                    visit(nested if nested.is_absolute() else path.parent / nested)
                elif not line.startswith('+'):
                    source = Path(line)
                    source = source if source.is_absolute() else path.parent / source
                    self.assertTrue(source.is_file(), str(source))
                    sources.append(source.resolve())

        visit(root / 'core/Flist.cva6')
        self.assertIn((root / 'core/fetch_B/frontend.sv').resolve(), sources)
        self.assertEqual(len([p for p in sources if p.parent == (root / 'core/smt').resolve()]), 9)


class ArtifactTransferTests(unittest.TestCase):
    def remote(self):
        remote = proxy.Remote.__new__(proxy.Remote)
        remote.host = 'test-host'
        remote.base_opts = lambda: []
        return remote

    def test_pull_failure_is_not_success(self):
        result = subprocess.CompletedProcess(['rsync'], 11)
        with patch.object(proxy.subprocess, 'run', return_value=result):
            with self.assertRaises(subprocess.CalledProcessError) as error:
                self.remote().pull('/run/output/', Mock())
        self.assertEqual(error.exception.returncode, 11)

    def test_successful_pull(self):
        result = subprocess.CompletedProcess(['rsync'], 0)
        with patch.object(proxy.subprocess, 'run', return_value=result):
            self.remote().pull('/run/output/', Mock())

    def test_py_destination_option(self):
        args = proxy.build_parser().parse_args(['py', 'script.py', '--pull', '--dest', '/artifacts/run/output'])
        self.assertTrue(args.pull)
        self.assertEqual(args.dest, '/artifacts/run/output')

    def test_py_default_destination(self):
        args = proxy.build_parser().parse_args(['py', 'script.py', '--pull'])
        self.assertIsNone(args.dest)

    def test_pull_one_existing_run(self):
        args = proxy.build_parser().parse_args(['pull', '--tag', 'selected-run', '--dest', '/artifacts/run'])
        remote = Mock(host='test-host')
        self.assertEqual(proxy.cmd_pull(remote, args), 0)
        remote.pull.assert_called_once_with(f'{proxy.REMOTE_ROOT}/runs/selected-run/output/', Path('/artifacts/run'))

    def test_pull_rejects_path_traversal(self):
        args = proxy.build_parser().parse_args(['pull', '--tag', '../other'])
        remote = Mock(host='test-host')
        with self.assertRaises(SystemExit):
            proxy.cmd_pull(remote, args)
        remote.start_master.assert_not_called()


@unittest.skipUnless(shutil.which('bash'), 'bash is required for soak-driver tests')
class SoakDriverTests(unittest.TestCase):
    def run_driver(self, text, rc=0, *, missing_harness=False, missing_hold=False):
        with tempfile.TemporaryDirectory(prefix='soak-oracle-') as tmp:
            root = Path(tmp)
            scripts = root / 'verif' / 'regress'
            scripts.mkdir(parents=True)
            driver = scripts / 'soft-ladder-opensbi-soak.sh'
            original = Path(__file__).resolve().parents[1] / driver.name
            driver.write_bytes(original.read_bytes())
            model = root / 'work-ver-smt2'
            model.mkdir()
            harness = model / 'Variane_testharness'
            harness.write_text(
                "#!/usr/bin/env bash\nprintf '%s\\n' \"$FAKE_SOAK_LOG\"\nexit \"$FAKE_SOAK_RC\"\n",
                encoding='utf-8', newline='\n')
            harness.chmod(0o755)
            firmware = root / 'firmware' / 'build'
            firmware.mkdir(parents=True)
            elf = firmware / 'fw_payload_r3a_c15_plat_skip.elf'
            elf.write_bytes(b'fake ELF for runner-only oracle tests')
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(('SOFT_', 'PEEL_', 'CVA6_', 'G6LC_'))}
            env.update({
                'SOFT_LADDER_SKIP_BUILD': '1',
                'SOFT_LADDER_FETCH': 'B',
                'SOFT_LADDER_HARNESS': str(root / 'missing' if missing_harness else model),
                'SOFT_LADDER_DIR': str(firmware.parent),
                'SOFT_LADDER_OSBI_OUT': str(root / 'logs'),
                'SOFT_LADDER_WALL_TIMEOUT': '5',
                'FAKE_SOAK_LOG': text,
                'FAKE_SOAK_RC': str(rc),
            })
            if missing_hold:
                env['SOFT_LADDER_HOLD'] = '1'
            else:
                env['SOFT_LADDER_ELF'] = str(elf)
            return subprocess.run(['bash', str(driver)], env=env, cwd=root,
                                  capture_output=True, text=True, timeout=15)

    def test_cookie_success(self):
        for text in ('[cookie-exit] t=42 [1000]=0x51b1babe',
                     '[trapdump] [1000]=0000000051b1babe [1008]=0',
                     '[cookie-exit] t=42 [1000]=0x51b1babe00000000'):
            with self.subTest(text=text):
                result = self.run_driver(text)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('CLASSIFY=SUCCESS', result.stdout)

    def test_process_failure_preserves_status(self):
        result = self.run_driver('[trapdump] [1000]=0', 17)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('rc=17', result.stdout)

    def test_timeout_banner_is_not_success(self):
        result = self.run_driver('*** SUCCESS *** (tohost = 0) after 12000000 cycles')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('CLASSIFY=SUCCESS', result.stdout)

    def test_partial_or_unbound_cookie_is_not_success(self):
        for text in ('[cookie-exit] t=42 [1000]=0x51b1c001',
                     '[cookie-exit] t=42',
                     '[trapdump] [1000]=151b1babe0',
                     '[trapdump] [1000]=0 [1008]=51b1babe'):
            with self.subTest(text=text):
                result = self.run_driver(text)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn('CLASSIFY=SUCCESS', result.stdout)

    def test_cookie_does_not_hide_harness_failure(self):
        for rc in (124, 126, 127, 134, 137):
            with self.subTest(rc=rc):
                result = self.run_driver('[trapdump] [1000]=51b1babe', rc)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(f'rc={rc}', result.stdout)
                self.assertNotIn('CLASSIFY=SUCCESS', result.stdout)

    def test_explicit_missing_model_cannot_fall_back(self):
        result = self.run_driver('[trapdump] [1000]=51b1babe', missing_harness=True)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertNotIn('CLASSIFY=SUCCESS', result.stdout)

    def test_missing_hold_cannot_use_natural_payload(self):
        result = self.run_driver('[trapdump] [1000]=51b1babe', missing_hold=True)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertNotIn('CLASSIFY=SUCCESS', result.stdout)


if __name__ == '__main__':
    unittest.main()
