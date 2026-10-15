# mini-itx

Selectable custom board produced by `mbgen` (`E:\cva6\mbgen`) and ingested with `mb ingest`.
The machine file is `corev-mb/boards/mini-itx/board.json`. The schematic entry
is `design.py`, which calls `corev-mb/lib` `build_board`. Pin/net/path live-sim
architecture (catalog-backed names, no invented USB or socket pinouts) is
`E:\cva6\mbgen\architecture\pin-circuits.md`. Board outlines (ITX/ATX/PCIe card)
stay independent of that kernel: `E:\cva6\mbgen\architecture\board-types.md`.

The live package name in that file is `cv64a6_imafdc_sv39`. Vendor controllers
are requested with `enable: false`: `verilog-ethernet`, `hdmi`, `litedram`,
`litesata`, `verilog-pcie`. `gaps.json` defers both USB jacks and their ESD
parts. Those gaps are `MbGap_*` localparams in the generated board package.
They are not instances.

`mb select mini-itx` adapts the core config. `mb design mini-itx` runs the
SKiDL scaffold. `--sync` on ingest is what fetches a catalog id.

`mb ingest` now verifies as well as locates: a `platform.json` whose
`core.harts` (cores × threads) or `core.source.sha256` disagree with
`core/include/<config>_config_pkg.sv` is refused before anything is written.
mbgen fills both from its generated profiles (`mbgen/mbcore/data/profiles.json`,
read from the config packages). A legacy `platform.json` without those fields
still imports, with a warning that its topology was not verified.

The Unreal preview draws the board at 20 times true size. Scene coordinates
stay in micrometres. One millimetre of contact pitch is two centimetres in
the viewport, which is the resolution the picture is built for: a PCIe slot
is two rows of separate spring contacts, each a narrow neck and a contact
head, at a 1 mm pitch, plus a plastic retention clip at the open end. The neck widens toward that head. Both lips of the
DIMM channel use that same pitch, with the contact heads standing above
the channel. The M.2 2280 card is plastic with that pitch as gold fingers on both faces of the 22 mm edge and a plastic M-key in the row. The SATA plug
uses that pitch as data and power contact groups with a plastic key
between them. The HDMI mouth
uses that pitch along the board side of the opening. The LAN jack uses
that pitch on the same board-side lip. The processor window is a land
grid at that pitch counted from the well, with no named pinout. The
front-panel header uses that pitch as two rows of pin posts. Ceramic
packages 7 mm and larger use that pitch as gull-wing leads on both long
edges. Decaps under 5 mm get pin-material terminations wrapping each end onto the top, bottom, and sides. The DIMM connector is 133×10×8.5 mm and sits on the PCB. The PCIe x16 housing is 89×8×11 mm, in front of the socket. The M.2 2280 module is 22×80×4 mm along the left edge. PHY, crystal, and ESD join on compile (`expand_hidden`); the live editable preview keeps them off. ESD stays a hatched 4 mm gap with a metal courtyard outline. Every part sits on the 1.6 mm PCB and the Mini-ITX courtyards do not overlap. The three packages on the NVMe module use that same lead row. Name
plaques scale with the part so those contacts stay visible in the
product view. Long thin slots skip the plaque; the solder-mask silk names them. The coin-cell clip uses that pitch as a contact row on
the cell. The crystal has two pads at its base. The I/O shield is a metal frame around those openings (USB Type-A
12.5×5.2 mm, LAN 16×13.5 mm, HDMI 14×4.8 mm) so the jack backs show
through the plate. USB keeps a hatched body and a Type-A D-shaped metal bezel
(wider at the bottom, 12.5×5.2 mm opening) on both the I/O mouth and the board-facing side, with a plastic tongue in each mouth. HDMI has a metal shell on both the I/O mouth and the board-facing side. HDMI and LAN carry
a 1 mm contact row in both mouths, and each rear jack has a cavity on
both Y faces. LAN has a latch and green/amber LEDs on both faces. The editor and Play both orbit,
pan, and zoom around the PCB centre. One mouse-wheel notch changes the distance
by 12 percent. Middle-mouse drag pans. Alt and the left button, or the middle
and right buttons together, orbit. The right button alone orbits in Play.

## Preview behaviour (no invented pinouts)

The Unreal preview is a painter. Legality lives in `E:\cva6\mbgen` (`mbcore`).

- USB Type-A stays a hatched D-gap with a plastic tongue and **zero** `Pin` records. There is no USB host controller in the vendor catalog.
- The CPU socket stays an unnamed 1 mm land-pad grid. This README does not name those pads. Pin-per-pin socket view is not offered. Deleting it paints a `SOCKET GAP` badge at the CPU sit and leaves zero socket `Pin`s.
- HDMI and LAN contact rows in the mesh are decorative until a pcbparts freeze **and** a KiCad footprint exist.
- `mb parts --freeze-pinout` may copy **names only** for the PCIe slot (C426228), SATA (C7500843), and front panel (C492422). DIMM and NVMe have no EasyEDA symbol in cache, so they stay empty. Pad XY is not invented.
- CEM rails (`P12V` / `P3V3` / `P3V3_AUX` / `GND`) and SATA grounds `1` / `4` / `7` auto-connect as **rails** with empty `paths` until a footprint. DIMM `GND` / `VDD` / `VTT` strings are not auto-tied.
- `LiveRouting` defaults off. Compile writes `nets.json` / `paths.json` / `errors.json` under the product snapshot and copies firmware/platform into `Content/Boards`. `mb ingest` still keys on `platform.json` / `core.config`.

See `E:\cva6\mbgen\mbsim\README.md` for Place / Del / palette keys, Bottom view (B), and the cdylib load path.
