# g6lc_bios architecture

Scaffold docs for the independent BIOS package. Nothing here is compiled.
The **platform is a rewrite** using TempleOS/ZealOS as specs; inferences are
validated against LibreCore (`PLAN.md` §0–§3).

| Doc | Role |
|---|---|
| `PLAN.md` | Living plan + current state (B0–B59, B82–B93, rewrite-from-spec) |
| `SETUP.md` | **Structure.** One setup document, two faces, slots, status painter, live `http-serve` session, glyph rows, guest fences the cell needs |
| `plan-endpoint.md` | **Endpoint.** BIOS web engine: one BrowserSession, one LDC cell; B82–B91c landed, B92 later |
| `plan-iframe.md` | Windowing, Firefox-like tabs, iframe sessions; chrome is Svelte, `g6b-iframe` is the session pool; local app path or remote URL (no `-netdev`) |
| `KERNEL-RV.md` | TempleOS/ZealOS kernel services → RISC-V S-mode / OpenSBI / PLIC |
| `ZEAL.md` | Spec contracts: keep / rewrite / refuse (`kernel-spec/` forks) |
| `DESIGN.md` | BoardSpec → analyze IR → HolyC + HTML+JS + ELF |
| `CODEGEN.md` | ASM IR philosophy: purpose-tagged nodes, not string literals |
| `DISPLAY.md` | Display-proxy: VGA plane vs GPU surface; virtio-gpu / HDMI / host-GL |
| `BROWSER.md` | Lightweight BIOS browser (WebIDL live/stub, goja/lirx/goosie specs) |
| `BROWSER-RUNTIME.md` | **Principle.** Interactive UI = browser + loaded LDC cell + UI-thread GL |
| `TLS.md` | Botan-spec RSA/ECDSA/X.509 + HolyC HTTPS + adapter ports |
| `g6b-hw.md` | Hardware adapters: virtio-net / ethernet / wifi / display catalog; isolated NAT + TCP/UDP; VGA until probe+announce; USB key + pointer HID; kernel fetch lowers onto hw TCP (HTTPS not in this crate; never `-netdev`) |
| `g6b-zealcli.md` | VGA mouse-less ZealOS CLI; HolyC builtin list; `LoadUI`; no `g6b-hw` |
| `WASM.md` | WASM decoder/JIT; LDC cell is the browser *app*, not guest `start_ops` |
| `LIBWASM-ABI.md` | libwasm host surface; B61–B68 sequence; handle model |
| `RENDER-VALIDATION.md` | goosie CSS golden-image methodology (not Playwright) |
| `KERNEL-API.md` | HTTP/1.1+HTTP/2 kernel endpoints; JS↔HolyC; compiled BIOS params |
| `USB.md` | USB host: always-on FAT32 flash; USB-key FileMgr FAT32/NTFS/ext4 |
| `MENUS.md` | Inferred setup tree; HolyC-UI ⊥ browser-UI; topology + uncore |
| `FILE-SERVER.md` | HolyC kernel HTTP(S) file server for HTML/JS/WASM |
| `g6b-pglite.md` | **Design.** First-party registry store + optional Electric PGlite dist wasm; HolyC / `/bios/store` / D `PGLite`. S0 (PR1) submodule + npm pin. |
| `g6b-pglite-svelte.md` | **Tutorial.** svelte-d `pgliteOpen` / `await pgliteStat` / USB live / SQL; parseSvelte call forms. |
| `g6b-store-instances.md` | **Identity.** UUID-led instances, purpose-based BIOS UI, deletable memory, USB key import/export; later iframe bind. |

Host pointer: [`../../architecture/g6lc-bios/README.md`](../../architecture/g6lc-bios/README.md).
Kernel spec checkouts: [`../kernel-spec/`](../kernel-spec/).
