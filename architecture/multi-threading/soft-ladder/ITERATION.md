# Soft-ladder promotion — iteration log

Append-only. One **primary** residual (or tightly coupled pair) per iteration.
Template at bottom.

**Active:** `iter-003` (cleanup monorepo-soak/tmp-dual-ci; RTL dual-issue notes).

---

## Active iteration

### iter-003 — Patch cleanup via in-tree RTL + shrink monorepo-soak / tmp-dual-ci

| Field | Value |
|-------|--------|
| **Started** | 2026-08-08 |
| **Bucket** | B1 (document landed dual-issue serialize) + B3 cleanup |
| **Primary ids** | retire monorepo-soak applied scripts; prune tmp-dual-ci probes |
| **Hypothesis** | Cont dual-issue serialize already lives in `issue_read_operands`; patch scripts/logs are pure debt |
| **I3 Fix** | Consolidated SS dual-issue comments in `issue_read_operands.sv`; deleted applied `patch-*.py` + E logs; tmp-dual-ci → production-only (~2.6 MB) |
| **I4 Verify** | Markers still present post-cleanup; dirs reduced |
| **I5 Retire** | monorepo-soak applied generators → `APPLIED.md` |
| **I6 Next** | **iter-004** → directed DI residual for remaining soft sites (spin/LRSC) or peel `mk_plat_skip` nops under re-soak |

---

## Completed iterations

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

| Order | id | Bucket | Note |
|------:|----|--------|------|
| 1 | `b1-amo-spin-lock` | B1 | Unblocks SA/heap/scratch natural locks |
| 2 | `b1-lrsc-cmpxchg` | B1 | Unblocks real atomic_cmpxchg |
| 3 | `b3-success-hang-cookies` | B3 | Stabilize SUCCESS definition for gates |
| 4 | `b1-csr-expected-trap` | B1 | Full hart_init probes |
| 5 | `b1-fdt-lenp-store` | B1 | Real printf |
| 6 | `b2-domain-finalize-cut` | B2 | After ecall poison understood / B1 stable |
| 7 | `b2-switch-mode-payload` | B2 | Linux handoff |
| 8 | `b1-dual-cmv-s3` | B1 | Platform override natural |
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
