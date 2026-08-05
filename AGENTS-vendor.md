# AGENTS Vendor — build-platform controller & PHY fetching

> **Scope:** how external **uncore controller / PHY IP** (DDR4, Ethernet, PCIe, HDMI, SATA/SD, …)
> is declared, fetched, updated, and scanned through the `build-platform`. This is the behaviour
> spec for the `vendor` command and the `config.vendor` catalog. It is a **standing workflow rule**:
> any change to how controllers/PHY are vendored goes through here, not through ad-hoc `git` in the
> tree.

This file documents the **mechanism**. The **catalog contents** (which controllers, their PHY split,
and where they land in `corev_apu`) live in `AGENTS-core-platform-vendor-actives.md`, and the
**RTL integration outlines** live in `architecture/uncore/`.

---

## 1. Why this exists

CVA6 already imports third-party RTL two different ways:

- **git submodules** (`.gitmodules`) — pulp-platform / lowRISC peripherals, `core-v-verif`, `cvfpu`, …
- **hjson vendoring** (`vendor/*.vendor.hjson` + `.lock.hjson`) — a pinned source snapshot with an
  excludes list and a patch dir (e.g. `pulp-platform/common_cells`).

That is fine for what exists, but it gives no single answer to *"which external controller/PHY does
the SoC uncore draw on, at what pin, under what license, and is it wired in yet?"* — and no uniform
way to fetch/upgrade a controller or to know when its RTL must be re-scanned. The `build-platform`
already is the single control surface for tools, submodules, and tests, so controller/PHY IP is
migrated onto it too. This is the **typed migration of `vendor/*.vendor.hjson` into a first-class
build-platform feature**.

---

## 2. Where the catalog lives

- **Type**: `VendorConfig` / `VendorControllerSpec` in `build-platform/src/config/schema.ts`.
- **Data**: `DEFAULT_CONFIG.vendor.controllers` in `build-platform/src/config/defaults.ts`.
- **Override**: the repo-root `.config.ts` (`vendor: { controllers: [...] }`) — enable, re-pin, or add.
- **Validation**: `validateConfig` in `build-platform/src/config/load.ts` (unique ids + paths, url/path present).
- **Engine**: `build-platform/src/tooling/vendor.ts`.
- **CLI**: `build-platform/src/cli/commands/vendor.ts` (registered in `cli/registry.ts`).

Adding a controller = **one catalog entry**. No new command, no new wiring — the same
"add a default → it is optional for every existing config" philosophy the rest of the platform uses.

### 2.1 A catalog entry (the fields that matter)

| Field | Meaning |
|---|---|
| `id` | CLI handle + catalog key (unique). |
| `domain` | `memory` / `network` / `interconnect` / `storage` / `display` / `usb` / `phy` / `peripheral` / `util` — drives grouping + corev_apu placement. |
| `kind` | `controller` / `phy` / `controller+phy` / `support` — the on-die-vs-analog reality. |
| `mechanism` | `submodule` (default for controllers) or `vendor` (in-tree snapshot). |
| `url`, `ref` | Upstream git URL + pin. **Leave `ref` unset = default branch; pin to a SHA before integration.** |
| `path` | Repo-relative checkout path (matches `.gitmodules` for submodules). |
| `license` | Upstream SPDX id (compliance / `AGENTS-licensing.md`). |
| `status` | `planned` → `vendored` → `integrated`. |
| `enabled` | Whether a bare `vendor sync` (no ids) fetches it. **Everything ships disabled.** |
| `scanPaths`, `scanOn` | Which sub-trees to scan and when a re-scan is required. |
| `integrationSeam`, `phyNote`, `architectureDoc` | Pointers into `corev_apu` and `architecture/uncore/`. |

---

## 3. The `vendor` command

Run via `./build.sh vendor …` / `.\build.ps1 vendor …` / `bun run build-platform/src/cli/index.ts vendor …`.

| Subcommand | Behaviour |
|---|---|
| `vendor list` | Catalog grouped by domain (default). `--json` for the raw tree. |
| `vendor status` | Per-controller checkout + `.gitmodules` registration + scan-needed hints. `--json` supported. |
| `vendor sync [ids…]` | Fetch: named ids, or (no ids) every `enabled` entry, or `--all`. |
| `vendor add <ids…>` | Fetch the named ids (explicit alias of `sync` — errors if no id given). |
| `vendor update <id> [--ref R]` | Bump the checked-out ref (submodule) or re-snapshot (`vendor`). |
| `vendor scan <ids…> \| --all` | Enumerate the RTL a controller exposes. `--json` for the file list. |

**Nothing fetches implicitly.** `setup` does **not** touch the vendor catalog; only an explicit
`vendor` invocation performs git network operations. Use `--dry-run` (`-n`) to preview every git
command first. This keeps minimal checkouts minimal and makes network actions auditable.

---

## 4. Mechanisms

### 4.1 `submodule` (default for controllers/PHY)
- First run: `git submodule add --force <url> <path>` then, if `ref` is set, `git -C <path> checkout <ref>`.
- Later runs: `git submodule update --init [--depth 1] -- <path>` then `checkout <ref>`.
- Preferred because controllers are **version-bumped and re-scanned** over their life; a submodule
  keeps the pin visible in `.gitmodules` + the gitlink and is trivial to `vendor update`.

### 4.2 `vendor` (in-tree source snapshot)
- Clone → checkout `ref` → delete `excludeFromUpstream` paths → strip `.git` → copy into `path` →
  write `<path>/.vendor-lock.json`.
- Mirrors the legacy `vendor/*.vendor.hjson` flow. Use it only for IP that must be **patched in-tree**
  or that should not appear as a submodule. Combine with a patch step if you carry local changes.

---

## 5. When scanning is required (the "certain circumstances")

A vendored controller is a large third-party tree. Agents must **not** blind-walk it on every task;
they scan it **only** at these lifecycle events, controlled by each entry's `scanOn`
(default `["on-fetch","on-update","on-integrate"]`):

- **on-fetch** — right after the first `vendor sync`: learn the module list, top module, bus type,
  parameters, and clocking before touching anything.
- **on-update** — after `vendor update` bumps the ref: re-scan to catch renamed/added/removed files
  and interface changes before re-elaborating.
- **on-integrate** — when wiring the block into a `corev_apu` flist / instantiating it: confirm the
  exact file set and the top-level ports against the integration outline.
- **manual** — everything else: do not re-scan a stable, already-integrated block.

`vendor scan <id>` prints the RTL file set (bounded at 4000 files) grouped by extension; `--json`
gives the machine-readable list an agent can act on. If a controller is not checked out, `scan`
tells you to `vendor sync` it first.

### 5.1 Per-vendor code-agent files (self-aware guides)

Each vendored block should carry its own living agent guide — `agents/vendor/AGENTS-vendor-<id>.md` —
that plays the role of an `AGENTS.md` **for that checked-out codebase**: it is authored against a
specific pin, knows when it is **stale** (catalog `ref` moved or `vendor scan` drift), maps the
block's interfaces onto the CVA6 AXI seam + `architecture/uncore/<domain>.md`, and encodes the
exploration + integration plan. Create it **on-fetch**, refresh it **on-update**, finalize it
**on-integrate** — the same triggers as §5. The governing meta-spec + copyable template is
**`AGENTS-vendor-code-agents.md`**.

---

## 6. Lifecycle & status discipline

`planned` → `vendored` → `integrated`. Keep the catalog honest:

1. **planned**: catalogued only. No checkout expected.
2. **vendored**: checked out (`vendor status` shows *present*), pinned to a SHA, scanned once — but
   not in any flist yet.
3. **integrated**: referenced by a `corev_apu` flist / instantiated in RTL, with the
   `AGENTS-specs-to-impl.md` / SoC-readiness gates satisfied. Bump `status` **and** pin `ref` to a
   commit SHA when a block reaches this state.

The promotion from `vendored` to `integrated` follows the same gates as `architecture/README.md`
(config-gate, flist registration, verify/test/observe/document) — vendoring the source is step zero,
not the finish line.

---

## 7. Licensing scope (interaction with `AGENTS-licensing.md`)

- The **build-platform code** for this feature (`schema.ts`, `defaults.ts`, `load.ts`, `tooling/vendor.ts`,
  `cli/commands/vendor.ts`, `cli/registry.ts`, `cli/args.ts`) is in scope: `.ts` files carry
  `SPDX-License-Identifier: LicenseRef-Proprietary` © the active contributor (`.active-contributor` = Etienne Cimon), per
  `.licensing-policy`.
- **Vendored upstream source keeps its own license verbatim** — recorded in the entry's `license`
  field and never rewritten. Check compatibility (all shipped entries are MIT / BSD-2-Clause /
  Solderpad) before integrating.
- These `AGENTS-*.md` docs and `architecture/**` are **out of licensing scope** (docs).

---

## 8. Relationship to the existing mechanisms

- Existing `.gitmodules` entries (e.g. `corev_apu/fpga/src/ariane-ethernet`) stay where they are. The
  catalog **documents** them (`status: integrated`, `enabled: false`) so the map is complete; it does
  not re-fetch them.
- Existing `vendor/*.vendor.hjson` pins continue to work with their own tool. New controllers should
  prefer the catalog. Migrating an existing hjson pin = add a `mechanism: "vendor"` entry with the same
  `url`/`rev`/excludes, then retire the hjson file in a later pass.

---

## 9. See also

- `AGENTS-vendor-code-agents.md` — meta-spec + template for the per-vendor `agents/vendor/AGENTS-vendor-<id>.md` guides.
- `AGENTS-core-platform-vendor-actives.md` — the controller/PHY substructure feeding `corev_apu`.
- `AGENTS-corev-apu.md` — the uncore + surrounding-die outline and SystemVerilog preconditions.
- `architecture/uncore/` — per-domain RTL integration outlines.
- `build-platform/AGENTS.md` — the platform overview; `AGENTS-build.md` — the pointer from the root.
- `AGENTS.md` §0.4 / `AGENTS-licensing.md` — licensing; `AGENTS-coding-philosophy.md` — RTL discipline.
