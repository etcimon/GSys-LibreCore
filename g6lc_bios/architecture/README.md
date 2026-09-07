# g6lc_bios architecture

Scaffold docs for the independent BIOS package. Nothing here is compiled.
The **platform is a rewrite** using TempleOS/ZealOS as specs; inferences are
validated against LibreCore (`PLAN.md` §0–§3).

| Doc | Role |
|---|---|
| `PLAN.md` | Living plan + current state (B0–B24 landed) |
| `KERNEL-RV.md` | TempleOS/ZealOS kernel services → RISC-V S-mode / OpenSBI / PLIC |
| `ZEAL.md` | Spec contracts: keep / rewrite / refuse (`kernel-spec/` forks) |
| `DESIGN.md` | BoardSpec → analyze IR → HolyC + HTML+JS + ELF |
| `CODEGEN.md` | ASM IR philosophy: purpose-tagged nodes, not string literals |
| `DISPLAY.md` | Display-proxy: low-res ZealOS plane → HDMI/DP / host-GL |
| `BROWSER.md` | Lightweight BIOS browser (WebIDL live/stub, goja/lirx specs) |
| `TLS.md` | Botan-spec RSA/ECDSA/X.509 + HolyC HTTPS + adapter ports |
| `WASM.md` | WASM-JIT + svelte-d UI (NodeDef, not LDC, not SvelteKit) |
| `LIBWASM-ABI.md` | **Plan.** Full 116-import libwasm host surface; B61–B68 completion sequence |
| `KERNEL-API.md` | HTTP/1.1+HTTP/2 kernel endpoints; JS↔HolyC; compiled BIOS params |
| `USB.md` | USB host: always-on FAT32 flash; USB-key FileMgr FAT32/NTFS/ext4 |
| `MENUS.md` | Inferred setup tree; HolyC-UI ⊥ browser-UI; topology + uncore |
| `FILE-SERVER.md` | HolyC kernel HTTP(S) file server for HTML/JS/WASM |

Host pointer: [`../../architecture/g6lc-bios/README.md`](../../architecture/g6lc-bios/README.md).
Kernel spec checkouts: [`../kernel-spec/`](../kernel-spec/).
