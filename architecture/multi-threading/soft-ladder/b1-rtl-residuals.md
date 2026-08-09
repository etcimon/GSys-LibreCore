# B1 — RTL / dual-issue residuals

Promotion order among B1 (from `inventory.yaml` priority):

1. **AMO / spin_lock** (`b1-amo-spin-lock`)
2. **LR/SC cmpxchg** (`b1-lrsc-cmpxchg`)
3. **CSR expected-trap** (`b1-csr-expected-trap`)
4. **FDT lenp store** (`b1-fdt-lenp-store`)
5. **Dual c.mv** (`b1-dual-cmv-s3`)

## Investigation map

### AMO / `spin_lock` (priority 1)

| Item | Detail |
|------|--------|
| Soft evidence | NOP `jal spin_lock/unlock` in OpenSBI SA, heap free/used, scratch_used |
| Fail pin | Real lock → `mepc=0x2` / early hang under DI |
| OpenSBI op | `amoadd.w.aqrl` style ticket lock |
| Primary RTL | `core/store_unit.sv`, `core/amo_buffer.sv`, LSU issue coupling |
| Also check | Dual-issue of AMO with following load/store/ALU; commit `amo_valid_commit` |
| Directed test sketch | `amoadd.w` to shared word; pair with independent ALU dual-issue; then two-thread later |
| Retire criterion | Remove all freelist/SA spin NOP4 from `mk_plat_skip.py` |
| **iter-004 fix (in tree)** | Hang-7 younger-cancel + no `flush_ex` on mispredict left cancelled AMO in depth-1 `amo_buffer` forever (`ready_o=0`). Fix: `cancel_i` flush when `cancelled_mask[tid]` and not yet at commit; skip push if already cancelled; AMO issue port-0 only under `SuperscalarEn`. Test: `verif/tests/custom/multicore/mini_amoadd_w_spin.S`. OpenSBI peel still needs lab re-soak. |

### LR/SC / `atomic_cmpxchg` (priority 1)

| Item | Detail |
|------|--------|
| Soft evidence | `atomic_cmpxchg` body = `ld; bne; sd; ret` (cont.50) at `0x800086c0` |
| Fail pin | Real `lr.d`/`sc.d` hang; cookie incomplete (`51b1c001` class) |
| Primary RTL | LSU reservation set, SC fail/success, flush interaction |
| Directed test sketch | LR; non-conflicting dual-issue op; SC success; LR; store; SC fail |
| Retire criterion | Delete soft cmpx shim; OpenSBI uses stock atomics |
| **iter-005 fix (in tree)** | (1) Skip `flush_commit` for `AMO_LR*` so LR does not `flush_ex` the pipe. (2) `lr_sc_pair_q` in issue: after LR until SC, block non-SC STORE so intervening stores cannot clear `axi_riscv_lrsc` exclusive. Helpers `is_amo_lr`/`is_amo_sc`. Test: `mini_lrsc_d.S`. Lab re-soak still required before peeling soft cmpx. |

### CSR expected-trap (priority 2)

| Item | Detail |
|------|--------|
| Soft evidence | After `sbi_hart_init` memset, jump to reinit (skip probes) |
| Fail pin | Illegal CSR dual-issued with `csrw mtvec` → trap handler restored before illegal |
| Primary RTL | CSR pipeline, exception vs following CSR write |
| Directed test sketch | `csrr` illegal; immediately `csrw mtvec, known`; check handler/mcause |
| Retire criterion | Full CSR probe loop in hart_init under DI |
| **iter-006 fix (in tree)** | `issue_stage` `unresolved_csr_q`: after CSR issue, no same-hart younger issue until that CSR `commit_ack` or flush. Test: `mini_csr_expected_trap.S`. |

### FDT `lenp` store (priority 2 — **active iter-012**)

| Item | Detail |
|------|--------|
| Soft evidence | Soft `sbi_printf` BANR cave; soft strlen ret-imm avoids deep FDT |
| Fail pin | PEEL_STRLEN on FW64: mepc=`0x80012eb2` mcause=6 mtval=`0x80012b2a` (code ptr as lenp) |
| Primary RTL | Store address path / dual-issue of address calc + store |
| Note | Hang-6 family; multiple sites (12eb2, 13128, …) |
| Retire criterion | Real `sbi_printf` / FDT walk green under PEEL_STRLEN |

### Dual `c.mv` (priority 3 — **peeled iter-008**)

| Item | Detail |
|------|--------|
| Soft evidence (retired) | Was nop pair @7312/7314; now **natural** by default |
| Fail pin (historic) | `s3` clobber → `ld a2,0(s3)` poison at 7316 |
| Isolate (2026-08-09) | Natural c.mv + soft stub `jal fdt_match` @731e → **cookie green**. PEEL_CMV alone failed mid-`sbi_strlen` because natural a0/a1 *enable* match, not dual-c.mv RF poison. |
| Bare directed | `mini_dual_cmv_s3.S`, `mini_strlen_rvc.S`, `mini_dual_cmv_strlen.S` **PASS** |
| Residual moved to | Soft stub fdt_match / FDT lenp / strlen (`b1-fdt-lenp-store`) |
| Retire criterion | **Met** for dual-c.mv class; `SOFT_CMV=1` bisect only |

### FDT match / `sbi_strlen` (priority 2 — **mid-RVI fixed; soft ret-imm until FDT**)

| Item | Detail |
|------|--------|
| Soft evidence | Soft `sbi_strlen` ret-imm 11 (cookie); natural match peeled |
| Fail pin (old FETCH_WIDTH=32) | `PEEL_STRLEN` mepc=`0x80004a50` mid-`add` |
| Fail pin (FETCH_WIDTH=64) | `PEEL_STRLEN` **past strlen** → mepc=`0x80012eb2` mcause=6 **FDT lenp** |
| RTL (iter-011) | `build_fetch_width`: min 64 when n_issue≥2 && RVC; + instr_queue PC continuity |
| Retire criterion | Soft strlen dropped when FDT green; PEEL_STRLEN mid-instr **closed** |

### Heap freelist malloc (priority 1 — **peeled iter-010**)

| Item | Detail |
|------|--------|
| Soft evidence (retired) | Was soft malloc/zalloc/free; now **natural** |
| Fail pin (historic) | freelist unlink sd mcause=6 @f0ba under spin-nop dual-hart |
| Isolate (2026-08-09) | PEEL_MALLOC×2 cookie green; `mini_freelist_unlink` PASS |
| Retire criterion | **Met**; `SOFT_MALLOC=1` bisect only |

## Already landed in RTL (do not re-patch via monorepo-soak scripts)

| Landing | Location | Soft-ladder impact |
|---------|----------|-------------------|
| SS dual-issue serialize after CF/ALU/MULT/FPU/LSU | `issue_read_operands.sv` (R3a cont.6/14/15/18) | Partial fix for FDT/lenp/callee-saved; soft printf may still be needed until fully clean |
| Hang-4 realign PC per FIFO word | `instr_queue.sv` | Dual-issue PC integrity |
| Hang-4 completion PC continuity | `instr_queue.sv` pc_j + dual-issue gate | defensive with FETCH_WIDTH=64 |
| DI+RVC FETCH_WIDTH min 64 | `build_config_pkg.sv` `build_fetch_width` | PEEL_STRLEN mid-RVI **fixed** |
| Hang-7 younger cancel (skip LOAD cancel) | `scoreboard.sv` | CF fallthrough recovery |
| Unresolved CF issue stall (per-hart) | `issue_stage.sv` | Blocks issue past unresolved CTRL_FLOW |
| AMOCAS.Q dual_we path | commit/issue/hpdcache/ariane_pkg | Zacas feature (not soft-ladder spin) |
| AMO buffer cancel + AMO port0 | amo_buffer / store_unit / issue | SA spins peelable |
| No flush after LR; LR→SC store barrier | commit / issue_read_operands | cmpxchg LR/SC peelable |
| Unresolved CSR issue stall | issue_stage | CSR probe tail peelable |
| Soft sbi_strlen ret-imm 11 | mk_plat_skip only | Cookie green until PEEL_STRLEN RTL |

## Iteration rule for B1

- Prefer a **bare-metal** directed test that does not depend on OpenSBI once the pin is clear.
- Only then re-run OpenSBI **with that soft site removed**.
- Do not combine two B1 residuals in one RTL change unless they share one mechanism.
- **Do not re-run** monorepo-soak `patch-*.py` for landings above — see `monorepo-soak/APPLIED.md`.
