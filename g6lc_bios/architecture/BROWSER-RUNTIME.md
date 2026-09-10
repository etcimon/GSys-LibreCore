# Browser runtime — the interactive BIOS UI

The BIOS setup UI is a **browser session** that loads one svelte-d application
and paints it on a high-definition scanout. It is not a kernel type table, not
a VGA glyph blit, and not Chromium / goja / puppeteer.

```
browser-ui/src/App.svelte
        │  svelte-d fall-through (not SvelteKit)
        ▼
svelte-engine-ws  (src-d NodeDef + src-ts jsExports / window.__svelteD.ts)
        │  LDC 1.43 wasm-eh + libwasm G6LC_G6B
        ▼
bios-ui-libwasm.wasm          ← the UI *application*
        │  loaded into
        ▼
BrowserSession  (UI hart / host UI thread)
        ├─ live g6b-dom          wasm mutates document/window
        ├─ JsExports             App_svelte.fetchBios / holycEval / register
        ├─ g6b-css (goosie)      cascade, :hover, Canvas32  ← raster is truth
        ├─ tick()                dirty restyle, skip-if-clean
        └─ g6b-gr::gl u_dom      GLES2 composite
                 │
                 ▼
        virtio-gpu / HDMI / DisplayPort / host-GL
        (GPU surface at the output's own geometry; never -netdev)
```

## Principle

| What | Where it lives | What it is not |
|---|---|---|
| One UI app | LDC cell `bios-ui-libwasm.wasm` | MVP encoder demo, guest `start_ops` |
| One engine | `BrowserSession` on the UI thread | UART face, HolyC REPL, kernel objects |
| DOM / `window` / JS exports | UI-thread `Host` + `WasmUi` | `g6b-kernel` types, BoardSpec handle 2 |
| Kernel I/O | `KernelPort` / `RouterPort` | a document |
| Style | goosie algorithms in `g6b-css` | Chromium, Fyne, Playwright |
| Present | GLES2 `u_dom` = CSS Canvas32 | VGA 8×8 glyphs as the web engine |
| Scanout | virtio-gpu (QEMU), HDMI/DP, host-GL | `-netdev`, Chromium compositor |

svelte-engine (`src-ts/modules/libwasm.ts` + `spa.ts`) is the contract the
loaded cell speaks:

- handle **1** = `document`, handle **2** = `window`
- `getRoot()` is `addObject(document.querySelector('#root'))` — a **new** handle
- D talks to JS through `window.__svelteD.ts` (Lodash `invoke`) and `exportDelegate`
- CSS is `GetCss!(Application, Theme)` then `libwasm.dom.addCss` / `render`
- Events are `domEvent`

`g6b-kernel` is the **wrong** place to hook those types. The kernel owns
BoardSpec, HolyC, the HTTP router, and the UI hart. It does not own `document`
/ `window` / JS exports. The interpreter must not return handle 0 for
`libwasm_global` with a "kernel cannot host JS" comment.

## Where the `.wasm` sits (level)

The svelte-d/LDC cell is a **browser-loaded application**, persisted as
`BrowserSession::wasm_ui` (`WasmUi`): module + object table + DOM handles +
interned `window`/`document`/`console` + `JsExports`. That instance stays
alive across `tick`, pointer/key dispatch, and GLES2 present.

| Level | Role of the LDC blob | Dynamic DOM / live JS exports? |
|---|---|---|
| **`WasmUi` in `BrowserSession`** | run `_start`, keep the instance, re-enter on events | **yes — this is the UI** |
| `/ui/ui.wasm` (kernel HTTP) | same bytes, served to a native `kernel.ts` adapter | yes, in a real browser |
| Guest `__ui_wasm` / `GetFile` | FileServe advertisement of those bytes | no (S-mode payload does not run the web engine) |
| `WasmJit` / `WasmStart` / `start_ops` | VGA glyph face (`i32.add`, 8×8 `DomPaint32`) | **no — not the web engine** |

Do not "run the UI" by lowering the LDC cell onto guest `start_ops`. Do not
drop the instance after `_start`. Do not intern `window` as BoardSpec.

## UI thread and scanout

`BrowserSession::tick(now_ns)` is one UI-hart frame: drain async JS, restyle
if the live DOM is dirty (`Engine::paint(&Node)`), set `UiTick.presented`
when GLES2 `u_dom` must composite. Skip-if-clean is the 100+ fps budget
(`DirtyFlag` empty → reuse last Canvas32; dirty tiles `TRANSFER_TO_HOST_2D`
the bbox, skip-if-clean emits no TRANSFER).

The **GPU surface** (`g6b_spec::Surface::Gpu`) paints the live session at the
output's own geometry. QEMU virt uses `virtio-gpu-device` (or
`virtio-gpu-gl-device` when `kernel.proxy.gl`); HDMI/DP uncore and host-GL
are the other high-def rungs. The VGA surface remains the 640×480 ZealOS
intent plane. See [`DISPLAY.md`](DISPLAY.md).

`:hover` is a goosie pseudo-class. The UI thread writes `data-hover="1"` on
the hit node; `g6b-css` matches `.bios-tab:hover` only then. Raster is truth;
GL composites `u_dom`.

## Transitional G6LC_G6B shortcut

B91d cell imports `env.getRoot` (Spa mount under `#libwasm-root`). Host
`get_root()` / `libwasm_global("document"|"window"|"console")` match
svelte-engine. DOM handle 2 stays the first `createElement` until
svelte-engine `{1: document, 2: window}` roots. That is **not** BoardSpec.

Kernel HTTP is a port, not a DOM. JS `fetchBios` / `holycEval` /
`registerEndpoint` live on `JsExports` (`App_svelte.*`), matching `print-ts.ts`.

B82–B91 landed on the host engine (`WasmUi`, cell-owned tabs, live CSS
`Engine::paint(&Node)`, UI-hart `tick` + timer heap, dirty-tile present
into modelled `__scan_fb`) and on the guest IR (`__ui_cap` + dirty-tile
`VioPaint` of that canvas). **B91b** keeps one persistent svelte-d `WasmUi` (`GuestCellLive`). **B91b+** `_start` keeps Binaryen `asyncify_*` (scratch above the D heap; `MAX_MEMORY_PAGES` 64). **B91b++** abort-stub `unreachable` is wasm-eh throw so Flatten-deleted `ready()` catch fail-softs after rewind. **B91c** virtio/UI-hart events re-enter D `jsCallback` / named `exportDelegate` input names (`Listener::Delegate`); the shipped cell keeps `Listener::Cell`. Guest
UART `Ui` and mailbox doorbell `U` are a UI-hart tick + pack
(`WebFeed::on_guest_ui`; `mbox_ui` jal `uart_ui`). Guest
`trap_timer` is skip-if-clean `tick` (rAF / timers / await). virtio-input
`EV_KEY` (Linux `KEY_*`, same codes as QEMU `sendkey`) maps to
`handle_key` / tab click so keyboard restyles CSS, not only VGA `DomNav`.
Tablet `EV_ABS` (`ABS_X`/`ABS_Y`, QEMU 0..=32767) and mouse `EV_REL` map
to `dispatch_pointer` `mousemove`; `BTN_LEFT` clicks at the last pointer.
`qemu-args` attaches `virtio-keyboard-device` then `virtio-tablet-device`.
Guest `InpInit` claims the first DeviceID 18 for VGA `INP_KQ`; `TabInit`
claims the second (`VIRTIO-TABLET-OK`). The exec model parks that tablet
on virtio-mmio slot 3 (PLIC irq 4) so source 3 stays the mailbox.
`host_inp_tab_kick` writes `EV_ABS` then `BTN_LEFT` into the tablet
eventq (`TabDrain` re-posts, no `INP_KQ`) so a VNC click activates the
hinted tab.
Cell-owned `#refresh` is the same `click` listener as the tabs (`g6b_listen`);
tablet ABS+`BTN_LEFT` on that hit box refreshes JSON like F10.
Click/hover/arrows/F10/JS await run on that session. The LDC cell is still
host-interpreted; `start_ops` is the VGA face. Windowing is **B92** later
([`plan-iframe.md`](plan-iframe.md)).
