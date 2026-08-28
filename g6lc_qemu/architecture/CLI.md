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
| `--fw-fdt DTB\|auto` | `auto` (the tree just generated) | embedded device tree |
| `--fw-payload FILE` | environment | kernel image or S-mode ELF |
| `--fw-jump-addr` / `--fw-jump-fdt-addr` | mode-dependent | |
| `--fw-make VAR=VAL` (repeatable) | — | passthrough to the firmware build |
| `--fw-allow-no-pie` | off | non-PIE toolchain path |
| `--build-fw` | off | drive the design project's own firmware scripts when present |
| `--fw-out DIR` | `out/fw` | honours the project's output variable when set |
| `--sbi-extension NAME=on\|off` | all discovered | limit or report supervisor-interface extensions |
| `--fw-print-region` | off | dump firmware / device-tree / payload layout before boot |

Firmware integration **composes** with the design project's existing scripts when they are present and
falls back to its own fetch/build when standalone. It never reimplements the project's profile.

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
| `--backend args\|qemu\|rust` | `qemu` if available, else `rust` | B0 / B1+B2 / B3 |
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

Every diagnosis artifact carries `"evidence": false`.

## 8. Emission

| Option | Values |
|---|---|
| `--emit` | `model`, `conformance`, `args`, `matrix`, `dts`, `dtb`, `qemu`, `qemu-machine`, `qemu-plugin`, `qemu-pmu-plugin` |
| `--emit-dir DIR` | default `out/emit/<target>/` |
| `--check` | re-emit to a temporary directory and diff; non-zero on drift |

## 9. Examples

```bash
g6q conform --target <id> --repo-root /path/to/design
g6q gen     --target <id> --repo-root /path/to/design --emit-model model.json
g6q run     --target <id> --repo-root /path/to/design --os firmware-smoke --build-fw
g6q run     --target <id> --machine g6lc-virt --os ubuntu --kernel Image \
            --rootfs rootfs.img --netdev user --ssh-port 2222 --smp 8
g6q tandem  --target <id> --elf test.elf --tandem spike --tandem-ref $(which spike)
g6q run     --target mini --backend qemu --stock-machine g6lc-mini --qemu-path ./qemu/build/qemu-system-riscv64 \
            --kernel ./smoke.elf --record trace.json
g6q tandem  --under-test trace.json --reference golden.json
g6q diag    --target <id> --replay boot.rec --checkpoint-at instret=12000000 \
            --checkpoint-out ckpt/
```

## 10. Standalone operation

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
