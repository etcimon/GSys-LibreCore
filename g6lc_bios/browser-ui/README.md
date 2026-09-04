# browser-ui — GSys LibreCore BIOS UI

TypeScript + Bun project. Svelte sources (not SvelteKit) compile through a
first-party **svelte-d fall-through** into `svelte-engine-ws`, then Bun emits
`out/bios-ui.wasm` for `g6b-wasm` JIT and `out/bios-ui.js` for `g6b-js`.

```
src/*.svelte
    │  compiler/  (svelte-d NodeDef / @prop / @child; refuse Kit)
    ▼
svelte-engine-ws/
    src-svelte/   ingested
    src-d/        mixin NodeDef IR
    src-ts/       jsExports + __svelteD.ts  (lang=ts splice)
    .svelte-d/    IR JSON + manifest
    │  TypeScript + Bun  (not LDC, not Binaryen, not kernel-spec)
    ▼
out/bios-ui.wasm   env.set_inner_text + env.fetch  export _start
out/bios-ui.js     g6b-js AOT (fetch / kernel.holyc / kernel.register)
out/catalog.json   LIVE / STUB / REFUSED constructs
```

`kernel-spec/svelte-d` is the compiler spec (not compiled, not linked). This
package rewrites the bun-side `compileWorkspace` / `dropWorkspace` path for
the BIOS: one wasm module, libwasm-shaped imports, HolyC/kernel `fetch`.

Screens match `architecture/MENUS.md` / crate `g6b-ui` (HolyC-UI ⊥ this
project): Main, CPU, Memory, Uncore, Devices, Boot, Settings, plus Flash /
FileMgr / clocks utilities.

Green: `bun test && bun run build` (also driven by `python tools/g6b.py check`).
