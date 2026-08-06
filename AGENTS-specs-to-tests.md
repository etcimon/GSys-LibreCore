# AGENTS-specs-to-tests.md — RISC-V spec ⇄ CVA6 test-suite map

This is the **living cross-reference from the RISC-V specification to the tests that exercise it**. When
you add, remove, retarget, or re-scope a test suite (or a `verif/tests/testlist_*.yaml`), update the
matching row here so "which spec chapter is this test protecting?" stays answerable in one hop.

- Tests are catalogued and run through the **build-platform orchestrator** (`bun` from
  `build-platform/`). It is the single entry point; suite definitions live in
  `build-platform/src/config/defaults.ts` (`tests.suites`).
- Underlying content: shell runners in `verif/regress/*.sh` driving test lists in
  `verif/tests/testlist_*.yaml` over the `verif/` DV flow (`verif/sim`, `verif/tb`, `verif/core-v-verif`).
- Companion docs: `AGENTS-specs-to-impl.md` (spec→RTL) and `AGENTS-specs-coverage.md` (status-only).

> **This file is a standing discipline (see `AGENTS.md`).** Co-equal with keeping `agents/spec/INDEX.md`
> current: a change to any test suite/testlist is not "done" until its row here (and the derived
> `AGENTS-specs-coverage.md`) is updated.

---

## Running the suites (single orchestrator)

```sh
cd build-platform
bun run src/cli/index.ts test --list            # every suite + group + runnable status
bun run src/cli/index.ts test <id>              # one suite (e.g. riscv-arch-test)
bun run src/cli/index.ts test --group arch      # a whole family
bun run src/cli/index.ts test --open-source     # everything runnable on the OSS toolchain
```

Suites whose tools / submodule (`riscv-dv`) / UVM simulator are missing are **skipped, not failed**.
Groups: `smoke`, `arch`, `directed`, `benchmark`, `uvm`, `generated`, `pk`, `linux`.

---

## Suite → spec area (forward map)

| Suite id | Group | Backing test list(s) | Spec area exercised |
|---|---|---|---|
| `smoke-cv64a6` | smoke | compliance/tests/arch subset (`-cv64a6_imafdc_sv39`) | Part I base + M/A/F/D/C sanity on rv64 |
| `smoke-cv32a6` | smoke | subset (`-cv32a6_imac_sv32`) | Part I base + M/A/C sanity on rv32 |
| `smoke-cv32a65x` | smoke | hello-world | bring-up sanity (embedded target) |
| `riscv-tests` | arch | `testlist_riscv-tests-<target>-{p,v}.yaml` | Part I base RV32I/RV64I + M/A/F/D/C unit tests; `-v` = Sv paging (Part II 4.x) |
| `riscv-arch-test` | arch | `testlist_riscv-arch-test-<target>.yaml` | Part I architectural conformance (base + enabled extensions) |
| `riscv-compliance` | arch | `testlist_riscv-compliance-<target>.yaml` | Legacy ISA compliance (base + extensions) |
| `csr-access` | arch | `testlist_riscv-csr-access-test-<target>.yaml` | Zicsr + Part II ch2 CSR access/permissions |
| `mmu-sv32` | arch | `testlist_riscv-mmu-sv32-arch-test-cv32a6_imac_sv32.yaml` | Part II 4.3 Sv32 paging; PMA regions (3.6) |
| `iss-tests` | directed | ISS directed programs | Part I base semantics vs. Spike reference |
| `issue-tests` | directed | `testlist_issues.yaml` | regression for previously-filed ISA/pipeline bugs |
| `cv32a6-tests` / `cv64a6-tests` | directed | `cv32a6_tests.sh` / `cv64a6_imafdc_tests.sh` | per-target directed base/ext regressions |
| `ooo-l3-tests` | directed (optional/lengthy) | `testlist_ooo_l3.yaml` + `ooo-l3-tests.sh` | U5 4-issue OoO ILP/memdep + L2/L3 (`cv64a6_ooo_server`) |
| `mc-stream-tests` | directed (optional) | `testlist_mc_stream.yaml` + `mc-stream-tests.{sh,ps1}` | U6/p6 stream plane × multicore + Zacas/spo: multi-stream PF, thrash, inclusive L3→L2/L1, AMOCAS.W/D, store-fwd, fence drain, CAS lock handoff, CF×stream (`cv64a6_ooo_server` / `server_math`) |
| `mc-spo-soak` | directed (optional) | `mc-spo-soak.{sh,ps1}` + `testlist_mc_stream` artifacts | Assemble smoke + dual-target lint for stream×spo/CF/CAS narrow list (no full sim required) |
| `mc-spo-spike` | directed (optional) | `mc-spo-spike.sh` + `testlist_mc_stream` | Spike ISS soak of multicore spo/CF/Zacas narrow tests (`cv64a6_server_math`); **Spike has no zacas** — CAS paths may soft-skip; not a hard CAS golden |
| `mc-mini-veri` | directed (optional) | `mc-mini-veri.sh` + `verif/tests/custom/multicore/mini_*.S` | **Hard** Verilator bare-metal CAS golden: `mini_tohost` / `mini_jumps` / `mini_amocas_{w,d}` on Variane (`cv64a6_imafdc_sv39`, `RVZacas`); no CRT |
| `mc-spo-veri` | directed (optional) | `mc-spo-veri.sh` + self-built CRT ELFs (`work-ver/mc_spo_elfs`) | CRT Variane smoke (**7/7** with `MC_SPO_VERI_FORCE_IMAFDC=1`, Verilator 5.008): AMOCAS.W/D, st-fwd, fence, cas_lock, cf/mispred stream. Residual hang/flake: `cas_stream`+`stream_plane` via `MC_SPO_VERI_FULL=1`. Prefer `mc-mini-veri` for hard bare CAS |
| `ara-vector-path` | directed (optional) | `ara-vector-path.{sh,ps1}` + `testlist_ara_vector.yaml` | U10ᵇ RVV (I ch9): Ara vendor + `Flist.ara` + `server_math_v` + DTS `v` + directed soft-skip/misa/LMUL memcpy + attach/lint gate (full RVV compliance cosim still open) |
| `timings-sta-handoff` | directed (optional) | `timings-sta-handoff.sh` | Host S0: timings package → review-only OpenSTA `seeds.sdc` + FO4 CSV + correlate scaffold (`architecture/build-platform-opensta-from-timing.md`) |
| `verify --formal` (not a suite) | formal | `core/ooo/formal/{cva6_ooo_freelist,cva6_ooo_rob,cva6_ooo_cancel,cva6_ooo_rename}.sby` via `verify.formalTasks` | U5: live freelist + ROB occupancy (slang BMC) + rename free/busy/bypass + cancel-mask policy model |
| `spec-deep-path` | directed (optional) | `spec-deep-path.{sh,ps1}` | FSE path/artifact gate + lint `cv64a6_spec_deep` / `cv64a6_ooo` |
| `spec-deep-tests` | directed (optional) | `testlist_spec_deep.yaml` + `spec-deep-tests.{sh,ps1}` | FSE S6: mispredict/STQ/fence + single-hart RVWMO/A litmus (`cv64a6_spec_deep`) |
| `server-math-tests` | directed (optional) | `testlist_server_math.yaml` | U10 C-light: misa B/H, cbo.zero, scalar memcpy (`cv64a6_server_math`) |
| `kvm-h-tests` | directed (optional) | `testlist_kvm_h.yaml` | H hfence + dual VS ecall + Sstc litmus (KVM-oriented) |
| `dual-hart-ci` | directed (optional) | `dual-hart-ci.sh` | SMT2/NrHarts=2 artifact + checklist |
| `smt-linux-boot-path` | directed (optional) | `smt-linux-boot-path.{sh,ps1}` | DTS vs sparse linux-dts + CLINT/PLIC per-hart gate (no full Linux image) |
| `smt-linux-rootfs` | linux (optional) | `smt-linux-rootfs.{sh,ps1}` + `testlist_smt_linux.yaml` + `software/smt2-linux/` | SMT OpenSBI R3a auto-build when toolchain present; sim if `CVA6_LINUX_PAYLOAD` / `fw_payload.elf` |
| `iti` / `instr-tracing` | directed | ITI / trace directed | trace/observability (not ISA-normative) |
| `debug` | directed | debug-module test | Debug spec (external), triggers |
| `interrupt` | uvm | `testlist_interrupt.yaml` | Part II traps/interrupts, CLINT/PLIC delivery |
| `custom/sstc_h` | directed | `testlist_custom.yaml` → `vstimecmp_htimedelta` | Sstc×H U9.0–9.2: htimedelta, vstimecmp, VSTIP mip/hip, VS mret + stimecmp alias + ecall |
| `csr-embedded` | uvm | `testlist_csr_embedded.yaml` | Part II CSRs on embedded cv32a65x |
| `pmp` | uvm | `testlist_pmp-cv32a65x.yaml` | Part II 3.7 PMP (+ 6.3 Smepmp) |
| `hwconfig` | uvm | `testlist_hwconfig.yaml` | config/parameterization legality (`check_cfg` surface) |
| `cvxif` | uvm | `testlist_cvxif.yaml` | CVXIF coprocessor interface (microarch seam) |
| `smoke-gen` / `generated` | generated | riscv-dv generated | randomized base+ext stress; RVWMO/ordering breadth |
| `generated-xif` | generated | riscv-dv + CVXIF | randomized CVXIF stress |
| `pk-tests` | pk | proxy-kernel tests | S/U-mode + syscall path (Part II supervisor) |
| `dhrystone` / `dhrystone-smoke` / `coremark` / `benchmark` | benchmark | perf workloads | performance (not conformance) |
| `linux` | linux | Linux boot | full-system: paging, traps, CSRs, atomics end-to-end |
| (`testlist_isacov.yaml`) | (coverage) | functional coverage groups | ISA functional-coverage collection across suites |

---

## Spec chapter → suites (reverse index)

| Spec chapter / feature | Suites that exercise it |
|---|---|
| Part I base RV32I / RV64I | `riscv-tests`, `riscv-arch-test`, `riscv-compliance`, `smoke-*`, `generated` |
| M (mul/div) | `riscv-tests` (`*um*`), `riscv-arch-test`, `generated` |
| A / Zalrsc (atomics, LR/SC) | `riscv-tests` (`*ua*`), `riscv-arch-test`, `linux` |
| Zacas AMOCAS.W/D (I §5.9) | `mc-mini-veri` (hard RTL), `mc-stream-tests` / `mc-spo-soak` / `mc-spo-spike` (directed/ISS), `mc-spo-veri` (CRT residual) |
| F / D (floating point) | `riscv-tests` (`*uf*`/`*ud*`), `riscv-arch-test` (rv64 targets) |
| C (compressed) | `riscv-tests` (`*uc*`), `riscv-arch-test`, `smoke-*` |
| Zicsr + Part II ch2 CSRs | `csr-access`, `csr-embedded`, `hwconfig` |
| Zifencei / fences (4.1) | `riscv-tests` (`fence_i`), `riscv-arch-test`, `spec-deep-tests` (`spec_fence_drain`) |
| RVWMO memory model (3.1) | `generated` (riscv-dv breadth); **`spec-deep-tests`** single-hart subset (`spec_rvwmo_litmus`) — multi-hart litmus still a gap |
| PMA regions (II-3.6) | `mmu-sv32`, `pmp` (indirect), `linux` |
| PMP (II-3.7) + Smepmp (6.3) | `pmp` |
| Sv32 (II-4.3) | `mmu-sv32` |
| Sv39 (II-4.4) | `riscv-tests` `-v` on `cv64a6_imafdc_sv39`, `linux` |
| Traps / interrupts (II ch3) | `interrupt`, `linux` |
| Supervisor / U-mode (II ch4) | `pk-tests`, `linux` |
| Bitmanip Zb* (I ch8) | `riscv-arch-test` (when `RVB`), `cv*-tests` |
| Vector V / RVV (I ch9) | `ara-vector-path` + `testlist_ara_vector.yaml` (attach/lint + directed; not full compliance cosim) |
| CVXIF coprocessor seam | `cvxif`, `generated-xif` (mutex with RVV accelerator path) |
| Randomized / functional coverage | `generated`, `smoke-gen`, `testlist_isacov.yaml` |
| Full-system integration | `linux` (single-hart BBL), `smt-linux-rootfs` (SMT preflight + optional payload), `pk-tests` |

---

## Known coverage gaps (kept honest)

These spec areas are **not directly exercised** by a dedicated open-source suite here (they rely on
randomized `generated` breadth, a commercial UVM sim, or are `absent` in RTL so untested by design):

- **RVWMO multi-hart / remote ordering** — single-hart directed subset lives in `spec-deep-tests`
  (`spec_rvwmo_litmus.S`); multi-hart litmus and Ztso still absent. Broader ordering still relies on
  `generated` (riscv-dv) where a UVM/ISS path is available.
- **Hypervisor H, Sv48/Sv57, newer Ss*/Sm*/Sv* extensions** — no dedicated suite; add one when the RTL
  row in `AGENTS-specs-to-impl.md` moves off `absent`/`partial`.
- **CFI, Packed SIMD, Matrix, vector crypto (`zvk*`)** — `absent` in RTL, therefore untested by design.
- **Zacas (I §5.9)** — RTL is **partial** (AMOCAS.W/D config-gated via `RVZacas`; AMOCAS.Q absent).
  Directed coverage: `testlist_mc_stream.yaml` (`zacas_*`, CAS lock, CF×stream) + suites
  `mc-stream-tests` / `mc-spo-soak` / `mc-spo-spike` (ISS; **not** hard CAS) /
  **`mc-mini-veri` (hard RTL golden)** / `mc-spo-veri` (CRT residual).
  Spike lacks zacas — never treat ISS skip as RTL pass. Sub-file:
  `agents/spec/riscv-spec-I-5.9-zacas.html`.
- **RVV / Vector (I ch9)** — RTL is **partial** (Ara attach live-lintable; purpose guide + DTS +
  directed `testlist_ara_vector.yaml` / suite `ara-vector-path`). Functional `v_memcpy_lmul`
  needs live Ara cosim; OpenSBI VRF save/restore + full RVV compliance / Spike cosim still open
  until `cva6.py` runs under that config. Sub-file: `agents/spec/riscv-spec-I-9-vector.html`.

When you close a gap, add/extend a `verif/tests/testlist_*.yaml`, register (or reuse) a suite in
`build-platform/src/config/defaults.ts`, and update the tables above + `AGENTS-specs-coverage.md`.

---

## Maintenance contract

When a test suite / testlist changes:
1. Update the forward and reverse rows here (suite id, backing list, spec area).
2. If the suite newly covers a previously-untested implemented chapter, update
   `AGENTS-specs-coverage.md` (it may move from *implemented* to *implemented & tested*).
3. Keep the suite catalog in `build-platform/src/config/defaults.ts` and this file in agreement
   (id, group, target, tools).
