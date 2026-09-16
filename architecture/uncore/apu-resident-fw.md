# APU resident firmware

**Domain:** graphics uncore · **Status:** bring-up images; production command service remains open

The firmware is an independently built device-control program in
`software/apu-fw`, not part of the BIOS UI, Linux virtio-gpu driver or Mesa.
Its permitted work is bounded decoding/validation, resource management,
queue scheduling and shader compilation. Vertex processing, rasterization,
texture sampling, fragment shading and pixel generation execute on APU RTL.

## What the committed images prove

| Image | Actual behavior at `d74010111` |
|---|---|
| `apu_fw.elf` / `apu_fw.hex` | Programs a TID+IADD native job; peeks 10/11; cookie `0x600D000A` |
| `apu_tgsi_fw.elf` / `apu_tgsi.hex` | Pre-encoded MOV shader job; cookie `0x600D000B`; no compiler |
| `apu_tgsi_cc.elf` / `apu_tgsi_cc.hex` | Links compiler/job code, but the RISC-V path scans opcodes and substitutes frozen MOV output; cookie `0x600D000B` |

A mini-hart model and directed CVA6 tests fetch these images from firmware
RAM. They are not a protected S-mode service, virtqueue decoder or stock-driver
renderer. A source-linked compiler with a target-only opcode stub is not
host/target compiler parity. See `apu-tgsi.md`.

## One service, two optional loading policies

The production artifact must have a manifest naming image length/digest,
entry, privilege, load/BSS/stack requirements, firmware ABI, native ISA,
RTL configuration and supported compatibility profile. No compiler-supplied
capability declaration may enable functionality absent from RTL.

- A platform loader can provision/start this image without `g6lc_bios`.
- BIOS can optionally select/stage the same artifact and invoke a bounded
  trusted-supervisor loader/start interface. The reserved hart runs the same
  service after Linux takes over. This is independent management, not a
  requirement to link firmware C into BIOS Rust or synchronize both releases.
- OpenSBI owns M-mode and domain/HSM policy; the service is S-mode. Do not
  parse untrusted virgl in M-mode. The current direct reset and M-mode DTS
  overlay remain diagnostics until a real S-mode launch is verified.

Loader, domain, reset and health responsibilities are defined once in
`apu-firmware-domain.md`. `crt0.S` currently sets SP and calls main; it does
not establish a production BSS/trap/privilege/interrupt/ready contract.
Hex preload and `fw_ready=#1` are not deployment loading mechanisms.

## Service-loop completion gates

1. Bring up a real trap/stack/BSS environment and deterministic initialization
   of resource/program validity. Do not rely on simulation-zeroed SRAM.
2. Establish runtime ABI/config/image identity and fresh instance readiness.
   Readiness is a completed bounded initialization/self-test, not a cookie
   from a previous firmware instance. Expose progress/fault diagnostics.
3. Consume both standard virtqueues through checked snapshots; validate
   descriptor chains, byte counts, continuations, object namespaces and
   resource lifetime before submitting native work. No descriptor-chain
   semantics are inferred from the flat virtio-gpu backing SG table.
4. Bound allocator/compiler/decoder work and enforce per-context quotas and
   deadlines. Interrupts enqueue/ack; long compilation never starves reset,
   completion or recovery service. Return deterministic standard errors.
5. Use the same semantic compiler on host and CVA6. Preserve program and
   resource identity through the combined memory/exec scheduler and issue
   used/fence publication only after execution and cache visibility.
6. Prove service restart, failed image load, stale request, queue reset and
   watchdog recovery with work outstanding. Keep mappings pinned during drain;
   protocol quarantine is not released by clearing a software variable.

## Boot-health adapter boundary

The BIOS plan's `g6b-bootctl`/`g6b-boot-health` already separate Linux-attempt
acknowledgement from firmware-candidate health and operator inhibition.
Reuse those principles and a versioned status adapter, not their private
structures or journal offsets. APU service status is a distinct namespace;
G6BH v1 has no APU domain. The APU must not write the Linux journal, choose
BIOS slots, enable autoboot or assume ownership of the platform watchdog.

Optional graphics failure leaves serial/recovery usable and the device off.
Only explicit required-graphics policy may delay Linux confirmation for a
real hardware graphics probe. Firmware alive, DRM bound, successful GPU work
and Linux healthy are separate facts. The existing BIOS live-Linux/watchdog
gates remain independent and incomplete until actually demonstrated.

## Evidence

Historical remote evidence: native encoding and host TGSI tests pass;
resident BFM 179 checks / 739 clocks; mini-hart 186 / 3,077; CVA6 cookie
14 / 1,835; CVA6 target-stub TGSI image 14 / 10,511. These results are
bring-up evidence only. Reproducible acceptance must rebuild the ELF/hex from
pinned source/toolchain and verify hashes, not silently use a checked-in hex
when compilation is skipped. Runs and limitations belong in the root
traceability records rather than a new chronological plan milestone.
