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
| **Results carry their revision.** `mb_apply` and `mb_route` return `revision`; `mb_route` also says `dirty_only` so a filtered result is never mistaken for the full set. | `mbcore_c/src/lib.rs`, `mb_session_revision` |

## Landed in this pass (S0–S2 groundwork)

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

- **S1** remaining: capture the initiating viewport for a whole gesture; Escape cancels a drag;
  Editor/standalone event-replay comparison (behaviour, not strings).
- **S2** remaining: `Design` v2 component instances with footprint/side/rotation; shared geometry
  (`geometry.rs`); outline migration proposals; the custom-SoC package contract as an input file.
- **S3–S10**: shared workspace UI, circuit model + recipes, lossless SKiDL adapter, real A* with
  layer-specific occupancy and net reservations, ngspice runner, KiCad bridge, visual fidelity,
  packaging — as in the plan of record.

## Known gaps recorded, not hidden

- `mbgen/**` is unclassified in `.licensing-tiers` (falls to the default `U **`) although the
  workspace declares MIT and is first-party. New files here carry the MIT header; the tier map
  itself was **not** edited by this pass — a policy decision for the maintainer.
- The processor window now lists every qualified profile on disk (33, including cv32 targets);
  an xlen/board-class filter belongs to S3.
- No approved custom-SoC package/pad map exists in the tree; manufacturing qualification of the
  LibreCore board stays blocked on that input (plan §5).
