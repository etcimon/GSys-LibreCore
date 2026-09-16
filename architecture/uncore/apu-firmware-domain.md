# APU firmware domain and boot ownership

**Domain:** graphics uncore · **Status:** protected-service design; bring-up wiring only

Review baseline: `d74010111d7f9d78e32e75fd64f4ea07c3323fcc` (2026-09-15).
EGL/GLES remain in clients. The APU service validates commands, manages resources
and compiles shaders; only the dedicated APU executes graphics stages.

## Current implementation versus required protection

| Seam | Present | Not established |
|---|---|---|
| Configuration | `apu_soc_legal`, `apu_domain_legal`, NAPOT/order helpers; two physical cores, `NrHarts=1` | Actual PMP programming or isolation |
| Firmware placement | `ApuHarness`: hart 1, RAM `0x90000000` / 256 KiB, control `0x40002000` / 4 KiB | RAM access firewall, image authentication, production loader |
| Application device | Guest `0x40001000` / 4 KiB; PLIC source 9 (AI remains source 8) | Working virgl device or coherent DMA |
| Boot | `PerCoreBoot`, firmware hex preload and CVA6 commit/cookie tests | An OpenSBI-launched S-mode service surviving Linux boot |
| Domain overlay | Opt-in `ariane-g6lc-apu.dts` includes `g6lc-apu-domain.dtsi` | Overlay selects `next-mode=3` (M-mode), not the intended S-mode payload |
| Source grant | `g6lc_apu_grant` compares supplied source/hart and full control address | The testharness supplies a constant firmware tag; this is not authentication |

The overlay's M-mode permissions and direct reset into firmware are diagnostic
scaffolding, **not** the deployment contract. Do not enable the Linux GPU node or
claim source isolation from these tests. A DT omission or `reserved-memory` alone
is not access control. Firmware RAM currently has no source input at all.

## Target boot contract (not yet implemented)

OpenSBI remains the trusted M-mode supervisor. The parser/compiler service runs
as an isolated S-mode payload on a reserved physical hart. Linux cannot acquire
that hart through its CPU topology or SBI HSM operations. All application harts
keep their normal boot path. No SMT reservation, CPU pipeline change or
`build-opensbi-smt2.sh` policy change is required by the APU plan.

Two provisioning paths converge on **one service image and runtime ABI**:

1. **Platform-managed:** trusted ROM/platform loader verifies and loads the
   configured APU image, establishes domains and starts it before Linux probes.
   `g6lc_bios` is not required to build, boot or operate the APU.
2. **Optional BIOS-managed:** BIOS stages/selects a compatible APU image and asks
   the trusted supervisor to validate, load and start the reserved service. The
   BIOS UI is not the service runtime, is not granted parser execution in M-mode,
   and does not gain unrestricted RAM/control access. Cross-domain start/restart
   needs an explicit bounded supervisor interface; ordinary Linux-domain HSM is
   not assumed to start a hart belonging to another domain.

Required start sequence:

- Stop admission and prove device/child DMA idle before any image replacement.
- Validate manifest/image identity, lengths, entry, privilege, ABI/native ISA,
  required RTL configuration and capability-profile compatibility. Digest/CRC
  alone is not authenticity; signature trust and rollback policy are separate.
- Load file-backed segments, initialize BSS/stack/workspace, perform required
  cache maintenance and instruction synchronization, then install protection.
- Grant firmware RAM/code/data and private control to the correct domain only;
  control is non-executable. Resolve actual OpenSBI revision/permission encoding,
  PMA attributes, PMP entry budget and root-domain exclusions before changing the
  template. Guest backing access must be bounded by the DMA/resource policy.
- Start the service in S-mode, collect versioned readiness for this boot instance,
  then expose only implemented virtio features. No `#1` preload delay or cookie
  is a hardware-ready signal.

The fabric must carry trusted source/domain metadata through arbitration and
buffering. AXI transaction ID and PROT are not intrinsically hart identity. If
cluster aggregation loses provenance, enforce protection before that loss or
introduce a verified metadata seam; never reconstruct it from an address.
Both control and RAM need adversarial application-hart and DMA denial tests.

## Minimal BIOS/Linux boot-health commonality

This is the only coordination required with the recoverable-BIOS plan
`plan-c06f2ee19717de0d.md`; the APU implementation has an independent update cycle.
Existing `g6b-bootctl` provides Linux/Firmware tickets and a redundant journal;
`g6b-boot-health` checks Linux root/services/watchdog readiness and discovers a
journal window through `/firmware/g6b-boot-health`. These do **not** implement an
APU service-health protocol. `Domain::Firmware` is BIOS-candidate health, not an
available APU namespace. Do not reinterpret v1 records or share a concurrently
written journal between BIOS, Linux and APU firmware.

Proposed adapter input, to be versioned before implementation: service image
identity, firmware/native-ISA ABI, hardware/config/capability identity, fresh
boot-instance nonce, device epoch, client-owner generation, lifecycle state,
self-test result and progress/fault counters. This is a status contract, not an
existing MMIO layout, FDT binding or SBI extension. A stale cookie/heartbeat must
not satisfy it. Publish a sanitized immutable handoff; Linux gets no private
firmware pointers, write grants or secret material.

- BIOS decides whether graphics is **optional** (default) or an explicit boot
  prerequisite. Optional APU failure degrades to serial/recovery and keeps the
  device disabled; it does not globally turn a healthy Linux boot into failure.
- APU-ready, successful hardware graphics self-test, BIOS-candidate confirmation
  and Linux-attempt confirmation are four different observations. Only the
  existing Linux readiness policy acknowledges the exact Linux attempt. None
  clears an operator inhibit or enables autoboot.
- A future required-graphics policy may use an ordinary DRM/EGL probe as one
  required-service predicate. DRM presence and a cached cookie are insufficient;
  hardware completion/output and no-fallback evidence are required for APU proof.
- A service heartbeat is not ownership of the platform boot watchdog. Linux
  takeover must have a proven no-gap watchdog path; the current file mock is not
  hardware watchdog evidence. APU recovery must not feed away a broken Linux boot.
- No post-Linux BIOS web/KVM loop is retained just to service graphics. The APU
  domain persists independently after BIOS management clients stop.

## Client ownership and recovery

Use BIOS and Linux as sequential virtio clients of the same device, not concurrent
private-mailbox owners. Before Linux entry: BIOS stops submissions, drains all
leases and display references, resets queues/device state and records a fresh
owner generation. Linux negotiates from clean virtio state; queue addresses and
BIOS context IDs are not inherited. A frozen presentation surface may survive
only via a separate explicit scanout lease, not a reusable guest mapping.

A guest virtio reset clears guest resources/epochs after drain; it is not permission
to overwrite firmware or reset a live AXI fabric. Firmware restart is supervisor
owned, revokes admission and waits for drain. Protocol quarantine requires a
coordinated fabric reset. On timeout, remain failed/isolated; do not free backing
or synthesize success. kexec, warm reset, service crash and failed image rollback
must follow the same ownership rules.

## Evidence and next acceptance

Historical directed evidence at the baseline commit: domain 26 checks;
`run-th-osbi.sh` 27 checks / 4 clocks; CVA6 DRAM-load-address 13/286;
UART, CLINT and PLIC stub stores 12/288, 12/288 and 12/290. Those last four
payloads are **not OpenSBI ELFs**, real timer/interrupt operation or Linux boot.

Next gate: real pinned OpenSBI → protected S-mode service + application Linux,
with source/RAM denial, correct topology/reserved-memory, service readiness and
reset fault injection. Run through the remote testharness proxy. See
`apu-firmware-ram.md`, `apu-resident-fw.md`, `apu-fw-exec.md` and
`apu-testharness-load.md`; generic synthesis is not PMP, CDC, STA or DFT sign-off.
