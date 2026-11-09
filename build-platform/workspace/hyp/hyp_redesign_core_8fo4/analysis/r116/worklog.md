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
