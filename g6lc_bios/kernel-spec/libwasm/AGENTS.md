# libwasm — Agent Guider (untracked-local)

```
id: libwasm
upstream: https://github.com/etcimon/libwasm.git
pin: 02f21a6 (v0.9.0-11)
mechanism: nested-clone
purpose: D SPA → wasm32-unknown-wasi; replaces LDC defaultlibs
green_command: dub build --arch=wasm32-unknown-wasi --compiler=ldc2 --config=ldc-master
green_cell: LDC 1.43.0-git (ldc2-build) + runtime-v1.43.0 — spa-wasm-eh PASS; spa-phobos is the Phobos cell
persistence: untracked-local
riscv_affinity: none
```

**Is:** spasm-derived WASM framework + vendored `druntime-wasm` + memutils/diet/fast/optional forks.  
**Is not:** stock LDC WASI (`CRuntime_WASI`), wasm-pack, or a general Phobos port.

**Compiler pin:** default LDC **1.43** / master (`__VERSION__ == 2113`) + carried `runtime-v1.43.0`. 1.36 (`2106`) and 1.42 (`2112`) stay as named configs.  
**Process:** `BUILDING.md` — empty WASM `post-switches`, then `dub build --arch=wasm32-unknown-wasi`.  
**Post-link:** Binaryen `wasm-opt --asyncify` for `.await`.

Notes: [`architecture/README.md`](architecture/README.md).

## Navigate

| Intent | Open |
|---|---|
| Why 1.36 / no stock import | `architecture/ldc-136.md`, `BUILDING.md` |
| Runtime vs LDC WASM | `architecture/runtime-vs-ldc.md` |
| Stub kernel / JS events / memory | `architecture/stub-kernel.md`, `js-events-memory.md` |
| CTFE SPA | `architecture/ctfe-apps.md` |
| Generate tree / upgrade 1.42 + wasm-eh | `architecture/runtime-adapt.md`, `upgrade-ldc.md` |
| Carry 1.36 splices onto LDC N±n | `tools/runtime-adapt` `--carry` / `--consecutive` |
| LDC master wasm-eh SPA test | `architecture/wasm-eh-test.md`, `tests/spa-wasm-eh/run.ps1` |
| 1.43 default + major Phobos | `architecture/spa-phobos-test.md`, `tests/spa-phobos/run.ps1` |
| Flags / asyncify | `architecture/flags.md` |
| `_start` / SPA | `source/libwasm/spa.d` |
| Allocator | `source/libwasm/rt/allocator.d` |

## Invariants

- Default cell is LDC 1.43 + `runtime-v1.43.0` (exceptions on). 1.36 pin is `--config=ldc-1.36`. The wasm-eh cell is `tests/spa-wasm-eh`; Phobos cell is `tests/spa-phobos`.
- Do not inherit LDC `-Iimport` on wasm triples.
- Keep `-fno-moduleinfo` on every package in this graph.
- Async imports must be listed on the `wasm-opt --asyncify` command.

## Open

See `architecture/open-questions.md`.
