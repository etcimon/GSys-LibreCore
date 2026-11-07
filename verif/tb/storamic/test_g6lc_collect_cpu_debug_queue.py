# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Synthetic matrix/identity guard tests, not RTL qualification."""
import json
from pathlib import Path
import shlex
import tempfile
import unittest

from collect_cpu_execution import sha256
from g6lc_collect_cpu_debug_queue import collect, HOST, SCOPE, TOP, WRAPPER, script_commands
from g6lc_cpu_debug_queue_trace import PROBES, TRACKED
from test_g6lc_cpu_debug_queue_trace import states


class QueueCollectorTests(unittest.TestCase):
    def setUp(self):
        self.repo = Path(__file__).resolve().parents[3]
        temporary = tempfile.TemporaryDirectory(prefix="storamic-queue-collector-",
                                                dir=self.repo / "build-platform/workspace")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return sha256(path)

    def save(self, directory, data):
        (directory / "result.json").write_text(json.dumps(data))

    def read(self, directory):
        return json.loads((directory / "result.json").read_text())

    def wave(self, directory, stage, enabled, privilege, late_entry=None):
        names = sorted(TRACKED)
        lines = ["$scope module test $end"]
        lines += [f"$var wire 64 s{i} {name} $end" for i, name in enumerate(names)]
        lines += ["$upscope $end", "$enddefinitions $end"]
        samples = states(stage, late_entry=(stage != 3) if late_entry is None else late_entry)
        for time, sample in enumerate(samples):
            sample["q_aw_prot"] = {0: 2, 1: 3, 3: 1}[privilege] if enabled else 0
            lines.append(f"#{time}")
            lines += [f"b{sample[name]:b} s{i}" for i, name in enumerate(names)]
        return self.write(directory / "execution.vcd", "\n".join(lines) + "\n")

    def matrix(self):
        origins, receipts = [], []
        for enabled in (0, 1):
            directory = self.root / f"generation{enabled}"
            sources = {WRAPPER: self.write(directory / "source" / WRAPPER, "configured CPU wrapper")}
            data = {"scope": "configured-cpu-external-debug-interpreter", "model_status": "pass",
                    "integer_diagnostic": False, "enabled": enabled, "cpu_sources": sources,
                    "yosys_sha256": "synthetic tool",
                    "model_sha256": self.write(directory / "cpu.il", f"model{enabled}"),
                    "scripts": {"model.ys": self.write(directory / "model.ys",
                        f"read_slang --top g6lc_storamic_cpu_debug_netlist -DSYNTHESIS -GOriginEnabled={enabled}")}}
            self.save(directory, data)
            origins.append(directory)
        profiles = [(3, s, e, d, n) for s in (1, 2, 3) for e in (0, 1)
                    for d, n in ((0, False), (16, False), (16, True))]
        profiles += [(p, 3, 1, 16, False) for p in (0, 1)]
        for index, (p, stage, enabled, delay, negative) in enumerate(profiles):
            directory = self.root / f"case{index}"
            origin = self.read(origins[enabled])
            sources = {WRAPPER: self.write(directory / "source" / WRAPPER, "configured CPU wrapper"),
                       HOST: self.write(directory / "source" / HOST, "queue fixture")}
            data = {
                "status": "pass", "scope": SCOPE, "target": "cv64a6_imafdc_sv39",
                "integer_diagnostic": False, "two_state_initialization": True, "model_status": "pass",
                "entry_privilege": p, "stage": stage, "enabled": enabled, "delay": delay, "negative": negative,
                "hold_cycles": 192, "cycles": 1000, "cpu_sources": origin["cpu_sources"], "sources": sources,
                "model_origin": {"sha256": sha256(origins[enabled] / "result.json")},
                "yosys_sha256": origin["yosys_sha256"], "returncode": int(negative),
                "model_sha256": self.write(directory / "cpu.il", f"model{enabled}"),
                "program_sha256": self.write(directory / "program.hex", f"normal{p}"),
                "debug_sha256": self.write(directory / "debug.hex", f"debug{p}"),
                "runner_sha256": self.write(directory / "runner.py", "runner"),
                "instrumented_sha256": self.write(directory / "instrumented.il", "observed model"),
                "read_only_probes": PROBES,
                "ports": {"done": "1", "debug_seen": "1", "hold_started": "1", "hold_finished": "1",
                          "failed": "0", "debug_origin_failed": "0", "write_checks": "110",
                          "read_checks": "100", "debug_writes": "11", "debug_reads": "10", "csr_checks": "10"},
            }
            data["scripts"] = {"execution.ys": self.write(directory / "execution.ys",
                "; ".join(shlex.join(c) for c in script_commands(directory, data)))}
            self.write(directory / "execution.log",
                       f"ERROR: Assertion {TOP}.debug_origin_observer" if negative else "finished")
            if not negative:
                data["vcd_sha256"] = self.wave(directory, stage, enabled, p,
                                              late_entry=(stage != 3 and delay == 0))
            self.save(directory, data)
            receipts.append(directory)
        return receipts, origins

    def test_full_scoped_matrix_still_does_not_qualify_native_or_all_queues(self):
        result = collect(self.repo, *self.matrix())
        self.assertEqual(len(result["cases"]), 20)
        for field in ("qualification", "native_qualified", "strict_compile_qualified",
                      "queued_mode_transitions_qualified", "fpu_isa_qualified"):
            self.assertFalse(result[field])

    def test_missing_profile_rejected(self):
        cases, origins = self.matrix()
        with self.assertRaisesRegex(ValueError, "missing complete"):
            collect(self.repo, cases[:-1], origins)

    def test_missing_generation_receipt_rejected(self):
        cases, origins = self.matrix()
        with self.assertRaisesRegex(ValueError, "missing configured"):
            collect(self.repo, cases, origins[:1])

    def test_altered_model_rejected(self):
        cases, origins = self.matrix()
        self.write(cases[0] / "cpu.il", "altered")
        with self.assertRaisesRegex(ValueError, "artifact identity"):
            collect(self.repo, cases, origins)

    def test_updated_digest_cannot_hide_cpu_forcing_command(self):
        cases, origins = self.matrix()
        data = self.read(cases[0])
        path = cases[0] / "execution.ys"
        data["scripts"]["execution.ys"] = self.write(path, path.read_text() + "; connect forced 1")
        self.save(cases[0], data)
        with self.assertRaisesRegex(ValueError, "non-read-only"):
            collect(self.repo, cases, origins)

    def test_relabeling_probe_mapping_rejected(self):
        cases, origins = self.matrix()
        data = self.read(cases[0])
        data["read_only_probes"]["cpu.cpu.debug_mode"] = "q_aw_valid"
        self.save(cases[0], data)
        with self.assertRaisesRegex(ValueError, "observation mapping"):
            collect(self.repo, cases, origins)

    def test_partial_program_rejected(self):
        cases, origins = self.matrix()
        data = self.read(cases[0])
        data["ports"]["write_checks"] = "101"
        self.save(cases[0], data)
        with self.assertRaisesRegex(ValueError, "incomplete queued"):
            collect(self.repo, cases, origins)

    def test_wrong_assertion_is_not_origin_oracle(self):
        cases, origins = self.matrix()
        negative = cases[2]
        self.write(negative / "execution.log", f"ERROR: Assertion {TOP}.queued_aw_stability")
        with self.assertRaisesRegex(ValueError, "named observer"):
            collect(self.repo, cases, origins)

    def test_completed_b_case_without_actual_mode_crossing_rejected(self):
        cases, origins = self.matrix()
        # First B profile follows the six AW and six W profiles.
        directory = cases[12]
        data = self.read(directory)
        data["vcd_sha256"] = self.wave(directory, 3, 0, 3, late_entry=True)
        self.save(directory, data)
        with self.assertRaisesRegex(ValueError, "actual queue/debug ordering"):
            collect(self.repo, cases, origins)


if __name__ == "__main__":
    unittest.main()
