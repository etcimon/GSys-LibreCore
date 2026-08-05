# Guide: Speculative Execution

Feature-addition playbook for speculation, flush/recovery, and memory ordering. Read `../../AGENTS.md`
first. Spec summaries live in `../spec/` (see `../spec/INDEX.md`).

## Table of contents
1. Spec grounding
2. Code map (`file:line`)
3. Config knobs
4. Feature-addition playbook
5. `.dts` linkage
6. Invariants and pitfalls

## 1. Spec grounding
Speculation is microarchitectural but strictly bounded by architecture: `specs/riscv-spec.html#memorymodel`
(3.1 RVWMO — preserved program order, fences, address/data/control dependencies), `#ext:ztso` (3.2),
`#ext:zifencei` (4.1 — instruction-fetch fence), the atomics `#ext:a` (5.1) and `#ext:zalrsc` (5.2 —
LR/SC reservations that misspeculation must not lose), `#ext:zawrs` (5.5 — wait-on-reservation
stalls), acquire/release `#ext:zalasr`, and precise-trap requirements in Privileged chapter 3.
Sub-files: `../spec/riscv-spec-I-3.1-rvwmo.html`, `-I-4.1-zifencei.html`, `-I-5.1-a.html`, `-I-5.5-zawrs.html`.

## 2. Code map
The speculation pipeline is a composition, not one module:
- Predict: `core/frontend/frontend.sv` (see `AGENTS-branch-prediction.md`).
- Track in-flight: `core/scoreboard.sv` (the speculative window; operands via `core/issue_read_operands.sv`).
- Execute: `core/ex_stage.sv`; branch resolution `core/branch_unit.sv` -> `resolved_branch_i`.
- Retire in order: `core/commit_stage.sv` (architectural state changes only here).
- Flush/redirect: `core/controller.sv` (`flush_i` sequencing) -> frontend redirect `core/frontend/frontend.sv:48,308`.
- Memory speculation: `core/load_unit.sv` (speculative loads / hazard checks), `core/store_buffer.sv` (speculative vs committed stores), `core/lsu_bypass.sv`, `core/amo_buffer.sv`.

## 3. Config knobs (`core/include/config_pkg.sv`)
- `NrScoreboardEntries` `241` (size of the in-flight/speculative window).
- `NrLoadBufEntries` `243`, `MaxOutstandingStores` `245` (memory-speculation depth).
- `WtDcacheWbufDepth` `219` (write-through drain depth interacting with store retirement).

## 4. Feature-addition playbook
Deepening speculation is primarily a sizing change: raise `NrScoreboardEntries` and the LSU buffer
depths in the target package, then verify the flush path still clears every speculative structure.
The correctness contract is that a flush from `core/controller.sv` must invalidate the scoreboard
entries, the frontend prediction in flight, and any un-committed LSU state simultaneously; adding a
new speculative buffer means adding it to that flush fan-out. Architectural writes happen only at
`core/commit_stage.sv`, and stores must not leave `core/store_buffer.sv` toward memory until they are
non-speculative. LR/SC reservations tracked in the D$/LSU must survive intervening speculation and be
cleared on the events RVWMO/`Zalrsc` require. If you add a new ordering primitive, encode it against
RVWMO preserved-program-order rules rather than ad hoc stalls.

## 5. `.dts` linkage
Speculation is not device-tree visible. Its only DT-facing footprint is the extension string
`riscv,isa` (the `A`, `Zawrs`, `Ztso`, `Zalasr` letters must match the config) and, where errata
mitigations are exposed, CPU-node `compatible` handling in software — not a DT property to add.

## 6. Invariants and pitfalls
Precise traps are non-negotiable: no exception, store, CSR side effect, or reservation change may
become architecturally visible before in-order commit. Store-to-load forwarding in the LSU must obey
RVWMO (`#memorymodel`); a forwarding path that ignores address dependencies is a memory-model bug,
not just a performance issue. Misspeculation must fully restore the reservation and store-buffer
state. Modern designs also consider transient-execution side channels; the spec does not mandate
mitigation, so treat it as a design decision documented alongside any widening of the window.
