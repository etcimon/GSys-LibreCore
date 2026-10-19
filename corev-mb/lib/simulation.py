# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# simulation.py — ngspice scenarios over the mbgen resolved circuit.
#
# A scenario is an explicit, checked-in JSON file (boards/<id>/sim/<name>.json):
# which components take which SPICE models, which sources drive which nets,
# which analysis runs, and which measurements must land in which range.
# Nothing is inferred from a role name: a component without a model in the
# scenario is simply not in the deck, and the deck says so.
#
# Results are revision-bound: the report carries sha256 of the circuit, the
# scenario and the generated deck, plus the simulator version string. A run
# that did not produce every measurement is `incomplete`, never `pass`.

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SCENARIO_SCHEMA_VERSION = 1

_ELEMENT_PREFIX = {"R": "R", "C": "C", "L": "L", "V": "V", "I": "I", "D": "D"}


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sha256_json(obj: Any) -> str:
    return sha256_text(json.dumps(obj, sort_keys=True, separators=(",", ":")))


def load_scenario(path: Path) -> dict[str, Any]:
    scenario = json.loads(Path(path).read_text())
    if scenario.get("schema_version") != SCENARIO_SCHEMA_VERSION:
        raise ValueError(f"scenario schema {scenario.get('schema_version')} is not {SCENARIO_SCHEMA_VERSION}")
    for key in ("id", "analysis", "measurements"):
        if key not in scenario:
            raise ValueError(f"scenario lacks '{key}'")
    return scenario


def _node_name(net: str, ground: str) -> str:
    if net == ground:
        return "0"
    return re.sub(r"[^A-Za-z0-9_]", "_", net)


@dataclass
class Deck:
    text: str
    elements: int
    missing: list[str] = field(default_factory=list)
    nodes: dict[str, str] = field(default_factory=dict)


def deck_from_circuit(circuit: dict[str, Any], scenario: dict[str, Any]) -> Deck:
    """Build an ngspice batch deck. Pins map to the circuit's nets; a modelled
    pin that is on no net becomes a `missing` entry and a unique floating node."""
    ground = scenario.get("ground", "GND")
    net_of_pin: dict[str, str] = {}
    for net in circuit.get("nets", []):
        for pid in net["pins"]:
            net_of_pin[pid] = net["id"]
    pins_of: dict[str, list[dict[str, Any]]] = {}
    for p in circuit.get("pins", []):
        pins_of.setdefault(p["part"], []).append(p)
    refs = {c["id"]: (c.get("refdes") or c["id"]) for c in circuit.get("components", [])}

    lines = [f"* mbgen scenario {scenario['id']} on {circuit.get('template_id', '?')}"]
    missing: list[str] = []
    nodes: dict[str, str] = {}
    elements = 0
    for cid, model in sorted(scenario.get("models", {}).items()):
        if cid not in refs:
            missing.append(f"component {cid} is not in the circuit")
            continue
        kind = str(model.get("kind", "")).upper()
        if kind not in _ELEMENT_PREFIX:
            missing.append(f"{cid}: unsupported model kind {kind!r}")
            continue
        pin_ids = model.get("pins")
        if not pin_ids:
            pin_ids = [p["id"] for p in sorted(pins_of.get(cid, []), key=lambda x: x["index"])][:2]
        if len(pin_ids) != 2:
            missing.append(f"{cid}: a {kind} element needs two pins, got {len(pin_ids)}")
            continue
        node_list = []
        for pid in pin_ids:
            net = net_of_pin.get(pid)
            if net is None:
                missing.append(f"{cid}: pin {pid} is on no net")
                node = f"float_{re.sub(r'[^A-Za-z0-9_]', '_', pid)}"
            else:
                node = _node_name(net, ground)
                nodes[net] = node
            node_list.append(node)
        value = str(model.get("value", "")).strip()
        if not value:
            missing.append(f"{cid}: model has no value")
            continue
        lines.append(f"{_ELEMENT_PREFIX[kind]}{refs[cid]} {node_list[0]} {node_list[1]} {value}")
        elements += 1
    for i, src in enumerate(scenario.get("sources", [])):
        name = src.get("name") or f"S{i}"
        plus = _node_name(src["plus"], ground)
        minus = _node_name(src.get("minus", ground), ground)
        nodes[src["plus"]] = plus
        lines.append(f"V{name} {plus} {minus} {src.get('spec', 'DC ' + str(src.get('value', 0)))}")
        elements += 1

    analysis = scenario["analysis"]
    kind = analysis.get("type", "op")
    control = [".control", "set filetype=ascii"]
    if kind == "op":
        control.append("op")
    elif kind == "tran":
        control.append(f"tran {analysis['step']} {analysis['stop']}")
    elif kind == "dc":
        control.append(f"dc {analysis['source']} {analysis['start']} {analysis['stop']} {analysis['step']}")
    else:
        missing.append(f"unsupported analysis type {kind!r}")
    for m in scenario.get("measurements", []):
        expr = m["expr"]
        how = m.get("type", "op")
        if how == "op":
            control.append(f"let __{m['name']} = {expr}")
            control.append(f"print __{m['name']}")
        elif how in ("max", "min", "avg", "rms", "pp"):
            control.append(f"meas {kind} __{m['name']} {how.upper()} {expr}")
        else:
            missing.append(f"measurement {m['name']}: unsupported type {how!r}")
    control += ["quit", ".endc", ".end"]
    text = "\n".join(lines + control) + "\n"
    return Deck(text=text, elements=elements, missing=missing, nodes=nodes)


@dataclass
class SimResult:
    status: str  # pass | fail | incomplete
    reason: str
    scenario_id: str
    measurements: dict[str, dict[str, Any]] = field(default_factory=dict)
    deck_sha256: str = ""
    circuit_sha256: str = ""
    scenario_sha256: str = ""
    simulator: str = ""
    log_tail: str = ""

    def as_dict(self) -> dict[str, Any]:
        return dict(self.__dict__)


_PRINT_RE = re.compile(r"^__(?P<name>\w+)\s*=\s*(?P<value>[-+0-9.eE]+)", re.MULTILINE)
_INCOMPLETE_MARKERS = (
    "timestep too small",
    "singular matrix",
    "no convergence",
    "gmin stepping failed",
    "source stepping failed",
    "unknown subckt",
    "could not find",
    "error",
)


def parse_measurements(stdout: str) -> dict[str, float]:
    out: dict[str, float] = {}
    for m in _PRINT_RE.finditer(stdout):
        try:
            out[m.group("name")] = float(m.group("value"))
        except ValueError:
            continue
    return out


def judge(scenario: dict[str, Any], values: dict[str, float], log: str) -> tuple[str, str, dict[str, dict[str, Any]]]:
    """Classify a finished run. Missing measurements or solver trouble are
    `incomplete`; an out-of-range measurement is `fail`."""
    low = log.lower()
    for marker in _INCOMPLETE_MARKERS:
        if marker in low and marker != "error":
            return "incomplete", f"simulator reported: {marker}", {}
    rows: dict[str, dict[str, Any]] = {}
    missing = []
    failed = []
    for m in scenario.get("measurements", []):
        name = m["name"]
        if name not in values:
            missing.append(name)
            rows[name] = {"value": None, "ok": False, "min": m.get("min"), "max": m.get("max")}
            continue
        v = values[name]
        ok = (m.get("min") is None or v >= float(m["min"])) and (m.get("max") is None or v <= float(m["max"]))
        rows[name] = {"value": v, "ok": ok, "min": m.get("min"), "max": m.get("max")}
        if not ok:
            failed.append(name)
    if missing:
        return "incomplete", f"measurements not produced: {', '.join(missing)}", rows
    if failed:
        return "fail", f"out of range: {', '.join(failed)}", rows
    if "error" in low and "0 errors" not in low:
        return "incomplete", "simulator log contains an error", rows
    return "pass", "all measurements in range", rows


def find_ngspice(explicit: str | None = None) -> str | None:
    for candidate in (explicit, os.environ.get("NGSPICE_BIN"), "ngspice", "ngspice_con"):
        if not candidate:
            continue
        found = shutil.which(candidate) or (candidate if Path(candidate).exists() else None)
        if found:
            return found
    return None


def ngspice_version(binary: str, timeout: float = 20.0) -> str:
    try:
        proc = subprocess.run([binary, "-v"], capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    first = (proc.stdout or proc.stderr).strip().splitlines()
    return first[0] if first else "unknown"


def run_scenario(
    circuit: dict[str, Any],
    scenario: dict[str, Any],
    workdir: Path,
    ngspice: str | None = None,
    timeout: float = 120.0,
) -> SimResult:
    deck = deck_from_circuit(circuit, scenario)
    base = SimResult(
        status="incomplete",
        reason="",
        scenario_id=scenario["id"],
        deck_sha256=sha256_text(deck.text),
        circuit_sha256=sha256_json(circuit),
        scenario_sha256=sha256_json(scenario),
    )
    workdir = Path(workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    deck_file = workdir / f"{scenario['id']}.cir"
    deck_file.write_text(deck.text)
    if deck.missing:
        base.reason = "deck incomplete: " + "; ".join(deck.missing)
        return base
    if deck.elements == 0:
        base.reason = "deck has no elements (scenario models nothing in this circuit)"
        return base
    binary = find_ngspice(ngspice)
    if binary is None:
        base.reason = "ngspice not found (install it or set NGSPICE_BIN)"
        return base
    base.simulator = ngspice_version(binary)
    log_file = workdir / f"{scenario['id']}.log"
    try:
        proc = subprocess.run(
            [binary, "-b", "-o", str(log_file), str(deck_file)],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            cwd=str(workdir),
        )
    except subprocess.TimeoutExpired:
        base.reason = f"timeout after {timeout} s"
        return base
    except OSError as exc:
        base.reason = f"could not start ngspice: {exc}"
        return base
    log = (log_file.read_text(errors="replace") if log_file.exists() else "") + "\n" + (proc.stdout or "") + (proc.stderr or "")
    values = parse_measurements(log)
    status, reason, rows = judge(scenario, values, log)
    if proc.returncode != 0 and status == "pass":
        status, reason = "incomplete", f"ngspice exit {proc.returncode}"
    base.status, base.reason, base.measurements = status, reason, rows
    base.log_tail = "\n".join(log.strip().splitlines()[-30:])
    return base
