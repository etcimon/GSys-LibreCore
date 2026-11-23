#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Exercise overlay publication/resume rules on a disposable generated layout."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from g6lc_hyp8_tuning import OUTPUT, PREFIX, UnsupportedLayout, prepare
from g6lc_pack_generated_rows import lower_mux_rows
from g6lc_tuning_policy import lua_binary, plan_verilator_flags, select_policy


class NativeOverlayTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        core = PREFIX + "_g6lc_core__pi2"
        self.recipe = self.root / (PREFIX + "__verFiles.dat")
        self.recipe.write_text('C "-DG6LC_HYP8_MC --threads 2"\n')
        self.name = core + "__DepSet_h1__0"
        (self.root / (PREFIX + "_classes.mk")).write_text(
            "VM_PARALLEL_BUILDS = 1\nVM_CLASSES_FAST += \\\n\t" + self.name + " \\\n")
        self.source = self.root / (self.name + ".cpp")
        self.source.write_text("u_recover__DOT__input")
        (self.root / (core + ".h")).write_text("header")

    def test_resume_does_not_rewrite_or_relabel(self):
        with patch("g6lc_hyp8_tuning.lower", return_value=("packed", 2)), \
             patch("g6lc_hyp8_tuning.lower_columns", return_value=("tiled", 3)):
            summary = prepare(self.root)
        self.assertEqual(summary["translationUnits"], 1)
        self.assertEqual(self.source.read_text(), "u_recover__DOT__input")
        (self.root / "compiled.o").touch()
        self.assertEqual(prepare(self.root), summary)
        output = self.root / OUTPUT / self.source.name
        output.write_text("stale")
        with self.assertRaisesRegex(ValueError, "overlay changed"):
            prepare(self.root)
        output.write_text("tiled")
        self.source.write_text("new input")
        with self.assertRaisesRegex(ValueError, "overlay changed"):
            prepare(self.root)

    def test_no_coverage_or_legacy_objects(self):
        with self.assertRaises(UnsupportedLayout):
            prepare(self.root)
        self.assertFalse((self.root / OUTPUT).exists())
        (self.root / "compiled.o").touch()
        with self.assertRaisesRegex(ValueError, "cannot retrofit"):
            prepare(self.root)

    def test_wrong_resumed_schedule(self):
        self.recipe.write_text('C "-DG6LC_HYP8_SMT2 --threads 2"\n')
        with self.assertRaisesRegex(ValueError, "schedule"):
            prepare(self.root)

    @unittest.skipUnless(lua_binary(), "requires Lua on PATH")
    def test_lua_selects_other_model_and_preserves_original(self):
        prefix, cls = "Vfabric", "Vfabric_crossbar"
        name = cls + "__DepSet_h1__0"
        (self.root / (prefix + "__verFiles.dat")).write_text(
            'C "--threads 1"\nS 123 456 "/rtl/crossbar.sv"\n')
        (self.root / (prefix + "_classes.mk")).write_text(
            "VM_PARALLEL_BUILDS = 1\nVM_CLASSES_FAST += \\\n\t" + name + " \\\n")
        (self.root / (cls + ".h")).write_text(
            "VlWide<32>/*1023:0*/ src; VlWide<4>/*127:0*/ dst;")
        source = "void eval(Vfabric_crossbar* vlSelf) {\n"
        for b in range(4):
            terms = [f"(((vlSelf->src[{r}U] >> {b}U) & 1U) << {r}U)" for r in range(32)]
            source += f"    vlSelf->dst[{b}U] = " + " | ".join(terms) + ";\n"
        source += "}\n"
        cpp = self.root / (name + ".cpp")
        cpp.write_text(source)
        plugin = self.root / "fabric.lua"
        plugin.write_text('if model.command == "--threads 1" and model.has_source("crossbar.sv") then\n'
                          '  select_rule(model.prefix .. "_crossbar", "->src", "tiled-columns")\nend')
        result = prepare(self.root, plugin, prefix)
        self.assertEqual((result["packedRows"], result["tiledColumns"]), (0, 4))
        self.assertEqual(cpp.read_text(), source)
        self.assertIn("::gather<", (self.root/OUTPUT/cpp.name).read_text())
        self.assertEqual(prepare(self.root, plugin, prefix), result)
        plugin.write_text(plugin.read_text() + "\n-- edited policy")
        with self.assertRaisesRegex(ValueError, "overlay changed"):
            prepare(self.root, plugin, prefix)

    @unittest.skipUnless(lua_binary(), "requires Lua on PATH")
    def test_example_policy_parity_and_bad_plugin(self):
        cmd = "-DG6LC_HYP8_MC --threads 2"
        example = Path(__file__).parent / "hyp8/policies/recovery.lua"
        self.assertEqual(select_policy(PREFIX, cmd, example)[0], select_policy(PREFIX, cmd, None)[0])
        plugin = self.root / "bad.lua"
        plugin.write_text('select_rule("*", "", "not-a-transform")')
        with self.assertRaisesRegex(ValueError, "unknown checked transform"):
            prepare(self.root, plugin)
        self.assertFalse((self.root / OUTPUT).exists())

    def test_packed_mux_rows_matches_complemented_enable_mux(self):
        header = "VlWide<4>/*127:0*/ dst;\nVlWide<2>/*63:0*/ sel;\nVlWide<4>/*127:0*/ a;\nVlWide<4>/*127:0*/ b;\n"
        # Build a 32-bit complemented-enable 2-way bitwise mux matching Verilator's t1_fmk_s shape
        terms = []
        for bit in range(32):
            lane = (f"((1U & (((vlSelf->sel[0U] >> 3U) & (vlSelf->a[1U] >> {bit}U))"
                    f" | ((~ (vlSelf->sel[0U] >> 3U)) & (vlSelf->b[2U] >> {bit}U)))) << {bit}U)")
            terms.append(lane)
        source = "void eval(V* vlSelf) {\n    vlSelf->dst[0U] = " + " | ".join(terms) + ";\n}\n"
        rewritten, count = lower_mux_rows(source, header)
        self.assertEqual(count, 1)
        self.assertIn("^ 0xffffffffU", rewritten)
        self.assertIn("vlSelf->a[1U]", rewritten)
        self.assertIn("vlSelf->b[2U]", rewritten)

    @unittest.skipUnless(lua_binary(), "requires Lua on PATH")
    def test_lua_clock_skip_planning_and_stats_verification(self):
        sleep_policy = Path(__file__).parent / "hyp8/policies/hyp8_mc_sleep.lua"
        flags, meta = plan_verilator_flags(
            PREFIX, "-DG6LC_HYP8_MC -DG6LC_HYP8_MC_SLEEP --threads 2", sleep_policy
        )
        self.assertIn("-fclock-skip-sink", flags)
        self.assertIn("-fdfg-peephole-pack-bitwise-mux", flags)
        self.assertEqual(meta["clockSkip"], [{"mode": "sink", "policy": "required"}])

        # Verify required clock-skip fails closed if __stats.txt shows 0 sink groups,
        # and passes when sink groups > 0.
        self.recipe.write_text('C "-DG6LC_HYP8_MC -DG6LC_HYP8_MC_SLEEP --threads 2"\n')
        stats_path = self.root / (PREFIX + "__stats.txt")
        stats_path.write_text("  Optimizations, Clock skip sink groups  0\n")
        with patch("g6lc_hyp8_tuning.lower", return_value=("packed", 1)), \
             patch("g6lc_hyp8_tuning.lower_mux_rows", return_value=("muxed", 2)), \
             patch("g6lc_hyp8_tuning.lower_columns", return_value=("tiled", 3)):
            with self.assertRaisesRegex(UnsupportedLayout, "required clock-skip"):
                prepare(self.root, sleep_policy)
            stats_path.write_text(
                "  Optimizations, Clock skip sink groups  4\n"
                "  Optimizations, Clock skip sink deferred calls  3400\n"
            )
            summary = prepare(self.root, sleep_policy)
        self.assertEqual(summary["clockSkipStats"]["sinkGroups"], 4)
        self.assertEqual(summary["clockSkipStats"]["sinkDeferredCalls"], 3400)
        self.assertEqual(summary["packedMuxRows"], 2)
