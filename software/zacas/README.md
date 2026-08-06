# Zacas (AMOCAS) residual policy

Hardware: config-gated **AMOCAS.W/D/Q** via `CVA6Cfg.RVZacas` (requires `RVA`).
**AMOCAS.Q** microarchitecture: `architecture/zacas-amocas-q.md` (register-pair + multi-beat RMW).

| Width | Status | Notes |
|-------|--------|-------|
| AMOCAS.W | **Implemented** | Decoder `AMO_CASW`; third GPR expected; pack/ALU / AXI CAS |
| AMOCAS.D | **Implemented** | Local UC RMW FSM (`CASD_*` / WT `AMO_CAS_*`) |
| AMOCAS.Q | **Implemented** | Decode + pair RF gather + 128b multi-beat RMW + dual WB; odd-reg illegal |

## Golden rules

1. **Hard CAS golden is RTL only** — `mc-mini-veri` + `zacas-policy` (`mini_amocas_{w,d,q}.S`).
2. **Spike has no zacas** — never treat Spike soft-skip / pass as AMOCAS correctness.
3. **Dual-ISS is not CAS golden**.
4. **AMOCAS.Q** requires even `rd`/`rs2` and 16-byte alignment; odd pair base remains illegal.

## Gates

| Suite / script | Role |
|----------------|------|
| `mc-mini-veri` | Hard W/D on Variane |
| `zacas-policy` | Contract + Q illegal-odd + W/D/Q mini smoke |
| `mc-spo-spike` | Stream soak; **not** Zacas golden |

## Spec anchors

- `agents/spec/riscv-spec-I-5.9-zacas.html` · `#ext:zacas`
- Plan: `architecture/zacas-amocas-q.md`
