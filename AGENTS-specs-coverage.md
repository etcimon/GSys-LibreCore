# AGENTS-specs-coverage.md — RISC-V spec coverage summary

A **status-only** summary of which RISC-V specification chapters CVA6 implements and tests. This is the
headline view: it deliberately carries **no file references and no line numbers** — a chapter marked
*Implemented & tested* means the behavior exists in RTL *and* is exercised by the test flow, nothing more.

- This file is **derived**, not authored: a chapter's status comes from `AGENTS-specs-to-impl.md`
  (does the RTL implement it?) and `AGENTS-specs-to-tests.md` (does a suite exercise it?). To find the
  *where*, open those two maps; this file intentionally omits it.
- Chapter numbering and anchors follow `agents/spec/INDEX.md`.

> **Standing discipline (see `AGENTS.md`).** Re-derive the affected rows here whenever
> `AGENTS-specs-to-impl.md` or `AGENTS-specs-to-tests.md` changes. Do not hand-edit a status without a
> corresponding change in one of those two source maps.

---

## Status legend and derivation

| Status | Derivation (from the two source maps) |
|---|---|
| `Implemented & tested` | RTL implements it (`implemented`/`config`) **and** a suite exercises it. |
| `Implemented (limited test)` | RTL implements it, but coverage is indirect/randomized/config-only. |
| `Partial` | Subset only, hint-only (NOP), or incomplete extension. |
| `Not implemented` | Absent from all shipped configs. |
| `N/A` | Non-normative or microarchitectural (no ISA behavior to certify). |

**Config caveat**: many rows are per-target. A status reflects the *maximal* capability across shipped
configs; a specific build may have less. Use the source maps + the target's profile to confirm.

---

## Part I — Unprivileged Architecture

| Chapter / feature | Status |
|---|---|
| Base RV32I / RV64I | Implemented & tested |
| Address space & memory (1.4) | Implemented & tested |
| Exceptions / traps / interrupts (1.6) | Implemented & tested |
| RVWMO memory model (3.1) | Implemented (limited test; single-hart directed in `spec-deep-tests`) |
| Ztso total store ordering (3.2) | Not implemented |
| Zifencei — FENCE.I (4.1) | Implemented & tested |
| Zicsr — CSR instructions | Implemented & tested |
| Zicntr / Zihpm — counters | Implemented (limited test) |
| M / Zmmul — multiply/divide | Implemented & tested |
| Zicond — conditional zero | Partial |
| Ziccif — fetch atomicity (4.9) | Implemented (limited test) |
| Ziccid — I/D coherence (4.10) | Implemented & tested |
| Zicclsm — misaligned access (4.14) | Partial |
| Zic64b — 64-byte blocks (4.15) | Implemented (limited test) |
| Control-Flow Integrity — Zicfilp/Zicfiss (4.17) | Not implemented |
| Zihintntl — non-temporal hints (4.18) | Partial |
| Zihintpause (4.19) | Implemented (config; limited test) |
| Cache-Management Ops — Zicbom/Zicboz/Zicbop (4.20) | Zicbom partial; **Zicboz full-line multi-beat (U7ᶜ)**; Zicbop HINT |
| A — atomics (5.1) | Implemented & tested |
| Zalrsc — LR/SC (5.2) | Implemented & tested |
| Zawrs — wait-on-reservation (5.5) | Partial (config; WRS→WFI path) |
| Zacas — compare-and-swap (5.9) | Partial (AMOCAS.W/D on smt2/server_math/ooo_server + DTS; Q absent) |
| Other Za* (Za128rs/Za64rs/Zabha/Zaamo/Zalasr) | Partial |
| F / D — floating point (ch6) | Implemented & tested |
| Q — quad float | Not implemented |
| Zfh — half float | Partial |
| C — compressed (ch7) | Implemented & tested |
| Zcmt — table jump | Implemented (limited test) |
| Zcb / Zcmp | Partial |
| Zba / Zbb / Zbs — bit-manipulation (ch8) | Implemented (limited test) |
| Zbc / Zbk* — carry-less / crypto bitmanip | Partial |
| V / Zve* — vector (ch9) | Partial (Ara attach; DTS v+zve64d on server-math-v only; opensbi A2; full cosim open) |
| Packed SIMD (ch10) | Not implemented |
| Zkn — scalar crypto / AES (ch11) | Partial |
| Zvk* — vector crypto | Not implemented |
| Matrix (ch12) | Not implemented |

---

## Part II — Privileged Architecture

| Chapter / feature | Status |
|---|---|
| Privilege levels M / S / U (ch1) | Implemented & tested |
| Control & Status Registers (ch2) | Implemented & tested |
| Reset (3.4) | Implemented (limited test) |
| Non-Maskable Interrupts (3.5) | Partial |
| Physical Memory Attributes — PMA (3.6) | Implemented & tested |
| Physical Memory Protection — PMP (3.7) | Implemented & tested |
| Sv32 paging (4.3) | Implemented & tested |
| Sv39 paging (4.4) | Implemented & tested |
| Sv48 paging (4.5) | Implemented (limited test) |
| Sv57 paging (4.6) | Not implemented |
| Supervisor instructions — SFENCE.VMA (4.1-4.2) | Implemented & tested |
| Hypervisor H extension (ch5) | Partial |
| Smepmp — PMP enhancements (6.3) | Implemented & tested |
| Smstateen (6.1) | Implemented (limited test) |
| Smrnmi (6.5) | Partial |
| Smctr / priv-CFI (6.8, 6.9) | Not implemented |
| Svnapot (7.1) | Implemented (config; limited test) |
| Svpbmt (7.2) | Partial (config; PTE/PBMTE; LSU PMA TBD) |
| Svadu / Svinval (7.3–7.4) | Partial / not implemented |
| Sstc — supervisor timer (8.8) | Implemented (config; limited test) |
| Sscofpmf (8.9) | Implemented (config; limited test) |
| Sh — hypervisor extensions (ch9) | Partial |
| Privileged listings / rationale (ch10, appA) | N/A |

---

## Part III — Profiles

Profiles are checklists of mandated extensions; a target satisfies one only if its config enables every
required feature above. Status is therefore per-target.

| Profile | Status |
|---|---|
| RVI20 | Implemented & tested (base targets) |
| RVA20 | Partial (config-dependent) |
| RVA22 | Partial (config-dependent) |
| RVA23 | Not implemented (requires V + newer Ss*/Sm*) |
| RVB23 | Not implemented (requires V + bitmanip mandates) |

---

## Microarchitecture (no normative chapter — certified by behavior, not conformance)

| Feature | Status |
|---|---|
| Branch prediction (BHT / PH_BHT / BTB / RAS) | Implemented & tested |
| Speculative execution (in-order, precise traps) | Implemented & tested |
| L1 caches (I$ + D$) | Implemented & tested |
| L2 / L3 cache | Not implemented |
| Multi-threading (SMT) | Not implemented |
| Branch prediction fabric (U1 TAGE/GSHARE/…) | Implemented (config; limited test) |
| Decoupled front-end (U2 FTQ/FDIP/loopbuf) | Implemented (config; limited test) |
| Multi-issue width 2–8 (superscalar) | Implemented (config; dual-issue tested) |
| Slice-OoO (U4) | Implemented (off by default) |
| Full OoO (U5) | Implemented (config; gated; formal scaffolds) |
| L2 cache (U6.0 SoC AXI) | Implemented (config; off by default) |
| SMT / multi-core (U6.1–U6.2) | U6.1 implemented (fine); U6.2 hub/SF/inv for `NrCores` 1–8 (default 1); dual-hart Linux lab open |
| Multi-core | Partial (parameterized 2–8; N=1 identity; stream plane suite) |
| Hypervisor (RVH) | U9.0–U9.2: vstimecmp/STCE/VSTIP/htimedelta/guest TIME; VS litmus; G-stage PTW; PLIC 16-ctx; HFENCE/HLV |
| AVX-like / server math | CBO full-line + RVB + server package; `_v` + Ara attach live-lintable |
| RVV / Ara (U10ᵇ) | Partial: live Ara lint + purpose guide + RVV 1.0 DTS (`v`/`zve64d`) + opensbi tier A2 + directed tests; SBI/cosim open |
| CVXIF coprocessor interface | Implemented & tested (mutex with RVV accelerator) |
| RVFI trace / debug triggers / PMU | Implemented & tested |

---

## Headline

Fully covered (implemented **and** tested): the RV64GC / RV32 base (I/M/A/F/D/C), CSRs and M/S/U
privilege, FENCE.I and I/D coherence, PMA, PMP (with Smepmp), Sv32/Sv39 paging, and the core
microarchitecture (branch prediction, precise speculation, L1 caches, CVXIF, observability).

Implemented (config / limited test): Sstc, Sscofpmf, Zihintpause, Svnapot; partial Zawrs / Zicboz /
Zicbop / Svpbmt; U1–U4 micro-arch, multi-issue width, U6.0 L2 (off by default).

Not implemented (and therefore untested by design): Ztso, CFI, Zacas, Packed SIMD, vector crypto
(`zvk*`), Matrix, Sv57, Smctr/priv-CFI, Svinval. **Partial:** RVV/V via Ara attach (lint path;
full compliance cosim open), dual-hart Linux lab. See `AGENTS-specs-to-impl.md` for the
authoritative RTL status, `agents/spec/riscv-spec-I-9-vector.html` for the Vector sub-file, and
`architecture/` for promotion paths.
