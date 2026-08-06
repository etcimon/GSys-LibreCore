# Regress script isolation map

> **Role:** Answer *"which script, which plane (ISS vs RTL), which target, how tall is the stack?"* in one hop.  
> **Governance:** `AGENTS.md` §0.2 (verify in lockstep) · suite catalog `build-platform/src/config/defaults.ts` · status rows `AGENTS-specs-to-tests.md`.  
> **Battery entry:** `verif/regress/stability-regress.sh` (suite id `stability-regress`).

This file is the **isolation ladder** for residual multicore / H / stream / CAS work. Prefer the **narrowest green gate** that would have caught the bug class before climbing to full CRT or Linux.

---

## 1. Axes (how to classify a failure)

| Axis | Values | How to use |
|------|--------|------------|
| **Plane** | `artifact` · `spike` (ISS) · `veri` (Variane RTL) · `dual-iss` | Fail on Spike first → ISS/test bug or ISA setup (PMP, medeleg). Pass Spike / fail RTL → microarch. Fail both → test or env. |
| **Target / package** | `cv64a6_imafdc_sv39` · `g6lc64_server_math` / `cv64a6_server_math` · `*_ooo_server` · `*_smt2` · `*_spec_deep` | Match `DV_TARGET` to the feature under test (Zacas → imafdc or server_math with `RVZacas`; H → server_math with `RVH`). |
| **Stack height** | bare ELF · CRT bare-metal · OpenSBI · Linux | Climb only after the lower stack is green. CRT hang ≠ bare hang. |
| **Feature domain** | stream/CRT · spo/CF · Zacas · H/KVM · vector/Ara · SMT · FO4/timing | Use the domain row in §3; do not mix CAS soft-skip on Spike with hard RTL golden. |
| **Budget** | seconds (Spike directed) · minutes (Variane smoke) · hours (full soak / Linux) | Use `STABILITY_PROFILE` / env knobs; never soft-pass a hard golden. |

**Hard rule — Zacas:** Spike has **no** `zacas`. AMOCAS on ISS may soft-skip or be non-golden. Hard CAS golden is **`mc-mini-veri`** (Variane bare), not `mc-spo-spike`.

**Hard rule — H-edge:** VS entry needs guest-capable memory (open PMP TOR on Spike when PMP regions exist; tests swallow illegal PMP CSR if absent). See `verif/tests/custom/kvm_h/h_edge_diag.S`.

---

## 2. Isolation ladder (narrow → wide)

```
mc-spo-soak / mini compile     artifact only (assemble + optional lint)
        ↓
kvm-h-spike                    Spike H-edge (no Verilator)
mc-spo-spike                   Spike stream×spo/CF (CAS not hard golden)
        ↓
mc-mini-veri                   bare RTL hard CAS + I$ jumps (imafdc preferred)
run-h-edge-veri / kvm-h-tests  H-edge on Variane (server_math)
        ↓
mc-spo-veri                    full CRT stream×spo on Variane (DeepSpec / budget sensitive)
        ↓
server-math-tests / dual-hart  package-level directed
OpenSBI / Linux suites         software stack
```

**Composed battery (AGENTS-todo §4):** `stability-regress.sh`  
Default profile `spike` = `kvm-h-spike` + `mc-spo-spike` + mini **compile** gate.  
Profile `full` also runs mini + H-edge on an existing Variane harness when present.

---

## 3. Script catalog (bring-up / residual focus)

| Script | Suite id | Plane | Default target | Stack | Domain | Notes |
|--------|----------|-------|----------------|-------|--------|-------|
| `mc-spo-soak.sh` | `mc-spo-soak` | artifact (+ optional lint) | `cv64a6_ooo_server` | source | stream×spo | Assemble smoke; `MC_SPO_LINT=0` / `MC_SPO_ROUNDS` |
| `mc-spo-spike.sh` | `mc-spo-spike` | spike | `g6lc64_server_math` | CRT via cva6.py | stream×spo/CF/CAS list | `MC_SPO_SPIKE_TESTS`, `ISS_TIMEOUT`, `OUT_DIR=/tmp/...` |
| `mc-mini-veri.sh` | `mc-mini-veri` | veri | `cv64a6_imafdc_sv39` | bare | I$ + **hard AMOCAS** | `MC_MINI_VERI_REBUILD`, `MC_MINI_VERI_TESTS` |
| `mc-spo-veri.sh` | `mc-spo-veri` | veri | server_math | CRT | stream×spo full | `MC_SPO_VERI_FORCE_IMAFDC=1` smoke; `MC_SPO_VERI_REBUILD` |
| `mc-stream-tests.sh` | `mc-stream-tests` | mixed | ooo_server | directed | U6 stream plane | Broader stream catalog |
| `kvm-h-spike.sh` | `kvm-h-spike` | spike | `g6lc64_server_math` | CRT | H-edge | 3/3 Spike green; no Verilator |
| `kvm-h-tests.sh` | `kvm-h-tests` | veri+spike | `g6lc64_server_math` | CRT | H + Sstc | Optional full DV list |
| `monorepo-soak/run-h-edge-veri.sh` | (soak helper) | veri | existing `work-ver` | CRT | H-edge | Reuses server_math TB; not a defaults suite |
| `stability-regress.sh` | `stability-regress` | composed | see profile | see legs | residual battery | §4 entry point |
| `dual-hart-ci.sh` | `dual-hart-ci` | artifact/lint | smt2 | package | SMT | Path/lint gate |
| `server-math-tests.sh` | `server-math-tests` | veri+spike | server_math | directed | B/H/CMO/memcpy | Package C-light |
| `sv-timing-*.sh` | `sv-timing-*` | FO4 screen | sparse/core | n/a | timing | Not functional ISS; not STA |
| `smoke-tests-cv64a6_*.sh` | `smoke-cv64a6` | mixed | imafdc | compliance subset | baseline | Upstream-style smoke |
| `dv-riscv-*.sh` | `riscv-tests` / arch / compliance | mixed | imafdc | arch | ISA | Long CI |

Install helpers (`install-spike.sh`, `install-verilator.sh`, …) and `common-riscv-tools.sh` are **tooling**, not functional gates.

---

## 4. Env knobs (quick reference)

| Variable | Scripts | Meaning |
|----------|---------|---------|
| `DV_TARGET` | most | Package / cva6.py target |
| `ISS_TIMEOUT` | `mc-spo-spike` | cva6.py ISS timeout (Spike wall ≈ /10) |
| `MC_SPO_SPIKE_TESTS` | `mc-spo-spike` | Space-separated test name override |
| `MC_SPO_VERI_TESTS` / `FORCE_IMAFDC` / `REBUILD` | `mc-spo-veri` | CRT subset / single-core smoke / rebuild TB |
| `MC_MINI_VERI_TESTS` / `REBUILD` | `mc-mini-veri` | Bare mini subset / rebuild |
| `MC_SPO_LINT` / `MC_SPO_ROUNDS` | `mc-spo-soak` | Lint on/off; assemble rounds |
| `KVM_H_SPIKE_TESTS` / `KVM_H_SPIKE_STEPS` | `kvm-h-spike` | H-edge subset / Spike step bound |
| `STABILITY_PROFILE` | `stability-regress` | `artifact` \| `spike` (default) \| `full` |
| `STABILITY_SKIP_*` | `stability-regress` | Skip individual legs (`HEDGE`, `SPO_SPIKE`, `MINI`, `SOAK`) |
| `OUT_DIR` | spike paths | Prefer Linux `/tmp/...` on WSL+NTFS trees |

---

## 5. Failure triage cheat-sheet

| Symptom | First gate | Likely class |
|---------|------------|--------------|
| tohost never written / HTIF spin | Spike log + `tohost` parse (see `kvm-h-spike`) | test exit / managed Spike HTIF |
| IAF on first S/VS insn after `mret` | `h_edge_diag` / bare S-entry | **PMP** default deny S/U/VS |
| mcause ≠ 10 on VS ecall | `h_edge_diag` | not in VS (MPV) or wrong trap |
| AMOCAS “pass” on Spike only | — | **invalid golden**; run `mc-mini-veri` |
| CRT hang ≥40 B fill→verify | `mc-spo-veri` + STQ depth | DeepSpec / `DEPTH_COMMIT` (see §2 CRT notes) |
| DIDNOTCONVERGE dense CRT | I$ way-pred / preload | see `mc-spo-veri` header comments |
| Lint-only fail dual-hart | `dual-hart-ci` | package / flist, not runtime |

---

## 6. Maintenance

- **New residual suite:** add script under `verif/regress/`, register in `defaults.ts`, add a row here + `AGENTS-specs-to-tests.md`.
- **New directed test:** prefer extending an existing testlist (`testlist_mc_stream.yaml`, `testlist_kvm_h.yaml`) over a one-off soak script.
- **Do not** document foundry/NDA PDK paths here (`AGENTS-technology.md` / `pd/pdk/`).
