# Soft-ladder promotion — iteration log

Append-only. One **primary** residual (or tightly coupled pair) per iteration.
Template at bottom.

**Active:** `iter-006` (B1 CSR expected-trap + full cont map).

---

## Active iteration

### iter-006 — Full cont.## map + CSR expected-trap issue stall

| Field | Value |
|-------|--------|
| **Started** | 2026-08-08 |
| **Bucket** | B1 (+ docs map) |
| **Primary ids** | `b1-csr-expected-trap`; map all cont.2–51 |
| **Hypothesis** | cont.33: younger issue after CSR lets `csrw mtvec` race illegal probe so expected-trap handler never runs. Full bring-up map needed to order peels. |
| **I3 Fix** | `unresolved_csr_q` in `issue_stage` (mirror CF stall); `CONT-FULL-MAP.md`; directed `mini_csr_expected_trap.S` + `mini_dual_cmv_s3.S` |
| **I4 Verify** | Directed CSR trap under DI when harness wired; OpenSBI peel CSR cut pending soak |
| **I5 Retire** | partial — keep cd86→cd0e until probe green |
| **I6 Next** | FDT lenp (`b1-fdt-lenp-store`) or lab re-soak AMO/LRSC/CSR peels |

---

## Completed iterations

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
| 1 | `b1-amo-spin-lock` | B1 | in_progress — peel after DI soak |
| 2 | `b1-lrsc-cmpxchg` | B1 | in_progress — peel soft cmpx after soak |
| 3 | `b1-csr-expected-trap` | B1 | in_progress — peel CSR cut after soak |
| 4 | `b1-fdt-lenp-store` | B1 | Real printf / hang-6 family |
| 5 | `b1-dual-cmv-s3` | B1 | Platform override natural; test scaffold |
| 6 | `b3-success-hang-cookies` | B3 | Stabilize SUCCESS definition for gates |
| 7 | `b2-domain-finalize-cut` | B2 | After ecall poison understood / B1 stable |
| 8 | `b2-switch-mode-payload` | B2 | Linux handoff |
| 9 | `b3-mk-plat-skip-oracle` | B3 | Retire when empty |

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
