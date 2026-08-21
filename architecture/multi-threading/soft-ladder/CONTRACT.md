# Soft-ladder contract — G1 genericity / least-coupled SMT2

What later **all-feature enable** and **core increases** along the specified
architecture envelopes (AI / OoO / BP / stream / RVV / `RVH` / L2–L3 /
`NrCores` 1…8) may skip *re-reading* living G1\* internals — and how remaining
recover is refactored toward that.

OpenSBI stays a **software plane**. RTL owns a **compressed dual-issue SMT
fetch class**, not ELF PCs. Catalog G1 (`g6lc_sb_keep`) is already extracted;
this file is the living recover (`G1kk`–`G1mf`) contract.

Cross-refs: `COMPLETION.md` (binding loop, SL-D/E) · `EXTRACT.md` (E0–E3 pattern) ·
`../fdt-topology-soft-ladder.md` · `../../stream8-class.md` ·
`../../server-math-hypervisor.md` · `../../remaining-upgrade-sequence.md` ·
`../../multi-core/README.md` · `../../../agents/guides/AGENTS-vector.md` ·
`AGENTS.md` §0.1.2 / §0.1.5.

**Baseline kept:** G1mf slfix `64f6c38e` / BuildID `850ebd78`. Cookie
`51b1babe` only. Soft getprop stays until `plat_hc==2`. **G1mg is not next.**

---

## 0. Two G1s (do not mix)

| | Catalog **G1** | Living **G1\*** (`kk`–`mf`) |
|--|--|--|
| Status | Soaked 2026-08-15 | Open (`7ba` still Branch at EX; no `@71e4`) |
| Home | `core/smt/g6lc_sb_keep.sv` | Inlined `frontend.sv` / `id_stage.sv` / `scoreboard.sv` |
| Action | Younger-cancel **keep** of ABI regs | **Rewrite** sibling `01` Branch → `c.jalr rd` |
| Later axes | Re-soak keep/cancel if OoO/SB width changes | Must extract before “without review” is meaningful |

Named class (predicates are already generic; OpenSBI is comments only):

> Aligned `pc[2:1]==00` RVI LOAD (`rd≠0`) recovers the sibling 8-byte half
> `pc[2:1]==01` **when that slot is Branch-bits** as `c.jalr` of that `rd`.
> Gate: `SuperscalarEn && NrHarts>1` (almost always `FETCH_WIDTH>=64`).
> SI never arms.

No RTL comparator of `0x800007ba` / `71e4` exists. Coupling is TRACE-named
flops. That is enough to train the next increment on one ELF.

---

## 1. What “without being reviewed” requires

It does **not** mean nobody looks. A later axis **does not re-open
`frontend.sv` recover archaeology**. It still runs the **soak table**
below. If that suite is green and the recover module’s **ports are
unchanged**, the axis may ship without a G1\* re-read.

All of the following must hold (today several are false — see §7):

1. **One named module** owns recover (`core/smt/g6lc_sib_cjalr`). Hosts only
   **call** it. No new `g1*` flops in tier-U files.
2. **This file** is the spec of record — not OpenSBI VAs.
3. **SI / stream-T=1 identity:** `!(SuperscalarEn && NrHarts>1)` const-folds
   recover off. `g6lc64_stream8` (`T=1`) and `NrHarts=1` packages elaborate
   without the sibling latch. Layer 1 present-at-npc is a **dual-issue RVC**
   class (see §3 gate split / §6.2) — do not keep it forever glued to `NrHarts>1`.
4. **SMT2 recover/keep/kill predicates live in `core/smt/g6lc_*`.** Remaining
   G1\* peel map: `EXTRACT.md` **Migration map** (E4–E9). Hosts call; leftover
   FSM / IQ rotate / NPC stay in frontend/realign/IQ. New SMT2 behavior lands
   in a module, not a new `g1*` flop.
5. **No OpenSBI in RTL.** No PC compares, no `plat_hc` heuristics. Scheduler
   exclusive-until-boot is architectural (WFI / halt / per-hart `sp`
   published), not `SMT_COLD_EXCL` as a lottery stand-in.
6. **Port freeze.** BP / OoO / `NrCores` / AI / Ara / `EnableAccelerator` /
   `RVV` / cluster snoop / `RVH` / `priv` / `V` / `gva` / `hfence` do **not**
   add ports to the recover module. A new input **is** a G1 review. Fetch
   exception sideband is **pass-through**, not an H control port (§6.5).
7. **Geometry is parameterized** (`VLEN`, `FETCH_WIDTH`, `addr[3]`,
   `pc[2:1]`), not 8-byte vs 16-byte comments from one I$ slice.
8. **Soak table green** on that axis’s package. Fail → review recover or
   grow the mini — not a new lettered latch.

### Soak table (the actual “review” of a later axis)

| Oracle | Pass means |
|--------|------------|
| `mini_jalr_bnez_lottery` | Compressed jalr + bnez + leftover jal **shape** (not VA `752`) |
| `mini_fdt_a0_is_fdt` | libfdt pointer/callee-saved **shape** (not `129f8`) |
| `mini_sib_cjalr` | `ld rd @00` + leftover jal x0 + sibling `01` executes as `c.jalr rd` |
| Hold ELF cookie `51b1babe` (+ nat `51b1d000`) | Integration still holds; **not** topology truth |
| SI smoke (`NrHarts=1`) | Recover const-folded |
| Stream8 smoke (`g6lc64_stream8`, T=1) | Recover still const-folded; `stream8-smoke` + CRT 9/9 + H-edge 3/3 |
| After SL-B: `plat_hc==2` + hart1 cold-boot | OpenSBI **confirm** — last, never first |
| RVV (`g6lc64_server_math_v` + live Ara) | `ara-vector-path` + directed `v_memcpy_*`; DTS `v` **only** on `_v` |
| Hypervisor (`RVH=1`) | `kvm-h-spike` / `kvm-h-veri` 3/3 on **that package**. DTS `h` **iff** `RVH=1`. smt2 today is `RVH=0` — H-edge is stream/server, not slfix hold |
| Core scale / all-feature envelope | Union soak §8.2 on **that named package**. Recover ports unchanged. `S=N×T≤8` |

If `mini_sib_cjalr` PASSes while OpenSBI `7ba` still hangs, **grow the mini**,
do not TRACE-name a new flop (G1dj lesson: lottery PASS @370 vs `752`).

---

## 2. Planes (least coupling)

```text
  software     GENERIC OpenSBI + DTS(N,T,ISA) + peels
               lottery / fw_boot_hart=-1 / HSM / printf / domain / plat_hc
                    │  confirm only
                    ▼
  recover      g6lc_sib_cjalr  (+ fetch-present helper if layer 1 extracts)
                    │  call
                    ▼
  hosts        frontend present / instr_realign / id_stage / IQ
               leftover FSM, kill_s1/s2, bp_valid  STAY HERE
                    │
     g6lc_sb_keep   g6lc_issue_barrier   g6lc_cf_unissued   U6.1 banks
     (catalog G1)   (stall only)         (flush/keep_line)  (RF/CSR/PC)
```

**Software owns:** hart lottery, FDT, HSM stack, printf, domain/`switch_mode`,
DTS `cpu-map`. `plat_hc` is a DRAM word OpenSBI writes. Soft getprop stays
until `plat_hc==2`.

**RTL owns:** honest compressed dual-issue SMT fetch/issue; banked RF/CSR/PC;
`mhartid = c×NrHarts+t`; CLINT/PLIC `S = NrCores × NrHarts`. Issue width is
**not** a hart.

**Do not put recover into:** `g6lc_sb_keep` (keep ≠ rewrite),
`g6lc_issue_barrier` (stall ≠ present), `g6lc_cf_unissued` (do not dump opcode
rewrite), scoreboard `mem_q` scan (`G1mf` — sunset; OoO will break it),
I$ `kill_s1`/`kill_s2` / `bp_valid` (frontend leftover/CF),
`acc_dispatcher` / Ara attach (RVV), cluster snoop / L2 (stream `NrCores`).

CVXIF dual (`AGENTS.md` §0.1.5): custom compute stays on the coprocessor
seam. Ara is the other sanctioned compute seam (`EnableAccelerator`). SMT
recover is the same idea — a `g6lc_*` seam so BP/OoO/AI/**RVV**/stream do not
edit `frontend.sv`. **CVXIF and Ara are mutually exclusive**; smt2 keeps
`CvxifEn=1` / `RVV=0` until a **named `_v` package** drops CVXIF.

---

## 3. Two layers (genericity)

The hole is **present the 16-bit at NPC**, not “ID invents JALR from last LOAD.”

| Layer | Rule | Home | Status |
|-------|------|------|--------|
| **1. Present-at-npc** | For `FETCH_WIDTH>=64`, every legal 16-bit start at `npc` is presented exactly once until consumed or architecturally redirected. Leftover-complete must not mash a **different** line onto `npc[2:1]==01`. | `instr_realign` + leftover FSM in frontend | Partial (`G1gx`). Live TRACE: at npc `7ba`, fetch_entry has c.jalr in neither half; leftover `766` and I$ `7c0` win |
| **2. Sibling recover** | If that 16-bit is lost and the sibling `01` slot is Branch-bits, rewrite as `c.jalr` of the preceding same-line `00` LOAD `rd` | `g6lc_sib_cjalr` | Living soup. Capture sources miss `7b0` at npc `7ba` |

Close the residual on **layer 1**. Layer 2 is a **bounded workaround** with a
sunset once layer 1 holds. More LOAD-latch sources (`G1mg`) push the wrong
layer. Keep `compressed_decoder` `G1gu` (high-half c.jalr when low is RVI
BRANCH). Do not re-land `G1gt`.

**Gate split (required for stream I=2, bit-identical until Phase 4b):**

| Layer | Gate today (living soup) | Gate after extract collapse |
|-------|--------------------------|-----------------------------|
| **1. Present-at-npc** | `SuperscalarEn && NrHarts>1` (same as recover) | **`SuperscalarEn && RVC && FETCH_WIDTH>=64`** — dual-issue compressed fetch, **independent of T** |
| **2. Sibling recover** | `SuperscalarEn && NrHarts>1` | stays **`SuperscalarEn && NrHarts>1`** — SMT leftover across threads |

Stream today is `I=1,T=1` → both off. Enabling stream dual-issue without this
split either (a) leaves leftover mash with no present fix (hang-6 family) or
(b) turns on SMT recover on a T=1 core (wrong class). EXTRACT Phase 3 stays
bit-identical (both SMT+SS). Phase 4b is the split, soaked on **stream8 I=2**,
not on OpenSBI `7ba`.

---

## 4. Module `g6lc_sib_cjalr` (not landed)

Package of pure functions (hit / encode `c.jalr rd` / is-00-RVI-LOAD /
is-01-Branch-bits) plus one optional sequential per-hart latch. EXTRACT
E0/E2 style. CERN-OHL-S / GSys-Commercial. `Flist.cva6` SMT block.

**Inputs (frozen):** slot `pc` / `instr` / `valid` / `hart_id`; optional
same-cycle `00` LOAD `rd` + line/`a3` from **present/issue** (not SB
`mem_q`, not commit); consume (IQ / sibling `01` presented); flush /
mispredict / `ex_valid` as **levels**.

**Outputs:** `hit` + `rd`; rewritten 16-bit `{4'b1001, rd, 5'0, 2'b10}`
and/or ID `op=JALR`, `fu=CTRL_FLOW`, `rs1=rd`, `rd=ra`.

**Non-goals (must not grow ports for):** `kill_s1`/`kill_s2` / `bp_valid` /
leftover NPC / I$ fill / IQ `idx_is` / thread_select / SB cancel / CVXIF /
cluster `NrCores` / snoop / L2 / `EnableAccelerator` / Ara AXI / `vl`/`vtype`
/ acc busy / `hstatus` / `hgatp` / `hfence` / `V` / `gva`. Recover does not
assume `BPType=BHT` (stream8 is `TAGE_LITE`) and does not assume `RVH=0`.

**Invariant:** rewrite only mid-line `01` **Branch-bits** (`G1je`/`G1lm`/`G1gt`
stay dead). Do not steal leftover slot0 (`G1es`/`G1in`). **Do not rewrite or
inject when the I$ beat has a fetch exception** (`FE_INSTR_GUEST_PAGE_FAULT` /
page fault / access fault) — pass `gpaddr`/`tinst`/`gva` through unchanged
(`frontend.sv` already captures those under `RVH`). SI: functions false.

---

## 5. Phases (one class per increment)

Hold-FAIL → revert that increment. Mini-first except bit-identical extract.

| Phase | What | Status |
|-------|------|--------|
| **0** | Freeze capture archaeology. **Do not land G1mg.** Living soup kept until extract. | **now** |
| **1** | Directed `mini_sib_cjalr` (fail-codes). Lottery + FDT stay regression. Isolated P4 stays. | **soaked** P0–P2 @431. P3 @518. P4 @597. skip-range HOLD-FAIL. later_br_01 MINI-FAIL FDT 23 @1184 (G1iz class) — reverted. sib8_fetch MINI-FAIL FDT hang @400000 (G1jd) — reverted. hi8_npc_fetch MINI-FAIL lottery 4 @362 (G1ja) FDT 57 @445 (G1jd) — reverted. lo11_npc00 MINI-FAIL sib P0 fail 1 @407 / FDT 0x10 @423 — reverted (jalr-target `[2:1]==11`). lo_pc_npc00 HOLD-FAIL plat_hc=80 mepc 0xb0/2 — reverted. ljx0_off / ljx0_pc / ljx0_bp hygiene. sib_lo_s2 MINI-FAIL G1jp — reverted. lo_ld_stay HOLD-FAIL 51b1c001 — reverted. lo_ld_lo11 hygiene. hi8_lo11 MINI-FAIL FDT 57 @445 (G1jd) — reverted. load_flush_next16 hygiene. ld_until_01 MINI-FAIL FDT 106 @409 (G1lm) — reverted. leftover_off_npc00 hygiene. leftover_slot0_off_npc00 MINI-FAIL sib printed 4 @448 / lottery hang @400000 / FDT 17 @413 — reverted. load00_vs_off16 hygiene. leftover_nx8_npc00 hygiene. leftover_hi8_s2 MINI-FAIL FDT 24 @201516 (G1hu) — reverted. load00_vs_lj hygiene. leftover_lo8_s2 hygiene. load00_lo8_s2 hygiene (7b0 not a valid same-8B LOAD return at n7b0). Off-line leftover-PC replay kept. leftover_blocks_01 + G1hj consume-PC-match hygiene. G1hj/jy is_mispredict spare hygiene. stash_keep16 hygiene. stash_keep_pc hygiene. load_flush_keep hygiene. plus2_stay + line_hi8_stay hygiene (TRACE n7b8@20431 n7c0@20438). idle_sib16 / idle_load_sib HOLD-FAIL 51b1c001 (G1jw) — reverted. hangj 766 is bp_valid leftover jal. slfix `2db4dea7` / `f5f908e4`. Not G1mg. Not G1gn. Not lo11. Not lo_pc. Not lo_ld_stay. Not sib_lo_s2. Not hi8_lo11 |
| **2** | Layer 1: present the 16-bit at `npc` when leftover-PC line ≠ npc line (`G1gx` family). Success = fetch_entry contains exact c.jalr bits. | queued |
| **3** | EXTRACT bit-identical `g6lc_sib_cjalr`. Hold cookie + FDT + lottery match G1mf. Hit **AND-not** fetch exception (H-safe; identity on smt2 `RVH=0`). | queued |
| **4** | Collapse inside the module: one latch; drop `G1mf`/`G1md`; drop ID rewrite when layer 1 holds; drop frontend invent when bits are present; TRACE PCs leave the header. | queued |
| **4b** | **Gate split:** layer 1 → `SS && RVC && FETCH_WIDTH>=64`; layer 2 stays SMT+SS. Soak on a stream8 **I=2** directed leftover mini (hang-6 class), not `7ba`. SI/T=1 identity for layer 2. | after 4; before stream I=2 default-on |
| **5** | Later axes use this soak table. Replace `SMT_COLD_EXCL` with WFI/`sp`. | after 4 |
| **6** | Envelope soaks (§8): core scale + all-feature **per named package**, recover ports frozen. SL-E DTS generator when a third topology appears. | after 5; SL-C first for smt2 Linux |

### Axis matrix (after Phase 4 / 4b)

| Axis | May skip G1\* re-read if | Must still |
|------|--------------------------|------------|
| **BP** | Does not change leftover FSM, `kill_s*`, or recover ports; consumes `cf_type` after present. Recover must not assume `BPType=BHT` | Re-soak lottery + `mini_sib_cjalr` + hold on **smt2**. Stream8 already `TAGE_LITE` — do not copy BHT-only clauses |
| **OoO** | Recover has **no** `mem_q` scan; IRO/ID see already-classified JALR | Re-soak sibling mini + `g6lc_sb_keep` + hold. New dispatch is a **new class** if minis fail |
| **`NrCores` / stream** | Recover arrays are `[NrHarts]` **per core**; no cluster/snoop/L2 ports. Stream `T=1` const-folds **layer 2** off | DTS `cpu-map` (cores vs SMT threads); CLINT `S=N×T`; `stream8-smoke`. Dual-issue on stream is §6.2, not this row |
| **`NrHarts>2`** | Latch depth from `NrHarts`; no T=2 hard-code | Scheduler + G3 `sp==0` mini; `check_cfg` |
| **AI island** | MMIO uncore / CVXIF leaf; `AccBanks>=NrHarts`; no issue stall into recover | `smt2-ai-tensor-track` after SL-C. Mutex with RVV (§6.3) |
| **RVV / Ara** | No recover ports for `acc_dispatcher` / VRF / `vl`. Vector stays behind `EnableAccelerator` | `ara-vector-path` on `_v` only. DTS `v` only on `ariane-server-math-v.dts`. Mutexes §6.3 |
| **Hypervisor (`RVH`)** | No recover ports for `V`/`gva`/`hfence`/`hgatp`. Inject suppressed on I$ exception. H CSRs already per-hart in `g6lc_smt_csr_bank` | H-edge 3/3 on **that** package. DTS `h` iff `RVH=1`. smt2 flip is §6.5 |
| **L2 / L3 / snoop / HWPF** | No cluster/cache ports on recover | `mc-spo-veri` / `ooo-l3-tests` on that package. Inclusive L3→L1 is uncore |
| **`FETCH_WIDTH` / I$ line** | Recover keys only `CVA6Cfg` geometry (`pc[2:1]`, `addr[3]`, `VLEN`) | Re-soak §1 if fetch width or line width changes; **do not** hard-code 8 B vs 16 B |
| **`NrIssuePorts` 2→4** | Recover is fetch, not issue width | Catalog G1 keep + barrier re-soak; `mini_sib_cjalr` only if `T>1` |
| **All-feature + `NrCores` scale** | Recover ports frozen; arrays `[NrHarts]` per core | Union soak §8. **Not** one mega-package |

G2/G3/G4/SL-C stay as `COMPLETION.md`: reuse G0/G1, named SMT scheduling mini,
B2 source unless DI/SMT, topology after `plat_hc==2`. **SL-D stream, RVV, and
H-edge do not share the smt2 hold ELF.**

---

## 6. Stream plane, RVV, and hypervisor (related adjustments)

Do **not** merge `g6lc64_smt2`, `g6lc64_stream8`, and `g6lc64_server_math_v`
into one package. Topology, issue width, vector, and H are orthogonal knobs;
the DTS triple (`package ⇔ .dts ⇔ spec`) is per package.

### 6.1 Live envelopes

| Package | N | T | I | RVV | CVXIF | RVH | BP | Recover layer 2 |
|---------|---|---|---|-----|-------|-----|-----|-----------------|
| `g6lc64_smt2` | 1 | 2 | 2 | 0 | 1 | **0** | BHT | **on** (living soup) |
| `g6lc64_stream8` | 2 | 1 | **1** | 0 | 1 | **1** | TAGE_LITE | **off** (`NrHarts=1`) |
| `g6lc64_server_math_v` | 1 | 1 | 2 | **1** | **0** | **1** | (server) | **off** (`NrHarts=1`) |

`S = N×T` software harts. Issue width is **not** a Linux hart.
`ariane-smt2.dts` = one core, two threads. `ariane-stream8.dts` = two cores,
one thread. Same `cpu@` count, different `cpu-map` (`fdt-topology-soft-ladder.md`).

Stream8 already has **`RVH=1`** (H-edge 3/3 on `kvm-h-veri`) plus `RVZacas`,
`DeepSpecEn`, L2, snoop — ISA/cluster, not fetch recover. Catalog G1 **keep**
(`g6lc_sb_keep`) is mostly `SuperscalarEn`-gated: it **will** arm if stream
I=2 is turned on, even with T=1. That is intended (FDT cancel under DI).
Layer 2 sibling rewrite must not. **smt2 is `RVH=0`** — hypervisor on SMT is
§6.5, not a recover edit.

### 6.2 Enabling / updating the stream plane

SL-D stays **orthogonal** (`COMPLETION.md` Stage 5). Soft-ladder hold ELF is
smt2-only. Stream updates:

| Change | Recover impact | Related adjustment |
|--------|----------------|--------------------|
| Raise `NrCores` (2→4/8) | None (per-core `[NrHarts]`) | PLIC `S≤8`; CLINT `NR_HARTS`; DTS `cpu-map`; L2 infer; snoop-filter entries |
| Keep `I=1` | Layer 1 and 2 stay off | Identity path; `stream8-smoke` / CRT 9/9 / H-edge |
| **Enable `I=2`** (`SuperscalarEn=1`) | Layer 2 still off (T=1). Layer 1 **must already be SS-gated** (Phase 4b) or leftover mash returns as hang-6 (`fdt_path_offset` BADOFFSET in the stream8 comment) | Mini-first on **stream8**: leftover/RVC present, not `mini_sib_cjalr`. Catalog G1 keep will arm — soak FDT shape on stream8, not smt2 `7ba` |
| Optional `T=2` on stream (hybrid N×T) | Layer 2 **on** per core | New package + DTS; not a stream8 tweak. Soak `mini_sib_cjalr` **and** cluster. `S=N×2` |
| Stream BP already `TAGE_LITE` + loop/indirect | Recover must ignore BP type | Do not add BHT-only present clauses; Phase 4b present helper takes leftover flags, not predictor internals |
| `DeepSpecEn` / STQ | Catalog G1 keep / STQ families (several HOLD-FAIL) | Re-soak keep/cancel on stream8 I=2; **not** sibling recover |

Do not run smt2 OpenSBI peels on stream8. Do not advertise SMT `cpu-map`
threads on stream DTS.

### 6.3 Enabling / updating RVV (Ara)

Vector is **not** an in-pipe ALU. Ara attaches at `EnableAccelerator` /
`acc_dispatcher` (`AGENTS-vector.md`). Recover must not grow `vl` / VRF /
acc-busy ports.

**Hard mutexes (do not paper over in recover):**

1. `CvxifEn` ⟂ `EnableAccelerator` (`core/cva6.sv` `gen_err_xif_and_acc`).
   smt2 `CvxifEn=1` (AI coprocessor). `_v` `CvxifEn=0`. A unified
   smt2+vector package **drops CVXIF** (in-core `g6lc_ai` off). MMIO
   `ai_island` can stay uncore.
2. `SuperscalarEn` ⟂ `EnableAccelerator` (`cva6.sv` `$fatal`,
   `translate_off`). `g6lc64_server_math_v` already sets **both**
   (`AGENTS-todo.md` **AI-2**). That is a **vector/AI track** lift of the
   assert + a dual-issue acc path — **not** a G1 recover edit. Do not enable
   RVV on smt2 until AI-2 is closed; a real sim should `$fatal` at t=0 today.

**Software / DTS:** `v` + `zve64d` only on `ariane-server-math-v.dts`.
`ariane-smt2.dts` and `ariane-stream8.dts` must **not** grow `v` unless that
package’s `RVV=1` **and** live Ara (`CVA6_ARA_ATTACH`). OpenSBI VRF
save/restore is the **software plane** (`software/vector/opensbi-vrf.md`) —
same split as HSM/printf. Stub Ara hangs functional V tests; `v_memcpy_skip`
is the CI-safe skip.

| Change | Recover impact | Related adjustment |
|--------|----------------|--------------------|
| RVV on `_v` only (status quo) | None (T=1, recover off) | `ara-vector-path`; DTS `v` on `_v` only |
| RVV on stream8 | Recover still off (T=1) | New `stream8_v` package: `CvxifEn=0`, `RVV=1`; **AI-2** if I=2; DTS; Ara AXI vs L2/snoop |
| RVV on smt2 | Recover stays scalar-fetch; **no** Ara ports | Named `smt2_v` package after SL-C **and** AI-2. Drop CVXIF. Acc long-latency must stay flush-safe with SMT banks. Re-soak hold + `mini_sib_cjalr` + `v_memcpy_lmul` — fail-code names the class |
| Ara VLEN / lanes | None | SoC attach params; not `cva6_cfg_t` recover |

**AI-2 / P4 `EnableAccelerator`:** decoupling the SS/accel assert is the
prerequisite for dual-issue + RVV. Scoreboard long-latency + catalog G1 keep
re-soak; sibling recover does not take acc_resp.

### 6.5 Enabling / updating hypervisor (`RVH`)

H is **CSR + MMU + LSU**, not fetch recover. Homes: `csr_regfile` (already
instantiated **per hart** in `g6lc_smt_csr_bank` — `v_o`, `en_g_translation_o`,
`ld_st_v_o`, `vfs_o` mux by `active_hart`), `cva6_mmu` G-stage / `hfence`,
decoder `hlv*`/`hsv*`. Spec: `architecture/server-math-hypervisor.md`.
`check_cfg`: `RVH` requires `RVS` (+ `SoftwareInterruptEn`); `SstcEn && RVH`
is legal (`vstimecmp` / `henvcfg.STCE`).

smt2 today **`HExtEn=0`**. Stream8 and `_v` already **`HExtEn=1`**. H-edge
3/3 therefore already proves recover-off packages with H; it does **not**
prove smt2+H until the package bit flips.

**The one recover invariant H needs (EXTRACT Phase 3, identity on smt2):**
do not inject/rewrite a slot when the I$ beat has
`FE_INSTR_GUEST_PAGE_FAULT` / page fault / access fault. Living G1kl sets
`instruction_valid[0]` from a LOAD latch without looking at
`icache_ex_valid_q`. Under `RVH=0` that path never sees a GPF (bit-identical
today). Under `RVH=1` a fake `c.jalr` would mask a guest I-fetch fault.
Preserve `gpaddr`/`tinst`/`gva` (frontend already captures them at
`frontend.sv` ~3747). That is **pass-through**, not an H port on recover.

`hfence.vvma`/`gvma` already raise MMU + pipeline flush. Recover subscribes
to `flush_i` like other latches — do not add an hfence pin.

| Change | Recover impact | Related adjustment |
|--------|----------------|--------------------|
| Stream8 / server `RVH=1` (status quo) | Layer 2 off (`T=1`) | H-edge 3/3. DTS: package has H; **`ariane-stream8.dts` omits `h` today** — add the token only when software should see H (KVM), then `kvm-h-veri` + DTS row. Not a G1 edit |
| **Enable `RVH` on smt2** | Layer 2 stays scalar-fetch. EXTRACT exception-suppress must already be in (`Phase 3`). No `V`/`gva` ports | Package `HExtEn=1` (Sstc already on). DTS add `h` to **both** `cpu@` nodes. Re-soak §1 table **and** H-edge on **smt2** TB. Two-stage PTW only changes I$ miss timing — fail-code names the class (leftover vs GPF vs CSR) |
| Update H CSRs / G-stage / HLVx | None | `csr_regfile` / PTW / LSU. Directed `verif/tests/custom/kvm_h/` + `sstc_h/` |
| PLIC VS contexts | None | U9.1 is 2×hart (M/S). Extra VS contexts are PLIC/harness, not recover. `S≤8` still binds `NumTargets=16` |
| `hgeie`/`hgeip` (still stub) | None | Hypervisor track; not G1 |

Do **not** advertise `h` on `ariane-smt2.dts` while `HExtEn=0`. Do **not** run
slfix hold ELF as the H-edge oracle.

### 6.6 What “related adjustments” means (checklist)

When stream, RVV, H, cache, OoO, or `NrCores` knobs change, do these
**instead of** editing G1\* (envelope recipe §8):

- Config: `check_cfg` already has `NrHarts`/`NrCores`/`RVV`/`CvxifEn`/`RVH`
  legality. Do not add recover-specific asserts that name OpenSBI.
- DTS: `cpu-map` shape from `(N,T)`; ISA string from package bits; **never**
  `v` until `RVV=1`; **never** `h` until `RVH=1`.
- CLINT/PLIC: `NR_HARTS = N×T` (harness). Issue width is not a target.
  Extra VS PLIC contexts are H-track.
- Flist: Ara extra flist only on `_v` targets.
- Suites: stream → `stream8-smoke` / `mc-spo-veri` / `kvm-h-veri`; RVV →
  `ara-vector-path`; H → `kvm-h-spike` / `kvm-h-veri` on that package; smt2
  recover → soak table §1. Do not cross-run hold ELF.
- Catalog G1 keep: re-soak if `SuperscalarEn` turns on (stream I=2) or acc WB
  timing changes (AI-2). That is `g6lc_sb_keep`, not `g6lc_sib_cjalr`.
- EXTRACT: sibling hit AND-not I$ exception (H-safe; smt2 `RVH=0` identity).

---

## 7. Constraints (carry-over)

- Cookie `51b1babe` only; nat `51b1d000`. Hold-FAIL → revert.
- Soft getprop stays until `plat_hc==2`. Do not start I4cg. Isolated P4 stays.
- Do not re-land: `G1ki`, `G1lk`, `G1lm`, leftover `kill_s2`, all-npc-00
  `!kill_s1`/`!kill_s2`, I$ sticky user[33], IQ sibling-01 rewrite, G0, G6, …
- Do not bump `WAIT` to 48. Do not lower `SMT_COLD_EXCL` until Phase 5.
- New RTL: Case R; tier-U callers Case B delta only; no copyright/SPDX churn.
- Timing: extract = existing present/ID compares. Collapse must not lengthen
  `kill_s2`/`bp_valid`. Latch is per-hart, not a CAM over SB.

---

## 8. All-feature envelopes and core scale (minimal review)

“All-feature enabled” along `architecture/` is **not one package**. Mutexes
forbid it: `CvxifEn` ⟂ Ara, `SuperscalarEn` ⟂ `EnableAccelerator` until AI-2,
`NrHarts>1` recover ⟂ stream `T=1`. Specified programs keep **named envelopes**;
recover stays a frozen per-core call. Core increases are **cluster + DTS**, not
frontend archaeology.

### 8.1 Specified envelopes (do not merge)

From `remaining-upgrade-sequence.md`, `stream8-class.md`, `multi-core/README.md`,
`router-core-upgrade-program.md`, `fdt-topology-soft-ladder.md`:

| Envelope | Package of record | N | T | I | H | V | CVXIF | Other | Layer 2 |
|----------|-------------------|---|---|---|---|---|-------|-------|---------|
| **SMT / soft-ladder** | `g6lc64_smt2` | 1 | 2 | 2 | 0→1 (§6.5) | 0 | 1 | BHT, L2 | **on** |
| **Stream / CRT** | `g6lc64_stream8` | 2…8 | 1 | 1→2 (§6.2) | 1 | 0 | 1 | TAGE, DeepSpec, Zacas, L2, snoop | **off** |
| **Server math + RVV** | `g6lc64_server_math_v` | 1–2 | 1 | 2 | 1 | **1** | **0** | Ara; AI-2 if SS+accel | **off** |
| **OoO server** | `g6lc64_ooo_server` | 4 | 1 | 2+ | 1 | 0 | 1 | `OoOEn`, L3, HWPF | **off** |
| **AI card** | `g6lc64_ai` | (stream-class) | 1 | 1 | 1 | 0 | 1 | `ai_island` MMIO + CVXIF AI | **off** |
| **Hybrid (future)** | *new pkg* | 2–4 | 2 | 2 | cfg | 0 xor V | xor | `S=N×T≤8` | **on** per core |
| **Router (scaffold)** | proposed `cv64a6_router` | 1 then 2 | 1 then 2 | 2 | cfg | 0 | 1 | HPDCACHE, Zic64b 64 B lines | on iff `T=2` |

Software harts `S = N×T`. **PLIC `NumTargets=16` ⇒ `S≤8`** (2 contexts × 8
harts; extra VS contexts are H-track, still inside 16). `NrHarts≤CVA6_MAX_SMT_HARTS`
(2). `NrCores≤CVA6_MAX_CORES` (8). Issue width is **not** a hart.

### 8.2 What “all-feature on this envelope” means

Turn on every knob **that envelope already specifies**, then scale N. Do **not**
fold SMT+RVV+CVXIF+OoO+N=8 into `g6lc64_smt2`.

| Knob | SMT envelope | Stream envelope | Recover |
|------|--------------|-----------------|---------|
| Dual-issue I=2 | already | Phase 4b first | layer 1 SS-gated; layer 2 only if T=2 |
| `RVH` | package+DTS+H-edge | already RTL; DTS `h` when KVM | exception-suppress only |
| RVV / Ara | `smt2_v` after SL-C **and** AI-2; drop CVXIF | `stream8_v`; T=1 | no Ara ports |
| AI island | MMIO after SL-C; CVXIF copro while `RVV=0` | `g6lc64_ai` | no issue stall into recover |
| BP TAGE/loop/indirect | optional; do not assume BHT | already TAGE_LITE | no BP ports |
| OoO / slice-OoO | new class if minis fail | ooo_server plane | **no** `mem_q` scan (Phase 4) |
| L2 / L3 / snoop / HWPF | cluster | cluster; L3 on ooo_server | no cache ports |
| DeepSpec / STQ | catalog keep re-soak | already | not sibling recover |
| `FETCH_WIDTH` 64→128/256 | parameterized keys only | same | re-soak §1; no magic 8 B |
| Zacas / H-ext / CMO | ISA / LSU | already | none |

**Union soak** (this is the review). Run the rows that apply; if all green and
recover **ports unchanged**, skip G1\* re-read:

1. If `T>1`: §1 table on that package (lottery, `mini_sib_cjalr`, hold if smt2).
2. If `T=1`: SI / stream identity — recover const-folded.
3. Cluster: `stream8-smoke` / `mc-spo-veri` (CRT 9/9) at that `NrCores`.
4. If `RVH`: `kvm-h-veri` 3/3 on **that** TB.
5. If `RVV`: `ara-vector-path` + live Ara tests; DTS `v` only on `_v`.
6. If `OoOEn`: `ooo-l3-tests`.
7. If AI island: `smt2-ai-tensor-track` (after SL-C for dual-hart).
8. DTS: `cpu-map` matches `(N,T)`; `h`/`v` match package bits; `validate` row.

Fail-code names the **new** class (PLIC scale, G-stage, acc WB, leftover on I=2,
…). It does not reopen `g1kk`.

### 8.3 Core increases (`NrCores` 1→2→4→8)

Recover arrays are `[NrHarts]` **inside one core**. Raising N instantiates more
`ariane` in `g6lc_cluster`. Layer 2 does not grow with N.

| Step | Related adjustment (not G1\*) |
|------|-------------------------------|
| N=1→2 | Live on stream8 / server_math. DTS two `cpu@`; CLINT `NR_HARTS=S`; PLIC 4 contexts if T=1 |
| N=2→4 | `ooo_server` starts at 4. L2 size infer `max(256 KiB, N×128 KiB)`; snoop-filter `64×N`; HWPF streams `max(4, 2×N)` |
| N=4→8 | `S=N×T≤8` ⇒ **T must stay 1** (hybrid T=2 max N=4). PLIC full 8×(M/S). SL-E generator strongly preferred over hand DTS |
| Hybrid N×T | New package only after SL-C (smt2) **and** stream N-scale green. `mhartid = c×T+t`. cpu-map: per-core `thread0/1` |

Do not retune recover when L2/L3 auto-size changes. Inclusive L3→L1 inv is
`g6lc_l1_inv_adapter` — uncore.

**SL-E** (`fdt-topology-soft-ladder.md` Phase D): generate DTS from
`(NrCores, NrHarts, IsaCode, cache geom)` once a third topology exists
(hybrid or N=4 stream). Until then, hand-written `ariane-smt2.dts` /
`ariane-stream8.dts` / `ariane-server-math-v.dts`.

### 8.4 Still a G1\* review (do not skip)

- New port on `g6lc_sib_cjalr` (ROB id, TAGE encoding, `V`, acc_busy, core-id, …).
- Leftover FSM / `kill_s1`/`kill_s2` / `bp_valid` policy change in frontend.
- Fetch geometry **not** expressed as `CVA6Cfg` (hard-coded 8 B / 16 B).
- Re-landing SB `mem_q` scan after Phase 4.
- Mini fail-code that is **not** a named class above.

Everything else in §8.1–8.3 is **union soak + DTS/PLIC/flist**, along the
specified architectures.
