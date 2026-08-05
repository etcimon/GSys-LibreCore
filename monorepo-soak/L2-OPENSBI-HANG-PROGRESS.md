# Hang progress (OpenSBI multi-core cv64a6_server_math) — 2026-08-05

## Fixed
- Hang-1..3: interconnect/AMO (MaxTrans, L2 R-drain, hub expect_r)
- Hang-4: dual-issue PC+2 — instr_queue stores realign PC per FIFO word
- Hang-5: dual×U2 jump into FDT strings — **workaround U2 off**
- **Mini preload:** PHDR starting below DRAM (0x7ffff000) stages+copies
  DRAM overlap → mini_tohost SUCCESS @353 with `+tohost_addr=0x80001040`
- **instr_realign 64b 2'b01:** left-aligned decode for pre-shifted I$ data
  (upstream TODO). Correctness fix; did **not** clear hang-6 alone.
  Note: under RVC, `build_fetch_width(1|2)` yields **FETCH_WIDTH=32**, so the
  64b realign path is not active on current single/dual configs.

## Hang-6 (dual residual) — refined 2026-08-05
- WFI `fw_platform_init` @ 0x800074ea/ec; **a0=-4 = FDT_ERR_BADOFFSET**
- Fail WFI is **shared** by both path_offset fail sites (`/` @ 0x8000727e and
  `/cpus` @ 0x80007342 both land on 0x800074ea).
- Timeline from hang6-a0probe: **first path "/" succeeds** (reaches getprop /
  match at ~116k); second path **`/cpus`** walks structure then fails ~132.5k.
- Mid `/cpus` walk samples show structure offsets 0x64–0x6e (name-skip region)
  then brief **npc in low mem 0x830/0x850** (looks like 0x800128x0 with upper
  bits cleared — possible speculative/frontend glitch or probe artifact; mepc
  stays 0 so not a normal trap). Then BADOFFSET WFI.
- DRAM FDT always intact (`tag_root=1`, `tag_cpus=1`, path `"/cpus"`).

### Bisects that still hang-6 (dual always a0=-4 @ 0x800074ec)
| Config | Result |
|---|---|
| SpeculativeSb forced 0 | still hang-6 |
| realign 2'b01 fix alone | still hang-6 |
| dual + FETCH_WIDTH=32 | still hang-6 |
| dual + NrALUs=1 | still hang-6 |
| dual + NrCommitPorts=1 | still hang-6 |
| dual + no mem dual | still hang-6 |
| **single-issue (NrIssuePorts=1)** | **no platform fail WFI** (→ hang-7) |

**Conclusion:** residual is **general dual-issue infrastructure** (ID/RF/scoreboard/
issue pairing), not fetch width, dual-ALU, dual-commit, SpecSb, or mem dual alone.

## Hang-7 (single-issue) — refined 2026-08-05
- **Not** “past platform_init then crash.” `sbi_init` is **never** reached
  (0 PC samples @ `0x800006e4`).
- `platform.hart_count` stays **0x80** (ELF static default = 128) for the whole
  run → **`fw_platform_init` never stores the real count** (never finishes).
- Early 15–80k: healthy FDT walk (`fdt_offset_ptr` / `fdt_next_tag` /
  `fdt_get_string` / `sbi_memchr` with `a1=0` null search, FDT base 0x8001e000).
- After ~130–150k: collapses into **`sbi_memchr` with a0 walking low unmapped
  pointers** (0xa → 0x23a1…), L2 AR to those addrs → **R Response Errored** storm.
- Top PC histogram: `0x80004bfc` (memchr load loop). Platform-fail WFI count **0**.

**Unified view with hang-6:** both are FDT structure-walk failures.
- Dual: `/cpus` path_offset returns **BADOFFSET** → software WFI (hang-6).
- Single: walk **does not return** (corrupted pointer into memchr) → never
  completes `platform_init` (hang-7). Same family; dual fails earlier/harder.

## OpenSBI map (fw_payload.elf)
| Symbol | Addr |
|---|---|
| fw_platform_init | 0x80007264 |
| path fail WFI | 0x800074ea |
| fdt_offset_ptr | 0x80012858 |
| fdt_next_tag | 0x80012944 |
| fdt_path_offset | 0x800137f4 |
| fdt_get_string | 0x80012e2a |
| sbi_memchr | 0x80004be4 |
| sbi_init | 0x800006e4 |
| platform / hart_count | 0x800403e8 + 0x50 |
| fw_fdt_bin / "/cpus" | 0x8001e000 / 0x8001f6c0 |

FDT image: magic d00dfeed, totalsize 0xa8d, off_struct 0x38, cpus node @ 0x13c,
cpu@0 @ 0x178, cpu@1 @ 0x394. Host-side walk of payload.bin is clean.

## Config now (disk) — **temporary single-issue unblock**
- SuperscalarEn=0, NrIssuePorts=1, NrCommitPorts=1, U2 off
- FETCH_WIDTH=32 (RVC, 1-issue)
- Dual residual still open; re-enable dual after walk fixed
- Hang-4 stored-PC + realign 2'b01 kept for dual re-enable
- NrCores=2, HPDCACHE_WT, L2+hub (differs from historical smt2 SUCCESS:
  smt2 was NrCores=1, WT dcache, no L2 hub)

## TB probes (updated)
- Dense 20k–160k every 500 cycles
- Extra GPRs: a0–a5, s0–s1, s2, ra
- On FDT-walk PCs: DRAM tag + LE word at `off_struct+a1`
- Flags: `CTRL_LOW_PC`, `MEMCHR_LO_PTR`

## Hang-7 root cause (2026-08-05 dense probe) — **CPU byte-load corruption**

New TB (`hang7-fdtprobe.log`, 200k): extra GPRs + `ra` + DRAM tag at offset.

**Smoking gun — stuck memchr caller:**
```
pc in sbi_memchr, ra=0x80013788, s1=0x8001f6c0 ("/cpus"), s2=0x8001e000 (FDT)
a0 walks 0x26 → 0xd47… (unmapped), a2=0x80046e88 (end ptr), MEMCHR_LO_PTR×62
```

`ra=0x80013788` is the return of:
```
fdt_path_offset_namelen alias path:
  lbu a5, 0(s1)        # path[0]
  li  a1, '/' (0x2f)
  bne a5, a1, alias    # *** taken even though path is "/cpus" ***
alias:
  mv a2, s3            # namelen
  mv a0, s1
  jal sbi_memchr       # ← stuck here
```

So **`lbu` of `path[0]` at 0x8001f6c0 did not return 0x2f`** (DRAM has `2f 63 70 75 73 00`). Software takes the **alias** branch for an absolute path.

Also `a2_end ≈ 0x80046e88` with small `a0` implies **namelen/s3 was huge** → `strlen("/cpus")` likely never saw the terminating NUL (same class: byte load of `path[5]` wrong). That turns alias `memchr` into an unbounded walk into unmapped space → R Response Errored storm.

Early FDT structure offsets from DRAM golden look fine (tag@0=1, @8=3 PROP, @c=4 NOP, …). Corruption is intermittent / path-dependent in the **CPU load path** (HPDCACHE sub-word and/or L2 MC), not the DRAM image.

**Dual hang-6 fit:** `/` succeeds, `/cpus` structure walk returns BADOFFSET — same load-data class on structure words/bytes under dual-issue stress.

## Bisects (hang-7 load path) — 2026-08-05 cont.

| Config | Result |
|---|---|
| **NrLoadBufEntries=1** (serialize loads) | **still hang-7**: MEMCHR_LO×110, hart_cnt=0x80, alias ra=0x80013788 a1=0x64. Rules out multi-outstanding ldbuf ID/`address_offset` mismatch as *sole* cause. |
| **L2En=0** (hub remains) | **different hang**: stuck @ `fdt_path_offset_namelen+0x6` (sd s3) with `nost=0 wbe=0`, iqf full — store/path to DRAM deadlocks without L2. Not a clean load-data bisect. Restored L2En=1. |

## TB (event probes added)
- Every-cycle (capped ×40) `[path0]` at **npc** 0x8001370a..20: a5 vs DRAM path[0]
- Every-cycle (capped ×40) `[mentry]` at sbi_memchr entry
- **Caveat:** probes use frontend `npc_q`, so RF lags commit (see path0 burst below)

## Commit-PC probe results (`hang7-commitpc.log`) — definitive

### path[0] check for `/cpus` is **correct at commit**
```
path0c @1fcf3 cpc=1370a (lbu) a5=0x7ffffffe  (RF before LBU writeback same cycle)
path0c @1fcf4 cpc=1370e (li)  a5=0x2f a1=0x11
path0c @1fcf5 cpc=13712       a5=0x2f a1=0x2f
path0c @1fcf7 cpc=13718 (bne) a5=0x2f a1=0x2f  slash_ok=1 a1_slash=1
path0c @1fd06 cpc=1371c       → normal path (not alias)
```
**LBU→bne is fine** for this `/cpus` call. Not a load-use bypass miss on path[0].

### Smoking gun — alias memchr entered with **a0 = -4 (FDT_ERR_BADOFFSET)**
```
mentryc @21223 cpc=0x80004be4  a0=0xfffffffffffffffc  a1=0x64
                a2=0x80046e8c  ra=0x80013788  s1=0x8001f6c0  s3=0
```
Then `add a2,a2,a0` → a2=0x80046e88; cursor walks from -4 → 0 → low unmapped
→ R Response Errored storm. Matches hang-7.

So **`fdt_path_offset` alias `memchr` is invoked with pointer = BADOFFSET (-4)**,
not with `"/cpus"`. s1 still shows path string (callee-saved leftover / prior frame);
**a0 was not s1 at the `mv a0,s1` that should precede the jal** — either:
1. `c.mv a0,s1` saw wrong s1 (forwarding) while RF later shows path, or
2. CF entered 0x80013784 with a0 already -4 (skipped setup), or  
3. A second path_offset/alias entry after a prior FDT call left a0=-4.

Issue stage **does stall** on raw load deps (`stall_rs1` if `!rs1_valid`) — design
intent is correct; the -4 pointer is a **data/CF corruption after a real BADOFFSET**,
not a simple LBU→bne race on path[0].

### Bisects so far
| Config | Result |
|---|---|
| NrLoadBufEntries=1 | still hang-7 |
| L2En=0 | store deadlock (different) |
| NrCores=1 | TB hierarchy break (gen_single / genblk); deferred |

## Next (priority)
1. Commit-log of 0x80013780–88 (alias setup) just before mentryc @21223 —
   what a0/s1/s3/a1 were at `mv a0,s1` / `jal memchr`
2. Trace who produced a0=-4 (which fdt_* returned BADOFFSET) in the 5k cycles
   after path0c @1fd07
3. Fix CF/operand path that feeds -4 into memchr; dual + U2; SUCCESS soak
4. NrCores=1 after TB gen_single/genblk probes fixed

## Hang-7 CF fix (2026-08-05 cont.)

**Proved (hang7-bltz):** error-path bltz→137ec→epilogue is correct; `ret` @
`0x8001377e` (RF ra=`0x80013816`) then next commit is `0x80013784`
(alias `jal memchr`) with a0=-4 — skips `mv a2,s3` / `mv a0,s1`.

**Fixes applied:**
1. `RASDepth` 2→16 on server_math (FDT call depth overflow).
2. Frontend: RAS-miss return leaves `cf=NoCF` (do not mark Return when
   `!ras_predict.valid`) so branch_unit always mispredicts to rs1.
3. `issue_stage`: restore unresolved-CTRL_FLOW stall when
   `!SpeculativeSb` (`resolve_branch_i` was unused). Blocks post-ret
   fallthrough issue until the cycle after resolve/mispredict flush.


## Hang-7 CF proof + fix attempts (2026-08-05 cont.)

### Proved (hang7-bltz alias_setup)
Error path is **software-correct** until `ret`:
```
@2120e cpc=13760 bltz a0=-4  → taken to 137ec error path
@21216 cpc=1376e epilogue
@2121e cpc=1377e ret  ra=0x80013816 (correct)
@21221 cpc=13784 jal memchr   **SKIPPED 13780/13782 setup**
@21223 mentryc a0=-4 a1=0x64 ra=0x80013788
```
Disasm: 13780=`mv a2,s3` 13782=`mv a0,s1` 13784=`jal memchr`.
So CF left `ret` into alias block without setup → hang-7.

### Fix attempts (all rebuilt on server_math single-issue)
| Change | Result |
|---|---|
| RASDepth 2→16 | **regress** early load-misalign `lw` @0x800136aa mtval=0x8001e8fb (~20–40k), no path0c |
| Frontend: RAS-miss leave cf=NoCF | same early trap class |
| issue_stage unresolved-CF stall (!SpeculativeSb) | **regress** early instr-access-fault mepc=0x7ffa4352 |
| All three | same class of early _start_hang |

Reverted all three. Baseline hang-7 (memchr -4 after path_offset ret) restored as known.

### Next (priority)
1. Safer fix for ret@1377e→13784: force JALR mispredict when `cf==Return` **and** fetch NPC was sequential (need redirect-taken sticky), or SpeculativeSb-style younger cancel without full stall.
2. Root-cause `fdt_next_node` BADOFFSET (a0=-4 @211d4) — dual hang-6 family.
3. Do **not** raise RASDepth until ckpt/RAS restore soak-clean on mini + OpenSBI.

## Hang-7 fix attempts (session cont.) — 2026-08-05

Kept after soak (mini SUCCESS; OpenSBI still hang-7):
- **scoreboard**: younger cancel on `bmiss` even when `!SpeculativeSb`
  (commit_drop of cancelled slots; LSU cancelled_mask)
- **bp_resolve_t.ckpt_restore** field + set on real mispredicts (frontend
  currently uses plain `is_mispredict` for BP restore again)

Tried and **reverted** (regress):
| Change | Result |
|---|---|
| RASDepth 2→16 | early load-misalign @ fdt_getprop |
| RAS-miss → cf=NoCF | no change / early trap with RAS16 |
| unresolved CF issue stall | early IAF mepc=0x7ffa4352 |
| Force is_mispredict on every Return + selective ckpt_restore | early illegal @ FDT (mepc in fw_fdt_bin) |
| flush_id_o on mispredict | early illegal @ FDT (mepc=0x8001e004) |

**Inference:** ret@1377e→13784 is **not** fixed by younger-cancel alone ⇒ either
no `bmiss` (predict_target == ra at EX, both wrong 13784) or 13784 is not
in the SB younger window. Next: probe `resolved_branch` at ret PC
(predict vs operand_a/ra) and/or issue-time ra for c.jr.

## Hang-7 CF FIXED (2026-08-05) — residual is hang-6 BADOFFSET WFI

### ret_ex definitive (pre-fix)
```
@2121b ret EX: tgt=0x80013816 misp=1 bp_pred=0x0 cf=Return ra=0x80013816
@21220 jal@13784 still in EX (wrong-path survived flush)
```
RAS-miss Return (pred=0) mispredicted correctly but post-ret fallthrough
still reached EX.

### Fix that cleared hang-7 memchr storm
1. **issue_stage**: unresolved-CTRL_FLOW stall when `!SpeculativeSb` —
   no issue past CF until `resolve_branch` (not cleared by flush_unissued alone).
2. **frontend**: clear `icache_valid_q` on `flush_i | is_mispredict`.
3. **scoreboard**: younger cancel on bmiss without SpeculativeSb.

### Post-fix OpenSBI (hang7-cfstall2)
- **MEMCHR_LO = 0**, no alias jal@13784 hang
- **Platform fail WFI** @ `0x800074ec` with **a0=-4** (FDT_ERR_BADOFFSET)
- `ra=0x80007340` (`/cpus` path_offset fail site)
- `hart_cnt=0x80` still (platform_init fail path)
- mini_tohost still **SUCCESS**

**Unified residual:** same as dual hang-6 — `fdt_path_offset("/cpus")`
returns BADOFFSET after structure walk (`fdt_next_node`). CF fallthrough
is no longer masking it.

## Hang-6 residual after hang-7 CF fix (2026-08-05 cont.)

### Status
- Hang-7 memchr/RAS fallthrough remains fixed (CF stall + icache_valid clear + younger cancel).
- Residual = dual hang-6 class: platform WFI @0x800074ec a0=-4, ra=0x80007340 (/cpus path_offset fail).

### Root cause refined (not DRAM / not tag load)
- Host FDT golden: cpus @ struct+0x104, chosen @0x64; path walk should succeed.
- All `ntag_ld` match DRAM (no byte/word corruption on structure tags).
- `optr_null=0` (fdt_offset_ptr never NULL in window).
- False `fdt_ret -8` @133ec is memcmp('h'-'p') for chosen vs cpus, not BADSTRUCTURE.

### Smoking gun: jal fdt_next_tag fallthrough
`fdt_next_node(fdt, 0x64, &depth=1)` returns BADOFFSET because first `jal fdt_next_tag` at 0x80012b0a does not transfer control:

| call | jal_ex | post-jal commits |
|---|---|---|
| 1st (from parent 0) | tgt=0x80012944 misp=0 taken=1 cf=Jump | next_tag runs (~400 cy) then 12b10 a0=tag |
| 2nd (from 0x64) | **same** tgt/misp/taken/cf | **12b10 2 cy later with a0 still fdt** → BADOFFSET |

So EX resolution is *correct* both times; frontend **predict field matches** but **NPC does not follow Jump** on the second encounter of the same PC. Sequential bne@12b10 retires with a0=fdt → tag check fails → -4.

### Fixes tried
| Change | Result |
|---|---|
| EX JAL: taken + mispredict if NoCF/wrong tgt | no change (jal_ex already misp=0) |
| EX JAL: **always** is_mispredict | **regress** early IAF mepc=0x1400000000 @~_start_hang |
| Reverted always-mispredict; kept selective JAL EX | (safe defensive; does not clear residual) |

### Next (priority)
1. Frontend: why Jump predict at jal@12b0a does not re-steer NPC on 2nd visit (instr_queue/FTQ/icache_valid/realign/RVC bundle).
2. Probe NPC + bp_valid + fetch_entry.cf at the cycle jal is pushed to IQ (1st vs 2nd).
3. Do **not** always-mispredict JAL from EX (early IAF).
4. Dual + U2 after single-issue /cpus walk green.


## Frontend Jump follow-through (session cont.)

### Proved
- `jal_ex` both visits: `tgt=0x80012944 misp=0 taken=1 cf=Jump` — EX predict field is **correct**.
- 2nd visit still commits sequential `bne@0x80012b10` 2 cy after jal (`a0` still FDT) — next_tag never runs.
- Tags/DRAM golden; not a load-data bug.

### Tried
| Change | Result |
|---|---|
| Clear `icache_valid_q` on `bp_valid` (extend hang-7) | still fallthrough (fallthrough already in IQ before bp) |
| EX JAL always `is_mispredict` | early IAF mepc=0x1400000000 |
| EX JAL always misp, ckpt only if NoCF/mismatch | **same early IAF** — not just RAS thrash |
| EX JAL selective NoCF/mismatch only | safe; does not clear residual |

### Inference
Fallthrough is already queued **behind** the jal when it resolves. Because `misp=0`, controller does not `flush_unissued`. Unresolved-CF stall then releases and 12b10 issues. Root is **frontend queuing sequential after unaligned multi-fetch of jal@12b0a before/without killing IQ**, not EX predict field.

### On disk (safe)
- hang-7 CF stall + younger cancel + icache clear on flush/mispredict/**bp_valid**
- selective JAL EX (taken + misp only if NoCF/wrong tgt)
- no always-mispredict JAL

### Next
1. When pushing taken CF, drop already-queued younger fetch entries (or delay sequential fetch until CF consumed).
2. Probe IQ contents (PCs) at jal issue time 1st vs 2nd.
3. Consider `flush_unissued` on taken Jump even when `!is_mispredict` (controller) without full NPC double-redirect.


## Hang-6 residual — Jump re-steer campaign (session continue)

Goal: kill sequential fallthrough after matching taken Jump at jal@0x80012b0a
without EX always-is_mispredict (known IAF mepc=0x1400000000).

### Attempts and outcomes

| Attempt | Mechanism | Result |
|---|---|---|
| Frontend is_mispredict OR taken Jump | NPC reseed + TAGE mispredict_i | **regress** early IAF mepc=0x1400000000 (TAGE_LITE RAS restore thrash, RASDepth=2) |
| Controller flush_if on taken Jump + SB cancel younger | IQ kill + cancel target path | **regress** early illegal / load-misalign (cancel kills correct younger without reseed) |
| Frontend jump_resteer (NPC reseed, no TAGE) + flush_if | Full recovery without RAS restore | **regress** illegal mepc=0x4 (re-fetch thrash / RAS double-push with depth 2) |
| Controller flush_if only (no SB cancel, no reseed) | IQ wipe, NPC stays | **regress** early load-misalign mtval=0x59 (discards correct target stream in IQ) |
| Issue-stage selective drop of pc+2/pc+4 after matching Jump | Drain fallthrough without flush | **regress** early load-misalign mepc=0x80020330 mtval=0xbf (too aggressive / handshake side-effects) |
| instr_queue hold after taken CF push | Block sequential push until CF issued | **regress** IAF mepc=0x800000000 (fetch/RAS timing under hold) |

### Kept (still on residual baseline)

- Hang-7 CF fix: unresolved CTRL_FLOW issue stall; icache_valid clear on flush|is_mispredict|bp_valid
- Selective EX JAL mispredict (NoCF / wrong tgt only) — no always-mispredict
- Classic controller flush only on is_mispredict
- Classic SB bmiss only on is_mispredict
- Config: single-issue, RASDepth=2, U2/FTQ off, NrCores=2, L2+hub

### Residual symptom (reconfirmed after reverts)

- Platform fail WFI @ 0x800074ec a0=-4 (FDT_ERR_BADOFFSET) ra=0x80007340
- hart_cnt still 0x80; path0c/slash OK earlier in walk
- jal_ex (when probed 130k-160k): both visits tgt=0x80012944 misp=0 taken=1 cf=Jump

### Root constraints (do not violate)

1. Never feed matching taken Jump into frontend is_mispredict under TAGE_LITE (RAS restore).
2. Never reseed NPC on matching Jump without a plan for RASDepth (re-fetch call sites).
3. Never flush_if on matching Jump without NPC reseed (loses target stream in IQ).
4. Never cancel all younger on matching Jump without reseed (kills correct target path).

### Next (surgical)

1. Probe IQ PCs at jal@12b0a issue/resolve (1st vs 2nd visit): confirm fallthrough is in IQ not SB.
2. instr_queue: when pushing taken CF (cf!=NoCF), drop already-queued younger entries in the same realign window or hold sequential push until CF head is consumed — fix at source without global flush.
3. Optional: gate TB dense probes earlier (path0c window OK; jal_ex only 130k-160k — residual WFI often later).
4. Do not raise RASDepth until residual + ckpt path soak-clean.
