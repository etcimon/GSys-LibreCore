# U5 / FSE recovery timeline

Single ordering for **mispredict** vs **full flush** in the production OoO path
(`core/ooo/g6lc_ooo_dispatch.sv`). Complements `architecture/speculative-execution/`.

## Mispredict (branch wrong-path)

Same cycle as `resolved_branch.is_mispredict`:

| Step | Actor | Action |
|------|--------|--------|
| 1 | `controller` | `flush_if`, `flush_unissued` (not full `flush_i`) |
| 2 | FE | Redirect PC; FSE S2 restores GHR+RAS from `g6lc_bp_ckpt` |
| 3 | `scoreboard` | `SpeculativeSb` cancels younger TIDs → `cancelled_mask` |
| 4 | `g6lc_rename` | `mispredict_i` restores map/free/busy from branch ckpt |
| 5 | IQ / ROB / LSQ | Squash entries whose TID ∈ `cancelled_mask` |
| 6 | **Load buf / STQ** (FSE S4) | Younger-only: load slots flushed by TID; speculative STQ repacked without cancelled TIDs |
| 7 | PRF | WB enabled only if `!cancelled_mask[wb_tid]` |
| 8 | `g6lc_memdep` | `flush_i \| mispredict_i` clears store-set + ld_wait |
| 9 | Commit | `commit_drop` retires cancelled slots; no arch RF/CSR write |

Older-than-branch in-flight ops continue and commit normally.

## Full flush (exception / fence / CSR side-effect / SMT coarse)

| Step | Actor | Action |
|------|--------|--------|
| 1 | `controller` | `flush_if`, `flush_unissued`, `flush_id`, `flush_ex`, … |
| 2 | SB | Full invalidate (`flush_i`) |
| 3 | rename / IQ / ROB / LSQ / memdep | `flush_i` full clear |
| 4 | FE | Redirect to trap/fence PC; optional `flush_bp` |

## Invariants

1. Cancelled younger never architectural commit (`commit_ack` ⇒ `commit_drop` if cancelled).  
   Formal scaffold: `core/ooo/formal/g6lc_ooo_cancel_props.sv`.
2. Speculative stores never leave the commit STQ before non-cancelled commit.
3. NI / non-idempotent loads never issue while still speculative (`load_unit`).
