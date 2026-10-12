# mbsim

The Unreal editor project lives in this cva6 tree at `mbgen/mbsim/MbgenSim`. It is generated. It is not authored by hand.

```text
mbgen open
```

That launches `UnrealEditor.exe` on `mbsim/MbgenSim/MbgenSim.uproject` when Engine 5.8 is on the machine.

```text
mbgen build --config builder.json
```

`builder.json` chooses the **outline** template (`mini-itx`, `matx`, `atx`, `pico-itx`, `pcie-card`), the config package, the Unreal version, and the output directory. The default writes `mbsim/MbgenSim`. Pin/net/path simulation is board-agnostic (`architecture/board-types.md`); swapping the template does not fork `route` or `auto_connect`.

That directory is a project the editor can open:

- `MbgenSim.uproject` enables the Python editor plugin and the procedural-mesh plugin.
- `Source/MbgenSim` is the runtime module. The board actor is scaled 20 times so a 1 mm pin pitch is 2 cm. PCIe and DIMM contacts are spring necks with a raised contact head at that pitch. Wheel zoom is 4 percent per notch times mouse sensitivity (default 0.25), clamped to one notch per event, and keeps camera yaw/pitch (no roll spin). Laws live in `mbcore/src/nav.rs`. `RebuildFromDesign` on the actor reloads `Content/Boards/scene.json`.
- `Content/Textures` holds the PBR maps: solder mask, brushed metal, plastic, gold, ceramic, the hatched gap texture, and a solder-mask normal. Silk courtyards are labeled roles only (CPU, DIMM, SODIMM, PCIE, CEM, NVME, WIFI, USB, LAN, HDMI, DP, DC, SATA, BAT), including live roles `gbe_magjack` and `rtc_battery`. Open-field pads sit on every sixth 32-pixel cell. Mesh extras key off `role`; `usb_c` stays a hatch. The IO shield windows follow live jack poses (`dp` and `dc_jack` included) and stay off when the outline has no I/O window. Mini-ITX mounting holes stamp only on a 170 mm PCB. `sodimm` shares DIMM springs; `wifi_m2` shares M.2 fingers; `pcie_cem` is a gold contact strip. Selecting a socket by role opens the processor window.
- `Content/Python/mbgen_materials.py` runs when the editor starts and builds one lit `MSlot_*` material per slot. Facing falloff is `(N·up)^2`. Mesh sections bind those assets. Until that script has run, the actor still draws the board with vertex colors from the same slots. The script uses editor subsystems (`UnrealEditorSubsystem`, `EditorActorSubsystem`, `LevelEditorSubsystem`).
- `Content/Meshes/board.gltf` is the same scene for an importer. glTF is Y-up. The actor uses the Z-up `scene.json`.
- `Content/Boards` also holds `platform.json`, `firmware.json`, `board.net`, `design_skidl.py` from the compile, plus `packages.json` (processor cards) and `library.json` (role palette: support, domain, optional MPN/LCSC, hatch, CEM/SATA contracts). `wifi_m2` carries a `radio: wifi` label; USB-C is a Gap row and is not on the default Mini-ITX. Compile also writes `product/nets.json`, `product/paths.json`, and `product/errors.json`, and copies the firmware/platform witness into `Content/Boards`.

## Controls

F frames the orbit on the PCB centre. BeginPlay, Play StartPlay, SetOutline, and the Python startup aim do the same. Name plaques face that overview look-from. Place hits the live PCB top from the scene AABB. Product close-ups in `mbgen_materials.py` aim from `scene.json` body centres and skip a part that is not on the live preview. Play overlay panels (Parts, Board, Processor, Properties) drag from the title text. Play and the editor orbit around the point under the cursor on right-drag (CATIA-style). Left-drag on empty space (PCB, shield, or miss) turns the camera in place: yaw and pitch are angles from the camera-to-click line. Empty picks use a mathematical rest plane under the board (1.5× pad, z=PCB bottom), not a mesh and not an infinite plane. Mouse-wheel zooms toward that point along the pick ray and keeps the current look (horizon roll stays 0). Default mouse sensitivity is 0.25 so an overview stays in frame. `cargo test -p mbcore --lib nav` covers the CATIA laws. A right-click without drag selects the part under the cursor (if any) and turns it 90° around the board normal. Drag a part to Place it. Arrow keys Place the selection on the board plane (X and Y from the 0,0 corner); Z stays sit-on-PCB. Properties show yaw and a Turn 90° control. Name plaques share the part tag so a live Place drag moves them with the body. Properties X/Y use the Settings unit (µm/mm/cm/m/mil/inch); Enter applies Place. Top-right Settings and Props icons open panels under the bar; Undo/Redo/Save/Open/Copy/Paste sit beside them. Ctrl+Z/Y undo/redo keep the camera; Ctrl+O frames the PCB centre. Ctrl+S save, Ctrl+C/V copy/paste through Saved/mbgen.sqlite. Mouse sensitivity scales look, orbit, pan, and zoom. Arrow keys stay 1 mm / Shift 0.1 mm. Left click selects a part. Drag on the live PCB top (from the scene AABB) sends `Place` at up to 10 Hz: `x_um = round(local.X / 0.0001)`. The mesh does not move until `preview` returns `applied`; then every reflowed body is translated (a `usb0` Place moves `hdmi0` when pack reflows it). Mouse-up and discrete gestures (Add / Copy / Delete / SetProperty / compile) full-rebuild. Del deletes the selection (`pcb` and `shield` stay) and returns the property sheet to Select a part. Ctrl+left click copies along the edge and selects the new part. Arrow keys nudge by 1 mm, Shift by 0.1 mm. Discrete Place / Nudge / Delete refresh the open property sheet. A rejected gesture leaves the meshes where they were. Select opens the property sheet in editor and Play (P toggles it) and logs `mbgen selected`; socket select also opens the processor window. read-only Support/domain, interface combo (role contracts only), `radio: wifi` label on `wifi_m2`, no pin combo on USB or the socket, Auto-connect for CEM/SATA rails only; those contract names are a read-only list on the sheet. The selected part paints EdgeS and courtyard snap ticks from `mb_anchors` (`mbgen anchors id= n= src=mbcore`). The socket sheet has a PackageCard combo. The same board-level block appears on the empty sheet and on any part when the design has no socket. (`SetProperty package_id` from `packages.json`) plus read-only ISA/cores/OoO/L2/L3/AI, editable firmware witness `hotkey` / `timeout_ms` / `product` (no CSRs), and firmware peripherals with `base` empty. C still opens the processor window; the live `package_id` is marked current. `package_id` applies through the selected part, the socket if present, or any remaining port (so a `pcie-card` without a socket still takes a package). Gap roles paint a quiet `GAP` badge; deleting the socket paints `SOCKET GAP` at the CPU sit (zero socket pins). SetOutline frames the orbit pivot on the PCB centre. T opens the board combo (`outlines.json`); the live `template_id` is marked current. A row sends `SetOutline`, re-packs on the new millimetre outline, and rewrites `T_Solder*` from that design (`mbgen textures wrote`). If the selected part is gone (socket on `pcie-card`), selection clears and the property sheet shows Select a part. Meshes drop the old solder material before the uasset is deleted so ATX 512×410 can replace Mini-ITX 512×512. Compile does not rewrite silk. L opens the parts palette (`library.json`); search filters role / MPN / LCSC / CEM-SATA contracts; click a row to `Add` and select the new part (missing name plaques are painted); drag a row onto the PCB top to `Add` then `Place` at the hit (`mbgen drop`). First palette open writes `library.json` from `mb_library_json` (`mbgen library json=mbcore`) then captures `Saved/Thumbnails/<role>.png` (`mbgen library thumbs first-open`); miss uses a role letter (hatched Gap rows). `SetOutline` recaptures thumbs if Parts is open, otherwise the next L recaptures from the new `scene.json`. C opens the processor window; a row sends `SetProperty` `package_id`. Enter compiles into `Content/Boards/product` (live preview meshes stay the editable scene; firmware/property sheets refill from the copied witness). Editor startup logs `mbgen product sections=` from that JSON without painting hidden expand parts. Camera world Z below the board midplane (1.6 cm at 20×) draws bottom copper; B toggles Bottom view from above (`mbgen bottom= cam= toggle=`).

## Gaps that stay empty

USB Type-A is a hatched D-gap with tongue and no `Pin` records. The CPU socket is an unnamed 1 mm land grid with zero named pins. HDMI and LAN mouths are decorative until a freeze **and** a footprint exist. `usb_c` and `wifi_m2` are `Support::Gap`. Firmware and SKiDL are witnesses; they do not invent those pinouts.

Distributor **names** (PCIe slot, SATA, front panel) may load from `mbcore/data/*.json` copied from the pcbparts cache. `dx_um` stays `None` until a KiCad footprint freeze. DIMM and NVMe have no EasyEDA names in cache, so they stay empty `NamesOnly`.

## Live routing contract

`UMbgenSettings` (`Config/Mbgen.ini`) keeps `LiveRouting=False`. Gestures always pack in mbcore (`preview` / `mb_apply`). They do **not** run A* unless `LiveRouting=1`.

When `LiveRouting=True`, after a **legal** gesture the actor calls `mb_route` on `mbcore_c`. Power/GND are rails with `paths=[]` until a Footprint exists. A* runs only for 2-pin nets that have pad XY (none on Mini-ITX today). Underside solders (`Hit.kind = Solder`) only if a footprint documents a drill.

DLL load (canonical; no `%PATH%`):

1. `ProjectDir/../../target/debug/mbcore_c.dll`
2. `ProjectDir/../../target/release/mbcore_c.dll` if debug is missing
3. Packaged: `ProjectDir/Binaries/Win64/mbcore_c.dll`

Build the DLL with `cargo rustc -p mbcore_c -- -C panic=abort` from `E:\cva6\mbgen`. UBT does not compile that crate. Stop `UnrealEditor` on `MbgenSim.uproject` before rebuilding the DLL once the editor holds it. If load fails, log `mbgen dll=exe-fallback` and keep `mbgen.exe preview`.

Actor tick stays off. 10 Hz Place is gated on the editor input preprocessor / Play controller. Logs: `mbgen dll=`, `mbgen LiveRouting=`, `mbgen reflow`, `mbgen nets=N open=K unroutable=U paths=P um`, `mbgen route dirty=D ms=M grid=250 paint_ms=P`. Editor rebuild loads the DLL so `mbgen dll=` appears without Play.

## Compile and ingest

`mbgen compile` / Enter write `nets.json`, `paths.json`, and `errors.json` next to `scene.json` under `Content/Boards/product/`. Compile paints NetError badges from `errors.json` even when `LiveRouting` is off. `mb ingest --from Content/Boards/platform.json` on the CVA6 build platform writes the selectable board and the package. It does not fetch vendor trees unless `--sync` is passed. Ingest does not consume Unreal meshes.

Unreal is not required to generate the project. Opening it compiles `MbgenSim` and the material graphs.
