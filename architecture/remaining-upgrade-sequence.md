# Remaining upgrade sequence — multi-core, hypervisor, AVX-like memcpy

Plan of record extension to `router-core-upgrade-program.md`. Ordered by **prerequisites** and
**perf/W for server/router Linux**. Detail: `server-math-hypervisor.md`.
All-feature enable + `NrCores` scale vs SMT fetch recover:
`multi-threading/soft-ladder/CONTRACT.md` §8 (named envelopes, union soak, no mega-package).

---

## 0. Done vs open (snapshot)

| Track | Status |
|-------|--------|
| U1–U4, multi-issue, U7ᵃ/ᵇ/ᶜ, U6.0–U6.2 integrated | **Done / partial** |
| **U6.1 dual-PC / CSR + follow-ons** | **Done (fine-grain)** — PC/CSR/RF/RAS/GHR banks; IF-only switch; `smt2-bringup.md` |
| **U9.0 Hypervisor Sstc×H** | **Done** — `vstimecmp` + `henvcfg.STCE` + VSTIP |
| **U9.1 htimedelta** | **Done** — guest time = mtime + htimedelta; TIME under V |
| **U9.2 VS litmus / trap polish** | **Done** — virtual-instr STCE, VSTIP mip, VS mret litmus; G-stage paths present |
| **U10 server math package** | **C-light production** — HPDCACHE+HWPF+L2 auto, RVB/Zicbo*/H+Sstc, `server-math-tests` (optional) |
| U10ᵇ RVV / Ara attach | **Partial / live-lintable** — Ara vendored + attach + lint; purpose guide + DTS + directed tests; full cosim/SBI open |
| Multi-context PLIC | **Done** — 16 targets (8×M/S); harness fan-out per core |
| **U5 full OoO** | **Production (gated)** — `OoOEn=1` backend; dual-issue `cv64a6_ooo` + 4-issue server pkg; cancel-mask mispredict recovery; `ooo-l3-tests` optional |

---

## 1. Spec map (RISC-V identity of “AVX” + H)

| Server need | Spec | Implementation seat |
|-------------|------|---------------------|
| AVX-wide copy | RVV 1.0 | Ara / CVXIF vector; `RVV` + misa.V |
| `rep stos` / zero | Zicboz | U7ᶜ multi-beat `cbo.zero` |
| Stream copy | Zicbop + HWPF | Decode HINT + `HwPrefetchEn` |
| Bit munge | Zba/Zbb (`RVB`) | Config-gated |
| KVM host | H-ext + Sstc | U9.0 `vstimecmp`; HS CSRs under `RVH` |
| Guest timer | Sstc + H | `henvcfg.STCE` + VSTIP |

---

## 2. Sequence graph

```
U6.2 multi-core ──┬── U9.0 Sstc×H (vstimecmp) ✅
                  ├── U9.1 htimedelta + TIME under V ✅
                  ├── U9.2 VS litmus + STCE virtual-instr ✅
                  ├── multi-context PLIC (16 tgt) ✅
                  ├── U10 server package ✅ C-light (HPDCACHE+HWPF+L2 auto + tests)
                  ├── U10ᵇ RVV/Ara config scaffold ✅ (IP flist open)
                  └── U5 OoO (production gated; L3+server PF✅)
```

### Phase B — Hypervisor

| Step | Content | Status |
|------|---------|--------|
| B0 | `vstimecmp`, `henvcfg.STCE`, legalize `Sstc&&RVH`, VSTIP | **done** |
| B1 | `htimedelta` + guest `time` under V | **done** |
| B1b | VS entry litmus + STCE virtual-instr + HVIP mask | **done** |
| B2 | G-stage (two-stage + G-only) | **present** (KVM stress open) |
| B3 | HFENCE/HLV/HSV | decoder+commit present |
| B4 | PLIC multi-context (16 targets, per-core M/S) | **done** |

### Phase C — AVX-like / math

| Tier | Content | Status |
|------|---------|--------|
| C-light | Full-line `cbo.zero`, Zicbop HINT, RVB, HWPF, HPDCACHE server pkg | **done** |
| C-heavy | RVV package + Ara attach + guide/DTS/tests | **partial**; full cosim / OpenSBI V open |

---

## 3. Enable (operator)

```
# Server / KVM / math host profile (select as active cva6_config_pkg):
core/include/cv64a6_server_math_config_pkg.sv
  → H=1, Sstc=1, RVB, Zicbo*, L2, NrCores=2, dual-issue, HWPF
  → RVV=0 until Ara is linked

# When Ara is on the flist:
core/include/cv64a6_server_math_v_config_pkg.sv  # VExtEn=1, CvxifEn=0
# See architecture/ara-vector-attach.md

# Router low-power remains default imafdc packages (H=0, NrCores=1).
```

---

## 4. Next concrete work

1. ~~`vendor sync ara` + `Flist.ara`~~ **done**  
2. ~~L3 victim → L2 tag inval~~ **done**  
3. ~~p6 stream plane × multicore suite~~ **done** — `mc-stream-tests` lint gate green  
4. ~~Ara flist + typed lint top for `cv64a6_server_math_v`~~ **done** (`extraFlistsByTarget`,
   `cva6_ara_lint_top`, suite `ara-vector-path` PASS)  
5. ~~Ariane EnableAccelerator + attach + live Ara (`CVA6_ARA_ATTACH=1`)~~ **done** (Verilator lint
   green with `vendor/ara/cva6_shim/*` + expanded Flist.ara deps)  
6. ~~Strengthen formal vs **live** freelist / ROB / multi-port rename~~ **done**
   (`verify.formalTasks` 4× `.sby`; cancel remains policy model)  
7. ~~R2a dual-hart payload + DTB + R3a OpenSBI `fw_payload.elf` on Windows~~ **done**
   (managed xPack + Cygwin OpenSBI wrap → `workspace/smt2-linux/fw_payload.elf`)  
8. ~~R3 dual-hart payload cosim (`cva6.py` + Verilator on WSL)~~ **done** (Variane SUCCESS
   ~6.5M cycles on `fw_payload.elf`); Spike via WSL managed install; **R3b Linux `Image`**
   still external (cva6-sdk / kernel build)
9. U10ᵇ software contract: ~~purpose guide + DTS `v` + directed vector tests~~ **done**
   (`AGENTS-vector.md`, `ariane-server-math-v.dts`, `testlist_ara_vector.yaml`); next =
   OpenSBI VRF context + `cva6.py` cosim of `v_memcpy_lmul` under live Ara
10. ~~Zacas AMOCAS.W/D + multicore spo/CF directed + Spike soak~~ **done** (`RVZacas`,
    `testlist_mc_stream`, `mc-spo-soak` / `mc-spo-spike`); ~~RTL mini hard CAS~~ **done**
    (`mc-mini-veri`); ~~full CRT `mc-spo-veri`~~ **done** (imafdc + server_math 9/9); ~~AMOCAS.Q~~ **done**
11. ~~Structural FO4 residual close sparse_ex/frontend @ 2.5 GHz~~ **done** (screening;
    S3b-lab real-STA retune still open)

**Live next (authoritative ordered list + file priors):**
[`AGENTS-todo.md`](../AGENTS-todo.md) — **Current phase** (landed table with prior paths) and
**Practical next** in `AGENTS-todo.md` (host residual §1–§10 largely **done**; lab FO4/STA + stream8 optional growth open).

Quick spine for those open items:

| Next | Open these |
|------|------------|
| ~~Suite catalog~~ **done** | `mc-mini-veri` + `mc-spo-veri` in `defaults.ts`; `AGENTS-specs-to-tests.md` |
| ~~CRT RTL residual~~ **done** | imafdc + server_math L2 9/9 · `mc-spo-veri.sh` |
| ~~H-edge~~ **done** (Spike+RTL 3/3) | `kvm-h-spike` · `architecture/server-math-hypervisor.md` |
| ~~Stability / dual-ISS / dual-hart host~~ **done** | `stability-regress` · `dual-iss-regress` · `dual-hart-ci` |
| ~~AMOCAS.Q~~ **done** | `zacas-policy` · `architecture/zacas-amocas-q.md` |
| R3b Linux Image | soft gate `r3b-linux-image` · Image external |
| Ara live cosim / VRF | `ara-vector-cosim` · lab when `_v` TB + Image |
| Lab FO4/STA | `s9-lab-gate` · real STA / OpenROAD still lab |
| ~~Stream8-class package~~ **promoted + CRT 9/9 + H-edge 3/3** | `g6lc64_stream8` · `mc-spo-veri` · `kvm-h-veri` |


