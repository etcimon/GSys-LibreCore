# Board workspace — successor to the v1 pin-circuits plan

| Field | Value |
|---|---|
| **Status** | Active. Supersedes the continuation rules in `progress.md` ("do not re-plan pin-circuits") by explicit user decision; v1 history in `pin-circuits.md` is preserved, not rewritten. |
| **Plan of record** | `C:\Users\etcim\.devin\plans\plan-063f1c4f9478ad21.md` (eleven stages S0–S10). This file carries the repo-visible contracts and what has landed. |
| **Decisions** | Circuit simulation (ngspice) in the first complete release · Unreal Editor and standalone share one UI/navigation · the first manufacturing target is the **custom LibreCore SoC** (no carrier substitute) |

---

## Why a successor

v1 shipped a legal integer-µm preview, but three handoffs were lossy and could not be fixed by
footprints alone:

1. The processor window was a **literal table** (`catalog.rs::PACKAGES`) whose topology had drifted
   from `core/include/*_config_pkg.sv` — `g6lc64_ooo_server` advertised 4 harts, the RTL has 4 × 2;
   ISA strings and AXI widths had drifted too. `firmware.json` fed that number to the BIOS and
   `mb ingest` checked only that the config file **existed**.
2. Two navigation implementations (editor bridge, Play pawn) shared constants but not laws; the
   `include_str!` tests proved text identity, not behaviour. The recorded rim-clamp leftover was a
   pivot problem, not a camera problem.
3. Part identities were derived from live role counts, so a deleted id could come back; the live
   session had no revision, so a stale async result was indistinguishable from a fresh one.

## Contracts (binding for everything under `mbgen/`)

| Contract | Where it is enforced |
|---|---|
| **Generated, never typed.** Every core/thread/ISA/AXI fact the board exports is read from the config package and carries `source.path` + `source.sha256`. A field the reader cannot resolve marks the profile `unresolved`; it is never defaulted and never offered for selection. | `mbcore/src/profile.rs`; `mbcore/data/profiles.json`; `cargo test` `committed_profiles_agree_with_core_include` fails on drift |
| **Shared constants are read, not guessed.** `config_pkg::AiCfgIsland` etc. resolve by reading `core/include/config_pkg.sv`; without it the profile stays unresolved. | `profile::shared_constants`, `read_config_pkg_with` |
| **Ingest verifies, then writes.** `mb ingest` refuses a bundle whose `core.harts` or `core.source.sha256` disagree with the config package it located. Legacy bundles import with a warning. | `build-platform/src/tooling/coreProfile.ts`, `mb.ts::cmdIngest`, `test/core-profile.test.ts` |
| **One navigation law.** Pivot pick, look, orbit, dolly and zoom distance are `mbcore::nav` functions reached through `mb_nav_*` (ABI v2). Both hosts call `FMbgenNav`; a missing DLL is a logged **reduced mode**, never a third implementation. | `mbcore/src/nav.rs`, `mbcore_c` `mb_nav_*`, `Source/MbgenSim/MbgenNav.{h,cpp}`, `unreal.rs::one_navigation_law_for_both_hosts` |
| **Empty-click pivot is never a rim corner.** Desk hit inside the finite pad, else a point on the cursor ray at the last focus depth. | `nav::pick_nav_pivot`, tests `empty_click_*`, `a_ray_that_misses_the_plane_keeps_the_focus_depth` |
| **Diagnostics are passive.** `DiagnoseNav` is a CallInEditor command; a click never runs the synthetic camera sweep. | `MbgenEditorBridge.cpp` mouse-down |
| **A drag ends under the cursor.** The release sample bypasses the 10 Hz gate (`PlaceSelectedAtRay(..., bFinal=true)`), then one rebuild. | actor, bridge, controller; `unreal.rs::a_drag_ends_under_the_cursor` |
| **Identity is monotonic.** `Design.id_seq` (schema 2) hands out ids per role; a deleted id is never reused, across reloads. v1 documents load and migrate. | `template.rs::allocate_id`, gesture tests |
| **Results carry their revision.** `mb_apply`, `mb_route` and `mb_circuit` return `revision`. A dirty `mb_route` carries **every** net and every surviving path plus `changed_nets`/`removed_nets`; it is never a subset. | `mbcore_c/src/lib.rs` (ABI v3), `route_returns_rails_with_empty_paths_and_dirty_routing_keeps_every_net` |
| **Refdes is persistent.** A component gets `C`/`J`/`U`/`Y`/`D`/`BT` + number once (`Design.refdes_seq`); copies, outline changes and reloads never reassign it. Scene bodies and `circuit.json` carry it. | `template.rs::assign_refdes`, `scene.rs`, `circuit.rs` |
| **One transform.** Pads, bodies, anchors and exports go through `geometry.rs` (`rotate_q`, `pad_world`, `body_z`); bottom side mirrors X and sits under the board. | `geometry.rs`, `scene::pose`, `net::anchors`, `route::terminal_of` |
| **The circuit is derived, never edited.** `circuit::resolve(design)` unions contract nets, explicit `Design.connections` and recipe connections into one snapshot; every disagreement is a `Diagnostic` with a rule id (`E-PIN-UNKNOWN`, `E-DOMAIN-CLASH`, `E-PIN-MULTI-NET`, `E-NC-CONNECTED`, `E-OPEN-REQUIRED`, `W-PASSIVE-OPEN`, `W-NET-NO-SOURCE`). A pin is on one net. | `circuit.rs` tests |
| **No invented pins.** A capacitor has two terminals by part class (`PinSpec::TwoTerminal`); everything else still waits for a frozen pinout. SATA grounds 1/4/7 are `GND` exactly as `interfaces.py` wires them. | `net.rs` |
| **Recipes are real parts.** `decap_per_rail` proposes components + connections (`Proposal`), applies atomically, reuses what its `CircuitBlock` already `owns`, shows removals, and only applies to a host that declares power contracts. Deleting the host removes exactly the owned parts. Compile no longer invents floating capacitors. | `recipes.rs`, `gesture.rs` (`expand_recipe`/`remove_recipe`/`connect`/`disconnect`/`no_connect`/`set_part`/`flip`), `export.rs::decoupling_in_the_bundle_comes_from_recipe_blocks_with_wired_terminals` |
| **Routing is deterministic and layer-aware.** A* over `(x, y, layer, heading)` with an admissible Manhattan heuristic to a pad, Dijkstra for tree joins; SMT bodies block their own layer only; other nets' copper and pads are obstacles; exact pad µm at both ends; same inputs → byte-identical paths; a search budget turns a hang into `Unroutable`. Rails stay `paths = []` until a plane plan exists. | `route.rs` tests (12), incl. `routing_is_deterministic_and_within_budget_on_a_mini_itx_grid` |
| **Incremental routing keeps clean paths.** A net is dirty when it touches a changed part or a moved body's keep-out crosses its previous path; everything else is kept byte-for-byte. | `route::route_incremental`, session `dirty_parts` |
| **The bundle is complete or absent.** `mbgen compile` writes every file then `manifest.json` last with a sha256 per file; `mb ingest` refuses a bundle whose files do not hash as declared, and copies `circuit.json`/`layout.json` only when verified. | `export::Bundle::manifest`, `mbcompiler::write_bundle`, `build-platform/src/tooling/mbBundle.ts` + tests |
| **SKiDL is lossless and counted.** `corev-mb/lib/circuit.py` builds one SKiDL part/pin/net per circuit entity with the same ids; no-connects come only from `circuit.no_connects`; ERC counts come from `skidl.erc_logger` counters; findings are mapped back to mbgen ids; the netlist is read back (s-expression parser) and compared (`parity`). `mb design` fails on an ERC error, a netlist failure or a parity mismatch. | `corev-mb/lib/circuit.py`, `soc.py::_build_from_circuit`, `corev-mb/tests/test_circuit.py` |
| **Simulation is explicit and revision-bound.** Scenarios are checked-in JSON (models, sources, analysis, measurements with ranges); the deck lists what it could not model; results are `pass`/`fail`/`incomplete` with sha256 of circuit, scenario and deck and the simulator version. No ngspice → `incomplete`, never `pass`. | `corev-mb/lib/simulation.py`, `simulate.py`, `mb simulate`, `test_simulation_pcb.py` |
| **Manufacturing is gated.** `pcb.manufacturing_gate` needs ERC, SKiDL parity, layout contract (placement + frozen footprint per populated part), PCB DRC and PCB parity — a missing report is a blocker. `kicad-cli` is discovered, never assumed. | `corev-mb/lib/pcb.py` |
| **A drag can be cancelled.** Mouse-down snapshots the design (`BeginPlaceDrag`); Escape restores it with no undo entry (`CancelPlaceDrag`); every sample of a gesture resolves against the viewport it started in (`GGestureViewport`). | `MbgenBoardActor.cpp`, `MbgenEditorBridge.cpp`, `MbgenPlayerController.cpp`, `unreal.rs::a_drag_can_be_cancelled_…` |
| **The SoC package is an input document.** `mbcore/data/soc_package.json` lists package, ball map, I/O banks, rails/sequence, thermal, reset/clock/boot pins, interfaces, footprint. `soc_package::assess` reports every null/empty field by path; `approved` only when declared approved **and** nothing is unresolved. The report rides in `circuit.json`, `layout.json`, `manifest.json`, is one `I-SOC-PACKAGE-UNRESOLVED` info on the socket, and is a required input of the Python `manufacturing_gate`. | `soc_package.rs` tests, `pcb.py`, `test_simulation_pcb.py` |
| **An outline change is proposed before it is applied.** `propose_outline` names kept / re-edged (`from_edge → to_edge`) / dropped (with the reason, including parts owned by a block whose host is dropped) / stock added / blocks removed / nets losing pins; `set_outline` applies exactly that. `mb_outline_proposal` is read-only; the Board window previews it and offers Apply. | `gesture.rs::the_outline_proposal_names_every_drop_…`, `mbcore_c` test, `MbgenOutlineWidget.cpp` |
| **Rip-up is bounded.** When a kept path walls a dirty net off, kept paths crossing the dirty net's pad span are released and routing runs again, at most `RIP_UP_ROUNDS` times; a board that still fails reports `Unroutable`. | `route.rs::a_kept_path_that_blocks_a_dirty_net_is_ripped_and_both_route` |
| **Findings are visible where they are made.** The Issues panel (`I` in both hosts) lists `circuit.json` diagnostics with rule id and part/pin/net; a row selects its part; the summary states error/warning/info counts and the SoC package status. It refreshes once per committed gesture, never per drag sample. Labels paint the persistent refdes large and the id small. | `MbgenIssuesWidget.{h,cpp}`, `unreal.rs::both_hosts_show_the_same_issues_panel_from_mb_circuit`, `paint_labels.py` |
| **Results are bound to the circuit's identity.** `mb_circuit` / `mbgen circuit` report `circuit_sha256` (sha256 of the compact resolved circuit); the bundle manifest records the same value as `source_circuit_sha256` (and `circuit_sha256` for the compiled circuit with placeholders). The Issues panel reads `corev-mb/boards/*/outputs` (SKiDL/ERC issues, parity, `sim/*.json` with measurements) **only** for boards whose manifest matches the live hash; any other ingested board is one `stale` row. Both hosts show the same results because both read the same files through the same widget. | `export::circuit_sha256`, `mbcore_c` test `circuit_json_carries_…`, `MbgenIssuesWidget::ReadBackOutputs` |

## Landed in pass 3 (S2 close, S3 start, S6 rip-up)

- `soc_package.rs` + `data/soc_package.json` (draft; every field unresolved and said so).
- `propose_outline` + `OutlineProposal`; `mb_outline_proposal`; `mbgen outline-proposal` / `mbgen circuit` CLI fallbacks for hosts without the DLL.
- `route_nets` rip-up rounds over `route_pass`.
- `UMbgenIssuesWidget` in both hosts; `AMbgenBoardActor::{CircuitJson, OutlineProposalJson, EnsureSession, DllText}`; Board window previews proposals; labels show refdes.
- Python gate takes the SoC package report; 21 tests. Rust 121 + 11 + 25.

## Landed in pass 2 (S2 close, S4, S5, S6, S7/S8 foundations)

- `Design` v2 component fields: `Port.{refdes, part: PartRef{mpn,lcsc,footprint}, value, dnp}`,
  `Placement.side`, `Design.{refdes_seq, connections, no_connects, blocks}`; `geometry.rs`.
- `circuit.rs` resolved snapshot + diagnostics; `recipes.rs` (`decap_per_rail`) with
  proposal/apply/remove/disown; seven new gestures; delete cascades through blocks.
- `route.rs` rewritten (occupancy per layer, A*, reservations, tree joins, exact endpoints,
  incremental `Keep`); `Path.id`; `RouteResult.{changed_nets, removed_nets, grid_um}`.
- Bundle v2: `circuit.json`, `layout.json`, `manifest.json`; `mbcore_c` ABI v3 (`mb_circuit`,
  incremental `mb_route`, session `dirty_parts`/`last_route`).
- `corev-mb/lib/{circuit,simulation,simulate,pcb}.py`; `soc.py` takes the circuit path when
  `circuit.json` is present; `corev-mb/tests/` (21 tests; live ngspice/kicad tests skip when absent).
- `mb ingest` bundle verification; `mb simulate`; `motherboard.simulation` config.
- Verified end to end: mini-itx → `expand_recipe` → compile → ingest → `mb design` (0 ERC errors,
  parity ok, 4 nets) → `mb simulate` (deck generated; `INCOMPLETE: ngspice not found` on this host).

## Landed in pass 1 (S0–S2 groundwork)

- `Design` schema 2: `schema_version`, `id_seq`, `allocate_id`, `migrate`.
- `mbcore_c` ABI v2: `mb_abi_version`, `mb_session_revision`, revision on apply/route, `mb_nav_*`.
- `FMbgenNav` shared host helper; pawn rewritten around explicit camera / forward / pivot state;
  editor bridge calls the same functions; UBT build of `MbgenSimEditor` succeeded.
- `mbcore/src/profile.rs` + `mbgen profiles --core-include DIR --out FILE`; 33 profiles, 33 qualified
  from the current tree; `PackageCard` is now a view over qualified profiles (`core_ua` kept only as
  a labelled preview heuristic).
- `firmware.json` / `platform.json` carry `harts` from the package and `source` provenance.
- `mb ingest` cross-checks `core.harts` and `core.source.sha256` before writing.

## Next (by plan stage)

- **S1** remaining: Editor/standalone event-replay comparison (behaviour, not strings).
- **S2**: fill `soc_package.json` from the approved package data when it exists (the reader and gate
  are in place); nothing else open.
- **S3** remaining: library exact-part search (pcbparts cache), pin/net explorer, recipe `Proposal`
  preview panel, running `mb design` / `mb simulate` from the hosts, waveform plots (today: per-
  measurement rows with pass/OUT).
- **S4**: more verified recipes (power entry / regulator, reset, clock, boot flash) — each needs a
  frozen pinout for its IC; the host side (`Proposal` preview panel, "apply as one undo") is UI work.
- **S5**: pin *functions* for frozen distributor pinouts (today 146 slot contacts are honest
  `W-PIN-OPEN-UNKNOWN-FUNCTION`); a rail *source* class so `W-NET-NO-SOURCE` can clear.
- **S6**: pad geometry (`PinSpec::Footprint`) from `cse_get_kicad` freezes so production nets get
  terminals; plane/zone plan for rails; host paints by `Path.id` with `changed_nets` instead of
  wholesale.
- **S7**: ngspice on the build host (`probe` / `tools install`) so the live tests stop skipping;
  tran/dc scenarios for reset and power-up once a regulator recipe exists.
- **S8**: a `.kicad_pcb` writer from `layout.json` (needs footprints), then `pcb.run_drc` /
  `export_manufacturing` behind `manufacturing_gate`.
- **S9/S10**: visual fidelity and packaging as in the plan of record.

## Known gaps recorded, not hidden

- `mbgen/**` is unclassified in `.licensing-tiers` (falls to the default `U **`) although the
  workspace declares MIT and is first-party. New files here carry the MIT header; the tier map
  itself was **not** edited by this pass — a policy decision for the maintainer.
- The processor window now lists every qualified profile on disk (33, including cv32 targets);
  an xlen/board-class filter belongs to S3.
- No approved custom-SoC package/pad map exists in the tree; manufacturing qualification of the
  LibreCore board stays blocked on that input (plan §5).
- No production role has pad XY yet, so `paths.json` is still empty on every outline; the router is
  exercised by injected-terminal tests only. Every component in the bundle has `mbgen:unresolved`
  as its footprint and the manufacturing gate reports that.
- ngspice and kicad-cli are absent on this host; `mb simulate` honestly returns `incomplete` (exit 4)
  and the KiCad bridge is exercised by pure tests only.
- Readback is by file: the hosts do not run `mb design` / `mb simulate` themselves; a result appears
  after the CLI has produced it and is shown only while the live circuit still has the identity it
  was produced from.
