# AGENTS-specs-to-impl.md — RISC-V spec ⇄ CVA6 RTL map

This is the **living cross-reference from the RISC-V specification to the SystemVerilog that implements
it**. When you change `core/**` (or `corev_apu/**`) RTL that affects ISA-visible behavior, update the
matching row here so the spec→code answer stays one hop away.

- Spec of record: `specs/riscv-spec.html` (anchors) with summaries in `agents/spec/*.html` (indexed by
  `agents/spec/INDEX.md`).
- Feature playbooks: `agents/guides/AGENTS-*.md`. Master narrative: `AGENTS.md` §5.
- Companion docs: `AGENTS-specs-to-tests.md` (what tests exercise each chapter) and
  `AGENTS-specs-coverage.md` (status-only summary, derived from this file + the tests map).

> **This file is a standing discipline (see `AGENTS.md`).** It is co-equal with keeping
> `agents/spec/INDEX.md` current and logging todos: an edit that changes ISA-visible RTL is not "done"
> until its row here (and the derived `AGENTS-specs-coverage.md`) is updated.

---

## Status vocabulary

| Status | Meaning |
|---|---|
| `implemented` | Always present in the core pipeline (not config-gated off in any normal target). |
| `config` | Present behind a `cva6_cfg_t` bit in ≥1 shipped target; **verify in the per-target package** (`core/include/cv*_config_pkg.sv`). |
| `partial` | Incomplete, hint-only (e.g. executed as a NOP), or a subset of the extension. |
| `absent` | Not implemented in any shipped config. |
| `n/a` | Non-normative or microarchitectural (no dedicated ISA RTL). |

**Caveat**: statuses describe the *maximal capability across shipped configs*. Almost everything is
per-target — always confirm against the target's `core/include/cv*_config_pkg.sv` before relying on a row.
Line numbers are cited only where stable/known; otherwise the file is cited at module granularity.

---

## How to use

1. Identify the spec chapter/`X.y` (via `agents/spec/INDEX.md`) your change touches.
2. Jump to the row below → open the **primary RTL loci** and the **config knob**.
3. For microarchitecture with no normative section (branch prediction, caches, speculation), use the
   "Microarchitectural map" section and the matching `agents/guides/` playbook.
4. After the RTL edit, refresh this row + the tests map + coverage.

---

## Part I — Unprivileged Architecture

### Base integer, memory model, fences
| Spec (anchor) | Status | Primary RTL loci | Config knob |
|---|---|---|---|
| RV32I / RV64I base (`#base`, `#rv32`, `#rv64`) | implemented | `core/decoder.sv`, `core/alu.sv`, `core/issue_read_operands.sv`, `core/commit_stage.sv`, `core/ariane_regfile_ff.sv` | `XLEN` (target pkg) |
| Address space / memory (1.4, `#sec:intro-memory`) | implemented | `core/load_store_unit.sv`, `core/cva6_mmu/`, `core/cache_subsystem/axi_adapter.sv` | `Axi*Width` |
| Traps / exceptions (1.6, `#trap-defn`) | implemented | `core/commit_stage.sv`, `core/csr_regfile.sv`, `core/controller.sv` | — |
| RVWMO memory model (3.1, `#memorymodel`) | implemented | `core/load_unit.sv`, `core/store_buffer.sv`, `core/lsu_bypass.sv`, `core/amo_buffer.sv` | `NrLoadBufEntries`, `MaxOutstandingStores` |
| Ztso total store order (3.2, `#ext:ztso`) | absent | — | — |
| Zifencei / FENCE.I (4.1, `#ext:zifencei`) | implemented | `core/controller.sv`, `core/frontend/frontend.sv`, `core/csr_regfile.sv` | `DcacheFlushOnFenceI` |

### Scalar integer extensions (ch4)
| Spec (anchor) | Status | Primary RTL loci | Config knob |
|---|---|---|---|
| Zicsr (CSRs) | implemented | `core/csr_regfile.sv`, `core/csr_buffer.sv` | — |
| Zicntr / Zihpm (counters) | implemented | `core/perf_counters.sv`, `core/csr_regfile.sv` | `PerfCounterEn` |
| ↳ `mhpmeventN` selector encoding | implemented | 8-bit WARL, split `[7:5]`=group / `[4:0]`=index (`core/include/ariane_pkg.sv` `MHPMEvent*`); group 0 is the legacy 5-bit encoding unchanged; groups 1–7 reserved for feature upgrades (`core/perf_counters.sv`) | `MHPMCounterNum` |
| M / Zmmul (mul/div) | implemented | `core/mult.sv`, `core/multiplier.sv`, `core/serdiv.sv` | `RVM`/`Zmmul` (target pkg) |
| Zicond (cond. zero) | config | `core/alu.sv`, `core/decoder.sv` | `RVZicond` |
| Ziccif fetch atomicity (4.9) | implemented | `core/frontend/`, `core/cache_subsystem/cva6_icache.sv`, `core/instr_realign.sv` | `Icache*` |
| Ziccid I/D coherence (4.10) | implemented | `core/controller.sv` (FENCE.I), cache flush policy | `DcacheFlushOnFenceI` |
| Zicclsm misaligned (4.14) | partial | `core/load_store_unit.sv`, `core/load_unit.sv`, `core/store_unit.sv` | target-dependent |
| Zic64b 64-byte blocks (4.15) | config | `core/cache_subsystem/*` | `Dcache*LineWidth`/`Icache*LineWidth` |
| CFI — Zicfilp/Zicfiss (4.17, `#unpriv-cfi`) | absent | — | — |
| Zihintntl (4.18) | partial | `core/decoder.sv` (hint→NOP) | — |
| Zihintpause (4.19) | **implemented (config)** | `core/decoder.sv` (PAUSE→NOP when `ZihintpauseEn`) | `ZihintpauseEn` |
| CMO — Zicbom/Zicboz/Zicbop (4.20, `#cmo`) | **partial→Zicboz full-line** | Zicbom: decoder/store/HPDCACHE; **U7ᶜ Zicboz multi-beat** (`CBOZ_WAIT`/`ISSUE`); Zicbop: PREFETCH HINT→NOP; server package enables all three | `RVZiCbom`, `RVZiCboz`, `RVZiCbop` |
| Server math / AVX-like (U10) | partial (C-light + `_v`) | `cv64a6_server_math{,_v}`; HPDCACHE+HWPF+L2 auto; `server-math-tests`; `_v` enables RVV for Ara | `RVB`, `RVZiCbo*`, `HwPrefetchEn`, `RVH`, `RVV` |
| Ara / RVV attach (U10ᵇ) | **partial / live lintable** | Same as Vector V row: `ariane` gen_acc + `cva6_ara_attach` + `cva6_axi_2to1_mux`; `CVA6_ARA_ATTACH=1` Verilator green; `vendor/ara/` + shims; suite `ara-vector-path`. Spec sub-file `agents/spec/riscv-spec-I-9-vector.html` | `RVV`, `EnableAccelerator` |
| KVM/H stress + H-edge | directed green (Spike+RTL 3/3) | `verif/tests/custom/kvm_h/*`, suites `kvm-h-spike` / `kvm-h-tests` | `RVH`, `SstcEn` |
| L3 DT / inclusive | **implemented (gated)** | L3/L2 victim→L1 (`cva6_l3_inclusive_inv`); L3→L2 tag match-inval (`l2_back_inval_*` / `inval_match_*`); TB `INCLUSIVE_L3=L3En` | `L3En`, cluster `INCLUSIVE_L3` |
| Stream plane × multicore (U6/p6) | **implemented (gated)** | `cva6_server_prefetcher` + `NrCores` packages; suite `mc-stream-tests` | `ServerPrefetchEn`, `NrCores`, `L2En`/`L3En` |
| PMU group 2 L2/L3/PF | implemented | `perf_counters` g2; cluster→ariane→cva6 ports | `L2En`/`L3En`/`ServerPrefetchEn` |
| OoO formal | **live freelist+ROB+rename** | `core/ooo/formal/`: freelist→`cva6_freelist` (prove); ROB→`cva6_rob` via yosys-slang (BMC d=16); rename→`cva6_rename` multi-port free/busy/bypass (BMC d=12); cancel policy model; `verify.formalTasks` (4 tasks) | `OoOEn` |
| SMT / multi-hart (U6.1) | implemented (fine) | `core/smt/*` + banked RAS/GHR; IF-only switch; CSR commit by `hart_id`; `smt2-bringup.md` | `NrHarts`, `SmtPolicy` |
| Full OoO (U5) | **implemented (production, gated)** | 4-issue rename/IQ/ROB/LSQ; cancel-mask mispredict squash; PRF WB gate; PMU g1; `cv64a6_ooo` + `cv64a6_ooo_server` | `OoOEn`, `DeepSpecEn`, `NrIssuePorts`, `RobEntries`, `MemDepPredEn` |
| Full speculative execution (FSE) | implemented (config; S0–S6) | Arch+plan under `architecture/speculative-execution/`; depth plane; recovery; LSU younger cancel; SMT-tagged cancel; **S6** `spec-deep-tests` + RVWMO/A directed + security residual | `DeepSpecEn`, `SpeculativeSb`, `BPCkptDepth`, `NrHarts`, `NrLoadBufEntries`, `MaxOutstandingStores` |
| L3 + server prefetch | implemented (gated) | `corev_apu/l3_cache/*`; DT notes `dts-l3-prefetch.md`; PMU grp1 proxies | `L3En`, `ServerPrefetchEn` |
| Multi-core cluster + L1 inv (U6.2) | partial | `corev_apu/src/cva6_cluster.sv`, `cva6_l1_inv_adapter.sv`; core `l1_inval_*` ports → WT D$ | `NrCores`, `Coh*` |

### Atomics (ch5)
| Spec (anchor) | Status | Primary RTL loci | Config knob |
|---|---|---|---|
| A extension (5.1, `#ext:a`) | config | `core/amo_buffer.sv`, `core/load_store_unit.sv`, `core/store_buffer.sv` | `RVA` (target pkg) |
| Zalrsc LR/SC (5.2) | config | `core/load_store_unit.sv`, D$ reservation in `core/cache_subsystem/*` | `RVA` |
| Zawrs wait-on-reservation (5.5) | **partial (config)** | `core/decoder.sv` (WRS.NTO/STO→WFI path), `core/csr_regfile.sv` WFI stall | `ZawrsEn` |
| Zacas compare-and-swap (5.9, `#ext:zacas`) | **implemented (W/D/Q gated)** | `RVZacas`; decode `AMO_CASW/D/Q` (`core/decoder.sv`); third-op + Q pair RF gather; `amo_req` hi/`is_quad`/`dual_we`; HPDCache multi-beat `CASD_*` (+Q HI beats); dual WB in `commit_stage`; pkgs `server_math{,_v}` / `ooo_server` / `imafdc_sv39`. **Hard RTL golden** `mc-mini-veri` + `zacas-policy` (`mini_amocas_{w,d,q,q_illegal}`); plan `architecture/zacas-amocas-q.md`. Spike has no zacas (not a golden). Spec sub-file `agents/spec/riscv-spec-I-5.9-zacas.html` | `RVZacas` (⇒ `RVA`) |
| Za128rs/Za64rs/Zabha/Zaamo/Zalasr (5.3-5.10) | partial | (subset via A) `core/amo_buffer.sv` | — |

### Floating point, compressed, bitmanip, vector, crypto, matrix
| Spec (anchor) | Status | Primary RTL loci | Config knob |
|---|---|---|---|
| F / D floating point (ch6, `#zf`) | config | `core/fpu_wrap.sv`, `core/cvfpu/` | `RVF`, `RVD`, `FpuEn` |
| Q quad / Zfh half | absent / config | `core/cvfpu/` (Zfh only) | `RVZfh` |
| C compressed (ch7, `#zc`) | config | `core/compressed_decoder.sv`, `core/instr_realign.sv`, `core/frontend/instr_scan.sv` | `RVC` |
| Zcmt (table jump) | config | `core/zcmt_decoder.sv` | `RVZCMT` |
| Zcb / Zcmp | config / partial | `core/compressed_decoder.sv`, `core/macro_decoder.sv` | target-dependent |
| Zba / Zbb / Zbs bitmanip (ch8, `#bits`) | config | `core/alu.sv`, `core/decoder.sv` | `RVB` |
| Zbc / Zbk* (carry-less / crypto bitmanip) | partial | `core/alu.sv`, `core/aes.sv` | target-dependent |
| Vector V / Zve* (ch9, `#vector`) | **partial (Ara attach)** | No in-core VRF; U10ᵇ Ara: `core/acc_dispatcher.sv`, `core/cva6.sv` `gen_accelerator`, `misa.V` in `core/csr_regfile.sv`; SoC `corev_apu/src/cva6_ara_attach.sv` + `cva6_axi_2to1_mux.sv`; vendor `vendor/ara/{upstream,Flist.ara,cva6_shim/}`; package `cv64a6_server_math_v_config_pkg.sv`. Mutually exclusive with `CvxifEn`. Live Verilator lint under `CVA6_ARA_ATTACH=1`. Software contract: `agents/guides/AGENTS-vector.md`, DTS `corev_apu/bootrom/ariane-server-math-v.dts`, directed `verif/tests/testlist_ara_vector.yaml`. Full RVV cosim / OpenSBI VRF still open | `RVV`, `EnableAccelerator` (`CVA6ConfigVExtEn`) |
| Packed SIMD (ch10, `#zp`) | absent | — | — |
| Scalar crypto Zkn (AES) (ch11, `#crypto`) | partial | `core/aes.sv` | target-dependent |
| Vector crypto Zvk* | absent | (not part of Ara attach baseline) | — |
| Matrix (ch12, `#matrix`) | absent | — | — |

---

## Part II — Privileged Architecture

| Spec (anchor) | Status | Primary RTL loci | Config knob |
|---|---|---|---|
| Privilege levels M/S/U (ch1) | implemented | `core/csr_regfile.sv`, `core/commit_stage.sv` | `PRIV`/mode support (target pkg) |
| CSRs (ch2, `#priv-csrs`) | implemented | `core/csr_regfile.sv`, `core/csr_buffer.sv` | — |
| Reset (3.4, `#reset`) | implemented | `core/cva6.sv`, `core/csr_regfile.sv` (reset values) | — |
| NMI (3.5, `#nmi`) | partial / config | `core/csr_regfile.sv`, `core/controller.sv` | `Smrnmi` |
| PMA — physical memory attributes (3.6, `#pma`) | implemented | region rules in target pkg + `core/cva6.sv`, checked in `check_cfg` | `Nr{Cached,Execute,NonIdempotent}RegionRules` |
| PMP — physical memory protection (3.7, `#pmp`) | implemented | `core/pmp/` | `NrPMPEntries` |
| Sv32 (4.3) | config | `core/cva6_mmu/` | `vm_mode_t` |
| Sv39 (4.4, `#sv39`) | config | `core/cva6_mmu/` | `vm_mode_t` (`ModeSv39`) |
| Sv48 (4.5) | config | `core/cva6_mmu/` | `vm_mode_t` (`ModeSv48`) |
| Sv57 (4.6) | absent | — | — |
| SFENCE.VMA / supervisor instr (4.1-4.2) | implemented | `core/cva6_mmu/`, `core/controller.sv`, `core/csr_regfile.sv` | — |
| Hypervisor H (ch5, `#hypervisor`) | partial (U9.0–U9.2) | `csr_regfile.sv` (HS CSRs + **vstimecmp/STCE/VSTIP/htimedelta** + TIME under V + virtual-instr STCE + HVIP mask), `cva6_mmu/` 2-stage+G-only PTW, HLV/HSV/HFENCE; PLIC 16-ctx | `RVH`, `SstcEn` |
| Smepmp (6.3) | config | `core/pmp/`, `core/csr_regfile.sv` | `Smepmp` |
| Smstateen (6.1) | config | `core/csr_regfile.sv` | `RVS`/stateen bits |
| Smrnmi (6.5) | partial / config | `core/csr_regfile.sv` | `Smrnmi` |
| Smctr / priv-CFI (6.8, 6.9) | absent | — | — |
| Svnapot (7.1) | **implemented (config)** | `cva6_ptw.sv`, `cva6_tlb.sv`, `cva6_shared_tlb.sv` (`is_napot_64k`) | `SvnapotEn` |
| Svpbmt (7.2) | **partial (config)** | PTE `pbmt` in `cva6_mmu.sv`; PTW legality; `menvcfg.PBMTE` / `pbmte_o` in `csr_regfile.sv` (LSU PMA force TBD) | `SvpbmtEn` |
| Svadu / Svinval (7.3–7.4) | partial / absent | A/D mostly SW; no Svinval | — |
| Sstc supervisor timer (8.8) | **implemented (config)** | `stimecmp` + `rtc_time_i` compare + STIP in `csr_regfile.sv`; CLINT mtime SoC-side | `SstcEn` (+ `rtc_time_i`) |
| Sscofpmf (8.9) | **implemented (config)** | `perf_counters.sv` OF/LCOFI; `scountovf` in `csr_regfile.sv`; 8-bit mhpmevent (U8ᵃ) | `SscofpmfEn` |
| Sh hypervisor extensions (ch9) | partial / config | `core/csr_regfile.sv`, `core/cva6_mmu/` | `RVH` |
| Privileged listings / rationale (ch10, appA) | n/a | — | — |

---

## Part III — Profiles

Profiles (`#vol:profiles`) are checklists of mandated extensions, not RTL. A given CVA6 target satisfies
a profile iff its config package enables the required rows above. Status is therefore **config-dependent**;
check the target package against the profile.

| Profile (anchor) | Status | Notes |
|---|---|---|
| RVI20 (`#_rvi20_profiles`) | config | Base integer targets satisfy it. |
| RVA20 (`#_rva20_profiles`) | partial / config | RVA-class 64-bit targets approximate it (verify F/D/C/A/Sv39/counters). |
| RVA22 (`#_rva22_profiles`) | partial / config | Adds Zic*/Sv* mandates — verify per target. |
| RVA23 (`#_rva23_profiles`) | absent / partial | Requires V + newer Ss*/Sm* not in-core. |
| RVB23 (`#_rvb23_profiles`) | absent / partial | As RVA23 (bitmanip-oriented). |

---

## Microarchitectural map (no normative spec section)

These are **integration/micro-arch**, constrained by the ISA only indirectly (they must stay transparent
to architectural results, coherence, ordering, precise traps). See `AGENTS.md` §5 and the guides.

| Feature | Status | Primary RTL loci | Config knob | Guide |
|---|---|---|---|---|
| Branch prediction (BHT/PH_BHT/BTB/RAS + U1 fabric) | **implemented (config)** | `frontend.sv`, `bht*.sv`, `btb.sv`, `ras.sv`, `cva6_bp_{top,tage,gshare,loop,ittage,statcor,ckpt,ghist}.sv`, `branch_unit.sv` | `BPType` (BHT/PH_BHT/GSHARE/TAGE_LITE), `BP*`, `RASDepth` | `agents/guides/AGENTS-branch-prediction.md` |
| Decoupled front-end (U2) | **implemented (config)** | `cva6_ftq.sv`, `cva6_fdip.sv`, `cva6_loop_buffer.sv`, `frontend.sv` | `FtqDepth`, `FdipEn`, `LoopBufEn` | `architecture/speculative-execution/` |
| Speculative execution (in-order, precise) | implemented | `scoreboard.sv`, `issue_read_operands.sv`, `ex_stage.sv`, `commit_stage.sv`, `controller.sv` | `NrScoreboardEntries`, `NrLoadBufEntries`, `MaxOutstandingStores` | `agents/guides/AGENTS-speculation.md` |
| Multi-issue width (superscalar precursor) | **implemented (config)** | `build_config_pkg` (NrIssuePorts 1\|2–8), `id_stage`, `instr_queue`, `issue_read_operands`, `ex_stage`, `scoreboard` free-slot full | `SuperscalarEn`, `NrIssuePorts` | `architecture/out-of-order/` |
| Slice-OoO (U4) | **implemented (off by default)** | `cva6_slice_{ist,steer,iq,rmt,dispatch}.sv`, `issue_stage.sv` | `SliceOoOEn`, `Slice*` | `architecture/out-of-order/` |
| Full OoO (U5) | **implemented (production, gated)** | `core/ooo/*`, cancel-mask recovery, `cv64a6_ooo` / `cv64a6_ooo_server` | `OoOEn`, `NrIssuePorts≤8` | `architecture/out-of-order/` |
| L1 caches (I$ + D$: WT / HPDCACHE / std) | implemented | `core/cache_subsystem/*`; selection `core/cva6.sv` | `DCacheType`, `Icache*`, `Dcache*`, `WayPredEn`, `ReplPolicy` | `agents/guides/AGENTS-l2l3-cache.md` |
| L2 cache (U6.0) | **implemented (config, SoC)** | `corev_apu/l2_cache/*`; wire in `ariane_testharness` when `L2En` | `L2En`, `L2ByteSize`, `L2SetAssoc`, `L2LineWidth`, `L2MshrDepth`, `L2DataBanks` | `architecture/l2-l3-cache/` |
| L3 / multi-core snoop (U6.2) | partial (hub+SF+inv; N=1 identity) | `corev_apu/coherence/cva6_{coherence_pkg,snoop_filter,inval_bus,coherence_hub}.sv` | `NrCores` 1…`CVA6_MAX_CORES`, `CohPolicy`, `SnoopFilter*` | `architecture/multi-core/`, `remaining-upgrade-sequence.md` |
| Multi-threading SMT (U6.1) | implemented (config; OpenSBI R3a) | `core/smt/*`; DTS smt2; `software/smt2-linux` OpenSBI generic+DTB + dual-hart SBI payload | `NrHarts`≤2, `SmtPolicy`, … | `architecture/multi-threading/` + `smt-linux-boot-path` + `smt-linux-rootfs` + `software/smt2-linux/` |
| CVXIF coprocessor / accelerator seam | implemented | `core/cvxif_fu.sv`, `core/acc_dispatcher.sv`, ports `core/cva6.sv` | `CvxifEn`, `EnableAccelerator` (mutually exclusive) | `AGENTS.md` §0.1.5 |
| RVFI trace / debug / PMU (observability) | implemented | `cva6_rvfi*.sv`, `trigger_module.sv`, `perf_counters.sv` (8-bit events U8ᵃ) | `DebugEn`, `PerfCounterEn`, `SscofpmfEn` | `AGENTS.md` §0.1.6 |

---

## Maintenance contract

When an RTL change lands:
1. Update the affected row(s) here — status and/or primary loci (keep `file:line` only where stable).
2. If it changes what is exercised, update `AGENTS-specs-to-tests.md`.
3. Re-derive the affected row(s) of `AGENTS-specs-coverage.md`.
4. If a spec sub-file is missing for the touched chapter, add it and flip its `agents/spec/INDEX.md` row.
5. Follow `AGENTS-coding-philosophy.md` (timing note, review checklist) and `AGENTS-licensing.md` for the
   code itself.
