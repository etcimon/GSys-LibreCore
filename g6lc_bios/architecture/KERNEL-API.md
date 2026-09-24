# Kernel HTTP endpoints — JS ↔ HolyC (not SvelteKit)

The BIOS browser does not run SvelteKit. svelte-d `NodeDef` paints UI;
`fetch` / `XMLHttpRequest` / libwasm `Object_Call_string__Handle` are **proxied
into the kernel**. Local `/bios` and `/ui` hit `g6b-http::Router`. Remote
`http(s):` is the same kernel path lowered onto `g6b-hw` TCP. HolyC
`RegisterEndpoint` writes the router table; `HttpGet`/`HttpsGet` go through
`holyc_request`.

```
svelte-d / JS  fetch("/bios/clocks")     fetch("http(s)://…") / HttpGet / HttpsGet
        │                                         │
        ▼                                         ▼
g6b-js Op::Fetch                          kernel_fetch / holyc_request
        │                                         │
        ▼                                         ▼
g6b-http::Router  ◄──  HolyC RegisterEndpoint    g6b-http::plan
        │                                         │
        │              HTTP/1.1 parse             ├─ http:  HTTP/1.1 GET bytes
        │              HTTP/2 + HPACK             └─ https: g6b-tls ClientHello
        ▼                                         ▼
   DOM / UART / BIOS params                  g6b-hw TCP (via=hw-tcp)
```

## Practicality (compiled features)

Each row is a BoardSpec gate. Off ⇒ no `#define`, no route, no IR object.

| Feature | Gate | Cost | Practical in ZealOS/RISC-V BIOS |
|---|---|---|---|
| HTTP/1.1 parse+respond | `kernel.http.http1` | small | **yes** — HolyC + JS default |
| HTTP/2 frames + HPACK static/literal | `kernel.http.http2` | medium | **yes (default on, preferred over HTTP/1.1)** — ALPN `h2` then `http/1.1`; h2c Upgrade; live `H2Session` multiplex + receive windows + CONTINUATION across chunks. |
| HPACK Huffman | always on with http2 | small decode | **yes** — RFC 7541 Appendix B |
| Dynamic HPACK / QPACK | — | large | **no** (refused) |
| JS `fetch` proxy | `kernel.http.proxy_js` | tiny | **yes** |
| iframe / JS / HolyC outbound GET | `kernel.http.outbound` | small | **yes (B92g+B93)** — kernel abstraction: `g6b-http` plans, `g6b-tls` ClientHello, **hw TCP** (`via=hw-tcp`). Off by default; on appliance/desktop/full. Never `-netdev`; iframe guests never KernelPort. HTTPS is not in `g6b-hw`. |
| virtio-net / SoC NIC / display catalog | `kernel.hw.*` | small | **yes (B93)** — `g6b-hw` `HwSession` (`platform.hw`); `VioNetProbe` DeviceID 1; isolated NAT + TCP/UDP; VGA until probe+announce. Never BIOS `-netdev`. |
| `/bios/clocks` | `kernel.params.clocks` | tiny JSON | **yes** |
| `/bios/edk2` | `kernel.params.edk2` | tiny | **yes** (view-only; EDK2 is a loader) |
| `/bios/u-boot` | `kernel.params.uboot` | tiny | **yes** (view-only) |
| `/bios/bootloader` | `kernel.params.bootloader` | tiny | **yes** (`next=opensbi`) |
| `/bios/flash` | `kernel.flash.enable` | small | **yes** — SPI NOR / mailbox / USB; OpenWrt image |
| `/bios/update` | `kernel.flash.self_update` | small | **yes** — BIOS self-update |
| `/bios/settings` | `kernel.settings.enable` | tiny JSON | **yes** — export/import |
| `/bios/settings/usb` | `kernel.settings.usb_key` | small | **yes** — USB key; without USB: UART/mailbox |
| `/bios/store` `/bios/store/{uuid}/*` | `kernel.store.enable` | small | **yes (S5)** — live `StorePort`; UUID instances; HolyC `Store*` even when HTTP is off. Default **on**. `GET …/stat` polls USB live persist (`ready`/`live`). Not SvelteKit |
| `/bios/profile` `/bios/features` | `kernel.http.enable` | tiny | **yes** — compiled feature map |
| `/bios/usb` `/bios/usb/ls` `POST /bios/usb/flash` | `kernel.usb.flash_fat32` | small | **yes** — **always** with USB; FAT32 firmware only |
| `/bios/files` `/bios/files/{fat32,ntfs,ext4}` | `kernel.usb.key` | small | **yes** — USB-key FileMgr; NTFS/ext4 listing, not flash |
| HTTPS serve | `kernel.http.serve` ∧ `tls.https` | medium | **yes** on adapter until delegate |
| `/ui/index.html` `/ui/app.js` `/ui/ui.wasm` | `kernel.http.files.{html,js,wasm}` | small | **yes** — HolyC `FileServe`; HTTPS when `files.https` |
| `/ui/pglite/{pglite.wasm,initdb.wasm,pglite.data,index.js}` | `kernel.store.pglite.files` (+ `pglite.js` for `index.js`) | FileServe of npm dist | **yes (S4a)** — host `mount()` only when bytes live; guest listing only if `pglite.embed`. Not Electric-in-`g6b-wasm` |
| `/bios/www` | `kernel.http.files.enable` | tiny JSON | **yes** — listing of mounted UI files |
| TLS ServerHello | `kernel.tls.serve` | small handshake | **yes** — first-party; not OpenSSL |
| USB MSC host | `kernel.usb.enable` | small | **yes** — FAT32 flash default on; not a netdev |
| `/bios/menu` `/bios/menu/{cpu,uncore,…}` | inferred topology/uncore | tiny JSON | **yes** — HolyC `MenuCpu` ≡ browser fetch |
| `GET /bios/settings/pending` `/bios/cli/screen` `/bios/fw/status` `/bios/hw/stat` `/bios/disk` | live `BrowserSession` | tiny | **yes** — `serve_setup` / `extra_fetch`. The page paints the nodes. The kernel does not write those ids. CLI screen is 404 when `kernel.cli.enable` is off |
| `POST /bios/holyc` | live `BrowserSession` | one line ≤ 480 bytes | **yes** — same text as `holyc_request` (`SettingSet`, `BootSelect`, …). Empty, multiline, or too long is 400 |
| `POST /bios/cli` | live `BrowserSession` | `open` / `close` / `key <name>` | **yes** when `kernel.cli.enable` — 404 when the CLI is off, 409 for a key while closed |
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
HttpGet("http://127.0.0.1/…");        // kernel → hw TCP
HttpsGet("https://…");                // kernel → hw TCP + ClientHello
```

Spec of WASM imports: `kernel-spec/libwasm` (`Object_Call_*`, `fetch`,
`druntime-wasm` `CRuntime_LIBWASM`). Not compiled.
