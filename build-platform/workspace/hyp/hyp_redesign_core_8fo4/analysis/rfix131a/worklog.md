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
(`verilator-v5.008-g6lc-44063db8-pgo`: compiler PGO, loop unrolling,
split-loops, simulation PGO), model `d2b24e58…` built from closure-rfix131a,
19 directed programs graded on tohost **and** on the log, plus the leaf
benches. No Linux boot has run on this tree.

| entry | class (r127m count) | isolated test | structural fix | verified |
|---|---|---|---|---|
| RFIX-131a-01 | speculative loads on the bus outside memory (18,131 AXI DECERR; device reads) | `hyp8_spec_bus_clean.S` | PMA non-idempotent regions (config) | yes: 3 DECERR + 1 UART read -> 0 |
| RFIX-131a-02 | execution under a stale privilege/translation context (16,558 + 4,635 `[ptw-err]`; 18,130 of the DECERR) | `hyp8_ctx_switch_clean.S`; leaves `ctx-barrier`, `csr-credit` | context barrier at dispatch + frontend hold | yes: 65 DECERR + 194 walks -> 0 |
| RFIX-131a-07 | TLB multi-hit (r129b model stop @317,424,744) | mmu leaf `TLB_OVL_*` (6 cases x 3 instances) + 2 mutants | fill evicts every entry it overlaps; PLRU records the answered hit | yes (leaf) |
| RFIX-131a-08 | non-idempotent load parked at the LSU head (found by -01's own test) | `hyp8_spec_bus_clean.S`, `hyp8_dev_load.S` | a non-idempotent load that is not the commit head is handed back | yes |
| RFIX-131a-03 | wrong-path data walks, null/garbage base (5,389) | `hyp8_spec_walk_clean.S` | a load is speculative until it is the commit head | yes: 3 walks -> 0 |
| RFIX-131a-04 | S-mode fetch faults at trap entry (490) | `hyp8_trap_entry_clean.S` (192 on r131; 64 remain) | open: the barrier covers announced traps only; a trap-cycle frontend hold was tried and withdrawn | no |
| RFIX-131a-05 | commit gaps > 2000 cycles: 6 real (LR parked by SC backoff), 24 are WFI idle | `sc-backoff` leaf | `67f413a63` (r130) | leaf only |
| RFIX-131a-06 | memory-order replays (706,483; IPC 0.25) | not yet | open | - |

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

## RFIX-131a-04 — S-mode fetch faults at trap entry (open: reproduced, one fix tried and withdrawn)

**Evidence.** 490 S-mode `[mmu-ife] cause=12` per boot; 272 are ITLB *hits*
on user addresses (`tq.sh sql` over `aux`): a U page fetched under S.

**Isolated test.** `verif/tests/custom/hyp8_trap_entry_clean.S`: U-mode
traps 128 times into an S-mode handler — 64 `ecall`, then 64 illegal
instructions. r131 model: 192 records. Tree with the context barrier
(RFIX-131a-02): 64 — exactly the illegal-instruction entries, i.e. the
barrier removes the class for every trap a CSR-class instruction announces
(`ecall`, and `sret` on the way back) and not for the others (exceptions,
interrupts). The test is **not** in the smoke list while it is dirty.

**Mechanism (from the test's trace).** `fetch_va=0xf0`, `priv=1`,
`itlb_hit=1`, 9 cycles after the last U-mode retirement: the faulting fetch
is the *in-flight* sequential request the I$ already holds (`areq.fetch_req`
stays up through READ / READ_V / KILL_ATRANS) when the trap commits; the
MMU evaluates that held request under the new privilege. The request is
being killed by the trap's flush, so nothing consumes the fault.

**Tried and withdrawn.** Holding the frontend's *new* requests for the trap
cycle (and, second attempt, the two cycles after it) changed nothing: 64
records either way — consistent with the mechanism above (the request
predates the trap). Both variants were removed; the tree carries no trap
hold.

**Next.** Either the fetch-side translation is evaluated under the context
the request was issued in (a request-side context tag), or a killed request
drops its translation request. Both touch the I$ ↔ MMU handshake
(`KILL_ATRANS` exists to keep the request up until the translation
answers), so this needs its own leaf before any change. Until then the
record is a fault presented to a killed fetch: no architectural effect was
observed in the test (tohost passes) or in the r127m boot.

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
scalar/smt2 0 `%Error`, model `d2b24e5891482748…` (final tree: RFIX-131a-01,
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

## Open classes (analysis so far)

- **RFIX-131a-05** — 6 real commit gaps (LR parked by a saturated
  SC-backoff mask, 396.95M / 429.42M; r130 fix `67f413a63`, `sc-backoff`
  leaf passes). Not re-observed on a boot.
- **RFIX-131a-06** — `mem_viol=706,483` replays, IPC 0.25 through the boot:
  the largest structural cost in the census.
- **RVFI trace fidelity** (found while isolating RFIX-131a-01): the trace
  printed the squashed fall-through of a mispredicted taken branch as
  retired (`ld t0,1128(a0)` with `mem 0x10001468`,
  `x5 = 0xca11ab1ebadcab1e`) while the architectural check (fall-through
  count) passes. To isolate: the tracer prints a cancelled commit slot, or
  the count check is blind to it.
- **Multi-core** — nothing above has run on `g6lc64_hyp8_mc` (4 cores × 2
  harts, L2/L3, coherence). The PMA declaration is in its config package;
  the mc model and its directed programs are the next isolated step, before
  any Linux or OpenWrt boot.
