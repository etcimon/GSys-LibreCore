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
  `css_golden` case. Five CSS fixture families are golden-locked.
- The §6 debugging facilities are **implemented and tested** (26 Rust tests in
  `g6b-css`, 10 Bun tests for the inspector).
- `g6b-css` currently implements the declaration/cascade/box-model core only
  (see its unit tests). It is **not** a web rendering engine: no float, grid,
  flex, text shaping, fonts beyond the 8×8 first-party bitmap, or compositing.
  `color` / `background-color` cascade but are not yet rasterised.
- Nothing in this document claims `browserscore.dev` can be navigated,
  scored, or screenshotted by the BIOS. It cannot; §1 explains why that would
  not be meaningful even if it could.
