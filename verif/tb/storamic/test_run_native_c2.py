# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "run_native_c2", Path(__file__).with_name("run_native_c2.py"))
C2 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C2)

HARNESS = ROOT / "corev_apu/tb/ariane_testharness.sv"
NATIVE_LINE = ("STORAMIC_C2_NATIVE p0_aw=10 p0_ar=18 p1_aw=0 p1_ar=0 "
               "p2_aw=0 p2_ar=0 m0_aw=10 m0_ar=18 m1_aw=0 m1_ar=0 "
               "m2_aw=0 m2_ar=0 done_w=10 done_r=18 src_ok_aw=9 src_ok_ar=14 "
               "err_resp=2 max_outstanding=2 beats0=143 beats1=0 beats2=0 "
               "max_lid=7 pending=0 violations=0")
TOPO_LINE = ("STORAMIC_C2_TOPOLOGY slv=3 mst=11 idx=10 idw=4 idws=6 "
             "latency=0 maxtrans=8")


def _sim(native=True, topo=True, success=True, fatal=False, timed_out=False,
         fail_tohost=None):
    nat = None
    if native:
        nat = {"line": NATIVE_LINE, "p0_aw": 10, "p0_ar": 18, "p1_aw": 0,
               "p1_ar": 0, "p2_aw": 0, "p2_ar": 0, "m0_aw": 10, "m0_ar": 18,
               "m1_aw": 0, "m1_ar": 0, "m2_aw": 0, "m2_ar": 0, "done_w": 10,
               "done_r": 18, "src_ok_aw": 9, "src_ok_ar": 14, "err_resp": 2,
               "max_lid": 7, "pending": 0, "violations": 0, "beats2": 0}
        nat["line"] = NATIVE_LINE
    return {"rc": 0, "success": success, "timed_out": timed_out,
            "fail_tohost": fail_tohost, "fatal": fatal, "fatal_msg": None,
            "native": nat, "topology": TOPO_LINE if topo else None,
            "native_line": NATIVE_LINE if native else None, "tail": ""}


class _Ctx:
    def __init__(self, sim):
        self._sim = sim
        self.plusargs_seen = []

    def run_sim(self, tag, elf, plusargs=(), debug_disable=True):
        self.plusargs_seen.append(tuple(plusargs))
        self.debug_disable_seen = getattr(self, "debug_disable_seen", [])
        self.debug_disable_seen.append(debug_disable)
        return self._sim


class ParseTests(unittest.TestCase):
    def test_parse_native_extracts_fields(self):
        d = C2.parse_native("noise\n" + NATIVE_LINE + "\nmore")
        self.assertIsNotNone(d)
        self.assertEqual(d["p0_aw"], 10)
        self.assertEqual(d["src_ok_aw"], 9)
        self.assertEqual(d["src_ok_ar"], 14)
        self.assertEqual(d["violations"], 0)
        self.assertEqual(d["pending"], 0)
        self.assertEqual(d["max_lid"], 7)
        self.assertIn("STORAMIC_C2_NATIVE", d["line"])

    def test_parse_native_missing_returns_none(self):
        self.assertIsNone(C2.parse_native("no report here"))

    def test_parse_topo(self):
        self.assertEqual(C2.parse_topo("x\n" + TOPO_LINE + "\n"), TOPO_LINE)
        self.assertIsNone(C2.parse_topo("nothing"))

    def test_parse_sba(self):
        line = ("STORAMIC_SBA_PROBE reads=1 writes=1 "
                "rd_sberror=0 wr_sberror=0")
        d = C2.parse_sba("noise\n" + line + "\nmore")
        self.assertIsNotNone(d)
        self.assertEqual(d["reads"], 1)
        self.assertEqual(d["writes"], 1)
        self.assertEqual(d["rd_sberror"], 0)
        self.assertEqual(d["wr_sberror"], 0)
        self.assertIsNone(C2.parse_sba("no probe line"))

    def test_fields_ok_exact_and_mismatch(self):
        nat = C2.parse_native(NATIVE_LINE)
        ok, _ = C2.fields_ok(nat, C2.C2_FIELDS_PO)
        self.assertTrue(ok)
        bad = dict(C2.C2_FIELDS_PO, src_ok_aw=0)
        ok, why = C2.fields_ok(nat, bad)
        self.assertFalse(ok)
        self.assertIn("src_ok_aw", why)

    def test_p_eq_m(self):
        nat = C2.parse_native(NATIVE_LINE)
        self.assertTrue(C2.p_eq_m(nat))
        nat["m0_aw"] = 99
        self.assertFalse(C2.p_eq_m(nat))


class CaseVerdictTests(unittest.TestCase):
    def _run(self, sim, **kw):
        fd, name = tempfile.mkstemp(suffix=".elf")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(b"x")
            return C2._case(_Ctx(sim), "c", "t", Path(name), **kw)
        finally:
            Path(name).unlink(missing_ok=True)

    def test_exact_pass(self):
        rec = self._run(_sim(), expect_fields=C2.C2_FIELDS_PO,
                        expect_success=True)
        self.assertEqual(rec["status"], "pass")
        self.assertTrue(rec["pass"])

    def test_wrong_count_is_fail(self):
        nat = C2.parse_native(NATIVE_LINE)
        nat["p0_aw"] = 11
        sim = _sim(); sim["native"] = nat
        rec = self._run(sim, expect_fields=C2.C2_FIELDS_PO,
                        expect_success=True)
        self.assertEqual(rec["status"], "fail")
        self.assertFalse(rec["pass"])

    def test_probe_off_zero_src_ok(self):
        # probe-off expects src_ok 0/0; feed that exact variant.
        nat = C2.parse_native(NATIVE_LINE)
        nat["src_ok_aw"] = 0
        nat["src_ok_ar"] = 0
        sim = _sim(); sim["native"] = nat
        rec = self._run(sim, expect_fields=C2.C2_FIELDS_QF,
                        expect_success=True)
        self.assertEqual(rec["status"], "pass")

    def test_missing_report_line_is_incomplete(self):
        rec = self._run(_sim(native=False, topo=True),
                        expect_fields=C2.C2_FIELDS_PO, expect_success=True)
        self.assertEqual(rec["status"], "incomplete")
        self.assertFalse(rec["pass"])

    def test_missing_topology_is_incomplete(self):
        rec = self._run(_sim(native=True, topo=False),
                        expect_fields=C2.C2_FIELDS_PO, expect_success=True)
        self.assertEqual(rec["status"], "incomplete")

    def test_timeout_is_incomplete(self):
        rec = self._run(_sim(native=True, topo=True, timed_out=True),
                        expect_fields=C2.C2_FIELDS_PO, expect_success=True)
        self.assertEqual(rec["status"], "incomplete")

    def test_unsuccessful_expected_success_is_fail(self):
        rec = self._run(_sim(success=False, fail_tohost="126"),
                        expect_fields=C2.C2_FIELDS_PO, expect_success=True)
        self.assertEqual(rec["status"], "fail")

    def test_virtio_negative_tohost16(self):
        rec = self._run(_sim(success=False, fail_tohost="16"),
                        expect_fields={"violations": 0, "pending": 0},
                        expect_success=False, expect_fail_tohost=16)
        self.assertEqual(rec["status"], "pass")

    def test_max_lid_floor_assert(self):
        # max_lid >= 1 required (m5 viability); 0 fails the gt check.
        rec = self._run(_sim(), expect_fields=C2.C2_FIELDS_PO,
                        expect_gt={"max_lid": 0}, expect_success=True)
        self.assertEqual(rec["status"], "pass")
        nat = C2.parse_native(NATIVE_LINE); nat["max_lid"] = 0
        sim = _sim(); sim["native"] = nat
        rec = self._run(sim, expect_fields=C2.C2_FIELDS_PO,
                        expect_gt={"max_lid": 0}, expect_success=True)
        self.assertEqual(rec["status"], "fail")


SBA_NATIVE_LINE = ("STORAMIC_C2_NATIVE p0_aw=10 p0_ar=18 p1_aw=1 p1_ar=1 "
                   "p2_aw=0 p2_ar=0 m0_aw=10 m0_ar=18 m1_aw=1 m1_ar=1 "
                   "m2_aw=0 m2_ar=0 done_w=11 done_r=19 src_ok_aw=9 "
                   "src_ok_ar=14 err_resp=4 max_outstanding=2 beats0=135 "
                   "beats1=2 beats2=0 max_lid=1 pending=0 violations=0")
SBA_LINE = ("STORAMIC_SBA_PROBE reads=1 writes=1 "
            "rd_sberror=0 wr_sberror=0")


def _sba_sim():
    sim = _sim()
    sim["native"] = C2.parse_native(SBA_NATIVE_LINE)
    sim["native_line"] = SBA_NATIVE_LINE
    sim["sba_probe"] = C2.parse_sba(SBA_LINE)
    return sim


class SbaCaseTests(unittest.TestCase):
    """c2-po-sba / c2-qf-sba: port-1 DMI SBA traffic scored by the monitor."""

    def _run(self, sim, **kw):
        fd, name = tempfile.mkstemp(suffix=".elf")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(b"x")
            ctx = _Ctx(sim)
            rec = C2._case(ctx, "sba", "t", Path(name), **kw)
            return rec, ctx
        finally:
            Path(name).unlink(missing_ok=True)

    def test_sba_fields_and_probe_pass(self):
        rec, ctx = self._run(
            _sba_sim(), expect_fields=C2.C2_SBA_PO, expect_success=True,
            plusargs=("+storamic_sba_probe",), expect_sba=C2.SBA_EXPECT)
        self.assertEqual(rec["status"], "pass")
        self.assertEqual(ctx.plusargs_seen, [("+storamic_sba_probe",)])

    def test_sba_probe_off_src_ok_zero(self):
        sim = _sba_sim()
        sim["native"]["src_ok_aw"] = 0
        sim["native"]["src_ok_ar"] = 0
        rec, _ = self._run(
            sim, expect_fields=C2.C2_SBA_QF, expect_success=True,
            plusargs=("+storamic_sba_probe",), expect_sba=C2.SBA_EXPECT)
        self.assertEqual(rec["status"], "pass")

    def test_sba_missing_probe_line_incomplete(self):
        # No STORAMIC_SBA_PROBE line on an otherwise-clean run means the DTM
        # probe never fired — no port-1 verdict evidence -> incomplete.
        sim = _sba_sim()
        sim["sba_probe"] = None
        rec, _ = self._run(
            sim, expect_fields=C2.C2_SBA_PO, expect_success=True,
            plusargs=("+storamic_sba_probe",), expect_sba=C2.SBA_EXPECT)
        self.assertEqual(rec["status"], "incomplete")
        self.assertFalse(rec["pass"])

    def test_sba_probe_fired_but_wrong_counts_fails(self):
        # A fired probe with wrong port-1 counts is a real deviation -> fail.
        sim = _sba_sim()
        sim["native"] = C2.parse_native(NATIVE_LINE)
        sim["native_line"] = NATIVE_LINE
        rec, _ = self._run(
            sim, expect_fields=C2.C2_SBA_PO, expect_success=True,
            plusargs=("+storamic_sba_probe",), expect_sba=C2.SBA_EXPECT)
        self.assertEqual(rec["status"], "fail")

    def test_sba_wrong_sberror_fails(self):
        sim = _sba_sim()
        sim["sba_probe"] = dict(sim["sba_probe"], rd_sberror=3)
        rec, _ = self._run(
            sim, expect_fields=C2.C2_SBA_PO, expect_success=True,
            plusargs=("+storamic_sba_probe",), expect_sba=C2.SBA_EXPECT)
        self.assertEqual(rec["status"], "fail")

    def test_sba_port1_counts_required(self):
        # A run with no port-1 traffic must not pass the SBA case.
        sim = _sba_sim()
        nat = C2.parse_native(NATIVE_LINE)
        sim["native"] = nat
        sim["native_line"] = NATIVE_LINE
        rec, _ = self._run(
            sim, expect_fields=C2.C2_SBA_PO, expect_success=True,
            plusargs=("+storamic_sba_probe",), expect_sba=C2.SBA_EXPECT)
        self.assertEqual(rec["status"], "fail")


class MutantStatusTests(unittest.TestCase):
    """A mutant that runs clean proves the guarded check is dead -> fail."""

    def test_mutant_clean_pass_is_fail(self):
        # good=False (judge saw no expected failure) + clean sim -> fail.
        self.assertEqual(C2._mutant_status(False, _sim()), "fail")

    def test_mutant_failed_as_expected_is_pass(self):
        self.assertEqual(C2._mutant_status(True, _sim(fatal=True)), "pass")

    def test_mutant_inconclusive_is_incomplete(self):
        # no report line, no success -> cannot confirm -> incomplete.
        sim = _sim(native=False, topo=False, success=False)
        self.assertEqual(C2._mutant_status(False, sim), "incomplete")

    def test_mutant_violations_not_clean_pass(self):
        nat = C2.parse_native(NATIVE_LINE); nat["violations"] = 3
        sim = _sim(); sim["native"] = nat
        # violations>0 means not a clean pass -> not 'fail' via clean_pass.
        self.assertEqual(C2._mutant_status(False, sim), "incomplete")


@unittest.skipUnless(HARNESS.is_file(), "harness not in closure")
class MutantPatchTests(unittest.TestCase):
    """Each mutant patch must actually rewrite the real harness source."""

    def setUp(self):
        self.orig = HARNESS.read_text()

    def _patched(self, fn):
        out = fn(self.orig)
        self.assertIsNotNone(out, "patch pattern missed")
        self.assertNotEqual(out, self.orig, "patch produced no change")
        return out

    def test_m1_trustedmaster(self):
        out = self._patched(C2._mut_patch_m1)
        self.assertIn(".TrustedMaster(1)", out)
        self.assertNotIn(".TrustedMaster(0)", out)

    def test_m2_route_localidwidth_only(self):
        out = self._patched(C2._mut_patch_m2)
        # route gets +1; the monitor's identical param must stay untouched.
        self.assertIn(".LocalIdWidth(ariane_axi_soc::IdWidth + 1)", out)
        mon = out.split("g6lc_storamic_c2_monitor", 1)[1]
        self.assertIn(".LocalIdWidth(ariane_axi_soc::IdWidth)", mon)

    def test_m3_rule_range(self):
        out = self._patched(C2._mut_patch_m3)
        self.assertIn("(ariane_soc::StoramicLength >> 1)", out)

    def test_m4_tapswap(self):
        out = self._patched(C2._mut_patch_m4)
        self.assertIn("slave[(gi == 0) ? 1 : ((gi == 1) ? 0 : gi)]", out)
        # request tap must remain unswapped.
        self.assertIn("AXI_ASSIGN_TO_REQ (c2_slv_req[gi],  slave[gi])", out)

    def test_m5_monitor_localidwidth_only(self):
        out = self._patched(lambda t: C2._mut_patch_m5(t, 2))
        self.assertIn(".LocalIdWidth(2)", out)
        # Only the route's identical param keeps the symbolic form (1 left);
        # the monitor's was rewritten to the literal mutant width.
        self.assertEqual(out.count(".LocalIdWidth(ariane_axi_soc::IdWidth)"),
                         1)
        rte = out.split("g6lc_storamic_checkpoint_route", 1)[1]
        self.assertIn(".LocalIdWidth(ariane_axi_soc::IdWidth)", rte)


class M5WidthTests(unittest.TestCase):
    """m5 mutant width = floor(log2(max_lid)); degenerate cases -> None."""

    def test_width_derivation(self):
        self.assertIsNone(C2.m5_width_for(0))
        self.assertIsNone(C2.m5_width_for(None))
        self.assertEqual(C2.m5_width_for(1), 0)
        self.assertEqual(C2.m5_width_for(7), 2)
        self.assertEqual(C2.m5_width_for(8), 3)
        self.assertEqual(C2.m5_width_for(15), 3)
        # width >= real LocalIdWidth(4) would be equivalent -> None.
        self.assertIsNone(C2.m5_width_for(16))
        self.assertIsNone(C2.m5_width_for(31))

    def _judge_sim(self, fatal=True, fatal_msg="", success=False,
                   native=True):
        sim = _sim(native=native, topo=True, success=success, fatal=fatal)
        sim["fatal_msg"] = fatal_msg
        sim["tail"] = ""
        return sim

    def test_m5_judge_accepts_decode_violation(self):
        sim = self._judge_sim(
            fatal_msg="%Error: STORAMIC_C2_VIOLATION aw_bad_prefix p=0")
        good, note = C2._judge_m5(sim)
        self.assertTrue(good)
        self.assertIn("aw_bad_prefix", note)

    def test_m5_judge_rejects_elaboration_fatal(self):
        # A parameter/elaboration %Error tripping before traffic is NOT an
        # acceptable kill even though fatal=True.
        sim = self._judge_sim(
            fatal_msg="%Error: parameter IdWidthSlave mismatch "
                      "LocalIdWidth=2 IdWidthSlave=6")
        good, note = C2._judge_m5(sim)
        self.assertFalse(good)

    def test_m5_judge_no_fatal_not_accepted(self):
        sim = self._judge_sim(fatal=False, success=True)
        good, _ = C2._judge_m5(sim)
        self.assertFalse(good)


class WideStageTests(unittest.TestCase):
    """native-c2-wide: latency modes, alternate targets, port-2 oracle."""

    VIRTIO_SNIPPET = ("        if ({1'b0, saddr_q[i]} < {1'b0, dma_base_i} ||\n"
                      "            {1'b0, saddr_q[i]} + 65'(slen_q[i]) > "
                      "win_end) win_ok = 1'b0;\n")

    def test_m7_patch_neuters_win_ok(self):
        out = C2._mut_patch_m7(self.VIRTIO_SNIPPET)
        self.assertIsNotNone(out)
        self.assertIn("win_ok = 1'b1;", out)
        self.assertNotIn("win_ok = 1'b0;", out)
        # Absent needle -> None (no silent no-op).
        self.assertIsNone(C2._mut_patch_m7("module x; endmodule"))

    def _m7_sim(self, m2=0, fatal=False, fatal_msg="", tohost="28",
                src_ok=0, viol=0):
        nat = {"m2_aw": m2, "m2_ar": 0, "src_ok_aw": src_ok,
               "src_ok_ar": src_ok, "violations": viol, "pending": 0}
        return {"rc": 0, "success": False, "fatal": fatal,
                "fatal_msg": fatal_msg, "native": nat, "tail": "",
                "fail_tohost": tohost}

    def test_m7_judge_port2_dma_kills(self):
        good, note = C2._judge_m7(self._m7_sim(m2=3))
        self.assertTrue(good)
        self.assertIn("m2=3", note)

    def test_m7_judge_fatal_kills(self):
        good, _ = C2._judge_m7(self._m7_sim(
            fatal=True, fatal_msg="STORAMIC_C2_VIOLATION aw_payload"))
        self.assertTrue(good)

    def test_m7_judge_survived_is_fail(self):
        # Still rejected, no port-2 DMA, no fatal -> mutant did not take.
        good, note = C2._judge_m7(self._m7_sim(m2=0, tohost="28"))
        self.assertFalse(good)
        self.assertIn("survived", note)

    def test_m7_judge_authorized_is_fail(self):
        good, _ = C2._judge_m7(self._m7_sim(
            fatal=True, fatal_msg="authorized asserted p=2"))
        self.assertFalse(good)

    def test_m7_judge_dirty_src_ok_fails(self):
        good, _ = C2._judge_m7(self._m7_sim(m2=2, src_ok=4))
        self.assertFalse(good)

    RING_SNIPPET = (
        "  function automatic logic in_window(input logic [63:0] a,\n"
        "                                     input logic [64:0] n,\n"
        "                                     input logic [63:0] base,\n"
        "                                     input logic [64:0] wend);\n"
        "    logic [64:0] e;\n"
        "    e = {1'b0, a} + n;\n"
        "    return ({1'b0, a} >= {1'b0, base}) && (e <= wend);\n"
        "  endfunction\n")

    def test_m7_ring_patch_neuters_in_window(self):
        out = C2._mut_patch_m7_ring(self.RING_SNIPPET)
        self.assertIsNotNone(out)
        self.assertIn("return 1'b1;", out)
        self.assertNotIn("(e <= wend)", out)
        # Absent needle -> None (no silent no-op).
        self.assertIsNone(C2._mut_patch_m7_ring("module x; endmodule"))

    def test_prim_aw_stage_and_evidence_exist(self):
        # The focused prim-aw leaf + shared evidence helper must be wired so
        # the AW power-cut trace can be captured ahead of the firmware guard.
        self.assertTrue(callable(getattr(C2, "run_prim_aw", None)))
        self.assertTrue(callable(getattr(C2, "_prim_evidence", None)))

    def test_latency_modes_values(self):
        # Spot-check the 10-bit channel-cut masks against axi_pkg
        # (Demux*=1<<9..5, Mux*=1<<4..0).
        vals = {s: v for s, _m, v in C2.XBAR_LATENCY_MODES}
        self.assertEqual(vals["cut_slv_ax"], 576)    # DemuxAw|DemuxAr
        self.assertEqual(vals["cut_mst_ax"], 18)     # MuxAw|MuxAr
        self.assertEqual(vals["cut_all_ports"], 1023)
        members = {m for _s, m, _v in C2.XBAR_LATENCY_MODES}
        self.assertEqual(members, {"CUT_SLV_AX", "CUT_MST_AX", "CUT_ALL_AX",
                                   "CUT_SLV_PORTS", "CUT_MST_PORTS",
                                   "CUT_ALL_PORTS"})

    def test_latency_topology_string(self):
        for slug, _m, val in C2.XBAR_LATENCY_MODES:
            topo = C2.TOPO_EXPECT.replace("latency=0", f"latency={val}")
            self.assertIn(f"latency={val}", topo)
            self.assertNotIn("latency=0", topo)

    def test_wide_targets_use_makefile_names(self):
        # target= must NOT carry the _config_pkg suffix (Makefile appends it).
        for slug, pkg, _note in C2.WIDE_TARGETS:
            self.assertFalse(pkg.endswith("_config_pkg"), pkg)
            self.assertTrue(pkg.startswith("g6lc64_"), pkg)

    def test_a2_probeon_refused(self):
        sim = _sim(native=False, topo=False, success=False, fatal=True)
        sim["fatal_msg"] = "%Error: STORAMIC_C2_ORIGIN_PROBE_UNSUPPORTED"
        sim["tail"] = ""
        ctx = _Ctx(sim)
        rec = C2._a2_probeon(ctx, "smt2", "smt2-po", Path("x.elf"))
        self.assertEqual(rec["outcome"], "unsupported-refused")
        self.assertEqual(rec["status"], "pass")

    def test_a2_probeon_refused_no_profile_still_passes(self):
        # Regression: the t=0 UNSUPPORTED $fatal precedes the PROFILE
        # $display, so a refused probe-on emits no profile line. With an
        # expect_profile fingerprint set that must NOT be scored
        # 'incomplete' -- the refusal is the required negative and the
        # sibling probe-off PROFILE proves target identity.
        sim = _sim(native=False, topo=False, success=False, fatal=True)
        sim["fatal_msg"] = "%Error: STORAMIC_C2_ORIGIN_PROBE_UNSUPPORTED"
        sim["tail"] = ""
        ctx = _Ctx(sim)
        rec = C2._a2_probeon(ctx, "ooo", "ooo-po", Path("x.elf"),
                             expect_profile=C2.PROFILE_FP["ooo"])
        self.assertEqual(rec["outcome"], "unsupported-refused")
        self.assertEqual(rec["status"], "pass")
        self.assertTrue(rec["pass"])

    def test_a2_probeon_ran_profile_mismatch_incomplete(self):
        # The fingerprint still gates the ran path: a supported target that
        # ran but elaborated the wrong config is incomplete, not pass.
        sim = _sim(native=True, topo=True, success=True, fatal=False)
        sim["profile"] = {"line": "STORAMIC_C2_PROFILE ooo=0 harts=1 cores=1",
                          "ooo": 0, "harts": 1, "cores": 1}
        ctx = _Ctx(sim)
        rec = C2._a2_probeon(ctx, "ooo", "ooo-po", Path("x.elf"),
                             expect_profile=C2.PROFILE_FP["ooo"])
        self.assertEqual(rec["outcome"], "supported-ran")
        self.assertEqual(rec["status"], "incomplete")

    def test_a2_probeon_ran_supported(self):
        sim = _sim(native=True, topo=True, success=True, fatal=False)
        ctx = _Ctx(sim)
        rec = C2._a2_probeon(ctx, "srvmath", "srvmath-po", Path("x.elf"))
        self.assertEqual(rec["outcome"], "supported-ran")
        self.assertEqual(rec["status"], "pass")

    def test_a2_probeon_inconclusive(self):
        sim = _sim(native=False, topo=False, success=False, fatal=False)
        ctx = _Ctx(sim)
        rec = C2._a2_probeon(ctx, "smt2", "smt2-po", Path("x.elf"))
        self.assertEqual(rec["outcome"], "inconclusive")
        self.assertEqual(rec["status"], "incomplete")

    def test_wide_entries_exist(self):
        self.assertTrue(callable(C2.execute_wide))
        self.assertTrue(callable(C2.run_wide))


class DmaWinTests(unittest.TestCase):
    def test_dma_win_kind_codes(self):
        # enum order: ...OK=27 REJ=28 NEEDS_RESET=29 STALL=30; status/istat
        # ride in bits 8+, so only the low byte selects the kind.
        self.assertEqual(C2.dma_win_kind("28"), ("rej", 28))
        self.assertEqual(C2.dma_win_kind("29")[0], "needs_reset")
        self.assertEqual(C2.dma_win_kind(str(29 | (0x0f << 8)))[0],
                         "needs_reset")
        self.assertEqual(C2.dma_win_kind(str(30 | (0x0f << 8) |
                                              (0x03 << 28)))[0], "stall")
        self.assertEqual(C2.dma_win_kind("27"), ("ok", 27))
        self.assertEqual(C2.dma_win_kind("22")[0], "other")   # FAIL_TIMEOUT
        self.assertEqual(C2.dma_win_kind(None)[0], "other")
        self.assertEqual(C2.dma_win_kind("garbage")[0], "other")

    def test_dma_win_pred_accepts_defined_rejections(self):
        # rej / needs_reset / stall are defined device outcomes; 'ok'
        # (wrongly accepted) and 'other' (timeout/crash) are not.
        self.assertTrue(C2._dma_win_pred("28"))
        self.assertTrue(C2._dma_win_pred(str(29 | (1 << 8))))
        self.assertTrue(C2._dma_win_pred(str(30 | (2 << 8))))
        self.assertFalse(C2._dma_win_pred("27"))
        self.assertFalse(C2._dma_win_pred("22"))
        self.assertFalse(C2._dma_win_pred(None))

    def test_case_callable_fail_tohost(self):
        fd, name = tempfile.mkstemp(suffix=".elf")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(b"x")
            elf = Path(name)
            # A defined rejection tohost passes the callable check.
            rec = C2._case(_Ctx(_sim(success=False, fail_tohost="28")),
                           "d", "t", elf,
                           expect_success=False,
                           expect_fail_tohost=C2._dma_win_pred,
                           require_topo=False)
            self.assertTrue(rec["pass"], rec)
            # FAIL_TIMEOUT (22) is not a defined outcome -> fail.
            rec2 = C2._case(_Ctx(_sim(success=False, fail_tohost="22")),
                            "d", "t", elf,
                            expect_success=False,
                            expect_fail_tohost=C2._dma_win_pred,
                            require_topo=False)
            self.assertFalse(rec2["pass"])
        finally:
            elf.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
