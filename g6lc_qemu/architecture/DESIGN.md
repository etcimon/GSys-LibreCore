# DESIGN — end-to-end shape

Index: [`README.md`](README.md). Invariants: [`../AGENTS.md`](../AGENTS.md).

---

## 1. What the package does

It reads a RISC-V design's own description of itself and produces the machinery to emulate that
design, plus a way to relate what the emulator did back to the hardware description.

```text
   config packages ─┐
   flists           ├──► ingest ──► TargetModel (JSON) ──┬──► B0 stock-QEMU argv + DTB
   SoC package      │        │                           ├──► B1 QEMU machine/CPU/device C
   device trees     │        └──► conformance report     ├──► B2 QEMU TCG plugins C
   PMU event table ─┘                                    └──► B3 native Rust VM
                                                                    │
                                                          D1 tandem │ D2 microarchitectural
```

Every backend reads the `TargetModel` and nothing else. That single constraint is what keeps them
consistent with each other and with the design.

## 2. The three inputs and their disagreements

> The flist decides what is **real**. The config decides what is **enabled**. The device tree decides
> what **software is told**.

| Input | Answers |
|---|---|
| Configuration packages | which features are enabled; how big each structure is |
| Flists (+ `+define+` set) | which RTL is actually compiled into the elaborated design |
| Device trees | what the operating system is told exists |

These routinely disagree, and each disagreement is a finding rather than an inconvenience:

- a vector extension enabled in configuration while the vector unit is **not on the flist** means the
  elaborated design has a stub — an emulator that executes vector instructions here is lying;
- an extension live in RTL but absent from the device tree is invisible to the guest;
- an extension advertised in the device tree but not live in RTL is a **guest-visible lie** and the
  emulator must refuse to reproduce it.

So the first-class output of ingest is not code, it is the **conformance report** ([`IR.md`](IR.md)
§3). `--conform strict` refuses to emulate anything not `live`.

## 3. Backends

| # | Backend | Emits | Output licence | Purpose |
|---|---|---|---|---|
| **B0** | stock-QEMU driver | argv, `-cpu` props, a generated DTB, and a **capability delta report** | none (no code) | day-one boot on an approximation; debugs firmware / DTS / rootfs plumbing before any emitter exists |
| **B1** | QEMU machine + CPU | C into a QEMU checkout | GPL-2.0, separate work | faithful full system |
| **B2** | QEMU TCG plugins | C against the plugin ABI | GPL-2.0, separate work | diagnosis inside QEMU |
| **B3** | native Rust VM | Rust, in-tree | MIT | tandem oracle, deterministic replay, checkpoints, CI without a QEMU build |

B3 is not a luxury. It is what keeps a working fast path and the whole diagnosis tier inside MIT, so
continuous integration never depends on building a GPL emulator. Its first tier is a decode-cached
threaded interpreter; JIT tiers are deferred until profiling justifies them.

**Emission is text-out only.** No crate links, includes or binds QEMU
([`../AGENTS-licensing.md`](../AGENTS-licensing.md) §2).

## 4. Machine profiles

| | `g6lc-soc` (default) | `g6lc-virt` |
|---|---|---|
| Memory map | byte-faithful to the design's SoC package | `g6lc-soc` + a virtio window |
| Storage / network | **none** | virtio-mmio blk / net / rng / 9p / console |
| RAM | exactly what the design specifies | configurable, may exceed the real part |
| Valid for | **all** diagnosis, tandem, checkpoints, memory-map and interrupt-topology questions | operating-system bring-up only |

A faithful embedded SoC generally cannot boot a distribution rootfs — no disk, no NIC, limited DRAM.
That is a property of the silicon, not a defect to route around. `g6lc-virt` exists so *software*
questions can be asked; its answers are invalid for hardware questions.

Enforcement, because this is the rule most likely to be violated in practice:

1. `profile` is a field of the `TargetModel` and is stamped into every artifact, trace header and
   JSON result;
2. `diag` and `tandem` refuse `g6lc-virt` unless `--allow-virt-diag` is given, and then taint the
   output;
3. the B1 memory-map self-check asserts only under `g6lc-soc`, and reports deltas under `g6lc-virt`.

## 5. Acceleration

**TCG, tuned. No host-hypervisor backend.**

The guest ISA is not the host ISA, so no hardware virtualisation extension can execute guest
instructions. The only thing a hypervisor offers a cross-ISA emulator is realising the guest address
space in host page tables so translated memory accesses skip the software TLB. That is a real
speed-up and a large, single-host-OS, hard-to-debug subsystem sitting under every diagnosis result.
Deferred, with a reopen condition recorded in [`../AGENTS-todo.md`](../AGENTS-todo.md).

Invested instead: multi-threaded TCG with one vCPU thread per **logical hart**
(`cores × threads-per-core`, bounded by the design's interrupt-controller context count),
translation-block chaining, TB-cache and softmmu sizing derived from the model, and correct atomic /
fence lowering.

Rough throughput, orders of magnitude only:

| Path | Rough |
|---|---|
| RTL simulation | 10–100 kIPS |
| reference ISS | 20–100 MIPS |
| B3 interpreter | 10–50 MIPS |
| B1 QEMU TCG | 200–500 MIPS |
| B1 + D2 instrumentation | 5–30 MIPS |

"Almost native" means *an interactive guest*, not host parity. The honest claim is roughly four
orders of magnitude faster than RTL simulation, which is what changes the workflow.

## 6. Diagnosis, in one paragraph

Two tiers, never the same run. **D1** emits RVFI-shaped commit records, runs lockstep against a
reference implementation or a captured RTL trace, and reports the *first* divergent instruction —
then exports a checkpoint so a cycle-exact simulator resumes the last hundred thousand instructions
instead of re-running the boot. **D2** models the structures the configuration parameterises
(predictors, TLBs, caches, scoreboard, thread select) at their configured sizes and emits the design's
own PMU events, so counters read inside the guest are comparable with counters from RTL. D1 is exact
where it claims to be; D2 is *informative* and reports no cycles. Detail: [`DIAG.md`](DIAG.md).

## 7. Staging

| Stage | Deliverable |
|---|---|
| **Q0** | scaffold, package surface, crate skeletons *(done)* |
| **Q1** | ingest, `TargetModel`, conformance |
| **Q2** | B0 driver + firmware chain |
| **Q3** | B3 interpreter + faithful devices + tandem records |
| **Q4** | B1 generated machine + memory-map self-check |
| **Q5** | D1 tandem, replay, checkpoint hand-off |
| **Q6** | accelerator ISA + device model + in-guest runtime |
| **Q7** | D2 models + PMU |
| **Q8** | MTTCG scale + virt profile + distribution rootfs |
| **Q9** | capability matrix |

Q1 is load-bearing: nothing downstream exists without the model. Q2 is deliberately early so that
firmware, device tree and rootfs plumbing are debugged before any C emitter is written.

## 8. Non-goals

Cycle accuracy · replacing an RTL simulator or an ISS as a verification reference · forking or linking
QEMU · defining an ISA · becoming a build platform.
