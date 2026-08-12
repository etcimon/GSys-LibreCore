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
| **Hypothesis** | **Updated:** namelen_ entry args OK; callee-saved **s2/s3 clobber** before first `by_offset` (`check_node`/`next_tag`) → a0=0, a2=`0x12b2a` → honest store fault. Soft getprop holds cookie. |
| **I2 Repro** | `PEEL_FDT_GETPROP=1 SOFT_LADDER_HARNESS=work-ver-smt2-fw64 bash verif/regress/soft-ladder-opensbi-soak.sh` |
| **I3 Fix** | Soft getprop default (holding). PEEL free-cave probes in oracle (not silicon fix). |
| **I4 Verify** | default cookie **51b1babe** with soft getprop |
| **Bisects (all negative)** | dual-commit; STQ-nofwd; force SI; ALU cancel-exempt — same pin; reverted. |
| **Directed (2026-08-09 lab on soft-ladder @2c06e6fb0 + work-ver-smt2-fw64)** | **7/7 soft-ladder-di PASS** incl. FDT shape + **`mini_fdt_next_tag_lbu`** (4×lbu BE tag assemble + s2/s3 preserve). `mini_fdt_check_prop_nest` fixed (valid `a2`; compare `s2`↔`s3` post-nest). **Gap:** PEEL pin still not in minis — needs longer OpenSBI namelen_ graph (check_node×next_tag×by_offset with real DTB offsets), not just 3 tags. |
| **Probe (PEEL)** | **namelen_ entry** walk+0x30: a0=`0x8001e000` fdt, a4=`0x80046f2c` lenp, a3=10. **by_offset entry** walk+0: a0=**0**, a1=8, a2=s3=**`0x80012b2a`**, ra=`0x800130b6`, count=1. |
| **OpenSBI map** | `namelen_`: `mv s2,a0; mv s3,a4; jal check_node; … mv a0,s2; mv a2,s3; jal by_offset`. `check_node@12b26 jal next_tag` → ra **`0x12b2a`**. `by_offset` fail `sw a0,0(s2)@12eb2`. mtval=`0x12b2a` = **check_node's next_tag link**, not stack. |
| **Conclusion** | s2 (fdt→0) and s3 (lenp→code `0x12b2a`) corrupted **inside** namelen_ after entry, before first by_offset. Stack save/restore alone is insufficient to repro (minis green). |
| **RTL focus** | (1) `fdt_next_tag` **byte-load / tag-assemble** path under DI+FETCH_WIDTH=64 (hang-6/7 family). (2) RF write of **link (ra)** colliding with s3. (3) Scoreboard result bus / dual-commit not primary (bisect−). Existing SS full-serialize after ALU/CF/LSU already in `issue_read_operands.sv`. |
| **Scaffold** | P0 suites; probes @`0x2cc0`/`0x2d48` when PEEL_FDT_GETPROP=1. DI default tests now include FDT shape minis. |
| **Oracle path** | `software/smt2-linux/soft-ladder/` |
| **I4b Holding (reconfirmed)** | default soft getprop soak **CLASSIFY=SUCCESS** cookie `51b1babe`, `plat_hc=2`, `coldboot_done=1` on soft-ladder + `work-ver-smt2-fw64` (2026-08-09). |
| **I4c PEEL (reconfirmed red)** | `PEEL_FDT_GETPROP=1`: trapdump mepc=`0x80012eb2` mcause=6 mtval=`0x80012b2a` s2=`0x12b2a`; walk: namelen entry fdt/lenp **OK**, by_offset a2=s3=`0x12b2a`, ra=`0x130b6`, count=1; `plat_hc=80`. |
| **I3b RTL (2026-08-09, soft-ladder branch)** | **(1)** `scoreboard.sv`: under `SuperscalarEn`, **cancel younger LOADs** on mispredict (same-hart only when `NrHarts>1`). SI keeps cont.5 LOAD exemption. Rationale: PEEL s2/s3 ← ra-link / 0 from wrong-path load RF-writes after RAS-miss/JAL; `after_flu_wb` is branch-tid so correct-path epilogue re-issues. **(2)** `issue_stage.sv`: per-hart **`unresolved_sp_q`** — after GPR write to **x2 (sp)** under SS, stall that hart until sp-writer commits (peer SMT continues). Targets `fdt_next_tag` frame save/restore races. |
| **I3c SMT / AI co-req on E rebuild** | `g6lc_smt_csr_bank.sv`: wire `ai_aicfg`/`ai_ais`/dirty/setcfg (active-hart mux, commit-hart gate) so `g6lc64_smt2` elaborates with AI-E CSR sideband. Multi-threading invariant: AI bank state is per-hart CSR bank, not a shared sticky. |
| **I4d Harness** | Rebuild `work-ver-smt2-slfix` on full tree (`E:\cva6`) — soft-ladder worktree lacks hpdcache submodule for verilate. |
| **I4e Hold @8e6 (2026-08-11, `smt2-ai-tensor-linux`)** | Restored known-good oracle md5 **`bc7ed11d…`** (cold rebuild `871e7cb6…` regressed to `plat_hc=80`/R-error). **`slfix`:** `plat_hc=2` `coldboot_done=1` `last_hartidx=1` @8e6, **no cookie**; hangpc `npc0=0x8000032e` (`_start_warm`) mepc=0 mcause=2. **`fw64`:** same ELF still PEEL pin mepc=`0x12eb2` mcause=6. **iter-012 advances FDT; residual post-coldboot.** |
| **I4f Cookie chase (2026-08-11)** | Binary probes on good oracle + `slfix` (j SUCCESS / stubs). **Note:** `coldboot_done` is set **early** in `sbi_init` (@`0x828`, before `hart_init`) — it does **not** mean cookie path ran. |
| | **A** j SUCCESS @`0x82c` (post-`coldboot_done`) | **COOKIE GREEN** `51b1babe` — success cave SW works on slfix |
| | **E** j SUCCESS @`0x840` (after `sbi_hart_init`) | **FAIL** — hang **inside** `sbi_hart_init` (never returns) |
| | **K** j SUCCESS @`0xcd86` (CSR probe entry after memset) | **COOKIE GREEN** — hang is in **CSR expected-trap probe tail** (or later in hart_init after probes) |
| | **L** SOFT_CSR cut `cd86→cd0e` (reinit) | **FAIL** — reinit path not a valid skip on this ELF |
| | **N/P** stub `hart_init` ret0 / skip probes then ret0 | **banr** soft printf runs; hang **mepc=`0x8002047a`** mcause=2 — **FDT/rodata string executed as code** (`compatible`/`riscv,aplic` bytes); npc `_wait_for_boot_hart` |
| | **B/C/D** j SUCCESS at domain_fin / start_finish | **FAIL** (never reached without hart_init progress) |
| **Conclusion I4f** | (1) Cookie cave OK. (2) Stock residual on slfix: **`sbi_hart_init` CSR feature probes** (cont.33 family; `unresolved_csr_q` present but probes still die). (3) After soft-skip hart_init: **platform ops `c.jalr a5`** into FDT (irqchip@`17e0` first → mepc=`0x2047a`, then ipi/timer/tlb). |
| **I4g Holding cookie green (2026-08-11)** | **`SOFT_HART_INIT` + `SOFT_PLAT_OPS`** → **`51b1babe`**. Artifact `*.held.elf`. Track `hold` auto-prefers held (builds peels from pin if missing). Reconfirm: track hold 20/0 @3e6. |
| **I4h CSR minis (2026-08-11)** | `mini_csr_expected_trap` **PASS**. New **`mini_csr_pmp_probe`** (a3 trap_info + multi pmpcfg/pmpaddr + dual illegal) **PASS** on `slfix`. Directed CSR expected-trap shape is green under iter-012. |
| **I4i Platform ops residual** | With SOFT_HART_INIT only: hang mepc=`0x8002047a` (irqchip@`17e0`). SOFT_HART_INIT+irqchip only: mepc=`0x80020072` (next plat jalr, ipi family). Full `SOFT_PLAT_OPS` → cookie green. Ops `c.jalr a5` targets land in FDT — corrupt/uninitialized `platform->ops` after soft FDT path. |
| **I4s RTL dual-confirm (2026-08-12, `master` + `work-ver-smt2-slfix`)** | In tree: `scoreboard.sv` younger-cancel **LOAD** under `SuperscalarEn` (sticky + **same-cycle** `cancelled_mask`); `issue_stage.sv` **`unresolved_sp_q`** (sp-write issue gate). **No** `unresolved_link_q` (tried; regressed hold). |
| | **Oracle discipline** | Pin md5 **`bc7ed11dab17454fd147e4927ba07fef`** only. Rebuilding held/pin via `mk_plat_skip.py` from current `fw_payload_diag.elf` (`8169b747…`) yields cold-regress class **`plat_hc=80`** / mepc=`0x8` — same as `*.cold-regress-20260811` (`871e7cb6…`). **Never cold-patch from this diag.** Held rebuild: `rebuild_held_from_pin.sh` (SOFT_HART_INIT+PLAT peels on pin). Pin backup: `fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf`. |
| | **Hold dual-confirm** | held md5 **`8b6b310e…`** on slfix @6e6 ×2: cookie **`[1000]=…51b1babe`**, **`plat_hc=2`**, **`coldboot_done=1`**, BANR `@1068`. Classifier must accept wide dump `\[1000\]=[0-9a-fA-F]*51b1babe` (suite already does). |
| | **Lab scripts** | `run_i4s_pin_soaks.sh`, `rebuild_held_from_pin.sh` (MIT, soft-ladder/). |
| **I4j Stock peel bisect (2026-08-12, pin `bc7ed11d` + slfix I4s)** | Matrix on good pin (soft getprop already in pin): |
| | **stock** (natural hart_init + natural plat) | **FAIL** mepc=`0xffffffff800129f4` mcause=**1** (IAF) at `fdt_next_tag` after `jal fdt_offset_ptr` (`beqz a0` @`129f4`); `plat_hc=2` coldboot_done=1; **no** BANR |
| | **SOFT_HART_INIT only** | **FAIL** mepc=`0x8002047a` mcause=**2** (illegal) — FDT/rodata as code via plat `c.jalr`; BANR present; matches I4i |
| | **SOFT_PLAT_OPS only** | **FAIL** same as stock (IAF @`129f4`) — plat soft alone does **not** move the residual |
| | **SOFT_HART_INIT+PLAT (hold)** | **SUCCESS** dual-confirm I4s |
| | **Read** | Two serial residuals under I4s: (1) **natural hart_init** → next_tag IAF (new/precise pin vs historic CSR-probe hang); (2) after soft hart_init → **platform ops→FDT**. CSR minis still green. |
| **I4k Soft next_tag peels stock (2026-08-12)** | On pin `bc7ed11d` + **soft `fdt_next_tag` ret0 only** (natural hart_init, natural plat ops, soft getprop already in pin): **dual-confirm SUCCESS** cookie `…51b1babe` `plat_hc=2` on slfix I4s. **Preferred hold** vs SOFT_HART_INIT+PLAT — peels natural hart_init/platform. Residual for RTL is **natural `fdt_next_tag`** (IAF after `fdt_offset_ptr` @`129f4`). `mk_plat_skip.py` now has `SOFT_FDT_NEXT_TAG` (default soft). |
| **I4l PMA DRAM alias (2026-08-12)** | Raw `mepc_q` is **`0xffff_ffff_8001_29f4`** (not a print artifact; `VLEN=XLEN=64`). IAF (`mcause=1`) is **`!match_any_execute_region`** in `pmp_data_if.sv`: execute window was only `0x8000_0000`..`0xC000_0000`. Fetch of the sign-extended DRAM alias misses PMA → IAF at the `beqz` after `jal fdt_offset_ptr`. |
| | **RTL** | `g6lc64_smt2_config_pkg.sv`: 4th execute + 2nd cached rule for `0xffff_ffff_8000_0000` length `0x4000_0000` (same DRAM). slfix rebuilt 2026-08-12 14:10. |
| | **Soak (I4l slfix)** | **Hold still SUCCESS** cookie/`plat_hc=2`. **Natural next_tag:** IAF @`129f4` **gone**. New residual: `mepc=0` `mcause=2` `npc0=0x8000032e` (`_start_warm`) `plat_hc=2` — RAS/return-to-0 family, not PMA. |
| **I4m Link-LOAD cancel + RAS ra=0 (2026-08-12)** | After I4l, natural next_tag `mepc=0` `mcause=2` `npc=_start_warm`. Hypothesis: I4s cancelled `fdt_offset_ptr` epilogue `ld ra,8(sp)` → `c.jr ra` to 0. |
| | **RTL** | `scoreboard.sv`: SS still younger-cancels LOAD except **rd==x1/x5**. `frontend.sv`: RAS `valid && ra==0` treated as empty. |
| | **Soak I4m slfix** | **Hold SUCCESS.** **Natural next_tag still FAIL** `mepc=0` `npc=_start_warm` — exempting `ld ra` was **not** enough. |
| **I4n** | Also spare non-AMO **STORE of rs2==x1/x5** (`sd ra` / `c.sdsp ra`). AMO still cancels. |
| | **Soak I4n slfix 14:39** | **Hold SUCCESS.** **Natural next_tag still FAIL** same pin (`mepc=0` `npc=_start_warm`). Link save/restore cancel is **not** the residual. Stop cancel-exemption chase. |
| **I4o Hang decode (2026-08-12)** | `npc0=0x8000032e` is `_start_warm` hart-id scan (`lwu a5,0(s9)`). Extended `[hangpc]` (TB-only relink) on natural next_tag: |
| | **act=1** | Live frontend is **hart 1** |
| | **hart0** | `mepc0=0` `mcause0=2` `wfi0=1` — **hart 0 already illegal-at-0**, parked WFI. **ra0=0x1** (not 0) **sp0=0x80047ca0** — I4m “jr ra with ra=0” is **wrong** |
| | **hart1** | `mepc1=0` `mcause1=0` `wfi1=0` `ra1=0x80000010` `sp1=0` — no trap; stuck in warm hart-id scan |
| | **Read** | Two-hart split: hart0 died at PC=0; hart1 never finished `_start_warm` (sp=0). Soft next_tag avoids whatever sent hart0 to 0. |
| **I4p SMT NPC-bank zero (2026-08-12)** | I4o: hart0 `mepc=0` while hart1 lives in `_start_warm`. `g6lc_smt_pc_bank` continuously snapshots `npc_live` (frontend `npc_q`, **reset 0**) over the reset `boot_addr`. First-cycle live=0 poisons bank[0]; later switch restores **PC=0**. |
| | **RTL** | `g6lc_smt_pc_bank.sv`: do not write a zero live NPC; restore 0 → `boot_addr_i`. `frontend.sv`: no `bp_valid` to PC=0 when `NrHarts>1`; no BTB train of target 0. |
| | **Soak I4p slfix 15:05** | **Hold SUCCESS** (hart1 now `sp1=0x80046000` `wfi1=1` — healthier than I4o). **Natural next_tag still FAIL** same split: `act=1` hart0 `mepc=0/wfi` `ra0=1`; hart1 `_start_warm@32e` `sp1=0`. PC-bank zero-guard is good SMT hygiene but **not** the nat next_tag residual. |
| **I4q Mispredict-to-0 (2026-08-12)** | I4p only blocked *predict* to 0. EX `is_mispredict` still did `npc_d = target` even when target=0 (JALR/rs1 stale). That fetch is empty DRAM → hart0 illegal. |
| | **RTL** | `frontend.sv` `npc_select`: if `NrHarts>1` and mispredict target is 0, **keep** `npc_q`. |
| | **Soak I4q slfix 15:16** | **PC=0 gone** (no `[first0]`). **Hold** now dies at **PEEL getprop** `mepc=0x80012eb2` `mcause=6` `ra=0x12e3e` (BANR, plat_hc=2) — FDT progressed. **Nat next_tag** dies **inside** `fdt_next_tag` `sw` @`129e8` `mcause=6` (nextoffset ptr). |
| **I4q hold+by_offset (held `c06e9bd3`)** | Stub `fdt_get_property_by_offset_` `c.li a0,0; c.jr ra`. **FAIL** cookie **`51b1c001`** (success-cave `lui t0,0x51b1c` without `addi -0x542` → `51b1babe`). Hang: hart0 **`spin_lock@8cbc`** (from `sbi_domain_dump` ra=`0xb2a2`); hart1 **`sbi_ecall_get_impid` `ld`@`8d18`** mcause=**4** `sp1=0x20` `wfi1=1`. I4q NPC-only guard left `is_mispredict` live → IF flush + younger-cancel of the correct path. |
| **I4t Zero-target JALR is not a flush (2026-08-12)** | I4q skipped NPC write but still declared mispredict. Controller flushed IF; scoreboard cancelled younger (including `spin_unlock` `lhu`, stack restores, success-cave `addi`). |
| | **RTL** | `branch_unit.sv`: if `NrHarts>1` and JALR target is 0, **clear** `is_mispredict`/`ckpt_restore`. `frontend.sv`: `is_mispredict` also ignores target-0. `scoreboard.sv`: `bmiss` also ignores target-0. SI const-folds away. |
| | **Timing** | One extra compare on the existing resolve/bmiss comb cones (`target==0`), gated by `NrHarts>1` so SI is bit-identical. No new sequential logic, clock, or SRAM. |
| | **Soak I4t slfix `ae305df2`** | **Hold+by_offset** still `51b1c001`: hart0 **`spin_unlock@8cc8`** (lock acquired vs I4q `spin_lock@8cbc`); hart1 `sbi_ecall_unregister` `ld@8df0` mcause=4 `sp1=0x10`. **Nat next_tag advanced:** no more `sw@129e8`; both WFI; hart1 **`sp1=0x80045f10`** in `sbi_hsm_init` wait (`atomic_read` ra=`0xf7a0`); hart0 IAF `mepc=0x8fffffff8` mcause=1. `[1000]` low word is a real `sw` of `51b1c001` over ELF `20ef8526`. |
| **I4u PC-bank snapshot only on switch (2026-08-12)** | Continuous `npc_q`→active-bank snapshot poisons the incoming hart: one beat after switch `npc_q` is still the outgoing stream. Hart1 then runs boot-hart code with a near-zero SP. |
| | **RTL** | `g6lc_smt_pc_bank.sv`: write the bank **only** on `switch_i` into `prev_hart` (I4p zero-guard kept). Restore still boot_addr if bank is 0. |
| | **Soak I4u hold-nobyoff `8b6b310e` slfix `28b3dfa7`** | **SUCCESS** cookie `…51b1babe` + `51b1d000` @1008, `plat_hc=2` BANR `coldboot_done=1`. hart1 parked `sp1=0x80046000` `wfi1=1`. Hold cookie restored (I4s ELF; do not keep by_offset stub on hold). |
| | **Soak I4u nat pin `bc7ed11d` slfix `28b3dfa7`** | **FAIL** same class as I4t nat: cookie `51b1c001` (cave lui, no `addi -0x542`); both WFI; hart1 healthy `sp1=0x80045f10` `sbi_hsm_init` wait; hart0 **IAF `mepc=ra=0x8fffffff8` mcause=1**. I4t unblocked `sw@129e8`; residual is a bad CF target on hart0. |
| **I6 Next** | Nat residual: hart0 IAF `0x8fffffff8` (HSM wait). Hold stays I4s peels `8b6b310e`. Then PEEL getprop. Do not cold-`mk` from diag `8169b747`. |

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
