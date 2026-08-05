# architecture/sv-timing (pointer)

The **authoritative** design and package agent guides live inside the package:

- [`sv-timing/AGENTS.md`](../../sv-timing/AGENTS.md) — package guider
- [`sv-timing/AGENTS-todo.md`](../../sv-timing/AGENTS-todo.md) — live todo / state
- [`sv-timing/architecture/DESIGN.md`](../../sv-timing/architecture/DESIGN.md) — architecture design (rev 4+)
- [`sv-timing/architecture/OPTIMIZATION-LEVELS.md`](../../sv-timing/architecture/OPTIMIZATION-LEVELS.md) — `-O` levels + dials design delta
- [`sv-timing/architecture/PERF-CACHE.md`](../../sv-timing/architecture/PERF-CACHE.md) — throughput + pre-compiled cache design delta
- [`sv-timing/architecture/FO4-ALGORITHM-UPGRADES.md`](../../sv-timing/architecture/FO4-ALGORITHM-UPGRADES.md) — FO4 reduction algorithms
- [`sv-timing/architecture/MONOREPO-SOAK.md`](../../sv-timing/architecture/MONOREPO-SOAK.md) — sparse real-core FO4 soak

This directory is a **redirect only** so monorepo `architecture/` navigation still finds the topic.

**Host workspace lifecycle** (granular `clean` of timings outs, `--from-timing` soak/diag hand-off) lives outside the package:

- [`../build-platform-workspace-lifecycle.md`](../build-platform-workspace-lifecycle.md) (when present)
- Adapter code: `build-platform/src/tooling/timings.ts`, CLI `timings`

**Human docs:** `docs/website/pages/sv-timing/` and `docs/website/pages/build-platform/timings.mdx`.
