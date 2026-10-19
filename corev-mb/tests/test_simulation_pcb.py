# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Tests for simulation.py (deck, judge, runner statuses) and pcb.py (gate,
# layout contract, discovery). ngspice / kicad-cli runs are skipped when the
# tools are absent; everything that does not need them runs always.

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "lib"
sys.path.insert(0, str(LIB))

import pcb  # noqa: E402
import simulation  # noqa: E402
from test_circuit import fixture  # noqa: E402


def scenario_divider(expect_min: float, expect_max: float) -> dict:
    return {
        "schema_version": 1,
        "id": "p12v_op",
        "description": "12 V entry into a 100 Ω load; the rail must read 12 V",
        "ground": "GND",
        "models": {"c0": {"kind": "R", "value": "100"}},
        "sources": [{"name": "IN", "plus": "P12V", "minus": "GND", "value": 12}],
        "analysis": {"type": "op"},
        "measurements": [{"name": "vrail", "expr": "v(P12V)", "type": "op", "min": expect_min, "max": expect_max}],
    }


class DeckTests(unittest.TestCase):
    def test_deck_maps_pins_to_nets_and_ground_to_zero(self) -> None:
        deck = simulation.deck_from_circuit(fixture(), scenario_divider(11.9, 12.1))
        self.assertEqual(deck.missing, [])
        self.assertEqual(deck.elements, 2)
        self.assertIn("RC1 P12V 0 100", deck.text)
        self.assertIn("VIN P12V 0 DC 12", deck.text)
        self.assertIn("op", deck.text.splitlines())
        self.assertIn("print __vrail", deck.text)
        self.assertTrue(deck.text.rstrip().endswith(".end"))
        self.assertEqual(deck.nodes["GND"], "0")

    def test_deck_reports_missing_inputs_instead_of_guessing(self) -> None:
        sc = scenario_divider(0, 1)
        sc["models"]["ghost"] = {"kind": "R", "value": "1k"}
        sc["models"]["slot0"] = {"kind": "R", "value": "1k"}  # 5 pins, no explicit pair -> first two
        sc["models"]["c0"] = {"kind": "Q", "value": "x"}
        deck = simulation.deck_from_circuit(fixture(), sc)
        self.assertTrue(any("ghost" in m for m in deck.missing))
        self.assertTrue(any("unsupported model kind" in m for m in deck.missing))
        # slot0.1 (A1) is on no net: flagged, not silently grounded.
        self.assertTrue(any("slot0.1 is on no net" in m for m in deck.missing))

    def test_judge_classifies_pass_fail_incomplete(self) -> None:
        sc = scenario_divider(11.9, 12.1)
        status, _, rows = simulation.judge(sc, {"vrail": 12.0}, "ok")
        self.assertEqual(status, "pass")
        self.assertTrue(rows["vrail"]["ok"])
        status, reason, _ = simulation.judge(sc, {"vrail": 3.3}, "ok")
        self.assertEqual(status, "fail")
        self.assertIn("vrail", reason)
        status, _, _ = simulation.judge(sc, {}, "ok")
        self.assertEqual(status, "incomplete")
        status, reason, _ = simulation.judge(sc, {"vrail": 12.0}, "Warning: singular matrix: check nodes")
        self.assertEqual(status, "incomplete")
        self.assertIn("singular", reason)

    def test_measurement_parser_reads_ngspice_prints(self) -> None:
        log = "Circuit: * mbgen\n__vrail = 1.200000e+01\n__other = -3.3\nNo. of Data Rows : 1\n"
        self.assertEqual(simulation.parse_measurements(log), {"vrail": 12.0, "other": -3.3})

    def test_runner_without_ngspice_is_incomplete_and_revision_bound(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            res = simulation.run_scenario(fixture(), scenario_divider(11.9, 12.1), Path(d), ngspice="definitely-not-a-binary-xyz")
            if simulation.find_ngspice() is not None:
                self.skipTest("ngspice present; covered by the live test")
            self.assertEqual(res.status, "incomplete")
            self.assertIn("ngspice not found", res.reason)
            self.assertEqual(len(res.deck_sha256), 64)
            self.assertEqual(len(res.circuit_sha256), 64)
            self.assertTrue((Path(d) / "p12v_op.cir").exists(), "the deck is written even when the tool is missing")

    def test_scenario_schema_is_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "s.json"
            p.write_text('{"schema_version": 1, "id": "x"}')
            with self.assertRaises(ValueError):
                simulation.load_scenario(p)

    @unittest.skipUnless(simulation.find_ngspice(), "ngspice not installed")
    def test_live_known_good_passes_and_wrong_expectation_fails(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            good = simulation.run_scenario(fixture(), scenario_divider(11.9, 12.1), Path(d))
            self.assertEqual(good.status, "pass", good.as_dict())
            self.assertNotEqual(good.simulator, "")
            bad = simulation.run_scenario(fixture(), scenario_divider(3.2, 3.4), Path(d))
            self.assertEqual(bad.status, "fail", bad.as_dict())


class PcbTests(unittest.TestCase):
    def test_discovery_never_raises(self) -> None:
        found = pcb.find_kicad_cli("not-a-real-kicad-cli-xyz")
        self.assertTrue(found is None or isinstance(found, str))

    def test_layout_contract_blocks_unresolved_footprints(self) -> None:
        c = fixture()
        layout = {
            "outline": {"id": "mini-itx", "w_um": 170000, "d_um": 170000},
            "placements": [
                {"id": "slot0", "footprint": ""},
                {"id": "c0", "footprint": "Capacitor_SMD:C_0402_1005Metric"},
            ],
        }
        rep = pcb.layout_contract(c, layout)
        self.assertFalse(rep["ok"])
        self.assertEqual(rep["unresolved_footprints"], ["slot0"])
        self.assertEqual(rep["unplaced"], [])
        layout["placements"][0]["footprint"] = "mbgen:unresolved"
        self.assertEqual(pcb.layout_contract(c, layout)["unresolved_footprints"], ["slot0"])
        c["components"][0]["dnp"] = True
        self.assertTrue(pcb.layout_contract(c, layout)["ok"], "DNP parts do not need a footprint")

    def test_gate_requires_every_input_and_all_green(self) -> None:
        gate = pcb.manufacturing_gate(None, None, None, None, None, None)
        self.assertFalse(gate["ready"])
        self.assertEqual(len(gate["blockers"]), 6)
        erc = {"ok": True, "errors": 0}
        par = {"ok": True}
        layout = {"ok": True, "unplaced": [], "unresolved_footprints": []}
        drc = {"ok": True, "violations": 0, "unconnected": 0}
        soc = {"id": "g6lc-soc-pkg", "declared_status": "approved", "approved": True, "unresolved": []}
        self.assertTrue(pcb.manufacturing_gate(erc, par, layout, drc, par, soc)["ready"])
        self.assertFalse(pcb.manufacturing_gate({"ok": False, "errors": 2}, par, layout, drc, par, soc)["ready"])
        self.assertFalse(pcb.manufacturing_gate(erc, par, {"ok": False, "unplaced": [], "unresolved_footprints": ["slot0"]}, drc, par, soc)["ready"])
        self.assertFalse(pcb.manufacturing_gate(erc, par, layout, {"ok": False, "violations": 3, "unconnected": 0}, par, soc)["ready"])
        self.assertFalse(pcb.manufacturing_gate(erc, par, layout, drc, {"ok": False}, soc)["ready"])
        # The draft SoC contract blocks on its own, even with everything else green.
        draft = {"id": "g6lc-soc-pkg", "declared_status": "draft", "approved": False, "unresolved": ["package.type"]}
        gate = pcb.manufacturing_gate(erc, par, layout, drc, par, draft)
        self.assertFalse(gate["ready"])
        self.assertIn("1 unresolved field(s)", gate["blockers"][0])
        self.assertFalse(pcb.manufacturing_gate(erc, par, layout, drc, par)["ready"], "a missing report is a blocker")

    def test_pcb_parity_reuses_the_readback_rules(self) -> None:
        text = """(export (components (comp (ref "J1")) (comp (ref "C1")))
          (nets (net (name "P12V") (node (ref "J1") (pin "2")) (node (ref "J1") (pin "3")) (node (ref "C1") (pin "1")))
                (net (name "GND") (node (ref "J1") (pin "4")) (node (ref "C1") (pin "2")))))"""
        rep = pcb.pcb_parity(fixture(), text)
        self.assertTrue(rep["ok"])
        self.assertEqual(rep["source"], "kicad-pcb")
        self.assertEqual(rep["nets_in_pcb"], 2)


if __name__ == "__main__":
    unittest.main()
