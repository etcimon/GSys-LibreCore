# Soft-ladder promotion — iteration log

Append-only. One **primary** residual (or tightly coupled pair) per iteration.
Template at bottom.

**Active:** `iter-010` (PEEL_MALLOC freelist after strlen soft peel).

---

## Active iteration

### iter-010 — Heap freelist / PEEL_MALLOC residual

| Field | Value |
|-------|--------|
| **Started** | 2026-08-09 |
| **Bucket** | B1 |
| **Primary ids** | `b1-heap-freelist-malloc` |
| **Hypothesis** | Soft malloc unblocked cookie; real freelist under DI still red |
| **I2 Repro** | `PEEL_MALLOC=1 bash verif/regress/soft-ladder-opensbi-soak.sh` |
| **I3 Fix** | TBD freelist RTL |
| **I4 Verify** | default cookie green; PEEL_MALLOC when fixed |
| **I6 Next** | real printf / PEEL_STRLEN RTL |

---

## Completed iterations

### iter-009 — FDT match / sbi_strlen residual (closed: match peeled, strlen soft)

| Field | Value |
|-------|--------|
| **Completed** | 2026-08-09 |
| **Result** | Stock `sbi_strlen` RVI `add a5,a4,a0` loop → mepc=`0x4a50` mcause=2. Soft `sbi_strlen` ret-imm 11 + **natural jal fdt_match** → cookie **51b1babe**. Bare `mini_strlen_rvc`/`mini_dual_cmv_strlen` PASS. Default: natural match + soft strlen; `PEEL_STRLEN=1` red. |
| **Next** | iter-010 freelist |

### iter-008 — Dual-c.mv OpenSBI residual (closed: peeled)

| Field | Value |
|-------|--------|
| **Completed** | 2026-08-09 |
| **Result** | Isolate: PEEL_CMV + SOFT_FDT_MATCH → **51b1babe**; PEEL_CMV alone mid-strlen fail. Bare minis dual_cmv / strlen_rvc / dual_cmv_strlen **3/3 PASS**. Default: natural c.mv + soft fdt_match stub. `b1-dual-cmv-s3` **peeled**. |
| **Next** | iter-009 FDT match / strlen |

### iter-007 — Ordered path integration + freelist soft + peels

| Field | Value |
|-------|--------|
| **Completed** | 2026-08-08 |
| **Result** | step1 4/4; soft malloc restores cookie; SPIN/CMPX/CSR peeled default; **final default soak cookie 51b1babe** on work-ver-smt2 (`veri_20260808-232820.log`); PEEL_CMV fail; commits through `263dc41a5` |
| **Next** | iter-008 dual-c.mv OpenSBI |

### iter-006 — Full cont.## map + CSR expected-trap issue stall

| Field | Value |
|-------|--------|
| **Completed** | 2026-08-08 |
| **Result** | `ae0acc968` CONT-FULL-MAP + unresolved_csr_q |
| **Next was** | ordered-path integration |

### iter-005 — LR/SC: no flush after LR + issue barrier to SC

| Field | Value |
|-------|--------|
| **Completed** | 2026-08-08 |
| **Result** | `041574c0c` — no LR flush_commit; lr_sc_pair store barrier; mini_lrsc_d.S |
| **Next was** | CSR + full map |

### iter-004 — AMO spin_lock residual: amo_buffer younger-cancel kill

| Field | Value |
|-------|--------|
| **Completed** | 2026-08-08 |
| **Result** | `amo_buffer.cancel_i` + port-0 AMO; `47572e98c` on E:\cva6 master |
| **Next was** | iter-005 LR/SC |

### iter-003 — Patch cleanup via in-tree RTL + shrink monorepo-soak / tmp-dual-ci

| Field | Value |
|-------|--------|
| **Completed** | 2026-08-08 |
| **Result** | soft-ladder committed on `E:\cva6` master (`a9ee4b143`); monorepo-soak APPLIED.md; SS serialize documented |
| **Next was** | iter-004 AMO spin |

### iter-002 — Monorepo-soak RTL sync + cont.## cross-map

| Field | Value |
|-------|--------|
| **Completed** | 2026-08-08 |
| **Result** | AMOCAS.Q / hang-7 / SMT hart / trapdump in worktree; integration map |
| **Next was** | cleanup patch dirs (iter-003) |

### iter-001 — Bootstrap promotion structure + B1 queue

| Field | Value |
|-------|--------|
| **Completed** | 2026-08-08 |
| **Result** | soft-ladder/ structure + inventory + iteration template |
| **Next was** | monorepo-soak RTL currency (iter-002) |

---

## Backlog (priority order)

See also `CONT-FULL-MAP.md` for cont.## disposition.

| Order | id | Bucket | Note |
|------:|----|--------|------|
| 1 | `b1-heap-freelist-malloc` | B1 | **active** — soft malloc default; PEEL_MALLOC red |
| 2 | `b1-sbi-strlen-rvi` | B1 | soft ret-imm 11; PEEL_STRLEN red mid-add @4a50 |
| 3 | `b1-fdt-lenp-store` | B1 | real printf / hang-6; match path peeled |
| 4 | `b1-dual-cmv-s3` | B1 | **peeled** (natural c.mv default) |
| 5 | `b1-amo-spin-lock` | B1 | **rtl-fixed** (natural spins default) |
| 6 | `b1-lrsc-cmpxchg` | B1 | **rtl-fixed** (natural LR/SC default) |
| 7 | `b1-csr-expected-trap` | B1 | **rtl-fixed** (natural CSR probes default) |
| 7 | `b2-domain-finalize-cut` | B2 | Domain cut / ecall multi-iter |
| 8 | `b2-switch-mode-payload` | B2 | Linux handoff |
| 9 | `b3-mk-plat-skip-oracle` | B3 | Shrink; not empty yet |

---

## Template (copy for next iteration)

```markdown
### iter-NNN — short title

| Field | Value |
|-------|--------|
| **Started** | YYYY-MM-DD |
| **Bucket** | B1 / B2 / B3 |
| **Primary ids** | inventory id(s) |
| **Hypothesis** | one sentence |
| **I1 Scope** | |
| **I2 Repro** | command / ELF / mepc pin |
| **I3 Fix** | paths touched |
| **I4 Verify** | gate result |
| **I5 Retire** | mk_plat_skip / inventory updates |
| **I6 Next** | next id or stop |

#### Notes
-
```
