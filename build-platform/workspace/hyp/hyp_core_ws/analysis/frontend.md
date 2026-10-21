# frontend (+ g6lc_ftq, g6lc_fdip, instr_queue, instr_realign/scan, g6lc_bp_top, ras, g6lc_bp_ckpt) — analysis (T1, loop + latency)

<!-- hyp8-status -->
> **Status: indicative, subject to further information.** Goal: **8 FO4 per
> cycle (5 GHz nameplate at `fo4_ps = 20`, margin 0.2)**. Every FO4 figure,
> stage count and kernel size here is a hypothesis read from the original RTL,
> the prior boards and the sv-timing reports (`reports/board.md`,
> `cut_surface.md`, `bottlenecks.md`, `carry_over.md`, `propagation.md`,
> `refusals.md`); the fresh 8-FO4 board's deciding value `D` is in
> `analysis/cut-ledger.md` and `analysis/coverage.md`. The cut-minimization
> protocol (`analysis/cut_minimization.md`) takes precedence over any planned
> cut listed below. Nothing here has been linted, simulated or measured on a
> board; a rewritten file may follow this analysis, the emitted sv-timing file
> (as-is or adapted), or the original RTL, as `coverage.md` records.


Source of logic: `core/fetch_B/frontend.sv` (1575 lines). Board: 102.5 structural (reg→reg `npc_q → npc_d`) / 128.2 adjusted. Kill identities (contract §3): fetch redirect by 2-bit I$ token (`want_valid_q/want_token_q`), `kill_s1|kill_s2`, replay reseed (`replay_q` rewinds `seq_base`), `is_mispredict` qualified by `!misp_outranked`, `cf_hold_q` armed only on an actual push.

## 1. State and writers

| State | Writers |
|---|---|
| `npc_q` | `npc_select`: `arch_valid` (commit/trap/eret redirect: `arch_pc`, `arch_step`), `redirect_hold` (`redirect_pc_q`), `replay_q` (no FTQ), `if_ready → next_block(seq_base)`, `bp_fire → predict_address`, else `seq_base` |
| `seq_base` (comb) | `npc_q` or the replayed address |
| FTQ (`g6lc_ftq`) | push on `if_ready | arch_reseed` with `arch_pc | predict_address | fetch_address`; flush on `flush_i | is_mispredict | bp_fire | replay_q | smt_restore_flush`; pop on demand accept not killed, or loop-buffer inject |
| `cf_hold_q`, `want_valid_q/want_token_q`, `icache_valid_q`, response registers, `replay_q/replay_addr_q`, `redirect_pc_q/redirect_hold` | per their events |
| predictor state (`g6lc_bp_top`: BTB/BHT/TAGE/ITTAGE/loop/statcor/RAS, checkpoints `g6lc_bp_ckpt`) | update on resolve (`resolved_branch_i`), speculative RAS push/pop on predecode, checkpoint restore on mispredict |

Loop-carried: `npc_q → predictor lookup (on the *returned* block's predecode) → predict_address/bp_fire → npc_d`; `seq_base → next_block → npc_d`; `if_ready` depends on `ftq_full`, `instr_queue_ready`, `cf_hold_q`, `bp_fire`, `arch_reseed`, `replay_q`.

## 2. Execution paths

| Event | Chain | Reaches |
|---|---|---|
| each cycle (sequential fetch) | `seq_base` → `next_block` (VLEN add of the block size) → `npc_d`; `ftq_push`/`if_ready` | FTQ, I$ request (`icache_dreq_o`) via FTQ head |
| I$ response | token match → realign/predecode (`instr_realign`, `instr_scan`) → `g6lc_bp_top` lookup on the block's PCs (BTB/BHT/TAGE index, RAS) → taken-slot priority → `predict_address`, `bp_fire` → `npc_d`, FTQ flush/push; instructions → `instr_queue` | the prediction for block N arrives after N's response: a taken branch costs the I$ round trip |
| resolve (`resolved_branch_i`) | `is_mispredict & !misp_outranked` → kill, FTQ/FDIP flush, redirect; predictor/RAS/ckpt update | — |
| commit redirect (`arch_valid`: trap, eret, `pc_commit`, replay at commit) | `arch_pc` → `npc_d`, reseed | — |
| instruction-queue replay (`replay_q`) | reseed, `seq_base` rewind | — |

The 128 adjusted FO4 is the predecode → predictor → taken-slot priority → `predict_address` → `npc_select` → FTQ push address chain in one cycle (the response-side loop), plus `next_block` on the sequential side.

## 3. Callers and callees

| Port | Reader | Kind | Kill | Tolerance |
|---|---|---|---|---|
| `icache_dreq_o` (vaddr, req, kill_s1/s2, token) | `g6lc_icache` | flop (request registered in the I$) | token | the I$ already answers by token; +N request latency = +N fetch latency, no protocol change |
| `fetch_entry_o/valid` → `fetch_entry_ready_i` | `instr_queue` → `id_stage` | valid/ready | `flush_i` | elastic by construction |
| `resolved_branch_i`, `pc_commit_i`, `set_pc_commit_i`, `flush_i`, `halt_frontend_i`, trap/eret vectors | from `controller`/`commit_stage`/`ex_stage` | inputs | — | a redirect arriving later = larger penalty, no correctness issue as long as `misp_outranked` ordering keeps (arch redirect beats a younger mispredict) |
| `g6lc_fdip` prefetch | I$ | req/token | — | — |
| RVFI/perf (bp events) | — | — | — | — |

## 4. Functional separation

| Block | In | Out | State | Kernel / stage | Cost |
|---|---|---|---|---|---|
| `g6lc_fe_nextline` | `npc_q` (block address), line-predictor array (untagged, indexed by block address bits, entry = next block address + "taken" bit), redirect inputs (registered) | `npc_d`, `ftq_push_vaddr` | `npc_q`, line table (e.g. 256 entries × VLEN) | **kernel**: table read (registered array output arrives with `npc_q` — the read for block N+1 is launched with N's index, i.e. the table is read one cycle ahead and the kernel is `npc = redirect ? redirect_pc : (line_taken ? line_target : next_block(npc_q))`: one 3:1 mux + the block incrementer on the low bits ≈ 4 FO4) | ≤ 6 FO4 |
| `g6lc_fe_btb_check` (stage F2, one cycle later) | the pushed block address, BTB/RAS lookup (tagged) | override #1: if the tagged BTB disagrees with the line guess → `override_pc`, epoch++ , kill the one younger push | BTB (as today), RAS top | stage | 8 FO4 (tag compare + select) |
| `g6lc_fe_override` (stage F4+, on the response) | predecoded block + TAGE/ITTAGE/loop/statcor verdicts (today's `g6lc_bp_top`) | override #2: `predict_address`/`bp_fire` as today but now compared against what was *already fetched* for the following blocks; squash by **epoch** (all FTQ entries, in-flight tokens and instruction-queue entries younger than the overriding block) | predictor tables | 2 stages: lookup (registered index from the block PCs), then taken-slot priority + target select | 8 FO4 each |
| `g6lc_fe_response` | I$ response, token | realign/predecode (2 stages: `instr_realign` boundary + `instr_scan` class/immediates) → `instr_queue` push | response regs | stages | 8 FO4 |
| `g6lc_fe_redirect` | `arch_valid/arch_pc`, mispredict, replay, `redirect_hold` | one registered redirect record (priority: arch > mispredict > replay, as today) consumed by the kernel next cycle | redirect reg | stage | 5 FO4 |
| `g6lc_ftq` | push/pop/flush + epoch per entry | head to the I$ | queue | stage (epoch compare on pop) | 4 FO4 |
| `instr_queue` (elastic) | pushes with epoch; `fetch_entry_ready_i` | per-lane slots; prefix-fire split into two steps | FIFO | stage | 8 FO4 |

Why the loop shrinks: the single-cycle recurrence becomes "block address → next block address" through an untagged table whose read is overlapped with the previous cycle (index = `npc_d` of the previous cycle is `npc_q`, so the table read happens during the cycle and arrives at the mux — if the array read itself exceeds the budget, use a 2-entry-wide table read ahead by two blocks). Every tagged/accurate structure becomes an override with an epoch kill.

## 5. Latency and throughput target

- 1 block/cycle while the line guess is right (today: a taken branch costs the I$ round trip because `bp_fire` comes from the response). Override #1 (BTB disagrees) costs 1 bubble; override #2 (TAGE etc.) costs the response latency (as today's taken-branch cost) **only when it disagrees with the line/BTB guess**.
- Mispredict (resolve) penalty: as today + the deeper pipeline (+2 from execute, +2 from rename, +2 from decode/realign) — recorded as a cost; recovery semantics unchanged (`misp_outranked`, token kill, reseed).
- Cost: line table (~256 × (VLEN−block bits + 1)), epoch bits on FTQ/IQ/tokens (3–4 bits), the extra response stages.

## 6. Decision

Files (new): `core/fetch_B/frontend.sv` (ports unchanged; internals = the blocks above), `core/frontend/g6lc_fe_nextline.sv`, `g6lc_fe_btb_check.sv`, `g6lc_fe_override.sv`, `g6lc_fe_redirect.sv`; `core/frontend/g6lc_ftq.sv` (epoch per entry), `core/fetch_B/instr_queue.sv` (elastic, epoch), `instr_realign.sv` + `instr_scan.sv` (two stages), `g6lc_fdip.sv` (epoch-aware flush), `g6lc_bp_top.sv` wrapper (lookup stage split), `ras.sv` (speculative push/pop keyed by epoch with checkpoint restore), `g6lc_bp_ckpt.sv` (restore keyed by epoch). `HypCfg`: `FeNextlineUntagged`, `FeNextlineEntries`, `FeOverridePred`, `FeEpochBits`.

Kill identities: `flush_i` (all), `is_mispredict & !misp_outranked` (epoch++, FTQ/FDIP/IQ younger entries, in-flight tokens by token match as today), `replay_q` (reseed as today), override #1/#2 (epoch++ for the younger stream only — an override is *not* a mispredict: predictor tables are not trained by it, RAS speculative state is rolled to the overriding block's checkpoint).

Expected `// hyp8:` departures: (1) `bp_fire`/`predict_address` no longer drive `npc_d` directly; they drive the override record; (2) `cf_hold_q` becomes "hold until the redirected block's push is registered" on the redirect record (same purpose); (3) FTQ entries carry an epoch; (4) the response path is 2 cycles longer.
