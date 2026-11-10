# r98 design and evidence boundaries

The accepted transformations expose parallel combinational work inside existing
operation lifetimes. Neither creates a pipeline stage or changes service interval.
Production `core/` and `corev_apu/` remain the functional references. Final
measurements, receipts and outstanding qualification tasks are in `worklog.md`.

## Caller bindings and invariants

| Surface | Binding used | Preserved contract |
|---|---|---|
| LSQ credits | Eight load/eight store entries, four-bit free counts | Registered occupancy only; no credit from pending events |
| PMP structural screen | Scalar XLEN64/PLEN56, eight implemented entries | Existing RMW, request owner and architectural apply edge |
| PMP bank discriminator | RV32/PLEN34 and RV64/PLEN56, full64-row candidate bank | Address/byte mapping, enable, locks, VS conversion and entry63 boundary |
| L2/L3 MSHR experiment | Depth2/4, line512, metadata17, waiter1/4 | FIFO order, pop/attach/complete/allocation priority, flush/reset |

## LSQ reduction

Each slot contributes one free bit using `valid === 1'b0`. This preserves the
old procedural `if (!valid)` treatment of unknown valid bits. Free counts are
explicitly sized `$countones` results; full flags reduce the same free masks.
Allocation, commit, cancellation, flush and event scheduling retain their
existing state boundaries. Width casts in the event/bench path make intended
sizes explicit; the bench's age input is connected to its distance data.

Timing acceptance required a package repair first. An intrinsic population count
cannot use the generic one-FO4 call fallback. Delay-v50 resolves the operand
width and bills a balanced reduction through the existing scaled-adder model.
Eight leaves use result widths2/3/4, costing `2 + 2*log2(3) + 4` FO4. Argument
arrival, nested calls and parallel branches retain expression-DAG ordering.
Unresolved width is marked, and function-body/spine estimates remain outside
this qualification. No technology/load-law calibration was changed.

## PMP row preparation

For architectural row `p`:

```text
configuration CSR = PMPCFG0 + (p / (XLEN / 8)) * (XLEN / 32)
configuration byte = p % (XLEN / 8)
address CSR = PMPADDR0 + p
address writable = !own_lock && !(p < 63 && next_lock && next_mode == TOR)
```

These indices are elaboration constants. Each generated row starts from its
registered value and applies only its matching enabled write. Odd PMPCFG CSRs
remain illegal in RV64. Entry63 has no neighbor; the retained simulation
reference explicitly bounds its previous dynamic neighbor read.

The actual VS converter maps only100..105/140..180 into2xx. Neither the input
nor output conversion domain intersects PMP3a0..3ef, so this bank decodes the
retained original address. This removes a structurally misleading conversion
dependency without changing which PMP write is selected.

WARL, read-only, unimplemented-entry normalization, privilege/owner checks, reset,
RMW data and final apply are outside the changed bank. `prepare_pmp.py` verifies
those surrounding bytes against the frozen source, allowing only the explicit
reference neighbor bound and EOF blank-line normalization. It extracts the
candidate bank and actual converter verbatim into private wrappers; the old bank
receives only the boundary normalization. The fixture is a bank discriminator,
not a replacement for full CSR retirement/permission qualification.

## Rejected MSHR experiment

Per-entry next-state predicates passed the original/candidate miter and directed
FIFO/ownership checks. The raw structural screen increased, while path review
also found distinct-entry aliasing and unresolved field widths. This cannot
justify a timing reduction or establish a physical regression.

The live MSHR is restored byte-for-byte to the frozen baseline. The candidate
is retained as `mshr-per-entry.rejected.sv`, matching both after manifests.
Future restructuring must first preserve entry identity and field widths in
measurement, then separate row-local data preparation from selection without
lengthening waiter attachment or changing pop/completion priority.

## Evidence and qualification

`screen.py` pins source/common inputs, the native tool and measurement versions.
Explicit baseline reuse requires its SHA. `audit.json` records the frozen leaf
receipts, retained timing identities and scoped licensing/syntax checks. LSQ
functional identity was regenerated on the final LF-byte sources after the
temporary CRLF edit artifact was normalized. `aggregate-review.json` records
the later build/model/ELF identity checks and diagnostic reassessment; its
`g6lc_lsq_event.sv` entry is LF-normalized equivalence, not byte equality,
because that aggregate predates normalization.

The scalar model and seven smokes pass with the prior cycle counts. Aggregate
qualification remains open: warnings persist, and the eight-wide MC profile
has unsound derived store capacity and truncated checkpoint metadata. The
runner now rejects RTL `$error` warnings despite a zero compiler exit. The
MC repair must cover configuration and all producer/record/consumer boundaries;
silencing diagnostics or changing only a consumer cast is insufficient.

No new storage, SRAM/clock/reset/DFT boundary, instruction, CSR encoding, device
tree capability or PMU feature was added. Area/power and physical timing remain
unmeasured. CSR/boot work stays paused; full OpenSBI/Linux, SMT retirement and
eight-FO4 closure are not implied by this batch.
