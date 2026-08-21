# Firmware-boot principles — what the core must guarantee

**Status:** normative. Two phases, in order:

1. **Handoff** — today's g1\* frontend (**handoff A**) vs `core/fetch/` (**handoff B**). When B's
   hold matches A, **retire A to `core/smt_legacy/`** (flist-only oracle).
2. **Capabilities** — **after that retirement**, `core/fetch/` **is A**. New work is A/B on that
   tree: peels and integration (mini → one RTL class → hold soak → retire soft) are the **same
   loop** as soft-ladder. This phase is how n-wide, stream, speculation, `RVH`, leftover present,
   etc. are added — not by grafting `g1*` onto fetch.

Soft-ladder (`multi-threading/soft-ladder/`) is **evidence** only (tag `g1-archive`). Do not add a
381st `g1*` predicate. Read [`core-fetch/NEGATIVE.md`](core-fetch/NEGATIVE.md) before proposing
anything in fetch, redirect, or squash.

Cross-plane: [`core-fetch/SPEC.md`](core-fetch/SPEC.md) · [`core-fetch/VALUES.md`](core-fetch/VALUES.md) ·
[`branch-prediction/`](branch-prediction/) · [`speculative-execution/`](speculative-execution/) ·
[`out-of-order/`](out-of-order/) · [`multi-threading/`](multi-threading/) · [`multi-core/`](multi-core/) ·
[`stream8-class.md`](stream8-class.md)

---

## 0. One paragraph

OpenSBI is ordinary RV64GC. It fails on `g6lc64_smt2` because that configuration does not implement
RV64GC correctly in (1) RVC realignment when `FETCH_WIDTH=64` yields four slots and 32-bit ops
straddle 8-byte windows, (2) fetch-redirect priority when trap, thread switch, and mispredict
contend, and (3) a speculative-recovery path patched into dropping architecturally required
writes. Fix those three **generically** on `core/fetch/`. During handoff, keep the g1\* frontend as
the cookie oracle. **After it is retired to `smt_legacy`**, fetch **is A** and capabilities are
added as B increments with the same peels and soak.

---

## 0.1 Phase 1 — Handoff (retired): g1\* frontend vs fetch

Hold/peel cookie-matched. Layout after retirement:

| | Oracle (g1\* / `smt_legacy`) | Default workspace B (`fetch_B`; frozen A is `core/frontend`) |
|--|--|--|
| RTL | `core/smt_legacy/` (g1\* frontend copies + recover + SMT banks) + `Flist.smt_legacy` | Frozen A: `core/frontend/` + `core/instr_realign.sv` + `core/smt/g6lc_fetch_{pkg,dbg}`. Default B: `core/fetch_B/` + `Flist.fetch_B` + `G6LC_FETCH_B` |
| Harness | `work-ver-smt2-slfix` | `work-ver-smt2-fetchb` |
| Role | opt-in cookie oracle | default instruction supply (`fetch_B`); A is frozen |

Do not compile both frontends. Do not use `g6lc64_di1` as the soak; do not stub TB `mepc`/`gpr` to 0.
`core/smt/` is pkg+dbg only (duplicates of `core/frontend` / `instr_realign` removed).
`core/fetch_B/` is the R6–R11 workspace (byte copy of retired fetch at `3745cfb06`)
for `sbi_console_init`, HSM start, `sbi_hart_switch_mode`. Predictors stay in
`core/frontend`. Nat still has no `ret@1826e` / console.
`smt_legacy` inventory (banks required on B vs recover vs oracle frontend):
[`core-fetch/SMT-LEGACY.md`](core-fetch/SMT-LEGACY.md).

**Live handoff pin:** B hold and peel are **cookie-green** (fetchb `ec1239ef`).
Hold: `[1000]=51b1babe` cave WFI `@0xef98` `plat_hc=2` BANR. Peel:
`[1000]=51b1babe` `[1008]=51b1d000`. Nat (pin `bc7ed11d`) is **not**:
`51b1c001` @`71e4` commits (I1 ok); hang `sbi_hsm_init` `@0xf796`; no
`ef70` fetch. A slfix cookies nat at t=83968 with `plat_hc=80` `sp1=0`.
`Flist.smt_legacy` is the opt-in A oracle (do not compile with `Flist.fetch`).
Do not port A's nat path if it is fabricate. Nat `ret@f772` → `0x8000081c`
is the **correct** `sbi_init` link (`bnez a0` after `jal hsm_init`); a0=0;
`coldboot_done` and `sbi_hart_init` **run** (expected-trap PMP commits).
Hold ELF is **SOFT_HART_INIT** (`li a0,0; ret` @`cccc`) — that is why hold
never visits `ce00`/`e280`. Nat TRACE: PMP grain + leftover `c.srli@ce64`
**presented** (`hw=9281 ok=1`); four expected-trap `mret`s complete; then
`csrrw mtvec` @`ec0c` dual-issues with `csrr tselect` @`ec10` (I13 hole):
handler writes `mtval=7a002673` and **stops before `mret`**, restore
`csrw mtvec` @`ec14` commits, `a5=2` takes the no-debug path @`ec1e`.
No `ret@cd22`, no `console_init@844`. Hart1 HSM-waits (`ra=f7a0`).
Dropping page-0 execute **HOLD-FAIL**. I13 `stall_csr_older` **landed**
(fetchb `856d8292`): hold cookie; tselect handler now `mret`s (mepc skip
`ec10`→`ec14`). Nat still no `ret@cd22`. Post-tselect `c.jalr a5@ec6e` **resolves**
(`src=6` `tgt=0x80007282`); mid-window I2 `hw=1101 ok=1`. Callback
enters; `jal@1826a` predicts `13884` (`cf=2`). `fdt_path_offset@13884`
and `fdt_ro_probe@12544` **commit** (`a0=0x82200000`, ra=`138a6`/`13792`);
probe returns `a0=0xaf5` (FDT totalsize). Walk continues (`jal@137ea`→
`13410`, nested probe ra=`1342c`). Never `ret@1826e`/`72a4`. Global at
`0x80040d60` is file-0, runtime `0x82200000` (not in ELF; 2 MiB past
`0x80200000`). Next: that R4 walk, not jal / leftover-keep / I17 / PMA.
`Flist.smt_legacy` is the opt-in A oracle.

---

## 0.2 Phase 2 — **after** `smt_legacy` retirement: fetch is A, capabilities are B

This is the standing process. Soft-ladder buckets and P1–P4 are unchanged; only the **RTL home** is
`core/fetch_B/` (plus issue/LSU when the capability is not fetch). Frozen A is `core/frontend`.

| Soft-ladder | After retirement |
|-------------|------------------|
| **A** | Frozen `core/frontend/` + `core/smt` pkg/dbg (last green) + last green peels |
| **B** | `core/fetch_B/` + **one** capability or one VALUES row |
| **P1 mini** | Directed fail-codes on **A**'s package (`g6lc64_smt2` or the envelope being enabled) |
| **P2 RTL** | One class in fetch combos / `fetch_en_t` — or issue/RAW if not fetch |
| **P3 integration** | `soak.sh` hold+nat+peel; cookie `51b1babe`; `CVA6_COOKIE_EXIT` |
| **P4 peels** | Same pin/held/peel/nat ELFs. Soft getprop stays until `plat_hc==2`. Drop a `mk_plat_skip` site only when B's hold is green **without** that peel |
| **SUCCESS** | trapdump cookie, not harness tohost=0 @400000 |

Adding a **capability** (this is the point of Phase 2):

| Capability | B is | Peel / integration |
|------------|------|--------------------|
| Leftover / present-at-npc (R4, R8) | L1/L2 VALUES row | minis then hold; no sibling `c.jalr` fabricate |
| Precise trap (R3) | L4 I9 bounded hold | `mini_csr_expected_trap` then hold |
| Indirect `jalr` (R5) | L4 resolve unfiltered (I11); predict-only legality | lottery mini then hold |
| Stream I=1 → I=2 | `geo.issue=2`, `en.restore=0` | stream leftover mini + stream FDT shape; **not** smt2 7ba; catalog G1 keep may arm — soak keep, not recover |
| n-wide 2→4 | `geo.issue=4`; L3 loop | sibling mini only if `T>1`; barrier/keep re-soak |
| `NrCores` 1→N | no fetch edit | DTS `cpu-map`, CLINT `S=N×T`, `stream8-smoke` |
| `NrHarts` 2→4 | `geo.harts`; leftover banks | G3 `sp==0` mini; `check_cfg` |
| `RVH` | inject suppressed on I$ exception; no H ports | H-edge on **that** package; DTS `h` iff `RVH=1` |
| RVV / Ara | no fetch ports | `_v` package after AI-2; DTS `v` only there |
| DeepSpec / OoO | flush/mispredict levels; maybe `hold_max` | `ooo-l3-tests`; no `mem_q` scan in fetch |

B fails hold → revert **that** capability increment; A (last green fetch) is untouched. A new fetch
**port** is a review. Peels never hide an open B1 hole (soft-ladder P5).

`smt_legacy` may stay as an opt-in bisect (`Flist.smt_legacy`) after retirement. It is **not** A
anymore and is not the plane for new capabilities.

---

## A. What firmware demands of the core

Derived from the OpenSBI coldboot path (`CONT-FULL-MAP.md`, `b1-rtl-residuals.md`). Each row is a
**capability**, not a workaround.

| # | Firmware activity | Core capability required |
|---|---|---|
| **R1** | `_start` → `_start_warm`: hart-id scan, `sp` init, boot-hart election | Per-hart state from reset; non-boot hart holds `sp=0` until *its* code writes it |
| **R2** | `sbi_init`, `coldboot_done` | Ordinary load/store/branch |
| **R3** | `sbi_hart_init` CSR probes via `__sbi_expected_trap` | Precise trap; handler at `mtvec` fetched and executed; correct 2-vs-4 `ilen` |
| **R4** | libfdt walk (nested, heavily RVC) | Mixed RVC/RVI at every 2-byte alignment; callee-saved + `ra`/`sp` survive speculation |
| **R5** | Platform ops `c.jalr` through a function-pointer table | Indirect branch; mispredicted `jalr` recovers to the architectural target |
| **R6** | Heap freelist | Store-to-load forwarding complete |
| **R7** | Ticket spinlocks, LR/SC | AMO forward progress; reservation not clobbered |
| **R8** | `sbi_printf` / `strlen` | Same as R4 |
| **R9** | Domain / ecall / HSM | Ordinary correctness + per-hart HSM |
| **R10** | `switch_mode` → S-mode | `mret`, privilege, `mstatus` |
| **R11** | Both harts visible to HSM | Per-hart `mhartid`, CLINT, CSR bank |
| **R12** | Linux Sv39 | MMU; two-stage under `RVH` |

R1, R3, R4, R5, R8 were ~90% of 380 increments. R4≡R8 (mixed C/I). R3≡R5 (redirect). **Two**
capability gaps.

---

## B. The invariants

Testable without OpenSBI. Against `CVA6Cfg` only — never a literal address, register, or encoding.

### B.1 Instruction supply ([`core-fetch/SPEC.md`](core-fetch/SPEC.md), [`VALUES.md`](core-fetch/VALUES.md))

| # | Invariant |
|---|---|
| **I1** | Decode is a function of bytes and address alone. Not `FETCH_WIDTH`, not which line delivered it, not slot count, not a previous instruction, not a register value. |
| **I2** | For every even `a`, the realigner emits exactly the ISA instructions at `a`, `a+ilen(a)`, … until the window is exhausted. No fabricate, duplicate, reorder, or rewrite downstream of the realigner. |
| **I3** | A 32-bit instruction whose low halfword is last in a window is leftover and completes **only** from the next window in address order. |
| **I4** | Leftover is **per-hart**. |
| **I5** | Leftover completable only if the low halfword is a legal RVI prefix (`[1:0]==2'b11`). |
| **I6** | IQ order is program order. Head selection must not depend on opcode, `rd`, or FU. |
| **I7** | If a window is dropped, *all* of its slots are dropped. Partial acceptance is illegal. |

### B.2 Fetch redirect

| # | Invariant |
|---|---|
| **I8** | Redirect sources have a total priority: `reset > exception-entry > eret > CSR/fence pc-commit > debug > SMT restore > branch resolution > replay > prediction > sequential`. A priority encoder, not a chain of `if`s. |
| **I9** | Exception-entry to `mtvec` is held until that instruction is consumed by decode. Bounded (I23). |
| **I10** | Thread switch never loses progress: outgoing next-PC banked, incoming restored; no foreign fetch-ahead. |
| **I11** | Mispredict always redirects to the resolved target. Resolution is never filtered by value. |
| **I12** | Sequential step is exactly the bytes consumed (one **window**, not +2). |

### B.3 Speculation and recovery

| # | Invariant |
|---|---|
| **I13** | On mispredict, squash exactly younger-in-program-order. Membership is program order only. |
| **I14** | Squash window from the resolving branch's own identity. Shared EX aliasing invalidates it. |
| **I15** | Squashed instructions perform no architectural write; non-squashed perform every required write. |
| **I16** | A store that has forwarded has architectural effect; a cancelled store that has not must drop. |
| **I17** | Forwarding is transparent. Never select forwarded vs RF by inspecting the value. |
| **I18** | Under `NrHarts>1`, squash is same-hart only. |

### B.4 Branch prediction

| # | Invariant |
|---|---|
| **I19** | Prediction is a hint and may be suppressed. **Resolution is not a hint.** |
| **I20** | Predictor tables may be shared; RAS/GHR/checkpoints are per-hart when `NrHarts>1`. |
| **I21** | Address-legality tests use the same translation regime the fetch will use. |

### B.5 Multi-hart / multi-core

| # | Invariant |
|---|---|
| **I22** | Per-hart precise traps and isolation (GPR/FPR/CSR/PC/priv/leftover/RAS). |
| **I23** | No starvation: every ready hart granted fetch within a bound. Every hold carries an explicit bound. |
| **I24** | RVWMO within and across harts/cores. |
| **I25** | `mhartid` unique: `hart_id_i + h`; DTS reports `NrCores × NrHarts`. |

### B.6 Identity

| # | Invariant |
|---|---|
| **I26** | Every envelope in §F.2 is correct on its own. Never gate a fix on an unrelated parameter. |
| **I27** | Reducing a knob to baseline yields a netlist bit-identical to that baseline. |
| **I28** | Behaviour gated on a parameter must be *explained* by that parameter. |

---

## C. Root causes

| | Claim |
|--|--|
| **RC1** | smt2 is throttled to single-issue (`fus_busy` after almost every FU). `SuperscalarEn` mainly raises `FETCH_WIDTH` 32→64. |
| **RC2** | ~1600 predicates gated `SS && NrHarts>1`, but the geometry is `SS ∧ RVC`. **A/B on smt2** decides this: B has no those predicates. If B still fails firmware, the hole is generic fetch (B's job). If B boots and A does not, A's gates were load-bearing. |
| **RC3** | `make_cjalr16` fabricates instruction bytes. Stays in A/`smt_legacy` only. B never synthesises opcodes. |
| **RC4** | Shared EX `one_cycle_data` / `flu_trans_id` can alias identity. Latent until throttle lifts. Not a fetch row. |
| **RC5** | Commit-stage value filters and forced cancelled writes. CF-0 landed the revert on E:\cva6; keep them off B and off any reintroduction into `smt_legacy`. |

---

## D. Experiments (search on minis; firmware is the gate)

| # | Experiment | Status |
|---|---|---|
| **AB-0** | Compile B (`G6LC_FETCH_B`) and A (`smt_legacy`/current frontend) as two harnesses on **smt2**. Same ELF. | **Landed** (`work-ver-smt2-fetchb` vs `work-ver-smt2-slfix`) |
| **AB-1** | Minis: `mini_sib_cjalr`, `mini_jalr_bnez_lottery`, `mini_fdt_a0_is_fdt` on both | first gate; fail-code names the **value row** |
| **AB-2** | Hold ELF TRACE: `_fw_start` 0x2a…0x5e, then `mtvec`, then first `hangpc` | **in progress** — B matches A through relocate + mtvec; pin `sbi_scratch_init` @`3912` |
| **E1** | Optional: same B on `NrHarts=1` **after** TB can dump gen_single CSR/RF honestly | not first; do not stub dumps |
| **E2** | Optional: `NrHarts=2`, `I=1`, `FW=32` | isolates SMT from geometry |
| **E4** | Mini sweep I × RVC × T | envelope matrix |
| **E5** | Spike committed-stream vs B | instruction oracle |

Firmware soak is a **gate**, not a search signal. Cookie is not a new peel site.

---

## E. ISA red lines

CF-0 on the lab tree reverted the commit-stage value filters, forced cancelled writes, value-inspecting forwards, and resolution-time PMA suppress. **Do not re-land them on B or into `smt_legacy`.** Remaining: `g6lc_sb_keep` exemption list is A-only and must not migrate; `g6lc_jalr_usable` on B is prediction-only or absent.

| Class | Illegal behaviour |
|---|---|
| Commit value filter | Drop `x8` unless 8-byte aligned; drop `x1` if result < 4 KiB |
| Cancelled writeback | Force GPR write for cancelled CTRL_FLOW/LOAD |
| Forward-by-value | Choose RF vs forward by page-zero / PMA / exec-region |
| Resolve-by-PMA | Suppress `is_mispredict` when target misses physical execute PMA |
| Squash exemption list | Keep-by-register / keep-by-imm / keep-by-FU |

---

## F. Configurability contract

B's equations use `fetch_geo_t` / `fetch_en_t` ([`VALUES.md`](core-fetch/VALUES.md)). **No** literal slot index, bit-range, encoding, register number, or `FETCH_WIDTH>=64` guard.

| Plane | Parameters | B obligation |
|---|---|---|
| **n-wide** | `NrIssuePorts` 1..8 | L3 loops `0..issue-1`. Fetch window ≠ issue width |
| **Fetch geometry** | `FETCH_WIDTH`, `FETCH_ALIGN_BITS`, `INSTR_PER_FETCH`, `RVC` | `g6lc_fetch_pkg` only |
| **SMT** | `NrHarts` | leftover/restore banks; `en.restore` |
| **Stream / cores** | `NrCores`, `T=1` | per-core instance; `en.restore=0`; no cluster ports |
| **Speculation / OoO** | `SpeculativeSb`, `DeepSpecEn`, `OoOEn`, `BPCkptDepth` | flush/mispredict levels; no fetch ports |
| **RVV / AI / RVH** | `RVV`, `EnableAccelerator`, `RVH` | no acc/`vl`/`gva` ports on fetch; exception pass-through |

Identity matrix (minis + lint on **fetch**. During handoff, slfix soak is the g1\* oracle. After
`smt_legacy` retirement, fetch **is A** and envelope B soaks use the same peel/hold loop):

| Config | N | T | I | Role vs fetch |
|---|---|---|---|---|
| `cv64a6_imafdc_sv39` | 1 | 1 | 1 | upstream identity |
| `g6lc64_smt2` | 1 | 2 | 2 | **A/B oracle** |
| `g6lc64_stream8` | 2 | 1 | 1 | stream; B with `en.restore=0` |
| `g6lc64_ooo` / `_ooo_server` | 1 | 1 | 2/4 | n-wide / OoO; B ports frozen |
| `g6lc64_server_math_v` / `_ai` | 1 | 1 | 2 | RVV/AI; no fetch ports |
| `g6lc64_di1` | 1 | 1 | 2 | optional lint control, **not** the OpenSBI soak |

---

## G. Process

Handoff (until `smt_legacy` exists): one VALUES row on fetch vs g1\* oracle; cookie is the gate.

**After retirement**, same loop as `multi-threading/soft-ladder/README.md` P1–P4, with fetch as A:

| Soft-ladder | Capability A/B (fetch is A) |
|---|---|
| Cookie as search signal | Minis + `fetch_snap_t`; cookie **gates** hold |
| New `g1*` flop | New VALUES row or `fetch_en_t` bit |
| `NrHarts>1` as SI identity | const-fold `en.restore` |
| Inline HOLD-FAIL | `NEGATIVE.md` |
| Peel new VAs | **no** — only retire existing `mk_plat_skip` when hold is green without that peel |

**Rails kept:** don't regress A; fail → revert that B increment; I27; one capability per increment; peels last.

**Rails discarded:** cookie-first search; g1\* on fetch; di1 as a substitute for handoff A/B.
