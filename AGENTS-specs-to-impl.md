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
| C compressed (ch7, `#zc`) | config | `core/compressed_decoder.sv` (identity `c.li`; SMT+SS G1ba leftover-RVI mash recover), `core/instr_realign.sv`, `core/frontend/instr_scan.sv` | `RVC` |
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
| CSRs (ch2, `#priv-csrs`) | implemented | `core/csr_regfile.sv`, `core/csr_buffer.sv`, `core/smt/g6lc_smt_csr_bank.sv` (G1dz: `csr_rdata`/`csr_exception` mux by commit hart) | — |
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
| Multi-issue width (superscalar precursor) | **implemented (config)** | `build_config_pkg` (NrIssuePorts 1\|2–8), `id_stage` (G1be same-line dest-before-Branch; G1cy leftover-Jump before later-slot fallthrough; G1em older CSR-to-a0 before a0-Branch; G1ev older ALU-to-a0 before a0-Branch; G1id mid-line 01 Branch on same line as aligned compressed Branch is JALR; G1ij mid-line 01 Branch whose 16-bit is not a Branch encoding follows that 16-bit; G1ik ID-visible aligned Branch arms same-line 01 recover; G1il aligned-Branch recover latch survives flush_i; G1io aligned npc + same-line I$ slot0 is I$[15:0]; G1ip leftover slot0 stays slot1 is I$[15:0] at aligned npc; G1iq stash aligned I$[15:0] compressed Branch present at aligned npc; G1ir G1ie arms from G1iq stash; G1it G1iq capture [15:0] Branch when I$ vaddr is mid-line 01; G1iu G1iq capture [15:0] Branch when npc is mid-line 01 on same I$ line; G1iw same-cycle sibling-half [15:0] Branch recovers mid-line 01; G1ix bp_valid must not kill_s2 while npc is mid-line 01), `frontend.sv` (G1ct dest-only mispredict beat; G1cz leftover-Jump slot0-only; G1ep consumed mid-line sequential-next I$ hold; G1fu fetch pc+2 after slot0-only compressed Branch consume; G1fv npc +2 when aligned compressed Branch presented slot0-only; G1fw npc +2 when IQ view is slot0-only compressed Branch; G1fy npc +2 when IQ view is slot0-only rvc_branch; G1ga npc +2 when IQ slot0 Branch and slot1 JumpR; G1gb npc +2 when frontend slot0 Branch and slot1 JumpR; G1gc npc +2 frontend Branch|JumpR even when leftover; G1gd npc +2 frontend Branch|JumpR even when bp_valid; G1ge after JumpR commit accept target I$ even if leftover jal unconsumed; G1gg jalr prefer usable RF over unusable forward; G1gp jalr resolve uses usable RF when operand_a is unusable; G1gq committed JALR redirects to RF[rs1] after unusable JumpR resolve; G1gs JALR resolve is JumpR even if RAS tagged Return; G1gu recover high-half c.jalr only when low is RVI BRANCH; G1gw mid-line exact c.jalr encoding forces JALR; G1gx mid-line slot0 is the 16-bit at that PC not leftover-complete; G1gy mid-line either-half exact c.jalr forces JALR; G1ha I$ +2 halfword only when exact c.jalr; G1hb slot1 from I$ +2 exact c.jalr even if valid; G1hc leftover-complete beat still presents I$ +2 c.jalr as slot1; G1hd issued op is JALR when mid-line fetch has exact c.jalr; G1hf mid-line !Branch usable-RF is JumpR; G1hg mid-line Branch orig 16-bit exact c.jalr is JumpR; G1hh any mid-line 01 slot from I$ +2 exact c.jalr; G1hi mid-line 01 from live I$ +2 exact c.jalr without same-line; G1hj stash aligned I$ +2 exact c.jalr fill mid-line 01; G1hk present slot0 at npc from stash when npc mid-line 01; G1jk G1hj/G1hk/G1hl present only at the captured +2 PC; G1jl sibling pair Branch+[31:16] c.jalr into PC-matched G1hj; G1jm keep registered aligned compressed-Branch I$ until +2 presented; G1jn spare kill_s2 when returning I$ is npc-00 same-line compressed Branch; G1jo replay must not kill_s1 while npc is aligned 00; G1jq leftover Jump must not flush/mispredict-kill s1 while npc is aligned 00; G1jt is_mispredict must not kill_s1 while npc is aligned 00; G1ju G1hj +2 c.jalr stash survives leftover Jump flush_i; G1jv G1hj capture beats flush_i clear; G1jx IDLE sibling-pair capture only when npc is the sibling +2 PC; G1jy latch IDLE aligned-00 sibling pair present only at npc +2 01; G1jz IDLE sibling latch +2 PC from last I$ return vaddr; G1ka present live user[33] pair at npc == last-return +2; G1kb slot0-only aligned compressed keeps +2 c.jalr even if slot0 is not Branch; G1kc leftover slot1 present of G1jy stash at npc-matched +2; G1kd G1jy capture without last-return +2 PC from current I$ sibling; G1ke same-line IDLE pair into G1jy; G1kf registered I$ same-line pair into G1jy; G1kg same-line pair on kill_s2 into G1jy; G1kh kill_s2 sibling user[33] pair into G1jy; G1kj npc-matched sibling pair into G1jy with full +2 PC; G1kk aligned-00 RVI LOAD rd recovers sibling 01 Branch as c.jalr; G1kl present G1kk c.jalr at npc 01 of the LOAD's sibling 8-byte half; G1km leftover slot1 present of G1kk c.jalr at npc sibling 01; G1kn aligned-00 RVI LOAD from I$ data into G1kk; G1ko G1kk survives leftover Jump flush_i; G1kp G1kk capture beats flush_i; G1kq G1kk survives leftover Jump is_mispredict; G1kr G1kk survives is_mispredict at npc 00; G1ks G1kk consume only at sibling 01; G1kt G1kk keep-until-sibling-01; G1ku G1kk I$ capture only when npc is on the same 16-byte line; G1kv present-path G1kk capture only when npc is on the same 16-byte line; G1kw G1kk from registered I$ aligned-00 RVI LOAD when npc is on the same 16-byte line; G1kx npc-line LOAD recapture may replace a held different-line LOAD; G1ky leftover slot1 G1kk present from same-cycle I$ LOAD cap at npc sibling 01; G1kz G1kl slot0 present from same-cycle I$ LOAD cap at npc sibling 01; G1la G1kl does not skip leftover 11 when G1kk sibling 01 matches; G1lb I$ aligned-00 RVI LOAD may replace G1kk even when npc is off that line; G1lc I$ LOAD recapture only when G1kk is empty; G1ld restore G1ku npc-line on g1kn; G1le last I$ aligned-00 RVI LOAD side-stash present at sibling 01; G1lf g1le keep-until-sibling-01; G1lg npc-line recapture may replace a held different-line g1le; G1lh present-path aligned-00 RVI LOAD into g1le; G1li registered I$ aligned-00 RVI LOAD into g1le; G1lj leftover slot1 g1le present from same-cycle I$/registered LOAD cap; G1lk G1kl from no-npc-line g1lj_cap reverted (cookie t=206848); G1ll G1kl from same-cycle g1le I$/registered LOAD cap with npc-line; G1lm IQ aligned-00 RVI LOAD sibling 01 recover reverted (FDT 106); G1ln ID-visible aligned-00 RVI LOAD arms sibling 01 Branch recover; G1lo ID latch of aligned-00 RVI LOAD survives flush_i; G1lp g1lo keep-until sibling 01; G1lq IQ-visible aligned-00 RVI LOAD into g1lo_cap; G1lr g1lq keep-until sibling 01; G1ls present-path instruction_valid 00 LOAD into g1lq_cap; G1lt live I$ aligned-00 RVI LOAD into g1lq_cap; G1lu registered I$ aligned-00 RVI LOAD into g1lq_cap; G1lv leftover slot1 g1lq present at npc sibling 01; G1lw G1kl slot0 from g1lq_hit; G1lx g1lq overwrite of g1lo_cap gated to empty or fetch 01 line; G1ly same-line g1lq overwrite of held g1lo; G1lz per-hart g1lo LOAD latch (peer 00 LOAD must not occupy hart0); G1ma per-hart g1lq IQ LOAD latch + sideband; G1mb per-hart g1le I$ LOAD side-stash; G1mc per-hart G1kk LOAD recover latch; G1md commit-visible aligned-00 RVI LOAD into g1lo; G1me g1lo commit capture beats flush_i; G1mf SB result-valid aligned-00 RVI LOAD into g1lo; G1hl leftover-complete slot1 from stash at npc mid-line 01; G1hm leftover-complete slot1 at stashed +2 PC; G1hn capture I$ [31:16] exact c.jalr even if vaddr not aligned; G1ho capture [15:0] exact c.jalr when vaddr mid-line 01; G1hp capture exact c.jalr from g1gx_data either half; G1hq capture incoming I$ +2 exact c.jalr even if fill is not registered; G1hr capture incoming I$ +2 exact c.jalr on kill_s2 even if valid is muted; G1hs leftover-complete Jump must not replay-kill I$ s1; G1ht replay must not kill_s1 while npc is mid-line 01; G1hv leftover Jump must not flush_i-kill s1 while npc is mid-line 01; G1hw leftover Jump must not is_mispredict-kill s1 while npc is mid-line 01; G1hx same-line +2 duplicate compressed Branch is JALR; G1hy aligned packet high-half c.jalr recovers mid-line 01 Branch; G1hz slot0-only aligned Branch keeps +2 c.jalr in instruction[31:16]; G1ia compressed +2 slot is the 16-bit at that PC not {+4,+2} mash; G1ib slot0-only must not hide a live +2 exact c.jalr; G1ic leftover-PC I$ must not present while npc is mid-line 01; G1ie frontend latch of aligned compressed Branch recovers same-line 01 Branch as c.jalr; G1ir G1ie arms from G1iq stash; G1it G1iq capture [15:0] Branch when I$ vaddr is mid-line 01; G1iu G1iq capture [15:0] Branch when npc is mid-line 01 on same I$ line; G1iw same-cycle sibling-half [15:0] Branch recovers mid-line 01; G1ji G1ie arms from G1iw sibling-half compressed Branch keep-until-01; G1ix bp_valid must not kill_s2 while npc is mid-line 01; G1jb aligned-Branch recover stash/latch not replaced by a different 8-byte line until that line's mid-line 01 is presented; G1jc first leftover-RVI I$ steal at npc 01 still issues npc 8-byte line once; G1jg first sequential-next 8-byte I$ at npc 01 still issues npc 8-byte line once; G1ih IQ output recovers same-line 01 Branch as c.jalr; G1ii IQ input latches aligned Branch for later +2 recover; G1gh leftover jal x0 waits for same-hart jalr commit; G1gi do not present leftover jal x0 while jalr in flight; G1gj do not present leftover jal x0 while npc is mid-line 01; G1gk hold leftover jal x0 hide 3 cycles after mid-line 01; G1gl do not reseed npc to leftover-PC replay after mid-line 01; G1gm do not reseed npc to leftover-PC replay while jalr has been seen; G1eq aligned I|I CSR not hidden; G1fr dest-only beat keeps later-slot JumpR; G1ft leftover-Jump slot0-only keeps later-slot JumpR; G1et fill missing aligned I|I CSR from I$; G1fq fill missing aligned compressed slot1 c.jalr from I$; G1ex dest-FIFO CSR-to-a0 different-line I$ hold; G1ez leftover-complete NoCF dest I$ hold; G1fa reject I$ ahead of npc), `instr_queue` (G1da leftover-Jump `idx_is` first push; G1dc leftover-Jump IQ head; G1em older CSR-to-a0 over rotate head; G1en leftover jal x0 vs queued CSR-to-a0; G1er aligned I|I CSR through branch_mask; G1fs Branch\|JumpR through branch_mask; G1ey dest-FIFO a0-Branch vs queued CSR-to-a0; G1fd mid-line consume wait before later a0-Branch; G1fe aligned I|I CSR-to-a0 data hides dest-FIFO a0-Branch; G1ff registered I$ I|I CSR-to-a0 hides later dest-FIFO a0-Branch; G1fi mid-line presentation wait before later a0-Branch; G1fj hold mid-line wait through sequential next; G1fl hide later a0-Branch until next line consumed; G1fo leftover jal x0 waits for dest-FIFO JumpR; G1fp leftover jal x0 waits for presented JumpR), `issue_read_operands`, `ex_stage`, `scoreboard` free-slot full, `g6lc_issue_barrier` (G1bh prefix through unresolved Branch; G1em a0-Branch vs ID CSR-to-a0; G1fh a0-Branch until seen CSR-to-a0 commits) | `SuperscalarEn`, `NrIssuePorts` | `architecture/out-of-order/` |
| Slice-OoO (U4) | **implemented (off by default)** | `cva6_slice_{ist,steer,iq,rmt,dispatch}.sv`, `issue_stage.sv` | `SliceOoOEn`, `Slice*` | `architecture/out-of-order/` |
| Full OoO (U5) | **implemented (production, gated)** | `core/ooo/*`, cancel-mask recovery, `cv64a6_ooo` / `cv64a6_ooo_server` | `OoOEn`, `NrIssuePorts≤8` | `architecture/out-of-order/` |
| L1 caches (I$ + D$: WT / HPDCACHE / std) | implemented | `core/cache_subsystem/*`; selection `core/cva6.sv` | `DCacheType`, `Icache*`, `Dcache*`, `WayPredEn`, `ReplPolicy` | `agents/guides/AGENTS-l2l3-cache.md` |
| L2 cache (U6.0) | **implemented (config, SoC)** | `corev_apu/l2_cache/*`; wire in `ariane_testharness` when `L2En` | `L2En`, `L2ByteSize`, `L2SetAssoc`, `L2LineWidth`, `L2MshrDepth`, `L2DataBanks` | `architecture/l2-l3-cache/` |
| L3 / multi-core snoop (U6.2) | partial (hub+SF+inv; N=1 identity) | `corev_apu/coherence/cva6_{coherence_pkg,snoop_filter,inval_bus,coherence_hub}.sv` | `NrCores` 1…`CVA6_MAX_CORES`, `CohPolicy`, `SnoopFilter*` | `architecture/multi-core/`, `remaining-upgrade-sequence.md` |
| Multi-threading SMT (U6.1) | implemented (config; OpenSBI R3a) | `core/smt/*` (`g6lc_lj_hide` leftover jal-x0 squash + G1gi–gm hide/replay; `g6lc_leftover` leftover-RVI classify; `g6lc_present` E9 mid-line 16-bit + hc/hh npc 01 + hm Jump-only (lo11_npc00 MINI-FAIL; lo_pc_npc00 HOLD-FAIL; lo_ld_stay HOLD-FAIL; hi8_lo11 MINI-FAIL G1jd; ljx0_off/ljx0_pc/ljx0_bp/lo_ld_lo11/leftover_off_npc00/leftover_nx8_npc00 hygiene; leftover_slot0_off_npc00 MINI-FAIL); `g6lc_lj_hide` leftover jal x0 PC latch; `g6lc_fe_kill` sib_lo_s2 MINI-FAIL G1jp; leftover_hi8_s2 MINI-FAIL G1hu; leftover_lo8_s2 hygiene; load00_lo8_s2 hygiene; `g6lc_sib_cjalr` load_flush_next16 hygiene; `g6lc_fe_keep` ld_until_01 MINI-FAIL G1lm; load00_vs_off16 hygiene; load00_vs_lj hygiene; `g6lc_sib_cjalr` E4 sibling-01 leftover_blocks_01; `g6lc_iq_hide` E8 IQ hide; `g6lc_fe_kill` E7 I$ kill spares; FSM/mux in `instr_realign.sv` / `frontend.sv` / `id_stage.sv` / `instr_queue.sv`); `cva6.sv` SMT_COLD_EXCL (G1df WFI; G1dg DRAM+grace); DTS smt2; `software/smt2-linux` OpenSBI generic+DTB + dual-hart SBI payload | `NrHarts`≤2, `SmtPolicy`, … | `architecture/multi-threading/` + `smt-linux-boot-path` + `smt-linux-rootfs` + `software/smt2-linux/` |
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
