# Generic completion plan (I4cf onward)

**G0+ is staged after EXTRACT.** Combo extract ladder is in place
(E5→E2+→E6→E7→E8→E4→E4 FE→E9→leftover). Leftover jal-x0 squash
**soaked** (`mini_sib_cjalr` PASS @431). g1gi–gm peel **soaked**.
Current next-action is OpenSBI 7ba still Branch (hangj 766 is leftover
jal **bp_valid**; later_br_01 MINI-FAIL FDT 23; lo11_npc00 MINI-FAIL
sib P0 fail 1 @407 / FDT 0x10 @423 — `[2:1]==11` is jalr-target
shape, not leftover 766; lo_pc_npc00 HOLD-FAIL plat_hc=80 mepc
0xb0/2; ljx0_off / ljx0_pc / ljx0_bp hygiene;
sib_lo_s2 MINI-FAIL G1jp; lo_ld_stay HOLD-FAIL 51b1c001;
lo_ld_lo11 hygiene; hi8_lo11 MINI-FAIL FDT 57 G1jd;
load_flush_next16 hygiene; ld_until_01 MINI-FAIL FDT 106 G1lm;
leftover_off_npc00 hygiene;
leftover_slot0_off_npc00 MINI-FAIL sib 4 / lottery hang / FDT 17;
load00_vs_off16 hygiene; leftover_nx8_npc00 hygiene;
leftover_hi8_s2 MINI-FAIL FDT 24 G1hu;
load00_vs_lj hygiene; leftover_lo8_s2 hygiene;
load00_lo8_s2 hygiene). off-line replay block
**kept**. skip-range latch **HOLD-FAIL**. P3 **PASS @518**. P4 **PASS @597**. hangpc fail4 after mini tohost is sequential past
pass-loop `c.j`. c.jalr skip-arm **HOLD-FAIL**. **g1gi–gm peel soaked.** **jal-x0 squash soaked.** **leftover soaked.** **E9 soaked.** **E4 FE soaked.** **E4 ID/SB soaked.** **E8 soaked.** **E7 soaked.** **E6 soaked.** **E2+ soaked.** **E5 soaked.** **G1mg is not
next.** G1mf hygiene kept (cookie t=83968; 7ba unchanged).
G1mf **kept**. G1me **kept**. G1md **kept**. G1mc **kept**. G1mb **kept**. G1ma **kept**. G1lz **kept**. G1ly **kept**. G1lx **kept**. G1lw **kept**. G1lv **kept**. G1lu **kept**. G1lt **kept**. G1ls **kept**. G1lr **kept**. G1lq **kept**. G1lp **kept**. G1lo **kept**. G1ln **kept**. G1lm **MINI-FAIL**. G1ll **kept**. G1lk **reverted**. G1lj **kept**. G1li **kept**. G1lh **kept**. G1lg **kept**. G1lf **kept**. G1le **kept**. G1ld **kept**. G1lc **kept**. G1lb **kept**. G1la **kept**. G1kz **kept**. G1ky **kept**. G1kx **kept**. G1kw **kept**. G1kv **kept**. G1ku **kept**. G1kt **kept**. G1ks **kept**. G1kr **kept**. G1kq **kept**. G1kp **kept**. G1ko **kept**. G1kn **kept**. G1km **kept**. G1kl **kept**. G1kk **kept**. G1kj **kept**. G1kh
**kept**. G1kg **kept**. G1kf **kept**. G1ke **kept**. G1kd
**kept**. G1kc **kept**. G1kb
**kept**. G1ka **kept**. G1jz
**kept**. G1jy **kept**. G1jx
**kept**. G1jv **kept**. G1ju
**kept**. G1jt **kept**. G1jq
**kept**. G1jo **kept**. G1jn
**kept**. G1jm **kept**. G1lm
**MINI-FAIL**. G1lk
**reverted**. G1ki
**HOLD-FAIL**. G1jw
**HOLD-FAIL**. G1js **HOLD-FAIL**.
G1jr **HOLD-FAIL**. G1jp **MINI-FAIL**.
G1jl **kept**. G1jk **kept**. G1ji
**kept**. G1jg **kept**.
G1jc **kept**. Hangj @20470 is not
the 7ba→71e4 hole. Fetch-steal at
npc 01 is closed (G1iz/G1jc/G1jg/G1jh).
G1jw **HOLD-FAIL**. G1js **HOLD-FAIL**. G1jr **HOLD-FAIL**. G1jp **MINI-FAIL**. G1jh **MINI-FAIL**. G1jf **MINI-FAIL**. G1je **MINI-FAIL**. G1jd **MINI-FAIL**. G1ja **MINI-FAIL**. G1iz **MINI-FAIL**. G1iy **MINI-FAIL**. G1ix **kept**. G1iw **kept**. G1iv **MINI-FAIL**. G1iu **kept**. G1it **kept**. G1is **HOLD-FAIL**. G1ir **kept**. G1iq **kept**. G1ip **kept**. G1io **kept**. G1il **kept**. G1ik **kept**. G1ij **kept**. G1ii **kept**. G1ih **kept**. G1ie **kept**. G1in **MINI-FAIL**. G1im **HOLD-FAIL**. G1ig **MINI-FAIL**. G1if **HOLD-FAIL**. G1id **kept**. G1ic **kept**. G1ib **kept**. G1ia **kept**. G1hz **kept**. G1hy **kept**. G1hx **kept**. G1hw **kept**. G1hv **kept**. G1hu **MINI-FAIL**. G1ht **kept**. G1hs **kept**. G1hr **kept**. G1hq **kept**. G1hp **kept**. G1ho **kept**. G1hn **kept**. G1hm **kept**. G1hl **kept**. G1hk **kept**. G1hj **kept**. G1hi **kept**. G1hh **kept**. G1hg **kept**. G1hf **kept**. G1he **MINI-FAIL**. G1hd **kept**. G1hc **kept**. G1hb **kept**. G1ha **kept**. G1gz **MINI-FAIL**. G1gy **kept**. G1gx **kept**. G1gw **kept**. G1gv **MINI-FAIL**. G1gu **kept**. G1gt **MINI-FAIL**. G1gs **kept**. G1gr **MINI-FAIL**.
G1gq **kept**. G1gp **kept**. G1go **HOLD-FAIL**.
G1gn **HOLD-FAIL**. G1gm **kept**. G1gl **kept**. G1gk **kept**. G1gj **kept**. G1gi **kept**. G1gh **kept**. G1gg **kept**. G1gf **HOLD-FAIL**. G1ge **kept**. G1gd **kept**. G1gc **kept**. G1gb **kept**. G1ga **kept**. G1fz **MINI-FAIL**. G1fy **kept**. G1fx **MINI-FAIL**. G1fw **kept**. G1fv **kept**. G1fu **kept**. G1ft **kept**. G1fs **kept**. G1fr **kept**. G1fq **kept**. G1fp **kept**. G1fo **kept**. G1fn **kept**. G1fm **MINI-FAIL**. G1fl **kept**. G1fk **MINI-FAIL**. G1fj **kept**. G1fi **kept**. G1fh **kept**. G1fg **kept**. G1ff **kept**. G1fe **kept**. G1fd **kept**. G1fc **MINI-FAIL**. G1fb **MINI-FAIL**. G1fa **kept**. G1ez **kept**. G1ey **kept**. G1ex **kept**. G1ew **MINI-FAIL**. G1es **MINI-FAIL**. G1eo **MINI-FAIL**. G1ec **MINI-FAIL**. G1eb **MINI-FAIL**. G1ea **kept**. G1dz **kept**. G1dy **MINI-FAIL**. G1dx **kept**. G1dw **HOLD-FAIL**. G1dv **kept**. G1du **kept**. G1dt **kept**. G1dr
**MINI-FAIL**. G1di **kept**. G1dg **MINI-FAIL**. Soft
getprop stays (`plat_hc=80`).
G1cr **kept** (hygiene). G1cq **kept** (hygiene). G1cp **kept**
(hygiene). G1co **HOLD-FAIL**. G1cn **MINI-FAIL**. G1cm **kept**
(hygiene). G1cl **MINI-FAIL**. G1ck **HOLD-FAIL**. G1cj **HOLD-FAIL**.
G1ci **kept** (hygiene). G1ch **HOLD-FAIL**. G1cg **MINI-FAIL**.
G1cf **MINI-FAIL**. G1ce **HOLD-FAIL**.

Cross-refs: `README.md` (P0–P6, I1–I6) · `CONTRACT.md` (G1 genericity /
least-coupled SMT2) · `ITERATION.md` · `b1-rtl-residuals.md` ·
`inventory.yaml` (`b1-fdt-lenp-store`) · `../fdt-topology-soft-ladder.md` ·
`../smt2-ai-tensor-linux.md` · `AGENTS-todo.md` SL-B…SL-T.

---

## 0. Why the small increments stop here

I4bu–I4cf chased the PEEL pin `c.lw a5,0(a0)@129f8` mcause=4 mtval=9 by adding
one cancel-exempt or one CF flush at a time. That family is exhausted:

| Family | Result |
|--------|--------|
| I4x Jump / I4bz Return / I4ce JumpR `flush_unissued` | Hold+nat green; peel unchanged |
| fdt `c.mv` pairs s1↔a0, s4↔a0, s2↔a0 | Soak-negative; I4cf s5↔a0 is the **last** one-register keep |
| I4bv page-0 data fault | **HOLD-FAIL** — do not re-land |
| I4ca page-0 `c.add a0,a1` commit filter | **HOLD-FAIL** — do not re-land |
| I4by page-0 forward drop, I4cc `waddr==a0 && rd!=a0` | Hold-safe; peel unchanged |
| I4bl mid-block `lui t0` line-start | Required for nat `51b1d000` — do not unwind |

**Pin (authoritative):** PEEL `7efc077a` **cookie-exit** t=22528
`51b1babe`+`51b1d000` (G1dd; `129f8/4/9` **gone**). Remaining:
`plat_hc=80` `coldboot_done=0` `last_hartidx=0` hart1 `sp1=0`. Soft
getprop stays until `plat_hc==2`.

Existing FDT minis stay green because they never produce 9 and then call
`offset_ptr`. Soft getprop stays in pin `bc7ed11d`. SUCCESS remains trapdump
`51b1babe` only.

Do **not** start I4cg or any further `c.mv` / single-opcode keep.

---

## 1. Binding loop (use this instead of I4*)

Same P1→P2→P3 as `README.md`, with a harder I2/I3 contract:

```text
  one directed mini (fail-codes)  →  ONE generic RTL class  →  OpenSBI confirm
         P1 / I2                         P2 / I3                    P3 / I4
```

| Step | Rule |
|------|------|
| **Mini first** | Land a bare test that *can* fail the live pin class. Distinct fail-codes per phase. No OpenSBI soak as the first experiment. |
| **One generic class** | The RTL names a *rule* (pointer liveness, callee-saved window, secondary-hart stack, …), not a register pair or a single OpenSBI VA. Config-gated (`NrHarts>1` / `SuperscalarEn`). SI identity. |
| **Confirm** | Mini green on `work-ver-smt2-slfix` → hold ELF must stay `51b1babe` → then PEEL / nat. Hold-FAIL → revert that class. Soak via `soak.sh` / `soak_common.sh` (`CVA6_COOKIE_EXIT=1`, parallel hold/nat/peel). No testharness checkpoint. Mini-first; soak only after the mini moves, or `SOAK_WHAT=hold` for a hold-safe check. |
| **Negative** | If the mini is green and PEEL does not move, the class is wrong — revert, do not add a second register to the same predicate. |
| **Retire** | Drop the matching `mk_plat_skip` site only after PEEL cookie green. |

This is still **one residual class per increment**. The increment is a *class*,
not a GPR.

---

## 2. Generic RTL classes (catalog)

Land at most one of these per iteration. Prefer the first class the mini
fail-code table actually hits.

### G0 — Pointer liveness (**HOLD-FAIL 2026-08-15 — reverted**)

A GPR used as a **load/store address** must not be a small non-zero
(page-0, FDT offset, tag, `strlen`). Stall the address-use until that GPR is
rewritten with high bits (real pointer) or an explicit 0 (NULL).

| | |
|--|--|
| **Hits** | PEEL `129f8` / `a0=9` (`c.lw` of offset-as-pointer) |
| **Not** | PMA-fault page-0 data (I4bv). Not “filter every `c.add a0`” (I4ca). Not “keep `c.mv sN,a0`”. |
| **Likely site** | `g6lc_issue_barrier` (EXTRACT E1) — not `g6lc_sb_keep`. Do not issue LOAD/STORE `rs1` while that GPR’s last write is page-0 non-zero. |
| **Gate** | SMT+SS only. One flop or scoreboard bit per GPR is too heavy — a single “small-addr” stall on the issue-valid cone is enough. |
| **Mini** | `mini_fdt_a0_is_fdt` (stage 0). |

### G1 — Callee-saved / ABI window (**soaked 2026-08-15**; peel unchanged)

Historic PEEL `sw a0,0(s2)@12eb2` with `s2` = `check_node→next_tag` ra
(`0x12b2a`). s2/s3 clobber inside namelen after entry.

| | |
|--|--|
| **Hits** | R2 after G0 unblocks `offset_ptr` |
| **Not** | Stall *all* younger issue on x8 (I4af HOLD-FAIL). Not another `c.mv s2` keep. |
| **Likely site** | Scoreboard: keep **sp-based** save/restore of `s0–s11`/`ra` through bmiss **as a class** (rs1==x2, rd/rs2 in callee-saved set). Or issue-stall dependents of an in-flight callee-saved write until it commits. |
| **Mini** | Extend the stage-0 mini with a namelen-shaped nest (P8/P9), or a second mini only if G0 is already green and 12eb2 is the new pin. |

### G2 — String / printf walk

BANR cave vs real `sbi_printf`. Same mechanism as G0 (pointer-as-offset) or G1
(callee-saved around `strlen`/format).

| | |
|--|--|
| **Hits** | R3 no-BANR / real printf after natural getprop |
| **Not** | I4bn-style extra STORE rs2 keep. I4bn already hold-safe and BANR is a **path** skip, not a cancel. |
| **Rule** | Reuse G0/G1. New RTL only if the mini fail-code is a *new* class. |

### G3 — Secondary-hart stack / HSM park

Nat/PEEL still show hart1 `_start_warm@32e` / `_wait_for_boot_hart@2e8` with
`sp1=0` while hart0 has a cookie or a later pin.

| | |
|--|--|
| **Hits** | R4 (hart1 `sp=0`) — SMT hygiene, not FDT |
| **Not** | PC-bank rewind (I4av/w HOLD-FAIL). I4u switch-only snap stays. |
| **Likely site** | Do not switch to a hart whose architectural `sp` is still reset-0 unless that hart is in WFI/HSM wait *by design*. Or publish the boot-hart HSM stack before the first switch. RF is already banked — this is scheduling, not another bank. |
| **Mini** | Dual-hart `_start_warm` + HSM park; fail if peer `sp==0` while boot hart has left `_start`. |

### G4 — Domain / switch_mode / leftover expected-trap

`b2-domain-finalize-cut`, `b2-switch-mode-payload`, nat `mepc=ec14`. CSR
minis already PASS; full `sbi_hart_init` still uses hold peels.

| | |
|--|--|
| **Hits** | R5 / B2 after SL-B cookie with natural getprop |
| **Rule** | Mini the *pin* (domain walk, ecall table, `switch_mode` prologue). RTL only if the fail is DI/SMT. Otherwise B2 **source** profile (`README.md` P5) — never a new binary VA. |

### G1b — Callee-saved **copy into a0** (next class)

G1 covered the **stack** window (STORE/LOAD/`addi s*,sp`) but left the
I4bw–cf `c.mv` list as four pairs. `offset_ptr_raw` is `c.mv a0,s0`
(`rd==a0`, `rs2==s0`) — **not** in that list. Mini P11 (two clean peels)
and P9e `0x1f`/`0x20` are green on restored G1; fail stays `0x19` inside
the peel after the a0=9 window.

| | |
|--|--|
| **Hits** | Cancelled `c.mv a0,s*` leaves a0 as 9 / `0x28` (header) → `c.lw` P9 |
| **Not** | Another single pair (I4cg). Not `c.mv s*,a0` (wrong-path would
  clobber the saved pointer). Not leftover-no-switch (W1). Not G0 stall. |
| **Rule** | ALU `!use_imm && rs1==x0 && rd==x10 && callee_saved(rs2)`. |
| **Site** | `g6lc_sb_keep::keep` — replace the four a0↔sN clauses with this
  restore class; keep the existing `c.mv sN,a0` pairs (already soaked). |

### G1c — Callee-saved **copy from a0** (save)

G1b restore is soaked; P9e is still a trap *inside* `offset_ptr_raw`
(grown mini: not 0x1b/0x22). `mv s0,a0` is C.MV `842a` — not in the
four I4bw–cf save pairs.

| | |
|--|--|
| **Hits** | Cancelled `c.mv s0,a0` leaves s0 stale; `c.mv a0,s0` writes page-0 |
| **Not** | One-register I4cg. Not G6 no-switch. |
| **Rule** | ALU `!use_imm && rs1==x0 && callee_saved(rd) && rs2==x10`. |
| **Site** | `g6lc_sb_keep::keep` — replace the four `sN←a0` pairs with this class. |

### G1d — Stack-pointer adjust (`addi sp,sp,*`)

Mini P9e software checks *after* the frame `sd` never fire (still
trap 19), including with hart1 parked. G1 kept `addi s*,sp` and stack
stores, not `addi sp`.

| | |
|--|--|
| **Hits** | Cancelled `addi sp` then `sd ra` to a stale/broken frame |
| **Not** | More `c.mv`. Not G6/W1 no-switch. Not I4cg. |
| **Rule** | ALU `rd==x2 && rs1==x2`. |
| **Site** | `g6lc_sb_keep::keep`. |

### G1e — Arg-file self-add (`c.add a*,rs` / `c.addiw a*`)

Variane prints `(tohost>>1)` **decimal**. Mini `tohost=19` is **P3
`0x13`**, not P9 `0x19` (that would print 25). First `offset_ptr`:
`c.addiw a5,0; c.add a1,a5; c.add a0,a1`. `c.add a0,a1` already kept
(`rd==a0 && rs1==a0`). `c.add a1,a5` was not.

| | |
|--|--|
| **Hits** | Cancelled `c.add a1,a5` leaves a1=0 → `a0=fdt+0` ≠ `fdt+0x28` |
| **Not** | P9. Not more `c.mv`. Not G6. |
| **Rule** | ALU `rd==rs1 && rd∈{x10..x17}`. |
| **Site** | `g6lc_sb_keep::keep`. |

### G1f — Arg ← a0 (`c.mv a5,a0`)

`offset_ptr` is `mv a5,a0` then `c.addiw a5,0; c.add a1,a5`. a5 is
not callee-saved, so G1b/G1c miss it.

| | |
|--|--|
| **Hits** | Cancelled `c.mv a5,a0` leaves a5 stale → P3 `a0≠fdt+0x28` |
| **Not** | Another sN pair (I4cg). Not G6. |
| **Rule** | ALU `!use_imm && rs1==x0 && arg_reg(rd) && rs2==x10`. |
| **Site** | `g6lc_sb_keep::keep`. |

### G1g — All ALU that write a0 (BE assemble)

P3 split: not NULL / `0x28` / `0x50` / page-0 / `fdt`. A third high-bit
pointer — `or a0,t0,t1` cancelled leaves a0=`fdt+8`, then `a5` is a
pointer and `a0=fdt+a5`.

| | |
|--|--|
| **Hits** | Second `load_be32` in `offset_ptr` (P0’s first one commits) |
| **Rule** | ALU `rd==x10`. |
| **Site** | `g6lc_sb_keep::keep`. |

### G1h — Drop boot-base forward on `c.mv a0↔s*`

Leftover tohost `1535148160` = `0x5b808080` = `(a0|1)>>1` ⇒ `a0_lo =
0xB7010100` (BE `B7 01 01 00`). P3 inner split is **`0x32`**: in-frame
2nd `load_be32` ≠ `0x28` while P0’s standalone `load_be32(fdt+8)` is
`0x28` and DRAM at `fdt_blob=0x80001048` is the real blob. `s0` dump
was **`0x80000000`** (`_start`). `c.mv s0,a0` (`842a`) took a forwarded
execute-region base instead of RF `a0=fdt`, so the 2nd load assembled
instruction bytes at `_start+8`.

| | |
|--|--|
| **Hits** | Mini P3 `0x32`; PEEL `a0=9` if `s0` is boot not fdt |
| **Not** | More ALU `rd==a0` keep (G1g). Not G0 stall. Not W1/G6 no-switch. |
| **Rule** | ALU `c.mv` a0↔s*: if forwarded rs2 is a **non-zero execute-region
  base**, use RF. NULL `0` is a legal copy — do not drop. |
| **Site** | `issue_read_operands` (next to I4by), helpers in `g6lc_sb_keep`. |

### G1n — D$ request ID wide enough for the load buffer

Hang-7 set smt2 `NrLoadBufEntries=8` but left `DcacheIdWidth=1`.
`data_id` is `DcacheIdWidth` bits; `ldbuf_windex` is `$clog2(8)=3`.
Truncation aliases rids 0/1; a live slot can retire another request's
line. P4 is the first `c.lw` of `0x80001070` (16 B line, new set).
Server/stream already use width 3.

| | |
|--|--|
| **Hits** | Mini P4 `a5=0x010dfeec` @200649; PEEL `c.lw` of a later FDT line |
| **Not** | G1l free-rid. Not G1m STQ. Not G0/G1i. |
| **Rule** | smt2 `DcacheIdWidth = $clog2(NrLoadBufEntries)` (3). |
| **Site** | `g6lc64_smt2_config_pkg`. SI other pkgs unchanged. |

### G1o — Stall `sd ra` while a jal/jalr `rd==ra` is still issued (**soaked**)

P6 `0x68` passed (slot == RF `ra` at save). `0x65` means RF was
already P5's `0x14c` — the P6 `jal` had left the SB (committed or
cancelled) before `sd ra`. G1o stalls STORE of ra while a same-hart
CTRL_FLOW `rd==ra` is `still_issued`. Combinational; no sticky bit
(not G1i / not `unresolved_link_q`). Mini still `0x65` @956 — the
jal was not in-flight. Hold+nat green. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if jal is still issued at `sd ra` |
| **Not** | D$ fill. Not G0. Not G1i. Not global `unresolved_link_q`. |
| **Rule** | SMT+SS STORE `rs2==ra`: stall while same-hart CTRL_FLOW
  `rd==ra` is `still_issued`. |
| **Site** | `issue_read_operands` operands_available. |

### G1p — Hold EX PC; only capture an acked CF (**soaked**)

`pc_n` defaulted to 0 every non-CF cycle. A jal could retire
`next_pc=4` and I4as would drop `we_gpr` to ra. SMT+SS now holds
`pc_o` and updates only on `valid && ack && CTRL_FLOW`. Mini still
`0x65` @956 — not a zeroed PC. Hold+nat green. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if jal WB used PC=0 |
| **Not** | G1o stall. Not G1i. Not I4as removal. |
| **Rule** | SMT+SS: hold EX PC/BP; capture only an acked CF. SI unchanged. |
| **Site** | `issue_read_operands` ID/EX PC combo. |

### G1q — I4as does not drop CTRL_FLOW `rd==ra` (**soaked**)

P6 jal issued (`0x6a` no). I4as no longer suppresses `we_gpr` to ra
when `fu==CTRL_FLOW` (page-0 J-imm / `next_pc=4`). Mini still `0x65`
@1008 — I4as was not this write. Hold+nat green (cookie-exit t=204800).
PEEL `129f8`/4/9. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if jal result was page-0 |
| **Not** | Never-issued. Not G1i. Not removing I4as for ALU ra=8. |
| **Rule** | SMT+SS: I4as skips CTRL_FLOW. SI unchanged. |
| **Site** | `commit_stage` I4as compare. |

### G1r — Jal link from the issuing instruction PC (**soaked**)

G1o/G1p/G1q no-ops. `branch_unit` `next_pc` used the shared EX `pc_i`.
SMT+SS carries the issuing CF PC in `fu_data.operand_c` and selects
it for `next_pc` / non-JALR `jump_base` / `resolved.pc`. SI identity.
Mini still `0x65` @1008 — not a shared-PC write (`operand_c==0` would
have been `ra=4` / `0x66`). Hold+nat green. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if jal WB used P5's PC |
| **Not** | I4as page-0. Not never-issued. Not G0/W1/G6/G1i. Not G1p hold. |
| **Rule** | SMT+SS: CF PC is the issuing instruction, not a shared EX flop. |
| **Site** | IRO `operand_c` + `g6lc_cf_pc` + `branch_unit`. |

### G1s — Cancelled link-jal still retires `ra` (**soaked**)

G1o–r no-ops. Keep already has `CTRL_FLOW && rd==ra`. SMT+SS commit
still `we_gpr` a dropped jal/jalr when `result[XLEN-1:12]!=0`.
Mini still `0x65` @1008 — the jal was not a cancelled commit with a
usable result (flushed before commit, or never allocated). Hold+nat
green. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if jal sat `commit_drop` with a real link |
| **Not** | Shared EX PC. Not I4as. Not G0/W1/G6/G1i. Not widening keep. |
| **Rule** | A cancelled jal `rd==ra` still retires its link (page-0 stays dropped). |
| **Site** | `commit_stage` drop path, both commit ports. |

### G1t — Link-jal is not unissued fallthrough (**soaked**)

IRO `flush_i` is `flush_unissued`. A jal can be popped (`issue_ack`)
without SB alloc, and `branch_valid_n` cleared, so EX never writes
the link. SMT+SS: `g6lc_sb_keep::alloc` still takes `CTRL_FLOW rd==ra`;
IRO keeps that port's `branch_valid`; barrier records the CF.
Mini still `0x65` @1008 — not this hole (`unresolved_cf` already
serializes a second CF). Hold+nat green. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if jal was popped and not allocated |
| **Not** | Commit-drop. Not G0/W1/G6/G1i. |
| **Rule** | A link-jal that IRO acks is allocated and still goes to EX. |
| **Site** | `g6lc_sb_keep::alloc` + SB + IRO `branch_valid` + barrier. |

### G1u — Flu WB pairs with the branch port (**soaked**)

G1o–t no-ops. I4ak prefers ALU0 over a same-cycle branch. SMT+SS:
`branch_data` is the branch port; `|branch_valid` forces flu
result/tid from it. SI identity (`one_cycle_data`). Mini still
`0x65` @1008 — SS serialize already blocks a second FLU. Hold+nat
green. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if jal WB was stolen |
| **Not** | Alloc race. Not G0/W1/G6/G1i. |
| **Rule** | SMT+SS: `|branch_valid` forces flu result/tid from the branch. |
| **Site** | `ex_stage` `branch_data` + flu mux. |

### G1v — Issue-time jal link in the SB (**soaked**)

G1o–u no-ops. Decode leaves `sbe.result` as the J-imm. SMT+SS alloc
of `CTRL_FLOW rd==ra` stores `pc+ilen` (`g6lc_sb_keep::link`). Flu
may still overwrite. Mini still `0x65` @1008 — flu (or a later write)
replaced the alloc link, or the jal never committed that result.
Hold+nat green. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if the jal committed J-imm / never WBed |
| **Not** | Flu steal. Not G0/W1/G6/G1i. |
| **Rule** | SMT+SS: a link-jal's SB result is `pc+ilen` at alloc. |
| **Site** | Scoreboard alloc of `CTRL_FLOW rd==ra`. |

### G1w — Flu does not replace an alloc-time link (**soaked**)

G1v wrote `pc+ilen` at alloc. SMT+SS flu of a link-jal sets `valid`
but keeps that result when it already has high bits
(`g6lc_sb_keep::keep_alloc_link`). Mini still `0x65` @1008 — the
jal's slot was not a flu WB of a live alloc-time link (never
allocated, or never committed). Hold+nat green. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if flu overwrote `0x2c2` with `0x14c` |
| **Not** | Alloc J-imm. Not G0/W1/G6/G1i. |
| **Rule** | A link-jal's alloc-time `pc+ilen` wins over flu data. |
| **Site** | Scoreboard flu WB of `CTRL_FLOW rd==ra`. |

### G1x — Link-jal is valid at alloc (**soaked**)

G1o–w no-ops. SMT+SS marks `CTRL_FLOW rd==ra` valid at alloc (like
FU NONE) so commit writes the G1v `pc+ilen` without waiting for flu.
EX still resolves. Mini still `0x65` @1008 — that jal was not an
invalid SB slot (never allocated, or fetch followed a prediction
without a jal in the SB). Hold+nat cookie green. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if the jal never became `valid` |
| **Not** | Flu overwrite. Not G0/W1/G6/G1i. |
| **Rule** | A link-jal can retire `pc+ilen` from alloc; EX still resolves. |
| **Site** | Scoreboard alloc of `CTRL_FLOW rd==ra`. |

### G1y — Keep the fetch line until the predicted Jump is in the IQ (**soaked**)

`bp_valid` used to drop `icache_valid_q` while `li t2` + `jal` share
one FETCH block. SMT+SS holds that line until the Jump is consumed
(`g6lc_cf_unissued::keep_line`). Mini still `0x65` @1008 — the jal
is consumed or never presented as Jump on that line. Hold+nat green.
Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if `bp_valid` dropped the jal with `li t2` |
| **Not** | Valid-at-alloc. Not G0/W1/G6/G1i. |
| **Rule** | A predicted Jump stays in the fetch block until the IQ takes it. |
| **Site** | `frontend` `icache_valid_q` kill + `g6lc_cf_unissued::keep_line`. |

### G1z — IQ must not drop an unissued predicted Jump (**NAT-FAIL 2026-08-16 — reverted**)

G1o–y no-ops. Held a presented IQ Jump + decoded `CTRL_FLOW rd==ra`
through `flush_if` (`g6lc_cf_unissued::keep_iq` / `keep_decode`).
Mini still `0x65` @1008 — the jal was not sitting in IQ/ID at
`flush_if`. Hold cookie green. **Nat and PEEL** `51b1c001` /
hart1 `sp=0` — a younger Jump kept across a real mispredict is
wrong-path. Reverted. Do not re-land.

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if IQ flushed the jal |
| **Not** | I$ line kill. Not G0/W1/G6/G1i. Not this keep. |
| **Rule** | An unissued predicted Jump `rd==ra` survives IQ flush. |
| **Site** | `instr_queue` / decode on `flush_if`. |

### G1aa — Leftover JAL holds NPC and leftover (**MINI-FAIL 2026-08-16 — reverted**)

Counted leftover RVI JAL as `jump_unconsumed`, delayed `bp_valid`
NPC, and kept leftover through `kill_s2`. Mini **regressed** to
P3 `0x2f` @590 (`offset_ptr` returned `fdt+8`). Every straddling
jal (not just P6) delayed target fetch. Reverted. Do not re-land.

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if leftover JAL never completed |
| **Not** | G1z. Not G0/W1/G6/G1i. Not I4ac leftover-all. |
| **Rule** | Leftover JAL is an unconsumed Jump. |
| **Site** | `instr_realign` `leftover_jal_o` + `npc_select` + `keep_unaligned`. |

### G1ab — NPC hold only for a presented Jump (**MINI-FAIL 2026-08-16 — reverted**)

`bp_valid` did not steal NPC while G1y `jump_unconsumed`. Mini
**regressed** to P3 `0x38` @545 (`offset_ptr` saw `s0==boot`).
P3 `jal@0x82` is a presented Jump — delaying its target fetch
breaks the call. NPC-delay family closed (G1aa leftover + G1ab
presented). Reverted. Do not re-land.

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if a presented Jump redirected before consume |
| **Not** | Leftover-JAL keep (G1aa). Not G1z. Not G0/W1/G6/G1i. |
| **Rule** | SMT+SS: `keep_npc` on existing `jump_unconsumed` only. |
| **Site** | `frontend` `npc_select`. |

### G1ac — A consumed Jump must still reach ID (**HOLD-FAIL 2026-08-16 — reverted**)

Parked IQ head `cf==Jump` across `bp_valid` (force-pop into a
hold; not `flush_if`). Mini still `0x65` @1008. **Hold** no
cookie @6e6 (`[1000]=80008cb6`, hart1 `mepc=0x8cb6` mcause=4).
Force-pop of an unread Jump is hold-unsafe. Reverted. Do not
re-land. Frontend Jump-keep family closed (G1z/G1aa/G1ab/G1ac).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if IQ pushed the jal and ID never took it |
| **Not** | NPC delay (G1aa/G1ab). Not G1z `flush_if` keep. Not G0/W1/G6/G1i. |
| **Rule** | SMT+SS: IQ output of `cf==Jump` survives `bp_valid` only. |
| **Site** | `frontend` / `instr_queue` on `bp_valid`, not `flush_if`. |

### G1ad — Align the P6 jal so it is not leftover (**landed, still 0x65**)

Frontend keep/park/NPC-delay all failed or no-op. P6 `jal@0x2be`
straddled the `0x2b8` block. Mini-only `.p2align 3` before
`li t2`/`jal`. Jal is a complete Jump in one FETCH block
(`0x2c0`/`0x2c4`). Mini still `0x65` @1021. Leftover is not
the hole (do not re-land G1aa). Batch TRACE: NPC `0x2c0`→`0x2c8`
then `offset_ptr`; `sd ra` with stale `ra`; jal wrote `0x2c8`
later.

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if the jal was a straddling leftover |
| **Not** | RTL. Not G1aa leftover keep. Not G0/W1/G6/G1i/G1z/G1ac. |
| **Rule** | Directed: one aligned P6 jal, same fail-codes. |
| **Site** | `mini_fdt_a0_is_fdt.S` P6 window only. |

### G1ae — Stall `sd ra` while a cancelled link-jal is still in the SB (**soaked**)

G1o uses `still_issued` (`issued & ~cancelled`). SMT+SS: G1o also
matches `sbe.valid` (cancel sets valid). Mini still `0x65` @1021
(same cycle count — jal was not a live SB slot at `sd`). Hold
cookie-exit t=202752 `51b1babe`+`51b1d000` BANR. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if `sd ra` raced a cancelled jal commit |
| **Not** | Unissued ID/IQ. Not G0/W1/G6/G1i/G1z/G1aa/G1ab/G1ac. |
| **Rule** | STORE `rs2==ra` waits for a live same-hart link-jal, cancelled or not. |
| **Site** | `issue_read_operands` G1o loop (`still_issued \|\| sbe.valid`). |

### G1af — Spec STQ does not forward (**HOLD-FAIL 2026-08-16 — reverted**)

SMT+SS forwarded only from the commit queue. Mini still `0x65`
@1021 (same cy — `0x68` was not spec-fwd). **Hold** `51b1c001`
@1000, no cookie @6e6, hart1 `8df0`/4 `sp1=0x10`. Extra
interlock starved the cave `addi`. Reverted. Do not re-land.
Not full STQ-nofwd (already peel-negative).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` after `0x68` passed |
| **Not** | This keep. Not G0/W1/G6/G1i/G1z. |
| **Rule** | A younger load waits until a spec store is committed. |
| **Site** | `store_buffer` `st_fwd_merge`. |

### G1ag — Stall `sd ra` while an older link-jal is still in ID (**soaked**)

G1ae only sees the SB. SMT+SS: do not issue STORE `rs2==ra`
while a same-hart `CTRL_FLOW rd==ra` is a valid ID head with
`pc < store.pc`. Mini still `0x65` @1021 (jal not in ID at
`sd`). Hold cookie-exit t=202752. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if jal is in ID when `sd ra` issues |
| **Not** | Spec STQ nofwd (G1af). Not G0/W1/G6/G1i/G1z/G1aa/G1ab/G1ac. |
| **Rule** | STORE `rs2==ra` waits for an unissued older same-hart link-jal in ID. |
| **Site** | `g6lc_issue_barrier` on `decoded_instr`. |

### G1ah — Forwarded spec store must still drain (**soaked**)

TRACE: `sp` is `0x80007ff0` from `0x68` through hang (same slot).
SMT+SS: a spec STQ entry that forwarded to a live load is
`fwd_keep` and survives cancel/flush. Mini still `0x65` @1021
(same cy — squash-after-fwd was not this hole). Hold cookie
t=202752. Keep (hygiene). Not G1af.

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if `0x68` forwarded a store that was then dropped |
| **Not** | All spec nofwd (G1af). Not G0/W1/G6/G1i. |
| **Rule** | A spec store that a load already forwarded from still drains. |
| **Site** | `store_buffer` `fwd_keep`. |

### G1ai — `sd ra` must use the post-`addi` `sp` (**soaked**)

IRO stalls STORE `rs2==ra` while a same-hart `addi sp` is
`still_issued`/`sbe.valid` or on an earlier port. Mini still
`0x65` @1021 (same cy — `addi` was not in the SB at `sd`).
TRACE still shows NPC at `sd` with `sp=0x80008000` (fetch, not
issue). Hold cookie t=202752. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if `sd ra` used the pre-`addi` frame |
| **Not** | G1ah `fwd_keep`. Not G1af. Not G0/W1/G6/G1i. |
| **Rule** | STORE of `ra` waits for the frame `addi sp`. |
| **Site** | IRO, `addi_sp` vs STORE `rs2==ra`. |

### G1aj — LOAD of `ra` waits for any STORE of `ra` (**HOLD-FAIL 2026-08-16 — reverted**)

Stalled every `LOAD rd==ra` while any same-hart `STORE rs2==ra`
was in the SB. Mini still `0x65` @1021 (store already left the
SB). **Hold** `51b1c001` @1000, no cookie @6e6, hart1 `8df0`/4
`sp1=0x10`. Nested OpenSBI frames starved the cave `addi`.
Reverted. Do not re-land. Not G1af.

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if epi `ld ra` raced a live `sd ra` |
| **Not** | This keep. Not G0/W1/G6/G1i. |
| **Rule** | LOAD of `ra` waits for a same-hart STORE of `ra`. |
| **Site** | IRO, STORE `rs2==ra` vs LOAD `rd==ra`. |

### G1ak — LOAD of `ra` waits only for an older STORE of `ra` (**HOLD-FAIL 2026-08-16 — reverted**)

G1ag-style `pc < load.pc` did not save the hold. Mini still
`0x65` @1021 (store already left the SB). **Hold**
`51b1c001` @1000, no cookie @6e6, hart1 `8df0`/4 `sp1=0x10`.
Same class as G1aj: older prologue `sd ra` blocked every
younger `ld ra` and starved the cave `addi`. Reverted.
LOAD-ra-waits-STORE-ra family closed. Do not re-land.

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if epi `ld ra` raced *that* frame's `sd ra` |
| **Not** | This keep. Not G1aj. Not G1af. Not G0/W1/G6/G1i. |
| **Rule** | LOAD of `ra` waits for an older same-hart STORE of `ra`. |
| **Site** | IRO, `sbe.pc < load.pc`. |

### G1al — STORE of `ra` waits for an older ID `addi sp` (**soaked 2026-08-16**)

G1ai missed ID. Mirror G1ag. Mini still `0x65` @1021 (same TRACE:
t=877 `sd` NPC `sp=0x80008000`; `addi` not an ID head at issue —
`c.addi16sp`/`c.sdsp` are a 4-byte pair). **Hold** cookie-exit
t=202752 `51b1babe`+`51b1d000`. Keep (hygiene). Not G1aj/G1ak.

| | |
|--|--|
| **Hits** | Mini P6 `0x65` if `sd ra` issued with pre-`addi` `sp` still in ID |
| **Not** | SB `addi` stall (G1ai). Not G1aj/G1ak. Not G1af. |
| **Rule** | STORE of `ra` waits for an older same-hart `addi sp` in ID. |
| **Site** | `g6lc_issue_barrier`, G1ag-style `pc < store.pc`. |

### G1am — Mini: second load of the `sd ra` slot (**landed 2026-08-16**)

After `0x68` (`ld t1,8(sp)` == RF `ra`), `ld t3,8(sp)` must
equal `t1`. **Mini `0x69` @953** (Spike PASS). TRACE: t=925
`t1=0x2c8`; t=931 `beq t3,t1` still `t3=0xed` (stale
`load_be32` byte). Hang `ra0=0x2c8` (never reached epi).
`0x68` is a false memory pass — `t1` matched `ra`, `t3` never
wrote. Isolated P4 stays. Keep the check.

| | |
|--|--|
| **Hits** | P6 `0x69` — two loads of `8(sp)` disagree |
| **Not** | D$ fill. Not G1af/G1aj/G1ak. |
| **Rule** | Two loads of `8(sp)` must agree; `t1==ra` is not enough. |
| **Site** | `mini_fdt_a0_is_fdt.S` P6 only. Isolated P4 stays. |

### G1an — LOAD dest must reach RF before the use (**soaked 2026-08-16**)

IRO stalls a use on a cancelled-valid same-hart LOAD of that
rs (raw_checker only sees `still_issued`). Commit writes a
cancelled LOAD dest (G1s analog). Mini still **`0x69` @953**
(same TRACE / same cy) — `ld t3` was not a cancelled-valid
SB slot. **Hold** cookie-exit t=202752. Keep (hygiene).

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `ld t3` dest was cancelled-valid |
| **Not** | D$ fill. Not G1af/G1aj/G1ak. |
| **Rule** | A cancelled-valid LOAD dest must reach RF before a use. |
| **Site** | IRO + `commit_stage` drop path. |

### G1ao — STQ forwards the same slot to every live load (**soaked 2026-08-16**)

Replay the last live STQ forward to the next same-PA load
after the store drains. Mini still **`0x69` @953** (same TRACE /
same cy) — `ld t3` never presented as `load_paddr_valid`.
**Hold** cookie-exit t=202752. Keep (hygiene). Not G1af.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if the 2nd `8(sp)` load misses a drained STQ |
| **Not** | D$ fill. Not G1af (all spec nofwd). Not G1aj/G1ak. |
| **Rule** | A spec store forwards to every matching live load. |
| **Site** | `store_buffer` last-forward hold. |

### G1ap — second same-address LOAD must reach the LSU (**MINI-HANG 2026-08-16 — reverted**)

`lsu_bypass` `ready_o = (status_cnt < 2)` under SMT+SS. Mini
burned **400000** cy, tohost=0 (harness false SUCCESS). 2-deep
LSU ready deadlocked. Reverted. Do not re-land.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if the 2nd `ld 8(sp)` was blocked by empty-only ready |
| **Not** | This keep. Not D$ fill. Not G1af/G1ao. |
| **Rule** | Two LOADs of the same address both reach the LSU. |
| **Site** | `lsu_bypass` ready. Isolated P4 stays. |

### G1aq — keep I$ line for older NoCF before a Branch (**soaked 2026-08-16**)

G1y is Jump only. G1aq also keeps while an unconsumed `NoCF`
sits before a `Branch` on the same line. Mini still **`0x69`
@953** (same cy). **Hold** cookie-exit t=202752. Keep (hygiene).
Not G1z/aa/ab/ac/G1ap.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `bp_valid` dropped `c.ldsp` before IQ |
| **Not** | 2-deep LSU ready (G1ap). Not D$ fill. Not G1af. |
| **Rule** | A presented LOAD dest is issued before a same-line use. |
| **Site** | `g6lc_cf_unissued::keep_line` + frontend. Isolated P4 stays. |

### G1ar — TRACE: does `c.ldsp t3` ever write RF? (**landed 2026-08-16**)

Poison `li t3,-1` before `ld t3`. Mini **`0x69` @954**. NPC
`0x4d0` is `c.li t3,-1`; `t3` stayed `0xed` through hang
`ra0=0x2c8`. `t3` *does* write earlier (`lbu t3` → `0xed`/`0x28`/`0x48`).
The `0x4d0` 16-bit prefix never retired. Keep the poison. Isolated P4 stays.

| | |
|--|--|
| **Hits** | P6 `0x69` — `t3` never left `0xed` after `li t3,-1` |
| **Not** | D$ fill. Not G1ap. Not G1af. |
| **Rule** | A `c.ldsp t3` RF write must be visible before `beq t3,t1`. |
| **Site** | mini + `log gpr gpr=t3,t1`. Isolated P4 stays. |

### G1as — leftover-RVI must not eat the next line's first 16-bit (**HOLD-FAIL 2026-08-16 — reverted**)

I4ae any-later leftover complete restricted to the immediately next
8B line. Mini still **`0x69` @953** (`t3` stayed `0xed`). Hold
`plat_hc=80` at bootrom `0x10050` / mepc `0x80000062` mcause=4 — I4ae
trap-tail leftover needs any-later complete. Not leftover-JAL keep
(G1aa). Do not re-land.

| | |
|--|--|
| **Hits** | Hold cold-regress `plat_hc=80`; mini still `0x69` |
| **Not** | G1aa leftover-JAL. Not G1ap. Not D$ fill. |
| **Rule** | A completed leftover must leave the next line's slot0 valid. |
| **Site** | `instr_realign` 64-bit leftover complete. Isolated P4 stays. |

### G1at — fetched `c.li t3` at `0x4d0` must issue/retire (**HOLD-FAIL 2026-08-16 — reverted**)

G1t analog: `flush_unissued` still allocates ALU `li` of a temp
and retires the decode imm. Mini still **`0x69` @954** (`t3` stayed
`0xed` — `c.li` never reached ID). Hold **wfi-exit** t=215040
`[1000]=80007204` mcause=6; hart1 `sp=0` mepc `0x2f2`/4. Wrong-path
temp `li` committed. Do not re-land.

| | |
|--|--|
| **Hits** | Hold wfi-exit `7204`/6; mini still `0x69` |
| **Not** | G1as leftover complete. Not G1aa. Not G1ap. Not D$ fill. |
| **Rule** | A fetched ALU dest at `0x4d0` is visible before `c.ldsp`/`beq`. |
| **Site** | `g6lc_sb_keep::alloc` + SB + commit. Isolated P4 stays. |

### G1au — IQ must present the fetched `0x4d0` 16-bit (**landed 2026-08-16**)

`keep_line` also holds leftover-RVI complete (`serving_unaligned`
slot0 unconsumed). Mini still **`0x69` @954** (`t3` stayed `0xed`).
Hold cookie t=202752 `51b1babe`+`51b1d000` BANR. Keep (hygiene).
Not leftover-complete address (G1as). Not leftover-JAL (G1aa).

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `c.li` is fetched but never enters IQ |
| **Not** | G1at alloc. Not G1as. Not G1aa. Not G1ap. Not D$ fill. |
| **Rule** | A leftover-RVI complete slot0 stays presented until IQ takes it. |
| **Site** | `g6lc_cf_unissued::keep_line` + frontend. Isolated P4 stays. |

### G1av — leftover complete only from the next line; keep leftover (**landed 2026-08-16**)

I4ae any-later complete restricted to the next 8B line; leftover
stays pending on every other fetch (G1as **dropped** it → `plat_hc=80`).
Mini still **`0x69` @954** (`t3` stayed `0xed`). Hold cookie t=202752
`51b1babe`+`51b1d000` BANR. Keep (hygiene). Leftover family closed
as the mini hole (`0x4c8` is already next-line). Not G1aa. SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `0x4d0` slot0 is leftover tail, not `c.li` |
| **Not** | G1as leftover drop. Not G1aa. Not G1at. Not G1ap. Not D$ fill. |
| **Rule** | A non-next-line fetch presents slot0; leftover stays pending. |
| **Site** | `instr_realign` 64-bit leftover complete. Isolated P4 stays. |

### G1aw — `serving_unaligned` only while leftover is completing (**landed 2026-08-16**)

`serving_unaligned_o` is `leftover_next_line`, not pending
`leftover_rvi`. Mini still **`0x69` @954** (`t3` stayed `0xed`).
Hold cookie t=202752 `51b1babe`+`51b1d000` BANR. Keep (hygiene).
Leftover-frontend family closed as the mini hole. Not G1as. Not G1aa.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if stale leftover flags `0x4d0` slot0 as unaligned |
| **Not** | G1as drop leftover. Not G1aa. Not G1at. Not G1ap. Not D$ fill. |
| **Rule** | `serving_unaligned` is 1 only when leftover is assembled this beat. |
| **Site** | `instr_realign` `serving_unaligned_o`. Isolated P4 stays. |

### G1ax — leftover-RVI Branch must not stall the taken-target prefix (**HOLD-FAIL 2026-08-16 — reverted**)

Do not arm `unresolved_cf` for a 32-bit no-link CF at `pc[2:1]==11`.
Mini still **`0x69` @953**. Hold **`plat_hc=80`** mepc `0x2cc8`/6,
hart1 `sp=0`, no cookie @6e6. Fallthrough after leftover Branch.
Do not re-land. Not G1i. Not G1at.

| | |
|--|--|
| **Hits** | Hold cold-regress `plat_hc=80`; mini still `0x69` |
| **Not** | G1i unresolved_a0. Not G1at alloc. Not G1as. Not G1ap. Not D$ fill. |
| **Rule** | A leftover-RVI Branch does not stall the taken-target first 16-bit. |
| **Site** | `g6lc_issue_barrier` `unresolved_cf`. Isolated P4 stays. |

### G1ay — issue older NoCF before a same-line predicted-taken Branch (**landed 2026-08-16**)

Stall a Branch at issue while an older same-hart ALU/LOAD dest is
still in ID or on another issue port, same 8B line. Mini still
**`0x69` @954** (`t3` stayed `0xed` — `c.li` never shared ID with
`beq`). Hold cookie t=202752 `51b1babe`+`51b1d000` BANR. Keep
(hygiene). Not G1ax. Not G1i. SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `beq@0x4d4` issues before `c.li` |
| **Not** | G1ax unresolved_cf skip. Not G1i. Not G1aq keep_line. Not G1ap. |
| **Rule** | A same-line Branch waits for an older unissued NoCF dest. |
| **Site** | `g6lc_issue_barrier` ID stall. Isolated P4 stays. |

### G1az — IQ must push slot0 of a new 8B line after leftover complete (**landed 2026-08-16**)

If the dest FIFO for an aligned line's slot0 is full, push nothing
and replay from `addr_i[0]` (not `addr_i[shamt]`). Mini still
**`0x69` @954** (`t3` stayed `0xed`). Hold cookie t=202752
`51b1babe`+`51b1d000` BANR. Keep (hygiene). Not G1aa. Not G1as.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `0x4d0` is fetched but IQ slot0 is empty |
| **Not** | G1ay ID stall. Not G1ax. Not G1as. Not G1aa. Not G1ap. |
| **Rule** | A new 8B line after leftover complete presents slot0 as valid. |
| **Site** | `instr_queue` push / replay. Isolated P4 stays. |

### G1ba — presented `c.li t3` must decode as ALU rd=x28 (**landed 2026-08-16**)

Leftover-RVI mash `{c.li_hi, branch_lo}` presents as 32-bit RVI
(`[1:0]==11`). Recover the high 16 as `c.li` when SMT+SS, the low
opcode is BRANCH, and the high half is C1 li. Identity `OpcodeC1Li`
already expands a presented `5e7d`. Mini still **`0x69` @952**
(`t3` stayed `0xed`; mash never presented). Hold cookie t=202752
`51b1babe`+`51b1d000` BANR. Keep (hygiene). Not G1az. Not G1at.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `c.li` is queued as leftover mash |
| **Not** | G1az IQ replay. Not G1at. Not G1as. Not G1ap. Not D$ fill. |
| **Rule** | A leftover mash of `c.li` over a Branch low half expands to ALU `rd==x28`. |
| **Site** | `compressed_decoder` default RVI path. Isolated P4 stays. |

### G1bb — hold registered I$ data while `keep_line` (**HOLD-FAIL 2026-08-16 — reverted**)

G1aq keeps `icache_valid_q` but still accepted the next I$ beat.
Freeze data/vaddr while `keep_line` so `0x4d0` is not overwritten
by taken-target `0x4e0`. Mini still **`0x69` @949** (same TRACE).
Hold **FAIL** `plat_hc=80` mepc `0x80012640` mcause=2; hart1
`sp=0`; no cookie @6e6. Freezing a stuck `keep_line` starved
OpenSBI fetch. Do not re-land. Not G1ab NPC hold. Not G1ac.

| | |
|--|--|
| **Hits** | Hold `plat_hc=80` `0x12640`/2; mini still `0x69` |
| **Not** | G1ba mash. Not G1at. Not G1aq keep-valid. Not D$ fill. |
| **Rule** | A kept line's data stays until IQ consumes the prefix. |
| **Site** | `frontend` I$ register. Isolated P4 stays. |

### G1bc — skip empty IQ head to present pushed slot0 (**landed 2026-08-16**)

Leftover complete rotates `idx_is`; slot0 (`c.li@0x4d0`) can sit
in a later FIFO while `idx_ds` names an empty head. Skip empty
heads only (do not present a later slot under the empty head —
hang-4). Mini still **`0x69` @952** (`t3` stayed `0xed`). Hold
cookie t=202752 `51b1babe`+`51b1d000` BANR. Keep (hygiene).
Not G1ac. Not G1az. Not G1bb.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `c.li` is pushed but head FIFO is empty |
| **Not** | G1bb I$ hold. Not G1at. Not G1ac. Not G1az. Not D$ fill. |
| **Rule** | An occupied later FIFO is the head when the named head is empty. |
| **Site** | `instr_queue` `idx_ds`. Isolated P4 stays. |

### G1bd — replay leftover-RVI taken target if slot0 missing (**HOLD-FAIL 2026-08-16 — reverted**)

When leftover-RVI taken CF pops and the next IQ head is not the
predict target, replay that target (one-shot). Mini still
**`0x69` @953**. Hold **FAIL** no cookie @6e6; mepc `0x800007b0`
mcause=4; hart1 `sp=0`; `plat_hc=2` `coldboot_done=0`. Replay
starved OpenSBI fetch. Do not re-land. Not G1ab. Not G1bb.

| | |
|--|--|
| **Hits** | Hold mepc `0x7b0`/4 no cookie; mini still `0x69` |
| **Not** | G1bc head skip. Not G1bb hold. Not G1ab NPC hold. Not D$ fill. |
| **Rule** | Leftover-RVI taken target slot0 is fetched into IQ. |
| **Site** | `instr_queue` replay. Isolated P4 stays. |

### G1be — ID must take fetched `0x4d0` `c.li` before same-line Branch (**landed 2026-08-16**)

If ID[0] is a Branch and fetch[0] is an older same-line NoCF dest,
insert the prefix at port 0 and shift the Branch to port 1 (port 1
must be empty). Mini still **`0x69` @952** (`t3` stayed `0xed`;
insert did not fire). Hold cookie t=202752 `51b1babe`+`51b1d000`
BANR. Keep (hygiene). Not G1ay. Not G1bd. Not G1at.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `c.li` is on fetch[0] and ID already holds `beq` |
| **Not** | G1bd replay. Not G1bb hold. Not G1at alloc. Not G1ac. Not D$ fill. |
| **Rule** | A same-line NoCF prefix is older than the Branch in ID. |
| **Site** | `id_stage` prefix fill. Isolated P4 stays. |

### G1bf — leftover-pending aligned slot0 is the 16-bit at `address_i` (**landed 2026-08-16**)

If leftover-RVI is pending and this fetch is not the next-line
complete, present slot0 as `{16'b0, data[15:0]}` at `address_i`
(`c.li@0x4d0`). Leftover stays (not G1as). Mini still **`0x69`
@952**. Hold cookie t=202752 `51b1babe`+`51b1d000` BANR. Keep
(hygiene). Not G1bb. Not G1bd.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover mash hid `c.li` as slot0 |
| **Not** | G1as leftover drop. Not G1bb hold. Not G1bd replay. Not D$ fill. |
| **Rule** | A leftover-pending aligned line presents slot0 as the 16-bit. |
| **Site** | `instr_realign` 64-bit override. Isolated P4 stays. |

### G1bg — same-line NoCF dest must retire across later Branch mispredict (**landed 2026-08-16**)

NPC visits `0x4d0`; `t3` stays `0xed`. Fetch/IQ/ID presentation
family did not write `t3`. `keep_prefix` never fired (`c.li` never
allocated). Mini still **`0x69` @952**. Hold cookie t=202752
`51b1babe`+`51b1d000` BANR. Keep (hygiene). Not G1at alloc.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `c.li` issues and is cancelled by `beq@0x4d4` |
| **Not** | G1at alloc-on-flush. Not G1bf slot0. Not G1bd. Not D$ fill. |
| **Rule** | An older same-line ALU/LOAD dest is not cancelled by that Branch. |
| **Site** | `g6lc_sb_keep` cancel keep. Isolated P4 stays. |

### G1bh — issue older same-line NoCF dest through `unresolved_cf` (**landed 2026-08-16**)

G1ay stalls a Branch only while the prefix is in ID or another
issue port (never fired). G1bg keeps it only after it allocates.
If `beq` already issued, `unresolved_cf` then blocks the older
same-line `c.li`. Mini still **`0x69` @952**. Hold cookie t=202752
`51b1babe`+`51b1d000` BANR. Keep (hygiene — `c.li` never at issue).
Not G1ax. Not G1ab/G1bb. SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `c.li` is at issue behind `unresolved_cf` |
| **Not** | G1ax leftover skip. Not G1ab NPC hold. Not G1bb data freeze. Not D$ fill. |
| **Rule** | An older same-line ALU/LOAD dest may issue while that Branch is unresolved. |
| **Site** | `g6lc_issue_barrier` + `keep_prefix`. Isolated P4 stays. |

### G1bi — IQ must deliver aligned slot0 NoCF dest to ID before same-line Branch consume (**HOLD-FAIL 2026-08-16 — reverted**)

Hold Branch as IQ head and rotate `idx_ds` to an older same-line
NoCF dest. Mini still **`0x69` @952** (never in another FIFO).
Hold: **wfi-exit** t=217088 cookie **`51b1c001`** (cave lui, no
`51b1babe`) mepc `0xb5c8`/4 BANR `plat_hc=2`. Holding OpenSBI
same-line `li`+`beq` starved the success cave. **Do not re-land.**
Not G1ab. Not G1bb. Not G1az/G1bc.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if slot0 `c.li` is dropped when later-slot `beq` is consumed |
| **Not** | G1ab NPC hold. Not G1bb freeze. Not G1az dest-full. Not D$ fill. |
| **Rule** | An aligned line’s slot0 NoCF dest must reach ID before that line’s Branch is consumed. |
| **Site** | `instr_queue` consume/push. Isolated P4 stays. |

### G1bj — aligned slot0 CF class is the 16-bit at that PC (**landed 2026-08-16**)

G1bi never saw `c.li` in a later FIFO. `c.li` is not pushed.
Leftover-RVI mash can tag slot0 as Branch so `branch_mask` hides
the 16-bit. Mini still **`0x69` @952**. Hold cookie t=202752
`51b1babe`+`51b1d000` BANR. Keep (hygiene — mash never presented).
Not G1ba. Not G1bf. Not G1bi. SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if slot0 `c.li` is classed as leftover Branch |
| **Not** | G1bi IQ rotate. Not G1ba mash decode. Not G1bb. Not D$ fill. |
| **Rule** | An aligned slot0’s CF type follows the 16-bit at that PC. |
| **Site** | `frontend` `is_branch[0]`. Isolated P4 stays. |

### G1bk — first valid beat must push aligned slot0 NoCF before `bp_valid` overwrite (**HOLD-FAIL 2026-08-16 — reverted**)

Push aligned slot0 NoCF even when `address_overflow` blocks the
later-slot Branch. Mini still **`0x69` @952**. Hold: **no
`[cookie-exit]`** (soak ran past t=202752 with no cookie). Pushing
slot0 while dropping the Branch predict address desynced OpenSBI
fetch. **Do not re-land.** Not G1az. Not G1bb. Not G1bi.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if slot0 is valid one beat and never consumed |
| **Not** | G1ab NPC hold. Not G1bb data freeze. Not G1bi IQ rotate. Not D$ fill. |
| **Rule** | An aligned slot0 NoCF dest is consumed on the first valid beat. |
| **Site** | `instr_queue` ready/push. Isolated P4 stays. |

### G1bl — do not accept a different-line I$ return while aligned slot0 NoCF is unconsumed (**landed 2026-08-16**)

`keep_line` keeps valid; the else-path still overwrites data/vaddr
with the `bp_valid` target (`0x4e0`). G1bb froze *all* data for
*all* `keep_line` — HOLD-FAIL. This class only rejects a
**different 8B line** while slot0 NoCF is valid and unconsumed.
Mini still **`0x69` @952**. Hold cookie t=202752 `51b1babe`+`51b1d000`
BANR. Keep (hygiene — slot0 not valid+unconsumed on the overwrite
beat). Not G1ab. Not G1bk. SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if the 0x4d0 beat is overwritten before IQ consume |
| **Not** | G1bb all-data freeze. Not G1ab NPC hold. Not G1bk overflow push. Not D$ fill. |
| **Rule** | A registered aligned slot0 NoCF dest is not overwritten by another line. |
| **Site** | `frontend` I$ register. Isolated P4 stays. |

### G1bm — IQ `consumed_o[0]` is architectural slot0 (**landed 2026-08-16**)

G1bl did not fire: either `valid[0]` was 0 or `consumed[0]` was
already 1. `consumed_o` is rotated `push_instr_fifo`; a later-slot
push can mark slot0 consumed. Mini still **`0x69` @952**. Hold
cookie t=202752 `51b1babe`+`51b1d000` BANR. Keep (hygiene — rotate
already matched dest-FIFO). Not G1az. Not G1bk. SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `consumed[0]` is 1 while slot0 was not pushed |
| **Not** | G1bk overflow push. Not G1az dest-full. Not G1bb. Not D$ fill. |
| **Rule** | `consumed_o[0]` of an aligned line is the slot0 push only. |
| **Site** | `instr_queue` consume rotate. Isolated P4 stays. |

### G1bn — IQ flush on `bp_valid` must keep a just-pushed aligned slot0 NoCF dest (**MINI-FAIL 2026-08-16 — reverted**)

Kept the dest FIFO that just received aligned slot0 NoCF across
`flush_i`. Mini **regressed** to P3 **`0x2a` @588** (`offset_ptr`
returned 0). Isolated P4 must stay. Wrong-path slot0 survived a
real flush (G1z family). **Do not re-land.** Not G1z (all Jump).

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `c.li` is pushed then flushed with the taken Branch |
| **Not** | G1z IQ Jump keep. Not G1at alloc. Not G1bi rotate. Not D$ fill. |
| **Rule** | A just-pushed aligned slot0 NoCF dest survives `bp_valid` IQ flush. |
| **Site** | `instr_queue` flush. Isolated P4 stays. |

### G1bo — aligned slot0 NoCF must be valid on the registered I$ beat (**MINI-FAIL 2026-08-16 — reverted**)

Widened G1bf to every aligned compressed slot0 and skipped
leftover-complete when `data[15:0]` was compressed. Mini
**regressed** to P1 **`0x10` @384** (first `load_be32`). Isolated
P4 must stay. **Do not re-land.** Not G1bf (leftover-only stays).

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if realign `valid_o[0]` is 0 at `0x4d0` |
| **Not** | G1bn flush keep. Not G1bf slot0 format. Not G1bb. Not D$ fill. |
| **Rule** | An aligned leftover-pending line presents slot0 as valid NoCF. |
| **Site** | `instr_realign` valid_o[0]. Isolated P4 stays. |

### G1bp — `keep_line`/`G1bl` prefix is any aligned NoCF dest slot (**hygiene 2026-08-16**)

G1bl required `valid[0]` && `addr[0][2:1]==00`. Leftover complete
puts the Branch in slot0; `c.li` may be a later slot. Mini still
`0x69` @952; TRACE still `0x4d0`→`0x4e0`; `t3` stayed `0xed`.
Hold cookie t=202752. Did not fire (0x4d0 never registered).
Keep. Not G1bo. Not G1bb. SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `c.li` is a later slot on the registered line |
| **Not** | G1bo realign widen. Not G1bb freeze. Not G1bn. Not D$ fill. |
| **Rule** | An aligned NoCF dest in any slot holds the line until consumed. |
| **Site** | `frontend` `g1bl_hold_line`. Isolated P4 stays. |

### G1bq — leftover-RVI complete must not `kill_s2` the taken-target fetch (**HOLD-FAIL 2026-08-16 — reverted**)

Masked `kill_s2` on `serving_unaligned`. Mini still `0x69` @960
(TRACE still `0x4d0`→`0x4e0`, `t3`=`0xed`). Hold **no
`[cookie-exit]`** past 90s (same class as G1bk). Reverted.
Do not re-land. Not G1aa/G1ab NPC. Not G1bb.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `0x4d0` fetch is killed before I$ valid |
| **Not** | G1aa NPC delay. Not G1ab NPC hold. Not G1bb freeze. Not D$ fill. |
| **Rule** | Leftover-complete beat (`serving_unaligned`) does not kill_s2. |
| **Site** | `frontend` `kill_s2`. Isolated P4 stays. |

### G1br — later-slot Branch is not predicted while older same-line NoCF dest is unconsumed (**HOLD-FAIL 2026-08-16 — reverted**)

Gated `is_branch[i]` from `instr_queue_consumed`. Mini still
`0x69` @952. Hold **non-converge** (`Active region did not
converge`, rc=255) — combo loop `is_branch` → IQ consume →
`g1br`. Reverted. Do not re-land consumed in the `is_branch`
cone. Not G1bj. Not G1bq. Not G1ab.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `beq@0x4d4` redirects before `c.li` queues |
| **Not** | G1bj mash class. Not G1bq kill_s2. Not G1ab NPC. Not D$ fill. |
| **Rule** | A later-slot Branch does not set `is_branch` until prefix is consumed. |
| **Site** | `frontend` `is_branch`. Isolated P4 stays. |

### G1bs — later-slot Branch is not predicted while older same-line NoCF dest is valid (**HOLD-FAIL 2026-08-16 — reverted**)

Gated `is_branch` from valid dest (no `consumed`). Mini still
`0x69` @952 (TRACE still `0x4d0`→`0x4e0`). Hold **no
`[cookie-exit]`** past 90s — too wide (any dest then Branch
suppresses OpenSBI taken predicts). Reverted. Do not re-land.
Later-slot `is_branch` family closed (G1br combo / G1bs wide).
Not G1br. Not G1bq. Not G1ab.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `c.li` is consumed the same beat `beq` predicts |
| **Not** | G1br consumed. Not G1bq kill_s2. Not G1ab NPC. Not D$ fill. |
| **Rule** | A later-slot Branch does not set `is_branch` while an older dest is valid. |
| **Site** | `frontend` `is_branch`. Isolated P4 stays. |

### G1bt — leftover taken Branch to the next 8B line must not `kill_s2` that fetch (**HOLD-FAIL 2026-08-16 — reverted**)

Spared `kill_s2` only when leftover-complete slot0 is a taken
Branch and `predict_address` is the next FETCH_WIDTH line.
Mini still `0x69` @952 (TRACE still `0x4d0`→`0x4e0`). Hold
**no `[cookie-exit]`** past 90s (same class as G1bq). Reverted.
Leftover `kill_s2` family closed (G1bq all / G1bt next-line).
Do not re-land. Not G1aa/G1ab NPC.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover `beq@0x4c6` kills the `0x4d0` fetch |
| **Not** | G1bq all leftover. Not G1aa/G1ab NPC. Not G1bs `is_branch`. Not D$ fill. |
| **Rule** | Leftover-complete taken Branch to the next 8B line does not kill_s2. |
| **Site** | `frontend` `kill_s2`. Isolated P4 stays. |

### G1bu — after leftover-complete taken Branch, reject I$ returns that are not the target line (**HOLD-FAIL 2026-08-16 — reverted**)

Armed a wait flop on leftover-complete taken Branch and
rejected non-target I$ returns. Mini still `0x69` @952
(TRACE still `0x4d0`→`0x4e0`). Hold **no `[cookie-exit]`**
past 90s (starved OpenSBI fetch, G1bb class). Reverted.
Do not re-land. I$ hold/barrier family closed (G1bb/G1bu).

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `0x4e0` registers before `0x4d0` |
| **Not** | G1bb freeze. Not G1bq/G1bt kill_s2. Not G1ab NPC. Not D$ fill. |
| **Rule** | Leftover-complete taken-target fetch completes before another line. |
| **Site** | `frontend` I$ register. Isolated P4 stays. |

### G1bv — stash leftover-Branch target I$ return (**hygiene 2026-08-16**)

Side-buffer the target-line I$ return and present it after
the leftover line drops. Mini still `0x69` @952; TRACE still
`0x4d0`→`0x4e0`; `t3` stayed `0xed`. Hold cookie t=202752.
Did not fire (`0x4d0` return never valid — `kill_s2`). Keep.
Not G1bb/G1bu. Not G1bq/G1bt. Not G1bk/G1bn/G1bi. SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `0x4d0` returns but registered line moved |
| **Not** | G1bb freeze. Not G1bu reject. Not G1bq/G1bt kill_s2. Not D$ fill. |
| **Rule** | Leftover-Branch target I$ return is presented even if overwritten. |
| **Site** | `frontend` realign mux. Isolated P4 stays. |

### G1bw — spare `kill_s2` only if s2 is the leftover-Branch target (**HOLD-FAIL 2026-08-16 — reverted**)

Spared `bp_valid` `kill_s2` when the in-flight s2 vaddr
matched the leftover-Branch target (`g1bv` wait/arm). Mini
still `0x69` @952 (TRACE still `0x4d0`→`0x4e0`). Hold **no
`[cookie-exit]`** past 90s. Reverted. Leftover `kill_s2`
family closed (G1bq all / G1bt next-line / G1bw s2==tgt).
Do not re-land. Not G1ab NPC.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `0x4d0` s2 is killed |
| **Not** | G1bq all leftover. Not G1bt next-line Branch. Not G1bu. Not D$ fill. |
| **Rule** | A leftover-Branch taken-target request completes s2. |
| **Site** | `frontend` I$ request/kill. Isolated P4 stays. |

### G1bx — leftover-complete Branch to the next 8B line does not raise `bp_valid` (**hygiene 2026-08-16**)

Sequential already fetches that target. Mini still `0x69`
@952; TRACE still `0x4d0`→`0x4e0`; `t3` stayed `0xed`. Hold
cookie t=98304 (earlier than 202752). Did not fire on the
mini hole (redirect is later `beq@0x4d4`). Keep. `kill_s2`
formula unchanged. Not G1ab. Not G1br. SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover `beq@0x4c6` `bp_valid` kills `0x4d0` |
| **Not** | G1bq/G1bt/G1bw kill_s2. Not G1ab NPC. Not G1br. Not D$ fill. |
| **Rule** | Leftover-complete taken Branch to the next line is not `bp_valid`. |
| **Site** | `frontend` `bp_valid`. Isolated P4 stays. |

### G1by — later-slot Branch does not raise `bp_valid` while older same-line dest is valid (**HOLD-FAIL 2026-08-16 — reverted**)

Kept `is_branch`/`cf_type`; cleared only `bp_valid`. Mini
still `0x69` @952. Hold **wfi-exit** t=217088 `plat_hc=80`
no cookie (store fault `mepc=0x13128`/6). Too wide (any
dest-then-Branch). Reverted. Do not re-land. Later-slot
`bp_valid`/`is_branch` family closed (G1br/G1bs/G1by).

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `beq@0x4d4` redirects before `c.li` queues |
| **Not** | G1br consumed. Not G1bs `is_branch`. Not G1bx leftover. Not D$ fill. |
| **Rule** | A later-slot Branch is not `bp_valid` while an older dest is valid. |
| **Site** | `frontend` `bp_valid`. Isolated P4 stays. |

### G1bz — leftover-complete later-slot CF does not raise `bp_valid` (**MINI-FAIL 2026-08-16 — reverted**)

`bp_valid` OR-reduce skipped `i!=0` while
`serving_unaligned` (leftover slot0 only). Intended to
stop leftover-line `c.j@0x4ce` from `kill_s2` of `0x4d0`.
Mini **P3 `0x39` @437** (`s0!=a0` after `c.mv s0,a0`).
Spike PASS. Too wide: leftover later-slot Jump is live in
P3 (`load_be32` / first `offset_ptr`). Reverted. Lab
restored G1bx `f39da849` / `5b5486d8` bit-identical.
Do not re-land. Leftover later-slot CF `bp_valid` family
closed with G1by (any-line later-slot Branch).

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover `c.j` kills `0x4d0` |
| **Not** | G1by any-line later-slot Branch. Not G1bx leftover Branch-to-next-line. Not G1bq kill_s2. Not D$ fill. |
| **Rule** | Leftover-complete later-slot CF is not `bp_valid`. |
| **Site** | `frontend` `bp_valid` OR-reduce. Isolated P4 stays. |

### G1ca — prefix hold is dest-before-Branch only (**hygiene 2026-08-16**)

Dropped G1bp's any-slot OR (`seen_branch && dest`).
Prefix is only dest older than Branch (in-loop
`seen_noncf`). Leftover-complete Branch then `li s11`
is not a prefix (that `g1bl`-rejected `0x4d0`). Mini
still `0x69` @952; TRACE still `0x4d0`→`0x4e0`; `t3`
stayed `0xed`. Hold cookie t=98304. Did not fire
(`0x4d0` never registered). Keep. Not G1bz later-slot
CF. Not G1bu. SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover dest-after-Branch `g1bl` rejected `0x4d0` |
| **Not** | G1bz leftover later-slot CF. Not G1by any-line Branch. Not G1bu barrier. Not D$ fill. |
| **Rule** | Prefix hold is dest *before* Branch. Dest after leftover Branch is not prefix. |
| **Site** | `frontend` `prefix_unconsumed`. Isolated P4 stays. |

### G1cb — leftover-complete later-slot Jump is not `jump_unconsumed` (**hygiene 2026-08-16**)

G1y keep skipped for `i!=0` while `serving_unaligned`.
After G1ca, leftover `c.j@0x4ce` was the only keep on
that line. `bp_valid` stays (not G1bz). Mini still
`0x69` @952; TRACE still `0x4d0`→`0x4e0`; `t3` stayed
`0xed`. Hold cookie t=98304. Did not fire (`0x4d0`
never registered). Keep. SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover `c.j` keep blocked `0x4d0` |
| **Not** | G1bz leftover later-slot `bp_valid`. Not G1y aligned jal. Not G1bu. Not D$ fill. |
| **Rule** | Leftover-complete later-slot Jump is not a keep_line reason. |
| **Site** | `frontend` `jump_unconsumed`. Isolated P4 stays. |

### G1cc — do not +8 NPC while leftover-Branch target is outstanding (**hygiene 2026-08-16**)

`g1bv_wait` and target not yet presented (`g1bv_use_stash`
or registered vaddr). Classic analog of FTQ cf-hold, only
for leftover-Branch target. Mini still `0x69` @952; TRACE
still `0x4d0`→`0x4e0`; `t3` stayed `0xed`. Hold cookie
t=98304. Did not fire (`g1bv_wait` not armed — leftover
beq static NT). Keep. Not G1ab/G1bu/G1bq. SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `0x4c8`→`0x4d0`→`0x4e0` skips the `0x4d0` fill |
| **Not** | G1ab Jump NPC. Not G1bu reject. Not G1bq kill_s2. Not D$ fill. |
| **Rule** | Leftover-Branch taken-target fetch is presented before sequential +8. |
| **Site** | `frontend` `npc_select`. Isolated P4 stays. |

### G1cd — hold NPC on leftover-Branch arm beat (`g1bv_arm`) (**HOLD-FAIL 2026-08-16 — reverted**)

G1cc wait flop is one cycle late; leftover-taken already
+8'd `0x4d0`→`0x4e0`. Held on combinational `g1bv_arm`.
Mini still `0x69` @952 (TRACE still `0x4d0`→`0x4e0` —
leftover beq static NT). Hold **no `[cookie-exit]`** past
6 min (starved OpenSBI fetch). Reverted. Lab restored
G1cc `113a844b` / `14047394` bit-identical. Do not re-land.
Same-cycle leftover-Branch NPC hold closed.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if arm-beat +8 skips `0x4d0` |
| **Not** | G1cc wait-only (kept). Not G1ab. Not G1bu. Not D$ fill. |
| **Rule** | Leftover-Branch target hold is armed the complete beat. |
| **Site** | `frontend` `g1cc_hold_tgt`. Isolated P4 stays. |

### G1ce — one-cycle +8 stall on leftover-complete (`serving_unaligned`) (**HOLD-FAIL 2026-08-16 — reverted**)

Leftover beq is static NT so `g1bv_arm`/G1cc never fire.
Stalled sequential NPC one cycle while leftover-complete
is presented. Mini still `0x69` @963 (TRACE first pass
`0x4c8`→`0x4e0`, skipped `0x4d0`; `t3` stayed `0xed`).
Hold **no `[cookie-exit]`** past 3 min (starved OpenSBI,
G1cd class). Reverted. Lab restored G1cc `113a844b` /
`14047394` bit-identical. Do not re-land. Leftover-complete
NPC +8 stall family closed (G1cd arm / G1ce complete).

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover-complete beat +8 skips `0x4d0` |
| **Not** | G1cd arm+wait. Not G1cc wait-only. Not G1ab. Not D$ fill. |
| **Rule** | Leftover-complete beat does not sequential-step NPC. |
| **Site** | `frontend` `npc_select`. Isolated P4 stays. |

### G1cf — one-cycle I$ re-request of leftover-complete next line (**MINI-FAIL 2026-08-16 — reverted**)

Overrode `icache_dreq.vaddr` (not NPC) for one cycle to
fill leftover-next (`0x4d0`) into the G1bv stash. Mini
**P1 `0x10` @406** (first `load_be32` — leftover-complete
in header walk stole the next fetch). Spike PASS. Reverted.
Lab restored G1cc `113a844b` / `14047394` bit-identical.
Do not re-land. Leftover-next I$ vaddr override closed.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover-next I$ is never requested |
| **Not** | G1cd/G1ce NPC stall. Not G1bu barrier. Not D$ fill. |
| **Rule** | Leftover-complete next line is fetched without moving NPC. |
| **Site** | `frontend` I$ `vaddr`. Isolated P4 stays. |

### G1cg — leftover-complete consume restarts IQ `idx_is` (**MINI-FAIL 2026-08-16 — reverted**)

After leftover slot0 (`addr[2:1]==11`) is consumed,
`idx_is` reset to 0 so the next aligned line's slot0
is FIFO 0. Mini **P1 `0x10` @384** (first `load_be32` —
leftover-complete in header walk desynced FIFOs). Spike
PASS. Reverted. Lab restored G1cc `113a844b` / `14047394`
bit-identical. Do not re-land. Not G1bi hold-Branch.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover rotate puts `beq@0x4d4` before `c.li` |
| **Not** | G1bi hold-Branch. Not G1cf I$ vaddr. Not D$ fill. |
| **Rule** | Leftover-complete consume restarts IQ fill rotation. |
| **Site** | `instr_queue` `idx_is_d`. Isolated P4 stays. |

### G1ch — leftover-complete Branch-only IQ `idx_is` restart (**HOLD-FAIL 2026-08-16 — reverted**)

G1cg was every leftover-complete (broke `load_be32`).
G1ch reset `idx_is` only when leftover slot0 is Branch.
Mini still `0x69` @952 (leftover beq static NT —
`cf!=Branch`, did not fire). Hold **no `[cookie-exit]`**
past 3 min (OpenSBI leftover-Branch desynced FIFOs).
Reverted. Lab restored G1cc `113a844b` / `14047394`
bit-identical. Do not re-land. Leftover `idx_is` restart
family closed (G1cg all / G1ch Branch).

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover-Branch rotate puts `beq@0x4d4` before `c.li` |
| **Not** | G1cg all leftover. Not G1bi hold-Branch. Not D$ fill. |
| **Rule** | Leftover-complete Branch consume restarts IQ fill rotation. |
| **Site** | `instr_queue` `idx_is_d`. Isolated P4 stays. |

### G1ci — leftover-complete later-slot Jump !bp_valid while slot0 unconsumed (**hygiene 2026-08-16**)

G1bz zeroed every leftover later-slot CF (P3 `0x39`).
G1ci only drops later-slot **Jump** `bp_valid` while leftover
slot0 is still unconsumed. After `consumed[0]`, later Jump
may predict (P3 `load_be32`). Mini still `0x69` @952; TRACE
still `0x4d0`→`0x4e0` (sequential +8, not `c.j`→fail);
`t3` stayed `0xed`. Hold cookie t=98304. Did not move the
hole (`0x4d0`→`0x4e0` is `if_ready` +8). Keep. Not
G1by/G1cb/G1br. Not G1bz (all CF). SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover later-slot `c.j` kills `0x4d0` |
| **Not** | G1bz all leftover later-slot CF. Not G1by aligned dest. Not D$ fill. |
| **Rule** | Leftover-complete later-slot Jump predicts only after slot0 is in the IQ. |
| **Site** | `frontend` `bp_valid`. Isolated P4 stays. |

### G1cj — leftover-complete sequential-next I$ stash, no NPC hold (**HOLD-FAIL 2026-08-16 — reverted**)

Stashed leftover-complete NoCF sequential-next I$
return without `g1bv_wait`. Mini still `0x69` @952
(did not fire — `0x4d0` return never valid). Hold
**wfi-exit t=217088** `plat_hc=80` `coldboot_done=0`
mepc `0x129b0`/2. Replayed sequential after leftover
in OpenSBI. Reverted. Do not re-land. Leftover
sequential-next stash family closed (G1bv wait-only
stays). Isolated P4 stays.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `0x4d0` I$ return is valid but never presented |
| **Not** | G1bv leftover-Branch wait. Not G1cd/G1ce NPC stall. Not D$ fill. |
| **Rule** | Leftover-complete NoCF sequential-next I$ return is presented after the leftover line drops. |
| **Site** | `frontend` G1bv stash fill. Isolated P4 stays. |

### G1ck — do not +8 off leftover-NoCF sequential next (**HOLD-FAIL 2026-08-16 — reverted**)

Held +8 only when leftover-complete slot0 is NoCF and
NPC is already the next 8B line. Mini still `0x69` @964
(fired; +12 cy). Hold **no `[cookie-exit]`** past 10 min
(G1ce class starve). Reverted. Do not re-land.
Leftover-complete NPC stall family closed (G1cd arm /
G1ce all leftover / G1ck leftover-NoCF next). Isolated
P4 stays.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `0x4d0` I$ is replaced by `0x4e0` same window |
| **Not** | G1ce all leftover +8. Not G1cj stash. Not D$ fill. |
| **Rule** | Leftover-complete NoCF sequential-next fetch is not abandoned for +8 on the complete beat. |
| **Site** | `frontend` `npc_select`. Isolated P4 stays. |

### G1cl — leftover-complete later slots after leftover-RVI Branch not presented (**MINI-FAIL 2026-08-16 — reverted**)

Hid leftover-complete later slots when slot0 is RVI
Branch. Mini **P1 `0x11` @442** (P1 leftover-Branch
fallthrough is live in the header walk). Spike PASS.
Reverted. Do not re-land. Isolated P4 stays.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover later-slot `c.j` steals `0x4d0` |
| **Not** | G1bz all leftover later-slot CF `bp_valid`. Not G1bo. Not D$ fill. |
| **Rule** | Leftover-complete later slots after a leftover-RVI Branch are not issued. |
| **Site** | `instr_realign` leftover_next_line. Isolated P4 stays. |

### G1cm — leftover-complete later-slot Jump not presented (**hygiene 2026-08-16**)

G1cl hid every leftover-Branch later slot (P1 `0x11`).
G1cm drops only later-slot `c.j` / `jal`; later ALU
stays. Mini still `0x69` @949 (P1 green; −3 cy). Hold
cookie t=83968 `51b1babe`+`51b1d000` BANR `plat_hc=2`.
Did not present `0x4d0` / write `c.li`. Keep. Not G1cl
all slots. Not G1bz. SMT+SS.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover later-slot `c.j` steals `0x4d0` |
| **Not** | G1cl all later slots. Not G1bz. Not D$ fill. |
| **Rule** | Leftover-complete later-slot Jump after a leftover-RVI Branch is not issued. |
| **Site** | `instr_realign` leftover_next_line. Isolated P4 stays. |

### G1cn — one-cycle I$ req suppress after leftover-NoCF sequential next (**MINI-FAIL 2026-08-16 — reverted**)

Suppressed I$ req one cycle after leftover-complete
NoCF with NPC already at the next 8B. Mini **P1 `0x10`
@386** (first `load_be32` leftover-complete in header
walk, G1cf class). Spike PASS. Reverted. Do not re-land.
Leftover-complete I$ req suppress closed. Isolated P4
stays.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if `0x4e0` request replaces `0x4d0` in s2 |
| **Not** | G1ck NPC hold. Not G1ce. Not D$ fill. |
| **Rule** | Leftover-complete NoCF sequential-next I$ is not replaced by +16 on the next beat. |
| **Site** | `frontend` `icache_dreq.req`. Isolated P4 stays. |

### G1co — leftover-complete next-line RVI Branch is cf=Branch (**HOLD-FAIL 2026-08-16 — reverted**)

Classified leftover-complete RVI Branch to next 8B as
`cf=Branch` without taken/predict. Mini still `0x69`
@940 (P1 green). Hold **no `[cookie-exit]`** past 10 min
(`unresolved_cf` on leftover NT beq). Reverted. Do not
re-land. Isolated P4 stays.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover NT `beq` never resolves as Branch |
| **Not** | G1bx taken-to-next `!bp_valid`. Not G1cd. Not D$ fill. |
| **Rule** | Leftover-complete RVI Branch to the next 8B line is a Branch in the IQ. |
| **Site** | `frontend` `cf_type`. Isolated P4 stays. |

### G1cp — aligned NoCF dest holds different-line I$ without later Branch (**hygiene 2026-08-16**)

Second pass `0x4d0`→`0x4d8` is sequential +8.
`beq@0x4d4` is static NT so `prefix=0`. Hold aligned
unconsumed NoCF dest without a later Branch. Leftover
still dest-before-Branch (G1ca). Mini still `0x69` @949
(did not fire — `0x4d0` never registered). Hold cookie
t=83968. Keep. Not G1bp leftover any-slot. Not G1by.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if second-pass `0x4d0` is overwritten before `c.li` queues |
| **Not** | G1ca leftover dest-after-Branch. Not G1bb freeze. Not D$ fill. |
| **Rule** | An aligned unconsumed NoCF dest is not overwritten by a different 8B I$ return. |
| **Site** | `frontend` `g1bl_hold_line`. Isolated P4 stays. |

### G1cq — leftover-complete NoCF does not replay-kill I$ s1 (**landed 2026-08-16**)

IQ overflow on leftover later slots (`li s11`) asserts
`replay` → `kill_s1`/`kill_s2` and cancels in-flight
`0x4d0`. Mask only the replay bit of `kill_s1` while
leftover-complete slot0 is NoCF. NPC still reseeds.
Mini still **`0x69` @949** (did not fire — replay is
not the mini hole). Hold cookie t=79872. Keep.
Not G1bq `!kill_s2`. Not G1cn req suppress. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover IQ overflow kills the `0x4d0` fill |
| **Not** | G1bq leftover `!kill_s2`. Not G1cn. Not D$ fill. |
| **Rule** | Leftover-complete NoCF IQ replay does not cancel the sequential-next I$ request. |
| **Site** | `frontend` `kill_s1`. Isolated P4 stays. |

### G1cr — mispredict to the registered I$ line does not drop it (**landed 2026-08-16**)

TRACE G1cq: first pass `0x4d0`→`0x4e0` (BHT taken
`beq@0x4d4`); replay `0x4c4`; third visit t=920
`0x4d0` with `t1==ra`, then `0x4d8`, `t3` stayed
`0xed`. Leftover `beq@0x4c6` resolves taken after
G1cp already held `0x4d0`; `flush_if`/`is_mispredict`
drops that line before IQ takes `c.li`. Keep the
registered line when the mispredict target is this
same 8B-aligned line. IQ still flushes. Mini still
**`0x69` @949** (did not fire — `0x4d0` was not
registered at the resolve). Hold cookie t=79872.
Keep. Not G1bb freeze. Not G1bd replay. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if leftover taken resolve kills a live `0x4d0` |
| **Not** | G1bb freeze. Not G1bd replay. Not leftover `kill_s2`. Not D$ fill. |
| **Rule** | A line-aligned mispredict target that is already the registered I$ line stays presented. |
| **Site** | `frontend` `icache_valid_q`. Isolated P4 stays. |

### G1cs — do not +8 NPC until a line-aligned mispredict target is presented (**landed 2026-08-16**)

G1cr did not fire: t=920 `0x4d0` is a reseed after
`flush_if`, not a live registered line. `if_ready`
then +8 to `0x4d8` before the `0x4d0` fill returns.
Registered wait (not G1cd arm-cycle). Hold sequential
step until that target line is presented. Mini still
**`0x69` @970** (fired; +21 cy). TRACE: t=932 `0x4d0`
`t1=ra` held to t=940 `0x4d8`; `t3` stayed `0xed` —
line presented, `c.li` still never writes. Hold cookie
t=75776. Keep. Not G1cc leftover-Branch wait. Not
G1cd/G1ce/G1ck leftover NPC stall. Isolated P4 stays.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if mispredict reseed +8 skips the `0x4d0` fill |
| **Not** | G1cc leftover-Branch wait. Not leftover NPC stall. Not D$ fill. |
| **Rule** | After a line-aligned mispredict, do not sequential-step NPC until that line is presented. |
| **Site** | `frontend` `npc_select`. Isolated P4 stays. |

### G1ct — presented mispredict-target first beat is dest-only to IQ (**landed 2026-08-16**)

G1cs presented `0x4d0` for one cycle then +8; later-slot
`beq@0x4d4` shared that packet so `c.li` never wrote.
Hide later IQ valids on the first `g1cs_wait` beat of
that line. **P6 `0x69` closed.** Mini now **P8 `0x18`**
@2446 (`s1/s2/s4/s5` survive `check_node` nest). Hold
cookie t=96256 (`plat_hc=80` last_hartidx=`7f` — classify
is cookie-exit only). Keep. Not G1cl leftover later
slots. Not G1cm leftover Jump. Isolated P4 stays.

| | |
|--|--|
| **Hits** | Mini P6 `0x69` if later-slot Branch shares the one-cycle target packet |
| **Not** | G1cl leftover later slots. Not G1cm leftover Jump. Not D$ fill. |
| **Rule** | First presented beat of a line-aligned mispredict target is dest-only to IQ. |
| **Site** | `frontend` IQ `valid_i` mask. Isolated P4 stays. |

### G1cu — leftover-complete slot0 Jump arms G1cc +8 hold (**MINI-FAIL 2026-08-16 — reverted**)

P8 TRACE: `jal check_node_like@0x3f6` leftover-RVI;
NPC `0x3ea`→`0x400` in 9 cy. Armed G1bv/G1cc on
leftover slot0 Jump. Mini still **P8 `0x18` @200727**
(sticky +8 starve). Reverted. Do not re-land (G1aa /
leftover NPC stall). Isolated P4 stays.

| | |
|--|--|
| **Hits** | Mini P8 `0x18` if leftover `jal` sequential +8 skips the callee |
| **Not** | G1aa leftover-JAL NPC. Not G1ct dest-only. Not D$ fill. |
| **Rule** | Leftover-complete slot0 Jump holds sequential NPC until its target line is presented. |
| **Site** | `frontend` `g1bv_arm`. Isolated P4 stays. |

### G1cv — leftover-complete slot0 Jump holds different-line I$ (**landed 2026-08-16**)

Do not overwrite the leftover-`jal` line with sequential
`0x400` while that Jump is unconsumed. Mini still
**P8 `0x18` @2446** (did not fire — leftover `jal` may
not be `cf=Jump` or already consumed). Hold cookie
t=96256. Keep. Not G1cu NPC hold. Not G1aa. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | Mini P8 `0x18` if `0x400` overwrites leftover `jal@0x3f6` |
| **Not** | G1cu/G1aa leftover Jump NPC. Not G1bl dest-only. Not D$ fill. |
| **Rule** | A leftover-complete unconsumed slot0 Jump is not overwritten by a different 8B I$ return. |
| **Site** | `frontend` `g1bl_hold_line`. Isolated P4 stays. |

### G1cw — leftover-complete slot0 jal is cf=Jump (**landed 2026-08-16**)

G1cv did not fire. Force leftover-complete slot0 JAL
to `cf=Jump` even if mash left NoCF. Mini still
**P8 `0x18` @2446** (did not fire — jal already Jump;
`serving_unaligned` is only the complete beat). Hold
cookie t=96256. Keep. Not G1co leftover NT beq. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | Mini P8 `0x18` if leftover `jal` is NoCF and sequential-skips |
| **Not** | G1co leftover NT beq as Branch. Not G1cu NPC. Not D$ fill. |
| **Rule** | Leftover-complete slot0 JAL is `cf=Jump` even if the mash path would leave NoCF. |
| **Site** | `frontend` `cf_type[0]`. Isolated P4 stays. |

### G1cx — leftover-complete slot0 Jump must enter IQ on the complete beat (**landed 2026-08-16**)

G1az only replayed aligned `pc[2:1]==00`. Leftover
`jal@0x3f6` is `11`; later-slot push + `addr[shamt]`
can drop it. Extend G1az block/replay to leftover
Jump. Mini still **P8 `0x18` @2446** (did not fire —
no overflow). Hold cookie t=96256. Keep. Not G1bd
target replay. Not G1cu NPC. Isolated P4 stays.

| | |
|--|--|
| **Hits** | Mini P8 `0x18` if leftover `jal` is presented but not pushed |
| **Not** | G1cu/G1aa leftover Jump NPC. Not G1cw classify. Not D$ fill. |
| **Rule** | Leftover-complete slot0 Jump is consumed into IQ on the complete beat. |
| **Site** | `instr_queue` push. Isolated P4 stays. |

### G1cy — leftover-complete slot0 Jump must issue before later-slot fallthrough (**landed 2026-08-16**)

G1cx did not fire (no FIFO overflow). Insert leftover
Jump (`pc[2:1]==11`, `CTRL_FLOW`, not Branch/JALR) at
ID port 0 when port 1 is empty and fetch[0] is older.
Not G1be (same-line dest-before-Branch; `0x3f6` and
`0x3fa` are different 8B lines). Mini still **P8 `0x18`
@2446** (did not fire — leftover `jal` is not at
`fetch_entry[0]` when later slots already sit at IQ
head). Hold cookie t=96256. Keep. Isolated P4 stays.

| | |
|--|--|
| **Hits** | Mini P8 `0x18` if leftover `jal` is at fetch[0] behind a younger ID[0] |
| **Not** | G1be same-line. Not G1bi IQ hold. Not G1cu NPC. Not D$ fill. |
| **Rule** | Leftover-complete slot0 Jump issues before later-slot fallthrough already in ID. |
| **Site** | `id_stage` insert after G1be. Isolated P4 stays. |

### G1cz — leftover-complete slot0 Jump is slot0-only to IQ (**landed 2026-08-16**)

Hide later slots on the leftover-Jump complete beat
(G1ct-class mask, Jump-only). Mini still **P8 `0x18`
@2446** (TRACE unchanged: `0x3f8` twice then `0x400`;
`ra` stayed `0x3a8`). If `idx_is != 0`, slot0 jal is
not in `fifo_pos` so the mask is a no-op push. Hold
cookie t=96256. Keep. Isolated P4 stays.

| | |
|--|--|
| **Hits** | Mini P8 `0x18` if later-slot `li`/`bne` enter IQ on the leftover-Jump complete beat |
| **Not** | G1cl leftover-Branch hide (P1 live). Not G1cm later Jump hide. Not G1ct mispredict dest-only. Not G1cu NPC. Not D$ fill. |
| **Rule** | Leftover-complete slot0 Jump is the only IQ valid on that beat. |
| **Site** | `frontend` IQ `valid_i` mask. Isolated P4 stays. |

### G1da — leftover-complete slot0 Jump restarts `idx_is` (**landed 2026-08-16**)

Use `idx_is=0` this beat when leftover slot0 is Jump,
then advance by `shamt`. Not G1cg (all leftover —
MINI-FAIL P1). Not G1ch (Branch-only — HOLD-FAIL).
Mini still **P8 `0x18` @2454** (fired; +8 cy). TRACE
later NPC is `0x3fa` not `0x400`; `ra` still not
`0x3fa` (jal never commits). Hold cookie t=96256.
Keep. Isolated P4 stays.

| | |
|--|--|
| **Hits** | Mini P8 `0x18` if leftover `jal@0x3f6` is valid but `idx_is` points past slot0 |
| **Not** | G1cg all leftover `idx_is`. Not G1ch leftover-Branch `idx_is`. Not G1cz valid mask. Not G1cu NPC. Not D$ fill. |
| **Rule** | Leftover-complete slot0 Jump is the first IQ push (`idx_is=0`). |
| **Site** | `instr_queue` `idx_is`. Isolated P4 stays. |

### G1db — leftover-complete slot0 Jump does not +8 NPC this beat (**HOLD-FAIL 2026-08-16 — reverted**)

One-cycle `serving_unaligned` +8 suppress for leftover
Jump. Mini still **P8 `0x18` @2454** (TRACE unchanged:
`0x400` skip is 7 cy after leftover-complete). Hold
**no `[cookie-exit]`** past 6 min (OpenSBI leftover JAL
starves fetch, G1ce class). Reverted. Lab restored G1da
`f97ba5fd` / `ef012931` bit-identical. Do not re-land.
Leftover-Jump +8 stall family closed (G1cu sticky /
G1db one-cycle). Isolated P4 stays.

| | |
|--|--|
| **Hits** | Mini P8 `0x18` if leftover `jal` predict is overwritten by sequential +8 |
| **Not** | G1cu leftover Jump G1cc. Not G1ce/G1ck leftover +8 stall. Not G1aa leftover-JAL NPC. Not D$ fill. |
| **Rule** | Leftover-complete slot0 Jump predict is not overwritten by fetch +8. |
| **Site** | `frontend` `npc_select`. Isolated P4 stays. |

### G1dc — leftover Jump in IQ must issue (**landed 2026-08-16**)

G1da pushed leftover `jal` to FIFO 0; `idx_ds` still
named a younger slot so jal never issued. Seek any
dest FIFO with leftover Jump (`pc[2:1]==11`, `cf=Jump`)
as IQ head. Mini **PASS @2692** (P8 `0x18` **closed**).
TRACE t=2446 `ra=0x3fa` (jal committed). Hold cookie
t=22528 (faster than t=96256). Keep. Isolated P4 stays.

| | |
|--|--|
| **Hits** | Mini P8 `0x18` if leftover `jal` sits in a dest FIFO behind `idx_ds` |
| **Not** | G1db/G1cu leftover Jump NPC. Not G1cy ID insert. Not G1bc empty-only skip. Not D$ fill. |
| **Rule** | Leftover Jump in any dest FIFO is the IQ head. |
| **Site** | `instr_queue` `idx_ds` mux. Isolated P4 stays. |

### G1dd — PEEL leftover `c.lw` after mini green (**confirmed 2026-08-16**)

G1dc leftover-Jump IQ head. PEEL `7efc077a` **cookie-exit**
t=22528 `51b1babe`+`51b1d000`. No `[pin-exit]`, no
`mepc=129f8` (hangpc `mepc=0` `wfi0=1`). Nat pin
`bc7ed11d` same cookie t=22528. Soft getprop stays:
`plat_hc=80` `coldboot_done=0` `last_hartidx=0` (hart1
`sp1=0`). Do not retire `mk_plat_skip`. Isolated P4 stays.

| | |
|--|--|
| **Hits** | PEEL `129f8/4/9` if leftover Jump IQ head is not that pin |
| **Not** | G1dc re-work. Not I4cg. Not D$ fill. Not stage-3 retire. |
| **Rule** | Mini-green + hold-safe, then PEEL cookie or a new pin. |
| **Site** | PEEL soak (no RTL). Isolated P4 stays. |

### G1de — second hart / `plat_hc` after PEEL cookie (**landed 2026-08-17**)

TB treated `CVA6_COOKIE_EXIT=0` as on (`getenv` presence).
Honor `0` as off (`g6lc_tb` / `ariane_tb` / `soak_common`
unset). Default cookie-exit still t=22528. Burn 200k:
still `plat_hc=80` `sp1=0` — inside `SMT_COLD_EXCL=200000`
(hart0 exclusive). Burn 250k: `act=1` `npc=_wait_for_boot_hart@2e8`
`ra1=0x10` `sp1=0` `wfi0=1`. Hart1 starts after cold
excl; boot hart already cave-WFI so HSM never publishes
the secondary stack. Do not lower `SMT_COLD_EXCL`. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | `plat_hc=80` at cookie; hart1 `@2e8` `sp1=0` after 200k |
| **Not** | G0. Not I4cg. Not lower `SMT_COLD_EXCL`. Not D$ fill. |
| **Rule** | `COOKIE_EXIT=0` burns past the cookie; COLD_EXCL explains `plat_hc=80` at t=22528. |
| **Site** | testharness + soak_common. Isolated P4 stays. |

### G1df — COLD_EXCL lifts on boot-hart WFI (**landed 2026-08-17**)

`SMT_COLD_EXCL` stays 200000. `cold_excl` also requires
`~smt_hart_halt[0]`. Cave WFI then lets hart1 start at
cookie t=22528 (`act=1` `npc=0x308` `ra1=0x10`) instead
of waiting until 200k. Mini **PASS @2692**. Hold+PEEL
cookie t=22528. `sp1=0` `plat_hc=80` remain. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | Hart1 idle until 200k while hart0 already cave-WFI |
| **Not** | Lower `SMT_COLD_EXCL`. Not G3 switch-to-sp0. Not G0. Not I4cg. |
| **Rule** | Cold exclusive does not outlive boot-hart WFI. |
| **Site** | `cva6.sv` `cold_excl`. Isolated P4 stays. |

### G1dg — COLD_EXCL also lifts after DRAM+grace (**MINI-FAIL 2026-08-17 — reverted**)

Lifted `cold_excl` when `boot_done && grace>=200` so
hart1 could join HSM/scratch before the cave WFI.
Mini **FAILED @1399** printed `1745289078` hex
`0x6806ff76` leftover a0 `0xd00dfeec`/`0xd00dfeed`
(FDT-magic mash / shared-path interleave). Spike PASS.
Did not soak hold. Reverted to G1df-only
`cold_excl = (smt_cold_q < 200000) && ~smt_hart_halt[0]`.
Do not re-land. Do not lower `SMT_COLD_EXCL`. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | Cookie hangpc `act=1` `@308` `sp1=0` (hart1 too late for HSM) |
| **Not** | G1df WFI-lift (stays). Not lower 200000. Not G3. Not G0. Not I4cg. |
| **Rule** | Dual-ready must not start the secondary on the shared boot path. |
| **Site** | `cva6.sv` `cold_excl`. Isolated P4 stays. |

### G1dh — nat / HSM after G1df WFI-lift; not DRAM+grace (**landed 2026-08-17**)

No RTL. Nat cookie **SUCCESS** t=22528 `51b1babe`+`51b1d000`
(`plat_hc=80` `last_hartidx=0` `coldboot_done=0`). Hangpc
`act=1` `@308` `ra1=0x10` `sp1=0` `wfi0=1`. `COOKIE=0`
100k burn: still `plat_hc=80` `sp1=0`; `npc` moved
`@308`→`@2f0` (`_wait_for_boot_hart`); hart0 stays WFI.
Natural `hart_init` does not publish HSM after the cave.
Do not re-land G1dg. Isolated P4 stays.

| | |
|--|--|
| **Hits** | After G1df, hart1 at `_start` `sp=0`; hold HSM stubbed |
| **Not** | G1dg DRAM+grace lift. Not G1df WFI-lift. Not lower COLD_EXCL. Not G0. Not I4cg. Not D$ fill. |
| **Rule** | Cave WFI ends hart0 boot; burning past the cookie cannot publish HSM. |
| **Site** | Nat soak (no RTL). Isolated P4 stays. |

### G1di — late reset-vector must not re-run the lottery (**landed 2026-08-17**)

`fw_boot_hart` returns -1, so a late hart1 `amoswap`s
`_boot_status` 2→1 and waits forever. TRACE: status
`1`→`2` @20480 → **`1` @22528** (G1df WFI-lift). After
boot-hart WFI, unseen harts stay not-ready (no reset
fetch). Not G3 switch-to-sp0. Not G1dg DRAM+grace.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | `_boot_status` 2→1 at G1df WFI-lift; hart1 `@2e8` `sp=0` |
| **Not** | G1dg DRAM+grace lift. Not G1df WFI-lift (stays). Not G3. Not lower COLD_EXCL. Not G0. Not I4cg. |
| **Rule** | A hart first activated after the boot hart has halted does not fetch the reset vector. |
| **Site** | `cva6.sv` `smt_hart_ready_sel`. Isolated P4 stays. |

### G1dj — `sbi_init` cave-WFI before HSM / `plat_hc==2` (**landed 2026-08-17**)

No RTL. TRACE: not `996` after `start_finish`. Path is
`c.jalr` → `generic_cold_boot_allowed` (writes `51b1c001`)
returns `a0=1` at `@752` → NPC `752→758→766` (`j`
`sbi_hart_hang`) → hang cave **falls through**
`switch_mode` into success `@ef70`. Isolated
`mini_jalr_bnez_lottery` (aligned `c.jalr` + RVI `bnez`)
**PASS @370**. Not a generic jalr+bnez skip. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | Cookie `plat_hc=80` `coldboot_done=0` `@ef98`; never `@828` |
| **Not** | G1di late-lottery park. Not G1dg. Not generic jalr+bnez (mini green). Not G0. Not I4cg. |
| **Rule** | Cookie via hang-fallthrough is not HSM-complete; lottery `bnez@752` must take in the OpenSBI packet. |
| **Site** | TRACE + `mini_jalr_bnez_lottery.S`. Isolated P4 stays. |

### G1dk — OpenSBI lottery `bnez@752` must take (`a0=1`) (**landed 2026-08-17**)

No RTL. TRACE npc `7a2` at t=20468 — lottery **taken**.
`752→758` was predicted-NT fetch. Hang is `7bc`
(`bnez a0, hang`) after `ld a5,8(a5)` / `c.jalr`.
Never `@828`. Grown mini (leftover `ld`, two-pass,
ops[1] load-use) **PASS @468**. Isolated P4 stays.

| | |
|--|--|
| **Hits** | Cookie via hang; `coldboot_done=0`; thought `752` skipped |
| **Not** | Generic jalr+bnez. Not leftover-RVI skip (mini green). Not G0. Not I4cg. |
| **Rule** | Lottery take is not enough; `7bc` must not hang before `@828`. |
| **Site** | TRACE + `mini_jalr_bnez_lottery.S`. Isolated P4 stays. |

### G1dl — lottery tail `7bc` hang before `coldboot_done` (**landed 2026-08-17**)

No RTL. TRACE: not `7bc` as the committed hang. After
`@7a2`, npc `7c0`/`7c8` — `jal sbi_scratch_init`.
`hart_count` at `platform+80` is `0x80`. **No npc
`@38e0`.** Leftover-`jal` mini (`c.mv a0,s2` + `ld` +
leftover `jal` + `bnez a0`) **PASS @475**. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | Cookie before `@828`; `jal scratch_init` fetch, no target |
| **Not** | `7bc` as sole hang. Not generic leftover jal (mini green). Not G0. Not I4cg. |
| **Rule** | Cold path must enter `sbi_scratch_init` and reach `@828`. |
| **Site** | TRACE + `mini_jalr_bnez_lottery.S` p3. Isolated P4 stays. |

### G1dm — `jal scratch_init` must run (`hart_count` / target) (**landed 2026-08-17**)

No RTL. TRACE t=20484 `7c0`/`7c8` `ra=0x752` `s2` live
`a0=0`. **No `@38e0`, no `7ca`.** Jal never retires
(ra would be `7ca`). Far leftover-jal mini (`jal`
`+0x3100`) **PASS @456**. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7c8` then cookie; jal does not retire; no `@38e0` |
| **Not** | Far leftover-jal (mini green). Not G1dl near jal. Not G1dg. Not G0. Not I4cg. |
| **Rule** | Leftover `jal@7c6` after lottery must retire and fetch `0x38e0`. |
| **Site** | TRACE + `mini_jalr_bnez_lottery.S` p3 far. Isolated P4 stays. |

### G1dn — leftover `jal@7c6` must retire after lottery (**landed 2026-08-17**)

G1dc seeks leftover `cf=Jump`. OpenSBI `jal@7c6` may
be NoCF mash so it never becomes IQ head (`ra` stays
`752`). Also seek leftover RVI jal opcode
(`pc[2:1]==11`, `instr[6:0]==jal`). Not G1cw slot0-only.
Not G1db. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7c8` `ra=752`; leftover jal not `cf=Jump` |
| **Not** | G1dc Jump-only (stays). Not G1dm far-jal mini. Not G1dg. Not G0. Not I4cg. |
| **Rule** | Leftover RVI jal in any dest FIFO is IQ head even if cf is NoCF. |
| **Site** | `instr_queue` `idx_ds` mux. Isolated P4 stays. |

### G1do — leftover `jal@7c6` must issue / fetch `0x38e0` (**landed 2026-08-17**; did not fire)

G1cw only marked leftover jal as `cf=Jump` at slot0.
`jal@7c6` may sit in a later leftover-complete slot so
it never enters a dest FIFO (`ra` stays `752`). Any
leftover-complete RVI jal (`pc[2:1]==11`) is `cf=Jump`.
Not G1co leftover Branch. Not G1cw slot0-only (stays
as the [0] case). Isolated P4 stays.

Hold+nat cookie t=22528 `ra` still `752`. Did not fire
(jal already Jump / already slot0). Keep (hygiene).

| | |
|--|--|
| **Hits** | After G1dn, `7c8` `ra=752`; jal not fetch[0] |
| **Not** | G1dn opcode IQ head. Not G1co. Not G1dg. Not G0. Not I4cg. |
| **Rule** | Leftover-complete RVI jal in any fetch slot is `cf=Jump`. |
| **Site** | `frontend` `cf_type`. Isolated P4 stays. |

### G1dp — leftover Jump dest FIFO full drains FIFO 0 (**landed 2026-08-17**; did not fire)

G1dn/G1do did not fire: leftover `jal@7c6` is already
Jump / already slot0, and never entered a dest FIFO
(`ra` stays `752`). Isolated leftover-jal minis PASS —
not a generic leftover-jal skip. After ~20k cy G1da
names dest FIFO 0; G1cx blocks all push while that
FIFO is full; G1dc only seeks leftover Jump already
in a dest FIFO. Drain FIFO 0 so jal can push. Do not
override a leftover Jump already in a dest FIFO (P8).
Not G1db NPC +8. Not G1cv accept-target I$ (drops
jal). Isolated P4 stays.

| | |
|--|--|
| **Hits** | After G1do, `7c8` `ra=752`; jal never in dest FIFO |
| **Not** | G1dc/G1dn already-in-FIFO head. Not G1do cf mux. Not G1db. Not G1cv accept-target. Not G0. Not I4cg. |
| **Rule** | Leftover-complete slot0 Jump + dest FIFO 0 full → IQ head is FIFO 0. |
| **Site** | `instr_queue` `idx_ds` mux. Isolated P4 stays. |

Hold+nat cookie t=22528 `ra` still `752`. TRACE `7c0`/`7c8`
one beat (`a0=0` `s2=0x80144000`), no `@38e0`. Did not
fire (dest FIFO 0 was not the hole — jal left the
window after consume). Keep (hygiene). Isolated P4 stays.

### G1dq — leftover jal consume-to-hang path (**landed 2026-08-17**)

No RTL. TRACE npc: `996`/`99c` @t=20314 `ra=390`; again
@20382 `ra=9a4`; success cave `@ef78` @20386 `a0=0x40000`;
hang cave `@ef50` @20461 `ra=752`; leftover `7c0`/`7c8`
@20484 `ra=752`; hang `@ef4c` @20495. **No `@38e0`.**
`996` is fetched (patched skip) *before* leftover jal.
Cookie is hang-fallthrough after that wander. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | `7c8` one beat then gone; `996` fetched first; no `@38e0` |
| **Not** | G1dp dest-FIFO drain. Not G1dn/G1do. Not G1db. Not G0. Not I4cg. |
| **Rule** | After `996`/cave fetch, leftover `jal@7c6` must retire or be killed as stale. |
| **Site** | TRACE. Isolated P4 stays. |

### G1dr — leftover link-jal is IQ head; leftover jal x0 is not (**MINI-FAIL 2026-08-17 — reverted**)

G1dq: `996` is a leftover `jal x0` to the success cave.
Narrowed G1dc to leftover **link**-jal (`rd!=x0`) so
`996` would not park IQ. Mini **P8 `0x18` @2454** —
G1dc-closed leftover jal sat behind `idx_ds` again.
Reverted. **Do not re-land.** Isolated P4 stays.

| | |
|--|--|
| **Hits** | After G1dq, `996` leftover jal x0 then `7c8` `ra=752` |
| **Not** | G1dc any leftover Jump (must stay). Not G1dp. Not G1db. Not G0. Not I4cg. |
| **Rule** | Do not narrow G1dc by `rd`. P8 leftover jal must stay IQ head. |
| **Site** | `instr_queue` `idx_ds` mux. Isolated P4 stays. |

### G1ds — leftover Jump IQ head is the oldest PC (**landed 2026-08-17**; did not fire)

G1dr MINI-FAIL: do not filter G1dc by `rd` (P8 leftover
jal is still a leftover Jump). `996` jal x0 and
`jal@7c6` both match G1dc; first-FIFO scan parked
`996`. Among leftover Jumps, IQ head is the oldest
PC (`7c6` before `996`). P8 jal at `0x3f6` stays the
oldest leftover Jump. Not G1dr. Not G1dp dest drain.
Not G1db +8. Isolated P4 stays.

| | |
|--|--|
| **Hits** | After G1dr revert; `996` and `7c6` both leftover Jump |
| **Not** | G1dr rd-narrow G1dc. Not G1dp dest drain. Not G1db. Not G0. Not I4cg. |
| **Rule** | Leftover Jump IQ head is min PC among matching dest FIFOs. |
| **Site** | `instr_queue` `idx_ds` mux. Isolated P4 stays. |

Hold+nat cookie t=22528 `ra` still `752`. TRACE `996`
@20382 then leftover `7c8` @20484 (~100 cy later).
**No `@38e0`.** Did not fire (not both leftover Jumps
in dest FIFOs). Keep (hygiene). Isolated P4 stays.

### G1dt — leftover Jump may issue through unresolved leftover Jump (**landed 2026-08-17**; did not fire)

G1ds: `996` then leftover `7c8` ~100 cy later. `996`
jal x0 can leave `unresolved_cf` stuck (Jump, not
Branch; `flush_unissued` does not clear the bit).
`jal@7c6` then cannot issue (`ra` stays `752`).
Leftover-complete Jump (`pc[2:1]==11`) may issue
through unresolved leftover Jump. G1ax leftover-RVI
CF skip — HOLD-FAIL. Not G1dr. Not G1ds mux.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | After G1ds, `7c8` one beat; `996` leftover Jump may hold `unresolved_cf` |
| **Not** | G1ax all leftover CF. Not G1dr rd. Not G1ds oldest-PC. Not G1db. Not G0. Not I4cg. |
| **Rule** | Leftover Jump issues through unresolved leftover Jump. |
| **Site** | `g6lc_issue_barrier`. Isolated P4 stays. |

Hold+nat cookie t=22528 `ra` still `752`. TRACE `7c0`/`7c8`
one beat, **no `@38e0`.** Did not fire (`996` did not
leave a leftover-Jump `unresolved_cf` that blocked
`jal@7c6`). Keep (hygiene). Isolated P4 stays.

### G1du — leftover-RVI capture survives replay `kill_s2` (**landed 2026-08-17**; did not fire)

G1dt did not fire. `7c0` is `c.mv`+`ld`+leftover jal
first half; replay `kill_s2` clears leftover so `7c8`
never completes the jal (`bp_valid` never sees
`@38e0`, `ra` stays `752`). Keep leftover-RVI capture
(`pc[2:1]==11`, `[1:0]==11`, not the complete beat)
across replay. G1cq is leftover-complete NoCF
!replay-kill I$. Not G1as drop. Not G1db +8.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | After G1dt, `7c8` one beat; no `@38e0`; `ra=752` |
| **Not** | G1dt unresolved leftover Jump. Not G1cq complete-NoCF. Not G1as. Not G1db. Not G0. Not I4cg. |
| **Rule** | Leftover-RVI capture this beat survives replay `kill_s2`. |
| **Site** | `frontend` `keep_unaligned`. Isolated P4 stays. |

Hold+nat cookie t=22528 `ra` still `752`. TRACE `7c0`/`7c8`
one beat, **no `@38e0`.** Did not fire (replay did not
drop leftover on `7c0`, or no replay that beat). Keep
(hygiene). Isolated P4 stays.

### G1dv — presented leftover Jump is not a stale G1dc leftover (**landed 2026-08-17**; did not fire)

Batch TRACE: after `7c8`, next NPC is hang `@ef4c`
(+10 cy), not `@38e0` / `7d0` / `766`. `996` jal x0
was fetched earlier and can remain in a dest FIFO;
G1dc parks IQ on it so `jal@7c6` never pushes (G1dp
blocked). If the presented leftover Jump PC ≠ G1dc
FIFO PC, drop that G1dc head and drain FIFO 0. P8
presented PC matches the FIFO jal. Not G1dr `rd`.
Not G1ds (7c6 not yet in a FIFO). Isolated P4 stays.

| | |
|--|--|
| **Hits** | After G1du, `7c8` then hang `@ef4c`; `996` leftover still in IQ |
| **Not** | G1dr rd-narrow G1dc. Not G1ds oldest-PC (7c6 not in FIFO). Not G1dp (blocked by G1dc). Not G1db. Not G0. Not I4cg. |
| **Rule** | Presented leftover Jump PC ≠ G1dc leftover PC → drain FIFO 0. |
| **Site** | `instr_queue` `idx_ds` mux. Isolated P4 stays. |

Hold+nat cookie t=22528 `ra` still `752`. TRACE `7c0`/`7c8`
then hang `@ef4c`; **no `@38e0`.** Did not fire
(presented `7c8` is not leftover Jump `[2:1]==11`,
or G1dc PC already matches). Keep (hygiene). Isolated
P4 stays.

### G1dw — leftover-pending, hold +8 at the complete line (**HOLD-FAIL 2026-08-17**; reverted)

G1du required `valid[3]`; C|I|U (`c.mv`+`ld`+jal-half)
captures leftover with `valid[3]=0`. Holding +8 while
leftover is pending and NPC is already the leftover-next
8B line starved fetch. Hold+nat: **no cookie**,
`mepc=0x80000780` `mcause=2` (illegal), hang
`npc=0x80002d38` `wfi0=1` `ra=0x390` after 6M cycles
(`tohost=0`). Same class as G1ce/G1ck/G1db. Reverted
`frontend` + `instr_realign` leftover ports. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | After G1dv, `7c8` not leftover Jump; no `@38e0` |
| **Not** | G1ce leftover-complete +8. Not G1du `valid[3]`. Not G1db. Not G0. Not I4cg. |
| **Rule** | Do not hold +8 on leftover-pending at the complete line. |
| **Site** | Reverted. Do not re-land. Isolated P4 stays. |

### G1dx — C|I|U leftover-RVI keep through replay (`valid[3]=0`) (**landed 2026-08-17**; did not fire)

G1du keep required presented `valid[3]`. C|I|U capture
(`7c0` `c.mv`+`ld`+jal-half) writes leftover with
`valid[3]=0` (`instr[3]={0,data[63:48]}`), so replay
`kill_s2` still dropped the flop. Drop the `valid[3]`
gate; keep on last-halfword RVI-start
(`addr[3][2:1]==11 && instr[3][1:0]==11`) even when
that slot is not presented. Not G1dw +8. Not G1ce.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | After G1dw revert: leftover jal never completes; G1du never armed |
| **Not** | G1dw leftover-pending +8. Not G1du `valid[3]`. Not G1ce. Not G0. Not I4cg. |
| **Rule** | Replay keep leftover-RVI capture even when last slot is not valid. |
| **Site** | `frontend` `g1du_keep_leftover` (drop `instruction_valid[IPF-1]`). Isolated P4 stays. |

### G1dy — leftover-RVI capture beat outranks `kill_s2` (**MINI-FAIL 2026-08-17**; reverted)

G1dx is replay-only. Holding leftover-RVI across any
`kill_s2` on the capture beat (not only `replay`)
broke the mini: printed **23** @1134 (s11=23
`strlen_like` window; leftover assembled across a
flush that must drop). Same class as keeping leftover
into the wrong complete. Reverted. Isolated P4 stays.

| | |
|--|--|
| **Hits** | After G1dx: same `7c0`/`7c8`; leftover never completes |
| **Not** | G1dx replay keep. Not G1dw +8. Not G1du `valid[3]`. Not G0. Not I4cg. |
| **Rule** | Do not let leftover-RVI capture outrank `kill_s2` (except replay keep). |
| **Site** | Reverted. Do not re-land. Isolated P4 stays. |

### G1dz — CSR rdata mux by commit hart, not fetch-active (**landed 2026-08-17**; did not fire)

TRACE G1dz: after lottery, `7b0`/`7b8` `s1=1` `a0=1`
(hart0 `csrr mhartid@7ac` retired 1). `7be` would skip
`scratch_init` (`c.bnez s1,874`). Bank `h` `mhartid` is
`base+h`; `csr_rdata_o` was muxed by `active_hart_i`
(fetch), so a hart0 commit after a switch read bank 1.
Commit results follow `commit_instr.hart_id`. Privilege
outputs stay fetch-active. Not leftover keep. Not +8
hold. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7ac` `csrr mhartid` → `a0=1` on hart0; `7be` skips `@38e0` |
| **Not** | G1dw +8. Not G1dy capture-keep. Not G1dx replay. Not G0. Not I4cg. |
| **Rule** | CSR read data / exception follow the committing hart. |
| **Site** | `g6lc_smt_csr_bank` rdata mux. Isolated P4 stays. |

Hold+nat cookie t=22528. TRACE still `7b0` `a0=1`
`s1=1`. No `@38e0`. Did not fire (`csrr` still
tagged/committed as hart1, or TRACE RF is hart1).
Keep (hygiene). Isolated P4 stays.

### G1ea — stall use while same-hart CSR to that rs is in SB (**landed 2026-08-17**; did not fire)

TRACE: at `7a2`–`7b8` `a1=0x12` (`c.li a1,1` not
retired) so `a0=1` is the `71e4` jalr return, not
`mhartid`. `c.mv s1,a0` forwards that 1; `s1` stays 1
at `7c0` after `a0` becomes 0 (G1dz `csrr` did fire).
`7be` `c.bnez s1,874` skips `scratch_init`. `idx_hzd`
can pick the older jalr writer of `a0`; CSR is never
forwarded. Stall any use while a same-hart CSR to that
rs is in the SB. Not G1dz mux. Not G1an LOAD. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | `7b4` `c.mv s1,a0` with stale `a0=1`; `7be` skips `@38e0` |
| **Not** | G1dz rdata mux. Not G1an cancelled LOAD. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | A same-hart CSR rd in the SB stalls younger uses of that rs. |
| **Site** | `issue_read_operands` next to G1an. Isolated P4 stays. |

Hold+nat cookie t=22528. TRACE unchanged (`7c0` `s1=1`
`a0=0`; no `@38e0`). Did not fire (CSR not in SB when
`c.mv` issued — `7ac` never entered / already gone).
Keep (hygiene). Isolated P4 stays.

### G1eb — stall use while older same-hart ID writer of that rs (**MINI-FAIL 2026-08-17**; reverted)

G1ea SB CSR stall did not fire. Stalling any younger
issue for an older ID writer deadlocked in-order SB
(tohost=0 @400000; hang, not pass). Same class as
G1i sticky `a0`. Reverted. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7b4` `c.mv` issues before `7ac`/`7a4`; `s1=1`; `7be` skips `@38e0` |
| **Not** | G1ea SB CSR. Not G1i unresolved_a0. Not G1ag STORE. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Do not stall an in-SB younger for an ID-only older writer. |
| **Site** | Reverted. Do not re-land. Isolated P4 stays. |

### G1ec — IQ head is oldest PC among nonempty dest FIFOs (**MINI-FAIL 2026-08-17**; reverted)

G1ds is leftover-Jump only. Widening to all nonempty
FIFOs broke P1: printed **16** (`0x10`) @412 (first
`load_be32`). Same class as G1cg/G1bo idx restart.
Reverted. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7b4` issues before `7ac`; `s1=1`; no `@38e0` |
| **Not** | G1ds leftover-only. Not G1eb ID RAW. Not G1ea SB CSR. Not G1dr. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Do not make IQ head oldest PC among all nonempty FIFOs. |
| **Site** | Reverted. Do not re-land. Isolated P4 stays. |

### G1ed — leftover-pending smash only if slot0 is compressed (**landed 2026-08-17**)

G1bf rewrote every aligned leftover-pending slot0 to
`{16'b0, data[15:0]}`. OpenSBI `750` `c.jalr`+`bnez`+
leftover `ld` leaves leftover pending through `71e4`.
Aligned `7a8` I|I (`addi`+`csrr`) and `7b0` I|C|C
(`ld`+`c.mv`) were smashed. TRACE: `c.li`/`csrr` retire
only at `7c0`; `s1` stays the `snez` 1 (`c.mv@7b4` never
retires); `ra` stays `752` (jal@`7c6` never retires).
Restrict G1bf to `instr_is_compressed[0]` so `0x4d0`
`c.li` still formats and RVI slot0 stays 32-bit.
Not G1bo (widen). Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7b4` `c.mv` never retires; `s1=1`; `jal@7c6` `ra=752`; no `@38e0` |
| **Not** | G1bo any-aligned-compressed. Not G1eb ID RAW. Not G1ec oldest-PC IQ. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Leftover-pending aligned smash is only for a compressed slot0. |
| **Site** | `instr_realign` G1bf predicate. Isolated P4 stays. |

Lottery mini (750-shape leftover + 7a2–7be) **PASS @540**.
FDT mini **PASS @2692**. Hold+nat cookie t=22528. TRACE
unchanged (`7b0`/`7b8` `a0=1` `a1=0x12` `s1=1`; `7c0`
`a0=0` `a1=1` `s1=1` `ra=752`; hang cave `@ef70`; no
`@38e0`). Did not fire (G1bf was not the retire hole).
Keep (RVI-safe). Isolated P4 stays.

### G1ee — IQ head is older CSR over a younger use of that rd (**landed 2026-08-17**; did not fire)

TRACE G1ed: after `7c8`, npc `766`/`768` then
`ef4c` (`sbi_hart_hang`). `7bc` `c.bnez a0,766`
takes because `a0` is still the `71e4` return (1);
`csrr@7ac` retires only at `7c0`. Dest-FIFO rotate
can issue `7b4`/`7bc` before `7ac`. Prefer the
CSR FIFO when another nonempty FIFO holds a younger
use of that rd (`c.mv` rs2 / `c.bnez` rs1' / RVI
rs1/rs2). Not G1ec all-oldest. Not G1eb ID stall
(in-order SB hang). G1dc leftover-Jump head stays
first. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7bc` takes to `766`/`ef4c` with stale `a0=1`; `csrr` late |
| **Not** | G1ec oldest-PC all FIFOs. Not G1eb ID RAW stall. Not G1dr rd filter. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | An older same-stream CSR is IQ head over a younger use of its rd. |
| **Site** | `instr_queue` `idx_ds` after G1dc. Isolated P4 stays. |

Lottery **PASS @540**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE still `766`→`ef4c`→`ef70`;
`ra=752`; no `@38e0`. Did not fire (`7ac` not in IQ
with `7bc`, or G1dc leftover `jal@766` already head).
Keep. Isolated P4 stays.

### G1ef — presented leftover Jump drops a different leftover Jump in IQ (**landed 2026-08-17**; did not fire)

G1dv drained a PC-mismatch leftover by issuing
FIFO 0. TRACE: `7c8` then `766` `jal x0` → `ef4c`.
When leftover-complete Jump is presented, leftover
Jump FIFO entries at another PC are hidden and
popped (not issued). G1dc ignores them. G1dv no
longer forces FIFO 0. Not G1dr (`rd` filter; P8
presented PC matches). Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7c8` then `766`/`ef4c`; stale leftover `jal x0` issued as G1dc/G1dv head |
| **Not** | G1dr link-jal-only. Not G1ee CSR order. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | A presented leftover-complete Jump replaces a different leftover Jump in the dest FIFOs. |
| **Site** | `instr_queue` `g1ef_stale` / `iq_vis_empty`. Isolated P4 stays. |

Lottery **PASS @540**. FDT **PASS @2692** (P8 stays).
Hold+nat cookie t=22528. TRACE still `766`→`ef4c`
at t=20486 (one beat after `7c8`). Did not fire
(`766` is a `7bc` redirect, not an in-FIFO leftover
at the `7c8` beat). Keep. Isolated P4 stays.

### G1eg — leftover-pending aligned fetch drops a foreign leftover Jump (**landed 2026-08-17**; did not fire)

`7a8` I|I (`addi`+`csrr`) is fetched but `csrr` is
not in IQ/SB when `7bc` issues (`unresolved_csr`
would have blocked `7bc`). Hypothesis: leftover
`jal x0@766` occupies a dest FIFO. When leftover
is pending and an aligned line is presented, pop
leftover Jump entries from another 8B line. Not
G1ef (that needs leftover-complete Jump at slot0).
Not G1dw +8 hold. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7ac` never in IQ; `7bc` takes `766` with `a0=1` |
| **Not** | G1ef present-Jump. Not G1dw +8. Not G1dr. Not G1ee/G1ea/G1eb. Not G0. Not I4cg. |
| **Rule** | Leftover-pending sequential fetch replaces a leftover Jump from another line. |
| **Site** | `instr_realign` `leftover_pending_o` → `instr_queue`. Isolated P4 stays. |

Lottery (7b8-shape) **PASS @562**. FDT **PASS @2692**.
Hold+nat cookie t=22528. TRACE still `7b8` `a0=1`
then `766`→`ef4c`. Did not fire (`750` leftover
likely completed at `758` before `7a8`, so
`leftover_pending=0`). Keep. Isolated P4 stays.

### G1eh — same-line IQ head is oldest PC (**MINI-FAIL 2026-08-17**; reverted)

`7b8` `c.beqz` before `7bc` `c.bnez` so `7bc` is
later and might see `csrr`. Same 8B line only —
not G1ec all FIFOs. Lottery **hang tohost=0 @400000**.
FDT **printed 89** (`0x59` P6 `offset_ptr` NULL)
@1043. Same class as G1ec in-order head. Reverted.
**Do not re-land.** Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7bc` issues before `7b8` `c.beqz`; stale `a0=1` |
| **Not** | G1ec all-FIFO oldest. Not G1eb ID stall. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Do not make IQ head oldest PC on a same-line group. |
| **Site** | Reverted. Do not re-land. Isolated P4 stays. |

### G1ei — aligned fetch drops leftover jal x0 from another line (**landed 2026-08-17**; did not fire)

G1eg needs `leftover_pending` (0 at `7a8`). Still
drop leftover `jal x0` (`rd==0`) from another 8B
line so G1dc does not park `766` through `csrr`.
Not G1dr (G1dc still any leftover Jump). Not G1eh.
P8 `jal ra` stays. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `766` jal x0 in IQ at `7a8`; `7ac` never issues; `7bc` takes |
| **Not** | G1dr G1dc rd-narrow. Not G1eh same-line. Not G1eg pending-only. Not +8. Not G0. Not I4cg. |
| **Rule** | An aligned sequential fetch replaces leftover `jal x0` from another line. |
| **Site** | `instr_queue` `g1ef_stale`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE still `7b8` `a0=1`→`766`.
Did not fire (`766` leftover from t=20410 is gone
by `7a8`; `20486` is a `7bc` redirect). Keep.
Isolated P4 stays.

### G1ej — aligned I|I push is atomic (**landed 2026-08-17**; did not close `7bc`)

If `addi@7a8` pushes and `csrr@7ac`'s dest FIFO is
full, `consumed[0]` still advances and replay
`addr[shamt]` skips `csrr`. Block the whole I|I
line so both RVI slots push or neither. Not G1az
slot0-only. Not G1eh IQ head. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7ac` dropped after `addi` consume; `7bc` sees `a0=1` |
| **Not** | G1az slot0-only. Not G1eh/G1ec IQ head. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | An aligned I|I package is replayed from slot0 if any dest FIFO is full. |
| **Site** | `instr_queue` `g1ej_ii_blocked`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE still `7b8` `a0=1`→`766`
(lottery window ~19 cy earlier). Did not close
`7bc`. Keep (I|I atomicity). Isolated P4 stays.

### G1ek — unconsumed aligned I|I holds different-line I$ (**landed 2026-08-17**; did not fire)

`7b8` can enter IQ while `7a8` `csrr` is still
unconsumed. Hold a different-line I$ beat while
aligned I|I (`valid[0]` and `valid[1]` RVI) is
not fully consumed. Not G1cv leftover Jump. Not
G1ce/+8 NPC. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7b0`/`7b8` overwrite `7a8` before `csrr` is consumed |
| **Not** | G1cv leftover Jump. Not G1ce/+8 NPC. Not G1ej push-atomic. Not G1eh. Not G0. Not I4cg. |
| **Rule** | An unconsumed aligned I|I line is not replaced by a later 8B I$ return. |
| **Site** | `frontend` `g1ek_ii_hold` on `g1bl_hold_line`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE still `7b8` `a0=1`→`766`
(same times as G1ej). Did not fire (I|I consumed
same beat, or `7a8` not presented as I|I). Keep.
Isolated P4 stays.

### G1el — unconsumed mid-line (`[2:1]==01`) holds different-line I$ (**landed 2026-08-17**; did not fire)

`7a2` is `c.li`+`auipc` at `[2:1]==01`. G1ek I|I
hold never arms. Hold different-line I$ while that
package is unconsumed so `7b8` cannot issue first.
Not G1ek. Not G1ce/+8 NPC. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7a2` overwritten by `7a8`/`7b8` before `c.li`/`csrr` consumed |
| **Not** | G1ek aligned I|I. Not G1cv leftover Jump. Not G1ce/+8 NPC. Not G1eh. Not G0. Not I4cg. |
| **Rule** | An unconsumed `[2:1]==01` fetch is not replaced by a later 8B I$ return. |
| **Site** | `frontend` `g1el_mid_hold` on `g1bl_hold_line`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE still `7b8` `a0=1`→`766`.
Did not fire (consumed same beat). Keep. Isolated
P4 stays.

### G1em — older CSR-to-a0 before a younger a0-Branch (**landed 2026-08-17**; did not close `7bc`)

TRACE G1el: `7b8` `a0=1`, sequential `7c0` `a0=0`,
then `766` at +2 cy — `7bc` issued with stale `a0`
before `csrr` could be the IQ/ID head. G1ee needs
the use still in IQ. G1ea needs CSR in SB. G1eb
stalled every RAW (hang). One class, three sites:
IQ head is older CSR-to-a0 over the rotate head;
ID inserts that CSR before a Branch on a0 (port 1
empty); issue stalls that Branch while the CSR is
still in ID. G1dc leftover Jump stays first. Not
G1eh/G1ec all-oldest. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7bc` issues with `a0=1` while `csrr@7ac` is still in IQ/ID |
| **Not** | G1ee use-still-queued. Not G1ea SB CSR. Not G1eb all RAW. Not G1eh. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | An older same-hart CSR that writes a0 issues before a younger Branch that uses a0. |
| **Site** | `instr_queue` + `id_stage` + `g6lc_issue_barrier`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE second-pass `7a2`@20449
`7a8`@20450 then `7b8` `a0=1`→`766`. No
`csrrcmt`. Did not close `7bc` (G1dc leftover
Jump still outranks G1em). Keep. Isolated P4 stays.

### G1en — leftover jal x0 drops while CSR-to-a0 is queued (**landed 2026-08-17**; did not fire)

G1ei hides leftover `jal x0` only on the aligned
present beat. After `7a8` is consumed, G1dc can
park `766` again so G1em never makes `csrr` the
head. Drop leftover `jal x0` (`rd==0`) while a
CSR-to-a0 is in a dest FIFO or is being presented.
G1dc still heads leftover Jump when no CSR-a0
(not G1dr). P8 `jal ra` stays. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover `jal x0@766` parks IQ through `csrr@7ac` |
| **Not** | G1dr G1dc rd-narrow. Not G1ei aligned-beat-only. Not G1eh. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Leftover `jal x0` is not queued beside an unissued CSR that writes a0. |
| **Site** | `instr_queue` `g1ef_stale` / `g1en_csr_a0`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged (`7a8`@20450,
`7b8` `a0=1`→`766`). No `csrrcmt`. Did not fire
(`jal x0` and `csrr` not in IQ together). Keep.
Isolated P4 stays.

### G1eo — aligned I|I restarts idx_is (**MINI-FAIL 2026-08-17**; reverted)

Mid-line `7a2` advances `idx_is` by 2 so `7a8`
I|I would rotate into FIFO 2/3. Restart `idx_is`
to 0 on aligned I|I (same predicate as G1ej).
Lottery **hang** tohost=0 @200678. FDT **printed
18** (`0x12` P2 header `lbu`) @434. G1cg-class
`idx_is` restart. Reverted to G1en slfix
`e017f1ca` / `5524d3ee`. **Do not re-land.**
Isolated P4 stays.

| | |
|--|--|
| **Hits** | `csrr@7ac` in FIFO 2/3 never G1em/G1en head |
| **Not** | G1cg leftover idx_is. Not G1da leftover Jump. Not G1ej block. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Do not restart `idx_is` on aligned I|I. |
| **Site** | Reverted. Do not re-land. Isolated P4 stays. |

### G1ep — consumed mid-line holds I$ that is not sequential next (**landed 2026-08-17**; did not fire)

G1el only holds while `[2:1]==01` is unconsumed.
After consume, `7b0` can replace `7a2` before
`7a8` I|I is presented. Reject a different-line
I$ unless it is the sequential next 8B. Not
G1eo `idx_is`. Not G1ce/+8 NPC. Not G1ck
leftover +8. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7a2` consumed then `7b0` overwrites before `csrr@7ac` |
| **Not** | G1el unconsumed. Not G1eo idx_is. Not G1ce/+8 NPC. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | A consumed mid-line `[2:1]==01` fetch is not replaced by a non-sequential later 8B. |
| **Site** | `frontend` `g1ep_hold` on `g1bl_hold_line`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged (`7a2`@20449
`7a8`@20450 then `7b8` `a0=1`→`766`). No
`csrrcmt`. Did not fire (`7a8` already next npc).
Keep. Isolated P4 stays.

### G1eq — aligned I|I slot1 CSR is not hidden by G1ct/G1cz (**landed 2026-08-17**; did not fire)

G1ct dest-only and G1cz leftover-Jump slot0-only
zero `valid[1+]`. If `7a8` I|I shares that beat,
`csrr` never enters IQ. Keep slot1 when it is a
CSR on an aligned I|I. G1ct `0x4d0` is C|Branch,
not I|I. Not G1eo `idx_is`. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `csrr@7ac` hidden so `7bc` sees `a0=1` |
| **Not** | G1ct dest-only on C|Branch. Not G1eo idx_is. Not G1ep I$ hold. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | An aligned I|I whose slot1 is CSR keeps that slot through dest-only / leftover-Jump hide. |
| **Site** | `frontend` `g1eq_ii_csr` on `g1ct_valid`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged. No `csrrcmt`.
Did not fire (`7a8` is not a G1ct/G1cz beat).
Keep. Isolated P4 stays.

### G1er — aligned I|I slot1 CSR is not dropped by IQ branch_mask (**landed 2026-08-17**; did not fire)

If slot0 is marked taken (`cf != NoCF`), `lzc`
zeros `valid[1]` so `csrr` never pushes. Restore
slot1 when the package is aligned I|I with a CSR
in slot1. Not G1eq `g1ct` hide. Not G1eo `idx_is`.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | `csrr@7ac` masked by taken slot0; `7bc` sees `a0=1` |
| **Not** | G1eq frontend hide. Not G1eo idx_is. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | An aligned I|I whose slot1 is CSR keeps that slot through `branch_mask`. |
| **Site** | `instr_queue` `g1er_ii_csr` on `valid`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged. No `csrrcmt`.
Did not fire (`valid_i[1]` already 0, or slot0
not taken). Keep. Isolated P4 stays.

### G1es — aligned I|I overrides leftover_next (**MINI-FAIL 2026-08-17**; reverted)

Do not leftover-complete onto an aligned line
whose data is I|I; present addi+csrr and keep
leftover pending. Lottery+FDT **hang** tohost=0
@400000. Starved leftover-complete onto
I|I-looking next lines. Reverted to G1er slfix
`15676b30` / `b7ebe6fd`. **Do not re-land.**
Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover_next on `7a8` smashes `csrr` off the package |
| **Not** | G1ed compressed smash. Not G1as drop leftover. Not G1eo idx_is. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Do not override leftover_next with aligned I|I. |
| **Site** | Reverted. Do not re-land. Isolated P4 stays. |

### G1et — fill missing aligned I|I slot1 CSR from I$ (**landed 2026-08-17**; did not fire)

If realign left slot1 invalid while slot0 is
line-aligned RVI and the I$ high word is CSR,
present that CSR. Leftover-complete slot0 is
`[2:1]==11` so this does not steal leftover_next
(G1es hang). Isolated P4 stays.

| | |
|--|--|
| **Hits** | `csrr@7ac` missing from realign; `7bc` sees `a0=1` |
| **Not** | G1es leftover_next override. Not G1ed smash. Not G1eo idx_is. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | A missing aligned I|I CSR slot is filled from the registered I$ word. |
| **Site** | `frontend` `g1et_ii_csr` after realign. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged. No `csrrcmt`.
Did not fire (slot1 already valid, or not CSR,
or leftover-complete beat). Keep. Isolated P4
stays.

### G1eu — leftover jal x0 does not leftover-complete onto I|I (**landed 2026-08-17**; did not fire)

G1es overrode leftover_next for *any* leftover
and hung. Only leftover `jal x0` (`rd==0`) skips
complete onto an aligned I|I line; present
addi+csrr and keep leftover pending. P8 `jal ra`
still completes. Not G1dr. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover `jal x0` leftover_next on `7a8` smashes `csrr` |
| **Not** | G1es any leftover. Not G1dr G1dc rd. Not G1ed. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Leftover `jal x0` does not complete onto an aligned I|I fetch. |
| **Site** | `instr_realign` after G1ed. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged. No `csrrcmt`.
Did not fire (leftover on `7a8` is not `jal x0`,
or leftover_next is not `7a8`). Keep. Isolated
P4 stays.

### G1ev — a0-Branch waits for older ALU a0 writer in ID (**landed 2026-08-17**; did not fire)

G1em is CSR-only. `auipc@7a4` / `addi@7a8` write
a0 before `7bc`. Insert that ALU at ID[0] when
the Branch is ID[0] (port 1 empty); stall the
Branch in issue while the ALU is still in ID.
Not G1eb stall-all RAW. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7bc` issues with `a0=1` while `auipc`/`addi` still in ID |
| **Not** | G1em CSR-only. Not G1eb all RAW. Not G1ay same-line. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | An older same-hart ALU that writes a0 issues before a younger Branch that uses a0. |
| **Site** | `id_stage` + `g6lc_issue_barrier`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged. No `csrrcmt`.
Did not fire (ALU-to-a0 not in ID with `7bc`).
Keep. Isolated P4 stays.

### G1ew — older ALU-to-a0 is IQ head over rotate (**MINI-FAIL 2026-08-17**; reverted)

G1ev ID stall did not fire. Prefer dest-FIFO
ALU-to-a0 (`auipc`/`addi`/`c.li`) over the
rotate head. Lottery **PASS @562**. FDT
**printed 29** (`0x1d` P10) @1854. G1eh-class
in-order head. Reverted to G1ev slfix
`671285ca` / `e7d9899c`. **Do not re-land.**
Isolated P4 stays.

| | |
|--|--|
| **Hits** | `addi@7a8` sits behind rotate; `7bc` issues first |
| **Not** | G1eh all-oldest. Not G1em CSR head. Not G1ev ID. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Do not make IQ head older ALU-to-a0 over rotate. |
| **Site** | Reverted. Do not re-land. Isolated P4 stays. |

### G1ex — unissued dest-FIFO / presented CSR-to-a0 holds different-line I$ (**landed 2026-08-17**; did not fire)

G1ek only holds while I|I is unconsumed. After
consume, `csrr@7ac` is in IQ and `7b0`/`7b8`
can still overwrite before it issues. Hold that
different-line I$ while dest-FIFO / presented
CSR-to-a0 is live. Not G1ew IQ head. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | `7b0`/`7b8` overwrite IQ before `csrr` issues; `7bc` sees `a0=1` |
| **Not** | G1ew ALU IQ head. Not G1ek unconsumed I\|I. Not G1ce/+8. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | Unissued dest-FIFO / presented CSR-to-a0 holds a different-line I$. |
| **Site** | `instr_queue` `g1ex_csr_a0_o`; `frontend` `g1ex_hold` on `g1bl_hold_line`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged (`7a2`@20449
`7a8`@20450 `7b8` `a0=1`→`766`@20467). No
`csrrcmt`. No `@38e0`. Did not fire (`7bc`
already in IQ, or CSR-to-a0 not queued on the
I$ request). Keep. Isolated P4 stays.

### G1ey — dest-FIFO a0-Branch waits for queued CSR-to-a0 (**landed 2026-08-17**; did not fire)

G1ex I$ hold did not delay `7bc`. G1em CSR IQ
head loses to G1dc leftover Jump, so `7bc` can
still issue from another FIFO. Hide dest-FIFO
a0-Branch while CSR-to-a0 is queued or
presented; same-cycle later issue-port CSR also
stalls the Branch. Not G1ew ALU head. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | `7bc` issues from dest FIFO while `csrr@7ac` is still queued |
| **Not** | G1ex I$ hold. Not G1em IQ head. Not G1ew ALU head. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Dest-FIFO a0-Branch is not IQ-visible while CSR-to-a0 is queued or presented. |
| **Site** | `instr_queue` `g1ey_is_a0_br` / `g1ef_stale`; `g6lc_issue_barrier` same-cycle later-port. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged. No `csrrcmt`.
Did not fire (CSR-to-a0 not queued with `7bc`).
Keep. Isolated P4 stays.

### G1ez — leftover-complete unconsumed NoCF dest holds different-line I$ (**landed 2026-08-17**; did not fire)

G1ca requires prefix_unconsumed when
`serving_unaligned`, so leftover auipc/addi
releases `7b0` before `csrr` pushes. Hold
different-line I$ while leftover-complete slot0
is an unconsumed NoCF dest. Not G1cv Jump. Not
G1bp prefix. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover auipc/addi `serving_unaligned` releases `7b0` before `csrr` |
| **Not** | G1cv leftover Jump. Not G1bp prefix. Not G1ca leftover Branch. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Leftover-complete unconsumed NoCF dest holds a different-line I$. |
| **Site** | `frontend` `g1ez_hold` on `g1bl_hold_line`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged. No `csrrcmt`.
Did not fire (`serving_unaligned` not set on the
`7a8` beat, or leftover slot0 not NoCF dest).
Keep. Isolated P4 stays.

### G1fa — reject I$ that is ahead of npc (**landed 2026-08-17**; did not fire)

TRACE holds npc `7a8` for 7 cy. A later-line I$
return (`7b0`/`7b8`) would skip addi+csrr.
Reject incoming I$ whose line is greater than
npc. Not G1ce/+8 stall. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7b0`/`7b8` I$ returns while npc is still `7a8`; `csrr` never presented |
| **Not** | G1ce/+8 NPC stall. Not G1ep consumed-01. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | An I$ line ahead of npc is not registered. |
| **Site** | `frontend` `g1fa_hold` on `g1bl_hold_line`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged. No `csrrcmt`.
Did not fire (incoming I$ line was never ahead
of npc; `7b0` arrives after npc already `7b0`).
Keep. Isolated P4 stays.

### G1fb — dest-FIFO a0-Branch ahead of npc is not IQ-visible (**MINI-FAIL 2026-08-17**; reverted)

Hide dest-FIFO a0-Branch whose PC line is still
ahead of npc (do not pop). Lottery **printed 4**
@375 (first-pass bnez took ret0). FDT **hang**
tohost=0 @400000. Reverted to G1fa slfix
`9215c343` / `0d55ef5f`. **Do not re-land.**
Isolated P4 stays.

| | |
|--|--|
| **Hits** | prefetched `7bc` in dest FIFO issues before `7a8` |
| **Not** | G1fa I$ ahead-of-npc. Not G1ey CSR-queued. Not G1ce/+8. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | Do not hide dest-FIFO a0-Branch while its PC is ahead of npc. |
| **Site** | Reverted. Do not re-land. Isolated P4 stays. |

### G1fc — dest-FIFO a0-Branch >1 line ahead of npc is hidden (**MINI-FAIL 2026-08-17**; reverted)

Narrower than G1fb: hide only when the Branch
PC line is more than one 8B line ahead of npc.
Lottery **printed 4** @375. FDT **hang** @400000.
Same as G1fb. Reverted to G1fa slfix `9215c343`
/ `0d55ef5f`. **Do not re-land.** Isolated P4 stays.

| | |
|--|--|
| **Hits** | prefetched `7bc` is +2 lines ahead of npc `7a8` |
| **Not** | G1fb any-ahead. Not G1fa I$. Not G1ey. Not +8. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | Do not hide dest-FIFO a0-Branch by npc-line distance. |
| **Site** | Reverted. Do not re-land. Isolated P4 stays. |

### G1fd — after mid-line consume, hide a0-Branch past sequential next (**landed 2026-08-17**; did not fire)

G1fb/G1fc npc-ahead hide MINI-FAIL. After a
mid-line `[2:1]==01` package is pushed, hide
dest-FIFO a0-Branch whose PC is past the
sequential next line until that line is
presented (or fetch skips past). Not npc
distance. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7a2` pushed then `7bc` issues before `7a8` I\|I |
| **Not** | G1fb/G1fc npc hide. Not G1ep I$ hold. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | After a mid-line consume, dest-FIFO a0-Branch past the sequential next waits for that next line. |
| **Site** | `instr_queue` `g1fd_wait_q` / `g1fd_hide`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged. No `csrrcmt`.
Did not fire (01 package not pushed before `7bc`,
or sequential next / skip cleared wait first).
Keep. Isolated P4 stays.

### G1fe — aligned I|I CSR-to-a0 data hides dest-FIFO a0-Branch (**landed 2026-08-17**; did not fire)

G1ey needs CSR queued. Detect aligned I|I whose
slot1 *data* is CSR-to-a0 even if `valid[1]=0`.
Hide dest-FIFO a0-Branch until that line is no
longer presented. Do not pop. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7a8` addi+csrr data present; `valid[1]=0`; `7bc` already in dest FIFO |
| **Not** | G1ey CSR queued. Not G1fd mid-line. Not G1fb/G1fc npc. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Aligned I|I CSR-to-a0 data hides dest-FIFO a0-Branch until that line drops. |
| **Site** | `instr_queue` `g1fe_ii_csr` / `g1fe_wait_q` / `g1fe_hide`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged. No `csrrcmt`.
Did not fire (`7a8` not presented as I|I CSR
data, or `7bc` not in dest FIFO then). Keep.
Isolated P4 stays.

### G1ff — registered I$ I|I CSR-to-a0 hides later dest-FIFO a0-Branch (**landed 2026-08-17**; did not fire)

G1fe looked at realign `instr_i` and did not
fire. Use the registered I$ word (G1et data):
aligned low RVI + high CSR-to-a0. Hide dest-FIFO
a0-Branch on a later line only. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7a8` I$ is addi+csrr; `7bc` already in dest FIFO |
| **Not** | G1fe realign `instr_i`. Not G1et fill. Not G1fb npc. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Registered I$ aligned I|I CSR-to-a0 hides a later dest-FIFO a0-Branch. |
| **Site** | `frontend` `g1ff_ii_csr`; `instr_queue` `g1ff_hide`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged. No `csrrcmt`.
Did not fire (registered I$ was not addi+csrr,
or `7bc` not in dest FIFO then). Keep. Isolated
P4 stays.

### G1fg — TRACE commit PC from packed entry MSB (**landed 2026-08-17**)

`log commit` never fired: packed `commit_instr_o`
is 2×464 (`VlWide` 928); port-0 `pc` is
`[W-1 -: 64]` = `[463:400]`, not old `[464:401]`.
Isolated P4 stays. Not RTL.

| | |
|--|--|
| **Hits** | TRACE `csrrcmt` never appeared; `7ac` commit unknown |
| **Not** | RTL. Not G1ew. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Commit PC is the MSB 64 bits of each packed scoreboard entry. |
| **Site** | `corev_apu/tb/g6lc_tb.cpp` TRACE `log commit`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. **`csrrcmt` t=20463 `7ac`.** `7b8`
t=20458 `a0=1` then `766` t=20467. CSR commits
*after* `7bc` has issued. Isolated P4 stays.

### G1fh — a0-Branch waits until seen CSR-to-a0 commits (**landed 2026-08-17**; did not fire)

G1fg: `csrr@7ac` commits t=20463 after `7b8`
t=20458. Arm a per-hart flop on IQ/ID/issue
CSR-to-a0; stall a0-Branch until that CSR
commits. Clear on flush. Not G1i. Isolated P4
stays.

| | |
|--|--|
| **Hits** | `7bc` issues after CSR is in IQ/ID but before commit |
| **Not** | G1ey dest-FIFO-only. Not G1em ID-only. Not G1ea SB-only. Not G1i. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | An a0-Branch waits until a seen same-hart CSR-to-a0 commits. |
| **Site** | `g6lc_issue_barrier` `g1fh_seen_q`; IQ `g1ex_csr_a0` via frontend. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged (`csrrcmt` t=20463,
`766` t=20467). Did not fire (`7bc` issued before
CSR was sighted). Keep. Isolated P4 stays.

### G1fi — mid-line wait on presentation, not consume (**landed 2026-08-17**; did not fire)

G1fd required consume of `[2:1]==01` and never
armed. Arm on presentation. Hide dest-FIFO
a0-Branch past sequential next until that line
is presented or fetch skips past. Not G1fb
npc-ahead. Do not pop. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7a2` presented; `7bc` in dest-FIFO before `7a8` |
| **Not** | G1fd consume. Not G1fb/G1fc npc. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | After a mid-line presentation, dest-FIFO a0-Branch past the sequential next waits for that next line. |
| **Site** | `instr_queue` `g1fi_wait_q` / `g1fi_hide`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged (`csrrcmt` t=20463,
`766` t=20467). Did not fire (`7a8` npc t=20450
clears wait before `7b8` t=20458). Keep.
Isolated P4 stays.

### G1fj — hold mid-line wait through sequential next (**landed 2026-08-17**; did not fire)

G1fi clears on presented line `>=` sequential
next (`7a8` t=20450). Hold through that next
line; clear only when fetch is *past* it
(`>`). Not G1fb npc-ahead. Do not pop.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7a2` presented; `7a8` I\|I must not drop the hide |
| **Not** | G1fi `>=` clear. Not G1fb/G1fc npc. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | After a mid-line presentation, dest-FIFO a0-Branch past sequential next waits until fetch is past that next line. |
| **Site** | `instr_queue` `g1fj_wait_q` / `g1fj_hide`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged (`csrrcmt` t=20463,
`766` t=20467). Did not fire (`7b0` t=20457 is
already past `7a8`, clears wait before `7b8`).
Keep. Isolated P4 stays.

### G1fk — hide dest-FIFO a0-Branch until CSR-to-a0 commit (**MINI-FAIL 2026-08-17** — reverted)

G1fi/G1fj clear on the next / next+1 line
before CSR is sighted. After mid-line `[2:1]==01`
presentation, hide dest-FIFO a0-Branch past
sequential next until a CSR-to-a0 *commits*
(or flush). Not line-distance. Not G1fb.
Not G1fh. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7a2` presented; `7bc` stays hidden until `7ac` commits |
| **Not** | G1fi/G1fj line-distance clear. Not G1fb npc. Not G1fh (needs CSR sighted). Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | After a mid-line presentation, dest-FIFO a0-Branch past sequential next waits for a CSR-to-a0 commit. |
| **Site** | Reverted. Do not re-land. Isolated P4 stays. |

Lottery **PASS @562**. FDT printed 0 @400000
(**hang**, not a pass). Restore G1fj.
Do not re-land. Isolated P4 stays.

### G1fl — hide dest-FIFO a0-Branch until next line consumed (**landed 2026-08-17**; did not fire)

G1fi clears on next-line presentation
(`7a8` t=20450). Clear only when that next
line is *consumed* (pushed). Not G1fk
CSR-commit. Not G1fb. Do not pop.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7a2` presented; `7a8` on `valid_i` but not pushed |
| **Not** | G1fi present-clear. Not G1fk CSR-commit. Not G1fb. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | After a mid-line presentation, dest-FIFO a0-Branch past sequential next waits until that next line is consumed. |
| **Site** | `instr_queue` `g1fl_wait_q` / `g1fl_hide`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged (`csrrcmt` t=20463,
`766` t=20467). Did not fire (`7a8` consumed
before `7b8`, or slot0 never `[2:1]==01`).
Keep. Isolated P4 stays.

### G1fm — arm mid-line wait on any slot `[2:1]==01` (**MINI-FAIL 2026-08-17** — reverted)

G1fi–G1fl arm only `valid_i[0]`. `7a2` may be
slot1 of an aligned `7a0` package. Arm on any
presented slot with `[2:1]==01`. Clear like
G1fi. Not G1fk. Not G1fb. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7a2` is slot1; slot0-only arm never fired |
| **Not** | G1fi slot0-only. Not G1fk CSR-commit. Not G1fb. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | A mid-line `[2:1]==01` in any presented slot arms the dest-FIFO a0-Branch wait. |
| **Site** | Reverted. Do not re-land. Isolated P4 stays. |

Lottery **PASS @562**. FDT printed 23 (`0x17` P7)
@1196. Restore G1fl. Do not re-land.
Isolated P4 stays.

### G1fn — TRACE `7bc` commit vs leftover `jal@766` (**landed 2026-08-17**)

No RTL. `7bc` never commits. `7c0` npc is
fetch-ahead (no `pkt7c0` commit). `7b8`
c.beqz commits t=20474. Leftover `jal x0`
`@766` commits t=20476. `a5=0x800071e4`
at `7b8` so `7ba c.jalr` should go to
`generic_cold_boot_allowed`. Isolated P4 stays.

| | |
|--|--|
| **Hits** | thought `7bc` took with stale a0; actually leftover `766` |
| **Not** | G1fm any-slot. Not G1fk. Not G1fb. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Cookie hang is leftover `jal x0@766` after `7b8`, not `7bc` take. |
| **Site** | `trace-lot.spec` commit `7b8`/`7bc`/`7c0`/`766`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. Keep. Isolated P4 stays.

### G1fo — leftover jal x0 waits for dest-FIFO JumpR (**landed 2026-08-17**; did not fire)

G1dc parks `766` after G1en/G1ey release.
Hide leftover `jal x0` while dest-FIFO has
`c.jalr`/`jalr`. Do not pop. Not G1dr. Not
G1ec. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7ba c.jalr` in dest-FIFO; G1dc still parks `766` |
| **Not** | G1dr rd. Not G1ec oldest-PC. Not G1cv. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Leftover `jal x0` waits while dest-FIFO has a JumpR. |
| **Site** | `instr_queue` `g1fo_hide`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged (`7b8` cmt
t=20474, `766` cmt t=20476, no `@71e4`).
Did not fire (`7ba` not in dest-FIFO). Keep.
Isolated P4 stays.

### G1fp — leftover jal x0 waits for presented JumpR (**landed 2026-08-17**; did not fire)

G1fo needs JumpR already queued. Hide leftover
`jal x0` while a JumpR is *presented*
(`instr_i` / `cf JumpR`, even if G1ct zeroed
`valid[1+]`). Do not pop. Not G1dr. Not G1fm.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7ba` on `instr_i`/`cf`; G1dc still parks `766` |
| **Not** | G1fo queued-only. Not G1dr. Not G1fm. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Leftover `jal x0` waits while a JumpR is presented. |
| **Site** | `instr_queue` `g1fp_hide`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged (`766` cmt
t=20476, no `@71e4`). Did not fire (`7ba`
never presented as JumpR). Keep.
Isolated P4 stays.

### G1fq — fill missing aligned compressed slot1 c.jalr from I$ (**landed 2026-08-17**; did not fire)

G1fo/G1fp hide `766` only if JumpR is
queued/presented. If realign left slot1
invalid on an aligned compressed package
whose I$ next halfword is `c.jalr`, fill
it like G1et. `!serving_unaligned` (not
G1es). Not G1eo. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7b8` compressed; I$ `[31:16]` is `c.jalr`; `valid[1]=0` |
| **Not** | G1et I\|I CSR. Not G1es leftover_next. Not G1eo `idx_is`. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | A missing aligned compressed `c.jalr` slot is filled from the registered I$ word. |
| **Site** | `frontend` `g1fq_cjalr` after realign. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged (`766` cmt
t=20476, no `@71e4`). Did not fire (`valid[1]`
already 1, or not that I$ beat). Keep.
Isolated P4 stays.

### G1fr — dest-only beat keeps later-slot JumpR (**landed 2026-08-17**; did not fire)

G1fq only fills when `valid[1]=0`. G1ct
dest-only can still smash an already-valid
slot1 `c.jalr`. Keep those slots (G1eq analog).
Do not exempt G1cz leftover-Jump slot0-only.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | G1ct dest-only beat; slot1 is live `c.jalr`/`jalr` |
| **Not** | G1fq fill. Not G1eq CSR. Not G1cz smash-all. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | A dest-only first beat must not hide a later-slot JumpR. |
| **Site** | `frontend` `g1fr_is_jalr` in `g1ct_valid`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged (`766` cmt
t=20476, no `@71e4`). Did not fire (`7b8` is
not a dest-only smash of live `7ba`). Keep.
Isolated P4 stays.

### G1fs — Branch|JumpR keeps slot1 through IQ branch_mask (**landed 2026-08-17**; did not fire)

G1ct dest-only is not the miss. Same-packet
later-slot JumpR after a Branch (`7b8 c.beqz`)
must not be cut by `branch_mask` (G1er analog).
Not G1eo `idx_is`. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7b8` cf!=NoCF zeros `valid[1]`; `7ba` never pushes |
| **Not** | G1er I\|I CSR. Not G1eq/G1fr frontend hide. Not G1eo. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | An aligned Branch\|JumpR keeps the JumpR slot through `branch_mask`. |
| **Site** | `instr_queue` `g1fs_br_jalr` on `valid`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged (`766` cmt
t=20476, no `@71e4`). Did not fire (`valid_i[1]`
already 0). Keep. Isolated P4 stays.

### G1ft — leftover-Jump slot0-only keeps later-slot JumpR (**landed 2026-08-17**; did not fire)

G1fs needs `valid_i[1]=1`. G1cz leftover-Jump
slot0-only smashes every later slot. Keep a
later-slot JumpR (still hide later li/bne).
Not G1cy. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover-Jump beat; later slot is live `c.jalr` |
| **Not** | G1fr dest-only only. Not G1cz smash-all. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Leftover-Jump slot0-only must not hide a later-slot JumpR. |
| **Site** | `frontend` `g1ct_valid` G1cz path. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2692**. Hold+nat
cookie t=22528. TRACE unchanged (`766` cmt
t=20476, no `@71e4`). Did not fire (`7b8` is
not leftover-Jump with live `7ba`). Keep.
Isolated P4 stays.

### G1fu — fetch pc+2 after slot0-only compressed Branch consume (**landed 2026-08-17**; did not fire)

`7ba` is never valid on the `7b8` beat, and
npc goes `7b8`→`7c0`. After slot0-only
*consume* of an aligned compressed Branch,
step npc to `pc+2` (not +8 hold). Present
same-line I$ from mid-line npc. Isolated P4 stays.

| | |
|--|--|
| **Hits** | only `7b8` consumed; next fetch must be `7ba` |
| **Not** | G1ce/+8 hold. Not G1ep mid-line 01. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Slot0-only consume of an aligned compressed Branch fetches `pc+2`. |
| **Site** | `frontend` `g1fu_plus2` / `g1fu_mid`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2681**. Hold+nat
cookie t=22528. TRACE unchanged (`7c0` t=20465,
`7b8` cmt t=20474). Did not fire (consume is
after the +8 step). Keep. Isolated P4 stays.

### G1fv — npc +2 when aligned compressed Branch is presented slot0-only (**landed 2026-08-17**; did not fire)

G1fu waits for consume (too late). Step npc
to `pc+2` when an aligned compressed Branch
is *presented* slot0-only (`instruction_valid[1]=0`),
not when consumed. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7b8` presented; `valid[1]=0`; npc must be `7ba` |
| **Not** | G1fu consume. Not G1ce/+8 hold. Not leftover keep. Not +8. Not G0. Not I4cg. |
| **Rule** | Presenting an aligned compressed Branch slot0-only fetches `pc+2`. |
| **Site** | `frontend` `g1fv_plus2`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2681**. Hold+nat
cookie t=22528. TRACE unchanged (`7c0` t=20465).
Did not fire (`instruction_valid[1]` still 1, or
not a Branch). Keep. Isolated P4 stays.

### G1fw — npc +2 when IQ view is slot0-only compressed Branch (**landed 2026-08-17**; did not fire)

G1fv uses frontend `instruction_valid[1]`. IQ
sees `g1ct_valid[1]`. Step `pc+2` when the IQ
view is slot0-only. Isolated P4 stays.

| | |
|--|--|
| **Hits** | G1ct smashed `valid[1]`; frontend still has slot1 |
| **Not** | G1fv frontend valid. Not G1fu consume. Not G1ce/+8. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | IQ slot0-only aligned compressed Branch fetches `pc+2`. |
| **Site** | `frontend` `g1fw_plus2`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2681**. Hold+nat
cookie t=22528. TRACE unchanged (`7c0` t=20465).
Did not fire (IQ slot1 still valid, or `7b8`
not `is_branch`, or `bp_valid`). Keep.
Isolated P4 stays.

### G1fx — IQ slot0-only +2 without is_branch (**MINI-FAIL 2026-08-17**; reverted)

G1fw requires `is_branch[0]`. Same IQ
slot0-only +2 without that gate. Isolated
P4 stays. Do not re-land.

| | |
|--|--|
| **Hits** | `7b8` not `is_branch` (cf mash) |
| **Not** | G1fw Branch gate. Not G1ce/+8. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | IQ slot0-only aligned compressed fetches `pc+2`. |
| **Site** | `frontend` `g1fx_plus2`. Isolated P4 stays. |

Lottery **PASS @563**. FDT **printed 42**
(P3 `0x2a` `offset_ptr` NULL) **@584**.
Restore G1fw slfix `83180681` / `eb7c8e21`.
Do not re-land (steps npc +2 on every
aligned compressed slot0-only IQ view;
skips FDT header walk). Isolated P4 stays.

### G1fy — IQ slot0-only +2 gated on rvc_branch (**landed 2026-08-17**; did not fire)

G1fx was too wide (any compressed). Same
IQ slot0-only +2 gated on `rvc_branch[0]`
encoding, not `is_branch` (G1bj may clear
it). Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7b8` `rvc_branch` but G1bj cleared `is_branch` |
| **Not** | G1fx all compressed. Not G1fw `is_branch`. Not G1ce/+8. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | IQ slot0-only aligned `c.beqz`/`c.bnez` fetches `pc+2`. |
| **Site** | `frontend` `g1fy_plus2`. Isolated P4 stays. |

Lottery **PASS @562**. FDT **PASS @2681**. Hold+nat
cookie t=22528. TRACE unchanged (`7c0` t=20465,
`766` cmt t=20476, no `7ba`). Did not fire
(IQ slot1 still valid, or `bp_valid`). Keep.
Isolated P4 stays.

### G1fz — IQ slot0 Branch +2 even if slot1 valid (**MINI-FAIL 2026-08-17**; reverted)

G1fw/G1fy require `!g1ct_valid[1]`. Step
+2 when IQ slot0 is an aligned compressed
Branch even if slot1 is valid. Isolated
P4 stays. Do not re-land.

| | |
|--|--|
| **Hits** | slot1 live at `7b8`; npc still `7c0` |
| **Not** | G1fy slot0-only. Not G1fx all compressed. Not G1ce/+8. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | IQ slot0 aligned compressed Branch fetches `pc+2` even if slot1 is valid. |
| **Site** | `frontend` `g1fz_plus2`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **printed 23**
(P7 `0x17` getprop-shaped) **@200633**.
Restore G1fy slfix `04ac16bb` / `3430deb0`.
Do not re-land (skips later-slot fallthrough
after a compressed Branch). Isolated P4 stays.

### G1ga — IQ slot0 Branch +2 only when slot1 is JumpR (**landed 2026-08-17**; did not fire at OpenSBI)

G1fz was too wide (any slot1). Same
slot0 aligned compressed Branch +2 only
when slot1 is JumpR (`7ba` c.jalr). Isolated
P4 stays.

| | |
|--|--|
| **Hits** | `7b8` Branch + `7ba` JumpR live in IQ view |
| **Not** | G1fz any slot1. Not G1fx all compressed. Not G1ce/+8. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | IQ slot0 compressed Branch + slot1 JumpR fetches `pc+2`. |
| **Site** | `frontend` `g1ga_plus2`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=22528. TRACE unchanged (`7c0` t=20465,
`766` cmt t=20476, no `7ba`). Did not fire at
OpenSBI `7b8` (IQ slot1 not JumpR, or
`bp_valid`). Lottery 557 vs 562: fired on
mini `7b8`-shape. Keep. Isolated P4 stays.

### G1gb — frontend Branch|JumpR +2 (**landed 2026-08-17**; did not fire at OpenSBI)

G1ga uses `g1ct_valid`. Frontend
`instruction_valid` may still show
Branch|JumpR when IQ smash hid slot1.
Same +2 on the frontend view. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | frontend `7b8` Branch + `7ba` JumpR; IQ hid slot1 |
| **Not** | G1ga IQ valid. Not G1fz any slot1. Not G1fx. Not G1ce/+8. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | Frontend slot0 compressed Branch + slot1 JumpR fetches `pc+2`. |
| **Site** | `frontend` `g1gb_plus2`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=22528. TRACE unchanged (`7c0` t=20465,
`766` cmt t=20476, no `7ba`). Did not fire at
OpenSBI `7b8` (frontend slot1 not JumpR, or
`serving_unaligned`, or `bp_valid`). Keep.
Isolated P4 stays.

### G1gc — frontend Branch|JumpR +2 even when leftover (**landed 2026-08-17**; did not fire at OpenSBI)

G1gb requires `!serving_unaligned`.
`7b8` may be on the leftover path.
Same frontend Branch|JumpR +2 even when
serving leftover. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover-serve `7b8` Branch + `7ba` JumpR |
| **Not** | G1gb `!serving_unaligned`. Not G1fz any slot1. Not G1fx. Not G1ce/+8. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | Frontend Branch\|JumpR fetches `pc+2` even on leftover serve. |
| **Site** | `frontend` `g1gc_plus2`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=22528. TRACE unchanged (`7c0` t=20465,
`766` cmt t=20476, no `7ba`). Did not fire at
OpenSBI `7b8` (slot1 not JumpR, or `bp_valid`
blocked +2). Keep. Isolated P4 stays.

### G1gd — frontend Branch|JumpR +2 even when bp_valid (**landed 2026-08-17**; TRACE flip)

All +2 gates required `!bp_valid`.
Not-taken `7b8` still raised `bp_valid`
with predict=`7c0`. Same frontend
Branch|JumpR +2 even when `bp_valid`.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7b8` Branch\|`7ba` JumpR; `bp_valid` predict `7c0` |
| **Not** | G1gc leftover-only. Not G1fz any slot1. Not G1fx. Not G1ce/+8. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | Frontend Branch\|JumpR fetches `pc+2` even if `bp_valid`. |
| **Site** | `frontend` `g1gd_plus2`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
**cookie t=96256** `51b1babe`+`51b1d000`. TRACE
**flipped** (authoritative):
`7ba` npc @20467, **`7ba` cmt @20475**, `7bc`
bnez cmt @20504, `7be` cmt @20514, **pkt7c0
@20520**, **scratch @38e0 @20519**, BANR
`[1068]=42414e52`, `last_hartidx=7f` `ra=7d2`.
No `71e4` after `7ba` cmt (leftover `766`
still fetched @20470). `plat_hc=80`. Keep.
Isolated P4 stays.

### G1ge — after JumpR commit accept target I$ even if leftover jal unconsumed (**landed 2026-08-17**; did not fire)

`7ba` c.jalr commits but does not
redirect to `71e4`. After a usable JumpR
resolve, lift `g1cv`/`g1fa` for that
target and keep npc there while leftover
jal is unconsumed. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7ba` JumpR resolve; leftover `766` holds `71e4` I$ |
| **Not** | G1cv general accept. Not G1fz. Not G1fx. Not G1ce/+8. Not leftover keep. Not G0. Not I4cg. |
| **Rule** | Committed usable JumpR target is fetched even if leftover jal is unconsumed. |
| **Site** | `frontend` `g1ge_wait_q` / `g1ge_lift`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=96256. TRACE unchanged vs G1gd (no
`@71e4` after `7ba` cmt @20475). Did not
fire (`7ba` cmt is not a usable JumpR
resolve). Keep. Isolated P4 stays.

### G1gf — stall jalr until rs1 is a usable pointer (**HOLD-FAIL 2026-08-17**; reverted)

G1ge arms only on usable JumpR resolve.
Stall jalr until rs1 is a usable pointer.
Isolated P4 stays. Do not re-land.

| | |
|--|--|
| **Hits** | `7ba` jalr with a5=0 at execute |
| **Not** | G0 all address-use. Not G1i unresolved_a0. Not G1fz. Not G1ce/+8. Not leftover keep. Not I4cg. |
| **Rule** | jalr issues only if rs1 is a usable pointer. |
| **Site** | `issue_read_operands` stall + RF prefer. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
**no cookie** after ~6 min (jalr stall hung
OpenSBI). Restore G1ge slfix `af3f2564` /
`d00a88ea`. Do not re-land (G0/G1i class).
Isolated P4 stays.

### G1gg — jalr prefer usable RF over unusable forward, no stall (**landed 2026-08-17**; did not fire)

G1gf stall was too wide. Same jalr
usable-RF prefer over unusable forward,
no stall. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `7ba` jalr; forward a5=0; RF a5=`71e4` |
| **Not** | G1gf stall. Not G0. Not G1i. Not G1fz. Not G1ce/+8. Not leftover keep. Not I4cg. |
| **Rule** | jalr uses RF rs1 if the forward is unusable and RF is usable. |
| **Site** | `issue_read_operands` forward mux. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=96256. TRACE unchanged vs G1gd (no
`@71e4` after `7ba` cmt). Did not fire
(forward already usable, or RF also
unusable). Keep. Isolated P4 stays.

### G1gh — leftover jal x0 must not issue while same-hart jalr uncommitted (**landed 2026-08-17**; did not fire at 20470)

`7ba` still commits without `@71e4`.
Leftover jal x0 waits for same-hart jalr
commit. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover `766` issues beside uncommitted `7ba` |
| **Not** | G1gf stall jalr. Not G1fo dest-FIFO hide. Not G0. Not G1fz. Not G1ce/+8. Not I4cg. |
| **Rule** | leftover jal x0 issues only after same-hart jalr commits. |
| **Site** | `g6lc_issue_barrier` `stall_leftover_jal_x0`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=96256. TRACE unchanged (`766` still
fetched @20470; `j766cmt` 31788 vs 31787).
Did not fire at the fetch (frontend leftover,
not issue). Keep. Isolated P4 stays.

### G1gi — do not present leftover jal x0 while jalr in flight (**landed 2026-08-17**; did not fire at 20470)

G1gh is issue-only. Hide leftover jal x0
when a jalr was presented. Isolated P4
stays.

| | |
|--|--|
| **Hits** | leftover `766` present while `7ba` jalr in flight |
| **Not** | G1gh issue stall. Not G1gf. Not G1fo dest-FIFO. Not G0. Not G1fz. Not I4cg. |
| **Rule** | leftover jal x0 is not presented while a jalr is in flight. |
| **Site** | `frontend` `g1gi_hide`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=96256. TRACE unchanged (`766` still
fetched @20470 before `7ba` presents). Did
not fire. Keep. Isolated P4 stays.

### G1gj — do not present leftover jal x0 while npc is mid-line 01 (**landed 2026-08-17**; did not fire at 20470)

G1gi needs jalr on the present bus.
Hide leftover jal x0 while npc is
`[2:1]==01`. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover `766` while npc is `7ba` |
| **Not** | G1gi jalr-on-bus. Not G1gf. Not G1gh. Not G0. Not G1fz. Not I4cg. |
| **Rule** | leftover jal x0 is not presented while npc is mid-line 01. |
| **Site** | `frontend` `g1gj_hide`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=96256. TRACE unchanged (`766` still
@20470; npc already `766` that beat, not
`7ba`). Did not fire. Keep. Isolated P4 stays.

### G1gk — hold leftover jal x0 hide after mid-line 01 (**landed 2026-08-17**; did not fire at 20470)

G1gj needs npc still `01` on the leftover
beat. Hold leftover jal x0 hide 3 cycles
after a mid-line 01 npc. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover `766` after npc left `7ba` |
| **Not** | G1gj same-cycle 01. Not G1gf. Not G1ce/+8. Not I4cg. |
| **Rule** | leftover jal x0 is not presented for 3 cycles after npc was mid-line 01. |
| **Site** | `frontend` `g1gk_cnt_q`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=96256. TRACE unchanged (`766` still
@20470). Hide needs leftover presenting
(`g1gi_lj`); hangj is npc replay to `766`.
Did not fire. Keep. Isolated P4 stays.

### G1gl — do not reseed npc to leftover-PC replay after mid-line 01 (**landed 2026-08-17**; did not fire at 20470)

G1gk hide needs leftover presenting.
`766` @20470 is npc via leftover-Jump
replay (G1az). Block that reseed after
mid-line 01. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover-PC replay steals npc after G1gd +2 |
| **Not** | G1gk present-hide. Not G1ce/+8. Not G1gf. Not I4cg. |
| **Rule** | leftover-PC replay does not reseed npc for 3 cycles after npc was mid-line 01. |
| **Site** | `frontend` `g1gl_block`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=96256. TRACE unchanged (`766` still
@20470). Counter/flush miss, or npc is not
leftover-PC replay. Did not fire. Keep.
Isolated P4 stays.

### G1gm — do not reseed npc to leftover-PC replay while jalr seen (**landed 2026-08-17**; did not fire at 20470)

G1gl needs `g1gk_cnt`. Block leftover-PC
replay while a jalr has been seen.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover-PC replay after jalr present / flush cleared cnt |
| **Not** | G1gl cnt gate. Not G1ce/+8. Not G1gf. Not I4cg. |
| **Rule** | leftover-PC replay does not reseed npc while a jalr has been seen. |
| **Site** | `frontend` `g1gm_block`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=96256. TRACE unchanged (`766` still
@20470). npc is not leftover-PC replay
(`[2:1]==11`). Did not fire. Keep.
Isolated P4 stays.

### G1gn — leftover-PC predict must not reseed npc after mid-line 01 / jalr seen (**HOLD-FAIL 2026-08-17** — reverted)

G1gl/G1gm blocked leftover-PC replay
and hangj @20470 stayed. Skip `bp_valid`
npc reseed when predict is leftover-PC
(`[2:1]==11`) after mid-line 01 / while
jalr seen. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `bp_valid` predict `766` after G1gd +2 |
| **Not** | G1gl/G1gm replay. Not G1ce/+8. Not G1bq `!kill_s2`. Not I4cg. |
| **Rule** | leftover-PC predict does not reseed npc after mid-line 01 / jalr seen. |
| **Site** | `frontend` `g1gn_block` on `npc_select`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
**no cookie** ~6 min (preload only).
`bp_valid` still raised `kill_s2` and
starved OpenSBI fetch. Restore G1gm
`bb0fe736` / `5cb7023d`. Do not re-land
(G1bq/G1bt `kill_s2` class). Isolated
P4 stays.

### G1go — leftover-PC is not a predicted target after mid-line 01 / jalr seen (**HOLD-FAIL 2026-08-17** — reverted)

G1gn skipped npc only. Clear `bp_valid`
when predict is leftover-PC so `kill_s2`
does not fire. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover-PC `bp_valid` after G1gd +2 |
| **Not** | G1gn npc-only skip. Not G1bq leftover `!kill_s2`. Not G1by/G1bz. Not I4cg. |
| **Rule** | leftover-PC is not a predicted target after mid-line 01 / jalr seen. |
| **Site** | `frontend` `bp_valid` clear. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
**no cookie** ~2 min (preload only).
Leftover-PC predict is load-bearing.
Restore G1gm. Do not re-land G1go/G1gn.
Isolated P4 stays.

### G1gp — jalr resolve uses usable RF when operand_a is unusable (**landed 2026-08-17**; did not fire at 7ba)

G1gn/G1go closed leftover-PC predict.
`7ba` commits @20475 with no `@71e4`.
IRO stashes RF rs1 in `operand_b`; EX
uses it as jump_base when `operand_a`
is unusable. Isolated P4 stays.

| | |
|--|--|
| **Hits** | JALR EX target 0 while RF rs1 is `71e4` |
| **Not** | G1gg IRO mux-only. Not G1gf stall. Not G1gn/G1go. Not I4cg. |
| **Rule** | JALR resolve takes a usable RF rs1 when the issued operand is unusable. |
| **Site** | `issue_read_operands` `operand_b` stash + `branch_unit` jump_base. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=96256. TRACE unchanged (`7ba` cmt
@20475, no `@71e4` after). RF at issue
was already the operand or also unusable,
or `7ba` is not JALR at EX. Did not fire.
Keep. Isolated P4 stays.

### G1gq — committed JALR redirects to RF[rs1] after unusable JumpR resolve (**landed 2026-08-17**; did not fire at 7ba)

G1gp is issue-time RF. At `7ba` commit
architectural a5 is `71e4`. Redirect a
committed JALR to RF[rs1] when a prior
JumpR resolve was unusable and npc is
not already on that line. Isolated P4
stays.

| | |
|--|--|
| **Hits** | JALR commits after E2-suppressed JumpR; RF rs1 usable |
| **Not** | G1gf stall. Not G1gg/G1gp issue. Not G1gn/G1go. Not I4cg. |
| **Rule** | committed JALR takes usable RF[rs1] if an unusable JumpR is pending and npc is elsewhere. |
| **Site** | `issue_stage` `g1gq_pend_q` + IRO RF peek; `cva6` mux into frontend/controller. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=96256. TRACE unchanged (`7ba` cmt
@20475, no `@71e4` after). Pend did not
arm — `7ba` is not an unusable JumpR
resolve (likely not JALR at EX). Did not
fire. Keep. Isolated P4 stays.

### G1gr — committed JALR redirects to RF[rs1] without EX JumpR pend (**MINI-FAIL 2026-08-17** — reverted)

G1gq needs EX `cf==JumpR` to arm.
`7ba` commits without that resolve.
Same commit redirect without the pend.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | JALR commits; RF rs1 usable; npc not on target |
| **Not** | G1gq EX pend. Not G1gf stall. Not G1gn/G1go. Not I4cg. |
| **Rule** | committed JALR takes usable RF[rs1] if npc is not on that line. |
| **Site** | `issue_stage` `g1gq_redir_o` without `g1gq_pend_q`. Isolated P4 stays. |

Lottery **PASS @588**. FDT **printed 42** (P3
`0x2a` `offset_ptr` NULL) **@782**.
**MINI-FAIL**. Restore G1gq `bd160664` /
`b3b1b394`. Do not re-land (too wide:
yanks live jalr). Isolated P4 stays.

### G1gs — JALR resolve is JumpR even if RAS tagged Return (**landed 2026-08-17**; did not fire at 7ba)

G1gr closed commit-without-pend.
`7ba` still does not resolve as JumpR.
Force JALR `cf_type=JumpR` so G1gq
can arm. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `c.jalr` a5 predicted Return; G1gq pend never arms |
| **Not** | G1gr commit-without-pend. Not G1gf stall. Not I4cg. |
| **Rule** | JALR resolve is JumpR (not Return). |
| **Site** | `branch_unit` `cf_type` override. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=96256. TRACE unchanged (`7ba` cmt
@20475, no `@71e4`). Did not fire —
`7ba` is not `op==JALR` at EX. Keep.
Isolated P4 stays.

### G1gt — recover high-half c.jalr from leftover-RVI mash (**MINI-FAIL 2026-08-17** — reverted)

G1gs needs `op==JALR`. Recover a
presented high-half `c.jalr` encoding
as compressed JALR (G1ba analog).
Isolated P4 stays.

| | |
|--|--|
| **Hits** | 32-bit RVI mash with high-half `c.jalr` at `7ba` |
| **Not** | G1ba `c.li`. Not G1gr. Not G1gs EX cf. Not I4cg. |
| **Rule** | leftover-RVI mash whose high half is `c.jalr` decodes as jalr. |
| **Site** | `compressed_decoder` default/RVI path. Isolated P4 stays. |

Lottery **PASS @557**. FDT **hang @400000**
(harness SUCCESS tohost=0 is a hang).
**MINI-FAIL**. Restore G1gs `2c73cca5`
/ `e8657e7f`. Do not re-land (too wide:
any RVI with a `c.jalr`-shaped high
half). Isolated P4 stays.

### G1gu — recover high-half c.jalr only when low is RVI BRANCH (**landed 2026-08-17**; did not fire at 7ba)

G1gt recovered high-half `c.jalr` from
*any* RVI mash. Same recover only when
the low half is RVI BRANCH (G1ba gate).
Isolated P4 stays.

| | |
|--|--|
| **Hits** | `{c.jalr_hi, BRANCH_lo}` mash at `7ba` |
| **Not** | G1gt any-RVI. Not G1ba `c.li`. Not G1gr. Not I4cg. |
| **Rule** | leftover-RVI BRANCH mash whose high half is `c.jalr` decodes as jalr. |
| **Site** | `compressed_decoder` default/RVI path. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=96256. TRACE unchanged (`7ba` cmt
@20475, no `@71e4`). Did not fire —
`7ba` is not `{c.jalr, BRANCH}` RVI mash.
Keep. Isolated P4 stays.

### G1gv — recover mid-line C2 c.jalr when [6:2] mashed to c.add (**MINI-FAIL 2026-08-17** — reverted)

G1gu needs an RVI BRANCH low half.
`7ba` is mid-line `[2:1]==01`. Recover
C2 `c.jalr` when `pc[2:1]==01` and
`[12]==1` / `rs1!=0` even if `[6:2]!=0`.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | mashed `c.jalr` at mid-line presents as `c.add` |
| **Not** | G1gt any-RVI. Not G1gu BRANCH mash. Not G1gr. Not I4cg. |
| **Rule** | mid-line C2 with `[12]==1` and `rs1!=0` is `c.jalr`. |
| **Site** | `compressed_decoder` C2 path + fetch PC. Isolated P4 stays. |

Lottery **PASS @557**. FDT **printed 46**
**@616**. **MINI-FAIL**. Restore G1gu
`224772b3` / `64ceb111`. Do not re-land
(real `c.add` at `pc[2:1]==01`). Isolated
P4 stays.

### G1gw — mid-line exact c.jalr encoding forces JALR (**landed 2026-08-17**; did not fire at 7ba)

G1gv closed mid-line any-`c.add`.
Force `op==JALR` when the presented
16-bit encoding is already `c.jalr`
at `pc[2:1]==01`. Isolated P4 stays.

| | |
|--|--|
| **Hits** | mid-line `c.jalr` bits do not expand |
| **Not** | G1gv `[6:2]` mash. Not G1gt any-RVI. Not G1gr. Not I4cg. |
| **Rule** | mid-line 16-bit `c.jalr` encoding is jalr. |
| **Site** | `id_stage` after `compressed_decoder`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2681**. Hold+nat
cookie t=96256. TRACE unchanged (`7ba` cmt
@20475, no `@71e4`). Did not fire —
fetch entry is not that 16-bit, or it
already expands and the hole is later
(IQ/issue `op`). Keep. Isolated P4 stays.

### G1gx — mid-line slot0 is the 16-bit at that PC (**landed 2026-08-17**; did not fire at 7ba)

G1gw needs fetch_entry at `7ba` to
be the 16-bit `c.jalr`, not leftover-
complete `{data[15:0], leftover}` or
an unshifted 32-bit word. Shift
same-line I$ so realign halfword 0
is at npc, and do not leftover-
complete onto mid-line `[2:1]==01`.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | mid-line present is leftover-complete / unshifted 32-bit |
| **Not** | G1gv mash. Not G1es I\|I starve. Not G1bf aligned-only. Not I4cg. |
| **Rule** | Mid-line slot0 is the 16-bit at that PC. |
| **Site** | `frontend` `g1gx_data` + `instr_realign` leftover_next mid-line. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2691**. Hold+nat
cookie t=96256 + BANR. TRACE unchanged (`7ba` cmt
@20475, hangj `766` @20470, no `@71e4` after
`7ba`). Did not fire — `7ba` is already that
16-bit, or the committed `7ba` is not this
present path (IQ/issue `op`). Keep. Isolated
P4 stays.

### G1gy — mid-line either-half exact c.jalr forces JALR (**landed 2026-08-17**; did not fire at 7ba)

G1gw sees only the low 16-bit.
Unshifted `{c.jalr, c.beqz}` at `7ba`
has `c.jalr` in the high half. Force
jalr when mid-line fetch_entry has
exact `c.jalr` in either half. Not
G1gt any-RVI. Not G1gu BRANCH-low.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | mid-line 32-bit word; high half is exact `c.jalr` |
| **Not** | G1gt any-RVI. Not G1gu BRANCH-low. Not G1gv `[6:2]` mash. Not I4cg. |
| **Rule** | Mid-line exact `c.jalr` in either half is jalr. |
| **Site** | `id_stage` after `compressed_decoder` (extends G1gw). Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2691**. Hold+nat
cookie t=96256 + BANR. TRACE unchanged (`7ba` cmt
@20475, hangj `766` @20470, no `@71e4` after
`7ba`). Did not fire — fetch_entry at `7ba`
has `c.jalr` in neither half (wrong
halfword / high zeroed). Keep. Isolated
P4 stays.

### G1gz — mid-line slot0 from I$ +2 halfword (**MINI-FAIL 2026-08-17** — reverted)

G1gy never saw `c.jalr` bits at `7ba`.
When slot0 PC is mid-line, take the
registered I$ +2 halfword. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | mid-line slot0 is the wrong 16-bit |
| **Not** | G1gx leftover-complete. Not G1gv mash. Not I4cg. |
| **Rule** | Mid-line slot0 is the I$ line's +2 halfword. |
| **Site** | `frontend` after realign. Isolated P4 stays. |

Lottery **printed 2 @411**. FDT **printed 90
@1082**. **MINI-FAIL**. Restore G1gy
`d40e1602` / `d18379f1` (bit-identical).
Do not re-land (yanks live mid-line
slot0). Isolated P4 stays.

### G1ha — I$ +2 halfword only when exact c.jalr (**landed 2026-08-17**; did not fire at 7ba)

G1gz yanked every mid-line slot0.
Same I$ +2 halfword only when that
halfword is exact `c.jalr`. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | mid-line slot0; I$ +2 is exact `c.jalr` |
| **Not** | G1gz all mid-line. Not G1gv mash. Not I4cg. |
| **Rule** | Mid-line slot0 is I$ +2 only if that halfword is `c.jalr`. |
| **Site** | `frontend` after realign. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2691**. Hold+nat
cookie t=96256 + BANR. TRACE unchanged (`7ba` cmt
@20475, hangj `766` @20470, no `@71e4` after
`7ba`). Did not fire — `7ba` is not mid-line
slot0 (it is slot1 of `7b8`, or already in
IQ). Keep. Isolated P4 stays.

### G1hb — slot1 from I$ +2 exact c.jalr even if valid (**landed 2026-08-17**; did not fire at 7ba)

G1ha is slot0-only. G1fq fills slot1
only when `valid[1]=0`. Force slot1
from I$ +2 exact `c.jalr` even when
slot1 is already valid. Isolated P4 stays.

| | |
|--|--|
| **Hits** | aligned compressed slot0; I$ +2 is `c.jalr`; slot1 already valid |
| **Not** | G1fz any slot1. Not G1gz slot0. Not G1es leftover_next. Not I4cg. |
| **Rule** | Slot1 is I$ +2 exact `c.jalr` even if already valid. |
| **Site** | `frontend` `g1fq_cjalr` (drop `!valid[1]`). Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2691**. Hold+nat
cookie t=96256 + BANR. TRACE unchanged (`7ba` cmt
@20475, hangj `766` @20470, no `@71e4` after
`7ba`). Did not fire — `7b8` beat is
`serving_unaligned` (G1fq/G1hb gated), or
slot1 was already that `c.jalr`. Keep.
Isolated P4 stays.

### G1hc — leftover-complete beat still presents I$ +2 c.jalr as slot1 (**landed 2026-08-17**; did not fire at 7ba)

G1hb is gated `!serving_unaligned`
and aligned slot0. Leftover-complete
slot0 is `[2:1]==11`. Fill slot1 from
I$ +2 exact `c.jalr`; slot0 stays
leftover. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover-complete on a line whose +2 is `c.jalr` |
| **Not** | G1es I\|I starve (do not steal leftover slot0). Not G1gz. Not I4cg. |
| **Rule** | Leftover-complete still presents I$ +2 `c.jalr` as slot1. |
| **Site** | `frontend` `g1hc_cjalr`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2691**. Hold+nat
cookie t=96256 + BANR. TRACE unchanged (`7ba` cmt
@20475, hangj `766` @20470, no `@71e4` after
`7ba`). Did not fire — leftover-complete is
not on that beat, or +2 is not `c.jalr` in
registered I$. Keep. Isolated P4 stays.

### G1hd — issued op is JALR when mid-line fetch has exact c.jalr (**landed 2026-08-17**; did not fire at 7ba)

Present-path family (G1gw–G1hc) did
not move `7ba`. Force issued `op==JALR`
when PC is mid-line and fetch_entry
has exact `c.jalr` in either half
(G1gy analog after ID). Isolated P4 stays.

| | |
|--|--|
| **Hits** | ID expand lost before issue; mid-line bits are `c.jalr` |
| **Not** | G1gt any-RVI. Not G1gz. Not I4cg. |
| **Rule** | Mid-line exact `c.jalr` bits issue as JALR. |
| **Site** | `id_stage` `decoded_hd` into `issue_n`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2691**. Hold+nat
cookie t=96256 + BANR. TRACE unchanged (`7ba` cmt
@20475, hangj `766` @20470, no `@71e4` after
`7ba`). Did not fire — fetch_entry at `7ba`
still has `c.jalr` in neither half (same as
G1gy). Keep. Isolated P4 stays.

### G1he — mid-line CTRL_FLOW usable-RF is JumpR (**MINI-FAIL 2026-08-17** — reverted)

ID/present never see `c.jalr` bits at
`7ba`. EX treats mid-line issued
CTRL_FLOW as JumpR when RF operand is
usable. Isolated P4 stays.

| | |
|--|--|
| **Hits** | mid-line `7ba` issued as Branch/Jump with usable RF |
| **Not** | G1gr commit redirect. Not G1gv. Not I4cg. |
| **Rule** | Mid-line CTRL_FLOW with usable RF is JumpR. |
| **Site** | `branch_unit` after G1gs. Isolated P4 stays. |

Lottery **PASS @557**. FDT **hang @400000**
(tohost=0). **MINI-FAIL**. Restore G1hd
`0805f6b0` / `77d6c7ff` (bit-identical).
Do not re-land (yanks live mid-line
Branch). Isolated P4 stays.

### G1hf — mid-line !Branch usable-RF is JumpR (**landed 2026-08-17**; did not fire at 7ba)

G1he yanked live mid-line Branch.
Same JumpR only when the issued op
is not a Branch. Isolated P4 stays.

| | |
|--|--|
| **Hits** | mid-line JAL/JALR-as-ADD with usable RF |
| **Not** | G1he all CTRL_FLOW. Not G1gr. Not I4cg. |
| **Rule** | Mid-line non-Branch CTRL_FLOW with usable RF is JumpR. |
| **Site** | `branch_unit` after G1gs. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2691**. Hold+nat
cookie t=96256 + BANR. TRACE unchanged (`7ba` cmt
@20475, hangj `766` @20470, no `@71e4` after
`7ba`). Did not fire — `7ba` is a Branch at
EX (`op_is_branch`). Keep. Isolated P4 stays.

### G1hg — mid-line Branch orig_instr exact c.jalr is JumpR (**landed 2026-08-17**; did not fire at 7ba)

`7ba` is a Branch at EX. JumpR only
when that mid-line Branch's
`orig_instr` is exact `c.jalr`. Carry
the 16-bit in `operand_c_hi`. Not
G1he all Branch. Isolated P4 stays.

| | |
|--|--|
| **Hits** | mid-line Branch whose orig 16-bit is `c.jalr` |
| **Not** | G1he all Branch. Not G1hf !Branch. Not I4cg. |
| **Rule** | Mid-line Branch with exact `c.jalr` orig is JumpR. |
| **Site** | `issue_read_operands` `operand_c_hi` + `branch_unit`. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2691**. Hold+nat
cookie t=96256 + BANR. TRACE unchanged (`7ba` cmt
@20475, hangj `766` @20470, no `@71e4` after
`7ba`). Did not fire — `7ba` orig 16-bit is
not exact `c.jalr` (same bits as G1gy/G1hd).
Keep. Isolated P4 stays.

### G1hh — any mid-line 01 slot from I$ +2 exact c.jalr (**landed 2026-08-17**; did not fire at 7ba)

`7ba` is a mid-line Branch whose
presented bits are not `c.jalr`.
Fill **any** slot at `[2:1]==01` from
I$ +2 when that halfword is exact
`c.jalr`. Not G1ha slot0-only. Not
G1hc leftover-complete slot1-only.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | valid mid-line slot; I$ +2 is exact `c.jalr`; same line |
| **Not** | G1ha slot0-only. Not G1hc leftover slot1. Not G1gz. Not I4cg. |
| **Rule** | Any mid-line 01 slot is I$ +2 exact `c.jalr`. |
| **Site** | `frontend` after G1ha. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2691**. Hold+nat
cookie t=96256 + BANR. TRACE unchanged (`7ba` cmt
@20475, hangj `766` @20470, no `@71e4` after
`7ba`). Did not fire — no same-line slot at
`[2:1]==01` while I$ +2 is exact `c.jalr`
(leftover `766` I$ is registered at present).
Keep. Isolated P4 stays.

### G1hi — mid-line 01 from I$ +2 exact c.jalr without same-line (**landed 2026-08-18**; did not fire at 7ba)

G1hh same-line missed because leftover
`766` I$ is live when `7ba` presents.
Fill a mid-line 01 slot from I$ +2
exact `c.jalr` **without** the same-line
check. Not G1gz. Isolated P4 stays.

| | |
|--|--|
| **Hits** | valid mid-line 01 slot; live I$ +2 is exact `c.jalr` |
| **Not** | G1hh same-line. Not G1gz. Not I4cg. |
| **Rule** | Mid-line 01 slot is live I$ +2 exact `c.jalr`. |
| **Site** | `frontend` G1hh without same-line. Isolated P4 stays. |

Lottery **PASS @557**. FDT **PASS @2691**. Hold+nat
cookie t=96256 + BANR. TRACE unchanged (`7ba` cmt
@20475, hangj `766` @20470, no `@71e4` after
`7ba`). Did not fire — leftover `766` I$ +2
is not exact `c.jalr`, so `g1ha_cjalr` is
false when `7ba` presents. Keep. Isolated
P4 stays.

### G1hj — stash aligned I$ +2 exact c.jalr; fill mid-line 01 (**landed 2026-08-18**; did not fire at 7ba)

Live I$ at `7ba` present is leftover
`766`, not the `7b8` line. Stash the
last aligned I$ `[31:16]` exact
`c.jalr` and fill a mid-line 01 slot
from that stash. Not G1hi live I$.
Not G1gz. Isolated P4 stays.

| | |
|--|--|
| **Hits** | earlier aligned line +2 is `c.jalr`; later mid-line 01 slot |
| **Not** | G1hi live I$. Not G1gz. Not line-start `c.jalr` (750). Not I4cg. |
| **Rule** | Mid-line 01 slot is the last stashed aligned I$ +2 `c.jalr`. |
| **Site** | `frontend` `g1hj_v_q` / `g1hj_hw_q`. Isolated P4 stays. |

Lottery **PASS @553** (was 557). FDT **PASS
@2691**. Hold+nat cookie t=96256 + BANR.
TRACE unchanged (`7ba` cmt @20475, hangj
`766` @20470, no `@71e4` after `7ba`).
Did not fire at `7ba` — no valid `[2:1]==01`
slot while the stash is live (npc `7ba`
@20467 is not a present slot). Keep.
Isolated P4 stays.

### G1hk — present slot0 at npc from stash when npc mid-line 01 (**landed 2026-08-18**; did not fire at 7ba)

G1hj only rewrites an existing mid-line
01 slot. npc is `7ba` @20467 with no
such slot. Present slot0 at npc from
the stash when npc `[2:1]==01`. Do not
steal leftover-complete slot0. Not
G1ha live I$. Not G1gz. Isolated P4
stays.

| | |
|--|--|
| **Hits** | stash live; npc `[2:1]==01`; no leftover-complete slot0 |
| **Not** | G1ha live I$. Not G1hj rewrite-only. Not G1gz. Not I4cg. |
| **Rule** | Mid-line npc presents slot0 from the stashed I$ +2 `c.jalr`. |
| **Site** | `frontend` after G1hj. Isolated P4 stays. |

Lottery **PASS @553**. FDT **PASS @2691**.
Hold+nat cookie t=96256 + BANR. TRACE
unchanged (`7ba` cmt @20475, hangj `766`
@20470, no `@71e4` after `7ba`). Did not
fire — leftover-complete slot0 is live
at npc `7ba` @20467 (G1hk skips that
beat). Keep. Isolated P4 stays.

### G1hl — leftover-complete slot1 from stash at npc mid-line 01 (**landed 2026-08-18**; did not fire at 7ba)

G1hk will not steal leftover-complete
slot0. On that beat present the stash
as **slot1** at npc (G1hc analog, stash
not live I$). Slot0 stays leftover.
Not G1es. Not G1gz. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover-complete slot0; stash live; npc `[2:1]==01` |
| **Not** | G1hc live I$. Not G1hk slot0. Not G1es. Not G1gz. Not I4cg. |
| **Rule** | Leftover-complete still presents stash `c.jalr` as slot1 at npc. |
| **Site** | `frontend` after G1hk. Isolated P4 stays. |

Lottery **PASS @553**. FDT **PASS @2691**.
Hold+nat cookie t=96256 + BANR. TRACE
unchanged (`7ba` cmt @20475, hangj `766`
@20470, no `@71e4` after `7ba`). Did not
fire — npc `7ba` @20467 and leftover
`766` @20470 are different cycles.
Keep. Isolated P4 stays.

### G1hm — leftover-complete slot1 at stashed +2 PC (**landed 2026-08-18**; did not fire at 7ba)

G1hl needs leftover-complete and npc
`01` in the same cycle. Carry the
stashed +2 PC and present slot1 at
that PC on leftover-complete **without**
npc `[2:1]==01`. Slot0 stays leftover.
Not G1es. Not G1gz. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover-complete slot0; stash live (any npc) |
| **Not** | G1hl npc `01`. Not G1es. Not G1gz. Not I4cg. |
| **Rule** | Leftover-complete presents stash `c.jalr` as slot1 at the stashed +2 PC. |
| **Site** | `frontend` `g1hj_pc_q` after G1hl. Isolated P4 stays. |

Lottery **PASS @553**. FDT **PASS @2691**.
Hold+nat cookie t=96256 + BANR. TRACE
unchanged (`7ba` cmt @20475, hangj `766`
@20470, no `@71e4` after `7ba`). Did not
fire — stash empty (`g1hj_cap` needs
vaddr `[2:1]==00`; `7b8` I$ is not that
aligned). Keep. Isolated P4 stays.

### G1hn — capture I$ [31:16] exact c.jalr even if vaddr not aligned (**landed 2026-08-18**; did not fire at 7ba)

Capture I$ `[31:16]` exact `c.jalr`
even when vaddr is not line-aligned
(`g1ha_v01!=00`). Still +2 of the
registered word, not line-start
`[15:0]`. Not G1gz. Isolated P4 stays.

| | |
|--|--|
| **Hits** | mid-line I$ request; `[31:16]` is exact `c.jalr` |
| **Not** | G1hj vaddr `00` only. Not line-start `[15:0]`. Not G1gz. Not I4cg. |
| **Rule** | Any registered I$ `[31:16]` exact `c.jalr` is stashed. |
| **Site** | `frontend` `g1hj_cap` drop `g1ha_v01==00`. Isolated P4 stays. |

Lottery **PASS @553**. FDT **PASS @2691**.
Hold+nat cookie t=96256 + BANR. TRACE
unchanged (`7ba` cmt @20475, hangj `766`
@20470, no `@71e4` after `7ba`). Did not
fire — registered `[31:16]` is still not
exact `c.jalr` (shifted mid-line puts
`c.jalr` in `[15:0]`). Keep. Isolated
P4 stays.

### G1ho — capture [15:0] exact c.jalr when vaddr mid-line 01 (**landed 2026-08-18**; did not fire at 7ba)

Also capture `[15:0]` exact `c.jalr`
when vaddr `[2:1]==01` (shifted mid-
line). Not line-start `750` (`vaddr==00`).
Not G1gz. Isolated P4 stays.

| | |
|--|--|
| **Hits** | mid-line I$ request; `[15:0]` is exact `c.jalr` |
| **Not** | G1hn `[31:16]` only. Not `750` line-start. Not G1gz. Not I4cg. |
| **Rule** | Mid-line registered `[15:0]` exact `c.jalr` is stashed. |
| **Site** | `frontend` `g1ho_lo`. Isolated P4 stays. |

Lottery **PASS @553**. FDT **PASS @2691**.
Hold+nat cookie t=96256 + BANR. TRACE
unchanged (`7ba` cmt @20475, hangj `766`
@20470, no `@71e4` after `7ba`). Did not
fire — unshifted I$ has exact `c.jalr`
in neither half. Keep. Isolated P4
stays.

### G1hp — capture exact c.jalr from g1gx_data either half (**landed 2026-08-18**; did not fire at 7ba)

Capture exact `c.jalr` from
`g1gx_data` (the shifted present
word) in either half. Unshifted
`icache_data_q` never shows those
bits. Not G1gz. Isolated P4 stays.

| | |
|--|--|
| **Hits** | shifted present word either half is exact `c.jalr` |
| **Not** | G1hn/G1ho unshifted `q`. Not `750`. Not G1gz. Not I4cg. |
| **Rule** | Present-word (`g1gx` / stash) exact `c.jalr` is stashed. |
| **Site** | `frontend` `g1hp_hi`/`g1hp_lo`. Isolated P4 stays. |

Lottery **PASS @553**. FDT **PASS @2691**.
Hold TRACE cookie t=96256 + BANR.
TRACE unchanged (`7ba` cmt @20475, hangj
`766` @20470, no `@71e4` after `7ba`).
Did not fire — `g1gx` shift when
`g1fu_mid&&vaddr00` maps to the same
`[31:16]` G1hn already checked.
Keep. Isolated P4 stays.

### G1hq — capture incoming I$ +2 exact c.jalr even if fill is not registered (**landed 2026-08-18**; did not move 7ba)

Capture exact `c.jalr` from the
incoming I$ +2 halfword
(`icache_dreq_i.data[31:16]`) even
when leftover-PC predict kills the
fill before `icache_data_q`. Not
line-start `[15:0]` (`750`). Not
G1gz. Isolated P4 stays.

| | |
|--|--|
| **Hits** | incoming I$ `valid` and `[31:16]` exact `c.jalr` |
| **Not** | registered `q` only. Not `750`. Not G1gz. Not I4cg. |
| **Rule** | Incoming FETCH_WIDTH +2 exact `c.jalr` is stashed. |
| **Site** | `frontend` `g1hq_hi`. Isolated P4 stays. |

Lottery **PASS @567** (was @553; fired
on lottery 7b8-shape). FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, hangj `766` @20470,
no `@71e4` after `7ba`). Did not
capture OpenSBI 7b8 — I$ sets
`dreq.valid = ~kill_s2`, so the
killed return never raises `valid`.
Keep. Isolated P4 stays.

### G1hr — capture incoming I$ +2 exact c.jalr on kill_s2 even if valid is muted (**landed 2026-08-18**; did not move 7ba)

Capture incoming I$ +2 exact
`c.jalr` on the `kill_s2` cycle
even when `dreq.valid` is 0. Data
stays on the bus; valid is muted.
Not G1bb freeze. Not `750`. Not
G1gz. Isolated P4 stays.

| | |
|--|--|
| **Hits** | `kill_s2` and bus `[31:16]` exact `c.jalr` |
| **Not** | G1hq `valid` only. Not G1bb. Not `750`. Not G1gz. Not I4cg. |
| **Rule** | Killed I$ return +2 exact `c.jalr` is stashed. |
| **Site** | `frontend` `g1hr_hi`. Isolated P4 stays. |

Lottery **PASS @567**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, hangj `766` @20470,
no `@71e4` after `7ba`). Did not
fire on OpenSBI 7b8 — `kill_s2` and
that window are not the same beat
(likely `kill_s1` before READ hit).
Keep. Isolated P4 stays.

### G1hs — leftover-complete Jump must not replay-kill I$ s1 (**landed 2026-08-18**; did not move 7ba)

G1cq spares leftover-complete NoCF
from replay `kill_s1`. Leftover jal
`x0` @766 is Jump; IQ overflow then
cancels the in-flight 7b8 fill
before READ (G1hr never saw the
bits). Not G1bq `!kill_s2`. Not
G1db leftover +8. Not G1gn leftover-
PC predict. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover-complete slot0 Jump; IQ replay |
| **Not** | G1cq NoCF only. Not G1bq `!kill_s2`. Not G1db. Not G1gn. Not I4cg. |
| **Rule** | Leftover-complete Jump does not replay-kill I$ s1. |
| **Site** | `frontend` `kill_s1` next to G1cq. Isolated P4 stays. |

Lottery **PASS @567**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, hangj `766` @20470,
no `@71e4` after `7ba`). Did not
fire — leftover Jump replay is not
the 7b8 kill. Keep. Isolated P4
stays.

### G1ht — replay must not kill_s1 while npc is mid-line 01 (**landed 2026-08-18**; did not move 7ba)

Replay must not `kill_s1` while npc
is mid-line `[2:1]==01` (7ba fetch
outstanding). G1hs leftover Jump is
not the replay source. Not G1bq
`!kill_s2`. Not G1gn leftover-PC.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | IQ replay; npc `[2:1]==01` |
| **Not** | G1hs leftover Jump. Not G1bq `!kill_s2`. Not G1gn. Not I4cg. |
| **Rule** | Mid-line fetch is not replay-killed. |
| **Site** | `frontend` `kill_s1` next to G1hs. Isolated P4 stays. |

Lottery **PASS @567**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, hangj `766` @20470,
no `@71e4` after `7ba`). Did not
fire — replay is not killing the
mid-line fetch. Keep. Isolated P4
stays.

### G1hu — leftover Jump bp_valid must not kill_s2 a different-line I$ (**MINI-FAIL 2026-08-18 — reverted**)

Leftover-complete Jump `bp_valid`
still redirects npc. It must not
`kill_s2` / drop a registered I$
whose 8B line is not the leftover
PC (7b8 fill vs `766`). Not G1bq
all leftover `!kill_s2`. Not G1gn
`!bp_valid`. Not G1bb freeze.

| | |
|--|--|
| **Hits** | leftover-complete slot0 Jump; registered I$ different 8B line |
| **Not** | G1bq all leftover. Not G1gn leftover-PC `!bp_valid`. Not G1bb. Not I4cg. |
| **Rule** | Leftover Jump predict does not kill a different-line I$ fill. |
| **Site** | `frontend` `kill_s2` + `icache_valid_q` drop. Isolated P4 stays. |

Lottery **PASS @567**. FDT **MINI-FAIL
printed 24** (P8 `0x18`) @2479. Restore
G1ht slfix `fd8628c4` / `a50fee86`
(bit-identical). Do not re-land
(G1bq / G1bt `kill_s2` class). Isolated
P4 stays.

### G1hv — leftover Jump must not flush_i-kill s1 while npc mid-line 01 (**landed 2026-08-18**; did not move 7ba)

Leave leftover `!kill_s2`. Spare
only the `flush_i` term of `kill_s1`
while leftover-complete Jump is live
and npc is mid-line 01. Not G1hu
`kill_s2`. Not G1ht replay. Not
G1gn leftover-PC. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover-complete slot0 Jump; npc `[2:1]==01`; `flush_i` |
| **Not** | G1hu `kill_s2`. Not G1ht replay. Not G1gn. Not I4cg. |
| **Rule** | Leftover Jump `flush_if` does not kill a mid-line I$ s1. |
| **Site** | `frontend` `kill_s1` `flush_i` term. Isolated P4 stays. |

Lottery **PASS @567**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, hangj `766` @20470,
no `@71e4` after `7ba`). Did not
fire — leftover Jump `flush_i` is
not the 7ba kill. Keep. Isolated P4
stays.

### G1hw — leftover Jump must not is_mispredict-kill s1 while npc mid-line 01 (**landed 2026-08-18**; did not move 7ba)

G1hv spared `flush_i` only. EX
`is_mispredict` still ORs into
`kill_s1` (and controller
`flush_if` rides with it). Same
leftover-Jump + npc 01 window.
Not G1hu `kill_s2`. Not G1gn.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover-complete slot0 Jump; npc `[2:1]==01`; `is_mispredict` |
| **Not** | G1hv `flush_i` only. Not G1hu `kill_s2`. Not G1gn. Not I4cg. |
| **Rule** | Leftover Jump EX mispredict does not kill a mid-line I$ s1. |
| **Site** | `frontend` `kill_s1` `is_mispredict` term. Isolated P4 stays. |

Lottery **PASS @567**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, hangj `766` @20470,
no `@71e4` after `7ba`). Did not
fire — leftover Jump `is_mispredict`
is not the 7ba kill. Keep. Isolated
P4 stays.

### G1hx — same-line +2 duplicate compressed Branch is JALR (**landed 2026-08-18**; did not fire at 7ba)

Leave the I$ kill family. 7ba is
Branch at EX because the +2 slot
repeats the aligned `c.beqz` 16-bit.
Force JALR; rs1 is C2 `rs1'`. Not
G1he all mid-line Branch. Not G1hg
exact `c.jalr`. Isolated P4 stays.

| | |
|--|--|
| **Hits** | aligned compressed Branch; later same-line `[2:1]==01` same 16-bit |
| **Not** | G1he any mid-line CTRL_FLOW. Not G1hg exact `c.jalr`. Not I4cg. |
| **Rule** | Duplicate compressed Branch at +2 of the same 8B line is JALR. |
| **Site** | `id_stage` after G1hd. Isolated P4 stays. |

Lottery **PASS @567**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, hangj `766` @20470,
no `@71e4` after `7ba`). Did not
fire — 7ba bits are not a copy of
the aligned `c.beqz`. Keep. Isolated
P4 stays.

### G1hy — aligned packet high-half c.jalr recovers mid-line 01 Branch (**landed 2026-08-18**; did not fire at 7ba)

7ba Branch is not a duplicate of
7b8. The aligned 7b8 fetch_entry
may still carry `{c.jalr, c.beqz}`.
Latch that +2 `c.jalr`; a later
same-line mid-line 01 Branch is
that jalr even if the 01 bits are
+4 `c.bnez`. Not G1hx duplicate.
Not G1gy on the 01 slot. Not G1he.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | aligned fetch `[31:16]` exact `c.jalr`; later same-line `01` Branch |
| **Not** | G1hx same 16-bit. Not G1gy on the 01 slot. Not G1he. Not I4cg. |
| **Rule** | Aligned packet +2 `c.jalr` recovers a later same-line mid-line Branch. |
| **Site** | `id_stage` after G1hx. Isolated P4 stays. |

Lottery **PASS @567**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, hangj `766` @20470,
no `@71e4` after `7ba`). Did not
fire — aligned 7b8 fetch_entry
`[31:16]` is not `c.jalr` (slot0-only
zeros the high half). Keep. Isolated
P4 stays.

### G1hz — slot0-only aligned Branch keeps +2 c.jalr in instruction[31:16] (**landed 2026-08-18**; did not fire at 7ba)

Aligned slot0-only compressed Branch
should still carry I$ `[31:16]` in
`instruction[31:16]` when that
halfword is exact `c.jalr`, so G1hy
can latch it. Prefer realign high
half, else I$. Not G1fq slot1 fill.
Not G1gz slot0 rewrite. Isolated P4
stays.

| | |
|--|--|
| **Hits** | slot0-only aligned `c.beqz`/`c.bnez`; +2 exact `c.jalr` |
| **Not** | G1fq slot1. Not G1gz all mid-line slot0. Not I4cg. |
| **Rule** | Slot0-only aligned compressed Branch keeps +2 `c.jalr` in the high half. |
| **Site** | `frontend` present after G1hm. Isolated P4 stays. |

Lottery **PASS @567**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, hangj `766` @20470,
no `@71e4` after `7ba`). Did not
fire — neither realign nor I$
`[31:16]` is `c.jalr` on that beat.
Keep. Isolated P4 stays.

### G1ia — compressed +2 slot is the 16-bit at that PC, not {+4,+2} mash (**landed 2026-08-18**; did not move 7ba)

Aligned realign put `data[47:16]`
(`{7bc,7ba}`) in slot1 at PC +2.
A compressed +2 slot is only the
16-bit at that PC. Not G1gz slot0.
Not G1fq slot1 fill. Isolated P4
stays.

| | |
|--|--|
| **Hits** | aligned fetch; slot0 compressed; slot1 compressed |
| **Not** | G1gz mid-line slot0. Not G1fq. Not I4cg. |
| **Rule** | Compressed +2 presents `{16'b0, data[31:16]}`. |
| **Site** | `instr_realign` FETCH_WIDTH=64 `2'b00`. Isolated P4 stays. |

Lottery **PASS @567**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, hangj `766` @20470,
no `@71e4` after `7ba`). Did not
fire — 7ba is not that slot1 mash
(or `data[31:16]` is not `c.jalr`).
Keep. Isolated P4 stays.

### G1ib — slot0-only must not hide a live +2 c.jalr (**landed 2026-08-18**; did not move 7ba)

G1ia left 7ba as Branch at EX.
G1hz only keeps +2 bits in slot0
high half. G1fr needs slot1 already
valid. Un-hide a live +2 exact
`c.jalr` as slot1 on an aligned
slot0-only beat, or present
unshifted I$ `[31:16]` at a mid-line
01 slot0-only PC. Not G1gz all
mid-line slot0. Not G1fq/G1hc fill
gates. Isolated P4 stays.

| | |
|--|--|
| **Hits** | slot0-only; +2 exact `c.jalr` in high half or I$ `[31:16]` |
| **Not** | G1gz all mid-line slot0. Not G1he. Not G1fq/G1hc. Not I4cg. |
| **Rule** | Slot0-only must not hide a live +2 exact `c.jalr`. |
| **Site** | `frontend` present after G1hz. Isolated P4 stays. |

Lottery **PASS @567**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, hangj `766` @20470,
no `@71e4` after `7ba`). Did not
fire — 7ba is still Branch and is
not a hidden +2 `c.jalr` slot.
Keep. Isolated P4 stays.

### G1ic — leftover-PC I$ must not present while npc is mid-line 01 (**landed 2026-08-18**; did not move 7ba)

G1hh/G1hi saw leftover 766 I$ live
at 7ba present. G1el holds only
while an unconsumed 01 package
exists. Mute leftover-PC I$
(`[2:1]==11`) to realign, and do
not let it replace the registered
line, while npc is mid-line 01.
Not G1gz rewrite. Not G1es. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | npc `[2:1]==01`; registered or incoming I$ is leftover-PC |
| **Not** | G1el unconsumed-01 package. Not G1gz. Not G1he. Not I4cg. |
| **Rule** | Leftover-PC I$ must not present while npc is mid-line 01. |
| **Site** | `frontend` `g1ic_leftover_mid` / `g1ic_hold`. Isolated P4 stays. |

Lottery **PASS @567**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, hangj `766` @20470,
no `@71e4` after `7ba`). Did not
fire — 7ba is already Branch in IQ
before leftover-PC I$ can present
it. Keep. Isolated P4 stays.

### G1id — mid-line 01 Branch on same line as aligned compressed Branch is JALR (**landed 2026-08-18**; did not move 7ba)

G1hx needs the same 16-bit. G1hy
needs aligned `[31:16]` exact
`c.jalr`. A mid-line 01 Branch on
the same 8B line as a just-seen
aligned compressed Branch is that
line's +2. JALR through the aligned
Branch's C2 `rs1'`. Not G1he all
mid-line. Isolated P4 stays.

| | |
|--|--|
| **Hits** | aligned `c.beqz`/`c.bnez` latched; later same-line `[2:1]==01` Branch |
| **Not** | G1hx same 16-bit. Not G1hy high-half `c.jalr`. Not G1he. Not I4cg. |
| **Rule** | Same-line +2 of an aligned compressed Branch is JALR. |
| **Site** | `id_stage` after G1hy. Isolated P4 stays. |

Lottery **PASS @567**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, hangj `766` @20470,
no `@71e4` after `7ba`). Did not
fire — 7ba is not that ID shape
(latch miss, or not a Branch at ID).
Keep. Isolated P4 stays.

### G1ie — frontend latch of aligned compressed Branch recovers same-line 01 Branch (**landed 2026-08-18**; lottery @571, did not move OpenSBI 7ba)

ID G1id missed because 7b8 may never
enter ID as aligned compressed
Branch. Latch that shape at present;
a same-line mid-line 01 Branch is
that line's +2 `c.jalr` (constructed
from the aligned Branch's C2 `rs1'`).
Not G1he. Not G1gz. Isolated P4 stays.

| | |
|--|--|
| **Hits** | presented aligned `c.beqz`/`c.bnez`; later same-line `[2:1]==01` Branch |
| **Not** | G1id ID latch. Not G1he all mid-line. Not G1gz. Not I4cg. |
| **Rule** | Frontend-latched aligned compressed Branch recovers same-line +2 Branch as `c.jalr`. |
| **Site** | `frontend` `g1ie_v_q` / present rewrite. Isolated P4 stays. |

Lottery **PASS @571** (was @567). FDT
**PASS @2691**. Hold TRACE cookie
t=96256 + BANR. TRACE 7ba window
unchanged (`7ba` cmt @20475, hangj
`766` @20470, no `@71e4` after
`7ba`). Fired on lottery, not at
OpenSBI 7ba (7ba bits are not a
Branch at present, or 7b8 was not
presented as aligned compressed
Branch). Keep. Isolated P4 stays.

### G1if — same-line 01 slot is c.jalr even if not a Branch (**HOLD-FAIL 2026-08-18** — reverted)

G1ie gated on the 01 slot already
looking like a Branch. Drop that
gate so any same-line 01 slot is
the +2 `c.jalr`. Isolated P4 stays.

| | |
|--|--|
| **Hits** | latched aligned compressed Branch; any same-line `[2:1]==01` slot |
| **Not** | G1ie Branch-bits gate. Not G1gz all mid-line slot0. Not I4cg. |
| **Rule** | Same-line mid-line 01 is `c.jalr`. |
| **Site** | `frontend` G1ie rewrite without Branch gate. Isolated P4 stays. |

Lottery **PASS @564**. FDT **PASS @764**
(was @2691). Hold TRACE **no cookie**
@600000 (`[1000]=800071d8`, no BANR).
**HOLD-FAIL**. Restore G1ie Branch-bits
gate. Do not re-land (yanks live
mid-line 01). Isolated P4 stays.

### G1ig — mid-line 01 Branch whose imm target is leftover-PC is JumpR (**MINI-FAIL 2026-08-18** — reverted)

7ba Branch at EX may carry a bnez
imm to 766. JumpR through usable
RF when that imm target is
leftover-PC (`[2:1]==11`). Not G1he
all Branch. Not G1hg exact `c.jalr`.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | mid-line 01 Branch; `pc+imm` `[2:1]==11`; usable RF |
| **Not** | G1he all CTRL_FLOW. Not G1hg. Not G1if. Not I4cg. |
| **Rule** | Mid-line 01 Branch to leftover-PC is JumpR. |
| **Site** | `branch_unit` after G1hg. Isolated P4 stays. |

Lottery **PASS @571**. FDT **hang
@400000** (tohost=0). **MINI-FAIL**.
Restore G1ie `branch_unit` (G1he
class). Do not re-land. Isolated P4
stays.

### G1ih — IQ output recovers same-line 01 Branch as c.jalr (**landed 2026-08-18**; did not move 7ba)

7ba is delivered from IQ after
G1ie present rewrite missed. Latch
aligned compressed Branch on IQ
push; recover a later same-line
01 Branch at IQ output. Keep
Branch-bits gate (not G1if). Not
G1id ID latch. Isolated P4 stays.

| | |
|--|--|
| **Hits** | aligned `c.beqz`/`c.bnez` pushed; later same-line 01 Branch at IQ output |
| **Not** | G1ie present rewrite. Not G1if any-slot. Not G1id. Not I4cg. |
| **Rule** | IQ output of same-line +2 Branch is `c.jalr`. |
| **Site** | `instr_queue` `g1ih_v_q` / output rewrite. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged.
Did not fire at OpenSBI 7ba (7b8
never pushed as aligned compressed
Branch, or 7ba bits are not Branch
at IQ output). Keep. Isolated P4
stays.

### G1ii — IQ input (valid, not only push) latches aligned Branch (**landed 2026-08-18**; did not move 7ba)

G1ih latched only on push of
aligned compressed Branch. 7b8 may
be valid at IQ input but not pushed
(G1ct smash). Latch from `valid_i`.
Also latch aligned `cf==Branch`
(G1bj may clear the 16-bit class).
Keep output Branch-bits gate (not
G1if). Isolated P4 stays.

| | |
|--|--|
| **Hits** | aligned Branch valid at IQ input; later same-line 01 Branch |
| **Not** | G1ih push-only. Not G1if any-slot. Not I4cg. |
| **Rule** | IQ input of an aligned Branch latches for later +2 recover. |
| **Site** | `instr_queue` `g1ih_v_q` latch. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged.
Did not fire — 7ba is not a Branch
encoding at IQ output (ID makes it
Branch later), or 7b8 is never an
aligned Branch at IQ input. Keep.
Isolated P4 stays.

### G1ij — mid-line 01 Branch whose 16-bit is not a Branch encoding follows that 16-bit (**landed 2026-08-18**; did not fire at 7ba)

Leave the IQ Branch-bits recover
family. 7ba is still Branch at EX.
G1bj analog at ID: if mid-line 01
decodes as Branch but the fetch
16-bit is neither `c.beqz`/`c.bnez`
nor RVI BRANCH, it is a mash —
drop CF (NOP). Isolated P4 stays.

| | |
|--|--|
| **Hits** | mid-line 01 Branch invented from non-Branch bits |
| **Not** | G1he all mid-line Branch. Not G1ig leftover-PC. Not G1id same-line latch. Not I4cg. |
| **Rule** | ID CF class of a mid-line 01 word follows the 16-bit at that PC. |
| **Site** | `id_stage` after G1id. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, no `@71e4` after).
Did not fire — 7ba bits *are* a
Branch encoding at ID. Keep.
Isolated P4 stays.

### G1ik — ID-visible aligned Branch arms same-line 01 recover (**landed 2026-08-18**; did not fire at 7ba)

G1id latched only compressed Branch
bits. 7b8 commits but is not that
encoding (G1ii analog at ID). Arm on
aligned Branch (compressed, RVI,
decoded `op_is_branch`, or in-ID
`issue_q`). Keep 01 Branch-bits gate
(not G1if). Isolated P4 stays.

| | |
|--|--|
| **Hits** | aligned Branch at ID fetch or `issue_q`; later same-line `[2:1]==01` Branch |
| **Not** | G1id compressed-bits only. Not G1he all mid-line. Not G1if any-slot. Not I4cg. |
| **Rule** | Any ID-visible aligned Branch recovers same-line +2 Branch as JALR. |
| **Site** | `id_stage` G1id latch + `issue_q` arm. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, no `@71e4` after).
Did not fire — 7b8 is never an
aligned Branch at ID (fetch or
`issue_q`). Keep.
Isolated P4 stays.

### G1il — aligned-Branch recover latch survives flush_i (**landed 2026-08-18**; did not fire at 7ba)

Leftover `jal@766` is fetched @20470
and may `flush_i` the G1ik latch
before 7ba is at ID. Keep
`g1hx_v_q` across flush (SMT+SS).
Same-line 01 Branch gate stays
(not G1if). Not G1bn dest-FIFO.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | aligned Branch latched; later `flush_i` (leftover Jump); same-line 01 Branch |
| **Not** | G1bn keep FIFO. Not G1if any-slot. Not G1he. Not I4cg. |
| **Rule** | ID aligned-Branch recover latch survives flush. |
| **Site** | `id_stage` `g1hx_v_q` flush. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, no `@71e4` after).
Did not fire — latch was never armed
(G1ik: 7b8 is never an aligned
Branch at ID). Keep.
Isolated P4 stays.

### G1im — aligned either-half compressed Branch is that Branch (**HOLD-FAIL 2026-08-18** — reverted)

7b8 commits @20474 but is never an
aligned Branch at ID. G1bj analog:
either half compressed Branch on an
aligned word forces Branch so +2
recover can arm. Isolated P4 stays.

| | |
|--|--|
| **Hits** | aligned `!Branch` whose high or low 16 is `c.beqz`/`c.bnez` |
| **Not** | G1ij mid-line drop. Not G1he. Not I4cg. |
| **Rule** | Aligned CF follows a compressed Branch 16-bit in either half. |
| **Site** | `id_stage` after G1ij. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2691**. Hold **HOLD-FAIL** no cookie
@250000 (`[1000]=20ef8526`, no BANR,
npc `0x10000`). Restore G1il
`604e3766` / `b6236f18` (bit-identical).
Do not re-land (yanks live aligned
ops whose high half looks like
`c.beqz`/`c.bnez`). Isolated P4 stays.

### G1in — leftover-PC I$ must not present while npc is aligned 00 (**MINI-FAIL 2026-08-18** — reverted)

G1ic mutes leftover-PC I$ only
while npc is mid-line 01. Same mute
+ hold while npc is aligned 00 so
leftover 766 data cannot present as
7b8. Not G1im either-half. Not G1gz.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover-PC I$ (`[2:1]==11`); npc aligned 00 |
| **Not** | G1ic 01-only. Not G1im decode. Not G1gz. Not I4cg. |
| **Rule** | Leftover-PC I$ must not present while npc is line-aligned. |
| **Site** | `frontend` `g1ic_leftover_mid` / `g1ic_hold`. Isolated P4 stays. |

Lottery **hang @400000** (tohost=0).
**MINI-FAIL**. Restore G1il `604e3766`
/ `b6236f18` (bit-identical). Do not
re-land (starves leftover-complete
next-line fetch). Isolated P4 stays.

### G1io — aligned npc + same-line I$ → slot0 is I$[15:0] (**landed 2026-08-18**; did not fire at 7ba)

Leave leftover-PC mute-on-aligned.
Present the 16-bit at aligned npc
from same-line I$ `[15:0]`. Do not
steal leftover slot0 (G1es). Not
G1in mute. Not G1gz mid-line.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | npc aligned 00; same-line I$ vaddr 00; slot0 already aligned |
| **Not** | G1in leftover-PC mute. Not G1es leftover_next. Not G1gz. Not I4cg. |
| **Rule** | Aligned slot0 is the 16-bit at that PC (I$ `[15:0]`). |
| **Site** | `frontend` present after G1ha. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged
(`7ba` cmt @20475, no `@71e4` after).
Did not fire — slot0 already had
those bits, or leftover blocked the
rewrite (`serving_unaligned`). Keep.
Isolated P4 stays.

### G1ip — leftover slot0 stays; slot1 is I$[15:0] at aligned npc (**landed 2026-08-18**; did not fire at 7ba)

G1io needs `!serving_unaligned`.
Leftover may occupy slot0 when npc
is 7b8. Present same-line I$ `[15:0]`
compressed Branch as slot1 at
aligned npc (G1hc analog). Slot0
stays leftover. Not G1in mute. Not
G1es. Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover slot0 `[2:1]==11`; npc aligned 00; I$ `[15:0]` `c.beqz`/`c.bnez` |
| **Not** | G1io slot0. Not G1hc +2 `c.jalr`. Not G1es. Not G1in. Not I4cg. |
| **Rule** | Leftover-complete + aligned npc → slot1 is the 16-bit at npc. |
| **Site** | `frontend` present after G1io. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2691**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window unchanged.
Did not fire — leftover `766` @20470
is after npc `7b8` @20458; they
never coincide. Keep.
Isolated P4 stays.

### G1iq — stash aligned I$[15:0] compressed Branch; present at aligned npc (**landed 2026-08-18**; FDT @2719, did not move OpenSBI 7ba)

7b8 present @20458 is not leftover+
slot1. Live I$ may not be the 7b8
line. Stash aligned I$ `[15:0]`
`c.beqz`/`c.bnez` (G1hj analog);
present when npc is aligned 00 on
that line. Do not steal leftover
slot0. Isolated P4 stays.

| | |
|--|--|
| **Hits** | aligned I$ `[15:0]` compressed Branch; later npc aligned 00 same line |
| **Not** | G1hj +2 `c.jalr`. Not G1in mute. Not G1es leftover. Not G1gz. Not I4cg. |
| **Rule** | Stashed aligned compressed Branch presents at aligned npc. |
| **Site** | `frontend` `g1iq_v_q` stash + present after G1ip. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2719** (was @2691). Hold TRACE cookie
t=96256 + BANR. TRACE 7ba window
unchanged (`7ba` cmt @20475, no
`@71e4` after). Fired on FDT, not at
OpenSBI 7ba. Keep.
Isolated P4 stays.

### G1ir — G1ie arms from G1iq stash (**landed 2026-08-18**; hygiene at OpenSBI 7ba)

G1ie only armed from a visible aligned
compressed Branch present. G1iq can
stash that half-word without presenting
it. Arm G1ie from `g1iq_v_q` (C2 rs1'
+ line); live present still overwrites.
Not G1if any-slot. Isolated P4 stays.

| | |
|--|--|
| **Hits** | G1iq stash valid; later same-line mid-line 01 Branch |
| **Not** | G1if any-slot 01. Not G1iq present-only. Not I4cg. |
| **Rule** | Stashed aligned compressed Branch arms G1ie recover. |
| **Site** | `frontend` G1ie `always_ff` after G1iq stash. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2719**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window identical to
G1iq (`7ba` cmt @20475, no `@71e4`
after). Did not fire at OpenSBI 7ba —
stash is not the 7b8 line (or gone
before 7ba). Keep.
Isolated P4 stays.

### G1is — any-vaddr I$ `[15:0]` compressed Branch (**HOLD-FAIL 2026-08-18**)

G1iq only captures when I$ vaddr is
aligned 00. Dropped that gate (G1hn
analog). Lottery **PASS @571**. FDT
**PASS @2723** (was @2719). Hold **no
cookie @250000** (`[1000]=8000341e`,
npc `0x80002d38`, mcause=4, no BANR).
Restore G1ir `a27b17d8` / `da52e0d6`
bit-identical. Do not re-land (yanks
wrong-line aligned Branch, leftover
766 line). Isolated P4 stays.

### G1it — capture line `[15:0]` Branch when I$ vaddr is mid-line 01 (**landed 2026-08-18**; hygiene at OpenSBI 7ba)

G1is any-vaddr yank HOLD-FAIL. Capture
unshifted `[15:0]` compressed Branch
when I$ vaddr is mid-line 01 (same
8-byte line; G1ho analog). Not leftover
11. Isolated P4 stays.

| | |
|--|--|
| **Hits** | I$ vaddr mid-line 01; `[15:0]` is `c.beqz`/`c.bnez` |
| **Not** | G1is any-vaddr. Not leftover 11. Not G1hn +2. Not I4cg. |
| **Rule** | Mid-line 01 I$ beat still carries the line's aligned Branch. |
| **Site** | `frontend` G1iq `g1iq_cap` + capture mux. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2719**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window identical to
G1ir (`7ba` cmt @20475, no `@71e4`
after). Did not fire — mid-line 01 I$
`[15:0]` is not a Branch at OpenSBI
7ba (or no such beat). Keep.
Isolated P4 stays.

### G1iu — capture line `[15:0]` Branch when npc is mid-line 01 on that I$ line (**landed 2026-08-18**; hygiene at OpenSBI 7ba)

G1it I$ vaddr==01 did not arm the 7b8
stash. Capture unshifted `[15:0]`
compressed Branch when npc is mid-line
01 and I$ is the same 8-byte line (any
vaddr offset, including 10/11 on that
line). Not G1is any-vaddr (leftover 766
is a different line). Isolated P4 stays.

| | |
|--|--|
| **Hits** | npc mid-line 01; I$ same line; `[15:0]` is `c.beqz`/`c.bnez` |
| **Not** | G1is any-vaddr. Not leftover-only. Not G1it vaddr-01-only. Not I4cg. |
| **Rule** | Same-line I$ beat while npc is +2 still carries the aligned Branch. |
| **Site** | `frontend` `g1iu_*` into G1iq cap + mux. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2719**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window identical to
G1it (`7ba` cmt @20475, no `@71e4`
after). Did not fire — no same-line I$
beat with `[15:0]` Branch while npc is
7ba. Keep.
Isolated P4 stays.

### G1iv — 128-bit I$ other-half `[15:0]` Branch (**MINI-FAIL 2026-08-18**)

G1iu same-line `[15:0]` did not see 7b8.
Reported the other 8-byte half of the
128-bit I$ line on `user[16:0]` and
stashed it as the sibling line's
aligned Branch. Lottery **PASS @577**
(was @571). FDT **FAIL tohost=91
@948**. Restore G1iu `8af45069` /
`4531ce14` bit-identical. Do not
re-land (sibling stash + G1ir rewrites
live mid-line 01 on that other line).
Isolated P4 stays.

### G1iw — same-cycle sibling-half `[15:0]` Branch recovers mid-line 01 (**landed 2026-08-18**; hygiene at OpenSBI 7ba)

G1iv stashed the other 8-byte half and
G1ir rewrote later 01s. Same-cycle
only: I$ reports other-half `[15:0]`
Branch on `user[16:0]`; present
rewrites a mid-line 01 Branch on the
sibling 8-byte line. No G1iq stash.
Not G1if. Isolated P4 stays.

| | |
|--|--|
| **Hits** | I$ 16-byte line; other half `[15:0]` Branch; slot mid-line 01 on sibling 8B |
| **Not** | G1iv stash. Not G1is any-vaddr. Not G1if any-slot. Not I4cg. |
| **Rule** | Sibling-half aligned Branch recovers same-cycle mid-line 01 only. |
| **Site** | `g6lc_icache` user sideband + `frontend` G1ie rewrite. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2719**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window identical to
G1iu (`7ba` cmt @20475, no `@71e4`
after). Did not fire — I$ is not
serving the 16-byte line that holds
7b8 while npc is 7ba. Keep.
Isolated P4 stays.

### G1ix — bp_valid must not kill_s2 while npc is mid-line 01 (**landed 2026-08-19**; hygiene at OpenSBI 7ba)

G1iw did not see the 7b8 line. G1ht
spares replay kill_s1 at npc 01, but
`kill_s2` still includes `bp_valid`.
Spare that term only while npc is
mid-line 01. Not G1hu leftover Jump.
Not G1in mute. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; npc `[2:1]==01`; `bp_valid` would kill I$ s2 |
| **Not** | G1hu leftover Jump. Not G1in mute. Not G1iv stash. Not I4cg. |
| **Rule** | Mid-line 01 fetch survives `bp_valid` kill_s2. |
| **Site** | `frontend` `kill_s2`. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2719**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window identical to
G1iw (`7ba` cmt @20475, no `@71e4`
after). Did not fire — `bp_valid` is
not why 7b8 is off the bus at 7ba.
Keep.
Isolated P4 stays.

### G1iy — flush/mispredict must not kill_s1 while npc is mid-line 01 (**MINI-FAIL 2026-08-19**)

G1ix `bp_valid` !kill_s2 did not move
7ba. G1hv only spares leftover Jump.
Spared `flush_i` / `is_mispredict`
kill_s1 for all npc mid-line 01.
Lottery **FAIL tohost=2 @430**. FDT
still PASS @2719. Restore G1ix
`87ff970a` / `9b6f563e` bit-identical.
Do not re-land (lottery needs
mispredict kill of mid-line 01).
Isolated P4 stays.

### G1iz — I$ vaddr stays npc 8-byte line at mid-line 01 (**MINI-FAIL 2026-08-19**)

G1iy any-npc-01 flush/mispredict spare
MINI-FAIL. Held `fetch_address` to
`{npc[VLEN-1:3],000}` while npc is
mid-line 01 and `bp_valid` (after
leftover predict). Lottery **PASS
@571**. FDT **FAIL tohost 23 @1192**
(P7 `0x17` getprop-shaped jal —
starves leftover-PC I$ at 01). Restore
G1ix `87ff970a` / `9b6f563e`
bit-identical. Do not re-land.
Isolated P4 stays.

### G1ja — different-line predict must not skip aligned-00 npc I$ (**MINI-FAIL 2026-08-19**)

G1iz held I$ at npc 01 every cycle.
Tried aligned-00 only: leftover
predict still wins `npc_d`; this
cycle's I$ vaddr stays the npc 8-byte
line (`kill_s2` still mutes present).
Lottery **FAIL tohost=4 @362** (first
pass took `bnez` / `ret0`). Restore
G1ix `87ff970a` / `9b6f563e`. Do not
re-land (extra 00-line I$ under
predict breaks lottery jalr/bnez).
Isolated P4 stays.

### G1jb — aligned-Branch recover not replaced until mid-line 01 presented (**landed 2026-08-19**)

G1ja extra 00-line I$ under predict
MINI-FAIL. G1iq/G1ie still lose the
7b8 line to a later different-line
aligned Branch before 7ba. Keep the
stash and G1ie latch until a mid-line
01 slot of that 8-byte line is
presented. Not G1ja. Not G1iz. Not
G1is any-vaddr. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; live aligned-Branch recover; later different-line `[15:0]` Branch |
| **Not** | G1ja 00 I$ under predict. Not G1iz 01 hold. Not G1is any-vaddr. Not I4cg. |
| **Rule** | Recover stash/latch of an aligned compressed Branch outranks a different 8-byte line until that line's +2 slot is presented. |
| **Site** | `frontend` G1iq capture + G1ie present arm. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2719**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window identical to
G1ix (`7ba` cmt @20475, no `@71e4`
after). Did not fire — 7b8 was never
in the stash (nothing to keep). Keep.
Isolated P4 stays.

### G1jc — first leftover-RVI I$ at npc 01 still issues npc 8-byte line (**landed 2026-08-19**)

G1jb keep-until-01 hygiene (7b8 never
in stash). G1iz held I$ at npc 01
every cycle and starved leftover
(FDT 23). One-shot: when I$ would
request a leftover-RVI PC (`[2:1]==11`)
on a different 16-byte line while npc
is mid-line 01, issue the npc 8-byte
line once, then leftover proceeds.
Not G1ja any-00 predict. Not G1in
mute. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; npc `[2:1]==01`; I$ leftover-RVI PC; different 16-byte line; first beat |
| **Not** | G1iz every-cycle 01 hold. Not G1ja all 00 predicts. Not G1in mute. Not I4cg. |
| **Rule** | First leftover-RVI fetch steal at mid-line 01 still requests the npc 8-byte line. |
| **Site** | `frontend` `npc_select` after trap-fetch. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2719**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window identical to
G1jb (`7ba` cmt @20475, no `@71e4`
after). Did not fire — leftover-RVI
I$ is not the fetch address while npc
is mid-line 01 (766 @20470 is after
npc 7ba @20467). Keep.
Isolated P4 stays.

### G1jd — sequential-next 8-byte fetch must not skip aligned-00 npc I$ (**MINI-FAIL 2026-08-19**)

G1jc leftover-RVI steal at npc 01
hygiene. Kept I$ on aligned-00 npc
when `bp_valid` predict is sequential
next 8B (not-taken 7b8→7c0). Lottery
**PASS @571**. FDT **FAIL tohost 57
@2652** (P3 `0x39` after `c.mv s0,a0`,
s0!=a0). Restore G1jc `7a480718` /
`308e5604`. Do not re-land (extra
00-line I$ under next-line predict
drops s0 copy). Isolated P4 stays.

### G1je — in-ID aligned-00 any op arms same-line 01 Branch recover (**MINI-FAIL 2026-08-19**)

G1ik only arms from in-ID aligned
Branch. Dropped that gate so any
in-ID aligned-00 on the same 8-byte
line arms mid-line 01 Branch→JALR.
Lottery **PASS @571**. FDT **hang
@400000** (tohost=0; was @2719).
Restore G1jc `7a480718` / `308e5604`.
Do not re-land (yanks live mid-line
01 Branch after a same-line 00 op).
Isolated P4 stays.

### G1jf — prev-cycle aligned-00 commit + this-cycle 01 Branch commit is JumpR (**MINI-FAIL 2026-08-19**)

G1je same-cycle ID any-00 MINI-FAIL.
Tried consecutive-cycle 00-then-01
Branch commit salvage as JumpR.
Lottery **PASS @571**. FDT **hang
@400000** (tohost=0; was @2719).
Restore G1jc `7a480718` / `308e5604`.
Do not re-land (yanks live in-order
00-then-01 Branch). Isolated P4 stays.

### G1jg — first sequential-next 8-byte I$ at npc 01 still issues npc 8-byte line (**landed 2026-08-19**)

G1jf consecutive-commit JumpR
MINI-FAIL. TRACE visits 7c0 around
npc 7ba. G1iz held I$ at 01 every
cycle (FDT 23). G1jc leftover-11
hygiene. One-shot: when fetch is the
next 8-byte line while npc is
mid-line 01, issue the npc 8-byte
line once so G1iq can capture 7b8.
Not G1jd at 00. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; npc `[2:1]==01`; fetch sequential next 8-byte line; first beat |
| **Not** | G1iz every-cycle 01. Not G1jc leftover-11. Not G1jd sequential at 00. Not I4cg. |
| **Rule** | First sequential-next fetch steal at mid-line 01 still requests the npc 8-byte line. |
| **Site** | `frontend` `npc_select` after G1jc. Isolated P4 stays. |

Lottery **PASS @571**. FDT **PASS
@2719**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window identical to
G1jc (`7ba` cmt @20475, no `@71e4`
after). Did not fire — fetch is not
sequential-next while npc is mid-line
01 (7c0 tags are npc visits; leftover
766 @20470 is `[2:1]==11`). Keep.
Isolated P4 stays.

### G1jh — first different 8-byte-line I$ at npc 01 still issues npc 8-byte line (**MINI-FAIL 2026-08-19**)

G1jg sequential-next one-shot at npc
01 hygiene (did not fire). G1jc
leftover-11 hygiene (did not fire).
Tried any remaining different 8-byte
I$ (leftover-00 / jump-target /
sibling) while npc is mid-line 01,
one-shot npc 8-byte line. Lottery
**PASS @571**. FDT **FAIL tohost 23
@1205** (P7 `0x17` getprop-shaped
jal; G1iz was 23 @1192). Restore
G1jg `2e1cc9f2` / `4b824269`
bit-identical. Do not re-land
(one-shot still starves leftover-PC
I$ at 01). Isolated P4 stays.

### G1ji — G1ie arms from G1iw sibling-half compressed Branch (**landed 2026-08-19**)

G1jh fetch-steal at npc 01 MINI-FAIL
(G1iz class). G1iw same-cycle sibling
recover misses leftover I$ at npc 01.
Latch the sibling C.BEQZ (`user[16:0]`)
into G1ie (line + C2 rs1') and keep
until 01 (G1jb). Not G1iv data stash.
Not a 01 I$ steal. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; I$ sibling-half `[15:0]` compressed Branch; G1ie keep-until-01 |
| **Not** | G1iv sibling stash. Not G1iw same-cycle only. Not G1jh/G1iz 01 steal. Not I4cg. |
| **Rule** | Sibling-half compressed Branch arms the aligned-Branch recover latch. |
| **Site** | `frontend` G1ie flop. Isolated P4 stays. |

Lottery **PASS @567** (was @571; fired).
FDT **PASS @2719**. Hold TRACE cookie
t=96256 + BANR. TRACE 7ba window
identical to G1jg (`7ba` cmt @20475,
no `@71e4` after). Did not fire at
OpenSBI 7ba (sibling not on the bus
at that PC). Keep.
Isolated P4 stays.

### G1jj — sibling-half [31:16] exact c.jalr into G1hj (**MINI-FAIL 2026-08-19**)

G1ji sibling [15:0] C.BEQZ→G1ie
hygiene. Tried sibling-half `[31:16]`
exact `c.jalr` (the real 7ba bits)
into the G1hj +2 stash. Lottery
**FAIL tohost 2 @200615**. FDT still
PASS @2719. Restore G1ji `f735925b`
/ `f1751d08` bit-identical. Do not
re-land (yanks a live mid-line jalr
from a sibling of a different 16-byte
line). Isolated P4 stays.

### G1jk — G1hj +2 c.jalr stash is PC-matched (**landed 2026-08-19**)

G1jj sibling `[31:16]` c.jalr MINI-FAIL
(any-01 present yanked lottery jalr).
G1hk/G1hl presented the stash at every
npc 01; G1hj rewrite hit every 01 slot.
Present/rewrite only when npc/addr is
the captured +2 PC. G1hm already used
that PC. Not G1jj new capture. Not a
01 steal. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; live G1hj +2 stash; present/rewrite at a mid-line 01 |
| **Not** | G1jj sibling capture. Not G1hk any-01. Not G1gz. Not I4cg. |
| **Rule** | Stashed +2 `c.jalr` is only presented at that PC. |
| **Site** | `frontend` G1hj/G1hk/G1hl present. Isolated P4 stays. |

Lottery **PASS @558** (was @567; fired).
FDT **PASS @2719**. Hold TRACE cookie
t=96256 + BANR. TRACE 7ba window
identical to G1ji (`7ba` cmt @20475,
no `@71e4` after). Did not fire at
OpenSBI 7ba (stash empty / PC never
7ba). Keep.
Isolated P4 stays.

### G1jl — sibling pair (Branch + [31:16] c.jalr) into PC-matched G1hj (**landed 2026-08-19**)

G1jj any sibling +2 c.jalr MINI-FAIL.
G1jk PC-matches present. Capture only
when sibling `[15:0]` is compressed
Branch **and** `[31:16]` is exact
`c.jalr` (the 7b8/7ba pair). Not
G1iv [15:0] stash. Not G1ji
constructed jalr. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; I$ sibling-half C.BEQZ + c.jalr pair; G1hj + G1jk |
| **Not** | G1jj any sibling +2. Not G1iv. Not G1jh 01 steal. Not I4cg. |
| **Rule** | Sibling 8-byte Branch/+2-jalr pair fills the PC-matched +2 stash. |
| **Site** | `g6lc_icache` user[33:17] + `frontend` G1hj capture. Isolated P4 stays. |

Lottery **PASS @558** (same as G1jk).
FDT **PASS @2719**. Hold TRACE cookie
t=96256 + BANR. TRACE 7ba window
identical to G1jk (`7ba` cmt @20475,
no `@71e4` after). Did not fire —
sibling pair not on the I$ bus at
7b0/7ba. Keep.
Isolated P4 stays.

### G1jm — keep registered aligned compressed-Branch I$ until +2 presented (**landed 2026-08-19**)

G1jl pair not on the bus. 7b8 `[31:16]`
is the real `c.jalr a5`. If that 8-byte
line registers, `bp_valid` 7c0 must not
drop it before 7ba presents. Not G1iz
vaddr force. Not G1bb all keep_line.
Not G1jh steal. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; registered vaddr 00 C.BEQZ/C.BNEZ; +2 of that line not yet presented |
| **Not** | G1iz every-cycle 01 vaddr. Not G1bb keep_line. Not G1ix npc-01 kill_s2. Not I4cg. |
| **Rule** | Registered aligned compressed-Branch I$ stays until that line's mid-line 01 is presented. |
| **Site** | `frontend` `g1bl_hold_line` + `bp_valid` valid-clear. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window identical to
G1jl (`7ba` cmt @20475, no `@71e4`
after). Did not fire — 7b8 never
registered (fill dies in s2). Keep.
Isolated P4 stays.

### G1jn — spare kill_s2 when returning I$ is npc-00 same-line compressed Branch (**landed 2026-08-19**; hygiene at OpenSBI 7ba)

G1jm needs 7b8 registered. G1ix
spares `bp_valid` kill_s2 at npc 01
only. Spare the same term when npc
is aligned 00 and the returning I$
(vaddr+data, no valid bit) is that
same 8-byte compressed Branch line.
Not G1ja fetch steal. Not G1hu.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; npc `[2:1]==00`; returning I$ same 8-byte line `[15:0]` C.BEQZ/C.BNEZ |
| **Not** | G1ja 00 steal. Not G1hu leftover Jump. Not G1ix npc-01. Not I4cg. |
| **Rule** | npc-00 aligned compressed-Branch I$ return survives `bp_valid` kill_s2. |
| **Site** | `frontend` `kill_s2` next to G1ix. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie t=96256 +
BANR. TRACE 7ba window identical to
G1jm (`7ba` cmt @20475, hangj `766`
@20470, no `@71e4` after). Did not
fire — in-flight s2 at npc 00 is the
previous 8-byte line, not 7b8. Keep.
Isolated P4 stays.

### G1jo — replay must not kill_s1 while npc is aligned 00 (**landed 2026-08-19**; fired, residual same)

7b8 request is in s1 at npc 7b8.
G1ht is 01-only. G1jn kill_s2
returning-data did not fire. Spare
replay `kill_s1` at npc 00. Not G1iy
flush/mispredict. Not G1hu. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; npc `[2:1]==00`; IQ replay would kill I$ s1 |
| **Not** | G1ht npc-01. Not G1iy flush/mispredict. Not G1hs leftover Jump. Not I4cg. |
| **Rule** | Aligned-00 fetch survives replay kill_s1. |
| **Site** | `frontend` `kill_s1` next to G1ht. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR (was t=96256). TRACE 7ba
window same shape −20 cy (`7ba` cmt
@20455, hangj `766` @20450, no
`@71e4` after). Fired; 7ba residual
unchanged. Keep. Isolated P4 stays.

### G1jp — bp_valid must not kill_s2 while npc is aligned 00 (**MINI-FAIL 2026-08-19 — reverted**)

G1ix is 01-only. G1jn returning-data
at npc 00 did not fire. G1jo saved
s1 from replay. Spared `bp_valid`
kill_s2 at all npc 00. Lottery
**FAIL tohost=2 @420**. FDT **FAIL
tohost=50 @545**. Restore G1jo
`82a16af8` / `76ee6fb9`. Do not
re-land (aligned-00 fetch needs
`bp_valid` kill_s2). Isolated P4
stays.

### G1jq — leftover Jump must not flush/mispredict-kill s1 while npc is aligned 00 (**landed 2026-08-19**; hygiene at OpenSBI 7ba)

G1hv is leftover Jump + npc 01.
G1jo saved replay s1 at npc 00.
G1jp all-00 kill_s2 MINI-FAIL. Spare
flush_i / is_mispredict kill_s1 when
leftover slot0 is Jump and npc is
00. Not G1iy all-01. Not G1hu.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | leftover-complete slot0 Jump; npc `[2:1]==00`; flush/mispredict would kill I$ s1 |
| **Not** | G1hv npc-01. Not G1iy all-01. Not G1jp kill_s2. Not G1hs replay. Not I4cg. |
| **Rule** | Leftover Jump does not flush/mispredict-kill I$ s1 at aligned npc 00. |
| **Site** | `frontend` `kill_s1` next to G1hv. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window same shape
as G1jo +6 cy (`7ba` cmt @20461,
hangj `766` @20456, no `@71e4`
after). Did not fire — leftover Jump
is not serving at npc 7b8. Keep.
Isolated P4 stays.

### G1jr — flush_i must not kill_s1 while npc is aligned 00 (**HOLD-FAIL 2026-08-19 — reverted**)

G1jo saved replay s1. G1jq leftover
Jump flush is not serving at 7b8.
Spared `flush_i` kill_s1 at all npc
00; `is_mispredict` stayed. Hold:
no cookie-exit, ran 600000 cy,
`[1000]=8000f1d0` `[1008]=4` BANR
`plat_hc=80`. Restore G1jq
`3a2716ac` / `06d18e49`. Do not
re-land (aligned-00 fetch needs
`flush_i` kill_s1). Isolated P4
stays.

### G1js — flush_i must not kill_s1 at npc 00 when s1 is the npc 8-byte line (**HOLD-FAIL 2026-08-19 — reverted**)

G1jr all-00 flush HOLD-FAIL. Spared
only when `fetch_address` is the
same 8-byte line as npc. Hold: same
pin as G1jr — no cookie @600000
`[1000]=8000f1d0` `[1008]=4` BANR.
Restore G1jq `3a2716ac` / `06d18e49`.
Do not re-land (same-line flush s1
at npc 00 is the G1jr hole). Isolated
P4 stays.

### G1jt — is_mispredict must not kill_s1 while npc is aligned 00 (**landed 2026-08-19**; hygiene at OpenSBI 7ba)

G1jr/G1js flush_i at npc 00 closed.
G1jo saved replay s1. Spare
`is_mispredict` kill_s1 at npc 00;
`flush_i` stays. Not G1iy both at
01. Not G1jp kill_s2. Isolated P4
stays.

| | |
|--|--|
| **Hits** | SMT+SS; npc `[2:1]==00`; `is_mispredict` would kill I$ s1 |
| **Not** | G1jr/G1js flush_i. Not G1iy flush+mispredict at 01. Not G1jp. Not I4cg. |
| **Rule** | Aligned-00 fetch survives `is_mispredict` kill_s1. Flush still kills. |
| **Site** | `frontend` `kill_s1` next to G1jq. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1jq (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — `is_mispredict` is
not why 7b8 dies at npc 00. Keep.
Isolated P4 stays.

### G1ju — G1hj +2 c.jalr stash survives leftover Jump flush_i (**landed 2026-08-19**; hygiene at OpenSBI 7ba)

G1jt is_mispredict !kill_s1 hygiene.
G1jr/G1js flush kill_s1 closed. G1hj
clears on every `flush_i`, so a
G1hr/G1jl capture is dropped before
7ba. Keep the stash through leftover
Jump flush until +2 presented.
`is_mispredict` still clears. Not
G1il. Not G1jb. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; G1hj valid; leftover-complete slot0 Jump; `flush_i` |
| **Not** | G1il G1ie latch. Not G1jb replace. Not G1jr kill_s1. Not G1jp. Not I4cg. |
| **Rule** | Leftover Jump flush does not drop the PC-matched +2 c.jalr stash. |
| **Site** | `frontend` G1hj flop. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1jt (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — G1hj was not live at
leftover Jump flush, or never
captured 7ba. Keep. Isolated P4
stays.

### G1jv — G1hj capture beats flush_i clear (**landed 2026-08-19**; hygiene at OpenSBI 7ba)

G1ju leftover-Jump keep hygiene —
either stash was empty or leftover
Jump was not serving, so `flush_i`
in the first `if` dropped a
same-cycle capture. Capture now
wins over `flush_i`. `is_mispredict`
still clears first. Not G1jr kill_s1.
Not G1jp. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; G1hj capture and `flush_i` same cycle |
| **Not** | G1ju leftover-only keep. Not G1il. Not G1jr kill_s1. Not G1jp. Not I4cg. |
| **Rule** | Same-cycle +2 c.jalr capture is not discarded by `flush_i`. |
| **Site** | `frontend` G1hj flop. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1ju (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — no same-cycle 7ba
c.jalr capture with `flush_i`. Keep.
Isolated P4 stays.

### G1jw — G1jl sibling-pair capture without I$ valid/kill_s2 (**HOLD-FAIL 2026-08-19 — reverted**)

G1jl required `valid || kill_s2`.
Captured whenever `user[33]` encoded
exact c.jalr. Lottery PASS @558,
FDT PASS @2719. Hold: no cookie
@600000 `[1000]=800071d8` `[1008]=4`
no BANR; later `coldfn` @200666.
Restore G1jv `50b9b2bd` / `ff1e7cde`.
Do not re-land (IDLE `user[33]`
yanked a later jalr into 71d8).
Isolated P4 stays.

### G1jx — IDLE sibling-pair capture only when npc is the sibling +2 PC (**landed 2026-08-19**; hygiene at OpenSBI 7ba)

G1jw any-IDLE `user[33]` HOLD-FAIL
(71d8). Capture the pair without
`valid`/`kill_s2` only when `npc`
already equals the sibling +2
(7ba while I$ vaddr still 7b0).
G1jk still PC-matches present. Not
G1jw. Not G1jj. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; `user[33]` pair; npc == sibling +2 of I$ vaddr |
| **Not** | G1jw any-IDLE. Not G1jj any sibling +2. Not G1jl valid-only. Not I4cg. |
| **Rule** | IDLE sibling Branch+c.jalr pair fills G1hj only at the +2 npc. |
| **Site** | `frontend` G1jl_hi. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1jv (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — at npc 7ba I$ vaddr
is not 7b0. Keep. Isolated P4 stays.

### G1jy — latch IDLE aligned-00 sibling pair; present only at npc +2 01 (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1jx needs I$ vaddr still 7b0 at npc
7ba. G1jw filled G1hj from IDLE
`user[33]` and G1hm leftover-injected
into 71d8. Latch the pair aside;
present slot0 only when npc is that
+2 01. Not G1hj. Not G1jw. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; IDLE `user[33]` pair; I$ vaddr `[2:1]==00`; later npc == sibling +2 01 |
| **Not** | G1jw G1hj fill. Not G1hm leftover inject. Not G1jj. Not I4cg. |
| **Rule** | IDLE sibling Branch+c.jalr pair presents only at the +2 npc, never via leftover slot1. |
| **Site** | `frontend` g1jy latch + G1hk-shaped present. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1jx (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — IDLE pair not latched
for 7ba, or leftover 11 blocked
present. Keep. Isolated P4 stays.

### G1jz — IDLE sibling latch +2 PC from last I$ return vaddr (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1jy stamped +2 from current I$
vaddr (already 7c0 in IDLE). Remember
the last `valid`/`kill_s2` return
vaddr (7b0 READ); IDLE `user[33]`
pair uses that for +2 PC. Still not
G1hj. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; IDLE `user[33]` pair; last I$ return vaddr |
| **Not** | G1jy current-vaddr 00. Not G1jw G1hj. Not G1jj. Not I4cg. |
| **Rule** | IDLE sibling pair +2 PC follows the returned line, not the next request. |
| **Site** | `frontend` g1jy latch. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1jy (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — last return was not
7b0 with IDLE pair, or leftover 11
blocked present. Keep. Isolated P4
stays.

### G1ka — present live user[33] pair at npc == last-return +2 (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1jy/G1jz flop missed the IDLE
window or leftover 11 blocked
slot0. Present combinationally from
live `user[33]` when npc is last I$
return sibling +2. Leftover 11 uses
slot1 (G1hl analog), not G1hm.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; live `user[33]` pair; npc 01 == last return sibling +2 |
| **Not** | G1jw G1hj. Not G1hm leftover inject. Not G1jj. Not I4cg. |
| **Rule** | Live sibling c.jalr presents at the last-return +2 npc the same cycle. |
| **Site** | `frontend` present next to G1jy. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1jz (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — at npc 7ba `user[33]`
is not the pair or last return +2
is not 7ba. Keep. Isolated P4 stays.

### G1kb — slot0-only aligned compressed keeps +2 c.jalr even if slot0 is not Branch (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1hz requires C.BEQZ/C.BNEZ; G1ik
7b8 is not Branch at ID. Keep +2
exact c.jalr in `[31:16]` for any
aligned-00 slot0-only compressed so
G1ib can un-hide slot1. Not G1fx
npc +2. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; slot0-only; npc/addr `[2:1]==00`; slot0 compressed; +2 exact c.jalr |
| **Not** | G1hz Branch-only. Not G1fx npc +2. Not G1jw. Not I4cg. |
| **Rule** | Slot0-only aligned compressed does not drop a live +2 c.jalr high half. |
| **Site** | `frontend` G1hz. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1ka (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — 7b8 not slot0-only
compressed with +2 c.jalr on that
beat. Keep. Isolated P4 stays.

### G1kc — leftover slot1 present of G1jy stash at npc-matched +2 (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1jy slot0 present skips leftover
11. G1ka leftover slot1 needs live
`user[33]`; G1hl needs G1hj. Present
the IDLE latch as slot1 at npc ==
latched +2 while leftover occupies
slot0. Not G1hm leftover inject
off-npc. Not G1jw G1hj. Isolated P4
stays.

| | |
|--|--|
| **Hits** | SMT+SS; G1jy live; leftover 11 slot0; npc 01 == latched +2 |
| **Not** | G1hm leftover inject. Not G1jw G1hj. Not G1ka live-user. Not I4cg. |
| **Rule** | IDLE sibling c.jalr presents as leftover slot1 at the latched +2 npc. |
| **Site** | `frontend` present next to G1ka leftover analog. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kb (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — G1jy stash empty at
npc 7ba, or leftover 11 not occupying
slot0 on that beat. Keep. Isolated
P4 stays.

### G1kd — G1jy capture without last-return; +2 PC from current I$ sibling (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1jy_cap required `g1jz_ret_v_q`.
7b0 may never valid/kill_s2 because
flush_i must still kill_s1 at npc 00
(G1jr/G1js). Capture IDLE `user[33]`
pair without last-return; +2 PC is
current I$ sibling +2 (not the 1-bit
`g1jx_sib_pc`). Present still
npc-matched (G1jy/G1kc). Not G1jw
G1hj. Not G1jx npc-already-+2.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; IDLE `user[33]` pair; no last I$ return |
| **Not** | G1jw G1hj. Not G1jz last-return PC. Not G1jx npc-already-+2. Not I4cg. |
| **Rule** | IDLE sibling pair latches at current I$ sibling +2 even if that line never returned valid/kill_s2. |
| **Site** | `frontend` G1jy_cap / `g1jy_pc_q`. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kc (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — IDLE `user[33]` pair
not on the bus with current vaddr
whose sibling is 7b8. Keep. Isolated
P4 stays.

### G1ke — same-line IDLE pair into G1jy (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

Sibling `user[33]` never the 7b8
pair. Latch current I$ `[15:0]`
compressed Branch + `[31:16]` exact
c.jalr at vaddr 00 during IDLE into
G1jy; +2 PC is this 8-byte line +2
(7b8→7ba). Not G1jw G1hj. Not G1jj
sibling stash. Not G1hn
valid/registered G1hj. Isolated P4
stays.

| | |
|--|--|
| **Hits** | SMT+SS; IDLE; vaddr 00; I$ `[15:0]` Branch + `[31:16]` exact c.jalr |
| **Not** | G1jw G1hj. Not G1jj sibling. Not G1hn G1hj. Not I4cg. |
| **Rule** | Same-line IDLE Branch+c.jalr latches at this line +2, npc-matched present. |
| **Site** | `frontend` G1jy_cap / `g1ke_pair`. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kd (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — 7b8 line not on live
I$ data during IDLE at vaddr 00.
Keep. Isolated P4 stays.

### G1kf — registered I$ same-line pair into G1jy (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1ke live dreq is already 7c0 in
IDLE. Latch the last registered I$
word (`g1et_data` / `icache_vaddr_q`)
same-line Branch+c.jalr pair into
G1jy without requiring
`icache_valid_q` (data_q holds after
valid drops). Not G1jw G1hj. Not
G1hn valid-beat G1hj. Isolated P4
stays.

| | |
|--|--|
| **Hits** | SMT+SS; IDLE; registered vaddr 00; `g1et_data` Branch + exact c.jalr |
| **Not** | G1ke live dreq. Not G1jw G1hj. Not G1hn G1hj. Not I4cg. |
| **Rule** | Last registered same-line pair latches at that line +2 after valid drops. |
| **Site** | `frontend` G1jy_cap / `g1kf_pair`. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1ke (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — registered I$ word
is not the 7b8 pair during IDLE
(never registered, or overwritten
by 7c0). Keep. Isolated P4 stays.

### G1kg — same-line pair on kill_s2 into G1jy (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1ke/G1kf IDLE-only; 7b8 fill may
die as kill_s2 (valid muted, data
still on the bus). Latch incoming
vaddr-00 Branch+c.jalr pair into
G1jy. Not G1jp all npc-00 kill_s2
spare. Not G1jw G1hj. Not G1hr
[31:16] c.jalr into G1hj. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; kill_s2; vaddr 00; incoming I$ Branch + exact c.jalr |
| **Not** | G1jp kill_s2 spare. Not G1jw G1hj. Not G1hr G1hj. Not I4cg. |
| **Rule** | kill_s2 same-line pair latches at this line +2, npc-matched present. |
| **Site** | `frontend` G1jy_cap / `g1kg_pair`. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kf (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — 7b8 pair not on
incoming I$ data during kill_s2 at
vaddr 00. Keep. Isolated P4 stays.

### G1kh — kill_s2 sibling user[33] pair into G1jy (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1kg is same-line data on kill_s2.
Sibling of 7b0 is the 7b8
Branch+c.jalr pair on `user[33]`.
Latch that into G1jy on kill_s2
(not G1hj/G1jl). Not G1jp kill_s2
spare. Not G1jw G1hj. Isolated P4
stays.

| | |
|--|--|
| **Hits** | SMT+SS; kill_s2; `user[33]` sibling Branch + exact c.jalr |
| **Not** | G1jp kill_s2 spare. Not G1jw G1hj. Not G1jl G1hj. Not I4cg. |
| **Rule** | kill_s2 sibling pair latches at sibling +2, npc-matched present. |
| **Site** | `frontend` G1jy_cap / `g1kh_sib`. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kg (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — sibling `user[33]`
pair not on the bus during kill_s2.
Keep. Isolated P4 stays.

### G1ki — I$ sticky last sibling pair on user[33] (**HOLD-FAIL 2026-08-20** — reverted)

Sticky `user[33]` across vaddr
change so G1ka can present at
last-return +2. Live `user[34]`
gated G1jl/G1jy/G1kh. Lottery
PASS @558. FDT PASS @2719. Hold
no cookie @600000 `[1000]=51b1c001`
no BANR (success-cave lui without
addi). Restore G1kh bit-identical
`229c4e51` / `f3d41166`. Do not
re-land. Isolated P4 stays.

### G1kj — npc-matched sibling pair into G1jy with full +2 PC (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

`g1jx_sib_pc` was 1-bit (never
matched). Widen to VLEN and capture
into G1jy when npc is already the
sibling +2, not G1hj (G1hm leftover
inject — G1jw). Drop the npc term
from G1jl_hi. Not G1ki sticky.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; live `user[33]` pair; npc 01 == current I$ sibling +2 |
| **Not** | G1jx into G1hj. Not G1ki sticky. Not G1jw. Not I4cg. |
| **Rule** | When npc is already the sibling +2, latch the live pair into G1jy. |
| **Site** | `frontend` `g1jx_sib_pc` / `g1kj_npc` / G1jy_cap. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kh (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — at npc 7ba I$ vaddr
is not 7b0, or `user[33]` is not
the pair. Keep. Isolated P4 stays.

### G1kk — aligned-00 RVI LOAD rd recovers sibling 01 Branch as c.jalr (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

`7b0` is `ld a5,96(s4)` on the same
16-byte line as `7ba`. Latch rd at
aligned-00 RVI LOAD; rewrite a
sibling 01 Branch as `c.jalr` of
that rd (a5, not G1ie a0). Not
G1je any-op. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; aligned-00 RVI LOAD rd!=0; sibling 16-byte-line 01 Branch |
| **Not** | G1ie C2 rs1'. Not G1je any-op. Not I4cg. |
| **Rule** | Present rewrite of 01 Branch on the captured LOAD's 16-byte line is `c.jalr rd`. |
| **Site** | `frontend` `g1kk_v_q` / `g1kk_rd_q` / `g1kk_line_q`. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kj (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — rewrite needs a live
01 Branch slot; npc 7ba has none
(leftover occupies present). Keep.
Isolated P4 stays.

### G1kl — present G1kk c.jalr at npc 01 of the LOAD's sibling 8-byte half (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1kk rewrite needs a live 01 Branch
slot; npc 7ba has none. Present slot0
at npc from the captured LOAD-rd
`c.jalr`, sibling 8-byte 01 of that
16-byte line. G1hk analog, not G1hj
bits. Not G1hm leftover inject. Not
G1je any-op. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1kk_v_q; npc 01 sibling of captured aligned-00 LOAD |
| **Not** | G1hm leftover inject. Not G1he all mid-line. Not G1je any-op. Not I4cg. |
| **Rule** | Present slot0 at npc == sibling 01 of the captured LOAD as `c.jalr rd`. Skip leftover 11 slot0. |
| **Site** | `frontend` G1kl present; `g1kk_a3_q`. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kk (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — leftover 11 occupies
slot0 (hangj `766` @20371 still in
window); G1kl skips like G1hk. Keep.
Isolated P4 stays.

### G1km — leftover slot1 present of G1kk c.jalr at npc sibling 01 (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1kl slot0 present skips leftover 11
(G1hk same skip). Present the LOAD-rd
`c.jalr` as slot1 at npc sibling 01
while leftover occupies slot0. G1hl
analog. Not G1hm leftover inject
off-npc. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1kk_v_q; leftover 11 slot0; npc 01 sibling of captured LOAD |
| **Not** | G1hm leftover inject off-npc. Not G1jw. Not I4cg. |
| **Rule** | Leftover-complete slot1 at npc sibling 01 is `c.jalr rd` from G1kk. |
| **Site** | `frontend` G1km leftover slot1. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kl (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — G1kl slot0 *and*
G1km slot1 both idle ⇒ `g1kk_v_q`
empty at npc 7ba (7b0 not captured
as present aligned-00 RVI LOAD).
Keep. Isolated P4 stays.

### G1kn — aligned-00 RVI LOAD from I$ data into G1kk (**landed 2026-08-20**; fired, residual unchanged)

Present `instruction_valid` missed
`7b0` (`g1kk_v_q` empty at npc 7ba —
G1kl/G1km). Capture aligned-00 RVI
LOAD from I$ (valid or IDLE) into
G1kk. G1ke analog, not G1jy pair.
Not G1jw G1hj. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; I$ vaddr 00 RVI LOAD rd!=0; valid or IDLE |
| **Not** | G1ke Branch+c.jalr pair. Not G1jw G1hj. Not G1ki sticky. Not I4cg. |
| **Rule** | I$ aligned-00 RVI LOAD arms G1kk without present `instruction_valid`. |
| **Site** | `frontend` `g1kn_load` / G1kk flop. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window **+3 cy** vs
G1km (`7ba` cmt @20464, hangj `766`
@20459, no `@71e4` after). Fired;
residual unchanged. Keep. Isolated
P4 stays.

### G1ko — G1kk survives leftover Jump flush_i (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1kn I$ capture fired (+3 cy) but
`7ba` still Branch. G1ju analog:
leftover Jump `flush_i` must not
clear G1kk. `is_mispredict` still
clears. Not G1jr/G1js npc-00
`flush_i` !kill_s1. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1kk_v_q; leftover Jump flush_i (g1hv\|g1jq) |
| **Not** | G1jr/G1js npc-00 flush kill_s1. Not G1jv capture-beats-flush. Not I4cg. |
| **Rule** | Leftover Jump `flush_i` does not drop G1kk. `is_mispredict` still does. |
| **Site** | `frontend` G1kk flop. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kn (`7ba` cmt @20464, hangj
`766` @20459, no `@71e4` after).
Did not fire — leftover Jump not
serving between `7b0` and npc `7ba`
(hangj @20374 before `7b0`; @20459
after npc 7ba). Keep. Isolated P4
stays.

### G1kp — G1kk capture beats flush_i (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1ko leftover Jump flush hygiene.
G1jv analog: same-cycle G1kk capture
beats `flush_i` clear. `is_mispredict`
still first. Not G1jr/G1js. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1kk_cap same cycle as flush_i |
| **Not** | G1jr/G1js npc-00 flush kill_s1. Not G1ko leftover-only keep. Not I4cg. |
| **Rule** | Capture of aligned-00 RVI LOAD / I$ LOAD beats `flush_i` clear. |
| **Site** | `frontend` `g1kk_cap` / G1kk flop. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1ko (`7ba` cmt @20464, hangj
`766` @20459, no `@71e4` after).
Did not fire — not a same-cycle
flush vs capture. Keep. Isolated
P4 stays.

### G1kq — G1kk survives leftover Jump is_mispredict (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1kp capture-beats-flush hygiene.
G1hw analog: leftover Jump
`is_mispredict` (`g1hv`/`g1jq`) must
not clear G1kk. `ex_valid` still
clears. Not G1iy all-01. Not G1jt
all npc-00. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1kk_v_q; leftover Jump is_mispredict (g1hv\|g1jq) |
| **Not** | G1iy all-01. Not G1jt all npc-00. Not I4cg. |
| **Rule** | Leftover Jump `is_mispredict` does not drop G1kk. `ex_valid` still does. |
| **Site** | `frontend` G1kk flop. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kp (`7ba` cmt @20464, hangj
`766` @20459, no `@71e4` after).
Did not fire — leftover Jump not
serving between `7b0` and npc `7ba`.
Keep. Isolated P4 stays.

### G1kr — G1kk survives is_mispredict at npc 00 (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1kq leftover Jump is_mispredict
hygiene. G1jt analog: `is_mispredict`
while npc is aligned 00 must not
clear G1kk (`7b8` c.beqz between
`7b0` and npc `7ba`). `ex_valid`
still clears. Not G1iy all-01.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1kk_v_q; is_mispredict at npc 00 (g1jt) |
| **Not** | G1iy all-01. Not G1kq leftover Jump only. Not I4cg. |
| **Rule** | Aligned-00 `is_mispredict` does not drop G1kk. `ex_valid` still does. |
| **Site** | `frontend` G1kk flop / `g1jt_spare_misp`. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kq (`7ba` cmt @20464, hangj
`766` @20459, no `@71e4` after).
Did not fire. Keep. Isolated P4
stays.

### G1ks — G1kk consume only at sibling 01 (**landed 2026-08-20**; fired, residual unchanged)

G1kk consume matched any 01 of the
16-byte line — `7b2` (mid-LOAD) can
drop the latch before npc `7ba`.
Consume only at sibling 01
(`addr[3] != g1kk_a3_q`). Isolated
P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1kk_v_q consume at 01 of the captured LOAD's 16-byte line |
| **Not** | G1if any-slot. Not G1je any-op. Not I4cg. |
| **Rule** | G1kk clears only when the sibling 8-byte 01 is consumed, not mid-LOAD 01. |
| **Site** | `frontend` G1kk flop consume. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window **−16 cy**
vs G1kr (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after).
Fired; residual unchanged — latch
survived `7b2` but G1kl still did
not present `c.jalr` at npc `7ba`.
Keep. Isolated P4 stays.

### G1kt — G1kk keep-until-sibling-01 (**landed 2026-08-20**; fired, residual unchanged)

G1ks sibling consume fired (−16 cy)
but `7ba` still Branch. G1jb analog:
do not replace G1kk with a different
16-byte line until that line's
sibling 01 is consumed. Same-line
recapture allowed. Not G1ki sticky.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1kk_v_q live; new capture on a different 16-byte line |
| **Not** | G1ki I$ sticky user[33]. Not G1if. Not I4cg. |
| **Rule** | A live G1kk latch is not replaced by a LOAD on a different 16-byte line. |
| **Site** | `frontend` G1kk flop capture guard. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window back to
G1jo (`7ba` cmt @20461, hangj `766`
@20456, no `@71e4` after) — undid
G1ks −16 cy. Fired; residual
unchanged. A first LOAD can block
`7b0`. Keep. Isolated P4 stays.

### G1ku — G1kk I$ capture only when npc is on the same 16-byte line (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1kt keep-until-01 blocked later
`7b0` with a first LOAD from
elsewhere. G1kn I$ capture only when
npc is on the same 16-byte line as
the I$ vaddr. Not G1ki sticky.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; I$ vaddr 00 RVI LOAD; npc same 16-byte line |
| **Not** | G1ki sticky. Not G1kn any-vaddr. Not I4cg. |
| **Rule** | I$ aligned-00 RVI LOAD arms G1kk only if npc is on that 16-byte line. |
| **Site** | `frontend` `g1kn_load` npc[VLEN-1:4]. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kt (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — present-path still
captures any aligned-00 LOAD. Keep.
Isolated P4 stays.

### G1kv — present-path G1kk capture only when npc is on the same 16-byte line (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1ku I$ npc-line hygiene. Present-path
aligned-00 RVI LOAD arms G1kk only
when npc is on the same 16-byte line.
G1ku analog. Not G1ki. Isolated P4
stays.

| | |
|--|--|
| **Hits** | SMT+SS; present aligned-00 RVI LOAD; npc same 16-byte line |
| **Not** | G1ki sticky. Not any-ID LOAD. Not I4cg. |
| **Rule** | Present-path G1kk capture requires npc on the LOAD's 16-byte line. |
| **Site** | `frontend` `g1kk_cap` present loop. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1ku (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — 7b0 is not
instruction_valid while npc is on
that line (I$ already 7c0). Keep.
Isolated P4 stays.

### G1kw — G1kk from registered I$ aligned-00 RVI LOAD (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1kv present npc-line hygiene. Live
I$ at npc 7ba is 7c0; present is
leftover. Capture G1kk from
registered I$ (`g1et_data` /
`g1kf_vaddr`) aligned-00 RVI LOAD
when npc is on the same 16-byte
line (G1kf analog). Do not require
valid_q / IDLE. Not G1ki. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; registered aligned-00 RVI LOAD; npc same 16-byte line |
| **Not** | G1ki sticky. Not G1kn live dreq. Not I4cg. |
| **Rule** | G1kk from registered I$ LOAD when npc is on that 16-byte line. |
| **Site** | `frontend` `g1kw_load` into `g1kk_cap`. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kv (`7ba` cmt @20461, hangj
`766` @20456, no `@71e4` after).
Did not fire — registered I$ is not
7b0 LOAD while npc is on that
16-byte line (last registered word
is 7b8/7c0). Keep.
Isolated P4 stays.

### G1kx — npc-line LOAD recapture may replace a held different-line LOAD (**landed 2026-08-20**; fired at OpenSBI 7ba, residual unchanged)

G1kw registered-I$ LOAD hygiene.
G1kt keep-until-sibling-01 lets a
first LOAD block 7b0. Allow recapture
when the new LOAD's 16-byte line is
npc's line. Same-line recapture
still allowed. Not G1ki. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; G1kk held; new npc-line LOAD different 16-byte line |
| **Not** | G1ki sticky. Not G1kt any different-line block. Not I4cg. |
| **Rule** | npc-line LOAD recapture may replace a held different-line LOAD. |
| **Site** | `frontend` G1kk flop capture. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window **−13 cy**
vs G1kw (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after;
G1ks window). Fired; residual
unchanged — later npc-line LOAD can
replace 7b0 before sibling 01.
Keep. Isolated P4 stays.

### G1ky — leftover slot1 G1kk present from same-cycle I$ LOAD cap (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1kx fired (−13 cy, residual
unchanged). G1km leftover slot1
needs the flop; capture at npc 7ba
presents next cycle. Present slot1
also from same-cycle I$ LOAD cap
(`g1kn`/`g1kw`) at npc sibling 01.
Not present-path `g1kk_cap` (comb
loop through `instruction_valid`).
Not G1hm. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; leftover 11 slot0; npc sibling 01; same-cycle I$ LOAD cap |
| **Not** | G1hm leftover inject. G1ki sticky. Present-path `g1kk_cap`. Not I4cg. |
| **Rule** | Leftover slot1 G1kk present from same-cycle I$ LOAD cap at npc sibling 01. |
| **Site** | `frontend` G1km + `g1ky_cap`. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kx (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after).
Did not fire — `g1kn`/`g1kw` not
true at npc 7ba (live I$ 7c0,
registered not 7b0). Keep.
Isolated P4 stays.

### G1kz — G1kl slot0 present from same-cycle I$ LOAD cap (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1ky leftover slot1 same-cycle I$
hygiene. G1kl slot0 from flop only;
skips leftover 11. Present slot0
also from same-cycle I$ LOAD cap
(`g1ky_cap`) at npc sibling 01.
Leftover 11 still skips (G1km/G1ky
slot1). Not G1hm. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; npc sibling 01; same-cycle I$ LOAD cap; not leftover 11 |
| **Not** | G1hm leftover inject. G1ki sticky. Not leftover-11 overwrite. Not I4cg. |
| **Rule** | G1kl slot0 present from same-cycle I$ LOAD cap at npc sibling 01. |
| **Site** | `frontend` G1kl + `g1ky_cap`. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1ky (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after).
Did not fire — leftover 11 still
skips and `g1ky_cap` is not true at
npc 7ba. Keep. Isolated P4 stays.

### G1la — G1kl does not skip leftover 11 when G1kk sibling 01 matches (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1kz slot0 same-cycle I$ hygiene.
G1kl skipped leftover 11. Present
slot0 c.jalr at npc sibling 01 even
when leftover occupies slot0 (flop
or `g1ky_cap`). Not G1hm off-npc
inject. Not G1jw. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; npc sibling 01; G1kk match; leftover 11 slot0 |
| **Not** | G1hm off-npc inject. G1jw G1hj. G1ki sticky. Not I4cg. |
| **Rule** | G1kl does not skip leftover 11 when G1kk sibling 01 matches. |
| **Site** | `frontend` G1kl leftover skip. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1kz (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after).
Did not fire — latch/cap still do
not match sibling 01 at npc 7ba.
Keep. Isolated P4 stays.

### G1lb — I$ LOAD may replace G1kk even when npc is off that line (**landed 2026-08-20**; fired, cookie t=206848, 7ba residual unchanged)

G1la leftover-skip hygiene. Present
path idle without 7b0 in G1kk. I$
aligned-00 RVI LOAD may replace
G1kk even when npc is not on that
line (latest I$ LOAD; undo G1ku+G1kt
for `g1kn`). Not G1ki. Isolated P4
stays.

| | |
|--|--|
| **Hits** | SMT+SS; I$ aligned-00 RVI LOAD; replace held different-line G1kk |
| **Not** | G1ki sticky. Not G1ku npc-line. Not G1kt keep for g1kn. Not I4cg. |
| **Rule** | Latest I$ aligned-00 RVI LOAD replaces G1kk even off npc-line. |
| **Site** | `frontend` `g1kn_load` + G1kk flop. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=206848**
(was t=83968 G1jo) + BANR. TRACE
7ba window identical to G1la (`7ba`
cmt @20448, hangj `766` @20443, no
`@71e4` after). Fired; cookie later;
7ba residual unchanged (later I$
LOAD overwrite, G1ks class). Keep.
Isolated P4 stays.

### G1lc — I$ LOAD recapture only when G1kk is empty (**landed 2026-08-20**; hygiene vs G1lb, cookie still t=206848)

G1lb fired (cookie t=206848, 7ba
unchanged). Restore G1kt
keep-until-01 for `g1kn` (no later
I$ LOAD replace). Keep G1ku undo:
empty latch still arms off-npc I$.
Not G1ki. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1kn; G1kk already held different-line |
| **Not** | G1ki sticky. Not restore G1ku npc-line. Not I4cg. |
| **Rule** | I$ LOAD recapture only when G1kk is empty or G1kx npc-line. |
| **Site** | `frontend` G1kk flop (`g1kn_load` bypass removed). Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=206848**
+ BANR. TRACE 7ba window identical
to G1lb (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after;
j766cmt @204987). Did not fire —
cookie delay is off-npc empty-latch
arm (G1ku undo), not later replace.
Keep. Isolated P4 stays.

### G1ld — restore G1ku npc-line on `g1kn` (**landed 2026-08-20**; fired, cookie t=83968 restored)

G1lc hygiene (cookie still t=206848).
Restore G1ku npc-line on `g1kn`
(undo remaining G1lb). Off-npc
empty-latch arm was the delay.
Not G1ki. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1kn I$ LOAD; npc same 16-byte line |
| **Not** | G1ki sticky. Not G1lb off-npc. Not I4cg. |
| **Rule** | I$ LOAD into G1kk only when npc is on that 16-byte line. |
| **Site** | `frontend` `g1kn_load` npc-line. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR (restored from t=206848).
slfix **bit-identical G1la**
`296f54ab` / `b410b55d`. TRACE 7ba
window identical to G1la (`7ba` cmt
@20448, hangj `766` @20443, no
`@71e4` after; j766cmt @83345).
Fired; cookie restored. Keep.
Isolated P4 stays.

### G1le — last I$ LOAD side-stash present at sibling 01 (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1ld restored cookie t=83968. Off-npc
I$ into G1kk delayed the cookie.
Last I$ aligned-00 RVI LOAD
side-stash (npc-independent), present
at that LOAD's sibling 01. G1kk stays
npc-line. Not G1ki. Not G1lb into
G1kk. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; I$ aligned-00 RVI LOAD; npc sibling 01 of that LOAD |
| **Not** | G1ki sticky. Not G1lb into G1kk. Not I4cg. |
| **Rule** | Last I$ LOAD side-stash presents c.jalr at that LOAD's sibling 01. |
| **Site** | `frontend` `g1le_*` + G1kl/G1km. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1ld (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after).
Did not fire — last I$ LOAD at npc
7ba is not 7b0 (I$ already 7c0).
Keep. Isolated P4 stays.

### G1lf — g1le keep-until-sibling-01 (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1le hygiene (cookie t=83968; last
I$ LOAD not 7b0 at npc 7ba). Keep
until sibling 01 (G1kt analog):
same-line recapture allowed; later
different-line I$ LOAD does not
replace. Not G1ki. Not G1lb into
G1kk. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1le held; new I$ LOAD different 16-byte line |
| **Not** | G1ki sticky. Not G1lb into G1kk. Not I4cg. |
| **Rule** | g1le keep until sibling 01; same-line recapture allowed. |
| **Site** | `frontend` g1le flop. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1le (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after).
Did not fire — first I$ LOAD still
blocks 7b0. Keep. Isolated P4 stays.

### G1lg — npc-line recapture may replace a held different-line g1le (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lf hygiene (first I$ LOAD blocks
7b0). npc-line recapture may replace
a held different-line g1le (G1kx
analog). Same-line recapture still
allowed. Not G1ki. Not G1lb into
G1kk. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1le held; new I$ LOAD different 16-byte line that is npc's line |
| **Not** | G1ki sticky. Not G1lb into G1kk. Not I4cg. |
| **Rule** | npc-line I$ LOAD recapture may replace a held different-line g1le. |
| **Site** | `frontend` g1le flop capture. Isolated P4 stays. |
| **Timing** | Extra `npc_q[VLEN-1:4]` compare on g1le capture enable (G1kx analog; SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1lf (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after).
Did not fire — at npc 7ba live I$ is
7c0 (not LOAD). Keep. Isolated P4
stays.

### G1lh — present-path aligned-00 RVI LOAD into g1le (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lg hygiene (at npc 7ba live I$ is
7c0). Present-path aligned-00 RVI
LOAD into g1le (G1kv analog; no
npc-line — g1le is the off-npc
side-stash). Flop only (not leftover
present). I$ overwrite after present.
Not G1ki. Not G1lb into G1kk.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; present aligned-00 RVI LOAD rd!=0 |
| **Not** | G1ki sticky. Not G1lb into G1kk. Not leftover present (comb loop). Not I4cg. |
| **Rule** | Present-path aligned-00 RVI LOAD into g1le without npc-line. |
| **Site** | `frontend` `g1lh_load` / `g1le_cap`. Isolated P4 stays. |
| **Timing** | Extra present-slot LOAD decode into g1le cap mux (SMT+SS only; flop-only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1lg (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after).
Did not fire — 7b0 is not
instruction_valid at npc 7ba (G1kv).
Keep. Isolated P4 stays.

### G1li — registered I$ aligned-00 RVI LOAD into g1le (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lh hygiene (7b0 not
instruction_valid at npc 7ba).
Registered I$ aligned-00 RVI LOAD
into g1le (G1kw analog; no npc-line).
Last overwrite after live I$ (G1kk
order). Do not require valid_q /
IDLE. Not G1ki. Not G1lb into G1kk.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; registered I$ vaddr 00 RVI LOAD rd!=0 |
| **Not** | G1ki sticky. Not G1lb into G1kk. Not npc-line (G1kw). Not I4cg. |
| **Rule** | Registered I$ aligned-00 RVI LOAD into g1le without npc-line. |
| **Site** | `frontend` `g1li_load` / `g1le_cap`. Isolated P4 stays. |
| **Timing** | Extra registered-I$ LOAD decode into g1le cap mux (SMT+SS only; flop-only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1lh (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after).
Did not fire — registered I$ is not
7b0 at npc 7ba (G1kw). Keep.
Isolated P4 stays.

### G1lj — leftover slot1 g1le present from same-cycle I$/registered LOAD cap (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1li hygiene (registered I$ is not
7b0 at npc 7ba). Leftover slot1 g1le
present from same-cycle I$/registered
LOAD cap (G1ky analog; `g1le_load` /
`g1li_load`). Flop is next cycle; not
present-path `g1lh` (comb loop). Not
G1kl slot0 this increment. Not G1ki.
Not G1lb into G1kk. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; leftover 11 slot0; npc sibling 01; same-cycle g1le I$/registered LOAD cap |
| **Not** | G1hm leftover inject. G1ki sticky. Present-path `g1lh`. Not G1lb into G1kk. Not I4cg. |
| **Rule** | Leftover slot1 g1le present from same-cycle I$/registered LOAD cap at npc sibling 01. |
| **Site** | `frontend` G1km + `g1lj_cap`. Isolated P4 stays. |
| **Timing** | Extra g1le I$/registered sibling compare into leftover slot1 mux (SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1li (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after).
Did not fire — `g1le_load`/`g1li_load`
not true at npc 7ba. Keep. Isolated
P4 stays.

### G1lk — G1kl slot0 from same-cycle g1le I$/registered LOAD cap (**landed 2026-08-20**; cookie-delay revert)

G1lj hygiene (`g1le_load`/`g1li_load`
not true at npc 7ba). G1kl slot0 from
`g1lj_cap` (G1kz analog; no npc-line).
G1la leftover overwrite applies. Fired:
cookie **t=206848** (was t=83968) + BANR;
7ba residual unchanged. G1lb class —
later no-npc-line sibling rewrite.
Reverted. Restore G1lj slfix
`673cd1d8` / `cf66549f`. Do not re-land
G1kl from no-npc-line `g1lj_cap`.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; npc 01; same-cycle g1le I$/registered LOAD cap (`g1lj_cap`) |
| **Not** | G1ki sticky. Not G1lb into G1kk. Not leftover slot1 (G1lj kept). Not I4cg. |
| **Rule** | G1kl slot0 from same-cycle g1le I$/registered LOAD cap. **Reverted** (cookie delay). |
| **Site** | `frontend` G1kl. Isolated P4 stays. |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=206848**
+ BANR (was t=83968). TRACE 7ba window
identical to G1lj. Fired; cookie later;
residual unchanged. **Reverted**. After
revert: slfix bit-identical G1lj
`673cd1d8` / `cf66549f`; lottery **PASS
@558**; hold TRACE cookie **t=83968**
restored + BANR. Isolated P4 stays.

### G1ll — G1kl slot0 from same-cycle g1le I$/registered LOAD cap with npc-line (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lk reverted (cookie t=206848). G1kl
slot0 from same-cycle g1le
I$/registered LOAD cap **with npc-line**
(G1kz analog; not G1lk no-npc-line
`g1lj_cap`). G1la leftover overwrite
applies. Not leftover slot1 (G1lj
kept). Not G1ki. Not G1lb into G1kk.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; npc 01; same-cycle g1le I$/registered LOAD on npc's 16-byte line, sibling [3] |
| **Not** | G1lk no-npc-line `g1lj_cap`. G1ki sticky. Not G1lb into G1kk. Not leftover slot1. Not I4cg. |
| **Rule** | G1kl slot0 from same-cycle g1le I$/registered LOAD cap with npc-line. |
| **Site** | `frontend` G1kl + `g1ll_cap`. Isolated P4 stays. |
| **Timing** | Extra npc-line sibling compare into G1kl mux (SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1lj (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after).
Did not fire — `g1ll_cap` not true at
npc 7ba. Keep. Isolated P4 stays.

### G1lm — IQ-visible aligned-00 RVI LOAD sibling 01 recover (**landed 2026-08-20**; MINI-FAIL revert)

G1ll hygiene (`g1ll_cap` not true at
npc 7ba). IQ `valid_i` aligned-00 RVI
LOAD last-replace latch (G1ii analog);
IQ output sibling 01 rewritten as
c.jalr of that rd (no Branch-bits
gate — 7ba is not Branch at IQ).
Lottery **PASS @558**. FDT **FAILED**
printed **106** @200619 (`offset_ptr`
s11=98 t2!=81). Rewrote a real sibling
01. **Reverted**. Restore G1ll slfix
`93a79414` / `cb4dc600`. Do not re-land
IQ LOAD sibling-01 rewrite. Isolated
P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; IQ valid_i aligned-00 RVI LOAD; later sibling 01 IQ output |
| **Not** | G1if any-slot. G1ih Branch-bits only. Not G1lk. Not I4cg. |
| **Rule** | IQ-visible 00 LOAD recovers sibling 01 as c.jalr. **Reverted** (FDT 106). |
| **Site** | `instr_queue` (reverted). Isolated P4 stays. |

After revert: lottery **PASS @558**.
slfix bit-identical G1ll. FDT PASS
@2719 by identity. Cookie t=83968.
Isolated P4 stays.

### G1ln — ID-visible aligned-00 RVI LOAD arms sibling 01 Branch recover (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lm MINI-FAIL (IQ sibling-01 rewrite).
In-ID `issue_q` aligned-00 LOAD (rd!=0)
arms same 16-byte-line sibling 01
Branch as JALR of that rd (G1ik analog).
Keep 01 Branch-bits gate (not G1lm
any-01, not G1je any-op). Isolated P4
stays.

| | |
|--|--|
| **Hits** | SMT+SS; issue_q aligned-00 LOAD rd!=0; fetch 01 Branch sibling 16-byte line |
| **Not** | G1je any-op. G1lm IQ any-01. G1if any-slot. Not G1lk. Not I4cg. |
| **Rule** | In-ID aligned-00 LOAD recovers sibling 01 Branch as JALR of that rd. |
| **Site** | `id_stage` `g1ln_id_arm`. Isolated P4 stays. |
| **Timing** | Extra issue_q LOAD compare on ID recover mux (SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
to G1ll (`7ba` cmt @20448, hangj
`766` @20443, no `@71e4` after).
Did not fire — 7b0 is not in `issue_q`
when 7ba is at ID. Keep. Isolated P4
stays.

### G1lo — ID latch of aligned-00 RVI LOAD survives flush_i (**landed 2026-08-20**; fired later, 7ba residual unchanged)

G1ln hygiene (7b0 has left `issue_q`
before 7ba at ID). Latch aligned-00
LOAD (rd!=0) from `issue_q` / fetch
(last-replace, G1hx analog). Survives
`flush_i` (G1il analog). Recover
sibling 01 Branch as JALR of latched
rd. Keep 01 Branch-bits gate (not
G1lm, not G1je). Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; ID-visible aligned-00 LOAD rd!=0; later sibling 01 Branch |
| **Not** | G1je any-op. G1lm IQ any-01. G1if any-slot. Not G1lk. Not I4cg. |
| **Rule** | ID LOAD latch last-replace; survives flush; sibling 01 Branch → JALR of that rd. |
| **Site** | `id_stage` `g1lo_v_q`. Isolated P4 stays. |
| **Timing** | Extra ID LOAD flop + sibling compare (SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
(`7ba` cmt @20448, hangj `766` @20443,
no `@71e4` after). Fired later:
`j766cmt` @83225 (was @83345, −120 cy);
extra scratch @83208. Residual 7ba
unchanged — later ID LOAD may overwrite
7b0 before 7ba. Keep. Isolated P4
stays.

### G1lp — g1lo keep-until sibling 01 (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lo last-replace fired later (j766cmt
−120 cy) but 7ba unchanged — a later
ID LOAD may overwrite 7b0. Keep until
sibling 01 (G1lf analog): same-line
recapture allowed; 01-line recapture
may replace a held different-line LOAD
(G1lg analog at ID). Consume only at
sibling 01 (G1ks analog). Not G1ki.
Not G1lb. Not G1lk. Not G1lm.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1lo held; new ID 00 LOAD different 16-byte line |
| **Not** | G1ki sticky. Not G1lb into G1kk. Not G1lk. Not G1lm. Not I4cg. |
| **Rule** | g1lo keep until sibling 01; same-line recapture allowed; 01-line recapture may replace. |
| **Site** | `id_stage` g1lo flop. Isolated P4 stays. |
| **Timing** | Extra 16-byte line + fetch/issue 01 compares on g1lo capture (G1lf analog; SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
(`7ba` cmt @20448, hangj `766` @20443,
no `@71e4` after). `j766cmt` back
@83345 (G1lo later fire undone).
Did not fire at 7ba — first ID LOAD
can block 7b0. Keep. Isolated P4
stays.

### G1lq — IQ-visible aligned-00 RVI LOAD into g1lo_cap (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lp hygiene (first ID LOAD can block
7b0). Latch IQ-visible aligned-00 RVI
LOAD from `g1ct_valid` (IQ input after
G1ct smash; G1ii analog). Sideband
last-overwrite into `g1lo_cap` (G1li
analog). Flop only — keep 01
Branch-bits recover (not G1lm IQ
rewrite). Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1ct_valid aligned-00 RVI LOAD rd!=0 |
| **Not** | G1lm IQ rewrite. G1ki sticky. G1lh instruction_valid. Not G1lk. Not I4cg. |
| **Rule** | IQ-visible 00 LOAD last-replace into g1lo_cap. Recover still 01 Branch-bits. |
| **Site** | `frontend` g1lq flop + `id_stage` g1lo_cap. Isolated P4 stays. |
| **Timing** | Extra IQ-input LOAD flop + ID cap mux (SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
(`7ba` cmt @20448, hangj `766` @20443,
no `@71e4` after). Did not fire —
last IQ-visible 00 LOAD can overwrite
7b0. Keep. Isolated P4 stays.

### G1lr — g1lq keep-until sibling 01 (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lq hygiene (last IQ 00 LOAD can
overwrite 7b0). Keep until sibling 01
(G1lf analog): same-line recapture
allowed; npc-line recapture may
replace a held different-line LOAD
(G1lg analog). Consume only at
sibling 01 (G1ks analog). Not G1ki.
Not G1lm. Not G1lk. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1lq held; new g1ct_valid 00 LOAD different 16-byte line |
| **Not** | G1ki sticky. Not G1lm IQ rewrite. Not G1lk. Not I4cg. |
| **Rule** | g1lq keep until sibling 01; same-line recapture allowed; npc-line recapture may replace. |
| **Site** | `frontend` g1lq flop. Isolated P4 stays. |
| **Timing** | Extra 16-byte line + npc compares on g1lq capture (G1lf analog; SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
(`7ba` cmt @20448, hangj `766` @20443,
no `@71e4` after). Did not fire —
first IQ-visible 00 LOAD can block
7b0; 7b0 is not `g1ct_valid` at npc
7ba. Keep. Isolated P4 stays.

### G1ls — present-path instruction_valid 00 LOAD into g1lq_cap (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lr hygiene (first IQ 00 LOAD can
block 7b0). Present-path
`instruction_valid` aligned-00 RVI
LOAD into `g1lq_cap` (G1lh analog).
`g1ct_valid` still overwrites after
present. 7b0 may be presented but
G1ct-muted. Not G1lm. Isolated P4
stays.

| | |
|--|--|
| **Hits** | SMT+SS; instruction_valid aligned-00 RVI LOAD rd!=0 |
| **Not** | G1lm IQ rewrite. G1ki sticky. Not leftover present. Not G1lk. Not I4cg. |
| **Rule** | present-path 00 LOAD into g1lq_cap; g1ct overwrite after. |
| **Site** | `frontend` g1lq_cap mux. Isolated P4 stays. |
| **Timing** | Extra instruction_valid LOAD compare on g1lq_cap (G1lh analog; SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
(`7ba` cmt @20448, hangj `766` @20443,
no `@71e4` after). Did not fire —
7b0 is not `instruction_valid` at npc
7ba (G1lh class). Keep. Isolated P4
stays.

### G1lt — live I$ aligned-00 RVI LOAD into g1lq_cap (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1ls hygiene (7b0 not
instruction_valid at npc 7ba). Live
I$ aligned-00 RVI LOAD into
`g1lq_cap` (G1le analog; overwrite
after present). Keep-until-01 still
filters (not G1lb into G1kk). Not
G1lm. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; live I$ aligned-00 RVI LOAD rd!=0 |
| **Not** | G1lb into G1kk. G1lm IQ rewrite. G1ki sticky. Not I4cg. |
| **Rule** | live I$ 00 LOAD overwrite into g1lq_cap after present. |
| **Site** | `frontend` g1lq_cap mux (`g1le_load`). Isolated P4 stays. |
| **Timing** | Extra live-I$ LOAD mux on g1lq_cap (G1le analog; SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
(`7ba` cmt @20448, hangj `766` @20443,
no `@71e4` after). Did not fire —
last I$ LOAD at npc 7ba is not 7b0
(I$ already 7c0). Keep. Isolated P4
stays.

### G1lu — registered I$ aligned-00 RVI LOAD into g1lq_cap (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lt hygiene (last I$ LOAD at npc
7ba is not 7b0). Registered I$
aligned-00 RVI LOAD into `g1lq_cap`
(G1li analog; overwrite when live
dreq missed). Keep-until-01 still
filters (not G1lb into G1kk). Not
G1lm. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; registered I$ aligned-00 RVI LOAD rd!=0 |
| **Not** | G1lb into G1kk. G1lm IQ rewrite. G1ki sticky. Not I4cg. |
| **Rule** | registered I$ 00 LOAD overwrite into g1lq_cap when live dreq missed. |
| **Site** | `frontend` g1lq_cap mux (`g1li_load`). Isolated P4 stays. |
| **Timing** | Extra registered-I$ LOAD mux on g1lq_cap (G1li analog; SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
(`7ba` cmt @20448, hangj `766` @20443,
no `@71e4` after). Did not fire —
registered I$ is not 7b0 at npc 7ba
(G1li class). Keep. Isolated P4
stays.

### G1lv — leftover slot1 g1lq present at npc sibling 01 (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lu hygiene (registered not 7b0 at
npc 7ba). Leftover slot1 from flopped
`g1lq` at npc sibling 01 (`g1le_hit`
analog). Same-cycle I$/registered
leftover slot1 is G1lj. Not G1lk
G1kl from no-npc-line. Not present-
path (comb loop). Not G1lm.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; leftover 11 slot0; npc sibling 01; g1lq_v_q holds that 16-byte line |
| **Not** | G1lk G1kl. G1lm IQ rewrite. G1hm leftover inject. Present-path comb loop. Not I4cg. |
| **Rule** | Leftover slot1 g1lq present as c.jalr of latched rd at npc sibling 01. |
| **Site** | `frontend` G1km + `g1lq_hit`. Isolated P4 stays. |
| **Timing** | Extra g1lq sibling compare into leftover slot1 mux (SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
(`7ba` cmt @20448, hangj `766` @20443,
no `@71e4` after). Did not fire —
leftover 11 not occupying slot0 at
npc 7ba, or g1lq does not hold 7b0.
Keep. Isolated P4 stays.

### G1lw — G1kl slot0 from g1lq_hit (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lv hygiene (leftover slot1 missed
at npc 7ba). G1kl slot0 from
`g1lq_hit` (npc-line; G1ll analog).
G1la leftover overwrite applies.
Not G1lk no-npc-line. Not G1lm.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; npc 01; g1lq_v_q holds that 16-byte line |
| **Not** | G1lk no-npc-line. G1lm IQ rewrite. G1hm off-npc inject. Not I4cg. |
| **Rule** | G1kl slot0 from g1lq_hit as c.jalr of latched rd. |
| **Site** | `frontend` G1kl + `g1lq_hit`. Isolated P4 stays. |
| **Timing** | Extra g1lq_hit term on G1kl slot0 present (SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR (not delayed). TRACE 7ba
window identical (`7ba` cmt @20448,
hangj `766` @20443, no `@71e4`
after). Did not fire — `g1lq_hit`
not true at npc 7ba (g1lq does not
hold 7b0). Keep. Isolated P4 stays.

### G1lx — g1lq overwrite of g1lo_cap gated to empty or fetch 01 line (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lw hygiene (`g1lq_hit` not true at
npc 7ba). g1lq last-overwrite of
`g1lo_cap` only when g1lo is empty or
g1lq line is the current fetch/issue
01 line. A held first LOAD in g1lq
no longer stuffs `g1lo_cap` every
cycle. Not G1lk. Not G1lm.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1lq_v; g1lo held; g1lq line != current 01 line |
| **Not** | G1lk. G1lm IQ rewrite. G1ki sticky. Not I4cg. |
| **Rule** | g1lq overwrites g1lo_cap only if g1lo empty or g1lq line == fetch/issue 01 line. |
| **Site** | `id_stage` g1lo_cap mux. Isolated P4 stays. |
| **Timing** | Extra g1lo_v / g1lp_01_line compare on g1lq overwrite (SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba window identical
(`7ba` cmt @20448, hangj `766` @20443,
no `@71e4` after). Did not fire —
issue/fetch still do not present 7b0
when overwrite is gated. Keep.
Isolated P4 stays.

### G1ly — same-line g1lq overwrite of held g1lo (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lx hygiene (issue/fetch still miss
7b0). Also allow g1lq overwrite of
`g1lo_cap` when g1lq line == held
g1lo line (same-line sideband
recapture). Not G1lk. Not G1lm.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; g1lq_v; g1lo held; g1lq line == held g1lo line |
| **Not** | G1lk. G1lm IQ rewrite. G1ki sticky. Not I4cg. |
| **Rule** | g1lq overwrites g1lo_cap if empty, same-line, or fetch/issue 01 line. |
| **Site** | `id_stage` g1lo_cap mux. Isolated P4 stays. |
| **Timing** | Extra g1lo_line compare on g1lq overwrite (SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba identical
(`7ba` cmt @20448, hangj `766` @20443,
no `@71e4` after). Did not fire —
g1lq still does not hold 7b0 (or g1lo
does not hold a same-line LOAD). A
shared g1lo flop lets a peer hart's
00 LOAD occupy 7b0. Keep.
Isolated P4 stays.

### G1lz — per-hart g1lo LOAD latch (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1ly hygiene (g1lq still misses 7b0).
One g1lo latch per hart so a peer 00
LOAD cannot occupy hart0's 7b0. G1ln
same-hart. g1lq overwrite indexes
`smt_hart_id_i` (g1lq has no hart tag
yet). Keep 01 Branch-bits recover.
Not G1lk. Not G1lm. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; NrHarts>1; 00 LOAD vs 01 Branch different hart_id |
| **Not** | G1lk. G1lm IQ rewrite. G1ki sticky. Not I4cg. |
| **Rule** | g1lo capture/keep/consume/recover is per-hart. G1ln arms only same-hart. |
| **Site** | `id_stage` g1lo array + G1ln hart compare. Isolated P4 stays. |
| **Timing** | Extra hart-index mux on g1lo recover (SMT+SS only; NrHarts=2). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba identical
(`7ba` cmt @20448, hangj `766` @20443,
j766cmt @83345, no `@71e4` after).
Did not fire — hart0 still does not
hold 7b0 at npc 7ba. Occupancy is not
only a peer hart (hart0's own first
LOAD or 7b0 never at ID). Keep.
Isolated P4 stays.

### G1ma — per-hart g1lq IQ LOAD latch (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1lz hygiene (hart0 still misses 7b0).
One g1lq latch per hart so a peer IQ
00 LOAD cannot occupy hart0's
sideband into g1lo. Capture/consume
the active hart; sideband is the
full per-hart array. Keep 01
Branch-bits recover. Not G1lk. Not
G1lm. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; NrHarts>1; IQ/present/I$ 00 LOAD on a peer hart |
| **Not** | G1lk. G1lm IQ rewrite. G1ki sticky. Not I4cg. |
| **Rule** | g1lq capture/keep/consume/hit is per-hart; each hart's g1lq feeds that hart's g1lo. |
| **Site** | `frontend` g1lq array + `cva6` sideband + `id_stage` g1lo_cap. Isolated P4 stays. |
| **Timing** | Extra hart-index mux on g1lq hit/sideband (SMT+SS only; NrHarts=2). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba identical
(`7ba` cmt @20448, hangj `766` @20443,
j766cmt @83345, no `@71e4` after).
Did not fire — g1lq[hart0] still
does not hold 7b0 at npc 7ba. Keep.
Isolated P4 stays.

### G1mb — per-hart g1le I$ LOAD side-stash (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1ma hygiene (g1lq[hart0] still
misses 7b0). One g1le latch per hart
so a peer I$ 00 LOAD cannot occupy
hart0's leftover/G1kl path.
Capture/hit/consume the active hart;
mispredict/flush drop only that hart.
Not G1lk. Not G1lm. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; NrHarts>1; I$/present 00 LOAD on a peer hart |
| **Not** | G1lk. G1lm IQ rewrite. G1ki sticky. Not I4cg. |
| **Rule** | g1le capture/keep/consume/hit is per-hart. |
| **Site** | `frontend` g1le array. Isolated P4 stays. |
| **Timing** | Extra hart-index mux on g1le hit (SMT+SS only; NrHarts=2). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba identical
(`7ba` cmt @20448, hangj `766` @20443,
j766cmt @83345, no `@71e4` after).
Did not fire — g1le[hart0] still
does not hold 7b0 at npc 7ba. Keep.
Isolated P4 stays.

### G1mc — per-hart G1kk LOAD recover latch (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1mb hygiene (g1le[hart0] still
misses 7b0). One G1kk latch per hart
so a peer 00 LOAD cannot occupy
hart0's G1kl/leftover c.jalr path.
Capture/hit/consume the active hart;
mispredict/flush drop only that hart.
Not G1lk. Not G1lm. Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; NrHarts>1; 00 LOAD on a peer hart |
| **Not** | G1lk. G1lm IQ rewrite. G1ki sticky. Not I4cg. |
| **Rule** | G1kk capture/keep/consume/G1kl is per-hart. |
| **Site** | `frontend` g1kk array. Isolated P4 stays. |
| **Timing** | Extra hart-index mux on G1kl (SMT+SS only; NrHarts=2). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba identical
(`7ba` cmt @20448, hangj `766` @20443,
j766cmt @83345, no `@71e4` after).
Did not fire — g1kk[hart0] still
does not hold 7b0 at npc 7ba.
Per-hart LOAD latches (g1lo/g1lq/
g1le/g1kk) exhausted. Keep.
Isolated P4 stays.

### G1md — commit-visible aligned-00 RVI LOAD into g1lo (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1mc hygiene (per-hart LOAD latches
exhausted). Retire of aligned-00 RVI
LOAD last-replaces that hart's g1lo
(keep-until would block 7b0 behind
an earlier LOAD). Keep 01 Branch-
bits recover. Not G1lk. Not G1lm.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; commit_ack; uncompressed 00 LOAD rd!=0 |
| **Not** | G1lk. G1lm IQ rewrite. G1ki sticky. Not I4cg. |
| **Rule** | Commit 00 RVI LOAD last-replaces g1lo[hart]; keep-until bypassed for that source. |
| **Site** | `id_stage` g1lo_cap + `cva6` commit ports. Isolated P4 stays. |
| **Timing** | Extra commit fu/pc compare on g1lo_cap (SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba identical
(`7ba` cmt @20448, hangj `766` @20443,
j766cmt @83345, no `@71e4` after).
Did not fire — g1lo still does not
hold 7b0 at npc 7ba (SMT flush_i
skips the capture loop). Keep.
Isolated P4 stays.

### G1me — g1lo commit capture beats flush_i (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1md hygiene (SMT flush_i skipped
capture). Commit 00 RVI LOAD still
captures into g1lo on leftover jal
flush (G1kp analog). Do not consume
on that cycle. Keep 01 Branch-bits
recover. Not G1lk. Not G1lm.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; flush_i; commit_ack 00 RVI LOAD |
| **Not** | G1lk. G1lm IQ rewrite. G1ki sticky. Not I4cg. |
| **Rule** | SMT flush_i still last-replaces g1lo from a retiring 00 RVI LOAD. |
| **Site** | `id_stage` g1lo flop flush arm. Isolated P4 stays. |
| **Timing** | Extra g1md_cmt capture on flush (SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba identical
(`7ba` cmt @20448, hangj `766` @20443,
j766cmt @83345, no `@71e4` after).
Did not fire — 7b0 may retire after
7ba is already at ID (lotgpr @20430
is not commit). Keep.
Isolated P4 stays.

### G1mf — SB result-valid aligned-00 RVI LOAD into g1lo (**landed 2026-08-20**; hygiene at OpenSBI 7ba)

G1me hygiene (7b0 may retire after
7ba at ID). Scoreboard result-valid
aligned-00 RVI LOAD last-replaces
g1lo[hart] (WB done, before
commit_ack). Keep 01 Branch-bits
recover. Not G1lk. Not G1lm.
Isolated P4 stays.

| | |
|--|--|
| **Hits** | SMT+SS; issued; sbe.valid; uncompressed 00 LOAD rd!=0 |
| **Not** | G1lk. G1lm IQ rewrite. G1ki sticky. Not I4cg. |
| **Rule** | Result-valid 00 RVI LOAD last-replaces g1lo[hart]; keep-until bypassed. |
| **Site** | `scoreboard` scan + `id_stage` g1lo_cap. Isolated P4 stays. |
| **Timing** | Extra SB-entry fu/pc scan on g1lo_cap (SMT+SS only). |

Lottery **PASS @558**. FDT **PASS
@2719**. Hold TRACE cookie **t=83968**
+ BANR. TRACE 7ba identical
(`7ba` cmt @20448, hangj `766` @20443,
j766cmt @83345, no `@71e4` after).
Did not fire — last SB 00 LOAD is
not 7b0, or 7b0 is not yet
sbe.valid at npc 7ba. Keep.
Isolated P4 stays.

### G1mg — not next (superseded by CONTRACT.md)

G1mf hygiene (last SB 00 LOAD is not
7b0). **Do not land** SB 00 LOAD into
g1lo gated by fetch/issue 01 line —
more layer-2 capture, same miss as
G1mf. Next is `CONTRACT.md`: Phase 1
`mini_sib_cjalr` (fail-codes), then
layer-1 present-at-npc, then EXTRACT
E4 `g6lc_sib_cjalr`. Keep 01
Branch-bits recover. Not G1lk. Not
G1lm. Watch cookie t=83968 / FDT 106.
Isolated P4 stays.

### mini_sib_cjalr — CONTRACT Phase 1 (soaked 2026-08-20)

Directed class oracle for sibling `ld@00` + `c.jalr@01` + leftover `jal x0`
skip-path. Not an OpenSBI VA. Fail-codes 1–12 in the file header.
`c.bnez` uses `a2` (rs1'). Check `a0` after `c.jalr` (not `t1`).

| Plane | Result |
|-------|--------|
| Spike | **PASS** tohost=1 (P3 far helper moves tohost past text `ALIGN 0x1000`) |
| slfix `7e280d82` P0–P2 | **PASS @431** printed 0 |
| slfix `7e280d82` P3 | **PASS @518** printed 0. 16-byte I$ 750 + leftover jal on next 16-byte line (760/766) + far helper. TRACE leftover `a6` never commits; sib `c.jalr` returns |

P3 matches OpenSBI 752 `bnez` skip of leftover 766 on the **next** 16-byte I$ line. P4 puts leftover jal at +14 of the same 16-byte I$ as `c.bnez`@00 (skip_arm is first 8B only). Both PASS — taken skip flushes leftover before sib 01. Off-line leftover-PC replay block **kept** (hold+nat cookie t=83968). hangj 766 @20443 is leftover jal **bp_valid**, not IQ replay. skip-range latch HOLD-FAIL. Not G1gn. Not G1mg. Lottery + FDT stay regression. Isolated P4 stays.

### G1m — STQ load interlock only for a live load

`load_paddr_valid` was tied to 1, so idle/store vaddrs were advertised
to STQ (false `[11:0]` match, sticky, and forward). P4 `c.lw` of
`fdt+0x28` then sat ~200k cy and retired `a5=0x010dfeec`. G1l showed
the beat hits a live ldbuf slot.

| | |
|--|--|
| **Hits** | Mini P4 200649 cy / garbage tag; false STQ stall/forward |
| **Not** | G1l free-rid. Not G1k address IRO. Not G0/G1i. Not STQ-nofwd. |
| **Rule** | `load_paddr_valid = valid_i`. `page_offset_matches` only if that
  valid. Forward already required it. |
| **Site** | `load_unit` + `store_buffer` address checker. All configs. |

### G1l — Ghost D$ `rvalid` must not retire a load

P4 `c.lw` address is `fdt+0x28`; DRAM word is 1; retired `a5=0x010dfeec`
after a fixed ~200k cy. G1k (address forward) did not move it. `rvalid`
output ignored `ldbuf_valid` — a leftover beat with a free `rid` still
raised `valid_o` / `ldbuf_r` with stale tid and rdata.

| | |
|--|--|
| **Hits** | Mini P4 garbage tag; any leftover D$ rid after the slot retired |
| **Not** | G1k address-forward. Not G0/G1i. Not STQ-nofwd. |
| **Rule** | `data_rvalid` retires/pops only if `ldbuf_valid[rid]`. |
| **Site** | `load_unit` `rvalid_output`. All configs (8-entry ldbuf, no
  fall-through). One extra AND. No new flop. |

### G1k — LOAD: cached RF pointer beats non-cached forward

P4: `c.lw` of `fdt+0x28` (a0 check passed) retired `a5=0x010dfeec`.
DRAM `[1070]=1`. Same dual-consumer as G1h: compare saw RF `a0`,
LSU can still take a leftover non-DRAM forward.

| | |
|--|--|
| **Hits** | Mini P4 `a5=0x010dfeec`; PEEL `c.lw@129f8` if address-forward is 9 |
| **Not** | G0 stall of small-nz address-use (HOLD-FAIL). Not G1i. Not I4by
  (that is ALU `c.add a0,a1` page-0 only). |
| **Rule** | SMT+SS LOAD: if RF `rs1` is inside a cached region and the
  forwarded `rs1` is not, use RF. |
| **Site** | `issue_read_operands` next to I4by. |

### G1j — I4ao 8-byte-aligned s0 may commit

Mini **`0x39`**: after `c.mv s0,a0`, `s0!=a0` and `s0` is not `_start`.
I4ao drops `we_gpr` to x8 when `result[3:0]!=0` (16B fp). Mini fdt is
`0x80001048` (`[3:0]=8`), so the ABI save of the fdt arg never commits.
`"/cpus"+1` is still byte-unaligned (`[2:0]!=0`).

| | |
|--|--|
| **Hits** | Mini P3 `0x39`; PEEL if `mv s0,a0` of an 8B-aligned fdt is dropped |
| **Not** | G1i stall. Not G0. Not widening I4ao. Not W1/G6. |
| **Rule** | Suppress s0 write only if `result[2:0]!=0`. |
| **Site** | `commit_stage.sv` I4ao compare. SMT+SS. SI unchanged. |

### G1i — Stall `c.mv s*,a0` while a0 is in-flight (**HOLD-FAIL 2026-08-15 — reverted**)

Mini still `0x32` @522 cy (stall did not fire). Hold: no cookie,
`mepc1=0x8000075a` mcause=4, BANR, `plat_hc=2`. Cancelled a0-write
leaves `unresolved_a0` stuck — in-order issue then starves every
later `c.mv s0,a0`. I4af family. **Do not re-land.**

### G6 — No quantum/starve switch inside an ABI call nest (**HOLD-FAIL 2026-08-15 — reverted**)

Mini still 19 @526 cy (same as G1b — nest did not fire or is not this
miss). Hold: no cookie, BANR, `mepc=0xa9c8` mcause=2. OpenSBI lives
inside `jal` frames; suppressing quantum for the nest is I4y/W1-coarse.
**Do not re-land.** Next class is not another no-switch.

### G5 — Topology honesty (not an RTL class)

Stock DTB, `plat_hc==2` without soft getprop, both harts HSM-visible, Linux
`/proc/cpuinfo` count == `NrCores×NrHarts`. This is SL-C. Blocked on G0–G2
peel, not another scoreboard compare.

---

## 3. Stages to completion

### Stage 0 — One mini (do this next)

`verif/tests/custom/multicore/mini_fdt_a0_is_fdt.S` — **landed**. Single test,
ten phases, distinct fail-codes. Run on current `work-ver-smt2-slfix`
**before** any new RTL. In `soft-ladder-di` default list.

| Phase | Intent | Fail |
|------:|--------|------|
| P0 | Blob magic / `off_dt_struct` header | `0x10` |
| P1 | `a0` at `offset_ptr`-shaped entry is **fdt base** (high bits), not 0/9 | `0x11` |
| P2 | 4×`lbu` header from that `a0` | `0x12` |
| P3 | Success path `c.addiw` / shift / `c.add a1,a5` / `c.add a0,a1` → `a0==fdt+offset` | `0x13` |
| P4 | Then `c.lw 0(a0)` does **not** fault; value is the tag/prop word | `0x14` |
| P5 | NULL path `c.li a0,0` stays 0 (do not invent a pointer) | `0x15` |
| P6 | After a committed small `a0` (9), a later address-use must not fire until rewrite | `0x16` |
| P7 | After `strlen`-like 9 in `a0`, caller must pass **fdt** into getprop-shaped jal, not 9 | `0x17` |
| P8 | Callee-saved s1/s2/s4/s5 survive a nest (`check_node`/`next_tag` shape) | `0x18` |
| P9 | `next_tag(0)` returns BEGIN_NODE (`c.lw` inside callee) | `0x19` |
| P9b | `offset_ptr(fdt, 9)` returns `fdt+off_dt_struct+9` (lbu only) | `0x1a` |
| P9c | `offset_ptr` returned page-0 non-zero (software catch before `c.lw`) | `0x1b` |
| P9d | `next_tag` entry `a0` is not a pointer (high bits 0) | `0x1c` |
| P10 | PEEL: `strlen` 9, `c.mv a0,s2`, `next_tag_peel` (`c.lw`, no high-bit skip) | `0x1d` |
| P11 | Two clean `next_tag_peel(fdt,0)` **before** the a0=9 window | `0x21` |
| P9e | After P10: `s2` still fdt / `mv a0,s2` took / peel returned 9 | `0x1f` / `0x20` / `0x1e` |

tohost=1 pass. Existing FDT minis stay in `soft-ladder-di` (do not weaken them).

**Read of the fail table:** P6/P7 fail ⇒ land **G0**. P8 fail ⇒ **G1**. P1–P5
green and P9 fail on slfix but Spike-green ⇒ the missing piece is SMT switch
during the walk (still G0/G1, not a new `c.mv`). All green on slfix ⇒ the PEEL
pin is stack-size/context; grow the mini until it fails, **then** RTL.

**Lab (2026-08-15, G1 then G1b slfix):** Spike **PASS**. slfix **FAIL
tohost=19** @526 cy. P11 / P9e `0x1f`/`0x20`/`0x1e` did **not** fire
(s2 live, `mv a0,s2` took, peel did not return 9). W1 leftover-no-switch
**HOLD-FAIL**. G6 call-nest no-quantum **HOLD-FAIL** `@a9c8` — do not
re-land either. G1b (`c.mv a0,s*`) hold+nat green, peel unchanged — keep.
Same 526 cy across G1/G1b/G6: mini miss is likely SS, not a quantum-switch.
Grown mini (high-bit check before `c.lw`): still **19** @531 cy — trap
*inside* `offset_ptr_raw`/`load_be32`, not 0x1b/0x22. G1c (`c.mv s*,a0`)
hold+nat green, peel unchanged, mini still 19 — keep. G1 copy class is
complete. **Mini tohost=19 is P3 `0x13`**. Split: not NULL / `0x28` /
`0x50` / `fdt` / page-0 — a third high-bit pointer. G1g (ALU `rd==a0`)
hold+nat green, P3 unchanged. Leftover dump `1535148160` = `0x5b808080`
⇒ `a0=0xB7010100`. Inner split **`0x32`**; `s0=0x80000000`. **G1h**
drops execute-region-base forward on `c.mv a0↔s*`. Soaked hold+nat
green. Mini `0x39` was I4ao dropping 8B-aligned fdt in s0 — **G1j**
narrowed that to byte-unaligned; P3 is green on slfix. P4 `c.lw`
of `fdt+0x28` retires `a5=0x010dfeec` (DRAM word is 1). G1k (LOAD
cached-RF vs non-cached forward) hold+nat green; P4 unchanged — the
miss is LSU data, not address forward. G1l (ghost rvalid) hold+nat
green; P4 unchanged — the beat hits a live ldbuf slot. G1m (live-load
STQ interlock) hold+nat green; P4 still 200649 cy — not a false STQ stall.
G1n (`DcacheIdWidth=3`) hold+nat green; P4 unchanged — hang-7 rid
width is not this write. Isolated P4 (no 2nd `offset_ptr`;
`c.lw` of `s2+0x28` direct) is **green @1161** on G1n — the 200k
leftover was the 2nd `offset_ptr`, not the `0x70` line. Do **not**
land a D$ fill class. P5 green. P6 PEEL window (`c.li a0,9`;
`c.mv a0,s2`; `jal offset_ptr`): two leaf restore+`load_be32` green;
entry `a0` has high bits (not `0x63`); **`0x65`** = `ld ra,8(sp)`
is P5's return `0x14c`. `0x68` passed (slot==RF). **G1o** stall of `sd ra` while jal is
still issued: hold+nat green; mini still `0x65`. **G1p** hold EX PC:
hold+nat green; mini still `0x65` @956 — not a zeroed PC. Keep both.
**G1q** I4as skip CTRL_FLOW: hold+nat green; mini still `0x65`.
Keep. **G1r** per-instr CF PC: hold+nat green; mini still `0x65`
@1008 — not a shared-PC write. Keep. **G1s** cancelled link-jal
still retires `ra`: hold+nat green; mini still `0x65` — not a
cancelled commit. Keep. **G1t** link-jal alloc despite
`flush_unissued`: hold+nat green; mini still `0x65`. Keep.
**G1u** flu pairs with the branch port: hold+nat green; mini
still `0x65`. Keep. **G1v** issue-time jal link: hold+nat
green; mini still `0x65`. Keep. **G1w** flu does not replace
alloc-time link: hold+nat green; mini still `0x65`. Keep.
**G1x** link-jal valid at alloc: hold+nat cookie green; mini
still `0x65`. Keep. **G1y** keep fetch line until Jump consumed:
hold+nat green; mini still `0x65`. Keep. **G1z** IQ/decode keep
Jump through `flush_if`: mini still `0x65`; hold green; **nat/peel
`51b1c001` / `sp1=0` — reverted.** Next is **G1aa** (NPC stays
until leftover Jump is consumed). **G1aa** leftover-JAL NPC/keep:
mini **P3 `0x2f` @590 — reverted.** Next is **G1ab** (NPC hold
only for presented `cf==Jump`). **G1ab** NPC hold: mini **P3
`0x38` @545 — reverted.** NPC-delay family closed. Next is
**G1ac** (consumed Jump still reaches ID; no NPC delay).
**G1ac** IQ park on `bp_valid`: mini still `0x65`; **hold no
cookie `[1000]=80008cb6` — reverted.** Frontend Jump-keep
family closed. **G1ad** aligned P6 jal: mini still `0x65` @1021.
Batch TRACE: jal write after `sd ra`. **G1ae** G1o also
`sbe.valid`: mini still `0x65` @1021 (same cy); hold cookie
t=202752. Keep. **G1af** spec STQ no-forward: mini still `0x65`;
**hold `51b1c001` @6e6 — reverted.** **G1ag** older-ID
link-jal stalls `sd ra`: mini still `0x65` @1021; hold
cookie t=202752. Keep. **G1ah** `fwd_keep`: mini still `0x65` @1021; hold
cookie t=202752. Keep. **G1ai** STORE ra waits `addi sp`: mini still `0x65`
@1021; hold cookie t=202752. Keep. **G1aj** LOAD ra waits any STORE ra: mini still
`0x65`; **hold `51b1c001` @6e6 — reverted.** **G1ak** older
STORE only: mini still `0x65` @1021; **hold `51b1c001` @6e6 —
reverted.** LOAD-ra-waits-STORE-ra family closed. **G1al** older
ID `addi sp` stalls `sd ra`: mini still `0x65` @1021; hold cookie
t=202752. Keep. **G1am** mini 2nd load of `8(sp)`: **`0x69`
@953** (`t1=0x2c8`, `t3` stuck `0xed`). Keep the check. Next
is **G1an** (cancelled-valid LOAD dest): mini still `0x69`
@953; hold cookie t=202752. Keep. **G1ao** STQ last-forward
hold: mini still `0x69` @953; hold cookie t=202752. Keep.
Next is **G1ap** (2nd same-address LOAD must reach the LSU).
**G1ap** 2-deep LSU ready: mini **400000 cy hang** tohost=0 —
reverted. **G1aq** keep line for older NoCF before Branch: mini
still `0x69` @953; hold cookie t=202752. Keep. **G1ar** poison
`li t3,-1`: still `0x69` @954; `t3` stayed `0xed` (`li` never
retired). Keep poison. **G1as** leftover-next-line-only: mini
still `0x69` @953; **hold `plat_hc=80` — reverted.** **G1at**
ALU-li alloc: mini still `0x69` @954; **hold wfi-exit `7204`/6
— reverted.** **G1au** keep leftover-complete slot0: mini still
`0x69` @954; hold cookie t=202752. Keep. **G1av** next-line
complete + keep leftover: mini still `0x69` @954; hold cookie
t=202752. Keep. **G1aw** `serving_unaligned` only on the complete
beat: mini still `0x69` @954; hold cookie t=202752. Keep. **G1ax**
leftover-RVI skip `unresolved_cf`: mini still `0x69` @953; **hold
`plat_hc=80` — reverted.** **G1ay** same-line Branch stall: mini
still `0x69` @954; hold cookie t=202752. Keep. **G1az** IQ slot0
replay: mini still `0x69` @954; hold cookie t=202752. Keep. **G1ba** leftover
mash `c.li` recover: mini still `0x69` @952; hold cookie t=202752.
Keep. **G1bb** I$ data hold: mini still `0x69` @949; **hold
`plat_hc=80` — reverted.** **G1bc** empty-head skip: mini still
`0x69` @952; hold cookie t=202752. Keep. **G1bd** leftover-target replay: mini still `0x69` @953;
**hold mepc `0x7b0`/4 no cookie @6e6 — reverted.** **G1be** ID
insert: mini still `0x69` @952; hold cookie t=202752. Keep.
**G1bf** leftover-pending slot0: mini still `0x69` @952; hold
cookie t=202752. Keep. **G1bg** keep_prefix: mini still `0x69`
@952; hold cookie t=202752. `c.li` never issued. Keep. **G1bh**
through-`unresolved_cf`: mini still `0x69` @952; hold cookie
t=202752. Never at issue. Keep. **G1bi** IQ hold-Branch: mini
still `0x69` @952; **hold wfi-exit `51b1c001` — reverted.**
**G1bj** slot0 CF class: mini still `0x69` @952; hold cookie
t=202752. Mash never presented. Keep. **G1bk** address-overflow
push: mini still `0x69` @952; **hold no cookie-exit — reverted.**
**G1bl** different-line I$ hold: mini still `0x69` @952; hold
cookie t=202752. Keep. **G1bm** consume-slot0: mini still `0x69`
@952; hold cookie t=202752. Keep. **G1bn** dest-FIFO keep: **mini
P3 `0x2a` @588 — reverted.** **G1bo** widen slot0: **mini P1
`0x10` @384 — reverted.** **G1bp** any-slot prefix hold: mini
still `0x69` @952; hold cookie t=202752. Did not fire (`0x4d0`
never registered). Keep. **G1bq** leftover `!kill_s2`: mini
still `0x69` @960; **hold no cookie-exit — reverted.** **G1br**
later-slot `!is_branch`: mini still `0x69` @952; **hold
non-converge rc=255 — reverted.** **G1bs** later-slot
`!is_branch` from valid dest: mini still `0x69` @952; **hold
no cookie-exit — reverted.** **G1bt** leftover next-line
`!kill_s2`: mini still `0x69` @952; **hold no cookie-exit —
reverted.** **G1bu** leftover-Branch I$ barrier: mini still
`0x69` @952; **hold no cookie-exit — reverted.** **G1bv**
target-return stash: mini still `0x69` @952; hold cookie
t=202752. Did not fire (`0x4d0` never returned). Keep. **G1bw**
s2==target `!kill_s2`: mini still `0x69` @952; **hold no
cookie-exit — reverted.** **G1bx** leftover `!bp_valid`: mini
still `0x69` @952; hold cookie t=98304. Did not fire. Keep.
**G1by** later-slot `!bp_valid`: mini still `0x69` @952;
**hold wfi-exit `plat_hc=80` — reverted.** **G1bz**
leftover later-slot `!bp_valid`: **MINI-FAIL P3 `0x39`
@437 — reverted.** **G1ca** dest-before-Branch prefix: mini
still `0x69` @952; hold cookie t=98304. Keep. **G1cb**
leftover later-slot Jump not keep: mini still `0x69`
@952; hold cookie t=98304. Keep. **G1cc** leftover-Branch
target NPC hold: mini still `0x69` @952; hold cookie
t=98304. Keep. **G1cd** arm-beat NPC hold: mini still
`0x69` @952; **hold no cookie-exit — reverted.** **G1ce**
leftover-complete +8 stall: mini still `0x69` @963;
**hold no cookie-exit — reverted.** **G1cf** leftover-next
I$ vaddr: **MINI-FAIL P1 `0x10` @406 — reverted.** **G1cg**
leftover `idx_is` restart: **MINI-FAIL P1 `0x10` @384 —
reverted.** **G1ch** leftover-Branch `idx_is` restart:
mini still `0x69` @952; **hold no cookie-exit — reverted.**
**G1ci** leftover later-slot Jump !bp_valid while slot0
unconsumed: mini still `0x69` @952; hold cookie t=98304.
TRACE still `0x4d0`→`0x4e0`. Keep. **G1cj** leftover
sequential-next stash: mini still `0x69` @952; **hold
wfi-exit `plat_hc=80` — reverted.** **G1ck** leftover-NoCF
sequential-next +8 hold: mini still `0x69` @964; **hold
no cookie-exit — reverted.** **G1cl** leftover-Branch
later slots hidden: **MINI-FAIL P1 `0x11` @442 —
reverted.** **G1cm** leftover later-slot Jump hide:
mini still `0x69` @949; hold cookie t=83968. Keep.
**G1cn** leftover-NoCF I$ req suppress: **MINI-FAIL P1
`0x10` @386 — reverted.** **G1co** leftover NT beq as
Branch: mini still `0x69` @940; **hold no cookie-exit —
reverted.** **G1cp** aligned dest hold: mini still `0x69`
@949; hold cookie t=83968. Keep. **G1cq** leftover
NoCF !replay-kill s1: mini still `0x69` @949; hold
cookie t=79872. Did not fire. Keep. **G1cr**
mispredict same-line I$ keep: mini still `0x69`
@949; hold cookie t=79872. Did not fire. Keep.
**G1cs** mispredict-target +8 hold: mini still
`0x69` @970 (fired; +21 cy); hold cookie t=75776.
Keep. **G1ct** dest-only first beat: **P6 `0x69`
closed.** Mini **P8 `0x18`** @2446. Hold cookie
t=96256. Keep. **G1cu** leftover Jump G1cc:
**MINI-FAIL** P8 `0x18` @200727 — reverted. **G1cv**
leftover Jump I$ hold: mini still `0x18` @2446; hold
cookie t=96256. Keep. **G1cw** leftover jal `cf=Jump`:
mini still `0x18` @2446; hold cookie t=96256. Keep.
**G1cx** leftover Jump G1az: mini still `0x18` @2446;
hold cookie t=96256. Keep. **G1cy** leftover Jump ID
insert: mini still `0x18` @2446; hold cookie t=96256.
Keep. **G1cz** leftover Jump slot0-only IQ: mini still
`0x18` @2446; hold cookie t=96256. Keep. **G1da**
leftover Jump `idx_is` first push: mini still `0x18`
@2454 (fired; +8 cy); hold cookie t=96256. Keep.
**G1db** leftover Jump !+8 this beat: **HOLD-FAIL** no
cookie-exit — reverted. **G1dc** leftover Jump IQ
head: mini **PASS @2692** (P8 closed); hold cookie
t=22528. Keep. **G1dd** PEEL cookie-exit t=22528
(`129f8` gone). Soft getprop stays. **G1de** `COOKIE_EXIT=0`
+ COLD_EXCL diagnose. **G1df** COLD_EXCL lifts on
hart0 WFI (fired). **G1dg** DRAM+grace COLD_EXCL lift:
**MINI-FAIL** leftover a0 FDT-magic — reverted. **G1dh**
nat cookie + `COOKIE=0` 100k: still `plat_hc=80` hart1
`_wait_for_boot_hart` `sp=0`. **G1di** late lottery park:
`_boot_status` stays 2; cookie `act=0` `@ef98`. **G1dj**
cookie is hang-fallthrough. **G1dk** lottery `@7a2` taken. **G1dl** cold path `jal scratch_init`. **G1dn** leftover jal opcode IQ head (did not
fire). **G1do** leftover jal `cf=Jump` any slot (did not
fire). **G1dp** leftover Jump dest FIFO drain (did not
fire). **G1dq** `996` fetched then leftover `7c8`.
**G1dr** leftover link-jal-only IQ head: **MINI-FAIL
P8 `0x18` — reverted.** **G1ds** oldest leftover Jump
PC (did not fire). **G1dt** leftover Jump through
unresolved leftover Jump (did not fire). **G1du**
leftover-RVI capture vs replay (did not fire).
**G1dv** presented leftover ≠ G1dc FIFO (did not
fire). **G1dw** leftover-pending +8 hold: **HOLD-FAIL**
no cookie, illegal `@780`, hang `@2d38` — reverted.
**G1dx** C|I|U replay keep (did not fire). **G1dy**
leftover capture outranks `kill_s2`: **MINI-FAIL
printed 23 @1134 — reverted.** **G1dz** CSR mux
(hygiene). **G1ea** SB CSR stall (hygiene). **G1eb**
ID RAW: **MINI-FAIL hang — reverted.** **G1ec**
oldest-PC IQ: **MINI-FAIL P1 `0x10` — reverted.**
**G1ed** leftover-pending smash only if slot0
compressed: lottery+FDT PASS; hold+nat cookie t=22528;
TRACE still `s1=1` `ra=752` — keep (hygiene). **G1ee**
IQ CSR-before-use: lottery+FDT PASS; hold+nat cookie
t=22528; TRACE still `766`→`ef4c` — keep (hygiene).
**G1ef** presented leftover Jump drops a different
leftover Jump: lottery+FDT PASS; hold+nat cookie
t=22528; TRACE still `766` at t=20486 — keep
(hygiene). **G1eg** leftover-pending drops a foreign
leftover Jump: lottery+FDT PASS; hold+nat cookie
t=22528; TRACE still `7b8` `a0=1`→`766` — keep
(hygiene). **G1eh** same-line oldest-PC IQ:
**MINI-FAIL** lottery hang + FDT P6 `0x59` —
reverted. **G1ei** aligned fetch drops leftover
`jal x0`: lottery+FDT PASS; hold+nat cookie t=22528;
TRACE still `7b8` `a0=1`→`766` — keep (hygiene).
**G1ej** I|I atomic push: lottery+FDT PASS; hold+nat
cookie t=22528; TRACE still `7b8` `a0=1`→`766` —
keep (hygiene). **G1ek** unconsumed I|I I$ hold:
lottery+FDT PASS; hold+nat cookie t=22528; TRACE
unchanged — keep (hygiene). **G1el** mid-line I$
hold: lottery+FDT PASS; hold+nat cookie t=22528;
TRACE unchanged — keep (hygiene). **G1em** older
CSR-to-a0 before a0-Branch: lottery+FDT PASS;
hold+nat cookie t=22528; TRACE `7a2`/`7a8` then
still `7b8` `a0=1`→`766` — keep (hygiene).
**G1en** leftover jal x0 vs queued CSR-to-a0:
lottery+FDT PASS; hold+nat cookie t=22528; TRACE
unchanged — keep (hygiene). **G1eo** aligned I|I
`idx_is` restart: **MINI-FAIL** lottery hang +
FDT P2 `0x12` — reverted. **G1ep** consumed
mid-line holds non-sequential I$: lottery+FDT
PASS; hold+nat cookie t=22528; TRACE unchanged
— keep (hygiene). **G1eq** aligned I|I slot1 CSR
not hidden by G1ct/G1cz: lottery+FDT PASS;
hold+nat cookie t=22528; TRACE unchanged — keep
(hygiene). **G1er** aligned I|I slot1 CSR through
IQ `branch_mask`: lottery+FDT PASS; hold+nat
cookie t=22528; TRACE unchanged — keep
(hygiene). **G1es** aligned I|I overrides
leftover_next: **MINI-FAIL** lottery+FDT hang
@400000 — reverted. **G1et** fill missing aligned
I|I CSR slot from I$: lottery+FDT PASS; hold+nat
cookie t=22528; TRACE unchanged — keep
(hygiene). **G1eu** leftover jal x0 does not
complete onto I|I: lottery+FDT PASS; hold+nat
cookie t=22528; TRACE unchanged — keep
(hygiene). **G1ev** a0-Branch waits for older ALU
a0 writer in ID: lottery+FDT PASS; hold+nat
cookie t=22528; TRACE unchanged — keep
(hygiene). **G1ew** older ALU-to-a0 IQ head:
**MINI-FAIL** FDT P10 `0x1d` — reverted. Next
is **G1ex**.
Not
G0/W1/G6/G1i/G1z/G1aa/G1ab/G1ac/G1af/G1aj/G1ak/G1ap/G1as/G1at/G1ax/G1bb/G1bd/G1bi/G1bk/G1bn/G1bo/G1bq/G1br/G1bs/G1bt/G1bu/G1bw/G1by/G1bz/G1cd/G1ce/G1cf/G1cg/G1ch/G1cj/G1ck/G1cl/G1cn/G1co/G1cu/G1db/G1dg/G1dr/G1dw/G1dy/G1eb/G1ec/G1eh/G1eo/G1es/G1ew.

### Stage 1 — Peel R1 (`129f8`)

One G0 (or G1 if the table says so) on slfix. Hold must stay `51b1babe`+`51b1d000`.
PEEL must leave `129f8`. New pin is whatever OpenSBI does next — do not
pre-name it I4cg.

Retire nothing yet. Soft getprop stays until stage 3.

### Stage 2 — Same loop on the next OpenSBI pins

Reuse stage 0’s mini (add phases only if a new class appears):

| Residual | Historic pin | Class |
|----------|--------------|-------|
| R2 `lenp` store | `12eb2` mcause=6 mtval=`12b2a` | G1 |
| R3 printf | no BANR / real `sbi_printf` | G2 = G0 or G1 |
| R4 hart1 stack | `@2e8`/`@32e` `sp1=0` | G3 |
| R5 domain / `ec14` | `mepc=ec14` / domain cut | G4 |

One class, one soak. Hold-safe. Do not combine R2+R3 in one RTL diff.

### Stage 3 — Retire softs (SL-B done)

| Soft | Retire when |
|------|-------------|
| Soft `fdt_getprop*` (pin default) | PEEL cookie `51b1babe` + `plat_hc==2` + `coldboot_done=1` |
| BANR printf cave | Real printf or source stub; cookie still `51b1babe` |
| `mk_plat_skip` getprop sites | inventory `b1-fdt-lenp-store` → `rtl-fixed` |

Pin md5 will change when getprop is natural — **rebuild held from the new pin**,
never cold-`mk` from diag `8169b747`.

### Stage 4 — SL-C topology truth

`fdt-topology-soft-ladder.md` phase B. No new FDT cancel-exempts.

1. Stock generic OpenSBI + `ariane-smt2.dtb`
2. `hart_count==2`, both harts HSM-visible
3. R3a dual-hart payload / R3 cosim
4. R3b Linux: `/proc/cpuinfo` processor count == 2
5. cpu-map SMT siblings if sysfs exposes them

This is the gate for “two software harts are real.”

### Stage 5 — SL-D stream (orthogonal)

`g6lc64_stream8` (`N=2,T=1,I=1`). Do not merge with smt2 DI work. Same
mini→class→confirm loop if a residual appears. Recover **layer 2**
const-folds off (`NrHarts=1`). Enabling stream **I=2** is hang-6
(present-at-npc / catalog keep), not `7ba` sibling recover — see
`CONTRACT.md` §6 / Phase 4b. Do not grow `v` on `ariane-stream8.dts`
unless a `_v` package sets `RVV=1`. Stream8 already **`RVH=1`** (H-edge
3/3); smt2 is **`RVH=0`** — hypervisor on SMT is `CONTRACT.md` §6.5.

### Stage 6 — SL-T multi-thread AI

`smt2-ai-tensor-linux.md`. T4 soft pytorch is already green on `g6lc64_ai`.
T5 dual workers need stage 4 + Linux Image. Do not claim multi-CPU AI until
SL-C. Unified smt2+island package is after that, not during G0.

Optional later: SL-E DTS generator (`NrCores×NrHarts`) — required once a
third topology or N>2 stream exists (`CONTRACT.md` §8.3). All-feature + core
scale is union soak on **named envelopes**, not a mega-package.

---

## 4. Confirm contract (every class)

| Gate | Pass |
|------|------|
| Mini | tohost=1 on slfix; Spike-green first if the test is new |
| Hold | `51b1babe` @1000 and `51b1d000` @1008; `plat_hc=2`; BANR until stage 3 |
| Nat pin `bc7ed11d` | both cookies until getprop is natural |
| PEEL `7efc077a` | cookie, or a **new** mepc/mcause/mtval (log it; do not keep the class if pin identical **and** mini did not fail) |
| SI | `NrHarts==1` bit-identical (const-fold) |
| DFT / timing | no new clock/latch; issue-valid or cancel cone only; note in the increment |

Harness: `work-ver-smt2-slfix`. Force rebuild: bump `SMT_UNISS_WAIT`, delete
`Variane_testharness` + `__ALL.a` + generated `.cpp/.h/.mk/*.d`. Copy
worktree → `E:\cva6` and **hash-verify** (trees are copies).

---

## 5. Hard rails (unchanged)

- Soft getprop stays in pin until stage 3.
- Do not reopen `129f0` as IAF.
- Do not unwind I4bl.
- Do not re-land I4bv or I4ca.
- Do not re-land G1z (IQ Jump keep through `flush_if`).
- Do not re-land G1aa (leftover-JAL NPC/keep).
- Do not re-land G1ab (NPC hold for presented Jump).
- Do not re-land G1ac (IQ Jump park on `bp_valid`).
- Do not re-land G1as (leftover-next-line-only complete).
- Do not re-land G1at (ALU-li alloc on `flush_unissued`).
- Do not re-land G1ax (leftover-RVI skip `unresolved_cf`).
- Do not re-land G1bb (hold registered I$ data while `keep_line`).
- Do not re-land G1bd (leftover-RVI taken-target replay).
- Do not re-land G1bi (IQ hold Branch / rotate to older same-line dest).
- Do not re-land G1bk (push slot0 through address_overflow).
- Do not re-land G1bn (keep dest FIFO across IQ flush).
- Do not re-land G1bo (widen aligned compressed slot0 / skip leftover complete).
- Do not re-land G1bq (leftover-complete `!kill_s2`).
- Do not re-land G1br (`consumed` in the `is_branch` cone).
- Do not re-land G1bs (later-slot `!is_branch` from any valid dest).
- Do not re-land G1bt (leftover taken Branch to next 8B `!kill_s2`).
- Do not re-land G1bu (leftover-Branch I$ target barrier).
- Do not re-land G1bw (s2==target `!kill_s2`).
- Do not re-land G1by (later-slot `!bp_valid` while dest valid).
- Do not re-land G1bz (leftover-complete later-slot `!bp_valid`).
- Do not re-land G1cd (NPC hold on leftover-Branch `g1bv_arm`).
- Do not re-land G1ce (one-cycle +8 stall on leftover-complete).
- Do not re-land G1cf (leftover-next I$ vaddr override).
- Do not re-land G1cg (leftover-complete IQ `idx_is` restart).
- Do not re-land G1ch (leftover-complete Branch-only `idx_is` restart).
- Do not re-land G1cj (leftover-complete sequential-next I$ stash).
- Do not re-land G1ck (leftover-NoCF sequential-next +8 hold).
- Do not re-land G1cl (hide leftover-Branch later slots).
- Do not re-land G1cn (leftover-NoCF I$ req suppress).
- Do not re-land G1co (leftover NT beq as `cf=Branch`).
- Do not re-land G1cu (leftover-complete slot0 Jump G1cc +8 hold).
- Do not re-land G1db (leftover-complete slot0 Jump !+8 this beat).
- Do not re-land G1dg (COLD_EXCL lift after DRAM+grace).
- Do not cold-`mk` from diag `8169b747`.
- Hold cookie `51b1babe` only.
- One residual class per increment — now meaning one **G*** class.
- Negative bisect → revert.
- Existing I4* keep/flush landings that are hold-safe stay; do not grow them.

---

## 6. Definition of done

SMT2/MT software path is complete when **all** of the following hold:

1. Natural `fdt_next_tag` / getprop / printf on slfix; pin/held/peel oracles
   retired or bisect-only (`b1-fdt-lenp-store` `rtl-fixed`, `b2-soft-printf`
   retired or source).
2. `plat_hc==2` without soft getprop; both harts HSM-visible.
3. Linux on `ariane-smt2.dts`: `/proc/cpuinfo` count == 2 (SL-C).
4. `mk_plat_skip.py` has no FDT/printf production sites (B3 cookies/trapdump
   may remain sim-only).
5. SL-T T5 may start (dual pytorch workers). Stream (SL-D) stays a separate
   package.

Until then the next implementation step is **stage 0** (the mini), then at
most one class from §2.
