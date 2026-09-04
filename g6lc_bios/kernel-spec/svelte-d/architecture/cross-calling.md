# Cross-calling — lang=d ↔ lang=ts through Lodash and exportDelegate

The next change that invents a per-function WASM import table, a second handle table, or arity-strict overloads so D can call TypeScript should read this and then stop.

**Guiding construction:** the two script cells stay two cells. Crossing uses seams that already exist: Lodash `invoke` on `window.__svelteD.ts`, and libwasm `exportDelegate` / `callNative`. The printer keeps the **simple name** in the file that declared the function. Registry keys are **module-mangled** (`identFromRel` + `_mod` for `context="module"`) so two `.svelte` files may both export `greet`. Calling is not arity-strict: only the arguments you wrote are forwarded; omitted trailing parameters keep the JS or D default.

```
.svelte  <script lang="ts"> export function greet(name = "world")
         <script lang="d">  this.update.msg = greet("Ada");
                            extern(C) export int add(int a, int b = 0)
──────────────────────────────────────────────────────────────────────
src-ts/modules/generated/<ident>.ts
   greet(...args) + jsExports.env.greet(...args)
   ensureSvelteD().registerTs(ident, "greet", fn)
   window.__svelteD.ts[ident].greet

src-d/<path>.d
   string greet(ARGS...)(auto ref ARGS args)
     → callTs!string("ident.greet", args)     // Lodash invoke
   svelte_d_wrap_ident_add(Handle)
     → exportDelegate("ident.add", &wrapper)
   registerDExports_ident() from construct / App.ready
```

Printer pin **`g126`**. Tests: `packages/svelte-kit-d/test/cross-call.test.ts` (Bridge / Peer / +page) and `packages/svelte-d-kit-admin/test/admin.test.ts` (AdminBridge / AdminPeer / `admin-mini`).

## How control actually moves

### Registry

`ensureSvelteD()` (`svelte-engine/src-ts/modules/libwasm.ts`) plants `window.__svelteD`:

| Field | Role |
|---|---|
| `ts[mod][name]` | TS exports. Lodash `invoke("mod.fn", args)` reads this. |
| `d[mod][name]` | Optional JS stubs that call `callNative('mod.fn', args)`. |
| `ret` / `setRet` | D→TS return slot. `callNative` returns `reg.ret`. |

`registerTs` / `registerD` create the inner objects on first use. The name `jsExports` is **not** registered as a function (the template’s `export const jsExports` is the module bag).

Module ident is `identFromRel(srcSvelteRel)` (`lib/Bridge.svelte` → `lib_Bridge_svelte`). `context="module"` uses `<ident>_mod`. A second instance script in the same file is `<ident>2`; a second module script is `<ident>_mod2`. Instance and module counters are separate so an instance after a module script does not become `ident2`.

Exports are registered even when the other language never calls them. Multiple `lang=ts` and `lang=d` tags in one file are all scanned.

### D calling TS (Lodash)

`analyzeCrossCall` (`print/cross_call.d`) parses `export function` / `export async function` / `export const fn =`. For each name the D body does not already define, the printer emits a **module-level** variadic thunk:

```d
string greet(ARGS...)(auto ref ARGS args)
{
  return callTs!(string)("lib_Bridge_svelte.greet", args);
}

JsPromise!(string) loadUser(ARGS...)(auto ref ARGS args)
{
  return callTsPromise!(string)("lib_Bridge_svelte.loadUser", args);
}
```

`callTs` (`libwasm/bridge.d`, public from `import libwasm;`) is:

```d
Lodash().defaultTo(eval("window.__svelteD.ts")).invoke(path, args).execute!T()
```

Zero arguments omit the `invoke` args so the JS default stays. Async / `Promise<T>` annotations become `callTsPromise` so `.await` is the same protocol as `{#await}`. Do not wrap that `.await` in `try`.

Same-file D uses the simple name. Another `.svelte` writes `import lib.Bridge : greet;` and calls the printed thunk. That is ordinary D module import, not a third FFI.

### TS calling D (`exportDelegate`)

`extern(C) export` is **lifted out of the struct** (`peelExternCExports`). The printer wraps it as `void svelte_d_wrap_<ident>_<name>(Handle)`, reads only the args that are present on the handle (missing → the D default), writes a non-void return through `setDRet`, and registers:

```d
void registerDExports_lib_Bridge_svelte() @trusted
{
  exportDelegate("lib_Bridge_svelte.add", &svelte_d_wrap_lib_Bridge_svelte_add);
}
```

`construct` calls that registrar. App `ready` also calls registrars for hung `src-d/lib/` components so a library that never constructed still answers `callNative`. TypeScript:

```ts
await window.callNative('lib_Bridge_svelte.add', [2, 3]) // 5
await window.callNative('lib_Bridge_svelte.add', [2])    // 2, b defaults
```

Wrappers currently peel `string` vs `int`. Other D types are a later arm, not a new FFI.

### `lang=ts` imports (G126)

`rewriteTsImports` rewrites the spliced body:

| Author specifier | Dest |
|---|---|
| `./foo` / `../foo` | dest helper path after ingest |
| `$lib/foo` | `src-ts/modules/helpers/lib/foo` |
| another `.svelte` | `./<ident>.ts` in `generated/` |
| npm (`admin-mini`, `lodash/fp`, `@scope/pkg`) | left as-is; collected as a spec |

npm specs fall through from the **project**, not by dumping `package.json` and not by a `file:` relativePath (that produced `./packages/…` and bun EPERM on a second `node_modules`):

1. dest `package.json` gets the project’s **declared range** (`dependencies` / `devDependencies` / …), else the version of the project’s installed copy.
2. dest `node_modules/<pkg>` gets a **copy** of the project’s install when that directory exists (`linkProjectPackage`).
3. `compile` runs `bun install` in the dest when a declared package is still missing (`installWsDeps`).
4. `ensureWsDeps` (kit-d pipeline) does the same if Vite or a declared dest dep is absent.

End of walk also `collectNpmFromSvelte`s every dest `.svelte` so a hash-skip still sees imports. Force `drop-ws` deletes `.svelte-d/src-hash.txt` so a pin bump (g126) is not skipped.

That is the same Vite cell as the rest of `src-ts`. It is not a Node HTTP stack.

## Loci

`riscv-compilers/libwasm/source/libwasm/bridge.d` — `callTs` / `callTsPromise` / `setDRet`  
`riscv-compilers/libwasm/source/libwasm/package.d:18` — `public import libwasm.bridge`  
`riscv-compilers/libwasm/source/libwasm/types.d:282-296` — `exportDelegate` / `unexportDelegate`  
`svelte-engine/src-ts/modules/libwasm.ts:39-76` — `ensureSvelteD` / `registerTs` / `registerD`; `callNative` returns `reg.ret`  
`packages/svelte-d/templates/engine/src-ts/modules/libwasm.ts` — packaged copy  
`packages/svelte-d/source/svelte_d/print/cross_call.d` — parse, thunks, peel, wrappers, import rewrite  
`packages/svelte-d/source/svelte_d/print/ts_attach.d` — instance vs `_mod` idents; wrap exports; `collectNpmFromSvelte`  
`packages/svelte-d/source/svelte_d/print/d_attach.d` / `dom_print.d` — peel, emit, `construct` + App `ready` register  
`packages/svelte-d/source/svelte_d/compile.d` — pin `g126`; `syncWsDependencies` + `installWsDeps`  
`packages/svelte-d/source/svelte_d/workspace/ws_deps.d` — range + copy + install  
`packages/svelte-d/source/svelte_d/workspace/drop.d` — force drop clears `src-hash.txt`  
`packages/svelte-kit-d/src/pipeline.ts` — `ensureWsDeps`  
`packages/svelte-kit-d/test/cross-call.test.ts` + `fixtures/cross-call/`  
`packages/svelte-kit-d/test/extensions.test.ts` + `fixtures/ext-app/` (`fake-grid`)  
`packages/svelte-d-kit-admin/src/lib/{AdminBridge,AdminPeer,admin-fmt.ts}` + `node_modules/admin-mini`  
[extensions.md](extensions.md) · [libwasm-js.md](libwasm-js.md) · [fallthrough.md](fallthrough.md)

## Invariants

- Two cells stay two cells. Crossing is Lodash `invoke` and `exportDelegate`, not a new WASM import list. (construction)
- Simple names stay in the declaring file. Registry keys are `ident.fn` / `ident_mod.fn`. (construction)
- Variadic `ARGS...` thunks forward only written args. Do not emit arity-strict overloads. (construction)
- `extern(C) export` is lifted out of the `nothrow` struct. (construction)
- dest deps copy the project’s install and write the declared range. Do not `file:` a relative path between two `node_modules`. (construction)
- `$lib` and relative TS imports rewrite onto dest helpers. npm specifiers stay bare. (construction)
- Do not wrap `callTsPromise` `.await` in `try`. (construction of the await protocol)
- Force drop clears `src-hash.txt` so a printer-pin bump reprints. (construction)

## Extension points

A new TS export shape (class method, `export { x as y }`) is a parser arm in `cross_call.d`. A new D wrapper type (bool, double, Handle) is a peel arm next to `looksStringParam`. A new JS library still follows the PgLite `Eval("window.X")` wrapper when it is not a `lang=ts` export.

## Did not close

Whether D wrappers should peel more than `string` / `int`. Whether `registerD` on `__svelteD.d` should be filled from the same `exportDelegate` pass (today TS uses `callNative` directly). Whether a hung lib that never reaches `construct` *or* App `ready` still needs an explicit registrar call.
