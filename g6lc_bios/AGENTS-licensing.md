# AGENTS-licensing — g6lc_bios

Everything first-party in this tree is **MIT**, © 2026 Etienne Cimon.

Reference forks live under `kernel-spec/` (`NOTICE`). Do not relicense, do not
edit their LICENSE/NOTICE files, do not add them to the Cargo workspace, do not
link them. First-party rewrite is MIT in `crates/**`. `.licensing-tiers` marks
`g6lc_bios/kernel-spec/{ZealOS,TempleOS,goja,lirx-dom,webidl,svelte-d,botan,libwasm}/**` as **U**.

No crate links QEMU, OpenSBI, EDK2, U-Boot, or `github.com/dop251/goja`.
Goja / lirx-dom / WebIDL are *semantic* specs (ES5 VM, DOM locality, interfaces).
The Go runtime is never built. WebIDL stays MPL-2.0 verbatim. Botan stays
BSD-2-Clause verbatim (`LICENSE.md`); the rewrite in `g6b-tls` is MIT.
libwasm stays MIT verbatim; the rewrite in `g6b-wasm` / `g6b-http` is first-party MIT.

Electric SQL PGlite is a **build-input submodule** at `pglite/` (not
`kernel-spec/`), fork `https://github.com/etcimon/pglite` tracking
`origin/main`. The TypeScript package is **Apache-2.0**; the Postgres wasm
inside the npm dist is **PostgreSQL License** (NOTICE, verbatim). Do not
relicense, do not edit their LICENSE, do not add `pglite/` to the Cargo
workspace, do not compile it. Dist bytes are a **gitignored npm pin**
(`pins.toml` `[pglite.dist]`, `.tools/pglite-dist/`). First-party store
rewrite is MIT in `crates/g6b-pglite`. `.licensing-tiers`:
`U g6lc_bios/pglite/**`.
