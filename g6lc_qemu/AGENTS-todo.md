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

`--loader bios` / `gen --emit bios-spec`: OpenSBI next-stage wiring for the independent `g6lc_bios` package. That package is a **rewrite** of TempleOS/ZealOS specs (`g6lc_bios/kernel-spec/`), not a vendor of those trees; ELF from `g6b elf`. Dual-band HolyC: UART0 nographic stdio, UART1 `-serial tcp:127.0.0.1:2222,server,nowait` (`--holyc-port`). QEMU hypothesis only.

---

## Ubuntu reference-only increment (2026-10-01)

Priors: `linux-dist/ubuntu/README.md`, `linux-dist/ubuntu/pins.toml`.

- [x] Preserve the Ubuntu scaffold; add official Resolute and Noble kernel gitlinks
  with lazy update and explicit local sparse checkout. Verified tags are source
  pins, not installed Ubuntu kernel evidence.
- [x] Record stock 26.04.1 then 24.04 acceptance separately from the historical
  custom Noble/RISC-V 6.6 development recipe. No generator/runtime code changed.
- [ ] Collect independent clean-image, installed kernel/config, Mesa/libdrm/loader/
  ICD manifests and test stock-client execution. Kernel sources alone do not close
  any boot or graphics acceptance gate.

## OpenWrt APU baseline boot/probe (2026-09-14)

Priors: `AGENTS.md` §OpenWrt console and graphics probe; `architecture/CLI.md`
§Operating system / Execution; `openwrt/kernel-virt.config`.

- [x] Boot the existing OpenWrt initramfs through `g6q run`, project-built QEMU
      10.0.0 and OpenSBI 1.5, with one hart, 1 GiB RAM and `--virtio gpu`.
- [x] Reach the BusyBox shell and execute guest probes. OpenWrt 24.10.2,
      `r28739-d9340319c6`, Linux 6.6.93, `sifiveu/generic`, `riscv64_riscv64`;
      `G6LC_OPENWRT_PROBE_DONE` emitted by the guest, runner exited 0.
- [x] Isolate the console mismatch without rebuilding or modifying the original
      kernel/rootfs: temporary `out/openwrt-apu-probe/console.cpio` overrides
      only `etc/inittab` to keep the standard login service on `ttyS0` instead
      of `ttySIF0`. The early prompt is `root@(none):~#`.
- [x] Observe virtio GPU device ID `0x0010` in guest sysfs. No DRM class/device,
      loaded virtio_gpu module or installed Mesa stack is present in this image.
- [x] Graphics-enabled OpenWrt kernel/packages and QEMU OpenGL/virgl build on
      the remote testharness: OpenWrt v24.10.2 has DRM/KMS, virtio_gpu, Mesa
      21.3, libdrm and `g6lc-egl-probe`; QEMU 10.0.0 has OpenGL/epoxy,
      virglrenderer 1.0.0, GBM, pixman and vhost-user. The probe forces modern
      virtio-mmio and uses unchanged guest Linux/Mesa/virtio-gpu.
- [x] Headless remote virgl proof through `vhost-user-gpu`: the host has no
      render node, so the contrib backend runs with an LD_PRELOAD surfaceless-
      EGL/GLES shim and `max_outputs=0`. Guest reports `+virgl`, capsets 1/2,
      `/dev/dri/renderD128`, `gbm-window` EGL surface, renderer `virgl
      (LLVMPIPE (LLVM 20.1.2, 256 bits))`, stable FNV-1a `0x3d667145`,
      `G6LC_EGL_GLES2_DRIVER=virgl`, `G6LC_EGL_GLES2_OK`, rc 0. Logs:
      `out/remote-gfx/gfx-20260914T203512Z/` (latest normal rerun).
- [x] Archive actual unchanged Mesa/Linux traffic: API/capset/resource/transfer/
      submit/fence events and binary command buffers are summarized by
      `openwrt/summarize-virgl-capture.py --strict`; normal capture
      `gfx-20260914T203512Z/capture` reports `result=PASS`.
- [x] Add and run opt-in unchanged-driver error probing:
      `remote-gfx-probe.py --negative` sets `g6lc_neg=1`, runs
      `g6lc-virgl-negprobe`, and validates with `--expect-errors`. Capture
      `gfx-20260914T203421Z/capture` reports `result=PASS`: malformed and
      out-of-range backend operations return `EINVAL`, while queue submission
      ioctls and virtio fences can still report/complete successfully.
- [x] Add and run the opt-in richer GLES2 audit workload:
      `remote-gfx-probe.py --mode vugpu --audit` sets `g6lc_audit=1` and runs
      `g6lc-egl-probe audit`, then validates with `--expect-audit`. Capture
      `gfx-audit-20260914T213500Z/capture` reports `result=PASS` with texture upload/sampling, sampler-view and
      sampler-state objects, fragment constants, indexed draw, scissor state,
      state-object binds, readback, cleanup and nine command-typed fences. The
      summarizer now decodes packed sampler-view fields and full mip-level
      backing sizes; this remains llvmpipe software-rendered contract evidence.
- [ ] In-process QEMU `egl-headless,gl=on` remains unavailable on this host
      (`simple-framebuffer`, no `/dev/dri/renderD*`); use `--mode vugpu` or a
      host with a real render node. This is host software rendering, not RTL/APU
      hardware proof.
- [x] Freeze the reduced P0 contract for the pinned Mesa path:
      `--cap-profile gles2-min` passed the strict audit in
      `gfx-20260914T221515Z/capture` and expected-error probing in
      `gfx-20260914T221551Z/capture` with all optional virgl capability masks
      clear. `gles2-xfer` retains only `VIRGL_CAP_TRANSFER` and passed in
      `gfx-20260914T221800Z/capture`. The full cap/limit, command, lifetime,
      fence/error, reset, DMA/cache and protected-firmware obligations are in
      `g6lc_bios/architecture/DISPLAY.md`. The separate BIOS package gate is
      green again, including the previous picker/JIT device-frame test.

No production configuration or RTL changed. This is a `g6lc-virt` software
boot/probe result over unchanged Linux/Mesa/virtio-gpu, not faithful SoC
simulation, hardware acceleration or P3 completion.

## DMA destination validation follow-up (complete)

Preserved the native evaluator and the subsequent mode-legality/INT4-alias changes.
Six initial regressions were observed failing before the production fixes: C alignment,
completion sinks, guest pending/fence/poll error status and restored device overlays.
Normal-RAM classification now excludes every overlapping device and conservatively
refuses empty/overflowing ranges. GEMM validates full C coverage/alignment and nonnull
completion sinks before producing C writes, including completion sinks for skipped ops.

Guest C/completion write boundaries now check errors and update the existing completion
and event status without allocating another ticket or changing descriptor pointers.
Queue fences only finish pending entries, so repeat fences cannot erase DMA failures
or advance the tail twice. Pointer failures report published ST_BAD_PTR, falling back
to ST_ERR; existing version/op/format/shape precedence is retained. Queue-fence
bookkeeping still does not replace the MMIO/direct GEMM computation route.

Validation: focused `cargo test -p g6q-vm` **170 passed, 0 failed, 1 ignored**;
`python tools/g6q.py check` **OK**, 607 workspace tests passed, 0 failed, 1 optional
benchmark ignored. Independence (80 files), bridge selftest, fmt and clippy green.
The release `float_specials_and_nonfused_rounding` discriminator passed unchanged;
no arithmetic barriers or float changes were added. The native fixture result in
`out/tensor-eval-dma.json` is byte-identical to `out/tensor-eval-wrapper.json`
(`git diff --no-index` exit 0): still 9 executed and 2 legal rejections.
Tests cover late mapping loss at poll, boundary revalidation, partial-span/no-partial-C
failure, null sinks, skipped ops and single completion/tail advancement. Only the
random/reference test fixtures gained explicit C backing memory required by the new
validation; fixed-K format packing is untouched. Scope: MIT/std-only B3 software;
no root, RTL, ai-tensor, dependency, grant or schema changes.

## Native tensor evaluation pass (complete)

Architecture/CLI.md and architecture/AI_BRIDGE.md defined the native descriptor
route before implementation. Added `tensor-eval` to the Rust CLI and Python primary
wrapper; `bridge evaluate` forwards source flags and can export source-buffer policy
samples. Results embed the full model, status/grant decisions and native C bytes.
`operand_b_k_major: Option<bool>` is ingested only from `DESC_B_K_MAJOR`; new evaluation
requires true. Legacy unresolved stand-ins keep their old stride interpretation.

B3 canonicalizes NaN C, always rejects SP24 and caches decoded RAM operands while
retaining scalar MMIO ordering, separate f32 multiply/add and wrapping integer sums.
Independent scalar comparisons cover every dense format, padded/asymmetric shapes,
random bits, special values, non-FMA rounding and late faults. Scratch stays bounded
and model-derived; the 4-GiB DRAM relocation test needs just 216 bytes for its small job.
Fixed two grant-ingest hazards: 32-bit SV hex literals were not read by ai_cfg, and
cap-window parsing could overwrite published package facts with None. No live grants
were widened; the new 0xfb fixture is explicitly software exploration.

Validation: `python tools/g6q.py check` **OK**, 595 tests passed, 0 failed, one optional
host benchmark ignored by the normal gate; independence 80 files, fmt/clippy and
bridge selftest green. `python tools/g6q.py doctor` exit 0 on Windows, Cargo 1.85.0;
only optional Spike is missing, no installation performed. The primary-wrapper and
bridge fixture invocations both returned exit 0, 9 executed / 2 legal rejections.
Host-only release benchmark passed separately: 3.95x..28.16x over per-MAC scalar
baseline, with complete per-format microseconds in architecture/AI_BRIDGE.md.

A live convenience ingest with only `--repo-root E:/cva6 --target g6lc64_ai` resolved
`soc.ai_island=null` and evaluation correctly refused. The host must pass a manifest
that actually contains the island config/descriptor/instruction packages; this is not
permission to use fixture grants for a live target. B1 guest/RTL timing and floating
exception-flag verification remain separate. MIT/std-only, no host imports, no RTL
edits, no GPL linkage. Rustfmt also normalized pre-existing wrapping in CLI loader
and BIOS-emission expressions so the full-package formatting gate could pass.

## Latest pass — Q6 functional island + control surface (2026-09)

**The ingest could not read the live design at all, and nothing had noticed.** Every
`RTL_FEEDBACK.md` row that said "published" was untested against the real packages: pointing
the readers at them returned `Err("bad integer: AIDRAMCHANSHIFTDEFAULT")`, so
`parse_ai_island_cfg_pkg` produced *no model*, not a model with one wrong field. Four reader
defects, one shape — **the design graduated from literals to named constants, and the reader
only understood numerals** (`architecture/RTL_FEEDBACK.md` §2.2):

- SKU literals refer to `AI_DRAM_CHAN_SHIFT_DEFAULT` / `AI_MAX_AR_OUT_LIVE` / `AI_DRAM_SIM_AXI`
  → `collect_symbols` builds a symbol table from the package's own scalars; an unresolved
  identifier is an error, never a zero.
- Capability-window case labels are symbolic (`CAP_OFF_DRAM_GBPS[15:2]:`) → `parse_case_cap_name`.
- `block_mnk` is a shift-OR of `CAP_BLOCK_*_SHIFT`, `DtypeMask` defaults to `AiIslandDtypeMask`
  → both read from the **package** now; the cap-window parse is the fallback.
- Flag accessors index by constant → `parse_flag_localparam` prefers `FLAG_*_SHIFT`/`_WIDTH`.

**F1's second half landed.** `REG_OFF_{CTL,STATUS,DOORBELL,CPL,QUEUE}` are ingested into
`AiIslandConfig::reg_offsets`; `control_surface_resolved()` separates *addressable* from
*operable*, because knowing where the descriptor window sits does not tell a guest how to ring
the bell. This also removed a live collision: the derived placement put `status` at
`desc_base + desc_bytes` = `0x180` = `PMU_OFF_R_BEATS`, so a guest read a beat counter as a
status word (§2.3).

**B3 computes the GEMM.** `crates/g6q-vm/src/gemm.rs` reads A/B from guest memory and writes
`C` (`ldc = n`, s8×s8→s32). Op codes, status codes and the accumulator-tile bound come from the
ingested model; F12's bound returns the package's own `ST_ERR`; a sub-byte or sparse request the
CAP window does not grant is refused rather than silently run as dense s8. A guest now drives a
job end-to-end through MMIO alone — `a_guest_can_drive_a_gemm_entirely_through_the_published_mmio_window`.

**One emitter defect fixed on the way:** the SPI creation block was emitted unconditionally
while its `hw/ssi/ssi.h` include was gated on the model, so a machine without an SPI peripheral
generated C that could not compile. The stale test that asserted otherwise was right.

**The green command is green again.** `python tools/g6q.py check` failed at HEAD, on three
counts that had nothing to do with this pass and were each masked by the one before it:
`cargo test` stops at the first failing binary, so the `g6q-diag` failures hid an
`g6q-emit-qemu` one; clippy never ran because the tests failed first. Cleared:

- 3 `g6q-cli` clippy errors — `run_bridge_pack` took eight positional `&str` (grouped into
  `BridgePackPaths`; six same-typed arguments in a row is a call site where a transposed
  pair compiles and writes the capability dump over the descriptor), and two
  `format!`-per-byte hex loops (`hex_string`).
- A **real emitter defect**: the SPI creation block was emitted unconditionally while its
  `hw/ssi/ssi.h` include was gated on the model, so a machine with no SPI peripheral
  generated C referencing `SSIBus`/`SSI_GPIO_CS` without the header. The stale test that
  asserted the block should not appear was right; the emitter had regressed past it.
- A **parallel-test file race**: two `loader::tests` stage the same fixed
  `out/loader-run/esp-openwrt` tree, so on Windows the loser got `os error 32`. The path is
  part of the loader contract, so the tests are serialised by a mutex rather than the
  product bent to suit them.

| Check | Result | At HEAD |
|---|---|---|
| `python tools/g6q.py check` | **OK** | FAILED |
| `cargo test --workspace` (parallel **and** `--test-threads=1`) | **560 pass / 0 fail** | 531 / 6 serial, plus a parallel-only flake |
| `cargo clippy --workspace --all-targets -- -D warnings` | clean | 3 errors |
| `cargo fmt --all --check` | clean | clean |
| `check_independence.py` | OK, 78 files | OK |

Open, deliberately: **B1 emitted C does not wire the island's interrupt** (`sysbus_connect_irq`
+ `qemu_irq_raise`); B3 does. And `0x110`/`0x114`/`0x118`/`0x11C` are still register-map comments
rather than localparams — the doorbell-and-claim path does not need them, the DMA-fetch path does.

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
| **Q2** B0 stock-QEMU driver + firmware chain | **done** — B0 argv/delta emission complete; `run` now supports `--backend args` (print stock-QEMU argv) and `--backend qemu` (spawn `qemu-system-riscv64` with `--qemu-path`, `--dry-run`); `fw` verb implemented with `Firmware`/`BootOptions` JSON inspection and `--fw-print-region` raw-size report; `python tools/g6q.py fetch-qemu` implemented with `--url`/`--ref`/`--full`/`--dry-run` overrides and `--depth 1` shallow default; the pinned QEMU v10.0.0 source is now in `qemu/` (gitignored, separate GPL work); `pins.toml` status updated to `fetched`; `python tools/g6q.py build-qemu` added with `--target`, `--debug`, `--mingw`, `--configure-only`, `--clean`, and `--dry-run`; it probes for python/bash/ninja and prints the configure/ninja commands in dry-run mode; `python tools/g6q.py install-qemu` added with `--package` and `--dry-run`; it builds `g6lc-qemu`, runs `gen --emit qemu`, copies C/FDT/plugin source files into the QEMU tree, and appends build-wiring fragments to `hw/riscv/Kconfig`, `configs/targets/riscv64-softmmu.mak`, `hw/riscv/meson.build`, `target/riscv/meson.build`, and `contrib/plugins/meson.build` (generated plugins are added automatically); `build-qemu` now runs WSL/bash out-of-tree `configure` and `ninja` on Windows and defaults to `--disable-libvduse --disable-vduse-blk-export --disable-vhost-user --disable-vhost-user-blk-server` to avoid NTFS/WSL symlink issues; host `qemu-system-riscv64` built and `--version` succeeds; **host-QEMU boot gate passed** with `g6lc-g6lc64_smt2` machine and the in-tree OpenSBI `fw_payload.elf` (`software/smt2-linux/scripts/build-opensbi-smt2.sh`) under WSL: OpenSBI v1.5 platform banner and `SMT2-OSBI-OK` observed; `g6lc-qemu run --backend qemu` currently requires explicit `--stock-machine g6lc-g6lc64_smt2 --stock-cpu g6lc-g6lc64_smt2` until the default is switched to the generated B1 machine. |
| **Q3** B3 native VM + tandem records | **in progress** — RV64I/M/A interpreter, CSR bank, mret/sret, Zicsr, CLINT/UART/PLIC with M/S-mode software + timer + external delivery, ecall/ebreak/illegal + load/store/fetch M-mode/S-mode traps with mepc/mcause/mtval, medeleg/mideleg, sstatus/sie/sip views, Sv39 page-table walker with 4K/2M/1G leaves, per-access translation, Zicbom/Zicboz no-op decoding, Zacas amocas.w/d, Zba sh[123]add/add.uw/slli.uw, Zbs bset/bclr/binv/bext, Zbb andn/orn/xnor, clz/ctz/cpop, clzw/ctzw/cpopw, min/max/minu/maxu, rol/ror/rori, rolw/rorw/roriw, rev8, orc.b, sext.b/sext.h, zext.h (RV32/RV64), RVC compressed (16-bit fetch, RV32C/RV64C expansion, control flow, stack-relative loads/stores), mret/sret tests, `run --backend native`, `tandem` CLI, D1 report library green; commit record extended with trap `cause`, `prv` and `halt` fields and a separate `record_order` counter so future trap and checkpoint records have their own index; F single-precision and D double-precision opcodes implemented; FP hardening pass done — explicit IEEE-754 rounding, OF/UF/NX/NV/DZ flag tracking and NaN canonicalisation cover all F/D <-> integer and F <-> D conversions; f32 arithmetic and FMA are rounded from an f64 intermediate; f32 FMA now uses one `f64::mul_add` rounding before the f32 final rounding; f64 FMA uses one host `f64::mul_add` rounding; f64 arithmetic improves OF/DZ/NV reporting; min/max/compare/sign-injection handle sNaN/qNaN and signed zero; FP edge-case unit tests added; `run --backend native` now resolves the target, assembles a `TargetModel`, and derives the reset vector, `xlen`, CLINT/PLIC/UART base addresses and PLIC source/target counts from the model, with hard-coded fallback addresses only when the model is silent; `chosen/stdout-path` extracted from DTS into `Facts.stdout_path`, carried in `Soc.stdout_path`, emitted in B1 FDT when present and otherwise derived from a UART peripheral; f64 add/sub/mul now honour RNE/RTZ/RDN/RUP/RMM using `two_sum`/`two_prod` error-free transforms and `f64_round_two`, set NX for inexact results and OF/UF for overflow/underflow, and produce directed-overflow rounding (e.g. RTZ/RDN round to max finite); unit test `f64_directed_rounding_sets_nx_and_picks_the_right_bracket` covers ties and brackets; div/sqrt/fma still use host single rounding and ignore rm; remaining: full directed rounding for f64 div/sqrt/fma and exact UF for subnormal products/FMA (requires a wider accumulator) |
| **Q4** B1/B2 generated QEMU machine and plugin | **done** — B1: machine/CPU/build-wiring emitters; machine emitter now supports `Soc.virtio_mmio` and the `--virtio-mmio N` CLI option; B1: model-driven MROM via `Soc.bootrom` and `--bootrom BASE:LEN`; B1: generated FDT as `hw/riscv/g6lc-<target>-dtb.c/h` embedded blob with model-derived `/cpus/timebase-frequency`, `/cpus/cpu-map` cluster/core/thread topology using numeric phandles, `/chosen/bootargs` and `/chosen/stdout-path` derived from a UART peripheral, `/memory`, `/soc/plic`, `/soc/clint` and memory-mapped peripherals; CLINT `interrupts-extended` wired to each hart's CPU intc with M-mode software (3) and M-mode timer (7); PLIC `interrupts-extended` and `interrupt-parent` use numeric phandles; `machine_init` loads the FDT (or user `-dtb`) and places it via `riscv_compute_fdt_addr`/`riscv_load_fdt`; `gen --emit qemu-machine` and `gen --emit qemu` include the FDT artifacts; B2: `gen --emit qemu-plugin` writes `contrib/plugins/g6lc-<target>.c` for the v4+ TCG plugin API; `gen --emit qemu` generates all B1/B2 artifacts; all GPL-header; build-wiring updated to QEMU v10's `configs/targets/riscv64-softmmu.mak` path and the `minikconf`-safe syntax (`bool` with no prompt, `depends on RISCV32 || RISCV64`, `riscv_ss.add(when: ...)`); `python tools/g6q.py install-qemu` can stage the generated sources and append the easy build wiring into a fetched `qemu/` checkout; **B1 generated machine and CPU now compile against QEMU v10.0.0**; B1 also emits `target/riscv/g6lc-<target>-ai.decode` and `target/riscv/insn_trans/trans_g6lc_<target>_ai.c.inc` from the ingested `AiInstrSet` for custom-2 queue instructions; **the generated `trans_` functions are no longer stubs** — see the Q4/Q6 B1 queue-instruction pass below: they call `helper_g6lc_ai_{enq,qfence,poll}`, which delegate to a generated `hw/riscv/g6lc-<target>-ai-island.c` sysbus device, and the whole set (decode + trans + helpers + device + machine wiring) is emitted behind one shared guard. Historical note on the CPU emitter: (`cpu-qom.h`, `RISCV_CPU_TYPE_NAME`, `TYPE_RISCV_CPU_BASE`, `misa_mxl_max`, `riscv_cpu_set_misa_ext`, `object_property_set_*` + `sysbus_realize` for the hart array, `qapi/error.h` for `error_fatal`, `system/device_tree.h` for `load_device_tree`, `<stddef.h>` in the embedded DTB C); `python tools/g6q.py build-qemu` produces a working `qemu-system-riscv64`; `qemu-system-riscv64 -M g6lc-unnamed -m 256 -nographic -bios default` now boots OpenSBI v1.5.1, prints the platform banner, and reports a valid `Domain0 Next Address` (0x80200000); also booted `g6lc-g6lc64_smt2` with the SMT2 `fw_payload.elf` and observed `SMT2-OSBI-OK` after the OpenSBI v1.5 banner; the B2 plugin now guards `is_io`/`paddr` with `#if G6LC_AI_DESC_DECODE == 1 || G6LC_AI_ISLAND_LEN != 0` so targets without an AI island build with `-Werror` clean. **Q4 topology invariants pass:** `g6q-emit-qemu` FDT emitter unit test asserts the generated DTB has one `cpu@{h}` node per `harts_total`; the generated B1 machine now emits `g6lc_<target>_machine_fdt_check` that counts `cpu@*` subnodes at runtime and asserts the count equals `g6lc_harts_total`; `g6q-cli` `fw build` resolves `PLATFORM_HART_COUNT` from the model or DTS and reports it in the build JSON. |
| **Q5** D1 tandem / replay / checkpoint | **in progress** — comparison + report library green; CLI `tandem` verb; `RecordFile` with artifact header + `read_record_file`/`write_record_file`; `run --record FILE` writes a stamped record file; `tandem` accepts both record files and plain record arrays; `architecture/CLI.md` updated to `--bootrom BASE:LEN` and `--record FILE`; `g6q-diag` `Checkpoint` type added with hart state, physical memory and device-state schema; `g6q-vm` `Hart::checkpoint`/`restore` and `PhysMem::snapshot`/`restore` round-trip; `run --backend native --checkpoint FILE` writes a resumable checkpoint; `run --backend native --restore FILE` now resumes from that checkpoint and makes `--image` optional; `architecture/CLI.md` updated; full CLINT/PLIC/UART state captured and restored via `MmioDevice::snapshot`/`restore`; `Halt::ReplayDivergence` and `Hart::run_replay` added with record-by-record diff; `run --backend native --replay FILE` replays against a `RecordFile` and fails on divergence; Q5 core D1 checkpoint/replay stack complete |
| **Q6** accelerator ISA + device + in-guest runtime | **done** — B3 native VM decodes and executes `ai.enq`/`ai.qfence`/`ai.poll` from an ingested `AiInstrSet`; `g6q-vm/src/insn.rs` adds `Insn::AiEnq/AiPoll/AiQfence` gated on the model; `g6q-vm/src/device.rs` adds `AiIsland::read_descriptor_event`, `queue_enq_with_event`, `queue_poll_details`, and `queue_qfence`; `g6q-vm/src/exec.rs` reads descriptors from guest memory, marks entries, writes completion words to `ptr_done`, and sets `rd`; the in-guest payload `tools/remote/payload/ai_island_queue_smoke.S` is assembled from model-derived `match_*`/descriptor-offset flags and prints `AI_OK` under `run --backend native`; `run --record` and `run --tensor` produce a D1 record file and a D2 tensor artifact; `tandem` and `diag` run cleanly over these artifacts; **B1 queue-instruction execution is complete** — `g6lc-<t>-ai.decode`, `trans_g6lc_<t>_ai.c.inc`, `g6lc-<t>-ai-helpers.{h,c}` and the `hw/riscv/g6lc-<t>-ai-island.{h,c}` device are generated behind one shared guard and execute `ai.enq`/`ai.qfence`/`ai.poll` in-target; verified to `AI_OK` on `g6lc-ai` from both an ELF and a raw image, with B3 agreeing on the same strengthened payload. The B2 plugin **cannot** record instruction-submitted work on the pinned QEMU (`qemu_plugin_get_registers()` does not expose the core GPRs) and now says so once instead of emitting an empty artifact; it remains the trace backend for this path |
| **Q7** D2 microarchitectural + PMU | **in progress** — PMU event table and `Uarch` raw map landed; D2 structure-size counters (`uarch.*`) scaffolded; **PMU FDT/CPU mapping landed**: OpenSBI-compatible `/pmu` node with `riscv,event-to-mhpmcounters` (fixed `mcycle`/`minstret`), `riscv,raw-event-to-mhpmcounters` from ingested design events, `interrupts-extended` for Sscofpmf LCOFIP, and generated QEMU CPU `ext_zihpm`/`ext_sscofpmf`/`pmu_mask`; B0 `-cpu` appends `pmu-mask` when `zihpm` is live; **B2 PMU counter plugin landed**: `g6q-emit-qemu/src/pmu.rs` generates `contrib/plugins/g6lc-<target>-pmu.c` from the published `PmuTable` (event names, groups, and `mhpmevent` selectors), registers per-hart instruction counters and a per-hart/per-event counter array, and writes a counters JSON at exit; `gen --emit qemu-pmu-plugin` is wired; `gen --emit qemu` includes it. |
| **Q8** MTTCG scale + virt profile + distro | **in progress** — B0 stock-QEMU driver now derives `-smp` from `harts_total` or the model's core/threads-per-core topology, emits `maxcpus` as a hotplug ceiling, parses `--icount N|off` and `--tcg-tuning default|tuned`, forces single-threaded TCG when icount is on (MTTCG and icount are mutually exclusive), allows explicit multi-threaded TCG with `tuned`, parses `--rootfs-format raw|qcow2`, `--console uart|virtio`, `--virtio rng`, `--os buildroot|ubuntu|debian|fedora` (forces `g6lc-virt`, `qcow2` default, and a default `root=/dev/vda` append), and `--distro-root` (searches for `vmlinuz/Image`, `initrd.img`, and `rootfs.qcow2`). `architecture/CLI.md` and `EMIT.md` updated. Q8 surface complete |
| **Q9** capability matrix | **done** — `g6q-ingest/src/matrix.rs` builds a JSON matrix from `Sources` and the capability table, one row per capability with `config` probe/value, `flist` probe/evidence, `dts` tokens/node/declared, `qemu` properties/delta, and the conformance `verdict`; `gen --emit matrix` wired in `g6q-cli/src/main.rs`; `g6q-core/src/json.rs` added `get`, `is_null`, `is_empty`, `as_array`, and `as_string` accessors; `g6q-flist/src/lib.rs` added `Presence::as_str`; tests cover matrix shape and the unsupported-QEMU delta. `architecture/CLI.md` and `architecture/IR.md` updated. |
|| **Q10** computed-only MMU geometry | **done** — `g6q-core/src/model.rs` `Isa` gains `paddr_bits`, `vaddr_bits`, `page_table_levels`, `vpn_bits`, and `satp_mode`; `g6q-ingest/src/lib.rs` derives these from `mmu_mode` + `xlen` for `sv32`, `sv39`, and `sv48`; `g6q-vm/src/mmu.rs` is now model-driven: a `Mmu` struct is built from `Isa` and used by `translate(mem, mmu, satp, vaddr)`, supporting bare, Sv32, Sv39, and Sv48 geometry; `g6q-vm/src/exec.rs` `Hart` stores a `Mmu`, `Hart::with_isa` derives it from the model, and `Hart::new` defaults to bare; CLI `run` uses `Hart::with_isa`; unit tests cover bare, Sv39 1 GiB leaf, non-canonical detection, and mode mismatch. `architecture/INGEST.md` and `schemas/target-model.schema.json` updated. |

### Q4/Q6 — B1 queue-instruction execution: helpers, in-target device, and ABI unification (this pass)

Closes the Q4/Q6 follow-up that was recorded as *"the generated `trans_` routines are stubs, so
actual B1 execution of `custom2` queue instructions still requires helper functions and an AI-island
device."* The helper/device half existed as unlanded work; this pass finished it **and removed the
directive-§1.2 violations it had introduced**, which were the same defect class Change set B5 was
written about — a backend that looks architecture-derived while typing its own constants.

**One source of truth for the accelerator ABI (the structural change).** B1 was becoming a *third*
implementation of the completion word and the capability window, alongside B2's decoder and B3's
device. Both moved into the IR:

- `g6q-core::model::AiDescLayout::pack_completion_word(ticket, status)` — packs from the ingested
  `make_completion` layout, with the fallback named once as `FALLBACK_COMPLETION_STATUS_SHIFT`. Also
  hardened: a malformed bit range now contributes nothing instead of wrapping into another field.
- `g6q-core::model::AiIslandConfig::{cap_words, cap_value, cap_unsourced}` + `clog2_u32` — moved out
  of `g6q-vm` verbatim. `g6q-vm::AiIsland` now delegates; all 112 of its tests still pass, which is
  the point of moving rather than reimplementing.

**B1 `ai_island.rs` is now model-derived throughout.** Replaced: the hard-coded
`status<<32 | ticket` macro (whose comment said `status[47:32]` while the code wrote `[63:32]`);
literal `0` for `ST_OK` at three sites; `cap_offsets` fallbacks of `0`/`4`/`8` and an invented
16-byte window width that answered 3 of ~12 capability words — a guest reading an un-emitted word
got `0`, which is a *legal* capability value; and `desc_bytes.max(64)` / `ptr_done = desc_bytes - 8`
invented geometry. The capability window is now a generated table from `cap_words()`, the version
check is emitted only when the accepted version, its field offset and `ST_BAD_VER` are *all*
published, and an empty window emits no table and no lookup (a zero-length array is not valid C).

**Fixed defects found while finishing it:**

- `machine.rs` passed `desc_layout.desc_bytes.max(64)` as `desc_base` — **a size used as an
  address**. Bases are now passed as `(bool decoded, uint64_t base)` pairs; unresolved means the
  window is not decoded and the device `warn_report`s, per Change set B4.
- Three different emission guards (`trans.rs` required `mask_f7f3op != 0`, `ai_island.rs` did not,
  `machine.rs`/`build.rs` used `ai_island.is_some()`), and `trans::emit` called `ai_island::emit`
  unconditionally. A model with an opcode but no mask emitted a device with no callers; the machine
  would `#include` a header that was never emitted. All four now call `ai_island::resolved()`.
- B1 `enq` returned `0xffffffff` on a full ring — the same value `poll` returns for *pending*. Now
  `0`, matching B3, with the pending sentinel emitted as one named macro. Recorded as ask **F15**:
  neither value is published by the design.
- `warn_report` was used without `qemu/error-report.h`.

**The payload's ELF link was silently broken, and the ledger's diagnosis of it was wrong.**
`tools/remote/payload/ai_island_smoke.lds` did not discard `.interp`/`.dynamic`/`.note`, so
`riscv64-linux-gnu-gcc` produced a dynamic executable whose program headers could not fit in front
of `.text` at DRAM base — the linker placed the LOAD segment one page *below* it (`0x7ffff000`).
QEMU loaded nothing and the reset vector jumped into unmapped memory: `-kernel <elf>` hung with **no
output at all**. `objcopy -O binary` hid it by discarding everything but `.text`, and a bare-metal
toolchain hides it by not emitting those sections — so it only appeared when the builder's toolchain
changed. The earlier remote AI-island failure attributed to unresolved `cap_base`/`desc_base` is
this. Fixed in the linker script plus `PAYLOAD_LINK_FLAGS` (`-static -no-pie --build-id=none`) in
`g6q_remote.py`, so local and remote compiles share one hardened link.

**The queue smoke was trivially satisfiable.** It only checked `x6 != 0xffffffff`, so any value —
including `0` from an early `!island` return — passed. It now poisons `ptr_done` with a sentinel and
asserts three things: the entry is not pending, the island **overwrote the sentinel**, and the word
returned in `rd` **equals the word written to memory**. It also `#error`s with a readable message
when a model-derived macro is missing, instead of emitting a wall of "illegal operands".

**B2 queue-instruction submissions cannot work on the pinned QEMU, and now say so.** The path
recorded nothing. Root cause: `qemu_plugin_get_registers()` is built from `gdb_get_register_list()`,
which walks only *dynamically-registered* gdbstub features (`cpu->gdb_regs`); a target's **core**
register file is never in that list. On v10.0.0 the `riscv64` list is 92 CSRs and no GPR, so `rs1` is
unreachable. Change set C6 claimed these APIs were "verified against the fetched pinned header" — the
header was verified, the behaviour was not. Fixed what can be fixed: registers are resolved in the
vCPU-init callback and **re-fetched on a lookup miss** (the list grows, and caching the miss disabled
every register read for the run), the limitation is warned once naming the API and pointing at B1/B3,
and `descriptor_addr` no longer subtracts the island base for a DRAM descriptor (the latch path
reports a window offset, the instruction path a guest-physical address).

**`install-qemu` re-entrancy.** Build-wiring appends used `if block in existing`, which both
re-appended on any emitter whitespace change and skipped a real append on a coincidental comment
match. Replaced with `_wiring_block_present()`, a whole-line comparison ignoring blanks and comments.
This was not theoretical: `hw/riscv/meson.build` and `target/riscv/meson.build` each carried only the
`g6lc-ai` block while `Kconfig` and `riscv64-softmmu.mak` carried all four targets, so three
generated machines were on disk and in the config but **never compiled**. After the fix, installing a
second target appended correctly and both machines build.

**Other stability fixes:** remote `configure`/`build`/`run` gained wall-clock ceilings
(`--step-timeout`, `0` disables) so a wedged builder fails instead of blocking; `_control_socket`
validates the ControlMaster with `ssh -O check` and removes a stale socket; `cmd_pull` stages to a
temp file and verifies it arrived before replacing the local binary (it previously deleted the
binary first, then called `chmod` on a path it had just renamed away); `payload_flags.py` refuses a
descriptor address below DRAM base instead of emitting `0x-...`; `fetch-qemu` reports a failed `git
fetch` instead of silently checking out a stale revision, writes `.g6lc_qemu_pin` LF-only, and
`_extract_archive` no longer leaks a scratch directory per extraction.

Verified (local, `fixtures/ai` + `E:\cva6` repo root, QEMU v10.0.0 built under WSL):

| Check | Result |
|---|---|
| `python tools/g6q.py check` | green — 56 `g6q-emit-qemu`, 40 `g6q-core`, 112 `g6q-vm`, 68/45/30/55/11/26/52 elsewhere |
| B1 machine + device + helpers compile | `hw_riscv_g6lc-ai-ai-island.c.o`, `target_riscv_g6lc-ai-ai-helpers.c.o`, `decode-g6lc-ai-ai.c.inc` |
| Payload ELF LOAD segment | single segment at `0x80000000` (was `0x7ffff000`) |
| B1 `-kernel <elf>` | `AI_OK` (previously no output) |
| B1 `-kernel <bin>` | `AI_OK` |
| B1 + B2 plugin attached | `AI_OK`, plus the one-time GPR-unreachable warning |
| **B3 native VM, same strengthened payload** | `AI_OK` — B1/B3 agree on pending-vs-done, the `ptr_done` write, and register-vs-memory word equality |
| Multi-target install | `g6lc-ai` **and** `g6lc-g6lc64_smt2` both registered and built |
| OpenSBI on `g6lc-g6lc64_smt2` | `OpenSBI v1.5.1`, `Platform Name: GSys LibreCore g6lc64_smt2` (explicit `-bios`; the default lookup needs an installed datadir) |

Not done, deliberately:

- No attempt to recover `rs1` in B2 by shadowing DRAM stores — that would infer a descriptor address
  from traffic rather than read it, which is the guessing this package exists to avoid.
- `POLL_PENDING` and the ring-full return stay emulator conventions until **F15** is answered.

### Remote build and AI-island scaffold (earlier pass)

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
limit. **Resolved by the G9 pass** — the SoC package (`*_soc_pkg.sv`) is discovered from the
expanded manifest or supplied via `--soc-pkg`, and top-level `NumTargets`/`NumSources` set the
interrupt-controller capacity. If the package is absent, `max_harts` remains `null`.
*Priors: `architecture/INGEST.md` §1 (planes).*

**G10 — Capability table coverage.** `crates/g6q-ingest/data/capabilities.ini` covers the extension
and unit surface reached so far. It is data and is expected to grow; two rules keep it honest. A
capability with no separate compilation unit must have **no** `impl` entry, or manifest membership
will report it as a stub. A capability the device tree cannot express must have **no** `dts` entry —
giving privilege modes extension tokens produced a false `undeclared` on every target until it was
removed. **G10 pass added `zcb`, `zcmp`, `zcmt` and `pmp`**: the three Zc code-size sub-extensions are
intrinsic (no `impl`) and use the standard `zcb`/`zcmp`/`zcmt` dts tokens; `pmp` uses the `NrPMPEntries`
count as its config probe and the `core/pmp/` compilation unit, with no `dts` token because the tree
cannot express PMP presence. Existing `zcb` now appears as `live` on `g6lc64_smt2`; `pmp` is `live`
where `NrPMPEntries > 0`; `zcmp`/`zcmt` remain `absent` until a target enables them.
*Priors: `crates/g6q-ingest/data/capabilities.ini` header.*

**G2 — Reader strategy escalation.** The Q0/Q1 config reader is deliberately narrow: it understands
`localparam` scalars, enum identifiers, named struct-literal members and simple arithmetic, and it
**fails loudly** rather than defaulting. If it proves brittle across real packages, escalate to a
vendored full SystemVerilog parser as an integral in-tree copy with a pin file — do not accumulate
special cases. Record the decision here before doing it.
*Priors: `architecture/INGEST.md` §2.*

**G3 — Schema stability.** `schemas/target-model.schema.json` and `conformance.schema.json` are
version-stamped from the first release. Any field rename is a `schema_version` bump plus a fixture
update; consumers read the version before the payload. **G3 pass bumped the model and conformance
schemas to version 2** and made `conformance.schema.json` require `schema_version` and `profile` so
a standalone report is self-describing.
*Priors: `architecture/IR.md`.*

**G4 — Zero-dependency stance.** The workspace has no external crates and offline
`cargo test --workspace` must keep working. Adding a dependency requires a decision recorded here, a
`pins.toml` entry with an exact version, permissive licence only, and a note on offline behaviour.
**G4 pass verified:** `tools/check_independence.py` rejects any non-path dependency or inherited
workspace dependency that is not itself an in-package path; `cargo test --workspace` runs offline
with only the pinned rust-toolchain; `pins.toml` `[dependencies]` is deliberately empty.
*Priors: `AGENTS.md` §3, `AGENTS-licensing.md` §5.*

**G5 — `E-GPLLINK` regression.** `tools/check_independence.py` is the enforcement point. Extend it
whenever a new way to reach QEMU appears (a build script, a linker attribute, a vendored header). A
violation must be a build failure, never a review comment. **G5 pass strengthened it** to catch
`links`, `build`, `crate-type`, and `target.'cfg(...)'.dependencies` in `Cargo.toml`;
`#[cfg_attr(..., link/)]`, `global_asm!`, and `include_str!`/`include_bytes!` that escape or load
under a `qemu/` path; added `--selftest` and wired it into `g6q.py check`. The check is now a build
failure for all known native-link surfaces.
*Priors: `AGENTS-licensing.md` §2.3.*

**G6 — Profile discipline plumbing.** `profile` must be a required field of every artifact the moment
artifacts start existing (Q2). Retrofitting stamps after the fact is how a `g6lc-virt` result ends up
quoted as a hardware result. **G6 pass added `profile` to `g6q_core::conform::Report`**; `g6q-ingest`
stamps it from the model's profile and `g6q-cli` demo_model sets it. The standalone conformance
JSON (`conform --json`, `gen --emit conformance`) now carries both `schema_version` and `profile`.
*Priors: `architecture/DESIGN.md` §"Machine profiles".*

**G7 — Pin hygiene.** `pins.toml` currently records QEMU, OpenSBI, and the external contracts this
package consumes. Whenever a consumed contract changes upstream, bump the pin **and** the affected
schema/ABI version in the same pass. Never reinterpret bits silently. **G7 pass updated the Q6
accelerator pins:** `contracts.ai_isa` now points to `core/cvxif_g6lc_ai/include/g6lc_ai_instr_pkg.sv`
and `contracts.ai_island_mmio` to `corev_apu/ai_island/include/g6lc_ai_desc_pkg.sv`; both are now
`read-at-runtime` because the package ingests the named package into `AiInstrSet`, `AiDescLayout`,
and `AiRegMap` rather than transcribing the document. The `isa-encoding.md` document and
`README.md` remain informative but are no longer the contract source for the generator.
*Priors: `AGENTS.md` §1.9.*

**G8 — Host adapter stays optional.** If a host project grows an adapter that spawns this CLI, it
lives in the host, not here, and the package must keep working without it. **G8 pass verified:** no
crate imports from a host build platform or CI harness; `g6q_remote.py` and `ai_tensor_bridge.py` are
standalone scripts the host may call, and the package never calls back into the host; `python
tools/g6q.py check` passes with no host path configured.
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

## Large change sets — grouped passes

The work that used to be open here has landed as the grouped passes below.  Each landed as a single
coherent pass with its own green `python tools/g6q.py check` and a fixture or remote test.

### Change set A — RTL/RVFI trace bridge (closes G12, landed)

Goal: a `g6lc-qemu ingest rvfi` path that reads CVA6 `trace_rvfi_hart_*.dasm` and produces a
`RecordFile` that `tandem` can compare against a QEMU or B3 trace.

**Landed in the Q5/Q6 RVFI dasm bridge pass.**

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

### Change set B — AI-tensor event model + clustering (closes G13, landed)

Goal: move the AI-island counter from "any MMIO in the window" to "descriptor ring events", and
scale the model to a cluster of islands / queues with per-operation efficiency counters.

**Landed across Change sets B2–B6 and C1/C2/C6/C7.**

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

Resolved since this section was opened:
- Firmware topology invariants (processor-node count and firmware hart count both equal `S`) as
  emitted-artifact checks:
  * `g6q-emit-qemu/src/dts.rs` test `dtb_cpu_node_count_matches_harts_total` asserts the generated
    FDT has one `cpu@{h}` node per logical hart.
  * `g6q-emit-qemu/src/machine.rs` emits a `g6lc_<target>_machine_fdt_check` runtime self-check
    that counts `cpu@*` subnodes under `/cpus` and `g_assert`s the count equals `g6lc_harts_total`.
  * `g6q-cli/src/main.rs` `fw_build` derives `PLATFORM_HART_COUNT` from the resolved model or DTS
    and reports it in the build JSON, so OpenSBI builds for the same hart count the FDT declares.
  * **Live build-and-boot gate passed:** `python tools/g6q.py install-qemu/build-qemu` for both
    `g6lc-target` and `g6lc-g6lc64_smt2` succeeded; `qemu-system-riscv64 -M g6lc-target` booted
    OpenSBI v1.5.1 with `Platform HART Count: 1`, and `-M g6lc-g6lc64_smt2` booted with
    `Platform HART Count: 2` and `Domain0 HARTs: 0*,1*`, confirming the two-thread SMT bring-up.
- Q6 in-guest AI smoke through the B3 native VM:
  * Fixed `g6q-vm/src/c.rs` `c_lui_imm` which shifted the `c.lui` nzimm left by 12 twice, producing
    `0x10000000` for a `c.lui x1, 0x10` instead of `0x10000`. Added `c_lui_imm_places_nzimm_in_bits_17_12`
    unit test with known machine words (0x60c1, 0x6085, 0x61fd).
  * The `tools/remote/payload/ai_island_smoke.S` payload compiles with model-derived flags from
    `payload_flags.py` and runs to `AI_OK` under `g6lc-qemu run --backend native --image out/ai_island_smoke.bin`
    for `fixtures/ai`; the tensor artifact records one `op=1`, `version=1`, `done=true` event.
- B1/B2 QEMU `g6lc-ai` machine from the same fixture:
  * `python tools/g6q.py install-qemu --package fixtures/ai --target ai` and `build-qemu` produced a
    `g6lc-ai` machine and `libg6lc-ai.so` / `libg6lc-ai-pmu.so` plugins.
  * The generated `qemu-system-riscv64 -M g6lc-ai -kernel out/ai_island_smoke.bin -bios none ...
    -plugin qemu/build/contrib/plugins/libg6lc-ai.so` runs to `AI_OK`, confirming the B1 FDT/SoC
    wiring matches the B3 model and the B2 plugin attaches to the AI-island window.
  * Fixed `tools/g6q.py _add_contrib_plugin` which used a substring match (`name in text`) and
    therefore thought `g6lc-ai` was already listed when `g6lc-ai_soc` and `g6lc-ai-pmu` were present.
    It now checks for the exact `contrib_plugins += '<name>'` line.
- Q7 D2 diagnosis over `fixtures/ai`:
  * `g6lc-qemu diag --uarch-out out/ai_uarch.json ...` with the AI fixture emits
    `ai.island.*` geometry counters (Exact) plus roofline counters (Modelled).
  * Merging the B3 native `out/ai_smoke_tensor.json` with `--tensor` adds
    `ai.tensor.ops`/`completes`/`bytes`/`macs`/`queue_entries` (Synthetic) and
    `ai.pmu.*` (Modelled) to the same counter array, closing the Q7 D2/Q6 runtime loop.
- Q7 B2 PMU plugin over the AI smoke:
  * `libg6lc-ai-pmu.so,out=/.../ai_qemu_pmu.json` attached to the `g6lc-ai` machine and ran
    the payload to `AI_OK`; the generated `out/ai_qemu_pmu.json` has one hart with
    `cycles: 39`, `instructions: 39` and the PMU event table (currently one `unresolved`
    placeholder event), confirming the Q7 B2 PMU plugin emits the counter artifact contract.
- Q6 in-guest queue-instruction smoke:
  * `payload_flags.py` now exports `AI_ENQ_MATCH`, `AI_POLL_MATCH`, `AI_QFENCE_MATCH`,
    `AI_DESC_BYTES`, and `AI_DESC_ADDR` (queue path: a descriptor in guest DRAM) when the
    model's `soc.ai_island.instr_set` is published.
  * New payload `tools/remote/payload/ai_island_queue_smoke.S` uses the design's own
    `ai.enq`/`ai.qfence`/`ai.poll` encodings (assembled via `.word` with the model's
    `match_*` values) to build a descriptor in DRAM, submit it, fence, and poll.
  * Compiled with WSL `riscv64-linux-gnu-gcc` and run through B3 native VM:

        cargo run -p g6q-cli -- run --backend native \
          --config-pkg fixtures/ai/ai_soc_config_pkg.sv \
          --flist fixtures/ai/manifest.f --dts fixtures/ai/board.dts \
          --target ai --image out/ai_island_queue_smoke.bin --steps 200 \
          --record out/ai_queue_record.json --tensor out/ai_queue_tensor.json

    prints `AI_OK`; `out/ai_queue_tensor.json` records `descriptor_addr = 0x8000ffc0`,
    `ptr_done = 0x80010000`, `m=n=k=1`, `op=1`, `version=1`, `done=true`,
    `status=0`, plus the roofline counters.
- Q8 DTS parser bug fix:
  * `fixtures/ai/board.dts` `stdout-path = "/soc/uart@10000000:115200";` misparsed because
    `parse_body` treated the `:` and trailing `;` inside the quoted string as structural tokens,
    turning the property name into `115200"`. `g6q-dts/src/tree.rs::parse_body` is now quote- and
    escape-aware, and a unit test (`colons_and_semicolons_inside_strings_do_not_misparse`) pins
    the fix.
  * `g6lc-qemu gen --emit dtb ...` for `fixtures/ai` now produces a DTB whose `fdtdump` shows
    `chosen { stdout-path = "/soc/uart@10000000:115200"; }`.
- Q5 D1 replay / tandem over the AI smoke:
  * `g6lc-qemu run --backend native ... --record out/ai_native_record.json` recorded 100,000
    instructions and printed `AI_OK`.
  * `g6lc-qemu run --backend native ... --replay out/ai_native_record.json` replayed to `AI_OK`
    with no divergence.
  * Two fresh `run --record` invocations compared with `tandem --under-test r1 --reference r2`
    report `"divergence": false` / `"records": 100000`, confirming the B3 VM is deterministic.
  * QEMU B2 `libg6lc-ai.so,trace=...` produced a 39-record trace (`out/ai_qemu_trace.json`)
    from the same payload, but its `prv` field is fixed at `0` because the plugin API does not
    expose current privilege; it is therefore a smoke trace, not a D1 reference.
- Conformance rules for `S` above the interrupt-context cap, and accumulator banks below thread
  count (`g6q-core::TargetModel::topology_rows` and `g6q-svcfg::derive::derive` both mirror the
  design's own assertions; tests cover the over-budget and raise-to-thread-count cases).
- B2 descriptor reassembly (`g6q-emit-qemu` plugin now emits submissions for both the MMIO-latch
  and queue-instruction paths; `AGENTS-todo.md` Q7/Q8 pass rows document the landed Change Sets
  C1 and C6).

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

### Change set B6 — 100-TOPS roofline report, PCIe transport stub, and remote payload flags (landed)

Goal: close the AI-tensor bridge pass requested in AGENTS-todo.md open items (100-TOPS reporting,
PCIe concept, and `g6q_remote.py` payload model-driving) without duplicating the roofline arithmetic
or inventing an unpinned transport.

Landed:
- `tools/ai_tensor_bridge.py results --tops` runs `g6lc-qemu diag` on the artifact, reuses the D2
  counter stream, and reports a 100-TOPS-style section (`peak_tops`, `peak_gops`, `total_macs`,
  `total_ops`, `total_gops`, `theoretical_time_us_at_peak`, `blocking_t`, `macs_per_cycle_total`,
  balance, intensity, and `bound` when a measured DRAM bandwidth closes the roofline). It is marked
  `tops_not_evidence: true` and prints the standard non-evidence disclaimer. `--measured-dram-gbps`
  closes the roofline if a host measurement exists.
- `tools/ai_tensor_bridge.py pcie` prints the proposed PCIe/virtio/BAR concept and exits with an
  error while `contracts.ai_host_transport` is `unpinned`. It does not invent descriptor geometry or
  transport state.
- `tools/remote/payload_flags.py` derives RISC-V payload `-D` flags from the ingested `TargetModel`
  (AI-island and UART bases, descriptor `desc_base`, field offsets for `m`/`n`/`k`/`ptr_done`,
  `OP_GEMM`, descriptor `version`, and the done pointer). `g6q_remote.py test --ai-island` and
  `remote-build --test-ai` accept `--model`, `--ai-m`, `--ai-n`, `--ai-k`, and `--ai-done-ptr` and
  pass the derived flags to the remote cross-compiler.
- `architecture/AI_BRIDGE.md` §5/§6 and `architecture/CLI.md` updated to describe `results --tops`,
  `pcie`, and the model-driven remote payload.
- `python tools/g6q.py check` green; `ai_tensor_bridge.py selftest` OK; local `g6lc-qemu diag` with
  `--tops` on the `ai_soc` tensor artifact reports 0.512 TOPS peak and 16.78M MACs for one GEMM
  event (not a 100-TOPS claim).

Deliberately not done, with reasons:
- No actual PCIe BAR/virtio/MSI modelling — `contracts.ai_host_transport` remains `unpinned`.
- No measured TOPS or host cycle count — the package does not invent timing.
- The roofline is still produced by `g6lc-qemu diag`; the bridge only re-aggregates.

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

### Change set C — D2 microarchitecture + virt distro readiness (Q7/Q8, landed)

Goal: make the D2 counters and virt profile usable for distro scale.

**Landed across the D2/virt readiness passes.**

Components:
- PMU event table ingestion from design package. **Landed** in prior pass.
- Generated PMU counter device tree and QEMU CPU properties. **Landed** — `/pmu` FDT node with OpenSBI-compatible raw and generic event-to-counter mappings, per-hart `interrupts-extended` for Sscofpmf, and generated `g6lc-*` CPU `ext_zihpm`/`ext_sscofpmf`/`pmu_mask`; B0 stock `-cpu` also appends `pmu-mask` when the model has counters live.
- QEMU counter plugin (B2) — **landed** for the model's published event table, with synthetic cycles/insns and zeroed unmapped event rows; `libg6lc-ai_soc-pmu.so` builds and `out=...` writes a per-hart JSON.
- Virtio block/network bridge for `g6lc-virt` — **landed**.
  - `g6q-emit-qemu` machine emitter now instantiates `virtio-mmio` transports from the model's `Soc.virtio_mmio` count and wires their IRQs to the PLIC.
  - `g6q-emit-qemu` FDT emitter emits Linux-compatible `virtio,mmio` nodes with `reg`, `interrupts`, `interrupt-parent`, and `dma-coherent` for each transport.
  - `g6lc-qemu gen` defaults `Soc.virtio_mmio = 8` when `--machine g6lc-virt` is requested, so the virt profile does not require an explicit `--virtio-mmio` count.
  - `python tools/g6q.py install-qemu` accepts `--machine` and `--virtio-mmio` and passes them through to `g6lc-qemu gen`.
  - A local `ninja -C qemu/build` with the AI fixture installed in `g6lc-virt` profile produces a `qemu-system-riscv64` that accepts both `-device virtio-blk-device,drive=hd0` and `-netdev user,id=net0 -device virtio-net-device,netdev=net0` on `-M g6lc-ai_soc` without error. `tools/g6q.py build-qemu` gains an opt-in `--slirp` flag to enable libslirp (and therefore the `user` netdev backend) by passing `--enable-slirp` to QEMU's configure.
- MTTCG determinism hooks (icount, inter-hart quantum) — **already landed** in Q8 B0 driver (`g6q-emit-args/src/invoke.rs`); `-icount` with `shift=N,align=off,sleep=off` and the `-accel tcg,thread=single|multi` resolution are wired and tested.

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
| 2026-08-30 | Q2 `g6lc-qemu run --backend qemu` WSL support + built plugin path fix | `g6q-cli/src/main.rs` adds `--wsl` to `run --backend qemu`: it spawns the QEMU binary through `wsl --` and converts Windows paths in `--kernel`, `--initrd`, `--dtb`, `--elf`, `--drive`, `--debug-file`, `--plugin` and the `--record` trace file into WSL-friendly paths (`C:\` -> `/mnt/c/`, backslashes -> forward slashes); `plugin_path()` now defaults to the built `qemu/build/contrib/plugins/libg6lc-<id>.so` instead of the generated-source `out/emit` tree; new unit tests cover `wslize_path`, `wslize_qemu_comma_arg`, and WSL dry-run wrapping; `architecture/CLI.md` documents `--wsl`, renames `--qemu-bin` to `--qemu-path` to match the implementation, and updates the `--plugin` default. | `python tools/g6q.py check` green; `g6q-cli` 59 tests pass. |
|| 2026-08-29 | **Q4/Q6 B1 queue-instruction execution + accelerator-ABI unification** (see the section above for the full account) | `g6q-core` gains `AiDescLayout::pack_completion_word` (+ `FALLBACK_COMPLETION_STATUS_SHIFT`) and `AiIslandConfig::{cap_words,cap_value,cap_unsourced}` + `clog2_u32`, moved out of `g6q-vm` so B1/B2/B3 share one implementation of the completion word and the capability window; `g6q-vm` delegates; new `g6q-emit-qemu/src/{trans,ai_island}.rs` emit the decoder, `trans_` routines, helpers and an in-target AI-island device behind a single `ai_island::resolved()` guard also used by `machine.rs` and `build.rs`; removed the hard-coded completion layout, literal `ST_OK`, invented `cap_offsets`/window width, invented descriptor geometry, and `machine.rs` passing a *size* (`desc_bytes`) as the `desc_base` *address*; ring-full return separated from the poll-pending sentinel (ask **F15**); payload linker script + `PAYLOAD_LINK_FLAGS` fix an ELF whose LOAD segment landed below DRAM base (the real cause of the remote AI-island failure previously blamed on unresolved island placement); queue smoke strengthened to assert the `ptr_done` write and register-vs-memory agreement, with `#error` guards for missing model macros; B2 register access moved to the vCPU-init contract, re-fetched on miss, `descriptor_addr` corrected per submission path, and the pinned-QEMU GPR limitation warned once; `install-qemu` wiring guards made whole-line (three generated machines were in `Kconfig`/`.mak` but absent from both `meson.build` files, so they were never compiled); remote `configure`/`build`/`run` timeouts, ControlMaster staleness check, safe `pull`, and several `g6q.py` robustness fixes. `architecture/EMIT.md` §3.5/§3.6/§4, `architecture/RTL_FEEDBACK.md` **F15** updated. | `python tools/g6q.py check` green; `g6q-emit-qemu` 56, `g6q-core` 40, `g6q-vm` 112 tests pass. Live: B1 `-kernel` ELF **and** raw image → `AI_OK`; B1+B2 plugin → `AI_OK` + one-time warning; B3 native, same payload → `AI_OK`; `g6lc-ai` and `g6lc-g6lc64_smt2` both build; OpenSBI v1.5.1 banner on `g6lc-g6lc64_smt2`. |
| 2026-08-30 | B2 PMU counter plugin (Change Set C part 3) | `g6q-emit-qemu/src/pmu.rs` now generates a buildable `g6lc-<target>-pmu.c` with `<inttypes.h>`, `PRIu64` formatting, and a `g6lc_pmu_event_value` helper that maps `cycles`/`instructions`/`minstret`/`mcycle` events to synthetic per-hart counts; other published events stay zero unless a later pass maps them. `g6q.py install-qemu` wires both `g6lc-<target>` and `g6lc-<target>-pmu` into `qemu/contrib/plugins/meson.build`. The `g6lc-ai_soc-pmu` plugin builds and writes a counters JSON (`{header, harts:[{hart,cycles,instructions,events:[{name,selector,value}]}]}`) when run with `out=FILE`. `python tools/g6q.py check` green; `g6q-emit-qemu` 38 tests pass; local `ninja -C qemu/build` and `qemu-system-riscv64 -plugin .../libg6lc-ai_soc-pmu.so,out=...` pass on the AI smoke payload. `architecture/EMIT.md` §B2.x and `AGENTS-todo.md` updated. |
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
|| 2026-08-30 | Remote build/test timeout and control-socket hardening | `tools/g6q_remote.py` `_control_socket` now reuses a valid ControlMaster (`ssh -O check`) and only starts a new one when the socket is absent or stale; it raises `RuntimeError` if the master fails to create its socket. `_rsync_to_remote`/`_rsync_from_remote` accept a timeout and fail on non-zero rsync. `_xpack_remote_bin_dir` honours `G6Q_REMOTE_XPACK_BIN`. Step timeouts are now passed through `cmd_doctor`, `cmd_sync`, `cmd_pull`, `cmd_clean`, and every `cmd_test` path (`smoke`, `plugin`, `ai-island` build/compile/run/grep). | `python tools/g6q.py check` green; `python -m py_compile tools/g6q_remote.py` OK. |
||| 2026-08-30 | Q4/Q6 queue-instruction smoke completion-word verification | `tools/remote/payload_flags.py` now exports `AI_ST_OK`, `AI_COMPLETION_TICKET_MASK`, `AI_COMPLETION_STATUS_SHIFT`, and `AI_COMPLETION_STATUS_MASK` from the ingested `desc_layout.completion` and `statuses.ST_OK`, falling back to the same `{16'h0, status, ticket}` layout the B1/B3 packer uses when the design does not publish `make_completion`. `tools/remote/payload/ai_island_queue_smoke.S` now asserts: (a) the entry is not still pending; (b) the island overwrote the sentinel at `ptr_done`; (c) the `ai.poll` return equals the memory-written word; (d) the completion word contains the ticket returned by `ai.enq`; (e) the status field equals `ST_OK`. | `python tools/g6q.py check` green; `g6lc-qemu run --backend native --config-pkg fixtures/ai/ai_soc_config_pkg.sv --flist fixtures/ai/manifest.f --dts fixtures/ai/board.dts --image out/ai_island_queue_smoke.bin` prints `AI_OK` with the new assertions. |
|| 2026-08-30 | Q4/Q6 model-driven payload linker script + `install-qemu` plugin wiring | `tools/remote/payload_flags.py` adds `generate_payload_lds(model, out_path)` to write an `ai_island_smoke.lds` whose load address and `_stack_top` come from `soc.dram.base` and `soc.dram.len` instead of hard-coded `0x80000000`/`0x81000000`; the default `ptr_done` is now clamped to fit within the published DRAM length. `tools/g6q_remote.py` `_compile_payload_local` and the remote `cmd_test --ai-island` path now use the generated linker script. `tools/g6q.py` `install-qemu` dry-run log and `AGENTS-todo.md` Q2 row now correctly state that `contrib/plugins/meson.build` is appended automatically (it has been since `_add_contrib_plugin` landed). | `python tools/g6q.py check` green; `python -m py_compile tools/g6q_remote.py` OK; `g6lc-qemu run --backend native --config-pkg fixtures/ai/ai_soc_config_pkg.sv --flist fixtures/ai/manifest.f --dts fixtures/ai/board.dts --image out/ai_island_queue_smoke.bin` prints `AI_OK` using the generated linker script; `g6lc-qemu install-qemu --dry-run` reports the correct plugin-wiring behaviour. |
||| 2026-08-30 | Q4/Q6 remote queue-instruction smoke flag | `tools/g6q_remote.py` `test` subcommand gains `--queue`; when used with `--ai-island` it compiles and runs `ai_island_queue_smoke.S` instead of the MMIO `ai_island_smoke.S`. `_compile_payload_local` now takes a `payload_stem`; log/ELF names follow the stem; `--queue` without `--ai-island` is rejected. The pass gate for `--queue` does not require the MMIO `ai_island_count` log line because the queue path uses `ai.enq`/`ai.qfence`/`ai.poll` directly. | `python tools/g6q.py check` green; `python -m py_compile tools/g6q_remote.py` OK; `g6q_remote.py test --help` shows `--queue`; `g6q_remote.py test --queue` rejects missing `--ai-island`; `g6q_remote.py test --ai-island --queue --model out/ai_soc_model.json --dry-run` succeeds. |
||| 2026-08-30 | Q4/Q6 remote smoke result naming | `tools/g6q_remote.py` `cmd_test` `--ai-island` result messages now name the payload (`ai-island-smoke` or `ai-island-queue-smoke`) and only print `ai_island_count` for the MMIO path. | `python tools/g6q.py check` green; `python -m py_compile tools/g6q_remote.py` OK. |
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
|| 2026-08-30 | B6 — 100-TOPS roofline report, PCIe transport stub, and remote payload flags | `tools/ai_tensor_bridge.py` gains `results --tops` (modelled peak/ops/MACs/time, `bound` when measured DRAM is supplied) and `pcie` concept, plus `--measured-dram-gbps`; `tools/remote/payload_flags.py` and `g6q_remote.py` `--ai-island` derive RISC-V payload compile flags from the ingested `TargetModel` and, when `--plugin-tensor` is set, pull the artifact and run `ai_tensor_bridge.py results --tops`; `architecture/AI_BRIDGE.md` and this file updated. | `python tools/g6q.py check` green; `ai_tensor_bridge.py selftest` OK; the existing `out/ai_soc_tensor_qemu.json` from a prior local QEMU smoke gives `results --tops --model out/ai_soc_model.json` `peak_tops: 0.512`, `total_macs: 16777216` for one `256x256x256` GEMM event (not a 100-TOPS claim). Local re-run is blocked by no RISC-V cross-toolchain and a WSL-only `qemu-system-riscv64`; the B3 equivalent (`g6q-vm` `ai_island_submits_and_completes` and `queue_enq_reads_descriptor_from_memory`) is exercised by `cargo test --workspace` and is green. |
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

| 2026-08-30 | G9 — SoC-package interrupt-controller capacity pass: `Sources` gains `soc_pkg: Option<Package>`; `g6q-cli` `resolve` discovers a `*_soc_pkg.sv` from the expanded manifest, or uses explicit `--soc-pkg`, and parses top-level `NumTargets`/`NumSources` into the model; `build_soc` prefers the SoC package's controller capacity over the device-tree wired count; `g6q-ingest` `soc_pkg_sets_interrupt_controller_capacity` test pins the behaviour; `ariane_soc_pkg.sv` now appears in `provenance.sources` and `g6lc-qemu gen --repo-root E:/cva6 --target g6lc64_smt2` reports `intc.targets=16`, `intc.max_harts=8`. `architecture/INGEST.md` §1 and this file updated; G9 resolved. | `python tools/g6q.py check` green; `g6q-ingest` 26, full workspace pass; `indep` and `flist` selftest pass. |
| 2026-08-30 | G10 — Capability table coverage pass: added `zcb`, `zcmp`, `zcmt` and `pmp` to `crates/g6q-ingest/data/capabilities.ini`. `zcb`/`zcmp`/`zcmt` are intrinsic (no `impl`) with `dts` tokens `zcb`/`zcmp`/`zcmt`; `zcb` is `live` on `g6lc64_smt2` because the device tree already advertises it; `zcmp`/`zcmt` remain `absent` until a target enables them. `pmp` uses `NrPMPEntries` as its config probe, `core/pmp/` as its compilation unit, and no `dts` token because the device tree cannot express PMP. The G10 invariant -- no `impl` for intrinsic features, no `dts` for tree-inexpressible features -- is preserved; the remaining `strict conformance: FAIL` on `g6lc64_smt2` is still the design gaps (`napot-pages` undeclared, `second-level-cache` stub), not table omissions. Also corrected `ai-island`'s `dts_node` from `ai-island` to `ai-matrix` after `conform` on `g6lc64_ai` showed the design advertises the island as `ai-matrix`. | `python tools/g6q.py check` green; `g6q-ingest` 26, full workspace pass; `indep` and `flist` selftest pass. |
| 2026-08-30 | G5 — Independence / E-GPLLINK regression pass: strengthened `tools/check_independence.py` to catch `links`, `build`, `crate-type`, and `target.'cfg(...)'.dependencies` in `Cargo.toml`; `#[cfg_attr(..., link/)]` and `global_asm!` in `.rs` files; and `include_str!`/`include_bytes!` paths that escape the package or load under a `qemu/` path. Added a `--selftest` that builds a bad package and a good package in a temporary directory and asserts the checker catches the expected violations while accepting the clean one. Wired `python tools/g6q.py check` to run the selftest after the real package scan so the regression check is exercised every green run. The existing `g6q-emit-qemu` module `build.rs` is a Rust source file, not a Cargo build script; the default build-script glob was tightened to `crates/*/build.rs` to avoid that false positive. | `python tools/g6q.py check` green; `indep` + `indep selftest` OK; full workspace pass. |
| 2026-08-30 | G7 — Pin hygiene pass: `pins.toml` `contracts.ai_isa` and `contracts.ai_island_mmio` now name the SystemVerilog packages the generator reads (`core/cvxif_g6lc_ai/include/g6lc_ai_instr_pkg.sv` and `corev_apu/ai_island/include/g6lc_ai_desc_pkg.sv`) and are marked `read-at-runtime`, matching the Q6 ingest implementation in `g6q-diag/ai_cfg.rs` and `g6q-diag/ai_desc.rs`. The markdown documents remain informative but are not the pin of record. | `python tools/g6q.py check` green; `indep` + `indep selftest` OK; full workspace pass. |
| 2026-08-30 | G3/G6 — Conformance report schema and profile stamp pass: `g6q_core::conform::Report` now carries `profile: Profile`; `Report::to_json` emits `schema_version` and `profile` alongside the rows. `SCHEMA_VERSION` and `pins.toml` schema_version bumped to `"2"`; `schemas/conformance.schema.json` and `schemas/target-model.schema.json` updated to require the new fields. `g6q-ingest::assemble` stamps the model's profile into `model.conformance.profile` so `conform --json` and `gen --emit conformance` cannot be mistaken for a different profile's result. `g6q-cli/src/main.rs` `demo_model` sets `report.profile = m.profile`; `g6q-core` tests and `fixtures/golden/mini-model.json` updated. | `python tools/g6q.py check` green; `g6q-core` 34, full workspace pass. |
| 2026-08-30 | G4/G8 — Zero-dependency and host-adapter boundary pass: verified that the workspace has no external crate dependencies (`check_independence.py` rejects non-path deps and inherited workspace deps not declared as in-package paths); `cargo test --workspace` runs offline; `pins.toml` `[dependencies]` is empty. Verified that no crate imports from or calls back into a host build-platform/CI harness; `g6q_remote.py` and `ai_tensor_bridge.py` are host-callable scripts only. Updated `AGENTS-todo.md` G4 and G8 invariants to reflect the standing enforcement. | `python tools/g6q.py check` green; `indep` + `indep selftest` OK; full workspace pass. |
| 2026-08-30 | `dts` verb pass: implemented the standalone `g6lc-qemu dts` verb in `g6q-cli/src/main.rs`; it resolves the device tree the same way `gen` does, applies `--dts-overlay`, `--dts-set`, and `--dts-del`, and emits either DTS source or a DTB blob via the existing `emit_device_tree` helper. `--validate` parses the tree and prints `valid`; `--emit dtb` switches to blob output. The unimplemented-verb test was retargeted to `fw fetch` (Q2 stub). | `python tools/g6q.py check` green; 51 `g6q-cli` tests, full workspace pass. |
| 2026-08-30 | `pins` verb pass: implemented a minimal in-crate TOML section parser in `crates/g6q-cli/src/pins.rs`; the `g6lc-qemu pins` verb now locates `pins.toml` by walking up from the current directory and reports the built-in tool constants plus the QEMU, OpenSBI, toolchain, and contract pins. The parser handles `[table]` sections, inline comments, string/integer/bare-word values, and nested `[contracts.<name>]` tables. Unit tests cover a sample pins file. | `python tools/g6q.py check` green; 52 `g6q-cli` tests, full workspace pass. |
| 2026-08-30 | `fw fetch` pass: `g6lc-qemu fw fetch` now locates `pins.toml`, reads the `[opensbi]` `url` and `ref` pins, and runs `git clone --depth 1 --branch <ref> <url> <dst>` into `out/fw-src/opensbi` (or `--fw-src`). `--dry-run` prints the planned clone command without running it. The destination is rejected if it already exists and is non-empty. `fw build` remains a Q2 stub (requires a cross-toolchain). | `python tools/g6q.py check` green; 52 `g6q-cli` tests, full workspace pass. |
| 2026-08-30 | `fw build` pass: `g6lc-qemu fw build` now reads the OpenSBI pin, validates that the source directory (`out/fw-src/opensbi` or `--fw-src`) contains a `Makefile`, detects a RISC-V cross-toolchain (`--cross-compile`, `CROSS_COMPILE`, or common `riscv64-*-gcc` prefixes on PATH), and invokes `make` with `CROSS_COMPILE=... PLATFORM=... FW_TEXT_START=...` plus `FW_DYNAMIC=y` (default), `FW_JUMP=y`, or `FW_PAYLOAD=y` depending on `--fw-mode`. `--dry-run` prints the planned `make` command. Source-less invocation is rejected with a clear error; the test verifies this. | `python tools/g6q.py check` green; 52 `g6q-cli` tests, full workspace pass. |
| 2026-08-30 | `g6q.py fetch-fw` and `g6q.py build-fw` pass: added `cmd_fetch_fw` and `cmd_build_fw` to `tools/g6q.py`, plus `fetch-fw` and `build-fw` argparse subcommands. These are thin wrappers that invoke `cargo run -p g6q-cli -- fw fetch|build ...`, reusing the in-crate pin reader and make logic. `--dry-run` works on both commands, printing the exact `git clone` or `make` command that would be run without requiring source or a toolchain. Updated the `g6q.py` header comment to list the new commands. | `python tools/g6q.py check` green; `g6q.py fetch-fw --dry-run` and `g6q.py build-fw --dry-run` verified end-to-end. |
| 2026-08-30 | `run` firmware/payload wiring pass: `resolve::boot_options` now treats `--fw-payload` as a synonym for `--kernel` when `--kernel` is absent, and auto-resolves a built OpenSBI firmware at `out/fw-src/opensbi/build/platform/<fw-platform>/firmware/fw_<fw-mode>.bin` when `--fw` is not given and `fw-mode` is not `none`. This makes `g6q run --backend args|qemu --fw ... --fw-payload ...` emit `-bios` and `-kernel` as expected. Added a `g6q-cli` test that verifies the stock-QEMU argv contains both flags and both paths. | `python tools/g6q.py check` green; 53 `g6q-cli` tests, full workspace pass. |
| 2026-08-30 | `doctor` RISC-V cross-toolchain probe pass: added `_probe_riscv_cross()` to `tools/g6q.py` and a `riscv cross-toolchain` row in `cmd_doctor`. It honors `CROSS_COMPILE` first, then tries the same `riscv64-*-` prefixes the `fw build` command uses, and reports the found prefix or `none found`. This makes `g6q doctor` useful as a pre-flight check before `g6q build-fw` / `g6q run` with a real cross-toolchain. | `python tools/g6q.py check` green; `g6q doctor` verified and shows the new row. |
| 2026-08-30 | `g6q.py run --build-fw` pass: added `_extract_fw_options()` and `--build-fw` handling to `cmd_run` in `tools/g6q.py`. When `g6q.py run -- --build-fw ...` is invoked, it first runs `fw fetch` and `fw build` (reusing `_fw_cli`) with the same `--fw-src/--fw-mode/--fw-platform/--fw-text-start/--cross-compile` and `--dry-run` flags, then proceeds to `cargo run -p g6q-cli -- run ...`. Verified end-to-end with `--dry-run` showing the clone, make, and run commands in sequence. | `python tools/g6q.py check` green. |
| 2026-08-30 | `AGENTS.md` daily commands pass: updated the package guider's daily commands list to include `fetch-fw`, `build-fw`, and the `run -- --build-fw ...` form, and updated the `doctor` one-liner to mention the RISC-V cross-toolchain probe. This keeps the landing-page documentation aligned with the new Q2 firmware chain. | `python tools/g6q.py check` green. |
| 2026-08-30 | `--fw-make` passthrough pass: `g6lc-qemu fw build` now accepts repeatable `--fw-make VAR=VAL` options and appends them to the OpenSBI `make` command line; invalid values (missing `=`) are rejected. `g6q.py build-fw` gained a matching `--fw-make` argparse option and forwards it. `g6q.py run --build-fw` extracts `--fw-make` from the `run` remainder and forwards it to both `fw fetch` and `fw build`. | `python tools/g6q.py check` green. |
| 2026-08-30 | `fetch-fw` real clone pass: ran `python tools/g6q.py fetch-fw` (no `--dry-run`) on Windows; it successfully cloned the pinned OpenSBI v1.5 source into `out/fw-src/opensbi` via `git clone --depth 1 --branch v1.5 ...`. `python tools/g6q.py build-fw` then correctly fails preflight because no RISC-V cross-toolchain is installed, preserving the honest error rather than attempting a broken build. | `fetch-fw` succeeded; `build-fw` blocked on missing cross-toolchain as expected. |
| 2026-08-30 | `--fw-out` staging pass: `g6lc-qemu fw build` now accepts `--fw-out DIR` (default `out/fw`). After a successful OpenSBI build, it copies `fw_<mode>.bin` and `fw_<mode>.elf` from the build tree to the output directory and reports them in the JSON under `staged`. `resolve::boot_options` now checks `out/fw/fw_<fw-mode>.bin` before the build tree when auto-resolving firmware for `run`. `g6q.py build-fw` and `g6q.py run --build-fw` forward `--fw-out`. | `python tools/g6q.py check` green. |
| 2026-08-30 | `architecture/CLI.md` firmware options pass: updated the firmware options table to document `--build-fw` as the package `fw fetch` → `fw build` chain (with a note that project-owned scripts may be wired later), clarified `--fw-out` as the staging directory for `fw_<mode>.bin/.elf`, and clarified `--fw-make` as a passthrough to the OpenSBI `make` command requiring `VAR=VAL`. | `python tools/g6q.py check` green. |
| 2026-08-30 | `fw build` test pass: added `fw_build_rejects_invalid_fw_make` unit test in `crates/g6q-cli/src/main.rs` that verifies `--fw-make` values missing `=` are rejected in dry-run mode. `g6q-cli` now has 54 unit tests. | `python tools/g6q.py check` green. |
| 2026-08-30 | `--fw-fdt` passthrough pass: `g6lc-qemu fw build` now accepts `--fw-fdt DTB`; when a path is provided it sets `FW_FDT_PATH=` for the OpenSBI make command. `--fw-fdt auto` is explicitly rejected with a clear message because generated-DTB embedding is not yet implemented. `g6q.py build-fw` and `g6q.py run --build-fw` forward `--fw-fdt`. `architecture/CLI.md` updated to mark `auto` as not-yet-implemented and document `DTB` as setting `FW_FDT_PATH`. | `python tools/g6q.py check` green. |
| 2026-08-30 | `g6q.py bridge` wrapper pass: added a `bridge` subcommand to `tools/g6q.py` that thinly wraps `tools/ai_tensor_bridge.py` (like `remote` wraps `g6q_remote.py`). Updated the header comment and `AGENTS.md` daily commands to list `python tools/g6q.py bridge`. Verified `g6q.py bridge doctor` runs the bridge doctor. | `python tools/g6q.py check` green. |
| 2026-08-30 | contained RISC-V toolchain pass: added `pins.toml` `[riscv_toolchain]` pin, `python tools/g6q.py setup-riscv` to download/extract the pinned xPack `riscv-none-elf-gcc` under `.tools/`, and `env_common.riscv_toolchain_bin()` so `apply_env()` and `g6q.py doctor` discover it. `g6q-cli` `detect_cross_compile` and `g6q.py _probe_riscv_cross` now include `riscv-none-elf-` and check the contained bin path. The toolchain was installed successfully on the Windows host under `.tools/xpack-riscv-none-elf-gcc-14.2.0-3`. | `python tools/g6q.py doctor` reports `riscv cross-toolchain ok`. |
| 2026-08-30 | `g6q_remote.py` contained-toolchain pass: added `_local_riscv_cc()` and `_compile_payload_local()` so the remote `test --ai-island` path can compile the smoke payload locally when the remote has no compiler (or `--local-riscv` is set) and rsync the `.elf` to the remote builder. This lets the contained xPack toolchain on Windows feed payload builds to a Linux remote QEMU. | `python tools/g6q.py check` green. |
| 2026-08-30 | `--fw-fdt auto` pass: implemented `--fw-fdt auto` in `g6lc-qemu fw build`. It resolves the target model, applies the same DDT overlays/mutations used by `--emit dtb`, writes `out/fw/fdt_auto.dtb` (or the `--fw-out` directory), and sets `FW_FDT_PATH` for the OpenSBI make command. Refactored `emit_device_tree` to share `resolved_dts_blob()` with the new firmware path. Added `fw_build_fw_fdt_auto_sets_fw_fdt_path` unit test. Updated `g6q.py build-fw` to accept `--target`, `--repo-root`, `--dts`, `--dts-overlay`, `--dts-set`, `--dts-del`, `--fw-payload`, and `--fw-jump-addr` and forward them. Updated `g6q.py run -- --build-fw` extraction to pass those options through. Updated `architecture/CLI.md` to remove the 'not-yet-implemented' note and describe `auto` as generated from the resolved model. | `python tools/g6q.py check` green. |
| 2026-08-30 | Windows `fw build` WSL pass: fixed native `g6lc-qemu fw build` on Windows by automatically using WSL when a PIE-capable RISC-V toolchain is installed in WSL. `fw build` now detects `wsl` on PATH, prefers `riscv64-linux-gnu-` (or other WSL toolchains) over the contained Windows xPack, translates source/FW_FDT/FW_PAYLOAD paths to WSL absolute paths, and invokes `wsl make -C ...`. The contained `xpack-riscv-none-elf-gcc` is still used for local payload compilation via `g6q_remote.py`. `g6q.py doctor` now reports `wsl` availability and the WSL toolchain used for OpenSBI. Updated `architecture/CLI.md` to document the Windows/WSL behavior. | `python tools/g6q.py check` green; native `g6q.py build-fw --fw-fdt auto ...` succeeds and stages `fw_dynamic.bin`/`fw_dynamic.elf` on Windows via WSL. |
| 2026-08-30 | `setup-host` cross-platform auto-tooling pass: added `python tools/g6q.py setup-host` to install missing host tools using the detected package manager (Windows/WSL `apt`, Linux `apt/dnf/pacman/apk`, macOS `brew`). Supports `--toolchain`, `--qemu`, `--dtc`, `--spike`, and `--all` with `--dry-run` and `--force`. The command probes native and WSL executables, installs `gcc-riscv64-linux-gnu`/`qemu-system-misc`/`device-tree-compiler` inside WSL on Windows, and updates `g6q.py doctor` to report WSL-resolved tools and point at `setup-host` for missing items. `architecture/CLI.md` documents the new command. | `python tools/g6q.py check` green; `g6q.py setup-host --all --dry-run` and `g6q.py doctor` verified on Windows/WSL. |
| 2026-08-30 | `AGENTS.md` comprehensive update pass: updated the package guider to reflect Q2 state. Added sections 8-11 covering current development state, host tooling and cross-platform setup (`setup-host`), firmware/QEMU build flow (`--fw-fdt auto`, WSL path translation), and navigating the CLI/architecture. Updated daily commands and `setup`/`setup-riscv`/`setup-host`/`doctor` descriptions. Fixed the `Non-goals` section to re-include the ISA-definition bullet. The guider now maps `g6q.py` commands to Rust verbs/crates/design docs and documents the independence gate. | `python tools/g6q.py check` green. |
| 2026-08-30 | Standalone host-tooling pass: created `platform-constants.toml` as the single source of truth for external download URLs and platform-specific host-tool constants (rustup, xPack RISC-V, Bootlin toolchain, QEMU Windows installer, dtc source). Moved rustup/xPack URLs out of `tools/g6q.py` and added `tools/tomlmini.py` plus `tools/platform_constants.py` to load the file. `g6q.py setup-host` now falls back to standalone binary downloads (Bootlin `riscv64-lp64d--glibc` on Linux, QEMU Windows installer) and build-from-source (dtc) when no package manager is detected, with a `--standalone` flag to prefer them. `env_common.py` adds standalone tool `bin/` directories to `apply_env()` PATH so `doctor` and `setup-host` can discover them. Updated `AGENTS.md` and `architecture/CLI.md` to document the new file and fallback behaviour. | `python tools/g6q.py check` green; `g6q.py doctor`, `setup-host --all --dry-run`, `setup-host --qemu --standalone --force --dry-run`, and `setup-riscv --dry-run` verified. |
| 2026-08-30 | Remote utility tooling pass: updated `tools/g6q_remote.py` to use `platform-constants.toml` for the pinned xPack RISC-V toolchain `ref` instead of a hard-coded path. Added `_xpack_remote_bin_dir()` helper and replaced the hard-coded `_TOOLCHAIN_PATH` constant in plugin/payload build commands. `_local_riscv_cc()` now searches the `apply_env()` PATH so standalone host tools are discoverable. `doctor` probes remote `riscv-none-elf-gcc`, `riscv64-unknown-elf-gcc`, `riscv64-none-elf-gcc`, and `riscv64-linux-gnu-gcc`. Updated `AGENTS.md` directory-map note for `g6q_remote.py`. | `python tools/g6q.py check` green; `python tools/g6q_remote.py doctor --dry-run` and `python tools/g6q_remote.py --help` verified. |
| 2026-08-30 | MSVC source-build pass: added `tools/msvc_env.py` to detect and import the Microsoft Visual C++ build environment, mirroring `build-platform/build.ps1` so native Windows source builds can find `cl.exe`. `tools/g6q.py _install_from_source` now supports `build_env = "msvc"` and multi-step `build_steps` lists. Added a Windows x64 `build_from_source` entry for `dtc` in `platform-constants.toml` that uses `meson` + MSVC. Updated `tools/tomlmini.py` to parse multi-line TOML arrays. Updated `AGENTS.md` and `architecture/CLI.md` to document the Windows dtc source-build fallback. | `python tools/g6q.py check` green; `g6q.py setup-host --dtc --standalone --force --dry-run` and `g6q.py doctor` verified. |
| 2026-08-30 | Build-tools auto-setup pass: extended `setup-host` with `--build-tools [TOOL...]` to install `make`, `meson`, `ninja`, `cmake`, `bison`, and `flex`. Added a contained `.tools/python-venv` that is created on demand and used to `pip install meson`, `ninja`, and `cmake` when no package manager is available. Build-from-source fallbacks now declare `requires` lists in `platform-constants.toml`, and `g6q.py _install_from_source` calls `_ensure_build_tools()` to install missing build tools before building (`dtc` Linux requires `make/bison/flex`; `dtc` Windows requires `meson/ninja/bison/flex`). `env_common.apply_env()` now prepends the venv `bin/`/`Scripts` directory to `PATH` so venv-installed tools are discoverable. Updated `architecture/CLI.md` and `AGENTS.md` to document the new flag and fallback behaviour. | `python tools/g6q.py check` green; `setup-host --build-tools --dry-run` and `setup-host --dtc --standalone --force --dry-run` verified. |
| 2026-08-30 | Remote handler documentation pass: updated `AGENTS.md` to document `tools/g6q_remote.py` as a remote QEMU build/test proxy. Added a `### Remote build/test` subsection under §10 with the command list and `remote-build` / `doctor` examples. Added `python tools/g6q_remote.py remote-build` to the daily commands. Updated the command-to-crate map so `fetch-qemu`/`build-qemu` references `g6q_remote.py` for remote builds and `remote-build` maps to `tools/g6q_remote.py`. The existing `g6q_remote.py` implementation already uses `platform-constants.toml` for the pinned xPack toolchain `ref`. | `python tools/g6q.py check` green. |
| 2026-08-30 | Chocolatey + dnf package manager pass: added `choco` detection to `_detect_package_manager()` so native Windows hosts use Chocolatey before falling back to WSL `apt-get`. Added Chocolatey package lists to `_HOST_TOOLS` (`qemu`, `dtc-msys2`) and `_BUILD_TOOLS` (`make`, `meson`, `ninja`, `cmake`, and `winflexbison3` for both `bison` and `flex`). Implemented `_install_packages()` for `choco install -y --no-progress`. After installing `winflexbison3`, `_setup_winflexbison_shims()` copies `win_bison.exe`/`win_flex.exe` into `.tools/win-flex-bison/bin` and renames them to `bison.exe`/`flex.exe` so `dtc`'s `meson` build finds the standard program names. dnf remains the second Linux package manager after apt, supporting Fedora/Red Hat. Updated `AGENTS.md` and `architecture/CLI.md` to document Chocolatey as the preferred native Windows package manager and the winflexbison3 shim behavior. | `python tools/g6q.py check` green; `setup-host --build-tools bison --force --dry-run` and `setup-host --dtc --standalone --force --dry-run` verified with `choco` selected. |
| 2026-08-30 | Smart Windows setup preflight pass: `setup-host` now detects missing native-Windows prerequisites (Chocolatey, WSL, MSVC) and either prompts the user with a numbered menu or, with `--yes`, auto-installs them. Added `--yes` (`-y`) and `--vs-year {2022,2025,2026}` options to `setup-host`. New helpers in `tools/g6q.py`: `_is_admin()`, `_install_choco()` (downloads and runs the official Chocolatey install script), `_install_msvc_via_choco(year)` (installs `visualstudio{year}buildtools` and `visualstudio{year}-workload-vctools`), `_print_wsl_instructions()`, `_windows_source_build_selected()`, and `_smart_windows_preflight()`. The preflight recurses after installing choco/MSVC so the state is re-evaluated. WSL still requires manual install; the tool prints `wsl --install -d Ubuntu` and exits gracefully. Updated `architecture/CLI.md` and `AGENTS.md` to document the `--yes`, `--vs-year`, and smart preflight behavior. | `python tools/g6q.py check` green; `setup-host --dtc --standalone --dry-run`, `setup-host --dtc --standalone --force --dry-run`, and `setup-host --build-tools --dry-run` verified. |
| 2026-08-30 | Build-platform gateway pass: added `build-platform/src/cli/commands/g6q.ts` to register a top-level `g6q` command in the build-platform CLI that forwards to `g6lc_qemu/tools/g6q.py`. The `--remote` flag switches the target to `g6lc_qemu/tools/g6q_remote.py` so `bun build-platform/src/cli/index.ts g6q --remote remote-build` (or `doctor`, etc.) works from the monorepo root. Registered the command in `build-platform/src/cli/registry.ts`. Updated host documentation: `build-platform/AGENTS.md` §4.2 uses the new command as a pass-through example; `AGENTS-build-platform.md` §2.4 catalogs `g6q`; `AGENTS-build.md` quick-facts list includes `g6q`; `AGENTS.md` root directory map links the emulation concern to the build-platform gateway; package `AGENTS.md` §5 notes the canonical host adapter. | `bun build-platform/src/cli/index.ts g6q doctor`, `g6q setup-host --build-tools --dry-run`, and `g6q --remote doctor --dry-run` verified. `python tools/g6q.py check` green. |
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

### OpenSBI boot on generated B1 `g6lc-g6lc64_smt2` — root-caused and green

The OpenSBI hang on the generated B1 machine was **not** a QEMU, FDT, CPU-property
or argv defect. It was a defect in the *host project's* OpenSBI fork.

- Symptom: `-M g6lc-g6lc64_smt2 -bios <smt2 fw_payload.bin>` produced no serial
  output and spun in `wfi`. `-d in_asm,exec,int` showed
  `riscv_cpu_do_interrupt: cause:5 epc:0x8000f2d4 tval:0x18 desc=fault_load` inside
  `sbi_malloc`, then `_start_hang` (`0x800003c8: wfi; j -4`).
- Root cause: the monorepo patched OpenSBI's `platform/generic/platform.c` with an
  FDT rewriter that called `sbi_malloc()` from `fw_platform_init()`
  (`fw_base.S:115`) — ~250 instructions **before** `sbi_init()` → `sbi_heap_init()`
  (`fw_base.S:367`). `hpctrl` was still zeroed BSS, so `sbi_list_for_each_entry`
  walked from `NULL` and loaded `n->size` at `NULL+0x18`. `tval=0x18` matches exactly.
  The rewriter also allocated *unconditionally*, before checking whether the token
  it wanted to strip was even present — and it never was.
- Fix (host project, outside this package): the runtime rewriter is retired;
  enforcement moved to DTB build time in `software/smt2-linux/scripts/dts_to_dtb.py`.
  Firmware is stock again.
- Result on this package's generated machine, unchanged apart from a rebuilt firmware:

  ```
  OpenSBI v1.5
  Platform Name             : eth,ariane-smt2
  Platform HART Count       : 2
  Platform IPI Device       : aclint-mswi
  Platform Timer Device     : aclint-mtimer @ 32768Hz
  Platform Console Device   : uart8250
  Domain0 HARTs             : 0*,1*
  ...
  SMT2-OSBI: boot hart
  SMT2-OSBI: peer up
  SMT2-OSBI-OK
  ```

  So the B1 machine, generated CPU, generated FDT, ACLINT SWI/MTIMER split, PLIC and
  `serial-mm regshift=2` were all correct the whole time.
- **Package-side defect found and fixed:** `run --backend qemu` resolved
  `qemu-system-riscv64` from `PATH`, which finds a distro QEMU with no `g6lc-*`
  machine, so the default invocation died with `unsupported machine type` even
  though the generated machine was fine. `qemu_binary()` in `g6q-cli/src/main.rs`
  now prefers an in-tree `qemu/build/qemu-system-riscv64` (either suffix; the
  Windows in-tree build is a WSL ELF with no `.exe`) and falls back to `PATH`.
  `--qemu-path` still wins, and `--verbose` prints the binary chosen. Two tests pin
  both branches; `architecture/CLI.md` §6 updated.
- **Repeatable one-command gate** for this path, no `--qemu-path` needed:

  ```
  g6lc-qemu run --repo-root <design> --target g6lc64_smt2 --backend qemu \
                --timeout 20 --expect SMT2-OSBI-OK
  ```

  Firmware resolves through `CVA6_LINUX_PAYLOAD` / `G6LC_QEMU_FW` (`resolve.rs`) or
  `out/fw/`. Verified: `qemu binary: qemu/build/qemu-system-riscv64`, banner, and
  `SMT2-OSBI-OK` seen, `--expect` satisfied.
- Residual conform item, **already surfaced correctly — do not special-case it**:
  the generated B1 FDT derives `zawrs` from `ZawrsEn=1` and advertises it, while the
  host project's handwritten `ariane-smt2.dts` omits it pending the SMT wait-for-peer
  item. `conform --target g6lc64_smt2` reports capability `wait-on-reservation` as
  `undeclared` (live in config, silent in DTS), which is exactly the intended signal;
  `napot-pages` (`svnapot`) is the same shape. That is the checker doing its job, not
  a bug to patch in an emitter.

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

### Q4 continuation - B1 default for `run --backend qemu`

- `g6q-cli` `run --backend qemu` now targets the generated B1 machine (`g6lc-<target>`) by default. `--stock-machine` and `--stock-cpu` are still accepted to force the B0 stock-QEMU driver (`-M virt -cpu rv64...`).
- `g6q-emit-args/src/invoke.rs` `build_argv` omits the `-cpu` argument when `StockTarget.cpu_base` is empty, so a generated machine that brings its own CPU type does not receive a conflicting stock `-cpu` line.
- `architecture/CLI.md` updated: the execution table notes that `--backend qemu` targets the generated B1 machine and that `--stock-machine`/`--stock-cpu` select B0; the examples show the new default and an explicit stock override.
- `python tools/g6q.py check` green; `g6q run --backend qemu --dry-run` shows `-M g6lc-unnamed -smp 1 -m 128M ...` with no `-cpu`; `g6q run --backend args` still prints the B0 stock argv (`-M virt -cpu rv64 ...`).

### Q4 continuation — B1 custom AI instruction build integration

- `g6q-emit-qemu/src/trans.rs` now emits:
  - `target/riscv/g6lc-<target>-ai-helpers.h` (unguarded `DEF_HELPER_*` fragment for QEMU `helper-proto`/`helper-gen`/`helper-info` expansion),
  - `target/riscv/g6lc-<target>-ai-helpers.c` (stub implementations),
  - `target/riscv/insn_trans/trans_g6lc_<target>_ai.c.inc` (translation fragment for `ai.enq`/`ai.qfence`/`ai.poll`),
  - `target/riscv/g6lc-<target>-ai.decode` (decodetree source driven by `AiInstrSet`).
- `g6q-emit-qemu/src/build.rs` build wiring adds the helper source and the `decodetree.process()` custom decoder to `target/riscv/meson.build`.
- `tools/g6q.py` `install-qemu` now:
  - copies generated sources recursively (so `insn_trans/` is staged),
  - appends `#include "target/riscv/g6lc-<target>-ai-helpers.h"` to `target/riscv/helper.h`,
  - inserts the decode and translation includes into `target/riscv/translate.c`,
  - appends the `decoder_table[]` entry `{ always_true_p, decode_g6lc_<target>_ai },`.
- The generated decoder reuses `!extern &r` from `target/riscv/insn32.decode` to avoid decodetree fixed-bit overlap and `bits left unspecified` errors.
- `python tools/g6q.py check` green; `python tools/g6q.py install-qemu --package fixtures\ai --target ai` followed by `python tools/g6q.py build-qemu` produced a linked `qemu-system-riscv64`. A WSL smoke run of `./qemu/build/qemu-system-riscv64 -M ?` shows `g6lc-ai` and `-M g6lc-ai -cpu ?` shows `g6lc-ai`; `-M g6lc-ai -cpu g6lc-ai -nographic -bios none` starts and runs (no firmware loaded).
- The generated helpers are still stubs that return `0`/no-op; functional queue semantics and an AI-island sysbus device are the next open item.

### B1 functional AI-island sysbus device and helpers pass

- `g6q-emit-qemu/src/ai_island.rs` (new module) emits `hw/riscv/g6lc-<target>-ai-island.{h,c}` from the ingested `AiIslandModel`.
- The generated device owns per-queue `G6lcAIQueueEntry` arrays, allocates sequential tickets, reads `ptr_done` from the descriptor image using the ingested `desc_layout.ptr_done` offset, writes 64-bit completion words with `G6LC_AI_COMPLETION(ticket, status)`, and exposes a `cap_base` MMIO capability window with version/clusters/macs-per-cycle.
- `g6q-emit-qemu/src/trans.rs` `emit_helpers_c` now emits functional helpers that call `g6lc_ai_island_enq/qfence/poll` on the global island instance, and `emit` wires the new `ai_island` emitter.
- `g6q-emit-qemu/src/machine.rs` maps `ai-island` peripherals to `g6lc_ai_island_create(...)` instead of `unimplemented-device`, passing `cap_base` and `desc_base` from the model.
- `g6q-emit-qemu/src/build.rs` adds `g6lc-<target>-ai-island.c` to the `hw/riscv/meson.build` build-wiring fragment.
- `tools/g6q.py` `install-qemu` copies the new device files and `_patch_hw_riscv_meson_build` appends the device to `hw/riscv/meson.build` when present.
- Removed stale hand-maintained `qemu/hw/riscv/g6lc-ai-island.{c,h}` and the duplicate meson block; the package-generated `g6lc-ai-ai-island.{c,h}` is now the sole source.
- The in-guest payload `tools/remote/payload/ai_island_queue_smoke.S` was reassembled with the model-derived `match_*` encodings (`0x0000505B`, `0x0200505B`, `0x0400505B`) and a 0x80020000 descriptor.
- `python tools/g6q.py check` green; `python tools/g6q.py install-qemu --package fixtures\ai --target ai` and `python tools/g6q.py build-qemu` produced a linked `qemu-system-riscv64`.
- A WSL smoke run of `./qemu/build/qemu-system-riscv64 -M g6lc-ai -cpu g6lc-ai -m 128M -nographic -bios none -kernel tools/remote/payload/ai_island_queue_smoke.elf` prints `AI_OK`, confirming `ai.enq` returns a ticket, `ai.qfence` drains the queue and writes the completion word, and `ai.poll` returns the completion.
- `architecture/EMIT.md` §B1 updated to document the new device and helper emission.

### B1 hardening — package-only build wiring and generated C formatting

- `tools/g6q.py` `_patch_target_meson_build` now appends `cpu_g6lc_<target>.c` together with `g6lc-<target>-ai-helpers.c` and the `decodetree` decode rule to `target/riscv/meson.build`, removing the need for a manual second meson line.
- `g6q-emit-qemu/src/trans.rs` and `g6q-emit-qemu/src/ai_island.rs` switched from `\n\` string continuations to raw-string `r###"..."###` format literals so the emitted C keeps its indentation (no more column-zero `return`/`if` in generated helpers and device).
- Re-ran `python tools/g6q.py install-qemu --package fixtures\ai --target ai` after `git checkout --` the patched QEMU build files; the generated `qemu/` tree is now entirely package-originated and has no duplicate meson blocks.
- `python tools/g6q.py build-qemu` and the in-guest `AI_OK` smoke still pass; `python tools/g6q.py check` is green.
- No git commit was made.

### Q4 continuation — g6lc-qemu run child SIGTERM + dry-run toolchain fallback

- `g6q-cli` `run` now terminates the QEMU child with `SIGTERM` and waits up to
  two seconds before falling back to `SIGKILL`. This lets B2 plugins and trace
  recorders run their `qemu_plugin_atexit_cb` callbacks when `--expect` or
  `--timeout` ends the run early.
- `g6q-cli` `fw build --dry-run` no longer requires a real RISC-V cross-toolchain
  on the host; validation of `--fw-make`, `--fw-mode`, and `--fw-payload` runs
  first so malformed inputs are rejected before the toolchain is even probed.
- `python tools/g6q.py check` is green.
- B1/B2 runtime smoke:
  - `g6q run --backend qemu --plugin qemu/build/contrib/plugins/libg6lc-g6lc64_smt2-pmu.so,out=out/smt2-pmu.json --timeout 10 --expect SMT2-OSBI-OK`
    succeeds and writes a non-empty `smt2-pmu.json` PMU counter artifact.
  - The generated B1 `g6lc-g6lc64_smt2` machine boots stock OpenSBI to
    `SMT2-OSBI-OK` with the B2 PMU plugin loaded.
- Soft-ladder S4 cross-check (monorepo):
  - The `mini_fdt_nt_ptr0` failure on `work-ver-smt2-fw64-B` was an
    **instruction-access fault (IAF)**, not a fetch_B/IQ leftover bug.
  - The FDT stub at `0x8001E030` is outside the `g6lc64_smt2` execute region
    (`0x80000000` length `0x1e000` ends at `0x8001DFFF`). The `c.jr a0` target
    `a0 = 0x8001E030` is architecturally correct; the I-cache returns the MMU/PMA
    exception, and the trap handler reports `mepc` low 32b = `0x1E030`
    (`tohost = 122928`).
  - Moving `.text.fdt` to `0x8001D000` in `verif/tests/custom/multicore/mini_fdt_nt_ptr0.{S,ld}`
    makes `mini_fdt_nt_ptr0` **PASS** (`tohost = 0` after ~492 cy) on
    `work-ver-smt2-fw64-B` and in the remote `di` suite. No RTL change.
  - The historic OpenSBI `mepc=0` / `sbi_hart_hang` S4 residual remains a
    separate issue if `fdt_next_tag` control flow reaches a non-execute address.

### Q7/Q8 continuation — g6lc-qemu run + diag + MTTCG smoke

- `g6q run --backend qemu --repo-root /mnt/e/cva6 --target g6lc64_smt2
  --timeout 15 --expect SMT2-OSBI-OK` boots the generated B1 machine to
  `SMT2-OSBI-OK` (using `G6LC_QEMU_FW=/mnt/e/cva6/build-platform/workspace/smt2-linux/fw_payload.bin`).
- `--tcg-tuning tuned` and `--icount 1` both reach the same boot gate, confirming
  the Q8 MTTCG / deterministic-time option plumbing in `resolve.rs`.
- `g6q diag --repo-root /mnt/e/cva6 --target g6lc64_smt2 --uarch-out out/uarch.json`
  writes a model-derived D2 counter artifact (roofline / structure counters).
- `g6q run --backend qemu --record out/smt2-trace.json --timeout 45
  --expect SMT2-OSBI-OK` now reaches `SMT2-OSBI-OK` and writes a 1.5 GB
  `out/smt2-trace.json` RecordFile (Q5/D1).
  - Fixed the B2 trace plugin to batch records per hart (64 Ki record buffers,
    `GString` formatted flushes) and to use a `GMutex` around the file write and
    the first-record comma state, making it safe under MTTCG and avoiding the
    original `fprintf`+`fflush` per-instruction overhead.
  - The previous `g_ptr_array_add: assertion 'rarray' failed` crash was caused by
    `g6lc_tb_trans` running before `qemu_plugin_install` had published
    `g6lc_trace_insns`; added a lazy-init guard and moved the initialization
    check into `qemu_plugin_install`.
  - `python tools/g6q.py check` remains green (112 workspace tests pass).
- `python tools/g6q.py check` remains green.

### Q3/Q5/Q7 continuation — native run, record/replay, PMU

- Built a 28-byte bare-metal `smoke.bin` (UART `OK\n` loop at 0x80000000) and ran it under `g6q run --backend native --image /tmp/smoke.bin --target g6lc64_smt2 --repo-root /mnt/e/cva6`.
- Native VM prints the expected `OK\n` stream and stops at the step limit; `--record out/native-smoke.json --steps 50` writes a valid RecordFile; `--replay out/native-smoke.json` reproduces the same stream with no divergence.
- `g6q run --backend qemu --plugin qemu/build/contrib/plugins/libg6lc-g6lc64_smt2-pmu.so,out=out/smt2-pmu.json --timeout 15 --expect SMT2-OSBI-OK` reaches the OpenSBI boot gate and writes a 6.8 KB `out/smt2-pmu.json` D2 counter artifact with `counter_count:6` and per-hart cycle/instruction/event entries.
- These confirm B3 native D1 record/replay and B2 QEMU PMU emission are usable end-to-end; `python tools/g6q.py check` remains green (112 workspace tests pass).
- Caveat: `run --backend native` currently runs a single hart and does not model SMT2 hart 1 peer bring-up, so it cannot run the same OpenSBI payload used with B1/B2.

### SMT2 soft-ladder OpenSBI cookie soak

- `smt2-ai-tensor-track.sh fast` passed 21/22 gates; the only failure is `g6lc64_smt2 lint` because local Verilator is missing (expected).
- `verif/regress/soft-ladder-opensbi-soak.sh` with `SOFT_LADDER_HARNESS=work-ver-smt2-slfix` and the pinned `fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf` reaches `CLASSIFY=SUCCESS fetch=B cookie 51b1babe` at `t=83968` cycles.
- The default `work-ver-smt2-fw64-B` harness did not reach the cookie within the 12 M cycle / 1800 s wall timeout (process killed after ~17 minutes with no `51b1babe` output), while `work-ver-smt2-slfix` completes in under a minute. This is a harness/frontend divergence, not a g6lc_qemu issue; documented here for the RTL SMT2 track.
- `smt2-ai-tensor-track.sh peel` (PEEL_FDT_GETPROP=1, pin ELF, 2 M cycle timeout) passes 21/0 and reaches `51b1babe` at `t=83968` on `work-ver-smt2-slfix`.
- `smt2-ai-tensor-track.sh hold` (held oracle, 3 M cycle timeout) passes 21/0 and reaches the same cookie at the same cycle count on `work-ver-smt2-slfix`.
- `smt2-ai-tensor-track.sh dual` (DUAL_HART_LIVE=0) passes all artifact/preflight checks; the only failure is `g6lc64_smt2 lint` (no local Verilator).
- `dual-hart-ci.sh` with `DUAL_HART_LIVE=1 DUAL_HART_HARNESS=work-ver-smt2-slfix/Variane_testharness` passes live `smt_dual_park`, `smt_peer_tohost`, `smt_dual_active`, `smt_dual_concurrent`, and `smt_dual_wfi_timer` on the `slfix` harness; only `g6lc64_smt2 lint` fails due to missing Verilator.
- `smt2-ai-tensor-track.sh tensor` passes 21/0: `run-ai-tensor.sh pytorch` runs the Device virt-card cases (PyTorch not installed) and reports OK.
- `smt2-ai-tensor-track.sh mt-soft` passes 21/0: sequential dual invoke passes.
- `smt2-ai-tensor-track.sh di` passes 6/7 mini FDT tests on `work-ver-smt2-slfix`; `mini_fdt_next_tag_lbu` reports `*** FAILED *** (tohost = 1)`, which is the known `corev_apu/tb/g6lc_tb.cpp` Verilator/HTIF `exit_code` convention printing "FAILED" for `tohost=1` even though `tohost=1` is the pass value.
- `smt2-ai-tensor-track.sh hard` passes 21/0: `tensor virt-impl --impl hard --suite narrow --core g6lc64_ai` runs the soft PyTorch/Device phase and the hard Verilator RTL phase on `work-ver-ai/Variane_testharness`; both `ai_island_mmio_smoke` and `ai_gemm_s8_smoke` PASS (`tohost = 0`).
- Summary of the `smt2-ai-tensor-track` staged track: `peel`, `hold`, `tensor`, `mt-soft`, and `hard` all pass 21/0; `dual` and `di` fail only on the missing local Verilator lint and the known `tohost=1` testbench convention, respectively.
- Investigated the `work-ver-smt2-fw64-B` OpenSBI soak failure: the passing `work-ver-smt2-slfix` harness is built with the legacy `core/Flist.cva6` (A fetch), while `work-ver-smt2-fw64-B` is built with `core/Flist.fetch_B` (B fetch). The same pin ELF and same 12 M cycle timeout produce a cookie on `slfix` and no cookie on `fw64-B`, confirming a fetch_B (L1-L4) divergence. The older `work-ver-smt2` harness is stale and prints the plusarg help instead of running; it is not a usable comparison point.
- Fixed the `dtc` `simple_bus_reg`/`unit_address_vs_reg` warnings on `corev_apu/bootrom/ariane-smt2.dts` by adding `reg = <0x0 0x0 0x0 0x0>;` and a `@0` unit address to the `/soc/smt-product-closeout` documentation node. `smt-linux-boot-path.sh` now passes with no dtc warnings.
- Resolved the `mini_fdt_nt_ptr0` S4 residual: the `tohost = 122928` (`0x1E030`) failure was an IAF because the FDT stub at `0x8001E030` is outside the `g6lc64_smt2` execute region. Moving `.text.fdt` to `0x8001D000` in `verif/tests/custom/multicore/mini_fdt_nt_ptr0.{S,ld}` makes the directed mini PASS on `work-ver-smt2-fw64-B` and in the remote `di` suite.
- The fetch_B target `0x8001E030` was never corrupt; `+fetch_snap` and an I-cache diagnostic display confirmed the `c.jr a0` redirect delivers the correct target and the I-cache returns an exception (not zero data from a fetch bug). The `btb` `predict_address = 0x80000000` seen before the redirect is the predicted fall-through path after the mispredict is killed, not a corrupt pointer.
- The historic OpenSBI `mepc=0` / `sbi_hart_hang` S4 class is a separate residual: it occurs when `fdt_next_tag` / `fdt_offset_ptr` control flow reaches a non-execute address (or when the trap-redirect path itself lands at PC 0). It is not addressed by the `mini_fdt_nt_ptr0` test-address fix.

### U0/E0 loader build scaffolding (this pass)

- Added `[u_boot]`, `[edk2]`, and `[edk2_platforms]` pins to `g6lc_qemu/pins.toml` with pinned upstream URLs and refs (U-Boot `v2025.07`, EDK2 `edk2-stable202511`, EDK2 platforms `master`). Status is `planned`.
- Added `g6lc_qemu/crates/g6q-cli/src/loader.rs` — a build-only scaffolding module that clones pinned source, generates a target-specific board package from `TargetModel`, writes a build script, and attempts the build only when the host has the prerequisites.
- Extended `g6lc-qemu fw` to dispatch `--loader u-boot|edk2` for both `fw fetch` and `fw build`; OpenSBI remains the default when `--loader` is absent or `opensbi`.
- Extended `python tools/g6q.py fetch-fw` and `build-fw` to accept `--loader`, `--loader-src`, `--loader-out`, and `--machine` and forward them to the Rust CLI.
- Generated U-Board board package includes: defconfig fragment, config-fragment, board header, FIT `.its` skeleton, `u-boot-build.sh`, and README. It uses the upstream `qemu-riscv64_smode_defconfig` as a base and overrides `CONFIG_SYS_TEXT_BASE`, `CONFIG_SYS_LOAD_ADDR`, and DRAM values from the model.
- Generated EDK2 board package (E1 wrap): `G6lcPlatformPkg.h`, `G6lcPcds.dsc.inc`, `edk2-build.sh`, README. The script builds upstream `OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc` (PEI-less S-mode payload). edk2-platforms is not required for `g6lc-virt`. xpack `ld` `-z notext` is dropped in generated `Conf/tools_def.txt` only.
- Validation green: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`, `python tools/check_independence.py`, `python tools/g6q.py check`, and the two loader dry-runs all pass in this pass.
- Added `--edk2-platforms-src` to `python tools/g6q.py fetch-fw` and `build-fw` so EDK2 `edk2-platforms` can be fetched to a non-default path.
- Build-platform integration: added `u-boot-build` and `edk2-build` regression suites (`build-platform/src/config/defaults.ts`) plus `u-boot-src` and `edk2-src` install recipes (`build-platform/src/tooling/recipes.ts`, `installProfiles.ts`, `cli/commands/tools.ts`); recipes delegate to `g6lc_qemu/tools/g6q.py fetch-fw` and clone into `build-platform/workspace/tooling/loader-src/`.
- Build-platform `bunx tsc --noEmit` and the `bun test` suite pass except for the pre-existing `branding-g6lc.test.ts` failure.
- Runtime stages: SL-W gate-6 `mini_stq_flush_fwd` **PASS** on `work-ver-smt2-fw64-B-slwfix` (`slw-gate6-noprop`, oracle green, no sim probes). E1 RTL SEC-ABI `mini_edk2_sec` **PASS**. E2 QEMU virt **green** (UEFI Shell). I6 FIFO data-order is proven (`cva6_fifo_v3_order.sby` 12/12 remote).
- E1 remote (ovh_calltorch, 2026-09-01): cloned `edk2-stable202511` to `/opt/testharness/cache/edk2-src`. BaseTools OK. Built ACPICA `iasl` 20260408 into `$HOME/.local/bin` (no sudo). Dropped `-z notext` in generated `Conf/tools_def.txt`. **`build -a RISCV64 -t GCC5 -p OvmfPkg/RiscVVirt/RiscVVirtQemu.dsc -b RELEASE` PASS** — `RISCV_VIRT_CODE.fd` (8 MiB) and `RISCV_VIRT_VARS.fd` (768 KiB) under `Build/RiscVVirtQemu/RELEASE_GCC5/FV/`. QEMU wants 32 MiB pflash (`truncate -s 32M`) at `g6q run` time.
- E1 Verilator isolation (2026-09-01): post-sync B with SL-W `wbuffer_all` (raw depth 11 + signed `%` into `fixup_q`) SIGSEGV'd `mini_must_pass` (rc=139, t=275, `id-dbg` truncated). HEAD dcache `work-ver-smt2-fw64-B-headiso` oracle green, `mini_edk2_sec` PASS, `mini_stq_flush_fwd` FAIL. IQ width casts were in both binaries — not the crash. Crash-fix (unsigned fixup index + power-of-two `WbufferAllDepth`) in `work-ver-smt2-fw64-B-slwfix`: oracle green, **`mini_edk2_sec` PASS** (6.5 s), `mini_stq_flush_fwd` still FAIL (gate-6, retires; no SIGSEGV).
- E1 QEMU argv: `g6q run --backend args --loader edk2 --loader-image CODE.fd` emits `-M virt,pflash0=pflash0,pflash1=pflash1,acpi=off` plus CODE/VARS `-blockdev`. Pads FDs to 32 MiB; `apply_edk2_pflash` floors `-m` to 4 GiB (RiscVVirt README).
- E2 QEMU smoke: the silent v1.5 hang was a **g6lc-FDT** `fw_dynamic` (embedded `example,mini-board`). A `PLATFORM=generic` rebuild with no `FW_FDT_PATH` (`out/fw/fw_dynamic-generic-virt.bin`) prints the v1.5 banner and hands off to `0x20000000`. Real `RISCV_VIRT_{CODE,VARS}.fd` (8 MiB / 768 KiB, `_FVH` at 40) padded to 32 MiB. CpuDxe SATP **green** after `RiscVInterrupt.S` fix (`patches/edk2-riscv-sstatus-no-stack.patch`): `DisableInterrupts` smashed `s0` (`addi sp,-4`+`sd`). Smbios-era `INST_ACCESS_PAGE_FAULT` was the same preprocessor ABI: `GCC5_RISCV64_PP_FLAGS` omitted `-mabi=lp64`, so `SupervisorModeTrap` did `addi sp,sp,-140` against `UINT64[35]` (280). Patches: `patches/edk2-riscv-trap-frame-width.patch` (offset ×8) + PP_FLAGS `-march=rv64gc -mabi=lp64` in generated `edk2-build.sh`. Linked CpuDxe (DEBUG and RELEASE): `addi sp,sp,-280`. QEMU 8.2.2 virt DEBUG: `SATP mode 10`, Bds, **UEFI Interactive Shell v2.2**. RELEASE: `Shell>` prompt. Default FDs: `out/loader-run/src/` (RELEASE). `g6q run --backend qemu --loader edk2 --wsl --smp 1 --expect "UEFI Interactive Shell"` **green** on in-tree QEMU 10.0.0 (`qemu/build/qemu-system-riscv64`). Distro 8.2 rejects g6q `-cpu ...,zacas=on`. `ProtectUefiImage` still warns 0x40 vs 0x1000 on DEBUG Shell.efi (non-fatal; DXEFV is 99% full so `-z common-page-size=0x1000` would overflow). `apply_edk2_pflash` prefers generic-virt OpenSBI.
- E2 virtio ESP: QEMU `fat:rw:out/loader-run/esp` with `EFI/BOOT/BOOTRISCV64.EFI` (RELEASE `Shell.efi`) + `startup.nsh` (`echo E2-VIRTIO-ESP` then launch that EFI). Shell mapping table shows `FS0:` / `HD0b:` / `BLK1:` (was `map: No mapping found` with no disk). `g6q run --backend qemu --loader edk2 --machine g6lc-virt --wsl --smp 1 --drive fat:rw:out/loader-run/esp --expect E2-VIRTIO-ESP` **green**. `--drive` requires `--machine g6lc-virt` (`check_profile` refuses disks on `g6lc-soc`).
- E3 OpenWrt Image: custom compile **PASS** on ovh_calltorch (`/opt/testharness/cache/openwrt`, pin **v24.10.2**, target `sifiveu/generic` + virt overlay). Kernel kconfig closed: `SOC_VIRT`/virtio/8250/EFI stub + `CMDLINE_BOOL`/`CMDLINE_EXTEND` + `GOLDFISH=y` / `GOLDFISH_TTY` not set; `apply-virt-overlay.sh` hooks `olddefconfig` into OpenWrt `Kernel/Configure`. linux compile ~109 s wall; world printed `OPENWRT_E3_BUILD_READY`. Product `openwrt-sifiveu-generic-sifive_unleashed-initramfs-kernel.bin` (gzip of PE32+ EFI stub, 8.2 MiB) pulled to `g6lc_qemu/out/loader-run/openwrt/`. **QEMU virt + EDK2 smoke green**: `EFI stub: Booting Linux Kernel` → `Linux version 6.6.93` (`riscv-virtio,qemu`, `efi: EFI v2.7 by EDK II`) → `virtio_blk` → `procd: - init -`. Overlay `g6lc_qemu/openwrt/{apply-virt-overlay.sh,build.sh,diffconfig,kernel-virt.config,push-overlay.py,pull-products.py,remote-olddef.sh,remote-status.sh,smoke-edk2.sh}`. Progress: `python3 verif/regress/remote/testharness_proxy.py --timeout 90 shell --no-hang --cmd-file g6lc_qemu/openwrt/remote-status.sh` (WSL). Pin in `g6lc_qemu/pins.toml` `[openwrt]` status `built`.
- E3 linux-dist / patchworks: compile uses **official** `github.com/openwrt/openwrt` @ v24.10.2 plus `g6lc_qemu/openwrt/patches/` (`apply-patches.sh`, seed 0001 olddefconfig hook + 0002 virt/ISA overlay from `g6lc64_smt2`). etcimon forks (`openwrt`, `openwrt-packages`, `openwrt-luci`, `openwrt-routing`, `openwrt-telephony`) live under `g6lc_qemu/linux-dist/openwrt-*` for development only; `extract-patches.sh` pulls `git format-patch` vs the official pin into `patches/from-fork/`. QEMU/testharness never build the forks. Ubuntu scaffold: `g6lc_qemu/linux-dist/ubuntu/` sharing `linux-dist/isa/`. Init: `linux-dist/init-submodules.sh`.
- E3 via `g6q run` **green**: `--loader edk2 --os openwrt` stages `out/loader-run/esp-openwrt/EFI/BOOT/BOOTRISCV64.EFI` from the OpenWrt PE (`initramfs-Image`) and drops `-kernel` so BDS loads the EFI stub. `g6q run --backend qemu --loader edk2 --os openwrt --machine g6lc-virt --smp 1 --timeout 90 --expect "Linux version 6.6" --target g6lc64_smt2` reached `EFI stub: Booting Linux Kernel` then `Linux version 6.6.93` (`efi: EFI v2.7 by EDK II`) and `--expect` SIGTERM'd QEMU.
- E3 dual-hart **green** (`--smp 2`, `g6lc64_smt2` NrHarts): OpenSBI `Platform HART Count : 2` / `HARTs 0*,1*`; Linux `nr_cpu_ids=2`, `plic ... 2 handlers for 4 contexts`, `smp: Bringing up secondary CPUs`, `smp: Brought up 1 node, 2 CPUs`. Userspace: `Run /init`, `init: Console is alive`, **`procd: - init -`**. Next: E4 RTL tandem (`--diag d1`; Variane cannot boot pflash — witness remains `mini_edk2_sec`).
- EDK2 patchworks: `g6q fw build --loader edk2` copies `patches/edk2-riscv-sstatus-no-stack.patch` and `edk2-riscv-trap-frame-width.patch` into the board package and the generated `edk2-build.sh` applies them to official tianocore/edk2 (CRLF-stripped, `--ignore-whitespace`). Scripts `g6lc_qemu/edk2/{apply,extract,check}-patches.sh` + `series`. **`check-patches.sh` green** against official `edk2-stable202511` (`CHECK_EDK2_PATCHES_OK`). Dev fork `github.com/etcimon/edk2` at `linux-dist/edk2`; compile never uses the fork. E4 full-FD RTL tandem is still impossible on Variane (no 32 MiB pflash); witness remains `mini_edk2_sec`.
- Verified dry-run commands:
  - `g6q fw build --loader u-boot --target g6lc64_smt2 --machine g6lc-virt --dry-run`
  - `g6q fw build --loader edk2 --target g6lc64_smt2 --machine g6lc-virt --dry-run`
  - `bun run src/cli/index.ts tools install u-boot-src --dry-run`
  - `bun run src/cli/index.ts tools install edk2-src --dry-run`
- U1 QEMU virt **green**: `g6q run --backend qemu --loader u-boot --machine g6lc-virt --smp 1 --timeout 30 --expect U-Boot --target g6lc64_smt2` — OpenSBI `Next Address 0x80200000` then **`U-Boot 2025.07-dirty`**, `CPU: riscv`, `Model: riscv-virtio,qemu`, `DRAM: 256 MiB`. Payload is `out/loader-build/u-boot-g6lc64_smt2-g6lc-virt/u-boot/u-boot.bin` (`qemu-riscv64_smode`).
- U2 QEMU virt **green**: `g6q run --backend qemu --loader u-boot --os openwrt --machine g6lc-virt --smp 1 --timeout 120 --expect "Linux version 6.6" --target g6lc64_smt2` — OpenSBI → **`U-Boot 2025.07-dirty`** (DRAM 1 GiB) → distro boot `virtio 0:1` → `bootefi` of `efi/boot/bootriscv64.efi` → **`EFI stub: Booting Linux Kernel`** → **`Linux version 6.6.93`** (`efi: EFI v2.11 by Das U-Boot`, `Machine model: riscv-virtio,qemu`). `--expect` SIGTERM'd QEMU. Staging: `apply_uboot_os_esp` writes MBR+FAT16 `out/loader-run/esp-uboot.img` from the same OpenWrt PE as E3 (`initramfs-Image`); QEMU `fat:rw:<dir>` has no partition table so U-Boot `part list` would miss it. `--kernel` is the OS image under `--os openwrt`; U-Boot itself is `--loader-image`.
- U2 dual-hart **green** (`--smp 2`, `g6lc64_smt2` NrHarts): OpenSBI `Platform HART Count : 2` / `HARTs 0*,1*`; Linux `nr_cpu_ids=2`, `CPUs=2`, `plic ... 2 handlers for 4 contexts`, `SBI HSM extension detected`, `smp: Bringing up secondary CPUs`, **`smp: Brought up 1 node, 2 CPUs`**. Userspace: `Run /init`, `init: Console is alive`, **`procd: - init -`**. Same command as U2 with `--smp 2 --expect "procd: - init -"`.
- U3a QEMU **green** on generated B1 `g6lc-g6lc64_smt2`: `g6q run --backend qemu --loader u-boot --machine g6lc-soc --smp 2 --timeout 30 --expect U-Boot --target g6lc64_smt2`. OpenSBI `Platform Name : GSys LibreCore g6lc64_smt2`, `HART Count : 2`, `Next Address 0x80200000`, then **`U-Boot 2025.07-dirty`**, `Model: GSys LibreCore g6lc64_smt2`, `DRAM: 256 MiB`. B1 emitter: reset stays at `-bios` (do not jump to `-kernel` from M-mode); `-kernel` loads at DRAM+2MiB. `--loader u-boot` without `g6lc-soc` still forces stock virt (U1/U2).
- U3b-dram QEMU **green**: `g6q run --loader u-boot --os openwrt --machine g6lc-soc --smp 2 --timeout 60 --expect "Linux version 6.6"`. No virtio. PE is `-device loader,file=initramfs-Image,addr=0x84000000,force-raw=on`. Soc U-Boot (`out/loader-build/u-boot-g6lc64_smt2-g6lc-soc/u-boot/u-boot.bin`) `bootefi 0x84000000:0x2000000` with FDT `bootargs earlycon=sbi`. **`EFI stub: Booting Linux Kernel`** → **`Linux version 6.6.93`**, **`Machine model: GSys LibreCore g6lc64_smt2`**, `efi: EFI v2.11 by Das U-Boot`. `bootefi <addr>` without `:size` fails (`No UEFI binary known`).
- U3b userspace **green** on generated `g6lc-soc` (`--smp 2 --timeout 120 --expect "procd: - init -"`): `smp: Brought up 1 node, 2 CPUs`, `plic ... 30 interrupts with 2 handlers for 4 contexts`, `Run /init`, `init: Console is alive`, **`procd: - init -`**. DRAM 256 MiB (`234396K/262144K available`). Timebase 32768 Hz (`sched_clock ... 33kHz`); failsafe wait is ~36 s wall.
- B1 FDT `cpu-map` **fixed** to Linux `cpus.yaml` / `ariane-smt2.dts` shape: SMT cores get `threadN { cpu = <&cpuM>; }` children (phandle of the **cpu node**, not the intc). Single-thread cores are leaves with `cpu = <&cpuM>`. Was emitting `threadN` **properties** on `core0`, so Linux logged `Can't get CPU for leaf core`. After re-emit + QEMU rebuild that warning is gone; `Brought up 1 node, 2 CPUs` still holds.
- B1 FDT CMO/cache **green**: `riscv,cbom-block-size` / `riscv,cboz-block-size` = 64 when those extensions are live; `i-cache-*` / `d-cache-*` from `IcacheByteSize`/`IcacheLineWidth` (bits/8) and D-cache counterparts; `tlb-split` when both TLB sizes are in the model. Linux no longer logs `Zicbom detected ... disabling as no cbom-block-size`.
- `g6q run --send-on MATCH=TEXT` writes to QEMU serial when `MATCH` appears (`\n` unescaped). `/proc/cpuinfo` from a shell is **not** claimed: OpenWrt `CMDLINE_EXTEND` appends `console=hvc0` after the FDT `bootargs`, and `g6lc-soc` has no virtio console, so no `Please press Enter` getty on UART.
- U3-FIT QEMU **green** on `g6lc-soc`: `mkimage` wraps the OpenWrt PE as `g6lc-efi.itb` (`type = kernel_noload`, `os = efi`). QEMU loads the FIT at `0x84000000`. Soc U-Boot **`bootm 0x84000000`**: `Loading kernel (any) from FIT Image at 84000000`, `Trying 'efi' kernel subimage`, `Transferring control to EFI (at address 840000d4)`, then **`Linux version 6.6.93`**. `bootm` of a raw PE fails (`Wrong Image Type`); BOOTCOMMAND then falls back to `bootefi addr:size`. Relative `mkimage` after `chdir` was the first miss (canonicalize the tool path). Not SD (no SDHCI). Next: SD/SPI, or E4 RTL tandem.
- U3-FIT `/proc/cpuinfo` **green** on generated `g6lc-soc` (`--smp 2 --expect CPUINFO-DONE`, 35 s): `processor : 0` / `hart : 0` and `processor : 1` / `hart : 1`, `mmu : sv39`. Path: newc `cpuinfo-init.cpio` as QEMU `-initrd` overlays `/init`, which prints via `/dev/kmsg` then `exec /sbin/init`. Opening `/dev/ttyS0` hangs (DCD). A FIT ramdisk via U-Boot EFI LoadFile2 is loaded then **disabled** (`INITRD ... overlaps in-use memory region`). B1 machine now `fdt_open_into`s the packed blob (slack) **before** `riscv_load_kernel` so `linux,initrd-*` sticks. OpenWrt `CMDLINE_EXTEND` still appends `console=hvc0`; no UART getty.
- U3-SPI **boot green** on generated `g6lc-soc`: no DRAM `-device loader`. Autoboot `sf probe` → **`SF: Detected n25q256a … 32 MiB`** / **`SPI-PROBE-DONE`** → `sf read 0x84000000 0 0x1800000` (**`SF: 25165824 bytes @ 0x0 Read: OK`** / **`SPI-READ-DONE`**) → `bootm` of that FIT → Linux 6.6.93 → **`CPUINFO-DONE`** (`processor : 0` and `: 1`). FIT lives only on `-drive if=mtd` (`spi-nor.img`).
- E2-PCI **green**: `g6q run --loader edk2 --os efi-shell --machine g6lc-virt --smp 1 --expect E2-PCI-ENUM`. FD Shell `startup.nsh` ran `pci`: **`00 00 00 00 ==> Bridge Device - Host/PCI bridge` Vendor 1B36 Device 0008** (QEMU GPEX).
- E2-PCI **function green**: same command with `--expect 1AF4`. Drives are `virtio-blk-pci` (not virtio-mmio). Shell `pci` lists **`00 00 01 00 ==> Mass Storage Controller - SCSI` Vendor 1AF4 Device 1001**. Mapping table is **`PciRoot(0x0)/Pci(0x1,0x0)`** (was `VenHw`). Stock virtio-blk, **not** an AI BAR. `virt_ai_card` smoke **PASS**. `ai_tensor_bridge.py pcie` still exits 1 (`contracts.ai_host_transport` **unpinned**).
- E2-PCI **BAR green**: `startup.nsh` runs `pci 00 01 00 -i` then **`E2-PCI-BAR`**. Config space dump of virtio-blk (`Vendor ID 1AF4` / `Device ID 1001`, BAR0 at cfg+0x10). PciRootBridgeIo config read, still not an AI BAR map. In-tree QEMU has **no slirp** (`-netdev user` refused); `virtio-net-pci` is emitted when `netdev_user` is set, not forced on this gate.
- E2-PCI **net green**: hubport (no slirp) + `virtio-net-pci`. `--expect E2-PCI-NET`: Shell `pci` lists **`00 00 02 00 ==> Network Controller - Ethernet controller` Vendor 1AF4 Device 1000**, then `pci 00 02 00 -i`. QEMU warns `hub 0 is not connected to host network` — enum only, no packet claim. Matches `pcie-endpoint.md` virtio-net **role**, not an AI BAR.
- E2-PCI **console + VirtioNet bind green**: `virtio-serial-pci` **`00 00 03 00` Vendor 1AF4 Device 1003** (Simple Communications). Shell `devices` shows **`Virtio Network Device`** bound on the net function (`--expect "Virtio Network Device"`). `ifconfig -l` listed nothing (no IP4_CONFIG2 on a disconnected hub) — SNP/driver bind is green; IPv4 config is not claimed.
- Bridge **virt-card route**: `ai_tensor_bridge.py push --route virt-card --repo-root <monorepo>` starts `CardAgent`, BAR4-puts A/B, `gemm_s8` golden `[[19,22],[43,50]]`, stamps `out/bridge/virt-card.json` with `evidence: false`, `tops_not_evidence: true`. `doctor` lists virt-card + edk2-pci. `pcie` prints 100 TOPS **definition** (§2) and still exits 1 while unpinned.
- EDK2 **CARD.TXT on PCI ESP**: `type fs0:\CARD.TXT` prints `stand-in: virt-ai-pcie` and **`100e12`** dense INT8 definition (`--expect 100e12`). Not a TOPS measurement.
- EDK2 **packed DESC.BIN on PCI ESP** **green**: `apply_edk2_pci_shell` runs `ai_tensor_bridge.py pack` against `out/ai_soc_model.json` (64-byte OP_GEMM, `version=1`, `m=n=k=2`) and writes `DESC.BIN` + `DESC.HEX` + `DESC.TXT` (`--decode-out`). `g6q run --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect OP_GEMM`: Shell `type fs0:\DESC.TXT` prints **`op=OP_GEMM`**. Same image BAR4-puts as name `DESC` into virt_ai_card UIO DESC@0x140 (`bar4_put_bytes`, round-trip) then golden GEMM `[[19,22],[43,50]]`. File + TCP bulk stand-in, **not** a pinned BAR. Transport still **unpinned** (`pcie` rc=1).
- EDK2 **CAP.TXT + model-seeded card CAP** **green**: `pack --cap-out` writes ingested `clusters`/`macs_per_cycle`/`clock_khz` and **modelled** peak (`256 MAC/cycle × 1 GHz × 2 ops/MAC = 512 GOPS / 0.512 TOPS`). `g6q run --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect modelled_peak_gops`: Shell `type fs0:\CAP.TXT` prints **`modelled_peak_gops=512`**. virt_ai_card CAP window is seeded from the same config; hello `cap` matches (`clusters=1`, `macs/cycle=256`, `sram_bytes=2097152`). 100e12 remains the class **definition**; fixture SKU is not 100 TOPS; `tops_not_evidence`.
- virt_ai_card **UIO MMIO stand-in** **green**: `mmio_rd`/`mmio_wr` on the existing 4 KiB window. `push --model` reads CAP `macs_per_cycle=256` at ingested off=8 and round-trips DESC at ingested `desc_base=0x140`. CAP.TXT **class vs SKU** **green**: `g6q run --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect class_need_macs_per_cycle` prints **`class_need_macs_per_cycle=50000`** (100 TOPS at 1 GHz) and **`sku_frac_of_class=0.00512`**. Not a pinned BAR; not a 100-TOPS measurement.
- virt_ai_card **doorbell + DONE claim** **green**: BAR4-stage A/B into card DRAM, host writes UIO DOORBELL, polls TICKET/DSTATUS, claims DONE, BAR4-gets C. `push --model` stamps `doorbell: {ticket:1, status:0, claimed:true}`. ESP `CPL.TXT` **green**: `g6q run --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect ticket_bit_high` prints ingested **`ticket_bit_high=31`** / **`status_bit_low=32`** / **`st_ok=0`**. Not a pinned BAR.
- Packed **completion word** **green**: `pack_completion` from ingested ticket/status bits writes `CPL.BIN` (8) / `CPL.HEX`. `g6q run --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect example_hex`: Shell prints **`example_hex=0100000000000000`** (ticket=1, ST_OK). virt-card stamps matching `completion_hex` and stand-in PMU `{r:8,w:4,cycles:4}` for the 2×2 GEMM (`pmu_not_tops`). Not a TOPS measurement.
- BAR4 **CPL join** + ESP **PLANE.TXT** **green**: virt-card BAR4-puts the packed completion word as name `CPL` and logs **`BAR4 CPL matches ESP CPL.BIN`**. `g6q run --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect tops_on=island`: Shell `type fs0:\PLANE.TXT` prints **`tops_on=island`**, `island_acc_tile_m=256`, `core_tile=not_in_this_model`. Core 8×8×8 is not typed in the bridge.
- **IRQ wait-then-claim** + ESP **JOIN.TXT** **green**: `push --model` logs **`irq_waited=True`**, **`BAR4 DESC matches ESP DESC.BIN`**, **`BAR4 CPL matches ESP CPL.BIN`**. `g6q run --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect join=firmware_and_card`: Shell `type fs0:\JOIN.TXT` prints **`join=firmware_and_card`**, `desc_hex_prefix=01000100`, `irq=wait_then_claim_done`. Eventfd MSI stand-in, not a pinned vector.
- ESP **ROOF.TXT** + JOIN SHA-256 **green**: `g6q run --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect class_dram_gbps`: Shell prints **`blocking_t=256`**, **`bytes_per_mac=0.007812`**, **`class_dram_gbps=390.625`** (§4 T=256 row). `push --model` logs **DESC sha256 matches ESP JOIN.TXT** and **CPL sha256 matches ESP JOIN.TXT**. Not a measurement.
- ESP **QUEUE.TXT** + ROOF **acc SRAM** **green**: `g6q run --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect work_quantum_k`: Shell prints **`work_quantum_k=64`**, `queues=2`, `queue_depth=64`, `doorbell_qid=0`. ROOF adds **`acc_sram_bytes=262144`** (256 KiB, §4 T=256 row) and **`acc_fits_island_sram=true`** vs ingested 2 MiB. `push --model` stamps doorbell `qid=0`.
- Multi-queue doorbell **green**: when card CAP `queues>=2`, ring qid 1 with ticket+1 after qid 0; read UIO STATUS (busy=0). QUEUE.TXT `doorbell_qid_last=queues-1`. `g6q run --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect doorbell_qid_last` prints **`doorbell_qid_last=1`**. `push --model` stamps `multi_queue=true` / `qid1.ticket=2`.
- Packed **null ptr_*** + ingested **irq_bit** **green**: ESP `PTR.TXT` `ptr_null=true` (ptr_*=0, BAR4 names A/B/C, `ptr_done_path=mmio_cpl`, no invented addresses). ESP `FLAGS.TXT` `irq_bit=2` / `irq_bit_ok=true` (`isa-encoding.md` §7). Packed DESC `flags=4`. virt_ai_card `FLAG_IRQ = 1<<2`. `wr_cpl_en=0` when `ptr_done=0`. `g6q run --backend qemu --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect irq_bit_ok` **green**. `push --model` stamps `ptr_null=true` / `flags_irq=true` and still joins ESP DESC/CPL. Transport still **unpinned**.
- Packed **ld_ab** + dense INT8 + cluster map **green**: `ld_ab = k | (n<<16)` from ingested field (2×2 → `lda=2` `ldb=2` `ld_ab_ok=true`). FLAGS `dtype_s8s8=true` `ew_byte=true` `sp24=false` `int4_not_in_headline=true` (100 TOPS definition, not INT4). QUEUE `cluster_from_map=true` `qid0_cluster=0` `qid1_cluster=1`. `g6q run --backend qemu --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect ld_ab_ok` **green**. `push --model` stamps `lda=2` `cluster=0` (qid1 cluster=1) and still joins ESP DESC/CPL. Transport still **unpinned**.
- Scheduling / QoS **green**: ESP `SCHED.TXT` `within_quantum=true` (stand-in `k=2` vs ingested `work_quantum_k=64`); `qos_from_qid` `qid0_qos=0` `qid1_qos=1`. FLAGS `fence_clear=true` `priority_default=true`. virt_ai_card rejects mismatched `ld_ab`. `g6q run --backend qemu --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect within_quantum` **green**. `push --model` stamps `qos=0` `within_quantum=true` and still joins ESP DESC/CPL. Transport still **unpinned**.
- qid bounds / desc version **green**: ESP `STAT.TXT` `qid_bound=true` `oob_qid=2` `version_ok=true`. Card doorbell `qid >= queues` or `version∉{0,1}` completes stand-in `ST_ERR` (ingested package publishes `ST_OK` only). `g6q run --backend qemu --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect qid_bound` **green**. `push --model` stamps `qid_bound=true` / `qid_oob` and still joins ESP DESC/CPL. Transport still **unpinned**.
- Ingested op table + CTL enable **green**: ESP `OP.TXT` `op_ok=true` `unknown_op_rejected=true`; `CTL.TXT` `wr_cpl_en=0` `disabled_rejected=true`. Card unknown op → `ST_BAD_OP`; doorbell while disabled → `ST_DISABLED`. `g6q run --backend qemu --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect op_ok` **green**. `push --model` stamps `disabled_rejected=true` and still joins ESP DESC/CPL. Transport still **unpinned**.
- CTL re-enable recovery **green**: ESP `CTL.TXT` `reenable_ok=true`. After a disabled doorbell, `CTL.enable=1` then a qid-0 ring completes `ST_OK` again. `g6q run --backend qemu --loader edk2 --os efi-shell --machine g6lc-virt --wsl --expect reenable_ok` **green**. `push --model` stamps `reenable_ok=true` and still joins ESP DESC/CPL. Transport still **unpinned**.
- U3-Shell **virt green**: `g6q run --loader u-boot --os efi-shell --machine g6lc-virt --smp 2 --expect "UEFI Interactive Shell"`. Distro boot `virtio 0:1` `bootefi` of EDK2 `Shell.efi` (`out/loader-run/esp-shell.img`). **`UEFI Interactive Shell v2.2`**, `UEFI v2.110 (Das U-Boot, 0x20250700)`, mapping table `FS0:` / `HD0b:`. Soc SPI FIT of the same PE: `bootm` **`Transferring control to EFI`** then hangs after `Booting <NULL>` (not UCS-2; ASCII expect would have matched). Soc `bootefi hello` **`Hello, world!`** / `Running on UEFI 2.11`. Soc U-Boot fragment now serial-only stdout, empty `bootargs`, `bootefi hello` fallback, and `# CONFIG_VIDEO/PCI/USB is not set`. Next soc Shell: a file device path on NOR (virt's working path), not a 32 MiB pflash FD.
- Missing host prerequisites to record: RISC-V cross-toolchain, `make`, `bash`, WSL (on Windows), `ninja`/BaseTools for EDK2, and network/git for source fetch.

### AI island CAP bank words + reader repairs (2026-09-29)

- `AiIslandConfig::cap_value` sources `bank_a_bytes` / `bank_b_bytes` (CAP 0x98/0x9C, flat
  panel mapping) from the ingested tile geometry (`operand_bank_bytes`: rows x
  ceil(elem_max x AccTileK / lanes) x lanes, elem_max 4 with `fp_datapath` else 1); the
  live-package test pins offsets and integer-strip values. B3 and the generated B1 device
  read the same words as the RTL.
- Reader repairs: `parse_cap_window_packed` skips the conditional `command_queue` arm
  (it aborted the whole packed set, leaving `dram_gbps` unsourced); the cfg-package
  constants reader stops at a `function` block, so the design keeps functions out of the
  `CAP_OFF_*`/`REG_OFF_*` block (recorded as a design-side convention, not a reader change).
- `tensor_eval::native_fixture_all_formats_and_rejections` root cause and fix: commit
  `9805b92cd` added `AiIslandConfig::fp_datapath` and the gemm refusal of float codes
  without it ("a set mask bit is not an implemented product"), but nothing in ingest ever
  sourced the field, so every float job was refused on every design (the fixture, mask
  0xfb, executed 3 of 11 instead of 9). Ingest now reads it from the design at the seam
  that decides it in RTL: `AiCfg.IslandFpEn` of the core package (`Package::nested`,
  the live `g6lc64_ai` package says 0 = integer strip); when the package carries no
  `AiCfg` (the synthetic fixture), the island's own legality rule decides -- the top
  asserts grant ⊆ implemented with the FP-aware implemented mask only under `IslandFpEn`,
  so a grant naming a float code (`FLOAT_GRANT_BITS` 0xF8 = codes 3..7) can only elaborate
  with the float datapath present. Read from the design either way, never assumed.
  Tests: ingest pins both sources (explicit 1/0 win over the mask; mask-only fallback).
- Green: whole workspace `cargo test` (cli 87, core 41, diag 75, vm 187, ingest 26, svcfg
  52, dts 45, emit-args 43, emit-qemu 59, flist 11). `check` still red only on the owner's
  in-progress `too_many_arguments` (`gemm.rs:97/931`, `exec.rs:3855`); `fmt --all` applied.

### B1 parity on the real repo: island flist, symbol namespacing, ai-matrix node (2026-09-29)

- Real-repo ingestion had no island: the core/SoC flists do not list the island packages.
  The island now publishes `corev_apu/ai_island/Flist.ai_island` and `g6q-cli` resolve adds
  it (`layout::AI_FLIST`) when present, so `gen --repo-root E:/cva6 --target g6lc64_ai`
  carries `soc.ai_island` (dtype 3, `fp_datapath` 0 from `AiCfg.IslandFpEn`, accmode 1,
  bank words 0x80000 / 0x40000) and emits `g6lc-g6lc64_ai` with the AI-island device.
- Two AI machines could not coexist in one QEMU tree: the emitted `helper_g6lc_ai_*`,
  `trans_ai_*`, `g6lc_ai_island*` symbols were target-blind and the fixture `ai` machine
  collided with `g6lc64_ai` at compile/link. `g6q-emit-qemu` now namespaces the decode
  instruction names, `trans_` routines, helpers and the island C API by the machine id
  (`trans_g6lc_<id>_ai_enq`, `helper_g6lc_<id>_ai_poll`, `g6lc_<id>_ai_island_create`, ...);
  tests pin the names and the absence of the old ones.
- The board DTS names the island node `ai-matrix` (`compatible = "g6lc,ai-matrix"`, the UIO
  `of_id` contract) while the fixtures use `ai-island`; the machine emitter's device create,
  `payload_flags.py` and the unimplemented-access filter accept both.
- `g6q_remote.py` false green: with the passphrase-protected key and no agent, the
  `conhost wsl ssh/rsync` calls hung or failed and the tool still logged "synced" / "built"
  on a Sep-14 binary. Runs now go through a WSL-native invocation with an agent unlocked via
  `SSH_ASKPASS` from the proxy's passphrase file. Open: make the tool check every ssh/rsync
  exit code and refuse to report a step it did not observe succeeding.
- Live: `g6lc-g6lc64_ai` builds with both AI machines present and boots OpenSBI v1.5.1
  (`Platform Name: GSys LibreCore g6lc64_ai`, `rv64imafdcbh`); the AI-island smoke on the
  real model is the run in progress (`b1-parity-20260929-r6`).

## APU RTL bridge — 3d-b stage 2 (external device)

- `ApuModel` (`soc.apu`) ingests `g6lc_apu_cfg_pkg.sv` ApuVenus literal plus `g6lc_apu_pkg.sv`
  `APU_SHM_*` from `corev_apu/apu/Flist.apu_soc` (repo-root path); every emitted constant is a
  published localparam so nothing is guessed and no RTL_FEEDBACK.md ask is needed.
- `soc.apu_bridge` set by `--apu-bridge` (`g6q.py install-qemu` forwards it) emits
  `hw/riscv/g6lc-<target>-apu-bridge.c`: a sysbus socket client to the Verilator bridge server
  (`verif/tb/apu/bridge/bridge_main.cpp`), bridging virtio-mmio frames, DMA via
  `address_space_rw`, and IRQ via `qemu_set_irq` with the nested wait loop that services
  interleaved DMA/IRQ frames while an MMIO reply is pending.
- Machine retags the board DTS virtio.mmio GPU window to `g6lc,apu-bridge` (or synthesizes it if
  absent); FDT keeps `virtio,mmio` (no `dma-coherent`) and carves the `APU_SHM_*` aperture out of
  the `memory@` nodes entirely — a `reserved-memory` child would register a busy iomem resource and
  fail `virtio_gpu`'s `devm_request_mem_region` with `-EBUSY`. The DRAM `MemoryRegion` still backs
  the aperture physically; to keep a `-kernel` image's BSS out of the linear-map hole, the emitted
  machine relocates `kernel_start_addr` to the aperture end when the aperture lies inside DRAM.
  Bridge wire ABI documented in `architecture/EMIT.md` section 3.7.
- Fixture `fixtures/apu/` stands in for the design packages; ingest still reports absent when the
  packages are not on the flist.
- **B2 plugin guard fix (this pass):** a model can publish the descriptor layout + queue
  instructions (`G6LC_AI_DESC_DECODE == 1`) while the board peripheral list has no ai-island
  window (`G6LC_AI_ISLAND_LEN == 0`) — the real `g6lc64_stream8` model hits exactly that
  combination.  The tensor globals (`g6lc_tensor_file`/`order`/`first_record`), the `tensor=`
  option, and the at-exit flush were guarded by `ISLAND_LEN != 0` only, while the desc-decode
  producer path referenced them unconditionally: the emitted plugin failed `-Werror` with
  undeclared identifiers, and `g6lc_desc_store`/`g6lc_desc_seen` were dead without the island.
  `plugin.rs` now guards the three shared sites with
  `G6LC_AI_DESC_DECODE == 1 || G6LC_AI_ISLAND_LEN != 0`, keeps the raw-access fallback
  island-only, and guards `g6lc_desc_store`/`g6lc_desc_seen` as island-only.
  Regression test: `tensor_globals_survive_desc_decode_without_an_island_window`.
- **Aperture growth (3d-b continuation):** `APU_SHM_BYTES` grew to 32 MiB; the emitted bridge
  comment and the FDT `reserved-memory` node follow `soc.apu.shm_*` automatically — no emitter
  change needed, re-running `install-qemu` re-derives them.
- **Stock-guest result (2026-10-07):** the unmodified Ubuntu 24.04.5 riscv64 image (kernel
  7.0.0-31-generic, `mesa-vulkan-drivers` 25.2.8) boots on the `g6lc-g6lc64_stream8` machine
  against the Verilator bridge; `virtio_gpu` probes cleanly (capset id 4 VENUS, 32 MiB host
  window, `renderD128`) and the Mesa Venus wire exchange runs `vkCreateInstance` →
  `vkEnumeratePhysicalDevices` → `vkGetPhysicalDeviceProperties` →
  `vkEnumerateDeviceExtensionProperties` before Mesa 25.2.8's `vn_physical_device.c`
  `KHR_external_memory_fd` hard requirement drops the device (design-side blocker, recorded in
  `architecture/uncore/apu-vulkan-engine.md` §11 row 3d-b). VenusOff control: llvmpipe-only,
  zero device DMA/IRQ. Driver at `/tmp/g6lc-apu-bridge/drive_guest.py` (transient, not a
  package artifact).
- **3d-b closure (2026-10-08):** with `VK_KHR_external_memory_fd` v1 advertised (the aperture
  blob *is* Venus's external-memory mechanism — §12.1 F9) and the bind2 staged-payload fix,
  the stock guest now completes both gates: `vulkaninfo --summary` lists the Venus GPU
  (`driverName = venus`, apiVersion 1.1.0) and the in-guest `vkcompute` dispatches
  `bufcopy.spv` bit-exact vs `spirv_model.py` (`G6LC_VKCOMPUTE_PASS words=32`). VenusOff
  control re-run: llvmpipe-only. Full ordered command stream captured in
  `architecture/uncore/apu-venus-command-trace.md`; artifacts under
  `/tmp/g6lc-apu-bridge/`.
- **F5 closure (2026-10-08):** memory-resident descriptors (§12.1 F5) verified end-to-end on the
  stock guest after the ObjTab stale-directory-row fix (dir rows now carry `gen[15:0]`; stale hits
  are tombstoned and probing continues — see §11 row F5). `vulkaninfo --summary` shows the Venus
  device, `vkcompute` → `G6LC_VKCOMPUTE_PASS words=32`, and `vkdescarr` →
  `G6LC_VKDESCARR_PASS words=32` with `ssboArrDyn=1 uboArrDyn=1` read back in-guest. Artifacts +
  logs persist under `.cache/f5-logs/` (guest/ + final/).
