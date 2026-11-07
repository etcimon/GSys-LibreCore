# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
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
