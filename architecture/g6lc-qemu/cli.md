# `g6lc_qemu` — command-line surface

Parent: [`README.md`](README.md) · OS/firmware semantics: [`os-linux-matrix.md`](os-linux-matrix.md).
Package implementation: `g6lc_qemu/crates/g6q-cli`; in-tree condensed copy at
`g6lc_qemu/architecture/CLI.md`.

Binary: **`g6lc-qemu`** (alias **`g6q`**). Every option states its default and its **source of
truth**, because the point of the tool is that defaults come from the design, not from the tool.

```
g6lc-qemu <verb> [options]
```

| Verb | Does |
|---|---|
| `gen` | ingest → `TargetModel` → emit (argv / DTB / QEMU C / plugins) |
| `run` | build a machine and execute it |
| `diag` | run with the diagnosis layer (D1/D2), emit reports |
| `tandem` | lockstep against Spike or an RTL trace, report first divergence |
| `dts` | read / overlay / mutate / validate / emit a device tree |
| `fw` | fetch / build / inspect OpenSBI (and payloads) |
| `conform` | ingest and print the conformance report only |
| `pins` | show / check pinned revisions (QEMU, OpenSBI, contracts) |
| `doctor` | host capability probe (toolchains, QEMU, dtc, Spike) |

Global: `--json-out FILE`, `-v/--verbose`, `-q/--quiet`, `--dry-run`, `--out-dir DIR`
(default `g6lc_qemu/out/`), `--color auto|always|never`.

---

## 1. Target, config, flist — *what design am I emulating?*

| Option | Default | Source of truth |
|---|---|---|
| `--repo-root PATH` | auto-detect upward from CWD | — (never required; see §10) |
| `--target ID` | *(required unless `--config-pkg`)* | `core/include/<ID>_config_pkg.sv`. `g6lc64_{smt2,ai,ooo,ooo_server,server_math,server_math_v,stream8}`, `cv64a6_imafdc_sv39`, `cv32a6_imac_sv32`, `cv32a65x`, … |
| `--config-pkg FILE` | derived from `--target` | direct file, for standalone use |
| `--plane core\|apu\|soc` | `soc` | [`generator.md`](generator.md) §1 |
| `--flist FILE` (repeatable) | `core/Flist.g6lc` + `Flist.ariane` (+ `core/Flist.fetch_B`) | the flists themselves |
| `--extra-flist FILE` | none | e.g. `vendor/ara/Flist.ara`, `core/Flist.smt_legacy`, `core/Flist.cva6_gate` |
| `--set VAR=VALUE` | `CVA6_REPO_DIR=<repo-root>` | flist `${VAR}` expansion; nothing is baked in |
| `--define K[=V]` | `G6LC_FETCH_B` (from `Flist.cva6`) | `+define+` set |
| `--incdir DIR` | from flists | `+incdir+` set |
| `--cfg-override FIELD=VALUE` | none | **marked `synthetic`**; taints every artifact |
| `--conform strict\|warn\|off` | `warn` for `run`, **`strict`** for `diag`/`tandem` | [`generator.md`](generator.md) §4 |
| `--emit-model FILE` | — | writes `target-model.json` |

**Why `--set` and not an env var:** the package must work against any LibreCore-shaped tree, so
`CVA6_REPO_DIR` is *passed in*, never assumed. `--repo-root` is sugar that populates it.

---

## 2. Device tree

| Option | Default | Notes |
|---|---|---|
| `--dts FILE` | derived from `--target` | `g6lc64_ai`→`ariane-ai.dts`, `g6lc64_smt2`→`ariane-smt2.dts`, `g6lc64_server_math_v`→`ariane-server-math-v.dts`, `g6lc64_ooo_server`→`ariane-ooo-server.dts`, `g6lc64_stream8`→`ariane-stream8.dts`, else `ariane-linux.dts` (bare tandem: `ariane.dts`) |
| `--dtb FILE` | — | use a prebuilt DTB verbatim; skips generation and most validation |
| `--dts-generate` | off | synthesise a DTS from the `TargetModel` instead of reading a file (useful for a config with no committed `.dts`) |
| `--dts-overlay FILE` (repeatable) | none | fragment merged over the base, in order |
| `--dts-set PATH=VALUE` (repeatable) | none | e.g. `/memory@80000000/reg=<0x0 0x80000000 0x0 0x20000000>`, `/chosen/bootargs=…`, `/cpus/timebase-frequency=32768`, `/soc/ai-matrix@40000000/status=disabled` |
| `--dts-del PATH` (repeatable) | none | e.g. drop `/soc/ai-matrix@40000000` on a non-AI run |
| `--isa-string AUTO\|STR` | `AUTO` | overrides `riscv,isa` |
| `--isa-extensions ADD,-DEL` | from config | token edits on `riscv,isa-extensions`: `h`, `v`, `zacas`, `xg6lcai`, `sstc`, `sscofpmf`, `svpbmt`, `zawrs`, … |
| `--cpu-topology auto\|NxT` | `auto` = `NrCores`×`NrHarts` | writes `cpu-map` cluster/core/thread. **`NrIssuePorts` never appears in DTS.** |
| `--pmu-map auto\|off\|FILE` | `auto` | `riscv,event-to-mhpmevent` from `perf_counters.sv` groups 0–4 |
| `--cache-props auto\|off` | `auto` | `i-cache-*`/`d-cache-*`, `riscv,cbom-block-size`, `riscv,cboz-block-size` |
| `--dump-dts FILE` / `--dump-dtb FILE` | — | write the resolved tree |
| `--dts-validate` | off (on under `--conform strict`) | re-runs the `AGENTS-dts-validation.md` §3 rows against config+flist; FAIL / WARN / GAP |

```bash
# Boot the AI package but with the island hidden from Linux, and 512 MiB of RAM
g6q run --target g6lc64_ai \
        --dts-del /soc/ai-matrix@40000000 \
        --dts-set '/memory@80000000/reg=<0x0 0x80000000 0x0 0x20000000>' \
        --dump-dts out/ai-noisland.dts

# Advertise H on stream8 (RTL has RVH=1; the committed DTS deliberately omits the token)
g6q run --target g6lc64_stream8 --isa-extensions h --dts-validate
```

---

## 3. APU / SoC map

| Option | Default | Source of truth |
|---|---|---|
| `--soc-map auto\|FILE` | `auto` | `corev_apu/tb/ariane_soc_pkg.sv` |
| `--machine g6lc-soc\|g6lc-virt` | **`g6lc-soc`** | [`backends.md`](backends.md) §2 |
| `--mem-base ADDR` | `0x8000_0000` | `DRAMBase` |
| `--mem-size SIZE` | `DRAMLength` — 1 GiB, or 512 MiB with `--define NEXYS_VIDEO` | `ariane_soc_pkg.sv` |
| `--peripheral ID=on\|off` | all as mapped | `debug`, `rom`, `clint`, `plic`, `uart`, `timer`, `spi`, `ethernet`, `gpio`, `hps` |
| `--peripheral-base ID=ADDR` | as mapped | **flags the machine non-faithful** |
| `--plic-sources N` | `30` (`NumSources`) | `ariane_soc_pkg.sv` |
| `--plic-targets N` | `16` (`NumTargets`) | ⇒ **`S = NrCores × NrHarts ≤ 8`** |
| `--uart-model ns16550a\|none` | `ns16550a` | `ariane-linux.dts` |
| `--uart-freq HZ` / `--uart-baud N` | `50000000` / `115200` | DTS |
| `--ai-island on\|off\|auto` | `auto` = `AiCfg.MatrixEn` | window `0x4000_0000`, 4 KiB, **PLIC source 8** |
| `--ai-island-cfg FILE` | `corev_apu/include/g6lc_ai_island_cfg_pkg.sv` | CAP geometry |
| `--l2 auto\|off\|SIZE` / `--l3 auto\|off\|SIZE` | `auto` from `L2En`/`L3En` (auto-sized in `build_config_pkg`) | config |
| `--bootrom FILE\|none` | `none` | zero-stage ROM at `0x1_0000` |

Any `--peripheral-base` / `--mem-size` deviation from the package sets `"faithful": false` in the
model, which propagates the same way `g6lc-virt` does.

---

## 4. OpenSBI / firmware

| Option | Default | Source of truth |
|---|---|---|
| `--fw-mode jump\|payload\|dynamic\|none` | `payload` | `software/smt2-linux/` contract |
| `--fw ELF\|BIN` | `$CVA6_LINUX_PAYLOAD` if set, else built | prebuilt `fw_payload.elf` / `fw_jump.bin` |
| `--opensbi-src DIR` | fetched to `out/opensbi` | `software/smt2-linux/scripts/fetch-opensbi.{sh,ps1}` |
| `--opensbi-ref TAG` | **`v1.5`** (≥1.4 required) | `pins.toml` |
| `--opensbi-platform ID` | `generic` | `PLATFORM=generic` — no vendor platform C |
| `--fw-text-start ADDR` | `0x8000_0000` | `FW_TEXT_START` |
| `--fw-fdt DTB\|auto` | `auto` (the DTB just generated) | `FW_FDT_PATH` |
| `--fw-payload FILE` | dual-hart SBI smoke, or `$LINUX_IMAGE` | kernel `Image` / S-mode ELF |
| `--fw-jump-addr ADDR` / `--fw-jump-fdt-addr ADDR` | mode-dependent | `fw_jump` |
| `--opensbi-make VAR=VAL` (repeatable) | — | passthrough: `CROSS_COMPILE=…`, `FW_OPTIONS=…` |
| `--opensbi-allow-no-pie` | off | the `riscv-none-elf-` non-PIE Makefile path (`OPENSBI_ALLOW_NO_PIE=y`) |
| `--build-fw` | off | invoke `software/smt2-linux/scripts/build-opensbi-smt2.{sh,ps1}` when in-repo |
| `--fw-out DIR` | `g6lc_qemu/out/fw` | honours `$SMT2_LINUX_OUT` when set |
| `--sbi-extension NAME=on\|off` | all discovered | limit/report the SBI extensions offered to S-mode (`hsm`, `time`, `ipi`, `rfence`, `srst`, `pmu`) |
| `--fw-print-region` | off | dump the firmware/DTB/payload layout before boot |

**Composition, not a fork.** The existing in-tree OpenSBI profile is authoritative: `PLATFORM=generic`,
`FW_TEXT_START=0x80000000`, `FW_FDT_PATH=<target>.dtb`, OpenSBI pinned at **v1.5**, and the
environment contract `CVA6_LINUX_PAYLOAD` / `LINUX_IMAGE` / `SMT2_LINUX_OUT`. `g6q fw` *drives* those
scripts when the monorepo is present and falls back to its own fetch/build when standalone. It never
reimplements the profile.

**HSM / secondary harts.** With `S > 1`, the emulator parks secondaries until SBI HSM start, exactly
as the dual-hart payload (`software/smt2-linux/payload/smt2_sbi_dual.S`) expects. `--sbi-extension
hsm=off` is available specifically to reproduce the failure mode where a secondary never starts.

```bash
# R3a-shaped: OpenSBI + dual-hart SBI smoke on smt2, everything from the repo
g6q run --target g6lc64_smt2 --os opensbi-smoke --build-fw

# Bring your own firmware and DTB, no repo at all
g6q run --config-pkg ./g6lc64_smt2_config_pkg.sv --dtb ./ariane-smt2.dtb \
        --fw ./fw_payload.elf --fw-mode payload
```

---

## 5. OS / kernel / rootfs

| Option | Default | Notes |
|---|---|---|
| `--os PROFILE` | `opensbi-smoke` | `baremetal`, `opensbi-smoke`, `buildroot`, `ubuntu`, `debian`, `fedora`, `custom` — see [`os-linux-matrix.md`](os-linux-matrix.md) §3 |
| `--kernel FILE` | `$LINUX_IMAGE` | Linux `Image` / `vmlinux` |
| `--initrd FILE` | — | initramfs |
| `--rootfs FILE` | — | disk image; **implies `--machine g6lc-virt`** |
| `--rootfs-format raw\|qcow2` | inferred | |
| `--drive FILE[,if=virtio,format=…]` (repeatable) | — | `g6lc-virt` only |
| `--append "STR"` | from `/chosen/bootargs` | merged into the DTS `chosen` node |
| `--maxcpus N` | `S = NrCores × NrHarts` | bounded by `--plic-targets`/2 ⇒ ≤ 8 |
| `--console uart\|virtio` | `uart` | `virtio` implies `g6lc-virt` |
| `--serial stdio\|file:PATH\|tcp:PORT\|null` | `stdio` | |
| `--netdev user\|tap\|none` | `none` | `user` implies `g6lc-virt` |
| `--net-fwd HOSTPORT:GUESTPORT` (repeatable) | — | with `--netdev user` |
| `--ssh-port N` | — | sugar for `--net-fwd N:22` |
| `--virtio blk,net,rng,9p,console` | — | `g6lc-virt` only |
| `--elf FILE` | — | bare ELF with `tohost`/`fromhost` harness semantics |
| `--exit-on-tohost` | on with `--elf` | mirrors the testharness exit convention |
| `--timeout SECONDS` / `--max-instret N` | none | bounded runs for CI |

**The rule this section exists to enforce:** anything that needs a disk or a NIC forces
`g6lc-virt`, and `g6q` says so on stderr the first time it happens rather than silently switching
profiles.

---

## 6. Execution, backend, accel

| Option | Default | Notes |
|---|---|---|
| `--backend args\|qemu\|rust` | `qemu` if available, else `rust` | B0 / B1+B2 / B3 ([`backends.md`](backends.md)) |
| `--qemu-bin PATH` | from `$PATH` / `doctor` | stock or generated |
| `--qemu-src DIR` | `g6lc_qemu/qemu` (gitignored) | emission target for B1/B2 |
| `--accel tcg` | `tcg` | the only value; host-hypervisor accel is a recorded non-goal |
| `--smp auto\|N` | `auto` = `NrCores × NrHarts` | MTTCG threads |
| `--tcg-tuning default\|tuned` | `tuned` | TB cache / chaining / softmmu sizing from the model |
| `--icount N\|off` | `off`; forced on by `--deterministic` | |
| `--deterministic` | off; implied by `--tandem`/`--record` | fixed instructions-per-`mtime`-tick, seeded device timing |
| `--gdb PORT` | — | gdbstub |
| `--trace-uart FILE` | — | raw console capture |

---

## 7. Diagnosis

| Option | Default | Notes |
|---|---|---|
| `--diag off\|d1\|d2\|full` | `off` | [`diagnosis.md`](diagnosis.md) |
| `--rvfi-out FILE` | — | `st_rvfi`-shaped trace |
| `--tandem spike\|verilator\|none` | `none` | implies `--diag d1 --deterministic --conform strict` |
| `--tandem-ref PATH` | — | Spike binary, or an RTL `st_rvfi` trace |
| `--stop-on-divergence` | on with `--tandem` | exits non-zero + `divergence.json` |
| `--record FILE` / `--replay FILE` | — | MMIO + IRQ record/replay keyed on `(hart, instret)` |
| `--checkpoint-at instret=N\|pc=ADDR\|uart="STR"` | — | trigger |
| `--checkpoint-out DIR` | — | Verilator-resumable state (**`g6lc-soc` only**) |
| `--pmu-out FILE` | — | `mhpmcounter` dump, groups 0–4 |
| `--uarch-out FILE` | — | D2 structure hit/miss profile |
| `--allow-virt-diag` | off | required to run `diag`/`tandem` under `g6lc-virt`; taints output |

Every diagnosis artifact carries `"evidence": false` and a pointer to
`architecture/multi-threading/testharness-proxy.md`.

---

## 8. Emission

| Option | Values |
|---|---|
| `--emit` | `model`, `args`, `dtb`, `dts`, `qemu-machine`, `qemu-plugin`, `all` |
| `--emit-dir DIR` | default `out/emit/<target>/` |
| `--check` | re-emit to a temp dir and diff; non-zero on drift (CI gate) |

```bash
g6q gen --target g6lc64_ooo_server --emit all --emit-dir out/emit/ooo-server
g6q gen --target g6lc64_ai --emit qemu-machine --qemu-src ./qemu --check
```

---

## 9. Worked invocations

```bash
# 1. Day-one: OpenSBI + buildroot on stock QEMU, faithful DTS, capability delta printed
g6q run --target g6lc64_smt2 --backend args --os buildroot \
        --kernel $LINUX_IMAGE --build-fw

# 2. Faithful SoC, generated machine, dual-core SMT2 Linux with correct topology
g6q run --target g6lc64_server_math_v --backend qemu --machine g6lc-soc \
        --smp auto --os buildroot --kernel Image --initrd rootfs.cpio \
        --append "console=ttyS0 earlycon maxcpus=4"

# 3. Ubuntu userspace over SSH (software-valid only; profile is stamped)
g6q run --target g6lc64_ooo_server --machine g6lc-virt \
        --os ubuntu --kernel Image --rootfs ubuntu-riscv64.img \
        --netdev user --ssh-port 2222 --mem-size 4G --smp 8

# 4. Tandem a directed test against Spike, stop at first divergence
g6q tandem --target g6lc64_smt2 --elf verif/tests/custom/multicore/mini_amocas_d.elf \
           --tandem spike --tandem-ref $(which spike) --json-out div.json

# 5. Bisect a boot hang, then hand a checkpoint to Verilator
g6q run  --target g6lc64_smt2 --os opensbi-smoke --deterministic --record boot.rec
g6q diag --target g6lc64_smt2 --replay boot.rec --checkpoint-at uart="_start_hang" \
         --checkpoint-out ckpt/

# 6. ai-tensor inside the guest against the generated island
g6q run --target g6lc64_ai --ai-island on --os buildroot \
        --initrd ai-tensor-initramfs.cpio --pmu-out pmu.json

# 7. Microarchitectural profile of a workload
g6q diag --target g6lc64_stream8 --diag d2 --elf bench.elf \
         --uarch-out uarch.json --pmu-out pmu.json

# 8. Just tell me what disagrees
g6q conform --target g6lc64_server_math_v
```

---

## 10. Standalone operation

No option above *requires* the monorepo. `--repo-root` derives paths from a target id as a
convenience; without it, `--config-pkg`, `--flist` + `--set`, `--soc-map`, `--dts`/`--dtb`, `--fw`
and `--kernel` fully specify a machine. This is the independence invariant
([`README.md`](README.md) §6.6) made operational: the package is usable against any LibreCore-shaped
tree, a fixture, or a downstream fork, with no `build-platform` and no this-repository dependency.

An optional host adapter (`build-platform` `qemu` command, mirroring `timings.ts`) is **Q8 and
optional**; the package must never require it.
