# AGENTS Vendor Code-Agents — per-vendor self-aware guides

> **Scope:** how every vendored controller/PHY carries its **own** agent guide — an
> `AGENTS-vendor-<id>.md` that plays the role of an `AGENTS.md` *for that checked-out third-party
> codebase*. This file is the **meta-spec + template** that governs those per-vendor files: where they
> live, how they **version themselves against the build-platform catalog**, how they **keep themselves
> updated**, and how they **map the vendor's RTL onto the CVA6 core platform** (via the `architecture/`
> references) to drive integration and exploration. It is a **standing workflow rule** referenced from
> `AGENTS-vendor.md` and registered in `AGENTS.md` §2.

`AGENTS-vendor.md` says **how IP is fetched**; `AGENTS-core-platform-vendor-actives.md` says **which IP
exists and where it attaches**; `architecture/uncore/*` gives the **per-domain RTL outline**. This file
closes the loop: it makes each vendored tree **self-describing to agents**, so a large, unfamiliar
third-party repository becomes a small, navigable, versioned integration surface instead of a blind scan.

---

## 1. The idea in one paragraph

A vendored controller (LiteDRAM, verilog-pcie, hdl-util/hdmi, …) is a foreign codebase with its own
module names, buses, clocking, and conventions. Rather than re-discover it on every task, each vendored
block gets a **living companion guide** — `AGENTS-vendor-<id>.md` — authored against a **specific pin**
of that codebase, that (a) records what it was written against, (b) knows when it is **stale**, (c)
maps the block's interfaces to the CVA6 AXI seam and the `architecture/uncore/<domain>.md` outline, and
(d) tells an agent exactly how to explore and integrate it. It is to the vendored tree what `AGENTS.md`
is to CVA6: the entry point that makes the codebase answerable in one hop.

---

## 2. Placement & naming

- **Canonical location (tracked):** `agents/vendor/AGENTS-vendor-<id>.md`, where `<id>` is the catalog
  id (`config.vendor.controllers[].id`, e.g. `litedram`, `verilog-pcie`, `hdmi`). This sits beside
  `agents/spec/` and `agents/guides/`, is version-controlled in the superproject, and **survives
  submodule re-checkout / re-vendoring** (submodule working trees are *not* file-tracked by the
  superproject, so a file dropped inside the checkout would not persist or version cleanly).
- **Optional in-checkout overlay:** a copy or pointer may be placed at the checkout root
  (`<path>/AGENTS-vendor-<id>.md`) for tools that look for an `AGENTS.md` at a codebase root — but the
  **canonical, authoritative copy is the superproject one**. Never commit it upstream; never modify the
  vendor's own files.
- **One file per catalog id.** If a vendor ships several separable cores you still integrate as
  catalog ids, so the mapping stays 1:1.

---

## 3. Self-aware versioning (against the build-platform description)

The **source of truth for identity + pin is the catalog entry** (the "build-platform vendor description
file"): `VendorControllerSpec` in `build-platform/src/config/defaults.ts` (typed in `schema.ts`). Each
`AGENTS-vendor-<id>.md` **mirrors** the catalog fields it was authored against and adds a provenance
block so it can reason about its own freshness:

```yaml
# --- provenance (self-versioning header) ---
vendor_id:     litedram
upstream_url:  https://github.com/enjoy-digital/litedram.git
authored_ref:  <commit-sha or tag the doc was written against>   # MUST equal catalog ref when integrated
catalog_ref:   <ref currently pinned in config.vendor>            # copy at last refresh
mechanism:     submodule            # from catalog
domain:        memory               # from catalog
kind:          controller+phy       # from catalog
license:       BSD-2-Clause         # from catalog (upstream SPDX; never rewritten)
status:        planned|vendored|integrated   # from catalog, kept in lockstep
scan_fingerprint: { files: <n>, tops: [<top1>, ...] }   # from `vendor scan <id>`
authored_at:   <ISO date>
last_refresh:  <ISO date>
refresh_trigger: on-fetch|on-update|on-integrate|manual
```

**Staleness rule (the "self-aware" part).** The doc is **stale** — and must be refreshed before it is
trusted for integration — when **any** of these holds:

1. `authored_ref` ≠ the catalog `ref` (the pin moved via `vendor update`).
2. `vendor scan <id>` drift: the current file count / top-module set differs from `scan_fingerprint`.
3. `status` in the doc ≠ `status` in the catalog.

A stale doc is a **warning, not a failure** (mirroring the platform's preflight-skip philosophy): note
it, refresh it, then proceed.

---

## 4. Self-updating behaviour (like an AGENTS.md of the checkout)

The per-vendor doc is a **living artifact**, refreshed on the same lifecycle events that gate scanning
(`AGENTS-vendor.md` §5), so it stays a faithful `AGENTS.md`-equivalent of the pinned tree:

| Trigger | Action on `AGENTS-vendor-<id>.md` |
|---|---|
| **on-fetch** (first `vendor sync`) | **Create** it from the template using `vendor scan <id>` output; set `authored_ref` to the pinned SHA and capture the fingerprint. |
| **on-update** (`vendor update`) | **Refresh** the interface map + fingerprint against the new ref; append a Refresh-log row; bump `authored_ref`/`catalog_ref`/`last_refresh`. |
| **on-integrate** (wiring into a flist) | **Finalize**: confirm the interface/connectivity map matches the wrapper actually written; flip `status` to `integrated` in both doc and catalog. |
| **manual** | Small clarifications; no ref change. |

The refresh is an **agent procedure**, not magic: after a sync/update, run `vendor scan <id> --json`,
diff against the recorded fingerprint, and rewrite the sections that changed. Keep the prose short and
the maps precise — the same discipline that keeps `AGENTS.md` under a page per topic.

---

## 5. Connective capabilities to the core platform

The doc's highest-value job is **connectivity**: turning the vendor's interfaces into a concrete
attachment to CVA6. It must cross-link the three platform anchors and translate between them:

- **Domain outline** — `architecture/uncore/<domain>.md` (the RTL integration plan; from the catalog
  `architectureDoc`). The vendor doc is the *instance* of that outline for this specific pin.
- **Substructure row** — `AGENTS-core-platform-vendor-actives.md` (the on-die-controller vs board/PHY
  split and the AXI seam).
- **Preconditions** — `AGENTS-corev-apu.md` §3 (the SystemVerilog gate: AXI/AXI-Lite front-end,
  async-active-low reset, explicit CDC for the vendor's clock domain, `tc_sram`/`tc_clk_gating`, PHY
  separation, DFT, RVFI/PMU, flist/DTS).

Concretely, the doc records a **connectivity map**: `<vendor top module>.<port group>` → CVA6
`ariane_axi_pkg` AXI channel / PLIC interrupt / clock domain, plus the PHY boundary (what is on-die vs
board/target). That map is what "optimizes connective capabilities" — the next agent wires the block
without re-reading the whole tree.

---

## 6. Exploration & integration dynamics

The doc encodes **how to navigate** the tree (so exploration is cheap) and **how to land it** (so
integration is deterministic):

- **Exploration map** — the `scanPaths` roots, the top module, config/parameter knobs, clock/reset
  inputs, the PHY boundary module, and the sim/test entry points; a small *navigate-by-intent* table
  (mirroring `AGENTS.md` §3) so an agent opens only the 3-6 files it needs.
- **Integration plan** — the promotion path from `AGENTS-vendor.md` §6 / `architecture/uncore/README.md`
  (config-gate → `corev_apu` AXI wrapper → flist → verify/test → observe → document), annotated with
  the specific ports/parameters this block needs, and the `AGENTS-corev-apu.md` precondition checklist
  ticked or flagged.
- **Inference hooks** — explicit *open questions / risks* (e.g. "PHY is FPGA-vendor MIG — ASIC needs a
  hard macro"; "clock domain X crosses to AXI, CDC FIFO required") so the next agent can infer the
  remaining work rather than rediscover the gaps.

---

## 7. The template (copy this into `agents/vendor/AGENTS-vendor-<id>.md`)

```markdown
# AGENTS Vendor — <id> (<one-line role>)

<!-- provenance block from §3 (yaml) -->

## 1. Identity
What this block is; upstream + license (from catalog); the pinned ref this doc describes.

## 2. Controller vs PHY split
On-die controller vs board/analog PHY (from the actives row + scan). The decisive boundary.

## 3. Top-level interface map (from `vendor scan <id>`)
- Top module(s): <top>
- Bus: <AXI4 / AXI-Lite / AXI-Stream / native> — width/id/user
- Parameters: <the knobs that must match config_pkg / ariane_axi_pkg>
- Clocks/resets: <domains + which cross into the core domain>
- Interrupts: <lines → PLIC>

## 4. Connectivity to CVA6
- AXI seam: <how it attaches at ariane.sv / corev_apu xbar>
- Wrapper plan: <corev_apu/... module to write>
- Cross-links: architecture/uncore/<domain>.md · AGENTS-core-platform-vendor-actives.md ·
  AGENTS-corev-apu.md §3 (preconditions)

## 5. Exploration map (navigate by intent)
| To find... | Open (within the checkout) |
|---|---|
| top / bus front-end | <path> |
| config / parameters | <path> |
| PHY boundary | <path> |
| sim / tests | <path> |

## 6. Integration plan (promotion path)
Config-gate → AXI wrapper → flist → verify (tb + DTS) → observe (PMU/RVFI) → document.
Preconditions checklist (AGENTS-corev-apu.md §3): [ ] reset [ ] CDC [ ] tc_sram [ ] DFT [ ] AXI types
[ ] PHY separation [ ] flist [ ] DTS cross-validation.

## 7. Verification & software hooks
tb entry, device-tree node, mainline Linux driver.

## 8. Open questions / risks
Explicit gaps for the next agent to infer against.

## 9. Refresh log (self-versioning history)
| date | ref | trigger | what changed |
|---|---|---|---|
```

A skeleton authored purely from **catalog-known** facts (no invented module names) is a valid *planned*
stub; the scan-derived sections are filled `<from vendor scan>` until the block is fetched.

---

## 8. Lifecycle & maintenance discipline

- **Create on-fetch, refresh on-update, finalize on-integrate.** Keep `status` and `authored_ref` in
  lockstep with the catalog; pin to a commit SHA before `integrated`.
- **The catalog is authoritative for identity/pin; the doc is authoritative for the interface map.** If
  they disagree, the doc is stale — refresh it.
- **Docs only.** `AGENTS-vendor-<id>.md` is documentation → **out of licensing scope** (`AGENTS.md`
  §0.4). It records the upstream SPDX from the catalog and **never** copies or rewrites the vendor's
  license or source.
- **One hop, one page per topic.** Keep each section terse; link, don't restate, the domain outline and
  preconditions.

---

## 9. See also

- `AGENTS-vendor.md` — fetch/update/scan mechanism + when scanning is required (the triggers this doc rides).
- `AGENTS-core-platform-vendor-actives.md` — controller/PHY substructure + on-die/board split.
- `AGENTS-corev-apu.md` — the uncore SystemVerilog preconditions the connectivity map must satisfy.
- `architecture/uncore/*` — the per-domain RTL outlines each per-vendor doc instantiates.
- `AGENTS.md` §2 (substructure map) · §0.4 (licensing scope) · `build-platform/AGENTS.md` (the `vendor` command).
