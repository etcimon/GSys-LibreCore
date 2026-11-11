# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Exercise independent formal-stage setup without invoking Linux tools."""
import ast
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest


class IndependentFormalStageTests(unittest.TestCase):
    def run_block_stage(self, mode="pass"):
        runner = Path(__file__).with_name("run_leaf.py")
        tree = ast.parse(runner.read_text())
        helpers = [n for n in tree.body if isinstance(n, ast.FunctionDef)
                   and n.name in {"run_block_formal", "block_formal_groups"}]
        workspace = runner.resolve().parents[3] / "build-platform/workspace"
        with tempfile.TemporaryDirectory(prefix="storamic-block-stage-", dir=workspace) as temp:
            out = Path(temp)
            scripts, budgets, outcomes, manifest = [], [], [], {}
            clock = [0.0]
            top, tag = "formal_block", "vblk-formal"
            prepared = out / f"{tag}-prepared.il"
            fixture = out / "formal_g6lc_storamic_virtio_blk.sv"
            fixture.write_text(runner.with_name(fixture.name).read_text())
            locations = [i for i, line in enumerate(fixture.read_text().splitlines(), 1)
                         if re.search(r"\bassert\s*\(", line)]
            self.assertEqual(len(locations), 32)
            assertions = {f"$assert{i}": {"type": "$assert",
                                        "attributes": {"src": f"{fixture.name}:{line}.1-{line}.80"}}
                          for i, line in enumerate(locations)}
            if mode == "duplicate-marker":
                fixture.write_text(fixture.read_text() + "\n// STORAMIC_WINDOW_LEMMAS_BEGIN\n")
            assumptions = {f"$assume{i}": {"type": "$assume", "attributes": {}} for i in range(4)}

            def run(command, **kwargs):
                script = Path(command[-1]).read_text()
                scripts.append(script)
                budgets.append(kwargs["timeout"])
                if "write_rtlil" in script:
                    prepared.write_text("frozen block model")
                    cells = {**assertions, **assumptions}
                    if mode == "missing-assertion":
                        del cells["$assert31"]
                    (out / f"{tag}-prepared.json").write_text(json.dumps(
                        {"modules": {top: {"cells": cells}}}))
                    return
                if mode == "budget":
                    clock[0] += 91
                if mode == "tamper":
                    prepared.write_text("changed block model")
                if mode in {"timeout", "mixed"} and len(scripts) == 2:
                    raise subprocess.TimeoutExpired(command, kwargs["timeout"])
                if mode in {"failure", "mixed"} and len(scripts) == 3:
                    raise subprocess.CalledProcessError(1, command)
                if mode == "other-failure" and len(scripts) == 5:
                    raise subprocess.CalledProcessError(1, command)

            environment = {
                "Path": Path, "json": json, "re": re, "time": SimpleNamespace(monotonic=lambda: clock[0]),
                "subprocess": SimpleNamespace(run=run, TimeoutExpired=subprocess.TimeoutExpired,
                                               CalledProcessError=subprocess.CalledProcessError,
                                               STDOUT=subprocess.STDOUT),
                "sha": lambda p: hashlib.sha256(p.read_bytes()).hexdigest(),
            }
            exec(compile(ast.Module(body=helpers, type_ignores=[]), str(runner), "exec"), environment)
            error = None
            try:
                environment["run_block_formal"](
                    "read_slang original_inputs\n", top, tag,
                    [("status-cover", "cover_status_o", 14), ("rsp-cover", "cover_rsp_o", 16)],
                    out, Path("/pinned/yosys"), manifest, outcomes, fixture)
            except (RuntimeError, subprocess.TimeoutExpired, subprocess.CalledProcessError) as caught:
                error = caught
            coverage = out / f"{tag}-coverage.json"
            return scripts, budgets, outcomes, json.loads(coverage.read_text()) if coverage.exists() else {}, error

    def test_block_prepares_once_and_preserves_every_assertion_and_concrete_cover(self):
        scripts, budgets, outcomes, coverage, error = self.run_block_stage()
        self.assertIsNone(error)
        self.assertEqual(len(scripts), 7)
        self.assertEqual(sum("read_slang" in script for script in scripts), 1)
        groups = coverage["groups"]
        self.assertEqual(groups["LEMMAS"], [f"$assert{i}" for i in range(20)])
        self.assertEqual(groups["RANGE"], ["$assert22"])
        for script, keep in ((scripts[1], groups["LEMMAS"]), (scripts[2], groups["LEMMAS"]),
                             (scripts[4], groups["OTHER"])):
            removed = script.split("delete ", 1)[1].splitlines()[0].split()
            self.assertEqual(set(removed), {f"formal_block/$assert{i}" for i in range(32)
                                            if f"$assert{i}" not in keep})
            self.assertNotIn("assert2assume", script)
            self.assertNotIn("cutpoint", script)
            self.assertIn("select -assert-count 4 t:$assume", script)
            self.assertIn("-prove-asserts -verify", script)
        self.assertIn("-seq 1 -set-init-zero -set-assumes -set-at 1 rst_ni 0", scripts[1])
        self.assertIn("-tempinduct-inductonly -maxsteps 1", scripts[2])
        self.assertNotIn("-set-init", scripts[2])
        self.assertNotIn("-set-at", scripts[2])
        self.assertIn("chformal -assert2assume", scripts[3])
        self.assertIn("cutpoint t:$dff", scripts[3])
        self.assertIn("select -assert-count 24 t:$assume", scripts[3])
        self.assertIn("sat -set-assumes -prove-asserts -verify", scripts[3])
        self.assertEqual(coverage["queries"][2]["requires"], ["window-base", "window-induction"])
        self.assertIn("-seq 14 -set-init-zero -set-assumes -set-at 1 rst_ni 0", scripts[4])
        for script, signal, depth in zip(scripts[5:], ("cover_status_o", "cover_rsp_o"), (14, 16)):
            self.assertNotIn("delete ", script)
            self.assertNotIn("cutpoint", script)
            self.assertNotIn("assert2assume", script)
            self.assertIn(f"-seq {depth}", script)
            self.assertIn(f"-prove {signal} 0 -falsify", script)
        self.assertEqual(budgets, [60] + [30] * 6)
        self.assertEqual(coverage["status"], "pass")
        self.assertTrue(coverage["coverage_complete"])
        self.assertEqual(len(outcomes), 3)

    def test_block_missing_obligation_and_model_tampering_cannot_pass(self):
        for mode, marker in (("missing-assertion", "INVENTORY"), ("duplicate-marker", "INVENTORY"),
                             ("tamper", "IDENTITY")):
            with self.subTest(mode=mode):
                _, _, outcomes, coverage, error = self.run_block_stage(mode)
                self.assertIsInstance(error, RuntimeError)
                self.assertIn(marker, str(error))
                self.assertEqual(outcomes, [])
                self.assertNotEqual(coverage.get("status"), "pass")

    def test_block_partial_results_and_budget_exhaustion_remain_explicit(self):
        for mode, status in (("timeout", "incomplete"), ("budget", "incomplete"),
                             ("failure", "fail"), ("mixed", "fail"), ("other-failure", "fail")):
            with self.subTest(mode=mode):
                scripts, _, outcomes, coverage, error = self.run_block_stage(mode)
                self.assertIsNotNone(error)
                self.assertEqual(outcomes, [])
                self.assertEqual(coverage["status"], status)
                self.assertEqual(len(coverage["queries"]), 6)
                if mode != "other-failure":
                    self.assertFalse(coverage["coverage_complete"])
                else:
                    self.assertTrue(coverage["coverage_complete"])
                if mode in {"timeout", "failure", "mixed"}:
                    self.assertTrue(coverage["queries"][2]["not_run"])
                    self.assertFalse(any("assert2assume" in script for script in scripts))
                if mode == "budget":
                    self.assertEqual(len(scripts), 3)
                    self.assertEqual(sum(q["status"] == "incomplete" for q in coverage["queries"]), 4)

    def run_register_formal(self, tamper=False):
        runner = Path(__file__).with_name("run_leaf.py")
        tree = ast.parse(runner.read_text())
        main = next(node for node in tree.body
                    if isinstance(node, ast.FunctionDef) and node.name == "main")
        block = next(node for node in ast.walk(main) if isinstance(node, ast.If) and
                     ast.unparse(node.test) == "'regs-formal' in stages")
        workspace = runner.resolve().parents[3] / "build-platform/workspace"
        with tempfile.TemporaryDirectory(prefix="storamic-regs-stage-", dir=workspace) as temp:
            out = Path(temp)
            calls, scripts = [], []
            prepared = out / "regs-formal-prepared.il"

            def run(command, **kwargs):
                text = Path(command[-1]).read_text()
                calls.append((command, kwargs))
                scripts.append(text)
                if "write_rtlil " in text:
                    prepared.write_text("prepared model")
                elif tamper:
                    prepared.write_text("changed model")

            environment = {
                "data": Path("/frozen"), "out": out, "stages": ["regs-formal"],
                "yosys": Path("/frozen/yosys"), "manifest": {}, "outcomes": [],
                "time": time, "json": json,
                "sha": lambda path: hashlib.sha256(path.read_bytes()).hexdigest(),
                "subprocess": SimpleNamespace(run=run, STDOUT=-2),
            }
            action = compile(ast.Module(body=block.body, type_ignores=[]), str(runner), "exec")
            if tamper:
                with self.assertRaisesRegex(RuntimeError, "REGS_FORMAL_MODEL_IDENTITY"):
                    exec(action, environment)
                self.assertEqual(len(calls), 2)
                return
            exec(action, environment)
            self.assertEqual(len(calls), 7)
            self.assertIn("flatten\nopt -full\ndffunmap\nopt_clean -purge\n", scripts[0])
            self.assertEqual(len(environment["outcomes"]), 6)
            self.assertEqual(environment["manifest"]["regs_formal_prepared"]["sha256"],
                             hashlib.sha256(b"prepared model").hexdigest())
            expected = [
                (12, "-prove-asserts -verify"),
                (12, "-prove cover_slverr_o 0 -falsify"),
                (12, "-prove cover_irqen_o 0 -falsify"),
                (12, "-prove cover_drain_o 0 -falsify"),
                (16, "-prove cover_commit_ok_o 0 -falsify"),
                (12, "-prove cover_commit_fail_o 0 -falsify"),
            ]
            for text, (depth, goal), (_, kwargs) in zip(scripts[1:], expected, calls[1:]):
                self.assertTrue(text.startswith(f"read_rtlil {prepared}\n"))
                self.assertIn(f"sat -seq {depth} -set-init-zero -set-assumes "
                              "-set-at 1 rst_ni 0 " + goal, text)
                self.assertEqual(kwargs["timeout"], 900)

    def test_register_goals_share_exact_preparation_without_weakening_queries(self):
        self.run_register_formal()

    def test_modified_prepared_register_model_rejects(self):
        self.run_register_formal(tamper=True)

    def test_only_maximum_model_extends_recorded_pgo_compile_budget(self):
        runner = Path(__file__).with_name("run_leaf.py")
        tree = ast.parse(runner.read_text())
        build = next(node for node in tree.body
                     if isinstance(node, ast.FunctionDef) and node.name == "build_model")
        self.assertEqual(build.args.kwonlyargs[0].arg, "pgo_compile_timeout")
        self.assertEqual(ast.literal_eval(build.args.kw_defaults[0]), 300)
        budget_calls = [
            node for node in ast.walk(tree) if isinstance(node, ast.Call) and
            any(key.arg == "pgo_compile_timeout" for key in node.keywords)]
        self.assertEqual(len(budget_calls), 1)
        budget = next(key.value for key in budget_calls[0].keywords
                      if key.arg == "pgo_compile_timeout")
        for name, expected in (("top-maximum", 1800), ("top", 300),
                               ("bad-width", 300)):
            value = eval(compile(ast.Expression(budget), str(runner), "eval"), {"name": name})
            self.assertEqual(value, expected)
        timeouts = [key.value for node in ast.walk(build) if isinstance(node, ast.Call)
                    for key in node.keywords if key.arg == "timeout"]
        self.assertEqual(sum(isinstance(node, ast.Name) and node.id == "pgo_compile_timeout"
                             for node in timeouts), 2)

    def test_block_formal_stages_initialize_their_own_sources(self):
        runner = Path(__file__).with_name("run_leaf.py")
        tree = ast.parse(runner.read_text())
        main = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "main")
        for stage, prefix, top in (
            ("vblk-formal", "vb_prefix", "formal_g6lc_storamic_virtio_blk"),
            ("vblk-flush-formal", "vf_prefix", "formal_g6lc_storamic_virtio_blk_flush"),
        ):
            with self.subTest(stage=stage):
                block = next(node for node in ast.walk(main) if isinstance(node, ast.If) and
                             ast.unparse(node.test) == repr(stage) + " in stages")
                setup = []
                for node in block.body:
                    if (isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
                            and isinstance(node.value.func, ast.Name)
                            and node.value.func.id == "run_block_formal"):
                        break
                    setup.append(node)
                environment = {"data": Path("/frozen"), "stages": [stage]}
                exec(compile(ast.Module(body=setup, type_ignores=[]), str(runner), "exec"), environment)
                self.assertIn("--top " + top + " ", environment[prefix])
                for name in ("g6lc_storamic_virtio_blk.sv", "formal_g6lc_storamic_virtio_blk.sv"):
                    self.assertIn(str(Path("/frozen") / name), environment[prefix])

    def test_dma_ownership_formal_is_reachable_and_preserves_all_queries(self):
        runner = Path(__file__).with_name("run_leaf.py")
        tree = ast.parse(runner.read_text())
        outer = next(node for node in ast.walk(tree) if isinstance(node, ast.If) and
                     isinstance(node.test, ast.BinOp) and
                     any(isinstance(value, ast.Constant) and value.value == "vdma-ownership-formal"
                         for value in ast.walk(node.test)))
        self.assertTrue(eval(compile(ast.Expression(outer.test), str(runner), "eval"),
                             {"stages": ["vdma-ownership-formal"]}))
        block = next(node for node in ast.walk(outer) if isinstance(node, ast.If) and
                     ast.unparse(node.test) == "'vdma-ownership-formal' in stages")
        workspace = runner.resolve().parents[3] / "build-platform/workspace"
        with tempfile.TemporaryDirectory(prefix="storamic-dma-formal-", dir=workspace) as temp:
            calls = []

            def run(command, **kwargs):
                text = Path(command[-1]).read_text()
                calls.append(text)
                negative = "-G OracleNegative=1 " in text
                if negative:
                    kwargs["stdout"].write("model found: FAIL")
                    kwargs["stdout"].flush()
                return SimpleNamespace(returncode=1 if negative else 0)

            env = {"data": Path("/frozen"), "out": Path(temp),
                   "yosys": Path("/frozen/yosys"), "outcomes": [],
                   "subprocess": SimpleNamespace(run=run, STDOUT=-2)}
            exec(compile(ast.Module(body=block.body, type_ignores=[]), str(runner), "exec"), env)
            self.assertEqual(len(calls), 6)
            self.assertEqual([row["depth"] for row in env["outcomes"]], [16, 8, 8, 8, 14, 12])
            for text in calls:
                for name in ("g6lc_storamic_pkg.sv", "g6lc_storamic_dma_axi.sv",
                             "formal_g6lc_storamic_dma_ownership.sv"):
                    self.assertIn(name, text)
                self.assertIn("flatten\nopt -full\ndffunmap\nopt_clean -purge", text)

    def test_policy_writer_profiles_and_independent_formal_sources(self):
        runner = Path(__file__).with_name("run_leaf.py")
        tree = ast.parse(runner.read_text())
        block = next(node for node in ast.walk(tree) if isinstance(node, ast.If) and
                     node.body and isinstance(node.body[0], ast.Assign) and
                     any(isinstance(value, ast.Constant) and value.value == "policy-writer"
                         for value in ast.walk(node.test)) and
                     any(isinstance(target, ast.Name) and target.id == "model_inputs"
                         for target in node.body[0].targets))
        env = {"stages": ["policy-writer"], "record_cases": []}
        exec(compile(ast.Module(body=[block], type_ignores=[]), str(runner), "exec"), env)
        self.assertEqual(len(env["record_cases"]), 5)
        self.assertEqual({case[0] for case in env["record_cases"]},
                         {"policy-writer-rsp0", "policy-writer-rsp4",
                          "policy-writer-rsp16", "policy-writer-off", "policy-writer-active-loss-reset"})
        for case in env["record_cases"]:
            self.assertIn("g6lc_storamic_policy_writer_model.sv", case[3])
            self.assertIn("g6lc_storamic_checkpoint_policy.sv", case[3])
            self.assertEqual(case[-1], "POLICY_WRITER_FAIL negative-oracle")
        block = next(node for node in ast.walk(tree) if isinstance(node, ast.If) and
                     node.body and isinstance(node.body[0], ast.Assign) and
                     isinstance(node.test, ast.BinOp) and
                     any(isinstance(value, ast.Constant) and value.value == "policy-writer-formal"
                         for value in ast.walk(node.test)) and
                     any(isinstance(target, ast.Name) and target.id == "model_inputs"
                         for target in node.body[0].targets))
        workspace = runner.resolve().parents[3] / "build-platform/workspace"
        with tempfile.TemporaryDirectory(prefix="storamic-policy-formal-", dir=workspace) as temp:
            calls = []

            def run(command, **kwargs):
                calls.append(Path(command[-1]).read_text())

            env = {"stages": ["policy-writer-formal"], "data": Path("/frozen"),
                   "out": Path(temp), "yosys": Path("/frozen/yosys"), "outcomes": [],
                   "subprocess": SimpleNamespace(run=run, STDOUT=-2)}
            exec(compile(ast.Module(body=[block], type_ignores=[]), str(runner), "exec"), env)
            self.assertEqual(len(calls), 5)
            self.assertEqual([row["policy_writer_formal"] for row in env["outcomes"]],
                             ["off-safety", "illegal-safety", "read-cover", "held-cover", "negative"])
            for text in calls:
                self.assertIn("formal_g6lc_storamic_policy_writer.sv", text)
                self.assertIn("g6lc_storamic_policy_writer_model.sv", text)
                self.assertIn("flatten\nopt -full\ndffunmap\nopt_clean -purge", text)
                self.assertIn("-seq 12 -set-init-zero -set-at 1 rst_ni 0", text)

    def test_writer_reset_stage_is_independent_and_preserves_original_profiles(self):
        runner = Path(__file__).with_name("run_leaf.py")
        tree = ast.parse(runner.read_text())
        block = next(node for node in ast.walk(tree) if isinstance(node, ast.If) and
                     node.body and isinstance(node.body[0], ast.Assign) and
                     isinstance(node.body[0].value, ast.List) and
                     any(isinstance(value, ast.Constant) and value.value == "checkpoint-writer-reset"
                         for value in ast.walk(node.test)) and
                     any(isinstance(target, ast.Name) and target.id == "model_inputs"
                         for target in node.body[0].targets))
        for stages, count, reset_count in [
            (["checkpoint-writer"], 6, 0),
            (["checkpoint-writer-reset"], 3, 3),
            (["checkpoint-writer", "checkpoint-writer-reset"], 9, 3),
        ]:
            with self.subTest(stages=stages):
                env = {"stages": stages, "record_cases": []}
                exec(compile(ast.Module(body=[block], type_ignores=[]), str(runner), "exec"), env)
                cases = env["record_cases"]
                self.assertEqual(len(cases), count)
                self.assertEqual(len({case[0] for case in cases}), count)
                reset = [case for case in cases if "-GResetDuringSave=1" in case[2]]
                self.assertEqual(len(reset), reset_count)
                if reset:
                    self.assertEqual({next(p for p in case[2] if p.startswith("-GRspCycles="))
                                      for case in reset}, {"-GRspCycles=0", "-GRspCycles=4",
                                                          "-GRspCycles=16"})
                for case in cases:
                    self.assertIn("g6lc_storamic_checkpoint_writer_model.sv", case[3])
                    self.assertIn("g6lc_storamic_dma_axi.sv", case[3])
                    self.assertEqual(case[-1], "CHECKPOINT_WRITER_FAIL negative-oracle")


    def test_cpu_origin_and_csr_scc_dispatch_to_their_stage_modules(self):
        runner = Path(__file__).with_name("run_leaf.py")
        tree = ast.parse(runner.read_text())
        main = next(node for node in tree.body
                    if isinstance(node, ast.FunctionDef) and node.name == "main")
        wanted = {
            "set(stages) & {'origin-profile', 'origin-queue'}",
            "set(stages) & {'cpu-origin', 'cpu-origin-unsupported', 'cpu-origin-atomic'}",
            "set(stages) & {'cpu-debug', 'cpu-debug-stq-mutant'}",
            "set(stages) & {'cpu-debug-trigger'}",
            "set(stages) & {'cpu-debug-return'}",
            "set(stages) & {'cpu-debug-queue'}",
            "set(stages) & {'stq-commit-flush'}",
            "set(stages) & {'csr-scc'}"}
        dispatch = {}
        for node in ast.walk(main):
            if isinstance(node, ast.If) and isinstance(node.test, ast.BinOp):
                text = ast.unparse(node.test)
                if text in wanted:
                    dispatch[text] = ast.unparse(node)
        self.assertEqual(set(dispatch), wanted)
        self.assertIn("run_origin_remote",
                      dispatch["set(stages) & {'origin-profile', 'origin-queue'}"])
        self.assertIn("run_cpu_origin",
                      dispatch["set(stages) & {'cpu-origin', 'cpu-origin-unsupported', 'cpu-origin-atomic'}"])
        self.assertIn("run_cpu_debug",
                      dispatch["set(stages) & {'cpu-debug', 'cpu-debug-stq-mutant'}"])
        self.assertIn("run_cpu_debug_trigger",
                      dispatch["set(stages) & {'cpu-debug-trigger'}"])
        self.assertIn("run_cpu_debug_return",
                      dispatch["set(stages) & {'cpu-debug-return'}"])
        self.assertIn("run_cpu_debug_queue",
                      dispatch["set(stages) & {'cpu-debug-queue'}"])
        self.assertIn("run_stq_commit_flush",
                      dispatch["set(stages) & {'stq-commit-flush'}"])
        self.assertIn("run_csr_scc", dispatch["set(stages) & {'csr-scc'}"])


if __name__ == "__main__":
    unittest.main()
