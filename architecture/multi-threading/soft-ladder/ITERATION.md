# Soft-ladder promotion — iteration log

Append-only. One **primary** residual (or tightly coupled pair) per iteration.
Template at bottom.

**Active:** `iter-008` (dual-c.mv OpenSBI residual after cookie-green default).

---

## Active iteration

### iter-008 — Dual-c.mv OpenSBI residual (post cookie-green peels)

| Field | Value |
|-------|--------|
| **Started** | 2026-08-08 |
| **Bucket** | B1 |
| **Primary ids** | `b1-dual-cmv-s3` |
| **Hypothesis** | Bare `mini_dual_cmv_s3` green under SS serialize; OpenSBI `PEEL_CMV` fails early (`plat_hc=80`) with `mepc≈0x80004a50` mcause=2 mid-`sbi_strlen` — control-flow/pointer poison from dual-c.mv window, not only `ld a2,0(s3)` at 7316 |
| **I2 Repro** | `PEEL_CMV=1 bash verif/regress/soft-ladder-opensbi-soak.sh` → no 51b1babe |
| **I3 Fix** | TBD: selective recovery around LOAD→consumer vs dual RF; keep nops default |
| **I4 Verify** | default cookie still green; PEEL_CMV only when fixed |
| **I6 Next** | PEEL_MALLOC freelist RTL in parallel |

---

## Completed iterations

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
| 1 | `b1-heap-freelist-malloc` | B1 | soft malloc default; PEEL_MALLOC still red |
| 2 | `b1-dual-cmv-s3` | B1 | **active** — OpenSBI PEEL_CMV fail; bare mini green |
| 3 | `b1-fdt-lenp-store` | B1 | Real printf / hang-6 family |
| 4 | `b1-amo-spin-lock` | B1 | **rtl-fixed** (natural spins default) |
| 5 | `b1-lrsc-cmpxchg` | B1 | **rtl-fixed** (natural LR/SC default) |
| 6 | `b1-csr-expected-trap` | B1 | **rtl-fixed** (natural CSR probes default) |
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
