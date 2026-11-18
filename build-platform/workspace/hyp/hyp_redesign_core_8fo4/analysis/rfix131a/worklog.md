# rfix131a — hyp8 root-cause register (boot-log error classes → isolated tests → structural fixes)

Numbering: `rfix131a` = fix round on top of the r131 tree (`a` = first
batch). Entries are `RFIX-131a-NN`. Each entry records the witness evidence,
the mechanism, the isolated `verif/` reproduction, the structural change and
a backport note for the original RTL (`core/`, `corev_apu/`), so the
backport can be done from this log and the tests alone.

Method (2026-11-16): no Linux/OpenWrt witness and no integration gate until
every record class below is reproduced by an isolated `verif/` test and
removed at its root. Witnesses and builds were stopped (r128b at RVFI cycle
1,070,988,199; r131 at 18,403,897; r130 never started; the r131-mc and the
aborted r132 aggregates killed); their logs are the batch data. APU work is
out of scope here.

Scope of the edits: `core/include/g6lc64_hyp8_config_pkg.sv`,
`core/include/g6lc64_hyp8_mc_config_pkg.sv`, `core/csr_buffer.sv`,
`core/ex_stage.sv`, `core/issue_stage.sv`, `core/g6lc_core.sv`,
`core/ooo/g6lc_ctx_barrier.sv` (new), `core/Flist.g6lc_hyp8`,
`verif/regress/remote/hyp8/Flist.hyp8_sim`, `Flist.hyp8_mc_sim`,
`verif/tests/custom/hyp8_spec_bus_clean.S`, `hyp8_ctx_switch_clean.S` (new),
`verif/tb/core/tb_g6lc_hyp8_ctx_barrier.sv` (new),
`tb_g6lc_hyp8_csr_credit.sv`, `tb_g6lc_hyp8_control.sv`,
`verif/regress/remote/run_hyp8_probe.py` (new), `run_hyp8_smokes.py`,
`run_hyp8_integration.py`, `run_hyp8_memory.py`.

## Status

"Verified" means: on the remote testharness, pinned fork toolchain
(compiler PGO, loop unrolling, split-loops, simulation PGO), directed
programs graded on tohost **and** on the log, plus the leaf benches. Round a
(entries 01, 02, 03, 07, 08): `verilator-v5.008-g6lc-44063db8-pgo`, model
`5fb248e6…` from closure-rfix131a, 19 programs. Round b (entries 04, 09):
`verilator-v5.008-g6lc-6fa24f6f-pgo` (the fork with the split-var fix, see
"Multi-core model build"), model `db8a7e82…` from closure-rfix131a-b2, 21
programs. Round c (entries 10, 11, 12): same toolchain, scalar model
`8c637554…` (21 programs) and two-hart model `2f3d94dd…`
(`g6lc64_hyp8_smt2`, `hyp8_smp_lrsc` with `NHARTS=2`) from
closure-rfix131a-c5. No Linux boot has run on this tree, and the four-core
model has not run on it yet.

| entry | class (r127m count) | isolated test | structural fix | verified |
|---|---|---|---|---|
| RFIX-131a-01 | speculative loads on the bus outside memory (18,131 AXI DECERR; device reads) | `hyp8_spec_bus_clean.S` | PMA non-idempotent regions (config) | yes: 3 DECERR + 1 UART read -> 0 |
| RFIX-131a-02 | execution under a stale privilege/translation context (16,558 + 4,635 `[ptw-err]`; 18,130 of the DECERR) | `hyp8_ctx_switch_clean.S`; leaves `ctx-barrier`, `csr-credit` | context barrier at dispatch + frontend hold | yes: 65 DECERR + 194 walks -> 0 |
| RFIX-131a-07 | TLB multi-hit (r129b model stop @317,424,744) | mmu leaf `TLB_OVL_*` (6 cases x 3 instances) + 2 mutants | fill evicts every entry it overlaps; PLRU records the answered hit | yes (leaf) |
| RFIX-131a-08 | non-idempotent load parked at the LSU head (found by -01's own test) | `hyp8_spec_bus_clean.S`, `hyp8_dev_load.S` | a non-idempotent load that is not the commit head is handed back | yes |
| RFIX-131a-03 | wrong-path data walks, null/garbage base (5,389) | `hyp8_spec_walk_clean.S` | a load is speculative until it is the commit head | yes: 3 walks -> 0 |
| RFIX-131a-04 | S-mode fetch faults at trap entry (490) | `hyp8_trap_entry_clean.S` (192 on r131; 64 after -02) | a killed fetch drops its translation request (I$ `KILL_ATRANS` state removed) | yes: 64 -> 0 |
| RFIX-131a-09 | a cancelled instruction acknowledged as retired (not in the census: found from the RVFI stream) | `hyp8_ghost_commit.S` | the commit bundle uses the combined cancel mask | yes: minstret +2 -> exact, fflags NX -> clear |
| RFIX-131a-10 | two harts on one core: a hart came back from a thread switch at PC 0 | `hyp8_smp_lrsc.S`, `NHARTS=2`, `g6lc64_hyp8_smt2` | the commit bundle's same-cycle merge carries the resolved successor of a control-flow instruction | yes (with -11, -12) |
| RFIX-131a-11 | two harts on one core: rename stalled for good ~30 instructions after reset | same | physical register pool has a per-bank liveness floor that scales with the hart count | yes |
| RFIX-131a-12 | two harts on one core: a hart resumed at the other hart's refetch PC | same | a refetch record is {pc, hart}; the CSR bank's deferred flush belongs to its own bank | yes: LR/SC count 72 -> 96 |
| RFIX-131a-05 | commit gaps > 2000 cycles: 6 real (LR parked by SC backoff), 24 are WFI idle | `sc-backoff` leaf | `67f413a63` (r130) | leaf only |
| RFIX-131a-06 | memory-order replays (706,483) | not needed | none: 0.3 % of the boot's cycles (see "Where the boot's cycles go") | - |

## 0. Correction of the r130 worklog (r128b "hang")

The two r130 sections "r128b forensics" and "r128b hang — deep RTL/kernel
forensic" are wrong and are superseded by this section.

- r128b was **not** killed and was **not** hung. The process (pid 2062250) was
  alive the whole time; the "log ends mid-line" observation was the stdio
  buffer of a running process, and the "r130 witness is running" inference
  matched run-directory paths, not live witnesses. r128b was stopped
  deliberately on 2026-11-16 at RVFI cycle 1,070,988,199 (this session).
- The UART silence after `[6.31] Freeing initrd memory` is the kernel's own
  quiet phase. r127m (the run that reached `G6LC_LINUX_SHELL`) prints the
  identical `[6.312965]` line at cycle 573,422,463 and its next line,
  `[19.39] io scheduler …`, at 1,227,720,505 (`tq.sh uart -r r127m`).
  r128b was stopped by hand at 1,070,988,199 — inside that phase.
- r127m's milestones by cycle: console `ttyS0` enabled 1,322,522,498;
  `Run /init` 1,430,638,389; `G6LC_LINUX_INIT_UP` 1,473,869,381;
  `G6LC_LINUX_SHELL` 1,529,110,782; from 1.537B on the hart sits in WFI.
  The 1.75e9 budget of r128b / r130 / r131 therefore **does** cover the
  shell. (An earlier version of this section put `/init` at ~2.53B cycles,
  from a kernel-time extrapolation, and concluded the budget was too small.
  That figure was wrong.)
- Consequence: r128b gives no verdict either way. It showed no defect, and
  it was stopped before it could show a shell.
- The 6.4M-hit function at `0xffffffff8027fc08` is a XOR/byte-store transform
  followed by `memset(…, 0, 360)` (a hash/cipher state), i.e. kernel self-test
  or entropy work inside that quiet phase, not a livelock.
- Still true: r131 scalar is functionally identical to r128b on the boot path
  (`107c4ca3c` needs `LoadExPubStages==2`, `3f3083a64` needs `TlbStages>=2`;
  the boot binding has both at 1).

## 1. Census (complete boot, `hyp8-osbi-scalar-r127m`, 2.67B cycles, 5.47 GB log)

Tools: `analysis/rfix131a/tools/census.sh` (one line per record
class), `ptw_census.sh` (sub-classes), `win.py` (bisecting window extractor
for RVFI + printers by cycle).

| class | r127m | r128b (1.06B) | nature |
|---|---:|---:|---|
| `[l1 dcache wbuffer] L1 obligation dropped` | 42,953,061 | 30,079,050 | diagnostic print (`[equiv] l1_obligation dropped=plain`, `tx_single viol=0`) |
| `[ptw-err]` | 29,141 | 18,450 | page-table walk ended in a fault — see sub-classes |
| `R Response Errored` (AXI DECERR) | 18,131 | 18,131 | a read nothing decodes reached the bus |
| `[hang]` | 900 (30 dumps) | 198 | commit gap > 2000 cycles |
| `[mmu-ife]` | 717 | 20 | instruction-side exception presented to fetch |
| `[seq-gap]` | 200 (print cap) | 12 | fetch sequence gap > 200 cycles |
| stall census `mem_viol` | 706,483 | 467,381 | memory-order violation replays; IPC 0.143 |

`[ptw-err]` sub-classes (r127m):

| count | instr | vaddr class | reading |
|---:|---|---|---|
| 16,553 | fetch | `0x800004f0` (one address) | M-mode trap-return window walked under the kernel `satp` at `mret` (r100/T42 "foreign walk") |
| 4,635 | data | `0x8004_5xxx` (OpenSBI stack) | physical address walked under a stale `mstatus.MPRV` context |
| 5,426 | data | 0, 3, 4, 8, 0x220 … | wrong-path loads with a null/garbage base, S-mode |
| 2,225 | both | user addresses | demand paging (architectural) |
| 242 | both | kernel image / vmalloc | to classify |

`R Response Errored`: 1 at cycle 5,570,552, then 18,130 between 350M and 370M
cycles (10M-bucket histogram: 8,745 + 9,385). `[mmu-ife]`: 227 U-mode
(demand paging) and 490 S-mode `cause=12` presentations (the kernel does not
take instruction page faults: wrong-path / stale-context fetches).

All of these are **not** architectural events except the ~2.2k demand-paging
walks: they are speculative or stale-context activity that left the core's
private state — a bus transaction, a page-table walk, a fetch exception
record.


## RFIX-131a-01 — speculative loads reach the bus outside memory

**Evidence.** 18,131 `R Response Errored` per boot (r127m and r128b, same
count): 1 at cycle 5,570,552 and 18,130 between 350M and 370M. With the
address-tagged harness (`a428ed7f3`, r131):
`[5570552] R Response Errored id=1 addr=0000000010001468 resp=3` — OpenSBI
at `0x8000b95a` restores `s3 = 0x1000_1000` and returns; no retired
instruction reads `0x1000_1468`; a wrong-path `ld …,0x468(s3)` put the read
on the bus and the xbar answered DECERR (`axi2mem` never answers an error).
The 350M–370M burst is OpenSBI `sbi_get_insn` (r128b window
352554330..352554760): `csrrw mtvec` @…544, `csrrs mstatus,MPRV` @…551,
`lhu a0,0(a6)` with `a6 = 0xffffffff80002a1e` @…635, DECERR at …557: the
`lhu` behind the CSR write is issued under the pre-write context (M-mode
bare) and its virtual address, truncated to PLEN, goes out as a physical
address.

**Root cause.** `load_unit` holds the rule already (a load flagged
speculative issues only when `dtlb_hit && !paddr_ni`; any other load to a
non-idempotent address waits for commit time with the store pipe drained —
`stall_ni`, `ABORT_TRANSACTION_NI`, `WAIT_WB_EMPTY`; the I$ does not fetch
speculatively from such a region; the write buffer keeps NI order). All of
it is gated by `NonIdemPotenceEn = NrNonIdempotentRules > 0 &&
NonIdempotentLength > 0`, and both hyp8 config packages declared two rules of
length 0: the gate was constant 0 and every address was treated as memory.

**Isolated test.** `verif/tests/custom/hyp8_spec_bus_clean.S` (M-mode, Sv39
root with the kernel-image alias only): A. 64 rounds of the MPRV window;
B. a trained-not-taken branch whose fall-through loads `0x468(base)`, probed
once with `base = 0x1000_1000` (vacant) and once with
`0x468(base) = 0x1000_0000` (UART receive register). tohost checks the data
and that the fall-through never takes architectural effect (count = 96); the
log must contain no `Response Errored` and no `[uart-axi-ar]`
(`run_hyp8_probe.py`; `run_hyp8_smokes.py` grades every smoke the same way).
Baseline on the r131 model (`hyp8-rfix131a-probe-base2`): tohost pass in
16,331 cycles, log dirty — `addr=00ffffff80003000`, `…3002` (A),
`addr=0000000010001468` (B, the witness address) and one
`[uart-axi-ar] addr=10000000` (a speculative read of a register with a read
side effect).

**Structural fix.** A PMA declaration, no logic: non-idempotent =
`[0, 0x1_0000)` (debug module + hole), `[0x2_0000, 0x8000_0000)` (devices
and holes), `[0xC000_0000, 2**56)`; idempotent = boot ROM + main memory. The
existing gate becomes live. RFIX-131a-02 removes the MPRV half of this class
at its origin as well; the PMA stays as the rule for branch wrong paths.

**Timing note (owed, not measured).** `paddr_ni` (three constant range
compares on the 44-bit PPN) now feeds `spec_issue_ok` → `data_req` and
`stall_ni`; the I$ `addr_ni` feeds `fetch_ok`. To be measured with sv-timing.

**Behaviour to watch when it first runs.** The NI paths of `load_unit`, the
I$ and the write buffer have never run in a hyp8 boot (constant-folded
away): every device load (UART LSR polling) now takes
`ABORT_TRANSACTION_NI` / `WAIT_WB_EMPTY`, and fetch from the debug module is
non-speculative.

**Backport (original RTL).** Every tier-R target package
`core/include/g6lc64_*_config_pkg.sv` carries the same
`NonIdempotentLength: {64'b0, 64'b0}` (e.g. `g6lc64_ooo_config_pkg.sv:187`);
declare the same three rules there (the SoC map in
`corev_apu/tb/g6lc_soc_pkg.sv` is the source of the bounds). The upstream
`cv*_config_pkg.sv` files are tier U: do not edit them. No RTL change is
needed in `core/load_unit.sv` — it has the same `paddr_ni` / `stall_ni` gate.

## RFIX-131a-02 — execution under a stale privilege / translation context

**Evidence.** `[ptw-err]` sub-classes of r127m: 16,553 ×
`vaddr=00000000800004f0 instr=1` (one address) and 4,635 × data walks for
OpenSBI stack addresses (`0x80045df0`, `…e00`, `…d80`); plus the 18,130
DECERR reads of RFIX-131a-01. Firmware at the two sites:
`_trap_exit`: `csrw mepc; ld; csrw mstatus` (`0x800004ec`, last slot of its
fetch line) `; ld; ld; mret` (`0x800004f6`) — the fetch window behind the
`mret` is looked up under the S-mode `satp` when the `mret` commits, misses
and starts a walk nobody owns. `sbi_get_insn`:
`csrrs mstatus,MPRV; lhu; …; csrw mstatus; csrw mtvec; ld (sp)` — the `lhu`
runs under the pre-MPRV context (bus error), the stack loads behind the
restoring write run under the stale MPRV context (walk of a physical address
in the S-mode table).

**Root cause.** CSR-class instructions (fu == CSR: CSR access, xRET,
ECALL/EBREAK, WFI, fences) change the privilege / translation context when
they commit, but the instructions behind them were dispatched, issued and
fetched before that, under the old context — and for one cycle after an
xRET the frontend still presents its old window under the new one. The tree
answered each visible consequence separately: r100 drops a "foreign" fetch
walk result by a page compare (`g6lc_mmu.sv` `ptw_walk_is_fetch`), T42 does
the same on the data side, r59 re-forms the refetch pc. The condition those
chains guard against — something executing under a context an older
in-flight instruction is about to replace — was never excluded.

**Isolated tests.**
- `verif/tests/custom/hyp8_ctx_switch_clean.S`: M-mode firmware at physical
  addresses the S-mode table does not map, S-mode payload at the kernel
  alias, 64 ecalls; the handler is the firmware's `sbi_get_insn` window and
  `_trap_exit` layout. No page fault is architectural, so the log must hold
  no `[ptw-err]`, `[mmu-ife]`, `Response Errored`. Baseline on the r131
  model (`hyp8-rfix131a-probe-ctx-base4`): tohost pass in 29,459 cycles, log
  dirty every round — 65 DECERR (`addr=00ffffff800000dc`), 130 data walks
  (`vaddr=0000000080003270/…278 instr=0`), 64 fetch walks
  (`vaddr=00000000800001c8 instr=1`).
- `verif/tb/core/tb_g6lc_hyp8_ctx_barrier.sv` (leaf `ctx-barrier`): the lane
  rule, exhaustive for 1/2/4/8 lanes.
- `verif/tb/core/tb_g6lc_hyp8_csr_credit.sv` (leaf `csr-credit`): the hold
  contract against the bench's ownership model, every cycle of the existing
  random run — high for every owner not cancelled this cycle (including the
  one committing now) and for the cycle after a commit.

**Structural fix: a context barrier.** One rule, stated once:

> nothing enters the out-of-order window, and the frontend makes no fetch
> request, behind a CSR-class instruction that has not committed.

- `csr_buffer.sv` `ctx_hold_o`: a CSR-class instruction is in flight — a
  live table entry (allocation at the dispatch consume edge → release at the
  commit edge; a cancelled or dead owner drops out through the liveness
  terms the credit already uses) or the cycle after a commit (`ctx_rel_q`:
  the context registers changed at that edge; the registered `flush_csr_i`
  and the frontend redirect are presented in it). Registered state only.
- `ooo/g6lc_ctx_barrier.sv` (new, combinational): lanes are kept up to and
  including the first CSR-class lane, none under hold. `issue_stage.sv`
  shows only kept lanes to `g6lc_ooo_dispatch`; a lane not kept is not
  acknowledged and `id_stage` re-presents it (the prefix acknowledge it
  already supports).
- `g6lc_core.sv`: `halt_frontend_i = halt_frontend | ctx_hold` (the existing
  fence.i hold input).
- Review mutant `G6LC_MUT_CTX_BARRIER_OFF` (hold constant 0) is the pre-fix
  behaviour for the tests above.

What this makes unnecessary (not removed in this round — to be retired once
the barrier has run): the r100 / T42 foreign-walk ownership compares for
the CSR/xRET cases, and the two-entry CSR address table (at most one
CSR-class instruction is in flight now).

**Not covered by the barrier.** Context switches that are not announced by
an instruction: trap entry (exception / interrupt taken at commit). The
kill is same-cycle there, but the frontend's old window can still be
presented for the cycle before the redirect lands (RFIX-131a-04). Branch
wrong paths (RFIX-131a-03).

**Costs / limits (unmeasured).** CSR-class instructions are now strictly
serialized (one in flight; the next dispatches two cycles after the
previous commits), so trap entry/exit sequences and non-flushing CSR reads
are slower; flushing CSR writes lose nothing (their successors were
discarded anyway). The hold is global across SMT harts (a CSR-class
instruction of one hart holds the other hart's dispatch and fetch) —
correct, conservative; a per-hart hold is a later refinement. Timing: an
NP-wide prefix AND on the dispatch valid lanes ahead of rename's capture
enable, and one OR on the frontend hold; to be measured with sv-timing.

**Verification.** See "Results" below.

**Backport (original RTL).** `core/issue_stage.sv` instantiates
`core/ooo/g6lc_ooo_dispatch.sv` the same way: add `g6lc_ctx_barrier` in
front of its `dispatch_valid_i`. `core/csr_buffer.sv` is the single-entry
upstream form (no dispatch allocation, no credit): the hold there is
"a CSR-class lane was acknowledged at dispatch and has not committed + 1",
which needs the dispatch-acknowledge strobe brought to it (the hyp8 tree's
`csr_disp_valid_i`) or a one-bit flag in `issue_stage`. `core/cva6.sv:1172`
has the same `halt_frontend_i` input (`core/controller.sv:398`). The
directed tests and the `ctx-barrier` leaf apply unchanged; `csr-credit`
needs the hyp8 table.

## RFIX-131a-03 — a load is speculative until it is the commit head

**Evidence.** 5,389 `[ptw-err] … instr=0` per boot for `vaddr` 0 (2,933),
4, 0x220, 3, 8 … in S-mode. `tq.sh around -r r127m -e ptw.data.null`: the
walk is requested between two retirements of straight-line code — by a load
that never retires, with a null base.

**Root cause.** The load unit already had the rule "a speculative load
issues only on a DTLB hit to idempotent memory and requests no walk"
(`tr_idle_ok`, `spec_issue_ok`). Its definition of *speculative* was the
`is_speculative_load` flag: "a branch issues on an older port in the same
cycle" (`ex_stage`), an in-order-issue notion. Under out-of-order issue
almost no wrong-path load carries it.

**Structural fix.** One definition: under OoO `spec_ld = not_commit_time`.
A load that is not the commit head issues only on a DTLB hit to idempotent
memory; otherwise it waits in `WAIT_SPEC_LOAD` and is handed back after the
dwell (`wsl_replay_fire`, 32 cycles), so it never holds the loads behind it.
The same definition subsumes the r71 / r124 flagged cases and the
non-idempotent hand-back of RFIX-131a-08. Review mutant
`G6LC_MUT_LU_SPEC_FLAG_ONLY` is the old definition.

**Isolated test.** `verif/tests/custom/hyp8_spec_walk_clean.S`: S-mode under
Sv39, a trained-not-taken branch whose fall-through dereferences a pointer
probed with 0, 8, 0x220 and a non-canonical value. r131 model: 3 walks
(`vaddr=0`, `8`, `0x220`); fixed tree: 0.

**Cost.** A correct-path load that misses the DTLB before it is the commit
head now waits up to 32 cycles and is replayed. Measured on the directed
programs only: `hyp8_dev_load` 26,527 → 30,061 cycles, `hyp8_spec_bus_clean`
13,706 → 13,728, `hyp8_ctx_switch_clean` 35,569 → 35,597; the 14 baseline
programs unchanged. The effect on a Linux boot's TLB-miss rate is not
measured.

**Not covered.** Wrong-path *stores* still translate (`store_unit` requests
its translation on arrival); the witness shows no store walks in the null
class, and the directed test's wrong-path store produced none.

**Backport.** `core/load_unit.sv`: same `tr_idle_ok` / spec gate on
`is_speculative_load`; the replacement needs `commit_tran_id_i` and the
replay path of the OoO tree.

## RFIX-131a-04 — a killed fetch drops its translation request

**Evidence.** 490 S-mode `[mmu-ife] cause=12` per boot; 272 are ITLB *hits*
on user addresses (`tq.sh sql` over `aux`): a U page fetched under S.

**Isolated test.** `verif/tests/custom/hyp8_trap_entry_clean.S`: U-mode
traps 128 times into an S-mode handler — 64 `ecall`, then 64 illegal
instructions. r131 model: 192 records. With the context barrier
(RFIX-131a-02): 64 — exactly the illegal-instruction entries (a trap no
CSR-class instruction announces). With this entry: 0. In the smoke list.

**Mechanism** (`+icf_trace` on the test, one trap; cycle A is the commit
cycle of the faulting instruction):

| cycle | I$ state | request | context | what happens |
|---|---|---|---|---|
| A | READ | `0xf0` (the fall-through), first cycle | U | the trap commits; the controller's flush is combinational, so `kill_s1/kill_s2` are up **in this cycle**; the translation answer is registered (`pmp_data_if`) and not there yet, so READ leaves for `KILL_ATRANS` |
| A+1 | KILL_ATRANS | `0xf0` held | **S** (`priv_lvl_q` changed at the edge) | the registered answer of cycle A arrives (valid, no fault) and ends the state; meanwhile the MMU evaluates the still-presented request again, now under S: ITLB hit on a U page -> `[mmu-ife]` |
| A+2 | IDLE | - | S | the fault of A+1 is on the answer register with nobody requesting |

So the kill and the context change are already aligned (kill in A, new
context from A+1); the one thing presenting an old-stream address under the
new context was the I$ state that holds a killed request "until the
translation answers". The two frontend holds tried earlier could not change
this: the request predates the trap and the frontend was already killed.

**Root cause.** `KILL_ATRANS` comes from the original cache, where the MMU
answered combinationally and a walk's result had no owner check: the killed
request was kept up so the walk it started would be delivered to it and not
to the next request. Neither holds in hyp8: the answer is a register beside
the request, valid only for the address on the pins (`if_rsp_current`), and
a walk result is delivered only to the request whose page it is (r100). The
state had no function left and one side effect: a translation request
outliving its kill — on a trap, into the next context (a fault record, or
on a miss a walk nobody owns; under an M-mode trap the old virtual address
taken as a physical one).

**Structural change** (`core/cache_subsystem/g6lc_icache.sv`).
- READ, killed without an answer: -> IDLE (was `KILL_ATRANS`); the state is
  removed from the FSM (7 -> 6 states; `KILL_MISS` is now encoding 5 in
  `+icf_trace`).
- The way-predictor re-read no longer keeps a killed request in READ.
- `areq_o.fetch_req = READ | READ_V`.
- Invariant, checked in every simulation including the Verilator model
  (`$error`, graded as a model error by the smoke runner): no translation
  request is presented in the cycle after `kill_s1`. With it, the commit
  cycle of a trap is the last cycle anything is fetched under the old
  context.

Timing (`sv-timing`, `analysis/timing/boards/rfix131a-b-{before,after2}`):
`g6lc_icache` worst register-to-register path 27.1 -> 26.75 FO4, 41 -> 40
paths over the 8-FO4 budget. The first form of the re-read guard (the kill
ANDed into the re-read condition) measured 27.75; the kill now selects
last, as in the response arm, and the condition's cone is unchanged.

**Verified.** `hyp8_trap_entry_clean`: 64 -> 0 `[mmu-ife]`, 23,394 cycles
before and after (a trap's kill lasts two cycles, so the earlier IDLE gains
nothing there). The 19 other programs pass with unchanged logs; cycle
counts move by -2 … -64 in four of them (`hyp8_csr_flush_skip` 2429 -> 2427,
`hyp8_h36_strlen_replay` 9095 -> 9084, `hyp8_zkn_kat` 6975 -> 6973,
`hyp8_ctx_switch_clean` 35597 -> 35533): a killed fetch frees the cache one
cycle earlier.

**Backport note.** `core/cache_subsystem/cva6_icache.sv` has the same
state. Removing it there is only correct together with (a) an owner check
on the page-table walk result (hyp8 r100, `ptw_walk_is_fetch`) and (b) an
answer that cannot be taken by a different request (hyp8: the registered
answer's address compare). Without those two the state is still doing its
original job.

## RFIX-131a-09 — "cancelled" has one definition at commit

**Evidence.** Not a census class: found from the RVFI stream while
isolating RFIX-131a-01. On the probe rounds of `hyp8_spec_bus_clean` the
trace shows the instruction behind the mispredicted branch retiring in the
branch's own commit cycle (`addi s7,s7,1`, `x23 = 0x31`, both `@10733`),
98 times for 96 architectural executions — while the next real execution
writes `0x31` again, i.e. the register was not written.

**Mechanism.** A mispredict cancels the younger slots through a combined
mask: the registered `cancelled` bit of each slot OR the window of the
branch resolving this cycle (`sb_cancel`). The registered bit is installed
at the following edge. The branch itself is committable in its resolve
cycle (the commit bundle merges a result that lands on the head in the same
cycle), and the slot behind it is then on commit port 1 with its result
long since written back. The commit bundle presented that slot with the
registered bit only, so it was acknowledged as a retirement; the rename
stage, which keys on the combined mask (`commit_arch`), treated the same
slot as cancelled.

**What leaked.** No register and no rename state — the PRF write and the
RAT / free-list commit are gated by the combined mask. Everything that
listens to `commit_ack` alone did see a retirement:
- `minstret` counted the instruction;
- `fflags` accrued the flags of a wrong-path floating-point instruction;
- RVFI printed it (and with it the trace database's retired counts).

**Isolated test.** `verif/tests/custom/hyp8_ghost_commit.S`: a late branch
(8 `mul` + 8 `div` behind its condition), trained not-taken, taken twice.
A: `minstret` between two reads against the exact instruction count. B: an
`fadd.d` behind the branch that is inexact only with the probe rounds'
operand; `fflags` must stay clear.
- model `5fb248e6…` (before): A delta 2253 for 2251 (+1 per probe round);
  with A's check disabled, B reads `fflags = 0x01` (NX).
- model `e72c7121…` (after): 2251, `fflags = 0`; RVFI retires the
  wrong-path `addi` of `hyp8_spec_bus_clean` 96 times, not 98.

**Structural change** (`core/sb_commit_bundle.sv`, `core/scoreboard.sv`).
The bundle takes the same-cycle half of the combined mask
(`sb_cancel.kill_req_o`); a slot it names is presented as a drop on every
port above 0 (`commit_drop_o`, and it merges no result). Port 0 keeps the
registered bit: it is the oldest entry of its hart and a mispredict cancels
only younger entries of that hart, so the term would be constant there and
port 0's decision path is unchanged. A simulation assertion states the rule
for all ports — a slot the combined mask names is only ever acknowledged as
a drop (`SBC_CANCELLED_RETIRE`) — which is also the check that the port-0
argument holds (it has to hold on the multi-core model too: mixed-hart
commit select).

Timing (`sv-timing`, same boards): `sb_commit_bundle` worst input-to-output
path unchanged at 21.9 FO4; the port-1 drop path 11.85 -> 14.2 FO4 inside
the module. Its new input, `sb_cancel.kill_req_o`, is 13.0 FO4 behind the
registered resolve record; the analyzer does not stitch the two sibling
modules, so the end-to-end figure (bounded by 13.0 + 14.2) is not measured.
If it shows on a stitched board, the equivalent cheap form for the
non-mixed select is "the resolving branch is the slot on port 0".

**Backport note.** Applies to any tree with the speculative scoreboard
(`sb_cancel` / `sb_commit_bundle`): wherever the architectural write is
gated by the combined mask and the commit acknowledge is not.

## RFIX-131a-10 / -11 / -12 — two harts on one core

`g6lc64_hyp8_smt2` (one core, two harts, the boot geometry) builds in ten
minutes and runs at scalar speed; `hyp8_smp_lrsc` with `NHARTS=2` (LR/SC and
AMO on shared counters, per-hart slots) is the reproduction. It failed on
the r131 tree too (A/B build), and the four-core model showed the same
first symptom, so these are not regressions of this round: two harts had
not run on hyp8 before. Three independent causes, each found from the trace
of the previous one's fix.

### -10: the resolved successor of a branch that commits in its resolve cycle

**Trace** (`+smt_flow_trace`). Hart 1 retires its `jalr` out of the boot
ROM; at the next thread switch its banked PC is 0 (`handoff … restore=0`),
and it fetches address 0 from then on.

**Mechanism.** Under the drained handoff the PC bank's frontier is the
successor of the last retired instruction, read at commit from
`bp.predict_address` for a control-flow instruction. That field holds the
*resolved* target only after `sb_lifecycle` installs it with the writeback.
The commit bundle already merges a writeback that lands on the head in the
same cycle (result, exception) — but not this field, so a branch committing
in its resolve cycle was presented with the registered value: the
prediction, or zero for an unpredicted `jalr`. A single hart never reads
the bank; the debug single-step `dpc` reads the same field.

**Change** (`sb_commit_bundle.sv`, `scoreboard.sv`). The same-cycle merge
carries the resolved successor when the resolve record names the presented
slot. Timing: one slot compare and a VLEN-wide select on
`commit_instr_o.bp.predict_address`, from the registered resolve record;
not measured.

### -11: the free list of one bank could run dry for good

**Trace** (`[dsp-stall]`, new, under `+disp_trace`). After 13 instructions
per hart the dispatch group is never taken again: `ren_stall=1`,
`r1_stall=1`, nothing in flight, `free=8 of 72` — and none of the eight in
the bank lane 0 allocates from.

**Mechanism.** Rename lane p allocates only from free-list bank
p % FreelistBanks (2 on hyp8). A retirement frees the register its
destination was mapped to *before*, whichever bank that was in. Lanes fill
in order, so bank 0 does most of the allocating and the architectural map
drifts into it. A bank no larger than the architectural state can end up
entirely mapped: empty, with nothing in flight to free into it. One hart
fits by construction (72 entries, 36 per bank, at most 32 mapped). The
default pool size was scaled by hart count for the map but not per bank:
two harts are 62 mapped registers against 36 per bank.

**Change** (`ooo/g6lc_ooo_dispatch.sv`). The pool has a liveness floor:
every bank holds the architectural registers of every hart plus one group
of spares (`FreelistBanks * (1 + 31 * NrHarts) + 4 * NrIssuePorts`; the FP
pool likewise); a larger configured or default pool is kept. One hart: 72,
unchanged (the scalar netlist is the same). Two harts, 2-wide: 103 -> 134.
Four cores x two harts, 8-wide: 199, unchanged (already above the floor).
The floor removes the stall; it does not make the two banks drain evenly —
that is a throughput matter for the bank-steering policy, not a liveness
one.

### -12: a refetch is {pc, hart}

**Trace.** With -10 and -11 both harts run, and the program fails its
LR/SC count: 72 for 96. Hart 0 retires `bnez t3` 60 times for 48 `sc.d`:
twelve rounds enter at the `bnez` without their own `lr`/`sc`. In the flow
trace hart 1's `sc.d` at `0x…84` retires, the counted drain runs, and the
thread switch that follows restores **hart 0** at `0x…88`.

**Mechanism.** A counted drain (CSR side-effect flush, replay, the flush
behind an `sc`) raises its refetch several cycles after its trigger, with
the PC it captured at the trigger. The hart was not captured: the PC was
banked into whichever hart's instruction sat on commit port 0 in the cycle
the refetch was raised — after a drain, usually the other hart's head or an
empty slot. The same pattern one level down: the CSR bank selected the
registered side-effect flush of "the committing hart" in the cycle after
the CSR retired, so with another hart on the port the flush was dropped or
took another bank's PC.

**Change** (`controller.sv`, `csr_write.sv`, `csr_regfile.sv`,
`smt/g6lc_smt_csr_bank.sv`, `g6lc_core.sv`). The drain captures the hart
beside the PC (from the CSR for a CSR flush, from the commit port
otherwise) and the frontend / PC bank use the captured hart for the drain's
refetch. The CSR bank raises the flush of whichever bank has one (one CSR
retires per cycle) and names that bank's hart.

The captured hart is selected by a registered "drain past its trigger"
flag, not by `drain_pending_o`: the latter carries the combinational
trigger, and the refetch hart feeds the SMT selector and the frontend,
whose outputs return into the controller's flush legs. The first form
(model `8c946e83…`, tag `rfix131a-c4`) closed that loop; the multi-threaded
model then gave different results run to run (`hyp8_h36_strlen_replay`
failing with three different cycle counts in six runs of one binary). Kept
here as the signature of a combinational loop in a threaded model:
identical binary, identical input, varying verdict.

Timing: a hart register beside `drain_pc_q` and a 2:1 select on the hart
into the frontend and the PC bank; not measured.

### Verified

`hyp8-rfix131a-c5-smt2-aggregate-t4` (model `2f3d94dd…`):
`hyp8_smp_lrsc`, `NHARTS=2`, passes in 67,448 cycles, four runs identical;
each hart 48 rounds, LR/SC and AMO counters 96. `hyp8-rfix131a-c5-aggregate-t4`
(model `8c637554…`): 21 of 21 programs pass with clean logs at the round-b
cycle counts, repeat runs identical.

**Backport note.** -10 and -12 apply to any tree with the speculative
scoreboard, the counted drain and the SMT PC bank; -11 to any tree with
banked free lists and more than one hart. None changes single-hart
behaviour.

## RFIX-131a-07 — TLB fill: a fill evicts every entry it overlaps

**Evidence.** `hyp8-osbi-scalar-r129b-mmustaged-diag2` (staged MMU,
`TlbStages=3`) stops at cycle 317,424,744 on `g6lc_tlb_hit_onehot0` in the
DTLB (`tq.sh asserts`). r129 analysis: with a staged lookup a response formed
before a fill commits reports a miss; the translation is walked and filled a
second time (vpn 7f81209 twice, 14 cycles apart).

**Review of `3f3083a64`.** It added `fill_dup`: a `TLB_STAGED`-gated,
field-by-field equality of the fill record against every stored tag (vpn,
asid, vmid, hart, is_page, v_st_enbl, napot), and refreshed the equal entry
in place. Two translations that are the same do not have equal records:
- a 2M / 1G page walked again from another 4K offset stores another
  `vpn[0]` (`vpn[1]`): not equal, second entry, multi-hit on the next
  lookup in that page;
- a global page walked under another ASID: not equal, both entries hit
  every ASID.
The mmu leaf shows it (mutant `G6LC_MUT_TLB_FILL_EQ_ONLY` = the r129 test:
the model stops on the one-hot assertion in the 2M case at t=7905).

**Structural fix.** The invariant the lookup relies on — no two valid
entries can hit the same lookup — is kept by the only writer that creates
entries, unconditionally (every `TlbStages`, every page size): *a fill evicts
every entry it overlaps and is written over one of them (else the PLRU
victim)*. Overlap = same context (stage enables, hart tag, VMID under
G-stage, ASID under S-stage unless either PTE is global) and intersecting
address ranges (a VPN level is compared only where neither is a larger page;
the low four VPN0 bits only where neither is NAPOT). The test may err only
towards "overlaps" (two-stage translation with different S/G sizes takes the
larger). `wild_levels()` states the page-size rule once, for the stored entry
and for the fill. `!lu_hit_o` on the fill is unchanged (install arbitration).

**Second finding (same leaf): the PLRU did not record staged hits.** The
PLRU update paired `rq_access` (the T1 *request* register) with `lu_hit_rsp`
(the T2 *response* register): one cycle apart, so a hit moved the tree only
when the requester held its access a second cycle. A fill then landed on the
entry that had just been hit (`TLB_OVL_KEEP_A` on the staged instance). Now
`lu_touch` = the answered hit (`lu_hit_q` staged, `lu_hit & lu_access_i`
combinational); the unstaged netlist is unchanged.

**Isolated tests.** `tb_g6lc_hyp8_mmu` T_H, on the three `HYP_EXT=0`
instances ({4,1}, {4,3}, {16,3} = entries, TlbStages): same 4K twice; 2M from
two offsets; 4K inside a 2M (the 2M goes); global under two ASIDs; 4K inside
a NAPOT range; four non-overlapping translations all stay. External checks
only (hit/miss/PTE) plus the DUT's own one-hot assertion. Mutants:
`G6LC_MUT_TLB_FILL_NO_EVICT`, `G6LC_MUT_TLB_FILL_EQ_ONLY`.

**Timing note (owed).** The fill arm gains a per-entry compare of the
registered update record against `tags_q` (27-bit VPN in three levels +
16-bit ASID), an OR-reduce and a lowest-set pick ahead of `tags_n`.

**Backport.** `core/cva6_mmu/cva6_tlb.sv` is upstream (tier U: do not edit
in place) and has the single-cycle lookup; the rule applies to any staged
derivative. The leaf cases are independent of the staging.

## RFIX-131a-08 — a non-idempotent load does not wait at the LSU head

**Evidence.** Found by RFIX-131a-01's own test on the first model with the
PMA: `hyp8_spec_bus_clean` wedged (budget-out at 400,000 cycles, no bus
error). `[hang]` dump (`tq.sh hangs`): commit head = the unresolved branch
`beqz a2` (`fu=4 op=17 pc=80000110`); the IQ window presents it, `take_ok=0`,
`lsu_rdy=0`; LSU bypass `cnt=4`; load unit `state=256` (WAIT_WB_EMPTY) on
`vaddr=0000000010001468`, `dtlb_hit=1`, write buffer empty.

**Root cause.** The wrong-path load to the device address was taken into the
non-idempotent path (`ABORT_TRANSACTION_NI` → `WAIT_WB_EMPTY` →
`WAIT_TRANSLATION` → `WAIT_GNT`, looping while `stall_ni`) to wait for
commit time. The load unit serves the LSU queue in order, so every load
behind it waited too; the queue filled (4); `lsu_ready` fell; the issue
lane's LSU occupancy gate held the lane the branch was presented on; the
branch that would squash the parked load never issued. A wait for commit
time at the head of an in-order queue can only be ended by something that is
behind it.

**Structural fix.** A non-idempotent load runs as the commit head; one that
reaches the load unit earlier is *handed back* — popped and replayed,
refetched at commit (the existing T33 `lu_replay_o` path) — in
`WAIT_WB_EMPTY` (`ni_yield`); and the `WAIT_SPEC_LOAD` dwell yield (r124) no
longer requires a DTLB miss: any load still flagged after the dwell yields.
The reference FSM carries the same two arms (equivalence assertions).

**Isolated tests.** `hyp8_spec_bus_clean.S` (the wedge) and
`hyp8_dev_load.S` (new): CLINT `mtimecmp` / `mtime` / `msip` loads and
stores interleaved with memory traffic, 64 rounds, checked for order.

**Cost (measured on `hyp8_dev_load`).** 26,527 cycles for 1,627
instructions, `lu_replay=192`: every device load that issues before it is
the commit head costs a replay and refetch. Device-polling loops (UART LSR)
will pay this; holding such a load at dispatch instead of replaying it is
the refinement if a boot shows it matters.

**Backport.** `core/load_unit.sv` has the same NI states and no replay
output; the hand-back needs the scoreboard replay path of the OoO tree
(`lu_replay_o` → `sb_lifecycle`).

## Results (remote testharness, closure-rfix131a)

Model: `hyp8-rfix131a-aggregate-t4`, target `g6lc64_hyp8` (scalar), lint
scalar/smt2 0 `%Error`, model `5fb248e681b5f180…` (final tree: RFIX-131a-01,
-02, -03, -07, -08), simulation PGO profiles applied, Verilator binary `d219b63fc4f8fcba`.

Directed programs (pass = tohost **and** clean log; r130 baseline cycles in
parentheses):

| program | cycles | bus_err | uart_rd | walk_err |
|---|---|---|---|---|
| h34_shift_dep | 685 (685) | 0 | 0 | 0 |
| h33_st_fwd | 1011 (1011) | 0 | 0 | 0 |
| hyp8_branch_cancel | 492 (492) | 0 | 0 | 0 |
| hyp8_csr_flush_skip | 2429 (2364) | 0 | 0 | 0 |
| hyp8_amo_store_order | 2163 (2199) | 0 | 0 | 0 |
| hyp8_amo_ready_order | 1207 (1231) | 0 | 0 | 0 |
| hyp8_f14_store_offset | 666 (671) | 0 | 0 | 0 |
| hyp8_h35_subword | 3038 (3038) | 0 | 0 | 0 |
| hyp8_h36_strlen_replay | 9095 (9095) | 0 | 0 | 0 |
| hyp8_h37_ldst_viol_strlen | 5959 (5959) | 0 | 0 | 0 |
| hyp8_h38_zbb_zero | 883 (883) | 0 | 0 | 0 |
| hyp8_lrsc_store | 988 (983) | 0 | 0 | 0 |
| hyp8_sv39_load | 3933 (3893) | 0 | 0 | 0 |
| hyp8_zkn_kat | 6975 (6949) | 0 | 0 | 0 |
| hyp8_spec_bus_clean | 13728 (new; r131 model: 3 DECERR + 1 UART read) | 0 | 0 | 0 |
| hyp8_ctx_switch_clean | 35597 (new; r131 model: 65 DECERR + 194 walks) | 0 | 0 | 0 |
| hyp8_dev_load | 30061 (new; 26527 before RFIX-131a-03) | 0 | 0 | 0 |
| hyp8_spec_walk_clean | 13806 (new; r131 model: 3 wrong-path walks) | 0 | 0 | 0 |
| hyp8_smp_lrsc | 11012 (new; built with NHARTS=1 on this single-hart model) | 0 | 0 | 0 |

Seven baseline programs changed cycle count (between −36 and +65); the other
seven are identical. The change set that could move them is the context
barrier, the PMA gate and the load-unit yield; which one moved which program
was not separated.

Leaf benches (`run_hyp8_memory.py`, 23 registered):

| result | leaves |
|---|---|
| pass | csr (76), csr-credit (5 cases incl. the hold contract), ctx-barrier (4 cases, 131,624 patterns), memory (176), issue, lsq-credit (252), flu, iqleg, dispatch (125), realign, linecheck, queue, alu (19,532), rom, pmp (23), sc-backoff (55), dcache (345), lsq (2,826), mmu (818, miter 990), ctrl, lbuf (22) |
| mutants fail as required | mmu + `G6LC_MUT_TLB_FILL_NO_EVICT`, mmu + `G6LC_MUT_TLB_FILL_EQ_ONLY` |
| not runnable | pmp-write, mshr: their reference/candidate sources (`g6lc_hyp8_pmp_bank_reference.sv`, `g6lc_l2_mshr_reference.sv`) are not in the tree |

The 19 programs and the 21 runnable leaves ran on the final tree
(`hyp8-rfix131a-smokes-t4` in the trace database: 19 programs, 19 pass,
0 error events).

Leaf infrastructure repaired on the way (each was failing before this round,
unrelated to the fixes): `csr` / `issue` / `lsq-credit` / `flu` did not
verilate (`cf_math_pkg` missing from their source lists); `csr` failed
`CSRTAB_LEGAL_FIRE_1` (the bench predates the r59 one-cycle commit hold
after a CSR fire; the r127 worklog had recorded it as "pre-existing");
`lsq-credit` never printed its token (its section runs under
`+credit_only`); `ctrl` drove main-tree Storamic controller ports the hyp8
controller does not have (now under `G6LC_CTRL_STORAMIC_PORTS`).

## Trace database (`verif/regress/remote/hyp8/tracedb/`)

`ingest.py` turns the model log of a run (witness, smokes, probe) into rows
of one SQLite file with categorical columns; `query.py` holds the reports;
`tq.sh` runs either on the remote host, next to the logs
(`/opt/testharness/tracedb/hyp8-trace.sqlite`: 45 MB for the witness logs
r127m … r131, 10.2 GB of text; 13 s for the 5.2 GB r127m log).

| table | content |
|---|---|
| `run` | tag, test, kind, rev, model, argv, budget, last cycle, cores, harts, verdict |
| `event` | cycle, core, hart, class, etype, addr, pc, aux, detail (JSON), raw line |
| `etype` | error type → class, origin (`wrong-path`, `stale-context`, `liveness`, `model-assert`, `architectural?`, `idle`, …), RFIX entry |
| `census` | periodic stall census per hart: retired, IPC, flush cycles, replays, memory violations |
| `uart` | console lines with the cycle they were printed at and the kernel time |
| `rvfi` | retired instructions around anchor events (bisected out of the per-core traces, never scanned) |
| `pc_sample` | sampled PC / privilege / region profile over the whole run |
| `thread` | per core / hart: retired, IPC, last cycle, max retirement gap, WFI |
| `kv`, `symbol` | `[equiv]` / `mc_*` counters; firmware symbols |

Reports: `runs`, `classes`, `origins`, `timeline`, `top`, `around`,
`asserts`, `hangs`, `threads`, `uart`, `profile`, `diff`, `sql`.

What it showed that the greps had not:
- `hangs`: of r127m's 30 commit-gap dumps, 24 have **WFI at the commit
  head** (`idle.wfi`, 1.537B–1.540B: the idle shell) and 6 are the LR parked
  by the SC backoff. The class is 6, not 30.
- `uart`: the boot's cycle clock (section 0) — which is what showed the
  earlier budget claim to be wrong.
- `classes` over r127m / r128b / r129-deep / r129b: `stale-context` events
  21,193 / 16,976 / 13,766 / 4,108, and the 18,131 bus errors are identical
  in every run that passes 370M cycles: deterministic firmware behaviour.
- `asserts`: the two model stops with their last retired instructions —
  r129b `g6lc_tlb_hit_onehot0` @317,424,744 (RFIX-131a-07) and r129-deep
  `lu_pop_is_presented` @375,989,307 (deep profile, not the boot binding;
  `56af5ea39` narrowed that assertion afterwards).
- `timeline -b 200000000`: memory-order replays run at ~193k per 200M
  cycles through the kernel's quiet phase (600M–1200M), IPC 0.25.

Limits: per-thread columns are populated from what the logs carry — the
ingested runs are all single-core, single-hart, so the core/hart split has
not been exercised on a multi-core log; kernel PCs are not symbolized (no
`vmlinux` on the host, only the firmware ELF).

## Tracing changes for multi-core logs

- `[ptw-err]`, `[mmu-ife]`, `[seq-gap]`, `[stall-census]` and `[hang]` end
  with `at=%m` (their instance path); `ingest.py` reads the physical core
  from `gen_core[N]`, so `event.core`, `thread.core` and the census rows
  are per core. Not yet exercised: no multi-core log exists.
- The per-event `[l1 dcache wbuffer] L1 obligation dropped` line is printed
  only under `+wbuf_obl_trace`. It was 43 M lines (5 GB) of the r127m log,
  and its volume is what cut other records and the harness verdict mid-line
  (four passing programs had no verdict row in the database until
  `ingest.py` learned to read a verdict glued behind a cut record). The
  ledger counters (`[equiv] … l1_obligation`) and the `g6lc_l1_obl`
  assertion are unchanged.
- `hyp8_smp_lrsc.S` (`NHARTS` from `HYP8_TEST_DEFINES`) is the first
  program meant to run on every hart: IPI release of the secondary cores,
  LR/SC and AMO on shared counters, per-hart slots on shared lines. It
  passes built for one hart on the scalar model; the 8-hart run needs the
  `g6lc64_hyp8_mc` model (`build/rfix131a/mc-model-and-smp.sh`).

## Results, round b (remote testharness, closure-rfix131a-b)

Model: `hyp8-rfix131a-b2-aggregate-t4`, target `g6lc64_hyp8`, lint
scalar/smt2 0 `%Error`, model `db8a7e820c904962…` (round a + RFIX-131a-04,
-09), 234 simulation-PGO profiles applied, Verilator binary
`deeede0a7a490c2c` (`tools/verilator` 6fa24f6fa). (`…-b-…`, model
`e72c7121…`, is the same tree with the first form of the I$ re-read guard;
identical results.)

21 of 21 directed programs pass with clean logs (no bus error, no UART
read, no walk / fetch-fault record in the `*_clean` programs, no model
error): the 19 of round a, `hyp8_trap_entry_clean` (23,394 cycles) and
`hyp8_ghost_commit` (50,777 cycles).

Leaf benches on closure-rfix131a-b (new toolchain): the 21 runnable leaves
pass (`dispatch` on a rerun: its model compile hit the 1800 s limit while
the host was building three models); `pmp-write` and `mshr` are still not
runnable (reference sources absent).

Same tree, `g6lc64_hyp8_l3` (one core, L2 + L3 on;
`hyp8-rfix131a-b2-l3-aggregate-t4`): 21 of 21 programs pass with clean
logs. The cache hierarchy on a single core is not where the multi-hart
failures below come from.

## Multi-core model build (what it costs and why)

The first `g6lc64_hyp8_mc` build of this round did not finish inside its
6 h budget: the runner timed out at 21,600 s while Verilator was still
elaborating, the timeout killed only the wrapper, and the orphaned
`verilator_bin` ran on to completion five hours later (39,300 s in all,
13 GB of C++ in 4,540 files; the scalar model is 0.47 GB in 237).

- **Why 13 GB.** The multi-core profile is not four scalar cores: each core
  is 8-wide issue with a 128-entry ROB and two harts
  (`g6lc64_hyp8_mc_config_pkg.sv`), against 2-wide / 32 entries / one hart
  for the scalar boot model. One core's share is ~3.2 GB, 7x the scalar
  model.
- **Why 11 h.** 38,660 s of the 39,300 s were one stage, `025_split_var`
  (`--stats`); every other stage together took 11 minutes. The fork's
  packed-variable split found the module of *every* variable reference by
  following `backp()` up to the module, and inside a statement list
  `backp()` is the previous sibling — linear in the list per reference,
  quadratic over the netlist, and unroll-before-split makes the lists long.
  Fixed in `tools/verilator` 6fa24f6fa (one top-down walk recording each
  split candidate's module, a second comparing it with the module of each
  reference). Scalar model: stage 025 36 s -> 3.2 s, and all 237 generated
  sources are byte-identical to the 44063db8 output for the same closure.
  The commit is local to the submodule checkout (not pushed; the
  superproject gitlink is unchanged); the builder source is staged from it
  with its tree id verified (`560aaf2c…`), toolchain
  `verilator-v5.008-g6lc-6fa24f6f-pgo`, `verilator_bin` `deeede0a…`, runtime
  header digest unchanged (`e900ec45…`).
- **Runner changes** (`run_hyp8_integration.py`, `hyp8-build-harness.sh`):
  a timeout now kills the whole process group; `HYP8_RESUME_TAG` continues
  an earlier run in place (its verified source, its completed verilation;
  the data closure of a resume may only carry runner tooling and test
  sources); `HYP8_BUILD_PGO_STAGE=verilate|instrumented|use` splits the
  build so no stage is redone and the SMP directed program runs on the
  instrumented model (functionally the final one; its run is the
  simulation-PGO training). `build/rfix131a/mc-staged.sh` drives the three
  stages.

## First multi-hart runs (isolated, `hyp8_smp_lrsc`)

Nothing multi-hart passes yet. Three runs, smallest reproduction last:

| model | harts | result |
|---|---|---|
| `g6lc64_hyp8_mc`, round-a tree, instrumented (`hyp8-rfix131a-mc-aggregate-t4`) | 4 cores x 2 | stopped by hand at 156 k cycles: cores 1–3 retire nothing, not even the boot ROM; on core 0 hart 1 retires the 6 ROM instructions and stops, hart 0 reaches `_start`, then retires one PC (`0x80000034`) every 66 cycles for good. A fetch takes 60–120 cycles. |
| `g6lc64_hyp8_smt2`, round-b tree (`hyp8-rfix131a-b2-smt2-aggregate-t4`) | 1 core x 2 | no verdict in 400 k cycles: hart 1 stops after the ROM (`@637`), hart 0 after `bgeu s0,s1,park` (`@1039`); from then on the window is empty, the instruction queue holds hart 0's next instructions and decode never takes them (`[hang] FE: … fe_v=11 fe_rdy=00`). |
| `g6lc64_hyp8_l3`, round-b tree | 1 x 1 | passes (above) |

So the failure does not need four cores, the 8-wide geometry, or L2/L3: one
core with two harts on the boot geometry shows it, in a model that builds in
ten minutes and runs at scalar speed. That is the reproduction to work
from.

It is not a regression of this round. A/B: the r131 closure built for
`g6lc64_hyp8_smt2` (`hyp8-rfix131a-ab-r131-smt2-aggregate-t4`, toolchain
44063db8) fails the same program at the same point — hart 1 stops after
its jump out of the ROM (`@527`), and the records printed for hart 0 then
run `_start` a second time (again reading `mhartid = 0`), skip from
`0x80000018` to `0x80000034` and retire that one PC every 62 cycles to the
budget (6,454 records, no verdict). What differs between the two trees is
only what the stream does after it has gone wrong. The r76 program already
lists "mc2 reset fetch" as open: two harts have not run on hyp8 since at
least then, and every Linux witness so far was single-hart.

**Simulation rate of the multi-core model.** Measured on the instrumented
model, 4 threads: 206 cycles/s (cycle 68,619 -> 87,957 in 94 s). The scalar
boot model runs ~10.8 k cycles/s and needs 1.53 B cycles to the shell. Even
at several times the instrumented rate, an 8-hart Linux boot on
`g6lc64_hyp8_mc` as configured (8-wide issue, 128-entry ROB per core) is
weeks of wall time per attempt. A multi-core Linux witness needs a smaller
multi-core profile (the boot geometry per core) or a shorter boot; this is
a decision, not something the build can fix.

## Where the boot's cycles go (r127m stall census, correction of RFIX-131a-06)

The census counts load replays and memory-order violations together
(`mem_viol=706,483`); the load unit's own replays are 8,415 of them. All
flush cycles of the whole run are 8.66 M of 2,671 M (0.3 %). Memory-order
replays are not what holds IPC at 0.26 and RFIX-131a-06 is closed without a
change.

At cycle 1.0 B (261.5 M instructions retired, IPC 0.261; `tq.sh sql` over
`census.detail`), the 813 M cycles without a retirement are:

| commit head is | cycles |
|---|---|
| issued, result not back yet (`inflight`): alu 257.7 M, ld 143.7 M, st 118.9 M, br 19.2 M | 542 M |
| not issued yet (`notissued`): alu 100.3 M, st 26.4 M, br 13.5 M, ld 12.9 M | 155 M |
| a store waiting for the store buffer (`st_sb`) | 58.5 M |
| ROB empty | 49.6 M |

An ALU instruction at the commit head that is still unissued or in flight
(358 M cycles for 170.6 M ALU instructions) means the window is nearly
empty most of the time: the instruction at the head has only just arrived.
The backend is supply-limited. The fetch side shows why in the
`+icf_trace` of the trap test: with translation on, every fetch is READ
(request), READ (the registered translation / PMP answer), READ_V
(response) — three cycles per 8-byte fetch at best — and the frontend often
has no next request ready in READ_V (two further idle cycles in the traced
loop). This is the staging the 8-FO4 work put there (registered PMP
verdict, registered hit response); it is recorded here as the measured cost
of that staging on a boot, not as a defect. Nothing was changed.

## Open classes (analysis so far)

- **RFIX-131a-05** — 6 real commit gaps (LR parked by a saturated
  SC-backoff mask, 396.95M / 429.42M; r130 fix `67f413a63`, `sc-backoff`
  leaf passes). Not re-observed on a boot.
- **RFIX-131a-13 (open) — four cores.** `g6lc64_hyp8_mc` on the round-c
  tree (`hyp8-rfix131a-c5-mc-aggregate-t4`: verilation 631 s with the fixed
  fork, 4,363 sources, phase-1 compile ~70 min at -j12), `hyp8_smp_lrsc`
  with `NHARTS=8`, instrumented model. Progress against the round-a model:
  cores 0 and 1 both run (harts 0–3 retire; hart 1 is inside its LR/SC
  round at cycle 3,500), cores 2 and 3 have not retired yet. The run stops
  at cycle 3,600 on the model's own check `ooo_switch_drained` in core 1:
  a thread switch while the LSQ reports busy
  (`[ooo-switch-drained] hart=0 sbem=1 sbn=0 stp=1 lsqb=1 rob=0 iq=0
  starve=1`), ten cycles after hart 3's `jalr` out of the ROM retired —
  with no load or store dispatched on that core. `lsq_busy_o` also counts
  staged update records (`ev_count`); the selector takes its switch
  decision one cycle before the `switch_o` pulse the check samples. Not
  seen on the two-hart, 2-wide model. Leaf benches on closure-rfix131a-c5:
  the 21 runnable leaves pass.
- **Owed measurements** — a stitched `sv-timing` figure for the port-1 drop
  path (RFIX-131a-09); `paddr_ni`, the context barrier and the TLB fill
  compare; boot-level cost of CSR serialization, non-idempotent load
  replays and commit-head walks.

## RFIX-131a-14 — SMP LR/SC lost update: exclusive monitor keyed by split AXI id (mc)

**Symptom.** `hyp8_smp_lrsc` (`-DNHARTS=8`) on `g6lc64_hyp8_mc` (4c x 2t,
instrumented phase-1 model, commit `16855c27f` LSQ fix) ran all four cores to
retirement and exited `tohost=1` at 127,611 cycles — `f_lrsc`: the shared
`lr.d`/`sc.d` counter `CNT_LRSC != ROUNDS*NHARTS` (384). Lost updates, not a
livelock (DONE==8 was already satisfied).

**Isolation.** `hyp8_smp_lrsc_kill.S` (new, `verif/tests/custom/`) — hart 0
(core 0) `lr.d X`, hart 2 (core 1) plain-`sd X`, hart 0 `sc.d X` must fail —
**passed** on the same model. So a remote store does kill a reservation
(address-wide `clr` in `axi_res_tbl`). The defect is not kill; it is the
LR→SC *reservation correlation* under contention.

**Root cause (confirmed by `+f14_trace` on the built model).** HPDCACHE issues
LR/SC as LDEX/STEX on **split AXI ids** — separate read/write id spaces. On
the DRAM boundary the monitor sees, for one hart's `lr.d`/`sc.d` pair on the
same word:

    adapter_ar id=3  ->  slv_ar lock=1  id=0x01   (LR  sets tbl[0x01]=addr)
    adapter_aw id=3  ->  slv_aw lock=1  id=0x00   (SC  checks tbl[0x00]==addr)

The mc build selected the **pulp `axi_riscv_atomics_wrap`**: `axi_riscv_lrsc`
+ `axi_res_tbl`, a reservation table `tbl[2^ID_WIDTH][addr]` that is
**keyed by AXI id** (`art_set_id=slv_ar_id`, `art_check_id=slv_aw_id`). With
LR on id 0x01 and SC on id 0x00 the reservation is stored in a slot the SC
never reads; SC success then depends on coincidental id collisions across the
8 harts, so `sc.d` commits a stale `base+1` and updates are lost — exactly
the observed wrong count that still completes.

The SoC already carries the correct monitor: `g6lc_axi_lrsc` /
`g6lc_axi_atomics_wrap`, an **address-keyed** NRes-entry table that "needs no
hart id" (its header cites this split-id case). It was gated behind
`G6LC_AI_EXCL_MULTI`, defined only for `G6LC_AI_DRAM_*` channel configs —
`g6lc64_hyp8_mc` sets none, so it silently fell back to the pulp wrap.

**Fix (testbench-only, `corev_apu/tb/g6lc_testharness.sv`).** Select
`g6lc_axi_atomics_wrap` whenever `NR_HARTS > 1` (or `G6LC_AI_EXCL_MULTI`),
`NRes = NR_HARTS`, `+define+G6LC_AI_LRSC_SINGLE_RES` still forces the
pre-fix depth-1 negative oracle. Single-hart targets (`g6lc64_hyp8`, `_l3`,
`_deep`, `_mmu_staged`, `_iqsteer2`, NR_HARTS=1) keep the pulp wrap unchanged.
Affects `g6lc64_hyp8_mc` (8) and `g6lc64_hyp8_smt2` (2); all required modules
(`g6lc_axi_lrsc`, `g6lc_axi_atomics_wrap`, `axi_cut_intf` in `axi_cut.sv`,
`axi_riscv_amos`) are already in both `Flist.hyp8_sim` and
`Flist.hyp8_mc_sim`. No core-RTL or `core/`/`corev_apu/` src change; no
synthesis impact. Generate-if keeps `i_axi_riscv_atomics` name; no TB probe
reaches inside the instance (only `master[DRAM]`/`dram` buses are observed).

**Verify.** Rebuild `g6lc64_hyp8_mc`, rerun `hyp8_smp_lrsc` NHARTS=8: expect
`tohost=1` with `CNT_LRSC==384`. `hyp8_smp_lrsc_kill` remains a regression
oracle (its SC must still fail after the remote store). `+f14_trace` after
the fix should show the g6lc monitor consuming LDEX/STEX regardless of the
0x01/0x00 id split.

**Backport.** Testbench selection only. If a future coherent-port/SoC needs
LR/SC at a non-DRAM boundary, the transferable rule is: *key reservations by
address (or by a hart/transaction tag the initiator controls), never by an
AXI id that an upstream split-id source does not preserve between the LR's
read channel and the SC's write channel.*

## RFIX-131a-15 — SMP directed-suite infrastructure + mc witness readiness (prep, no RTL)

While `rfix131a-d` `g6lc64_hyp8_mc` instrumented compiles, the multicore
directed suite (`verif/tests/custom/multicore/*.S`, 154 programs written for
the ariane review harness) was wired for the hyp8 model so SMP correctness is
qualified in fast isolated runs *before* the slow Linux/OpenWrt witness:

- `verif/regress/remote/run_hyp8_mc_directed.py` (new): assembles each .S
  with the hyp8 `GCC_FLAGS` + `link_verilator.ld`, reads `tohost` via `nm`
  (auto-detect — no fixed-address assumption), runs the built
  `output/model/Variane_testharness` with `+tohost_addr/+max-cycles/
  +debug_disable`, and grades with the same SUCCESS/tohost/wedged/log_dirty
  rule as `run_hyp8_smokes`. Per-test `-D` defines and an optional `-march`
  override (zacas). `oracle_neg` entries expect the deliberate fail code.
  Emits `smokes-results.json` so `tracedb/ingest.py` picks the `.log`s up as
  `smoke` kind (mc `gen_core[N]`/`hart=` columns already handled).
- `build_closure.py`: `verif/tests/custom/multicore/*.S` added to
  `EXTRA_GLOBS` so future closures carry the sources.
- `build-platform/workspace/build/rfix131a/mc-directed.sh` (workspace,
  untracked helper): waits for `results.json`, pushes `multicore/`+`common/`
  as `--data`, runs the suite via `testharness_proxy py`.
- Curated 34-program suite: SMP bring-up/hart liveness, shared-line + L2/L3
  coherence, LR/SC+AMO, traps/CSR, icache, PMU.

**mc witness readiness verified.** `hyp8-mc-witness-launch.sh` +
`g6lc-hyp8-mc-linux.dtb` + `linux-mc` firmware profile confirmed: the
`fw_payload.elf` for sha `04f3b24b…` is already present at
`/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/...`.
Witness fires on the `use` (profile-use) model once `results.json` reports
`build_complete`.

**Predicted first mc-witness risk.** `hyp8_smp_lrsc` runs identical M-mode
code on all harts — it does not exercise divergent per-hart architectural
state. The core banks per-hart CSRs (`priv_lvl_b`, `satp`, `mstatus`,
`commit_hart`/`whart_commit_id`, `sb_head_pc[hart]`, per-hart `irq_i`/
`ipi_i`/`time_irq_i`). Linux is the first workload to give SMT2 sibling
harts different `satp`/`stvec`/`sie` and per-hart timer+IPI; a CSR-bank leak
or commit-port misroute is the expected first mc-boot failure mode,
diagnosable via the per-hart tracedb columns + `[mmu-trace]`/commit probes.
The directed suite's `mc_smt2_boot_release`, `mc_hart1_trap`,
`mc_icache_switch_storm` and coherence tests are the fast oracle for that
class before the witness.

## RFIX-131a-16 — Zacas (RVZacas / AMOCAS.W/D/Q) enablement + first functional result

**Enablement (done).** `RVZacas: bit'(1)` added to both
`core/include/g6lc64_hyp8_config_pkg.sv` and `g6lc64_hyp8_mc_config_pkg.sv`
(RVZacas requires RVA; both already set). `build_config_pkg.sv` now derives
`NrRgprPorts = NrIssuePorts*3` under `G6LCCfg.RVZacas` (was *2), so
`OPERANDS_PER_INSTR=3` — scalar 2 issue ports -> 6 GPR read ports; mc scales
correspondingly. Decode (`g6lc_decode_s2.sv`) has explicit AMOCAS.W/D/Q cases
with the corrected even-pair check `instr.atype.rd[7] || instr.atype.rs2[20]`
(packed fields keep instruction bit positions; `[0]` indexing resolved to X/0
under Verilator and was rejected by slang). `fu_data_t`/`lsu_ctrl_t` carry
`operand_c` + `_hi` halves; `issue_read_operands.sv` routes rd-sourced
expected->operand_c, keeps imm=0 for the rs1 address, forwards third-source
hazards, and does the AMOCAS.Q two-phase register-pair gather. LSU ->
`g6lc_hpdcache_if_adapter` -> hpdcache AMO/uncached paths plumbed.

**Strict test.** `verif/tests/custom/hyp8_amocas.S` — D/W/Q success + mismatch,
.W sign-extension, Q pair-gather, and a distinct `0xE1` illegal-instruction
code so "not implemented" is separable from wrong CAS results. Encodings
verified by objdump (rd=a0 expected/dest, rs1=a2 addr, rs2=a1 new).

**Scalar build (g6lc64_hyp8, RVZacas=1): CLEAN.**
`hyp8-rfix131a-zacas-aggregate-t4`: lint scalar+smt2 rc=0, build_complete,
model `b342ca0e…`, simPgo=237 profiles, verilator `deeede0a…` (-pgo fork,
unroll+split_var). **All 22 baseline directed tests PASS** incl.
`hyp8_trap_entry_clean`, `hyp8_spec_walk_clean`, `hyp8_dev_load`,
`hyp8_ghost_commit`, `hyp8_smp_lrsc` (1-hart).

**FIRST FUNCTIONAL BUG — AMOCAS.D returns rd=0.**
`hyp8_amocas` fails at `fail_d_ret` (code 11): rvfi trace at the amocas.d
(0x80000078) shows `x10(a0)=0x0` while the CAS store path was entered.
Encoding re-verified correct (funct5=00101 funct3=011 rd=a0 rs1=a2 rs2=a1).
Root-cause analysis of `g6lc_hpdcache_if_adapter.sv` CASD FSM:
- `is_casd_req` = RVZacas && req && amo_op==AMO_CAS1 && (!word || is_quad);
  store_unit maps AMO_CASW/D/Q -> AMO_CAS1, so D takes the local CASD RMW FSM.
- casd_old_q capture (`casd_old_d = hpdcache_rsp_i.rdata[0]` @ CASD_LD_WAIT)
  and the ack/result mux (`result = casd_old_q` @ CASD_DONE) read correctly;
  ack is correctly gated to CASD_DONE while casd_busy (no premature ack).
- Most likely defect: the CASD **load returns 0** (forced
  `pma.uncacheable` UC path, or addr/tag path), so casd_old=0 and
  `rdata[0]==operand_c` fails -> CASD_INVAL -> rd=0, mem unchanged.
  AMOCAS.W (packed HPDCACHE AMO path) and .Q untested — test bails at the
  first D check.
- NEXT: confirm whether mem stayed 0x1111 (mismatch path) vs updated; probe
  the UC load return for a 64-bit CASD LD; check operand_c (expected)
  routing through data_cmp. Do NOT weaken the strict test.

**mc wedge (parallel finding).** `hyp8_smp_lrsc` on rfix131a-d instrumented
mc model WEDGED (not a timeout): 2 cores stuck at store-commit, `amo_rdy=0`,
`since_ack=22000`, IQ arb no grants, frontend `fe_rdy=0`. NRes=8 verified
correct (NR_HARTS=4x2). Isolation run `rfix131a-d-mc-isolate`
(mc_boot_sanity/mc_hart1_store_visible/mini_lrsc_d/mini_amoadd_w_spin) launched
to split atomic-path (my g6lc_axi_lrsc wrap) vs general store/coherence.

**RFIX-131a-16 refinement — CASD path divergence identified.** Comparing
`hpdcache_req_amo` (normal AMO, works: LR/SC/AMOADD all pass) vs
`hpdcache_req_casd` (AMOCAS.D/Q local RMW): both use `phys_indexed=1`,
`addr_tag=amo_tag`, `tid='1`, `need_rsp=1`. The ONE functional divergence is
`pma.uncacheable`: normal AMO = `hpdcache_req_is_uncacheable || LR || SC`
(i.e. cacheable for RAM); **CASD hard-codes `uncacheable=1'b1`** (line ~606)
to force the uncached path for its multi-beat load/store/inval. Since the
CASD `casd_old`/ack/result logic verified correct and `rd=0` ⇒ the captured
`rdata[0]` was 0, the defect is almost certainly the **forced-UC 64-bit LOAD
returning 0** (or the compare operand path). Next probe: check
`hpdcache_uncached` LOAD handling for `size=2'b11`/dword + `be=8'hff`, and
whether `operand_c`(expected) reaches `data_cmp` intact; consider whether
CASD should be cacheable like the normal AMO path instead of forced-UC.

**RFIX-131a-17 — mc secondary-core hold is EXPECTED, not the wedge.**
`g6lc_cluster.sv`: `BOOT_HOLD=(NC>1 && NrHarts>1)`, `BOOT_HOLD_CYC=200000`.
Secondary cores (c!=0) get `core_clk` via `tc_clk_gating` with
`en_i = rel & ~core_sleep_ok`, where
`rel = (boot_hold_q >= 200000) || ipi_seen_q[c]` and `ipi_seen_q[c]` latches
on `|ipi_i[c]`. Testbench `mc_held[c] = !gen_boot_icg.rel`; verdict maps held
cores to **exit 125 / "HELD … not a hang"** (explicitly benign per the
comment at g6lc_testharness.sv:1745).

`mc_boot_sanity` (1464 cyc) -> held_mask=1110, retired_mask=0001, exit 125:
cores 1-3 correctly held (test too short for the 200K auto-release and sent
no IPI). **This is expected bring-up, NOT a defect** — do not chase it.
`hyp8_smp_lrsc`'s earlier hang showed *active* cores (IQ arb, scoreboard,
LSU/AMO state), i.e. secondaries WERE released (IPI or >200K cyc) and then
wedged on the atomic/store path — that remains the real mc defect. For
OpenWrt/Linux, OpenSBI HSM releases secondaries via IPI and the workload runs
≫200K cycles, so BOOT_HOLD is not the boot blocker; the post-release
coherence/atomic wedge is.

**RFIX-131a-18 — RVV/Ara port of 509f4767 onto hyp8-mc (elaboration-clean).**
Ported the dual-issue accelerator mechanism from
`g6lc64_ooo_int2_l3_v_ai` (commit `509f4767`) onto the hyp8 OoO backend.
ACCEL is held at the commit head and steered to issue port 0 — the same
non-speculative contract as CVXIF — because `acc_dispatcher` forwards to Ara
only after commit; a younger-than-head issue would occupy the vector unit
while an older op can still fault. Scalar `rd` renaming is skipped for ACCEL
(Ara owns VRF state; `vsetvl` results land via the commit-mirror, like CSR/AMO).

Mechanism (all in `core/`):
- `ooo/g6lc_iq.sv`: class vector widened `[6:0]`→`[8:0]`, added `C_ACCL`;
  ACCEL classified from `disp_sbe_i[p].fu==ACCEL`; added to head-only assert.
- `ooo/g6lc_iq_bank.sv`: class ports/records →8b; `C_ACCL` in `port0`; **`ord`
  predicate extended to include `alloc_cls_i[p][C_ACCL]`** — without this an
  ACCEL entry would bypass the registered-legality pipeline entirely.
- `ooo/g6lc_iq_legal.sv`: `info_cls_i`→8b, `C_ACCL` in `head_only` + the
  runtime head-only legality assert.
- `issue_read_operands.sv`: ACCEL in the dual-issue FU-busy chain (port-0
  only), per-FU `fus_busy[p].accel`, and a translate-off assert that ACCEL is
  never acked on a nonzero port.
- `ooo/g6lc_ooo_dispatch.sv`: `need_rd` excludes ACCEL (no scalar rename).
- `g6lc_core.sv`: removed `assert(!(SuperscalarEn && EnableAccelerator))` —
  dual-issue Ara is legal under the head+port0 contract.
- `include/config_pkg.sv`: AI seam asserts ported — seam B (Cvxif, no RVV),
  seam D (AccelEn, no RVV/Cvxif), seam I (`!AccelEn && !CvxifEn && Queues>0`,
  RVV legal); `AccelEn && RVV` still illegal; added
  `DmaInvalEn && L2En && !L2CmoEn` legality; added `cva6_cfg_t`/`cva6_cfg_empty`
  aliases onto `g6lc_cfg_t` for the vendored upstream surface.
- `include/cva6_config_pkg.sv` (NEW): exposes `cva6_cfg =
  build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg)` — the *live* hyp8
  config, not an empty default — plus `CVA6ConfigDataUserWidth`(=AxiUserWidth)
  and `CVA6ConfigRvfiTrace`(=G6LCConfigRvfiTrace) that `ariane_pkg` needs for
  struct widths. Required ordering: after config_pkg+build_config_pkg+mc pkg.
- `include/g6lc64_hyp8_mc_config_pkg.sv`: `G6LCConfigVExtEn = 1` (RVV live;
  `build_config` derives `cfg.RVV=1`, `cfg.EnableAccelerator=1`).
- `corev_apu/src/g6lc_ara_attach.sv`: upstream Ara param is `.CVA6Cfg` (not
  `.G6LCCfg`); type aliases `cva6_to_acc_t`/`acc_to_cva6_t` bind `g6lc_to_acc_t`/
  `acc_to_g6lc_t`.
- `verif/regress/remote/hyp8/Flist.hyp8_mc_sim`: `+define+G6LC_ARA_ATTACH`,
  Ara incdirs, `vendor/ara/Flist.ara` package+source list, `cva6_config_pkg.sv`,
  upstream `core/include/ariane_pkg.sv` (decoder's `import ariane_pkg::*`).

Config parity vs reference `g6lc64_ooo_int2_l3_v_ai`: CvxifEn=0, HExtEn=0,
VExtEn=1, VLEN=64, SuperscalarEn=1, RVZacas=1, CoproType=COPRO_NONE,
OoOEn=1, L2En=1, L3En=1, NrHarts=2 all match. Intentional hyp8 deltas:
**NrIssuePorts=8** (hyp8 8-wide issue vs reference 2) and **NrCores=4** (vs 2).
`AiCfg=AiCfgOff` (vs reference `AiCfgIsland`) is correct for pure RVV: the
matrix-island DMA plane is absent; `EnableAccelerator`→Ara is independent of
AiCfg and `AiCfgOff` passes every seam assert trivially (all fields 0).

**Verification:** `verilator --lint-only` on `Flist.hyp8_mc_sim`
(`-DG6LC_HYP8_MC`, top `g6lc_soc`) → **0 errors**. The `vmfpu.sv` PINMISSING
warning (`early_valid_o` unconnected, an output) proves the `gen_on`
(G6LC_ARA_ATTACH) branch elaborated — i.e. `EnableAccelerator`/`RVV` are live,
not dead-code lint. NOT yet verified: functional vector execution, the
commit-head/port-0 contract at runtime, or boot. The reference leaf bench
`verif/tb/core/run-iq-accel-head.sh` + `tb_g6lc_iq_accel_head.sv` targets the
*reference* `core/ooo/g6lc_iq.sv` (upstream naming); a hyp8-adapted equivalent
is the next directed check (hyp8 IQ is banked + steered + replayed, so the bench
needs `G6LCCfg`/`HypCfg`, the extra steer/replay ports, and `ACCEL_OP` fu_ops).

**RFIX-131a-19 — hyp8 IQ ACCEL-head leaf bench fixed; positive + both negative
controls pass.** The `tb_g6lc_iq_cvxif_head`-derived bench cloned onto the
banked hyp8 `g6lc_iq` could not observe `issue_valid_o` for *either* CVXIF or
ACCEL — the interface outgrew the bench (steer/replay/FU-ready/spec ports) and
the banked IQ + registered 2-stage arbiter is ~6 cycles dispatch->issue, far
deeper than the fixed `#2`/`repeat(4)` waits the shallow upstream bench used.

Root causes found by hierarchical probe (`cand_v_i`->`cand_v_q`->`pv_d`/`pv_q`->
`merged`->`win_v`->`win_s_v`->`take_grant`):
- **S1/S3 held->issue checks fired too early.** `expect_issue` now POLLS
  `iv!==0` for positives (issue_valid holds until acked, so waiting cannot
  drop it) and settles `HELD_CYCLES=60` (> full candidate->issue flight) for
  held checks, so a NOHEAD mutant that lets the op issue is still caught.
- **S3 dual-issue was untestable as written.** A plain ALU is not head-only, so
  op7 issued the moment it was ready — stealing port 0 before op5's head, and
  (worse) once op5 was presented-but-unacked, op7 kept winning the port-0
  *selection* while `take_grant[0]` was blocked by `pres_q[0].v`, got marked
  `used` for port 1, and deadlocked. Fixed by gating op7 on a register
  writeback (`offer_op_prs` prs=5 rdy=0) and waking it ~1 cycle after
  `commit_ptr` moves, so op7's candidate reaches the arbiter the same cycle
  op5's does -> simultaneous grant: ACCEL port0 + ALU port1 (`iv=2'b11`).
- **`drain_ports`** now acks until `iv==0` (was a single `ia` tick) so no
  phantom presentation leaks into the next scenario.

Result (`verif/regress/remote/hyp8/run_iqaccel_leaf.sh`, local host Verilator):
`PASS positive` (checked=5) / `PASS oracle negative` / `PASS mutation caught`
(`G6LC_MUT_ACCEL_NOHEAD` trips the design's own `g6lc_r68_iqleg_head_only`
assertion before the bench check). The mutation define is committed in
`g6lc_iq_legal.sv` beside the existing `G6LC_MUT_*` review-mutant hooks.

Backport note: the mechanism is symmetric with CVXIF (same head-only+port0
path); no core-RTL change was needed — this was purely a stale-harness fix.
The ACCEL class/`ord`/`port0` wiring verified here is what the mc RVV model
relies on; runtime vector execution is still gated on the staged mc build.

## RFIX-131a-20 — RVV mc verilate blocker fixed (serdiv CVA6Cfg alias); mc wedge = scoreboard.sv:297 issue-ack/valid skew

**RVV/Ara mc build (`hyp8-rfix131a-e-mc-aggregate-t4`, stage=verilate) failed
at elaboration:** `%Error-PINNOTFOUND … vendor/ara/…/lane/simd_div.sv:313
Parameter pin not found: 'CVA6Cfg'`. Root cause: the mc flist resolves
`serdiv` to the hyp8 redesign copy
(`hyp_redesign_core_8fo4/core/serdiv.sv`), whose config parameter is the
LibreCore `G6LCCfg` (`config_pkg::g6lc_cfg_t`). Tier-U Ara `simd_div`
instantiates `serdiv` through the *upstream* `CVA6Cfg` parameter name —
the boundary-rename seam `AGENTS-branding.md` §0.4a warns about. Only
`serdiv` crosses this boundary with a config-struct parameter: a module-
name cross-reference of every Ara instantiation against the 238 hyp8-core
modules in `Flist.hyp8_mc_sim` yields exactly `{serdiv, fpnew_top}`, and
`fpnew_top` is FPnew-parametric (`Features`/`Implementation`/`DivSqrtSel`/
`TagType`/`TrueSIMDClass`/`EnableSIMDMask`), not `CVA6Cfg`-typed, so it is
clean. `g6lc_ara_attach.sv` already binds `.CVA6Cfg(G6LCCfg)` correctly
(same packed type via the `cva6_cfg_t` typedef alias).

**Fix (`b5d57a451`):** `serdiv` gains `parameter config_pkg::cva6_cfg_t
CVA6Cfg = config_pkg::cva6_cfg_empty` plus a resolved
`parameter config_pkg::g6lc_cfg_t CFG = (G6LCCfg != g6lc_cfg_empty) ?
G6LCCfg : CVA6Cfg`; the three `G6LCCfg.TRANS_ID_BITS` uses (id_i/id_o/id_q)
now read `CFG`. `cva6_cfg_t`/`cva6_cfg_empty` are typedef/localparam aliases
of `g6lc_cfg_t`/`g6lc_cfg_empty`, so both names carry the identical packed
value; exactly one is non-empty per instantiation. G6LCCfg callers
(`mult.sv`) are unaffected (scalar+smt2 flists share this file). Idiom
verified on a standalone packed-struct parameter model (per-caller field
resolution confirmed). Additive, synthesizable, tier-U Ara untouched.

**mc wedge root-cause candidate (`rfix131a-d-mc-isolate`):** the "wedge" is
not a hang — `mc_hart1_store_visible` aborts at cycle 328980 on
`scoreboard.sv:297`: `Issue acknowledged but instruction is not valid`
(`issue_ack_i[i] |-> issue_instr_valid_o[i]`, `gen_core[0]`). The boot trace
shows npc parked at `0x10040` (a hart spin) before the assert. Mechanism:
`issue_instr_valid_o[i] = decoded_instr_valid_i[i] & issue_open[i]`
(sb_lifecycle.sv:243) is the *decode→scoreboard allocation* view —
combinational, high only the cycle decode presents the instruction.
`issue_ack_i` is `issue_read_operands.issue_ack_o` (= `issue_ack_pre &
res_admit`, gated by flush/casq_stall/port-order/AMO rules at
issue_read_operands.sv:1668-1711) returned through `issue_ack_iro`→
`issue_ack_sb`→scoreboard, i.e. the *FU-issue* view possibly pipelined
relative to the allocation view. A one-cycle (or SMT per-hart-window)
skew between the presented-valid and the ack produces exactly this
assert. `issue_open[i]=~issue_full[i]` is flow-control, not per-instruction
validity. NEXT: on the instrumented model, probe `issue_ack_i` vs
`issue_instr_valid_o`/`decoded_instr_valid_i`/`issue_open` alignment on
`gen_core[0]` at the failing window (hang_dump already brackets it);
determine whether the ack is registered one stage deeper than the valid
(most likely) or an SMT `smt_issue_win` lets a non-head hart's ack reach
the shared scoreboard port. This is pre-RVV (rfix131a-d), so it is NOT a
regression from the ACCEL port — it blocks every 2+-active-hart mc test
and therefore any SMP Linux/OpenWrt boot.

## RFIX-131a-21 — mc scoreboard.sv:297 wedge: SMT quiesce masks in-flight OoO group ack (FIXED)

Supersedes the RFIX-131a-20 "pipeline skew" hypothesis. Root cause is the
SMT drained-handoff quiesce, not a generic valid/ack alignment:

- `g6lc_core.sv` drove the scoreboard `decoded_instr_valid_i` as
  `issue_entry_valid_id_issue & {NP{!smt_quiesce && !(NrHarts>1 && halt_ctrl)}}`.
- `smt_quiesce = thread_select.quiesce_o = drain_pending_q | switch_q` asserts
  the moment a hart drain is *requested* — long before `drain_ready_i`
  (which needs `ooo_drained_id` = `!(|grp_v_q) && !grp_pend_q && rob/iq/lsq
  empty`) lets the switch complete.
- Meanwhile `g6lc_ooo_dispatch` holds an already-captured group in the
  *registered* `grp_v_q`; `dispatch_ack_o = iqdisp_ack & grp_v_q & grp_go`
  still fires once IQ/LSQ/CSR credits arrive — it does not depend on
  `decoded_instr_valid_i`.
- On that ack cycle the scoreboard saw `issue_instr_valid_o =
  decoded_instr_valid_i(=0, masked) & issue_open = 0` while
  `issue_ack_i = 1` → `scoreboard.sv:297` assert. Worse, `alloc_fire =
  decoded_instr_valid_i & decoded_instr_ack_o & keep` was 0, so the
  instruction dispatch had already committed into the IQ got **no
  scoreboard slot** — an orphaned IQ entry (trans_id never allocated in
  mem_q) → hang/corruption even if the assert were waived.

Only reachable when `NrHarts>1` (SMT): scalar `NrHarts==1` ties
`smt_quiesce=0` and the `halt_ctrl` term is masked off, which is why the
scalar/smt-free directed suite never fired it.

FIX (issue_stage.sv + g6lc_core.sv): move the quiesce/halt mask off the
scoreboard input onto the *dispatch-capture* boundary.
- `.decoded_instr_valid_i(issue_entry_valid_id_issue)` — unmasked, so the
  scoreboard keeps `issue_instr_valid_o`/`alloc_fire` consistent for the
  in-flight group through its ack (decoded_instr_i still names the held
  group: decode holds it until `decoded_instr_ack_o`, and drain_ready
  forbids the switch until `grp_v_q` is empty, so active_hart — and hence
  issue_entry_* — is still the outgoing hart during the ack window).
- New `issue_stage.issue_quiesce_i = smt_quiesce || (NrHarts>1 &&
  halt_ctrl)` ANDed into `disp_valid_ctx` (OoO) and the slice/inorder
  dispatch-valid inputs — identical gating for NEW captures, none for the
  already-captured group's completion. `g6lc_ctx_barrier` is purely
  combinational so its unmasked `lane_valid_i` view is harmless.
- Scalar/single-hart: `issue_quiesce_i` const-0 → bit-identical behaviour.

RVV note: `g6lc64_hyp8_mc` `G6LCConfigVExtEn` set 1→0 for the witness
build — the committed Ara cone (VExtEn=1) pushes mc Verilator elaboration
past the remote builder (~104 GiB → signal 9). The ACCEL/IQ-contract port
stays committed and leaf-verified; the mc .dts advertises no 'v'/'zve',
so VExtEn=0 matches the software contract. Flip back to 1 on a larger
builder to qualify RVV under mc.
