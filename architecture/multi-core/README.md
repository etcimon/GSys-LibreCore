# Extension point: multi-core (1…8)

**U6.2.** Shared L2 (U6.0) in `../../corev_apu/l2_cache/`. Cluster size is
`cva6_cfg_t.NrCores` ∈ {1..`CVA6_MAX_CORES`} (default max **8**; override with
`` `define CVA6_MAX_CORES N ``). SMT threads **per core** remain `NrHarts` ≤ 2.

Guides: `../../agents/guides/AGENTS-l2l3-cache.md`, `../../agents/guides/AGENTS-soc-readiness.md`.
Sequence: `../remaining-upgrade-sequence.md`.

## Intent
N coherent CVA6 cores: shared LLC, write-invalidate coherence, scaled CLINT/PLIC,
unique `mhartid`, SMP Linux. Not dual-only — **parameterized 2–8**.
SMT fetch recover (`g6lc_sib_cjalr`) is **per core** (`[NrHarts]`); raising N
does not re-open G1\* — `../multi-threading/soft-ladder/CONTRACT.md` §8.

## Current state
| Item | Status |
|------|--------|
| Shared L2 (U6.0) | `corev_apu/l2_cache/` |
| L3 + stream PF | `corev_apu/l3_cache/` + `g6lc_server_prefetcher` (ooo_server / server_math PF) |
| Inclusive L3→L2/L1 | **Live** — L2 `l2_back_inval_*` + L1 `g6lc_l3_inclusive_inv`; TB `INCLUSIVE_L3=L3En` |
| `NrCores` 1…8 | **Live** in `config_pkg` / packages (default 1) |
| Snoop filter / inv bus / hub | **Live** under `corev_apu/coherence/` |
| SoC N-core wrapper | **`corev_apu/src/g6lc_cluster.sv`** (N×ariane + hub + L2/L3/PF) |
| L1 inv adapter | **`g6lc_l1_inv_adapter.sv`** + core `l1_inval_*` → **WT and HPDCACHE** |
| Testharness | **`ariane_testharness`** uses cluster + CLINT `NR_CORES=NrCores` |
| CLINT | Scaled to `NrCores` |
| PLIC | Multi-context 16 targets (8×M/S) |
| Tests | **`mc-stream-tests`** + **`mc-spo-soak`** (stream × Zacas/spo/CF narrow); `dual-hart-ci`, `stream8-smoke`, `ooo-l3-tests` |
| Zacas (AMOCAS) | **W/D/Q** — `RVZacas` on server_math / ooo_server / imafdc; hard golden `zacas-policy` + `mc-mini-veri`; suite under `verif/tests/custom/multicore/` |
| Spo/CF soak | **`mc-spo-soak`**: multi-round assemble + dual-target lint; CF×stream, CAS×stream, mispred×stream |

## Invalidation leaf repair (2026-09-16)

`g6lc_inval_bus.sv` now requires every target to have space or a retainable
matching tail before global acceptance. Admission and queue update share a
per-target merge predicate. A sole entry being consumed on this edge cannot
retain a new invalidation: enqueue the new command if space exists, otherwise
hold acceptance until a later cycle. No new state, clock, stage, port or config
field is added; this repairs the existing parameterized contract rather than
making broken behavior selectable.

The original N3/depth2 RTL passes a basic control but fails both independent
reproducers: mixed-target ready is incorrectly one, and coalesce-plus-pop loses
the newly accepted command. The repaired leaf passes N/depth 1/1, 2/1, 3/2, 4/3
and 4/4, each with directed, wrap and 600-cycle deterministic stimulus plus an
injected-ready-error control. The reference queues do not read DUT pointers.

Eight-step binary formal checks pass at N3/depth2 for admission, status/capacity
and preserving a new command after a sole-entry departure. Both scenario covers
are reached; original RTL and checker mutation fail. This is local bounded
safety/reachability, not an unbounded full-FIFO or coherence proof.

| Matched generic synthesis | Before cells | After cells | Sequential cells |
|---|---:|---:|---:|
| N1/depth1 identity | 0 | 0 | 0 / 0 |
| N3/depth2 | 1,900 | 1,860 | 372 / 372 |
| N4/depth4 | 6,528 | 6,623 | 988 / 988 |

No latches/check problems are reported. Sharing merge eligibility does not
uniformly reduce logic: N4/depth4 costs 95 extra generic cells. Consumer-ready
now participates in eligibility when a sole tail could depart; physical timing
of that combinational cone remains unmeasured. Reset/DFT state and array storage
are unchanged. Existing blocked/coalesce outputs describe actual admission;
no PMU selector, ISA, DTS, cacheability, RR or scheduler setting changes.

`run_inval_review.py` snapshots sources and uses the validated private Verilator
runtime; `REVIEW_INVAL_BASELINE=1` reproduces the original failures and
`REVIEW_INVAL_QUALITY=1` performs the local formal/paired-synthesis checks.
Artifacts: `review-inval-before-20260916`, `review-inval-after-20260916`,
`review-inval-quality-20260916`. The later `review-inval-clean-tb-20260916`
reruns all five geometries/negatives after test-only width/loop cleanup and has
no Verilator warnings. RTL hashes remain `a8a78d03…` → `2cafee7f…`.

**Integration remains open:** producers must retain/reserve blocked obligations;
the hub still does not gate accepted writes on invalidation capacity. Held AXI
owner/ID and inclusive-source acknowledgment/eviction issues are separate.
Stationary same-line tails still merge flags before delivery; this is not a new
AXI irrevocable-payload guarantee. The SMT2 package has one physical core and
uses the hub identity path, so this leaf change does not alter its tested path;
no fresh full SMT2 or multicore regression is claimed by these leaf checks.

Full platform `verify --lint --sim --synth` was inspected in dry-run only: its host
route selects local executables, which are not approved RTL evidence here, and
the immutable remote source snapshot lacks the build-platform CLI. All SKIPs
remain SKIPs despite the generic banner. Full source-bound remote verification
and broader cluster qualification remain open. Licensing configuration/headers
were reviewed manually using the recorded tier-R authorization; `diag run
licensing` remains unregistered, not an automated pass.

## Hub contract reproductions (2026-09-16)

`review-hub-before-20260916` uses the live hub, repaired invalidation leaf, snoop
filter and LR/SC tracker with N2, four shared OT slots, depth-two invalidation
queues, 64-bit AXI, broadcast policy, SF disabled and LR sideband tied off.
`tb_g6lc_coherence_hub.sv` reuses the existing L2 bench's exact AXI channel types.
No hub RTL change is made in this run.

| Contract | Recorded result |
|---|---|
| Basic read response owner/original ID/data | PASS; an injected observed-data error is caught |
| Held AR with a newly higher-priority requester | FAIL: memory-side payload changes before acceptance |
| Held AW with a newly higher-priority requester | FAIL: memory-side payload changes before acceptance |
| Held AR while an older R frees a lower OT slot | FAIL: memory-side ID changes while the address remains held |
| AW with one free OT slot and no competing AR | FAIL: unused AR preference denies the available write credit |
| Accepted write invalidation retention under a stalled consumer | FAIL: three writes accepted/completed, only two invalidations delivered |

Each scenario starts from reset and uses legal held source requests. The write
responder waits for both AW and W, holds B until handshake, releases invalidation
consumers at cycle 32 and checks delivery by cycle 128. This avoids requiring a
future correct design to accept a write while its target queue is full. It checks
accepted-write notification retention, not the complete memory visibility protocol.
All five failures remain open even though the runner's expected-outcome checks
match. `REVIEW_HUB_BASELINE=1` in `run_inval_review.py` reproduces them; this is
not a PASS-only regression or release qualification. Hub SHA `78ad3d66…`,
executable `2ae26616…`; source/runtime manifests are retained.

The build reports three pre-existing LR-line width warnings and six block-local
response-temporary latch warnings in the hub. Actual mapped latch presence has
not been measured for this hub run; no synthesis-clean claim is made.

**Next repair boundary:** retain the selected AR/AW owner and memory-side slot
while valid is stalled, and include pending reservations in shared-slot allocation.
Only reserve a distinct AW slot for an AR that actually competes. Before integration,
check simultaneous held channels, slot handoff/completion, original-ID restoration
and the N1 identity path. Invalidation retention is a separate obligation: the
current request and SF lookup are activated by `aw_fire`, so feeding current
`inv_ready` back into AW grant forms a feedback dependency. Define prospective
intent, commit/reservation and write-visibility handling before coding that path;
do not repair it with a ready-wire loop or claim a buffer alone proves coherence.

## Held address/ID reservation repair (2026-09-16)

The next retained hub candidate (`2b9af41a…`) fixes the first four hub failures.
When AR or AW is offered but stalled, it records that channel's owner and
memory-side slot. Reserved slots participate in free-slot exclusion; a held
transaction keeps its own credit even when all slots are occupied. A new AW
reserves a second slot only when a new AR actually competes, so a phantom read
no longer disables the sole write credit.

Only owner/slot/held metadata is captured, not full AXI packets. This relies on
the AXI source contract: a master must retain valid and payload until acceptance.
The formal harness states that assumption explicitly. Pending selections override
RR/starvation selection; starvation counters still age, but the force event is
suppressed while a held selection wins. No new PMU selector, configuration field,
queue depth, port, clock or pipeline stage is introduced. Existing async-low reset
clears the metadata; ordinary scan-visible flops need no new memory/clock-gate seam.
The free-slot exclusion and held-owner/slot muxes are new timing cones; no STA or
physical-power result is claimed.

`review-hub-reservations-20260916` passes 12 positive records across OT4 and OT1,
including simultaneous reservations, pool exhaustion, response backpressure,
original-ID restoration and reset while held. Both response-oracle negatives are
caught. `review-hub-hold-starve-20260916` repeats the matrix with 20-cycle held
request checks; the DUT source is unchanged. The accepted-write invalidation-loss case deliberately remains failed
(3 accepted/completed, 2 delivered), not a qualifying negative control.

`review-hub-reservation-quality-20260916` passes eight-step binary safety at
N2/OT4, N2/OT1 and N1 identity. It checks held AR/AW stability, routing at acceptance,
ID exclusion/bounds and real AW credit, under legal held master requests. The
original RTL and a forwarded-address checker mutation fail; both held-pair and
last-write-credit covers are reached. This is not unbounded transaction lifetime,
full response/ATOP ordering, complete coherence or full-SMT qualification.

| Matched generic hub synthesis (broadcast, SF off, inv depth 2) | Cells before / after | Sequential before / after |
|---|---:|---:|
| N1/OT1 | 0 / 0 | 0 / 0 |
| N2/OT1 | 470 / 2,351 | 28 / 293 |
| N2/OT4 | 2,760 / 2,808 | 326 / 342 |
| N4/OT4 | 5,981 / 6,238 | 607 / 625 |

The OT1 comparison is not equal capability: the old allocator made AW grant
impossible, allowing its write/invalidation logic to be pruned. The repair makes
that existing functionality usable. N2/OT4 adds eight logical hold-state bits,
but the realized netlist has 16 more sequential cells after changed constant
pruning; do not equate source register counts with total netlist deltas.

Paired synthesis reports no latches/check problems, including in the old netlist.
Defaulting the response-local temporaries removes six Verilator latch warnings;
it is not claimed to remove physical latches. Three pre-existing LR tracker width
warnings remain outside this repair. Core/IQ/predictor and named SMT2 configuration
remain unchanged, and N1 is still identity; no fresh full-core SMT2 run is claimed.

Reproduce with `REVIEW_HUB_RESERVATIONS=1` for simulations and
`REVIEW_HUB_QUALITY=1` for formal/synthesis in `run_inval_review.py`. The full
source-bound platform gate, producer invalidation reservation/retention, write
visibility, and inclusive-source qualification remain open. Do not wire current
`aw_fire`-activated invalidation ready into AW grant as a shortcut.

## Accepted-write invalidation loss — repaired

The hub generated a write's invalidation request **combinationally from
`aw_fire`** and presented it to the invalidation bus in the same cycle. If the
bus was not ready that cycle the request simply evaporated, so a write could be
accepted and completed with no invalidation ever delivered — reproduced as
`HUB_INV_LOSS`: three accepted, completed writes producing only two
invalidations. The source comment recorded this as deliberate ("inv path is
best-effort with coalesce under storms"), and the earlier attempt to gate AW on
`inv_ready` was correctly rejected because `inv_ready` is itself
`aw_fire`-dependent, so that closes a combinational loop.

**Repair: retain the obligation instead of gating on readiness.** A single
registered slot holds an accepted write's invalidation until the bus takes it. A
retained entry is presented in preference to a fresh one, and a fresh request the
bus accepts immediately still costs no extra cycle. Admission consults only the
**registered** occupancy plus the incoming `aw.cache[1]` attribute — never
`inv_ready` and never `aw_fire` — so a write that will need an invalidation is
refused while the slot is occupied and no loop is created. Because admission is
blocked while occupied, one slot is sufficient: the obligation cannot be
overwritten.

New state is one `coh_inval_t`, an `NC`-bit target mask and a valid bit. Evidence:
`review-hub-invretain-v1` records 15/15 across the outstanding-limit geometries
with the response-oracle negative control still firing, and scenario 5 — the
invalidation-loss reproducer — now passes.

**Still open:** the inclusive source's `inv_busy_o` remains unconsumed and the
eviction producer has no admission handshake, so a later victim can still be lost
while an earlier one waits. That is a separate producer-side contract from the
hub's write path repaired here.

## Inclusive-source acknowledgment repair (broad RTL review)

`g6lc_cluster` now masks inclusive ready when the hub wins that core's invalidation
mux. The source-derived seam test plus live `g6lc_l3_inclusive_inv` reproduces the
old loss: core0 acknowledged an unselected inclusive victim and never received it.
The candidate delivers it exactly once after hub traffic clears; N1/N3/N4 positive
and payload-error controls pass. The source-selection equation is formally checked.
N3 mux synthesis changes180→183 generic cells with no state. There is no new
clock, memory, configuration field or pipeline stage.

This fixes acknowledgment provenance, not eviction retention or complete inclusion.
`inv_busy_o` remains unconsumed, and the eviction producer still has no admission
handshake; a later victim can be lost while an earlier one waits. The hub's accepted-
write notification loss also remains open. Neither a passing mux test nor the
protected in-order core regressions waives those contracts.

Evidence: `review-rtl-audit-incl-before-v3`, `review-rtl-audit-after-v1`,
`review-rtl-audit-quality-tail-v7`, and the matched24-record
`review-rtl-audit-integrations-v1`. The component test extracts the actual cluster
mux/ready connection; it is not a complete L3-enabled cluster simulation.

## Contention optimisations
Snoop filter · inv coalesce · multi-master AXI RR + anti-starve · NC bypass · N=1 identity.

## Sanctioned seam
Cluster size at **SoC** (`corev_apu`); core stays single-hart-instance + `mhartid`.
Hub sits between core AXI masters and shared L2. DRAM is **below** L2/L3: `mem_req_o`
hits the testharness `master[DRAM]` slave (`g6lc_ai_dram_backend`). Multi-channel
stripe (`DramChannels`) is that slave's property, not a per-core port and not
`cva6_cfg_t`. Raising `NrCores` adds requesters, not guaranteed miss-fill concurrency:
the current L2 top remains serialized. It does **not** instantiate PHYs. Plan: [`../uncore/dram-channel-scaling.md`](../uncore/dram-channel-scaling.md).

## `.dts`
N× `cpu@`, PLIC contexts, CLINT extents, `next-level-cache = <&l2>`.
One `memory@` node even when `DramChannels>1` (hardware stripe, not N Linux banks).

## Invariants
RVWMO across harts · cluster-wide LR/SC+AMO (exclusive monitor **above** the channel
demux) · MMIO never cached · precise traps per hart · N=1 `IDENTITY_FAST` still sees
the same DRAM slave.
