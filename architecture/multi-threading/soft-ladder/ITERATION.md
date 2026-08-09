# Soft-ladder promotion — iteration log

Append-only. One **primary** residual (or tightly coupled pair) per iteration.
Template at bottom.

**Active:** `iter-005` (B1 LR/SC exclusive pair).

---

## Active iteration

### iter-005 — LR/SC: no flush after LR + issue barrier to SC

| Field | Value |
|-------|--------|
| **Started** | 2026-08-08 |
| **Bucket** | B1 |
| **Primary ids** | `b1-lrsc-cmpxchg` |
| **Hypothesis** | Real OpenSBI `atomic_cmpxchg` LR/SC hangs because (1) `flush_commit` after every AMO including LR restarts the pipe and (2) intervening STORE under DI can clear `axi_riscv_lrsc` reservation so SC fails forever. Production ELF uses soft `ld/bne/sd` (cont.50). |
| **I3 Fix** | Skip `flush_commit` for LR; `lr_sc_pair_q` blocks non-SC STORE issue until SC or flush; `is_amo_lr`/`is_amo_sc` helpers; `mini_lrsc_d.S` |
| **I4 Verify** | Directed LR/SC when harness wired; OpenSBI peel soft cmpx still needs lab re-soak |
| **I5 Retire** | partial — keep soft cmpx until cookie green with real `lr.d`/`sc.d` |
| **I6 Next** | Lab re-soak real cmpxchg + real SA locks; then FDT lenp / CSR |

---

## Completed iterations

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
