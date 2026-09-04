# Kernel HTTP endpoints — JS ↔ HolyC (not SvelteKit)

The BIOS browser does not run SvelteKit. svelte-d `NodeDef` paints UI;
`fetch` / `XMLHttpRequest` / libwasm `Object_Call_string__Handle` are **proxied
into the kernel router**. HolyC `RegisterEndpoint` writes the same table.

```
svelte-d / JS  fetch("/bios/clocks")
        │
        ▼
g6b-js Op::Fetch  ──►  g6b-http::Router  ◄──  HolyC RegisterEndpoint
        │                      │
        │              HTTP/1.1 parse (RFC 9112)
        │              HTTP/2 frames + HPACK (RFC 9113 / 7541)
        ▼                      │
   DOM / UART            compiled BIOS params
```

## Practicality (compiled features)

Each row is a BoardSpec gate. Off ⇒ no `#define`, no route, no IR object.

| Feature | Gate | Cost | Practical in ZealOS/RISC-V BIOS |
|---|---|---|---|
| HTTP/1.1 parse+respond | `kernel.http.http1` | small | **yes** — HolyC + JS default |
| HTTP/2 frames + HPACK static/literal | `kernel.http.http2` | medium | **yes** — web ClientHello-shaped h2 on the adapter |
| HPACK Huffman | always on with http2 | small decode | **yes** — RFC 7541 Appendix B |
| Dynamic HPACK / QPACK | — | large | **no** (refused) |
| JS `fetch` proxy | `kernel.http.proxy_js` | tiny | **yes** |
| `/bios/clocks` | `kernel.params.clocks` | tiny JSON | **yes** |
| `/bios/edk2` | `kernel.params.edk2` | tiny | **yes** (view-only; EDK2 is a loader) |
| `/bios/u-boot` | `kernel.params.uboot` | tiny | **yes** (view-only) |
| `/bios/bootloader` | `kernel.params.bootloader` | tiny | **yes** (`next=opensbi`) |
| `/bios/flash` | `kernel.flash.enable` | small | **yes** — SPI NOR / mailbox / USB; OpenWrt image |
| `/bios/update` | `kernel.flash.self_update` | small | **yes** — BIOS self-update |
| `/bios/settings` | `kernel.settings.enable` | tiny JSON | **yes** — export/import |
| `/bios/settings/usb` | `kernel.settings.usb_key` | small | **yes** — USB key; without USB: UART/mailbox |
| `/bios/profile` `/bios/features` | `kernel.http.enable` | tiny | **yes** — compiled feature map |
| `/bios/usb` `/bios/usb/ls` `POST /bios/usb/flash` | `kernel.usb.flash_fat32` | small | **yes** — **always** with USB; FAT32 firmware only |
| `/bios/files` `/bios/files/{fat32,ntfs,ext4}` | `kernel.usb.key` | small | **yes** — USB-key FileMgr; NTFS/ext4 listing, not flash |
| HTTPS serve | `kernel.http.serve` ∧ `tls.https` | medium | **yes** on adapter until delegate |
| `/ui/index.html` `/ui/app.js` `/ui/ui.wasm` | `kernel.http.files.{html,js,wasm}` | small | **yes** — HolyC `FileServe`; HTTPS when `files.https` |
| `/bios/www` | `kernel.http.files.enable` | tiny JSON | **yes** — listing of mounted UI files |
| TLS ServerHello | `kernel.tls.serve` | small handshake | **yes** — first-party; not OpenSSL |
| USB MSC host | `kernel.usb.enable` | small | **yes** — FAT32 flash default on; not a netdev |
| `/bios/menu` `/bios/menu/{cpu,uncore,…}` | inferred topology/uncore | tiny JSON | **yes** — HolyC `MenuCpu` ≡ browser fetch |
| `/bios/cpu` `/bios/uncore` | aliases | tiny | **yes** |
| SvelteKit `load` / `hooks` / `handleFetch` | `kernel.ui=sveltekit` | Node/kit | **refused** |
| Chromium / goja runtime | — | huge | **refused** |

## Build profiles

`profile` (or `kernel.profile`) is the **baseline**; explicit JSON still wins.

| Profile | Shape |
|---|---|
| `embedded` | UART, SPI self-update, HTTP/1.1, settings UART/mailbox, **USB FAT32 flash**, no file server |
| `router` | embedded + OpenWrt flash + recovery **HTML** file server (no JS/WASM, HTTP not HTTPS) |
| `appliance` | HTML+JS file server over HTTPS + USB-key FileMgr |
| `desktop` | svelte-d + HTML/JS/**WASM** file server over HTTPS + display-proxy |
| `full` | desktop + OpenWrt flash + USB-key FileMgr + HTTPS file server |

Fixture `g6lc32-router.json` is `profile=router`. `g6lc64-virt.json` is `profile=full`.

QEMU BIOS argv still has **no** `-netdev`. After `NET-DELEGATE` the same
router rides `/dev/g6lc-bios`.

## Register once, call from either face

```
RegisterEndpoint("/bios/custom");     // HolyC
kernel.register("/bios/custom");      // JS
fetch("/bios/custom");                // JS / svelte-d / WASM
HttpHandle("GET /bios/custom HTTP/1.1\r\n\r\n");
KernelGet("clocks");                  // → /bios/clocks
```

Spec of WASM imports: `kernel-spec/libwasm` (`Object_Call_*`, `fetch`,
`druntime-wasm` `CRuntime_LIBWASM`). Not compiled.
