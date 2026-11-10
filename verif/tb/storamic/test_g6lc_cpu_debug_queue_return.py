# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Unit coverage for the cpu-debug-return and cpu-debug-queue Verilator runners."""
import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CpuDebugReturnRunnerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runner = _load("run_cpu_debug_return")
        cls.program = _load("g6lc_cpu_debug_return_program")

    def test_case_inventory_is_full_matrix_plus_negatives(self):
        cases = self.runner._case_list()
        positives = [c for c in cases if not c["negative"]]
        negatives = [c for c in cases if c["negative"]]
        self.assertEqual(len(cases), 18)
        self.assertEqual(len(positives), 12)
        self.assertEqual(len(negatives), 6)
        # M/S/U x origin x delay positives.
        self.assertEqual(
            {(c["priv"], c["origin"], c["delay"]) for c in positives},
            {(p, o, d) for p in (0, 1, 3) for o in (0, 1) for d in (0, 16)})
        # Negatives: every priv/origin at delay16 with Negative=1.
        self.assertEqual(
            {(c["priv"], c["origin"], c["delay"]) for c in negatives},
            {(p, o, 16) for p in (0, 1, 3) for o in (0, 1)})

    def test_images_generate_for_all_privileges(self):
        cache = {}
        for priv in (0, 1, 3):
            img = self.runner._images(self.program, cache, priv)
            self.assertEqual(len(img["normal"].split()), 1024)
            self.assertEqual(len(img["debug"].split()), 1024)
            self.assertEqual(len(img["program_sha256"]), 64)
            self.assertEqual(len(img["debug_sha256"]), 64)
        self.assertEqual(set(cache), {0, 1, 3})

    def test_driver_and_interpreter_exist(self):
        for rel in (self.runner.DRIVER_REL, self.runner.INTERP_REL,
                    self.runner.NETLIST_REL):
            self.assertTrue((HERE.parents[2] / rel).is_file(), rel)


class CpuDebugQueueRunnerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runner = _load("run_cpu_debug_queue")
        cls.program = _load("g6lc_cpu_debug_program")

    def test_case_inventory_covers_stages_1_to_3(self):
        cases = self.runner._case_list()
        positives = [c for c in cases if not c["negative"] and not c["mutant"]]
        negatives = [c for c in cases if c["negative"]]
        mutants = [c for c in cases if c["mutant"]]
        # M-priv stage x origin x delay positives.
        self.assertEqual(
            {(c["stage"], c["origin"], c["delay"]) for c in positives
             if c["priv"] == 3},
            {(s, o, d) for s in (1, 2, 3) for o in (0, 1) for d in (0, 16)})
        # U/S coverage on stage 3 origin-on delay16.
        self.assertEqual(
            {(c["priv"], c["stage"], c["origin"], c["delay"])
             for c in positives if c["priv"] in (0, 1)},
            {(0, 3, 1, 16), (1, 3, 1, 16)})
        # Negative flag oracle on each stage at delay16.
        self.assertEqual(len(negatives), 6)
        self.assertTrue(all(c["delay"] == 16 and c["priv"] == 3
                            for c in negatives))
        # One LSU debug-ignore mutant on stage 2.
        self.assertEqual(len(mutants), 1)
        self.assertEqual(mutants[0]["stage"], 2)
        self.assertEqual(self.runner.HOLD_CYCLES, 192)
        self.assertEqual(tuple(sorted({c["stage"] for c in cases})), (1, 2, 3))

    def test_images_generate_for_all_privileges(self):
        cache = {}
        for priv in (0, 1, 3):
            img = self.runner._images(self.program, cache, priv)
            self.assertEqual(len(img["normal"].split()), 1024)
            self.assertEqual(len(img["debug"].split()), 1024)
        self.assertEqual(set(cache), {0, 1, 3})

    def test_driver_and_interpreter_exist(self):
        for rel in (self.runner.DRIVER_REL, self.runner.INTERP_REL,
                    self.runner.NETLIST_REL):
            self.assertTrue((HERE.parents[2] / rel).is_file(), rel)


if __name__ == "__main__":
    unittest.main()
