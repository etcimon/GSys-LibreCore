# Licenses — svelte-D design and every language/runtime it depends on

This file is the license surface for **this design workspace** and a map of terms for works svelte-D will *use* or *emit toward*. It does not relicense those works. It is not legal advice.

Markdown in this folder takes **no inline SPDX header** when committed under the LibreCore host (`DOCS_UNDER_TIER`). The SPDX expression for *this* original work is `MIT`.

---

## 1. This design (and a future svelte-D compiler)

Copyright (c) 2026 Etienne Cimon and contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

If this folder is committed into the GSys LibreCore host worktree, it is **tier T = MIT** (see host `.licensing-policy`). That is independent of the `riscv-dev/` scaffold’s **CC0-1.0** dedication, which applies only to the scaffold surface named in `riscv-dev/LICENSE`, not to this original work.

---

## 2. Using the D language does not relicense anything

The D programming language specification and reference implementation are under their own terms (historically Boost for the language/runtime lineage). **Writing or generating D source is unconstrained by svelte-D.** Generated `.d` files belong to the application author. svelte-D does not place its MIT on emitted app code unless the author copies compiler-owned headers into that code (the printer must not).

---

## 3. Toolchain (not linked into app objects as svelte-D product)

| Work | Role | Terms (as commonly distributed) | svelte-D rule |
|---|---|---|---|
| LDC | D compiler, both cells | BSD-3-Clause / LLVM exceptions (LDC/LLVM) | Toolchain. Do not vendor LDC. Pin versions in the manifest. |
| LLVM (inside LDC) | backend | Apache-2.0 with LLVM exceptions | Toolchain. |
| DUB | package driver | MIT | Toolchain. |
| Binaryen `wasm-opt` | post-link asyncify | Apache-2.0 | Toolchain. Not part of the D/wasm *link set* as a library. |
| bun / Node | compiler host | bun: MIT; Node: various | JS-side only. |

---

## 4. Runtime and library works svelte-D emits *toward*

These stay under **their** licenses. svelte-D must preserve copyright and permission notices when it copies files (JS glue, templates). It must not relicense them. Generated apps that `import libwasm` / `import vibe.d` are **derivative of those libraries in the usual way** and must comply with those libraries’ terms (MIT attribution is the typical duty here).

| Work | Pin referenced | License | Notes |
|---|---|---|---|
| **libwasm** (fork of spasm) | live HEAD `64a97ce` / tag `v0.10.0` (2026-08-14). `AGENTS.md` header still says `02f21a6`. `setenv-wasm.ps1` add-locals **`0.9.0`**. | MIT — Copyright (c) 2018 Sebastiaan Koppe; authors also Etienne Cimon (`dub.sdl`) | `E:\cva6\riscv-compilers\libwasm\LICENSE.md`. Bindings + SPA + replacement runtime. |
| **spasm** (upstream lineage) | — | MIT — Sebastiaan Koppe | Attribution travels with libwasm. |
| **diet-wasm** (inner package) | path `./diet-wasm` | MIT — Copyright (c) 2012-2014 Sönke Ludwig | `libwasm/diet-wasm/LICENSE.txt`. Wasm-cell only. |
| **memutils-wasm**, **fast-wasm**, **optional-wasm** | inner packages | their own MIT (see each tree) | Wasm-cell. |
| **vibe.0** (`vibe-0`) | `eb51b27` / tag `v1.2.1` | MIT — Copyright (c) 2012-2015 Sönke Ludwig; (c) 2014-2023 Etienne Cimon | `E:\cva6\riscv-dev\vibe.0\LICENSE.txt`. **File exceptions below.** |
| **vibe.d** (lineage) | fork-era identity `"0.7.23"` | MIT | Do not conflate git tag 1.2.1 with `vibeVersionString`. |
| **memutils**, **botan**, **botan-math**, **libasync**, **libhttp2** | `modules.json` host catalog | their own MIT / terms | Host cell. memutils is **undeclared** in vibe.0 `dub.json` but required. |
| **Svelte** / **SvelteKit** / `svelte/compiler` | JS parse dependency | MIT | JS-side of the bun compiler **only**. Not a D/wasm link. |
| **Google asyncify.ts** | vendored in slideshow3dai `src-ts/modules/asyncify.ts` | Apache-2.0 | Copyright 2019 Google Inc. Keep the header when copying. |
| **lodash** | optional app JS | MIT | App dependency, not compiler runtime. |
| **moment** | optional app JS | MIT | App dependency. |
| **PgLite** (`@electric-sql/pglite`) | slideshow3dai JS | Apache-2.0 | JS-only. Do not pull into the D/wasm link set as a C/GPL object. |

### vibe.0 file exceptions (do not forget)

From `vibe.0/LICENSE.txt`:

- `source/vibe/data/dom.d` — Boost License 1.0
- `source/vibe/data/xml.d` — Boost License 1.0
- `source/vibe/db/pgsql/pgsql.d` — Boost License 1.0 (docs: PostgreSQL manual open license)
- `source/vibe/db/sqlite/sqlite3.d` — Boost License 1.0
- `source/vibe/http/cookiejar_dates.d` — BSD-3-Clause

A svelte-D generated server that imports those modules inherits those file terms. The printer’s default `import vibe.vibe` already reaches some of this graph; NOTICE generation must list them when the host cell is emitted.

---

## 5. Hard guards

1. **Do not vendor GPL into the D/wasm link set.** LibreCore’s FPGA bootrom is GPL-2.0-or-later and is a separate work. Host `dma-mapping.h` is GPL-2.0-only. Neither is a svelte-D dependency. If an app author adds a GPL D library to the wasm graph, that is their conveyance problem; the compiler must not do it by default.
2. **Do not emit a second `SPDX-License-Identifier` onto third-party files** (LibreCore `E-TIERCONFLICT` / `E-UPSTREAMWRITE` analog). Copy glue with original headers intact.
3. **Do not assert svelte-D MIT over libwasm or vibe.0** on the strength of generated call sites.
4. **Attribution:** applications and the compiler distribution include a `NOTICE` (or equivalent) listing MIT copyrights actually copied (Koppe; Ludwig; Cimon; Svelte authors; Google asyncify).

---

## 6. Host LibreCore tiers (only if committed here)

| Path | Tier | SPDX |
|---|---|---|
| `riscv-dev/svelte-D/**` (this design, future TS compiler if placed here) | **T** | MIT |
| `riscv-dev/AGENTS*.md` scaffold | scaffold CC0 (not this folder) | CC0-1.0 |
| Nested checkouts `libwasm`, `vibe.0`, `slideshow3dai` | **not** this folder; their own terms | unchanged |

Active contributor recorded in host `.active-contributor` is Etienne Cimon. CLA is not required for tier T.
