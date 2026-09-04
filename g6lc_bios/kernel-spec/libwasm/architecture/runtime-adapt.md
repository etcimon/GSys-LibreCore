# runtime-adapt — generate CRuntime_LIBWASM from LDC

## How it works

`tools/runtime-adapt` is a **host** D/dub package (not on the wasm graph). serve-d loads it as a normal recipe (`dub.sdl` + `source/`). Parsing is **libdparse 0.24** — the same lexer/parser serve-d and D-Scanner use.

It reads the temporary recursive clone `tmp/ldc-1.36.0` (`runtime/druntime/src` + `runtime/phobos`) and the current `druntime-wasm/`, classifies every `.d`/`.di`, then **writes a libwasm-compatible tree** plus JS error-handling stubs that follow `onAssertErrorMsg`.

```text
cd tools/runtime-adapt
dub build --compiler=<host ldc, not the wasm cell>
dub run --compiler=<host ldc> --
# defaults:
#   --ldc-root      ../../tmp/ldc-1.36.0
#   --new-import    riscv-dev/toolchains/ldc2-1.42.0-windows-x64/import
#   --out-dir       ../../tmp/generated-druntime-wasm
```

| kind (1.36 vs libwasm) | n | generate |
|---|---:|---|
| identical | 110 | copy LDC 1.36 body |
| adapted | 21 | copy libwasm body |
| stub-adapt | 4 | copy libwasm body (`object.d`, `core/memory.d`, …) |
| extra | 14 | copy libwasm (`core/sys/wasi`, gccbuiltins, …) |
| missing | 604 | omit — these are the stub-required kernel holes |

`object.d` is **stub-adapt**: LDC 1.36 `object.d` is rejected; the generated file keeps libwasm’s `version(CRuntime_LIBWASM)` guard. That is the same module the wasm `ldc2.conf` junction `import-libwasm` points at.

Upgrade map against LDC **1.42.0** `import/` (DMD 2.112.1): 106 rebase-from-new, 22 reapply-adapt, 24 stub-or-port, 565 still-omit. See `upgrade-ldc.md`.

## Loci

`tools/runtime-adapt/dub.sdl`  
`tools/runtime-adapt/source/{app,parseutil,classify,generate,kernel}.d`  
`tmp/ldc-1.36.0` (clone, gitignored)  
`tmp/generated-druntime-wasm/` (generated)  
`tmp/runtime-adapt-report.md`

## Invariants

- This tool is compiled with a **host** LDC (1.42 in this workspace). Do not pass `--arch=wasm32-unknown-wasi`. Construction.
- Do not replace `druntime-wasm/` with the generated tree until a wasm compile cell matches today’s pin. Convention.
- Newest-LDC upgrade keeps the same classify → copy-or-omit → JS abort stubs loop. Convention.

## Carry (LDC-style) — N±n stock + taught splices

The pin generate **copies** libwasm bodies for the 25 adapted files. That cannot
move to LDC 1.35 or 1.42: you would be pasting 1.36 blobs onto a new frontend.

`--carry` is the LDC-style override (`ldc2/tools/runtime-adapt`):

| Tree | Role |
|---|---|
| **stock** | LDC-N clone (`runtime/…`) or flat `import/` (`--ldc-tag` / `--stock-root`) |
| **generated** | stock + `adapt.d` splices + libwasm-only extras (`core/sys/wasi`) |
| **pin** | `druntime-wasm/` (1.36 adaptations) — FILE-CMP only, never copied onto hook files |

Taught splices in `source/adapt.d` (replay onto **any** LDC-N `object.d` / `rt/lifetime.d`):

- `object.crt-gate` — `version (CRuntime_LIBWASM)` after `module object;`
- `hook._d_allocmemory[T]` — no `GC.malloc`
- `hook._d_throw_exception` — abort on pre-1.43 (DtoThrow still names it; 1.43+ uses `libwasm.rt.eh`)
- `drop-import.*` — no `rt.minfo` / threads / dwarf EH

On `--ldc-tag v1.43.0` (and later) carry **keeps** `phobosMath` / `phobosOther` (numeric, complex, mathspecial, json, regex, random, datetime, …). File/socket/process/concurrency, GC, threads, OS, and stock dwarfeh stay omitted. Pre-1.43 tags still use the pin-curated std set.

`--consecutive` walks adjacent tags. Each tag is **stock-N + the same splices**,
not a copy of N’s tree onto N+1. Missing stock for a tag is skipped (clone
`tmp/ldc-<ver>` or pass `--new-import` for 1.42).

Output is `libwasm/runtime-v<ldcV>/` (gitignored). After emit, `--carry` runs
`ldc2 --version` for that V and compiles `tests/smoke_start.d` with
`-I runtime-vV -d-version=CRuntime_LIBWASM -fno-moduleinfo` (wasm triple,
host fallback).

```text
dub test  --root=tools/runtime-adapt --compiler=ldc2
dub run   --root=tools/runtime-adapt --compiler=ldc2 -- --carry --ldc-tag v1.36.0
dub run   --root=tools/runtime-adapt --compiler=ldc2 -- --carry --ldc-tag v1.42.0
dub run   --root=tools/runtime-adapt --compiler=ldc2 -- --consecutive
```

`missed-libwasm` on FILE-CMP = stock==generated, pin still has a hunk we did
not splice (teach `adapt.d`, do not copy pin).

## Extension points

`--new-import` at a later LDC. `--no-generate` for classify-only. JS stubs land in `generated/js/error-handling.ts` for slideshow3dai / dom-ts to adopt.
`--carry` / `--consecutive` / a new `splices ~=` in `adapt.d`.
