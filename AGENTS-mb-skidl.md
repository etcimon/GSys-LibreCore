# AGENTS-mb-skidl — corev-mb SKiDL board-design philosophy

The **PCB design-philosophy** for `corev-mb`, and the board-implementation
counterpart to `AGENTS-coding-philosophy.md` (which governs RTL). Where that
file turns a feature idea into synthesizable, timing-clean SystemVerilog, this
one turns a board feature into a **manufacturable PCB** whose SKiDL description
maps accurately to a real schematic and to the CVA6 SoC/uncore it serves.

- Workflow/governance: `AGENTS-motherboard.md` · Per-board contract: `AGENTS-mb-<id>.md` · SKiDL flow: `corev-mb/lib/`
- Not a board. `mb-skidl` is a **discipline**, not a `boardid` (there is no `corev-mb/boards/skidl/`).

> ### Scope + rules banner (read first)
> - **This is `.md` — out of licensing scope** per `AGENTS.md` §0.4. It changes no code.
> - **It binds the *implementation phase* of `custom` boards** (`board.json` → `"skidl":"custom"`,
>   the only mode `mb design` runs). Third-party/reference boards (e.g. `genesys2`, `"skidl":"omitted"`)
>   only **document** parts in `board.json.phys[]`; they are not authored here.
> - It is subordinate to the `AGENTS.md` §0 SoC prime directive and to `AGENTS-motherboard.md` §5 gates.

---

## 0. #1 Rule — USE THE TOOLS (pcbparts.dev + `mb`)

**Never invent an MPN, a pinout, or a footprint.** Every part, pin, and footprint comes from a
tool call; every claim is traceable to a datasheet. If a tool result looks empty you are almost
certainly offline — pcbparts.dev calls are **cache-first and network-gated**: pass `--online`
(TS client `PCBPARTS_ALLOW_NETWORK=1`) or you get `source:"stub"`. Don't freak out, don't
hand-fabricate; re-run with `--online`, or ask.

The 14 pcbparts.dev tools, grouped by how the board flow uses them:

| Phase | Tools |
|---|---|
| **Discover** | `jlc_search`, `jlc_search_help`, `sensor_recommend`, `board_search`, `cse_search` |
| **Inspect** | `jlc_get_part`, `jlc_get_pinout`, `board_get`, `mouser_get_part`, `digikey_get_part` |
| **Decide / fix** | `jlc_find_alternatives`, `jlc_stock_check`, `get_design_rules` |
| **Bring into SKiDL** | `cse_get_kicad` (symbol + footprint) |

**Part-selection priority (our analog of "prefer atopile packages"):**
1. **Reuse** an existing `corev-mb/lib/interfaces.py` template / a part already in `board.json`.
2. Parts with a **real KiCad footprint** available (`cse_get_kicad`) — no footprint, no part.
3. **In-stock, JLCPCB Basic/Preferred** parts (`jlc_stock_check`) to keep assembly cheap and reproducible.
4. Cross-referenced availability on Mouser/DigiKey (`mouser_get_part`/`digikey_get_part`) for supply resilience.
5. Only then a novel part — and record its datasheet in `board.json.references.vendorDocs`.

Drive it all through the build-platform: `mb parts --query "…" --online`, `mb select`, `mb design`,
`mb expand`, `mb test`. The CLI is the single control surface; the caching + provenance come for free.

---

## 1. Top-level design flow

Mirror of the atopile top-level loop, mapped to our stack:

1. **Research** the interfaces the board must expose (from `corev-mb/architecture/<id>/README.md`
   and the board's `board.json.interfaces`). Query candidates: `jlc_search`, `board_search`
   (find an OSHW board with the same SoC/interface set), `sensor_recommend` for management sensors.
2. **Inspect** the promising parts: `jlc_get_part` (specs/datasheet), `jlc_get_pinout` (pin map),
   `board_get` (a reference board's BOM + neighborhoods + rules).
3. **Propose** the part list + block architecture to the user; record the decision by editing
   `board.json` (`interfaces[]`, `phys[]`, `apu.controllers[]`). Revise on feedback.
4. **Acquire footprints**: `cse_get_kicad` for every chosen part; keep them with the design.
5. **Instantiate** in `corev-mb/boards/<id>/design.py` using `corev-mb/lib/interfaces.py`
   templates (`scratch_part`, `soc_placeholder`, `connector`, `build_from_spec`).
6. **Regenerate** the config + board package: `mb select <id>` (adapts `soc.*`, syncs uncore
   controllers, writes `<id>_board_pkg.sv`).
7. **Build the PCB view**: `mb design <id> --online` → SKiDL assembles + runs ERC → netlist/BOM.

> **After any change, always `mb design <id>`** to rebuild and re-run ERC (our `build_project`).

---

## 2. Power architecture

Board power is derived, not guessed. For **each** part (the CVA6 SoC/FPGA + every controller/PHY
in `board.json`) read its required rails and current from the datasheet (`jlc_get_part`); if
current is unlisted, estimate from the datasheet's typical/max and add margin.

**Rail planning:**
- Enumerate every distinct rail: core (`VDD`), memory (DDR `VDDQ`, `VTT`, `VREF`), transceiver/PHY
  rails, FPGA/IO-bank rails (`VCCO`), PLL/analog rails, USB/PCIe rails, and a management rail (3V3).
- **Tolerance** ~3-5% for digital rails; **tighter** for DDR `VREF`/`VTT` and PLL/analog (follow the
  datasheet). DDR `VTT` = `VDDQ/2` and must **track** `VDDQ`.
- Get the SoC/core view from `AGENTS-configuration.md` (voltage/power/thermal); the board must agree
  with it (that file is the SoC's view, the config packages are the core's view, `board.json` is the
  board's view — all three must agree).

**Input source + regulator decision tree** (the atopile rule, kept):
- Pick the input: barrel/`XT30` (embedded), **USB-C PD** (console/dev), or an **ATX/DC** feed for a
  desktop board (e.g. the Mini-ITX `milkv-jupiter` target). Add the connector part.
- **Regulator choice:** `Vin > Vout` & **low** current → **LDO**; `Vin > Vout` & **high** current →
  **buck**; `Vin < Vout` → **boost**; `Vin` may be above *or* below `Vout` (e.g. Li-ion → 3V3) →
  **buck-boost**. Query e.g. `jlc_search "buck converter 5A 1.0V"`.
- Battery is rare for these SBC/desktop-class boards (wall-powered); a **coin cell** for the RTC is
  common — add it, plus a charger only if a rechargeable pack is actually present.

**Sequencing & decoupling:**
- Define **power-on sequencing** (typically core before I/O; DDR `VTT`/`VREF` after `VDDQ`; PHYs per
  datasheet). Use enable chaining / a sequencer / PMIC as needed.
- **Decoupling** per rail: bulk near each regulator; high-frequency ceramics **at the BGA balls**.

**Example (custom desktop-class board):** 12 V DC in → buck 3V3 (I/O + management) + buck 1.0 V
(core) + DDR rail set (`VDDQ`, tracking `VTT`, `VREF`); USB-C for the serial console; coin cell RTC.

---

## 3. Communications / interfaces (SoC pin ⇄ board PHY)

The decisive CVA6 fact: an interface is an **on-die controller** (in `corev_apu`, AXI-attached)
plus a **board PHY**. SKiDL wires the SoC pins to the PHY; the controller lives in RTL.

| Interface | Controller (on-die, `vendor` id) | PHY / part (board) | Board bus |
|---|---|---|---|
| DDR3/4 | `litedram` / FPGA MIG | SODIMM/discrete + (FPGA) hard PHY | address/data/strobe |
| 1G Ethernet | `verilog-ethernet` / `ariane-ethernet` | RGMII PHY (e.g. RTL8211E) + magnetics + RJ45 | RGMII (4 pairs) + MDIO |
| PCIe | `verilog-pcie` / `litepcie` | SerDes hard IP; slot/M.2 | diff lanes + REFCLK |
| USB | *(gap — see architecture docs)* | ULPI/USB PHY or host controller | ULPI / diff pairs |
| SATA | `litesata` | SerDes + connector | diff pairs |
| SD/eMMC | `litesdcard` / AXI Quad SPI | slot + level shift | SPI / SD bus |
| HDMI | `hdmi` (TMDS) | connector + ESD/re-driver | TMDS diff pairs |
| UART | APB UART | USB-UART bridge (e.g. FT2232) | TX/RX |
| JTAG | `dmi_jtag` | header | TCK/TMS/TDI/TDO |
| Board mgmt | (I2C/SPI) | EEPROM/PMIC/temp sensor (`sensor_recommend`) | I2C/SPI |

**SKiDL idiom:** verify pins with `jlc_get_pinout`, then connect by bus:
`soc["RGMII_TXD"] += phy["TXD"]` (or `bus[i] += phy_bus[i]`). Group each interface as a
**hierarchical subcircuit** so the schematic reads like the block diagram.

**Reference clocks (do not forget):** 25 MHz for the Ethernet PHY, 100 MHz PCIe REFCLK (0.6 pF-class,
diff), 27 MHz HDMI TMDS clock, the SoC main clock, and a 32.768 kHz RTC crystal. Each is a part; each
has placement rules (§4).

---

## 4. Physical positioning — the ideal resulting PCB

SKiDL fixes **connectivity + footprints**; **geometry/placement is a KiCad step** downstream of the
generated netlist. This section is the placement *intent* the design must carry so the eventual
layout is manufacturable and signal-clean. Pull concrete numbers with `get_design_rules`
(stackup/clearance/impedance for the target class + layer count) and any `board_get` design rules.

**General placement order:** SoC first (center, under the heatsink region), memory hugging the SoC,
regulators near their loads, connectors at the board edges, clocks next to their sinks.

- **Decoupling:** HF ceramics **on the BGA ball field / as close as possible** to each power ball;
  bulk caps beside each regulator. Short, wide power paths; solid reference planes.
- **DDR:** shortest, **length/skew-matched** routing; **fly-by** topology for DDR3/4 with `VTT`
  termination near the far end; keep DDR away from switching regulators and clocks; match within byte
  lanes, then lane-to-lane per the SoC/PHY spec.
- **High-speed serial (PCIe / USB3 / SATA / HDMI TMDS):** **differential** 90/100 Ω, intra-pair
  length match tight, minimize vias and layer changes, continuous ground reference, **AC-coupling
  caps near the TX**, connectors at the **edge**; respect the slot/M.2 keepouts.
- **Ethernet:** PHY adjacent to magnetics then RJ45 in a straight shot; isolate the analog/chassis
  ground island; keep the 25 MHz clock local.
- **Regulators (esp. switchers):** tight input/output cap loops, thermal copper + vias, keep-out from
  DDR/clocks/analog; place away from sensitive nets.
- **Clocks/crystals:** immediately next to the load pins, ground guard, **no traces routed underneath**.
- **Connectors:** USB/HDMI/RJ45/power/M.2/PCIe/SD at board edges; honor the mechanical form factor
  (e.g. Mini-ITX outline + mounting holes for the `milkv-jupiter` target) and I/O shield/bracket zones.
- **Thermal:** SoC/hot regulators under airflow/heatsink; thermal vias; avoid crowding tall parts.
- **Planes/stackup:** dedicated power/ground planes; controlled-impedance layers for the diff pairs
  (from `get_design_rules`).

**Capturing intent (accuracy seam):** record placement/routing constraints in the board spec you
already have — `board.json` `interfaces[].notes` / `phys[].notes` + `references` — and in
`corev-mb/architecture/<id>/README.md`. A forward-looking optional `layout` block per interface/phy
(`{ zone, edge, lengthMatchPs, impedanceOhm, keepout }`) is the natural extension when the flow adds
KiCad placement automation; until then these live as notes and are applied during KiCad layout.

---

## 5. SKiDL ⇄ schematic accuracy

The whole point: the SKiDL source should read like, and generate, a correct schematic.

- **Named nets = schematic labels.** Name every meaningful net (`VDD_CORE`, `DDR_VREF`,
  `ETH_MDIO`); anonymous nets make an unreadable schematic.
- **Hierarchy = block diagram.** One SKiDL subcircuit per interface/domain (power, DDR, ethernet, …)
  so `generate_schematic` mirrors the architecture.
- **Every part is complete:** real **footprint** (`cse_get_kicad`), **refdes**, **value**, **MPN**.
  No placeholder that cannot be ordered or placed.
- **Power/ground are explicit nets** with a drive set (see `interfaces.build_from_spec` tying pin
  1/2 of each connector to `VDD`/`GND`) so ERC can reason about them.
- **Determinism:** parts + footprints come from tools, not from memory, so a re-run reproduces the
  same schematic/netlist. Emit `generate_netlist` (→ KiCad) and, where useful, `generate_schematic`.

---

## 6. Development process (the loop)

```
mb select <id>            # adapt core/uncore config + generate board package
mb design <id> --online   # SKiDL assemble + ERC   (add --fix for the alternatives loop)
   └─ read ERC → jlc_find_alternatives / jlc_get_pinout / cse_get_kicad → edit design.py/board.json → repeat
mb expand <id> --add pcie_x1:1,usb_host:2 --online   # grow the interface set, then re-`mb select`
mb test <id>              # verify the tandem core+board feature set (--run drives the RTL build)
freeze                    # jlc_stock_check + mouser/digikey cross-ref before committing outputs
```

- **Always `mb design` after changes** (our `build_project`); builds surface ERC errors/warnings —
  review and fix them, don't ignore warnings.
- The ERC→alternatives loop is bounded by `motherboard.pcbParts.maxFixIterations`.
- Generated artifacts (`generated/`, `outputs/`) are gitignored — they must be reproducible from
  `board.json` + `design.py` + tool cache, never hand-patched.

---

## 7. corev-mb code philosophy (ties to SoC readiness)

- **Controller ↔ PHY split is sacred:** the controller is RTL in `corev_apu`; the PHY is a board
  part. Never model a controller as a board part or vice-versa.
- **`board.json` is the source of truth;** `design.py` derives from it. Keep them consistent (a
  `mb expand` edits `board.json`, then you re-`mb select`).
- **Config-gated & optional:** `board.core` pins the CVA6 target config; do not design a board
  feature the core/uncore cannot drive — check the honest deltas in `corev-mb/architecture/<id>/`
  (e.g. RVV, multi-core, LPDDR4 PHY, USB3 are current CVA6 gaps).
- **Licensed vendor docs are cited, not copied** (`references.vendorDocs`); no NDA/paywalled content
  in-tree.
- **`.dts` ⇄ config ⇄ board alignment** for every Linux-visible interface (`AGENTS-dts-validation.md`).
- **SoC-readiness gates** (`AGENTS-motherboard.md` §5): ERC clean; SI/PI + power-sequencing notes for
  high-speed lanes; reproducible; core/uncore untouched by selection.
- **Tandem verification:** `mb test <id>` reports the combined core+board feature set — a board
  feature is only "done" when the RTL that drives it is present and tested too.

---

## 8. Per-domain quick playbooks

Each: *tools → part class → rails → key placement/routing rule → ERC gotcha.*

- **DDR3/4** — `jlc_search "DDR3L SODIMM socket"` / MIG; `VDDQ`+`VTT`(=`VDDQ/2`, tracked)+`VREF`;
  fly-by + length match; ERC: unterminated strobes / missing `VREF` divider.
- **Ethernet (RGMII)** — `jlc_search "gigabit rgmii phy"`, `jlc_get_pinout`; 1.0/2.5/3.3 V + AVDD;
  PHY→magnetics→RJ45 straight, 25 MHz local; ERC: MDIO pull-up, unconnected LED/PHYAD straps.
- **PCIe / M.2** — `jlc_search "PCIe x4 slot"`, `get_design_rules`; 3.3 V + 12 V (slot) + lane rails;
  90 Ω diff, REFCLK 100 MHz diff, AC caps near TX; ERC: missing PERST#/CLKREQ#, no AC coupling.
- **USB** — `jlc_search "USB 2.0/3.0 phy"` (controller is a current gap); 3.3/1.2 V; 90 Ω diff, ESD
  at connector; ERC: missing `RREF`, floating `ID`/`VBUS` sense.
- **HDMI** — `jlc_search "HDMI ESD re-driver"` (e.g. TPD12S016 class); 3.3 V + 5 V hot-plug; TMDS
  100 Ω diff, short from source; ERC: no `+5V`/HPD/DDC pulls.
- **SD/eMMC** — `jlc_search "microSD push-pull socket"`; 3.3 V (+1.8 V for UHS/eMMC); level shift;
  ERC: missing CMD/DAT pull-ups.
- **UART/JTAG** — `jlc_search "FT2232 USB uart"` / header; 3.3 V; near the edge/USB; ERC: swapped
  TX/RX, missing `TRST`/pull-ups.
- **Power** — `jlc_search "buck 1.0V 6A"` / LDO; per §2; tight loops + thermal; ERC: no feedback
  divider, `EN` floating.
- **Clocks** — `jlc_search "25MHz crystal"` / oscillator; part of the rail it serves; adjacent to
  load, guarded; ERC: missing load caps.

---

## 9. Board-feature implementation checklist (carry-over)

Confirm each before calling a board feature done, or state why it does not apply:

- **Tool-sourced:** every part's MPN/pinout/footprint came from a pcbparts.dev tool (`--online`), not memory.
- **Footprint-complete:** `cse_get_kicad` footprint + refdes + value assigned to every part.
- **Rails defined:** each part's rails + tolerances captured; regulators chosen by the §2 tree; sequencing noted.
- **Decoupling + planes:** per-rail decoupling and reference-plane plan recorded.
- **Signal integrity:** diff-pair impedance + intra/inter-pair length-match rules noted (from `get_design_rules`).
- **Placement intent:** connector/edge, DDR/high-speed, clock, thermal notes captured in `board.json`/architecture doc.
- **ERC clean:** `mb design` passes ERC (0 errors); warnings reviewed.
- **Sourcing:** `jlc_stock_check` (+ Mouser/DigiKey cross-ref) confirms availability.
- **Traceable:** datasheets/manuals cited in `references.vendorDocs` (cited, not copied).
- **Config-tethered:** `board.json.core` matches an existing CVA6 target; `mb check`/`mb test` pass; no core-unsupported feature.
- **Reproducible:** artifacts regenerate from `board.json` + `design.py`; nothing hand-patched.
- **Documented:** `AGENTS-mb-<id>.md` + `corev-mb/architecture/<id>/README.md` updated.

---

## 10. Cross-references

- `AGENTS-motherboard.md` — the `mb` configure flow, `board.json` schema, SoC-readiness gates.
- `AGENTS-coding-philosophy.md` — the RTL counterpart (this file is its PCB sibling).
- `AGENTS-configuration.md` — the SoC's voltage/power/thermal context the board must agree with.
- `AGENTS-corev-apu.md` / `AGENTS-core-platform-vendor-actives.md` — controller side of the split.
- `corev-mb/lib/` — the SKiDL flow (`soc.py`, `interfaces.py`, `erc.py`) + pcbparts client (`pcbparts_mcp.py`).
- `corev-mb/architecture/<id>/` — per-board development target + honest CVA6 gaps.
