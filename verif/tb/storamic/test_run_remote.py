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
    def invoke(self, output, *args, tracked=""):
        with mock.patch.object(sys, "argv", [
                "run_remote.py", "--stages", "dstore",
                "--output-root", str(output), *args]), \
                mock.patch.dict(os.environ, {}, clear=True), \
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


if __name__ == "__main__":
    unittest.main()
