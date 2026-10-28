# r19 — GEMM functional windows and parallel arithmetic

This pass implements three functional leaves and two additional register
windows in the hyp APU GEMM path. The final board is
`build-platform/workspace/build/sv-timing/hyp8-src/boards/ai-island/
analyze-ai-hyp-r19.json`; its `.cmd` and `.manifest.json` record the invocation,
source/input hashes, caller references and successful gate logs.

## Measurement and caller contracts

The matched baseline is `analyze-ai-hyp-r19-before-complete.json`, using
`inputs/ai-island-hyp-r19-before-complete.f` and the pre-r19 GEMM snapshot.
The timing-flist audit found that the existing `g6lc_ai_mul_seq` dependency
was missing from the generated closure. It is now included in both matched
boards. The three new leaves are also explicit flist entries. The initial
`r19-before` and intermediate `first/second/third` boards are retained.

All numbers use sv-timing 0.1.0, ir-v5, delay-v44, parser v0.13.5,
5,000 MHz, 20 ps/FO4 and 0.2 margin: an **8.0-FO4 structural screen**.
There is no physical timing or 8-FO4 closure claim.

| Module / former cone | Before | Final structural FO4 |
|---|---:|---:|
| `g6lc_ai_gemm_seq` local maximum | 119.50 | 98.00 |
| FP accumulation arithmetic | 118.10 inside GEMM | 94.93 in `g6lc_ai_gemm_fp32_add` |
| Residency span arithmetic | 114.60 inside GEMM | 18.30 in `g6lc_ai_gemm_span` |
| New `g6lc_ai_gemm_store_plan` | inside GEMM | 39.80 |
| Shared iterative `g6lc_ai_mul_seq` | existing dependency | 20.00 |

Caller reference searches followed `cross_module_paths` instance names, ports,
bridge nets and parent/child path IDs back to island top and dispatch.
Island top's single-cluster arm uses `i_gemm` directly; dispatch's `i_eng`
instances consume a complete slice descriptor and the original N as C pitch.
Both callers allow variable job latency, require start while ready, and
associate completion/errors/PMU publication with the accepted job.

| Caller stitch | Before | Final |
|---|---:|---:|
| dispatch → GEMM | 153.80 | 127.25 |
| island top → GEMM | 157.05 | 130.50 |

New internal stitches are also reported, rather than hiding the extracted
logic: GEMM→store planner is **132.75**, GEMM→span **111.25**, and the FP
adder stitches are approximately **114.50**. These graph estimates are
over budget; module maxima alone do not establish end-to-end closure.

Follow-up audit: these stitch rows are representative module-path sums,
not validated connected cones. All four internal rows append operand-assembly
path 1297 to unrelated child outputs; span/store selections also end at
internal register D pins. FP's selected 21.55 contribution omits its later
composed 94.93 cone. External stitch comparisons need the same qualification.
See [gemm-internal-stitches-r19.md](gemm-internal-stitches-r19.md) for the
source/IR evidence and the actual boundaries to optimize.

## Functional split and transforms

The strategy follows `sv-timing/ALGORITHMS-EXPERTS.md`: A20's parallel
dependency schedule, A33's distinction between latency-neutral relocation
and temporal/architectural changes, A104's one-hot masked-OR selection,
and A134's preparation of facts at their owning transaction boundary.
These are handwritten RTL changes measured again after implementation,
not timing credits or projected stage counts.

**Store ownership — `g6lc_ai_gemm_store_plan.sv`.** A request captures the
committed C credit. Separate credit, parallel burst/stripe limits and
publication stages produce a stable descriptor. The planner owns the address
until the associated B response. Incremental row/column addresses replace
the repeated row×pitch product. Row strides use the descriptor's original
`ldc`, including cluster slices. An assertion compares the cursor to the
original address function.

Once planned, the store continues to own its immutable committed columns
even when more dots enter the MAC pipeline. AW/W/B use that plan token,
rather than re-sampling a changing trail-readiness predicate.

**Raw W-beat window.** C-bank data, lane, byte mask and last travel together
through a register before bus packing. The ready/valid payload remains held
through backpressure. A separate SRAM-fetch cursor advances on capture while
the AXI counter advances on acceptance. This permits simultaneous drain and
refill without duplicating a beat, sustaining one beat per cycle within
dual-read pair/wide bursts under continuous ready. Reads stop at the plan's
last beat even when its buffered payload is stalled. Assertions check
`fetched - retired == buffered_valid` and payload stability; the existing
AXI channel cuts remain in place.

**Seed-read window.** Accumulate-C AR preparation captures the address and
remaining count, computes burst and stripe bounds in parallel, then publishes
the request. The next descriptor can prepare while the current R burst
drains. Its cursor advances only on AR acceptance, and the descriptor holds
until accepted. The retained product/load-completion join from r18 remains.

**Residency facts — `g6lc_ai_gemm_span.sv`.** A/B/C span products run in
parallel through the existing bounded shift-add multipliers. Completion
bits join zero and nonzero products in either order. Span arithmetic,
widened end addresses and overlap comparisons occupy separate windows.
The original 32-bit span arithmetic is preserved, and simulation assertions
compare the published overlap facts with the original expressions.
`ST_PREP` waits for these facts before reuse can skip a load; it is bypassed
when both reuse parameters are disabled. Invalidation remains live.

**FP recurrence — `g6lc_ai_gemm_fp32_add.sv`.** Two signed FP32 significands
need a 26-bit aligned sum, rather than the 640-bit dot-product representation.
Exponent differences run beside the exponent comparison. Positive and
negative sum candidates run in parallel, using
`-sum = ~aligned_a + ~aligned_b + 2`; the negative candidate uses an explicit
carry-save pair followed by one carry-propagate add. Twenty-five constant
normalization candidates run beside leading-bit detection and combine through
a mutually exclusive masked-OR. No encoded-MSB→variable-shift chain remains.

The FP leaf deliberately matches the repository's `fp32_add`, including its
signed alignment truncation and zero-exponent convention. Its existing
non-IEEE corner behavior is preserved. This is equivalence to that reference,
not IEEE-754 certification. The accumulator recurrence, dot tags and MAC
latency remain unchanged.

## Focused evidence and reproducibility

From the repository root under WSL:

```sh
bash build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/analysis/tools/run_ai_r19.sh gemm
AI_GEMM_DPF_LIST=0 bash build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/analysis/tools/run_ai_r19.sh reuse
bash build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/analysis/tools/run_ai_r19.sh cluster
bash build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/analysis/tools/run_ai_r19.sh wide
bash build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/analysis/tools/run_ai_r19.sh stripe
```

The runner uses `/usr/bin/verilator` with `--assert`, MAX_K=64 and DPF=0/2;
the reuse run uses MAX_N=64. `gemm-extra-sources.inc.sh` supplies the hyp
leaves to existing bench closures only when those files exist.

Successful logs under `build-platform/workspace/build/ai-gemm/`:

| Log | Evidence |
|---|---|
| `r19-gemm-stream.log` | Both backend goldens; 112 accumulate checks per DPF; 100,000 FP32 value/flag equivalence vectors per DPF; 56 signed checks; 672 AXI stall witnesses |
| `r19-reuse-stream.log` | Same focused checks with reuse enabled; span assertions; 16 residency-slot comparisons |
| `r19-cluster-stream.log` | Independent integer GEMM goldens for single/two/four engines over all three shapes |
| `r19-wide-stream.log` | 128-bit and 512-bit store paths |
| `r19-stripe-stream.log` | NCH=1/2, stripe caps, two live read IDs and mathematical C golden |

The final reuse/cluster/wide runs also report actual elastic W refill events
(67 in the slot run, up to 93 per cluster-bench instance, and 3/2 in two wide
instances), with the token-conservation and stall-stability assertions active.

The 100,000 FP vectors are repeated across configurations, not distinct
coverage sets. They include signed zeros, cancellation, subnormals,
infinities/NaNs, overflow and alignment boundaries, and compare all 37
result/flag bits.

The stripe harness needed its missing spill-register sources, a start pulse
driven off the sampling edge, and a bounded read delay before demanding two
live IDs. With immediate one-beat responses, a staged planner can legally
reuse ID 2 before preparing its next request; the strengthened harness holds
responses long enough to exercise both slots and retains the two-ID check.
The backend protocol test also required MAX_K≥17; the runner now provides 64.
An attempted legacy `+panel_reuse` invocation required much larger M/N
parameters and is not counted as a pass; the fitting slot gate is used here.

Verilator still warns about existing latches in `g6lc_ai_pe_dot`. Canonical
`verify --lint --synth --target g6lc64_hyp8` fails its three steps on the absent
production-path `core/include/g6lc64_hyp8_config_pkg.sv`; it does not qualify
the overlay. The final attempt is recorded in `r19-verify-final.log`.

## Tradeoffs, readiness and remaining work

The store planner adds four preparation edges and the raw W window adds a
startup edge, with full-rate refill inside a burst. Seed AR preparation adds
three edges but overlaps subsequent requests with R draining. Reuse adds
up to 32 multiplier steps plus capture/join/publication before admission to
the load/MAC phases. These are deliberate latency/area trades.

Backend fixture cycles are 1107/1196 for DPF=0/2 (r18: 1048/1126).
Single/two/four-engine PMU counts for the cluster shapes are
359/214/214, 488/345/233 and 318/320/320. These are fixture/engine counts,
not application throughput or dispatcher-inclusive latency.

Readiness review: existing configuration parameters and type seams remain;
no ISA, encoding, DTS or software ABI changed. New state uses the existing
clock and asynchronous active-low reset. No memory macro, clock gate or
clock domain was introduced. Existing SRAM/testmode seams remain; new
descriptor/beat registers are ordinary flops for the existing scan flow.
Total PMU cycles
include `ST_PREP`; the four phase buckets retain their existing meanings,
so preparation appears as additional uncategorized total cycles.

The trade is additional registers, parallel normalization candidates and
iterative preparation state for shorter combinational cones. Area, power,
scan insertion, placement and physical STA are not measured. Headers and tier
metadata were checked for the changed code; new RTL is tier R and tooling/
benches are tier T. Snapshots are retained under `analysis/tools/zips/`.

Remaining dominant work is the load-completion/control path (98.00), shared
operand-format gathering (92.95), and FP recurrence (94.93 leaf). Further FP staging
requires scheduling or interleaving dependent accumulations together with
their tags; adding an output flop alone would corrupt the recurrence.
No full-island formal, Linux boot, all-parameter qualification or 8-FO4
closure is established by this pass.
