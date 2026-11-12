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


if __name__ == "__main__":
    unittest.main()
