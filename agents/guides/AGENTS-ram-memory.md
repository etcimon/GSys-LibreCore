# Guide: RAM / Memory (PMA, MMU, PMP, AXI)

Feature-addition playbook for the memory system. Read `../../AGENTS.md` first. Spec summaries live in
`../spec/` (see `../spec/INDEX.md`).

## Table of contents
1. Spec grounding
2. Code map (`file:line`)
3. Config knobs
4. Feature-addition playbook
5. `.dts` linkage
6. Invariants and pitfalls

## 1. Spec grounding
The memory system is heavily normative: `specs/riscv-spec.html#sec:intro-memory` (1.4 — the single
byte-addressable `2^XLEN` space), `#pma` (3.6 — Physical Memory Attributes: cacheability, coherence,
idempotency, atomicity, alignment per region), `#pmp` (3.7 — Physical Memory Protection),
`#sv39` (4.4 — 39-bit paging; siblings `#sv32`, `#sv48`, `#sv57`), plus the `Sv` extensions
`#ext:svadu` (HW A/D), `#ext:svinval` (fine-grained TLB invalidation), `#ext:svnapot`,
`#ext:svpbmt`, and misaligned/fetch rules `#ext:zicclsm`, `#ext:ziccif`.
Sub-files: `../spec/riscv-spec-II-3.6-pma.html`, `-II-3.7-pmp.html`, `-II-4.4-sv39.html`, `-I-1.4-memory.html`.

## 2. Code map
- LSU top: `core/load_store_unit.sv`; loads `core/load_unit.sv`; stores `core/store_unit.sv`; store queue `core/store_buffer.sv`; AMOs `core/amo_buffer.sv`; bypass `core/lsu_bypass.sv`.
- MMU / translation: `core/cva6_mmu/` (page-table walker, I/D TLBs, Sv modes); see `docs/06_cv64a6_mmu/` and `docs/03_cva6_design/MMU.rst`.
- Protection: `core/pmp/` (PMP entry matching and checks).
- Memory-side bus: `core/cache_subsystem/axi_adapter.sv`, `wt_axi_adapter.sv`; SoC RAM `corev_apu/axi_mem_if/`; boot `corev_apu/bootrom/`.

## 3. Config knobs (`core/include/config_pkg.sv`)
- Virtual-memory mode `vm_mode_t` enum `45-52` (`ModeSv32/39/48/57`); TLB sizing `InstrTlbEntries` `257`, `DataTlbEntries` `258`.
- Memory bus `Axi{Addr,Data,Id,User}Width` `168-176`, `AxiBurstWriteEn` `176`.
- Region rules used by PMA/decoding, validated in `check_cfg` `451-453`: `NrCachedRegionRules`, `NrExecuteRegionRules`, `NrNonIdempotentRules` (each <= `NrMaxRules`=16 at `60`).
- Widths `XLEN`/`VLEN` and paging depend on the target package (`core/include/cv*_config_pkg.sv`).

## 4. Feature-addition playbook
Adding or resizing a RAM region is config-first. Set the physical base/size through the target
package's region rules and mark it cacheable/executable/idempotent as appropriate; a device (MMIO)
region must instead be added to the non-idempotent, non-cacheable set so it is neither speculated
nor cached. Match `Axi*Width` to the SoC interconnect and the memory in `corev_apu/axi_mem_if/`.
Selecting a different paging mode is a change of `vm_mode_t` plus the MMU elaboration in
`core/cva6_mmu/`; enabling hardware A/D or fine-grained invalidation pulls in `Svadu`/`Svinval` and
their CSR plumbing. PMP entries are configured through the machine CSRs and checked in `core/pmp/`.
Every change must be reflected in the device tree so Linux sees the same map (below).

## 5. `.dts` linkage
The physical RAM is a `memory@<base> { device_type = "memory"; reg = <hi lo size>; }` node whose
base/size must lie within `AxiAddrWidth` and match the cacheable region rules. The CPU node carries
`mmu-type = "riscv,sv39"` (etc.) mirroring `vm_mode_t`, and `riscv,isa` must list the enabled `Sv`
extensions. MMIO peripherals appear under the `soc` node with `ranges`/`reg` matching the
non-idempotent regions; `clint@`/`plic@` map to `corev_apu/clint` and `corev_apu/rv_plic`.

## 6. Invariants and pitfalls
Non-idempotent (MMIO) regions must never be cached or speculatively accessed — mis-tagging a region
cacheable is the classic bug that breaks device I/O. PMA (`#pma`) is checked before PMP (`#pmp`);
both must agree with the `.dts`. Misaligned accesses depend on `Zicclsm` (`#ext:zicclsm`); if absent,
the LSU traps. TLB reach and `*TlbEntries` must suit the page sizes of the chosen `Sv` mode, and the
`.dts` `mmu-type` must equal `vm_mode_t` or Linux will fault during early paging.
