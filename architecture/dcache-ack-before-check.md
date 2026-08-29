# WT D$ ACK-before-check — the L1-stale class (SL-W)

**Status:** micro-arch note of record for the S1 residual. Not a candidate list — the candidates
are exhausted (see below). This file exists to separate the two failure modes that every logged
attempt conflated, and to state the one design axis that has **not** been tried.

Evidence of record: [`multi-threading/linux-boot-scale.md`](multi-threading/linux-boot-scale.md) §S1
(~60 tagged proxy runs; do not duplicate rows here).
RTL: `core/cache_subsystem/wt_dcache_wbuffer.sv` (header note 3, `VoidKeepEn` / `VoidKeepTag`).
Queue entry: **SL-W** in [`../AGENTS-todo.md`](../AGENTS-todo.md).
Execution: proxy-only ([`multi-threading/testharness-proxy.md`](multi-threading/testharness-proxy.md)).

---

## 0. The defect, stated without the firmware

The write-through D$ write buffer holds a word in `(valid, dirty, txblock)` per byte plus a word-level
`(checked, hit_oh)` cache state. A word is only written into the **L1 data array** once its tag has
been checked and a way is known. A returning write ACK frees the TX immediately — deliberately, so
the return FIFO cannot deadlock a load miss through `tx_rdwr_collision`.

If the ACK arrives **before** that tag check (`checked == 0`, "VOID"), the word is dropped from the
buffer. Main memory is correct, because this is write-through. **L1 is not**: if a stale copy of that
line was already resident, it stays resident, and a later load hits it and reads pre-store data.

This is a **write-through coherence defect between the write buffer and the L1 data array**. It is
not an OpenSBI bug, not a fetch bug, and not specific to libfdt — OpenSBI's `fdt_next_tag` nest just
happens to produce the exact store→ACK→load timing that exposes it. It will outlive this firmware.

**It is not fetch.** The class is SP-proven: 1st `fdt_next_tag` SP=`0x80046e00`, 2nd SP=`0x80046e20`
(Δ=+32 = `check_node` frame), alias PA `0x80046e38` = 1st `sd ra,56(sp)` = 2nd `ld s3,24(sp)`. The
store commit-acks with the right value and the restore load retires `0x12b2a`. No fetch combo is
involved, and `linux-boot-scale.md` §2 forbids spending a combo on it.

---

## 1. Two failure modes, and why every attempt hit both

| | Mode (a) — **staleness** | Mode (b) — **forward progress** |
|---|---|---|
| Statement | An ACK'd-but-unchecked word must either land in L1 or invalidate that line | The buffer's `valid`/`txblock`/keep state also governs forwarding, `empty_o` and TX allocation |
| Symptom | `tight` / `nt-nl` restore load reads stale (`s3 = 0x12b2a`) or the pin at `mepc=0x80012eb2` | `h0` **HANG @40000** in the FDT_PROP walk; `nextoff = 0`, walk never ends |
| Proof it is real | `s1-tight-hold-trace`: hold overlay **DEAD** (`v=0 hit=0`), DRAM alias already = `lenp` from t=10240, yet the 2nd `ld s3` retires `0x12b2a` — the load source is stale **L1** | `s1-h0-keep-hang-trace`: **not** an LSU stall. h0 is *retiring* `0x8001311a–0x80013176` with `ra=0x800130b6`, `s3=0`, SP growing — a software infinite loop fed by a wrong value |

The trials cluster cleanly once split this way:

- **Invalidate-on-ACK** (`ackinv`, `voidchk2`): fixes (a) — `tight` PASS @22606, pin *moved*, which is
  the confirmation that the class is L1-stale — and breaks (b): h0 HANG.
- **Keep-until-check** (`keep`, `keepv`, `keepnz`, `keep512`, `keepcoal`, `keeppend`, `snoopd`,
  `snoopd2`, `snoopd8`, and their TTL variants): also reach (a) — `s1-h0-snoopd8t-trace` shows the 2nd
  `ld s3` **getting `lenp`**, i.e. the pin genuinely moves — and land in (b) anyway: FDT_PROP hang at
  `npc=0x80013148`.
- **Late L1 write** (`wr1`, `latel1`, `latel1b`, `chkhit*`, `wrack`): (b) directly — `wr1` hangs even
  *software* namelen ("late way-write after evict").
- **Hit poisoning** (`nackhit`, `nackhit2`, `nackstick`, `nack2`, `nack2cl`, `nack2idx`): partial (a)
  — `s3` recovers, `s2` does not. `s1-tight-nack2idx-trace` is the important one: **"poison does not
  refill the s2 line while the s3 miss is in flight."**

**Capacity is not the knob.** Exactly one keep is too few (`keep1nz`, `keeppend`: an intervening
unique PA steals the alias slot, `tight` still fails `s3`); two or more is enough for `tight` and
still hangs h0 (`keep2nz`, `keeppend2`, `snoopd2`). Caps of 2/3/5/6/7 and TTLs of 400/512 were all
swept. There is no capacity or lifetime setting that satisfies both modes.

---

## 2. Why that is structural, not bad luck

Every logged attempt implemented the (a)-fix **inside the write buffer's own state**: it either held
`valid`/`txblock` longer, kept an extra entry, retried `wr_req`, or masked a hit. But that state is
simultaneously:

1. the **forwarding** source for loads (`wbuffer_hit_oh`, per-byte `valid` mask),
2. the **drain/ordering** signal (`empty_o`, consumed by fences and the LSU),
3. the **TX allocation** pool (`txblock`, `free_tx_slots`, `tx_rdwr_collision`),
4. and the input to **miss/refill** sequencing.

So an (a)-fix expressed in that state cannot avoid perturbing (b). The `nack2idx` trace names the
sharpest instance of (4): a suppressed hit does not cause the line to be refilled while another miss
to a different index is outstanding, so the load sees neither the buffer nor a fresh line.

---

## 3. The axis that has not been tried

**Decouple the L1 fixup from the write-buffer entry.** Concretely, an ACK'd-but-unchecked word should
be moved into a small, separate **post-ACK L1 fixup queue** that:

- **owns no buffer state** — the wbuffer entry is freed exactly as it is today, so forwarding,
  `empty_o`, TX allocation and NC/NI handling are byte-for-byte unchanged (mode (b) untouched *by
  construction*, not by tuning);
- carries `{paddr, be, data}` only, and retires an entry by performing the tag check it missed and
  then **either** writing the hit way **or** invalidating the line if the tag check misses;
- is **ordered against refill**: an entry may only retire when that index has no refill in flight and
  no tag check in progress — this is the `nack2idx` finding turned into a rule rather than a race;
- is **bounded and lossy-safe**: if the queue is full, fall back to *invalidating* the line rather
  than dropping the fixup. Invalidation is always architecturally safe here (write-through: memory is
  correct), it merely costs a miss. This is what removes the capacity tension in §1 — correctness no
  longer depends on the queue being deep enough.

The write side of this already exists: `check_wr` (`wt_dcache_wbuffer.sv:426-429`) writes the hit way
at tag-check time for VOID-kept words. What is missing is storage that is *not* the buffer entry, and
the refill ordering.

**Why the current containment is not this.** `nackinv` + the `VoidKeepEn`/`VoidKeepTag` window is a
*workload-scoped* stand-in: it narrows mode (a) to the OpenSBI ecall-extension objects so that mode
(b) is never provoked. It reaches the cookie (pin `51b1babe` t=131072, `plat_hc=2`,
`coldboot_done=1`; hold t=126976, `plat_hc=2` + BANR) but it does not generalise: VOID ACK-before-check
still leaves L1 at ELF/BSS for every address outside the window (`ecall_time.next = 0`). No S4 / S6 /
S7 envelope may depend on it.

---

## 4. Acceptance gates (all proxy-only)

A candidate is green only if **all** of these hold, in this order:

| # | Gate | Green |
|---|------|-------|
| 1 | `mini_fdt_*` battery (`nt_frame32`, `nt_stock`, `nt_cpus`, `stq_alias_jal`, `nt_set`, `nt_osbi`) | PASS, no new hang |
| 2 | `b1-nt-nl` tight / sw / h0 / n3 | **all four** PASS — the historic trap is fixing one and hanging another |
| 3 | Pin `bc7ed11d` | cookie `51b1babe`, `plat_hc=2`, `coldboot_done=1` |
| 4 | Hold `8b6b310e` | cookie `51b1babe` + BANR, `plat_hc=2` |
| 5 | I4dp hygiene | `g6lc64_server_math_v` **and** `g6lc64_ooo_server` still `tohost=0` at the 200M cap |
| 6 | Window off | gate 3 + 4 still green with `VoidKeepEn = 0` — this is the test that the fix is *general* |

Gate 6 is the point of the whole exercise: until it passes, the containment is load-bearing and SL-W
stays open.

## 5. Observability ask (§0.1 principle 6)

Every one of the ~60 runs needed a bespoke TB hook (`log wrack`, `log hold`). That is the reason the
chase was expensive. A fix must land with permanent instrumentation: a counter for **VOID ACKs**
(ACK with `checked == 0`), for **denied `wr_ack`**, and for **fixup-queue full → invalidate**, exposed
as PMU events rather than `$display`. `nackinv` and the VOID-keep window shipped without any, which is
why "is the containment even arming?" repeatedly cost a TRACE run.

## 6. Do not

- Do not widen `VoidKeepTag` as a substitute for the fix (`0x80040`–`0x80045` already reverted).
- Do not re-land any tag from §1 — they are classified, not merely failed.
- Do not spend a fetch combo on this (`linux-boot-scale.md` §2) and do not reopen a G1\* letter.
- Do not force `replay = 0`; the hold overlay remains load-bearing for the h0 hart1 sticky case.
- Do not treat harness `tohost = 0` as cookie green (`AGENTS.md` §0.8).
