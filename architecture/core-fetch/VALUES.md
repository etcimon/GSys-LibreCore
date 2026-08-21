# Value reference table — A predicates → B combos

Companion to [`SPEC.md`](SPEC.md). Maps every A present/keep/kill/rewrite **value** onto one B
`always_comb` (or DELETE / not-fetch). Increment ids are traceability only; they do not appear in B.

Handoff: map g1\* present/keep/kill onto fetch combos; leftover fabricate stays in **`smt_legacy`**.
**After** that retirement, this table is how **B** (`core/fetch_B`) grows a capability: add a row,
not a fifth combo. Frozen A is `core/frontend`. Peels and hold-soak stay P1–P4.

---

## 0. Law

L1 produces bytes. L2/L3 may drop, never modify. L4 picks the next PC. Kill is two assigns.

If a row needs `rd`, `fu`, `cf_type` as an *accept* key, `make_cjalr16`, `user[33]`, an OpenSBI VA,
or `FETCH_WIDTH>=64` as a magic gate, fate is **DELETE** (stays in `smt_legacy` only).

---

## 1. B combos (the only RTL)

```text
align_slots     L1  leftover + halfword cursor     I1–I5
window_accept   L2  live iff win_tag match         I7
arch_redirect   L4  one encoder                    I8–I12
kill_s1/s2      —   misp|flush|replay ; | bp_valid
```

B today (`core/fetch_B/frontend.sv` — kill + L2 window + I8 `arch_src` + I19 `bp_fire` + thin `next_block`):

```text
kill_s1         = g6lc_fetch_pkg::kill_s1(is_mispredict, flush_i, replay)
bp_fire         = bp_valid && predict_fetchable(target)   // I19; not on resolve
kill_s2         = g6lc_fetch_pkg::kill_s2(kill_s1, bp_fire)
redirect_hit    = window_accept(icache_valid_q, 0, same_win(vaddr, redirect_pc))
redirect_accept = window_accept(if_ready, kill_s2, same_win(fetch_addr, redirect_pc))
arch_src        = arch_src_sel(restore, debug, commit_for_hart, ex, eret, misp)
                  // I8: ex > eret > commit > debug > restore > misp
                  // commit_for_hart: commit only if commit_hart == active (SMT)
npc_d           = arch_valid ? (arch_step ? next_block(arch_pc) : arch_pc)
                : redirect_hold ? redirect_pc_q
                : if_ready ? next_block(seq_base) : seq_base
fetch_address   = arch_valid ? arch_pc : (redirect_hold ? redirect_pc : seq_base)
                  // I8 on the I$ port — not restore-first
npc_q_o         = snap_pc(restore && inflight, inflight_addr, npc_q)
                  // I10: bank accepted I$ addr, not next_block past a killed window
realign.flush_i = flush_i          // leftover_update: flush is inert (like kill)
realign.kill_i  = kill_s2          // leftover_update: kill does not consume
realign.hart_i  = smt_hart_i       // I4 banks
iq push         = packet_accept(overflow)   // I7 all-or-nothing
iq.hart         = packet_hart(en, smt_hart) // L3; decode from entry, not active
iq.upto_cf      = packet_upto_cf(taken, slots)  // L3; first predicted CF ends packet
redirect_hold   = redirect_rehold(!ftq, pend, lost, hit)
stall_csr_older = younger issue port waits if an older port is CSR  // I13; not fetch
```

Leftover is `instr_realign`:

```text
carry_ok = leftover_complete(
    carry_valid,
    leftover_next(addr, carry_pc),   // addr == carry_pc + 2  (I3)
    rvi_prefix(carry_lo),            // lo[1:0]==2'b11        (I5)
    1'b1)                            // host already shifts; hw[0] completes
hw_compressed[j] = (ilen_of(cfg, hw[j]) == 2)
```

Do **not** gate complete on fetch-window-aligned `pc[ALIGN-1:1]==0` — that misses mid-line
straddles (e.g. `0x7b6`→`0x7b8`). `start_hw0` is the shifted-stream slot0, not the window base.

```text
leftover_drop = leftover_pending && valid && !complete   // I3; keep only on I$ bubble
```

I3 keep (tried): `carry_valid_d = leftover_pending` so a non-next valid window does not
drop the carry. **HOLD-FAIL** fetchb `563299f6`: `plat_hc=80` `coldboot_done=0`
`mepc=0x80012584` mcause=2 `mtvec=0x3c8` (I4az leftover-across-foreign-window).
Reverted — drop on non-next remains; `flush_i` still clears. Do not keep leftover
across a valid window that is not `leftover_next`.

Snap (`g6lc_fetch_dbg`): `h=` (active SMT hart) `drop=` (`leftover_drop`). Issue-port
hart lives on `fetch_entry.hart_id` (TRACE `hart=` reads RF banks). Bind cannot take a
`fetch_entry_t` type param on Verilator 5.008 — do not add `ih=` that way.

---

## 2. Catalog (condensed)

Normalize A’s `[2:1]` → `hw_off`, `[VLEN-1:3]` → `win_tag`. Drop `smt_ss` unless the value is
per-hart leftover/switch (`en.restore`).

| Value (inferred) | A / I4* / g1* site | Fate | B combo |
|------------------|--------------------|------|---------|
| Leftover 32-bit across windows | `I4ae` `G1av/aw`, `g6lc_leftover::{rvi,on_next,assemble}` | L1 | `leftover_complete` / `leftover_next` |
| Drop leftover on valid non-next | `I4az` keep FAIL | L1 | `leftover_drop` (keep only on I$ bubble) |
| Leftover only if RVI prefix | `I4ad` | L1 | `rvi_prefix` |
| Per-hart leftover | `I4ab` | L1 | carry banks `[hart_i]`; `en.restore` folds T=1 |
| Kill inert on leftover | `G1bq/bt/bw` HOLD-FAIL (do not spare kill) | L1 | `leftover_update`: kill does not consume/drop |
| Flush inert on leftover | I4ac is trap leftover into bootrom, not this | L1 | `leftover_update` ignores `flush`; valid non-next still overwrites |
| Spec leftover hold | spec leftover hold FAIL | DELETE | `spec_req` is sequential-fetch high; ≡ I3 keep (`plat_hc=80`) |
| Compressed then straddling RVI not fused | `I4aa` | L1 | cursor walk |
| 16-bit at mid-window npc | `G1gx/ia/fu/bf/ed` present | L1 | cursor from `address_i` |
| Do not replace the live I$ window | `fe_keep` `G1y/aq/bl…` | L2 | `window_accept` + `same_win` |
| All-or-nothing window | `G1az/cx/ej/bm` `I7` | L2 | `packet_accept` — IQ pushes none if any needed FIFO is full |
| Oldest-PC issue | `G1be/cy` `I6` | L3 | IQ drain rotate; no opcode head |
| Packet ends at first predicted CF | IQ `branch_mask` | L3 | `packet_upto_cf` — n-wide `geo.slots`; BTB-miss jalr stays NoCF |
| Re-present killed redirect | `redirect_hold` | L4 | `redirect_rehold` (`!ftq && pend && lost && !hit`) |
| L2 live[] expected | dbg used npc (starve) | L2 observe | `window_expected` = hold ? redirect : vaddr; leftover slot0 always ge |
| Packet carries fetch hart | decoder `smt_hart_id_i` (active) | L3 | `packet_hart` at IQ push; B decode from `fetch_entry.hart_id` |
| Trap/eret/commit outrank SMT restore | `I4y` `I8` | L4 | `arch_src_sel` |
| Commit PC only for the active hart | I8 drain vs restore | L4 | `commit_for_hart` — outgoing CSR/fence must not reseed incoming |
| Hold mtvec fetch (bounded) | `I4z/bq/bs/bt` `I9` | L4 | `redirect_pend` until I$ registers; `smt_trap_hold` |
| Do not switch mid-trap | `I4br` `I23` | L4 | `smt_trap_hold_o` |
| Sequential step is one window | `G1fu…gd` +2 HOLD-FAIL | L4 | `next_block` |
| Predict may filter; resolve never | `I4t/v/ah` `I11` `I19` | L4 | `predict_fetchable` on `bp_fire` only; misp unfiltered |
| jalr/jr is CF even without BTB | R5 | DELETE on B | HOLD-FAIL `018aeebb`: `sp1=0` `mepc1=0x348/2` — JumpR with target 0 |
| Spare `kill_s2` of in-flight | `fe_kill` `G1cq/hs/jn` | DELETE | — |
| Fabricate sibling `c.jalr` | `G1kk…mf` `sib_cjalr` | DELETE | — (RC3) |
| Mid-line 16-bit expanded as `jalr` without C2 check | `G1gw` `G1gy` `G1hd`–`ij` | DELETE on B (`G6LC_FETCH_B` identity expand) | I1; A keeps recover |
| Mash / `jalr_usable` on resolve / `cf_unissued` / G1gg / G1gq / SB bmiss | E2/E3/E5 `g6lc_rvc_enc` `g6lc_jalr_usable` | DELETE on B | `G6LC_FETCH_B` skips; A keeps; I1/I11/I17. Inventory [`SMT-LEGACY.md`](SMT-LEGACY.md) |
| Sibling `c.jalr` arm / I$ `user[]` half | `G1iw/jl` `g1lo` `g1hx/hy` `g1mf` `sb_load00` | DELETE on B | `G6LC_FETCH_B` skips capture; rewrite already skipped; SPEC §7 |
| ID splice older fetch in front of a parked branch | `G1be` `G1cy` `G1em` `G1ev` | DELETE on B | I6; IQ drain is the order |
| Hide leftover jal / opcode IQ hide | `lj_hide` `G1dc…ex` | DELETE | `slot_live` observe only |
| Sibling I$ `user[33]` | `G1iw/jj/jl/ki` | DELETE | — |
| CSR/ALU before dependent CF | `G1em/ev/ey/fh/ee` | **RAW** | scoreboard, not fetch |
| Same-cycle CSR pair (expected-trap) | I13 hole | issue, not fetch | `stall_csr_older`: younger port waits; `unresolved_csr_q` is next-cycle only |
| Store-link wait / STQ fwd | `G1o/ae/ah/ao` | **RAW** / LSU | `g6lc_issue_barrier` / `store_buffer` |
| Bank NPC on switch; never bank 0 | `I4u` `I4p` `I10` | SMT | `g6lc_smt_pc_bank`; B ties off t0 rewind |
| Snapshot in-flight fetch, not next_block | I10 skip-760 | L4 | `snap_pc` on `npc_q_o`; not I4av/I4aw |
| Drop page-0 execute (keep `@0x10000`) | I4ag nat `0x81c` | DELETE | HOLD-FAIL IAF `npc=0x2e8` `sp1=0`; I11 |
| `ret@f772` → `0x8000081c` | I17 guess | KEEP as-is | architectural `sbi_init` link; a0=0; not ra poison |
| t0 lui/addi rewind of banked PC | `I4bg/bi/bk/bl/bp` | DELETE on B | A keeps; NEGATIVE same-page rewind |
| `keep_unaligned` via `~trap_hold` flush gate | `I4ac` | DELETE | NEGATIVE plat_hc=80 |

Full increment lists: [`LEDGER.md`](LEDGER.md). Failed tunings: [`NEGATIVE.md`](NEGATIVE.md).

**7ba / sibling recover** is the fabricate row. B is correct when `slot.bytes` equals I$ memory at
that PC, even if A shows a constructed `c.jalr`.

---

## 3. Metadata — so envelopes do not edit combos

Knobs change **widths and which rows are live**, not the equations. `NrCores`, L2, `BPType`, RVV,
Ara never appear.

```systemverilog
typedef struct packed {
  int unsigned w_bytes, align_bits, slots, hw_per_w, issue, harts, hold_max;
  logic smt, rvc, ftq, rvh;
} fetch_geo_t;

typedef struct packed {
  logic align, accept, order, redirect, restore, trap_hold, bp_hint;
} fetch_en_t;
```

| Envelope | `geo` / `en` | Snap to watch (`+fetch_snap`) |
|----------|----------------|-------------------------------|
| smt2 `T=2,I=2,FW=64` | `smt=1`, `issue=2`, `slots=4`, `restore=1` | `rst`, `h=`, leftover, `[fetch_slot]` ×4, TRACE `hart=`, `age=`/`hm=` |
| stream8 `T=1,I=1,N=2` | `smt=0`, `issue=1`, `slots=2`, `restore=0`; **two core instances** | `T=0` / `rst=0`; no fetch `NrCores` |
| ooo_server `I=4` | `issue=4`; L1/L2 unchanged | `issue_v[3:0]`, port1-without-0 SVA; `live=` width `geo.slots` |
| DeepSpec / OoO | no new `en` bit; maybe `hold_max` if FTQ/ckpt deeper | `spec`, `k2`, `src` (misp=6), `cf_mask`, `wr=` (I$ valid ∩ ¬same_win), `age=` |
| `RVH` | `geo.rvh` | exception sideband already pass-through |

`NrCores` is N frontends, not a fetch field. Speculation is `spec` + `kill_s2` (predict/misp/flush), never a spare opcode kill. Stream I=2: raise `geo.issue` on the **stream** package — not smt2 7ba.

---

## 4. Sim-only debug (`g6lc_fetch_dbg.sv`) — **landed**

`core/fetch_B/g6lc_fetch_pkg.sv` (synth) + `g6lc_fetch_dbg.sv` (bind, `translate_off`). Frontend
calls `kill_s1`/`kill_s2`, `window_accept`/`same_win` on redirect, and a thin `next_block`.
Snap does not assign kill/NPC/bytes.

`pragma translate_off`. Bind into `frontend`; not a fifth combo. Must not assign
`kill_s*` or `slot.bytes`.

`fetch_snap_t`: `{npc, fetch_addr, vaddr_q, expected, win_tag_v, win_tag_e, hw_off_f,
leftover, same_win, accept, live_mask[SLOTS], cf_mask[SLOTS], issue_v[ISSUE], kill_s1,
kill_s2, spec, redirect_hold, redirect_hit, arch_src, restore_fire, geo_issue, geo_harts,
geo_slots}`.

`[fetch_slot] k= pc= hw= cf= ilen= same= ok=` — one line per live slot (`geo.slots` wide).
`hw` is `instr[15:0]`; `ok` is I1 (`hw` equals the shifted I$ halfword at that PC; leftover
slot 0 is the previous window and is not compared). `cf` is `cf_t` (0=NoCF … 4=Return).

Snap extras for envelopes: `exp=` is `window_expected` (redirect or vaddr, **not** npc);
`wr=` window reject; `age=` cycles of `redirect_hold` (I23 observe, no silent release);
`hm=` `geo.hold_max`. `live=` is prefix-drop against that expected (leftover slot0 kept).
Do not AND `live` into IQ while `accept` includes `kill_s2`.
Window filter also matches **slot PC / rpc / tgt**, so `+fetch_snap_lo/hi` around a pin
does not miss a mispredict whose `fa` already left the window.

SVA (sim): slot valids are a prefix (no holes); consecutive live PCs step by `pc_ilen`;
same-window bytes match I$ (I1). `issue>1 && order |-> !(port1 && !port0)` unchanged.

`arch_src` is I8 via `arch_src_sel`: 1=EX, 2=DEBUG, 3=ERET, 4=COMMIT, 5=RESTORE, 6=MISP.
SVA: same-cycle restore+exception ⇒ `src=EX`.

SVA: `!en.restore |-> !restore`; `en.restore && harts<2` error; `accept |-> same_win`;
`kill_s1 |-> misp|flush|replay`; `issue>1 && order |-> !(port1 && !port0)`.

Plusarg `+fetch_snap`: print leftover / window-reject / restore / spec+kill / redirect_hold
/ predicted-CF edges, plus `[fetch_slot]` rows. `+fetch_snap_lo=` / `+fetch_snap_hi=` (hex,
allowlisted in `g6lc_tb.cpp`) print every cycle whose npc/fa/vq/**slot PC/rpc/tgt** is in
that window. Off by default.

A/B TRACE: compare snaps. Truth is I$ `data` + `ilen_of`, not A's rewritten halfword. First
`bytes≠memory` on B is L1; A fabricate vs B memory is B correct.

---

## 5. How to revise a row

1. Name the **value**, not a `g1*`.
2. Fit it in one of the four combos or mark DELETE / RAW.
3. If it needs a new **input** on align/accept/redirect, that is a fetch review (port freeze).
4. Mini first; hold TRACE of `fetch_snap_t`; cookie last.
5. Fail → revert that increment. Frozen A (`core/frontend` + `core/smt` pkg/dbg) is unchanged.
   Edit **`core/fetch_B`** only.

Live B pin (fetchb `6348c84e`, snap `rpc`): `sbi_scratch_init` @`3912` **commits**. IAF
`0x80047000` is EX resolve of `rpc=0xbcba` (`c.srli` in memory) — **not fetch**.
TRACE `a4=a5=0x80042870` (aligned); `c.lw a5,0(a5)` is not the fault. Next pin is IAF
`mepc=0x80047000` `mcause=1` (fetch of a non-text VA; dump-WFI @`sbi_pmu_init+0xb0` /
`0x80002d38`). Snap `rpc`/`tgt` at t=81371: **`rpc=0x8000bcba` `tgt=0x80047000` `src=6`**. Memory at `0xbcba`
is `c.srli a4,a4,0x20` (`0x9301`), not a `jalr`. Commit TRACE already retired that `c.srli`.
Fetch I1 holds. The resolve PC is a **non-CF** — EX identity alias (I14 / RC4
`flu_trans_id`), not leftover and not `sib_cjalr`. Do not PMA-filter resolve (I11). This pin
leaves the fetch plane.

I14 pairing (this increment): `g6lc_ex_id` — one CF issue port owns `fu_data`, PC,
compressed, BP, hart, ALU compare, and `flu_trans_id`. IRO no longer holds the last CF
PC (G1p) or smuggles PC through `operand_c` (G1r). `branch_unit` uses `pc_i`. Scoreboard
keep list is **not** extended (NEGATIVE.md §8).

Rebuild fetchb `1b8e329a` (slot snap), held `8b6b310e`. Windowed `+fetch_snap_lo/hi=8000bcb0/8000bd00`:

| t | slot | pc | hw | cf | ilen | I1 `ok` |
|--:|--:|---|---|--:|--:|--:|
| 31693, 81231, **81357** | k=1 | `0xbcba` | `9301` | **0 NoCF** | 2 | 1 |
| **81371** MISP | live=`0000` cf=`0000` | rpc=`0xbcba` | — | src=6 | — | — |

Zero SVA hits (`bytes!=memory`, slot hole, pc step). L1 emitted the memory `c.srli` as
NoCF fourteen cycles before the resolve. Fetch I1/I2 hold.

**ID RC3 (this increment):** `G1gw`/`G1gy` expanded a mid-line (`pc[2:1]==01`) 16-bit as
`jalr` when `[15:12]==1001 && [6:2]==0 && rs1!=0` — **no C2 `[1:0]==10` check**.
`c.srli rd,32` (`0x9301`) matches; B now takes `instruction_rvc_raw` under
`G6LC_FETCH_B`. The `decoded_hd` sib_cjalr rewrite (G1hd–ij) is likewise A-only.
A/slfix unchanged. Do not PMA-filter resolve (I11).

Rebuild fetchb `71637263`. Windowed TRACE: **zero** `rpc=0xbcba`. `0xbcba` still `hw=9301`
cf=0 ok=1. IAF `0x80047000` is gone. Hold ran 6e6: `coldboot_done=1`, `mtvec=0x800003d8`,
hart1 `mepc=0x80008df0` `mcause=4` WFI, hart0 `npc=0x80008cb0` (no trap). Dump `[1000]`
contains `51b1c001` (not the hold cookie `51b1babe`). Next pin is after `sbi_scratch_init`.

**I6 ID splice (this increment):** G1be/cy/em/ev insert-older-at-port-0 is A-only.
fetchb `3c33528f`. Hold 6e6 **same hang class**: hart0 `npc=0x80008cb0` in `spin_lock`
(`and`@`8cae` straddles window `8cb0`; `ra0=0x3a52` = `sbi_scratch_used_space` after
`jal extra_lock`). hart1 `mepc=0x80008df0` `ld 8(a0)` `mcause=4` `sp1=0x60`.
`[1000]=51b1c001` is **`generic_cold_boot_allowed`** (held stub `lui+addi 1`, then
`a0=1`) — not a truncated success cave (`sbi_hart_switch_mode` @`0xef70` writes
`51b1babe`). Do not add another ID splice. Next class: leftover of that `and` into
`8cb0`, or hart1 `a0` unaligned — still I1/I3, not `sib_cjalr`.

Directed leftover minis on B: lottery hangs (`mcause=2` near its trap); FDT fail printed `105`
=`P6 0x69` (2nd `ld 8(sp)` vs `t1`, store-forward — not L1). Do not treat either as a leftover
combo miss.

**I3 leftover of `and`@`8cae` (this increment):** holds. `spin_lock` wait loop is
`and a1,a3,a4` @`8cae` (32-bit, straddles `8cb0`) then `beq` @`8cb2`; `j 8cae` @`8cbc`.
Hold TRACE fetchb `3c33528f` held `8b6b310e`: `and` **commits** (first `andcmt` t=31064;
tickets match `a1==a2` at t=81083, 84465, …). Drop-on-non-next did not lose that RVI.

Hart1 TRACE (`hart=1`) at the same `8df0` window:

| t | loc | hart1 `ra` | `sp` | `a0` |
|--:|---|---|---|---|
| 94420 | `8de0` (hart0 fetch; hart1 RF idle) | 0 | 0 | 0 |
| 200384 | `8df0` `c.ld 8(a0)` | 0 | `0x40` | 0 then **`-3`** |
| hang 2e6 | `mepc1=8df0` `mcause=4` `wfi1=1` | 0 | `0x60` | unaligned (`8(a0)=5`) |

`a0=-3` → `c.ld` address 5 → `mcause=4`. `sp` walked `0→0x40→0x50→0x60` (page-zero
epilogues, **R1**). `ra1=0`: unregister ran with no call. Next class is hart1 PC /
stack (I10 restore, R1), not leftover and not `sib_cjalr`. Do not keep leftover.
Do not ID-splice. Do not PMA-filter resolve. Snap `h=`/`ih=`/`drop=`.

**L3 `packet_hart` (this increment):** IQ stamps the fetch hart; B decode uses
`fetch_entry.hart_id` not the active hart (`G6LC_FETCH_B`). A still overwrites from
`smt_hart_id_i`. One frontend line (`.hart_i(smt_hart_i)`). n-wide: `geo.issue` still
widens `[fetch_slot]` / `issue_v`; TRACE `hart=` selects the RF bank. fetchb
`33d6490e`: hang class **unchanged** (`and` still commits; hart1 still retires
`8de2` with `ra=0` `sp=0x50` `a0=-3`). **I8 `commit_for_hart` (this increment):** TRACE t=200082 `src=4` `tgt=0x8cbc`
while `h=1` stole hart1's ROM fetch (hart0 `spin_lock` commit). B now applies
PC_COMMIT only if `commit_hart == active`. fetchb `2c2a9567`: hart1 **takes
`jr s0`** (slot `10014` `cf=3`, npc `0x80000000`); `sp1=0x80048000`. Hang
**moved**: hart0 `mepc=0x80047f48` `mcause=1` dump-WFI `@0x2d38`; hart1
`mepc=0x80000768` `mcause=4` (`j`@`766` leftover vs `c.ld`@`768`); both WFI;
`plat_hc=2`. Jalr-always-JumpR **reverted** (target 0). `leftover_update` (kill does not
consume carry) **landed** fetchb `5808e9d7`: hang class **unchanged**. Spec leftover
hold **reverted** fetchb `265ea994`: `plat_hc=80` `npc0=0x10050` `mtvec=0x10040`
(I3 keep — `spec_req` is sequential-fetch high). Flush-inert leftover **landed**
fetchb `e97c051b`: hang **unchanged** (`768`/`47f48` `plat_hc=2`). Snap: switch
holds leftover (`t=201766 pend=1`) then `768` is a **foreign** drop (`drop=1`
`hw=7e60` `c.ld`) — restore NPC skipped the in-flight `760` window that would
have created `jal`@`766` leftover. **I10 `snap_pc` (this increment):** bank the
accepted I$ address when switch kills it, not `next_block`. fetchb `ec1239ef`:
hold **cookie-exit** t=202752 `[1000]=51b1babe` `plat_hc=2` `coldboot_done=1`
BANR `npc0=0xef98` (cave WFI after `lui`/`addi` `51b1babe`). Slot `766`
`hw=e06f` `cf=2` leftover-completes. `CVA6_COOKIE_EXIT` stops before the
`51b1d000` store. Not I4av/I4aw. Do not PMA-filter resolve.

**I10 restore TRACE** (fetchb `33d6490e`, `+fetch_snap` `src=5`): first switch **to hart1**
at t=200079 restores **ROMBase `0x10000`** (correct unused bank). Leave at t=200593
`npc=0x10050` = bootrom `_hang` `j 1b` — `jr s0` @`0x10014` was not taken on that
quantum. Hart0 ROM `jr s0` commits with `s0=0x80000000` at t=293. B ties off t0
rewind (`npc_alt=0`). fetchb `fa1b970c`: hang class **unchanged** (first hart1 restore
was already ROMBase, not a t0 rewind). Next is R5: hart1 `jr s0` @`0x10014` not taken
(`_hang` @`0x10050`). Do not PMA-filter resolve.
