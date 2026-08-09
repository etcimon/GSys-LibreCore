# Soft-ladder promotion — iteration log

Append-only. One **primary** residual (or tightly coupled pair) per iteration.
Template at bottom.

**Active:** `iter-004` (B1 AMO spin_lock / amo_buffer cancel).

---

## Active iteration

### iter-004 — AMO spin_lock residual: amo_buffer younger-cancel kill

| Field | Value |
|-------|--------|
| **Started** | 2026-08-08 |
| **Bucket** | B1 |
| **Primary ids** | `b1-amo-spin-lock` |
| **Hypothesis** | Hang-7 younger-cancel marks AMO cancelled; commit_drop never asserts `amo_valid_commit`; mispredict does not `flush_ex`; depth-1 `amo_buffer` stays full → later OpenSBI `spin_lock`/`amoadd.w` wedges (`mepc=0x2` class) |
| **I3 Fix** | `amo_buffer.cancel_i` + `store_unit` TID cancel; skip push if already cancelled; SS AMO port-0 only; directed `mini_amoadd_w_spin.S` |
| **I4 Verify** | Directed bare-metal under DI when harness wired; OpenSBI cont.47 re-soak with real SA locks (peel spin NOP) still pending lab soak |
| **I5 Retire** | partial — keep spin NOP in `mk_plat_skip` until OpenSBI cookie green |
| **I6 Next** | Re-soak cont.47 real locks; if green peel SA/heap spin nops; else `b1-lrsc-cmpxchg` |

---

## Completed iterations

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
