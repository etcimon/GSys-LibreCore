# Bounded Development Harness Work Record

The bounded provisioning/runner increment and empty-layout correction are
implemented. No new remote RTL result or full qualification is claimed.

Follow-up: `apu-pgo-dma-increment.md` records enforced compiler PGO and bounded
unroll. Repository compiler provisioning now covers every APU RTL leaf stage,
not just dev. The compiler source digest plus PGO recipe digest keys its cache.
Cold two-pass setup is separate from the short simulation budgets below.
Generated simulator PGO is now also required and auto-provisioned. Current
receipts, immutable-image cache and concurrent development policy:
`apu-simulator-pgo-implementation.md`.

## Workflow

Use the existing testharness proxy and isolated snapshot, not a second remote
execution path. No network/SSH access was performed in this increment. The
prepared short command is:

```sh
APU_LEAF_STAGES=dev APU_DEV_COHORT=layout \
  bash verif/tb/apu/run-apu-remote-leaf.sh
```

Default dev cohort is `immutable`; `baseline` is also selectable. Each runs
three or four selected mechanisms, not a percentage-based conformance claim.
Dev now detaches by default: launch-only exit4 is INCOMPLETE until collected,
so implementation can continue concurrently on the mutable local tree.
`APU_LEAF_DETACH=0` restores synchronous CI, with a4200s poll budget,
2400s suite cap and5s poll interval. Compiler setup1200s, simulator-PGO total
setup1800s, per build/lock600s, training60s and final validation60s are distinct
budgets. Cold setup/build is not promised to be a short test.
Tune with `APU_TOOL_SETUP_TIMEOUT`, `APU_DEV_BUILD_TIMEOUT`,
`APU_DEV_TEST_TIMEOUT`, `APU_DEV_SUITE_TIMEOUT` and `APU_LEAF_TIMEOUT`.
Simulator-specific limits are `APU_SIM_PGO_TIMEOUT`, `APU_SIM_BUILD_TIMEOUT`
and `APU_SIM_TRAIN_TIMEOUT`.

Presence-only, without installation/build/simulation:

```sh
bash verif/tb/apu/run-apu-dev.sh --layout --check
```

Missing source/oracle files fail before the proxy opens SSH. Missing compiler
or runtime files fail check-only immediately. A normal dev run may provision
offline; `APU_AUTO_INSTALL=0` makes missing/stale tools a blocker instead.
Missing host dependencies are reported, never installed with apt/sudo.

## Implementation

- `verif/tb/apu/local-verilator.sh`: ready check includes actual compiler,
  launcher, runtime header, includer and matching source receipt.
  `apu_ensure_verilator` skips warm setup, otherwise checks local prerequisites
  and builds offline from tools/verilator with timeout (1200s), opt-out via
  APU_AUTO_INSTALL=0. Strict selector still rejects stale/missing tools.
  Snapshot identity comes from a proxy-generated 64-hex digest file rather
  than git (isolated snapshots lack git). No PATH fallback/system install.
- `run-apu-dev.sh`: baseline/immutable/layout cohorts, --check presence-only
  mode, required vector .hex/.exp/.json, PGO driver and recursive Flist presence checks
  through `apu_dev_preflight.py`. Native phase build timeout600s, test timeout60s,
  both configurable; preserves timeout return codes. Per-cache lock avoids
  same-cache concurrent builds/runs; per-run log directory may be supplied.
- `testharness_proxy.py`: new `apu-leaf --stages dev` mode, local input
  preflight BEFORE SSH, minimal compiler source closure (src/include/bin/m4
  plus configure.ac/root .in templates/install-sh and upstream license files)
  rides with checksum-verified
  snapshot. Compiler cache keyed by compiler-only digest; simulation cache
  keyed by entire source identity. No new --repo-tools flag (removed as
  unnecessary); dev automatically uses tools-source provisioning.
  Internal APU_VERILATOR_HOME/source-ID path cannot be overridden by --env.
  Hidden/unrecognized untracked compiler files are not uploaded; track a
  required new extensionless script explicitly. Tracked upstream files retain
  their headers, notices and licenses verbatim.
  Allows cohort/budget/auto-install knobs with validation. All RTL leaf stages
  now require the source-bound compiler and generated simulator PGO.
  Default dev cohort is immutable.
- `apu_source_manifest.py`: tools/verilator allowed in explicit file-list
  mode, not broad default walk; includes dev/tool configuration keys.
- `run-apu-regress.sh`: dev stage invokes short runner; rc3 missing tools
  now INCOMPLETE (as rc4/124/137 already were), not RTL failure.
- Small RTL fix: `vnfront` StDslHdrC resets dsl_off/dn/recs/hash BEFORE
  empty-layout branch. Previously a nonempty then empty layout inherited
  sizing/hash state. No new state/clock/ports/features added.
- New `vn_golden.py --compute-session ue_cpos_emptylayout_1 bufcopy_1
  --variant emptylayout`: creates unused empty layout after real layout;
  allocates empty set FIRST from exact-capacity pool, then real set. Stale
  sizing exhausts pool incorrectly. Included in regen and full vgtop runner;
  dev layout cohort selects it plus dslcompat and negative layoutmix.
  An assertion checks empty-layout sizing/hash before allocation; it is under
  translate_off and has not been formally proved.

## Evidence And Limits

- 19 short local harness tests pass in approximately 3.3s (fake
  tools/simulations, not RTL).
  Expanded `test_local_verilator.py` plus new `test_apu_dev.py` exercise
  runtime-file detection, check-only side effects, missing oracle, warm skip,
  no-auto-install blocker, invalid budgets, build/test timeouts and zero-check
  PASS rejection, failure-diagnostic precedence and missing explicit tools.
- `run-apu-dev.sh --immutable --check` and `--layout --check` pass on actual existing cache,
  with no installation/build/tests.
- 38 selected APU proxy/manifest/gate/compiler-closure tests pass with mocked
  workers in 6.39s; 23 model/tooling tests pass in 0.021s.
- Actual minimal compiler closure configures without git metadata: 365 files,
  21.30s, no compiler build, downloads or system install. This caught required
  root .in templates missing from the initial proposed closure.
- New emptylayout fixture generates: 6074 tape words, 301 expectation records,
  16 steps. Generation is not RTL execution.
- Pinned repository Verilator 5.008 lint/elaboration passes with assertions
  enabled and warnings fatal (existing targeted waivers retained).
- A broader 127-test proxy run has two cache-counter expectation mismatches
  and four fixtures missing `allow_overlap`, outside these APU changes.
  They were left untouched. This is not a claim that the full proxy suite is
  green.

Real local cold compiler and isolated simulator-PGO infrastructure checks have
since passed; remote cold setup/execution, the new RTL probe, full aggregate,
compliance/formal/synthesis/physical qualification and T2 backend remain open.
Previous immutable probe passes do not validate the new RTL correction.
Configured verify may require managed-tool patches; use dry-run for planning,
not as a PASS. Never invoke shared cleanup without approval.
Current configured dry-run plans 25 steps, executes none, and reports the
managed-simulator patch gap. The scoped 15-source header/tier/attribution audit,
shell syntax and source diff checks pass. Logs are under
`$HOME/.cache/librecore/apu/dev-harness-checks.log`.

## SoC And Licensing Review

The RTL delta only initializes existing metadata registers on every successful
layout-header path, including an empty layout. It adds no state, datapath cone,
array, SRAM port, clock, reset, ISA/CSR/DTS change or optional device feature.
It inherits the existing Venus enable/reset/scan/transaction boundaries.
Existing fault/reply/debug paths observe allocation outcomes; no new PMU event
is needed for this existing-contract correction. No frequency/area/power
improvement is claimed. The added property is an assertion, not a proof.

RISC-V spec/profile statuses remain unchanged. Relevant T tooling retains MIT;
the R frontend retains its existing dual license and contributor attribution.
Upstream compiler sources are copied unmodified with their license files;
they are build-time executable tools, not RTL link inputs. Scoped header/tier
audit and syntax/diff checks do not imply a signed-CLA or full licensing-tool
result. User's concurrent Storamic/core changes remain untouched.

Previous immutable state increment is documented in
`apu-immutable-implementation.md` and remains separate evidence.
