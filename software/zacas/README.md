# Zacas (AMOCAS) residual policy

Hardware: config-gated **AMOCAS.W/D** via `CVA6Cfg.RVZacas` (requires `RVA`).
**AMOCAS.Q is deferred** (AGENTS-todo §8) — not a near-term residual bug to soft-pass.

| Width | Status | Notes |
|-------|--------|-------|
| AMOCAS.W | **Implemented** | Decoder `AMO_CASW`; third GPR expected; `amo_alu` / HPDCache / AXI CAS pack |
| AMOCAS.D | **Implemented** | Local RMW FSM in HPDCache adapter (`CASD_*`); WT missunit path |
| AMOCAS.Q | **Deferred / illegal** | Decoder: non-W/D width → `illegal_instr`; no 128b datapath |

## Golden rules

1. **Hard CAS golden is RTL only** — suite `mc-mini-veri` (`mini_amocas_{w,d}.S`).
2. **Spike has no zacas** — never treat Spike soft-skip / pass as AMOCAS correctness.
3. **Dual-ISS is not CAS golden** — see `verif/regress/AGENTS-regress-scripts.md`.
4. **AMOCAS.Q** must **illegal-trap** (`mini_amocas_q_illegal.S`); do not implement silently.

## Gates

| Suite / script | Role |
|----------------|------|
| `mc-mini-veri` | Hard W/D on Variane (prefer `cv64a6_imafdc_sv39` or any `RVZacas=1` TB) |
| `zacas-policy` | Contract + Q illegal + optional mini W/D smoke |
| `mc-spo-spike` | Stream soak; **not** Zacas golden |

## Spec anchors

- `agents/spec/riscv-spec-I-5.9-zacas.html` · `#ext:zacas`
- Impl: `AGENTS-specs-to-impl.md` (Zacas row)
- Tests: `AGENTS-specs-to-tests.md` (mc-mini-veri / mc-stream)

## Why Q is deferred

AMOCAS.Q needs a 128-bit atomic RMW (even register pairs for expected/new on RV64),
extra RF ports or multi-beat memory, and backend (HPDCache/AXI) support for 16-byte
atomic compare. That is a full feature program, not residual polish. Ship W/D hard
green; keep Q illegal until a dedicated design pass.
