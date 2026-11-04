# Uncore outline — Storamic

Status: default-off refusal foundation plus standalone executable-model slice
with selected leaf evidence; aggregate qualification remains open. The native
projection stays off/refuse — no native model or media grant. No VirtIO-MMIO
capability; the former CXL target is retired by the package's decision.
System specification: [Storamic](../storamic/README.md). Normative subsystem
contracts: [g6lc_storamic](../../g6lc_storamic/architecture/README.md). Source
audit: [general-purpose review](../../g6lc_storamic/architecture/general-purpose-review.md).

Attach through `corev_apu/storamic/` at the shared memory-side AXI boundary,
preserving native atomic/coherence ownership above it. `StoramicEn` excludes other
primary-memory backends for the same aperture. Existing targets remain unchanged
when disabled.

This is first-party RTL, not a vendor catalog entry. Its standalone closure may
not import LiteDRAM, PULP bus/cell implementations or external PCIe controllers.
Physical macro bindings remain separate and must not conceal digital controllers.
Board packages and pin constraints await actual component/PHY selection.

All QEMU work belongs exclusively to `g6lc_qemu/`; the testharness owns RTL
simulation and evidence collection, not a second emulator.

## Integration task map

The canonical [task backlog](../../g6lc_storamic/architecture/implementation-tasks.md)
owns status and acceptance criteria. Native integration work is:

- ST-004: joined-path refusal, request-service readiness and native build/preload guards.
- ST-010/ST-011: allocate control/IRQ/map bindings and carry full payload/attributes through the thin adapter.
- ST-012: selected-backend initialization, CPU/atomic/DMA ownership and native model boot.
- ST-015/ST-016/ST-031: selected physical bindings, constraints and profile qualification.

Keep controllers, routing, discovery and media state in `g6lc_storamic/`; keep
SoC types, configuration projection, address/IRQ integration and board bindings
outside its standalone closure. No QEMU launcher or model belongs in this adapter.
