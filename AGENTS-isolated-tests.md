# GSys LibreCore — Isolated Root-Cause Tests for SoC/Boot Bugs

> Companion to `AGENTS.md` (prime directive) and `agents/guides/AGENTS-verilator-performance.md`.
> This guide is the standing workflow for turning a *symptom* seen in a long SoC
> boot (e.g. the 4-core `g6lc64_hyp8_mc` OpenWrt witness) into an **isolated,
> mutation-checked leaf test** that pins the exact RTL root cause — so the fix is
> proven in seconds, not re-discovered by another multi-hour witness.

Tier: **T** (tooling/docs, MIT). No RTL licence header.

---

## 0. Why isolated tests (the failure this prevents)

A full-model OpenWrt witness takes **hours to days** per datapoint and its log is
a *symptom* stream, not a cause. The recurring anti-pattern this guide exists to
kill:

- Judging "progress" by cycle count alone (the rfix131a log records a witness
  declared "past the wedge" that had actually frozen at `retired=6333` — the
  secondary harts were still committing, so the per-core `+hang_dump` watchdog
  stayed silent).
- Fixing the *boundary* symptom (an XBAR `ar_ready=0`, a full MSHR, a held B)
  without decoding *which* upstream unit produced it.
- Re-running the whole witness to check a one-line RTL change.

The correct loop is **witness → decode the stall dump → isolate the unit →
leaf-test the mechanism → fix → re-run only the discriminating tests →
witness once to confirm the frontier moved.**

---

## 1. The four test layers (cheapest → most expensive)

| Layer | Where | What it proves | Cost |
|---|---|---|---|
| **Unit leaf TB** | `verif/tb/<area>/tb_g6lc_*.sv` + `verif/regress/remote/hyp8/run_*_leaf.sh` | the exact unit FSM/arbiter/datapath under a crafted stimulus | seconds (host Verilator `--binary`) |
| **Remote leaf runner** | `verif/regress/remote/run_*_leaf.py` | same unit on the pinned remote toolchain/closure | ~min |
| **Directed assembly** | `verif/tests/custom/hyp8_*.S` + `run_hyp8_mc_directed.py` | the mechanism end-to-end across real cores/L1/L2/coherence | minutes–hours |
| **Firmware witness** | `run_hyp8_witness.py` + `witness_*.sh` | the actual OpenWrt boot milestone | hours–days |

A root cause is *done* only when it has a **leaf test that fails on the bug and
passes on the fix**, plus a directed/witness re-run showing the frontier moved.

---

## 2. Diagnostic plusargs (the decode surface)

All are allow-listed in `verif/regress/remote/hyp8/hyp8_tb.cpp`
(`verilog_plusargs[]`); an unlisted `+arg` is rejected by HTIF and kills the run.
Windowed probes share `+trace_from=<cyc>` / `+trace_to=<cyc>`.

**Stall dumps — `+smt_stats`** (the single most valuable flag; enables the whole
family, each bounded/age-triggered so it never floods):

- `[coh-stall]` — coherence hub per-slot `aw/ar` dumps: `core oid xr bdone bh
  rh rl line owed invw invs` plus per-core `inv[] v rdy line ways pendv
  pendline enq deq`. Decode: `bdone=0`→B never returned; `bdone=1 bh=1
  owed/invw≠0`→B withheld pending invalidation; `invs<INV_APPLY_LATENCY`→settle.
- `[l2-stall]` — L2 fill/tracker/FSM state (`st`, `mar/marr/mrv/mrr`, MSHR).
- `[l1/dcache-stall]`, `[xbar-ar-stall]` (`full/selocc/ar_ready`), `[dcache-stall]`.
- `g6lc_core.sv gen_smt_stats` — SMT selector / scoreboard / WT-dcache /
  HPD-replay drained-handoff observers.

**Core-side windowed probes** (`+trace_from/to` bounds):

- `+hang_dump=N` — `[hang]` block after N cycles without a commit-ack: SB head,
  SBX slots, IQ entries, `LSQ st[]/ld[]` (`addr_v data_v done addr`), `st_unresolved`,
  `st_live`, LU/LSU/D$/I$ one-line state.
- `+lsq_trace` — `[lsq]` load-entry `unres/dwait/rel`, `st_resolved`,
  `st_data_res`, `ld_alloc`, `complete/ev_complete`.
- `+ld_state` — `[ldst]` load-FSM gate-term trace (state, ldbuf_full, data_req,
  gnt, rvalid, treq, dtlb, wpo, pav, va, pa).
- `+tlb_trace` — `[tlb]` update/flush/lookup.
- `+smt_mem_watch=<pa>` — watches one physical line through dcache_mem /
  missunit / wbuffer (`+smt_flow_trace` for the unfiltered stream).
- `+smt_cyc_progress=N`, `+smt_progress`, `+stall_census`, `+equiv_report`,
  `+seq_gap_trace`, `+seq_gap_limit`.

> **Buffering caveat:** stdout is block-buffered to `run-hyp8.log`; only
> `std::cerr` probes (e.g. the early `[rob]` ROB_RETIRE_TID window,
> `main_time 1450–1560`) appear immediately. With no periodic probe enabled the
> log stays flat until the window — that is normal, not a hang. `%CPU`≈190–200
> confirms the sim is advancing.

---

## 3. `mc_verdict` exit codes (how a wedge is *named*)

`g6lc_testharness.sv` folds per-core retirement into the exit code
(`exit_o>>1`):

- **125** — core(s) still clock-held at end.
- **126** — *a core ran and then stopped retiring* (`mc_any_hung`):
  `core_retired && !mc_last_wfi && mc_gap_cur ≥ MC_GAP_LIMIT(5000)`.
  `mc_last_wfi` is set from the last retired insn == `WFI(0x10500073)`, so a
  parked hart is exempt. **Note `mc_gap_max` prints only *completed* gaps** —
  a core frozen mid-gap shows small `max` yet still trips 126. Trust 126.
- **127** — a core retired nothing / `+mc_verdict_fault` control.
- **0 / program code** — `tracer_exit[31:1]` (tohost).

A `wedged` directed-test state = `+max-cycles` reached with no tohost verdict —
*never* a pass (`run_hyp8_mc_directed.py`).

---

## 4. The leaf-test contract (rfix131a pattern)

Model: `verif/tb/core/tb_g6lc_thread_select_t0.sv` +
`verif/regress/remote/hyp8/run_tsel_t0_leaf.sh`.

A leaf test has **three runs**, all required:

1. **positive** — `verilator --binary --timing --assert` on
   `config_pkg + build_config_pkg + <unit>.sv + tb_*.sv`; TB drives a crafted
   stimulus and must print `PASS tb_<name>`.
2. **`+oracle_negative`** — same TB with a plusarg that raises the pass floor;
   must emit the *named* `$fatal` tag (e.g. `TSEL_T0_S1_PEER_STARVED`). Proves
   the check isn't vacuous.
3. **mutation** — rebuild with `-DG6LC_MUT_<NAME>` which reverts the fix in the
   unit; must *fail* with the named tag (e.g. `G6LC_MUT_SMT_T0_DEFER_UNBOUNDED`
   → `switches=0`). Proves the test actually covers the bug.

TB conventions: instantiate the DUT with `build_config_pkg::build_config`,
drive `clk/rst_n`, synthesize the *real* trigger condition as a periodic
`always @(posedge clk)` pattern (e.g. "`li t0` issues N cycles before each
fetch_fire"), accumulate invariant counters, `$fatal(1,"<TAG> ...")` on
violation, `$display("PASS ...")` + `$finish` on success. Mutations live behind
`ifdef` in the unit, defaulting to fixed behaviour.

Remote leaf runners (`run_ctrl_leaf.py`, `run_lsq_leaf.py`, `run_rob_leaf.py`,
`run_sbcommit_leaf.py`, `run_idstage_leaf.py`, `run_iq*_leaf.sh`) push the same
TB to the pinned remote closure.

---

## 5. Directed assembly tests (`verif/tests/custom/`)

`hyp8_*.S` are linked RISC-V programs run on the *whole* mc model by
`run_hyp8_mc_directed.py` — they exercise the mechanism across real cores, L1,
L2 and coherence (e.g. `mc_smt2_boot_release`, `mc_shared_line_resident`,
`mc_store_load_new_line`, `mc_l3_stride_scan`, `zacas_amocas_d`,
`mc_cas_lock_handoff`, `mc_l2_write_read`). A new root cause gets a directed
test that reproduces its *access pattern* (same-line store→load ordering,
multi-core invalidation, AMO/LR-SC sequences) so it fails fast and determin-
istically instead of waiting for the boot to reach it.

`hyp8_fixval_gate.py` chains these on a model-ready tag, then runs the tracedb
ingest (below) and writes a gate record.

---

## 6. tracedb diagnostics + ingest

`/opt/testharness/tracedb/ingest.py --db /opt/testharness/tracedb/hyp8-trace.sqlite`
(+ `autoingest.sh`) ingests finished/in-flight run logs into a queryable SQLite
DB. `ingest.py` discovers runs by `results.json` / `<test>.elf`; it classifies
events into `pass / fail / wedged / stopped / killed(wall) / no-verdict` and a
`stall` class keyed on `[l2-stall]/[coh-stall]/[xbar-*-stall]/[dcache-stall]`.

Workflow: run the cohort → `ingest.py <tags>` → query `thread`/`progress.cycprog`
for per-hart `retired`/`last_pc` freeze points and the `stall` rows for the
named blocker → *then* write the leaf test. The DB is the index; the witness log
is the evidence.

---

## 7. hyp8 OpenWrt-witness specifics

- **Model**: `hyp8-fast-gcc13-t2/output/model/Variane_testharness` — Lua
  `hyp8_mc_fast.lua` + `--no-assert` + GCC 13.3 + PGO (~1,385 cyc/s class, ~64 MB).
- **Payload**: `localmc-stage/output/fw_payload.elf` — OpenSBI@`0x80000000` +
  strict supervisor + Linux `payload.bin`@`0x80200000` + `g6lc-hyp8-mc-linux.dtb`
  (OpenWrt v24.10.2). Identity is sha256-checked, never assumed
  (`HYP8_FW_SHA256`, `results.json` `modelSha256` gate in `run_hyp8_witness.py`).
- **Launch**: `witness_*.sh` exports `TH_OUT_DIR`, `HYP8_INT_TAG`,
  `HYP8_FW_SHA256`, `HYP8_TOHOST`, `HYP8_MAX_CYCLES`, `HYP8_PLUSARGS` then runs
  `run_hyp8_witness.py` → `subprocess.Popen(..., start_new_session=True)`
  (detached; survives the proxy session). Record lands in `output/witness.json`.
- **`+tohost_addr`** is the ELF's tohost; `+max-cycles`/`+time_out` the budget.
- **last_pc decode**: `0x8000xxxx`=OpenSBI, `0x8001xxxx`=libfdt,
  `0x8002-4xxxx`=sbi_init/HSM, `0x802xxxxx`=payload phys, `0xffffffff8..`=MMU on.
  Secondary harts park in `_wait_for_boot_hart`/`sbi_hsm_hart_start`.
- **Known-good milestone oracle** = scalar `r127m`: ~20M first UART, ~23M Linux
  banner, ~1.32G console, ~1.54G shell. mc is compared against it.
- **Clock-skip**: the fast build's PGO verilator lacks `-fclock-skip-sink`
  (driver warns + skips), so sleep phases get no extra speedup — budget wall
  time accordingly (~days for a full boot).

### Prior root causes fixed with this loop (rfix131a)

- **RC1**: `g6lc_axi_lrsc` R-counter underflow (both-trees fix + leaf TB + directed).
- **RC2**: `g6lc_thread_select` I4bg deferral starving the boot hart (`tb_g6lc_thread_select_t0.sv` + `run_tsel_t0_leaf.sh`).
- **RC3**: `wt_dcache_missunit` `cas_amo_sel` spurious miss-port ack → `MISS_WAIT`.
- **RC4**: `g6lc_zicclsm` OoO TID-swallow (OpenWrt `printc` wedge @cyc=14,505,435, core0 hart0 `pc=0x8000a014` `ld s2,32(sp)`, `mc_verdict` 126): when a younger word-wrapping load/store entered `B0_ACTIVE`/`B0_WAIT`/`B1_ACTIVE`/`B1_WAIT` (or emitted via `hold_v_q`), `g6lc_zicclsm` unconditionally cleared `ld_valid_o`/`st_valid_o` and triggered its FSM without checking `ld_tid_fu_i == orig_q.trans_id` / `st_tid_fu_i == orig_q.trans_id`, silently dropping older in-flight `load_unit` `ldbuf` completions (`tid=51` @`0x00ff` ate `tid=48` @`0x80053e20`). Fixed in both RTL trees (`core/g6lc_zicclsm.sv` + hyp mirror) with 3-gate leaf (`tb_g6lc_zicclsm_hyp8.sv` / `run_zicclsm_leaf.sh`, `G6LC_MUT_ZICCLSM_TID_SWALLOW`) and 5-second full-core directed repro (`mc_zicclsm_ooo_overlap.S`).
- **RC5**: `store_buffer` multi-beat Zicclsm store commit (`stb_insert.sv`, `stb_commit.sv`, `store_buffer.sv`, and main `core/store_buffer.sv`): two-beat word-wrapping stores push `beat0` and `beat1` with the same `trans_id`, while `commit_stage` pulses `commit_i` once; `stb_insert` ordered `beat1` older than `beat0` (tripping `spec_order_matches_anchor`), and `stb_commit` popped only 1 beat, dropping half the store and stranding the other beat (deadlocking `MixCommit` on the next store via `head_mismatch_o`). Fixed in both trees with equal-TID age ordering (`beat0` older than `beat1`) + atomic two-beat pop into architectural `pend2` + S1 same-TID commit guard; 3-gate leaf (`tb_g6lc_stq_zicclsm_hyp8.sv` / `run_stq_zicclsm_leaf.sh`, `G6LC_MUT_STQ_ZICCLSM_SINGLE_BEAT`) + `run-stq-commit-flush.sh` green.
- **RC6**: `g6lc_zicclsm` + `load_unit` `ld_checked` circular deadlock (`g6lc_zicclsm.sv`, `load_store_unit.sv` in both trees): a younger wrapping load issued OoO ahead of an older unresolved store (`ld_checked_i == 0`) entered `B0_ACTIVE -> B0_WAIT` and pinned `lsu_bypass` head while `load_unit` refused to publish `beat0` until `ld_checked_i == 1`, blocking the older store behind it in `lsu_bypass`/IQ (`lsu_ready=0`, reproduced by both `mc_zicclsm_ooo_overlap.S` and `hyp8_zicclsm.S`); additionally, `load_unit.lu_replay_o` firing in `B0_ACTIVE`/`B1_ACTIVE` left `g6lc_zicclsm` stuck in `B0_WAIT`/`B1_WAIT`. Fixed by replaying unchecked wrapping loads immediately in `IDLE` (`ld_replay_o` + `pop_ld_byp_o`) and aborting splits back to `IDLE` on `lu_replay_fu_i`; verified by `run_zicclsm_leaf.sh` (`G6LC_MUT_ZICCLSM_UNCHECKED_SPLIT`) + `run-zimop-ntl.sh`.

---

## 8. Checklist for a new root cause

1. **Name the symptom** — which core/hart, `last_pc`, `mc_verdict` code, first
   frozen `cycprog` cycle.
2. **Decode the dump** — `[hang]`/`[lsq]`/`[ldst]` for the core side;
   `[coh-stall]`/`[l2-stall]`/`[xbar]`/`[dcache-stall]` for the fabric. Identify
   the *producer* of the missing response, not the consumer that stalled.
3. **Isolate** — write `tb_g6lc_<unit>_<aspect>.sv` driving the exact handshake
   sequence; prove it wedges/violates on the current RTL.
4. **Fix both trees** — `build-platform/workspace/hyp/hyp_redesign_core_8fo4/`
   **and** the main `core/`/`corev_apu/` mirror (the built closure is the hyp
   workspace; keep them in lockstep).
5. **Leaf gate** — `run_<name>_leaf.sh`: positive PASS + `+oracle_negative`
   fires + `G6LC_MUT_*` caught.
6. **Directed** — add/extend a `verif/tests/custom/hyp8_*.S` reproducing the
   access pattern; run via `run_hyp8_mc_directed.py`.
7. **Witness** — rebuild the model (`build_closure.py --mc` /
   `hyp8-build-harness.sh`), write `results.json`, relaunch the witness with the
   same `HYP8_FW_SHA256`; confirm `retired`/`last_pc` pass the old freeze point.
8. **Ingest** — `ingest.py` the tag so the DB records the new frontier.

Do **not** declare victory on cycle count; require the named milestone (UART
bytes, `last_pc` region advance, `mc_verdict` exit) to move.
