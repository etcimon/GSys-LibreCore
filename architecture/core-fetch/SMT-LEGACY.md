# `core/smt_legacy/` — what default B still compiles, and why recover is not fetch

Companion to [`README.md`](README.md), [`SPEC.md`](SPEC.md) §8, [`LEDGER.md`](LEDGER.md) §2,
[`NEGATIVE.md`](NEGATIVE.md), [`../firmware-boot-principles.md`](../firmware-boot-principles.md).

> **2026-09-10 — the directory has been split.** `smt_legacy` used to be *three things in
> one directory*: 9 files live on B, 10 g1\* recover, and 4 oracle frontend copies. The
> two retired groups now live under **`core/fetch_A/`**, so `core/` no longer holds a
> duplicate of anything `core/fetch_B/` owns:
>
> | Now at | What | Reached by |
> |---|---|---|
> | `core/smt_legacy/` (9 files) | **LIVE on B** — SMT2 banks/scheduler + shared packages | `Flist.cva6` |
> | `core/fetch_A/smt_legacy/` (10) | g1\* recover; call sites skipped under `G6LC_FETCH_B` | `Flist.cva6` (compiled for A / `id_stage` / oracle) |
> | `core/fetch_A/smt_legacy/` (4) | oracle frontend copies | `-f Flist.smt_legacy` only |
> | `core/fetch_A/frontend/` (3) | retired `frontend`/`instr_queue`/`instr_scan` | nothing; was commented out of `Flist.cva6` |
> | `core/fetch_A/smt/` (2) | frozen-A `g6lc_fetch_{pkg,dbg}` | `-f Flist.fetch` only |
>
> `core/frontend/` now holds **predictors only**, and `core/smt/` is gone. The rule that
> matters is unchanged and is now also structural: **never compile two `module
> frontend`.** Tiering follows the files (`.licensing-tiers` gained `core/fetch_A/**` as
> tier R) — retiring RTL does not relicense it. §1 below describes the 19 files
> `Flist.cva6` still compiles; §2 the oracle set. Paths in both sections are updated.

## 1. Default `Flist.cva6` — 19 files

### 1.1 SMT banks / scheduler (required on B)

Instantiated from `cva6.sv`. Fine-grain switch: flush IF + unissued decode; EX drains;
RF/CSR/RAW keyed by instruction `hart_id`. Not a fetch combo.

| File | Role |
|---|---|
| `g6lc_thread_select.sv` | Hybrid miss / quantum / starve; delayed `switch_o` so PC restore sees the **incoming** hart |
| `g6lc_hart_state.sv` | Ready = enable ∧ ¬WFI; sticky miss/block are contention, not `~ready` |
| `g6lc_smt_regfile.sv` | Banked integer RF (`NrHarts==1` → single `ariane_regfile`) |
| `g6lc_smt_pc_bank.sv` | Snapshot outgoing NPC on `switch_i` only; restore `npc_bank[active]`. B ties off t0 `npc_alt` |
| `g6lc_smt_csr_bank.sv` | Banked CSRs; `hart_halt_o` → WFI |
| `g6lc_issue_barrier.sv` | CF/CSR barrier + I13 `stall_csr_older` |

Holds that wrap `thread_select` live in `cva6.sv` (`SMT_COLD_EXCL`, DRAM grace, first-act exclusive),
not in fetch.

### 1.2 Shared pipeline helpers still called on B

| File | Why B still needs it |
|---|---|
| `g6lc_ex_id.sv` | I14: one CF issue port owns PC / BP / `flu_trans_id` |
| `g6lc_sb_keep.sv` | IRO `cmv_abi_ptr` / `exec_region_base`; scoreboard keep list is **A recover** (do not extend on B) |
| `g6lc_cf_pc.sv` | Per-instr CF PC before `branch_unit` |

### 1.3 g1\* recover packages — compiled, not fetch-B supply

**Now under `core/fetch_A/smt_legacy/`.** Still listed in `Flist.cva6` so A/`id_stage` /
the oracle frontend can call them; the move only stops them sitting beside live B RTL.
`fetch_B` `{frontend,instr_realign,instr_queue}` import **`g6lc_fetch_pkg` only**.

| File | What it papered over | B replacement |
|---|---|---|
| `g6lc_present.sv` / `g6lc_leftover.sv` | Mid-window / leftover FSM keyed on opcode and `pc[2:1]` | L1 `hw_off` / `leftover_complete` / `leftover_next` / `rvi_prefix` |
| `g6lc_fe_keep.sv` / `g6lc_fe_kill.sv` | Hold or spare a registered I$ line by CF class | L2 `window_accept`; kill inert on leftover |
| `g6lc_iq_hide.sv` / `g6lc_lj_hide.sv` | Drop/hide IQ entries by opcode | L3 oldest-PC + `packet_upto_cf` |
| `g6lc_sib_cjalr.sv` / `g6lc_rvc_enc.sv` mash | Synthesise `c.jalr` / mashed C | I1: bytes from I$; `G6LC_FETCH_B` skips mash and ID rewrite |
| `g6lc_jalr_usable.sv` on **resolve** | Suppress mispredict if target “looks unusable” | I11: resolve unfiltered; PMA only on **predict** (`bp_fire`) |
| `g6lc_cf_unissued.sv` | Extra `flush_unissued` on predicted-correct Jump/Return/JumpR | B `kill_s2` on `bp_fire` + `packet_upto_cf`; skip on B |

They compensated for a frontend that did not emit the instruction in memory (I1/I2/RC3).
Porting one into `fetch_B` is a regression — [`NEGATIVE.md`](NEGATIVE.md), [`LEDGER.md`](LEDGER.md) §2.

`id_stage` already skips sib_cjalr `decoded_hd`, G1gw/gy expand, and G1be/cy splice under
`G6LC_FETCH_B`. Shared-pipeline recover calls (mash, resolve `jalr_usable`, `cf_unissued`,
IRO G1gg, issue G1gq, scoreboard unusable-bmiss) skip under `G6LC_FETCH_B`; A unchanged.

Sibling **arm** also skips on B: `g1ik/ln/lz`, `g1hx/hy` latches, `g1lo_cap` / `g1lo_v_q`,
scoreboard `g1mf` / `sb_load00`, I$ `user[33:0]` sibling half (`g6lc_icache` G1iw/jl).
Rewrite was already off; capture still ran and is now A-only.

Shared-pipeline recover is **skipped on B** (`G6LC_FETCH_B`): mash, resolve
`jalr_usable`, `cf_unissued`, sib_cjalr rewrite **and** arm, I$ `user[]`,
`keep`/`keep_prefix` cancel, IRO value-inspect (I4by/G1k/G1h/G1gg), G1v/w/x
jal-link, G1t flush spare, leftover jal-x0 issue (G1dt/G1gh), G1fh sticky,
opcode/rd issue stalls, IRO store-ra/addi-sp. A unchanged.

**Still live on B (not recover):** SMT banks / `thread_select`; I13
`unresolved_cf` / `unresolved_csr` / `stall_csr_older`; I14 `g6lc_ex_id`;
IRO G1an (cancelled LOAD vs `raw_checker`) and G1ea (CSR never forwarded).
Do not extend the keep list. B STQ flush keeps `!cancelled` spec stores
(older frame `sd s2/s3`). Next: re-TRACE getprop `sw` / `ret@1826e`.

## 2. Not on the default flist — oracle frontend (4 files)

**Now under `core/fetch_A/smt_legacy/`.** Only via `-f Flist.smt_legacy` (drop `G6LC_FETCH_B` and `-f Flist.fetch_B`; leave predictors
in `core/frontend`):

- `frontend.sv`
- `instr_queue.sv`
- `instr_scan.sv`
- `instr_realign.sv`

Same module names as `fetch_B` / frozen A. Do not compile two frontends.

Formerly 23 files in one directory = 19 default + 4 oracle. After the split:
`core/smt_legacy/` 9 live, `core/fetch_A/smt_legacy/` 14 (10 recover + 4 oracle).

## 3. `thread_select` in one paragraph

`g6lc_hart_state` tags miss/block on the active hart and exports a ready vector that **ignores**
sticky miss. `cva6.sv` may mask unseen harts after boot-hart WFI and assert `hold_i`
(`smt_switch_hold`). `g6lc_thread_select` (smt2: `SMT_HYBRID`, Q=128, starve=64) then picks a
peer: miss-switch after 16-cycle activate blackout and 32-cycle stall age, else starve, else
quantum, else not-ready. `switch_o` is delayed one cycle so `active_hart_o` already names the
incoming hart when `g6lc_smt_pc_bank` restores. Controller flushes IF + unissued only.

## 4. What to edit

| Goal | Edit |
|---|---|
| R6–R11 / FDT / leftover present | `core/fetch_B/` (the only live supply) (`g6lc_fetch_pkg`, realign, queue, frontend). Frozen A untouched |
| SMT schedule / banks | `core/smt_legacy/g6lc_thread_select.sv` etc. (still there) + `cva6.sv` holds |
| g1\* recover | **Do not.** Oracle-only, now `core/fetch_A/smt_legacy/`. Skip remaining call sites with `G6LC_FETCH_B` |
