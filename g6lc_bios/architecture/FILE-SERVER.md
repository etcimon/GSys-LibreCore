# HolyC kernel file server (HTML / JS / WASM over HTTP and HTTPS)

The BIOS UI is not Chromium and not a host directory listing. Generated
`index.html`, `app.js`, and `ui.wasm` live in the **kernel router** and are
served by HolyC `FileServe` / `HttpsServe` on the adapter until `NET-DELEGATE`,
then on `/dev/g6lc-bios`. QEMU BIOS argv still has **no** `-netdev`.

```
BoardSpec kernel.http.files
        │
        ▼
g6b-http::files::mount  →  /ui/index.html  /ui/app.js  /ui/ui.wasm
        (wasm/js from browser-ui/out; g6b-wasm KernelHost on boot)
        │
        ├─ HTTP/1.1  GET  (h1 encode, content-type)
        └─ TLS 1.2   ClientHello → ServerHello+Cert+HelloDone
                     application-data record wraps the same HTTP
        │
        ▼
HolyC FileServe("/ui/index.html")
     HttpsServe()
     TlsServerHello("localhost")
g6b http-serve --spec fixtures/g6lc64-virt.json --port 0 --once
```

Framing is first-party (`g6b-tls` ServerHello, RSA+ECDSA suites). Application
records carry plaintext HTTP on the host stand-in; AES-GCM record cipher after
Finished is a later increment. Not OpenSSL, not Botan linked.

## Build gates

| Flag | `#define` / feature | Default by profile |
|---|---|---|
| `kernel.http.files.enable` | `G6LC_HTTP_FILES` / `http_files` | off on `embedded` |
| `html` | `G6LC_HTTP_FILES_HTML` | `router` recovery page |
| `js` | `G6LC_HTTP_FILES_JS` | `appliance`+ |
| `wasm` | `G6LC_HTTP_FILES_WASM` | `desktop`/`full` (needs `kernel.wasm`) |
| `https` | `G6LC_HTTPS_FILES` | `appliance`+ (needs `tls.https`) |
| `kernel.tls.serve` | `tls_serve` | ServerHello compiled with HTTPS serve |
| `files.root` | URL prefix | `/ui` |

JSON overlay still wins:

```json
"http": { "serve": true, "files": { "enable": true, "html": true, "js": true, "wasm": true, "https": true, "root": "/ui" } }
```

`files.wasm` without `kernel.wasm.enable` is a `check()` error. `files.https`
without `tls.https` is refused. Files need `http.serve` (adapter or mailbox).

## Content types

| Path | Type |
|---|---|
| `/ui/index.html` `/ui/` `/` | `text/html` |
| `/ui/app.js` | `application/javascript` |
| `/ui/ui.wasm` | `application/wasm` (`\0asm`) |
| `/ui` `/bios/www` | JSON listing |

SvelteKit `+page` routing is refused. The USB-key FileMgr (`/bios/files`) is a
different tree (FAT32/NTFS/ext4 listings), not this UI file server.

## Guest advert (G6UI)

The OpenSBI payload does **not** mount a VFS. When WASM or HTTP files are
live, `UiInit` writes a 32-byte header at `__ui_blob` (BSS after the UART
line) and the ELF carries `browser-ui/out/bios-ui.wasm` in `.rodata`
(`__ui_wasm`):

| Offset | Word |
|---|---|
| 0 | `G6UI` (`0x4955_3647`) |
| 4 | wasm size (bytes) |
| 8 | flags: bit0 wasm, bit1 js, bit2 html, bit3 gl, bit4 rvv, bit5 ai-island, bit6 jit |
| 12 | `proxy.accel` code |
| 16 | pointer to `__ui_wasm` (64-bit `sd` / 32-bit `sw`) |
| 24 | first word of `__ui_wasm` (`\0asm`) after `FileServe` |
| 28 | nfiles (`/ui/index.html`, `/ui/app.js`, `/ui/ui.wasm` as compiled) |

UART/mbox command `Ui` / `U` prints `UI` (same path as `View` → `VIEW`).
`FileServe` (KStart `jal` after `UiInit`) echoes `\0asm`, stores nfiles, and
prints `FILE` plus each live `/ui/` path. UART/mbox `File` / `F` is the HolyC
`FileServe("/ui")` rewrite (not a VFS).

`GetFile` is GET `/ui/ui.wasm` on the guest blob: UART `Get` / `G` prints
`GET /ui/ui.wasm` (and `HTTP/1.1 200` when `kernel.http.enable`); mailbox
kick `G` writes `\0asm` at RSP+0 and the wasm size at RSP+4 (length 8). After
`NET-DELEGATE` that is the `/dev/g6lc-bios` GET, still **not** a netdev.

Host file-serve still uses `g6b-wasm::BIOS_UI_WASM`; the guest blob is the
in-payload copy.
