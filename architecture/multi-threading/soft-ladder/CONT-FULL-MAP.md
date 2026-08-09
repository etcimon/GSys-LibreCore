# Full cont.## × SMT2 bring-up → implementation map

Source narrative: `../smt2-bringup.md` (R3a cont.2–51 + Soft-ladder pointer).  
Living status: `inventory.yaml`. Active work: `ITERATION.md`.

**Target:** `g6lc64_smt2`, Variane DI, SUCCESS cookie `51b1babe` / concurrent baseline `200155`.  
**Production soft ELF:** `tmp-dual-ci/mk_plat_skip.py` + `fw_payload_r3a_c15_plat_skip.elf`.

---

## 1. End-to-end readiness picture

```text
  cont.2–14   STQ / load forward / SpeculativeSb  ──► mostly RTL-landed (R3a)
  cont.15–18  DI CF serialize / first 51b1babe   ──► SS full serialize landed
  cont.19     dual c.mv s3 poison                ──► soft nop; OpenSBI PEEL_CMV FAIL
  cont.20–26  peel domain/printf/ecall           ──► soft printf; SA real (47+)
  cont.27–32  banner / heap                      ──► soft malloc (freelist open)
  cont.33     hart_init CSR probes               ──► peeled (natural + CSR stall)
  cont.34–40  domain_finalize cuts               ──► B2 domain cut
  cont.41–46  start_finish / domain ld-hart      ──► B2 + soft switch_mode cookie
  cont.47–51  SA/spins/cmpx/scratch              ──► spins+cmpx peeled; soft malloc
```

| Layer | Goal | Status |
|-------|------|--------|
| **B1 RTL** | Delete soft nops by fixing DI | AMO/LRSC/CSR/c.mv/fdt_match/**malloc** peeled; soft strlen + printf **open** |
| **B2 firmware** | Source profile instead of VA patches | Domain cut / printf / switch_mode still soft |
| **B3 harness** | Cookie gate scripts | default soak **51b1babe** 2026-08-08 on work-ver-smt2 |

---

## 2. cont.## → bucket → RTL / soft disposition

| cont | Pin (short) | Bucket | Soft today | RTL / code status | Retire criterion |
|------|-------------|--------|------------|-------------------|------------------|
| **2–5** | STQ paddr / branch-TID cancel / STQ-empty loads | B1 | none | **Landed** (store_buffer sticky/forward, scoreboard after_flu_wb) | n/a |
| **6–11** | s4=lenp / path_offset −4 / next_tag | B1 | soft printf later | Partial: STQ forward + SS serialize; **FDT residual open** (`b1-fdt-lenp-store`) | real printf |
| **12–14** | STQ forward, store-side sticky, SpeculativeSb decouple | B1 | none | **Landed** load_unit/store_buffer | n/a |
| **15–18** | DI illegal@2; full CF serialize; 51b1babe | B1 | lottery / cookie | **Landed** SS post-CF/ALU/LSU serialize | n/a |
| **19** | dual `c.mv` → s3 poison | B1 | **natural** (peeled) | isolate: fail was fdt_match→strlen not c.mv | keep peeled |
| **20** | peel stubs; load-WB stall **negative** | — | — | do not re-try full load-WB drain | — |
| **21** | domain_init DI illegal@2; trap t1 | B3 | trap cave | TB trapdump **landed** | debug-only |
| **22** | post-domain SA **stale ra** | B1 | soft SA | STQ fwd should help; **spin + ra** still soft | real SA |
| **23–24** | soft SA global; natural hsm/coldboot | B1/B2 | soft SA | same as 22/47 | real SA |
| **25–26** | peel fwft/ecall; soft printf BANR | B1/B2 | soft printf | FDT lenp family | real printf |
| **27–30** | banner / heap / putc / domain_dump | B2 | various | peels mostly natural | source profile |
| **31–33** | hart_init; **CSR expected-trap** | B1 | natural probes default | **peeled** (CSR stall + cookie green) | keep peeled |
| **34–35** | domain_finalize soft; real console | B2 | domain cut; jalr softs | — | source no-ops |
| **36–40** | soft hsm_start; domain walk pins | B2 | domain cut | cont.45 peeled real hsm_start | full domain |
| **41–43** | soft start_finish; domain@bb68 | B2 | start_finish soft | — | real finish |
| **44** | real printf → **lenp mcause=6** | B1 | soft printf | STQ+SS partial; **open** | real printf |
| **45** | real hsm_hart_start | B2 | — | **peeled** | n/a |
| **46** | real ld domain_hart_ptr then exit | B2 | cut after ld | multi-iter → ecall poison | full walk |
| **47** | real SA; spins | B1 | natural spins default | **peeled** (SOFT_SPIN bisect) | keep peeled |
| **48–50** | finish; cmpxchg | B1 | natural LR/SC default | **peeled** (SOFT_CMPX bisect) | keep peeled |
| **51** | scratch_used; switch_mode | B2/B3 | switch cookie soft; soft malloc | cookie WFI green | Linux handoff |

---

## 3. B1 implementation order (do not skip)

| Step | id | Mechanism | Landed commits / plan |
|-----:|----|-----------|------------------------|
| 0 | hang-4/7, SS serialize, STQ fwd | CF cancel, issue stall, store→load | pre-soft-ladder + `a9ee4b143` |
| 1 | `b1-amo-spin-lock` | amo_buffer cancel; AMO port0 | `47572e98c` |
| 2 | `b1-lrsc-cmpxchg` | no LR flush; LR→SC store barrier | `041574c0c` |
| 3 | `b1-csr-expected-trap` | unresolved CSR issue stall | **iter-006** |
| 4 | `b1-fdt-lenp-store` | dual-issue pointer integrity | next after CSR soak |
| 5 | `b1-dual-cmv-s3` | wrong-path LD / RF | after FDT or parallel directed |
| 6 | Soft SA ra (cont.22) | stack RAW + spin | follows AMO green |

---

## 4. B2 / B3 (after B1 floor)

| id | Action |
|----|--------|
| `b2-domain-finalize-cut` | Source early-finalize **or** fix ecall poison after multi-iter |
| `b2-soft-printf` | Drop when FDT B1 green |
| `b2-switch-mode-payload` | Platform SUCCESS stub then Linux image |
| `b2-console-platform-jalr` | NULL device ops in platform |
| `b3-success-hang-cookies` | Document only; no ROM |
| `b3-mk-plat-skip-oracle` | Shrink site-by-site as B1/B2 land |

---

## 5. Negative results (do not re-try without new evidence)

| Attempt | Result |
|---------|--------|
| Dual-commit serialize LOAD/ALU (cont.19b) | natural c.mv still poison |
| Full load-WB issue drain (cont.20) | illegal@0xa; cookie regress |
| SpeculativeSb hold-ret-until-STQ-empty | FDT next_tag collapse |
| Soft ecall with multi-iter domain | unblocks multi-iter, poisons real ecall |

---

## 6. Ordered path (lab integration)

```text
1. B1 directed DI soak
   bash verif/regress/soft-ladder-di-regress.sh
   # SOFT_LADDER_HARNESS=work-ver-smt2 (default)
   # SOFT_LADDER_SPIKE=1 optional; SOFT_LADDER_COMPILE_ONLY=1 assemble only
   # or: SOFT_LADDER=1 bash verif/regress/dual-iss-regress.sh

2. OpenSBI cookie (default peels spin/cmpx/CSR/c.mv/fdt_match/malloc; soft strlen)
   bash verif/regress/soft-ladder-opensbi-soak.sh
   # Bisect: SOFT_SPIN SOFT_CMPX SOFT_CSR SOFT_CMV SOFT_FDT_MATCH SOFT_MALLOC
   # Experimental: PEEL_STRLEN=1 (red @4a50 stock strlen)
   # SUCCESS = trapdump [1000] contains 51b1babe only

3. PEEL_STRLEN RTL (iter-011) then real printf
4. B1 FDT lenp → real printf (drop BANR)
5. B2 domain full walk (real ecall); switch_mode payload
6. Empty mk_plat_skip → retire b3-mk-plat-skip-oracle
```

Checklist:

```text
[x] step1 soft-ladder-di-regress (4 minis) under work-ver-smt2 — PASS 4/4
[x] step2 cookie baseline (soft malloc + natural spins/cmpx/CSR) — PASS 51b1babe
     (confirmed final default soak: /tmp/.../veri_20260808-232820.log)
[x] PEEL_SPIN / natural spins → cookie green (default)
[x] PEEL_CMPX / natural LRSC → cookie green (default)
[x] PEEL_CSR / natural CSR probes → cookie green (default)
[x] natural c.mv + soft fdt_match stub → cookie green (iter-008)
[x] natural fdt_match + soft sbi_strlen ret-imm 11 → cookie green (iter-009)
[x] natural malloc/zalloc/free → cookie green (iter-010)
[!] PEEL_STRLEN → FAIL mid sbi_strlen mepc=0x80004a50; RTL PC continuity in tree, harness rebuild pending
[ ] real sbi_printf (FDT lenp)
[ ] domain full walk; switch_mode payload
[ ] mk_plat_skip empty → retire
```

---

## 7. File index

| Artifact | Role |
|----------|------|
| This file | Full cont.## disposition |
| `inventory.yaml` | Per-site status |
| `b1-rtl-residuals.md` | B1 deep map |
| `b2-firmware-policy.md` | B2 sketch |
| `b3-sim-harness.md` | cookies / TB |
| `monorepo-soak-integration.md` | soak scripts × RTL |
| `../smt2-bringup.md` | lab narrative cont.2–51 |
