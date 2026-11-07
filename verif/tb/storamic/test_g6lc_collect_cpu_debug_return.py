# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Return-direction canonical script guards; synthetic inputs only."""
import json
import shlex
from pathlib import Path
import tempfile
import unittest

from collect_cpu_execution import sha256
from g6lc_collect_cpu_debug_return import collect, HOST, SCOPE, TOP, script_commands, validate_script
from g6lc_cpu_debug_queue_trace import PROBES, TRACKED
import test_g6lc_collect_cpu_debug_queue as queue_test_support
from test_g6lc_cpu_debug_return_trace import states


class ReturnScriptTests(unittest.TestCase):
    def setUp(self):
        repo = Path(__file__).resolve().parents[3]
        temporary = tempfile.TemporaryDirectory(prefix="storamic-return-script-",
                                                dir=repo / "build-platform/workspace")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.data = {"enabled": 1, "delay": 16, "negative": False, "entry_privilege": 3,
                     "stage": 3, "cycles": 4000, "read_only_probes": PROBES}
        self.path = self.directory / "execution.ys"
        self.path.write_text("; ".join(shlex.join(c) for c in script_commands(self.directory, self.data)))

    def test_correct_separate_return_profile_accepted(self):
        validate_script(self.directory, self.data)
        self.assertIn("-GHoldCycles=384", self.path.read_text())
        self.assertIn("g6lc_storamic_cpu_debug_return_interpreter", self.path.read_text())

    def test_force_command_cannot_be_hidden(self):
        self.path.write_text(self.path.read_text() + "; connect cpu.debug_mode 0")
        with self.assertRaisesRegex(ValueError, "non-read-only"):
            validate_script(self.directory, self.data)

    def test_old_192_cycle_profile_not_accepted(self):
        self.path.write_text(self.path.read_text().replace("-GHoldCycles=384", "-GHoldCycles=192"))
        with self.assertRaisesRegex(ValueError, "noncanonical"):
            validate_script(self.directory, self.data)


class ReturnMatrixTests(unittest.TestCase):
    # Reuse only the synthetic artifact/temporary-directory helpers, not queue assertions.
    setUp = queue_test_support.QueueCollectorTests.setUp
    write = queue_test_support.QueueCollectorTests.write
    save = queue_test_support.QueueCollectorTests.save
    read = queue_test_support.QueueCollectorTests.read
    wave = queue_test_support.QueueCollectorTests.wave

    def return_wave(self, directory, privilege, enabled, late=False):
        names = sorted(TRACKED)
        lines = ["$scope module test $end"]
        lines += [f"$var wire 64 s{i} {name} $end" for i, name in enumerate(names)]
        lines += ["$upscope $end", "$enddefinitions $end"]
        for time, sample in enumerate(states(privilege, enabled, late=late)):
            lines.append(f"#{time}")
            lines += [f"b{sample[name]:b} s{i}" for i, name in enumerate(names)]
        return self.write(directory / "execution.vcd", "\n".join(lines) + "\n")

    def matrix(self):
        templates, origins = queue_test_support.QueueCollectorTests.matrix(self)
        profiles = [(p, e, d, n) for p in (0, 1, 3) for e in (0, 1)
                    for d, n in ((0, False), (16, False), (16, True))]
        cases = []
        for directory, (p, enabled, delay, negative) in zip(templates, profiles):
            origin = self.read(origins[enabled])
            data = self.read(directory)
            data.update({
                "scope": SCOPE, "entry_privilege": p, "enabled": enabled, "delay": delay,
                "negative": negative, "stage": 3, "hold_cycles": 384,
                "cpu_sources": origin["cpu_sources"],
                "sources": {**origin["cpu_sources"], HOST: self.write(directory / "source" / HOST, "return fixture")},
                "model_origin": {"sha256": sha256(origins[enabled] / "result.json")},
                "returncode": int(negative),
                "model_sha256": self.write(directory / "cpu.il", f"model{enabled}"),
                "program_sha256": self.write(directory / "program.hex", f"normal{p}"),
                "debug_sha256": self.write(directory / "debug.hex", f"return{p}"),
            })
            data["ports"].update({"write_checks": "111", "debug_writes": "100"})
            generation = {"scope": "seven-write debug return firmware only", "entry_privilege": p,
                          "expected_writes": 7, "expected_reads": 4, "debug_writes": 4,
                          "debug_reads": 2, "held_debug_offset": 28,
                          "program_sha256": data["program_sha256"], "debug_sha256": data["debug_sha256"]}
            data["firmware_receipt_sha256"] = self.write(directory / "firmware.json", json.dumps(generation))
            data["scripts"] = {"execution.ys": self.write(directory / "execution.ys",
                "; ".join(shlex.join(c) for c in script_commands(directory, data)))}
            self.write(directory / "execution.log",
                       f"ERROR: Assertion {TOP}.debug_origin_observer" if negative else "finished")
            if not negative:
                data["vcd_sha256"] = self.return_wave(directory, p, enabled)
            self.save(directory, data)
            cases.append(directory)
        return cases, origins

    def test_complete_return_matrix_does_not_qualify_native_or_all_queues(self):
        result = collect(self.repo, *self.matrix())
        self.assertEqual(len(result["cases"]), 18)
        for field in ("qualification", "native_qualified", "strict_compile_qualified",
                      "queued_mode_transitions_qualified", "fpu_isa_qualified"):
            self.assertFalse(result[field])

    def test_six_write_gate_cannot_count_as_seven_write_return(self):
        cases, origins = self.matrix()
        data = self.read(cases[0])
        data["ports"]["write_checks"] = "110"
        self.save(cases[0], data)
        with self.assertRaisesRegex(ValueError, "incomplete queued"):
            collect(self.repo, cases, origins)

    def test_old_firmware_metadata_rejected_even_after_digest_updated(self):
        cases, origins = self.matrix()
        data = self.read(cases[0])
        firmware = json.loads((cases[0] / "firmware.json").read_text())
        firmware["expected_writes"] = 6
        data["firmware_receipt_sha256"] = self.write(cases[0] / "firmware.json", json.dumps(firmware))
        self.save(cases[0], data)
        with self.assertRaisesRegex(ValueError, "seven-write firmware"):
            collect(self.repo, cases, origins)

    def test_missing_return_profile_rejected(self):
        cases, origins = self.matrix()
        with self.assertRaisesRegex(ValueError, "missing complete"):
            collect(self.repo, cases[:-1], origins)

    def test_missing_cpu_generation_rejected(self):
        cases, origins = self.matrix()
        with self.assertRaisesRegex(ValueError, "missing configured"):
            collect(self.repo, cases, origins[:1])

    def test_complete_program_with_drained_response_is_not_crossing_evidence(self):
        cases, origins = self.matrix()
        data = self.read(cases[0])
        data["vcd_sha256"] = self.return_wave(cases[0], 0, 0, late=True)
        self.save(cases[0], data)
        with self.assertRaisesRegex(ValueError, "cross actual DRET"):
            collect(self.repo, cases, origins)

    def test_changed_model_rejected(self):
        cases, origins = self.matrix()
        self.write(cases[0] / "cpu.il", "altered")
        with self.assertRaisesRegex(ValueError, "artifact identity"):
            collect(self.repo, cases, origins)

    def test_unrelated_assertion_is_not_debug_origin_oracle(self):
        cases, origins = self.matrix()
        self.write(cases[2] / "execution.log", f"ERROR: Assertion {TOP}.queued_w_stability")
        with self.assertRaisesRegex(ValueError, "named observer"):
            collect(self.repo, cases, origins)
