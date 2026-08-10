# Host integration (optional)

**Principle (same as `sv-timing`):** the monorepo may **spawn and discover** `ai-tensor`; it must not
become a Cargo dependency of this package.

---

## 1. Host responsibilities

| Host (e.g. LibreCore `build-platform`) | Package |
|---|---|
| Locate `ai-tensor/` next to `sv-timing/` | Independent root |
| Run `python tools/ait.py setup\|test\|doctor` | Owns tooling |
| Pass profile / MMIO base from DTS or board json | Interprets profile |
| Run directed ELFs (`ai-matrix-veri`) as HW soak | Does not require those ELFs to unit-test |
| Never `path = "../core"` in package `Cargo.toml` | Enforced by check-independence |

Monorepo command (landed):

```text
cva6-build tensor status | doctor | test | golden | cosim | check
```

Mirror of `cva6-build timings` → `sv-timing`. Implementation:
`build-platform/src/tooling/tensor.ts` + `cli/commands/tensor.ts` (spawn only).

---

## 2. Data exchanged

| Artifact | Direction | Format |
|---|---|---|
| Profile id / pins | host → package | env or CLI |
| Caps / probe JSON | package → host | `schemas/probe.v1.json` (later) |
| Job metrics | package → host | optional JSON |
| isa-encoding path | host → gen tool | optional sync only |

---

## 3. What stays out of the host

- Framework wheel build matrices (torch/tf versions) — package or separate CI.
- Island RTL edits — monorepo agents under `AGENTS.md` §0.
- Inventing opcodes in host TypeScript.

---

## 4. Documentation links

- Package entry: [`../AGENTS.md`](../AGENTS.md)
- Monorepo AI scaffold: [`../../architecture/ai-matrix/README.md`](../../architecture/ai-matrix/README.md)
- Island README: [`../../corev_apu/ai_island/README.md`](../../corev_apu/ai_island/README.md)
- sv-timing host precedent: [`../../sv-timing/AGENTS-host.md`](../../sv-timing/AGENTS-host.md)

## 5. Concrete monorepo spawn

```bash
# from monorepo root
bash monorepo-soak/run-ai-tensor.sh test    # independence + cargo + golden-check (+ harness)
bash monorepo-soak/run-ai-tensor.sh golden
bash monorepo-soak/run-ai-tensor.sh cosim   # harness suite + CLI external checks
AI_TENSOR_DIR=/path/to/ai-tensor bash monorepo-soak/run-ai-tensor.sh check
```

Still never add monorepo paths to package `Cargo.toml`.

## 6. Cosim bridge (package-owned)

| Layer | Who | How |
|---|---|---|
| Offline dual oracle | package CI | `run_builtin_suite` sim + SoftIsland |
| External adapter | package `tools/cosim_harness.py` | `AI_TENSOR_COSIM_CMD` |
| Monorepo spawn | `monorepo-soak/run-ai-tensor.sh` | sets env; never path-deps crates |
| Host CLI | `cva6-build tensor …` | discovers package; spawns soak script |
| Live RTL TB | lab only | `AI_TENSOR_RUN_RTL=1` + `AI_TENSOR_RTL_CMD=…` |

Default harness path used by spawn / `ait.py test|cosim`:

```bash
export AI_TENSOR_COSIM_CMD="python3 tools/cosim_harness.py"
```

## 7. Multi-tile desc stream (production RT)

Large GEMMs use **one queue, sequential tickets**, zero-copy A/B via `lda`/`ldb`:

| API | Role |
|---|---|
| `Queue` | `qid` + ticket allocator |
| `plan_gemm_s8_stream` / `run_gemm_s8_stream` | full A/B once; scratch C tile; accumulate |
| `run_gemm_s8_auto` | delegates to stream path |
| CLI `stream-gemm` | sim or SoftIsland backend |

Framework ops should call the stream path rather than re-gathering tiles on the host.

