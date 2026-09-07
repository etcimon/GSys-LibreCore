# Lightweight BIOS browser

Not Chromium, not Go goja, not puppeteer. Specs:

| Spec | Path | License | Role |
|---|---|---|---|
| goja (ES5 VM contract) | `kernel-spec/goja` | MIT | opcodes / host-object loop; **not linked** |
| lirx-js/dom | `kernel-spec/lirx-dom` | MIT | DOM mutation locality; **not linked** |
| WebIDL | `kernel-spec/webidl/definitions` | MPL-2.0 | interface catalog |
| svelte-d | `kernel-spec/svelte-d` | MIT | Svelte → libwasm/WASM UI; **not LDC** |
| goosie | `kernel-spec/goosie` | MIT | CSS cascade / box model / display-list contract for `g6b-css`; **not compiled, no Go, no Fyne, no Playwright gate** |

First-party MIT implementation (B50–B52):

```
BoardSpec.menus() + g6b-ui::faces_for / setup_reads
    ├─ HolyC Menu* → g6b-http::Router → same menu JSON
    └─ g6b-ui::setup_html → checked HTML / g6b-dom
         ├─ g6b-kernel::BrowserSession
         │    setup_script → g6b-js AOT → DOM + shared router
         │    generated WASM _start → bounded g6b-wasm + KernelHost
         │    refresh → select_menu → UART / Gr / display-proxy
         └─ /ui/index.html + /ui/app.js (browser-ui/src/kernel.ts)
              native DOM navigation + fetch → shared router
              native WebAssembly + queued host imports → refresh
```

These are distinct execution surfaces. Host `BrowserSession` and the HTTP
adapter are executable; the S-mode ELF still advertises the G6UI blob and
runs bring-up helpers. It does **not** yet execute the whole DOM/JS runtime
or install arbitrary native JIT code on the guest. Numeric RISC-V lowering
and its machine-word tests are described in `WASM.md`.

See [`WASM.md`](WASM.md). Design BIOS screens as `.svelte`; this package lowers a
v1 subset and a `_start` wasm module. Compile is `bun run build` in
`browser-ui/` (LDC 1.43 wasm cell optional via `G6B_DUB_WASM=1`). It does
not compile `kernel-spec/`.

The live subset is BIOS DOM mutation and **Fetch** through the kernel HTTP
proxy. SvelteKit `load` / `hooks` / `handleFetch` are **refused**. WebIDL catalog
labels are not claims of complete browser interface conformance.
`canvas.getContext("webgl"|"opengl")` identifies the enabled display-proxy GL
adapter; it is not a full Canvas/WebGL implementation, GPU driver or browser
compositor process. Other interfaces remain named stubs or refusals.

HTTPS is HolyC + `g6b-tls` (SHA-256, AES-128, TLS hello stub) on RISC-V, not
OpenSSL. See `architecture/TLS.md`.

## Implemented JS/DOM subset

`g6b-js::compile` tokenizes the entire input before producing operations.
It supports compile-local `var` string/boolean bindings and reassignment,
string concatenation, parentheses, boolean negation, quoted/Unicode escapes,
comments, and strict statement delimiters. Host statements are console log,
DOM ID/compound-selector mutation, Fetch with an explicit method, and
host-only HolyC/endpoint calls. A syntax error produces no operations;
a runtime error stops execution but does not undo previous operations.
Static `var` node bindings now support createElement/createTextNode, ID and
compound-selector lookup, aliases/reassignment, text/attribute/hidden mutation,
appendChild and removeChild. A handle-bearing script is compiled into one
bounded `DomTransaction`; identity survives reparenting, ID changes, removal
and text replacement. A failed transaction preserves the original tree/dirty
flags. Such scripts cannot mix fetch/log/kernel effects, and handles do not
persist across scripts. Limits include 4,096 retained nodes/handles, 64-edge
depth, 4 MiB DOM/program payload, 16,384 steps and 1,048,576 work units.
Functions, general numeric evaluation, loops, arbitrary objects/Promises and
general ES5 evaluation remain unsupported. Source/token/nesting/string/binding/
output budgets bound compilation. There is no Go runtime.

A separate `compile_async` / `AsyncScheduler` handles the bounded await/throw/
catch subset described in `WASM.md`. It is not silently enabled in static
`compile`; the LDC/libwasm build path now runs Binaryen Asyncify, but the D
`await`/`catch` Promise-continuation host driver is still a stub. `BrowserSession` admits scripts
only when BoardSpec enables JS, services read-only configured kernel endpoints
without a network wait, and resumes completed requests on the next poll.
Left/Right/Home/End menu input stays independent of suspended scripts; navigation
cancels their continuations. F10 refreshes values, never saves or flashes.

`Node` supports attributes, reflected ID/hidden state, textContent/innerText,
append/remove and single-compound selectors (tag, ID, class, attribute
presence/equality). Mutating a node dirties that node/parent only; no-op writes
stay clean. Hide/show preserves children. `parse_checked` accepts a balanced
HTML subset, attributes/entities and raw script/style contents; unsupported
or malformed markup returns an error rather than a partially mounted tree.
UART painting skips hidden/script/style nodes and keeps table rows separate.
This is lirx-style mutation locality, not a complete lirx reactive runtime.

## DOM event model

`g6b-dom::event` provides a bounded HTML5-style `Event`, `EventInit`,
`addEventListener`, `removeEventListener` and `dispatch_event`. Propagation
runs capture phase (root → target), then bubble phase (target → root) if
`bubbles` is true. `stopPropagation` cancels the rest of the tree;
`stopImmediatePropagation` cancels siblings on the current node;
`preventDefault` is recorded and returned from `dispatch_event` so the caller
can decide whether to run a default action (e.g. link navigation). Listeners
are stored as data (`event_listeners` on `Node`) and invoked through an
`EventHost` trait, so `g6b-js` and `libwasm` each provide their own callback
mapping without making `Node` non-`Clone`. The model is intentionally narrow:
no `EventTarget` interface object, no `CustomEvent` subclassing, no default
action dispatch inside `g6b-dom`; those live in the host layers.

`BrowserSession` owns a `BrowserEventHost` (callback table), `hit_boxes` from the
last CSS raster, and `dispatch_pointer` / `dispatch_key` helpers. A pointer event
performs a reverse hit-box lookup using the CSS-rendered `HitBox` list, constructs
an `Event` whose `target` is the rendered node's `id`, and runs
`g6b-dom::dispatch_event` on the `<body>` subtree. `g6b-css::render_sheet_to_output`
now attaches the `Canvas` to the `Cursor` so nested blocks are painted and recorded
as hit boxes; without this the hit list only contained top-level blocks.
`BrowserEventHost::invoke` records triggered listeners; `BrowserSession` then
runs the concrete AOT `g6b_js` program or libwasm re-entry after the DOM borrow
is released. AOT listeners execute `g6b_js::run` with a `{detail}` placeholder
replaced by `event.detail`. libwasm listeners re-enter `g6b_wasm::run_with_fuel_mut`
with the stored module, object table and DOM handles, passing an event object
handle plus the original listener handle. `KernelHost` collects libwasm listener
registrations during `_start`; `BrowserSession` persists `wasm_module`,
`wasm_objects`, and `wasm_handles` across re-entries.

## Configuration and execution

BoardSpec remains the only settings source. Existing `profile`, `kernel.ui`,
`kernel.wasm`, `kernel.http`, `kernel.usb`, `kernel.settings`, `kernel.gr` and
`kernel.proxy` gates are shared with HolyC. For example, overlay a profile:

```json
{
  "schema_version": 1,
  "profile": "full",
  "kernel": {
    "browser": { "js": "aot", "start_menu": "cpu" },
    "wasm": { "enable": true, "jit": false },
    "http": { "proxy_js": true }
  }
}
```

`js` accepts `aot` or `off` (`none` is an off alias). `start_menu` is one of
main/cpu/memory/uncore/devices/boot/settings. Disabling JS leaves complete
static HTML; host WASM execution is separately gated. A normal browser needs
its JS adapter to instantiate WASM. Disabling `http.proxy_js` prevents both
JS and WASM from reading the router, without removing static menu values.
The all-profile sample WASM may refer to disabled utilities; `KernelHost`
skips those reads with `WASM-SKIP-FETCH` diagnostics and tolerates only known
optional absent text targets. Unknown DOM IDs fail. Repaint errors surface as
`BROWSER-ERROR`, not success markers. File root paths must be local absolute
paths without traversal. Fetch cannot reinterpret a remote origin as a local
kernel endpoint; JS registration is confined to `/bios/custom`.

The host session uses `setup_script(spec)`, not unconditional execution of
the all-profile compiler demonstration `bios-ui.js`. WASM runs after mount;
router refresh then restores authoritative values before menu selection and
painting. Native browser import Fetch queues selected GETs synchronously and
drains them asynchronously after `_start`; no Promise is returned to an i32
WASM import. Browser import memory, call and queue budgets are checked, but
native WebAssembly does not have the Rust interpreter's fuel counter.

The optional LDC artifact is a **separate component scaffold**, never the
BoardSpec settings authority. Its DOM bridge interprets D strings as `(len,ptr)`
(unlike MVP `(ptr,len)`), binds root handle 1 to a detached staging root, and
commits only after successful `_start`. Rollback restores the original node
identities. Handles, UTF-8, memory ranges, call counts, total strings and tree
depth are bounded; unknown handles, root moves/cycles, active tags, arbitrary
property setters, HTML injection, URL properties and event setters are refused.
Unmount detaches without invalidating the retained handle. The current contract
is initialization-only, not a callback/reactive object bridge.

The libwasm host also exposes the libwasm await/object-string ABI:
`env.libwasm_await_supported`, `env.libwasm_await_failed`,
`env.libwasm_await_error`, `env.libwasm_await_value`,
`env.libwasm_note_await_fail`, `env.libwasm_note_await_ok`,
`env.libwasm_get__string` and `env.libwasm_add__string`. These are the host
imports that the `await_status` D module (and `g6b_kernel.d`) use to read and
record `.await` settlement after an `env.libwasm_await__void` rewind. The
`createLibwasmHost` JS implementation bounds-checks the sret pointer, allocates
UTF-8 payload memory, and writes a D `(length, ptr)` string struct. Rejected
await state maps to a string via `libwasm_await_error`; resolved values map to
`libwasm_await_value`; `libwasm_get__string` copies an object-table string back
into guest memory. Object handles start at `0x0010_0000` and are owned by the
host; the guest cannot create arbitrary JS objects. The `env.fetch` promise
resolves to the response body text (or rejects on non-2xx), so
`libwasm_await_value` writes the body and `libwasm_await_error` writes the
rejection reason after a rewind.

Since B61 that table is **refcounted**, matching `struct JsHandle`:
`libwasm_copyObjectRef` increments and returns the same handle,
`libwasm_removeObject` decrements and frees at zero, freed slots are reused,
and the table is capped at 4,096 live objects. Handles `1` (staging DOM root)
and `2` (BoardSpec scope) are protected roots — copy is identity, release is an
error. Double free, use-after-free and over-budget allocation all throw, and
because import errors mark the transaction `failed`, a lifetime violation can
never commit a partial tree. Object handles still carry no properties; the
per-receiver property registry is B63.

The browser host also runs **Lodash chains** (B67). `struct Lodash` ships a
JSON command buffer through the twelve `ldexec_*` imports; `createLibwasmHost`
parses it and evaluates it over the same bounded value model as the kernel's
`g6b-js` backend. There is no `eval`: when a chain carries a D-delegate
iteratee, libwasm emits one of five fixed generated arrow functions, and the
host recognises those by identity and calls the guest's
`__indirect_function_table` instead — so the predicate runs in wasm. Any other
`=(…)` payload, and any `VarType.eval` chain seed, is refused. Unlike the
kernel lane, the browser lane *can* dispatch the iteratee, because it can
re-enter the instance. The full object/property/event surface the bindings
expect is [`LIBWASM-ABI.md`](LIBWASM-ABI.md).

Since **B69** the generic `Object_Call`/`Object_Getter` machinery also serves
`Element.setAttribute` / `getAttribute` / `removeAttribute` and
`Element.classList` (`add` / `remove` / `toggle` / `contains`) on the browser
host, using the existing B63/B64 call families and the `TestNode` `classList`
mock in `browser-ui/compiler/compile.test.ts`. The first bounded ES6+ host
object, `Map`, is exposed through the new `libwasm_map_*` imports and creates a
real JS `Map` for string keys and values.

A bounded **guest** lane also exists when `kernel.wasm.jit` is live
(`WASM.md` B53): `g6b-elf` merges `g6b-wasm::jit::start_ops` into the
payload's `WasmStart` anchor and KStart `jal WasmUi` runs it once at boot.
The guest `__ui_dom` table mirrors the same menu text into a bounded row
store; `DomPaint` echoes `DOM| <text>` on serial and blits the first-party
8x8 font into `__gr_plane`, and `VioPaint` pushes it to the virtio-gpu
scanout. The guest lane now also bridges input (`InpDrain` → `DomKey`/
`DomNav` → `inp.last`/`nav.sel` rows, QEMU `sendkey`-verified) and a
**bounded multi-slot await**: UART `Await` claims the first non-pending
slot of `AWAIT_SLOTS`=4 at `__ui_dom+16` (`AWAIT pending N`; all four
pending → `AWAIT-REJ full`; a resolved/rejected slot is reusable), and
`DomAwait` — polled on the `trap_timer` tick (one slot per call, O(1)
bounded IRQ work) and the `Ui`/`Keys` paths (`AWAIT_SLOTS` calls to
drain) — resolves pending slots (`AWAIT-GET /bios/menu` per slot → `await.N` =
`"resolved menu"`, dirty-marked; the tick's dirty-watermark repaint
carries it to the scanout without a `Ui`). `Throw`/`T` rejects a pending
slot — `Throw N` targets slot `N`, plain `Throw` the newest pending
(`AWAIT-THROW /bios/menu` → `await.N` = `"rejected menu"`) — the thrown
rejection, caught and visible in the DOM; nothing pending is a no-op
(`AWAIT-THROW none`). All three are also **guest imports**: `env.await()
-> i32` returns the claimed slot (-1 when full), `env.throw(i32)`
rejects the given slot (-1 → newest), and `env.catch(i32) -> i32`
returns 1 when that slot is currently rejected (0 otherwise, including
out-of-range). They are lowered to `WasmAwait`/`WasmThrow`/`WasmCatch`
(the same routines the UART commands `jal`), so a lowered wasm `call
env.await`/`call env.throw`/`call env.catch` drives the queue from guest
code — including a `local.set`/`local.get`-held slot for a *targeted*
reject or catch (`jit::tests::start_ops_executes_await_throw_imports` and
`start_ops_catch_reveals_a_rejected_row`, both xlens). The shipped
`bios-ui.wasm` uses it end to end — `await fetchBios("/bios/menu")` in
`App.svelte` emits `call env.await` at `_start`, claiming a slot at `Ui`
that the next timer tick resolves (QEMU-verified); the browser host binds
`env.await`/`env.throw`/`env.catch` as bounded `Set`s of pending and
rejected slots resolved by `drain()`, and the interpreter `Host` gains
default `await_op`/`throw_op`/`catch_op` no-ops. This is the guest-side correlate of the host async scheduler's
semantics — pending/drain/bounded-capacity-reject/throw-reject with the
kernel's poll integration — at a fixed 4-slot queue, not the full ES6
Promise/event-loop model. The ES6-shaped host `BrowserSession`,
reactivity, per-task promise graphs and a JS-visible `Promise`/`catch`
object remain separate lanes or open gates, and the guest lane never
replaces them. See `DISPLAY.md` "Async frames and IRQ-context paint safety" for
the trap-frame/`VIO_BUSY` concurrency contract this rests on.

Browser limits: 1 MiB module, 16 MiB observed WASM memory, 4,096 handles,
16,384 imports, 64 KiB individual/1 MiB total decoded strings, DOM depth 64.
The fixed generated particle step uses no DOM imports after commit. Native
WASM is still not preemptible by the host call budget when code makes no
imports; only locally generated/verified artifacts belong in this lane.

The 1980s BIOS theme remains readable without JS/WASM/GL. With the LDC lane
available and `kernel.proxy.enable && kernel.proxy.gl`, a WebGL spell-like
particle field and moving **GSys LibreCore** text wordmark appear behind
translucent panels. The mark is locally generated text, not a fetched logo
asset. App.svelte supplies the static effect CSS; D supplies simulation state.
Reduced-motion, pause, hidden-tab suspension, context loss and GL-unavailable
fallbacks preserve menus. Browser WebGL availability does not certify hardware
acceleration or establish guest RISC-V OpenGL support. See `DISPLAY.md`.

## Worker interfaces and compute separation

The implemented browser compute path uses **Dedicated Workers**, following
Worker/DedicatedWorkerGlobalScope message, messageerror, error and terminate
semantics. Workers have no Document or Window. `g6b-webidl` records the explicit
subset and bounded error/message types; the broad Worker interface remains
classified as a stub for the first-party VM, not falsely promoted to complete
WebIDL conformance. `new Worker`/arbitrary worker-script JS is not parsed by the
Rust static VM. ServiceWorker remains refused: it needs registration, origin/scope,
install/activate, extendable-event lifetime and fetch interception, not a thread
pool. SharedWorker lifetime/ports are also not implemented.

When BoardSpec tasking and JS/files are enabled, the kernel router serves
`worker.js` and HTML publishes its local path and worker limit. `computeBios`
is a Promise-returning **convenience RPC wrapper**, not a claim that standard
Worker.postMessage returns a Promise. Native Worker handles the real message
transport; one request is in flight per worker. The pool lazily creates at most
min(BoardSpec worker limit, reported browser hardware concurrency minus the UI
thread), with a one-worker fallback. It admits 128 requests and 16 MiB aggregate
copied buffers. Caller buffers are copied, then those copies are transferred.
Abort/deadline/termination reject pending Promises and discard late completions;
there is a 30-second dispatched-job deadline. No busy loop waits for completion.

Worker operations are SHA-256 and native WebCrypto AES-GCM. AES-GCM requires a
non-extractable secret CryptoKey with the requested usage, generates a fresh
96-bit nonce for encryption, uses a 128-bit authentication tag, and rejects
modified ciphertext. Data is capped at 1 MiB (plus the decrypt tag), additional
authenticated data at 64 KiB. Keys are never logged. This is **browser-engine
WebCrypto**, not the BIOS TLS stub or a new unaudited cipher. A SHA-256 worker
check button demonstrates awaited completion without a mutation route. Full
SubtleCrypto is not implemented in the first-party VM.

The host BIOS exposes a separate `TaskServices` bridge: prepared HolyC handlers,
isolated no-import numeric WASM and first-party SHA-256 jobs are dispatched as
owned work outside the UI borrow. Numeric jobs may produce native JIT IR; host
execution is still bounded interpretation. Completion/cancellation is typed and
one-shot. This is not yet a general JS Worker object or D await/worker binding
inside the guest. See `KERNEL-RV.md` for the tested ASM task context and the
remaining SMP runqueue/guest-dispatch contracts. Neither browser hardwareConcurrency
nor a per-hart policy test proves guest all-core saturation.

## Browser-UI design notes (flash + file manager)

Two screens share the 640×480 Gr plane and the high-res display-proxy. They
are **svelte-d NodeDef**, not SvelteKit routes. `fetch` hits the kernel
router; HolyC `UsbLs` / `UsbFlash` / `UsbKey` is the other KVM face of the
same table. USB contract: [`USB.md`](USB.md).

| Screen | Gate | Layout (640×480) | High-res proxy |
|---|---|---|---|
| **Flash** | `G6LC_USB_FAT32` (always when USB on) | one column: title `USB-FAT32`, list of `.bin`/`.elf`/`.img`, Flash / Update | same list, larger type; status strip on the GL plane |
| **FileMgr** | `G6LC_USB_KEY` | two panes: volume tabs `fat32 \| ntfs \| ext4` + directory listing | tabs stay left (~280 CSS px), listing fills; DPI from `kernel.proxy.dpi` |

**Flash** is the embedded/router listing. No tabs, no NTFS, no “open folder”.
B51 removes the apparent startup flash action: listings are explicitly
read-only until a real image-write backend exists. UART-only builds paint
the same list (`id="usb-list"`). Settings without a key stay on UART/mailbox.

**FileMgr** is the USB-key extra. svelte-d `Construct::FileMgr` is **live**:
`lower()` emits `fetch("/bios/files/{fat32,ntfs,ext4}")` plus `SetInnerText`
on `fm-list`. `{#each}` stays a stub, so the listing is one text node (canned
JSON), not a virtualized grid. Do not grow SvelteKit `+page` / `load` /
`handleFetch` to “make a file app”.

Design rules:

1. **Flash never lists NTFS/ext4.** A firmware image on those volumes is
   visible in FileMgr; the operator copies it to the FAT32 stick (or uses
   SPI/mailbox). Embedded builds must not pull an NTFS decoder for flashing.
2. **One Fetch proxy.** FileMgr does not open `file://`, does not use
   `<input type="file">`, and does not talk to a second HTTP stack. `env.fetch`
   / `Op::Fetch` → `g6b-http::Router`.
3. **Low-res first.** The ZealOS plane is 640×480×16. FileMgr tabs wrap to
   one line; names truncate. Display-proxy scales that plane — it does not
   relayout. High DPI only enlarges glyphs.
4. **SSH+HolyC twin.** `UsbLs("ntfs")` / `UsbFlash("openwrt.bin")` /
   `UsbKey("present")` print the same verbs the HTML paints. Neither face
   replaces the other (`PLAN.md` §4).
5. **After `NET-DELEGATE`.** The stick is the OS’s. BIOS FileMgr becomes
   view-only through `/dev/g6lc-bios` if the listing was cached; it is not
   a second MSC driver in Linux.

Generated hooks: `Browser.ZC` comments `USB-FAT32` / `USB-FILES`; `Svelte.ZC`
catalog includes `SVELTE-LIVE FileMgr` and `SVELTE-LIVE Menu`; setup HTML always
has `#usb-flash` and `#bios-menu`. When `usb.key`, `#filemgr` with `#fm-tabs` /
`#fm-list`. CPU/uncore screens `fetch /bios/menu/*`. HolyC-UI is a different
artifact (`HolycUi.ZC`); see [`MENUS.md`](MENUS.md).
