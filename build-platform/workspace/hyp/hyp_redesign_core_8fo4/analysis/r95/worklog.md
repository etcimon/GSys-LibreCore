# r95: current-source inventory and retirement-first timing continuation

## Completed

The requested philosophy/reasoning documents, the complete ALGORITHMS-EXPERTS
manual, and the identified linked methodology/contract guides are fully read.
See `reading-ledger.md`; do not restart that phase from an older task summary.

HEAD: `cea7c94edec8048d44ab04cdc1effbb1a11460ea`. The pre-existing tracked edits
to production `g6lc_apu_vnfront.sv`, `g6lc_apu_xfer.sv` and its bench are untouched.
No RTL has been edited in r95. No new boot or functional qualification exists.

`inventory.py` is new MIT tooling, not a timing-package change. It indexes
scoped Hyp sources and analysis artifacts, refreshes exact-token lexical
caller candidates, checks timing input identities, and creates one task per
over-budget module before implementation. Six lexical helper checks pass.
The first end-to-end attempt found a nullable old reference mapping; that
was corrected and the second attempt completed. No failed output was deleted.

Invocation:

```text
python build-platform/workspace/hyp/hyp_redesign_core_8fo4/analysis/r95/inventory.py --repo E:/cva6 --tag start
```

Outputs: `start-sources.json` (688 files, 624 module names, 144 changed or
added since the old index), `start-analysis-index.json` (711 artifacts),
`start-workqueue.json` (223 over-budget module tasks). This is a search/task
index, not an elaborated hierarchy or a semantic review of all indexed files.
112 of the 656 legacy indexed files changed; another 32 files were added.

All five r94 final timing manifests still match their source, analyzer,
flist and map hashes. Repeating those runs was unnecessary. The missing
whole-source core census was run using the existing r94 measurement code,
with its output globals redirected to r95, preserving archived evidence.
It analyzes the 285 module declarations found in the scalar portable flist.
`boards/baseline-core-all.{json,ir.json,manifest.json,peaks.json,log}` retain
the result. `params-core-all.json` records the r88-derived scalar binding.
Its inputs also match the snapshot used by the refreshed work queue.

Instrument: delay-v49, ir-v6, fo4-v1, package 0.1.0, parser v0.13.5;
5000 MHz, 20 ps/FO4, margin 0.2, 8-FO4 screening budget. No cost retuning,
OpenROAD execution, emitted transformation or physical timing claim.
The corpus includes disabled/uninstantiated implementations. In particular,
HPDCACHE rows are not the scalar WT clock path, nor does a list of module
maxima establish a connected whole-core path.

## Initial Strategy

The first latency-neutral OoO candidate is `g6lc_flu_reserve` (67.45 FO4
input-to-output, reported primary line 91). Its complete source and the
`ooo_lat_class`, `ooo_flu_cycles` and reservation-window functions are read.
The caller and actual IR chain still need inspection before editing.

The current algorithm classifies each lane, computes a variable offset,
then greedily updates a working reservation word in port order. A candidate
is constant-offset class masks plus parallel per-offset predecessor masks:
fixed classes only contend with earlier eligible fixed requests for the same
slot; a divider wins only if it precedes every eligible fixed/divider request
and the old window is empty. A winning divider excludes later fixed requests.
Prove this against the current greedy loop for arbitrary windows/offers before
using it. Preserve the existing ALU2 exception, tentative-offer versus final
accept distinction, actual-accept state updates and divider owner lifetime.
This does not authorize additional issue latency or changes to port steering.

The other 222 module tasks remain open. Carry forward r94 exclusions:
simulation FP reference, disconnected AR planner/cluster-set, reset/NBA
aggregation in invalidation, and sinkless private hub counters. The task queue
preserves these rows as audits, never as timing gains.

## Validation Access

The user explicitly approved use of the existing remote gateway to upload
isolated snapshots and run scoped elaboration/Verilator/OpenSBI checks.
That approval excludes installation, OpenROAD, deletion of existing artifacts
and edits to shared remote sources. No extra permission question is needed
for the approved validation scope.

`probe tools` completed: managed GCC, Spike, Icarus, Python venv, OpenSBI
artifacts and formal tools are present; managed local Verilator and OpenROAD
are missing. Nothing was installed.

Gateway preflight findings:

- Bun's default WSL launcher fails with `need GNU Make under WSL`.
- `G6LC_REGRESS_ENGINE=git-bash` reaches the shell wrapper but its hard-coded
  `python3` resolves to the Windows Store stub.
- Calling the same repository proxy with the existing contained interpreter
  initializes its SSH credentials safely, then `doctor` fails because native
  `rsync` is missing. This is not a remote RTL/toolchain verdict.
- Contained interpreter:
  `E:/cva6/build-platform/workspace/tooling/python-venv/Scripts/python.exe`.
  Proxy: `verif/regress/remote/testharness_proxy.py`.
- Proxy `shell --cmd-file` and `py --data <file>` exist. Inspect their existing
  transport implementations before using them; do not invent an installation.
  `py --data <directory>` explicitly uses rsync, while a file may use the
  existing single-file transport. Check that rather than assuming a blocker.

No remote validation job has been launched. Keep deterministic one-thread
simulation, assertions and the validated runtime. Do not run Verilator locally.

## Source/Artifact Cautions

- `software/smt2-linux/opensbi` exists but is not the source checkout. A
  `git -C ... rev-parse HEAD` there incorrectly falls back to the outer repo
  and returns cea7c94ed. Require the expected git top-level and source file,
  not just directory existence.
- The real local source is
  `build-platform/workspace/smt2-linux/opensbi/firmware/fw_base.S`.
  Its checkout identity and requested architectural loci still need review.
- `integration-inputs.json` has matched scalar/SMT2 firmware and DTB hashes,
  Linux payload hashes and userspace markers. Its smoke-source path points
  at the deleted old build workspace; inspect the current integration runner
  before treating those tests as executable.
- The current harness already has `--x-initial-edge` and banked-observer
  build flags. Do not apply a second generic reset-delivery fix from history.
- Current CSR code already has dispatch-owned credits; evaluate that contract
  against the root's different pending-request mechanism, not by copying an
  obsolete ready equation.

## Next Work

1. Finish configuration/firmware source and five carry-over mechanism audits.
2. Expand the 223-module queue into caller-qualified priority batches and
   explicit ownership/latency/configuration contracts.
3. Resolve the supported proxy invocation; capture actual scalar/SMT2/MC
   elaboration and current config maps without touching production sources.
4. Dump the actual FLU reservation dependency chain; try the exact parallel
   rewrite only after its caller review and small equivalence discriminator.
5. Execute the smallest affected remote checks and source-pinned boot witness
   where feasible; preserve all blockers, provenance and negative controls.
6. Update root `AGENTS-todo.md` and the implementation log for this code pass;
   those updates are still pending.

No commit is made. No 8-FO4, Linux, precise-retirement or physical closure claim.

## Subsequent Implementation Checkpoint

`execution-plan.md` is now authored. `planned-sources.json` adds stable
C95 per-file tasks; `planned-workqueue.json` retains the 223 H95 module
tasks, all created before RTL edits. The planned analysis index has 717
artifacts. The source/caller/configuration inventory phase is complete;
unreviewed execution paths remain explicit tasks, not qualified findings.

The real OpenSBI checkout is verified at
`build-platform/workspace/smt2-linux/opensbi`, commit
`455de672dd7c2aa1992df54dfb08dc11abbc1b1a`. Its fw_base, CSR detect,
expected-trap, sbi_init, HSM, locks, generic platform and fdt.c files all
match that commit byte-for-byte. The election/relocation, expected-trap,
release/acquire, ticket-lock, HSM/WFI and FDT paths were read at their
architectural loci. Do not use the empty software/... directory as source.

Native proxy `shell --cmd-file remote-preflight.sh` successfully reaches
the builder without rsync. It reports 12 CPUs, load about 2.2, about 113 GiB
available, 205 GB free disk, the expected private runtime hash, and the
existing modified Verilator 5.008 plus pinned GCC. Two pre-existing
Variane processes are active; do not terminate or mutate them. Source
uploads/heavy validation have still not run.

WSL Ubuntu-24.04 already has `/usr/bin/rsync`; no installation is needed.
The first direct WSL proxy command failed because Git Bash converted its
`/mnt/e/...` argument to a Windows Git path. The next invocation should set
`MSYS_NO_PATHCONV=1` and `MSYS2_ARG_CONV_EXCL=*`, using the same existing
repository proxy and its internal credential handling. Do not expose
credential values or modify the proxy just to work around that launcher.
All proxy push/pull paths, including single-file transfers, use rsync.

The FLU IR/caller review is complete for the selected admission seam:
IRO lines 1647-1740 derive pre-ack offers independently of admit, then
postprocess final accepts; exception/flush lanes reserve nothing.
The real top chain is lane_alu2 (10.1) -> lane_cyc (28.2) -> lane_div (2.6)
-> divider admit (5.8) -> div_claim (13.3) -> fixed admit (7.3), 67.45 FO4.
There is no permission to change tentative offers into final accepts in
the admission expression. The constant-mask/parallel predecessor candidate
is still NOT implemented.

### CSR Wide-Issue Repair In Progress

Source-level defect confirmed: dispatch's grp_csr_need_q/csr_need and all
credit ports are two bits, while csr_buffer has two slots. A three-CSR group
cannot pass an empty table's credit; four/eight CSR lanes truncate to zero.
The whole-group dispatch contract does not provide a partial-drain escape.
This is not claimed as the current scalar firmware stop.

Six Hyp RTL files are now changed: g6lc_ooo_pkg, csr_buffer, dispatch,
ex_stage, issue_stage and g6lc_core. New constant helpers derive table
capacity max(2, issue ports) for OoO, retaining one entry in order, and
enough credit bits including the full-capacity value. One-/two-issue
capacities and bit widths remain unchanged. Counts, registered predecode,
all connecting ports and the inline allocation oracle use the same width.
The lowest-free allocator's fixed shifts were generalized to cover the
derived table depth (the old shifts covered only four following positions).
No register enable, accepted-allocation event, commit/cancel sweep, clock,
reset, architectural side effect or production reference was changed.

`pre-csr/sources.zip` and `pre-csr/identity.json` preserve the exact six
pre-edit files and EOL conventions. Four were CRLF; pure byte-level EOL
normalization restored that convention after apply_patch. Diff sizes are
small (no whole-file churn). Plain git diff --check flags terminal CR as
trailing whitespace; rerun with the established r94
`-c core.whitespace=blank-at-eol,blank-at-eof,space-before-tab,cr-at-eol`.
Do not remove valid CRLF just to silence the default diagnostic.

The repair is NOT yet elaborated or simulated. Next: focused CSR capacity,
address/identity/release/cancel checks at 1/2/4/8 ports, default-arm old/new
comparison and a useful narrow-count negative control; then full caller
elaboration including MC. The pre-edit timing manifests are now historical
baselines, not current-source results for the changed files. Update tasks
and the append-only implementation log before finishing the pass.

### CSR Validation Checkpoint (Continuation)

The direct WSL proxy works with MSYS_NO_PATHCONV=1 and
MSYS2_ARG_CONV_EXCL=*. Doctor passed; no installation or proxy edit.

New MIT bench: `verif/tb/core/tb_g6lc_hyp8_csr_credit.sv`. Five independently
modeled cases (ports 1/2/3/4/8) cover full groups, distant free holes,
commit lookup without commit, commit+allocation, cancelled arrivals,
random holds/releases/cancels/flush and in-flight reset. Actual slot/credit
dimensions are reported but not used as the oracle. Canonical
`run_hyp8_memory.py` has an optional csr-credit route, manifest checking,
validated initial-edge flag and strict width flags for that route.
The legacy csr route now includes g6lc_ooo_pkg, its new sizing dependency.
build_closure.py's existing bench glob already includes the new bench.

First run: `hyp8-r95-csr-1d1626c609-current`, source manifest 729 files.
All five simulated cases pass (4006 cycles / 8012 checks each; port 1:
4007 / 8014). However its full-flist compile emitted WIDTHEXPAND=16 and
WIDTHTRUNC=2 that the legacy runner merely censused. Do NOT call this a
strict clean gate: two truncations and most expansions are unused vendor
axi_pkg/fpnew_pkg functions; one expansion was our bench's 12-bit literal.
The bench literal is fixed. The new leaf now compiles only its actual nine
package/module/bench dependencies (COMMON + OOO pkg + csr_buffer + bench),
with WIDTH/WIDTHEXPAND/WIDTHTRUNC fatal. No vendor source or diagnostic
suppression was added. Source capture remains the complete closure.

Second source snapshot: see `csr-snapshot-2.json`, base
`build-platform/workspace/build/hyp8-r95-csr-73e4d2d277`.
Manifest SHA a8d74f78d8d7d33db99512eeeb852b54f8a447613a3fe2d1d887edd362a36e2b.
Frozen runner SHA 5c23b1ddcbe154c587d73155c0fc78c242bfd7e3e88ff806ba6c66c15964c652.
Tag `hyp8-r95-csr-73e4d2d277-current` is RUNNING in shell `ebc0e4`.
Read its finite result, then inspect output; do not restart it. First run
shell `54f96c` has completed and its artifacts are local under remote-runs.

Next validation: baseline-small using all six pre-csr files and
G6LC_HYP8_CSR_SMALL_ONLY; narrow-width and incomplete-prefix copied-source
negative controls. None is prepared/run yet. Efficient approach: an approved
proxy py wrapper can copy this already isolated remote data/current snapshot
to its own output/closure, verify every original hash, restore the six old
files from the small pre-csr zip or apply an exact one-site mutation, update
the private manifest, and run the frozen canonical runner via runpy with
TH_DATA_DIR/TH_OUT_DIR rebound. Upload only wrapper, frozen runner, control
metadata and pre-csr zip as files, avoiding three full 729-file WSL transfers.
Never modify the current snapshot or shared remote repo. Reject compile
errors as negative-control evidence; require the specific simulation failure.

Important FLU follow-up: the recorded 67.45 chain is an ANALYZER dependency
chain, not proven sensitizable. ALU2 classification feeding a MULT divider
test contains mutually exclusive FU conditions. Qualify logical scenarios
before timing credit. Also trace actual IRO ALU2 steering: current reserve
excludes low ALUs on every nonzero port, whereas old continuation text says
ALU2 was disabled under WbReserve. Do not assume that old text is current or
change that exclusion without matching the real completion port contract.
No FLU RTL edit has occurred.

Licensing configs were rechecked; selected six RTL files resolve R and keep
existing author/upstream notices; new bench and helpers resolve MIT T. No
vendor or reference source was changed. CRLF-aware git diff --check passes.
Root implementation-log append, final licensing/checklist/impact note,
full caller elaboration, aggregate verify and source-pinned boot remain open.
