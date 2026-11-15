# r129 — deep-profile (`LoadExPubStages=2`) lost exception; memory leaf repair

Scope: `core/load_unit.sv`, `verif/tb/core/tb_g6lc_hyp8_memory.sv`. Structural
screening and simulation evidence only; no physical timing claim. The default
binding (`Hyp8`, `LoadExPubStages=1`) is the profile the Linux witnesses run;
the deep profile stays OFF by default.

## 1. Test data

`hyp8-osbi-scalar-r127n-deep` (closure-r127n, target `g6lc64_hyp8_deep`)
stopped at cycle 254,915,572:

```
load_unit.sv:1879 misaligned_entry_excepts: misaligned load buffer slot 0
popped without its exception (state_q=0000000010 kill=0 valid_o=0 ex_o=0
ex_o.cause=0 tid_o=5 slot_tid=5 rkill=1 done=0 flushed=0 canc=0 flush=0
pend=1 rvalid=0 rid=0 last=0)
```

`state_q` bit 1 is `WAIT_GNT`; `pend=1` is the slot's `ex_pend_q` bit.

## 2. Mechanism trace

Under `LU_EXPEND` a same-cycle exception kill (`ex_pub`: SEND_TAG, own fault,
the killed tag's own dummy response) does not present. It pushes the r51
pending record, and the response capture tombstones the slot
(`rkill_q <= kill_req && rresp == last_id`).

1. Cycle T (SEND_TAG, kill): record pushed, `ex_pend_q[slot]` set, slot
   `rpend=1 rkill=1`. The SEND_TAG arm also decides the next request exactly
   as IDLE does; with a request at the head and no D$ grant, `state_d =
   WAIT_GNT`.
2. Cycle T+1 (WAIT_GNT, `valid_i=1`): `pend_state_ok = 0` (WAIT_GNT is only
   safe without a head request), so `ex_pend_sel = 0` and the record does
   not present. `drn_ok[slot] = rpend && valid && rkill = 1`, so the slot
   drains.
3. Edge T+1: `ldbuf_valid_d[slot] = 0` clears `ex_pend_q[slot]`;
   `pend_dead_d = 1`.
4. T+2: the head record is dropped as dead. The faulting load never writes
   back: the exception is lost and the commit head would wait forever. The
   assertion stops the model at step 2.

The 12 bare-metal smokes pass on the deep target because none takes a new
load in a faulting load's kill cycle without an immediate grant.

## 3. Alternative explanations and the distinguishing check

- *Assertion too strict (as in r124)*: rejected. The r124 case had a publish
  for the tid in the pop cycle with a different legal cause. Here nothing is
  published at all (`valid_o=0`), and step 3 shows nothing can publish later.
- *Cancelled/flushed load (precise drop)*: rejected by the message
  (`flushed=0 canc=0 flush=0`).
- *Default-profile defect*: rejected. Under `==1` `ex_pub` presents and pops
  in the kill cycle; r126, r127m (userspace reached) and the leaf case below
  (`I4_EX_AT_KILL`) cover it.

Distinguishing check: leaf case I4 (section 5) drives exactly steps 1-2 and
then grants the second load. Pre-fix behavior (mutant) reproduces the witness
message verbatim, including `state_q=0000000010 kill=0 valid_o=0 ex_o=0`.

## 4. Change

`drn_ok[i] = rpend && valid && (flushed || (rkill && !(LU_EXPEND && ex_pend_q[i])))`

A slot with a live pending record stays allocated until the record pops.
`pend_pop` clears the bit (and re-marks the tombstone); the drain follows one
cycle later. This is the lifetime a deferred record's slot already has.

- **Contract**: deep profile only. Exception completions are unchanged in
  order and content. The faulting slot is freed one cycle later than before
  when the publish was not delayed, and stays for the length of the wait
  when it was. Flush/cancel paths are unchanged (`flushed_q` arm; the pending
  bit is cleared by `flushed_d`). Progress: the record presents in any of
  SEND_TAG / ABORT / ABORT_NI / WAIT_FLUSH / WAIT_WB_EMPTY or with no head
  request, the same bound as deferred records; every later load passes
  through SEND_TAG, so held slots do not accumulate.
- **Default profile**: `LU_EXPEND` is a constant 0; the term folds to the
  previous expression. Smoke cycle counts are unchanged (section 6).
- **Timing impact**: one extra AND input from a flop (`ex_pend_q`) on the
  drain mask, deep profile only. No new path into `ldbuf_valid_d` from the
  publish gate (the reason r51 defers the pop). Not re-boarded: default
  netlist unchanged, deep is not the measured profile of record.
- **Sim-only**: `mis_done_q` now records the same four causes the pop-cycle
  check accepts (r124), because under `==2` the publish precedes the drain.
- **Mutant** `G6LC_MUT_LU_EXPEND_DROP` redefined as the pre-r129 drain. Its
  old form (push without the capture tombstone) is behaviorally identical to
  the fixed design and could no longer fail.

## 5. Memory leaf (`tb_g6lc_hyp8_memory`)

The leaf had been failing since `7d7d7dc5a` (I/O loads are never forwarded):
`FWD_RSP_POSSIBLE` at tick 152, on the pinned remote toolchain and on local
Verilator 5.020 alike (`hyp8-r128-leaf-memory-base`). The bench config was
`cfg_empty`, which has no cacheable region, so every bench address was I/O.
A/B: with `stb_fwd.sv` of `7d7d7dc5a~1` the old bench passes 160; with the
current file it fails. The RTL is as intended; the bench was stale.

- Bench config now carries the Hyp8 cacheable region (`0x8000_0000`, 1 GiB).
- C3b (new): a store and a matching load outside the region produce a
  response that reports no coverage (`FWD_IO_NOT_FORWARDED`).
- I4 (new): section 3's reproduction, both profiles.
- F1/F2/I1: one extra cycle before the `*_FREED` checks under `==2`.

| Run (pinned remote toolchain, closure-r129) | Result |
|---|---|
| `hyp8-r129-leaf-memory-default` | `HYP8_MEMORY_PASS checked=176` |
| `hyp8-r129-leaf-memory-deep` (`G6LC_HYP8_DEEP`) | `HYP8_MEMORY_PASS checked=177`, `expend: pushed=4 presented=5` |
| `hyp8-r129-leaf-memory-deepmut` (+`G6LC_MUT_LU_EXPEND_DROP`) | FAIL `misaligned_entry_excepts … state_q=0000000010 kill=0 valid_o=0 ex_o=0` |

Local lint (`lint_hyp8_core_local.sh`, default and `-DG6LC_HYP8_DEEP`):
clean of fatal classes, the 7 known open warnings.

## 6. Integration (closure-r129, fork PGO toolchain `d219b63f…`)

Default binding `hyp8-r129-aggregate-t1`: lint scalar/SMT2 rc 0, 0 `%Error`,
model `df39f9e6c315628b68c287377546afb6b5510b02100428d73039f07365fe3be3`,
sim-PGO 201 profiles. `hyp8-r129-smokes-t1`: **14/14 pass**, cycle counts
identical to r126/r128 (685 1011 492 2364 2199 1231 671 3038 9095 5959 883
983 3893 6949).

Not done here: no default-binding boot witness was rerun for this change
(the default expression is unchanged by constant folding; `r128b` is the
witness of record for the committed default tree). The deep-profile build,
smokes and boot witness are recorded below once they report.
