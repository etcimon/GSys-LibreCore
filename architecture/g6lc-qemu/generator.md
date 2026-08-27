# `g6lc_qemu` — the generator: ingest, IR, conformance

Parent: [`README.md`](README.md) (read §2, the three-input thesis, first).
Package implementation: `g6lc_qemu/crates/{g6q-svcfg,g6q-flist,g6q-dts,g6q-core}`.

This document defines **what the generator reads, what it produces, and how it reports the places
where the three inputs disagree**. Everything downstream — all four backends and both diagnosis
tiers — consumes the `TargetModel` and nothing else.

---

## 1. Planes

The generator ingests in two planes, selected by `--plane`.

| Plane | Reads | Produces |
|---|---|---|
| **`core`** | `core/include/config_pkg.sv`, `core/include/<target>_config_pkg.sv`, `core/include/ariane_pkg.sv` (PMU widths/groups), `core/include/build_config_pkg.sv` (derived fields), `core/perf_counters.sv` (event matrix), `core/Flist.{cva6,g6lc,fetch_B,smt_legacy}`, `vendor/ara/Flist.ara` | ISA + CSR + microarchitecture facts, PMU event table, instruction-supply selection |
| **`apu`** | `corev_apu/tb/ariane_soc_pkg.sv`, `Flist.ariane`, `corev_apu/include/g6lc_ai_island_cfg_pkg.sv`, `corev_apu/ai_island/include/g6lc_ai_desc_pkg.sv`, `corev_apu/ai_island/**` (module presence) | memory map, peripherals, PLIC/CLINT geometry, island MMIO + descriptor ABI |
| **`soc`** (default) | both | the complete machine |

A third input set, orthogonal to the planes, is the **device trees**
(`corev_apu/bootrom/ariane*.dts`) — read by `g6q-dts` and compared against both planes.

`--plane core` is useful on its own: it is what a `linux-user`-style or ISA-only run needs, and it is
what the `Xg6lcai` T0 instruction model needs to know without pulling in the island.

---

## 2. Readers

### 2.1 `g6q-svcfg` — SystemVerilog configuration reader

**Scope, deliberately narrow.** The inputs are about a dozen known, stylistically uniform package
files: a `typedef struct packed` describing `cva6_user_cfg_t` / `cva6_cfg_t`, `localparam` scalars,
and named struct literals (`Field: value,`) in each target package. A full SystemVerilog parser is a
large dependency for that job.

Q0–Q1 therefore ship a **purpose-built parameter reader**: it resolves `localparam` scalars, enum
identifiers (`bp_type_t`, `repl_policy_t`, `smt_policy_t`, `coh_policy_t`, `copro_type_t`), named
struct-literal members (including the nested `ai_cfg_t`), simple integer arithmetic and `` `define ``
substitution — and, critically, **fails loudly on anything it does not understand** rather than
guessing a default. A field it cannot resolve becomes `unresolved`, which the conformance report
surfaces and `--conform strict` treats as fatal.

> **Escalation, recorded now so it is not a surprise later.** If the narrow reader proves brittle
> across packages, the package vendors **dalance/sv-parser** exactly as `sv-timing` does
> (`sv-timing/AGENTS-vendor-sv-parser.md`: integral in-tree copy under `crates/sv-parser`, path
> dependency, pin file, patches in sort order). The Q1 gate — all seven `g6lc64_*` packages plus the
> `cv{32,64}a6*` family round-tripping to golden JSON — is what makes brittleness *detectable*
> instead of latent.

**Fields consumed** (not exhaustive; the reader is field-driven from `cva6_cfg_t`, so new knobs
appear automatically and land in the model as `unknown-but-carried`):

| Group | Fields |
|---|---|
| Width / base | `XLEN`, `VLEN`, `IS_XLEN32/64`, `FpgaEn` |
| Extensions | `RVA`, `RVZacas`, `RVB`, `ZKN`, `RVV`, `RVC`, `RVH`, `RVZCB`, `RVZCMP`, `RVZCMT`, `RVZiCond`, `RVZiCbom`, `RVZiCboz`, `RVZiCbop`, `RVZicntr`, `RVZihpm`, `RVF`, `RVD`, `XF16`, `XF16ALT`, `XF8`, `SstcEn`, `SscofpmfEn`, `SvnapotEn`, `SvpbmtEn`, `ZihintpauseEn`, `ZawrsEn` |
| Privilege / MMU | `RVS`, `RVU`, `TvalEn`, `DebugEn`, `InstrTlbEntries`, `DataTlbEntries`, `UseSharedTlb`, `SharedTlbDepth` |
| Front end | `RASDepth`, `BTBEntries`, `BPType`, `BHTEntries`, `BHTHist`, `BPGhistLen`, `BPTageTables`, `BPTageTableEntries`, `BPTageTagBits`, `BPLoopEn`, `BPIndirectEn`, `BPIndirectEntries`, `BPStatCorEn`, `BPCkptDepth`, `FtqDepth`, `FdipEn`, `FdipDistance`, `LoopBufEn`, `LoopBufEntries` |
| Issue / commit | `SuperscalarEn`, `NrIssuePorts`, `NrCommitPorts`, `NrScoreboardEntries`, `NrLoadBufEntries`, `MaxOutstandingStores`, `ALUBypass`, `NrLoadPipeRegs`, `NrStorePipeRegs` |
| Speculation | `SliceOoOEn`, `SliceIstEntries`, `SliceAiqDepth`, `SliceBiqDepth`, `SliceMaxRunahead`, `OoOEn`, `DeepSpecEn` |
| Memory | `WayPredEn`, `WayPredEntries`, `ReplPolicy`, `HwPrefetchEn`, `HwPrefetchStreams`, `DcacheMshrDepth`, `DcacheFlushOnFence*`, `L2En`, `L2ByteSize`, `L2SetAssoc`, `L2LineWidth`, `L2MshrDepth`, `L2DataBanks`, `WtDcacheWbufDepth` |
| Threads / cores | `NrHarts`, `SmtPolicy`, `SmtFetchQuantum`, `SmtStarveLimit`, `NrCores`, `CohPolicy`, `SnoopFilterEn`, `SnoopFilterEntries`, `CohInvalDepth`, `CohAxiStarveLimit` |
| Coprocessor | `CvxifEn`, `CoproType`, `EnableAccelerator`, nested `AiCfg` (`MatrixEn`, `AccelEn`, `TileLdEn`, `RequantEn`, `SparseEn`, `UmodeEn`, `Int4En`, `Sparse24En`, `TileM/N/K`, `TileCount`, `AccBanks`, `AccDepth`, `Queues`, `QueueDepth`) |

**`check_cfg` mirroring.** `core/include/config_pkg.sv`'s `check_cfg` assertions are the RTL's own
legality rules (power-of-two `BTBEntries`/`BHTEntries`, `!(BPIndirectEn && BTBEntries==0)`,
`!(BPType==GSHARE && BHTEntries==0)`, SMT quantum ≥ 1, `NrHarts ≤ CVA6_MAX_SMT_HARTS`,
`NrCores ≤ CVA6_MAX_CORES`, …). The generator re-expresses them as a **validator** so that an
illegal config is rejected identically on both sides. A config the RTL would refuse to elaborate must
not produce a running emulator — that is how a bogus "it works in QEMU" report gets born.

### 2.2 `g6q-flist` — flist expansion and membership

A generic `.f` reader in the portable style `sv-timing` already established
(`sv-timing/AGENTS-host.md` §"Portable `--files-from`"): paths, `#`/`//` comments, `+incdir+`,
`+define+`, nested `-f` / `-F` with cycle guarding, `${VAR}` / `$VAR` expansion from an explicit
`--set` map (`CVA6_REPO_DIR` is *passed in*, never baked in).

Output is two things:

1. the **file set** actually compiled for this target, and
2. the **define set** in effect (`G6LC_FETCH_B`, `NEXYS_VIDEO`, …).

Membership queries the model then asks:

| Question | Evidence |
|---|---|
| Is Ara real or a stub? | `vendor/ara/Flist.ara` in the set **and** the upstream tree present, vs `core/cva6_accel_first_pass_decoder_stub.sv` alone |
| Which instruction supply? | `+define+G6LC_FETCH_B` + `core/Flist.fetch_B` (default B) vs frozen A (`core/frontend/` + `core/smt/g6lc_fetch_{pkg,dbg}`) vs oracle (`core/Flist.smt_legacy`) |
| Is the AI CVXIF plane compiled? | `core/cvxif_g6lc_ai/**` in the set + `CoproType == COPRO_G6LC_AI` |
| Is the island compiled? | `corev_apu/ai_island/**` in the set (note: the island README records it is **not yet on the SoC AXI flist** in every configuration) |
| L2 / L3 present? | `corev_apu/l2_cache/**`, `corev_apu/l3_cache/**` |
| Gate-level vs RTL | `core/Flist.cva6_gate` |
| DRAM window size | `NEXYS_VIDEO` define ⇒ 512 MiB, else 1 GiB (`ariane_soc_pkg.sv`) |

### 2.3 `g6q-dts` — device tree reader / writer

Reads a `.dts` (or `.dtb`) into a small node/property tree; supports overlay merge, `--dts-set` /
`--dts-del` mutation, and emission back to `.dts` / `.dtb`. The properties it *understands
semantically* — as opposed to carries opaquely — are exactly the rows of
[`../../AGENTS-dts-validation.md`](../../AGENTS-dts-validation.md) §3:

`riscv,isa`, `riscv,isa-base`, `riscv,isa-extensions`, `mmu-type`, `tlb-split`,
`riscv,cbom-block-size` / `riscv,cboz-block-size`, `i-cache-*` / `d-cache-*`, `cpu-map`
(cluster/core/thread), `timebase-frequency`, `clock-frequency`, `riscv,pmu`
(`riscv,event-to-mhpmevent`), `riscv,cpu-intc`, `sifive,clint0`, `sifive,plic-1.0.0` (`riscv,ndev`),
`memory@`, `chosen/bootargs` + `stdout-path`, and `g6lc,ai-matrix` (with `g6lc,acc-tile-*`,
`g6lc,macs-per-cycle`, `g6lc,queues`, `g6lc,queue-depth`, `g6lc,noc-width`).

`--dts-validate` re-runs the §3 cross-checks against the ingested config and flist facts, in the same
FAIL / WARN / GAP vocabulary the existing `validate-cva6-dts.ps1` uses, so the two tools agree.

### 2.4 PMU table reader

`core/perf_counters.sv` holds the event matrix as `event_group[grp][idx] = <signal>` with the packing
`{group[7:5], idx[4:0]}` (`ariane_pkg`: `MHPMEventGrpWidth=3`, `MHPMEventIdxWidth=5`). The reader
extracts group → index → symbolic-event-name, giving:

| Group | Contents |
|---|---|
| 0 `MHPMGrpLegacy` | idx 1–22: I$/D$ miss, ITLB/DTLB miss, load/store, exception, eret, branch, mispredict, branch-exception, call, return, SB full, IF empty, I$/D$ access, eviction, I-TLB flush, integer, FP, pipeline bubbles |
| 1 | OoO / MLP: rename+ROB backpressure, IQ stall, mispredict, load, store, LSQ stall, STL forward, rename stall |
| 2 | server memory: L3 miss, L3 hit, PF issue, PF train, L2 miss |
| 3 | FSE: mispredict, spec cancel, window full, issue bubble, load pressure, store pressure |
| 4 `MHPMGrpAI` | `ai_pmu_{op,mma,post,t0,busy}` (gated on `AiCfg.MatrixEn`) |

This table is what makes D2 counters and the DTS `riscv,event-to-mhpmevent` map *the same numbers*.
See [`diagnosis.md`](diagnosis.md) §5.

---

## 3. The `TargetModel` IR

One JSON document (schema: `g6lc_qemu/schemas/target-model.schema.json`), version-stamped, with a
provenance block. It is the **only** interface between ingest and every backend.

```jsonc
{
  "schema_version": "1",
  "generated_by": { "tool": "g6lc-qemu", "version": "0.1.0", "rev": "<git-describe|unknown>" },
  "provenance": {
    "repo_root": "E:/cva6",
    "repo_rev": "<sha|dirty|unknown>",
    "sources": [ { "path": "core/include/g6lc64_ai_config_pkg.sv", "sha256": "…" } ],
    "defines": ["G6LC_FETCH_B"],
    "overrides": [ { "field": "NrHarts", "value": 2, "origin": "--cfg-override" } ]
  },

  "target":   { "id": "g6lc64_ai", "plane": "soc", "profile": "g6lc-soc" },

  "isa": {
    "xlen": 64, "base": "rv64i",
    "extensions": { "m": "live", "a": "live", "f": "live", "d": "live", "c": "live",
                    "zacas": "live", "zba": "live", "v": "absent", "h": "absent",
                    "xg6lcai": "live" },
    "isa_string": "rv64imafdc_zba_zbb_zbs_zicbom_zicboz_zacas",
    "mmu": { "mode": "sv39", "itlb": 16, "dtlb": 16, "shared_tlb": false },
    "vendor_ids": { "mvendorid": "…", "marchid": "…", "mimpid": "…" }
  },

  "csr":  { "implemented": [ { "addr": "0x801", "name": "aicfg", "gate": "AiCfg.MatrixEn" } ] },

  "uarch": {
    "issue": { "superscalar": true, "issue_ports": 2, "commit_ports": 2, "scoreboard": 16 },
    "bp":    { "type": "TAGE_LITE", "btb": 32, "bht": 128, "ras": 8, "tage_tables": 4 },
    "cache": { "l1i": {...}, "l1d": {...}, "l2": { "enabled": true, "bytes": 262144 } },
    "smt":   { "harts": 1, "policy": "RR", "quantum": 1 },
    "cores": { "count": 2, "coherence": "filtered" },
    "ooo":   { "slice": false, "full": false, "deep_spec": false }
  },

  "soc": {
    "peripherals": [ { "id": "clint", "base": "0x2000000", "len": "0xc0000", "model": "sifive,clint0" } ],
    "dram": { "base": "0x80000000", "len": "0x40000000" },
    "plic": { "sources": 30, "targets": 16, "max_priority": 7 },
    "harts_total": 2
  },

  "ai": {
    "present": true, "seam": "B",
    "core_plane": { "tile_m": 8, "tile_n": 8, "tile_k": 8, "acc_banks": 1, "queues": 1 },
    "island": { "base": "0x40000000", "len": "0x1000", "plic_source": 8,
                "acc_tile": [256,256,256], "macs_per_cycle": 256, "desc_bytes": 64 }
  },

  "pmu": { "groups": { "0": { "1": "l1_icache_miss", "...": "..." }, "4": { "0": "ai_op" } } },

  "flist": { "supply": "fetch_B", "ara": "stub", "island_on_soc_flist": true,
             "files": 412, "defines": ["G6LC_FETCH_B"] },

  "conformance": { "…": "see §4" }
}
```

**Design rules for the IR.**

- **Carry, don't collapse.** A config field the readers do not semantically understand is still
  carried into `uarch.raw` so a future backend can use it without a re-ingest.
- **Every capability has a verdict**, never a bare boolean (§4).
- **Provenance is mandatory.** Source SHA-256s and the repo rev go in, so a `target-model.json`
  attached to a bug report is self-describing and a stale model is detectable.
- **`--cfg-override` is recorded as `synthetic`**, never silently folded into the config, and the
  taint propagates into traces and PMU dumps.

---

## 4. The conformance report

The first-class output. Schema: `g6lc_qemu/schemas/conformance.schema.json`; verb: `g6q conform`.

Each row is a capability with the three inputs and a verdict:

| Verdict | Meaning | `--conform strict` |
|---|---|---|
| `live` | enabled in config, RTL on the flist, declared in DTS | emulate |
| `stub` | enabled in config, but the compiled RTL is a stub/placeholder | **refuse**; report |
| `absent` | disabled in config (and correctly absent elsewhere) | skip |
| `undeclared` | live in RTL but not advertised in the DTS | emulate, warn (guest will not use it) |
| `overdeclared` | advertised in DTS but not live in RTL | **refuse**; this is a guest-visible lie |
| `unresolved` | a reader could not determine the field | **refuse** |
| `synthetic` | forced by `--cfg-override` | emulate, taint all artifacts |

Worked examples from today's tree:

| Capability | Config | Flist | DTS | Verdict |
|---|---|---|---|---|
| RVV on `g6lc64_server_math_v` | `RVV=1` | `Flist.ara` **absent** ⇒ stub Ara | `v`, `zve64d` in `ariane-server-math-v.dts` | **`stub`** — and `overdeclared` against the DTS |
| H on `g6lc64_stream8` | `RVH=1` | live | `h` token **omitted** in `ariane-stream8.dts` | **`undeclared`** (deliberate today) |
| H on `g6lc64_smt2` | `RVH=0` | — | no `h` (correct per `CONTRACT.md` §6.5) | `absent` |
| `Xg6lcai` on `g6lc64_ai` | `AiCfg.MatrixEn=1` | `core/cvxif_g6lc_ai/**` + `corev_apu/ai_island/**` | `xg6lcai` + `g6lc,ai-matrix` | `live` |
| Zacas on `g6lc64_smt2` | `RVZacas=1` | live | `zacas` | `live` |
| Instruction supply | — | `+define+G6LC_FETCH_B` | not DT-visible | `live (fetch_B)` |

`--conform strict` is the default for `diag` / `tandem`; `warn` is the default for `run`. This split
matters: you *want* to boot a partially-conformant machine while bringing it up, and you *never* want
to publish a diagnosis from one.

---

## 5. Determinism and pinning of the ingest

- Sources are hashed; the model records SHA-256 per file. Re-running `gen` on an unchanged tree
  produces a byte-identical model (map ordering is canonicalised).
- `pins.toml` records the QEMU rev, the OpenSBI ref (v1.5), the `Xg6lcai` contract revision, and the
  `AGENTS-dts-validation.md` revision the DTS checks were written against — the "pinned cross-connect"
  pattern `ai-tensor/architecture/VERSIONING.md` established. If a silicon doc changes the contract,
  the pin is bumped deliberately; bits are never silently reinterpreted.
- Golden fixtures under `g6lc_qemu/fixtures/` (a miniature config package + flist + DTS + expected
  model JSON) keep `cargo test --workspace` green **without the monorepo**, satisfying the
  independence invariant.

---

## 6. Standalone use (no monorepo)

Everything above is addressable by explicit path, so the package is usable against any LibreCore-shaped
tree — or a fixture — without `build-platform` and without this repository:

```bash
g6lc-qemu gen \
  --config-pkg /path/to/g6lc64_ai_config_pkg.sv \
  --flist      /path/to/Flist.g6lc --set CVA6_REPO_DIR=/path/to/repo \
  --soc-map    /path/to/ariane_soc_pkg.sv \
  --dts        /path/to/ariane-ai.dts \
  --emit-model target-model.json
```

`--repo-root` is a convenience that derives all of the above from a target id; it is never required.
