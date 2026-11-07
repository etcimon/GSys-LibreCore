# Native graphics raster stage

Status: implemented, host-native-model evidence only.  No fragment-shader
consumption of generated records, ROP/framebuffer write, `vkCmdDraw*`
submission, capset advertisement, RTL, CTS, Linux or physical qualification
is claimed or enabled.  Draw records still fail replay admission atomically;
zero capsets remain advertised.

## Scope

`corev_apu/apu/tools/vn_graphics_raster.py` adds the rasterization stage as
an executor runtime operation between vertex shading and fragment shading:

- `Raster` — frozen operation carrying the immutable VS-out record image
  (`vary`, bytes, `count * 144`, `3 <= count <= MAX_RECORDS`,
  triangle-aligned), the viewport tuple `(x, y, w, h, minz, maxz)` floats,
  the scissor tuple `(x, y, w, h)` ints, `count` vertices, `flat`/`nopersp`
  8-bit varying-location masks, `front_ccw` and the `cull` bitmask
  (1 front, 2 back).
- `RasterRuntime` — cooperative `advance(budget)`:
  1. per triangle performs the golden-mirrored integer setup: f32 viewport
     transform (`fma`-shaped like the fpnew chain), F2I RNE to 16.8 fixed
     point, 64-bit edge functions at pixel centres (`px*256+128`), the
     top-left rule, pre-swap-area cull decision and front-facing resolution
     exactly as `vn_golden.gfx_tri_coverage`;
  2. emits one 144-byte FS-in record per covered pixel in row-major order:
     slot 0 = `FragCoord {px+0.5, py+0.5, z_win, 1/w_clip}` with
     perspective-correct window z and the `1/w` denominator, slots 1..8 =
     varyings at locations 0..7;
  3. interpolation: `flat` locations copy vertex-0 attribute bits
     verbatim; `nopersp` locations interpolate linearly in screen space;
     all other locations use perspective-correct
     `sum(lam_i * A_i / w_i) / sum(lam_i / w_i)` in f32;
  4. yields after `PIXEL_QUANTUM` (16384) pixel-centre tests per turn and
     resumes mid-triangle via `emit_ctx`, so large primitives make bounded
     cooperative progress;
  5. coverage is bounded to the viewport rectangle intersected with the
     scissor; primitives are assumed inside the view volume (bounded
     profile: no clip-plane generation, `w <= 0` or non-finite vertices
     mark the triangle degenerate).
- `TransferExecutor` accepts `Raster` beside `Compute`/`Fetch`/`Shade`/
  `FragmentShade`; `_turn` retires it with
  `job.raster_stats[op] = {records, steps, triangles, culled, degenerate,
  tests, robust}`.

## Budgets and faults

- `MAX_FRAGMENTS = 32768` covered pixels per operation (also clamped to the
  scissor area); exceeding it faults the job — a truncated fragment image
  is never published.
- `PIXEL_QUANTUM = 16384` pixel tests per cooperative turn;
  `MAX_RECORDS = 1024` vertices per operation.
- Record image is caller-supplied immutable bytes; the runtime generates
  records internally and holds no memory owners (`owners = {}`).

## Raster+fragment composite

`RasterShade` / `RasterShadeRuntime` chain the two stages inside one
executor operation, mirroring how `Shade` wraps `Fetch`: the runtime
drives `RasterRuntime` to completion, then lazily constructs a
`FragmentShade` operation over the generated FS-in image and a
`FragmentShadeRuntime`, delegating `advance`/`done`/`color`.  Executor
stats land in `job.rastershade_stats`.

Constraints of the composite:

- The fragment module is scanned at admission: Fragment execution model,
  no descriptor decorations, `batch` bound — identical to `FragmentShade`.
- Helper-invocation lanes are never generated (bounded raster emits none),
  so `helpers` is always zero.
- `FrontFacing` is a per-work-record scalar in the current ABI.  When the
  fragment module declares a `FrontFacing` input, all emitted primitives
  must share one facing (tracked per triangle in `raster.fronts`) or the
  job faults with `mixed front-facing exceeds native profile`.

## Evidence

- `test_vn_graphics_raster.py` (9 tests): coverage set equality against the
  independent `vn_golden.gfx_tri_coverage` oracle on 8x8 and 200x200
  viewports, perspective interpolation value check, `w != 1` FragCoord.w,
  flat bit-exact copy, scissor/cull bounding, degenerate and `w <= 0`
  skips, multi-turn bounded progress, fragment-budget job fault and
  admission refusals.
- Frozen native cohort `native-raster-02`: 600 tests PASS,
  `sources_unchanged: true`; `PASS: host-native-model; no RTL/CTS
  qualification`.
- `RasterShade` composite: 3 further tests (end-to-end color passthrough
  with interpolated-value spot check, mixed-facing fault + uniform-facing
  pass, stage/descriptor refusals); cohort `native-rastershade-01`.

## Not claimed

FS-in consumption by `FragmentShade`, lines/points/patched primitives,
clip planes, multisample, depth/stencil, blend and all ROP/writeback to
attachments, `DrawPlan` -> operation conversion, `vkCmdDraw*` replay,
descriptor bindings for graphics stages, synchronization, capsets, CTS,
RTL and physical qualification all remain open.  This stage is reachable
only as an executor runtime operation from native tests; no wire command
produces it yet, and its output records are not yet consumed by a shading
stage inside the executor.
