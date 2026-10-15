# Live sim (Unreal 5.8 preview)

| Field | Value |
|---|---|
| **Status** | Landed on `E:\cva6` master (`df9aff1`) |
| **Kernel** | `mbcore` integer µm; Unreal paints at 20× (`ToCm` 0.0001) |
| **Nav laws** | `mbcore/src/nav.rs` |

---

## Split

- **mbcore** owns legality and millimetre arithmetic.
- **Unreal** paints. Canonical C++/Python live under `mbsim/MbgenSim/Source/MbgenSim` and `Content/Python`.
- **mbcompiler** `src/unreal.rs` `include_str!`s those files so dual-source tests fail if C++ drifts.
- Gestures go through `mb_apply` on `mbcore_c` when the DLL loads; `mbgen.exe preview` is fallback. The actor does not Tick. Rebuild only when `applied` is true.

Do not invent USB / CPU-socket / HDMI / PHY pinouts or MMIO. Do not upgrade the GND-only compile stub unless asked.

---

## CATIA navigation

| Input | Behaviour |
|---|---|
| Right-drag | Orbit around the pick (mesh hit, else rest plane) |
| Right-click, no drag (>8 px is a drag) | Select the part under the cursor and `Turn` 90° around Z; empty click turns the current selection |
| Wheel | Dolly along the pick ray; yaw/pitch kept; roll 0 |
| Left-drag on a part | `Place` on the PCB top (XY from 0,0; Z sit-on-PCB) |
| Left-drag on empty (PCB, shield, miss) | Look in place: yaw/pitch from the camera-to-click line; camera location stays |
| Middle-drag | Pan |
| Alt+left | Orbit (same as right-drag) |

Constants (`nav.rs`, copied in Unreal):

- `ZOOM_RATIO = 1.04`, `WHEEL_NOTCH_LIMIT = ±1`, `DEFAULT_SENS = 0.25`
- Orbit 0.12°/px yaw, 0.10°/px pitch; pitch ±85°; roll 0
- Distance clamp 20–8000 (preview cm)

`PinView` on the editor client: `ToggleOrbitCamera(false)`, set rotation, **then** set location, `SetLookAtLocation(LookAt, false)`. Look-at on empty look is `GNavPivot` from the rest-plane pick, **not** `Cam + Fwd * Dist` (that walks the focus into empty space and looks like zoom-out). Play `AddLook` uses reconstructed `FRotator(Pitch, Yaw, 0)` as `PinnedFwd` so `PlaceCamera` stays put.

Wheel: `ClampWheel` ±1, `ZoomDistance` with `1.04^sens`. sqlite `sens_law=catia` seeds 0.25 once; later user values persist. Cursor Place is 1:1 millimetre. Arrow keys Place 1 mm / Shift 0.1 mm (not scaled by mouse sens).

Tests: `cargo test -p mbcore --lib nav` and `unreal::catia_nav_source_tests` in `mbcompiler`.

---

## Mathematical rest plane

Empty nav picks use **math only**. There is no desk mesh (a painted pad stole traces and broke part selection / anchors).

- `DESK_PAD = 1.5`, z = PCB bottom (`PcbBotCm`)
- `hit_desk` / `AMbgenBoardActor::HitDeskWorld` clamp XY to that rectangle so a shallow ray never runs to infinity
- `PickNavPivot`: editable part hit, else `HitDeskWorld` under the cursor, else last `GNavPivot`
- Place still uses the live PCB top (`HitWorldOnBoard` / `BoardPlaneUm`)
- Live Mini-ITX section count without a desk body: **144**

Cause of the old slam: unbounded PCB-plane pick sent the pivot kilometres away. Diagnose: `desk_pick_does_not_run_to_infinity`.

FOV on the editor perspective client is Unreal’s default **90°**. Product captures use ~55°. A look-in-place at 90° can *look* like zoom-out (board slides off-centre) even when `look_moved = 0`. Empty click with the cursor off the PCB clamps to the pad **rim**.

---

## DiagnoseNav (viewport bridge)

`AMbgenBoardActor::DiagnoseNav` (CallInEditor) → `FMbgenEditorBridge::DiagnoseNav`.

Reads the live `FLevelEditorViewportClient` after draw: cam, rot, look-at, `ViewFOV`, `ShouldOrbitCamera`, `GNavPivot`, `HitDeskWorld` along view and cursor, distances, `recede` (`d_look` > 1.25× both `d_desk` and `d_pcb`). Draws the rest-plane rectangle and cam→desk / cam→look rays (`DrawDebug`, no collision). Writes `Saved/mbgen-navdiag.json`. Empty left-down look also calls it.

Sweep (then restore): `LookViewport(240, -180)` then a synthetic 24°/12° orbit. JSON fields `look_moved`, `look_d1`, `orbit_moved`, `orbit_d1`.

Python `diagnose_nav()` in `Content/Python/mbgen_materials.py` calls `DiagnoseNav` then SceneCapture2D from `UnrealEditorSubsystem.get_level_viewport_camera_info` to `Saved/mbgen-navdiag.png`. Do not use `FrameViewport` high-res shot for this (PIE can steal it).

Measured after FrameOrbit on Mini-ITX: cam ≈ (392.6, 1.0, 185.2), look/pivot PCB (170, 170, 1.6), FOV 90, orbit off, recede 0, `d_pcb` ≈ 335. Look sweep `look_moved = 0`, `d_pcb` unchanged. Probe hit `slot0`.

---

## Place, Turn, selection

- `Place` stores optional `Placement.x_um` / `y_um`; Z stays sit-on-PCB (`1600 + sz/2` µm). Off-board AABB rejected. Board 0,0 is front-left actor-local.
- `Turn` increments `yaw_q` 0..=3. Pack width stays `port.width_um` (not yaw-swapped extents).
- Parse `yaw_q` with `TryGetNumberField` (default 0). Stale `scene.json` may omit the field.
- Incremental Place translates Root-attached meshes that carry the part `ComponentTag` (body + name plaques). Extras parented to the part mesh inherit the move. Turn full-rebuilds.
- `RebuildFromDesign` clears `SelectedId` when the id is gone from the scene.
- `FindLive(Hint)`: hint world, then PlayWorld, then editor world. Palettes and EditorBridge use it.

---

## Chrome and sqlite

`Saved/mbgen.sqlite` (UE 5.8 SQLiteCore): tables `settings`, `saves(name=board)`, `log(seq undo)`, `clip(id=1)`. Enable the plugin in the uproject and `MbgenSim.Build.cs`.

Undo after non-incremental gestures and `FinishPlaceDrag` (one step per drag). Seed/open snapshots only when `HasUndoLog()` is false. Ctrl+Z/Y keep the camera; Ctrl+O frames. Ctrl+S/O save/load; Ctrl+C/V clipboard (`yaw_q`, paste +2000 µm X).

Top-right chrome (`FMbgenChrome`): Settings, Props, Undo, Redo, Save, Open, Copy, Paste. Editor window width from `GetSizeInScreen`; Play from widget `GetDesiredSize`; 8 px inset.

Properties X/Y in the Settings unit from board 0,0; Enter Place. Yaw display + Turn 90°.

---

## Compile vs live preview

`CompileBoard` writes `Content/Boards/product` and paints `NetError`. It must not rebuild the live actor from `product/scene.json` (hidden PHY/ESD stay off the editable preview). `place_board` logs `mbgen product sections=` from that JSON. Mini-ITX product body count ≈ 22.
