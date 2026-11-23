# SMARTr: Crash-Fault Handling On The Checkpoint Substrate

Status: architecture plan, 2026-11-23. SMARTr is a system-level process
built on the native checkpoint composition (`native-composition.md`); it is
mostly software policy plus small record-format deltas, not new checkpoint
machinery. Nothing in this document is implemented beyond the primitives it
names; each element carries its own qualification gate.

## 1. Name and scope

**SMARTr — S.M.A.R.T. Refresher** — is the crash-fault handling discipline for
systems whose main memory is a Storamic stick: monitor, refresh, snapshot on
fault, hibernate, recover, re-apply integrity. It answers four production
needs that plain checkpointing does not:

- **Fault forensics:** a coherent RAM image plus CPU state captured at the
  moment of a kernel fault, durable across the power loss that often follows.
- **Mission rollback:** a periodic "last known good" image that a reset
  restores automatically — single-event-upset tolerance without full TMR.
- **Clean hibernate:** an orderly save → power off → cold-restore cycle for
  suspend-to-RAM-image workloads.
- **Integrity refresh:** compensation patches layered onto the stick and
  verified before the system returns to normal journaling operation — with
  access controls so checkpoint data is never exposed to an unauthenticated
  second party.

Explicitly **deferred**: the second-hand debugging platform itself —
physically transferring sticks to an analysis host, a maintenance readout
port, source-correlated root-cause analysis, and auto-generated patches
(§7). The *access-control contract* that platform would consume is part of
this architecture (SR-11) and is planned now.

## 2. Elements

| Element | What it is | Status |
|---|---|---|
| SR-1 | Fault-hibernate SAVE (software-managed trigger) | Mechanism qualified; fault use is new policy |
| SR-2 | Crash-context page (CPU state inside the image) | Convention only; no RTL |
| SR-3 | Checkpoint classes + recovery selection | Needs record-format delta |
| SR-4 | Periodic refresher + cold rollback | Cold recovery exists; scheduling new |
| SR-5 | Moving-window segmented checkpoint (RAM scaling) | Needs segment manifest delta |
| SR-6 | Single-mode FAST tape streaming (no journal select) | Frame protocol is the journal; relative jumps over gaps; tradeoff lives in SR-12 knobs |
| SR-7 | N-generation checkpoint ring | Layout + scan-order change |
| SR-8 | Wear-aware checkpoint policy | Policy now; hardware accounting later |
| SR-9 | Compensation patch carrier on the stick | Contract to define; generation deferred |
| SR-10 | Clean hibernate (save → power off → cold restore) | Mechanism exists; flow to qualify |
| SR-11 | Checkpoint data access control | Level-1 plan now; confidentiality deferred |
| SR-12 | Runtime feature/policy knobs | Control-register fields; per-feature tradeoffs |
| SR-13 | Per-region tape journal — real-time journaling | Needs tape device leaf + controller journal port + replay engine |

### SR-1 Fault-hibernate SAVE

Software-managed: the kernel fault path (panic, oops, MCE-equivalent,
watchdog — a defined fault-entry contract, not every interrupt) writes the
crash context (SR-2), issues `SAVE` on the checkpoint control page, then
halts or powers off. The endpoint pauses CPU/debug/VirtIO producers, drains,
copies the window and publishes the record — all existing, qualified
machinery. New work is the fault-entry ordering contract: context write →
fence → `SAVE` → power off, and which faults qualify.

### SR-2 Crash-context page

CPU state is not in the checkpoint image (RAM only). SMARTr reserves a page
(or per-hart slots for SMT/multi-core) inside the checkpointed window where
software writes `pt_regs`, exception cause, privilege level, build ID and a
magic tag before SAVE. The image captures it automatically. No RTL change;
needs a memory-map reservation so the allocator never reuses the page, plus
a documented ABI. Verification: firmware writes a pattern to the reserved
page, SAVE, mutate, cold-restore, verify the page contents; a mutant that
excludes the page from the window must fail the oracle.

### SR-3 Checkpoint classes and recovery selection

Today two record slots alternate by generation and recovery picks the newest
*valid* image. For SMARTr that is wrong after a fault SAVE: the crash image
would become the automatic restore target, displacing the last-good
refresher image. Design:

- Record carries a **class** — `REFRESH` (periodic, rollback-eligible),
  `FAULT` (forensic) or `HIBERNATE` (SR-10) — in a spare field of the
  record word or a new word.
- Boot recovery scans for the newest valid **REFRESH** image only. `FAULT`
  and `HIBERNATE` images are restored only on an explicit platform command
  (or by the hibernate resume path, which *is* explicit).
- Alternative considered and rejected as primary: a separate fault-image
  extent the recovery scan never reads — simpler but wastes a second full
  image region and complicates capacity accounting. The class bit is cheaper.

This is the crux SMARTr item: without it, fault forensics, hibernate and
mission rollback fight over the same two slots.

### SR-4 Periodic refresher and cold rollback

A scheduled SAVE (software timer or platform agent) keeps the newest
REFRESH image fresh — the "last known good". On detected instability
(trap storm, EDAC scrub errors, watchdog) the system resets; boot recovery
restores the REFRESH image before the hart runs. **Hot RESTORE is not the
rollback path**: it replaces RAM while the core continues forward from its
commit head — memory rolls back, execution does not. Mission rollback wants
cold-boot-into-image semantics, which already exist (`g6lc_storamic_boot_
recovery`). Verification: cadence SAVE → inject fault → reset → restored
data matches the pre-fault image; a mutant that restores the FAULT class
automatically must be caught by SR-3's oracle.

### SR-5 Moving-window segmented checkpoint (scaling)

The checkpoint image is a **logical whole** built by a **moving window**:
the copy engine sweeps the RAM address space in window-sized segments
(`W` = a hardware parameter — copy-buffer/beat granularity and per-segment
timeout budget), so RAM size scales by *segment count*, not by window size.

- **Segments:** `ceil(RAM_bytes / W)` passes; each pass copies
  `[base_i, base_i+W)` through the existing `mem_*`/`st_*` seams to its
  flash segment region. `W` stays small enough for the serial copy budget;
  `RAM_bytes` is bounded only by the reserved flash extent
  (`N_segments × W × 2 banks + manifests`). The sweep is sequential over
  image extents and uses **relative jumps** (§3) over non-image holes —
  MMIO apertures, carve-outs, uncheckpointed regions — so a RAM map with
  gaps checkpoints as one continuous frame with holes skipped, not as
  many partial frames.
- **Manifest:** the record grows a segment table — per-segment
  `{base, len, crc32c}` — committed *after* all segment data, so the whole
  multi-segment image stays atomic under the same frame protocol
  (stream segments in sweep order → manifest → record → commit marker
  last, per §3).
  Recovery validates the manifest, then copies every segment back.
  Under the tape discipline (§3) segment copy order *is* append order on
  media — the sweep streams, it never seeks.
- **Atomicity choice:** v1 keeps whole-image atomicity (one manifest commit
  = one image). The follow-on, per-segment records with independent
  commit markers, enables partial/incremental images — that is the real
  path to dirty-region tracking (SR-5b) and is deliberately deferred.
- **Relation to window = partition:** the moving window replaces the
  earlier "critical partition" idea for full coverage; a *static*
  sub-window remains available as a policy choice (checkpoint only a
  defined extent) but is no longer needed for scaling.

### SR-6 Single-mode FAST tape streaming

There is **no journal-mode select** — the earlier JOURNAL/FAST dual-mode
idea is dropped. The checkpoint 'file' *is* the tape of §3, and crash
safety comes from the frame structure itself rather than from a separate,
slower journaling path:

- Segment data streams sequentially while its CRC is folded into the
  copy pass; the manifest, record body and commit marker are then placed
  at their frame positions via **relative jumps** — short forward
  repositioning inside the append stream — never backward rewrites,
  never a second pass.
- A power cut anywhere leaves either a complete committed frame or a
  torn tail that recovery truncates at the last valid marker. There is
  no torn-middle case because the head only moves forward.
- Relative jumps are also how the head crosses reserved extents,
  alignment padding, unavailable/bad regions and non-image RAM holes.
  Each frame's commit marker self-locates its position, so no jump
  table exists — recovery is a scan for valid markers wherever frames
  landed. Non-contiguous frames are normal, not exceptional.

The performance contract of FAST: no per-stage flush waits beyond the
commit boundary, CRC computed during the copy rather than as a second
pass, and the append head free to fast-forward over gaps. The
performance tradeoff therefore moves entirely into *whether and how
often* to checkpoint — SR-12's knobs (refresher on/off, cadence,
segment geometry, crash-context) — not into *how* to journal, because
there is only one way and it is already the fast one. A workload that
needs lower overhead disables or slows SMARTr; it does not get a
"less safe" write mode. A mutant that reports a torn frame as committed,
or lets a relative jump move the head backward/overwrite, must fail.
This governs the checkpoint record path only — virtio-blk durability
stays on the durable-store flush contract, unchanged.

### SR-7 N-generation checkpoint ring

Two slots give one rollback generation. Radiation/critical-mission rollback
wants depth: under the tape discipline (§3) generations are **retained
frames** in the append log — depth N means the log keeps the N newest
committed frames per class, reclaiming oldest-first by whole-region erase
when space runs out. Capacity is `N × (total_image_bytes + manifests)`
planned in the reserved extent; the record format is already generational
and the change is append-head management plus scan order in
`g6lc_storamic_checkpoint_media`. Generation exhaustion still refuses
rather than wraps — under the log it means "no reclaimable region," which
must surface as a SAVE refusal, not silent overwrite.

### SR-8 Wear-aware checkpoint policy

Every SAVE writes the full image; flash endurance is finite (real wear
leveling/FTL is P0/P1 physical scope, not this document). SMARTr policy:
adaptive SAVE interval (fault counters raise frequency, quiet periods
lower it), erase-cycle accounting hooks (`journal_gen` telemetry exists but
is not a wear map), and a budget that refuses SAVE when the projected wear
cost exceeds policy. With SR-6 single-mode, the wear levers are cadence,
retention depth (SR-7) and segment geometry (SR-12) — there is no
write-path mode to trade; true delta saves are deferred with SR-5b.

### SR-9 Compensation patch carrier

The mechanism to *receive* integrity patches on the stick, independent of
the deferred analysis platform that would *generate* them: a patch
partition in the user flash area or a dedicated reserved extent, plus a
boot-time application contract (boot firmware reads the patch block,
verifies signature/generation, applies to the kernel image inside the RAM
window or to boot config). CPU-level compensation means boot
configuration/CSR-default patches — CVA6 has no writable microcode, so
errata-class fixes remain RTL respins; the carrier can only carry what
software/firmware can apply.

### SR-10 Clean hibernate

Plain suspend-to-image: software quiesces the system, issues `SAVE` with
class `HIBERNATE`, powers off; on resume the platform issues the explicit
restore (boot recovery does not auto-select HIBERNATE images — SR-3), the
image returns and execution continues from the saved RAM state. This is
the closest SMARTr gets to classic hibernation and needs no new machinery
beyond SR-3's class bit and the explicit-restore command path. Device
state is not in the image — drivers re-probe on resume, as today.
Verification: firmware SAVE(class=HIBERNATE) → power cycle → explicit
RESTORE → data/code match; a mutant that auto-restores HIBERNATE on boot
without the command must fail.

### SR-11 Checkpoint data access control

Checkpoint images contain the whole system RAM — secrets included. The
architecture carries access controls even though the analysis platform that
would use them is deferred (§7):

- **Level 0 (exists):** `g6lc_storamic_store_guard` blocks the user port
  from the reserved flash extent; only the internal maintenance owner
  reaches records/images.
- **Level 1 (planned):** an **export policy** in checkpoint configuration —
  `NEVER` / `KEYED` / `OPEN` — gating any future readout of record or image
  data. `KEYED` requires the protected-ABI unlock key (the `+0x3020`
  mechanism and `unlock_key_i` port already exist, currently tied off) at
  the maintenance boundary. Records carry the policy under which they were
  written so a later reader knows the rules.
- **Level 2 (deferred):** image **confidentiality** — encrypt the image
  body (key derived from module identity + unlock key, or an AES engine)
  with transparent decrypt on restore; plus a keyed integrity check so a
  second-hand reader cannot forge records. Deferred to the security/
  physical qualification gates; Level 1 ships first.
- A stick moved to a second computer must not leak the previous system's
  RAM image to an unauthenticated holder — that is the property Level 1
  buys before any export path exists.

### SR-12 Runtime feature/policy knobs

SMARTr features are individually switchable at runtime for performance
workload priorities, through control-register fields. There is no
journal-mode knob — SR-6 is single-mode FAST; the tradeoff surface is
*whether and how much* to checkpoint, not *how* to write it:

| Knob | Off / degraded | On / full | Tradeoff |
|---|---|---|---|
| Checkpoint enable + refresher cadence | No periodic SAVE — lowest overhead, no rollback depth | Periodic REFRESH — rollback depth | Wear + flash bandwidth |
| Crash-context capture | Fault SAVE carries RAM only | Context page written pre-SAVE | Small fixed cost per fault |
| Class acceptance | REFRESH-only recovery | FAULT/HIBERNATE restorable on command | Attack/accident surface |
| Export policy | `NEVER` | `KEYED`/`OPEN` per SR-11 | Confidentiality vs debug access |
| Segment geometry | Fewer, larger segments — fewer manifests | More, smaller — finer partial images later | Manifest overhead vs flexibility |
| Frame retention depth | 1 generation | N generations per class (SR-7) | Reserved extent capacity |

Rules: changes are legal only while no save/restore is in flight; every
knob change is reflected in the next frame's record metadata; a knob may
narrow capability but never widen it past the qualified profile (e.g.,
class acceptance cannot make a FAULT image auto-restorable on boot —
explicit restore only). This is the workload-priority surface: a
throughput phase runs checkpoint-off or slow cadence; an assurance phase
runs frequent REFRESH + crash-context on + deep retention.

### SR-13 Per-region tape journal — real-time journaling

Periodic frames bound the loss window to the SAVE interval. Mission-
critical workloads (high-radiation, no-second-chance, tight RPO) need
**continuous** protection: a tape-mode journal device attached to each
RAM region, owned by the memory controller, streaming every journal-
eligible store to tape *before* it lands in RAM.

- **Attachment.** Each RAM region/bank gets a dedicated tape journal
  device — sequential-append-only, so its write interface is narrower
  than AXI (append-record in, status out; random-access read for replay
  and export). The controller holds one journal port per region and
  steers stores by region decode, exactly as it already routes RAM vs
  flash vs control page.
- **Journal-ahead-of-RAM (write-ahead log).** A journal-eligible store
  first appends its record — `{seq, region, addr, data, flags, crc32c}`
  — to the region's tape and commits it; only then does the RAM write
  proceed. RAM is therefore always a subset of the journal: a power cut
  anywhere loses at most the uncommitted tail, never committed data.
  This is what makes it *real-time* — there is no pause, drain or SAVE
  in the loop.
- **Epoch commits.** A store stream is not a consistent cut by itself.
  An `EPOCH` marker record (written by software at defined quiescent
  points, or by the controller at drain boundaries) bounds a recoverable
  point; recovery replays records in `seq` order up to the last valid
  epoch commit. Cross-region consistency uses per-region sequence
  spaces plus an epoch record per region — a global cut is the set of
  epoch commits sharing an epoch ID.
- **Recovery composition.** Cold boot = restore the newest committed
  base frame (SR-5/SR-6, which carries a journal watermark) → replay
  the journal tail from that watermark forward → RAM reaches the last
  committed write. Journal records older than the base frame's
  watermark are reclaimed when the frame's region is erased — the tape
  log and the frame log share the §3 append discipline and can share
  the reserved extent or use per-region extents.
- **Selectivity is mandatory.** Journaling every store costs ~4–6×
  write amplification on journaled traffic plus tape program wear.
  Journal scope is per-region and per-class through SR-12 knobs;
  mission profiles journal protected extents only (kernel, stacks,
  device-state pages, lockstep regions). The controller may coalesce
  consecutive writes to the same line into one record — an hotspot
  optimization, not a semantic change.
- **Relationship to SAVE.** The journal protects *data* continuously;
  SAVE still produces the coherent *machine* image (paused CPU/debug/
  VirtIO state) that the journal cannot capture — in-flight core state
  is not a store. Fault-hibernate and hibernate flows carry a journal
  watermark in the frame record so post-restore replay resumes at the
  right sequence. RPO for journaled data becomes ≈0; RPO for
  unjournaled RAM remains the SAVE interval.
- **Access control.** The journal stream is checkpoint data — the
  same secrets as the image. SR-11's export policy and Level-2
  confidentiality apply to journal extents identically.
- **Honest limits.** Journaled stores pay append latency (or posted
  ordering) and bandwidth; tape endurance is consumed continuously, so
  SR-8 wear policy becomes load-bearing rather than advisory; the
  replay engine and per-region arbitration need their own qualification
  lane; and none of this replaces coherent SAVE for machine-state
  snapshots.

## 3. Design principle — tape-line checkpoint writes

Checkpointing adopts a **tape discipline** for its flash data structures:
all SMARTr-managed *writes* are sequential appends at a monotonic head;
all *reads* stay random-access. One SAVE produces one **frame** —
`[seg_0 data]…[seg_{n-1} data][manifest][record][commit marker]` —
appended in order at the head; the next SAVE appends the next frame.
Nothing in the checkpoint path performs in-place updates or
read-modify-write on flash.

- **Append head with relative jumps.** A head pointer in the checkpoint
  media state (rebuilt by the commit scan at reset) marks the next free
  byte. The head advances sequentially and may make **relative jumps** —
  forward-only skips over reserved extents, alignment padding,
  unavailable/bad regions and non-image RAM holes, exactly like tape
  fast-forward. Jumps never move the head backward and never rewrite;
  each commit marker self-locates its frame, so no jump table is kept.
  Segment order follows the SR-5 moving window: the sweep order over RAM
  *is* the append order on media, so the copy engine streams rather than
  seeks — and relative jumps are the only repositioning it ever does.
- **Frame = end-of-tape label.** A frame is valid iff every section CRC
  validates and its commit marker matches the frame's generation/class.
  A power cut leaves a torn tail — an uncommitted partial frame that
  recovery truncates at the last valid marker. This makes power-cut
  safety structural rather than protocol-dependent.
- **Erase discipline.** Flash erases occur only at region boundaries and
  only for regions whose frames are all superseded; reclaim is
  whole-region erase, never selective — tape-spool reuse that distributes
  wear sequentially along the append direction.
- **Directory.** The newest committed frame per class is found by a
  bounded forward scan for valid commit markers (tape-directory
  semantics). The existing two-slot metadata pair may remain as a
  fast-boot cache of that scan, but the frame log is authoritative.
- **Reads.** Restore, recovery scan and forensic export read frames at
  recorded offsets — random-access, and reads never move the append
  head, so a reader cannot corrupt the append stream.
- **Scope.** The discipline governs the checkpoint/reserved extent and
  SMARTr-managed structures only. User virtio-blk data keeps its existing
  random-access path and durable-store flush contract; the two share
  media but not discipline.

Consequences: power-cut safety becomes structural (torn tail ≠ corrupt
data); write amplification is minimal (no RMW, erase only at boundaries);
wear levels naturally along the append direction; and SR-6/SR-7 fall out
cleanly — the single FAST mode is simply the append stream itself (there
is no weaker or stronger variant to select), and the N-generation ring
is N retained frames reclaimed oldest-first. Software rule for SMARTr
writers: **allocate sequentially, never patch in place, jump only
forward — to change a value, append a new frame.**

## 4. Profile boundary

SMARTr inherits the checkpoint qualification boundary unchanged (W0–W5 in
`completion-plan.md`): in-order cores only today, SMT2/multi-core widening
in progress, OoO/hypervisor/AI writers refused. SMARTr adds no new profile
requirement, but production fault-hibernate needs whatever profile actually
ships — an unqualified profile cannot issue a trustworthy SAVE.

## 5. Verification

Each element gets a `native-ckpt` variant stage on the remote testharness
plus mutants, matching existing discipline:

- SR-1/2: context-page pattern survives SAVE → mutate → cold restore;
  mutant excluding the page fails.
- SR-3: fault SAVE then reset must restore REFRESH, not FAULT/HIBERNATE;
  mutant ignoring class fails the oracle.
- SR-4: cadence + fault + reset rollback; timing within `TimeoutCycles`.
- SR-5: multi-segment image over RAM larger than one window restores
  byte-exact; torn segment manifest rejected; capacity math checked.
- SR-6: single-mode enforcement — torn tail truncated at last valid
  marker; relative jump forward over a gap leaves both frames valid;
  mutant reporting torn/overwritten frame as committed fails.
- SR-7: corrupt newest slot → older valid selected; exhaustion refuses.
- SR-9: patch apply/verify/reject paths; bad signature never applies.
- SR-10: hibernate save → power cycle → explicit restore round-trip.
- SR-11: export attempts without the key refused at the maintenance
  boundary; `NEVER` policy denies all readout; record carries its policy.
- SR-12: knob transitions rejected mid-save; metadata reflects the
  active policy; no journal-mode field exists to flip.
- SR-13: journaled store survives power cut → cold boot restores base
  frame + replays tail to last epoch; unjournaled store in same window
  is lost (defined); torn journal tail truncated; epoch-less replay
  policy verified; per-region seq ordering under concurrent regions;
  mutant writing RAM before journal commit fails.

## 6. Ordering

SR-3 is the record-format delta that gates everything else; SR-5's
manifest and SR-6's frame/relative-jump layout ride the same record
change (SR-6 needs no mode field — FAST is the only mode). SR-1/2/4/8/
9/10/11/12 are software/policy on existing machinery plus control-register
fields. SR-7 scales capacity; SR-13 (per-region tape journal) builds on
the SR-5/SR-6 frame layout and SR-4 recovery composition; SR-5b
(per-segment records → dirty-region tracking) follows. Suggested order:
SR-3 → SR-5 manifest + SR-6 frame layout → SR-2 → SR-1 → SR-10 → SR-4 →
SR-13 → SR-12 → SR-11 → SR-8 → SR-9 carrier → SR-7 → SR-5b. W2 profile
completion precedes any production claim; P0/P1 physical gates precede
wear/wear-leveling and confidentiality claims.

## 7. Relationship to existing machinery

Nothing here replaces the qualified composition — SMARTr is a policy and
record-format layer on top:

- Pause/drain producers, endpoint FSM, policy module, identity lock,
  journal protocol, boot recovery agent: reused unchanged.
- New RTL surface is deliberately small: record class + segment manifest
  fields and the frame/relative-jump append layout
  (`g6lc_storamic_checkpoint_media` / record codec), control-register
  policy fields, the per-region tape journal device leaf plus the
  controller journal port and replay engine (SR-13), and later the
  export gate.
- Every outside-Storamic-folder delta (control registers already live in
  `g6lc_storamic_regs`, inside the standalone tree) gets a
  `hyp8-port-ledger.md` row when it lands.

## 8. Deferred: second-hand debugging platform

Out of scope for now, recorded so the boundary is explicit: transferring
sticks to an analysis host, a maintenance readout port for the reserved
flash extent (the `store_guard` blocks the user port; no maintenance master
or chip-off flow exists), source-correlated root-cause analysis, and
auto-generated compensation patches. It needs a host-interface decision
and consumes SR-11's export policy and SR-3's class bit — revisit after
those land.
