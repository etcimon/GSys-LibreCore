# Store instances — UUID identity, purpose, USB import/export

**Status:** living (S1). Implementation on **`E:\cva6/g6lc_bios`**.
Engine, SQL dialect, Lodash intern, and BoardSpec gates stay in
[`g6b-pglite.md`](g6b-pglite.md). This file is the **identity and
lifetime** contract those PRs must implement.

Green remains `python tools/g6b.py check`. QEMU argv never `-netdev`.
Store default **on** (`kernel.store.enable`). Crate `g6b-pglite` is S1.

---

## 0. Thesis

A store **instance** is identified by a **UUID**. A **purpose** is what
the BIOS UI (and later an iframe web app) asks for. Memory instances are
**deletable**. USB is **import/export of a dump**, not a second database
engine and not firmware flash.

```
purpose  "registry" | "setup" | "files" | "ssh" | …
    │  get-or-create current, or create another
    ▼
instance  uuid  (RFC 4122 lowercase)
    │  tables live in RAM (PersistMode::Memory)
    ├─ drop(uuid)          → gone (deletable memory)
    ├─ export(uuid, usb)   → {volume}/stores/{purpose}/{uuid}.g6bstore
    └─ import(usb path)    → memory instance, same uuid if free
```

Named `StoreId` as the catalog key is **retired**. Short names remain
**purposes** (allow-list), not instance ids. HTTP `/bios/store/{id}/query`
in later PRs is `{uuid}`, not `"registry"`.

---

## 1. Why UUID, not a purpose string

| Need | Purpose-as-key (old sketch) | UUID instance |
|---|---|---|
| BIOS setup UI | one `"registry"` | `open_purpose("registry")` → current uuid |
| Two FileMgr sessions | collide | two uuids, same purpose `files` |
| Delete one without the other | drop the only named db | `drop(uuid)` |
| USB round-trip | filename = name, clashes across keys | file is `{uuid}.g6bstore`; import restores that uuid if free |
| Later iframe tab | inherit `"registry"` or nothing | session binds `{uuid, purpose}`; navigate does not steal another tab’s rows |
| Operator listing | names | `{uuid, purpose, persist, rows}` |

TempleOS/ZealOS registry is a *service*. LibreCore still gates it
(`kernel.store.enable`), but the service is a **catalog of instances**,
not one global named database.

---

## 2. Types

```rust
/// RFC 4122, display lowercase 8-4-4-4-12. Nil UUID refused as an instance id.
pub struct StoreUuid([u8; 16]);

/// Allow-listed short name. BIOS UI and later apps ask for this, not a uuid.
pub struct Purpose(String); // ^[a-z][a-z0-9_]{0,31}$

pub struct StoreRegistry {
    spec: StoreCfg,
    instances: BTreeMap<StoreUuid, Store>,
    current: BTreeMap<Purpose, StoreUuid>, // at most one current per purpose
}

pub struct Store {
    uuid: StoreUuid,
    purpose: Purpose,
    label: Option<String>,     // operator-facing; not a key
    persist: PersistMode,      // live medium of *this* copy
    tables: BTreeMap<String, Table>,
    tx: Option<Tx>,
    handles: u32,              // close decrements; drop removes the instance
}

pub enum PersistMode {
    Memory, // default; survives close; dies on drop or reboot
    ElfSeed, // hydrated from `__g6b_store_dump`; live copy is then Memory
    UsbLive, // live FileMgr dump; volume/rel on Store
}
```

`UsbLive` is the live FileMgr-backed copy: mutating `query`/`exec`/`commit`/`load`
auto-flush a compressed `.g6bstore` when not in a transaction. Snapshot
export/import remains. A setup dialog polls `stat` until `live && ready`.

Dump JSON (versioned, first-party — not PGlite tar):

```json
{
  "g6b_store": 1,
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "purpose": "registry",
  "label": null,
  "tables": { "kv": { "cols": [], "rows": [] } }
}
```

`python tools/g6b.py store-embed --fixture FILE --out FILE` emits this shape.
`g6b-elf` packs it as `__g6b_store_dump` when `persist.elf` and the file is
present (`G6B_STORE_DUMP` or `out/g6b_store_dump.json`). Missing dump is
`PersistUnarmed` at `elf://` open, not `BoardSpec::check()`. `check()` never
runs `store-embed`.

---

## 3. Purpose-based BIOS UI

The shell never needs to mint a uuid in D/JS unless it is listing or
exporting.

| Purpose | Who | Typical lifetime |
|---|---|---|
| `registry` | kernel / HolyC / default `PgLite()` | process; export to USB to keep |
| `setup` | BIOS setup UI (tabs, last menu) | process; deletable |
| `settings` | operator settings rows (sibling of `/bios/settings` JSON, not a replacement in S0) | process; USB export is the portable copy |
| `files` | later `app:files` iframe | per session or imported uuid |
| `ssh` | later `app:ssh` iframe | same |

BoardSpec `kernel.store.purposes` is the allow-list (was `names` in the
first sketch). `apply_store`: if `enable` and `purposes` empty, fill
`["registry"]`. Unknown purpose → `CapDenied` / 404, not a new instance.

**Current pointer.** `open_purpose(p)` returns `current[p]`, or creates
one Memory instance and sets current. Creating a *second* instance of
the same purpose (`create(p)`) is allowed up to `max_per_purpose`;
`current` does not move unless the operator/UI switches it
(`StoreSelect(purpose, uuid)`).

BIOS UI usage:

- Setup chrome talks to `open_purpose("registry")` (or `"setup"` once that
  purpose is on the overlay).
- Listing / export chrome shows uuid + purpose + row counts.
- Delete is an explicit `drop(uuid)` (HolyC `StoreDrop`, `DELETE /bios/store/{uuid}`),
  never an implicit `close()`.

---

## 4. Deletable memory

Default persist is **Memory**. Always available when `kernel.store.enable`.
Volatile across reboot. **Deletable without reboot.**

| Verb | Effect on the instance | USB file |
|---|---|---|
| `close(uuid)` | unbind handle; instance **stays** in `list()` | untouched |
| `drop(uuid)` | remove from registry, free tables | **untouched** (operator deletes via FileMgr if they want) |
| reboot / process end | all Memory gone | dumps remain |
| `export` | snapshot; instance stays | created/overwritten at the export path |
| `import` | new (or restored) Memory instance | read-only for this verb |

PGlite JS `.close()` destroys an in-process db. BIOS `close` is **unbind**,
because purpose-based UI must reopen the same uuid. Destruction is
`drop` / `StoreDrop` / HTTP `DELETE`.

`drop` of the current instance for a purpose clears `current[purpose]`.
Next `open_purpose` creates a fresh uuid.

Budgets (fail closed; same caps as [`g6b-pglite.md`](g6b-pglite.md) plus):

| Knob | Default | Cap |
|---|---|---|
| `max_instances` (JSON `max_stores` alias ok in PR2) | 4 | 16 |
| `max_per_purpose` | 2 | 8 |
| `max_open` (handles) | 4 | 8 |

Exceeding → `StoreError::Budget`, never a silent LRU drop of another
instance.

---

## 5. USB key import / export

USB here is the **key FileMgr** (`kernel.usb.key`, `/bios/files/{fat32,ntfs,ext4}`),
the same host as settings import/export ([`USB.md`](USB.md)). It is **not**:

- FAT32 **flash** (`/bios/usb/ls` firmware: `openwrt.bin` / `g6lc_bios.elf` / `linux.img`)
- `file://`, IndexedDB, OPFS, QEMU `-netdev`, Linux VFS

`persist.usb` (BoardSpec) **arms** export/import. Unarmed →
`PersistUnarmed`, no silent Memory-only “success” that looks like a save.

**Export** `StoreExport(uuid, volume [, rel])`:

- Volume must be a live key kind (`fat32` / `ntfs` / `ext4`), not `flash`.
- Default rel: `stores/{purpose}/{uuid}.g6bstore`
- Body = dump JSON, size ≤ `max_result_bytes`
- Overwrite of the same uuid path is allowed; overwrite of a **different**
  uuid’s file is refused
- Memory instance is unchanged

**Import** `StoreImport(volume, rel)`:

- Parse dump; purpose must be allow-listed
- If dump `uuid` is free: restore **that** uuid (round-trip preserves identity)
- If that uuid is already live: **refuse** (`Exec("uuid live")`) unless
  `replace=true` (HolyC/HTTP flag, default false)
- Resulting instance is Memory (the USB file is not a live mount)
- Sets `current[purpose]` only if that purpose had no current

Canned `g6b-fs` listings grow `stores/` on key volumes when `persist.usb`
is on (PR3+). Flash listing never grows store files.

Settings `backup/settings.bak` stays settings. Store dumps are a sibling
tree, not a key inside `settings.json`.

---

## 6. Addressing (`dataDir` / HTTP / HolyC)

PGlite-shaped `dataDir` still exists for `PgLite(dataDir)`. Parse:

| Input | Meaning |
|---|---|
| omitted / `""` / `memory://` | `open_purpose("registry")` Memory |
| `registry` / `memory://registry` | `open_purpose("registry")` — **name in the path** |
| `{purpose}` matching the allow-list | `open_purpose` |
| `{uuid}` / `memory://{uuid}` | `open_uuid` |
| `elf://` / `elf://{purpose}` | hydrate `__g6b_store_dump` for that purpose → Memory instance (`persist.elf`) |
| `usb://VOL` / `usb://VOL/{purpose}` | live-attach `UsbLive` on that key volume (purpose name in the path) |
| `usb://VOL/{uuid}` | live-attach that uuid on the volume |
| `usb://VOL/rel.g6bstore` | import that snapshot |
| `idb://` `file://` `http(s):` | refuse |

HTTP (later PR4; ids are uuid except purpose helpers):

| Method | Path | Body | Result |
|---|---|---|---|
| GET | `/bios/store` | — | `{enable, purposes, budgets, persist, instances:[{uuid,purpose,persist,rows}]}` |
| GET | `/bios/store/purpose/{purpose}` | — | current `{uuid,…}` or 404 |
| POST | `/bios/store` | `{purpose}` | create Memory `{ok,uuid,purpose}` |
| DELETE | `/bios/store/{uuid}` | — | drop (deletable memory) |
| POST | `/bios/store/{uuid}/export` | `{volume, rel?}` | write dump on USB key |
| POST | `/bios/store/import` | `{volume, rel, replace?}` | Memory instance `{ok,uuid}` |
| POST | `/bios/store/{uuid}/open` | `{dataDir?}` | bind handle |
| POST | `/bios/store/{uuid}/query` | `{sql, params:[]}` | rows |
| POST | `/bios/store/{uuid}/exec` | `{sql}` | results |
| POST | `/bios/store/{uuid}/begin\|commit\|rollback\|close` | `{}` | `{ok}` |
| GET | `/bios/store/{uuid}/stat` | — | poll `{ready,live,volume,path,bytes}` |
| POST | `/bios/store/open` | `{dataDir}` | `usb://VOL` live-attach |
| GET | `/bios/store/{uuid}/dump` | — | dump JSON |
| PUT | `/bios/store/{uuid}/load` | dump JSON | replace tables of **that** uuid (purpose must match) |

HolyC (later PR5):

| Builtin | Args |
|---|---|
| `StoreOpen` | purpose → `STORE-OPEN {uuid} {purpose}` |
| `StoreSelect` | purpose, uuid |
| `StoreClose` | uuid (unbind) |
| `StoreDrop` | uuid (delete memory) |
| `StoreQuery` / `StoreExec` / tx | uuid **or** purpose (purpose → current) |
| `StoreDump` / `StoreLoad` | uuid |
| `StoreExport` | uuid, volume [, rel] |
| `StoreImport` | volume, rel |
| `StoreList` | uuid + purpose + persist + rows |
| `StoreStat` | uuid-or-purpose → poll `{ready,live}` |

Disabled (`!store.enable`) → `STORE-REFUSED`. HTTP off does **not** refuse
HolyC. UART gets no new single-letter command in v1.

D `PGLite`: `PgLite()` / `PgLite("registry")` still `attempt(dataDir)`.
Add `drop()`, `export(volume)`, `import(volume, rel)` on the wrap in PR7
only if Lodash `MAX_PARAMS` holds (volume + rel as two strings is fine).
UUID is in the JSON result of open/list, not a new import family.

---

## 7. Later iframe web apps (B92, not this series)

[`plan-iframe.md`](plan-iframe.md) sessions do **not** inherit the shell
catalog. Store is **native** (`bios.store`).

| Origin | Store |
|---|---|
| Shell (BIOS UI) | yes, when `kernel.store.enable`; all allow-listed purposes |
| Registered local app (`app:files`, `app:ssh`, …) | **only declared purposes** (hook `bios.store: ["files"]`) |
| Local `/ui/*.html`, `srcdoc`, `about:blank` | no |
| Local `/ui/*.wasm` nested cell | no unless registered or later elevation |
| Remote `http(s):` | **never** |

Session field (B92, architecture only now):

```
IframeSession.store: Option<{ uuid: StoreUuid, purpose: Purpose, drop_on_close: bool }>
```

- Shell may `create(purpose)` when opening a registered app and bind that
  uuid to the session.
- `drop_on_close=true` is the ephemeral scratch default for a new iframe
  app that did not import a uuid (deletable memory).
- Imported uuid (USB) binds with `drop_on_close=false`.
- Navigate re-populates JS; the **uuid binding** is the session’s, not the
  new document’s intern table. Drop happens on tab close only if flagged.
- Nested `createBrowserContext` still does not intern `pglite` unless the
  hook declared the cap.
- Elevation catalog name remains `bios.store`; later prompt may name a
  **purpose**, not the whole catalog. Remote cannot ask.

This file does **not** implement B92. It names the bind so S1 types are
not purpose-as-key, which would block iframe isolation later.

---

## 8. ELF seed vs USB vs memory

| Medium | Role | Delete |
|---|---|---|
| Memory | working copy; default | `drop` or reboot |
| ELF `__g6b_store_dump` | read-only factory image per purpose (`persist.elf`) | not deletable (rodata); hydrate makes a Memory copy |
| USB key dump | portable snapshot (`persist.usb`) | FileMgr delete of the `.g6bstore`; not `StoreDrop` |
| Electric `pglite.embed` | **not** a registry dump (separate wasm+initdb+data) | n/a |

Fail closed: unarmed `elf://` or USB export/import → `PersistUnarmed`.
No fallback that looks like a successful save. No `idb://`.

---

## 9. BoardSpec (PR2)

`StoreCfg` fields that this contract adds/renames:

- `purposes: Vec<String>` (JSON `purposes`; `names` accepted as alias then dropped)
- `max_instances` (JSON `max_stores` kept as the knob name if PR2 prefers one field)
- `max_per_purpose`
- `persist.memory` default true; `persist.elf` / `persist.usb` default false

`check()` flag-to-flag: `persist.usb` needs `usb.key`; purposes match the
ident alphabet; `1..=max_instances` purposes when enable (fill
`["registry"]`). Still **no** disk probe.

---

## 10. Verification (later PRs, not S0)

| Test | Asserts |
|---|---|
| `create("registry")` twice → two uuids, `max_per_purpose` | |
| `drop(uuid)` then `list()` omits it; `open_uuid` → `UnknownStore` | |
| `close` then `open_uuid` still works | |
| export without `usb.key` / `persist.usb` → `PersistUnarmed` | |
| export to `flash` volume refused | |
| import restores dump uuid when free; refuse when live | |
| import purpose not allow-listed → `CapDenied` | |
| iframe-shaped cap: purpose `files` cannot `open_uuid` of `registry` | architecture test in S2 |

S0 (this PR): submodule + pin + this document. No crate, no routes.

---

## References

- [`g6b-pglite.md`](g6b-pglite.md) — engine, SQL, Lodash, FileServe pin
- [`USB.md`](USB.md) — flash vs key FileMgr
- [`plan-iframe.md`](plan-iframe.md) — session isolation; `bios.store`
- [`KERNEL-API.md`](KERNEL-API.md) — JS ≡ HolyC table
- [`FILE-SERVER.md`](FILE-SERVER.md) — FileServe; store POST cap later
