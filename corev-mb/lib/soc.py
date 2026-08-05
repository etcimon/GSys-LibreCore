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

    _write_bom(spec, out_dir / f"{boardid}_bom.json")
    return 0 if report.ok else 1


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


def _write_bom(spec: dict[str, Any], path: Path) -> None:
    bom = {
        "board": spec.get("boardid"),
        "phys": spec.get("phys", []),
        "interfaces": [
            {"id": i.get("id"), "domain": i.get("domain"), "kind": i.get("kind"), "phy": i.get("phy")}
            for i in spec.get("interfaces", [])
        ],
    }
    path.write_text(json.dumps(bom, indent=2))
    print(f"[corev-mb] wrote BOM: {path}")
