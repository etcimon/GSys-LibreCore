# g6lc_bios — Agent Guider (package root)

> **Scope:** Independent setup firmware. The **platform is a rewrite** of
> TempleOS / ZealOS, which are **specs** under `kernel-spec/` — not a port, not
> a vendor blob, not a Cargo dependency. Hosts (`g6lc_qemu`, `build-platform`)
> may *emit* a BoardSpec JSON; they never become crate dependencies.

| Artifact | Path | Role |
|---|---|---|
| This guider | `AGENTS.md` | Invariants + current planning state |
| Live todo | `AGENTS-todo.md` | Stage checklist |
| Living plan | `architecture/PLAN.md` | Rewrite-from-spec, conformity gate, B0–B52; guest browser/JIT residuals |
| Licensing | `AGENTS-licensing.md` | MIT first-party; Unlicense `kernel-spec/` |
| Architecture | `architecture/` | PLAN, ZEAL, DESIGN, CODEGEN |
| Kernel spec | `kernel-spec/` | TempleOS + ZealOS reference forks (not compiled) |
| Green commands | `python tools/g6b.py check`, then `python tools/g6b.py regress` | independence + Bun tests/build + fmt + clippy + workspace tests; separate BIOS/transport regression |

## Current planning state

**B0–B52 plus B55–B59 host lanes landed within the stated host/guest boundaries.** Profiles `embedded`/`router` → `full` compile UART+SPI flash
up to browser-UI HTTPS and USB settings. USB FAT32 flash is always compiled;
the USB-key file manager (FAT32/NTFS/ext4) is extra. 64-bit SMT2 / multi-issue /
stream / OoO / hypervisor / RVV specs infer setup menus. HolyC kernel file
server emits generated HTML/JS/WASM over HTTP or HTTPS. HolyC-UI and browser-UI
share the menu tree. JS `fetch` and HolyC share one router. SvelteKit refused.
The OpenSBI ELF `jal`s `TimerInit` (SBI TIME + `rdtime`) before park and takes
supervisor timer irq 5 with the scause interrupt bit. Every hart sets `sp` and
`stvec` before the park split; stacks sit in BSS after the image. Display-proxy
geom is payload words; QEMU virt uses `-smp` + `virtio-gpu-device`
(`virtio-gpu-gl-device` under `proxy.gl`, `--no-gl` fallback, `--vnc`
frontend; never `-netdev`).
`g6b smoke` runs the S-mode payload on the host (SBI putchar/TIME + UART0 THR)
until park. Hart 0 `wfi` takes irq 5 once (IRQ_TIMER). Secondary harts WFI after
`satp`/`sp`/`stvec` with no tick. Unexpected traps print `TRAP-<scause>-<sepc>`
and park (INT_FAULT), not an `sret` loop. `uncore.plic` runs `PlicInit` (S-mode
ctx1) — sets a nonzero priority for every enabled source (QEMU resets
priorities to 0) and trap irq 9 claim/complete: UART irq 10 (QEMU virt
ns16550; `trap_uart` RX), virtio-mmio irqs 1..=8 (slot i → irq 1+i,
`trap_vio` ISR read/ack + `__vio` irq counter — QEMU-verified), and mbox
irq 3. `harts>1` runs `HartStart` (SBI HSM + IPI); trap irq 1 (SSI) `sret`s.
`loopback.enable` runs `MboxInit` (`G6MB` + irq_en at `0x10100000`); trap irq 3
services doorbell kicks (`View` → ST_RSP, `Reboot` → SBI SRST). Dual-band UART1
sets `IER.ERBFI` and waits with `WFI` (not a busy poll, never a netdev). UART
RX appends `__uart_line`; a newline matches `View`/`Reboot`/`Shutdown`/`Wakeup`
(4-char prefix or first letter). `ViewSection("name")` prints `VIEW name`.
`GrInit` writes a `GR16` header at `__gr_plane` (after stacks), a 4bpp 640×480
plane with a boot scanline, and an 8×8 `G6LC` blit; QEMU still uses
`virtio-gpu-device` (never `-netdev`; `proxy.gl` selects
`virtio-gpu-gl-device` + `egl-headless,gl=on`). `ProxyScale` runs when
`kernel.proxy.gl`.
`UiInit` publishes a `G6UI` header at `__ui_blob`; the ELF carries the UI
wasm (LDC libwasm cell when live) in `.rodata`. UART/mbox `Ui` prints `UI`.
`FileServe` echoes `\0asm` and prints `/ui/` paths; UART/mbox `File` lists
them. `GetFile` is GET `/ui/ui.wasm` (mailbox RSP `\0asm`+size; not a
netdev). Host FileServe may add `/ui/pglite/*` when `kernel.store.pglite.files`
and dist bytes are live; guest listing does so only for `pglite.embed`. Native
`kernel.ts` `pglite` is a `/bios/store` facade (shell BINDINGS only); optional
Electric `createPgliteWasm` is not assigned on the real DOM. Host `BrowserSession` runs that LDC cell and does **not** fall back
to the MVP encoder wasm. `WasmJit` is the numeric `i32.add` worker leaf when
`kernel.wasm.jit`; `WasmUi` then runs `WasmStart` (MVP straight-line `_start`
imports) against `__ui_dom` and `DomPaint` (8×8 glyphs) — a VGA/UART text
face, not the web engine. GPU-class scanout must present `BrowserSession`
Canvas32 (B90: host blit of dirty tiles into modelled `__scan_fb`; B91:
guest `VioPaint` TRANSFERs `__ui_cap` tiles when WEB_PRESENT, else
full-frame `FbExpandSel`).
UART `Ui` re-dumps the
live DOM via `DomPaint`. `VioProbe` (`Purpose::Virtio`, live when
`wants_virtio_gpu`) scans QEMU-virt virtio-mmio slots `0x10001000+0x1000*i`
(all 8 transports exist at a 0x1000 stride; `-device` attaches to the last
free bus) for DeviceID 16 and prints `VIRTIO-GPU <slot>`/`VIRTIO-GPU-NONE`;
`VioInit` then performs the virtio 1.x handshake (reset → ACK|DRIVER →
FEATURES_OK readback → DRIVER_OK), sets up controlq rings in `__vio` BSS,
completes one `GET_DISPLAY_INFO` descriptor round-trip (`VIRTIO-INFO`), and
`VioScan` drives the pixel sequence (`RESOURCE_CREATE_2D` →
`RESOURCE_ATTACH_BACKING` → `SET_SCANOUT` → band fill →
`TRANSFER_TO_HOST_2D` → `RESOURCE_FLUSH` → `VIRTIO-SCAN`) — the resource and
rects are the **`__disp`-latched output mode** (`DispSel` runs first; the
proxy default is the common case), and
`FbExpand`/`FbExpand1`/`DomPaint32` fill the X8R8G8B8
`__scan_fb` with the `Proxy::to_ppm` semantics (`fit`/`dpi` = uniform
scale, centered letterbox; `fill` = per-axis stretch) computed from `__disp`
w/h/stride at runtime — then `VioPaint` (virtio class only)
TRANSFER+FLUSHes the full frame (`VIRTIO-PAINT`) after `WasmUi`/`DomPaint`
and on the UART `Ui` re-dump, and `DispPaint` (uncore class only) commits
the same surface to the display engine. **Verified on QEMU 8.2 + OpenSBI 1.5** via
`fixtures/g6lc64-qemu.json`: QMP `screendump` is 1920×1080 with the 640×480
DOM/Gr plane ×2 centered at (320,60) — matching the host-modelled
framebuffer and the `display-proxy` PPM geometry exactly. A `display`-class
peripheral (`fixtures/g6lc64-hdmi.json`) selects the native uncore scanout:
`DispPaint` commits `__scan_fb` to the engine contract
(`architecture/uncore/hdmi-display.md`) plus a `G6FB` descriptor — the
`simple-framebuffer`-shaped BIOS→Linux handoff — and `wants_virtio_gpu`
yields to it. `qemu-args` emits `virtio-gpu-gl-device` + `egl-headless,gl=on`
under `proxy.gl` (needs a host DRM render node `/dev/dri/renderD*` —
surfaceless EGL is not software GL; `--no-gl` → 2D fallback)
and `--vnc N` exports the console for BIOS+Linux alike. QEMU needs
`-global virtio-mmio.force-legacy=false` (the default legacy v1 transport
ignores the v2 queue registers — `qemu-args` emits it) and the used-ring
poll is `1<<22` (QueueNotify is iothread-async) — with SEIE armed the
`VioInit`/`VioCmd` waits `wfi` on the used-buffer irq instead of pure spin
(bounded by the same budget plus the periodic timer). `InpInit` probes the
slots for DeviceID 18 (`virtio-keyboard-device` then
`virtio-tablet-device` under `wants_virtio_input()`; guest takes the
first slot for VGA `INP_KQ`, `TabInit` the second), posts 8 `virtio_input_event` buffers on the
eventq, and `trap_inp`→`InpDrain` pushes each `EV_KEY` into the bounded
`INP_KQ` queue (`INP` marker, buffer re-posted); UART `Keys`/`K` and the
mailbox `K` doorbell dump it via `InpPoll` (`KEY <8-hex>`; mbox answers
`RSP="KEYS"`), and `DomKey`/`DomNav` (`kernel.wasm.jit`) mirror the queue
into the DOM: `inp.last` = the newest key (`DOM| key <hex>`), `nav.sel` =
menu navigation (arrows move `sel` over `spec.menus()`, Enter opens →
`NAV <name>` serial + `open <name>` row; `NAV_SEEN` watermark scan — the
physical ring stays for the `Keys` dump). UART `Await`/`A` (jit-gated)
claims a bounded await slot (`__ui_dom` header +16, `AWAIT_SLOTS`=4 u32s —
idle/pending/resolved/rejected, `npend` count at +12) → `AWAIT pending N`
+ `await.N` row = `"pending menu"`; all four pending → `AWAIT-REJ full`
(fail closed); a resolved slot is reusable. `Throw`/`T` rejects the newest
pending slot (`AWAIT-THROW /bios/menu` → `await.N` = `"rejected menu"`) —
the thrown rejection, caught and visible in the DOM. The slot logic lives
in `WasmAwait`/`WasmThrow`/`WasmCatch` (the UART commands are thin `jal`s)
— and lowered wasm can drive the same queue: `env.await()->i32` returns
the claimed slot (-1 when full), `env.throw(i32)` rejects that slot
(-1 → newest), and `env.catch(i32)->i32` returns 1 iff the slot is
rejected, all `import_stub` entries — the shipped `bios-ui.wasm` does
exactly that for `await` (`await fetchBios("/bios/menu")` in `App.svelte`
→ `call env.await` at `_start`, resolved by the next timer tick;
QEMU-verified). `start_ops` lowers i32 locals, `drop` and single-i32
call results through a bounded s2..s5 pool. `DomAwait` resolves one slot
per call (the `Ui`/`Keys` polls loop it `AWAIT_SLOTS` times); `Throw N`
targets slot N. `DomAwait` polls
drain the ready set on the `trap_timer` tick and the `Ui`/`Keys` paths
(`AWAIT-GET /bios/menu` per slot → `resolved menu`), so `await` never
blocks DOM events. The
timer tick also flushes a dirty-watermark-gated background repaint
(`DomPaint`+`VioPaint`/`DispPaint`) — input/nav/await mutations reach the
scanout without a `Ui`. The trap frame now saves `ra`+`t0..t6`+`a0..a7`
(16 slots): a trap-time `jal` must not destroy the interrupted context —
a tick landing inside a normal-context `VioCmd` `wfi` faulted `vqc_poll`
with a clobbered `t5` before the fix (diagnosed via `stval` —
`TRAP-<scause>-<sepc>-<stval>`). `VIO_BUSY` (`__vio+0x5f0`) guards the
ctrlq: `VioCmd` holds it per transaction and `VioPaint` skips when busy,
so a trap-time repaint can never interleave mid-transaction.
**QEMU 8.2-verified** on `g6lc64-virt.json` (WSL2, stock virt, OpenSBI
fw_dynamic): monitor `sendkey` → `INP`, serial `Keys` → the exact Linux
keycodes, `Ui` → `DOM| key …` + `VIRTIO-PAINT`, QMP `screendump` =
P6 1920×1080 with guest pixels; `MBOX-NONE`/`UART1-NONE` on the absent
stock-virt devices, and `egl-headless,gl=on` correctly refuses with
`egl: no drm render node available` (WSL2 has no `/dev/dri`). Absent-device tolerance: unmapped MMIO raises scause 5/7
with `stval`; `trap_fault` recovers probe-window faults (UART1 /
loopback-mbox) so `g6lc64-virt.json` now boots on stock QEMU virt too —
`MboxInit` also readback-checks the doorbell so QEMU's `fw_cfg` at
`0x10100000` reports `MBOX-NONE` instead of swallowing `G6MB`, and the
`uart1` probe runs before `PlicInit` arms the irq (a trap-context fault on
a missing device would nested-trap and clobber `sepc`). The modeled
UART1 sits at `uart0+0x9000` — above the always-present virtio-mmio window
(QEMU virt has no second real ns16550). `g6lc64-qemu.json` is the
stock-virt-faithful spec: `loopback` off (mbox `0x10100000` is QEMU `fw_cfg`),
`dual_band.tcp` off, `postboot`/`net_expose` never; `g6lc64-virt.json`
keeps those lanes enabled — the probes degrade to `MBOX-NONE`/`UART1-NONE`
on stock virt instead of parking.

B50–B52 add bounded JS/DOM and validated i32 WASM execution, shared complete
menu rows, native-browser navigation/imports, `kernel.browser.start_menu`,
post-script Gr/proxy painting, and real numeric RV32/RV64 lowering. B55–B59
extend the host lanes: mutable per-run WASM memory and widened i32 lowering, a
bounded nonblocking JS async scheduler (`await`/throw/catch with budgets and
cancellation), transactional DOM in both Rust and the native-browser kernel,
cooperative RV32/RV64 task-switch IR with bounded scheduler/task services, a
DedicatedWorker compute protocol, and a provenance-gated LDC 1.43 libwasm
component-shell cell (Asyncify build path landed with the custom binaryen;
full Svelte semantics and the D `await`/`catch` host driver still fail closed).
The host
`BrowserSession` and served native app are executable. The guest ELF still
has bring-up helpers, not the complete browser runtime or arbitrary JIT code
installation. Read `BROWSER.md` / `WASM.md` for supported subsets and limits;
never equate a `WASM-JIT` boot marker with native compilation of the UI.

QEMU `--loader bios` is hypothesis, never Variane evidence.

## Prime directives

1. **Rewrite, do not port.** Read `kernel-spec/ZealOS` (prefer) or
   `kernel-spec/TempleOS`, then write first-party MIT in `crates/**`. Do not
   compile, link, or copy x86/VGA/ring-0/oracle/`/Apps` from the forks.
2. **Conformity.** Every inference from the spec forks must agree with LibreCore:
   OpenSBI M-mode, this payload S-mode, BoardSpec parameterization, PMA/PMP,
   DTS UART/PLIC/SPI/timer map, no AI-island clash at `0x40000000`, firmware-boot
   principles. When ancestor and LibreCore conflict, **LibreCore wins**.
3. **KD0.** `cargo test --workspace` succeeds with only this tree + `fixtures/`.
   `kernel-spec/` is not a crate.
4. **Generated, never typed.** XLEN, RVV, UART base, hart count, mailbox base/IRQ
   come from BoardSpec.
5. **Display is HTML+JS in the kernel**, painted on the BIOS Gr/UART viewport.
   The other KVM face is SSH+HolyC (ZealC CLI), not a replacement.
6. **No Go goja *runtime*, no Chromium, no puppeteer bus.** `kernel-spec/goja`
   is a semantic spec (like TempleOS). Never `import` it, never `go build` it.
7. **OpenSBI stays M-mode.** This package is an S-mode payload.
8. **Post-boot access is parameterized.** After Linux, immutable sections stay
   viewable and write-disabled. The OS NIC may carry gateway/web/SSH only until
   `LinuxHandoff` (`until-delegate`); then the mailbox + PLIC IRQ (`/dev/g6lc-bios`)
   is the loopback — never a netdev.
9. **ASM IR, not string literals.** Generated RISC-V (`KStart.S`, `KInts.S`,
   `MemCpy.S`, ELF words) is lowered from `g6b-asm` after an analysis pass that
   names each object's purpose and architectural home. Do not add a second
   `format!(.s)` / `Vec<u32>` encoder. See `architecture/CODEGEN.md`.

## Render debugging methodology (CSS / DOM / pixel accuracy)

Ancestor: `kernel-spec/goosie` (MIT, `1039ae6`) — the spec of record for
**rendering logic**: `internal/css` for tokenizing, selector matching and
cascade ordering; `internal/renderer` for the box model, layout passes, display
list and dirty regions. Read it, then write first-party Rust in `crates/g6b-css`
(prime directive 1). Its Go source, Goja embedding, Fyne windowing and
Playwright/Chromium verification gate are **refused** — precedence and the full
keep/refuse map are in `kernel-spec/README.md` and
`architecture/RENDER-VALIDATION.md` §5.

The **browser instance** (`createBrowserContext`) owns the `console` / `window` /
`document` singletons a UI is built on. It is engine-agnostic on purpose: the
contract is `bindings()` (an allow-listed `name -> object` map) plus
`consolePage()`, so libwasm consumes it through a single `libwasm_global` import
while plain JS and the devtools panel use it directly. Instances are isolated by
`contextId`, so an embedded frame gets its own console ring. Console shape and
the bounded-ring-that-reports-drops behaviour follow goosie's
`internal/browsercontrol/types.go`. Details: `RENDER-VALIDATION.md` §6.

Four facilities, in the order you should reach for them:

1. **`g6b_css::parse_survey`** — *what is missing.* Point it at real-world CSS;
   it returns the stylesheet plus the sorted list of properties this engine does
   not implement, instead of refusing the sheet. Use it to grow
   `fixtures/css-features.json`. The strict `parse` still refuses the same
   input, so a survey can never widen the render path.
2. **`g6b_css::inspect::explain`** — *why is this value what it is.* A
   DevTools-shaped report: winning declaration first, every overridden candidate
   kept visible with the reason it lost (`!important` / specificity / source
   order), plus the resolved box. `to_text()` for a serial log or console,
   `to_json()` for the browser inspector. It reads the winner out of `cascade`
   itself, so the report can never disagree with the engine it describes.
3. **`createBrowserContext(...).renderConsoleInto(el)`** — *what did the UI
   report.* Paints the bounded console ring into a DOM element, i.e. the
   devtools console panel. `consolePage(since)` polls incrementally and reports
   `dropped`/`missed` rather than silently skipping.
4. **`createRenderInspector`** (`browser-ui/src/kernel.ts`) — *are we
   pixel-accurate.* `diff(el, report, tolerance)` compares an `explain` JSON
   against the host browser's `getComputedStyle` and
   `getBoundingClientRect` for the same element. Length mismatches get a
   whole-pixel tolerance; keyword mismatches never do. `describe(el)` dumps the
   host's own view.

Why the third one is legitimate where a conformance score is not: the host
browser is an **external oracle** for computed values, so a disagreement
localises a cascade or box-model bug to one property. A recognition score from
`@browserscore/supports` — or from our own engine answering its own
`supports()` — is self-reported and measures nothing;
`architecture/RENDER-VALIDATION.md` §1 has the evidence. Track A (feature
inventory) says *what to build*; track B (golden PPM diff) says *whether it is
right*. A feature row is flipped to `landed` only by track-B evidence.

Rules that have already caught bugs here:

- A property outside `SUPPORTED_PROPERTIES` is **refused**, not ignored. A
  silently dropped `float` produces a confidently wrong layout and makes a
  backlog row look landed.
- Fractional and `em`/`rem` lengths are refused, not truncated — the raster is a
  whole-pixel grid.
- An unsupported selector shape (descendant, child, attribute) parses to
  `matchable == false` so it never matches, rather than matching the wrong node.
- Unsupported at-rules are skipped past their **matching** brace. Taking the
  first `}` leaked `@media`'s nested rules into the sheet as a malformed rule.
- Never raise a tolerance budget or re-record a golden to turn a test green.

## Daily commands

```
python tools/g6b.py check
python tools/g6b.py design-compile --spec fixtures/g6lc64-virt.json --out out
python tools/g6b.py boot --spec fixtures/g6lc64-virt.json
python tools/g6b.py qemu-args --spec fixtures/g6lc64-virt.json
python tools/g6b.py holyc-serve --spec fixtures/g6lc64-virt.json --port 2222 --once
python tools/g6b.py http-serve --spec fixtures/g6lc64-virt.json --port 0 --once
python tools/g6b.py loopback --spec fixtures/g6lc64-virt.json --port 0 --once
python tools/g6b.py elf --spec fixtures/g6lc64-virt.json --out out/g6lc_bios.elf
python tools/g6b.py smoke --spec fixtures/g6lc64-virt.json
python tools/g6b.py gr --spec fixtures/g6lc64-virt.json --out out/setup.ppm
python tools/g6b.py display-proxy --spec fixtures/g6lc64-virt.json --out out/proxy.ppm
python tools/g6b.py regress
```

Navigate: plan of record `architecture/PLAN.md`; web-engine endpoint
`architecture/plan-endpoint.md` (B82–B91); keep/refuse map `architecture/ZEAL.md`;
codegen philosophy `architecture/CODEGEN.md`; display-proxy `architecture/DISPLAY.md`;
interactive UI `architecture/BROWSER-RUNTIME.md` (browser loads the LDC cell
on a UI thread; GLES2 `u_dom` onto virtio-gpu/HDMI); subset/config
`architecture/BROWSER.md`; render validation + CSS methodology
`architecture/RENDER-VALIDATION.md`; libwasm host ABI + completion plan
`architecture/LIBWASM-ABI.md`; USB `architecture/USB.md`; menus
`architecture/MENUS.md`; file server `architecture/FILE-SERVER.md`; TLS
`architecture/TLS.md`; kernel HTTP `architecture/KERNEL-API.md`; spec checkouts
`kernel-spec/README.md`.
