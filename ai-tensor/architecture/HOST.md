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

Suggested monorepo command shape (future):

```text
cva6-build tensor setup | doctor | test | probe
```

Mirror of `cva6-build timings` → `sv-timing`.

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
bash monorepo-soak/run-ai-tensor.sh test    # independence + cargo + golden-check
bash monorepo-soak/run-ai-tensor.sh golden
AI_TENSOR_DIR=/path/to/ai-tensor bash monorepo-soak/run-ai-tensor.sh check
```

Still never add monorepo paths to package `Cargo.toml`.

