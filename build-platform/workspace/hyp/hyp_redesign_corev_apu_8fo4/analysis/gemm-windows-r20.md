# GEMM r20 — prepared load completion and fixed operand layouts

Implementation pass following `gemm-internal-stitches-r19.md`.
The pre-edit sequencer is in `analysis/tools/zips/gemm-r20-before.zip`.
The timing executable is frozen at `hyp8-src/inputs/r20-sv-timing.exe`;
the matched baseline is `boards/ai-island/analyze-ai-hyp-r20-before.json`.
The live timing executable changed since r19, so old/new-model numbers
must not be interpreted as RTL gains.

Design contract:

- Prepare final-row/final-burst facts in the existing AR planner window.
  Retain all-issued until the owning load phase ends. Complete only after all
  accepted bursts return; preserve the sticky seed/load completion join.
- Use scalar channel admission/acceptance signals independently of the AXI
  payload. Keep AR slot reservation, R metadata and write-edge ownership.
- Generate constant 1/2/4-byte layouts and select them with format facts.
  Normal MAC groups use direct B-bank-group wiring; accumulate mode retains
  indexed groups. INT4 nibble masking and valid/coordinate alignment remain.
- Add no pipeline cycle, new clock, memory or ABI. Existing parameter legality,
  testmode/reset and PMU behavior apply. No config feature is added.

Validation: capture matched timing reports; use the existing backend,
accumulation/protocol, striped and multicluster checks on an isolated,
hash-verified hyp closure through the remote proxy. Add a simulation-only
comparison of completion and operand interfaces to the previous expressions.
Do not promote this into aggregate qualification or physical timing closure.

Remote preflight: 12 CPUs, approximately 116 GB available RAM, 205 GB free;
two existing model processes remain running. Use two compiler jobs per leaf,
one model thread, without mutating their tool/runtime or source directories.
Implementation and final evidence follow below.

## Result — implemented and remotely checked

Matched delay-v45 / ir-v6 measurements:

| Module | Before | Final |
|---|---:|---:|
| `g6lc_ai_gemm_seq` | 98.00 | **73.50 FO4** |
| `g6lc_ai_gemm_fp32_add` | 94.93 | 94.93 |
| `g6lc_ai_gemm_store_plan` | 39.80 | 39.80 |
| `g6lc_ai_gemm_span` | 18.30 | 18.30 |

The sequencer maximum falls 25%; the FP leaf is now the larger GEMM-family
cone. This is not a 25% reduction in whole-island clock delay.
The final board/IR/manifest are `analyze-ai-hyp-r20.{json,ir.json,manifest.json}`.
Their manifest records the frozen analyzer, all 65 closure files, remote
results and runtime identities. RTL SHA256:
`739118e063051fa14803c1337a21e6d9782f2fc079630fdc09cf6f5567119f4f`.

The AR planner now captures final-row and terminal-burst bits. A retained
all-issued bit and an empty-after-handshake predicate replace live issued-row
arithmetic in completion. This works for both ordered and split IDs, without
adding a receive/write cycle. Existing slot and lane-FIFO ownership remain.
Scalar offers isolate channel control from payload assembly.

The operand publication region now has per-lane constant layouts and a
separate B-group selection. Normal MAC mode uses fixed groups; accumulate
mode uses its indexed groups. INT4's nibble masks are preserved. No additional
pipeline stage or MAC cycle was introduced.

## Remote evidence

The new reusable runner is `verif/regress/remote/run_ai_hyp_gemm_review.py`.
Its `--prepare` option creates a source archive from the existing bench source
lists, resolves the hyp overrides, includes headers/helpers, and hashes every
file. Remote execution verifies the archive before building. Builds use two
compiler jobs and one simulation thread, in private run directories.
The stock 5.008 runtime is copied privately, repaired using the existing
qualified wide-constant fix, checked against the pinned header hash and
tested with original/fixed canaries. Installed tools are untouched.

| Remote tag | Result |
|---|---|
| `ai-gemm-r20-baseline-r1` | r19 source, DPF=0/NCH=1/OutCols=4: six cases and negative oracle pass |
| `ai-gemm-r20-first-r1` | fifteen cases pass: DPF=0/NCH=1 and DPF=2/NCH=2 with OutCols=4/reuse; stripe NCH=1/2; cluster configurations 1/2/4 |
| `ai-gemm-r20-wide-r1` | existing 128/512-bit and streaming-store bench passes |

The backend cases include 112 accumulate checks per profile, signed arithmetic,
protocol backpressure (672/869 stalls), 16 reuse-slot checks per profile, and
100,000 FP value/flag comparisons per profile. Negative golden corruption is
detected in both profiles.

Simulation-only `G6LC_AI_HYP_R20_CHECK` comparisons retain the previous
dynamic-index operand expressions and previous completion predicate.
They cover **62,576 lane samples** and **21,898 load-cycle comparisons**.
Format mask `11111011` covers the seven exercised encodings. Some unused
cluster instances correctly report zero samples; active instances have
nonzero checks and the bench checks mathematical C values.

The matched DPF=0 baseline and new golden both finish in **1344 cycles**.
Their complete warning signatures match after normalizing paths/locations.
Existing PE/vendor LATCH/UNOPTFLAT/width warnings remain; this is not a
warning-clean or synthesis-qualified result.

Raw logs and result JSON:
`C:/Users/etcim/AppData/Local/Temp/cva6-artifacts/<remote-tag>/`.
The source archives are `analysis/tools/zips/gemm-r20-{baseline,first}-closure.zip`.

Example reproduction from the repository root (through WSL on this host):

```text
python3 verif/regress/remote/testharness_proxy.py py \
  verif/regress/remote/run_ai_hyp_gemm_review.py \
  --tag <unique-tag> --data <first-closure.zip> \
  --env VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator \
  --env GEMM_REVIEW_CONFIGS=backend0,backend2,stripe1,stripe2,cluster \
  --pull --dest <artifact-directory>
```

Run `GEMM_REVIEW_CONFIGS=wide` separately for the existing combined wide bench.
The manifest retains each uploaded runner hash; the wide run used the
corrected `wide` selector, which needs no top parameter override.

## Remaining limits and next work

`bun build-platform/src/cli/index.ts verify --lint --synth --remote --target
g6lc64_hyp8` returned 1: remote lint and synthesis both fail because the
generic gate expects `/opt/testharness/repo/core/include/g6lc64_hyp8_config_pkg.sv`.
Strict standalone slang elaboration is skipped on that route.
`verify-ai-hyp-r20.log` records the two failures and one skip. This adapter
result does not qualify the overlay or invalidate the isolated leaf results.

Final sequencer path 1395 (73.50) is the sequential update bundle whose hot
node is `stride_b_grp_q` initialization at line 4207. Paths 1293/1292
(71.75/71.05) are operand-bank address preparation. These are the next local
owners; the larger FP recurrence remains the primary GEMM-family target.
The previously derived parallel rounded-polarity rewrite and C-commit
publication cut remain unimplemented. Caller sums retain the connectivity
qualification from the r19 audit.

Licensing checked: existing sequencer tier R/SPDX/attribution preserved;
new verification runner tier T, MIT, Etienne Cimon. Configuration, reset,
testmode, ISA/DTS and PMU contracts are unchanged. Physical timing,
area/power, aggregate qualification and the 8-FO4 objective remain open.
