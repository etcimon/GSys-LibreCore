# B1 — RTL / dual-issue residuals

**Scaffold phases:** P1 directed mini → **P2 RTL fix** → P3 osbi peel (see parent `README.md`).
B1 is the **primary long-term home** for residual classes; softs only hold evidence until RTL lands.

Historical promotion order among B1 (from `inventory.yaml` priority):

1. **AMO / spin_lock** (`b1-amo-spin-lock`) — peeled / rtl-fixed path
2. **LR/SC cmpxchg** (`b1-lrsc-cmpxchg`) — peeled
3. **CSR expected-trap** (`b1-csr-expected-trap`) — peeled
4. **FDT lenp store** (`b1-fdt-lenp-store`) — **active**
5. **Dual c.mv** (`b1-dual-cmv-s3`) — peeled

## Investigation map

### AMO / `spin_lock` (priority 1)

| Item | Detail |
|------|--------|
| Soft evidence | NOP `jal spin_lock/unlock` in OpenSBI SA, heap free/used, scratch_used |
| Fail pin | Real lock → `mepc=0x2` / early hang under DI |
| OpenSBI op | `amoadd.w.aqrl` style ticket lock |
| Primary RTL | `core/store_unit.sv`, `core/amo_buffer.sv`, LSU issue coupling |
| Also check | Dual-issue of AMO with following load/store/ALU; commit `amo_valid_commit` |
| Directed test sketch | `amoadd.w` to shared word; pair with independent ALU dual-issue; then two-thread later |
| Retire criterion | Remove all freelist/SA spin NOP4 from `mk_plat_skip.py` |
| **iter-004 fix (in tree)** | Hang-7 younger-cancel + no `flush_ex` on mispredict left cancelled AMO in depth-1 `amo_buffer` forever (`ready_o=0`). Fix: `cancel_i` flush when `cancelled_mask[tid]` and not yet at commit; skip push if already cancelled; AMO issue port-0 only under `SuperscalarEn`. Test: `verif/tests/custom/multicore/mini_amoadd_w_spin.S`. OpenSBI peel still needs lab re-soak. |

### LR/SC / `atomic_cmpxchg` (priority 1)

| Item | Detail |
|------|--------|
| Soft evidence | `atomic_cmpxchg` body = `ld; bne; sd; ret` (cont.50) at `0x800086c0` |
| Fail pin | Real `lr.d`/`sc.d` hang; cookie incomplete (`51b1c001` class) |
| Primary RTL | LSU reservation set, SC fail/success, flush interaction |
| Directed test sketch | LR; non-conflicting dual-issue op; SC success; LR; store; SC fail |
| Retire criterion | Delete soft cmpx shim; OpenSBI uses stock atomics |
| **iter-005 fix (in tree)** | (1) Skip `flush_commit` for `AMO_LR*` so LR does not `flush_ex` the pipe. (2) `lr_sc_pair_q` in issue: after LR until SC, block non-SC STORE so intervening stores cannot clear `axi_riscv_lrsc` exclusive. Helpers `is_amo_lr`/`is_amo_sc`. Test: `mini_lrsc_d.S`. Lab re-soak still required before peeling soft cmpx. |

### CSR expected-trap (priority 2)

| Item | Detail |
|------|--------|
| Soft evidence | After `sbi_hart_init` memset, jump to reinit (skip probes) |
| Fail pin | Illegal CSR dual-issued with `csrw mtvec` → trap handler restored before illegal |
| Primary RTL | CSR pipeline, exception vs following CSR write |
| Directed test sketch | `csrr` illegal; immediately `csrw mtvec, known`; check handler/mcause |
| Retire criterion | Full CSR probe loop in hart_init under DI |
| **iter-006 fix (in tree)** | `issue_stage` `unresolved_csr_q`: after CSR issue, no same-hart younger issue until that CSR `commit_ack` or flush. Test: `mini_csr_expected_trap.S`. |
| **iter-012+ lab (2026-08-11)** | `mini_csr_expected_trap` + **`mini_csr_pmp_probe`** (OpenSBI a3 trap_info + multi pmp) **PASS** on `work-ver-smt2-slfix`. Hold still uses `SOFT_HART_INIT` (OpenSBI full body) + `SOFT_PLAT_OPS` (irqchip/ipi/timer/tlb jalr→FDT). |

### FDT `lenp` / getprop (priority 2 — **active iter-012**)

| Item | Detail |
|------|--------|
| Soft evidence | Soft `fdt_getprop_namelen` + `fdt_get_property_namelen` → NULL; soft printf BANR |
| Fail pin | **Live:** `plat_hc=80` `coldboot_done=0` hart1 `sp1=0` after PEEL cookie (G1df: hart1 `@308`). Historic `129f8/4/9` **gone** (G1dd). G1dg DRAM+grace lift **MINI-FAIL**. Historic `12eb2`/`12b2a` is R2 after `plat_hc==2`. |
| Trapdump | mepc/mcause/mtval/sp/s0/s2/ra: s2==mtval; ra=`0x12e3e`; sp/s0 show intact 48B by_offset_ frame |
| Mechanism (updated) | Dual-commit, STQ-nofwd, force SI issue **all PEEL-negative** (same pin). s2 = check_node→next_tag ra. Not issue dual / dual-commit / STQ-fwd alone. **mtval=`0x12b2a` is the link address of `jal next_tag` inside `check_node`** — s3 ends up holding **ra residue**. |
| Primary RTL | hang-6 family; frontend/`instr_queue`; LSU **byte-load** structure path; scoreboard RF / link write |
| Directed | **Shape minis PASS.** **`mini_fdt_a0_is_fdt`** (`COMPLETION.md` stage 0) — P0–P11 / P9e fail-codes. slfix still P9=19 after G1b; Spike PASS. |
| PEEL pin (authoritative) | **Live:** PEEL `7efc077a` cookie-exit t=22528 `51b1babe`+`51b1d000` (G1dd). `129f8/4/9` gone. Remaining `plat_hc=80` / hart1 down. |
| Probe result | **namelen_ entry OK** (fdt/`lenp` good); **by_offset entry bad** (a0=0, a2=s3=`0x12b2a`). s2/s3 corrupted in `check_node`/`next_tag` window. |
| RTL focus | **g1gi–gm peel** `g6lc_lj_hide` (soaked). OpenSBI 7ba still Branch: leftover 766 after 760 `c.jalr`. TRACE: n7b0 @20430; **n7b8 @20431** a0=1; **n7c0 @20438**; n7ba @20440; hangj 766 @20443; 7ba cmt Branch ra=752 a5=`71c0`. c.jalr skip-arm HOLD-FAIL. **G1mg not next.** P3 PASS @518. P4 PASS @597. skip-range HOLD-FAIL. later_br_01 MINI-FAIL FDT 23 @1184 (G1iz/G1jh). sib8_fetch MINI-FAIL FDT hang @400000 (G1jd) — reverted. hi8_npc_fetch MINI-FAIL lottery 4 @362 (G1ja) FDT 57 @445 (G1jd) — reverted. lo11_npc00 MINI-FAIL sib P0 fail 1 @407 / FDT 0x10 @423 — reverted (jalr-target `[2:1]==11` is not leftover 766). lo_pc_npc00 HOLD-FAIL plat_hc=80 mepc 0xb0/2 — reverted (leftover I$ load-bearing at npc 00 first 8B). ljx0_off / ljx0_pc / ljx0_bp hygiene. sib_lo_s2 MINI-FAIL G1jp — reverted. lo_ld_stay HOLD-FAIL 51b1c001 — reverted. lo_ld_lo11 hygiene. hi8_lo11 MINI-FAIL FDT 57 @445 (G1jd) — reverted. load_flush_next16 hygiene. ld_until_01 MINI-FAIL FDT 106 @409 (G1lm) — reverted. leftover_off_npc00 hygiene. leftover_slot0_off_npc00 MINI-FAIL sib printed 4 @448 / lottery hang @400000 / FDT 17 @413 — reverted. load00_vs_off16 hygiene. leftover_nx8_npc00 hygiene. leftover_hi8_s2 MINI-FAIL FDT 24 @201516 (G1hu) — reverted. load00_vs_lj hygiene. leftover_lo8_s2 hygiene. load00_lo8_s2 hygiene. slfix `2db4dea7` / `f5f908e4`. idle_sib16 / idle_load_sib HOLD-FAIL 51b1c001 (G1jw) — IDLE user[33] into G1hj closed. plus2_stay + line_hi8_stay + stash_keep_pc hygiene (G1hj never captures 7ba; fetch at n7b8 is leftover 766). Off-line leftover-PC replay block kept. leftover_blocks_01 + G1hj consume-PC-match + is_mispredict spare + stash_keep16 + load_flush_keep hygiene. slfix `44c0f9bc` / `67e89a65`. cookie t=83968; hangj 766 is bp_valid leftover jal. G1gd TRACE **flip**: `7ba` cmt @20475, pkt7c0, scratch `@38e0`, BANR; no `@71e4` after `7ba`. G1mf hygiene (SB result-valid 00 LOAD into g1lo; cookie t=83968; 7ba unchanged — last SB 00 LOAD is not 7b0, or 7b0 is not yet sbe.valid). G1me hygiene (g1lo commit capture beats flush_i; cookie t=83968; 7ba unchanged — 7b0 may retire after 7ba is already at ID). G1md hygiene (commit 00 RVI LOAD into g1lo; cookie t=83968; 7ba unchanged — g1lo still does not hold 7b0 at npc 7ba; SMT flush_i skips the capture loop). G1mc hygiene (per-hart G1kk latch; cookie t=83968; 7ba unchanged — g1kk[hart0] still does not hold 7b0 at npc 7ba; per-hart LOAD latches exhausted). G1mb hygiene (per-hart g1le I$ side-stash; cookie t=83968; 7ba unchanged — g1le[hart0] still does not hold 7b0 at npc 7ba). G1ma hygiene (per-hart g1lq IQ latch; cookie t=83968; 7ba unchanged — g1lq[hart0] still does not hold 7b0 at npc 7ba). G1lz hygiene (per-hart g1lo latch; cookie t=83968; 7ba unchanged — hart0 still does not hold 7b0 at npc 7ba). G1ly hygiene (same-line g1lq overwrite of held g1lo; cookie t=83968; 7ba unchanged — g1lq still does not hold 7b0, or g1lo does not hold a same-line LOAD). G1lx hygiene (g1lq overwrite of g1lo_cap gated to empty or fetch 01 line; cookie t=83968; 7ba unchanged — issue/fetch still do not present 7b0 when overwrite is gated). G1lw hygiene (G1kl slot0 from g1lq_hit; cookie t=83968; 7ba unchanged — g1lq_hit not true at npc 7ba, g1lq does not hold 7b0). G1lv hygiene (leftover slot1 g1lq at npc sibling 01; cookie t=83968; 7ba unchanged — leftover 11 not occupying slot0 at npc 7ba, or g1lq does not hold 7b0). G1lu hygiene (registered I$ 00 LOAD into g1lq_cap; cookie t=83968; 7ba unchanged — registered is not 7b0 at npc 7ba). G1lt hygiene (live I$ 00 LOAD into g1lq_cap; cookie t=83968; 7ba unchanged — last I$ LOAD at npc 7ba is not 7b0). G1ls hygiene (present-path instruction_valid 00 LOAD into g1lq_cap; cookie t=83968; 7ba unchanged — 7b0 not instruction_valid at npc 7ba). G1lr hygiene (g1lq keep-until sibling 01; cookie t=83968; 7ba unchanged — first IQ 00 LOAD can block 7b0; 7b0 not g1ct_valid at npc 7ba). G1lq hygiene (IQ-visible 00 LOAD into g1lo_cap; cookie t=83968; 7ba unchanged — last IQ 00 LOAD can overwrite 7b0). G1lp hygiene (g1lo keep-until sibling 01; cookie t=83968; 7ba unchanged — first ID LOAD can block 7b0; j766cmt back @83345). G1lo fired later (ID LOAD latch last-replace; cookie t=83968; 7ba unchanged — later ID LOAD may overwrite 7b0; j766cmt −120 cy). G1ln hygiene (in-ID aligned-00 RVI LOAD arms sibling 01 Branch recover; cookie t=83968; 7ba unchanged — 7b0 not in issue_q when 7ba is at ID). G1lm **MINI-FAIL** (IQ aligned-00 RVI LOAD sibling 01 recover FDT 106 @200619; restore G1ll `93a79414` / `cb4dc600`). G1ll hygiene (G1kl from same-cycle g1le I$/registered cap with npc-line; cookie t=83968; 7ba unchanged — g1ll_cap not true at npc 7ba). G1lk **reverted** (G1kl from no-npc-line g1lj_cap delayed cookie t=206848, 7ba unchanged; restore G1lj `673cd1d8` / `cf66549f`, cookie t=83968). G1lj hygiene (leftover slot1 g1le from same-cycle I$/registered LOAD cap; cookie t=83968; 7ba unchanged — g1le_load/g1li_load not true at npc 7ba). G1li hygiene (registered I$ aligned-00 RVI LOAD into g1le; cookie t=83968; 7ba unchanged — registered is not 7b0 at npc 7ba). G1lh hygiene (present-path aligned-00 RVI LOAD into g1le; cookie t=83968; 7ba unchanged — 7b0 not instruction_valid at npc 7ba). G1lg hygiene (npc-line recapture may replace a held different-line g1le; cookie t=83968; 7ba unchanged — at npc 7ba live I$ is 7c0, not LOAD). G1lf hygiene (g1le keep-until-sibling-01; cookie t=83968; 7ba unchanged — first I$ LOAD still blocks 7b0). G1le hygiene (last I$ LOAD side-stash present at sibling 01; cookie t=83968; 7ba unchanged — last I$ LOAD at npc 7ba is not 7b0). G1ld fired (restore G1ku npc-line on g1kn; cookie t=83968 restored; bit-identical G1la). G1lc hygiene (I$ LOAD recapture only when G1kk is empty; cookie still t=206848 — delay is off-npc empty-latch arm). G1lb fired (I$ LOAD may replace G1kk even when npc is off that line; cookie t=206848 was t=83968; 7ba residual unchanged — later I$ LOAD overwrite). G1la hygiene (G1kl does not skip leftover 11 when G1kk sibling 01 matches; 7ba unchanged — latch/cap still do not match sibling 01 at npc 7ba). G1kz hygiene (G1kl slot0 present from same-cycle I$ LOAD cap; 7ba unchanged — leftover 11 still skips and g1ky_cap is not true at npc 7ba). G1ky hygiene (leftover slot1 G1kk present from same-cycle I$ LOAD cap; 7ba unchanged — g1kn/g1kw not true at npc 7ba). G1kx fired (npc-line LOAD recapture may replace a held different-line LOAD; 7ba window −13 cy vs G1kw, residual unchanged — later npc-line LOAD can replace 7b0 before sibling 01). G1kw hygiene (G1kk from registered I$ aligned-00 RVI LOAD; 7ba unchanged — registered is not 7b0 while npc is on that line). G1kv hygiene (present-path G1kk capture only when npc is on the same 16-byte line; 7ba unchanged — 7b0 not instruction_valid while npc is on that line). G1ku hygiene (G1kk I$ capture only when npc is on the same 16-byte line; 7ba unchanged — present-path still captures any aligned-00 LOAD). G1kt fired (G1kk keep-until-sibling-01; 7ba window back to G1jo @20461, residual unchanged — first LOAD can block 7b0). G1ks fired (G1kk consume only at sibling 01; 7ba window −16 cy, residual unchanged). G1kr hygiene (G1kk survives is_mispredict at npc 00; 7ba unchanged). G1kq hygiene (G1kk survives leftover Jump is_mispredict; 7ba unchanged — leftover Jump not serving between 7b0 and npc 7ba). G1kp hygiene (G1kk capture beats flush_i; 7ba unchanged). G1ko hygiene (G1kk survives leftover Jump flush_i; 7ba unchanged — leftover Jump not serving between 7b0 and npc 7ba). G1kn fired (I$ aligned-00 RVI LOAD into G1kk; 7ba window +3 cy, residual unchanged). G1km hygiene (leftover slot1 G1kk c.jalr at npc sibling 01; 7ba unchanged — `g1kk_v_q` empty). G1kl hygiene (present G1kk c.jalr at npc 01 sibling 8-byte; 7ba unchanged — leftover 11 skips slot0). G1kk hygiene (aligned-00 RVI LOAD rd recovers sibling 01 Branch as c.jalr; 7ba unchanged — no 01 Branch slot at npc 7ba). G1kj hygiene (full sibling +2 PC into G1jy; 7ba unchanged). G1ki **HOLD-FAIL** (I$ sticky user[33]; `[1000]=51b1c001` no BANR @600000; restore G1kh `229c4e51` / `f3d41166`). G1kh hygiene (kill_s2 sibling user[33] into G1jy; 7ba unchanged). G1kg hygiene (kill_s2 same-line pair into G1jy; 7ba unchanged). G1kf hygiene (registered I$ same-line pair into G1jy; 7ba unchanged). G1ke hygiene (same-line IDLE pair into G1jy; 7ba unchanged). G1kd hygiene (G1jy capture without last-return, +2 from current I$ sibling; 7ba unchanged). G1kc hygiene (G1jy leftover slot1 at npc-matched +2; 7ba unchanged). G1kb hygiene (G1hz any compressed slot0-only keeps +2 c.jalr; 7ba unchanged). G1ka hygiene (live user[33] present at last-return +2; 7ba unchanged). G1jz hygiene (IDLE sibling latch +2 PC from last I$ return; 7ba unchanged). G1jy hygiene (IDLE aligned-00 sibling latch present at npc +2 01; 7ba unchanged). G1jx hygiene (IDLE sibling-pair capture at npc==+2; 7ba unchanged — I$ vaddr not 7b0 at npc 7ba). G1jw **HOLD-FAIL** (G1jl capture without valid/kill_s2; `[1000]=800071d8` mcause=4 @600000). G1jv hygiene (G1hj capture beats flush_i; 7ba unchanged). G1ju hygiene (G1hj stash survives leftover Jump flush_i; 7ba unchanged). G1jt hygiene (is_mispredict !kill_s1 at npc 00; 7ba unchanged). G1js **HOLD-FAIL** (same-line flush_i !kill_s1 at npc 00; same pin as G1jr). G1jr **HOLD-FAIL** (all npc-00 flush_i !kill_s1; no cookie @600000 `[1000]=8000f1d0` mcause=4). G1jq hygiene (leftover Jump flush/mispredict !kill_s1 at npc 00; 7ba unchanged — leftover Jump not serving at 7b8). G1jp **MINI-FAIL** (all npc-00 bp_valid !kill_s2; lottery 2 @420, FDT 50 @545). G1jo keep (replay !kill_s1 at npc 00 fired; cookie t=83968; 7ba window −20 cy; residual unchanged). G1jn hygiene (spare kill_s2 when returning I$ is npc-00 same-line compressed Branch; 7ba unchanged — in-flight s2 is previous line). G1jm hygiene (keep registered aligned Branch I$ until +2 presented; 7ba unchanged — 7b8 never registered). G1jl hygiene (sibling pair Branch+[31:16] c.jalr into PC-matched G1hj; 7ba unchanged — pair not on the I$ bus). G1jk hygiene (G1hj +2 stash present only at captured PC; lottery @558 fired; 7ba unchanged). G1jj **MINI-FAIL** (sibling [31:16] exact c.jalr into G1hj; lottery 2 @200615). G1ji hygiene (G1ie from G1iw sibling-half C.BEQZ; lottery @567 fired; 7ba unchanged — sibling not on the bus at 7ba). G1jh **MINI-FAIL** (one-shot different 8-byte I$ at npc 01; FDT 23 @1205 G1iz class). Fetch-steal at npc 01 closed (G1iz/G1jc/G1jg/G1jh). G1jg hygiene (one-shot sequential-next I$ at npc 01; 7ba unchanged — fetch not sequential-next at 01). G1jf **MINI-FAIL** (prev-cycle 00 + 01 Branch commit JumpR; FDT hang @400000). G1je **MINI-FAIL** (in-ID aligned-00 any op; FDT hang @400000). G1jd **MINI-FAIL** (sequential-next 00 I$; FDT 0x39 @2652). G1jc hygiene (one-shot leftover-RVI I$ at npc 01; 7ba unchanged — steal not concurrent with npc 01). G1jb hygiene (recover latch keep-until-01; 7ba unchanged — 7b8 never in stash). G1ja **MINI-FAIL** (aligned-00 npc I$ under predict; lottery 4 @362). G1iz **MINI-FAIL** (I$ vaddr hold at npc 01; FDT 23 @1192). G1iy **MINI-FAIL**. G1ix hygiene (`bp_valid` !kill_s2 at npc 01; 7ba unchanged). G1iw hygiene (same-cycle sibling-half recover; 7ba unchanged). G1iv **MINI-FAIL**. G1iu hygiene (npc-01 same-line I$ `[15:0]` Branch; 7ba unchanged). G1it hygiene (mid-line 01 I$ `[15:0]` Branch; 7ba unchanged). G1is **HOLD-FAIL**. G1ir hygiene (G1ie from G1iq stash; 7ba unchanged — stash not the 7b8 line). G1iq fired on FDT @2719 (7ba unchanged). G1ip hygiene (leftover slot1 I$[15:0]; leftover @20470 after npc 7b8). G1io hygiene (aligned slot0 I$[15:0]). G1in **MINI-FAIL**. G1im **HOLD-FAIL**. G1il hygiene (latch survives flush; never armed). G1ik hygiene (ID aligned-Branch latch; 7b8 never Branch at ID). G1ij hygiene (ID 01 CF follows 16-bit; 7ba bits *are* Branch at ID). G1ii/G1ih hygiene (IQ latch/output). G1ie fired on lottery @571 (7ba unchanged). G1if **HOLD-FAIL**. G1ig **MINI-FAIL**. G1id/G1ic/G1ib/G1ia/G1hz/G1hy/G1hx/G1hw/G1hv/G1ht/G1hs/G1hr/G1hq/G1hp/G1ho/G1hn/G1hm/G1hl/G1hk/G1hj/G1hi/G1hh/G1hg/G1hf/G1hd/G1hc/G1hb/G1ha/G1gy/G1gx/G1gw/G1gu/G1gs/G1gq/G1gp hygiene. G1hu/G1he/G1gz/G1gv/G1gt/G1gr/G1ig/G1in MINI-FAIL. G1go/G1gn/G1if/G1im HOLD-FAIL. G1gm/G1gl/G1gk/G1gj/G1gi/G1gh/G1gg/G1ge hygiene. G1gf HOLD-FAIL. G1ix/G1iw/G1iu/G1it/G1ir/G1iq/G1ip/G1io/G1il/G1ik/G1ij/G1ii/G1ih/G1ie/G1id/G1ic/G1ib/G1ia/G1hz/G1hy/G1hx/G1hw/G1hv/G1ht/G1hs/G1hr/G1hq/G1hp/G1ho/G1hn/G1hm/G1hl/G1hk/G1hj/G1hi/G1hh/G1hg/G1hf/G1hd/G1hc/G1hb/G1ha/G1gy/G1gx/G1gw/G1gu/G1gs/G1gq/G1gp/G1gm/G1gl/G1gk/G1gj/G1gi/G1gh/G1gg/G1ge/G1gd kept. Do not re-land G1ew/G1es/G1eo/G1eh/G1ec/G1eb/G1dr/G1fb/G1fc/G1fk/G1fm/G1fx/G1fz/G1gf/G1gn/G1go/G1gr/G1gt/G1gv/G1gz/G1he/G1hu/G1if/G1ig/G1im/G1in/G1is/G1iv/G1iy/G1iz/G1ja/G1jd/G1je/G1jf/G1jh/G1jj/G1jp/G1jr/G1js/G1jw/G1ki/lo11_npc00/lo_pc_npc00/+8 hold. |
| **RTL landing (iter-012 / I4s–I4cf)** | I4s–I4bl as before; **nat `51b1babe`+`51b1d000`**. **I4bt** PEEL `3e4` **gone**; pin `mepc=0x800129f8` mcause=4 mtval=9. **I4bu/bw–bz/cb–cf** kept (peel unchanged). **I4bv** and **I4ca** reverted. **I4* increments closed** — next is `COMPLETION.md` stage 0. Soft getprop stays. Pin `bc7ed11d…`; peel elf `7efc077a…`. |
| Suite | `soft-ladder-di` (FDT shape in **default** tests); osbi `PEEL_FDT_GETPROP=1` (+ entry probes in oracle) |
| Retire criterion | Natural getprop + real printf cookie green; `plat_hc==2` without soft getprop |

### Dual `c.mv` (priority 3 — **peeled iter-008**)

| Item | Detail |
|------|--------|
| Soft evidence (retired) | Was nop pair @7312/7314; now **natural** by default |
| Fail pin (historic) | `s3` clobber → `ld a2,0(s3)` poison at 7316 |
| Isolate (2026-08-09) | Natural c.mv + soft stub `jal fdt_match` @731e → **cookie green**. PEEL_CMV alone failed mid-`sbi_strlen` because natural a0/a1 *enable* match, not dual-c.mv RF poison. |
| Bare directed | `mini_dual_cmv_s3.S`, `mini_strlen_rvc.S`, `mini_dual_cmv_strlen.S` **PASS** |
| Residual moved to | Soft stub fdt_match / FDT lenp / strlen (`b1-fdt-lenp-store`) |
| Retire criterion | **Met** for dual-c.mv class; `SOFT_CMV=1` bisect only |

### FDT match / `sbi_strlen` (priority 2 — **peeled**)

| Item | Detail |
|------|--------|
| Soft evidence (retired) | Was ret-imm 11; now **natural** with FETCH_WIDTH=64 |
| Fail pin (old) | mepc=`0x4a50` mid-`add` under FETCH_WIDTH=32 |
| RTL | `build_fetch_width` min 64 for DI+RVC |
| Retire criterion | **Met** (`SOFT_STRLEN=1` bisect only) |

### Heap freelist malloc (priority 1 — **peeled iter-010**)

| Item | Detail |
|------|--------|
| Soft evidence (retired) | Was soft malloc/zalloc/free; now **natural** |
| Fail pin (historic) | freelist unlink sd mcause=6 @f0ba under spin-nop dual-hart |
| Isolate (2026-08-09) | PEEL_MALLOC×2 cookie green; `mini_freelist_unlink` PASS |
| Retire criterion | **Met**; `SOFT_MALLOC=1` bisect only |

## Already landed in RTL (do not re-patch via monorepo-soak scripts)

| Landing | Location | Soft-ladder impact |
|---------|----------|-------------------|
| SS dual-issue serialize after CF/ALU/MULT/FPU/LSU | `issue_read_operands.sv` (R3a cont.6/14/15/18) | Partial fix for FDT/lenp/callee-saved; soft printf may still be needed until fully clean |
| Hang-4 realign PC per FIFO word | `instr_queue.sv` | Dual-issue PC integrity |
| Hang-4 completion PC continuity | `instr_queue.sv` pc_j + dual-issue gate | defensive with FETCH_WIDTH=64 |
| DI+RVC FETCH_WIDTH min 64 | `build_config_pkg.sv` `build_fetch_width` | PEEL_STRLEN mid-RVI **fixed** |
| Hang-7 younger cancel (skip LOAD cancel) | `scoreboard.sv` | CF fallthrough recovery |
| Unresolved CF issue stall (per-hart) | `issue_stage.sv` | Blocks issue past unresolved CTRL_FLOW |
| AMOCAS.Q dual_we path | commit/issue/hpdcache/ariane_pkg | Zacas feature (not soft-ladder spin) |
| AMO buffer cancel + AMO port0 | amo_buffer / store_unit / issue | SA spins peelable |
| No flush after LR; LR→SC store barrier | commit / issue_read_operands | cmpxchg LR/SC peelable |
| Unresolved CSR issue stall | issue_stage | CSR probe tail peelable |
| Soft sbi_strlen ret-imm 11 | mk_plat_skip only | Cookie green until PEEL_STRLEN RTL |

## Iteration rule for B1

- Prefer a **bare-metal** directed test that does not depend on OpenSBI once the pin is clear.
- From I4cf onward follow **`COMPLETION.md`**: one mini with fail-codes, then **one generic RTL class** (G0–G4). Do not add I4cg-style register keeps.
- Only then re-run OpenSBI **with that soft site removed**.
- Do not combine two B1 residuals in one RTL change unless they share one mechanism.
- **Do not re-run** monorepo-soak `patch-*.py` for landings above — see `monorepo-soak/APPLIED.md`.
