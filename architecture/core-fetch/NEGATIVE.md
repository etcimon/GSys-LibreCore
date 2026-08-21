# Negative results — indexed by mechanism

**Read this before changing B (`core/fetch_B/`) or proposing a fetch/redirect/squash patch.** These
classes failed on **A**. Porting one into B is a regression, not a shortcut. Frozen A is
`core/frontend`; the g1\* oracle is `smt_legacy`.

Distillation of 314 `HOLD-FAIL` / `MINI-FAIL` notes from A’s `frontend.sv` / `instr_queue.sv` /
`id_stage.sv` / `instr_realign.sv` / issue / commit / `core/smt/*.sv`. Raw text: tag **`g1-archive`**
(`c377958a8`).

**Why indexed by mechanism.** The old inline notes were indexed by increment id, and the result was
that the *same rule* was independently rediscovered and re-failed up to five times. "Do not stall or
fault on a small-non-zero address use" was learned as `I4bv`, then `I4ca`, then `G0`, then `G1i`, then
`W1` — five reverts, five soaks, one lesson. Each entry below is **one lesson**, with every id that
hit it.

Legend for symptoms: `plat_hc=80` = platform hart-count probe failed early; `51b1c001` = success cave
executed its `lui` but not its `addi` (partial cave = wrong-path or lost instruction); `no cookie` =
never reached the cave; `tohost=N` = mini failure code; `printed N @C` = mini phase N failed at cycle C.

---

## 1. Unbounded holds and stalls — **the largest failure class**

**Lesson:** *Any mechanism that suppresses forward progress must carry an explicit cycle bound.
Unbounded "wait until condition X" starves the pipeline, and firmware boot is the workload most
sensitive to it.* This class alone accounts for ~25 reverts.

| Sub-mechanism | Ids | Symptom |
|---|---|---|
| Hold NPC on same-cycle arm signal | `G1cd` | `no cookie-exit` (starved fetch) |
| Hold NPC `+W_BYTES` step on leftover-complete | `G1ce`, `G1ck`, `G1db`, `G1dw` | `no cookie-exit` past 6–10 min; `illegal @780`, `hang @2d38` |
| Sticky `+W_BYTES` starve via arm | `G1cu` | `MINI-FAIL P8 0x18 @200727` |
| Freeze registered I$ data across flush | `G1bb` | `plat_hc=80 mepc 0x12640/2` |
| Barrier on I$ target of a leftover branch | `G1bu` | `no cookie-exit` |
| Stall JALR until `rs1` is a usable address | `G1gf` | hung |
| Stall all younger issue on a frame-pointer write | `I4af` | `plat_hc=80 coldboot_done=0 mcause=4` |
| Stall address-use while a small-value rewrite is in flight | `G0` | `plat_hc=80 mepc=0x7394 mcause=6` |
| Sticky "unresolved argument register" issue gate | `G1i` | `plat_hc=80` (cancelled writer leaves the bit stuck) |
| ID-stage RAW stall against any older writer | `G1eb` | `hang @400000 tohost=0` (deadlocks SB head) |
| Suppress thread switch while realign leftover pending | `W1` | `no cookie mepc=0x80012e78 mcause=2` |
| Delay switch on I$-present ∩ ¬ID ∩ ¬IQ | `I4bd` | `51b1c001`, hart1 `mepc=350 sp=0` |
| Delay switch while IQ head valid (unconditional) | `I4bb` | `51b1c001`, `mepc=b290 mcause=2` |
| Block miss-switch after an immediate-write to a temp | `I4bh` | nat regress: no cookie after 6e6 cy, ~200k AXI errors |
| Gate NPC snapshot on stack-pointer commit | `I4bm` | `51b1c001`, `mepc=d04 mcause=4` |
| 2-deep LSU ready | `G1ap` | mini hang |

**Design consequence:** `SPEC.md` §3 bounds window holds at `SLOTS` cycles and §5.1 bounds the
exception-entry latch by an I$ round-trip with a timeout that reports a fetch error. Invariant **I23**
makes the bound mandatory.

---

## 2. Kill / flush suppression

**Lesson:** *Flush suppression must be scoped to a specific, provable in-flight object — never to a
PC-alignment class or to "all cycles where the PC looks like X". Both over-broad and over-narrow
scoping fail, and there is no stable middle setting.* Eight settings were tried; every one failed in
one direction or the other.

| Sub-mechanism | Ids | Symptom |
|---|---|---|
| Suppress `kill_s2` on leftover-complete | `G1bq`, `G1bt`, `G1bw` | `no cookie-exit` |
| Suppress `kill_s2` for leftover Jump with different-line I$ | `G1hu` | `MINI-FAIL FDT printed 24 (P8 0x18) @2479` |
| Suppress `kill_s2` at *all* window-aligned PCs | `G1jp` | `MINI-FAIL lottery 2 @420, FDT 50 @545` |
| Suppress `flush_i`→`kill_s1` at *all* window-aligned PCs | `G1jr`, `G1js` | `no cookie @600000 [1000]=8000f1d0 mcause=4` |
| Suppress flush/mispredict `kill_s1` at mid-window PCs | `G1iy` | `MINI-FAIL lottery 2 @430` |
| Sibling-window `kill_s2` sparing | `sib_lo_s2`, `leftover_hi8_s2` | `MINI-FAIL lottery 2 @420 / FDT 50 @545 / FDT 24 @201516` |
| Keep IQ/decode through `flush_if` | `G1z`, `I4az` | `51b1c001`, `sp1=0`; `npc=8cc8 spin_unlock` |
| Keep one registered I$ window across a thread switch | `I4bf` | `51b1c001`, `npc=8cae`, hart1 `sp=0` |
| No `flush_if` on thread switch at all | `I4be` | `51b1c001`, hart1 `mepc=f6d0 mcause=4 sp=0x10` |
| Gate realign flush with `~trap_hold` | `I4ac` | `plat_hc=80 mepc=0x80000098 mcause=6` (pre-trap leftover survived into bootrom) |
| Hold leftover across speculative non-next | spec leftover hold | `plat_hc=80 npc0=0x10050 mtvec=0x10040` (`spec_req` ≡ sequential; I3 keep) |

**Design consequence:** `SPEC.md` §2.2 makes `kill_i` *inert* on leftover state, so no suppression is
needed at all — a killed window simply changes nothing. §3 makes acceptance all-or-nothing so there is
no partially-consumed window to protect. This entire class evaporates rather than being re-tuned.

---

## 3. Prediction suppression

**Lesson:** *Broad `bp_valid` suppression removes load-bearing prediction and starves fetch. Narrow
suppression is fine but only ever buys performance. Never suppress **resolution**.*

| Sub-mechanism | Ids | Symptom |
|---|---|---|
| Suppress prediction for any later-slot CF while a dest is valid | `G1by` | `plat_hc=80` wfi-exit `t=217088` |
| Suppress prediction for leftover-complete later-slot CF | `G1bz` | `MINI-FAIL P3 0x39 @437` |
| Suppress prediction at leftover PC after mid-window / jalr seen | `G1go`, `G1gn` | `no cookie` ~2–6 min |
| Zero every leftover later-slot CF class | `G1bz` (variant) | `MINI-FAIL P3 0x39` |
| Treat all mid-window non-branch CF as indirect | `G1he` | `MINI-FAIL FDT hang @400000` |
| Treat leftover-PC branch as indirect | `G1ig` | `MINI-FAIL FDT hang @400000` |
| Hold NPC for a presented Jump | `G1ab` | `MINI-FAIL P3 0x38` |
| Park IQ Jump on `bp_valid` | `G1ac` | `no cookie` |
| jalr `JumpR` without a BTB target (predict 0) | B R5 try | `sp1=0` `mepc1=0x348/2` `51b1c001` |
| Drop page-0 execute region (keep bootrom `@0x10000`) | I4ag/I19 nat | HOLD-FAIL no cookie IAF `npc=0x2e8` `sp1=0` (I11: resolve still used `0x81c`) |

**Design consequence:** invariant **I19** separates hint from resolution; `SPEC.md` §6 puts all
legality filtering at priority 8 and forbids it at priority 6.

---

## 4. Instruction fabrication and rewrite scope

**Lesson:** *Rewriting the instruction handed to decode cannot be made safe by tightening its trigger
condition. Every widening yanked a live instruction; every narrowing missed the case it was written
for. The premise is wrong: the frontend must deliver the bytes that are in memory.*

| Sub-mechanism | Ids | Symptom |
|---|---|---|
| Rewrite any mid-window slot from I$ +2 | `G1gz` | `MINI-FAIL lottery 2 @411, FDT 90 @1082` |
| Rewrite any same-window mid slot as indirect | `G1if` | `no cookie @600000` |
| Capture sibling half at any PC | `G1is` | `no cookie @250000` (yanks wrong-window branch) |
| Capture sibling half from the sibling window | `G1iv` | `MINI-FAIL FDT 91 @948` |
| Capture sibling pair without I$ valid / kill gating | `G1jw`, `idle_sib16` | `no cookie @600000 [1000]=800071d8 mcause=4`; `51b1c001 @250000` |
| Capture sibling upper half unconditionally | `G1jj` | `MINI-FAIL lottery 2 @200615` |
| Sticky last sibling pair | `G1ki` | HOLD-FAIL |
| Rewrite from any aligned op (not just branch/load) | `G1je` | `MINI-FAIL FDT hang @400000` |
| Rewrite in the instruction queue rather than decode | `G1lm` | `MINI-FAIL FDT 106 @200619` |
| Any-RVI mash recovery | `G1gt` | MINI-FAIL |
| Widen leftover presentation to any aligned compressed slot0 | `G1bo` | `MINI-FAIL P1 0x10 @384` |
| Aligned pair overrides leftover completion | `G1es` | `MINI-FAIL lottery+FDT hang @400000` |
| Keep registered aligned load until sibling mid-window | `ld_until_01` | `MINI-FAIL FDT 106 @409` |
| Drop aligned op whose upper half looks like a compressed branch | `G1im` | `no cookie @250000` |

**Design consequence:** this whole class is deleted, not fixed. `SPEC.md` §2.3 property
`A_no_fabricate` makes it structurally impossible: every emitted instruction is a contiguous slice of
the fetched window or a leftover completion. RC3 in
[`../firmware-boot-principles.md`](../firmware-boot-principles.md) explains why it existed.

---

## 5. Instruction-queue ordering and rotation

**Lesson:** *Program order cannot be restored downstream by opcode-class priority rules. Every
"instruction of class X is queue head" rule either starved the issue window or reordered something
live.*

| Sub-mechanism | Ids | Symptom |
|---|---|---|
| Global oldest-PC across all queues | `G1ec` | `MINI-FAIL P1 0x10 @412` |
| Same-window oldest-PC | `G1eh` | `MINI-FAIL lottery hang @400000, FDT 89 @1043` |
| Older ALU-writes-argument as head | `G1ew` | `MINI-FAIL FDT 29 @1854` |
| Leftover link-jal only as head | `G1dr` | `MINI-FAIL P8 0x18 @2454` |
| Restart rotation index on aligned pair | `G1eo` | `MINI-FAIL lottery hang @200678, FDT 18 @434` |
| Restart rotation index on leftover-complete | `G1cg` | `MINI-FAIL P1 0x10 @384` |
| Restart rotation index on leftover-complete branch only | `G1ch` | `no cookie-exit` |
| Skip empty rotation head | `G1bc` | kept, but only masks the rotation defect |
| Hold branch to rotate to an older same-window dest | `G1bi` | `plat_hc=80` wfi-exit `t=217088`, `51b1c001` |
| Push slot0 through address-FIFO overflow | `G1bk` | `no cookie @202752` |
| Keep destination FIFOs across flush | `G1bn` | `MINI-FAIL P3 0x2a @588` |
| Hide queue entries by NPC distance | `G1fb`, `G1fc` | MINI-FAIL |
| Hide queue entries until a CSR commits | `G1fk` | `MINI-FAIL FDT hang @400000` |
| Arm mid-window wait on any slot | `G1fm` | `MINI-FAIL FDT 23 @1196` |
| Mute later-slot branch at mid-window NPC | `later_br_01` | `MINI-FAIL FDT 23 @1184` |

**Design consequence:** `SPEC.md` §4 is oldest-PC-per-hart with a *contiguity* requirement and **zero**
opcode awareness (**I6**). The rotation mechanism is removed entirely.

---

## 6. I$ address override and window stealing

**Lesson:** *Forcing the fetch address away from the architectural next-PC starves whatever the
architectural stream needed. One-shot steals sometimes survived; continuous forcing never did.*

| Sub-mechanism | Ids | Symptom |
|---|---|---|
| Override I$ address for leftover-next | `G1cf` | `MINI-FAIL P1 0x10 @406` |
| Stash sequential-next after leftover-NoCF | `G1cj` | `plat_hc=80` wfi-exit `t=217088` |
| Suppress one I$ request after leftover-NoCF | `G1cn` | `MINI-FAIL P1 0x10 @386` |
| Mute leftover-PC I$ while NPC window-aligned | `G1in` | `MINI-FAIL lottery hang @400000` |
| Keep I$ address on NPC window at mid-window PC | `G1iz` | `MINI-FAIL FDT 23 @1192` |
| Different-window predict skips the NPC window | `G1ja` | `MINI-FAIL lottery 4 @362` |
| Sequential-next skips the NPC window | `G1jd` | `MINI-FAIL FDT 57 @2652` |
| First different-window I$ at mid-window NPC | `G1jh` | `MINI-FAIL FDT 23 @1205` |
| Fetch the sibling window while NPC is on the first half | `sib8_fetch` | `MINI-FAIL FDT hang @400000` |
| Any-different-window hold at window-aligned NPC | `hi8_npc_fetch`, `hi8_lo11` | `MINI-FAIL lottery 4 @362, FDT 57 @445` |
| Leftover-shaped fetch vs window-aligned NPC | `lo11_npc00`, `lo_pc_npc00` | `MINI-FAIL sib P0 1 @407, FDT 0x10 @423`; `plat_hc=80 mepc 0xb0/2` |
| Hold on an aligned RVI load at window-aligned NPC | `lo_ld_stay` | `51b1c001 @250000 plat_hc=80` |
| NPC-based leftover slot0 hide | `leftover_slot0_off_npc00` | `MINI-FAIL sib 4 @448, lottery hang, FDT 17` |

**Design consequence:** `SPEC.md` §3 compares the delivered window tag against `expected_pc` and
rejects mismatches wholesale; §5 owns `expected_pc` exclusively. Nothing else may steer the fetch
address.

---

## 7. Value-based stalls, faults, and forwarding drops

**Lesson:** *Never make a control decision by inspecting a data value. Every attempt — stalling on a
small pointer, faulting a page-zero access, dropping a forward whose value looks wrong — either broke
boot or masked the defect while corrupting something else.*

| Sub-mechanism | Ids | Symptom |
|---|---|---|
| Fault data accesses to page zero | `I4bv` | `plat_hc=80`-class: cave `sd@2d18 mcause=6 mtval=0x80009`, hart1 illegal `@1007c` |
| Filter commit of a page-zero pointer increment | `I4ca` | `51b1c001 coldboot_done=0 mepc=0x9e50 mcause=4` |
| Stall address-use while a small-value write is in flight | `G0` | `plat_hc=80 mepc=0x7394 mcause=6 ra=FDT` |
| Drop forward of a small non-zero to a load/store base | `G0` (forward half) | as above |
| Sticky per-register "unresolved" bit | `G1i` | `plat_hc=80` |
| Disable speculative store-to-load forwarding | `G1af` | HOLD-FAIL (breaks memory ordering) |
| Stall a load of a link register behind any store of it | `G1aj`, `G1ak` | HOLD-FAIL |

**Still in tree and to be reverted** (see `firmware-boot-principles.md` §E): the `I4by` / `G1k` / `G1h`
value-inspecting forward drops, and the `I4ao` / `I4as` commit filters. They are listed here because
they belong to the same disproven class — they merely happened to move a symptom rather than break
boot.

**Design consequence:** invariants **I15** and **I17**. Forwarding is transparent or broken; there is
no third option and no value test that repairs it.

---

## 8. Speculative-recovery exemptions

**Lesson:** *An exemption list on a squash window is evidence that the window is wrong. The list grew
to fourteen clauses over ~30 increments and never moved the pin, because each clause protects
instructions that are **older** than the branch — i.e. the window itself is mis-derived.*

Attempted exemptions, all landed, none decisive: link register save/restore (`I4n`), frame-pointer
save/restore (`I4ai`), frame-pointer setup (`I4aj`), frame-relative loads (`I4aq`, `I4al`), the call
itself (`I4at`), immediate-form writes to temporaries (`I4ap`, `I4ax`, `I4ay`), argument-register
stores (`I4bn`), self-increment of an argument register (`I4bu`), register-copy pairs for four
different register numbers (`I4bw`, `I4bx`, `I4cd`, `I4cf`), argument-base loads (`I4cb`).

Also tried and reverted: allocate on `flush_unissued` (`G1at`, `plat_hc=80`-class wfi-exit
`mepc=0x7204/6 hart1 sp=0`); skip the unresolved-CF bit for leftover CF (`G1ax`, `plat_hc=80`);
commit-side wrong-waddr filter (`I4cc`, landed, pin unchanged).

**Design consequence:** RC4 in `firmware-boot-principles.md` identifies the aliasing that mis-derives
the window. Invariants **I13** (program order only) and **I14** (unaliased branch identity). The
exemption list is deleted, not extended.

---

## 9. Thread-switch drain and PC banking

**Lesson:** *Do not try to preserve in-flight front-end state across a switch, and do not rewind a
banked PC without a proven restart source. Both were attempted from six directions.*

| Sub-mechanism | Ids | Symptom |
|---|---|---|
| Prefer unissued PC over live NPC when banking | `I4av` | `51b1c001 mepc=b53a mcause=4 sp1=0` |
| Same-page rewind of the banked PC | `I4aw` | no cookie, `npc=8cc8 spin_unlock`, garbage link |
| Unaligned rewind after an immediate-write | `I4bj` | `51b1c001 npc=404 mepc=ce0 mcause=4` |
| Gate the snapshot on a stack-pointer commit | `I4bm` | `51b1c001 mepc=d04 mcause=4` |
| Keep leftover decode across the switch | `I4az` | no cookie, `npc=8cc8` |
| Drain the queue before switching (unconditional) | `I4bb` | `51b1c001 mepc=b290` |
| Delay switch on I$-present with empty decode | `I4bd` | `51b1c001` hart1 `mepc=350 sp=0` |
| No `flush_if` on switch | `I4be` | `51b1c001` hart1 `mcause=4 sp=0x10` |
| Keep one registered I$ window across switch | `I4bf` | `51b1c001 npc=8cae` |

**Kept and sound:** snapshot the outgoing hart's next-PC **only on switch** (`I4u`), never write a zero
next-PC over a valid one (`I4p`), restore below trap/eret/pc-commit priority (`I4y`).

**Design consequence:** `SPEC.md` §5 priority 5 plus per-hart L1 leftover and per-hart L3 FIFOs make
the switch a clean handoff with no in-flight state to preserve. Invariants **I4**, **I10**, **I18**,
**I22**.

---

## 10. Combinational loops

**Lesson:** *Do not gate an instruction's control-flow classification on whether the queue consumed
it. `is_branch → queue consume → gating → is_branch` is a loop.*

| Ids | Symptom |
|---|---|
| `G1br` | combinational loop through `consumed` |
| `G1bs` | `no cookie-exit` (widened to any dest, then branch) |

**Design consequence:** layering in `SPEC.md` §0 — L2/L3 may only clear `valid`; classification is
computed once in L1/`instr_scan` and never revisited.

---

## 11. Leftover-completion window

**Lesson:** *A straddling instruction may be completed **only** by the immediately following window.
Both looser and tighter rules fail.*

| Sub-mechanism | Ids | Symptom |
|---|---|---|
| Complete from any later window | `G1as` | `plat_hc=80` |
| Complete from the same window on replay | (pre-`I4ae`) | illegal instruction at the straddle PC |
| Complete `{hi, 0}` when the low half is absent | (pre-`I4ad`) | illegal instruction (`0x34300000`) |
| Drop leftover on any non-adjacent fetch | `G1as` | `plat_hc=80` |
| Later-slot suppression after a leftover branch | `G1cl` | `MINI-FAIL P1 0x11 @442` |
| Treat leftover next-window branch as a resolved class | `G1co` | `no cookie-exit` past 10 min |
| Keep leftover-NoCF from replay-killing the I$ | `G1cq` | kept for hygiene only |

**Kept and correct — now structural in `SPEC.md` §2.2:** adjacency (`I4ae` + `G1av`), RVI-prefix check
(`I4ad`), per-hart banking (`I4ab`), mid-window start handling (`G1gx`, `G1ia`), and the
compressed-then-straddling-RVI case (`I4aa`).

---

## 12. Process-level negatives

From `CONT-FULL-MAP.md` §5 and the iteration log — these are about *method*, and they are the reason
this file exists.

| Attempt | Result |
|---|---|
| Serialize dual commit of load/ALU | pin unchanged |
| Full load-writeback issue drain | illegal at low address; cookie regressed |
| Hold speculative return until store queue empty | FDT walk collapsed |
| Force single-issue to isolate | pin unchanged |
| Disable speculative store-to-load forwarding | pin unchanged |
| Steering ~200 increments by a 32-bit firmware cookie | pin unchanged for the entire span |
| Treating the firmware pin as authoritative | authoritative for 200 increments that did not move it |
| Gating fetch fixes on `NrHarts>1` for netlist identity | hid a geometry defect behind a thread parameter for ~1,600 predicates |

**Design consequence:** the process rules in `firmware-boot-principles.md` §G — search with directed
minis and instruction-stream co-simulation; the firmware soak is a regression gate only; identity comes
from parameter const-folding, not from scope gating.
