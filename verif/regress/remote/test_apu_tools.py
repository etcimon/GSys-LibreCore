# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Offline source-closure tests. No remote access or compiler build."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import testharness_proxy as proxy


class CompilerClosureTests(unittest.TestCase):
    def test_config_templates_and_licenses_are_carried_without_secrets(self):
        with tempfile.TemporaryDirectory(prefix='apu tools ') as directory:
            root = Path(directory)
            base = root / 'tools/verilator'
            base.mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', str(base)], check=True)
            names = ('configure.ac', 'Makefile.in', 'src/Makefile.in',
                     'include/verilated.h', 'bin/verilator', 'install-sh',
                     'verilator.pc.in', 'verilator-config.cmake.in',
                     'verilator-config-version.cmake.in', 'LICENSE', 'Artistic')
            for name in names:
                path = base / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('fixture\n')
            subprocess.run(['git', '-C', str(base), 'add', '.'], check=True)
            (base / 'src/new.cpp').write_text('new source\n')
            (base / 'src/.env').write_text('not a tool source\n')
            (base / 'src/private.key').write_text('not a tool source\n')
            files = proxy.apu_verilator_sources(root)
            for name in (*names, 'src/new.cpp'):
                self.assertIn('tools/verilator/' + name, files)
            self.assertNotIn('tools/verilator/src/.env', files)
            self.assertNotIn('tools/verilator/src/private.key', files)

    def test_missing_source_is_a_fast_tools_blocker(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(SystemExit) as error:
                proxy.apu_verilator_sources(Path(directory))
            self.assertEqual(error.exception.code, 3)


if __name__ == '__main__':
    unittest.main()
