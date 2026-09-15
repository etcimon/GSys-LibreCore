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

## Verification boundary (2026-09-11)

Real QEMU runs the emitted S-mode `WasmUi`/`start_ops` glyph face. The live `BrowserSession` remains a **host** engine; `WebFeed` connects it to the Rust execution model, not to a native QEMU browser runtime. The agreed current pass verifies UI and autoboot independently, not an in-guest web engine.

- `tools/qemu_web_autoboot.sh` captures `picker.{ppm,png}` before input and `screen.{ppm,png}` after `AUTOBOOT-UI`; QMP errors, absent captures, unchanged frames, and blank scanout fail. Use the g6lc_qemu-built binary via `QEMU=...`. Default `up` wraps to the last BIOS UI entry, followed by Enter.
- `fixtures/g6lc64-web-autoboot.json` is the full-profile 1920x1080 path; `g6lc64-web-autoboot-vga.json` is the full-profile 640x480 VGA-intent surface on virtio-gpu transport. Neither claims legacy PC VGA register support.
- ELF emission defaults to **no external media**, not the modelled NTFS key. Explicit `--volume` media are still discovered and packed. The guest clears the picker row count before entering the UI face.
- Host visual review: `cargo run -p g6b-cli -- ui-ppm32 --spec fixtures/g6lc64-web-autoboot.json --width 1280 --height 900 --click tab-cpu --key F10 --out out/cpu.ppm`. Repeat `--key`, `--click`, or `--hover` in command order on one persistent session. `tools/ppm2png.py` converts the result for inspection. These images are host-engine renderings, not QEMU screenshots.

The rendering root is the D cell's actual `main`, with input paths remapped into that subtree. Static fallback HTML is used only before a cell mounts. Svelte declares data sources; the kernel/host adapters perform reads, and both adapters supply the same menu row-array ABI. No RTL, clocks, ISA, DTS, or hardware memory map changes are involved.

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
The DeviceID-18 scan classifies each device by **capability, not slot
order** (B122): it writes `select=EV_BITS`/`subsel=EV_ABS` into the
mmio config window and reads back the `EV_ABS` bitmap length — nonzero
⇒ `TabInit`/tablet (`VIRTIO-TABLET-OK slot= irq=`), else `InpInit`/
keyboard for `INP_KQ`. The exec model parks that tablet on virtio-mmio
slot 3 (PLIC irq 4) so source 3 stays the mailbox.
`host_inp_tab_kick` writes `EV_ABS` then `BTN_LEFT` into the tablet
eventq when only `hint_abs` is set (`TabDrain` re-posts, no `INP_KQ`) so a
VNC click activates the hinted tab. `hint_rel` / `hint_wheel` skip that
dummy click. `TabDrain` decodes ABS/REL/wheel into `PTR_X`/`PTR_Y`/
`PTR_CLICK`/`PTR_MOVE`/`PTR_WHEEL` (`__vio` scratch) so `DomtPtr` can
dispatch click, mousemove, wheel, and hover — see the pointer lane below.

**Guest-side DOM raster lane (B111, exec-model verified).** `domt.rs`
(`Purpose::UiDom`) is a *bounded* stand-in for the shipped engine — not
the svelte-d cell. It keeps a `__dom` node arena (64 B records) plus a
`__dom_str` text pool in BSS, and provides `DomtCreate`/`Append`/`Text`/
`Style`/`Listen`/`Focus`/`Dirty`, a block-flow `DomtLayout`, and
`DomtRaster`, which paints bg/glyph pixels **directly into `__scan_fb`**
and records each painted node rect in `__ui_cap` (guest-asserted
`WEB_PRESENT`). `VioPaint` then takes the `vp_web` path and TRANSFERs
those dirty tiles — the guest owns the frame; host `inject_web_present`
stays off, so `guest_dom_raster_fills_scan_fb`/`guest_dom_key_recolors_a_node`
prove the guest produced the pixels. `DomtKey` drains `INP_KQ` and
focus-dispatches `KEY_*` to the focused node's listener (`DomtDemo`
recolors a row), and `trap_timer`'s `__dom` dirty check re-runs
`DomtLayout`+`DomtRaster`, closing input→listener→mutation→repaint→present.

**The shipped svelte-d cell now lands on this arena (B112, exec model).**
`kernel.wasm.guest_jit` runs `jitr.rs`'s in-payload JIT, which translates the
~204 KB LDC/libwasm cell and executes `_start` natively; its `env.*` imports
route through `jit_ext_tab` to the `Lw*`/`Domt*` bridge. The bridge adapts
libwasm's handle ABI (`handle = node_index + 1`, `createElement` = `NodeType`
ordinal, `setProperty` len-before-ptr, `add_event_listener` resolving an
element-**id** string via `LwFindId` over the `__dom_id` side-table) onto the
fixed 64 B `__dom` records. Verified: the cell allocates 56 live nodes, sets
47 element ids, registers the source's 8 `g6b_listen` listeners
(id→node→`N_LEV`), and `DomtRaster` paints 279K px into `__scan_fb` with no
`DomtBoot` demo fallback. This is the guest DOM lane — a bounded stand-in for
the engine, not the full CSS cascade — and it is exec-model verified, not yet
a QEMU screendump.
Cell-owned `#refresh` is the same `click` listener as the tabs (`g6b_listen`);
tablet ABS+`BTN_LEFT` on that hit box refreshes JSON like F10.
Click/hover/arrows/F10/JS await run on that session. **B114 adds the
listener re-entry lane**: a nonzero `add_event_listener` cb is biased into
`N_LISTEN >= 0x100` (a wasm funcidx), and `DomtKey` fills the `__ev_obj`
record then `JitCall`s that funcidx between `JitRun`s — so a delegate
`appendChild` provably mutates `__dom` off a real `INP_KQ` keydown
(`guest_jit_listener_reenters_cell_on_key`). The *shipped* cell still keeps
`listener=0` (the BIOS protocol, host runs fetch/select), and `start_ops` is
the VGA face. **B115 adds the pointer lane**: `TabDrain` latches the last
`ABS_X`/`ABS_Y` + a `BTN_LEFT` `PTR_CLICK` flag, and `trap_tab` then runs
`DomtPtr` (`guest_jit`), which scales to display px, `DomtHit`s the topmost
`F_VIS` rect node, fills `__ev_obj` (`clientX`/`clientY`/target-handle)
and `JitCall`s the node's wasm funcidx — a real tablet `BTN_LEFT` re-enters
the cell the same way `DomtKey` re-enters on a key
(`guest_jit_listener_reenters_cell_on_click`). **B130 extends that packet
to SYN_REPORT:** `REL_X`/`REL_Y` clamp-add into `PTR_X`/`PTR_Y` and latch
`PTR_MOVE`; `REL_WHEEL` latches `PTR_WHEEL`; `EV_SYN` is a no-op because
the used-ring walk already batches. `PTR_HOVER` starts at NONE. `DomtPtr`
then dispatches mouseout-old / mouseover-new / mousemove / wheel
(`deltaY`=`EVO_VALUE`) / click (`guest_jit_mousemove_via_rel`,
`guest_jit_mouseover_first_enter`, `guest_jit_wheel_at_button`).
**B131 normalizes RFB/KVM into that packet:** `ptr.rs` `PtrNorm` scales
framebuffer px to tablet ABS, coalesces moves, preserves left press/release,
and refuses a second source while left is held. An RFB 3.8 PointerEvent or
`KvmPointer` injects the same virtio eventq (`guest_jit_rfb_pointer_clicks_button`,
`guest_jit_kvm_wheel_at_button`). Not RFB session/auth.
**B132 adds modifiers and DOM buttons:** `button` is 0/1/2 (left/middle/right),
`buttons` is the chord mask, `ctrlKey`/`shiftKey`/`altKey`/`metaKey` come from
keyboard `PTR_MODS`, and a click `DomtFocus`es the hit node
(`guest_jit_click_button_is_zero`, `guest_jit_rfb_right_button_is_two`,
`guest_jit_shift_click_shiftkey`, `guest_jit_click_focuses_button`).
**B125 adds the capture/at-target/bubble walk:** `DomtHit` is geometric (the
topmost `F_VIS` rect, not a listener filter); `DomtDispatch` snapshots the
`N_PARENT` chain. **B126 replaces the one per-node slot** with a bounded
`__dom` listener table (64×16 B after the node pool). `DomtListen` ORs `N_LEV`
and appends `{node,mask,cb,LSNF_CAPTURE}`; `DomtFire` scans by `eventPhase`
(capturing needs the flag, bubbling needs it clear, at-target fires capture
then bubble). `stopPropagation` skips remaining nodes. A node can hold both
a capture and a bubble listener (`guest_jit_two_listeners_on_parent`).
**B127 adds `once`/`passive`/removal:** `add_event_listener`'s last i32 packs
`LSNF_CAPTURE|ONCE|PASSIVE` (0/1 stay capture-only). `once` tombs the record
after `JitCall`; `passive` sets `EVO_PASSIVE` so `preventDefault` is a no-op;
`remove_event_listener` maps to `EXT_RMLSN`→`LwRmLsn` (tombstone by cb). **B116 adds the `__ev_obj` property bridge** so the
delegate can *read* the event, not just be re-entered: `Object_Getter__{int,
uint,ushort,bool,Handle}` route to `LwEvGet` (name-matched `lw` of the
`__ev_obj` fields — `clientX`/`clientY`/`code`/`target`/`currentTarget`/
`eventPhase`/`type`/`defaultPrevented` and aliases), and the no-arg-void
`Object_Call___void` routes to `LwEvCall`, which sets `EVO_PD` on
`preventDefault` (read back as `defaultPrevented`) and `EVO_STOP` on
`stopPropagation`.
Bounded to the live event object (`handle == &__ev_obj`). **UTF-8 string
getters** (`Object_Getter__string` → `EXT_EVGETSTR`→`LwEvGetStr`) write a D
`{len,ptr}` for `type`/`key`/`code` (`code` is KeyboardEvent.code, never a
Linux keycode). **OptionalUint/Handle** (`LwEvGetOpt`) write `{value,defined}`;
`relatedTarget` is defined=0. **float** (`LwEvGetF`) is `fcvt.s.w` of the
integer field. **double** (`LwEvGetD`) is `fcvt.d.w`. **OptionalString**
writes `{len,ptr,defined}` (`defined` iff the UTF-8 payload is non-empty).
**OptionalBool** writes `{value,defined}` bytes (`bubbles`/`cancelable`/
`isTrusted` are defined=1). **OptionalDouble** writes `{f64,defined}` from
the integer field. The gate
`guest_jit_listener_reads_event_props` appends iff `clientX>=200 &&
target!=0 && defaultPrevented` — a real click lands `clientX≈325`. String
gates: `guest_jit_listener_reads_event_type_string` (click → `"click"`) and
`guest_jit_listener_reads_event_code_string` (KEY_ENTER → `"Enter"`). **B117 is
the Stage-3 op-coverage gate** (`g6b_wasm::op_coverage`): it lowers the whole
cell through the shared `lower_one` and walks the re-entrable set (`_start` +
func exports + element-table funcs) to report `TRAP_UNSUP`/`TRAP_EXT`/
`TRAP_BADFUNC` in reachable code — the hard check behind `await_supported=1`.
On the shipped cell it finds exactly one reachable gap, `fidx 94`'s uncaught
`throw` (cross-function wasm-EH, a cold path), and the gate asserts no *new*
gap class appears. Windowing is **B92** later
([`plan-iframe.md`](plan-iframe.md)).
