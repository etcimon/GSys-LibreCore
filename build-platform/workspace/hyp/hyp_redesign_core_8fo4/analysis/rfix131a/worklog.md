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

| entry | class | isolated test | fix | verified |
|---|---|---|---|---|
| RFIX-131a-01 | speculative loads on the bus outside memory (18,131 AXI DECERR, device reads) | `hyp8_spec_bus_clean.S` — reproduced on the r131 model | PMA non-idempotent regions (config) | **no** (model with the fix not built) |
| RFIX-131a-02 | execution under a stale privilege/translation context (16,553 + 4,635 `[ptw-err]`, 18,130 of the DECERR) | `hyp8_ctx_switch_clean.S` — reproduced on the r131 model; leaves `ctx-barrier`, `csr-credit` | context barrier at dispatch + frontend hold | **no** (leaves and model not run) |
| RFIX-131a-03 | wrong-path data walks with a garbage base (5,426 `[ptw-err]`) | not yet | not yet | — |
| RFIX-131a-04 | S-mode fetch exception presentations on squashed fetches (490 `[mmu-ife]`) | not yet | not yet | — |
| RFIX-131a-05 | commit stalls > 2000 cycles (30 `[hang]` dumps, LR backoff) | `sc-backoff` leaf (r130) | `67f413a63` (r130) | leaf only; not re-observed on a boot |
| RFIX-131a-06 | memory-order violation replays (706,483; IPC 0.143) | not yet | not yet | — |
| RFIX-131a-07 | `g6lc_tlb` fill-time upsert is gated by `TLB_STAGED` (`3f3083a64`) | mmu leaf | to restate as an unconditional one-entry-per-key invariant | — |


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
  identical `[6.312965]` line and then nothing until `[19.39] io scheduler …`,
  `[23.46] Run /init`, shell at uptime 24.79 s, last RVFI cycle
  2,670,920,795 with a 3.0e9 budget. Kernel time advances ~107.7M cycles per
  second, so 6.31 s is ~0.68B cycles and `/init` is ~2.53B cycles.
- r128b, r130 and r131 were launched with `+max-cycles=1.75e9`: that budget
  ends at ~16 s of kernel time and **cannot** reach `/init`. None of them
  could have produced a shell verdict; no RTL defect is implied.
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

**Verification so far.** Local host lint of the core flist
(`lint_hyp8_core_local.sh`): clean of fatal classes, 7 open warnings, all
pre-existing `CMPCONST` in `sb_head.sv`. **Nothing has been simulated**: the
leaves and the two directed tests have not run on a tree with the fix.

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

## Open classes (analysis so far)

- **RFIX-131a-03** — 5,426 data walks for `vaddr` 0, 3, 4, 8, 0x220 … in
  S-mode: loads behind a mispredicted branch with a null/garbage base.
  `tr_idle_ok = dtlb_hit || !spec_ld` already says a load flagged
  speculative does not request a walk; these loads were not flagged. To
  establish which loads miss the flag (r71: the bypass does not clear or
  set it for queued entries) before choosing the rule.
- **RFIX-131a-04** — 490 S-mode `[mmu-ife] cause=12` presentations (142 of
  them with `ptw_err=0`: an ITLB hit with a permission error, i.e. a U page
  looked up under S after trap entry). The frontend's request across a
  commit-side redirect; candidate rule: no fetch request in a cycle a
  commit-side flush is pending.
- **RFIX-131a-05** — 30 `[hang]` dumps: the LR parked by a saturated
  SC-backoff mask at 396.95M / 429.42M (r130 analysis, fix `67f413a63`,
  `sc-backoff` leaf). No boot has run with it.
- **RFIX-131a-06** — `mem_viol=706,483` replays and IPC 0.143 over the
  boot: not an error record, but the largest structural cost in the census.
- **RFIX-131a-07** — `g6lc_tlb.sv` `fill_dup` (`3f3083a64`) is a
  `TLB_STAGED`-gated compare chain in the fill arm. The invariant behind it
  (at most one valid entry per translation key) holds for every staging if
  the fill is an upsert unconditionally; to be restated that way and proved
  on the mmu leaf rather than gated.
- **RVFI trace fidelity** (found while isolating RFIX-131a-01): the trace
  printed the squashed fall-through of a mispredicted taken branch as
  retired (`ld t0,1128(a0)` with `mem 0x10001468`, `x5 = 0xca11ab1ebadcab1e`)
  while the architectural check (fall-through count) passes. To isolate:
  either the tracer prints a cancelled commit slot or the count check is
  blind to it.
