# `g6lc_qemu` — staging Q0 → Q9

Parent: [`README.md`](README.md). Live queue: `g6lc_qemu/AGENTS-todo.md` (in-tree, per the
independence contract). This file is the **plan of record**; the queue is the state.

Each stage names its deliverable, its **entry** condition, its **exit gate**, and what its output may
be cited as. The recurring answer to the last is *"a hypothesis and a checkpoint, never evidence"*
([`README.md`](README.md) §6.1).

---

## Q0 — Scaffold, package surface, Rust skeleton ✅ *(this pass)*

**Deliverable**

- `architecture/g6lc-qemu/**` — the eight design docs.
- `g6lc_qemu/` — `AGENTS.md`, `AGENTS-todo.md`, `AGENTS-licensing.md`, `README.md`, `LICENSE` (MIT),
  `pins.toml`, in-tree condensed `architecture/`, `tools/` Python spine, Cargo workspace with nine
  crate skeletons, `fixtures/`, `schemas/`.
- Registration: `architecture/README.md` rows, `.licensing-tiers` (`T g6lc_qemu/**`),
  `AGENTS-todo.md` track row, root `.gitignore`.

**Deliberate constraint:** the Q0 workspace declares **no external Rust dependencies**. Everything is
`std`-only — a hand-rolled argv parser and JSON writer, in the same spirit as `build-platform`'s
zero-runtime-dependency invariant. Adopting `serde`/`clap` is a later, recorded decision subject to
the supply-chain rules in `AGENTS.md` (no floating ranges, prefer versions published ≥ 7 days).
The payoff is that `cargo test --workspace` runs offline, on a fresh host, with no registry fetch.

**Exit gate:** `python tools/g6q.py check` green (independence + fmt + clippy + `cargo test
--workspace` on fixtures). No file outside `architecture/g6lc-qemu/**`, `g6lc_qemu/**` and the four
registration files is touched.

---

## Q1 — Ingest, `TargetModel`, conformance ✅ *(complete)*

**Deliverable** `g6q-svcfg` (config-package reader + `check_cfg` validator), `g6q-flist` (expander +
membership facts), `g6q-dts` (read/overlay/mutate/emit/validate), `g6q-core` (IR + JSON + conformance).
Verbs `gen --emit model` and `conform` become real.

**Exit gate**

1. All seven `g6lc64_*` packages **and** `cv64a6_imafdc_sv39` / `cv32a6_imac_sv32` / `cv32a65x`
   round-trip to a `target-model.json` that matches golden fixtures.
2. `check_cfg` mirroring rejects a deliberately illegal config (non-power-of-two `BTBEntries`;
   `BPIndirectEn` with `BTBEntries=0`; `NrHarts > CVA6_MAX_SMT_HARTS`).
3. The conformance report correctly emits, without hand-coding:
   - `stub` for RVV on `g6lc64_server_math_v` when `vendor/ara/Flist.ara` is absent, **and**
     `overdeclared` against the `v`/`zve64d` tokens in `ariane-server-math-v.dts`;
   - `undeclared` for H on `g6lc64_stream8` (RTL `RVH=1`, DTS omits `h`);
   - `live (fetch_B)` for the instruction supply under `+define+G6LC_FETCH_B`.
4. Re-running `gen` on an unchanged tree is byte-identical.

**Citable as:** a statement about *the repository's own consistency*. The conformance report is
genuinely useful output on its own — it is the first stage that pays for itself.

**Outcome.** Gate met. 21 configuration packages parse (165 fields, 0 unresolved, all legal);
7 device trees parse with topologies matching their documented `N×T` shapes; `gen` is byte-identical
on re-run. The report reproduces the stub-vector and undeclared-H cases unaided, and adds two that
were not previously flagged: the second-level cache is enabled on every target while its RTL is on
no manifest, and `g6lc64_ai` declares one `cpu@` node against a two-core configuration.

Three refinements the soak forced, all recorded in `g6lc_qemu/AGENTS-todo.md`:

- **Presence is three-valued.** A unit missing from an *incomplete* manifest is `unresolved`, not
  `stub`. "Could not tell" is a gap in the inputs; "is a stub" is a claim about the design, and
  conflating them turns a tooling problem into a fabricated hardware finding.
- **Legality splits user-level from derived.** Several of the design's assertions run after its own
  inference, where `0` means *infer* — applying them to source values fails valid packages.
- **The capability table is data**, not code (`g6q-ingest/data/capabilities.ini`, overridable with
  `--capabilities`), because field names, path fragments and device-tree tokens belong to a design
  rather than to the emulator.

---

## Q2 — B0: stock-QEMU driver + OpenSBI ✅ *(emission complete; boot gate pending host tooling)*

**Deliverable** `g6q-emit-args`: generated `.dtb`, `-cpu rv64,<props>`, machine/kernel/initrd/append
argv, plus the **capability delta report** (what stock `virt` cannot express). `g6q fw` drives the
in-tree OpenSBI profile (`PLATFORM=generic`, v1.5, `FW_TEXT_START=0x8000_0000`, `FW_FDT_PATH`).

**Exit gate** `g6q run --backend args --os opensbi-smoke` reaches the OpenSBI banner and the dual-hart
SBI smoke on a stock `qemu-system-riscv64 -M virt`; `--os buildroot` reaches a shell. The delta report
is non-empty and accurate (it must list the memory map, PLIC geometry and the absent island).

**Why this is early:** it debugs DTS generation, the firmware chain, payload layout and rootfs
plumbing *before* any C emitter exists, and it gives the project a working Linux-in-seconds loop from
stage two rather than stage five.

**Progress.** `--emit args` builds the full invocation from the model — processor properties from
**live capabilities only** (a stub is never turned on, or the guest would exercise a feature the
design under test does not provide), plus the capability delta. `--emit dts` / `--emit dtb` work
through an in-tree flattened-tree writer *and* reader, so **no external device-tree compiler is
required**; all seven real trees round-trip with their facts intact. Disks and networking are
refused on the faithful machine, which genuinely has neither.

**Blocked on host tooling, and honestly so.** No emulator, device-tree compiler or cross-toolchain
is installed where this was written, so the exit gate above has *not* been demonstrated and `g6q fw`
is not implemented — building the firmware chain blind against the in-tree profile would be
guesswork. The `qemu` property names in the capability table are likewise unvalidated; most default
to the device-tree token, and a wrong one fails at start-up rather than silently. Closing Q2 needs
an emulator and a toolchain on the host.

---

## Q3 — B3: native Rust VM + `st_rvfi` ◐ *(RV64I/M/A, CSR bank, mret/sret, CLINT/UART/PLIC with M/S-mode software + timer + external delivery, ecall/ebreak/illegal + load/store/fetch M-mode/S-mode traps with mepc/mcause/mtval, medeleg/mideleg, sstatus/sie/sip views, Sv39 page-table walker with 4K/2M/1G leaves, per-access translation, Zicbom/Zicboz no-op decoding, Zacas amocas.w/d, Zba sh[123]add/add.uw/slli.uw, Zbs bset/bclr/binv/bext, mret/sret tests, `run --backend native`, `tandem` CLI, D1 report green; F/D/C/Zbb next)*

**Deliverable** `g6q-vm`: T0 decode-cached interpreter for the target's resolved ISA; faithful
`g6lc-soc` devices (ROM, DRAM, CLINT with deterministic `mtime`, PLIC `NumSources=30`/`NumTargets=16`,
ns16550a UART); Sv39/Sv39x4 walker; trap delivery; `st_rvfi` emitter; `--deterministic`,
`--record`/`--replay`.

**Exit gate**

1. Boots OpenSBI to the S-mode payload on `g6lc-soc`.
2. `g6q tandem --tandem spike` is clean across the directed suites the target already runs
   (`verif/tests/testlist_*` shapes: `mc_stream`, `zacas` minis, `kvm_h` where `RVH` is live).
3. Deterministic replay reproduces a recorded run bit-identically.

**Citable as:** validation *of the emulator*. A tandem-clean B3 is the precondition for trusting
anything in Q5+.

---

## Q4 — B1: generated QEMU machine

**Deliverable** `g6q-emit-qemu`: `g6lc-soc` and `g6lc-virt` machines, CPU variants with extension
gating and honest `mvendorid`/`marchid`/`mimpid`, the SoC devices, and the generated **self-check**
that asserts the built machine's map equals `ariane_soc_pkg.sv`.

**Exit gate** `--os buildroot --machine g6lc-soc --backend qemu` reaches a shell; the self-check passes
(every peripheral base/length, `NumSources`/`NumTargets`, the DRAM window incl. the `NEXYS_VIDEO`
variant); `gen --check` reports no drift.

**Boundary reminder:** the emitted tree is GPL-2.0, gitignored, and produced by an MIT generator that
does not link QEMU ([`README.md`](README.md) §3).

---

## Q5 — D1: tandem, replay, checkpoint → Verilator

**Deliverable** `g6q-diag` D1 tier + the emitted `g6lc_rvfi.c` plugin; first-divergence bisection with
`divergence.json`; `--checkpoint-at` / `--checkpoint-out` in a shape the Verilator testharness can
resume from.

**Exit gate** Take one **known** signature from the existing soak logs — a `hangpc` class, or the
`coldboot_done=0` + WFI at `_start_hang` shape, or a cookie-classification case
([`../multi-threading/testharness-proxy.md`](../multi-threading/testharness-proxy.md) §1.5) —
reproduce it in seconds, and emit a checkpoint that Verilator resumes to the same outcome.

**This is the stage that changes the workflow.** A 200 M-cycle blind soak becomes a targeted
~100 k-instruction window. It is also the stage where the "not evidence" rule matters most: the
resumed **Verilator** run produces the finding; the emulator produced the *pointer*.

---

## Q6 — `Xg6lcai` + island + ai-tensor in-guest

**Deliverable** custom-2 T0 decode and `aicfg`/`aistatus` in B1 and B3; the generated
`g6lc_ai_island` device (CAP window, `CTL@0x100`, doorbell, `desc_ptr@0x118/0x11C`, `DONE@0x10C`,
PMU`@0x180`, AI-3 region checks, PLIC source 8, 64-byte `Desc64`); the ai-tensor **`qemu-uio`**
backend.

**Exit gate** In-guest ai-tensor binds the `g6lc,ai-matrix` UIO node, discovers geometry from the CAP
window, submits a `gemm_s8` descriptor, takes the PLIC-8 interrupt, claims DONE, and matches the same
INT8 golden as `ai_gemm_s8_smoke`. PMU group 4 counters move. Trap fidelity holds (reserved
`funct3=111`, out-of-range tile index, `TileLdEn=0` ⇒ `ai.ldt` illegal, U-mode without `aiperm`).

**Cross-connect:** contract consumed by pin from
[`../ai-matrix/isa-encoding.md`](../ai-matrix/isa-encoding.md); no opcode is defined here.

---

## Q7 — D2: microarchitectural models + PMU groups 0–4

**Deliverable** `g6lc_uarch.c` + `g6lc_pmu.c` plugins and the equivalent in B3: BP (BTB / BHT /
TAGE-lite / loop / ITTAGE / statistical corrector), RAS, FTQ/FDIP/loop-buffer occupancy, I/D/shared
TLB, L1I / HPDCACHE / L2 / L3 with the configured replacement and way-prediction, scoreboard and
issue/commit occupancy, store/load buffers, SMT thread select, coherence traffic — each sized from the
`TargetModel`. PMU groups 0–4 from `perf_counters.sv`, plus Sscofpmf OF/MINH/SINH/UINH and `scountovf`.

**Exit gate** In-guest `perf stat` returns config-shaped counters; the D2 profile **trend-correlates**
with a Verilator run on the same workload — same ranking of hot spots, same order of magnitude.
Equality is explicitly *not* the criterion ([`diagnosis.md`](diagnosis.md) §6), and `mcycle` is
labelled synthetic in every dump.

---

## Q8 — MTTCG scale, `g6lc-virt`, distro rootfs

**Deliverable** `--smp auto` = `NrCores × NrHarts` under MTTCG with correct `cpu-map`; `--tcg-tuning
tuned`; the `g6lc-virt` machine with virtio blk/net/rng/9p/console; `--os ubuntu|debian|fedora`;
`--netdev user --ssh-port`. Optional (and only optional) `build-platform` adapter: a `qemu` command
mirroring `timings.ts`.

**Exit gate**

1. `g6lc64_ooo_server` (S = 4×2 = 8) and `g6lc64_server_math_v` (S = 2×2 = 4) boot SMP Linux on
   `g6lc-soc` with `/proc/cpuinfo` and `lscpu` showing the correct core/thread topology; all CPUs
   come online via HSM; IRQ affinity moves across harts.
2. Ubuntu on `g6lc-virt` reaches a login and accepts SSH over `--net-fwd`.
3. Every `g6lc-virt` artifact is stamped and `diag`/`tandem` refuse it without `--allow-virt-diag`.

**Constraints held:** PLIC `NumTargets=16` ⇒ `S ≤ 8`; `CVA6_MAX_SMT_HARTS = 2`; issue width is not a
hart.

---

## Q9 — Representative Linux capability matrix

**Deliverable** the runnable matrix of [`os-linux-matrix.md`](os-linux-matrix.md) §5 (23 rows), driven
per target, emitting `Pass` / `Fail` / `N/A` with the observation command and raw output, and with
`N/A` justified by the conformance verdict.

**Exit gate** The matrix runs unattended for `g6lc64_smt2`, `g6lc64_server_math_v`, `g6lc64_ooo_server`,
`g6lc64_stream8` and `g6lc64_ai`; every `Fail` is triaged to **config**, **DTS** or **RTL**; every RTL
triage is handed to Verilator with a checkpoint. Rows 21–23 (distro userspace, network, block storage)
are permanently `virt`-tainted and reported separately from rows 1–20.

**Citable as:** a statement that the software-visible surface of a configuration is coherent. Not as
a soak, peel, pin, or Linux-cap result — §4 of [`os-linux-matrix.md`](os-linux-matrix.md) keeps that
bar on the builder.

---

## Cross-stage rules

| Rule | Applies |
|---|---|
| **Not evidence.** Output is a hypothesis + a checkpoint. | every stage |
| **`E-GPLLINK`.** No crate links/includes QEMU; emitted C is a separate work. | Q4, Q5, Q7 |
| **`E-UPSTREAMWRITE`.** Read tier-U files; never edit them. | every stage |
| **Generated, not typed.** A constant in an emitter is a defect. | Q1 onward |
| **Profile discipline.** `g6lc-soc` for anything hardware; `g6lc-virt` stamped and quarantined. | Q4 onward |
| **Determinism before diagnosis.** | Q3 onward |
| **Independence.** `cargo test --workspace` green on fixtures alone, no monorepo path in any `Cargo.toml`. | every stage |
| **Pins, not reinterpretation.** Contract changes bump `pins.toml`. | Q6 especially |

## Deliberate deferrals

| Deferred | Until |
|---|---|
| B3 T1/T2 JIT | profiling shows the interpreter is the bottleneck for a gate |
| Host-hypervisor accel (KVM/WHPX/EPT) | MTTCG plateaus *and* Linux-host-only is acceptable |
| Full RVV/Ara semantics | after Q7; reported `stub` until then |
| OoO / FSE pipeline timing | never — Verilator owns cycles |
| `build-platform` adapter | Q8, optional, never required |
| Third-party Rust dependencies | a recorded decision with supply-chain review |
