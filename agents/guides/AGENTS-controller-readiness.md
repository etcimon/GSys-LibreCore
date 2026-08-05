# Guide: Controller / uncore readiness (vendor build-platform → core SystemVerilog)

Feature-addition playbook for bringing an external uncore controller or PHY IP onto the CVA6
die through the `build-platform` vendor catalog. Read `../../AGENTS.md` first; the mechanism lives in
`AGENTS-vendor.md`, the on-die/board split in `AGENTS-core-platform-vendor-actives.md`, the
SystemVerilog preconditions in `AGENTS-corev-apu.md`, and the per-domain RTL outlines in
`architecture/uncore/*.md`.

## Table of contents

1. Platform grounding
2. Code map (`file:line`)
3. Config knobs
4. Feature-addition playbook
5. `.dts` linkage
6. Invariants and pitfalls

---

## 1. Platform grounding

CVA6 is a CPU core (`core/`). A chip needs an **uncore** around it: DRAM, PCIe, Ethernet,
SATA/SD, HDMI, etc. The `build-platform` adds a typed `vendor` catalog
(`config.vendor.controllers`) so each external controller/PHY is declared once, fetched on
demand, scanned at the right lifecycle event, and tracked through `planned` → `vendored` →
`integrated`. This guide aggregates the **concrete SystemVerilog consequences** of that catalog:
every entry is still an **AXI citizen** that must satisfy the `AGENTS-corev-apu.md` preconditions
before it can enter a `corev_apu` flist. The catalog is the control surface; the core/uncore RTL is
where the integration gates are enforced.

---

## 2. Code map

- **Build-platform catalog types:** `build-platform/src/config/schema.ts:276-373`
  (`VendorDomain`, `VendorKind`, `VendorMechanism`, `VendorStatus`, `VendorControllerSpec`,
  `VendorConfig`).
- **Default catalog entries:** `build-platform/src/config/defaults.ts:472-653`
  (`vendor.controllers` for DDR4, Ethernet, PCIe, HDMI, SATA/SD, existing `ariane-ethernet`).
- **Catalog validation:** `build-platform/src/config/load.ts:115-126` (unique ids/paths, required
  `url` + `path`).
- **Fetch / update / scan engine:** `build-platform/src/tooling/vendor.ts:1-396`
  (`selectControllers`, `syncControllers`, `updateController`, `scanController`,
  `needsScan`).
- **CLI command:** `build-platform/src/cli/commands/vendor.ts:42-127`
  (`list`, `status`, `sync`, `add`, `update`, `scan`).
- **Core AXI memory-side seam:** `corev_apu/src/ariane.sv:67-68` (`noc_req_o` / `noc_resp_i`),
  parameterised by `ariane_axi_pkg` types.
- **Core config struct:** `core/include/config_pkg.sv:62-438` (`cva6_cfg_t`), with legality
  assertions in `check_cfg` at `446-468`.
- **Uncore preconditions (the gate):** `AGENTS-corev-apu.md` §3 (clock/reset, CDC, AXI,
  `tc_sram`, PHY separation, DFT, observability, flist/DTS).
- **Per-domain integration outlines:** `architecture/uncore/*.md` (`README.md`,
  `ddr4-controller.md`, `ethernet-controller.md`, `pcie-root-complex.md`,
  `storage-controllers.md`, `hdmi-display.md`).
- **Per-vendor code-agent guides:** `agents/vendor/AGENTS-vendor-<id>.md` governed by
  `AGENTS-vendor-code-agents.md`.

---

## 3. Config knobs

### 3.1 Build-platform catalog fields (`VendorControllerSpec`, `schema.ts:324-361`)

| Field | Why it matters for core SystemVerilog |
|---|---|
| `id` | CLI handle + catalog key; drives `agents/vendor/AGENTS-vendor-<id>.md` and wrapper `ifdef` names. |
| `domain` | Groups controllers by subsystem (`memory`/`network`/`interconnect`/`storage`/`display`/…). |
| `kind` | `controller`/`phy`/`controller+phy` — forces the on-die/board boundary decision. |
| `mechanism` | `submodule` (preferred, easy re-pin) or `vendor` (snapshot for in-tree patches). |
| `url`, `ref` | Upstream pin. **Pin `ref` to a commit SHA before `integrated`.** |
| `path` | Repo-relative checkout path; for `submodule` it must match `.gitmodules`. |
| `license` | Upstream SPDX; compliance only, never rewritten. |
| `status` | `planned` → `vendored` → `integrated`. Keep in lockstep with the wrapper/FLIST. |
| `enabled` | Default `false`. Nothing is fetched implicitly; `vendor sync` (no args) only fetches `enabled` entries. |
| `scanPaths` | Sub-trees to enumerate (`vendor scan <id>`) before wiring the block. |
| `scanOn` | Triggers requiring re-scan (`on-fetch`, `on-update`, `on-integrate`, `manual`). |
| `integrationSeam` | Where the wrapper lands, e.g. `corev_apu/fpga/src`. |
| `phyNote` | The decisive on-die controller vs board/analog PHY split. |
| `architectureDoc` | The per-domain outline in `architecture/uncore/*.md`. |

### 3.2 Core / uncore gating knobs

- **Core config:** `CVA6Cfg` (`config_pkg.sv:62-438`) carries feature bits; add a per-board or
  per-controller parameter when the controller is ISA/SoC-visible. Keep it off by default so
  minimal configs still elaborate. Add a `check_cfg` assertion (`446-468`) for legal combinations.
- **Board narrowing:** `corev_apu/fpga/src/ariane_xilinx.sv` uses `` `ifdef GENESYSII / KC705 /
  NEXYS_VIDEO / VCU118 / … `` plus `corev_apu/fpga/*.svh` to select pins, PHY instantiation, and
  optional controller wrappers.
- **AXI widths:** `ariane.sv:42-49` pulls `AxiAddrWidth`, `AxiDataWidth`, `AxiIdWidth`, and
  channel types from `ariane_axi_pkg`. The controller wrapper must match these; no ad-hoc bus widths.

---

## 4. Feature-addition playbook

Adding a controller is a **catalog → scan → wrapper → flist → verify** chain, not a single edit.

1. **Catalog the IP.** Add a `VendorControllerSpec` to
   `build-platform/src/config/defaults.ts:480-653` (or your `.config.ts` overlay) with `status:
   planned`, `enabled: false`, `kind`/`phyNote` that honestly split on-die from board/analog, and
   `architectureDoc` pointing at a new or existing `architecture/uncore/<domain>.md` outline.
2. **Validate the catalog.** `bunx tsc --noEmit && bun test` runs `validateConfig`
   (`load.ts:115-126`) and ensures ids/paths are unique and required fields are present.
3. **Document the domain outline.** If this is a new subsystem, create
   `architecture/uncore/<domain>.md` describing intent, chosen controller, PHY split, AXI seam,
   config gate, invariants, verification, DTS, and scan pointers. It is a scaffold (not compiled).
4. **Fetch.** `vendor sync <id> --dry-run` previews the git action; then `vendor sync <id>`
   checks out the block (submodule or snapshot). For submodules the path must not collide with an
   existing `.gitmodules` entry (`tooling/vendor.ts:94-99`).
5. **Scan.** `vendor scan <id> --json` enumerates the RTL file set and top modules bounded at
   4000 files (`tooling/vendor.ts:27-32`). Use the output to fill the per-vendor guide.
6. **Create the per-vendor code-agent guide.** Write `agents/vendor/AGENTS-vendor-<id>.md` from the
   template in `AGENTS-vendor-code-agents.md` §7, including the provenance block (`authored_ref`,
   `catalog_ref`, `scan_fingerprint`) and the interface/connectivity map.
7. **Implement the `corev_apu` wrapper.** This is the SystemVerilog integration point:
   - Attach to the AXI/NoC fabric at `ariane.sv:67-68` / the `corev_apu` xbar.
   - Gate the block with a `CVA6Cfg` bit or board `*.svh` define so it is absent in minimal configs.
   - Apply `AGENTS-corev-apu.md` §3: async-active-low reset, explicit CDC for every off-core clock,
     `tc_sram` for packet/DMA/line buffers, `tc_clk_gating`, `test_en_i`/`testmode_i` propagation,
     AXI type reuse, and PHY separation (board wrapper, not reusable RTL).
8. **Register in the flist / build.** Add reusable source files to the relevant
   `corev_apu/fpga/Makefile` or Bender manifest; board-specific files are selected by target.
9. **Verify.** Add a directed test + device model in `corev_apu/tb/` or `verif/`, keep the
   compliance regression green, and run `bun test`.
10. **DTS / software.** Add the MMIO / interrupt / memory-map node in `corev_apu/**/*.dts*` and
    cross-validate per `AGENTS-dts-validation.md`. Point at a mainline Linux driver where one
    exists; note if a bespoke driver is required.
11. **Observe.** Add a PMU event in `core/perf_counters.sv` and RVFI/debug visibility where relevant
    (`AGENTS-corev-apu.md` §3.8).
12. **Promote.** Change catalog `status` to `integrated` and pin `ref` to the exact commit SHA the
    wrapper was verified against. Update `AGENTS-core-platform-vendor-actives.md` and regenerate
    its table from the catalog.

---

## 5. `.dts` linkage

A controller is a **memory-mapped AXI slave** (and optionally an AXI master for DMA). Its
`integrationSeam` plus `phyNote` determine the device-tree shape:

- **MMIO base/size** must lie inside a `non-idempotent` (device) region declared in
  `config_pkg.sv` region rules and in the `.dts` `soc` node, or the core may cache/speculate it.
- **Interrupts** route to `corev_apu/rv_plic` lines and must match the PLIC node in the `.dts`.
- **DMA masters** (framebuffer scanout, PCIe, NIC, SATA) appear as additional AXI masters on the
  xbar; their address windows must be reflected in the `.dts` `ranges` if the controller has its
  own subordinate bus.
- **ISA / capability exposure:** if the controller enables a discoverable feature (e.g. a display
  framebuffer, PCIe ECAM), update the CPU or `/soc` compatible/properties and keep them in sync
  with `misa`/ISA string and `AGENTS-specs-to-impl.md`.

Use `AGENTS-dts-validation.md` and `AGENTS-corev-apu.md` §3.11 as the cross-validation procedure.

---

## 6. Invariants and pitfalls

- **Controllers are not core pipeline edits.** Do not reach into `core/issue_read_operands.sv`,
  `core/scoreboard.sv`, or the cache controllers unless a feature truly requires it. Add at the
  `corev_apu` AXI seam or behind CVXIF.
- **PHY separation is decisive.** On-die = digital controller RTL. Analog PHY / SerDes / high-speed
  I/O (DDR MIG, PCIe transceiver, Ethernet PHY chip, HDMI re-driver) are board/target items, never
  soft-coded into reusable controller RTL.
- **No implicit fetching.** `enabled: false` and `status: planned` are the shipped defaults. A
  checkout only happens after an explicit `vendor sync <id>` or `--all`.
- **Pin before integration.** Move `ref` from a floating branch to a commit SHA when `status` becomes
  `vendored` or `integrated` so the per-vendor guide and the wrapper agree on the exact RTL.
- **Catalog is identity; per-vendor guide is interface map.** If `vendor scan <id>` drifts from the
  recorded `scan_fingerprint`, the guide is stale and must be refreshed before integration.
- **Minimal-config elaboration.** The block must be gateable out entirely; `cva6_cfg_empty`
  (`config_pkg.sv:442`) and the smallest target packages must still synthesize.
- **AXI is the only reusable bus.** Use `ariane_axi_pkg` / `ariane_axi_soc_pkg` types; do not
  introduce ad-hoc protocols across `corev_apu`.
- **Every off-core clock is a CDC.** DDR, PCIe, SerDes, pixel, and PHY RX/TX clocks require an
  explicit async FIFO or synchroniser, documented in the wrapper and per-vendor guide.
- **Backend boundaries.** Arrays go through `tc_sram`; gating through `tc_clk_gating`; power cells
  through `tc_pwr.sv`. Large blocks need their own placement/clock/power plan.
- **DFT threading.** Propagate `test_en_i` / `testmode_i` through new stateful logic and memories.
- **Licensing is split.** Vendored upstream source keeps its own license (recorded in the catalog);
  new `build-platform`/wrapper **code** is MIT per `.licensing-policy`. Docs are out of scope.

---

## See also

- `AGENTS-vendor.md` — fetch/update/scan mechanism and lifecycle.
- `AGENTS-core-platform-vendor-actives.md` — the on-die controller vs board/PHY substructure.
- `AGENTS-corev-apu.md` — SystemVerilog preconditions for `corev_apu` wrappers.
- `AGENTS-vendor-code-agents.md` — meta-spec + template for `agents/vendor/AGENTS-vendor-<id>.md`.
- `architecture/uncore/*` — per-domain RTL integration outlines.
- `AGENTS-soc-readiness.md` — cross-cutting SoC/tape-out discipline.
