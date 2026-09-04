# Licensing — what the next dependency addition must not do

The next change that copies a file, adds an npm/DUB dependency, or emits a `NOTICE` should treat this as construction.

svelte-D (this design, and a future compiler) is **MIT**. Host commit under LibreCore is **tier T / MIT**, Markdown without inline SPDX (`DOCS_UNDER_TIER`). That is **not** the `riscv-dev/` scaffold CC0, and it is **not** a license on D, LDC, libwasm, vibe.0, Svelte, Binaryen, or app code the printer emits.

Using the D *language* does not relicense anything. Emitting D is unconstrained; generated app `.d` files belong to the application author. The printer must not stamp svelte-D MIT onto those files.

| Work | Terms | How svelte-D may touch it |
|---|---|---|
| D language / reference runtime lineage | Boost (historical) | emit D; do not relicense |
| LDC / LLVM | BSD-3 / Apache-2.0+LLVM exceptions | toolchain pin in manifest |
| Binaryen | Apache-2.0 | invoke `wasm-opt`; do not link into wasm as a library |
| bun / Node / Vite | bun MIT; Node mixed | **app** JS glue inside svelte-engine-ws only, not the compiler |
| Svelte / SvelteKit **syntax** (not the npm compiler) | MIT (syntax is not a work we copy) | implement a Pegged grammar; do not vendor `svelte/compiler` |
| Pegged | Boost | host-cell DUB dep of svelte-d |
| libdparse | Boost 1.0 | host-cell DUB dep; parse D scripts |
| serve-d | MIT | IDE only; do not link |
| libwasm / spasm | MIT, Koppe 2018; Cimon on `dub.sdl` | `import libwasm`; copy notices |
| diet-wasm | MIT, Ludwig 2012–2014 | wasm-cell only |
| memutils-wasm / fast-wasm / optional-wasm | their MIT | wasm-cell |
| vibe.0 | MIT Ludwig 2012–2015, Cimon 2014–2023 | `import vibe.vibe`; NOTICE |
| vibe.0 `data/dom.d`, `data/xml.d`, `db/pgsql/pgsql.d`, `db/sqlite/sqlite3.d` | **Boost 1.0** | inherit if imported |
| vibe.0 `http/cookiejar_dates.d` | **BSD-3** | inherit if imported |
| memutils, botan, libasync, libhttp2 | their terms (host catalog) | host cell |
| Google `asyncify.ts` | Apache-2.0, Copyright 2019 Google Inc. | **keep the header** when copying |
| lodash, moment | MIT | optional **app** JS, not compiler runtime |
| PgLite | Apache-2.0 | JS only; not a D/wasm link object |

**Hard guards.** Do not vendor GPL into the D/wasm link set (LibreCore FPGA bootrom GPL-2.0-or-later and `dma-mapping.h` GPL-2.0-only are unrelated and must stay unrelated). Do not rewrite third-party SPDX or copyright lines (`E-UPSTREAMWRITE` analog). Do not assert svelte-D MIT over a third-party file because we generate a call site. `DisableDebugger` is not a license issue; Boost/BSD file exceptions are.

When the compiler first copies glue templates, the same PR adds a `NOTICE` template listing Koppe, Ludwig, Cimon, Svelte authors, and Google Inc. as applicable.

## Loci

`libwasm/LICENSE.md`  
`libwasm/diet-wasm/LICENSE.txt`  
`vibe.0/LICENSE.txt`  
`slideshow3dai/src-ts/modules/asyncify.ts:1-15`  
host `.licensing-policy` (`LICENSE_TIER_T=MIT`, `DOCS_UNDER_TIER`)  
`riscv-dev/LICENSE` (CC0 scaffold — does not swallow this folder)  
`../LICENSE.md` (full MIT text + tables)

## Invariants

- Glue copies keep original copyright headers. (construction of Apache-2.0 / MIT attribution)
- Private env never appears in `generated/client`. (construction — also a security rule)
- No GPL object in the default wasm or host link line. (construction)

## Did not close

Whether generated apps get a `NOTICE` always or only when the adapter copies third-party glue (recommendation: always when glue is copied). Whether Boost file exceptions should be listed even if the printer’s default import graph might not reach `pgsql.d` (recommendation: list them if `import vibe.d` is emitted, because the barrel is wide).
