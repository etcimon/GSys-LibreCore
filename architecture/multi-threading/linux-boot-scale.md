# Linux-boot scale — OpenSBI steps, fetch_B combos, named envelopes

**Status:** plan of record for full Linux boot **and** SMT2 on n-issue multi-core,
without churning frozen `core/frontend` or growing a fifth fetch combo.

Live Linux-boot bar (I4dp): `g6lc64_server_math_v` and `g6lc64_ooo_server` already
reach harness `tohost = 0` at 200M cycles through the proxy. This file says how to
**observe OpenSBI**, when to use **`smt_legacy`**, and how to turn on features that
smt2 does **not** have yet (RVH, RVV, `NrCores` scale, stream I=2, `NrHarts>2`)
while staying inside **`fetch_B`’s four combos**.

Execution: [`testharness-proxy.md`](testharness-proxy.md) (proxy-only evidence).  
Fetch law: [`../core-fetch/SPEC.md`](../core-fetch/SPEC.md) · [`../core-fetch/VALUES.md`](../core-fetch/VALUES.md).  
Envelopes: [`soft-ladder/CONTRACT.md`](soft-ladder/CONTRACT.md) §6–§8.  
Firmware capabilities: [`../firmware-boot-principles.md`](../firmware-boot-principles.md) R1–R12.  
Topology: [`fdt-topology-soft-ladder.md`](fdt-topology-soft-ladder.md).

---

## 0. Law

1. **Do not merge packages.** Mutexes stay: `CvxifEn` ⟂ Ara, `SuperscalarEn` ⟂
   `EnableAccelerator` until AI-2, recover layer 2 ⟂ stream `T=1`. One named
   envelope per soak.
2. **Frozen A is `core/frontend`.** New fetch behaviour is a **VALUES row** on
   one of B’s four combos, or it is **not fetch**. `smt_legacy` is an opt-in
   **oracle** (`Flist.smt_legacy`, proxy `--flavour legacy`), not the plane for
   new capabilities.
3. **Issue width is not a hart.** `S = NrCores × NrHarts`. Linux/OpenSBI see
   `cpu@` nodes. `NrIssuePorts` never appears in DTS.
4. **PLIC `NumTargets=16` ⇒ `S ≤ 8`** (M+S contexts × 8 harts). `T=2` max
   `N=4`; `N=8` forces `T=1`. `NrHarts ≤ CVA6_MAX_SMT_HARTS` (**2** today).
5. **Cookie `51b1babe` ≠ I4dp `tohost=0`.** Soft-ladder green is cookie only.
   Linux-cap green is no-trap at 200M. Both via proxy logs.
6. **Soft getprop stays until `plat_hc==2`.** Do not start I4cg. Do not re-land
   I4cd / I4ce / I4cf. Keep I4dn.

---

## 1. Live packages (planning numbers)

CONTRACT §6.1 historically listed `ooo_server` `T=1` and `_v` `T=1`. **Live
config packages** (Linux-boot I4dp) are:

| Package | N | T | I | RVV | CVXIF | RVH | `S=N×T` | Linux-cap (I4dp) |
|---------|---|---|---|-----|-------|-----|---------|------------------|
| `g6lc64_smt2` | 1 | 2 | 2 | 0 | 1 | **0** | 2 | cookie path; FDT walk still residual |
| `g6lc64_server_math_v` | **2** | **2** | 2 | **1** | **0** | **1** | **4** | `tohost=0` @ 200M (`work-ver-server-math-v-B`) |
| `g6lc64_ooo_server` | **4** | **2** | **4** | 0 | 1 | **1** | **8** | `tohost=0` @ 200M (`work-ver-ooo-server-B`) |
| `g6lc64_stream8` | 2 | 1 | 1 | 0 | 1 | 1 | 2 | CRT/H-edge; not the OpenSBI cookie ELF |

**`g6lc64_server_math_v` is the full-stack bar to copy:** dual-core, SMT2,
dual-issue, RVV/Ara, `RVH`, L2 — already Linux-cap green. smt2 OpenSBI work
must not regress that package. n-issue multi-core already exists as
`ooo_server` (I=4, N=4, T=2, S=8). The missing work is **honest OpenSBI FDT
on fetch_B smt2**, then **turning on the knobs smt2 still lacks**, using
those two boots as hygiene — not a new frontend.

`NrHarts > 2` is **not** the next lift (`check_cfg` `CVA6_MAX_SMT_HARTS=2`).
`T>1` on the ooo_server / `_v` class is **already live**.

---

## 2. fetch_B’s four combos (the only fetch RTL)

From [`VALUES.md`](../core-fetch/VALUES.md) §1. **Do not add a fifth combo.**
Capability work is a row on one of these, or it belongs in issue/LSU/CSR/uncore.

| Combo | Layer | Owns | Use for scale |
|-------|-------|------|----------------|
| **`align_slots`** | L1 | leftover + halfword cursor; **per-hart leftover** | RVC/RVI straddle (OpenSBI R4); `NrHarts` leftover banks; stream I=2 leftover present. **Not** sibling `c.jalr` fabricate |
| **`window_accept`** | L2 | drop whole window iff `win_tag` match | Fetch geometry (`FETCH_WIDTH`); never opcode/rd |
| **`arch_redirect`** | L4 | one encoder: ex > eret > commit > debug > restore > misp | Precise trap (R3), `c.jalr` (R5), SMT restore (R1/R11), `RVH` exception pass-through. **No** PMA/value filter |
| **`kill_s1` / `kill_s2`** | — | `misp\|flush\|replay` ; `bp_valid` | Same-hart squash (I18). Stream `en.restore=0` const-folds restore |

L3 (`order` / IQ upto-CF) may drop, never modify. n-wide (`I` 2→4) is
**`geo.issue` on L3 loop**, not a new combo and not a hart.

**`core/frontend` (frozen A):** last green fetch. New letters stay out.  
**`core/smt_legacy`:** g1\* oracle for A/B blame only (`proxy soak --flavour legacy`).  
**`core/**` outside fetch:** STQ/issue/CSR banks when the fail-code is not fetch
(R4 callee-saved / I4ca class). Still one class per iteration.

---

## 3. OpenSBI observation ladder (what to watch)

Watch **firmware activity**, not ELF PCs in RTL. Each row is already a
capability in firmware-boot-principles §A. Proxy soak/TRACE records the log;
smt_legacy is the optional A side of the same ELF.

| Step | OpenSBI activity | Observe in log | Fetch combo if B-red | Not fetch |
|------|------------------|----------------|----------------------|-----------|
| **O0** | `_start` / `_start_warm`, lottery, `sp` | hangpc, `sp1`, `last_hartidx` | `arch_redirect` restore | I4dn ready/IPI |
| **O1** | `sbi_init`, `coldboot_done` | `coldboot_done=1` | — | ordinary LS |
| **O2** | `sbi_hart_init` expected-trap | mepc in handler, not `ff0e` illegal | `arch_redirect` mtvec hold + `align_slots` I+C+RVI | CSR bank |
| **O3** | libfdt namelen / next_tag / getprop | **cookie or pin `12eb2`** | leftover L1; **not** g1\* | STQ/s2-s3 (SL-A) |
| **O4** | platform `c.jalr` | not FDT-as-code | `arch_redirect` I11 | plat ops |
| **O5** | printf / strlen | BANR; not `4a50` | `align_slots` | — |
| **O6** | domain / HSM / both harts | `plat_hc==2`, hart1 WFI `sp≠0` | restore + I4dn | CLINT `S=N×T` |
| **O7** | `switch_mode` → S | payload entry | L4 eret | — |
| **O8** | Linux Sv39 / `cpuinfo` | Image path; `/proc/cpuinfo` count = `S` | — | DTS `cpu-map` |

smt2 is **stuck at O3** (combined natural FDT). `_v` and `ooo_server` already
pass O8-as-cap (`tohost=0`). Do not use their 200M-cap SUCCESS as cookie green.

**A/B:** same ELF, `soak --flavour legacy` then `--flavour B`. A-green/B-red ⇒
one VALUES row on a combo. A-red ⇒ generic core (STQ/issue) or B2. Never mix
Mdirs.

---

## 4. Features smt2 does not have yet (and where they land)

| Missing on `g6lc64_smt2` | Already live where | Next RTL home | Software |
|--------------------------|--------------------|---------------|----------|
| Natural FDT / `plat_hc==2` | pin natural getprop + real printf; BANR on canonical hold | SL-A dual-confirm; S2 pin+plat-ops printf green; hart+printf leftover `@12ad8` | BANR stays on hold `8b6b310e` |
| `RVH` | stream8, `_v`, `ooo_server` | package `HExtEn=1`; L4 inject-suppress on I$ ex (identity today) | DTS `h` on **both** `cpu@` |
| RVV / Ara | `_v` only | **no fetch ports**; named `smt2_v` **after SL-C and AI-2**; drop CVXIF | `v` only on `_v` DTS |
| `NrCores>1` | `_v` N=2, stream8 N=2, ooo N=4 | **no fetch edit**; cluster + DTS + CLINT `S=N×T` | `cpu-map` cores |
| n-issue I=4 | `ooo_server` | `geo.issue=4` on L3; keep/barrier re-soak | not in DTS |
| Stream I=2 | stream8 is I=1 | L1 leftover present, SS-gated; layer 2 **off** (T=1) | do not advertise SMT threads |
| `NrHarts>2` | nowhere (`MAX=2`) | L1 leftover banks `geo.harts`; `check_cfg`; G3 `sp==0` mini | PLIC/CLINT; **after** `S≤8` rule rewritten |
| Hybrid N×T DTS | hand smt2 / stream8 / `_v` / ooo | SL-E generator | third topology only |

---

## 5. Concrete steps (do in order)

Each step: proxy `doctor` → `sync`/`build` as needed → recorded log under
`runs/<tag>/`. Hygiene: I4dp `_v` and `ooo_server` 200M-cap still `tohost=0`
if the class touches SMT ready, IPI, fetch, or STQ.

### S0 — Execution rail (done as policy)

Proxy-only evidence ([`testharness-proxy.md`](testharness-proxy.md)). Compile
may be local; **runs** are not.

### S1 — OpenSBI R4 on fetch_B smt2 (SL-A, **active**)

**Observe:** pin `mepc=0x80012eb2` vs cookie. TRACE: 2nd `next_tag`
`ld s3,24(sp)` ← 1st `sd ra,56(sp)` (32 B `check_node` alias).

**Done (proxy, 2026-08-25):**

| Tag | Log | Result |
|-----|-----|--------|
| `b1-frame32` | `remote-runs/b1-frame32/run-B.log` | `mini_fdt_nt_frame32` **PASS** (tohost=0 @4030). Reconstructed 64 B-after-32 B nest does **not** pin. |
| `s1-peel-trace` | `remote-runs/s1-peel-trace/output/s1_peel_trace.classify.txt` | combined peel still pin-exit t=10240 `12eb2/6/12b2a` `plat_hc=80`. |
| `b1-nt-stock` | `remote-runs/b1-nt-stock/run-B.log` | `mini_fdt_nt_stock` **PASS** @756. `offset_ptr` + `c.lw` + `jr` empty BEGIN/PROP — not the pin. |
| `b1-nt-cpus` | `remote-runs/b1-nt-cpus/run-B.log` | `mini_fdt_nt_cpus` **PASS** @851. BEGIN_NODE `"cpus"` per-byte `jal offset_ptr` + 4×lbu — not the pin. |
| `b1-stq-jal` | `remote-runs/b1-stq-jal/run-B.log` | `mini_stq_alias_jal` **PASS** @985. 16 then 2 nested 16 B thunks on the alias nest — not the pin. |
| `b1-nt-set` | `remote-runs/b1-nt-set/run-B.log` | `mini_fdt_nt_set` **PASS** @1463. FDT `0x8002e000` / alias `0x8003e038` same `addr[11:6]` — not the pin. |
| `b1-nt-osbi` | `remote-runs/b1-nt-osbi/run-B.log` | `mini_fdt_nt_osbi` **PASS** @1432. Stock walk at pin VAs, TRACE SP, node offset 0. Isolated walk is not the pin. |
| `b1-nt-warm` | `remote-runs/b1-nt-warm/run-B.log` | hart1 + alias-line warmup + two-call walk **PASS** @10718. Occupancy is not the pin. |
| `b1-nt-nl` | `remote-runs/b1-nt-nl/run-B.log` | **PIN REPRO.** Stock `namelen_`@`13040` (cave nop'd) + `by_offset_`@`12e26` + `check_node`. Trap mepc=`0x80012eb2` (tohost 13 = write 27) @10881. |
| `b1-wt-delay2` | `remote-runs/b1-wt-delay2/run-B.log` | `mini_wt_delay_ld` **PASS** @1583. Two stores (`0x12b2a` then `lenp`) + 400-iter delay + load — isolated WT RAW is not the pin. |
| `b1-nt-sw` | `remote-runs/b1-nt-sw/run-B.log` | software 144B namelen **PASS** @10714. |
| `b1-nt-pro0` | `remote-runs/b1-nt-pro0/run-B.log` | stock prologue saves *before* `check_node` **PASS** @10668. |
| `b1-nt-pro0b` | `remote-runs/b1-nt-pro0b/run-B.log` | saves **between** `check_node` and 2nd `next_tag` **FAIL tohost=2** @10607 (`s2` clobber). |
| `b1-nt-far` | `remote-runs/b1-nt-far/run-B.log` | 5 sd @`0x80048000` **PASS** @10694. Count alone is not the pin. |
| `b1-nt-five` | `remote-runs/b1-nt-five/run-B.log` | 5 stock mid-saves **FAIL tohost=1** @10662 (**s3** clobber). 4 mid-saves **hang**. |
| `b1-nt-five-fence` | `remote-runs/b1-nt-five-fence/run-B.log` | 5 mid-saves + `fence rw,rw` **PASS** @10700. |
| `b1-stq-jal-200k` | `remote-runs/b1-stq-jal-200k/run-B.log` | `mini_stq_alias_jal` **PASS** @985 (40k cap hang was not sticky — dual-hart, see h1park). |
| `s1reg-mini_stq_alias_jal-h1park` | `remote-runs/s1reg-mini_stq_alias_jal-h1park/run-B.log` | hart1 WFI park like `h0`. **PASS @986** (rvfi 974). 200k hang was both SMT harts sharing SP `0x80008000`, not `store_buffer` comb defaults. |
| `b1-nt-nl-*-wrprio` | same-bank data-load yields to one-shot `wr_ack` (`rd_off_i`) | **tight PASS @10682** (rvfi); h0/sw **Verilator active-region abort** (gnt updates `address_off_d`). |
| `b1-nt-nl-*-wrprio` (all-data) | stall every data-load on `wr_req` | tight/h0 **HANG @40000**; sw **PASS @10776**. `wr_ack` DCE'd. |
| `b1-nt-nl-*-wrprio` (`rd_off_q`) | same-bank vs registered off | **tight PASS @10682**; sw **PASS @10774**; **h0 HANG @40000**. TRACE `s1-h0-wrprio-hang-trace`: FDT_PROP `0x8001311a+` ra=`0x800130b6` s3=0 SP=`0x800544e0` — keep pairing. **Reverted.** |
| `b1-nt-nl-sw-wrprio-rev` | stock overlay + stock ACK-before-check after wrprio revert | **PASS @10714**. tight **s3 @10633**; h0 **pin 13 @10869**. Width casts kept. |
| `b1-nt-nl-*-nackinv` | on denied `wr_ack`, inval that hit way (later load misses to DRAM) | **tight PASS @10645** (rvfi 10633); sw **PASS @10730**; **h0 HANG @40000**. TRACE `s1-h0-nackinv-hang-trace`: FDT_PROP `0x8001311a+` ra=`0x800130b6` s3=0 SP=`0x80051b70`. Phase-1 restore fix, phase-2 namelen hang. **Reverted.** |
| `b1-nt-nl-sw-nackinv-rev` | stock overlay + stock ACK-before-check after nackinv revert | **PASS @10714**. tight **s3 @10633**; h0 **pin 13 @10869**. Width casts kept. |
| `b1-nt-nl-tightprop` | tight + software-correct s2/s3 + 24× `next_tag` walk | stock **tohost=3 @11510** (write 7: **s2 and s3** dead at restore; walk **ok**). Phase 2 is not a stock nested-`next_tag` hang. |
| `b1-nt-nl-tightprop-nackinv` | TRACE-only nackinv + tightprop | **PASS @13714** (write 1: phase1+walk). Phase-2 h0 hang was not generic `next_tag`. |
| `b1-nt-nl-tightbo` | tight + software-correct + `jal by_offset` | stock **HANG @40000** (by_offset blob cave deleted `addi sp,-48`, callee still +48). |
| `b1-nt-nl-tightbo-sp` | caller `addi -48` before by_offset | **tohost=7 @11173** (write 15: by_offset returned 0; no hang). |
| `b1-nt-nl-h0-addi` | namelen.bin cave → `addi sp,-144` | stock still **pin 13 @10881** (phase 1). |
| `b1-nt-nl-h0-addi-nackinv` | nackinv + addi prologues | **h0 PASS @16268**. tight PASS @10645. nt-osbi PASS @16279. **nackinv kept.** |
| `s1reg-hold` | soak `--hold` held `8b6b310e` | fw64-B still pin `12eb2` `plat_hc=80`. Cookie stays slfix. |
| `b1-nt-nl-h0-fence` | `remote-runs/b1-nt-nl-h0-fence/run-B.log` | trampoline `fence rw,rw` **in** FDT_PROP loop @`1307e` **HANG** `tohost=0` @40000. |
| `b1-nt-nl-h0-fence2` | `remote-runs/b1-nt-nl-h0-fence2/run-B.log` | one-shot fence after 5 mid-saves @`13074` (not in loop) **HANG** `tohost=0` @40000. |
| `b1-nt-nl-h0-nop4` | `remote-runs/b1-nt-nl-h0-nop4/run-B.log` | 4 B `addi x0,x0,0` at `13074` **PIN** `tohost=13` @11083. Reloc is fine; fence is the hang. |
| `b1-nt-nl-h0` | `remote-runs/b1-nt-nl-h0/run-B.log` | restored unpatched `namelen.bin` still **PIN** `tohost=13` @10869. |
| `b1-nt-nl-cut` | `remote-runs/b1-nt-nl-cut/run-B.log` | packed namelen ret after 2nd `jal next_tag` **HANG** @40000 and @200000. Truncated I-stream is not a probe. |
| `b1-nt-nl-cutbo` | `remote-runs/b1-nt-nl-cutbo/run-B.log` | ret before `jal by_offset` **HANG** @40000. |
| `b1-nt-nl-cutli` | `remote-runs/b1-nt-nl-cutli/run-B.log` | keep leftover `c.li a5,9` then ret **HANG** @40000. |
| `b1-nt-nl-bochk` | `remote-runs/b1-nt-nl-bochk/run-B.log` | full namelen I-stream; `by_offset`@`12e26` is a live s3/s2 checker. **FAIL tohost=1** (write 3) @10649 — **s3 already dead at `jal by_offset`**. Pin is not inside `by_offset`. |
| `b1-nt-nl-tight` | `remote-runs/b1-nt-nl-tight/run-B.log` | software 5 `c.sdsp` then stock tail, **no extra CF, low VA**. **FAIL tohost=1** (write 3) @10633 — s3 clobber **without** pin VAs. |
| `b1-nt-nl-tightva` | `remote-runs/b1-nt-nl-tightva/run-B.log` | same tail at `1306a` / `jal@1307e` then checker. **HANG** @40000 (cut class: leftover after `1307e` is not stock). |
| `b1-nt-nl-tightnop1` | `remote-runs/b1-nt-nl-tightnop1/run-B.log` | tight + 1 `c.nop`. **FAIL tohost=1** @10632 (s3). |
| `b1-nt-nl-tightnop2` | `remote-runs/b1-nt-nl-tightnop2/run-B.log` | tight + 2 `c.nop`. **FAIL tohost=1** @10634 (s3). |
| `b1-nt-nl-tightnop4` | `remote-runs/b1-nt-nl-tightnop4/run-B.log` | tight + 4 `c.nop`. **FAIL tohost=2** @10798 (**s2**; s3 lived). |
| `b1-nt-nl-tightn0` | `remote-runs/b1-nt-nl-tightn0/run-B.log` | 0 mid `c.sdsp` then stock tail. **HANG** @40000. |
| `b1-nt-nl-tightn1` | `remote-runs/b1-nt-nl-tightn1/run-B.log` | 1 mid (`s11,40(sp)`). **PASS** @10624. |
| `b1-nt-nl-tightn2` | `remote-runs/b1-nt-nl-tightn2/run-B.log` | 2 mid. **PASS** @10625. |
| `b1-nt-nl-tightn3` | `remote-runs/b1-nt-nl-tightn3/run-B.log` | 3 mid. **PASS** @10625. |
| `b1-nt-nl-tightn4` | `remote-runs/b1-nt-nl-tightn4/run-B.log` | 4 mid. **HANG** @40000 (same class as historic 4 mid-saves). |
| `s1-tight-trace` | `remote-runs/s1-tight-trace/output/s1_nt_nl_trace.classify.txt` | tight TRACE: 2nd `c.sdsp` t=10210 s3=lenp SP=`0x80046eb0`; DRAM alias=lenp from t=10240; 2nd `ld s3` t=10582 retires **`0x12b2a`**. **STQ/hold overlay of stale ra; DRAM has younger store.** Same class as trampoline. |
| `b1-nt-nl-tight-holdempty` | hold overlay skipped / cleared when wbuffer empty | tight still **s3 @10633**; h0 still pin @10869; **sw HANG @40000** (was PASS). **Reverted.** |
| `b1-nt-nl-tight-holdupd` | younger store updates hold; hold wins over leftover STQ | tight/h0/sw all **HANG @40000** (n3 still PASS). Drain-CAM class. **Reverted.** |
| `b1-nt-nl-*-noovl` | no hold data overlay; stall then D$ | tight still **s3 @11033**; nt-nl pin @11277; h0 **flake** PASS then pin; sw PASS @11110; n3 flake. L1 hit still stale (DRAM=lenp). **Reverted.** |
| `b1-nt-nl-*-rawdrain` | no overlay + WAIT_PAGE_OFFSET until STQ+wbuffer empty | tight/sw/h0/n3 all **HANG @40000**. Fence-in-LSU deadlocks. **Reverted.** |
| `b1-nt-nl-*-chktx` | no overlay + TX only after wbuffer tag-check | **tight PASS @11035**; sw **s3 @11111**; h0 **HANG @40000**; n3 **s3 @11048**. Combo proves L1+no-overlay; delayed TX poisons sw/h0. **Reverted.** |
| `b1-nt-nl-*-latel1` | no overlay + one-shot L1 write on `check_en_q1` after ACK (`!txblock && !dirty && rtrn_empty`) | tight still **s3 @11033**; sw PASS @11112; h0 pin 13 @11267; n3 PASS @11025. Same as no-overlay — write did not land (rtrn FIFO busy on 5 TX). **Reverted.** |
| `b1-nt-nl-*-latel1b` | pending L1 write of checked ACK'd hits when `rtrn_empty` | tight still **s3 @11033**; sw PASS @11112; h0 pin 13 @11267; **n3 HANG @40000**. **Reverted.** |
| `b1-nt-nl-sw-latel1-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-chkhit` | no overlay + `wr_req` on check-hit (`rtrn_empty`, any valid) | **tight PASS @11016**; sw PASS @11110; n3 PASS @11025; **h0 HANG @40000** (r2 hang); stock `b1-nt-nl` **HANG @40000**. |
| `b1-nt-nl-*-chkhit-ovl` | overlay back + same pre-TX/any-hit `wr_req` | **tight PASS @10616**; sw PASS @10714; **h0 HANG @40000**. Extra `wr_req` hangs packed namelen even with overlay. |
| `b1-nt-nl-*-chkhit-txb` | overlay + `wr_req` only if `txblock` (true in-flight) | tight **s3 @10633**; h0 **pin 13 @10869**; sw PASS @10714. In-flight-only is a no-op for the gate. |
| `b1-nt-nl-sw-chkhit-rev` | stock overlay + stock ACK path after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-keepv` | no overlay + keep wbuffer valid after ACK (steal clean-held) | **tight PASS @11016**; sw PASS @11110; n3 PASS @11025; **h0 HANG @40000**. |
| `b1-nt-nl-*-keepv2` | same, skip tag-check of clean-held | tight **PASS @11016**; sw PASS @11110; **h0 HANG @40000**. Hang is not leftover `tocheck`. |
| `b1-nt-nl-*-keepv-ovl` | overlay + keep-valid | **tight PASS @10616**; sw PASS @10714; **h0 HANG @40000**. Occupancy of ACK'd words hangs packed namelen even with overlay. |
| `b1-nt-nl-sw-keepv-rev` | stock overlay + stock ACK clear-valid | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-keep1` | overlay + keep only newest ACK'd word | tight **s3 @10633** (alias is not last of 5); **sw HANG @40000**; h0 **tohost=12 @10693**. **Reverted.** |
| `b1-nt-nl-sw-keep1-rev` | stock overlay + stock ACK clear-valid | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-keep5` | overlay + cap clean-held at `DCACHE_MAX_TX+1`=5 | tight **s3 @10638** (prologue already fills the cap; alias dropped); sw **PASS @10714**; h0 **tohost=12 @11110**. **Reverted.** |
| `b1-nt-nl-sw-keep5-rev` | stock overlay + stock ACK clear-valid | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-keepv-emp` | overlay + keep-all ACK'd, **stock** `empty_o=!(|valid)` | **tight PASS @10621**; sw PASS @10722; **h0 HANG @40000**. `empty_o` was not the hang. **Reverted.** |
| `b1-nt-nl-sw-keepv-emp-rev` | stock overlay + stock ACK clear-valid | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-keep7` | overlay + cap clean-held at depth−1=7 | **tight PASS @10631**; sw PASS @10724; **h0 HANG @40000**. |
| `b1-nt-nl-*-keep6` | overlay + cap clean-held at 6 | **tight PASS @10624**; **sw HANG @40000**; h0 **tohost=12 @11039**. |
| `b1-nt-nl-sw-keep7-rev` | stock overlay + stock ACK clear-valid | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-ovl-wbuf` | overlay only if `dcache_wbuffer_empty` | tight **s3 @11033** (same cycle as no-overlay — wbuffer not empty, alias already gone); sw PASS @11110; h0 **pin 13 @11267**. **Reverted.** |
| `b1-nt-nl-sw-ovl-wbuf-rev` | stock overlay | cap hang @40000 then **PASS @10714** (`-rev2`). Known sw flake. Width casts kept. |
| `b1-nt-nl-*-hold-grant` | younger same-PA store updates `g1ao_hold` on wbuffer grant | tight **s3 @10633** (stock cycle — grant did not refresh overlay); sw PASS @10714; h0 **pin 13 @10869**. **Reverted.** |
| `b1-nt-nl-sw-hold-grant-rev` | stock overlay | **PASS @10714**. Width casts kept. |
| `s1-tight-hold-trace` | `log hold` of `g1ao_hold_{v,hit,pa,data}` at 2nd `ld s3` | tight: hold **DEAD** (`v=0 hit=0`) at t=10581/10582. Leftover `pa=0x80046e38` (peel alias) `data=0x2`, not mini alias `0x80046ec8`. No `hit=1` in the ntr window. DRAM alias=lenp from t=10240; 2nd `ld s3` still **`0x12b2a`**. Overlay is not the load source. `remote-runs/s1-tight-hold-trace/output/s1_nt_nl_trace.classify.txt`. |
| `b1-nt-nl-*-ackinv` | L1 tag-valid inval on store ACK (hit way if checked, all ways if VOID); no `wr_req`, no keep, no fill | **tight PASS @22606** (rvfi); sw **PASS @22731**; **h0 HANG @40000**. Tight pin moved — L1-stale class confirmed. All-way VOID inval hangs packed namelen. **Reverted.** |
| `b1-nt-nl-sw-ackinv-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-voidchk` | VOID ACK keep-valid until `check_en_q1`, then way-only tag inval | tight **s3 @18169**; h0 **pin 13 @18439**; sw PASS @18281. Alias ACK is **checked**, not VOID. **Reverted** (superseded by voidchk2). |
| `b1-nt-nl-*-voidchk2` | VOID pend + **checked-ACK hit-way inval** (no all-way) | **tight PASS @22606**; sw PASS @22731; **h0 HANG @40000**. Way-only checked inval is enough for tight and still hangs namelen. **Reverted.** |
| `b1-nt-nl-sw-voidchk-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-wrack` | keep ACK'd checked-hit word valid until `wr_ack`; retry `wr_req`; free rtrn | **tight PASS @10616** (rvfi, stock-cycle keep); sw PASS @10714; **h0 HANG @40000**. `wr_ack` starve + occupancy (load vs `wr_req` same bank). **Reverted.** |
| `b1-nt-nl-sw-wrack-rev` | stock overlay + stock ACK-before-check after revert | cap hang @40000 then **PASS @10714** (`-rev2`). Known sw flake. Width casts kept. |
| `b1-nt-nl-*-snoop` | keep `!wr_ack` ACK'd word until a load snoops, then drop (no `wr_req` retry) | **tight PASS @10407**; h0 **tohost=12 @10264** (not pin 13); **sw HANG @40000**. First snoop consume is too eager (later load sees stale L1). **Reverted.** |
| `b1-nt-nl-sw-snoop-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-steal` | keep `!wr_ack` words across snoops; steal oldest keep when a new store needs a slot | **tight PASS @10580**; sw PASS @10626; **h0 HANG @40000**. Steal never fires if namelen never fills depth 8; `empty_o` still blocked. **Reverted.** |
| `b1-nt-nl-sw-steal-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-empkeep` | keep `!wr_ack` words; `empty_o` ignores keep entries | **tight PASS @10616**; sw PASS @10714; **h0 HANG @40000**. Hang is not STQ sticky / `empty_o` (same as keep-all). **Reverted.** |
| `b1-nt-nl-sw-empkeep-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `s1-h0-keep-hang-trace` | TRACE-only re-land keep+`empty_o`; hang dumps `after=38000` | h0 still **HANG @40000**. Not LSU stall: retiring **namelen `0x8001311a–0x80013176`** (FDT_PROP loop). ra=`0x800130b6` s3=0 a0=0 SP=`0x80054570` (stack growing). Alias DRAM at hang=`0x80012b60` (not lenp). `nextoff=0` walk never ends. `remote-runs/s1-h0-keep-hang-trace/output/s1_h0_hang_trace.classify.txt`. Keep **reverted**. |
| `b1-nt-nl-*-keepnz` | keep `!wr_ack` only if stored bytes are nonzero; `empty_o` ignores keep | **tight PASS @10616**; sw PASS @10714; **h0 HANG @40000**. Zero filter is not enough (stale ra `0x12b2a` is nonzero). **Reverted.** |
| `b1-nt-nl-sw-keepnz-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-keep1nz` | at most one keep: newest `!wr_ack` nonzero | tight **s3 @10633** (alias replaced by a later keep); h0 **pin 13 @11079** (no hang); sw PASS @10714. One keep is too few for tight, enough to not hang h0. **Reverted.** |
| `b1-nt-nl-sw-keep1nz-rev` | stock overlay + stock ACK-before-check after revert | cap hang @40000 then **PASS @10714** (`-rev2`). Known sw flake. Width casts kept. |
| `b1-nt-nl-*-keep3nz` | cap 3 newest `!wr_ack` nonzero keeps | **tight PASS @10616**; sw PASS @10714; **h0 HANG @40000**. 3 is enough for tight, still too many for namelen. **Reverted.** |
| `b1-nt-nl-*-keep2nz` | cap 2 newest `!wr_ack` nonzero keeps | **tight PASS @10616** (rvfi 10604); sw PASS @10714; **h0 HANG @40000**. Alias is among the 2 newest; 2 still hangs namelen. **Reverted.** |
| `b1-nt-nl-sw-keep2nz-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-keep512` | keep `!wr_ack` nonzero with TTL 512 cycles | **tight PASS @10616**; sw PASS @10714; **h0 HANG @40000**. Same as keep-all: namelen walk refreshes keeps. **Reverted.** |
| `b1-nt-nl-sw-keep512-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-keepcoal` | keep `!wr_ack` nonzero only if entry was a `wbuffer_hit_oh` rewrite | tight **tohost=12 @10763** (2nd store coalesced; pin moved, later fail 12); h0 **pin 13 @10869** (1st already gone, no hit); sw PASS @10714. **Reverted.** |
| `b1-nt-nl-sw-keepcoal-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-keeppend` | one pending-alias: last virgin ACK kept until same-PA rewrite; virgin ACK steals other keeps | tight **s3 @10633**; h0 **pin 13 @11079**; sw PASS @10714. Same pairing as `keep1nz` — intervening unique PAs steal the alias slot. **Reverted.** |
| `b1-nt-nl-sw-keeppend-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-keeppend2` | two pending-alias slots (unique-PA cap 2) | **tight PASS @10616**; sw PASS @10722; **h0 HANG @40000**. Same pairing as `keep2nz`. **Reverted.** |
| `b1-nt-nl-sw-keeppend2-rev` | stock overlay + stock ACK-before-check after revert | cap hang @40000 then **PASS @10714** (`-rev2`). Known sw flake. Width casts kept. |
| `s1-tight-keepcoal-trace` | TRACE-only re-land keepcoal + fail/hangpc | tight TRACE **s3 @10671** (a0=3 `fail3`); 2nd `ld s3` t=10620 **`0x12b2a`**; DRAM alias=lenp from t=10304; hold **DEAD**. Not tohost=12. `remote-runs/s1-tight-keepcoal-trace/output/s1_nt_nl_trace.classify.txt`. Keep **reverted**. |
| `b1-nt-nl-tight-keepcoal2` | keepcoal rerun without TRACE | tight **s3 @10633** (not 12). keepcoal 12 was a coalesce race, not sticky. |
| `b1-nt-nl-sw-keepcoal-trrev` | stock overlay + stock ACK-before-check after TRACE revert | **PASS @10714**. Width casts kept. fail/hangpc TRACE kept. |
| `b1-nt-nl-*-wr1` | one-cycle `wr_req` retry of denied L1 word write; no keep-valid | **tight HANG @40000**; **h0 HANG @40000**; **sw HANG @40000**. Late way-write after evict hangs even software namelen. **Reverted.** |
| `b1-nt-nl-sw-wr1-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-nackhit` | suppress D$ hit on the way of a `!wr_ack` word-write (one-entry poison) | tight **s3 @10639**; h0 **pin 13 @10878**; sw PASS @10716. Stock pairing — poison overwritten or not armed at alias load. **Reverted.** |
| `b1-nt-nl-sw-nackhit-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `s1-tight-wrack-trace` | TRACE `log wrack` of WT `wr_req`/`wr_ack`/`wr_data` after t=10000 | wrack **12** hits (ack0=2 ack1=10). **lenp `0x80046f2c` denied @t=10229** (`req=0x1`). Next deny **FDT `0x8001e000` @t=10249** overwrites one-entry poison. 2nd `ld s3` still **`0x12b2a`**. `remote-runs/s1-tight-wrack-trace/output/s1_nt_nl_trace.classify.txt`. TB `log wrack` kept. |
| `b1-nt-nl-*-nackhit2` | two-entry deny-hit poison (cap 2 idx/way) | **tight HANG @40000**; **h0 HANG @40000**; sw PASS @10720. Two poisons move tight off s3 into hang (same class as occupancy 2+ / ackinv). Latches on `matched`/`age`. **Reverted.** |
| `b1-nt-nl-sw-nackhit2-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-nackstick` | sticky one-entry poison until data load of that idx (no overwrite) | tight **s2 @10640** (tohost=2 — **s3 passed**, FDT `s2` stale); **h0 HANG @40000**; sw PASS @10718. Alias poison stuck; FDT deny @t=10249 ignored. **Reverted.** |
| `b1-nt-nl-sw-nackstick-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-nack2` | latch-free two-entry poison + consume-on-data-load | tight **s2 @10646**; **h0 HANG @40000**; sw PASS @10720. Same pairing as nackstick — second slot / consume did not fix FDT `s2`. **Reverted.** |
| `b1-nt-nl-*-nack2cl` | latch-free two-entry poison, clear on `wr_cl` only (no consume) | tight **s2 @10646**; **h0 HANG @40000**; sw PASS @10720. Identical to nack2/nackstick. nackhit2 tight hang was the latches, not two unconsumed poisons. **Reverted.** |
| `b1-nt-nl-sw-nack2cl-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-nack2idx` | latch-free 2-entry idx-only poison (mask all ways, `wr_cl` clear) | tight **s2 @10646**; **h0 HANG @40000**; sw PASS @10720. Same pairing as nack2cl. **Reverted.** |
| `s1-tight-nack2idx-trace` | TRACE under nack2idx | **s3 restore got lenp** (`c.ldsp s3,24(sp)` @`12a66`, PA `0x80046ec8`). **s2 restore got 0** (`c.ldsp s2,32(sp)` @`12a6e`, PA **`0x80046ed0`**); DRAM `0x46ed0`=FDT `0x8001e000` from t=10304. fail a0=5 s2=0 (not `0x12b2a`). hold DEAD. wrack still 2 denies (10229 lenp, 10249 FDT). Poison does not refill the s2 line while the s3 miss is in flight. `remote-runs/s1-tight-nack2idx-trace/output/s1_nt_nl_trace.classify.txt`. |
| `b1-nt-nl-sw-nack2idx-rev` | stock overlay + stock ACK-before-check after revert | cap hang @40000 then **PASS @10714** (`-rev2`). Known sw flake. Width casts kept. |
| `b1-nt-nl-*-snoopd` | keep `!wr_ack` checked-hit until a **data** load snoops (not tag-only) | **tight PASS @10614**; sw **PASS @10713**; **h0 HANG @40000**. Data-snoop fixed original snoop sw hang / h0=12. h0 is keep-class occupancy. **Reverted.** |
| `s1-h0-snoopd-hang-trace` | TRACE h0 hang tail `after=38000` under snoopd | same FDT_PROP as keep hang: PC **`0x8001311a–0x80013150`**, ra=`0x800130b6`, s3=0 s2=0 SP=`0x80054570`. `remote-runs/s1-h0-snoopd-hang-trace/output/s1_h0_hang_trace.classify.txt`. |
| `b1-nt-nl-sw-snoopd-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-snoopd2` | snoopd + **lifetime cap 2** (arm at most two denied-ACK words; never re-arm) | **tight PASS @10614**; sw **PASS @10713**; **h0 HANG @40000**. The first two keeps are enough to hang namelen FDT_PROP (same as keep2nz). **Reverted.** |
| `b1-nt-nl-sw-snoopd2-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-snoopd2t` | snoopd2 + **TTL 512** on the two keeps | **tight PASS @10614**; sw **PASS @10713**; **h0 HANG @40000**. TTL 512 does not unhang h0 — the pair poisons FDT_PROP before expiry (tight has no post-restore reload). **Reverted.** |
| `b1-nt-nl-sw-snoopd2t-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-snoopwr` | snoopd2 + one-shot L1 `wr_req` next cycle after data-snoop, then drop | **tight PASS @10615**; sw **PASS @10714**; **h0 HANG @40000**. Unlike wr1, sw did not hang. h0 still keep-class — the pair is likely never data-snooped (or is zeros overlaying FDT_PROP). **Reverted.** |
| `b1-nt-nl-sw-snoopwr-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `b1-nt-nl-*-snoopd8` | snoopd2 + keep only if `wr_data[31:28]==4'h8` (skip zeros/nextoff) | **tight PASS @10606**; sw **PASS @10705**; **h0 HANG @40000**. Pointer filter does not unhang h0. **Reverted.** |
| `s1-h0-snoopd8-hang-trace` | TRACE h0 hang tail under snoopd8 | still FDT_PROP `0x8001311a+`, ra=`0x800130b6`, s3=0 s2=0 SP=`0x80054570`. last next_tag t=10983 SP=`0x80046e90`. `remote-runs/s1-h0-snoopd8-hang-trace/output/s1_h0_hang_trace.classify.txt`. |
| `b1-nt-nl-sw-snoopd8-rev` | stock overlay + stock ACK-before-check after revert | **PASS @10714**. Width casts kept. |
| `s1-h0-wrack-trace` | stock B TRACE wrack on h0 | **pin 13 @10869**. wrack **24** (ack0=2 ack1=22). Same two denies as tight: **lenp `0x80046f2c` @t=10222**, **FDT `0x8001e000` @t=10242**. 2nd `ld s3` **`0x12b2a`**, DRAM=lenp, hold DEAD. `remote-runs/s1-h0-wrack-trace/output/s1_nt_nl_trace.classify.txt`. |
| `b1-nt-nl-*-snoopd8t` | snoopd8 + **TTL 400** | **tight PASS @10614**; sw **PASS @10713**; **h0 HANG @40000**. **Reverted.** |
| `s1-h0-snoopd8t-trace` | TRACE h0 under snoopd8t | 2nd `ld s3` **got lenp** t=10573 (pin moved). Then **FDT_PROP hang** npc=`0x80013148` ra=`0x800130b6` SP=`0x80055410`. Keep letters closed for h0: restore vs FDT_PROP cannot pair. `remote-runs/s1-h0-snoopd8t-trace/output/s1_nt_nl_trace.classify.txt`. |
| `b1-nt-nl-sw-snoopd8t-rev` | stock overlay + stock ACK-before-check after revert | cap hang @40000 then **PASS @10714** (`-rev2`). Known sw flake. Width casts kept. |

**Named class (SP-proven, not fetch):** 1st `fdt_next_tag` SP=`0x80046e00`,
2nd SP=`0x80046e20` (Δ=+32 = check_node frame). Alias PA **`0x80046e38`** =
1st `sd ra,56(sp)` = 2nd `ld s3,24(sp)`. 2nd `c.sdsp s3` @`129d8` **commit_ack**
t=8245 with s3=lenp `0x80046f2c`; restore t=8599 retires **`0x12b2a`**. Mini
tight TRACE (SP=`0x80046eb0`, alias **`0x80046ec8`**) shows DRAM=lenp and
**`g1ao_hold` dead** — the 2nd `ld s3` takes **stale L1** (ACK-before-check
dropped the word write). Not a 5th combo. I4cf keep-on-cancel HOLD-FAIL — do
not re-land. Overlay remains load-bearing for h0 hart1 sticky; do not force
replay=0.

**Do next (still S1, still not I4cg / D$ fill / I4cf):** **nackinv
kept** (same-cycle; nackinv-d1 hung h0 @40000). Pin ELF `pin-bc7ed11d`
**cookie `51b1babe` t=108544** `plat_hc=2` `coldboot_done=1`. Hold
`8b6b310e` at **2M**: `plat_hc=2` BANR **`51b1c001`** =
`generic_cold_boot_allowed` stub, not truncated success cave. TRACE `s1-hold-ecall-d1rev` / `s1-hold-ecall-list`:
`sbi_ecall_register_extension` **NULL walk** (`a5=0`, sentinel
`a3=0x80040518`) while DRAM list is live (`next=ecall_time
0x800405a0`, `prev=ecall_rfence 0x800405d8`). `s1-hold-headld` (early commit TRACE) **Heisenbug**:
`sbi_heap_init @0x8000f3f4`. No-TRACE soak `s1-hold-2m-nots`: hangpc
**`0x80008d98` `a5=0`** (`ld a4,16(a5)` of NULL, IPI register),
plat_hc=2 BANR `51b1c001`. nackinv covers **checked** denied `wr_ack`
only; VOID ACK-before-check still leaves L1 at ELF/BSS (`ecall_time.next=0`).
VOID extra wr_req closed. `s1-hold-head90k`: first **8d8c @t=107092**
(TIME register); IPI walk is **time → rfence → NULL** (`8d9e` a5=0
@t=107455). Head is live; **`a5=0` was `ecall_rfence.next`**.
VOID-keep `0x80040xxx` until tag-check: void mini **PASS @406**;
h0 **PASS @16268**; pin **`51b1babe` t=131072**; hold **`51b1babe`
t=126976**. Dual-confirm. Overlay stock. ACK-before-check stock.
nackinv kept. S2 pin printf dual-confirm; hold BANR. I4dp not re-run. S4
Image external.

**Exit:** combined peel cookie **or** that L1-stale class moved the pin without
regressing hold cookie / I4dp.

### S2 — SL-B peel getprop + printf (OpenSBI O5)

Getprop on pin-bc7ed11d is **already natural** (namelen/next_tag match
diag; by_offset/namelen_ are jal probes). Printf peel (`sbi_printf@A980`
diag prologue): pin **`39b9dcc2` `51b1babe`+`51b1d000` t=131072** no BANR;
plat-ops-only **`7d670268` same cookie**. Hart-init-only FAIL leftover-RVI
at **`fdt_next_tag` FDT_PROP `addi@12ad6`** (`npc=12ad8` completing half;
`a0=0x82200638`). Canonical hold keeps BANR + `SOFT_HART_INIT` (`8b6b310e`).
Do not replace pin/held. **S2 pin printf dual-confirm.** Hold printf is
the `@12ad8` residual, not a new BANR peel.

### S3 — SL-C topology truth (OpenSBI O6)

Stock DTB, `hart_count==2` on smt2, hart1 `sp≠0`. I4dn already unmasks IPI.
I4dn + COLD IPI-preempt in `cva6.sv`. Pin/hold cookies kept (`sp1=0`).
Side `ipi-tab` `3314827d` **dual-confirm** cookie **`51b1babe`+`51b1d000`**
and **`sp1=0x80045f10`** (`s3-ipi-tab6`/`6b`, COOKIE_EXIT=0 200k). In-line
MSIP after cookie `sw` (no jal-to-hang). Do not replace pin/held. Do not
widen VOID-keep. Not G1dg. DTS stays `ariane-smt2.dts`.

### S4 — Full Linux Image on the **existing** boot envelope

Do **not** wait for smt2 cookie to invent a new `_v` boot. I4dp already has
`g6lc64_server_math_v` (N=2 T=2 I=2 V=1 H=1) at cap (2026-08-24 log). **R3b**
is external `Image` + `r3b-linux-image` on **that** package (`G6LC_DTS` /
`ariane-server-math-v.dts`, `tohost` `0x80041730`). smt2 R3b comes after S3.

S4 start (2026-08-26): `r3b-linux-image` contract **SKIP** (no Image). `_v`
Mdir rebuilt with COLD IPI-preempt. I4dp ELF
`linux-g6lc64_server_math_v/fw_payload.elf` md5 **`834d65e0`** is **R3a**
OpenSBI + `payload_bin` **0x178** at `0x80200000` (`smt2_sbi_dual`), **not**
Linux Image and **not** pin `bc7ed11d` (same md5 as `ooo_server/fw_payload.elf`).
`tohost` `0x80041730`. 2M smoke `s4-smv-2m` no-trap `tohost=0`; hangpc
`@2f0`/`plat_hc=80` is pin-layout / C0-only. Spike `-p2` + `ariane-smt2.dtb`
(`s4-spike-r3a`): **`SMT2-OSBI-OK`**. `[hangpc1]` 2M: C0 `@2f0` `sp=0`; C1
boot hart `sp=0x80046e10` illegal `@46f2c` (outside ELF; C1=`mhartid=2` not
in the ELF's 2-cpu FDT). `ariane-server-math-v.dts` now **4 `cpu@`** (N=2 T=2);
do not replace I4dp ELF `834d65e0`. New artifact **`203f9359`**
`build-platform/workspace/smt2-linux-v4/fw_payload_r3a_v4.elf` (4-cpu FDT).
2M `s4-v4-2m`: FDT tsz `0x1122` but **same C1 illegal `@46f2c`**. Cluster boot-hold **works** (v4 180k `[hangpc1]` all-0). C0 boot hart
`c.jr ra` to stack **`ra=mepc=0x80046f2c`** `coldboot_done=0` (pre-`sbi_init`,
`fw_platform_init`; FDT DRAM healthy). Cause: `_v` 1 GiB execute made
scratch X so I4v did not drop the JumpR (smt2 I4ag already `.text`-only).
Config: I4ag analog on `_v` (`.text` `0x1e000` + 32 MiB payload at
`0x80200000` + sign-ext; no page-0). **2M `s4-v4-pma-2m`:** IAF
`mcause=1` at `@46f2c` (was illegal 2). **TRACE `s4-op-ra-trace`:** jump table OK; `offset_ptr` #1 ret OK; name-loop
`jal@129f8` then IAF `@46f2c`. **`s4-v-nt-minis`:** frame32 + alias_jal **PASS**; stock/osbi **HANG**.
TRACE **`s4-stock-ldra`:** many `offset_ptr` then stuck `ld ra@e0`.
**RAS16 + TAGE_LITE + ckpt=16 SIGSEGV, reverted.** HPD last-id abort
**negative, reverted.** ckpt=0 and SKIP_HUB **same stock `ld ra@e0`**.
BHT diagnostic: stock hang **moved** to jtab `c.lw@130`; osbi **IAF `@46f2c`**.
**FtqDepth=0 live:** stock **PASS @1085**; **`mini_fdt_nt_osbi` PASS @20145**. v4 2M **past namelen** (`ra=0x80014182` after `jal fdt_stringlist_contains`); IAF **mepc=0** `mcause=1` WFI `_start_hang` (not `@46f2c`).
**`mini_hpd_2jr` HANG** at 2nd jtab `lw` after `jr a5`. Two `lw` and
`lw;jal;lw` **PASS**. Skip HPD `WAIT_FLUSH` **SIGSEGV, reverted**.
smt2 WT stock **PASS @756**. Do not re-land I4m
on B. Not G1dg.

This is how “works with `g6lc64_server_math_v` in line with current Linux boot
capabilities” is kept: Image/VRF/cpuinfo land on `_v` first; smt2 copies the
**software** path once FDT is honest.

### S5 — SMT2 `RVH` (smt2 feature not present)

Package bit + DTS `h` on both threads. Fetch: L4 pass-through only (no fake
`c.jalr` on I$ GPF). H-edge 3/3 on **smt2** TB via proxy `--verlib`. Do not
run slfix hold ELF as H-edge oracle.

### S6 — Stream plane (orthogonal)

- **N=2→4→8, T=1, I=1:** cluster + DTS + CLINT; **zero fetch combos**.
- **I=1→2:** `geo.issue=2`, `en.restore=0`; leftover **L1** present mini on
  stream8, not `mini_sib_cjalr`. Catalog keep may arm — soak FDT shape on
  stream8.
- Never smt2 hold ELF on stream8. Never SMT `cpu-map` threads on stream DTS.

### S7 — n-issue multi-core, adjustable `NrCores` (ooo_server class)

Live `ooo_server` is already **I=4, N=4, T=2, S=8**. Adjust N by config + DTS
+ L2 infer, not frontend:

| N | T | S | Allowed | Fetch |
|---|---|---|---------|-------|
| 1–4 | 2 | 2–8 | yes (PLIC bound) | leftover banks already T=2; L3 `geo.issue=4` |
| 8 | 1 | 8 | yes | `en.restore=0` |
| 8 | 2 | 16 | **no** until PLIC `NumTargets` grows | — |

n-wide 2→4: L3 loop only. Re-soak catalog keep/barrier; sibling mini **only if
T>1**. Frozen frontend untouched.

### S8 — `NrHarts>2` (not next)

Requires `CVA6_MAX_SMT_HARTS` lift, L1 leftover depth, scheduler, G3 `sp==0`
mini, CLINT/PLIC. **After** S3 and a written PLIC bound. Still no fifth combo.

### S9 — RVV on SMT (after AI-2)

`g6lc64_server_math_v` **is** the RVV Linux envelope now (S4). A `smt2_v`
package: `CvxifEn=0`, `RVV=1`, live Ara, after SL-C **and** AI-2 (SS ⟂ accel
assert). Fetch takes **no** `vl`/VRF ports. Re-soak hold + `v_memcpy_lmul`.

---

## 6. Step × combo × package

| Step | Package | Combo touched | Proxy tag (example) |
|------|---------|---------------|---------------------|
| S1 | `g6lc64_smt2` | none (STQ same-PA, not a combo) | `b1-frame32` PASS; `b1-nt-nl` pin `12eb2`; `s1-nt-nl-h0-trace` DRAM=lenp / s3=stale |
| S2–S3 | `g6lc64_smt2` | L4 restore if hart1 | soak default / nat |
| S4 | `g6lc64_server_math_v` | none if I4dp holds | `i4dp-smv` 200M |
| S5 | `g6lc64_smt2` + `RVH` | L4 ex suppress | `h-edge-smt2` |
| S6 N-scale | `g6lc64_stream8` | none | `stream8-n4` |
| S6 I=2 | stream8 SS | L1 leftover | `stream8-i2` |
| S7 | `g6lc64_ooo_server` | L3 issue loop only | `i4dp-ooo` |
| S8 | new `check_cfg` | L1 `geo.harts` | later |
| S9 | `_v` then `smt2_v` | none | `ara-vector-path` |

---

## 7. What “efficient” means here

- **Reuse I4dp boots** instead of re-proving Linux on smt2 first.
- **One VALUES row or one STQ/issue class** per iteration; revert HOLD-FAIL.
- **Cluster instantiates cores**; fetch arrays stay `[NrHarts]` per core.
- **DTS from `(N,T,ISA)`**; SL-E generator only when a third topology would
  triple-maintain hand files (`ariane-smt2`, `ariane-stream8`,
  `ariane-server-math-v`, `ariane-ooo-server`).
- **smt_legacy** only when an A/B pair is required to blame fetch vs generic.

---

## 8. Exit criteria (full Linux + SMT2 scale)

| Gate | Green means |
|------|-------------|
| smt2 OpenSBI | cookie `51b1babe`, `plat_hc==2`, hart1 parked, no soft getprop |
| `_v` Linux | I4dp cap **and** R3b Image `cpuinfo` count = 4 (`N=2,T=2`) |
| `ooo_server` Linux | I4dp cap; `cpuinfo` = 8; I=4 not visible in DTS |
| Stream | `stream8-smoke` + CRT at that `N`; I=2 leftover mini if SS |
| SMT2+H | H-edge 3/3 on smt2 TB; DTS `h` |
| SMT2+V | only after AI-2; `_v` path already green |

Fail-code names a **new** class (PLIC, G-stage, acc WB, FDT alias). It does
not reopen G1\* letters or `core/frontend`.
