# `g6lc_qemu` — OpenSBI modes, OS profiles, and the Linux capability matrix

Parent: [`README.md`](README.md) · Options: [`cli.md`](cli.md) §4–§5 · Profiles:
[`backends.md`](backends.md) §2.

This document answers two questions. **What does it take to boot a given OS on a given LibreCore
configuration?** And, at Q9, **which Linux-visible capabilities does that configuration actually
deliver?**

---

## 1. The boot chain

```text
  [bootrom @0x1_0000]        optional; --bootrom
        │
        ▼
  OpenSBI  (M-mode)          PLATFORM=generic · FW_TEXT_START=0x8000_0000 · FW_FDT_PATH=<dtb>
        │                    pinned v1.5 (≥1.4 required)
        ├─ fw_jump  ──────►  next stage at --fw-jump-addr, FDT at --fw-jump-fdt-addr
        ├─ fw_payload ────►  payload linked in: dual-hart SBI smoke, or Linux Image
        └─ fw_dynamic ────►  next-stage info struct from the loader
        │
        ▼
  S-mode payload             Linux Image | smt2_sbi_dual.S | custom ELF
        │
        ▼
  userspace                  initramfs | virtio rootfs
```

The in-tree profile is authoritative and is **driven, not reimplemented**
(`software/smt2-linux/README.md`, `architecture/multi-threading/smt-linux-rootfs.md`):

| Item | Value |
|---|---|
| Platform | `PLATFORM=generic` — no vendor platform C, same as upstream OpenSBI "Ariane FPGA" |
| Text start | `0x8000_0000` |
| FDT | `FW_FDT_PATH=<target>.dtb`, generated or from `corev_apu/bootrom/` |
| OpenSBI | **v1.5** pin, ≥ 1.4 required |
| Env contract | `CVA6_LINUX_PAYLOAD`, `LINUX_IMAGE`, `SMT2_LINUX_OUT`, `CROSS_COMPILE` |
| Non-PIE path | `OPENSBI_ALLOW_NO_PIE=y` for `riscv-none-elf-` toolchains |
| Products | `fw_payload.elf` under `$SMT2_LINUX_OUT` / `build-platform/workspace/smt2-linux/` |

## 2. OpenSBI modes and what each is for

| `--fw-mode` | Use | Notes |
|---|---|---|
| `payload` (default) | R3a/R3b-shaped runs; the dual-hart SBI smoke; Linux `Image` embedded | matches the existing profile most closely |
| `jump` | separately loaded kernel; iterating on the kernel without rebuilding firmware | needs `--fw-jump-addr`, `--fw-jump-fdt-addr` |
| `dynamic` | a loader supplies the next-stage struct | for U-Boot / FIT experiments (cva6-sdk shape) |
| `none` | bare-metal ELF via `--elf`, tandem, directed tests | no M-mode firmware at all |

**HSM and secondary harts.** With `S = NrCores × NrHarts > 1`, secondaries park until SBI HSM start,
which is what `software/smt2-linux/payload/smt2_sbi_dual.S` exercises. Two deliberately reproducible
failure modes: `--sbi-extension hsm=off` (secondary never starts) and `--maxcpus 1` (kernel ignores
them). Both are real bring-up bugs worth being able to stage on demand.

**SBI extensions modelled:** `base`, `time`, `ipi`, `rfence`, `hsm`, `srst`, and `pmu` (the last one
matters — `perf` in the guest goes through SBI PMU, and it must agree with the `mhpmevent` mapping in
[`diagnosis.md`](diagnosis.md) §5).

---

## 3. OS profiles

`--os PROFILE` sets defaults; every one of them can be overridden by the explicit options in
[`cli.md`](cli.md) §5.

| Profile | Machine | Firmware | Payload | Storage / net | What it proves |
|---|---|---|---|---|---|
| `baremetal` | `g6lc-soc` | `none` | `--elf` | none | directed tests, tandem, `tohost` harness semantics |
| `opensbi-smoke` | `g6lc-soc` | `payload` | dual-hart SBI smoke | none | firmware + DTB + hart topology; the R3a-shaped gate |
| `buildroot` | `g6lc-soc` | `payload` | Linux `Image` | initramfs | **the faithful full-stack profile** — Linux to a shell on the real memory map |
| `ubuntu` | **`g6lc-virt`** | `payload`/`jump` | distro `Image` | virtio-blk + virtio-net | a real distro userspace: apt, glibc, a native compile |
| `debian` | **`g6lc-virt`** | as above | distro `Image` | virtio | second distro, catches Ubuntu-specific assumptions |
| `fedora` | **`g6lc-virt`** | as above | distro `Image` | virtio | third; RISC-V-forward packaging |
| `custom` | as given | as given | as given | as given | escape hatch; nothing implied |

### 3.1 Why distros force `g6lc-virt`

The faithful SoC map (`corev_apu/tb/ariane_soc_pkg.sv`) has **no PCI and no virtio**. It has SPI
(`0x2000_0000`) and Ethernet (`0x3000_0000`) windows, but those are not a Linux storage stack you can
put a multi-gigabyte rootfs on, and DRAM is `DRAMLength` = **1 GiB** (512 MiB with `NEXYS_VIDEO`).
A Ubuntu server rootfs needs a block device, a network, and comfortably more RAM.

That is a property of the silicon, not a defect to route around. So:

- `buildroot` on **`g6lc-soc`** is the profile that answers hardware questions. Initramfs, no disk,
  real memory map. This is the profile whose results mean something about the design.
- `ubuntu`/`debian`/`fedora` on **`g6lc-virt`** answer *software* questions: does this ISA / CSR /
  PMU / SBI surface satisfy a real distribution and its toolchain? Valid and valuable — and
  **invalid** for SoC-map, interrupt-topology, timing or diagnosis claims.

`g6q` prints the switch on stderr the first time a profile forces `g6lc-virt`, stamps
`"profile": "g6lc-virt"` into every artifact, and `diag`/`tandem` refuse it without
`--allow-virt-diag`.

### 3.2 Getting distro images

Not vendored, not fetched silently. `g6q doctor --os ubuntu` prints what is needed (a `riscv64` kernel
`Image` + a rootfs image), and the docs record the shapes that are known to work. The cva6-sdk
(U-Boot + FIT) path from `smt-linux-rootfs.md` R3c remains the FPGA route; the emulator uses the
simpler `Image` + rootfs form.

---

## 4. Linux-cap reference points (do not regress these)

From [`../multi-threading/linux-boot-scale.md`](../multi-threading/linux-boot-scale.md) §1 — the live
bar the emulator should be able to reproduce, and must never be presented as replacing:

| Package | N | T | I | RVV | CVXIF | RVH | `S=N×T` | Live Linux-cap (Verilator, I4dp) |
|---|---|---|---|---|---|---|---|---|
| `g6lc64_smt2` | 1 | 2 | 2 | 0 | 1 | 0 | 2 | cookie path; FDT walk residual |
| `g6lc64_server_math_v` | 2 | 2 | 2 | 1 | 0 | 1 | **4** | `tohost=0` @ 200M |
| `g6lc64_ooo_server` | 4 | 2 | 4 | 0 | 1 | 1 | **8** | `tohost=0` @ 200M |
| `g6lc64_stream8` | 2 | 1 | 1 | 0 | 1 | 1 | 2 | CRT/H-edge |

Standing constraints: PLIC `NumTargets=16` ⇒ **`S ≤ 8`**; `CVA6_MAX_SMT_HARTS = 2`; **issue width is
not a hart** and never appears in DTS.

---

## 5. Q9 — the Linux capability matrix

The Q9 deliverable is a runnable suite that fills this table **per target**, from inside the guest.
A capability the target does not have yields `N/A` (from the conformance report), not a failure —
the matrix measures *the implementation*, not an ideal.

| # | Capability | Config knob(s) | DTS token / node | In-guest observation | Profile |
|---|---|---|---|---|---|
| 1 | Base RV64GC boot | `XLEN`, `RVC`, `RVF`, `RVD` | `riscv,isa-base`, `riscv,isa` | shell prompt; `uname -m`; `/proc/cpuinfo` isa | soc |
| 2 | SMP / SMT topology | `NrCores`, `NrHarts`, `SmtPolicy` | `cpu-map` cluster/core/thread | `lscpu` core/thread counts; `taskset` spread; `/proc/interrupts` per-CPU | soc |
| 3 | HSM secondary bring-up | `NrCores`×`NrHarts` | `cpu@N` `status` | all `S` CPUs online; `echo 0 > .../cpuN/online` and back | soc |
| 4 | Sv39 paging + TLB | `mmu-type`, `*TlbEntries` | `mmu-type`, `tlb-split` | fork/mmap stress; `stress-ng --vm`; no spurious faults | soc |
| 5 | Zba / Zbb / Zbs | `RVB` | `zba,zbb,zbs` | isa string; `hwprobe`; bitmanip micro-benchmark speedup | soc |
| 6 | ZKN crypto | `ZKN` | `zkn` | `openssl speed`; kernel crypto selftests | soc |
| 7 | Zacas (incl. `amocas.q`) | `RVZacas` | `zacas` | 128-bit `__atomic` CAS; `stress-ng --atomic` | soc |
| 8 | Zicbom / Zicboz / Zicbop | `RVZiCbo*` | `zicbom`,`zicboz`,`zicbop`, `riscv,cb*-block-size` | DMA-coherency test; `memset`/`bzero` throughput | soc |
| 9 | Sstc supervisor timer | `SstcEn` | `sstc` | timer IRQ without SBI TIME calls; `/proc/timer_list` | soc |
| 10 | Sscofpmf + PMU | `SscofpmfEn`, `RVZihpm` | `riscv,pmu` `event-to-mhpmevent` | `perf stat` returns groups 0–4; `perf record` overflow IRQ fires; `scountovf` | soc |
| 11 | Svpbmt | `SvpbmtEn` | `svpbmt` | non-cacheable userspace mapping of an MMIO window | soc |
| 12 | Zawrs | `ZawrsEn` | `zawrs` | contended-lock benchmark; `wrs.nto` path taken | soc |
| 13 | Zihintpause | `ZihintpauseEn` | `zihintpause` | spin-loop `pause` decoded as NOP, no D$ fence flush | soc |
| 14 | Hypervisor / KVM | `RVH` | `h` | `kvm-ok`-equivalent; nested guest boot on `_v` / `ooo_server` | soc |
| 15 | Sstc × H guest timers | `SstcEn` + `RVH` | `sstc`, `h` | `vstimecmp`/`htimedelta` under a nested guest | soc |
| 16 | RVV / Ara | `RVV` + `Flist.ara` | `v`, `zve64d` | vector memcpy; **`stub` verdict if the flist lacks Ara** | soc |
| 17 | `Xg6lcai` | `AiCfg.MatrixEn` | `xg6lcai`, `g6lc,ai-matrix` | ai-tensor UIO `gemm_s8` vs INT8 golden; PMU group 4 moves | soc |
| 18 | L2 / L3 / prefetch | `L2En`, `L3En`, `HwPrefetchEn` | cache nodes | streaming bandwidth; PMU group 2 (L3 hit/miss, PF issue/train) | soc |
| 19 | PLIC / CLINT | `NumSources`, `NumTargets` | `sifive,plic-1.0.0`, `clint0` | `/proc/interrupts` distribution; IRQ affinity moves | soc |
| 20 | Debug triggers | `DebugEn` | — | `gdb` hardware breakpoint via `--gdb` | soc |
| 21 | Distro userspace | — | — | Ubuntu/Debian boot to login, `apt`, a native `gcc` compile, SSH in | **virt** |
| 22 | Network stack | — | virtio-net | `ping`, `curl`, `iperf3` | **virt** |
| 23 | Block storage + fs | — | virtio-blk | `ext4` mount, `fio` smoke | **virt** |

Every row records: verdict (`Pass` / `Fail` / `N/A`), the conformance verdict that produced `N/A`, the
observation command, and the raw output. Failures are triaged to one of three places — **config**
(knob off or illegal), **DTS** (undeclared / overdeclared), or **RTL** (a real bug, which then goes to
Verilator for evidence).

Rows 1–20 are the ones that say something about the implementation. Rows 21–23 are the "can it host a
real OS" question and are permanently tainted `virt`.

---

## 6. What a green matrix does and does not mean

**Does mean:** this configuration's ISA, CSR, SBI, interrupt and PMU surface is coherent enough that a
real Linux — and, for rows 21–23, a real distribution — uses it correctly; and the `.dts` ↔ config ↔
spec triple holds for a third independent consumer, which is a genuinely strong statement about
[`../../AGENTS-dts-validation.md`](../../AGENTS-dts-validation.md) alignment.

**Does not mean:** the RTL is correct, the design meets timing, the counters are accurate, or anything
about cycles. Nothing here is citable as a soak, peel, pin or Linux-cap result — the bar in §4 stays
where it is, on the builder, through the proxy
([`../multi-threading/testharness-proxy.md`](../multi-threading/testharness-proxy.md)).
