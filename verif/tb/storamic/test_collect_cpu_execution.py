# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Synthetic receipt predicate tests only; no RTL or tool qualification."""
import json
from pathlib import Path
import tempfile
import unittest

from collect_cpu_execution import collect, sha256


HOST = "verif/tb/storamic/tb_g6lc_storamic_cpu_interpreter.sv"


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[3]
        temp = tempfile.TemporaryDirectory(prefix="storamic-collector-test-",
                                           dir=self.repo / "build-platform/workspace")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def receipt(self, name, *, extra=True, generation=False, cpu="cpu", host="host"):
        out = self.root / name
        out.mkdir()
        sources = {}
        for file, text in (("cpu.sv", cpu), (HOST, host)):
            path = out / "source" / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            sources[file] = sha256(path)
        (out / "program.hex").write_text("rom")
        data = {
            "status": "pass", "qualification": False, "target": "cv64a6_imafdc_sv39",
            "scope": "extended-mprv-cpu-rtlil-interpreter" if extra else "full-configured-cpu-rtlil-interpreter",
            "extra_mprv": extra, "integer_diagnostic": False, "startup_cycles": None,
            "two_state_initialization": True, "sources": sources, "yosys_sha256": "synthetic",
            "program_sha256": sha256(out / "program.hex"), "profiles": [], "results": [], "scripts": {},
            "expected_writes": 7 if extra else 5, "expected_reads": 6 if extra else 4,
            "program_coverage": ["M", "S", "U", "MPRV/MPP=S", "MPRV/MPP=U", "MPRV/MPP=M"],
        }
        for enabled in (0, 1):
            folder = out / f"enabled{enabled}"
            folder.mkdir()
            model = folder / "cpu.il"
            model.write_text(f"synthetic model {enabled}")
            data["profiles"].append({"enabled": enabled, "rtlil_sha256": sha256(model)})
            if generation:
                script = folder / "model.ys"
                script.write_text(f"read_slang -GIntegerDiagnostic=0 -GOriginEnabled={enabled}")
                data["scripts"][script.relative_to(out).as_posix()] = sha256(script)
            for delay, negative in ((0, 0), (16, 0), (16, 1)):
                label = f"enabled{enabled}-delay{delay}-negative{negative}"
                script = out / (label + ".ys")
                script.write_text("sim -assert" + (" -GExtraMprv=1" if extra else ""))
                data["scripts"][script.name] = sha256(script)
                (out / (label + ".log")).write_text(
                    "ERROR: Assertion g6lc_storamic_cpu_interpreter.cpu_origin_observer" if negative else "done")
                data["results"].append({
                    "case": label, "matched": True, "startup_only": False, "returncode": negative,
                    "ports": {"done": "1", "failed": "0",
                              "write_checks": bin(data["expected_writes"])[2:],
                              "read_checks": bin(data["expected_reads"])[2:]},
                })
        self.write(out, data)
        return out

    def write(self, directory, data):
        (directory / "result.json").write_text(json.dumps(data))

    def read(self, directory):
        return json.loads((directory / "result.json").read_text())

    def extended_pair(self):
        return self.receipt("exec"), self.receipt("model", extra=False, generation=True, host="old host")

    def check_extended(self, execution, model):
        return collect(self.repo, [execution], extra_mprv=True, model_receipts=[model])

    def test_legacy_gate_preserved(self):
        result = collect(self.repo, [self.receipt("legacy", extra=False, generation=True)])
        self.assertEqual((result["expected_writes"], result["expected_reads"]), (5, 4))
        self.assertFalse(result["native_qualified"])

    def test_extended_reuses_identical_cpu_with_distinct_host(self):
        result = self.check_extended(*self.extended_pair())
        self.assertEqual((result["expected_writes"], result["expected_reads"]), (7, 6))
        self.assertFalse(result["qualification"])
        self.assertFalse(result["strict_rtl_compile_qualified"])

    def test_extended_cannot_pass_legacy_gate(self):
        execution, _ = self.extended_pair()
        with self.assertRaises(ValueError):
            collect(self.repo, [execution])

    def test_extended_requires_generation_receipts(self):
        execution, _ = self.extended_pair()
        with self.assertRaisesRegex(ValueError, "generation receipts"):
            collect(self.repo, [execution], extra_mprv=True)

    def test_extended_rejects_old_probe_counts(self):
        execution, model = self.extended_pair()
        data = self.read(execution)
        data["results"][0]["ports"]["write_checks"] = "101"
        self.write(execution, data)
        with self.assertRaisesRegex(ValueError, "probe checks"):
            self.check_extended(execution, model)

    def test_extended_rejects_incomplete_matrix(self):
        execution, model = self.extended_pair()
        data = self.read(execution)
        data["results"].pop()
        self.write(execution, data)
        with self.assertRaisesRegex(ValueError, "execution cases"):
            self.check_extended(execution, model)

    def test_extended_requires_host_parameter(self):
        execution, model = self.extended_pair()
        data = self.read(execution)
        name = data["results"][0]["case"] + ".ys"
        (execution / name).write_text("sim -assert")
        data["scripts"][name] = sha256(execution / name)
        self.write(execution, data)
        with self.assertRaisesRegex(ValueError, "host checks"):
            self.check_extended(execution, model)

    def test_extended_rejects_different_model_sources(self):
        execution = self.receipt("exec")
        model = self.receipt("model", extra=False, generation=True, cpu="different CPU")
        with self.assertRaisesRegex(ValueError, "source/tool identity"):
            self.check_extended(execution, model)

    def test_extended_rejects_integer_diagnostic(self):
        execution, model = self.extended_pair()
        data = self.read(execution)
        data["integer_diagnostic"] = True
        self.write(execution, data)
        with self.assertRaisesRegex(ValueError, "diagnostic profile"):
            self.check_extended(execution, model)


if __name__ == "__main__":
    unittest.main()
