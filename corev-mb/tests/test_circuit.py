# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Tests for the lossless SKiDL compiler (corev-mb/lib/circuit.py).
#
#   python -m unittest discover -s corev-mb/tests -p "test_*.py"
#
# The fixture mirrors the mbgen circuit.json schema (schema_version 1): a
# distributor-frozen slot with contract pins, a two-terminal capacitor, nets
# from contract + recipe, one explicit no-connect. A deliberately wrong
# circuit (two drivers on one net) must fail, and the netlist readback must
# detect tampering.

from __future__ import annotations

import copy
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parents[1] / "lib"
sys.path.insert(0, str(LIB))

import circuit as circuit_mod  # noqa: E402

try:
    import skidl  # noqa: E402

    HAVE_SKIDL = True
except Exception:  # noqa: BLE001
    HAVE_SKIDL = False


def pin(part: str, num: str, name: str, kind: str, domain: str, index: int) -> dict:
    return {
        "id": f"{part}.{num}",
        "part": part,
        "index": index,
        "name": name,
        "kind": kind,
        "domain": domain,
        "side": "Through",
        "dx_um": None,
        "dy_um": None,
    }


def fixture() -> dict:
    pins = [
        pin("slot0", "1", "A1", "Signal", "A1", 0),
        pin("slot0", "2", "A2", "Power", "P12V", 1),
        pin("slot0", "3", "B1", "Power", "P12V", 2),
        pin("slot0", "4", "B4", "Ground", "GND", 3),
        pin("slot0", "5", "A5", "Signal", "A5", 4),
        pin("c0", "1", "1", "Passive", "", 0),
        pin("c0", "2", "2", "Passive", "", 1),
    ]
    return {
        "schema_version": 1,
        "template_id": "mini-itx",
        "package_id": "cv64a6_imafdc_sv39",
        "components": [
            {
                "id": "slot0",
                "refdes": "J1",
                "role": "pcie_slot",
                "part": {"lcsc": "C2834553"},
                "dnp": False,
                "side": "Top",
                "yaw_q": 0,
                "x_um": 10000,
                "y_um": 20000,
                "pin_spec": "names_only",
                "pin_count": 5,
            },
            {
                "id": "c0",
                "refdes": "C1",
                "role": "decap",
                "value": "100n",
                "dnp": False,
                "side": "Top",
                "yaw_q": 0,
                "x_um": 12000,
                "y_um": 20000,
                "pin_spec": "two_terminal",
                "pin_count": 2,
                "owner_block": "slot0.decap_per_rail",
            },
        ],
        "pins": pins,
        "nets": [
            {"id": "P12V", "class": "Power", "pins": ["slot0.2", "slot0.3", "c0.1"], "origins": ["contract", "recipe"]},
            {"id": "GND", "class": "Ground", "pins": ["slot0.4", "c0.2"], "origins": ["contract", "recipe"]},
        ],
        "no_connects": ["slot0.5"],
        "obligations": [{"pin": "slot0.2", "reason": "P12V contact"}],
        "diagnostics": [
            {
                "rule": "W-NET-NO-SOURCE",
                "severity": "warning",
                "stage": "resolve",
                "net": "P12V",
                "message": "rail P12V has consumers but no regulator or supply connector on it",
            }
        ],
    }


class PureTests(unittest.TestCase):
    def test_pin_ids_split_on_the_last_dot(self) -> None:
        self.assertEqual(circuit_mod.pin_number("slot0.83"), "83")
        self.assertEqual(circuit_mod.pin_part("slot0_c_p12v_0.1"), "slot0_c_p12v_0")

    def test_sexpr_parser_reads_kicad_nets(self) -> None:
        text = """(export (version "D")
          (components (comp (ref "J1") (value "pcie_slot") (footprint "mbgen:unresolved")))
          (nets (net (code 1) (name "P12V") (node (ref "J1") (pin "2") (pintype "POWER-IN"))
                     (node (ref "C1") (pin "1")))
                (net (code 2) (name "GND") (node (ref "J1") (pin "4")))))"""
        nets = circuit_mod.netlist_nets(text)
        self.assertEqual(nets["P12V"], {("J1", "2"), ("C1", "1")})
        self.assertEqual(nets["GND"], {("J1", "4")})
        comps = circuit_mod.netlist_components(text)
        self.assertEqual(comps["J1"]["footprint"], "mbgen:unresolved")

    def test_parity_detects_missing_and_mismatched_nets(self) -> None:
        c = fixture()
        good = """(export (components (comp (ref "J1")) (comp (ref "C1")))
          (nets (net (name "P12V") (node (ref "J1") (pin "2")) (node (ref "J1") (pin "3")) (node (ref "C1") (pin "1")))
                (net (name "GND") (node (ref "J1") (pin "4")) (node (ref "C1") (pin "2")))))"""
        self.assertTrue(circuit_mod.parity(c, good)["ok"])
        tampered = good.replace('(node (ref "C1") (pin "2"))', "")
        p = circuit_mod.parity(c, tampered)
        self.assertFalse(p["ok"])
        self.assertEqual(p["mismatched_nets"][0]["net"], "GND")
        self.assertEqual(p["mismatched_nets"][0]["missing_nodes"], ["C1.2"])
        dropped = good.replace('(net (name "GND") (node (ref "J1") (pin "4")) (node (ref "C1") (pin "2")))', "")
        self.assertEqual(circuit_mod.parity(c, dropped)["missing_nets"], ["GND"])

    def test_bom_rows_carry_identity_and_unresolved_footprints(self) -> None:
        rows = circuit_mod.bom_rows(fixture())
        self.assertEqual(rows[0]["refdes"], "J1")
        self.assertEqual(rows[0]["lcsc"], "C2834553")
        self.assertEqual(rows[0]["footprint"], circuit_mod.UNRESOLVED_FOOTPRINT)
        self.assertEqual(rows[1]["owner_block"], "slot0.decap_per_rail")

    def test_schema_version_is_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "circuit.json"
            p.write_text(json.dumps({"schema_version": 99}))
            with self.assertRaises(ValueError):
                circuit_mod.load_circuit(p)


@unittest.skipUnless(HAVE_SKIDL, "skidl not installed")
class SkidlTests(unittest.TestCase):
    def setUp(self) -> None:
        skidl.reset()

    def test_good_circuit_compiles_with_counted_erc_and_round_trips(self) -> None:
        c = fixture()
        parts = circuit_mod.build_from_circuit(c)
        self.assertEqual(set(parts), {"slot0", "c0"})
        self.assertEqual(parts["slot0"].ref, "J1")
        self.assertEqual(parts["c0"].value, "100n")
        self.assertEqual(parts["c0"].fields["mbgen_block"], "slot0.decap_per_rail")
        report = circuit_mod.run_structured_erc(c)
        self.assertEqual(report.counter_source, "erc_logger")
        self.assertTrue(report.ok, report.as_dict())
        rules = {i.rule for i in report.issues}
        # mbgen's own diagnostic rides along; skidl flags the undriven rails
        # (there is no regulator) and the one unknown-function open contact.
        self.assertIn("W-NET-NO-SOURCE", rules)
        self.assertIn("W-SKIDL-NET-NO-DRIVE", rules)
        self.assertIn("W-PIN-OPEN-UNKNOWN-FUNCTION", rules)
        self.assertEqual(report.aggregates["unknown_function_open_pins"], {"slot0": 1})
        # The explicit no-connect is not reported as open.
        self.assertFalse(any(i.pin == "slot0.5" for i in report.issues))
        drives = [i for i in report.issues if i.rule == "W-SKIDL-NET-NO-DRIVE"]
        self.assertEqual(sorted(d.net for d in drives), ["GND", "P12V"], "one finding per undriven rail, not per sink pin")
        self.assertIn("2 power-in contact(s)", next(d for d in drives if d.net == "P12V").message)
        with tempfile.TemporaryDirectory() as d:
            text = circuit_mod.write_netlist(Path(d) / "x.net")
        nets = circuit_mod.netlist_nets(text)
        self.assertEqual(nets["P12V"], {("J1", "2"), ("J1", "3"), ("C1", "1")})
        par = circuit_mod.parity(c, text)
        self.assertTrue(par["ok"], par)
        self.assertEqual(par["unresolved_footprints"], ["C1", "J1"])

    def test_two_drivers_on_one_net_is_an_error_not_a_pass(self) -> None:
        c = fixture()
        c["pins"].append(pin("u1", "1", "OUT", "Signal", "OUT", 0))
        c["pins"].append(pin("u2", "1", "OUT", "Signal", "OUT", 0))
        for cid, ref in (("u1", "U1"), ("u2", "U2")):
            c["components"].append(
                {"id": cid, "refdes": ref, "role": "driver", "dnp": False, "side": "Top", "yaw_q": 0, "x_um": 0, "y_um": 0, "pin_spec": "names_only", "pin_count": 1}
            )
        c["nets"].append({"id": "CLASH", "class": "Signal", "pins": ["u1.1", "u2.1"], "origins": ["explicit"]})
        parts = circuit_mod.build_from_circuit(c)
        parts["u1"][1].func = skidl.Pin.types.OUTPUT
        parts["u2"][1].func = skidl.Pin.types.OUTPUT
        report = circuit_mod.run_structured_erc(c)
        self.assertFalse(report.ok)
        self.assertGreaterEqual(report.errors, 1)
        clash = [i for i in report.issues if i.severity == "error" and i.source == "skidl"]
        self.assertTrue(clash, report.as_dict())
        self.assertEqual(clash[0].net, "CLASH")
        self.assertIn(clash[0].part, {"u1", "u2"})

    def test_mbgen_errors_fail_the_report_even_if_skidl_is_quiet(self) -> None:
        c = fixture()
        c["diagnostics"].append(
            {"rule": "E-DOMAIN-CLASH", "severity": "error", "stage": "resolve", "pin": "slot0.3", "net": "P3V3", "message": "x"}
        )
        circuit_mod.build_from_circuit(c)
        report = circuit_mod.run_structured_erc(c)
        self.assertFalse(report.ok)
        self.assertEqual(report.aggregates["mbgen_errors"], 1)

    def test_unknown_pin_in_a_net_is_refused(self) -> None:
        c = fixture()
        c["nets"][0]["pins"].append("ghost.7")
        with self.assertRaises(KeyError):
            circuit_mod.build_from_circuit(c)

    def test_real_bundle_if_present(self) -> None:
        bundle = Path(__file__).resolve().parents[2] / "mbgen" / "target" / "tmp" / "bundle" / "circuit.json"
        if not bundle.exists():
            self.skipTest("no compiled bundle at mbgen/target/tmp/bundle")
        c = circuit_mod.load_circuit(bundle)
        parts = circuit_mod.build_from_circuit(c)
        self.assertEqual(len(parts), len(c["components"]))
        report = circuit_mod.run_structured_erc(c)
        self.assertTrue(report.ok, [i.as_dict() for i in report.issues if i.severity == "error"])
        with tempfile.TemporaryDirectory() as d:
            text = circuit_mod.write_netlist(Path(d) / "b.net")
        self.assertTrue(circuit_mod.parity(c, text)["ok"])


if __name__ == "__main__":
    os.chdir(Path(__file__).resolve().parent)
    unittest.main()
