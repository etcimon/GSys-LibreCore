# Remaining upgrade sequence — multi-core, hypervisor, AVX-like memcpy

Plan of record extension to `router-core-upgrade-program.md`. Ordered by **prerequisites** and
**perf/W for server/router Linux**. Detail: `server-math-hypervisor.md`.
All-feature enable + `NrCores` scale vs SMT fetch recover:
`multi-threading/soft-ladder/CONTRACT.md` §8 (named envelopes, union soak, no mega-package).

---

## 0. Done vs open (snapshot)

WIP snapshot (SMT2 / QEMU / 100 TOPS / PCIe vs OoO·H·RVV·stream):
[`current-stage.md`](current-stage.md). QEMU is never Variane evidence.

| Track | Status |
|-------|--------|
| U1–U4, multi-issue, U7ᵃ/ᵇ/ᶜ, U6.0–U6.2 integrated | **Done / partial** |
| **U6.1 dual-PC / CSR + follow-ons** | **Banks landed (fine-grain); product closeout open** — PC/CSR/RF/RAS/GHR banks; IF-only switch; *open:* dual-commit same cycle, banked BHT/BTB, FP reg banking, idle-thread clock gate, `Zawrs`/wait-for-peer, `SMT2` default SKU, boot-crutch retirement. |
| **U9.0 Hypervisor Sstc×H** | **Done** — `vstimecmp` + `henvcfg.STCE` + VSTIP |
| **U9.1 htimedelta** | **Done** — guest time = mtime + htimedelta; TIME under V |
| **U9.2 VS litmus / trap polish** | **Done** — virtual-instr STCE, VSTIP mip, VS mret litmus; G-stage paths present |
| **U10 server math package** | **C-light production** — HPDCACHE+HWPF+L2 auto, RVB/Zicbo*/H+Sstc, `server-math-tests` (optional) |
| U10ᵇ RVV / Ara attach | **Partial / live-lintable** — Ara vendored + attach + lint; purpose guide + DTS + directed tests; full cosim/SBI open |
| Multi-context PLIC | **Done** — 16 targets (8×M/S); harness fan-out per core |
| **U5 full OoO** | **Implemented/gated; qualification blocked** — live dispatch store self-blocking is reproduced; rename/LSQ/recovery/FP/hart and wide-retirement contracts remain open. In-order SMT2/stream8 passes do not qualify this path. |

---

## Broad RTL path review (2026-09-16)

This pass follows live control/data paths across issue/scoreboard/commit, OoO
rename/IQ/ROB/LSQ/PRF, speculative store forwarding, prediction/history recovery,
and shared L2/L3/invalidation. It is not a line-by-line proof of the repository,
vendored IP, firmware or every feature combination. Feature names, source presence
and old production labels are not substitutes for executed qualification.

### Selected repairs and measured trade-offs

| Change | Mechanism and result | Promotion scope |
|---|---|---|
| OoO IQ readiness | Remove selection/issue-time false wakeup; retain actual WB wakeup and capture WB coincident with dispatch. Permit the final exactly fitting dispatch group. | Directed/random tests and watched-readiness formal; not complete OoO execution qualification. |
| MSHR merge lifetime | A full matching waiter queue cannot be hidden by another free slot; post-pop append order and post-append completion preserve newly accepted waiters. | Generic leaf fixed; current L2/L3 top remains serialized and has no waiter drain. |
| Inclusive invalidation acknowledgment | Only the selected source receives ready. Hub priority now masks inclusive ready per target. | Source-derived mux plus live inclusive-leaf checks; producer eviction retention still open. |
| TAGE decay period | Twelve-bit wrap implements the stated 4096 accepted-update period. | Latent contract repair; usefulness training is tied off and not used in allocation. Prediction-output equivalence passes, no accuracy/power claim. |

Matched generic fixtures (scope metadata excluded):
- IQ two ports/depth8/four-bit tags: 13,866→13,074 cells, 698→699 sequential cells.
- IQ four ports/depth16/seven-bit tags: 60,370→53,260 cells, 1,538→1,540 sequential cells.
- MSHR depth4/two waiters: 878→1,003 cells, 127 state cells unchanged.
- MSHR depth8/three waiters: 1,995→2,095 cells, 284 state cells unchanged.
- Inclusive mux N3: 180→183 cells, zero state.
- Small TAGE fixture: 587→584 generic cells, 89 state cells unchanged. The small
  mapping difference is not attributed to a new predictor performance benefit.

No new array, clock, reset, pipeline stage, ISA/DTS field or feature enable is added.
Existing configuration/type seams remain. IQ removes a quadratic comparison cone
but adds per-dispatch WB comparisons; MSHR ready now includes pop/index eligibility;
inclusive ready adds a per-target priority gate. These are timing-impact loci, not
STA/Fmax closure. Scan/storage strategy is unchanged; fixed-size source registers
and generic mapped sequential counts must not be conflated.

Evidence: `review-rtl-audit-after-v1` passes 54 positive/negative component records;
`review-rtl-audit-integrations-v1` matches all 24 protected depth-two SMT2/stream8
records against their immutable qualified baselines, including timing, retirement,
operand traces, ROI reports and the expected stream8 negative. Thus the prior
independent SMT2 reference analyses remain bound to byte-identical new traces.
OoO is off in these packages; no full-OoO/L3 release claim follows.

Formal evidence is split rather than collapsed into one PASS: IQ v5 proves watched
readiness/capacity/storage relations by reset base plus two-step induction under
stable witness inputs and uniqueness of the watched live TID, with wait/drain
covers; MSHR rest-v3 passes ten-step admission/count/uniqueness safety and three
covers; tail-v7 proves TAGE prediction-output equivalence by two-step induction
and the inclusive-source acknowledgment equation. Mutations are detected. Earlier
harness/container initialization, frontend symbolic-witness/lowering, induction
and automatic internal-equivalence failures remain archived; only the named
successful recipes qualify. The TAGE miter proves useful bits zero as assertions,
not assumptions, and does not require the intentionally changed decay signal to
match. Reused synthesis numbers come from frozen raw artifacts, not reruns.

### Remaining blockers and effort-ranked next checks

| Priority/path | Established source contract or reproduced result | Next faithful check / constraint |
|---|---|---|
| ~~P0 OoO store issue~~ **repaired** | `mem_stall_i` gated STORE on `older_st`, which a store sets at dispatch, blocking its own issue→AGU→WB resolution. `g6lc_iq` now gates LOAD only. Rests on the source mechanism plus 54/54 component and 24/24 integration records; the dispatch-fixture records corroborate but do not establish it (see caveat). | Store lifetime still ends at WB, and `older_store_pending_o` is not age-aware: holding stores to commit needs a monotonic age or it deadlocks an older load behind a younger store. |
| **P0 dispatch fixture is not a trustworthy instrument** (blocks the items below it) | Rebuilding identical RTL with the simulator optimiser disabled (`-O0`) makes even the basic ALU case fail with `DISPATCH_ID` — `trans_id` never reaches issue — while default optimisation propagates it correctly. A functional result that depends on optimisation level means this fixture cannot separate RTL from toolchain behaviour, so its passes **and** its failures are provisional. Isolated `tb_g6lc_review_lsq` is unaffected and passes 4/4 with live controls. | Settle the fixture's stimulus timing (it drives with blocking assignments a fixed `#2` before a hand-rolled `tick()`, fragile under `--timing`), or re-host the integrated check under an independent frontend, then confirm optimisation level no longer changes the result. |
| P0 store writeback does not retire its LSQ entry (observation, **not** an established RTL defect) | `DISPATCH_STORE_WB_RETIRE` is red at default optimisation. VCD of the netlist shows completion arriving correctly while `i_lsq.alloc_id_i[0]` and `st_q[0].id` never leave zero and the intermediate `alloc_ids` is optimised away. Refuted: writeback/commit double-free; spurious allocation on an invalid port; duplicated id computation (sharing one signal changed nothing, edit reverted). | Re-read only after the fixture above is trustworthy. If it survives, then chase the id plumbing. |
| P0 LSQ store age/lifetime | `older_store_pending_o` is not age-aware and commit drains only through port 0. | Add a monotonic sequence number **before** moving the release point to commit, or an older load deadlocks behind a younger uncommitted store. |
| P0 OoO rename admission | Request validity and enable are gated by `can_go`, while `can_go` depends on rename stall. | Reproduce exhausted freelist feedback; separate ungated capacity calculation from committed updates. |
| P0 LSQ allocation/age/STL | Full means no free entry, not sufficient group credits; freed-slot reuse breaks index-as-age; STL data feeds address operand A. | Multi-alloc saturation, younger/older store distinction, exact byte coverage and load-result forwarding tests before speculative memory enable. |
| P0 rename recovery | Pre-group checkpoint, no resolving-branch identifier, snapshots of changing free/busy state; full flush resets identity mapping. | Preserve older work and committed values through multiple branches, late WB/commit and traps; do not infer precision from checkpoint storage. |
| P0 OoO hart/FP domains | Single rename/PRF namespace and generic TID bookkeeping do not establish separate hart/FP ownership. | Per-hart/per-class allocation, WB/bypass, exception and flush isolation. |
| P0 retirement width | Four-port configuration falls through scoreboard's one-port count path; commit remains two-port oriented. | Prefix commit/count/TID conservation tests; distinguish configured width from supported retirement. |
| P0 shared coherence | Accepted-write notification loss remains reproduced in the hub. The inclusive source's busy output is unused and eviction producer has no admission handshake. | Reserve invalidation obligations and settle write visibility; retain multiple victims under backpressure before scaling traffic. |
| P1 predictor context | Multi-slot base row/index overlap, per-window tagged provider, and fetch-hart folds used for training need explicit ownership. | Opposing branches within a window and fetch/resolve-hart mismatch accuracy tests; no blind capacity increase. |
| P1 prediction checkpoints | Push and pop are both driven from resolution; same-cycle count assignments and checkpoint association need reconciliation. | FIFO conservation plus branch-correlated prediction-time snapshots, before claiming speculative recovery or right-sizing. |
| P1 STQ/cancellation | Page-offset stalls, full-address forwarding and one-shot saved forwards coexist with different cancel/flush paths. | Full PA/byte-enable, same-PA peer write, fence/trap and commit handoff traces; preserve existing passing SMT2 behavior. |
| P1 cache refill errors | Serialized cacheable fill installs data and returns OKAY without a dedicated response-error accumulator. | Cacheable SLVERR/DECERR refill, no poisoned-line install and retry tests; bypass-error tests alone are insufficient. |
| P1 warm fetch | Prior traces demonstrate initiation interval two, but cycle-level IQ/backend reasons are incomplete. | Add neutral occupancy/readiness observations before registered fetch overlap; never reintroduce combinational ready feedback. |
| P2 real nonblocking L2/L3 | **Same-line hit-under-miss landed**: readers merging onto an in-flight fill are accepted and drained with their own id/beats (leaf 50→42 cycles for 8 shared-line readers; different-line control unchanged). Waiter pop is no longer tied low. Still one outstanding fill: 8 distinct-line misses remain 176 cycles / 8 fills, i.e. no MLP. | Multiple concurrent DRAM fills with response routing/reordering and per-fill line buffers; waiter response-error propagation; write interleaving. L3 still reuses the serial engine. |
| P2 area/physical | IQ compaction, tag flops and speculative checkpoints remain cost candidates. | Prove lifetimes first, then mapped macro/STA/power comparisons; no physical area from generic counts alone. |

### Follow-on pass: store-issue repair + L2 hit-under-miss

Both changes are qualified within the scopes stated in
`architecture/out-of-order/README.md` and `architecture/l2-l3-cache/README.md`.

Integration identity was re-established with `g6lc_l2_top` **actually overlaid** —
the earlier overlay list silently omitted it, so a first pass of this gate proved
nothing about the L2 change. `review-rtl-audit-integrations-v4`: 24/24 records,
every SMT2 and stream8 **cookie identical** to the frozen depth-two baselines, and
every architectural instruction stream identical. 13 records (all SMT2) are also
cycle-identical; the 11 stream8 records retire the same instructions 1-2 cycles
earlier during boot, which is the expected effect of a cache-timing change and was
confirmed by diffing the traces (80,667 identical lines, differing only in the
retirement-cycle column). The gate now requires cookie plus architectural
identity and records exact cycle identity separately, rather than being relaxed.

Because all cookies are unchanged, **no end-to-end SMT2 or stream8 speedup is
claimed** from hit-under-miss; the measured gain is confined to the leaf
shared-line stimulus. Full OoO remains unqualified: the store-issue repair removes
one deadlock, it does not close rename admission/recovery, LSQ age/forwarding,
hart/FP ownership or wide retirement.

The two-entry MSHR package promotion and prior fetch/predictor fixes remain intact.
No OoO, L3, replacement or cacheability option is newly enabled. Full source-bound
platform, firmware/ISA/FP/RVH/FPGA, DFT and physical qualification remain open.

## 1. Spec map (RISC-V identity of “AVX” + H)

| Server need | Spec | Implementation seat |
|-------------|------|---------------------|
| AVX-wide copy | RVV 1.0 | Ara / CVXIF vector; `RVV` + misa.V |
| `rep stos` / zero | Zicboz | U7ᶜ multi-beat `cbo.zero` |
| Stream copy | Zicbop + HWPF | Decode HINT + `HwPrefetchEn` |
| Bit munge | Zba/Zbb (`RVB`) | Config-gated |
| KVM host | H-ext + Sstc | U9.0 `vstimecmp`; HS CSRs under `RVH` |
| Guest timer | Sstc + H | `henvcfg.STCE` + VSTIP |

---

## 2. Sequence graph

```
U6.2 multi-core ──┬── U9.0 Sstc×H (vstimecmp) ✅
                  ├── U9.1 htimedelta + TIME under V ✅
                  ├── U9.2 VS litmus + STCE virtual-instr ✅
                  ├── multi-context PLIC (16 tgt) ✅
                  ├── U10 server package ✅ C-light (HPDCACHE+HWPF+L2 auto + tests)
                  ├── U10ᵇ RVV/Ara config scaffold ✅ (IP flist open)
                  └── U5 OoO (production gated; L3+server PF✅)
```

### Phase B — Hypervisor

| Step | Content | Status |
|------|---------|--------|
| B0 | `vstimecmp`, `henvcfg.STCE`, legalize `Sstc&&RVH`, VSTIP | **done** |
| B1 | `htimedelta` + guest `time` under V | **done** |
| B1b | VS entry litmus + STCE virtual-instr + HVIP mask | **done** |
| B2 | G-stage (two-stage + G-only) | **present** (KVM stress open) |
| B3 | HFENCE/HLV/HSV | decoder+commit present |
| B4 | PLIC multi-context (16 targets, per-core M/S) | **done** |

### Phase C — AVX-like / math

| Tier | Content | Status |
|------|---------|--------|
| C-light | Full-line `cbo.zero`, Zicbop HINT, RVB, HWPF, HPDCACHE server pkg | **done** |
| C-heavy | RVV package + Ara attach + guide/DTS/tests | **partial**; full cosim / OpenSBI V open |

---

## 3. Enable (operator)

```
# Server / KVM / math host profile (select as active cva6_config_pkg):
core/include/cv64a6_server_math_config_pkg.sv
  → H=1, Sstc=1, RVB, Zicbo*, L2, NrCores=2, dual-issue, HWPF
  → RVV=0 until Ara is linked

# When Ara is on the flist:
core/include/cv64a6_server_math_v_config_pkg.sv  # VExtEn=1, CvxifEn=0
# See architecture/ara-vector-attach.md

# Router low-power remains default imafdc packages (H=0, NrCores=1).
```

---

## 4. Next concrete work

1. ~~`vendor sync ara` + `Flist.ara`~~ **done**  
2. ~~L3 victim → L2 tag inval~~ **done**  
3. ~~p6 stream plane × multicore suite~~ **done** — `mc-stream-tests` lint gate green  
4. ~~Ara flist + typed lint top for `cv64a6_server_math_v`~~ **done** (`extraFlistsByTarget`,
   `cva6_ara_lint_top`, suite `ara-vector-path` PASS)  
5. ~~Ariane EnableAccelerator + attach + live Ara (`CVA6_ARA_ATTACH=1`)~~ **done** (Verilator lint
   green with `vendor/ara/cva6_shim/*` + expanded Flist.ara deps)  
6. ~~Strengthen formal vs **live** freelist / ROB / multi-port rename~~ **done**
   (`verify.formalTasks` 4× `.sby`; cancel remains policy model)  
7. ~~R2a dual-hart payload + DTB + R3a OpenSBI `fw_payload.elf` on Windows~~ **done**
   (managed xPack + Cygwin OpenSBI wrap → `workspace/smt2-linux/fw_payload.elf`)  
8. ~~R3 dual-hart payload cosim (`cva6.py` + Verilator on WSL)~~ **done** (Variane SUCCESS
   ~6.5M cycles on `fw_payload.elf`); Spike via WSL managed install; **R3b Linux `Image`**
   still external (cva6-sdk / kernel build)
9. U10ᵇ software contract: ~~purpose guide + DTS `v` + directed vector tests~~ **done**
   (`AGENTS-vector.md`, `ariane-server-math-v.dts`, `testlist_ara_vector.yaml`); next =
   OpenSBI VRF context + `cva6.py` cosim of `v_memcpy_lmul` under live Ara
10. ~~Zacas AMOCAS.W/D + multicore spo/CF directed + Spike soak~~ **done** (`RVZacas`,
    `testlist_mc_stream`, `mc-spo-soak` / `mc-spo-spike`); ~~RTL mini hard CAS~~ **done**
    (`mc-mini-veri`); ~~full CRT `mc-spo-veri`~~ **done** (imafdc + server_math 9/9); ~~AMOCAS.Q~~ **done**
11. ~~Structural FO4 residual close sparse_ex/frontend @ 2.5 GHz~~ **done** (screening;
    S3b-lab real-STA retune still open)

**Live next (authoritative ordered list + file priors):**
[`AGENTS-todo.md`](../AGENTS-todo.md) — **Current phase** and **Practical next**.
The **2026-09-16 stability-balanced reassessment** in `AGENTS-todo.md` and the
user-local `plan-ea69493e7a14829a.md` supersedes RR-first sequencing. E1–E6 are
work families, not a rigid queue: retained IQ/predictor gains are the foundation;
next measure warm-fetch supply and reproduce shared-path correctness scenarios,
then screen serialized-MSHR right-sizing and matched CPU-visible memory service.
Tag-SRAM feasibility/physical inputs proceed in parallel. Scheduler, concurrency,
width and policy growth require their own bottleneck evidence.
F0–F5 remain qualification gates, not a serial queue of historical experiments.
Technology/library/SRAM/constraint acquisition starts in parallel, not after RTL.
The IQ now also passes binary-state temporal induction and all twelve cover
predicates in its reduced formal envelope. The twelve-frame BMC remains historical
evidence; wider/FPGA/RVH and full-pipeline qualification are still separate.
Executable-data cacheability A/B now passes its short and larger controls, but
hot-scan ROI rises 275,593 to 374,177 cycles (+35.77%). Keep that candidate
isolated: checked locality subsequently identifies a repeated wrong-path
instruction-refill bottleneck rather than a cache-capacity explanation. A
response-aligned predictor lookup plus consistent absolute-corrector repair is
now retained after independent leaf/selector checks, SMT2 integration, broader
stream8 controls and synthesis. Locality ROI improves about 30.77%; unchanged-policy
hot-scan improves 4.66%. The corrector adds 99 generic leaf cells, no state bits.
Mapped timing/power and broader release qualification remain open; do not
automatically remove the cacheability workaround or tune RR.

The demonstrated restart, redirect-owner and split-target integer failures are
repaired and independently revalidated with the private corrected runtime.
NWORKERS=1 is still not a dual-active SMT pass; the two activated integer
encodings do not close natural firmware, FP isolation, ordering or physical
qualification. The old RR-specific livelock attribution and vacuous formal
PASS labels remain withdrawn. Do not repeat obsolete bisects to justify a new
optimization; use the current accepted-stream and cacheability contracts.

Preserve completed leaf and mapped equivalence through 8 KiB at their scope;
16 KiB collect and production mapped/physical gates remain incomplete. The
cacheability-overlay stream8 hot+scan recorded 374,177→325,980 ROI cycles, but
it is one RR-favourable experiment, not a production default decision. Named
stream8 and SMT2 controls remain separate. RR remains default-off.
Stage map: [`current-stage.md`](current-stage.md) (parallel envelopes, not one serial queue).
Host residual §1–§10 largely **done**; lab FO4/STA + stream8 optional growth open.
QEMU firmware ladder (U-Boot/EDK2 virt+soc) is **green as hypothesis**; E4 pflash and soc Shell
remain. 100 TOPS next is **I3 measure then I2**, gated by `RTL_FEEDBACK.md` F9–F14, not by KVM or
full OoO. PCIe host transport stays **unpinned**.

Quick spine for those open items:

| Next | Open these |
|------|------------|
| ~~Suite catalog~~ **done** | `mc-mini-veri` + `mc-spo-veri` in `defaults.ts`; `AGENTS-specs-to-tests.md` |
| ~~CRT RTL residual~~ **done** | imafdc + server_math L2 9/9 · `mc-spo-veri.sh` |
| ~~H-edge~~ **done** (Spike+RTL 3/3) | `kvm-h-spike` · `architecture/server-math-hypervisor.md` |
| ~~Stability / dual-ISS / dual-hart host~~ **done** | `stability-regress` · `dual-iss-regress` · `dual-hart-ci` |
| ~~AMOCAS.Q~~ **done** | `zacas-policy` · `architecture/zacas-amocas-q.md` |
| R3b Linux Image | soft gate `r3b-linux-image` · Image external |
| Ara live cosim / VRF | `ara-vector-cosim` · lab when `_v` TB + Image |
| Lab FO4/STA | `s9-lab-gate` · real STA / OpenROAD still lab |
| ~~Stream8-class package~~ **promoted + CRT 9/9 + H-edge 3/3** | `g6lc64_stream8` · `mc-spo-veri` · `kvm-h-veri` |
| QEMU E4 / soc Shell | `u-boot-edk2-boot-architecture.md` · no 32 MiB pflash on Variane; soc StartImage hang |
| 100 TOPS I3→I2 | `scaling-100tops.md` §4.2–§11 · `uncore/dram-channel-scaling.md` · `RTL_FEEDBACK.md` F9–F14 · shared DRAM slave (cores + `NrCores` + island) · do not grow clusters before measured BW |
| PCIe transport pin | `pcie-endpoint.md` · keep GPEX RC ≠ virt_ai_card EP until `ai_host_transport` |


