#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Exercise overlay publication/resume rules on a disposable generated layout."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from g6lc_hyp8_tuning import OUTPUT, PREFIX, UnsupportedLayout, prepare


class NativeOverlayTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        core = PREFIX + "_g6lc_core__pi2"
        self.recipe = self.root / (PREFIX + "__verFiles.dat")
        self.recipe.write_text('C "-DG6LC_HYP8_MC --threads 2"\n')
        self.name = core + "__DepSet_h1__0"
        (self.root / (PREFIX + "_classes.mk")).write_text(
            "VM_PARALLEL_BUILDS = 1\nVM_CLASSES_FAST += \\\n\t" + self.name + " \\\n")
        self.source = self.root / (self.name + ".cpp")
        self.source.write_text("u_recover__DOT__input")
        (self.root / (core + ".h")).write_text("header")

    def test_resume_does_not_rewrite_or_relabel(self):
        with patch("g6lc_hyp8_tuning.lower", return_value=("packed", 2)), \
             patch("g6lc_hyp8_tuning.lower_columns", return_value=("tiled", 3)):
            summary = prepare(self.root)
        self.assertEqual(summary["translationUnits"], 1)
        self.assertEqual(self.source.read_text(), "u_recover__DOT__input")
        (self.root / "compiled.o").touch()
        self.assertEqual(prepare(self.root), summary)
        output = self.root / OUTPUT / self.source.name
        output.write_text("stale")
        with self.assertRaisesRegex(ValueError, "overlay changed"):
            prepare(self.root)
        output.write_text("tiled")
        self.source.write_text("new input")
        with self.assertRaisesRegex(ValueError, "overlay changed"):
            prepare(self.root)

    def test_no_coverage_or_legacy_objects(self):
        with self.assertRaises(UnsupportedLayout):
            prepare(self.root)
        self.assertFalse((self.root / OUTPUT).exists())
        (self.root / "compiled.o").touch()
        with self.assertRaisesRegex(ValueError, "cannot retrofit"):
            prepare(self.root)

    def test_wrong_resumed_schedule(self):
        self.recipe.write_text('C "-DG6LC_HYP8_SMT2 --threads 2"\n')
        with self.assertRaisesRegex(ValueError, "schedule"):
            prepare(self.root)
