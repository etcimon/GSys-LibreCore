# Stream8-class production package (scaffold)

**Status:** **promoted + live RTL green** — package on `Flist.cva6` via `TARGET_CFG=g6lc64_stream8`; Variane `work-ver-stream8` on Linux Verilator **5.008**: mini AMOCAS.W/D/Q + stream plane SUCCESS; lint via `linux-eda-suite` overlay.
**Queue:** `AGENTS-todo.md` practical next optional growth · residual CRT + H-edge **already green**.  
**Contract:** `architecture/README.md` (scaffold; promote via §0.2 + config-first).

## Intent

A single **production-class** CVA6V-EC / G6LC package that freezes the residual bring-up plane into
one named SoC envelope:

| Axis | Target envelope (proposal) | Priors / live base |
|------|----------------------------|--------------------|
| Issue width | **n-wide** (start **2**, option **4**) | `g6lc64_ooo{,_server}` · `architecture/out-of-order/` |
| Cluster | **y-core** (start **2**, scale **≤8**) | `NrCores` · `g6lc_cluster` · `architecture/multi-core/` |
| SMT | **NrHarts ≤ 2** per core (optional) | `g6lc64_smt2` · `architecture/multi-threading/` |
| Memory | Shared **L2 + L3** + stream PF | `architecture/l2-l3-cache/` · server_math / ooo_server |
| ISA residual | **IMAFDC + H + Zacas (W/D/Q)** + optional **V/Ara** | server_math{,_v} · `zacas-policy` · `ara-vector-*` |
| FO4 screen | Structural **@ x GHz** (host `sv-timing`; not STA) | `AGENTS-build-platform.md` §6.1 · `fo4-v1.toml` |
| STA | Lab only — never retune FO4 from fixtures | `s9-lab-gate` · OpenSTA plan |

Name **stream8** = “stream-plane multicore CRT class” + max cluster **8**, not a hard-wired 8-issue core.

## Why now

Residual host gates that blocked package freeze are **landed**:

- Multicore RTL CRT: imafdc **9/9** + `g6lc64_server_math` L2 **9/9** (`mc-spo-veri`)
- H-edge Spike+RTL **3/3** (`kvm-h-spike` / Variane)
- Zacas **W/D/Q** hard green (`zacas-policy`)
- Dual-hart host residual (`dual-hart-ci`; live smt2 Variane still lab when native Verilator)

Stream8 is therefore **optional growth**, not a bugfix: pick numbers, add a config package + DTS,
and keep minimal packages identity-clean.

## Proposed package surface (when promoted)

Promotion artifacts (landed this pass):

| Artifact | Role |
|----------|------|
| `core/include/g6lc64_stream8_config_pkg.sv` | **landed** — N=2, Zacas, DeepSpec, L2, H; C-light in-order (server_math freeze) |
| `corev_apu/bootrom/ariane-stream8.dts` | **landed** — dual physical cores + L2 + zacas ISA |
| `verif/tests/testlist_stream8.yaml` | **landed** — stream + AMOCAS.W/D/Q + h_edge_diag |
| `verif/regress/stream8-smoke.sh` | **landed** — contract + mini compile + soft lint |
| `build-platform` suite `stream8-smoke` | **landed** — `optional: true` (not `defaultSuites`) |

Config knobs stay in `config_pkg::cva6_cfg_t` + `check_cfg` — no hard-coded stream8 inside pipeline stages.

### Suggested starting numbers (review before RTL)

| Knob | Start | Notes |
|------|-------|-------|
| `NrCores` | 2 | CRT proven; scale to 4/8 only after N=2 smoke |
| Issue width | 2 (`g6lc64_ooo` lite) or in-order server_math | 4-issue only if FO4 screen + formal stay green |
| `NrHarts` | 1 bare-metal CRT; 2 only on smt2 track | Dual-park software gate exists; full smt2 Variane lab |
| `RVZacas` | 1 | W/D/Q; Spike never CAS golden |
| `DeepSpecEn` | 1 | STQ deepen required for stream fill→verify |
| Target FO4 screen | 2.5 GHz structural | STA retune separate (S3b-lab) |

## Acceptance (promotion checklist)

1. **Config-gated** package elaborates; minimal configs unchanged.  
2. **Lint** `verify --lint --target g6lc64_stream8` with host-native Verilator.  
3. **Mini golden** AMOCAS.W/D/Q + stream plane subset hard PASS (no soft-skip CAS).  
4. **H-edge** smoke still green on the package (or documented ISA strip).  
5. **`.dts` ↔ config ↔ spec** row in `AGENTS-dts-validation.md`.  
6. **Timing note** + FO4 screen; no `fo4-v1` edit from fixture STA.  
7. **Licensing** + coding-philosophy on every new `.sv` (tier R/T per policy).  
8. Update `AGENTS-specs-to-{impl,tests,coverage}.md` only for ISA-visible / suite deltas.

## Explicit non-goals (this scaffold)

- No rebrand / publication branch merge here.  
- No default-on stream8 in CI `defaultSuites`.  
- No Linux Image / R3b hard gate (remains external).  
- No OpenROAD LEF or real-STA FO4 table edit without lab tools.

## Open first

| Layer | Path |
|-------|------|
| Multi-core | `architecture/multi-core/README.md` |
| OoO packages | `architecture/out-of-order/README.md` |
| L2/L3 | `architecture/l2-l3-cache/README.md` |
| Program | `architecture/router-core-upgrade-program.md` · `remaining-upgrade-sequence.md` |
| SoC numbers | `AGENTS-configuration.md` |
| Host residual | `AGENTS-build-platform.md` §4–§7 · `AGENTS-todo.md` |
