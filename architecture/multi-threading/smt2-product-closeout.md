# SMT2 product closeout checklist

SMT2 is **not** finished when the soft-ladder cookie is green. Cookie / topology
are the first trust gate; this file tracks the remaining product-closeout items
and the FDT properties that compensate for them until they are retired.

The FDT exposes unimplemented product features as `/soc/smt-product-closeout`
properties so OpenSBI and Linux can adapt **intrinsically** rather than guessing
at the micro-architecture. Each property is removed when its item is retired.

---

## 1. Boot-crutch retirement

| Item | Locus | Acceptance | Status | FDT property |
|------|-------|------------|--------|--------------|
| `SMT_COLD_EXCL` | `core/cva6.sv` | `plat_hc == 2` and `coldboot_done == 1` on natural OpenSBI, no `SOFT_*` peels | Open | `smt,boot-crutches` bit 0 |
| `SMT_FIRST_ACT_EXCL` | `core/cva6.sv` | Secondary hart starts cleanly without first-activation window | Open | `smt,boot-crutches` bit 1 |

---

## 2. Fetch / control-flow (S4 residual)

| Item | Locus | Acceptance | Status | FDT property |
|------|-------|------------|--------|--------------|
| `fetch_B` / `instr_queue` leftover → jump-to-0 | `core/frontend/instr_queue.sv`, `core/frontend/frontend.sv`, `g6lc_thread_select.sv` | Natural OpenSBI FDT walk reaches cookie `51b1babe` without `PEEL_FDT_GETPROP`, `SOFT_HART_INIT`, or `SOFT_PLAT_OPS` | Open | none; fix is pure RTL |

The S4 live pin is `mepc=0` after `sbi_trap_redirect` (`ra=0x12994`, offset_ptr
jump). `12958` illegal is closed; `leftover_retake` and `leftover-complete slot0
push` are kept, `pipe_keep` / `leftover_replay_hold` / `leftover_drop hold` are
reverted.

---

## 3. Dual-commit of two different harts

| Item | Locus | Acceptance | Status | FDT property |
|------|-------|------------|--------|--------------|
| Same-cycle two-hart commit | `core/commit_stage.sv`, `core/csr_buffer.sv` | Two different harts can each retire a CSR or excepting instruction in the same cycle without serialization stalls | Open | `smt,dual-commit` = 0 |

While open, the FDT tells firmware to serialize per-hart SBI/CSR paths; Linux
sees standard per-hart CSRs.

---

## 4. Branch-prediction banks

| Item | Locus | Acceptance | Status | FDT property |
|------|-------|------------|--------|--------------|
| Banked BHT/BTB | `core/frontend/bht.sv`, `core/frontend/btb.sv` | No cross-hart predictor pollution; per-hart tables or flush-on-switch | Open | `smt,banked-bht` = 0 |

While open, the OS scheduler may avoid security-relevant hart migration; OpenSBI
may flush before HSM start if needed.

---

## 5. FP / vector register banking

| Item | Locus | Acceptance | Status | FDT property |
|------|-------|------------|--------|--------------|
| Banked F/D/V RF | `core/fpu_wrap.sv`, `core/acc_dispatcher.sv` | Full FPU/vector context is per-hart; no save/restore on every thread switch | Open | `smt,fp-register-banking` = 0 |

While open, the OS must do a full FPU/vector context switch on every hart
switch; no lazy FPU.

---

## 6. Idle-thread clock gating

| Item | Locus | Acceptance | Status | FDT property |
|------|-------|------------|--------|--------------|
| Per-hart clock gate | `core/cva6.sv` / `tc_clk_gating` | WFI on one hart can gate its clock without stalling the peer | Open | `smt,idle-clock-gate` = 0 |

While open, `cpu-idle-states` must only define WFI (state 0); no deeper
C-states.

---

## 7. `Zawrs` / wait-for-peer

| Item | Locus | Acceptance | Status | FDT property |
|------|-------|------------|--------|--------------|
| `Zawrs` wait-on-pause | `core/controller.sv` / SBI | `sbi_send_ipi_and_wait` works correctly across harts | Open | `smt,zawrs` = 0 |

While open, SBI must not use `sbi_send_ipi_and_wait`; Linux does not advertise
`zawrs`.

---

## 8. SMT2 as a default SKU

| Item | Locus | Acceptance | Status | FDT property |
|------|-------|------------|--------|--------------|
| Default `NrHarts=2` package | `core/include/g6lc64_smt2_config_pkg.sv`, `ariane-smt2.dts` | A production package uses `NrHarts=2` without being explicitly experimental | Open | `smt,default-sku` = `experimental` |

The `g6lc64_smt2` package is the bring-up vehicle. The default production
identity remains `NrHarts=1` until this item closes.

---

## 9. FDT compensation properties

Until all of the above are retired, the DTS for any SMT package must include:

```dts
soc {
    smt-product-closeout {
        compatible = "smt,product-closeout";
        smt,boot-crutches = <0x3>;          /* bits 0 and 1 */
        smt,dual-commit = <0>;
        smt,banked-bht = <0>;
        smt,fp-register-banking = <0>;
        smt,idle-clock-gate = <0>;
        smt,zawrs = <0>;
        smt,default-sku = "experimental";
    };
};
```

OpenSBI consumes these properties in the `CVA6_DI_BRINGUP` profile and patches
`cpu@` `status` / `available` fields accordingly. Linux may read
`smt,default-sku` to decide whether to trust dual-hart topology before the
product closeout is complete.

---

## 10. Verification gates

| Gate | Suite / run | Acceptance |
|------|-------------|------------|
| Natural FDT walk | `work-ver-smt2-fw64` / `slfix`, PEEL_FDT_GETPROP=0 | cookie `51b1babe` |
| Topology truth | `work-ver-smt2-slfix` | `plat_hc == 2`, `coldboot_done == 1`, no `SOFT_*` peels |
| Linux `/proc/cpuinfo` | `g6lc64_server_math_v` / `g6lc64_ooo_server` via proxy | 2 / 8 processors as expected |
| SMT product closeout | `smt2-product-closeout.md` (this file) | all rows `closed`, FDT properties removed |

---

## 11. Related files

| File | Role |
|------|------|
| [`fdt-topology-soft-ladder.md`](fdt-topology-soft-ladder.md) | `NrCores` × `NrHarts` / cpu-map contract |
| [`soft-ladder/inventory.yaml`](soft-ladder/inventory.yaml) | Soft-site registry, status of B1/B2/B3 |
| [`soft-ladder/b2-firmware-policy.md`](soft-ladder/b2-firmware-policy.md) | `CVA6_DI_BRINGUP` profile, FDT source patches |
| [`smt2-bringup.md`](smt2-bringup.md) | SMT bring-up, boot crutches, known limits |
| [`../AGENTS-todo.md`](../AGENTS-todo.md) | SL-X tracks this checklist |
