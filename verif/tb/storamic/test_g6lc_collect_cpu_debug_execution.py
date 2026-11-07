# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Synthetic collector predicate checks; no RTL or tool qualification."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from collect_cpu_execution import sha256
from g6lc_collect_cpu_debug_execution import collect, SCOPE, HOST, WRAPPER, PACKAGE, PROOF_TOP


class DebugCollectorTests(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[3]
        temp = tempfile.TemporaryDirectory(prefix="storamic-debug-collector-test-",
                                           dir=self.repo / "build-platform/workspace")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return sha256(path)

    def save(self, directory, data):
        (directory / "result.json").write_text(json.dumps(data))

    def read(self, directory):
        return json.loads((directory / "result.json").read_text())

    def matrix(self, generation=True, entry_privilege=None):
        receipts = []
        for enabled in (0, 1):
            for delay, negative in ((0, False), (16, False), (16, True)):
                out = self.root / f"e{enabled}d{delay}n{int(negative)}"
                out.mkdir()
                sources = {name: self.write(out / "source" / name, text) for name, text in
                           ((HOST, "host"), (WRAPPER, "configured wrapper"), (PACKAGE, "new priority"))}
                scripts = {}
                if generation and delay == 0:
                    scripts["model.ys"] = self.write(out / "model.ys",
                        f"read_slang --top g6lc_storamic_cpu_debug_netlist -DSYNTHESIS -GOriginEnabled={enabled}")
                scripts["execution.ys"] = self.write(out / "execution.ys",
                    f"read_slang -GOriginEnabled={enabled} -GResponseDelay={delay} -GNegative={int(negative)}" +
                    (f" -GEntryPrivilege={entry_privilege}" if entry_privilege is not None else "") + ";"
                    "sim -zinit -assert")
                self.write(out / "execution.log",
                    "ERROR: Assertion g6lc_storamic_cpu_debug_interpreter.debug_origin_observer" if negative else "done")
                data = {
                    "status": "pass", "qualification": False, "scope": SCOPE,
                    "target": "cv64a6_imafdc_sv39", "integer_diagnostic": False,
                    "two_state_initialization": True, "enabled": enabled, "delay": delay, "negative": negative,
                    "runner_sha256": self.write(out / "runner.py", "synthetic runner"),
                    "sources": sources, "cpu_sources": {k: v for k, v in sources.items() if k != HOST},
                    "yosys_sha256": "synthetic tool", "scripts": scripts,
                    "program_sha256": self.write(out / "program.hex", "normal"),
                    "debug_sha256": self.write(out / "debug.hex", "debug"),
                    "model_status": "pass", "model_sha256": self.write(out / "cpu.il", f"synthetic model {enabled}"),
                    "returncode": int(negative),
                    "ports": {"done": "1", "failed": "0", "debug_origin_failed": "0", "debug_seen": "1",
                              "write_checks": "110", "read_checks": "100", "debug_writes": "11",
                              "debug_reads": "10", "csr_checks": "10"},
                }
                if entry_privilege is not None:
                    data["entry_privilege"] = entry_privilege
                self.save(out, data)
                receipts.append(out)
        proof = self.root / "proof"
        proof.mkdir()
        data = {"status": "pass", "qualification": False, "yosys_sha256": "synthetic tool",
                "scope": "unrestricted two-state combinatorial redirect priority only", "cases": []}
        for candidate in (False, True):
            out = proof / ("candidate" if candidate else "baseline")
            data["cases"].append({
                "candidate": candidate, "matched": True, "returncode": 0 if candidate else 1,
                "pkg_sha256": self.write(out / "source" / PACKAGE, "new priority" if candidate else "old priority"),
                "top_sha256": self.write(out / "source" / PROOF_TOP, "proof top"),
                "script_sha256": self.write(out / "proof.ys", "proof"),
                "log_sha256": self.write(out / "proof.log", "SUCCESS!" if candidate else "FAIL!"),
            })
        self.save(proof, data)
        return receipts, proof

    def test_full_matrix_never_promotes_native_or_queue_qualification(self):
        result = collect(self.repo, *self.matrix())
        self.assertEqual(len(result["cases"]), 6)
        for key in ("qualification", "native_qualified", "strict_rtl_compile_qualified",
                    "queued_mode_transitions_qualified", "debug_other_privileges_qualified"):
            self.assertFalse(result[key])

    def test_missing_case_rejected(self):
        receipts, proof = self.matrix()
        with self.assertRaisesRegex(ValueError, "missing debug execution"):
            collect(self.repo, receipts[:-1], proof)

    def test_incomplete_program_rejected(self):
        receipts, proof = self.matrix()
        data = self.read(receipts[0])
        data["ports"]["write_checks"] = "101"
        self.save(receipts[0], data)
        with self.assertRaisesRegex(ValueError, "round trip"):
            collect(self.repo, receipts, proof)

    def test_unrelated_assertion_is_not_an_origin_oracle(self):
        receipts, proof = self.matrix()
        self.write(receipts[2] / "execution.log",
                   "ERROR: Assertion g6lc_storamic_cpu_debug_interpreter.cpu_debug_observer")
        with self.assertRaisesRegex(ValueError, "oracle"):
            collect(self.repo, receipts, proof)

    def test_altered_model_rejected(self):
        receipts, proof = self.matrix()
        self.write(receipts[0] / "cpu.il", "altered")
        with self.assertRaisesRegex(ValueError, "model artifact"):
            collect(self.repo, receipts, proof)

    def test_missing_model_generation_rejected(self):
        receipts, proof = self.matrix(generation=False)
        with self.assertRaisesRegex(ValueError, "generation receipts"):
            collect(self.repo, receipts, proof)

    def test_integer_diagnostic_rejected(self):
        receipts, proof = self.matrix()
        data = self.read(receipts[0])
        data["integer_diagnostic"] = True
        self.save(receipts[0], data)
        with self.assertRaisesRegex(ValueError, "configured full-CPU"):
            collect(self.repo, receipts, proof)

    def test_disabled_assertions_rejected_even_with_updated_digest(self):
        receipts, proof = self.matrix()
        data = self.read(receipts[0])
        path = receipts[0] / "execution.ys"
        data["scripts"]["execution.ys"] = self.write(path, path.read_text().replace(" -assert", ""))
        self.save(receipts[0], data)
        with self.assertRaisesRegex(ValueError, "host/assertion mode"):
            collect(self.repo, receipts, proof)

    def test_different_priority_proof_source_rejected(self):
        receipts, proof = self.matrix()
        data = self.read(proof)
        data["cases"][1]["pkg_sha256"] = self.write(proof / "candidate/source" / PACKAGE, "different priority")
        self.save(proof, data)
        with self.assertRaisesRegex(ValueError, "proof source mismatch"):
            collect(self.repo, receipts, proof)

    def external_models(self, receipts):
        models = []
        for index in (0, 3):
            out = self.root / f"generation{index}"
            shutil.copytree(receipts[index], out)
            data = self.read(out)
            data["status"] = "incomplete"  # Only its later execution was interrupted.
            data["scripts"]["model.ys"] = self.write(out / "model.ys",
                "read_slang --top g6lc_storamic_cpu_debug_netlist -DSYNTHESIS "
                f"-GOriginEnabled={data['enabled']}")
            self.save(out, data)
            models.append(out)
        return models

    def test_generation_stage_pass_can_survive_interrupted_execution(self):
        receipts, proof = self.matrix(generation=False)
        models = self.external_models(receipts)
        result = collect(self.repo, receipts, proof, model_receipts=models)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(len(result["cases"]), 6)
        self.assertFalse(result["qualification"])

    def test_incomplete_model_generation_rejected(self):
        receipts, proof = self.matrix(generation=False)
        models = self.external_models(receipts)
        data = self.read(models[0])
        data["model_status"] = "incomplete"
        self.save(models[0], data)
        with self.assertRaisesRegex(ValueError, "generation identity"):
            collect(self.repo, receipts, proof, model_receipts=models)

    def test_supervisor_matrix_has_explicit_narrow_scope(self):
        result = collect(self.repo, *self.matrix(entry_privilege=1), entry_privilege=1)
        self.assertEqual(result["executed_debug_entry_privileges"], [1])
        self.assertEqual(result["scope"], "S-mode external debug round trip only")
        self.assertFalse(result["debug_other_privileges_qualified"])
        self.assertFalse(result["native_qualified"])

    def test_user_matrix_cannot_count_as_supervisor(self):
        receipts, proof = self.matrix(entry_privilege=0)
        with self.assertRaisesRegex(ValueError, "privilege mismatch"):
            collect(self.repo, receipts, proof, entry_privilege=1)

    def test_forged_privilege_metadata_cannot_override_host_parameter(self):
        receipts, proof = self.matrix(entry_privilege=3)
        for directory in receipts:
            data = self.read(directory)
            data["entry_privilege"] = 1
            self.save(directory, data)
        with self.assertRaisesRegex(ValueError, "host entry privilege"):
            collect(self.repo, receipts, proof, entry_privilege=1)

    def test_user_matrix_needs_explicit_host_privilege(self):
        receipts, proof = self.matrix()
        for directory in receipts:
            data = self.read(directory)
            data["entry_privilege"] = 0
            self.save(directory, data)
        with self.assertRaisesRegex(ValueError, "host entry privilege"):
            collect(self.repo, receipts, proof, entry_privilege=0)

    def test_altered_execution_runner_rejected(self):
        receipts, proof = self.matrix()
        self.write(receipts[0] / "runner.py", "altered runner")
        with self.assertRaisesRegex(ValueError, "runner identity"):
            collect(self.repo, receipts, proof)


if __name__ == "__main__":
    unittest.main()
