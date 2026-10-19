# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# pcb.py — KiCad bridge and the manufacturing gate.
#
# mbgen keeps routing intent and placement in layout.json; KiCad remains the
# manufacturing router and the DRC authority. This module:
#   * discovers `kicad-cli` (never assumes it),
#   * runs DRC / exports through it when a board file exists,
#   * compares a KiCad-exported netlist against the mbgen circuit (parity),
#   * and computes the manufacturing gate: a pure decision over the ERC,
#     parity, DRC and layout reports. Any missing input blocks the gate.

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

from circuit import UNRESOLVED_FOOTPRINT, netlist_nets, parity

_WINDOWS_KICAD_DIRS = (Path(r"C:\Program Files\KiCad"), Path(r"C:\Program Files (x86)\KiCad"))


def find_kicad_cli(explicit: str | None = None) -> str | None:
    for candidate in (explicit, os.environ.get("KICAD_CLI")):
        if candidate and (shutil.which(candidate) or Path(candidate).exists()):
            return shutil.which(candidate) or candidate
    found = shutil.which("kicad-cli")
    if found:
        return found
    for root in _WINDOWS_KICAD_DIRS:
        if root.exists():
            for version in sorted(root.iterdir(), reverse=True):
                exe = version / "bin" / "kicad-cli.exe"
                if exe.exists():
                    return str(exe)
    return None


def _run(args: list[str], timeout: float) -> tuple[int, str]:
    try:
        proc = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except OSError as exc:
        return 127, str(exc)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def run_drc(kicad_cli: str, board: Path, report: Path, timeout: float = 600.0) -> dict[str, Any]:
    """`kicad-cli pcb drc --format json --severity-all --exit-code-violations`."""
    report = Path(report)
    report.parent.mkdir(parents=True, exist_ok=True)
    code, log = _run(
        [kicad_cli, "pcb", "drc", "--format", "json", "--severity-all", "--exit-code-violations", "-o", str(report), str(board)],
        timeout,
    )
    out: dict[str, Any] = {"ok": code == 0, "exit": code, "report": str(report), "violations": None, "unconnected": None, "log_tail": log[-2000:]}
    if report.exists():
        try:
            data = json.loads(report.read_text())
            out["violations"] = len(data.get("violations", []))
            out["unconnected"] = len(data.get("unconnected_items", []))
            out["ok"] = out["ok"] and out["violations"] == 0 and out["unconnected"] == 0
        except json.JSONDecodeError:
            out["ok"] = False
            out["log_tail"] += "\nDRC report is not JSON"
    else:
        out["ok"] = False
    return out


def export_manufacturing(kicad_cli: str, board: Path, out_dir: Path, timeout: float = 600.0) -> dict[str, Any]:
    """Gerbers, drill, position files. Only call after the gate is open."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    steps = {
        "gerbers": [kicad_cli, "pcb", "export", "gerbers", "-o", str(out_dir / "gerbers") + os.sep, str(board)],
        "drill": [kicad_cli, "pcb", "export", "drill", "-o", str(out_dir / "drill") + os.sep, str(board)],
        "pos": [kicad_cli, "pcb", "export", "pos", "--format", "csv", "--units", "mm", "-o", str(out_dir / "placement.csv"), str(board)],
    }
    results: dict[str, Any] = {}
    for name, args in steps.items():
        code, log = _run(args, timeout)
        results[name] = {"ok": code == 0, "exit": code, "log_tail": log[-500:]}
    results["ok"] = all(results[k]["ok"] for k in steps)
    return results


def export_netlist_from_pcb(kicad_cli: str, board: Path, out: Path, timeout: float = 300.0) -> str | None:
    """Netlist as the PCB sees it (`kicad-cli pcb export netlist`, KiCad ≥ 9)."""
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    code, _ = _run([kicad_cli, "pcb", "export", "netlist", "-o", str(out), str(board)], timeout)
    if code != 0 or not out.exists():
        return None
    return out.read_text()


def pcb_parity(circuit: dict[str, Any], pcb_netlist_text: str) -> dict[str, Any]:
    """Circuit ↔ board connectivity agreement, same rules as the SKiDL readback."""
    out = parity(circuit, pcb_netlist_text)
    out["source"] = "kicad-pcb"
    out["nets_in_pcb"] = len(netlist_nets(pcb_netlist_text))
    return out


def layout_contract(circuit: dict[str, Any], layout: dict[str, Any]) -> dict[str, Any]:
    """Every populated component must have a placement and a resolved footprint."""
    placements = {p["id"]: p for p in layout.get("placements", [])}
    unplaced = []
    unresolved = []
    for c in circuit.get("components", []):
        if c.get("dnp"):
            continue
        p = placements.get(c["id"])
        if p is None:
            unplaced.append(c["id"])
            continue
        fp = p.get("footprint") or (c.get("part") or {}).get("footprint") or ""
        if not fp or fp == UNRESOLVED_FOOTPRINT:
            unresolved.append(c["id"])
    return {
        "ok": not unplaced and not unresolved,
        "components": len(circuit.get("components", [])),
        "unplaced": unplaced,
        "unresolved_footprints": unresolved,
        "outline": layout.get("outline"),
    }


def manufacturing_gate(
    erc: dict[str, Any] | None,
    skidl_parity: dict[str, Any] | None,
    layout: dict[str, Any] | None,
    drc: dict[str, Any] | None,
    pcb_par: dict[str, Any] | None,
) -> dict[str, Any]:
    """Pure gate. Every input is required; a missing one is a blocker, not a pass."""
    blockers: list[str] = []
    if erc is None:
        blockers.append("no ERC report")
    elif not erc.get("ok"):
        blockers.append(f"ERC has {erc.get('errors', '?')} error(s)")
    if skidl_parity is None:
        blockers.append("no SKiDL netlist parity report")
    elif not skidl_parity.get("ok"):
        blockers.append("SKiDL netlist disagrees with the circuit")
    if layout is None:
        blockers.append("no layout contract report")
    else:
        if layout.get("unplaced"):
            blockers.append(f"{len(layout['unplaced'])} component(s) without placement")
        if layout.get("unresolved_footprints"):
            blockers.append(f"{len(layout['unresolved_footprints'])} component(s) without a frozen footprint")
    if drc is None:
        blockers.append("no PCB DRC report")
    elif not drc.get("ok"):
        blockers.append(f"PCB DRC: {drc.get('violations', '?')} violation(s), {drc.get('unconnected', '?')} unconnected")
    if pcb_par is None:
        blockers.append("no PCB connectivity parity report")
    elif not pcb_par.get("ok"):
        blockers.append("PCB connectivity disagrees with the circuit")
    return {"ready": not blockers, "blockers": blockers}
