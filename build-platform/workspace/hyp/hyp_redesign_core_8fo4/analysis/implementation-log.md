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


## r31 — loop-buffer inject identity + hang-dump CSR/FE owners (2026-10-23)

**Defect (loop buffer)**: `hit_q`/`hit_data_q` were captured at `seq_hit`
for `lookup_vaddr_i` (the FTQ head) but `consume_o = hit_q &&
lookup_ready_i` never re-checked that the head being injected into was
still the same head/epoch; `seq_hit` also did not require the head to be
valid. A flush/reseed between detection and consume (FTQ re-pushed with a
redirect target; the lbuf flush did not include `reseed_now`) injected the
OLD block's bytes under the NEW head address.

**Diff** (all under `hyp_redesign_core_8fo4/core/`):
  - `frontend/g6lc_loop_buffer.sv`: new input `lookup_valid_i`; new
    registers `hit_vaddr_q`/`hit_epoch_q` captured with the hit;
    `seq_hit` now requires `lookup_valid_i`;
    `hit_live = hit_q && lookup_valid_i && lookup_vaddr_i==hit_vaddr_q &&
    hit_epoch_q==epoch_i`; `hit_o`/`consume_o`/`active_o` all gated by
    `hit_live`; flush dominates the hit register (no re-arm on the flush
    cycle); stale hits (`hit_q && !hit_live`) are retired, not injected;
    new translate_off assertion `g6lc_loop_buffer: inject identity`.
    The old expressions are preserved under `ifdef
    G6LC_MUT_LBUF_STALE_HIT` as a review mutation.
  - `fetch_B/frontend.sv`: `i_lbuf` gains `.lookup_valid_i(ftq_head_valid)`
    and `.flush_i(... | reseed_now)`.
  - `g6lc_core.sv`: `hd_print()` gains `[hang] CSR seam` (csr_buffer
    tab_q[0..1] + commit_hit/commit_release, csr_decode staged-request
    taps, rdata_valid, commit_csr, commit port 0) and `[hang] FE` (FTQ
    head/full/cf_hold/demand/pf, iq_ready/halt/reseed/flush/replay/
    mispredict/epoch/npc, redirect_inflight/lost, fetch-entry handshake,
    lbuf state, icache_dreq ready). `md_stall` -> `|md_stall_v` tracks
    the external rename.
  - `smt/g6lc_smt_csr_bank.sv`: new translate_off `dbg_csr_req_*` tap
    arrays assigned inside `gen_single`/`gen_csr` — Verilator cannot
    index `gen_csr[h]` scopes from outside, so the bank surfaces the
    per-hart staged request (valid/op/addr/tid/match/apply) as flat
    arrays; hd_print indexes them by the port-0 head's hart.
  - `Flist.g6lc_hyp8`, `verif/regress/remote/hyp8/Flist.hyp8_sim`:
    `g6lc_ooo_pkg.sv` moved before `axi_pkg.sv` — required because the
    external pass added `g6lc_ooo_pkg::ooo_lat_class(...)` to
    `issue_read_operands.sv`, which otherwise fails elaboration:
    `%Error-PKGNODECL: ... issue_read_operands.sv:654:14: Package/class
    'g6lc_ooo_pkg' not found, and needs to be predeclared (IEEE
    1800-2017 26.3)`.

**Directed leaf** (`lbuf` section of tb_g6lc_hyp8_control.sv, tag
hyp8-control-lbuf-r1b): arm on a taken branch at B+0x18->B, fill D0..D3,
normal hits at B and B+8, reseed-without-flush under a held hit
(LBUF_STALE_NO_INJECT / LBUF_DEMAND_RESUMES / LBUF_REHIT_D2), epoch bump
under a held hit (LBUF_EPOCH_NO_INJECT), flush coincident with detection
(LBUF_FLUSH_NO_INJECT). Result:

    HYP8_LBUF_PASS checked=22
    HYP8_LBUF_LEAF_PASS warnings=none census={'PINMISSING': 3,
      'LITENDIAN': 7, 'WIDTHEXPAND': 15, 'WIDTHTRUNC': 2}

Mutant (tag hyp8-control-lbuf-r1mut, HYP8_EXTRA_DEFINES=
G6LC_MUT_LBUF_STALE_HIT) fails the stale-hit protection check, proving
the bench discriminates:

    FAIL LBUF_STALE_NO_INJECT

**Discriminator re-run on the frozen r30 model** (tag
hyp8-osbi-scalar-r13-hang, frozen fw a9218107, +stall_census
+hang_dump=2000): wedge reproduces, `*** [mc_verdict] FAIL: a core ran
and then stopped retiring (exit code 126)`; 1,153,186 hart-0 RVFI
retires, last at 0x8000ea9a. Three dump bursts at cyc 3608591/3609591/
3610591; the head of the scoreboard is the csrrw itself:

    [hang] SB head slot=22 issued=1 valid=0 cancelled=0 replay=0 fu=6
      op=33 pc=000000008000ea9e tid=0 ex=0 | port0 valid=0 fu=6
      pc=000000008000ea9e ack=0 drop=0 | commit_ptr=22 issue_ptr=21
    [hang] LSQ ld[0] id=0 addr_v=1 done=0 addr=00000080040038
    [hang] LSU bypass ... LU state=1 ldbuf_v=00000010 ...

Contrary to the r30 note ("the csrrw was never fetched"), the SB head
entry shows the mtvec write WAS issued and never produced a committable
result. mtvec grep on trace_rvfi_hart_00.dasm: 0 literal hits (the dasm
prints encodings); the same mtvec-op encodings 0x30561673/0x30561073
retired earlier at 0x8000ea70/0x8000ea78 in the same function.

**r31 build**: closure hyp8-integration-r31-closure (816 files), tag
hyp8-integration-r31c. Lint scalar rc=0 (WIDTHEXPAND 343/WIDTHTRUNC
87/LATCH 3 — identical to r30), smt2 rc=0 (WIDTHEXPAND 354/WIDTHTRUNC
97/LATCH 5 — +1 expand, +2 latch vs r30's 353/97/3). Model sha256
7116737ac7284e55859ea692795a23878a0df118ddf49e8e27c05b16a9b9549e.
sha-diff vs r30 closure (17 files): MINE —
fetch_B/frontend.sv, frontend/g6lc_loop_buffer.sv, g6lc_core.sv,
smt/g6lc_smt_csr_bank.sv, Flist.hyp8_sim; EXTERNAL — ex_stage.sv,
include/build_config_pkg.sv, issue_read_operands.sv, issue_stage.sv,
load_store_unit.sv, lsu_bypass.sv, ooo/g6lc_flu_reserve.sv,
ooo/g6lc_iq_arb.sv, ooo/g6lc_iq_bank.sv, ooo/g6lc_iq_legal.sv,
ooo/g6lc_memdep.sv, ooo/g6lc_ooo_dispatch.sv. Session-window churn
(sha-before -> sha-after): only my 5 core-tree files changed; no
external edits landed during the pass.

**Smokes (r31)**: hyp8-h34-r30 SUCCESS (tohost=0) @682 (= r30 @682);
hyp8-h33-r26 FAIL — budget-out, no real tohost (r30 passed @889);
hyp8-branch-cancel-r17 SUCCESS (tohost=0) @473 (r30 @475). A/B closure
hyp8-integration-r31x-closure = r30 + only my 5 files (external hunks in
g6lc_core.sv reverted, `md_stall` restored) builds clean (model sha256
62926815268e405638608a99f8da27d0dec889e7db868642fcb9dcb2380d85ab) and
hyp8-h33-r26x passes @889 — the h33 store-forward regression is owned by
the EXTERNAL edits; branch-cancel also passes on r31x @475.

**Witness hyp8-osbi-scalar-r14** (r31 model, same recipe + stall_census/
hang_dump): wedge does NOT reproduce — 2,049,766 RVFI retires (census
ret=2,066,236), max retirement gap 314 cycles, zero [hang] lines, zero
%Error, zero UART, verdict `SUCCESS (tohost = 0) after 6000000 cycles
[cycle budget reached: no tohost verdict]` with NO mc_verdict FAIL.
Attribution witness hyp8-osbi-scalar-r14x (r31x model): the wedge DOES
reproduce bit-for-bit (same ret=1,165,719 census, same SB head
0x8000ea9e fu=6 op=33 issued=1 valid=0, FAIL exit code 126) — the
external edits, not the loop-buffer fix, carry the r14 repair. The lbuf
fix is a real latent-defect repair (mutant-proven) but not the wedge
cause. On the reproducing wedge the new B2 diagnostics resolve the
owner:

    [hang] CSR seam: buf[0] v=1 tid=23 addr=da0 | buf[1] v=1 tid=5
      addr=c01 | hit=0 rel=0 rdy=0 | req v=0 op=0 addr=305 tid=10 |
      match=0 apply=0 rdata_v=0 | commit_csr=0 | port0 v=0 fu=6 tid=22
      ack=0
    [hang] FE: head v=1 pc=000000008000eb5e ftq_full=0 cf_hold=1
      demand=0 pf=0 | iq_rdy=0 halt=0 reseed=0 flush=0 replay=0 misp=0
      epoch=4 npc=000000008000eb60 | red_iq=0 lost=0 fe_v=01 fe_rdy=00 |
      lbuf act=0 hold=0 hit=0 armed=0 capt=0 | ic_rdy=1

Read: the staged CSR request register is EMPTY (req v=0; the mtvec op
is not parked in csr_regfile), the csr_buffer holds two unrelated
transactions (tid=23 addr 0xda0, tid=5 addr 0xc01), and the frontend
already ran ahead to pc=0x8000eb5e with the loop buffer fully idle —
the wedge is downstream of decode, in the CSR ex/commit publish path
consistent with SB head issued=1 valid=0 and the unresolved
LSQ ld[0]/ldbuf entry.

Evidence: local pulls hyp8-osbi-scalar-r13-hang/, hyp8-r31-smokes/,
hyp8-r31x-h33/, hyp8-bc-ab/, hyp8-osbi-scalar-r14/,
hyp8-osbi-scalar-r14x/, hyp8-integration-r31b|31c|31x/output/results.json,
hyp8-control-lbuf-r1b|r1mut/output/; remote run dirs under
/opt/testharness/runs/ of the same names.

## r32 — CSR table identity (alloc cancel-qualification + owner-liveness release)

### STEP 1 — discriminating trace: H-LEAK refuted, H-CREDIT refuted

Probe build `hyp8-integration-r31xp` (r31x basis = r30 + agent r31 files +
`+csrtab_trace` event trace in csr_buffer.sv gen_ooo and an IRO-side
`[csrtab] iro_ack` print; model sha256
`715cf64e846177edc3db89b1fe92fbfe59af6d031812918d21532ad27fa2f9aa`).
Witness `hyp8-osbi-scalar-r14xp` (+csrtab_trace +stall_census
+hang_dump=2000, pinned fw a9218107…): wedge reproduces bit-for-bit —
1,153,186 hart-0 RVFI retires, last retired pc `0x8000ea9a`, exit 126,
102 `[hang]` lines, 1084 `[csrtab]` lines.

Wedge-window csrtab excerpt (allocs show cmask, release/cancel events
follow each entry):

    [csrtab] cyc=3606456 cancel_sweep ent=0 tid=27 addr=30a
    [csrtab] cyc=3606511 alloc tid=8  addr=305 ent=0 cmask=0 allocated=1 dropped=0 free=2 tab={0,0}
    [csrtab] cyc=3606512 alloc tid=9  addr=30a ent=1 cmask=0 allocated=1 dropped=0 free=1 tab={1,0}
    [csrtab] cyc=3606518 release tid=8  hit=1 tab={1,1}
    [csrtab] cyc=3606520 release tid=9  hit=1 tab={0,1}
    [csrtab] cyc=3606524 alloc tid=10 addr=305 ent=0 cmask=0 allocated=1 dropped=0 free=2 tab={0,0}
    [csrtab] cyc=3606526 release tid=10 hit=1 tab={1,0}
    [csrtab] cyc=3606545 iro_ack tid=23 pc=000000008000eaa2 csr_ready_i=1
    [csrtab] cyc=3606546 alloc tid=23 addr=da0 ent=0 cmask=0 allocated=1 dropped=0 free=2 tab={0,0}
    [csrtab] cyc=3606586 iro_ack tid=5  pc=000000008000ead2 csr_ready_i=1
    [csrtab] cyc=3606587 alloc tid=5  addr=c01 ent=1 cmask=0 allocated=1 dropped=0 free=1 tab={1,0}
    (no further [csrtab] lines — table frozen for the remaining ~2.4M cycles)

Final hang state (identical all three dumps):

    [hang] SB head slot=22 issued=1 valid=0 cancelled=0 replay=0 fu=6 op=33
           pc=000000008000ea9e tid=0 ex=0 | port0 valid=0 fu=6
           pc=000000008000ea9e ack=0 drop=0 | commit_ptr=22 issue_ptr=21
    [hang] CSR seam: buf[0] v=1 tid=23 addr=da0 | buf[1] v=1 tid=5 addr=c01
           | hit=0 rel=0 rdy=0 | req v=0 op=0 addr=305 tid=10 | match=0
           apply=0 rdata_v=0 | commit_csr=0 | port0 v=0 fu=6 tid=22 ack=0

Findings:

- **H-LEAK refuted.** Both resident entries allocated with `cmask=0`; the
  run contains zero cancelled arrivals against the table. No same-edge
  cancelled arrival ever occurred.
- **H-CREDIT refuted.** `dropped=1` never fired; every `iro_ack` shows
  `csr_ready_i=1` and every alloc found a free entry; the IRO→table
  distance is a uniform one cycle.
- The wedged head (tid 22, `csrrw mtvec` at 0x8000ea9e) produced **no**
  `iro_ack` and **no** table alloc anywhere in the run — the slot's
  `issued` bit is set at scoreboard allocation into the issue ring
  (sb_lifecycle.sv:345 `a_mem issued:1`), not at FU grant.
- **Actual mechanism — admission-order priority inversion.** The
  operand-stalled `csrrw mtvec` (reads a2) waited in the IQ while two
  younger, operand-ready CSRs (`0x8000eaa2`→`da0`, `0x8000ead2`→`c01`)
  were acked and took both table entries. `csr_ready` then stuck at 0:
  the residents can only release at commit, but in-order commit is
  behind the never-issuable head → deadlock. The table is correct;
  the admission order is not safe for a DEPTH=2 credit-limited buffer.

### STEP 2 — csr_buffer identity hardening (real latent bug, not this wedge)

Implemented as specified, kept because the cancelled-arrival race is a
genuine latent defect proven by the leaf mutant:

- `csr_buffer.sv`: `sb_live_i [NR_SB_ENTRIES]` input routed from the
  scoreboard `issued` vector through `ex_stage` (`.sb_live_i(sb_live_i)`
  on `csr_buffer_i`); `alloc_ok = csr_valid_i && !cancelled_mask_i[tid]
  && !flush_i`; owner-liveness sweep `tab_d[i].valid &= sb_live_i[tid]`
  before cancel/release/alloc; `free_count` computed from the swept
  table (same-cycle credit for dying entries); translate_off liveness
  + onehot-tid assertions; `[csrtab]` probe retained; old unqualified
  behaviour wrapped under `G6LC_MUT_CSRTAB_LEAK`.
- Leaf `tb_g6lc_hyp8_csr` extended (50→63 checks): same-edge cancelled
  arrival leaves no entry, pre-allocated dead-slot entry freed by the
  liveness sweep, back-to-back legal CSRs unchanged.
- `hyp8-control-csr-r7`: `HYP8_CSR_PASS checked=63`,
  `HYP8_CSR_LEAF_PASS warnings=none census={'SELRANGE': 8}`.
- `hyp8-control-csr-r7mut` (`G6LC_MUT_CSRTAB_LEAK`):
  `FAIL CSRTAB_CANCELLED_ARR_NO_ENTRY` — discriminates as required.
- r15x trace shows the qualification firing in-system:
  `[csrtab] cyc=3602768 cancelled-arrival ignored tid=5 addr=b05`.

### STEP 3 — h33 bisection: each external group independently breaks it

- `hyp8-integration-r32a` (r32 + LSU-credit group → r30: lsu_bypass,
  load_store_unit, issue_read_operands, issue_stage, ex_stage externals,
  g6lc_core lsu_count hunks; sha `3d40815b…`): h33 FAIL — 400k
  budget-out, jmp resolves 36286, gap=72.
- `hyp8-integration-r32b` (r32 + OoO group → r30: flu_reserve, iq_arb,
  iq_bank, iq_legal, memdep, ooo_dispatch; sha `2df650c0…`): h33 FAIL —
  400k budget-out, jmp resolves 36294, gap=51 (same signature as r32).
- `hyp8-h33-r27x` (r32x = r30 + agent files + STEP-2 fix): **PASS @889**
  — the csr_buffer change is exonerated.
- Only shared external across both builds is
  `include/build_config_pkg.sv` (CohMaxOutstanding scaling) — a proven
  no-op at NrCores=1 (coh_slots = 4 either way). ⇒ the h33 store-forward
  livelock has a sufficient fault in **each** external group (dual
  regression), not one group.

### STEP 4 — r32 build of record and witnesses

- `hyp8-integration-r32` (tree: r31 + STEP-2 fix + all external edits):
  lint scalar rc=0 WIDTHEXPAND 343 / WIDTHTRUNC 87 / LATCH 3 (identical
  to r31); smt2 rc=0 354 / 97 / 5 (identical). Model sha256
  `d5c567b8315a7c81ef26cdcbc1402d0ccea0a953a916acfb60faa8e04e9c5f25`.
- Smokes: `hyp8-h34-r31` PASS @682; `hyp8-h33-r27` FAIL (400k
  budget-out livelock, expected — external); `hyp8-branch-cancel-r18`
  PASS @473.
- Witness `hyp8-osbi-scalar-r15`: **no wedge** — 2,049,766 RVFI retires,
  last retired pc `0x800128a4` at budget end, 0 `[hang]` lines, 0
  `%Error`, 0 UART bytes, budget-out SUCCESS only, max retirement gap
  314. External edits keep the repair.
- Attribution `hyp8-osbi-scalar-r15x` (r30 + agent files + STEP-2 fix):
  **wedge reproduces bit-for-bit** — 1,153,186 retires, last pc
  `0x8000ea9a`, same tab={23@da0, 5@c01} freeze, same census
  (ret=1,165,719), FAIL exit 126. ⇒ the STEP-2 fix does not own the
  wedge repair; the external edits do (consistent with the priority-
  inversion mechanism — the fix hardens identity, not admission order).

### Churn and sha records

- Closure diff r31→r32: `core/csr_buffer.sv` (MINE), `core/ex_stage.sv`
  (MINE: `.sb_live_i` connect), `verif/regress/remote/hyp8/hyp8_tb.cpp`
  (MINE: csrtab_trace allowlist). No other file changed.
- Tree churn r31-after→r32 (`analysis/r32-tree-sha.txt`):
  `core/csr_buffer.sv` and `core/ex_stage.sv` only — no external edits
  landed during r32.
- Model shas: r32 `d5c567b8…`, r32a `3d40815b…`, r32b `2df650c0…`,
  r32x `d9f00970…`, r31xp `715cf64e…`.
- Bench/tooling touched: `verif/tb/core/tb_g6lc_hyp8_control.sv`
  (csr leaf +63 checks, `sb_live` driver), `verif/regress/remote/
  run_hyp8_memory.py` (HYP8_EXTRA_DEFINES now honoured on source-list
  leafs).

### Follow-up for the r33 brief

The wedge needs an admission-order fix, not an identity fix: either gate
CSR `iro_ack` on "no older live CSR slot" (CSR admits strictly in
dispatch order) or charge the credit against older un-acked CSRs so a
DEPTH=2 table can never be captured entirely by younger instructions.
The `+csrtab_trace` evidence identifies the exact starvation window
(cyc 3606546–3606587) for an A/B rerun.


## r33 — CSR table allocation at dispatch (program-order ownership) + frontier finding

The r13/r14x CSR wedge mechanism, closed architecturally. A resource
released in commit order must be allocated in program order; the r32
fix hardened identity but left admission at IRO grant, where a held
older CSR is invisible to the IQ-resident frontier.

### STEP 1 — `+iqleg_trace` finding: X-BLIND confirmed

`hyp8-osbi-scalar-r14xq` on the r31xq probe model (wedge reproduced
bit-for-bit: 1,153,186 retires, last pc `0x8000ea9a`, 102 `[hang]`
lines, 9350 `[iqleg]` lines, 1084 `[csrtab]` lines). The discriminating
window shows the wedged head is not in the IQ banks — it sits in the
arbiter's presentation slot, where the legality frontier cannot see it:

```
[iqleg] arb   cyc=3606544 p=0 win_q={v1,t23,b3,e1} pres_q={v0,t22,b6,e0} iv=1 iack=1 csr_rdy=1
[iqleg] iro   cyc=3606545 p0 tid=23 pc=000000008000eaa2 fu=6 csr_rdy=1 ack=1
[iqleg] csrtab cyc=3606545 iro_ack tid=23 csr_ready_i=1
[iqleg] csrtab cyc=3606546 alloc tid=23 addr=da0 ent=0 free=2
[iqleg] legal cyc=3606500-40 front_v=0 front_tid=0 oldest_v=00000000
```

tid 22 (`csrrw a2,mtvec,a2`, operand-stalled on a2) was taken from the
bank into `pres_q` while IRO held it un-acked; with `front_v=0` the
younger bank-resident CSRs (23, then 5) were `legal=1`, won `win_q`,
and were IRO-acked into both table entries at cyc 3606545/3606586.
Neither X-FRONT defect fired: the merge, the `older_t` row, and the
`csr_oldest_tid_o` select were all observed correct once the bank held
both younger CSRs (`front_tid=22` at 3606542 — too late; the arbiter
had already consumed them). Verdict: **X-BLIND** — an arbiter-held op
is invisible to the IQ-resident frontier. The fix therefore cannot be
a legality repair; ownership has to move to dispatch.

### STEP 2 — dispatch-time allocation

`csr_buffer.sv` gen_ooo:

- New dispatch ports `disp_valid_i[NR_PORTS]`, `disp_tid_i`,
  `disp_addr_i` (the sbe `result[11:0]`, confirmed as the CSR immediate
  carrier). Entries allocate in lane order into the lowest free slots
  after the r32 liveness/cancel/commit sweeps — program order by
  construction; an older stalled CSR always already owns its entry.
- `csr_valid_i`/`fu_data_i` no longer allocate; they serve only the
  commit release lookup. `csr_credit_o` (free entries post-sweep) is
  exported through ex_stage → g6lc_core → issue_stage to
  `g6lc_ooo_dispatch`, which gates group acceptance on
  `csr_credit >= popcount(CSR-class lanes)` using the `alloc_cls[C_CSR]`
  predicate — all-or-nothing under the r25 group ack and r19
  kill-dominates ordering.
- IRO-side `csr_ready_i` is now "the presented tid owns an entry"
  (structurally always true for a live CSR) — verified by the L3
  assertion `csr_valid_i |-> |fu_entry`, plus `$onehot0` per tid and
  owner-liveness assertions from r32.
- Mutant `G6LC_MUT_CSRTAB_IRO_ALLOC` restores IRO-time allocation.

### Leaves

- `hyp8-control-csr-r8`: `HYP8_CSR_PASS checked=75` — the exact
  inversion (stalled oldest + two ready younger), the credit<2 group
  stall, dispatch-alloc + cancel sweep, and the back-to-back regression
  all covered; leaf census `{'SELRANGE': 13}`, no warnings.
- `hyp8-control-csr-r8mut`: fails at `[424] CSRTAB_INV_A_OWNS_LOW` —
  the mutant restores the inversion and the leaf discriminates it.
- `hyp8-control-dispatch` re-run: `HYP8_DISPATCH_PASS checked=66` —
  the group gate change did not regress dispatch checks.

### r33 build of record + smokes + witnesses

- `hyp8-integration-r33` (r32 + STEP-2, externals kept): lint scalar
  rc=0 343/87/3, smt2 rc=0 354/97/5 — identical to r32. Model sha256
  `b5ae0816c2e6cff2c0bb75359ca7c235e5c54c01ced977e2515535ad2acd53a3`.
- `hyp8-integration-r33x` (r30 + agent files + r32 fix + r33 fix):
  lint scalar 343/87/3, smt2 353/97/5. Model sha256
  `e185e8e6b22ef596fbd2f928e972afd2ad6df2efe010e164b3fa7e6d2c288948`.
- Smokes (`hyp8-r33-smokes`): `hyp8-h34-r32` PASS @682;
  `hyp8-h33-r28` FAIL (400k budget-out — expected, the external groups
  own the store-forward livelock); `hyp8-branch-cancel-r19` PASS @473;
  `hyp8-h33-r28x` PASS @889; `hyp8-branch-cancel-r19x` PASS @475 —
  identical to r32 cycle counts.
- Witness `hyp8-osbi-scalar-r16` (r33, `+csrtab_trace +stall_census
  +hang_dump=2000`): **no wedge** — budget-out SUCCESS at 6M, census
  ret=2,066,236 (bit-identical to r15), 0 `[hang]`, 0 `%Error`, 0 UART.
- Attribution `hyp8-osbi-scalar-r16x` (r33x): the dispatch-time alloc
  trace is correct end-to-end (240 `[csrtab]` lines of paired
  disp_alloc→fu_grant→release; no inversion) — but the run aborted at
  cyc 3600670 on the new L3 assertion `csr_valid_i |-> |fu_entry`: a
  CSR granted at the FU whose owner slot died between dispatch and
  presentation legitimately has no entry (the liveness sweep already
  freed it; its result is dropped). The assertion was over-strict and
  was relaxed post-r33 to exempt dead/cancelled/flush grants — r17x on
  r34x carries the relaxed form and completes the wedge-window proof.

### Provenance

- Closure diff r32→r33 (all mine): `core/csr_buffer.sv`,
  `core/ex_stage.sv`, `core/g6lc_core.sv`, `core/issue_stage.sv`,
  `core/ooo/g6lc_ooo_dispatch.sv`,
  `verif/regress/remote/hyp8/hyp8_tb.cpp` (`iqleg_trace` allowlist).
  r33x = r33x-closure regenerated from r30 + the agent file set +
  r32/r33 fixes; no new external edits landed during r33.
- Tooling: `verif/tb/core/tb_g6lc_hyp8_control.sv` (csr section → 75
  checks, credit-gated dispatch driver); `run_r33_smokes.py`,
  `run_r16_witness.py`, `run_r16x_witness.py`,
  `assemble_r33_closures.py` under `C:/Users/etcim/cva6-artifacts/`.


## r34 — T1 rank-0 structural pass + analyze-ghz-r2

Rank-0 combinational-identity rewrites against the timing board's
ranked cones, with per-item equivalence discipline (reference kept
under translate_off, `assert(new===old)` every active cycle, a
`G6LC_MUT_T1_*` mutant re-selecting the old path, and a
`[equiv] <module> <item>: checked=N` report at $finish under
`+equiv_report`). Baseline = r33 / r33x trees.

### B0 — board reproduction

`analyze-ghz-r1` reproduced bit-for-bit as `boards/hyp8-core/
analyze-ghz-r1b.json`: every dFO4 = +0.0 except the two legitimate
r33-edited files (csr_buffer +15.0 from dispatch allocation,
g6lc_ooo_dispatch +0.4 from the credit gate). Verified command saved
to `boards/hyp8-core/analyze-ghz-r1.cmd` (sv-timing analyze,
--files-from inputs/hyp8-core.f, --param-map inputs/param-map-hyp8.json,
--width-map inputs/width-map.json, --assume-xlen 64, --package-mode
packages, --all-modules --stages, --target-mhz 5000 --fo4-ps 20
--budget-margin 0.2, RUST_MIN_STACK=16M).

### B1 — model-truth (rename_resolve hi_last)

Single-module measure (`boards/hyp8-core/analyze-ren-t1b1.json`,
36 nodes / 23 regions / 34 paths): inline log-depth prefix-OR
measured 30.1 FO4 vs 8.0 budget (board-billed cone 41.6). The
functional rewrite attempts (prefix-OR, packed slices, element
arrays) all broke the `g6lc_t1_renres_eq` equivalence in
g6lc_rename.sv — item 1 **not landed**; `g6lc_rename_resolve.sv` and
`g6lc_rename.sv` reverted to r33 state (verified against
t1-tree-sha-before).

### B2 — landed items (with equivalence discipline)

Per-item rewritten-cone FO4 from the single-module reanalysis
runs (module-level worst on the r2 board can sit on a different cone):

| item | module | cone r1 | cone r2 | [equiv] counter |
|------|--------|---------|---------|-----------------|
| 15   | g6lc_iq_legal (serial-class legality from age-matrix row) | 28.8 (pres 122.0, stitch-of-record 222.7) | 16.4 (pres 21.9, stitch 134.2) | leg |
| 13   | sb_lifecycle (exclusive arms + one-hot alloc) | 24.6 | 16.4 | col |
| 9    | g6lc_rename_recover (row-local alloc marks) | 20.0 | 16.0 | pubmarks |
| 11   | g6lc_fe_override (late-select RAS link adds) | 19.8 | 16.4 | ras_upd |
| 3    | g6lc_tlb (flat PLRU set/clear masks) | 19.4 | 18.0 | plru |
| 7    | g6lc_lsq_release (unique-case arms, source one-hot) | 17.6 | 13.4 | arms |
| 12   | g6lc_lsq_event (SelectIncrement ev_count) | 17.1 | 16.4 | evcount |
| 14   | g6lc_lsq_slot (row-local hit decode) | 16.4 | 15.6 | arms |
| 2    | g6lc_lsq_cam_bank (be carried in cam entry) | 15.0 | 11.0 | cambe |

Not landed: item 1 rename_resolve (equivalence failures, reverted).
Discarded by measurement: item 18 alu one-hot shifter 27.9→48.0;
item 5 lsq_reduce id/pay carry 38.2→43.5 (discard notes kept in
core/alu.sv and core/ooo/g6lc_lsq_reduce.sv). Excluded per brief
(rank-1 / externally-owned): IRO, lsu_bypass, iq_bank, iq_arb,
ooo_dispatch, LSU/load_unit, ptw, multiplier, lbuf peek, sb_commit.

### B3 — leaves (r75 control closure)

- `hyp8-control-dispatch-r38`: HYP8_DISPATCH_PASS checked=66 —
  equiv counts leg=416 evcount=416 cambe=9 arms(release)=9
  arms(slot)=9 pubmarks=38.
- `hyp8-control-csr-r9t1`: HYP8_CSR_PASS checked=75 (same as r8).
- `hyp8-control-lsq-r*` : HYP8_LSQ_PASS checked=24 + equivs.
- `hyp8-control-alu-r9t1`: HYP8_ALU_PASS checked=23.
- Census: identical warning census to the pre-T1 leaf baseline.

### B4 — r34 / r34x of record

- `hyp8-integration-r34` (r33 + T1): lint scalar 343/87/3,
  smt2 354/97/3 (LATCH 3 — T1 pass removed the 2 leftover latches);
  model sha256 `2c449f7ecf101f392ec5766d16343e39faae58420cc31f7c8c275a0e0628caef`.
- `hyp8-integration-r34x` (r33x + T1 incl. iq_legal port):
  lint scalar 343/87/3, smt2 353/97/3; model sha256
  `46e5037e851fa45d35a2a8e8641745fea34dbdfbcfc737a5c22589e6f5e46cd2`.
- Smokes (`hyp8-r34-smokes`) bit-identical to r33/r33x:
  h34 @682, h33 400k budget-fail (external store-forward livelock,
  unchanged), bc @473 | r34x: h33x @889, bcx @475. equiv=29 lines/run.
- Witness `hyp8-osbi-scalar-r17` (r34, +stall_census +hang_dump=2000
  +equiv_report): budget-out SUCCESS, mc_verdict exit 0, gap 314,
  **final census ret=2,066,236 — bit-identical to r16**; 0 [hang],
  0 %Error, 0 UART. equiv counts: leg/col/evcount/arms/slot/arms/
  cambe(×16)/plru(×2) all checked≈6.0M, ras_upd=54,836,
  pubmarks=1,152,473.
- Witness `hyp8-osbi-scalar-r17x` (r34x): got **past** the
  0x8000ea9e CSR wedge (1,218,494 retires > r14x's 1,153,186 — the
  dispatch-allocation ownership proof holds on the external-free
  model), then stopped at ~cyc 3,775,788 on a **different,
  previously-unreachable wedge**: empty-pipeline frontend starvation
  (`sb_empty=1`, issue_valid=00, CSR seam empty/rdy=1, FE head
  demand=1 with epoch-reseed cycling fe_v=00). mc_verdict FAIL 126,
  ret=1,218,494, 18 [hang] lines, 0 %Error, all equivs>0. r16x had
  aborted at cyc 3,600,670 on the strict L3 assertion, before this
  window. Attribution run `hyp8-osbi-scalar-r16xr` on
  `hyp8-integration-r33xr` (r34x minus every T1 file = r33x + the
  relaxed assertion only; model sha
  a2088cb5199c2185fe2de8e52527021e0ab74ff2f0250ada1294e26c38c224a9)
  reproduces the wedge **bit-for-bit**: identical ret=1,218,494,
  identical 18 [hang] lines (onset cyc 3,775,788, SB head
  0x8000c9ec), identical census — the frontend-starvation wedge is
  **latent in r33x, not T1-induced**, and the T1 pass is
  cycle-transparent on the x profile too. Root cause of the new
  wedge (FE reseed cycling with sb_empty, epoch advancing while
  fe_v=00) is a separate open defect on the external-free model.

### B4 — analyze-ghz-r2 board

`boards/hyp8-core/analyze-ghz-r2.json` (r34 tree, verified r1
command) + `clock-r2-vs-r1.csv`. Board structural clock **0.81 GHz**
(49.2 FO4, g6lc_shared_tlb reg-to-reg :860 — the known RVH-arm path
the tool cannot exclude per-path; its live cone is 28.3). The top
LIVE limit is **39.0 FO4 ≈ 1.03 GHz**, a tie between `csr_buffer`
(reg-to-reg :240, +15.0 — the r33 dispatch-allocation cone,
pre-existing since r33, not a T1 regression) and `g6lc_ptw`'s live
cone (39.0; its billed 43.1 is RVH-arm). IQ-complex stitched path
**222.7 → 134.2 FO4** (`g6lc_iq` stitch column; iq_legal pres
122.0 → 21.9, module 28.8 → 16.4, dFO4 −12.4 — the single largest
module move on the board). Other T1 module moves at min-fo4 10:
g6lc_tlb 40.7→38.5 (−2.2), g6lc_lsq_event 29.0→25.1 (−3.9); all
other modules dFO4 +0.0 except csr_buffer +15.0 and
g6lc_ooo_dispatch +0.4 (both legitimate r33 changes). Unmoved
clock-setters: rename_resolve 41.6 in-stage RR (item 1 not landed),
lsq_reduce 38.2 in-stage R (item 5 discarded), iq_arb 34.8,
iq_bank 32.3, loop_buffer 31.8, icache 22.0 (+0.0), alu 27.9
(item 18 discarded).

### Provenance / tree churn

- r34 = r33 closure + 14 files (13 T1 + hyp8_tb.cpp); r34x = r33x
  closure + 13 files with iq_legal ported onto the r30 scalar-frontier
  base. Manifests regenerated (693 unique on-disk files).
- t1-tree-sha-before diff: exactly the 13 edited files, all mine —
  zero external churn during T1.
- Closure tags: `hyp8-integration-r34{,x}-closure`,
  `hyp8-control-r75-closure`; runs `hyp8-control-{dispatch-r38,
  csr-r9t1,lsq,alu-r9t1}`, `hyp8-r34-smokes`,
  `hyp8-osbi-scalar-r17{,x}`; boards `analyze-ghz-r1b`,
  `analyze-ren-t1b1`, `analyze-ghz-r2`, `clock-r2-vs-r1.csv`.


---

## r35 (part 1) — FE reseed-cycling trace, 20M witness, csr_buffer alloc rank-0, hi_last fixture

### S1 — `[win]` windowed probe + r17xq trace (H-OV confirmed)

`core/fetch_B/frontend.sv`: the `[win]` lifecycle probe's
`$time() < 200000` cap replaced by the `+trace_from`/`+trace_to`
cycle window (same convention as `+commit_trace` in g6lc_core.sv),
gated on `+fetch_win_trace`; the line gained `rpl`/`rpa`
(instr_queue replay_o/replay_addr_o), `fev`
(fetch_entry_valid_o), `fpush`/`fpop`/`fhv`/`fhva`/`ftqf`
(FTQ), `dmd`/`dmfr`/`rsnw` (demand/fire/reseed_now), `dreq`/`drva`/
`irdy` (icache_dreq_o.req/vaddr, icache_dreq_i.ready) and `lt`.
Plusargs `fetch_win_trace`, `trace_from`, `trace_to` already in the
hyp8_tb.cpp allowlist. Build `hyp8-integration-r34xq` (= r34x
closure + probe only); run `hyp8-osbi-scalar-r17xq`
(+fetch_win_trace +trace_from=3773000 +trace_to=3776500
+stall_census +hang_dump=2000, 6M budget).

Result: wedge reproduced **bit-for-bit** — ret=1,218,494,
FAIL 126, identical 18 `[hang]` lines, 0 %Error, 0 UART, firmware
sha a9218107… (probe non-invasive). 2914 `[win]` lines captured.

The wedge is an exact ~11-cycle self-squash loop, onset ≈ cyc
3773774 (first `red=1 src=9` after the last healthy fetch burst),
steady from 3773783. One loop pass (verbatim, ep=6→7 shown):

```
[win] cyc=3773773 … rsp=0 vaddr=…ca20 ov1=1 src=10 redpc=…ca1e res=…ca1e ep=6 lo=1 lopc=…ca1e fev=00 fhva=…ca28 dreq=1 drva=…ca28
[win] cyc=3773774 … k1=1 k2=1 red=1 src=9 redpc=…ca1e res=…ca1e ep=7 rsnw=1 dreq=0 drva=…ca1e
[win] cyc=3773775 … dmd=1 dmfr=1 dreq=1 drva=…ca1e fhv=1
[win] cyc=3773778 … rsp=1 vaddr=…ca1e take=1 irdy=1
[win] cyc=3773780 … npc advances ca20→ca28→ca30, fpush=1, loep 6→7 (carry epoch follows)
[win] cyc=3773782 … lt=1 dreq=1 drva=…ca28
[win] cyc=3773783 … rsp=1 vaddr=…ca20 take=1 ov1=1 irdy=1
[win] cyc=3773784 … k1=1 k2=1 red=1 src=9 redpc=…ca1e ep=0 rsnw=1
```

full excerpt: `hyp8-osbi-scalar-r17xq/win_onset.txt` (132 lines,
cyc 3773770–3773930 = ~2.5 passes).

Disassembly of the loop site (fw_payload.elf, sha a9218107…):

```
8000ca1a: fe9fa0ef  jal  ra,80007a02 <misa_extension_imp>   # call: test bit 68
8000ca1e: 20050163  beqz a0,8000cc20                       # 32-bit insn at ca1e-ca21 — straddles the 16B I$ line boundary at ca20
8000ca22: 6499      lui  s1,0x6
8000ca24: 05600513  li   a0,86
8000ca28: fdbfa0ef  jal  ra,80007a02 <misa_extension_imp>   # FTQ head inside the wedge
8000ca2c: c119      beqz a0,8000ca32
8000ca2e: 6004e493  ori  s1,s1,1536
8000ca32: 30049073  csrw mstatus,s1
```

**Verdict: H-OV survives.** `src=9` = `SRC_OV1` (stage-1
override; SRC_REPLAY=8, SRC_OV2=10 — `g6lc_fe_redirect.sv:97-100`).
Every pass: both I$ lines arrive and are taken (`rsp=1 take=1` on
vaddr ca1e *and* ca20 — the straddle's two halves land, `lo=1
lopc=ca1e` carry holds with epoch tracking `loep` following `ep`),
`lt=1` (line-taken guess) precedes `ov1=1` on the cycle the second
line completes, then `k1=k2=1 red=1 rsnw=1` squashes the whole
window and reseeds to **redpc=0x8000ca1e — the straddled beqz's own
vaddr** (== `res`, the resume pointer), not its target (0x8000cc20
if taken) nor fallthrough (0x8000ca22). Because `beqz` target =
vaddr+imm, redirect-to-self is consistent with the override's
immediate decode reading `imm=0` for the carry-completed
instruction — the branch's high bytes live in the second line,
which the ov1 target path apparently never sees. The verdict
re-decides identically each pass (no resolve feedback can arrive —
nothing is ever admitted), so the loop is stable; epochs cycle
0→7.

Refuted: **H-RL** — the carry is live each pass (`lo=1`,
`lopc=ca1e`, `loep` tracks `ep`) and both lines `take=1`; the kill
is what prevents use, not a dropped carry. **H-REP** — `rp=0` and
`rpl=0` in all 2914 lines; the queue never replays
(`rpa=0x80012960` is an inert leftover). Also refuted as
first-false: **I$→realign** (lines delivered and taken every pass),
**realign→IQ** as a data-path failure — `vmask=0000`/`fev=00`, but
the `k1/k2` kill arrives *because of* the ov1 verdict, so the empty
presentation is downstream of the wrong squash, not its cause.
**First-false promise: predictor→FTQ (the SRC_OV1 verdict's
redirect target / re-fire discipline on a straddled CF).**

### S2 — `hyp8-osbi-scalar-r18` (r34, 20M-cycle witness)

r34 model sha `2c449f7e…` (unchanged since B4), firmware sha
a9218107…, `+time_out=20000000 +max-cycles=20000000
+debug_disable +quiet_axi +tohost_addr=0x80041730 +stall_census
+hang_dump=2000 +equiv_report`. Verdict: **SUCCESS, budget
reached, no tohost** — `*** SUCCESS *** (tohost = 0) after
20000000 cycles`, mc_verdict exit 0, all cores retired, **max
retirement gap 314** (same as r16/r17). Final census cyc
19,999,986: **ret=6,900,750**, ipc 0.345 sustained at every 2M
checkpoint — no slowdown, no wedge, the external-free frontend
self-squash does not exist on the tree-of-record profile (the
wedge is only reachable on the r30-base r34x/r33x profile).
0 `[hang]` lines, 0 `%Error`, **0 UART bytes** (firmware still
in pre-console code at the 20M cutoff). `[ckpt] final`:
allocs=1,123,475 pops=939,988, pop_mismatch=0, restores=38,657,
restore_mismatch=0, mispredicts br=22,521 ret=0 jmp=16,136.
`[equiv]` all >0: leg/col/evcount/arms/cambe(×16)/plru(×2)
checked=19,999,976–86 (every cycle), ras_upd=183,248,
pubmarks=3,846,820. Wall 5,910,705 ms ≈ 98.5 min. No last-pc
marker — budget-out runs emit no hang dump; retirement was
uninterrupted to the cutoff.

### S3 — csr_buffer :240 two-lane alloc → parallel free-vector picks (rank-0)

`core/csr_buffer.sv` (the analyze-ghz-r2 live clock-setter, 39.0
FO4): the serial in-place lane scan (lane 1 saw lane 0's write
through tab_d, chaining through the table writes) replaced by a
swept free vector `free_v[DEPTH]` (`!valid | !sb_live | cancelled |
commit-release`, computed once on tab_q), per-lane one-hot picks
`alloc_take[p] = rem & ~below` with `below` the log-depth
prefix-OR of `rem = free_v & ~alloc_used` (A140 isolate form;
DEPTH=2), per-entry one-hot masked writes, and
`csr_credit_o = popcount(free_v)` (one 2-bit add). The old serial
scan remains under `G6LC_MUT_T1_CSRALLOC` (live-path mutant) and as
the translate_off `ref_tab`/`ref_free` reference, asserted every
cycle (`tab_d === ref_tab && csr_credit_o === 2'(ref_free)` —
assertion compiled out under the mutant, which re-selects the old
expression on the live path) plus `[equiv] csr_buffer alloc:
checked=N` on `+equiv_report`.

Measurement (`--modules csr_buffer`, verified analyze flags):
**39.0 → 22.9 FO4** (`analyze-csra-t1.json` worst_path_fo4
22.9075) — the live board limit drops to ~32.x (ptw live 39.0
remains; csr_buffer is off the critical list at 5000 MHz/20 ps/0.2
units). Leaf `hyp8-control-csr-r10`: `HYP8_CSR_PASS checked=75`,
`[equiv] csr_buffer alloc: checked=77`, `HYP8_CSR_LEAF_PASS
warnings=none census={'SELRANGE': 13}`; `hyp8-control-csr-r10mut`
(mutant): `HYP8_CSR_PASS checked=75` — T1 identity discipline
(mutant proves the wiring, not discrimination).

### S4 — E6 fixture: hi_last function-billing over-read

`sv-timing/fixtures/auto_correct/fn_prefix_or_billing.sv` (MIT,
Etienne Cimon): four forms of a 6-input highest-set one-hot —
`hi_last` as a `function` with the `l <<= 1` prefix loop vs the
explicit inline prefix-OR, each in standalone and gather-context
(7-call) shape. Readings (`analyze` on the fixture): call 9.0,
inline 14.1, call_gather 15.0, inline_gather 33.4 FO4 — **the
function-vs-inline billing gap is context-bound and reverses
standalone**; it does not reproduce a universal call-form penalty,
which is what the fixture documents. Golden test
`fn_prefix_or_billing_goldens_pin_current_readings` pins the four
readings (passes); `fn_prefix_or_forms_measure_within_spread` is
`#[ignore]`-marked expected-mismatch (the 41.6→30.1
rename_resolve gap is therefore recorded as unresolved
context-bound billing, not a defect to fix in the cost table —
no analyzer/cost-table changes). `cargo test -p sv-timing-core
--lib fn_prefix_or`: 1 passed, 1 ignored.

### Deferred / not landed

- The frontend self-squash fix: deliberately **not authored** —
  the trace evidence above goes to the lead for the design (per
  the r35 brief; expected r36). Probe-only closure
  `hyp8-integration-r34xq` retains the `[win]` instrumentation.
- rename_resolve item 1 (hi_last inline): still not landed (r34
  note stands — equivalence failed; single-module measured 30.1).
- r35 tree churn vs the r34 closure: **exactly 2 files, both
  mine** — `core/csr_buffer.sv` (S3 rewrite) and
  `core/fetch_B/frontend.sv` (S1 probe). The walk also lists 6
  "NEW" paths (`alu_shift_hi.sv`, `g6lc_fetch_dbg.sv`,
  `neg/mut_*.sv` ×3, `hpdcache_typedef.svh`) — all unreferenced
  working-tree files absent from every closure since r33 (the
  closure manifest is build-flist driven; `g6_fetch_dbg`/
  `alu_shift_hi` sit only in the sv-timing analyzer flist), not
  r35 churn. Zero external edits observed.
- Tags: build `hyp8-integration-r34xq` (model sha `4d1702f9…`,
  lint scalar 343/87/3, smt2 353/97/3 — identical census to
  r34x); runs `hyp8-osbi-scalar-r17xq`, `hyp8-osbi-scalar-r18`,
  `hyp8-control-csr-r10{,mut}`; board
  `boards/hyp8-core/analyze-csra-t1.json`; closure
  `hyp8-integration-r34xq-closure`; fixture
  `sv-timing/fixtures/auto_correct/fn_prefix_or_billing.sv`.

## r36 — override-#1 identical-state refire (livelock) + unlearn delivery; boot observability

### Defect (from r17xq/r34xq probe evidence)

`src=9 (SRC_OV1)` leg-2 squelch loop on the straddled `beqz a0` at
0x8000ca1e: the check's unbacked-taken clause redirected to
`resume_pc_i` = the queue frontier = the CF's own vaddr, killing the
very window (0x8000ca20) that carries the CF's second half. The
frontier could never advance; the refetch re-pushed the same block
with the same untagged guess → identical {chk_vaddr, resume} → refire,
~11-cycle period, `fe_v=00` forever.

### Fix (core/frontend/g6lc_fe_btb_check.sv — D1, by contract)

An override is a prediction correction and must not be re-applied to an
identical state. A registered `sq_q = {valid, vaddr, resume}` records
the last leg-2 fire; leg 2 is suppressed when the same block is
re-checked at the same frozen frontier (`sq_valid && chk_vaddr ==
sq_vaddr && resume == sq_resume`). The guess is left to architectural
resolution — the stream follows it, the CF resolves at execute, a wrong
guess recovers — slower than the squelch, never a livelock. `sq_q`
clears on `flush_bp_i`, on a leg-1 fire, and on any frontier move
(`resume != sq_resume`) so genuinely new states are never suppressed.
Leg 1 (tagged-BTB leg) unchanged. Old leg 2 kept under review mutant
`G6LC_MUT_FE_OV1_REFIRE`; translate_off assertion "ov1 refire on
identical state" added; stale comment amended with the straddle caveat.

### Leaf (verif/tb/core/tb_g6lc_hyp8_control.sv section F)

`hyp8-control-linecheck-r3c` (closure `hyp8-control-r77-closure`):
`HYP8_LINECHECK_PASS checked=53` (36 prior + 17 new) —
LINECHECK_OV1_FIRE / _UNLEARN_EMIT / _UNLEARN_LANDS / _OV1_ONCE /
_OV1_NEW_STATE + straddle-walk checks. `hyp8-control-linecheck-r3mut`
fails at `LINECHECK_OV1_ONCE` (mutant refires on identical state).

### Unlearn delivery (D2)

The r17xq2 probe (`hyp8-integration-r34xq2`, `+fetch_win_trace`
3773000–3776500) reproduced the wedge bit-for-bit (ret=1,218,494,
FAIL 126, 18 [hang] lines identical to r16xr) and captured the
arbitration on every pass of the loop: at each leg-2 fire
`o1v=1 o1p=0x8000ca38 o1t=0` (the unlearn for the checked block) and
`o2v=1 o2p=0x8000ca1e o2t=0` (a same-cycle override-#2 train) — and the
delivered `nl_train` carried ov2's record (`nlv=1 nlp=…ca1e nlt=0
widx=67`), never ov1's. The `resolve > ov2 > ov1` priority in
`frontend.sv` dropped the unlearn every cycle: the wrong guess
survived its own refutation and the refetch re-read `lt=1` — the
refire's self-sustaining half.

Fix (core/fetch_B/frontend.sv): an ov1 unlearn
(`ov1_train_valid && !ov1_train_taken`) is promoted above ov2, below
only the architectural resolve — a refutation of the guess that just
caused a squelch must never be dropped to a lower-priority producer.
Plus a translate_off delivery assertion: an ov1 unlearn with no
same-cycle resolve must appear on `nl_train` verbatim
("frontend: ov1 unlearn dropped by train arbitration"). LINECHECK_
UNLEARN_WINS is not expressible at the pair leaf (the arbiter lives in
frontend.sv, outside the check+nextline pair); coverage is the
assertion exercised by all model runs plus the r19xv2 witness through
the wedge region.

### Integration

- Closures `hyp8-integration-r36{,x}-closure` = r34{,x} + exactly
  {`core/csr_buffer.sv` (r35 alloc), `core/fetch_B/frontend.sv` (probe),
  `core/frontend/g6lc_fe_btb_check.sv` (D1)}; `hyp8_tb.cpp` re-staged.
- `hyp8-integration-r36`: model sha `c3b6f025…`, lint scalar 343/87/3,
  smt2 354/97/3 (identical census to r34). D1-only model.
- `hyp8-integration-r36x`: model sha `e90c1c10…`, lint scalar 343/87/3,
  smt2 353/97/3 (identical census to r34x). D1-only model.
- Combined-fix rebuilds (D1 + D2): `hyp8-integration-r36v2` model sha
  `24a25a92…`, lint scalar 343/87/3, smt2 354/97/3;
  `hyp8-integration-r36xv2` model sha `7625bc45…`, lint scalar
  343/87/3, smt2 353/97/3 — censuses identical to r36/r36x (the D2 mux
  + assertion add no lint delta).
- Smokes (v2 models, `hyp8-r36v2-smokes`) bit-identical: h34=682,
  bc=473, h33x=889, bcx=475 real tohost + 30 equiv entries each;
  h33 on r36v2 budget-out 400000 (external store-forward line,
  expected).
- Witness `hyp8-osbi-scalar-r19x` (r36x D1-only, 6M): SUCCESS
  budget-out, rc=0, `[mc_verdict] all 1 core(s) retired
  instructions`, ret=1,703,355 @ cyc 5,999,986 (vs ret=1,218,494
  frozen at the r16xr wedge), max retirement gap 371, 0 [hang],
  0 %Error, 0 UART, 0 refire-assertion hits, 30 [equiv] lines —
  D1 alone breaks the livelock (the suppress lets the straddled
  window complete so the frontier advances).
- Witness `hyp8-osbi-scalar-r19xv2` (r36xv2 D1+D2, 6M): SUCCESS
  budget-out, rc=0, `[mc_verdict] all 1 core(s) retired
  instructions`, ret=1,703,285 @ cyc 5,999,986, 0 [hang], 0 %Error,
  0 UART, 0 assertion hits (refire and unlearn-drop both silent),
  30 [equiv] lines, ckpt clean (pop_mismatch=0,
  restore_mismatch=0). Ret differs from D1-only r19x by −70
  (1,703,285 vs 1,703,355): the unlearn now lands, clearing the
  poisoned guess and altering the speculative trajectory — the
  intended D2 effect, not a regression.
- Witness `hyp8-osbi-scalar-r19v2` (r36v2 D1+D2, 20M, +equiv_report
  +rvfi_cycle_stamp): SUCCESS budget-out, rc=0, `[mc_verdict] all 1
  core(s) retired instructions`, exit 0, ret=6,789,008 @ cyc
  19,999,986 (r18/r34: 6,900,750 — the suppress changes speculation
  trajectory by construction; −1.6% retires, not a hang signature),
  uniform ipc 0.339 at every 2M census, 0 [hang], 0 %Error, 0 UART,
  0 assertion hits (refire + unlearn-drop), 30 [equiv] lines
  (csr_buffer alloc checked=19,999,986 etc.), ckpt clean
  (pop_mismatch=0, restore_mismatch=0). Wall 6,047 s.

### Boot observability (r18/r34, 20M, no fix — facts only)

- PC histogram of the last 200k RVFI retires (cyc 19,420,806–19,999,978):
  100% inside OpenSBI's libfdt walk — `fdt_offset_ptr` 133,072,
  `fdt_next_tag` 55,561, `fdt_next_node` 10,098,
  `fdt_subnode_offset_namelen` 1,269. Milestone PCs: 2M→`fdt_next_node`,
  6M→`fdt_offset_ptr`, 12M→`fdt_offset_ptr`. Retire stream ran to the
  final cycle (6,900,750 lines, last retire cyc 19,999,978) — the core
  is processing its embedded FDT, not parked in `sbi_hart_hang`; an
  FDT-walk livelock is not excluded by the histogram alone.
- UART path: harness models `mock_uart` at UARTBase 0x1000_0000
  (`InclUART=0` under Verilator → `mock_uart` instantiates on the same
  axi2apb window; THR byte → `$write %c` to sim stdout; LSR always
  THRE/TEMT). The dtb's `stdout-path=/soc/uart@10000000` ns16550a and
  `console=ttyS0,115200 earlycon=sbi` bootargs target exactly that
  window — the path is fully modeled; "0 UART bytes" is a genuine
  no-write fact (OpenSBI never reached console output), not an
  instrument gap.
- Payload identity: `linux_scalar` — OpenSBI generic `fw_payload`
  (FW_TEXT_START=0x80000000, FW_PAYLOAD_OFFSET=0x200000) carrying
  `linux-payload.bin` (a real Linux kernel + initramfs at 0x84000000),
  dtb `g6lc-hyp8-linux.dtb`. fw sha `a9218107…` pinned in
  `analysis/integration-inputs.json`.
- r19x (r36x D1-only, 6M) last-200k-retire histogram: `fdt_offset_ptr`
  104,574, `__sbi_expected_trap` 44,962, `fdt_next_tag` 28,490,
  `fdt_get_property_namelen_` 2,087, `fdt_next_node` 1,952,
  `fdt_ro_probe_` 1,920, sbi_mem*/strlen helpers — the same FDT-parser
  trajectory at 6M as r18 shows at 20M; retire #627,782 (≈2M census
  point) at PC 0x800128c0 (fdt_offset_ptr region). Progress past the
  wedge is real retirement work, not a redirect loop.
- r19v2 (r36v2 D1+D2, 20M) last-200k-retire histogram (cyc
  19,405,474–19,999,986): `fdt_offset_ptr` 134,300, `fdt_next_tag`
  54,633, `fdt_next_node` 9,744, `fdt_subnode_offset_namelen` 1,323 —
  ~99.4% inside the libfdt walk, statistically identical to r18.
  Milestones: 2M→`fdt_next_tag` (0x800129a0), 6M→`fdt_offset_ptr`
  (0x800128c0), 12M→`fdt_offset_ptr` (0x800128f4), last retire
  @19,999,986→`fdt_next_tag` (0x80012aa4). No `sbi_hart_hang`, timer,
  delay, or lock-spin symbols anywhere in the window; the fix does not
  change where the core spends its time — OpenSBI's embedded-FDT parse
  is simply a ~20M-cycle workload on this model.

## r37 — libfdt residence: progress analysis + reference comparison

**Verdict: value-livelock, not slow progress.** The r19v2 residence is a
stable self-restart: `fdt_subnode_offset_namelen` calls
`fdt_next_node(fdt, 0, &depth)` forever because the caller's depth cell
always reads back 0 — a speculative stack store→load visibility defect,
the first wrong value is **not** a DTB word. No firmware or RTL change
was made; mechanism reported for fix authorization.

### STEP 1 — progress vs cycle (r19v2 RVFI trace, fw sha a9218107)

- `fdt_next_node` entry (0x80012b16): **4903 retires, every one with
  a1=0** — every call restarts the walk at structure offset 0.
- `fdt_next_tag` outcomes per call chain: tag `3` (NOP) ×12,257, tag
  `1` (BEGIN_NODE) ×4,902. Per-call loop shapes: `[8:B, 24:P, 40:P, 0]`
  ×3,676; `[8:B, 0]` ×1,225; one `[8,24,40,72,0]`; one empty.
- The validation call `fdt_next_tag(fdt, 0, &next)` always writes
  `nextoffset=8` correctly; the in-loop tags then walk 24→40→…→0 —
  **every DTB structure word loaded is correct** (verified against ELF
  bytes; header loads too: totalsize 0x843, off_struct 0x38,
  size_struct 0x63c, version 0x11).
- Caller chain (nm + full-ELF disasm, `hyp8-r37-caller3`): the looping
  `fdt_subnode_offset_namelen` instance was entered once at cyc 75,805
  from `fdt_path_offset_namelen` (jal @0x8001378a, name-ptr a2=0x8001f479),
  itself reached via `fdt_path_offset` (jal @0x80013842) called from
  **`fw_platform_init`** (jal sites 0x80007276/0x80007338/0x800073ee) —
  OpenSBI platform bring-up resolving FDT paths before console output.
- Inside `fdt_subnode_offset_namelen`: loop back-edge at 0x800133de →
  `jal fdt_next_node` @0x800133e6 (ret 0x800133ea); the depth-guard
  branch @0x800133f4 sees depth==0 every iteration → skips the name
  compare → restarts with offset 0. `fdt_next_node` correctly returns
  nodeoff=0 to the caller (raw records: caller `mv s1,a0` writes 0;
  the compressed epilogue insns are absent from trace format, a
  display omission, not a control divergence).
- DTB census: totalsize 0x843, 14 BEGIN_NODE tags, 57 props, 86 tags;
  root children `chosen`@0x7a, `cpus`@0x134, `memory@`@0x3af,
  `soc`@0x3eb. A complete root-child walk should return 0x7a first and
  finish in ~86 tag steps — the observed stream never leaves offset-0
  restarts, so the same offsets repeat with identical data = livelock.

### STEP 2 — production reference (archive, no new run needed)

- `linux-probe-l1ooo-trace` (production `core/` on this testharness,
  full RVFI): **15,812,118 retires**, first UART store at retire
  ordinal **1,297,731**, 4,761 UART stores total, OpenSBI v1.5 banner
  reached, exit 0. hyp8 r19v2: ~6.8M retires, zero UART — 5× the
  production count-to-banner with no banner. (Production run reported
  max retire gaps 270–276 cyc — diagnostics, not the defect.)

### STEP 3 — first wrong value (hyp8-r37-cell2 capture)

- `fdt_next_node`'s internal depth cell is coherent **inside the
  callee**: `lw a5,0(s2)` @0x80012b78, `+1`, `sw a5,0(s2)` @0x80012b7e.
- The caller's load of the **same stack cell** (~36 cyc later) reads the
  stale init value every time:

  ```
  cyc=81524 LD pc=80012b78 depth val=0
  cyc=81547 ST pc=80012b7e depth val=0x1
  cyc=81583 LD pc=800133ea depth val=0   ← stale
  cyc=86063 LD pc=80012b78 depth val=1
  cyc=86086 ST pc=80012b7e depth val=0x2
  cyc=86122 LD pc=800133ea depth val=0   ← stale
  ```

- Owner boundary: **store→load visibility/forwarding for a speculative
  stack store** (callee sw retires, caller lw 36 cyc later sees old
  data) — LSQ/write-buffer forwarding region, not D$ contents, not the
  DTB. Broken §4.3 promise: `analysis/execution-path-plan.md:119` —
  F6, "pending + committed-pending visible to hazards/forwarding".
- Mechanism chain: depth stays 0 → branch @0x800133f4 skips name check
  → `fdt_next_node` returns 0 → loop re-calls with a1=0 → livelock.
- No one-line identity defect pinpointed inside RTL in this brief; fix
  design deferred to lead (candidate: verify the forwarding/visibility
  path for a store retired while a younger same-address load was
  already in flight, or a speculative-slot release ordering issue).


## r38 (part 1) — store→load visibility miss localization

Diagnosis only, on the r36v2 model (sha `24a25a92…`); run
`hyp8-osbi-ld-vis-r1` (r19v2 recipe, 90k-cycle budget) with
`+ld_state +ld_lo=81400 +ld_hi=81700 +stq_trace +lsq_trace
+commit_trace +trace_from=81400 +trace_to=81700 +disp_trace
+rvfi_cycle_stamp +stall_census`. No RTL change. Probes:
`C:/Users/etcim/cva6-artifacts/hyp8-r38-ldvis/`.

### Same-address check (RVFI mem fields) — confirmed

```
cyc=81524 LD pc=80012b78 x15=0 addr=0000000080046ed8
cyc=81547 ST pc=80012b7e      addr=0000000080046ed8 sval=0x1
cyc=81583 LD pc=800133ea x15=0 addr=0000000080046ed8   ← stale
cyc=86063 LD pc=80012b78 x15=1 addr=0000000080046ed8
cyc=86086 ST pc=80012b7e      addr=0000000080046ed8 sval=0x2
cyc=86122 LD pc=800133ea x15=0 addr=0000000080046ed8   ← stale
```

Store (`sw a5,0(s2)`, 4B) and caller load (`lw a5,-0xb8(s2)`, base
operand 0x80046f20 + imm -0xb8) both target byte `0x80046ed8`.

### Store lifetime (iteration 1, tid=0, pc=0x80012b7e, data=1)

- alloc @81508; wb @81539; commit fire/ack @81541 (`[cmt] c=81541
  ... ack=11 dec=11 fire=11`).
- store_buffer: `commit_push` @81542 (`pushv=1 pend=1 pushpa=ed8
  pusht=0`); `cq0=v1 paed8/t0` @81543; drain request `dreq=1 dwe=1
  aidx=ed8` @81543-44; D$ store-port grant `gnt=1 dgnt=1 s2w=1`
  @81545; commit-queue pop @81546 → page-offset sticky armed
  (`stkv=1 stkpov=1 stkpo=ed8`).
- WT wbuffer (`wt_*` events): `wt_alloc ptr=0 data=1 be=0f` @81544;
  store-side tag-check reads (port 3) @81547-51; `wt_check ptr=0
  wtag=...8ddb hit=01` @81550-54 — the line WAS resident (way0).
  Two wbuffer records cover the word: tid=1 (older entry, same
  line, merged drain word `0000000100000001`) and tid=0 (this
  store). Both pushed TXs to the bus @81547/81548.
- Record tid=1: `wt_rtrn` @81559 (sack), **array write
  `wt_word idx=ed off=8 ways=01 data=1 ack=1` @81562**, evict
  @81563, txv clear @81564 → `dcache_wbuffer_empty_i` (wbe)=1
  @81564 → store-buffer sticky cleared @81565.
- Record tid=0: `wt_ack ... checked=0 hit=01 fix_push=1` @81567 →
  **`wt_fixup_push pa=ed8 be=0f data=1` @81567** — ACKed before its
  tag check completed → post-ACK fixup queue, array write deferred;
  `wt_evict id=0 push=1`. The fixup entry then occupies
  `fixup_wbuffer_o[0]` = `wbuffer_all[10]` (WtDcacheWbufDepth=8 →
  WbufExportDepth=10; hit bit = 0x400).
- **`wt_fixup_wr idx=ed off=8 ways=01 data=1 ack=1` @81573** — the
  deferred array write → `fixup_pop` at the 81573→74 edge.

### Stale-load tuple (tid=15, pc=0x800133ea, 4B)

- alloc @81563; `[lsq] ld_alloc p=0 idx=0 id=15 older=00000000` —
  no unresolved older store tracked (store already retired).
- addr valid @81570 (`LSQ[0] addr_v=1 addr=80046ed8`); lsqb insert
  @81571; issue/pop @81572.
- `[ldst] c=81572 v=1 acc=1 dreq=1 gnt=1 pop=1 pom=0 poso=0 stb=0
  fwd=0 sbe=1 wbe=1 treq=1` — no STB forward candidate, no
  page-offset match; `[stq] lpv=1 poi=ed8 lpa=ed8` but `pom=0`
  (spec/cmt/pend/S1/S2/sticky all legitimately empty — the store
  had fully drained to the D$).
- Load-unit FSM: `st=0000000001` (LU_S_IDLE) @81572 →
  `st=0000000100` (LU_S_SEND_TAG) @81573 → IDLE; **no
  WAIT_PAGE_OFFSET** (`wpo=0` throughout). LSQ: `dwait_set v=0`
  @81573, `unres=0` — verdict "none" (no wait, no forward).
- `LU-REQ id=0 idx=ed8` @81572 → `LU-TAG` @81573 → **`LU-RSP rid=0
  rdata=0` @81575** → `LU-WB tid=15` @81576 → `complete_in` @81577
  → retire (RVFI) @81583, x15=0.

### Where the bytes were at the load's D$ request (@81572)

Not in the spec queue, commit queue, commit_pend, S1/S2, or the
R3a sticky — all correctly empty (handoff to the D$ had completed).
Inside the D$: the fixup entry (pa=ed8, data=1) was alive in
`fixup_wbuffer_o[0]` AND the array word already held 1 (written
@81562 by the sibling record). The D$ forward path DID match:
`wt_lookup c=81573 port=1 pa=...ed8 ... forward=00000400 be=0f`
(bit10 = fixup slot 0). `wbuffer_fwd_hit` suppressed any refill —
the response was resolved entirely by the forward overlay.

### The miss — T1/T2 forward-merge race on the fixup export

`wt_dcache_mem` runs the response in two stages
(`HypCfg.DcacheHitExtra==2`, gen_rsp_pipe :575-643): T1 latches
`wbuf_hit_oh_q` and per-entry byte-valids `wbuf_vld_q`; T2 merges
`rd_data_c` and registers `rd_data_q`. The hit/valid vectors are
T1 snapshots, **but the leaf payload is read live**:
`node[0][e].d = wbuffer_all[e].data` (:506).

`fixup_wbuffer_o` is **positional**, not slot-stable
(wt_dcache_wbuffer.sv:1200-1259): `fwd_ent[i]` maps newest-first
via `usrc = (fixup_tail + 2D-1-ufifo) % D` and emits `'0` once
`ufifo >= fixup_cnt`. A `fixup_pop` therefore retracts the whole
exported payload one edge after its array-write ack.

Cycle-exact race:

```
81573: load T1 — live wbuffer_hit_oh=0x400 (fixup entry alive)
       → wbuf_hit_oh_q[10]=1, wbuf_vld_q[10]=0f latched @73→74
81573: wt_fixup_wr ack=1 → fixup_pop → fixup_cnt→0 @73→74
       → wbuffer_all[10] = '0 during 81574
81574: T2 — merge_hit[10]&merge_vld[10]=1 → wbuffer_be=0f,
       but wbuffer_all[10].data is now 0 → rd_data_c = 0
81575: rd_data_q = 0 → LU-RSP rdata=0 → x15=0 @81583
```

The overlay also **masked a correct resident array word** (the same
store's bytes were written to idx=ed/off=8/way0 @81562). The
invariant claimed at wt_dcache_mem.sv:572-574 ("a drain between T1
and T2 cannot silently retract forwarded bytes; a drained slot's
payload is not rewritten in the same window") holds for in-place
`wbuffer_q` slots but is **false for `fixup_wbuffer_o`**: pop
empties the slot entirely and push remaps it (tail-relative).

Iteration 2 is identical: `wt_fixup_push pa=ed8 data=2` @86106 →
live `forward=0x400` at the caller load's T1 @86112,
`wt_fixup_wr ack=1` @86112 → pop @112→113 → T2 reads dead slot →
`LU-RSP rdata=0` @86114 → x15=0 @86122.

### Contrast — callee reload LD@0x80012b78 @86063 (returned 1)

- tid=15 (re-allocated ~86042); `LU-REQ id=0 idx=ed8` @86052 →
  `LU-TAG` @86053 → **`LU-RSP rid=0 rdata=1` @86055** → retire
  @86063.
- At its T1 @86053 there was **no** fixup/wbuffer entry for ed8
  (`forward=0` — the iteration-2 store was still in the STB:
  `wt_alloc` @86083). Its response came through the plain
  array/refill read path — no forward overlay, no race.

The miss is timing/path specific: it fires only when a load's D$
access lands in the narrow fixup-entry window (push→pop ≈ 6-7
cycles) such that the entry is alive at T1 and dead at T2.

### First-false promise

**wbuffer→load forward** — inside `wt_dcache_mem`'s staged
response: the T1-snapshotted forward decision (`merge_hit`,
`merge_vld`) is honored at T2 against a **live, positional** fixup
export whose payload is retracted by `fixup_pop` in the T1→T2 gap.
All other candidates are exonerated by the tuples: the store_buffer
contract was fully discharged (spec/cmt/pend/S1/sticky empty only
*after* the D$ had accepted and made the bytes forward-visible —
wbe@81564 predates but does not gate the fixup export), the LSQ
verdict was faithful (`older=0`, `unres=0`, `dwait=0` — the store
had retired before the load allocated), and the load-unit
interlock was faithful (`pom=0` correctly reported STB-side
emptiness; the load correctly proceeded to the D$ forward path).

Broken §4.3 promise (refined from r37): F6 — "pending +
committed-pending visible to hazards/forwarding". The bytes were
visible at T1 but the promise was silently retracted before the
response beat. Owner boundary: `wt_dcache_mem.sv` gen_rsp_pipe
merge (live `wbuffer_all[e].data` leaf) ×
`wt_dcache_wbuffer.sv` positional `fwd_ent`/`fixup_wbuffer_o`
export.

No RTL change made; fix design deferred to the lead (options noted:
T1-snapshot the forwarded payload; hold the fixup export stable one
extra cycle past pop; or T2-revalidate + replay).

## r38 — wbuffer→load forward payload snapshot (T1 representation) + witness r20

Fix per PL-P2/PL-P3 (the same rule F6 imposed on stb_fwd in r1): the
wbuffer→load forward must cross the D$ T1→T2 edge as a complete
representation {hit one-hot, byte-valid, DATA}, not as a match whose
payload is re-read live at T2. r37/r38-part-1 showed the r37
fdt_next_node value-livelock was caused by exactly this: a load whose
T1 matched a positional fixup export (`forward=0x400`, slot 10) had
its T2 land after `fixup_pop` retracted the export; the live reread
returned 0 and the forward overlay masked the already-correct array
word.

### RTL (wt_dcache_mem.sv, gen_rsp_pipe DcacheHitExtra=2 arm)

- T1: alongside `wbuf_hit_oh_q`/valid capture, the per-byte forward
  word selected by the live hit one-hot from live `wbuffer_all[*].data`
  (including positional fixup export slots) is computed and registered
  into `fwd_data_q`.
- T2: merges `fwd_data_q` bytes under captured byte-valid with the
  array read; the fixed path never reads `wbuffer_all` at T2.
- Old live-T2 form preserved under `G6LC_MUT_WBUF_FWD_LIVE_T2`.
- translate_off: every-cycle equivalence assertion (slot still valid
  and unchanged at T2 → registered word == live word) +
  `[equiv] wt_dcache_mem fwd_snap: checked=N` under `+equiv_report`.
- `empty_o` unchanged — fixup bytes are already memory-visible (the
  entry exists only because memory ACK happened before the tag check),
  so fence-level visibility holds; the forward covers same-core RAW
  ordering only (per-core observer caveat recorded in the file).

Churn vs r36v2/r36xv2 closures: exactly ONE file
(`core/cache_subsystem/wt_dcache_mem.sv`, sha aef1d9713ce77045…).

### Leaf (tb_g6lc_hyp8_dcache)

- `hyp8-control-dcache-dchx2-r48`: `HYP8_DCACHE_PASS checked=292
  dchx=2 stores=102`; `[equiv] wt_dcache_mem fwd_snap: checked=852`.
  New DCHX_FIXUP_WINDOW_FWD case drives the traced lifecycle
  (push@N, load T1@N+6, pop@N+6→N+7, T2@N+7) via a RETIRE write+pop
  (the dead-entry drop retains payload and cannot expose the mutant);
  plus pop-before-T1 (plain array read) and pop-after-T2 (live
  forward) variants.
- `hyp8-control-dcache-dchx2-r48mut`: fails at
  `FAIL DCHX_FIXUP_WINDOW_FWD` — assertion
  tb_g6lc_hyp8_control.sv:3668 @11066, as required.
- `hyp8-control-dcache-dchx0-r20`: `HYP8_DCACHE_PASS checked=313
  dchx=0 stores=112` (no T1/T2 split; window witness vacuous).
- `hyp8-control-memory-r31` (neighbour): `HYP8_MEMORY_PASS
  checked=99`, unchanged.

### Closures / lint / builds

- r38 = r36v2 + fix; r38x = r36xv2 + fix (693 files each).
- `hyp8-integration-r38`: lint scalar 343/87/3, SMT2 354/97/3, 0
  errors; build rc=0; model sha
  676610eb132df76cc7db4f31e802cb1891d728b178aa60f84e1430ed6f4c967f.
- `hyp8-integration-r38x`: lint scalar 343/87/3, SMT2 353/97/3
  (r36xv2 baseline — the external-free profile has carried 353 since
  r34xq; brief's 354 figure is the r36v2 census), 0 errors; build
  rc=0; model sha
  e5edfdf740709f58f165baee280de54ebe1c6a66ce5065ae50a08eaa53d7c5cd.

### Smokes (hyp8-r38-smokes)

- h34-r38 682, bc-r38 473, h33x-r38x 889, bcx-r38x 475 — bit-identical
  to r36v2/r36xv2, 31 equiv counters each (30 + fwd_snap).
- **h33-r38: 400k budget-out → real `*** SUCCESS *** (tohost = 0)
  after 969 cycles`.** Positive delta on the flagged forward path:
  h33_st_fwd was silently wedging on the same fixup-pop T1/T2 race on
  the scalar profile (r36v2 showed `[cycle budget reached: no tohost
  verdict]`); the snapshot fix returns the forwarded data and the
  program completes. fwd_snap exercised: checked=68 (h33-r38), 74
  (h33-r38x).

### Witness hyp8-osbi-scalar-r20x (r38x, 6M, +equiv_report)

- `*** SUCCESS *** (tohost = 0) after 6000000 cycles [cycle budget
  reached: no tohost verdict]`; mc_verdict exit 0; ckpt final clean
  (pop_mismatch=0, restore_mismatch=0); rc=120 standing budget-out
  convention; wall 32.6 min.
- ret=**1,920,215** (vs 1,703,285 on r19xv2); ipc 0.314/0.323/0.320
  at 2M/4M/final census; 0 [hang], 0 %Error, 0 assertion hits.
- **UART: THE GATE IS OPEN.** First UART store pc 0x80010e1e
  (uart8250_putc) @cyc 4,757,906, retire ordinal **1,531,354**
  (production reference: 1,297,731 — +18% deeper pipeline, expected).
  315 bytes total, verbatim:
  `ESC \r\nOpenSBI v1.5\r\n` + the ASCII logo through `|_|\r\n\r\n`.
- Milestone retire ordinals (cycle): sbi_init 314,041 (984,661);
  sbi_domain_init 315,295 (992,073); sbi_hsm_init 354,412 (1,192,096);
  sbi_hart_init 1,151,960 (3,602,732); sbi_console_init 1,205,724
  (3,784,909); first UART 1,531,354 (4,757,906); sbi_irqchip_init
  1,695,236 (5,383,870). sbi_timer_init / sbi_ecall_init / Boot HART
  line / payload jump: NOT reached within 6M (banner bytes were the
  logo only). Last pc @5,999,986 = 0x80012898 fdt_offset_ptr (legit
  FDT walk, blob at 0x82200000).
- fdt_next_node entries: 544 over 6M vs 4,903 livelock restarts on
  r19v2 — real walks.
- equiv: 31 counters; fwd_snap checked=**987,677**; csr_buffer alloc /
  lsq arms/evcount/col / iq_legal / tlb plru ×2 ≈ 5,999,986; cambe
  ×16 = 5,996,496; ras_upd 44,245; pubmarks 1,110,029.
- mem side note: mem_viol=23 at final census (standing counter, grew
  7→9→23 — speculative violations replayed; same counter nonzero on
  prior witnesses).

### Witness hyp8-osbi-scalar-r20 (r38, 20M, +equiv_report)


### Witness hyp8-osbi-scalar-r20 (r38, 20M, +equiv_report)

- `*** SUCCESS *** (tohost = 0) after 20000000 cycles [cycle budget
  reached: no tohost verdict]`; mc_verdict exit 0; ckpt final clean
  (pop_mismatch=0, restore_mismatch=0); wall 98.7 min; rc=120
  convention; 0 [hang], 0 %Error, 0 assertion hits.
- ret=**5,622,020**; ipc 0.323/0.325/0.326 at 10/12/14M, 0.281 final
  (the last window is the spin below); mem_viol=379.
- equiv: 31 counters; fwd_snap checked=**2,659,179**; csr_buffer
  alloc/tlb plru x2 19,999,986; cambe x16 19,997,631.
- Milestone retire cycles: sbi_init 980,598; sbi_domain_init 987,437;
  sbi_hsm_init 1,187,385; sbi_hart_init 3,597,224; sbi_console_init
  3,778,788; sbi_irqchip_init 4,739,788; sbi_ecall_register_extension
  entries from 16,262,171. fdt_next_node entries 757 (legit walks).
  banner / Boot HART / payload jump: NOT reached.
- **0 UART bytes.** The scalar profile is a second-order witness: it
  progressed ~2x slower through init (fdt_getprop/domain phases) and
  at ~16.26M entered a NEW spin in sbi_ecall_register_extension
  (79,499 iterations of the list-walk loop 0x80008d2a-8d38 to budget
  out; last pc 0x80008d38 @19,999,976). Mechanism captured verbatim:
  the circular-list walk loads head->next=0x800405a0 correctly, walks
  nodes 0x800405a0 (TIME)->0x800405d8 (RFNC)->0x80040610 (sPI)->
  0x80040648 (SRST 0x10), then node 0x80040648's `next` at
  mem[0x80040648] returns **0** instead of &head=0x80040518 -- the
  pointer stored by that node's own insert (`sd a3,0(a1)`) ~600
  cycles earlier. a5=0 then spins on mem[0]/mem[0x18] reads at ~47
  cycles/iter. Same defect CLASS as r37 (committed-store -> later-
  load reads zero), but PERSISTENT (600+ cycle distance -- not the
  T1/T2 window the r38 snapshot covers). r19v2 never reached this
  site (its livelock was ~10x earlier), so this is a previously
  unexercised path on the scalar profile -- r38 exposed it by fixing
  the first blocker. fwd_snap: 2.66M checks, 0 assertion hits.
- r20-vs-r20x retire-PC stream compare (evidence for the profile
  divergence): identical until retire ordinal 5,255, where r20x
  squashed a `ret @0x80012ada` (redirect straight to the RAS-predicted
  return target, architecturally equivalent) while r20 retired it;
  streams re-sync with +1 shift for 310 retires then diverge again --
  pre-existing profile behavior. Zero trap-handler-body executions on
  both traces (no M-mode interrupts).

Next-step note for the lead: the r20 spin localizes to a persistent
committed-store visibility miss (a node `next` link stored by a
prior registration read back as 0 by a walk ~600 cycles later --
array-level staleness, not a forwarding window). Candidates: fixup
write updating memory but not the resident D$ line the walk hits, or
the store never reaching the array. Not diagnosed further here.

## r39 (part 1) — second visibility miss localization + r21x

### r38 second miss localized: wbuffer retire drops a re-drained entry's L1-write obligation (resident line never updated)

Diagnostic run `hyp8-osbi-ecall-vis-r1` on the r38 model
(sha 676610eb132df76cc7db4f31e802cb1891d728b178aa60f84e1430ed6f4c967f),
16.29M-cycle windowed probes (+ld_state/+ld_trace window, +stq_trace,
+lsq_trace, +commit_trace, +disp_trace, +smt_flow_trace, +stall_census,
+equiv_report, +rvfi_cycle_stamp). Verdict `*** SUCCESS *** after
16290000 cycles [budget]`, ckpt clean, fwd_snap=2,659,179, 0 asserts.

**D$ line state for 0x80040640 (idx=0x64):**
`wt_refill cycle=16263020 idx=64 tag=00000080040 way=3 nc=0
data=00000000000000000000000080009130` — resident in **way 3**,
offset-8 word = 0 (correct pre-insert content). No wt_inval, no
eviction, no second refill for idx=64 at any later cycle in the whole
run — the line stayed resident with the refill-time word until the end.

**Store lifetime (both stores to 0x80040648):**
- `wt_alloc cycle=16263521 ptr=0 merge=0 be=ff data=0x80040648`
  (store A, `sd a1,0(a1)`); tag checks `wt_check ptr=0 wtag=100080c9
  hit=08` @16263528-36 — line confirmed resident, way 3.
- TX sends: `wt_tx @16263524 id=3 data=0x80040648` and
  `wt_tx @16263525 id=2 data=0x80040648` (dirty→0, txblock→1, bytes in
  flight to memory).
- **store B (`sd a3,0(a1)`, data=0x80040518) merged into the SAME entry
  while in flight**: `wt_alloc cycle=16263529 ptr=0 merge=1
  data=0x80040518 | before: valid=ff dirty=00 txblock=ff` — bytes
  re-dirtied (state 111), must re-drain.
- `wt_ack cycle=16263540 id=3 ptr=0 wtag=100080c9 data=0x80040518
  be=00 checked=1 hit=08 wr_req=00 wr_ack=0 fix_push=0 check_wr=0` —
  `ack_be = tx.be & ~dirty = 0` (all bytes re-dirtied) so BOTH retire
  legs are masked (`leg_l1_d` and `leg_fire_d` both require `|ack_be`,
  wt_dcache_wbuffer.sv:1574-1600): no array write, no fixup — `drop_q`
  evict; txblock cleared (entry survives 110).
- Re-drain: `wt_tx cycle=16263542 id=3 data=0x80040518` (the merged
  bytes sent again; dirty→0, txblock→1, tx_stat[3] records ptr=0).
- `wt_ack cycle=16263544 id=2 ptr=0 wtag=100080c9 be=00 checked=1
  hit=08 wr_req=00 fix_push=0` — the second return's snapshot also
  caught dirty=ff (pre-@542-drain) → drop. The evict cleared ALL byte
  valids (`evbe & ~dirty`, live dirty now 0) → **the entry was freed
  while send @16263542 (id=3) was still in flight.**
- `wt_alloc cycle=16263546 ptr=0 merge=0 data=0x80040648` — ptr=0
  reallocated to the `0x80040610` store (wtag 80c9→80c2).
- `wt_ack cycle=16263558 id=3 ptr=0 wtag=100080c2 be=ff checked=1
  hit=04` — the orphaned return resolves ptr=0 to the NEW occupant's
  word (cross-retire); `wt_word cycle=16263557 idx=61 off=0 ways=04
  data=0x80040648` wrote the *new* occupant's data into idx=61 —
  correct value only by coincidence (both words wanted 0x80040648).
- **No `wt_word idx=64` in the window at all** (all 72 log-wide are
  <15M, FDT era). **No `wt_fixup_push` for wtag 80c9/80ca.**
- The `0x80040650` stores (wtag 80ca, ptr=1) hit the SAME pattern:
  merged @16263539 while in flight, ACKs @16263548/52 dropped be=00 —
  also never wrote the array (invisible: the `prev` field is never read
  by the walk).

**Load (`ld a5,0(a5)` @0x80008d36 → 0x80040648):**
port=1 lookups @16263906/909/938/941 all `hit=00 forward=00 be=00
result=0`; `LU-RSP rid=0 rdata=0` @16263908 — hit-latency response, no
port=3 recheck, **no refill** (the spin's address-0 lookups DID miss
and refill normally — port=3 `refill=1` + wt_refill on idx=1). The
load was served the stale resident word (0) — ~79,499 identical
iterations to budget-out. Secondary anomaly: the port=1 `hit` print
reads 00 while the same line checked hit=08 for the store — worth a
probe-semantics check, but does not change the outcome (array word = 0
either way).

**Store's bytes at the load's T1/T2:** only in memory (the three
wt_tx sends); absent from the array, absent from the wbuffer (entry
freed @16263544), absent from the fixup queue. Persistent — not a
window race.

**First-false promise:** the wbuffer retire released an entry on an
earlier ACK while a *re-drain* of the same entry's bytes was still
in flight. `ack_be = rtrn_tx.be & ~dirty` (:1723) masks the
L1-write and fixup legs for bytes a younger same-word store re-dirtied
(correct), but the subsequent `drop_q`/`valid_mid` release
(:2097-2102, :1534-1545) frees the entry as soon as the re-drained
send clears `dirty` — without waiting for that send's own ACK. The
re-drain's L1-write obligation was held only inside the entry and dies
with it; tx_stat keeps pointing at the freed slot, whose reallocation
turns the surviving return into a cross-retire against a different
word. §4.3 F6 refined: "a checked resident-line store must terminate
in an array write or a fixup; `checked=1 hit!=0` must never end in a
silent drop." Defect site: wt_dcache_wbuffer.sv retire/leg paths
(shared by r38 and r38x — the trigger is the multi-send + merge-in-
flight + interleaved-ACK interleaving; timing-dependent).

**Siblings confirmed innocent:** STB/commit drained before the D$
events; LSQ `older=0` verdicts faithful; no other write to 0x80040648
in the window; r38's T1/T2 snapshot not involved (forward=00 at the
load — the store had left the buffer ~360 cycles earlier).

### hyp8-osbi-scalar-r21x (r38x, 20M) — second miss does NOT reproduce; new assertion abort at 17.01M

Model sha e5edfdf740709f58f165baee280de54ebe1c6a66ce5065ae50a08eaa53d7c5cd,
fw a9218107…. **Aborted** at cycle 17,010,870 on
`load_unit.sv:1477 misaligned_entry_excepts` (misaligned load-buffer
entry did not complete with LD_ADDR_MISALIGNED and a killed request).
rc=255, 0 [hang], 2 %Error lines, no end-of-run equiv counters
(aborted before report). ret=5,471,606; census @16M: ret=5,190,520,
ipc=0.324, mem_viol=69.

- **UART = 315 bytes, byte-identical to r20x** (`\x1b\r\nOpenSBI
  v1.5\r\n` + logo through `|_|\r\n\r\n`); first UART store at retire
  ordinal 1,531,354 (same ordinal as r20x). No Platform Name / Boot
  HART / Domain lines (aborted before them).
- Milestones (ordinal/cycle): sbi_domain_init 315,294/992,073;
  sbi_hsm_init 354,411/1,192,096; sbi_hart_init 1,151,959/3,602,732;
  **sbi_timer_init 3,615,886/11,330,397**; **sbi_ecall_init
  5,471,453/17,009,632**; sbi_ecall_register_extension first entry
  5,471,477/17,009,894. Payload jump / S-mode: not reached.
- **ecall_exts_list walk: 194 retires in pc 0x80008d* total — no
  spin.** The last ~80 retires show `sbi_ecall_register_extension`
  working correctly end-to-end: the list walk read the right `next`
  pointers (`mem[0x800405a0]=0x800405d8`, TIME/RFNC name words
  0x54494d45/0x52464e43), inserted node 0x80040610 with all seven
  linking stores, restored ra/s0 from the stack (0x80009162 /
  0x80045f10) and retired `ret` @17,010,858. The misaligned-entry
  assertion fired ~12 cycles after that `ret`, on a younger
  (post-return) load.
- Verdict: the persistent store→load visibility miss is **not
  reproduced on the external-free line** — same shared wbuffer RTL,
  different interleaving exposure. The r21x abort is a third,
  distinct signature in the load_unit misaligned-completion contract;
  not localized here.

### Artifacts / provenance
- ecall-vis run: /opt/testharness/runs/hyp8-osbi-ecall-vis-r1
  (run-hyp8.log ~7.6 GB); local extracted views:
  cva6-artifacts/hyp8-r39-ecallvis/{win-all,win-wt,win-addr}.txt +
  full probes file.
- r21x run: /opt/testharness/runs/hyp8-osbi-scalar-r21x;
  cva6-artifacts/hyp8-osbi-scalar-r21x/results.json.
- Churn this pass: analysis/implementation-log.md only. No RTL change.

## r41 — wbuffer single-TX drain discipline + IRO T50 lag + cfg legality (r38/r38x overlay)

Three defects repaired, all in the write-buffer drain/retire path plus
the legacy IRO multiplier-writeback arm. Frozen tree assembled as
closures r41 (= r38 + 3 files) and r41x (= r38x + 3 files, x-line IRO
port); each manifest records exactly three sha256 differences vs its
parent (see below). No commit; hashes pin the evidence.

### Defects and mechanism

1. **D1 grant-window recapture (first-false promise).** Under
   `HypCfg.WbufPipelined` the drain stage `gen_drain_reg`
   (wt_dcache_wbuffer.sv) recaptured `dr_ptr/dr_mux/dr_bdirty/dr_vld`
   from `wbuffer_q` every `!drain_hold_q` cycle. The grant at N+1
   (`dirty_rd_en = miss_req_o && miss_ack_i`) updates `dirty`/`txblock`
   in `wbuffer_d`, visible only at N+2, so the N+1 capture re-offered a
   just-granted entry at N+2 — a second TX for bytes already in flight
   (two in-flight TXs on different AXI ids; violates the byte-state
   contract bdirty-excludes-txblock). Fix: module-level
   `drn_hit[gi] = miss_req_o && miss_ack_i && (dr_ptr == gi)` and
   `dirty_sendable = WbufPipelined ? (dirty & ~drn_hit) : dirty` feeding
   `i_dirty_rr.req_i` and `dr_vld`. Live arm is literal identity
   (`assign dirty_sendable = dirty;`) to avoid the
   dirty_ptr→drn→req→dirty_ptr combinational loop. Mutant
   `G6LC_MUT_WBUF_DRAIN_RECAPTURE` restores the unmasked request.
   Assertion `g6lc_tx_single`: on `miss_req_o && miss_ack_i`,
   `wbuffer_q[dr_ptr].txblock=='0 && tx_cnt_q[dr_ptr]=='0`; $error plus
   `[equiv] wt_dcache_wbuffer tx_single: checked=N viol=N` under
   +equiv_report.
2. **One-cycle-late `dr_vld` after an ack** (leaf-exposed): `dr_vld`
   stayed asserted for one cycle after an acknowledgement, letting a
   level acceptor resend. Caught by the J0 `DCHX_SINGLE_TX` check and
   the tx_single assertion; fixed by the same masked-request change
   (dr_vld <= |dirty_sendable).
3. **Dead-pop `txblock` release** (leaf-exposed): a dead-pop eviction
   could clear `txblock` while a transaction was still in flight.
   Caught by the `g6lc_tx_single` assertion (`txblock==0` on accept)
   and the J1 ledger scenario; fixed by ownership-gating the txblock
   release on the in-flight ledger (`tx_cnt_q`/`last_tx_gi`, viol
   counter printed in the same equiv line).

4. **IRO T50 lag, legacy arm only** (issue_read_operands.sv): under
   `!HypCfg.WbReserve` a `MulWbLag = hyp_mult_stages(...)-1` shift
   register of `|mult_valid_q` (`mult_wb_block`) replaces the single
   `if (|mult_valid_q)` rule — ports reference commit 5c5829b52. The
   `WbReserve` arm is unchanged (`assign mult_wb_block = |mult_valid_q`).
   Same hunk applied to the x-line IRO variant (staging-r41x).
5. **`hyp_cfg_ok` legality** (g6lc_hyp_pkg.sv): added
   `ok &= h.WbReserve || (h.AluStages == 1)` — the legacy structural-
   hazard arm models one-cycle FLU classes; a staged ALU needs the
   reservation model. HypDefault (1,0) and Hyp8 (3,1) both pass.

### Leaf matrix (tb_g6lc_hyp8_control.sv, section J; run_hyp8_memory.py)

| run | build | verdict |
|---|---|---|
| hyp8-control-dcache-dchx0-r41base | baseline section J, dchx0 | `HYP8_DCACHE_PASS checked=313 dchx=0 stores=112` |
| hyp8-control-dcache-dchx2-r41 | r41 plain, dchx2 | `HYP8_DCACHE_PASS checked=277 dchx=2 stores=88`; `tx_single: checked=88`, `l1_obligation: dropped=2`, `fwd_snap: checked=732` |
| hyp8-control-dcache-dchx2-r41recap | +G6LC_MUT_WBUF_DRAIN_RECAPTURE | J1/J2 pass, then `FAIL DCHX_SINGLE_TX` (expected negative control; log shows `g6lc_tx_single violation: entry 0 txblock=ff tx_cnt=1` at c=2150) |
| hyp8-control-dcache-dchx2-r41recapfi | +RECAPTURE +G6LC_MUT_WBUF_FREE_INFLIGHT | `FAIL DCHX_REDIRTY_REDRAIN_L1` inside J1 (expected ledger negative control) |
| hyp8-control-dcache-dchx0-r41 | r41 plain, dchx0 (live arm) | `FAIL D_NO_PMU_PULSE` — r41 path performs a fixup write/invalidate where the baseline dead-drops (sim.log c=404-408: `evict sid=2 ... push=1 drop=0`, fx FSM busy), so the expected PMU pulse is absent. Open item; not iterated further per the minimal-gate directive. |

### Closures (sha256 diffs vs parents, manifest-pinned)

- r41 (693 files, parent r38): wt_dcache_wbuffer.sv 5967b9f5→bb38a121,
  g6lc_hyp_pkg.sv c4e9c656→16dd24c3, issue_read_operands.sv 8815f819→910c10b9.
- r41x (693 files, parent r38x): wbuffer 5967b9f5→bb38a121,
  g6lc_hyp_pkg.sv c4e9c656→16dd24c3, issue_read_operands.sv
  1e1f0010→ce85915f (x-line port).
- Working tree re-verified identical to closure contents (same shas).
- Closures: cva6-artifacts/closures/hyp8-integration-r41{,x}-closure.

### Integration lint + build (remote, testharness_proxy `py` → run_hyp8_integration.py)

- `hyp8-integration-r41`: **build_complete**; 693 source files; model
  sha256 3144a8a1f766eccb9665e1fc269a94d3085ad850f221f7d9833f437b4dd9f8d2;
  build rc=0; runtime dep check 204 files vs pinned runtime header.
  Lint scalar rc=0 %Error=0; smt2 rc=0 %Error=0. Census identical to
  r38 modulo WIDTHEXPAND/WIDTHTRUNC: scalar 343/87/3 (WIDTHCONCAT),
  smt2 354/97/3; LATCH=3 (all tier-U axi_riscv_amos_alu.sv).
  Artifacts: cva6-artifacts/hyp8-integration-r41/{results.json,
  lint-scalar.log, lint-smt2.log, build-harness.log}.
- `hyp8-integration-r41x`: **build_complete**; model sha256
  7929daa7a818b5b0f15c5fd4ab71ee66c8db22ad98c43b33266f03d7ecb90c88.
  Lint scalar rc=0 %Error=0 (343/87/3), smt2 rc=0 %Error=0 (353/97/3).
  Artifacts: cva6-artifacts/hyp8-integration-r41x/.

### Smokes (run_r41_smokes.py, +time_out/+max-cycles=400000 +debug_disable +quiet_axi +equiv_report +tohost_addr=0x80001000)

ELF shas are record-only (rebuilt per run; not bit-reproducible vs the
r38 pins — same srcSha256 + gccSha256). Model shas pin-matched.

| run | cycles | expected | verdict |
|---|---|---|---|
| hyp8-h34-r41 | 682 | 682 | SUCCESS, bit-identical; tx_single checked=0 |
| hyp8-h33-r41 | 969 | 969 | SUCCESS, bit-identical; tx_single checked=10 viol=0, l1_obligation dropped=5, fwd_snap 46 |
| hyp8-branch-cancel-r41 | 473 | 473 | SUCCESS, bit-identical |
| hyp8-h33-r41x | **899** | 889 | SUCCESS tohost=0 but +10 cycles vs r38x — attributable to the drain-recapture fix (a removed redundant re-send serializes the drain differently; tx_single checked=10 viol=0, l1_obligation dropped=3, fwd_snap 60). Recorded, not hand-waved. |
| hyp8-branch-cancel-r41x | 475 | 475 | SUCCESS, bit-identical |

Artifacts: cva6-artifacts/hyp8-r41-smokes/results.json;
remote /opt/testharness/runs/hyp8-r41-smokes + per-test run dirs.

### Witnesses (detached, left running)

- `hyp8-osbi-scalar-r22`: model hyp8-integration-r41, fw_payload.elf sha
  a9218107… (pinned), argv `+time_out=20000000 +max-cycles=20000000
  +debug_disable +quiet_axi +tohost_addr=0x80041730 +stall_census
  +hang_dump=2000 +equiv_report +rvfi_cycle_stamp`, launched via
  `proxy py run_r22_witness.py --tag hyp8-r22-witness-launch`;
  remote pid 1202929, run dir /opt/testharness/runs/hyp8-osbi-scalar-r22.
- `hyp8-osbi-scalar-r22x`: same argv on the r41x model, pid 1202930,
  /opt/testharness/runs/hyp8-osbi-scalar-r22x.
- Predictions: r22 must pass the 16.26M sbi_ecall_register_extension
  site (the r39 miss); r22x either passes or re-hits the r21x
  load_unit.sv:1477 misaligned_entry_excepts abort at ~17.01M (third
  signature, out of scope here). **Verdicts pending — detached, not
  polled.**

### Open items
- rr fairness note: in the pipelined arm `i_dirty_rr.gnt_i(dirty_rd_en)`
  advances the pointer on the live pick `dirty_ptr` while the granted
  entry is the registered `dr_ptr` — fairness only, not correctness.
- dchx0 D_NO_PMU_PULSE divergence (fixup-vs-dead-drop) — unresolved,
  deferred at the minimal gate.
- Neighbour `memory` leaf not re-run this batch (minimal gate).
- ELF hashes are record-only going forward (rebuilds not bit-stable).

### r41 addendum — witness verdicts (polled after r42-T board close)

The two detached 20M witnesses both **aborted on the r41 `g6lc_tx_single`
assertion** — the r41 repair does NOT hold under real traffic:

- `hyp8-osbi-scalar-r22` (r41 model): `%Error: wt_dcache_wbuffer.sv:2406`
  `g6lc_tx_single` — "second send while TX in flight: entry 0 txblock=80
  tx_cnt=1" at cycle 971182 (~0.97M), preceded by a sustained burst of
  `l1_obligation ... freed by drop` events. `Verilog $stop` abort.
  Remote log: /opt/testharness/runs/hyp8-osbi-scalar-r22/run-hyp8.log.
- `hyp8-osbi-scalar-r22x` (r41x model): identical signature at cycle
  289632 (~0.29M). Remote log:
  /opt/testharness/runs/hyp8-osbi-scalar-r22x/run-hyp8.log.

Neither prediction was reached: r22 died ~15.3M cycles before the
16.26M `sbi_ecall_register_extension` site; r22x never approached the
17.01M `misaligned_entry_excepts` signature. The witnesses are not
running (both aborted; no remote verilator processes remain).

Static narrowing on the shipped tree: the failing grant reached
`dr_ptr=0` while `wbuffer_q[0].txblock==8'h80` and `tx_cnt_q[0]==1`.
`bdirty[k]` (and therefore the arbiter-visible `dirty[k]`) is forced to
zero whenever ANY `txblock` bit is set, and `dirty_sendable` masks the
just-granted entry via `drn_hit` — so a *fresh* pick of a blocked entry
is impossible. The residual hole is therefore one of: (a) a drain
record captured while the entry was sendable surviving a drop+realloc
of that slot into a state whose ledger no longer matches the captured
view; (b) a `tx_cnt`/`txblock` release-vs-decrement skew on the drop
path (`ev_gi && rtrn_tx.vld` gates both, but `evbe` coverage is
per-byte — a partial release leaves `txblock` set while `tx_cnt` has
already decremented, and the converse half-release is unhandled); or
(c) a return-FIFO pop whose `rtrn_ptr` snapshot names the wrong entry
under drop bursts. Also noted: `wbuffer_d[gi].txblock[k]` has no
`wr_gi` clear term, so a reallocated slot inherits stale `txblock` —
that wedges the entry (it can never become `bdirty`) rather than
double-sends, but it is a real liveness hole adjacent to this one.
`hyp8-h34-r41x` was never launched (run dir absent) — the x-line h34
smoke evidence is missing.

This is a first-false-promise miss on real traffic; the dchx2 leaf
matrix (man_dup) does not exercise the drop-burst interleaving that
produces it. An r41v2 closure + rebuild + rewitness is required before
the wbuffer repair can be called verified; decision left to the plan
owner. The r42-T tree below was measured on the same wbuffer source.

### r41v2 diagnostic — predictions (written before launch, 2026-10-24)

Diagnostic model = r41x closure + `wt_dcache_wbuffer.sv` with the
new translate_off `g6lc_free_slot_clean` invariant
(`(|wbuffer_q[k].valid == 0) |-> (txblock == '0 && tx_cnt_q[k] == '0)`)
— it fires at the first free-with-ownership-residue slot and names the
entry/cycle so the windowed trace identifies the last clearing path.
No functional RTL change. Run: r41x reproduction (aborts at 289632),
`+smt_flow_trace +equiv_report` added to the r22x argv, window ≈
cycles 286600–289700.

Three named-mechanism predictions:

- **(a) Held D2 drain record surviving a drop/realloc of the same
  slot.** Predicts: the last `wt_alloc` to ptr 0 lands while
  `drain_hold_q` still carries the old record — i.e. an `smt-flow`
  `wt_alloc` line for ptr 0 after the drop, with no intervening
  `wt_tx`/`dr_vld` recapture, followed by a `wt_tx` whose dr_ptr=0
  grant fires `g6lc_tx_single`.
- **(b) txblock clear not ownership-gated while tx_cnt=1.** Predicts:
  a `txblock 1→0` transition on entry 0 byte 7 (`txblock=80` at the
  abort names byte 7) in the window with **no** `wt_ack` covering that
  byte's TX — i.e. an `ev_gi`/`vkc_gi`/inval clear while
  `tx_cnt_q[0]=1`. (`wr_gi` has no txblock term, so a merge cannot
  clear it; but a freed-with-txblock slot reallocated by `wr_gi`
  *inherits* txblock — that variant shows as `g6lc_free_slot_clean`
  firing at the free, then `wt_alloc` to the same ptr.)
- **(c) W2S return snapshot naming the wrong entry under drop
  bursts.** Predicts: `rtrn_ptr != tx_stat_q[rtrn_id].ptr` at an
  `evict` — visible as a `wt_evict` line whose ptr release lands on an
  entry other than the one the TX id named at push.

Discriminator: if `g6lc_free_slot_clean` fires *before* the final
`wt_tx`, the residue existed at free time → (b)-family; if the slot is
clean until the anomalous grant, the captured-record path (a) or the
snapshot path (c) owns it.

## hyp8 r42-T — Tier 1/2 structural FO4 pass (2026-10-24)

Scope: structural timing only. Per the deferred-validation decision no
leaves, smokes, or witnesses were run on the r42-T tree; functional
evidence for these rewrites is their in-tree equivalence assertions and
review mutants plus the r42-T lint below. Tools: sv-timing delay-v44 /
correction-v5, parser pin v0.13.5, IR v5; board argv =
analyze-ghz-r3.cmd with `inputs/param-map-hyp8-v2.json` (AluStages=3,
RVH=0, CohPolicy=COH_FILTERED pinned — the r1/r2 alu/lsq/shared_tlb
rows were measurement errors, superseded per T9).

### Board result (post-revert tree)

`boards/hyp8-core/analyze-ghz-r4.json` (full `--all-modules --stages`,
45 live modules) + `clock-r4-vs-r3b.txt` (top-45 diff):

- Structural clock **0.96 GHz / 41.6 FO4** — `g6lc_rename_resolve`
  in-stage RR (the retained explicit `hi_last` prefix OR). Identical
  limiter to r3b: the pass held the top-of-board flat; every landed
  item's target cone was below the global limiter after the
  countercase reverts.
- Top rows: shared_tlb 39.6 (:841), lsq_reduce 38.2 (in-stage R),
  ptw 37.4 (:604), g6lc_tlb 36.4 (:602), load_unit 36.1 (into L2),
  iq_arb 34.8 (ARB), wt_dcache_mem 33.3 (:526), iq_bank 32.3 (SEL),
  rename_recover 31.8 (:589), loop_buffer 31.8 (:236).
- Movers vs r3b: `g6lc_rob` −1.9 (item-23 parallel-arm pick),
  `g6lc_ooo_dispatch` −0.4 (item-21 predecode). `g6lc_core` +14.7 is a
  translate_off hang-dump instrumentation cone (hierarchical CSR taps
  added under `//pragma translate_off` for H5 blame locality; the
  analyzer charges them into the module row) — not an RTL regression.
- Stitched (cross-module) top-10, for the record: iq→iq_arb 134.2,
  dispatch→iq 124.7, iq→iq_legal 122.5, iq→iq_bank 121.1,
  iq→iq_payload 117.9, iq→iq_xbar 105.2, hpdcache_ctrl→pe 92.6,
  mmu→shared_tlb 84.9, lsq→lsq_event 76.1, dispatch→lsq 75.0 FO4 —
  all port-bridge bookkeeping cones, not structural clock-setters.
- Six-module `--modules` run (v2 map, `--stages`), worst in→reg /
  reg→reg / reg→out per module: g6lc_lsq_reduce 38.2 (in-stage R);
  alu 24.6/27.9/24.6 (A3); stb_fwd 25.6 (F1); wt_dcache_wbuffer
  21.9/22.0/22.0 (:1826); ex_stage 16.4 (rr :852); multiplier 16.2
  (S2); store_buffer 15.4 (rr :412); g6lc_lsq 11.5 rr + 65.0 in→out.
  JSON: boards/hyp8-core/analyze-six-r4.json.

### Item census (file:line, rank, before→after, mutant, counter)

G1 multiplier — all landed, mutants `G6LC_MUT_T2_MULT_{CLMUL,CORR,CSEL}`,
counters `multiplier clmul|corr|csel`, board multiplier 16.2 (S2):
- R1 new file `core/mult_clmul.sv` (tier-R header; slice-accumulate
  CLMUL S2–S7, publishes at S7 with vld/tid/op lockstep); instantiated
  in `multiplier.sv:624`; added to `core/Flist.g6lc_hyp8:185` and
  `verif/regress/remote/hyp8/Flist.hyp8_sim:200`.
- R1' two CSA correction rows in S2 (`multiplier.sv:225-315`),
  pre-S1 CPA removed.
- R1" S7 carry-select high half, candidates formed in S6
  (`multiplier.sv:539-620`).

G2 alu/ex_stage:
- R3 shift_hi group to A2 with A2→A3 registered result — landed;
  alu worst 27.9 in-stage A3 (unchanged limiter).
- R4 one-hot AND-OR on `one_cycle_select`/`rs{1,2}_forwarding` —
  ex_stage.sv:489-518; mutant `G6LC_MUT_T2_EXSTAGE_OCDATA`;
  counter `ex_stage ocdata`.
- Item 20 `WbCaptureStages` — rank-1, Hyp8=1: registered FLU
  publication record in ex_stage.sv:899-943; mutant
  `G6LC_MUT_T2_WBCAP`; counter `ex_stage wbcapture`; +1 FLU distance
  derived inside `g6lc_ooo_pkg::ooo_flu_cycles`; hyp_cfg_ok legality
  added (`WbCaptureStages==0 || WbReserve`).

G3 LSQ:
- R5 `pick_dist` narrowed to IDW+1 with all-ones sentinel —
  g6lc_lsq_reduce.sv:86/164, g6lc_lsq.sv:1176/1235; mutant
  `G6LC_MUT_T2_LSQ_PICKDIST`; counters `g6lc_lsq_reduce pickdist`,
  `g6lc_lsq pvpick`. lsq_reduce is now the #3 module row (38.2
  in-stage R) — below the limiter; noted as the next candidate.
- Item 12: already realized (balanced pairwise `evcount` from the
  earlier T1 batch) — classified, no change.
- V-window re-time: **not landed** — the conditional in the plan
  (fold the gather into the registered verdict stage without changing
  `ld_checked`) was not met; `g6lc_lsq_verdict` untouched.

G4 memory:
- R7a **countercase** (load_unit.sv:651): the non-idempotent verdict
  select on `load_pa_now_v` fed the FSM decode back into its own
  control cone — 57.1/57.9 FO4 vs retained 36.1; reverted.
- R7b **not landed**: the registered publish record cannot replace the
  combinational pick without a protocol answer for which cycle the
  shared PPN port belongs to a held key; deferred with R7a (in-file
  note).
- R8 **not landed**: `stb_insert`/`stb_fwd`/`store_buffer` already
  carry the A141 `spec_older` pairwise matrix + per-byte
  youngest-writer form from earlier work (store_buffer.sv:854) —
  classified as already realized; rank popcounts already absent.
- R6 **classified** (store_unit.sv:326): the 42.3 reg→out arm launches
  from the DTLB PPN mux inside the MMU; `LsuAguStages==2` already
  registers the AGU result, so a second register would add a cycle
  without removing the DTLB leg. No change.

G5 wbuffer:
- R2 **not landed**: `wt_dcache_fixupq.sv` not created; the fixup/
  coalesce logic remains inside `wt_dcache_wbuffer.sv`
  (fixup_push/alloc/tail ~:701-870). Deferred — and now gated by the
  r41 `tx_single` witness failure, which must be root-caused before
  further wbuffer surgery.

G6 issue/IQ/dispatch:
- R9 `cnt_zero_q` predecode at the countdown edge — g6lc_iq_bank.sv
  :190/366/1515; mutant `G6LC_MUT_T2_IQ_CNTZ`; counter
  `g6lc_iq_bank cntz`. iq_bank 32.3 in-stage SEL.
- Item 17 **countercase** (issue_read_operands.sv:763): independent
  per-port hold vectors — the broader limiter stayed 46.4 and the
  rewrite added structural complexity; reverted.
- Item 21 dispatch legality/steer predecode from `grp_*_q` —
  g6lc_ooo_dispatch.sv:290/304/396/625; mutant
  `G6LC_MUT_T2_DISP_GRPGO`; counter `g6lc_ooo_dispatch grpgo`;
  −0.4 FO4 on the module row.
- Item 8 **classified**: `g6lc_iq_arb` already registers bank
  candidates in `cand_q` at T+1 (g6lc_iq_arb.sv:8) — the SEL→ARB
  candidate register the item asked to restore is already present; no
  `IqCandStage` field added, no `ooo_flu_cycles` change needed.

G7 translation/frontend/retire:
- Item 4 **countercase** (g6lc_ptw.sv:563): the registered post-
  `data_rvalid` decode bundle billed the whole decode cone even though
  consumed a stage later — 37.4 → 63.8/64.5 FO4; reverted incl. the
  temporary `PtwDecodeStage` field.
- Item 19 landed — g6lc_shared_tlb.sv:186/459: live-arm flush-select
  decode staged on registered `walk_own_q`/`walk_blk_q`; mutant
  `G6LC_MUT_T2_STLB_FLUSHSEL`; counter `g6lc_shared_tlb flushsel`;
  svt-pipe annotation `cycle stlb q=walk_own_q,walk_blk_q
  d=flush_state_d steps=1`. Board 39.6 (:841).
- Item 16 **classified** (wt_dcache_ctrl.sv:345): already realized by
  the `DcacheHitExtra==2` T1/T2 staging; no new structure.
- Item 1: retained the explicit `hi_last` prefix OR (41.6 FO4 —
  the board limiter). Item 1(c) **countercase**
  (rename_resolve.sv:120): predecoded `rd` one-hot indexed select
  measured 41.6 → 49.5; reverted.
- Item 23 landed where equivalent: `g6lc_rob` parallel ahit/whit pick
  (:184-349, counter `g6lc_rob pick`, −1.9), `csr_buffer` one-hot tid
  alloc (:156-179, `csr_buffer alloc`), `lsu_bypass` parallel mem_n
  (:183-332, `lsu_bypass memn`), plus `g6lc_tlb plru`,
  `sb_lifecycle col`, `g6lc_rename_recover pubmarks`,
  `g6lc_fe_override ras_upd`, `g6lc_iq_legal leg` arm rewrites with
  their `[equiv]` counters. **Controller arm countercase**
  (controller.sv:480): the A22 parallel-arm rewrite measured
  25.1 → 67.2 FO4; reverted.
- Items 13/9/11 untouched (landed earlier).

### Lint census (remote, run_hyp8_integration lint phase only)

| tag | scalar %Error | smt2 %Error | smt2 WIDTHEXPAND/WIDTHTRUNC/LATCH |
|---|---|---|---|
| hyp8-integration-r42t-g1 | 0 | 0 | 354/97/3 |
| hyp8-integration-r42t-g2 | 0 | 0 | 354/97/3 |
| hyp8-integration-r42t-g3 | 0 | 0 | 355/97/3 (+1 WIDTHEXPAND, site not pinned) |
| hyp8-integration-r42t-g7 | — | — | run dir created 12:52, output empty — sync produced no payload; superseded by r42t-final2 |
| hyp8-integration-r42t-final | 84 | — | **lint_failed**: `g6lc_rob.sv:362-369` — the item-23 equivalence block indexed the `gen_slot` generate scope with a procedural loop variable (`gen_slot[s]`); generate scopes only take constant indices. Fix: check moved inside `gen_slot` (genvar `s`), per-slot `[equiv] g6lc_rob pick[<s>]` counters |
| hyp8-integration-r42t-final2 | 0 | 0 | 354/97/3 — **build_complete**, model sha256 `d0c51e28c69360ee18b52723979855af1e45abf1e4cc732a0bcdfaf07479b544`, 694 staged files |

r42t-final2 scalar census: 343 WIDTHEXPAND, 123 LITENDIAN,
87 WIDTHTRUNC, 10 CMPCONST, 9 UNSIGNED, 9 CASEINCOMPLETE, 5 STMTDLY,
4 IMPLICITSTATIC, 3 WIDTHCONCAT, 3 LATCH, 1 SYMRSVDWORD, 1 COMBDLY —
identical to the r41 baseline. The g3 +1 WIDTHEXPAND is gone in the
final tree (removed with the reverted items). runtimeDepChecked=true
(204 dep files), pinned Verilator 5.008.

LATCH=3 everywhere is the tier-U `axi_riscv_amos_alu.sv` triplet.
**Transport note:** the `r42t-final2` closure was delivered by cloning
the already-synced `r42t-final` remote closure (`cp -a`) and pushing
only `g6lc_rob.sv` + the regenerated `manifest.json` through
`Remote.push` (the proxy's 12 MB tar-over-ssh closure upload kept
dying on ControlMaster resets); the remote runner was then launched
detached with `TH_DATA_DIR`/`TH_OUT_DIR`. Manifest sha-verification of
all 694 staged files passed inside the run.

### Deferred / next tier (explicit)

- r42-T leaves, smokes, witnesses: **deferred by the user** — none run;
  the equivalence evidence is the in-tree `[equiv]` counters (24
  counters total) and the `G6LC_MUT_T2_*` review mutants.
- Rename 1′ RR-a/RR-b with `prev2` and the Batch E wbuffer redesign:
  deliberately not attempted (ownership change without a witness).
- **Gating item:** the r41 witness failure (addendum above) — an
  in-flight-TX hole remains in `wt_dcache_wbuffer` under drop bursts;
  fix + r41v2 closure + rewitness required before the wbuffer repair
  is verified, and before G5 R2 should proceed.

---

## r43-T (tangent) — top-down FO4 reduction, lint-only gate

User-directed tangent off the r41v2 diagnostic: work the r4 board's
>=20-FO4 list top-down, rank-1 changes allowed even where they add a
cycle, validation deferred to lint only. **No leaves, no smokes, no
witnesses were run in this pass.** Working tree: r43-T.

### Board result (same argv as r4: --all-modules --stages, v2 param map,
### --target-mhz 5000 --fo4-ps 20 --budget-margin 0.2)

`boards/hyp8-core/analyze-ghz-r5.json` + `clock-r5-vs-r4.txt`:
**structural clock 0.96 -> 1.03 GHz (41.6 -> 38.6 FO4)**; new clock-setter
is `g6lc_shared_tlb` (reg-to-reg :791, the SFENCE.VMA flush-match decode).

Landed:

| item | module | cone | r4 -> r5 | rank / mechanism |
|------|--------|------|----------|------------------|
| T1 | g6lc_rename_resolve | in-stage RR | **41.6 -> 3.5** | (a) position-ordered balanced late-select `(|h[5:3]) ? chain(5,4,3) : chain(2,1,0,arch)` replacing the `hi_last` one-hot + masked-OR gather on every gathered field; (b) `HypCfg.RenameResolveStages` (Hyp8=2): RR-a registers per-lane match vectors `h_s1_q/h_s2_q/h_s3_q` + `rra_q` lane records, RR-b does late-select + rs_rdy clear; third producer record `prev2_i` added through g6lc_rename/g6lc_rename_publish, cleared in g6lc_rename_recover, dispatch `grp_pend_q` serialization extended by one. Module is off the top-45 entirely |
| T2 | g6lc_ptw | Svnapot rr | 37.4 -> 37.5 (+0.1) | `HypCfg.PtwDecodeStage` (Hyp8=1): new `PTE_DECODE` state — raw `data_rdata` -> `pte_q` at rvalid, registered decode bundle next cycle, every PTE_LOOKUP arm reads bundle bits only; +1 cycle/level on a TLB miss (walk latency). Kept: module-neutral but removes the raw-PTE cone from the FSM and the locus moved from :604 to :763 |
| T3 | g6lc_lsq_reduce | R | 38.2 -> 29.9 (-8.3) | `HypCfg.LsqReduceStages` (Hyp8=2): R1 registers `{pick_valid,pick_slot,pick_dist,wait_d,dwait_ids}`, R2 does the one-hot decode + id/pay gathers + publishes `win_*`; R->V distance derived from the field |
| T5 | g6lc_shared_tlb | rr | 39.6 -> 38.6 (-1.0) | VVMA lookup-path predicate work kept; the remaining :791 limiter is the SFENCE 4-arm flush decode — same exclusive-arm class as the T4/T6/T9 countercases, no safe flat rewrite |
| T7 | g6lc_iq_arb | ARB bundle | 34.8 -> 33.5 (-1.3) | `cand_cancl_q` captured at candidate capture (live mask remains authoritative final AND) + `HypCfg.IqArbStages` (Hyp8=2): ARB1 tournament -> registered `win_s_q`, ARB2 take/presentation; owned-TID exclusion and `!pres_q[p].v` stay live. Earlier real-path measure ~48.8 -> 35.6 |

Reverted countercases (old form restored, countercase note in-file):

| item | module | result | why reverted |
|------|--------|--------|--------------|
| T4 | wt_dcache_mem :526 | 33.3 -> 35.0 | flat AND-OR per-byte merge replaced the priority tree — charged all cones, lost the exclusive-case accounting (same class as T6/T9) |
| T6 | g6lc_iq_bank SEL | 32.3 -> 38.0 | registered `legal_q` at the bank boundary worsened SEL |
| T8 | load_unit | 37.5 -> 37.5 | `LuTransStage` staged MMU response relocated the cone to ~36.15 but the existing FSM state path (load_unit.sv:1162) stayed the limiter — full revert including the HypCfg field |
| T9 | alu A3 | 27.9 -> 73.8 | one-hot `a3_sel_q` arm-group predecode + flat AND-OR destroyed the 35-arm unique-case's exclusive-arm accounting — worst countercase of the pass |

Classified without a change (cone inspected, no safe rewrite):

- `g6lc_rename_recover` (31.8): true worst is :451 (39.3, the publish
  per-port dynamic-index write into the architectural map — map-RAM
  write-port redesign, a backend seam, out of tangent scope); the :589
  board row is a 25-LHS bundle makespan.
- `g6lc_loop_buffer` (31.8): :236 `hit_live` 64-bit compare is
  live-input — feeds `consume_o`/`hit_q` next-state; staging changes
  the output contract.
- `sb_lifecycle` (28.9): :362 flagged "P10 handshake lock, InsertReg
  refuse" by the analyzer — port-indexed alloc gather, no deeper cone.
- `g6lc_fe_override` (30.2): :421 is a 13-LHS bundle makespan.
- `g6lc_tlb` (36.4): countercase already recorded (T5).
- Skipped per plan: tier-U fpnew_*/aes, wt_axi_adapter (classified),
  wt_dcache_wbuffer (r41v2 owns), controller A22 (prior countercase),
  g6lc_core (translate_off instrumentation taps), nonexistent
  wt_dcache_fixupq.sv.
- `g6lc_shared_tlb` :791 (new clock-setter): 4-arm SFENCE exclusive
  decode — the T4/T6/T9 countercase class; a staged-flush rank-1 is
  the only remaining lever and is deferred (flush semantics change).

New HypCfg fields this pass: `RenameResolveStages` (HypDefault 1,
Hyp8 2), `IqArbStages` (1|2, Hyp8 2). (`PtwDecodeStage`,
`LsqReduceStages` were added earlier in the pass; `LuTransStage`
added-then-reverted with T8; `WbCaptureStages` stays 0.)

Lint gate (the only validation): remote full-top lint of the r43-T
closure (`hyp8-r43t-closure`, 694 staged files + manifest sha-verify)
via `run_hyp8_lint_only.py` — tag `r43t-lint3`,
**scalar rc=0, smt2 rc=0; 0 %Error both profiles**; census scalar
344 WIDTHEXPAND / 87 WIDTHTRUNC / 3 WIDTHCONCAT, smt2 355/97/3 —
+1 WIDTHEXPAND per profile vs the r41 baseline (new r42/r43 code);
the `prev2_sh` packed->unpacked array assignment flagged as
`SEL unexpected` (g6lc_rename_resolve.sv:413) was fixed element-wise
before the passing run.

### r41xdiag collection (collateral to the tangent)

The already-running windowed diagnostic `hyp8-osbi-scalar-r41xdiag`
was collected after it finished on its own (not relaunched): same
signature as r22/r22x — `g6lc_tx_single` abort at cycle 289,632
(remote run dir + pulled `remote-runs/hyp8-osbi-scalar-r41xdiag/`).
Trace evidence for the r41v2 continuation: entry 0's byte 7
(be=80, pa 0x800403f7, wtag 0x1000807e) was sent **twice** —
`wt_tx id=1` @289618 and `wt_tx id=2` @289619 — while the recapture
mask should have made the second pick impossible. Global send/evict
tally is otherwise balanced (6406 sends / 6404 evicts, the 2 leftovers
being the unreturned tail); the alloc stream shows `ptr=1 merge=0
hit=01` @289616 opening a second live slot for the same word while
entry 0 still had an in-flight byte — consistent with prediction (a):
a held/stale drain record offered again after a drop/realloc window,
the `drn_hit` mask keyed on `dr_ptr` protecting the wrong slot. The
pre-abort burst of `L1 obligation dropped` events on entries 0/1 is
the realloc churn that primes the stale record. Adjacent confirmed
static hole (unchanged, r41v2 owns): `wbuffer_d[gi].txblock[k]` has
no `wr_gi` clear — a realloc'd slot inherits stale txblock/valid/dirty
state.

## r41v2 — write-buffer drain repair round 2 (LockIn root + return-view + W3-hit bypass)

### Root mechanism (r41xdiag trace, cycle-pinned)

Entry 0's byte 7 (be=80, pa 0x800403f7, wtag 0x1000807e) drained once
correctly and then again one cycle later: `wt_tx id=1` @289618 and
`wt_tx id=2` @289619 — the second send carried no `wt_ssent` (the miss
unit never sent it; the write-buffer committed it internally) and
`g6lc_tx_single` fired at 289632 (`txblock=80 tx_cnt=1`).

The drain record (`dr_ptr`/`dr_vld`/`drain_hold_q`) is NOT the stale
party: `i_dirty_rr` was instantiated with `.LockIn(1'b1)`, and in the
vendor `rr_arb_tree`, LockIn freezes `req_q` while a request waits for
its grant (`lock_d = req_o & ~gnt_i`; while `lock_q`, `req_d = req_q`
ignores live `req_i`). The W-buffer already holds the offer stable in
`drain_hold_q`/`dr_*`, so the arbiter lock was redundant — and at the
grant edge the `drn_hit` mask removed the just-granted entry from the
LIVE request vector while the arbiter kept replaying the FROZEN mask:
the D1 capture after the ack re-picked entry 0 with its txblock/tx_cnt
update one edge late. Two sends, one byte, two tx ids — the memory-
reorder hazard the single-TX ledger exists to forbid.

The W2/W3 same-word-alias hypothesis from the earlier report is
DISPROVEN for this abort: the `wt_alloc ptr=1 merge=0` @289616 carried
store operand base 0x800403f9 -> word 0x800403f8, while entry 0 held
word 0x800403f0 — a legitimate different-word allocation. (The earlier
read of the alloc as a same-word second slot was wrong; `hit=%h` in the
wt_alloc line prints the OLD occupant's resident hit_oh, not the
request's hit vector.)

### Fixes (wt_dcache_wbuffer.sv only; one-file churn)

- **F-d (root):** `i_dirty_rr` LockIn 1'b1 -> 1'b0 (`WBUF_DRAIN_LOCKIN`
  localparam); `drain_hold_q`/`dr_*` is the sole offer-stability
  mechanism. Review mutant `G6LC_MUT_WBUF_DRAIN_LOCKIN` restores the
  frozen pick. New Verilator-active `g6lc_drn_norepick` (drn_hit_q
  history): a grant whose pick was just granted last cycle is a
  violation.
- **F-a:** `rtrn_wb` reads the LIVE entry through the registered
  pointer (`wbuffer_q[rtrn_snap_ptr_q]`); `rtrn_snap_ptr_q`/
  `rtrn_snap_tx_q` retained. `ack_be`, `leg_l1_d`, `leg_fire_d`,
  `rtrn_checked_mid`, `vmid_clr`, byte release now observe one state —
  the frozen `rtrn_snap_wb_q` view let snapshot-dirty force `ack_be=0`
  while the live release freed the bytes (`l1_obligation dropped`,
  nonzero in h33-r41x and churning before both aborts). The obligation
  drop is now a hard `g6lc_l1_obl` assertion (counter kept;
  `G6LC_MUT_WBUF_SNAP_VIEW` keeps counter-only mode). Timing cost: the
  8:1 indexed wbuffer_q read re-enters the return-leg cone.
- **F-b:** a fresh non-merge alloc fully initializes byte state —
  valid/dirty from `wrv_be`, txblock=0, checked=0, hit_oh=0; `w3_merge_q`
  carries merge-vs-fresh through the W3 descriptor (`wrv_merge`).
  `g6lc_alloc_clean` names any fresh alloc landing on a slot with
  tx_cnt>0 or txblock!=0.
- **F-c (structural, disproven-root but requested):** W2 coalesce
  decision includes the W3-pending same-tag write (`w1_w3hit_q`, merge
  target `w3_ptr_q`); mutant `G6LC_MUT_WBUF_W3_HIT_BYPASS` drops it.
  NOTE on reachability: under the W1 write-once suppression protocol a
  valid W1 capture can never coincide with a pending W3 write — a W3
  occupant implies an `e_accept` in the previous cycle, which suppresses
  that capture and forces a recapture after the write lands. The bypass
  is defense-in-depth (vacuous today); the real guards are the new
  Verilator-active invariants: `g6lc_hit_hot1_v` ($onehot0 of
  wbuffer_hit_oh, duplicated out of `ifndef VERILATOR`) and
  `g6lc_word_uniq` (no two live slots share a wtag, pairwise).

### Closures (sha-pinned, exactly-one-file churn)

- `hyp8-integration-r41v2-closure` (693 files, parent r41):
  wt_dcache_wbuffer.sv `bb38a121` -> `95f4be4e`; no other churn.
- `hyp8-integration-r41v2x-closure` (693 files, parent r41x):
  wt_dcache_wbuffer.sv `bb38a121` -> `95f4be4e`; no other churn
  (the wbuffer file is identical across the two lines; the x-line
  delta lives in issue_read_operands).

### Module timing (--modules wt_dcache_wbuffer, v2 param map)

22.0 -> 24.9 FO4 structural clock for the module; the new limiter is
the W2->W2S crossing (:2004 rdy/e_accept into the W3 descriptor regs),
+2.9 FO4 consistent with the F-a live indexed read re-entering the
return-leg cone. Not a top-45 clock-setter (board clock remains
shared_tlb :791 at 38.6). JSON: boards/hyp8-core/analyze-wbuf-r41v2.json.

### Remote evidence

- Integration lint r41v2 (run_hyp8_lint_only.py, tag
  hyp8-integration-r41v2): **scalar rc=0 (343/87/3), smt2 rc=0
  (354/97/3), 0 %Error both profiles** — census identical to the r41
  baseline. r41v2x lint: **scalar rc=0, smt2 rc=0, 0 %Error**.
- Integration lint+build r41v2/r41v2x (run_hyp8_integration.py):
  BUILD OK both lines. Model sha256: r41v2
  `bb2309c4c9cee2345af0713156e92b6a3d73423049f7f3f7b4f60fcfe16bea61`,
  r41v2x `d5982add800ee061045b90854d94ae5f8f4db1bd8f37999e35f918f16ec02336`.
- Smokes (run_r41v2_smokes.py): **r41v2 line h34=682 / h33=969 /
  branch-cancel=473** (bit-identical to r41 — the repair did not move
  any of the three paths); **r41v2x line h34=682 / h33=899 /
  branch-cancel=475** — h34x first record, x-line h33 holds at 899
  (the +10 vs the pre-F-a 889 expectation is the F-a live-view change
  attributed earlier; tx_single checked=10 viol=0).
- Witnesses hyp8-osbi-scalar-r23 / -r23x (20M, +stall_census
  +hang_dump=2000 +equiv_report +rvfi_cycle_stamp,
  +tohost_addr=0x80041730, fw_payload sha-pinned): **both FAILED at
  ~24.6k cycles** — r23 at cycle 24,594, r23x at 24,596, identical
  signature: `wt_dcache_wbuffer.sv:2554 g6lc_l1_obl`:
  "[l1 dcache wbuffer] checked+resident entry 0 wtag=00000010008dec
  freed by drop without L1 write" — preceded by sustained
  `l1_obligation dropped` churn on entry 0; boot trace parked at
  npc=0x10040 (bootrom park loop). The F-a live-view repair did not
  eliminate the obligation drop; the hard g6lc_l1_obl assertion fired
  instead of a silent violation, which is the intended fail-loud
  behaviour — the surviving mechanism is a third drop path the
  snapshot view did not cover (investigation open; the
  r41xdiag/r41v2 evidence names the drop+realloc window on the same
  slot as the prime suspect). OpenSBI retirement is NOT restored on
  this line. Also note: the frozen r41v2/r41v2x models predate r43-T
  and still carry the latent hi_last lowest-set (oldest-wins)
  direction bug found in the rename_resolve equivalence review —
  see the hyp8-l3-r1 section.

## hyp8-l3-r1 — OpenSBI on the ooocoh L2/L3 stack (first simulation of the r43-T tree)

User request: run OpenSBI on the single-core no-hub ooocoh L2/L3
cache stack (`g6lc64_smt2_l3` field set) on the CURRENT hyp8 tree —
r41v2 functional + r42-T/r43-T structural. This run is also the first
simulation of that tree (the tangent gate was lint-only). Reference
analogue `ooocoh-p2-osbi-smt2l3-L0-r2` (T8c, AGENTS-ooo-plan:1717):
stock OpenSBI retires at 14.3M cycles on the reference core under a
20M cap. The two-core hub/int2 variant was NOT attempted — hyp8 is
single-hart.

### Config seam + copied fields

`core/include/g6lc64_hyp8_config_pkg.sv`: `ifdef G6LC_HYP8_L3` next to
`G6LC_HYP8_SMT2` selects the L2/L3/WtAxiAllocEn field set copied
verbatim from `core/include/g6lc64_smt2_l3_config_pkg.sv` —
L2En=1, L2LineWidth=512, L2MshrDepth=2, L3En=1, L3LineWidth=512,
L3MshrDepth=4, WtAxiAllocEn=1, L3InclusiveEn=0, L2TagSramEn=1,
L2WriteUpdateEn=1, L2PrefetchEn=0, and every L2*/L3* set/way/bank
field; else-branch keeps the existing zeros, so the scalar and SMT2
profiles are identity. The hyp APU tree already instantiates
`g6lc_l2_top`/`g6lc_l3_top` under `L2En`/`L3En` (Flist.hyp8_apu
:397/:401) — no production-core port was needed. `wt_axi_adapter`
`WtAxiAllocEn` handling mirrored (T8a finding: without allocate
attributes the L2 is a bypass). Harness: `g6lc64_hyp8_l3` added to
`verif/regress/remote/hyp8/hyp8-build-harness.sh`
(`-DG6LC_HYP8_L3`, harts=1, same CFLAGS as g6lc64_hyp8). DTS:
`verif/regress/remote/hyp8/g6lc-hyp8-l3.dts` from g6lc-hyp8.dts +
l2-cache/l3-cache nodes chained `next-level-cache` from the cpu node
exactly as `ariane-smt2-l3.dts`, geometry matching the copied fields.

### Firmware (stock OpenSBI, no edits — P1)

`build_boot_firmware.py`, OpenSBI pin `455de672`:
- fw_payload.elf sha256
  `01ae648d85a77acae08d106708a3ceba115f092747c5a7d284e1ca831c3d4f5f`
- g6lc-hyp8-l3-linux.dtb sha256
  `d60d477d398d4450d69973f8306c1948fa3b44cd106aab05f674eacf2e63c54c`
- tohost `0x80041730`

### Closure + lint + build (r6 — final)

`hyp8-l3-r6-closure`: 822 files, manifest sha256
`6e39a3b104652fd00593b6a0da2a46178a95bb1246e9ba29a371a42890c896dc`
— the r43-T tree + the config seam + harness/DTS additions + the
assertion-reference corrections below. Integration
`hyp8-l3-integration-r6` (sha-verified source, pinned Verilator
5.008-causal + private runtime dfbc2c4a…, riscv gcc 14.2.0):

- lint scalar rc=0 (343 EXPAND/87 TRUNC/3 CONCAT, 0 %Error)
- lint smt2   rc=0 (354/97/3, 0 %Error)
- lint l3     rc=0 (354/90/5, 0 %Error)
- build g6lc64_hyp8_l3 rc=0, model sha256
  `15539b40acc9abf28d5c44a880bbb5d24a0ab61cd987121026df7c16988c4946`

### First-simulation assertion exposure (r1→r6 debugging record)

First simulation of the r43-T assertion set surfaced four
reference-side bugs — all translate_off, all fixed by aligning the
reference to the staged RTL, none touching functional logic:

1. r1: all three smokes stopped at `g6lc_iq_arb.sv:923`
   `g6lc_t3_iq_arb_moh` (staged m_oh drift) — first-simulation
   exposure of the staged-arbiter reference.
2. r3: h34 passed (813); h33 `g6lc_t2_pickdist_eq`
   (g6lc_lsq_reduce.sv:344) — the R5-era reference compared
   `pick_valid[1]`/`pick_dist[1]`/`pick_slot[1]`, undriven once the
   tree splits at FBASE under LsqReduceStages>=2; replaced with the
   root_* vs one-edge-delayed reference tree compare. branch-cancel
   `g6lc_t2_mult_csel_eq2` (multiplier.sv:737) — `prod_q` registers
   at S7 while the product reference carried only a single-edge
   delay; added the second delayed reference stage.
3. r4: h34 813 / bc 516 pass; h33 `g6lc_t3_lsqr2_eq`
   (g6lc_lsq_reduce.sv:432) — field dump (r5) showed
   v=1/1 leaf=001/001 id=11/11 **dist=01/00** pay/wait/dwait equal:
   same winning slot, different dist. Root cause: a local register
   named `ref_dist` inside `gen_lsq_r2_eq` shadowed the module-level
   `ref_dist` tournament array, so `ref_dist <= ref_dist[1]` sampled
   the register's own bit 1 — stuck at 0 — instead of the reference
   root. Renamed to `ref_d`/`ref2_d`; h34/bc had passed only because
   their winning picks carried dist=0. NOT an RTL defect.
4. r43-T review also corrected a semantic bug in the
   `g6lc_rename_resolve` equivalence gather: `hi_last` computed the
   LOWEST set bit (oldest producer wins) while the documented
   contract and the live late-select are newest-wins (highest
   index). The translate_off reference was corrected to a true
   highest-set helper; the frozen r41v2/r41v2x models still carry
   the original gather — a latent functional bug on that line.

### Smokes on the L3 model (r6, all PASS)

`+time_out=400000 +max-cycles=400000 +debug_disable +quiet_axi
+equiv_report +tohost_addr=0x80001000`:

- hyp8-h34-l3r6: **real tohost, 813 cycles**, 111 equiv lines,
  0 errors; elf `02dec56a…`
- hyp8-h33-l3r6: **real tohost, 1141 cycles**, 111 equiv lines,
  0 errors; elf `69bb52f1…`
- hyp8-branch-cancel-l3r6: **real tohost, 516 cycles**, 111 equiv
  lines, 0 errors; elf `cc8b8ccc…`
- model sha `15539b40…` pin-verified per run.

### Witness launch (detached, not awaited)

`hyp8-osbi-l3-r1` launched 2026-10-24 ~19:33 UTC on the r6 model
(sha-pinned `15539b40…`), fw_payload sha-pinned `01ae648d…`:

```
Variane_testharness +time_out=30000000 +max-cycles=30000000
  +debug_disable +quiet_axi +tohost_addr=0x80041730 +stall_census
  +hang_dump=2000 +equiv_report +rvfi_cycle_stamp fw_payload.elf
```

Predictions (written before launch): banner later than r20x's 4.76M
cycles — the L2/L3 miss latency adds to every boot fetch — and after
the reference's 14.3M-cycle ooocoh-p2 retirement as a plausible upper
marker under the 30M cap; `l3_hit` census expected ≈0 per T8c (the
L3 sees almost no hits at this footprint). The r41v2 wbuffer
assertion set rides in this build — `g6lc_l1_obl`/`g6lc_tx_single`
will fail loud if the surviving drop mechanism recurs on the L2/L3
path. Verdict: **aborted at cycle 483,343** — not a boot. The model
hit `g6lc_spec_entry_live` at `core/store_buffer.sv:1292`:
"[Speculative Queue] entry 0 holds tid 28 whose scoreboard slot is
not live", then `$stop`. No UART bytes, no banner, no tohost
verdict, no stall census, no equivalence report (pulled artifacts:
`remote-runs/hyp8-osbi-l3-r1/` — run-hyp8.log, results.json,
summary.{txt,json}). Preceded by 6,799 `l1_obligation ... freed by
drop` records; boot trace parked around npc=0x10040/0x10000 (the
bootrom wait loop — same signature as the r23/r23x aborts). The
store-buffer scoreboard liveness failure is distinct from the r23
wbuffer leg and remains open — see the r41v2 section for the
state of that investigation.

## Segment card — rename gather direction (hi_last oldest vs newest)

Question (from lead review of hyp8-l3-r1 item 4): the shipped
`hi_last` in `g6lc_rename_resolve` isolates the LOWEST set producer
bit (oldest-wins), while the module contract ("priority mux
newest-wins" per g6lc_rename.md) requires the HIGHEST. Was the
r43-T reference correction (hi_last → hi_first in the eqf gather)
right, and does the shipped line carry a real functional bug?

Discriminator: `verif/tests/custom/hyp8_raw_window.S` — eight
variants each building a two/three-writer window on one rd with a
consumer whose correct input is the newest writer's value:
V0 [li a5,5; li a5,7; mv a0,a5], V1 same pattern shifted one slot,
V2 independent filler between second writer and consumer,
V3 dependent WAW pair (li;addi), V4 three-writer WAW, V5 FP pair
(fmv.w.x f5 x2; fmv.x.w), V6 single-writer control, V7 spaced pair
(published-map control). Observed consumer values packed as a
32-bit signature → tohost; all-newest expected 0x7a977739.

Runs (pinned models, elf sha `d1b9799a…`/`83aca27f…`, tohost
0x80001000):
- **hyp8-integration-r41v2** (frozen line, hi_last = oldest-wins
  live): SUCCESS at 649 cycles — all variants observed newest.
- **hyp8-l3-integration-r6** (r43-T late-select = newest-wins
  live): SUCCESS at 775 cycles, all variants observed newest
  (rvfi tail: `sw a0 → mem 0x80001000 = 1`, s11=0x7a977739).
  One earlier invocation on this same model/elf flaked to a
  budget-out at 400k with a cause=2 trap at 0x8000005e and an
  odd retire stream (handler fetch + resumed stream + a retired
  tohost store that the tracer did not count); 3/3 subsequent
  runs passed cleanly at 775 cycles. Recorded as a
  nondeterministic L3-path anomaly (fetch or store drain), not a
  rename-semantics divergence — see open items.

Multi-hot census (diagnostic closures, translate_off counters
inside gen_lane — no RTL change):
- `hyp8-r41v2-mhdiag` (model `efa26743…`, scalar build): h34
  hits p1 f0=15 f2=7; h33 hits p1 f0=26 f1=10 f2=26; all other
  lanes/fields zero. **multi=0 diverge=0 everywhere** — the
  producer vectors are at most single-hot on the frozen pipeline.
  hyp8-rawwin-mhdiag (the discriminator itself on this model):
  p1 f0=9 f1=4 f2=7, **multi=0 diverge=0** — the directed
  two-writer patterns also never reach a multi-hot window.
- `hyp8-l3-mhdiag` (model `421d7870…`, L3 build, RRS=2 live):
  h34 hits p1 f0=15 f2=7; h33 hits p1 f0=22 f1=11 f2=22;
  **multi=0 diverge=0 everywhere** — the deeper r43-T window does
  not hold two producers of one rd on these tests either.

Why the frozen line is correct anyway (structural): on the
RRS=1 pipe, r1_v_q is a single-cycle pulse, s2 drains every
occupied cycle, and prev1 has a one-cycle lifetime. Dispatch's
grp_pend_q serializes group captures to ≥4 edges apart (pend set
at capture, cleared at ren_pub — the cycle after publish). So at
any resolve cycle, prev0/prev1 records are always dead; the only
live producer a lane can see is a same-group older lane — at most
one per field (lane 0 for lane 1). hi_last vs hi_first pick the
SAME bit on a single-hot vector: **the direction is structurally
unobservable on the shipped 1-stage pipeline.** The "latent
direction bug" in the frozen models is real in the code but
unreachable — the OpenSBI boots on that line neither exercised
nor refuted it.

Conclusion: newest-wins (hi_first / the late-select) is the
correct contract direction and is what the r43-T live path
implements; the frozen line's oldest-wins gather is a latent,
structurally unreachable divergence — the shipped pipeline can
never present two live producers to one field, so the direction
bit is unobservable (measured: 0 multi-hot across h34+h33+rawwin
on BOTH lines). The OpenSBI boots on the frozen line neither
exercised nor refuted it, and the r43-T newest-wins path is
observationally identical on every variant. The earlier r2
latesel fire (pick=47 ref=20 at cycle ~300) is therefore best
explained as the RR-a/RR-b producer-record boundary shifting a
single producer between stages — the bookkeeping hole the
prev2_sh/cover_eq fix addressed — not a true two-producer
multi-hot; with multi=0 measured on the verdict vectors, no
semantic correction beyond that bookkeeping fix was needed. The
hi_first reference stands as the contract-correct checker; the
"latent functional bug" wording in item 4 is narrowed to a latent,
unreachable code divergence.

Open items:
- The single flaky r6 rawwin run (cause=2 trap loop at
  0x8000005e on an `or`; retired sw tohost=1 not counted by the
  tracer) — same family as the store-path anomalies under
  investigation on the L3 line; not reproduced in 3 reruns.
- The census only covers h34/h33/rawwin; multi-hot could
  conceivably arise in longer workloads — but the grp_pend
  serialization bound (≥4-edge captures vs 1-cycle record
  lifetime) says it is structurally impossible on the frozen
  line, and the r6 verdict window shows the same single-hot bound
  under RRS=2 on all tests run.

## r44 (functional batch, implementation)

Scope: hyp8 only, no new files. Three execution-path repairs plus
leaf-bench coverage; cycle contracts preserved (no new pipeline
stages, no new ports, no config fields — pub/drain latency,
DcacheHitExtra behavior, and LsqReduceStages counts unchanged for
the shipped 8/10-leaf callers; the small-N shapes are corrected to
the configured count (see lsq_reduce below)).

Edits (pre-r44 snapshots: cva6-artifacts/r44/pre/ + MANIFEST.sha256):
- core/load_unit.sv (+178 diff lines): the publication/drain
  selection at :1119-1247 replaced serial low-bit priority + linear
  index OR + indexed gathers with balanced first-valid heap trees
  (PLEAVES padded, lowest-eligible-index wins, index-0 default when
  nothing eligible — the original retire_idx semantics incl.
  exception cycles). Merged payload rides the tree (pub_payload_t
  {meta,word}; word = per-byte fwd overlay) so ldbuf_rdata,
  trans_id_o and fwd_merged_data are selected directly — exception/
  spec/store-forward override priorities and the ldbuf_rindex/free
  side effects untouched. translate_off miter: independent
  ascending-scan reference index per edge, index/any/record/word
  compared; non-vacuous (multi-eligible and partial-forward edges
  exercised by the memory leaf).
- core/cache_subsystem/wt_dcache_mem.sv (+128): FWD byte reduction
  split at the EXISTING T1 register edge. PARTIAL_FWD =
  (DcacheHitExtra==2), forced 0 under the three mutant defines
  (FWD_ONE_HOT, FWD_LIVE_T2, new rollback G6LC_MUT_T4_DCFWD_FULL_T1).
  Under PARTIAL_FWD the padded associative left-valid-wins tree runs
  FWD_SPLIT levels live, the [byte][part] {v,d,u} frontier is
  captured at T1, and the remaining levels finish at T2 — no live
  slot is re-read at T2. Under !PARTIAL_FWD the original full merge
  + capture is retained exactly. The fsnap linear-capture checker
  still verifies the T2 word/BE/user tuple.
- core/ooo/g6lc_lsq_reduce.sv (+157) + g6lc_lsq.sv (+5): new param
  TRACK_WAIT (default 1; i_vio_red passes 0 — its wait/dwait were
  already unconnected — i_stl_red/i_q_red keep 1). TRACK_WAIT=0
  removes the cand_nd/cand_ur cones and ties wait_d/dwait_d to 0.
  All slot widths use SW=(LG>0?LG:1); SL/FBASE derive from true LG —
  NLEAF==1 gives SL=0, NLEAF==2 gives SL=1 (FBASE=1 either way) —
  with an explicit no-invalid-range generate arm. RSTG = (LsqReduceStages>=2)
  regardless of tree geometry (was: silently 1 when FBASE<2 — the
  r43-T 2-stage request was being dropped on small-N instances; all
  callers now get exactly the configured count). R1 captures NFR
  group-winner id/pay snapshots (GROUP_LEAVES=1<<SL contiguous
  leaves per frontier node, local gather only — no global dynamic
  read); R2's final index is root_s>>SL into the NFR snapshots.
  Cost: a bounded local mux enters R1 (reported, not assumed a win).
- verif/tb/core/tb_g6lc_hyp8_memory.sv (+111): response-slot
  publication/drain cases through the existing request/response/
  forward/verdict drivers — two eligible slots different TIDs/data
  (lowest publishes first, next publishes the following cycle),
  partial forward-byte overlay, empty/default-0, flush/tombstone
  drain; own-rid misaligned-exception cases kept.
- verif/tb/core/tb_g6lc_hyp8_control.sv (+423): (a) lsq reducer
  checker — selected 10-instance matrix (NLEAF,stages,DIR,TRACK_WAIT)
  = (1,1,0,1) (1,2,0,1) (2,1,0,1) (2,2,0,1) (3,2,0,1) (8,1,0,1)
  (8,2,0,1) (8,2,1,0) (10,2,0,1) (10,1,1,1); directed empty / highest-real-
  leaf-only / equal-distance ties (lowest slot wins) / duplicated
  waiting TIDs / flush between R1/R2; payloads randomized on every
  input edge; independent scalar scan sampled at input, expected
  output delayed by exactly the configured stage count. (b) dcache
  K-section on an isolated wt_dcache_mem — sources in three padded-
  tree frontier groups (wbuffer slot2 / fixup0 all-idx10 / fixup6
  all-idx16) with overlapping valid bytes, distinct data AND user
  bytes; K1 group0 wins all bytes; K2 cross-group byte overlay;
  K3 T1 capture then fixup pop+reuse before T2 (response must carry
  the snapshot); K4 no-hit. Driver note: on this driver under remote
  Verilator v5.008 --timing, mid-task writes on the unpacked-array
  DUT ports were not observed to re-trigger downstream comb
  evaluation, so km_* inputs are clock-staged registers; the request task
  grants for exactly one cycle and the fixup-reuse write lands at
  the T1 edge.

Evidence (remote ovh_calltorch, Verilator v5.008, closure
hyp8-r44-closure 393 files; runs under remote-runs/hyp8-r44-*):
- memory leaf:  HYP8_MEMORY_PASS checked=120          (memory-r2)
- lsq leaf:     HYP8_LSQ_PASS checked=2018, 0 event misses (lsq-r2)
- dcache +2:    HYP8_DCACHE_PASS checked=290          (dcache-r13)
- rollback +2, -DG6LC_MUT_T4_DCFWD_FULL_T1: PASS checked=290 —
  identical response tuple  (dcache-r15-fullt1)
- mutant -DG6LC_MUT_WBUF_FWD_LIVE_T2: FAIL caught by the existing
  DCHX_FIXUP_WINDOW_FWD check — discriminated  (dcache-r16-livet2)
- dcache +0 (-DG6LC_HYP8_DCHX0): FAIL D_NO_PMU_PULSE at the D
  dead-entry drop check — BASELINE failure, NOT r44: reproduced
  bit-for-bit with the pre-r44 wt_dcache_mem swapped into the same
  closure/bench (hyp8-r44-premem-closure, run premem-dchx0).
  First +0 leaf run since the bench progressed past B_LB0; the
  fixup dead-entry path pulses pm_fixup_write/inval under the
  0-arm where the check expects none. Not retuned per brief —
  recorded as blocker.
- Full-top lint (run_hyp8_lint_l3.py on hyp8-r44-int-closure,
  817 files, tag hyp8-r44-lint): scalar rc=0 (343/87/3
  EXPAND/TRUNC/CONCAT), smt2 rc=0 (354/97/3), l3 rc=0 (354/90/5);
  0 %Error all; the only LATCH warnings are 3 in vendor
  axi_riscv_amos_alu.sv (pre-existing upstream).

Timing (analyzer binary sha256 d837e8798a2b34800c2ec13abda21ee69
e88d5558e57b9d1085c049057f08a91 — identical before/after):
- before: boards/hyp8-core/analyze-r44-before.{json,log}
- after:  boards/hyp8-core/analyze-r44-after.{json,log}
  (cwd build/sv-timing/hyp8-src, param map
  analysis/r44-param-map.json, --all-modules --stages,
  5000MHz/20ps FO4/margin 0.2). Region-graph deltas present in all
  four touched modules (wt_dcache_mem 60->74, load_unit 140->150,
  g6lc_lsq_reduce 35->56 regions). Per-caller NLEAF/PAYW
  specialization is NOT in the scalar map — for paired analysis use
  pre copies at cva6-artifacts/r44/pre/ vs working tree, or the
  int closure manifest (hyp8-r44-int-closure/manifest.json) for
  exact post shas.
- No claim of boot, Linux retirement, or physical closure from
  this batch.

### r44 rework (timing countercases, consolidated)

Lead-measured before->after on the first r44 aggregate: load module
36.15->38.3, L5 regtoout 34.65->38.3; cache RR 33.346->34.046
(intoreg 37.6 unchanged); LSQ reduce RR 29.9->62.65, intoreg
22.1->37.2 — countercases, reworked as follows. First-attempt
variants are retained in cva6-artifacts/r44/candidates/ (passing
leaf evidence above stands; they are validated candidates awaiting
finer tool/physical evidence, not enabled in the tree):

- wt_dcache_mem-partial-frontier.sv (sha 59b58e34...): restored to
  the pre-r44 file in-tree; the bench K-section coverage is kept.
  The +0 baseline failure record above is unchanged.
- load_unit-heap-tree.sv (sha 410bdc96...): replaced by parallel
  prefix priority masks + balanced masked-OR gathers — pub_oh/
  drn_oh = first-eligible one-hot (`!(|ok[j-1:0])` prefix exclude),
  pub_select_oh adds the empty-case slot-0 default; leaves gate
  index/payload by the masks, node combine is a pure OR, no valid
  tree and no final payload mux. $onehot(pub_select_oh) asserted;
  the independent-scan miter is unchanged.
- g6lc_lsq_reduce-compact-payload.sv (sha 491e3d0c...): the NFR
  group-winner R1 gather is reverted — r1_id/r1_pay are full-NLEAF
  snapshot arrays again (`r1_id <= ent_id_i`), R2 gathers
  r1_id[root_s]/r1_pay[root_s] exactly as pre-r44. KEPT: TRACK_WAIT
  specialization (i_vio_red ties the wait cones to 0), the row-local
  dwait decoder + its translate_off scan miter, SW safe widths, the
  FBASE==1 tie arm, and the geometry-independent
  RSTG=(LsqReduceStages>=2) fix. Remaining cs0/cs1 in gen_pick_hi
  now use SW.

Dispatch candidate (fifth file, separately measured): the 54.6-FO4
ISS limiter traced to gen_op_asm fp_a/fp_b — three FP-use predicates
(is_rs1_fpr/is_rs2_fpr/is_imm_fpr over the staged record) are now
captured at the same iqi_take edge as iss_sbe_q/iss_fpsel_q
(iss_fpa_q/iss_fpb_q/iss_fpc_q, hold under flush/cancel/pop like the
record they shadow). fp_a/fp_b and issue_op_c_valid_o read the
cached bits; fh_c bypass gating and all valid/ack/operand wiring
unchanged. translate_off per-lane === invariant against the original
expressions over the held record (checked/active_fp/active_int
counters under +equiv_report). Pre-copy frozen at
r44/pre/core/ooo/g6lc_ooo_dispatch.sv; candidate variant at
r44/candidates/g6lc_ooo_dispatch-fp-pred-cache.sv.

Measurements (same binary sha d837e879..., same map/inputs):
- A/B/C refined: boards/hyp8-core/analyze-r44-refined.{json,log}
- dispatch candidate (on top of A/B/C):
  boards/hyp8-core/analyze-r44-dispatch.{json,log}
Verdict is the lead's; no remote reruns authorized yet.

### r44 final verification (post-review, post-verdict)

Lead verdict on the refined aggregate: KEEP priority-mask load select
(L5 regtoout 34.65->30.25, module 36.15 unchanged), KEEP LSQ
TRACK_WAIT/row-local decode/small-N fix (module 29.9 unchanged — no
winner-tree gain claimed), KEEP dispatch predicate cache (ISS module
max 54.6->48.3, in-stage 54.6->27.0 with displaced into-stage
24.15->48.3; intoreg 9.2->9.55, RR 22.3->23.35). wt_dcache_mem is the
exact pre-r44 file (sha 1597b4ee53200de75e56 — identical to
r44/pre). Counter observability fix: lane0_active_fp now requires
iss_v_q and is labelled lane0 (p0-only counters).

Final source sha256 (truncated 20):
  load_unit.sv          c9b243b2e0341e77dbf5
  wt_dcache_mem.sv      1597b4ee53200de75e56   (= r44/pre)
  g6lc_lsq.sv           f6f83fb55915ed721792
  g6lc_lsq_reduce.sv    ab0494c31b97547ef794
  g6lc_ooo_dispatch.sv  619c3d84651b386dd213
  tb_g6lc_hyp8_control  bdceca80ba1b35b134e9
  tb_g6lc_hyp8_memory   8f1d50b92e8d9aa0ab97

Leaf evidence on the final source-pinned closure (hyp8-r44-closure,
393 files, manifest sha-pinned; remote ovh_calltorch, Verilator
v5.008; runs remote-runs/hyp8-r44f-*):
- memory   HYP8_MEMORY_PASS   checked=120
- lsq      HYP8_LSQ_PASS      checked=2018
- dcache +2 (restored wt_dcache_mem + retained K frontier/snapshot/
  reuse coverage): HYP8_DCACHE_PASS checked=290 dchx=2
- dispatch HYP8_DISPATCH_PASS checked=115, pop_take_same=0
  (r2 rerun, hyp8-r44f-dispatch-r2 — supersedes the checked=91 r1
  run, which indexed issue_cnt with out-of-range tids 32..34/60..61;
  N2/N3 now use tids 8/9/10, unrelated WB 28/29, and wait_issue
  range-checks tid<NSB). The serialized arbiter never coincided
  iss_pop & iqi_take; reported as observed-not-covered. pop_take_n
  now accumulates $countones(iss_pop & iqi_take) per edge.
- +0 dcache NOT rerun (known baseline failure, recorded above).

Dispatch bench addition (section N, port-driven only): stalls
issue_ack_i, admits fadd_sbe, waits for the staged iss record, holds
through unrelated wb_once traffic and a flush_unissued mask cycle
(ivalid/iopc_v masked that cycle, record+class reoffered), releases
and admits an alu_sbe while ack is held low to inspect ITS staged
class bits (all-zero FP bits, int operand validities); N2 repeats
int->FP; N3 kills a held FP record with flush_i (no reoffer, no
issue). The DUT's own per-lane === invariant ran the whole time
(counters: fp_pred checked/lane0_active_* under +equiv_report).

Full-top lint on the final int closure (hyp8-r44-int-closure, 817
files; run tag hyp8-r44f-lint): scalar rc=0 (343/87/3
EXPAND/TRUNC/CONCAT), smt2 rc=0 (354/97/3), l3 rc=0 (354/90/5),
0 %Error; the only LATCH are the 3 pre-existing vendor
axi_riscv_amos_alu inferences.

git diff --check on handoff files: no real trailing whitespace in
added lines (the tool flags every '+' line because the touched
files carry CRLF endings; a per-line scan of the new regions shows
none). Licensing: existing per-file tier/headers preserved (hyp core/**
files inherit upstream notices under the default U tier); RTL
changes were not relicensed; no new files, manifests unchanged.
No boot/Linux/frequency claim is made by this batch.

### r45 execution record (post-verdict verification)

Timing verdict (lead): KEEP A/B/C. Boards: analyze-r45-before/after
under boards/hyp8-core/, binary d837e879..., r44-param-map.json.

Leaf evidence (closure hyp8-r45-closure, 394 files sha-pinned; remote
ovh_calltorch, Verilator v5.008 driver; runs remote-runs/hyp8-r45-*):

- mmu leaf `tb_g6lc_hyp8_mmu` (top appended to tb_g6lc_hyp8_control.sv;
  runner entry 'mmu' in run_hyp8_memory.py): **HYP8_MMU_PASS
  checked=716 miter=771** — tag hyp8-r45-mmu-r6 (canonical; r4 same
  verdict before the probe ifdef).

  Router miter: old g6lc_shared_tlb (UseSharedTlb=0, real module) vs
  new g6lc_tlb_miss_router, all outputs compared at every edge over
  DEPTHS {2,3,64} x HYP_EXT {0,1} (group1 runs RVH=1). Directed:
  I-only / D-only / simultaneous (D-hit suppresses I) / no-owner
  return (hit=1, updates 0) / live stage-flag switches / distinct
  returned hart+asid+vmid+content / all flush types / full 2*depth
  quiet window with exact resume edge (MMU*_W_WINDOW) / reset midwalk;
  then a 300-cycle deterministic varying-input soak. miter=771 edges.

  Depth-1: the old reference does NOT elaborate at SharedTlbDepth=1 —
  probe tag hyp8-r45-mmu-refd1 (G6LC_MMU_REF_D1) fails verilation with
  %Error-UNSUPPORTED 'left < right of bit extract: 11<12' at
  g6lc_shared_tlb.sv:478/480/495/497 (unsupported reference geometry).
  The new router IS exercised at depth 1 (i_dut_d1) against the
  explicit 2-cycle quiet-window expectation (MMU0_W1_WINDOW pass).

  Negative control: bench copy tb_mmu_router_mut with the I-return arm
  suppressed (if (1'b0)) — standing instance proves discrimination
  (MMU_MUT_IROUTE_DROPPED/DISC pass in the good run); the
  G6LC_HYP8_MMU_MUTANT build (tag hyp8-r45-mmu-mut) swaps it into the
  i_dut slot and fails by name: **FAIL MMU0_IRET_VALID** (named I-route
  check, not a timeout/compile failure).

  TLB predicate leaf: real g6lc_tlb with the new row-flush predicate
  generates + in-DUT old-form miter (ref_row_sfence/ref_row_addr_match
  asserted === every rst_ni cycle; MMU_MITER_EQ_FINAL). External
  oracle over entries {4,4,16}x stages {1,3,3} (HYP_EXT=0) and
  {4,16} x {1,3} (HYP_EXT=1/RVH): 4K/superpage/NAPOT-64K fills,
  distinct PPN/context, global-vs-ASID discrimination, VMID
  discrimination, flush all/addr-only/asid-only/both, flush-beats-fill
  priority (TLB0_FLUSH_BEATS_FILL). All port-driven; no forced state.
  TlbStages=3 sampled at two edges through the TLB (the third PMP step
  lives in g6lc_mmu, not exercised here).

- memory leaf (retained r44 cases + H section): **HYP8_MEMORY_PASS
  checked=129** — tag hyp8-r45-memory-r3 (+9 over r44's 120). H section
  drives the PA-capture qualification by ports: no capture with
  data_gnt=0 & dtlb_hit=0 (H_IDLE_HIT0_NOCAP, H_GNT_HIT0_NOCAP),
  capture on hit while held in WAIT_GNT (H_GNT_HIT1_CAP, H_PA_HELD,
  H_PA_VAL=0x81234000), no capture under held cancel
  (H_CANCEL_NOCAP), PA-valid clears on release (H_PA_CLEARED). The
  in-DUT g6lc_pa_now_eq invariant (load_pa_now_v === valid_i &&
  translation_req_o && dtlb_hit_i) ran the whole time.

- Dispatch/dcache/lsq untouched this round (dispatch leaf not rerun;
  wt_dcache_mem still exact r44/pre restoration 1597b4ee).

Two pre-existing defects surfaced by the leaf (both flagged to lead):

1. g6lc_tlb.sv plru_node_ents: `lvl = $clog2(n+1)` yields the correct
   BFS level only when n+1 is a power of two; for every other tree node
   sidx underflows -> empty SETM/CLRM mask -> right-side tree nodes never
   update (N=4: entry 3 unreplaceable; LRU order wrong). Discriminating
   evidence in hyp8-r45-mmu-dbg11 sim.log: t=7455 lu_hit_rsp=0100 (hit
   on entry 2), plru_tree_q=001011 -> live flat form produced
   n=001010 but the priority-loop reference produced 001110 (node2 must
   set). Never flagged earlier because no prior leaf instantiates
   g6lc_tlb and a hit on a slot >=2 is required to expose it. Dead high
   bits: plru_tree_q is sized 2*(N-1) but replace_en only decodes real
   nodes 0..2^PLRU_LVL-2, so the phantom bits are pure dead state.
   Applied minimal fix: `lvl = $clog2(n+2)-1`, and narrowed the
   g6lc_t1_plru_eq equivalence compare to the real-node prefix
   (PLRU_REAL = 2^PLRU_LVL-1) since the reference only models real
   nodes. Both changes sit in the same source region; the fix is
   confirmed by the leaf passing end-to-end.

2. g6lc_shared_tlb.sv enabled arm (UseSharedTlb=1): elaboration probe
   (i_stbl_probe behind G6LC_MMU_STBL_PROBE; tag hyp8-r45-mmu-r5)
   shows the shared-table path elaborates but trips -Werror-LATCH on
   `patched_pte` (g6lc_shared_tlb.sv:511): tag_comparison assigns it
   only inside the way-hit condition — a real latch, dormant because
   hyp8 always builds UseSharedTlb=0. Not fixed here (module was not in
   the r45 brief; the arm is unreachable in the shipped config).

Bench-side fixes made while bringing the leaf up (no RTL effect):
- tb_g6lc_hyp8_memory.sv configuration(): added c.PPNW=44 — the leaf
  cfg came from g6lc_cfg_empty (PPNW=0), degenerating dtlb_ppn_i to a
  [-1:0] port; only visible once H_PA_VAL read PA content.
- Driver-struct discipline: dynamic-indexed writes into packed
  multi-dim vectors (and field-select port expressions on unpacked
  struct arrays) do not propagate through DUT ports under this
  Verilator (--timing); TLB stimulus uses one shared packed-struct
  driver + runtime selector mux in the port expressions instead.
- st1 lookups now hold lu_access_i across one edge so the TLB PLRU
  pointer actually advances on comb hits.

Lint (int closure hyp8-r45-int-closure, 818 files; tag hyp8-r45-lint):
scalar rc=0 (343/87/3 EXPAND/TRUNC/CONCAT), smt2 rc=0 (354/97/3),
l3 rc=0 (354/90/5) — all 0 %Error; only the 3 pre-existing vendor
axi_riscv_amos_alu LATCH warnings. verilator_bin sha
3e622e33b741d1b2ba69. Manifest sha for g6lc_tlb matches final source
(1173f9bc5c7f6cfb07e0).

Source shas (sha256, 20-char prefix, final):
  g6lc_tlb_miss_router.sv (new)  0536c44cbfd31fc54e5d
  g6lc_mmu.sv                    77b7f1b7a9bb8eef1c71
  g6lc_tlb.sv                    1173f9bc5c7f6cfb07e0
  load_unit.sv                   1ad322f2f59d6acc0dd0
  tb_g6lc_hyp8_control.sv        b436cd6a7fc446084088
  tb_g6lc_hyp8_memory.sv         f28914da632c1fc55ea1
  run_hyp8_memory.py             6ce4ddbab9b3331fc6df
  Flist.g6lc_hyp8                0ae81ebfd99a3d2d23cb
  Flist.hyp8_apu                 4400397f23397199d916
  Flist.hyp8_sim                 991aa19b6262d9a12794
  .licensing-tiers               1564bd41e30540a8a336
  REUSE.toml                     ecfeb1dbcced2dec3895
  inputs/hyp8-core.f             0fbfc57aa8605cbe63e1

Licensing: .licensing-tiers carries the exact-path R rule
`R build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/g6lc_mmu/
g6lc_tlb_miss_router.sv` (after the broad hyp U rule at :277);
REUSE.toml annotates the same full path (Case-A aggregate). No stale
root-path `core/g6lc_mmu/...` rule remains. Existing files not
relicensed. No commits, no firmware, no boot/frequency/physical claim.

### r46 execution record

Two threads: scalar OpenSBI discrimination (r43 rank-1 stages vs store
path for the 483k spec_entry_live stop) and one structural item
(dispatch operand select).

THREAD 1 — OpenSBI scalar, two closures:

- hyp8-r46a-closure (818 files): full current working tree,
  g6lc_hyp_pkg sha 9f49a8b5f375d1703095bff.
- hyp8-r46b-closure: identical tree EXCEPT the closure copy of
  g6lc_hyp_pkg.sv Hyp8 literal — RenameResolveStages 2->1,
  LsqReduceStages 2->1, IqArbStages 2->1, PtwDecodeStage 1->0
  (closure-only; working tree untouched). Closure pkg sha
  12576a2b82ec7e17fc49 (manifest key carries the incdir double-slash
  `include//g6lc_hyp_pkg.sv`; first r46b run failed input-hash check
  on a stale manifest entry and was rerun after fixing it).

Integration (run_hyp8_integration.py, scalar target g6lc64_hyp8):
- hyp8-integration-r46a: build_complete, lint scalar+smt2 rc=0/0
  %Error, model sha 9db431b94c3fe119b94864.
- hyp8-integration-r46b: build_complete (HYP8_ALLOW_OVERLAP=1 recorded
  — witness r24a already running), lint rc=0/0 %Error, model sha
  a59b8eee5203eda1eb0389da3c4f609e.  No first-elaboration fixes needed.

Smokes (real tohost, +tohost_addr=0x80001000, 400k budget):
- r46a: h34=685, h33=1010, bc=492 (vs r41's 682/969/473; structural
  stages active — drift expected, reported).
- r46b: h34=682, h33=969, bc=473 — exactly the r41 numbers under the
  rank-1 config.

Witnesses (frozen fw_payload.elf a9218107..., +tohost_addr=0x80041730,
+stall_census +hang_dump=2000 +equiv_report +rvfi_cycle_stamp
+stq_trace +stq_lo=470000 +stq_hi=490000 — sb_trace does not exist as
a plusarg; stq_trace window used instead, 20M budget, detached):
- hyp8-osbi-scalar-r24a (r46a model): launched ~20:12:28Z; **reproduced
  the stop — [444284] store_buffer.sv:1292 ooo_spec_entry_live "entry 0
  holds tid 25 whose scoreboard slot is not live", $stop abort**.
  stq_count=0 (abort at 444k preceded the 470k window). results.json
  pulled to remote-runs/hyp8-r46a-witness-launch/.
- hyp8-osbi-scalar-r24b (r46b model): launched ~20:18:42Z; probed at
  ~20:28Z — log past cycle 490,000 (stq window fully captured, 8890 stq
  lines), ZERO errors, still running. It has crossed both 444,284 (A's
  abort) and 483,343 (the L3 stop).
- Discrimination per the stated map: A reproduced spec_entry_live, B
  passed the reference point => the r43 rank-1 stages own the stop;
  the store path is exonerated at this resolution. B outcome beyond
  ~490k pending (20M budget; not awaited).

THREAD 2 — g6lc_ooo_dispatch operand select (gen_op_asm :1277/:1280):
replaced the nested 2:1 chains with flat AND-OR. Two variants measured
with the exact r44/r45 argv (same binary/map):
- Variant G (gated selects, |fh_a/|hit_a in the AND): dispatch module
  max 48.3 -> 25.3 (regtoout @:371 gen_wb_tag); intoout 23.5,
  intoreg 9.55, regtoreg 23.35. Operand-mux cone <=4.0.
- Variant S (masked-bypass, kept): identical board — module max 25.3.
  ofa/oa are zero when their hit vectors are zero, so the bypass terms
  gate on fp_ alone; kept because the AND is one term shorter.
Recorded countercase: G identical to S on this board (no T9-style
billing regression either way). translate_off reference: pre-r46
nested expression compared === every cycle + $onehot on the select
quadrant (per-lane, under rst_ni). Working tree dispatch sha
c3d91a2a3a151e21b565. Awaiting lead verdict; dispatch leaf (A/B/C/N)
runs on a fresh closure only after acceptance.

### r46 bisection pass (post-verdict)

Dispatch-S verdict: KEPT (48.3->25.3 module max; G/S boards identical --
recorded countercase showing flat AND-OR selects are not uniformly
penalized, contra the T9 lesson). Dispatch leaf on fresh closure
hyp8-r46-closure (394 files): **HYP8_DISPATCH_PASS checked=115
pop_take_same=0 opasm_int=0 opasm_fp=0** (tag hyp8-r46-dispatch).
Non-vacuity result: the === miter's bypass terms were never exercised
-- zero edges with hit_a/fh_a set (in every directed case the WB lands
while the consumer is still upstream of iss staging). File-path arm was
checked every cycle; bypass arms are untested by this leaf. Reported
to lead; a directed staged-record WB-hit case would need a bench delta.

Field bisection of the spec_entry_live stop (closures built from the
r46a tree -- pre-dispatch-S; Hyp8 pkg patched in closure copy only;
both manifest keys `include/g6lc_hyp_pkg.sv` + `include//...` updated;
first c1 attempt failed hash check on the missed second key, rerun):
- c1 RenameResolveStages=2 only: hyp8-integration-r46c1 build_complete
  model 1f0699ab4005b7362635; smokes 683/981/476; witness
  hyp8-osbi-scalar-r25c1 launched ~20:41Z (stq window 430-450k).
- c2 IqArbStages=2 only: hyp8-integration-r46c2 model
  efc48fbe97cb1613f609; smokes 684/1003/490; r25c2 launched ~20:50Z.
- c3 LsqReduceStages=2 only: hyp8-integration-r46c3 model
  b504a7e242892ab92544; smokes 682/969/473 (identical to rank-1 B);
  r25c3 launched ~20:55Z.
- c4 PtwDecodeStage=1 only: hyp8-integration-r46c4 model
  bc15bb90c2b14f856b6d; smokes 682/969/473; r25c4 launched ~20:56Z.
All witnesses: fw a9218107..., +tohost_addr=0x80041730 +stall_census
+hang_dump=2000 +equiv_report +rvfi_cycle_stamp +stq_trace
+stq_lo=430000 +stq_hi=450000, 20M budget, detached.
HYP8_ALLOW_OVERLAP=1 recorded for the c-builds (r24b still running).

Early fleet probe (~20:57Z): r25c1 stq max_cycle=449,996 zero errors --
RenameResolveStages=2 ALONE does not reproduce at/near 444k.
r25c2 stq max_cycle=450,000 zero errors -- IqArbStages=2 alone does not
reproduce either. r25c3/r25c4 still pre-window; r24b past 490k clean.
Pending: c3/c4 window crossing and all four to 20M or abort.

Fleet probe ~21:07Z: ALL FOUR c-witnesses crossed the 430-450k
window with zero errors (r25c1 449,996; r25c2/r25c3/r25c4 450,000) and
r24b continues past 490k. No single r43 field alone reproduces
spec_entry_live at/near A's 444,284 stop -- if one fires later the
hang_dump/stq evidence names it; if none fire, the stop is a
multi-field interaction (A ran all four at r43 values together).
Witnesses left running to their 20M budgets.

## r46 mechanism trace + dispatch op-select non-vacuity (~21:35Z)

### hyp8-osbi-scalar-r24a-win (r46a model 9db431b9, fw a9218107)
Reproduced the abort: [444284] store_buffer.sv:1292 ooo_spec_entry_live
"entry 0 holds tid 25 whose scoreboard slot is not live". Traces:
+stq_trace 430-450k, +commit_trace_from/to 430-450k, +disp_trace,
+trace_from/to 430-450k, +hang_dump=2000. Extract at
remote-runs/hyp8-r46-t25/ (disp/stq/cmt filtered dumps).

tid 25 lifetime (store, fu=2, prd=0):
- 444255 disp alloc bank0 ent0 (rs1_rdy=0/rs2_rdy=1)
- 444260 rdy=111
- 444262 disp kill why=vanish canc=1 flush=0 (group kill: bank1 ent0
  tid26 killed same cycle) -- cancelled_mask[25] rises
- 444264 disp take port=0 -- TAKEN 2 CYCLES AFTER THE KILL: the
  IqArbStages=2 registered winner was already frozen at ARB when the
  cancel landed; the take-ack consumed a dead entry
- 444265 pop + iro v=1 ack=1 -- dead record issued
- 444269 stq vi=1 vwf=1 paddr=f20 tid=25 (store_unit s1)
- 444270 stq s1v=1 s2v=1 s2pa=f20 s2tid=25 (s2)
- 444270..443 sv stays 0, s2w/dgnt=0: spec push waits on the
  drain/wbuffer path ~14 cycles
- 444284 spec entry written with sb_live[25]=0 -> assert fires same
  edge (sv never printed 1; $stop beat the signature-change line)

Verdict on the mask-lifetime hypothesis: CONFIRMED with a refinement.
Commit pointer had already moved past 25 (cmt cptr 26->27 ~444263;
f0/t26 drop fires 444263), so cancelled_mask[25] and sb_live[25] both
fell ~444263-264 -- LONG before the spec entry landed at 444284. The
insert gate !cancelled_mask_i[tid] (store_unit.sv:584) is transient and
had expired; sb_live is not checked at insert. The enabling defect is
upstream: the take-after-kill -- a registered ARB winner is not
re-qualified against cancel, so a vanished IQ entry was issued.
Secondary: the s2 entry survived ~14 cycles of drain wait instead of
being squashed by its cancel, and the spec-push admission test is the
expired mask rather than sb_live.

### Bisection update (r25c2 verdict in)
r25c2 (IqArbStages=2 only, model efc48fbe) ABORTED at [3763469]
g6lc_lsq_cam_bank.sv:209 gen_upd_pipe[1] g6lc_t1_cam_oa -- "killed
match": the LSQ CAM produced a match on a cancelled tid. Same class as
the STQ assert: a dead tid propagated into a downstream consumer.
IqArbStages=2 alone is sufficient for take-after-kill propagation; the
r46a failure site needs the other rank-2 stages' added store-path
latency for the dead tid to reach the STQ spec queue past the mask
window instead of tripping an earlier LSQ check (or being absorbed).
Still running clean: r24b (rank-1 baseline, past 490k, 34MB log),
r25c1 (RR=2), r25c3 (LsqReduce=2), r25c4 (PtwDecode=1) -- all past
their 430-450k windows, no errors at ~21:34Z probe. r25c2 dead;
r24a-win dead (expected abort). No boot claim: nothing reached tohost.

### Dispatch leaf, op-select bypass arms (tag hyp8-r46-dispatch-r3)
Bench sec_o added (tb_g6lc_hyp8_control.sv sha 6b7622ff86b71b95eda6;
dispatch RTL unchanged at c3d91a2a3a151e21b565). Port-driven: hold
issue_ack_i low, admit a consumer dependent on an issued producer, and
HOLD the WB bus presented across the wake->take->iss_v window (the r5
select reads registered wakeup, so a 1-cycle wb_once can never overlap
the staged window -- a re-presented WB is legal stimulus).
HYP8_DISPATCH_PASS checked=125 pop_take_same=0 opasm_int=1 opasm_fp=1
-- both bypass arms exercised exactly one staged-overlap edge each;
opa/opb ports and opa_last/opb_last carry the WB data. First attempt
(hyp8-r46-dispatch-r2, wb_once version) passed vacuously again
(opasm=0/0) -- recorded as evidence the arms are unreachable via
single-cycle WB presentation under the r5 registered-wake select.

## r47 -- IQ-arb sticky kill (take-after-kill repair)

Root cause (accepted): g6lc_iq_arb sampled cancelled_mask_i only at
candidate capture (cand_cancl_q, C) and re-polled it live at take. The
mask names a tid only until commit-drop (~2 cycles), so a pulse in the
un-sampled middle of the ARB_STG=2 flight (C=444261, kill C+1,
take C+3) was missed: the record was taken and issued dead (r46 tid-25
trace; r25c2's 3763469 lsq_cam killed-match is the same defect one
scoreboard seam earlier).

### TIMING FIRST (over-budget, reported before other results)
boards/hyp8-core/analyze-r47-iqarb.json (exact r44/r45 argv, same
analyzer binary/map, delay-v44 + correction-v5):
- r45 baseline (analyze-r45-after): ARB in-stage 33.50, GRN->ARB into
  21.45, module regtoreg 28.41.
- r47 final: ARB in-stage **33.85** (+0.35 over the 33.5 limit),
  GRN->ARB into 24.4, regtoreg ~30.01 (win_s_regs accumulate cone,
  :625/:634).
- The 33.85 is an independent-LHS bundle / dependency-floor makespan
  artifact at the ARB out0 presentation bundle (:794), NOT a data-cone
  increase: identical 33.85 across four structural variants (baseline
  gate-form; mask_any refactor; separate win_kill_regs always_ff; and a
  control variant whose take-gate comb was literally pre-r47 text). Raw
  path even FELL 388.6->368.2 with the same 27.2 deflated chain. No
  timing-clean formulation was found that changes the billed number;
  the +0.35 is flagged here for the lead's verdict.
- VERDICT (lead): ACCEPT as measured -- bundle-makespan billing
  shift (pre-r47-text control measured identically, raw chain fell),
  and the fix repairs a baseline defect (r24b's 17.2M killed-match
  stop is the decisive evidence).

### Implementation (g6lc_iq_arb.sv only, sha efd11367fb892a885ff5)
- mask_q <= cancelled_mask_i every cycle; cleared on flush/reset
  (whole-mask register, covers the tournament-cycle sample).
- kill_h[b][ci] <= cancelled_mask_i[cand_tid_q[b][ci]] in
  arb_stg_regs (ARB_STG==2 only; C+1 CTL-snapshot read, register-
  indexed). ARB_STG==1 ties kill_h=0 -- mask_q already covers its only
  unsampled middle cycle.
- win_kill_next[p] = kill_h[win[p].bank][win[p].ci] |
  mask_any[win[p].tid] | (win_s_kill[p] && win_v[p] &&
  win[p].tid==win_s[p].tid); mask_any = cancelled_mask_i|mask_q.
  T35-style: kills ACCUMULATE on the held/re-selected record because
  the mask is transient.
- DEVIATION from the literal take-gate instruction, equivalent-or-
  stronger form kept: the accumulated verdict squashes the winner at
  staging -- win_s_v[p] <= win_v[p] && !win_kill_next[p] -- so a killed
  record is never a staged winner at all (covers take AND the
  stall/held bookkeeping), while take_grant keeps exactly its pre-r47
  cone (!pres_q.v && take_ok && !cancelled_mask_i[win_s.tid]).
  win_s_kill lives in a separate always_ff (win_kill_regs) to keep the
  analyzer's per-block bundle billing clean; self-clears when pres_q
  owns the port. A k=3 pulse during the take window blocks take_grant
  that cycle (live read) and the accumulated verdict suppresses the
  record at the next staging edge, so it can never retry.
- take_grant remains the single grant point: take_v/ack/pay outputs and
  ALL reservation side effects (w_in_tk, w_flu_tk, w_fpu_tk, div_tk,
  ein/eflu/efpu/ediv window enables) derive from it, so a killed record
  never takes and never reserves a WB slot.
- Mutant G6LC_MUT_IQ_ARB_NO_STICKY_KILL restores win_s_v<=win_v (live
  read only, the defect form).
- Header + block comments updated to the C/C+1/C+2/C+3 sampled-
  coverage timeline (:44-53, :230-249, :804-832).
- g6lc_iq_bank.sv (sha 99ca345ae4dba4b2c233): translate_off
  "take on dead entry" $error when a take addresses an entry with
  valid=0 -- detection only, no masking.
- No store-path RTL touched.

### Leaf verification (closure hyp8-r47-closure, 394 files;
###   tb_g6lc_hyp8_control.sv e3e19d54e901971e20bf, run_hyp8_memory.py
###   6ce4ddbab9b3331fc6df)
- hyp8-r47-issue-r4 (final structure): HYP8_ISSUE_PASS checked=99 --
  k in {0,1,2,3} single-cycle cancel pulses on ARB_STG=2 (i_arb2) and
  ARB_STG=1 baseline (i_arb, kept for the authored fixed-edge checks),
  no-cancel control takes at the expected edge, no take_v/ack_v/issue
  and no bank pop for any cancelled tid, held-record no-duplicate
  checks. Earlier run history: r1 failed ARB_TAKE_P0_TID1 (bench
  assumed ARB1 edge; added i_arb2 for Hyp8 ARB2); r2 failed
  ARB_TAKE_TID5 (stale fixed-edge expectation vs the real WbReserve
  deferral; converted to bounded poll); r3 passed gate-form
  checked=99; r4 re-passes the final suppress-form checked=99.
- hyp8-r47-issue-mut2 (G6LC_MUT_IQ_ARB_NO_STICKY_KILL): fails by name
  at [1529] F_ARB2_K1_TAKE -- sticky coverage is what kills the take.

### Scalar closure + lint + smokes
- hyp8-r47-int-closure (818 files, full tree incl. dispatch S c3d91a2a
  + all r43 stages at Hyp8 values + r47 arb/bank).
- hyp8-integration-r47: build_complete, model sha 7b1c5d1d...; lint
  scalar rc=0 / smt2 rc=0, 0 %Error, LATCH=3 (the three pre-existing
  vendor axi_riscv_amos_alu latches).
- hyp8-r47-lint-l3 (run_hyp8_lint_l3.py, all three profiles):
  scalar rc=0 (WEXP343/WTRUNC87/WCONCAT3), smt2 rc=0 (354/97/3),
  l3 rc=0 (354/90/5); %Error=0, LATCH=3 everywhere -- identical census
  to r45.
- Smokes (tag hyp8-r47, model 7b1c5d1d): h34_shift_dep 685,
  h33_st_fwd 1010, hyp8_branch_cancel 492 -- IDENTICAL to r46a
  685/1010/492; all tohost=0 SUCCESS. No smoke hits a kill case.

### Witnesses
- hyp8-osbi-scalar-r26 launched ~22:20Z detached on model 7b1c5d1d,
  fw a9218107..., +tohost_addr=0x80041730 +stall_census
  +hang_dump=2000 +equiv_report +rvfi_cycle_stamp +stq_trace
  430000-450000; 20M budget. Confirmed running (log growing).
  Prediction: crosses 444284 and 3763469 clean.
- Collected statuses at ~22:21Z probe:
  - r24b (rank-1 baseline): DEAD at [17247934]
    g6lc_lsq_cam_bank.sv:209 "equiv cambe (killed match)" -- the SAME
    defect class fires in the all-1-stages baseline too, ~17.2M cycles
    in (much rarer window: ARB_STG=1 leaves only one unsampled cycle).
  - r25c2 (IqArb=2): DEAD [3763469] same assert (already known).
  - r25c1 (RR=2): running clean, ~44.5MB log.
  - r25c3 (LsqReduce=2): running clean, ~37.6MB.
  - r25c4 (PtwDecode=1): running clean, ~37.6MB.
- No tohost anywhere; no boot/Linux/frequency/physical claim.

### Source shas (sha256 20-char)
g6lc_iq_arb efd11367fb892a885ff5 | g6lc_iq_bank 99ca345ae4dba4b2c233 |
tb_g6lc_hyp8_control e3e19d54e901971e20bf | run_hyp8_memory.py
6ce4ddbab9b3331fc6df | leaf closure hyp8-r47-closure (manifest pins
both) | int closure hyp8-r47-int-closure | model 7b1c5d1d | board
analyze-r47-iqarb.json.


## r48 -- PTW legacy-arm structural split + load_unit PA-capture split (2026-10-2x)

Lead's r48 brief: make the PDEC arm selection structural so the inactive
profile does not bill a dead procedural arm; split the load_unit PA
capture register's valid bit off its deep data-enable cone; exclude
g6lc_shared_tlb from the active board; re-emit the top-16 active
ranking.  All measured with the exact r44/r45 analyze argv
(analyze-r48-ptw-load.json, board sha 2ba401ededf7831a).

### r48A g6lc_ptw: legacy decode arm -> g6lc_ptw_leg_decode module

- The 37.55 FO4 module limiter at :763 lived inside the `if (PDEC)
  ... else` LEGACY verdict arm -- dead under Hyp8 PtwDecodeStage=1 but
  billed into g6lc_ptw by the syntactic parser.
- Fix: `if (!PDEC) begin : gen_legacy_dec` instantiates new module
  g6lc_ptw_leg_decode carrying the legacy verdict body verbatim
  (defaults replayed at head, identical semantics); g6lc_ptw merges
  leg_* into the FSM next-state only under `data_rvalid_q && !PDEC`.
  Single FSM kept; no forked state copy.  PDEC=1 ties leg_* to the
  held-register defaults (dead constant assigns).
- Result: g6lc_ptw active max 37.55 -> **35.7 @:535** (regtoreg, IDLE
  top-pointer formation -- a real active path previously shadowed by
  the dead arm).  g6lc_ptw_leg_decode standalone = 53.0 @:174 (dead
  for the active profile; excluded, see r48C).  The syntactic instance
  graph retains i_leg_dec plus one 88.7 FO4 port_bridged stitch on
  g6lc_ptw.out0 -- same dead-arm artifact class as i_shared_tlb had;
  noted, not an active path.
- Lint/elaboration under both PDEC values:
  - hyp8-r48-lint (PDEC=1 profile): scalar/smt2/l3 all rc=0, %Error=0,
    LATCH=3 (pre-existing vendor axi_riscv_amos_alu); gen_pdec_eq
    miter still elaborates.
  - hyp8-r48b-lint (closure-only Hyp8 patch PtwDecodeStage=0, both
    manifest keys updated): scalar/smt2/l3 all rc=0 -- i_leg_dec
    instantiated and all ports bound; identical warning census.
  - hyp8-integration-r48b: build_complete, model dc7d7b07; detached
    witness hyp8-osbi-scalar-r48b launched 23:07Z with the standard
    flags + stq window 430k-450k -- real walk traffic through the
    extracted module (the mmu leaf never instantiates g6lc_ptw).
- Source freeze: analysis/r48/pre/{g6lc_ptw.pre.sv,load_unit.pre.sv}
  (r47-int-closure pinned copies) + manifest.json.

### r48B load_unit: PA-capture valid/data split (KEPT)

- Pre: module max 35.05 @:587 (regtoreg and regtoout co-limited on the
  load_pa_now_v-gated 56-bit load_pa_q enable: cancel_hit 64:1 mask
  read + pa_capture_state decode + ldbuf_full fanned onto every bit).
- Change: load_pa_v_q keeps the full predicate; load_pa_q's data flop
  captures on `valid_i && dtlb_hit_i` alone.
- Legality (verified before edit): (1) load_pa_q consumers are only
  the four pa_hold_lo mux arms gated by load_pa_v_q, plus a
  translate_off $display (:2031, cosmetic -- may print transient data
  while v=0).  (2) While the load is head, lsu_ctrl.fu==LOAD keeps the
  shared MMU port pointed at this vaddr, so dtlb_ppn_i is this load's
  own lookup and cannot change under a continuously asserted hit
  (removal drops hit first; a refill needs a miss-side walk that
  re-enters pa_capture_state and recaptures under load_pa_now_v as
  before).  Head-admission transients sit under v_q=0/pa_drop.  (3)
  pa_drop (flush|!valid|pop) clears v on the pop edge -- unchanged.
- Result: module max 35.05 -> **30.25 @:1286** (regtoout); the capture
  cone itself is now 22.7.  No other load_unit kind rose above the old
  max.  KEPT per the brief's rule.
- Evidence: translate_off shadow register replays the old
  load_pa_now_v-gated capture; g6lc_pa_shadow_eq asserts
  load_pa_v_q |-> load_pa_q === shadow every cycle.  hyp8-r48-memory:
  **HYP8_MEMORY_PASS checked=129** (H section incl. shadow, no fire).
  hyp8-r48-lint2 (combined r48 tree): scalar/smt2/l3 rc=0, %Error=0,
  census identical to pre-change.

### r48C active-board exclusions + re-emit

- clock_exclude.txt += g6lc_shared_tlb (not instantiated: gen_shared_table
  needs G6LCCfg.UseSharedTlb=1; hyp8 runs UseSharedTlb=0 via
  g6lc_tlb_miss_router) and g6lc_ptw_leg_decode (not instantiated:
  needs HypCfg.PtwDecodeStage=0; hyp8 runs 1).  Justifications
  recorded in analysis/timing-summary.json exclusions_added_r48.
- analysis/timing-summary.json re-emitted (schema
  hyp8-timing-active-board.v1; pre file frozen to
  r48/pre/timing-summary.pre.json).  Top-16 active ranking (all 16
  live modules):

  1. g6lc_ptw 35.7 (rr @:535; stitch 88.7 = dead i_leg_dec bridge)
  2. g6lc_iq_arb 33.9 (in-stage ARB; r47 billing floor, lead-accepted)
  3. wt_dcache_mem 33.3  4. g6lc_iq_bank 32.3  5. g6lc_rename_recover 31.8
  6. g6lc_loop_buffer 31.8  7. g6lc_tlb 31.0  8. load_unit 30.2 (L5)
  9. g6lc_fe_override 30.2  10. g6lc_lsq_reduce 29.9
  11. g6lc_slice_dispatch 29.9  12. wt_dcache_ctrl 28.6
  13. issue_read_operands 28.0  14. alu 27.9  15. sb_commit_bundle 27.4
  16. store_unit 26.7

  Structural FO4 (lower_to_ir), not STA sign-off.

### Witness census update (23:07Z probe; supersedes r47 status lines)

- hyp8-osbi-scalar-r26 (r47 fixed tree): RUNNING, ~7.62M cycles (rvfi
  stamp @7620217), 0 errors -- crossed r46a's 444,284 and c2's
  3,763,469.  Next barrier: the 17.25M killed-match cluster.
- hyp8-osbi-scalar-r25c1 (RenameResolve=2): COMPLETED the 20M-cycle
  budget, "SUCCESS (tohost = 0) [cycle budget reached: no tohost
  verdict]" -- clean run, NOT a boot claim.
- r24b / r25c3 / r25c4: all DEAD on g6lc_lsq_cam_bank.sv:209 killed-match
  at 17,247,934 / 17,247,990 / 17,247,934 -- the baseline + two
  single-field runs hit the same class r47 repairs, ~17.2M deep.
- r25c2: DEAD [3,763,469] (known).
- hyp8-osbi-scalar-r48b (PtwDecodeStage=0, leg_decode active):
  launched 23:07Z, running.

### Source shas (sha256)

g6lc_ptw ec695990b47f97442416 | g6lc_ptw_leg_decode
ef61932751867e814f7c | load_unit bf6b6a6401d563ccd9 | pre-ptw 785b0c2d
| pre-load_unit 1ad322f2 | Flist.hyp8_sim 18a8486f | Flist.g6lc_hyp8
286d534b | .licensing-tiers 0b8c8516 (leg_decode added as tier R) |
REUSE.toml 05e11ca2 | closures: hyp8-r47-closure (395f, leaf),
hyp8-r48-int-closure (819f), hyp8-r48b-closure (pkg 5991deb6) |
r48b model dc7d7b07 | board analyze-r48-ptw-load.json 2ba401ed.

## r49 — loop_buffer expected-PC register (KEPT) + rename_recover census (REVERTED)

### g6lc_loop_buffer :236 — KEPT (32.78 -> 26.90)

- Cone census: base_q[5:0] + {replay_q,3'b0} low add -> pc_low_lit[6]
  carry -> unique-case select of base_hi_p1_q/base_q high halves ->
  32b+26b compares -> 8-input AND -> out0/hit_q. Registered operands
  (base_q, replay_q); the reconstruction is a fetch-path combinational
  chain (pre-registered-compare form).
- Transform (proven list: "predecode a compare whose operands are both
  registered one cycle earlier into an existing register"): new
  pc_cur_q maintains base_q + replay_q<<ALIGN, written on the same edge
  as replay_q/base_q via pc_cur_d = base_d + (replay_d<<ALIGN) (own
  always_comb reading the final _d values; covers every arm/fill/
  consume/flush priority case identically). seq_hit is now one VLEN EQ.
  No new latency: the adder sits on the register input, not the lookup.
- Miter (translate_off): pc_cur_q === expect_pc and seq_hit ===
  ref_seq_hit (old split-compare form via addr_eq) asserted every cycle.
- Boards (exact r44/r45 argv): analyze-r49-pre.json /
  analyze-r49-post{,2,3}.json. Final (post3): module max 32.78 ->
  26.90 regtoreg @:352 (the pc_cur_d region's own dep-floor billing);
  regtoout 32.78 -> 26.50 @:229; regtoreg cone 31.78 -> 25.50 @:229;
  intoout unchanged 23.20. No kind exceeds 26.90; intoout max
  unchanged. KEPT.
- Scalar lint hyp8-r49-lint2 (closure hyp8-r49-lint-closure, 819 files):
  rc=0, 0 %Error, LATCH=3 (pre-existing vendor), zero loop_buffer
  warnings.
- Shas: pre d1f2b972ac9b -> post 44772d18eca9.

### g6lc_rename_recover :589 — REVERTED (census + two countercases)

- Cone census: :589 sits in p_next_state, the unbanked always_comb
  (lhs=25, writes=70, deps=64). The board value is an
  independent-LHS-bundle makespan floor (31.8), not a gate-depth path:
  raw chain deflates 248.7 -> 11.0 but the dep floor dominates; billed
  chain rel2 -> ckpt_cnt_d[rec_hart] -> retire clamp -> ckpt_head_d ->
  pos_d (@:640). P10 handshake lock: restore is indexed by a same-edge
  pulse+index; InsertReg refused; staging prohibited.
- Attempt 1 (in-block mask merge, balanced-reduction analog): sections
  accumulated set/clear masks + one merged tail per bitmap. Result
  36.25 @:600 — WORSE; the mask writes added to the same region's dep
  count. Reverted.
- Attempt 2 (masks hoisted to module scope, comb->comb read of amap_d/
  owner_d per gen_posd precedent): 36.25 @:494 — identical floor billed
  on the mask/merge region; the floor follows the dependency structure,
  not the syntactic block, and cycles went 4->5.
- Verdict: no proven-list transform improves; the same-edge indexed
  restore forbids staging and the floor is inherent to the rec ->
  cnt -> retire -> head -> pos dependency chain. File restored
  byte-exact to pre (c273cd24041f4f0bbf5e9fd69..., verified sha), post3
  re-measure reproduces pre exactly (31.8 @:589). Census + countercases
  are the r49 artifact for this module.

### Freeze + witness status (probe ~23:25Z)

- analysis/r49/pre/{g6lc_loop_buffer,g6lc_rename_recover}.pre.sv +
  analysis/r49/post/ + analysis/r49/manifest.json.
- hyp8-osbi-scalar-r26 (r47 tree): RUNNING, ~12.70M cycles
  (stall-census cyc=12000000, ret=3365591, ipc=0.280; trace stamp
  12702252), zero verdict/error lines. Past 444,284 and 3,763,469;
  next barrier 17.25M (the r24b/c3/c4 killed-match cluster).
- hyp8-osbi-scalar-r48b (PDEC=0, extracted legacy arm active):
  RUNNING, ~3.65M cycles (trace @3651620), zero verdict lines.
- No tohost verdict anywhere -> no boot claim. The active PDEC=1 r48
  tree still has no detached witness; the next full-tree closure must
  carry r48+r49.

## r50 -- full-tree closure + fresh active board (2026-10-25, ~23:55Z)

- Closure hyp8-r50-closure (819 files: 491 flist + 311 include + 18
  extra) pins the full current tree: r47 iq_arb sticky kill, r48A PTW
  PDEC split (g6lc_ptw_leg_decode), r48B load_unit PA-capture split,
  r49 loop_buffer pc_cur_q, dispatch S. No new RTL this round.
- Lint hyp8-r50-lint: scalar rc=0 / smt2 rc=0 / l3 rc=0, 0 %Error in
  all three; LATCH=3 each (pre-existing vendor axi_riscv_amos_alu).
- Integration hyp8-integration-r50: build_complete, model sha
  a3b320727d9286b4c48166cffcc201ba0c481f682de40b037decd9955e4902b9.
- Smokes (real tohost=0 SUCCESS): h34 685 / h33 1010 / branch-cancel
  492 -- IDENTICAL to the r46a/r47 baseline; the loop_buffer pc_cur_q
  restructure did not move h34/h33 (no drift).
- Witness hyp8-osbi-scalar-r27 launched detached ~23:46Z on the r50
  model, fw_payload.elf sha a9218107 (verified at launch), flags
  +time_out=20000000 +max-cycles=20000000 +debug_disable +quiet_axi
  +tohost_addr=0x80041730 +stall_census +hang_dump=2000 +equiv_report
  +rvfi_cycle_stamp +stq_trace +stq_lo=17240000 +stq_hi=17260000
  (window moved to bracket the 17.25M killed-match barrier).
- Active board re-emitted from a FRESH full run:
  boards/hyp8-core/analyze-r50.json sha 6bd7c6f0f411b66b33c0..., exact
  r44/r45 argv with param map analysis/r44-param-map.json (sha
  75d16bc9, 62 keys incl. the rank-1 stage fields). Top-16 in
  analysis/timing-summary.json: ptw 35.7, iq_arb 33.9, dcache_mem
  33.3, iq_bank 32.3, rename_recover 31.8, tlb 31.0, load_unit 30.2,
  fe_override 30.2, lsq_reduce 29.9, slice_dispatch 29.9, dcache_ctrl
  28.6, iro 28.0, alu 27.9, sb_commit_bundle 27.4, loop_buffer 26.9
  (was 31.8 @:236; new limiter :352), store_unit 26.7. Structural FO4,
  not STA. Exclusions unchanged (g6lc_shared_tlb, g6lc_ptw_leg_decode).
- MEASUREMENT-HYGIENE NOTE: the r49 boards (analyze-r49-{pre,post*}),
  first r50 control run, were taken against inputs/param-map-hyp8.json
  (45 keys, lacks HypCfg.{RenameResolve,IqArb,LsqReduce,PtwDecode}
  fields and pins AluStages=2/IqSpecWakeup=2) -- a stale map, not the
  r44 map. Under it iq_arb reads 54.66 / ptw 49.50; those numbers are
  param-map artifacts, NOT regressions. loop_buffer/rename_recover are
  stage-param-invariant (identical values under both maps) so the r49
  keep/revert verdicts stand. Discarded control board sha
  9ccd36319af5a467.
- Witness status @~23:41Z: hyp8-osbi-scalar-r26 (r47 tree) running
  ~14.0M (census cyc=14000000 ret=3947276 ipc=0.282), zero
  verdict/error lines; 17.25M barrier next. hyp8-osbi-scalar-r48b
  running ~6.0M clean. No tohost verdict anywhere -> no boot claim.

### r26 final (collected ~00:13Z) -- STOPPED, new owner

- hyp8-osbi-scalar-r26 (r47 tree) aborted at [19466403]:
  load_unit.sv:1537 `misaligned_entry_excepts` -- "misaligned load
  buffer entry did not complete with LD_ADDR_MISALIGNED and a killed
  request" (Verilog $stop -> Aborting). Owner: ex_stage.lsu.load_unit,
  misaligned-grant completion contract (grant+1 must be exception+
  kill or translation-abort states; observed neither).
- Cleared all three prior defect barriers first: 444,284 (r24a
  spec_entry_live), 3,763,469 (r25c2 lsq_cam killed-match), and the
  17,247,9xx cluster (r24b/c3/c4) -- the r47 sticky-kill repair is
  confirmed against every prior stop class. The misaligned stop is a
  NEW failure owner, ~534k cycles short of the 20M budget.
- Last census cyc=18000000: ret=5094133 ipc=0.283; ldbuf_full=18,
  mem_viol=388 (climbing from 16 @2M). No [equiv] lines emitted
  (aborted before equiv report); no UART output in log. No tohost
  verdict -> no boot claim.
- r48b running ~10M clean @00:01Z; r27 (r50 tree) launched ~23:46Z,
  ~2M @00:01Z. Whether r50 hits the same misaligned assert is an open
  empirical question (r48B touched load_unit's PA capture, not the
  misaligned path).

## r50d -- misaligned_entry_excepts investigation (~00:25Z)

- Code read (no RTL change): ldbuf_w = data_req & data_gnt (:1095);
  grants only issue from IDLE/WAIT_GNT/SEND_TAG (:793-796). Under the
  antecedent, C+1 state_q is confined to {SEND_TAG, ABORT_TRANSACTION,
  ABORT_TRANSACTION_NI, WAIT_FLUSH}; the last three always carry
  kill_req (kill_abort/abort_ni/flush :811-813) and satisfy disjunct
  (b). A violation therefore implies state_q==SEND_TAG at C+1 with
  either kill_req && !valid_o (kill w/o same-cycle rvalid publish; the
  ex_pub arm :1237 requires data_rvalid in the kill cycle, rid==last
  OR !kill) or !kill_req (ex_i absent or PTW-broadcast-suppressed,
  kill_send :808) or pub_any stealing the shared valid_o (:1257 —
  else-if ordering would lose the exception publish entirely).
- Diagnostic: translate_off $error enrichment only (state_q, kill,
  valid_o, ex_o, ex_i.v/cause, ex_ptw, flush, canc_hit, canc_mask,
  dtlb_hit, rvalid, gnt, entry tid/op/off). hyp8-r50d-closure (819f),
  hyp8-integration-r50d build_complete model 91f56a6e50af, lint
  scalar/smt2 rc=0 0 %Error. hyp8-osbi-scalar-r27d launched ~00:22Z
  detached, +ld_state +smt_flow_trace +trace_from=19460000
  +trace_to=19467000 +stq_trace 17.24M-17.26M window.
- r27 (r50 tree) running clean ~6M @00:22Z; r48b ~14M clean. Awaiting
  the ~19.47M window on both for H1-vs-H2 discrimination.

### r27d diagnostic result (~02:05Z) — send_tag_kill_rvalid fires

- All three trees (r26/r47, r48b/PDEC=0, r27/r50) aborted at the
  IDENTICAL cycle 19,466,403 — deterministic, instruction-driven.
- r27d (diagnostic model 91f56a6e): aborted same cycle but on
  send_tag_kill_rvalid (:1576) — "SEND_TAG kill without the matching
  dummy data_rvalid". Both asserts describe the same event; the abort
  print order differs across builds (identical waveforms, different
  $error scheduling). Enriched misaligned message never printed.
- Port timeline [ldport/ldfsm] 19466360-389 shows back-to-back grants
  (did cycling 0/1/2) with rvalids ~3 cycles later, and exv=1 landing
  one cycle AFTER the SEND_TAG of the earlier sequence (exv at 388 vs
  tag at 387). Probe lines for 19466390-402 were lost to C stdio
  buffering on abort (stderr %Error jumped ahead; ~14 cycles of
  [ldport] never flushed).
- wt_dcache_ctrl gen_fsm_hit2 reading: every serving state answers
  kill_req with same-cycle data_rvalid (READ/READ_WAIT/READ_V/
  MISS_REQ/MISS_WAIT/MISS_RTRN_W/REPLAY_REQ); only IDLE and
  KILL_MISS/KILL_MISS_ACK do not — and IDLE is unreachable at a tag
  cycle (grant consumed the request one cycle earlier). Remaining
  violators: (a) rid-mismatch — rvalid present but mapping to an
  older in-flight slot (back-to-back grants share the port), or
  (b) ldbuf_rindex-vs-last_id conflation — pub_any at :1257 wins the
  shared index over rresp_idx even when the correct dummy rvalid
  arrives, which also suppresses ex_pub (else-if) so the exception
  publish can be stolen by an unrelated slot's data completion.
- Open: kill reason at 403 is the last unknown — own-fault
  (ex_i.valid&&!ex_ptw&&!flush&&!mask) => real lost completion (H2);
  cancel/flush kill (mask||flush term) => precise drop, assertion gap
  (H1). send_tag_kill_rvalid's message lacks the fields; proposed next
  diagnostic prints rresp_idx/data_rid/ex_i/canc fields in BOTH
  asserts (or a single shared violation dump). Awaiting verdict.
- Side note: r27d log is 6.9G — smt_flow_trace's OTHER probes
  ([smt-flow]/[smt-probe]/[lsqb]/retire/wb) are NOT bounded by
  +trace_from/+trace_to; only ldst/ldfsm/ldport are.

### r50e diagnostic (~02:30Z)

- Board procedure locked (lead verdict): boards/hyp8-core/analyze-r50.cmd
  records the exact argv naming analysis/r44-param-map.json (map sha
  75d16bc9...30e9) + board sha 6bd7c6f0...; execution-path-plan.md E1
  amended — a board without correct-map argv + recorded map sha is invalid.
- load_unit.sv (diagnostic only): send_tag_kill_rvalid $error now prints
  state_q, rvalid, did, rid, rresp_idx, ldbuf_rindex, last_id, pub_any,
  ex_i.{valid,cause}, ex_ptw_i, flush_i, cancel_hit, canc_mask[last_tid].
  Probe survival: [ldfsm]/[ldport] re-gated to (ld_state || smt_flow_trace)
  inside the window and every windowed line $fflush'd (r27d lost
  19466390-402 to C stdio buffering on abort).
- hyp8-r50e-closure 819 files (load_unit sha 2e1969a5);
  hyp8-integration-r50e build_complete, model 52fb8df4a7ee,
  lint scalar/smt2 rc=0, 0 %Error, LATCH=3 (pre-existing).
- hyp8-osbi-scalar-r27e launched ~02:25Z detached: standard flags +
  stq 17.24-17.26M + ld_state + trace_from=19460000 + trace_to=19467000,
  NO +smt_flow_trace (6.9G flood removed). r27 already dead at 19466403
  (identical to r26/r48b) — no kill needed.
- ANALYTIC RESULT (ex retention, settles (iii)/(b)): the killed entry's
  exception is DROPPED, not retained, when ex_pub loses the response
  cycle. ex_pub (:1237-1240) is single-shot: requires
  req_port_i.data_rvalid && state_q[LU_B_SEND_TAG] && ex_i.valid &&
  !ex_ptw_i && ((last_id==rresp_idx) || !kill_req_w), and sits behind
  `else if` under pub_any (:1257/:1263). The rvalid captures into the
  slot (rpend_q/rdata_q :506-508) and marks rkill_q (:509); next cycle
  drn_ok (:1167-1169) drains it silently via the drain pick (:1276-1279).
  No other arm sets ex_o.valid (:1253 default; only :1268, :1288);
  ex_o.cause/tval are driven LIVE from ex_i (:678-682) — nothing stores
  the exception for retry. Additionally a killed LIVE-tid slot is
  pub_ok-eligible (pub_ok does not check rkill_q, :1158-1160) — it can
  publish the dummy response as real data (misaligned_entry_no_data's
  target). For a live tid with ex_ptw_i=0 this is a real lost completion
  (H2): silent drain pop => the head's tid never completes => wedge.
  For a dead tid (flush_i/cancelled_mask kill, which requires
  ex_ptw_i=1 per kill_send :808-809) the drain is the legal precise
  drop => H1. Discriminator at 403 is exactly
  ex_ptw_i + cancelled_mask_i[last_tid] + flush_i — all printed by the
  r50e diagnostic.

### r51 sticky exception-pending + strict ex priority (load_unit)

- Ruling (lead): implement r51 now, in parallel with r27e. Sticky
  ex-pending for own-fault SEND_TAG kills; captured ex record; strict
  exception priority over the data tree; deferred pop via drn
  tombstone; misaligned_entry_excepts becomes a deferred/eventual form
  with the precise-drop disjunct; send_tag_kill_rvalid tests
  rresp_idx==last_id (D$ response identity, not the publish pick).
- Final structure (load_unit sha e44cbe41): pending-exception FIFO —
  shift register, head at index 0, entry = {slot, slot_oh, tid,
  exception_t}. ex_pend_set arms on own-fault kill
  (state_q[SEND_TAG] && ex_i.valid && !ex_ptw_i && valid &&
  !flushed_d). Depth = NrLoadBufEntries (pending entry holds its slot;
  overflow impossible). Registered head readiness pend_rdy_q/liveness
  pend_dead_q evaluated one cycle ahead on pend_d[0] so the publish
  gate reads registers only. Publish = cnt>0 && rdy && !dead &&
  !flush_i && pend_state_ok, where pend_state_ok = {SEND_TAG, ABORT,
  ABORT_NI, WAIT_FLUSH, WAIT_WB_EMPTY} | (!valid_i && !WPO) — FSM
  states where no head publish arm (WT fault / SPEC writeoff /
  st_fwd_done) can fire; unsafe states resolve bounded, empty head
  drains to !valid_i — liveness via commit-stall backpressure.
  Publish carries no pop: the slot is tombstoned (rkill_q OR head's
  slot_oh, guarded by ldbuf_valid) and freed by the drn pick next
  cycle — keeps the gate out of the ldbuf_valid_d register cone.
  Dead-head pop is unconditional (precise drop, never publishes).
  pub_ok excludes rkill_q/ex_pend_q slots (dummy-as-data hazard closed
  by logic; misaligned_entry_no_data retained as the check).
  ex_pend_sticky_drop assert: a publish never lands for a tid
  cancelled the previous cycle (same-cycle landing is legal — pub_ok
  reads flushed_q, never the live mask, so the scoreboard already
  tolerates WB-on-cancel-edge).
- Mutant: G6LC_MUT_LSU_EXPEND forces ex_pend_set=0 and restores the
  old pub_any-over-ex_pub priority — leaf fails by name.
- Leaf (remote, pinned harness): hyp8-r51-memory-l HYP8_MEMORY_PASS
  checked=152 on the final structure — L1 kill-cycle contention
  (exception wins, other slot publishes next cycle), L2 delayed dummy
  (exactly once), L3 cancel-at-kill (silent drain), L4 control.
  Mutant hyp8-r51-memory-mut2 fails by name: I1_EX_WINS.
- TIMING — structural debt, lead ruling "accept as measured":
  exact argv + r44 map 75d16bc9. History: slot-bit+pub-gate 56.40,
  st_fwd gating 62.10, state-set gate 48.4/52.4, per-slot FIFO 43.0,
  +live-mask removal 42.55, +one-hot head 42.05, +registered
  rdy/dead FINAL 41.05 regtoout load_unit.out0 @L1360 (independent-LHS
  bundle lhs=8 writes=18 makespan=41.0 deps=18, raw 92.6->deflated
  14.5); plain-path max 35.05; regtoreg 33.50. Reference 30.25 was the
  same bundle class on the same region (makespan billing, not a real
  cone — deflated numbers ~14-16 both sides). The mandatory residual
  is the publish-gate field (state_ok + registered rdy/dead + flush).
  Recorded as structural debt "load_unit exception publish-port
  arbitration"; candidate future specialization: an exception-only
  completion needs no data path — a dedicated exception WB lane /
  WbReserve slot would take the pending publish off the shared
  valid_o/trans_id_o port entirely. Deferred to a later pass.
- Boards: analyze-r51[a..l]-loadunit.json under
  build/sv-timing/hyp8-src/boards/hyp8-core/ (c,d,e,f,g,h,i,j,k,l on
  the final lineage).

### r51 closure / r27e verdict / r28

- r27e (r50e tree, enriched send_tag_kill_rvalid): DEAD at [19466403]
  — identical cycle to r26/r48b/r27 (fully deterministic). Verbatim:
    [19466403] %Error: load_unit.sv:1576: Assertion failed in
    TOP...i_load_unit.send_tag_kill_rvalid: SEND_TAG kill without the
    matching dummy data_rvalid (state_q=0000000100 rvalid=1 did=2
    rid=0 rresp_idx=0 rindex=1 last_id=0 pub_any=1 ex_i.v=1
    ex_i.cause=0000000000000004 ex_ptw=0 flush=0 canc_hit=0
    canc_mask=0)
  Shape: dummy rvalid WAS present and addressed the killed entry
  (rresp_idx=0 == last_id=0) but the OLD assert tested the publish
  pick (ldbuf_rindex=1) — pub_any stole the shared index in the kill
  cycle. ex_i.v=1 cause=4 (LD_ADDR_MISALIGNED) ex_ptw=0 flush=0
  canc_hit=0 canc_mask=0 -> LIVE own-fault exception dropped on the
  floor: H2 CONFIRMED. r51 (sticky ex-pending FIFO + strict ex
  priority + rresp_idx==last_id property) is the fix for exactly this
  shape. No H1 precise-drop disjunct needed for this event.
- hyp8-r51-closure: 819 files, pins load_unit e44cbe41 (final FIFO +
  registered-rdy structure). (Leaf bench tb_g6lc_hyp8_memory 074f15b9
  lives in the leaf closure hyp8-r51-leaf-closure, not the sim flist.)
- hyp8-integration-r51: build_complete, model
  cd44a9134e99f702717789884714e34f292769956aa30a5cc5d2354b251bfe0d;
  lint scalar/smt2 rc=0, 0 %Error, LATCH=3 vendor pre-existing.
  (First attempt 07:25Z stopped at build_blocked_by_overlap while
  r27e ran; re-ran clean at 07:17Z after r27e's abort.)
- hyp8-r51-lint-l3: scalar/smt2/l3 all rc=0, 0 %Error, LATCH=3.
- hyp8-r51-smokes (real tohost): h34=685 / h33=1010 / bc=492 —
  identical to r50 baseline, zero drift.
- hyp8-osbi-scalar-r28: launched detached ~07:23Z on model cd44a913,
  fw_payload a9218107, standard flags only (20M budget, stall_census,
  hang_dump, equiv_report, rvfi_cycle_stamp; no stq/ld_state/smt_flow
  windows). r27e showed rvalid=1 so no cache-side gate on the launch.

### r52 structural pass (boards analyze-r52pre/b/c/d/r52; exact argv, r44 map 75d16bc9)

- B1 g6lc_ptw gen_pdec_dec: shared predicates hoisted to
  continuous-assign wires (pte_is_leaf/napot64k/perm_i_fault/perm_d_ok/
  ptr_last/g_tr/gpptr); pdec_dec no longer reads dec_d.* — intra-block
  field chain broken. Module 35.7 -> 27.4 (PTW-DEC into 35.7->17.4,
  new limiter the pre-existing PTW-V arm :930). KEPT. r52b-ptw board.
- B2 wt_dcache_mem p_bank_req: read/write one-hots decoded
  independently (rd_bank_oh/wr_bank_oh, grant=rd_tag_only ||
  !(rd_ack&&collision); disjointness asserted translate_off
  g6lc_rd_wr_bank_disjoint); bank_idx per-bank rd-wins-own-bank;
  wr_denied/vld_we/inv_ack_o/wr_ack_o separate assigns. Cone
  37.6 intoout/intoreg :429 -> gone (residual intoreg 28.4@:325);
  module clock unchanged 33.35 (untouched forward tree :544, billed
  identically). KEPT. r52c board. Forward tree (L508-545) untouched
  per brief.
- B3 g6lc_fe_override: predict_fetchable evaluated per slot before
  the pred_win OR-gather (slot_fetch, pred_fetchable=|(pred_win &
  slot_fetch)); invariant cf!=NoCF => slot_pred_v asserted
  translate_off g6lc_feovr_predwin (bp_valid |-> |pred_win). Stage S
  30.25@:421 -> 24.9@:354 (pre-existing second path); guess_ok/
  ov2_pc_o not the new limiter (chain is the cf_win/sel region :354).
  KEPT. r52c board.
- B4 g6lc_iq_bank (ge1,ge2) pair tree: 32.30 -> 42.45 — WORSE.
  Reverted byte-exact (sha 99ca345a == r51 pin). COUNTERCASE,
  board analyze-r52d-iq.json kept.
- B5 g6lc_iq_arb: per-port block split into presentation + take
  always_comb; ack dynamic-index writes -> per-bank decoded assigns.
  33.85@:794 -> 32.85@:787 (take cone now bills separately).
  KEPT. r52d/r52 boards.
- B6 g6lc_lsq_reduce: design note only — analysis/r52-lsq-age-matrix.md
  (maintained pairwise age matrix vs compare-matrix; est. R1 29.9 ->
  ~10 FO4; awaiting ruling).
- Final board analyze-r52.json sha d6ffd997 (cmd header of record):
  active top: load_unit 41.0 (debt), dcache_mem 33.3, iq_arb 32.9,
  iq_bank 32.3, rename_recover 31.8, tlb 31.0, lsq_reduce 29.9,
  slice_dispatch 29.9, dcache_ctrl 28.6, iro 28.0, alu 27.9,
  sb_commit 27.4, ptw 27.4, loop_buffer 26.9, store_unit 26.7,
  fe_override 24.9. No module rose vs pre.
- Verify: hyp8-r52-lint scalar/smt2/l3 all rc=0, 0 %Error, LATCH=3
  vendor pre-existing. hyp8-r52-leaves: HYP8_MMU_PASS checked=716
  miter=771; HYP8_DCACHE_PASS checked=290 dchx=2 (pipelined; the
  single-cycle DCHX0 config's known D_NO_PMU_PULSE failure is
  untouched); HYP8_MEMORY_PASS checked=152.
- hyp8-r52-closure: 819 files (491 flist + 311 include + 18 extra).
  hyp8-integration-r52: build allowed under HYP8_ALLOW_OVERLAP=1
  (r28 witness in flight); model + smokes reported below.
  hyp8-integration-r52 (HYP8_ALLOW_OVERLAP=1, r28 in flight):
  build_complete, model dd7c36e0d868c9fa..., lint scalar/smt2 rc=0
  0 %Error. hyp8-r52-smokes (real tohost): h34=685 / h33=1010 /
  bc=492 — identical to r50/r51 baseline, zero drift.
  r28 witness alive ~4.89M cycles @07:47Z, censuses clean
  (mem_viol=16 flat).

### r53 structural pass (pre board analyze-r52.json d6ffd997; final analyze-r53.json fd874eb7)

- X1 g6lc_slice_dispatch: confirmed NOT in the active Hyp8 profile
  (issue_stage.sv gen_slice_ooo arm requires SliceOoOEn; hyp8 cfg
  SliceOoOEn=0/OoOEn=1). Added to inputs/clock_exclude.txt;
  justification in analyze-r53.cmd header.
- T1 g6lc_tlb hit prefix: multi-hit reachable only via inconsistent
  page tables or a software SFENCE race (a hit suppresses any second
  fill) — outside contract. tlb_above/tlb_hi1 prefix removed; rsp
  gather masked-ORs tlb_hitv; translate_off
  g6lc_tlb_hit_onehot0 asserts $onehot0 gated on rq_access.
  Module 31.0 -> 30.85 (T2-into 31.0->26.0, new top :634). KEPT.
- B6 g6lc_lsq_reduce: distance tournament -> registered pairwise
  compare matrix. Parent computes st_age_q (shared by i_stl_red +
  i_q_red — stl_eid_q/q_eid_q snapshot the same st_q[*].id at the same
  edge, verified) and vio_age_q[u] (covers vv virtual leaves) via
  ooo_age_older at the C-stage edge; pivot-invariance argued (retired
  leaves dead in cand). win_mask = cand & ~|(cand & row/col) per DIR;
  lowest-index one-hot for the equal-id tie; dist_i payload-only;
  R1/R2 RSTG split preserved. Module 29.9 -> 15.10 (intoreg :229 —
  above the ~12 stretch target, halved). KEPT.
  In-DUT miter g6lc_lsq_red_age_miter vs verbatim translate_off
  tournament (ref_*); G6LC_MUT_LSQ_AGE_DIR flips row/col.
- D1 wt_dcache_mem :544 investigation -> analysis/r53-dcache-fwd.md
  (chain census, wtag ~50b x8 compares, rd_tag live port; 3 candidates
  incl. T1-registered compare + alloc-edge bypass hazard analysis).
- Leaf repair (bench predates the E-C-R-V staged LSQ + file split):
  tb_g6lc_lsq interface g6lc_cfg_t/G6LCCfg+HypCfg; do_query waits the
  registered verdict; wait_verdict latches the 1-cycle
  forward/stall/violation pulses + viol_id; F/G scenarios added
  (youngest-of-two DIR=0 oracle, oldest-violator DIR=1 oracle);
  run_lsq_leaf.py input list extended to the split modules (+pkgs,
  cf_math_pkg, yosys_bin via data), verilator PATH wrapper, mutant
  expectation accepts LSQ_MASK_H0 (broadcast semantics catch the
  dropped hart tags by name).
- Verify: hyp8-r53-lint scalar/smt2/l3 all rc=0, 0 %Error, LATCH=3.
  LSQ leaf (hyp8-r53-lsq16/17): see below. hyp8-integration-r53
  build_complete model 52c906d3 (HYP8_ALLOW_OVERLAP=1, r28 in flight).
  hyp8-r53-smokes: h34=685 / h33=1010 / bc=492 — identical.
- Final board analyze-r53.json sha fd874eb7: load_unit 41.0 (debt),
  dcache_mem 33.3, iq_arb 32.9, iq_bank 32.3, rename_recover 31.8,
  tlb 30.9, dcache_ctrl 28.6, iro 28.0, alu 27.9, sb_commit 27.4,
  ptw 27.4, loop_buffer 26.9, store_unit 26.7, axi_adapter 26.2,
  ai_exec 26.1, aes 26.0, sb_lifecycle 25.9. g6lc_lsq_reduce 15.10
  (off top-18); slice_dispatch excluded. No module rose.

### r54 structural pass (pre board analyze-r53.json fd874eb7; final analyze-r54.json cdd0c594)

- B4b g6lc_iq_bank e_cancl (32.3 regtoout :382): ruled out — a
  cancelled-but-valid entry could still win cand0/cand1 and displace a
  live candidate that cycle (perf-visible, not logic-equivalent);
  gen_take_dead :1457 cannot be shown unreachable. Live read kept.
- alu :711 dense-control cone (27.87): split the two serial >>>
  loops into per-result always_comb — COUNTERCASE 27.87->48.05
  (the split billed each loop's full shamt chain separately),
  reverted byte-exact.
- g6lc_iq_arb :787 take decode (32.85): per-bank one-hot decode for
  take_v_o/take_cand_o/take_idx_o — COUNTERCASE 32.85->34.21,
  reverted byte-exact (dynamic index write was cheaper than the
  3-bank compare fanout).
- wt_dcache_ctrl :255 hit0 READ/REPLAY_READ arm (28.57): hoisted
  rd_hit_fwd/req_rd_ack/tagv_seen/replay_cond to gen_fsm_hit0-scope
  wires; state_d single-write per arm (kill the IDLE-then-READ
  overwrite). KEPT 28.57->24.02.
- issue_read_operands fus_busy :1666 (28.0): COUNTERCASE-DECLARED —
  two prior rewrites of this exact prefix-copy chain measured 46.4
  (in-file record :765-768); 28.0 is the dependency floor. No edit.
- sb_commit_bundle :368 cport_valid (27.40): replaced the
  !ex_merged.valid read with the equivalent direct predicate
  !(sel_sbe.ex.valid || (wb_hit && wbex.valid)) — cuts the
  cport_ex->cport_valid block dep. KEPT 27.40->25.40.
- Board note: g6lc_lsq_reduce drifts 15.10->16.5 on an unchanged file
  (analyzer variance, same delta on both r54 boards; still << its
  pre-r53 29.9). No other module rose.
- Verify: hyp8-r54-lint scalar/smt2/l3 all rc=0, 0 %Error, LATCH=3.
  hyp8-r54-closure 819 files.

### r55 witnesses / board hygiene (pre board analyze-r54.json cdd0c594)

- r28 (hyp8-osbi-scalar-r28, r51 model): RAN TO 20M BUDGET-OUT,
  past the 19,466,403 deterministic r51-barrier abort — the pending-
  exception FIFO repair is confirmed by the witness (no abort line;
  clean CPU-time exit at 19,999,981). [equiv] counters all live:
  cambe 19,982,037; lsq_reduce pickdist/dwait/lsqr2 ~19.98M (the r53
  age-matrix miter across the whole run — zero divergence);
  fwd_snap 1,764,815; pub_tree multi=7658 pfwd=0; tx_single 345,279
  viol=0; l1_obligation dropped=302,834. No tohost verdict (witness is
  liveness-only; budget reached). Not restarted.
- hyp8-r55-closure: 819 files; tree = r54 + lead's line-ending
  normalization (alu.sv 787cc3cf, sb_commit_bundle c5c11fca,
  g6lc_lsq_reduce 12b39f31 — recorded in manifest note).
- hyp8-integration-r55: build_complete model 34a5c9dd (scalar/smt2
  lint rc=0 inline; HYP8_ALLOW_OVERLAP=1, r28 in flight at launch).
  hyp8-r55-smokes on the new model: 685/1010/492 — identical.
- X2 g6lc_ai_exec: CONFIRMED not instantiated under Hyp8
  (frequency_closure.uninstantiated_modules; it lives under
  cvxif_g6lc_ai with no active g6lc_ai_coprocessor instance).
  Added to inputs/clock_exclude.txt; re-emitted analyze-r55.json
  sha 75fd8a1d — corrected top-16 drops ai_exec (26.1); no other
  change, zero rises.
- hyp8-l3-integration-r55: build_complete model b40475f8 on
  hyp8-l3-r55-closure (824 files, scalar/smt2/l3 lint rc=0).
- hyp8-osbi-l3-r2 launched ~08:59Z (detached, standard flags, 30M,
  fw 01ae648d stock) on model b40475f8. PAST the r1 discriminator:
  771,776 cycles at ~09:04Z > r1's 483,343 abort (store_buffer
  g6lc_spec_entry_live), still running.

### r55b r28 progress analysis (forensic, no new sim)

- r28 retired 5,612,115 instrs in 20M cycles, ipc 0.281 flat
  (0.278->0.283 across 10M->20M census) — real retirement throughout,
  not a stall.
- PC evidence: at ~10M cycles the retired PCs sat in
  fdt_supernode_atdepth_offset / fdt_parent_offset / fdt_getprop /
  irqchip_plic_cold_init / fdt_parse_hart_id (real OpenSBI cold-boot
  FDT+PLIC work). At ~19.9M the last-2000 histogram is dominated by
  nputs (0x80009f80-0x80009fc0 = the per-char lbu/jalr/bne loop),
  printc, print, and uart8250_putc/set_reg (0x80010e5c-0x80010e72 +
  the set_reg sw/sh/sb to uart8250_base) — the OpenSBI console output
  path. PC region changed 10M->20M => forward progress, not a spin.
  VERDICT (a): it was emitting the banner char-by-char through printf
  when the 20M budget hit; per-char printf at ~0.28 ipc is just slow.
- UART: zero [uart] lines in run-hyp8.log, but the disasm proves
  uart8250_putc executes its sw/sh/sb to uart8250_base — the harness
  does not emit [uart] trace lines on this model (r1 also had
  uart_lines=0), so absence of a banner in the log is NOT absence of
  console output; the PC path is the evidence.
- Stall census: dominant class = ack_full (1,906,322 of 3,705,793
  ack_cyc); dmiss/dc_req/dc_gnt/mshr all 0 — no memory bottleneck.
  flush_cyc=17,949 trivial.
- mem_viol: grew 16 -> 1200 over the run (same climb shape as r26's
  16->258->333; memory-order violation replays, not an assert).
- l1_obligation dropped=302834 plain=302834: counts LEGAL obligation
  drops via the plain-drop path (the equiv counter that replaced the
  r41v2 hard assertion); every drop took the legal path (plain=dropped
  count), high rate but no violation — the assertion never fired.
- l3-r2: alive ~1.14M cycles; its tail sits in a tight 8-PC loop
  inside fdt_offset_ptr (0x800128c8-0x800128e4) with a dominant
  3-instr bne/store encoding repeated ~1600x — heavier than r28's
  print loop; watch whether it exits FDT traversal into PLIC/print
  or is a real livelock at the next probe.

### r56 (UART observability + r29 witness; l3-r2 discrimination; load_unit census)

- A UART: InclUART=0 under Verilator -> mock_uart; its uart_tx already
  $write("%c")s each THR byte to stdout but r28's log has ZERO banner
  bytes (53 'OSBI/boot' hits were all [boot] reset-trace lines) — the
  raw %c stream is invisible to [uart] grep and may be suppressed in
  the causal build. Added a TB-only probe at the APB boundary in
  corev_apu/tb/g6lc_peripherals.sv (translate_off): fires on
  uart_psel&penable&pwrite&THR-offset, prints "[uart] <char>", dumps
  bytes to uart.txt, final "[uart] uart_bytes=N". Covers both the
  apb_uart and mock_uart arms. hyp8-r56-closure 819f;
  hyp8-integration-r56 build_complete model c11570a0 (lint rc=0).
  hyp8-osbi-scalar-r29 launched ~09:19Z detached (INT_TAG
  hyp8-integration-r56, fw a9218107, standard flags, 60M budget);
  alive ~231k cycles at ~09:21Z.
- B l3-r2 discrimination: r28's first uart8250_putc-range PC at
  5,433,078, first print/nputs-range at 5,941,767 (fdt range interleaved
  through init). l3-r2: fdt-range only, last fdt PC 3,079,877, ZERO
  print/uart hits; at ~3.96M cycles still in fdt_offset_ptr region —
  below the 2x discriminator (~10.9M no-print), keep watching. L3 DTS
  adds l2/l3 nodes => some FDT-walk inflation is legitimate.
- C load_unit census (analyze-r55 75fd8a1d): 41.05 regtoout bundle
  (r51 debt), 35.05 regtoout plain state_q->state_d :1360, 33.5
  regtoreg state_d unique-case :1046 (dep floor deps=31). Candidates
  C1 (B1-class predicate hoist, est ~-9 FO4) / C2 (publish-vs-state
  always_comb split, ~-3) written to analysis/r56-load-unit-publish.md.

### r57 (load_unit C1-null / C2-skipped; UART read/AXI probes; r30 witness)

- load_unit C1 (predicate hoist d_rvalid/kill_req/lu_valid/ex_v/ex_ptw
  into load_control): analyze-r57a measured 41.05 -> 41.05 — NULL.
  The dep floor is state_d's own arm-to-arm write chain, not input
  recompute. C1 reverted; the file was restored byte-exact from the
  r55 closure pin (sha e44cbe41, LF) after the manual revert left a
  CRLF residual.
- load_unit C2 (publish-vs-state always_comb split): SKIPPED with
  reason — rvalid_output already owns valid_o/trans_id_o/rdata_o; the
  only mixed writes left are pop_ld_o/lu_replay_o/miss_req_o inside
  ~10 nested state_q arms, so splitting them duplicates the FSM (a
  replication edit, not a safe equivalent). The dep floor needs a
  single-state_d-write FSM restructure, which is out of scope for an
  equivalent-rewrite pass. load_unit 41.05 remains accepted r51 debt.
  Ruling (b) accepted; no leaf/mutant rerun needed (tree = r55 pin).
- UART probes (TB-only, translate_off, in g6lc_peripherals.sv):
  [uart] THR-write log + uart.txt + uart_bytes; [uart-rd] read-side
  probe (first 200 + per-offset histogram); [uart-axi-ar]/[uart-axi-r]
  AR/R handshake log at the UART slave port. All in hyp8-r56-closure.
- hyp8-integration-r57 build on hyp8-r56-closure (819f).

### r57 resolution — OpenSBI v1.5 banner CONFIRMED (r30)

- hyp8-integration-r57 build_complete on hyp8-r56-closure (all UART
  probes). hyp8-osbi-scalar-r30 launched ~10:01Z (r57 model, 60M).
- At ~5.51M cycles r30 emitted the first [uart] byte; at ~5.6M the
  stream reached 315 bytes = the full "OpenSBI v1.5" ASCII banner
  (verbatim in uart.txt: ESC\r\nOpenSBI v1.5\r\n + the logo).
- Path proof: [uart-axi-ar] addr=10000014 (LSR) at master[UART];
  [uart-axi-r] data=...60... resp=0; [uart-rd] off=5 data=60.
  The putc poll reads THRE|TEMT, writes THR — correct 16550 flow.
  The r55b "14M cycles in nputs/putc, 0 bytes" was the invisible %c
  stream (mock_uart's $write had no [uart] tag), NOT a stall: r28
  was printing the banner when its 20M budget hit.
- Discriminators resolved: H1 (read never reaches APB) dead — AR
  arrives at master[UART]. H2 (bridge returns 0) dead — [uart-rd]
  off=5 data=60. H3 confirmed — real banner emission.
- l3-r2: 16.67M, alive, forward progress (left fdt_offset_ptr ~9.4M,
  did post-FDT work, back in FDT for a later init pass).
- r29: 13.7M still running on the write-probe-only model (its %c
  bytes are invisible but the PCs prove the same banner emission).

### r58 (wt_dcache_mem D1 repartition; UART banner confirmed on r30)

- W thread: r30 emitted the complete OpenSBI v1.5 banner (uart.txt
  verbatim — ESC + logo + \r\n). UART path works end-to-end
  ([uart-axi-ar] addr=10000014, [uart-axi-r] data=..60.., [uart-rd]
  off=5 data=60, [uart] bytes). r28's "14M in putc, 0 bytes" was the
  invisible %c stream, never a stall. r30 past banner at 8.5M in
  post-FDT platform-info work; l3-r2 19.4M same 0x80004b region.
- S D1 wt_dcache_mem (DcacheHitExtra==2 repartition): T1 now captures
  wbuf_hit_oh_q + per-entry {valid,data,user} snapshot
  (wbuf_vld_q/wbuf_data_arr_q/wbuf_user_arr_q); T2 runs the byte-lane
  merge tree on the SNAPSHOT via wbuf_dat_src/wbuf_usr_src (live arm
  unchanged). merge_hit=wbuf_hit_oh_q, merge_vld=wbuf_vld_q,
  wbuffer_*=fwd_*_c (T2 comb). Removed dead wbuf_be_q/wbuf_data_q/
  wbuf_user_q. fwd_snap equiv re-pointed: serial recompute over the
  same T1 snapshot inputs vs the balanced-tree result.
- Board analyze-r58a: wt_dcache_mem 33.35 -> 28.4 FO4, ZERO module
  rises. KEPT (accept rule met). Flop add: (WbufferAllDepth-1)x
  (XLEN+USER) - XLEN/8 bits net.
- Verification: hyp8-r58-leaf-closure (395f). HYP8_DCACHE_PASS
  checked=290 dchx=2 stores=88 (pipelined), HYP8_MMU_PASS checked=716
  miter=771, HYP8_ISSUE_PASS checked=99, HYP8_MEMORY_PASS checked=152
  all identical to baseline. G6LC_MUT_WBUF_FWD_LIVE_T2 mutant fails by
  name (FAIL DCHX_FIXUP_WINDOW_FWD at tb_g6lc_hyp8_control:4067) after
  fixing the mutant arm to live-read wbuffer_all via gen_live_mut_src
  (the shared-leaf-source patch had snapshot-reads in both arms).
  hyp8-integration-r58 build_complete model 65643d24, lint scalar/smt2
  rc=0. hyp8-r58-smokes 685/1010/492 identical. Flop cost ~+2224
  (WbufferAllDepth=32 x 72b snapshot - 72b removed merge regs).
  File LF-normalized (i/lf w/lf).

### r58b (D1 refinement — narrowed snapshot; smt2-r1 queued)

- Lead refinement: snapshot only real entries — wbuf_data_arr_q/
  wbuf_user_arr_q narrowed to [WbufferAllRaw-1:0] (19 entries); pad
  entries (19..31) tied '0 via gen_snap_src/gen_snap_pad generate
  (wbuffer_all pads are '0 at :183 so merge_hit is always 0 there).
  T1 capture + fsnap recompute bounded by WbufferAllRaw. Flop cost
  final: 19x(64+8) - (64+8+8) ~= +1,288 flops.
- analyze-r58b: wt_dcache_mem 28.4 UNCHANGED, zero rises.
- Re-verified: HYP8_DCACHE_PASS checked=290 dchx=2 stores=88 +
  HYP8_MMU_PASS checked=716 miter=771 (hyp8-r58b-dleaf);
  G6LC_MUT_WBUF_FWD_LIVE_T2 fails by name (FAIL DCHX_FIXUP_WINDOW_FWD
  tb_g6lc_hyp8_control:4067, hyp8-r58b-dmut); hyp8-r58-lint-l3
  scalar/smt2/l3 all rc=0 (LATCH=3); hyp8-r58-smokes2 685/1010/492.
- hyp8-osbi-scalar-r29 killed (redundant — r30 covers the banner).
- hyp8-smt2-integration-r58 building (SOFT_LADDER_BUILD_TARGET=
  g6lc64_hyp8_smt2) for hyp8-osbi-smt2-r1 (60M, fw a9218107).

### r58c consolidated summary (pre-r52 -> post-r58b)

Module board (pre board analyze-r52pre -> analyze-r58b; active ≥20 FO4
that changed, plus accepted debt/floors):

  module                    pre     post    note
  wt_dcache_mem             37.60   28.40   r52-B2 one-hots + r58-D1 T2-snapshot
  g6lc_ptw                  35.70   27.40   r52-B1 pdec hoists
  g6lc_iq_arb               33.85   32.85   r52-B5 presentation/take split
  g6lc_tlb                  31.00   30.85   r53-T1 masked-OR hit gather
  g6lc_fe_override          30.25   24.90   r52-B3 slot_fetch before gather
  g6lc_lsq_reduce           29.90   16.50   r53-B6 compare-form age matrix
  wt_dcache_ctrl            28.57   24.02   r54 state_d predicate hoist
  sb_commit_bundle          27.40   25.40   r54 ex_merged.valid direct form
  load_unit                 41.05   41.05   accepted r51 debt (C1-null, C2-skipped)
  g6lc_iq_bank              32.30   32.30   floor (B4 countercase, e_cancl ruled)
  g6lc_iq_arb               -       32.85   (kept at 32.85 post-B5)
  issue_read_operands       28.00   28.00   dependency floor (2 prior 46.4 cases)
  alu                       27.87   27.87   floor (>>> split 48.05, one-hot 73.8)

  Excluded (uninstantiated, clock_exclude.txt): g6lc_ai_exec 31.57,
  g6lc_slice_dispatch 29.85, g6lc_shared_tlb 51.25, g6lc_ptw_leg_decode
  53.00 — raw JSON values are not active-profile costs.

Countercases (board file -> measured):
  g6lc_iq_bank ge1/ge2 pair tree   r52 B4   32.3 -> 42.45  (byte-exact revert)
  g6lc_iq_bank e_cancl live read   r54      ruled out pre-edit (dead-entry
                                            displaces live cand; gen_take_dead
                                            unreachable-proof fails)
  alu serial >>> per-result split  r54      27.87 -> 48.05 (byte-exact revert)
  g6lc_iq_arb per-bank 1hot decode r54      32.85 -> 34.21 (byte-exact revert)
  issue_read_operands fus_busy     r54      2 prior prefix-copy cases = 46.4;
                                            28.0 is the deps=80 dependency floor
  load_unit C1 predicate hoist     r57      41.05 -> 41.05 null (input preds
                                            already shared; floor is arm-to-arm
                                            state_d chain) — reverted
  load_unit C2 pub/state split     r57      skipped — only pop_ld/lu_replay/
                                            miss_req remain inside the FSM;
                                            splitting = FSM replication, not
                                            equivalent hoist
  dcache B4 (r52) iq_bank pair     recorded countercase territory, not retried

Witnesses (tag / model / fw / outcome):
  hyp8-osbi-scalar-r28  r51 model       a9218107  20M budget-out, PAST the
                          19,466,403 r51-barrier (all [equiv] counters live,
                          0 divergences); no tohost — liveness witness
  hyp8-osbi-scalar-r29  r56 write-probe a9218107  killed ~13.7M (redundant
                          after r30 proved the banner path)
  hyp8-osbi-scalar-r30  r57 full-probe  a9218107  OpenSBI v1.5 banner CONFIRMED
                          (uart.txt verbatim); alive ~13.9M post-banner
  hyp8-osbi-l3-r2       r55 l3 b40475f8 stock     alive ~24.5M, past r1's
                          483,343 death and the 10.9M fdt discriminator
  hyp8-osbi-smt2-r1     r58 smt2        a9218107  launched ~11:10Z, 60M
  hyp8-osbi-l3-r1       r55 l3          stock     died 483,343 on
                          store_buffer g6lc_spec_entry_live (pre-r47)

### r58d (l3-r2 budget-out; l3-r3 + smt2-r1 launched; r30 platform table)

- hyp8-osbi-l3-r2 FINISHED 30M budget-out, clean: no tohost verdict
  (same framing as r28). Final PC 0x8000eff0. All [equiv] counters
  live at end: fwd_snap checked=2,822,711 (the r58 D1 snapshot check
  ran the whole run — zero divergence), pub_tree checked=29,999,986
  multi=9,458 pfwd=0, tx_single checked=502,462 viol=0, l1_obligation
  dropped=353,370 plain=353,370.
- r30: ~21.25M printed the full OpenSBI platform table verbatim —
  "Platform Name : GSys LibreCore hyp8 simulation", uart8250 console,
  aclint-mtimer @12.5MHz, Runtime SBI Version 2.0, Domain0 root with
  the UART region 0x10000000-0x10000fff R,W mapped (matches DTS).
- hyp8-l3-integration-r58 build_complete (hyp8-l3-r58-closure 824f);
  hyp8-osbi-l3-r3 launched ~11:53Z (80M, stock fw, standard flags,
  UART probes on the r58 L3 model).
- hyp8-osbi-smt2-r1 launched ~11:10Z (60M, g6lc64_hyp8_smt2 model,
  fw a9218107, UART probes).
- r30 at ~22.87M: full OpenSBI cold-boot dump COMPLETE through
  Boot HART MIDELEG=0x0 — Domain0/root, all platform devices, heap
  stats, Boot HART ID/Priv/ISA block. Next bytes = payload output.

### r58e (r30 handoff confirmed; l3-r3 launch bug; smt2-r1 dead-fetch)

- r30: 26,976,331 — still in sbi_hart_switch_mode + sbi_malloc (the
  OpenSBI domain-init handoff); uart_n=2627, last bytes are the
  Boot HART MIDELEG/MEDELEG trailing zeros. No payload PCs yet, no
  trap. ret 5.61M->5.90M ipc 0.28->0.27. Classification (i): still
  printing/handing off — payload entry imminent.
- l3-r3: launch assert bug — my sed clone kept the r55 MODEL_SHA pin
  (b40475f8) vs the r58 model (dc3316c8). Fix: pin updated, relaunch
  as hyp8-osbi-l3-r3b.
- smt2-r1: KILLED (SIGTERM at 15M). [boot] trace shows npc advancing
  (0x10000->0x10040...) — fetch works, but ret=0 forever — the
  bootrom spins in a wait that never resolves on g6lc64_hyp8_smt2.
  Classified: harness/DTS wiring (no SMT2 smoke exists on this
  harness — the smokes run on scalar only). Not an RTL bug.

### r59 arch-redirect skip — fix
Mechanism (probe-verified, `hyp8-probe-r59m5` `[r59]` lines): flushing CSR writes are applied deferred through csr_buffer; `controller.drain_seq` latched `drain_pc_q <= pc_commit_i` at the deferred `flush_csr_i` trigger, by which the commit head had rotated to the younger instruction, so the commit-redirect resumed at `next.pc+4` — dropping exactly one instruction after every flushing CSR (OpenSBI `sbi_hart_switch_mode` lost `csrw mepc` + the `j`→`mret` tail: the r30 infinite loop; no run ever reached the payload). When the pipeline was drained the stale slot read produced arbitrary backward resumes.
Fix: csr pc carried with the registered flush — `csr_write.sv`/`csr_regfile.sv` stamp `commit_instr_i.pc` at `csr_apply` (the retire cycle) into `flush_pc_o`; `smt/g6lc_smt_csr_bank.sv` selects it per hart like `flush_o`; `g6lc_core.sv` routes `flush_csr_pc_ctrl` to `controller.csr_flush_pc_i`; `drain_pc_q <= flush_csr_i ? csr_flush_pc_i : pc_commit_i`; `smt_arch_redirect_pc` uses `pc_commit_fe`. Second defect found by the directed test: the deferred-flush window let the younger marker commit/execute before the squash (t2=2 double-execute) — fixed by `commit_stage.sv` `csr_hold_q` one-cycle commit suppression after every CSR fire.
Verification (`hyp8-integration-r59c`, model sha d243c0e0): lint scalar/smt2 rc=0 (3 LATCH baseline); smokes h34=685/h33=1010/bc=492 identical; `hyp8_csr_flush_skip` `*** SUCCESS ***` 2350 cyc (was 14680193 fail on r58). markerA now retires t2=1 (was 2). r58 closures: hyp8-r59c-closure 820 files, hyp8-r59-leaf-closure 395. Witnesses: r31 launched on r59c (60M); l3-r3b killed; l3-r4 pending r59 L3 build. RVFI gap: flushing-CSR commit records still absent — `commit_drop_o = sel_mem.cancelled` in sb_commit_bundle; the flushing CSR's slot is cancelled when it acks so `commit_ack & ~commit_drop` masks the record (also gates smt_retire_valid) — retirement-observability defect, not fixed.
Board (lead, same argv as r53/r55; `boards/hyp8-core/analyze-r59.{json,cmd}` sha 6db2db2615dc635d): commit_stage 21.50, controller 25.10, csr_regfile 37.37 — unchanged vs analyze-r58b; csr_write/g6lc_smt_csr_bank/g6lc_core carry no clock-setting path; no module rose. The fix is timing-neutral on this board.
Line endings: all five RTL edits preserved their files' existing eol (controller/csr_write LF; csr_regfile/g6lc_core/smt_csr_bank CRLF).

### r59b rvfi dropped-commit records — fix
Mechanism (probe `hyp8-probe-r59rv2`, `[rvp]` lines): flushing-CSR commits are clean at the scoreboard — `mack=1 drop=0 ack=1` at the commit cycle (e.g. t=418, pcc=0x80000010). The records were dropped trace-side: `g6lc_rvfi_probes.sv` stages instr→instr_dly_q→instr_q for the H12 post-write CSR pairing and cleared the whole pack on `flush_i`; the deferred csr_write flush fires one cycle after the ack and killed the staged frame. Same mechanism ate mret/mispredict records (any redirecting instruction whose flush lands while its frame is staged).
Fix (trace-side only, `g6lc_rvfi_probes.sv`): on `flush_i` keep staged frames that captured a real retire (`commit_ack && !commit_drop || ex_commit_valid`) instead of zeroing the pack; csr_q follows its surviving frame.
Verified (`hyp8-probe-r59rv3`, r59c source + fix): `trace_rvfi_hart_00.dasm` now shows `csrw mstatus` @0x80000010 and @0x800002a2 (0x30001073) and `mret` @0x80000214/0x80000332 (0x30200073); `hyp8_csr_flush_skip` still `*** SUCCESS ***` 2350 cyc; smokes on the fixed model identical: h34=685 / h33=1010 / bc=492 (record visibility is trace-side — no cycle delta, as expected).
Note: the r59c integration model predates this trace fix; it lands in the next integration build.
Witnesses: r31 (r59c model, 60M) running — at last poll still in OpenSBI init (~4.3M cyc, PC 0x80012xxx, 0 payload PCs ≥0x80200000 yet); l3-r4 (hyp8-l3-integration-r59, 80M) running. Lint: `hyp8-r59-lint-l3` rc=0, 0 %Error. Board `analyze-r59` (lead): commit_stage/controller/csr_regfile unchanged, no rises.

### r60 arch-redirect + rvfi record fix — integrated
`hyp8-r60-closure` (820 files) + `hyp8-integration-r60b` (model sha 64567e84…): lint scalar/smt2 rc=0 (first attempt's build blocked by witness overlap — relaunched with HYP8_ALLOW_OVERLAP=1); `hyp8-r60-lint-l3` clean (0 %Error all profiles). Smokes `hyp8-r60-*`: h34=685 / h33=1010 / bc=492 — identical; `hyp8_csr_flush_skip` `*** SUCCESS ***` 2350 cyc. Production-model rvfi (`hyp8-r60-hyp8_csr_flush_skip/trace_rvfi_hart_00.dasm`) shows `csrw mstatus` 0x30001073 (4×, incl. 0x80000010 + window-boundary 0x800002a2) and mret records — the r59b trace fix verified on the real build.
Witnesses running: `hyp8-osbi-scalar-r31` (r59c model, 60M; still OpenSBI init, 0 PCs ≥0x80200000 at ~5M) and `hyp8-osbi-l3-r4` (hyp8-l3-integration-r59, 80M).

### r61 open: hyp8-osbi-scalar-r31 kernel-side stall (facts, hypotheses, next checks)
Facts (r31, r59c model, linux-scalar fw a9218107): OpenSBI v1.5 dump complete (uart.txt 2,627 B, through `Boot HART MEDELEG`), `sbi_hart_switch_mode` completed (no 0x8000efxx loop), payload entered ~21.77M, kernel running at high-half VAs (satp live). Trace frozen at cycle 21,945,565 in a 7-instruction poll loop 0xffffffff8005a8ac..a8ba (lw/ld pointer-table walk in kernel data 0xffffffff81216450/480, c.beqz flag test; poll word 0xffffffff81216480 reads constant 0x11). LSQ st[1] id=5 / st[2] id=7 to 0xffffffff81216468 valid, undrained — most likely the speculative post-loop stores re-allocated per iteration (not a drain defect; unproven). iti/rvfi: zero interrupt-cause trap records in the whole run. No kernel UART text (earlycon=sbi → the first printk would appear as SBI console ecalls → UART bytes; none) — the stall is before the first printk.
Platform facts: DTS `riscv,isa` does not advertise sstc (kernel uses the SBI timer path); hyp8 config `SstcEn=1`; DTS timebase 12.5 MHz, clint@2000000 with MTIP/MSIP to CPU0_intc 3/7; OpenSBI reported `aclint-mtimer @ 12500000Hz`.
Hypotheses: H1 a lock/flag wait on a word that an earlier atomic (lr/sc or AMO) left in a bad state (0x11 constant) — pre-irq early boot, which fits "before first printk"; H2 timer-tick wait with no interrupt delivery (CLINT mtime/mtimecmp/time_irq or mie/mideleg) — only if the kernel had already enabled interrupts; H3 store-drain defect — only if ids 5/7 are older than the retiring tid.
Earliest discriminating checks (next session): (1) symbolize the loop PCs/data with a payload-matched vmlinux — candidates: /opt/testharness/cache/openwrt/build_dir/target-riscv64_riscv64_musl/linux-sifiveu_generic/linux-6.6.93/{vmlinux,System.map}; confirm the match by comparing payload.bin against the Image produced by that tree (sha256) before trusting symbols; (2) from the rvfi tail: last sstatus/sie writes (interrupts enabled or not), count of `ecall` with PC ≥ 0x80200000, and any `lr.w/d`, `sc.w/d`, `amo*` records targeting 0xffffffff81216480/468 with their results; (3) if H2: `[hang]` mip/mie/mideleg/mtimecmp/mtime and whether any AXI write hit the mtimer window; (4) if H3: compare st ids 5/7 against the commit pointer in the hang dump.
Witnesses at hand-off: r31 hung (alive, 21.95M, no tohost); l3-r4 (r59 L3 model, 80M) running in OpenSBI init; r28/r30 retired. Boot claim: none — OpenSBI completes and the kernel starts; Linux does not yet reach its console.

### r61 store/AMO readiness deadlock — fix
Root cause (lead): `store_unit.sv` `st_ready = store_buffer_ready & amo_buffer_ready` — under OoO issue a younger AMO reached amo_buffer first (amo_rdy=0 in the r31 [hang] dump) so the older plain store at the SB head could never post (WAIT_STORE_READY), and the AMO never reached commit to free the buffer. Now `st_ready = instr_is_amo ? amo_buffer_ready : store_buffer_ready`.
Evidence: r31 + l3-r4 both wedged identically at ~21.9M/ret=5,984,752 / ~ret=6,614,057 with `SU state=3 tid_q=7 treq=1 dtlb_hit=1 st_ready=0`, `dc_req=0`, LSQ `st[1]/st[2]` to 0xffffffff81216468, head `fu=2 op=62 pc=ffffffff8005a91a`.
`hyp8-r61-closure` (821 files, +hyp8_amo_store_order.S) + `hyp8-integration-r61b` (sha 994d9db9e434f182): lint scalar/smt2 rc=0, `hyp8-r61-lint-l3` clean. Smokes `hyp8-r61-*`: h34=685 / h33=1010 / bc=492 / csr_flush_skip SUCCESS 2350 — unchanged.
Directed test `hyp8_amo_store_order`: FAILED tohost=2 at 942 cyc on BOTH r61b and r60b — does NOT reproduce the wedge (no timeout on the old model) and verdict unchanged by the fix — flagged; the kernel witness is the real proof.
Leaves: rerun on the correct leaf closure (first attempt used the integration closure — missing tb_g6lc_hyp8_memory.sv).
Witness: `hyp8-osbi-scalar-r32` launched on r61b (60M, UART probe, fw a9218107); l3-r4 left wedged on the pre-fix model.

### r61b amo_buffer owner-liveness sweep (lead)
The r61 directed test did not reproduce the wedge on the old model (hyp8 memory-op ordering did not let the younger AMO ahead of the older store), which points at the alternative mechanism for r31: a wrong-path AMO posted into the depth-1 amo_buffer AFTER its cancel pulse had expired (T35 lifetime), i.e. a DEAD entry no commit will ever pop — same class as the r47 arbiter and csr_buffer liveness sweeps. `store_unit.sv`: `amo_cancel` now also fires on `!sb_live_i[amo_tid_q]` (flush_amo_buffer still refuses while amo_valid_commit_i). The r61 st_ready decoupling stays (it is independently correct). Test `hyp8_amo_store_order.S`: v2 chain fixed (was storing to address 0 — the tohost=2/raw 5 fail on both models), new v4 trains a branch not-taken then takes it after a slow chain so the fall-through amoadd is speculatively issued and cancelled; the correct path then needs the buffer (wedge = budget-out) and checks lock2 unchanged by the wrong path.

### r61c store/AMO liveness sweep — fix v2
Second mechanism (lead): `store_unit.sv` `amo_cancel` now also fires on `!sb_live_i[amo_tid_q]` — a wrong-path AMO posted after its cancel pulse expired is a dead entry nothing pops (same class as the csr_buffer liveness sweep). r61 st_ready decoupling retained. Test `hyp8_amo_store_order.S` fixed (v2 addr-0 bug) + v4 (branch-trained not-taken, last iteration taken after a slow chain → fall-through amoadd speculatively issued+cancelled; lock2 must stay 7).
`hyp8-r61c-closure` (821) + `hyp8-integration-r61c` (build_complete) + `hyp8-l3-integration-r61c-2` (L3, build_complete): lint scalar/smt2 rc=0, `hyp8-r61c-lint-l3` clean (lint_complete, 0 %Error).
Smokes (all five SUCCESS): h34=685 / h33=1010 / bc=492 / csr_flush_skip=2350 / amo_store_order=SUCCESS 2091.
Non-vacuity check: `hyp8_amo_store_order` also SUCCESS at 2091 on the OLD `hyp8-integration-r60b` model — the directed test still does NOT trigger the deadlock on the buggy model (the microbench can't create the younger-AMO-holds-buffer-while-older-store-waits interlock); it is functional coverage only, the kernel witness is the wedge reproducer.
Leaves (r61c-leaf-closure, 395): HYP8_ISSUE_PASS checked=99 + HYP8_MEMORY_PASS checked=152, rc=0, warnings=none.
Witnesses: r32 + l3-r4 killed; `hyp8-osbi-scalar-r33` launched on r61c (60M); `hyp8-osbi-l3-r5` launched on `hyp8-l3-integration-r61c-2` (80M) — both alive. Next watchpoint: whether they clear the ~21.9M-cycle 0xffffffff8005a91a store-translation wedge.

### r62 open: hyp8-osbi-scalar-r33 (r61c) wedges at the same kernel AMO (facts + next check)
r33 (r61c: st_ready decoupling + amo_buffer liveness sweep) froze with the identical `[hang]` block as r31 (cyc≈21,949,773): SB head slot 3 = fu STORE-class op 62 (AMO) pc 0xffffffff8005a91a, issued=1 valid=0; SU state=WAIT_STORE_READY tid_q=7 treq=1 dtlb_hit=1 st_ready=0; amo_rdy=0 (amo_buffer occupied); STQ spec=0 commit=0; LSQ st[1] id=5 / st[2] id=7 addr 0x...81216468 (= x9+0x18, the AMO target) addr_v=data_v=1; IQ holds AMO instances at the same pc (slot 11 op 62, slot 9 op 64) with ready=0010010; LSU bypass cnt=1 (e1 fu=2 tid=5); dc_req=0; no interrupt/ecall records.
Reading: with `st_ready` for an AMO = amo_buffer_ready, state 3 + amo_rdy=0 means the SU is holding an AMO (slot 7) behind an AMO already in the depth-1 amo_buffer (slot 5), while the commit head (slot 3) is a third AMO instance with no result. AMOs are a head-only IQ class (g6lc_iq_legal C_AMO: legal only when tid == commit_ptr, registered compare), so slots 5 and 7 can only have issued when they were at the head — i.e. they are OLDER instances of the spin-loop AMO that already retired (or should have) and whose amo_buffer/LSQ bookkeeping was never released, OR slot 3's AMO issued and was dropped from the LSU without a result (T40 pop / replay path) so the head can never complete. The r61 fixes were correct in their own right but are not the owner of this wedge.
Earliest discriminating check (next session): windowed trace from the first issue of the slot-3 AMO (pc 0xffffffff8005a91a): per cycle — IQ take of slots 3/5/7 (legal/at_head), lsu_bypass push/pop with tid, SU state/trans_id_q/valid_o/pop_st_o/translation_req_o/dtlb_hit_i/ex_i.valid, amo_buffer push/pop/flush with amo_tid_q and amo_resp.ack, commit amo_valid_commit/commit_ack for the AMO slots, LSQ st alloc/release for ids 3/5/7, and the branch resolution/cancel pulses of the loop. Expected outcomes: (a) an AMO retired without its amo_buffer pop (amo_resp.ack missed → fifo full forever) → fix the pop/ack handshake; (b) slot 3 popped from the bypass without posting (exception/replay pop with no re-issue) → fix the pop path; (c) a retired AMO's LSQ st entry never released → LSQ release for AMO class.
Also noted: `hyp8_amo_store_order.S` passes on both old and fixed models (v1–v4 do not reproduce the wedge; coverage only) — the kernel witness remains the reproducer; a directed test for the spin-loop AMO shape (amoswap in a predicted loop, branch resolving late) is still to be written once the mechanism is pinned.
Witnesses at hand-off: r33 wedged (alive, no tohost), l3-r5 running (r61c L3, 80M; expected to wedge the same way), r31/r32/l3-r4 killed.

### r63 timing-hoist pass
Edits (equivalent rewrites, no functional change):
- `ooo/g6lc_rename_recover.sv`: `ckpt_cnt_pre` wire carries base+reserve+repair; retire loop reads the wire and writes `ckpt_cnt_d[h]` once per hart (was RMW across 4 legs).
- `g6lc_mmu/g6lc_tlb.sv`: `row_inval[i]` per-row generate wires flatten the RVH sfence/vvma/gvma arm chain; `tags_n[i].valid` is a two-arm mux (inval | update).
- `ooo/g6lc_iq_arb.sv`: `pres_live[p]`/`win_live[p]` hoisted; presentation split into control block (valid+ack) and payload block (payload driven whenever a record is present; live source selected by pres_live — pres_q[p].v-only sel would leak stale payload when pres is dead-but-set behind a live win).
- `sb_lifecycle.sv`: `issue_open[i] = ~issue_full[i]` wire; offer/ack cone reads the wire.
- `g6lc_mmu/g6lc_shared_tlb.sv`: `patched_pte = '0` default in tag_comparison (removes the dormant latch — documented).
Verification: `hyp8-r63-closure` (821) + `hyp8-integration-r63` (sha 01721c8b73b0b1, build_complete): lint scalar/smt2 rc=0; `hyp8-r63-lint-l3` clean (0 %Error all profiles). Smokes all five SUCCESS — h34=685 / h33=1010 / bc=492 / csr_flush_skip=2350 / amo_store_order=2091 (identical to r61c — rewrites are neutral as expected). Leaves (r63-leaf-closure, 395): HYP8_ISSUE_PASS checked=99 + HYP8_MEMORY_PASS checked=152, rc=0.
Not yet done: `g6lc_ptw_leg_decode` L174 and `ooo/g6lc_slice_dispatch` L202 hoists + `shared_tlb` L579 dependency hoist (excluded-module measurement items), `analyze-r63.json`/`analyze-r63-all.json` board runs (sv-timing toolchain is lead-side).

### r63 lead review + board (analyze-r63.json sha c058046d35d7b263, argv in analyze-r63.cmd)
- g6lc_tlb per-row `tags_n` split: 30.85 -> 48.62 (dense-control-cone billing of the per-row generate) — COUNTERCASE, reverted byte-exact to the r61c pin (sha d7dbb51b).
- g6lc_rename_recover ckpt_cnt_pre hoist: 31.80 -> 31.80 (null) — reverted byte-exact (c273cd24); the 31.8 is the bundle makespan on 26 LHS with max_field 11.0 and no intra-block dependency to hoist — a floor under this analyzer.
- g6lc_iq_arb pres_live/win_live + control/payload split: 32.85 -> **30.61** regtoout L826 — KEPT (payload select by pres_live is the equivalent form: a dead-but-set pres with a live win must serve the win payload).
- sb_lifecycle issue_open wire: 25.87 -> **24.87** — KEPT.
- g6lc_shared_tlb `patched_pte='0` default: 51.25 unchanged (excluded arm) — KEPT as the dormant-latch fix; its dependency hoist, g6lc_ptw_leg_decode L174 and g6lc_slice_dispatch L202 remain TODO (r64).
- Hygiene: the sidekick's edits re-encoded three files' non-ASCII comment characters (cp1252 mojibake) and wrote g6lc_iq_arb.sv with LF; the lead restored the exact bytes (per-line cp1252->utf-8 inverse) and CRLF; diffs vs the r61c pins now contain only the intended RTL lines (iq_arb 34 lines, sb_lifecycle 8, shared_tlb 2). No module rose on the active board (g6lc_rvfi_probes 7.5->8.5 from the r59b trace fix).
- Lint/smokes/leaves of the sidekick's r63 run (hyp8-integration-r63 sha 01721c8b) covered the tlb/rename_recover variants that are now reverted; the kept set is a subset, re-gated in the next integration.

### r64 S6 excluded-arm hoists (partial)
- `g6lc_mmu/g6lc_ptw_leg_decode.sv` L174: shared leaf-PTE predicates hoisted to wires `leg_ppn_hi_err`/`leg_misaligned`/`leg_gtrans_i_ok`/`leg_gtrans_d_ok` — the two identical ppn-high guards, the misaligned gate, and both g-translation conditions now evaluate once.
- Pending (not applied): `ooo/g6lc_slice_dispatch` L202, `g6lc_mmu/g6lc_shared_tlb` L579 dependency hoists; `analyze-r64-all.json` board + closure-only lint configs (UseSharedTlb=1/PtwDecodeStage=0/SliceOoOEn=1).
- `hyp8-r64-closure` (821) + `hyp8-integration-r64` build_complete, lint scalar/smt2 rc=0; smokes all five SUCCESS (685/1010/492/2350/2091 — identical).

### r62 probe status
`hyp8-probe-r62b2` probe model built (store_unit/amo_buffer/commit_stage/iq_arb/lsu_bypass/g6lc_lsq/controller +r62_trace windowed displays, window 21.9M-21.96M); `hyp8-osbi-scalar-r34p` launched (linux fw a9218107, 22.2M) — running, pre-window. First probe build attempt failed on a non-signal `take` in iq_arb; fixed.

### r64 S6 lead measurement
- g6lc_ptw_leg_decode predicate hoist: 53.0 -> 53.0 (analyze-r64.json sha 40510e4243f4bbd3) — null: the limiter is the `leg_state_d` unique-case crit arm (28.5, prep_arm 28.5), not an intra-block dependency; reverted byte-exact to the r63 pin. The PDEC=0 arm would need the same bundle-capture split the active PDEC arm got in r43-T (a stage, config-gated) — recorded under r64-program S6 as a stage item, not a hoist.
- slice_dispatch L202 / shared_tlb L579 hoists and the closure-only lint trio remain TODO (sidekick context-limited; one item per handoff).

### r62 probe result — AMO-buffer self-deadlock mechanism (evidence)
Witness `hyp8-osbi-scalar-r34q` on probe model `hyp8-probe-r62c` (+fetch_win_trace windowed displays in store_unit/amo_buffer/commit_stage/iq_arb/lsu_bypass/g6lc_lsq/controller, window 21.9M-21.96M); 420,006 `[r62]` lines; wedge reproduced at ~21.9458M (75 [hang] dumps, budget-out 22.2M, ret frozen at 5,984,752 as r31/r33).

Timeline (cycles):
- ~21.900.0xx-21.945.5xx: normal flow — plain stores (op 0x25/0x26) through SU (state_q 00->01->00, pop_st_o pulses); amo_buffer empty (amo_valid=0). Earlier AMOs committed correctly (21924023 push with amo_valid_commit_i=1 -> amo_resp.ack=1 at 21924038 -> commit_ack at 21924062, pc=0xffffffff8065b814, amo_valid_commit_o=1 flush_commit_o=1).
- cyc 21,945,777: `amo_buffer valid_i=1 no_st_pending_i=1 amo_valid_commit_i=0 flush_i=0 cancel_i=0` — a SPECULATIVE AMO push lands with NO commit validation. From 21,945,778 on: `amo_valid=1` permanently, `cancel_i=0`, `cancelled_mask_i=0` — the entry is never cancelled (its tid is live — the head AMO's own slot).
- Frozen state (identical 21.9459M→22.1999M): `store_unit state_q=11(WAIT_STORE_READY/3) instr_is_amo=1 trans_id_q=7 st_ready=0 amo_buffer_ready=0 translation_req_o=1 dtlb_hit_i=1 lsu_ctrl.vaddr=0xffffffff81216468`; `commit_stage pc=0xffffffff8005a91a fu=2 op=3e valid=0 amo_valid_commit_o=0`; `controller` all flush legs 0.

Mechanism: the head AMO (pc=0xffffffff8005a91a, LSQ st[2] id=7, vaddr 0xffffffff81216468) speculatively pushed into amo_buffer at 21945777 while amo_buffer_ready was momentarily 1; the FSM stayed in WAIT_STORE_READY — the push consumed the sole buffer slot but was not marked posted. The resident entry can only fire on `amo_req = no_st_pending & amo_valid_commit & amo_valid`; `amo_valid_commit_o` requires the commit-head AMO to be `valid`, which requires the SU's result, which requires the entry to fire — self-deadlock. No cancel/flush leg ever fires for the entry (sb_live sees it live).

Owner: store_unit.sv AMO post/FSM handshake — either the state must advance on the accepted push (register the post) or `st_ready` must treat a resident own-tid entry as already-posted; the `treq=1 dtlb_hit=1` field is the same stale signal observed in the unprobed [hang] dumps (the SU is simultaneously asserting a DTLB request that reports hit — part of the same held cycle).

Artifacts: /opt/testharness/runs/hyp8-osbi-scalar-r34q/run-hyp8.log (420k r62 lines + 75 hang dumps), /opt/testharness/runs/hyp8-r62-ev/output/pull_r62_events.log (event extraction), tools/pull_r62_tail.py + pull_r62_events.py.

### r62 fix (lead): store_unit duplicate-AMO self-deadlock
Mechanism (r34q probe): an AMO already posted into the depth-1 amo_buffer is presented to the store unit AGAIN (same trans_id at the bypass head — a replay re-issue after the first copy had posted; the SB entry's valid was cleared by the replay so the head shows valid=0). The second copy waits in WAIT_STORE_READY on amo_buffer_ready, which only clears when the resident entry fires on amo_valid_commit — which needs the head's result — which needs this request: self-deadlock (Linux first spinlock, ret frozen at 5,984,752 on r31/r33/r34q).
Fix: `amo_dup = valid_i && instr_is_amo && !amo_buffer_ready && (amo_tid_q == lsu_ctrl_i.trans_id)`. IDLE accepts the duplicate even with st_ready=0 (pop + VALID_STORE); VALID_STORE re-publishes valid_o but suppresses the second push (`amo_dup_q`); WAIT_STORE_READY exits on amo_dup. translate_off counter `[equiv] store_unit amo_dup: consumed=N` (+stq_trace prints each). The r61/r61c changes stay. Still to establish: WHY the AMO was re-issued (replay of a head-only op) — a replay of a posted AMO should be impossible or should flush the buffer; tracked as r62b.

### r65 store_unit amo_dup fix — verification
Lead fix in store_unit.sv: `amo_dup` consumes a re-presented AMO whose own entry is already resident in amo_buffer (re-publishes valid_o without a second push; `[equiv] store_unit amo_dup: consumed=N` counter). `hyp8-r65-closure` (821) + `hyp8-integration-r65` (sha 49c41cc904ca5d, build_complete): lint scalar/smt2 rc=0; `hyp8-r65-lint-l3` 0 %Error all profiles. Smokes all five SUCCESS — h34=685 / h33=1010 / bc=492 / csr_flush_skip=2350 / amo_store_order=2091 (identical). Leaves (r65-leaf-closure, 395): HYP8_ISSUE_PASS checked=99 + HYP8_MEMORY_PASS checked=152, rc=0.
Witness `hyp8-osbi-scalar-r35` launched on r65 (60M, linux fw a9218107, +stall_census +hang_dump=2000 +equiv_report +rvfi_cycle_stamp) — watchpoint: crossing the ~22.3M-cycle AMO self-deadlock point where r31/r33/r34q froze.

### r62b root cause (lead): stale at_head legality on IQ entry re-allocation
r34q event list: tid-5 AMO (op 0x40) issued at 21,945,775 and posted into amo_buffer at 21,945,777 while the commit head was the OLDER tid-7 AMO (pc 0xffffffff8005a91a, valid=0); tid 7 then waits in WAIT_STORE_READY on amo_buffer_ready forever (its result is what amo_valid_commit needs). AMOs are a head-only IQ class, so a younger AMO must never issue: `g6lc_iq_legal` computes `at_head_d[b][e] = (info_tid == commit_ptr_i)` registered to `at_head_q`, and `legal_d` registered to `legal_o` — at_head_q is one cycle staler than the entry's class/tid. When an IQ entry is re-allocated right after its previous head-only occupant left from the head, the stale at_head_q=1 makes the NEW occupant legal for one cycle; a ready AMO (spin-loop operands are ready) issues non-head. Fix: `legal_d` requires `at_head_q && (info_tid_i == commit_ptr_q)` (live tid vs registered pointer) — rejects the stale bit, keeps the "legal the cycle after it reaches the head" contract. The r62 `amo_dup` SU handling and r61/r61c changes stay (defensive; `amo_dup` consumed=0 expected). Verification: hyp8-integration-r66, smokes, issue leaf, lint x3, witness r36.

### r66 iq_legal at_head staleness fix — verification
Lead fix in `ooo/g6lc_iq_legal.sv`: `at_head_q` is one cycle staler than the entry's class/tid — a re-allocated IQ entry inherited at_head=1 and let the younger tid-5 AMO issue non-head (speculatively posting to amo_buffer before its commit turn). `legal_d` now requires `at_head_q && (info_tid_i == commit_ptr_q)`. `hyp8-r66-closure` (821) + `hyp8-integration-r66` (sha f090ec28d85bce, build_complete): lint scalar/smt2 rc=0; `hyp8-r66-lint-l3` 0 %Error all profiles. Smokes all five SUCCESS — h34=685 / h33=1010 / bc=492 / csr_flush_skip=2350 / amo_store_order=2091 (identical). Leaves (r66-leaf-closure, 395): HYP8_ISSUE_PASS checked=99 + HYP8_MEMORY_PASS checked=152, rc=0.
Witness `hyp8-osbi-scalar-r36` launched on r66 (60M, linux fw a9218107, +stall_census +hang_dump=2000 +equiv_report +rvfi_cycle_stamp) — watchpoint: crossing the ~22.3M-cycle AMO self-deadlock point where r31/r33/r34q/r35 froze.

### r62c open (lead): r36 wedges identically after the at_head fix — refined hypothesis + next probe
r36 (r66: iq_legal live tid compare + SU amo_dup + r61/r61c) wedged with the same signature (ret 5,984,752; SU WAIT_STORE_READY tid 7; amo buffer resident; commit port0 pc 0xffffffff8005a91a op 0x3e valid=0; `[hang]` commit_ptr=3). The r34q event list shows the loop body has TWO AMOs: pc 0x...a91a (op 0x3e) and pc 0x...a922 (op 0x40); bypass program order per iteration is tid3(store 0x26) -> tid5(AMO 0x40 @a922) -> tid7(AMO 0x3e @a91a of the next iteration). tid 5 pushed into amo_buffer at 21,945,777 (amo_valid_commit_i=0), tid 7 then stalls behind it.
Refined reading: tid 5 (a922, iteration k-1) is OLDER than tid 7 (a91a, iteration k) in program order and may well have issued legitimately at the head; the deadlock then is that the COMMIT PORT presents slot 7 (pc a91a, valid=0) while the resident buffer entry belongs to slot 5, so `amo_valid_commit` (which needs the presented head to be the valid AMO) never rises for slot 5 — i.e. a commit-presentation/reclaim-pointer disagreement (sb_commit_bundle port-0 select vs scoreboard commit_ptr; MixedSmt head select / privileged-head reroute) rather than an issue-legality or buffer-readiness defect. The `[hang]` line `SB head slot=3 ... commit_ptr=3` with port0 pc a91a (slot 7) is consistent with port 0 not presenting commit_ptr.
Next probe (one run, r62 model rebuilt on r66, window 21.94M-21.95M): per cycle print scoreboard commit_ptr, sb_commit_bundle sel_oh/p0 selection terms (priv, p0_oh, cptr_oh, head_slot_i/head_valid_i), commit port0 {slot, tid, pc, op, valid, issued, cancelled}, iq_legal at_head_q/legal_o for the IQ entries holding tids 3/5/7, amo_buffer push tid (trans_id_q at valid_i), amo_valid_commit_o. Expected: identify why slot 5's AMO is not presented at port 0 when it is the oldest unreclaimed entry (or, if commit_ptr really is 7, why tid 5 was legal). Fix follows from that answer; the three defensive changes already landed stay.
Verification state of the r66 tree: lint x3 clean, five smokes identical (685/1010/492/2350/2091), issue/memory leaves pass. Witness: r36 wedged (no tohost); l3-r5 stale (pre-r62 model) — kill at next session start.

### r62c probe result (r66 tree, r37p witness)
Wedged identically (ret=5,984,752, budget-out 22.0M); 100,010 [r62] lines. Key events: flush at ~21945736 (commit_ptr 13→0, head_valid_c_o=0); commits remarched 0→1→3; head = SB tid 3 (pc=0xffffffff8005a91a op=0x3e, the AMO). LSU id 5 AMO (op=0x40) pushed into amo_buffer at 21945786 while commit_ptr=3 (non-head); LSU id 7's AMO (op=0x3e — the head's own LSU-side request) presented at 21945790 and locked SU state 11 trans_id_q=7 forever. amo_dup consumed=0 — resident entry is LSU id 5, held request is id 7 — different ids, not a re-presentation. Port 0 presents commit_sel_slot_i[0]=00011 throughout the freeze.

### r62c probe result — lead reading
r37p (r66 probe model) events: 21,945,719 LSU id 21 AMO (op 0x3e) posts normally; 21,945,729 id 23 AMO (0x40) waits; **21,945,736 a flush** (SB commit_pointer 13 -> 0, epoch bump) ; 21,945,782 the commit head is SB slot 3 = AMO op 0x3e pc 0x...a91a with issued=1 valid=0; 21,945,784 LSU request id 5 (op 0x40) arrives and posts into amo_buffer at 21,945,786 (not at head); 21,945,790 LSU request id 7 (op 0x3e) arrives and freezes in WAIT_STORE_READY; slot 3's own LSU request never appears after the flush; slot 5 is never presented at port 0; commit_ptr stays 3.
Two sharpened hypotheses: (H-A, favoured) the flush at 21,945,736 cleared the lsu_bypass/store-unit request of the already-ISSUED head AMO (slot 3) while the scoreboard kept the entry (issued=1) — an orphaned request: the entry can never obtain a result and the pipeline wedges behind it (the younger AMOs 5/7 then merely decorate the wedge). Owner: the flush class raised at 21,945,736 (which legs? frontend redirect / flush_unissued / mem replay) vs lsu_bypass's flush handling — the bypass must only drop requests whose SB entries are also squashed, or the scoreboard must clear `issued` for dropped requests so they re-issue. (H-B) tids 5/7 issued despite the head-only class — check whether their IQ takes preceded the flush (then legality is irrelevant) or followed it (then the r66 gate did not hold). Discriminator: the same probe window with `[r62:controller]` flush legs decoded at 21,945,736 and the lsu_bypass flush/pop lines for id 3 (or whichever id slot 3's request carried) between 21,945,700 and 21,945,740, plus the IQ take cycles for ids 5/7.
State at hand-off: r66 tree lint x3 clean, five smokes identical, leaves pass; witnesses r36/r37p wedged at 21.95M; l3-r5 killed. No boot claim.

### r62c flush census
Flush at 21945735-39: flush_if/id/ex=1 with set_pc_commit_o=1 at 21945739 (commit-driven redirect); cancelled_mask_i=0 throughout (full-slot clear, not masked cancel). Pre-flush in-flight LSU reqs: id 21 op 0x3e (pushed buffer @21945719), id 23 op 0x40 (@21945729), id 25 op 0x3e (@21945735) — all dropped by the flush; LSU ids restart post-flush (id 0 @21945766). Post-flush order: head becomes SB tid 3 @21945782 (pc=0xffffffff8005a91a op=0x3e valid=0); LSU id 5 (AMO op 0x40) issues @21945784 → buffer push @21945786; LSU id 7 (AMO op 0x3e = the head's own LSU-side request) issues @21945790 → SU locks state 11 trans_id_q=7. LSU trans_ids are allocated in LSU-arbitration order (younger AMO won the race), NOT SB program order.

### r62c flush census — lead reading and hand-off
Facts: commit-redirect flush (set_pc_commit at 21,945,739; flush_if/id/ex 735–739) restores the SB pointer 13 -> 0; the three in-flight LSU AMO requests (ids 21/23/25) are dropped with their SB entries (correct: they belong to the squashed window). Post-flush allocation is program-ordered 0,1,2,3(AMO @a91a = head),4,5(AMO @a922),6,7(AMO @a91a next iteration). LSU requests then arrive as id 0 (store), id 5 (AMO, younger) at 21,945,784 -> posts into amo_buffer at 21,945,786, id 7 (AMO, younger) at 21,945,790 -> WAIT_STORE_READY; slot 3's own LSU request never appears although `issued=1`; commit port 0 presents slot 3 (valid=0) forever. `[hang]` op values are hex (op=62 -> 0x62 AMO_MINDU-range AMO; 64 -> 0x64) — both are AMO-class (SU instr_is_amo=1).
Two defects to separate (both post-flush): (D1) head-only legality did not hold — slots 5 and 7 (AMO class) issued while commit_ptr was 3; the r66 live compare makes this impossible IF `commit_ptr_i` wired into g6lc_iq_legal is the scoreboard commit pointer the probe printed — check the wiring (issue_stage -> g6lc_iq -> g6lc_iq_legal `.commit_ptr_i`) and print at_head_q/legal_o for the entries holding tids 3/5/7 at 21,945,780–790; (D2) slot 3's issued request is missing from the LSU: trace the IQ take of tid 3 (g6lc_iq_bank take_v/cand for the entry with tid 3) and the lsu_bypass push — if it was taken and never pushed (or pushed and dropped by the tail of the drain flush at 739), the fix is in the issue->bypass handoff across the counted drain (a take in the drain's last cycles must either be replayed or must clear `issued`). Defensive fix regardless (lead design, not yet applied): in store_unit accept AMOs only when `lsu_ctrl_i.trans_id == commit_tran_id_i` (the committing/head tid) — `st_ready = instr_is_amo ? (amo_buffer_ready && at_head) : store_buffer_ready` — so a younger AMO can never occupy the depth-1 buffer ahead of the head; with D2 fixed this gate is never exercised (assert-and-count it).
- r62c defensive gate applied (lead): store_unit `st_ready` for AMOs = `amo_buffer_ready && (lsu_ctrl_i.trans_id == commit_tran_id_i)`; a younger AMO can no longer occupy the depth-1 buffer ahead of the head. D1/D2 investigation (why slots 5/7 issued non-head post-flush; where slot 3's request went) remains open and is the next probe.

### r67 amo_at_head gate — verification + smoke regression
Lead fix in `store_unit.sv`: `st_ready` for AMOs = `amo_buffer_ready && amo_at_head` where `amo_at_head = (lsu_ctrl_i.trans_id == commit_tran_id_i)` — AMOs post only at commit head. `hyp8-r67-closure` (821) + `hyp8-integration-r67` (sha 5d76323255117d, build_complete): lint scalar/smt2 rc=0; `hyp8-r67-lint-l3` 0 %Error all profiles. Smokes: h34=685 / h33=1010 / bc=492 / csr_flush_skip=2350 SUCCESS — **hyp8_amo_store_order FAIL: wedged 400k cycles, no tohost verdict, ret halted at first AMO (PCs ~0x80000144-48, loads retiring before it)**. Leaves: HYP8_ISSUE_PASS checked=99 + HYP8_MEMORY_PASS checked=152 rc=0 (memory leaf's AMO cases did not stall — bench drives the head tid correctly). Regression hypothesis: the younger/early AMO request can occupy the single store_unit lane waiting on `amo_at_head` while the actual head instruction can't reach the SU to complete — commit_ptr never reaches the AMO's tid — a new circular dependency upstream of the buffer (no RTL change made; directed test unchanged). Witness `hyp8-osbi-scalar-r38` launched on r67 (60M, linux fw, +equiv_report) — will report whether the kernel AMO path wedges early or reaches the ~22.3M point.

### r67 countercase + D1 probe (lead)
The r67 SU gate (AMO posts only when trans_id == commit_tran_id_i) deadlocked `hyp8_amo_store_order` at its first AMO (400k, no tohost) while h34/h33/bc/csr_flush_skip stayed green and r38 (linux) kept retiring to ≥20M. The `+iqleg_trace` probe (hyp8-probe-iqleg) shows the v1 AMO (tid 0x0c, cls C_ST|C_AMO) is NEVER taken: legal_i=1 at cyc 434 (ready=0), then legal_o cleared from 435 on with commit_ptr_i==0x0c (it is the head) — the entry is held by a legality term other than the head compare: the store-order arm `!(is_st && older_st)` (st_front frontier) or the at_head bit index (the probe's at_head_q bit 24 may not be this entry's). The SU gate turned this latent IQ-side stall into a wedge; without the gate the AMO was posted by a path that is not the normal take (to be identified: dispatch-time lsu path / a take not logged). Gate WITHDRAWN (store_unit back to r61c st_ready form); r61/r61c/r62 amo_dup and the r66 iq_legal live compare stay. Next: (1) in g6lc_iq_legal print the four legal_d terms separately for the AMO entry (head_only arm, is_ld arm, is_csr arm, is_st/older_st arm with st_front_v_q/st_front_tid_q) on the directed test; (2) find the path that issues an AMO when legal_o=0 (grep iq_bank take gating and any LSU dispatch bypass); the fix is at that path — AMOs must issue only via the legal head-only take.

### r68 D1 + mc target prep
**D1 (iqleg term probe, probe models hyp8-probe-iqleg2 / hyp8-probe-iqleg-r67):** `hyp8_amo_store_order` + `+iqleg_trace`. Term breakdown for the wedging run's stuck AMO entry: `b=4 e=0 tid=0x12 cls=0010010` (C_ST|C_AMO) with `commit_ptr=0x0c` — the AMO is YOUNGER than the head and correctly `legal_d=0` (t_hd=1 since tid!=ptr_q; t_st=1 since st_front=0x0e older). The real freeze: `commit_ptr0` pinned at `0x0c` forever — the head op (tid 0x0c, cls=0000001 C_LD taken at cyc 430 legal=1) never completes because its LSU request sits behind the younger AMO's gated SU request in the lsu_bypass FIFO — LSU-ordering head-of-line deadlock, not IQ legality. On the passing run (current tree, r67 gate withdrawn): same AMO stays illegal while younger (correct), reaches head at ~cyc 713 (ptr=0x12, sfront=self) -> legal_d=1 -> issue; SUCCESS 2091 cycles. Other AMOs take with legal_i=1 ready=1 (real issues); legal_i=0 takes (cyc 1144/1174/1248/1278) are kill/cancel-path takes of dead entries.
**r38 verdict (r67 gate):** wedged at cyc=21947800, ret=5,984,752 — SU `state=3 tid_q=5` (the YOUNGER AMO's request holds the store-unit lane, not the head's own tid 7/3); `st_ready=0` forever because commit_ptr can't reach tid 5 while the head AMO's LSU request waits behind tid 5 in the LSU FIFO. The amo_at_head gate moved the circular wait from amo_buffer to store_unit + starves older LSU traffic — reverted by lead; store_unit back to r61c form.
**mc target:** g6lc64_hyp8_mc_config_pkg.sv created (NrCores=4, NrHarts=1, NrIssuePorts=8, L2 256KiB/L3 1MiB unconditional, SnoopFilterEn=1, CohInvalDepth=4, CohAxiStarveLimit=16); Flist.hyp8_mc_sim swaps the config pkg; hyp8-build-harness.sh gained g6lc64_hyp8_mc (TARGET_HARTS=4); g6lc-hyp8-mc.dts + g6lc-hyp8-mc-linux.dts (4 cpu@/intc, 4-hart clint/plic, L2/L3 nodes; dtb sha 08f301e8); linux-mc fw profile in build_boot_firmware.py; run_hyp8_integration.py gained HYP8_BUILD_TARGET env + HYP8_LINT_MC mc lint profile (mc flist). hyp8-mc-integration-r1 building.

### r68 lead synthesis — the kernel wedge owner, refined to one discriminating check
Established: (1) AMOs only issue head-legal via the normal take; (2) takes with legal_i=0 exist as KILL-PATH takes of cancelled entries; (3) the lsu_bypass is a single in-order FIFO into one store_unit lane, so a stalled store-class request at its head blocks every request behind it, including an older one; (4) in the kernel wedge the post-flush LSU requests id 5 (AMO @a922) and id 7 (AMO @a91a) arrive BEFORE the head slot 3's own request and cannot have been head-legal (commit_ptr went 0->1->3). Therefore ids 5/7 were most likely NOT live issues of the post-flush slots 5/7 but DEAD pre-flush IQ entries taken through the kill path (or surviving in the arb's staged registers across the flush) whose cancel-mask bit had expired and whose tid had just been re-allocated to live post-flush instructions — the request enters the LSU with a reused tid, posts into amo_buffer (owner-liveness sweep sees the NEW live slot 5 and keeps it), and the second dead request blocks the bypass head in WAIT_STORE_READY, starving slot 3's real request behind it. This is the r47 class (cancel lifetime vs late consumer) at the IQ->LSU seam.
Discriminating check (one grep on the r37p/r62 log, no sim): for the LSU requests id 5 @21,945,784 and id 7 @21,945,790, find the IQ/arb take lines that produced them (bank/entry, legal_i, source pres/win/win_s) and the DISPATCH cycle of those IQ entries. Dispatch before the flush at 21,945,735 => dead entry survived the flush (find the register: iq_bank entry valid, arb win_q/pres_q/win_s, lsu_bypass) and the fix is to clear it on flush_i / drop its request (also: a kill-path take must never assert issue_valid toward an FU). Dispatch after => revisit legality.
Changes standing from r61–r67: st_ready decoupling, amo_buffer liveness sweep, SU amo_dup, iq_legal live compare (all verified; none is the owner). The r67 SU gate is withdrawn (countercase).

### r68 — IQ legality occupant identity (D1 owner), lr_sc window consequence, int-dot pipeline (2026-10-26)
Lead-authored. Reasoning lenses: coding-philosophy §0 (weigh links, change the surviving mechanism), workflow P2/P4/T1/T2/T6/T7/T9, heuristics H1/H2/H5, RT-P2 (identity precedes correlation), RT §4.4 (repetition is not generality), ALGORITHMS A120/A134 (facts registered at their update edge).

SEGMENT CARD
  QUESTION      Why do post-flush head-only ops (lr.d/sc.d, tids 5/7) issue while commit_ptr=3, and why does the head lr.d (tid 3) never reach the LSU (r62c D1/D2)?
  ENVELOPE      g6lc64_hyp8 r66/r67 trees; r37p/r34q probe facts; hyp8_amo_store_order r67 wedge and the lead's iqleg term probe (r68 D1).
  CONTRACT      g6lc_iq_legal: "a bit may stay 0 a cycle longer, never 1 too early" — for the occupant it serves.
  OBSERVATIONS  (a) r37p: younger head-only tids issued ~6 cycles after allocation with ready operands; (b) iqleg probe: "takes with legal_i=0" at cyc 1144/1174/1248/1278 — but g6lc_iq_arb.take_v_o fires only on take_grant, which excludes every killed record, so those are NOT kill-path takes; (c) the directed test hyp8_amo_store_order was written on the premise "under OoO the younger address-ready AMO reaches the amo_buffer first" — i.e. non-head AMO issue was the observed normal; (d) legal_d reads the entry's record with no liveness term and legal_o is one register behind it.
  MECHANISM     legal_o(t+1)=legal_d(t) is computed from whatever record slot (b,e) holds at t. A new occupant lands at A+2 (pend-staged alloc); legal_o(A+2) was formed at A+1 from the STALE record (invalid, previous class/tid). For a stale non-ordering class (every slot after reset/flush: cls=0; most slots in steady state) legal_d=1, so a fresh head-only/load/store/CSR entry whose operands are ready at dispatch is a candidate in its first live cycle regardless of commit_ptr / frontier / unresolved stores. Captured by the arbiter at A+2, granted A+3 while legal_o has already dropped to 0 — exactly observation (b). The hole is slot-history dependent, which is why the lead's single-entry inspection (b=4 e=0, previous occupant a gated load → stale 0) saw "correct" legality and generalized wrongly (RT §4.4).
  CONSEQUENCE   Linux spin loop (W6): sc.d tid 5 and lr.d tid 7 issue non-head; tid 7 opens issue_read_operands.lr_sc_pair keyed to itself; the head lr.d tid 3 is a non-SC store-class op and is refused issue_ack while the window is open; the window closes only on an SC issue or !still_issued[7] — tid 7 cannot retire behind 3. D2 = tid 3 was never issued (SB `issued` records allocation, RT 10.5), not lost in the LSU. r67's SU gate turned the same early issue into an LSU head-of-line wedge (directed test) — a store unit cannot repair issue order by waiting.
  ALTERNATIVE   lead r68 synthesis: dead pre-flush entries taken through a kill path with reused tids. Rejected: take_v_o requires take_grant = !kill; flush clears bank/arb/bypass registers; the directed-test wedge has no flush at all.
  DISCRIMINATOR leaf tb_g6lc_hyp8_iqleg (bank stand-in with the pend-staged alloc timing): L1 fresh head-only non-head must read legal=0 in its first live cycle. Pre-r68 form (mutant G6LC_MUT_IQLEG_STALE_OCCUPANT) reads 1. Full-core: hyp8_amo_ready_order.S (older AMO/LR with a late operand directly ahead of a ready younger AMO/SC/LR) wedges on the old tree, completes on the new.
  RESULT        leaf HYP8_IQLEG_PASS checked=23 locally (Verilator 5.020) and on the pinned remote toolchain (hyp8-r68-iqleg-leaf, zero diagnostics of any class); mutant fails L1 by name AND the module's new L3 assertion fires at the exact cycle (hyp8-r68-iqleg-leaf-mut). Full hyp8 core lint (local, -Wno-BLKANDNBLK for the stock-5.020 cvfpu limitation): 0 %Error, no diagnostic in the touched modules. Integration build + smokes: hyp8-integration-r68c launched (closure hyp8-r68-closure, 729 files, built by the new verif/regress/remote/hyp8/build_closure.py — the r20b relative-include file is now mechanized).
  LIMITS        No boot claim. The kernel witness (hyp8-osbi-scalar) must be re-run on r68 to confirm the ~21.95M wedge clears; the lr_sc_pair window is now bounded by head-only LR issue (closes on the LR's own retirement), not redesigned.
  NEXT ARTIFACT landed: assertions g6lc_r68_iqleg_head_only (g6lc_iq_legal), g6lc_r68_take_head_only (g6lc_iq), g6lc_r68_su_amo_head (store_unit); leaf `iqleg` in run_hyp8_memory.py; directed test in run_hyp8_integration.py TESTS.

Changes (hyp tree):
- `ooo/g6lc_iq_legal.sv`: per-entry facts (at_head_d, unres_d) register against the bank's NEXT-state tid (`info_tid_d_i`, new port) so a landing occupant's first live cycle reads facts about itself; `info_v_q` warm gate on the frontier-dependent classes (CSR/store: the frontier registered this cycle was formed from last cycle's live records); `legal_d &= info_v_i`; r66 live compare kept as defence; mutant `G6LC_MUT_IQLEG_STALE_OCCUPANT`; L3 assertion.
- `ooo/g6lc_iq_bank.sv`: `ord` record bit (|cls[5:0]) set at allocation; `ready` reads `(legal_i || !ord)` so unordered classes never wait on registered legality (an OR2 beside rs1_ok's own OR level — no select-cone depth change); `info_tid_d_o` export (e_d.tid: alloc mux over the registered pend record, no cancel/ack term).
- `ooo/g6lc_iq.sv`: wiring + grant-time assertion.
- `store_unit.sv`: r67 gate stays withdrawn (lead); L3 assertion "AMO at the bypass head is the commit head" under OoOEn.
Latency effects (recorded): head-only and load legality keep their intended distance (facts from e_d); CSR/store legality is one cycle later at allocation only (warm); unordered classes unchanged (previously they could lose a cycle depending on the slot's stale class — now deterministic).
Timing note (structural): at_head_d/unres_d cones start one mux level later (e_d.tid = alloc_hit ? pend_rec.tid : e_q.tid); legal_d gains two AND inputs on a reg->reg cone. Board to be re-run (`analyze --stages` on the edited set) before the next S-item; no module is expected to rise above the 32.3 iq_bank clock-setter.

Repo-side artifacts (tier T, MIT): `verif/tb/core/tb_g6lc_hyp8_iqleg.sv`, `verif/regress/remote/hyp8/{run_iqleg_leaf.sh,lint_hyp8_core_local.sh,build_closure.py}`, `verif/tests/custom/hyp8_amo_ready_order.S`, leaf `iqleg` + TESTS row.

AI island (production tree, tier R): `corev_apu/ai_island/g6lc_ai_pe_dot_pipe.sv` — pipelined INT8/INT4 dot product (M1 two 8x4 half products, M2 combine, one adder-tree level per stage, two output registers; Latency = $clog2(Lanes)+5 = the float pipe's OBSERVED valid_o, its header's "+4" is one short — the sequencer metadata pipe is tuned to the observed value). Bit-identical to g6lc_ai_pe_dot (narrow growing-width tree, exact for Lanes<=512). `g6lc_ai_gemm_seq.sv` gains `DotPipeInt` on the same start/valid handshake (`dot_pipe_en`), the comb int cell is not instantiated when selected. Verified: tb_g6lc_ai_pe_dot_pipe (Lanes 1/4/8/16, random INT8/INT4, masks, bubbles, latency) and run-gemm-backend.sh dpf=2 — every live-format golden passes for nch=1,2,4,8. Structural effect (not STA): the integer MAC cell's reg->reg cone drops from ~130 FO4 (8x8 mul + 9 adds, Lanes=256) to one 8x4 multiply or one <=25-bit add (~10 FO4), i.e. the 2 GHz nameplate stops being structurally impossible for the integer path; MAC/s remains port-bound (8 B/cycle, scaling-100tops.md §4.2). `AiIslandPeImplMask` is unchanged.

### r68 verification record + F14 (2026-10-26, lead)
- `hyp8-integration-r68c` (closure 729): lint scalar/smt2 rc=0 (0 %Error, 3 LATCH baseline), model `e5e8aeaa…` built; every smoke aborted at cycle 659 on the pre-existing T1 equivalence assert `g6lc_t1_iqleg_eq` — its translate_off reference recomputed `unres` from the live tid while r68 forms it from the next-state tid. Reference moved to `fact_tid` (same identity); leaf still 23/23.
- `hyp8-integration-r68d` (closure 730, model `e5baf3f7…`): lint scalar/smt2 rc=0 / 0 %Error. Smokes (`run_hyp8_smokes.py`, new durable runner, `hyp8-r68d-smokes`): h34=685 (=), h33=1011 (+1), bc=492 (=), csr_flush_skip=2364 (+14), amo_store_order=2190 (+99: its younger address-ready AMOs now wait for the head, as the contract requires) — five SUCCESS with real tohost. New directed `hyp8_amo_ready_order`: v1 (AMO/AMO) and v2 (lr.d/sc.d) complete; no wedge anywhere (the old-tree deadlock shape is gone), **FAILED tohost=76 at 1085 cyc**.
- **F14 (new, outside the r68 class).** The rvfi trace (`hyp8-r68d-aro/trace_rvfi_hart_00.dasm`) shows v3's `sc.d a7,a4,(a5)` retiring with `mem 0x80001140 <= 0x99` (lockq, correct address, a7=0, a3=a6=0 all correct), yet the harness read **0x99 at tohost 0x80001000** (reported 76 = 0x99>>1). The architectural trace is right and DRAM is wrong: the SC's AXI write landed at an address with bits [8:6] cleared (0x140 -> 0x000). v2's `sc.d` to lockd (0x…1108) would land at 0x…1008 — unobserved because the test's readback hits the write-through L1. Owner candidates, in order: the exclusive-store path of the uncore (`g6lc_axi_lrsc` reservation table / AW re-issue, `wt_axi_adapter` atomic address formation), not the core issue logic. Discriminator: AXI AW address of the SC beat vs its rvfi mem address (one `+smt_flow_trace`/AXI probe run, or `verif/tb/ai_island/run-dram-atomics.sh` extended with an SC at a 64 B-misaligned-by-0x140 address). Visibility channel 1 (a write performed where the architecture did not write) — a memory-corruption class; it predates r68 (the r61c `hyp8_amo_store_order` passes only because its lock words sit at offsets whose [8:6] are already 0: lockw/lock2/lock3 are all 64 B-aligned at offsets 0x40/0x80/0xC0… check) and must be run on the production tree too.
- Not done this pass: OpenSBI/Linux witness on r68d (`hyp8-osbi-scalar-r39` to be launched on model `e5baf3f7…`, watchpoint: the ~21.95 M-cycle spinlock wedge of r31/r33/r36/r38); the structural board on the edited set; F14 root cause.

### r68 board + witness launch + F14 narrowing (lead, 2026-10-26)
- Board `boards/hyp8-core/analyze-r68.json` (argv of record in `analyze-r68.cmd`, r44 map, delay-v44, budget 8.0, --all-modules --stages): every edited module is unmoved vs analyze-r63 — g6lc_iq_legal 21.85 (frontier merge into->out, :179), g6lc_iq_bank 32.3 (reg->out :395, the SEL cone; the `(legal_i || !ord)` OR2 added no depth, as designed), g6lc_iq_arb 30.6, g6lc_ooo_dispatch 25.3, store_unit 42.3; no module rose anywhere on the board. The r68 at_head/unres cones (now from e_d.tid) are not their module's limiter. Top of the active board stays g6lc_lsq 72.2 into->reg, hpdcache_ctrl_pe 76.6, g6lc_decode_s3 53.7, g6lc_ptw_leg_decode 53.0, bht 52.5, wt_dcache_wbuffer 50.1 (g6lc_iq 182.4 into->out is the wrapper's first-fit steer bundle, same as r63 — excluded from the clock rule as before). Throughput program unchanged: r64-program S1 (load_unit publish lane) -> S2 (IqSelStages) -> S4 -> S3 -> S5, one witness per landed item.
- Witness `hyp8-osbi-scalar-r39` launched detached on the r68d model (`e5baf3f7…`, fw `a9218107…` from hyp8-firmware-r1, tohost 0x80041730, 60 M, +stall_census +hang_dump=2000 +equiv_report) via the new `run_hyp8_witness.py`; collect with `testharness_proxy.py pull --tag hyp8-osbi-scalar-r39`. Watchpoint: ret 5,984,752 / cyc ~21.95 M (the r31/r33/r36/r38 spinlock wedge). Classify from positive milestones (UART banner, payload PCs >= 0x80200000, first kernel ecall) — never from the absence of a hang dump.
- F14 narrowing: `g6lc_axi_lrsc` passes `aw_addr` through unmodified (:163) and reserves the exact `ar_addr` (:251) — exonerated as the address owner. `wt_axi_adapter` AMO_SC arm forms `amo_off_d` from paddr[$clog2(AxiDataWidth/8)-1:0] only (:415) and the AW address from the same `dcache_data.paddr` as plain stores — candidates left: the D$ write-through / miss-unit atomic request path (`wt_dcache_missunit` AMO address capture), the cluster/L2/L3 atomic adapter (`g6lc_axi_atomics_wrap`), and the DRAM backend's exclusive write handling. Next check: one AXI probe print of `aw.addr` for `aw.lock` beats on `hyp8_amo_ready_order` (expected 0x…1140; observed DRAM 0x…1000).

### r68e — CAM live-mask requalification; witness r40 (lead, 2026-10-26)
- `hyp8-osbi-scalar-r39` (r68d model) stopped at cyc 42,914 on `g6lc_lsq_cam_bank` `g6lc_t1_cam_oa` ("killed match"): the CAM samples the cancel mask at stage E (`ccl_q`); a cancel landing in the C cycle itself published a match for an event the scoreboard had already killed. The assertion was stricter than the design; the r68 issue-timing shift made the window reachable. Fix (option (c) of execution-path-plan §5a item 2): registered `ev_id_c_q`, `ccl_live = ccl_q && !cancelled_mask_i[ev_id_c_q]` requalifies `match_o/unres_o/nodata_o` — conservative (channel 3: a cancelled event's verdict has no meaning), the T1 reference requalified the same way, assertion now holds by construction. Cost: one dynamic mask read + AND on the reg->out cone.
- `hyp8-integration-r68e` (closure 730, model `d175776a…`): lint scalar/smt2 rc=0; smokes identical to r68d (685/1011/492/2364/2190 SUCCESS; `amo_ready_order` fails on F14 only, no wedge).
- Witness `hyp8-osbi-scalar-r40` launched detached on r68e (fw a9218107, 60 M, +stall_census +hang_dump=2000 +equiv_report). Collect: `testharness_proxy.py pull --tag hyp8-osbi-scalar-r40`. Watchpoint unchanged (ret 5,984,752 / ~21.95 M).

### r68 close-out (lead, 2026-10-26)
- Witness `hyp8-osbi-scalar-r40` (r68e, model `d175776a…`) alive at hand-off: past the cycle-42,914 r39 stop (752 KB log, no %Error, no abort) — collect with `testharness_proxy.py pull --tag hyp8-osbi-scalar-r40`; classify from positive milestones only.
- F14 discriminator landed as `verif/tests/custom/hyp8_f14_store_offset.S` (TESTS row): plain `sd` then `sc.d` at the addr[8:6]!=0 offset class with distinct fail codes (76 = plain-store/DRAM/SBA path, 86 = SC-specific). Runs on the next integration build (`run_hyp8_integration.py` compiles TESTS; `run_hyp8_smokes.py` executes them). Note the harness verdict path: `dtm->exit_code()` is fesvr reading tohost through the DTM/SBA, so an SBA/DRAM read-side address defect is a live alternative to a write-side one — the test's plain-store arm separates them.
- Remaining program (unchanged order, one witness per item): r64 S1 load_unit publish lane -> S2 IqSelStages -> S4 TLB ctx pre-match -> S3 rename_recover two-edge -> S5; F14 root cause after the discriminator; `AiIslandPeImplMask`/dtype grant widening once the pipelined paths carry the live SKU.

### r68b — g6lc_iq_legal frontier gathers as balanced masked-OR trees (rank 0, lead)
Carry-over census on analyze-r68: the module's into->out limiter (21.85, :179) was the per-hart NBE-serial `|=` tid gather of the NH>1 arm (billed although hyp8 elaborates NH=1 — the "excluded arm" class, kept because SMT2 instantiates it) and, under NH<=1, the BANKS-deep last-wins `if` chain of the frontier merge. Both selects are over proven one-hot0 vectors (`g6lc_t1_iqleg_oh`), so a masked AND + log2 OR tree is exact (A104 OneHotSelect / A140 "write the depth you mean"). Board (`analyze-r68b-iqleg.json`, --modules): **21.85 -> 19.5**; new limiter is the pairwise `ooo_age_older` frontier matrix (:122, into->reg). Leaf 23/23 unchanged (the T1 reference still recomputes the serial chain every cycle); NH=2 arm elaborates clean (`lint_iqleg_nh2.sh`). No latency change. `out_rtl/` mirror refreshed for the touched file. Next rank-0 candidate on this module: the :122 matrix — `ooo_age_older` is two 5-bit subtracts + compare per pair; A134 "cache the state-only side at its update edge" applies (the bank frontier tids are registered one level up, so `tid - commit_ptr` could be stored as the age key).

### r69 P1 — g6lc_iq first-fit steer as a one-hot rotate (rank 0, lead)
`(hint + k) % BANKS` + BANKS-deep k-scan per lane -> eligible-bank one-hot, rotate right by hint, `x & -x`, rotate left; per-bank taken count kept so a bank may take several lanes exactly as the scan did. BANKS power-of-two asserted at elaboration (the rotate IS the modulo). Board `analyze-r69-iq.json` (--modules g6lc_iq): **182.4 -> 101.7** into->out (:225). The residue is the inherent lane-serial dependence (lane 1's eligibility reads lane 0's pick) plus two variable rotates and the isolate incrementer; the next cut is rank 1 (register `bank_free`-derived eligibility a cycle early — A120 — or steer lane 1 from a pre-rotated copy), recorded, not implied. Equivalence: `g6lc_r69_steer_eq` recomputes the pre-r69 scan every cycle (function form, no latch). Lint: full hyp8 core 0 %Error, no diagnostic on g6lc_iq.sv. Gate: dispatch leaf (HYP8_DISPATCH_PASS) + smokes on the next integration.

- r69 P1 gate: dispatch leaf on the P1 closure (`hyp8-r69-dispatch-leaf2`, pinned toolchain): `HYP8_DISPATCH_PASS checked=125 pop_take_same=0 opasm_int=1 opasm_fp=1`, warnings none. `run_hyp8_memory.py` flist leaves now accept the repo-relative closure layout build_closure.py writes (`${HYP_CORE_DIR}` -> the hyp tree's build-platform path) as well as the lead's `hyp_core/`. Next: integration build + smokes on this closure (`hyp8-r69-closure`, 731 files), then P3 (iq_legal age key) and P2 (rename_read late-select) per r69-fo4-program.md.

### r68b r67 gate verdict + r69 mc2 in-flight
r67 SU gate confirmed reverted: r38 (gate model) wedged cyc=21947800 ret=5,984,752, SU state=3 tid_q=5 (younger AMO holds SU lane, st_ready=0; head AMO's own request starves in lsu_bypass FIFO). iqleg term probe (hyp8-probe-iqleg-r67): stuck AMO tid=0x12 correctly legal_d=0 (younger than ptr=0x0c + older st front 0x0e); wedge = LSU head-of-line blocking. On gate-free tree the smoke passes 2091c (AMO legal at head ~cyc 713, sfront=self). Fix belongs at lsu_bypass/arbitration presentation, not st_ready.
r69: g6lc64_hyp8_mc_config_pkg NrCores=4/NrHarts=2/NrIssuePorts=8 (mhartid=core*2+h), Flist.hyp8_mc_sim, harness g6lc64_hyp8_mc TARGET_HARTS=8, g6lc-hyp8-mc{,-linux}.dts (8 cpus/intcs, 8-hart clint/plic, L2/L3 nodes), linux-mc+strict-mc fw profiles (dtbs sha 24bdd6a7/7813ffd5); hyp8-mc2-integration-r1 building (>1h, 8-hart model); fw built runs/hyp8-firmware-mc2d; watcher hyp8-mc2-watch2 auto-launches hyp8-osbi-mc2-strict-r1 (40M).

### r69 in-flight checkpoint
hyp8-mc2-integration-r1 (8-hart 4-core, NrIssuePorts=8) compiling >1.5h at -j2 — normal for the scale. Watcher runs/hyp8-mc2-watch2 (mc2_watch_and_launch.py, 6h deadline) auto-launches hyp8-osbi-mc2-strict-r1 (40M budget, strict-mc fw_payload from hyp8-firmware-mc2d/output/build-strict-mc/) on build_complete. Next after strict: if ret=0 bootrom-spin -> diagnose harness mhartid/clint wiring; else hyp8-osbi-mc2-r1 (linux-mc fw from build-linux-mc/, 80M, UART probe, +equiv_report). Status reads via `remote-testharness.sh py` (writes output/status.txt) + `pull --tag` (overlap guard blocks shell while sims run; py+pull path unaffected).

### r69 poll checkpoint
mc2 build still compiling ~2.5h (8-hart 4-core NrIssuePorts=8 model, -j2). Watcher hyp8-mc2-watch2 auto-launches hyp8-osbi-mc2-strict-r1 (40M) on build_complete. Lead-side scalar witness hyp8-integration-r68e also running (overlap guard blocks shell; status via py task + pull --tag works). State file: tools/mc2_status.py writes output/status.txt.

### r69 integration (lead, 2026-10-26)
`hyp8-integration-r69` (P1 steer rewrite; closure 731): lint scalar/smt2 rc=0, build_complete. Smokes (`hyp8-r69-smokes`): h34=685 / h33=1011 / bc=492 / csr_flush_skip=2364 / amo_store_order=2190 — identical to r68e (P1 is cycle-neutral as a rank-0 rewrite must be). `amo_ready_order` still fails on F14 only.
**F14 discriminated: `hyp8_f14_store_offset` -> tohost 86 (raw 0xAD).** The plain `sd` at the same offset class passed its own check and did NOT reach tohost; the `sc.d` did. Owner is **SC-specific**: the exclusive-store path (AW with `lock`) lands with addr[8:6] cleared while plain stores do not. Candidates now narrowed to the lock-qualified write path: `wt_axi_adapter` AW formation when `axi_wr_lock=1` (shares `dcache_data.paddr` with plain stores -> unlikely), the uncore exclusive adapter (`g6lc_axi_atomics_wrap` / `axi_riscv_lrsc` instance in the cluster/testharness) and the DRAM backend's exclusive-write handling. Next: AXI AW probe on lock beats (expected 0x…1180-class address vs observed).

- F14 locus: the testharness DRAM exclusive path is `g6lc_axi_atomics_wrap` = `g6lc_axi_lrsc` (pass-through, exonerated) feeding the vendored pulp `axi_riscv_atomics` (`axi_riscv_lrsc` + `axi_riscv_amos`, ADDR_WIDTH 64) — the SC's locked AW is rewritten there. Next probe: print `mst.aw_addr` vs `slv.aw_addr` on `aw_lock` beats inside the wrap (one translate_off display), then the pulp `axi_riscv_lrsc` reservation/address slicing (its `AXI_ADDR_WIDTH` vs the testharness slave offset width is the first thing to compare).

### r68e/r40: gate-free tree passes the AMO wedge — new load-class wedge at 26M
hyp8-osbi-scalar-r40 (r68e = current tree, r67 gate withdrawn; r66 iq_legal + amo_dup + r61c st_ready): reached cyc=26,000,000 ret=5,988,941 IPC 0.230 — ~4M cycles PAST r38's r67-gate wedge point (ret=5,984,752 @ ~21.95M). The r66 at_head fix cleared the original AMO-buffer deadlock. New wedge at [hang] cyc=22114642: SB head slot=26 issued=1 valid=0 fu=1 op=47 (LOAD-class op 0x2f) pc=ffffffff8063aeee lsu_ready=0 since_ack=2000 — a load-unit stall, NOT the AMO mechanism. 90 hang blocks; OpenSBI boot UART intact (PMP/delegation dump). r68e is lead-side scalar lane, not mine.
mc2 build still compiling (8-hart model >2.8h at -j2).

### r40/r68e FINAL: 40M budget-out, wedged cyc=22114642 on load-class op (post-AMO)
hyp8-osbi-scalar-r40 (r68e, gate-free current tree) ENDED: final cyc=39999999 (40M budget, 3.5h wall). Wedged at cyc=22114642 — SB head slot=26 issued=1 valid=0 fu=1 op=47 (LOAD-class 0x2f) pc=ffffffff8063aeee lsu_ready=0 — ~180k cyc PAST the old AMO point (ret=5988941 vs r38's 5984752). r66 at_head fix cleared the original AMO deadlock; next kernel-path blocker is a load-unit stall on a compressed load (fu=1 op=0x2f). 90 hang blocks, OpenSBI UART 2627B intact. r68e was a lead-side lane; mc2 make is the only remote process left.

### r69 checkpoint 2
mc2 build still compiling ~4h (8-hart/4-core/NrIssuePorts=8 model, -j2). r40/r68e ended: 40M budget-out, wedged cyc=22114642 load-class (fu=1 op=0x2f) — r66 at_head cleared the AMO deadlock; next blocker is the load-unit stall at pc=0xffffffff8063aeee. Watcher hyp8-mc2-watch2 auto-launches hyp8-osbi-mc2-strict-r1 on build_complete. Status via tools/mc2_status.py + pull --tag.

### r69 checkpoint 3
mc2 build still compiling ~4h+ (8-hart/4-core/NrIssuePorts=8, -j2, DepSet files >270 — very heavy). Watcher hyp8-mc2-watch2 (mc2_watch_and_launch.py, 6h deadline from 12:27) auto-launches hyp8-osbi-mc2-strict-r1 on results.json build_complete. r40/r68e ENDED 40M budget-out wedged cyc=22114642 (load-class fu=1 op=0x2f pc=0xffffffff8063aeee — NEW mechanism past old AMO point). Status: tools/mc2_status.py → py task writes output/status.txt → pull --tag <t> → read /mnt/c/tmp-pullN/status.txt.

### r69 P3 — COUNTERCASE (lead, 2026-10-26, uncommitted record)
Per-bank ring distance (`ooo_age_dist`) cached once per frontier, matrix cells as one `dist[bb] < dist[b]` compare: board `analyze-r69-iqleg.json` **19.5 -> 31.4** (into->reg :127). The 5-bit subtract in series with the compare bills worse than ooo_age_older's three parallel compares (whose half-select structure is already the A118 form). Reverted byte-exact to the r68b pin; leaf/NH=2 lint had passed, so the rewrite was correct but not an improvement. Lesson for the pattern card: "cache the state-only side" (A134) pays only when the cached value is REGISTERED at its source — here the distance would have to be produced by the bank with its registered frontier (bank-side adder off the merge cone), which is the rank-1 form of P3, not a wrapper-side rewrite.
Next in order: P2 g6lc_rename_read :292 late-select (rank 0); F14 AW probe inside g6lc_axi_atomics_wrap (slv vs mst aw_addr on aw_lock beats).

### r69 P2 — COUNTERCASE (lead, 2026-10-26, uncommitted record)
`ckpt_slot` three-step conditional-subtract wrap -> one conditional subtract (exact under the caller's `cnt + sb_cnt < CKPT_PER_HART` guard): board `analyze-r69-rr.json` **49.6 -> 56.1** (into->out :297). Lint clean, but the analyzer bills the single `>=`/`-` pair plus the `h*CKPT_PER_HART` add as a longer serial cone than the three bounded steps (which it apparently folds as repeated constants). Reverted byte-exact to the committed pin. The :292 arm (`lane_o[gp].ckpt_slot` = head + cnt + popcount(same-bank lanes), then wrap) remains the limiter; the honest rank-0 move is the one named in r69-fo4-program P2 — late-select — i.e. compute the candidate slot for each possible `sb_cnt` value (0..NP-1, constants) in parallel and select by the popcount one-hot (A118), which removes the popcount from the adder's input; not attempted this pass (budget).
Status of the consecutive program: P1 landed (182.4 -> 101.7, gated); r68b landed (21.85 -> 19.5); P3 and P2 measured as countercases and reverted; P4-P10 remain as designed in r69-fo4-program.md.

### r69 P4 — NULL (lead, 2026-10-26, uncommitted record)
Fence legality chain (illB/illC/illD replace arms) as a one-hot priority select with tvm set-arms OR'd flat: lint clean, board `analyze-r69-d3.json` 53.7 -> 53.2 (into->out). Below the acceptance threshold: the module's number is the 58-LHS bundle floor (independent-LHS makespan), not the chain. Reverted byte-exact. Rank-0 conclusion for g6lc_decode_s3: splitting the `always_comb` per output family (so each LHS bills alone) is the only representation move left; the real cone is already short.
Program status: landed r68b (21.85->19.5), P1 (182.4->101.7); measured-and-reverted P3 (19.5->31.4), P2 (49.6->56.1), P4 (53.7->53.2 null). Remaining rank-0: P2' late-select over sb_cnt constants, P10 instr_queue one-hot placement, decode bundle split. Rank-1 (P5 LsqVerdictStages, P6 load_unit exception lane, P7 StoreTransStages, P8 wbuffer versioned writes) and rank-2 (P9 IqSelStages) as designed in r69-fo4-program.md, each a lockstep item with its own leaf, smokes and witness.

### r69 mc2 cfg fix: BPCkptDepth 32 -> 128
mc2 build finished (model exists) but runner timed out at 7200s default (orphaned make completed). Strict witness auto-launched and ABORTED at cyc 0 on config_pkg.sv:1234 assert: !(OoOEn && BPCkptDepth!=0 && BPCkptDepth<RobEntries) — build_config_pkg derives RobEntries=max(NrScoreboardEntries=32, NrIssuePorts*16=128)=128, so BPCkptDepth=32<128 fails. FIXED in g6lc64_hyp8_mc_config_pkg.sv: BPCkptDepth 32->128 (pow2, matches ooo_server's BPCkptDepth=RobEntries convention). Patched remote closure+source copies, manifest rehashed, rerun relaunched (HYP8_BUILD_TIMEOUT=21600, overlap allowed). watch2 still armed for strict relaunch.

### r70 — load-class wedge probe, FDT-relocation defect, mc2 build/launch repair (lead, 2026-10-26)
- Ground truth re-read from the remote (not from the watcher): `hyp8-mc2-integration-r1`'s Python runner died on the fixed 7200 s build timeout while the orphaned `make -j2` kept compiling (1292/2027 DepSet objects at 7h15m); the watch2 watcher keyed on `results.json: build_complete`, which could never appear. Replaced by `remote-runs/mc2_watch3.py` (keys on the linked binary + make exit; records model sha; chains strict-mc -> linux-mc). `run_hyp8_integration.py` gained `HYP8_BUILD_TIMEOUT` (default unchanged 7200). Model linked 20:40 (sha `a2863327…`, 227 MB), but the first strict launch stopped at time 0 on `config_pkg.sv:1234` (`BPCkptDepth(32) < derived RobEntries` — `NrIssuePorts*16 = 128` under OoOEn); the config fix (`BPCkptDepth: 128`, hyp8-mc pkg) landed in the tree after that model's source snapshot, so the 8-hart model must be rebuilt.
- **Firmware packaging defect (harness side, all Linux profiles).** The generic platform's default `FW_PAYLOAD_FDT_ADDR=0x82200000` (r40 UART: `Domain0 Next Arg1: 0x82200000`) lies 32 MiB inside the 65,943,552-byte Linux payload at 0x80200000, so fw_base.S's FDT relocation overwrote the kernel image before every Linux witness to date. `build_boot_firmware.py` now passes `FW_PAYLOAD_FDT_ADDR=0x88000000` (clear of every payload, inside the 256 MiB memory node). Rebuilt as `runs/hyp8-firmware-mc2e` (linux-scalar `ac36f379…`, linux-mc `a40ac37c…`, strict-mc `8ed382d7…`; tohost 0x80041730 unchanged). Not a claim about the r40 wedge's cause — the kernel's first FDT read (`fdt32_ld` = four byte loads at FIX_FDT 0xffffffc6fec00000..3, which is exactly the r40 hang shape: tids 26-29, addr ..00/01/02/03, LU WAIT_GNT, ldbuf empty) targets DRAM either way; a cacheable load that never gets a D$ grant is an RTL liveness defect regardless of the bytes it would read.
- Probe for that wedge: `g6lc_core.sv` `gen_hd_wt` adds two `[hang]` lines on the same `+hang_dump` trigger — the LU request (valid/tid/vaddr/paddr/dtlb_hit/treq/ex/cancelled, data_req/gnt/tag_valid/kill/rvalid, wbuf_not_ni/po_match/st_empty/no_st) and the WT D$ load-port anatomy (rd_req/rd_ack/miss_req/miss_ack/miss_nc/miss_replay/miss_rtrn, wbuffer_fwd_hit, wr_cl_vld, PTW port, miss-unit state/MSHR, wbuffer valid/empty/not_ni/tx_vld, adapter). TB-only, own generate scope (gen_cache_wt exists only for DCacheType==WT); hierarchical refs to the per-port ctrl were rejected by Verilator (unnamed generate block), so the wt_dcache-level arrays are read instead. Local hyp8 core lint 0 %Error; `hyp8-integration-r70b` (closure 731, model `71c8eda0…`) lint scalar/smt2 rc=0, build_complete.
- Witnesses launched on r70b: `hyp8-osbi-scalar-r41a` (old fw `a9218107…`, 24 M, reproduces the r40 wedge with the new anatomy) and `hyp8-osbi-scalar-r41b` (FDT-fixed fw `ac36f379…`, 60 M). Classification rule unchanged: positive milestones only.
- Open from the hand-off review: F14 (SC write lands with addr[8:6] cleared; SC-specific; locus pulp `axi_riscv_atomics` in the testharness DRAM path) is still unresolved and would corrupt any Linux spinlock release that reaches DRAM — it must be fixed or shown harness-only before a boot claim.

### r69 checkpoint 4
mc2 BPCkptDepth fix (32->128, derived RobEntries=NrIssuePorts*16=128) applied + remote source patched; model2 rebuild compiling ~2h at -j7 (objs~603/2040, new DepSet h24430560 series = patched cfg re-elaborated; cc1plus 99% on giant TUs). First strict/linux witness attempts aborted on the OLD binary (config_pkg.sv:1234 assert — pre-patch). Watcher hyp8-mc2-watch4 auto-launches hyp8-osbi-mc2-strict-r1 on model2 binary. r40/r68e final: 40M budget-out wedged cyc=22114642 (load-class). Status: tools/mc2_prog2.py + pull --tag.

### r71 — two Linux-path liveness owners found and fixed (lead, 2026-10-26)
**r41a (r70b model, old fw) reproduced the r40 wedge at cyc 22,114,642 with the new anatomy:** `LU req: valid_i=1 tid=26 vaddr=ffffffc6fec00001 dtlb_hit=0 treq=0 data_req=0 | LU state=1 (IDLE one-hot)`, D$ load port idle (rd_req=0, miss unit IDLE, wbuffer empty), PTW port idle. The load unit holds a valid DTLB-missing load and requests neither translation nor data: `tr_idle_ok = dtlb_hit || !is_speculative_load` (and the IDLE/SEND_TAG issue gate of the same form) sends a flagged load to WAIT_SPEC_LOAD, which returns to IDLE next cycle (no `_miss`), forever. Owner: `lsu_bypass` clears `is_speculative_load` only for the *incoming* request when `resolved_branch_i.valid && !is_mispredict` lands in the same cycle (upstream in-order timing: the earlier-port branch resolves as the load enters). Under OoO the branch resolves later and queued entries / the registered head are never updated (OoO handles mispredicts through the cancel mask instead), so a load issued in the same cycle as an earlier-port branch (`ex_stage.speculative_load`) that then misses the DTLB can never be translated. First reachable in Linux at its first FIX_FDT byte load (`fdt32_ld`, four byte loads at 0xffffffc6fec00000..3 — tids 26..29 in the r40/r41a dumps). **Fix (`load_unit.sv`):** `spec_ld = is_speculative_load && (!OoOEn || not_commit_time)` replaces the raw flag in `tr_idle_ok`, `spec_issue_ok`, both FSM issue gates and the reference-FSM copies — the commit head has no older unresolved branch by construction, so it is not speculative; younger flagged loads still wait (and drop on `_miss`). Timing: one AND of the existing `not_commit_time` compare onto the data_req/translation_req cones (recorded; load_unit is already the accepted-debt module). Not changed: the same-cycle-only definition of `speculative_load` in `ex_stage` (in OoO it under-approximates speculation; NI protection under OoO rests on `not_commit_time`/`stall_ni`, which this fix leaves intact).

**r41b (r70b model, FDT-fixed fw) stopped at cyc 15,690,822 with a different owner — frontend:** `sb_empty=1`, `FE head v=0 cf_hold=1 demand=0 fe_v=00 red_iq=0 lost=0`, PC in libfdt (`fdt_subnode_offset_namelen+0x48`), SB empty, nothing in flight. `cf_hold_q` arms on a reseed push and clears only on `icache_take` or `flush_i && !reseed_now`; the FTQ is also flushed by `is_mispredict` / `smt_restore_flush` and drains stale-epoch heads by itself. When the held redirect record is dropped that way and no reseed re-arms the queue, `if_ready=0` (hold) and `demand_req=0` (no head) forever. **Fix (`fetch_B/frontend.sv`):** `else if (ftq_empty) cf_hold_q <= 0` (FTQ `empty_o` now wired); a `[fe-hold-release]` translate_off witness prints fetch_address/npc/redirect state at the release so the resume PC can be checked against the lost target (`g6lc_fe_nextline` keeps the redirect PC as the block cursor under `hold_i`; the r42b run is the behavioral check — OpenSBI must print the platform table past the banner where r41b stopped). Why it appeared only on the FDT-fixed fw: the libfdt walk over the relocated FDT shapes the branch stream differently; it is a latent FE liveness hole independent of firmware.

Also this pass: `g6lc_ai_cluster_dispatch.sv` gained the `DotPipeInt` parameter + forward (the r68 island_top edit passed it to a module that did not declare it; r71 lint stopped on PINNOTFOUND). r71b (frontend fix only) and r71c (both fixes) closures built; witnesses r42a (old fw, 30 M — the 22.11 M wedge must clear) and r42b (FDT-fixed fw, 60 M) follow on r71c.

- r71c verification: `hyp8-integration-r71c` (closure 731, model `c1b686f7…`) lint scalar/smt2 rc=0, build_complete. Smokes (`hyp8-r71c-smokes`): h34=681 / h33=1007 / bc=491 / csr_flush_skip=2314 / amo_store_order=2164 — five SUCCESS with real tohost; all slightly faster than r69 (685/1011/492/2364/2190) because the hold now releases when the FTQ empties (the `[fe-hold-release]` witness fires after essentially every redirect — ~108k times in the first 2 M cycles of r42b — i.e. the pre-r71 hold outlived the redirect record in the normal path too, idling fetch until the I$ take; the release resumes at the post-redirect cursor, e.g. `red_pc=80000000 -> fetch_address=80000680`). `amo_ready_order` (rc=76) and `f14_store_offset` (rc=86) fail exactly as before on F14 (SC write address, harness DRAM atomics path) — unchanged, not in this pass's scope. Witnesses r42a/r42b running on r71c.

### r69 checkpoint 5
model2 rebuild3 running (verilator into output/model2) with BOTH fixes: BPCkptDepth=128 + DcacheIdWidth=5 (lead's r71 fix, already in repo file — remote source copy now synced). OLD model2 binary sha=5ba2e387 (BPCkptDepth-only) hit load_unit.sv:1716 assert (DcacheIdWidth<REQ_ID_BITS at NrIssuePorts=8 → NrLoadBufEntries floor=32, REQ_ID_BITS=5). Wait for new sha != 5ba2e387 → relaunch hyp8-osbi-mc2-strict-r1 (40M, strict-mc fw) → then hyp8-osbi-mc2-r1 (linux-mc, 80M). Lead-side lanes r70b/r71c run scalar witnesses — do not touch. Tools: mc2_prog2.py/mc2_rb3.py + pull --tag.

### r71 cont. — frontend hold release is a COUNTERCASE (reverted); I$ anatomy added (lead, 2026-10-27)
- r42a (old fw) and r42b/r43b (FDT-fixed fw) on the hold-release tree both stopped EARLIER than before (17,152,878 / 15,298,922) in a new shape: `sb_empty=1`, FTQ head valid, `demand=1`, `cf_hold=0`, `fe_v=00`, I$ cycling IDLE/READ/MISS over *advancing* sequential lines (0x80013c90 -> 0x800140d0 -> 0x80014500; FTQ head 0x80013c98 -> 0x800140d8 -> 0x80014508 across the three 1000-cycle dumps) — fetch runs away sequentially after a burst of four reseeds 13 cycles apart (epochs 3..6, `[fe-hold-release]` at t=15,296,829..874, all `red_pend=0 red_inflight=0`), and nothing reaches decode. The release let `if_ready` refill the queue from the nextline cursor right after each reseed; the stream that results is not the one the realigner/instruction queue is waiting for. Reverted to the pre-r71 hold (`icache_take` / `flush_i && !reseed_now` only). Kept: `ftq_empty` wire and a translate_off `[fe-hold-stuck]` detector (256 cycles of held+empty, prints the redirect bookkeeping) so the r41b owner is reported with its lost-record identity next time. Correct fix direction for r41b (not implemented): a reseed record dropped by a later FTQ flush that does not re-arm must be re-presented through the redirect_lost path (or the FTQ flush on is_mispredict must carry the pending reseed), never resumed sequentially.
- The `[hang] I$` anatomy line (state/flush/inv/vaddr/nc, dreq/areq handshakes, mem_req/ack/rtrn, adapter, PTW state, ITLB access/hit) is now part of the WT hang dump.
- `load_unit` spec_ld fix stays (unaffected by the FE countercase; r41a identified the owner unambiguously). Validation witness: r44a (old fw, 30 M) on r71e must pass 22,114,642; r44b (FDT-fixed fw) is expected to reproduce the r41b lost-redirect hold at ~15.69 M and print `[fe-hold-stuck]`.
- mc2: model3 (BPCkptDepth 128, DcacheIdWidth 5) compiling at -j6 (`output/model3/make-j6.log`); watcher `hyp8-mc2-watch6` chains strict-r3 (40 M) -> linux-r3 (80 M) on `runs/hyp8-firmware-mc2e` (FDT-fixed) firmware.

### r71 verdicts (lead, 2026-10-27)
- **`hyp8-osbi-scalar-r44a`** (r71e model `fa50e7bf…` = load_unit spec_ld fix + original FE hold + anatomy; old fw `a9218107…`): **passed the r40/r41a wedge** — ret 6,115,771 at 24 M vs the frozen 5,988,941 of r40 (the kernel executed ~127k more instructions past its first FIX_FDT read; the DTLB-missing flagged load now translates at the commit head). Next stop at cyc 22,551,795: `sb_empty=1, cf_hold=1, ftq head v=0, demand=0`, `[fe-hold-stuck] fetch_address=ffffffff8063b260 red_pc=ffffffff8063b328 red_pend=0 red_inflight=0 red_lost=0 red_tail=0 epoch=3` — the same lost-redirect hold as r41b/r44b (FDT-fixed fw: cyc 15,690,822, `fetch_address=800133c0 red_pc=80004c04`), now in kernel code. One owner remains on the Linux path on both firmware layouts: a reseed record dropped from the FTQ without a re-arming reseed while `cf_hold_q` stays set. Fix direction (not landed; the sequential-release shortcut was a measured countercase): make the FTQ flush sources and the hold consistent — either re-present the lost reseed target through the redirect_lost/redirect_pend path or clear the hold on the same `is_mispredict`/`smt_restore_flush` flush that empties the queue only when a reseed re-arms it next cycle; needs a directed FE test (reseed followed by a stale resolve-side flush with no redirect) before the next witness.
- **mc2 (4-core x 2-hart, L2/L3/coherence):** `model3` (NrIssuePorts=8, BPCkptDepth 128, DcacheIdWidth 5; sha `d9c95ee3…`) links but stops at time 0 on `g6lc_icache.sv:355` `FETCH_ALIGN_BITS == 3`: `build_fetch_width(8, RVC)` = 128 bits, and the hyp8 I$ rewrite (offset fold, 64-bit response record) is pinned to the 64-bit fetch of the 2-issue profile. **8-issue needs a 128-bit fetch path through g6lc_icache / realign / instruction queue — a design item, not a config fix.** To still obtain a 4-core/8-hart L2/L3 coherence witness, `model4` is building from the same source with `NrIssuePorts: 4` (64-bit fetch; the repo mc package stays at 8 and is the open design target; the 8-issue copy is kept as `output/g6lc64_hyp8_mc_config_pkg.8issue.sv`). Watcher `hyp8-mc2-watch7` chains `hyp8-osbi-mc2-strict-r4` (40 M, strict-mc) -> `hyp8-osbi-mc2-r4` (80 M, linux-mc, FDT-fixed fw) and records model/elf identity in each run's `witness.json`. Classification rule unchanged: no boot claim without a kernel milestone or tohost; the single-core line predicts the FE hold wedge will appear on every core once Linux is entered.
- F14 (SC write with addr[8:6] cleared, harness DRAM atomics path) remains open and would corrupt spinlock releases that reach DRAM; it must be fixed or proven harness-only before any boot claim.

### r72 — fetch-bound 8-issue (A+B), IQ anatomy, methodology notes (lead, 2026-10-27)
Methodology review before this pass (what cost time in r69–r71 and what to keep):
- Countercase rate on blind structural rewrites stayed ~50% (P2/P3/P4 and the FE hold release) — every structural edit is measured on its own board before anything else moves, and behavioral shortcuts are not landed without a directed test. Kept.
- The big losses were infrastructure, not RTL: a fixed 7200 s build timeout, a watcher keyed on a status that could never appear, `pkill -f` patterns matching the issuing shell, and a `-j2` rebuild on a 12-core box. Each is now a knob (`HYP8_BUILD_TIMEOUT`, `HYP8_BUILD_JOBS`) or a rule (watchers key on artifacts; kill by PID).
- 8-hart models cost 3–8 h per build: config asserts (`BPCkptDepth`, `DcacheIdWidth`, `FETCH_ALIGN_BITS`) only fire at time 0 of the *built* model. Rule: evaluate `check_cfg` and the time-0 `initial assert`s against the new package by reading `build_config_pkg` derivations before launching an 8-hart build; batch every config change into one rebuild.
- Diagnostic anatomy in the `+hang_dump` block is the cheapest discriminator we have (one scalar build ≈ 5 min with ccache, the hang reproduces deterministically); a probe model per hypothesis beats reasoning from partial dumps.

A — `FetchWidth` user knob (`config_pkg` g6lc_user_cfg_t, `build_config_pkg`: explicit width else `build_fetch_width`), two new `check_cfg` statements (RVC multi-issue needs ≥64; window ≤ I$ line). hyp8 scalar `FetchWidth: 0` (auto, unchanged); mc `FetchWidth: 64, NrIssuePorts: 8` — the 8-issue core on the hang-6-hardened 64-bit path, "fetch-bound" by label.
B — `instr_queue`: packet slots (`NrSlot = Geo.slots`) separated from queue columns (`NrFifo = Geo.qslots = pot(max(slots, issue))`, new `fetch_geo_t.qslots/log2_qslots`); push-side masks/ranks/gathers/`consumed_o`/replay rest-PC/pend-frontier push addresses are slot-wide, the fill pointer/one-hot drain/FIFO arrays are column-wide. Identical geometry whenever `NrIssuePorts <= INSTR_PER_FETCH` (2-issue profile bit-identical). For mc: 8 drain positions over 8 columns filled 4 per packet.
Hang dump: `[hang] IQF` (drain/fill pointers, per-column empty/full/usage, ready/replay/fe_valid/pos_present/block_any/consumed, realigner bank/unaligned/carry, redirect bookkeeping, bp_pend/tgt) — for the r41b/r44b held-empty and the r42/r43 run-away variants, whose common symptom is `fe_v=00`.
Lint: local hyp8 core 0 %Error; `hyp8-integration-r72b` lint scalar/smt2/mc all 0 %Error (mc = `NrIssuePorts 8, FetchWidth 64, qslots 8`). mc model `hyp8-mc2-integration-r2` building from the same closure (-j6, 12 h budget) with watcher `hyp8-mc2-watch8` → strict-r5 → linux-r5.
mc2 `model4` (4-issue dual-hart, old source): strict-r4 never fetched — `[hang] cyc=2000 sb_empty=1 FE pc=0x10000 reseed=1 lost=1 ic_rdy=0` from reset. Same class as the earlier `g6lc64_hyp8_smt2` "bootrom wait" observation: with NrHarts=2 the I$ is never ready at the reset vector and the FE re-presents the lost reset redirect forever. The r2 model carries the I$ anatomy, so its first hang dump (cycle 2000, seconds into the run) classifies this without a long simulation. Dual-hart boot is therefore gated on that fix, independent of A/B.

### r72 structural pass — two measured countercases, boards of record (lead, 2026-10-27)
- Board sanity: `analyze-r72-iq.json` (--modules instr_queue,g6lc_lsq,load_unit,g6lc_iq, r44 map): instr_queue 45.1 regtoout exclusive_case_mux (`instr_data_in` 26 arms) **identical before/after B** (analyze-r68 45.1 @450 -> r72 45.1 @456) — B is board-neutral for the 2-issue profile as designed. g6lc_lsq 72.2 intoreg plain @1206 is the PHYS_VALIDATE scan (`CohPolicy == COH_OOO`); both hyp8 profiles are `COH_FILTERED`, so it is dead logic here (excluded-arm class, like shared_tlb/ptw_leg_decode) — a two-stage window (per-entry event/address/lane_be capture, then condA/pm verdict) is the design for the COH_OOO arm; not attempted without a COH_OOO leaf.
- load_unit L5 per-family split (`rvalid_output` -> publish family {valid_o, ex_o.valid, trans_id_o} + pop family {ldbuf_r, ldbuf_rindex, retire_idx}, arms verbatim): **41.0 independent_lhs_bundle -> 46.0 dense_control** (`analyze-r72-lu.json`); the plain path stays 35.0 either way. The analyzer re-classifies the control family as a dense control cone and bills it higher than the bundle makespan. Reverted byte-exact (`analyze-r72-lu2.json` = 41.0). Conclusion stands from r51/r64: the only lever below 35 on this module is the dedicated exception completion lane (S1, rank 1).
- g6lc_iq steer eligibility as parallel constant thresholds (`free_gt[b][k] = bank_free[b] > k`, chain selects `free_gt[b][usedc[b]]`): **101.7 -> 102.9** (plain 97.6 -> 100.1, `analyze-r72-iqs.json`); the dynamic index by the taken count is billed as a mux deeper than the FCNT_W compare. Reverted byte-exact. Rank-0 moves on the steer are exhausted; the remaining move is rank 1 (register `bank_free`-derived eligibility at the bank update edge, lane 1 from a pre-rotated copy) with the dispatch leaf as gate.
- r72b smokes (`hyp8-r72b-smokes`, model `a5ac1bc6…`): 685/1011/492/2364/2190 SUCCESS — bit-identical to r69 (A/B neutral on the 2-issue profile; the r71 spec_ld fix is not exercised by them); F14 pair unchanged (76/86). Witnesses r45a (old fw, 30 M) / r45b (FDT-fixed fw, 60 M) running on r72b with the IQF anatomy.

### r73 — the fetch wedge owner: a stale bp_pend filter armed by a losing ov2 verdict (lead, 2026-10-27)
- `hyp8-osbi-scalar-r45b` (r72b, FDT-fixed fw) reproduced the hold at cyc 15,690,822 with the new `[hang] IQF` line: instruction queue completely empty (`empty=1111`, usage 0, `ready=1`), realigner idle, redirect bookkeeping idle (`red_pend/inflight/lost/tail=0`, `red_pc=80004c04` stale) — and **`bp_pend=1 bp_tgt=800124d4`** while the hold's lost target was `fetch_address=800133c0`, `epoch=5`. `icache_take` drops every I$ return that does not match an armed `bp_tgt` under the live epoch (`bp_ret_ok`, frontend.sv:993). The pend was armed by the raw `ov2_valid` verdict (frontend.sv:399) for a target whose record never applied: in `g6lc_fe_redirect` the weak chain is replay > ov1 > ov2, so an ov2 verdict coinciding with a replay (the IQ refusing the very window the predictor just judged) loses the arbitration — the replay record pushes the refused window, bumps the epoch once, and the pend (stamped `fe_epoch+1` = that same epoch) then filters for a window nobody fetches. Every return of the stream that was fetched is dropped: with the hold that is the held-empty FTQ (r41b/r44b/r45b), without it the sequential run-away (r42/r43). Both shapes, one owner.
- Fix (`fetch_B/frontend.sv`): arm the ov2 pend on the record's apply cycle (`hyp_fe_override2_o` = `ov2_taken`), with `bp_tgt <= red_pc` and `bp_pend_epoch <= fe_epoch` (at apply the epoch register already reads the record's epoch); plus a supersession clear — a reseed applying to another window drops the pend (redundant with the epoch rule except in the same-cycle race; keeps the register honest). Mispredict arming unchanged (its TTL bound stays).
- Verification: local lint 0 %Error; `hyp8-integration-r73` (closure 732, model `96202c76…`) lint scalar/smt2 rc=0; smokes 685/1011/492/2364/2190 SUCCESS (identical — the race needs an IQ refusal in the verdict cycle, which no directed test produces; the Linux witnesses are the test). Witnesses `hyp8-osbi-scalar-r46a` (old fw, 40 M; must pass 22,551,795) and `r46b` (FDT-fixed fw, 80 M; must pass 15,690,822) running. Directed FE mini for the ov2/replay race to be written against `tb_g6lc_hyp8_control` once the witnesses confirm.

### r73 verdicts so far + mc2-r2 first dump (lead, 2026-10-27)
- **`hyp8-osbi-scalar-r46b` (r73, FDT-fixed fw) passed the 15,690,822 wedge** — 18 M cycles, ret 5,011,702 and climbing, no `[hang]`; the stale-bp_pend owner is confirmed on the layout that reproduced it four times (r41b/r44b/r45b). `r46a` (old fw) at 18 M, must pass 22,551,795 (same owner, kernel code) — pending.
- **mc2 `hyp8-mc2-integration-r2`** (4 cores x 2 harts, `NrIssuePorts 8 / FetchWidth 64 / qslots 8`, model `cbcea4ba…`) linked and launched `hyp8-osbi-mc2-strict-r5`. First `+hang_dump` at cyc 2000 on core 0: `I$ st=6 (KILL_MISS) vaddr_q=0x10000 nc=1 mem_req=0 mem_ack=0 rtrn_vld=0 adp irtrn=0`; FE `reseed=1 lost=1`, FTQ/IQ empty, `fe_v=00000000`. The non-cacheable bootrom fetch was issued and acked, the frontend killed/re-presented the reset redirect, and the IFILL return never came back — the I$ waits in KILL_MISS forever, nothing is ever delivered. Same class as the earlier `g6lc64_hyp8_smt2` "bootrom wait" and `model4` (4-issue) observation; it is a cluster/harness-level loss of the instruction-fill return for NrCores=4 (no 4-core hyp8 model has ever fetched; the production `ooocoh` 4-core runs used the production harness). Candidates, in order: cluster hub AXI ID/return routing (AxiIdWidth 4 + core index vs the harness xbar id width) for NC reads, bootrom slave behaviour under TARGET_HARTS=8, and the FE's reset-redirect kill racing the NC miss (why `lost=1`). Discriminator: an AXI AR/R probe on the cluster master port (id/addr of the first ifill and whether R returns with that id) — one translate_off display, cycle-2000 result, no long run needed. Dual-hart Linux is gated on this; A/B are not involved (the queue is empty and ready).
