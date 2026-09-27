# Versioning and cross-connect

**Goal:** keep `ai-tensor` **independently releasable** while staying **aligned** with monorepo
architecture and live `ai_island` when a profile says so.

---

## 1. Three version axes

| Axis | What it versions | Bump when |
|---|---|---|
| **`abi_rev`** | Pack format, status codes, C ABI symbols | Descriptor/CSR meaning changes for software |
| **`isa_doc_rev`** | Pin to monorepo `architecture/ai-matrix/isa-encoding.md` | Upstream contract text changes |
| **`island_rev`** | Pin to `corev_apu/ai_island` behavior/MMIO | CTL map, doorbell, DMA semantics change |

Frameworks depend on **`abi_rev`**.  
Hardware bring-up selects **`island_rev` + profile**.  
Docs sync uses **`isa_doc_rev`**.

Semantic versioning for the package release (Cargo/PyPI) tracks **`abi_rev`** primarily;
profiles may lag a release if sim still matches.

---

## 2. Profiles (selectable cross-connect)

A **profile** is a small manifest (future `profiles/*.toml`) naming pins + defaults:

```toml
# Conceptual example — file lands with M1
id = "sim-v0"
abi_rev = "0.1.0"
isa_doc_rev = "monorepo:<git-sha-or-tag>"
island_rev = "none"          # sim does not map MMIO
backend = "sim"
features = ["t2_desc_v1", "completion_word_v1"]

id = "linux-island-p3"
abi_rev = "0.1.0"
isa_doc_rev = "monorepo:<same or newer>"
island_rev = "monorepo:<ai_island-compatible-sha>"
backend = "linux-uio"
mmio_map = "island_p3_v1"    # offsets table in package
features = ["t2_desc_v1", "dma_fetch", "wr_cpl_en", "plic_src8"]
```

**Selection:** env `AI_TENSOR_PROFILE=…`, CLI `--profile`, or framework device string
`aitensor:0?profile=linux-island-p3`.

Default for CI: **`sim-v0`**.

---

## 3. Cross-connect matrix

| Package concern | Monorepo / island artifact | Profile field |
|---|---|---|
| Op / flag / dtype bits | `isa-encoding.md` | `isa_doc_rev` |
| 64 B layout | `g6lc_ai_desc_pkg` + isa §7 | `abi_rev` + golden fixtures |
| CTL / doorbell / regions | `ai_island` README + RTL | `island_rev` + `mmio_map` |
| Completion DMA | `wr_cpl_en`, mem_store | feature `wr_cpl_en` |
| PLIC | Variane source 8 | feature `plic_src8` |
| T0 enq | CVXIF coprocessor | feature `t0_enq` |

Missing feature ⇒ runtime `Unsupported` (not silent CPU fallback).

---

## 4. Compatibility policy

1. **Additive island MMIO** (new RO caps bits): new profile or minor `island_rev`; old profiles keep
   working if they ignore unknown bits.
2. **Changing descriptor field meaning:** new `abi_rev` major; dual-pack only if explicitly
   maintained (avoid).
3. **Monorepo scaffold vs RTL drift:** package goldens follow **RTL pin** when they disagree;
   file a monorepo doc bug.
4. **Framework packages** declare supported `abi_rev` range; refuse to load mismatched native SO.

---

## 5. Sync procedure (manual until automated)

1. Read monorepo `isa-encoding.md` + `ai_island` README at chosen revs.
2. Update `ABI-CONTRACT.md` / fixtures if bits changed.
3. Bump `abi_rev` or profile pins in VERSIONING / future `profiles/`.
4. Run sim goldens; optional monorepo `ai-matrix-veri` as HW oracle.
5. Note the pin in `AGENTS-todo.md` and release notes.

Automation later: `tools/ait.py pin-set --isa … --island …` writes profile TOML.

---

## 6. Flexibility vs optimality

| Flexible | Optimal default |
|---|---|
| Multiple profiles | One **sim-v0** always green |
| Optional T0 / IRQ / DMA features | T2 desc + poll first |
| Bounce memory profile | Shared VA / AI-3 regions |
| Cosim oracle | Not on critical CI path |

Do not multiply profiles per framework — only per **platform capability**.

## 7. Live profiles (Phase A)

| Profile file | Backend | Pin intent |
|---|---|---|
| `profiles/sim-v0.toml` | sim | Panel box 1024×512×512, Macs=512, NocWidth=64, `pmu_v1`, `compute_ref` |
| `profiles/island-p3-v1.toml` | linux-uio (M5) | Same geometry; MMIO base `0x4000_0000`; PLIC 8 |

The profile **filenames are retained for caller path stability**, but their contents now
explicitly pin `abi_rev=2.0.0`, `contract_version=2`, `operand_b_layout="k-major"`,
and `t2_desc_v2`. `sim-v0.toml` now identifies as `sim-v2`;
`island-p3-v1.toml` identifies as `island-p3-desc-v2`. The latter is a v2 compatibility
requirement, not a claim that an old v1 device was upgraded. Its MMIO offset-map name
remains `island_p3_v1` because the offsets did not change. Both retain the conservative
`dtype_mask=0x0001` pin; real devices must be gated by discovered CAP, not this default.
The earlier conceptual examples are historical v1 examples and are not accepted as
executable v2 profiles. Parsers reject explicit non-v2 versions and `t2_desc_v1`.

`profiles/software-reference-v2.toml` is an explicit software-only full scalar reference
(`0x00fb`, no SP24). Python `Device.from_profile` selects the pure Python reference even
if an optional native extension is installed. Rust callers select
`Caps::software_reference_v2()` or `MmioDevice::software_reference_v2()`; the minimal
Rust profile parser remains metadata, not a device factory. Native PyO3 constructors
accept `software_reference=True`; old extensions without `CONTRACT_VERSION=2` are refused.
No C binary caps structure was extended. Package release numbers remain a separate
release-management step; the wire ABI revision and descriptor version are already explicit.

