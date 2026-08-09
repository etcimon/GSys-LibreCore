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
  cont.19     dual c.mv s3 poison                ──► soft nop; RTL open (wrong-path LD?)
  cont.20–26  peel domain/printf/ecall           ──► soft SA / soft printf
  cont.27–32  banner / heap / cave rehome        ──► B2 softs
  cont.33     real hart_init; CSR probe cut      ──► B1 CSR serialize (iter-006)
  cont.34–40  domain_finalize cuts               ──► B2 domain cut
  cont.41–46  start_finish / domain ld-hart      ──► B2 + soft SA
  cont.47–51  real SA-nolock; soft cmpx; spins   ──► B1 AMO/LRSC in progress
```

| Layer | Goal | Status |
|-------|------|--------|
| **B1 RTL** | Delete soft nops by fixing DI | AMO cancel + LR/SC pair + SS serialize + STQ fwd **in tree**; CSR stall **iter-006**; dual-c.mv / FDT lenp **open** |
| **B2 firmware** | Source profile instead of VA patches | Not started (keep binary peels) |
| **B3 harness** | SUCCESS = cookie/trapdump only in sim | TB trapdump landed; cookies still in ELF |

---

## 2. cont.## → bucket → RTL / soft disposition

| cont | Pin (short) | Bucket | Soft today | RTL / code status | Retire criterion |
|------|-------------|--------|------------|-------------------|------------------|
| **2–5** | STQ paddr / branch-TID cancel / STQ-empty loads | B1 | none | **Landed** (store_buffer sticky/forward, scoreboard after_flu_wb) | n/a |
| **6–11** | s4=lenp / path_offset −4 / next_tag | B1 | soft printf later | Partial: STQ forward + SS serialize; **FDT residual open** (`b1-fdt-lenp-store`) | real printf |
| **12–14** | STQ forward, store-side sticky, SpeculativeSb decouple | B1 | none | **Landed** load_unit/store_buffer | n/a |
| **15–18** | DI illegal@2; full CF serialize; 51b1babe | B1 | lottery / cookie | **Landed** SS post-CF/ALU/LSU serialize | n/a |
| **19** | dual `c.mv` → s3 poison | B1 | nop @7312/14 | dual-commit try **negative**; residual wrong-path LOAD? | natural c.mv |
| **20** | peel stubs; load-WB stall **negative** | — | — | do not re-try full load-WB drain | — |
| **21** | domain_init DI illegal@2; trap t1 | B3 | trap cave | TB trapdump **landed** | debug-only |
| **22** | post-domain SA **stale ra** | B1 | soft SA | STQ fwd should help; **spin + ra** still soft | real SA |
| **23–24** | soft SA global; natural hsm/coldboot | B1/B2 | soft SA | same as 22/47 | real SA |
| **25–26** | peel fwft/ecall; soft printf BANR | B1/B2 | soft printf | FDT lenp family | real printf |
| **27–30** | banner / heap / putc / domain_dump | B2 | various | peels mostly natural | source profile |
| **31–33** | hart_init; **CSR expected-trap** | B1 | cut after memset | **iter-006** unresolved CSR stall | full probes |
| **34–35** | domain_finalize soft; real console | B2 | domain cut; jalr softs | — | source no-ops |
| **36–40** | soft hsm_start; domain walk pins | B2 | domain cut | cont.45 peeled real hsm_start | full domain |
| **41–43** | soft start_finish; domain@bb68 | B2 | start_finish soft | — | real finish |
| **44** | real printf → **lenp mcause=6** | B1 | soft printf | STQ+SS partial; **open** | real printf |
| **45** | real hsm_hart_start | B2 | — | **peeled** | n/a |
| **46** | real ld domain_hart_ptr then exit | B2 | cut after ld | multi-iter → ecall poison | full walk |
| **47** | real SA; **nop spin** | B1 | spin NOP4 | **iter-004** amo_buffer cancel | no spin nops |
| **48–50** | finish thru atomic_write; soft **cmpx ld/sd** | B1 | soft cmpx | **iter-005** LR/SC pair | real lr/sc |
| **51** | real scratch_used; switch_mode prologue | B2/B3 | switch body soft | cookie WFI | Linux handoff |

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

2. OpenSBI peels (one class at a time; re-soak cookie after each)
   python tmp-dual-ci/mk_plat_skip.py                    # default soft cont.51
   PEEL_SPIN=1 python tmp-dual-ci/mk_plat_skip.py        # real spins
   PEEL_CMPX=1 python tmp-dual-ci/mk_plat_skip.py        # real lr/sc cmpx
   PEEL_CSR=1  python tmp-dual-ci/mk_plat_skip.py        # CSR probes
   PEEL_CMV=1  python tmp-dual-ci/mk_plat_skip.py        # natural c.mv
   PEEL_ALL_B1=1 …                                       # experimental all four
   # SUCCESS = 51b1babe in trapdump (CVA6_TRAP_DUMP=1), Variane DI

3. B1 FDT lenp → real printf (drop BANR) when green
4. B1 dual-c.mv residual if PEEL_CMV fails
5. Soft SA retirement (ra + spin already green)
6. B2 domain full walk (real ecall); switch_mode payload
7. Empty mk_plat_skip → retire b3-mk-plat-skip-oracle
```

Checklist:

```text
[x] step1 soft-ladder-di-regress (4 minis) under work-ver-smt2 — PASS 4/4
[x] step2 cookie baseline (soft malloc + natural spins/cmpx/CSR) — PASS 51b1babe
     (confirmed final default soak: /tmp/.../veri_20260808-232820.log)
[x] PEEL_SPIN / natural spins → cookie green (default)
[x] PEEL_CMPX / natural LRSC → cookie green (default)
[x] PEEL_CSR / natural CSR probes → cookie green (default)
[!] PEEL_CMV → FAIL plat_hc=80 mepc≈0x80004a50 mcause=2 (mid sbi_strlen);
    bare mini_dual_cmv_s3 PASS — keep c.mv nops default
[ ] PEEL_MALLOC → real freelist (b1-heap-freelist-malloc)
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
