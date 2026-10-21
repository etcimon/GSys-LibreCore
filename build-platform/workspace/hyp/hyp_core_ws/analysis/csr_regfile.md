# csr_regfile — analysis (T1, latency class)

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


Source of logic: `core/csr_regfile.sv` (3684 lines; svt-plan lines 239–262: "address/privilege translation → CSR read select → read-modify-write and architectural outputs"). Board: 105.5 structural (reg→reg) / 87.0 adjusted (A128). 427 failing paths — the widest module by count. CSR ops issue only at the commit head (contract §4) and are executed/acked at commit through `csr_buffer` (two-entry per-tid address table under OoO).

## 1. State and writers

All architectural CSRs (m/s/h/u, PMP cfg/addr, counters, fflags/frm, debug), `priv_lvl_q`, trap/interrupt state, `satp`, `pmpcfg_o/pmpaddr_o` outputs, `csr_rdata_o`, trap vector / epc outputs to the frontend, `irq_ctrl_o`, `fence`/`flush` requests to the controller, `dcsr/halt` for debug. Writers: the commit-ack'd CSR op (`csr_op_i`, `csr_addr_i`, `csr_wdata_i`), trap entry (`ex_i` at commit), xRET, interrupt pending (`irq_i`, `ipi_i`, timer), counters increment every cycle (`instret`, `cycle`), debug requests, PMU events.

## 2. Execution paths

| Event | Chain | Reaches |
|---|---|---|
| CSR op at commit (`csr_en`) | 12-bit address decode (+ privilege/virtualization legality) → read mux over ~150 CSRs → RMW (`set/clear/write`) → write decode → next state; `csr_rdata_o` to commit (substituted into `wdata` → PRF mirror) | `commit_stage` same cycle (decides flush/`csr_exception`) |
| trap at commit (`ex_i.valid`) | cause/priority → `mcause/mepc/mtval/mstatus` updates; `trap_vector_base_o` → frontend | frontend redirect (via commit/controller) |
| xRET | `mstatus` restore, `priv_lvl`, `epc_o` | frontend |
| interrupt arrival | `mip` → pending/enable mask → `irq_ctrl_o` → commit (interrupt injection) | commit the same cycle |
| every cycle | counters + PMU | — |
| PMP | `pmpcfg_o/pmpaddr_o` (registered state, exported) → MMU/PMP checks | comb from regs |

## 3. Callers

| Port | Reader | Kind | Adaptation |
|---|---|---|---|
| `csr_rdata_o`, `csr_exception_o` | `commit_stage` (same cycle as the op) | comb | with the commit bundle, the CSR op is *presented* at t (bundle), read/legality produced at t+1, RMW/write and ack at t+2; the commit bundle holds the CSR op two cycles (CSR ops serialize at the head, so no throughput cost) |
| `trap_vector_base_o`, `epc_o`, `eret_o`, `set_debug_pc_o` | frontend/controller | flop capture | +1 with the bundle; the frontend redirect record takes them |
| `irq_ctrl_o` | commit (interrupt injection decision) | comb | registered: an interrupt is injected one cycle later — allowed (interrupts are asynchronous) |
| `pmpcfg_o/pmpaddr_o`, `satp_ppn_o`, `priv_lvl_o`, `*_en_o` (translation enables), `fs_o/vs_o`, `frm_o`, `tvm/tw/tsr`, `debug_mode_o` | MMU, PMP checks, decoder/issue legality, FPU, ex_stage | comb from regs | unchanged (registered state); the *write* lands one cycle later than today → the controller's flush after a CSR side effect (already a full flush) must wait for the write: the bundle's "side effects next cycle" rule covers it (flush requested at t+2) |
| `perf_*`, RVFI CSR taps | — | — | re-anchored |

## 4. Functional separation

| Block | Kernel / stage | Cost |
|---|---|---|
| `csr_decode` (C1): address → class (one-hot of ~12 banks: machine-trap, machine-info, supervisor, hypervisor, PMP, counters, FP, debug, custom), legality (priv, virt, `tvm/tw/tsr`, read-only), registered | stage: 12-bit compare tree ≈ 5 FO4 | ≤ 8 FO4 |
| `csr_read` (C2): per-bank local read mux (≤ 16:1 per bank) ∥, then bank select 12:1 → `rdata` registered; RMW operand prepared | stage (bank mux 4 FO4 + select 3 FO4) | ≤ 8 FO4 |
| `csr_write` (C3): RMW (`set/clear`: AND/OR, 1 FO4) + write decode (bank one-hot from C1) → register writes; side-effect requests (flush, fence, satp change) registered to the controller | stage | 6 FO4 |
| `csr_trap` : cause priority (trap vs interrupt vs debug), `mepc/mcause/mtval/mstatus` update, `priv_lvl` next; trap vector select — operates on the commit bundle's exception record (t+1) | stage (priority encode 5 FO4 + mux) | ≤ 8 FO4 |
| `csr_irq` : `mip/mie/mideleg` → pending → `irq_ctrl_o` registered | stage | 5 FO4 |
| `csr_counters` : `cycle/instret/hpm` increments (64-bit incrementers split low/high with registered carry) | stage | 6 FO4 |
| `csr_pmp` : config/addr registers and the exported view | registered (as today) | — |

## 5. Latency and throughput target

- CSR op: 2 cycles at commit (read at t+1, write/ack at t+2); throughput irrelevant (serialized at the head).
- Trap/xRET redirect: +1 (bundle) — the frontend receives it as a registered redirect record.
- Interrupt injection: +1.
- Counters: unchanged rate; `instret` counts the bundle's acks.
- Cost: C1/C2/C3 registers (~12 + 64 + 64 bits), carry split for counters.

## 6. Decision

Files (new): `core/csr_regfile.sv` (ports unchanged; `csr_rdata_o` valid 1 cycle after `csr_en`, `csr_ack_o` added), `csr_decode.sv`, `csr_read.sv`, `csr_write.sv`, `csr_trap.sv`, `csr_irq.sv`, `csr_counters.sv`. `HypCfg`: `CsrReadStages` (1 = today's same-cycle, 2 = C1/C2 with C3 the cycle after).

Kill identities: none by tid (commit-head only); a CSR op whose bundle is dropped (cancelled) never reaches C1.

Expected `// hyp8:` departures: (1) `csr_rdata_o` +1 and `commit_stage` holds the CSR op for two cycles; (2) side-effect flush requested one cycle later; (3) interrupt injection registered.
