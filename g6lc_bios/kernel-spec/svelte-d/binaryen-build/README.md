# binaryen-build

Prebuilt `wasm-opt` from the [etcimon/binaryen](https://github.com/etcimon/binaryen) `svelte-d` fork (Flatten + Asyncify on wasm `try_table`).

`bunx svelte-d setup` downloads the matching host triple here, the same way it fetches LDC 1.43 into `~/.svelte-d/toolchains`. CI (`.github/workflows/wasm-opt.yml`) compiles the `binaryen/` submodule (`--parallel 2`) and publishes `wasm-opt-<triple>.tar.gz` to the **`wasm-opt-binaries`** branch (and the rolling `wasm-opt-svelte-d` GitHub Release). Setup tries the release first, then that branch.

```
binaryen-build/
  LICENSE                 Apache-2.0 (Binaryen)
  README.md               this file
  linux-x86_64/wasm-opt
  linux-aarch64/wasm-opt
  darwin-x86_64/wasm-opt
  darwin-arm64/wasm-opt
  windows-x86_64/wasm-opt.exe
```

Binaries are gitignored. The LICENSE stays in the tree so a project that ships a compiled `wasm-opt` keeps Binaryen’s terms next to the tool.

Override the lookup with `SVELTE_D_WASM_OPT` or `SVELTE_D_BINARYEN_BUILD`. Authors with CMake can still `bun run build-wasm-opt`.
