# g6lc_qemu — architecture index

Design documents for this package. They are **self-contained**: nothing here resolves outside
`g6lc_qemu/`. Where the package models a contract owned by a design project, the contract is named
in `../pins.toml` and its content is *ingested at runtime*, never transcribed into these documents.

| Doc | Role |
|---|---|
| [`DESIGN.md`](DESIGN.md) | End-to-end shape: the three inputs, four backends, two machine profiles, staging |
| [`INGEST.md`](INGEST.md) | Readers — config packages, flists, device trees, PMU event table |
| [`IR.md`](IR.md) | `TargetModel` JSON IR and the conformance report |
| [`EMIT.md`](EMIT.md) | Emitter contract for B0–B3, including the GPL-out rule |
| [`AI_BRIDGE.md`](AI_BRIDGE.md) | Accelerator scale-out, the pushed-work reach path, and the host bridge boundary |
| [`RTL_FEEDBACK.md`](RTL_FEEDBACK.md) | Findings that flow back into the design: open asks, what they unblock, the cluster-debug workflow, and the change-set aggregation policy |
| [`DIAG.md`](DIAG.md) | D1 tandem and D2 microarchitectural tiers, and their error bars |
| [`CLI.md`](CLI.md) | Complete command-line surface |

Governance and invariants live one level up in [`../AGENTS.md`](../AGENTS.md); the licensing boundary
in [`../AGENTS-licensing.md`](../AGENTS-licensing.md); the live queue in
[`../AGENTS-todo.md`](../AGENTS-todo.md).

**Design is law.** Change a document here (or open a delta in `../AGENTS-todo.md`) before making a
large structural change to the crates.
