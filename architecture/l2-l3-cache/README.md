# Extension point: L2 / L3 cache + server prefetch

**RTL:** `../../corev_apu/l2_cache/`, `../../corev_apu/l3_cache/`. Playbook:
`../../agents/guides/AGENTS-l2l3-cache.md`.

## Intent
Cache levels below L1 to cut DRAM traffic for multi-core + speculative server workloads,
without editing L1 files or weakening RVWMO.

## Hierarchy

```
cores ──► coherence hub ──► L2 ──► L3 (opt) ──► server prefetcher (opt) ──► DRAM
                                                                      │
                         island GEMM DMA (xbar master) ───────────────┘
                                      DRAM = N-channel stripe (I3)
```

DRAM channels are **not** an L2 feature. The stripe (`DramChannels`, default 64 B =
L2 line) sits on the SoC DRAM slave so L2/L3 miss fills, the server prefetcher, and
the island DMA share one map. L2 data-bank selection is
`(set * associativity + way) % banks`, not `addr[7:6]`. At eight ways/four banks
this is effectively way-based, so there is no one-bank/one-channel guarantee.
Do not let a line or AXI burst straddle `2^DramChanShift`.
Detail: [`../uncore/dram-channel-scaling.md`](../uncore/dram-channel-scaling.md).

| Level | Module | Config |
|-------|--------|--------|
| L2 | `g6lc_l2_top` | `L2En`, size/assoc/MSHR/banks; default-off `L2RoundRobinEn` experiment |
| L3 | `g6lc_l3_top` (wraps L2 engine) | `L3En` (requires `L2En`) |
| Prefetch | `g6lc_server_prefetcher` | `ServerPrefetchEn`, streams, distance |

## Evidence compartments (do not mix)

| Lane | Files | Purpose |
|------|--------|---------|
| L2 RTL | `corev_apu/l2_cache/g6lc_l2_{top,tag,data,mshr,pkg}.sv` | Cache engine; `RR_EN` generate is default-off |
| Leaf sim | `verif/tb/l2/tb_g6lc_l2.sv`, `run-l2-tb.sh` `L2TB_MODE=sim`, proxy `l2-leaf --mode sim` | Replacement/bypass/AMO-arith at the L2 pin |
| Leaf units | `verif/tb/l2/tb_g6lc_l2_units.sv`, `--mode units` | MSHR merge/full/waiter + data bank-conflict only |
| Leaf synth | `run-l2-tb.sh` `L2TB_MODE=synth`, `--mode synth` | Generic `$mem_v2` / cell counts; not STA |
| Equiv | `run-l2-tb.sh` `L2TB_MODE=equiv`, proxy `l2-equiv` | RR-off vs pinned pre-RR; map/collect/bbox |
| Isolated overlay | `verif/regress/isolated-config-overlay.py` | Copies one package; allowlist `L2RoundRobinEn` only |
| Cluster CRT | `mini_amocas_{w,d,q}.S`, `mini_stream_plane.S`, `qualify-stream8-minis.sh` | Zacas/stream functional; not L2 ROI |
| Isolated core | `mini_checked_work.S`, `mini_l2_hot_scan.S` | Fill/verify and hot+scan; not CRT minis |
| SMT2 | `g6lc64_smt2`, `qualify-soft-ladder-osbi.sh` | Cookie soak; do not pair RR-on until fetch is approved |
| OoO formal | `core/ooo/formal/g6lc_ooo_rename.sby` (+ cover, path-check only) | Rename BMC vs covers; remote z3 cover TIMEOUT; not an L2 gate |

Proxy kinds stay split: `rtl-leaf-diagnostic`, `rtl-leaf-units`, `rtl-leaf-synth`, `rtl-leaf-equivalence`. Generic synth is not physical area.

## Server-ready smart prefetch

`g6lc_server_prefetcher.sv` on the L3→DRAM (or L2→DRAM) AXI edge:

1. **Next-line** at `ServerPfDistance` on demand miss  
2. **Multi-stream stride** train (up to `ServerPfStreams`)  
3. **Demand always wins** AR arbitration; PF injects only when AR idle  

Complements L1 HPDCACHE stride (`HwPrefetchEn`) — L1 for tight loops, L3 edge for
LLC-friendly server streams (packet buffers, page copy, KVM guest memory).

## U6.0 L2 (implemented)
MSHR line-merge, banked data (`tc_sram`), NC bypass, WT+RA, parallel tags.
Exclusive `AR.lock` (LDEX) is captured and forwarded on the memory-side AR and
never takes the tag-hit path — otherwise `g6lc_axi_lrsc` never arms and
`sc.d` returns 1. `AW.lock` / ATOP were already preserved.

## Invariants
RVWMO; PMA (MMIO uncached via NC bypass); CBO end-to-end; 64 B lines with `Zic64b`
(equals default `DramChanShift=6`). Demand miss wins AR over prefetch **and** must
keep winning over island GEMM when both share the DRAM slave.

## Status
L2, L3 and server PF RTL are **present/config-gated**, not release-qualified.
The L2 top FSM serializes requests through fill and response; multiple MSHR
entries and data ports do not establish hit-under-miss, merged-response service,
or multiple outstanding misses at this boundary. PMU group 2 is **wired**
(cluster → core); do not sum duplicate shared-cache views across cores.
Inclusive paths are **present/config-gated**, with concurrency qualification open:
- L3 (or L2) victim → **L1** via `g6lc_l3_inclusive_inv` (`INCLUSIVE_L3`; TB sets it when `L3En`)
- L3 victim → **L2 tag match-inval** via `l2_back_inval_*` / `inval_match_*` on `g6lc_l2_tag`
DT: `dts-l3-prefetch.md`. Stream×multicore suite: `mc-stream-tests` (`g6lc64_ooo_server`).
Open: Ara live vector on sim flist (IP vendored + `Flist.ara` ready).

## Default-off replacement experiment (2026-09-14)

`L2RoundRobinEn` flows through both config structs, `build_config`, and
`g6lc_cluster` into `g6lc_l2_top.RR_EN`. All 27 explicit target literals,
including deprecated/UVM variants, set it to zero. `check_cfg` requires L2
enabled and power-of-two associativity of at least two. L3 inherits the
unchanged `RR_EN=0` default and has no policy enable of its own.

The experiment retains lowest-invalid-way priority. For all-valid sets it
uses a per-set pointer, advanced past the installed way only when installation
completes. A one-port, one-cycle `tc_sram` in `gen_rr.i_metadata` reads on
cacheable, non-exclusive AR acceptance, alongside the existing request capture.
The result is available in `S_TAG`; neither hits nor misses gain an FSM stage.
Tag reset invalidates all ways, and invalid-first installs initialize each set
before the pointer can be used for all-valid replacement. No SRAM reset sweep
or resettable per-set flop array is required. Reset/invalidation tests exercise
this rule. This relies on the current serialized controller; nonblocking work
must redesign metadata ownership/read timing rather than reuse it blindly.

**Timing/backend/DFT:** additional control is an accepted-AR read enable, set
address mux, and installed-way increment; no new clock or reset domain. Logical
metadata is 512×3 = 1,536 bits at 256 KiB/eight ways/64 B. Actual macro width,
periphery, test access/MBIST, scan integration, mapped area, power and the
1.25 GHz target remain unqualified. `tc_sram` is the macro seam, not evidence
that a foundry macro or DFT hookup exists. Existing hit/miss/victim ports provide
leaf observability; no new architectural PMU event/CSR or software ABI is claimed.
DTS sizes, line widths, memory map, ISA discovery, SMT scheduling, issue and
retirement are unchanged. Structural/default-off equivalence is still a gate;
matching test counters alone is not a netlist proof.

### Diagnostic evidence, not production qualification

Run `bash verif/tb/l2/run-l2-tb.sh`; the runner does not clean prior outputs.
Each invocation creates a fresh `run-*` child under `L2TB_OUT` and copies its
closed input set into `source/`, checking source consistency before compilation.
It compiles the copy, not the live worktree, and preserves logs, hashes and
`run.args`. Simulation always enables the bypass and ATOP follow-up regressions.
`L2TB_OUT` selects an artifact parent, `L2TB_RR_EN=0|1` selects policy,
and `L2TB_EXTRA` accepts geometry overrides. `L2TB_MODE=config` checks the
`TARGET_CFG` package, propagation and legal enable; `+bad-cfg=1|2|3` must fail
for no L2, one way, and non-power-of-two ways. `L2TB_CONFIG_LINT=1` limits that
mode to elaboration. `L2TB_MODE=synth` runs Yosys/slang with live AXI ports,
memory-count and no-latch assertions. These runs are local diagnostics under
the AGENTS exception; they emit no strict `G6LC_EVIDENCE` and prove no SMT/core
or multicore configuration. Source/executable hashes and logs accompany final
simulation runs; remote source/build/run binding remains separate.

The original 13-phase checked suite uses independent requested-write and backing-memory
models, response ID/length/data checks, stalled-response assertions, exact
accepted/completed-work accounting, unique misses, installed fills and external
traffic. It covers cold/all-way hits, full-line responses, conflict traces,
masked WT stores, quiescent back-invalidation, reset, NC and exclusive bypass.
Zero MSHR-full/bank-conflict counts at the serialized top are **coverage gaps**,
not concurrency passes. `L2TB_MODE=units` instantiates `g6lc_l2_mshr` and
`g6lc_l2_data` directly; remote Verilator 5.008 PASS
`l2-leaf-20260915T020340-df5db8e21fd8` (`mshr_full=1 merge=1 merge_full=1
waiter=1 bank_conflict=1 bank_ok=1`). The top still leaves `merge_full_o`
unconnected and ties `waiter_pop_i` to 0.

Verilator 5.020, 4 KiB/four ways/64 B, memory latency 6, seed `0x600df00d`:

| Phase | Legacy cycles | RR cycles | Interpretation |
|---|---:|---:|---|
| hot_scan | 12,096 | 9,024 | 192 RR hits vs zero legacy hits |
| lfsr | 9,840 | 8,640 | 99/446 RR hits vs 24/446 legacy hits |
| protected_hot | 1,152 | 1,920 | RR regression: 48 vs 96 hits; legacy protects nonzero ways |
| Entire diagnostic | 30,315 | 26,811 | 1,493 completed reads, 83 writes each; workload-specific only |

Artifacts: `remote-runs/l2-sram-final-rr{0,1}/`. Despite the directory name these
are **local** diagnostics. Zero initial memory latency with one bubble every
three cycles passes both policies (`l2-sram-stall-rr{0,1}`); an eight-way RR
fixture with bubbles every five cycles also passes (`l2-sram-8way-rr1`). The
old random-mix numbers used an incorrectly converted seed and are superseded.

Yosys/slang generic 4 KiB/four-way screening (`l2-synth-rr{0,1}`) passes:
two vs three pre-map memories, 120,844 vs 121,015 post-map generic cells, no
latches and zero `check -assert` problems. Memory mapping expands data SRAMs
to generic gates/flops, so this is **not** a physical-area percentage. Verilator
`LATCH`/`UNOPTFLAT` diagnostics remain narrowly waived by signal for this bench;
they did not establish physical latches or loops in the synthesized fixture.
Vendor SRAM read-output reset warnings remain visible in synthesis logs.

### Bypass-R correctness follow-up (2026-09-14)

The recorded `+bypass-backpressure` failure was reproduced from a fresh copied
baseline (`remote-runs/l2-drain-before/run-30YFmOGc`), then repaired independently
of replacement policy. `S_BYPASS_R` now retains the slave's ready signal rather
than being overridden by the common drain block. The AR outstanding flag clears
only on `RVALID && RREADY && RLAST`; the existing short-last guard for line fills
is retained. This is an unconditional AXI correctness correction inside the
existing enabled L2 engine (also reused by L3), **not** a new optional feature.
It adds no state, SRAM, clock/reset domain or pipeline stage. The restored
slave-to-master ready path and last-handshake qualification are the timing
change; physical STA is still required. No ISA/DTS/config geometry change or
new PMU event is needed for this handshake repair. Scan/MBIST state is unchanged.

The regression extension checks five bypass requests / thirteen accepted R
beats: single/burst stalls including the final beat, exclusive EXOKAY and
SLVERR/DECERR forwarding. Three synthetic ATOP response schedules check R before
B, R held across B, and delayed R after B, including ID/data/user stability and
exact completion counts. A following full-line miss/hit checks return to normal
service; a deliberately injected early short-last checks the existing fill
guard. These are **AXI seam/robustness tests**, not actual AMO arithmetic or
reservation-monitor verification. Cacheable fill errors and a new request
racing an as-yet-unoffered delayed ATOP response remain outside this coverage.

Local Verilator 5.020 four-way RR off/on suites pass, now 16 measured phases
plus three ATOP forwarding cases: 1,501 accepted reads / 86 writes each,
30,689 / 27,185 cycles. The original 13 phases retain their previous counts and
cycles. Eight-way RR with latency=0/stall-every=3 also passes. Generic leaf
synthesis passes with 120,846 / 121,017 cells (+2 per policy vs before the fix),
two/three pre-map memories, no latches and no check problems. Artifacts:
`l2-drain-after-rr0/run-w3tXDS1s`, `l2-drain-after-rr1/run-XPrW1XDa`,
`l2-drain-stall-8way/run-h6RTCnpq`, and `l2-drain-synth-rr{0,1}/run-*` under
`remote-runs/` (these named artifacts are local).

**Remote isolation:** `testharness_proxy.py l2-leaf <snapshot-source-dir>
--rr-en 0|1` copies only ten allowlisted inputs into a fresh remote `runs/l2-leaf-*`
directory, checks uploaded hashes, executes the expanded suite, pulls logs and
emits `leaf-result.json`. It never calls shared-repository sync, cleanup, or
stranded-harness killing. It can also snapshot the repository root; source
changes during upload fail remote checksum validation. Failure/missing logs
cannot become success. This record explicitly sets `strictQualification=false`;
it is not the core/SMT `G6LC_EVIDENCE` contract. The initial remote attempt
correctly failed on a Verilator-version-incompatible warning name; the runner
now probes warning-name support and uses the vendor-scoped WIDTH alias, without
disabling assertions. Pinned Verilator 5.008 subsequently passes both policies:
`l2-leaf-20260914T234313-4bd9099b1be4` (off) and
`l2-leaf-20260914T234448-fec52bccce2d` (on), with source hashes and pulled logs.

The bypass defect is **fixed at the tested leaf boundary**, but promotion still
requires real ATOP/AMO/SMT controls and cluster integration. Concurrent
invalidations, cacheable fill errors, MSHR merging/full, bank conflicts, formal
non-vacuity, production geometry, paired core workloads and physical
qualification remain open. RR default-off equivalence must use the corrected
AXI baseline; the repaired stalled-bypass behavior intentionally differs from
the defective baseline. Performance promotion is **NOT QUALIFIED**.

### Independent policy model and scoped equivalence

The bench now maintains independent line addresses, valid bits and per-set
next-victim pointers from accepted requests, completed installs, writes and
quiescent invalidations. It checks hit/miss classification, install set/way,
victim validity/address and nonempty coverage. A separate reset/fill test
invalidates way one, fills that hole first, then checks the subsequent full-set
victim. Expected victim addresses can be deliberately corrupted with
`+policy-oracle-negative`; this fails the checker rather than emitting PASS.
The model covers the serialized/quiescent test envelope, not simultaneous
install/invalidation arbitration or MSHR concurrency.

Remote 5.008 results (17 phases plus three ATOP schedules):

| Profile | Checked lookups | Installs | Evictions | Victim-way mask | Run |
|---|---:|---:|---:|---|---|
| Four-way, RR off | 1,484 | 1,341 | 1,243 | `1` | `l2-leaf-20260915T001658-72af040d10a6` |
| Four-way, RR on | 1,484 | 1,122 | 1,013 | `f` | `l2-leaf-20260915T001701-554d8da2815c` |
| Eight-way RR, latency0/stall3 | 1,432 | 1,058 | 952 | `ff` | `l2-leaf-20260915T001821-86549ac21b77` |

The four-way runs complete 1,507 reads and 86 writes each. These checks validate
policy execution, not just a favorable miss-count change. The proxy requires
positive consistent counters and the correct policy-specific victim mask;
missing cases, duplicate PASS records, wrong masks and failing return codes
are rejected. Its environment explicitly fixes geometry, seed and empty extra
overrides. The original workload trade-off remains; no new speedup is claimed.

`L2TB_MODE=equiv bash verif/tb/l2/run-l2-tb.sh` runs a separately bounded Yosys
check. Its default is a **512-byte/four-way/two-set fixture**, not production
cache geometry. `L2TB_BYTE_SIZE` and `L2TB_SET_ASSOC` override it;
`L2TB_EQ_TIMEOUT` defaults to 120 seconds. Missing inputs, tool failures,
timeouts or unproven points fail. The local Git store must contain reference
blob `5be075b1a01ff754da384c3dd129fd58c33733fa` (override via
`L2TB_EQ_BASE_BLOB` only with an independently reviewed reference). The runner
copies this pre-RR engine and applies only the two-line bypass fix, refusing
a reference already containing RR or lacking the expected patch anchor.
Original/corrected reference hashes, blob ID, copied current sources and the
Yosys script are retained in the fresh run directory. No worktree RTL is
rewritten to construct the golden model.

The fixture has live AXI inputs and all observation outputs. Both sides use the
same current tag/data/MSHR primitives, 512-bit lines, four MSHRs and two banks;
this tests the top-level replacement delta, not historical primitive changes.
The flow maps memories, normalizes asynchronous resets at clock boundaries,
requires a nonempty comparison set, merges identical cells, and runs
`equiv_simple -short -undef -seq 2` plus `equiv_status -assert`. It does not
ignore unknown cells or waive unproven points. This is scoped clock-boundary
sequential equivalence under the matching-state/reset model, not electrical
reset/CDC or whole-SoC verification.

Yosys 0.68+1 (`c30457480`) proves:
- 256 B/two-way fixture: **9,151 proven, zero unproven**
  (`l2-equiv-short/run-p9hU86oH`).
- 512 B/four-way fixture: **11,675 proven, zero unproven**
  (`l2-equiv-4way-small/run-GC6b0TBD`).
- `L2TB_EQ_NEGATIVE=1` inverts only the gate hit output and must fail;
  `l2-equiv-short-negative/run-YSRsaZAE` leaves exactly that output unproven.

The final default-mode rerun also passes (`l2-equiv-final/run-1blQPZgt`);
`l2-equiv-final-negative/run-ZG0cGREl` fails on the inverted hit output.

Earlier full-cone and alternative-preprocessing trials timed out; a structural
matching trial produced invalid internal matches and was rejected. The
4 KiB **mapped** check also exceeded the 120-second SAT budget. None is counted
as a proof or used to justify RTL changes.

### Larger-geometry equivalence and real AMO controls (2026-09-15)

`L2TB_EQ_MEM=bbox` keep-hierarchy blackboxes slang-uniquified
`g6lc_l2_tag*` / `g6lc_l2_data*` / `g6lc_l2_mshr*` / `tc_sram*` so flop
tags do not enter SAT. That is **controller/port** RR-off equivalence
against the pinned bypass-corrected pre-RR engine, not a tag-flop netlist
proof. Yosys 0.33: 4 KiB/4-way 2054/0 (`run-ChPtb8Vc`); 16 KiB/4-way PASS
(`run-kLWpIH6I`); 256 KiB/8-way 2057/0 (`run-zisQrCl4`,
`--unroll-limit=16384`). Inverting `hit_o` leaves exactly that output
unproven. Collect 4 KiB/4-way **13828/0** (`run-DIR7V5Rx`, 275 s); the
earlier collect timeout is superseded. Mapped
flop-tag RR-off vs bypass-corrected pre-RR: 1 KiB/4-way **16670/0**
(`run-CpQ2EFZ1`); 2 KiB/4-way **26625/0** (`run-lOd2ZWuD`); 4 KiB/4-way
**46468/0** (`run-n4dThvgT`, 300 s); 8 KiB/4-way **86023/0**
(`run-76BAyumg`, 490 s). The earlier 4 KiB mapped 120 s miss is
superseded, not waived. Default ladder includes 1 KiB/2 KiB map plus
4 KiB/16 KiB bbox; 8 KiB map is opt-in (600 s). Proxy `l2-equiv --mem
map|bbox`. Isolated equiv must set `YOSYS` to testharness
`toolchains/formal/bin/yosys`. 1 KiB mapped hit-inversion leaves exactly
`hit_o` unproven (`run-eYUjh1hE`, 16670/1). Collect 16 KiB timed out at
900 s (`l2-equiv-...T072626-2597c1ae5355`) — incomplete, not waived.

`+amo-arith` (always enabled by the runner) is a **real** memory-side AMO
model: ADD/SWAP/CAS.W arithmetic, exclusive LR EXOKAY reservation, SC
EXOKAY success and OKAY failure, then a cacheable read that must observe
the computed value after WT self-inval. Remote Verilator 5.008 PASS
`l2-leaf-20260915T012151-99c14472e3e2` (RR off). Synthetic ATOP R/B
forwarding remains; it does not replace this. Cluster AMOCAS W/D/Q and SMT
cookie soaks stay the named-package controls (`qual-stream8-minis`,
`qual-soft-ladder-osbi`). Isolated stream8 RR-on now ran the four cluster
minis with **identical** cycles vs production RR-off (AMOCAS.W 550, D 704,
Q 998, stream_plane 2138). `mini_l2_hot_scan.S` (512 L2 sets, 16 scan
rounds, hot checksum PASS) is also **384,179 / 384,179** cy. Paired leaf A/B (amo-arith PASS both). 4-way/4 KiB: RR-off **31,108** cy
vs RR-on **27,604** cy (`hot_scan` 12,096→9,024; `protected_hot` 1,152→1,920).
8-way/4 KiB: RR-off **26,256** cy (`...T080935-67c68349c896`) vs RR-on
**26,080** cy (`...T081003-a0436a16ea1d`, mask=ff) — mix ~0.7%; hot_scan
6,720→4,928 cancelled by protected_hot 1,792→3,584. Core+L1+WT still 0
delta. Best area/perf in this tranche: keep RR default-off. SMT2 RR-on remains
a fetch livelock. No RR default-on and no performance promotion.

Isolated core overlays (`verif/regress/isolated-config-overlay.py`) may
flip only `L2RoundRobinEn` in a copied package and derived flist.
`SOFT_LADDER_ISOLATED=1` refuses production Mdir basenames
(`work-ver-stream8`, `work-ver-smt2-fw64-B`, …) even when the path is
absolute. `mini_checked_work.S` is a 48 KiB checked fill/verify with DRAM
markers; N=2 is experimental.

Isolated RR-on candidate (2026-09-15): Mdir `iso-stream8-rr1`, overlay
`L2RoundRobinEn` 0→1, exe `ec650f20…` vs production `7e27de94…`. Same
N=2 ELF as the RR-off control: kernel `tohost=1` after 154,170 cycles
(`checked-work-stream8-n2-rr1`). Cycle match is expected for sequential
fill/verify; it is not a replacement-policy speedup. Production defaults
stay RR-off.

SMT2 pairing (same overlay, named package not merged): isolated
`iso-smt2-rr1` elaborates `i_l2.gen_l2.gen_rr.i_metadata` (real RR-on).
Production N=1 uncompressed-tohost CONTROL PASS
(`checked-work-smt2-n1-norvc`, 129,455 cy, `tohost=1`; fully
uncompressed body 135,616 cy). Isolated RR-on **livelocks** in verify
at 400k and 2M cy (`tohost=0`): SMT2 I=2 fetch dual-issues the two loop
addis and never the `bnez`. Uncompressing the loop and inserting a nop
only moved the stuck pair. Stream8 I=1 RR-on still completes. Not L2
data corruption (never `tohost=3`). Fetch dual-issue repair is
follow-on. Not a pass and not promotion.

MSHR merge/full/waiter and same-bank vs different-bank conflict are now
leaf-covered (`L2TB_MODE=units`). Isolated stream8 RR-on checked-work is a
functional envelope (`iso-stream8-rr1`, 154,170 cycles, `tohost=1`), not
promotion. Production-geometry mapped equivalence, candidate-on SMT
pairing, and physical gates remain open. Rename allocation/exhaustion/ckpt
covers reached locally with yices (`g6lc_ooo_rename_cover.sby`); they are
not a testharness formalTasks gate. The separate core lint command passed its budget (278 warnings) and strict
elaboration; the unbounded core synthesis attempt was cancelled incomplete.
This tranche changes verification/tooling and the leaf TB memory model
only: no new silicon state, clock, reset, PMU event, ISA/DTS exposure or
enabled production replacement policy.
