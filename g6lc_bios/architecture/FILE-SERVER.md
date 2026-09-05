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
        (HTML from g6b-ui; native app.js from browser-ui/src/kernel.ts;
         WASM from browser-ui/out; host boot uses g6b-wasm KernelHost)
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
| `/ui/worker.js` | `application/javascript`, tasking + JS/file gated Dedicated Worker |
| `/ui/ui.wasm` | `application/wasm` (`\0asm`), bounded first-party VM lane |
| `/ui/ui-libwasm.wasm` | `application/wasm`, optional LDC 1.43 component/particle lane |
| `/ui` `/bios/www` | JSON listing |

SvelteKit `+page` routing is refused. The USB-key FileMgr (`/bios/files`) is a
different tree (FAT32/NTFS/ext4 listings), not this UI file server.

## Browser adapter and transport limits (B51)

`app.js` is a native JavaScript module with real menu click handlers, validated
row refresh and WebAssembly imports. It does not assume a global HolyC
`kernel` object and does not execute canned flash/settings mutations.
`kernel.browser.js=off` suppresses its mounting/loading; static HTML retains
all menu rows. `http.proxy_js=false` removes network reads from the adapter.
A failed refresh/module startup reports an error and restores a static view.

The local CLI server binds **127.0.0.1 only**. It frames fragmented HTTP/1
headers and Content-Length bodies, limits a request to 8 KiB, rejects chunked
requests and ambiguous Content-Length, and applies one-second total read/write
deadlines. One request is served per connection with `Connection: close`.
The server remains serial: an idle connection can delay the next by up to a
second, but no longer indefinitely. TLS and HTTP/2 regressions verify the
existing host framing subset, not authenticated browser-compatible TLS.
Use local **HTTP** for the browser preview; do not deploy this stand-in as a
secure remote management endpoint. With `files.root="/"`, `/` remains HTML
and the file listing moves to `/files.json`.

## Optional LDC artifact publication

`kernel.ui=svelte-d` plus WASM/file gates and a nonempty verified artifact add
`ui-libwasm.wasm` to the existing router at the configured file root. JS off
leaves downloads/static settings available but does not instantiate the module.
The served HTML still comes from BoardSpec; the LDC component scaffold is a
separate panel, never a second settings model. Optional `worker.js` is served
from the first-party native worker source only when task services and JS files
are enabled; its local URL/worker bound come from the same BoardSpec. It runs
in a native DedicatedWorker scope, not a ServiceWorker registration or a kernel
network interception process. App.svelte's generated CSS is
embedded in the same HTML. The adapter source remains native JavaScript.

The Bun build checks compiler/runtime input provenance, exact ABI, actual
startup through the restricted DOM host and initial particle memory before
publication. `out/build.json` hashes WASM/JS/HTML/CSS products;
`out/bios-ui-libwasm.json` reports availability and provenance. A requested DUB
failure returns nonzero and clears the optional published file; skipped builds
cannot silently preserve an artifact whose inputs changed. Normal workflow is
Bun build before Cargo embedding, using the package check wrapper rather than
assuming a direct Cargo invocation refreshes generated products.

Host serving embeds the LDC artifact through `g6b-asm`/`g6b-wasm`, but **does not
replace the guest G6UI blob**. Guest `GetFile` still exposes the small MVP module;
the larger LDC module needs the full guest runtime and transport/scanout work.

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
