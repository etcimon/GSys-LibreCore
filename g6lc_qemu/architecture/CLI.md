# CLI — command-line surface

Index: [`README.md`](README.md) · Crate: `g6q-cli`. Binary **`g6lc-qemu`**, alias **`g6q`**.

Every option states its default and its **source of truth**, because the point of the tool is that
defaults come from the design rather than from the tool.

```
g6lc-qemu <verb> [options]
```

| Verb | Does |
|---|---|
| `gen` | ingest → `TargetModel` → emit (argv / device tree / QEMU C / plugins) |
| `run` | build a machine and execute it |
| `diag` | run with the diagnosis layer, emit reports |
| `tandem` | lockstep against a reference, report first divergence |
| `dts` | read / overlay / mutate / validate / emit a device tree |
| `fw` | fetch / build / inspect firmware |
| `conform` | ingest and print the conformance report only |
| `pins` | show / check pinned revisions |
| `doctor` | host capability probe |

Global: `--json-out FILE`, `-v/--verbose`, `-q/--quiet`, `--dry-run`, `--out-dir DIR`
(default `out/`), `--color auto|always|never`.

---

## 1. Design selection

| Option | Default | Source of truth |
|---|---|---|
| `--repo-root PATH` | auto-detect upward | — (never required, §10) |
| `--target ID` | required unless `--config-pkg` | the design's per-target configuration package |
| `--config-pkg FILE` | derived from `--target` | direct file, for standalone use |
| `--soc-pkg FILE` | discovered from the flist (`*_soc_pkg.sv`) | the SoC/peripheral package (e.g. `ariane_soc_pkg.sv`) |
| `--plane core\|apu\|soc` | `soc` | [`INGEST.md`](INGEST.md) §1 |
| `--flist FILE` (repeatable) | derived from `--target` | the manifests themselves |
| `--extra-flist FILE` | none | optional units (vector, alternate supply, gate-level) |
| `--set VAR=VALUE` | `<root var>=<repo-root>` | flist variable expansion; nothing baked in |
| `--define K[=V]` | from the manifests | `+define+` set |
| `--incdir DIR` | from the manifests | `+incdir+` set |
| `--cfg-override FIELD=VALUE` | none | marked **`synthetic`**; taints every artifact |
| `--conform strict\|warn\|off` | `warn` for `run`, **`strict`** for `diag`/`tandem` | [`IR.md`](IR.md) §3 |
| `--emit-model FILE` | — | writes the model JSON |

## 2. Device tree

| Option | Default | Notes |
|---|---|---|
| `--dts FILE` | derived from `--target` | the design's own tree for that target |
| `--dtb FILE` | — | prebuilt blob, verbatim; skips generation and most validation |
| `--dts-generate` | off | synthesise from the model instead of reading a file |
| `--dts-overlay FILE` (repeatable) | none | merged over the base, in order |
| `--dts-set PATH=VALUE` (repeatable) | none | e.g. a memory `reg`, `chosen/bootargs`, a node `status` |
| `--dts-del PATH` (repeatable) | none | remove a node or property |
| `--isa-string AUTO\|STR` | `AUTO` | overrides the ISA string property |
| `--isa-extensions ADD,-DEL` | from config | token edits on the extension list |
| `--cpu-topology auto\|NxT` | `auto` = cores × threads-per-core | writes the topology map. Issue width is **not** a hart and never appears in a device tree. |
| `--pmu-map auto\|off\|FILE` | `auto` | event mapping from the design's counter table |
| `--cache-props auto\|off` | `auto` | cache geometry and maintenance block sizes |
| `--dump-dts FILE` / `--dump-dtb FILE` | — | write the resolved tree |
| `--dts-validate` | off; on under `--conform strict` | cross-check against config + flist facts |

## 3. SoC / peripherals

| Option | Default | Source of truth |
|---|---|---|
| `--soc-map auto\|FILE` | `auto` | the design's SoC/peripheral package |
| `--machine g6lc-soc\|g6lc-virt` | **`g6lc-soc`** | [`DESIGN.md`](DESIGN.md) §4 |
| `--mem-base ADDR` / `--mem-size SIZE` | from the SoC package | overriding sets `faithful: false` |
| `--peripheral ID=on\|off` | as mapped | per-peripheral gate |
| `--peripheral-base ID=ADDR` | as mapped | **flags the machine non-faithful** |
| `--intc-sources N` / `--intc-targets N` | from the SoC package | target count bounds total harts |
| `--uart-model … \|none`, `--uart-freq`, `--uart-baud` | from the device tree | console |
| `--accel on\|off\|auto` | `auto` from config | accelerator device presence |
| `--accel-cfg FILE` | the design's island configuration package | capability geometry |
| `--l2 auto\|off\|SIZE` / `--l3 auto\|off\|SIZE` | `auto` | cache levels |
| `--bootrom BASE:LEN\|none` | `none` | zero-stage boot ROM window (e.g. `0x1000:0xf000`) |

## 4. Firmware

| Option | Default | Notes |
|---|---|---|
| `--fw-mode jump\|payload\|dynamic\|none` | `payload` | |
| `--fw ELF\|BIN` | environment, else built | prebuilt firmware |
| `--fw-src DIR` / `--fw-ref TAG` | `out/fw-src`, pin from `../pins.toml` | build from source |
| `--fw-platform ID` | `generic` | no vendor platform code |
| `--fw-text-start ADDR` | from the pin | link address |
| `--fw-fdt DTB\|auto` | `auto` (generated from the resolved model) | embedded device tree; `DTB` sets `FW_FDT_PATH` for OpenSBI; `auto` writes `out/fw/fdt_auto.dtb` and passes it |
| `--fw-payload FILE` | environment | kernel image or S-mode ELF |
| `--fw-jump-addr` / `--fw-jump-fdt-addr` | mode-dependent | |
| `--fw-make VAR=VAL` (repeatable) | — | passthrough to the OpenSBI `make` command; values must contain `=` |
| `--fw-allow-no-pie` | off | non-PIE toolchain path |
| `--build-fw` | off | run `fw fetch` then `fw build` before the main command; project-owned scripts may be wired later |
| `--fw-out DIR` | `out/fw` | staging directory for built `fw_<mode>.bin` and `fw_<mode>.elf` |
| `--sbi-extension NAME=on\|off` | all discovered | limit or report supervisor-interface extensions |
| `--fw-print-region` | off | dump firmware / device-tree / payload layout before boot |

Firmware integration **composes** with the design project's existing scripts when they are present and
falls back to its own fetch/build when standalone. It never reimplements the project's profile.

On Windows, `fw build` automatically uses WSL (and a WSL-installed PIE-capable `riscv64-linux-gnu-` or
`riscv64-unknown-elf-` toolchain) when `wsl` is on PATH, because OpenSBI's Makefile requires POSIX
utilities and a linker that supports PIE. The contained Windows `xpack-riscv-none-elf-gcc` remains
available for local payload compilation.

Secondary harts park until the supervisor interface starts them; `--sbi-extension hsm=off` and
`--maxcpus 1` exist specifically to reproduce the two classic bring-up failures.

## 5. Operating system

| Option | Default | Notes |
|---|---|---|
| `--os PROFILE` | `firmware-smoke` | `buildroot`/`ubuntu`/`debian`/`fedora` imply `g6lc-virt`, `qcow2` rootfs format, and a `root=/dev/vda` append unless overridden |
|| `--distro-root DIR` | `out/dist/<os>` | search directory for `vmlinuz`/`Image`, `initrd.img`, and `rootfs.qcow2`; explicit `--kernel`/`--initrd`/`--rootfs` win |
| `--kernel FILE` | environment | kernel image |
| `--initrd FILE` | — | initial ramdisk |
| `--rootfs FILE` / `--rootfs-format raw\|qcow2` | — | **implies `--machine g6lc-virt`** |
| `--drive FILE[,if=virtio,format=…]` (repeatable) | — | virt profile only |
| `--append "STR"` | from the device tree | merged into the boot arguments |
| `--maxcpus N` | see §6 |  |
| `--console uart\|virtio`, `--serial stdio\|file:…\|tcp:…\|null` | `uart`, `stdio` | `virtio` adds `virtio-serial-device` + `virtconsole`; implies virt profile |
| `--netdev user\|tap\|none`, `--net-fwd H:G`, `--ssh-port N` | `none` | networking implies the virt profile |
| `--virtio blk,net,rng,9p,console` | — | virt profile only; `rng` currently wires `virtio-rng-device` |
| `--elf FILE`, `--exit-on-tohost` | — | bare-metal harness semantics |
| `--timeout SECONDS`, `--max-instret N` | none | bounded runs for CI |

Anything needing a disk or a network forces `g6lc-virt`, and the tool **says so on stderr** the first
time rather than silently switching profiles.

## 6. Execution

| Option | Default | Notes |
|---|---|---|
| `--backend args\|qemu\|rust` | `qemu` if available, else `rust` | B0 / B1+B2 / B3; `--backend qemu` targets the generated `g6lc-<target>` B1 machine; use `--stock-machine` / `--stock-cpu` to force the B0 stock target |
| `--qemu-bin PATH` / `--qemu-src DIR` | discovered / `qemu/` | stock binary; emission target |
| `--accel tcg` | `tcg` | only value; host-hypervisor acceleration is a recorded non-goal |
| `--smp auto\|N` | `auto` = cores × threads-per-core | multi-threaded translation; "auto" uses the model |
|| `--maxcpus N` | `smp` | CPU hotplug ceiling, at least `smp` |
| `--tcg-tuning default\|tuned` | `default` | `tuned` forces `-accel tcg,thread=multi` when `smp > 1`; incompatible with `--icount` |
| `--icount N\|off` | off; forced by `--deterministic` | `N` is the `shift` value; `off` disables; icount forces single-threaded TCG |
| `--deterministic` | off; implied by `--tandem` / `--record` | fixed tick ratio, seeded devices |
| `--debug CATEGORIES` | — | `-d` log categories for QEMU (`unimp`, `guest_errors`, ...); repeatable |
| `--debug-file FILE` | — | `-D` log path for QEMU debug output |
| `--plugin PATH` | — | load a TCG plugin (default `out/emit/<target>/contrib/plugins/g6lc-<id>.so`) |
| `--record FILE` | — | write a stamped `RecordFile` (B3 native; B1+B2 QEMU auto-loads the trace plugin) |
|| `--checkpoint FILE` | — | write a resumable `Checkpoint` of the native run |
|| `--restore FILE` | — | resume a native run from a `Checkpoint`; `--image` is optional when this is given |
|| `--replay FILE` | — | replay the native run against a `RecordFile`, fail on divergence |
| `--gdb PORT`, `--trace-uart FILE` | — | |

## 7. Diagnosis

| Option | Default | Notes |
|---|---|---|
| `--diag off\|d1\|d2\|full` | `off` | [`DIAG.md`](DIAG.md) |
| `--rvfi-out FILE` | — | commit-record trace |
| `--tandem <ref>\|none`, `--tandem-ref PATH` | `none` | implies `--diag d1 --deterministic --conform strict` |
| `--stop-on-divergence` | on with `--tandem` | non-zero exit + `divergence.json` |
| `--record FILE` / `--replay FILE` | — | commit-record trace (record) / record-file playback (replay); QEMU `RecordFile` produced by `--record` with `--backend qemu` |
|| `--tensor FILE` | — | AI-island tensor event trace (`g6q run --backend native` writes it from B3, `g6q run --backend qemu` uses the B2 plugin `tensor=` arg); D2 `ai.tensor.*` counters derive from this stream |
| `--checkpoint-at instret=N\|pc=ADDR\|uart="STR"` | — | trigger |
| `--checkpoint-out DIR` | — | resumable state, **faithful profile only** |
| `--pmu-out FILE`, `--uarch-out FILE` | — | counters; structure profile |
| `--allow-virt-diag` | off | required to diagnose under the virt profile; taints output |
|| `--measured-dram-gbps-x1000 N` | — | host-supplied measured DRAM bandwidth in 1/1000 GB/s; closes the roofline even when the design has not published it |

Every diagnosis artifact carries `"evidence": false`.

## 8. Emission

| Option | Values |
|---|---|
| `--emit` | `model`, `conformance`, `args`, `matrix`, `dts`, `dtb`, `qemu`, `qemu-machine`, `qemu-plugin`, `qemu-pmu-plugin` |
| `--emit-dir DIR` | default `out/emit/<target>/` |
| `--check` | re-emit to a temporary directory and diff; non-zero on drift |

## 9. Host tooling setup

These are implemented in `tools/g6q.py` rather than the Rust `g6lc-qemu` binary because they touch the host environment.

| Command | Purpose |
|---|---|
| `g6q setup` | contained rustup/cargo under `.tools/` |
| `g6q setup-riscv` | contained xPack `riscv-none-elf-gcc` for small payloads |
| `g6q setup-host` | auto-install OpenSBI toolchain, QEMU, DTC, or Spike using the detected package manager |

`setup-host` detects the platform/package manager:

- **Windows:** WSL with `apt-get` (tools run inside WSL, because OpenSBI needs a POSIX shell and a PIE-capable linker).
- **Linux:** `apt`, `dnf`, `pacman`, or `apk`.
- **macOS:** `brew`.

Flags:

- `--toolchain` (default) — PIE-capable RISC-V toolchain for OpenSBI (`gcc-riscv64-linux-gnu` on apt/dnf, `riscv64-linux-gnu-gcc` on pacman; brew requires a manual tap).
- `--qemu` — `qemu-system-riscv64`.
- `--dtc` — `dtc` / `device-tree-compiler`.
- `--spike` — prints build-from-source instructions (no distribution packages yet).
- `--all` — all of the above.
- `--build-tools` [TOOL ...] — install build dependencies (`meson`, `ninja`, `cmake`, `bison`, `flex`, `make`). With no tools listed, installs all of them.
- `--standalone` — prefer standalone binary downloads / source builds over the package manager.
- `--yes` (`-y`) — non-interactive: automatically install missing platform dependencies (Chocolatey, MSVC Build Tools).
- `--vs-year` `{2022,2025,2026}` — Visual Studio / Build Tools year for Windows auto-install (default `2022`).
- `--dry-run` — print the plan without installing.
- `--force` — reinstall even if already present.

On Windows, `setup-host` runs a smart preflight: if Chocolatey, WSL, or MSVC is missing for the selected operation it either prompts for the desired fix (install Chocolatey, install MSVC via Chocolatey, or show WSL instructions) or, with `--yes`, installs them automatically.

`g6q doctor` reports each tool and points at `setup-host --<tool>` when something is missing.

## 10. Examples

```bash
g6q conform --target <id> --repo-root /path/to/design
g6q gen     --target <id> --repo-root /path/to/design --emit-model model.json
g6q run     --target <id> --repo-root /path/to/design --os firmware-smoke --build-fw
g6q run     --target <id> --machine g6lc-virt --os ubuntu --kernel Image \
            --rootfs rootfs.img --netdev user --ssh-port 2222 --smp 8
g6q tandem  --target <id> --elf test.elf --tandem spike --tandem-ref $(which spike)
g6q run     --target mini --backend qemu --qemu-path ./qemu/build/qemu-system-riscv64 \
            --kernel ./smoke.elf --record trace.json
# Explicit B0 stock-QEMU override:
g6q run     --target mini --backend qemu --stock-machine virt --stock-cpu rv64 \
            --qemu-path qemu-system-riscv64 --kernel ./smoke.elf
g6q tandem  --under-test trace.json --reference golden.json
g6q diag    --target <id> --replay boot.rec --checkpoint-at instret=12000000 \
            --checkpoint-out ckpt/
```

## 11. Standalone operation

No option above requires a host project. `--repo-root` derives paths from a target id as a
convenience; without it, `--config-pkg`, `--flist` + `--set`, `--soc-map`, `--dts`/`--dtb`, `--fw` and
`--kernel` fully specify a machine.

```bash
g6q gen --config-pkg ./target_config_pkg.sv \
        --flist ./manifest.f --set ROOT=/abs/design \
        --soc-map ./soc_pkg.sv --dts ./board.dts \
        --emit-model model.json
```

This is the independence invariant made operational: the package is usable against any
similarly-shaped tree, a fork, or a fixture.
