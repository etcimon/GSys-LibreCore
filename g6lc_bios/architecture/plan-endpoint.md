# BIOS web engine — endpoint plan

**Status:** living endpoint. Implementation on **`E:\cva6/g6lc_bios`**, not a
stale worktree. This file is the updated copy of the session plan (web-engine
PRs 1–7). Historical ZealOS scaffold remains in [`PLAN.md`](PLAN.md).

**Ancestor:** `kernel-spec/goosie` is the DOM/CSS rendering-engine spec (never
compiled, no Go, no Fyne, no Playwright).

**JS reference:** `browser-ui/src/kernel.ts` `createLibwasmHost` +
`createBrowserApp` — the behaviour `BrowserSession` must match.

**Green:** `python tools/g6b.py check` then `python tools/g6b.py regress` from
`g6lc_bios` with cargo on PATH. QEMU BIOS path never `-netdev`. Never Variane.

See also [`BROWSER-RUNTIME.md`](BROWSER-RUNTIME.md) (principle),
[`AGENTS-todo.md`](../AGENTS-todo.md) (B82–B91 schedule), and
[`plan-iframe.md`](plan-iframe.md) (later: windows, tab engine, iframe
sessions, local or remote URL).

---

## 0. Thesis

The BIOS display is a **first-party web engine**. The svelte-d /
svelte-engine-ws **LDC libwasm cell** (`bios-ui-libwasm.wasm`) is the
application. `BrowserSession` is the runtime: persistent wasm instance
(`WasmUi`), live DOM, capture/bubble events, goosie-style CSS, a UI-thread
frame loop, OpenGL-accelerated present onto virtio-gpu / HDMI / host-GL at
the BoardSpec refresh (60–120 Hz, not capped at 60; extend with 100/144).

Tab clicks, JSON from `/bios/menu/<id>`, CSS restyle, and scanout are the
**same path**. Any other wasm/JS lane that looks interactive but cannot reach
that present path is deleted or demoted so it cannot be mistaken for the UI.

This is not Chromium, not goja-the-runtime, not a guest port of the LDC cell
in one step. It is host-native `BrowserSession` first, then the guest scanout
**is that engine’s framebuffer**.

`g6b-kernel` is the **wrong** place to hook libwasm types (`document` /
`window` / `JsExports`). The kernel supplies `KernelPort` (fetch / HolyC /
register). The UI-thread `Host` interned those globals.

---

## 1. What is true today (after B82–B91)

| Lane | What actually runs | What the operator sees |
|---|---|---|
| Native browser (`kernel.ts`) | `createLibwasmHost` instantiates the LDC cell against a real DOM. `createBrowserApp` registers **click** on `[data-menu-link]`, **click** on `#refresh`, **keydown** for F10/arrows, fetches JSON, paints rows. WebGL particles on `requestAnimationFrame`. | A dynamic tabbed setup page. |
| Host `BrowserSession` | Interpreter `_start` of the LDC cell builds the tree and fetches JSON. `WasmUi` keeps module + object table + interned `window`/`document` + `JsExports` across `tick` and pointer dispatch. Cell-owned tab/refresh clicks (`Listener::Cell` / `g6b_listen`); Rust `select_menu` is the default action. `Engine::paint(&Node)` rasters the live tree. `Role::Ui` on `ui_hart` runs `tick`; `TimerHeap` fires B66 timers / rAF. goosie `:hover` via `data-hover`. `present_gl` composites GLES2 `u_dom`. Dirty tiles `TRANSFER_TO_HOST_2D`/`FLUSH` into modelled `__scan_fb`. | A PPM / GL composite of the Svelte tree; host-modelled scanout matches `ui_ppm32`. QMP tab shots stay `qemu_tab_shots.sh` / remote g6q. |
| Guest ELF | `start_ops` lowers straight-line MVP `_start` to `WasmDomText` / `WasmFetch` against `__ui_dom` rows (VGA face). GPU-class `VioPaint` TRANSFERs `__ui_cap` dirty tiles of Canvas32 packed by the host engine (B91). `WasmJit` is `i32.add`. `/ui/ui.wasm` FileServe bytes are the LDC cell. | Glyphs on the VGA face; GPU scanout is the web engine canvas via dirty tiles. LDC cell is still host-interpreted; `start_ops` is not `Object_Call`. |

`Role::Ui` / `ui_hart` run `BrowserSession::tick` when `kernel.tasking` is
enabled (B89).

The LDC `ready()` in `svelte-engine-ws/src-d/app.d` builds tabs and fills
`tbody` from JSON. `App.svelte` `on:click` lowers to `g6b_listen`; the host
binds `Listener::Cell` until the next `G6B_DUB_WASM=1` rebuild emits those
calls. Rust `select_menu` is the default action if the cell did not
`preventDefault`.

---

## 2. Misleading paths (status)

| Path | Action | Status |
|---|---|---|
| Silent MVP fallback when LDC `_start` fails | **Delete.** `kernel.ui=svelte-d` requires the cell; failure is `BROWSER-ERROR`. | **landed B82** |
| ELF / `/ui/ui.wasm` = MVP encoder | Embed **LDC cell** when the svelte-d lane is live. | **landed B82/B83** |
| `jal WasmJit` = `i32.add` as “the UI” | Document as numeric-worker JIT. UI execution is `WasmUi` / `instance.call`. | **documented B82**; rename leftover still open |
| Guest `start_ops` → glyphs as “the UI” | VGA/UART **text face** only. GPU-class scanout presents Canvas32. | **documented B82**; host blit **B90**; guest dirty-tile `VioPaint` **B91** (`start_ops` unchanged) |
| Hit boxes from static `session_page_html` | Pixels and hits from the **live** Svelte tree. | **landed B82** |
| `set_property(..., "style")` refused | One style write path. | **landed B82** |
| `libwasm_global` returns 0 (“kernel cannot host JS”) | UI-thread Host interns `window`/`document`/`console`. | **landed B84** |
| Handle 2 = BoardSpec | Retired. Handle 2 is first `createElement` until LDC `getRoot` matches svelte-engine. | **landed B84** |
| `:hover` “browser-only, absent from raster” | goosie `:hover` + `data-hover`. | **landed B84**; goldens **B88** |
| `select_menu` as the only tab implementation | Cell owns `on:click`; Rust is default action if no `preventDefault`. | **landed B87** |
| CSS via HTML serialize/parse each frame | `Engine::paint(&Node)` + DirtyFlag. | **landed B88** |
| B66 `setTimeout` id 0 | Implement on the UI thread or **refuse at the ABI verifier**. | **landed B89** |
| Host WebGL particles as scanout evidence | Optional `u_fx` behind `u_dom`. Not CSS truth. | **documented B90** — dirty-tile `u_dom` is scanout; particles are not |

UART 4bpp + 8×8 font stays the **HolyC/VGA face**, not a fake web engine.

---

## 3. Target architecture

```
                    BoardSpec.menus() + g6b-http::Router
                                    │
         svelte-d ──► svelte-engine-ws ──► LDC 1.43 bios-ui-libwasm.wasm
                                    │
                    ┌───────────────┴────────────────┐
                    │     BrowserSession (UI thread) │
                    │  WasmUi (persistent instance)  │
                    │  KernelHost as borrow          │
                    │  KernelPort (fetch/HolyC only) │
                    │  g6b-dom live tree             │
                    │  g6b-css style/layout/paint    │  ← goosie algorithms
                    │  hit boxes from last paint     │
                    │  timer heap + fps cap          │
                    └───────────────┬────────────────┘
                                    │ Canvas32 @ output W×H×DPI
                    ┌───────────────┼────────────────┐
                    ▼               ▼                ▼
              CPU golden      GLES2 dirty tiles   virtio-gpu / HDMI / PCIe FB
              (track B)       u_dom (+ optional   TRANSFER dirty rects
                               u_fx particles)
```

**Parity rule:** a `Host` import that `createLibwasmHost` implements for the
cell must have a UI-thread `Host` implementation that mutates the same DOM
meaning, or the ABI verifier must reject the cell. No third “almost” host.

**Single present rule:** GPU-class outputs (`virtio-gpu`, uncore scanout, PCIe
linear FB, host-gl) display Canvas32 from `BrowserSession::tick`. They never
upscale `__gr_plane` unless `kernel.proxy.surface=vga` was explicitly chosen.

**Level of the `.wasm`:** the LDC cell is a **browser-loaded application**
(`WasmUi`). `/ui/ui.wasm` serves the same bytes. Guest `__ui_wasm` is
FileServe advertisement. `WasmJit` / `start_ops` are not this engine.

---

## 4. UI thread

Use the existing scheduler instead of inventing a second one.

- Hart `kernel.tasking.ui_hart` (default 0) runs `Role::Ui` / `Job::Ui` only.
- `BrowserSession::tick(now_ns)` is the UI job body. Workers (`Sha256`,
  `WasmNumeric`, HolyC handlers) **must not** touch `session.dom` or GL.
- Frame period = `1e9 / refresh_hz`. BoardSpec `fps` already allows 30 / 60 /
  120; extend the legal set with `100` and `144`. `fps=0` (auto) already
  picks 120 when detected ≥ 90 Hz.
- Per-tick budget: wasm fuel cap, layout dirty-rect cap (goosie merges ≤ 64
  rects), dt clamp 50 ms. Skip present if dirty regions are empty.
- `setTimeout` / `setInterval` / a bounded `requestAnimationFrame` alias land
  on this heap. B66 no longer returns 0 (or the verifier rejects the import).
- Reduced-motion: one static frame. Hidden-tab / UART-only: no GL present,
  UART lines still update.

Guest S-mode: `trap_timer` still `jal`s `VioPaint`. **B91:** `__ui_cap`
holds dirty tiles + a compact node count; when `WEB_PRESENT` the host exec
model packs BrowserSession Canvas32 into `__scan_fb` and `VioPaint`
TRANSFERs those rects (skip-if-clean is `VIRTIO-PAINT-SKIP`). **B91b:**
`guest_cell_scanout` / `smoke_cell` run the LDC cell on the same
[`g6b_wasm::Host`] import set as `BrowserSession` (`KernelHost`), then pack
that canvas for guest `VioPaint`. This is an **exec-model S-mode stand-in**,
not a RISC-V interpreter of the ~942-function LDC cell and not
`start_ops` `Object_Call`. Silicon compact paint of a guest interpreter
remains later.

---

## 5. Persistent wasm instance and events

Replace remaining “build `KernelHost`, run `_start`, tear down, stash
tables” with:

```
BrowserSession {
  wasm_ui: WasmUi,   // module + memory + globals + tables + objects + handles
  dom: Node,
  stylesheet + computed style cache,
  hit_boxes,
  timers,
  surface,
}
```

Landed in B85: `WasmUi` owns module, object table, placements, interned
window/document/console, `JsExports`. Event re-entry `take_persist` /
`restore`.

Landed B86: `WasmUi::call` / `call_listener`; interned Event with coords
and `preventDefault`. LDC `getRoot()` is an `env.getRoot` host import; the
shipped cell still inlines `return 1` until `G6B_DUB_WASM=1`.

Landed B87: `App.svelte` `on:click` → `g6b_listen`; host `Listener::Cell`.
Rust `select_menu` is the default action. JSON stays `/bios/menu/<id>`.

Landed B89: `Role::Ui` on `ui_hart` runs `tick`; `TimerHeap` fires
`setTimeout` / `setInterval` / `requestAnimationFrame` through `WasmUi::call`
(never id 0). BoardSpec `fps` admits 100 and 144.

---

## 6. Live CSS (goosie rewrite, not HTML round-trip)

Spec: `goosie/internal/css`, `internal/renderer/{invalidation,dirty_region,
incremental_layout,incremental_painter,mouseinput,layout}.go`. First-party
in `g6b-css`.

| Before B88 | After (B88) |
|---|---|
| `render32(html, css, w, h)` of `live_render_html` | `Engine::paint(&Node)` → Canvas32 + HitBox[] + DirtyRegion |
| `Node.dirty` unused by CSS | DirtyFlag: Style / Layout / Paint; walk `dirty_union` (no parent pointer) |
| `:hover` via `data-hover` | hover target from pointer; goldens `ui_tab_hover_ppm32` |
| `.bios-tab-active` if `select_menu` said so | classList mutation restyles this frame; golden `ui_tab_cpu_ppm32` |
| `files.assets` PNG/SVG | keep; raster from live `src` |

CPU raster remains **truth** ([`RENDER-VALIDATION.md`](RENDER-VALIDATION.md)).
Goldens for: initial setup page, each tab after click+JSON, hover on a tab,
refresh button. No Chromium, no Playwright.

`:hover` and transitions: honour colour/background restyle; ignore
`transition:` duration in the BIOS raster (instant).

---

## 7. OpenGL acceleration and high-def present

`g6b-gr::gl` stays a GLES2 listing (not libGL, not Chromium).

- `u_dom` = Canvas32 (or dirty tiles) at **output** resolution (gpu surface).
- `u_zeal` = 640×480 plane **only** on VGA surface.
- Optional `u_fx` = particle buffer from the same wasm instance, composited
  **behind** `u_dom` when `proxy.gl` and reduced-motion is off.

Present (**B90, host landed**):

- `host-gl`: upload dirty tiles each tick (`glTexSubImage2D` per 64 px tile).
- `virtio-gpu` / `virtio-gpu-gl-device`: `TRANSFER_TO_HOST_2D` + `FLUSH` of
  dirty rects (not full-frame every tick). Skip-if-clean emits no TRANSFER.
- Uncore HDMI / PCIe linear FB: write dirty tiles into the latched `__disp.fb`.
- Host exec-model blit of Canvas32 into modelled `__scan_fb` (X8R8G8B8);
  `scanout_ppm` is the Main→CPU→Memory evidence vs `ui_ppm32`. Guest
  `VioPaint` stays full-frame until B91. QMP tab shots are
  `tools/qemu_tab_shots.sh` (remote g6q, 2D virtio-gpu) — not `g6b.py check`.

High-DPI: VGA face keeps shared scale/letterbox; **gpu** face paints CSS at
native `w×h`. 100+ fps is dirty-rect + skip-if-clean.

GL is validated **against** the CPU golden. A GL-only pretty picture is not
evidence.

---

## 8. Guest vs host (honest split)

**B82–B90 are host-native.** QEMU evidence in that window is: `g6q run
--loader bios` with the **host engine driving scanout** (exec-model blit of
Canvas32 into modelled `__scan_fb`). Check evidence is host-modelled
`scanout_ppm` vs `ui_ppm32`. QMP tab screendumps (`qemu_tab_shots.sh`) stay
on remote g6q — WSL2 has no DRM render node.

**B91 (landed, assessed increment):** guest `__ui_cap` compact persist
(dirty tiles + node count) + `VioPaint` TRANSFER of those rects when the
host packs Canvas32 (`GuestWebPresent`). VGA `start_ops` / 48-row
`__ui_dom` unchanged. Same `Host` import set stays on the host
`BrowserSession`; do not grow `start_ops` to `Object_Call`. A guest
S-mode interpreter of the LDC cell is still later.

Numeric `jit_riscv` stays a **worker** for `Job::WasmNumeric`. The LDC cell
(~942 functions, wasm-EH, Asyncify) is **not** JIT’d whole.

---

## 9. `kernel.ts` relationship

`createLibwasmHost` remains the native-browser host (desktop browser loading
`/ui/`). `BrowserSession` is the BIOS engine (QEMU / silicon).

They must share:

- Import names and fail-closed policy (`wasm-cell.ts` verifier).
- Event semantics (click, keydown, preventDefault).
- Fetch allow-list (`setup_reads` + local `/ui/`).
- Tab/JSON behaviour.

They must **not** share: Chromium layout, `getComputedStyle` as CI, WebGL as
the definition of pixels.

Move tab/refresh/keyboard **into the Svelte/D app** (B87) so both hosts just
dispatch events. Keep a thin “if no listener, default action” in both hosts.

---

## 10. Implementation order (rescheduled)

Work tree: **`E:\cva6/g6lc_bios`**.

| Stage | Plan PR | Title | State |
|---|---|---|---|
| **B82** | 1 | Cut misleading UI lanes | **landed** |
| **B83** | 1b | `fetch` / `<img src>` / `/ui` assets / `u_dom` listing | **landed** |
| **B84** | — | libwasm types on UI-thread Host; `KernelPort`; `:hover` | **landed** |
| **B85** | 2a | `WasmUi` persistent instance; live tab classList; tick/present_gl | **landed** (host docs + instance) |
| **B86** | 2b | `instance.call` without KernelHost reconstruct; event coords / preventDefault; LDC `getRoot` host import | **landed** (shipped cell still `return 1` until `G6B_DUB_WASM=1`) |
| **B87** | 3 | Cell-owned tab/refresh/JSON (`on:click` in App.svelte → D) | **landed** (host; LDC rebuild still pending) |
| **B88** | 4 | Live CSS `paint(&Node)` + DirtyFlag + tab/hover goldens | **landed** |
| **B89** | 5 | UI-thread `Role::Ui` tick; timer heap; fps 100/144; B66 or verifier-refuse | **landed** |
| **B90** | 6 | Dirty-tile GL + virtio-gpu TRANSFER + QMP tab screendumps | **landed** (host blit + modelled scan_fb; QMP shots remain remote g6q) |
| **B91** | 7 | Guest libwasm instance (later) | **landed** (compact persist + dirty-tile `VioPaint`; `start_ops` not grown) |
| **B91b** | — | Guest S-mode LDC cell, same Host import set | **landed** (exec-model `guest_cell_scanout` / `smoke_cell`; not a RISC-V interpreter of the cell) |

Do not grow `start_ops` to `Object_Call`. Do not treat B12b–B13 or B54 as this
endpoint. B92 is later.

---

## 11. Verification

- `python tools/g6b.py check` and `regress` after every stage.
- New regress cases (B88/B89): `ui_tab_cpu_ppm32`, `ui_tab_hover_ppm32`,
  `ui_tick_skips_clean_frame`.
- B90 check: `ui_scan_fb_matches_css_ppm32`, `ui_tab_cpu_dirties_scanout_tiles`;
  skip-if-clean asserts no extra `SCAN-TRANSFER`.
- B91 check: `vio_paint_web_present_transfers_dirty_tiles_not_glyphs`,
  `guest_web_present_transfers_css_into_vio_fb`. Glyph-path
  `vio_probe_finds_modelled_gpu_at_slot0` still expands 4bpp when `__ui_cap`
  is not WEB_PRESENT.
- B91b check: `smoke_cell_runs_ldc_host_not_start_ops` (`WASM-INTERPRETER`,
  `VIRTIO-PAINT`, `cap_nodes > 1`). `guest_web_present` now requires the
  LDC cell to have run on `KernelHost`.
- QEMU QMP (not `g6b.py check`): `tools/qemu_tab_shots.sh` against
  `fixtures/g6lc64-qemu.json` on remote g6q (2D `virtio-gpu-device`).
  Never Variane.
- Bun tests: cell click handler fires under `createLibwasmHost` **and** a
  `KernelHost` mock that is the same import table (B87).
- Independence: still no crates.io, no path deps leaving `g6lc_bios`; goosie
  never `go build`.

---

## 12. Refusals (unchanged)

- Chromium, puppeteer, Playwright, Go goja runtime, Fyne, SvelteKit
  `+page`/`load`/`handleFetch`.
- Host `eval`. Invented return values for unimplemented imports.
- GL as pixel truth. Whole-cell RISC-V JIT of the LDC artifact.
- Mapping GR/scanout onto AI-island `0x40000000`.
- `-netdev` on the QEMU BIOS path.
- Hooking `document`/`window` as kernel / BoardSpec types.

---

## 13. Key decisions

1. **One app = LDC libwasm cell.** MVP `bios-ui.wasm` is a compiler
   demonstration, not a runtime fallback.
2. **One engine = `BrowserSession` on the UI hart.** Native browser
   `kernel.ts` is a second host of the same ABI, not the scanout.
3. **Goosie algorithms on the live `Node` tree.** No HTML serialize/parse
   per frame (B88 finishes this).
4. **CPU raster defines pixels; GL/virtio-gpu accelerate dirty tiles.**
5. **The Svelte app owns tabs and JSON (B87).** Hosts dispatch events; they
   do not maintain a parallel menu state as the source of truth.
6. **100+ fps is dirty-rect + skip-if-clean at BoardSpec `fps` (extend with
   100/144),** not a full re-layout.
7. **Guest glyph UI is not the web engine.** GPU-class outputs present
   Canvas32. Guest libwasm is B91.
8. **Fail closed in public.** Unimplemented EventHandler/timer is a
   verifier error, not id 0.
9. **`KernelPort` is the only kernel I/O the cell may call.** Types live on
   the UI-thread Host / `WasmUi`.

---

## 14. Later: windows and iframe sessions

Not B89–B91. The BIOS UI becomes a small window manager (status bar in
setup chrome, Firefox-like tabs inside a window, iframe sessions that
navigate to a **local app path or a remote URL**). Remote loads use
adapter `HttpsGet` / post-delegate mailbox — never QEMU `-netdev`. Full
plan: [`plan-iframe.md`](plan-iframe.md).
