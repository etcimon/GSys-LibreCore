# CPU50 — CPU/debug-origin qualification result

Scope: verification-only closure of the remaining C1 CPU/debug-origin items.
No production RTL under `core/`, `corev_apu/`, or `g6lc_storamic/rtl/` was
modified. All qualification evidence is from isolated remote snapshots run
through `run_remote.py` with the owned Verilator runtime
(`storamic-tools35-8e064f51`, runtime header sha256
`e900ec451629715860e4faffdce5127f5f118ddcaa433125b79f12d3cbb718f8`).

Local Python suite: **165 tests, all OK** (`python -m unittest discover`,
`verif/tb/storamic`).

## Combined qualification run — `storamic-b74425a4c1bc`

One frozen snapshot ran all 11 requested stages. `run_remote.py` exited **0**:
the remote `py` finished `rc=0`, the auto-pull completed (`pull rc=0`), and the
runner's post-run source/stage identity check passed before it printed
`Storamic selected stages passed` → `leaf-result.json`. `leaf-result.json`:
`status: pass`, `error: none`; `stage-results.json`: **266 per-case records,
all `pass: true`**; `run_leaf.log` ends `STORAMIC_REMOTE_SELECTED_STAGES_PASS`.
Launched with `--timeout 6000` (the prior 2400 s default was too short for this
11-stage selection on a loaded host).

| Stage | Records (pass) | Notes |
|---|---|---|
| cpu-debug-trigger | 38 | Sdtrig=0 deny + mech3/4/5 |
| cpu-debug-queue | 52 | HoldStage 1-5 incl. s4/s5 load AR/R |
| cpu-debug-return | 36 | held-B across DRET |
| cpu-debug | 112 | 48 cases + stq-mutant + builds |
| cpu-debug-stq-mutant | (in cpu-debug) | 8/8 `commit_and_flush` reject |
| cpu-origin | 18 | enabled0/1 |
| cpu-origin-atomic | 6 | AMO/LR/SC |
| cpu-origin-unsupported | 4 | RVH=1 zeroing |
| origin-profile | 3 | + negatives |
| origin-queue | 2 | + negative |
| stq-commit-flush | 5 | pos/neg/prefix/mutants |

`cpu-debug` origin-0 (`o0`) verdicts are **byte-identical** to the prior
qualification `storamic-cc977ef86fa1` (same cycles/counts on all 18 markers), so
earlier origin-0 evidence stands: moving `OriginEnabled` forwarding from a
remote patch into committed interpreter source did not change behaviour.

Non-qualifying / corroborating history:
- `storamic-b8efef926eaf` — same 11 stages, remote `leaf-result.json`
  `status: pass` with 266/266 records, but the harness **2400 s watchdog fired
  at the completion boundary**, so `run_remote.py` printed
  `Incomplete: no leaf-result.json` on a pull race and its post-run identity
  verification never executed. Per project rule a runner-"Incomplete" run is
  not closure evidence; retained as **corroborating** only. The fix was a
  `--timeout SECONDS` option on `run_remote.py` (default 2400 unchanged).
- `storamic-2c3f96bae2c8` (`cpu-debug-return` origin0 verdict abort) and
  `storamic-601cd89e9a1e` (`CPU_DEBUG_INTERPRETER_PATCH_INVENTORY` — the
  committed interpreter already forwarded `OriginEnabled`, so the runner's
  remote patch found no `INTERP_OLD` match; the patch was then removed) —
  aborted before all stages ran.

## Per-item results

- **cpu-debug-trigger** (`storamic-8d679ba79ca3`, 19/19): Sdtrig=0 deny pair
  (`csrr tselect` → mcause 2) + mechanism-3 execute + store/load address
  triggers; "after" timing (`DPC=T+4` exec, `access_pc+4` store/load),
  `dcsr.cause=3`. Two upstream Sdtrig deviations logged (not C1-blocking,
  SDTRIG=0): mcontrol6 records `CauseRequest`/post-trigger DPC; the store/load
  `debug_from_mcontrol_o` pulse is not commit-qualified (bench pads 64 NOPs).
- **cpu-debug-queue HoldStage 1-5** (`storamic-b108f5361c8b`, 26/26): stage 4
  holds the dedicated firmware-load AR (`Probe+48`, never debugger-read)
  unaccepted and stage 5 accepts it with R held across entry; load carries
  firmware origin, debugger accesses `000`, firmware completes after `DRET`.
  Three testbench/runner bugs fixed — no RTL defect.
- **cpu-debug-return**: M/S/U × origin × delay + Negative, HoldStage=3 held-B.
  Read-return reasoning: a debug-issued read cannot pend across `DRET` —
  `load_unit.sv:762-765` raises `valid_o` only on a non-flushed `ldbuf` R and
  `load_unit.sv:241-251` marks flushed entries so they never produce a result.
- **cpu-origin-atomic** (`storamic-85eafabb8b42`, 6/6): real-core AMO/LR/SC —
  AMO `AW(atop=RMW,id-bit1,prot=000)`+`W` old value on R+B; LR `AR(lock=1)`→R;
  SC `AW(lock=1)`+`W`→`B.EXOKAY`; no external adapter. Atomic `prot==000`,
  ordinary keep M(001)/U(010); `+expect_atomic_origin` rejects; origin-off
  all-`000`. Earlier post-`mret` stall was a missing firmware prologue
  (CSR/`pmpcfg`/`mtvec` → trap loop), not RTL.
- **cpu-origin-unsupported + origin-profile + origin-queue**
  (`storamic-3d48a7b778aa`, 17/17): `UnsupportedProfile` variant (RVH=1 +
  Storamic flags, fixture assert relaxed only for the variant, recorded in
  manifest) completes identically with every data `prot==000`;
  `+expect_supported` rejects `aw-prot`.

## Testbench/runner bugs fixed (no RTL changes)

1. `tb_..._cpu_debug_queue_interpreter.sv`: generic first-write-accept
   `debug_req` fired for all stages, entering debug on `store(0)` before the
   dedicated load could issue its AR — squashing it so the HoldStage 4/5
   trigger never fired. Scoped to write-hold stages (`HoldStage <= 3`).
2. `tb_..._{cpu_debug,cpu_debug_return,cpu_debug_queue}_interpreter.sv`:
   `g6lc_storamic_cpu_debug_netlist` was instantiated without forwarding
   `OriginEnabled`, so the core always tagged origins while the oracle expected
   `000` for origin0. Forwarded the parameter in committed source; the
   `run_cpu_debug.py` remote patch (`INTERP_OLD→INTERP_NEW`) and its
   `interpreter_patched_sha256` manifest field were removed as obsolete.
3. `run_cpu_debug_queue.py`: negative/mutant verdicts compared FAIL regex
   `group(6)` (`cycles`) to `"debug-origin-failed"` instead of `group(5)`
   (`reason`). Fixed.

## Yosys evidence-flow note (dormant path)

The committed interpreters now bind `g6lc_storamic_cpu_debug_netlist
#(.OriginEnabled(OriginEnabled))`. The active Verilator flow compiles the
netlist from source, so this is required and correct. The **legacy Yosys
receipt flow** (`model.ys`/`execution.ys` + `g6lc_collect_cpu_debug_*.py`)
parameterizes the netlist separately and writes a **parameterless** `cpu.il`
(`OriginEnabled` constant-folded; verified 0 occurrences across
`storamic-cpu-debug-{15,queue-17,return-18}` `cpu.il`). If that dormant flow is
ever regenerated, `hierarchy -check` would reject the `#(.OriginEnabled(...))`
binding ("parameter not found"); existing receipts and collectors are unaffected
(they validate frozen artifacts, and there is no active repo generator). To
revive it, `model.ys` must preserve `OriginEnabled` as a parameter in `cpu.il`,
or the interpreter binding be dropped for that flow.

## Out-of-profile / omitted

- SDTRIG=1 trigger entry, `NrHarts>1`, OoO, virtualization/SMT debug paths,
  `tdata` triggers, other debug mechanisms/privilege corners: refused by
  `g6lc_storamic_origin_supported`; not C1 rows, require requalification before
  the predicate widens.
- The mcontrol6 cause-3/after-timing and non-commit-qualified store/load pulse
  are upstream Sdtrig deviations, logged separately; SDTRIG=0 in the qualified
  profile.
