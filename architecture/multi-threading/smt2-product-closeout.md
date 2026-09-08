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
| `fetch_B` / `instr_queue` leftover → jump-to-0 | `core/fetch_A/frontend/instr_queue.sv`, `core/fetch_A/frontend/frontend.sv`, `g6lc_thread_select.sv` | Natural OpenSBI FDT walk reaches cookie `51b1babe` without `PEEL_FDT_GETPROP`, `SOFT_HART_INIT`, or `SOFT_PLAT_OPS` | Open | none; fix is pure RTL |

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

Scope, precisely: the **instructions are implemented**. `core/decoder.sv` decodes
`WRS.NTO` (imm `0x00d`) and `WRS.STO` (imm `0x01d`) under `CVA6Cfg.ZawrsEn` and
retires them as `ariane_pkg::WFI` with WFI's privilege/`TW` rules. Zawrs permits
`WRS` to terminate for any reason, so that is a conforming implementation, and
every `g6lc*` package sets `ZawrsEn: bit'(1)`.

What is open is the SMT **wait-for-peer wake** (no reservation-set-invalidation
wake between the two harts). That is a microarchitectural quality-of-implementation
item plus a firmware policy, not an ISA-advertisement item. While open: SBI must
not use `sbi_send_ipi_and_wait`, and `ariane-smt2.dts` does not list `zawrs` in
`riscv,isa` / `riscv,isa-extensions`. Packages without the SMT wake constraint
(`ariane-linux`, `ariane-ai`, `ariane-stream8`, `ariane-ooo-server`,
`ariane-server-math-v`) do advertise `zawrs`, which is correct for them.

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

**This node is documentation only. No firmware reads it.** The `cpu@` nodes are
the sole guest-visible contract, and they must simply not advertise what the SKU
does not provide. `smt,default-sku` is a checklist marker, not a runtime input.

### Enforcement: build time, not run time

`software/smt2-linux/scripts/dts_to_dtb.py` runs before `make` and proves the
invariant. For each `smt,<item> = <0>` that maps to a guest-visible extension
(table `CLOSEOUT_ISA_TOKENS`; today only `zawrs`), it checks every `riscv,isa`
and `riscv,isa-extensions` in the tree:

| Case | Behaviour |
|------|-----------|
| No `cpu@` advertises the token | prints `closeout OK: no cpu@ advertises <tok>`, compiles |
| A `cpu@` advertises it | **fails the DTB build** (exit 3), naming property and token |
| `--strip-closeout` | rewrites a temporary DTS without the token, compiles that, leaves the source DTS untouched |
| `--no-closeout-check` | skips the guard |

Non-ISA properties (`dual-commit`, `banked-bht`, `fp-register-banking`,
`idle-clock-gate`, `boot-crutches`, `default-sku`) are deliberately not enforced —
they describe microarchitecture and policy, not guest-visible ISA. `g6q conform`
remains the checker for config × DTS disagreement generally
(capability `wait-on-reservation`: `config = ZawrsEn`, `dts = zawrs`).

### Retired: the OpenSBI runtime rewriter

An earlier revision patched OpenSBI's `platform/generic/platform.c` with
`g6lc_fdt_smt_compensation()` (via a now-deleted
`scripts/patch_opensbi_smt_compensation.py`) to strip `zawrs` from the FDT at
run time. It is retired for three independent reasons:

1. **It was dead.** `ariane-smt2.dts` has never advertised `zawrs`, so the strip
   had nothing to remove.
2. **It broke the boot.** The rewriter called `sbi_malloc()` from
   `fw_platform_init()` (`fw_base.S:115`), which runs ~250 instructions before
   `sbi_init()` → `sbi_heap_init()` (`fw_base.S:367`). `hpctrl` was still zeroed
   BSS, so `sbi_list_for_each_entry` dereferenced `NULL+0x18` and trapped
   `fault_load` with `mtval = 0x18`, landing in `_start_hang`. This was the
   OpenSBI-on-QEMU hang observed on `g6lc-g6lc64_smt2`.
3. **It cost a fork.** The patch matched upstream source text by anchor and had
   to track it across OpenSBI revisions.

Firmware stays stock. When the wait-for-peer item closes, add `zawrs` back to the
`cpu@` nodes and drop `smt,zawrs` — no firmware change is involved.

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
