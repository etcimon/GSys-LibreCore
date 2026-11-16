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

Deep profile `hyp8-r129-deep-aggregate-t4` (`HYP8_BUILD_TARGET=g6lc64_hyp8_deep`,
`--threads 4`, unroll 256/131072, split-loops vlt): lint rc 0, model
`48c0ea782fe31e5307d562801fe983a87080e167ab4bbcf18feaa4667ea4b0c4`, sim-PGO 235
profiles. `hyp8-r129-deep-smokes-t4`: **14/14 pass** at the same cycle counts
(the smokes take no load fault, so they do not exercise the pushed record).

Boot witness `hyp8-osbi-scalar-r129-deep` launched on that model (pid 2630423,
observer 2630715, firmware `30e1311e…`, tohost `0x80041730`, budget 1.75e9).
The previous deep run stopped at 254,915,572; passing that point and the two
userspace markers are both required before the deep profile can be proposed
as a default.

## 7. Staged MMU (`G6LC_HYP8_MMU_STAGED`) multi-hit: evidence so far, probe, queued replay

`hyp8-osbi-scalar-r127x-mmustaged` stopped at 317,424,744 on
`g6lc_tlb_hit_onehot0` in the DTLB. From its hart trace, the last events
before the stop are the kernel's ASID-width probe (`asids_init`):

| cycle | pc | instruction |
|---:|---|---|
| 317,414,300 | `ffffffff808063de` | `csrw satp, a5` (ASID field all ones) |
| 317,414,483 | `ffffffff80806426` | `csrw satp, a1` (restore) |
| 317,414,520 | `ffffffff8080642a` | `sfence.vma` (x0, x0) |

The multi-hit follows about 10,200 cycles later. These are the only `satp`
writes in the last 400,000 trace lines (from about cycle 315.14M; earlier
lines were not searched), and the only S-mode `sfence.vma` there; the other
flushes in that span are M-mode `sfence.vma` at `0x80005676`, the last at
317,224,774. The probe sequence is therefore the leading suspect. This is a **hypothesis**: which two entries collide, and how the
second one was written, is not known yet.

What is settled by reading `g6lc_tlb.sv`:

- The fill gate is `update_i.valid & replace_en[i] & !lu_hit_o`. Under
  staging `lu_hit_o` is the answer to the lookup of two cycles earlier, not
  to the page being filled.
- Consecutive stale misses of one held request cannot duplicate an entry on
  their own: the PLRU victim only moves on a hit answer, and a hit answer in
  the fill cycle suppresses the fill. A duplicate needs a miss answer for a
  page that is present (a killed in-flight lookup, or a tag that differs
  only in a field the lookup ignores) after the victim has moved.

Not done: no RTL change to the staged TLB. A fix written before the
colliding entries are known would be a guess.

Instrument (sim-only, `translate_off`): `+tlb_trace` prints `[tlb]`
UPD/FLUSH/LU lines inside `+trace_from/+trace_to`; both multi-hit assertions
now print every entry's tag and PTE before they stop. `hyp8_tb.cpp`
allowlists the plusarg. Staged target on closure-r129b
(`hyp8-r129b-mmustaged-aggregate-t4`, model `a222cecea1e8817c…`, sim-PGO 234):
lint rc 0, 14/14 smokes (`hyp8_sv39_load` 4219, as r127af). Local: lint
clean for the default and staged defines, `HYP8_MMU_PASS checked=716`.

Replay `hyp8-osbi-scalar-r129b-mmustaged-diag2` (window 317,410,000 to
317,426,000, budget 330M) is **queued, not running**: three 4-thread models
plus an APU leaf job oversubscribed the 12-core host (load 17, the deep
witness fell to about 1 kcyc/s), so the first attempt was stopped after
five minutes. `run_hyp8_witness.py` gained `HYP8_WAIT_PIDS`; the replay
starts when either live witness (r128b pid 2062250, r129-deep pid 2630423)
exits.

## r129-deep witness outcome + F15 assertion fix (2026-11-16)

`hyp8-osbi-scalar-r129-deep` (LoadExPubStages=2) monitor exit=1 at cycle
**375,989,307** — past the earlier 254.9M `misaligned_entry_excepts` fix
(107c4ca3c) but short of userspace. Terminal line:

    load_unit.sv lu_pop_is_presented: F15 popped slot not presented
    (rindex=5 tid=12 tid_o=15 valid=1 head=000)

Analysis: **assertion false-positive, not an RTL bug.** The F15 antecedent
`ldbuf_r && pub_fire` treats any load-buffer pop during a publish-eligible
cycle as "the data publish popped". Under EXPEND=2 `ldbuf_r = a_data |
a_drn`; when `a_pend=1 & drn_any=1 & pub_any=1` the drain arm frees a dead
slot (rindex=5, tid=12) in the same cycle the pending-exception arm
presents its own tid (15). The presented tid is correct — the drained
slot legitimately presents nothing. The RTL priority (pend > data, drain
frees dead slots only) loses no load.

Fix (sim-only, `translate_off`): antecedent narrowed to `a_data` — the
literal "data publish arm" pop the property documents — and the error
message now prints `pend/drn/pubidx/drnidx` so any recurrence exposes the
arm split. Local lint clean. The deep witness must be re-run to confirm
it clears 375.9M and reaches userspace; a recurrence with the new fields
would distinguish a real divergence.

## r129b-mmustaged-diag2 replay: multi-hit root cause (2026-11-16)

The queued diagnostic replay ran to the window and captured the dump the
instrument was built for. `g6lc_tlb` multi-hit at c=317,424,730 on
va=ffffffff81313318. The 16-entry dump shows entries **6 and 8 are
byte-identical valid duplicates**: `v=1 vpn=7f81209 asid=0000 ispg=10
ppn=81400 pte=…e7`. (Also near-duplicate invalid copies of vpn=480000b,
580189b, 7f812c7 — invalid, harmless.)

Fill trace — the same vpn written twice, 14 cycles apart, both miss:

    c=317424551  UPD vpn=7f81209 hit_o=0 repl=…01000000 wr=1
    c=317424565  UPD vpn=7f81209 hit_o=0 repl=…00000001 wr=1   (way bit32)

Both fills reported `hit_o=0`: the second lookup's tag sample preceded
the first fill's commit — a **fill-visibility latency hazard** in the
staged pipeline. The second fill therefore wrote a second valid copy of
an already-present vpn → two live entries match one VA → multi-hit.

This breaks the invariant stated at g6lc_tlb.sv:448-453 ("a second fill
is suppressed whenever the first entry hits"): coexistence here is an
EXACT same-page-size duplicate, a third mechanism beyond the
inconsistent-tables / SFENCE-race cases that comment lists. The
suppression only works if the first entry is visible to the second
lookup's hit detect; the ~14-cycle fill latency leaves a window where a
second lookup for the same vpn still misses.

Fix direction (not yet implemented — needs pipeline analysis + a
directed repro before touching the staged TLB): either track in-flight
fills and suppress a second fill for an already-filling vpn, or make
the fill commit visible to hit detect within the lookup-to-fill window.
Off-by-default experimental profile; the default (TlbStages=1) TLB is
unaffected — r126/r127m/r128 all passed on it.
