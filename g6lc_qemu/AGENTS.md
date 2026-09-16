# g6lc_qemu — Agent Guider (package root)

> **Scope:** This file is the entry point for agents working **inside `g6lc_qemu/`**.
> The package is **project-independent**: it must build, test, and generate its emulation artifacts
> with only this tree + `fixtures/`. Host monorepos (GSys LibreCore / CVA6 `build-platform`) are
> **optional consumers** that pass paths on the command line — they never become crate dependencies.

| Artifact | Path | Role |
|---|---|---|
| **This guider** | `AGENTS.md` | Purpose, invariants, navigation, extension playbook |
| **Live todo / state** | [`AGENTS-todo.md`](AGENTS-todo.md) | Stage checklist; update every pass |
| **Licensing** | [`AGENTS-licensing.md`](AGENTS-licensing.md) | MIT first-party; the **GPL-out boundary** |
| **Architecture index** | [`architecture/README.md`](architecture/README.md) | Map of in-tree design docs |
| **System design** | [`architecture/DESIGN.md`](architecture/DESIGN.md) | End-to-end shape, backends, staging |
| **Ingest** | [`architecture/INGEST.md`](architecture/INGEST.md) | Config / flist / DTS readers |
| **IR** | [`architecture/IR.md`](architecture/IR.md) | `TargetModel` + conformance report |
| **Emission** | [`architecture/EMIT.md`](architecture/EMIT.md) | B0–B3 emitter contract |
| **Diagnosis** | [`architecture/DIAG.md`](architecture/DIAG.md) | D1 tandem / D2 microarchitectural |
| **CLI** | [`architecture/CLI.md`](architecture/CLI.md) | Complete option surface |
| **Human entry** | [`README.md`](README.md) | Quickstart, usable without knowing any monorepo |
| **Terms** | [`LICENSE`](LICENSE) | MIT |

---

## 0. Purpose — a generator, not an emulator you maintain by hand

**`g6lc_qemu` reads a LibreCore-shaped design and generates the machinery to emulate it.**

Inputs are the design's **own** files: the SystemVerilog config packages, the flists that say what is
actually compiled, the SoC package that fixes the memory map, the device trees, and the PMU event
matrix. Outputs are four backends over one IR:

| # | Backend | Output | License of output |
|---|---|---|---|
| **B0** | stock-QEMU driver | argv + `.dtb` + `-cpu` props (**no code emitted**) | — |
| **B1** | QEMU machine + CPU | C into a QEMU checkout | **GPL-2.0**, separate work |
| **B2** | QEMU TCG plugins | C against the plugin ABI | **GPL-2.0**, separate work |
| **B3** | native Rust VM | Rust, in this tree | **MIT** |

…plus a two-tier diagnosis layer: **D1** tandem (RVFI-shaped lockstep, divergence bisection,
checkpoints) and **D2** microarchitectural (structures sized from the config; PMU counters from the
design's own event table).

| What this package **is** | What this package **is not** |
|---|---|
| A generator over config + flist + DTS | A hand-maintained emulator |
| A conformance reporter for design/flist/DTS disagreement | A second source of truth for the ISA |
| An MIT tool that *writes* GPL C | A QEMU fork, or anything that links QEMU |
| A triage and bisection instrument | A source of citable verification evidence |
| A cycle-informative model | A cycle-accurate model |

---

## 1. Prime directives

1. **Independence (KD0).** `cargo test --workspace` and every default command succeed with only this
   tree + `fixtures/`. No compile- or link-time dependency on a monorepo, `build-platform`, Verilator,
   or QEMU. Enforced by `tools/check_independence.py`.
2. **Generated, never typed.** Every ISA / CSR / memory-map / PMU / descriptor constant a backend
   needs is derived from the design's files. **A hard-coded constant in an emitter is a defect**, not
   a shortcut — it creates a second source of truth whose divergence gets misattributed to the RTL.
3. **`E-GPLLINK` — the hard boundary.** No crate under `crates/**` may depend on, `#include`,
   `bindgen`, or link any QEMU header or library. Emission is **text-out only**. See
   [`AGENTS-licensing.md`](AGENTS-licensing.md).
4. **Read-only toward the design.** The generator only *reads* the source tree. It never edits a
   config package, flist, DTS or RTL file, and never touches a copyright / SPDX / attribution line.
5. **Design is law.** Behaviour, backend boundaries and the IR are defined under `architecture/`.
   Update the design (or open a delta in `AGENTS-todo.md`) before a large structural change.
6. **Determinism before diagnosis.** Anything feeding D1/D2 runs with fixed instructions-per-`mtime`
   tick, seeded device timing and recorded MMIO/IRQ. A non-deterministic oracle is not an oracle.
7. **Two machine profiles, never one.** `g6lc-soc` is faithful to the SoC package and is the only
   profile any diagnosis may cite. `g6lc-virt` adds virtio so a distro can boot, and is stamped and
   quarantined. Never merge them.
8. **Not evidence.** Output is a **hypothesis and a checkpoint**. Where this package sits inside a
   verification project, that project's own harness remains the sole source of green.
9. **Pins, not reinterpretation.** External contracts (QEMU rev, OpenSBI ref, ISA/descriptor
   contracts, trace-record layout) live in `pins.toml`. A contract change bumps a pin deliberately;
   bits are never silently reinterpreted.
10. **State.** Every implementation pass updates [`AGENTS-todo.md`](AGENTS-todo.md).

---

## 2. Directory map

```
g6lc_qemu/
  AGENTS.md  AGENTS-todo.md  AGENTS-licensing.md  README.md  LICENSE
  pins.toml                  ← pinned revs: QEMU, OpenSBI, contracts
  platform-constants.toml    ← platform-specific download URLs for host tooling
  Cargo.toml                 ← workspace (first-party path deps only)
  rust-toolchain.toml        ← pinned channel; contained rustup installs it into .tools/
  g6q.sh / g6q.ps1           ← thin wrappers → tools/g6q.py (no business logic)
  architecture/
    README.md DESIGN.md INGEST.md IR.md EMIT.md DIAG.md CLI.md
  tools/
    g6q.py                   ← PRIMARY CLI: setup doctor build test check gen run flist clean env
    env_common.py            ← contained-toolchain paths
    tomlmini.py              ← minimal TOML reader for platform-constants.toml
    platform_constants.py    ← loader for platform-constants.toml
    msvc_env.py              ← MSVC build environment detection (mirrors build-platform/build.ps1)
    flist_expand.py          ← generic ${VAR} / nested -f expander (no project names baked in)
    check_independence.py    ← KD0 + E-GPLLINK enforcement
    g6q_remote.py            ← remote QEMU build/test proxy; uses platform-constants.toml for the pinned xPack toolchain ref
    ai_tensor_bridge.py      ← host bridge over the tensor artifact contract (AI_BRIDGE.md §5)
  crates/
    g6q-svcfg/               ← SystemVerilog config-package reader + legality rules
    g6q-flist/               ← flist expansion + membership facts (Present/Absent/Unknown)
    g6q-dts/                 ← device tree parse + semantic extraction
    g6q-core/                ← TargetModel IR, conformance report, JSON (dependency-free)
    g6q-ingest/              ← assembles the model from the three readers + capability table
    g6q-emit-args/           ← B0: stock-QEMU argv + DTB
    g6q-emit-qemu/           ← B1/B2: QEMU C emitters (text out only)
    g6q-vm/                  ← B3: native Rust virtual machine
    g6q-diag/                ← D1 tandem records + D2 models + PMU
    g6q-cli/                 ← binary `g6lc-qemu` (alias `g6q`)
  fixtures/                  ← miniature config pkg + flist + dts + golden model JSON
  schemas/                   ← target-model.schema.json, conformance.schema.json
  out/                       ← gitignored: emitted artifacts, DTBs, firmware
  qemu/                      ← gitignored: the QEMU checkout emission targets (separate GPL work)
  openwrt/                   ← E3 compile: official OpenWrt + patches/ (MIT scripts)
  linux-dist/                ← etcimon OpenWrt forks (openwrt-*) + ubuntu scaffold; not used at compile
  .tools/                    ← gitignored: contained rustup / cargo / venv
```

---

## 3. Zero-dependency stance (current)

The workspace declares **no external Rust dependencies**. Argv parsing and JSON writing are
hand-rolled `std`-only. This is deliberate:

- `cargo test --workspace` runs offline on a fresh host with no registry fetch — which is what makes
  the independence claim real rather than aspirational.
- It keeps the supply-chain surface at zero for a tool that will be pointed at other people's trees.

Adopting a dependency is a **recorded decision** in `AGENTS-todo.md` plus a `pins.toml` entry, subject
to the usual supply-chain hygiene: pin an exact version, prefer one published at least a week ago, no
floating ranges.

---

## 4. Daily commands

From `g6lc_qemu/`:

```bash
python tools/g6q.py setup       # contained rustup/cargo (+venv) under .tools/
python tools/g6q.py setup-riscv # contained xPack RISC-V cross-toolchain under .tools/ (payloads)
python tools/g6q.py setup-host  # auto-install OpenSBI/qemu/dtc toolchain via package manager
python tools/g6q.py doctor      # host probe: rust, python, qemu, dtc, spike, wsl, riscv cross-toolchain
python tools/g6q.py build
python tools/g6q.py test
python tools/g6q.py check       # GREEN COMMAND: independence + fmt + clippy + test
python tools/g6q.py run -- --help
python tools/g6q.py flist --in entry.f --set ROOT=/abs/project --out portable.f
python tools/g6q.py fetch-qemu   # clone the pinned QEMU source into gitignored qemu/
python tools/g6q.py install-qemu # stage generated B1/B2 sources into qemu/
python tools/g6q.py build-qemu   # configure + build qemu/ (or --dry-run to preview)
python tools/g6q_remote.py remote-build  # sync, configure, build, pull, test on a remote builder
python tools/g6q.py fetch-fw     # clone the pinned OpenSBI source into out/fw-src/
python tools/g6q.py build-fw --fw-fdt auto --target <id> --dts board.dts
python tools/g6q.py bridge       # host AI-tensor bridge wrapper
python tools/g6q.py run -- --build-fw --backend qemu --target <id>  # fetch, build, and run
python tools/g6q.py clean        # cargo target + out/
python tools/g6q.py clean --all # + .tools/ (re-run setup after)
```

Thin wrappers: `./g6q.sh check` · `.\g6q.ps1 check`. **Do not grow logic in the wrappers** — port it
to `tools/g6q.py`.

### Green command

```
python tools/g6q.py check
```

This is the local completion gate. Nothing outside this package substitutes for it.

---

## 5. Extension playbook

| Task | Where |
|---|---|
| Change architecture | `architecture/*.md` + a note in `AGENTS-todo.md` |
| Add a config field to the model | `crates/g6q-svcfg` (reader) + `crates/g6q-core` (IR) + `schemas/target-model.schema.json` + a fixture |
| **Add / retarget a capability** | `crates/g6q-ingest/data/capabilities.ini` — **data, not code**; override at run time with `--capabilities FILE` |
| Add a conformance rule | `crates/g6q-core` + `schemas/conformance.schema.json` + a fixture case |
| Change how the model is assembled | `crates/g6q-ingest` (keeps `g6q-core` dependency-free) |
| Add a DTS property understood semantically | `crates/g6q-dts` + a fixture |
| Add / change a QEMU emitter | `crates/g6q-emit-qemu` — **text out only**, banner + SPDX on every emitted file |
| Add a stock-QEMU capability mapping | `crates/g6q-emit-args` |
| Add an instruction / CSR to the native VM | `crates/g6q-vm`, gated on a model field, never on a literal |
| Add a diagnosis model or PMU event | `crates/g6q-diag` — sized from the model, never hard-coded |
| Add a CLI verb or option | `crates/g6q-cli` + `architecture/CLI.md` |
| Add package automation | `tools/g6q.py` (**not** the shell wrappers) |
| Change how host-pushed accelerator work is packed or retrieved | `tools/ai_tensor_bridge.py` + `architecture/AI_BRIDGE.md`
| Wire package into a host build-platform / CI harness | host adapter (outside this tree); canonical adapter is `build-platform/src/cli/commands/g6q.ts` (`bun build-platform/src/cli/index.ts g6q [--remote] <cmd>`). Package boundary is `tools/g6q.py`, `tools/ai_tensor_bridge.py` and `tools/g6q_remote.py`. The host calls them; they never call back into the host, import from it, or require a host path to pass `check`. | — descriptor geometry comes from the ingested model, never a literal |
| Independence regression | `tools/check_independence.py` |

---

## 6. Standing checklist (every code pass)

- [ ] `AGENTS-todo.md` updated
- [ ] `python tools/g6q.py check` green
- [ ] No new external crate dependency (or: recorded decision + `pins.toml` entry)
- [ ] No QEMU header / library reachable from any crate (`E-GPLLINK`)
- [ ] No hard-coded design constant in an emitter or model
- [ ] Emitted files carry the `DO NOT EDIT` banner and correct SPDX
- [ ] SPDX header on net-new first-party code files (`MIT`)
- [ ] Fixtures-only success criteria preserved (no monorepo path required)
- [ ] `architecture/` still accurate for user-visible behaviour changes
- [ ] Machine profile stamped into any new artifact type
- [ ] A constant the design does not publish is recorded as an ask in
      `architecture/RTL_FEEDBACK.md` and left visibly unresolved — never quietly defaulted
- [ ] Where the design publishes a *set* of names (capabilities, fields, ops), a test pins that set
      so an added name surfaces as a tracked gap instead of becoming a guest-visible zero

---

## 7. Non-goals

- Cycle accuracy, pipeline timing, IPC, or any latency-derived number.
- Replacing an RTL simulator or an ISS as a verification reference.
- Vendoring, forking, or linking QEMU.
- Becoming a build platform, a test runner, or a second control surface for a host project.
- Defining an ISA. Instruction encodings, CSR maps and device ABIs are *consumed by pin* from the
  design's own normative documents.

---

## 8. Current development state (Q4/Q6)

The package is past Q2; the active pass is **Q4/Q6** — the B1/B2/B3 queue-instruction and
AI-island path. Earlier stages (ingest, IR, B0 argv, B3 native VM, D1/D2 scaffolding) are live.

Implemented in the current pass:

- **B1** generated QEMU machine/CPU/AI-island device, instruction decode, `trans_` functions, and
  helpers; builds and boots `g6lc-ai` and `g6lc-g6lc64_smt2`.
- **B2** plugin attaches, emits trace/tensor/PMU artifacts, and reports its own limitations
  (`qemu_plugin_get_registers()` does not expose the RISC-V GPRs on the pinned QEMU).
- **B3** native VM decodes and executes `ai.enq`/`ai.qfence`/`ai.poll`, reads descriptors from
  guest memory, writes completion words back, and produces tensor records.
- Model-driven in-guest payloads (`ai_island_smoke.S`, `ai_island_queue_smoke.S`) compile from
  ingested descriptor/instruction geometry. The linker script is also model-driven:
  `payload_flags.py MODEL --lds-out PATH` writes an `ai_island_smoke.lds` with `soc.dram.base` and
  `soc.dram.len` so the payload is linked at the same DRAM base the native VM / QEMU machine uses.
- `tools/g6q_remote.py` syncs, builds, and tests QEMU B1/B2 on a remote builder with step
  timeouts and ControlMaster reuse; `g6q_remote.py test --ai-island --queue` runs the
  queue-instruction smoke payload instead of the MMIO doorbell payload.

Still open or gated:

- AI-island MMIO `cap_base`/`desc_base`, queue-full/poll-pending return encodings, packed
  capability layouts, and other constants are design-side asks in
  `architecture/RTL_FEEDBACK.md` (F1–F15). The emulator keeps them visibly unresolved rather
  than silently defaulting.
- B2 queue-instruction submission register recovery is limited on the pinned QEMU; B1/B3 cover
  the same path.
- PCIe/virtio host transport for pushed accelerator work remains unpinned.
- Cycle-accurate or latency-derived numbers remain out of scope.

Every completed pass is recorded in [`AGENTS-todo.md`](AGENTS-todo.md). Treat that file as the
authoritative changelog.

---

## 9. Host tooling and cross-platform setup

The package depends on a small set of host tools. **Required:** Python and Rust/Cargo. **Optional:** RISC-V cross-toolchain (OpenSBI), QEMU, DTC, Spike, WSL (Windows). The optional tools are installed by `setup-host`.

### `setup` vs `setup-riscv` vs `setup-host`

| Command | What it installs | Why it exists |
|---|---|---|
| `g6q setup` | contained rustup + Cargo under `.tools/` | `cargo` is required to build the workspace; containment keeps the host clean. |
| `g6q setup-riscv` | contained xPack `riscv-none-elf-gcc` under `.tools/` | Bare-metal toolchain for small payloads and the remote payload compile path. |
| `g6q setup-host` | host OS tools via package manager, standalone download, or source build | OpenSBI needs a **PIE-capable** `riscv64-linux-gnu` toolchain; QEMU and DTC are also managed here. |

`setup-host` detects the platform/package manager, then falls back to the alternatives in `platform-constants.toml`:

- **Windows:** WSL with `apt-get` (default WSL distribution, run as root via `wsl -u root`). If WSL is not available, QEMU can be installed from a pinned Windows installer, and `dtc` can be built from source with `meson` once the MSVC build environment is detected.
- **Linux:** `apt`, `dnf`, `pacman`, or `apk` in that order. If none are present, the OpenSBI toolchain can be installed from a pinned Bootlin tarball and `dtc` built from source.
- **macOS:** `brew`. If `brew` is missing, `dtc` can be built from source.

On Windows, WSL tools are used for OpenSBI, QEMU, and DTC because OpenSBI's Makefile requires POSIX utilities and the Windows xPack linker does not support PIE. `doctor` now reports `wsl <cmd>` for WSL-resolved tools.

Use `setup-host --build-tools` (or `setup-host --build-tools meson ninja`) to install the build tools that `dtc`, `spike`, and other source builds need. When a package manager is unavailable, `meson`, `ninja`, and `cmake` are installed via `pip` into `.tools/python-venv`; `bison` and `flex` require a package manager or manual install.

On Windows, `setup-host` runs a smart preflight. If Chocolatey, WSL, or MSVC is missing for the requested operation, it either prompts for the desired fix (install Chocolatey, install Visual Studio Build Tools via Chocolatey, or print WSL instructions) or, with `--yes`, installs the missing pieces automatically. Use `--vs-year` to pick a Visual Studio year (`2022`, `2025`, or `2026`; default `2022`).

### Typical first-time setup

```bash
python tools/g6q.py setup              # contained Rust toolchain
python tools/g6q.py setup-riscv        # contained bare-metal xPack (payloads)
python tools/g6q.py setup-host --all   # PIE toolchain, qemu, dtc in WSL/Linux/macOS
python tools/g6q.py doctor             # verify everything
python tools/g6q.py check              # GREEN gate
```

`--spike` is not packaged; the command prints build-from-source instructions.

---

## OpenWrt console and graphics probe (2026-09-14)

The existing `out/loader-run/openwrt/initramfs-Image` boots through OpenSBI 1.5
and `qemu/build/qemu-system-riscv64` 10.0.0 to OpenWrt 24.10.2 / Linux 6.6.93.
Use the explicit `g6lc-virt` / stock `virt` profile; this is not RTL evidence.
The sifiveu rootfs starts gettys on `ttySIF0` and `tty1`, so adding a virtio
console alone does not supply a login on QEMU's `ttyS0`. For an isolated test,
use an external newc initramfs containing only `etc/inittab`, retaining the
sysinit/shutdown entries and using `ttyS0::askfirst:/usr/libexec/login.sh`.
The tested artifact is `out/openwrt-apu-probe/console.cpio`; the original image
and firmware remain unchanged. Windows `tar.exe --format=newc` can create it
when WSL lacks `cpio`.

```text
python tools/g6q.py run -- --backend qemu --target g6lc64_smt2 --repo-root .. --os openwrt --machine g6lc-virt --stock-machine virt --qemu-path qemu/build/qemu-system-riscv64 --fw out/fw/fw_dynamic-generic-virt.bin --initrd out/openwrt-apu-probe/console.cpio --smp 1 --mem-size 1G --virtio gpu --wsl
```

For automation, `--send-on "Please press Enter=\n"` activates the console;
the early prompt is `root@(none):~#`, so match `:~#` rather than assuming the
hostname or working directory. Generate completion markers with `printf PREFIX_%s DONE`
so serial echo cannot satisfy `--expect PREFIX_DONE` before commands execute.

The remote graphics baseline now uses the pinned OpenWrt 24.10.2 image with
DRM/KMS, `virtio_gpu`, Mesa 21.3, libdrm, the in-tree `g6lc-egl-probe` and
its opt-in `g6lc-virgl-negprobe` companion, plus remote QEMU 10.0.0 configured
with OpenGL/epoxy, virglrenderer, GBM, pixman and vhost-user. The testharness
host has only `/dev/dri/card0` backed by `simple-framebuffer`, so in-process
`-device virtio-gpu-gl-device -display egl-headless,gl=on` still fails before
guest boot (`egl: no drm render node available`). The working headless path is
QEMU's unchanged `vhost-user-gpu` frontend plus the contrib backend, with
`openwrt/vugpu-virgl-surfaceless.c` preloaded only into that backend so
virglrenderer selects Mesa surfaceless GLES on llvmpipe. Run it through the
authenticated testharness transport:

```bash
python openwrt/push-overlay.py
python openwrt/remote-gfx-probe.py --mode vugpu
python openwrt/remote-gfx-probe.py --mode vugpu --audit
python openwrt/remote-gfx-probe.py --mode vugpu --negative
python openwrt/remote-gfx-probe.py --mode vugpu --audit --cap-profile gles2-min
```

The probe forces modern virtio-mmio (`virtio-mmio.force-legacy=false`), uses
shared memfd memory, disables scanouts (`max_outputs=0`), decompresses the
packaged gzip initramfs kernel automatically, and collects logs under
`out/remote-gfx/<tag>/`. The normal run was verified again after the
negative-probe image rebuild in `out/remote-gfx/gfx-20260914T203512Z/`:
guest `+virgl`, two capsets (virgl v1 size 308; virgl2 v2 size 1384),
`/dev/dri/renderD128`, EGL 1.4 on a real `gbm-window` surface, renderer
`virgl (LLVMPIPE (LLVM 20.1.2, 256 bits))`, stable `G6LC_PIXEL_FNV1A=0x3d667145`,
`G6LC_EGL_GLES2_DRIVER=virgl`, `G6LC_EGL_GLES2_OK`, `G6LC_GFX_DONE rc=0`, and
`G6LC_GFX_RESULT=PASS`.

`--audit` adds `g6lc_audit=1`, keeps the unchanged guest stack, runs
`g6lc-egl-probe audit`, and validates the capture with `--expect-audit`. The
archived run `out/remote-gfx/gfx-audit-20260914T213500Z/` reports
`G6LC_AUDIT_PIXEL_FNV1A=0x35f36230`, `G6LC_AUDIT_RESULT=PASS` and strict capture
`result=PASS`. Its five submitted command buffers exercise texture upload and
sampling, packed sampler-view target/format/level fields, sampler state,
fragment constant data, an indexed draw, scissor state, state-object creation
and binding, readback transfers, object destruction and context cleanup. Nine
fences cover 3D resource creation, command submission and transfer traffic.
This remains host llvmpipe software-rendered evidence for the external driver
contract, not APU RTL or hardware rendering proof.

`--negative` adds `g6lc_neg=1`, replaces only the guest probe binary, and keeps
the QEMU/Linux/Mesa path unchanged. `out/remote-gfx/gfx-20260914T203421Z/`
archives the resulting API events and malformed command buffers. The unchanged
driver rejects bad capset IDs, absent context-init, and invalid BO lookup locally
(`EINVAL`/`ENOENT`). Invalid 3D resource creation, out-of-bounds transfer, an
unknown virgl opcode, and a truncated command are queued through virtio and then
reported by the backend as `EINVAL`; their virtio fences still complete and the
guest ioctls may report success. `summarize-virgl-capture.py --strict
--expect-errors` reports `result=PASS` for that run. The `Failed to register
client: -95` line remains the expected fbdev/KMS-client failure when scanouts are
disabled. All of this is host software-rendered virgl evidence over the unchanged
Linux/Mesa driver path, not APU/RTL or physical-GPU evidence.

`--cap-profile gles2-min` masks the host backend's capset to the reduced
contract documented in `g6lc_bios/architecture/DISPLAY.md` while leaving QEMU,
Linux and Mesa unchanged. `out/remote-gfx/gfx-20260914T221515Z/` passed the
full audit with `bset=0`, `capability_bits=0`, `capability_bits_v2=0`, API-level
transfers instead of `TRANSFER3D`, `BLIT`, sampler views/states, indexed draw,
constant data and cleanup. `gfx-20260914T221551Z/` passed the same reduced
capset under `--expect-errors`. The optional `gles2-xfer` profile retains only
`VIRGL_CAP_TRANSFER` and passed in `gfx-20260914T221800Z/`. These are still
llvmpipe-rendered contract probes, not APU RTL or hardware acceleration proof.

## 10. Firmware and QEMU build flow

The firmware chain is independent from the QEMU build chain. Both emit artifacts into gitignored `out/` and `qemu/`.

### Firmware

```bash
python tools/g6q.py fetch-fw   # clone OpenSBI v1.5 into out/fw-src/opensbi
python tools/g6q.py build-fw --fw-fdt auto --target fixtures/mini --dts fixtures/mini/board.dts
```

`build-fw` uses `g6lc-qemu fw build`, which:

1. Resolves the target model and DTS.
2. Applies overlays/mutations.
3. Writes `out/fw/fdt_auto.dtb` (or `--fw-out`) when `--fw-fdt auto`.
4. Invokes `make` in the OpenSBI source.

On Windows, it auto-detects WSL and a PIE toolchain, translates source/FDT/payload paths to WSL absolute paths, and runs `wsl make -C ... CROSS_COMPILE=riscv64-linux-gnu- ...`. The output is staged as `out/fw/fw_dynamic.{bin,elf}`.

### QEMU

```bash
python tools/g6q.py fetch-qemu          # clone the pinned QEMU into qemu/
python tools/g6q.py install-qemu        # stage generated B1/B2 C into qemu/
python tools/g6q.py build-qemu          # configure and build qemu/
```

`build-qemu` is a separate GPL-2.0 work and is never linked by `crates/**`.

### Remote build/test

For hosts where a local QEMU B1/B2 build is impractical, `tools/g6q_remote.py` is a build/test proxy that syncs `qemu/` to a remote Linux builder, runs `configure`/`ninja`, and pulls the resulting `qemu-system-riscv64` back. It uses `platform-constants.toml` for the pinned xPack RISC-V toolchain `ref` and probes the remote for cross-compilers.

Commands: `doctor`, `sync`, `configure`, `build`, `pull`, `run`, `test`, `clean`, `remote-build`.

```bash
python tools/g6q_remote.py doctor       # probe ssh/rsync and remote toolchain
python tools/g6q_remote.py remote-build # sync, configure, build, pull, smoke
python tools/g6q_remote.py build --step-timeout 3600   # ceiling for one remote step
python tools/g6q_remote.py test --ai-island --queue --model out/ai_soc_model.json  # queue-instruction smoke
```

Remote connection and toolchain discovery are controlled by environment variables. Fresh hosts
should set `G6Q_REMOTE_HOST` and `G6Q_REMOTE_ROOT`; the defaults below are the original
`ovh_calltorch` testharness layout and are only retained for backwards compatibility.

| Variable | Default | Meaning |
|---|---|---|
| `G6Q_REMOTE_HOST` | `ovh_calltorch` | SSH host for the builder |
| `G6Q_REMOTE_ROOT` | `/opt/testharness/g6lc-qemu` | Remote work root (`<root>/repo/qemu`, `<root>/build/qemu`, `<root>/runs`) |
| `G6Q_REMOTE_KEY` | — | Path to SSH private key (passphrase via `G6Q_REMOTE_PASS` or first line of `G6Q_REMOTE_CREDS`) |
| `G6Q_REMOTE_XPACK_BIN` | derived from `platform-constants.toml` | Remote xPack `.../bin` directory; overrides the pinned toolchain path |
| `G6Q_SSH_BIN` | `ssh` | SSH command (supports `wsl ssh` on Windows) |
| `G6Q_RSYNC_BIN` | `rsync` | Rsync command (supports `wsl rsync` on Windows) |
| `G6Q_SSH_CONTROL` | `/tmp/g6q-remote-<uid>-<host>.sock` | SSH ControlMaster socket path |

Every remote step has a wall-clock ceiling (`--step-timeout SECONDS`, `0` to disable). A wedged
builder must make the pass **fail**, not hang: an SSH session that never returns is
indistinguishable from a slow one, and a pass that neither succeeds nor fails is the worst outcome
for an automated gate. Defaults are per step (configure 30 min, build 2 h, run 15 min, rsync 30 min,
doctor/toolchain probes 60 s/30 s, smoke timeout = `--timeout` + 30 s).

In-guest payloads are linked with `PAYLOAD_LINK_FLAGS` (`-nostdlib -nostartfiles -static -no-pie
-Wl,--build-id=none`) and a model-generated linker script. These are load-bearing, not hygiene —
see the linker-script comment in `tools/remote/payload/ai_island_smoke.lds`: a Linux-targeting cross
compiler otherwise emits a dynamic executable whose LOAD segment lands *below* DRAM base, and the
payload then hangs with no output at all. A bare-metal toolchain hides the problem, so it only
surfaces when the builder's toolchain changes. `payload_flags.py MODEL --lds-out PATH` generates a
linker script with `soc.dram.base` / `soc.dram.len` from the model, and `tools/g6q_remote.py`
uses it automatically for both local and remote payload compiles.

---

## 11. Navigating the CLI and architecture

The CLI has two layers:

1. **Rust binary `g6lc-qemu` (`crates/g6q-cli/src/main.rs`)** — the option parser, model resolution, emitters, and `run` harness.
2. **Python wrapper `tools/g6q.py`** — host setup, Cargo invocation, QEMU/OpenSBI fetch and build, and the `check` green gate.

### Where options are defined

- `architecture/CLI.md` is the complete option surface. Add an option there first.
- `crates/g6q-cli/src/args.rs` (or `main.rs` if still in one file) parses and validates options.
- `crates/g6q-cli/src/resolve.rs` resolves inputs into a `TargetModel`.
- `crates/g6q-cli/src/main.rs` dispatches verbs.
- `tools/g6q.py` exposes Python-level subcommands and forwards the right argv to `g6lc-qemu`.

### Adding a feature

1. Read the relevant `architecture/*.md` and the [extension playbook](#5-extension-playbook) above.
2. Update the architecture doc if the user-visible surface changes.
3. Implement in the appropriate crate.
4. Add/extend `g6q-cli` tests; do not rely on the host monorepo.
5. Mirror any new `g6lc-qemu` option in `tools/g6q.py` if it is exposed at the package level.
6. Run `python tools/g6q.py check`.
7. Update `AGENTS-todo.md`.

### Command-to-crate map

| `g6q.py` command | Rust verb / crate | Design doc |
|---|---|---|
| `setup` | `tools/g6q.py` + `env_common.py` | `AGENTS.md` §9 |
| `setup-riscv` | `tools/g6q.py` + `platform-constants.toml` | `AGENTS.md` §9 |
| `setup-host` | `tools/g6q.py` + `platform_constants.py` + `platform-constants.toml` | `architecture/CLI.md` §9 |
| `conform` | `g6lc-qemu conform` | `IR.md` |
| `gen` | `g6lc-qemu gen` | `EMIT.md` |
| `emit` (in `gen`) | `g6lc-qemu --emit ...` | `EMIT.md` |
| `run` | `g6lc-qemu run` | `CLI.md`, `DIAG.md` |
| `flist` | uses `tools/flist_expand.py` | `INGEST.md` |
| `fetch-fw` / `build-fw` | `g6lc-qemu fw fetch/build` | `CLI.md` |
| `fetch-qemu` / `build-qemu` | `g6q.py` drives git + make (or `g6q_remote.py` for remote builds) | `EMIT.md`, `AGENTS-licensing.md` |
| `remote-build` | `tools/g6q_remote.py` | `AGENTS.md` §10 |
| `bridge` | `tools/ai_tensor_bridge.py` | `AI_BRIDGE.md` |
| `remote` | `tools/g6q_remote.py` | `AGENTS.md` (host boundary) |

### Independence gate

Every change must still pass `tools/check_independence.py`:

- no crate depends on an external Rust dependency (unless recorded).
- no crate links or includes QEMU headers/libraries.
- `fixtures/` are sufficient for `cargo test --workspace` and `python tools/g6q.py check`.

If a feature cannot meet these invariants, it belongs outside the package (host adapter, remote builder, etc.) and must be called through the documented boundary: `tools/g6q.py`, `tools/ai_tensor_bridge.py`, `tools/g6q_remote.py`.
