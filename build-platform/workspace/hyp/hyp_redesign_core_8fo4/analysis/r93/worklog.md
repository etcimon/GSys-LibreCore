# r93: one-cycle DOT4 publication

Baseline: r92, commit `7d01bc4df`. Accepted RTL specializes DOT4A arithmetic
by register-port count at elaboration and exposes one signed 32-bit value
to the original opcode result arm. Two ports supply the sign-extended
18-bit dot sum; three or more retain the five-operand sum with modulo-32
accumulation. The result arm extends once to XLEN. The earlier XLEN-wide
alias and nested port-count condition are removed.

## Matched results

| Binding | r92 | r93 accepted |
|---|---:|---:|
| One cycle, two ports | 60.43985 | 45.60 |
| One cycle, three ports | 63.60 | 45.60 |
| Two cycles, two ports | 34.10 | 34.10 |
| Two cycles, three ports | 34.10 | 34.10 |

Tool: sv-timing-core 0.1.0, parser_pin=v0.13.5.
Structural delay-v49 / ir-v6 / correction-v5, fo4_ps=20, target=5000 MHz,
margin=0.2, budget=8. Results are the maximum across all reported path
kinds, including input-to-register. The accepted artifacts are
`../timing/boards/r93-publish-d{1,2}-r{2,3}.{json,log,manifest.json}`.
The recipe checks binary, flist and parameter hashes against the frozen
r92 boards. The final source and all four manifests were checked; no
parse skips or analyzer errors occurred.

From the repository root, on the intended source revision:

```text
python build-platform/workspace/hyp/hyp_redesign_core_8fo4/analysis/r93/measure.py NEW_LABEL
wsl -e bash -lc 'cd /mnt/e/cva6 && bash build-platform/workspace/hyp/hyp_redesign_core_8fo4/analysis/r93/run_hyp8_ai_exec_local.sh'
```

Use a new measurement label; the recipe refuses overwrite. Large IR and
compiler logs remain local. Source SHA256 for the accepted timing and leaf:
`1cb9de38e5f9fa56537228c3d64f86ce5041da33376364af87e609011c068082`.

This gain is sensitive to how static configuration and sign extension are
represented in the structural analyzer. Synthesis can already fold static
conditions. The result is not evidence of an equivalent mapped or routed
delay reduction. The arithmetic tree itself remains the r92 implementation.

## Strategies evaluated

- A broad one-hot publication path separated low result bits and sign before
  an OR merge with other results. It passed functional checks but measured
  60.89 FO4: two serial sign-broadcast nodes cost 11.1 and 11.8 FO4.
  The default worsened slightly, and the two-stage report included an
  inactive path. Rejected; patch saved in `select-rejected.patch`, boards
  `r93-select-*`. These boards used CRLF source; its hash matches exactly
  the LF candidate after CRLF conversion.
- An inline low-word/high-sign slice variant measured 60.44/73.75 FO4
  for the one-cycle two/three-port bindings and failed XLEN=32 elaboration
  because of the empty replication. Rejected. `r93-narrow-*` describes
  that pre-fix candidate, not the later generate-extension workaround;
  the workaround was also discarded and has no accepted timing claim.
- The accepted alternative moves configuration selection outside opcode
  publication, retains a bounded signed value, and uses one result assignment.
  It preserves the original result register and all surrounding contracts.
- A global explicit compressor tree was considered, not implemented.
  ALGORITHMS-EXPERTS A85 already models multi-operand addition as reduction
  plus a final adder; A77 records cases where explicit carry-save logic
  regresses. A future arithmetic trial must measure the complete connected
  tree, with signed correction and accumulator width proved, rather than
  assume improvement from a compressor's name or a hierarchy split.

## Functional evidence

Eight configurations pass the existing exhaustive byte-pair, randomized
DOT4/DOT4A, accumulator-wrap, reset, metadata/PMU, continuous DOT issue,
MMA and F17 checks. New checks cover full-width GETCFG, zero-request SETCFG,
POLL and disabled ENQ, plus a sixteen-operation mixed stream with no idle
gaps. The stream checks per-opcode latency, acceptance spacing, identity,
data and absence of extra completions.

| Binding | Checks |
|---|---:|
| D1, ports 2, XLEN 64 | 140303 |
| D1, ports 3 or 4, XLEN 64 | 140347 each |
| D1, ports 3, XLEN 32 | 140347 |
| D2, ports 2, XLEN 64 | 141889 |
| D2, ports 3 or 4, XLEN 64 | 141941 each |
| D2, ports 3, XLEN 32 | 141941 |

PASS records and binding identities are in `logs/summary.txt` and
`logs/sim-*.log`. Historical r92 evidence is unchanged.

The repository lint attempt remains blocked by its generated Hyp8 flist
pointing at missing production `core/include/g6lc64_hyp8_config_pkg.sv`.
The actual log and exit status 1 are retained in `logs/verify-lint.*`.
The final `./build.sh verify --lint --sim --synth --target g6lc64_hyp8`
attempt also exited 1: both lint steps and synthesis failed on that missing
package; CV64 simulation exited 1 and CV32 simulation exited 130. Their
root causes were not diagnosed. Full output and status are retained in
`logs/verify-full.*`. This is focused leaf qualification, not a passing
aggregate verification gate.

No state, cycle, throughput, reset, ownership, DFT, PMU, encoding or
DTS/software contract changes. Production RTL is untouched by this work.
Existing tier-R RTL and MIT verification/tooling notices remain intact.
The scoped licensing pass checked the active Etienne Cimon policy, file-tier
matches, inherited headers and existing CLA records; no link set changed.
No OpenROAD or mapped area/power/timing study was run; 8-FO4 closure remains open.
