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
                 LDC 1.43 + DUB + local libwasm/runtime-v1.43.0
                              |
                 public/bios-ui.wasm → out/bios-ui-libwasm.wasm

Bun first-party encoder → out/bios-ui.wasm      bounded g6b-wasm lane
Bun first-party AOT     → out/bios-ui.js        host g6b-js demonstration
Native JS adapter      → out/kernel.js         served as /ui/app.js
App.svelte styles      → out/bios-ui.css        embedded in served HTML
Compiler preview       → out/index.html        not BoardSpec authority
Catalog / hashes       → out/catalog.json, build.json, bios-ui-libwasm.json
```

## Build and test

From this directory in PowerShell:

```powershell
$env:SVELTE_D_LDC="E:\cva6\riscv-compilers\ldc2-build\bin\ldc2.exe"
$env:LIBWASM_ROOT="E:\cva6\g6lc_bios\browser-ui\libwasm"
$env:G6B_DUB_WASM="1"
bun scripts/build.ts
$env:G6B_TEST_LDC_CELL="1"
$env:G6B_TEST_LDC_FX="1"
bun test
```

On other hosts, set the two paths to an LDC **1.43** executable and the local
BIOS libwasm adaptation. No stock LDC defaultlibs or inherited host imports are
used. Missing/incomplete carried runtime, unmatched compiler, failed DUB,
invalid ABI or trapping startup fail the requested build. The current local
runtime carry contains time/demangle/invariant/source-set repairs; those still
need recording in the adaptation generator or a vendored carry for reprovisioning.

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
- `/ui/ui.wasm` is the small first-party VM artifact. The optional
  `/ui/ui-libwasm.wasm` is the LDC component scaffold and particle simulation;
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
  JS Promises. Await-bearing Svelte/Asyncify requests are currently rejected.
- The S-mode ELF still carries the MVP G6UI blob and bring-up helpers. Full LDC
  WASM execution, guest JS continuation installation, RISC-V EH/JIT suspension,
  GPU scanout and an interactive QEMU WASM interface remain open.

Contracts: `../architecture/{BROWSER,WASM,DISPLAY,FILE-SERVER,PLAN}.md`.
