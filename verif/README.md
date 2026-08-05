# CVA6: Verification Environment for the CVA6 CORE-V processor core

- [Directories](#directories)
- [Prerequisites](#prerequisites)
- [Test execution](#test-execution)
- [Verification plan](#verification-plan)
- [Environment variables](#environment-variables)
- [32-bit configuration](#32-bit-configuration)

## Directories:
- **bsp**:   board support package for test-programs compiled/assembled/linked for the CVA6.
This BSP is used by both `core` testbench and `uvmt_cva6` UVM verification environment.
- **regress**: scripts to install tools, test suites, CVA6 code and to execute tests
- **sim**:   simulation environment (e.g. riscv-dv)
- **tb**:    testbench module instancing the core
- **tests**: source of test cases and test lists

There are README files in each directory with additional information.

## Build platform (recommended single entry point)

All of these regression suites are catalogued and orchestrated by the **build platform**
(`../build-platform/`, run `bun` from `build-platform/`) — the recommended single entry point. It provisions the
open-source toolchain, discovers every `verif/regress` suite, and runs them uniformly across
Windows / Linux / macOS:

```sh
cd build-platform
bun run src/cli/index.ts test --list            # list every discovered suite + runnable status
bun run src/cli/index.ts test riscv-arch-test   # run one suite
bun run src/cli/index.ts test --group arch      # run a whole family
bun run src/cli/index.ts test --open-source     # run everything runnable on the open-source toolchain
```

The raw `verif/regress/*.sh` scripts and the `DV_*` environment variables below remain fully supported
for direct and CI use; the build platform simply wraps them with dependency preflight and a single
configuration surface. The spec ⇄ test mapping for these suites is maintained in
`../AGENTS-specs-to-tests.md`.

## Verification plan
Verification plan is available only for vcs tool and located in sim/cva6.hvp, it's used within a modifier to filter out only needed features. Example sim/modifier_embedded.hvp for embedded config.

To generate the coverage database user should run at least a test or regression with coverage enabled by setting:
- `export cov=1`

To view or edit verification plan use command:
- `cd sim`
- `verdi -cov -covdir vcs_results/default/vcs.d/simv.vdb -plan cva6.hvp -mod modifier_embedded.hvp`

To generate verification plan report in html format use command:
- `cd sim`
- `urg -hvp_proj cva6_embedded -group instcov_for_score -hvp_attributes description -dir vcs_results/default/vcs.d/simv.vdb -plan cva6.hvp -mod modifier_embedded.hvp`

## Environment variables
Other environment variables can be set to overload default values
provided in the different scripts.

The default values are:

- `DV_TARGET`: `cv64a6_imafdc_sv39`
- `DV_SIMULATORS`: `veri-testharness,spike`
- `DV_TESTLISTS`: `../tests/testlist_riscv-tests-$DV_TARGET-p.yaml
../tests/testlist_riscv-tests-$DV_TARGET-v.yaml`
- `DV_OPTS`: no default value
