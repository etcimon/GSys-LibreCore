# WT D$ ACK-before-check — the L1-stale class (SL-W)

**Status:** micro-arch note of record for the S1 residual. The post-ACK fixup queue is implemented
in `wt_dcache_wbuffer.sv` and plumbed through `wt_dcache`/`wt_dcache_mem`; it is disabled by default
(`WtDcacheFixupDepth=0`) and leaves the `VoidKeepEn`/`VoidKeepTag` containment unchanged until proxy
gate 6 is passed. The explicit `inv_req`/`inv_ack` invalidation port and the four SL-W PMU events are
in place. Core and SMT2 path/payload/cap diagnostics pass; SMT2 Verilator lint still shows the
pre-existing internal `Different default drivers` error on `we_gpr_commit_id`.

Evidence of record: [`multi-threading/linux-boot-scale.md`](multi-threading/linux-boot-scale.md) §S1
(~60 tagged proxy runs; do not duplicate rows here).
RTL: `core/cache_subsystem/wt_dcache_wbuffer.sv` (post-ACK fixup queue, `VoidKeepEn`/`VoidKeepTag` containment), `wt_dcache.sv` (`inv_req`/`inv_ack` plumbing + PMU pass-through), `wt_dcache_mem.sv` (explicit way invalidation), `perf_counters.sv` (group 5 SL-W events), `ariane_pkg.sv` (`MHPMGrpSLW`).
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

## 2.1 `mini_stq_flush_fwd` (gate-6, now PASS)

`load_tx_collision` covers **in-flight store TXes** only. A store that is still a
**valid wbuffer word** (not yet a TX) does not set `tx_vld`. A following load
that **misses L1** then issues a refill of stale DRAM while the store sits in
the buffer — the `ld` in the second frame sees the previous frame's `ra`.

A per-word **miss-unit mask** of those loads was tried and reverted: it starves
FDT walks (mode b). The landed axis is the opposite: if the wbuffer/fixup
already holds the **full XLEN word**, the read controller treats that as a hit
and completes from the overlay (`wbuffer_fwd_hit_o` in `wt_dcache_mem`, consumed
in `wt_dcache_ctrl`). No miss-port arbitration change.

RVFI on `work-ver-smt2-fw64-B-slwfix` (`edk2-e1-slwfix`, 406 cycles):
`c.sdsp s3,24(sp)` at `0x8000006c` writes `0x33330000` to `0x80007ff8`; later
`c.ldsp s3,24(sp)` retires with **PC=`0x80000000`** (should be `0x8000008a`
after `c.nop` at `0x80000088`) and **s3=`0x18`** from LSU PA `0x80007ff8`.
Neighbour `ld s2` from `0x80007ff0` is correct (`0x22220000`). So gate-6 is
two defects on one retire: leftover/npc-0 delivery of the 16-bit load, and a
D$ / STQ forward miss that is **not** f1's `ra` (`0x8000002a`). Probe `[slw-fwd]` / `[stq-fwd]` (`slw-stq-probe`): f2 `sd s3` is in the
wbuffer at t=358–359 (`wdata=0x33330000`, `fwd=1`); by t=368 `hit=0 be=0`
and L1 `cache=0`; STQ forward `v=0` for that PA. Neighbour `0x80007ff0`
gets an L1 hit (`rdhit=1`, `0x22220000`) and `ld s2` is correct. The
failing load's `s3=0x18` is **not** any probed overlay. `fixup_paddr_push`
now uses `{wtag, byte-zeros}` rather than `wr_paddr` (which prepends zeros
and drops tag bits) plus a same-cycle VOID-ACK forward.
`mini_stq_flush_fwd` **PASS** (`slw-stq-coal`, oracle green, `mini_edk2_sec`
PASS). Evicts were `checked=1` so VOID-only `fixup_evict` never pushed; ACK
then cleared the wbuffer with no L1 write (`hit_oh=0`). Pushing checked
tag-misses and keeping them on miss closed iter 0 (`ld s3` at `0x8000008a`
returns `0x33330000`). Iter 1 still saw the previous word until same-PA
coalesce (`0x33330001` overwrites the queued `0x33330000`). The first post-sync B that
included the combined `wbuffer_all` (raw depth 11) plus signed `%` into
`fixup_q` **SIGSEGV'd Variane at bootrom** (`mini_must_pass` rc=139, t=275,
`id-dbg` truncated). Isolation: HEAD dcache (`work-ver-smt2-fw64-B-headiso`)
oracle green and `mini_edk2_sec` PASS; IQ width casts were in both binaries.
Cause: Verilator 5.008 C++ still evaluates `fixup_q[src_idx]` on the unused
ternary side, and signed `(-1)%2 == -1`; lzc `$clog2(11)=4` can index past a
packed 11-entry `VlWide`. Mitigations in RTL: unsigned FIFO index in
`p_fixup_wbuffer`, pad `WbufferAllDepth` to the next power of two. Do not
re-land the miss-unit mask.
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

### 3.1 Implemented micro-architecture

The queue lives inside `wt_dcache_wbuffer.sv` and owns **no wbuffer state**. It is parameterized by
`CVA6Cfg.WtDcacheFixupDepth`; depth `0` removes the queue and leaves the legacy `VoidKeepEn`/
`VoidKeepTag` containment bit-identical.

**Entry (`fixup_t`):** `paddr`, `be[(XLEN/8)-1:0]`, `data[XLEN-1:0]`, `user[DCACHE_USER_WIDTH-1:0]`,
`state`. State machine:

- `PEND` — pushed on VOID ACK; waits for the line's cache index to have **no refill in flight**
  (`wr_cl_vld_d`/`wr_cl_vld_q` for that index). This is the `nack2idx` finding made explicit.
- `CHECK` — issues a tag-only `rd_req_o` to the cache; two cycles later `rd_hit_oh_q`/`rd_vld_bits_i`
  are captured.
- `RETIRE` — on a hit, drives `wr_req_o` with the fixup `data`/`be`/`user` to the hit way; on a miss
  the entry is discarded (memory is authoritative). On full-queue fallback, a hit becomes an
  explicit line invalidation (see below).

**Push.** In `p_tx_stat`, when a store ACK returns and the wbuffer word is `!checked` and the ACK is
not captured by `VoidKeepEn`/`VoidKeepTag`, push the `{paddr, be, data, user}` to the fixup queue
instead of dropping. The wbuffer entry is freed exactly as today, so forwarding, `empty_o`, TX
allocation and NI/NC handling are unchanged.

**Full fallback.** If the queue is full when a VOID ACK arrives, the bypass slot is used first; if
that is also occupied, `p_tx_stat` now asserts `fixup_hold` to keep the wbuffer return FIFO entry
and the TX block set until the bypass frees and the entry can be pushed. The wbuffer word stays
valid/dirty (retransmission is safe; memory already holds the written bytes), and the `pm_fixup_full`
event is recorded. This is option (a) from the micro-arch note: it closes the second-overflow gap
without a separate wbuffer invalidate path, but it must be bounded by a small `WtDcacheFixupDepth`
and verified against the FDT hold class so the stall does not re-enter forward-progress mode (b).
Gate-6 is the first proxy run with `WtDcacheFixupVoidKeepEn = 0` and `WtDcacheFixupDepth > 0`. A local WSL Verilator 5.020 build for `g6lc64_smt2` reaches the Verilator code-generation phase but then hits an internal fault (the Debian 5.020 behavior the Makefile already flags); the lint and elaboration pass through the queue logic, so the next evidence must come from a pinned-5.008 build or the proxy.

**Refill ordering.** A `PEND` entry may not move to `CHECK` while any of `wr_cl_vld_d`/`wr_cl_vld_q`
matches its line index. This keeps the queue ordered with respect to cache refills.

**Port arbitration.**

- The word-write port (`wr_req_o` / `wr_idx_o` / `wr_off_o` / `wr_data_o` / `wr_data_be_o`) is shared
  between `check_wr` (the legacy `VoidKeepEn` path), fixup `RETIRE`, and `p_tx_stat` ACK writes.
  Priority in the RTL mux is `check_wr` > fixup retire > `p_tx_stat`.
- The tag-read port (`rd_req_o` / `rd_tag_o` / `rd_idx_o` / `rd_off_o`) is shared between wbuffer
  `tocheck` and fixup `PEND` entries. The wbuffer has priority; fixup reads issue only when no wbuffer
  word is pending (`!(|tocheck) && !check_en_q && !check_en_q1`).

**Invalidate path.** Option 1 (explicit invalidation port) is implemented. `wt_dcache_wbuffer` outputs
`inv_req_o`, `inv_idx_o`, `inv_way_oh_o`, `inv_vld_bits_o`; `wt_dcache` passes them to
`wt_dcache_mem`, which drives `vld_we` with `vld_wdata = inv_vld_bits_i & ~inv_way_oh_i` for the
selected way. `inv_req` has priority over the existing `wr_denied` path and over single-word writes;
only a cache-line refill (`wr_cl_vld_i`) blocks it.

**Config and observability.** `WtDcacheFixupDepth` is in `config_pkg::cva6_cfg_t` and
`build_config_pkg` (default `0` until gate 6; suggested `2` or `4`). PMU events are in
`core/perf_counters.sv` group `MHPMGrpSLW` (`ariane_pkg.sv`): `DCACHE_WBUF_VOID_ACK` (push),
`DCACHE_WBUF_FIXUP_WRITE` (retire on hit), `DCACHE_WBUF_FIXUP_INVAL` (full fallback), and
`DCACHE_WBUF_FIXUP_FULL` (slot exhaustion).

**Verification transition.** Keep `VoidKeepEn = 1` while wiring M1–M3. Once gate 6 is green with
`VoidKeepEn = 0`, remove `VoidKeepEn`/`VoidKeepTag` entirely.

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
