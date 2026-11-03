# Verification and promotion

Foundation is not device qualification. All results name the source/configuration,
fixtures, tool versions/binary hashes, seed, stage and oracle. Preserve unrelated
worktree changes and record the exact snapshot instead of assuming HEAD identity.

## Earliest faithful checks

1. Config legality and first-party source/include/package/instance closure.
2. AXI refusal protocol: independent AW/W, IDs, complete bursts, backpressure,
   response stability, reset and inactive physical outputs.
3. Executable SRAM model: regions, narrow writes, boundary splitting, ordering.
4. Passive media identification, timing and error models.
5. Native CPU/AI/APU ownership, atomics, fairness and default-off identity.
6. VirtIO-MMIO register/ring/DMA and block-model protocol, including malformed
   descriptors and reset/ordering.
7. Stock Linux block/PMEM discovery, durable operations and fault handling.
8. Active links and applicable physical qualification.

Keep independent negative/mutant controls. A test never observed to fail may not
distinguish the mechanism it claims to protect. Check 1/2/3/4/8 sticks, mixed sizes,
empty/unknown slots, overflow/overlap, invalid profiles, conflicting backends,
unsupported capability requests and removal without silent remapping.

## Remote testharness

Use the existing remote testharness gateway with isolated source manifests and
selected generated inputs. Build caches depend on source, configuration and tool
identity, including modified Verilator binaries. Run detached with bounded
resources and collect/resume instead of launching duplicate jobs.

Return pass/fail/incomplete distinctly. Missing summaries, timeouts and identity
mismatches cannot become success. Selected-stage leaf evidence is not a strict
whole-system qualification. Use remote lint/elaboration, directed simulation,
bounded properties and synthesis smoke; a PHY black box is not physical proof.

## g6lc_qemu only

Keep its project-independent input/IR/emitter model, fixtures-only checks and GPL
text-output boundary. Consume published configuration/flists; absent constants go
to `g6lc_qemu/architecture/RTL_FEEDBACK.md`, never fabricated defaults.

First establish a labeled stock-QEMU/Linux reference profile through g6lc_qemu.
Later emit an RTL-in-the-loop bridge there. Actual tested MMIO/configuration,
mailbox, DMA, IRQ and memory transactions must reach RTL at the declared cut.
Do not map the tested memory aperture to ordinary QEMU RAM and call that controller
validation. Such shortcuts are explicitly software-only.

QEMU is not a CPU-cache coherence or physical-link timing oracle. Separate native
RISC-V tests from an external-host reference, whose transport is unselected. All QEMU launching and
remote orchestration remains in g6lc_qemu; the simulator-side peer may live in verif.

## Timing and readiness

M0 has bounded frontend state, independent registered responses and no media
arrays/CDC/high-speed PHY. Later arrays use SRAM macro seams; clock/reset crossings
are explicit, with asynchronous assertion and synchronized deassertion. Preserve
testmode/scan observability. No 5 GHz, DDR4-bandwidth, VirtIO-compliance or physical
power/area claim follows from skeleton lint or structural timing.

## Executable foundation suite

Build-platform registers the optional `storamic-remote-leaf` suite outside its
default suites. Its wrapper delegates to the existing testharness `py` gateway.
The leaf accepts `--stages protocol,config,integration,synth,formal` (or a subset).
It uses one compiler job, unique isolated snapshots and selected-stage identity;
it does not implement a second SSH transport or a QEMU launcher.

Direct equivalent from the repository root:

```text
python3 verif/tb/storamic/run_remote.py --stages protocol,integration,synth,formal
```

On this Windows host, native Python lacks rsync; the existing WSL environment
passes gateway preflight and can execute the same command with
`wsl --cd /mnt/e/cva6 python3 ...`. No new tool installation was needed.

The standalone compilation uses exactly `Flist.storamic` and first-party test
fixtures. Native adapter tests additionally supply the inherited external AXI
interface/package and headers, outside the standalone implementation boundary.
The configuration sweep retains old-target failures instead of converting them
to success. The formal proof is bounded to depth 12 and covers response stability
and error responses, not full AXI compliance, liveness or media correctness.
