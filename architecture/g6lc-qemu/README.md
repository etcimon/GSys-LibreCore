# Extension point: `g6lc_qemu` — generated emulation and SV diagnosis

**Status:** **Q1 — ingest, `TargetModel` and conformance landed** · **Code prefix:** `g6lc_qemu` / `g6q` ·
**Licensing:** tier **T** (MIT) · **Package:** [`../../g6lc_qemu/`](../../g6lc_qemu/)

Feature-domain for **emulating GSys LibreCore** rather than simulating it: a self-contained Rust
**generator** that reads LibreCore's own config packages, flists, SoC package and device trees, and
emits several emulation backends — stock-QEMU invocations, QEMU C (machine / CPU / `ai_island` /
TCG plugins), and a native Rust virtual machine — together with a two-tier **diagnosis layer** that
relates emulator behaviour back to the SystemVerilog.

Read [`../README.md`](../README.md) (scaffold contract) and [`../../AGENTS.md`](../../AGENTS.md) §0
first.

> ### Scaffold contract
> Nothing in this directory is compiled. No path here is referenced by `core/Flist.cva6`, any
> `verif/` flist, or any `pd/` script. These documents *reserve* seams and record decisions; they
> move no RTL. `.md` only, tier **T**, no inline SPDX header (`DOCS_UNDER_TIER`).
>
> The **package** at [`../../g6lc_qemu/`](../../g6lc_qemu/) *is* code, and is also tier **T** (MIT).
> It is project-independent in the `sv-timing` / `ai-tensor` sense: it builds and tests with only its
> own tree plus fixtures, and the monorepo is an *optional consumer*.

---

## Document index

| Doc | Role |
|---|---|
| **this file** | Why it exists, the three-input thesis, the GPL boundary, invariants |
| [`generator.md`](generator.md) | Ingest model (`core` / `apu` planes), the `TargetModel` IR, the conformance report |
| [`backends.md`](backends.md) | B0–B3 emission targets, the `g6lc-soc` / `g6lc-virt` machine split, MTTCG |
| [`diagnosis.md`](diagnosis.md) | **D1** tandem (`st_rvfi`) and **D2** microarchitectural + PMU tiers |
| [`ai-island.md`](ai-island.md) | `Xg6lcai` CPU model, generated island device, ai-tensor **in-guest** |
| [`cli.md`](cli.md) | Complete command-line surface: target / DTS / APU / OpenSBI / OS / diag |
| [`os-linux-matrix.md`](os-linux-matrix.md) | OpenSBI modes, OS profiles (incl. Ubuntu), the Q9 capability matrix |
| [`staging.md`](staging.md) | Q0–Q9 stages with entry / exit gates |

Related programs of record:
[`../multi-threading/testharness-proxy.md`](../multi-threading/testharness-proxy.md) (evidence
discipline) ·
[`../multi-threading/linux-boot-scale.md`](../multi-threading/linux-boot-scale.md) (Linux-cap bar) ·
[`../ai-matrix/isa-encoding.md`](../ai-matrix/isa-encoding.md) (frozen `Xg6lcai` contract) ·
[`../../AGENTS-dts-validation.md`](../../AGENTS-dts-validation.md) (DT ⇄ spec ⇄ RTL rows).

---

## 1. Why an emulator, and why a *generator*

### 1.1 The gap it fills

The project has two execution models today and neither answers the question "does this configuration
run a real operating system":

| Model | Throughput | What it knows |
|---|---|---|
| Verilator RTL (`verif/regress`, remote builder) | ~10–100 kIPS | everything, cycle-accurately |
| Spike ISS (tandem, `corev_apu/tb/common/spike.sv`) | ~20–100 MIPS | the ISA, generically |

A Linux-boot evidence run is a **200 M-cycle Verilator soak on a remote builder**
([`../multi-threading/testharness-proxy.md`](../multi-threading/testharness-proxy.md)), and the
failure modes being chased there are firmware-level: `coldboot_done=0`, WFI at `_start_hang`,
"illegal @46f2c", cookie classification. Those are triage problems, and triage at 10 kIPS is the
bottleneck. Spike is fast but knows nothing about `ariane_soc_pkg`'s memory map, the `ai_island`
MMIO window, `perf_counters.sv`'s event groups, or which RTL is actually on the flist.

`g6lc_qemu` is the missing middle: **fast enough to boot a distro, specific enough to be diagnostic.**

### 1.2 Why generated

`AGENTS.md` §0.3 lists "hard-coded constants instead of `CVA6Cfg`" as a top cost-driver anti-pattern.
An emulator with a hand-written ISA table, memory map, CSR list and PMU event list is exactly that
anti-pattern, one directory over — and worse, because its divergence from the RTL gets **misattributed
to the RTL**. A diverging emulator used as an oracle is worse than no emulator.

Therefore every table the backends need is *derived*: extension gating, CSR map, memory map,
PLIC/CLINT geometry, PMU event indices, island MMIO offsets, the 64-byte descriptor ABI, and the ISA
string. A constant typed into an emitter is a defect, not a shortcut.

---

## 2. The thesis (three inputs, and their disagreements)

> **The flist decides what is real. The config decides what is enabled. The DTS decides what software
> is told. An emulator generated from all three — and which *reports where they disagree* — is the
> only kind worth building here.**

| Input | Source of truth | Answers |
|---|---|---|
| **Config** | `core/include/config_pkg.sv` + `core/include/*_config_pkg.sv` + `corev_apu/include/g6lc_ai_island_cfg_pkg.sv` | which features are *enabled* and how big the structures are |
| **Flist** | `core/Flist.{cva6,g6lc,fetch_B,smt_legacy,cva6_gate}`, `Flist.ariane`, `vendor/ara/Flist.ara`, `+define+` | which RTL is *actually compiled* |
| **DTS** | `corev_apu/bootrom/ariane*.dts` | what *software is told* exists |

The three routinely disagree, and each disagreement is a real finding:

- `RVV=1` in `g6lc64_server_math_v_config_pkg.sv` while `vendor/ara/Flist.ara` is **absent** ⇒ the
  elaborated design has a **stub** Ara. An emulator that happily executes vector instructions here is
  lying about the design under test.
- `+define+G6LC_FETCH_B` selects `core/fetch_B/` over frozen `core/frontend/`; `Flist.smt_legacy`
  swaps in the `g1*` oracle. Different instruction supply, same config.
- `ariane-stream8.dts` omits the `h` token although the stream8 RTL has `RVH=1`
  ([`../../AGENTS-dts-validation.md`](../../AGENTS-dts-validation.md) §3) — deliberate today, but the
  emulator must *say so* rather than silently advertise H to the guest.

So the generator's first-class output is not code, it is the **conformance report**: for every
capability, the `(config, flist, dts)` triple and a verdict of `live` / `stub` / `absent` /
`undeclared` / `synthetic`. `--conform strict` refuses to emulate anything not `live`.

This is what makes "follows `core/` or `corev_apu/` according to configs and flists" load-bearing
rather than decorative. Details: [`generator.md`](generator.md) §4.

---

## 3. The GPL boundary (decided; do not relitigate casually)

QEMU is **GPL-2.0**. `AGENTS.md` §0.4 carries a hard `E-GPLLINK` guard: GPL material must never enter
a link set with Apache / CERN-OHL material. The repo already handles one GPL work this way — the FPGA
bootrom is tier **F**, "a separate work".

**Decision.**

| Thing | License | Tracked? |
|---|---|---|
| `g6lc_qemu/` generator crates and tooling | **MIT** (tier T) | yes |
| Emitted QEMU C (machine, CPU props, devices, TCG plugins) | **GPL-2.0**, authored *by the emitter* into a separate work | **no** — gitignored `g6lc_qemu/qemu/` and `out/` |
| The QEMU checkout the emission targets | upstream GPL-2.0, untouched | no — pinned in `pins.toml`, fetched on demand |
| Native Rust VM backend (**B3**) | **MIT** (tier T) | yes |

**The rule, enforced not merely stated:** no crate under `g6lc_qemu/crates/**` may depend on,
`#include`, `bindgen`, or link any QEMU header or library. Emission is **text-out only**. The
package's `tools/check_independence.py` fails the build on violation, and the workspace declares no
QEMU-adjacent dependency at all.

The consequence worth internalising: **B3 (native Rust) is not a luxury.** It is the backend that
keeps a fast path and the whole diagnosis tier inside MIT, so CI, the tandem oracle and the
checkpoint/replay machinery never require a GPL build.

---

## 4. Shape at a glance

```text
                core/include/*_config_pkg.sv ─┐
                core/include/config_pkg.sv    │
                corev_apu/tb/ariane_soc_pkg.sv│      ┌──────────────────┐
                corev_apu/include/g6lc_ai_*   ├─────►│  g6q ingest      │
                core/Flist.* · Flist.ariane   │      │  (svcfg/flist/   │
                vendor/ara/Flist.ara          │      │   dts readers)   │
                corev_apu/bootrom/ariane*.dts─┘      └────────┬─────────┘
                core/perf_counters.sv                         │
                                                              ▼
                                                     ┌──────────────────┐
                                                     │   TargetModel    │ ── conformance report
                                                     │   (JSON IR)      │ ── target-model.json
                                                     └───┬───┬───┬───┬──┘
                              ┌──────────────────────────┘   │   │   └────────────────┐
                              ▼                              ▼   ▼                    ▼
                     B0 stock-QEMU argv           B1 QEMU machine C     B2 TCG plugins C     B3 Rust VM
                     + generated DTB              (g6lc-soc/g6lc-virt)  (rvfi/uarch/pmu)     (MIT, tandem)
                     ── no code emitted ──        ──── GPL-2.0 out ────  ─── GPL-2.0 out ──  ─── MIT ───
```

Full backend contract: [`backends.md`](backends.md).

---

## 5. Two machine profiles, never one

| Profile | Contents | Valid for |
|---|---|---|
| **`g6lc-soc`** | bit-faithful to `corev_apu/tb/ariane_soc_pkg.sv`: Debug `0x0`, ROM `0x1_0000`, CLINT `0x200_0000`, PLIC `0xC00_0000` (`NumTargets=16`, `NumSources=30`), UART `0x1000_0000`, Timer `0x1800_0000`, SPI `0x2000_0000`, Ethernet `0x3000_0000`, GPIO/AI island `0x4000_0000`, DRAM `0x8000_0000` (1 GiB), HPS `0xFF80_0000`. **No PCI. No virtio.** | every diagnosis claim, every SoC-map / interrupt-topology question, tandem, checkpoints |
| **`g6lc-virt`** | `g6lc-soc` **+** virtio-mmio (blk / net / rng / 9p / console) **+** a larger RAM window | OS bring-up only: Ubuntu, Debian, Fedora, anything needing a disk and a network |

The faithful SoC cannot boot a distro rootfs — it has no block device and no network. That is a
property of the silicon, not a defect to paper over. `g6lc-virt` exists so that *software* questions
("does this ISA/CSR/PMU surface satisfy a real distro?") can be asked, and its answers are **invalid**
for hardware questions.

Enforcement: the profile is stamped into every artifact, trace and JSON result, and the `diag` /
`tandem` verbs refuse `g6lc-virt` unless `--allow-virt-diag` is passed explicitly.

---

## 6. Invariants

1. **Not evidence.** Per [`../multi-threading/testharness-proxy.md`](../multi-threading/testharness-proxy.md)
   §1 ("one toolchain… local WSL and the builder must not fork a second green"), `g6lc_qemu` output
   may **never** be cited as a soak, peel, pin or Linux-cap result. It produces a *hypothesis* and a
   *checkpoint*; Verilator-on-the-builder stays the green. This is the single most important rule here.
2. **`E-GPLLINK`.** No crate links or includes QEMU (§3).
3. **`E-UPSTREAMWRITE`.** The generator only **reads** tier-U files (`core/Flist.cva6`,
   `core/include/config_pkg.sv`, `core/include/ariane_pkg.sv`, `corev_apu/tb/ariane_soc_pkg.sv`).
   It never edits them and never "fixes" a copyright, SPDX or attribution line.
4. **No second source of truth.** Any table a backend needs is derived from repo files. A hand-written
   constant in an emitter is a defect (§1.2).
5. **`mvendorid` / `marchid` honesty.** Read from the same place the RTL reads them
   (`OPENHWGROUP_MVENDORID` / `ARIANE_MARCHID` in `core/cva6_rvfi.sv` today). Never faked — already a
   release blocker in [`../../AGENTS-todo.md`](../../AGENTS-todo.md).
6. **Independence.** No monorepo path in any `Cargo.toml`; `cargo test --workspace` green on the
   package's own `fixtures/` alone; the monorepo is an optional consumer discovered at runtime via
   `--repo-root`.
7. **Branding.** `g6lc_qemu` / `g6q` prefixes; machine ids `g6lc-soc` / `g6lc-virt`. No `CVA6` /
   `CORE-V` branding on new surfaces (`AGENTS-branding.md` §3: rename at the boundary, never inside a
   tier-U file).
8. **Determinism before diagnosis.** Any run that feeds D1/D2 must be deterministic (fixed
   instructions-per-`mtime`-tick, seeded device timing, recorded MMIO/IRQ). A non-deterministic oracle
   is not an oracle.

---

## 7. Non-goals (with reopen conditions)

| Non-goal | Reopen condition |
|---|---|
| **Host-hypervisor acceleration** (KVM/WHPX, EPT-mapped Sv39, Captive-style) | Only if MTTCG plateaus below the workload need *and* a Linux-host-only backend is acceptable. Cross-ISA guests cannot execute natively on VT-x; the only win available is realising the guest address space in host page tables, and that is a large, Linux-only, hard-to-debug subsystem. |
| **Cycle accuracy** | Never. Verilator owns cycles; D2 is *informative* with documented error bars ([`diagnosis.md`](diagnosis.md) §6). |
| **Replacing Spike as tandem reference** | Never. B3 becomes a *second* reference, not a replacement. |
| **Vendoring or forking QEMU into tracked history** | Never (§3). |
| **Becoming a second build platform** | The optional `build-platform` adapter is Q8 and the package must never require it. |
| **Full RVV/Ara semantics** | Staged. Until then RVV is reported `stub` when `Flist.ara` is absent. |

---

## 8. Pitfalls

- **Citing a `g6lc-virt` run as a SoC result.** The most likely way this project produces a
  misleading answer. Mitigated by profile stamping + `--allow-virt-diag`, but the discipline is human.
- **Letting D2 numbers be read as measurements.** They are *configured-structure models*, not the RTL.
  Correlation is the acceptance criterion, never equality.
- **Hand-editing generated C.** Emitted files carry a `DO NOT EDIT — generated by g6lc_qemu <rev>`
  banner; the tree is gitignored so an edit is silently lost on the next `gen`. Fix the emitter.
- **Drifting from the frozen `Xg6lcai` contract.** [`../ai-matrix/isa-encoding.md`](../ai-matrix/isa-encoding.md)
  is normative for opcodes, CSRs and the descriptor. The emulator consumes it by pin; it never
  reinterprets bits ([`ai-island.md`](ai-island.md) §7).
- **Assuming `NrIssuePorts` is visible to Linux.** It is not. `S = NrCores × NrHarts`, and PLIC
  `NumTargets=16` ⇒ `S ≤ 8` ([`../multi-threading/linux-boot-scale.md`](../multi-threading/linux-boot-scale.md) §0).

---

## 9. Staging summary

| Stage | Deliverable | Exit gate |
|---|---|---|
| **Q0** ✅ | This tree + `g6lc_qemu/` package skeleton + registration | `python tools/g6q.py check` green on fixtures |
| **Q1** ✅ | Ingest + `TargetModel` + conformance | 21 packages round-trip (0 unresolved); 7 DTS parse; stub-Ara, undeclared-H, stub-L2 and an AI topology mismatch all flagged unaided |
| **Q2** ◐ | **B0** stock-QEMU driver + OpenSBI payload | argv + capability delta + `dts`/`dtb` emission done (no external device-tree compiler needed); **boot unverified** — no emulator/toolchain on the authoring host |
| **Q3** | **B3** Rust VM + faithful devices + `st_rvfi` | boots OpenSBI to S-mode; tandem-clean vs Spike |
| **Q4** | **B1** generated `g6lc-soc` machine | buildroot Linux shell; memory map self-check byte-identical |
| **Q5** | **D1** tandem, replay, checkpoint → Verilator resume | reproduces a known soak signature in seconds |
| **Q6** | `Xg6lcai` + island device + ai-tensor `qemu-uio` | in-guest `gemm_s8` matches the INT8 golden; PMU group 4 moves |
| **Q7** | **D2** micro models + PMU groups 0–4 (B2 + B3) | `perf stat` config-shaped; trend-correlates with Verilator |
| **Q8** | MTTCG scale + `g6lc-virt` + distro | S=8 SMP boot with correct `cpu-map`; Ubuntu login over SSH |
| **Q9** | Linux capability matrix | every row Pass/Fail/N-A, failures triaged to config / DTS / RTL |

Gates in full: [`staging.md`](staging.md).
