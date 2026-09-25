# Technology spec — `g6lc_ooo_snoop_filter` sharer-signature SRAM

Scope: the single `tc_sram` instance `i_presence` in
`corev_apu/coherence/g6lc_ooo_snoop_filter.sv`, `ImplKey = "g6lc_coh_signature"`. It exists only
when `CVA6Cfg.CohPolicy == COH_OOO` (promoted envelope: `g6lc64_ooo_int2`, two WT cores, L2).
This document is the macro-binding and DFT plan required by `AGENTS-technology.md` §6 and
`agents/guides/AGENTS-soc-readiness.md` ("plan MBIST for any new SRAM instance"); it does not by
itself arm the technology pass (`technology.optimizationPass` stays `false`).

## Geometry (generic path)

| Parameter | Value | Derivation |
|---|---|---|
| Words | `SNOOP_FILTER_ENTRIES` (128 in `g6lc64_ooo_int2`) | one word per line index |
| Data width | `32 * ceil(NR_CORES / 4)` bits (32 for 2..4 cores) | one byte lane per core, padded to 32-bit words |
| Byte width | 8 | per-core byte writes; only bit 0 of each lane is logical |
| Ports | 1 | lookup (read) and acquisition (write) arbitrate on the port; lookup wins |
| Latency | 1 | `result_valid_o` one cycle after `lookup_valid_i && lookup_ready_o` |
| Init | none | cold sweep writes every word to 0 after reset (`NR_ENTRIES` cycles); `ready_o` is low until done |

Logical state is `NR_ENTRIES * NR_CORES` bits (256 for 2 cores / 128 entries); the padded
storage is 4,096 bits. Keep the two numbers separate in area records
(`AGENTS-optimization-tool.md`).

## Binding rules

- Swap only at the `tc_sram` seam: a technology wrapper selected by `ImplKey` must be
  port- and latency-equivalent (1-cycle read, byte-write enables, single port).
- The filter never relies on SRAM reset contents; the cold sweep is the initialization
  contract. A macro with a hardware clear may skip the sweep only if the wrapper still asserts
  `ready_o` no earlier than the generic path would.
- Conservative correctness depends on writes never being dropped: any wrapper that adds write
  latency or a write-collision rule must preserve "a granted acquisition is visible to the next
  lookup that starts after it".

## DFT / MBIST plan

- MBIST: the macro is idle whenever the hub holds no AW lookup and no AR acquisition, which is
  the reset state and any quiescent point; BIST may own the port through the wrapper while
  `ready_o` is held low, since the hub gates AW/AR admission on `ready_o` (`sig_initialized`).
  A BIST pass that clears the array must be followed by the cold sweep or an equivalent clear,
  because any set bit is conservative but a cleared bit for a line a core still holds is not.
- Scan: the filter adds registered state only (`initialized_q`, `init_index_q`,
  `result_valid_o`); no new clock, reset domain or latch; `test_en_i`/`testmode_i` paths in the
  cluster are unchanged.
- Observability: PMU group 2 events 5/6 (L1 invalidation applied, COH_OOO load replay) and the
  hub's `coh_sf_overapprox_o` (asserted per accepted invalidating write under `COH_OOO`).

## Open

Foundry macro selection, MBIST controller instantiation, STA on the target library and power
characterization are physical-design deliverables under `pd/pdk/<technology>/`; none is claimed here.
