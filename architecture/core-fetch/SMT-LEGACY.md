# `core/smt_legacy/` — what default B still compiles, and why recover is not fetch

Companion to [`README.md`](README.md), [`SPEC.md`](SPEC.md) §8, [`LEDGER.md`](LEDGER.md) §2,
[`NEGATIVE.md`](NEGATIVE.md), [`../firmware-boot-principles.md`](../firmware-boot-principles.md).

`smt_legacy` is **three things in one directory**. Default `Flist.cva6` compiles 19 of 23 files.
The other four are the g1\* frontend copies and are opt-in only (`Flist.smt_legacy`).
`fetch_B` never instantiates that frontend and must not compile it (two `module frontend`).

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

Listed in `Flist.cva6` so A/`id_stage` / the oracle frontend can call them.
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
Do not extend `g6lc_sb_keep::keep` on B.

## 2. Not on the default flist — oracle frontend (4 files)

Only via `-f Flist.smt_legacy` (drop `G6LC_FETCH_B` and `-f Flist.fetch_B`; leave predictors
in `core/frontend`):

- `frontend.sv`
- `instr_queue.sv`
- `instr_scan.sv`
- `instr_realign.sv`

Same module names as `fetch_B` / frozen A. Do not compile two frontends.

23 files in the directory = 19 default + 4 oracle.

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
| R6–R11 / FDT / leftover present | `core/fetch_B/` (`g6lc_fetch_pkg`, realign, queue, frontend). Frozen A untouched |
| SMT schedule / banks | `core/smt_legacy/g6lc_thread_select.sv` etc. + `cva6.sv` holds |
| g1\* recover | **Do not.** Oracle-only. Skip remaining call sites with `G6LC_FETCH_B` |
