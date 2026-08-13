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
| **I4v JALR target must be executable (2026-08-12)** | Nat residual after I4t/u: hart0 `c.jr`/`jalr` to **`0x8fffffff8`** (not in any execute PMA → IAF). I4t only dropped target 0; page-0 is still an execute *rule* (`0x0` len `0x1000`) so PMA-alone would re-allow PC=0. |
| | **RTL** | SMT JALR is not a mispredict/bmiss/NPC reseed/BTB train unless target is **above page 0** and `is_inside_execute_regions`. Same three sites as I4t. |
| | **Timing** | Four existing PMA range-checks on the resolve cone, gated by `NrHarts>1`. Same helper already on the I$ path (`pmp_data_if`). |
| | **Soak I4v slfix `5431a9d5`** | **Hold SUCCESS** `51b1babe`+`51b1d000` (no regression). **Nat:** `0x8fffffff8` IAF **gone**. New pin: hart0 **illegal `mepc=0x82200004`** mcause=2 `ra0=0x82200000` (empty DRAM — not in ELF; segments end `0x80022e18` / `0x80200178`). hart1 in `_wait_for_boot_hart@2e8` `sp1=0` `wfi1=0` (secondary wait; not the I4q poison). Cookie still `51b1c001`. |
| **I4w Execute is text, not 1 GiB DRAM (2026-08-12)** | I4v nat jumped to **`0x82200000`** = payload **`0x80200000`** with bit 25 set. 1 GiB execute (I4l copy of the original window) made that empty DRAM PMA-legal → illegal @`0x82200004`. ELF text ends `0x80022e18`; payload is `0x80200000` (0x178 B). |
| | **RTL** | `g6lc64_smt2_config_pkg.sv`: execute length **32 MiB** (`0x200_0000`) on both identity and sign-ext alias. Cached stays 1 GiB. I4v then treats `0x82200000` as a non-execute JALR (no flush/reseed). |
| | **Timing** | Config constants only; no new logic. |
| | **Soak I4w slfix `4e75093e`** | **Hold SUCCESS** `51b1babe`+`51b1d000` (no regression). **Nat:** `0x82200004` illegal **gone**; no more `51b1c001`. New pin: hart0 **`_trap_handler` `sd`@`3e4`** mcause=**6** mtval=`0xfd` (t1 not the `0x80001000` dump base). mtvec=`0x3d8` first insn is patched `j 0x2d00` (pmu/trap cave) — fallthrough into the dump with garbage t1. hart1 `_start_warm` `sp1=0`. |
| **I4x Trap-vector JAL is not a JALR (2026-08-12)** | I4w nat: first insn at `mtvec=0x3d8` is patched `jal x0, 0x2d00` (dump cave). I4v's frontend/`bmiss` filter applied to *every* mispredict, so that Jump lost its flush and fallthrough `sd@3e4` ran with garbage t1 (mtval=`0xfd`). |
| | **RTL** | Frontend `is_mispredict` + scoreboard `bmiss` suppress **only** `cf_type==JumpR`. `controller.sv`: on SMT, a predicted-correct taken **Jump** still `flush_unissued` (IQ fallthrough kill; no `flush_if`). |
| | **Soak I4x slfix `70d39e28`** | **Hold SUCCESS.** **Nat same pin** as I4w (`mepc=0x3e4` mcause=6). Fallthrough is not a JALR-filter miss: they never fetched `jal@3d8` (next 8B block `@3e0`). |
| **I4y Trap vector outranks SMT restore (2026-08-12)** | `npc_select` gave SMT restore highest priority, so a switch on/after `ex_valid` replaced `mtvec=0x3d8` with a stepped NPC (`0x3e0`). |
| | **RTL** | `frontend.sv`: restore only if no exception/eret/CSR-flush/debug. **Not** `flush_i`→no-switch (that starved hart1, hold `51b1c001`). |
| | **Soak I4y restore-priority `0787247a`** | **Hold SUCCESS.** **Nat same** `3e4` — restore-vs-trap alone is not enough (flush may persist a cycle after `ex_valid`). |
| | **RTL+** | Also: `if_ready && !flush_i` before NPC increment so a killed mtvec fetch cannot step to +8. |
| | **Soak I4y+ `51989a79`** | **Hold SUCCESS.** **Nat still `3e4`.** Restore-priority + no-NPC-step-on-flush did not fetch `jal@3d8`. Nested cave dump still records the fallthrough `sd`. |
| **I4z Sticky mtvec fetch (2026-08-12)** | I4y did not move `3e4`: first 8B at `mtvec` still never registered. Stale `bp_valid`/`kill_s2` plus `if_ready` step drops the jal line; next block is `csrr@3e0`/`sd@3e4`. |
| | **RTL** | `frontend.sv` (smt2 only): on `ex_valid` latch mtvec and hold `fetch_address`/`npc` there until `icache_valid_q` presents that block. Stale `bp_valid` does not kill that fill or steal NPC. SI unchanged. |
| | **Soak I4z slfix `48a38994`** | **Hold SUCCESS.** **Nat `3e4` gone.** New pin: inside **`__sbi_expected_trap`** `csrr mtval@0xff0e` mcause=2; `mtvec=0xff08`; ra=`0xcd86` (`sbi_hart_init` post-memset CSR probes). hart1 IAF `mepc=0x4`. Cookie `51b1c001` (cave lui). I4z unblocked mtvec fetch; residual is expected-trap / hart_init (I4f/cont.33). |
| **I4aa Expected-trap I+C+RVI realign (2026-08-12)** | `__sbi_expected_trap` is `csrr; c.sd; csrr` in one 64-bit fetch. Re-align presented `{csrr_lo, c.sd}` as a 32-bit at `+4`, so `csrr mtval@ff0e` was illegal. |
| | **RTL** | `instr_realign.sv` (FETCH_WIDTH=64, RVI-first): C then RVI-start → emit the C alone and carry the half-RVI as unaligned. `frontend.sv`: one-beat `trap_tail_q` after mtvec hit so SMT restore cannot steal the completing fetch. |
| | **Soak I4aa slfix `0fb8f0f8`** | **Hold SUCCESS.** **Nat same pin** as I4z (`ff0e` mcause=2, `mtvec=ff08`, ra=`cd86`). Re-align I+C+RVI split + longer trap_tail did not move it — completing fetch is present (`npc=0xff10`); residual is inside the handler (a3/`unresolved_csr` or a second decode of `csrr mtval`). |
| **I4ab Per-hart realign leftover (2026-08-12)** | I4aa soak-negative: `npc=ff10` so the completing line exists, but a shared `unaligned_q` is cleared on SMT `flush_if`. Hart0 then resumes the `csrr mtval` fragment at `ff0e` as illegal. |
| | **RTL** | `instr_realign.sv`: bank leftover/addr/flag by `hart_i`; flush clears only the active hart. `frontend.sv` passes `smt_hart_i`. SI is one bank. |
| | **Soak I4ab slfix `372e2ef5`** | **Hold SUCCESS.** **Nat same pin** (`ff0e` mcause=2). Per-hart leftover is still good SMT hygiene but is not this fault. |
| **I4ac Keep realign leftover through trap-tail (2026-08-13)** | `csrr mtval@ff0e` is a straddling RVI. `instr_realign.flush_i` was `kill_s2` (flush_if \| bp). A flush while hart0 is still active (trap-tail) dropped the leftover 16b; the 16b fragment `0x2773` decodes as `csrrs a4, 0x0` → illegal at `ff0e`. |
| | **RTL** | `frontend.sv`: realign flush = `kill_s1 & ~trap_hold`. Exception entry still clears leftover (arm `trap_fetch` one cycle later). |
| | **Soak I4ac slfix `b6c8c35a`** | **HOLD FAIL** `plat_hc=80` `mepc=0x80000098` mcause=6 (bootrom). Gating realign flush with `~trap_hold` is too early-boot. **Reverted.** |
| **I4ad Leftover-RVI keep + no-fragment complete (2026-08-13)** | Completing fetch assembled `{0x3430, leftover=0}` = `0x34300000` (compressed-0 / illegal) at `ff0e`. Flush cleared the leftover *flag* the same cycle the 16b `0x2773` was saved. I4ac kept leftover by muting `flush_i` for all of `trap_hold`, so *pre-trap* leftover survived into bootrom. |
| | **RTL** | `instr_realign.sv`: (1) `clear_unaligned_i` on SMT `ex_valid` (new stream at mtvec); (2) keep leftover across `kill_s2` only while `trap_hold` *after* that clear; (3) complete only if leftover `[1:0]==11` (`leftover_rvi`) — do not issue `{hi, 0}`. `frontend.sv`: pass `ex_valid` as clear; stale `bp_valid` no longer kills/redirects during `trap_hold` (fetch+tail). Realign `flush_i` stays `kill_s2` (I4ac revert). SI: both new ports const-0; leftover_rvi is a 2-bit compare on an existing flop. |
| | **Timing** | One 2-bit leftover compare on the realign comb cone; `ex_valid` and `trap_hold` already exist. No new sequential depth, clock, or SRAM. |
| | **Soak I4ad slfix `69217636`** | **Hold SUCCESS** `51b1babe`+`51b1d000` `plat_hc=2` (I4ac hold-regress gone). **Nat same pin** `ff0e` mcause=2 `mtvec=ff08` ra0=`cd86`. npc advanced to **`ff20`**. Both harts now `mepc=ff0e`. Completing against a *replay of the mtvec block* would assemble `{csrr_mcause_lo, 0x2773}` at `ff0e`. |
| **I4ae Same-block leftover is not a complete (2026-08-13)** | I4ad keep leftover through trap_hold; a *replay* of `ff08` then completed `{data[15:0]=0x2773, leftover=0x2773}` = `0x27732773` (csr `0x277`) at `ff0e`. Real complete is the next 8B (`ff10` = `0x3430`). |
| | **RTL** | `instr_realign.sv` FETCH_WIDTH=64: complete leftover only when `address_i[VLEN-1:3] != leftover[VLEN-1:3]`. Same-block replay takes the aligned I+C+RVI path (I4aa re-saves `0x2773`). SI unchanged (compare is on existing address bits). |
| | **Timing** | One `(VLEN-3)`-bit equality on the realign comb cone, gated by leftover_rvi. No new flops. |
| | **Soak I4ae slfix `db528dc4`** | **Hold SUCCESS** (no regression). **Nat `ff0e` gone.** New pin: `fdt_next_node` `lw s1,-72(s0)` @`0x12c0a` mcause=4 mtval=`0x8001f7b9` s0=`0x8001f801` (FDT-ish fp). sp0=`0x80047cf0` healthy. Both WFI. hart1 still `sd@3e4` mcause=6 `sp1=0`. Cookie cave `51b1c001` gone; `plat_hc=2` `coldboot_done=1`. Expected-trap unblocked; residual is the FDT-walk s0 clobber (SL-A). |
| **I4af unresolved fp / x8 (2026-08-13)** | I4ae nat: `fdt_next_node` `lw s1,-72(s0)` @`12c0a` mcause=4 with **s0=`0x8001f801`** (.rodata/FDT), not the stack fp. Prologue is `addi s0,sp,80` then immediate `sw/lw ±72(s0)`. I4s gated only x2; younger frame ops can issue with a stale s0 (previous libfdt leftover). |
| | **RTL** | `issue_stage.sv`: `unresolved_fp_q` mirrors `unresolved_sp_q` for rd **x8**. Same-hart SS only; SI const-0. One flop/hart, same issue-valid AND. |
| | **Timing** | Extra 1-bit flop + compare on the existing issue-valid cone, gated by `SuperscalarEn`. No new FU, SRAM, or clock. |
| | **Soak I4af slfix `c0152778`** | **HOLD FAIL** `plat_hc=80` `coldboot_done=0` `ld@0x7378` mcause=4 mtval=`0x80046f94` (sp+4). Gating *all* younger issue on x8 is too coarse (I4s x2 is the stack pointer; x8 is written in every framed function). **Reverted.** |
| **I4ag Execute is .text, not FDT/rodata (2026-08-13)** | I4w 32 MiB execute still covers `.rodata`/`FDT` @`0x8001e000`. I4ae nat s0=`0x8001f801` is interior rodata; `fdt_next_tag` `jr a5` through a jump table is PMA-legal if a5 lands there. I4af x8-gate hold-regressed — this is config only. |
| | **RTL** | `g6lc64_smt2_config_pkg.sv`: identity+sign-ext execute length **`0x1e000`** (`.text` ends `0x1d918`; `.rodata` starts `0x1e000`). Add 4 KiB execute at `0x80200000` and sign-ext alias. Cached stays 1 GiB. I4v then refuses JALR into FDT. |
| | **Timing** | Two extra PMA range-checks on the existing I4v resolve cone. No sequential logic. |
| | **Soak I4ag slfix `6021c2ca`** | **Hold SUCCESS** (no regression). **Nat same pin** as I4ae (`lw@12c0a` s0=`0x8001f801`). s0 poison is a register clobber, not a JALR into FDT. I4ag still correct (I4w follow-through) — keep. |
| **I4ah Predicted CF must be executable (2026-08-13)** | I4ag made FDT non-execute, so I4v no longer treats `jr`→`0x8001f801` as a mispredict. A *stale BTB* hit on `fdt_next_tag` `jr a5` still fetched rodata; that stream was never flushed and s0 became `0x8001f801` at `lw@12c0a`. I4p only dropped target 0. |
| | **RTL** | `frontend.sv` `bp_valid`: SMT also requires `is_inside_execute_regions` (same helper as I4v). SI unchanged. |
| | **Timing** | Reuse the four PMA compares already on the I4v resolve cone; now also on `bp_valid` (not the ALU). No new flops. |
| | **Soak I4ah slfix `706de030`** | **Hold SUCCESS.** **Nat same pin** as I4ae/g (`lw@12c0a` s0=`0x8001f801`). Stale-BTB fetch of FDT is not this fault (or BTB was already clean). I4ah still closes the I4ag+I4v predict hole — keep. |
| **I4ai Cancel-exempt fp save/restore (2026-08-13)** | I4ae–h nat s0=`0x8001f801` is **`"/cpus"+1`** in `.rodata` — a caller name pointer, not a computed fp. I4n already keeps `sd`/`ld` of ra (x1/x5) through bmiss; `sd s0`/`ld s0` were still cancelled, so a framed libfdt call could return with the caller's name pointer still in s0. I4af (issue-gate) hold-regressed; this is the I4n bit only. |
| | **RTL** | `scoreboard.sv` sequential cancel + same-cycle `cancelled_mask`: also skip SS non-AMO STORE rs2==x8 and SS LOAD rd==x8. SI unchanged (cont.5). |
| | **Timing** | Two extra 5-bit compares on the existing cancel cone. No new flops. |
| | **Soak I4ai slfix `c6c75e27`** | **Hold SUCCESS.** **Nat same pin** (`lw@12c0a` s0=`0x8001f801`). Cancel-exempt fp save/restore is not this write — s0 is already the name pointer at the `lw`. Keep (I4n analog, hold-safe). Note: LOAD-exempt x8 can let a wrong-path `ld s0` retire the caller's name pointer; next increment may drop that half. |
| **I4aj Keep `addi s0,sp,*` through bmiss (2026-08-13)** | I4ai soak-negative: s0 was already `"/cpus"+1` at the `lw`. That is the *caller* name pointer left in RF when a bmiss cancelled `addi s0,sp,80` (ALU, not I4n-class). Wrong-path `ld s0` would *reinstall* that pointer — I4aj **drops** I4ai's LOAD-x8 exempt. |
| | **RTL** | `scoreboard.sv`: SS cancel skips ALU `rd==x8 && rs1==x2` (fp setup). Keep STORE rs2==x8. LOAD x8 cancel restored (I4m). SI unchanged. |
| | **Timing** | Two extra 5-bit compares on the existing cancel cone. No new flops. |
| | **Soak I4aj slfix `2087fecb`** | **Hold SUCCESS.** **Nat same pin** (`lw@12c0a` s0=`0x8001f801`). Cancelling `addi s0,sp,*` is not this write. Keep (tighter than I4ai LOAD-x8 exempt). |
| **I4ak FLU ALU0 result pairs with port0 tid (2026-08-13)** | I4aj soak-negative. `fdt_get_name` `addi s1,a0,1` produces **exactly** `"/cpus"+1`. FLU mux retired `alu_result[0]` under `one_cycle_data.trans_id` (last one-cycle port) while ALU0 inputs were also `one_cycle_data` — a later port could steal ALU0 and/or the tid. |
| | **RTL** | `ex_stage.sv`: `alu_data[0] = alu_valid[0] ? fu_data[0] : one_cycle_data`. FLU WB: `alu_valid[0]` writes `alu_result[0]` to `fu_data[0].trans_id`. Other-port ALU still via `|alu_valid` + `one_cycle_data`. SI: `alu_valid[0]` is the only bit (identity). |
| | **Timing** | Same FLU mux cone; one extra `alu_valid[0]` select. No new flops. |
| | **Soak I4ak slfix `0e1d5e3e`** | **Hold SUCCESS.** **Nat same pin** (`lw@12c0a` s0=`0x8001f801`). FLU port0 pairing is not this write (SS already one FLU/cycle). Keep (correctness). `fdt_get_name` `addi s1,a0,1` still the unique producer of `"/cpus"+1`. |
| **I4al Keep `ld s0,off(sp)` through bmiss (2026-08-13)** | I4aj soak-negative: poison is written *after* `next_node` prologue. `fdt_offset_ptr` `add a0,a0,a1` / `fdt_get_name` `addi s1,a0,1` can land `"/cpus"+1` in x8; cancelled `ld s0,0(sp)` then leaves it. I4ai blanket LOAD-x8 was dropped (wrong-path `ld s0` from a non-sp base). |
| | **RTL** | `scoreboard.sv`: also skip SS LOAD `rd==x8 && rs1==x2` (`c.ldsp` / `ld s0,imm(sp)`). Link x1/x5 unchanged. SI unchanged. |
| | **Timing** | Two extra 5-bit compares on the existing cancel cone. No new flops. |
| | **Soak I4al slfix `67449f6a`** | **Hold SUCCESS.** **Nat same pin** (`lw@12c0a` s0=`0x8001f801`). Stack `ld s0` restore is not this write. Keep (I4n analog for fp). The `"/cpus"+1` value is a **committed** ALU/add with `rd=s0`, not a cancelled restore. |
| **I4am Commit: no unaligned addi-to-s0; CASQ waddr gated (2026-08-13)** | I4al soak-negative: `"/cpus"+1` is a *committed* ALU write to x8. `addi s1,a0,1` vs `addi s0,a0,1` is `rd[0]`. Leftover AMOCAS.Q `dual_we` retargeted `waddr[1]=rd\|1` on any retire. |
| | **RTL** | `commit_stage.sv`: (1) `casq_dual_now` only if `op==AMO_CASQ`. (2) SMT+SS: suppress GPR write of ALU `use_imm` to x8 when `result[3:0]!=0` (cannot be ABI fp). `mv s0,a0` (`!use_imm`) untouched. SI unchanged. |
| | **Timing** | One extra compare on the existing commit we_gpr cone. No new flops. |
| | **Soak I4am slfix `f740d7d7`** | **Hold SUCCESS.** **Nat same pin.** The s0 write is **not** `addi` (`use_imm`) — filter never fired. Leftover is R-type `add` (`c.add a0,a1` in `offset_ptr`) or a load. CASQ `waddr` gate still correct — keep. |
| **I4an Commit: no unaligned `add` to s0 except `c.mv` (2026-08-13)** | I4am soak-negative: write is not `addi`. `fdt_offset_ptr` `c.add a0,a1` is R-type ADD (`!use_imm`); if it retires as `rd=s0`, result is `"/cpus"+1`. |
| | **RTL** | `commit_stage.sv`: extend I4am — also suppress ALU to x8 when `result[3:0]!=0` and (`use_imm` **or** `rs1!=x0`). `c.mv s0,rs2` (`rs1=x0`) still writes. SMT+SS only. |
| | **Timing** | Same commit we_gpr cone as I4am; one extra rs1 compare. No new flops. |
| | **Soak I4an slfix `35b18409`** | **Hold SUCCESS** (`51b1babe` `plat_hc=2`). **Nat same pin** (`lw@12c0a` s0=`0x8001f801` ra0=`1`). Write is **not** R-type `add` either (or `we_gpr` already 0 / `rd`/`result` not matching at commit). Keep (tighter ALU filter, hold-safe). Leftover: LOAD / `c.mv s0,rs2` / wdata≠result. |
| **I4ao Commit: no unaligned write to s0 (2026-08-13)** | I4an soak-negative: not ALU `addi`/`add`. Next producers of `"/cpus"+1` in x8 are a **LOAD** of that pointer or `c.mv s0,rs2` (`rs1=x0`, I4an explicitly open). ABI fp is 16B-aligned — any unaligned result to x8 is not a frame pointer. |
| | **RTL** | `commit_stage.sv`: drop the ALU/`use_imm`/`rs1` qualifier. SMT+SS: suppress **any** `we_gpr` to x8 when `result[3:0]!=0`. SI unchanged. |
| | **Timing** | Same commit we_gpr cone as I4an; fewer compares. No new flops. |
| | **Soak I4ao slfix `e2f62630`** | **Hold SUCCESS** (`51b1babe` `plat_hc=2`). **Nat moved.** `12c0a` load-fault / s0=`"/cpus"+1` **gone**. New class: cookie **`51b1c001`** (cave `lui t0,0x51b1c` without `addi -0x542` → `51b1babe`); hangpc `npc0=0x12c0a` `mepc0=0xec14` mcause=2 `ra0=8`; `[1008]` not `51b1d000`; hart1 clean; both not WFI. I4ao fired — poison was a committed unaligned `we_gpr`→s0 (LOAD/`c.mv`). Keep. |
| **I4ap Keep `addi t0,t0,*` through bmiss (2026-08-13)** | I4ao unblocked the s0 poison. Nat now writes the success-cave `lui` half (`51b1c001`) but not `addi t0,t0,-0x542` (`51b1babe`) nor the `51b1d000` store. I4n keeps `ld`/`sd` of x5; ALU `addi t0` is still cancelled on bmiss. |
| | **RTL** | `scoreboard.sv`: also skip SS cancel of ALU `rd==x5 && rs1==x5 && use_imm` (`addi t0,t0,imm`). Sequential + `cancelled_mask`. SI unchanged. Not an fp peel. |
| | **Timing** | Two extra 5-bit compares + `use_imm` on the existing cancel cone. No new flops. |
| | **Soak I4ap slfix `315db99b`** | **Hold SUCCESS.** **Nat same as I4ao** (`51b1c001`, `npc=12c0a`, `mepc=ec14` mcause=2 `ra0=8`). Cookie `addi t0,t0,-0x542` is not cancelled (or never reached). Keep (x5 analog of I4aj, hold-safe). Live hang is still `lw s1,-72(s0)` @`12c0a` — no mcause=4 because I4ao blocked the poison write. |
| **I4aq Keep `lw *,off(s0)` through bmiss (2026-08-13)** | I4ap soak-negative. I4s still cancels `lw s1,-72(s0)` (rd=x9, rs1=x8). I4al only keeps loads *into* s0 from sp. After I4ao the address is a real fp; a bmiss-cancel of that lw leaves npc stuck at `12c0a` with no access fault. |
| | **RTL** | `scoreboard.sv`: also skip SS LOAD `rs1==x8` (frame-relative). Sequential + `cancelled_mask`. Link x1/x5 and `ld s0,off(sp)` unchanged. SI unchanged. |
| | **Timing** | One extra 5-bit compare on the existing cancel cone. No new flops. |
| | **Soak I4aq slfix `99fee71f`** | **Hold SUCCESS.** **Nat same as I4ao/p** (`51b1c001`, `npc=12c0a`, `mepc=ec14` `ra0=8`). Cancelling `lw s1,-72(s0)` is not this hang. Keep (I4al analog for frame-relative, hold-safe). Leftover: leftover `amo_resp` wdata mux, hangpc-bank stale vs live cave, or `ra=8` clobber. |
| **I4ar Commit: amo wdata only when retiring an AMO (2026-08-13)** | I4aq soak-negative. Default `wdata[0] = amo_resp.ack ? amo_result : instr.result` — leftover `ack` after LR/SC/CAS substitutes AMO data onto the next ALU/LOAD retire. I4am/n/ao all filter `commit_instr.result`, so they miss this. Matches I4am leftover `dual_we`. |
| | **RTL** | `commit_stage.sv`: `wdata[0]` takes `amo_resp.result` only if `ack && instr_0_is_amo`. AMO block already gated. All configs (leftover ack is not SMT-only). |
| | **Timing** | One extra AND on the existing wdata mux select. No new flops. |
| | **Soak I4ar slfix `d2972c59`** | **Hold SUCCESS.** **Nat same as I4ao** (`51b1c001`, `npc=12c0a`, `mepc=ec14` `ra0=8`). Leftover `amo_resp` wdata is not this write. Keep (I4am analog, correctness). `mepc=ec14` is stale hart_init `csrw mtvec` after `tselect` (coldboot already done). Live: cave stored `51b1c001` (lui `0x51b1c` + 1, not `addi -0x542`) then npc stuck at `lw@12c0a`; `ra=8` is page0. |
| **I4as Commit: no page0 write to ra; hangpc dumps s0 (2026-08-13)** | I4ar soak-negative. `ra0=8` cannot be a return address (I4an had `ra=1` — the +1 theme). A later `c.jr ra` would fetch page0 (I4t/v will not call that a mispredict). Hangpc already reads live `npc_q`. |
| | **RTL** | `commit_stage.sv`: SMT+SS suppress `we_gpr` to x1 when `result[VLEN-1:12]==0`. `ariane_tb.cpp` hangpc also prints s0 (frame at the `12c0a` lw). SI unchanged. |
| | **Timing** | One extra compare on the existing I4ao we_gpr cone. No new flops. TB print only. |
| | **Soak I4as slfix `bcc15d9a`** | **Hold SUCCESS** (sp0 moved `47f30`→`480e0`; s0=`480f0` healthy fp). **Nat moved.** `ra0=8` **gone** (`ra0=0x80012bc8` = next_node after `jal next_tag`). `npc` left `12c0a` → **`0x800129f0`** `jal fdt_offset_ptr@128e8` inside `fdt_next_tag`. s00=`0x80047c60` (stack, 16B-aligned, 0x70 below sp). Cookie still `51b1c001`. I4as fired. Keep. |
| **I4at Keep `jal`/`jalr` that write ra through bmiss (2026-08-13)** | I4as unblocked `12c0a`. Live fetch is `next_tag` `jal offset_ptr` @`129f0` — a CTRL_FLOW that I4s still younger-cancels. I4n keeps `ld`/`sd` of ra, not the call itself; a cancelled jal is refetched forever (`npc` stuck on the call). |
| | **RTL** | `scoreboard.sv`: also skip SS cancel of CTRL_FLOW `rd==x1`. Sequential + `cancelled_mask`. SI unchanged. |
| | **Timing** | One extra 5-bit compare on the existing cancel cone. No new flops. |
| | **Soak I4at slfix `6113d81e`** | **Hold SUCCESS.** **Nat same as I4as** (`npc=129f0` `jal offset_ptr`, `ra=12bc8`, s0=`47c60`, cookie `51b1c001`). Cancelling the jal is not this hang. Keep (I4n analog for the call, hold-safe). Leftover: `unresolved_cf` sticky, fetch of `offset_ptr@128e8`, or the jal issues but never redirects. |
| **I6 Next** | I4au: `unresolved_cf` not releasing after a committed jal, or frontend not taking `jal offset_ptr@128e8`. Do not blanket-gate x8 issue. Do not cold-`mk` from diag `8169b747`. |

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
