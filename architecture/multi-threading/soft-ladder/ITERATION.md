# Soft-ladder promotion — iteration log

Append-only. One **primary** residual (or tightly coupled pair) per iteration.
Template at bottom.

**Active:** `iter-012` (FDT lenp / getprop — soft getprop; natural strlen peeled).

---

## Active iteration

### iter-012 — FDT `lenp` / getprop residual

| Field | Value |
|-------|--------|
| **Started** | 2026-08-09 |
| **Bucket** | B1 |
| **Primary ids** | `b1-fdt-lenp-store` |
| **Hypothesis** | `fdt_get_property_by_offset_` fail-path `sw a0,0(s2)` with s2=code (`0x12b2a` = ra of `fdt_next_tag` return in `fdt_check_node_offset_`); soft `fdt_getprop_namelen` unblocks cookie with natural strlen |
| **I2 Repro** | `PEEL_FDT_GETPROP=1 SOFT_LADDER_HARNESS=work-ver-smt2-fw64 bash verif/regress/soft-ladder-opensbi-soak.sh` → mepc=0x12eb2 mcause=6 mtval=0x12b2a; trapdump s2=mtval, ra=0x12e3e (return into by_offset_ after check_prop), sp/s0 frame intact |
| **I3 Fix** | Soft getprop default (cookie green). RTL bisects below all **negative** — experimental gates reverted. |
| **I4 Verify** | default cookie **51b1babe** (natural strlen + soft getprop) on work-ver-smt2-fw64 |
| **Bisects (all negative)** | (1) dual-GPR dual-commit; (2) full dual-commit serialize (`fw64c`); (3) STQ-nofwd under SS + `st_pipeline_busy` (`fw64d`); (4) force SI issue `issue_ack_o[p>0]=0` (`fw64e`) — **identical** mepc=0x12eb2 mtval=0x12b2a s2=ra. Not dual-commit / dual-issue / STQ-forward alone. |
| **Disasm pin** | `by_offset_`: `mv s2,a2`; `jal check_prop`; `bltz` → `sw a0,0(s2)`. s2 should be lenp; observed s2=ra of `check_node→next_tag`. Frame sp/s0 intact. |
| **Directed** | `mini_fdt_lenp_sw.S`, `mini_fdt_s2_nest.S` (bare PASS; OpenSBI path still red) |
| **Oracle path** | `software/smt2-linux/soft-ladder/` |
| **I6 Next** | Deeper: corrupt `a2`/`s3` *before* by_offset (lenp already code), or structure-load walk making check_prop fail + separate s2 poison; dual-fetch/IQ; RF write of link. Keep soft getprop. Topology: `../fdt-topology-soft-ladder.md`. AGENTS-todo SL-A..E. |

---

## Completed iterations

### iter-011 — Stock sbi_strlen mid-RVI residual (closed: FETCH_WIDTH=64 + peel)

| Field | Value |
|-------|--------|
| **Completed** | 2026-08-09 |
| **Result** | FETCH_WIDTH=64 fixes mid-RVI. Natural strlen default; soft `fdt_getprop_namelen` + soft printf keep cookie. Soft strlen ret-imm is bisect-only (`SOFT_STRLEN=1`). |
| **Next** | iter-012 FDT getprop/lenp |

### iter-010 — Heap freelist / PEEL_MALLOC (closed: peeled)

| Field | Value |
|-------|--------|
| **Completed** | 2026-08-09 |
| **Result** | PEEL_MALLOC×2 cookie **51b1babe** coldboot_done=1; `mini_freelist_unlink` PASS. Default natural malloc. Historic f0ba mcause=6 unblocked by AMO/spin peels. |
| **Next** | iter-011 PEEL_STRLEN |

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
| 1 | `b1-fdt-lenp-store` | B1 | **active** — soft getprop; PEEL_FDT_GETPROP → 12eb2 mcause=6 |
| 2 | `b1-sbi-strlen-rvi` | B1 | **peeled** natural strlen (FETCH_WIDTH=64) |
| 3 | `b1-heap-freelist-malloc` | B1 | **peeled** natural malloc default |
| 4 | `b1-dual-cmv-s3` | B1 | **peeled** natural c.mv default |
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
