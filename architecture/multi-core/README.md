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

## Cross-core LR/SC ownership — reviewed, sound (with one dead signal)

A review pass asked whether a remote store can leave a hart's LR reservation
valid, letting its SC succeed after another core wrote the line. Tracing it:

* the hart-local reservation in `hpdcache_uncached` is reset ONLY by that hart's
  own store stage (`uc_lrsc_snoop_o = st1_req_valid_q & st1_req_is_store`) or its
  own AMO/SC. The coherence invalidation path reaches the cache DIRECTORY
  (`cva6_hpdcache_subsystem` read-response inval) and never touches it.
* the hub's `g6lc_lr_sc_tracker` is wired with `sc_probe_i = 1'b0` and `sc_ok_o`
  unconnected, so it only produces kill hints, not SC decisions.
* `g6lc_l2_top` deliberately forwards `AxLOCK` downstream rather than answering a
  locked access from cache (see its LDEX/STEX note): the authoritative reservation
  is the downstream exclusive monitor.

So a stale-valid local reservation cannot grant an SC — it only lets the SC reach
memory, where the monitor that sees every core's writes adjudicates it. The local
buffer can fail an SC early; it can never succeed one alone. **No defect.** This is
recorded because the question recurs and the answer is not local to any one file.

Two notes that ARE actionable:

* `coh_sc_fail_o` is permanently zero. It is driven by the tracker's `sc_fail_o`,
  which can only assert when `sc_probe_i` is high — and that input is tied off.

  **Audited the whole set rather than just this one.** In the real `gen_cluster` path,
  `coh_inv_fire_o`, `coh_sf_hit_o`, `coh_sf_overapprox_o`, `coh_arb_starve_o`,
  `coh_split_conflict_o` and `coh_lr_kill_o` are all genuinely driven from live
  conditions. `coh_sc_fail_o` is the only member that cannot fire, so this is one dead
  signal, not a systemic observability gap.

  It could not be fixed by driving the probe: the hub does not adjudicate SC.
  `g6lc_l2_top` forwards AxLOCK downstream precisely because the authoritative
  reservation is the downstream exclusive monitor, so the hub never learns an SC
  outcome.

  **Re-pointed rather than retired.** The hub does observe one honest, related fact: an
  SC-shaped store arriving while it holds no matching reservation for the storing core.
  That is a store the downstream monitor is expected to refuse. `sc_fail_o` /
  `coh_sc_fail_o` are therefore replaced by `sc_noresv_o` / `coh_sc_noresv_o`, driven by

  ```systemverilog
  if (store_is_sc_i)
    sc_noresv_o = !(valid_q[store_core_i] && (line_q[store_core_i] == st_line));
  ```

  evaluated against the pre-store state. The naming is deliberate: this is "no
  reservation recorded here", **not** "the SC failed" — the hub is not entitled to the
  second claim, and a name that implied it would be the same over-reach as the dead
  signal it replaces. The probe port is kept but documented as unused.

  Renamed at all five live sites (tracker, hub port + identity tie-off + instantiation,
  cluster tie-off, `tb_g6lc_coherence_hub`, and both hub wrappers in
  `run_inval_review.py`). Verified: uncore lint clean at 4 warnings, unchanged, and the
  hub reservation suite passes **15/15**.
* the reservation is one entry per cache, so two SMT harts sharing a d-cache share
  one reservation. That costs progress (each hart's LR displaces the other's, so an
  SC fails and retries) but not correctness, for the same reason as above. It is the
  same shape as the AI-X1 defect, which mattered there because that monitor WAS
  authoritative.

## Snoop filter could hide a live sharer — repaired

The hub computes a write's invalidation targets as
`sf_present & ~(1 << writer)`, so the filter's safety property is that it may
over-report sharers but must never under-report one. Its header says exactly that
("over-approx on capacity miss ... so correctness is preserved").

It could under-report. A capacity conflict overwrote the entry and forgot the
displaced line's sharers, which is safe only while that line stays untracked (a
lookup then misses and falls back to "everyone"). The moment the line was
installed again from one core's fetch, the entry HIT and reported that core alone,
skipping every other core still holding it. `clear_valid_i` is tied off in the hub,
so nothing ever corrected the set afterwards.

Reproduced with an independent model of what each core holds, built from the
bench's own allocations: `SF_SHARER_LOST addr=4000 writer=1 must=01 targets=00
hit=1 over=0` — a confident hit with an empty target set, so the other core keeps a
stale line.

Repair: an entry installed over a DIFFERENT valid tag now starts with every core
marked present, because that index has already forgotten at least one line and the
incoming line may be among them. A still-invalid index has forgotten nothing since
reset, so it keeps the exact single-core set — checked by a precision scenario, so
the fix cannot degenerate into "always broadcast".
`review-sf-after-v3` passes 5 records; `review-sf-fault-v3` restores the original
install and reproduces the lost sharer.

**Reachability: live.** `g6lc64_stream8` (NrCores=2), `g6lc64_ooo_server` and
`g6lc64_server_math` all set `CohPolicy = COH_FILTERED` with `SnoopFilterEn = 1`,
so this gated real invalidations in the multi-core configurations.

**Cost, stated plainly:** an index that has ever thrashed now reports "everyone" for
whatever line sits there, degrading toward broadcast instead of answering wrongly.
The precise fix is directory-style back-invalidation on displacement — invalidate
the displaced entry's sharers so forgetting them is sound — which needs another
invalidation source in the hub (with its own retention, or the repaired
`HUB_INV_LOSS` defect returns). That is recorded as follow-up, not bundled here.

## External invalidations on HPDCACHE — RESOLVED: delivered, including to an idle observer

**Answered with a correct invocation and a non-vacuous verdict.** The missing piece was
never the RTL: it was `+tohost_addr`, which the proxy derives from the ELF via `nm` and
which my hand-rolled commands omitted, together with `+debug_disable`. With
`+time_out=400000 +debug_disable +quiet_axi +tohost_addr=0x80001000`:

| Test | Result | Reading |
|---|---|---|
| `mc_boot_sanity.S` | SUCCESS after **364** cycles, `rvfi_tracer ... terminated` | the invocation is valid at all |
| `mc_shared_line_coherence.S` (polling observer) | SUCCESS after **773** cycles, terminated | busy observer sees the remote write |
| `mc_shared_line_quiet.S` (idle observer) | SUCCESS after **240698** cycles, terminated | **idle observer also sees it** |

Every verdict ended EARLY, well inside the 400000-cycle bound, and each carries the
`rvfi_tracer ... Simulation terminated` marker — the same two conditions the proxy's own
suite classifier requires, so none of these is the vacuous SUCCESS-at-the-bound described
below.

The quiet run's cycle count is itself the internal check that the test did what it
claims: 240698 cycles matches hart 0's 60000-iteration register-only wait at roughly four
cycles per iteration. So the window in which hart 1 performed its remote write really was
a window in which hart 0 issued no load, store or fence — and hart 0 still read the new
value afterwards.

**Conclusion: HPDcache delivers external coherence invalidations, and delivery does not
depend on the observing hart generating its own memory traffic.** The source-level
concern that opened this section — that `mem_resp_read_inval_i` is only sampled while
`mem_resp_read_valid_i` is asserted — does not produce a lost invalidation in this
design. The mechanism by which the pulse survives is still not traced in the source, and
that remains a documented open question; but the behaviour is now established rather than
assumed, in both the busy and idle cases.

**The revert was correct.** `cva6_hpdcache_subsystem.sv` stays as upstream wrote it.

**Two residual caveats, stated rather than buried.**

1. *Mechanism untraced.* The behaviour is established; why the pulse survives the
   `mem_resp_read_valid_i` gate is not. Nothing should be edited on that path until it is.
2. *Residency is assumed, not measured.* The conclusion rests on hart 0's load having
   ALLOCATED the line. The test is built so that load must miss — hart 1 wrote the value,
   hart 0 never did — and read-allocate is the standard behaviour, but I have not verified
   it independently in this configuration. If the D-cache never held the line, both the
   polling and the idle test would pass vacuously and prove nothing about invalidation.

Work on closing caveat 2 is under way in `mc_shared_line_resident.S`, which makes its
coherence verdict conditional on demonstrated residency instead of assuming it. Two
measurement attempts and what they taught:

* **Single-load timing does not resolve it.** A `csrr mcycle` / `ld` / `csrr mcycle`
  window costs 16 cycles whether or not the line is resident — `csrr` is serialising and
  its fixed overhead swamps the difference. Measured: first load 16, reload 16.
* **Amortising over a loop gives a number but not yet a verdict.** 64 loads of the same
  line cost **791 cycles**, i.e. 12.4 cycles per load. The loop body is four instructions
  on an in-order core, so several of those cycles are loop overhead, leaving the per-load
  memory cost ambiguous between a hit and a miss.

**The baseline was added, and it settles the method rather than the question.** Running
the identical loop over 64 DISTINCT never-touched lines gives **779 cycles**, against
**793 cycles** for 64 loads of the same line. They are the same, and the guaranteed-miss
loop is if anything marginally cheaper.

So on this model a miss costs no more than a hit, and **timing cannot detect residency at
all**. That is not a tuning problem to be fixed with a better threshold — the instrument
has no resolution, which is exactly what a measured baseline is for. Had I picked a
constant instead, I would have "confirmed" residency or refuted it purely by choosing the
number.

**The architectural instrument was tried next, and it is broken.** `mhpmevent` legacy
index 2 is "L1 D-Cache misses" (`core/perf_counters.sv`). Programmed into
`mhpmcounter3` and read around both loops, it returns **0 misses across 64 guaranteed
misses** — the test refused to conclude and reported code 15, "counter not wired",
rather than mistaking a dead counter for a resident line.

A positive control settles whose fault that is. Reprogramming the same counter with
legacy index 5, "load accesses", and running the identical program gives **64 and 64** —
exactly `REPS` for each loop. So the CSR path, the event programming and the counter
reads are all correct, and the zero is a property of the event, not of the measurement.

Before calling that a defect I tested the obvious innocent explanation, because the
source supplies one: hpdcache computes `evt_cache_read_miss_o =
~st2_mshr_alloc_is_prefetch_i` (`hpdcache_ctrl_pe.sv`), i.e. **prefetch-driven
allocations are excluded from this event by design**. My baseline walked `BASE + i*64`,
a perfectly sequential stride — the ideal case for a stride prefetcher — so a healthy
counter could legitimately report zero.

Re-run with the walk order shuffled (step 37 lines mod 64: every line visited once, no
constant delta for a prefetcher to lock onto): **still 0 misses**. So the prefetch
exclusion does not explain it.

### ROOT CAUSE (supersedes the PMU "defect" below, and voids the coherence results above)

The PMU event is **not** broken. Every observation in this section has one cause, found
in `cva6_hpdcache_if_adapter.sv:94`:

```systemverilog
assign hpdcache_req_is_uncacheable =
    !config_pkg::is_inside_cacheable_regions(CVA6Cfg, load_paddr) ||
    config_pkg::is_inside_execute_regions(CVA6Cfg, load_paddr);
```

A load is marked uncacheable if it falls inside an **execute** region. On
`g6lc64_stream8` those regions are:

| Region | Range |
|---|---|
| ExecuteRegion[0] | `0x8000_0000 .. 0xC000_0000` |
| CachedRegion[0]  | `0x8000_0000 .. 0xC000_0000` |

They are **identical**. The execute region covers the whole cacheable region, so
**every load from DRAM is uncacheable and the L1 D-cache holds no DRAM data at all.**

That single fact explains the entire chain, which is what makes it convincing rather
than merely plausible:

* the D-cache miss event reads 0 because nothing allocates an MSHR — the event is
  healthy, and my "dead PMU event" finding is **withdrawn**;
* same-line and distinct-line loops cost the same (793 vs 779) because every load goes
  to memory either way — hence timing had no resolution;
* D-cache *accesses* still count 64, because requests do reach the cache; they simply
  bypass it.

**Consequence: the coherence results in this section are vacuous.** Hart 0 never held
the line, so "the idle observer saw the remote write" shows only that it read memory. It
says nothing about invalidation delivery, busy or idle. The residency caveat I flagged
turned out to be the whole story.

**Scope: every HPDCACHE configuration in the repo.** `is_inside_execute_regions` is a
plain range check over the ExecuteRegion rules, and `g6lc64_stream8`, `g6lc64_ooo_server`
and `g6lc64_server_math` all declare the identical pair — ExecuteRegion[0] =
`0x8000_0000 +0x4000_0000`, CachedRegion[0] = `0x8000_0000 +0x4000_0000`. So on all three,
the L1 D-cache read-allocates nothing from DRAM. Note the asymmetry: the store/AMO path
(same file, later branch) applies only the cacheable check, without the execute
exclusion, so it is specifically load allocation that is disabled.

**This is a serious performance finding in its own right,** and it is a design decision
rather than something to patch unilaterally. The exclusion was added deliberately to fix
a real I$/D$ aliasing case — the comment cites a jtab line the I-cache already holds, and
names the tests it repaired (`2jr_fencei`, `2jr_pad`, `2jr_data`). Simply deleting it
would very likely reintroduce that defect, which is why I have not touched it.

### Attempting the source fix: what the aliasing is NOT

Asked to fix the aliasing at source, I went looking for the mechanism, because the
comment records a symptom ("HPD HIT of a jtab line I$ already holds") and not a cause.
A hit alone cannot hang a cache; something has to be misrouted or lost.

The strongest candidate was **response-ID aliasing**, which would have been the same
defect class as the Ara/core AXI mux repaired earlier in this review. The arbiter's
read-response demux routes purely by id:

```systemverilog
mem_resp_read_rt[i] = (i == int'(icache_miss_id_i)) ? 0 : 1;
```

so any D$ read carrying `ICACHE_RDTXID` has its refill delivered to the instruction
cache, and the load never completes. `ICACHE_RDTXID` is `{1'b1, 0...}`, the MSB of
`MEM_TID_WIDTH`, while D$ miss ids are `{mshr_alloc_way, mshr_set}`.

**Ruled out for the shipped configurations.** The id spaces are partitioned by
construction and the bound is explicit: `MEM_TID_WIDTH >= clog2(mshrSets*mshrWays) + 1`,
where the `+1` reserves the MSB for the I$. `g6lc64_stream8` has NrLoadBufEntries=8 →
8 D$ ids → needs 4, supplies 4. `g6lc64_ooo_server` has 24 → needs 6, supplies 8. No
collision. So this is not the 2jr mechanism, and **the aliasing hazard behind the
execute-region exclusion remains unidentified** — I will not change a load path on a
guess.

### What the investigation did fix

That bound was checked only inside `pragma translate_off`. A configuration violating it
would **synthesize** and only complain in simulation — while producing exactly the silent
hang described above: a D$ refill delivered to the I$, no error anywhere. It is now a
generate-scope `$error`, the same treatment given to the OoO hart/FP legality guards.

Verified both ways rather than assumed: with `MEM_TID_WIDTH` temporarily narrowed to 5 on
`g6lc64_ooo_server` (which needs 6), the gate reports *"remote refused: 1 elaboration
guard(s) fired — unsound configuration"*; restored, it passes at 4 warnings.

Worth noting the margin is **zero, not comfortable**: stream8 needs 4 and supplies 4, so
raising `NrLoadBufEntries` to 16 would have aliased silently before this guard existed.

### RESOLVED — the "aliasing hazard" was a false assertion, and the exclusion is gone

**The 2jr hang is not a cache hazard.** It is a bind-attached frontend checker observing
the wrong signal:

```systemverilog
frontend.sv:166   logic replay, replay_q;
frontend.sv:175     replay_q <= replay && !arch_valid;                     // registered
frontend.sv:820   assign kill_s1 = kill_s1(is_mispredict, flush_i, replay_q);
g6lc_fetch_dbg.sv bind: .kill_s1_i(kill_s1), .replay_i(replay)             // combinational
```

`kill_s1` is built from `replay_q`, while the checker was handed the combinational
`replay`. One cycle after `replay` drops, `replay_q` still holds `kill_s1` high and
`replay_i` reads 0, so a perfectly legal replay-kill trips
*"kill_s1 outside misp|flush|replay"* and the simulation aborts. Fixed by binding
`.replay_i(replay_q)` — the same term the driver uses.

**Three-arm evidence** on `g6lc64_stream8`, flavour B, arms differing only as stated:

| Test | exclusion ON | exclusion OFF, checker as-was | exclusion OFF, checker fixed |
|---|---|---|---|
| `mc_boot_sanity` | SUCCESS 359 cy | SUCCESS 359 cy | SUCCESS 359 cy |
| `mini_hpd_2jr` | SUCCESS 534 cy | **assertion** | **SUCCESS 545 cy** |
| `mini_hpd_2jr_pad` | SUCCESS 491 cy | **assertion** | **SUCCESS 497 cy** |
| `mini_hpd_2jr_data` | SUCCESS 501 cy | **assertion** | **SUCCESS 519 cy** |

`mc_boot_sanity` passing identically in all three arms is the control: the arms are
otherwise equivalent, so the middle column isolates the exclusion and the right column
isolates the checker fix.

**Consequence: the execute-region term is removed** from
`cva6_hpdcache_if_adapter.sv`, restoring L1 D$ load allocation for DRAM on every
HPDCACHE configuration — it had been disabled wholesale to avoid a checker bug.
`G6LC_DCACHE_EXEC_UNCACHED` restores the old behaviour for bisection.

Breadth check on the default build (exclusion removed, checker fixed): the whole
`mini_hpd_*` family plus the sanity tests, **22 pass / 0 fail**, each requiring both a
SUCCESS and the `rvfi_tracer ... terminated` marker. Default-target lint unchanged at
8 / 54 warnings.

**Still owed before release:** a full regression, not 22 directed tests — this changes
the D-cache's allocation behaviour on every HPDCACHE configuration.

## P0 — CROSS-CORE COHERENCE IS BROKEN, AND THE D$ EXCLUSION WAS MASKING IT

**This vindicates the original HPDCACHE invalidation concern that I twice withdrew.** It
was withdrawn as "vacuous" because the L1 D-cache held no DRAM data — and that was true.
The moment D$ load allocation is restored, the defect appears.

`mc_hart1_store_visible.S` separates the property from the reporting channel: hart 1 stores
a cookie to a shared cache line, and **hart 0** — whose `tohost` writes are known to work —
loads that line and reports what it saw. Code 1 means observed, code 9 means never
observed.

**One-variable control.** Both arms are flavour B from the same source, differing only by
`G6LC_DCACHE_EXEC_UNCACHED`:

| Arm | D$ load allocation for DRAM | Result |
|---|---|---|
| `work-ver-s8-b-uncached` (exclusion present) | OFF | **SUCCESS, 6449 cycles** — hart 0 observed the store |
| `work-ver-s8-b-retired` (exclusion removed) | ON | **code 9, 320416 cycles** — hart 0 never observed it |
| production `work-ver-stream8` (exclusion present) | OFF | SUCCESS, 8448 cycles |

With the D-cache actually caching DRAM, **hart 0 polls a stale zero forever**: hart 1's
store never invalidates hart 0's copy. Cross-core coherence does not work on this
configuration.

**Consequence for the execute-region decision, which now reverses.** Removing that
exclusion is still correct for performance and the 2jr checker fix still stands — but the
exclusion was *also* acting as an unintended correctness crutch: by keeping every DRAM load
uncached it made stale copies impossible, hiding the coherence defect. So the ordering
matters:

1. **fix cross-core invalidation delivery**, then
2. remove the exclusion and keep the performance.

Shipping step 2 without step 1 converts a performance problem into a correctness one. The
`G6LC_DCACHE_EXEC_UNCACHED` define exists precisely so the safe behaviour can be restored
while step 1 is in progress.

### MECHANISM — traced end to end, and the original analysis was right

The chain is intact until the last hop, and every link was checked rather than assumed:

1. **hub generates it.** `POLICY=COH_FILTERED` + `SnoopFilterEn=1`, targets computed as
   `sf_present & ~(1 << aw_winner)`; the snoop filter allocates on `aw_fire | ar_fire`
   (`g6lc_coherence_hub.sv:509`), so core 0's polling load registers it as a sharer.
2. **cluster delivers it** through `g6lc_inval_bus` → `g6lc_l1_inv_adapter` →
   `l1_inval_valid_i`.
3. **`cva6.sv` forwards it** to the HPDCACHE subsystem (`cva6.sv:2127-2129`). Note the std
   branch instead ties `inval_ready = 1'b1` and drops it, which is the distinction the
   corrected comment now records.
4. **the subsystem forwards it** — AXI branch:
   `dcache_resp_read_inval = ext_inval_valid = inval_valid_i`, with
   `inval_ready_o = 1'b1`.
5. **hpdcache drops it.** This is the defect:

```systemverilog
// hpdcache.sv:1132
always_comb begin : mem_resp_read_demux_comb
    mem_resp_read_miss_valid = 1'b0;
    if (mem_resp_read_valid_i) begin          // <-- the gate
        ...
        mem_resp_read_miss_valid = 1'b1;      // only ever set inside it
    end
end
assign mem_resp_read_miss_inval = mem_resp_read_inval_i;   // payload, but nothing consumes it
```

`mem_resp_read_miss_valid` is the signal that makes the miss handler act on the response
**and on its invalidation payload**, and it is asserted *only while a read response is
concurrently valid*. The invalidation nline is wired through combinationally, but nothing
consumes it on its own.

So an external coherence invalidation that arrives while no D$ read response happens to be
in flight is **acknowledged and silently discarded** — and `inval_ready_o = 1'b1` is the
lie that makes it silent: the subsystem asserts unconditional acceptance for a path that
only lands by coincidence. An idle observer, which is precisely the failing case in the
control above, never has a read response in flight.

### FIX APPLIED AND VERIFIED

`cva6_hpdcache_subsystem.sv`, AXI branch only (the L15 branch already receives
invalidations natively in its response stream). A one-entry retention holds the external
invalidation until HPDCACHE actually consumes it, and `inval_ready_o` now reports real
occupancy instead of unconditional acceptance:

```systemverilog
assign inv_inject             = ext_inv_pend_q & ~axi_rresp_valid;  // real response wins
assign dcache_read_resp_valid = axi_rresp_valid | inv_inject;
assign dcache_resp_read_inval = inv_inject;
assign axi_rresp_ready        = dcache_read_resp_ready & ~inv_inject;
assign inval_ready_o          = ~ext_inv_pend_q;                    // honest backpressure
```

Two design points that the source settled rather than intuition:

* **Injecting a response cycle is sanctioned, not a hack.** An invalidation-only response
  is a first-class case in `hpdcache_miss_handler.sv` — it is how the OpenPiton/L15 port
  delivers invalidations at all. The metadata FIFO is written on `mem_resp_inval_i`
  regardless of `r_last`, the data FIFO is explicitly *not* written (`& ~mem_resp_inval_i`),
  `mem_resp_ready_o` derives from metadata space alone, and `REFILL_IDLE` routes `is_inval`
  to `REFILL_INVAL` without touching the MSHR (`mshr_ack = ~is_inval`). The injected cycle
  therefore needs no data, no `r_last` and no MSHR entry.
* **An invalidation must own its cycle.** Because `is_inval` diverts the FSM to
  `REFILL_INVAL` *instead of* refilling, piggybacking an invalidation onto a real response
  would drop that refill. Hence `inv_inject` is qualified with `~axi_rresp_valid`.
* One entry suffices **because** the producer is now back-pressured rather than lied to;
  the inval bus holds the request instead of losing it.

**Verified against the criterion committed to before the fix was written:**

| Arm | `mc_hart1_store_visible.S` |
|---|---|
| exclusion removed, unfixed | code 9 at 320416 cycles (never observed) |
| **exclusion removed + retention fix** | **SUCCESS at 6471 cycles (observed)** |
| exclusion present (`uncached` control) | SUCCESS at 6449 cycles |

The fixed cached arm now matches the uncached arm's latency almost exactly (6471 vs 6449),
which is the expected signature of an invalidation that lands promptly. Breadth on the
fixed build: `mini_hpd_*` plus the sanity tests, **22 pass / 0 fail**, each requiring both a
SUCCESS and the `rvfi_tracer ... terminated` marker. Default-target lint unchanged at
8 / 54 warnings.

**This also unblocks the execute-region removal**, whose ordering constraint was step 1
then step 2: invalidation delivery is now fixed, so keeping the D$ allocation restored is
no longer trading performance for correctness. `G6LC_DCACHE_EXEC_UNCACHED` remains for
bisection.

### Back-pressure: measured, with its limit stated

`mc_two_inval_backpressure.S` closes the gap I flagged above. Hart 0 caches **two** lines
(different sets, so no eviction or conflict refill can refresh either), then waits in a
register-only loop — no load, store or fence, so there is no read response for an
invalidation to ride on. Hart 1 then writes both lines back-to-back with no fence between
them, so two invalidations target one idle core as close together as the pipeline issues
them. The failure codes are deliberately distinct — 9 for a stale A, 11 for a stale B —
because a single "it failed" verdict could not distinguish a dropped *second* invalidation
from a broken first one.

| Arm | Result |
|---|---|
| **exclusion removed + retention fix** | **SUCCESS (both observed), 60569 cycles** |
| exclusion removed, unfixed | code 9 — A stale — 60561 cycles |
| exclusion present (`uncached` control) | SUCCESS, 60519 cycles |

Both invalidations are delivered on the fixed build, so nothing is lost across a
second arrival. Note the unfixed arm fails with **9, not 11**: its *first* invalidation is
already dropped, so that arm never reaches the back-pressure case at all — which is worth
saying rather than presenting it as a graded comparison.

### Instrumented, and the answer is not the flattering one

I said the end-to-end pass could not distinguish a retention that fills and drains
correctly from one that never fills, so I instrumented it rather than leaving the claim as
an argument. `cva6_hpdcache_subsystem.sv` now counts, under `translate_off`, invalidations
actually delivered on a stolen response cycle (`injected`) and cycles where the producer was
held off because the slot was full (`backpressured`), reported in a `final` block.

| Test | Verdict | Counters (per core) |
|---|---|---|
| store-visible | SUCCESS 6471 cy | `injected=1`, `backpressured=0` |
| two invalidations, idle observer | SUCCESS 60569 cy | `injected=2` / `injected=4`, `backpressured=0` |
| **miss-streaming observer, 4 writes** (`mc_inval_bp_stress.S`) | SUCCESS 37573 cy | `injected=4` / `injected=6`, `backpressured=0` |

Two things follow, and only one of them is good news:

* **The injection path is genuinely exercised.** `injected` is non-zero on both cores in
  every run, so invalidations really are delivered by the stolen response cycle. That is
  direct evidence for the fix's *mechanism*, not merely its outcome — which is what the
  passing verdicts alone could not give.
* **`backpressured` is 0 in every test, including the stress one.** The slot never filled,
  so **the one-entry depth's overflow path remains unproven.** I could not provoke it from
  software even with an observer streaming misses (to keep the response channel busy and
  defer injection) and four writes issued back-to-back.

The likely reason is upstream buffering: `g6lc_inval_bus` already holds `INVAL_DEPTH`
entries per core (`COH_DEFAULT_INVAL_DEPTH = 4`, `g6lc_coherence_pkg.sv:12`), so the
retention sees a drip rather than a burst, and injection finds a free response cycle before
the next invalidation arrives.

### Overflow path now qualified by a unit bench

The retention was inline logic, which is *why* only a full-core test could reach it. It is
now `core/cache_subsystem/g6lc_inval_retain.sv` — a named unit with an explicit contract
and its own assertions — instantiated by the subsystem at `DEPTH=1`. The extraction is
behaviour-identical: the three full-core tests return the **same** cycle counts
(6471 / 60569 / 37573) and the same counters as the inline version.

`verif/tb/uncore/tb_g6lc_inval_retain.sv` drives the producer and the response channel
directly, so the slot can be held full for as long as needed. Contract checked:
conservation (every accepted invalidation emitted exactly once, in order), honest
backpressure, and *a real response always wins the channel* — asserted because
piggybacking would divert the consumer's FSM to `REFILL_INVAL` and drop a refill.

| DEPTH | Scenarios | Negative control | Back-pressure cycles in scenario 0 |
|---|---|---|---|
| **1 (as shipped)** | 3 / 3 pass | caught | **11** |
| 2 | 3 / 3 pass | caught | 10 |
| 4 | 3 / 3 pass | caught | 8 |

`backpressured` is non-zero at every depth, so **the overflow path is finally exercised —
including at `DEPTH=1`, the depth that actually ships** — with nothing lost and order
preserved. Scenario 1 confirms injection never occurs while the channel is busy
(`emitted=0`), and scenario 2 drains under toggling consumer readiness without loss.

**Wired into a review runner**, `verif/regress/remote/run_retain_review.py`, because a
check that exists only in a shell history is a check that silently stops running. It hashes
its inputs, records the Verilator version, sweeps DEPTH 1/2/4 × scenarios 0/1/2, runs the
negative control at every depth, and refuses a scenario-0 run that reports
`backpressured=0` — a verdict without back-pressure has not tested the overflow path
whatever it says.

It also carries an RTL fault arm, `REVIEW_RETAIN_FAULT=1`, which restores the **original
defect** (`inval_ready_o = 1'b1` — unconditional acceptance with no room). Evidence:

| Arm | Records | Fault detected at (depth, scenario) | Runs without back-pressure |
|---|---|---|---|
| clean | 12 / 12 matched | none (correct) | 0 |
| fault | 12 / 12 matched | (1,0) (1,2) (2,0) (2,1) (2,2) (4,0) (4,1) | 0 |

The faulted source hashes differently (`b4720bf2…` vs `83d99bdd…`) so the two arms are
attributable. With the fault present the bench reports `RETAIN_LOSS accepted=12 emitted=0`
at DEPTH=1 — every invalidation accepted and none delivered, which is exactly the P0 this
unit exists to prevent.

Two things worth recording about the bench itself:

* `DEPTH` is overridable (`-GDEPTH=N`) specifically so the shipped depth is qualified
  rather than a friendlier one. It started as a `localparam`, which would have tested only
  `DEPTH=2`.
* The **negative control was initially inert at `DEPTH=1`**: it perturbed the *second*
  accepted entry, and at depth 1 only one is ever accepted (measured `negative_caught=0`
  at `DEPTH=1` versus `1` at 2 and 4). It now perturbs the first. That is the failure mode
  this review keeps meeting — a control that cannot fail where it matters most — and it was
  only visible because the depths were swept rather than assumed.

And three about the runner, all the same mistake in different clothing — an over-narrow
criterion that made *correct* behaviour look like a failure:

* it required **every** scenario to detect the injected fault, but scenario 1 only checks
  that nothing is injected while the channel is busy, which unconditional readiness does
  not disturb. A fault control should assert that the *suite* catches the defect, not that
  every case does;
* it looked only for the bench's `RETAIN_ERRORS`, while at `DEPTH>1` the fault overruns the
  occupancy bound so the *unit's own* assertion fires first — a detection, counted as a
  miss;
* it labelled the negative control's intentional errors as `faultDetected`, which made the
  clean arm's `results.json` read as though faults had been found in good RTL. `reported`
  and `detected` are now distinct.

Finally, the runner resolves its inputs from the repo when no copies are staged, so it runs
standalone on the builder over plain ssh. It previously required the `remote py` wrapper,
which blocks the local CLI for the whole run and needs a round trip per arm; both arms now
complete in a single invocation in about 15 seconds.

### Re-qualification: the original tests now pass, and the counters prove the mechanism

With D$ allocation restored *and* invalidation delivery fixed, the three tests that this
whole investigation started from were re-run. All pass — and the per-core `injected`
counter separates the two delivery paths for the first time:

| Test | Verdict | `injected` |
|---|---|---|
| `mc_shared_line_coherence` (polling observer) | SUCCESS, 25661 cycles | **0** |
| `mc_shared_line_quiet` (idle observer) | SUCCESS, 25422 cycles | **4** |
| `mc_shared_line_resident` | SUCCESS, 25156 cycles | **3** |

This is the quantitative confirmation the earlier arguments lacked:

* the **polling** observer needs **no injections at all** — its own refill traffic supplies
  the read responses the invalidations ride on. That is exactly the "rescue" mechanism
  hypothesised far earlier in this document, when the FLAG-loop argument was retracted for
  being consistent with both a working and a broken design;
* the **idle** observer needs **4** — it has no read responses in flight, so every
  invalidation it receives came through the retention/injection path. Remove that path and
  this test is the one that fails, which is precisely what the one-variable control showed;
* `mc_shared_line_resident` passing means its **residency gate now passes**, so residency is
  finally *measured* rather than assumed. That gate was written long ago and could never
  pass, because at the time the D-cache held no DRAM data at all — the same root cause.

Three things that were each asserted, retracted, or left open across this document —
invalidation delivery to an idle observer, the polling observer's self-rescue, and line
residency — are now settled by one consistent set of measurements.

### Regression status for this change

| Stage | Result |
|---|---|
| lint, `g6lc64_stream8` / `ooo_server` / `server_math` | **pass** — 7 / 4 / 7 warnings |
| synth of `g6lc_inval_retain` (yosys-slang → generic gates) | **pass** — 8 cells (2 `$_DFFE_PN0P_`, 2 ANDNOT, 2 AND, NOT, OR), **no latch cells**, `check -assert` 0 problems |
| full-core sim, `mini_hpd_*` + sanity | **21 / 21** |
| full-core sim, the three cross-core tests | all pass |
| unit bench, both arms | **12 / 12** each |
| synth of the whole cluster (`g6lc64_ooo_server`) | **killed — exit 137 (SIGKILL) after ~16.5 min** |

The cluster synth failure is **pre-existing, not this change** — but my first explanation
of it was wrong, and correcting it matters more than quietly fixing it. I called it an OOM
on a 30 GiB host; the builder actually has **12 cores and 125 GiB** (116 free), and the
failures are **deadlines**: cut at 900 s, then exit 137 at ~994 s, then exit 255 at 2412 s
against a 2400 s budget. The route is slow, not crashing.

Three changes came out of that:

* **measurement**, so the next failure is attributable: each target's yosys now runs under
  `/usr/bin/time` and its peak RSS and elapsed time ride out on the `RESULT` line. A run
  that dies otherwise leaves nothing to distinguish an OOM from a deadline — precisely how
  the first diagnosis went wrong;
* **parallelism, with an honest limit**: per-target runners launch through
  `xargs -P $(nproc)`, so a *multi-target* sweep now saturates the builder instead of
  costing N × one target. A *single* cluster target cannot saturate 12 cores, because yosys
  is single-threaded — splitting the cluster into independently synthesised submodules is
  what would, and that is the real answer if per-change cost matters;
* the budget floor raised to 5400 s so the route can complete at least once.

`g6lc64_stream8` synth passes clean in ~178 s (36 warnings), so the fast path is healthy.

One bug in my own change is worth recording: the per-target runners are written with a
*quoted* heredoc so the yosys command text survives verbatim — but the child `bash` then
inherits the environment and **not** plain shell variables, so they ran with an empty
`$RUNROOT`/`$YS` and emitted no `RESULT` line. The gate reported *"no RESULT lines … check
the proxy credentials"*, which is a misleading way to spell "the script I generated was
broken". Fixed by exporting them.

**The synth stage did catch a real defect of mine, though, and it is worth recording why
lint did not.** I had declared `axi_rresp_valid/ready` and `axi_rresp` *after* the arbiter
instantiation that consumes them. Verilator tolerates that use-before-declaration; yosys-
slang correctly rejects it:

```
cva6_hpdcache_subsystem.sv:510: error: identifier 'axi_rresp_ready' used before its declaration
```

So a Verilator-clean build is not evidence of SystemVerilog conformance, and the synth
stage is not redundant with lint even when both "just elaborate". The declarations now sit
at the top of the AXI branch.

**Still owed:** the whole-cluster synth route needs to complete somewhere before any
area/timing claim, and a secondary core that runs and *then* hangs is still not caught by
the verdict (see below).

## CORE 1 EXECUTES; ITS COMMITTED STORE NEVER REACHES POLLED MEMORY

**Resolved by the test above.** Hart 1's store *is* globally visible when caching is off
(the `uncached` arm passes in 6449 cycles), so the "committed store never reaches polled
memory" observation was an artifact of the testbench polling the DRAM array while the write
sat in a write-back L2 — a harness limitation, not a lost write. `tohost` from hart 1 is
simply not a reliable reporting channel; use hart 0 to report, as that test does.

**Retraction first.** The section below concluded "the second core never executes a single
instruction". That is **wrong**, and it was wrong for the same reason as three earlier
mistakes in this document: I read a silent verdict as evidence about the DUT without an
instrument that could see the DUT. The instrument existed, was broken, and I had skipped
repairing it.

`CVA6_MC_PC_PROBE` prints `c1.npc` but would not compile: its hierarchy paths were stale
(`i_cva6_icache`, now `i_g6lc_icache` — the g6lc icache replaced the CVA6 one). Five
renames and it builds. With it:

```
c1.npc: 0x10000 -> 0x10014 -> 0x8000001c -> 0x8000002c
```

**Core 1 is elaborated (102 generated files reference `gen_core__BRA__1`), fetches the
bootrom, jumps to DRAM, and executes the test.** Disassembly pins what those addresses
mean in `mc_hart1_alive.S`:

| Address | Instruction |
|---|---|
| `0x80000024` | `sw a0,0(t0)` — the store to `tohost` |
| `0x80000028` | `fence rw,rw` |
| `0x8000002c` | the park loop, **after** both |

Core 1 sits at `0x8000002c`, so **it executed and retired the store**. The probe's final
sample also shows `l2a=0x80001000` — the store's address presented at the L2. So the write
propagates at least to the L2 and still never appears in the memory the testbench polls
for `tohost`.

**The real question is therefore: why is a committed store from core 1 not visible in
polled DRAM, when the identical store from core 0 is?** The testbench reads the DRAM array
directly, so a write parked dirty in a cache — or lost in the hub's write path — is
invisible to it. Both are in scope for this review, and the hub is the only structural
difference between the two cores' write paths.

This does not rehabilitate the earlier coherence results: they remain withdrawn for the
D$-allocation reason, and any two-hart handshake through memory is unsafe to interpret
while core 1's stores do not land.

### Why this went unnoticed for so long — observability gap, now closed for visibility

```systemverilog
g6lc_cluster.sv:221   assign rvfi_probes_o = core_rvfi[0];
```

**The cluster forwards only core 0's RVFI probes.** Every trace-based check — including the
suite classifier's `rvfi_tracer ... Simulation terminated` marker, which this review has
been treating as the gold standard for "the run really finished" — was blind to core 1 by
construction. A multi-core cluster with a single-core trace interface cannot report a
secondary-core problem at all, which is exactly the observability failure `AGENTS.md`
§0.1(6) exists to prevent.

**Closed TB-side, deliberately not by widening the port.** `rvfi_probes_o` is a scalar
consumed by `ariane.sv`, the Xilinx and Altera tops, `ariane_gate_tb` and the APU benches,
and a missing pin is an error here (`%Error-PINMISSING`), so widening it to an array would
force a change at every instantiation. Instead `ariane_testharness.sv` now instantiates a
`cva6_rvfi` + `rvfi_tracer` per secondary core, fed by tapping the cluster's per-core probe
array hierarchically — no RTL interface change at all.

Two design points:

* **These tracers observe; they never terminate.** Core 0's `tracer_exit` drives `rvfi_exit`
  and therefore simulation termination, so a secondary core reaching its own halt must not
  end the run. `end_of_test_o` is left open on the secondary instances.
* `HART_ID` is `c * NrHarts`, matching the cluster's `mhartid` derivation, so trace files
  line up with architectural hart numbering rather than core index.

Verified: on the store-visibility test, `trace_rvfi_hart_00.dasm` has 6084 instructions and
**`trace_rvfi_hart_01.dasm` now has 8072** — core 1's stream is visible for the first time.
The verdict is unchanged (SUCCESS at 6471 cycles) and exactly **one** `Simulation
terminated` marker is emitted, so the classifier's contract is intact.

### The VERDICT is now multi-core aware too

Visibility alone still let a run pass while a secondary core did nothing, so the pass
criterion was extended rather than left as an owner decision: **every instantiated core
must retire at least one instruction by the time core 0 declares the test over.** A
violation forces exit code **127** through `exit_o`, which is the channel the C++ side
already turns into the run's verdict.

That is deliberately the weakest useful criterion. A secondary core parked in an idle loop
is indistinguishable from a hung one without test-specific knowledge, so demanding
*progress* at the end would fail legitimate tests; demanding "it ran at all" cannot. It is
safe on every configuration here because the bootrom sends all harts to DRAM_BASE with no
parking, so even a single-hart test executes the `mhartid` check on each core before
branching — and with `NR_CORES == 1` the check is vacuous.

**Verified in both directions**, because a verdict never observed to fail is
indistinguishable from one that cannot fail:

| Run | Result |
|---|---|
| normal | `SUCCESS`, `[mc_verdict] all 2 core(s) retired instructions` |
| `+mc_verdict_fault` (secondaries forced to appear silent) | **`FAILED (tohost = 127)`**, `retired_mask=01` |
| breadth: `mini_hpd_*` + sanity | **21 / 21 pass**, each also requiring the mc_verdict line |
| the three cross-core tests | all `SUCCESS` |

Three details that cost a cycle each and are worth recording:

* `rvfi_instr[N-1:0].valid` is illegal — a range is not allowed on the instance part of a
  dotted reference, so the retire reduction is an explicit loop.
* the plusarg had to be **allowlisted** in `g6lc_tb.cpp`. An unlisted plusarg is handed to
  HTIF, rejected, and the run dies — which looks exactly like the control "working" while
  the verdict was never exercised at all.
* the diagnosis had to move to a `final` block: the C++ side leaves its loop the moment
  `exit_o[0]` is set, so a `$display` issued in that same cycle never reached the log. The
  first version exited 127 with **no reason printed** — a verdict without a diagnosis,
  which is the complaint this review levels at everything else.

What is still *not* covered: a secondary core that runs and then hangs while core 0
finishes. Catching that needs either a per-core liveness window or test-declared
expectations, and both risk failing legitimate idle parks — so it is left open rather than
guessed at.

### Superseded — "the second core never executes" (WRONG, kept as the record)

This is the finding that subsumes the rest of this document, and it was found by asking
the simplest possible question directly instead of inferring it from a shared-line test.

`mc_hart1_alive.S` inverts the roles of every other test here: **hart 0 parks in a plain
branch loop and only hart 1 writes `tohost`**, so a SUCCESS cannot be manufactured by
hart 0. `mc_hart1_trap.S` goes further — hart 1's *first* instruction is a deliberate
`unimp`, so even a hart that fetches one instruction and faults would publish
`32+((mcause<<1)|1)` through the trap handler.

| Probe | `work-ver-s8-b-retired` (current) | `work-ver-stream8` (production) |
|---|---|---|
| hart 1 writes `tohost` (`wfi` park) | watchdog `2147483647` | watchdog `2147483647` |
| hart 1 writes `tohost` (plain-loop park) | watchdog `2147483647` | watchdog `2147483647` |
| hart 1 faults on its first instruction | watchdog `2147483647` | watchdog `2147483647` |

**Hart 1 does not execute a single instruction on either build.** The trap variant rules
out any store-visibility explanation: a hart that fetched even one instruction would have
written the handler's value. `wfi` is ruled out too — the plain-loop park behaves
identically.

Consequences, stated plainly because they are unwelcome:

* **Every two-hart test in `verif/tests/custom/multicore/` has been passing on hart 0
  alone.** That includes the polling and idle-observer coherence results recorded earlier
  in this file. They were already withdrawn as vacuous for the D$-allocation reason; this
  is a second, independent reason they prove nothing about coherence.
* The earlier 773-cycle "polling observer" pass is explained: in that version hart 0 wrote
  the seed itself, so it could complete without hart 1 ever running.
* No cross-core invalidation, snoop-filter or LR/SC claim can be supported by full-core
  simulation on this configuration until the second core boots.

What is ruled out as the cause:

* **the bootrom** — it deliberately sends *all* harts to DRAM_BASE with no parking, and
  the comment records that parking `mhartid!=0` was removed precisely because it "made
  dual-active bare-metal impossible". The generated `bootrom.sv` is newer than
  `bootrom.S` and its commit message is "Sync the generated bootrom with its source";
* **`BOOT_HOLD` clock gating** — it is `(NC > 1) && (NrHarts > 1)`, and stream8 is
  NrCores=2 / NrHarts=1, so `core_clk[1]` is ungated `clk_i`;
* **boot address** — `PerCoreBoot` is only set under `G6LC_APU`, so both cores take
  `boot_addr_i = ROMBase`;
* **the `[boot]` trace** is not evidence either way: `corev_apu/tb/g6lc_tb.cpp:676` prints
  core 0 only and only while `main_time < 64`, so the `npc=0x0` I cited in the superseded
  note below said nothing about hart 1. That inference is withdrawn.

Remaining candidates, in order: core 1 held in reset by the harness; core 1's I$ fetch
never receiving a response through the coherence hub / AXI arbiter (which would be a real
uncore defect and directly in scope for this review); or core 1 not actually elaborated.
The natural instrument is the TB's own multi-core PC probe, which prints `c1.npc` — but
**it no longer compiles**: `CVA6_MC_PC_PROBE_COMPILE` fails on stale hierarchy paths such
as `gen_cache_hpd__DOT__i_cache_subsystem__DOT__i_cva6_icache__DOT__cache_en_q`. Repairing
that probe is the cheapest next step and is now the top multi-core item.

### How the blocker was cleared (recorded: it cost most of the effort)

Two non-obvious obstacles sat in front of the experiment, and neither was an RTL defect:

* **`legacy` flavour cannot build** — `%Error-PINMISSING` at
  `core/fetch_A/smt_legacy/frontend.sv:4003`, missing `push_cf_i` / `cf_resolve_i`. All
  work now uses **flavour B (fetch_B)**, and that supply is now **retired in the tooling**
  rather than merely avoided: `soft-ladder-build-harness.sh` refuses flavour
  `legacy|a|A|oracle` with a directive message, overridable only by
  `SOFT_LADDER_ALLOW_RETIRED_FETCH_A=1` for work on repairing that supply itself.

  The flist was trimmed on evidence, not by assumption. Of the ten
  `core/fetch_A/smt_legacy/*` helpers it listed, **five were dead** — referenced only by
  fetch_A files the flist does not even compile (`frontend.sv`, `instr_queue.sv`,
  `instr_realign.sv`) — and are removed: `g6lc_fe_kill`, `g6lc_iq_hide`, `g6lc_present`,
  `g6lc_leftover`, `g6lc_lj_hide`.

  **The other five are not retired despite their path**, and deleting them would have
  broken the build: `g6lc_rvc_enc`, `g6lc_jalr_usable`, `g6lc_cf_unissued`, `g6lc_fe_keep`
  and `g6lc_sib_cjalr` are used by the *live* core — `compressed_decoder`, `id_stage`,
  `controller`, `scoreboard`, `branch_unit`, `issue_read_operands`, `issue_stage`. They are
  **misfiled under `fetch_A/`**, not dead; relocating them to a neutral directory is a
  follow-up. The nine `core/smt_legacy/*` entries are likewise left alone — that is a
  different directory carrying SMT support (CSR bank, thread select, regfile) which
  NrHarts>1 configurations still need.

  Verified after the trim: stream8 flavour B builds clean (8 warnings), the breadth suite
  is **22 pass / 0 fail**, default-target lint unchanged at 8 / 54, and flavour `legacy`
  now refuses instead of failing 30 s later with an error that looks like the caller's.
* **flavour B appeared to segfault on every ELF** — it was the **8 MB default stack**.
  The Verilated model is stack-allocated and this configuration exceeds it; `gdb` put the
  fault in `getenv()` inside `main`, the first page touch past the limit. `ulimit -s
  unlimited` and it runs. Nothing was wrong with the model.

The earlier "BLOCKED" conclusion below was written before those were understood; it is
superseded.

### Superseded — reproduction attempt recorded as blocked

To identify the mechanism I built a `ifdef seam, `G6LC_DCACHE_EXEC_CACHEABLE`, which drops
the execute-region term so both arms come from ONE source state, and taught
`isolated-config-overlay.py` / `soft-ladder-build-harness.sh` a `--define` form (a bare
`NAME` in `SOFT_LADDER_OVERLAY`) so an isolated build can carry it. Editing RTL between
builds would have made the two arms unattributable.

The experiment could not be run, because **the tree cannot currently produce a working
`g6lc64_stream8` netlist in either flavour**:

| Flavour | Result |
|---|---|
| `legacy` (fetch_A / smt_legacy supply) | **build fails** — `%Error-PINMISSING` at `core/fetch_A/smt_legacy/frontend.sv:4003`, missing pins `push_cf_i`, `cf_resolve_i` |
| `B` (fetch_B supply, stock flist) | builds clean (8 warnings) but the model **segfaults immediately** (rc=139) on every ELF |

Both arms of the flavour-B pair segfault — including the control built with **no define at
all** — so the crash is not caused by the seam. And neither `core/fetch_A`, `core/fetch_B`,
`core/fetch` nor `core/frontend` is modified in this worktree, so neither breakage is mine.

The production `work-ver-stream8` binary (dated 2026-09-15) runs all four tests fine, which
means it was built from an **older source state** than the tree can reproduce today. That is
the honest status: the 2jr mechanism remains unidentified, and it is now blocked on a
build-infrastructure regression rather than on analysis.

A first false step here is worth recording too: my initial pair compared the production
netlist against an overlay build, and the overlay silently derives from the STOCK flist —
so that pair differed by frontend supply (fetch_A vs fetch_B) as well as by the define. The
segfault it produced was unattributable. The corrected pair pins both arms to flavour B,
verified by diffing the two flists (identical but for the define) and the config packages
(md5 `7ad570b1…` on both).

**Prerequisites for the mechanism hunt, now explicit:** fix the `fetch_A/smt_legacy`
frontend pin mismatch, or fix whatever makes a fetch_B `stream8` model segfault at startup.
Until one of those is resolved, option 3 cannot be attempted and the execute-region
exclusion cannot be removed on evidence.

The options for the execute-region exclusion itself, for whoever owns that call:

1. **Narrow the predicate to the actual hazard** rather than the whole region — the
   aliasing case is a load to a line the I-cache holds, not every load to executable
   memory. This is the right fix if the hazard can be stated precisely.
2. **Separate the regions in configuration** so ExecuteRegion covers only the text range
   rather than all of DRAM. Cheap, but it only helps if code and data are actually
   separable in the memory map, and it leaves the predicate's over-reach in place for
   anyone who later widens the region again.
3. **Fix the aliasing at its source** (I$/D$ coherence for the shared line) and remove
   the exclusion entirely. Most correct, most work.

Whichever is chosen, it needs the `2jr_*` tests as its regression gate, since those are
what the exclusion was protecting.

### Superseded — "the PMU event does not fire"

**Finding — the L1 D-cache miss PMU event does not fire on HPDCACHE configurations.**
The wiring looks complete at every level: `cva6.sv` connects `.dcache_miss_o` for the
HPDCACHE branch, `cva6_hpdcache_wrapper.sv` drives it from hpdcache's real
`evt_cache_read_miss_o`, and that signal is genuinely computed on MSHR allocation. Yet
across 64 cold, shuffled, never-touched lines the counter reads zero, while the same
counter on the same loops reports 64 load accesses. This is the same class as
`coh_sc_fail_o` being hardwired zero — an observability event that cannot fire — and
`AGENTS.md` §0.1(6) requires a working PMU event per feature.

**Residual, stated so the next reader does not over-trust this:** the remaining check is
an RTL-level trace of `dcache_miss_cache_perf` (waveform or an SVA counting pulses),
which would distinguish "the event never pulses" from "it pulses but something between
it and `generic_counter` swallows it". Everything so far is black-box.

Consequence for residency: it stays **unproven**, but now for a known and specific
reason. Timing has no resolution on this model, and the one architectural instrument that
could answer it does not count. Repairing the miss event is the prerequisite, and it is
worth repairing on its own merits — a dead cache-miss counter blinds every performance
investigation on these configurations, not just this one.

Until then: the idle-observer result stands on its own terms (the write was observed
after a provably traffic-free window), with residency resting on read-allocate being
standard behaviour rather than on a measurement in this configuration.

### Superseded analysis (kept: the reasoning, and four wrong turns, are the record)

**Final status: my source-level claim was wrong, and the RTL change has been
reverted.** Two runs on the pre-change stream8 netlist, the second with a test that
provably caches the line:

| Test version | Result |
|---|---|
| v1 (hart 0 wrote LINE then read it back) | `SUCCESS tohost=0`, 57657 cycles |
| v2 (hart 1 initialises LINE; hart 0 never writes it) | `SUCCESS tohost=0`, 67100 cycles |

In v2 hart 0 reads SEED — a value only hart 1 ever wrote — so its load genuinely
missed and filled a cache line, and the write buffer cannot explain it. Hart 0 then
observed hart 1's overwrite. The control words each sit in a different cache set
(index `addr[12:6]`: LINE 0, READY 4, FLAG 8, GO 12, GO2 16 for a 32 KiB 4-way), so no
conflict eviction can be refreshing the copy either. **External invalidations are
delivered.**

`core/cache_subsystem/cva6_hpdcache_subsystem.sv` is therefore restored to its
original state. Keeping an unvalidated modification to a working, load-bearing path —
one that re-arbitrates the read-response channel and gates `inval_ready_o` — would add
risk for no demonstrated benefit. Re-linted after the revert: 4 warnings, unchanged.

**Correction to the "self-proving" argument (this supersedes it).** The FLAG-loop
argument below proves invalidation delivery *for a polling observer* — and that is
exactly the case where the observer's own refill traffic can supply the coincident
read response the invalidation needs. It does not establish delivery for an observer
that is idle. So the polling test's pass does **not** settle the question, and my
previous conclusion was too strong.

The cached region is `[0x8000_0000, 0xC000_0000)` in this configuration, so the
addresses used are genuinely cacheable; that candidate explanation is ruled out.

`mc_shared_line_quiet.S` is the decisive variant: hart 0 becomes resident on the line,
then waits in a **register-only** loop (no loads, stores or fences, therefore no read
responses) while hart 1 overwrites it. First run on the pre-change netlist:
`FAILED (tohost = 2147483647) after 900013 cycles` — that value is the harness cycle
timeout, not one of the test's fail codes, so it is **inconclusive**: neither hart
reached a verdict. The v2 polling test completes in 67100 cycles, so something in the
quiet variant does not terminate and its bounds/instrumentation need work (a progress
marker per stage, and a smaller quiet window) before it can be trusted either way.

**RETRACTION of the "different program" finding below, and what replaced it.** The
ELF-hash argument was itself an unvalidated instrument — exactly the error
`AGENTS-rt-learning-philosophy-AGI.md` RT-P1 names ("the instrument is part of the
observation") and RT-H1 forbids ("validate before interpreting"). Compiling the SAME
source twice, seconds apart, yields different md5s (`4e6a2d79…`, `ef2f42d8…`): this
toolchain embeds non-code content, so md5-of-ELF is NOT a program identity.

Comparing actual code instead settles it. The disassembly of `mc2.elf` (the 67100-cycle
PASS), `poll2.elf` (the 1.2M-cycle hang) and a fresh compile are **identical**
(objdump md5 `2e4409b189f6eebc3d8ccac8fb13424c`). They are the same program.

**Hypothesis 2 — run-to-run non-determinism — is also REFUTED.** Three consecutive runs
of the identical ELF with identical plusargs produced the identical verdict, the
identical cycle count (1200013) and the identical frontend warning at the identical
cycle (240711). The simulation is deterministic. Note also that `+verilator+seed+N` is
rejected by the HTIF argument parser before Verilator sees it, so seed control is not
even available at this boundary — worth knowing independently.

**Hypothesis 3 — the files differ outside `.text` — is REFUTED too, and that settles it.**
`mc2.elf` and `poll2.elf` are byte-identical in every loadable byte: same size (9832),
zero section-header and program-header differences, `tohost` at the same address
`0x80001000`, and identical full `objcopy -O binary` image md5 `8a6d40fd…`. And
`mc2.elf` — the very file that once reported SUCCESS at 67100 cycles — now times out at
exactly 1200013 cycles, and at 600013 under the smaller bound, with the same terminal
state. The `+time_out` value is not the variable; it only decides where the cut falls.

**FOURTH correction, and this one is the root cause: my invocation was never valid.**
The "model is broken" reading below is wrong. Tracing the recurring `cause=24` through
`riscv_pkg` gives `DEBUG_REQUEST = 24` — the harts were taking debug requests, not
hanging on anything the tests did. `ariane_testharness` defaults `debug_enable` to 1 and
routes the DMI path, so a run without `+debug_disable` sits in debug. Adding it removes
the `cause=24` line outright, confirming the mechanism.

The repo's own runner shows the canonical invocation, in `testharness_proxy.py`:

```
Variane_testharness +time_out=N +max-cycles=N +debug_disable +quiet_axi [+tohost=…] ELF
```

My hand-rolled command supplied only `+time_out`. That is why a minimal program which
provably reached its store (`mc_boot_sanity.S`, stalled at the `j` *after* the `sw`)
still never delivered `tohost`. `verif/regress/remote/mc-shared-line-coherence.sh` now
uses the canonical plusargs and carries a comment explaining why hand-rolling it is a
trap.

So the correct summary of this whole episode: **four successive conclusions of mine were
wrong — a dropped-invalidation defect, a different-program explanation, run-to-run
non-determinism, and a broken model — and every one of them came from reading an
instrument I had not validated.** The RT-P1 discipline is not a formality; each
retraction cost more than the validation would have. The one genuinely open technical
question (does an idle observer miss an invalidation?) is still unanswered, and is now
answerable, because the harness can finally be driven correctly.

### Harness verdict semantics: `+max-cycles` can turn a hang into a pass

Measured while repairing the invocation, and important beyond this section.

With `+max-cycles` set equal to `+time_out` — which is what `testharness_proxy.py`
does — a run that never completes prints:

```
*** SUCCESS *** (tohost = 0) after <bound> cycles
```

at **exactly** the bound. Verified at 200000 and at 2000000: the reported cycle count is
always the bound. The fesvr cut wins over the DUT watchdog, and `tohost` reads 0 because
nothing ever wrote it, so a hang is reported as a pass. With `+time_out` alone, the same
incomplete run reports `tohost = 2147483647`, which is distinguishable.

This is the same defect class as the platform gate that printed "Gate passed" over eight
SKIPs: **a verdict that cannot tell success from silence.** `mc-shared-line-coherence.sh`
therefore does not pass `+max-cycles`, and its predicate accepts a SUCCESS only if the
run ended *before* the bound; a SUCCESS at the bound is reported as `VACUOUS` and a
watchdog value as a failure.

Two related facts for whoever drives this harness next: `+tohost=<addr>` is **not** a
valid plusarg (it is rejected with the usage banner), and a freshly written bare-metal
ELF that simply stores to `tohost` and spins is not observed even with `+debug_disable`
and a `fence` — the repo's own review runners use `-m <cycles> -s 1 +debug_disable` and
check in-memory cookies rather than relying on `tohost`. Use those runners rather than
hand-rolling, which is the lesson this whole episode keeps teaching.

**Superseded — "the model does not run these programs at all".**
Every ELF now stalls in early boot — the same `commit-dbg` state (pc≈0x80000074,
cause=24) and the same `g6lc_fetch_dbg` assertion at the same cycle 240711, regardless
of which program is loaded. That is a property of the model, not of any test. The single
earlier pass is not reproducible in the current environment, and nothing about it can be
recovered: its model-binary hash was never recorded at the time, so whether the binary
moved cannot now be established. That is the concrete cost of not pinning evidence.

**Consequences.**

1. This harness cannot serve as a coherence testbed until the early-boot stall is
   understood. A fresh `g6lc64_stream8` model must be built from a recorded source state,
   with the model-binary hash captured in the run record.
2. The frontend assertion is the first thing to chase, and it may be a real defect rather
   than collateral: `g6lc_fetch_dbg.sv:347`, `I23 redirect_hold age 3 exceeds
   geo.hold_max 2`, on hart 1's frontend.
3. The HPDCACHE invalidation question is back to "no simulation evidence in either
   direction" — the source-level concern stands unexamined, and the change stays reverted
   because reverting never required positive evidence.

Three of my hypotheses died here in sequence — the HPDCACHE gating defect, run-to-run
non-determinism, and an out-of-`.text` file difference — each eliminated by a cheap
observation rather than by argument. Per §2.5 of the learning philosophy that is the
unit of progress; per RT-P1 the lesson is that each of those hypotheses was born from
reading an instrument without first validating what it could and could not show.

Two hypotheses of mine have now died in this section — the HPDCACHE gating defect and
simulation non-determinism — each killed by an observation I would not have made if I
had kept reasoning from source alone. That is the intended mode: per §2.5 of the
learning philosophy, the unit of progress is an eliminated alternative, not a longer
explanation.

**Superseded — the environment-integrity finding as first written.** A later
control run exposed that the evidence base is not trustworthy. The unmodified polling
test, which had passed in 67100 cycles, was re-run on the same netlist and hit the
1.2M-cycle harness timeout. Investigating:

* the simulator binary is UNCHANGED — `/opt/testharness/work/work-ver-stream8/
  Variane_testharness`, md5 `5b487b85a4893e04876fe8bb2ba9f95e`, dated 2026-09-15
  02:12:59. So the DUT did not move under us.
* but the two ELFs compiled from the SAME source path have different hashes:
  `mc2.elf` (the 67100-cycle pass) is `9df358283a7057f7702cee8825ecdb21`, while
  `poll2.elf` (today's control, same path, same flags) is
  `ce2626c1af03a0c218867a45c5b84dc9`.

The "control" was therefore **not the same program** that passed, so the comparison is
void — and, worse, it is not currently known which source state produced the pass. The
quiet-observer runs cannot be interpreted either, because their reference point is
unverified. Both harts also now trip a frontend assertion at ~240k cycles
(`g6lc_fetch_dbg: I23 redirect_hold age 3 exceeds geo.hold_max 2`, hart 1), which is a
separate machine-level stall that has nothing to do with polling versus quiet waiting
and which needs its own investigation.

**Nothing in this section is settled.** The earlier "invalidations are delivered"
conclusion rested on the 67100-cycle pass, and that result is no longer attributable to
a known source state. Treat the HPDCACHE invalidation question as fully open.

**Before any further coherence experiment:** pin the evidence. Record the md5 of the
simulator binary AND of the compiled ELF in every run, refuse to compare two runs whose
hashes differ, and re-establish a passing baseline from a known source state. The
methodological lesson is the same one this review keeps relearning — an unpinned
reference point silently turns a comparison into a coincidence.

**Standing position:** the defect is neither demonstrated nor excluded. The RTL change
stays reverted, because there is still no reproduction to justify modifying a path that
carries every D-cache response — but the source-level concern is NOT closed, and the
quiet-observer experiment is the way to close it.

**Superseded argument, kept for the record.** Hart 0 spins on FLAG with
ordinary loads, and hart 1 writes FLAG. For hart 0 to leave that loop at all, its
cached FLAG line must have been invalidated — otherwise it would have read a stale
zero until the bound expired and exited with code 6 (FLAG timeout). The run instead
completed in 67100 cycles with the correct LINE value. So invalidation delivery is
demonstrated twice over in the same run: once for FLAG (loop exit) and once for LINE
(final value). This is not a lucky coincidence of timing; it is the control-flow of the
test.

**What remains genuinely open is the mechanism, not the behaviour.** The AXI arbiter
drives `dcache_read_resp_valid_o = mem_resp_read_valid_arb[1]`, i.e. only on real read
responses, and `hpdcache.sv`'s demux samples `mem_resp_read_inval_i` only inside
`if (mem_resp_read_valid_i)`, while the AXI branch supplies the invalidation as an
independent pulse with `inval_ready_o = 1'b1`. By that reading a pulse should be lost;
empirically none is. Something carries it that I have not located — a candidate worth
checking is whether the spin loop's own refill traffic supplies the coincident response
often enough, or whether the region is not cached at all in this harness's PMA.

The way to settle it is a PMU-instrumented variant rather than more source reading:
have hart 0 load LINE twice before the remote write (the second load must HIT, proving
residency) and once after (which must MISS), reading the D-cache miss counter around
each. That distinguishes "invalidated" from "never resident" directly. Until then the
mechanism is unexplained — but the behaviour is correct, and no change to this path is
justified.

## Earlier framing (superseded)

**Correction (supersedes the stronger wording kept below).** The directed test ran on
the pre-change stream8 netlist and **passed**: `*** SUCCESS *** (tohost = 0) after
57657 cycles`. Hart 0 observed hart 1's write. So the property this section claimed was
broken is not broken in that experiment, and the source analysis below must be treated
as a hypothesis, not a demonstrated defect.

Two candidate explanations, one ruled out:

* *Fence flushing the copy* — ruled out. `g6lc64_stream8` sets
  `DcacheFlushOnFence = 1'b0`, so hart 0's `fence rw, rw` does not flush its D-cache.
* *The test never cached the line* — the likely flaw, and it is mine. Hart 0 stores
  SEED to LINE and then loads it back to "confirm" the value. In HPDcache that load can
  be satisfied from the **write buffer**, returning SEED without allocating a cache
  line. The check that was supposed to prove the line was cached is exactly what lets
  it not be. The line must instead be initialised by something other than hart 0 (or
  the write buffer drained) before hart 0's caching load.

Status of the RTL change: **retained but unvalidated**. It replaces a mechanism whose
source-level gating I traced (below), it elaborates, and it leaves the default targets
unchanged — but no executed test distinguishes it from the original. It must not be
counted as a repaired defect until a test that provably caches the line fails before it
and passes after.

## Source analysis (hypothesis, not a reproduction)

This is the defect the stale `cva6.sv` comment was pointing at, and it is worse
than the comment suggested: the wiring was present, so the invalidation LOOKED
delivered, but it was silently discarded.

HPDcache samples `mem_resp_read_inval_i` **only while `mem_resp_read_valid_i` is
asserted**. Both `mem_resp_read_miss_valid` and `mem_resp_read_ready_o` are computed
inside `if (mem_resp_read_valid_i)` in the read-response demux (`hpdcache.sv`), and
the metadata FIFO write is `mem_resp_valid_i & (... | mem_resp_inval_i)`
(`hpdcache_miss_handler.sv`). That is correct for the L15/OpenPiton port, where an
invalidation arrives AS a beat on that channel.

The AXI branch reused that port for an INDEPENDENT external coherence invalidation
and reported `inval_ready_o = 1'b1` unconditionally. So every invalidation that did
not happen to coincide with a memory read response was dropped, and the hub was told
it had been delivered — a remote write left this core's line stale with no retry and
no error anywhere.

**Reachable on every multi-core HPDCACHE configuration**: `g6lc64_stream8`
(NrCores=2), `g6lc64_ooo_server`, `g6lc64_server_math`.

Repair: the invalidation is held in one slot and presented as its own response beat
in a cycle the arbiter is not using, retired only on acceptance, with
`inval_ready_o` refusing a second obligation while one is owed. A synthetic beat is
safe because the miss handler excludes invalidations from MSHR acknowledgement
(`mshr_ack = ~is_inval`) and from the data FIFO, so only `inval_nline` is consumed.

**Verification status:** superseded by the correction at the head of this section. The
change elaborates and the default targets are unaffected (8 / 54 warnings, pass), but
the one executed experiment PASSED on the pre-change netlist, so nothing here is
established. The next step is a test whose caching load cannot be served by the write
buffer.

The `g6lc64_ooo_server` warning count moved 2 -> 4 across these passes; the two new
warnings are **not** from this repair. Both are `WIDTHCONCAT` on
`g6lc_l2_tag.sv:112` (`tags_q <= '0`), i.e. the whole-array tag reset introduced
earlier in this review, and they quantify the flop tag arrays at production geometry:
**3,080,192 bits** in `gen_l3.i_l3.i_l3_as_l2` and **401,408 bits** in `gen_l2.i_l2`.
Roughly 3.4 Mbit of tag state in flip-flops. The warnings are worth keeping rather
than silencing: they are now the messenger for the tag-SRAM item.

## Coverage finding: cacheable cross-core sharing was untested

The HPDCACHE invalidation defect above survived because nothing exercised the
property it breaks. Checked directly:

* the `mc_*` tests under `verif/tests/custom/multicore` are single-hart programs run
  under a multi-core configuration. `mc_cas_lock_handoff.S`, for example, CASes its
  own stack and never involves a second hart.
* `ai_dual_core_excl_smoke.S` IS a genuine two-hart test, but hart 0 only ever
  touches the shared line through `lr.d`/`sc.d` — the uncached/AMO path — so a
  dropped CACHEABLE invalidation cannot affect its result. It also targets the AI
  DRAM flavour, not a multi-core HPDCACHE build.

So the suite had no test where one hart caches a line with an ordinary load and
another hart writes it. `verif/tests/custom/multicore/mc_shared_line_coherence.S`
now covers exactly that: hart 0 loads LINE (and confirms it read its own seed, so a
later stale read cannot be blamed on never caching it), hart 1 stores a new value
and raises FLAG on a **separate** line so hart 0's spin cannot refill LINE as a side
effect, and hart 0 must then observe the new value. `tohost=9` is the stale-line
failure; `verif/regress/remote/mc-shared-line-coherence.sh` runs it.

**Not yet executed.** It needs a multi-core HPDCACHE netlist and the builder's
`work-ver-stream8` currently holds no built simulator, so this is a written
discriminator, not a result. The runner deliberately refuses to build implicitly:
a silent rebuild would make a pass or fail impossible to attribute to a source
state. Running it before and after the invalidation repair is the outstanding step.

## Hub arbitration fairness: the starve override cannot fire while AW is pending

`g6lc_coherence_hub` keeps per-core, per-channel starve counters and, at
`AXI_STARVE_LIMIT`, overrides round-robin to force the starved core to win
(`g6lc_coherence_hub.sv:129-140`). None of that had ever been exercised: the hub bench
left `coh_arb_starve_o()` **unconnected**, so "the RTL drives it" was the only evidence
the override worked — the same gap that made three PMU-style events look alive earlier in
this review.

`tb_g6lc_coherence_hub` scenario 9 connects it and drives both cores' AW while the memory
side refuses. The trace (`+starve_trace`) is unambiguous:

```
i=14  aw_valid=11  starve0=14  starve1=14  force=0  hold=1  grant=1
i=16  aw_valid=11  starve0=16  starve1=16  force=0  hold=1  grant=1
i=19  aw_valid=11  starve0=16  starve1=16  force=0  hold=1  grant=1
```

Two facts, one confirming the design and one qualifying it:

* **the counters are correct.** They climb and then *saturate* at the limit — the `< LIMIT`
  guard at line 414 means a starvation claim can never wrap around and be silently lost.
  That was a reading before; it is now measured.
* **the override never fires, because `aw_hold_q` suppresses it.** Line 141 clears
  `aw_starve_force` whenever a hold is active, and the hold latches on grant and persists
  until the memory side accepts. So `coh_arb_starve_o` **cannot assert while an AW is
  pending downstream**, no matter how long a core has waited.

The suppression is *correct* in itself — the AW owner must not change mid-burst or W data
would be mis-routed. But it means the override is not an unconditional service bound: the
real bound is `AXI_STARVE_LIMIT` **plus the hold duration**, and the hold is set by the
downstream memory, not by the hub.

**My first stimulus was also wrong, and the test said so rather than passing.** Refusing AW
for *everyone* is not starvation — no core is being served, so no core is relatively
starved. Scenario 9 failed with `HUB_STARVE_NOT_OBSERVED` instead of reporting success,
which is the behaviour a fairness test must have: if it cannot demonstrate the condition it
claims to test, it is not allowed to pass.

### The corrected experiment — after two harness errors, and a retraction of a retraction

Scenario 9 now has every core request AW continuously while the memory side accepts *and
completes* writes, with core count, starve limit and window all parameterised
(`-GNC`, `-GSTARVE_LIMIT`, `-GCYCLES`).

Getting a trustworthy measurement took two harness fixes, and in between I published a
conclusion that was wrong:

1. **Refusing AW for everyone is not starvation.** Nobody is served, so nobody is
   relatively starved, and `aw_hold_q` keeps the override suppressed throughout. The test
   correctly failed with `HUB_STARVE_NOT_OBSERVED` rather than passing.
2. **The B channel was never drained, and then drained one cycle too early.** Without B the
   outstanding scoreboard fills after `MAX_OUTSTANDING` writes and the hub stops granting:
   every configuration reported exactly **4** grants in total, and a 20× longer window
   changed nothing. My first fix issued B in the *same* cycle as the AW handshake — but the
   slot is only registered at the clock edge, so the response arrived before the entry
   existed and was never matched. Delaying B by one cycle took total grants from **4 to
   600**.

With a harness that actually runs:

| Config | total grants | distribution | override asserted |
|---|---|---|---|
| NC=2, limit 16 | 600 | **300 : 300** | **0 cycles** |
| NC=4, limit 16 | 600 | **150 × 4** | **0 cycles** |
| NC=8, limit 16 | 600 | **75 × 8** | **0 cycles** |
| NC=4, limit 1 | 600 | **599 : 0 : …** | shut-out |
| NC=8, limit 1 | 600 | **599 : 0 : …** | shut-out |

**Retraction.** Earlier in this document I recorded that the override "fires routinely at
the production limit — 39 of 60 cycles" and that my round-robin reasoning was "not the
operative effect". That measurement came from the stalled harness: with the hub jammed,
every core waited indefinitely and trivially passed the limit. On a working harness the
override **never fires at the production limit** — zero cycles in 1200, at 2, 4 *and* 8
cores — and round-robin alone distributes grants perfectly evenly. The original reasoning
was right; the refutation was an artifact.

**The real finding, and it is sharper than a bias.** When the override *does* engage, it
does not merely favour higher indices — it **locks the arbiter onto one core**. At limit 1
a single core takes **599 of 600** grants and others get **none**, at both 4 and 8 cores.
The cause is the selection loop (`g6lc_coherence_hub.sv:129-140`) assigning
`aw_winner = c` for every starved core, so the highest-indexed starved core always wins;
at a low limit it re-qualifies immediately after each grant and never yields.

So the override is not a fairness net — engaged, it is a fairness *hazard*. What protects
production is that it never engages: the margin between the service interval and
`AXI_STARVE_LIMIT = 16` is the entire safety argument, and that margin is now measured
rather than assumed. Anyone lowering the limit, or lengthening the service interval enough
to reach it, should expect monopolisation rather than rescue.

The scenario also refuses to judge what it cannot: when total grants < core count it reports
`HUB_STARVE_INCONCLUSIVE` instead of a shut-out, because four grants shared among eight
cores is a throughput limit and not an arbiter defect. That guard exists because I nearly
reported exactly that as a defect.

**Suite state:** 9/9 scenarios pass with the output connected. At the default production
configuration (2 cores, limit 16, 60 cycles) scenario 9 reports `grants=15 15`,
`starve_cycles=0` — even distribution, override never engaged. Its negative control fires
(`HUB_STARVE_SHUTOUT core 0 never granted`), and the pre-existing scenario-0 control still
fires, so neither check has been weakened.

**Owner decision queued:** make the override pick *rotationally* among starved cores —
e.g. scan from `aw_rr_q` and take the first starved core — rather than letting the loop's
last iteration win. That converts the mechanism from a hazard into the net it was intended
to be, and costs one changed loop. It is not applied here because the override is
unreachable in production and changing arbitration without a reproduction of harm would be
speculative.

## inval_bus drain: no loss, but the loss-signal was misnamed

The invalidation bus sits between the hub and the L1 retention repaired above, so if it
dropped requests the retention fix would be pointless. It does not: `inv_ready_o` is
`can_accept`, which is false whenever **any** target FIFO is full
(`g6lc_inval_bus.sv:60-84`), so the producer is back-pressured and the hub holds the
request. Together with the hub's own registered invalidation obligation and the L1-side
retention, all three stages of the path now hold rather than discard.

What was wrong was the **name**. The observability output was `inv_drop_o`, documented as
*"producer drop (all FIFOs full)"*, but it is assigned

```systemverilog
assign inv_stall_o = inv_req_i.valid & ~inv_ready_o;   // was inv_drop_o
```

— that is *"the producer was refused this cycle"*, and the request is retried, not lost. On
a coherence path that distinction is the whole ballgame: anyone debugging a stale line
would see `inv_drop` high and conclude invalidations were being discarded, which is exactly
the wrong direction to search. The signal is also **unconnected in the hub**, so nothing
was ever going to contradict the misreading.

Renamed to `inv_stall_o` at all five sites. Two details reinforce that this was a naming
defect rather than a design one: both existing benches already bound it to a signal called
**`blocked`**, and the module comment claims *"line-coalesce: back-to-back same-line inv to
same core merges"* — a design that coalesces rather than drops.

This is the same repair as `coh_sc_fail_o` → `coh_sc_noresv_o` earlier in this review:
point the name at the condition the signal actually observes. Verified: inval-bus leaf
bench passes, hub suite 9/9, `g6lc64_ooo_server` lint unchanged at 4 warnings against its
recorded baseline.
