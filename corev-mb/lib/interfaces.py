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
    soc.tag = "soc"
    soc["VDD"] += vdd
    soc["GND"] += gnd
    _leave_open_pins(soc)

    parts: dict[str, Any] = {"soc": soc}
    for iface in spec.get("interfaces", []):
        kind = str(iface.get("kind", "iface"))
        domain = str(iface.get("domain", "peripheral"))
        real_pins = _distributor_pins(kind)
        if real_pins:
            # Pin 1 of these symbols is not a power pin, so it is not tied to VDD.
            conn = scratch_part(f"CONN_{kind.upper()}", "J", real_pins)()
            print(f"[corev-mb] {kind}: {len(real_pins)} pins from the distributor symbol")
            if kind == "pcie_slot":
                tied = _tie_pcie_slot_power(skidl, conn, gnd)
                print(f"[corev-mb] pcie_slot: {tied} power or ground pins on P12V, P3V3, P3V3_AUX, or GND")
            elif kind == "sata":
                tied = _tie_sata_grounds(conn, gnd)
                print(f"[corev-mb] sata: pins 1, 4, and 7 on GND ({tied} tied)")
        else:
            conn = connector(kind, DOMAIN_PIN_HINT.get(domain, 4))()
            # Tie pin 1/2 to power rails so the stub is not fully floating.
            conn[1] += vdd
            conn[2] += gnd
        _leave_open_pins(conn)
        ident = str(iface.get("id", kind))
        conn.tag = ident
        parts[ident] = conn
    attached = attach_catalog_footprints(spec, parts)
    print(f"[corev-mb] catalog footprints: {attached} set, {len(parts) - attached} unresolved")
    return parts


def _tie_pcie_slot_power(skidl: Any, conn: Any, gnd: Any) -> int:
    """Tie the x16 slot rails from the CEM pin names.

    B1–B3 and A2–A3 are +12 V. B8, A9, and A10 are +3.3 V. B10 is +3.3 V
    auxiliary. B4, A4, and B7 are ground. Later ground pins stay open.
    """
    p12 = skidl.Net("P12V")
    p3 = skidl.Net("P3V3")
    p3aux = skidl.Net("P3V3_AUX")
    for net in (p12, p3, p3aux):
        net.drive = skidl.POWER
    rails = {
        "B1": p12, "B2": p12, "B3": p12, "A2": p12, "A3": p12,
        "B8": p3, "A9": p3, "A10": p3,
        "B10": p3aux,
        "B4": gnd, "A4": gnd, "B7": gnd,
        # Grounds through the end of the x1 section (pin 18).
        "A12": gnd, "B13": gnd, "A15": gnd, "B16": gnd, "B18": gnd, "A18": gnd,
    }
    tied = 0
    for name, net in rails.items():
        conn[name] += net
        tied += 1
    return tied


def _tie_sata_grounds(conn: Any, gnd: Any) -> int:
    """A 7-pin SATA data plug: pins 1, 4, and 7 are ground. Pins 8 and 9 stay open."""
    tied = 0
    for name in ("1", "4", "7"):
        conn[name] += gnd
        tied += 1
    return tied


def _leave_open_pins(part: Any) -> None:
    """The remaining stub pins are not a net yet. Skip their unconnected ERC."""
    for pin in part.pins:
        try:
            connected = pin.is_connected()
        except Exception:
            connected = bool(getattr(pin, "nets", None))
        if not connected:
            pin.do_erc = False


def attach_catalog_footprints(spec: dict[str, Any], parts: dict[str, Any]) -> int:
    """Set part.footprint from a pcbparts KiCad model when one is returned.

    Cache is used first. The network is used only when PCBPARTS_ALLOW_NETWORK=1.
    A miss leaves the footprint empty rather than inventing a library name.
    """
    client = _catalog_client()
    queries = _queries_by_ref(spec)
    kinds = {str(iface.get("id") or ""): str(iface.get("kind") or "") for iface in spec.get("interfaces", [])}
    count = 0
    seen: dict[tuple[str, str], str | None] = {}
    for ident, part in parts.items():
        query = queries.get(ident)
        if not query:
            continue
        kind = kinds.get(ident, "")
        key = (query, kind)
        if key not in seen:
            seen[key] = _lookup_footprint(client, query, _KIND_QUERIES.get(kind, ()))
        name = seen[key]
        if name:
            part.footprint = f"SamacSys:{name}"
            count += 1
            continue
        dist = _KIND_DISTRIBUTOR.get(kind)
        if dist:
            part.fields["MPN"] = dist[0]
            part.fields["LCSC"] = dist[1]
            pins = _pinout(client, dist[1])
            if pins:
                part.mb_pin_count = len(pins)
                part.mb_pins = pins
    return count


_PINOUTS: dict[str, list[dict[str, str]]] = {}


def _catalog_client() -> Any:
    """One parts client for the whole design run."""
    client = getattr(_catalog_client, "current", None)
    if client is None:
        from pcbparts_mcp import PcbPartsClient  # noqa: PLC0415

        client = PcbPartsClient()
        _catalog_client.current = client
    return client


def _distributor_pins(kind: str) -> list[tuple[str, str, str]] | None:
    dist = _KIND_DISTRIBUTOR.get(kind)
    if not dist:
        return None
    pins = _pinout(_catalog_client(), dist[1])
    if not pins:
        return None
    return [(pin["number"], pin["name"], "passive") for pin in pins]


def _pinout(client: Any, lcsc: str) -> list[dict[str, str]]:
    cached = _PINOUTS.get(lcsc)
    if cached is not None:
        return cached
    data = client.jlc_get_pinout(lcsc=lcsc).data
    rows = data.get("pins") if isinstance(data, dict) else None
    if not isinstance(rows, list):
        _PINOUTS[lcsc] = []
        return []
    pins = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        number = str(row.get("number") or "").strip()
        name = str(row.get("name") or "").strip()
        if number:
            pins.append({"number": number, "name": name or number})
    _PINOUTS[lcsc] = pins
    return pins


def _queries_by_ref(spec: dict[str, Any]) -> dict[str, str]:
    found: dict[str, str] = {}
    for phy in spec.get("phys", []):
        ref = str(phy.get("ref") or "")
        mcp = phy.get("mcp") or {}
        query = mcp.get("query") if isinstance(mcp, dict) else None
        if ref and isinstance(query, str) and query.strip():
            found[ref] = query.strip()
    return found


# Extra catalog keys tried after the board query. Each one was checked
# against cse_get_kicad and the connector filter before it was listed.
_KIND_QUERIES: dict[str, tuple[str, ...]] = {
    "usb_stack": ("USB-A",),
    "hdmi": ("10029449-111RLF",),
    "decap": ("GRM155R71C104KA88D",),
    "crystal": ("ABS07-32.768KHZ-T",),
    "esd": ("USBLC6-2SC6",),
    "spi_flash": ("W25Q128JVPIQ",),
    "phy_gbe": ("KSZ8081RNACA-TR",),
    "vtt": ("TPS51200DRCR",),
}

# JLCPCB parts whose description matches the role. The KiCad model service
# has no footprint for these, so the MPN is recorded and the footprint stays empty.
_KIND_DISTRIBUTOR: dict[str, tuple[str, str]] = {
    "sata": ("SATA-603-M07S1BY-A", "C7500843"),
    "dimm": ("90411-151231", "C5889263"),
    "nvme_m2": ("MLD-NGFF-M-4.8H", "C52766533"),
    "front_panel": ("PZ254V-12-10P", "C492422"),
    "pcie_slot": ("2EG08217-D2D-DF", "C426228"),
}


def _lookup_footprint(client: Any, query: str, extras: tuple[str, ...] = ()) -> str | None:
    # A known part number is enough. Skip the looser search when it hits.
    for extra in extras:
        found = _footprint_for_candidate(client, query, extra)
        if found:
            return found
    for candidate in _candidates(client, query):
        found = _footprint_for_candidate(client, query, candidate)
        if found:
            return found
    return None


def _footprint_for_candidate(client: Any, query: str, candidate: str) -> str | None:
    data = client.cse_get_kicad(query=candidate).data
    name = _footprint_name(data)
    if name and _acceptable(query, data):
        return name
    return None


def _acceptable(query: str, data: dict[str, Any]) -> bool:
    wants_connector = any(
        word in query.lower()
        for word in ("receptacle", "holder", "socket", "jack", "header", "connector", "slot", "magjack")
    )
    if not wants_connector:
        return True
    blob = " ".join(str(data.get(key) or "") for key in ("description", "mfr_part_number", "kicad_footprint")).lower()
    return any(hint in blob for hint in ("connector", "receptacle", "jack", "holder", "socket", "header", "battery"))


def _candidates(client: Any, query: str) -> list[str]:
    ordered = [query]
    search = client.jlc_search(query, limit=1)
    model = _first_model(search.data)
    if model and model not in ordered:
        ordered.append(model)
    # A bare word such as "connector" matches an unrelated model. Keep a token
    # when it contains a digit, or when it is a connector family the catalog indexes.
    families = {"RJ45", "HDMI", "SATA", "DIMM", "USB", "PCIe", "CR2032", "M.2"}
    tokens = []
    for tok in query.replace("/", " ").split():
        if tok in families or (len(tok) >= 4 and any(c.isdigit() for c in tok) and any(c.isalpha() for c in tok)):
            tokens.append(tok)
    tokens.sort(key=len, reverse=True)
    for tok in tokens:
        if tok not in ordered:
            ordered.append(tok)
    return ordered


def _first_model(data: Any) -> str | None:
    row = data
    if isinstance(data, dict):
        rows = data.get("results")
        row = rows[0] if isinstance(rows, list) and rows else data
    if isinstance(row, dict):
        for key in ("model", "mpn", "mfr_part_number", "lcsc"):
            value = row.get(key)
            if isinstance(value, str) and value.strip() and value.strip() != "-":
                return value.strip()
    return None


def _footprint_name(data: Any) -> str | None:
    if not isinstance(data, dict) or data.get("error"):
        return None
    raw = data.get("kicad_footprint")
    if not isinstance(raw, str):
        return None
    for token in ('(module "', '(footprint "'):
        at = raw.find(token)
        if at >= 0:
            rest = raw[at + len(token):]
            name = rest.split('"', 1)[0].strip()
            return name or None
    return None
