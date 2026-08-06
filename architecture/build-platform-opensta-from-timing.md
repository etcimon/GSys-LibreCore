# From-timing packages → OpenROAD / OpenSTA validation loop

| Field | Value |
|---|---|
| **Status** | Host offline path complete (S0–S3a fixture + S4a scaffold); lab S3b/S4b open |
| **Owner** | `build-platform/` host adapter + optional `pd/` scripts |
| **Package boundary** | `sv-timing/` stays monorepo-independent (`AGENTS-host.md`, `STA-HANDOFF.md`) |
| **Related** | `architecture/build-platform-workspace-lifecycle.md`, `sv-timing/architecture/STA-HANDOFF.md`, `AGENTS-build-platform.md` §7, `AGENTS-technology.md` |

---

## 1. Goal

Use **precompiled** timings packages (`--output` / `--from-timing`) as the **input contract** for an optional **open-source PD smoke path**:

1. Validate that host packages are complete enough for PD entry (structure + SDC seeds).
2. Optionally **synthesize** a sparse surface (Yosys / yosys-slang) from `portable.f` or emit `svt_corrected.f`.
3. Optionally run **OpenSTA** (and later OpenROAD) when liberty + tools are present.
4. **Correlate** structural FO4 ranking vs STA path reports to **trust-calibrate** and **fix** sv-timing (cost tables, path extraction bugs, false criticals) — **without** claiming FO4 is sign-off.

**Hard rule (unchanged):** structural FO4 is **not** STA. STA WNS/TNS remain authoritative for silicon. FO4 drives *screening* and *fix prioritization*.

---

## 2. Why this closes the loop

| Gap today | How this plan closes it |
|-----------|-------------------------|
| `timings summary` is FO4-only | STA correlation report ranks agreement / disagreement |
| Corrected emit not exercised by PD | Opt-in synth+STA on `corrected/` after human review |
| OpenROAD detect-only | Phased smoke: SDC → synth → OpenSTA → OpenROAD (each soft-skip if missing) |
| FO4 model untrusted for CI gates | Golden FO4 fixtures + optional STA rank correlation (informational CI) |
| Package independence | All PD knowledge stays in **host** (`tooling/staHandoff.ts`, scripts under workspace) |

---

## 3. Architectural bounds

| Bound | Rule |
|-------|------|
| **sv-timing independence** | No OpenROAD/OpenSTA crates under `sv-timing/`. Host reads `analyze.json` / `sta_hints` only. |
| **No auto sign-off SDC** | Generated `.sdc` is **review-only** comments + `create_clock` seed; never auto `set_max_delay` from FO4 (`STA-HANDOFF.md` §6). |
| **No auto-merge correct emit** | STA on emit requires `--use-emit` + existing `corrected/`; never writes into `core/`. |
| **PDK omitted under NDA** | Liberty/LEF for real nodes live under gitignored `pd/pdk/`; open-PDK (sky130) is optional study path. |
| **Soft-skip by default** | Missing `opensta` / liberty / OpenROAD → skip stage, exit 0 with report (CI green without PD tools). |
| **Config-gated** | `physicalDesign.flow`, liberty path, enable flag in `.config.ts` — defaults off. |

---

## 4. Input package contract (`--from-timing`)

Minimum for **S0** (SDC seeds + dashboard):

| Artifact | Role |
|----------|------|
| `portable.f` | Source list for optional synth |
| `analyze.json` or `correct.json` | Paths, `frequency_closure`, `sta_hints[]` |
| `stamp.json` | Host provenance |
| `soak-dashboard.json` | Optional FO4 summary (T3b) |

For **S1+** synth/STA:

| Artifact | Role |
|----------|------|
| `param-map.json` | Width assumptions for packages mode |
| `corrected/` + `svt_corrected.f` | Only with `--use-emit` after review |
| Liberty `.lib` | OpenSTA delay model (host-supplied or open-PDK) |
| Optional LEF/tech | OpenROAD only |

---

## 5. Phased delivery

### Phase S0 — SDC seed + correlation scaffold — **done**

```text
from-timing DIR
  → parse analyze.json
  → emit workspace/.../sta-handoff/<tag>/
       seeds.sdc          # create_clock + commented report_timing seeds
       fo4_paths.csv      # path_id,total_fo4,slack,start,end,kind
       handoff-manifest.json
       correlate.json     # FO4 ranks; STA ranks when S2 ran
```

CLI:

```bash
cva6-build timings sta-handoff --from-timing <dir> [--output <out>] [--target-mhz N]
cva6-build timings sta-handoff --from-timing <dir> --try-tools [--top M] [--liberty path.lib]
```

### Phase S1 — Yosys synth smoke (sparse) — **implemented (soft-skip)**

- Reads sources from `portable.f` or emit `svt_corrected.f` (`--use-emit`).
- Yosys from OSS CAD suite (`edaPaths`) + yosys-slang when `.sv` present; else `read_verilog`.
- Top from `--top` / first analyze module / `modules_requested`.
- Writes `synth/netlist.v`, `sources.f`, `yosys.log`.
- Soft-skip if yosys missing or empty source list; fail status if yosys runs but errors (S0 still ok).

### Phase S2 — OpenSTA smoke — **implemented (soft-skip)**

- Requires S1 netlist + liberty (`--liberty` / `CVA6_LIBERTY` / `pd/pdk/**/typical.lib`).
- Binary `sta` or `opensta` on PATH.
- Writes `opensta/run.tcl`, `paths.rpt`, `wns.txt`, `opensta.log`.
- Soft-skip without liberty or binary; stub TCL still written when netlist exists without liberty.

### Phase S3 — Correlate — **host done (incl. offline fixture); lab FO4 retune open**

- `correlate.json` includes `sta_rank`, `overlap_score`, `missing_in_sta` / `missing_in_fo4`.
- Parser: `parseOpenStaPathReport` (Startpoint/Endpoint/slack lines).
- **S3a offline:** `lab-run` injects `fixtures/sta_smoke/opensta_paths.rpt` so CI always exercises
  overlap scoring without a real OpenSTA binary (labeled `s2-opensta-fixture`, not sign-off).
- **S3b host:** `timings fo4-golden check|write` + fixture `fo4-golden.json` (drift gate for packages).
- **S3b host propose:** `timings retune-propose` (also auto after `lab-run`) reads `correlate.json` +
  `fo4-v1.toml` inventory → `retune-proposal.{md,json}`. **Never edits** the model. Flags synthetic
  fixture STA so lab does not retune from offline S3a.
- **S3b lab:** retune `sv-timing/resources/fo4-v1.toml` when **real** STA disagree (package-side),
  using the proposal as the operator checklist.

### Phase S3 — Correlation & fix loop for sv-timing

| Signal | Action on sv-timing / host |
|--------|----------------------------|
| FO4 top path missing in STA | Check hierarchical name map; improve `sta_hints` |
| STA critical path FO4-ranked low | Revisit FO4 table / multi-cycle tags / package opacity |
| Correct emit improves FO4 but not STA | Review transform safety; do not auto-trust emit |
| Monorepo soak package | `svt.py monorepo-soak --correct --emit` → `--from-timing` pkg → `sta-handoff [--use-emit]` |
| Golden fixture FO4 drift | Update fixture baselines with commit note |

Deliverables:

- `correlate.json`: `{ fo4_rank[], sta_rank[], overlap[], missing_in_sta[], missing_in_fo4[] }`
- Optional CI job: **informational** (no fail on FO4/STA disagreement until model trusted)
- Package-side: fixture tests remain independence-clean; FO4 table tweaks in `resources/fo4-v1.toml` only with golden re-baselines

### Phase S4 — OpenROAD floorplan smoke

- **S4a (done):** when S1 netlist exists, write `openroad/floorplan.tcl`; run `openroad -exit`
  if on PATH (soft-fail without tech LEF).
- **S4b (lab):** open-PDK sky130 LEF/lib or NDA drop under `pd/pdk/`; no tape-out claim.
- Tiny module set only (`sta_smoke` / `comb_adder`), not full CVA6.

### Phase S5 — Full-core / SoC (out of scope for early gates)

- Full `cv64a6` STA remains commercial or multi-day open flow.
- Host may point STA at corrected **hot modules** only.

---

## 6. Command & workspace layout

```text
workspace/build/
  sv-timing/<pkg>/           # --from-timing input
  sta-handoff/<pkg-tag>/     # produced by timings sta-handoff
    seeds.sdc
    fo4_paths.csv
    handoff-manifest.json
    correlate.json
    soak-dashboard.json      # copy or link from package
    synth/                   # S1
      netlist.v
      yosys.log
    opensta/                 # S2
      run.tcl
      wns.txt
      paths.rpt
    openroad/                # S4
      …
```

Clean purpose: add `sta-handoff` under `build/sta-handoff` (future `clean sta` alias of subdir).

---

## 7. Correlation semantics (normative for S3)

1. Rank FO4 paths by `total_fo4` descending; take top *N* (default 16).
2. Parse STA path report for endpoint/startpoint strings (tool-specific adapter).
3. **Overlap score** = fraction of FO4 top-*N* whose start/end tokens appear in STA top-*N* (normalized, case-fold).
4. **Never** fail CI on low overlap in v1; log + write `correlate.json`.
5. When overlap is high and FO4 `frequency_closure.closes` disagrees with STA WNS, prefer STA and file an FO4 model issue.

---

## 8. Fixing sv-timing from results

| Finding class | Fix surface |
|---------------|-------------|
| Parser / IR miss | `sv-timing-core` lower + fixtures |
| FO4 cost wrong class | `resources/fo4-v1.toml` + golden FO4 tests |
| Hint names useless for STA | `sta_hints_from_design` + hierarchical instance graph |
| Correct emit worse STA | transform allowlist / refuse paths; host refuse list |
| Host flist wrong | `tooling/timings.ts` portable.f / param-map |

Package CI stays **fixture-only**. Host correlation is **additive** and may live only in monorepo CI.

---

## 9. Relationship to residual candidates

| Candidate | Tie-in |
|-----------|--------|
| Broader `CVA6_FROM_TIMING` | Soaks preflight package; optional `sta-handoff` after suite |
| Bench correlation | Side-by-side `soak-dashboard` + Dhrystone/CoreMark env metrics in one JSON |
| Windows sim | Orthogonal; STA path is primarily Linux/WSL |
| Technology / PDK | Liberty binding at `pd/pdk/` + `CVA6_TECH_OPT` when armed |
| Zacas / RVV | Not required for STA smoke; hot modules may include `alu` first |

---

## 10. Acceptance checklist (SoC readiness tone)

- [x] S0 always runs offline (no PD tools).
- [x] S1–S2 soft-skip cleanly; probe documents missing opensta/liberty.
- [x] Generated SDC is review-only (comments + create_clock seed).
- [x] Independence: `sv-timing cargo test` needs no OpenSTA.
- [x] Correlate JSON is reproducible given same analyze + STA reports
      (offline: synthetic `opensta_paths.rpt` fixture → numeric `overlap_score`).
- [x] Documented in `AGENTS-build-platform.md` and host help.
- [x] **S3b-lab host propose** — `retune-propose` + lab-run artifact (review-only).
- [ ] **S3b-lab** FO4 table retune from **real** STA (package edit; not host).
- [ ] **S4b** OpenROAD + tech LEF (not host).

---

*Operator one-shot (offline S0 + soft S1–S4 + fixture S3a + retune propose):*

```bash
./build.sh timings doctor          # readiness + fo4-v1 inventory + retune checklist
./build.sh timings lab-run         # fixture → golden → handoff → inject → lab-report + retune-proposal
./build.sh timings retune-propose  # re-emit proposal from latest correlate
CVA6_LIBERTY=/path/to.lib ./build.sh timings lab-run --no-sta-fixture --try-tools
./build.sh timings retune-propose  # after real STA: costHints become actionable
```

*Real-core auto-correct → from-timing → OpenSTA (package-first):*

```bash
# From repo root (analyze + correct + emit package; optional handoff):
bash verif/regress/monorepo-soak-from-timing.sh
SVT_STA_HANDOFF=1 bash verif/regress/monorepo-soak-from-timing.sh
# Or from sv-timing/:
python tools/svt.py monorepo-soak --profile sparse_ex --correct --emit --allow-latency \
  --sta-handoff --use-emit --try-tools
# Liberty path for real S2:
CVA6_LIBERTY=/path/to.lib python tools/svt.py monorepo-soak --profile sparse_ex \
  --correct --emit --sta-handoff --use-emit --try-tools
```

See `sv-timing/architecture/MONOREPO-SOAK.md` §5.1.

*Host offline track is complete (S0–S3a fixture, S3b propose, S4a scaffold, doctor, CI) and re-gated by
`verif/regress/s9-lab-gate.sh` (AGENTS-todo §9). Remaining work is lab PD (real S3b-lab FO4 retune,
S4b LEF) or optional live stacks (R3b Image, Ara cosim, dual-hart CRT). Zacas.Q residual is closed.*
