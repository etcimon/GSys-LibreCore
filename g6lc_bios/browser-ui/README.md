# browser-ui — GSys LibreCore BIOS UI

First-party Bun/TypeScript Svelte front end, not SvelteKit. The compiler emits
`svelte-engine-ws` with one libwasm `Spa!App`, plus a separate bounded MVP
WASM/AOT demonstration. **LDC 1.43** compiles the generated D workspace through
DUB and the local carried `libwasm/runtime-v1.43.0`. The TypeScript front end
itself is not an LDC-built compiler executable; `kernel-spec` remains reference-only.

```text
src/*.svelte → compiler/ → svelte-engine-ws/
                            src-d/       NodeDef / @prop / @child + particle D
                            src-svelte/  ingested components
                            src-ts/      host exports
                            .svelte-d/   IR, isolated LDC config, provenance
                              |
                 LDC 1.43.0-beta1 (pinned, toolchains/ldc.lock.json)
                 + bundled DUB + local libwasm/runtime-v1.43.0
                              |
                 public/bios-ui.wasm → out/bios-ui-libwasm.wasm

Bun first-party encoder → out/bios-ui.wasm      bounded g6b-wasm lane
Bun first-party AOT     → out/bios-ui.js        host g6b-js demonstration
Native JS adapter      → out/kernel.js         served as /ui/app.js
App.svelte styles      → out/bios-ui.css        embedded in served HTML
Compiler preview       → out/index.html        not BoardSpec authority
Catalog / hashes       → out/catalog.json, build.json, bios-ui-libwasm.json
```

## Pinned LDC toolchain

The optional libwasm cell is built by **one pinned upstream LDC release**, not
by whatever `ldc2` the host happens to have. The pin is
[`toolchains/ldc.lock.json`](toolchains/ldc.lock.json):

| field | value |
| --- | --- |
| release | [`v1.43.0-beta1`](https://github.com/ldc-developers/ldc/releases/tag/v1.43.0-beta1) |
| frontend | DMD 2.113.0 (what `libwasm/runtime-v1.43.0` is written against) |
| source | `github.com/ldc-developers/ldc` release assets only |
| integrity | upstream `ldc2-1.43.0-beta1.sha256sums.txt` digest per host asset |
| DUB | bundled in the release (`bin/dub`), so LDC and DUB are never mismatched |

Install it (idempotent, ~46-97 MB depending on host):

```powershell
bun run install-ldc          # or: bun scripts/install-ldc.ts
bun run check-ldc            # report only; non-zero when not installed
bun scripts/install-ldc.ts --force   # re-download and re-extract
```

The installer downloads the asset for the running host, **verifies the pinned
SHA-256 before extracting**, extracts into
`toolchains/ldc2-1.43.0-beta1-<host>/`, re-runs `ldc2 --version` and refuses
anything that is not exactly the pinned release, then writes
`toolchains/installed.json`. `toolchains/` is gitignored apart from the lock
file, so the tree is reproducible from the pin rather than vendored.

Then build the cell:

```powershell
bun run build-libwasm        # install-ldc + G6B_DUB_WASM=1 bun scripts/build.ts
```

`compiler/ldc.ts` prefers the pinned tree over any ambient toolchain, because
the artifact provenance hash (`.svelte-d/wasm-artifact.json`) covers the
compiler binary itself: a host-built `1.43.0-git-<sha>` snapshot is a
*different* compiler and would mark the shipped artifact stale on every other
machine. Precedence is:

1. `SVELTE_D_LDC` / `LDC` / `WASM_LDC` / `SVELTE_D_WASM_LDC` (explicit escape hatch)
2. `toolchains/ldc2-1.43.0-beta1-<host>/bin/ldc2` (the pin)
3. `DC`, `~/.svelte-d/toolchains`, repo seeds, `PATH`

`resolveToolchain().pinned` reports which of these won.

`ldc2-1.43.0-beta1-addon-wasi.tar.xz` is deliberately **not** pinned: the cell
links `-defaultlib=` against the carried `libwasm/runtime-v1.43.0`, so no
prebuilt WASI druntime/phobos is used. A host with no published LDC build
(`windows-arm64`) is refused with that message; only the optional cell is
affected, `out/bios-ui.wasm` needs no D toolchain at all.

## Build and test

From this directory in PowerShell:

```powershell
bun run install-ldc
$env:LIBWASM_ROOT="E:\cva6\g6lc_bios\browser-ui\libwasm"
$env:G6B_DUB_WASM="1"
bun scripts/build.ts
$env:G6B_TEST_LDC_CELL="1"
$env:G6B_TEST_LDC_FX="1"
bun test
```

`LIBWASM_ROOT` is optional when the checkout is in its normal place; set it to
the local BIOS libwasm adaptation if discovery fails. No stock LDC defaultlibs
or inherited host imports are used. Missing/incomplete carried runtime,
unmatched compiler, failed DUB, invalid ABI or trapping startup fail the
requested build. The current local runtime carry contains
time/demangle/invariant/source-set repairs; those still need recording in the
adaptation generator or a vendored carry for reprovisioning.

Set `G6B_WASM_ASYNCIFY=1` to run the custom Binaryen `wasm-opt --asyncify` pass
after LDC link (enabling the D `await`/`catch` build path). Asyncify is skipped
when no D source uses `await` unless explicitly requested.

Without `G6B_DUB_WASM=1`, `bun run build` generates MVP/JS/HTML/CSS and retains
an optional LDC module only if source/runtime/compiler/adapter hashes and startup
verification still match. Stale or absent optional output becomes an empty file
with explicit unavailable status. Actual compiler probes are opt-in via the two
test variables above; default tests do not claim those probes ran.

From the BIOS package root:

```text
python tools/g6b.py check
python tools/g6b.py regress
python tools/g6b.py http-serve --spec fixtures/g6lc64-smt2.json --port 8080
```

Use local HTTP; production authenticated TLS is not implemented by this preview.
`http-serve` uses the kernel router and BoardSpec settings, not a directory server.

## Runtime/display boundaries

- Both HolyC and browser menus use the same BoardSpec rows. JS-off, read-proxy,
  utility and file gates remain effective. Values are read-only; F10 refreshes,
  never saves. Left/Right/Home/End navigate while focus is in setup controls.
- `/ui/ui.wasm` is the LDC libwasm cell when live (MVP encoder otherwise).
  `/ui/ui-libwasm.wasm` is the same LDC artifact. `/ui/g6lc.svg` is a bundled
  mark for `<img src>` / `fetch("/ui/…")`. The optional particle simulation;
  its imports use D `(length,pointer)` strings and an i32 exception tag.
- The LDC scaffold explicitly disables its unused D router. Unsupported object,
  event, Promise and runtime calls trap rather than inventing successful values.
  Complete Svelte tree/reactivity/routes/lifetime handling is still open.
- With `kernel.ui=svelte-d`, JS/WASM/files enabled and `kernel.proxy.enable/gl`,
  native WebGL renders D/WASM particles and a moving GSys LibreCore text wordmark
  behind translucent App.svelte CSS. Geometry/DPI/refresh come from BoardSpec;
  pause, reduced-motion, hidden-tab and context-loss handling preserve setup.
  CSS is extracted static CSS, not CSS executed as WASM or full Svelte scoping.
- The Rust JS continuation subset supports nonblocking await-fetch/throw/catch
  through explicit scheduler polls. This does **not** imply D Asyncify or general
  JS Promises. The LDC/libwasm build path now runs Binaryen Asyncify when
  requested or when the generated D source uses `await`; the full D
  `await`/`catch` Promise-continuation host driver and Svelte lowering are still
  open.
- The S-mode ELF still carries the MVP G6UI blob and bring-up helpers. Full LDC
  WASM execution, guest JS continuation installation, RISC-V EH/JIT suspension,
  GPU scanout and an interactive QEMU WASM interface remain open.

Contracts: `../architecture/{BROWSER,WASM,DISPLAY,FILE-SERVER,PLAN}.md`.
