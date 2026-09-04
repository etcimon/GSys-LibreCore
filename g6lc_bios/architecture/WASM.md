# WASM-JIT — svelte-d UI on the g6b kernel

`kernel-spec/svelte-d` (MIT) is the **compiler spec**: Svelte syntax falls
through to a libwasm NodeDef graph and one wasm module. BIOS does **not**
compile that tree. `browser-ui/` is the first-party bun+TS consumer:

```
browser-ui/src/*.svelte
        │  svelte-d fall-through (not SvelteKit)
        ▼
browser-ui/svelte-engine-ws/     dub.sdl wasm-eh cell
        src-d/   mixin NodeDef / @prop / @child / mixin Spa!App
        src-ts/  jsExports + window.__svelteD.ts
        .svelte-d/wasm-ldc.json   LDC 1.43 pin (never PATH 1.41/1.42)
        │
        ├─ LDC 1.43 + dub --arch=wasm32-unknown-wasi
        │    libwasm = local clone browser-ui/libwasm (G6LC_G6B)
        │    public/bios-ui.wasm
        │
        └─ bun first-party MVP encoder → out/bios-ui.wasm
                 │
                 ▼
        g6b-wasm decode + KernelHost
                 ├─ set_inner_text → g6b-dom
                 ├─ fetch          → g6b-http::Router
                 └─ jit_riscv      → g6b-asm Purpose::WasmJit
        g6b-elf payload
                 ├─ `.rodata` `__ui_wasm` = out/bios-ui.wasm
                 ├─ BSS `__ui_blob` `G6UI` header (size/flags/ptr/`\0asm`/nfiles)
                 └─ KStart `jal UiInit` / `FileServe` / `GetFile` / `WasmJit` (`i32.add`)
        g6b-js AOT of out/bios-ui.js
                 ├─ fetch / kernel.register → same Router
                 └─ kernel.holyc            → HolyC REPL
```

The local libwasm clone is **not** `kernel-spec/libwasm`. `version(G6LC_G6B)`
turns the JS `Object_Call_*` import table into D stubs that call
`env.set_inner_text` / `env.fetch` — the g6b-wasm Host. vibe.0 host cell
refused (OpenSBI + mailbox).

| svelte-d construct | BIOS |
|---|---|
| `mixin NodeDef!"tag"` | live HTML (`g6b-webidl`) |
| `@prop!"innerText"` / `{msg}` | `SetInnerText` |
| `{#if ident}` / `@visible` | `set_visible` |
| `_start` / `mixin Spa!App` | export `_start`; `WASM-JIT` |
| `{#each}` / `UnorderedList` | stub |
| `{#await}` / Binaryen asyncify | stub |
| `FileMgr` | **live** — kernel `fetch /bios/files/{fat32,ntfs,ext4}` |
| `Menu` | **live** — `fetch /bios/menu/{cpu,uncore}` |
| vibe.0 host cell | refused |
| SvelteKit `+page` / `load` / `handleFetch` | **refused** |

LDC discovery matches svelte-d `findLdc`: `SVELTE_D_LDC`,
`~/.svelte-d/toolchains`, `riscv-compilers/ldc2-build/bin` (this host:
`E:\cva6\riscv-compilers\ldc2-build\bin\ldc2.exe` 1.43.0-git). Full
`dub build` of the ws cell: `G6B_DUB_WASM=1 bun run build`.
