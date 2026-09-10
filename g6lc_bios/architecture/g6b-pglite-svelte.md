# Svelte store tutorial (svelte-d)

BIOS screens are `.svelte`. svelte-d is a **bounded** parser (`parseSvelte`):
string-literal calls in `<script>`, not SvelteKit, not `db.exec(variable)`,
not a poll loop. JSON-returning calls may be **assigned** (`let rows =
await pgliteQuery(…)`) and interpolated (`{rows}`, `{st.ready}`). Those
calls lower to LDC `_start` (`print-d` → `PgLite`) and to lang=ts `mount()`
(`print-ts` → interned `pglite()`).

Green remains `python tools/g6b.py check`. The compiled construct is
`browser-ui/src/Store.svelte` (flattened into App `_start`). It opens the
**memory** `registry` (store enable defaults on). Do **not** put
`pgliteOpen("usb://…")` in that file unless `persist.usb` is armed — that
is `PersistUnarmed` on the default BoardSpec. USB live belongs in an
overlay or the lang=ts poll loop below.

`printG6bJs` (g6b-js AOT) keeps Store **fetch + text** only. It does not
emit `pglite(...)` — `g6b-js` must not depend on `g6b-pglite`. SQL runs
in LDC `_start` and lang=ts `mount()`.

Identity, USB live persist, and SQL grammar:
[`g6b-pglite.md`](g6b-pglite.md), [`g6b-store-instances.md`](g6b-store-instances.md),
[`USB.md`](USB.md).

---

## 1. What svelte-d parses

| Script call | D (`ready`) | lang=ts `mount()` |
|---|---|---|
| `pgliteOpen("usb://fat32/registry")` | `PgLite("usb://fat32/registry")` | `pglite("usb://fat32/registry")` |
| `pgliteOpen("memory://registry")` | `PgLite("memory://registry")` | `pglite("memory://registry")` |
| `pgliteOpen("memory://{uuid}")` | `PgLite("memory://{uuid}")` | `pglite("memory://{uuid}")` |
| `pgliteOpen("registry")` | `PgLite("registry")` | `pglite("registry")` |
| `await pgliteWaitReady()` | `db.waitReady()` (awaits) | `await db.stat()` |
| `await pgliteStat()` | `db.statAsync()` (awaits) | `await db.stat()` |
| `pgliteStat()` | `db.stat()` | `await db.stat()` |
| `pgliteExec("SQL")` | `db.exec` | `await db.exec` |
| `pgliteQuery("SQL", "[…]")` | `db.query` | `await db.query` |
| `await pgliteQuery("SQL", "[…]")` | `db.queryAsync` | `await db.query` |
| `let rows = await pgliteQuery("SQL", "[…]")` | `auto rows = db.queryAsync` | `const rows = await db.query` |
| `{rows}` | `setProperty(…, JSON.stringify(rows))` | `innerText = JSON.stringify(rows)` |
| `{st.ready}` | `st["ready"]` then stringify | `JSON.stringify(st && st.ready)` |
| `pgliteQueryAsync("SQL", "[…]")` | `db.queryAsync` | `await db.query` |
| `pgliteBegin()` / `Commit` / `Rollback` | `db.begin` / … | `await db.begin` / … |
| `pgliteListen("ticks")` | `db.listen` | `await db.listen` |
| `pgliteUnlisten()` | `db.unlisten("*")` | `await db.unlisten` |
| `pgliteDump()` / `pgliteLoad("{…}")` | `db.dump` / `db.load` | `await db.dump` / `load` |
| `pgliteExport("fat32")` | `db.exportUsb("fat32")` | `await db.exportUsb` |
| `pgliteClose()` | `db.close` | `await db.close` |
| `fetchBios("/bios/store")` | `g6b_fetch` | `fetch` |
| `holycEval("StoreStat(\"registry\")")` | `g6b_holyc` | `kernel.holyc` |

Arguments must be **quoted string literals**. Params are one JSON array
string (`"[1,\"alice\"]"`), never variadic `$1,$2` (Lodash `MAX_PARAMS`).

`{#await}` and `{#each}` in markup are still **stubs**. Assign in the
script and paint JSON text (or one field). The element must have an `id`.
Do not assign `pgliteOpen` (it constructs `PgLite`). Bind names `db` /
`root` are reserved.

---

Compiled `Store.svelte` (memory registry, always-on):

```svelte
<script>
fetchBios("/bios/store");
pgliteOpen("memory://registry");
await pgliteWaitReady();
pgliteExec("CREATE TABLE IF NOT EXISTS bios_ui (k TEXT PRIMARY KEY, v TEXT)");
let rows = await pgliteQuery("SELECT k, v FROM bios_ui", "[]");
</script>
<section id="store">
  <h2 id="store-title">Store</h2>
  <p id="store-status">{rows}</p>
</section>
```

`rows` is the query JSON (`{rows, fields, affectedRows}`). svelte-d
stringifies it onto `#store-status` after `_start` awaits. AOT JS does
not run SQL.

Same shape for `let st = await pgliteStat()` / `await pgliteWaitReady()`
/ `pgliteDump()` / `pgliteExec` when you need the JSON in the page:

```svelte
<script>
let st = await pgliteStat();
</script>
<p id="usb-ready">{st.ready}</p>
```

---

## 2. USB live instance (dialog)

Canned key volume is present when `persist.usb` is armed. One await is
enough on `_start`:

```svelte
<script>
pgliteOpen("usb://fat32/registry");
let st = await pgliteWaitReady();
pgliteExec("CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)");
pgliteQuery("INSERT INTO kv VALUES ($1, $2)", "[\"boot\",\"opensbi\"]");
let rows = await pgliteQuery("SELECT v FROM kv WHERE k = $1", "[\"boot\"]");
pgliteExport("fat32");
</script>
<main id="bios-ui">
  <p id="status">{rows}</p>
  <p id="usb-ready">{st.ready}</p>
</main>
```

`pgliteWaitReady` / `await pgliteStat` return
`{ok, uuid, purpose, persist, live, volume?, path?, bytes, format?, ready}`.
A dialog that **requires USB** proceeds when `live && ready`.

The **name lives in the path** after the scheme, not a second argument:

| Path | Meaning |
|---|---|
| `memory://registry` | Memory, purpose `registry` |
| `memory://{uuid}` | reopen that Memory uuid |
| `usb://fat32/registry` | USB live, purpose `registry` on volume `fat32` |
| `usb://fat32/{uuid}` | USB live, attach that uuid on `fat32` |
| `elf://registry` | ELF seed for purpose `registry` |
| `registry` | short for `memory://registry` |

`usb://ntfs/registry` and `usb://ext4/registry` are the other key volumes.
Never `usb://flash`. Snapshot import is a file path:

```svelte
<script>
pgliteOpen("usb://fat32/stores/registry/00000000-0000-4000-8000-000000000001.g6bstore");
await pgliteWaitReady();
</script>
```

### Poll loop (lang=ts only)

svelte-d `_start` is one-shot. If the operator must insert a stick, loop
on the interned factory (shell BINDINGS, not the real DOM `window`):

```js
const db = pglite("usb://fat32/registry");
let s = await db.stat();
while (!(s.ok && s.live && s.ready)) {
  s = await db.stat();
}
```

HolyC equivalent: `StoreOpen("usb://fat32/registry"); StoreStat("registry");`

---

## 3. Memory registry (default)

Omit `pgliteOpen` or pass `"memory://registry"` (short `"registry"` is the same):

```svelte
<script>
pgliteExec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)");
pgliteBegin();
pgliteQuery("INSERT INTO t VALUES ($1, $2)", "[1,\"alice\"]");
pgliteCommit();
let rows = await pgliteQuery("SELECT name FROM t WHERE id = $1", "[1]");
</script>
<p id="name">{rows}</p>
```

`pgliteRollback()` undoes the open transaction. `pgliteClose()` unbinds;
`StoreDrop` / `DELETE /bios/store/{uuid}` deletes the memory instance.

---

## 4. ELF seed

```svelte
<script>
pgliteOpen("elf://registry");
await pgliteWaitReady();
let rows = await pgliteQuery("SELECT * FROM kv", "[]");
</script>
<p id="kv">{rows}</p>
```

Needs `persist.elf` and a linked `__g6b_store_dump`. Missing dump is
`PersistUnarmed`, not a BoardSpec `check()` error.

---

## 5. Listen / HTTP / HolyC

```svelte
<script>
pgliteListen("ticks");
fetchBios("/bios/store");
holycEval("StoreOpen(\"usb://fat32/registry\")");
holycEval("StoreStat(\"registry\")");
holycEval("StoreExport(\"registry\", \"fat32\")");
</script>
```

`GET /bios/store/{uuid}/stat` is the same JSON as `pgliteStat`.
`POST /bios/store/open` `{dataDir:"usb://fat32/registry"}` is `pgliteOpen`.

---

## 6. Not this parser

| Want | Do this instead |
|---|---|
| `db.exec(sqlVariable)` | literal `pgliteExec("…")` |
| `{#each rows}` | `{rows}` JSON text (`{#each}` is a stub) |
| Poll until USB appears | lang=ts `while` on `await db.stat()` |
| `{#await}` block | `let rows = await pgliteQuery` then `{rows}` |
| Electric `PGlite.create` | `createPgliteWasm` on native `kernel.ts` only |
| `idb://` / `file://` | refused |
| Cartesian `JOIN` | `INNER JOIN … ON a.col = b.col` |
| `let db = pgliteOpen(…)` | `pgliteOpen(…)` (constructs `PgLite`, not JSON) |

Construct catalog marks **Store** live (`SVELTE-LIVE Store`).
