# Instruction supply plane (`core/fetch/`)

**Two phases.** Handoff first: this tree is B against the g1\* frontend. **After** that frontend is
retired to **`smt_legacy`**, **this tree is A**. New capabilities are A/B on fetch with the **same
peels and hold-soak** as soft-ladder (P1 mini → P2 one class → P3 OpenSBI → P4 retire soft).

Normative why: [`../firmware-boot-principles.md`](../firmware-boot-principles.md).

| File | Role |
|---|---|
| [`SPEC.md`](SPEC.md) | Geometry, four layers, A→B migration, flist swap |
| [`VALUES.md`](VALUES.md) | Value reference table (present/keep/kill/rewrite → B combos) + `fetch_geo_t` / `fetch_en_t` / sim debug |
| [`LEDGER.md`](LEDGER.md) | Every kept increment: subsumed into a B combo, or frozen in `smt_legacy` |
| [`NEGATIVE.md`](NEGATIVE.md) | **Read first.** Mechanisms that failed; do not port into B |

## The rule

> The decode of an instruction is a function of its bytes and its address alone.

`SPEC.md` `A_decode_pure` / `A_no_fabricate`. L2/L3 may **drop**, never modify. Only L1 produces bytes.

## Handoff sizes (g1\* vs fetch)

| | g1\* `core/frontend` + recover | `core/fetch` (handoff B → later A) |
|--|--|--|
| Lines | ~10236 | **3832** (37%) |
| `frontend.sv` | 4082 | **905** |
| `g1*` in frontend | 1065 | 0 |
| Predictors | identical | identical |

## Layout after retirement (default = former fetch B)

| Path | Role |
|---|---|
| `core/frontend/` + `core/instr_realign.sv` | Default supply (**A**): copies of the retired fetch tree |
| `core/smt/` | That fetch tree (`g6lc_fetch_pkg`/`dbg` + supply copies). Not dual-compiled with `core/frontend` |
| `core/smt_legacy/` | g1\* oracle frontend + recover packages + SMT banks |
| `core/fetch_B/` | **After** the retirement commit: dev copy of `core/smt` for R6–R11 |

Default `Flist.cva6`: `+define+G6LC_FETCH_B`, pkg/dbg from `core/smt/`, frontend files in
`core/frontend`. Oracle: drop the define and pkg/dbg, comment B frontend/realign/scan/queue,
`-f Flist.smt_legacy`. Do not compile both frontends.

## Status

| Step | State |
|------|--------|
| Drop-in B (same module names, no g1 ports) | **landed** (`work-ver-smt2-fetchb`) |
| `_fw_start` 0x2a…0x5e identical to A | **yes** |
| OpenSBI `mtvec=_trap_handler` | **yes** |
| Hold cookie | **yes** fetchb `ec1239ef` `[1000]=51b1babe` cave WFI `@0xef98` `plat_hc=2` BANR |
| Peel cookie | **yes** `[1000]=51b1babe` `[1008]=51b1d000` |
| Nat (pin `bc7ed11d`) | **not yet** — R5/I2 ok; `13884`/`12544` commit (`a0=0x82200000`→probe `0xaf5`); FDT walk continues, no `ret@1826e`. No leftover-keep / I17 / PMA |
| Split B into `g6lc_fetch_{align,window,order,redirect}` | after that pin; bit-identical extract |
| g1\* frontend → `smt_legacy` | **retired**: `core/smt_legacy/` (oracle + recover + banks); fetch tree is `core/smt/`; copies applied to `core/frontend` |
| Capability A/B (peels + soak on fetch) | **after** that retirement; see principles §0.2 |
| `g6lc_fetch_pkg.sv` + `g6lc_fetch_dbg.sv` | **landed** (kill + leftover + L2 `window_accept`; snap for n-wide/SMT/spec; `+fetch_snap`) |
| `instr_realign` leftover | **landed** (`leftover_complete` / `leftover_next` / `rvi_prefix`; `start_hw0=1`) |
| L2 redirect window | **landed** (`redirect_hit` / `redirect_accept` = `window_accept` + `same_win`) |
| I4 per-hart leftover | **landed** (`instr_realign` carry banks `[hart_i]`; kill inert) |
| I8 restore vs trap | **landed** (`arch_src_sel` + `fetch_address = arch_pc`; no restore-first I$ mux) |
| I7 all-or-nothing IQ | **landed** (`packet_accept`; no partial enqueue) |
| I19 predict-only PMA | **landed** (`bp_fire = bp_valid && predict_fetchable`; never on resolve) |
| I3 leftover pending | **landed** (`leftover_pending_o` / snap; drop on valid non-next) |
| `+fetch_snap_lo/hi` | **landed** (allowlisted in `g6lc_tb.cpp`; snap prints `rpc`/`tgt`) |
| L1 `hw_off` | **landed** (realign cursor start from pkg) |
| I14 EX identity | **landed** (`g6lc_ex_id`; IRO/EX pick PC+bp+fu_data from the CF port; no G1p/G1r/G1u; scoreboard keep list not extended) |
| Slot snap / I1 SVA | **landed** (`[fetch_slot]` pc/hw/cf/ilen; bytes-vs-I$ ; n-wide `geo.slots`; no frontend combo) |
| I1 ID identity | **landed** (`G6LC_FETCH_B`: no G1gw/gy JALR expand, no sib_cjalr `decoded_hd`; A keeps recover) |
| I6 ID splice | **landed** (`G6LC_FETCH_B`: no G1be/cy/em/ev insert-older-at-port-0) |
| I3 leftover keep | **reverted** (`plat_hc=80` `coldboot_done=0` `mepc=0x12584` mcause=2 — I4az class) |
| `and`@`8cae` leftover | **holds** (commits; tickets match). Hang is hart0 ticket wait + hart1 `8df0`/`4` |
| leftover_drop snap | **landed** (`leftover_drop` + `h=` in `[fetch_snap]`; no frontend combo) |
| L3 `packet_hart` | **landed** (IQ stamp; B decode from `fetch_entry.hart_id`; one `.hart_i` line) |
| I10 B no t0 rewind | **landed** (`G6LC_FETCH_B`: `npc_alt` tied off; A keeps I4bl) |
| I8 `commit_for_hart` | **landed** (PC_COMMIT only if commit hart == active; one `commit_hart_i`) |
| R5 jalr always `JumpR` | **reverted** (`sp1=0` `mepc1=0x348` mcause=2 — JumpR with target 0) |
| Kill-inert leftover | **landed** (`leftover_update`: `kill_s2` does not consume carry) |
| Spec leftover hold | **reverted** (`plat_hc=80` `coldboot_done=0` `npc0=0x10050` `mtvec=0x10040` — I4az / I3 keep: `spec_req` is high on sequential fetch) |
| Flush-inert leftover | **landed** (`leftover_update` ignores `flush_i`; hang **unchanged** `768`/`47f48`) |
| I10 snap in-flight | **landed** (`snap_pc`; hold **cookie** `51b1babe`; peel `51b1babe`+`51b1d000`) |
| I13 same-cycle CSR | **landed** (`stall_csr_older` in `g6lc_issue_barrier`; fetchb `856d8292`; hold **cookie**; nat tselect handler now `mret`s; still no `ret@cd22`) |
| L3 `packet_upto_cf` / L4 `redirect_rehold` | **landed** fetchb `63fa23a9` (IQ + one frontend assign). Hold **cookie**. Dbg: `window_expected`/`wr=`/`age=`/`hm=` (n-wide/spec observe; live not an IQ drop) |
| `Flist.smt_legacy` | **landed** (opt-in A oracle; do not compile with `Flist.fetch`) |

Until `smt_legacy` exists, do not start stream I=2 / n-wide / `RVH` as fetch-A experiments. Envelope
tweaks then go through `fetch_geo_t` / `fetch_en_t`. `NrCores`, RVV, Ara, L2 do not add fetch ports.
