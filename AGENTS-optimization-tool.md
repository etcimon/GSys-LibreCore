# Optimization tool

This is how an RTL optimization is accepted or rejected. Each task is a folder. The assembly in that folder is what measures cycles. The area number is the structural area report for the same RTL snapshot. A later change in the folder is compared with the first change of the same configuration.

FO4 remains the timing screen. It is not the cycle count used here.

## Where the folders are

Ongoing decisions live here:

```text
optimization/tasks/<task-id>/
  task.json
  series.json          # omitted until a soak and an area report exist
  asm/<test>.S
```

`sv-timing/fixtures/opt-tasks/` is the same shape and is what `cargo test -p sv-timing-area` scores. Copy a fixture into `optimization/tasks/` when a real change starts. Do not treat the checked-in `example: true` series as a measured soak.

## What a task records

`task.json` names the decision and the assembly tests that are allowed to speak for it. Each test has:

- `id` — the name a soak writes into `series.json`
- `lane` — `cpu`, `graphics`, `ai`, or `coherence`
- `work` — payload operations inside the assembly, not the cycle count
- `configs` — the configuration knobs this test is about
- `asm` — path of the kernel relative to the task folder

The kernel stores its `mcycle` delta in the `mark_cycles` symbol. A passing run still has to check its own result. A stale coherence line is a failure, not a large cycle count.

`series.json` is the log of RTL snapshots, oldest first:

```json
{
  "example": false,
  "series": [
    {
      "change": "baseline",
      "config": { "coherence": "on", "cores": "2" },
      "area_au": 0,
      "modules": { "coherence": 0 },
      "tests": [
        { "id": "coherence_shared_line", "cycles": 1 },
        { "id": "cpu_ilp", "cycles": 1 }
      ]
    }
  ]
}
```

Replace the numbers with the soak and the area report. `area_au` is the design area from `sv-timing area` on that RTL tree. `modules` is the exclusive area of the modules the change touched. `cycles` is `mark_cycles` from the assembly soak of that same tree and configuration.

The first entry for a configuration is the baseline. Benefit of a later entry is `(baseline_cycles - cycles) / baseline_cycles`. Positive means fewer cycles. Area delta is the later area minus the baseline area.

## How to score

From `sv-timing/`:

```text
cargo run -p sv-timing-cli -- optimize --root ../optimization/tasks
cargo run -p sv-timing-cli -- optimize --task ../optimization/tasks/coherence-shared-line
```

`--json-out` writes the same decision under the current directory. `sv-timing area --opt-task <folder>` or `--opt-root <dir>` attaches that decision to an area report. Pass one of those, not both.

Record a snapshot after the area command and the assembly soak. `--module` names are read from that area report, including nested rows:

```text
cargo run -p sv-timing-cli -- optimize --record --task ../optimization/tasks/issue-width --change wider-issue --config issue=4 --area-report ../area-report.json --module alu --cycles-file ../mark-cycles.txt
```

The first recorded change for a configuration is the baseline. A later `--record` on the same configuration computes the benefit, the design area delta, and the exclusive-area delta of each named module. An `example: true` series is not modified unless `--replace-example` is also passed, which drops the illustration and starts the measured log.

`--cycles-file` reads a soak log. JSON with a `tests` array is accepted. A text log is one `test-id cycles` or `test-id=cycles` line per test, and `#` comments are ignored. `--cycles` overrides the file for the same id.

The printed decision for each change is one of:

| Decision | Meaning |
|---|---|
| `unmeasured` | No cycle count yet. The task stays open. |
| `same` | Cycles did not move against the baseline. |
| `faster_same_area` | Fewer cycles, area unchanged. |
| `faster_less_area` | Fewer cycles and less area. |
| `faster_more_area` | Fewer cycles and more area. This is the tradeoff to accept or reject. |
| `slower` | More cycles. |

A control test that should not move stays at benefit 0. In the coherence example, `coherence_shared_line` is the test that may improve, and `cpu_ilp` is the control.

## Coherence example

`optimization/tasks/coherence-shared-line/` asks whether a snoop-filter change is worth its area. Its series is a measured structural-area baseline of the coherence sources, with no assembly cycles yet, so the score stays `unmeasured`. The arithmetic illustration, including the 0.4 cycle benefit, remains in `sv-timing/fixtures/opt-tasks/coherence-shared-line/` and is marked `example: true`.

The baseline area is 904 under `area-v1`. Exclusive area is hub 260, invalidation bus 16, L1 adapter 68, LR/SC tracker 560. The snoop filter reports 0 because its storage type did not resolve. A function used to be billed at the product of every range in its body; `line_base` was 64×56×64. The return width is now only the ranges before the function name, so the adapter's shift is 64 bits.

- `asm/coherence_shared_line.S` is two harts and one cacheable line. Hart 0 times the path from seeing the first value through seeing the value written by the other hart. Work is 2 observations. Configurations: `coherence`, `l2`, `cores`.
- `asm/cpu_ilp.S` is 64 dependent-free adds. It is there so an unrelated issue-path change is not credited to the coherence edit.
- The checked-in series is an example: the coherence test falls from 2000 cycles to 1200 (benefit 0.4) while `cpu_ilp` stays at 400, and structural area rises by 120. The decision is `faster_more_area`. Replace those numbers before using the folder as evidence.

`optimization/tasks/issue-width/` is an open task. It has the cpu assembly and no series, so a score says `unmeasured`.

## Area

Area in a task is the structural area report for that RTL snapshot, under `resources/area-v1.toml`. The same weights on two snapshots make the area delta the silicon change the model can see: storage bits, operators, and the modules named in the series. Absolute foundry cell counts wait until a mapped netlist retunes that table. Do not turn a placeholder area product into a pass/fail golden.

Parameterized instances are still counted once until the parameters are specialized, so a replicated block can be smaller in the report than on silicon. The `instance_params=unrecorded` tag is that gap. Record the module you actually edited in `modules` so the decision still shows its exclusive area.

## What this is not

These marks are not commercial CPU, graphics, or AI benchmark scores. They are not FO4. A folder records one decision at a time so an RTL edit can be kept, revised, or dropped from the numbers in that folder.
