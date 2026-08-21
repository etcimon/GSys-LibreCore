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

Formal (when split out): `A_decode_pure`, `A_no_fabricate`, `A_pc_monotonic`, `A_leftover_adjacent`,
`A_leftover_rvi`, `A_leftover_hart`, `A_kill_inert`, `A_no_loss`.

Live B: `core/fetch_B/instr_realign.sv` — `carry_ok = leftover_complete(...)`;
`hw_compressed = (ilen_of==2)`; cursor over `NrHalfWords`. A non-next valid window
still **drops** leftover (`leftover_drop`; I4az / `plat_hc=80` if kept). Kill **and
flush** are inert (`leftover_update = valid && !kill`). Spec leftover hold
(`spec_req` skips drop) **reverted** — `spec_req` is sequential-fetch high.
Snap prints `h=` / `drop=` (no frontend combo).

---

## 3. L2 — window accept

```text
accept = valid && !kill && (win_tag(addr) == win_tag(expected_pc))
live[k] = slot[k].valid && accept && (slot[k].pc >= expected_pc)
```

Hold bound = `geo.hold_max` (`SLOTS`, or FTQ depth). Unbounded hold is the largest `NEGATIVE.md`
class.

Live B: `redirect_hit` / `redirect_accept` are `window_accept` + `same_win` (no `[VLEN-1:ALIGN]`
literals). `live_mask` is observed in `g6lc_fetch_dbg` (`slot_live` + `window_expected` +
`slot_ge_expected`); **not** an IQ drop — `accept` includes `kill_s2`, which would eat taken
jumps. `wr=` is I$ valid ∩ ¬same_win. Do not use `npc` as L2 expected (npc has `next_block`'d).

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
fetch input.

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
| `g6lc_{present,sib_cjalr,fe_keep,fe_kill,lj_hide,iq_hide,leftover,rvc_enc}` | Stay with `smt_legacy`. Never instantiated on B |
| `g6lc_jalr_usable` on resolve | Already removed (CF-0 / I11). Predict-only or absent on B |
| `id_stage` recover latches / `make_cjalr16` | `smt_legacy` only; B ID sees memory bytes |
| I$ sibling `user` channel | dead on B |
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
