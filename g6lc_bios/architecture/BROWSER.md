# Lightweight BIOS browser

Not Chromium, not Go goja, not puppeteer. Specs:

| Spec | Path | License | Role |
|---|---|---|---|
| goja (ES5 VM contract) | `kernel-spec/goja` | MIT | opcodes / host-object loop; **not linked** |
| lirx-js/dom | `kernel-spec/lirx-dom` | MIT | DOM mutation locality; **not linked** |
| WebIDL | `kernel-spec/webidl/definitions` | MPL-2.0 | interface catalog |
| svelte-d | `kernel-spec/svelte-d` | MIT | Svelte → libwasm/WASM UI; **not LDC** |

First-party MIT rewrite:

```
WebIDL catalog (g6b-webidl)
    →  g6b-dom  live Node/Document/Element/Canvas
    →  g6b-js   AOT ES5 (goja-shaped) against that DOM
    →  browser-ui  svelte-d NodeDef / @prop / {#if} → svelte-engine-ws → WASM
    →  g6b-wasm    MVP decode + KernelHost (g6b-http + DOM) + RISC-V lower
    →  g6b-html parse
    →  display-proxy OpenGL adapter paints DOM status on the high-res plane
```

See [`WASM.md`](WASM.md). Design BIOS screens as `.svelte`; this package lowers a
v1 subset and a `_start` wasm module. Compile is `bun run build` in
`browser-ui/` (LDC 1.43 wasm cell optional via `G6B_DUB_WASM=1`). It does
not compile `kernel-spec/`.

Live interfaces are the BIOS UI + a GL viewport + **Fetch** (kernel HTTP
proxy). SvelteKit `load` / `hooks` / `handleFetch` are **refused**. Everything
else is a named stub (`STUB WebGLRenderingContext`) or refused (WebRTC, add-ons).
`canvas.getContext("webgl"|"opengl")` binds the **display-proxy GL adapter**,
not a GPU driver and not a browser compositor process.

HTTPS is HolyC + `g6b-tls` (SHA-256, AES-128, TLS hello stub) on RISC-V, not
OpenSSL. See `architecture/TLS.md`.

## Browser-UI design notes (flash + file manager)

Two screens share the 640×480 Gr plane and the high-res display-proxy. They
are **svelte-d NodeDef**, not SvelteKit routes. `fetch` hits the kernel
router; HolyC `UsbLs` / `UsbFlash` / `UsbKey` is the other KVM face of the
same table. USB contract: [`USB.md`](USB.md).

| Screen | Gate | Layout (640×480) | High-res proxy |
|---|---|---|---|
| **Flash** | `G6LC_USB_FAT32` (always when USB on) | one column: title `USB-FAT32`, list of `.bin`/`.elf`/`.img`, Flash / Update | same list, larger type; status strip on the GL plane |
| **FileMgr** | `G6LC_USB_KEY` | two panes: volume tabs `fat32 \| ntfs \| ext4` + directory listing | tabs stay left (~280 CSS px), listing fills; DPI from `kernel.proxy.dpi` |

**Flash** is the embedded/router UI. No tabs, no NTFS, no “open folder”.
Selecting a name `POST`s `/bios/usb/flash`. UART-only builds paint the same
list as cells (`id="usb-list"`). Settings without a key stay on UART/mailbox.

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
