# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# interfaces.py — SKiDL interface templates for corev-mb boards.
#
# Each factory returns SKiDL parts built "from scratch" (no external KiCad
# library required to import this module), so a design.py can start ERC-clean
# and then refine footprints/pins with pcbparts.dev (cse_get_kicad, jlc_get_pinout).
# These are intentionally minimal scaffolds: the point is to give the design
# loop real nets to check, not a finished schematic.
#
# skidl is imported lazily inside the factories so this module is import-safe
# even when skidl is not installed (the CLI can still load board specs).

from __future__ import annotations

from typing import Any


def _skidl() -> Any:
    import skidl  # noqa: PLC0415 (optional dependency, imported on demand)

    return skidl


def scratch_part(name: str, ref_prefix: str, pins: list[tuple[str, str, str]]) -> Any:
    """Create a library-free SKiDL part. pins = [(num, name, func)]."""
    skidl = _skidl()
    part = skidl.Part(name=name, ref_prefix=ref_prefix, tool=skidl.SKIDL, dest=skidl.TEMPLATE)
    func_map = {
        "pwr_in": skidl.Pin.types.PWRIN,
        "pwr_out": skidl.Pin.types.PWROUT,
        "in": skidl.Pin.types.INPUT,
        "out": skidl.Pin.types.OUTPUT,
        "bidir": skidl.Pin.types.BIDIR,
        "passive": skidl.Pin.types.PASSIVE,
    }
    for num, pname, func in pins:
        part += skidl.Pin(num=num, name=pname, func=func_map.get(func, skidl.Pin.types.PASSIVE))
    return part


def soc_placeholder() -> Any:
    """A minimal CVA6 SoC/APU footprint stand-in (power + a few I/O rails)."""
    return scratch_part(
        "CVA6_SOC",
        "U",
        [
            ("1", "VDD", "pwr_in"),
            ("2", "GND", "pwr_in"),
            ("3", "CLK", "in"),
            ("4", "RSTN", "in"),
            ("5", "JTAG_TCK", "in"),
            ("6", "JTAG_TMS", "in"),
            ("7", "UART_TX", "out"),
            ("8", "UART_RX", "in"),
        ],
    )


def connector(kind: str, pin_count: int = 4) -> Any:
    """Generic board connector/interface stub with `pin_count` passive pins."""
    pins = [(str(i + 1), f"{kind.upper()}_{i+1}", "passive") for i in range(max(2, pin_count))]
    return scratch_part(f"CONN_{kind.upper()}", "J", pins)


# Per-domain hint for how many pins a stub connector should have. Real designs
# replace these with pcbparts.dev footprints via cse_get_kicad.
DOMAIN_PIN_HINT = {
    "memory": 8,
    "network": 8,
    "interconnect": 8,
    "storage": 6,
    "display": 8,
    "usb": 4,
    "peripheral": 4,
}


def build_from_spec(spec: dict[str, Any]) -> dict[str, Any]:
    """Instantiate a scaffold circuit from a board.json dict.

    Returns a dict of created parts keyed by a stable name. Connects power and
    ground so skidl.ERC() has real nets to evaluate.
    """
    skidl = _skidl()
    vdd = skidl.Net("VDD")
    gnd = skidl.Net("GND")
    vdd.drive = skidl.POWER
    gnd.drive = skidl.POWER

    soc = soc_placeholder()()  # instantiate the TEMPLATE
    soc["VDD"] += vdd
    soc["GND"] += gnd

    parts: dict[str, Any] = {"soc": soc}
    for iface in spec.get("interfaces", []):
        kind = str(iface.get("kind", "iface"))
        domain = str(iface.get("domain", "peripheral"))
        conn = connector(kind, DOMAIN_PIN_HINT.get(domain, 4))()
        # Tie pin 1/2 to power rails so the stub is not fully floating.
        conn[1] += vdd
        conn[2] += gnd
        parts[str(iface.get("id", kind))] = conn
    return parts
