# Generic instruction-supply specification (`core/fetch_B/`) — B

**Status:** Handoff is retired. Frozen **A** is `core/frontend` + `core/instr_realign` (applied
fetch at `3745cfb06`) with pkg/dbg in `core/smt/`. **B** is `core/fetch_B/` (`Flist.fetch_B`,
default compile) — same peels and P1–P4. Module names match (`frontend`, `instr_queue`,
`instr_realign`, …). Live drop-in is still one `frontend.sv` + realign + queue until
`sbi_console_init` / R6–R11 close.

Implements **I1**–**I12** of [`../firmware-boot-principles.md`](../firmware-boot-principles.md).
Value catalog: [`VALUES.md`](VALUES.md).

**Prime constraint:** no address, register number, instruction encoding, or literal bit index.
Everything from `{FETCH_WIDTH, INSTR_PER_FETCH, FETCH_ALIGN_BITS, NrIssuePorts, NrHarts, RVC, VLEN}`
via `fetch_geo_t`.

---

## 0. Layering (target after A/B is cookie-green)

```text
        I$ response  (one window: FETCH_WIDTH bits @ window-aligned address)
              │
   L1  ALIGN     g6lc_fetch_align     bytes+addr → slots     I1–I5
   L2  WINDOW    g6lc_fetch_window    drop only              I7
   L3  ORDER     g6lc_fetch_order     oldest-PC, width=I     I6
   L4  REDIRECT  g6lc_fetch_redirect  priority encoder       I8–I12
```

**L2 and L3 may drop, never modify.** Only L1 produces instruction bytes.

Live B already does L4 (`arch_redirect_select`), simple kill, and a cursor realigner. Splitting L1–L3
into named modules is a **bit-identical extract** after firmware progress, not a second rewrite.

---

## 1. Geometry — `g6lc_fetch_pkg`

| Name | Definition | FW=32/RVC | FW=64/RVC | FW=128/RVC | FW=64/!RVC |
|---|---|---|---|---|---|
| `W_BYTES` | `FETCH_WIDTH/8` | 4 | 8 | 16 | 8 |
| `ALIGN_BITS` | `FETCH_ALIGN_BITS` | 2 | 3 | 4 | 3 |
| `SLOTS` | `INSTR_PER_FETCH` | 2 | 4 | 8 | 2 |
| `HW_PER_W` | `FETCH_WIDTH/16` | 2 | 4 | 8 | 4 |
| `MIN_ILEN` | `RVC ? 2 : 4` | 2 | 2 | 2 | 4 |

Functions: `hw_off(pc)`, `win_base(pc)`, `win_tag(pc)`, `same_win(a,b)`, `next_block(pc)`,
`ilen_of(hw)` — the **only** encoding knowledge in L1–L4 (`RVC ? (hw[1:0]==11 ? 4 : 2) : 4`).
Opcode class belongs to `instr_scan` (predict) and the decoder (execute). L2/L3 must not consult it.

`fetch_geo_t` / `fetch_en_t`: [`VALUES.md`](VALUES.md) §3. Envelopes const-fold `en.restore` (SMT)
and `geo.issue` (n-wide). `NrCores` is not a fetch field.

---

## 2. L1 — align / leftover

Per-hart leftover `{lo_v, lo_hw, lo_pc}`. Complete only if `leftover_next` (`addr == lo_pc+2`)
and `rvi_prefix(lo_hw)` (`[1:0]==11`). The host already right-shifts the I$ line so halfword 0 is
the completing high half — `start_hw0` is that shifted slot0, **not** `pc[ALIGN-1:1]==0` (would
miss mid-line straddles). Else leftover stays pending (I3). Kill does not change leftover state.
`start_pc` is the first PC to emit (replaces A’s shift/present mux).

Formal: the leftover half of this list is **live and proven** — `core/fetch_B/formal/`
(`g6lc_fetch_align.sby`), no module split required, because the contract already *is* a set of
pure functions in `g6lc_fetch_pkg`. `A_leftover_adjacent` = I3, `A_leftover_rvi` = I5,
`A_kill_inert` = `leftover_update`/`leftover_retake`, `A_no_loss` = `leftover_slot0_push`
(in `g6lc_fetch_order.sby`). Still unproven and still needing the split (they quantify over
memory bytes or over the per-hart bank, neither of which is a closed tuple): `A_decode_pure`
(I1), `A_no_fabricate` (I2), `A_leftover_hart` (I4). I1/I2 are asserted instead at L3 in
`g6lc_fetch_dbg`. Full map: §10.

Live B: `core/fetch_B/instr_realign.sv` — `carry_ok = leftover_complete(...)`;
`hw_compressed = (ilen_of==2)`; cursor over `NrHalfWords`. A non-next valid window
still **drops** leftover (`leftover_drop`; I4az / `plat_hc=80` if kept). Flush and
`kill_s1` (misp/replay) are inert; leftover-complete **does** update on `bp_fire`
so the next leftover jal can be captured (`realign.kill_i = kill_s1`). Spec leftover hold
(`spec_req` skips drop) **reverted** — `spec_req` is sequential-fetch high.
I7 is all-or-nothing except leftover-complete slot0 (`leftover_slot0_push`): if the
carry insn fits and later slots overflow, push slot0, consume leftover, replay the rest
at the first unpushed PC. Holding leftover-complete (`pipe_keep` / leftover_replay_hold)
**MINI-FAIL** osbi mepc=129b8. 12958 illegal **closed**. Snap prints `h=` / `drop=` (no frontend combo).

---

## 3. L2 — window accept

```text
accept = valid && !kill && (win_tag(addr) == win_tag(expected_pc))
live[k] = slot[k].valid && accept && (slot[k].pc >= expected_pc)
```

Hold bound = `geo.hold_max` (`SLOTS`, or FTQ depth). Unbounded hold is the largest `NEGATIVE.md`
class.

Live B: `redirect_hit` / `redirect_accept` are `window_accept` + `same_win` (no `[VLEN-1:ALIGN]`
literals). `live[]` masks IQ `instruction_valid` with `slot_keep_link` (`pc>=exp` **or**
direct jal/call). Return/branch/addi still drop (`12970` vs `next_tag@12974`).
`present_expected` is latched on I$ take (`bp_pend ? tgt : vaddr`). `accept` is 1 here —
do not AND `kill_s2` (eats taken jumps). Leftover slot0 is always ge. `wr=` is I$ valid ∩
¬same_win. Do not use `npc` as L2 expected (npc has `next_block`'d). Not I$ extra-shift
(NEGATIVE `start_pc`) and not exact `vaddr==tgt` (NEGATIVE `bp_pend` exact-PC).
`bp_ret_ge` (`vaddr>=tgt` + hold `seq_base` on tgt) is the same class as exact-PC
(stock/osbi/frame/alias/split MINI-FAIL) — do not re-land.

---

## 4. L3 — order

Per-hart FIFO; fill port `p+1` only if `pc == prev.pc + prev.ilen`. Width = `geo.issue`. Taken CF
ends the packet naturally (`packet_upto_cf`, n = `geo.slots`). Opcode-agnostic (I6). Live B:
`packet_hart` is stamped at IQ push; decode reads `fetch_entry.hart_id` so a switch cannot
retag an in-flight packet as the incoming hart (R1). BTB-miss jalr is NoCF — not a packet
end (NEGATIVE always-JumpR).

---

## 5. L4 — redirect (live in B as `arch_redirect_select`)

| Prio | Source | Target |
|---:|---|---|
| 0 | RESET | `boot_addr_i` |
| 1 | EXCEPTION | `trap_vector_base_i` (hold until decode consumes — I9, bounded) |
| 2 | DEBUG | debug ROM |
| 3 | ERET | `epc_i` |
| 4 | PC_COMMIT | `pc_commit_i` (+4 if not halt) |
| 5 | SMT_RESTORE | `smt_npc_restore_i` (`en.restore` only) |
| 6 | RESOLVE | resolved target — **never filtered (I11)** |
| 7 | WINDOW_REJECT | `expected_pc` |
| 8 | PREDICT | `predict_address` — may filter (I19) |
| 9 | SEQUENTIAL | `win_base(expected_pc) + W_BYTES` |

Live B: `arch_src_sel` implements I8 (`ex > eret > commit > debug > restore > misp`). Restore is
`en.restore` only. **`fetch_address` uses that encoder** (`arch_valid ? arch_pc : hold/seq`) —
a restore-first I$ mux outranked trap (I4y) and could present a banked data VA. Trap hold is
`redirect_pend` until the I$ block is registered (`smt_trap_hold_o`); do not gate leftover flush
with `~trap_hold` (NEGATIVE `I4ac`).

Redirect completion: a target is done when its block is **registered**. Kill of that in-flight
re-presents the target (`redirect_hold`). Sequential step is one window (I12).

I10 live B: `g6lc_smt_pc_bank` snapshots `npc_live` only (`npc_alt` tied off). First
hart1 restore is `ROMBase` (`0x10000`); A may still rewind t0. `npc_q_o` is
`snap_pc`: if a request is in-flight at restore, bank that accepted address
(not fetch-ahead `next_block`). Hold cookie `51b1babe` fetchb `ec1239ef`.

I8 live B: `commit_for_hart` — `set_pc_commit` reseeds fetch only when the
committing hart is active. TRACE t=200082 `src=4` `tgt=0x8cbc` while `h=1`
stole hart1's bootrom `jr s0`.

---

## 6. Predictor seam

Opaque hint `{taken, target, cf_type, confidence}`. Suppression is I19 only. Per-hart RAS/GHR/ckpt
(I20). `g6lc_cf_legal(regime, target)` at priority 8 only — never on resolve. `BPType` is not a
fetch input. `bp_fire` also requires the CF slot was consumed (IQ accept); classification is
independent of consume (NEGATIVE G1br).

---

## 7. I$ interface

One window: `FETCH_WIDTH` bits + exception sideband (`gpaddr`/`tinst`/`gva` pass-through under
`RVH`). No sibling-half `user[33]`. No `ICACHE_LINE_WIDTH` in the frontend.

---

## 8. Migration — done; workspace is `fetch_B`

| Path | Fate |
|---|---|
| `core/frontend/*.sv` + `core/instr_realign.sv` | Frozen **A** (applied fetch). Predictors still compiled from here |
| `core/smt/` | **pkg + dbg only**. Not on the default flist while `Flist.fetch_B` is included |
| `core/smt_legacy/` | g1\* oracle frontend + recover + SMT banks (`Flist.smt_legacy`) |
| `g6lc_{present,sib_cjalr,fe_keep,fe_kill,lj_hide,iq_hide,leftover,rvc_enc}` | Stay with `smt_legacy`. Never instantiated on B. Inventory: [`SMT-LEGACY.md`](SMT-LEGACY.md) |
| `g6lc_jalr_usable` on resolve | **I11:** skip under `G6LC_FETCH_B` (`branch_unit` / IRO G1gg / issue G1gq). A keeps. Predict-only is `bp_fire` |
| `id_stage` recover latches / `make_cjalr16` | `smt_legacy` only; B ID sees memory bytes |
| I$ sibling `user` channel | **dead on B** (`G6LC_FETCH_B` skips G1iw/jl overlay in `g6lc_icache`) |
| `g6lc_smt_*` banks, `thread_select`, `issue_barrier`, `sb_keep` | `core/smt_legacy/` (not fetch) |
| `core/fetch_B/` | **B workspace** — default `Flist.cva6` via `-f Flist.fetch_B` |

B wiring: `Flist.fetch_B`, `+define+G6LC_FETCH_B`, g1 ports tied in `cva6.sv`.

Sizes: A fetch plane ~10.2k L → B 3.8k L (−63%). Spec extract (align/window/order/redirect modules)
is extra cleanup, not a size target.

---

## 9. Build order

1. **Keep A/B dual harness on smt2.** Search with minis + `fetch_snap_t` TRACE. Firmware is the gate.
2. Close B’s live pin (`sbi_scratch_init` @`3912`) as a **value row** (`VALUES.md`) — not a `g1*`.
3. Align I8 (SMT restore vs trap) on B if TRACE shows it; bounded trap hold (I9, I23).
4. Bit-identical extract: `g6lc_fetch_pkg` + align/window/order/redirect; `g6lc_fetch_dbg.sv`
   `translate_off`.
5. Hold cookie matched; g1\* frontend → `core/smt_legacy/`. Frozen A is `core/frontend`.
   Default flist is `Flist.fetch_B`. Nat pin still hangs in the R4 FDT walk (`jal@1826a`);
   do not copy A's nat cookie if it is `plat_hc=80` fabricate.
6. **Capability A/B** (same peels / `soak.sh`): one `fetch_en_t` or VALUES row per increment
   **in `core/fetch_B`** (stream I=2 leftover mini, n-wide `geo.issue`, `RVH`
   exception-suppress, …). Do not touch the issue throttle (RC1/RC4) until R6–R11.

ISA red lines stay off. `NEGATIVE.md` classes stay out of B.

---

## 10. Ladder position of every fetch invariant

Where each invariant is *checked today*, and whether it is worth moving left. Rungs are the
feedback-latency ladder in
[`../multi-threading/AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md`](../multi-threading/AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md)
§4: **L0** definition · **L1** elaboration · **L2** bounded proof · **L3** simulation assertion ·
**L4** directed mini · **L5** suite · **L6** firmware · **L7** peel/hold/TRACE. A check's value is
roughly inversely proportional to its latency, so the standing work item is always "move the check
from S to S'", never "run S again".

| Inv | Rule (short) | Rung now | Artifact | Envelope proven | Move left? |
|---|---|---|---|---|---|
| **I1** | decode is a function of bytes+address alone | **L2** + L3 | `g6lc_fetch_realign.sby` (live module: emitted halfword == `data_i` at that slot's own address); `g6lc_fetch_dbg` keeps the same check in every sim | smt2 cfg (FW=64, T=2, RVC) | Done. *This row previously read "L3 is leftmost feasible" - that was wrong: one window is a bounded free input, so the quantifier is closed after all.* |
| **I2** | realigner emits exactly the ISA instrs, no rewrite | L3 + L2 | dbg slot pc-step + emission check; `packet_upto_cf` order proof | slots ≤ 8 | Partly moved. The packet-order half is L2; the bytes half stays L3. |
| **I3** | leftover completes only from the next window | **L2** | `g6lc_fetch_align.sby` | all addresses | Done. |
| **I4** | leftover is per-hart | **L2** | `g6lc_fetch_realign.sby` - a window presented for one hart leaves every other hart's carry unchanged (NH=2) | smt2 cfg | Done. |
| **I5** | complete only from a legal RVI prefix | **L2** | `g6lc_fetch_align.sby` | all halfwords | Done. Also re-checked on the *emitted* slot at L3. |
| **I6** | IQ order is program order, opcode-agnostic | **L2** | `g6lc_fetch_iq.sby` - NON-INTERFERENCE over two live `instr_queue` copies: identical control, different raw `instr_i`, identical `ready_o`/`consumed_o`/`replay_*`/`fetch_entry_valid_o`/`.address`. Packet-mask shape also proven by `g6lc_fetch_order` | smt2 cfg, NI=2 | Done. |
| **I7** | whole window or none | **L2** | `packet_accept`, `leftover_slot0_push` | all | Done. |
| **I8** | redirect total priority order | **L2** | `g6lc_fetch_redirect.sby` (incl. restore-never-outranks-trap) | both T envelopes | Done. |
| **I9** | trap entry held until decode consumes | L3 (observe) | `redirect_hold` / `hold_age` | - | **Open.** Needs the hold state, which lives in `frontend.sv`; a live-module proof there is far heavier than the realigner (predictors + IQ elaborate too). Next candidate after I6. |
| **I10** | thread switch loses no progress | **L2** | `g6lc_fetch_smt.sby` (`snap_pc`) | both T envelopes | Done. |
| **I11** | mispredict always redirects to the resolved target | L1 + L3 | `G6LC_FETCH_B` skips `g6lc_jalr_usable`; `diag-isa-red-lines` RL-RESOLVE-PMA | — | Enforced by absence, mechanically. |
| **I12** | sequential step is one window | **L2** | `g6lc_fetch_geo.sby` (`nxt == base + W`, `nxt > pc`, `!same_win(pc, nxt)`) | FW 32/64/128/256 × RVC on/off | Done. |
| **geo** | window algebra is self-consistent (`win_base`/`win_tag`/`same_win`/`hw_off` agree; `ilen_of` ≡ `rvi_prefix`) | **L2** | `g6lc_fetch_geo.sby` | 6 envelope points | Done. This is SPEC §1 and §F as properties. |
| **I23** | every hold carries an explicit bound | L3 (warn) | `g6lc_fetch_dbg` latched `$warning` | live geometry | Observe-only on purpose: silent release is a recorded negative. |
| **R1/I4** | packet carries the *fetching* hart | **L2** | `g6lc_fetch_smt.sby` (`packet_hart`) | both T envelopes | Done. |
| **I8 (SMT)** | PC_COMMIT reseeds only for the active hart | **L2** | `g6lc_fetch_smt.sby` (`commit_for_hart`) | both T envelopes | Done. |

**Envelope note (the `C` collapse).** Three different mechanisms keep these proofs from being
per-package, and the distinction matters when adding a fourth:

1. **Free the fold.** `en.restore` and `en_smt` are *free inputs* in the redirect and SMT proofs,
   so one run covers T=1 and T>1 together instead of needing a package each.
2. **Prove at the ceiling.** The order proof runs at `N=8`, the geometry ceiling. A narrower
   `INSTR_PER_FETCH` is the same proof with upper slot inputs tied off, and tying an input off can
   only *remove* counterexamples — so the wide proof subsumes the narrow ones.
3. **Sweep what must be pinned.** Only `g6lc_fetch_geo` genuinely needs a concrete
   `FETCH_WIDTH`/`ALIGN_BITS`/`RVC`, so it is a multi-task sby sweep (6 points) rather than a
   single run.

So raising `geo.issue`, `geo.harts` or `FETCH_WIDTH` is a **re-run** (seconds), not a re-soak
(hours). Do not "specialise" a proof down to a package's geometry — that weakens it. Prefer (1),
then (2), and only use (3) when the function genuinely reads `cfg`.

**One stated assumption**, recorded rather than hidden: `g6lc_fetch_geo` assumes the PC is not in
the final window of the 64-bit space, because `win_base(pc) + W_BYTES` wraps there and forward
progress genuinely does not hold. The core cannot fetch such an address (VLEN is 39/64 and no PMA
execute region reaches the top), so the strong property is kept and the impossible input excluded.

**Open, in ladder order:** just **I9** (bounded trap hold). I4 and I6 both closed by moving from
pure functions to LIVE modules: I1/I2/I4 in `g6lc_fetch_realign` (the realigner plus its per-hart
bank) and I6 in `g6lc_fetch_iq` (two queue copies). I9 is the last one, and it is harder than
either because the hold state lives in `frontend.sv`, which drags in the predictors and the queue.

**A note on proof shape, since it decided three of these.** A property that says "X must not
depend on Y" cannot be witnessed by any single execution, so it needs self-composition: run two
copies, vary only Y, assert the observable agrees. That is how I6 is proven, and it is the right
shape for any future "opcode-agnostic" / "value-independent" claim -- including the ISA red lines
in `../firmware-boot-principles.md` sE, which are all of that form.
