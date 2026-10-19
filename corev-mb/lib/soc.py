# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# soc.py — Entry point for the SKiDL board-design flow (custom boards).
#
# `build_board(boardid)` is what a generated design.py calls. It:
#   1. loads corev-mb/boards/<id>/board.json,
#   2. (custom boards only) assembles a scaffold circuit from the declared
#      interfaces via interfaces.build_from_spec,
#   3. runs ERC (erc.run_erc),
#   4. optionally uses pcbparts.dev to look up alternatives for failing PHYs
#      when ERC_FIX=1 and PCBPARTS_ALLOW_NETWORK=1,
#   5. writes a netlist to corev-mb/boards/<id>/outputs/.
#
# It degrades gracefully: if skidl is not installed it prints how to get it and
# returns a non-zero code without crashing.

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from erc import run_erc
from pcbparts_mcp import PcbPartsClient


def repo_root() -> Path:
    return Path(os.environ.get("CVA6_REPO_DIR", os.getcwd()))


def board_dir(boardid: str) -> Path:
    return repo_root() / "corev-mb" / "boards" / boardid


def load_spec(boardid: str) -> dict[str, Any]:
    spec_file = board_dir(boardid) / "board.json"
    if not spec_file.exists():
        raise FileNotFoundError(f"No board.json for '{boardid}' at {spec_file}")
    return json.loads(spec_file.read_text())


def build_board(boardid: str) -> int:
    spec = load_spec(boardid)
    skidl_mode = spec.get("skidl", "omitted")
    print(f"[corev-mb] board={boardid} skidl={skidl_mode} status={spec.get('status')}")

    if skidl_mode != "custom":
        print(f"[corev-mb] '{boardid}' is not a custom board (skidl={skidl_mode}); no schematic to build.")
        return 0

    try:
        import skidl  # noqa: PLC0415
    except Exception:  # noqa: BLE001
        print("[corev-mb] skidl is not installed. Install it into the managed venv:")
        print("           pip install -r corev-mb/lib/requirements.txt")
        return 2

    circuit_file = board_dir(boardid) / "circuit.json"
    if circuit_file.exists():
        return _build_from_circuit(boardid, spec, circuit_file)

    import interfaces  # local module (flat on sys.path)

    skidl.reset()
    parts = interfaces.build_from_spec(spec)
    print(f"[corev-mb] instantiated {len(parts)} scaffold part(s) from {len(spec.get('interfaces', []))} interface(s)")

    report = run_erc()
    print(report.text.strip() or "[corev-mb] ERC produced no messages.")

    if not report.ok and os.environ.get("ERC_FIX") == "1":
        _attempt_fixes(spec, report.messages)

    out_dir = board_dir(boardid) / "outputs"
    out_dir.mkdir(parents=True, exist_ok=True)
    net_file = out_dir / f"{boardid}.net"
    try:
        skidl.generate_netlist(file_=str(net_file))
        print(f"[corev-mb] wrote netlist: {net_file}")
    except Exception as exc:  # noqa: BLE001
        print(f"[corev-mb] netlist generation skipped: {exc}")

    _write_bom(spec, out_dir / f"{boardid}_bom.json", parts)
    return 0 if report.ok else 1


def _build_from_circuit(boardid: str, spec: dict[str, Any], circuit_file: Path) -> int:
    """Lossless path: compile the ingested mbgen circuit, ERC it, write the
    netlist, read it back and compare. Any failure is a non-zero exit."""
    import skidl  # noqa: PLC0415

    import circuit as circuit_mod  # local module (flat on sys.path)

    circuit = circuit_mod.load_circuit(circuit_file)
    out_dir = board_dir(boardid) / "outputs"
    out_dir.mkdir(parents=True, exist_ok=True)
    skidl.reset()
    parts = circuit_mod.build_from_circuit(circuit)
    print(
        f"[corev-mb] compiled circuit.json: {len(parts)} component(s), "
        f"{len(circuit.get('pins', []))} pin(s), {len(circuit.get('nets', []))} net(s)"
    )
    report = circuit_mod.run_structured_erc(circuit)
    erc_file = out_dir / f"{boardid}.erc.json"
    erc_file.write_text(json.dumps(report.as_dict(), indent=2) + "\n")
    for issue in report.issues:
        tag = issue.rule
        where = " ".join(x for x in (issue.part, issue.pin, issue.net) if x)
        print(f"[corev-mb]   {issue.severity.upper():7} {tag:32} {where} — {issue.message}")
    print(f"[corev-mb] ERC: {report.errors} error(s), {report.warnings} warning(s) -> {erc_file}")

    net_file = out_dir / f"{boardid}.net"
    try:
        text = circuit_mod.write_netlist(net_file)
    except Exception as exc:  # noqa: BLE001
        print(f"[corev-mb] netlist generation FAILED: {exc}")
        return 1
    print(f"[corev-mb] wrote netlist: {net_file}")
    par = circuit_mod.parity(circuit, text)
    par_file = out_dir / f"{boardid}.parity.json"
    par_file.write_text(json.dumps(par, indent=2) + "\n")
    print(
        f"[corev-mb] parity: {'ok' if par['ok'] else 'MISMATCH'} "
        f"({par['nets_checked']} nets checked, {len(par['unresolved_footprints'])} unresolved footprint(s)) -> {par_file}"
    )
    bom = {
        "board": boardid,
        "source": "circuit.json",
        "components": circuit_mod.bom_rows(circuit),
        "phys": spec.get("phys", []),
    }
    bom_file = out_dir / f"{boardid}_bom.json"
    bom_file.write_text(json.dumps(bom, indent=2) + "\n")
    print(f"[corev-mb] wrote BOM: {bom_file}")
    return 0 if report.ok and par["ok"] else 1


def _attempt_fixes(spec: dict[str, Any], messages: list[str]) -> None:
    """Best-effort: query pcbparts.dev for alternatives to the declared PHYs."""
    client = PcbPartsClient()
    if not client.allow_network:
        print("[corev-mb] ERC_FIX set but network disabled; pass --online to query pcbparts.dev.")
        return
    max_iter = int(os.environ.get("ERC_MAX_ITER", "4"))
    print(f"[corev-mb] ERC fix loop (max {max_iter} iterations, {len(messages)} message(s))")
    for phy in spec.get("phys", [])[:max_iter]:
        mpn = phy.get("mpn")
        if not mpn:
            continue
        res = client.jlc_find_alternatives(mpn=mpn, limit=3)
        print(f"[corev-mb]   {phy.get('ref')}: alternatives for {mpn} -> source={res.source} ok={res.ok}")


def _write_bom(spec: dict[str, Any], path: Path, parts: dict[str, Any] | None = None) -> None:
    parts = parts or {}
    rows = []
    core = spec.get("core") if isinstance(spec.get("core"), dict) else {}
    rows.append({
        "id": "soc",
        "domain": "core",
        "kind": "soc",
        "footprint": "",
        "mpn": "",
        "lcsc": "",
        "config": core.get("config", ""),
    })
    for iface in spec.get("interfaces", []):
        ident = str(iface.get("id") or "")
        part = parts.get(ident)
        fields = getattr(part, "fields", {}) if part is not None else {}
        rows.append({
            "id": ident,
            "domain": iface.get("domain"),
            "kind": iface.get("kind"),
            "footprint": getattr(part, "footprint", "") if part is not None else "",
            "mpn": fields.get("MPN", "") if isinstance(fields, dict) else "",
            "lcsc": fields.get("LCSC", "") if isinstance(fields, dict) else "",
            "config": "",
            "pin_count": getattr(part, "mb_pin_count", 0) if part is not None else 0,
            "pins": getattr(part, "mb_pins", []) if part is not None else [],
        })
    bom = {
        "board": spec.get("boardid"),
        "phys": spec.get("phys", []),
        "interfaces": rows,
    }
    path.write_text(json.dumps(bom, indent=2))
    print(f"[corev-mb] wrote BOM: {path}")
