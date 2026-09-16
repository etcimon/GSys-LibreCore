# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import subprocess
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import testharness_proxy as proxy


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


if __name__ == '__main__':
    unittest.main()
