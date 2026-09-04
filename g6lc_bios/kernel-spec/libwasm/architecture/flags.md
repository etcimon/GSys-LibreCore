# Compiler and Binaryen flags

## How it works

Two layers rewrite the program. LDC 1.36 + LLD produce `*-raw.wasm`. Binaryen `wasm-opt` then **asyncifies** that module so JS can pause it.

### LDC `dflags` (slideshow3dai / dom-ts)

| Flag | Purpose in this tree |
|---|---|
| `--wasm-enable-eh` | Ask LDC’s LLVM 17 WASM backend to emit exception-handling opcodes instead of abort-on-throw. README: this path still has a bug; many Phobos ports are blocked on it. |
| `-mattr=+exception-handling` | Enable the same CPU/feature bit on the LLVM target so object files actually contain EH. libwasm’s library `dub.sdl` sets this without `--wasm-enable-eh`; apps set both. |
| `-fvisibility=hidden` | Hide un-`export`ed symbols (LDC ≥ 1.13). Cuts binary size; JS can only call exported C names (`_start`, `domEvent`, `allocString`, `dumpApp`, `loadApp`). |
| `-flto=full` | Full LTO across D/C++ objects at link. Size/speed; increases compile time. Commented `-Oz` is the extra size hammer. |
| `-fno-moduleinfo` | Do not emit ModuleInfo / `__minfo`. Required because `druntime-wasm` does not register modules the stock way. Also on every helper package. |
| (commented) `-Oz`, `--vv`, `--vtemplates`, … | Debug / size; not part of the default cell. |

### LDC `lflags`

| Flag | Purpose |
|---|---|
| `-strip-all` | Strip mangled names from the wasm (size). Debug becomes harder. |
| libwasm library: `-allow-undefined --export-table --export=domEvent --export=allocString --export=dumpApp --export=loadApp -export=__heap_base` | Leave JS imports unresolved; export the glue ABI. |

### `ldc2.conf` `"^wasm(32|64)-"` (LDC 1.36, after BUILDING.md)

| Setting | Purpose |
|---|---|
| `-defaultlib=` | Do not link `phobos2-ldc` / `druntime-ldc`. |
| `-L-z -Lstack-size=1048576` | 1 MiB WASM stack. `asyncify.ts` hard-codes `DATA_END = 1048576` to match. |
| `-L--stack-first` | Stack below globals so overflow does not clobber data. |
| `-link-internally` | Use LDC’s bundled LLD; no external `wasm-ld` on PATH. |
| `-L--export-dynamic` | Export non-hidden symbols (apps then hide most via `-fvisibility=hidden`). |
| `post-switches = []` | **BUILDING.md.** Stop inheriting `-I` to LDC’s `import/`. |
| `lib-dirs = []` | No stock lib search. |

### Binaryen (`wasm-opt`, not wasm-pack)

```text
wasm-opt --asyncify --pass-arg=asyncify-imports@env.libwasm_await__void \
  public/<name>-raw.wasm -o public/<name>.wasm
```

`--asyncify` instruments every function that can reach that import so the WASM stack can unwind into linear memory and rewind when the JS Promise settles. `--pass-arg=asyncify-imports@env.libwasm_await__void` names the **only** import that is allowed to be async; other imports stay sync. BUILDING.md’s `--asincify` is the same pass, misspelled. The consumer’s `asyncify.ts` (Google’s helper, vendored) must agree on stack bounds (1 MiB) and export names (`asyncify_start_unwind`, …).

Without this pass, `.await` on a JS Promise cannot yield; the import would block the WASM thread or fail.

## Loci

`dub.sdl` (library + examples/dom-ts)  
slideshow3dai `dub.sdl` (consumer)  
`source/libwasm/types.d:181,925-927` — `libwasm_await__void` / `await`  
`examples/dom-ts/src-ts/modules/asyncify.ts`  
`BUILDING.md`  

## Invariants

- Changing stack size in `ldc2.conf` **must** change `DATA_END` in `asyncify.ts`. Convention, easy to miss.
- Do not drop `--asyncify` while `.await` remains in the D API. Construction of the yield protocol.

## Extension points

New async import: add the `extern(C)` symbol, implement it as `async` in JS, and append it to the `asyncify-imports` list.

## Open questions

Whether `--wasm-enable-eh` plus asyncify compose on LLVM 17 is unverified; README already warns EH is buggy.
