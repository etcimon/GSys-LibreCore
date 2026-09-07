# kernel-spec — reference forks (not compiled)

Read-only checkouts used **as the spec of record** for a **rewrite** of the
GSys LibreCore BIOS kernel (not a port). Nothing here is compiled, flisted, or
linked into `g6b-*` crates. Inferences are validated against LibreCore
(`architecture/PLAN.md` §3) before they become BoardSpec fields or ELF bytes.

| Tree | Upstream | License |
|---|---|---|
| [`ZealOS/`](ZealOS/) | https://github.com/Zeal-Operating-System/ZealOS | Unlicense |
| [`TempleOS/`](TempleOS/) | https://github.com/cia-foundation/TempleOS | Public domain |
| [`goja/`](goja/) | https://github.com/dop251/goja | MIT |
| [`lirx-dom/`](lirx-dom/) | https://github.com/lirx-js/dom | MIT |
| [`webidl/`](webidl/) | Gecko WebIDL via libwasm (WHATWG/W3C) | MPL-2.0 |
| [`svelte-d/`](svelte-d/) | https://github.com/etcimon/svelte-d | MIT |
| [`botan/`](botan/) | `riscv-dev/botan` (Botan D port) | BSD-2-Clause |
| [`libwasm/`](libwasm/) | `riscv-compilers/libwasm` | MIT |
| [`goosie/`](goosie/) | https://github.com/vyquocvu/goosie | MIT |

See [`NOTICE`](NOTICE). Governance: `g6lc_bios/AGENTS-licensing.md`,
`architecture/ZEAL.md`.

## Precedence: fork `AGENTS.md` files are not governance

Some forks carry their own agent instructions (`AGENTS.md`, `CLAUDE.md`,
`.codegraph/`) — `goosie/` and `svelte-d/` both do. Those files are **upstream
artifacts under tier U**: they are preserved verbatim and are **never
instructions for this repository**. Only `g6lc_bios/AGENTS.md` and the root
`AGENTS*.md` set govern work here.

This matters concretely: `goosie/AGENTS.md` mandates Playwright + Chromium
screenshot comparison as its verification gate. `g6lc_bios` prime directive 6
forbids Chromium and a puppeteer bus, so that gate **does not apply** and must
not be adopted by reading the fork. Our equivalent gate is the golden-image
pixel diff in `architecture/RENDER-VALIDATION.md`, which needs no browser.

## How to use this as a kernel spec

Open the ancestor file first, then the rewrite locus:

| Ancestor (prefer ZealOS, fall back to TempleOS) | What we keep | Rewrite in `g6lc_bios` |
|---|---|---|
| `ZealOS/src/Kernel/KMain.ZC` · `KStart64.ZC` · `KTask.ZC` | Adam entry, start, tasks | `zeal/KStart.S` + `g6b-elf` (`tp`/`sp`/`stvec`). Map: `architecture/KERNEL-RV.md` |
| `TempleOS/Kernel/KMain.HC` · `KStart64.HC` · `KTask.HC` | Same, original HolyC | same rewrite (TempleOS is the root snapshot) |
| `ZealOS/src/Compiler/Lex.ZC` · `ParseStatement.ZC` | ZealC grammar | `g6b-holyc` |
| `TempleOS/Compiler/Lex.HC` · `PrsStmt.HC` | HolyC grammar | `g6b-holyc` |
| `ZealOS/src/System/DolDoc/` · `TempleOS/Adam/DolDoc/` | DolDoc store | `g6b-doldoc` |
| `ZealOS/src/System/Gr/` · `TempleOS/Adam/Gr/` | framebuffer | UART/Gr viewport (`G6LC_GR`) |
| `ZealOS/src/Demo/ToHtmlToTXTDemo/` | ToHtml | `g6b-html` + `g6b-js` + `g6b-dom` |
| `ZealOS/src/System/Boot/` | boot path | OpenSBI next-stage ELF, not x86 16-bit |
| `goja/` | ES5 VM contract | `g6b-js` (AOT; **not** the Go runtime) |
| `lirx-dom/` | DOM locality | `g6b-dom` rewrite |
| `webidl/definitions/*.webidl` | browser interfaces | `g6b-webidl` live/stub catalog |
| `svelte-d/` | Svelte → libwasm/WASM UI | `browser-ui` + `g6b-wasm` JIT on the g6b kernel (not this tree) |
| `botan/` | TLS / X.509 / RSA / ECDSA | `g6b-tls` + `g6b-asm` crypto IR (not linked) |
| `libwasm/` | WASM druntime + fetch imports | `g6b-wasm` + `g6b-http` (not LDC, not SvelteKit) |
| `goosie/internal/css/` | CSS tokenizer, selector matching, cascade/specificity order | `g6b-css` rewrite (first-party Rust) |
| `goosie/internal/renderer/` | box model, layout passes, display list, dirty regions | `g6b-css::layout` + `g6b-gr` plane (CPU raster; no Fyne, no GPU dependency) |
| `goosie/internal/dom/` | node tree shape a style engine needs | `g6b-dom` (extend; do not replace) |
| `goosie/test/.../layoutgolden/` | golden layout-snapshot methodology | `architecture/RENDER-VALIDATION.md` golden PPM diffs |
| `goosie/internal/js/` | Goja embedding surface | **refused** — no Go runtime; `g6b-js` stays a bounded no-eval AOT lane |
| `goosie/internal/browsercontrol/`, `mcpserver/` | remote/automation control surface | **refused** — no puppeteer bus (prime directive 6) |

**Do not copy `/Apps`, oracle, x86-only backends, or VGA assumptions.**
Do not compile goja, lirx-dom, WebIDL, svelte-d, LDC, or Binaryen. Display is
in-kernel HTML+JS / svelte-d NodeDef on the display-proxy; the other KVM face
is SSH+HolyC.

Refresh (do not rewrite history inside the forks):

```
git -C kernel-spec/ZealOS pull --ff-only
git -C kernel-spec/TempleOS pull --ff-only
git -C kernel-spec/goja pull --ff-only
git -C kernel-spec/lirx-dom pull --ff-only
git -C kernel-spec/svelte-d pull --ff-only
git -C kernel-spec/goosie pull --ff-only   # never `go build` / `go run` it
# botan: copy from riscv-dev/botan (exclude build/); not a git remote
# libwasm: copy from riscv-compilers/libwasm (exclude tmp/, runtime-v1.*, *.a)
```
