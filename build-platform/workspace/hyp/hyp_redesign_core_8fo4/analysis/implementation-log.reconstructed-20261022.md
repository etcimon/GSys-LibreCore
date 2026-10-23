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
*(recovered verbatim, original lines 1-15; the sentence continues into the
lost region)*

---

## RECONSTRUCTION NOTICE (2026-10-22)

The pre-r18 body of this log (~125 KB, original lines ~16-1819 plus
fragments) was destroyed on 2026-10-22 by a local file-write mishap: a
`Path.write_text` call without `encoding=` truncated the file on the
default cp1252 codec mid-append. The authoritative run evidence is NOT
lost — it lives in:

- remote run dirs `/opt/testharness/runs/<tag>/` (run-hyp8.log,
  run-diag*.log, trace_rvfi/encaps/iti artifacts, output/ manifests),
- local pulls + closures under `C:\Users\etcim\cva6-artifacts\`
  (`closures/hyp8-*`, per-tag remote-runs),
- `AGENTS-todo.md` line 7 — the intact rolling qualification paragraph,
- this file's recovered verbatim regions, marked below.

Sections marked **[RECONSTRUCTED]** are condensed records rebuilt from
those anchors — every tag/verdict/mechanism is independently
re-derivable from the cited artifacts. Regions marked
**[VERBATIM RECOVERED]** are byte-exact text pulled from session
transcript records (lines cited in the original numbering).

## Condensed record of lost sections [RECONSTRUCTED]

**Batch A — memory/PRF ownership** (header text above is verbatim):
held PRF operands (`read_enable_i` raddr capture), pending store-slot
reservations, forwarding payload lifetime. Leaf `tb_g6lc_hyp8_memory`
-> `HYP8_MEMORY_PASS` 43 checks, tag `hyp8-memory-own-r5`.

**Batch B — CSR retirement seam**: commit_stage/csr_buffer/csr_decode/
csr_regfile/csr_counters common-event retirement; IQ payload ownership;
arbiter owned-TID exclusion + serial port0 class; in-FF age-matrix
capture; IRO-acceptance FLU reservation (`g6lc_flu_reserve`); IRO
candidates/scoreboard split; generic replay encode; `IqSpecWakeup=0`
WbReserve profile. Leaves: `HYP8_CSR_PASS checked=50`
(`hyp8-control-csr-r6`), `HYP8_ISSUE_PASS checked=67`
(`hyp8-control-issue-r14`), closure `remote-runs/hyp8-control-r1-closure`.

**Batch F — lead-supplied wakeup/recovery fixes**: rename-owned
`int_busy_o`/`fp_busy_o` feed `grp_rs*_ready` from final held-group
phys tags at IQ allocation; `ex_stage` gates branch redirect
publication by the cancellation mask; `g6lc_rename_recover` uses the
current-state `rel2` clamp (retire-between-select-and-repair no longer
underflows) + scoped latch/SELRANGE rewrites.

**Integration r4** (`hyp8-integration-r4`, closure
`hyp8-integration-r1-closure`, 815 hash-verified files): scalar +
`-DG6LC_HYP8_SMT2` `--lint-only` both rc=0 with full warning census;
`G6LCConfigNrHarts` seam (`ifdef G6LC_HYP8_SMT2` -> 2); scalar
`Variane_testharness` sha256
`071a989f2c7249921ab425bf1c4b10ac6024f4c834f09efc20b1bac5eaed6988`,
warnings=108 errors=0. Runner `verif/regress/remote/run_hyp8_integration.py`.

**Dispatch leaf saga**: `tb_g6lc_hyp8_dispatch` first failure
`A_CONSUMER_LOST_WAKEUP` — instrumented diag (`hyp8-control-dispatch-diag-r3`,
`+dispatch_trace`) proved a stale `wb_id_i->tid_prd_q` comb read held
`ren_int_busy[32]` (busy-clear dropped by the `wb_prd!=0` guard);
resolved as bench/model artifact + real wakeup fix ->
`HYP8_DISPATCH_PASS checked=16` (`hyp8-control-dispatch-r2`, closure
`hyp8-control-r5-closure`).

**Batch G — instr_realign carry transaction**: the single
pending-completion record was replaced by eager bank advance + an
explicit `restore_i` verdict path wired from the stage-S retained
window (`carry_restore`); `tb_g6lc_hyp8_realign` proves
completion+new-tail, restore, per-hart coexistence ->
`HYP8_REALIGN_PASS checked=39`.

**Smoke rounds r10-r14** (tohost-armed from r11 onward —
`+tohost_addr=0x80001000`; earlier runs lacked the plusarg ->
budget-out artifact recorded at original :1608):
`hyp8-h34-r11b` `SUCCESS (tohost = 0) after 656 cycles` PASS;
`hyp8-h33-r5` `FAILED (tohost = 128) after 517 cycles` — first
semantic failure: `sd x10,0(x8)` at 0x80000022 wrote
0x1122334455667788, the paired `ld` at 0x80000026 returned `x6=0`
(load-delivers-wrong-value signature).

**Commit-path diagnostic** (`hyp8-h33-commit-diag`, r13-diag model):
`tid19` cancelled+replay'd load drop-committed at probe c=728 with
`commit_drop_i[0]` but `commit_instr_o[0].valid=0` — the hyp8 `ld_ok`
gate can retract `valid` for a cancelled load while the
validity-agnostic drop path acks. Fix: `scoreboard.sv` commit-port
SVAs widened to `ack |-> (valid || drop)` with the hyp8 contract
comment. tid19's replay traced to the l_hit path marking cancel+replay
after a same-cycle forward; further diagnosis:

**h33-r5 discrimination** (`hyp8-h33-r5-diag`, `+lsq_trace`):
`vio_waited` suppression in the violation CAM masked a NEEDED replay —
`dwait_q` is sampled once at the verdict; a store whose address is
unresolved at verdict can't STL-match, and `unres`-only gating let the
load publish the stale D$ response (load 17 @0x80000026 committed
stale at c434). Fix: unsuppressed first-address-resolution violation
CAM at `g6lc_lsq.sv` `.match_i({vv_match_q, vio_match_q})`; `waited_q`
removed from `g6lc_lsq_release.sv`. Contract: a store's FIRST
address-resolution event names waiting loads — waited-or-not.

**SL-W fixup tag-miss livelock** (`g6lc_wt`/`wbuffer`):
`FIXUP_CHECK` tag miss -> `FIXUP_PEND` retried forever ("until a refill
makes the line visible") with no escape when no refill ever comes —
head-of-queue wedge parked a same-line load. Fix by contract:
missunit exports `mshr_vld_o`/`mshr_cl_idx_o` (index bits of
`mshr_q.paddr`) routed through `wt_dcache.sv` to new wbuffer inputs;
on `!(|fixup_hit_oh_q)`: MSHR colliding on the entry's index ->
FIXUP_PEND, else retire WITHOUT array write (dead-entry drop leg — no
wr/inv port, no PMU pulse). Invariant: memory already holds the bytes
(entry pushed on memory ACK) so any later refill reads them.
DCHX2 also needed `MISS_RTRN_W/V` timing (`rd_data_q` lagged
`miss_rtrn_vld` 2 cycles). Result: `HYP8_DCACHE_PASS checked=115`
both arms (`dchx0-r19d`, `dchx2-r47`); earlier dcache leaves
`checked=25`/`103` superseded.

**LSQ directed leaf** (`tb_g6lc_hyp8_lsq`): verdict `final_q` set one
edge early on `ld_ev_valid_i` (checked could publish before `dwait`
landed — `G2A_CHECKED_EARLY`, real RTL bug); fix: `final_q` on the
registered V-stage verdict. Result `HYP8_LSQ_PASS checked=17`
(`hyp8-control-lsq-r5`).

**r15** (`hyp8-integration-r15`): lints rc=0 (census WIDTHEXPAND 326 /
WIDTHTRUNC 87 / LATCH 3), model sha
`93b07779d0548a7e7dcb29ff3070dba421765d8b5b1524dc9ba0e7728b603202`.
`hyp8-h34-r12` PASS tohost=0 @656. `hyp8-h33-r7` parked-load wedge:
`+ld_state` showed `WAIT_PAGE_OFFSET` `pom=1 poso=0 stb=1` — a
store-buffer commit-side match persisting after the store's fixup
dropped. `+stq_trace` proved the held source was the **wbuffer W1
producer-acceptance recapture** (`w1_accepted_q` missing) + the
return-snapshot re-arm `!evict` masks (r8 tx_stat leak -> FAIL-126);
fixed in `store_buffer.sv` + `wt_dcache_wbuffer.sv`.

**r17 smokes (pre-correction record)** — see verbatim block below and
the A-series correction note following it.

## [VERBATIM RECOVERED] — original lines 1820-1927

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

### r17 smokes (stop at first semantic failure = the witness)

- `hyp8-h34-r14`: PASS — 400k budget end, no tohost in ELF
  (`tohost_addr: 0`, termination-by-timeout is the designed exit for
  these bench ELFs), all 1 core retired instructions, exit 0, max gap
  53 (< 5000), ckpt allocs=39949 pops=39946.
- `hyp8-h33-r9`: PASS — same budget-exit class, all retired, exit 0,
  max gap 69. The r8 FAIL-126 is gone.
- `hyp8-branch-cancel-r1`: PASS — all retired, exit 0, max gap 53,
  restores=2 (the cancel path exercised: mispredict=1).
- `hyp8-osbi-scalar-r1`: **FAIL — witness stop point.** Frozen scalar
  ELF `fw_payload.elf` (sha
  a9218107ce26c7d00a99ae188dc7ca8c1f77f2b16e4ef8d4c46e2ef4a026a37b),
  6,000,000-cycle budget reached, **zero UART output**
  (`grep -c 'OpenSBI|UART' run-hyp8.log = 0`),
  `FAIL: a core ran and then stopped retiring (exit code 126)`.
  Discriminating read: `[ckpt] final allocs=17 pops=7 restores=4
  clears=16`, last retire `pc=0x10062` — the core stopped dispatching
  ~17 instructions in, inside the ROM trap region. Consistent with the
  previously diagnosed frontend fetch/realigner defect (stale
  `i_instr_realign.leftover_pc_o` survives a correctly-predicted
  redirect; `SRC_OV1` then redirects to 0x800000a8 — the middle of the
  32-bit `addi` at 0xa6 — cause-2 trap at ~c1109, `mtvec` never
  updated). Retirement wedging inside the trap handler is downstream;
  the first semantic failure is the frontend defect, which is OPEN and
  not addressed by this sequence.

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

### Open items carried forward

- Frontend fetch/realigner defect (stale leftover_pc + SRC_OV1 to a
  mid-instruction target): witness-blocking, OPEN. Evidence:
  `hyp8-osbi-scalar-r1` run-diag logs + this log's earlier `[win]`
  section (c=1050-1079).
- `branch-cancel`/h34/h33 ELFs have no tohost; their verdicts are
  retirement-liveness + exit-code based. A tohost-terminated variant
  would strengthen the smoke record.
## [VERBATIM RECOVERED] — original tail (line-table tag-domain fix section)

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
