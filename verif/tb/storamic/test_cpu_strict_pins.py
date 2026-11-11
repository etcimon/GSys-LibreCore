# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "storamic_run_cpu_strict_pins",
    Path(__file__).with_name("run_cpu_strict_pins.py"))
STAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAGE)

UNOPT = ("%Error-UNOPTFLAT: file.sv:1:1: Signal unoptimizable: Circular "
         "combinational logic: 'tb.cpu.sig_a'\n")


def _pins(ids_by_case):
    variants = {}
    for case, ids in ids_by_case.items():
        variant, origin = case.rsplit("-origin", 1)
        variants.setdefault(variant, {})["origin" + origin] = [
            {"identity": i, "basis": "proof"} for i in ids]
    return {"variants": variants}


class IdentityTests(unittest.TestCase):
    def test_identities_extracts_hierarchical_names(self):
        text = UNOPT + UNOPT.replace("sig_a", "sig_b[3]")
        self.assertEqual(STAGE._identities(text),
                         ["tb.cpu.sig_a", "tb.cpu.sig_b[3]"])

    def test_other_errors_flags_fatal_non_unoptflat(self):
        text = ("%Error-PINMISSING: missing pin\n"
                "%Error: Exiting due to 2 error(s)\n")
        self.assertEqual(len(STAGE._other_errors(text)), 1)
        self.assertIn("PINMISSING", STAGE._other_errors(text)[0])
        # UNOPTFLAT and the Exiting trailer are not "other" errors.
        self.assertEqual(STAGE._other_errors(UNOPT +
                         "%Error: Exiting due to 1 error(s)\n"), [])

    def test_strict_options_have_no_unoptflat_suppression(self):
        self.assertIn("-Werror-UNOPTFLAT", STAGE.STRICT)
        self.assertNotIn("-Wno-UNOPTFLAT", STAGE.STRICT)
        self.assertNotIn("-Wno-fatal", [])  # sanity: fatal class retained
        self.assertIn("-Wno-fatal", STAGE.STRICT)


class EvaluateTests(unittest.TestCase):
    def _results(self, mapping):
        return {name: {"text": text, "rc": 1, "seconds": 1.0}
                for name, text in mapping.items()}

    def test_subset_pass_and_stale_pin_reported(self):
        pins = _pins({"fields-origin0": ["tb.cpu.a", "tb.cpu.b"],
                      "fields-origin1": ["tb.cpu.a", "tb.cpu.b"],
                      "fp-origin0": ["tb.cpu.x"], "fp-origin1": ["tb.cpu.x"]})
        res = self._results({
            "fields-origin0": UNOPT.replace("sig_a", "a"),
            "fields-origin1": UNOPT.replace("sig_a", "a"),
            "fp-origin0": UNOPT.replace("sig_a", "x"),
            "fp-origin1": UNOPT.replace("sig_a", "x")})
        observed, verdicts, hard_fail, stale = STAGE._evaluate(res, pins)
        self.assertEqual(hard_fail, [])
        self.assertTrue(all(v["pass"] for v in verdicts.values()))
        # "tb.cpu.b" pinned but absent -> stale-pin (allowed shrink).
        self.assertEqual(stale["fields-origin0"], ["tb.cpu.b"])
        self.assertEqual(verdicts["fields-origin0"]["stale_pins"],
                         ["tb.cpu.b"])

    def test_unpinned_identity_fails_and_is_named(self):
        pins = _pins({"fields-origin0": ["tb.cpu.a"], "fields-origin1": ["tb.cpu.a"],
                      "fp-origin0": ["tb.cpu.x"], "fp-origin1": ["tb.cpu.x"]})
        res = self._results({
            "fields-origin0": UNOPT.replace("sig_a", "a") +
                              UNOPT.replace("sig_a", "NEWLOOP"),
            "fields-origin1": UNOPT.replace("sig_a", "a"),
            "fp-origin0": UNOPT.replace("sig_a", "x"),
            "fp-origin1": UNOPT.replace("sig_a", "x")})
        _, verdicts, hard_fail, _ = STAGE._evaluate(res, pins)
        self.assertFalse(verdicts["fields-origin0"]["pass"])
        self.assertEqual(verdicts["fields-origin0"]["unpinned"],
                         ["tb.cpu.NEWLOOP"])
        self.assertTrue(any("NEWLOOP" in f for f in hard_fail))

    def test_fatal_non_unoptflat_fails(self):
        pins = _pins({"fields-origin0": ["tb.cpu.a"], "fields-origin1": ["tb.cpu.a"],
                      "fp-origin0": ["tb.cpu.x"], "fp-origin1": ["tb.cpu.x"]})
        bad = UNOPT.replace("sig_a", "a") + "%Error-LATCH: latch\n"
        res = self._results({
            "fields-origin0": bad, "fields-origin1":
                UNOPT.replace("sig_a", "a"),
            "fp-origin0": UNOPT.replace("sig_a", "x"),
            "fp-origin1": UNOPT.replace("sig_a", "x")})
        _, verdicts, hard_fail, _ = STAGE._evaluate(res, pins)
        self.assertFalse(verdicts["fields-origin0"]["pass"])
        self.assertTrue(any("LATCH" in e for e in
                            verdicts["fields-origin0"]["other_errors"]))
        self.assertTrue(any("fields-origin0" in f for f in hard_fail))


class CanaryAndCouplingTests(unittest.TestCase):
    _CPU = "g6lc_strict_pins_canary_top.u_cpu.cpu.sig_a"

    def _log(self, *ids):
        return {"text": "".join(
            "%Error-UNOPTFLAT: f.sv:1:1: Circular combinational logic:"
            f" '{i}'\n" for i in ids), "rc": 1}

    def test_canary_detects_loop_alongside_core_identities(self):
        verdict, ok = STAGE._evaluate_canary(self._log(
            self._CPU, "g6lc_strict_pins_canary_comb"))
        self.assertTrue(ok)
        # Only the non-core identity is reported as the canary hit.
        self.assertEqual(verdict["canary_hits"],
                         ["g6lc_strict_pins_canary_comb"])

    def test_canary_fails_when_only_core_identities_present(self):
        # No looped canary signal -> nothing outside the u_cpu.cpu cone.
        verdict, ok = STAGE._evaluate_canary(self._log(self._CPU))
        self.assertFalse(ok)
        self.assertEqual(verdict["canary_hits"], [])

    def test_coupling_requires_pass_zero_scc_zero_latch_same_manifest(self):
        sha = "ab" * 32
        good = {"pass": True, "sccs": 0, "latches": 0,
                "sources_sha256": sha}
        self.assertTrue(STAGE._coupled(good, sha))
        self.assertFalse(STAGE._coupled(None, sha))
        self.assertFalse(STAGE._coupled({**good, "sccs": 3}, sha))
        self.assertFalse(STAGE._coupled({**good, "latches": 1}, sha))
        self.assertFalse(STAGE._coupled({**good, "pass": False}, sha))
        self.assertFalse(STAGE._coupled(good, "cd" * 32))


class EnvAndDirectiveTests(unittest.TestCase):
    def test_env_sets_verilator_root_only_for_fork_native(self):
        env = STAGE._env({"kind": "g6lc-fork-native", "root": "/opt/vlt"})
        self.assertEqual(env["VERILATOR_ROOT"], "/opt/vlt")
        env2 = STAGE._env({"kind": "system", "root": "/usr"})
        self.assertNotIn("VERILATOR_ROOT", env2)

    def test_strip_directives_only_touches_commented_waivers(self):
        with tempfile.TemporaryDirectory(
                dir=ROOT / "build-platform/workspace") as tmp:
            tree = Path(tmp)
            (tree / "a.sv").write_text(
                "// verilator lint_off UNOPTFLAT\nmodule a; endmodule\n")
            removed = STAGE._strip_directives(tree)
            self.assertEqual(len(removed), 1)
            self.assertNotIn("lint_off", (tree / "a.sv").read_text())
            # A non-comment directive must be refused.
            (tree / "b.sv").write_text(
                "(* verilator lint_off UNOPTFLAT *) module b; endmodule\n")
            with self.assertRaises(AssertionError):
                STAGE._strip_directives(tree)

    def test_command_has_strict_opts_and_no_suppression(self):
        plan = {"incdirs": ["core/include"], "defines": ["+define+G6LC_FETCH_B"],
                "files": []}
        runtime = {"verilator_options": ["--unroll-count", "256"]}
        cmd = STAGE._command("/vlt/verilator", runtime, Path("/tree"),
                             plan, Path("/out"), "x", STAGE.TOP, 0,
                             [Path("/tree/f.sv"), Path("/tree/b.sv")],
                             Path("/out/c.vlt"))
        self.assertIn("--lint-only", cmd)
        self.assertIn("-Werror-UNOPTFLAT", cmd)
        self.assertIn("-Werror-LATCH", cmd)
        self.assertIn("-Werror-PINMISSING", cmd)
        self.assertIn("--unroll-count", cmd)
        self.assertIn("-GOriginEnabled=0", cmd)
        self.assertIn("-GIntegerDiagnostic=0", cmd)
        self.assertNotIn("-Wno-UNOPTFLAT", cmd)
        self.assertTrue(cmd[-1].replace("\\", "/").endswith("/out/c.vlt"))
        self.assertTrue(cmd[-2].replace("\\", "/").endswith("/tree/b.sv"))
        self.assertTrue(cmd[-3].replace("\\", "/").endswith("/tree/f.sv"))


if __name__ == "__main__":
    unittest.main()
