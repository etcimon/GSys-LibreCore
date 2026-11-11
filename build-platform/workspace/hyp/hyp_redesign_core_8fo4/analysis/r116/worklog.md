# r116 — Fork PGO toolchain, simulation PGO and the relaunched Linux witness

## 1. State found on 2026-11-09

- The remote testharness had been wiped and partly reprovisioned by the
  r115 session (`analysis/r115/worklog.md` §6). The r114 witness
  (PID 2644580) and every hyp8 run directory, model and the frozen
  `hyp8-firmware-mc2e` firmware were gone. r114's last recorded state is
  RVFI cycle 154377924 at `Memory: 235848K/262144K available`; its final
  outcome is unknown and will not be recovered.
- No fork prefix at the current `tools/verilator` gitlink `44063db83`
  existed. The staged sources were at local commits of older trees.
- Two orphaned verilations were still running: a `--lint-only` MC run
  (`hyp8-integration-r115-lint`, 8 h 20 min, 13.7 GB RSS) and the
  instrumented MC PGO training of the splitvar prefix (7 h 32 min). Both
  are the known pathological MC grind (r115 recorded 3 h 16 min for the
  same class). Both were stopped; neither had produced output.
- The working tree carries the r115 FO4 batch, still unqualified at the
  time: `store_unit` (fused store data), `g6lc_decode_s3` (fence
  override), `load_unit` (`ex_pub` split), `wt_dcache_wbuffer`
  (coalesce mask), `csr_regfile` (`dpc_d` coalesce), `g6lc_loop_buffer`
  (always_comb split).

## 2. Toolchain of record for r116

| Item | Identity |
|---|---|
| Fork source | `tools/verilator` `44063db83`, staged from `git archive`; staged content tree `8c5a5452…` equals the gitlink tree |
| Compiler PGO | `install-verilator-g6lc.sh VLT_PGO=1`, training = 4-thread, split-loops, `--unroll-count 256 --unroll-stmts 131072` verilate-only build of `g6lc64_hyp8` (155 s, normal exit, 132 `.gcda`), pass 2 `-O3 -march=native -fprofile-use` |
| Prefix | `/opt/testharness/toolchains/verilator-v5.008-g6lc-44063db8-pgo` |
| `verilator_bin` | `d219b63fc4f8fcba45deef3c6a1672c526f66ec11873da941bc2194cd84dd24e` (same binary in `runtime/bin`) |
| Runtime header | `runtime/include/verilated_funcs.h` `e900ec451629715860e4faffdce5127f5f118ddcaa433125b79f12d3cbb718f8` |

The MC target is no longer the training default: under the instrumented
binary it never finished. gcov writes profiles only on normal exit, so the
installer now bounds training with `VLT_PGO_TRAIN_TIMEOUT` and aborts if no
profile is produced.

## 3. Simulation PGO in the hyp8 harness

`hyp8-build-harness.sh` compiled the generated C++ at verilated.mk's
default `-Os`, without a profile. It now follows the soft-ladder recipe of
record (`-O2`, slow classes `-O1`, `-march=x86-64-v3` on AVX2/BMI2 hosts)
plus simulation PGO: instrumented build, training runs, then a
`-fprofile-use` rebuild of the same generated sources. The training input
for r116 is the boot firmware itself, 2M cycles (OpenSBI early boot).
A build that writes no profile fails rather than being labelled PGO.
`run_hyp8_integration.py` now selects the fork runtime, flavour and model
threads from env and records the executed `verilator_bin` and the applied
profile count. Commit `e0270963d`.

## 4. Firmware rebuilt from pinned inputs

`build_boot_firmware.py` ran on the frozen OpenSBI archive, recipes,
strict payload and Linux payload (`da38306f…`, restored to
`/opt/testharness/runs/linux-payload-l1s2/payload.bin`). All five DTBs were
recompiled from the repository DTS and match the pinned hashes. The
`linux-scalar` ELF is `30e1311e494000032d3db67e771c4878ea16aaabb0810a489b3da1bda2c77545`;
it differs from `ac36f379…` because the ELF debug data embeds the build
directory (191 occurrences of the run path). The loaded image
`fw_payload.bin` is `4935aa27abb23e1a0fabb4cb9ea57c40864fb3f30a2f1773dbe631615bb455f2`
and contains no path. tohost/fromhost stay at `0x80041730`/`0x80041728`.
Run: `hyp8-firmware-r116`.

## 5. Models, smokes and witness

| Run | Threads | Model SHA256 | Sim PGO profiles |
|---|---:|---|---:|
| `hyp8-r116-aggregate-t4` | 4 | `483edecbc0466b7c1ade5decde19180f9c90f39c6d40bede52847a10e0528cfa` | 227 |
| `hyp8-r116-aggregate-t1` | 1 | `480c7534d7dc3538a81f08bf35e5e556b2ba6f2db261abc6c8c99857749edd1f` | 195 |

Both include the r115 FO4 batch. Scalar/SMT2 lint: rc 0, zero `%Error`,
609/630 warnings. The earlier 602/623 totals were measured with a different
instrument, so the +7 is not attributed to RTL here. `hyp8-r116-smokes-t4`:
**12/12 pass**, cycle counts identical to the prior baselines (h34 685,
h33 1011, branch_cancel 492, csr_flush_skip 2364, amo_store_order 2199,
amo_ready_order 1231, f14 671, h35 3038, h36 9095, h37 5959, h38 883,
lrsc_store 983).

Boot witness `hyp8-osbi-scalar-r116` (t4 model, firmware above, 1B-cycle
budget, standard flags `+stall_census +hang_dump=2000 +equiv_report
+rvfi_cycle_stamp`), PID 4079233, marker observer in `output/boot-monitor`.
A duplicate `r117` on the t1 model was used for rate comparison and stopped.

| Measure | r113/r114 (pinned `-Os`, 1 thread) | r117 (PGO, 1 thread) | r116 (PGO, 4 threads) |
|---|---:|---:|---:|
| Early-boot rate | ~2.3–2.7 kcyc/s | ~9.5 kcyc/s | **~21 kcyc/s** |
| Retired at 2M / 4M cycles | 537393 / 1105424 | 537393 / 1105424 | 537393 / 1105424 |

The identical retirement census shows that the FO4 batch, threading and
PGO leave early boot behavior unchanged. At r116's rate the 1B budget is
about 13 hours, and r113's 300M-cycle point about 4 hours.

## 6. Limits

- The witness has not reached userspace yet; markers `G6LC_LINUX_INIT_UP`
  and `G6LC_LINUX_SHELL` are both required.
- The r115 FO4 batch is validated here only by lint, 12 smokes and the
  boot witness; structural FO4 is not physical timing closure.

## 7. r116 terminal failure: accepted-stream discontinuity (issue 9)

r116 passed every earlier frontier (SLUB at ~248M, mount-cache at ~286M,
both in under 4 h) and then oopsed at RVFI cycle 313455038:
`Unable to handle kernel paging request at virtual address ffffffff81313318`,
`epc == ra == ffffffff81313318`, cause 0xc, PID 1 (`swapper/0`), followed by
`Kernel panic - not syncing: Fatal exception`.

**Mechanism (RVFI, deterministic).** The function at `0xffffffff80043902`
(frame `bb60..bbb0`) calls `0x8003dfd6` (`jal` at `0x80043a90`). The callee
retired `addi sp,sp,-48` (sp `bb30`), its saves and `c.lw a5,72(s1)` at
`0x8003dfee`, and then the next retired instruction was **`0x80043a8c`** — the
caller's pre-call `mv a1,s1`, not the callee's `c.bnez` at `0x8003dff0`. No
return, branch or trap separates them. The caller re-executed the call, a
second `addi sp,-48` gave sp `bb00`, and the first frame was never popped.
Back in the caller, its epilogue ran with sp `0x30` too low: `ld ra,72(sp)`
read `bb78`, which the caller's own prologue had filled with
`sd s5,24(sp)` = `&__per_cpu_offset` (`0xffffffff81313318`), and `ret` jumped
into non-executable data.

**Frontend trace (r118diag, same model, windowed printers).** Block
`0x8003dfe8` (`mv`, `beq`, `c.lw`: no taken CF) carried a **taken next-line
guess to `0x80043a8c`**. The untagged line table aliases on the low address
bits, and block `0x800407e8`, whose `ret` really does return to
`0x80043a8c`, shares the entry. Override #1 stood down because the guess
equalled the RAS top (`ras_agree`), which it treats as a correctly learned
return, although this block contains no return. Override #2 adjudicates only
windows that contain a predicted-taken CF (`bp_fire_live && !guess_ok`). The
instruction queue therefore accepted block `0x80043a8c` as the successor of
`0x8003dfee`, with no CF in the accepted stream that could expose the jump at
execute. Fetch timeline: `npc=0x80043a8c` follows `0x8003dfd8` at cycle
307975548; an ov1 restart at 549 recovered once; the second time (557)
there was no override, and `0x80043a8c` was taken at 579 with the frontier
at `0x8003dff0`.

**Discriminator.** `hyp8-osbi-scalar-r119head` (model
`74df0a97…`, the closure with the six r115 FO4 files restored to HEAD, same
toolchain and firmware) reproduced the identical oops (same epc, ra and
register file). The defect predates the r115 batch; the batch is not
implicated.

**Correction (`fetch_B/frontend.sv`).** Queue-accepted parcels are
irrevocable, so the frontend now enforces the invariant the r113 frontier
already tracks: a live window is accepted only if one of its live slots
starts at the hart's frontier (`resume_pc_q`). A window disjoint from the
stream is refused whole, and the override-#1 record (shared, same restart pc)
squelches to the frontier; the epoch kill drops younger windows. The check
is "any live slot at the frontier", not "first slot", because the prefix
filter intentionally keeps a direct jal/call below the expected address
(`slot_keep_link`). A frontier-valid bit keeps the guard off out of reset and
after a record-less flush, until a record or the first accepted window
defines it. A sim-only assertion flags 64 consecutive refusals at one
frontier (livelock), and `+equiv_report` prints the refusal count.

Timing: one VLEN equality per slot against a register, OR-reduced beside
the existing queue valid path; the refusal joins the existing ov1 record
(no new stage, state beyond one valid bit per hart, or clock/reset). Not
ISA-visible; no DTS/config change.

**Qualification so far.** Local lint clean (7 known `sb_head` CMPCONST
warnings). `hyp8-r120-aggregate-t4` (model `014e3810…`, sim-PGO 230
profiles, includes the r115 batch): scalar/SMT2 lint rc 0, 0 `%Error`,
609/630 warnings. `hyp8-r120-smokes-t4`: 12/12 pass with identical cycle
counts, `seq_gap refusals=0` on every smoke. Boot witness
`hyp8-osbi-scalar-r120` is running.

## 8. Guard qualification: r120 false positive, r121 past the oops, new wedge

**r120 (first guard form) wedged at RVFI 499,770** (OpenSBI, IPC 0.066).
A short diag replay (`hyp8-osbi-scalar-r120cdiag`, `+seq_gap_trace`) showed a
single refusal: frontier `0x800125d0`, completing window
(`s_serving_unaligned=1`) with slot 0 at `0x800125ce`. A replay record
re-keys the frontier to the refused block address, i.e. the second half of
the straddling instruction whose first half the carry restore hands back.
Slot 0 of a completing window now also continues a frontier two bytes past
its start. The diag replay of the corrected form (`r120ddiag`) ran 22M
cycles with zero refusals and an unchanged retirement census.

**r121 (model `07a4dd5d…`, sim-PGO 228 profiles, r115 batch + guard).**
Lint 609/630 warnings, 0 `%Error`; smokes 12/12 with identical cycle counts
and zero refusals. The witness reproduced the r114 census at 2M cycles and
refused 12 windows over the run. At 311,926,541 it refused exactly the r116
failure (frontier `0x8003dff0`, window `0x80043a8c`). Linux continued past
the old oops point for the first time: secondary-CPU bring-up, clocksource,
futex hash, netlink, DMA pools, PTP, EDAC, `vgaarb`, and `clocksource:
Switched to clocksource riscv_clocksource` (UART `[3.112507]`).

**New terminal state.** Retirement stopped at RVFI cycle **441,938,308**
(`c.bnez` at `0xffffffff8063e21c`; the next record, `jal` at
`0x8063e204`, never retires). There was no `%Error` and no repeated-refusal
assertion. The census retirement and empty-cycle counters froze, and no
`[hang]` dump fired for this stall. The only `[hang]` dumps are from a
transient 4,000-cycle stall at 396.95M that recovered. The run was stopped
at ~504M cycles and committed as `6a5d55603` (frontend guard). Deterministic
replay `hyp8-osbi-scalar-r122diag` (same model, frontend, commit and refusal
traces windowed on 441,937,800–441,942,000) is running to classify it. This
is a new frontier, not a userspace result; both markers are still required.

## 9. Load-unit deadlock (r124) and misaligned-fault assertion (r125)

**Wedge at 441,938,308 classified (`hyp8-osbi-scalar-r123diag`, re-armed
`+hang_dump`, commit `6a85016b8`).** The commit head was load tid 18
(`ld t1,0(t0)` at `0xffffffff80657f58`), issued and queued in the LSU bypass
FIFO. The load unit was occupied by younger load tid 30 (vaddr
`0xffffffd801807558`): flagged speculative, DTLB miss, no translation
request, PTW idle. It ping-ponged `IDLE`<->`WAIT_SPEC_LOAD` waiting to
become non-speculative, which needs the older head load to retire first.
r71 had cleared the flag only for the commit head. Fix `c5c9262de`: after
32 cycles in that loop the load is handed back through the existing T33
replay path (pop + `lu_replay_o`, refetched at commit), mirrored in the
reference FSM. `hyp8-r124-aggregate-t4` model `b661f20d…`: 12/12 smokes,
identical cycle counts.

**r124** passed 441.9M and went on: UDP/UDP-Lite hash tables,
`NET: Registered PF_UNIX/PF_LOCAL`, `PCI: CLS 0 bytes` (UART `[4.275]`,
~474M cycles), with 12 stream-continuity refusals. It stopped at
475,300,009 on `misaligned_entry_excepts`: slot 0 (tid 9) drained by rkill
with cause 0xd (load page fault) published by the `WAIT_TRANSLATION` head
arm for the same tid. The privileged spec allows address-misaligned
exceptions to rank either above or below page/access faults, so that is
legal. Commit `7eb2f6e1c` accepts misaligned, access-fault, page-fault or
guest-page-fault causes there (sim-only check; tid and drain conditions
unchanged).

**r125** (model `ffdb9de6…`, sim-PGO 225 profiles, 12/12 smokes) is running
with a 1.5B-cycle budget and the marker observer. Userspace not yet reached.

## 10. r125 outcome and the held-PA capture (r126)

**r125** (model `ffdb9de6…`) passed the 475.3M assertion point and ran to
1,284,039,107 cycles: `Unpacking initramfs...`, `workingset`, squashfs,
jffs2, `Freeing initrd memory: 908K`, io schedulers `mq-deadline` and
`kyber`, `shpchp`, `switchtec: loaded.` (UART `[19.454]`). 12 stream
refusals and 6 hang dumps (all transient). It stopped on
`g6lc_pa_shadow_eq` (`load_unit.sv`): the live held load PA differed from
the `load_pa_now_v`-gated shadow. r48 had widened the `load_pa_q` write
enable to `valid_i && dtlb_hit_i` on the argument that the key cannot change
while its valid bit is set; the boot refutes that argument. Which input
moved was not traced. Commit `ad6a429b9` writes the register under
`load_pa_now_v` again (the shadow's own definition), giving back the r48
enable-cone timing gain until it is re-derived with this case covered.

The first observer flagged r125 as `model-error` at 363M because its check
matched the testbench's non-fatal `%Warning … Assertion failed … R Response
Errored` lines. The checker now matches `%Error` lines only; a second
observer was attached for the rest of that run.

**r126** (model `3a82cda6…`, sim-PGO 225 profiles, 12/12 smokes) is running
with a 3B-cycle budget. Userspace markers not yet reached.
