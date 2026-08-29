# g6lc_qemu — live todo / stage state

In-tree queue for this package. **Retrieval contract:** every open item cites where its priors live —
by default this package's own `architecture/` docs; where a host project supplies the normative
contract, the pin in `pins.toml` plus the document it names.

| Layer | Open first | Role |
|---|---|---|
| Why / invariants | [`AGENTS.md`](AGENTS.md) | Independence, `E-GPLLINK`, generated-not-typed, profile rule |
| Licensing boundary | [`AGENTS-licensing.md`](AGENTS-licensing.md) | MIT in, GPL out, enforcement |
| Design | [`architecture/DESIGN.md`](architecture/DESIGN.md) | Backends, staging, structure |
| Ingest / IR | [`architecture/INGEST.md`](architecture/INGEST.md) · [`architecture/IR.md`](architecture/IR.md) | Readers, `TargetModel`, conformance |
| Emission | [`architecture/EMIT.md`](architecture/EMIT.md) | Emitter contract |
| Diagnosis | [`architecture/DIAG.md`](architecture/DIAG.md) | D1 / D2 tiers, error bars |
| CLI | [`architecture/CLI.md`](architecture/CLI.md) | Option surface |

**Green command:** `python tools/g6q.py check`

---

## Current stage

**Q1 — ingest, `TargetModel`, conformance. Complete.**

The three readers work against real input, the model assembles from them, and `gen` / `conform` are
live. Nothing is emitted or executed yet.

Verified against a real design tree (opt-in soaks, `G6Q_DESIGN_ROOT`): **21 configuration packages**
parse at 165 fields with **0 unresolved** and all legal; **7 device trees** parse with topologies
matching their documented `cores × threads` shapes; model generation is **byte-identical** on re-run.

Findings the conformance report produces unaided, each an inputs disagreement rather than a rule
written for it:

| Target | Finding |
|---|---|
| vector-enabled target | `stub` **+** `overdeclared` — enabled in configuration, vector manifest not in the build, tree still advertises the tokens |
| all targets | second-level cache `stub` — enabled in configuration, its RTL on no manifest |
| two targets | hypervisor `undeclared` — live in RTL, token deliberately omitted from the tree |
| all targets | NAPOT pages `undeclared` |
| accelerator target | **topology**: 2 logical harts in configuration, 1 `cpu@` node in the tree — software would see one |

| Stage | State |
|---|---|
| **Q0** scaffold, package surface, Rust skeleton | **done** |
| **Q1** ingest + `TargetModel` + conformance | **done** — `timebase-frequency` extracted from DTS into `Facts.timebase_hz`, carried in `Isa.timebase_hz`; `chosen/bootargs` extracted into `Facts.bootargs`, carried in `Soc.bootargs`; `cpu-map` topology (`cores`, `threads_per_core`) extracted from DTS and config into `Soc`; all consumed by the B1 FDT emitter; `g6q-dts` path mutation module (`set`/`del`/`merge`) supports `--dts-set PATH=VALUE`, `--dts-del PATH`, and `--dts-overlay FILE` with missing-node creation, quote stripping, and value parsing for both string and cell-list properties; `resolve.rs` and `gen --emit dts|dtb` apply overlays then per-property mutations before fact extraction / output; `Node::to_dts` added for source rendering; schema updated |
| **Q2** B0 stock-QEMU driver + firmware chain | **in progress** — B0 argv/delta emission complete; `run` now supports `--backend args` (print stock-QEMU argv) and `--backend qemu` (spawn `qemu-system-riscv64` with `--qemu-path`, `--dry-run`); `fw` verb implemented with `Firmware`/`BootOptions` JSON inspection and `--fw-print-region` raw-size report; `python tools/g6q.py fetch-qemu` implemented with `--url`/`--ref`/`--full`/`--dry-run` overrides and `--depth 1` shallow default; the pinned QEMU v10.0.0 source is now in `qemu/` (gitignored, separate GPL work); `pins.toml` status updated to `fetched`; `python tools/g6q.py build-qemu` added with `--target`, `--debug`, `--mingw`, `--configure-only`, `--clean`, and `--dry-run`; it probes for python/bash/ninja and prints the configure/ninja commands in dry-run mode; `python tools/g6q.py install-qemu` added with `--package` and `--dry-run`; it builds `g6lc-qemu`, runs `gen --emit qemu`, copies C/FDT/plugin source files into the QEMU tree, and appends build-wiring fragments to `hw/riscv/Kconfig`, `configs/targets/riscv64-softmmu.mak`, `hw/riscv/meson.build`, and `target/riscv/meson.build`; plugin wiring still requires manual `contrib/plugins/meson.build` edit; `build-qemu` now runs WSL/bash out-of-tree `configure` and `ninja` on Windows and defaults to `--disable-libvduse --disable-vduse-blk-export --disable-vhost-user --disable-vhost-user-blk-server` to avoid NTFS/WSL symlink issues; host `qemu-system-riscv64` built and `--version` succeeds; remaining: host-QEMU boot gate with a real kernel/image |
| **Q3** B3 native VM + tandem records | **in progress** — RV64I/M/A interpreter, CSR bank, mret/sret, Zicsr, CLINT/UART/PLIC with M/S-mode software + timer + external delivery, ecall/ebreak/illegal + load/store/fetch M-mode/S-mode traps with mepc/mcause/mtval, medeleg/mideleg, sstatus/sie/sip views, Sv39 page-table walker with 4K/2M/1G leaves, per-access translation, Zicbom/Zicboz no-op decoding, Zacas amocas.w/d, Zba sh[123]add/add.uw/slli.uw, Zbs bset/bclr/binv/bext, Zbb andn/orn/xnor, clz/ctz/cpop, clzw/ctzw/cpopw, min/max/minu/maxu, rol/ror/rori, rolw/rorw/roriw, rev8, orc.b, sext.b/sext.h, zext.h (RV32/RV64), RVC compressed (16-bit fetch, RV32C/RV64C expansion, control flow, stack-relative loads/stores), mret/sret tests, `run --backend native`, `tandem` CLI, D1 report library green; commit record extended with trap `cause`, `prv` and `halt` fields and a separate `record_order` counter so future trap and checkpoint records have their own index; F single-precision and D double-precision opcodes implemented; FP hardening pass done — explicit IEEE-754 rounding, OF/UF/NX/NV/DZ flag tracking and NaN canonicalisation cover all F/D <-> integer and F <-> D conversions; f32 arithmetic and FMA are rounded from an f64 intermediate; f32 FMA now uses one `f64::mul_add` rounding before the f32 final rounding; f64 FMA uses one host `f64::mul_add` rounding; f64 arithmetic improves OF/DZ/NV reporting; min/max/compare/sign-injection handle sNaN/qNaN and signed zero; FP edge-case unit tests added; `run --backend native` now resolves the target, assembles a `TargetModel`, and derives the reset vector, `xlen`, CLINT/PLIC/UART base addresses and PLIC source/target counts from the model, with hard-coded fallback addresses only when the model is silent; `chosen/stdout-path` extracted from DTS into `Facts.stdout_path`, carried in `Soc.stdout_path`, emitted in B1 FDT when present and otherwise derived from a UART peripheral; f64 add/sub/mul now honour RNE/RTZ/RDN/RUP/RMM using `two_sum`/`two_prod` error-free transforms and `f64_round_two`, set NX for inexact results and OF/UF for overflow/underflow, and produce directed-overflow rounding (e.g. RTZ/RDN round to max finite); unit test `f64_directed_rounding_sets_nx_and_picks_the_right_bracket` covers ties and brackets; div/sqrt/fma still use host single rounding and ignore rm; remaining: full directed rounding for f64 div/sqrt/fma and exact UF for subnormal products/FMA (requires a wider accumulator) |
| **Q4** B1/B2 generated QEMU machine and plugin | **in progress** — B1: machine/CPU/build-wiring emitters; machine emitter now supports `Soc.virtio_mmio` and the `--virtio-mmio N` CLI option; B1: model-driven MROM via `Soc.bootrom` and `--bootrom BASE:LEN`; B1: generated FDT as `hw/riscv/g6lc-<target>-dtb.c/h` embedded blob with model-derived `/cpus/timebase-frequency`, `/cpus/cpu-map` cluster/core/thread topology using numeric phandles, `/chosen/bootargs` and `/chosen/stdout-path` derived from a UART peripheral, `/memory`, `/soc/plic`, `/soc/clint` and memory-mapped peripherals; CLINT `interrupts-extended` wired to each hart's CPU intc with M-mode software (3) and M-mode timer (7); PLIC `interrupts-extended` and `interrupt-parent` use numeric phandles; `machine_init` loads the FDT (or user `-dtb`) and places it via `riscv_compute_fdt_addr`/`riscv_load_fdt`; `gen --emit qemu-machine` and `gen --emit qemu` include the FDT artifacts; B2: `gen --emit qemu-plugin` writes `contrib/plugins/g6lc-<target>.c` for the v4+ TCG plugin API; `gen --emit qemu` generates all B1/B2 artifacts; all GPL-header; build-wiring updated to QEMU v10's `configs/targets/riscv64-softmmu.mak` path and the `minikconf`-safe syntax (`bool` with no prompt, `depends on RISCV32 || RISCV64`, `riscv_ss.add(when: ...)`); `python tools/g6q.py install-qemu` can stage the generated sources and append the easy build wiring into a fetched `qemu/` checkout; **B1 generated machine and CPU now compile against QEMU v10.0.0** (`cpu-qom.h`, `RISCV_CPU_TYPE_NAME`, `TYPE_RISCV_CPU_BASE`, `misa_mxl_max`, `riscv_cpu_set_misa_ext`, `object_property_set_*` + `sysbus_realize` for the hart array, `qapi/error.h` for `error_fatal`, `system/device_tree.h` for `load_device_tree`, `<stddef.h>` in the embedded DTB C); `python tools/g6q.py build-qemu` produces a working `qemu-system-riscv64`; `qemu-system-riscv64 -M g6lc-unnamed -m 256 -nographic -bios default` now boots OpenSBI v1.5.1, prints the platform banner, and reports a valid `Domain0 Next Address` (0x80200000); remaining: boot a real S-mode payload/kernel image and validate reset-vector/FDT/peripheral behavior |
| **Q5** D1 tandem / replay / checkpoint | **in progress** — comparison + report library green; CLI `tandem` verb; `RecordFile` with artifact header + `read_record_file`/`write_record_file`; `run --record FILE` writes a stamped record file; `tandem` accepts both record files and plain record arrays; `architecture/CLI.md` updated to `--bootrom BASE:LEN` and `--record FILE`; `g6q-diag` `Checkpoint` type added with hart state, physical memory and device-state schema; `g6q-vm` `Hart::checkpoint`/`restore` and `PhysMem::snapshot`/`restore` round-trip; `run --backend native --checkpoint FILE` writes a resumable checkpoint; `architecture/CLI.md` updated; full CLINT/PLIC/UART state captured and restored via `MmioDevice::snapshot`/`restore`; `Halt::ReplayDivergence` and `Hart::run_replay` added with record-by-record diff; `run --backend native --replay FILE` replays against a `RecordFile` and fails on divergence; Q5 core D1 checkpoint/replay stack complete |
| **Q6** accelerator ISA + device + in-guest runtime | **in progress — scaffold** |
| **Q7** D2 microarchitectural + PMU | **in progress** — PMU event table and `Uarch` raw map landed; D2 structure-size counters (`uarch.*`) scaffolded; **PMU FDT/CPU mapping landed**: OpenSBI-compatible `/pmu` node with `riscv,event-to-mhpmcounters` (fixed `mcycle`/`minstret`), `riscv,raw-event-to-mhpmcounters` from ingested design events, `interrupts-extended` for Sscofpmf LCOFIP, and generated QEMU CPU `ext_zihpm`/`ext_sscofpmf`/`pmu_mask`; B0 `-cpu` appends `pmu-mask` when `zihpm` is live; **B2 PMU counter plugin landed**: `g6q-emit-qemu/src/pmu.rs` generates `contrib/plugins/g6lc-<target>-pmu.c` from the published `PmuTable` (event names, groups, and `mhpmevent` selectors), registers per-hart instruction counters and a per-hart/per-event counter array, and writes a counters JSON at exit; `gen --emit qemu-pmu-plugin` is wired; `gen --emit qemu` includes it. |
| **Q8** MTTCG scale + virt profile + distro | **in progress** — B0 stock-QEMU driver now derives `-smp` from `harts_total` or the model's core/threads-per-core topology, emits `maxcpus` as a hotplug ceiling, parses `--icount N|off` and `--tcg-tuning default|tuned`, forces single-threaded TCG when icount is on (MTTCG and icount are mutually exclusive), allows explicit multi-threaded TCG with `tuned`, parses `--rootfs-format raw|qcow2`, `--console uart|virtio`, `--virtio rng`, `--os buildroot|ubuntu|debian|fedora` (forces `g6lc-virt`, `qcow2` default, and a default `root=/dev/vda` append), and `--distro-root` (searches for `vmlinuz/Image`, `initrd.img`, and `rootfs.qcow2`). `architecture/CLI.md` and `EMIT.md` updated. Q8 surface complete |
| **Q9** capability matrix | **done** — `g6q-ingest/src/matrix.rs` builds a JSON matrix from `Sources` and the capability table, one row per capability with `config` probe/value, `flist` probe/evidence, `dts` tokens/node/declared, `qemu` properties/delta, and the conformance `verdict`; `gen --emit matrix` wired in `g6q-cli/src/main.rs`; `g6q-core/src/json.rs` added `get`, `is_null`, `is_empty`, `as_array`, and `as_string` accessors; `g6q-flist/src/lib.rs` added `Presence::as_str`; tests cover matrix shape and the unsupported-QEMU delta. `architecture/CLI.md` and `architecture/IR.md` updated. |
|| **Q10** computed-only MMU geometry | **done** — `g6q-core/src/model.rs` `Isa` gains `paddr_bits`, `vaddr_bits`, `page_table_levels`, `vpn_bits`, and `satp_mode`; `g6q-ingest/src/lib.rs` derives these from `mmu_mode` + `xlen` for `sv32`, `sv39`, and `sv48`; `g6q-vm/src/mmu.rs` is now model-driven: a `Mmu` struct is built from `Isa` and used by `translate(mem, mmu, satp, vaddr)`, supporting bare, Sv32, Sv39, and Sv48 geometry; `g6q-vm/src/exec.rs` `Hart` stores a `Mmu`, `Hart::with_isa` derives it from the model, and `Hart::new` defaults to bare; CLI `run` uses `Hart::with_isa`; unit tests cover bare, Sv39 1 GiB leaf, non-canonical detection, and mode mismatch. `architecture/INGEST.md` and `schemas/target-model.schema.json` updated. |

### Remote build and AI-island scaffold (this pass)

- Added `tools/g6q_remote.py` — a testharness-style remote QEMU build proxy for the `ovh_calltorch` / `/opt/testharness/g6lc-qemu` layout. Subcommands: `doctor`, `sync`, `configure`, `build`, `pull`, `run`, `test`, `clean`, plus a convenience `remote-build` that does sync → configure → build → pull and an optional OpenSBI smoke test. Uses rsync over a persistent SSH ControlMaster, ccache, and `ninja -j$(nproc)` for incremental builds.
- Wired into `tools/g6q.py` as `python tools/g6q.py remote -- <subcommand>` and `python tools/g6q.py remote-build -- <options>`.
- Added `tools/remote/ai-island-overlay.dts` and `tools/remote/payload/ai_island_smoke.{S,lds}` — an overlay that adds an `ai_island@40000000` node to the mini fixture and an M-mode RISC-V smoke payload that submits a descriptor, writes a done pointer, polls status, and prints `AI_OK`.
- `g6q-emit-qemu` machine emitter maps `ai-island`/`ai-matrix` peripherals to QEMU's `unimplemented-device` and the generated plugin now counts and reports accesses inside the AI-island physical address window.
- `g6q.py install-qemu` now wires the generated plugin into `contrib/plugins/meson.build` automatically (before the `foreach` loop), and `g6q_remote.py` configures QEMU with `--enable-plugins`.
- `g6q_remote.py test --ai-island` is implemented: it rsyncs the payload, probes for a RISC-V cross compiler on the remote builder, compiles the payload, runs `qemu-system-riscv64 -M <machine> -bios none -kernel <elf> -plugin libg6lc-<machine>.so`, pulls the log, and checks for `AI_OK` and `ai_island=N>0`.
- **Live remote smoke passed on `ovh_calltorch` (148.113.222.95):** `python tools/g6q.py remote-build --test-ai --machine g6lc-mini --host 148.113.222.95` (from WSL with `sshpass`/pip `ninja`/`meson`) produced a working out-of-tree QEMU build, the M-mode payload compiled with the remote `xpack-riscv-none-elf-gcc-14.2.0-3`, and the run log showed `AI_OK` with `ai_island_count=3` MMIO hits.
- Emission fixes driven by the live QEMU v10.0.0 build: plugin callbacks updated to the current `qemu_info_t`/`qemu_plugin_vcpu_simple_cb_t` signatures (no userdata on vCPU lifecycle/tb-trans callbacks), and the generated machine no longer attempts `sysbus_connect_irq` for `unimplemented-device` peripherals.
- `g6q-vm` gained `device::AiIsland`, a 64-byte MMIO stub matching the `g6lc_ai_desc_pkg.sv` descriptor surface, with `g6q-vm` `Hart::tick` raising an M-mode external interrupt on `irq_pending`.

### Q4 multi-hart + remote batch pass

- Generated `g6lc-unnamed` and `g6lc-mini` reinstalled with the latest emitters and `python tools/g6q.py install-qemu` now writes LF-only build-wiring appends on Windows (`newline="\n"` for meson/Kconfig/plugin wiring and the install marker).
- `g6q-emit-qemu` machine emitter now sets `mc->min_cpus`, `mc->default_cpus`, and `mc->max_cpus` from the model's `harts_total`, so multi-hart targets boot without requiring a manual `-smp` override.
- Added the `g6lc64_smt2` target (2-hart SMT profile from `E:\cva6`) to the generated QEMU build: `python tools/g6q.py install-qemu --package E:\cva6 --target g6lc64_smt2` produced `g6lc-g6lc64_smt2`, wired it into `Kconfig`/`meson`/`contrib/plugins`, and the remote out-of-tree build produced `qemu-system-riscv64` with three generated machines (`g6lc-unnamed`, `g6lc-mini`, `g6lc-g6lc64_smt2`).
- `tools/g6q_remote.py` smoke/plugin log-grep commands now use an `export PATH=...` shell wrapper and `check=False` so the OpenSBI smoke runs end-to-end on the remote dispatcher; `remote-build` no longer forces the OpenSBI smoke when only `--test-ai` or `--test-plugin` is requested.
- **Live remote tri-test on `ovh_calltorch` (148.113.222.95):**
  - `remote-build --test --machine g6lc-g6lc64_smt2 --no-pull` → OpenSBI v1.5.1 banner, `Platform Name: GSys LibreCore g6lc64_smt2`, `Boot HART Base ISA: rv64imafdcb`.
  - `test --smoke --machine g6lc-unnamed` → OpenSBI banner for `GSys LibreCore unnamed`.
  - `test --ai-island --machine g6lc-mini` → `AI_OK` with `ai_island_count=3`.
- `g6q-emit-qemu` plugin emitter now wraps the AI-island counter in `#if G6LC_AI_ISLAND_LEN != 0`, eliminating `-Wtype-limits` warnings on targets with no `ai-island` peripheral.
- `python tools/g6q.py check` green after the batch.

### B2 plugin tensor event completion tracking (this pass)

- `g6q-emit-qemu/src/plugin.rs`: B2 QEMU plugin now buffers tensor submissions in `g6lc_tensor_events[hart]` and writes the artifact at exit via `g6lc_tensor_event_write`.
- `g6lc_desc_submit` assigns a per-hart `g6lc_next_ticket[hart]`, matching the B3 `AiIsland` ticket sequence.
- Added `g6lc_ai_qfence_exec` to mark in-flight events as `done = true` / `status = G6LC_AI_ST_OK` when the `ai.qfence` instruction is decoded.
- Qfence detection uses the ingested `G6LC_AI_QFENCE_MASK` / `G6LC_AI_QFENCE_MATCH` macros with `QEMU_PLUGIN_CB_NO_REGS`.
- Removed immediate `fprintf` from `g6lc_desc_submit`; non-doorbell descriptor-window stores shadow the latch without writing raw access records.
- Added `g6lc_tensor_complete_by_ptr_done` so a guest store to an in-flight event's `ptr_done` address marks that event `done = true` / `status = G6LC_AI_ST_OK`.
- Artifact header `profile_tainted` is now `G6LC_PROFILE_TAINTED` derived from `model.diagnosable()` at emit time, matching the native `ArtifactHeader`.
- Artifact record format matches the native `TensorArtifact` JSON, including `ticket=%u`, `status=%u`, and `done` rendered as `"true"` / `"false"`.
- `architecture/EMIT.md` §B2 documents the buffering, qfence/ptr_done completion, ticket allocation, and artifact header.
- `g6q-diag/src/ai_tensor.rs` adds `ai.tensor.completes` counter; `architecture/DIAG.md` §4.1 updates the counter table.
- `g6q-emit-qemu/src/plugin.rs` emits `G6LC_AI_ST_OK` from the ingested `ST_OK` status code and uses it for `ai.qfence` and `ptr_done` completion status, matching the B3 `AiIsland` status codes.
- `g6lc_tensor_events` are initialised to `NULL` in `qemu_plugin_install` and freed in `g6lc_atexit`.
- `python tools/g6q.py check` green after the pass.

### Host bridge PyTorch consumer pass

- `tools/ai_tensor_bridge.py` `DescLayout` gains `op_name()` and `status_name()` reverse lookups.
- `TensorArtifact.summary(layout)` resolves op/status codes to the design's own names when a model is supplied.
- `TensorArtifact.pytorch_summary(layout)` returns one record per completed operation with `op_code`, `op_name`, `status_code`, `status_name`, `shape_m/n/k`, `dtype`, and A/B/C/output pointers.
- `ai_tensor_bridge.py results` accepts `--model` and `--per-event` to emit the PyTorch-friendly summary.
- `architecture/AI_BRIDGE.md` §5 documents the `results --model` and `results --per-event` contract for Python/PyTorch consumers.
- `ai_tensor_bridge.py` selftest validates name resolution, aggregate summary, and PyTorch output list.
- `python tools/g6q.py check` green after the pass.

### Cluster-aware tensor artifact pass (RTL-relevant bridge)

- `g6q-core` `AiTensorEvent` gains `cluster: u32`; `g6q-diag` `to_json`/`from_json` carry it and default missing values to `0`.
- `g6q-emit-qemu/src/plugin.rs` `EVENT_FIELDS` includes `cluster`; generated `G6lcTensorEvent` struct, `g6lc_desc_submit`, and `g6lc_tensor_event_write` emit the `cluster` field, defaulting to `0` when the descriptor package does not publish it.
- `g6q-vm/src/device.rs` `queue_enq` sets `cluster: 0` with a comment that cluster dispatch is not yet published in the descriptor package (`RTL_FEEDBACK.md` F6).
- `tools/ai_tensor_bridge.py` `TensorArtifact.summary` adds `by_cluster` and accepts `clusters` from the model; `pytorch_summary` includes `cluster`; `cmd_results` extracts `clusters` from `soc.ai_island.config.clusters` and passes it to the summary.
- `architecture/AI_BRIDGE.md` §5 documents `by_cluster`, `clusters`, and per-event `cluster`.
- `architecture/RTL_FEEDBACK.md` adds F6: the design must publish how a descriptor is dispatched to a cluster before events can be attributed per cluster.
- `python tools/g6q.py check` green after the pass.

### `ai.poll` B2 completion path pass

- `g6q-core` `AiDescLayout` gains `CompletionLayout` with ticket/status bit ranges.
- `g6q-diag/src/ai_desc.rs` parses `make_completion` from `g6lc_ai_desc_pkg.sv` and extracts the ticket/status bit layout.
- `g6q-emit-qemu/src/plugin.rs` emits `G6LC_AI_COMPLETION_*` macros from the ingested layout.
- `g6q-emit-qemu/src/plugin.rs` emits `G6LC_AI_POLL_DECODE/MASK/MATCH` and `g6lc_ai_poll_exec` when the instruction set and completion layout are both ingested.
- The `g6lc_ai_poll_exec` callback reads the polled ticket from `rs1`, finds the in-flight event, reads the 8-byte completion word at `ptr_done`, and marks the event done when the word contains the matching ticket and `G6LC_AI_ST_OK`.
- `architecture/EMIT.md` §Completion documents the `ai.poll` path and `make_completion` ingestion.
- `schemas/target-model.schema.json` accepts `desc_layout.completion`.
- `python tools/g6q.py check` green after the pass.

### B3 completion word uses `make_completion` layout pass

- `g6q-core/src/model.rs` `CompletionLayout` is now used by both B2 emission and B3.
- `g6q-vm/src/device.rs` `AiIsland::completion_word()` packs the word from the ingested `CompletionLayout` when the model provides it, falling back to the reference `{status, ticket}` layout only when the package does not publish `make_completion`.
- `g6q-vm/src/device.rs` `MmioDevice::load` for the `completion` register calls `completion_word()`.
- `g6q-vm/src/device.rs` tests add `completion` to `model_with_layout()` and a new `ai_island_completion_word_uses_ingested_layout` test with a swapped layout (ticket at 63:16, status at 15:0) to prove packing is layout-driven.
- `python tools/g6q.py check` green after the pass.

### B2 ptr_done store completion decoding pass

- `g6q-emit-qemu/src/plugin.rs` emits `G6LC_AI_COMPLETION_DECODE` when the ingested `CompletionLayout` is present.
- `g6q-emit-qemu/src/plugin.rs` `g6lc_vcpu_mem_access` extracts the 64-bit store word from `qemu_plugin_mem_get_value` and passes it to `g6lc_tensor_complete_by_ptr_done`.
- `g6q-emit-qemu/src/plugin.rs` `g6lc_tensor_complete_by_ptr_done` decodes `read_ticket` and `read_status` from the stored word using the `G6LC_AI_COMPLETION_*` bit macros and marks the event done only when `read_ticket == e->ticket` and `read_status == G6LC_AI_ST_OK`. When the layout is unresolved it falls back to the previous address-match behavior.
- `architecture/EMIT.md` §Completion documents the store-value decoding path.
- `g6q-emit-qemu` tests `the_ptr_done_completion_path_decodes_when_layout_resolved` and `the_ptr_done_completion_path_falls_back_without_layout`.
- `python tools/g6q.py check` green after the pass.

### `dtype_mask` capability window resolution pass

- `g6q-core/src/model.rs` `AiIslandConfig` gains `dtype_mask: Option<u32>` and `to_json` carries it.
- `schemas/target-model.schema.json` accepts `dtype_mask` as `integer|null`.
- `g6q-diag/src/ai_cap.rs` (new module) parses `DtypeMask` from `g6lc_ai_cap_window.sv` module parameter declarations.
- `g6q-diag` tests parse a synthetic cap window and the real `g6lc_ai_cap_window.sv` if present.
- `g6q-ingest/src/lib.rs` `build_ai_island_model` finds `g6lc_ai_cap_window.sv` in the flist and sets `config.dtype_mask` from it.
- `g6q-vm/src/device.rs` `cap_value` sources `dtype_mask` from the model, so it is no longer `cap_unsourced`.
- `g6q-vm` test `every_published_capability_name_is_accounted_for` now expects only `block_mnk` as unsourced.
- `architecture/RTL_FEEDBACK.md` F3 updated: `dtype_mask` is now read from the cap window but remains fragile because it is a parameter, not a package constant; `block_mnk` remains an open ask.
- `python tools/g6q.py check` green after the pass.

### `block_mnk` capability window resolution pass

- `g6q-core/src/model.rs` adds `CapBlockMnk` and `AiIslandConfig.block_mnk: Option<CapBlockMnk>`; `to_json` carries it.
- `schemas/target-model.schema.json` accepts `block_mnk` as an object with `m_low/m_width/n_low/n_width/k_low/k_width` or `null`.
- `g6q-diag/src/ai_cap.rs` `parse_cap_window_block_mnk` finds the `14'h05:` case arm, extracts the `lg2u(AccTile*)` concatenation order and padding width, and computes each field's low bit and width.
- `g6q-diag` tests parse a synthetic cap window and the real `g6lc_ai_cap_window.sv`.
- `g6q-ingest/src/lib.rs` sets `config.block_mnk` when `g6lc_ai_cap_window.sv` is in the flist.
- `g6q-vm/src/device.rs` `cap_value` packs `block_mnk` from `log2(AccTileM/N/K)` and the ingested `CapBlockMnk`; adds `clog2_u32` helper matching `$clog2`.
- `g6q-vm` `model_with_layout()` and `every_published_capability_name_is_accounted_for` now exercise `block_mnk` and `dtype_mask` and expect `cap_unsourced()` to be empty.
- `g6q-vm` `the_capability_window_answers_from_the_model_once_placed` checks `cap_read(0x10) == Some(0x888)` for 256^3 tiles.
- `architecture/RTL_FEEDBACK.md` F3 updated: both packed words are now read from the cap window, but the ask for design-published localparams remains because the parameter/concatenation source is fragile.
- `python tools/g6q.py check` green after the pass.

### B3 `queue_poll` returns packed completion word pass

- `g6q-vm/src/device.rs` `AiIsland::completion_word()` delegates to a new `pack_completion_word(ticket, status)` helper.
- `g6q-vm/src/device.rs` `AiIsland::queue_poll` finds the in-flight queue entry and, when done, returns the packed completion word using the ingested `make_completion` layout. Pending entries still return `0xffff_ffff`; unknown/retired tickets return the completion word with `ST_OK`.
- `g6q-vm` test `rings_come_from_the_model_and_harts_do_not_serialise_onto_one` asserts `queue_poll(t) == t` after `queue_qfence` to prove the packed word contains the ticket.
- `architecture/EMIT.md` §Completion documents that B3 `queue_poll` and the B2 `ai.poll` path share the same completion-word packing.
- `python tools/g6q.py check` green after the pass.

### `cap_packed` capability words pass

- `g6q-core/src/model.rs` adds `CapPackedField`, `CapPackedWords`, and `AiIslandConfig.cap_packed`; `to_json` serializes the map.
- `schemas/target-model.schema.json` accepts `cap_packed` as an object mapping capability names to arrays of `{name, low, width}`.
- `g6q-diag/src/ai_cap.rs` parses the cap window `always_comb` case arms, extracts packed words by capability offset, maps `IslandCfg.*` names to config field names, and records unmodeled fields (e.g. `meas_milli`) with a leading underscore.
- `g6q-diag` tests parse synthetic and real `g6lc_ai_cap_window.sv` packed `dram_gbps` and `queues` words.
- `g6q-ingest/src/lib.rs` sets `config.cap_packed` when the cap window module is present.
- `g6q-vm/src/device.rs` `cap_value` falls through to `pack_cap_packed` for any capability name not in the flat match; packed words are built from model field values, with underscore-prefixed fields treated as zero.
- `g6q-vm` tests `the_capability_window_answers` and `every_published_capability_name_is_accounted_for` now exercise packed `queues` (`queue_depth << 16 | queues`) and `dram_gbps` (`_meas_milli << 16 | dram_gbps`).
- `g6q-vm` `model_with_layout` no longer treats `queue_depth` as a standalone capability word; it is only a packed subfield of `queues`.
- `architecture/RTL_FEEDBACK.md` F3 updated to note all packed capability words are now read from the cap window.
- `python tools/g6q.py check` green after the pass.

### F5 descriptor `flags_layout` pass

- `g6q-core/src/model.rs` adds `DescFlagsLayout` (`dtype_shift/mask`, `priority_shift/mask`, `irq_bit`) and `AiDescLayout.flags_layout`; `to_json` serializes it.
- `schemas/target-model.schema.json` accepts `flags_layout` as an object or null under `desc_layout`.
- `g6q-diag/src/ai_desc.rs` parses `g6lc_ai_desc_pkg.sv` comment and `desc_prio`/`desc_irq` helpers to populate `flags_layout`.
- `g6q-emit-qemu` emits `G6LC_AI_DTYPE_SHIFT`/`MASK` from the ingested `flags_layout`, and requires `flags_layout` for `G6LC_AI_DESC_DECODE`, so it no longer uses the `g6q_core` constant.
- `g6q-emit-qemu` `model_with_island` test fixture carries a `flags_layout`.
- `architecture/RTL_FEEDBACK.md` F5 updated: the layout is now ingested from the package, but the ask for design-published localparams remains so the parser does not depend on comments and helper names.
- `python tools/g6q.py check` green after the pass.

### F5 follow-up — remove hard-coded dtype constants from g6q-core

- `g6q-core/src/model.rs` removes the `DTYPE_SHIFT` and `DTYPE_MASK` fallback constants.
- `g6q-diag/src/ai_tensor.rs` carries `TensorTrace.flags_layout`; `TensorArtifact` serializes and recovers it; `AiTensorEvent::dtype_from_flags` takes a `&DescFlagsLayout`; a `DEFAULT_FLAGS_LAYOUT` fallback is kept inside `g6q-diag` for older bare event arrays.
- `g6q-emit-qemu` emits the full `flags_layout` object into the B2 tensor artifact header (preprocessor-gated on `G6LC_AI_DESC_DECODE`) and emits `G6LC_AI_PRIO_SHIFT`/`MASK`/`IRQ_BIT` macros.
- `g6q-cli` writes `TensorArtifact` with `flags_layout` from the model and imports `TensorArtifact`.
- `architecture/RTL_FEEDBACK.md` F5 updated: the `g6q_core` fallback constants are removed.
- `python tools/g6q.py check` green after the pass.

### F5 follow-up — bridge uses `flags_layout` to recover `dtype`

- `g6q-diag/ai_tensor.rs` already carries `TensorTrace.flags_layout` and `TensorArtifact` serializes it.
- `tools/ai_tensor_bridge.py` `TensorArtifact` reads `flags_layout` from the artifact, stores it, and uses `_dtype_for_event` to recover `dtype` from `flags` when the event omits `dtype` or sets it to zero.
- `TensorArtifact.summary()` and `pytorch_summary()` report the recovered `dtype`.
- Selftest creates an artifact with `flags_layout` and an event that has `dtype` missing, verifying `by_dtype` and `pytorch_summary` show the recovered value.
- `architecture/AI_BRIDGE.md` §5 updated to describe the `flags_layout` recovery and the state table now lists it as landed.
- `python tools/g6q.py check` green after the pass.

### B3 `ai.enq` reads the descriptor from guest memory

- `g6q-vm/src/device.rs` adds `AiIsland::read_descriptor_event`, which reads each `desc_layout` field from `PhysMem` at `desc_addr + offset`, derives `dtype` from `flags` using `flags_layout`, and returns a populated `AiTensorEvent`.
- `g6q-vm/src/device.rs` adds `queue_enq_with_event` and keeps `queue_enq` as a convenience that passes `None` (falling back to the MMIO shadow `version`/`op`).
- `g6q-vm/src/exec.rs` `execute_ai_enq` reads the descriptor event from memory before calling `queue_enq_with_event`, so the B3 tensor event matches the guest descriptor image.
- `g6q-vm/src/device.rs` test `queue_enq_reads_descriptor_from_memory` packs a descriptor into `PhysMem` and asserts the recovered event fields and `dtype`.
- `g6q-vm/src/device.rs` `queue_qfence` now returns a list of `(ptr_done, completion_word)` pairs and `g6q-vm/src/exec.rs` `execute_ai_qfence` writes them to guest memory using `PhysMem`.
- `g6q-vm/src/device.rs` test `queue_qfence_writes_completion_words_to_memory` and `g6q-vm/src/exec.rs` test `ai_enq_reads_descriptor_and_qfence_writes_completion` cover end-to-end descriptor reading and completion writeback.
- `architecture/DIAG.md` §4.1 and `architecture/AI_BRIDGE.md` state table updated.
- `python tools/g6q.py check` green after the pass.

---

### B2 tensor event PMU field pass

- `g6q-core` `AiTensorEvent` already carries `pmu_r_beats`, `pmu_w_beats`, `pmu_cycles`, and `pmu_gbps_x1000` from the earlier B3/D2 pass.
- `g6q-emit-qemu/src/plugin.rs` adds the same four `uint32_t` fields to the generated `G6lcTensorEvent` C structure and initializes them to `0` in `g6lc_desc_submit`.
- `g6q-emit-qemu/src/plugin.rs` `g6lc_tensor_event_write` now emits the four PMU JSON fields in the `fprintf` format string and passes the event fields to `fprintf`, so the generated B2 artifact has the same key shape as the native B3 artifact.
- B2 values remain `0` because the plugin does not model accelerator execution timing or real PMU state; the values are `Fidelity::Modelled` unavailable at this stage.
- `g6q-emit-qemu` test `the_submission_record_matches_the_native_artifact_shape` now asserts that `pmu_r_beats`, `pmu_w_beats`, `pmu_cycles`, and `pmu_gbps_x1000` appear in the emitted C and that `e->pmu_r_beats, e->pmu_w_beats, e->pmu_cycles, e->pmu_gbps_x1000` are passed to `fprintf`.
- `g6q-diag` test `b2_tensor_event_parses_pmu_fields_as_zero` constructs a B2-shaped JSON record with all four `pmu_*` keys set to `0` and proves `AiTensorEvent::from_json` consumes it, confirming the B2 output is parseable by the same bridge path as B3.
- `architecture/EMIT.md` §B2 documents the B2/B3 PMU field parity and the distinction between B2 zero/unavailable values and B3 roofline-derived modelled values.
- `python tools/g6q.py check` green after the pass.

---

### B2/B3 tensor artifact compare (PMU modelled-vs-zero divergence)

- `g6q-diag` `TensorArtifact::compare` already surfaces any `AiTensorEvent` field difference, so a B2 zero-PMU record and a B3 roofline-PMU record diverge on the PMU fields.
- Added `tensor_event_round_trips_pmu_values` to prove a non-zero set of `pmu_r_beats`, `pmu_w_beats`, `pmu_cycles`, and `pmu_gbps_x1000` round-trips through `TensorTrace::to_json`/`from_json`.
- Added `tensor_artifact_compare_reports_pmu_modelled_vs_zero` to construct a B2-shaped event (all `pmu_*` zero) and a B3-shaped event (same geometry, modelled PMU values) and assert `TensorArtifact::compare` returns `Some(...pmu_r_beats...)`.
- This closes the B2/B3 artifact parity loop: the plugin carries the fields and the native model populates them, and `TensorArtifact::compare` can explain the modelled difference without treating it as an error.

---

### Remote builder WSL/Windows + passphrase support

- `tools/g6q_remote.py` now consumes `G6Q_REMOTE_CREDS` (passphrase file), `G6Q_REMOTE_KEY` (private-key path), and `G6Q_REMOTE_HOST` (SSH target) so a Windows host can drive the `ovh_calltorch` builder.
- On Windows it falls back to `wsl ssh`/`wsl rsync`; because `wsl` cannot be spawned from a non-interactive Python `subprocess` without a console handle, the script is **invoked from the WSL side** (`wsl python3 /mnt/e/cva6/g6lc_qemu/tools/g6q_remote.py ...`) using WSL-native `ssh`/`rsync`.
- `G6Q_REMOTE_ASKPASS_INTERNAL=1` forces the `SSH_ASKPASS` helper into the WSL internal filesystem (`/root/.g6q_remote_askpass.sh`) so `chmod 700` is honored and a passphrase-protected key can be unlocked without a TTY.
- `tools/g6q_remote.py` `_control_socket` now passes the askpass environment to the persistent `ssh -M` master.
- `tools/g6q_remote.py` `cmd_doctor` probes `ninja` with `$HOME/.local/bin` on `PATH` so user-installed `ninja` is reported.
- A live `wsl python3 ... remote-build --host ubuntu@148.113.222.95` completed: synced the staged `qemu/` source, configured, built `qemu-system-riscv64` remotely, and pulled it back to `E:\cva6\g6lc_qemu\qemu\build\qemu-system-riscv64`.
- Remote OpenSBI smoke passed:
  ```text
  OpenSBI v1.5.1
  Platform Name             : GSys LibreCore mini
  Domain0 Next Address      : 0x0000000080200000
  Boot HART Base ISA        : rv64imafdcv
  ```
- Local WSL OpenSBI boot of the pulled binary also printed the same banner, confirming the remote build artifact runs.
- Remote AI-island smoke ran but did not produce `AI_OK`; the payload was compiled and loaded, but the run was killed after 5s with only `qemu-system-riscv64: terminating on signal 15`. This is consistent with the model leaving `cap_base`/`desc_base` unresolved (`architecture/RTL_FEEDBACK.md`) so the guest has no published MMIO window for the AI island yet.
- `python tools/g6q.py check` green after all changes.

---

### Q2 status — emission complete, boot gate pending host tooling

Landed and tested offline:

- **`--emit args`** — full invocation from the model: machine, processor properties from
  live capabilities only, processor count, memory, firmware mode, disks, networking with port
  forwards, serial, deterministic time. Plus the **capability delta**: what a stock model cannot
  express (vendor extensions, the coprocessor seam, the memory map, and a hart-topology mismatch
  when there is one).
- **`--emit dts` / `--emit dtb`** — a flattened-tree writer *and* reader, so no external
  device-tree compiler is needed. All 7 real trees round-trip with their facts intact.
- Disks and networking are **refused on the faithful machine**, which genuinely has neither.

**Not verified, and cannot be on this host:** no emulator, no device-tree compiler and no
cross-toolchain are installed, so the Q2 exit gate — firmware banner and a shell on a stock
binary — has not been demonstrated. Two consequences worth stating plainly:

- **`qemu` property names in the capability table are unvalidated.** Most default to the
  device-tree token, which is usually right. Check `-cpu help` on the pinned release before
  trusting a boot. A wrong name fails at start-up rather than silently, which is the better
  failure.
- **The firmware chain (`g6q fw`) is not implemented.** It needs a cross-toolchain to be
  meaningful, and building it blind against the in-tree profile would be guesswork.

Closing Q2 needs an emulator and a toolchain on the host, then: validate the property names,
implement `fw`, and run the two boots.

## Open items

**G1 — Q1 ingest. Closed.** Readers, model assembly, capability table, `gen` and `conform` are live
and soaked against a real tree. Remaining Q1-adjacent work is device-tree *mutation* (`--dts-set`,
`--dts-del`, overlay merge, blob emission) and `--dts-validate`, which land with the command-line
surface that needs them at Q2.
*Priors: `architecture/INGEST.md`, `architecture/IR.md`.*

**G9 — Interrupt-controller capacity is not read.** `intc_targets` currently counts the contexts a
**board wires**, taken from the controller's `interrupts-extended` list. The controller's hardware
capacity lives in the design's SoC package, which the `apu` plane does not read yet. Until it does,
`max_harts` describes what the board connects, not what the silicon could serve. The model reports
`null` rather than `0` when the number is unknown, so nothing downstream mistakes ignorance for a
limit. Close this when the SoC-package reader lands.
*Priors: `architecture/INGEST.md` §1 (planes).*

**G10 — Capability table coverage.** `crates/g6q-ingest/data/capabilities.ini` covers the extension
and unit surface reached so far. It is data and is expected to grow; two rules keep it honest. A
capability with no separate compilation unit must have **no** `impl` entry, or manifest membership
will report it as a stub. A capability the device tree cannot express must have **no** `dts` entry —
giving privilege modes extension tokens produced a false `undeclared` on every target until it was
removed.
*Priors: `crates/g6q-ingest/data/capabilities.ini` header.*

**G2 — Reader strategy escalation.** The Q0/Q1 config reader is deliberately narrow: it understands
`localparam` scalars, enum identifiers, named struct-literal members and simple arithmetic, and it
**fails loudly** rather than defaulting. If it proves brittle across real packages, escalate to a
vendored full SystemVerilog parser as an integral in-tree copy with a pin file — do not accumulate
special cases. Record the decision here before doing it.
*Priors: `architecture/INGEST.md` §2.*

**G3 — Schema stability.** `schemas/target-model.schema.json` and `conformance.schema.json` are
version-stamped from the first release. Any field rename is a `schema_version` bump plus a fixture
update; consumers read the version before the payload.
*Priors: `architecture/IR.md`.*

**G4 — Zero-dependency stance.** The workspace has no external crates and offline
`cargo test --workspace` must keep working. Adding a dependency requires a decision recorded here, a
`pins.toml` entry with an exact version, permissive licence only, and a note on offline behaviour.
*Priors: `AGENTS.md` §3, `AGENTS-licensing.md` §5.*

**G5 — `E-GPLLINK` regression.** `tools/check_independence.py` is the enforcement point. Extend it
whenever a new way to reach QEMU appears (a build script, a linker attribute, a vendored header). A
violation must be a build failure, never a review comment.
*Priors: `AGENTS-licensing.md` §2.3.*

**G6 — Profile discipline plumbing.** `profile` must be a required field of every artifact the moment
artifacts start existing (Q2). Retrofitting stamps after the fact is how a `g6lc-virt` result ends up
quoted as a hardware result.
*Priors: `architecture/DESIGN.md` §"Machine profiles".*

**G7 — Pin hygiene.** `pins.toml` currently records QEMU, OpenSBI, and the external contracts this
package consumes. Whenever a consumed contract changes upstream, bump the pin **and** the affected
schema/ABI version in the same pass. Never reinterpret bits silently.
*Priors: `AGENTS.md` §1.9.*

**G8 — Host adapter stays optional.** If a host project grows an adapter that spawns this CLI, it
lives in the host, not here, and the package must keep working without it.
*Priors: `AGENTS.md` §1.1.*

### Q4/Q5 debug, trace and AI-island pass

- Added `--debug` / `--debug-file` to `BootOptions` and `g6q_emit_args::build_argv`; they drive QEMU's `-d`/`-D`.
- B2 trace plugin emits `RecordFile` objects with `header.profile`, `order`, `hart`, `pc_rdata`,
  `pc_wdata`, `insn`, `trap`, `cause`, `prv`, `halt`, `rd_addr`, `rd_wdata`, `frd_addr`, `frd_wdata`
  as numeric JSON; the prior `0x...` string experiment was dropped because `CommitRecord` already
  parses integers.
- The plugin counts loads, stores, MMIO and AI-island window hits; the AI-island base and length are
  model-derived, not hard-coded.
- `g6q_remote.py` shell wrappers now export `PATH` consistently for configure, build, plugin build,
  payload compile and QEMU run commands; `ninja` and the `xpack-riscv-none-elf-gcc-14.2.0-3` toolchain
  are found reliably.
- `run --backend qemu --record FILE` auto-loads the generated trace plugin with `trace=<tmp>` and
  copies the plugin output to `FILE` after QEMU exits.
- `tandem` accepts both raw record arrays and wrapped `RecordFile` objects.
- Live remote run: `g6lc-mini` AI-island smoke produced `AI_OK` with `ai_island_count=3`; the trace
  (`40` records) pulled and `tandem --under-test trace.json --reference trace.json` reported
  `{ "divergence": false, "records": 40 }`.
- `architecture/CLI.md`, `DIAG.md`, `EMIT.md` updated.

**G11 — RESOLVED (this pass). `python tools/g6q.py install-qemu` now maps the package directory to**
the appropriate `resolve` options: repo-root layout (pass `--repo-root`) or a flat fixture (pass
explicit `--config-pkg`, `--flist`, `--dts`, and `--target`). It also accepts `--target` and
`--dts-overlay` overrides. The generated `g6lc-unnamed` machine now boots OpenSBI from a real
`E:\cva6` repo-root package without any temporary overlay.
*Priors: `tools/g6q.py`, `architecture/CLI.md`.*

**G12 — RESOLVED (this pass).** The CVA6 testbench (`corev_apu/tb/rvfi_tracer.sv`) writes
`trace_rvfi_hart_*.dasm` with one line per retired instruction: mode, PC, instruction word,
register write (`xN`/`fN`) and memory access (`mem ...`).
`crates/g6q-diag/src/rvfi.rs` parses the dasm text, handles both `x10` and `x 8` spacing produced by
the tracer, derives `pc_wdata` from the next record's `pc_rdata`, sets `halt` for final `wfi`/`ebreak`,
and maps exception names to causes.  `g6lc-qemu tandem --under-test trace.dasm --reference trace.json`
loads `.dasm` files directly.  Validation: a real `trace_rvfi_hart_00.dasm` from the CVA6 verif/sim
output parsed 17 records and self-tandem reported `{ "divergence": false, "records": 17 }`.
*Priors: `architecture/DIAG.md` §2.4, `crates/g6q-diag/src/rvfi.rs`, `crates/g6q-cli/src/main.rs`.*

**G13 — AI-tensor events (in progress, descriptor package reader landed).** The AI-island device
currently counts MMIO window accesses.  The next step is to decode descriptor ring activity
(descriptor address, length, completion pointer, done flag) and emit tensor-shaped events (batch,
input/output address, length, dtype, completion) into a separate trace stream or `CommitRecord`
extension.  `crates/g6q-diag/src/ai_desc.rs` now reads `g6lc_ai_desc_pkg.sv` and derives descriptor
size, op/status constants and field byte offsets from the `bits_to_desc` bit-range map.  Next: model
field for the queue ring, `AiTensorEvent` type, and VM/plugin event emission.
*Priors: `architecture/DESIGN.md`, `crates/g6q-diag/src/ai_desc.rs`, `crates/g6q-vm` AI-island device.*

---

## Large change sets — open steps grouped into passes

The remaining open items are not independent one-file fixes; they cluster into three large change
sets.  Each should land as a single coherent pass with its own green `python tools/g6q.py check` and
its own remote or fixture test.

### Change set A — RTL/RVFI trace bridge (closes G12)

Goal: a `g6lc-qemu ingest rvfi` path that reads CVA6 `trace_rvfi_hart_*.dasm` and produces a
`RecordFile` that `tandem` can compare against a QEMU or B3 trace.

Components:
- `crates/g6q-diag/src/rvfi.rs` — parser for `rvfi_tracer.sv` text (mode/PC/insn, `xN`/`fN` writes,
  `mem ...` loads/stores, `exception @` traps, compressed vs uncompressed widths).
- `g6q-diag` record builder: map `pc_rdata`, `insn`, `mode`/`prv`, `rd_addr`/`rd_wdata`,
  `frd_addr`/`frd_wdata`, `trap`/`cause`, `mem_addr`; derive `pc_wdata` from the next record's
  `pc_rdata` (last record uses `pc + size` and `halt=true` for `wfi`/`ecall`);
  map `exception @ ...` to `trap=true` and `cause` from the exception name.
- CLI verb or `tandem` loader: detect `.dasm` inputs and call the parser (same `load_records`
  fallback pattern used for wrapped record files).
- Tests: synthetic `trace_rvfi_hart_0.dasm` fixtures and a round-trip check that parsed records
  match hand-built `CommitRecord`s.
- Docs: `architecture/DIAG.md` §2.4 and `architecture/CLI.md` `--rvfi-out`/ingest notes.

### Change set B — AI-tensor event model + clustering (closes G13)

Goal: move the AI-island counter from "any MMIO in the window" to "descriptor ring events", and
scale the model to a cluster of islands / queues with per-operation efficiency counters.

Components:
- `g6q-diag` package readers:
  - `g6lc_ai_desc_pkg.sv` — descriptor size, op/status codes, field byte offsets.
  - `g6lc_ai_island_cfg_pkg.sv` — cluster count, MACs/cycle, queues, queue depth, capability
    window layout.
  - `g6lc_ai_instr_pkg.sv` (optional) — queue CSR numbers and `ai.enq`/`ai.poll`/`ai.qfence`
    custom-opcode encodings when `AiQueues > 0`.
- `g6q-core` `TargetModel` extension for:
  - `ai_island` cluster config (clusters, MACs/cycle, SRAM, queues, queue depth, SKU target).
  - `ai_queue` ring (base, head, tail, depth, qid, enable) per queue / cluster node.
  - `ai_desc_layout` (byte offsets and op/status constants) so VM and plugin decode the same ABI.
- `g6q-vm` `AiIsland` device:
  - Build from `AiIslandConfig` + `AiDescLayout` instead of hand-coded 64-byte register map.
  - Decode descriptor writes (T2 MMIO window) and emit `AiTensorEvent`s.
  - Implement `aiqbase` / `aiqctl` / `aiqhead` CSRs and `ai.enq` / `ai.poll` / `ai.qfence` when the
    queue is enabled.
  - Update `ai_island_submits_and_completes` and add a queue-ring smoke test.
- `g6q-diag` D2 counters for AI efficiency:
  - `ai.tensor.ops` (descriptor submissions), `ai.tensor.bytes` (A/B/C data touched),
    `ai.tensor.macs` (estimated dense MACs = m*n*k per GEMM/CONV), all synthetic.
- `g6q-emit-qemu` B2 plugin:
  - Track AI MMIO window stores, accumulate a 64-byte descriptor and emit a `tensor.json` event on
    the version/op doorbell.
  - Optionally watch the queue CSR/MEM writes for T0 doorbells and emit queue events.
  - Keep `G6LC_AI_ISLAND_BASE` / `LEN` from the model; use only integer arithmetic, no QEMU headers.
- `tools/g6q_remote.py` — pull the generated `tensor.json` alongside the commit trace and report
  `ai_island_count` + `ai.tensor.*` counters.
- AI-island smoke payload extended to submit one descriptor and poll completion (T2 or T0 queue
  path depending on `Queues`).
- Docs: `architecture/DIAG.md` §2.x (tensor trace stream), `architecture/EMIT.md` §B2.x (plugin
  tensor output), `architecture/CLI.md` `--record` / remote trace options.

### Change set B2 — accelerator scale-out boundary + host bridge (Q7, landed)

Design of record: `architecture/AI_BRIDGE.md`. The pushed-work reach path (host writes descriptors,
guest driver submits them) is now a documented boundary with a package-local tool, rather than an
implied capability.

Landed:
- `architecture/AI_BRIDGE.md` — separation-of-concerns table, the two reach paths over one IR, what
  island scale means in the model vs what is never simulated, structural gaps named as gaps, host
  bridge ownership, and stage placement on the existing **Q** axis (no new letter namespace).
- `pins.toml` — `contracts.ai_island_cap` (read-at-runtime) and `contracts.ai_host_transport`
  (**unpinned**; the transport is deliberately not modelled until pinned).
- `tools/ai_tensor_bridge.py` — `doctor` / `pack` / `push` / `results` / `compare` / `selftest`.
  Descriptor geometry is read from `soc.ai_island.desc_layout`; the tool types no offset, size, op
  or status value, and refuses a model with no ingested layout.
- `g6q-cli` — `run --backend native --tensor FILE` writes the stamped tensor artifact from B3, so the
  native and QEMU routes produce the same artifact shape.
- `tools/g6q.py check` — added a `bridge selftest` step so the bridge cannot rot silently.
- Root `AGENTS.md` — `g6lc_qemu` rows in §2 substructure map and two §3 navigate-by-intent rows
  (emulation/tracing; pushed AI-tensor work).

Deliberately **not** done, with reasons:
- No transport/BAR/virtio modelling — `contracts.ai_host_transport` is unpinned; transcribing a
  proposed BAR table would create the divergence §1.9 exists to prevent.
- No throughput, bandwidth, or TOPS claim anywhere — the IR carries `macs_per_cycle` / `dram_gbps`
  and the emulator reports them without timing them (directive 6).
- `ai.tensor.bytes` / `ai.tensor.macs` are **not** re-derived in Python; they stay in `g6q-diag` so
  the dtype-width table and dense-execution assumption have one implementation.

Open follow-ups (reopen conditions recorded):
- Capability-window reads answered from `config.cap_offsets` rather than device defaults (Q7).
- Transport modelling once `contracts.ai_host_transport` is pinned (Q8).

### Change set B3 — model-derived AI-island device (Q6/Q7/Q8, landed)

The device model previously typed its own guest-visible surface. That is the §1.2 defect, and it also
meant B3 and any future descriptor-decoding B2 plugin could disagree byte-for-byte about the
descriptor while both looked correct.

Landed:
- `AiRegMap` — MMIO window resolved from `desc_layout` field offsets; `status`/`completion` placed
  from `desc_bytes`. `Default` is an explicitly-labelled bring-up fallback, used only when no layout
  has been ingested, so the 81 pre-existing tests keep their meaning.
- `AiStatusCodes` — `ST_OK` / `ST_BAD_VER` / `ST_DISABLED` resolved by name from the package.
- Multi-ring island: `config.queues` rings at `config.queue_depth`, `ring_for_hart` = one ring per
  hart wrapping when rings < harts, and **island-wide ticket allocation** so `ai.poll` is unambiguous
  once a second hart submits. `AiQueue::enqueue` became `enqueue_with_ticket`.
- Capability window: `cap_words()` derives every value from `AiIslandConfig`; `cap_read()` decodes
  only once `cap_base` is set, and an offset the model never named is reported absent rather than as
  zero (zero is a legal capability value).
- 5 new tests, incl. a layout whose offsets differ from the fallback so a passing test can only be
  reading the model (`ptr_done` at 56, not `0x40`).

Docs corrected against a monorepo survey (all three were wrong in-tree):
- `architecture/EMIT.md` claimed the B2 tensor plugin reassembles descriptors from parsed offsets. It
  does not — it records raw MMIO accesses. Now states current vs planned, and why the two backends
  must agree byte-for-byte.
- `architecture/AI_BRIDGE.md` §5 called the descriptor ring the "stream plane". Wrong: in the host
  design "stream plane" is a *multi-core, one-thread-per-core* SoC topology, and the package named
  for it caps cluster count, not issue width. Corrected, with the error acknowledged in §4.1.
- `architecture/AI_BRIDGE.md` gained §4.1, recording that **no 1000-TOPS target exists** in the host
  design (stated target is the 100-TOPS class on a single monolithic die; multi-card scale-out is
  described nowhere), that **no package exceeds 4-issue** (8 is headroom only), and that eight cores
  with two threads each is prohibited by the `S ≤ 8` interrupt-context arithmetic.

Open, with reopen conditions:
- **Ingest gap:** the model carries capability *offsets* but no window *base*. Until the design
  package exposes one, `cap_base` stays `None` and the window is undecoded. Inventing a base would
  put a guest-visible address in `device.rs`.
- Conformance rules for `S` above the interrupt-context cap, and accumulator banks below thread
  count (both are design asserts the emulator should mirror).
- B2 descriptor reassembly, so the plugin stream carries submissions rather than accesses.
- Firmware topology invariants (processor-node count and firmware hart count both equal `S`) as
  emitted-artifact checks; the design's own two-thread bring-up is not green here.

### Change set B4 — island MMIO placement, ingested or reported (Q6, landed)

Closes the ingest gap opened by B3. Investigating it found the reason the gap existed: **a
guest-visible island address has two halves that live in two different kinds of file.** Field offsets
within the descriptor are in the accelerator's descriptor *package* and were already ingested; the
*base* of the descriptor window and of the capability window are decided by the island's address
decode, i.e. RTL, and are published nowhere the reader can consume.

Landed:
- `AiIslandConfig.cap_base` / `.desc_base` as `Option<u64>`, plus `placement_resolved()`; both in the
  model JSON and the schema (which is `additionalProperties: false`, so it had to be extended).
- `ai_cfg.rs` parses `CAP_BASE` / `DESC_BASE` (also `REG_OFF_CAP` / `REG_OFF_DESC`,
  `AI_CAP_BASE` / `AI_DESC_BASE`) when a package declares them, and leaves them `None` otherwise. It
  does **not** parse the RTL address decoder.
- `AiRegMap::from_desc_layout(layout, base)` — the base and the field offsets are separate arguments
  because they come from separate sources; conflating them into one number was the original error.
- Unresolved placement is loud, not defaulted: descriptor window collapses to 0, capability window is
  **not decoded at all** (a guest read returns nothing rather than plausible wrong geometry),
  `g6q run --backend native` warns, and the bridge warns while still packing (a packed image is
  placement-independent — it just cannot be delivered).
- Tests: placement ingested; placement absent and reported; window follows the stated base; the
  fallback and un-based offsets must *not* decode; unresolved is visible rather than invented.
  `g6q-vm` 87, `g6q-diag` 26.

Why absence is loud rather than defaulted: a wrong base relocates the *entire* descriptor while every
individual field still looks correctly placed relative to its neighbours, so the failure presents as a
driver or descriptor bug anywhere except where it is.

**Ask on the design (not an emulator change):** publish the island register-map placement as
localparams in the accelerator configuration package, alongside the `CAP_OFF_*` offsets already
there. Until then the pushed path is end-to-end exercisable only against a model that states the
bases.

### Change set B5 — self-review of B3/B4, and the RTL feedback ledger (Q6, landed)

Re-reading B3/B4 against the *reference packages* (not the fixtures) found two defects I had shipped
while claiming to remove exactly that defect class.

**Defect 1 — a dead lookup hiding a literal.** `submit()` resolved the supported descriptor version
via `desc_layout.op("DESC_VERSION")`. The reader only inserts `OP_*`-prefixed names into `ops`, and
the package has no such constant, so the lookup **could never resolve** and every call fell back to
the literal `1` while *looking* model-derived. Fixed: `AiDescLayout.version: Option<u64>` parsed from
a published constant; when absent the device uses a single named `FALLBACK_DESC_VERSION` with a
comment saying only a design-side constant can remove it. Recorded as ask **F2**.

**Defect 2 — capability names that do not match the package.** `cap_words()` matched invented names
(`qos_classes`, `work_quantum_k`, `acc_tile_*`, `noc_width`, `dram_channels`) while the package
publishes `qos`, `quantum`, `block_mnk`, `dtype_mask`. Four real capability words hit the `_ =>
continue` arm and vanished silently — and a guest reading an absent word gets zero, which is a legal
capability value, so nothing would have looked wrong. Fixed: names mapped to the package's own
spellings, plus `cap_unsourced()` reporting what cannot be sourced, a CLI warning naming them, and a
test pinning the published name set so an added capability surfaces as a tracked gap. The two packed
encodings stay unsourced by choice (ask **F3**) rather than transcribing a bit layout.

Landed:
- `AiDescLayout.version` in IR, JSON, schema; parsed from `DESC_VERSION`/`DESC_VER` when published.
- `AiIsland::cap_value` / `cap_unsourced`; CLI warns on unsourced capability words.
- Tests: published-name-set accounting (asserts only the packed pair is unsourced, and that `qos` /
  `quantum` / `dram_gbps` now answer); descriptor version honoured from the package.
  `g6q-vm` 89, `g6q-diag` 26, `g6q-core` 27.
- New `architecture/RTL_FEEDBACK.md`: asks **F1–F4** with what each unblocks and a dependency order,
  the cluster bring-up debug workflow (fastest instrument → D1 first divergence → checkpoint
  hand-off), and the change-set aggregation policy.
- `AGENTS.md` §6 gained two standing checklist items: unpublished constants become asks, never quiet
  defaults; and published *name sets* get a pinning test.
- Root `AGENTS.md` §2 points at the ledger.

Lesson worth keeping: "derived from the model" is not established by *calling a lookup*. Both defects
type-checked, passed the existing tests, and read as architecture-derived. Only comparing against the
real package caught them — which is why the name-set pinning test is now a checklist item.

### Change set C1 — B2 descriptor reassembly (Q7, landed)

Closes the gap `EMIT.md` had been overstating: the plugin now emits **submissions**, not raw accesses,
so the remote route produces the same artifact as the native one and cross-route comparison becomes
meaningful.

Landed:
- Plugin emits descriptor geometry from the model: `G6LC_AI_DESC_DECODE`, `_BASE`, `_BYTES`, and one
  `G6LC_AI_OFF_<FIELD>` / `_SZ_<FIELD>` pair per field the layout names.
- Per-hart descriptor shadow + `g6lc_desc_store` + `g6lc_desc_submit`; the event fires on the
  doorbell (descriptor offset 0) write.
- Store **values** come from `qemu_plugin_mem_get_value`, confirmed present in the pinned QEMU
  (plugin API v4) by reading the fetched header rather than assuming. Without it reassembly is
  impossible — the value is not otherwise exposed to a plugin.
- `DTYPE_SHIFT`/`DTYPE_MASK` moved to `g6q_core::model` as the single definition, used by both
  `g6q_diag::ai_tensor::dtype_from_flags` and the emitter, so they cannot drift. Recorded as ask F5.
- Emitted record uses the **native artifact's key set**, with layout-absent fields as zero rather
  than omitted, so a consumer cannot tell which backend produced an event.
- Self-gating: when the geometry is unresolved (F1), **no decoder is emitted at all** — not a `#if`
  around dead text. Decoding against a guessed base would produce plausible-looking wrong events.
- 4 new emitter tests: decode off when unresolved (both no-island and no-base cases), offsets come
  from the layout, store-value reassembly present, and artifact key-set agreement. `g6q-emit-qemu` 24.

### Change set C2 — topology conformance rules (Q8, landed)

The interrupt-budget arithmetic existed (`Soc::max_harts`, `hart_count_fits`) but was never
*reported*, so an illegal configuration ran silently.

Landed:
- `TargetModel::topology_rows()` emitting two conformance rows, wired into `g6q-ingest` after the
  capability rows:
  - `interrupt-contexts` — `Live` when the hart count fits the controller budget,
    **`Overdeclared`** when it exceeds it (refused under `--conform strict`; the surplus harts cannot
    receive interrupts), `Unresolved` when the budget is unknown rather than a silent pass;
  - `hart-topology` — compares what the tree declares against what the design provides:
    `Overdeclared` when the tree claims processors that do not exist (firmware would start them),
    `Undeclared` when it hides some (permitted with a warning — the guest simply runs on fewer).
- No tree read means no `hart-topology` row: absence of an input is not a finding.
- 3 new `g6q-core` tests covering fits / exceeds / unknown-budget and all three tree cases.
  `g6q-core` 30.

This is the package's core purpose applied to topology rather than to capabilities: the configuration
says what is enabled, the tree says what software is told, and the disagreement is the finding.

### Change set C6 — B2 queue-instruction submission path (Q7, landed)

The MMIO path from C1 only sees submissions that store to the latch window. A guest using the custom
enqueue instruction passes a descriptor *pointer* in a register, with the descriptor in guest memory —
invisible to any memory callback on the island region. The plugin now recognises the instruction.

Landed:
- Translate-time match: `(insn & G6LC_AI_ENQ_MASK) == G6LC_AI_ENQ_MATCH`, both emitted from the
  ingested `AiInstrSet`. `rs1` is extracted from the encoding and passed as callback userdata.
- Exec callback reads `rs1` via `qemu_plugin_get_registers` / `qemu_plugin_read_register`, then reads
  `G6LC_AI_DESC_BYTES` from that address via `qemu_plugin_read_memory_vaddr`, and emits the **same**
  submission record as the MMIO path.
- Registered with `QEMU_PLUGIN_CB_R_REGS`, not `NO_REGS` — the register read returns nothing
  otherwise. All three APIs verified against the fetched pinned header, not assumed.
- `G6LC_AI_ENQ_DECODE` gates the path and requires **both** the encoding and the descriptor geometry.
  A zero mask would match every instruction, so an un-ingested instruction set disables the path
  rather than defaulting it.
- 2 new tests: encoding comes from the model and the API calls are present; path absent when the
  instruction set is un-ingested *and* when the geometry is unresolved. `g6q-emit-qemu` 26.

One deliberate transcription, named in `EMIT.md`: the canonical RISC-V register names in index order,
because QEMU exposes registers under ABI names rather than `xN`. That is an ISA naming fact, not a
design contract, and both spellings are tried.

### Change set C7 — elaborate the configuration before reading it (Q1, landed)

Started as "add the accumulator-banks-below-threads rule" and the investigation changed the task.
`build_config_pkg.sv` does not merely *check* that relation — it **raises** `AccBanks` to `NrHarts`.
So the rule is not a violation to report; the *derivation* is behaviour to reproduce. Reading the
package literally was a live correctness bug, and a much broader one than the AI field:

| Written | Elaborated | Believing the package means |
|---|---|---|
| `RVZacas` on, `RVA` off | Zacas **masked off** | executing atomics the hardware traps — a guest-visible lie |
| `ZKN` on, `RVB` off | `RVB` **implied on** | refusing instructions the hardware has |
| `NrIssuePorts: 0` | inferred `SuperscalarEn ? 2 : 1` | a machine that cannot issue anything |
| `ALUBypass` on, not superscalar | forced off | modelling bypass the design does not build |
| `AccBanks < NrHarts` | raised to `NrHarts` | fewer accumulator banks than exist |

Landed:
- New `g6q-svcfg/src/derive.rs`: `derive(&mut Package) -> Vec<Derivation>` applying the documented
  derivations — masked dependencies, implied extensions, inferred issue width and ALU count, bypass
  forcing, speculative-store-buffer implication, accelerator-seam derivation, accumulator-bank floor.
  Each carries the field, the change and the **reason**, so it can be checked against the design's
  build step one by one.
- `g6q-ingest` elaborates the package **before** anything reads it, and records every applied
  derivation in `provenance.derivations`.
- `Provenance.derivations` in the IR, JSON and schema. Deliberately separate from `overrides`: a
  derivation is the design's own behaviour and must **not** mark the model unfaithful, whereas an
  override must.
- 12 `derive` tests + 2 ingest tests, including that Zacas does not reach the ISA surface as `live`
  when its dependency is off, and that a package needing no derivation records none.
  `g6q-svcfg` 48, `g6q-ingest` 21.
- `architecture/INGEST.md` §2.0a documents the distinction and the two load-bearing properties.

Two properties tested because both are load-bearing:
- **idempotence** — re-deriving an elaborated package reports no changes, so a caller can tell
  "already elaborated" from "needs elaborating";
- **a derivation is not an override** — it does not taint faithfulness.

Not guessed: derivations this reader cannot reproduce stay absent, and `legality` already reports the
corresponding rules as unchecked rather than as passes.

**C9 (landed, completes the correction sweep).** Added the two remaining corrections after reading the
build step's exact logic rather than working from recollection:
- `NrCommitPorts` — raised only under superscalar *and* only when the package asks for fewer than two
  ports. A commit width narrower than the issue width but at least two is **deliberate** in the
  design, so correcting it would model a machine the design does not build. Tested both ways.
- `NrLoadBufEntries` — raised to four entries per issue port, minimum eight, when deep speculation is
  enabled.
`g6q-svcfg` 51.

**Scope decision recorded in `INGEST.md` §2.0a:** the build step also *computes* fields the package
never writes (FP presence/width, the non-standard-extension flag, four transprecision vector flags,
write-back port count, physical and guest-physical address widths, page-table geometry). Those are
**not** mirrored, because nothing reads them yet and unconsumed fields are scaffolding. Two are the
first candidates when a consumer appears: the physical address width bounds any emitted memory map,
and the page-table geometry is what the native VM's walk should be sized by rather than an assumed
scheme.

### Change set C — D2 microarchitecture + virt distro readiness (Q7/Q8)

Goal: make the D2 counters and virt profile usable for distro scale.

Components:
- PMU event table ingestion from design package. **Landed** in prior pass.
- Generated PMU counter device tree and QEMU CPU properties. **Landed** — `/pmu` FDT node with OpenSBI-compatible raw and generic event-to-counter mappings, per-hart `interrupts-extended` for Sscofpmf, and generated `g6lc-*` CPU `ext_zihpm`/`ext_sscofpmf`/`pmu_mask`; B0 stock `-cpu` also appends `pmu-mask` when the model has counters live.
- QEMU counter plugin (B2) — still open; the FDT/CPU mapping is the prerequisite.
- Virtio block/network bridge for `g6lc-virt`.
- MTTCG determinism hooks (icount, inter-hart quantum).

These are intentionally larger than a single session and are listed here so work is not started in
scatter-shot commits.

---

## Deferred (with reopen conditions)

| Item | Reopen when |
|---|---|
| B3 T1/T2 JIT tiers | the interpreter is measurably the bottleneck for a stage gate |
| Host-hypervisor acceleration | MTTCG plateaus below need *and* a single-host-OS backend is acceptable |
| Full vector-extension semantics | after Q7; reported as `stub` until then |
| Pipeline / cycle modelling | never — an RTL simulator owns cycles |
| Multi-target single binary | a convenience, not a gate |

---

## Pass log

| Date | Pass | Outcome |
|---|---|---|
| 2026-08-30 | F6 cluster dispatch modelled from `queue_cluster_map` or `cluster` descriptor field | `g6q-core` `AiIslandConfig` adds `queue_cluster_map`; `schemas/target-model.schema.json` accepts the array; `g6q-diag/ai_cfg.rs` parses `QueueClusterMap` from the config struct or a top-level localparam; `g6q-vm` `read_descriptor_event` and the B2 `g6q-emit-qemu` plugin both resolve `cluster` from a `cluster` descriptor field, then `queue_cluster_map`, then leave it unresolved (0); tests in `g6q-diag`, `g6q-vm`, and `g6q-emit-qemu` cover all three sources; `architecture/RTL_FEEDBACK.md` F6, `AI_BRIDGE.md`, and `EMIT.md` updated. | `python tools/g6q.py check` green; `g6q-diag` 47, `g6q-vm` 108, `g6q-emit-qemu` 36 tests pass. |
| 2026-08-30 | Roofline traffic model corrected against `g6lc_ai_gemm_seq.sv` (F12, F13) | Read the live GEMM unit rather than trusting the plan's model, which invalidated part of the previous pass. Two design facts: (a) the engine is **whole-matrix-resident** (load all A → all B → MAC → store C), not `T`-blocked streaming, and `ST_CHK` **rejects** `m`, `n` or `k` > `MaxDim`, so the plan's own §12 acceptance shape `4096³` cannot be submitted as one descriptor — ask **F12**; (b) §4's `bytes/MAC = 2/T` counts **inputs only**, and the `s32` writeback `4·m·n` is *twice* the input traffic at `m = n = k = T`, making true intensity 42 rather than 128 MAC/byte — ask **F13**. `roofline.rs` now reports `compulsory_read_bytes` (`m·k + k·n`, no dataflow assumption), `tiled_read_bytes` (§4's model), `dram_read_bytes = max` of the two, `dram_write_bytes`, `shape_fits_blocking`, and separates total `intensity_mac_per_byte` from `tiled_input_intensity_mac_per_byte`. The old model was correct *only* at `m = n = k = T` — the one shape the first pass tested. New tests pin the small-shape floor, the writeback dominance, the blocking limit, and the maximal-shape coincidence that hid the bug. `RTL_FEEDBACK.md` §3.2 tabulates plan-vs-built; `DIAG.md` §4.3 gains the max-of-two rule and a fourth discipline. | `python tools/g6q.py check` green; `g6q-diag` 61 tests pass. |
| 2026-08-30 | D2 analytic roofline bound + F9 PMU-offset ingestion | New `g6q-diag/src/roofline.rs` applies the design's own bandwidth model (`scaling-100tops.md` §4) to the *ingested* island geometry: `gemm(cfg, m, n, k)` returns MAC-bound cycles, blocking `T` from the accumulator geometry, `dram_bytes = macs·2/T`, arithmetic intensity `T/2`, machine balance, and which resource binds. Every counter is `Fidelity::Modelled` (a bound, never `Exact`); an unmeasured `DramGBps` yields `None` for the bandwidth half rather than zero; `utilisation_percent` requires a design-side measurement the package cannot invent. Shape-independent rows (blocking/intensity/balance/peak) join `ai_island_counters`. Tests pin the plan's worked numbers — 98.3 TOPS at 8 clusters, balance ~123 vs §4's ~125, `T=512` compute-bound, `T=128` bandwidth-bound, and the measured `256³` point (65 536 MAC bound vs 83 705 measured = 78%, projected to collapse below 15% if the array widens without the memory path). `AiIslandConfig` gains `pmu_offsets` with a `PMU_OFF_*` reader (empty against the live package, asserted). New ask **F11** (unpublished `DramGBps` blocks the bandwidth half); `RTL_FEEDBACK.md` §3.1 gains a live-vs-SKU table; `DIAG.md` §4.3 documents the bound and its three discipline rules. | `python tools/g6q.py check` green; `g6q-diag` 58, `g6q-ingest` 25 tests pass. |
| 2026-08-30 | F10 descriptor arithmetic-type subfields (`dtype`/`accmode`/`ew`/`sp24`) made explicit | Reviewed the live island RTL and the 100-TOPS plan of record. `g6lc_ai_desc_pkg.sv` publishes only `desc_prio`/`desc_irq` plus one comment `flags[13:8] type fields (dtype/accmode/ew/sp24)`, which both understates the span (`sp24` is bit 14) and conflates three ABI fields — so the emulator was reporting an INT4 request as `dtype = 16`. `g6q-core` adds `FlagField` and extends `DescFlagsLayout` with `accmode`/`ew`/`sp24_bit`/`dtype_combined` + `arith_type_resolved()`; `g6q-diag/ai_desc.rs` prefers per-field accessors and marks the comment span as combined; schema updated; `fixtures/ai/g6lc_ai_desc_pkg.sv` publishes the accessors so the forward path is tested while a new test pins that the *live* package leaves them unresolved. New asks **F7** (cap-window layout: `scaling-100tops.md` §8 disagrees with shipped RTL from `0x14`), **F8** (`clusters_present`/`clusters_enabled` not split), **F9** (PMU offsets `0x180`–`0x18C` published only as comments) and **F10** recorded in `architecture/RTL_FEEDBACK.md`, with a new §3.1 explaining why F9/F10 gate the 100-TOPS programme. | `python tools/g6q.py check` green; `g6q-diag` 49, `g6q-ingest` 25 tests pass. |
| 2026-08-30 | F6 cluster dispatch end-to-end ingest test | Added `fixtures/ai/` with invented minimal AI packages and a `g6q-ingest` test `ai_island_ingestion_carries_queue_cluster_map` proving `build_ai_island_model` carries `queue_cluster_map`, descriptor layout, and instruction encodings through to `AiIslandModel`; `fixtures/README.md` updated. | `python tools/g6q.py check` green; `g6q-ingest` 24 tests pass. |
| 2026-08-30 | F4 descriptor word-order validation in `g6q-diag` | `g6q-diag/src/ai_desc.rs` `parse_ai_desc_pkg` cross-checks `bits_to_desc`, `desc_to_bits`, and the `desc_t` struct byte-offset comments; mismatches are reported as parse errors; tests `validates_word_order_against_desc_t_comments_and_desc_to_bits`, `rejects_desc_t_comment_mismatch`, and `rejects_bits_to_desc_desc_to_bits_mismatch` cover the three failure modes; `architecture/RTL_FEEDBACK.md` F4 and `AI_BRIDGE.md` state table updated. | `python tools/g6q.py check` green; `g6q-diag` 45 tests pass. |
| 2026-08-30 | B3 `ai.poll` writes the completion word to `ptr_done` | `g6q-vm/src/device.rs` adds `queue_poll_details(ticket)` returning `(word, ptr_done)`; `g6q-vm/src/exec.rs` `execute_ai_poll` writes the completion word to `ptr_done` only when the entry is done (not while pending); `g6q-vm` test `ai_poll_writes_completion_word_to_ptr_done` covers the end-to-end writeback; `architecture/DIAG.md` §4.1 updated. | `python tools/g6q.py check` green; `g6q-vm` 108 tests pass. |
| 2026-08-30 | B3 `ai.qfence` writes completion words to `ptr_done` | `g6q-vm/src/device.rs` `queue_qfence` returns `(ptr_done, completion_word)` pairs; `g6q-vm/src/exec.rs` `execute_ai_qfence` writes them to guest memory; `g6q-vm` tests `queue_qfence_writes_completion_words_to_memory` and `ai_enq_reads_descriptor_and_qfence_writes_completion` cover the end-to-end path; `architecture/DIAG.md` §4.1 and `AI_BRIDGE.md` state table updated. | `python tools/g6q.py check` green; `g6q-vm` 106 tests pass. |
| 2026-08-30 | B3 `ai.enq` reads descriptor from guest memory | `g6q-vm/src/device.rs` adds `AiIsland::read_descriptor_event` and `queue_enq_with_event`; `g6q-vm/src/exec.rs` reads the descriptor from `PhysMem` before enqueuing; `g6q-vm` test `queue_enq_reads_descriptor_from_memory` covers recovery of all descriptor fields and `dtype` from `flags_layout`; `architecture/DIAG.md` §4.1 and `AI_BRIDGE.md` state table updated. | `python tools/g6q.py check` green; `g6q-vm` 104 tests pass. |
| 2026-08-30 | F5 follow-up — bridge uses `flags_layout` to recover `dtype` | `tools/ai_tensor_bridge.py` `TensorArtifact` reads `flags_layout` from the artifact and uses it to recover `dtype` from `flags` when missing; `summary()` and `pytorch_summary()` report the recovered value; selftest verifies recovery; `architecture/AI_BRIDGE.md` §5 and state table updated. | `python tools/g6q.py check` green; bridge selftest OK. |
| 2026-08-30 | F5 follow-up — remove `DTYPE_SHIFT`/`DTYPE_MASK` from `g6q-core` | `g6q-core` removes the `DTYPE_SHIFT`/`DTYPE_MASK` constants; `g6q-diag/ai_tensor.rs` adds `TensorTrace.flags_layout`, `TensorArtifact` serializes/recovers it, and `AiTensorEvent::dtype_from_flags` takes `&DescFlagsLayout`; `g6q-emit-qemu` emits the full `flags_layout` into the tensor artifact header and emits `G6LC_AI_PRIO_SHIFT`/`MASK`/`IRQ_BIT`; `g6q-cli` writes `TensorArtifact` with the model's layout; `architecture/RTL_FEEDBACK.md` F5 updated. | `python tools/g6q.py check` green; `g6q-diag` 42, `g6q-emit-qemu` 35, `g6q-cli` 50, workspace tests pass. |
| 2026-08-30 | F5 descriptor `flags_layout` pass | `g6q-core` adds `DescFlagsLayout` with `dtype/priority/irq` subfields and `AiDescLayout.flags_layout`; `g6q-diag/src/ai_desc.rs` parses them from `g6lc_ai_desc_pkg.sv` comments and `desc_prio`/`desc_irq` helpers; `schemas/target-model.schema.json` accepts `flags_layout`; `g6q-emit-qemu` emits `G6LC_AI_DTYPE_SHIFT`/`MASK` from the ingested layout and requires `flags_layout` for descriptor decode, removing the hard-coded constant from the emitter; `architecture/RTL_FEEDBACK.md` F5 updated. | `python tools/g6q.py check` green; `g6q-diag` 42, `g6q-emit-qemu` 35 tests pass. |
| 2026-08-30 | `cap_packed` capability words pass | `g6q-core` adds `CapPackedField`/`CapPackedWords`; `g6q-diag/src/ai_cap.rs` parses `dram_gbps` and `queues` packed-word layouts from `g6lc_ai_cap_window.sv`; `g6q-ingest` sets `config.cap_packed` from the cap window; `g6q-vm` `cap_value` packs words using the field list; tests `the_capability_window_answers` and `every_published_capability_name_is_accounted_for` cover packed values; `architecture/RTL_FEEDBACK.md` F3 updated; `schemas/target-model.schema.json` accepts `cap_packed`. | `python tools/g6q.py check` green; `g6q-diag` 42, `g6q-vm` 103 tests pass. |
| 2026-08-30 | B3 `queue_poll` returns packed completion word pass | `g6q-vm/src/device.rs` adds `AiIsland::pack_completion_word(ticket, status)` and `completion_word()` delegates to it; `queue_poll` returns the packed completion word when the entry is done, `0xffff_ffff` while pending, and the `ST_OK` completion word for unknown/retired tickets; `g6q-vm` test `rings_come_from_the_model` updated; `architecture/EMIT.md` §Completion documents B3/B2 alignment. | `python tools/g6q.py check` green; `g6q-vm` 103 tests pass. |
| 2026-08-30 | `block_mnk` capability window resolution pass | `g6q-core` `AiIslandConfig` gains `CapBlockMnk` and `block_mnk: Option<CapBlockMnk>`; `g6q-diag/src/ai_cap.rs` parses the `14'h05:` case arm and computes `m/n/k` low bits/widths; `g6q-ingest` sets `config.block_mnk` from `g6lc_ai_cap_window.sv`; `g6q-vm` `cap_value` packs the word from `clog2(AccTile*)` and the ingested layout; `g6q-vm` tests `the_capability_window_answers` and `every_published_capability_name_is_accounted_for` now cover `block_mnk` and `dtype_mask`; `schemas/target-model.schema.json` accepts `block_mnk`; `architecture/RTL_FEEDBACK.md` F3 updated. | `python tools/g6q.py check` green; `g6q-diag` 40, `g6q-vm` 103 tests pass. |
| 2026-08-30 | `dtype_mask` capability window resolution pass | `g6q-core` `AiIslandConfig` gains `dtype_mask: Option<u32>`; `g6q-diag/src/ai_cap.rs` (new module) parses `DtypeMask` from `g6lc_ai_cap_window.sv`; `g6q-ingest` reads the cap window from the flist and sets `config.dtype_mask`; `g6q-vm` `cap_value` sources `dtype_mask`; `g6q-vm` test now expects only `block_mnk` as unsourced; `schemas/target-model.schema.json` accepts `dtype_mask`; `architecture/RTL_FEEDBACK.md` F3 updated. | `python tools/g6q.py check` green; `g6q-diag` 38, `g6q-vm` 103 tests pass. |
| 2026-08-30 | `ai.poll` B2 completion path pass | `g6q-core` `AiDescLayout` gains `CompletionLayout` with ticket/status bit ranges; `g6q-diag/src/ai_desc.rs` parses `make_completion` from `g6lc_ai_desc_pkg.sv`; `g6q-emit-qemu/src/plugin.rs` emits `G6LC_AI_COMPLETION_*` macros and `g6lc_ai_poll_exec` that reads `rs1` ticket and the 8-byte completion word at `ptr_done`, marking the matching event done when ticket and `G6LC_AI_ST_OK` match; `schemas/target-model.schema.json` accepts `desc_layout.completion`; `architecture/EMIT.md` section Completion documents the `ai.poll` path; `g6q-emit-qemu` tests for poll presence and absence without completion layout. | `python tools/g6q.py check` green; `g6q-diag` 36, `g6q-emit-qemu` 33, `g6q-cli` 50, `g6q-vm` 102, `ai-bridge` selftest pass. |
| 2026-08-30 | B3 completion word uses `make_completion` layout pass | `g6q-vm/src/device.rs` `AiIsland::completion_word()` packs the completion word from the ingested `CompletionLayout`, with the same fallback the B2 path uses; `g6q-vm` `MmioDevice::load` for the `completion` register uses it; `g6q-vm` tests add `completion` to `model_with_layout()` and a swapped-layout test to prove packing is layout-driven. | `python tools/g6q.py check` green; `g6q-vm` 103 tests pass. |
| 2026-08-30 | B2 ptr_done store completion decoding pass | `g6q-emit-qemu/src/plugin.rs` extracts the 64-bit stored word and passes it to `g6lc_tensor_complete_by_ptr_done`; when the `CompletionLayout` resolves it decodes ticket/status from `G6LC_AI_COMPLETION_*` macros and only marks the matching in-flight event done with `G6LC_AI_ST_OK`; falls back to address-match completion when the layout is unresolved; `architecture/EMIT.md` §Completion updated; two new emitter tests. | `python tools/g6q.py check` green; `g6q-emit-qemu` 35 tests pass. |
| 2026-08-28 | Cluster-aware tensor artifact pass (RTL-relevant bridge) | `g6q-core` `AiTensorEvent` gains `cluster: u32`; `g6q-diag` `to_json`/`from_json` default missing `cluster` to `0`; `g6q-emit-qemu/src/plugin.rs` `EVENT_FIELDS` and generated C carry `cluster`; `g6q-vm/src/device.rs` `queue_enq` sets `cluster: 0` and records the unresolved dispatch as `RTL_FEEDBACK.md` F6; `tools/ai_tensor_bridge.py` `summary` adds `by_cluster` and `clusters` from model, `pytorch_summary` includes `cluster`; `architecture/AI_BRIDGE.md` §5 and `architecture/RTL_FEEDBACK.md` F6 updated. | `python tools/g6q.py check` green; `g6q-diag` 36, `g6q-emit-qemu` 31, `g6q-cli` 50, `g6q-vm` 102, `ai-bridge` selftest pass. |
| 2026-08-28 | Host bridge PyTorch consumer pass | `tools/ai_tensor_bridge.py` `DescLayout` adds `op_name()` and `status_name()` reverse lookups; `TensorArtifact.summary(layout)` resolves op/status codes to the design's names and adds `by_dtype`, `inflight`, and `by_op_name`/`by_status_name` when a model is supplied; `TensorArtifact.pytorch_summary(layout)` returns one record per completed operation with `op_code`, `op_name`, `status_code`, `status_name`, `shape_m/n/k`, `dtype`, and A/B/C/output pointers; `cmd_results` accepts `--model` and `--per-event`; `architecture/AI_BRIDGE.md` §5 documents the Python/PyTorch consumer route. | `python tools/g6q.py check` green; `ai-bridge` selftest passes. |
| 2026-08-28 | B2/B3 tensor artifact profile header pass (closes the G13 artifact-shape gap) | `g6q-cli/src/main.rs` writes the B3 tensor `header` with `g6q_diag::ArtifactHeader::from_model`, so `profile` is the machine profile (`g6lc-soc`/`g6lc-virt`) and `profile_tainted` reflects `model.diagnosable()` instead of using the target id; `g6q-emit-qemu/src/plugin.rs` emits `#define G6LC_PROFILE` from `model.profile.as_str()` and writes it into the B2 trace record header and the B2 tensor event header in place of `G6LC_TARGET_ID`; `g6q-emit-qemu` test checks `G6LC_PROFILE` is present. Keeps the generated log prefix at `[g6lc-%s]` via `G6LC_TARGET_ID`. | `python tools/g6q.py check` green; `g6q-cli` 49, `g6q-emit-qemu` 30; `indep`, `flist`, and `ai-bridge` selftests pass. |
| 2026-08-28 | Tensor artifact wrapper + `diag --tensor` comparison pass (continues G13) | `g6q-diag/src/ai_tensor.rs` adds `TensorArtifact` with an `ArtifactHeader` and a `TensorTrace`, plus `to_json`/`from_json`/`from_file` that accept both the wrapped `{"header":..., "events":[...]}` form and a bare event array; `TensorArtifact::compare` reports profile, taint, event count and first differing event. `g6q-cli/src/main.rs` `diag --tensor` now accepts one artifact (merge counters) or two artifacts (compare and fail on divergence). `g6q-emit-qemu/src/plugin.rs` emits the qfence instruction mask/match/decode macros as scaffolding for B2 completion tracking. | `python tools/g6q.py check` green; `g6q-cli` 50, `g6q-diag` 36; `indep`, `flist`, and `ai-bridge` selftests pass. |
| 2026-08-28 | B2 plugin tensor event completion tracking pass (closes G13 qfence + ptr_done + ticket + taint + st_ok) | `g6q-emit-qemu/src/plugin.rs`: `g6lc_desc_submit` appends `G6lcTensorEvent` to `g6lc_tensor_events[hart]` and assigns `ev.ticket = g6lc_next_ticket[hart]++`; `g6lc_tensor_event_write` emits the native `TensorArtifact` JSON with `ticket`, `status`, and `done` (`"true"`/`"false"`); `g6lc_atexit` writes all buffered events and frees the arrays; `g6lc_ai_qfence_exec` marks in-flight events done using `G6LC_AI_QFENCE_MASK`/`G6LC_AI_QFENCE_MATCH`; `g6lc_tensor_complete_by_ptr_done` marks an event done on a guest store to its `ptr_done` address; `G6LC_PROFILE_TAINTED` is derived from `model.diagnosable()` and used for both trace and tensor artifact headers; `G6LC_AI_ST_OK` is emitted from `desc_layout.status("ST_OK")` and used for completion status. `g6q-diag/src/ai_tensor.rs` adds `ai.tensor.completes` to `tensor_counters`. `architecture/EMIT.md` §B2 and `architecture/DIAG.md` §4.1 updated. `g6q-emit-qemu` tests for qfence, qfence absence, ticket allocation, taint macro, `G6LC_AI_ST_OK`, and the artifact shape. | `python tools/g6q.py check` green; `g6q-emit-qemu` 31, `g6q-diag` 36 tests; `indep`, `flist`, and `ai-bridge` selftests pass. |
| 2026-08-30 | Q9 capability matrix | **done** — `g6q-ingest/src/matrix.rs` builds a JSON matrix from `Sources` and the capability table, one row per capability with `config` probe/value, `flist` probe/evidence, `dts` tokens/node/declared, `qemu` properties/delta, and the conformance `verdict`; `gen --emit matrix` wired in `g6q-cli/src/main.rs`; `g6q-core/src/json.rs` added `get`, `is_null`, `is_empty`, `as_array`, and `as_string` accessors; `g6q-flist/src/lib.rs` added `Presence::as_str`; tests cover matrix shape and the unsupported-QEMU delta. `architecture/CLI.md` and `architecture/IR.md` updated.
|| **Q10** computed-only MMU geometry | **done** — `g6q-core/src/model.rs` `Isa` gains `paddr_bits`, `vaddr_bits`, `page_table_levels`, `vpn_bits`, and `satp_mode`; `g6q-ingest/src/lib.rs` derives these from `mmu_mode` + `xlen` for `sv32`, `sv39`, and `sv48`; `g6q-vm/src/mmu.rs` is now model-driven: a `Mmu` struct is built from `Isa` and used by `translate(mem, mmu, satp, vaddr)`, supporting bare, Sv32, Sv39, and Sv48 geometry; `g6q-vm/src/exec.rs` `Hart` stores a `Mmu`, `Hart::with_isa` derives it from the model, and `Hart::new` defaults to bare; CLI `run` uses `Hart::with_isa`; unit tests cover bare, Sv39 1 GiB leaf, non-canonical detection, and mode mismatch. `architecture/INGEST.md` and `schemas/target-model.schema.json` updated.
|| 2026-08-30 | MMU PTE-size and Sv32/Sv48 coverage | `g6q-vm/src/mmu.rs` derives PTE width from `Isa.xlen` (4 bytes for RV32/Sv32, 8 bytes for RV64/Sv39/Sv48), uses the correct RV32/RV64 `satp` mode/PPN layout, and walks 4-byte or 8-byte PTEs at `vpn * pte_bytes`. New tests cover Sv32 4 KiB and 4 MiB leaves, Sv39 2 MiB leaf, and Sv48 4 KiB/2 MiB/1 GiB leaves plus Sv48 non-canonical rejection.
|| 2026-08-30 | Measured DRAM bandwidth closes the roofline loop (F11 / F14) | `g6q-core` `AiIslandConfig` gains `measured_dram_gbps_x1000: Option<u32>`; `schemas/target-model.schema.json` accepts it as `integer|null`; `g6q-diag/src/roofline.rs` uses the measured value when present and falls back to the nameplate `dram_gbps` otherwise, computing the bandwidth bound in milli-GB/s to avoid precision loss; `g6q-diag/src/lib.rs` adds `Fidelity::Measured` so design-side measured counters are comparable for equality; `g6q-diag/src/uarch.rs` emits `ai.island.measured_dram_gbps_x1000` as `Measured`; `g6q-vm/src/device.rs` `pack_cap_packed` publishes the measured half of `CAP_OFF_DRAM_GBPS` and saturates values above 16 bits, matching `g6lc_ai_cap_window.sv`; `g6q-cli/src/main.rs` adds `--measured-dram-gbps-x1000` to `diag` so a host-supplied measurement overrides the model, with a test that builds a tiny repo root with an AI island and proves `ai.island.measured_dram_gbps_x1000` and `ai.roofline.balance_mac_per_byte` appear in `--uarch-out`; `architecture/CLI.md` documents the option. `tools/ai_tensor_bridge.py` adds a `diag` subcommand with `--measured-dram-gbps` (GB/s) that passes the converted milli-GB/s value to `g6lc-qemu`, so the host bridge can close the F11 loop without waiting for RTL PMU wiring; `architecture/AI_BRIDGE.md` §5 adds `diag` to the bridge table and updates `push` to describe `--uarch-out` and `--measured-dram-gbps`. `architecture/RTL_FEEDBACK.md` updates F11 (emulator side closed, RTL still must drive the value) and adds F14 (16-bit measured half cannot represent the 400 GB/s target in 1/1000 units without saturating). | `python tools/g6q.py check` green; `g6q-diag` 63, `g6q-vm` 109, `g6q-core` 34, `g6q-ingest` 25, `g6q-cli` 51 tests pass. |
|| 2026-08-30 | Q7 AI-island D2 structure counters | `g6q-diag/src/uarch.rs` adds `ai_island_counters` to emit `ai.island.*` counters from the ingested `AiIslandConfig` (`clusters`, `sram_bytes`, `acc_tile.m/n/k`, `noc_width`, `dram_channels`, `queues`, `queue_depth`, `qos_classes`, `work_quantum_k`, `clock_khz`) as `Fidelity::Exact` geometry values, and marks `macs_per_cycle` and `dram_gbps` as `Fidelity::Synthetic` because the emulator does not model throughput or bandwidth. `g6q-diag/src/lib.rs` exports the new function; tests cover both geometry and fidelity.
|| 2026-08-30 | Q5 `diag` verb with `--uarch-out` | `g6q-diag/src/uarch.rs` adds `model_counters` to combine CPU-side `uarch.*` and `ai.island.*` counters; `g6q-diag/src/lib.rs` re-exports it. `g6q-cli/src/main.rs` implements `cmd_diag`, rejecting virt-profile diagnosis unless `--allow-virt-diag` is set, and writes D2 counter JSON via `--uarch-out` (or prints to stdout). `g6q-cli` tests updated to use `dts` as the unimplemented-verb example and to verify `diag` writes counter output.
|| 2026-08-30 | Q5 tensor-trace reader + `diag --tensor` | `g6q-diag/src/ai_tensor.rs` adds `AiTensorEvent::from_json` (recovering `dtype` from `flags` when `dtype` is absent), `TensorTrace::from_json`, `TensorTrace::from_file`, and a round-trip test. `g6q-cli/src/main.rs` `cmd_diag` reads `--tensor FILE` and merges `ai.tensor.*` counters from the event stream. `g6q-cli` test verifies `diag` with both `--uarch-out` and `--tensor` emits the combined counter set.
|| 2026-08-30 | Q3 native VM Sv32/Sv48 fetch tests | `g6q-vm/src/exec.rs` adds `sv32_four_megabyte_page_fetches_and_advances_pc` and `sv48_one_gigabyte_page_fetches_and_advances_pc` end-to-end tests: a `Hart` with the matching `Mmu` geometry walks a real page table and fetches a `lui` instruction through Sv32 (4 MiB leaf, `xlen=32`) and Sv48 (1 GiB leaf, two-level table, `xlen=64`).
|| 2026-08-30 | Q7 expanded D2 structure counters | `g6q-diag/src/uarch.rs` adds `structure_counters` mappings for `NrIssuePorts`/`NrCommitPorts`/`NrWbPorts`/`NrALUs`/`SuperscalarEn`, SMT `SmtFetchQuantum`/`SmtStarveLimit`, AXI `AxiAddrWidth`/`AxiDataWidth`/`AxiIdWidth`/`MemTidWidth`, cache geometry (`IcacheSetAssoc`/`DcacheSetAssoc`/`L2SetAssoc`/`L3SetAssoc`, line widths, data banks), and interface enables `CvxifEn`/`ZawrsEn`/`HwPrefetchStreams`. All are `Fidelity::Exact`; zero or inferred fields are still skipped.
|| **Q9** capability matrix pass: new `g6q-ingest/src/matrix.rs` builds a JSON capability matrix from `Sources` and the design's own capability table; each row exposes the `config` probe and resolved value, the `flist` probe kind + implementing/stub path fragments + evidence, the `dts` tokens/node/declared status, and the stock-QEMU `qemu` properties or the delta when stock QEMU cannot express the capability; the row carries the same `verdict` as the conformance report. `g6q-cli/src/main.rs` adds `gen --emit matrix` and writes to `--json-out`. `g6q-core/src/json.rs` adds `get`, `is_null`, `is_empty`, `as_array`, and `as_string` accessors. `g6q-flist/src/lib.rs` adds `Presence::as_str`. `architecture/CLI.md` and `architecture/IR.md` updated. | `python tools/g6q.py check` green; `g6q-ingest` 23, `g6q-cli` 47; `indep` and `flist` selftest pass. |
|| 2026-08-30 | Q7 B2 PMU counter plugin pass: new `g6q-emit-qemu/src/pmu.rs` generates `contrib/plugins/g6lc-<target>-pmu.c` from `TargetModel.pmu` (event names, `mhpmevent` selectors, `counter_count`); the plugin uses the QEMU v4+ TCG plugin API to maintain per-hart instruction and per-hart/per-event counters, writes a counters JSON file at exit, and prints a per-hart summary; `g6q-cli/src/main.rs` adds `gen --emit qemu-pmu-plugin` and includes the file in `gen --emit qemu`; `g6q-emit-qemu/src/lib.rs` exposes `pub mod pmu`; tests verify the GPL header, QEMU plugin API symbols, PMU macros, and the CLI dispatch. `architecture/CLI.md` and `architecture/EMIT.md` updated. This is a sampling/scaffold plugin; it cannot read the guest's `mhpmevent` CSRs, so all published events are counted and a later pass can map live `mhpmevent` values via a QEMU helper or tandem reference. | `python tools/g6q.py check` green; `g6q-emit-qemu` 29, `g6q-cli` 46; `indep` and `flist` selftest pass. |
|| 2026-08-30 | Q8 distro virt surface pass: `BootOptions` gains `drive_format`, `console`, `virtio`, and `os`; `build_argv` honours `--rootfs-format raw|qcow2` in `-drive format=...`; `--console virtio` adds `virtio-serial-device` + `virtconsole,chardev=serial0` and is rejected on the faithful profile; `--virtio rng` adds `rng-random,id=rng0` + `virtio-rng-device`; `--os buildroot|ubuntu|debian|fedora` forces the `g6lc-virt` profile, selects `qcow2` as the default rootfs format (overridable with `--rootfs-format`), supplies a default `root=/dev/vda rw console=ttyS0` append unless the caller passes `--append`, and searches `--distro-root` (default `out/dist/<os>`) for `vmlinuz`/`Image`, `initrd.img`, and `rootfs.qcow2` when those images are not explicitly named; `g6q-cli/resolve.rs` wires all of these. Tests cover qcow2 drive format, virtio console profile gating, virtio-rng emission, distro profile gating, append defaults, and `--distro-root` image search. `architecture/CLI.md` and `architecture/EMIT.md` updated. | `python tools/g6q.py check` green; `g6q-emit-args` 28, `g6q-cli` 43; `indep` and `flist` selftest pass. |
|| 2026-08-30 | Q8 MTTCG / deterministic icount / smp policy pass: `g6q-emit-args` gains `Icount` enum and `BootOptions` fields for `maxcpus`, `icount`, and `mttcg`; `build_argv` derives `-smp` from `harts_total` and, when `Soc.cores`/`threads_per_core` divide `smp` evenly, emits `cores=C,threads=T,sockets=S`; `maxcpus` is the hotplug ceiling bounded below by `smp`; `--icount N` sets `shift=N,align=off,sleep=off` and forces `-accel tcg,thread=single` because MTTCG is incompatible with instruction counting; `--tcg-tuning tuned` requests multi-threaded TCG when `smp > 1`; `--smp auto` maps to the model default; `g6q-cli/resolve.rs` parses all four. Tests cover topology, maxcpus, icount shift, deterministic single-thread, tuned multi-thread, and icount suppressing an MTTCG request. `architecture/CLI.md` and `architecture/EMIT.md` updated. | `python tools/g6q.py check` green; `g6q-emit-args` 25, `g6q-cli` 43; `indep` and `flist` selftest pass. |
|| 2026-08-30 | Q7 PMU FDT/CPU mapping pass (Change Set C part 2): `PmuTable.counter_mask()` and `counter_mask` JSON field; OpenSBI-compatible `/pmu` FDT node emitted by `g6q-emit-qemu/dts.rs` with `compatible = "riscv,pmu"`, `interrupts-extended` per hart to `cpu-intc` 13 (Sscofpmf LCOFIP), `riscv,event-to-mhpmcounters` for generic `cycles`/`instructions` (mcycle/minstret), and `riscv,raw-event-to-mhpmcounters` rows from the ingested `{group, index, mhpmevent}` table (selector + all-ones mask + programmable-counter bitmap); reserved events filtered from the raw mapping. Generated QEMU CPU (`g6q-emit-qemu/cpu.rs`) sets `cpu->cfg.ext_zihpm`, `cpu->cfg.ext_sscofpmf`, and `cpu->cfg.pmu_mask` (or disables them explicitly when absent). B0 stock QEMU (`g6q-emit-args/invoke.rs`) appends `-cpu ...,pmu-mask=0x...` when `zihpm` is live. `g6q-svcfg/derive.rs` now derives `RVZihpm` from `PerfCounterEn`; `crates/g6q-ingest/data/capabilities.ini` gates `zihpm` on `RVZihpm` and `perf_counters` flist. Tests: `g6q-core` `counter_mask` and JSON field; `g6q-emit-qemu` FDT/CPU PMU; `g6q-emit-args` B0 `pmu-mask`; `g6q-svcfg` `RVZihpm` derivation. `schemas/target-model.schema.json` updated. | `python tools/g6q.py check` green; full workspace pass; `indep` and `flist` selftest pass. `AGENTS-todo.md` and `architecture/EMIT.md` updated. |
|| 2026-08-30 | Q8 PMU event table ingestion + D2 structure models (Change Set C part 1): new `g6q-core/src/pmu.rs` parses `core/perf_counters.sv` and `core/include/ariane_pkg.sv` to build a `PmuTable` of `{group, index, name, mhpmevent}` preserving the `{group[7:5], idx[4:0]}` encoding, group tags from section comments and AI index names from the package; `g6q-ingest` populates `TargetModel.pmu` from the flist and `TargetModel.uarch` as a raw map of scalar config fields; `g6q-diag/src/uarch.rs` emits `uarch.*` structure-size counters (`Fidelity::Exact`) from that map, skipping zero/infer fields; `uarch` + `pmu` added to the model JSON and schema. Verified on a real `g6lc64_ooo` model: `counter_count` 6, `grp_width` 3, `idx_width` 5, `uarch` populated. Fixed `g6q-ingest` file lookup to match by base name and fixed `g6q-core/pmu` to strip SV comments and extract `localparam` statements individually so `;` in comments and `endfunction` boundaries do not swallow constants. | `python tools/g6q.py check` green; `g6q-core` 32, `g6q-diag` 28, `g6q-ingest` 21; full workspace pass; `indep` and `flist` selftest pass. `architecture/INGEST.md`, `DIAG.md`, `IR.md` and `AGENTS-todo.md` updated. |
| 2026-08-30 | Architecture review (PCIe endpoint, 100-TOPS scaling, SMT2/ai-tensor Linux track): read `architecture/ai-matrix/scaling-100tops.md`, `architecture/uncore/pcie-endpoint.md`, `architecture/uncore/pcie-root-complex.md`, `architecture/g6lc-qemu/os-linux-matrix.md` and `architecture/multi-threading/smt2-ai-tensor-linux.md`; distilled implications for `g6lc_qemu` into `architecture/AI_BRIDGE.md` §6.1 (two-plane split, staged SKU, virtio/BAR4 control+bulk, endpoint-not-root-complex, transport remains unpinned) and `AGENTS.md` extension-playbook row (host adapter stays outside this tree). No new code; no unsubstantiated throughput or multi-card claims. | `python tools/g6q.py check` green after doc-only changes. |
| 2026-08-27 | Q0: package surface (`AGENTS*`, `README`, `LICENSE`, `pins.toml`), in-tree `architecture/`, Python spine (`g6q.py`, `env_common.py`, `flist_expand.py`, `check_independence.py`), Cargo workspace + nine std-only crate skeletons, synthetic fixtures, JSON schemas. | Package independent and compiling; `check` green on fixtures. Q1 unblocked. |
| 2026-08-27 | Q1: configuration reader + legality rules; manifest membership with a three-valued presence; device-tree parser + semantic extraction; `g6q-ingest` (10th crate) with the data-driven capability table; `gen` and `conform` implemented. Contained toolchain provisioned by `setup`. | 174 tests green on the package's **own** toolchain; 21 packages and 7 trees soaked; model byte-identical on re-run. Q2 unblocked. |
| 2026-08-27 | Q3 pass: native VM Zbb bit-manipulation instructions (`andn`, `orn`, `xnor`, `clz`, `ctz`, `cpop`, `clzw`, `ctzw`, `cpopw`, `min`, `max`, `minu`, `maxu`, `rol`, `ror`, `rori`, `rolw`, `rorw`, `roriw`, `rev8`, `orc.b`, `sext.b`, `sext.h`, `zext.h` for RV32/RV64), decode/execute/tests, plus corrected Zbb unit-test register and value expectations. | `python tools/g6q.py check` green; 61 workspace tests pass; `indep` and `flist` selftest pass. |
|| 2026-08-29 | Q3 F-extension pass (single-precision RV32F/RV64F): `Fregs` NaN-boxed 32-register file; `fflags`/`frm`/`fcsr` CSRs; `CommitRecord` FP writeback fields; decoder/execute for FLW/FSW, FMADD/FMSUB/FNMSUB/FNMADD, FADD/FSUB/FMUL/FDIV/FSQRT, FSGNJ/N/X, FMIN/FMAX, FCVT.W/WU/L/LU and S.W/WU/L/LU, FMV.X.W/X.W, FEQ/FLT/FLE, FCLASS; unit tests and commit-record tests. | `python tools/g6q.py check` green; 67 workspace tests pass; `indep` and `flist` selftest pass. FMA/arithmetic use host `f32` as a bring-up implementation; explicit rounding mode and full IEEE-754 exception flag modelling remain for a later pass. |
|| 2026-08-30 | Q4/Q5 remote trace pass: QEMU debug logging (`--debug`/`--debug-file` to `-d`/`-D`), B2 trace-record plugin with `order`, `hart`, `pc_rdata`, `pc_wdata`, `insn`, `trap`, `cause`, `prv`, `halt`, `rd_addr`, `rd_wdata`, `frd_addr`, `frd_wdata`; numeric JSON fields; AI-island MMIO access counter from model-derived base/length; `g6q_remote.py` shell wrapper fixes so configure/build/plugin/payload commands see `ninja`, cross-toolchain and `~/.local/bin` uniformly; `run --backend qemu --record FILE` auto-loads the generated plugin and copies the temporary trace; `tandem` accepts wrapped `RecordFile` objects and raw arrays; live remote `g6lc-mini` AI-island smoke with `AI_OK` and `ai_island_count=3`; trace pulled and `tandem` reports 40 records with no divergence. | `python tools/g6q.py check` green; 77 workspace tests pass; `indep` and `flist` selftest pass. `architecture/CLI.md`, `DIAG.md`, `EMIT.md` updated. |
| 2026-08-29 | Q5/Q6 RVFI dasm bridge pass: new `g6q-diag/src/rvfi.rs` parser for `trace_rvfi_hart_*.dasm`; handles `core:`, `core N:`, `x10`, `x 8`, `mem`, exception and `wfi` lines; derives `pc_wdata` and `halt`; maps exception names to `mcause`; CLI `tandem` loads `.dasm` inputs; validated on a real `trace_rvfi_hart_00.dasm` from CVA6 verif/sim (17 records, self-tandem green); G12 resolved. | `python tools/g6q.py check` green; 16 diag tests pass; `indep` and `flist` selftest pass. `architecture/DIAG.md` §2.4 and `AGENTS-todo.md` updated. |
| 2026-08-29 | Q3 D-extension pass (double-precision RV32D/RV64D): D FPR raw 64-bit accessors; decoder/execute for FLD/FSD, FMADD/FMSUB/FNMSUB/FNMADD.D, FADD/FSUB/FMUL/FDIV/FSQRT.D, FSGNJ/N/X.D, FMIN/FMAX.D, FCVT.S/D and D/S, FCVT.W/WU/L/LU.D and D.W/WU/L/LU, FMV.X.D/D.X, FEQ/FLT/FLE.D, FCLASS.D; unit tests; fixed FCLASS.S/D decoder `rs2=0` bug. | `python tools/g6q.py check` green; 69 workspace tests pass; `indep` and `flist` selftest pass. FMA/arithmetic use host `f64` as a bring-up implementation; explicit rounding mode and full IEEE-754 exception/NaN propagation remain for a later pass. |
| 2026-08-29 | Q6/Q7 AI-island clustering analysis pass (Change Set B part 1): expanded `AGENTS-todo.md` and `architecture/EMIT.md`/`DIAG.md` with tensor-trace plugin, queue-ring model and AI D2 counters; added `g6q-diag/src/ai_cfg.rs` to parse `g6lc_ai_island_cfg_pkg.sv` (validated on the real file at `E:/cva6/corev_apu/include/g6lc_ai_island_cfg_pkg.sv`); added `g6q-core::model::AiIslandConfig` to `Soc`; wired `g6q-ingest` to derive it from the flist so `TargetModel.soc.ai_island` now carries clusters, MACs/cycle, queues, queue depth and capability offsets. | `python tools/g6q.py check` green; 21 diag, 19 ingest, 77 VM and full workspace pass; `indep` and `flist` selftest pass. |
| 2026-08-29 | Q6/Q7 AI-island architecture-derived model pass (Change Set B part 2): moved `AiDescLayout`/`DescField` to `g6q-core`; added `g6q-diag/src/ai_instr.rs` to parse `g6lc_ai_instr_pkg.sv` for custom-2 opcode, queue CSRs and `ai.enq`/`ai.poll`/`ai.qfence` match/mask values; introduced `g6q-core::model::AiIslandModel` grouping `AiIslandConfig`, `AiDescLayout` and `AiInstrSet`; wired `g6q-ingest` to populate `Soc.ai_island` from all three design packages; updated `schemas/target-model.schema.json`. | `python tools/g6q.py check` green; 23 diag, 19 ingest, full workspace pass; `indep` and `flist` selftest pass. |
| 2026-08-29 | Q6/Q7 AI-island custom-2 decode pass (Change Set B part 3): added `Insn::AiEnq`/`AiPoll`/`AiQfence` to `g6q-vm`; added `decode_with_ai` using `AiInstrSet` match/mask; wired `Hart.ai_instr_set` into the fetch/decode stage; added `Hart` stub execute arms that currently trap so the workspace compiles. | `python tools/g6q.py check` green; 78 VM, full workspace pass; `indep` and `flist` selftest pass. |
| 2026-08-29 | Q6/Q7 AI-island queue ring + tensor events pass (Change Set B part 4): added `AiQueue` ring to `g6q-vm` device with enqueue/poll/fence and `AiTensorEvent` emission; `Hart` execute for `ai.enq`/`ai.poll`/`ai.qfence` interacts with the `AiIsland` device; `Hart.ai_model` field added; unit and execution tests. | `python tools/g6q.py check` green; 80 VM, full workspace pass; `indep` and `flist` selftest pass. |
| 2026-08-29 | Q6/Q7 AI-island D2 counters + QEMU tensor trace pass (Change Set B part 5): added `g6q-diag::ai_tensor::tensor_counters` deriving `ai.tensor.ops/bytes/macs/queue_entries` from `AiTensorEvent` streams (all `Fidelity::Synthetic`); extended `g6q-emit-qemu` B2 plugin to open and write a second `tensor.json` output for AI-island MMIO accesses (enabled by `tensor=` arg) and emit per-hart AI-island MMIO counts. | `python tools/g6q.py check` green; full workspace pass; `indep` and `flist` selftest pass. |
| 2026-08-29 | Q6/Q7 AI-island model wiring + smoke payload pass (Change Set B part 6): `AiIsland` accepts and uses an `AiIslandModel` to set queue depth; `g6q-cli run --backend native` wires the model's `soc.ai_island` into the `Hart` (AI instr set + model) and adds a configured `AiIsland` device at the model/DTB peripheral address; `g6q-vm` queue execution test uses `set_ai_model`; `architecture/CLI.md` documents `--tensor FILE`. | `python tools/g6q.py check` green; full workspace pass; `indep` and `flist` selftest pass. |
| 2026-08-29 | Q1 elaborate the configuration before reading it (Change Set C7): investigating the planned accumulator-banks rule found that `build_config_pkg.sv` **raises** `AccBanks` rather than asserting it — so the task was reproducing a derivation, not reporting a violation, and the problem was far broader than one AI field. New `g6q-svcfg/src/derive.rs` applies the design's documented derivations (masked dependencies like `RVZacas &= RVA`, implied extensions like `ZKN ⇒ RVB`, inferred `NrIssuePorts`/`NrALUs`, bypass forcing, speculative-store-buffer implication, accelerator-seam derivation, accumulator-bank floor), each recording field/change/**reason**; `g6q-ingest` elaborates the package before anything reads it and records applied derivations in the new `Provenance.derivations` (IR + JSON + schema), kept **separate from overrides** because a derivation is the design's own behaviour and must not taint faithfulness. Tested for idempotence and for the guest-visible case: Zacas written on with `RVA` off must not reach the ISA surface as `live`. `architecture/INGEST.md` §2.0a documents the written-vs-elaborated distinction. | `python tools/g6q.py check` green; `g6q-svcfg` 48, `g6q-ingest` 21; bridge selftest OK; `indep` OK. |
| 2026-08-29 | Q7 B2 queue-instruction submission path (Change Set C6): the plugin now also catches submissions that never touch the MMIO latch window — translate-time match on `(insn & G6LC_AI_ENQ_MASK) == G6LC_AI_ENQ_MATCH` from the ingested `AiInstrSet`, `rs1` extracted from the encoding, then an exec callback (registered `QEMU_PLUGIN_CB_R_REGS`, since `NO_REGS` cannot read registers) reads the register and `qemu_plugin_read_memory_vaddr`s the descriptor out of guest memory, emitting the same submission record as the MMIO path. `G6LC_AI_ENQ_DECODE` requires both the encoding and the geometry: a zero mask would match every instruction. Register/memory-read APIs verified against the fetched pinned header. | `python tools/g6q.py check` green; `g6q-emit-qemu` 26; bridge selftest OK; `indep` OK. |
| 2026-08-29 | Q7/Q8 B2 descriptor reassembly + topology conformance (Change Sets C1, C2): the emitted plugin now reassembles descriptors and emits **submissions** rather than raw MMIO accesses, using `G6LC_AI_OFF_*`/`_SZ_*` macros generated from `desc_layout` and store values from `qemu_plugin_mem_get_value` (confirmed present in the pinned QEMU by reading the fetched header, not assumed); the record uses the native artifact's key set so a consumer cannot tell which backend produced an event; the decoder is **not emitted at all** when the geometry is unresolved (ask F1) rather than hidden behind a `#if`. `DTYPE_SHIFT`/`DTYPE_MASK` moved into `g6q_core::model` as one definition shared by the D2 derivation and the emitter (ask F5). Separately, `TargetModel::topology_rows()` now reports the interrupt-context budget (`Overdeclared` when the hart count exceeds it, `Unresolved` when unknown) and tree-vs-design processor counts (`Overdeclared` when the tree claims harts that do not exist, `Undeclared` when it hides some), wired into ingest — arithmetic that existed but was never reported. | `python tools/g6q.py check` green; `g6q-emit-qemu` 24, `g6q-core` 30, `g6q-vm` 89; bridge selftest OK; `indep` OK. |
| 2026-08-29 | Q6 self-review of B3/B4 + RTL feedback ledger (Change Set B5): comparing the shipped code against the *reference packages* caught two defects of the class B3 claimed to remove — (1) `submit()` resolved the descriptor version through `desc_layout.op("DESC_VERSION")`, a lookup that can never resolve because the reader only stores `OP_*` names and the package publishes no such constant, so it always fell back to the literal `1` while looking model-derived; (2) `cap_words()` matched invented capability names while the package publishes `qos`/`quantum`/`block_mnk`/`dtype_mask`, so four real words silently vanished and would have read as zero (a legal capability value). Fixed with `AiDescLayout.version` (IR/JSON/schema, parsed when published, single named fallback otherwise), package-spelled capability names, `cap_unsourced()` + CLI warning, and a test pinning the published name set. New `architecture/RTL_FEEDBACK.md` aggregates asks F1–F4 with dependency order, the cluster-debug workflow, and the change-set aggregation policy; two new standing checklist items in `AGENTS.md` §6. | `python tools/g6q.py check` green; `g6q-vm` 89, `g6q-diag` 26, `g6q-core` 27; bridge selftest OK; `indep` OK. |
| 2026-08-29 | Q6 island MMIO placement ingested or reported (Change Set B4): `AiIslandConfig.cap_base`/`.desc_base` (`Option<u64>`) + `placement_resolved()`, in the model JSON and the schema; `ai_cfg.rs` parses `CAP_BASE`/`DESC_BASE` (and `REG_OFF_*`/`AI_*` spellings) when published and leaves them unresolved otherwise; `AiRegMap::from_desc_layout(layout, base)` keeps the base and the field offsets as separate arguments because they come from separate sources. Unresolved placement is loud: descriptor window collapses to 0, capability window is not decoded at all, native run warns, bridge warns while still packing. **Root cause recorded:** a guest-visible island address has two halves — field offsets are in the descriptor package (ingested), window bases are in the island's RTL address decode (published nowhere consumable). Documented as an ask on the design in `AI_BRIDGE.md` §3.1, not worked around. | `python tools/g6q.py check` green; `g6q-vm` 87, `g6q-diag` 26; bridge selftest OK; `indep` OK. |
| 2026-08-29 | Q6/Q7/Q8 model-derived AI-island device (Change Set B3): `AiRegMap` + `AiStatusCodes` resolve the MMIO window and `ST_*` codes from the ingested `desc_layout` (fallback retained and labelled for the no-model case); island became multi-ring from `config.queues`/`queue_depth` with `ring_for_hart` and island-wide tickets so `ai.poll` stays unambiguous across harts; capability window values derived from `AiIslandConfig` via `cap_words()`/`cap_read()`, decoded only once a base is supplied. 5 new tests using a layout whose offsets differ from the fallback. **Corrected three in-tree doc errors found by a monorepo survey:** `EMIT.md` overstated the B2 plugin (it records MMIO accesses, it does not reassemble descriptors); `AI_BRIDGE.md` misused "stream plane" for the descriptor ring (it is a multi-core/one-thread-per-core SoC topology); and new §4.1 records that no 1000-TOPS target, no >4-issue package, and no 8-core×2-thread configuration exists in the design of record. | `python tools/g6q.py check` green; 86 `g6q-vm` tests (was 81); bridge selftest OK; `indep` OK. |
| 2026-08-29 | Q7 accelerator scale-out boundary + host bridge (Change Set B2): new `architecture/AI_BRIDGE.md` fixing the pushed-work boundary and the host-bridge dependency direction; `pins.toml` gained `contracts.ai_island_cap` (read-at-runtime) and `contracts.ai_host_transport` (unpinned, deliberately unmodelled); new `tools/ai_tensor_bridge.py` (`doctor`/`pack`/`push`/`results`/`compare`/`selftest`) which derives all descriptor geometry from `soc.ai_island.desc_layout` and types no offset/op/status; `g6q-cli run --backend native --tensor FILE` now writes the stamped artifact from B3 so native and QEMU routes agree in shape; `bridge selftest` added to the green command; root `AGENTS.md` gained `g6lc_qemu` substructure + navigate-by-intent rows. **Design review of the first draft rejected three defects before landing:** external monorepo paths in a self-contained doc, transcribed geometry constants (`0x4000_0000`, AccTile, BAR sizes, PLIC source) duplicating the ingested model, and an invented `B1–B5` stage namespace colliding with the B0–B3 backend letters — all replaced by pin references, model field names, and the existing Q axis. | `python tools/g6q.py check` green; bridge selftest OK; `indep` OK (65 files); full workspace pass. |
| 2026-08-30 | B3 AI-island PMU register model (F9): `g6q-vm/src/device.rs` adds `pmuread` support through `AiIsland::pmu_load`/`pmu_value`; `queue_qfence` calls `update_pmu` on the most recently completed event, computing AXI R/W beat counts from the event shape, a bound cycle count from `g6q-diag::roofline::gemm`, and a modelled milli-GB/s figure (`bytes * ClockKhz / cycles / 1000`); PMU values are read through offsets published in `AiIslandConfig::pmu_offsets` (`PMU_OFF_*` localparams when the design publishes them). `crates/g6q-vm/src/device.rs` adds a test that proves `load(0x180..0x18c)` returns non-zero values after `queue_qfence`. `architecture/RTL_FEEDBACK.md` F9 updated: emulator side is ready, the design still needs to publish the offsets. | `python tools/g6q.py check` green; `g6q-vm` 110 tests; `indep`, `flist`, and `ai-bridge` selftest pass. |
| 2026-08-30 | D2 AI-island PMU counters via tensor artifacts: `AiTensorEvent` gains `pmu_r_beats`/`w_beats`/`cycles`/`gbps_x1000`; `g6q-vm` stores modelled PMU values per event in `queue_qfence`; `g6q-diag/src/ai_tensor.rs` `tensor_counters` emits `ai.pmu.*` counters from the last completed event as `Fidelity::Modelled`; `to_json`/`from_json` round-trip the new fields; `g6q-cli` tests updated. `architecture/DIAG.md` §4.1 table adds `ai.pmu.*`. `python tools/ai_tensor_bridge.py` `push --uarch-out` will now carry `ai.pmu.*` counters through the artifact. | `python tools/g6q.py check` green; `g6q-vm` 110, `g6q-diag` 64, `g6q-cli` 52; `indep`, `flist`, and `ai-bridge` selftest pass. |
| 2026-08-29 | Q6/Q7 remote tensor retrieval + queue smoke pass (Change Set B part 7): `tools/g6q_remote.py` `test`/`remote-build` subcommands gained `--plugin-tensor PATH`; the plugin is invoked with `,tensor=PATH` and the resulting `tensor.json` is rsynced back to `out/remote_runs/<tag>/tensor.json`; added `g6q-vm` `ai_queue_full_and_ticket_sequence` integration test that enqueues to a model-configured depth, exercises queue-full, `ai.qfence`, `ai.poll`, and drains `AiTensorEvent`s into D2 `ai.tensor.*` counters. | `python tools/g6q.py check` green; 81 VM, full workspace pass; `indep` and `flist` selftest pass. |

### Defects found and fixed while soaking Q1

| Defect | Why it mattered |
|---|---|
| POSIX absolute paths were treated as relative on one host | every membership query silently missed — a tooling gap that reads as a design fact |
| Unterminated preprocessor directives swallowed the declaration after them | one real package parsed to an **empty** configuration, silently |
| String lists split on raw commas | every vendor-prefixed `compatible` and `mmu-type` was cut in half |
| An unreadable nested manifest aborted the whole manifest | dropped the core file set, so core units reported `stub` rather than "unknown" |
| Manifest gaps rendered as `stub` | "could not tell" presented as a claim about the design; now `unresolved` |
| Post-inference legality rules applied to source values | flagged valid packages (`0` means *infer* for cache size and issue width) |
| `setup` used the run-time environment | would have installed the toolchain into the user's home instead of the package |
| Unknown interrupt budget reported as `0` | stated a limit the inputs do not support; now `null` |
| Privilege modes given device-tree tokens | false `undeclared` on every target |

### Boot-validation notes (Q4)

OpenSBI v1.5.1 now boots the generated `g6lc-unnamed` machine and prints its banner.
Root-cause fixes found during the pass:

1. **UART `reg-shift` mismatch.** The generated DTB advertised `reg-shift = <2>` for `ns16550a`, but the QEMU `serial-mm` device was created with default `regshift=0`, mapping only 8 bytes. OpenSBI wrote at offset 0xc, took a store/AMO access fault, and entered `sbi_hart_hang()` before printing. Setting `qdev_prop_set_uint8(dev, "regshift", 2)` on `serial-mm` fixes the hang.
2. **Generated CPU was a generic/dynamic CPU, so QEMU applied default MISA bit properties (`f`, `d`, `h` on).** Switching the generated CPU's parent to `TYPE_RISCV_VENDOR_CPU` keeps the emitter-supplied `misa_ext` from being overwritten. The `S` bit requires `U`, and `satp_mode.supported` must be set explicitly for the chosen MMU mode.
3. **No-kernel boot needs a non-zero `next_addr`.** With `info.image_low_addr = 0`, OpenSBI's `sanitize_domain()` finds the next address inside the M-mode firmware region and hangs. A fallback `dram_base + 0x200000` (outside the firmware image) lets OpenSBI print and then hand off to a non-existent S-mode payload, which is the correct behaviour until a kernel is supplied.

These fixes are now in the generator: `g6q-emit-qemu` emits `reg_shift` / `clock_frequency` into the `serial-mm` UART, uses `TYPE_RISCV_VENDOR_CPU` with `misa_ext` covering the model's live ISA plus the `S`/`U` and MMU dependencies, sets `satp_mode.supported` from the chosen MMU mode, and provides a `dram_base + 0x200000` `image_low_addr` fallback for no-kernel boot. `python tools/g6q.py check` is green and `qemu-system-riscv64 -M g6lc-unnamed -m 256 -nographic -bios default` reaches the OpenSBI banner and reports `Domain0 Next Address: 0x80200000`. The same boot succeeds from the real `E:\\cva6` repo-root package after `python tools/g6q.py install-qemu --package E:\\cva6`, producing a `rv64imafdcb` base ISA plus the DTS-advertised multi-letter extensions.

### Q7 — AI-island B2/B3 tensor parity and remote smoke pass

- `fixtures/ai/` completed as a package with `ai_soc_config_pkg.sv`, `g6lc_ai_island_cfg_pkg.sv`, `g6lc_ai_desc_pkg.sv`, `g6lc_ai_instr_pkg.sv`, `manifest.f`, and `board.dts` placing the AI island at `0x30000000`.
- `g6q-ingest` 64-bit `cap_base`/`desc_base` placement parsing fixed for `u64` values.
- `tools/remote/payload/ai_island_smoke.S` and linker script aligned with the ingested 64-byte descriptor layout (`m/n/k` at offsets `0x08`/`0x0c`/`0x10`, `ptr_done` at `0x38`) and island base `0x30000140` with UART at `0x10000000`.
- `g6q-vm/src/device.rs` now emits a B3 `AiTensorEvent` on MMIO shadow submit, using the ingested descriptor `version_op`/`ptr_done` offsets and the island base.
- `g6q-emit-qemu/src/plugin.rs` B2 plugin now detects I/O accesses with `qemu_plugin_hwaddr_is_io` and uses the callback virtual address for I/O; `descriptor_addr` is emitted as the island-relative offset (`0x140`), matching the B3 native artifact convention.
- Generated machine and plugin installed as `g6lc-ai_soc` (`--target ai_soc`) into `qemu/`; stale `g6lc-ai` build-wiring and C files cleaned from the QEMU tree.
- Remote build, configure, and build succeeded on `ovh_calltorch` (`ubuntu@148.113.222.95`) using WSL-native `ssh`/`rsync` and an internal askpass helper.
- Remote AI-island smoke passed: guest printed `AI_OK`, `ai_island_count=5`, and the `tensor.json` artifact was pulled to `out/remote_runs/test-1787971932/tensor.json`.
- Native B3 run with `--tensor out\\b3_tensor.json` produced the same event shape (`descriptor_addr=320`, `ptr_done=0x80010000`, `done=true`, `status=0`).
- `g6lc-qemu diag --tensor out\\b3_tensor.json --tensor out\\remote_runs\\test-1787971932\\tensor.json --uarch-out out\\uarch.json` reported no divergence.
- `python tools/g6q.py check` green after fixing `g6q-emit-qemu` `push_str("\\n")` and `g6q-vm` `AiTensorEvent` default-init; workspace tests, `indep`, `flist`, and `ai-bridge` selftests pass.
- Outputs remain modelled hypotheses, not verification evidence.

### Q7 continuation — B2 plugin GCC portability + QEMU staging cleanup + local `g6lc-ai_soc` smoke

- `g6q-emit-qemu/src/plugin.rs` now emits `#include <inttypes.h>` and `PRIu64` for `uint64_t` tensor fields instead of non-portable `%llu`, fixing `-Werror=format` on glibc `uint64_t = long unsigned int`.
- `g6q-emit-qemu/src/plugin.rs` guards `g6lc_tensor_write` with `#if G6LC_AI_DESC_DECODE != 1` so the fallback is only compiled when the geometry is unresolved, fixing `-Werror=unused-function`.
- `g6q-emit-qemu/src/plugin.rs` moves the `store_word` declaration and `qemu_plugin_mem_get_value` switch under `#if G6LC_AI_DESC_DECODE == 1`, fixing `-Werror=unused-but-set-variable` for targets without completion/ptr_done decode.
- Removed stale `g6lc-unnamed`, `g6lc-mini`, `g6lc-g6lc64_smt2`, `g6lc-target` generated machine, CPU and plugin sources from `qemu/`, and trimmed `Kconfig`, `meson.build`, and `configs/targets/riscv64-softmmu.mak` to only `g6lc-ai_soc` for the local boot gate.
- `python tools/g6q.py install-qemu --package fixtures\ai` now derives `--target ai_soc` from the config package stem (`ai_soc_config_pkg.sv`) and installs only the `g6lc-ai_soc` B1/B2 files.
- Local `ninja -C qemu/build` completed; `qemu-system-riscv64` and `libg6lc-ai_soc.so` built from the generated source.
- Local AI-island smoke: compiled `tools/remote/payload/ai_island_smoke.S`, ran `qemu-system-riscv64 -M g6lc-ai_soc -bios none -kernel out/ai_island_smoke.elf -plugin qemu/build/contrib/plugins/libg6lc-ai_soc.so,tensor=out/local_runs/ai_smoke/tensor.json`, guest printed `AI_OK` and the B2 plugin wrote `tensor.json`.
- `g6lc-qemu run --backend native --image out/ai_island_smoke.elf --tensor out/b3_tensor.json` produced a matching B3 tensor artifact; `g6lc-qemu diag` reported no divergence.
- `python tools/g6q.py check` green (111 `g6q-vm` tests, 36 `g6q-emit-qemu` tests, etc.).

### Q7 continuation — AI queue CSR support + install-qemu cleanup

- `g6q-vm/src/device.rs` adds `AiIsland::queue_csr_read` and `queue_csr_write` for the ingested `aiqbase`/`aiqctl`/`aiqhead` CSRs, per-hart ring selection via `ring_for_hart`, and head value normalisation to the queue depth.
- `g6q-vm/src/exec.rs` intercepts `csrrw`/`csrrs`/`csrrc`/`csrrwi`/`csrrsi`/`csrrci` to AI queue CSR numbers and delegates to the island; all other CSRs remain under `CsrBank` control. A guard prevents intercepting when all three CSR numbers are zero (unconfigured or default tests).
- `g6q-vm/src/exec.rs` test `ai_queue_csrs_read_and_write` covers `csrrw` to `aiqbase`/`aiqctl`/`aiqhead` and verifies the queue state.
- `tools/g6q.py` `_gen_command` now derives `--target` from the config package stem (`cfg.stem.removesuffix("_config_pkg")`) instead of the package directory name, so `python tools/g6q.py install-qemu --package fixtures\ai` correctly targets `ai_soc` rather than `ai`.
- `qemu/hw/riscv/Kconfig` and `qemu/configs/targets/riscv64-softmmu.mak` trailing blank lines cleaned.
- `python tools/g6q.py check` green; `g6q-vm` 111 tests pass.
