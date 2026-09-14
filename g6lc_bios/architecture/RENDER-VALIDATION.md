# Render validation — pixel-accurate styling for `browser-ui`

Governance: `g6lc_bios/AGENTS.md` prime directives. Reference spec:
`kernel-spec/goosie` (MIT, read-only, never compiled). Feature inventory
schema: `@browserscore/supports` (MIT).

This document defines the **agent development methodology** for growing a
first-party CSS/layout engine (`g6b-css`) and proving its output is
pixel-accurate, without Chromium, Playwright, or a puppeteer bus.

## 1. The measurement problem (read this before trusting a score)

`@browserscore/supports` and `browserscore.dev` detect whether a runtime
**recognizes** a feature. The library's own mechanisms are:

| Namespace | Mechanism |
|---|---|
| `supports.css.property('display')` | `CSS.supports` / style-object probing |
| `supports.css.atrule('@layer')` | at-rule parse acceptance |
| `supports.js.global('Promise')` | global presence |
| `supports.html.element('search')` | element recognition |
| events | presence of an `on*` property, or a manual trigger |

`browserscore.dev` states the limit directly: *"This test checks which web
platform features the browser recognizes, not whether they are implemented
correctly."*

Two consequences bind this methodology:

1. **A recognition score is not a rendering-correctness signal.** It cannot
   detect a wrong margin, a mis-collapsed box, a bad cascade order, or an
   off-by-one raster.
2. **Self-scoring is circular.** If `g6b-css` answers its own
   `CSS.supports`-equivalent, the score is self-reported. A `supports()` that
   returns `true` for every input scores 100% while rendering nothing. Never
   treat our own detection answer as evidence.

Therefore recognition is used **only as a backlog**, and correctness is
established **only by golden-image diffs**. Track A says *what to build*;
track B says *whether it is right*.

## 2. Track A — feature inventory (backlog, not score)

Import the `@browserscore/supports` **feature list** (its test data is
essentially JSON) into `fixtures/css-features.json` as an ordered
implementation queue. Each row carries:

```
{ "id": "css.property.margin-inline",
  "kind": "property",
  "state": "planned | bounded | landed | refused",
  "fixture": "fixtures/render/margin-inline.html",
  "note": "..." }
```

Rules:

- `state` is set by **track B evidence**, never by a detection call.
- `refused` is a first-class outcome with a reason (out of BIOS scope, needs a
  GPU dependency, needs arbitrary JS). Refusal keeps the queue honest.
- The aggregate is reported as `landed / total`, and always labelled
  *"feature coverage, not correctness"*.

Track A never runs in the BIOS and never fetches the network. It is a
build-time checklist.

## 3. Track B — golden-image pixel diff (the correctness gate)

This is the gate that replaces goosie's Playwright/Chromium comparison, which
prime directive 6 forbids.

The BIOS already has a deterministic raster path:

```
g6b-css parse + cascade + layout  →  display list
        →  g6b-gr 4bpp/16bpp plane  →  Proxy::to_ppm  →  PPM bytes
```

`Proxy::to_ppm` is already exercised by the `gr_framebuffer` and `disp_scan`
regressions and is deterministic across `fit` / `fill` / `dpi` modes. So:

1. Each fixture renders to a PPM through the existing proxy path.
2. The PPM is compared per-pixel against a committed golden under
   `fixtures/render/golden/`.
3. A fixture declares a tolerance budget: `max_pixel_delta` and
   `max_changed_ratio`. Anti-aliased text gets a nonzero budget; solid box
   geometry gets zero.
4. Exceeding the budget **fails `bios_regress.py`**. There is no
   `UPDATE_SNAPSHOTS` escape hatch: a golden changes only in a commit whose
   diff artifact is reviewed and whose message states the intended visual
   change.

Because the raster is CPU and first-party, this gate is hermetic — no browser,
no network, no GPU, no render node. It runs in CI and on a WSL host with no
`/dev/dri`.

### Guest display-list parity (local plan review, 2026-09-14)

`g6b-kernel::tests::guest_display_list_matches_host_pixels` packs the shipped
cell's scene with `dl_pack`, then executes the emitted RISC-V `DlPaint` and
`VioPaint` for **every packed menu state at 640×480 and 1920×1080**. Its oracle
is an independent `BrowserSession::paint_css_at` result for the same menu and
geometry, not a readback of the guest buffer. It compares every visible RGB
channel with **zero tolerance**; the unused X byte of B8G8R8X8 is excluded.
No `WebFeed` pixel injection or `__web_pk` fallback is installed. Faults,
execution-limit halts, missing WEBDL, wrong geometry and unconsumed dirty tiles
fail the gate. This checks guest replay/transport equivalence, not independent
CSS conformance; the existing reviewed CSS goldens remain unchanged.

The `g6b-elf::tests::picking_bios_ui_replaces_the_picker_rows` integration gate
also runs the actual shipped guest JIT, packed routes and picker handoff at the
fixture's 1920×1080 output, and compares the committed device framebuffer against
the host scene.
It rejects a picker repaint after handoff. Old `DOM|` rows are not a web-frame
oracle: suppressing those rows is part of the face-ownership contract. This
whole-boot gate opts into `run_module_with_limit(..., 192_000_000)` and must
finish before the bound; other smoke callers retain their 48M default.

Both pixel gates run in `tools/bios_regress.py` as `guest_pixel_parity`, as well
as in workspace tests. They require neither a GPU nor remote g6q. Actual QEMU
capture parity and QEMU-GL/remote g6q evidence remain assigned to the other
session; local exec-model equality is not a claim of either.

`out/setup.ppm` (`g6b gr`) and `out/proxy.ppm` (`g6b display-proxy`) are
**legacy text-plane diagnostics**, not styled web screenshots. Their blue
background is deliberate. The former banner-only font incorrectly rendered
most characters as identical boxes; the host font now covers printable ASCII
with guest-matching uppercase folding, checked exhaustively against the guest
font. Repainting shorter text clears old cells. Use `ui-ppm32` at explicit
`--width`/`--height` for a styled host reference, or `smoke --out-vio` for device-side
exec-model pixels; neither is a QEMU capture. A `halt=Limit` smoke snapshot is
incomplete and must not be used as parity evidence; use the explicitly budgeted
integration gate for the full guest-JIT boot.

### Where OpenGL fits (and where it must not)

Correctness is defined on the **CPU raster**, which is the reference. The
`proxy.gl` / `virtio-gpu-gl-device` path is an *acceleration* of an already
verified image, so its obligation is to match the CPU golden within the same
budget — GL is validated *against* the CPU path, never used to define truth.
This keeps the gate runnable where no render node exists (see `DISPLAY.md`).

## 4. The agent iteration loop

For one feature row:

1. Read the ancestor: the matching `kernel-spec/goosie/internal/css` or
   `internal/renderer` locus. Understand the algorithm.
2. **Rewrite, do not port** (prime directive 1). First-party Rust in
   `crates/g6b-css`. No Go, no Fyne, no Goja.
3. Add the HTML/CSS fixture under `fixtures/render/`.
4. Implement until the layout unit tests pass.
5. Generate the PPM, inspect it, commit it as the golden **only** once it is
   visually correct by reading the geometry — a golden is an assertion, so a
   wrong golden is worse than no golden.
6. Flip the track-A row to `landed`, citing the fixture.
7. `python tools/g6b.py check` then `regress`.

Anti-patterns, all of which have bitten this class of work:

- Committing a golden to make a red test green.
- Raising a tolerance budget instead of fixing geometry.
- Marking a row `landed` from a `supports()` call (see §1.2).
- Importing goosie's verification gate along with its algorithm (§5).

## 5. Boundary with the goosie reference

| Taken as spec | Refused |
|---|---|
| CSS tokenizer / selector matching / specificity + cascade order | Go source, `go build`, any Go dependency |
| Box model, block/inline layout, display list, dirty regions | Fyne windowing/input |
| Golden layout-snapshot *idea* | Playwright + Chromium comparison gate (`goosie/AGENTS.md`) |
| DOM tree shape a style engine needs | Goja JS runtime (`internal/js`) |
| — | `internal/browsercontrol`, `internal/mcpserver` — remote automation bus |

`goosie/AGENTS.md` is an upstream tier-U artifact and is **not** governance
here; see `kernel-spec/README.md` §"Precedence".

## 6. Render debugging facilities

Summary here; the working methodology is `g6lc_bios/AGENTS.md` §"Render
debugging methodology".

| Facility | Question | Where |
|---|---|---|
| `g6b_css::parse_survey` | what CSS is missing? | `crates/g6b-css/src/lib.rs` |
| `g6b_css::inspect::explain` | why is this value what it is? | `crates/g6b-css/src/inspect.rs` |
| `StyleReport::to_text` | DevTools-shaped dump for serial/console | as above |
| `StyleReport::to_json` | machine-readable, for the browser inspector | as above |
| `createBrowserContext` | console/window/document singletons; pollable console | `browser-ui/src/kernel.ts` |
| `createRenderInspector().diff` | are we pixel-accurate vs. the host browser? | `browser-ui/src/kernel.ts` |
| `createRenderInspector().describe` | what did the host browser compute? | as above |

The loop for one feature row:

```
parse_survey(real_world_css)      -> missing property list -> css-features.json
explain(sheet, el, width)         -> which rule won, and the resolved box
  .to_json()  ->  inspector.diff(el, json, tolerance)
                                  -> per-property disagreement vs. the browser
fixtures/render/<name>/           -> fixture.html + fixture.css + fixture.json
g6b css-render --fixture <name>   -> out/render/<name>.ppm
g6b ppm-diff --actual out/... --golden fixtures/render/golden/<name>.ppm
                                  -> the committed correctness gate
```

The `bios_regress.py` case `css_golden` runs this loop for every fixture under
`fixtures/render/`. A fixture JSON carries `w`, `h`, `tolerance`, `golden`, and a
human `note`. The command line is:

```
g6b css-render --fixture fixtures/render/box_basic --out out/box.ppm
g6b ppm-diff --actual out/box.ppm --golden fixtures/render/golden/box_basic.ppm --tolerance 0
```

`explain` deliberately keeps overridden declarations in the report. When a box
is 3px too wide, the actionable fact is almost never the computed value — it is
which declaration was expected to win and did not.

### The browser instance (`createBrowserContext`)

`console` / `window` / `document` singletons live on a **browser instance**, not
on the libwasm host. The instance is engine-agnostic by construction: nothing in
`createBrowserContext` mentions WebAssembly, libwasm, or the object table.

The contract offered to any engine is two functions:

| Contract | Meaning |
|---|---|
| `bindings()` | allow-listed `name -> object` map |
| `global(name)` | one binding, or `undefined` when not allow-listed |
| `consolePage(since)` | bounded poll: `{contextId, pageRevision, entries, dropped, missed}` |
| `renderConsoleInto(el, since)` | paint the ring into a DOM element |

Consumers, none of which the instance knows about:

- **libwasm** — one import, `libwasm_global(name) -> handle`, resolves a binding
  to a protected object handle. With the handle, the existing typed family
  already reaches members: `Object_Call_string__void(h, "log", msg)`. That is
  why there is no console ABI.
- **the MVP `createWasmHost`** — can route its `log` into the same ring.
- **plain JS / the devtools panel** — uses `console`/`window`/`document`
  directly.

Adding a second engine must not require editing `createBrowserContext`.

Console shape follows `kernel-spec/goosie`
`internal/browsercontrol/types.go` — `ConsoleEntry{level, data, timestamp}` and
a bounded `ConsolePage{contextId, pageRevision, entries, dropped}` — and the
level set follows `internal/js/runtime.go` (`log`/`info`/`warn`/`error`/`debug`;
goosie's `table` is refused because we have no table renderer).

Deliberate properties, each covering a way a console can lie:

- **Bounded ring that reports.** `dropped` counts lifetime evictions and
  `missed` tells a poller how many entries it can never see because the ring
  moved past its cursor. `renderConsoleInto` paints a dropped-entries notice, so
  a panel never *looks* complete when it is not.
- **Isolated instances.** Each has its own `contextId` and ring, so an embedded
  frame's output cannot interleave into its parent's console. A frame gets its
  own instance; it does **not** get to read a cross-origin frame's console,
  which same-origin policy forbids regardless of our design.
- **Text, never markup.** Rows are written via `textContent`, so a logged
  `<img onerror=...>` is displayed, not parsed.
- **Fail closed.** An unknown global is `undefined` (JS) or handle `0`
  (libwasm), never a stub object that swallows writes. Singletons are protected
  roots the guest cannot free.
- **Bounded formatting.** `String()` per argument, 4 KiB cap, `[uncloneable]`
  for cycles. No `%s`/`%o` mini-language — that is an unbounded parser.

### Why the browser diff is an oracle and a score is not

`inspector.diff` compares against `getComputedStyle` / `getBoundingClientRect`
in whatever browser loads the served `/ui/` page. That browser is an
**independent** implementation, so a mismatch is evidence. Contrast §1: a
recognition score, or our own engine answering its own `supports()`, is
self-reported and can be made perfect without rendering anything.

Limits, stated plainly:

- `diff` needs a real DOM. The `bun test` harness uses `TestNode` mocks, so the
  inspector tests drive an injected `getComputedStyle`; a host without one
  throws rather than reporting a pass.
- It compares *computed values and one rect*, not rasterised pixels. Pixel
  truth remains the golden PPM diff in §3.
- It requires opening the page by hand. It is an interactive dev tool, not a
  CI gate, and must never be presented as one.

## 7. Honest status

- Track A and track B are **defined and wired** into `bios_regress.py` via the
  `css_golden` case. Five CSS fixture families are golden-locked (palette lane).
- The §6 debugging facilities are **implemented and tested** (26 Rust tests in
  `g6b-css`, 10 Bun tests for the inspector).
- `g6b-css` implements a **bounded modern lane** (`render32.rs`) alongside the
  16-colour palette lane (`render.rs`). The modern lane supports `rgba()`,
  opacity, rounded corners, background images, `object-fit`, `font-family`/
  `font-size`/`font-weight`, `text-align`, SVG/raster assets and icons via the
  bundled TTF font set, plus the layout primitives in §8. It is still **not** a
  web rendering engine: no float, grid, flex, text shaping, `@media`, or
  advanced compositing.
- `g6b-cli css-render --modern --assets DIR` and `g6b-kernel::ui_ppm32` expose
  the modern lane to the command line and to the host setup-page PPM path.
- `g6b-html` `to_uart_lines` now emits `img` `alt` text and skips `svg`/`canvas`
  for the no-graphics UART fallback.
- Nothing in this document claims `browserscore.dev` can be navigated,
  scored, or screenshotted by the BIOS. It cannot; §1 explains why that would
  not be meaningful even if it could.

## 8. Layout primitives (2026-09-09) — the three defects the screenshots showed

Rendering the real setup page at the virtio-gpu scanout geometry exposed three
layout defects. They were fixed against the `kernel-spec/goosie`
`internal/renderer/layout.go` algorithms, rewritten (prime directive 1), not
ported.

### 8.1 `max-width` + `margin: auto` — the centred column

`#bios-ui { max-width: ...; margin: 0 auto }` did nothing: `max-width` was not
in `SUPPORTED_PROPERTIES`, so `parse_survey` dropped it, and `auto` margins
resolved to `0` through `length`.

Goosie solves the auto margins against the **used border-box width**
(`computeLayoutBox`, `layout.go:638-673`), and clamps that width with
`MaxWidth` before the solve. `g6b_css::computed_box` now does the same:
`min-width`/`max-width` clamp the used width (subtracting the edges under
`box-sizing: border-box`), and CSS 2.1 §10.3.3 then distributes the free space
across whichever horizontal margins are `auto`.

### 8.2 The inline formatting context — why table cells stacked

`<th>A</th><th>B</th>` painted on separate lines. Root cause was **not** the
table: an inline element recursed into `children_layout`, whose trailing
`flush_items` ends the line. Every inline element therefore ended its own line.

`render32` now splits the two jobs: `children_layout` owns a block formatting
context and flushes once at the end, while `inline_children` appends into the
**caller's** item run. Only a block, a `<br>`, an absolutely-positioned box or
the end of the BFC breaks a line. `display` can also promote or demote an
element (`is_block_for`), so `display: block` on a `<span>` and
`display: inline` on a `<div>` both behave.

### 8.3 Automatic table layout, and atomic inlines

- **Tables.** `table_columns` measures each column's max-content width
  (`max_content_width`, bounded to depth 32 and `MAX_TABLE_COLS` = 16), then
  `distribute` shares the container width in proportion, giving the rounding
  remainder to the last column so a row tiles exactly. `<tr>` lays its cells out
  through `row_layout`, in two passes: measure every cell, then paint them all
  at the shared row height so a row reads as one band. Not implemented, and not
  pretended: `colspan`, `rowspan`, `table-layout: fixed`, border collapsing.
- **`display: inline-block`.** An atomic inline that keeps its own background,
  border, padding and radius — the reason a tab strip reads as tabs rather than
  coloured words. Sized shrink-to-fit (max-content plus edges, clamped to the
  line) and bottom-aligned on the line box, matching the replaced-element path.

### 8.4 Evidence

Five `g6b-css` tests, each written to fail on the pre-fix engine:
`max_width_with_auto_margins_centers_the_column` (and its flush-left control),
`inline_elements_share_one_line_instead_of_stacking`,
`inline_block_tabs_keep_their_own_boxes_on_one_line`, and
`table_cells_lay_out_as_columns_and_share_a_row_height`. One `g6b-kernel` test,
`setup_page_renders_a_keyboard_tab_strip_above_aligned_tables`, asserts the
composed result on the actual setup page at 1280x720: one tab per menu, all on
one row below the banner, non-overlapping and shrink-to-fit, above a table whose
header cells share a row and ascend in `x`.

**Not covered by a golden.** These are geometry assertions on hit boxes, not PPM
diffs; the `css_golden` case still only locks the five palette-lane fixtures.
A `render32` golden family is still open.
