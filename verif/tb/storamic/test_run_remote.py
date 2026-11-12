# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "storamic_run_remote", Path(__file__).with_name("run_remote.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class PrepareTests(unittest.TestCase):
    def invoke(self, output, *args, tracked="", toolrec=None,
               toolrec_path=None, git_heads=None):
        # toolrec=None keeps the legacy no-record path; pass a dict to exercise
        # the tools record. git_heads maps a submodule suffix to a HEAD sha.
        if toolrec_path is None and toolrec is not None:
            toolrec_path = ROOT / "verif/tb/storamic/storamic_tools.json"
        load_ret = ((toolrec, None, toolrec_path) if toolrec is not None
                    else (None, None, None))

        def fake_head(path):
            text = str(path).replace("\\", "/")
            for suffix, head in (git_heads or {}).items():
                if text.endswith(suffix):
                    return head
            return None

        with mock.patch.object(sys, "argv", [
                "run_remote.py", "--stages", "dstore",
                "--output-root", str(output), *args]), \
                mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch.object(RUNNER, "load_tools_record",
                                  return_value=load_ret), \
                mock.patch.object(RUNNER, "_git_head", side_effect=fake_head), \
                mock.patch.object(RUNNER.shutil, "which", return_value="/offline/bun"), \
                mock.patch.object(RUNNER.subprocess, "check_output", return_value=tracked), \
                mock.patch.object(RUNNER.subprocess, "call",
                                  side_effect=AssertionError("unexpected remote launch")), \
                contextlib.redirect_stdout(io.StringIO()):
            return RUNNER.main()

    def test_prepare_records_identity_and_missing_runtime_without_launch(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            output = Path(tmp)
            self.assertEqual(self.invoke(output, "--prepare-only"), 0)
            plan = json.loads(next(output.glob("*/launch-plan.json")).read_text())
            self.assertEqual(plan["status"], "prepared")
            self.assertFalse(plan["qualification"])
            self.assertEqual(len(plan["blockers"]), 2)
            manifest_file = Path(plan["manifest"])
            self.assertEqual(plan["manifest_sha256"],
                             hashlib.sha256(manifest_file.read_bytes()).hexdigest())
            manifest = json.loads(manifest_file.read_text())
            source = ROOT / "corev_apu/storamic/g6lc_storamic_durable_store.sv"
            self.assertEqual(manifest["sources"][source.name],
                             hashlib.sha256(source.read_bytes()).hexdigest())
            self.assertIn("STORAMIC_RUNNER_SHA=" + plan["runner_sha256"],
                          plan["command"])

    def test_commit_defaults_preparation_tracks_promoted_rtl_and_fixture(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(
                Path(tmp), "--prepare-only", "--stages", "commit-defaults"), 0)
            plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
            self.assertEqual(len(plan["blockers"]), 2)
            manifest = json.loads(Path(plan["manifest"]).read_text())
            for name in ("core/commit_stage.sv", "verif/tb/storamic/run_commit_defaults.py",
                         "verif/tb/storamic/g6lc_commit_defaults_fixture.sv",
                         "verif/tb/storamic/tb_g6lc_commit_defaults.sv"):
                path = ROOT / name
                self.assertEqual(manifest["sources"][path.name],
                                 hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertFalse(plan["qualification"])

    def test_commit_formal_and_synth_are_independent_of_cpp_runtime(self):
        for stage in ("commit-defaults-formal", "commit-defaults-synth"):
            with self.subTest(stage=stage), \
                    tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
                self.assertEqual(self.invoke(
                    Path(tmp), "--prepare-only", "--stages", stage), 0)
                plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
                self.assertEqual(plan["blockers"], [])
                self.assertFalse(plan["qualification"])

    def test_load_translation_stages_track_actual_core_and_are_independent(self):
        for stage in ("load-translation", "load-translation-synth"):
            with self.subTest(stage=stage), \
                    tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
                self.assertEqual(self.invoke(
                    Path(tmp), "--prepare-only", "--stages", stage), 0)
                plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
                self.assertEqual(len(plan["blockers"]), 2 if stage == "load-translation" else 0)
                manifest = json.loads(Path(plan["manifest"]).read_text())
                for name in ("core/load_unit.sv", "core/lsu_bypass.sv",
                             "verif/tb/core/tb_g6lc_rtl_review.sv",
                             "verif/tb/storamic/run_load_translation.py"):
                    path = ROOT / name
                    self.assertEqual(manifest["sources"][path.name],
                                     hashlib.sha256(path.read_bytes()).hexdigest())
                self.assertFalse(plan["qualification"])

    def test_fetch_queue_stages_track_promoted_queue_and_are_independent(self):
        for stage in ("fetch-queue", "fetch-queue-synth", "load-translation,fetch-queue"):
            with self.subTest(stage=stage), \
                    tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
                self.assertEqual(self.invoke(
                    Path(tmp), "--prepare-only", "--stages", stage), 0)
                plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
                self.assertEqual(len(plan["blockers"]), 0 if stage == "fetch-queue-synth" else 2)
                manifest = json.loads(Path(plan["manifest"]).read_text())
                for name in ("core/fetch_B/instr_queue.sv", "core/fetch_B/g6lc_fetch_pkg.sv",
                             "core/cva6_fifo_v3.sv", "core/include/g6lc64_smt2_config_pkg.sv",
                             "core/include/ariane_pkg.sv",
                             "verif/tb/core/tb_g6lc_fetch_queue.sv",
                             "verif/tb/storamic/run_fetch_queue.py"):
                    path = ROOT / name
                    self.assertEqual(manifest["sources"][path.name],
                                     hashlib.sha256(path.read_bytes()).hexdigest())
                self.assertFalse(plan["qualification"])

    def test_fetch_queue_mutation_reverts_exactly_the_promoted_admission(self):
        spec = importlib.util.spec_from_file_location(
            "storamic_run_fetch_queue", Path(__file__).with_name("run_fetch_queue.py"))
        queue = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(queue)
        promoted = "push_instr[f] & (cf_type_i[s] != ariane_pkg::NoCF)"
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            for count in (0, 2):
                source = Path(tmp) / f"queue{count}.sv"
                source.write_text("module m;\n" + (promoted + ";\n") * count + "endmodule\n")
                with self.assertRaisesRegex(RuntimeError, "FETCH_QUEUE_MUTATION_INVENTORY"):
                    queue._mutate(source, Path(tmp) / "mutant.sv")
            mutant = Path(tmp) / "mutant.sv"
            queue._mutate(ROOT / "core/fetch_B/instr_queue.sv", mutant)
            text = mutant.read_text()
            self.assertNotIn(promoted, text)
            self.assertIn("push_address |= push_instr[f] & "
                          "(instr_data_in[f].cf != ariane_pkg::NoCF);", text)

    def test_owned_tool_paths_replace_toolchain_defaults(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(
                Path(tmp), "--prepare-only", "--stages", "fetch-queue",
                "--runtime-json", "/opt/testharness/x/runtime.json",
                "--runtime-header-sha256", "a" * 64,
                "--verilator", "/opt/testharness/runs/a/bin/verilator",
                "--yosys", "/opt/testharness/runs/b/bin/yosys",
                "--solver-bin", "/opt/testharness/runs/c/yices/bin"), 0)
            plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
            command = plan["command"]
            self.assertIn("VERILATOR=/opt/testharness/runs/a/bin/verilator", command)
            self.assertIn("VERILATOR_ROOT=/opt/testharness/runs/a", command)
            self.assertIn("YOSYS=/opt/testharness/runs/b/bin/yosys", command)
            self.assertIn("PATH=/opt/testharness/runs/c/yices/bin:"
                          "/opt/testharness/runs/b/bin:/usr/local/bin:/usr/bin:/bin",
                          command)
            self.assertFalse(any("toolchains/verilator" in c for c in command))
            self.assertEqual(plan["tools"]["verilator"],
                             "/opt/testharness/runs/a/bin/verilator")

    def test_owned_tool_paths_reject_outside_gateway_root(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            with self.assertRaises(SystemExit):
                self.invoke(
                    Path(tmp), "--prepare-only", "--stages", "fetch-queue",
                    "--runtime-json", "/opt/testharness/x/runtime.json",
                    "--runtime-header-sha256", "a" * 64,
                    "--verilator", "/usr/bin/verilator")

    RECORD = {
        "verilator": {
            "head": "1" * 40,
            "verilator": "/opt/testharness/toolchains/vlt-pgo/runtime/bin/verilator",
            "runtime_json": "/opt/testharness/runs/vlt-validate/output/runtime.json",
            "runtime_header_sha256": "a" * 64,
            "compiler_sha256": "b" * 64,
        },
        "yosys": {
            "head": "2" * 40,
            "path": "/opt/testharness/toolchains/yosys-g6lc/bin/yosys",
            "sha256": "c" * 64,
        },
        "solver_bin": "/opt/testharness/runs/solver/yices-2.6.5/bin",
    }
    RECORD_HEADS = {"tools/verilator": "1" * 40, "tools/yosys": "2" * 40}

    def _record_file(self, directory, record=None):
        path = Path(directory) / "storamic_tools.json"
        path.write_text(json.dumps(record or self.RECORD))
        return path

    def test_tools_record_supplies_defaults_and_pins_source(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            rec_path = self._record_file(tmp)
            self.assertEqual(self.invoke(
                Path(tmp) / "out", "--prepare-only", toolrec=self.RECORD,
                toolrec_path=rec_path, git_heads=self.RECORD_HEADS), 0)
            plan = json.loads(next((Path(tmp) / "out").glob("*/launch-plan.json")).read_text())
            self.assertEqual(plan["blockers"], [])
            self.assertEqual(plan["tools"]["verilator"],
                             self.RECORD["verilator"]["verilator"])
            self.assertEqual(plan["tools"]["yosys"], self.RECORD["yosys"]["path"])
            self.assertEqual(plan["tools"]["solver_bin"], self.RECORD["solver_bin"])
            command = plan["command"]
            self.assertIn("VERILATOR=" + self.RECORD["verilator"]["verilator"], command)
            self.assertIn("YOSYS=" + self.RECORD["yosys"]["path"], command)
            self.assertIn("STORAMIC_RUNTIME_JSON=" +
                          self.RECORD["verilator"]["runtime_json"], command)
            self.assertIn("STORAMIC_RUNTIME_HEADER_SHA256=" +
                          self.RECORD["verilator"]["runtime_header_sha256"], command)
            self.assertIn("STORAMIC_EXPECT_YOSYS_SHA256=" +
                          self.RECORD["yosys"]["sha256"], command)
            manifest = json.loads(Path(plan["manifest"]).read_text())
            self.assertIn("storamic_tools.json", manifest["sources"])

    def test_tools_record_explicit_verilator_overrides_record(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            rec_path = self._record_file(tmp)
            self.assertEqual(self.invoke(
                Path(tmp) / "out", "--prepare-only",
                "--verilator", "/opt/testharness/runs/custom/bin/verilator",
                toolrec=self.RECORD, toolrec_path=rec_path,
                git_heads=self.RECORD_HEADS), 0)
            plan = json.loads(next((Path(tmp) / "out").glob("*/launch-plan.json")).read_text())
            self.assertEqual(plan["tools"]["verilator"],
                             "/opt/testharness/runs/custom/bin/verilator")
            self.assertIn("VERILATOR=/opt/testharness/runs/custom/bin/verilator",
                          plan["command"])

    def test_tools_record_head_mismatch_is_incomplete(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            rec_path = self._record_file(tmp)
            bad_heads = dict(self.RECORD_HEADS)
            bad_heads["tools/verilator"] = "9" * 40
            self.assertEqual(self.invoke(
                Path(tmp) / "out", "--prepare-only", toolrec=self.RECORD,
                toolrec_path=rec_path, git_heads=bad_heads), 4)
            self.assertFalse(list((Path(tmp) / "out").glob("*/launch-plan.json")))

    def test_load_tools_record_rejects_invalid_json_and_none(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            f.write("{not json")
            bad = f.name
        try:
            args = type("A", (), {"tools_record": bad})()
            rec, err, _ = RUNNER.load_tools_record(args, ROOT)
            self.assertIsNone(rec)
            self.assertIn("not valid JSON", err)
        finally:
            os.unlink(bad)
        none_args = type("A", (), {"tools_record": "none"})()
        self.assertEqual(RUNNER.load_tools_record(none_args, ROOT), (None, None, None))
        missing_args = type("A", (), {"tools_record": "/nonexistent/x.json"})()
        self.assertEqual(RUNNER.load_tools_record(missing_args, ROOT), (None, None, None))

    def test_timeout_is_forwarded_to_the_remote_command(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(
                Path(tmp), "--prepare-only", "--stages", "fetch-queue",
                "--timeout", "6000"), 0)
            plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
            command = plan["command"]
            index = command.index("--timeout")
            self.assertEqual(command[index + 1], "6000")
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(
                Path(tmp), "--prepare-only", "--stages", "fetch-queue"), 0)
            plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
            command = plan["command"]
            index = command.index("--timeout")
            self.assertEqual(command[index + 1], "2400")

    def test_core_leaf_stages_share_the_reference_package_without_duplication(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(
                Path(tmp), "--prepare-only", "--stages",
                "config,commit-defaults,load-translation-synth",
                tracked="core/include/cv64a6_imafdc_sv39_config_pkg.sv\n"), 0)
            plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
            manifest = json.loads(Path(plan["manifest"]).read_text())
            self.assertIn("cv64a6_imafdc_sv39_config_pkg.sv", manifest["sources"])

    def test_commit_reference_package_does_not_duplicate_configuration_sweep(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(
                Path(tmp), "--prepare-only", "--stages", "config,commit-defaults",
                tracked="core/include/cv64a6_imafdc_sv39_config_pkg.sv\n"), 0)
            plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
            manifest = json.loads(Path(plan["manifest"]).read_text())
            self.assertIn("cv64a6_imafdc_sv39_config_pkg.sv", manifest["sources"])

    def test_launch_without_runtime_still_refuses(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(Path(tmp)), 4)
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_quiesce_preparation_records_its_bench_and_runtime_blockers(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            output = Path(tmp)
            self.assertEqual(self.invoke(
                output, "--prepare-only", "--stages", "quiesce"), 0)
            plan = json.loads(next(output.glob("*/launch-plan.json")).read_text())
            self.assertEqual(plan["stages"], ["quiesce"])
            self.assertEqual(len(plan["blockers"]), 2)
            manifest = json.loads(Path(plan["manifest"]).read_text())
            source = ROOT / "verif/tb/storamic/tb_g6lc_storamic_quiesce.sv"
            self.assertEqual(manifest["sources"][source.name],
                             hashlib.sha256(source.read_bytes()).hexdigest())

    def test_supplied_runtime_is_not_claimed_validated_by_preparation(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            output = Path(tmp)
            self.assertEqual(self.invoke(
                output, "--prepare-only", "--runtime-json", "/remote/runtime.json",
                "--runtime-header-sha256", "a" * 64), 0)
            plan = json.loads(next(output.glob("*/launch-plan.json")).read_text())
            self.assertEqual(plan["blockers"], [])
            self.assertFalse(plan["qualification"])
            self.assertIn("performed by the remote leaf", plan["runtime_validation"])

    def test_checkpoint_preparation_tracks_bench_and_requires_runtime(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            output = Path(tmp)
            self.assertEqual(self.invoke(
                output, "--prepare-only", "--stages", "checkpoint-ram"), 0)
            plan = json.loads(next(output.glob("*/launch-plan.json")).read_text())
            self.assertEqual(len(plan["blockers"]), 2)
            manifest = json.loads(Path(plan["manifest"]).read_text())
            source = ROOT / "verif/tb/storamic/tb_g6lc_storamic_checkpoint_ram.sv"
            self.assertEqual(manifest["sources"][source.name],
                             hashlib.sha256(source.read_bytes()).hexdigest())

    def test_formal_preparation_needs_no_cpp_runtime(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            output = Path(tmp)
            self.assertEqual(self.invoke(
                output, "--prepare-only", "--stages", "quiesce-formal"), 0)
            plan = json.loads(next(output.glob("*/launch-plan.json")).read_text())
            self.assertEqual(plan["blockers"], [])
            manifest = json.loads(Path(plan["manifest"]).read_text())
            source = ROOT / "verif/tb/storamic/formal_g6lc_storamic_quiesce.sv"
            self.assertEqual(manifest["sources"][source.name],
                             hashlib.sha256(source.read_bytes()).hexdigest())

    def test_bad_digest_is_rejected_before_preparation(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
                self.invoke(Path(tmp), "--prepare-only", "--runtime-header-sha256", "bad")
            self.assertEqual(cm.exception.code, 2)
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_checkpoint_formal_preparation_is_runtime_independent(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            output = Path(tmp)
            self.assertEqual(self.invoke(
                output, "--prepare-only", "--stages", "checkpoint-synth,checkpoint-formal"), 0)
            plan = json.loads(next(output.glob("*/launch-plan.json")).read_text())
            self.assertEqual(plan["blockers"], [])
            manifest = json.loads(Path(plan["manifest"]).read_text())
            for name in ("g6lc_storamic_checkpoint_ctrl.sv",
                         "formal_g6lc_storamic_checkpoint_ctrl.sv"):
                self.assertIn(name, manifest["sources"])

    def test_record_preparation_binds_stages_and_real_media_sources(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            output = Path(tmp)
            self.assertEqual(self.invoke(
                output, "--prepare-only", "--stages", "checkpoint-record"), 0)
            plan = json.loads(next(output.glob("*/launch-plan.json")).read_text())
            manifest = json.loads(Path(plan["manifest"]).read_text())
            self.assertEqual(manifest["stages"], plan["stages"])
            self.assertEqual(len(plan["blockers"]), 2)
            for name in ("g6lc_storamic_checkpoint_pkg.sv", "g6lc_storamic_checkpoint_io.sv",
                         "g6lc_storamic_checkpoint_media.sv", "g6lc_storamic_store_guard.sv",
                         "tb_g6lc_storamic_checkpoint_media.sv"):
                self.assertIn(name, manifest["sources"])

    def test_record_formal_preparation_needs_no_runtime_or_launch(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            output = Path(tmp)
            self.assertEqual(self.invoke(
                output, "--prepare-only", "--stages",
                "checkpoint-record-synth,checkpoint-record-formal"), 0)
            plan = json.loads(next(output.glob("*/launch-plan.json")).read_text())
            self.assertEqual(plan["blockers"], [])
            manifest = json.loads(Path(plan["manifest"]).read_text())
            self.assertEqual(manifest["stages"], plan["stages"])
            self.assertIn("formal_g6lc_storamic_checkpoint_io.sv", manifest["sources"])
            self.assertIn("formal_g6lc_storamic_checkpoint_codec.sv", manifest["sources"])

    def test_service_preparation_preserves_sources_and_runtime_boundary(self):
        for stages, blockers in (
                ("checkpoint-service", 2),
                ("checkpoint-service-synth,checkpoint-service-formal", 0)):
            with self.subTest(stages=stages), \
                    tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
                output = Path(tmp)
                self.assertEqual(self.invoke(
                    output, "--prepare-only", "--stages", stages), 0)
                plan = json.loads(next(output.glob("*/launch-plan.json")).read_text())
                self.assertEqual(len(plan["blockers"]), blockers)
                manifest = json.loads(Path(plan["manifest"]).read_text())
                self.assertEqual(manifest["stages"], plan["stages"])
                for relative in (
                        "g6lc_storamic/rtl/fabric/g6lc_storamic_checkpoint_service.sv",
                        "verif/tb/storamic/tb_g6lc_storamic_checkpoint_service.sv",
                        "verif/tb/storamic/formal_g6lc_storamic_checkpoint_service.sv"):
                    source = ROOT / relative
                    self.assertEqual(manifest["sources"][source.name],
                                     hashlib.sha256(source.read_bytes()).hexdigest())

    def test_endpoint_preparation_keeps_native_inactive_and_captures_binding(self):
        for stages, blockers in (
                ("checkpoint-endpoint", 2),
                ("checkpoint-endpoint-synth,checkpoint-endpoint-formal", 0)):
            with self.subTest(stages=stages), \
                    tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
                output = Path(tmp)
                self.assertEqual(self.invoke(output, "--prepare-only", "--stages", stages), 0)
                plan = json.loads(next(output.glob("*/launch-plan.json")).read_text())
                self.assertEqual(len(plan["blockers"]), blockers)
                manifest = json.loads(Path(plan["manifest"]).read_text())
                for relative in (
                        "corev_apu/storamic/g6lc_storamic_checkpoint_endpoint.sv",
                        "corev_apu/storamic/g6lc_storamic_checkpoint_model.sv",
                        "g6lc_storamic/rtl/fabric/g6lc_storamic_checkpoint_service.sv",
                        "verif/tb/storamic/formal_g6lc_storamic_checkpoint_endpoint.sv",
                        "verif/tb/storamic/tb_g6lc_storamic_checkpoint_endpoint.sv"):
                    source = ROOT / relative
                    self.assertEqual(manifest["sources"][source.name],
                                     hashlib.sha256(source.read_bytes()).hexdigest())
                endpoint = (ROOT / "corev_apu/storamic/g6lc_storamic_checkpoint_endpoint.sv").read_text()
                self.assertIn("Cfg = g6lc_storamic_cfg_pkg::StoramicOff", endpoint)

    def test_cpu_origin_and_csr_scc_register_and_prepare_independently(self):
        for stage, blockers in (("cpu-origin", 2), ("csr-scc", 0),
                                ("cpu-debug", 2),
                                ("cpu-origin,cpu-debug", 2),
                                ("cpu-origin,csr-scc", 2),
                                ("cpu-debug,cpu-origin,csr-scc", 2),
                                ("fetch-queue,cpu-origin,cpu-debug,csr-scc", 2)):
            with self.subTest(stage=stage), \
                    tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
                self.assertEqual(self.invoke(
                    Path(tmp), "--prepare-only", "--stages", stage), 0)
                plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
                self.assertEqual(len(plan["blockers"]), blockers)
                manifest = json.loads(Path(plan["manifest"]).read_text())
                self.assertEqual(manifest["stages"], plan["stages"])
                self.assertFalse(plan["qualification"])

    def test_cpu_origin_tracks_frozen_closure_and_bench_inputs(self):
        tracked = {
            "verif/tb/storamic/cpu_origin_plan.json": None,
            "verif/tb/storamic/run_cpu_origin.py": None,
            "verif/tb/storamic/tb_g6lc_storamic_cpu_origin.sv": None,
            "verif/tb/storamic/g6lc_cpu_origin_program.py": None,
            "verif/tb/storamic/origin_cache.vlt": None,
            "verif/tb/apu/g6lc_dram_peek64_stub.cpp": None,
            "core/cva6.sv": None,
            "core/csr_regfile.sv": None,
            "core/include/ariane_pkg.sv": None,
        }
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(
                Path(tmp), "--prepare-only", "--stages", "cpu-origin"), 0)
            plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
            manifest = json.loads(Path(plan["manifest"]).read_text())
            self.assertGreater(len(manifest["sources"]), 260)
            for name in tracked:
                path = ROOT / name
                self.assertEqual(manifest["sources"][path.name],
                                 hashlib.sha256(path.read_bytes()).hexdigest())

    def test_cpu_debug_tracks_frozen_closure_and_debug_inputs(self):
        tracked = {
            "verif/tb/storamic/cpu_origin_plan.json": None,
            "verif/tb/storamic/run_cpu_debug.py": None,
            "verif/tb/storamic/run_cpu_origin.py": None,
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug.sv": None,
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_interpreter.sv": None,
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_netlist.sv": None,
            "verif/tb/storamic/g6lc_cpu_debug_program.py": None,
            "verif/tb/storamic/g6lc_cpu_origin_program.py": None,
            "verif/tb/storamic/origin_cache.vlt": None,
            "verif/tb/apu/g6lc_dram_peek64_stub.cpp": None,
            "core/load_store_unit.sv": None,
            "core/cva6.sv": None,
        }
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(
                Path(tmp), "--prepare-only", "--stages", "cpu-debug"), 0)
            plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
            manifest = json.loads(Path(plan["manifest"]).read_text())
            self.assertGreater(len(manifest["sources"]), 260)
            for name in tracked:
                path = ROOT / name
                self.assertEqual(manifest["sources"][path.name],
                                 hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertNotIn("tb_g6lc_storamic_cpu_origin.sv", manifest["sources"])

    def test_csr_scc_sources_are_leaf_only(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(
                Path(tmp), "--prepare-only", "--stages", "csr-scc"), 0)
            plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
            manifest = json.loads(Path(plan["manifest"]).read_text())
            for name in ("csr_regfile.sv", "trigger_module.sv", "run_csr_scc.py",
                         "triggers_pkg.sv", "rvfi_types.svh",
                         "cv64a6_imafdc_sv39_config_pkg.sv"):
                self.assertIn(name, manifest["sources"])
            for name in ("cpu_origin_plan.json", "run_cpu_origin.py",
                         "tb_g6lc_storamic_cpu_origin.sv", "cva6.sv"):
                self.assertNotIn(name, manifest["sources"])

    def test_strict_pins_and_core_scc_register_and_track_closure(self):
        for stage in ("cpu-strict-pins", "core-scc",
                      "cpu-strict-pins,core-scc"):
            with self.subTest(stage=stage), \
                    tempfile.TemporaryDirectory(
                        dir=ROOT / "build-platform/workspace") as tmp:
                self.assertEqual(self.invoke(
                    Path(tmp), "--prepare-only", "--stages", stage), 0)
                plan = json.loads(
                    next(Path(tmp).glob("*/launch-plan.json")).read_text())
                manifest = json.loads(Path(plan["manifest"]).read_text())
                self.assertEqual(manifest["stages"], plan["stages"])
                # cpu_origin closure is the shared proof/diagnostic basis.
                self.assertGreater(len(manifest["sources"]), 260)
                for name in ("cpu_origin_plan.json", "cva6.sv",
                             "csr_regfile.sv", "g6lc_core_scc_top.sv",
                             "run_core_scc.py"):
                    self.assertIn(name, manifest["sources"])
                if "cpu-strict-pins" in stage:
                    for name in ("cpu_strict_pins.json",
                                 "cpu_strict_fields.vlt",
                                 "g6lc_strict_pins_canary.sv",
                                 "tb_g6lc_storamic_cpu_origin.sv",
                                 "run_cpu_strict_pins.py"):
                        self.assertIn(name, manifest["sources"])

    def test_core_scc_is_not_a_simulation_stage(self):
        # core-scc is Yosys-only: it must not force the C++/Verilator runtime.
        self.assertNotIn("core-scc", RUNNER.SIMULATION_STAGES)
        self.assertIn("core-scc", RUNNER.ALLOWED_STAGES)
        self.assertIn("cpu-strict-pins", RUNNER.SIMULATION_STAGES)

    def test_axi_gate_formal_registers_and_tracks_its_closure(self):
        # axi-gate-formal is Yosys-only (no C++/Verilator runtime) and its
        # source closure is exactly the two DUTs, two wrappers and the runner.
        self.assertNotIn("axi-gate-formal", RUNNER.SIMULATION_STAGES)
        self.assertIn("axi-gate-formal", RUNNER.ALLOWED_STAGES)
        with tempfile.TemporaryDirectory(
                dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(
                Path(tmp), "--prepare-only", "--stages", "axi-gate-formal"), 0)
            plan = json.loads(
                next(Path(tmp).glob("*/launch-plan.json")).read_text())
            manifest = json.loads(Path(plan["manifest"]).read_text())
            self.assertEqual(manifest["stages"], ["axi-gate-formal"])
            for name in ("g6lc_storamic_axi_gate.sv",
                         "g6lc_storamic_cpu_pause.sv",
                         "formal_g6lc_storamic_axi_gate.sv",
                         "formal_g6lc_storamic_cpu_pause.sv",
                         "run_axi_gate_formal.py", "yosys_bin.py"):
                self.assertIn(name, manifest["sources"])

    def test_cpu_pause_registers_and_tracks_its_closure(self):
        # cpu-pause is a real-CPU simulation stage: it must be allowed, need the
        # runtime, and carry the cpu_origin closure plus gate/pause/rvfi/bench.
        self.assertIn("cpu-pause", RUNNER.SIMULATION_STAGES)
        self.assertIn("cpu-pause", RUNNER.ALLOWED_STAGES)
        with tempfile.TemporaryDirectory(
                dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(
                Path(tmp), "--prepare-only", "--stages", "cpu-pause"), 0)
            plan = json.loads(
                next(Path(tmp).glob("*/launch-plan.json")).read_text())
            manifest = json.loads(Path(plan["manifest"]).read_text())
            self.assertEqual(manifest["stages"], ["cpu-pause"])
            for name in ("cpu_origin_plan.json", "cva6.sv", "cva6_rvfi.sv",
                         "g6lc_storamic_axi_gate.sv",
                         "g6lc_storamic_cpu_pause.sv",
                         "tb_g6lc_storamic_cpu_pause.sv",
                         "g6lc_cpu_pause_program.py", "run_cpu_pause.py"):
                self.assertIn(name, manifest["sources"])

    def test_stq_commit_flush_sources_are_leaf_only(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(
                Path(tmp), "--prepare-only", "--stages", "stq-commit-flush"), 0)
            plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
            manifest = json.loads(Path(plan["manifest"]).read_text())
            for name in ("store_buffer.sv", "tb_g6lc_stq_commit_flush.sv",
                         "run_stq_commit_flush.py", "config_pkg.sv",
                         "g6lc64_ooo_config_pkg.sv", "riscv_pkg.sv",
                         "ariane_pkg.sv", "g6lc_ooo_pkg.sv"):
                self.assertIn(name, manifest["sources"])
            for name in ("cpu_origin_plan.json", "run_cpu_origin.py",
                         "cva6.sv", "load_store_unit.sv"):
                self.assertNotIn(name, manifest["sources"])

    def test_cpu_debug_stq_mutant_shares_the_cpu_debug_closure(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            self.assertEqual(self.invoke(
                Path(tmp), "--prepare-only", "--stages",
                "cpu-debug-stq-mutant"), 0)
            plan = json.loads(next(Path(tmp).glob("*/launch-plan.json")).read_text())
            manifest = json.loads(Path(plan["manifest"]).read_text())
            self.assertEqual(manifest["stages"], ["cpu-debug-stq-mutant"])
            for name in ("cpu_origin_plan.json", "run_cpu_debug.py",
                         "tb_g6lc_storamic_cpu_debug.sv",
                         "g6lc_cpu_debug_program.py", "store_buffer.sv"):
                self.assertIn(name, manifest["sources"])

    def test_csr_scc_mutation_reverts_exactly_the_promoted_fix(self):
        spec = importlib.util.spec_from_file_location(
            "storamic_run_csr_scc", Path(__file__).with_name("run_csr_scc.py"))
        stage = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(stage)
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
            for count in (0, 2):
                source = Path(tmp) / f"csr{count}.sv"
                source.write_text(
                    "module m;\n" + "    mask                   = '0;\n" * count +
                    "endmodule\n")
                with self.assertRaisesRegex(RuntimeError, "CSR_SCC_MUTATION_INVENTORY"):
                    stage._mutate(source, Path(tmp) / "mutant.sv")
            mutant = Path(tmp) / "mutant.sv"
            stage._mutate(ROOT / "core/csr_regfile.sv", mutant)
            text = mutant.read_text()
            self.assertIsNone(re.search(r"^    mask\s*=\s*'0;\s*$", text, re.M))
            self.assertNotIn("automatic logic DirVecOnly;", text)
            self.assertIn("logic DirVecOnly;", text)

    def test_unknown_and_duplicate_stages_refuse_before_preparation(self):
        for stages in ("checkpoint-record,unknown", "checkpoint-record,checkpoint-record"):
            with self.subTest(stages=stages), \
                    tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp:
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
                    self.invoke(Path(tmp), "--prepare-only", "--stages", stages)
                self.assertEqual(cm.exception.code, 2)
                self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_query_command_searches_output_and_work_with_tail(self):
        cmd = RUNNER.query_command("/opt/testharness", "storamic-abc123",
                                   "CHECKPOINT_ROUTE_FAIL", tail=7, file_glob="*.log")
        self.assertIn("/opt/testharness/runs/storamic-abc123", cmd)
        self.assertIn("find output work", cmd)
        self.assertIn("-name '*.log'", cmd)
        self.assertIn("grep -HnE " + __import__("shlex").quote("CHECKPOINT_ROUTE_FAIL"), cmd)
        self.assertTrue(cmd.rstrip().endswith("tail -7"))

    def test_query_command_quotes_hostile_pattern(self):
        import shlex
        pattern = "a'; rm -rf /; echo '"
        cmd = RUNNER.query_command("/opt/testharness", "r1", pattern)
        # The pattern is single-quoted for the remote shell, so it cannot break out.
        self.assertIn("grep -HnE " + shlex.quote(pattern), cmd)

    def test_query_mode_invokes_remote_shell_without_stages(self):
        captured = {}

        def fake_call(command, cwd=None):
            captured["command"] = command
            return 0

        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp, \
                mock.patch.object(sys, "argv", [
                    "run_remote.py", "--query", "storamic-abc123",
                    "--grep", "UNOPTFLAT", "--tail", "3", "--file", "*.log"]), \
                mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch.object(RUNNER.shutil, "which", return_value="/offline/bun"), \
                mock.patch.object(RUNNER.subprocess, "call", side_effect=fake_call), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(RUNNER.main(), 0)
        command = captured["command"]
        self.assertIn("remote", command)
        self.assertIn("shell", command)
        remote_cmd = command[command.index("--") + 1]
        self.assertIn("/runs/storamic-abc123", remote_cmd)
        self.assertIn("UNOPTFLAT", remote_cmd)
        self.assertTrue(remote_cmd.rstrip().endswith("tail -3"))

    def test_query_requires_grep(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build-platform/workspace") as tmp, \
                mock.patch.object(sys, "argv", [
                    "run_remote.py", "--query", "storamic-abc123"]), \
                mock.patch.dict(os.environ, {}, clear=True), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(RUNNER.main(), 4)
        self.assertIn("--grep", out.getvalue())


if __name__ == "__main__":
    unittest.main()
