# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# circuit.py — SKiDL compiler for the mbgen resolved circuit (`circuit.json`).
#
# This is the lossless path: every component, pin and net in the UE5 workspace
# becomes exactly one SKiDL part, pin and net, with the same identifiers.
# Nothing is inferred here — pin functions come from the circuit's pin kinds,
# no-connects only from the circuit's explicit `no_connects`, and the netlist
# is read back and compared to the input so a disagreement is a reported
# failure, not a silent drift.
#
# Open pins are never exempted from ERC. SKiDL's own findings are captured
# from its logger (counted, not grepped), mapped back to mbgen component /
# pin / net ids, and merged with mbgen's resolve diagnostics into one report.

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

CIRCUIT_SCHEMA_VERSION = 1

# mbgen pin kind -> SKiDL pin function. Unknown-function signal contacts
# (frozen name only) are BIDIR: the least-assuming connectable type.
_PIN_FUNC = {
    "Power": "PWRIN",
    "Ground": "PWRIN",
    "Signal": "BIDIR",
    "Clock": "INPUT",
    "Analog": "PASSIVE",
    "Passive": "PASSIVE",
}

UNRESOLVED_FOOTPRINT = "mbgen:unresolved"


@dataclass
class Issue:
    rule: str
    severity: str  # error | warning | info
    source: str  # mbgen | skidl | parity
    message: str
    part: str | None = None
    pin: str | None = None
    net: str | None = None
    suggestion: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {k: v for k, v in self.__dict__.items() if v is not None}


@dataclass
class ErcResult:
    ok: bool
    errors: int
    warnings: int
    counter_source: str
    issues: list[Issue] = field(default_factory=list)
    aggregates: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "errors": self.errors,
            "warnings": self.warnings,
            "counter_source": self.counter_source,
            "issues": [i.as_dict() for i in self.issues],
            "aggregates": self.aggregates,
        }


def load_circuit(path: Path) -> dict[str, Any]:
    circuit = json.loads(Path(path).read_text())
    version = circuit.get("schema_version")
    if version != CIRCUIT_SCHEMA_VERSION:
        raise ValueError(f"circuit.json schema {version} is not {CIRCUIT_SCHEMA_VERSION}")
    return circuit


def pin_number(pin_id: str) -> str:
    """`<part>.<number>` -> `<number>`."""
    return pin_id.rsplit(".", 1)[1] if "." in pin_id else pin_id


def pin_part(pin_id: str) -> str:
    return pin_id.rsplit(".", 1)[0] if "." in pin_id else pin_id


def refdes_map(circuit: dict[str, Any]) -> dict[str, str]:
    """component id -> refdes; a component without one gets a stable fallback."""
    out: dict[str, str] = {}
    for c in circuit.get("components", []):
        ref = c.get("refdes") or f"X_{c['id']}"
        out[c["id"]] = ref
    return out


def build_from_circuit(circuit: dict[str, Any]) -> dict[str, Any]:
    """Instantiate SKiDL parts and nets for the resolved circuit.

    Returns {component id: Part}. Caller is responsible for `skidl.reset()`.
    """
    import skidl  # noqa: PLC0415
    from skidl import Net, Part, Pin, SKIDL, TEMPLATE  # noqa: PLC0415

    pins_of: dict[str, list[dict[str, Any]]] = {}
    for p in circuit.get("pins", []):
        pins_of.setdefault(p["part"], []).append(p)
    refs = refdes_map(circuit)
    parts: dict[str, Any] = {}
    skidl_pins: dict[str, Any] = {}

    for comp in circuit.get("components", []):
        cid = comp["id"]
        tmpl = Part(tool=SKIDL, name=comp["role"], dest=TEMPLATE)
        for p in sorted(pins_of.get(cid, []), key=lambda x: x["index"]):
            func = getattr(Pin.types, _PIN_FUNC.get(p["kind"], "UNSPEC"))
            tmpl += Pin(num=pin_number(p["id"]), name=p["name"], func=func)
        part_ref = comp.get("part") or {}
        footprint = part_ref.get("footprint") or UNRESOLVED_FOOTPRINT
        part = tmpl(ref=refs[cid], value=comp.get("value") or comp["role"], footprint=footprint)
        part.fields["mbgen_id"] = cid
        part.fields["mbgen_role"] = comp["role"]
        part.fields["mbgen_pin_spec"] = comp.get("pin_spec", "")
        if part_ref.get("mpn"):
            part.fields["MPN"] = part_ref["mpn"]
        if part_ref.get("lcsc"):
            part.fields["LCSC"] = part_ref["lcsc"]
        if comp.get("dnp"):
            part.fields["DNP"] = "1"
        if comp.get("owner_block"):
            part.fields["mbgen_block"] = comp["owner_block"]
        parts[cid] = part
        for p in pins_of.get(cid, []):
            skidl_pins[p["id"]] = part[pin_number(p["id"])]

    for net in circuit.get("nets", []):
        n = Net(net["id"])
        for pid in net["pins"]:
            sp = skidl_pins.get(pid)
            if sp is None:
                raise KeyError(f"net {net['id']} names unknown pin {pid}")
            n += sp

    # Explicit no-connects only. Everything else stays visible to ERC.
    for pid in circuit.get("no_connects", []):
        sp = skidl_pins.get(pid)
        if sp is not None:
            sp.func = Pin.types.NOCONNECT

    _ = skidl  # keep import for callers that pass the module around
    return parts


class _Capture(logging.Handler):
    def __init__(self) -> None:
        super().__init__(level=logging.DEBUG)
        self.records: list[logging.LogRecord] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.records.append(record)


_PIN_RE = re.compile(r"pin (?P<num>\S+)/(?P<name>\S+) of (?P<part>\S+)/(?P<ref>\S+)")
_NET_RE = re.compile(r"(?:on|for) net (?P<net>\S+)")
_PUNCT = ".,;:"


def _tok(s: str) -> str:
    """SKiDL messages end tokens with prose punctuation (`J1.`, `CLASH,`)."""
    return s.rstrip(_PUNCT)


def _classify(message: str) -> str:
    low = message.lower()
    if "unconnected pin" in low:
        return "PIN-OPEN"
    if "insufficient drive" in low:
        return "NET-NO-DRIVE"
    if "conflict" in low:
        return "PIN-CONFLICT"
    if "no pins" in low or "has no connections" in low:
        return "NET-EMPTY"
    return "OTHER"


def run_structured_erc(circuit: dict[str, Any]) -> ErcResult:
    """Run skidl.ERC() on the current circuit and map findings back to mbgen ids."""
    import skidl  # noqa: PLC0415

    refs = refdes_map(circuit)
    by_ref = {v: k for k, v in refs.items()}
    pin_info = {p["id"]: p for p in circuit.get("pins", [])}

    issues: list[Issue] = []
    # mbgen resolve-time diagnostics ride along so one report has both sources.
    for d in circuit.get("diagnostics", []):
        issues.append(
            Issue(
                rule=d["rule"],
                severity=d["severity"],
                source="mbgen",
                message=d["message"],
                part=d.get("part"),
                pin=d.get("pin"),
                net=d.get("net"),
                suggestion=d.get("suggestion"),
            )
        )

    cap = _Capture()
    logger = skidl.erc_logger
    logger.addHandler(cap)
    counter_source = "erc_logger"
    try:
        for name in ("error", "warning"):
            counter = getattr(logger, name, None)
            if counter is not None and hasattr(counter, "reset"):
                counter.reset()
            else:
                counter_source = "records"
        skidl.ERC()
    finally:
        logger.removeHandler(cap)

    unknown_open: dict[str, int] = {}
    no_drive: dict[str, int] = {}
    for rec in cap.records:
        if rec.levelno < logging.WARNING:
            continue
        msg = rec.getMessage()
        severity = "error" if rec.levelno >= logging.ERROR else "warning"
        kind = _classify(msg)
        part = pin = net = None
        m = _PIN_RE.search(msg)
        if m:
            part = by_ref.get(_tok(m.group("ref")))
            if part:
                pin = f"{part}.{_tok(m.group('num'))}"
        n = _NET_RE.search(msg)
        if n:
            net = _tok(n.group("net"))
        if kind == "PIN-OPEN" and pin and pin in pin_info:
            info = pin_info[pin]
            # A frozen name with no known function is not a wiring defect yet; it
            # is a missing input. Aggregate per part instead of one row per pin.
            if info["kind"] == "Signal" and info["domain"] == info["name"]:
                unknown_open[part or "?"] = unknown_open.get(part or "?", 0) + 1
                continue
        if kind == "NET-NO-DRIVE" and net and pin:
            # One undriven rail yields one warning per sink pin in SKiDL; the
            # finding is about the net, so report it once with the sink count.
            no_drive[net] = no_drive.get(net, 0) + 1
            continue
        rule = f"{'E' if severity == 'error' else 'W'}-SKIDL-{kind}"
        issues.append(Issue(rule=rule, severity=severity, source="skidl", message=msg, part=part, pin=pin, net=net))
    for net, count in sorted(no_drive.items()):
        issues.append(
            Issue(
                rule="W-SKIDL-NET-NO-DRIVE",
                severity="warning",
                source="skidl",
                message=f"net {net}: no driver for {count} power-in contact(s)",
                net=net,
                suggestion="add a power-entry or regulator block that drives this rail",
            )
        )
    for part, count in sorted(unknown_open.items()):
        issues.append(
            Issue(
                rule="W-PIN-OPEN-UNKNOWN-FUNCTION",
                severity="warning",
                source="skidl",
                message=f"{refs.get(part, part)} ({part}): {count} frozen contacts with no known function left open",
                part=part,
                suggestion="freeze a pinout with functions (mb parts --freeze-pinout) or connect/NC each contact",
            )
        )

    if counter_source == "erc_logger":
        errors = int(logger.error.count)
        warnings = int(logger.warning.count)
    else:
        errors = sum(1 for r in cap.records if r.levelno >= logging.ERROR)
        warnings = sum(1 for r in cap.records if r.levelno == logging.WARNING)
    mbgen_errors = sum(1 for d in circuit.get("diagnostics", []) if d["severity"] == "error")
    return ErcResult(
        ok=errors == 0 and mbgen_errors == 0,
        errors=errors + mbgen_errors,
        warnings=warnings,
        counter_source=counter_source,
        issues=issues,
        aggregates={
            "skidl_errors": errors,
            "skidl_warnings": warnings,
            "mbgen_errors": mbgen_errors,
            "unknown_function_open_pins": unknown_open,
        },
    )


def write_netlist(path: Path) -> str:
    """Generate the KiCad netlist for the current circuit; raises on failure."""
    import skidl  # noqa: PLC0415

    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    skidl.generate_netlist(file_=str(path))
    text = path.read_text()
    if "(nets" not in text and "(net" not in text:
        raise RuntimeError(f"netlist at {path} has no nets section")
    return text


# --- s-expression readback --------------------------------------------------


def _tokenize(text: str) -> list[str]:
    tokens: list[str] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch.isspace():
            i += 1
        elif ch in "()":
            tokens.append(ch)
            i += 1
        elif ch == '"':
            j = i + 1
            buf = []
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n:
                    j += 1
                buf.append(text[j])
                j += 1
            tokens.append("".join(buf))
            i = j + 1
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in "()":
                j += 1
            tokens.append(text[i:j])
            i = j
    return tokens


def parse_sexpr(text: str) -> Any:
    tokens = _tokenize(text)
    pos = 0

    def parse() -> Any:
        nonlocal pos
        tok = tokens[pos]
        pos += 1
        if tok == "(":
            out = []
            while tokens[pos] != ")":
                out.append(parse())
            pos += 1
            return out
        if tok == ")":
            raise ValueError("unbalanced netlist")
        return tok

    return parse()


def netlist_nets(text: str) -> dict[str, set[tuple[str, str]]]:
    """{net name: {(ref, pin number)}} from a KiCad netlist."""
    tree = parse_sexpr(text)
    out: dict[str, set[tuple[str, str]]] = {}
    for section in tree[1:]:
        if not (isinstance(section, list) and section and section[0] == "nets"):
            continue
        for net in section[1:]:
            name = None
            nodes: set[tuple[str, str]] = set()
            for item in net[1:]:
                if item[0] == "name":
                    name = item[1]
                elif item[0] == "node":
                    ref = pin = None
                    for f in item[1:]:
                        if f[0] == "ref":
                            ref = f[1]
                        elif f[0] == "pin":
                            pin = f[1]
                    if ref is not None and pin is not None:
                        nodes.add((ref, pin))
            if name is not None:
                out[name] = nodes
    return out


def netlist_components(text: str) -> dict[str, dict[str, str]]:
    """{ref: {value, footprint}} from a KiCad netlist."""
    tree = parse_sexpr(text)
    out: dict[str, dict[str, str]] = {}
    for section in tree[1:]:
        if not (isinstance(section, list) and section and section[0] == "components"):
            continue
        for comp in section[1:]:
            row: dict[str, str] = {}
            for item in comp[1:]:
                if item[0] in ("ref", "value", "footprint") and len(item) > 1:
                    row[item[0]] = item[1]
            if "ref" in row:
                out[row["ref"]] = row
    return out


def parity(circuit: dict[str, Any], netlist_text: str) -> dict[str, Any]:
    """Compare the circuit's nets with what the netlist says. Single-pin nets
    are reported as skipped (KiCad netlists carry connections, not intents)."""
    refs = refdes_map(circuit)
    expected: dict[str, set[tuple[str, str]]] = {}
    skipped: list[str] = []
    for net in circuit.get("nets", []):
        nodes = {(refs[pin_part(p)], pin_number(p)) for p in net["pins"] if pin_part(p) in refs}
        if len(nodes) < 2:
            skipped.append(net["id"])
            continue
        expected[net["id"]] = nodes
    actual = netlist_nets(netlist_text)
    missing = sorted(n for n in expected if n not in actual)
    extra = sorted(n for n in actual if n not in expected and len(actual[n]) >= 2)
    mismatched = []
    for n, nodes in expected.items():
        if n in actual and actual[n] != nodes:
            mismatched.append(
                {
                    "net": n,
                    "missing_nodes": sorted(f"{r}.{p}" for r, p in nodes - actual[n]),
                    "extra_nodes": sorted(f"{r}.{p}" for r, p in actual[n] - nodes),
                }
            )
    comps = netlist_components(netlist_text)
    missing_parts = sorted(refs[c["id"]] for c in circuit.get("components", []) if refs[c["id"]] not in comps)
    unresolved = sorted(ref for ref, row in comps.items() if row.get("footprint") == UNRESOLVED_FOOTPRINT)
    ok = not missing and not extra and not mismatched and not missing_parts
    return {
        "ok": ok,
        "nets_checked": len(expected),
        "nets_skipped_single_pin": skipped,
        "missing_nets": missing,
        "extra_nets": extra,
        "mismatched_nets": mismatched,
        "missing_parts": missing_parts,
        "unresolved_footprints": unresolved,
    }


def bom_rows(circuit: dict[str, Any]) -> list[dict[str, Any]]:
    refs = refdes_map(circuit)
    rows = []
    for c in circuit.get("components", []):
        part = c.get("part") or {}
        rows.append(
            {
                "id": c["id"],
                "refdes": refs[c["id"]],
                "role": c["role"],
                "value": c.get("value") or "",
                "mpn": part.get("mpn", ""),
                "lcsc": part.get("lcsc", ""),
                "footprint": part.get("footprint") or UNRESOLVED_FOOTPRINT,
                "side": c.get("side", "Top"),
                "dnp": bool(c.get("dnp")),
                "pin_count": c.get("pin_count", 0),
                "pin_spec": c.get("pin_spec", ""),
                "owner_block": c.get("owner_block"),
            }
        )
    return rows
