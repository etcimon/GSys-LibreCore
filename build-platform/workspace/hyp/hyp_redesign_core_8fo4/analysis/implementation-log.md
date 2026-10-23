# hyp8 implementation log — memory/PRF ownership repair

This log records the first coordinated implementation batch from the
caller-aware retirement plan: preserving accepted operation ownership under
staging across the physical register file, the speculative store buffer, and
the forwarding pipeline. All edits are confined to the materialized hyp8 tree
under `build-platform/workspace/hyp/hyp_redesign_core_8fo4/core`; production
`core/` and `corev_apu/` were not touched. Verification is proxy-only leaf
evidence on an isolated uploaded source closure — it exercises the changed
leaves plus a faithful queue-model wrapper, not full-core elaboration, and it
makes no claim about boot or 8FO4 qualification.

`core/ooo/g6lc_prf.sv` gained a `read_enable_i` input per read port. The
registered read-address stage now captures `raddr_i[r]` only when
`read_enable_i[r]` is asserted, so a read launched for a staged issue record
keeps its address while the lane is held and unrelated address traffic on the
port cannot overwrite it. The write path replaced the fixed 32-bit hi/lo
slice merge with a `DATA_WIDTH`-parameterized `selected_data`: the highest
matching write port wins, entry zero still reads back zero under
`ZERO_REG_ZERO`, and the write-through bypass is unchanged.

`core/ooo/g6lc_ooo_dispatch.sv` drives the two read-enable bits of the integer
PRF from `iqi_take[p]` so an operand read is only re-captured when a new
operation is actually accepted into the lane's issue stage. The shared
floating-point PRF read port is enabled by `|fp_take` across all three read
slots, and a new `fp_pending_hold` term (`iss_v_q & iss_fpsel_q & ~iss_pop`)
blocks a second FP candidate from taking the shared port while a staged FP
record is still held — the port frees on the current holder's pop edge, which
the pop term in `iss_v_q`'s update already permits in the same cycle.
`core/ooo/g6lc_ooo_backend.sv` ties its dormant PRF instance's
`read_enable_i` to `'1`. `flush_unissued` recovery semantics were deliberately
not touched; the recovery transaction is a separate design item.

`core/stb_insert.sv` now treats the staged S1 record as a reservation:
`reserved_slots` exposes `s1_slot_q` while `s1_v_q` holds, `free_slots` is the
complement of queue validity OR the reservation, and new arrivals pick the
lowest free slot — two consecutive accepted stores can no longer claim the
same slot before the first has installed. `ins_take` is also qualified by
`!flush_i` so a store accepted into staging while a flush lands cannot mark a
post-flush arrival as staged. The S1 age row/column capture now counts the
pending owner that installs at the same edge: a slot covered by
`s2_wr_valid_o && s1_slot_q` is treated as live with TID `s1_tid_q`, keeping
program order between an installing store and the arrival behind it. Two
simulation-only assertions guard the contract: an accepted insertion always
sees a nonzero free mask, and the held S1 slot stays one-hot.

`core/store_buffer.sv` replaced the hard-coded eight-entry speculative
occupancy count with a balanced padded-power-of-two reduction over
`DEPTH_SPEC` (leaf values are exactly `speculative_queue_n[i].valid`), and
replaced the registered `p_ready` credit — which could advertise capacity
for a slot the current same-cycle arrival had already claimed — with a
same-cycle credit: `ready_o` compares `speculative_status_cnt_n` plus the
incoming store term against `DEPTH_SPEC`. `count_n` already folds in the
S1-to-array installation and the commit pop, so no terms were re-added. The
latency comments were updated to record that the registered credit alone was
unsound. The forwarding and address-checker instances also gained the
committed-pending record inputs described below.

`core/stb_fwd.sv` now snapshots the represented payload with the match: F1
captures every speculative and committed queue slot's `.data` into
`f1_spec_data_q`/`f1_cmt_data_q` when `req_valid_i` is accepted, carries them
to `f2_*_data_q`, and the F3 byte emit reads the F2 snapshot instead of the
live queue arrays — a slot freed and reused between match and response can
no longer change the forwarded data. A new architectural source,
`cmt_pending_valid_i`/`cmt_pending_entry_i` (wired to the store buffer's
`commit_push_valid`/`commit_push_entry`, the S4 record waiting to land in the
commit queue), is matched in F1 with the same full-word/zero-block/per-byte
logic, carried through F2, and ranked in F3 after the live arrivals and
speculative sources but before the older committed queue entries; its byte
mask is included in the cover computation and a `cbo.zero` pending entry
contributes zero bytes. Being architectural, it is not filtered by the
speculative TID age rules. `core/addr_glue`'s `address_checker` instance in
`store_buffer.sv` receives the same record as an unconditional committed
match: it sets `page_offset_matches_now`/`po_commit_match` and is not gated
by `spec_stall_futile`. Only the forwarding pipeline valids clear on flush;
the committed source itself survives.

Verification evidence is `verif/tb/core/tb_g6lc_hyp8_memory.sv` (MIT, Etienne
Cimon): a focused bench around the real `g6lc_prf` (64-bit 2R2W and 32-bit
3R2W instances), `stb_insert`, and `stb_fwd`, driven by a small queue model
that replays the store buffer's wrapper semantics (removal set, live_after,
S2 install, head pop, pend push). It checks a launched PRF read holding
across three cycles of address churn at both widths, highest-port
same-address write wins, phys-zero behavior, consecutive stores claiming
distinct slots with surviving payloads and correct pending-owner age order,
cancelled and flushed pending records never installing, no accepted
insertion against an empty free mask, a forwarded word surviving slot
free-and-reuse before F3 with the original data, partial-byte and cbo.zero
sources, the pending committed push outranking the queued commit entries,
and a visible speculative source outranking the pending push — 43 explicit
checks, driven on the clock-low phase and sampled after the posedge, bounded
by a watchdog, printing `HYP8_MEMORY_PASS` only after all assertions.

The remote runner `verif/regress/remote/run_hyp8_memory.py` (MIT) uploads the
manifest materialized under `remote-runs/hyp8-memory-own-r1-closure/` (309
flist sources plus the bench, with sha256s in `manifest.json`), pins the
private runtime `/opt/testharness/runs/review-private-runtime-20260915/runtime`
by `verilated_funcs.h` digest plus compiled-`.d` dependency check, invokes the
managed 5.008-mod Verilator by absolute path
(`/opt/testharness/src/verilator-causal/bin/verilator`, since the proxy PATH
does not export it) with `--timing --assert --threads 1`, builds with `make -j2`,
scans the build log for the WIDTH/IMPLICIT/MULTIDRIVEN/LATCH/`%Error` classes
(no global suppression hides them), and fails unless `HYP8_MEMORY_PASS`
appears. It reports the selected bench only — the flist supplies package
dependencies, not a core elaboration claim.

The gate ran under tag `hyp8-memory-own-r5` (r1–r4 were consumed by
environmental/bench iterations: an untranslated data path, the missing
`verilator` on the proxy PATH, the missing `g6lc_hyp_pkg` in the source list,
and a bench check that sampled `free_slots` post-edge rather than at the
capture edge). Outcome: `HYP8_MEMORY_PASS checked=43`, sim rc=0, build log
free of the scanned warning classes; the only remaining diagnostic is a
pre-existing `%Warning-UNOPTFLAT` on the F3 per-byte OR-reduce network `sr`
in `stb_fwd.sv` (distinct bits per level — a Verilator scheduling note, not a
combinational loop, and unchanged in character from the tree's prior form).
Pulled artifacts: `remote-runs/hyp8-memory-own-r5/output/` (`build-model.log`,
`sim.log`, `results.json`, `sources.json`, `command-model.json`, model sha256
`5e1fbb87…`). No flist manifest changed, so `flist_check.py` was not rerun.
Existing remote workloads were not touched; the capacity probe showed
load ≈4 on 12 cores before the run, and two compiler jobs were used.

## hyp8 control/retirement batch (2026-10-22)

The second coordinated batch lands the common-event CSR retirement seam and
the issue-boundary ownership work from `analysis/continuation-design.md`,
plus the consolidated review corrections. All edits remain under the
materialized hyp8 tree; production `core/` and `corev_apu/` are untouched.
Leaf evidence is proxy-only on a fresh 318-file closure
(`remote-runs/hyp8-control-r1-closure`, flist=310 + 3 include-only headers +
3 copied-source negatives + 2 benches, sha256s in `manifest.json`).

Commit/CSR seam: `commit_stage.sv` retires via common-event wires -
`commit_ack_o = fire`, `suppress = '0`, `commit_macro_ack_o =
commit_macro_ack_dec` - with the delayed-ack pend registers removed; the CSR
request is gated `!csr_head || ((CsrReadStages==1 || csr_seen_match) &&
csr_rdata_valid_i)`, and `csr_exception_i` merges only for a matching CSR
head. `scoreboard.sv` checks the current ack against
`commit_bundle_valid_o` and slot issued state. `csr_buffer.sv` resolves the
address combinationally from the live table by `csr_commit_tid_i`
independently of `csr_commit_i` and derives credit from `free_count +
commit_release` against `1 + csr_valid_i`. `csr_decode.sv` holds an occupied
request register cleared only by flush or `consume_i` (a still-present
request cannot replace itself on the consume edge), with a `CsrReadStages==1`
bypass arm and legality `{1,2}`. `csr_regfile.sv` takes `flush_i`, qualifies
the request by `req_valid && head.fu==CSR && tid match`, applies on
`commit_ack_i[0] && !ex_i.valid`, returns rdata-valid on the request match,
and gates every phase-B default, the write strobes, `flush_req`, `dfsc`, and
the WFI arm on `csr_apply` - the arm condition is gated and sets `wfi_d=1`
rather than assigning `csr_apply` (an unapplied WFI must never clear an
existing sleep). Decode exceptions (`uae_w`/`vuae_w`) stay ungated, and the
monolithic reference assertions reproduce the same apply-gated state. The
six RVH write cases (HTVAL/HTINST/HGEIE/HGATP/HTIMEDELTA[H]) were restored
from the reference semantics, the RVH `vsstatus_d.fs` dirty line was added,
the config-gated mirror/restore defaults were completed so no `always_comb`
state is latch-inferred, and `mcountinhibit_i` is driven by
`32'(mcountinhibit_q)`. `csr_counters.sv` computes the carry in-cycle: each
low word extends to 33 bits, bit 32 selects between the live high word and
an independent high+1 candidate, and no carry state survives a software
write; its comment now states the value path timing requires remeasurement
rather than claiming an 8-FO4 fit.

Issue boundary: `g6lc_iq_payload.sv` registers `{rd_sbe_o, rd_orig_o,
rd_prd_o}` under `rd_enable_i` (async-low reset to zero), driven by the
per-port OR of `take_v`; `g6lc_iq_arb.sv` excludes candidates whose tid is
owned by any live win/pres record, carries a `port0` serial-class flag
(CSR/AMO/CVXIF) into `elig` so those candidates can only ever take port 0,
and now captures the age matrix inside the clocked block - the equivalent
`aq_d` combinational cone read the `cand_tid_i` port stale in the generated
5.008-mod model (the comparison and the candidate capture landed in separate
scheduling regions), so the same compare of the same inputs is evaluated at
the capture edge; that observation is scoped to this generated-model
scheduling pattern, not a general claim about combinational port reads.
`g6lc_ooo_dispatch.sv` gates `iqi_take` on flush/cancel, keeps issue-valid
masked so surviving accepted work re-offers, and replaces the replay index
loop with generated per-bit OR reductions over `rp_oh` (RP_N-wide
prefix-below lowest-set). `issue_read_operands.sv` splits the original
scoreboard process into `issue_candidates` (raw per-lane pre-ack) and
`issue_scoreboard` (final filtering: admit mask, CVXIF/CASQ/LR-SC/AMO rules,
in-order lane prefix, flush suppression); reservation offers use the raw
pre-ack and accepts use the final ack, all side effects read the final ack.
`g6lc_flu_reserve.sv` owns the completion window at actual IRO acceptance:
offers reserve nothing, an accepted fixed-latency lane sets bit `1 +
ooo_flu_cycles` in `reserved_next` and the window shifts on the capture
edge, the divider is claimed only on an accepted divide and held until the
matching writeback or scoreboard reclamation, and `WbReserve=0` admits all
without tracking. `ooo_flu_cycles` returns 2 for `LAT_ALU_LOW`,
`AluStages` for full ALU only when `AluStages>=2 && AluStaggered` (matching
`ex_stage.ALU_STAG`, else 1), 2 for CTRL_FLOW, 1 for CSR/AES, and
`MultStages` for multiplies with 0 for the variable divider. `ex_stage`
routes the branch exception through the winning-branch select and carries a
one-hot publication assertion; the profile legality now requires
`IqSpecWakeup==0` whenever `WbReserve` is set, the countdown fields were
widened to `WAKE_W`, and obsolete `svt-stage: absorb ... by=spec-wakeup`
comments on SEL/ARB/ISS were removed - real-WB scheduling does not absorb
dependent waits under `IqSpecWakeup=0`.

Verification: `verif/tb/core/tb_g6lc_hyp8_control.sv` (MIT) holds two leaf
tops. `tb_g6lc_hyp8_csr` instantiates the real commit_stage, csr_buffer,
and csr_regfile plus copied-source negatives (delayed ack, commit-gated
address) and a standalone `csr_counters` with DebugEn/PerfCounterEn pinned
on; cases cover the two-phase write/read response, back-to-back lifetimes,
a stalled-response halt (request registers, response stays live >=3 cycles
with no fire and no write, ack resumes within two ticks of release), a
halt-only head that never requests, the unsupported-CSR trap, a flush
killing a stalled pending record after the head is withdrawn, MRET/WFI
completion and the WFI sleep state, counter carry landing in the same cycle
with no stale carry, and inhibit/debug freeze - `HYP8_CSR_PASS checked=50`
at tag `hyp8-control-csr-r6` (model sha256
`8184920f80d73671ef95ae8e05749cb368b7e8b7c195396d5170f0d409927b8d`), sim
rc=0, no scanned warning classes. `tb_g6lc_hyp8_issue` instantiates the
real payload RAM, arbiter, reservation module, and the combinational-read
mutation control; cases cover adjacent grants carrying distinct payload
ids, a held record surviving >=3 cycles with no duplicate take and the
stale offer cleared before the ack edge, serial candidates never taking
port1 (verified while port1 is idle), the registered payload snapshot
outliving a reused slot while the copied comb read leaks it, reservation
offsets 2/3/4/9 against `reserved_q` after the capture-edge shift,
next-cycle CSR admission, an ALU(offset3)-then-CSR(offset2) collision, a
same-cycle two-lane CSR offer admitting exactly one accept with no phantom
claim, a declined offer reserving nothing, and divider ownership held to
writeback or reclamation - `HYP8_ISSUE_PASS checked=67` at tag
`hyp8-control-issue-r14` (model sha256
`47bf961f2624bf2a236ff86141edc9e31092711d7237fc090e696b6cb6878094`), sim
rc=0, no scanned warning classes. Intermediate failures r10-r13 were
bench-side expectation defects resolved against the emulated-bank contract
(combinational `ack_v` read before settle, a c1-only bank offer that a real
bank never makes since c1 is the second-oldest entry, and a take gated only
on `pres_q`, not `win_q`); r1-r9 retained for the earlier mechanical and
generated-model diagnosis. No boot, full-core elaboration, or 8FO4 claim is
made; unrelated remote workloads were left running.

## hyp8 full-top integration preparation (batch E, remote)

The full `g6lc_testharness` top now elaborates under Verilator for both the
default scalar profile and the named SMT2 selection. In
`core/include/g6lc64_hyp8_config_pkg.sv` a `G6LCConfigNrHarts` seam
(`ifdef G6LC_HYP8_SMT2` -> 2 else 1) feeds `NrHarts`; source default stays
single-hart and `SmtDrainedHandoff` remains 1 - no mixed residency is
claimed. `verif/regress/remote/hyp8/hyp8-build-harness.sh` maps explicit
`--target g6lc64_hyp8` / `g6lc64_hyp8_smt2` (the latter adds
`-DG6LC_HYP8_SMT2` to Verilator and `-DG6LC_TB_BANKED` to CFLAGS; both add
`-DG6LC_TB_OOO`), refuses an unspecified legacy default with usage text, and
logs `target=`/`harts=`/`flist=`/`top=` in the build log. Two mechanical
flist defects were repaired on the way: `g6lc_flu_reserve.sv` was listed
ahead of `g6lc_ooo_pkg.sv` (packages must precede use) in `Flist.g6lc_hyp8`,
`Flist.hyp8_apu`, and `Flist.hyp8_sim`, and `wt_dcache_wbuffer_leg.sv` was
missing from `Flist.hyp8_apu` and `Flist.hyp8_sim` though present in the
canonical core flist.

`verif/regress/remote/run_hyp8_integration.py` (MIT) drives the route:
hash-verified isolated source closure under `TH_DATA_DIR` (815 files,
`manifest.json` sha256 per file, verified before tools), materialized at
`TH_OUT_DIR/source` as `CVA6_REPO_DIR`; full-top `--lint-only --no-timing
--assert -Wall` lint for scalar then `-DG6LC_HYP8_SMT2` with the harness
warning policy; the exact proxy overlap query; then, only when the guard is
clear or `HYP8_ALLOW_OVERLAP=1` is explicitly supplied, the pinned isolated
scalar build (2 compiler jobs, 1 model thread, `VERILATOR_FLAVOUR=pinned`,
private runtime + verilator-causal + pinned RISCV/SPIKE). It assembles the
two bounded test programs fresh and writes `results.json`/`summary.txt`.
Absent the opt-in, a busy guard writes `build_blocked_by_overlap` and stops
after lint.

Run `hyp8-integration-r4` (closure `remote-runs/hyp8-integration-r1-closure`
rebuilt at 815 files): both lint profiles rc=0 with full warning census in
`results.json` (scalar: WIDTHEXPAND 325, LITENDIAN 123, WIDTHTRUNC 87,
LATCH 12, CASEINCOMPLETE 9, CMPCONST 10, UNSIGNED 9, smaller others, %Error
0; smt2 essentially identical, LATCH 11). The overlap probe recorded four
pre-existing `Variane_testharness` workloads (ooocoh-t53-server1,
ooocoh-t60-ooo x2, ooocoh-t61-server1) plus capacity (12 logical CPUs, load
4.57/4.20/3.93, ~84 GiB available); the run was launched with the explicit
per-run `HYP8_ALLOW_OVERLAP=1` opt-in (recorded in `results.json.guard`),
max 2 compiler jobs and 1 model thread, default guard unchanged. The
isolated scalar build then completed: `BUILD OK` `Variane_testharness`
sha256 `071a989f2c7249921ab425bf1c4b10ac6024f4c834f09efc20b1bac5eaed6988`,
`target=g6lc64_hyp8 harts=1`, harness-reported warnings=108 errors=0.
Artifacts: `remote-runs/hyp8-integration-r4/output/` (`results.json`,
`lint-scalar.log`, `lint-smt2.log`, `command-*.json`, `build-harness.log`,
`model/build.log`, `model/Variane_testharness`, `inputs/`). Earlier tags
r1-r3 retain the materialization iterations (missing `include` subdir
files, package ordering, missing wbuffer_leg entry). Boot inputs prepared,
not run: `inputs/h34_shift_dep.elf` and `inputs/h33_st_fwd.elf` assembled
fresh (tohost 0x80001000, source/gcc/elf sha256 in `results.json.inputs`).
The frozen SMT2 OpenSBI inputs were hash-verified against the lead's pins
and staged at `remote-runs/hyp8-integration-r1-inputs/smt2-opensbi/` but
are marked NOT configuration-aligned (firmware advertises zicbom/zacas,
hyp8 disables both; the Linux DTB advertises H) - provenance retained, do
not run; a matched DTS/firmware package is required before qualification.
No firmware was executed; the build is a review point, not a boot or 8FO4
claim.


## hyp8 wakeup/recovery ownership batch (batch F)

This batch fixes two grounded ownership defects in the OoO dispatch seam and
one redirect-publication hole, plus the scoped full-top latch/SELRANGE
diagnostics the r4 lint recorded in our files.

Lost wakeup (rename R1 snapshot vs allocation-time busy): g6lc_rename
gained int_busy_o/p_busy_o outputs wired to the recover unit's live
usy_q/busy_q bitmaps. g6lc_ooo_dispatch reads them through

en_int_busy/
en_fp_busy and computes grp_rs*_ready combinationally
from the FINAL held-group physical tags (grp_prs*_q/grp_fprs*_q) at the
IQ allocation cycle, then feeds disp_rs*_ready_i from those wires instead
of the R1-captured snapshot. The R1 
s*_ready_o snapshot is now
diagnostic-only (connected open); the stale grp_rs*_rdy_q registers and
their capture writes are removed. 	b_g6lc_rtl_review ties the new outputs
open explicitly.

Cancelled-branch publication: in x_stage the branch unit's resolve
pulse is now 
esolve_branch_raw; 
esolve_branch_o =
resolve_branch_raw && br_lane_v and 
esolved_branch_o is the record with
alid = br_lane_v, where r_lane_v = resolved_branch.valid &
~cancelled_mask_i[resolved_branch.trans_id]. A younger branch still in B1
when an older mispredict cancels its TID can no longer publish a redirect.
No !flush_i term: a branch can generate its own flush.

Checkpoint retire-between-select-and-repair: in g6lc_rename_recover the
repair unwind count is now 
el2 = (int'(g_pos) < int'(g_cnt)) ?
int'(g_pos) : 0 - pos_q is already maintained from head_d, so a
selected slot outside the current live ring means every older checkpoint
retired and the surviving count is 0; the old g_cnt-1 clamp underflowed
to all-ones when g_cnt was already 0. 
_ret is a per-hart array
declared outside the process (the scalar automatic re-triggered the LATCH
diagnostic), 
el2 is a named-block automatic default-0, and a
ckpt_cnt_q[h] <= CKPT_PER_HART assertion plus an updated 
ef_rel2
golden reference hold the bound.

Latch/SELRANGE rewrites (no semantic change, no waivers):
g6lc_rename_publish drops the conditional val/aval temporaries and
accumulates into pub_ck_aval_o/pub_ck_faval_o directly;
g6lc_iq steering uses generated steer_bank/steer_found nets instead
of conditional ound/ locals; g6lc_lsq's virtual-leaf process
indexes with (v < u) ? v : v-1 inline; issue_read_operands reads

egister_read[CASQ_HI_IDX] under OPERANDS_PER_INSTR == 3 and the g1gq
extra read uses a clamped constant index.

Dispatch seam bench: 	b_g6lc_hyp8_dispatch (third top in
erif/tb/core/tb_g6lc_hyp8_control.sv) instantiates the real
g6lc_ooo_dispatch (real rename/IQ/PRF/ROB/LSQ children) on
uild_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg), one hart.
Cases: A integer lost wakeup (producer TID1 issued, consumer rs1 depends,
ONE WB during the consumer's rename, removed before IQ allocation,
consumer must issue within 30 cycles with op_a = 64\'h12345678); B same
seam through the FP PRF (FADD classifies FP sources on rs2/result[4:0],
so the FP dependence rides rs2=1 and op_b must carry
64\'h4008000000000000); C intra-group RAW (same-group producer/consumer,
consumer must not issue until WB3 = 64\'hBEEF); D checkpoint retired
between select and repair (branch TID1 issued, same-cycle WB+commit_ack+
mispredict, ckpt_cnt_q[0] must read 0 - never all-ones - and a second
branch group must still be accepted). 
un_hyp8_memory.py gained
HYP8_LEAF=dispatch, which compiles the actual full core flist
(Flist.g6lc_hyp8 parsed from the closure: 310 sources + incdirs +
defines), records a distinct-class warning census (WIDTH/WIDTHEXPAND/
WIDTHTRUNC/WIDTHCONCAT/IMPLICIT/MULTIDRIVEN/LATCH counted separately),
and hashes the real erilator_bin and driver into results;

un_hyp8_integration.py records the same tool hashes and asserts the
built model's .d dependency on the pinned erilated_funcs.h.

Run hyp8-control-dispatch-r1 (closure 
emote-runs/hyp8-control-r2-closure,
391 files): build clean on the fatal classes (warnings=[],
census LITENDIAN 7 / WIDTHEXPAND 28 / UNOPTFLAT 23 / WIDTHTRUNC 5 /
UNSIGNED 3 / WIDTHCONCAT 2 - every hyp8 LATCH and SELRANGE diagnostic is
gone), model sha256 8473d07da5b7f4864e4704d1a1a353d8fd5115a76be221b9a689d1f2c0af0ca7,
verilator_bin 3e622e33..., driver 1da6decb.... FIRST SEMANTIC FAILURE:
A_CONSUMER_LOST_WAKEUP at sim cycle 251 - the producer issued (the
dispatch->IQ->arb->issue path works), the consumer group allocated into
the IQ (dack check passed), but the consumer never issued within 30
cycles after the WB. Stopped here per protocol; no instrumentation
series was run. Static review confirms the prescribed wiring is in place
verbatim; whether the residual stall is in the bitmap clear propagation,
the alloc-edge ready capture, or another legality gate is undetermined.
Also in this batch: erif/tests/custom/hyp8_branch_cancel.S (MIT) was
added for the next full-model snapshot - a cold taken branch followed by
a younger independent redirect in one issue group; it was NOT executed
and no full-model rebuild was performed.

Earlier in the batch: the single bounded r4 diagnostic
(hyp8-prebusy-h34-r1, h34_shift_dep.elf against the immutable r4 model,
sha256-verified before execution) did not reach tohost - it hit a fetch
assertion instr_realign.sv:280 realign continuation lost carry PC/hart
alignment at sim cycle 396 after fetch progressed npc=0x10000..0x10040.
Classified as an unrelated current-model fetch failure, recorded as
diagnostic evidence only, not debugged per instructions.


### Dispatch diagnostic capture (hyp8-control-dispatch-diag-r3)

Opt-in trace inside tb_g6lc_hyp8_dispatch only (+dispatch_trace, passed as
HYP8_LEAF_ARGS split by shlex through the leaf runner): one
HYP8_DISPATCH_BOUNDARY record per tick while cycles<80 plus per-entry
HYP8_DISPATCH_ENTRY records whenever an IQ slot carrying TID 2 is valid.
Runner now records WIDTHEXPAND/WIDTHTRUNC/WIDTHCONCAT counts as
openDiagnostics (acceptance policy unchanged). Two instrument defects were
fixed, not RTL: the bun remote-py wrapper keeps only the last --env token
(the gateway script testharness_proxy.py was invoked directly with both
--env tokens, identical py path), and {"str","str"} concatenation is
not accepted by this Verilator as a $display format argument (the packed
literal printed as one giant decimal and dropped all field names) - both
displays are now single literal format strings. Tag
hyp8-control-dispatch-diag-r2 was consumed by the two instrument-defect
attempts (first ran the memory leaf with the dropped HYP8_LEAF env;
second produced the garbled trace).

Run hyp8-control-dispatch-diag-r3 (closure remote-runs/hyp8-control-r4-closure,
391 files): build clean on fatal classes, census LITENDIAN7 WIDTHEXPAND28
WIDTHTRUNC5 WIDTHCONCAT2 UNSIGNED3 UNOPTFLAT23 (openDiagnostics recorded),
model sha256 24877d9d4b70e890e1cc61c5c7215593056e0e961280bc8a6dbbc4207a67e597.
Same semantic failure A_CONSUMER_LOST_WAKEUP (sim rc -6, leaf line 1067).

Trace record (tick samples are pre-edge after the #1 settle):
cyc6 producer TID1 ren_capture; cyc9 ren_pub; cyc10 grp_v=01 tid1 dack -
producer IQ-allocated; cyc11 tid_prd_q[1]=32, ren_int_busy[32]=1;
cyc14 producer issues (ivalid=01); cyc15 consumer TID2 ren_capture;
cyc16 wb_v=0001 AND data_wb_valid=00001 but data_wb_prd[0]=0 - the
combinational wb_prd=tid_prd_q[wb_id_i] evaluated 0 while wb_id_i[0]=1
and tid_prd_q[1]=32 (consistent with wb_id_i evaluated at its pre-drive
value); cyc17 data_wb_prd[0]=32 (corrects one cycle later, wb_id still 1);
cyc18 consumer ren_pub; cyc19 grp_v=01 tid2 grp_prs1_0=32
grp_rs1_ready_0=0 dack - consumer allocated with rs1_ready 0 because
ren_int_busy[32] is still 1: the busy clear was dropped since the
wb_prd!=0 guard saw 0. cyc19-49: entry sits b=4 e=0 valid tid=2
rs1_rdy=0 legal=1 cand_v=00 - permanently ineligible.

Decisive facts: the WB busy-clear did not fire (ren_int_busy[32]=1 for
all 30+ observed cycles, not only at the display sample, so the edge
evaluation also saw the stale value); the live-map readiness fix itself
did exactly what it was designed to do - grp_rs1_ready reflected the
(true) busy state at allocation. The residual defect is upstream of it:
the wb_id_i->tid_prd_q index evaluated stale inside this generated model,
matching the r9 stale-comb-port-read pattern; whether model-scheduling
anomaly or an RTL-observable hazard is undetermined pending review.


### Batch G: clocked WB adapter + frontend carry repair (hyp8-control-dispatch-r2, hyp8-control-realign-r2)

The diag-r3 C++ inspection classified the wb_id->tid_prd stale read as an
instrument artifact of the coroutine-driven bench, not an RTL timing
defect. Two changes landed:

Dispatch bench (tb_g6lc_hyp8_control.sv): the DUT-facing wb_v/wb_id/
wb_data/wb_exc are now written ONLY by a clocked adapter FF fed from new
wb_drive_* registers - the tuple is registers-stable for a full cycle
before the consuming edge, like a real FU writeback. reset_all clears the
drive side; wb_once launches on one tick and consumes on the next; cases
A/B assert the WB capture precedes dack (the lost-wakeup window is
unchanged); case D stages the WB one tick ahead of cack/mispredict so
they are consumed together. Trace instrumentation remains opt-in and was
not enabled for the final runs.

Frontend carry repair (the torn carry transaction, not an assertion
workaround): instr_realign drops pend_valid_o/pend_resolve_i/pend_keep_i
and pend_q/pend_hart_q entirely. The carry bank now eagerly advances to
each completing window's own result (carry_valid_d/carry_instr_d/
carry_addr_d already encode "new tail" vs "dropped carry"), while a later
refusal/protected verdict restores the consumed prefix explicitly through
the new restore_i/restore_hart_i/restore_pc_i/restore_instr_i/
restore_next_i inputs. restore_i has write priority over the normal
bank_update for its hart only; other harts' writes coexist. The
registered continuation successor uses the identical
bank_update && carry_valid_d condition with restore priority on
restore_next_i; the PC/successor consistency assertion is kept and new
sim assertions pin the restore tuple contract (RVI lower half,
next = pc + 2, legal hart). bank_valid_o now reads only this hart's bank
slot (no pend OR). The literal if(1'b1) gen_continuation is restored to
if(FastContinuation) with a real fallback (direct carry_addr_q + 2
compare; window_last_pc from hw_avail) so non-Fast geometry still
elaborates. frontend.sv removes the pend handshake; the verdict is now
carry_restore = s_live && s_carry_done && (s_protect || replay) &&
!meta_clear && !arch_now with the payload taken from the stage-S
retained window (meta_d_q.hart, s_addr[0], s_instr[0][15:0],
64'(s_vaddr) - the window start is exactly carry PC + 2, no adder on the
rollback path). g6lc_fe_override.s_valid_o is connected as s_live. This
eliminates the torn carry transaction; the r4-boot-path assertion at the
old line 280 was not disabled - it now constrains the new restore path.

New leaf tb_g6lc_hyp8_realign (same bench file, same full-flist closure):
independent literal expected stream on the 2-hart RVC/64b geometry -
A (3 C.NOP + tail 0093@1006), B (completes 00100093@1006 AND leaves tail
0193@100e in one window), C (completes 00300193@100e + 3 C.NOP, carry
drops), D (hart-1 tail 00b3@2006 written at the same edge as hart-0's
restore), B2 (B resent under a fresh response epoch completing
identically off the restored prefix), K (killed window inert), S
(stale-epoch window inert and not presented), F (normal foreign window
drops the carry while hart 1 survives). One runner link fix was needed
upstream of the semantics: id_stage's $unit DPI decl shares a generated
DepSet object with package helpers this top references, so the leaf adds
the MIT g6lc_dram_peek64_stub.cpp as a verilate input (dead code under
this top; the real peek stays testharness-owned) - same pattern as
run_idstage_leaf.py. That link failure was recorded as
hyp8-control-realign-r1 and is retained.

Results (normal no-plusarg runs, closure remote-runs/hyp8-control-r5-closure
dispatch / r6 realign, 391/392 files, make -j2, --threads 1):
  dispatch HYP8_DISPATCH_PASS checked=16  rc=0
    model sha256 ac91538a2dd354865f1ddac7364561fc37580fff704a3ea6ab4228739e5ff6db
    census LITENDIAN7 WIDTHEXPAND28 WIDTHTRUNC5 WIDTHCONCAT2 UNSIGNED3
    UNOPTFLAT23 (identical to diag-r3; openDiagnostics recorded)
  realign  HYP8_REALIGN_PASS checked=39   rc=0
    model sha256 5405d6599828e425ca32909aef198fe6de90cc5fa582487e3bf537d6e74a9e07
    census LITENDIAN7 WIDTHEXPAND15 WIDTHTRUNC2 UNOPTFLAT6
    (openDiagnostics recorded)
Both use verilator_bin 3e622e33..., driver 1da6decb....

Caller/licensing pass: the only production caller of the removed pend
ports was frontend.sv (updated); tb_rl_sbs.sv was already stale against
the epoch interface and remains untouched; gen_g6lc_core.py references
only surviving leftover_valid_o/leftover_pc_o. All upstream notices
preserved (instr_realign/frontend keep tier-U SHL headers + "Modified
by" attribution; g6lc_fe_override tier-R; bench/runner/stub MIT). No
firmware, boot, synthesis, OpenROAD, or full-model rebuild was run; the
dispatch pass is leaf evidence only.


### Integration r5 rebuild + first bounded smoke (hyp8-integration-r5, hyp8-h34-r2)

Post-Batch-G whole-core rebuild through run_hyp8_integration.py on the
fresh r5 closure (816 files incl. the new verif/tests/custom/
hyp8_branch_cancel.S input; TESTS is now explicit (name,source) pairs).
Lead review corrections present in the snapshot: instr_realign
carry_done_o <= 0 in the reset branch; frontend split_wait comment.
scalar lint rc=0, smt2 lint rc=0; guard recorded HYP8_ALLOW_OVERLAP=1
opt-in against 4 existing Variane workloads (limits 2 jobs / 1 thread,
load 4.52, MemAvail ~84 GiB). scalar build rc=0: model sha256
ef133ca1369bc65e12af28d6de7c42d4871c797c06427e0cc727a82afc2917a2,
runtime .d dep check ok (185 files), warnings WIDTHEXPAND67 WIDTHTRUNC16
WIDTHCONCAT3 UNSIGNED3 CMPCONST7 SYMRSVDWORD1 %Error0. verilator_bin
3e622e33..., driver 1da6decb.... Inputs assembled fresh (gcc d50d61d9):
h34_shift_dep elf 1b9e9c1b..., h33_st_fwd elf 9e4ccd84...,
hyp8_branch_cancel elf 9ac1f397..., all tohost 0x80001000.

FIRST SEMANTIC FAILURE - sequence stopped per protocol:
hyp8-h34-r2 (sha-verified r5 model, +tohost_addr=0x80001000
+smt_progress +stall_census +hang_dump=1000 +rvfi_cycle_stamp) aborted at
cycle 488 on a NEW assertion, not the r4-era carry one:

  instr_queue.sv:890 lane_class_chk: [instr_queue] lane_cf diverged
  from cf != NoCF   (i_frontend.i_instr_queue)

Progress evidence vs r4: the run retired 21 instructions (RVFI trace
296-474, boot loop 0x10000-0x10014 then real program 0x80000000-
0x8000003e: the lui/addiw/addi constant-materialization sequence) where
r4 died on the instr_realign continuation assertion at cycle 396 with
fetch stuck at npc=0x10040. npc now stalls at 0x10040 for ~45 trace
steps before the queue assertion fires - the fetch-side carry repair
held; the failure moved downstream into instruction-queue lane CF
classification. Root cause not investigated per stop rule; h33_st_fwd
and hyp8_branch_cancel were NOT run.

Artifacts (C: per approved artifact path):
C:/Users/etcim/AppData/Local/Temp/cva6-artifacts/hyp8-integration-r5/
  results.json lint-*.log command-*.json build-harness.log model/ inputs/
C:/Users/etcim/AppData/Local/Temp/cva6-artifacts/hyp8-h34-r2/
  run-hyp8.log trace_rvfi_hart_00.dasm trace_hart_0.dasm iti/encaps.traces


### Integration r6 rebuild + bounded leaves + first r6 smoke (queue/ALU batch)

Two concrete defects fixed (lead-diagnosed): (a) instr_queue.sv cf gather
used a ONE-BIT logic'() cast on both 3-bit cf_t operands -- Jump=2 and
Return=4 folded to NoCF while is_taken stayed 1; replaced with the
full-width OR-gather `cf_t'(instr_data_in[f].cf | (cf_type_i[i] &
{$bits(cf_t){fsel_oh[f][i]}}))`, and lane_class_chk moved from always_comb
immediate assertions to posedge sampling under rst_ni && !flush_i on
nonempty heads only (both class comparisons/messages preserved); (b)
alu.sv a3cls1_q captured the A3 class for EVERY op incl. branch/CSR/AES
bystanders, and result_o selects result3_q solely on a3cls3_q -- an
invalid predecessor could shadow a younger valid A2 result. New
result_valid_i ownership port: alu (a3cls1_q <= result_valid_i &&
alu_is_a3(...)), alu_wrapper (per-ALU bit vector), ex_stage
(alu_result_owner: bit0 = alu_in && !flush_i, bit1 = |alu2_valid_i &&
!flush_i, extras = alu_valid_i[a] && !flush_i when a<NrIssuePorts else 0).
Caller audit: ex_stage->alu_wrapper->alu is the only chain; no bench or
generator template emits the alu/alu_wrapper interface directly
(gen_g6lc_core.py only wires alu_fwd_* ex_stage ports). tb_rl_sbs.sv
remains stale/unqualified (not counted as covered).

New leaves on the full-flist r7 closure (391+stub=392 files):
  queue  tb_g6lc_hyp8_queue -- all 5 cf_t classes, 2-cycle held drain,
         payload/cf/ckpt/target preserved, NoCF-branch target not
         consumed, consecutive CF packets target order, epoch drop.
  alu    tb_g6lc_hyp8_alu  -- invalid-owner predecessors {EQ,CSR_READ,
         AES64ES,SLL} cannot claim A3 (ADD 5+7 publishes 12+qtid at A2);
         EQ compare still true with owner=0; valid SLL 9<<3 publishes 72
         at A3+rtid; bubble-separated ADD publishes 12; flush-equivalent
         owner=0 case identical.
Results (first semantic run each, normal no-plusarg):
  hyp8-control-queue-r1  verilate error (bench typo consumed_o vs
                         consumed -- instrument defect, not semantic)
  hyp8-control-queue-r2  HYP8_QUEUE_PASS checked=89  rc=0
                         model acfed47d7d42f84e0162ba7c00aae6874858e7f0a9028ebbb4870ced14da547b
                         census LITENDIAN7 WIDTHEXPAND15 WIDTHTRUNC2 UNOPTFLAT4
  hyp8-control-alu-r1    HYP8_ALU_PASS checked=23  rc=0
                         model 330e35fee1bc69d120b3805d8e5641fea9d096f5a8f132e2fecc89c18d247e40
                         census LITENDIAN7 WIDTHEXPAND15 WIDTHTRUNC2
openDiagnostics recorded; acceptance policy unchanged (LATCH fatal, no
new waivers). verilator_bin 3e622e33..., driver 1da6dec....

Whole-core r6: closure hyp8-integration-r6-closure (816 files incl.
hyp8_branch_cancel.S). scalar lint rc=0, smt2 lint rc=0, scalar build
rc=0: model sha256
e3eb3b4070bcdbb41db835d6aecfb3fe2f4d7081ef1ec5872b177eab823ac939,
runtime .d dep check ok (185 files), warnings WIDTHEXPAND65 WIDTHTRUNC16
WIDTHCONCAT3 UNSIGNED3 CMPCONST7 SYMRSVDWORD1 %Error0 (WIDTHEXPAND 67->65
after the cast repair). guard: explicit HYP8_ALLOW_OVERLAP=1 vs 4 Variane
workloads, limits 2 jobs/1 thread. Inputs: h34 elf e10b0539..., h33
3b914253..., branch_cancel 92c96ac2..., all tohost 0x80001000. Artifacts
C:/Users/etcim/AppData/Local/Temp/cva6-artifacts/hyp8-integration-r6.

FIRST R6 SEMANTIC FAILURE - sequence stopped per protocol:
hyp8-h34-r3 (sha-verified r6 model, +tohost_addr=0x80001000 +smt_progress
+stall_census +hang_dump=1000 +rvfi_cycle_stamp, --time-out 50000):
NO assertion (lane_cf fixed) but non-convergence -- "*** SUCCESS ***
(tohost = 0) after 50000 cycles" then "[mc_verdict] FAIL: a core ran and
then stopped retiring (exit code 126)", sim rc=120. 41 instructions
retired (r5: 21) reaching pc=0x80000090 (bne x28,x14,0x8, word
0x008e1363 @557) before retirement stopped. Fetch npc parked at 0x10040
from t=0x16 while retirements continued to @557+ -- the frontend stopped
issuing new fetch addresses. hang dumps: sb_empty=1, head slot9
pc=0x80000004 valid=0, IQ issue_valid=00, LSU idle. ckpt census:
allocs=10 pops=6 restores=1 restore_dropped=1, resolves br=6 jmp=1
mispredicts jmp=1. A restore was DROPPED -- consistent with the
frontend's carry-restore path (s_protect/replay verdict after the jmp
mispredict) not landing, leaving fetch parked. Root cause NOT
investigated per stop rule; h33/branch-cancel NOT run. Raw artifacts:
remote-runs/hyp8-h34-r3/ and
C:/Users/etcim/AppData/Local/Temp/cva6-artifacts/hyp8-h34-r3/.

Temp-path note: C:\Users\etcim\AppData\Local\Temp is virtualized for the
file tools (edits land in a per-tool view); the real r4 leaf closure was
incidentally re-materialized with current sources by an earlier script
invocation (its manifest now reflects r7-era sources). All closures are
rebuildable; per-run sources.json hashes remain the authoritative record.
Bench materialization for r7 and the r6 integration closure were done
inline via bash python to bypass the drift.

## Batch J — queue ownership boundary + boot-ROM read latency (2026-10-21)

### r6 root cause (diagnostic hyp8-h34-epoch-diag-r1, immutable r6 model,
### no code change; raw logs remote-runs/hyp8-h34-epoch-diag-r1/ and
### C:/Users/etcim/AppData/Local/Temp/cva6-artifacts/hyp8-h34-epoch-diag-r1/)

Correction of record: r6 hyp8-h34-r3 was a RETIREMENT STALL, not simulator
non-convergence — the model ran normally to the 50000-cycle budget with
tohost=0. The `[boot] npc=0x10040` prints cover only the first ~63 cycles
and do not describe the final NPC; `restores/restore_dropped` is the BPU
checkpoint census, not the realigner carry-restore handshake.

Traced mechanism (accepted-prefix epoch drop + orphaned target records):
  * t=488 epoch1 queue accepts PCs 0x8000005e/62/66 (vmask!=0, one
    predicted Jump at 66 pushes a target record).
  * t=489 delivers 5e. t=490 epoch2 redirect: lane_live/stale
    invalidates the STORED 62/66 entries — they drop inside the
    consumed prefix without pos_present, so fetch_entry_is_cf=0 and
    their target record is never popped.
  * t=545 epoch2 queues 90/94; t=546 delivers 90 with instr FIFO
    full=0000 but ready_o=0 — the depth-2 shared target FIFO is full.
  * t=547 epoch3 redirect drops Jump@94: second target orphaned.
  * After: zero new queue input (ready_o=0 blocks pushes), no live CF
    can be consumed to pop a target -> permanent starvation; [icf]
    parked at 0x800000a0, scoreboard/IQ/LSU idle.
Ownership-boundary error: a weak prediction redirect invalidates
UNACCEPTED fetch windows, not the instruction prefix already accepted
by instr_queue (frontend comment O7m documented the reverted
queued-instruction flush).

### instr_queue.sv repair
  * win_live = (push_epoch_i == epoch_i) retained on INPUT acceptance —
    a dead-epoch window is still dropped whole (no push/replay/consume).
  * Per-lane eligibility replaced: lane_live[f] = ~instr_queue_empty[f],
    lane_stale[f] = 1'b0; lane_epoch_ok removed. Stored epoch kept as
    provenance only — it cannot revoke an accepted entry.
  * Consumed-prefix structure, CF serialization, index rotations,
    record fields, FIFO depths, target accounting all unchanged;
    pos_stale/fill-prefix machinery retained (stale arm constant-0).
  * pop_address still follows actually consumed CF entries — instruction
    and target records now have paired lifetimes: a stored CF always
    reaches delivery or the whole queue takes flush_i (which resets BOTH
    FIFOs); no early is_mispredict flush added (restart frontier /
    controller own that seam). Frontend .flush_i(flush_i|smt_restore_flush)
    unchanged.

### Boot-ROM read-latency defect (lead-verified from the same diag trace:
### AXI read for 0x10008 returned 01f4141300100413 = 0x10000's word, and
### RVFI retired the 0x10000/0x10004 pair again at 0x10008/0x1000c)
  * g6lc_testharness.sv: i_axi2rom was the LEGACY axi2mem (data_i sampled
    one cycle after combinational req). Replaced with existing
    g6lc_axi2mem_reg behind typed AXI structs (AXI_ASSIGN_TO_REQ /
    AXI_ASSIGN_FROM_RESP on master[g6lc_soc::ROM], g6lc_axi_soc
    req_slv_t/resp_slv_t), rst_ni=ndmreset_n, req/addr/rdata wiring
    preserved; we/be/wdata unconnected.
  * localparam BootromReadLatency = 3: adapter pulses req_q at edge0,
    ROM addr_q at edge1, bank_rdata_q at edge2; adapter samples rdata_i
    at edge RD_LAT counted from edge0 (RD_LAT=1 == combinational memory).
  * bootrom.sv: stale comment corrected (consumer samples three edges
    after its request beat; comment only, no ROM logic change).
  * Debug-module legacy axi2mem path untouched (dm_mem latency matches
    the legacy contract; out of scope).

### hyp8_branch_cancel.S
  * _start replaced with li t0,3 / li t1,5 / mul t2,t0,t1 / beq t2,t2,good
    / bne t2,zero,bad / nop / nop — both branches wait on the same
    8-stage multiply so they can issue adjacently when it completes.
    good/bad/tohost bodies unchanged. Functional control-flow gate only;
    late-cancel subpath coverage NOT claimed without observation.

### Leaves (each one semantic run, first failure stops)
  * queue leaf hyp8-control-queue-r3 (closure hyp8-control-r8-closure,
    392 files): HYP8_QUEUE_PASS checked=126. New cases: two-orphan
    starvation counterexample (Jump@0x1020 tgt 0x4000 + Return@0x1024
    tgt 0x4040 accepted under epoch0 with ready held, epoch bump to 1
    WITHOUT flush -> both records stay live, drain in order, q_ready
    recovers; fails the old source), dead-epoch input rejection
    (push_epoch0 vs epoch1: consumed=0, no replay, no entry, no
    pointer/target advance), explicit flush_i (both FIFOs clear, fresh
    packet delivers). All prior cf-width/hold/payload/target/cancel
    checks retained. Model d6f4494b...; census LITENDIAN7 WIDTHEXPAND15
    WIDTHTRUNC2 UNOPTFLAT4; openDiagnostics unchanged policy.
  * rom leaf hyp8-control-rom-r1 (closure hyp8-control-r9-closure =
    r8 + g6lc_axi/g6lc_soc/g6lc_axi_soc pkgs + g6lc_axi2mem_reg +
    bootrom, 397 files): HYP8_ROM_PASS checked=26. Actual
    g6lc_axi2mem_reg #(.RD_LAT(3)) + actual banked bootrom; typed AR/R
    driven directly; literal words 0x0->01f41413_00100413,
    0x8->00000597_f1402573, 0x10->00040067_07458593; three single-beats
    in order, reverse back-to-back, len=1 INCR burst (r.last only on
    beat 2), r_ready held low 2 cycles on one beat. Model 20babd76...;
    census LITENDIAN7 WIDTHEXPAND21 WIDTHTRUNC2.

### Interrupted-build note
  * A first hyp8-integration-r7 build was launched before the ROM defect
    reached the batch; its in-flight compile was killed (own job) and
    relaunched on the updated closure including the harness/ROM fix.
    The killed attempt's partial artifacts remain under the remote
    run dir; the relaunched build is authoritative.

### r7 build - complete

hyp8-integration-r7 (815-manifest closure, incl. queue repair + typed
g6lc_axi2mem_reg RD_LAT=3 + ROM comment + new branch_cancel):
scalar lint rc=0, smt2 lint rc=0, build rc=0. Model sha256
4764feddeedf123095e72b36822474b9ca4532ce93735167c7310d99223090a6,
runtime dep check 183 files ok, build census WIDTHEXPAND65 WIDTHTRUNC16
WIDTHCONCAT3 UNSIGNED3 CMPCONST7 SYMRSVDWORD1 %Error0 (unchanged vs r6).
Overlap guard HYP8_ALLOW_OVERLAP=1 recorded; 4 Variane workloads
enumerated and untouched; 2 jobs / 1 thread. Inputs assembled: h34
007017c9..., h33 9f9ea758..., branch_cancel 8fd5345d... (new mul-dep
source 09393f11...), all tohost 0x80001000. Artifacts
C:/Users/etcim/AppData/Local/Temp/cva6-artifacts/hyp8-integration-r7.

FIRST R7 SEMANTIC FAILURE - sequence stopped per protocol:
hyp8-h34-r4 (sha-verified r7 model, --verlib ../runs/hyp8-integration-r7/
output/model, +tohost_addr=0x80001000 +smt_progress +stall_census
+hang_dump=1000 +rvfi_cycle_stamp, --time-out 50000):
  [649] %Error: store_buffer.sv:1147 speculative_buffer_underflow:
  "[Speculative Queue] You are committing although there are no stores
  to commit" (assert: cnt==0 |-> !commit_i), sim abort.
PROGRESS EVIDENCE: the epoch/target-starvation stall is GONE - 54
instructions retired (r6 stalled at 41), reaching pc 0x800000de
(past the old 0x80000090 boundary and through the ep2/ep3 redirect
region); RVC decode and the redirect/restore path now advance fetch.
The new failure is a DIFFERENT defect class: commit_i asserted while
the speculative store queue is empty - a store-commit accounting
boundary issue, not investigated per the stop rule.
h33_st_fwd / hyp8_branch_cancel NOT run. Firmware witness not reached.
Raw artifacts: remote-runs/hyp8-h34-r4/ and
C:/Users/etcim/AppData/Local/Temp/cva6-artifacts/hyp8-h34-r4/.

## Batch K - store-commit ownership gate + commit-edge SVA sampling repair (r8)

### Root cause of hyp8-h34-r4 (store_buffer.sv:1147 underflow @649)
RVFI retired through 0x800000de = `la t0,tohost`; the next instruction is the
program's FIRST store. store_unit VALID_STORE asserts valid_o (scoreboard
completion) and st_valid (store_buffer valid_i) in the SAME cycle, but
stb_insert stages the arrival: S1 capture at the next edge, S2 writeback
installs into speculative_queue_q one edge later. commit_stage's
store_commit_hold only consulted commit_lsu_ready_i = store_buffer
commit_ready_o = drain_commit_ready && !commit_pend_v, which never checked
that the committing store is installed. commit_i fired while the store was
still in S1: stb_commit pop_oh=0, pend_v not set - the committed store was
silently LOST and speculative_buffer_underflow caught it. Ownership defect
of the staged insertion, not an assertion issue.

### Repair (store_buffer.sv)
  * commit_ready_o now requires the committing transaction to be INSTALLED:
    commit_tid_present scans spec_valid_q/trans_id for commit_trans_id_i;
    commit_ready_o = drain_commit_ready && !commit_pend_v &&
    (!G6LCCfg.OoOEn || commit_tid_present). Presence, not head, is
    deliberate: ordering/head validation stays with ooo_commit_is_oldest
    and MIX_COMMIT head_mismatch. No S1 bypass, stb_insert latency
    unchanged. No committing-hart input exists on the module; single-hart
    hyp8 tid identity is complete - recorded SMT2/per-hart ownership
    obligation in the comment.

### Caller audit (performed before the gate)
  * commit_lsu_ready_o: ex_stage -> g6lc_core; consumers:
    commit_stage.sv store_commit_hold (the gated hold, sole commit gate),
    g6lc_core.sv commit gating (~2057), store stall census (~2656). No
    non-store retirement path consumes it, so no ready-split was needed.
  * commit_lsu_o asserts for fu==STORE && !AMO (commit_stage.sv ~333):
    plain int/FP stores and cbo.zero all insert one speculative entry via
    st_valid; other CBO ops and prefetches decode to non-STORE classes;
    AMOs are excluded by the existing predicate and by store_unit's
    amo-vs-store routing. No STORE-class non-inserting op found, so no
    operation predicate exclusion was required.
  * Exception path: commit_stage handles ex.valid/break_from_trigger
    BEFORE the store_commit_hold block, so exception-bearing stores never
    reach the hold and are never gated by the new presence term.

### Second defect found by the leaf: commit-edge SVA sampling
The extended leaf's first real commit exposed that the concurrent
assertions observing state the commit itself mutates read POST-pop values
under the pinned verilator: bench [edge] monitor showed
head_v=1/tid=10/spec_v=0001 at the commit edge while ooo_commit_is_oldest
reported "handoff took tid 0". Generated model inspection: __Vsampled vars
are re-captured at every __eval invocation and the asserts run in
nba_sequent after the pop's NBA apply, so comb head (and the post-pop
count for underflow) read post-edge. Under IEEE preponed sampling both
assertions were correct; under this tool they fire on every legal commit.
Repaired formulation (translate_off region, same contract): commit-edge
facts (commit_i, empty, headless, tid, head tid) are shadowed into real
flops in the sequent region; speculative_buffer_underflow and
ooo_commit_is_oldest now check only the shadowed registered facts on the
following edge - semantics-agnostic under either evaluation order.

### Leaf extension + result
tb_g6lc_hyp8_memory gained a REAL store_buffer instance (full
stb_insert/stb_commit/stb_drain integration, Hyp8 profile, single-word
dcache request port model, data_gnt held). D-section modeled on
commit_stage (commit_i only when commit_ready_o): T=10 install delay
(ready held low while the entry is in S1, asserted at first ready cycle,
exactly one commit-queue push + one memory request with T's
address/data/be/size), never-inserted tid 15 holds commit_ready_o low for
4 cycles, back-to-back T=11/T=12 committed in order exactly once each,
plus a pre-commit head/tid check and a bench empty-commit check.
All 43 prior checks preserved.
hyp8-memory-own-r11 (closure hyp8-control-r15-closure): HYP8_MEMORY_PASS
checked=74 (43 + 31). Model 3777e9ef...; census WIDTHTRUNC1 UNOPTFLAT2;
runtime/toolchain hashes unchanged.
Earlier diagnostic iterations r6-r10 (one semantic-run repair loop):
is_oldest post-pop sampling proven by [edge] monitor + __Vsampled
generated-code inspection; mirror SVA reproduced the artifact.

### r8 integration build + first smoke (sequence stopped)
hyp8-integration-r8 (closure hyp8-integration-r8-closure, 816 files;
changed vs r7: store_buffer.sv d2de32e831, bench additions carried):
scalar lint rc=0, smt2 lint rc=0, build rc=0. Model sha256
35d9864b11ffdc1ba4e5cf56e4ef61144bb8aa0904cef1384ec28f50b6ca9505;
184-file runtime dep check; census WIDTHEXPAND65 WIDTHCONCAT3
WIDTHTRUNC16 UNSIGNED3 CMPCONST7 SYMRSVDWORD1, %Error0 (identical to
r6/r7). HYP8_ALLOW_OVERLAP=1; unrelated Variane workloads untouched.
Inputs: h34 ed78148c, h33 e2de5833, branch_cancel 84edef64,
tohost 0x80001000.
First smoke hyp8-h34-r5 (sha-verified via --expect-exe-sha256,
--verlib ../runs/hyp8-integration-r8/output/model, budget 50000,
+tohost_addr=0x80001000 +smt_progress +stall_census +hang_dump=1000
+rvfi_cycle_stamp): FIRST SEMANTIC FAILURE - a NEW assertion
g6lc_lsq_slot.sv:302 ooo_lsq_st_live (gen_st_live_assert[1]) fired at
cycle 652: a valid LSQ store-slot entry references a transaction id
whose scoreboard sb_live bit is 0. The r7 store_buffer underflow did
NOT recur; this is a different defect class (LSQ slot liveness vs
scoreboard). Sequence stopped per the stop rule; h33/branch-cancel
not run; firmware witness not reached. No speculative repair
attempted. Raw artifacts: remote-runs/hyp8-h34-r5 + C:/.../cva6-artifacts.


## Batch L - LSQ liveness oracle repair (r9)

### Root cause of the r8/h34-r5 assertion (lead derivation, verified)
g6lc_lsq_slot.sv:302 ooo_lsq_st_live was over-strict relative to the
staged release: commit_st registers into ev_commit_* (g6lc_lsq_event.sv
196-204) one edge after the scoreboard clears sb_live (sb_lifecycle.sv
152 mem_q.issued, cleared at commit-ack ~465), and the LSQ slot releases
by id from the registered event one edge later (g6lc_lsq_slot.sv
268-273). Exactly one cycle of valid-entry + dead-tid exists, inert
(consumers already gate on sb_live: g6lc_lsq.sv 1063/1100/1112), and tid
reuse cannot overlap it (free count from registered sb_issued_cnt_q
makes the slot allocatable at c+1, sb_live rising at the same edge the
old entry clears).

### Oracle repair (g6lc_lsq_slot.sv translate_off only, no logic change)
ooo_lsq_st_live now requires pending release: a valid entry whose tid is
dead must have ev_commit_st_i[c] && ev_commit_id_i[c]==id pending this
cycle (rel_pend_st). New ooo_lsq_st_stale_one_cycle requires such an
entry to be gone (or re-tagged) at the next edge, checked on shadowed
registered facts (dead_st_v_q/dead_st_id_q, same post-edge-sampling-
safe pattern as the store_buffer batch). New allocation-identity
assertions ooo_lsq_alloc_{st,ld}_id_unique: an allocated tid must not
be held by another valid entry unless it is released this cycle.
Load side UNCHANGED with rationale: hyp8 CohPolicy=COH_FILTERED
(g6lc64_hyp8_config_pkg.sv:249) so PHYS_VALIDATE=0 and the
ev_commit_ld_i release path is inactive; load release is ld_release_i,
a combinatorial mask verdict (g6lc_lsq_release.sv:80) with no
one-cycle post-commit staging - the pending-release form does not
apply. Residual: ooo_lsq_ld_live remains over-strict for a load whose
entry outlives its commit waiting on older-store masks (not observed).

### Bench/runner hygiene discovered
The shared bench tb_g6lc_hyp8_control.sv declared g6lc_axi_soc types at
tb_g6lc_hyp8_rom module scope, breaking every non-rom leaf's compile
(discovered on dispatch rerun). tb_g6lc_hyp8_rom is now guarded by
`ifdef G6LC_HYP8_ROM_LEAF; the rom leaf spec gained extra_defines.

### Leaf + r9 build
hyp8-control-dispatch-r3c (closure hyp8-control-r16-closure, 397 files
= r15 + new lsq_slot + guarded bench): HYP8_DISPATCH_PASS checked=16;
revised assertions elaborate and do not fire. Model c8f3fe2c...
hyp8-integration-r9 (closure hyp8-integration-r9-closure, 816 files;
changed vs r8: g6lc_lsq_slot.sv 3e4dee15 only): scalar lint rc=0,
smt2 lint rc=0, build rc=0. Model sha256
729bd57e850a6ed1b62aac6b11d0dd16ebd419d21aab322e882848615c948d7e;
184-file dep check; census WIDTHEXPAND65 WIDTHCONCAT3 WIDTHTRUNC16
UNSIGNED3 CMPCONST7 SYMRSVDWORD1, %Error0 (unchanged).

### First r9 smoke hyp8-h34-r6 - FIRST SEMANTIC FAILURE
Same recipe (sha-verified, budget 50000): no assertion. The program
RAN TO ITS END MARKER - RVFI: auipc/addi compute tohost=0x80001000
(0x800000da/0x800000de), `sw a0,0(t0)` at 0x800000e2 RETIRED @637,
then the standard park loop c.j . at 0x800000e6 from ~cycle 650 to
the 50000 budget. But tohost read 0: [stall-census] dc_req=0 dc_gnt=0
for the entire run and retired st=1 - the committed tohost store never
reached the dcache/memory port. The store was lost between speculative
commit and drain/issue. mc_verdict printed no FAIL (retirement gap 53,
"program exit code 0") because the park loop keeps retiring; the run is
a failure by the standing rule (cookie-free SUCCESS(tohost=0)).
Observations only; not debugged. Sequence stopped: h33/branch-cancel
not run; firmware witness not reached. Raw artifacts
remote-runs/hyp8-h34-r6 + C: cva6-artifacts mirror.


## Batch M - data-PMP same-cycle verdict repair (r10)

### Root cause of the r9 lost tohost store (lead derivation, verified)
Hyp pmp_data_if.sv delayed the LSU data response two registers
(req_q/req2_q) behind the pmp's own registered verdict, but neither
store_unit nor load_unit waits on lsu_valid_o: store_unit posts
paddr_to_sb in VALID_STORE one cycle after the IDLE-cycle request and
load_unit's SEND_TAG consumes the same paddr/ex one cycle after request
(reference one-cycle MMU contract). The +2 presentation made the store
capture a stale/zero paddr - diag evidence: wbuffer write carried
correct data=1/be=0f but pa=0 (hyp8-h34-store-diag-r1), and the PMP
verdict for the access also arrived two cycles late (precision hole).
The reference core/pmp/src/pmp_data_if.sv data side is fully
combinational: lsu_valid_o=lsu_valid_i, lsu_paddr_o=lsu_paddr_i,
exception from a combinational pmp on lsu_paddr_i.

### Repair (pmp.sv / pmp_data_if.sv / load_store_unit.sv)
pmp.sv gained REG_VERDICT (default 1 = the existing registered request
boundary; 0 = reference combinational compare feeding the same
entry-match/allow logic on live inputs). pmp_data_if.sv gained
DATA_VERDICT_STAGES (legal 0/2, else elaboration $error): 0 = reference
contract verbatim (comb pass-through + comb data verdict on
lsu_paddr_i/ld_st_priv_lvl_i/lsu_is_store_i, tval=lsu_vaddr_i,
gva=ld_st_v_i); 2 = the staged implementation preserved verbatim under
generate with its comment corrected to state the consumer contract it
requires (wait on lsu_valid_o, route by requester - the current LSU
does not). The fetch areq path is unchanged (icache uses its own
fetch_valid handshake). The translate_off locked-entry assertions are
unchanged (data_allow_o is module-scope in both modes; comb mode
compares the current-cycle request). load_store_unit.sv:573 passes
.DATA_VERDICT_STAGES(0) explicitly with the contract comment.
Instantiation audit: pmp_data_if only at load_store_unit.sv:573;
pmp also at g6lc_ptw.sv:368 (i_pmp_ptw, keeps default registered
boundary - its comment relies on the +1 verdict riding the PTW
grant/lookup cycles) and the fetch-side i_pmp_if inside pmp_data_if
(default unchanged). No other behavior changed.
Leaf: new tb_g6lc_hyp8_pmp (HYP8_LEAF=pmp) - actual pmp_data_if with
the hyp8 config, same-cycle checks after #1 settle with no clock
between request and check: all-OFF M-mode pass-through; entry0 NAPOT
RW 0x8000_0000/2GiB + S-mode: store 0x80001000 no ex, store/load
0x00001000 -> ST/LD_ACCESS_FAULT same cycle with tval=vaddr;
lsu_valid_i=0 -> no exception. hyp8-control-pmp-r1 (closure
hyp8-control-r17-closure): HYP8_PMP_PASS checked=14.
Timing debt recorded: the data PMP verdict is back on the LSU request
cone (reference structure); a staged verdict needs an explicit
translation-response handshake in load_unit/store_unit (future work).
Linux-mode risk flagged for Sv39: g6lc_mmu TlbStages=3 answers the
small TLBs two cycles after the access while lsu_dtlb_hit_o is
documented same-cycle - bare-mode OpenSBI does not exercise it; not
changed.

### r10 build + smoke sequence
hyp8-integration-r10 (closure 816 files; changed vs r9: pmp.sv,
pmp_data_if.sv, load_store_unit.sv): lint rc=0 x2, build rc=0. Model
34374f4d1df100f476f78b627eed624b4a6c3f5feaa27be69552c516c2025d5d;
census unchanged (WIDTHEXPAND65 WIDTHCONCAT3 WIDTHTRUNC16 UNSIGNED3
CMPCONST7 SYMRSVDWORD1, %Error0).
hyp8-h34-r7: FIRST SMOKE PASS - SUCCESS (tohost = 0) after 656 cycles,
terminated at 644, rc=0, mc_verdict clean. The tohost store now reaches
the write port with the correct pa.
hyp8-h33-r1: FIRST SEMANTIC FAILURE - g6lc_lsq_slot.sv:350
ooo_lsq_ld_live (gen_ld_live_assert[0]) fired @490. Discriminating
read (RVFI): last retire is the first store->load pair's store
sd t0,0(s0) mem 0x80001050=0x1122334455667788 @439; NO load had
committed when the ld entry went dead-tid. Consistent with the
allocated-but-not-yet-issued window: the store's commit freed the tid,
the following load's LSQ alloc reused it while sb_live had not yet
re-asserted (sb_live rises at issue, not at LSQ allocation). Same
over-strict-oracle class as the store side, at the START of tid life;
whether the ld entry's tid equals the freed store tid is not visible
in this trace (would need an LSQ probe). Not debugged; branch-cancel
not run; firmware witness not reached. Raw artifacts
remote-runs/hyp8-h33-r1 + C: mirror.

### Batch N - wt_dcache DcacheHitExtra=0 arm + real forwarding leaf (STOPPED: both variants fail)

Scope delivered:
- wt_dcache_ctrl.sv (hyp, sha 0991443b2c7f98f2): restored the reference
  DcacheHitExtra==0 FSM arm under `DCACHE_HIT0` (generate-selected, +2 arm
  byte-identical under gen_fsm_hit2); vld_data_d uses the reference
  `rd_req_q ? rd_vld_bits_i : vld_data_q` in the 0 arm; added the
  elaboration check `DcacheHitExtra inside {0,2}` ($error). Tier/notice
  headers preserved.
- tb_g6lc_hyp8_control.sv leaf `tb_g6lc_hyp8_dcache` (HYP8_LEAF=dcache,
  sha 3983596e5e0924e0): real wt_dcache (NumPorts=3, P_LD=1,
  P_ST=NumPorts-1), single-outstanding memory model (MEM_LAT=4,
  store-through shadow, line-load returns). Cases: store->load forward at
  distances 0..4 after data_gnt (D0..D4), byte-merge (lb0/lb7/lh4,
  sb-merge, ld), store coalescing (sd + sb +1 + sb +7 -> ld), literal
  expectations. Variant select: -DG6LC_HYP8_DCHX0 for DcacheHitExtra=0,
  default = current Hyp8 (2); identical bench code both runs.

Bench driver defects found and FIXED during leaf bring-up (bench-only):
1. Load driver: mid-cycle task pokes on the combinational grant moved
   request/tag phases off FSM boundaries (phantom accept -> parked READ,
   D3_NO_GNT). Replaced by an edge-synchronous LDS FSM (REQ->TAG->RSP)
   matching load_unit's registered protocol.
2. Store driver: store gnt is REGISTERED and stays high the whole grant
   cycle; the task saw the previous store's stale gnt and dropped
   data_req in the same cycle -> the two C_COAL byte stores vanished
   before any edge (all three [stg] prints at c=368). Replaced by an
   edge-synchronous accept FSM. With the fix, all three C stores land
   (verified in wbuffer_data).

DECISIVE structural finding (leaf evidence, remote runs
hyp8-control-dcache-dchx0-r16 and hyp8-control-dcache-dchx2-r2):
g6lc_hyp_rr_arb_tree (the rd-port arbiter in wt_dcache_mem) is a QUEUED
arbiter: gnt_o pulses at request CAPTURE into a 2-deep queue while
req_o/idx_o reflect the queue HEAD, which pops at service. The read-side
machinery assumes grant-at-service (upstream comb rr_arb_tree):
- mem captures compare operands (bank_idx_q/bank_off_q/cmp_en_q) at
  rd_acked = head POP, compare results belong to the popped request;
- the ctrl's verdict runs at a FIXED latency after its capture-grant
  (0-arm: READ = gnt+1; +2 arm: READ_V after the staged pipeline).
Whenever the pop is not aligned with the capture (queue occupied by a
port-2 store tag-check, or rd_port_busy), the verdict consumes compare
results belonging to ANOTHER request -> stale-address forward merge.

Evidence, DCHX0 (r16): B_LB0 (ld @0x1090) verdict used
wbuffer_cmp_addr=0x1070 (bank_idx_q=07): during the accept cycle
rd_ack[1]=1 (port1 captured) while idx_o=2 (port-2 tag-check @idx07 was
the popped head). Forward merge hit the leftover 0x1070 entry -> load
returned 0x1122334455667788, expected a5a5c3c3deadbeef. FAIL B_LB0_DATA.
D0..D4 and B_MERGE pass only because every earlier store wrote the same
data (stale-cmpa invisible).

Evidence, DCHX2 (r2): same queued-arb skew under the +2 staging - B_LB7
(ld @0x1097) returned 0x1122334455667788: the T1 compare snapshot
sampled operands belonging to the port-2 pop (cmpa=0x1050,
wrdata=1122..) while the live merge for cmpa=0x1097 already showed the
correct a5a5c3c3deadbeef one cycle later. FAIL B_LB7_DATA.

DECISION (per handoff rule): BOTH variants fail the forwarding leaf ->
Hyp8.DcacheHitExtra NOT changed (stays 2). No integration r11, no
smokes, no firmware witness. The defect is in the rd-port
queued-arbiter composition (grant-at-capture vs verdict-at-fixed-delay),
shared by both arms; it plausibly also explains the h33 forward miss
(tid17 ld returned 0 while the store's data sat in the wbuffer/fixup).

Open follow-ups recorded in AGENTS-todo:
- rd-port arbiter/verdict contract: either service-timed rd_ack (grant
  at pop) or response routing keyed to the request's pop, so each ctrl
  verdicts on its own compare; recheck DcacheHitExtra choice after.
- +2 staging gaps observed earlier remain open until the arbiter
  contract is resolved (wbuffer->fixup T1 visibility, refill response
  alignment).
- h33-r1 ls dead-tid residue (ooo_lsq_ld_live @490) still unresolved -
  may be coupled to the missed forward (entry dwait bookkeeping) or the
  allocated-before-sb_live oracle window; revisit after rd-path fix.

Leaf debug aids kept, all sim-only: in-ctrl [rdc] trace under
`ifdef G6LC_HYP8_DCTRL_TRACE` inside translate_off; bench [evt]/[wbx]/
[arb]/[mem]/[stg] monitors in tb_g6lc_hyp8_dcache (bench scope).
r10 model (34374f4d...) untouched; unrelated models untouched; nothing
committed.

=== Batch N resolution: rd-port arbiter contract fix (lead handoff) ===

Fix applied (option A): wt_dcache_mem.sv i_rr_arb_tree replaced with the
vendor common_cells rr_arb_tree (already in Flist.g6lc_hyp8:97; same
params as reference: NumIn=NumPorts, DataWidth=1). gnt_o is now the
gnt_i-qualified same-cycle service grant, so rd_ack_o coincides with the
SRAM access the ctrl arms verdict on. The queued cell
(hyp_cells/g6lc_hyp_rr_arb_tree.sv) remains in the flist but has ZERO
instantiations after this audit.

Arbiter audit (every instance, live-signal-indexing = queued-unsafe):
- wt_dcache_mem.sv:349  i_rr_arb_tree  -> vendor (THE defect site;
  rd_ack gates verdict + indexes live rd_idx/rd_off/rd_tag_only)
- wt_axi_adapter.sv:278 i_rr_arb_tree  -> already vendor since M3
  bring-up (comment cites H40: AR issued with meta-fifo never pushed)
- wt_dcache_wbuffer.sv:1623 i_tx_id_rr -> vendor (tx_id indexes live
  tx_vld/tx_stat; stale slot hazard)
- wt_dcache_wbuffer.sv:1921 i_dirty_rr -> vendor (dr_mux carries live
  wbuffer_q payload; byte-merge-after-capture hazard)
- wt_dcache_wbuffer.sv:1943 i_clean_rr -> vendor (check_ptr indexes live
  array for check writeback)
- g6lc_core.sv:4021     pc fifo arb    -> pre-existing vendor, unchanged
- APU tree: no g6lc_hyp_rr_arb_tree instantiations.
All converted sites were queued-unsafe (each indexes live requester
signals or treats gnt_o as the access cycle); none were queued-safe.

Leaf rerun (identical bench, closure r18-based):
- hyp8-control-dcache-dchx0-r18: HYP8_DCACHE_PASS checked=25 dchx=0
- hyp8-control-dcache-dchx2-r3:  HYP8_DCACHE_PASS checked=25 dchx=2
D0-D4 distances, B_LB0/B_LB7/B_LH4, B_MERGE, C_COAL all correct under
BOTH variants -> DECISION per lead rule: DCHX2 passes -> keep
Hyp8.DcacheHitExtra=2 (unchanged; no issue-leaf rerun needed since the
profile did not change). The queued-arbiter contract was the defect,
not the +2 hit staging; the earlier +2 visibility/refill observations
were the same mechanism seen through the staged arm.

Integration r11 (closure = r10 + wt_dcache_ctrl/mem/wbuffer, 816 files):
lint scalar rc=0, smt2 rc=0, build rc=0. Model sha256
4d70d7bb79db93c776df9deb0570ab4707ac2d8e98d04222090247a405fe8894.
Lint census (scalar): WIDTHEXPAND324 WIDTHTRUNC87 WIDTHCONCAT3
LITENDIAN123 IMPLICITSTATIC4 STMTDLY5 UNSIGNED9 CMPCONST10
CASEINCOMPLETE9 LATCH3 COMBDLY1 SYMRSVDWORD1 %Error0.
Inputs: h34 elf 47c56adb, h33 elf fc784eaa, branch_cancel 7a93c099,
tohost 0x80001000.

Smokes (model sha-verified via --expect-exe-sha256):
- hyp8-h34-r8: PASS - SUCCESS (tohost=0) after 656 cycles, rc=0.
- hyp8-h33-r2: FIRST SEMANTIC FAILURE - ooo_lsq_ld_live
  (g6lc_lsq_slot.sv:350, gen_ld_live_assert[0]) fired @476, rc=255.
  branch-cancel and firmware witness NOT run per stop rule.

h33-diag-r2 (immutable r11 model, +smt_flow_trace +lu_replay_trace
+ld_trace, budget 520) - tid-17 evidence for the dead-tid residue:
  alloc  c=439 id=17 pc=80000026 ld t1,0(s0)
  LU-REQ c=457 idx=050 tid=17
  LU-RSP c=460 rdata=1122334455667788   (FORWARD NOW CORRECT - arbiter
         fix carries into the full core; was rdata=0 in diag-r1)
  LU-WB  c=461 ex=0
  retire c=462 id=17 valid=0 drop=0 ex=0 replay=0
  wb     c=462 data=1122334455667788
  assert @476 (14 cycles post-commit; entry still valid, sb_live=0)
No flush/cancel/replay/mem_viol for tid17; the only control line is
c=330 flush_unissued=1 mispredict=1 (pre-alloc redirect). No LSQ
release events exist in the trace vocabulary (nothing prints release),
so the release boundary is unobserved in trace; the evidence shows only
that no ld_release fired for a normally-completed, committed load for
14+ cycles. With forwarding correct, the residue is decoupled from the
D$ defect: under Batch L's analysis ev_commit_ld_i is inactive in
COH_FILTERED and ld_release_i is the only (combinatorial) release path
- whatever gates it did not fire. One-cycle staged-release oracle
explanations cannot cover a 14-cycle residue; this is now a candidate
RTL lifetime defect (or an oracle that does not match the intended
load-reclamation contract). Oracle unchanged per lead instruction.
Artifacts mirrored to C:\...\cva6-artifacts\ for dchx0-r18, dchx2-r3,
integration-r11, h34-r8, h33-r2, h33-diag-r2. r10/r11 models immutable;
unrelated models untouched; nothing committed.

=== Batch N follow-up A: lint census scope resolution ===

The r10 "WIDTHEXPAND65 no LATCH" figure was a different census scope
(dedup/site count, not the runner's raw log census). At the SAME scope
(lint-scalar.log, results.json warnings): r10 = WIDTHEXPAND326 +
LATCH3 + IMPLICITSTATIC4 + STMTDLY5 + COMBDLY1 + CASEINCOMPLETE9;
r11 = identical except WIDTHEXPAND 326 -> 324 (two sites removed by the
Batch N arbiter/logic change). No new warning classes. The 3 LATCHs are
all in tier-U vendor APU rtl axi_riscv_amos_alu.sv:28 (cas_cmp,
cas_swap, cas_mem) - upstream PULP atomics ALU, untouched by Batch N,
present identically in r10. No latch fix needed or applied.

=== Batch N follow-up B: +lsq_trace probe; h33 dead-tid residue ===

Probe (sim-only, translate_off, +lsq_trace, prints only c<2000):
- g6lc_lsq.sv: per-valid-load change line (i/id/done/unres/dwait/rel),
  dwait_set events, nonzero st_resolved/st_data_res masks, ld_alloc
  (idx/id/alloc_older), and complete_valid_i (input) + ev_complete
  (staged output) per wb port.
- g6lc_lsq_event.sv: [lsq-ev] per-port input/output boundary print
  (in_v/in_id/in_st/canc/flush + out_v/out_id).
- hyp8_tb.cpp: "lsq_trace" added to the plusarg allowlist (the harness
  rejects unlisted plusargs; first diag run died on that).
Diag model hyp8-integration-r12-diag-d (r11 closure + probe +
harness allowlist), build rc=0, model
611e5a26f20f872309cb21cfaeb07979e134dafad9e099086501bc41d7dd175f (the
r12-diag-c build - tag d = re-run of same closure for the c model; the
probe/harness sources are identical across b/c/d builds, lint census
unchanged vs r11, probe adds 0 warnings).

hyp8-h33-lsq-diag-r1d (same h33 ELF, budget 500, +lsq_trace
+smt_flow_trace +ld_trace), verbatim [lsq]/[lsq-ev] window 401-476:

  c=401 complete_in p=0 id=12 is_st=0 canc=0
  c=402 ev_complete  p=0 id=12 is_st=0
  c=408 complete_in p=0 id=13 ...        c=409 ev_complete p=0 id=13
  c=416 complete_in p=0 id=14 ...        c=417 ev_complete p=0 id=14
  c=423 complete_in p=0 id=15 ...        c=424 ev_complete p=0 id=15
  c=428 st_resolved=00010000   st_data_res=00010000   (tid16 addr+data)
  c=431 complete_in p=1 id=16 is_st=1    c=432 ev_complete p=1 id=16
  c=434 st_resolved=00010000   st_data_res=00010000   (tid16 commit)
  c=439 ld_alloc p=0 idx=0 id=17 older=00000000   <- NO older unresolved
  c=440 ld i=0 id=17 done=0 unres=00000000 dwait=00000000 rel=0
  c=447 dwait_set v=0 id=17 mask=00000000         <- dwait set EMPTY
  c=462 complete_in p=2 id=17 is_st=0 canc=0      <- input fired
  c=462 [lsq-ev] w=2 in_v=1 in_id=17 in_st=0 canc=0 flush=0 out_v=0
  (smt-flow: wb c=462 port=2 id=17 data=1122334455667788 correct;
   retire c=462 id=17)
  c=476 ooo_lsq_ld_live fires; entry still valid.

FINDING: ld_release stayed low because done=0 - both masks were already
EMPTY at alloc (older=0) and the verdict's dwait set was empty (the
arbiter fix means the store's data was already visible). done is set
only by ev_complete (is_st=0) in g6lc_lsq_slot.sv:252-258. The load's
completion DID reach the LSQ boundary - complete_valid_i[2]=1 id=17
is_st=0 at c=462 - and i_event's own in-line probe saw it (in_v=1,
canc=0, flush=0 at the same edge). But ev_complete_valid_o[2] never
asserted on any cycle: every other port shows the in@N -> out@N+1
pattern (w=0 x7, w=1 x1); w=2's single occurrence produced nothing.

This is mechanically inconsistent with the gen_cmp flop (always_ff:
ev_complete_valid_o[2] <= complete_valid_i[2] && !cancelled && !flush;
all three inputs probed favorable at the capture edge). The probe print
itself uses the same sampling class that has produced pinned-Verilator
ordering artifacts before (post-edge-visible comb/flop levels that a
same-edge flop samples differently). The discriminating open point: was
complete_valid_i[2] (wb_valid_i[2] = wt_valid_ex_id[LOAD_WB] =
load_valid_o, a shift_reg flop output, NrLoadPipeRegs=1) high for a
full preponed cycle as the flop requires, or only in a post-edge window
the probe saw but the flop did not? W=0/W=1 valids (flu_valid_o,
store_valid_o paths) behave identically as 1-cycle pulses yet their
ev_complete fired - so a pure pulse-width story does not discriminate.
Unverified candidate mechanisms, in order of consistency with the
evidence: (1) pinned-Verilator multi-eval ordering on the input comb
settle (needs a non-pinned sim or wave dump to confirm); (2) a real
capture-condition defect visible only under a combination not present
in the probes. Oracle and release logic unchanged per instruction.
Artifacts: remote-runs/hyp8-{integration-r12-diag-d,h33-lsq-diag-r1d}
mirrored to C:\...\cva6-artifacts\.

=== Load commit-reclamation (architectural release) + oracle + ev-miss evidence ===

RTL (g6lc_lsq_slot.sv): the by-id commit-ld release was gated inside
if (PHYS_VALIDATE) at lines 243-246 -- dead in the WT config
(COH_FILTERED -> PHYS_VALIDATE=0), so a load entry's lifetime depended
entirely on the completion event being captured. Hoisted the release
loop out of the PHYS_VALIDATE block, unchanged semantics otherwise:
ev_commit_ld_i[c] && id match -> ld_d[i].valid=0, unconditional (the
phys addr/size updates stay gated as before). ev_commit_ld is
commit_ack && fu==LOAD staged one edge in g6lc_lsq_event, so a committed
load entry now always dies one edge after commit -- mirrors the store
contract, removes the single-point dependency on complete capture.
No consumer relies on a committed load entry persisting: violation CAM,
phys_pending/replay and the checked-publish path all gate on
sb_live_i[tid] which clears at commit, and checked_q is a per-tid
sticky flop independent of the entry.

Oracle (translate_off, g6lc_lsq_slot.sv): ooo_lsq_ld_live replaced with
the pending-release form (valid && !sb_live |-> rel_pend_ld ||
ld_release_i; rel_pend_ld = OR_c ev_commit_ld_i[c] && id match), plus
ooo_lsq_ld_stale_one_cycle via dead_ld_* shadow flops (same post-edge-
safe pattern as the store side). alloc_ld_conflict exclusion extended
to !(ld_release_i || rel_pend_ld) -- commit-edge tid reuse is legal.
Store side unchanged.

Evidence retention (g6lc_lsq_event.sv translate_off): per-port shadow
of (complete_valid_i && !cancelled && !flush); if ev_complete_valid_o[w]
does not assert on the next edge, per-port counter increments and an
[lsq-ev-miss] c/w/id line prints (first 8); per-port summary at final.
Non-fatal. The +lsq_trace probes and the hyp8_tb.cpp allowlist entry
stay.

Dispatch leaf rerun (new assertions must elaborate + hold):
hyp8-control-dispatch-r4, closure hyp8-control-r19-closure (r18 + the
three lsq files) -> HYP8_DISPATCH_PASS checked=16, rc=0.

hyp8-integration-r12 (816-file closure = r11 + g6lc_lsq.sv,
g6lc_lsq_slot.sv, g6lc_lsq_event.sv, hyp8_tb.cpp): lint rc=0 x2, build
rc=0; model sha256
89961eafb1dcbf39f35db3560fdccfba7289d9ad8ee71aa58fc6278f90ea5920;
lint-scalar census IDENTICAL to r11 (WIDTHEXPAND324 ... LATCH3 %Error0)
- all changes add zero warnings. Inputs: h34 2d0fb8cb, h33 e54a480e,
branch_cancel 8defb6e4.

Smokes on the r12 model (+lsq_trace armed for the miss counters):
- hyp8-h34-r9: PASS (tohost @656, rc=0). [lsq-ev-miss] w=0..3 all 0.
- hyp8-h33-r3: NEW failure class - not the assertion. The ooo_lsq_ld_live
  residue is GONE; the first store->load pair retired architecturally
  CORRECT (RVFI: x6 = 0x1122334455667788 from 0x80001050; retire @462).
  The program then stalled and budgeted out at 50000 cycles
  ([mc_verdict] FAIL exit 126, rc=120): SB head slot=20 pc=0x80000032
  issued=1 valid=0 for ~49000 cycles; commit dead.
  [lsq-ev-miss] w=0..3 all 0 - the complete-capture miss did NOT recur
  in this model.
- hyp8-branch-cancel-r1, firmware witness: NOT run (stop rule).

Discriminating read (hyp8-h33-hang-diag-r1, +smt_flow_trace +lsq_trace
+ld_trace, same r12 model):
  alloc c=468 port=1 id=20 pc=80000032 insn=00000001 fu=3 rd=0 rs1=0 rs2=0
  -> the stuck head is the FIRST c.nop in program order (addi x0,x0,0).
  id=20 never produces an `operands` line (every other tid does: id18
  @479, id19 @485, id21 @501, id22 @524, id23 @531) and never produces a
  wb line -> allocated but never reached issue_read_operands; no
  cancel/flush/mispredict in the window (last control line c=330).
  id=24 (the SECOND c.nop, alloc c=514 port=1 behind port-0 store id23)
  is resident in IQ[13] unissued at hang - same signature: port-1 alloc
  immediately behind a port-0 STORE alloc. id18 (port-1 bne behind the
  port-0 LOAD id17) issued fine, so the discriminator is not merely
  port-1. Candidates: (a) c.nop/hint decode marks the op in a class the
  IQ never makes ready or that gets popped without operands staging;
  (b) a dispatch drop of port-1 ops behind store allocs; (c) same
  pinned-Verilator stale-read class on an issue_ack/iss_q capture.
  This failure is downstream of the previous one (h33 previously died
  at 476 before reaching it) - not reachable before, not caused by the
  commit-release change which touches only LSQ slot validity.
  [lsq-ev] shows every complete captured this build: tid17's load
  complete fired normally on w=2 (in@462, out@463, ev_complete p=2) --
  the prior-cycle miss did NOT recur; id=19/22/23 completes also in->out.
  tid21 load: complete w=2 in@507/out@508, done=1 rel=1 @509, then idx0
  re-allocated to id=21 @484 (commit-release/early-release path both
  functional).
Artifacts: remote-runs/hyp8-{control-dispatch-r4,integration-r12,
h34-r9,h33-r3,h33-hang-diag-r1} mirrored to C:\...\cva6-artifacts\.
r11/r12-diag models immutable; nothing committed.

=== +disp_trace lifecycle probe -> h33 hang localized to IRO port-1 never-ack ===

Probe (sim-only, translate_off, +disp_trace, c<2000):
g6lc_ooo_dispatch.sv -- [disp] alloc/busyset at dispatch_ack_o (bank=i_iq.asgn,
ent=i_iq.wr_entry, prs/prd, rs*_rdy, ren_int_busy of sources); wbclr on
data_wb_valid (wb ports + commit mirror); grant on i_iq.i_arb win_v&&take_ok;
take=iqi_take, pop=iss_pop, iro=issue_valid_o|issue_ack_i; kill lines for every
real drop class (flush/cancel on staged, presented, and arb win_q/pres_q
records; fpblk; bank-entry vanish without aack); rdy-bit changes per bank
entry. Flag named disp_life_trace (+disp_trace) because the pre-existing
+icf_trace probe already owns the symbol disp_trace. hyp8_tb.cpp: "disp_trace"
added to the allowlist.

Build: hyp8-integration-r13-diag-b (r12 closure + probe; first attempt tag
hyp8-integration-r13-diag died on the disp_trace symbol clash, renamed).
Lint x2 rc=0; scalar census = r12 +1 (WIDTHEXPAND 325 -- the probe's IQE'
cast, sim-only). Model sha256
a7854549fa27fbb0fe159e612d82a04de64a5f97cd5fb045edd1ef367c1b7568.

Run: hyp8-h33-disp-diag-r1, h33 ELF +disp_trace +smt_flow_trace, budget 700,
rc=0 (budget-out, no tohost -- same hang). NOTE: E: hit 100% during the pull;
run-B.log pulled via the proxy `shell` subcommand to C:\artifacts. Disk-full
is an environment issue for subsequent pulls; remote run dir intact.

VERBATIM tids 18-24 (log lines 530-704):
[disp] alloc c=439 p=1 tid=18 bank=5 ent=1 fu=4 rd=0 prs1=38 prs2=32 prd=0 rs1_rdy=1 rs2_rdy=0 rs3_rdy=1 busy_prs1=0 busy_prs2=1   (bne; waits tid17's t1 via prd 32? rs2=prs32... see wbclr)
[disp] rdy c=463 bank=5 ent=1 tid=18 rdy=111   (woken by tid17's wbclr)
[disp] grant c=464 port=0 tid=18 / take c=465 / pop c=466 / iro c=466 v=1 ack=1 / wbclr c=469 prd=0 / retire 469. CLEAN.
[disp] alloc c=468 p=0 tid=19 bank=6 ent=0 fu=2 rd=0 prs1=69 prs2=38 prd=0 all-rdy   (sd @0x2e)
[disp] alloc c=468 p=1 tid=20 bank=7 ent=1 fu=3 rd=0 prs1=0 prs2=0 prd=0 rs1_rdy=1 rs2_rdy=1 rs3_rdy=1 busy_prs1=0 busy_prs2=0   (c.nop @0x32)
[disp] grant c=470 port=0 tid=19 AND grant c=470 port=1 tid=20
[disp] take c=471 port=0 tid=19 AND take c=471 port=1 tid=20
[disp] pop c=472 port=0 tid=19 / iro c=472 port=0 tid=19 v=1 ack=1
[disp] iro c=472 port=1 tid=20 v=1 ack=0  ... ack=0 CONTINUOUSLY through c=686 (end of window) -- never popped, never killed.
[disp] wbclr c=476 port=1 tid=19 prd=0 / wb c=476 / retire c=478 -- last retire ever.
[disp] alloc c=484 p=0 tid=21 bank=0 ent=0 fu=1 rd=6 prs1=69 prd=6 all-rdy  (ld @0x34)
[disp] alloc c=484 p=1 tid=22 bank=1 ent=1 fu=4 rd=0 prs2=6 rs2_rdy=0 busy_prs2=1  (bne waits on ld's prd 6)
[disp] grant/take/pop/iro-ack tid21 port0 @486-488; wbclr prd=6 c=507; tid22 rdy->111 c=508; grant 509/take 510/pop 511/ack1 port0.
[disp] alloc c=514 p=0 tid=23 bank=2 ent=0 fu=2 rd=0 prd=0 all-rdy (sd @0x3c)
[disp] alloc c=514 p=1 tid=24 bank=3 ent=1 fu=3 rd=0 prs1=0 prs2=0 prd=0 ALL ready  (second c.nop)
[disp] grant c=516 port=0 tid=23 AND grant c=516 port=1 tid=24
[disp] take c=517 port=0 tid=23 / pop 518 / iro ack1 @518 / wbclr 522.
   tid24: grant consumed the bank candidate (take_v fired) but iqi_take[1]
   never asserted -- iss_v_q[1] still holds tid20 -> the winner sits in
   win_q/pres_q presenting forever, bank entry (bank3 ent1) un-acked ->
   hang dump's IQ[13] resident. No kill line, no rdy change, no operand wait.
Zero [disp] kill lines in the whole log. [lsq-ev-miss] all 0.

ANSWERS:
- tid20: allocated (bank7/ent1), granted port1 @470, taken @471, STAGED
  (iss_v_q[1]), presented issue_valid_o[1]=1 continuously from c=472,
  issue_ack_i[1]==0 forever. Not killed. Boundary: IRO issue_ack_o[1].
- tid24: NO ready bit is 0 and it waits on NO prd -- allocated fully ready
  (prs1=prs2=prd=0); blocked solely by the occupied port-1 staging slot.
- Stores DO carry rd=0/prd=0 into rename (tids 19,23); busyset prd=0 fires
  per alloc; wbclr prd=0 fires on the wb ports (wb_value_valid is not prd!=0
  gated) while the commit mirror IS prd!=0-gated (no cmt=1 line for prd=0) --
  prd-0 busy aliases across concurrent rd=0 producers, cleared by the first
  prd=0 wb (tid18's @469 while tid19/20 had just set it). False-ready only.

WHY ack[1]==0 (static narrowing, unverified which term): IRO
issue_ack_o[1] = issue_ack_pre[1] & res_admit[1] (nop: not amo, casq is
port0-only, flush=0, stall_i=stall_acc_id=0, oa_en=0 for renamed so
stall_raw[1]=ss_raw[1]=0 as rs==0 excluded). So issue_ack_pre[1]=0 via
fu_busy[1]=fus_busy[1].alu (inherited fus_busy[0].alu = !flu_ready_i |
|mult_valid_q; port0 stale-record effects -- the '1 cases -- only hold
while port0's last record is CF/ALU/CSR/MULT/FPU; post-518 stale=STORE
clears them) OR res_admit[1]=0 (reserved_q/div_live_q wedged). flu_ready
was proven 1 at c=511 (bne tid22 acked) -- a stuck mult_ready/flu_ready
drop after ~512 is possible but invisible (issue_stall prints only on
port0 stalls; port0 never stalled so it never printed). Also possible:
same pinned-Verilator stale-read class on an IRO input. The FIRST-EVER
port1 presentation in the run is the one that never acks (only 2 port1
grants total: tid20, tid24) -- nothing ever issued on port1.

## Batch — IRO stale-lane throttle repair + issue-leaf IRO harness (hyp8-integration-r13)

Root cause accepted from disp-diag: `issue_read_operands.sv` structural_hazards
applied the in-order dual-issue `unique case (issue_instr_i[p-1].fu)` throttle
without `issue_instr_valid_i[p-1]`. Under OoO a drained lane keeps its last
presented record; a stale fu==STORE held fus_busy[1]='1 forever, so the first
port-1 presentation (tid20 c.nop) could never ack and commit starved.

### RTL diff (all in issue_read_operands.sv unless noted)
- structural_hazards (~694-765): `fus_busy[p] = fus_busy[p-1]` inheritance kept
  (global unit-busy terms); port-0-only csr/cvxif lines unconditional; the
  `unique case` now inside `if (issue_instr_valid_i[p-1])` -- the throttle
  applies only while the older lane presents a valid instruction this cycle.
  Comment updated to state the valid-qualified contract.
- is_alu_bypass (~615): both-lanes-valid qualifier added -- a same-cycle
  forward is only defined while the port-0 producer issues this cycle.
- use_alu2 (~633): port-1 FU check qualified with issue_instr_valid_i[1]
  (dead under Hyp8 WbReserve=1, correct for other profiles).
- gen_ssraw c1/c2/c3 (~1103-1116): earlier-lane rd comparisons qualified
  with issue_instr_valid_i[e]; me_* keep masks already gated via e_same.
- assign_fp_raddr_pack (~1863): port 0 keeps the shared FP raddr only while
  it presents a valid FP-class record; a drained lane's stale fu/op can no
  longer steal port 1's FPR read.
- Audited and left unchanged (already valid-gated or acceptance-side, not
  stale-field reads): cvxif_instruction_valid, casq_active (1224),
  res_offer/res_accept (1620-22), mult/csr stall terms, LR/SC lr_sc_pair
  (gated on fwd_i.still_issued), commit/RVFI read paths.
- g6lc_rename_recover.sv (~697): translate_off assertion
  `disable iff (!rst_ni) !busy_q[0]` -- physical int p0 (the x0 mapping)
  must never be busy. Source inspection confirmed p0 cannot be set today:
  need_rd excludes int rd==0 (dispatch), g6lc_rename_read allocs int prd
  only under need_rd_i, freelist reset/repair starts at index 1, WB busy
  clear is wb_prd!=0-gated, commit mirror excludes 0. Assertion is
  belt-and-braces; FP p0 (fbusy_q) intentionally unchecked.

### Leaf (tb_g6lc_hyp8_issue, tb_g6lc_hyp8_control.sv)
Real issue_read_operands instantiated as i_iro (inert-side pins tied) with
three directed checks over the staged-record seam:
- IRO_STALE_STORE_P1_ACK: STORE acked on port 0, lane drains with stale
  fu==STORE retained; valid ALU c.nop-class on port 1 must ack (<=4cy budget).
- IRO_STALE_ALU_P1_ACK: same drain on an ALU record.
- IRO_PAIR_*: both lanes live ALU -> port1 NOT acked same cycle (positive
  throttle), port1 acks after port 0 drains even though stale record stays
  fu==ALU.
Bench config fix: leaf configuration() set NrRgprPorts=2 (OPI=1, illegal --
  fired the OPERANDS_PER_INSTR assert and double-drove raddr_pack_base);
  corrected to 4 (NrIssuePorts*2, matching build_config's derivation).
runner: build_config_pkg.sv + g6lc_rvc_enc.sv added to leaf source lists.

Results: hyp8-control-issue-r15  HYP8_ISSUE_PASS checked=74
         hyp8-control-dispatch-r5 HYP8_DISPATCH_PASS checked=16
         (p0 assertion elaborates and holds under the real dispatch tree)

### Integration: hyp8-integration-r13
Closure: C:\Users\etcim\cva6-artifacts\closures\hyp8-integration-r13-closure
(816 files, manifest-hashed; carries the IRO fix, p0 assert, commit-ld
release, ev-miss counters, +lsq_trace and +disp_life_trace probes).
lint scalar rc=0, smt2 rc=0, build rc=0 (228s).
Model sha256 5975665f227324966a85d6857a552f6f72c252b0b94f17e1a3aecb4fce1118ed
Scalar census (lint-scalar results scope): WIDTHEXPAND325 WIDTHTRUNC87
WIDTHCONCAT3 LITENDIAN123 IMPLICITSTATIC4 STMTDLY5 UNSIGNED9 CMPCONST10
CASEINCOMPLETE9 LATCH3 COMBDLY1 SYMRSVDWORD1 %Error0.
LATCH3 = pre-existing tier-U vendor baseline
(axi_riscv_amos_alu.sv:28 cas_cmp/cas_swap/cas_mem), unchanged.
Inputs: h34 4f24462e h33 fe27bba2 branch_cancel 4ce853ce tohost 0x80001000.

### Smokes (ordered; model pinned via --expect-exe-sha256)
- hyp8-h34-r10: PASS -- terminated after 644 cycles, all mc_* verdicts clean,
  [lsq-ev-miss] summary 0/0/0/0. (First attempt ran to budget because the
  local nm produced no +tohost_addr; rerun with explicit
  +tohost_addr=0x80001000 -- invocation artifact, not a verdict.)
- hyp8-h33-r4: FIRST SEMANTIC FAILURE -- but a new one, and the port-1
  deadlock is gone: program advanced past the old hang point (all issues
  correctly serialized in-order on port0 while both lanes valid; the stale-
  lane path no longer blocks) through the st->ld forward pair with CORRECT
  data (tid19 lbu wb c=725 data=0x88 = stored LSB), tid18 sd retired at 727.
  At c=741: scoreboard.sv:269 "Commit acknowledged but instruction is not
  valid". branch-cancel-r1 and firmware witness NOT run per stop rule.

### Failure analysis (one discriminating read: hyp8-h33-r4-diag, same model,
### +smt_flow_trace +disp_trace, budget 3000)
Evidence: tid19 (lbu @0xa4) alloc c=678, iro ack 682, wb c=725 port=2 with
correct forwarded data; tid18 retires 727; NO events 728-740 (no alloc,
kill, control, cancel); commit_ack_i[0] fires at 741 and the SVA sees
commit_instr_o[0].valid=0. tid19 was the LAST allocated slot (no allocs
after c=678 -- next fetches never arrived at dispatch).

Mechanism check (each link source-verified):
- commit_ack_o = fire is a SAME-CYCLE decision (commit_stage.sv:195,551):
  fire[0] requires commit_instr_i[0].valid && bundle_valid[0] OR the
  commit_drop_i[0] path. An ack on a truly-invalid non-dropped slot is a
  logical contradiction in coherent simulation.
- tid19 was never cancelled (zero [disp] kill / control / replay lines;
  cancelled=0 at its wb) -> the drop path cannot explain the ack.
- mem_q[19].sbe.valid was set at wb c=725; only cf_hit (an ack -- none
  printed) or flush clears it. ld_checked_o is sticky by design
  (g6lc_lsq.sv:1013 "Sticky until the tid is re-allocated, cancelled, or
  flushed so a freed entry cannot retract it") -- the commit-load release
  cannot retract it.
- Therefore at the 741 edge the coherent state had rec_valid=1 on sel=19;
  the assert can only observe valid=0 if its commit_instr_o[0].valid term
  (comb: sel_oh=1<<commit_ptr_q -> sel_flat masked-OR -> sel_sbe.valid &&
  ld_ok) was re-evaluated AFTER the same edge's NBA updates -- the ack's own
  cf_hit frees mem_q[19] AND advances commit_ptr_q 19->20; a post-edge
  recompute then reads slot 20 (NEVER allocated -> sbe.valid=0).
- Consistency check on why only tid19 trips it: every earlier commit had a
  live next head (post-edge rec_valid stays 1); tid19 was the last live
  slot -> the post-edge read lands on a free slot. h34 survives because
  its `j done` spin keeps allocating, so a live next slot always exists.

Assessment: signature matches the pinned-Verilator sampled-value/eval-order
artifact class already documented for this project (store_buffer SVA
artifacts, g6lc_iq_arb r9, g6lc_lsq_event w=2 missed capture). This is the
first instance where the artifact is an SVA READ of a comb function whose
inputs legitimately change at the same edge -- inherent race between the
ack event and the freed/next-head selection it reads. Unverified link:
Verilator's actual sampling order for this specific property (consistent
with every observed fact; the alternative requires an unobservable
cancellation or a commit_ptr advance without an ack, both contradicted by
the trace). Discriminating evidence if pursued: a per-cycle print of
commit_ptr/commit_sel_slot/rec_valid terms at commit_ack, or a
non-pinned-simulator run of the same ELF.

## LSQ waited-mask repair + scoreboard drop-commit contract (hyp8-integration-r14)

### Replay source (established)
h33 tid19 (`lbu` @0x800000a4, alloc c=678, issued c=682, wb c=725 with the
correct forwarded byte 0x88 from older store tid18) was cancelled+replayed
by the LSQ violation CAM's `v_viol` path: store tid18 was allocated older
and still address-unresolved when tid19 allocated, so tid19 tracked it in
its alloc snapshot; the load's verdict completed while the store was
unresolved; when the store's FIRST address-resolution event later reached
the violation CAM the tracked load was named as a violator -> false
memory-order violation -> replay flush. Contract breach: the load had
been ordered against the store (it waited), so the store's first
resolution cannot be a violation against it.

### CAM trigger terms
Trigger: `ev_addr_valid[u] && ev_addr_is_st[u] && !cancelled` only
(g6lc_lsq.sv:509); store data (`ev_data`), commit (`rc` in st_resolved)
and `ev_phys` do not re-fire the CAM. Candidate set pre-fix = every live
overlapping older-checked load leaf.
Post-fix gating, three identity suppressions of loads that tracked the
eventing store:
- bank leaves: `.match_i = {vv_match_q, vio_match_q & ~vio_waited_q}` with
  `vio_waited_q[u][i] <= ld_waited[i][ev_addr_id[u]]` snapshotted at the
  event edge (g6lc_lsq.sv:444-450, 603, 853);
- same-cycle load events: `!ld_waited_on(ev_addr_id[v], ev_addr_id[u])`
  (g6lc_lsq.sv:523);
- dedup query leaf: `!ld_waited_on(ev_query_id, ev_addr_id[u])` (:540).
`ld_waited` is the new sticky mask in g6lc_lsq_release (`waited_q`,
:34-41,119-143): OR of the alloc-time unres snapshot and every verdict
data-wait (`vld_dwait`); cleared only on store commit/cancel/flush or
entry death -- never on resolution.

### scoreboard.sv:269
`commit_ack_i[i] |-> (commit_instr_o[i].valid || commit_drop_o[i])` with
the hyp8 contract comment: a cancelled load's ld_checked bit may be
released before its drop-commit, so the drop path is validity-agnostic by
design; strict validity retained for non-drop commits via the disjunction.
Applied on port 0 and the cp generate (scoreboard.sv:269-276).

### Leaf
Dispatch leaf sections E (tracked-store suppression: older unresolved
store + earlier load verdict -> no violation) and F (untracked older
store still flags, names load id) added to tb_g6lc_hyp8_control.sv;
`HYP8_DISPATCH_PASS checked=20` (tag hyp8-control-dispatch-r9, closure
hyp8-control-r24-closure). The dwait-on-data variant (store addr resolved,
data late) is NOT expressible in the dispatch leaf: dispatch drives
`st_data_v = agu_valid` atomically with the store's address event
(g6lc_ooo_dispatch.sv:1197). Direct-LSQ bench needed for that case
(ported-hyp8 `tb_g6lc_lsq` work item).

### r14 build
Closure `cva6-artifacts/closures/hyp8-integration-r14-closure` (816
files). First r14 attempt failed full-top lint: the closure missed
`corev_apu/apu/g6lc_apu_fault_sup.sv` (relative `include "../apu/..."`
from g6lc_testharness.sv:2385); root cause was a stale manifest that
predated the include-resolution pass output. Rebuilt closure -> the INCRE
fixpoint now resolves it (plus ~180 normalized-key entries, most already
on disk under incdir keys). Then: lint scalar rc=0 (WIDTHEXPAND 326,
WIDTHTRUNC 87, LATCH 3 -- the known tier-U axi_riscv_amos_alu baseline,
%Error 0), lint smt2 rc=0, scalar build rc=0 under
HYP8_ALLOW_OVERLAP=1 / jobs=2 / threads=1; model sha256
`2ef79f265419bbbda1c1a9edda6ea15db274339f8bea6caa4b10f815c55ddd63`,
runtimeDepFiles=186 checked.

### Smokes (run via proxy `run --verlib hyp8-r14`, /opt/testharness/work symlink
-> runs/hyp8-integration-r14/output/model; remote binary sha256-verified
by hand after `--expect-exe-sha256` mangled through the ssh layer)
- Invocation lesson: the proxy `run` computes `+tohost_addr` via LOCAL nm;
  on Windows it is absent -> the DTM tohost watch is never armed and the
  run budgets-out with "no tohost verdict" even though the program's
  tohost store retires identically. h34-r11 was exactly this artifact
  (identical first 55 retires vs r10, then post-tohost `j .` spin).
  All smokes need `--plusarg +tohost_addr=0x80001000` (results.json
  records the per-ELF tohost).
- hyp8-h34-r11b: `*** SUCCESS *** (tohost = 0) after 656 cycles`
  (rvfi_tracer 644) -- PASS, identical path to r10. ev-miss 0/0/0/0.
- hyp8-h33-r5: `*** FAILED *** (tohost = 128) after 517 cycles` -- STOP,
  first semantic failure. No SVA fired (the widened scoreboard assertion
  held through the earlier commit window); [lsq-ev-miss] 0/0/0/0. RVFI
  trace: the FIRST st->ld pair in the program -- `sd t0,0(s0)` ->
  `mem 0x80001050 = 0x1122334455667788` at 0x80000022 -- then
  `ld t1,0(s0)` (insn 0x00043303, distance-0 check) at 0x80000026
  returned `x6 = 0` (expected 0x1122334455667788). The program took its
  own FAIL 1 path (li a0,0x101; sw -> tohost). 21 retires total before
  the fail write. This is a load-returns-wrong-value failure (delivered
  0 = untouched scratch), not a replay/violation manifestation --
  distinct signature from the tid19 replay class repaired here.
  REGRESSION vs the r13 model, where h33 retired past pc 0xa0 (distance
  0..4 and byte-overlap checks all passed) before the drop-commit SVA.
  r14-vs-r13 functional delta is exactly the waited_q/CAM-suppression
  diff (scoreboard change is assert-only): candidates are (a) a needed
  violation replay wrongly masked by the new ~vio_waited term
  (load completed on stale memory while the CAM was suppressed), or
  (b) a forward-path/verdict loss with an unrelated cause. The CAM
  diff itself touches only vv_match/vio_match gating -- stl forward
  and unres/dwait drain are untouched. Diag run hyp8-h33-r5-diag on
  the same model with +smt_flow_trace +lsq_trace +disp_trace
  +commit_trace_from=300..700 discriminates.
- hyp8-branch-cancel-r1, hyp8-osbi-scalar-r1: NOT RUN per stop rule.

## h33-r5 discrimination + r6-diag LSU wedge analysis (post-r14)

### r5 root cause — VERIFIED: the `vio_waited` suppression masked a needed replay
Same ELF `h33_st_fwd.elf` in all runs. r5-diag (r14-diag model, with the
waited-mask suppression) reproduced the failure exactly; r6-diag (earlier
unsuppressed model) ran the same pair correctly.

- Load tid17 `ld t1,0(s0)` @0x80000026: alloc @401 (`older=00010000`,
  tracks store tid16 @0x22), issued port1 @406, `dwait_set v=1 mask=0` @410
  (verdict-time STL CAM matched nothing — store's address still unresolved),
  `unres` cleared @430 (store16 addr resolved @429 `st_resolved=00010000`),
  `wb` data=0 @432, `retire valid=1 drop=0 replay=0` @434 — committed stale.
- Store tid16's data landed in the wbuffer only @437 (`wt_alloc`).
- In the r14 model the store16 addr-resolution event @429 matched load17 in
  the vio CAM but `vio_match & ~vio_waited` masked it (load had tracked the
  store via unres/older since alloc). No violation → no replay → x6=0 →
  bne taken → fail path (a0=0x101 → tohost, parked in wbuffer →
  "tohost=0, no verdict" budget-out).
- In the unsuppressed model the same event replays the load (r6-diag:
  forward raced and delivered a partial 0x88, replay recovered the full
  0x1122334455667788 — the "false violation" interpretation behind the
  waited-mask was itself wrong; that replay was legitimate recovery).
- Deeper defect the CAM covers: dwait is sampled once at the load's
  verdict event; an older store whose address is still unresolved at that
  moment yields dwait=0 and is never re-evaluated when its address later
  resolves. `unres` gates `checked` but does not refresh dwait. The only
  safety net is the first-resolution violation CAM — exactly what the
  suppression killed.
- FIX = current tree: revert to unsuppressed CAM
  (`match_i = {vv_match_q, vio_match_q}`, g6lc_lsq.sv:826) + documenting
  comment (:820-825) + +lsq_trace probe retained. `waited_q` fully removed
  from g6lc_lsq_release (diff vs HEAD is cosmetic only). scoreboard.sv
  widened SVA retained.

### r6-diag LSU wedge — separate latent defect: SL-W fixup tag-miss retry livelock
- Fixup queue took pushes for 0x1050 (retired @466), 0x1058 (@514), then
  0x1060/68/70/78/90 — but NO `wt_fixup_wr` after c=514.
- `FIXUP_CHECK`: `fixup_check_en_q1 && !|fixup_hit_oh_q` → `FIXUP_PEND`
  (wt_dcache_wbuffer.sv:1061-1070) — "keep the entry until a refill makes
  the line visible." The head at 0x80001060 re-probes the tag port every
  ~5 cycles forever (`hit=00` every time); probes continue to budget end.
- Probes are `fixup_rd_req` (not wbuffer checks: `wt_check`/`check_en_q1`
  prints stop at c865; `fixup_rd_req` requires `!|tocheck`).
  `forward=0x4000` = `wbuffer_all[14]` = `fixup_wbuffer_i[4]`
  (WbufExportDepth=10 → slots 10-14 are fixup exports) — the stuck slot
  forwards its word into the load-merge path forever.
- `empty_o = !|valid && !w3_vld` excludes the fixup queue →
  `dcache_wbuffer_empty` still asserted ~880; all wbuffer drains through
  878 evicted cleanly (every wt_alloc shows ptr=0, before valid=00).
- The parked op is load `id=0 gen=6` @0x8000012a → pa 0x80001090: issued
  @882, LSQ event @886 (clean: older=0, unres=0, dwait mask=0), then
  silent — zero non-port-3 D$ probes after ~870, no pop/complete. Bypass
  holds it (`lsu_ready=0` @1962) → tohost `sw` tid11 @0x15e sits at IRO
  `ack=0` from c=926 → commit head pinned → `c.j` loop fills scoreboard.
- Load hold — unverified which gate: cannot be WAIT_GNT/TAG/WB
  (data_req→probes), WAIT_TRANSLATION (entered only post-grant), WPO
  (needs page_offset_matches — all sources empty by ~880: commit/spec
  queues drained, sticky released on wbuffer_empty), spec/NI loop
  (NI rules empty; dwait_set required dtlb_hit=1). Remaining candidates:
  IDLE+accept_req=0 (valid_i=0 = bypass bookkeeping wedge, or ldbuf_full
  — unlikely at depth 8), or data_req asserted but never acked (invisible
  to wt_lookup — needs +ld_state/state_q probe to discriminate).
- Circular deadlock: whatever holds the load prevents the tohost store →
  no commit progress → c.j-only refetches → no refill of line 0x80001060
  → fixup head never retires → queue stays wedged (and `fixup_full` →
  `fixup_hold` would block future wbuffer rtrn legs too).

## LSQ verdict/checked same-edge race fix + integration-r15 (h33-r7 stop)

### LSQ leaf directed bench — verdict pipeline race found and fixed

Directed leaf `tb_g6lc_hyp8_lsq` (`HYP8_LEAF=lsq`, closure
`hyp8-control-r28-closure`; remote `hyp8-control-lsq-r5`):
`HYP8_LSQ_PASS checked=17`, ev-miss 0/0/0/0.

- **G2A_CHECKED_EARLY (r3) — real RTL bug, not a bench artifact.**
  `final_q` in `g6lc_lsq_verdict.sv` was set on the input event
  `ld_ev_valid_i`, one edge before `vld_v`/`vld_dwait` landed in
  `g6lc_lsq_release`'s `dwait_q`. At the in-between edge the
  `ld_checked_o` publish gate saw `final=1` with `dwait_q` still '0
  (`dwait_empty=1`) and published sticky `checked` while the load had a
  recorded dwait dependency. +lsq_trace evidence: `dwait_set id=25
  mask=01000000` @c31, `dwait=01000000` @c32, checked already high.
  A load could publish stale data — the exact class the leaf was added
  to qualify. Fix: `final_q` now sets on the registered V-stage verdict
  (`ld_verdict_valid_o`/`ld_verdict_id_o`, cancelled-masked), so final
  and dwait bookkeeping land on the same edge and `checked_q` evaluates
  settled state. `final_mask` is internal-only (sole consumer is the
  checked loop) so the one-edge delay is contained.
- **G2A_LATE_REPLAY (r4) — bench expectation gap.** A `wait` verdict
  pulses `replay_valid_o` exactly once (hyp8 H3 re-arm of dependents);
  the baseline snapshot predated the wait verdict. Bench now asserts
  `rpl_cnt == rpl_base+1 && rpl_id_last == 25` (positive check that the
  wait replay fired) and re-baselines before the late data/commit/phys
  events.

### Integration build r15

Closure `hyp8-integration-r15-closure` (766 files; delta vs r14 =
dcache fixup/MSHR/ctrl + load_unit probe + LSQ unsuppressed-CAM +
verdict final_q + rob held-kill + tb allowlist). Remote
`hyp8-integration-r15`: lint scalar rc=0 (census WIDTHEXPAND 326,
WIDTHTRUNC 87, LATCH 3 — r14 baseline, %Error 0), lint smt2 rc=0,
scalar build rc=0, jobs=2/threads=1/overlap-1. Model sha256
`93b07779d0548a7e7dcb29ff3070dba421765d8b5b1524dc9ba0e7728b603202`.

### Smokes — stop at first semantic failure

- `hyp8-h34-r12`: PASS — `*** SUCCESS *** (tohost = 0) after 656
  cycles`, ev-miss 0/0/0/0.
- `hyp8-h33-r7`: **STOP — parked-load livelock, r6-diag class**, now
  with the load-side gate fully resolved by the +ld_state probe.
  `hyp8-h33-r7-diag` (+ld_state +smt_flow_trace +lsq_trace +disp_trace,
  budget 3000):
  - Load tid=0 (va/pa 0x80001090) parks in `WAIT_PAGE_OFFSET`
    (`st=0000001000`) from c~898 to end; verbatim gate:
    `pom=1 poso=0 stb=1 fwd=0 sbe=0 wbe=1 spok=1 isn=0 cnc=0 treq=0
    dreq=0 rpl=0 dtlb=1 pav=1 wpo=255`.
  - `pom=1` with `poso=0` => commit-queue-class match
    (`po_commit_match` or its re-armed sticky) — the committed store to
    0x80001090 (wt_alloc @868, wt_tx id2/3, wt_ack @887-891).
  - Fixup drop path WORKED: fixup_push @887-891, tag probe hit=00 @889,
    then silence — entry dropped per the new contract; `wbe=1` (wbuffer
    + fixup drained). The r6-diag fixup-head retry livelock is gone.
  - But `sbe=0` — `store_buffer_empty_o` held: a store-buffer-internal
    match source (commit_queue entry / commit_push pend / sticky
    re-armed by a live match) still holds the 0x80001090 match after
    the store's memory write completed and its fixup dropped.
  - `rpl=0` — T33 WPO replay correctly suppressed (`poso=0`,
    "committed/draining store finishes on its own") — it never does.
  - Circular: parked load -> `lsu_ready=0` -> younger sw @0x15e (tid=11)
    pinned at IRO `ack=0` -> commit head pinned -> c.j refetches.
  - This DISPROVES the r6-diag "cannot be WPO" guess — WPO is exactly
    where the load sits; the fixup drop fixed the wbuffer side, the
    store-buffer commit-side match bookkeeping is the remaining defect.
  - `+stq_trace` produced zero lines — the probe does not exist in this
    tree (allowlist entry present but no implementation). Next
    discriminating probe: store-buffer-internal match-source dump
    (commit_queue[i].valid/address, commit_pend_v/commit_push_valid,
    page_offset_sticky_*_q, s1_v, spec occupancy).
- `hyp8-branch-cancel-r1`, `hyp8-osbi-scalar-r1`: NOT RUN per stop rule.

---

## r16/r17 — parked-load wedge root cause, return-channel fixes, leaf + smoke + witness record

### Store-buffer committed-source release (static answer + stq_trace)

Static read of `core/store_buffer.sv`: the committed-source match
(`po_commit_match`) holds while the store's record sits in the commit
queue (`commit_queue_q[i].valid`) or in the spec-pop -> commit-queue
pend (`commit_push_valid`/`commit_pend_v`). `stb_drain` retires a
commit-queue entry on `req_port_i.data_gnt` — the registered W2 verdict
(`gnt_q`) of the wbuffer port. The drained store at 0x80001090 should
have been released by exactly that grant: wt_tx/ack @887-891 (diag
ledger) produced the W2 grant that pops the commit-queue head, and the
same edge clears its page-offset match bookkeeping.

`+stq_trace` implemented (translate_off, print-on-change, cycle<3000,
all fields from the brief; allowlist already present) and run
(`hyp8-h33-stq-diag-r1` / `-collect`): the held source was **not** a
queue entry, pend, or sticky — the commit record had popped correctly.
The wedge was the wbuffer-side W1 producer-acceptance slot: after the
registered grant, a back-to-back producer (the popped commit-queue head
driving the NEXT request on the grant cycle) recaptured the W1 stage
while `data_req` remained asserted, so its grant was never re-armed —
the second store's `data_gnt` never arrived and the queue wedged behind
a dead W2 slot.

### Fixes (in tree)

- `core/store_buffer.sv`: `w1_accepted_q` — write-once-per-granted-
  request producer acceptance. The producer observes `gnt_q` the cycle
  after the W2 verdict; suppressing `w1_vld` for exactly the
  verdict->grant window keeps a held `data_req` from stealing the next
  request's grant (h33-r7 wedge mechanism).
- `core/cache_subsystem/wt_dcache_wbuffer.sv`: return-snapshot re-arm
  prevention — `snap_v_i/fire_i/l1_i` masked with `!evict`
  (`G6LC_MUT_RTRN_SNAP_REARM` keeps the pre-fix arms for review). The
  dying snapshot was re-arming its leg one edge past its evict: a second
  `leg_push_q`/`drop_q` two cycles later popped the NEXT return's FIFO
  entry under a stale id, stranding that return's tx_stat slot — the
  h33-r8 FAIL-126 leak (wtx-diag ledger: `wt_evict ... drop=1` for a
  return whose push was consumed by the re-arm).

### Integration builds

- `hyp8-integration-r16`: lint x2 rc=0, scalar build rc=0 (w1 fix in).
- `hyp8-integration-r17`: lint x2 rc=0, scalar build rc=0 (snap-rearm
  masks in). Model/closure under
  `/opt/testharness/runs/hyp8-integration-r17/`; the control-leaf
  closure `hyp8-control-r36-closure` is hash-identical to the r17 tree
  (wt_dcache_wbuffer.sv 5967b9f5, wt_dcache_mem.sv 0fcf194a, ctrl
  a7a67e82, bench c21c8af9 — verified file-by-file).

### r16 smokes (pre-snap-fix)

- `hyp8-h34-r13b`: PASS — `*** SUCCESS *** (tohost = 0) after 656
  cycles`, all verdicts clean.
- `hyp8-h33-r8`: **FAIL — `mc_verdict: a core ran and then stopped
  retiring (exit code 126)`**. `hyp8-h33-wtx-diag-r1` ledger shows the
  tx_stat slot stranded by the snapshot re-arm described above.

### r17 smokes — corrected record (tohost verdicts)

The bench ELFs DO carry `tohost` at `0x80001000` (assembled with
`link_verilator.ld`; the integration runner's TESTS table now declares it
per input and nm-verifies the built ELF — a missing/mismatched symbol is a
hard `tohost_missing` failure, never a liveness run). Earlier r14/r9/r1
smoke entries below were launched WITHOUT `+tohost_addr` (`tohost_addr: 0`
in the header meant the plusarg was omitted, not that the ELF lacked the
symbol) — those liveness-class results are semantically invalid and are
struck. The corrected r17 runs were launched WITH `+tohost_addr=0x80001000`
(proven by branch-cancel's real 451-cycle verdict):

- `hyp8-h34-r15`: **FAIL** — `[commit-dbg] t=520 pc=0x8000007e cause=24`
  (SimDTM DEBUG_REQUEST; these runs were launched without
  `+debug_disable`), then `t=688 pc=0x10058 cause=2` (the OV1 misfire
  described below), then `cause=2 pc=0x808` repeating to the 400k
  budget — `[cycle budget reached: no tohost verdict]`. The test itself
  was healthy until the debug hijack.
- `hyp8-h33-r10`: **FAIL** — same chain: `cause=24 @0x80000052` t=572 →
  `cause=2 @0x10058` t=747 → `0x808` loop → no tohost verdict.
- `hyp8-branch-cancel-r2`: **PASS** — `*** SUCCESS *** (tohost = 0)
  after 451 cycles`, a REAL tohost verdict (completed before the ~500-
  cycle `DmiDelCycles` gate opened); restores=2, mispredicts br=1 jmp=1.
- `hyp8-osbi-scalar-r1`: **FAIL — witness stop point.** Frozen scalar
  ELF `fw_payload.elf` (sha
  a9218107ce26c7d00a99ae188dc7ca8c1f77f2b16e4ef8d4c46e2ef4a026a37b),
  6,000,000-cycle budget reached, **zero UART output**
  (`grep -c 'OpenSBI|UART' run-hyp8.log = 0`),
  `FAIL: a core ran and then stopped retiring (exit code 126)`.
  Discriminating read: `[ckpt] final allocs=17 pops=7 restores=4
  clears=16`, last retire `pc=0x10062` — the core stopped dispatching
  ~17 instructions in, inside the ROM trap region.
- The `hyp8-osbi-scalar-diag-r1` evidence (r17, 2500 cycles,
  +smt_flow_trace +rvfi_cycle_stamp +fetch_win_trace) and ELF objdump
  (0x800000a8 = the upper halfword of the 32-bit `addi` at 0xa6, not an
  instruction boundary) established the mechanism precisely — see
  "Batch N — frontend override #1 domain defect" below. The earlier
  stale-`leftover_pc_o` attribution is RETRACTED: instr_realign's
  epoch/kill/carry contract is intact; the defect is the override #1
  clause firing on a guess class no tagged predictor can back.

### Directed leaves on the r17 tree

- LSQ verdict leaf (closure-r28, `hyp8-control-lsq-r5`):
  `HYP8_LSQ_PASS checked=17` — includes the directed
  verdict-while-unresolved -> late address-resolution -> violation
  names the load, and the resolved-addr/late-data no-violation
  negative. `final_q` alignment fix verified by G2A.
- Memory leaf (`hyp8-memory-own-r12`, control-r17-closure = r17 tree):
  `HYP8_MEMORY_PASS checked=88` — covers store commit -> wbuffer gnt ->
  store-buffer release -> same-page-offset load not interlocked after
  `dcache_wbuffer_empty` (the r15 wedge sequence), plus the
  return-channel cases.
- Dcache leaf DCHX2 (`hyp8-control-dcache-dchx2-r45`, r36-closure =
  r17 tree): `HYP8_DCACHE_PASS checked=115 dchx=2 stores=22`.

### DCHX0 disposition — arm present; leaf observability fix only

- The "hardcoded assert / hit0 arm compiled out" note was stale:
  `wt_dcache_ctrl.sv` has `localparam DCACHE_HIT0 =
  (HypCfg.DcacheHitExtra == 0)` + `gen_fsm_hit0` (the ported upstream
  single-cycle READ arm), legality `{0,2}` at ctrl:163-165 and
  `g6lc_hyp_pkg.sv:198`. `wt_dcache_mem.gen_rsp_live` is the ==0
  response path. No RTL restoration was needed and the legality
  predicate stays `{0,2}` — **no DCHX2-only narrowing, no debt**.
- Actual leaf blocker (first build `hyp8-control-dcache-dchx0-r19` on
  the r17-tree closure): elaboration failed on the bench's debug
  probes — `dut.i_wt_dcache_mem.wbuffer_rdata` and the comb `*_c`/`*_d`
  internals are optimizer-folded (`Can't find definition ... <no
  instances found>`). Empirically fragile under BOTH arms: dchx2-r46
  (r45's exact recipe + unified bench) lost the same name, while the
  module-scope mutation assignment (`-DG6LC_MUT_WBUF_FWD_ONE_HOT`,
  r19b) resolved — per-byte generate-scoped drivers inside
  `gen_fwd_lane` make the packed name optimizer-visible only by luck.
  Registered internals (bank_idx_q/bank_off_q/cmp_en_q/vld_sel_q,
  fixup_cnt, rtrn_snap_*) survive deterministically.
- Fix (verif-only, `verif/tb/core/tb_g6lc_hyp8_control.sv`): the
  `[mem]` and `[arb]` debug prints now read port-level equivalents
  (`dut.rd_hit_oh[1]`, `dut.rd_vld_bits[1]`, `dut.rd_data[1]`,
  `dut.wbuffer_fwd_hit`, `dut.wr_cl_vld`) or '0 where no port
  equivalent exists; flop probes kept. Note: under DcacheHitExtra==2
  the port readouts are the T2-registered values, +2 cycles vs the
  former comb internals — documented in the bench comment.
- Rerun on the r17-tree closure (`hyp8-control-dcache-dchx0-r19c-closure`
  = r36 hardlink copy + patched bench sha bb6c0d13):
  `hyp8-control-dcache-dchx0-r19d` —
  **`HYP8_DCACHE_PASS checked=115 dchx=0 stores=22`**;
  `hyp8-control-dcache-dchx2-r47` (same patched bench, r45 recipe) —
  **`HYP8_DCACHE_PASS checked=115 dchx=2 stores=22`**. Identical check
  counts on both arms.

### Batch N — frontend override #1 domain defect (diagnosed + fixed)

**Evidence chain (r17, verbatim).** `hyp8-osbi-scalar-diag-r1` (2500
cycles, `+smt_flow_trace +rvfi_cycle_stamp +fetch_win_trace`;
`+icf_trace` is an ALU-shift probe, not a frontend probe, and
`g6lc_fetch_dbg.sv`'s realigner bind is dropped from `Flist.hyp8_sim`, so
no direct leftover/carry readout exists — reported as unavailable, not
claimed):

- RVFI retire stream `0x80000000` → first trap: 0x80000000 `0x00050433`,
  0x80000004 `0x000584b3`, 0x80000008 `0x00060933`, 0x8000000c
  `0x66c000ef`, then 0x80000010..0x80000032, then ROM `0x10040
  0xf1402573`, `0x10044 0x00000597`, `0x10048 0x03c58593`, `0x10050
  0xffdff06f` (`j -4` park loop).
- Traps: `cause=24 @0x80000038` (~t=552, SimDTM DEBUG_REQUEST), then
  `cause=2 @0x10058` (~t=716) and `cause=2 @0x808` repeating.
- `[win]`: `0x10050` response taken epoch 7 (t=609); `0x10058` pushed
  with a taken line guess (t=614); override/redirect for `0x10058`,
  NPC back to `0x10050` (t=615); the `0x10058` take allocates
  `0x00000000` and commits `cause=2` (~t=703-716); then `0x810`/`0x808`.
- ELF bytes `0x800000a4..0x800000ac`: `0x800000a6 326a0a13 addi
  s4,s4,806`, `0x800000aa 305a1073 csrw mtvec,s4` — `0x800000a8` is the
  upper halfword of the `addi`, never an instruction boundary.
- Boot ROM: `RomSize=221` qwords from 0x10000; `0x800`/`0x808` are
  out-of-range and read as zero (the debug ROM is a zero stub), and
  `csr_trap.sv` in debug mode targets `DmBaseAddress +
  ExceptionAddress = 0x808` — hence the permanent illegal-instruction
  loop after the first debug-mode trap.

**Mechanism.** `g6lc_fe_btb_check`'s override #1 second clause,
`!btb_hit && chk_line_taken_q && !ras_agree`, fires on ANY taken line
guess with no tagged backing. But the untagged line table was trained by
EVERY live verdict (`g6lc_fe_override` `train_valid_o <= s_live`,
`train_taken_o <= bp_fire_live`) and by every resolve — including direct
`Jump`/`Branch` outcomes, which no tagged predictor can ever back (the
tagged BTB only trains `is_mispredict && JumpR`; the RAS only covers
returns; and under hyp8 `BPType=TAGE_LITE && BPIndirectEn=1` the check's
own `i_chk_btb` is compiled out entirely — `gen_no_chk_btb` — leaving
RAS-agree as the only adjudicator). The ROM park loop's `jal x0,-4` at
0x10050 is exactly such a guess: verdict-trained taken→0x1004c; on the
next sequential push of 0x10050 the check sees taken, no BTB, no RAS
agreement → override #1 redirects to `next_block(0x10050) = 0x10058`,
fetching the zero padding past the ROM's last word → `cause=2` → (in
debug mode) the `0x808` livelock. In ordinary code the same misfire
skips the trained CF and diverges control flow silently — the h34/h33
smokes show the park-loop instance verbatim (above); normal-code
instances wedge without trapping.

**Fix (r18 tree, by identity — the cached guess's domain tag).** The
untagged table may only hold guesses the tagged check can adjudicate.
New `train_tagdom` qualifier carried through the train record:
`g6lc_fe_override` computes `pred_tagdom` = the predicting slot's
cf ∈ {Return, JumpR×CHK_TAGGED_BTB} (registered alongside
`train_*`); `frontend.sv` derives `nl_train_tagdom` per producer
(resolve: cf-domain test; ov2: the verdict's own tag; ov1: 1, tag-domain
by construction); `g6lc_fe_nextline` masks `ltaken` writes with it
(taken-write requires tagdom; unqualified/not-taken writes still clear —
the unlearn path is unchanged). `CHK_TAGGED_BTB` is a localparam
mirroring `gen_no_chk_btb`, so configs where the check owns a real
tagged BTB keep JumpR guesses. Under hyp8 the table consequently holds
only RAS-backed return guesses; direct jumps and branches are
re-predicted at the verdict stage each pass (the pre-table behaviour),
and override #1's clause can only see guesses its invariant covers — by
construction rather than by provenance bits on entries (which an
aliased read would smuggle past the check).

**Leaf.** New `tb_g6lc_hyp8_linecheck` (real `g6lc_fe_nextline` +
`g6lc_fe_btb_check` composed exactly as `frontend.sv` wires them): the
park-loop sequence — direct-`j` taken train at tagdom=0 → re-push of the
block presents an untaken guess, no override, fetch continues
sequentially (never a mid-stream redirect); tag-domain train → taken
guess → unbacked override #1 to `next_block` still fires; RAS-agree
keeps the check silent; unlearn clears.
`hyp8-control-linecheck-r2` on closure `hyp8-control-r48-closure`:
**`HYP8_LINECHECK_PASS checked=36`**.



- r18 sequence in flight: the override-#1 domain fix below + three
  smokes re-run with `+tohost_addr=0x80001000 +debug_disable`, then the
  firmware witness `hyp8-osbi-scalar-r2` (6,000,000 cycles).
- The debug-mode park itself (hart spins `wfi`/`j -4` at mtvec because
  the debug ROM at 0x800 is zero-filled and no DMI resume arrives) is
  upstream-parity behaviour, not a defect; future runs needing the
  fesvr DMI path quiesced should pass `+debug_disable` or
  `+jtag_rbb_enable=1`.
- Note on invocation hygiene: `testharness_proxy.py run` already
  nm-discovers `+tohost_addr` and always passes `+debug_disable`; the
  r17 smoke runs bypassed it with a custom launcher (no `+debug_disable`,
  no `+jtag_rbb_enable`) — that is what let the SimDTM halt request reach
  the core mid-test.

---

## Record-integrity note (2026-10-22)

An append with a cp1252 default codec truncated this file. The text above
this note was restored verbatim from the IDE local-history snapshot of
2026-10-22 17:37 (120,885 characters, the last pre-truncation state).
The interim reconstructed file is kept as
`implementation-log.reconstructed-20261022.md`; the sections below were
written after the snapshot and are carried over from it.

## A-series correction note [RECONSTRUCTED]

The original log stated the smoke ELFs carried no tohost — **wrong**.
All three smoke ELFs carry `tohost` at `0x80001000` (nm-verified); the
r17 runs' `tohost_addr: 0` field meant the `+tohost_addr` plusarg was
omitted, making those verdicts liveness-only — semantically invalid
(h33's failure path writes `tohost=0x101`, which reads as "PASS" under
liveness). Corrected r17 verdicts with `+tohost_addr=0x80001000`:
`hyp8-h34-r15` and `hyp8-h33-r10` budgeted out at 400k with NO tohost
verdict — genuine semantic failures; `[commit-dbg]` shows
`cause=24 (DEBUG_REQUEST) @0x8000007e/0x80000052` -> `cause=2 @0x10058`
-> repeating `cause=2 @0x808` (the SimDTM halt hijack exposed the
unparked debug ROM; `+debug_disable` quiesces it — upstream-parity, not
a defect). `hyp8-branch-cancel-r2` finished at 451 cycles BEFORE the
~500-cycle DMI gate: `SUCCESS (tohost = 0)`. Runner hardened: TESTS now
carry explicit `(name, elf, tohost)` triples, nm fallback, and missing
`+tohost_addr` is an error for tohost-bearing inputs rather than a
silent liveness run.

## Frontend B-series evidence + line-table tag-domain fix [RECONSTRUCTED]

`hyp8-osbi-scalar-diag-r1` (r17, budget 2500, `+smt_flow_trace`
`+rvfi_cycle_stamp` `+icf_trace`) evidenced the witness stop: retire
stream from 0x80000000 halts with a cause-2 trap after a SRC_OV1
redirect to `0x800000a8` — the middle of the 32-bit instruction at
`0x800000a4` (objdump: instruction spanning 0xa4-0xa7, next at 0xa8).
Mechanism as diagnosed: `g6lc_fe_btb_check` can issue override #1 for
direct `Jump`/`Branch` guesses that have NO tagged BTB backing — an
untagged line-table `ltaken` entry trained by the verdict path later
reads as a taken guess the check's invariant cannot adjudicate, and
OV1 fires to a stale record (leftover_pc surviving a predicted
redirect — the `[win]` trace claim). Chosen repair (not the
leftover-pc provenance path): restrict line-table training to the
domain the check can actually adjudicate. Under hyp8
(`BPType=TAGE_LITE && BPIndirectEn=1` -> `gen_no_chk_btb`, `chk_pred`=0)
that domain is RAS-backed `Return` only — see the VERBATIM section
above for the design text and the `HYP8_LINECHECK_PASS checked=36` leaf.

- r18 sequence in flight note (original): three smokes re-run with
  `+tohost_addr=0x80001000 +debug_disable`, then the firmware witness
  `hyp8-osbi-scalar-r2` (6,000,000 cycles) — COMPLETED, see r18 section.
- The debug-mode park itself (hart spins `wfi`/`j -4` at mtvec because
  the debug ROM at 0x800 is zero-filled and no DMI resume arrives) is
  upstream-parity behaviour, not a defect; future runs needing the
  fesvr DMI path quiesced should pass `+debug_disable` or
  `+jtag_rbb_enable=1`. *(verbatim-recovered bullet)*
- Note on invocation hygiene (verbatim-recovered bullet):
  `testharness_proxy.py run` already nm-discovers `+tohost_addr` and
  always passes `+debug_disable`; the r17 smoke runs bypassed it with a
  custom launcher (no `+debug_disable`, no `+jtag_rbb_enable`) — that is
  what let the SimDTM halt request reach the core mid-test.


---

## r18 integration + corrected smokes + witness STOP — dispatch publish-vs-kill race (proven)

**Build.** `hyp8-integration-r18` (closure `hyp8-integration-r18-closure`):
lint scalar rc=0 / smt2 rc=0; scalar model built
(`Variane_testharness` sha256
`7735a1861ff7d6f9bb8c31faeca14475a78deba531f5b1411cb8ee4c15926405`);
warning census WIDTHEXPAND 329 (+3 vs r15 baseline: the tagdom reduction),
WIDTHTRUNC 87, LATCH 3. jobs=2, 1 thread.

**Corrected smokes — all three REAL tohost verdicts
(`+tohost_addr=0x80001000 +debug_disable +quiet_axi`):**

| tag | ELF | verdict |
|---|---|---|
| `hyp8-h34-r16` | h34_shift_dep | `SUCCESS (tohost = 0) after 656 cycles` |
| `hyp8-h33-r11` | h33_st_fwd | `SUCCESS (tohost = 0) after 966 cycles` |
| `hyp8-branch-cancel-r3` | hyp8_branch_cancel | `SUCCESS (tohost = 0) after 451 cycles` |

h34 matches the r13b/r16 reference (656 cycles); h33 — which wedged at
400k under r17 with debug-park — now retires and writes `tohost=0` at
966 cycles. The line-table tag-domain gate resolved the OV1 defect both
smokes were tripping.

**Firmware witness `hyp8-osbi-scalar-r2` — STOP (semantic failure).**
Frozen `fw_payload.elf` (sha `a9218107…`, tohost `0x80041730` via nm —
the r1 run had *no* `+tohost_addr` at all; r2 launched with the
ELF-symbol address). The run aborts at main_time 24988 on the stock
upstream SVA `scoreboard.sv:283 genblk2[0]` —
"Issue acknowledged but instruction is not valid"
(`issue_ack_i[0] |-> issue_instr_valid_o[0]`). r17's identical witness
ran 6,000,000 cycles with **zero %Error** — the assert is reachable now
because the r18 prediction-timing change aligned a latent race.

**Discriminating run** `hyp8-osbi-r2-diag` (same model,
`+smt_flow_trace +rvfi_cycle_stamp`, 26k budget) reproduces the assert
at the identical edge. Tail context:

```
alloc  c=24970 id=0/1 gen=154 pc=0x8001375c/0x80013760  (predicted-path lbu + bgeu)
retire/wb c=24974 id=31 pc=0x80013758  (backward branch resolves)
control c=24974 flush=0 flush_unissued=1 resolve=1 mispredict=1 target=0x8001379c
[24988] %Error  issue_ack_i[0] with issue_instr_valid_o[0]=0   <- next edge
```

**Mechanism — proven by construction, not conjecture.**
`dispatch_ack_o = iqdisp_ack & grp_v_q & {grp_go}` and
`grp_go` is `!flush_unissued_i`-gated, so a nonzero `grp_v_q[0]` at the
post-flush cycle is required for the observed ack. `grp_v_q` clears on
`mispredict_i | flush_i | flush_unissued_i` — but ONLY in the `else if`
leg (`g6lc_ooo_dispatch.sv:530-532`): `if (ren_pub)` at :514-521 has
priority and re-captures `grp_v_q <= ren_group_valid & dispatch_valid_i`.
`ren_pub` is the rename pipe's registered publish — independent of the
resolve, so it can coincide with the flush edge. The zombie-lane mask
`dispatch_valid_i` is sampled pre-flush: `decoded_instr_valid_i` is
still presenting the predicted-path group during the flush cycle and
only retracts at the edge. Therefore a rename publish coincident with
`flush_unissued_i` (c=24974) re-creates a `grp_v_q` lane out of dead
slots; at c=24975 `grp_go` acks it while the scoreboard presents
`issue_instr_valid_o=0` → SVA. The assert's existence itself proves
`ren_pub` fired on the flush edge with `dispatch_valid_i=1` — every
other path to `grp_v_q≠0` is killed by the `else if` leg. Downstream the
ack allocs an IQ entry on a non-flush edge (`e_d[e].valid = !flush_i`)
plus `ld_alloc/st_alloc` LSQ entries — a wrong-path instruction enters
execution state; the `dispatch`'s own `OOO_RECOVERY_ACCEPT` assert
(:366-368) correctly stayed silent because the ack lands one cycle
*after* the flush, not on it.

The designers' comment at :515-520 ("a cancelled slot ... must not enter
grp_v_q") covers a kill *between* capture and publish; the coincident
publish-on-kill-edge case escapes exactly because the mask is sampled
before the kill retires the presented group.

**Proposed fix (by identity — kill outranks publish for grp_v_q):**
mask the re-capture with the kill event that invalidates the lanes,
e.g. `grp_v_q <= ren_group_valid & dispatch_valid_i &
{NP{~(mispredict_i | flush_i | flush_unissued_i)}}` (or reorder the
if/else). Other `ren_pub` side-effects (steer advance, `grp_sbe_q`
capture, `grp_pend_q` drop — already kill-priority at :509) are inert
when `grp_v_q` stays 0. NOT APPLIED — reported for decision.

**Status.** r18 = smokes semantic-pass (3/3 tohost), witness STOP on the
dispatch publish-vs-kill race. r17 models immutable; no commits; E:
~4.3 GB free.


## 2026-10-22 — r19: publish-vs-kill fix landed; leaf + smokes green; witness r3

**Fix applied** (`core/ooo/g6lc_ooo_dispatch.sv`, the r2-diag root cause):
the `grp_v_q` capture is reordered so the kill leg
`mispredict_i | flush_i | flush_unissued_i` clears FIRST and outranks the
`ren_pub` re-capture (previously `if (ren_pub)` won and resurrected the
pre-flush lanes — the proven osbi-scalar-r2 mechanism). The block comment
records the sibling-state audit: `grp_sbe_q`/`grp_orig_q`/tid staging and
`grp_may_bypass_q` are consumed only through `grp_v_q`/`grp_go`/
`dispatch_ack_o` and are inert while `grp_v_q == 0`; `steer_q` is a
performance hint; `grp_pend_q` already had kill priority (:509). No other
publish-edge state can present a dead lane.

**Dispatch leaf** (`tb_g6lc_hyp8_dispatch` in tb_g6lc_hyp8_control.sv):
new section G (publish edge coincident with `flush_unissued_i` while
`dispatch_valid_i` still presents the pre-flush lanes) and G2 (same with
`mispredict_i`, live checkpoint via a dispatched branch). Checks: no
`grp_v_q` re-capture, no `dispatch_ack_o` over the next 8 cycles, no IQ
allocation, no issue accept for the dead lanes; then a fresh post-kill
group acks and issues normally. Result: `HYP8_DISPATCH_PASS checked=30`
(tag `hyp8-control-dispatch-r12`, closure `hyp8-control-r50-closure`,
warnings=none).

- First run (r11, closure r49) failed `G_FRESH_NO_ISSUE` — diagnosed via
  `+dispatch_trace` as a **bench artifact, not RTL**: section F leaves
  `iack='0` (issue acks held off) and `reset_all` did not restore it, so
  the fresh group's record staged into `iss_v_q[0]` and was never popped
  (`iss_pop = iss_v_q & issue_ack_i`). `reset_all` now restores
  `iack='1`. The coincident-edge behaviour itself was already correct in
  that run: `grp_v_q` stayed 00 and no zombie `dack`/`ivalid` appeared.

**Integration build** `hyp8-integration-r19` (closure
`hyp8-integration-r19-closure`, 816 hash-verified files): lint scalar
rc=0 / smt2 rc=0; scalar model `Variane_testharness` sha256
`7b7e1365bde8bd8304038ca48d492c742b1d1c7364bc6612a1ecab99fd75e5f7`.
Census — scalar lint: WIDTHEXPAND 329, WIDTHTRUNC 87, LATCH 3 (r18
baseline); smt2 lint: 339/97/3; build.log: WIDTHEXPAND 68, WIDTHTRUNC 16,
WIDTHCONCAT 3, UNSIGNED 3, CMPCONST 7, SYMRSVDWORD 1. jobs=2, 1 model
thread, HYP8_ALLOW_OVERLAP=1 (foreign workloads preserved, recorded in
results.json guard).

**Smokes** via `testharness_proxy.py run` (nm-derived tohost, sha-pinned
model, `+debug_disable +quiet_axi` baked into the runner):

| tag | verdict |
|---|---|
| hyp8-h34-r17 | `*** SUCCESS *** (tohost = 0) after 656 cycles` |
| hyp8-h33-r12 | `*** SUCCESS *** (tohost = 0) after 966 cycles` |
| hyp8-branch-cancel-r4 | `*** SUCCESS *** (tohost = 0) after 451 cycles` |

All identical to r18 — semantic tohost passes, zero ev-miss.
(Note: a first h34 attempt warned "no tohost symbol" because the local
`E:/...`-style toolchain path did not resolve in Git-Bash `PATH`; the run
was voided and re-run under the corrected `/e/...` path — the proxy's
nm fallback then emitted `+tohost_addr=0x80001000` as designed.)

**Firmware witness** `hyp8-osbi-scalar-r3`: frozen `fw_payload.elf` sha
`a9218107…` (same input as r2), `+tohost_addr=0x80041730` nm-derived,
`+debug_disable +quiet_axi`, budget 6,000,000 — **STOP: budget-out FAIL**.
Verdict lines verbatim:

    fw_payload.elf *** SUCCESS *** (tohost = 0) after 6000000 cycles
        [cycle budget reached: no tohost verdict]
    *** [mc_verdict] all 1 core(s) retired instructions
    *** [mc_verdict] program exit code 0
    *** [mc_gap] core 0 max retirement gap 313 cycles (limit 5000, wfi=0)
    *** [mc_verdict] FAIL: a core ran and then stopped retiring (exit code 126)
    [ckpt] final core=0 allocs=1582 pops=1555 pop_mismatch=0 pop_dead=0
        restores=10 restore_mismatch=0 restore_dropped=10 refused=0 clears=10
        | resolves br=1550 ret=6 jmp=9 mispredicts br=9 ret=0 jmp=1
    [lsq-ev-miss] summary w=0..3 count=0
    Wall clock 1,193,169 ms; zero %Error, zero UART output.

**The r2 defect is verified fixed in vivo**: the same mispredict
(`bgeu` @0x80013760, iteration N+1 of the `fdt_path_offset_namelen` path
loop) resolved at ~cycle 24,974 — r2 died on the scoreboard SVA at 24,988;
r19 instead retired the redirect target path cleanly (rvfi: 0x8001379c
`c.ldsp s2` @25020, 0x8001379e `c.ldsp ra` @25024, 0x800137a0 `c.ldsp s0`
@25030). No assertion fired in the full 6M budget.

**New stop point — discriminating read** (stop rule honored, no probe run
yet): the hart retired 4,820 instructions then stalled permanently inside
the `fdt_path_offset_namelen` epilogue. An older committed `c.sdsp
s2,48(sp)` (retire @~24,918, mem 0x80046f50, value 0x8001e000) occupies
the stack page sp≈0x80046f20; three younger same-page `c.ldsp` loads
completed (s2←0x80046f50 forwarded the just-stored value, ra←0x80046f68,
s0←0x80046f60), then the remaining four same-page loads — s1←0x80046f58,
s3←0x80046f48, s5←0x80046f38, s4←0x80046f40 — plus `mv a0,s4`,
`addi sp,sp,80`, `ret` never retired (5.97M dead cycles, gap counter saw
only 313-cycle inter-retire gaps, i.e. the terminal stall is the failure).
Signature is the r15 h33-wedge family: a committed store's store-buffer
record holding a page-offset match that its drain path does not release.
The r16 fixes (`w1_accepted_q`, return-snapshot re-arm) are IN this tree,
so this is a residual leg or a sibling held source — the r15 analysis
already flagged "the drop path bypasses whatever release signal the STQ
bookkeeping expects". Needs a +ld_state/+stq_trace diag run on the r19
model to name the held source (commit_queue entry vs commit_push pend vs
page_offset_sticky vs spec occupancy). Not run — awaiting decision.

**Open items.**

- Witness r3 stop point: parked same-page load(s) behind a committed
  stack store ~cycle 25k — name the held STQ source (diag probe run).
- OPEN PERF DEBT: under untagged-BTB hyp8 the line table retains only
  RAS-backed return guesses; direct jumps/branches are re-predicted at
  verdict every pass (the tagdom fix's accepted coverage cost).
- The publish-vs-kill coincidence was latent in r17 too — r18's prediction
  timing newly aligned it; the fix closes it for all prediction timings.

r17/r18 models immutable; no commits; E: ~29 GB free.


### stq-diag-r1 discriminating read (r19 model, 30k budget, +smt_flow_trace +ld_state +stq_trace)

Run `hyp8-osbi-stq-diag-r1` on sha-pinned r19 model (7b7e1365…), frozen ELF.
Budget-out as expected (wedge ~c25030). Local pull:
`C:\Users\etcim\cva6-artifacts\hyp8-osbi-stq-diag-r1\run-B.log`.

**CAUTION / artifact note:** the run dir's `output/` copy of
`trace_hart_0.dasm`/`iti.traces`/`encaps.traces` was populated by a
relative-path `cp` slip and contains **foreign-run traces** (a 0x8000086a
`c.j .` stream) — ignore them. `run-B.log` and `trace_rvfi_hart_00.dasm`
are the genuine diag output (rvfi tail identical to r3).

**The wedge is a LOST load, not a parked one.**

- Commit head pinned on scoreboard slot `id=5 gen=153` =
  `ld s1,56(sp)` (pc 0x800137a2, va 0x80046f58): alloc @25008,
  IQ issue (operands a=0x80046f20 imm=0x38) @25043, LSU accept @25033
  (IDLE, `dreq=1`, pa resolves to 0x80046f58), FSM → `WAIT_GNT` @25034.
- Then it evaporates: **no `wt_lookup` for pa=0x80046f58 after 24541**,
  no `data_gnt`, no forward, no `wb`, no `pop`, no kill/`fls` in the
  window (all `fls=1` events are early-boot). ldbuf mask drains
  `11→10→01→00` by c25073, FSM back to IDLE `v=0` — nothing remains of
  the transaction in any visible stage.
- Siblings on the SAME 64B line (0x80046f40-7f) completed through the
  miss→refill path: `wt_lookup` 0x46f48 @25033 / 0x46f40 @25050 /
  0x46f38 @25053,56; refills idx f4 @25046, idx f3 @25069; wb id=6 @25050,
  id=9 @25054, id=7 @25073. The FIRST of the three (tid=5) was never
  served — a queue-order victim, not a line residency issue.
- Scoreboard `stalled` heartbeats (26055/27079/28103/29127):
  `issue_ptr=3 commit_ptr=5 full=0 decoded=11 ack=00` — the decode seam
  holds 11 valid instrs (post-ret target path 0x80013846..0x8001386c was
  allocated through 25092), dispatch never acks again because the commit
  head is pinned.
- `+stq_trace` is capped at c<3000 — **zero STQ visibility in the wedge
  window**; needs an uncapped variant or deeper LSU probe.

Store record lifecycle for the same word (context for the hypothesis):
earlier store → wt_tx id=3/2 @24511-12 (data 0x8001f468, be=ff),
`wt_fixup_push` @24530 (match=0) and @24534 (match=1), `wt_txv` vld→0
@24531/24535, and the fixup export was still live at 24541
(`wt_lookup port=3 … forward=00000800 result=0x8001f468`). The load
entered the LSU while that fixup record still existed.

**Two candidate mechanisms** (both consistent with every visible fact):

1. *Lost-beat / mis-association:* the load's ldbuf entry or FSM request
   was consumed by a `data_gnt`/return beat attributed to a different
   tid (the shared FSM serves one tracked request; ldbuf bookkeeping may
   have popped the wrong entry — needs `ldbuf_q[i].trans_id/vaddr` and
   return-channel `data_id` visibility to confirm).
2. *Forward-track orphan:* the load's tracking latched onto the pending
   fixup record for 0x80046f58 at entry (pom printed 0, but the store's
   fixup record was live), and the fixup-drop/apply path around the
   25046 refill released the record without delivering data or a
   re-issue signal — the r15-identified "drop path bypasses whatever
   release signal" class, one leg deeper.

**Not run / not changed:** no RTL touched; r19 model immutable. Probe gap:
`+stq_trace` cap 3000; `+ld_state` shows only the shared-FSM input head,
not the tracked ldbuf entry — next diag needs `ldbuf_q[i].{valid,trans_id,
vaddr}` + `req_port_i.data_id` + fixup queue occupancy printed on change.


## r20 — LSU bypass overwrite fix (IRO lsu_valid_q gate) + A/B attribution of the arbiter-rewrite wedge

### Mechanism (hyp8-osbi-ld-diag-r1, verbatim)

    c=25032 [lsqb-evt] insert tid=5 wp=0 cnt=0 ok
    c=25033 [lsqb-evt] insert tid=7 wp=1 cnt=1 ok
    c=25034 [lsqb-evt] insert tid=9 wp=0 cnt=2 OVERWRITE-FULL

The lsu_bypass queue is depth-2; `mem_n[write_pointer_q] = lsu_req_i` is
unconditional on `lsu_req_valid_i` with no full check. tid 9 wrapped onto
the live tid-5 head — no pop_ld/pop_st/flush/cancel-mask, no grant, no
writeback. Reservation shadow: IRO grant -> lsu_valid_q (T+1) -> LSU AGU
A2 -> bypass insert (T+2) -> cnt (T+3), while `ready_o = empty` allows
3 grants in that window.

### Fix (core/issue_read_operands.sv)

`fus_busy[0].load/store` now also sets while `|lsu_valid_q` — the granted
strobe counts as busy for one cycle, forcing >=2-cycle spacing between
bypass posts so queue occupancy is visible before a third grant:
bounded at cnt=2 = depth. No change to ready semantics, no counter.

### Directed leaf — tb_g6lc_hyp8_issue LSU-shadow section

`hyp8-control-issue-r19` (closure hyp8-control-r54-closure):
`IRO_LSU_SHADOW_OK checks=14` — ld1 grants, vq pulses; ld2/ld3 blocked
exactly one cycle each during the strobe then ack; ready gate still
blocks/releases on lsu_ready_i; store follows the same gate. The bench's
initial attempt dropped issue_instr_valid_i before the accept edge —
fixed by holding valid through the tick after the combinational ack;
section moved to run FIRST so its evidence survives the arbiter
sections' failure (below).

### r20b build (closure hyp8-integration-r20-closure, 816 files)

NOTE — closure-builder fixpoint bug found: `cand.resolve()` resolves
relative incdir joins against CWD, so building from the tools dir
dropped `corev_apu/apu/g6lc_apu_fault_sup.sv` (766 files, lint fail).
Rebuilt from E:/cva6 → 816 files.

Lint scalar rc=0 (WIDTHEXPAND 341 — +12 vs r19's 329 from the concurrent
iq_arb rewrite; WIDTHTRUNC 87, LATCH 3), smt2 rc=0 (351/97/3), scalar
model sha256 `df747e1bb02314f370c1cde1ac4d60746f22e658a1bdb824b86d9262ec7b2d75`.

### Smokes on r20b — STOP at h33, discriminating A/B

- `hyp8-h34-r18`   SUCCESS (tohost = 0) after 674 cycles — real verdict.
- `hyp8-h33-r13`   budget-out FAIL: test FAILED internally — `ld` at
  0x800000a4 read mem 0x80001078 = 0 (expected merged store data), took
  FAIL 2 (a0=0x102), `sw` to tohost retired (rvfi mem 0x80001000 <- 0x102)
  but harness read tohost=0 — store data not reaching memory.
  Then `j done` loop to 400k.

**A/B bisect** — `hyp8-integration-r20arb19`: r20 tree with `g6lc_iq_arb.sv`
reverted to the r19 copy (my IRO gate kept). `hyp8-h33-r13arb19` →
`SUCCESS (tohost = 0) after 970 cycles`. **The wedge is the in-flight
iq_arb rewrite, not the IRO fix** — consistent with leaf check
ARB_TAKE_P0_TID1 failing on the same rewrite (take path changed).

### arb19-model smokes (fix isolated)

| tag | verdict |
|---|---|
| hyp8-h34-r18arb19 | `*** SUCCESS *** (tohost = 0) after 658 cycles` |
| hyp8-h33-r13arb19 | `*** SUCCESS *** (tohost = 0) after 970 cycles` |
| hyp8-branch-cancel-r5arb19 | `*** SUCCESS *** (tohost = 0) after 454 cycles` |

### Witness `hyp8-osbi-scalar-r4` — launched on the arb19 model

frozen fw_payload.elf sha a9218107…, +tohost_addr=0x80041730, 6,000,000
cycles, detached pid on the remote; labelled explicitly as running the
r20-arb19 model (r20-pure witness is blocked by the arbiter defect until
the rewrite settles).


### Witness `hyp8-osbi-scalar-r4` verdict (arb19 model, 6M, verbatim tail)

    fw_payload.elf *** SUCCESS *** (tohost = 0) after 6000000 cycles
        [cycle budget reached: no tohost verdict]
    [commit-dbg] t=25873 pc=000000008001300e ex.valid=1 cause=2   (x3)
    *** [mc_verdict] all 1 core(s) retired instructions
    *** [mc_verdict] program exit code 0
    *** [mc_gap] core 0 max retirement gap 313 cycles (limit 5000, wfi=0)
    *** [mc_verdict] FAIL: a core ran and then stopped retiring (exit 126)
    [ckpt] final core=0 allocs=1632 pops=1595 pop_mismatch=0
        restores=15 restore_mismatch=0 restore_dropped=15 clears=16
        | resolves br=1568 ret=9 jmp=33 mispredicts br=13 ret=0 jmp=2
    [lsq-ev-miss] summary w=0..3 count=0
    Wall clock 1,119,690 ms; zero %Error, zero UART.

Discriminating read — **a fetch-domain defect, not the LSU lost-load**:
0x8001300e is a legal `c.sd s7,72(sp)` per objdump yet committed
cause=2 (illegal instruction) at t=25873; the older in-sequence stores
0x8001300a/0x8001300c never appear in RVFI before the exception
published; RVFI ends at 0x80013004 (`addiw`) and the ITI fetch trace
ends at the same PC — after the trap redirect the frontend produced
ZERO further instructions (mtvec handler never fetched). The fetched
bytes for the 0x80013006..0x80013012 window were illegal despite a
legal encoding — fetch-delivery integrity (leftover/tag-domain class
residual, or refill data), then post-trap fetch starvation. LSU tid-5
lost-load mechanism itself is fixed (leaf + h33 pass on the same model);
the witness advanced into a different, fetch-side wedge. Remote
evidence: /opt/testharness/runs/hyp8-osbi-scalar-r4/ (run-hyp8.log,
trace_rvfi_hart_00.dasm — 9930 lines, iti.traces).

## fe-diag-r1 — cause-2 wedge root-caused to I$-fill data mis-association (no fix: insertion point below probe reach on frozen model)

Tag `hyp8-osbi-fe-diag-r1`, frozen `hyp8-integration-r20arb19` (arbiter-reverted, LSU fix in),
`+time_out=27000 +max-cycles=27000 +tohost_addr=0x80041730 +smt_flow_trace +rvfi_cycle_stamp
+icf_trace +win_trace +iq_trace +id_dbg_trace +commit_trace +fetch_win_trace +fetch_kill_check`,
windows 25500–26200. rc=120 (budget), 111,803-line log at `cva6-artifacts/hyp8-osbi-fe-diag-r1/`.

### Verdict

The cause-2 wedge is **not** a realigner/queue/decode defect and **not** post-trap starvation.
The fetch RESPONSE for va `0x80013000` (miss, REQ c=25799 → RSP c=25813, ~14cy) delivered the
bytes of pa `0x80012000`; the next fetch (`0x80013008`, ~3cy) hit the just-installed poisoned
line; `0x80013010`/`0x80013018` fetched clean. Byte-exact match vs ELF:

    ELF 0x80012000: ff853503 0186179b 0086169b 6741 / 0117e7b3
    pushed pc 0x80013000: ff853503   0x80013004: 0186179b   0x80013008: 0086169b   0x8001300c: e7b36741

Realigner stitched leftover `e7b3` (low half of poisoned word @0x8001300e) + real `e0e2`
(0x80013010) into `e0e2e7b3` = OP funct7=0x70 (illegal) → cause 2 @ pc 0x8001300e, committed
t=25873. Bogus stream before it retired harmlessly (`ld a0,-8(a0)` id16, `slliw` id17 @c25860).
Post-trap: flush c=25860-61, redirect mtvec=0x800003c8 ep=5, fetch REQ/RSP normal — handler is
`wfi` (10500073) + `c.j .` → OpenSBI idle park, fif flushes repeat = WFI semantics, not a bug.

### Boundary established (frozen model)

- I$ geometry alias-clean: idx=vaddr[11:4], tag=paddr[63:12] (bit 12 tagged).
- `mem_data_o.paddr={cl_tag_d,vaddr_q[11:4],0}`; `read_miss_arm` requires `fetch_valid`
  (M-mode passthrough → always fresh in READ) → AR addr is request-correct by construction.
- wt_axi_adapter: id-0 channel serial, meta-fifo ordered, `i_icache_data` can't orphan
  (KILL_MISS/FLUSH drain or drop returns; abandon-before-push impossible via arm gating).
- `0x80012000` never executed/fetched this run (absent from RVFI/ITI/win traces) → the line
  content came from memory, not a resident line.

Insertion point therefore sits in: adapter request/return bookkeeping vs AXI-below
(shim/interconnect/memory model) — **unobservable on the frozen model**: all bus-side probes
are bring-up-capped (`[icf]` t<600, `[iax]` t<600, `[wta]` t<3000, `[soc]` t<4000).
Discriminating next step (needs a rebuild): uncap `+wta`/`+icf` in-window or add an ifill
AR/R probe keyed on paddr — capture whether AR on the bus was 0x80013000 (then R-side/memory)
or 0x80012000 (then request-record path).

### Secondary (real, not the cause)

`lopc=0x800136b6` stale leftover survived a bpf-kill at c=25541 (src=10) through ~300cy of
post-redirect windows — same leftover-not-rekeyed class as the fixed SRC_OV1 leg, but provably
benign here (pushed bytes are window data, not bank). Also `id-dbg` showed `dec_pc=0x80013008`
vs `fetch_addr=0x8001300e` skew and `is_illegal=0` on the poisoned 32-bit packet (cause-2
raised downstream) — worth a look when the frontend probes get uncapped.


---

## r21 diag + r22 repair — I$ wrong-line fill: REQUEST-SIDE, areq standing-response staleness (pmp_data_if currency key)

### ifill-diag-r1 verbatim (r21 model, +trace_from=25700 +trace_to=25900)

```
[ifill] t=25814 REQ paddr=00000080012000 tid=0 nc=0 cltd=00000080012 cltq=00000080012 vaq=0000000080013000 avld=1 apa=00000080012ff8
[wta2]  t=25814 ICREC push paddr=00000080012000 tid=0 nc=0
[wta2]  t=25816 AR head=00000080012000 araddr=0000000080012000 arid=0 tid=0 metapush=1
[soc]   t=25820 hart AR araddr=0x80012000 -> R beats = real pa-0x80012000 content (0186179bff853503 / e7b367410086169b)
[25827] %Error ifill_tag_match: installed tag 00000080013 != request tag 00000080012 (ifill record mis-association)
```

Attribution: **request-side**. The adapter request record and the issued AR are both
`0x80012000`; the AXI R data returned is the genuine content of pa `0x80012000`
(objdump-verified). The line was then INSTALLED under tag `0x80013` (the fresh cl_tag
for va `0x80013000`) — so the miss request itself went out one page down, and the
new `ifill_tag_match` sim-only assert caught exactly that mis-association.

### Mechanism (proven)

`mem_data_o.paddr = {cl_tag_d, vaddr_q[idx], 0}` with
`cl_tag_d = areq_i.fetch_valid ? areq_i.fetch_paddr[tag] : cl_tag_q`. At t=25814 the
request `vaddr_q=0x80013000` (4K page crossing) while `apa=0x80012ff8` — the areq
response still held the PREVIOUS request's paddr. The areq response is not
combinational-fresh: `pmp_data_if.sv:84` snapshots `if_req_q <= icache_areq_i`
EVERY cycle and drives `icache_areq_o` from the register. The icache FSM (READ,
`read_miss_arm`) treats `fetch_valid` as current — legal under the original comb
contract, wrong under the registered verdict boundary (added for the PMP's own
staging). The in-window trigger is the hyp8 W1-overlap accept in READ_V: the
previous request's last cycle holds `fetch_req=1`, so its response is standing in
`if_req_q` in the new request's first READ cycle. Same-page stale tags are
harmless; at a page crossing the stale tag stitches onto the new index →
AR one page down. Latent false-HIT leg identical (stale tag vs new index).

### Fix by identity (pmp_data_if.sv)

`icache_areq_o.fetch_valid = if_req_q.fetch_valid && (if_fetch_vaddr_q ==
icache_fetch_vaddr_i)` — present the standing response only while it answers the
vaddr currently on the request pins. `if_fetch_vaddr_q` was already registered
beside the response (for tval); the key costs one compare, zero new state. Within
a held request the vaddr never changes → zero added latency on the normal path;
only the one-cycle stale window at a request change is suppressed (the exact W1
overlap case). Exception injection in the same comb block is gated by the same
qualified valid. No counters, no contract change: the response is simply re-keyed
to the request it answers — the same "release/re-key by identity" rule as the
tagdom and areq fixes before it.

### Leaf (pmp leaf, new section F in tb_g6lc_hyp8_pmp)

Directed: response for A standing + request still A -> presented (F_A_*); request
moves across 4K with fresh B reply already on areq_i -> suppressed until B's own
response registers (F_B_STALE_SUPPRESSED/F_B_*); same-page next window also keyed
out (F_C_*); no-reply stays invalid (F_C_NOREPLY); retry of A presents its own
record (F_REPLAY_*). `HYP8_PMP_PASS checked=23` (tag hyp8-control-pmp-r14,
closure hyp8-control-r59-closure, model sha 3bca3834...).

### r22 build

`hyp8-integration-r22` (closure hyp8-integration-r22-closure, 816 files): sha-diff
vs r21 closure = `pmp_data_if.sv` ONLY — no new external edits in window. Lint
scalar rc=0 (WIDTHEXPAND 341 / WIDTHTRUNC 87 / LATCH 3), smt2 rc=0 (351/97/3),
`%Error` 0. Model `Variane_testharness` sha256
`dc2dc73c7fa5a6090cbf74d615ae216bd68bb00f8471b333205ab39a3879f96f`. Guard: 9
unrelated procs (allowed, recorded). Inputs: nm-verified tohost 0x80001000.

### r22 smokes — 3/3 REAL tohost

- hyp8-h34-r20:          `SUCCESS (tohost = 0) after 666 cycles`
- hyp8-h33-r15:          `SUCCESS (tohost = 0) after 889 cycles`  (h33 now passes
  on the external-arbiter tree — the grant_snap collapse resolved the r20 h33
  failure mode independently of the pmp fix)
- hyp8-branch-cancel-r7: `SUCCESS (tohost = 0) after 454 cycles`

### hyp8-osbi-scalar-r5 (frozen fw_payload.elf, +tohost_addr=0x80041730, 6M cycles)

Verdict verbatim:

```
fw_payload.elf *** SUCCESS *** (tohost = 0) after 6000000 cycles [cycle budget reached: no tohost verdict]
*** [mc_verdict] all 1 core(s) retired instructions
*** [mc_verdict] program exit code 0
*** [mc_gap] core 0 max retirement gap 314 cycles (limit 5000, wfi=0)
*** [mc_verdict] FAIL: a core ran and then stopped retiring (exit code 126)
[ckpt] final core=0 allocs=2036 pops=1865 pop_mismatch=0 pop_dead=0 restores=51 restore_mismatch=0 restore_dropped=51 refused=0 clears=11 | resolves br=1787 ret=35 jmp=94 mispredicts br=34 ret=1 jmp=16
[lsq-ev-miss] summary w=0..3 count=0
CPU time 1211298 ms / wall 1211277 ms
```

- **The pmp areq-currency fix cleared the wrong-line wedge**: the stream now
  retires cleanly through the whole 0x80013000 page — last retire `0x800130dc`
  (mv a0,s9) vs r4's stop at `0x80013004` before the cause-2 site. RVFI dasm
  13994 lines vs 9930 on r4; zero %Error in the full budget (the
  `ifill_tag_match` assert never fired).
- **New wedge, same lost-load family**: the next unretired instruction is
  `0x800130de: c.ld s9,56(sp)` (stack load, same class as r19's tid-5 evaporation
  and r3's parked same-page stack loads). ITI fetch trace also ends at
  `0x800130dc` — no further fetch/retire activity for ~5.97M cycles. No commit
  exception, no kill, no pop; the load vanished between allocation and
  completion — i.e., a sibling leg of the LSU lost-load class, NOT the areq
  staleness just fixed (which was fetch-side and is proven cleared).
- Discriminating read done at the wedge: RVFI tail (last 8 retires verbatim:
  `0x800130d6/0x800130d8/0x800130da` stack loads `x19/x21/x26 <- mem 0x80046e*`,
  `0x800130dc mv`), ITI tail (last entry 0x800130dc), objdump of
  `0x800130d0..0x80013100` (epilogue: stack reloads, `addi sp,144`, `ret`,
  `beq`, `j` — all ordinary). The unretired head is unambiguous.
- **UART: zero output** (the harness UART section is empty — OpenSBI had not
  reached console init before the wedge).
- Evidence: `/opt/testharness/runs/hyp8-osbi-scalar-r5/` (run-hyp8.log,
  trace_rvfi_hart_00.dasm 13994 lines, iti.traces).

### Status

r22 verifies the areq-currency repair end-to-end (leaf + smoke + witness: the
wrong-line fill mechanism is dead). The witness' first remaining semantic
failure is the LSU lost-load family at `c.ld s9,56(sp)` — the r19 tid-5 class
whose bypass-shadow leg was already gated (fus_busy while |lsu_valid_q) but which
evidently has at least one more live leg. Next discriminating step (lead's
call): r22-diag rerun with `+ld_state +stq_trace +lsu_bypass probes` in
+trace_from=33200 +trace_to=33600 — wedge edge is ~c33340 — to name which LSU
record dropped this load (same disambiguation recipe that named tid-5).


## r25 — IQ-bank phantom-taken repair (partial dispatch ack root-caused); witness reaches a frontend wrong-path skip (new family)

### Fix (this round)

- `core/ooo/g6lc_iq_bank.sv` allocation scan: free-slot `lone` selection was
  accumulated into `taken` for **every** lane, including lanes whose
  `alloc_i[p]` was 0. With a bank at exactly one free entry and only lane 1
  requesting that bank (`alloc_i={0,1}`), lane 0's inactive scan still consumed
  the slot → lane 1 got no ack → partial `iqdisp_ack=01` → dispatch replayed
  the group → stale `grp_tid_q` reuse → upstream `scoreboard.sv:283`
  "Issue acknowledged but instruction is not valid" (r24 witness, c57031).
- Exact change: `taken |= lone & {ENTRIES{alloc_i[p]}};` — accumulate only
  slots consumed by active lanes. Pre-existing latent bug (present in both
  pre- and post-external-rewrite versions); exposed by Hyp8 steering.

### Directed leaf — dispatch section J

- `verif/tb/core/tb_g6lc_hyp8_control.sv`: lane-1-only fill drives one bank to
  1 free entry (poison producer keeps fillers unready so slots stay resident;
  +NP steering offset accounted), then a two-lane group whose lane 1 steers to
  the starving bank. Checks: all-or-nothing `iqdisp_ack`, no partial ack, no
  stale-lane replay, exactly +2 IQ allocations.
- Result: `HYP8_DISPATCH_PASS checked=40` (tag `hyp8-control-dispatch-r14g`,
  closure `hyp8-control-r62-closure`). On the buggy tree iqdack would have
  been `01` → `J_IQDACK_PARTIAL` fatal — discriminating regression.
- Bench iterations: `JDBG`/D1 prints retained; occupancy via `bank_free`
  (Verilator can't variable-index gen scopes).

### Build — hyp8-integration-r25

- Closure 816 files; **sha-diff vs r24 = `g6lc_iq_bank.sv` + `g6lc_ooo_dispatch.sv`
  only — no new external edits.**
- Lint: scalar rc=0 (WIDTHEXPAND 343, WIDTHTRUNC 87, LATCH 3, %Error 0);
  smt2 rc=0 (353/97/3). Runtime dep check OK.
- Model `Variane_testharness` sha256
  `8de994efc7ee9a2efbb575f40e0309e73d1844ac2c652fcc5e5c60b80285c2c4`.

### Smokes — 3/3 real tohost

| tag | verdict |
|---|---|
| hyp8-h34-r23 | `*** SUCCESS *** (tohost = 0) after 666 cycles` |
| hyp8-h33-r18 | `*** SUCCESS *** (tohost = 0) after 889 cycles` |
| hyp8-branch-cancel-r10 | `*** SUCCESS *** (tohost = 0) after 454 cycles` |

### Witness hyp8-osbi-scalar-r8 — STOP: budget-out; frontend wrong-path skip (NEW family)

Frozen ELF sha `a9218107…`, `+tohost_addr=0x80041730`, 6,000,000 cycles.
Verdict verbatim:

```
fw_payload.elf *** SUCCESS *** (tohost = 0) after 6000000 cycles [cycle budget reached: no tohost verdict]
*** [mc_verdict] all 1 core(s) retired instructions
*** [mc_verdict] program exit code 0
*** [mc_gap] core 0 max retirement gap 314 cycles (limit 5000, wfi=0)
*** [mc_verdict] FAIL: a core ran and then stopped retiring (exit code 126)
[ckpt] final core=0 allocs=3553 pops=2834 pop_mismatch=0 pop_dead=1 restores=210 restore_mismatch=0 restore_dropped=210 refused=0 clears=11 | resolves br=2513 ret=120 jmp=411 mispredicts br=108 ret=1 jmp=101
```

Zero %Error, zero UART. 26,194 RVFI retires (vs 13,994 on r5) — the iq_bank
fix cleared the mid-boot wedges.

#### Discriminating read (all from RVFI+ELF, no probes needed)

1. **Park site**: last retire `0x800074e4 c.ld s6,48(sp)`; next unretired
   `0x800074e6 wfi; wfi; j .` — `sbi_hart_hang()` inlined in
   `fw_platform_init+0x286`.
2. **Error path**: `bltz a0,800074dc` at `0x8000733e` — taken because
   `fdt_path_offset(fdt, "/cpus")` returned `a0 = -8` (FDT_ERR_TRUNCATED;
   RVFI `mv a1,a0` at 0x8000733c → `x11=0xfffffffffffffff8`).
3. **FDT bytes verified correct in memory**: lbu reads show
   magic `d00dfeed`, totalsize `0x843`, off_dt_struct `0x38`, version `0x11`,
   size_dt_struct `0x63c`, path `/cpus ` at 0x8001f478 — header intact.
4. **The walk's struct reads**: `e038`=FDT_BEGIN_NODE, `e03c`=name "",
   `e040`=`0x03000000`→PROP — then the len read at e044 **never happened**;
   `fdt_offset_ptr` returned NULL at its totalsize bound (`bltu a4,a6` taken
   at 0x800128f4 → `*nextoffset=-8` → TRUNCATED).
5. **Root cause — a control-flow skip**: the second `fdt_next_tag` call
   (entry `mv s5,a1` → s5=8 verified) computed `s2=3`=PROP correctly
   (full bswap chain retired, x18=3), but **every instruction from
   `0x800129ca` (`sw`) through `0x80012a16` (`mv a1,s5`) never retired** —
   the dispatch tail (sw/li/mv/bltu/auipc/addi/slli/add/lw-table/add/jr),
   the whole PROP case (0x80012a2c-0x80012aa4 incl. its lenp `jal`), and the
   shared-tail head (li a2,4 / mv a1,s5) are all absent from the entire
   26k-line retire stream. Execution surfaced at `0x80012a18` (`mv a0,s4`)
   → `jal fdt_offset_ptr`.
6. **Stale operands prove the skip**: callee computed `a3=off_dt_struct+a1=
   0x38` → a1=0 = leftover of `slliw a1,a5,0x18`(→0); the failing bound used
   a2 = leftover `lui a2,0xff0` = `0xff0000` → `0x38+0+0xff0000 > 0x843` →
   NULL. Both stale values exactly match the last writes before the gap —
   confirmed semantic (not a trace hole: the callee arithmetic itself
   observes the stale a1).
7. **Mechanism family**: ~86 bytes of correct-path code skipped; control
   landed mid-handler at `0x80012a18`. Candidates: (a) stale-PC redirect —
   `0x80012a18` = `c.j 0x80012a16` target +2 (the stale `lopc` leftover
   class already flagged at fe-diag), (b) BTB/predicted-jr corrupted target,
   (c) a squash that killed correct-path and redirected wrong. This is a
   **frontend redirect/PC-tracking failure — a NEW family**, not the LSU
   lost-load class. Needs frontend probes (redirect target vs BTB vs
   realigner pc) to name the leg; the stale-`lopc` fix is the prime suspect.

- Evidence: `/opt/testharness/runs/hyp8-osbi-scalar-r8/` (run-hyp8.log,
  trace_rvfi_hart_00.dasm 26194 lines, iti.traces, fw.dasm dump,
  fdwalk.txt FDT-code disasm excerpt). RVFI analysis verbatim above.


## hyp8-integration-r27 + witness hyp8-osbi-scalar-r10 (2026-10-23)

**Change**: `core/ooo/g6lc_rename_recover.sv` — the translate_off
equivalence assert `one-hot select != arithmetic select` is now gated on
`ref_take` (was `mispredict_i`), the $fatal prints
sel/ref/lvl/hart/cnt/head, and a $display logs void-select divergence.

**Root cause of the r9 abort at c691969**: a mispredict that arrives on an
EMPTY hart ring (cnt_m==0 — stale in-flight resolve of a branch whose
checkpoint an earlier unwind already popped, or a tid_ckpt level='1')
makes sel_take=0 and sel_level='0 (no pos match). The arithmetic
reference underflows unsigned: `rel = cnt_m-1` = 0xFFFFFFFF →
`ref_level = ckpt_slot(hart, head+0xFFFFFFFF)` = garbage. The ungated
assert compared the don't-care level anyway → $fatal. sel_take==ref_take
and sel_hart==ref_hart are literally the same expressions, so the only
content was level equality — only owed when the select is consumed.
Functional behavior identical to the pre-rewrite arithmetic (which
produced the same garbage, equally unused: take=0 → rec_v_q=0 → no
repair).

**Leaf** (`hyp8-control-dispatch-r15`, closure hyp8-control-r66):
section K reproduces the exact leg — two branch ckpts, mispredict the
older → unwind to pos-0 slot → cnt=0 → stale second resolve (dead-slot
level) → void select. Verbatim:

    [2008] rename_recover: void select on empty ring: lvl=1 sel_level=0 ref_level=31 cnt=0 head=0
    HYP8_DISPATCH_PASS checked=45

(+5 checks vs r14g: K_TWO_CKPTS/K_RING_NOT_EMPTY/K_VOID_REPAIR/
K_VOID_CNT/K_POST_CKPT.)

**r27 build**: closure hyp8-integration-r27-closure, 816 files; sha-diff
vs r26 = g6lc_rename_recover.sv ONLY (19df0296e61c -> b8c60015e9f8);
no new external edits. Lint scalar rc=0 %Error=0 (WIDTHEXPAND 343/
WIDTHTRUNC 87/LATCH 3), smt2 rc=0 (353/97/3). Model sha256
35b5c7a5c69d7a4f1844dd9a68d9889daa576f749339f7b437eedd514518b873.

**Smokes (r27)**: h34-r25 SUCCESS (tohost=0) @666; h33-r20 @889;
branch-cancel-r12 @454 — 3/3 real tohost.

**Witness hyp8-osbi-scalar-r10** (frozen fw a9218107, +tohost_addr=
0x80041730, 6M): the void leg fired at the EXACT r9 abort cycle:

    [691969] rename_recover: void select on empty ring: lvl=10 sel_level=0 ref_level=9 cnt=0 head=10
    [967123] rename_recover: void select on empty ring: lvl=12 sel_level=0 ref_level=10 cnt=0 head=11

gate held both times; run continued. 627,776 RVFI retires (r9: 443,418)
— reached sbi_init. [ckpt] allocs=57087 pops=46640 pop_mismatch=0
restores=2605 restore_mismatch=0; mispredicts br=1733 ret=109 jmp=763.
ZERO %Error.

**Verdict**: budget-out FAIL — `a core ran and then stopped retiring
(exit 126)`. New wedge: `sbi_init` prologue — `sd s2,160(sp)` @0x800006ec
retired; `sd s3,152(sp)` @0x800006ee fetched (ITI through 0x8000070a) but
never retired. Stack-store disappearance mid-prologue — same LSU-domain
lost-op family signature as the tid-5 lost-load class. Zero UART.
Evidence: /opt/testharness/runs/hyp8-osbi-scalar-r10/ (run-hyp8.log,
trace_rvfi_hart_00.dasm, iti.traces); local pull hyp8-r27-smokes-witness/.

**Next**: probe the wedge — the retire-gap counter reported max gap 324
yet retirement halted; need +ld_state/+stq_trace/+commit_trace around
the wedge cycle (determine from a +rvfi_cycle_stamp run; last fetch
~0x8000070a, wedge inside sbi_init prologue at ~c1.0-1.2M range).

================================================================
r28 — sb_cancel dead-slot identity fix (stale B2 resolve after free)
================================================================

**Diagnosis (from stq-diag + r10 witness trace)**. The sbi_init wedge
(sd s3,152(sp) @0x800006ee never retiring) is NOT a new LSU lost-op —
the LSU path is clean. The real defect found by the trace: a stale
registered B2 branch-resolve record redirecting the frontend AFTER its
scoreboard slot was cancelled and dropped:

    c=967108  tid=4 resolves REAL mispredict -> redirect 0x8000099c;
              cancel window covers younger tids 5..9
    c=967109  tid=7 (pc 0x80000736, FU4, younger branch) dropped
              (commit/drop clears BOTH issued and cancelled per
              sb_lifecycle.sv commit-ack path)
    c=967110  tid=7's already-in-flight registered B2 record still
              publishes mispredict -> redirect 0x80000766 (stale target)
    c=967123  rename_recover: void select on empty ring (lvl=12) —
              consequence of the stale resolve, not an independent defect
    c=967127  [disp] alloc tid=10 ... at redirected (wrong) stream

Root cause: `cancelled_mask_o` encodes the transient `cancelled` bit,
which sb_lifecycle clears together with `issued` on commit/drop. A
registered resolve record that arrives one+ cycles after the drop finds
`cancelled=0` and passes the `~cancelled_mask` gates in ex_stage and
the FE redirect path. Cancellation bits are not durable allocation
state — they cannot identify a DEAD slot.

**Fix (sb_cancel.sv)**: qualify resolve/cancel identity by slot
liveness (`issued`) instead of only the `cancelled` bit:
  - `cancelled_mask_o[t] |= ~mem_q_i[t].issued` — a slot no longer
    allocated is dead to resolve consumers regardless of cancel state.
  - `bmiss_o` gated so a dead-tid resolve cannot publish kill/mispredict.
Rationale: `sbe.valid` is RESULT validity (0 for allocated-not-yet-
written ops) — folding it in would wrongly mask live work; `issued`
is the allocation bit and is set at dispatch, cleared only at
commit/drop — exactly the liveness needed. Current-cycle allocation
is not in mem_q yet and cannot produce a same-cycle resolve.

**Directed leaf** — dispatch Section L (tb_g6lc_hyp8_control.sv):
drives sb_cancel + the resolve publish path with a branch tid whose
slot is cancelled and dropped (issued->0, cancelled->0 via the
commit-ack path), then presents the stale resolve: assert no
kill/mispredict escape, cancelled_mask[tid]=1 while dead, and a live
resolve on a different tid still publishes. Result:

    HYP8_DISPATCH_PASS checked=58
    (renamed recover void-select diag [2008] still prints — expected)

**r28 build**: closure hyp8-integration-r28-closure, 816 files;
sha-diff vs r27 = core/sb_cancel.sv ONLY (+manifest); no new external
edits (tb file already carried the L section as harness). Source hash
47e6550f11e5 -> c5b0e2fc9ba2. Lint scalar/smt2 + model: see below.

**Smokes (r28)** / **Witness hyp8-osbi-scalar-r11**: see below.

**r28 first-attempt regression (h33-r21)**: smokes STOPPED at h33 --
budget-out, core parked. Traced rerun (hyp8-h33-r21-diag, +ld_state
+stq_trace +disp_trace +lsq_trace +commit_trace, 6k budget): last
retire sd t0,0(s0) @0x80000022 tid=16; the forwarding ld t1,0(s0)
@0x80000026 tid=17 pinned at commit head (cptr=17, slot valid=0).

Verbatim lifetime: alloc c=404, grant c=407, take c=408, pop c=409,
lsqb insert c=411 / pop_ld c=412, [ldst] c=412 dreq=1 gnt=1
va=0x80001050 -> ldb entry 1 allocated, tv=1 c=413, then rvld=0
forever (ldb=00000001 stuck). The store's STQ record cq0(t16,pa050)
went v1->v0 at c=441 ~1 edge after push: g6lc_lsq_slot drops st_d on
cancelled_mask_i[id] and slot16's commit-ack had cleared .issued ->
the ~issued mask term marked the committed-but-undrained store dead.
Kill of post-commit LSU bookkeeping = mask over-extension.

**Fix revision (r28b)**: cancelled_mask_o reverted to cancelled-only
(same-cycle bmiss window unchanged). Dead-slot authority enforced at
the two resolve gates instead: sb_cancel bmiss_o requires
mem_q_i[tid].issued (dead resolve opens no cancel window); ex_stage
br_lane_v gains & sb_live_i[trans_id] (dead resolve publishes no
record/pulse/redirect). Leaf L re-semanticed: free slots unmasked,
freed slots unmasked, stale resolve -> !bmiss && kill==0.
HYP8_DISPATCH_PASS checked=57 + HYP8_MEMORY_PASS checked=88
(hyp8-control-dispatch-r17, closure r68).

**r28b build**: closure hyp8-integration-r28b-closure, 816 files;
sha-diff vs r27 = sb_cancel.sv + ex_stage.sv only; no external edits.

## r28b wedge diag (hyp8-osbi-fe-diag-r3/r4, [smt-flow]+[icf] on the frozen model)

The r28b witness (hyp8-osbi-scalar-r11) wedged again at ~c965.2k with the
same architectural signature (a0 stale into a jal at the redirected
stream). Windowed traces on the IMMUTABLE r28b model (newer
fetch_snap/fetch_supply probes absent from that closure; [win] capped at
t<200k) pinned the loss:

    c965208 [smt-flow] control flush=0 flush_unissued=1 resolve=1
            mispredict=1 target=0x8000099c   <- REAL redirect record
    c965209 redirect applies: FTQ flush+push 0x8000099c@(e+1);
            npc_q <- next_block = 0x800009a0
    c965210 [smt-flow] control flush=1 flush_unissued=1 resolve=0
            mispredict=1 target=0x80000766   <- STALE resolve: dead-slot
            fields (sb_live gate zeroed valid, is_mispredict still reads 1)
    ~965211 flush_if -> FTQ flush + same-cycle push of fetch_address =
            npc_q = 0x800009a0 -> the 0x8000099c entry is destroyed one
            cycle after its creation; redirect_rehold is !ftq&&...=0
            under FtqEn so the lost target is never re-presented
    c965225 demand issues head 0x800009a0; first alloc pc=0x800009a0
    -> 0x8000099c: li a0,0x53 silently dropped (argument to the callee
       at 0x80007a02; jal/ret continue the wrong-value stream)

Mechanism: controller.sv raised flush_if_comb/flush_unissued_comb on
`resolved_branch_i.is_mispredict` WITHOUT the `resolved_branch_i.valid`
gate. The r28b dead-slot fix suppressed `valid` at the ex_stage/scoreboard
gates (br_lane_v &= sb_live) but the controller consumes the raw record:
a dead resolve's residual is_mispredict=1 field produced a bare
flush_if with no redirect record -- the one case where the FTQ
flush+push npc reseed permanently orphans the architectural target
(every real flush carries its own redirect record that reseeds next
cycle). Confirmed chain: [smt-flow] resolve=0&mispredict=1 at c965210
(the exact bus state), controller leg at controller.sv:242 ungated,
i_frontend.flush_i <- flush_ctrl_if (g6lc_core.sv:1287), FTQ
flush+push(fetch_address) reseeds head, demand trace REQ 0x800009a0.

**Fix (controller.sv)**: gate the mispredict leg on
`resolved_branch_i.valid` -- an invalid record produces no flush at all
(this also removes a spurious flush_unissued of live unissued work on
the same stale event). Wrapped in `ifdef G6LC_MUT_CTRL_STALE_RESOLVE`
review-mutation per the established convention.

**Directed leaf** -- new tb_g6lc_hyp8_ctrl section in
tb_g6lc_hyp8_control.sv + 'ctrl' entry in run_hyp8_memory.py: idle,
invalid-resolve-with-mispredict-field -> zero flush outputs, valid
mispredict -> IF+unissued only, valid predicted-correct -> no flush,
eret full flush preserved, invalid junk record -> no flush.

    HYP8_CTRL_PASS checked=6                          (hyp8-control-ctrl-r1)
    mutant A/B: HYP8_EXTRA_DEFINES=G6LC_MUT_CTRL_STALE_RESOLVE
      -> FAIL CTRL_STALE_RESOLVE_NO_FLUSH             (r1mut, expected)

**r29 build**: closure hyp8-integration-r29-closure, 816 files;
sha-diff vs r28b = core/controller.sv (this fix) + core/ooo/g6lc_iq_arb.sv
(external comment/whitespace-only churn -- no functional delta; flagged as
external edit). Lint scalar/smt2 + model + smokes + witness: see below.

================================================================
r30 — load_unit ex_pub kill-cycle identity fix (misaligned-entry
exception suppressed on its own dummy rvalid)
================================================================

**Witness failure (hyp8-osbi-scalar-r12, r29 model)**: at c=1168793
`load_unit.sv:1459` assertion `misaligned_entry_excepts` fired.
Faulting insn: pc 0x8000b71c `ld a4,0(a6)` (enc 0x00083703) with
a6=1 — a genuine RV64 misaligned LD on the wrong-path side of a ret.
Lifetime: lsq insert tid=17 c=1168778, pop/load-head c=1168779; load
unit accepted+granted same cycle (LU_B_IDLE, data_req=gnt=1, va=1,
pop=1) -> LU_S_SEND_TAG expected next; no exception was ever
published before the assert.

**Root cause**: the misaligned exception is generated in
load_store_unit and reaches the load unit through pmp_data_if
(DATA_VERDICT_STAGES=0 — combinational for the request cycle; timing
skew eliminated). In LU_B_SEND_TAG, ex_i.valid raises kill_send ->
kill_req_w, and the D$ returns a dummy data_rvalid for the killed
tag's OWN slot (rresp_idx == ldbuf_last_id_q). The ex_pub term was

    ((ldbuf_last_id_q != rresp_idx) || !kill_req_w)

— under a kill it published only for OTHER slots' responses, so the
one response the killed request is guaranteed (its own dummy) was
excluded: valid_o/ex_o.valid never asserted. The same term could also
publish the standing exception on an UNRELATED slot's response under
a kill (mis-attribution). Identity-correct:

    ((ldbuf_last_id_q == rresp_idx) || !kill_req_w)

**External-churn note**: between the r29 closure and this fix the
external rewrite pass restructured load_unit.sv (~drn/pub pick
refactor) at 08:33:09 and REVERTED the first application of this fix
to the buggy `!=` (its own comment still describes the correct
semantics: "the tag that owns this response"); the identity term was
re-applied at 08:42:22 on the rewritten predicate and verified stable
through the r30 build. g6lc_rename_recover.sv was rewritten twice in
the same window and returned to its r29 content (no net diff).

**Directed leaf** — new tb_g6lc_hyp8_memory section F (memory leaf
source closure extended with cf_math_pkg + g6lc_hyp_lzc +
load_unit): the real load_unit DUT, MmuPresent=0, misaligned RV64
LD (vaddr bit0): grant at IDLE -> SEND_TAG, then same-cycle
ex_i(LD_ADDR_MISALIGNED) + dummy data_rvalid on the tag's own rid
must publish valid_o+ex_o.valid+cause=4+tid and free the slot
exactly once; a second LD on a different slot id repeats the leg
(the publish follows last_id's slot, not a fixed index). Result:
HYP8_MEMORY_PASS checked=99 (+11 vs 88; tag hyp8-control-memory-r30b,
closure hyp8-control-r30b). Mutant A/B on the captured pre-fix tree
(closure hyp8-control-r30, `!=`): LU_MIS_EX_PUBLISH fails while
LU_MIS_REQ/SEND_TAG/KILL all pass — exactly the witness suppression
(tag hyp8-control-memory-r30mut5). Bench delta: two #2 settle gaps
added after comb drives (Verilator reads downstream comb after the
next eval point; acc=0 was a stale read, not a gate).

**r30 build**: closure hyp8-integration-r30-closure (816 files).
sha-diff vs r29:
  core/load_unit.sv             (this fix)
  core/ooo/g6lc_iq_arb.sv       (external: win_oh per-candidate
                                 column gather restructure)
  core/ooo/g6lc_iq_bank.sv      (external: registered e_cancl —
                                 ready reads last cycle's cancel;
                                 take/next-state see live mask)
  core/ooo/g6lc_lsq_verdict.sv  (external: per-bit column gathers
                                 for wait/stl/viol picks)
Lint scalar rc=0 (WIDTHEXPAND 343/WIDTHTRUNC 87/LATCH 3, %Error 0),
smt2 rc=0 (353/97/3). Model sha256
07a54529efbe501cc49f22600257f07fe8021d3e9cca4b4dc8c24ef392925c57.

**Smokes (r30)** — 3/3 real tohost:
  hyp8-h34-r29           SUCCESS (tohost=0) @682
  hyp8-h33-r25           SUCCESS (tohost=0) @889
  hyp8-branch-cancel-r16 SUCCESS (tohost=0) @475

**Witness hyp8-osbi-scalar-r13** (frozen fw a9218107,
+tohost_addr=0x80041730, 6M): 2,306,327 RVFI retires — past the r12
assert cycle (1,168,793) with ZERO %Error; the misaligned-entry leg
is proven in vivo. Verdict verbatim:

    fw_payload.elf *** SUCCESS *** (tohost = 0) after 6000000 cycles
      [cycle budget reached: no tohost verdict]
    *** [mc_verdict] FAIL: a core ran and then stopped retiring
      (exit code 126)
    [ckpt] allocs=211229 pops=175376 pop_mismatch=0 restores=8808
      mispredicts br=5773 ret=40 jmp=2995

New wedge signature (discriminating read):

    last retire  0x8000ea9a  add a4,a3,zero   (x14=0x80045ec0)
    next insn    0x8000ea9e  csrrw a2,mtvec,a2 (sbi_hart_init)
    ITI fetch trace ALSO ends at 0x8000ea9a — the csrrw was never
    fetched: a frontend/fetch-side starvation boundary, not CSR
    decode and not LSU. encaps.traces shows continued activity
    after the last retire.

Evidence: /opt/testharness/runs/hyp8-osbi-scalar-r13/ (run-hyp8.log,
trace_rvfi_hart_00.dasm 2,306,327 lines, iti.traces); local pull
hyp8-r30-smokes-witness/.

**Next**: locate the last-retire cycle with +rvfi_cycle_stamp, then
a windowed frontend diag (+fe_trace +win_trace +icf_trace
+smt_flow_trace, +-200 cycles) to name the gate that stopped fetch
issue at the mtvec boundary (FTQ head, pending resolve/flush,
queue-full, or a fetch sideband parked on the CSR write).
