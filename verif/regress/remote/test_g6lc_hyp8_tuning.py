#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Exercise overlay publication/resume rules on a disposable generated layout."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from g6lc_hyp8_tuning import OUTPUT, PREFIX, UnsupportedLayout, prepare
from g6lc_pack_age_compare import lower_age_compare
from g6lc_pack_assert_cone import compute_assert_only_vars, lower_assert_cone
from g6lc_pack_assert_guard import lower_assert_guard
from g6lc_pack_bit_columns import lower_bit_columns
from g6lc_pack_generated_rows import lower_mux_rows
from g6lc_pack_scatter_mask import lower_scatter_mask
from g6lc_pack_wide_mux import lower_wide_mux
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

    def test_strided_bit_columns_full64_nonbyte_stride(self):
        # Stride = 522 bits (non-multiple of 8, matching i_sb_commit_bundle.mem_col)
        # 64 entries * 522 bits = 33408 bits = 1044 VlWide words
        header = "VlWide<1050>/*33599:0*/ mem_flat;\nVlWide<16>/*511:0*/ mem_col;\n"
        lines = ["void eval(V* vlSelf) {", "    // Body"]
        for col in range(8):
            base = 248 + col
            terms = []
            for bit in range(63, -1, -1):
                src_bit = base + bit * 522
                w, sh = divmod(src_bit, 32)
                terms.append(f"(((QData)((IData)((1U & (vlSelf->mem_flat[{w}U] >> {sh}U))))) << {bit}U)")
            expr = " | ".join(terms)
            lines.append(f"    vlSelf->mem_col[{2*col}U] = (IData)({expr});")
            lines.append(f"    vlSelf->mem_col[{2*col+1}U] = (IData)(({expr}) >> 0x20U);")
        lines.append("}\n")
        rewritten, count = lower_bit_columns("\n".join(lines), header)
        self.assertEqual(count, 16)
        self.assertIn("g6lc_column::gather_bits64<248ULL, 522ULL>", rewritten)
        self.assertIn("g6lc_column::column64<0>", rewritten)
        self.assertIn("g6lc_column::column64<7>", rewritten)

    def test_circular_age_compare_uvec_ou_and_word_batch(self):
        lines = ["void eval(V* vlSelf) {", "    // Body"]
        # 1. 64-entry uvec run
        for k in range(64):
            clr = (~(1 << k)) & 0xffffffffffffffff
            lines.append(
                f"    __Vfunc_ooo_age_older__{100+k}__cp = (0x3fU & (IData)(vlSelf->cp));\n"
                f"    __Vfunc_ooo_age_older__{100+k}__b = (0x3fU & (vlSelf->tid[4U] >> 0xaU));\n"
                f"    __Vfunc_ooo_age_older__{100+k}__bm = (0x3fU & __Vfunc_ooo_age_older__{100+k}__b);\n"
                f"    __Vfunc_ooo_age_older__{100+k}__cm = (0x3fU & __Vfunc_ooo_age_older__{100+k}__cp);\n"
                f"    __Vfunc_ooo_age_older__{100+k}__Vfuncout = ((({k}U < __Vfunc_ooo_age_older__{100+k}__cm) == "
                f"(__Vfunc_ooo_age_older__{100+k}__bm < __Vfunc_ooo_age_older__{100+k}__cm)) ? "
                f"({k}U < __Vfunc_ooo_age_older__{100+k}__bm) : (__Vfunc_ooo_age_older__{100+k}__bm < __Vfunc_ooo_age_older__{100+k}__cm));\n"
                f"    vlSelf->uvec = ((0x{clr:016x}ULL & vlSelf->uvec) | ((QData)((IData)((((IData)((vlSelf->unres >> {k}U)) & "
                f"(vlSelf->hart[(3U & (((IData)({k}U) + (0x40U & (vlSelf->info_hart >> 0x11U))) >> 5U))] >> "
                f"(0x1fU & ((IData)({k}U) + (0x40U & (vlSelf->info_hart >> 0x11U)))))) & "
                f"(IData)(__Vfunc_ooo_age_older__{100+k}__Vfuncout)))) << {k}U));"
            )
        # 2. 8-bit word-batched vio_age_d run
        for b in range(8):
            clr32 = (~(1 << b)) & 0xffffffff
            lines.append(
                f"    __Vfunc_ooo_age_older__{200+b}__cp = (0x3fU & (IData)(vlSelf->cp));\n"
                f"    __Vfunc_ooo_age_older__{200+b}__b = (0x3fU & (vlSelf->vv[{b}U] >> 2U));\n"
                f"    __Vfunc_ooo_age_older__{200+b}__a = (0x3fU & (vlSelf->ld[0U] >> 3U));\n"
                f"    __Vfunc_ooo_age_older__{200+b}__am = (0x3fU & __Vfunc_ooo_age_older__{200+b}__a);\n"
                f"    __Vfunc_ooo_age_older__{200+b}__bm = (0x3fU & __Vfunc_ooo_age_older__{200+b}__b);\n"
                f"    __Vfunc_ooo_age_older__{200+b}__cm = (0x3fU & __Vfunc_ooo_age_older__{200+b}__cp);\n"
                f"    __Vfunc_ooo_age_older__{200+b}__Vfuncout = (((__Vfunc_ooo_age_older__{200+b}__am < __Vfunc_ooo_age_older__{200+b}__cm) == "
                f"(__Vfunc_ooo_age_older__{200+b}__bm < __Vfunc_ooo_age_older__{200+b}__cm)) ? "
                f"(__Vfunc_ooo_age_older__{200+b}__am < __Vfunc_ooo_age_older__{200+b}__bm) : "
                f"(__Vfunc_ooo_age_older__{200+b}__bm < __Vfunc_ooo_age_older__{200+b}__cm));\n"
                f"    vlSelf->vio_age_d[0x10U] = ((0x{clr32:08x}U & vlSelf->vio_age_d[0x10U]) | "
                f"((IData)(__Vfunc_ooo_age_older__{200+b}__Vfuncout) << {b}U));"
            )
        lines.append("}\n")
        rewritten, count = lower_age_compare("\n".join(lines))
        self.assertEqual(count, 72)
        self.assertIn("g6lc_age::mask64(", rewritten)
        self.assertIn("uint32_t __Vg6lcW", rewritten)

    def test_scatter_eq_mask_dwait(self):
        header = "SData/*15:0*/ cand_nd;\nVlWide<3>/*95:0*/ stl_eid_q;\nQData/*63:0*/ dwait_d;\n"
        out_terms = []
        for t in range(63, -1, -1):
            slot_terms = []
            for s in range(15, -1, -1):
                bit = s * 6
                w, sh = divmod(bit, 32)
                if sh + 6 <= 32:
                    if sh + 6 == 32:
                        eq = f"({t}U == (vlSelf->stl_eid_q[{w}U] >> {sh}U))"
                    else:
                        eq = f"({t << sh}U == ({0x3f << sh}U & vlSelf->stl_eid_q[{w}U]))"
                else:
                    lsh = 32 - sh
                    eq = f"({t}U == (0x3fU & ((vlSelf->stl_eid_q[{w+1}U] << {lsh}U) | (vlSelf->stl_eid_q[{w}U] >> {sh}U))))"
                mbit = f"((IData)(vlSelf->cand_nd) >> {s}U)" if s else "(IData)(vlSelf->cand_nd)"
                slot_terms.append(f"({mbit} & {eq})")
            body = " | ".join(slot_terms)
            out_terms.append(f"(((QData)((IData)({body}))) << {t}U)" if t else f"((QData)((IData)({body})))")
        source = "void eval(V* vlSelf) {\n    vlSelf->dwait_d = " + " | ".join(out_terms) + ";\n}\n"
        rewritten, count = lower_scatter_mask(source, header)
        self.assertEqual(count, 1)
        self.assertIn("g6lc_age::scatter_eq64<16U, 6U, 0U, 6U>(static_cast<uint32_t>(vlSelf->cand_nd), &vlSelf->stl_eid_q[0U])", rewritten)

    def test_wide_mux_guard_two_level_hoist(self):
        header = "VlWide<16>/*511:0*/ rob_d;\nVlWide<16>/*511:0*/ rob_q;\n"
        lines = ["void eval(V* vlSelf) {", "    // Body"]
        for k in range(10):
            lines.append(
                f"    vlSelf->rob_d[{k}U] = (C0[{k}U] & ((IData)(vlSelf->flush) ? C1[{k}U] "
                f": ((IData)(vlSelf->do_alloc) ? vlSelf->alloc[{k}U] : vlSelf->rob_q[{k}U])));"
            )
        lines.append("}\n")
        rewritten, count = lower_wide_mux("\n".join(lines), header)
        self.assertEqual(count, 10)
        self.assertIn("if ((IData)(vlSelf->flush))", rewritten)
        self.assertIn("} else if ((IData)(vlSelf->do_alloc)) {", rewritten)

    def test_assert_guard_hoist_onehot(self):
        source = (
            "void eval(V* vlSelf) {\n"
            "    if (VL_UNLIKELY((1U & (~ VL_ONEHOT0_I(((a == 1U) << 1U) | (a == 2U)))))) {\n"
            "        if (VL_UNLIKELY(vlSymsp->_vm_contextp__->assertOn())) {\n"
            "            VL_WRITEF(\"err\\n\");\n"
            "            VL_STOP_MT(\"x.sv\", 1, \"\");\n"
            "        }\n"
            "    }\n"
            "}\n"
        )
        rewritten, count = lower_assert_guard(source)
        self.assertEqual(count, 1)
        self.assertLess(rewritten.find("->assertOn()"), rewritten.find("VL_ONEHOT0_I"))

    def test_assert_cone_gate_slices_dead_shadow_vars(self):
        header = (
            "IData/*31:0*/ live_q;\n"
            "IData/*31:0*/ shadow_a;\n"
            "IData/*31:0*/ shadow_b;\n"
            "IData/*31:0*/ __Vcellout__out_o;\n"
        )
        tu = (
            "void eval(V* vlSelf) {\n"
            "    // Body\n"
            "    vlSelf->live_q = vlSelf->live_q + 1U;\n"
            "    vlSelf->__Vcellout__out_o = vlSelf->live_q;\n"
            "    vlSelf->shadow_a = vlSelf->live_q ^ 0x55U;\n"
            "    vlSelf->shadow_b = vlSelf->shadow_a + 1U;\n"
            "    if (VL_UNLIKELY(vlSymsp->_vm_contextp__->assertOn())) {\n"
            "        if (vlSelf->shadow_b != vlSelf->live_q) VL_STOP_MT(\"x.sv\", 1, \"\");\n"
            "    }\n"
            "}\n"
        )
        dead = compute_assert_only_vars(header, [tu])
        self.assertEqual(dead, {"shadow_a", "shadow_b"})
        rewritten, count = lower_assert_cone(tu, dead)
        self.assertEqual(count, 2)
        self.assertIn("if (VL_UNLIKELY(vlSymsp->_vm_contextp__->assertOn())) {\n        vlSelf->shadow_a", rewritten)
        self.assertNotIn("assertOn())) {\n        vlSelf->live_q", rewritten)

    @unittest.skipUnless(lua_binary(), "requires Lua on PATH")
    def test_lua_sentinel_policy_introspection_and_probes(self):
        sentinel_policy = Path(__file__).parent / "hyp8/policies/hyp8_mc_sentinel.lua"
        rules, meta = select_policy(
            PREFIX, "-DG6LC_HYP8_MC --threads 2", sentinel_policy,
            markers=("u_recover__DOT__", "i_sb_commit_bundle__DOT__mem_col",
                     "__Vfunc_ooo_age_older__", "i_stl_red__DOT__dwait_d", "i_rob__DOT__rob_d"),
            stats={"mtask_count": 30},
            sentinel_info={"dfg": {"strided_column_tile": 12}},
        )
        ops = {op for _, _, op in rules}
        self.assertTrue({"packed-rows", "packed-mux-rows", "tiled-columns",
                         "strided-bit-columns", "circular-age-compare",
                         "scatter-eq-mask", "wide-mux-guard"} <= ops)
        self.assertEqual(len(meta["sentinelProbes"]), 4)
