# Setup page — one BoardSpec, two faces

**Status:** structure of the setup UI after `9b5c140` (`g6lc_bios: keep one
setup page and omit IP addresses from TLS SNI`). Nothing here is compiled.
The living changelog stays in [`PLAN.md`](PLAN.md). The web-engine thesis
stays in [`plan-endpoint.md`](plan-endpoint.md). This file is the layout of
the page the operator actually gets.

Two faces read one `BoardSpec`. The keyboard face is `g6b-zealcli`. The
browser face is `browser-ui/src/App.svelte`, published as
`browser-ui/out/index.html` and included by `g6b-ui::setup_html`. Both call
the same HolyC names and fail closed when the matching gate is off. The
kernel returns fetch bodies. It does not `set_inner_text` the status nodes
the page owns.

`g6b-ui` must not depend on `g6b-zealcli` (that cycles
ui → zealcli → holyc → http → ui). Boot-entry HTML and the Wi-Fi catalog
line live in `g6b-spec` so the UI crate can inject them without that edge.

## Three pictures

These are different evidence. A screenshot of one is not a proof of another.

| Picture | What runs | What a shot shows |
|---|---|---|
| Host CSS | `BrowserSession` paints the shell with `g6b-css` (`ui_ppm32` / display-proxy) | The styled setup page |
| Guest glyph | First-party `browser-ui/out/bios-ui.wasm` lowered by `start_ops` into `__ui_dom`, then `DomPaint32` | Flat rows on the virtio-gpu plane. `fixtures/g6lc64-web-hd.json` sets `kernel.wasm.jit` and leaves `guest_jit` false, so this ELF does not run the LDC cell |
| LDC cell | `browser-ui/out/bios-ui-libwasm.wasm` inside `BrowserSession::wasm_ui` | Fetches and `g6b_listen`. On the kernel host it adopts the shell instead of leaving a second page |

`python tools/g6b.py check` rebuilds the first-party wasm and `index.html`.
It does not rebuild the LDC cell (`G6B_DUB_WASM` is off), so a green check
can leave `bios-ui-libwasm.wasm` at the bytes already in the tree.

## The document

`App.svelte` is the source. `g6b-ui` compiles in `browser-ui/out/index.html`
with `include_str!` and then injects BoardSpec rows. The compiler strips
HTML comments, so a feature gate cannot be a `<!--g6b:…-->` marker. Gates
are real elements.

The painted root is `<main id="bios-ui">`. Stable row ids are
`menu-{id}`, `field-{menu}-{id}`, `label-{menu}-{id}`, `row-{menu}-{id}`,
and `access-{menu}-{id}`. `g6b-ui` fills each `<tbody id="menu-…-body">`.
`index_html_keeps_every_app_svelte_id` fails the build when an id in
`App.svelte` is missing from `out/index.html`.

A row in `g6b_spec::WRITABLE` gets a Set control (`setting_control`): an
enum `<select>`, yes/no, or a text/number input, plus
`data-setting-apply`. The click posts `SettingSet` on the session overlay.
The compiled row text stays the value from this boot. Everything not in
`WRITABLE` is a view of what was compiled. The table is boot next / hotkey /
timeout / volume / autoboot, `cpu_hz`, UART baud, the settings start menu,
CLI boot / mouse / geometry, and `kernel.flash.url`. Cache sizes and TLB
depth are not BoardSpec fields and are not shown.

### Slots

`clear_slot` empties the interior of `<div id="g6b-slot-…">` and stops at
the first `</div>`. The wrapper stays, so a later `</section>` is not eaten.
Slot interiors must not contain nested `div`s.

| Slot | Emptied when |
|---|---|
| `g6b-slot-boot-media` | `kernel.cli.autoboot.enable` is off |
| `g6b-slot-console` | `kernel.cli.enable` is off |
| `g6b-slot-manual` | `kernel.http.outbound` is off |
| `g6b-slot-fw` | `kernel.cli.fw` is off |
| `g6b-slot-save` | settings export is off |
| `g6b-slot-load` | settings import is off |

When autoboot is on, `#boot-entries-body` is filled from
`listed_boot_entries`: payload, then `bios-ui` when the web stack is
compiled. That list does not invent volumes. Volume media is probed by
zealcli `Ports`. `BootSelect` records `BOOT-PICK` and does not rewrite the
compiled row text.

The Devices Wi-Fi line is `wifi_catalog_line`: compiled adapter id and
model, or "no adapter". No SSID and no association. `GET /bios/disk` is
`disk_json` over those ports (name, filesystem, boot proof). The proof
names a loader only when that file was actually listed. Size is `n/a` when
the port has no capacity. Modelled `KEY-FAT:` stays read-only; vi `:w` is
the `mount -w` path.

## Who writes the page

```
App.svelte ──bun──► out/index.html ──include_str──► g6b-ui::setup_html
                                                      │ rows, slots, libwasm mount
                                                      ▼
                                            BrowserSession.dom  (the shell)
                                                      │
                         cell _start ── adopt existing ids; do not clone the page
                                                      │
native kernel.ts applySetupFaces ◄── GET bodies ── fetch_extra
```

`applySetupFaces` in `browser-ui/src/kernel.ts` is the painter. `navigate`
calls it, including on a menu change. A disabled fetch proxy must swallow
these reads and must not issue menu writes.

| Node | GET | Body |
|---|---|---|
| `#settings-pending` | `/bios/settings/pending` | pending overlay JSON |
| `#cli-screen` | `/bios/cli/screen` | console text (404 when the CLI is off) |
| `#fw-digest` | `/bios/fw/status` | the `sha256=` line from `fw status` |
| `#hw-nat-status` | `/bios/hw/stat` | `nat` and `phase` |
| `#disk-body` | `/bios/disk` | volume JSON, painted as rows |

Until the painter runs, the shell still says "no pending settings writes"
and "digest: (none)". `paint_response` is not taught to fill these ids.

## Session modules

`BrowserSession` is still the UI-thread runtime
([`BROWSER-RUNTIME.md`](BROWSER-RUNTIME.md)). The setup behaviour is split
so the next control does not land in the wrong arm of `cell_click`:

| Module | Owns |
|---|---|
| `g6b-kernel/src/session.rs` | construction, the painted tree, `select_menu`, `shell` |
| `g6b-kernel/src/actions.rs` | `shell_click`: `data-boot`, `data-settings`, `data-net`, `data-fw`, `data-manual`, `data-console`, `data-setting-apply` |
| `g6b-kernel/src/fetch_extra.rs` | `extra_fetch` and `serve_setup` |
| `g6b-kernel/src/lib.rs` | `cell_click`: refresh, then `shell_click`, then a menu tab |

`shell` is one `g6b_zealcli::Session`. Console `set`, page **Set**, and
Save/Load share that overlay. Save is `SettingsExport("uart")`. Load is
`SettingsImport("uart")` of the last export on this session, not a USB
`settings.json`. The overlay is a BoardSpec patch for the next boot. It
does not rewrite the running spec or the compiled row text.

The console is that same shell, not a second CLI. `POST /bios/cli` bodies
are `open`, `close`, or `key <name>`. `open` sets `console_open`. `key`
is 409 while closed, 400 on a refused name, 404 when the CLI is compiled
out. The page paints `#cli-screen` from the response. A console key does
not change the setup tab.

The manual control is one iframe-session slot (`g6b-iframe` is a session
pool, not a window manager and not an `<iframe>` element). Outbound off
clears the slot and fails closed. QEMU BIOS argv still has no `-netdev`.

## One DOM

`setup_html` already contains `<main id="bios-ui">`. The LDC `ready()`
still `createElement`s and `appendChild`s a second copy, then
`setProperty(..., "id", ...)`. On the kernel host that id write adopts the
shell node (`WASM-ADOPT-ID`) instead of renaming the staging node. If the
cell appended the staging node first, the host detaches it so `#libwasm-root`
does not keep a blank `<main>`. An append whose parent or child is already
adopted is a no-op (`WASM-APPEND-ADOPTED`). `innerText` on an adopted node
that already has element children is a no-op, so the cell cannot wipe the
shell labels.

`strip_cell_page_clone` still drops a `<main id="bios-ui">` that landed
under `#libwasm-root`, and it runs before `g6b_listen` is bound, so the
listener attaches to the shell tab. `live_paint_root` walks past the mount
and returns the shell. `path_to_id` prefers a node outside `#libwasm-root`.

An empty mount has no shell ids, so adopt does not fire. The bun tests that
instantiate the shipped cell through the JS libwasm host still expect a
`MAIN` child and a full node count. That host is not the kernel document.

The shipped cell does emit `g6b_listen` and `jsCallback`. Rust `select_menu`
remains the default action when the cell does not `preventDefault`.

## File server

`g6b http-serve` keeps one `BrowserSession` for the life of the process.
`dispatch_http` tries `serve_setup` before `Router::handle_bytes_store`.

| Request | Handler |
|---|---|
| `POST /bios/holyc` | `submit_setup_line` on that session. Empty, longer than 480 bytes, or a newline is 400 |
| `POST /bios/cli` | the console verbs above |
| `GET` of the five status paths | `extra_fetch` |
| anything else | the stateless router (files, `/bios/menu`, `/bios/store` through `StorePort`) |

HTTP/1 responses get `Connection: close`. Static `/bios/menu` stays on the
router. The native page posts the same HolyC line `holyc_request` accepts.
It does not grow a third interpreter. See [`FILE-SERVER.md`](FILE-SERVER.md)
for the file routes and [`KERNEL-API.md`](KERNEL-API.md) for the endpoint table.

## Glyph rows

`DomPaint` / `DomPaint32` paint a row when it has both text and the visible
flag. `set_visible(id, 0)` clears that flag when the id already has a row.
A hidden parent with no text of its own does not create a row, so the
encoder clears the flag on each text id underneath it.

`emit-wasm.ts` `glyphHiddenTextIds` appends `set_visible(id, 0)` for text
ids under a `hidden` ancestor. `projectHtml` does not stamp `hidden` onto
those descendants: the HTML shell is what `g6b-ui` injects rows into, and
a stamped `hidden` would hide the injected row. The font folds `a-z` onto
`A-Z`. Detail of the blit stays in [`DISPLAY.md`](DISPLAY.md) and
[`WASM.md`](WASM.md).

## Guest fences the cell needs

Two exec facts are part of running this page on the guest, not part of the
HTML:

- `MAX_JIT_LOCALS` in `g6b-asm` `jfmt.rs` is 2048. The shipped cell has a
  function frame of 1057 locals. The decoder ceiling stays 4096. A lower
  fence refuses the cell with `jcode: func 11 locals … exceeds bound`.
- RV64 `slli` with a shift of 32..63 sets funct7's low bit (the encoding of
  `slli t1, t1, 48` is `0x03031313`). `VioCmd` masks `avail.idx` with
  `slli`/`srli` by `xlen-16`. The OP-IMM decoder accepts that shift when
  `(funct7 & 0x7e) == 0` and XLEN is 64. RV32 still rejects funct7 = 1.
  Crypto funct7 `0x08` / `0x19` is unchanged.

## TLS peer name

An IP literal is the TCP address, not a server name (RFC 6066).
`client_hello_for_peer` omits SNI for an `IpAddr` and uses
`client_hello_with` for any other host. A refused name returns `tls: sni`
instead of panicking. HolyC `TlsClientHello`, `TlsServerHello`, and
`HttpsGet` use that helper. TLS 1.3 `client_hello_tls13` and
`client_hello_tls13_psk` share `push_server_name`, which skips the
extension for an IP and still computes the PSK binder over the hello that
is sent. A host with a port (`127.0.0.1:443`) is not an address literal and
is still refused. Detail stays in [`TLS.md`](TLS.md).
