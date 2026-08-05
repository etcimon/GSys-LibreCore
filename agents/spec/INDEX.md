# Spec substructure guider (`agents/spec/`)

Index of `specs/riscv-spec.html` at `X.y` granularity. Each row is (or will become) one sub-file
`riscv-spec-<Vol>-<X.y>-<slug>.html`. Read `../../AGENTS.md` first for the reasoning and navigation.

- **Domain tags**: `BP` branch prediction, `CACHE` L1/L2/L3 + coherence, `RAM` memory/MMU/PMP,
  `SPEC` speculation/ordering. Untagged rows are ISA-arithmetic and low-priority for the current intents.
- **Status** (sub-file existence): `done` / `exemplar` / `pending` / `n/a`.
- **CVA6 RTL status** for ISA-visible rows is kept in each sub-file’s **CVA6 status** line and
  summarised in `../../AGENTS-specs-to-impl.md` / `../../AGENTS-specs-coverage.md` (refresh on every
  ISA-visible RTL pass). Snapshot after U5–U10 / Ara attach / multi-core stream (2026-07):
  - **Implemented (config):** Zihintpause, Sstc, Sscofpmf, Svnapot, (partial) Zawrs / Zicboz / Zicbop / Svpbmt.
  - **Micro-arch RTL present:** U1 TAGE fabric, U2 FTQ/FDIP/loopbuf, U3 way-pred/RRIP, U4 slice-OoO,
    U5 full OoO (gated), multi-issue width 2–8, U6 L2/L3 + multicore hub, SMT2, U9 H/Sstc path.
  - **RVV (Vol I ch9):** **partial** — not in-core; U10ᵇ Ara attach behind `EnableAccelerator` /
    `CVA6Cfg.RVV` (`cv64a6_server_math_v`, `g6lc_ara_attach`, `vendor/ara/`); live lint under
    `CVA6_ARA_ATTACH=1`. Sub-file: `riscv-spec-I-9-vector.html`. Vector crypto `zvk*` still absent.
- **Anchor** is the fragment in `specs/riscv-spec.html#<anchor>`; **Src** is the source line.

---

## Part I — Unprivileged Architecture (`#vol:unpriv`, src 1172)

### 1. Introduction (`#_introduction`)
| X.y | Title | Anchor | Src | Domain | Sub-file | Status |
|---|---|---|---|---|---|---|
| 1.4 | Memory | `#sec:intro-memory` | 3858 | RAM | `riscv-spec-I-1.4-memory.html` | done |
| 1.6 | Exceptions, Traps, Interrupts | `#trap-defn` | — | SPEC | `riscv-spec-I-1.6-traps.html` | done |
| 1.1-1.3,1.5,1.7 | Terminology / overview / encoding | (various) | — | — | — | n/a |

### 2. Base Instruction Sets (`#base`)
| X.y | Title | Anchor | Domain | Sub-file | Status |
|---|---|---|---|---|---|
| 2.1 | RV32I (JAL/JALR/branches) | `#rv32` | BP | `riscv-spec-I-2.1-rv32i.html` | done |
| 2.2 | RV64I | `#rv64` | — | — | done |
| 2.3 | RV32E/RV64E | `#rv32e` | — | — | n/a |

### 3. Memory Models (`#mm`)
| X.y | Title | Anchor | Src | Domain | Sub-file | Status |
|---|---|---|---|---|---|---|
| 3.1 | RVWMO Memory Consistency Model | `#memorymodel` | 6600 | CACHE RAM SPEC | `riscv-spec-I-3.1-rvwmo.html` | **exemplar** |
| 3.2 | Ztso Total Store Ordering | `#ext:ztso` | — | SPEC | `riscv-spec-I-3.2-ztso.html` | done |

### 4. Scalar Integer Extensions (`#zi`)
| X.y | Title | Anchor | Src | Domain | Sub-file | Status |
|---|---|---|---|---|---|---|
| 4.1 | Zifencei (FENCE.I) | `#ext:zifencei` | 8880 | BP SPEC | `riscv-spec-I-4.1-zifencei.html` | **exemplar** |
| 4.9 | Ziccif (fetch atomicity) | `#ext:ziccif` | — | RAM | `riscv-spec-I-4.9-ziccif.html` | done |
| 4.10 | Ziccid (I/D coherence) | `#_ziccid_extension_for_instructiondata_coherence_and_consistency` | — | CACHE | `riscv-spec-I-4.10-ziccid.html` | done |
| 4.11 | Ziccrse (reservability) | `#ext:ziccrse` | — | RAM SPEC | — | done |
| 4.14 | Zicclsm (misaligned) | `#ext:zicclsm` | — | RAM | `riscv-spec-I-4.14-zicclsm.html` | done |
| 4.15 | Zic64b (64-byte blocks) | `#ext:zic64b` | 10978 | CACHE | `riscv-spec-I-4.15-zic64b.html` | done |
| 4.17 | Control-Flow Integrity (CFI) | `#unpriv-cfi` | 11109 | BP | `riscv-spec-I-4.17-cfi.html` | done |
| 4.18 | Zihintntl (non-temporal) | `#ext:zihintntl` | — | CACHE | — | done |
| 4.19 | Zihintpause | `#ext:zihintpause` | — | SPEC | — | done |
| 4.20 | Cache Management Ops (CMO) | `#cmo` | 12653 | CACHE | `riscv-spec-I-4.20-cmo.html` | done |
| 4.2-4.8,4.12,4.13,4.16 | Zicsr/Zicntr/M/Zmmul/Zicond/... | (various) | — | — | — | done |

### 5. Atomic Instructions (`#za`)
| X.y | Title | Anchor | Src | Domain | Sub-file | Status |
|---|---|---|---|---|---|---|
| 5.1 | A Extension | `#ext:a` | 14288 | SPEC RAM | `riscv-spec-I-5.1-a.html` | done |
| 5.2 | Zalrsc (LR/SC) | `#ext:zalrsc` | — | SPEC | `riscv-spec-I-5.2-zalrsc.html` | done |
| 5.5 | Zawrs (wait-on-reservation) | `#ext:zawrs` | 14761 | SPEC | `riscv-spec-I-5.5-zawrs.html` | done |
| 5.6 | Zaamo (AMOs) | `#ext:zaamo` | — | RAM | — | done |
| 5.7 | Zalasr (acquire/release) | `#ext:zalasr` | — | SPEC | — | done |
| 5.9 | Zacas (CAS) | `#ext:zacas` | — | SPEC | — | done |
| 5.3,5.4,5.8,5.10 | Za128rs/Za64rs/Zabha/Zama16b | (various) | — | RAM | — | done |

### 6-12 + Appendices (ISA-arithmetic, low priority for current intents)
| Ch | Title | Anchor | Status |
|---|---|---|---|
| 6 | Scalar Floating-Point (F/D/Q/Zfh/...) | `#zf` | done |
| 7 | Compressed (Zca..Zcmop) | `#zc` | done |
| 8 | Bit Manipulation (Zba/Zbb/Zbs/B/...) | `#bits` | done |
| 9 | Vector (Zve*/V/Zvfh/...) | `#vector` | done (CVA6: **partial** Ara RVV attach — see sub-file) |
| 10 | Packed SIMD | `#zp` | n/a |
| 11 | Cryptography (scalar/vector) | `#crypto` | done |
| 12 | Matrix | `#matrix` | n/a |
| A-E | Listings / Memory-model supplement / Naming / Examples / Rationale | `#app:mm` ... | done (B=SPEC) |

---

## Part II — Privileged Architecture (`#vol:priv`, src 67256)

### 1. Introduction (`#_introduction_2`) — 1.1-1.3 privilege levels / debug — done

### 2. Control and Status Registers (`#priv-csrs`) — 2.1-2.7 — done

### 3. Machine-Level ISA (`#machine`)
| X.y | Title | Anchor | Src | Domain | Sub-file | Status |
|---|---|---|---|---|---|---|
| 3.4 | Reset | `#reset` | — | — | — | done |
| 3.5 | Non-Maskable Interrupts | `#nmi` | — | SPEC | — | done |
| 3.6 | Physical Memory Attributes | `#pma` | 75927 | RAM CACHE | `riscv-spec-II-3.6-pma.html` | **exemplar** |
| 3.7 | Physical Memory Protection | `#pmp` | 76569 | RAM | `riscv-spec-II-3.7-pmp.html` | **exemplar** |
| 3.1-3.3 | M-level CSRs / MM regs / priv instr | (various) | — | — | — | done |

### 4. Supervisor-Level ISA (`#supervisor`)
| X.y | Title | Anchor | Src | Domain | Sub-file | Status |
|---|---|---|---|---|---|---|
| 4.3 | Sv32 | `#sv32` | — | RAM | `riscv-spec-II-4.3-sv32.html` | done |
| 4.4 | Sv39 | `#sv39` | 79453 | RAM | `riscv-spec-II-4.4-sv39.html` | **exemplar** |
| 4.5 | Sv48 | `#sv48` | — | RAM | `riscv-spec-II-4.5-sv48.html` | done |
| 4.6 | Sv57 | `#sv57` | — | RAM | — | done |
| 4.1-4.2 | Supervisor CSRs / instructions (SFENCE.VMA) | (various) | — | RAM | — | done |

### 5. H Extension (Hypervisor) (`#hypervisor`)
| X.y | Title | Anchor | Domain | Status |
|---|---|---|---|---|
| 5.5 | Two-Stage Address Translation | `#two-stage-translation` | RAM | done |
| 5.1-5.4,5.6 | Modes / CSRs / instructions / traps | (various) | — | done |

### 6. Sm Machine Extensions (`#sm`)
| X.y | Title | Anchor | Src | Domain | Status |
|---|---|---|---|---|---|
| 6.3 | Smepmp (PMP enhancements) | `#smepmp` | — | RAM | done |
| 6.8 | Smctr (Control Transfer Records) | `#smctr` | 85550 | BP | done |
| 6.9 | Control-Flow Integrity (CFI) | `#priv-cfi` | — | BP | done |
| 6.1,6.2,6.4-6.7,6.10 | Smstateen/indirect-csr/... | (various) | — | done |

### 7. Sv Supervisor Virtual-Memory Extensions (`#sv`)
| X.y | Title | Anchor | Domain | Status |
|---|---|---|---|---|
| 7.1 | Svnapot (NAPOT contiguity) | `#ext:svnapot` | RAM CACHE | done |
| 7.2 | Svpbmt (page-based memory types) | `#ext:svpbmt` | CACHE RAM | done |
| 7.3 | Svadu (HW A/D update) | `#ext:svadu` | RAM | done |
| 7.4 | Svinval (fine-grained TLB inval) | `#ext:svinval` | RAM | done |
| 7.5,7.6 | Svvptc / Svrsw60t59b | (various) | RAM | done |

### 8. Ss Supervisor Extensions (`#ss`)
| X.y | Title | Anchor | Domain | Status |
|---|---|---|---|---|
| 8.1 | Ssqosid (QoS identifiers) | `#ssqosid` | CACHE | done |
| 8.8 | Sstc (supervisor timer) | `#Sstc` | — | done |
| 8.2-8.7,8.9,8.10 | Ssu64xl/Ssccptr/... | (various) | — | done |

### 9. Sh Hypervisor Extensions (`#sh`) — 9.1-9.7 — done
### 10. Privileged Instruction Set Listings (`#_risc_v_privileged_instruction_set_listings`) — done
### Appendix A — Historical Rationale (`#app:priv-rationale`) — done

---

## Part III — Profiles (`#vol:profiles`, src 89395)

Profiles declare mandated extension sets; they are the checklist a config + `.dts` must satisfy.
| X.y | Title | Anchor | Domain | Sub-file | Status |
|---|---|---|---|---|---|
| 1.x | Introduction / components / RVA rationale | `#_introduction_6` | — | `riscv-spec-III-1-intro.html` | done |
| 2.x | RVI20 Profiles | `#_rvi20_profiles` | — | — | done |
| 3.x | RVA20 Profiles | `#_rva20_profiles` | ALL | `riscv-spec-III-3-rva20.html` | done |
| 4.x | RVA22 Profiles | `#_rva22_profiles` | ALL | `riscv-spec-III-4-rva22.html` | done |
| 5.x | RVA23 Profiles | `#_rva23_profiles` | ALL | `riscv-spec-III-5-rva23.html` | done |
| 6.x | RVB23 Profiles | `#_rvb23_profiles` | ALL | — | done |

---

## Spec-complete pass sub-file map

The following grouped or chapter-level files cover rows where multiple X.y subchapters are summarized
together. Per-X.y files created in this pass are already listed in the tables above.

| Group | Sub-file |
|---|---|
| Vol I 1.1-1.3,1.5,1.7 (terminology) | `riscv-spec-I-1-introduction.html` |
| Vol I 2.2 RV64I | `riscv-spec-I-2.2-rv64i.html` |
| Vol I 4.2-4.8,4.12,4.13,4.16 (Zicsr/Zicntr/M/Zmmul/Zicond) | `riscv-spec-I-4-scalar-integer-low.html` |
| Vol I 4.11 Ziccrse | `riscv-spec-I-4.11-ziccrse.html` |
| Vol I 4.18 Zihintntl | `riscv-spec-I-4.18-zihintntl.html` |
| Vol I 4.19 Zihintpause | `riscv-spec-I-4.19-zihintpause.html` |
| Vol I 5.3/5.4/5.8/5.10 (Za128rs/Za64rs/Zabha/Zama16b) | `riscv-spec-I-5.3-za128rs.html`, `I-5.4-za64rs.html`, `I-5.8-zabha.html`, `I-5.10-zama16b.html` |
| Vol I chapter 6 Floating-Point | `riscv-spec-I-6-floating-point.html` |
| Vol I chapter 7 Compressed | `riscv-spec-I-7-compressed.html` |
| Vol I chapter 8 Bit-Manipulation | `riscv-spec-I-8-bitmanip.html` |
| Vol I chapter 9 Vector | `riscv-spec-I-9-vector.html` |
| Vol I chapter 10 Packed SIMD | `riscv-spec-I-10-packed.html` |
| Vol I chapter 11 Cryptography | `riscv-spec-I-11-crypto.html` |
| Vol I chapter 12 Matrix | `riscv-spec-I-12-matrix.html` |
| Vol I appendices A-E | `riscv-spec-I-appA-E.html` |
| Vol II 1.1-1.3 (privileged intro/debug) | `riscv-spec-II-1-intro.html` |
| Vol II 2.1-2.7 (CSRs) | `riscv-spec-II-2-csrs.html` |
| Vol II 3.1-3.3 (M-level CSRs/instructions) | `riscv-spec-II-3-machine-level.html` |
| Vol II 3.4 Reset | `riscv-spec-II-3.4-reset.html` |
| Vol II 3.5 NMI | `riscv-spec-II-3.5-nmi.html` |
| Vol II 4.1 Supervisor CSRs | `riscv-spec-II-4.1-supervisor-csrs.html` |
| Vol II 4.2 Supervisor instructions | `riscv-spec-II-4.2-supervisor-instructions.html` |
| Vol II 4.6 Sv57 | `riscv-spec-II-4.6-sv57.html` |
| Vol II 5.1-5.4,5.6 (H modes/CSRs/instructions/traps) | `riscv-spec-II-5.1-hypervisor-modes.html`, `II-5.2-hypervisor-csrs.html`, `II-5.3-hypervisor-instructions.html`, `II-5.4-mlevel-csrs-hypervisor.html`, `II-5.6-hypervisor-traps.html` |
| Vol II 5.5 Two-Stage Translation | `riscv-spec-II-5.5-two-stage-translation.html` |
| Vol II 6.1/6.2/6.4/6.5/6.6/6.7/6.10 (Sm*) | `riscv-spec-II-6.1-smstateen.html`, `II-6.2-smcsrind.html`, `II-6.4-smcntrpmf.html`, `II-6.5-smrnmi.html`, `II-6.6-smcdeleg.html`, `II-6.7-smdbltrp.html`, `II-6.10-pointer-masking.html` |
| Vol II 6.3 Smepmp | `riscv-spec-II-6.3-smepmp.html` |
| Vol II 6.8 Smctr | `riscv-spec-II-6.8-smctr.html` |
| Vol II 6.9 Priv-CFI | `riscv-spec-II-6.9-priv-cfi.html` |
| Vol II 7.1-7.4,7.5-7.6 (Sv*) | `riscv-spec-II-7.1-svnapot.html`, `II-7.2-svpbmt.html`, `II-7.3-svadu.html`, `II-7.4-svinval.html`, `II-7.5-svvptc.html`, `II-7.6-svrsw60t59b.html` |
| Vol II 8.1-8.10 (Ss*) | `riscv-spec-II-8.1-ssqosid.html`, `II-8.2-ssu64xl.html`, `II-8.3-ssccptr.html`, `II-8.4-sstvecd.html`, `II-8.5-sstvala.html`, `II-8.6-sscounterenw.html`, `II-8.7-ssstrict.html`, `II-8.8-sstc.html`, `II-8.9-sscofpmf.html`, `II-8.10-ssdbltrp.html` |
| Vol II chapter 9 Sh hypervisor extensions | `riscv-spec-II-9-hypervisor-extensions.html` |
| Vol II chapter 10 Privileged listings | `riscv-spec-II-10-privileged-instruction-set-listings.html` |
| Vol II Appendix A | `riscv-spec-II-appA-priv-rationale.html` |
| Vol III 1.x Introduction | `riscv-spec-III-1-intro.html` |
| Vol III 2.x RVI20 | `riscv-spec-III-2-rvi20.html` |
| Vol III 3.x RVA20 | `riscv-spec-III-3-rva20.html` |
| Vol III 4.x RVA22 | `riscv-spec-III-4-rva22.html` |
| Vol III 5.x RVA23 | `riscv-spec-III-5-rva23.html` |
| Vol III 6.x RVB23 | `riscv-spec-III-6-rvb23.html` |

## Backfill protocol

To add a sub-file: create `riscv-spec-<Vol>-<X.y>-<slug>.html` following the conventions in
`../../AGENTS.md` section 7, then flip its **Status** here to `done`. Do not restructure this index;
append rows only. Priority order tracks the four domains: RAM/CACHE (3.x/4.x/PMA/PMP/Sv), then SPEC
(RVWMO/atomics/fences), then BP (CFI/CTR), then Profiles, then the low-priority arithmetic chapters.
