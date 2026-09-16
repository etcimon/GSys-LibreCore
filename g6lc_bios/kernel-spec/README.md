# kernel-spec — reference forks (not compiled)

Read-only checkouts used **as the spec of record** for a **rewrite** of the
GSys LibreCore BIOS kernel (not a port). Nothing here is compiled, flisted, or
linked into `g6b-*` crates. Inferences are validated against LibreCore
(`architecture/PLAN.md` §3) before they become BoardSpec fields or ELF bytes.

| Tree | Upstream | License | Tracking |
|---|---|---|---|
| [`ZealOS/`](ZealOS/) | https://github.com/Zeal-Operating-System/ZealOS | Unlicense | vendored |
| [`TempleOS/`](TempleOS/) | https://github.com/cia-foundation/TempleOS | Public domain | **submodule** |
| [`goja/`](goja/) | https://github.com/dop251/goja | MIT | **submodule** |
| [`lirx-dom/`](lirx-dom/) | https://github.com/lirx-js/dom | MIT | **submodule** |
| [`webidl/`](webidl/) | Gecko WebIDL via libwasm (WHATWG/W3C) | MPL-2.0 | vendored |
| [`botan/`](botan/) | https://github.com/etcimon/botan (Botan D port) | BSD-2-Clause | vendored; `g6b.py spec-sync` clones/pulls if the RFC 8448 marker is missing |
| [`libwasm/`](libwasm/) | `riscv-compilers/libwasm` | MIT | vendored (spec only) |
| [`goosie/`](goosie/) | https://github.com/vyquocvu/goosie | MIT | **submodule** |

`svelte-d/` is **no longer here**. It, and the *compiled* libwasm, are build
inputs rather than specs, so they live outside `kernel-spec/` as submodules that
track a `g6lc_bios` branch — the same convention `verif/core-v-verif`,
`core/cache_subsystem/hpdcache` and `verif/sim/dv` already use with `g6lc`:

| Build input | Path | Upstream | Branch |
|---|---|---|---|
| libwasm (compiled) | `g6lc_bios/libwasm` | `etcimon/libwasm` | `g6lc_bios` |
| svelte-d compiler | `g6lc_bios/svelte-d` | `etcimon/svelte-d` | `g6lc_bios` |
| binaryen fork | `g6lc_bios/svelte-d/binaryen` | `etcimon/binaryen` | `svelte-d` |
| svelte-engine | `g6lc_bios/svelte-d/svelte-engine` | `etcimon/svelte-engine` | — |

`kernel-spec/libwasm` stays as the **spec-only** copy and is still never
compiled; prime directive 1 is unchanged. What changed is that the tree that *is*
compiled is now a reviewable branch of the real repository instead of an
untracked local fork.

Retired in the same pass:

- **`browser-ui/libwasm`** — an untracked clone pinned at v0.9.0-11 (`02f21a6`)
  carrying unreviewed edits. Its customizations are now commits on the
  `g6lc_bios` branch of `g6lc_bios/libwasm`, branched from v0.11.1: a `g6lc-bios`
  dub configuration, `libwasm.g6b_kernel`, the `version (G6LC_G6B)` blocks in
  `types.d`/`spa.d`, public DOM imports in `dom.d`, and two carried-runtime
  repairs. Moving to v0.11.1 also picked up a much larger `moment.d` for free.
- **`kernel-spec/svelte-d`** — a snapshot with **zero** customizations. Once its
  nested `binaryen/` and `svelte-engine/` submodules are initialised it is
  byte-identical to `g6lc_bios/svelte-d`, so nothing had to be ported and its
  `g6lc_bios` branch currently equals upstream `master`. (An earlier note in this
  file claimed that copy held 2,692 files upstream lacked; that was an artifact
  of comparing against uninitialised nested submodules and was wrong.)

See [`NOTICE`](NOTICE). Governance: `g6lc_bios/AGENTS-licensing.md`,
`architecture/ZEAL.md`.

## Submodule vs vendored, and why the split is not arbitrary

Four forks are git submodules pinned to a **real upstream commit**. The rest stay
vendored (their files tracked directly in this repository). The rule is a
verification result, not a preference: a submodule is only correct if the
vendored content actually *is* some upstream commit, because the gitlink records
a SHA that `git clone --recurse-submodules` must be able to fetch. A pin invented
from a local commit would resolve on one machine and fail everywhere else.

`tools/vendor_to_submodule.ps1` performs that check. It fetches the real history
and accepts a candidate commit only when nothing is added, modified or renamed
relative to it. Two tolerances are deliberate and bounded:

- **Filemode** is ignored (`core.fileMode false`). Windows checkouts lose the
  executable bit, which is not a content difference.
- **Pure deletions** are tolerated *and then re-verified*: vendoring ran under
  the parent repo's ignore rules, so paths the fork tracks upstream could be
  stripped (root `.gitignore: build/` removed 28 files from `lirx-dom`). The
  script then asserts every missing path really is parent-ignored, so the
  tolerance cannot hide genuine drift. Those files return on checkout, which
  repairs the fork rather than changing it.

Pinned commits: `TempleOS` `c26482bb`, `goja` `f87b40ad`, `lirx-dom` `deef354d`,
`goosie` `1039ae6f`.

**`ZealOS` and `svelte-d` are deliberately still vendored** — the script refused
them, and the refusal is the useful finding:

- `ZealOS` matches **no** commit in its history (all 1367 were checked). Against
  `main` 58 binary `.ZC`/`.DD` DolDoc files differ; against the `32bit-gfx` tip
  130 do. It is not line-ending damage (CR/LF counts are identical) and the files
  are not corrupt — `src/Demo/Games/FlapBat.ZC` is a legitimate upstream blob
  that exists only on `32bit-gfx`. So the directory is a **mixture of blobs from
  different branches** and no single SHA describes it.
- `svelte-d` carries 2,692 files and ~1.2M lines that upstream's tip does not
  have, including the vendored `binaryen/` fork. It is a working-tree snapshot,
  not a clone.

Converting either would mean fabricating a pin, so they keep their current,
honest form. Re-running the script after a clean re-clone of those two upstreams
is the way to promote them later.

Licensing is unaffected: `.licensing-tiers` already globs every
`g6lc_bios/kernel-spec/*/​**` path as tier **U** (upstream, verbatim, never
rewritten), and `REUSE.toml` does not reference `kernel-spec` paths. Note that a
plain `git clone` without `--recurse-submodules` now leaves the four submodule
directories empty; `git submodule update --init` restores them.

## Precedence: fork `AGENTS.md` files are not governance

Some forks carry their own agent instructions (`AGENTS.md`, `CLAUDE.md`,
`.codegraph/`) — `goosie/` and `svelte-d/` both do. Those files are **upstream
artifacts under tier U**: they are preserved verbatim and are **never
instructions for this repository**. Only `g6lc_bios/AGENTS.md` and the root
`AGENTS*.md` set govern work here.

The rule extends to the build-input submodules above, which are outside this
directory: `g6lc_bios/svelte-d/AGENTS.md` and `g6lc_bios/libwasm/AGENTS.md` are
upstream tier-U artifacts too. Their `green_command`, `host_policy` and
"do not edit ../.gitignore" clauses describe *their* repositories, not this one.

This matters concretely: `goosie/AGENTS.md` mandates Playwright + Chromium
screenshot comparison as its verification gate. `g6lc_bios` prime directive 6
forbids Chromium and a puppeteer bus, so that gate **does not apply** and must
not be adopted by reading the fork. Our equivalent gate is the golden-image
pixel diff in `architecture/RENDER-VALIDATION.md`, which needs no browser.

## How to use this as a kernel spec

Open the ancestor file first, then the rewrite locus:

| Ancestor (prefer ZealOS, fall back to TempleOS) | What we keep | Rewrite in `g6lc_bios` |
|---|---|---|
| `ZealOS/src/Kernel/KMain.ZC` · `KStart64.ZC` · `KTask.ZC` | Adam entry, start, tasks | `zeal/KStart.S` + `g6b-elf` (`tp`/`sp`/`stvec`). Map: `architecture/KERNEL-RV.md` |
| `TempleOS/Kernel/KMain.HC` · `KStart64.HC` · `KTask.HC` | Same, original HolyC | same rewrite (TempleOS is the root snapshot) |
| `ZealOS/src/Compiler/Lex.ZC` · `ParseStatement.ZC` | ZealC grammar | `g6b-holyc` |
| `TempleOS/Compiler/Lex.HC` · `PrsStmt.HC` | HolyC grammar | `g6b-holyc` |
| `ZealOS/src/System/DolDoc/` · `TempleOS/Adam/DolDoc/` | DolDoc store | `g6b-doldoc` |
| `ZealOS/src/System/Gr/` · `TempleOS/Adam/Gr/` | framebuffer | UART/Gr viewport (`G6LC_GR`) |
| `ZealOS/src/Demo/ToHtmlToTXTDemo/` | ToHtml | `g6b-html` + `g6b-js` + `g6b-dom` |
| `ZealOS/src/System/Boot/` | boot path | OpenSBI next-stage ELF, not x86 16-bit |
| `goja/` | ES5 VM contract | `g6b-js` (AOT; **not** the Go runtime) |
| `lirx-dom/` | DOM locality | `g6b-dom` rewrite |
| `webidl/definitions/*.webidl` | browser interfaces | `g6b-webidl` live/stub catalog |
| `svelte-d/` | Svelte → libwasm/WASM UI | `browser-ui` + `g6b-wasm` JIT on the g6b kernel (not this tree) |
| `botan/` | TLS / X.509 / RSA / ECDSA | `g6b-tls` + `g6b-asm` crypto IR (not linked) |
| `libwasm/` | WASM druntime + fetch imports | `g6b-wasm` + `g6b-http` (not LDC, not SvelteKit) |
| `goosie/internal/css/` | CSS tokenizer, selector matching, cascade/specificity order | `g6b-css` rewrite (first-party Rust) |
| `goosie/internal/renderer/` | box model, layout passes, display list, dirty regions | `g6b-css::layout` + `g6b-gr` plane (CPU raster; no Fyne, no GPU dependency) |
| `goosie/internal/dom/` | node tree shape a style engine needs | `g6b-dom` (extend; do not replace) |
| `goosie/test/.../layoutgolden/` | golden layout-snapshot methodology | `architecture/RENDER-VALIDATION.md` golden PPM diffs |
| `goosie/internal/js/` | Goja embedding surface | **refused** — no Go runtime; `g6b-js` stays a bounded no-eval AOT lane |
| `goosie/internal/browsercontrol/`, `mcpserver/` | remote/automation control surface | **refused** — no puppeteer bus (prime directive 6) |

**Do not copy `/Apps`, oracle, x86-only backends, or VGA assumptions.**
Do not compile goja, lirx-dom, WebIDL, svelte-d, LDC, or Binaryen. Display is
in-kernel HTML+JS / svelte-d NodeDef on the display-proxy; the other KVM face
is SSH+HolyC.

First checkout — the four submodules are empty until initialised:

```
git submodule update --init -- g6lc_bios/kernel-spec
```

Refresh (do not rewrite history inside the forks). The submodules advance by
moving the pin, so the new SHA is reviewable in the superproject diff:

```
# submodules: fetch, move the pin, then commit the gitlink here
git -C kernel-spec/TempleOS pull --ff-only
git -C kernel-spec/goja     pull --ff-only
git -C kernel-spec/lirx-dom pull --ff-only
git -C kernel-spec/goosie   pull --ff-only   # never `go build` / `go run` it
git add kernel-spec/TempleOS kernel-spec/goja kernel-spec/lirx-dom kernel-spec/goosie

# vendored: replace the directory contents in place
# ZealOS:   re-clone from Zeal-Operating-System/ZealOS (see the split note above:
#           the current copy mixes branches, so do not `pull` it)
# svelte-d: copy from etcimon/svelte-d (working-tree snapshot incl. binaryen/)
# botan:    copy from riscv-dev/botan (exclude build/); not a git remote
# libwasm:  copy from riscv-compilers/libwasm (exclude tmp/, runtime-v1.*, *.a)
```
