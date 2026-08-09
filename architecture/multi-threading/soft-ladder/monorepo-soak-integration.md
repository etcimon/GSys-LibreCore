# Monorepo-soak × cont.## × soft-ladder integration

Cross-map of `monorepo-soak/*` lab patches with soft-ladder **cont.33–51** and the
three-bucket promotion model. Goal: **bring RTL up to date** without treating
binary OpenSBI peels as permanent.

Sources:
- `monorepo-soak/L2-OPENSBI-HANG-PROGRESS.md` (hang-1…7, dual-issue FDT)
- `monorepo-soak/patch-*.py`, `fix-*.py`, `wire-*.py`, `restore-*.py`
- Soft ladder: `smt2-bringup.md` cont.33–51, `inventory.yaml`

---

## 1. How the two workstreams relate

| Stream | What it is | Primary artifact |
|--------|------------|------------------|
| **monorepo-soak** | Lab scripts that **wrote RTL/TB/docs** on the soak host (`E:\cva6`) | Python patchers + hang logs |
| **cont.## soft ladder** | Binary OpenSBI peels on DI (`mk_plat_skip.py`) | Soft sites + mepc pins |
| **soft-ladder/** | Promotion structure | B1/B2/B3 + iterations |

**Unified rule:** monorepo-soak hang fixes that are already in RTL = **B1/B3 landed**.
Soft-ladder cont.## that still soft-patch OpenSBI = **still open** until RTL or
source policy retires them.

---

## 2. Monorepo-soak classification (apply / skip)

### A. RTL patches — **apply / keep in tree** (B1 or SMT)

| Script | Domain | Soft-ladder / cont link | Disposition |
|--------|--------|-------------------------|-------------|
| `patch-amocas-q-rtl.py` + `rtl2` + `commit` + `issue-stall` + `raddr` | Zacas AMOCAS.Q | Adjacent B1 atomics; not soft-ladder spin | **Keep landed** on E:; **sync into worktree** if missing |
| `restore-amocas-q-rtl.py` | Revert experimental casq | — | Only if undoing a bad experiment |
| Hang-4 `instr_queue` realign PC | Dual-issue fetch PC | cont.19 dual-issue family | **Already in both trees** |
| Hang-7 scoreboard younger cancel / `ckpt_restore` / frontend RAS notes | Dual CF | cont. hang-6/7 FDT CF; supports B1 dual-issue | **Landed** (partial both trees) |
| `patch-raw-hart.py` | SMT RAW hart-aware | multi-hart | **Sync if missing** |
| `patch-rf-whart.py` | SMT RF write hart | multi-hart | **Sync if missing** |
| `patch-dual-wfi-halt.py` | Per-hart WFI | SMT | **Sync if missing** |
| `patch-smt-switch-align.py` | Thread switch align | SMT | Review then keep |
| `patch-smt-*-boot*.py` / hold / kick / force | Coldboot exclusivity experiments | B2/B3 multi-hart | **Do not re-apply blindly** — many reverts exist; prefer stable subset on E: tip |
| `fix-amocas-q-*.py` | AMOCAS debug | — | Historical; prefer final amocas patches |

### B. TB / verif — **apply as B3**

| Script | Disposition |
|--------|-------------|
| `patch-trap-dump-tb.py` | **Keep** trapdump in TB (`CVA6_TRAP_DUMP`) — soft-ladder SUCCESS depends on it |
| `fix-dual-iss-tohost.py` / `fix-dual-iss-map.py` | Keep dual-iss regress helpers |
| `wire-kvm-h-veri.py`, stream8/stability wires | Suite-specific; land only with matching tests |

### C. Docs-only — **apply as documentation**

| Script | Disposition |
|--------|-------------|
| `patch-s4`…`s8-docs.py`, `patch-h-edge-*-docs.py`, concurrent/stream8 docs | Prefer hand-maintained `architecture/` + `AGENTS-*` over re-running generators |

### D. Do **not** treat as production RTL

| Class | Why |
|-------|-----|
| Temporary NrIssuePorts=1 unblock | Lab bisect only (`L2-OPENSBI-HANG-PROGRESS`) |
| RASDepth 2→16 without soak | Documented **regress** |
| unresolved-CF full issue stall | Documented **regress** |
| force-casq-off / force-is-quad0 experiments | Debug |

---

## 3. cont.## → integration target

| cont / pin | Bucket | Monorepo-soak overlap | RTL action |
|------------|--------|----------------------|------------|
| cont.19 dual `c.mv` | B1 | Dual-issue ID/RF | Directed dual `c.mv` test + issue/scoreboard review |
| cont.21 trapdump t1 | B3 | `patch-trap-dump-tb` | Keep TB; not core logic |
| cont.33 CSR expected-trap | B1 | — | New directed CSR DI residual |
| cont.44 FDT lenp / hang-6/7 FDT walk | B1 | **hang-6/7** (same family: FDT walk under dual) | Continue dual-issue load/CF; soft printf until fixed |
| cont.47 AMO spin | B1 | Hang-1..3 AMO/interconnect history | AMO path + dual-issue AMO |
| cont.49–50 LR/SC cmpx | B1 | AMOCAS.Q landings adjacent | LR/SC residual separate from casq |
| cont.46–51 domain multi-iter / ecall poison | B2 (+ possible B1 mem) | hang-6 structure walk | Domain cut until load/CF solid; no soft ecall |
| cont.49–51 soft switch_mode | B2 | — | Platform profile |

**Key insight:** hang-6/7 FDT corruption and soft-ladder **b1-fdt-lenp-store** / dual residual are one program: dual-issue infrastructure + load/CF integrity under OpenSBI FDT walks.

---

## 4. Worktree vs `E:\cva6` (2026-08-08 audit)

| Area | Worktree | E:\cva6 (lab tip) |
|------|----------|-------------------|
| Hang-4 instr_queue PC | Present | Present |
| Hang-7 cancel/ckpt/frontend notes | Partial | Fuller |
| AMOCAS.Q dual_we / raddr / commit | **Missing** | **Present** |
| raw_checker hart-aware | **Missing** | **Present** |
| TB trapdump | **Missing** | **Present** |
| Soft-ladder promotion docs | Present | Mirrored |

**Action for “RTL up to date”:** sync the monorepo-soak **landed** RTL/TB set from `E:\cva6` into the worktree (see §5). Do **not** re-run experimental SMT boot force scripts.

---

## 5. Sync set (monorepo-soak landings → worktree)

Copy from authoritative lab tree when bringing cleanup worktree current:

```
core/include/ariane_pkg.sv
core/decoder.sv
core/amo_buffer.sv
core/commit_stage.sv
core/issue_read_operands.sv
core/issue_stage.sv
core/scoreboard.sv
core/raw_checker.sv
core/cva6.sv
core/cache_subsystem/cva6_hpdcache_if_adapter.sv
core/cache_subsystem/miss_handler.sv   # if dual_we defaults present
core/smt/g6lc_smt_csr_bank.sv
core/branch_unit.sv                    # if tip has R3a younger-cancel tid
corev_apu/tb/ariane_tb.cpp             # trapdump
```

After sync: `inventory.yaml` mark related AMOCAS items as rtl-landed; keep B1 open for spin/LRSC/FDT.

---

## 6. Iteration plan (after sync)

| Iter | Focus | Source |
|------|-------|--------|
| **002** | Confirm AMOCAS + dual-issue landings elaborate; dual-iss smoke | monorepo-soak AMOCAS |
| **003** | `b1-amo-spin-lock` directed test + RTL | soft-ladder cont.47 |
| **004** | `b1-lrsc-cmpxchg` | cont.49–50 |
| **005** | FDT dual residual (hang-6 family / lenp) | hang progress + cont.44 |
| **006** | B2 source profile shrink mk_plat_skip | b2-firmware-policy |

---

## 7. Safety

1. Prefer **file sync of known-good tip** over re-running old patch scripts (scripts are not always idempotent; some leave botched replaces).
2. Re-run patch scripts only with `ROOT` pointed at a clean tree and after reading the script.
3. Every sync: note in `ITERATION.md` which paths and that concurrent/DI OpenSBI cookie should be re-soaked on lab host.
