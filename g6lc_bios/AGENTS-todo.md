# g6lc_bios — live todo

Green commands: `python tools/g6b.py check` (independence + Bun tests/build + fmt + clippy + workspace tests), then `python tools/g6b.py regress` (separate BIOS/transport regression).

Web-engine endpoint (one BrowserSession, one LDC cell; B82–B91d landed —
[`architecture/plan-endpoint.md`](architecture/plan-endpoint.md) §15 leftovers:
`WasmJit` names, QMP shots). Track-B 4bpp `ui_ppm` is a live-Engine downsample.
Work tree **`E:\cva6/g6lc_bios`**.

## Recovery-first program — foundation increment (2026-09-14)

- [x] `g6b-bootctl`: allocation-free `no_std` boot-attempt protocol and redundant
      journal; strict version/length/reserved/CRC checks, nonce/target/image
      identity, sticky failure policy, exact Linux readiness acknowledgement.
- [x] Fault injection found and fixed two admission hazards: an initial I/O
      failure leaving the cached Boot decision usable, and losing a newer
      in-progress record resurrecting an older healthy record's boot permission.
      Degraded records now hold recovery, not silently fall back to autoboot.
- [x] `g6b-runtime-abi`: checked versioned request header, generational context,
      spans and non-aliasing output. Operations are vocabulary only, not services.
- [x] Kernel/VFS journal adapter bounds writes to two declared slots and requires
      explicit durability. `FileBlock::flush` now calls OS `sync_all`, not the
      non-durable `File::flush`. Disposable-file reopen/neighbour tests pass.
- [x] 17 boot-control + 6 ABI + 2 adapter tests; VFS 39/39. Both new libraries
      cross-check on `riscv64imac-unknown-none-elf` with Rust 1.85.0 (target install
      approved by the user). No external crate dependencies or unsafe code added.
- [x] Full `g6b.py check` passed, including independence, browser build/tests,
      fmt, Clippy, workspace tests and BIOS regression with pixel-parity gates.
- [x] Native service-callee ELF (P0 link/entry): `g6b-guest` + `tools/guest_native.py`
      emit a labelled `native-service-callee-not-bootable-firmware` RV64IMAC
      image (RX/R file-backed PT_LOAD only; no RW/BSS/WX/dynamic). `g6b elf
      --native-manifest` composes it as extra PT_LOADs; `e_entry` stays the
      generated ASM BIOS. A `Purpose::NativeService` probe `jalr`s the callee
      with a 256-byte ABI frame (SIE masked) and prints `NATIVE-SERVICE-OK`.
      **QEMU 8.2.2 virt + OpenSBI 1.3:** composed
      `out/native/g6lc_bios-native.elf` serial contains `NATIVE-SERVICE-OK`
      (and not `NATIVE-SERVICE-FAIL`). Host tests: `g6b-guest` 5/5,
      `g6b-elf` native parse/composition, `tools/test_guest_native.py`.
      Default `g6b elf` without the manifest is unchanged.
- [x] P1 bounded poll loop (IRQ enqueue / Poll / Cancel): `g6b-guest::service`
      keeps a 128-byte core at ABI frame offset 128 (RX/R callee, no BSS).
      `Input` only enqueues; `Poll` runs a quota in normal context and always
      takes watchdog before slow I/O; `Cancel` is generation-checked and tears
      down only the named context. Host tests 9/9. BIOS probe enqueues
      watchdog+slow with SIE masked, restores SIE, then `Poll`.
      **QEMU 8.2.2 virt:** `NATIVE-SERVICE-OK` and `NATIVE-POLL-OK`.
      Not `alloc`, not wasm/DOM/Asyncify `RuntimeContext`, not a timer-tick
      poll loop after park.
- [x] P2 inhibit-before-autoboot (no durable guest journal yet): `BootStatus`
      and `BootTrial` return `NotReady` without a durable `SlotStorage`.
      BIOS probe requires that, clears `AUTO_ON`, prints `NATIVE-BOOT-HOLD`.
      Host `AutoBoot::with_decision(Stay)` does not arm the countdown and
      ticks never take entry 0. **QEMU 8.2.2 virt:** `NATIVE-BOOT-HOLD`.
      Not virtio-blk write/flush, not 8 KiB G6BH slots on media, not an
      unattended Linux handoff.
- [x] P2 guest virtio-blk write/flush in the journal window: `BlkWrite` /
      `BlkFlush` (`VIRTIO_BLK_T_OUT` / `T_FLUSH`). `BlkInit` accepts
      `F_FLUSH` when offered. Writes outside LBA 8..24 print `BLK-RANGE`
      and do not land. Exec model: `BLK-WRITE-OK`, `blk_flushes>=1`,
      protective MBR `0xAA55` survives. Not installed on the production
      boot path (selftest is test-only). Not 8 KiB G6BH commit, not a
      Linux trial.
- [x] P2 8 KiB G6BH slots on the virtio-blk journal window: `JrnLoad` /
      `JrnCommit` (8-sector rewrite + `BlkFlush` + `G6BH` readback). Host
      `Journal::initialize` plants a fail-closed record at LBA 8; guest
      load/commit keeps `Record::decode` + `Stay(Provisioning)`. Exec
      `the_guest_loads_and_commits_g6bh_slots_on_the_journal_window`.
      `JournalStorage::on_bios_window` is LBA 8. Not QEMU-backed, not a
      Linux trial, not A/B firmware images.
- [x] P2 QEMU-backed journal I/O: UART `Jrn` runs `JrnLoad`+`JrnCommit` on
      a writable virtio-blk scratch disk with a planted G6BH window.
      **QEMU 8.2.2 virt:** `JRN-LOAD-OK` / `JRN-COMMIT-OK`; post-run disk
      still CRC-valid `G6BH` + Provisioning. Avail ring now uses
      `ring[idx % 8]` (the previous always-slot-0 kick timed out the second
      request on real QEMU). Not A/B firmware, not a Linux trial.
- [x] P2 A/B firmware-slot protection: `FirmwareLayout::BIOS` places journal
      at LBA 8..24 and selector stubs A/B at LBA 24..32 / 32..40. Layout
      check rejects overlap and GPT collision. `BlkWrite` still cannot
      land outside the journal window; exec journal commit leaves `G6FA`/
      `G6FB` intact; QEMU `Jrn` disk still has those stubs plus CRC-valid
      G6BH. Not a full SPI image, not `UpdateApply`, not a slot switch.
- [x] P2 inactive-slot stage + select hold: `FwStage` writes firmware B
      only; A/journal/GPT are `FW-RANGE`. `FwSelect` is `FW-HOLD`. Exec
      `the_guest_stages_inactive_firmware_and_refuses_select`. UART `Fws`.
      Not a full image, not a slot switch, not QEMU, not autoboot.
- [x] P2 declared inactive-slot rewrite: `FwCommit` writes all 8 sectors of
      B, flush, first/last readback (`FW-COMMIT-OK`). Recovery A intact.
      Not SPI, not selector rewrite, not QEMU.
- [x] P2 selector rewrite (nominate): `Journal::nominate_inactive` sets
      `Record.staged=B` without clearing inhibit. Guest `FwSelect` writes
      `G6SL` at B+8. Exec `FW-SELECT-OK`. `may_select` still Stay. Not autoboot.
- [x] P2 torn-media fail-closed: `FwSelect` requires first+last B sectors.
      Mixed slot is `FW-HOLD`, no `G6SL`. Interrupted nominate never Boot.
- [x] P1 wasm/DOM/Asyncify `RuntimeContext` table (`g6b-runtime-abi`
      `ContextTable`, 4 slots). Generation-checked handles, independent
      continuations, overlapping wasm windows rejected, teardown isolation.
      Host `g6b-runtime-abi` 12/12. Not an `alloc` heap, not guest
      `__prom`/`P_ASUSP` rewrite.
- [x] P1 guest `__prom` per-context suspend: 4-slot table, `PromCtx`/`P_CTX`.
      Slot 0 aliases `P_ASUSP`/`P_RESUME`. Slot 1 await does not write slot 0.
      `guest_jit_ctx1_suspend_does_not_alias_slot0`. Not an `alloc` heap.
- [x] P1 bounded no_std bump arena (`g6b-runtime-abi::Bump`). Aligned
      `Span`s over caller-owned backing; fail-closed OOM/align/overflow.
      Host 22/22. Not `GlobalAlloc`, not guest BSS, not QEMU.
- [x] P1 timer-tick Poll after park: `__native_abi` BSS, `trap_timer`
      `NativePoll`. Exec `NATIVE-TICK-POLL-OK` once. Not QEMU.
- [ ] P2 leftover: none of the named leftovers (SPI-sized image / boot
      nominated slot stay with later P2–P12 work, not this gate).
- [x] Linux-generic health helper (`g6b-boot-health`): reads the pending
      G6BH attempt, checks `Readiness`, acknowledges only that ticket.
      Does not enable autoboot or write firmware slots. OpenWrt adapter is
      file-based (`openwrt_release` / overlay / stamps), no ubus/procd.
      Tests: premature/wrong attempt, exact confirm leaves Provisioning
      inhibit, OpenWrt readonly-root. Not a Linux handoff, not a live
      OpenWrt VM.
- [x] P11 bundle discovery (no jump): `g6b-boot-health::bundle` accepts only a
      RISC-V `Image` plus explicit initrd, FDT, root= and bootargs.
      Squashfs/UBI are `NotExecutable`. Truncated Image and missing pieces
      are named refusals. Does not load Linux, does not write the journal.
- [x] P11 same-guest Linux entry ABI (canary, not OpenWrt): `LinuxEnter`
      sets `satp=0`, `sie=0`, `a0=tp` (hartid), `a1=FDT`, `jalr` entry.
      Exec `linux_enter_sets_satp0_hartid_and_fdt` → `LINUX-ENTRY-OK`.
      `prepare_attempt` validates the bundle then `Journal::begin`
      (InProgress) without jumping. Not a live kernel, not satp paging.
- [x] P11 relocate Image+FDT into reserved `__linux_load` BSS (does not
      overlap payload/stacks). `LinuxRelocate` refuses overlapping src/dest
      (`LINUX-LOAD-OVERLAP`) then copies and `LinuxEnter`s. Exec
      `linux_relocate_copies_into_reserved_bss_and_refuses_overlap`. Not a
      real OpenWrt Image from disk, not a live VM.
- [x] P11 disk Image load into `__linux_load`: `LinuxLoadDisk` BlkReads
      Image+FDT from LBA 40 (past firmware B), then `LinuxEnter` at
      `dest+text_offset`. Exec `linux_load_disk_reads_image_and_enters` →
      `LINUX-ENTRY-OK`. Not a live OpenWrt VM, not autoboot.
- [x] P11 persist-before-handoff: `LinuxLoadDisk` refuses unless a G6BH slot
      is `InProgress` (`LINUX-HOLD`). Exec hold-without-journal; QEMU `Lnx`
      after `g6b arm-disk` → `LINUX-ENTRY-OK`. Does not clear inhibit or
      enable autoboot.
- [x] P11 watchdog-nowayout: `WatchdogStamp` requires `nowayout=1`. Keepalive
      alone is not ownership; magic-close without nowayout is Unhealthy.
      OpenWrt adapter uses the stamp. Host 17/17. Not a live VM, not ioctl.
- [x] P11 FDT health handoff: `HealthHandoff` FDT node `g6b,boot-health-1`
      with journal-lba/sectors. Canary `LINUX-HEALTH-OK`. Host 20/20.
      Not a live kernel.
- [x] P11 helper journal discovery: `--dtb` / `--dt-root` set the G6BH
      offset from the handoff. GPT and wrong size are Bounds. Host 23/23.
- [x] P11 volume discovery (no jump): `g6b-boot-health::volume` walks
      GPT/MBR and classifies each partition payload. RISC-V Image is a
      kernel; squashfs/UBI is a rootfs and not executable; FDT is a
      device tree. Table type is a claim. `--scan` is read-only. Host
      30/30. Not a filesystem walk, not a live VM, not QEMU.
- [x] P11 filesystem file discovery (no jump): mountable partitions
      list `/`, `/boot`, `/efi/boot`. `/boot/Image` is Kernel;
      squashfs file is Rootfs and not executable; EFI loader and
      extlinux.conf are not kernels. Host 34/34. Not a recursive tree
      walk, not a live VM, not QEMU.
- [x] P11 `/dev/watchdog` ioctl mock: file-backed `WatchdogDevice`
      with Linux open/keepalive/magic-close/nowayout. `ioctl(2)` is
      not issued. Host 42/42. Not a live device, not QEMU.
- [x] P11 platform WDT survives `LinuxEnter`: `G6WD` + `mtime`
      deadline armed before `sie=0`. WFI hang still `LINUX-WDT-FIRE`
      with `ticks=0`. Canary is not an ack. `g6b-asm` 124/124.
- [ ] Linux-generic helper leftover: live OpenWrt VM, real kernel.
- [ ] Remaining approved runtime/EH/network/TLS/UI/KVM/iframe/update/Linux boot
      phases. Remote QEMU and GPU/RTL changes remain outside this program.

These are foundations, not live recovery or management services. Existing boot
behavior is unchanged. Storage users must serialize writers across the whole
journal transaction; cross-process locking is not supplied by an `&mut` borrow.
Physical power-loss and post-handoff watchdog recovery remain qualification gates.

## Local plan review — PPM, stage 3 and pixel parity (2026-09-14)

- [x] Reproduce unreadable legacy PPM text: `g6b-gr::glyph_row` contained only
      banner glyphs and returned one box for almost every character. Complete
      printable ASCII with guest-matching uppercase folding; add exhaustive
      host/guest glyph equality and shorter/removed-row repaint tests.
- [x] Clarify that `gr`/`display-proxy` are text diagnostics, not styled web
      scanout. Their blue background is intentional; no golden was re-recorded.
- [x] Enforce reachable-op preflight in `install_guest`; an unsupported reachable
      import is refused before any image is installed.
- [x] Fix `JitCall`'s descending argument slots and bound arguments/function
      indices. Fix stale empty values after late fulfillment on rewind.
- [x] Drive Asyncify after resumed calls, preserving function and arguments for
      `JitResume`; validate late fulfillment through all eight awaits and DOM
      rows, plus a second suspension/resume. Preserve the shared event record
      while suspended; defer input until after resume. One continuation only.
- [x] Add zero-RGB-difference host-versus-guest pixel parity for every packed
      menu at 640×480 and 1920×1080, without pixel injection or WebBlit fallback.
      Add completed-device-frame equality to the picker/JIT integration gate.
      That full boot opts into a bounded 192M-step budget instead of accepting
      the old 48M `Limit` snapshot; other smoke callers retain their default.
- [x] Wire both pixel gates into `bios_regress.py` (`guest_pixel_parity`).
- [x] `g6b.py check` and a separate `regress` passed, including fresh
      `out/setup.ppm`/`out/proxy.ppm`, unchanged CSS goldens and both pixel gates.
      Styled host reference: `out/web-review-host.ppm` at 1920×1080. The original
      HD picker fixture completed at 83,655,903 instructions (`Wfi`, zero faults),
      with guest-created field rows and exact committed-frame RGB equality.
- Remaining stage-3 scope: complete tag/payload/stack-correct wasm EH, and
  live guest networking beyond packed routes. UTF-8 getters (B124),
  capture/bubble (B125), multiple records (B126), `once`/`passive`/removal
  (B127), Optional/float getters (B128), double/OptionalString/Bool/Double
  (B129), SYN_REPORT REL/wheel/hover (B130), RFB/KVM normalize (B131) and
  modifiers/multi-button/click-to-focus (B132) and host-oracle
  mutation/lifetime (B133) and password controls (B134) and
  timeStamp/deltaMode (B150), text/backspace (B151), caret (B152), and
  selection (B153) landed. Guest `try_table` catch dest (B154), interp
  `catch_all` without fabricated payloads (B155), guest JIT vsp restore
  (B156), `try_table` catch dest vsp restore (B157), and cross-function
  throw into single-clause `try_table` (B158), and one-cell tagged
  payload across `R_THROW` (B159), and multi-clause `try_table` EXCCHK
  (B160), multi-cell tagged payload (B161, bound 4), `rethrow 0`
  (B162), rethrow into `try_table` (B163), `catch_all_ref`/`throw_ref`
  (B164), `catch_ref` (B165), continuation-owned EH (B166), `JitCall`
  EH nest restore (B167), guest-JIT await-in-try fail-closed (B168), and
  callee-await from a try (B169), and `call_indirect` to an awaiter from a
  try (B170), host-interp await-in-try fail-closed (B171), and interp
  callee-await from a try (B172) landed. **P4 sequential leftovers are
  closed.** IME and RFB session/auth stay with later phases. P5
  binary-safe HTTP/1 response parse (B173), chunked decode (B174),
  partial I/O (B175), TCP EOF vs WouldBlock (B176), and virtio-net
  feature negotiation (B177), RX/TX queues (B178), and exec-model
  loopback packet (B179), Ethernet/ARP (B180), and IPv4 ICMP echo
  (B181), TCP SYN/SYN-ACK (B182), and TCP ACK (B183) landed; TCP
  payload HTTP GET (B184), TCP FIN (B185), UDP echo (B186), DNS A
  (B187), DHCP (B188), TCP RST (B189), SYN :81 retransmit (B190), and
  KernelNet NAT packets (B191), TCP reassembly (B192), NAT TCP listen
  (B193), virtio-shaped DMA (B194), virtio desc/avail/used rings
  (B195), KernelNet on exec guest rings (B196), and kstart `__vio`
  second GET (B197), KernelNet `from_kstart` (B198), and ICMP MTU
  (B199), IPv4 fragment reassembly (B200), and KernelNet
  cancel/watchdog during a NAT fetch (B201), and link-loss
  completion (B202), and KernelNet socket GET without blocking
  connect/DNS (B203), isolated NAT DNS A job (B204), and NAT nameserver
  10.0.2.3 (B205), DNS destination policy (B206), and HTTP redirect
  origin policy (B207), TCP window (B208), and generational job
  slots (B209) landed. **P5 sequential leftovers are closed.** The P5
  gate still needs external isolated peers, QEMU `-netdev`, and a PHY.
  P6 suite advertisement (B210), fail-closed TLS entropy (B211), and
  HKDF-SHA256 (B212), and TLS 1.3 Expand-Label (B213) started:
  ClientHello does not offer CBC/RSA; random is not `sha256(host)`;
  RFC 5869; RFC 8446 labels; AES-128-GCM (B214); TLS 1.3 AEAD
  record (B215); transcript/Finished (B216).
- Remote g6q/QEMU-GL is owned by the other session; no remote run or emulator
  modification belongs to this local pass.

Licensing/integration review: existing MIT headers retained, no dependencies
added and no upstream code copied. No RTL, clock/reset, ISA, DTS, DFT or
synthesis change. Firmware timing adds bounded resume dispatch and defers input
while the single Asyncify continuation owns its buffer; pixel loops are unchanged.

## APU P0 protocol groundwork (2026-09-14)

Priors and remaining gates: `architecture/DISPLAY.md` §API-neutral APU;
reference-only source pins: `pins.toml [graphics_wire]`.

- [x] Preserve concurrent TGSI-text/stage/state-binding corrections and add eight
      package-local `p0_` wire/model tests; five tests first exposed wrong bind,
      clear, feature-bit and capset-size/layout behavior.
- [x] Correct `VIRGL_BIND_*` wire masks, color-clear bit and virtio feature bits;
      request the complete 308-byte capset-v1 payload plus 24-byte response header.
      The model grants no GLSL profile and rejects unsupported capset IDs/versions.
- [x] Independent installed virglrenderer 1.0.0 capset query and generated
      execbuffer diagnostic: 307,200 exact pixels, zero differences at 640×480.
      This is external-renderer evidence, not a native APU or full virtio client test.
- [x] Focused tests, fmt and Clippy; separate `python tools/g6b.py regress` pass.
- [x] Follow-up request validation: fenced submit/readback, 64-bit fence checks,
      response bounds, cyclic-descriptor refusal, split/truncated OUT payloads,
      first-error stop and RV32/RV64 u16 queue-index wrap. Correct the double-V
      flip against QEMU's actual Y_0_TOP source flag. The tracked external replay
      validates 11 requests and fences 1/2 with 307,200 exact pixels on both
      llvmpipe and explicit D3D12 Intel Arc; not a Linux-driver or RTL proof.
- [x] OpenWrt 24.10.2 / Linux 6.6.93 boots through `g6lc_qemu` and executes
      guest probes. Temporary ttyS0 inittab overlay leaves original images intact.
- [x] Remote graphics baseline now runs unchanged Linux virtio-gpu + Mesa virgl
      over modern virtio-mmio using QEMU vhost-user-gpu and a host-side
      surfaceless-EGL shim. Guest reaches `gbm-window`, renderer `virgl
      (LLVMPIPE...)`, stable pixel FNV-1a `0x3d667145`, `G6LC_EGL_GLES2_OK`, rc 0.
      This is host software-rendered driver-path evidence, not APU/RTL proof.
- [x] Actual unchanged Mesa/Linux traffic is archived and strict-validated in
      `g6lc_qemu/out/remote-gfx/gfx-20260914T203512Z/capture`; resources,
      transfers, fences and cleanup are `result=PASS`.
- [x] Opt-in negative ioctl probing through the unchanged guest driver is
      archived in `g6lc_qemu/out/remote-gfx/gfx-20260914T203421Z/capture`.
      Invalid resource creation, out-of-bounds transfer, unknown opcode and a
      truncated command are rejected by the backend (`EINVAL`), while queue
      ioctls and virtio fences can still complete asynchronously.
- [x] The opt-in richer GLES2 audit run is archived in
      `g6lc_qemu/out/remote-gfx/gfx-audit-20260914T213500Z/capture` and passes
      strict validation. It adds real Mesa/driver evidence for texture
      upload/sampling, packed sampler views/state, fragment constants, indexed
      drawing, scissor state, state binds, transfers/readback, cleanup and
      command-typed fences; still host software rendering, not APU RTL.
- [x] Fix the picker publication race: AUTO_ON is set after initialization/draw.
- [x] The picker/JIT test now checks the completed device framebuffer rather
      than stale `DOM|` rows. It uses an explicit integration-only instruction
      budget and rejects `Limit`; zero-tolerance equality passes locally. The
      current full `python tools/g6b.py check` is green, including that test
      and the BIOS regression suite.
- [x] Freeze the reduced P0 device contract in `architecture/DISPLAY.md`:
      unchanged Linux/Mesa passed `gles2-min` audit and expected-error probes
      (`gfx-20260914T221515Z`, `gfx-20260914T221551Z`) with all optional virgl
      capability masks clear; `gles2-xfer` remains an optional `TRANSFER3D`
      diagnostic (`gfx-20260914T221800Z`). The contract records
      context/resource isolation, reset, async errors, DMA/cache ownership and
      protected-firmware obligations.
- [ ] P1/P2 APU RTL and firmware; P3 unchanged-driver hardware GLES2 proof;
      P4 feature/gaming qualification; P5 HDMI/DisplayPort integration.

Review: existing MIT headers retained; external references are not linked or
installed dependencies. No RTL/ISA/DTS/timing/DFT change; no compliance claim.

## Completed UI-and-boot pass — Svelte presentation (2026-09-11)

- [x] Verify pinned LDC 1.43.0-beta1 and forked wasm-opt; rebuild baseline asyncified cell.
- [x] Reproduce undeclared `os@KEY-NTFS` in the emitted full-profile picker; add a failing regression and use only explicitly supplied volumes for ELF emission.
- [x] Verify picker-first and BIOS-UI selection on VGA-intent and GPU surfaces through the g6lc_qemu-built QEMU; retain separate before/after screenshots and fail on QMP errors. QEMU 10.0.0: `out/ui-review-qemu-{vga,gpu}/{picker,screen}.png`, 640x480 and 1920x1080, Up/Enter → `AUTOBOOT-PICK bios-ui`, no retained picker rows.
- [x] Rewrite Svelte presentation against external kernel data providers; verify live host DOM/CSS interactions and renderings. `out/ui-review-{main,cpu,memory}-hd.png` are 1920x1080 **host** images; CPU is selected by click, Memory by keys plus hover. Root identity and every menu's kernel-sourced values are regression-tested. Correct the native JS menu-envelope mismatch and preserve JS-off/proxy-off data-read gates.
- [x] Run package gates and record results. `python tools/g6b.py check` passed (independence, 116 Bun tests with two opt-in compiler probes skipped, fresh artifact validation, fmt, clippy, workspace tests, BIOS regression). The explicit `python tools/build.py libwasm` build verified LDC 1.43.0-beta1 plus forked wasm-opt Asyncify; shipped SHA-256 `214c07b7240faa5cb3774f66b7d486905e70c63fa4804dc10c40b7fd012faf18`. Separate `python tools/g6b.py regress` passed, including all five unchanged CSS goldens. The workspace retains its existing ignored Node.js differential test.
- Licensing/SoC review: existing first-party MIT headers retained; fixture follows tier T; no new dependency, GPL link, upstream attribution change, RTL, clock, reset, ISA, or DTS change. Timing/DFT/synthesis gates are not applicable to this firmware/tooling-only pass.
- **Agreed scope:** UI and boot first. Native QEMU currently executes `WasmUi`/`start_ops`, not `BrowserSession`. Host UI renderings and QEMU glyph-face screenshots are separate evidence; no native guest browser completion is claimed.

| Stage | State |
|---|---|
| **B0** scaffold KD0 + schema + fixtures | landed |
| **B1** `g6b-design` Config.ZC / Connectors.ZC / linker | landed |
| **B2** DolDoc ToHtml | landed |
| **B3** UART HTML viewport + `g6q run --loader bios` wiring | landed |
| **B4** rewrite of Adam/KMain from TempleOS/ZealOS spec (`KMain.ZC`, `Adam.ZC`) | landed |
| **B5** fast HolyC init (`HOLYC-READY`) | landed |
| **B6** DOM+JS UI boot (`UI-BOOT`) | landed |
| **B7** HolyC dual-band UART + SSH-like TCP (QEMU `-serial tcp`) | landed |
| **B8** `bios-regress` (`tools/bios_regress.py`) | landed |
| **B8b** post-boot Linux access: immutable view-only, structural params, KVM power | landed |
| **B8c** sideband loopback (mbox+IRQ), NIC `until-delegate`, Linux misc stub | landed |
| **B8d** SSH+HolyC KVM face in addition to HTML+JS | landed |
| **B9** host-generated RV32/64 ELF (`g6b elf` → `out/g6lc_bios.elf`); `KStart64` rewrite | landed |
| **B9b** kernel-spec → RISC-V: `KStart.S` / `KInts.S` (no CR0/IDT/LAPIC) | landed |
| **B10** Gr / SysGrInit rewrite (`g6b-gr`, PPM, virtio-gpu argv) | landed |
| **B11** HolyC RISC-V ISel (`MemCpy.S`; RVV gated) + `g6b-asm` IR | landed |
| **B12** generated `/dev/g6lc-bios` miscdriver (fops, irq, probe; not a netdev) | landed |
| **B12b–B13** in-guest bind; optional real SSH | open |
| **B14** display-proxy + OpenGL-ES2 adapter (HDMI/DP 30/60/120) | landed |
| **B15** WebIDL live/stub BIOS browser (goja/lirx specs, not runtimes) | landed |
| **B16** HolyC HTTPS + SHA-256/AES-128 | landed |
| **B17** WASM-JIT + svelte-d UI catalog | landed |
| **B18** Botan-spec RSA/ECDSA/X.509 + adapter HTTPS/SSH ports | landed |
| **B19** Kernel HTTP/1.1+HTTP/2, JS↔HolyC endpoints, BIOS params, libwasm spec | landed |
| **B20** Profiles embedded→full; OpenWrt flash; settings ± USB key; HTTPS serve | landed |
| **B21** USB FAT32 flash always-on; USB-key FileMgr FAT32/NTFS/ext4; browser-UI notes | landed |
| **B22** 64-bit SMT2/multi-core/issue/stream/OoO/H/RVV topology; uncore menus; HolyC-UI ⊥ browser-UI | landed |
| **B23** HolyC kernel file server: HTML/JS/WASM over HTTP(S); TLS ServerHello; `http.files` | landed |
| **B24** RISC-V S-mode timer + trap dispatch (ASM IR); high-DPI/high-res proxy; QEMU virtio-gpu regress | landed |
| **B25** QEMU-runnable payload: `jal TimerInit` before park; scause interrupt-bit + `rdtime`; proxy_geom ELF words; boot log = `kstart_msg` | landed |
| **B26** Per-hart S-mode bring-up: stacks after payload; all harts `stvec` then hart≠0 WFI; ELF `p_memsz`; QEMU `-smp` | landed |
| **B27** Bare `satp`+`sfence.vma`; host S-mode ELF smoke (`g6b smoke`) | landed |
| **B28** UART0 ns16550 THR + SBI putchar; smoke secondary hart parks | landed |
| **B29** UART0 8N1 init; smoke IRQ_TIMER on `wfi` | landed |
| **B30** INT_FAULT: `TRAP-<scause>-<sepc>` then WFI; illegal-insn smoke | landed |
| **B31** S-mode PLIC `PlicInit` + SEI irq 9 claim/complete | landed |
| **B32** SBI HSM `hart_start` + IPI; trap SSI irq 1 | landed |
| **B33** `MboxInit` `G6MB` + irq_en at `loopback.base`; PLIC irq 3 | landed |
| **B34** `trap_mbox` View/Reboot/Shutdown/Wakeup doorbell kicks | landed |
| **B35** UART PLIC irq 1 RX (`trap_uart`); UART1 IER then WFI | landed |
| **B36** SysGrInit `GrInit` `GR16` header at `__gr_plane` | landed |
| **B37** 4bpp 640×480 plane + boot scanline (`KSTART-GR-PLANE`) | landed |
| **B38** 8×8 `G6LC` blit on the 4bpp plane (`KSTART-GR-FONT`) | landed |
| **B39** UART line buffer; newline View/Reboot/Shutdown/Wakeup | landed |
| **B40** UART 4-char prefixes `View`/`Rebo`/`Shut`/`Wake` | landed |
| **B41** `ViewSection("name")` quote walk → `VIEW name` | landed |
| **B42** `browser-ui` svelte-d → svelte-engine-ws → WASM; local libwasm g6b clone; `g6b-svelte` removed | landed |
| **B43** `g6b-ui` shared HolyC-UI ⊥ browser-UI (MENUS.md screens + settings/USB utilities) | landed |
| **B44** Kernel fetch paints `g6b-ui` DOM ids; `kernel.holyc` runs Menu*/Usb* via HolyC REPL | landed |
| **B45** Optional display-proxy GL accel `kernel.proxy.accel=off\|auto\|rvv\|ai-island` | landed |
| **B46** Guest `G6UI` blob + KStart `jal ProxyScale` / `UiInit`; ELF `p_memsz` +24 | landed |
| **B47** Embed `bios-ui.wasm` in ELF rodata; `jal WasmJit`; UART/mbox `Ui` command | landed |
| **B48** Guest `FileServe`: echo `\\0asm`, `/ui/` listing; UART/mbox `File` | landed |
| **B49** Guest `GetFile`: UART/mbox GET `/ui/ui.wasm`; RSP `\\0asm`+size | landed |
| **B50** Strict bounded JS AOT; Unicode/escape correctness; DOM attributes/selectors/local dirty tracking; non-destructive visibility; checked HTML and table-row painting | landed (host software; architecture limits apply) |
| **B51** Shared spec-derived menu rows, `kernel.browser.start_menu` and JS gates; host BrowserSession/Gr/proxy execution; native read-only browser navigation/WASM imports; bounded local HTTP framing | landed (host software; architecture limits apply) |
| **B52** Validated bounded i32 WASM control/locals/calls; fuel; RV32/RV64 numeric export lowering and differential machine-word tests | landed (host software; architecture limits apply) |
| **B53** Guest runtime JS/DOM integration, input/GPU scanout, executable JIT installation/trampolines/cache sync | host prerequisites advanced; bounded guest `_start`→`__ui_dom`→`DomPaint` lane + `Ui` re-dump + executed-plane PPM + `VioProbe`/`VioInit`/`VioScan` virtio-gpu path **verified on real QEMU 8.2 + OpenSBI 1.5** (`fixtures/g6lc64-qemu.json`, QMP screendump shows the guest-painted band **and the 1920×1080 high-res proxy scanout** — `FbExpand` scale-blit, centered `to_ppm` geometry); uncore `display`-engine seam (`DispPaint` + `G6FB` simplefb handoff, `fixtures/g6lc64-hdmi.json`, exec-modelled) + `qemu-args` `--vnc`/`--no-gl`/`virtio-gpu-gl-device` under `proxy.gl` landed; **virtio-input eventq (`InpInit`/`InpDrain`/`InpPoll` + `virtio-keyboard-device` argv) and WFI-driven ctrlq/eventq waits landed (exec-model verified)**; **absent-device tolerance for stock QEMU virt landed** (`trap_fault` recoverable probe windows for UART1/mbox — `g6lc64-virt.json` boots stock `virt`); runtime gates open |
| **B54** Real persistent settings/flash backends and authenticated production TLS; remove canned mutation acknowledgements only with backend implementation | open |
| **B55** Mutable per-run WASM memory (load/store/size/grow) + extended i32 lowering (bitwise/shifts/rotates/ordering) via `g6b-asm` | landed (host; RV32/RV64 differential machine-word tests) |
| **B56** Bounded nonblocking JS async: `await` fetch tokens, throw/catch, cancellation, stale/duplicate rejection, per-task/tick budgets | landed (host) |
| **B57** Transactional DOM (`DomTransaction` + native-browser DOM-kernel host); explicit libwasm ABI mount with startup verification | landed (host) |
| **B58** Cooperative RV32/RV64 task-switch IR, bounded scheduler/task services, DedicatedWorker compute protocol shared by browser/HolyC menus | landed (host IR + services; guest dispatch open) |
| **B59** LDC 1.43 + vendored `runtime-v1.43.0` libwasm cell: DUB workspace, provenance/ABI/startup-gated publication, Asyncify build path with custom binaryen, D particle exports + WebGL backdrop | landed (component-shell artifact; libwasm await status/object-string ABI, `g6b-wasm` dispatch and JS host `createLibwasmHost` landed; D `catch` rejection->wasm-EH throw and full Svelte tree still open) |
| **B59b** pinned LDC toolchain: `browser-ui/toolchains/ldc.lock.json` (upstream `v1.43.0-beta1`, per-host SHA-256), `scripts/install-ldc.ts` verify-then-extract installer, pin-first discovery in `compiler/ldc.ts` | landed (host; replaces ambient `1.43.0-git` discovery — see below) |
| **B82** Cut misleading UI lanes: svelte-d requires the LDC cell; live DOM is the raster; guest `WasmStart` is VGA glyphs only | landed (host) |
| **B83** `fetch` / `<img src>` through `/ui` files; GLES2 `u_dom` = CSS Canvas32 | landed (host) |
| **B84** libwasm types on the UI-thread Host, not the kernel; `KernelPort`; goosie `:hover` | landed (host) |
| **B85** Interactive UI: browser loads the LDC cell as `WasmUi`; tick/present_gl; live tab classList | landed (host docs + persistent instance) |
| **B86** Persistent `instance.call` without KernelHost reconstruct; event object coords / preventDefault; LDC `getRoot` host import | landed (host; shipped cell still inlines `getRoot()=1` until `G6B_DUB_WASM=1`) |
| **B87** Cell-owned tab/refresh/JSON: `on:click` → `g6b_listen`; host `Listener::Cell` preventDefault + fetch/select; Rust `select_menu` is default action only | landed (host; D emit ready, shipped cell uses host bind until `G6B_DUB_WASM=1`) |
| **B88** Live CSS `Engine::paint(&Node)`; DirtyFlag Style/Layout/Paint; goldens per tab + hover (no HTML round-trip) | landed (host; 4bpp `ui_ppm` is Canvas32→PALETTE downsample; dirty tiles B90) |
| **B89** UI-thread `Role::Ui` / `ui_hart` runs `tick`; timer heap; fps 100/144; B66 timers implemented or ABI-verifier refused | landed (host) |
| **B90** Dirty-tile GLES2 + virtio-gpu TRANSFER/FLUSH; QMP tab screendumps vs `ui_ppm32` goldens; host blit of Canvas32 into modelled `__scan_fb` | landed (host; QMP tab shots remain `qemu_tab_shots.sh` / remote g6q) |
| **B91** Guest libwasm instance: same Host + compact DOM + dirty paint in S-mode. Do not grow `start_ops` to `Object_Call` | compact persist + dirty-tile `VioPaint` landed; **B91b** `GuestCellLive`/`WebFeed` **landed**; **B91c** virtio/UI events re-enter D delegates via `jsCallback` / `Listener::Delegate` (shipped cell stays `Listener::Cell` until `G6B_DUB_WASM=1`) **landed** |
| **S0** `g6b-pglite` submodule + npm pin; UUID store-instance architecture | landed (PR1). Identity: [`architecture/g6b-store-instances.md`](architecture/g6b-store-instances.md) |
| **S1** BoardSpec `kernel.store` + crate `g6b-pglite` (parser/DML/tx) | landed (enable **default on**; overlay `false` to compile out) |
| **S2** `/bios/store` + HTTP cap + HolyC `Store*` | landed |
| **S3** Lodash `HostDispatch` + intern `window.pglite` + `libwasm.pglite` | landed (BrowserSession-complete; native D `execute!JSON` is S5+) |
| **S4** FileServe `/ui/pglite/*` + `g6b.py pglite-dist`; optional Electric instantiate | landed (S4a FileServe + S4b native facade / `createPgliteWasm`) |
| **PR3c** `g6b.py store-embed` → `__g6b_store_dump`; `elf://` hydrate | landed (`persist.elf`; missing dump is PersistUnarmed / explicit-path link error) |
| **S5** USB live + G6BS + `stat`/`statAsync` + JOIN/listen | landed. `UsbLive` auto-flush; `GET /bios/store/{uuid}/stat` + HolyC `StoreStat` + D `stat()`/`statAsync()` + `await store.stat()` for a dialog that polls until `live && ready`. `INNER JOIN ON`, `LISTEN`/`NOTIFY` per-store. svelte-d: `Store.svelte` flattened into App `_start`; `let rows = await pgliteQuery` paints `{rows}` / `{st.ready}` via `JSON.stringify`; g6b-js AOT stays fetch+text |

B53 guest-DOM increment (2026-09): `g6b-asm` gained `Purpose::UiDom`,
`Addr::{WasmData,UiFont,UiDom}`, `Module.{wasm_data,font,dom_bytes}`, the
first-party 8x8 font (`font.rs`) and the guest DOM service (`dom.rs`:
`WasmUi`, `WasmStart` anchor, `WasmDomFind`/`WasmDomText`/`WasmDomVisible`,
`WasmFetch`/`WasmLog`, `DomPaint` with `DOM| ` serial + 4bpp `__gr_plane`
glyphs). `g6b-wasm::jit::start_ops` lowers the straight-line wasm `_start`
(`i32.const` + `env` import calls, fail-closed) onto the `WasmStart` anchor;
`jit::data_image` supplies `__wasm_data` (≤16 KiB `.rodata`). `g6b-elf`
merges both into one `payload_module` shared by ELF packing and host smoke;
`exec` covers `__ui_dom` BSS and captures `smoke.dom_rows`/`dom_pix0`.
`python tools/g6b.py check` green (independence, Bun tests/build, fmt,
clippy, workspace tests, 13/13 bios-regress incl. `elf_smoke`); new tests:
`start_ops` guest-IR execution on both XLENs (`DOM| UI-BOOT`, `dom_rows=1`),
fail-closed cases, `wasm_jit_smoke_runs_dom_imports` (gr paint),
`wasm_jit_smoke_serial_only_without_gr`. `g6b smoke` on `g6lc64-virt.json`
prints `DOM| ` menu text and `GET /bios/...` lines. This is a bounded
boot-time render lane — not guest JS execution, not arbitrary wasm, and not
virtio-gpu scanout evidence.

B53 follow-on (2026-09): `Purpose::Virtio` + `VioProbe` — bounded read-only
virtio-mmio slot scan (`0x10001000+0x200*i`, MagicValue `virt`, DeviceID 16)
printing `VIRTIO-GPU <slot>` / `VIRTIO-GPU-NONE`; gated by the new shared
`BoardSpec::wants_virtio_gpu` (same predicate emits `virtio-gpu-device` in
QEMU argv). Host exec models the slot-0 device (`run_module_no_gpu` covers
the absent path). Collision fix: modeled UART1 base moves `0x10001000` →
`0x10002000` when the GPU is attached (QEMU virt has no second ns16550; the
window is virtio-mmio). UART `Ui` now re-dumps the live DOM (`jal DomPaint`).
`exec::Smoke::gr_frame` + `g6b smoke --out f.ppm` export the executed
`__gr_plane` (GR16+4bpp) as PPM via `g6b-gr::plane_to_ppm`. Still open:
virtqueue setup, `RESOURCE_*`/`SET_SCANOUT`/`TRANSFER_TO_HOST_2D`/`FLUSH`,
input delivery, guest JS/runtime gates.

B53 follow-on 2 (2026-09): `VioInit` (`g6b-asm::vio`) — virtio 1.x handshake
(reset, ACK|DRIVER, `VIRTIO_F_VERSION_1`, FEATURES_OK readback, DRIVER_OK),
controlq setup (desc/avail/used in `__vio` BSS, `Op::Fence` before avail-idx
and notify), and one real `GET_DISPLAY_INFO` descriptor-chain round-trip
verified by `VIRTIO-INFO` (resp `0x1101`) vs `VIRTIO-GPU-FAIL`. The exec
virtio-mmio model now implements the register file (status/features/queue/
ISR/notify), walks chains out of guest RAM, writes the display-info response
+ used elems, and latches `vio_status`/`vio_last_cmd`/`vio_last_resp` into
`Smoke`. `smoke` on `g6lc64-virt.json` prints `VIRTIO-GPU 0` → `VIRTIO-GPU-OK`
→ `VIRTIO-INFO`.

B53 follow-on 3 (2026-09): `VioCmd` + `VioScan` (`g6b-asm::vio`) — the
submit-one virtqueue routine (desc0 OUT req / desc1 WRITE resp, avail
publish, `fence`, `QueueNotify`, bounded used poll, resp type in a0) drives
the full pixel sequence: `RESOURCE_CREATE_2D` → `RESOURCE_ATTACH_BACKING`
→ `SET_SCANOUT` → guest green-band fill of `__scan_fb` →
`TRANSFER_TO_HOST_2D` → `RESOURCE_FLUSH` → `VIRTIO-SCAN`. The exec model
tracks resources, bounds-checks the backing attach against `__scan_fb`,
latches the scanout rectangle, copies backing→device surface on transfer
and counts flushes (`Smoke::vio_scanout`/`vio_flushes`/`vio_fb*`);
`g6b smoke --out-vio f.ppm` exports the device surface
(`g6b-gr::x8r8_to_ppm`, `g6b_kernel::scanout_ppm`). `smoke` now ends
`vio=0xf/0x104/0x1100 scanout=true flushes=1`. Two defects fixed en route:
`slli/srli 16` on rv64 masks 48 bits, not 16, so avail-flags "preservation"
re-published a stale idx (avail jumped 1→3, replayed the CREATE chain);
and bare `sw(x0,t2,off);` statements in `scan_node` silently dropped the
rect/offset stores. Also corrected `RESP_OK_DISPLAY_INFO` = 0x1101 (was
0x1100 = `RESP_OK_NODATA`) and the 408-byte display-info response size,
and moved `VIO_REQ_OFF` 0x100→0x120 — the 8-entry used ring needs 72B from
0xC0, so ring index 7's `len` would have clobbered the request area on
wrap. Interrupt lane: the device now counts InterruptStatus bit-0
assertions (`Smoke::vio_irqs`, 6 per boot) and both completion paths read
InterruptStatus (0x60) and write it back to InterruptACK (0x64). Still
open: eventq/input, real PLIC irq delivery (the used-ring poll is bounded
but busy), QEMU-visible pixels — the modeled surface is host-side
protocol evidence only.

B55–B59 verification (2026-09): `python tools/g6b.py check` passed
independence, 42 Bun tests across 3 files (0 fail) including the actual LDC
cell startup against the explicit DOM ABI and an isolated LDC-compiled
particle-D run, `bun run build` emitting `out/bios-ui.wasm` plus a verified
fresh LDC component-shell artifact, fmt, strict Clippy and 276 Rust tests
(1 ignored: Node-native WebAssembly differential memory case). Asyncify /
`wasm-opt` is absent on this host and fails closed: requesting it or compiling
await-bearing Svelte sources returns status 3 and never ships an artifact.
`bios-regress` passed all 13 cases. No RTL/silicon, guest JIT, or full
guest-browser claim follows from these host results. MIT headers and upstream
reference boundaries were retained; the LDC runtime carry is vendored with its
upstream notices intact.

B53 follow-on 4 (2026-09) — **real QEMU execution**: the `g6lc_qemu`-built
OpenSBI 1.5 `fw_dynamic` + QEMU 8.2 `virt` booted `out/g6lc_bios-qemu.elf`
built from the new **stock-virt-faithful** `fixtures/g6lc64-qemu.json`
(`loopback` off — the mbox `0x10100000` is QEMU `fw_cfg`; `dual_band.tcp`
off — no second ns16550; `postboot`/`net_expose` never). Serial shows
`VIRTIO-GPU 7` → `VIRTIO-GPU-OK` → `VIRTIO-INFO` → `VIRTIO-SCAN` and a QMP
`screendump` PPM shows the guest-painted 64-row green band — real
guest→virtio-gpu→scanout evidence. Three QEMU-virt realities fixed en route:
(1) all 8 virtio-mmio transports always exist at `0x10001000+0x1000*i`
(0x200 regions, 0xE00 gaps fault) — `VIO_MMIO_STEP` was 0x200 and silently
truncated through the un-checked `addi` immediate to a zero step (all I/S
encoders now range-assert via `check_imm12`), and `-device` lands on the
last free bus (slot 7); (2) the transports default `force-legacy=1`
(Version=1), which ignores the v2 QueueDesc/Avail/Used/Ready registers —
`qemu-args` now emits `-global virtio-mmio.force-legacy=false`; (3) QEMU
services QueueNotify on an iothread, so `VIO_POLL_MAX` is `1<<22`, not a
few thousand iterations. The modeled UART1 moved to `uart0+0x9000` (above
the window) and `trap_uart`'s UART1 drain is emitted only when
`dual_band.tcp` — both were unmapped-MMIO reads on stock virt.

B53 follow-on 5 (2026-09): `VioPaint` (`g6b-asm::vio`) closes the
DOM→scanout lane on QEMU: palette-expand `__gr_plane` (4bpp, hi-nibble even)
into `__scan_fb` (X8R8G8B8) through the inline `vio_pal` table (same values as
`g6b-gr::PALETTE`), then full-frame `TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH`
via `VioCmd`. Boot order: `VioPaint` is `jal`ed after `WasmUi` (the last
`__gr_plane` painter) and re-runs on the `trap_uart` `Ui` path so the UART
`Ui` refresh also updates the QEMU scanout. It saves ra + t3..t6 itself —
the trap frame only covers t0..t2/a0..a2/a6/a7. **Verified**: QEMU
`screendump` after `VIRTIO-PAINT` shows the DOM/Gr plane (glyph pixels +
boot scanline) on the virtio-gpu console with a histogram identical to the
host-modelled `vio_fb`; `smoke` now reports `flushes=1+paints`,
`irqs=6+2*paints` and the test asserts the whole `vio_fb` equals the
expanded `gr_frame`. Host `STEP_LIMIT` raised 2M→12M for the real
w*h/2-iteration expand loop.

B53 follow-on 6 (2026-09): **PLIC irq completion verified on QEMU.** The
machine DTB (`qemu -M virt,dumpdtb`) gives virtio-mmio slot i → PLIC irq
`1+i` (GPU slot 7 → irq 8) and UART0 → irq 10 — the guest's `UART_IRQ`
was model-only 1 and would have matched the wrong source. `PlicInit` now
writes nonzero source priorities for every enabled irq (QEMU PLIC priority
resets to 0 → a 0-priority source never asserts), enables irqs 1..=8 +
UART(10) + mbox, and `trap_sei` resolves a claimed virtio irq from
`__vio+VIO_DEV_OFF` (`irq = 1 + (dev-0x10001000)/0x1000`) → `trap_vio`
reads InterruptStatus, writes InterruptACK (clears the device level — no
storm), and bumps `__vio+VIO_IRQF_OFF`. `VioInit` stores `dev_off` at
`vi2_dev` (before the first notify). QEMU `xp` shows `irqf == 8` after boot
— exactly the 6 scan + 2 paint completions — so used-buffer interrupts are
claimed through the real PLIC; `VioCmd` still polls `used.idx` as the
bounded fallback (the flag is evidence, not a gate). The UART command lane
is QEMU-verified too: `qemu-args` now always emits a bidirectional serial
(`-serial tcp:127.0.0.1:<port>,server,nowait`; `dual_band.tcp.host_port`
when set, else `G6B_UART_CONSOLE_PORT`=4567) — a `-serial file:` console is
output-only and strands `trap_uart` input. Verified on QEMU: writing
`View`/`Ui`/`File` to the TCP serial dispatches through PLIC irq 10 →
`trap_uart`; `Ui` re-ran `DomPaint`+`VioPaint` live on the virtio console.
Exec model: `vio_notify`
sets `plic_pending |= 1<<1` (slot-0 model → irq 1) and the uart injection
uses `UART_IRQ`; tests assert `sei_claims` covers the virtio claims. Still
open: eventq/input delivery, `wfi`-driven waits (the poll stays bounded),
full `g6lc64-virt.json` under QEMU (needs a custom mbox device model).

B53 follow-on 7 (2026-09): **high-res/high-DPI scanout + the uncore display
seam.** The scanout is now the proxy high-res target, not the Gr geometry:
`VioScan` creates/attaches/scanouts `gp.2×gp.3` (1920×1080 on
`g6lc64-qemu.json`; `VIO_FB_MAX` 4→16 MiB for the 8.3 MB surface) and the
blit was split — `FbExpand` is the shared, backend-agnostic scale-expand of
the 4bpp `__gr_plane` into `__scan_fb` with the *same semantics as
`g6b_gr::proxy::Proxy::to_ppm`* (`fit`/`dpi` = uniform `scale` in a
**centered** letterbox — ox=(hi_w−low_w·sc)/2, oy likewise; `fill` = bounded
per-axis integer stretch, exact for integral ratios), then `VioPaint` pushes
the whole high-res rect (TRANSFER+FLUSH) — **QEMU-verified**: `screendump`
is `P6 1920×1080` with the 640×480 DOM/Gr plane ×2 centered at (320,60),
letterboxes black, green band on top. Host test
`vio_paint_scale_expands_to_proxy_high_res` samples the scaled surface
against the plane nibbles. A `peripherals[]` `class:"display"` entry
declares the **native uncore engine** (HDMI/DP): `BoardSpec::display_ctrl()`
yields `wants_virtio_gpu` and `wants_disp_scan()` emits `DispPaint`
(`FbExpand` → register-window commit per
`architecture/uncore/hdmi-display.md` → `DISP-OK`) plus a `G6FB` descriptor
at `__vio+0x400` — the `simple-framebuffer`-shaped BIOS→Linux handoff (same
surface, no re-init). `exec` models the window (`disp_committed` +
`disp_desc`); `fixtures/g6lc64-hdmi.json` exercises it (smoke `DISP-OK`, no
VIRTIO lines). QEMU frontends: `qemu-args` emits `virtio-gpu-gl-device` +
`-display egl-headless,gl=on` when `proxy.gl` (virgl — needs a host DRM
render node; this WSL host has none → `opengl is not available`), `--no-gl`
falls back to `virtio-gpu-device` (identical guest commands), and `--vnc N`
appends `-vnc 127.0.0.1:N` — a host frontend over the QEMU console that
serves the BIOS scanout and a later Linux guest identically. Still open:
host render-node availability for real virgl (`egl-headless,gl=on` needs
`/dev/dri/renderD*` — `--no-gl` is the fallback; WSL2 confirmed the gate:
`egl: no drm render node available`). QEMU `sendkey` verification of the
input lane is **done** — see the follow-on-8 QEMU note below.

B53 follow-on 8 (2026-09) — **virtio-input eventq + WFI waits + absent-device
tolerance.** `VIO_DEV_INPUT` (DeviceID 18) is scanned on the virtio-mmio
slots: `InpInit` performs the virtio 1.x handshake on the probed input slot,
sets up the *eventq* (queue 0 — 8 posted `virtio_input_event` buffers in
`__vio+INP_*`, `VIO_BSS` → 0x600) and notifies; the exec model's
`host_inp_kick` stands in for QEMU `sendkey` (canned `EV_KEY` KEY_A press →
used elem → InterruptStatus → PLIC irq `1+slot`). `trap_inp` acks the device
ISR and `jal`s `InpDrain`, which pushes each `EV_KEY` event as
`(code<<8)|value` into the bounded 16-entry `INP_KQ` key queue (serial
marker `INP`) and re-posts every consumed buffer so the device never runs
dry. UART `Keys`/`K` (`CMD_KEYS`) and the mailbox `K` doorbell both run
`InpPoll` → `KEY <8-hex>` dump per queued entry (mbox answers
`RSP = "KEYS"`); the model feeds `Keys\n` after the canned keypress and the
smoke prints `KEY 00001e01` — the full sendkey→eventq→irq→queue→command
loop is exec-verified. **Kick arming (exec model):** `host_inp_kick` is
*not* only `wfi`-halt-gated. The run loop also pokes it as soon as
`__uart_line[AUTO_ON]` reads nonzero (the picker armed) — necessary because
the picker's vga-surface `FbExpand` upscale can spend the whole step budget
before `park`/`wfi`, which would starve a halt-only poke. Since
`take_pending_sei` runs every step, the raised input irq lands at the next
boundary while the picker still owns the plane — reaching `CliKey`→`AutoKey`
and, for `bios-ui`, letting `AutoPick` flip `__disp.surface` to gpu before
`VioPaint` so `FbExpand` is skipped entirely. `feed_events` is the shared
`WebFeed` drain the halt and armed kicks both use. **DOM-input bridge:**
`DomKey` (`kernel.wasm.jit`
gated — `WasmDomText` lives on that lane) mirrors the newest `INP_KQ`
entry into an `inp.last` DOM row (`"key <8hex>"` in `INP_KEYTXT` scratch),
called from `trap_inp` after `InpDrain` and after `InpPoll` in the `Keys`
paths — dirty-marks the row like a browser input event; the repaint stays
on the explicit `Ui`/refresh path (a per-keypress `VioPaint` is not the
irq's job and would blow the bounded step budget). `Smoke::dom_lastkey`
walks `__ui_dom` for the row; `vio_input_eventq_delivers_key` asserts it
plus `KEY 00001e01`, and the `Ui` repaint echoes `DOM| key 00001e01` —
input→eventq→irq→queue→DOM→paint is exec-verified end to end.
**Menu navigation (`DomNav`, jit-gated):** the canned kick is now a
3-event `sendkey` burst (`a` + `down` + `ret`) — DomNav walks `INP_KQ`
from a `NAV_SEEN` watermark (non-destructive; `Keys` still dumps the ring)
and press events drive the spec-derived menu tree: UP/LEFT sel-1,
DOWN/RIGHT sel+1 (wrap over `spec.menus()`), ESC reset, ENTER → open latch
+ serial `NAV <name>`; the `nav.sel` row shows `nav <name>`/`open <name>`
from its own `NAV_TEXT` scratch (WasmDomText stores the text *pointer* —
rows can never share a scratch buffer). `Smoke::dom_nav`/`dom_navtext`
walk `__ui_dom` — `vio_input_eventq_delivers_key` asserts
`NAV cpu` + `open cpu` + the three `KEY` lines; **QEMU-verified**:
`sendkey a/down/ret/down/up` → `INP`×10 → `NAV cpu` → `Ui` repaint echoes
`DOM| key 00006700` + `DOM| nav cpu`. `qemu-args` emits `-device virtio-keyboard-device` under
`BoardSpec::wants_virtio_input()` (= `wants_virtio_gpu && kernel.wasm.enable`).
**WFI-driven waits:** `VioInit`'s used-ring wait and `VioCmd`'s completion
wait insert `wfi` between a poll miss and the loop-back when `uncore.plic`
armed SEIE — the iteration bound still caps wake-check cycles and the
periodic timer keeps wakes coming, so a silent device degrades to the
bounded timeout rather than hanging (exec model completes synchronously:
the first check exits before `wfi`; QEMU exercises the irq-wake path).
**Absent-device tolerance for stock QEMU virt:** unmapped MMIO loads/stores
raise load/store access faults (scause 5/7, `stval` = fault address) in the
exec model when `stvec` is armed, and `trap_fault` treats `stval` inside the
UART1 or loopback-mbox probe window as device-absent — sets the
`__uart_line` flag and resumes at `sepc+4` — so `g6lc64-virt.json` boots on
stock `virt` (no g6lc-bios mailbox, no second ns16550) instead of parking on
`TRAP`. `MboxInit` additionally readback-checks the doorbell write
(`MBOX-NONE` when `G6MB` does not echo — covers QEMU's mapped-but-foreign
`fw_cfg` at `0x10100000`, which absorbs writes without faulting). Ordering
fix: `uart1_node`'s probe now runs before `PlicInit` arms the UART irq — a
trap-context `uart1_drain` read on an absent UART1 would otherwise take a
*nested* access fault and clobber `sepc`; `trap_mbox`/`uart1_drain` gate on
the absent flags. Exec model: `is_uart1` is presence-gated, the input device
is modelled at slot 1 (transport regs + eventq buffer latch +
`host_inp_kick`), and `run_module_bare` is the stock-QEMU shape (no mbox /
no UART1) — `stock_qemu_absent_devices_recover` asserts `MBOX-NONE` +
`UART1-NONE` + `VIRTIO-GPU-OK` + `VIRTIO-INPUT-OK` + `INP` with no `TRAP-`
and a `Wfi` halt; `vio_input_eventq_delivers_key` covers the eventq round
trip. `48/48` exec tests, `python tools/g6b.py check` green.
**QEMU-verified (2026-09, WSL2 QEMU 8.2.2 + bundled OpenSBI 1.3
fw_dynamic, stock `-M virt`):** `g6lc64-virt.json` boots end to end —
OpenSBI → `KSTART-*` → `UART1-NONE` + `MBOX-NONE` (QEMU's fw_cfg at
`0x10100000` correctly rejected) → `VIRTIO-GPU 7`-`OK` → `INFO` → `SCAN` →
`PAINT` (QMP `screendump` = P6 1920×1080 with nonzero guest pixels →
`out/g6b_qemu_screen.ppm`) → `VIRTIO-INPUT-OK` → monitor `sendkey a`/`b`
→ `INP` ×4 → serial `Keys` → `KEY 00001e01`/`1e00`/`3001`/`3000` (exact
Linux codes) → `Ui` → `DOM| key 00003000` (the `inp.last` row on the
live DOM) → `VIRTIO-PAINT`. Virgl attempt confirmed the documented host
gate: `egl: no drm render node available` (WSL2 has no `/dev/dri`; the
d3d12 WSLg driver is not a DRM render node) — `--no-gl`/`virtio-gpu-device`
is the verified path. Runner script: `out/g6b_qemu_run.sh`.

**Bounded await + background frames (2026-09, stage-5 remainder):**
- **`Await`/`A` UART command** (`CMD_AWAI`, jit-gated): claims the first
  non-pending slot of `AWAIT_SLOTS`=4 u32s at `__ui_dom` header +16
  (0 idle / 1 pending / 2 resolved / 3 rejected; +12 `npend` is the
  pending-count fast test) and renders the `await.N` row `"pending menu"`
  → `AWAIT pending N`. All four pending → `AWAIT-REJ full` (bounded
  capacity, fail closed); a resolved slot is reusable. `DomAwait` is the
  kernel poll: drains every pending slot — `AWAIT-GET /bios/menu`
  (deferred router fetch marker) → `await.N` → `"resolved menu"` →
  dirty-marks the DOM. **`Throw`/`T`** (`CMD_THRO`) rejects the newest
  pending slot — `AWAIT-THROW /bios/menu`, `await.N` → `"rejected menu"`,
  `npend`--, slot reclaimable — the thrown/caught transition (state 3,
  now exercised); nothing pending → `AWAIT-THROW none`, not an abort.
  The slot logic lives in **`WasmAwait`/`WasmThrow`** (`dom.rs`; the UART
  handlers are thin `jal`s) and the same routines are the **`env.await`/
  `env.throw` guest imports** (`jit::import_stub`) — a lowered wasm
  `call env.await`/`call env.throw` claims/rejects a slot on the guest
  code path (exec-verified, both xlens — `jit::tests::
  start_ops_executes_await_throw_imports` and the new
  `start_ops_catch_reveals_a_rejected_row`). Signatures: `env.await`
  `()->i32` returns the claimed slot (-1 when full); `env.throw` `(i32)`
  rejects *that* slot when pending (a0<0 → the newest pending — the
  default). A third guest import, **`env.catch(i32)->i32`**, returns 1
  when the requested slot is rejected (state 3) and 0 for idle, pending
  or resolved slots, including out-of-range indices. `WasmCatch` (`dom.rs`)
  is a leaf query over `__ui_dom[AWAIT_SLOT_OFF + a0*4]`. The browser host
  (`kernel.ts createWasmHost`) now binds all three imports. `start_ops` now lowers i32 `local.get`/`local.set`/
  `local.tee`/`drop` and single-i32 call results: locals and call results
  live in a bounded s2..s5 pool (`local.set` repoints rather than copies —
  a pushed `local.get` keeps its value), results materialize into a fresh
  pool reg so the next call's arg loads cannot clobber a0. The UART
  `Throw N` parses an optional slot digit (`__uart_line[6]`); plain
  `Throw` keeps `a0=-1`. `DomAwait` resolves **at most one** pending slot
  per call (bounded O(1) IRQ work; the `Ui`/`Keys` polls call it
  `AWAIT_SLOTS` times to drain) — QEMU-deterministic: a UART command burst
  can no longer out-race the whole queue inside one tick. The **shipped**
  `bios-ui.wasm` uses it: `await fetchBios("/bios/menu")` in `App.svelte`
  parses to a fetch op + an `AwaitOp`, `emit-wasm.ts` imports `env.await`
  (`()->i32`) and emits `call env.await; drop` — the guest `_start`
  claims `AWAIT pending 0` at `Ui` and a tick resolves it. The browser
  host (`kernel.ts createWasmHost`) binds `env.await`/`env.throw`/
  `env.catch` against bounded `Set`s of pending and rejected slots
  (`await()` returns the index, `throw(slot)` rejects it, `catch(slot)`
  queries it, `drain()` resolves all); the interpreter `Host` gained
  default `await_op`/`throw_op`/`catch_op` and `binary.rs` accepts the
  `(0,1)`/`(1,0)`/`(1,1)` signatures.
- **Poll points:** `trap_timer` (the periodic tick) and `Ui`/`Keys` — the
  timer tick drains pending await slots asynchronously (all 4) and flushes
  a **background repaint** (`DomPaint` + `VioPaint`/`DispPaint`) gated on
  the `DOM_PAINTED` dirty-watermark, so input/nav/await mutations reach
  the scanout without a `Ui` command and without per-irq repaints.
- **Trap-frame correctness fix (found via real QEMU):** the trap entry
  frame now saves `ra` + `t0..t6` + `a0..a7` (16 slots, 128B rv64) — it
  previously saved only 8 regs, so a trap-time `jal` (DomPaint/VioPaint/…)
  destroyed the interrupted context's `t3..t6`/`a3..a5`/`ra`; a timer irq
  landing inside a normal-context `VioCmd` `wfi` resumed `vqc_poll` with a
  clobbered `t5` → load-access fault. `s0..s11`/`gp`/`tp` stay callee-saved
  per the ABI (`DomPaint`/`DomNav` already frame them).
- **`VIO_BUSY` ctrlq re-entrancy guard** (`__vio+0x5f0`): `VioCmd` sets it
  for the transaction and clears on every exit; `VioPaint` silently skips
  while set — a trap-time paint can never interleave on the shared ring
  mid-transaction.
- **Exec model:** in-trap `wfi` (SIE masked, SPIE latched) is a bounded
  poll pause, never a halt — the outer loop's kick+SEI path can never fire
  there, so halting would abort mid-trap. `sei_claims` bound 64→128 (the
  per-byte UART claims + repaint irqs + input burst + margin) and the timer
  budget gains a second post-input tick to exercise the dirty-check
  repaint. `STEP_LIMIT` 16M→24M covers the extra repaint.
- **TRAP format:** `trap_fault` now prints `TRAP-<scause>-<sepc>-<stval>`
  (the faulting address — how the `t5` clobber was diagnosed).
- **Evidence:** exec `vio_input_eventq_delivers_key` asserts
  `AWAIT pending 0..3` + `AWAIT-REJ full` + `AWAIT-THROW` + `AWAIT-GET`×3
  + `rejected menu` + ≥3 `VIRTIO-PAINT` (incl. the timer-driven repaint).
  **QEMU-verified:** serial `Await`×4 → `AWAIT pending 0`..`3` → `Throw`
  → `AWAIT-THROW /bios/menu` (slot 3 rejected) → the next timer tick
  drains the remaining three (`AWAIT-GET`×3 → `DOM| resolved menu`×3 +
  `DOM| rejected menu` → `VIRTIO-PAINT`), a post-resolve `Await` reuses
  freed slots, input `NAV cpu` intact, zero `TRAP` — a real multi-slot
  await with resolve+reject that paints concurrently with DOM events,
  bounded and nonblocking. (`AWAIT-REJ full` is exec-verified; on QEMU
  the tick resolves slots between sends so the bound never fills.)
- Still open within B53: guest-side JS `Promise`/`catch` object semantics
  (the slot queue is now a wasm import the shipped `_start` calls — a JS
  `await`/`throw` lowers to it, but there is no JS-visible `Promise`
  object or guest JS runtime yet), and the `wfi`-inside-trap hardware
  semantics differ per implementation (QEMU wakes on masked-pending; the
  model treats it as a poll pause).

B53 follow-on 9 (2026-10) — **native 32bpp DOM text paint (`DomPaint32`).**
`g6b-asm::dom` gained `DomPaint32`, a bounded native-resolution 32bpp glyph
painter that reads live `__ui_dom` rows and the 8×8 `__font` table and writes
B8G8R8X8 pixels directly into `__scan_fb` at the output's native geometry
(`g6b_spec_proxy` `hi_w`/`hi_h`), plus a full-frame clear. `FbExpandSel` now
dispatches GPU + DOM rows → `DomPaint32`, GPU + empty DOM → `FbExpand1`, and
VGA → `FbExpand`. `VioPaint` and `DispPaint` both call `FbExpandSel`, so the
same surface logic covers virtio-gpu and the uncore display engine. A
DOM-dirty watermark update at the top of `FbExpandSel` prevents nested timer
re-entry while the long native clear is running, and the `trap_timer` dirty
watermark check keeps background repaints bounded.

- `g6b-asm` gained `Module::scan_fb_addr()` and `exec::Smoke::scan_fb` so
  regression tests can inspect the native 32bpp surface.
- `g6b-wasm::jit::tests::dom_paint32_paints_native_32bpp_text_on_gpu_surface`
  asserts the first row of the first glyph (`U` from `UI-BOOT`) in native
  1920×1080 B8G8R8X8, and `DISP-OK`/`disp_committed` on a `display`-class
  uncore peripheral (`wants_disp_scan`) to avoid the virtio-input eventq and
  stay within `STEP_LIMIT`. It passed on both the focused `cargo test` and the
  full `python tools/g6b.py check` (independence, Bun tests/build, fmt,
  clippy, workspace tests, 13/13 `bios-regress`).
- Follow-on tests added for the three-way surface dispatch:
  - `dom_paint32_empty_dom_falls_back_to_fbexpand1` proves an empty
    `__ui_dom` on a GPU-class output lands the 640×480 plane 1:1 at
    `(640,300)` using `FbExpand1` instead of `DomPaint32`.
  - `dom_paint32_vga_surface_stays_magnified` proves `kernel.proxy.surface`
    `"vga"` forces `FbExpand` (×2 for 1920×1080 dpi=192) and reports
    `disp_sel.1 == 0`.
  - `dom_paint32_paints_native_32bpp_text_on_gpu_surface_rv32` proves the
    same native glyph paint on RV32 when a low entry (`0x0001_0000`) keeps
    the scanout address below the sign bit.
  - `g6b-wasm::binary::encode_empty_ui_module` is the tiny empty `_start`
    helper used by the fallback test.
- The 4bpp `__gr_plane` / `DomPaint` path remains intact for VGA-class output
  and for the legacy UART `Ui` re-dump.
- Hardware support claims remain as documented in `architecture/DISPLAY.md`:
  no AMD/NVIDIA modesetting, no PCIe BAR assignment, no HDMI hot-plug, the
  guest GPU path is not the Rust CSS engine or WebGL.

B50–B52 verification (2026-09-05): `python tools/g6b.py check` passed
independence, 15 Bun tests/build, fmt, strict Clippy and 196 Rust tests;
`python tools/g6b.py regress` passed all 13 cases, including shared UI HTTP,
fragmented headers, idle preconnections, ELF smoke and framebuffer output.
Native WASM tests execute the emitted import/visibility ABI; numeric JIT tests
execute lowered RV32/RV64 machine words. Local HTTP page/app/menu endpoints
returned 200. Optional LDC wasm-eh execution was skipped; no RTL/silicon or
full guest-browser claim follows from these host results. MIT headers and
upstream reference boundaries were retained, with no external dependencies.

B53-catch verification (2026-09-06): added guest `env.catch(i32)->i32`;
`g6b-wasm` `start_ops_catch_reveals_a_rejected_row` and
`compile.test.ts` "env.catch reports rejection without consuming it and
throw handles negative slot" passed; `bun test` 41 pass / 2 skip;
`cargo test -p g6b-wasm -p g6b-asm` green. `env.catch` is a query over the
same `AWAIT_SLOTS` state and does not consume the rejection. Host/browser
catch remains bound; compiler/parse.ts does not yet emit `{#await}`
`{:catch}` reactivity (no source pattern uses it).

Priors: `architecture/PLAN.md` (rewrite-from-spec + conformity + current state),
`architecture/ZEAL.md`, `kernel-spec/`, host `g6lc_qemu` `--loader bios`.

B60: `g6b-wasm::Asyncify` now drives a real step/resume loop: `run_start`
reserves an asyncify data region above `__heap_base`, `libwasm_await__void`
sets `__asyncify_state`/`__asyncify_data` so the instrumented wasm can unwind,
and `KernelHost` records the slot and implements `take_slot`/`resolve_slot`.
`Asyncify::new` correctly maps function-export indices to the body table when
imports are present, fixing the live LDC 1.43 / libwasm
`browser-ui/out/bios-ui-libwasm.wasm` path. `call_import` is now a
`Runtime` method with access to live globals, enabling host imports to mutate
asyncify state. A minimal asyncified module now sleeps and resumes through the full
`Asyncify::step`/`resume` loop in `g6b-wasm` tests. Still open: full D
`await`/`catch` Promise continuation lowering, `libwasmAwaitFailed` /
`libwasmAwaitError` rejection hooks, and `resolve_slot` performing actual
kernel/router I/O and writing the resolved value back to the guest. The
bounded guest engine still does not claim full guest-browser / JS Promise /
complete Asyncify rewind semantics.

B61-B68 (planned, 2026-09-06): the complete libwasm host ABI was measured
rather than estimated. `browser-ui/libwasm/source/libwasm/types.d` declares
**116** distinct `extern(C)` host imports and its declaration set is
byte-identical to the reference checkout, so the target is exact. Of those 116,
**3** are implemented (`libwasm_await__void`, `libwasm_get__string`,
`libwasm_add__string`); the remaining 113 are `assert(0)` stubs in
`g6b_kernel.d`, which is the correct fail-closed state. Usage across the 684
generated `bindings/**` files concentrates in eleven names plus
`Object_VarArgCall__*` (2,035 call sites through the
`Serialize_Object_VarArgCall` template).

The staged sequence is recorded in `architecture/LIBWASM-ABI.md`: B61
refcounted object table (`libwasm_add__object` / `removeObject` /
`copyObjectRef`, roots 1 = staging DOM, 2 = BoardSpec scope); B62 scalar
box/unbox, which requires refactoring `g6b-wasm::call_import` off its
i32-only operand coercion; B63 property get/set behind an allow-listed
per-receiver property registry; B64 `Optional!T` sret returns (landed; presence
flag offset verified from the `optional.d` source and the LDC 1.43 artifact); B65 a
bounded first-party JSON codec extending `g6b-spec::json` for
`Object_VarArgCall__*` (landed; `JSON_parse_string` / `JSON_stringify`, all twelve
`Object_VarArgCall__*` signatures, and an `argsdef` descriptor parser supporting
`Optional!T` and `SumType!(...)` are wired through `g6b-wasm`, `browser-ui/src/kernel.ts`,
`compiler/wasm-cell.ts`, and `libwasm/g6b_kernel.d`); B66 event handlers / timers / named
`libwasm_set__function` (re-entry guarded by committed DOM state and asyncify state); B67
a no-eval allow-listed Lodash/Moment interpreter; B68
typed-array views and promise combinators.

B61-B66, `getTimeStamp`, B67 Moment core, B68 promise combinators, and B68 typed
array / DataView `Create` are implemented. Still open: full Moment method set.
Permanently refused: `eval` in any form
(including the Lodash `=(...)` iteratee path that the reference `ldexec` JS
evaluates), the WebGL/WebGPU/RTC/XUL/Payment/SubtleCrypto binding families, and
any reading of a linking LDC artifact as evidence of a browser. B66 is now
guarded by committed DOM state and asyncify state; real re-entry from host
events/timers only fires when safe.

B61 verification (2026-09-06): the refcounted libwasm object table landed.
`crates/g6b-wasm/src/objects.rs` is a shared bounded `ObjectTable<T>` (4,096
live objects, slot freelist, explicit refcounts) used by `KernelHost` and the
g6b-wasm `TestHost`; `createLibwasmHost` mirrors it in TypeScript.
`libwasm_add__object` / `libwasm_removeObject` / `libwasm_copyObjectRef` are
declared in `g6b_kernel.d` (their `assert(0)` stubs removed), dispatched in
`Runtime::call_import`, and checked by the `wasm-cell.ts` ABI verifier, so a
shipped LDC artifact importing them is validated at build time. `copyObjectRef`
returns the same handle and increments; release frees only at zero; handles 1
and 2 are protected roots. Hosts that do not implement the trio return `Err`
from the trait default rather than fabricating a handle.

Two defects were found by the new tests rather than by inspection. The browser
`libwasm_get__string` silently returned `""` for a freed handle, which is the
use-after-free the design says must fail closed; it now raises. The `TestHost`
object vector allowed a handle to be reused after removal because it never
tracked frees at all; it now uses the real table.

Verified: `cargo test -p g6b-wasm` 51 pass / 1 ignored (5 new `objects` unit
tests plus 2 new interpreter dispatch tests, including a `Bare` host asserting
the fail-closed defaults); `bun test` 49 pass / 2 skip / 0 fail with 7 new
cases covering refcount, slot reuse, six parametrised lifetime violations and
the budget; `G6B_DUB_WASM=1 G6B_WASM_ASYNCIFY=1 bun scripts/build.ts` produced
a `fresh` verified asyncified LDC 1.43 artifact against the widened ABI;
`python tools/g6b.py check` and `regress` green.

Still open and unchanged: 110 of the 116 stock libwasm imports. The DOM handle
space and the object handle space remain separate (they merge in B63), and an
allocated object carries no properties until the B63 property registry exists.
Nothing here is a Promise/event/JS-runtime claim.

B62/B67 verification (2026-09-06): scalar box/unbox and the Lodash lane are
wired end to end, and a documented contract was found to be wrong and corrected.

The correction first. `architecture/LIBWASM-ABI.md` previously said arrow
functions were refused and that a no-eval "Tier A" still covered
`map`/`filter`/`find`. Both cannot hold: `lodash.d:606,614,621,628,635` shows
libwasm's own `putLocal` emitting an arrow function as the parameter whenever a
Lodash iteratee is a D delegate, so refusing arrow functions refuses every
predicate-taking method. The resolution is that those five strings are fixed
and compiler-generated, and all five merely call the guest indirect function
table; the host recognises them by identity and dispatches into wasm. `eval`
stays absent without costing the iteratee half of the library. The doc now
states this, and the ES6 table no longer claims arrow functions are refused
outright.

B62 landed: `LibwasmValue` in `crates/g6b-wasm/src/values.rs` models the boxed
scalar and vector shapes, and `g6b-wasm::Host` exposes typed `add_*`/`get_*`
methods. `Runtime::call_typed_import` decodes typed operands ahead of the
all-i32 table; `validate` admits the numeric libwasm add/get signatures;
`invoke` allows non-i32 signatures for imports while wasm-local bodies stay an
i32 machine. The 15 `libwasm_add__*` and 14 `libwasm_get__*` scalar/array
imports are declared in `g6b_kernel.d`, dispatched in `g6b-wasm`, mirrored in
`browser-ui/src/kernel.ts`, and verified in `wasm-cell.ts`.

B67 backend: `crates/g6b-js/src/lodash.rs` is a bounded command-buffer parser
(the `lodash.d:417-475` sigil convention), a `JsValue` model and an evaluator
over 37 methods, with `Iteratee` for guest dispatch. All twelve `ldexec_*`
imports are declared in `g6b_kernel.d`, dispatched in `g6b-wasm`, ABI-verified
in `wasm-cell.ts`, and mirrored in `browser-ui/src/kernel.ts`. Budgets: 256
commands, 64 KiB buffer, 5 params, 4,096 elements.

Lane difference, deliberate and documented: the browser host dispatches the
guest iteratee through `__indirect_function_table`; `KernelHost` cannot re-enter
a running instance, so a predicate chain fails closed with
`CallbackUnavailable` rather than computing a wrong answer without the
predicate. Closing that is B66, not B67.

One divergence was caught by test rather than inspection: `Object.create(null)`
has no `toString`, so the browser lane threw `TypeError: No default value`
where the Rust backend returned `"[object Object]"`. A shared `jsString` helper
now makes the two lanes agree.

Verified: `cargo test -p g6b-js` 55 pass (10 new lodash tests: sigil decoding,
all five boilerplates recognised as callbacks, hostile JS refused by name,
value chains, guest dispatch once per element, throw propagation, unsupported
method and budget failures, truncation fuzz, and an assertion that every
advertised method is reachable); `cargo test -p g6b-wasm` 53 pass / 1 ignored
(includes a new B62 scalar round-trip test proving i32/u32/i64/f64/bool/byte
round-trips and width preservation through `libwasm_add__*` / `libwasm_get__*`);
`bun test` 52 pass / 2 skip / 0 fail (new B62 scalar round-trip test in
`compile.test.ts`); fresh verified asyncified LDC 1.43 artifact;
`python tools/g6b.py check` and `bios-regress` green.

The B61–B62–B67 libwasm host surface is implemented. B63 is landed: the
`g6b-wasm::Runtime` typed `Object_Getter__*` / `Object_Call__*` dispatch, the
D host imports in `browser-ui/libwasm/source/libwasm/g6b_kernel.d`, the
signature verifier in `browser-ui/compiler/wasm-cell.ts`, and the fail-closed JS
handlers in `browser-ui/src/kernel.ts` are all in place with Rust and Bun tests.
The shipped asyncified LDC 1.43 artifact now uses the B63, B64, and B65 families when
D code imports them. B67 Moment core, B68 typed arrays / DataView Create are now wired.

**B59b (2026-09-08)** — the optional libwasm cell now has a **pinned**
compiler instead of an ambient one. `browser-ui/toolchains/ldc.lock.json`
names upstream `v1.43.0-beta1` (DMD 2.113.0, matching the carried
`runtime-v1.43.0`) and carries the upstream
`ldc2-1.43.0-beta1.sha256sums.txt` digest and byte size for each of the five
published host assets. `bun scripts/install-ldc.ts` downloads the asset for
the running host, checks size and SHA-256 **before** extracting, extracts into
`browser-ui/toolchains/<asset-dir>/`, re-reads `ldc2 --version` and deletes the
tree unless it is exactly the pin, then writes `toolchains/installed.json`.
Only `.gitignore` and the lock file are tracked, so the ~220 MB tree is
reproducible from the pin rather than vendored. `compiler/ldc-pin.ts` is the
sole reader and validates schema, 1.43-ness, tag/version agreement and the
upstream repository; a host with no published build (`windows-arm64`) is
refused with that message rather than downgraded.

`compiler/ldc.ts::findLdc` now prefers the pinned tree over every ambient
toolchain (only the `SVELTE_D_LDC`/`LDC`/`WASM_LDC`/`SVELTE_D_WASM_LDC`
env escape hatch outranks it), and `resolveToolchain().pinned` reports which
won. This is a correctness fix, not ergonomics: `cellInputHash` hashes the
compiler **binary content**, so the previously discovered host-built
`1.43.0-git-1218a47` produced an `inputs` digest nobody else could reproduce —
which is exactly why every build reported
`artifact=stale ... source/runtime/toolchain/ABI mismatch` and shipped a
zero-byte `out/bios-ui-libwasm.wasm`. With the pin installed,
`G6B_DUB_WASM=1 bun scripts/build.ts` produces a verified `fresh` 37,253-byte
artifact whose provenance records `LDC - the LLVM D compiler (1.43.0-beta1):`,
and subsequent plain builds keep it fresh from cache. The release bundles DUB,
so the LDC/DUB pair can no longer be mismatched. The `addon-wasi` package is
deliberately not pinned: the cell links `-defaultlib=` against the carried
runtime, so no prebuilt WASI druntime/phobos is used.

Two tests that had never actually executed were corrected rather than left
aspirational. `actual full LDC cell starts with the explicit DOM ABI` had a
frozen four-import list and a hand-written stub env; it now derives both from
the module and additionally checks that the provenance manifest matches the
bytes and names the pinned compiler. `executes the shipped LDC cell through
the actual host` asserted `UI-BOOT`/`CPU`/`Settings` text and >10 nodes — that
was only ever green because the artifact was empty. The shipped cell is the
component **shell** plus the kernel boundary: it mounts one `<main>` and drives
18 `/bios/...` GETs, one `holyc` line and one `register_endpoint` call through
`createLibwasmHost`'s fail-closed URL/method validation, and builds no setup
tree. The test now asserts that, so the gap cannot be silently misread as
implemented. Verified: `bun test` 96 pass / 2 skip / 0 fail; with
`G6B_TEST_LDC_CELL=1 G6B_TEST_LDC_FX=1` the two real-compiler probes run and
pass for the first time (14/14 in `build.test.ts`); `cargo test --workspace`
green; `python tools/g6b.py check` and `bios-regress` OK. No RTL/silicon,
guest JIT or guest-browser claim follows.

**B72 (2026-09-07)** — browser instance: `createBrowserContext` in
`browser-ui/src/kernel.ts` owns the `console`/`window`/`document` singletons,
with a bounded pollable console ring and `renderConsoleInto(el)` for a devtools
panel. Shape follows `kernel-spec/goosie` `internal/browsercontrol/types.go`
(`ConsoleEntry{level,data,timestamp}`, `ConsolePage{contextId, pageRevision,
entries, dropped}`) and `internal/js/runtime.go` levels
(log/info/warn/error/debug; `table` refused, no table renderer).

**Engine-agnostic by construction** — nothing in `createBrowserContext`
references WebAssembly, libwasm or the object table. The contract is
`bindings()` (allow-listed `name -> object`) + `global(name)` + `consolePage()`.
libwasm consumes it via ONE new import, `libwasm_global(name) -> handle`
(`g6b_kernel.d`, `wasm-cell.ts` `127,127->127`, `interp.rs` kernel lane returns
0); with the handle the existing `Object_Call_string__void(h,"log",msg)` reaches
members, so there is no console ABI. Plain JS and the devtools panel use the
singletons directly. Adding a second engine must not edit the context.

Honest properties: bounded ring reports `dropped` **and** `missed` (a poller
whose cursor fell behind is told, never silently skipped); instances are
isolated by `contextId` so a frame cannot interleave into its parent; rows are
`textContent` so logged markup is displayed not parsed; unknown globals are
`undefined`/handle 0, never a stub that swallows writes; singletons are
protected roots the guest cannot free; formatting is `String()`-per-arg with a
4 KiB cap and `[uncloneable]` for cycles — no `%s` mini-language. 17 Bun tests.

Boundary: a frame gets *its own* instance. It does **not** get to read a
cross-origin frame's console or DOM — same-origin policy forbids that
independently of this design, so no amount of local plumbing enables it.

**B73 (2026-09-07)** — golden-image PPM harness wired into `bios_regress.py`.
New `g6b css-render` and `g6b ppm-diff` CLI commands; `g6b-gr::canvas` adds a
pixel-accurate 16-colour canvas, PPM parser and per-pixel diff with tolerance;
`g6b-css::render` implements the first layout pass (block-flow children, margin
edge stacking, background-colour fill, border-width outlines, content-box vs
border-box, percent widths, display:none) and a colour-name/hex allow-list mapped
to the 16-colour BIOS palette. Shorthand expansion for `margin`, `padding`, and
`border` added to the parser, with `border-style` dropped (not rendered) and
`border-color` as a new property.

Five fixture families under `fixtures/render/` with committed goldens:
`box_basic`, `border_box`, `stacked`, `margin_collapse`, `percent_width`. The
`css_golden` `bios_regress.py` case renders each and runs `ppm-diff`; all pass.
The `margin_collapse` fixture intentionally documents the *current* non-collapsing
behaviour (gap = sum) so a future margin-collapse change must update the golden
and be reviewed. `percent_width` uses `w=64,h=32`. The renderer refuses unknown
colours rather than defaulting them; a test asserts a box with `chartreuse` and
`aquamarine` stays transparent/white.

Honest limits: no inline/inline-block/flex/grid, no margin collapse, no text
rendering (the canvas is box-only), no float, no font metrics, no CSS shorthand
for `border-*` or `background`, and `margin_collapse` golden would change if/when
margin collapse is added.

**B71 (2026-09-07)** — render debugging facilities. Three layers, documented as
methodology in `AGENTS.md` §"Render debugging methodology" with `kernel-spec/goosie`
`internal/css` + `internal/renderer` cited as the rendering-logic ancestor:
`g6b_css::parse_survey` (what CSS is missing — returns the sheet plus the sorted
unsupported-property list instead of refusing, for growing
`fixtures/css-features.json`); `g6b_css::inspect::explain` (why a value won —
DevTools-shaped trace keeping overridden candidates visible with
`!important`/specificity/source-order reasons, plus the resolved box;
`to_text()` and `to_json()`); and `createRenderInspector` in
`browser-ui/src/kernel.ts` (`diff` an `explain` JSON against the host browser's
`getComputedStyle`/`getBoundingClientRect`, whole-pixel tolerance on lengths
only; `describe` dumps the host view). 26 Rust + 10 Bun tests.

Design points worth keeping: `explain` reads the winner out of `cascade` rather
than recomputing it, so the debugger cannot disagree with the engine it
describes; the strict `parse` still refuses everything `parse_survey` tolerates,
so a survey cannot widen the render path; and a host without
`getComputedStyle` throws rather than reporting a pass. The browser diff is an
**external** oracle for computed values (legitimate evidence), unlike a
recognition score or a self-answered `supports()` — `RENDER-VALIDATION.md` §1,
§6. It compares computed values and one rect, not pixels; pixel truth stays the
golden PPM diff, still unwired into `bios_regress.py`.

**B70 (2026-09-07)** — render validation groundwork: `kernel-spec/goosie`
(MIT, `1039ae6`, tier U in `.licensing-tiers`) added as the read-only spec for
CSS cascade / box model / display list, per prime directive 1 (rewrite, do not
port). New `crates/g6b-css`: bounded CSS subset parse, specificity-ordered
cascade (`!important` > specificity > source order), and content-box/border-box
box model, 18 tests. `architecture/RENDER-VALIDATION.md` defines the two-track
methodology and `fixtures/css-features.json` the track-A backlog.

Two boundaries recorded because both are easy to get wrong:
1. `@browserscore/supports` and `browserscore.dev` measure feature
   **recognition**, not rendering correctness (upstream states this). A
   recognition score is therefore a backlog, never a correctness gate, and a
   self-reported score from our own engine is circular — a `supports()` that
   returns `true` for everything scores 100% while rendering nothing.
2. `goosie/AGENTS.md` and `svelte-d/AGENTS.md` are upstream tier-U artifacts,
   **not** governance here. Goosie's file mandates a Playwright + Chromium
   comparison gate, which prime directive 6 forbids; our gate is the golden PPM
   diff. Precedence is stated in `kernel-spec/README.md`.

Still open: golden-image harness wiring into `bios_regress.py`, inheritance
pass, shorthand expansion, and rasterising `color`/`background-color`. No
rendering engine is claimed — no float, flex, grid, or text shaping.

**B69 (2026-09-07)**: generic DOM method bindings (`setAttribute`/`getAttribute`/`removeAttribute`
and `classList.add`/`remove`/`toggle`/`contains` through `Object_Call`/`Object_Getter`) and a
bounded ES6 `Map` host surface (`libwasm_map_create`/`set`/`get`/`has`/`delete`/`clear`) are wired
across `g6b-wasm`, `g6b_kernel.d`, `wasm-cell.ts`, `kernel.ts`, and `compile.test.ts`. Rust and Bun
tests pass; QEMU execution was skipped because `qemu-system-riscv64` is not installed in this
environment. Still open: full Moment method set, D `Map` wrapper, and `Set`.
Value-returning iteratees remain impossible because the generated delegate ABI
is `bool`-only. None of this is a JS engine.

**B72 (2026-09-07)** — DOM event model and TTF font display unit foundations.
`g6b-dom::event` lands `Event`, `EventInit`, `addEventListener`,
`removeEventListener`, `dispatch_event` with capture/bubble propagation,
`stopPropagation`, `preventDefault`, and `EventHost` callback indirection so
`Node` stays `Clone`. 8 Rust tests pass. `g6b-ttf` is added as a first-party
wrapper around the pinned `fontdue = "0.8.0"` crate: `BiosFont::from_bytes`,
`render`, `metrics`, and `blit_glyph` into `g6b-gr::Canvas`. `check_independence.py`
is taught an explicit `_ALLOWED_EXTERNAL` set so pinned crates do not violate KD0.
Architecture updates in `BROWSER.md` (event model) and `DISPLAY.md` (TTF unit).
`g6b-cli` gains `css-paint` to render `g6b-ui::setup_html` through
`g6b_css::render_ui_to_canvas` with approximate colour mapping and text layout.
Still open: `g6b-js` AOT event-listener ops, `libwasm`/`browser-ui` event ABI,
CSS-rendered hit boxes for pointer/keyboard dispatch in `BrowserSession`, and
using `g6b-ttf` to replace the 8×8 built-in font in the CSS text path.

**B73 (2026-09-07)** — TTF font integration, CSS hit boxes, and host event
boundary. The OFL Inconsolata font is bundled under `fixtures/fonts/` and loaded
through `g6b-ttf::default_bios_font`; `g6b-css::render` uses `BiosFont` metrics
and `blit_glyph` for the CSS text cursor when `DrawText::Yes`, with 8×8 fallback.
`g6b-css` now produces `RenderOutput { canvas, hit_boxes }`: each painted block
gets a `HitBox` carrying DOM path, `id`, tag, and bounding rect. `BrowserSession`
gains `BrowserEventHost`, `hit_boxes`, `add_event_listener`, `remove_event_listener`,
`dispatch_pointer`, and `dispatch_key` using `Node::dispatch_event`. `g6b-wasm`
adds `addEventListener`/`removeEventListener`/`dispatchEvent` to the `Host` trait
and `call_import` dispatch. `BrowserSession::listeners_run` executes AOT listeners
through `g6b_js::run` with `{detail}` substitution and re-enters libwasm by
cloning the module and calling `g6b_wasm::run_with_fuel_mut` with an event object
handle. `KernelHost` collects pending libwasm listeners during `_start` and
`BrowserSession` persists `wasm_module`, `wasm_objects`, and `wasm_handles` for
re-entry. D event imports added to `browser-ui/libwasm/source/libwasm/g6b_kernel.d`,
JS event stubs added to `browser-ui/src/kernel.ts` for both wasm hosts, and the
libwasm ABI verifier in `browser-ui/compiler/wasm-cell.ts` accepts the new
signatures. `g6b.py check` and `bios-regress` green.

**B74 (2026-09-08)** — CSS pointer-hit dispatch tests and propagation. The
`g6b-css::render` `Cursor` was missing its `canvas` reference, so nested block
painting and hit-box collection were silently disabled; `paint_block` now sets
`cursor.canvas = Some(canvas)`. CSS hit-box tests added: `hit_boxes_record_block_ids_and_paths`,
`hidden_and_display_none_are_excluded_from_hit_boxes`, and
`hit_boxes_support_reverse_lookup_by_coordinate`. `g6b-kernel` adds
`browser_session_pointer_dispatch_uses_css_hit_box` and
`browser_session_pointer_dispatch_propagates_capture_then_bubble`, proving
`BrowserSession::dispatch_pointer` finds the CSS hit target, routes through
`Node::dispatch_event`, and fires capture/target/bubble listeners in order.
`path_to_id` returns a `<body>`-relative path matching the CSS hit-box convention.
`g6b.py check` and `bios-regress` green.

**B75 (2026-09-08)** — display outputs split from the VGA surface (P1+P2 of the
display-output plan). Root cause found first: `FbExpand` sourced the 4bpp
`__gr_plane` unconditionally, so the upscaled ZealOS-intent plane *was* the
HDMI/virtio-gpu picture, and `wants_virtio_gpu()`/`wants_disp_scan()` chose a
transport at generate time with no runtime arbitration at all.
`g6b-spec` gains `OutputClass` (`pcie-linear-fb` > `uncore-scanout` >
`virtio-gpu` > `none`), `Surface` (`vga`/`gpu`), `DisplayOutput`, `Pcie`,
`display_outputs()`, `default_output()`, `default_surface()`, `surface_toggle()`
and `wants_pci_scan()`. The ladder is over **validated framebuffers, never
vendors**. `g6b-gr::proxy::Proxy` gains `outputs`/`active`/`surface`,
`select_output`, `set_surface`, `toggle_surface`, `select_line` (`DISP-SEL`) and
`to_ppm_gpu`, which **refuses** a canvas that is not native geometry rather than
upscaling it; `bar_h` is 0 on the GPU surface because the status is a real DOM
node there. `/bios/display` GET/POST is the single toggle mechanism for the
browser (`#disp-toggle`, absolutely positioned top-right), HolyC
(`DisplayPrint`/`DisplayToggle` + the new `DisplaySurface` builtin) and the
kernel (`BrowserSession::surface`, `toggle_surface`, `proxy()`).
`g6b-css` gains `position:absolute` + `top`/`right`/`bottom`/`left` with a
containing-block model, an out-of-flow drain pass so absolutes paint on top
without moving the flow, and value-level survey reporting so the real
`position:fixed`/`relative` stacking CSS drops-and-reports instead of failing the
sheet. Two latent bugs fixed en route: `DrawText::No` never actually suppressed
glyphs, and `Cursor` was missing its canvas so nested blocks were measured but
never painted (B74). `check_display()` refuses a `pcie.mmio` window that swallows
any peripheral, `dram_base` or the ECAM base — QEMU virt's 32-bit PCIe window is
`0x40000000..0x80000000`, exactly the ai-island GEMM block, so the two cannot
coexist. REQUIREMENTS now state the AMD AtomBIOS/DCN + NVIDIA GSP refusal and the
HPD/EDID contract-revision ask (drafted as revision 2 in `hdmi-display.md`).
`g6b.py check` and `bios-regress` green.

**B76 (2026-09-08)** — guest-side display mux and the surface-gated blit (P3+P4
of the display-output plan). New ASM IR purposes `PciScan` and `DisplayMux`.
`PciProbe` walks bus-0/fn-0 ECAM for base class `0x03` and accepts BAR0 only if
it is a memory BAR, nonzero and inside `pcie.mmio` (`PCI-GPU` /
`PCI-GPU-DEMOTED` / `PCI-GPU-NONE`); it never assigns a BAR and never mode-sets.
`DispSel` walks the candidate ladder, latches the first **present** rung into
`__disp` (`__vio+0x600`) and prints `DISP-SEL <class><surface>`; an explicit
`kernel.proxy.surface` overrides the rung default so guest and host agree.
`proxy_geom` gained a `proxy_outputs` table (header + one 6-word record per
candidate) after its eight legacy words, so existing offsets are unchanged.
`FbExpand` was generalised into `expand_node_named`, yielding `FbExpand1` (scale
1, centred) alongside it, with per-copy loop labels and a single shared
`vio_pal`; `FbExpandSel` picks between them from the latched surface and both
`VioPaint` and `DispPaint` now route through it. **This is the concrete fix for
the original complaint**: on a GPU-class output the 640×480 plane lands 1:1 at
(640,300) of a 1920×1080 scanout instead of being magnified ×2, proven by
`gpu_surface_places_the_plane_1to1_instead_of_magnifying_it`; the ×2 upscale is
still proven on the VGA surface by the existing test, now explicitly pinned with
`"surface":"vga"` rather than being allowed to become unreachable.
Exec model gains a read-only PCIe ECAM window, a modelled stdvga-shaped
controller, `Smoke::disp_sel`/`pci_fb`, and `Module::vio_bss_addr`. Two real
bugs found: the interpreter never decoded `sltu` (added to the IR, encoder and
model — the BAR range check needs a genuine unsigned compare, not the signed
sign-bit tricks used elsewhere), and `DispSel` initially ignored the surface
override. HPD is read only at contract revision 2 and reported `HPD_UNKNOWN` on
revision 1 — the model reports rev 1, so nothing claims hot-plug detection.
New fixture `fixtures/g6lc64-pcie-gpu.json` plus `disp_sel_pcie` and
`disp_sel_vga` regression cases; `disp_scan` now also asserts `DISP-SEL 21`.
`DomPaint32` is now implemented (see B53 follow-on 9 above). Still open:
the per-output geometry jump table, which is unnecessary until EDID reports
differing modes.
`g6b.py check` and `bios-regress` green.

B76 follow-on (2026-09-08) - **runtime `__disp` geometry.** The scanout path
no longer reuses the gen-time `g6b_spec_proxy` default: `DispSel` latches the
winning rung's `w`/`h`/`stride` into `__disp` and every consumer reads them
there. `FbExpand`/`FbExpand1` compute the integer scale from the latched mode
(new IR op `Op::Divu`, clamped 1..=64) plus the centred letterbox and
right-row pad - the mode (`fit`/`fill`/`dpi`) is still a gen-time pick between
divide forms, but the operands are runtime. `DomPaint32` clears `w*h` words and
addresses glyph rows by the latched stride. `VioScan` runs *after* `DispSel`
(it was emitted inside the earlier virtio call block), gates on
`__disp.class == VirtioGpu`, and sizes CREATE_2D/TRANSFER/FLUSH from `__disp`;
`DispPaint` gates on `UncoreScanout` and programs the engine + `G6FB`
descriptor from the latch, so a backend never commits a surface it did not win
(previously `DispPaint` painted whenever the engine MAGIC was present, even
when PCIe won the ladder). `__scan_fb` is sized as the max across
`display_outputs()` so every rung's mode fits. Per-output jump table retired
entirely: the runtime scale covers differing output modes, and EDID (contract
rev 2) can land without codegen changes. Encoder/executor gained `s8`/`s9`.
Two host-model bugs found: `VioScan` ran before `DispSel` could not have read
the latch (fixed by the reorder), and the executor never truncated effective
addresses on RV32 - `la`/`auipc` at `0x8xxx_xxxx` sign-extended into the u64
register file and every load/store/`jalr` bounds-check missed. `eff_addr`
now wraps `rs1 + imm` at 32 bits for xlen=32. New exec tests:
`fb_expand_follows_the_disp_latch_not_the_gen_time_proxy` (poked 1280x720,
both xlens), `fb_expand_sel_dispatches_per_output_geometry` (one latched
1600x1200, `vga` surface -> scale-2 fit at (160,120), `gpu` surface -> 1:1 at
(480,360)), and `dom_paint32_uses_the_disp_latch_geometry` (`FbExpandSel` ->
`DomPaint32` at a poked 800x600, pixel-checked glyph cells at the latched
stride). The PCIe-linear-fb paint path is now closed: `DISP_SEL_FB_LO`
doubles as the blit destination pick - nonzero means the latched output has
its own linear window (the pcie rung's accepted BAR), so `FbExpand`/
`FbExpand1`/`DomPaint32` write it in place and `PciPaint` is just
`FbExpandSel` + `fence` + `PCI-PAINT` (gated on `__disp.class ==
PcieLinearFb` and `DISP_PCI_FB != 0`; no doorbell, the BAR is the display
memory). The exec model keeps a `VIO_FB_MAX`-sized BAR shadow
(`Smoke::pci_fb_img`) - the aperture is device-sized because the read-only
probe cannot size BARs. `PciPaint` is also wired into the `Ui` repaint lane
and the timer tick beside `VioPaint`/`DispPaint` (each self-gates on
`__disp.class`); `Ui` deliberately still skips `DispPaint` - the uncore
repaint is covered by the timer's dirty-DOM watermark and a second full
`FbExpandSel` inside UART IRQ context would double the frame cost.
`pci_probe_accepts_a_linear_bar_and_wins_the_ladder`
asserts `PCI-PAINT`, nonzero BAR pixels at the 1:1 offset, and an all-zero
`__scan_fb` (proving the fallback was not painted); the demoted case stays
quiet and falls through to virtio. `g6b.py check` and `bios-regress` green.

B77 (2026-09-09) — modern RGBA render lane (`g6b-css::render32`) completed and
wired into the host tool-chain. `g6b-gr` Canvas32 surfaces, `g6b-img` PNG/SVG/
icon assets, `g6b-ttf` bundled fonts, `g6b-css` `rgba()`/opacity/rounded-corners/
images/SVG/icons/font-properties all pass focused tests. The `render32` parser
now uses `parse_survey` so real-world stylesheets with unsupported properties
fail closed per-property, not per-page. `g6b-html` `to_uart_lines` emits `img`
`alt` text and skips `svg`/`canvas` for the UART fallback lane. `g6b-cli`
`css-render` gained `--modern` and `--assets DIR` to exercise the new lane from
the command line. `g6b-kernel` exposes `ui_ppm32`/`ui_ppm32_output` (track-A true-
colour setup-page PPM) and a regression test proving the setup page renders a
non-empty RGBA PPM. `g6b-css` re-exports `AssetMap`/`FontSet` so callers can use
`render32` without extra crate deps. Still open: `g6b-spec` `files.assets` flag +
`g6b-http` asset mount, `g6b-ui`/`browser-ui` modern CSS (80s BIOS look + icons/
logo) and render32 goldens in `bios_regress`. `g6b.py check` and `bios-regress`
green.

B78 (2026-09-09) — high-definition 80s BIOS look applied to the browser UI and
static setup page. `browser-ui/src/App.svelte` now emits a dark navy/cyan/amber
color scheme with rounded corners, Inconsolata typography, translucent panels and
a clear status strip. The generated `out/bios-ui.css` is embedded into
`g6b_ui::setup_html` and picked up by `g6b-kernel::ui_ppm32`; both `g6b-ui` tests
and the `ui_ppm32_renders_setup_page` regression pass. Unsupported properties are
ignored by `g6b-css::parse_survey` and apply only in real browsers. Still open:
`g6b-spec` `files.assets` flag + `g6b-http` asset mount and render32 goldens in
`bios_regress`. `g6b.py check` and `bios-regress` green.

B79 (2026-09-09) — tabbed BIOS setup UI, and the three layout defects that were
blocking it. Rendering the real page at the virtio-gpu scanout geometry showed
a full-width column, table cells stacked one per line, and tabs that could only
ever be coloured words. All three were `g6b-css` gaps, fixed against the
`kernel-spec/goosie` `internal/renderer/layout.go` algorithms (rewritten, not
ported) and documented in `architecture/RENDER-VALIDATION.md` §8:
(1) `max-width`/`min-width` clamp the used width and CSS 2.1 §10.3.3 solves the
`auto` horizontal margins, so `margin: 0 auto` centres;
(2) the inline formatting context was split — `inline_children` appends into the
caller's run instead of recursing into `children_layout`, whose trailing
`flush_items` used to end the line after **every** inline element, which is why
`<th>A</th><th>B</th>` stacked; `is_block_for` also honours `display`;
(3) automatic table layout (`table_columns` max-content measurement +
`distribute`, `row_layout` two-pass with a shared row height) and
`display: inline-block` as an atomic inline that keeps its own background,
border, padding and radius. No colspan/rowspan/`table-layout: fixed`/border
collapse.
UI: `g6b_ui::setup_html` now emits a tab strip (`role="tablist"`, per-tab
`role="tab"`/`tabindex`/`aria-selected`, `.bios-tab`/`.bios-tab-active`) directly
under the banner, a status bar beneath it, panelled sections and a keyboard hint
footer; the chrome CSS lives in `setup_html` because `g6b-css` matches only
element/`#id`/`.class` selectors, while `browser-ui/src/App.svelte` keeps only
browser-side effects (hover, focus ring, zebra rows, scanline wash). New CLI
`g6b display-proxy-32` and `g6b ui-ppm32`, `g6b_kernel::proxy_ppm32` +
`Proxy::to_ppm32` (GPU surface renders at the scanout geometry instead of
upscaling the 640x480 plane), and `tools/ppm2png.py` as a stdlib-only viewing aid.
Real bug found in the harness: `tools/bios_regress.py` decoded BIOS stdout with
the Windows locale codepage, so the first non-cp1252 UTF-8 byte in the new
keyboard hint killed six cases with a `UnicodeDecodeError`; it now decodes
`utf-8` explicitly. `g6b.py check` and `bios-regress` green.

B80 (2026-09-10) - the generated libwasm cell now builds the real setup tree and
fills it from BoardSpec JSON, and the guest engine was corrected to accept what
LDC actually emits. Four defects, in the order they surfaced:
(1) `compiler/parse.ts` pushed every non-self-closing element onto its parent
*and* onto the stack, so each node was emitted twice and every close re-emitted
the whole subtree - `App.svelte`'s 81-node chrome lowered to 1,020 `createElement`
calls. Only the pop appends now.
(2) `compiler/print-d.ts` emitted bare `setProperty`/`appendChild`; they are
qualified through `libwasm.dom` and the startup verifier's `Element` double in
`compiler/wasm-cell.ts` grew the attribute/property methods `_start` actually
calls.
(3) `printReady` now keeps every fetch handle and, behind
`libwasm_await_supported()`, awaits `/bios/menu/<id>`, parses the response with
`parseJSON!ThreadMemAllocator` (fast-wasm takes the allocator as its first
template argument) and appends label/value/access rows into the matching
`menu-<id>-body`. Data retrieval stays JSON/text only; Svelte still owns the HTML.
(4) `g6b-wasm` refused the resulting artifact twice over. `0xc0..=0xc4` - the
sign-extension proposal, which LDC 1.43 emits for D `byte`/`short` casts - is now
decoded, validated and interpreted as a unary conversion (`i32.extend8_s` etc.),
with `0xc5` still rejected. `MAX_FUNCTIONS` 256 -> 1,024 and `MAX_LOCALS`
256 -> 4,096, because the real cell declares 942 functions; module bytes, memory
pages, operand stack, control depth, instruction count and fuel are untouched, so
the byte/memory/time envelope is unchanged. `architecture/WASM.md` records both.
The shipped artifact is `via=dub artifact=fresh verified asyncified LDC artifact
(wasm EH + asyncify)`; a new `compile.test.ts` case instantiates it through the
real host with a mock `/bios/` fetch and asserts the injected rows are present.
`bun test` 97 pass / 2 skip, `g6b.py check` and `bios-regress` green.

B81 (2026-09) - the libwasm LDC cell is now the source for the host CSS
scanout path. `g6b-kernel::KernelHost` was already able to run `_start` against
a fresh mount under `#libwasm-root`; this pass added `dom_to_html` (with hidden
skip, text/attribute escaping, void-tag and style/script handling), immutable
`find_node_by_id`/`first_descendant_by_name`, and `renderable_setup_html`.
`ui_ppm`, `ui_ppm_output`, `ui_ppm32`, `ui_ppm32_output` and `ui_ppm32_output_at`
now: (1) run `BrowserSession` when the libwasm lane is live, (2) extract the
libwasm `<main>` from `#libwasm-spa`, and (3) wrap it in a self-contained
`<html><head><style>` document so the CSS raster paints the Svelte-built tree
without duplicating the static `#bios-ui` shell. The old debug
`probe_libwasm_import_types` test was removed, Clippy warnings in the libwasm
host were fixed, and `python tools/g6b.py check` stays green (independence, Bun
tests/build, fmt, strict Clippy, workspace tests, 13/13 bios-regress cases
including `dom_js_ui_boot`). Real QEMU screendump is the next verification step
and depends on the separate `g6lc_qemu` build.

**B82 (2026-09)** — cut misleading UI lanes (web-engine PR 1). Host
`BrowserSession` no longer falls back to the MVP encoder wasm when the LDC
cell fails or is absent: `kernel.ui=svelte-d` requires the libwasm artifact
and `_start` errors are session failures (`BROWSER-ERROR`), not a second
module. Hit boxes and `ui_ppm*` serialize the **live** Svelte tree
(`live_render_html`). `/ui/ui.wasm` (host HTTP and guest `__ui_wasm`) is the
LDC cell when live. `setProperty(..., "style")` writes the same style
attribute as `element.style`. `WasmJit` / `WasmStart` remain the VGA glyph
face (MVP `start_ops`); they are documented as not the web engine.
`LIBWASM-ABI.md` B70 now names the real hole (persistent instance, live CSS,
frame present) instead of claiming callback execution is pending.

**B83 (2026-09)** — Svelte `fetch()` and `<img src>` through the D cell and
`/ui` file server. `g6b_fetch` (print-d) already emits `env.fetch`; the kernel
host now serves local `/ui/…` files from the same router as `/bios/…` menu
JSON. `setProperty("src")` is allowed for `/ui/*.svg|png|jpg|ico` (remote /
`javascript:` refused). `HttpFiles.assets` mounts `fixtures/ui-assets/g6lc.svg`
as `/ui/g6lc.svg`. `ui_ppm32` loads those files into the CSS `AssetMap` so
render32 paints `<img>`. GLES2 listing documents `u_dom` as the wasm-mutated
Canvas32 (`composite_ppm32`). App.svelte carries `#bios-mark`. The LDC cell
picks the img up on the next `G6B_DUB_WASM=1` rebuild; host HTTP and CSS
assets do not wait on that.

**B84 (2026-09)** — g6b-kernel is the wrong place to hook libwasm types.
`libwasm_global` no longer returns 0 with a "kernel cannot host window"
comment; the UI-thread `Host` interns `window` / `document` / `console`.
`KernelPort` (`g6b-kernel::RouterPort`) is the only kernel I/O the wasm
cell may call. `Host::get_root` / `add_css` match svelte-engine `spa.ts`.
goosie `:hover` is live (`data-hover` + `g6b-css`). `BrowserSession::tick`
presents GLES2 `u_dom` when the DOM is dirty. Handle 2 is still the first
`createElement` until the LDC cell's `getRoot()` is rebuilt.

**B85 (2026-09)** — architecture names the interactive UI as a browser that
loads the svelte-d LDC cell (`WasmUi`) on a UI thread and presents goosie
Canvas32 through GLES2 `u_dom` onto virtio-gpu / HDMI / host-GL. The cell is
not a kernel type and not guest `WasmStart`. `BrowserSession` keeps one
persistent instance (module, object table, interned window/document,
`JsExports`) so live DOM mutation and JS exports survive `tick` and pointer
dispatch. Tab clicks restyle `bios-tab-active` on the live tree.

**B86 (2026-09)** — `WasmUi::call` / `call_listener` re-enter the persistent
cell without empty KernelHost reconstruct. Interned `Event` objects carry
`type`/`target`/`detail`/`clientX`/`clientY`/`cancelable`/`defaultPrevented`.
`preventDefault` on that object skips the Rust tab default action. D
`getRoot` is now an `env.getRoot` host import (svelte-engine
`querySelector('#root')`); the shipped LDC blob still inlines `return 1`
until `G6B_DUB_WASM=1`.

**B87 (2026-09)** — cell-owned tab/refresh/JSON. `App.svelte` `on:click`
lowers through print-d to `g6b_listen(id, "click")` (listener 0). The host
maps that to `Listener::Cell`, which `preventDefault`s and runs `select_menu`
+ `/bios/menu/{id}` fetch (or `refresh()`). Rust `select_menu` is the default
action only. The shipped LDC cell has not emitted `g6b_listen` yet;
`bind_cell_clicks` covers tabs and `#refresh` until `G6B_DUB_WASM=1`.

**B88 (2026-09)** — live CSS. `g6b-css::Engine::paint(&Node)` rasters the
Svelte tree without HTML serialize/parse. `DirtyFlag` is Style/Layout/Paint
on `g6b-dom::Node`; skip-if-clean walks `dirty_union`. Goldens:
`ui_tab_cpu_ppm32`, `ui_tab_hover_ppm32`, `ui_tick_skips_clean_frame`.
Track-B 4bpp `ui_ppm` downsamples that Canvas32 to nearest PALETTE (flatten
over white); `g6b_css::render` stays for `css_golden` fixtures only. Dirty
tiles landed in B90.

**B89 (2026-09)** — UI hart + timers. When `kernel.tasking` is on,
`Role::Ui` / `Job::Ui` on `ui_hart` is the `BrowserSession::tick` body.
`TimerHeap` implements B66 `setTimeout`/`setInterval`/`clear*` and a
bounded `requestAnimationFrame` (ids start at 1, never 0). Due callbacks
re-enter through `WasmUi::call`. BoardSpec `kernel.proxy.fps` admits 100
and 144 (auto picks 144 when `detected_hz >= 144`). Skip-if-clean stays
the present budget.

**B90 (2026-09)** — Dirty-tile present. `Engine` records a pixel bbox
(`DirtyRegion::from_diff`) and splits it into 64 px tiles (collapse to one
rect past 64 tiles). `tick` paints then `present_scanout`: blit those tiles
of Canvas32 into modelled `__scan_fb` (X8R8G8B8, flatten over white) and
emit `TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH` of just those rects
(`SCAN-TRANSFER` / `SCAN-FLUSH`). Skip-if-clean is `SCAN-SKIP` / no
TRANSFER. GLES2 listing documents `glTexSubImage2D` per tile. Check
evidence is host-modelled `scanout_ppm` vs `ui_ppm32` (`ui_scan_fb_matches_css_ppm32`,
`ui_tab_cpu_dirties_scanout_tiles`). QMP Main→CPU→Memory tab shots stay
`tools/qemu_tab_shots.sh` on remote g6q (2D `virtio-gpu-device`; WSL2 has
no DRM). Guest `VioPaint` is still full-frame unless `__ui_cap` WEB_PRESENT.

**B91 (2026-09)** — Guest dirty-tile present + compact persist. `__ui_cap`
(`G6CP`) holds a live node count and ≤64 dirty rects. When the exec model
packs `GuestWebPresent` (BrowserSession Canvas32 + tiles), `VioScan` skips
the green band fill and `VioPaint` TRANSFERs those tiles then consumes
them (`VIRTIO-PAINT-SKIP` on a later `Ui`). VGA `start_ops` / 48-row
`__ui_dom` / glyph `FbExpandSel` stay the text face. The LDC cell is not
JIT’d in S-mode; do not grow `start_ops` to `Object_Call`.

## Remaining web-engine schedule (plan-endpoint)

Do these on `E:\cva6/g6lc_bios` in this order. Do not grow guest `start_ops`
into `Object_Call`. B12b–B13 and B54 are a different axis. Track-B 4bpp
`ui_ppm` is landed (live Engine downsample). Leftovers: `WasmJit` names, QMP.

| Next | Depends | Work |
|---|---|---|
| **B86** | B85 | **landed** — `WasmUi::call` / `call_listener`; Event `clientX`/`clientY`/`preventDefault`; D `getRoot` is a host import. Shipped cell still `return 1` until `G6B_DUB_WASM=1` |
| **B87** | B86 | **landed** — `on:click` → `g6b_listen`; host `Listener::Cell`; Rust `select_menu` is default action. Shipped cell uses host bind until `G6B_DUB_WASM=1` |
| **B88** | B86 | **landed** — `g6b-css` `Engine::paint(&Node)`; DirtyFlag Style/Layout/Paint; goldens `ui_tab_cpu_ppm32` / `ui_tab_hover_ppm32` / `ui_tick_skips_clean_frame`; 32-bit session path no longer serializes HTML. Track-B 4bpp `ui_ppm` / `ui_ppm_output` downsample the same canvas (`ui_ppm_is_live_engine_downsample`); `g6b_css::render` is fixture-only |
| **B89** | B86 | **landed** — `Role::Ui` on `ui_hart` runs `tick`; `TimerHeap` for `setTimeout`/`setInterval`/rAF (id > 0); BoardSpec `fps` 100/144; skip-if-clean |
| **B90** | B87–B89 | **landed** — dirty-tile GLES2 `u_dom` + virtio-gpu `TRANSFER_TO_HOST_2D`/`FLUSH`; host blit of Canvas32 into modelled `__scan_fb`; check vs `ui_ppm32`. QMP tab shots: `qemu_tab_shots.sh` / remote g6q |
| **B91** | B90 | **landed** — `__ui_cap` compact persist + dirty-tile `VioPaint` of host-packed Canvas32. `start_ops` not grown. |
| **B91b** | B91 | **landed** — `GuestCellLive` / `WebFeed` … UI-thread WAT throw/await. **B91b+ landed:** `_start` keeps `asyncify_*`; scratch above D heap; `MAX_MEMORY_PAGES` 64. **B91b++:** Flatten deleted `ready()`’s catch around await (abort stub f70 via `_d_throw`). Interpreter maps `{unreachable;end}` abort stubs to wasm-eh throw; `run_start` fail-softs unhandled D abort after rewind (empty `catch (Exception e)` intent). `print-d.ts` splits DOM try from `.await` and wraps `parseJSON` only. Shipped wasm unchanged until `G6B_DUB_WASM=1`. **JS↔wasm EH:** host `TypeError`/`DOMException` (libwasm WebIDL `Node.appendChild` / `Document.createElement` / Request) become wasm-eh tag 0; wasm `throw` is `unhandled wasm exception` at the JS host. `start_ops` unchanged. |
| **B91c** | B91b | **landed** — after `_start`, virtio-input / UI-hart events re-enter registered D delegates through export `jsCallback(ctx, fun, eventHandle)` (table `get(ptr)(ctx, handle)` if the export is absent). `Object_Call_EventHandler__void` becomes `Listener::Delegate`; `libwasm_set__function` names whose name is an input event (`click` / `onclick` / `keydown`, …) fire on `dispatch_pointer` / `dispatch_key`. Shipped LDC cell has no `jsCallback` and keeps `Listener::Cell` / `g6b_listen` until `G6B_DUB_WASM=1`. `start_ops` unchanged. |
| **B91d** | B91c | **landed** — `G6B_DUB_WASM=1 G6B_WASM_ASYNCIFY=1` fresh verified cell: `jsCallback` export, `getRoot` + `add_event_listener` imports, `g6b_listen` from `_start` (host `bind_cell_clicks` skipped). `print-d.ts` hoists tbody handles out of the DOM try. `start_ops` unchanged. |
| **B92** | B88–B89 | **B92g landing** — Svelte chrome; session pool; intern; `vars={frameVars}`; gated outbound `http(s):` (`kernel.http.outbound` on appliance/desktop/full; kernel fetch → hw TCP; never `-netdev` / iframe KernelPort). Nested `/ui/*.wasm` later. **B92f/h/i later** — `app:ssh`, drag, elevation. [`architecture/plan-iframe.md`](architecture/plan-iframe.md) |
| **B93** | B92g | **landed** — crate `g6b-hw`: virtio-net DeviceID 1 probe, catalog, isolated NAT/TCP/UDP, named host NIC, display probe, **USB-key + pointer HID**. Fetch is kernel→hw TCP (HTTPS not in hw). **`g6b-zealcli`:** VGA mouse-less ZealOS CLI (`HOLYC_BUILTIN_NAMES`, `LoadUI`, `kernel.cli.boot=auto` yields to browser-ui on GPU). No hw dep. [`architecture/g6b-hw.md`](architecture/g6b-hw.md) [`architecture/g6b-zealcli.md`](architecture/g6b-zealcli.md) |
| **B94** | B93 | **landed** — `g6b-zealcli` redesign into the minimally dependent face. Container (`screen`): `kernel.cli.{rows,cols,scrollback}`, bottom-aligned scrollback, prompt on the **bottom row**, PgUp/PgDn + `scroll`, optional `kernel.cli.mouse` (wheel/click, off by default). Input (`input`): one Linux `KEY_*` alphabet for USB HID / virtio-keyboard / UART, line editor + history. Ports seam (`ports`): `VolumePort`/`NetPort`/`FlashPort` lent by `g6b-kernel::zealcli` (no `g6b-hw` dep). Modules: read-only `vi`, ZealOS drives (`fsview`, `KEY-FAT:/…`), generated `man`, `settings` overlay → BoardSpec patch (`g6b_spec::menu::WRITABLE`), edk2/u-boot `boot` selector with **probed** presence, poll-driven `fw` update (HTTPS or USB key, no worker thread; magic+size verify, kernel sha256 on stage). One web bundle: `kernel.web.enable` gates wasm+js+dom+render+css together, `profile=barebone` excludes it, and `cli.boot=ui` is refused while it is compiled (CLI boots first). HolyC gains `Drv`/`CliMan`/`SettingSet`/`BootSelect`/`Fw*` — registered because the shell implements them. `g6b zealcli` / `g6b man` drive the container. [`architecture/g6b-zealcli.md`](architecture/g6b-zealcli.md) |
| **B95** | B94 | **landed** — guest paints the container on VGA: `dom::attach_text_face` (row table + font + `DomPaint`, no wasm shims) plus `CliInit` publishing the host-rendered `CLI| …` rows into `__ui_dom` (`KSTART-CLI`, `ZEALCLI-PAINT n`). Two guest bugs found by long mixed-case text and fixed with regression tests: `sp` was the **bottom** of a hart's stack slot (single-hart images pushed into the `.rodata` `__font` tail), and the mirrored font pairs `( ) [ ] { } < > / \` were reversed (`/>` printed `\<`). QEMU 8.2 + OpenSBI 1.3: `fixtures/g6lc64-zealcli.json` → legible container in a 640×480 screendump, no `UI-BOOT`/`WASM` in the image; `fixtures/g6lc64-web-hd.json` → CLI first, then browser-UI on a 1920×1080 scanout. Runner `tools/qemu_zealcli.sh`. **Next:** guest-side key→container edit (`CliKey`) so the prompt is interactive in the ELF, not only on the host. |
| **B96** | B95 | **landed** — the guest container is **interactive**. New `g6b-asm::cli`: `CliInit` (edit line + container rows + live prompt row), `CliKey` (own `CLI_SEEN` watermark over `INP_KQ`: printable append, backspace, Enter), `CliEnter` (bounded table: `clear`/`reboot`/`shutdown` + one verb per packed page; a miss is `CLI-CMD?`), `CliSync`, and a 128-byte keymap pinned to `g6b_zealcli::input` by a dev-dep test. The edit line is `__uart_line + CLI_LINE_OFF` and the bottom row points at it, so a keystroke changes the next frame; keys never paint in IRQ context (`CLI_DIRTY` + tick), while a serial line no builtin claims dispatches and paints in the trap like `Ui`. Pages are host-rendered (`CLI:<name>| …` from `g6b_kernel::boot`: `help`, `menu`, one per setup screen) — build-time text plus a live line, which is what a guest with no interpreter can honestly offer. `wants_virtio_input` now follows the text face rather than wasm (a keyboard-first CLI needs it most); `wants_virtio_tablet` keeps the pointer opt-in. **Third guest bug fixed:** `DomPaint` never erased, so a shorter row or page left the previous text on screen — it now clears the text band first. QEMU: `help` on serial → `CLI-PAGE help`; `sendkey m e n u` → `/>MENU` on the prompt row; `ret` → `CLI-PAGE menu`. **Next:** `s0..s5` are not in the trap frame while `DomPaint` uses them — a tick landing inside a normal-context paint can still tear a frame (guard like `VIO_BUSY` or widen the frame); page scrolling (`PgUp`/`PgDn` over a page taller than the container); guest-side `set`/`fw` verbs (they need the host band today). |
| **B97** | B96 | **landed** — `autoboot`, the countdown boot picker, as the power-on face. `kernel.cli.autoboot.{enable,timeout_ms=2000,order,bios_ui}` + writable rows `boot.autoboot_timeout` / `boot.autoboot_order`; orders `live-first` (recovery media leads), `os-first`, `payload-first`, with setup always the fallback and the browser UI offered **last** only when the web stack is compiled. New `g6b-zealcli::detect` names its evidence for every row — RISC-V `Image` header (`RISCV\0\0\0` @0x30, `RSC\x05` @0x38, EFI `MZ`/`PE` stub), ISO 9660 PVD at sector 16 + El Torito, `casper/vmlinuz` + `.disk/info`, `openwrt-*.manifest` (its `base-files` revision), `EFI/BOOT/BOOTRISCV64.EFI`, `*.itb`, `bootmgr` — and leaves anything else `unknown`; the device column is the reported vendor and blank when the transport said nothing. `g6b-zealcli::autoboot` is the widget (wraparound, digits, Enter, Esc, countdown that takes **entry 0** because it is the unattended path; any navigation stops the clock). Host media are real: `g6b_kernel::DirVolumes` + `--volume ID=PATH[:role[:vendor]]` with a seek-based `read_window` (a boot menu is not a path-traversal primitive: `..` is refused). Guest: `AutoDraw`/`AutoKey`/`AutoTick`/`AutoPick` with the list packed from the host (`CLI-AB-*` tags) and the countdown in **timer ticks**; `wants_virtio_input` already followed the text face. Taking a medium prints `AUTOBOOT-PICK <id>` + `AUTOBOOT-HANDOFF no block reader in this payload yet (B98)` — it names the stage and the reason, never pretends. QEMU (`tools/mkmedia.sh`, `tools/qemu_autoboot.sh`, `tools/qemu_openwrt_chain.sh`): a real xorriso ISO shows as `> 1. G6LC-OPENWRT-INST [INSTALLER] QEMU DVD-ROM`, the OpenWrt key as `2. OpenWrt sifiveu-generic-sifive_unleashed (1~d9340319c6) [firmware]`, the countdown runs `20s→19s→18s`, `down/up/up` moves the marker `1→2→1→4` (wraparound), Enter picks, and stage 2 boots the picked image to `Linux 6.6.93 … r28739-d9340319c6` → `procd: - init -`. **Next (B98):** a block reader + Image/DTB handoff so the payload boots what it picked (stage 2 is QEMU's loader today); attaching extra `virtio-blk-device`s stops keystrokes reaching the guest although GPU+keyboard probe `OK` (interactive runs use `DRIVES=0`) — a device-slot/irq interaction to root-cause; `s0..s5` still outside the trap frame; picker paging for lists taller than the container. |
| **B99** | B97 | **landed** — new crate `g6b-vfs`: real block devices, partition tables and filesystems behind one mount table, shared by the shell, HolyC and the browser UI. **GPT** (both CRC32s checked, type GUIDs named, a bad CRC reported not hidden) + **MBR** + a whole-disk fallback; `probe` decides the filesystem from its *superblock*, never the table's claim, and every answer carries the field that decided it. **FAT32 read/write** — create, overwrite, grow, shrink, `mkdir`, `remove`, both FAT copies plus the FSInfo free count kept in step, and **VFAT long-name creation** (a `BOOTRI~1.EFI` alias with the name checksum) because the removable-media UEFI path has an 11-character basename and an 8.3-only writer could not repair an ESP at all. **ext2/3/4 read** (extents *and* classic direct/indirect, fast symlinks) plus a deliberately narrow write: an existing regular file, **in place**, only when it fits its allocated blocks and the superblock is clean — including the **crc32c inode checksum** (`metadata_csum`), which is what `e2fsck` caught on the first attempt against a real image. **NTFS read-only** (`$MFT` walk with update-sequence fixups, resident and run-list `$DATA`). Kernel `VfsService` owns the devices and mounts on demand, so a mount table cannot hold a dangling driver borrow. Shell: `drives`, `mount [-w]`, `umount`, and `cd`/`ls`/`cat`/`write`/`rm`/`mkdir` over `/mnt/<name>`, `<name>:/path` and relative paths, with an auto read-only mount on access and `mount` **refusing to guess** between two candidates. `vi` is an editor where the file can be written back (`i I a A o O x dd`, `:w`, `:wq`, `ZZ`, and `:q` refusing to discard an edit) and the read-only viewer elsewhere *with the reason*. OS detection reads the volume (`/etc/os-release`, `/etc/openwrt_release`, `.disk/info`, then layout). HolyC gains `Mount`/`Mounts`/`Drives`/`VfsLs`/`VfsCat`/`VfsWrite`/`OsDetect`; the browser UI gets the same answers as JSON. `g6b vfs scan|ls|cat|write|os --disk PATH` and `g6b zealcli --disk ID=PATH`. **Verified against the distro's own tools** (`tools/mkfs_fixtures.sh`): images from `mkfs.vfat`, `mkfs.ext4` and `sfdisk` are read *and written*, `e2fsck -fn` is clean, `debugfs` and `mtools` read our writes, `fsck.vfat` is clean, and a long-named file is created. [`architecture/g6b-vfs.md`](architecture/g6b-vfs.md) **Next:** the **guest** block driver (USB-MSC / virtio-blk) so the payload can read a disk itself and finish the autoboot handoff; ext4 allocation and journal work; NTFS write; FAT32 create timestamps. |
| **B100** | B99 | **landed** — the three carried-over guest hazards closed, with QEMU evidence. **(1) The virtio-blk keystroke bug is a real starvation bug, root-caused and fixed.** A virtio-mmio interrupt is *level-triggered*, so completing the PLIC claim does not lower the device's line: a device this BIOS has no driver for (a `virtio-blk-device` handed to the picker) re-asserted immediately and the hart never left `trap_sei`. `trap_vio_ack` now reads `InterruptStatus` and writes `InterruptACK` on the base derived from the claimed irq, for any unhandled source **inside the virtio window** (two range guards keep it off non-virtio addresses) — what a driver owes the bus even for a device it does not use. New `VIRTIO-INPUT-OK slot=N irq=M` made the diagnosis a one-liner: the guest's own view was already right (`slot=6 irq=7`) with one drive *or* two, so the fault was the bus, not the probe. QEMU: with both the ISO and the key image attached, the marker moves `> 1.` → `> 2.` → `> 1.` and Enter picks — previously the countdown always won. **(2) The `DomPaint` `s0..s5` tear is guarded.** The trap frame saves `ra`, `t0..t6`, `a0..a7` but not the s-registers `DomPaint` uses, so a tick inside a normal-context paint could repaint with the interrupted call's registers. `PAINT_BUSY` (`__uart_line+296`) is the same discipline as `VIO_BUSY`; it lives in the uart-line block because **that block always exists** — the first attempt put it in `__vio` and a board with no virtio device wrote into whatever followed an absent block, which the mbox `GET` test caught. QEMU: 27 lit glyph bands in the 640×480 plane, container intact. **(3) The picker pages.** A list taller than the container scrolls with the selection and prints `-- 1-6 of 10 (up/down scrolls) --`, wraparound included, frame geometry unchanged. Plus: the **EDK2/U-Boot selector now reads real volumes** (mount read-only, ESPs first, offer only what was read, note the source — and U-Boot is recognized by `extlinux.conf`/`boot.scr` as well as `u-boot.itb`, because "present" and "has something to boot" differ), and FAT32 create records carry the **FAT epoch** instead of a zero date (`mdir` showed `1980-00-00`; a BIOS has a monotonic counter, not a clock). **Still open:** the **guest block driver** (USB-MSC / virtio-blk) — the payload still cannot read a disk itself, so `AUTOBOOT-HANDOFF` remains staged and the `g6b-vfs` drivers run beside the board rather than on it; ext4 allocation/journal; NTFS write. |
| **B101** | B100 | **landed** — the **guest reads its own sectors**. A real virtio-blk driver in the S-mode payload (`g6b-asm::vio`: `BlkInit`/`BlkRead`/`BlkSig`, `Purpose::VirtioBlk`), gated by `BoardSpec::wants_virtio_blk()` = `uncore.storage` + a CLI/picker + the virtio transport — a block driver without a storage controller is a claim about hardware that is not there. `BlkInit` scans the mmio window for DeviceID 2, runs the same virtio 1.x handshake as every other device here, and brings up the requestq with rings in `__vio+BLK_*`, accepting `VERSION_1` and **nothing else** (an accepted feature the driver does not implement changes the request format under a parser that cannot follow it). `BlkRead` submits the three-descriptor chain the spec mandates (5.2.6) — read-only header, device-writable 512-byte landing zone, one-byte status — and **the status byte decides, not the used ring**, because a device can complete a request and report `IOERR` while a ring-only reader parses the previous sector as the one it asked for. `BlkSig` reads LBA 0, then LBA 1 when a `0x55AA` signature suggests a table, and names the medium from its own bytes: `gpt` on `"EFI PART"`, else `mbr`, else `raw` — the protective `0xEE` type byte is a claim, the header signature is evidence. The block layout is past `__vio`'s 12-bit reach, so the routines form one base register for it. Boot names the attached medium; the serial `Blk` verb repeats it. Exec model: a modelled virtio-blk device at `VIO_BLK_SLOT` that *follows the descriptor chain* (a model that hard-coded offsets would pass on a chain no real device could parse) over a GPT-shaped backing image, plus `Smoke::blk_reqs` so a test asserts the driver **asked the device** rather than reading stale RAM. **QEMU 8.2 with real images** (`tools/qemu_blk.sh`, drive attached read-only): `VIRTIO-BLK 5` → `VIRTIO-BLK-OK` → `BLK-SIG gpt` on the real `sfdisk` disk (ESP + ext4) and `BLK-SIG mbr` on the real `mkfs.vfat` superfloppy — the same ELF distinguishes them, so the LBA-1 check does real work. **Two bugs the hardware found that the model had not:** the used-ring poll compared against zero instead of the shadow index, so the second request in a run returned before the device answered (`BLK-ERR` on the LBA 1 read of a real GPT disk), and the 0x1000 slot stride does not fit an `addi` immediate. **Still open:** the guest can read *sectors* but not *files* — locating `/boot/Image` needs a filesystem in the payload (the `g6b-vfs` drivers are host Rust, not ASM IR), so `AUTOBOOT-HANDOFF` remains staged and the picker's entries still come from host-supplied media; next is building picker rows from `BlkSig`/`BlkRead` and choosing between a minimal guest FAT32 reader for the ESP path and a kernel at a known raw offset. USB mass storage is the other transport a real board will have. |
| **B102** | B101 | **landed** — deeper `vi` ↔ filesystem coupling, and a **real sparse-file bug** it uncovered. `blocks_of` returned physical blocks *in order* and dropped `ee_block` (the logical block an extent starts at), so a file with a hole came back **rearranged** — every later block pulled forward into the gap, which is worse than missing because it looks like data. The map is now logical→physical: a hole reads as zeros at its own offset, an *uninitialized* extent is left unmapped (the OS still has to convert it), the classic indirect chain carries its logical base too, and an in-place write is refused when it would reach past the contiguously mapped prefix, naming the mapping. **Verified against a file the Linux kernel made sparse** (loop-mounted the real `mkfs.ext4` image; `filefrag` shows logical 0 and 3 mapped): our read is byte-exact with Linux — 12292 bytes, `HEAD` at 0, zeros in the hole, `TAIL` at 12288 rather than pulled to 4096 — and the write guard fires on the same file with the file left untouched; `e2fsck -fn` stays clean after in-place writes. New `EditBudget`/`EditTerms`: every driver states its write terms **before** an edit — FAT32 `fat32 rw` (creates/grows/shrinks, ceiling = its own clusters plus the free ones, *counted* rather than taken from the advisory FSInfo hint), ext4 `ext4 rw <=4096B in place` (existing regular file, no growth, bounded by the contiguous prefix), NTFS `ntfs ro` with the refusal naming `$LogFile` (an unlogged write leaves a volume that mounts but is subtly wrong). `vi` shows the terms in its status line, refuses at `:w` with `E212: … 1024 is the limit here (…)` while the buffer is still open, and the session **reads the bytes back and compares** after every save — a BIOS write is the last thing to touch a volume before a reboot, so a driver's `Ok` is not evidence. Fidelity, because a BIOS edits files other systems wrote: **CRLF preserved** (a DOS `extlinux.conf` is the normal case; normalizing rewrites every line and can break a strict loader — the status line says `[dos]`), UTF-8 **BOM** preserved, a missing final newline preserved, and a file over 256 KiB opens **read-only** naming both sizes because saving a prefix would truncate it. `MountPort` gains `edit_budget` + `read_window`. One plumbing flaw the end-to-end test caught: the budget was first evaluated through a read-only borrow, so a writable mount answered “0 bytes, read-only” for a file the operator could in fact save — it now uses the mount's **granted** mode. **Still open:** ext4 allocation/journal (so create/grow), NTFS write, and the guest still reads sectors rather than files. |
| **B103** | B102 | **landed** — **autoboot → browser UI on the complete build**, verified on QEMU, and four real bugs on the way there. The container was *not* the power-on face on a web build at all: `wants_cli_face` excluded `wasm.jit`, so a build carrying wasm+js+dom+css compiled **no guest picker** and went straight to the browser — `kernel.cli.boot=auto` held only in the host log. Both faces are compiled now and share one plane through a latch, `FACE_OWNER` (`__uart_line+300`): the container paints first, `WasmUi`'s rung is skipped until the latch flips, keys go to whichever face owns the screen (feeding both would move the picker's marker *and* the browser's menu on one press), and the timer tick runs the owner's work. Taking the picker's **BIOS UI** entry flips the latch, prints `AUTOBOOT-UI` and calls `WasmUi`; `Esc`/`CliInit` takes the plane back; a band `Ui` is treated as the same request and claims it too. **The picker's digits never worked in the guest**: the footer advertised “1-9 pick” and `AutoKey` handled only Esc/Enter/arrows, so pressing `3` got the default entry on Enter — implemented with an unsigned range test (`KEY_1..KEY_9` = 2..=10, and `1 - 2` wrapping is what rejects everything below `KEY_1`). **The payload never zeroed its BSS**: the ELF loader writes `p_filesz` and leaves the rest as found, so the picker's `AUTO_ON`/`AUTO_DONE` words could come up non-zero and `CliInit` would decide the picker had already run — the control blocks (UART line → DOM rows, and the virtio rings) are now zeroed after the boot log, deliberately **not** `__ui_cap` (magic-guarded, and a host may pre-fill it per B91) nor the pixel surfaces (megabytes each frame rewrites). And the QEMU harness itself was lying: the band is *partly* doubled (the boot log goes to SBI putchar **and** the UART0 THR), and a `sed 's/\(.\)\1/\1/g'` filter ate real double letters — `AUTOBOOT-READY` became `AUTOBOT-READY`, so every grep missed a marker the firmware was printing correctly; matching is now canonical on both sides (runs collapsed) with the raw band kept beside it. QEMU 8.2 on `fixtures/g6lc64-web-autoboot.json` (1920×1080 virtio-gpu, `timeout_ms=0` so the picker waits): `KSTART-CLI` → `ZEALCLI-PAINT 4` → `AUTOBOOT-READY 3 entr(ies)` → digit `3` + Enter → `AUTOBOOT-PICK bios-ui` → `AUTOBOOT-UI browser face owns the plane`, and the screendump goes from 15,936 to **37,504 lit pixels**. `tools/qemu_web_autoboot.sh` waits for the picker instead of sleeping a guess (the complete build prints a ~34 KB log through SBI putchar, twice per character, which no fixed settle window survives on TCG). The exec model's step ceiling rose to 48M because CLI-first genuinely does two paint passes; three `dom_paint32_*` tests that target the *web* path now say `cli.enable=false`, which is the configuration they were implicitly testing. **Next in this series:** the Svelte→pglite→volume round trip (create/insert/query with the store on a USB key, readable outside pglite), btrfs r/w, ext4 allocation+journal, NTFS write, and guest file-level reads. |
| **B104** | B103 | **landed** — the store persists through a **real volume**, and a libwasm `_start` drives it. `g6b_pglite::StoreVolume` is the seam: the kernel implements it over `SharedVfs` — the *same* mount table the shell uses — and `attach_volume` swaps the registry's in-memory `usb` map for the medium. `export` writes **JSON text** to the volume (a pulled key is readable by the OS it is plugged into; `codec::unpack` accepts raw JSON back), checks the *medium* for a uuid collision before overwriting, `import` reads the medium first, and `resolve_store_mount` maps the spec's fs-kind name (`fat32`/`ntfs`/`ext4`) to the one mounted instance, refusing ambiguity. The UI write side is `fetch_post`: `KernelPort::fetch_post` gated to `/bios/store` only, `KernelHost::fetch_post` logs `WASM-POST`/`WASM-SKIP-POST` and interns the response, and `Window.fetch_post`/`fetch` return the interned *value* so the `__Handle` dispatch boxes the response string (a guest holding `I32(handle)` could never `libwasm_get__string` it — that import also landed: `(raw, handle)` sret readback, JS-kernel parity). Tests in `crates/g6b-kernel/src/vfs.rs`: router-level create/insert/query → export → fresh-registry import on a real FAT32 image; the gate refusing non-store POSTs; and a hand-assembled `_start` running `libwasm_global("window")` → `Object_Call_string_string__Handle` → `libwasm_get__string` → `set_inner_text` onto the key. QEMU: `DISK=` on `tools/qemu_web_autoboot.sh` attaches a *writable* virtio-blk image; `real-fat32.img`, picker `[payload, bios-ui]`, digit 2 → `AUTOBOOT-PICK bios-ui` → `AUTOBOOT-UI`, 36,212 lit pixels at 1920x1080. **Next:** btrfs r/w, ext4 allocation+journal, NTFS write, guest file-level reads. |
| **B105** | B104 | **landed** — **btrfs in `g6b-vfs`**: read, plus the three leaf-level writes a BIOS may honestly perform. Read path: superblock at 0x10000 (csum verified), `sys_chunk_array` bootstraps the chunk map then the chunk tree completes it, the **root tree** locates the FS tree (default subvolume) and the **csum tree**, and every node is verified — `bytenr` must equal the address asked for and `crc32c(0, node[32..])` must hold, because a corrupt tree is reported, never parsed anyway. Directories list via `DIR_INDEX`, lookup compares names against `DIR_ITEM`s (so a hash collision cannot send a lookup to the wrong inode), files assemble from inline + regular `EXTENT_DATA`, and `read_window` reads only the covering extents. Writes, all leaf-level and all re-sealing the node's csum: **in-place data write** inside a file's existing extents *with the csum tree refreshed per written sector* — an unchecksummed write is a filesystem error the moment the OS reads it back; **inline-extent replace** (a file that lives in a leaf is rewritten there, bounded by `max_inline` and the leaf's measured free space — which is how the store's repeated `store.json` flushes land on one path); and **create/mkdir** (inode + inode-ref + dir-item + dir-index + inline extent, refused when the leaf cannot take it — a split is the OS's machinery). Refused and named: extent allocation/backrefs, `remove`, multi-device/RAID and zoned/extent-tree-v2/stripe-tree/metadata-uuid volumes. Spec: `kernel.usb.fs_btrfs` (on with the full key file manager, off in barebone's one-parser diet), `kernel.store.persist.volume` accepts `btrfs`, `resolve_store_mount` maps it, the manual/`USB-FILES`/browser volume list name it. Tests: driver unit tests on a hand-laid spec-shaped volume (every checksum and key ordering exercised), the zealcli walk+vi-save test, and `a_store_round_trips_through_btrfs` (create/insert/query → export → JSON on the medium → fresh-registry import). Verification limit stated in the doc: `mkfs.btrfs`/`btrfs check` are not on this host, so a distro-tool check remains the residual. **Next:** NTFS write, guest file-level reads. |
|| **B106** | B105 | **landed** — **ext4 allocation and metadata checksums** in `g6b-vfs`. Block and inode allocation now drive file creation and tail growth: `alloc_block`/`alloc_inode` update bitmaps, group counters, and the block/inode-bitmap `crc32c`s; `grow_blocks` extends extent-mapped and direct-block inodes; `create` and `mkdir` insert directory entries and `.`/`..` blocks. Metadata checksums under `metadata_csum` are maintained end-to-end: superblock (crc32c from `~0` over 1020 bytes), group descriptors (`crc32c(s_csum_seed, gd)` with the 16-bit `bg_checksum` zeroed), block/inode bitmaps (`crc32c(s_csum_seed, bitmap)` without a group-number prefix), inodes (seed = `s_csum_seed` chained with inode number and `i_generation`, checksum fields zeroed), and directory blocks (`i_csum_seed` over the block before the 12-byte checksum tail). The old in-place-only ceiling is replaced by an honest `EditBudget` (`can_grow = true`, no `max_bytes` cap for non-sparse regular files); sparse files are still refused mid-hole. Verified against the real `mkfs.ext4` `out/media/real-ext4.img` from `tools/mkfs_fixtures.sh`: `g6b vfs write --rw` creates a file under `/etc`, and the resulting image passes `e2fsck -fn` with no errors. Updated the kernel `vi` test to expect the new `ext4 rw` terms and a successful grow. **Next:** guest file-level reads. |
|| **B107** | B106 | **landed** — **NTFS resident `$DATA` writes** in `g6b-vfs` (see `architecture/g6b-vfs.md` §B107). **Next:** guest file-level reads. |
|| **B108** | B107 | **landed** — **guest file-level reads** in the S-mode payload. `g6b-asm::fatfile::FatRead` and `g6b-asm::ext4file::Ext4Read` drive the virtio-blk device (`BlkInit`/`BlkRead`/`BlkSig`), walk the root directory, and read a named file into a guest buffer — FAT32 via the BPB/FAT/cluster path, ext4 via superblock → group descriptor → inode table → direct-block `i_block`. `BlkSig` now latches the medium into a `BLK_SIG` kind word (`0 none, 1 fat, 2 gpt, 3 mbr, 4 ext4, 5 raw`) each reader gates on — it also probes LBA 2 for the ext4 magic `0xEF53` on media with no `0x55AA`, so `BLK-SIG ext4` is reported from the medium's own bytes. Both readers are wired into the boot path, the `Blk` trap path, and now the autoboot picker — `AutoPick` on a medium entry calls `BlkSig`+`FatRead`+`Ext4Read` so the guest genuinely reads the medium it picked (`AUTOBOOT-HANDOFF medium read; payload image load staged (B98)`), while a board with no driver still reports the honest `no block reader` line. All tested with modelled 64-sector superfloppies in `g6b-asm::exec`; the ext4 reader refuses extent trees and multi-sector directories rather than mis-parsing them. **Next:** loading a payload image by name (incl. partition addressing) and jumping to it, plus real QEMU verification. |
||| **B109** | B108 | **landed** — **btrfs pglite + autoboot OS detection**. A libwasm `_start` cell now posts SQL through `fetch_post` to a **btrfs** USB key (`g6b-kernel::vfs::tests::a_libwasm_cell_posts_sql_through_fetch_post_to_a_btrfs_key`), inserts two rows, queries them, paints the SELECT JSON into `#status`, and exports the dump to `g6lc/wasm-store-btrfs.json`. A fresh `StoreRegistry` imports it back and queries both rows, proving the pglite → shared VFS → btrfs r/w path and the store's `mkdir`/`write` on btrfs. Also, `g6b-zealcli::detect` now reads `/etc/os-release` (then `/usr/lib/os-release`) and names the installed OS from `PRETTY_NAME`/`NAME`, so a btrfs (or ext4) root with os-release appears in the autoboot picker as the OS it is running — e.g. `G6LC btrfs Linux`. Tested with unit tests; the host-side code is green. Full g6lc_qemu verification with the actual svelte-d/LDC 1.43 wasm build and QEMU is blocked in this environment by the missing LDC 1.43 toolchain and `qemu-system-riscv64`, but the prebuilt `BIOS_UI_LIBWASM` path and the host model are ready. |
| **B110** | B103 | **landed** — **picker repaints that actually commit, a face-owned surface latch, bounded flexbox + box-shadow, compact Svelte chrome, and a green check/regress run end-to-end.** The picker's dirty watermark only moved on line edits, so `AutoDraw` republished `__ui_dom` and printed serial but the scanout never refreshed — the countdown digit and the `>` marker were invisible in QEMU. `AutoDraw` now bumps `CLI_DIRTY` after `DomPaint`, which also covers `AutoTick`'s per-second redraw (`auto_draw_schedules_a_scanout_commit`). `DISP_SEL_SURFACE` is a **live latch**: `DispSel` stores the rung default, `CliInit` stores `vga` when the container claims the plane (4bpp plane magnifies through `FbExpand` — the scaled-text look), and `AutoPick`/`Ui` store `default_surface()` for the browser face (`FbExpand1`/`DomPaint32` at output geometry). Four display-ladder exec tests that asserted the *field* now run `cli.enable=false` — the configuration they were implicitly testing before the CLI face became the default power-on face; `DISP-SEL <class><surface>` on serial remains the latch evidence. `g6b-css` gained a bounded flexbox subset (`display:flex`, `flex-direction row/row-reverse`, `flex-wrap nowrap/wrap`, grow/shrink/basis + the `flex` shorthand, `justify-content`, `align-items`, `gap`, item budget) and bounded `box-shadow` (one outer shadow, blur ≤32, spread ±64, bounded offsets, excluded from hit regions); the survey test's missing-feature list lost `gap` accordingly. The compact Svelte chrome uses two-column flex fields (`data-writable` rows, no access column) and `#status` carries the session claim at boot (`UI-BOOT: read-only setup`); stale assertions were updated to the compact contract — `Menu()` is compared semantically (its serializer orders keys differently from `Menu::json()`), first visual row is 4 cells, `read-only` is the live spelling. Toolchain pinned as required: `bios-ui.wasm` 1,536 B + `bios-ui-libwasm.wasm` ~204 KB built by LDC `1.43.0-beta1` through the pinned dub package, then the forked Binaryen `wasm-opt` 132 (`asyncify`, `try_table`) — `wasm-cell: artifact=fresh verified`. QEMU 8.2.2 on both surfaces: `console-review-gpu.elf` (1920×1080, 34,636 lit) and `console-review-vga.elf` (640×480, 9,063 lit) both show `KSTART-CLI` → `ZEALCLI-PAINT` → `AUTOBOOT-READY` → `up` wrap → `AUTOBOT-PICK bios-ui` → `AUTOBOT-UI browser face owns the plane` → `VIRTIO-PAINT` commits. Step-budget note: a default-on picker with real countdown commits is ~8M steps per repaint at 1080p on TCG — legitimate work, not a runaway; display-ladder unit tests pin `cli.enable=false` to stay under the 48M harness ceiling. `g6b check` OK + `bios_regress.py` 17/17 (fmt, `clippy -D warnings`, workspace tests, browser-ui 115 pass + 2 intentional skips, css goldens). The guest lane remains the bounded text/`DomPaint` face; the live engine stays host-side — no in-guest browser is claimed. |
| **B111** | B110 | **landed (exec model, not QEMU)** — **guest-JIT substrate + guest-DOM raster/input lane** in `g6b-asm`. `Op` grew `fence.i`, register shifts, ordered branches, `lh`/`lhu`/`sh`, `remu` and the word ops; `Module` gained `__jit_code`+`__wasm_mem` BSS (`g6b-elf` `p_memsz` covers them) behind `kernel.wasm.guest_jit`. `jitr.rs` translates a bounded WASM subset (const/lget/lset/ltee, i32·i64 alu/cmp, `br`/`br_if`, `call`, loads/stores, globals, mem ops) into `__jit_code`, `fence.i`s it, `jalr`s the entry — the `test` cell returns `WASM-JIT 0x1e` (30) through guest-emitted code, no `TRAP-`. Two translator bugs fixed on the way: `emi` patched **S-type** immediates as I-type so every `sd`/`sw` with a nonzero offset wrote to offset 0 (`jit_ems` now splits `imm[4:0]→[11:7]`/`imm[11:5]→[31:25]`), and the `em_trap` skip branches used `+24` where the 6-word trap block needs `+28` (a *passed* fuel/bounds check landed **on** the trap `jalr` and jumped through a stale `t6`). M2 adds `domt.rs`: `__dom` node arena (64 B records) + `__dom_str` pool, `DomtInit`/`Create`/`Append`/`Text`/`Style`/`Listen`/`Focus`/`Dirty`, bounded block-flow `DomtLayout`, and `DomtRaster` filling `__scan_fb` while recording `__ui_cap` dirty rects so `VioPaint` presents the guest frame instead of `DomPaint32` overwriting it (host `inject_web_present` stays off in the lane). `DomtKey` drains `INP_KQ` and focus-dispatches to the `LSN_DEMO` listener (`DomtDemo` recolors a row), so the `KEY_*` burst drives input→listener→mutation→dirty→repaint→present — `guest_dom_key_recolors_a_node` asserts `0xc02a10` pixels exist only via that path. A real `JitRun` bug it exposed: the prologue saved caller `s0` to `SP+96` *before* `csrrc s0,sie` read the masked `sie`, so `jit_done` restored `sie`=caller-`s0`(0) — `SEIE`/`STIE` never came back and no SEI could be delivered; the frame grew a slot and `sie` now restores from `SP+112`. `g6b check` + `bios-regress` green. |
| **B112** | B111 | **landed (exec model, not QEMU)** — **the guest JIT translates and runs the shipped ~204 KB LDC/libwasm cell end-to-end.** `jitr.rs` (M3a–M3c) grew the translator to integer-complete coverage (`br_table`, `call_indirect` over `__jit_ftab`, bulk-memory `copy`/`fill`/`init`, table ops, `clz`/`ctz`/`popcnt`, sign-extension, typed `select`) plus the exec-model FPU (`f32`/`f64` load/store/arith/cvt through `Op` FP variants + `fr[32]`); `jcode.rs` `ext_id` maps every `env.*` libwasm import to a fixed `jit_ext_tab` slot. **M3d is the host-ABI bridge**: libwasm's DOM handle is `node_index+1` (`getRoot`→1), strings are `(len,ptr)` for `setProperty` but `(ptr,len)` for `add_event_listener`, `createElement` takes a `NodeType` ordinal (stored biased by `TAG_LW` so `N_TAG!=0` keeps it live for the raster), `setProperty(el,"id",v)` copies into a new `__dom_id` BSS side-table (32 B/node), and `add_event_listener` resolves a target **id string** to a node via `LwFindId` then registers `N_LEV` through `DomtListen`. `EXT_FETCH`→`LwFetch` adds the `__wasm_mem` base because guest-JIT imports carry raw linear-memory offsets while the legacy `jit.rs` path resolves `Addr::WasmData` absolutes. `libwasm_await_supported` returns 0 and the `libwasm_await_*` stubs stay bounded — fail-closed, not a fake asyncify. **Two real bugs fixed:** `if`-without-`else` left `Ctrl::If.jz=u32::MAX`, `slot_target`'s `lw` sign-extended it to −1 so the branch jumped to `slot0−128` (the previous function's padding) and `_start` re-entered ~121k×; and `LwAddLsn` emitted a shared `lwal_next` label 6×, collapsing the event-name dispatch so only `click` could ever match. `Smoke` gained `domt_{next,live,listen,ids}` — `domt_addr` resolves `__dom` (`__wasm_mem` top) and `done()` scans the arena. **Gate `guest_jit_executes_shipped_cell`:** 252 funcs translate (`WASM-JIT-F …fc`), `_start` reaches `WASM-JIT`, no `TRAP-`, `domt_next=56 live=56 ids=47 listen=8` — the 8 registrations are exactly the source's 8 `g6b_listen` calls (7 tabs + refresh) resolved id→node — and 279K painted px with **zero** `DomtBoot` `0x1e3a5a` demo fallback, proving the cell's own tree painted. `g6b-asm` 75 + `g6b-wasm` 100 green. **Honest limits:** exec-model only (not QEMU); the raster is the bounded `DomtRaster` block-flow, not the CSS/goosie engine; listeners latch `N_LEV` but `listener=0` (BIOS protocol) so no wasm-funcidx re-entry yet; `await`/`throw` remain fail-closed in the guest lane. |
| **B113** | B91 / DISPLAY-GL | **landed (exec model, not real-GPU QEMU)** — **the guest emits a real virgl command stream** on `proxy.gl` boards (`crates/g6b-asm/src/virgl.rs` + `vio.rs::virgl_node`/`cmdbuf_node` + `exec.rs` 3D arms). `VioInit` now accepts `VIRTIO_GPU_F_VIRGL` in word-0 driver features (masked: a plain `virtio-gpu-device` offers 0, so the accept is fail-closed with no codegen branch); the exec model tracks `vio_drv_feats` and gates 3D on `virgl_live` (device `vio_gl` *and* the negotiated bit, not mere capability). `VioVirgl` (call-node after `VioScan`, before `VioPaint`) walks a static `__virgl_req` record table (`[req_len][resp_len][flags][req…]`) driving `GET_CAPSET_INFO`/`GET_CAPSET`(virgl capset blob) → `CTX_CREATE`(ctx 1) → `RESOURCE_CREATE_3D`(`RES_RT` offscreen render target) → `CTX_ATTACH_RESOURCE` → `SUBMIT_3D` — the `REQFLAG_BUF` records go through `VioCmdBuf`, a **3-descriptor chain** (32-byte `virtio_gpu_cmd_submit` OUT + `__virgl_cmd` execbuffer OUT + resp WRITE); `vio_exec_chain` now gathers *all* OUT descriptors before dispatch (previously first-only, which is why `SUBMIT_3D` needed it). `virgl.rs` emits a real `VIRGL_CMD0`-framed stream (`cmd|object<<8|body_dwords<<16`, len = body dwords excl. header — confirmed against the decoder): surface/shader/vertex-element/sampler objects + `SET_FRAMEBUFFER_STATE` + `CLEAR`(depth is a double=2 dwords) + `DRAW_VBO`(12) + inline texture/VBO writes. **Offscreen RT separation:** `RES_RT` is a distinct resource with its own `virgl_fb`/`virgl_backing` — the raster never touches `vio_fb` (the earlier shared-scanout version corrupted `vio_paint_scale`/`gpu_surface`). **A real layout bug it exposed:** `image_filesz` must sum *every* emitted rodata blob — it initially omitted `virgl_cmd`/`virgl_req`, so `stack_memsz`-derived BSS bases (`gr_base`/`scan_fb_base`/`domt_base`/…) shifted by the virgl size vs `resolve_addr`'s `stacks`, and the test snapshots read a slid window (`gr_frame` all-zeros, `0xaa` at the plane origin). Tests: `virgl_submit_executes_textured_quad` (CAPSET→ctx→submit→raster counters), `virgl_exec_rasterizes_inline_texture`, `virgl_texture_byte_kill_test` (flip a texel → surface differs), invalid-context/malformed-stream. `g6b-asm` 78 green. **Honest limits:** the model parses/rasters the stream itself — *not* real-GPU QEMU raster; `egl-headless,gl=on` needs a host `/dev/dri/renderD*` this host lacks, so byte-exact TGSI sampling and the QEMU screendump stay open. **Next:** real-GPU QEMU screendump (needs `/dev/dri/renderD*`), M5 latency/visual. **M4b landed:** `__virgl_out` guest readback — `Addr::VirglOut` BSS region (last in the `stacks` chain, after `__dom_id`; `extra_bss`/`p_memsz` carry it, `image_filesz` untouched since it's `.space` not file rodata). After the `__virgl_req` loop, `VioVirgl` `sw`-builds `RESOURCE_ATTACH_BACKING`(`RES_RT`→`La VirglOut`, `entries[0].addr` needs the resolved BSS addr so it can't ride the static reqtab) + `TRANSFER_FROM_HOST_3D`(`RES_RT`, box w×h) through `VioCmd`; the model routes `virgl_backing[RES_RT]`→`__virgl_out` and DMAs `virgl_fb`→guest RAM. `Smoke::virgl_out` snapshots it; `virgl_submit_executes_textured_quad` asserts `virgl_out == virgl_fb` byte-exact (checkerboard in guest RAM), and `virgl_transfer_requires_attached_backing` covers the unbacked/unknown-resource refusals. |
| **B114** | B112 | **landed (exec model, not QEMU)** — **Stage-2 display-list carry + real-input → wasm listener re-entry.** `dlp.rs` `DlPaint` replays a packed `__web_dl` op stream (`FILL`/`FILLR`/`STRKR`/`COV`/`TILEPX`/`TREF` + clip) into `__scan_fb`; `WebPaint` picks display-list replay when `WEB_DL_MAGIC` is live, else the `__web_pk` pixel pack, else the guest `DomtRaster` fallback, and `DomtKey` maps the nav arrows/Home/End onto the `H_WST` state switch so `dl_paint_nav_key_switches_state_via_domt_key` repaints state 1 through the real `INP_KQ` drain. **Listener re-entry:** `N_LISTEN` is now three bands — `0` BIOS protocol (`g6b_listen`), `LSN_DEMO` builtin, and `>=LSN_FUNC`(`0x100`) a wasm funcidx. `LwAddLsn` biases a nonzero `add_event_listener` cb to `0x100+idx` so it can't alias the builtins; `DomtKey`'s `dtk_lsn` fills the new `__ev_obj` record (`EV_TYPE`/`CODE`/`VALUE`/`CX`/`CY`/`TARGET`-as-handle) and `JitCall`s `funcidx = N_LISTEN − 0x100` with the event handle — the same between-`JitRun`s re-entry the asyncify rewind uses, so the `DomtKey` queue loop's `S0–S2` survive (generated code only touches `s8–s11`/`t0–t6`/`a0–a7`). `Module` gained `__ev_obj` BSS (`Addr::EvObj`, last region after `__virgl_out`). **Gate `guest_jit_listener_reenters_cell_on_key`:** a hand-built delegate cell registers `add_event_listener("x","keydown",$delegate)`; a queued `KEY_ENTER` + the canned burst each re-enter and `appendChild`, so `domt_live` grows `2→6` (`listen=1 ids=1`), laid-out rects prove the dirty→`DomtLayout`→repaint chain ran. Still open: the `libwasm_get__*` event-property getter bridge (delegates can't yet read `__ev_obj` through wasm memory) and a pointer/hit-test path for `EV_CLICK`. `g6b check` + `bios-regress` green. |
| **B115** | B114 | **landed (exec model, not QEMU)** — **pointer `EV_CLICK` hit-test → `JitCall` re-entry** (the second `DomtDispatch` leg). `TabDrain` now *decodes* each consumed `virtio_input_event` (`{type,code,value}` via `lhu`/`lw` — the earlier `andi 0xffff` didn't fit `imm12`), latching the last `ABS_X`/`ABS_Y` into new `__vio` scratch `PTR_X`/`PTR_Y`/`PTR_CLICK` (`0x7b4–0x7bc`, after `TAB_LAST_USED`/`VIO_NET_OFF`) and setting `PTR_CLICK` on a `BTN_LEFT` press. `trap_tab` then `jal DomtPtr` (`guest_jit`-gated, after `TabDrain`): it consumes the click, scales tablet `0..=0x7fff` → display px via `mul`+`srli 15` over `DISP_SEL_W`/`DISP_SEL_H` (640×480 fallback), `DomtHit`s the topmost `F_VIS` rect node latching `N_LEV & EV_CLICK` (document-order scan, later = topmost, no capture/bubble), fills `__ev_obj` (`EV_CLICK`,`code`=BTN_LEFT,`value`=1,`clientX`/`clientY`=px,`target`=handle), and `JitCall`s `N_LISTEN−0x100` — one dispatch per trap, `H_DIRTY` bump drives the `trap_timer` repaint. **Gate `guest_jit_listener_reenters_cell_on_click`:** a click-delegate cell's probe run reads the button's laid-out rect, then `run_module_web_feed` + a stub `WebFeed::hint_abs` delivers a *real* `ABS_X/ABS_Y`/`BTN_LEFT` virtio poke at the button centre — `domt_live` `2→3` (the delegate `appendChild`ed, rect laid out below). Still open: `libwasm_get__*` getter bridge; pointer `EV_KEYDOWN`/`EV_MOUSEMOVE`/`EV_SCROLL` lanes + capture/bubble walk. `g6b check` + `bios-regress` green. |
| **B116** | B115 | **landed (exec model, not QEMU)** — **the `__ev_obj` event-property bridge** — a delegate can now *read* the event, not just be re-entered by it. Two new EXT slots join `jit_ext_tab` (`EXT_EVGET`/`EXT_EVCALL`, ids 18/19): `ext_id` routes `env.Object_Getter__{int,uint,ushort,bool,Handle}` (the i32-returning, non-sret getters — `(handle,len,ptr)`) onto `LwEvGet`, and the no-arg-void `Object_Call_<args>__void` shape onto `LwEvCall`. `LwEvGet` is bounded to the live event object (`handle` must equal `&__ev_obj`, else 0), name-matches the property string via `LwNameEq` against a bounded literal table, and `lw(handle,off)`s the field: `clientX/screenX/pageX/offsetX`→`EVO_CX`, `…Y`→`EVO_CY`, `code/keyCode/which/button`→`EVO_CODE`, `detail/value/deltaY`→`EVO_VALUE`, `target/srcElement/currentTarget`→`EVO_TARGET` (a real node handle), `type`→`EVO_TYPE` (the `EV_*` mask as int — the *string* `type` is a separate sret lane), `defaultPrevented`→`EVO_PD`; `cancelable`/`bubbles`/`isTrusted` are constant-1. `LwEvCall` name-matches `preventDefault` and sets the new `EVO_PD` field (offset 24, zeroed each dispatch by `DomtKey`/`DomtPtr`) — the `preventDefault`→`defaultPrevented` write-back round-trip. String getters (`type`,`key`) and `float`/`double`/`Optional*` still `TRAP_EXT` (bounded deferral). **Gate `guest_jit_listener_reads_event_props`:** the `test_module_evget` delegate reads `clientX`/`target`, calls `preventDefault`, reads `defaultPrevented`, and `appendChild`s iff `(clientX>=200)&&(target!=0)&&defaultPrevented` — a real tablet click lands `clientX≈325`, so `domt_live` `2→3` only when every read round-trips. (A test-cell bug fixed on the way: a property-name offset `≥0x40` needs a 2-byte signed-LEB `i32.const`; the pool was repacked under `0x40`.) `g6b-asm` 88/88, `g6b-wasm` 104/104. |
| **B117** | B116 | **landed (exec model)** — **the Stage-3 opcode reachability preflight** — the plan's hard gate for the already-live `await_supported=1` lane is now a real, runnable report instead of an unwritten precondition. `jcode.rs` grew `op_coverage(wasm) -> OpCoverage` (re-exported `g6b_wasm::op_coverage`): it lowers every defined body through a new shared `lower_one` helper (the fidx-68 `Static_Call` DIAG, `lower_fn`, balanced-ctrls, terminal `R_RET` — the *same* normalization `encode` packs, refactored so both share it), then BFS-walks the call graph from the re-entrable roots — `_start`, every func-kind export (a delegate/`jsCallback` is `JitCall`-ed back in, not reached by `_start`'s own `call` edges), and every element-table func (the funcref set a `call_indirect`/`ref.func` names — the `add_event_listener` delegate funcidx lives there) — and classifies each `R_TRAP` in reachable code as a blocking `OpGap` (`TRAP_UNSUP`/`TRAP_EXT`/`TRAP_BADFUNC`) or a benign marker (`TRAP_UNREACH`/`TRAP_XLATE`). `OpCoverage::clean()` is the gate; `OpGap::describe()` renders each gap (`uncaught throw tag 0`, `unmapped env import`, …). **Result on the shipped cell: 252 funcs, 239 reachable, 1 blocking gap** — `fidx 94` is `_start`-reachable and carries an *uncaught* `throw` (`TRAP_UNSUP` orig `0x200|tag`): a cold error branch `throw`s to its caller, cross-function wasm-EH jitr does not unwind (`guest_jit_executes_shipped_cell` proves that branch isn't taken on the happy path). **Gate `shipped_cell_op_coverage_report`:** asserts every reachable gap is exactly that `0x200`-tagged throw class — no unlowered *opcode*, unmapped import, or bad call in live code — and bounds the count so a new reachable gap fails loudly. Still open: lowering the cross-function `throw`/`rethrow` unwind (the one real coverage gap), and `clean()` for a fully-covered cell. `g6b-asm` 88/88, `g6b-wasm` 105/105. |
| **B118** | B117 | **landed — QEMU-verified, not just exec model** — **the whole LDC/libwasm JIT-cell web face runs on the real `g6lc_qemu` build** (QEMU 10.0.0, WSL2, `tools/qemu_web_autoboot.sh` on `fixtures/g6lc64-web-autoboot.json` → `guest_jit`+`jit_cell="auto"` → `BIOS_UI_LIBWASM`, the 204 KB `browser-ui/out/bios-ui-libwasm.wasm`). Serial markers confirm every stage the exec model had only simulated: `KSTART-WASM-JIT`/`WASM-JIT-RV` install the cell; the guest builds and owns the persistent DOM (`WASM-CREATE-ELEMENT`/`WASM-APEND` over ~90 nodes); **`WASM-AD-EVENT-LISTENER tab-* click 0 capture=false`** registers eight listeners through the `add_event_listener` funcidx lane; **`WASM-FETCH /bios/*` ×8 → `KernelGet`/`__kget`** then **`WASM-AWAIT-VOID slot` → `WASM-AWAIT-RESOLVED slot` ×8** resolve the menu/store routes into the field rows; `AUTOBOOT-UI browser face owns the plane` hands off and **`WEBDL 0/01/02`** — the `__web_dl` display-list carry — repaints each menu state into `__scan_fb` → the 1920×1080 virtio-gpu scanout is **fully lit (2,073,600 px)**, `VIRTIO-PAINT-SKIP` showing the legacy `WasmUi`/`DomPaint` path suppressed once the web face owns the surface. **Real-input loop proven:** virtio-keyboard `send-key` Right/Left → `DomtKey` `dtk_fwd`/`dtk_back` → `H_WST`±1 → `H_DIRTY` → `DlPaint` repaints — screendumps `nav-a/b/c/d` walk Main→CPU→Memory→CPU with `a≠b≠c` and **`b==d` byte-identical** on the return, so the repaint is guest-state-driven, deterministic, and noise-free; each menu's fields (Cores/Threads/SMT/Hz, DRAM base/length/offset) are the real `/bios/menu/*` bodies. No `TRAP-*`, no `ERR`. Artifacts `out/qemu-web-ab-verify/` (gitignored). **Honest residual:** the nav tabs are wired `listener=0` (the BIOS-protocol `H_WST` switch, not a wasm callback), so what QEMU proves is the real-input→`H_WST`→`DlPaint`→scanout chain — the wasm-callback `JitCall` *re-entry* itself is exec-model-verified (B114/B115) but was not driven on QEMU because a pointer click needs a virtio-tablet and `-display none` has no host mouse to steer it (adding `virtio-tablet-device` flooded `trap_tab` with ABS events and starved the keyboard queue — needs a coordinated abs-event inject). Cross-function `throw` unwind and `clean()` still open; virgl composite still untested (no `/dev/dri` on WSL2). |
| **B119** | B118 | **landed (exec model)** — **cross-function wasm-EH unwind + strict `cov.clean()`.** The one reachable coverage gap from B117 (fidx-94 `throw` to caller fidx-91's `catch`) is now lowered: `jfmt.rs` adds `R_THROW`/`R_EXCCHK`/`R_EXCCLR` (`R_OP_COUNT` 39→42) and `TRAP_EXC`(11); `jitr.rs` adds `OFF_EXC`/`OFF_EXCTAG` to the `__jit` header tail (3232/3240) plus `em_jitfield` (`li`+`add` off `s9` for >12-bit fields) and three handlers. Design: **static per-call check, no dynamic handler stack** — a callee `R_THROW` stores tag→`EXCTAG`, sets `EXC`, folds its frame (`s10=s11`; `ld ra,8(sp); ld s11,0(sp); sp+=16; jalr ra`, the same tail `jit_h_ret` ends with) and returns into the caller's post-`jalr` `R_EXCCHK`; that check `ld`s `EXC`, and on set either `slot_target`+`jalr` to the statically-resolved innermost enclosing `catch` head (an `R_EXCCLR` that clears `EXC`) or re-emits the unwind tail to propagate up (`a=u32::MAX`). Top-level `jit_after`/`jit_call_done` re-check `EXC` → `jit_exc_uncaught` → `jit_trap`(TRAP_EXC), which **consumes `EXC` first** so the resumed continuation can't re-fire into a report loop. The one correctness fix on the way: `em_jitfield`'s `jit_lia` clobbers `a1`, so `R_EXCCHK` parks `rec.a` in `t2` before the field read and restores it for `slot_target` (without it the catch target was a wild address → machine `TRAP-2`). `jcode.rs` `lower_fn` emits `R_EXCCHK` after every `Call`/`CallIndirect` (+~609 records on the shipped cell, well under `MAX_JIT_RECORDS`), `R_EXCCLR` at each catch head, `R_THROW` for escaping `Throw`/`Rethrow`, and `Delegate` forwards `R_JMP`-throws→`R_THROW` while leaving `R_EXCCHK` to propagate. **Gates:** `guest_jit_cross_func_throw` (callee `throw` → caller `catch_all` → 777, no `TRAP-`), `guest_jit_uncaught_throw` (top-frame `throw` → `WASM-JIT-TRAP 0b`, no machine fault), and `shipped_cell_op_coverage_report` now asserts `cov.clean()` (252 funcs / 239 reachable / **0 gaps**). `g6b-asm` 88/88, `g6b-wasm` 107/107. **Still open (documented limits):** `catch <tag>` doesn't match tags (first `catch`/`catch_all` wins — the catch_all/single-tag shipped cell is unaffected); virgl composite still untestable on WSL2 (no `/dev/dri`); QEMU `JitCall`-on-click still needs a wasm-funcidx-listener cell (shipped nav tabs are `listener=0` BIOS-protocol — B118). |
| **B120** | B119 | **landed — real-QEMU keydown → `JitCall` re-entry** — closes the B118 honest residual's *mechanism* (wasm-callback re-entry on a real input event), on the keyboard lane rather than the pointer. `jcode.rs` adds `delegate_key_cell()` — a bootable `jit_cell="delegate"` cell (spec validation accepts `"delegate"`; `cell_bytes` selects it). `_start` sets `root.id="r"` + `root.innerText="READY"` (the bare element tree has no text — `DomtRaster` would paint only the dark page bg) and registers `add_event_listener("r","keydown",$delegate)` **on the root**, which is the default `H_FOCUS` (node idx 0), so a queued keydown dispatches to the funcidx listener with no `DomtFocus`. `$delegate(ev)` appends a `<button>` with `innerText="K"` — each press adds a visible row. **QEMU proof** (`out/qemu-web-delegate/`, `fixtures/g6lc64-web-delegate.json` — `jit_cell="delegate"` with the libwasm/`svelte-d` lane off so `WebPaint` falls through to `DomtRaster`): `AUTOBOOT-UI` hands the plane to FACE_WEB, then `send-key a` → virtio-keyboard → `trap_inp`→`InpDrain`→`INP_KQ`→`DomtKey` `dtk_lsn` → root `N_LISTEN>=0x100` → `__ev_obj` filled → `JitCall($delegate)` → `createElement`/`setProperty`/`appendChild` → `__dom` grows + `H_DIRTY` → `trap_timer`→`DomtRaster` paints the new `K` row. **Screendumps A/B differ by 14,713 px** (the appended `K` button row lights a fresh band); zero `TRAP-*`/`ERR`. Exec gate `guest_jit_delegate_cell_key_reenters_root` asserts the same path without `DomtFocus` (queued key → root listener → `domt_live` ≥3). **Still open:** the *pointer/click* lane (`DomtPtr`→`JitCall`) is not yet QEMU-driven — QEMU's headless input tooling can't reliably target `virtio-tablet` under `-display none` (`input-send-event …device` aborts on `qemu-fixed-text-console`/`device` link lookup; `send-key` misroutes to the tablet when both are attached; `input-send-event` without `device` lands abs/btn on the keyboard). The `DomtKey`/`DomtPtr`→`JitCall` re-entry mechanism is identical between lanes (B115 proves the click lane on the exec model). The shipped libwasm cell keeps `listener=0` BIOS-protocol nav tabs by design. |
| **B121** | B120 | **landed (exec model) — pointer-lane listener cell + a precise QEMU-injection diagnosis.** `jcode.rs` factors `delegate_key_cell` into a shared `delegate_cell(ev)` builder and adds `delegate_click_cell` (`jit_cell="delegate-click"`, spec-validated, `cell_bytes`-selected): `add_event_listener("r","click",$delegate)` on the root, which `DomtLayout` lays out to the **full display**, so any tablet `ABS_X/ABS_Y`+`BTN_LEFT` press `DomtHit`s it with no child-rect aiming. `fixtures/g6lc64-web-delegate-click.json` boots it `cli.enable=false` — no picker, and `DomtPtr`/`DomtRaster` are ungated when cli+web don't share the plane (`faces_share_plane` = `wants_cli_face && wasm.jit`). Exec gate `guest_jit_delegate_cell_click_reenters_root` runs a real `trap_tab`→`TabDrain`→`DomtPtr`→`JitCall` on a canned ABS+BTN poke at screen centre → root listener fires → `domt_live` ≥2. **QEMU injection diagnosis (why the click lane stays host-limited):** `virtio_input_send` queues input events but only flushes to the guest on a trailing `EV_SYN`/`SYN_REPORT`, and drops entirely when `!vinput->active`; `TabInit` does complete the handshake (DRIVER_OK + 8 posted eventq buffers), so the device *is* active — but on this headless/VNC WSL2 host no injection path fills the guest tablet queue: `send-key` misroutes to the tablet, `input-send-event …device` aborts on the `qemu-fixed-text-console` device-link lookup, `input-send-event` without `device` lands abs/btn on the keyboard queue, and a real VNC RFB `PointerEvent` flood reaches the console but `virtio_input_send` doesn't deliver (`TAB` stays ~1, `DPJ` dispatch probe 0). **The guest `DomtPtr`→`JitCall` path is proven in the model and is the same mechanism as the QEMU-proven keydown lane** — the only gap is host-side tablet event injection, which needs a pointer-grab-capable display backend (or a GTK/`sdl` frontend, not available headless on WSL2). `g6b-wasm` 109/109. | path-gated HTTP body cap; HolyC `StoreOpen`/`StoreQuery`/…; `STORE-REFUSED` when `!store.enable`. Lodash intern is S3. |
| **B122** | B121 | **landed — real-QEMU pointer click → `JitCall` re-entry** — the B121 "host-side injection limit" was wrong; the gap was a **guest** bug. Instrumented `virtio_input_send` proved QEMU *does* deliver `input-send-event` (`VIPUSH n=5` pops/fills/pushes/raises the irq under `-display none`), yet `trap_tab` never fired — the claimed-irq trace showed the tablet's real irq 6 was being routed through `trap_inp`. Root cause: `vio.rs` `ipi_claim` assigned the **first** DeviceID-18 device (ascending mmio scan) to `VIO_INP_OFF` and the second to `VIO_TAB_OFF`, but `virt` attaches `keyboard`/`tablet` in `-device` order — with `-device virtio-tablet` listed last the tablet still lands at the *lower* slot (0x10006000, irq 6) and got mislabeled the keyboard. **Fix — capability classification:** each DeviceID-18 slot now probes the virtio-input config window (`VIO_REG_CONFIG`): one `sw` packs `select=EV_BITS(0x11)`|`subsel=EV_ABS(3)` into `virtio_input_config`, and `lbu config+2` reads the `EV_ABS` bitmap length — nonzero ⇒ tablet → `VIO_TAB_OFF`, else keyboard → `VIO_INP_OFF`. Slot order no longer matters. (`exec.rs` models the config window now: `inp_cfgsel`/`tab_cfgsel` latches, `size` reads `0` for the keyboard / `8` for the tablet on the `0x0311` select.) **Second guest fix — document-root viewport:** `DomtHit` returned `NONE` on a centre click because `DomtLayout` gave the root a *content* height (one text row, `h=16`); a `click` listener registered on the root is a document-level listener, so the root element now generates the initial containing block — `domt_layout_node` clamps the root's `N_H` up to the display height, matching the "root spans the `__disp` output" contract and the exec test's own "root covers the whole extent" assumption. **QEMU proof** (`out/qemu-web-delegate-click/`, `qemu_click_diff.sh`, clean un-instrumented build): `input-send-event` abs+btn → `trap_tab`→`TabDrain` (`TAB`×5/click) → `DomtPtr` → `DomtHit`(root) → `JitCall` → delegate appends `<button>` (`H_NEXT` 3→4) → `H_DIRTY` → `trap_timer` repaint → **scanout A→B / B→C each +changed pixels, A→C cumulative, 0 `TRAP-`**. `VIRTIO-TABLET-OK` now also prints `slot=`/`irq=` like the keyboard's line. `g6b-asm` 88/88, `g6b-wasm` 109/109, `g6b-spec` 41/41. |
| **B123** | B122 | **landed — guest `__prom` promise-object model** (scope C: settle-state await + combinators) — `LwFetch` no longer returns a raw `__kget` index; it allocates a bounded `__prom` record (BSS region after `__ev_obj`, `Addr::Prom`, `PROM_MAX`=64×`PROM_REC`=48) holding `pending`/`fulfilled`/`rejected` + value/reason spans, and returns `handle=index+1`. `LwAwaitVoid` consults the record's settle state: `FUL`→`cur`=body, `REJ`→`P_AFAIL`+`cur` empty, `PEND`→latch `P_ASUSP` and arm the unwind. **Rejection surface:** `libwasm_await_failed` (`EXT_AWAIT_FAIL`→`LwAwaitFail` reads `P_AFAIL`) + `libwasm_await_error` (`EXT_AWAIT_ERR`→`LwAwaitErr` writes the `{len,ptr}` reason — the failing url — to `__wasm_mem[raw]`). **Combinators:** `libwasm_add__ints` (`EXT_ADDINTS`→`LwAddInts`, len-first, allocs a `PROM_K_IARR` record wrapping a `__wasm_mem` i32 span) feeds `libasync_promise_{all,any,allsettled}__promise` (`EXT_PROM_*`→`LwPromAll/Any/Alls`→`PromCombine`→`PromScan` aggregation: all=first-REJ-or-FUL, any=first-FUL-or-all-REJ, alls=all-settled→FUL). `libwasm_note_await_{ok,fail}` (`EXT_NOTEFUL/_REJ`) settle a still-pending record from the host. **Pending suspend/resume lane (exec-model wired):** a `PEND` record at await time makes `jit_after` arm the asyncify rewind (`stop_unwind`+`start_rewind`, state=`REWINDING`, buffer populated) then *park* via `jit_result` instead of re-invoking — the timer IRQ is masked inside `jit_after`, so it can't spin. `trap_timer`→`PromDrain` re-runs `KernelGet` for pending fetches (`PR_BUDGET`=64-tick grace, fail-closed REJ at 0) and rescans pending combinators; when the `P_ASUSP` record settles it clears the latch and raises `P_RESUME`, and `trap_timer` itself `JitCall`s `_start` right after the drain — whose `REWINDING` top-check rewinds into the await continuation to `libwasm_await_value`. (The resume lives in the trap, not `park`: the `sepc` of an interrupted `wfi` is the `wfi`, so a post-`wfi` check would be unreachable; `JitCall`-from-trap is already proven by listener re-entry.) **Pending is a real producer:** a `KernelGet` *miss* now pends rather than sync-rejecting — `__kget` is a route cache and `PromDrain` settles the miss on the poll (late hit→FUL, budget→REJ), matching the browser kernel where `fetch` returns a genuinely pending promise that resolves asynchronously. **Known bound:** a pending await reached *inside* a `JitCall` (listener re-entry, or the resume itself) does not re-park — `jit_call_done` does not drive the asyncify/pending lane; only the `JitRun`→`jit_after` path suspends. The shipped cell's baked routes still resolve synchronously, so the lane stays exercised by a dedicated gate rather than the shipped fetch path. Exec gates: `guest_jit_fetch_reject_sets_await_failed` (miss→PEND→`PromDrain`→REJ→afail+reason), `guest_jit_promise_combinators` (all/any/alls over `add__ints` arrays), `guest_jit_prom_drain_settles_pending` (PEND→FUL on hit, PEND→REJ on budget), `guest_jit_pending_await_suspends_then_resumes` (real shipped cell: omit `/bios/menu/main` → suspend on its await → tick `PromDrain`-reject → `P_RESUME` → `JitCall` rewind → rejection path). `g6b-asm` 88/88, `g6b-wasm` 113/113, `g6b-spec` 41/41; shipped-cell + B122 click re-entry stay green. |
| **B124** | B116 / P3 | **landed (exec model, not QEMU)** — **UTF-8 `__ev_obj` string getters.** `ext_id` maps `env.Object_Getter__string` to `EXT_EVGETSTR`(28)→`LwEvGetStr`: a D sret `{len,ptr}` at `__wasm_mem[raw]` for `type` (`"click"`/`"keydown"`), `key` (`"Enter"`/`"a"`) and `code` (KeyboardEvent.code `"Enter"`/`"KeyA"`, never the Linux keycode integer in `EVO_CODE`). Unknown names / non-event handles write empty. Payload is copied into the last 32 B of the KSTR tail (`OFF_MEMB - EV_STR_BYTES`, past `mem_pages`); `LwAwaitVal`'s bump wraps before that scratch. **Gates:** `guest_jit_listener_reads_event_type_string` (tablet click → `"click"` len 5 → `__dom` grows) and `guest_jit_listener_reads_event_code_string` (queued KEY_ENTER → `"Enter"` len 5, not 28). All 20 `guest_jit_*` tests green, including the shipped cell. Still open at landing: capture/bubble (B125), multiple listener records, `float`/`double`/`Optional*`, full SYN_REPORT. |
| **B125** | B124 / P3 | **landed (exec model, not QEMU)** — **capture → at-target → bubble.** Host `g6b-dom::dispatch_event` no longer skips non-capture target listeners when `bubbles=false` (`non_bubbling_fires_target_noncapture`). Guest `DomtHit` is geometric (topmost `F_VIS` rect; `ev_mask` is unused). `DomtDispatch` snapshots the `N_PARENT` chain (≤`DOMT_DEPTH`) and fires the one per-node slot: `F_CAPTURE` on the way down, at-target always, `!F_CAPTURE` on the way up. `LwAddLsn` a5 stores `F_CAPTURE`. `__ev_obj` grows `EVO_PHASE`/`EVO_CUR`/`EVO_STOP`; getters serve `eventPhase`/`currentTarget`; `LwEvCall` matches `stopPropagation`. **Gates:** `guest_jit_click_capture_on_parent` (child click → root capture `eventPhase==1`) and `guest_jit_click_bubble_on_parent` (`eventPhase==3`). 22/22 `guest_jit_*` including the shipped cell. Still open at landing: multiple listener records (B126), `float`/`Optional*`, full SYN_REPORT. |
| **B126** | B125 / P3 | **landed (exec model, not QEMU)** — **bounded multiple listener records.** `__dom` grows a 64×16 B table after the node pool (`DOMT_LSN_OFF`). `DomtListen(node,mask,cb,capture)` ORs `N_LEV`, keeps the first `N_LISTEN`, and appends `{node,mask,cb,LSNF_CAPTURE}` for wasm cbs (fail closed at 64). `DomtFire` scans the table by `EVO_PHASE` (capturing=flag, bubbling=!flag, at-target=capture then bubble) and still special-cases `LSN_DEMO`. `DomtDispatch` always calls `DomtFire` on each path node. **Gate** `guest_jit_two_listeners_on_parent`: capture+bubble on the root both fire on a child click (live≥4). 23/23 `guest_jit_*`. Still open at landing: `once`/`passive`/removal (B127). |
| **B127** | B126 / P3 | **landed (exec model, not QEMU)** — **`once`/`passive`/removal.** `add_event_listener` a5 packs `LSNF_CAPTURE=1`/`ONCE=2`/`PASSIVE=4` (0/1 stay capture-only). `DomtFire` sets `EVO_PASSIVE` around `JitCall` so `LwEvCall` `preventDefault` is a no-op, then tombs `LSN_NODE=NONE` when `ONCE`. `remove_event_listener` → `EXT_RMLSN`(29)→`LwRmLsn` tombs matching `LSN_CB`. Host oracle: `once_listener_fires_only_once`, `passive_listener_cannot_prevent_default`. **Gates:** `guest_jit_once_listener_fires_once` (two KEY_ENTER → live=3), `guest_jit_passive_prevent_default_is_noop` (append iff `defaultPrevented==0`), `guest_jit_remove_event_listener` (click after remove → live=2). 26/26 `guest_jit_*`. Still open at landing: `float`/`Optional*` (B128). |
| **B128** | B127 / P3 | **landed (exec model, not QEMU)** — **OptionalUint/Handle and float getters.** `Object_Getter__Optional{Handle,Uint}` → `EXT_EVGETOPT`(30)→`LwEvGetOpt` writes `{value:u32, defined:u8}` at `__wasm_mem[raw]`; `relatedTarget` is a known name with `defined=0`. `Object_Getter__float` → `EXT_EVGETF`(31)→`LwEvGetF` (`jal LwEvGet` then `fcvt.s.w`/`fmv.x.w`). Host decode allows `Object_Getter__*`/`Object_Call_*` f32/f64/i64. **Gates:** `guest_jit_optional_event_getters` (defined `clientX`≥200 and `relatedTarget` none), `guest_jit_float_event_getter` (`clientX` as f32 ≥ 200.0). Not `double`/`Optional{String,Bool,Double}` (B129). |
| **B129** | B128 / P3 | **landed (exec model, not QEMU)** — **double and Optional{String,Bool,Double}.** `Object_Getter__double` → `EXT_EVGETD`(32)→`LwEvGetD` (`fcvt.d.w`/`fmv.x.d`). OptionalString `{len,ptr,defined}` (defined iff UTF-8 non-empty). OptionalBool `{value:u8, defined:u8}` (`bubbles`/`cancelable`/`isTrusted`). OptionalDouble `{f64,defined}` from the integer field. **Gates:** `guest_jit_double_event_getter`, `guest_jit_optional_string_event_getter`, `guest_jit_optional_bool_double_event_getters`. 31/31 `guest_jit_*`. Not SYN_REPORT. |
| **B130** | B129 / P3 | **landed (exec model, not QEMU)** — **SYN_REPORT pointer packet (REL/wheel/hover).** `TabDrain` clamp-adds `REL_X`/`REL_Y` into `PTR_X`/`PTR_Y` (0..0x7fff), latches `PTR_MOVE` on ABS/REL motion and `PTR_WHEEL` on `REL_WHEEL`; `EV_SYN`/`SYN_REPORT` is an explicit no-op (the used-ring walk is the packet). `PTR_HOVER` inits to NONE (`-1`), not 0 (root). `DomtPtr` dispatches mouseout-old then mouseover-new, mousemove, wheel (`EVO_VALUE`=`deltaY`), then click. `WebFeed::hint_rel`/`hint_wheel` skip the dummy `BTN_LEFT`. BSS: `PTR_MOVE`/`PTR_WHEEL`/`PTR_HOVER` at `0x7cc..0x7d4` (after `BLK_FLUSH_OK`, not over virtio-net/blk). **Gates:** `guest_jit_mousemove_via_rel`, `guest_jit_mouseover_first_enter`, `guest_jit_wheel_at_button`. 34/34 `guest_jit_*`. Dummy ABS+BTN TAB count stays 3. Not RFB/KVM normalize, not QEMU. |
| **B131** | B130 / P3 | **landed (exec model, not QEMU)** — **RFB/KVM input normalize.** `g6b-asm/src/ptr.rs` `PtrNorm` scales/clips framebuffer px → tablet ABS (`px * 0x8000 / disp`, inverse of `DomtPtr`), coalesces moves to the last ABS pair, emits every left press/release and wheel edge, and rejects a second source while left is held. RFB 3.8 PointerEvent (`[5, mask, x_be, y_be]`) and first-party `KvmPointer` inject the same virtio-tablet eventq as local ABS/REL. Dummy local ABS+BTN path is unchanged (TAB count 3). **Gates:** `ptr::` 7/7; `guest_jit_rfb_pointer_clicks_button`; `guest_jit_kvm_wheel_at_button`. 36/36 `guest_jit_*`. Not RFB 3.8 session/auth (P8), not QEMU `-vnc`. |
| **B132** | B131 / P3 | **landed (exec model, not QEMU)** — **modifiers, DOM button/buttons, right/middle, click-to-focus.** `button` getter is DOM 0/1/2 (`EVO_BTN`), not Linux `BTN_*` (`EVO_CODE`). `buttons` is the chord mask. `ctrlKey`/`shiftKey`/`altKey`/`metaKey` read `EVO_MODS` bits latched by `InpDrain` from `KEY_LEFT/RIGHT*`. `TabDrain` maps `BTN_LEFT/MIDDLE/RIGHT` to `PTR_CLICK=button+1` and `PTR_BTNS`. `PtrNorm` emits matching virtio BTN edges for RFB bits 0/1/2. `DomtPtr` `DomtFocus`es the hit node on click. **Gates:** `guest_jit_click_button_is_zero`; `guest_jit_rfb_right_button_is_two`; `guest_jit_shift_click_shiftkey`; `guest_jit_click_focuses_button`; `ptr::rfb_right_emits_btn_right_not_left`. 40/40 `guest_jit_*`. Not password controls, not host-oracle mutation. |
| **B133** | B132 / P3 | **landed (host oracle)** — **mutation-stable dispatch path + event lifetime.** `Node` carries a `stamp`. `dispatch_event` snapshots root→target stamps at start; later phases look up by stamp, so removing the target during parent capture cannot fire the sibling that slid into that child index. A missing stamp is skipped. `currentTarget` and `eventPhase` are cleared when dispatch returns. `EventHost::invoke_in_tree` lets a listener mutate the tree; existing `invoke` impls keep working. **Gates:** `mutation_does_not_retarget_sibling`; `current_target_and_phase_clear_after_dispatch`. `g6b-dom` 14/14. Not password controls, not guest `__dom` generation retargeting. |
| **B134** | B133 / P3 | **landed (exec model, not QEMU)** — **password controls.** `setProperty(el,"type","password")` sets `F_PASSWORD`. `DomtRaster` paints `*` (`0x2a`) per character; `N_TPTR`/`N_TLEN` keep the real value. `DomtKey` default action: focused password + KEY_A + `!preventDefault` copies the value to the string-pool tail and appends `'a'`. **Gates:** `guest_jit_password_keeps_value`; `guest_jit_password_masks_raster`; `guest_jit_password_types_a`. Not a full editor, not IME, not QEMU. |
| **B135** | B134 / P1 | **landed (host, not QEMU)** — **portable wasm/DOM/Asyncify `RuntimeContext`.** `g6b-runtime-abi::ContextTable` (4 slots) issues generation-checked `Context` handles. Each slot owns a wasm `Span`, a DOM stamp, and one `Continuation` (`pc` / Asyncify span / `__prom` handle). Overlapping wasm windows are `Error::Overlap`. Teardown bumps generation and cannot steal a neighbour's resume. Stale/foreign handles are `Error::Context`. **Gates:** `two_contexts_keep_independent_continuations`; `teardown_does_not_cancel_neighbour`; `stale_generation_after_teardown_is_rejected`; `overlapping_wasm_windows_are_rejected`; `table_full_is_overflow`; `foreign_handle_cannot_resume_this_slot`. `g6b-runtime-abi` 12/12; `g6b-guest` 10/10. Not an `alloc` heap, not a guest `__prom`/`P_ASUSP` rewrite, not timer-tick Poll after park. |
| **B136** | B135 / P1 | **landed (exec model, not QEMU)** — **guest `__prom` per-context suspend.** 4-slot table after the promise records (`PROM_CTX_OFF`, stride 16). `PromCtx(slot)` selects `P_CTX`. `LwAwaitVoid` writes `table[P_CTX].asusp`; slot 0 still aliases `P_ASUSP`. `PromDrain` walks all slots and raises `P_RESUME` when any parked promise settles. **Gates:** `guest_jit_ctx1_suspend_does_not_alias_slot0`; `guest_jit_pending_await_suspends_then_resumes`. Not an `alloc` heap, not timer-tick Poll after park. |
| **B137** | B136 / P1 | **landed (host, not QEMU)** — **bounded no_std bump arena.** Workspace `unsafe_code = forbid`, so this is not a Rust `GlobalAlloc` / `extern crate alloc`. `g6b-runtime-abi::Bump` is a cursor over caller-owned backing: `alloc(size, align)` / `alloc_word` return aligned `Span`s, fail closed on OOM, non-power-of-two align, and wrapping add; `reset` rewinds; two bumps do not share a cursor. A `POLL_REPORT_BYTES` word alloc fits and indexes a caller-owned buffer without overlapping the next span. **Gates:** `sequential_word_allocs_are_aligned_and_disjoint`; `oom_is_fail_closed`; `bad_align_is_bounds`; `reset_reuses_the_arena`; `two_bumps_do_not_share_a_cursor`; `poll_report_fits`; `overflow_add_is_fail_closed`; `zero_size_does_not_consume_capacity`; `sequential_spans_do_not_overlap`; `caller_owned_backing_is_indexed_by_span`. `g6b-runtime-abi` 22/22; `g6b-guest` 10/10. Not guest BSS, not timer-tick Poll after park, not QEMU. |
| **B138** | B137 / P1 | **landed (exec model, not QEMU)** — **timer-tick Poll after park.** Boot probe copies the 256-byte ABI frame to `__native_abi` (after `__linux_load`). `trap_timer` always `jal NativePoll`; without `--native-manifest` the stub returns. Composed native magic-gates `G6SC`, `jalr`s the callee with `a0=__native_abi` (SIE still masked in trap), and prints `NATIVE-TICK-POLL-OK` once. Exec intercepts the callee `jalr` via `NativeHook` (`g6b_guest::native_entry`); host smoke still does not map extra PT_LOADs. **Gates:** `poll_second_tick_continues_remaining_slow`; `native_tick_poll_after_park_runs_once`. `g6b-guest` 11/11; `g6b-elf` 28/28; `g6b-asm` 121/121. Not nested-IRQ Poll, not QEMU, not autoboot. |
| **B139** | B138 / P2 | **landed (exec model, not QEMU)** — **inactive firmware stage + select hold.** Recovery slot A (LBA 24) stays protected. `FwStage` is `VIRTIO_BLK_T_OUT` into inactive B (LBA 32..40) only; A/journal/GPT are `FW-RANGE` before QueueNotify. Exec model allows T_OUT on journal **or** inactive B, still not A. `FwSelect` prints `FW-HOLD` and does not rewrite the selector or arm autoboot. UART `Fws` runs `FwStageSelftest`. **Gates:** `inactive_slot_is_the_only_stage_window`; `slot_select_is_refused_while_inhibit_and_never_switches`; `the_guest_stages_inactive_firmware_and_refuses_select` (`FW-STAGE-OK` / `FW-RANGE` / `FW-HOLD`, `G6FA` intact, `G6FB`→`G6FS`, MBR `0xAA55`). `g6b-bootctl` 21/21; `g6b-asm` 122/122. Not a full SPI image, not a slot switch, not QEMU, not autoboot. |
| **B140** | B139 / P2 | **landed (exec model, not QEMU)** — **declared inactive-slot rewrite.** `FwCommit` writes all 8 sectors of firmware B (`G6FS` + index + `G6FE` at offset 508), `BlkFlush`, then readbacks LBA 32 (index 0) and LBA 39 (index 7, tail `G6FE`). `FwStage` no longer prints per-sector OK. UART `Fws` still holds select. **Gates:** `the_guest_stages_inactive_firmware_and_refuses_select` now `FW-COMMIT-OK` / `FW-RANGE` / `FW-HOLD`; `blk_fw_b`/`blk_fw_b_last`=`G6FS`, `blk_fw_b_end`=`G6FE`, recovery A `G6FA`. `g6b-bootctl` 21/21; `g6b-asm` 122/122. Not SPI, not selector rewrite, not torn-media, not QEMU, not autoboot. |
| **B141** | B140 / P2 | **landed (exec model, not QEMU)** — **staged-slot nomination.** `Record.staged` is wire byte 20 (0/1/2). `Journal::nominate_inactive` persists B without clearing inhibit; `may_nominate(A)` is `Operator`; `decision`/`may_select` still Stay. Guest `FwSelect` requires `G6FS` on B, writes `G6SL` at offset 8, flush+readback (`FW-SELECT-OK`); missing stage is `FW-HOLD`. **Gates:** `nominate_inactive_records_b_without_clearing_inhibit`; `the_guest_stages_inactive_firmware_and_nominates_b` (`FW-SELECT-OK`, `blk_fw_sel=G6SL`, A intact). `g6b-bootctl` 22/22; `g6b-asm` 122/122. Not autoboot, not torn-media, not QEMU. |
| **B142** | B141 / P2 | **landed (exec model, not QEMU)** — **torn-media fail-closed.** `FwSelect` readbacks B last sector (`G6FS`, index 7, `G6FE`) before nominating; a mixed slot (first `G6FS`, last `G6FB`) is `FW-HOLD` with no `G6SL`. Recovery A and MBR survive. Interrupted `nominate_inactive` (failed I/O / partial write) never `Decision::Boot`. **Gates:** `torn_inactive_firmware_is_not_nominated`; `interrupted_nominate_never_clears_inhibit`; complete path still `the_guest_stages_inactive_firmware_and_nominates_b`. `g6b-bootctl` 23/23; `g6b-asm` 123/123. Not SPI, not autoboot, not QEMU. |
| **B143** | B142 / P11 | **landed (host, not QEMU)** — **watchdog-nowayout ownership.** `g6b-boot-health::WatchdogStamp` parses `nowayout`/`magic_close`/`keepalive`. `owned()` is true only with `nowayout=1`; keepalive alone is not ownership; magic-close without nowayout is an unmonitored gap. OpenWrt adapter reads `run/g6b-boot-health.watchdog`. Ack with keepalive-only stamp is `Unhealthy` (InProgress unchanged); nowayout ack Confirms without enabling autoboot. **Gates:** `keepalive_alone_is_not_ownership`; `magic_close_without_nowayout_is_an_unmonitored_gap`; `openwrt_keepalive_without_nowayout_is_unhealthy`; `openwrt_nowayout_ack_confirms_without_autoboot`. `g6b-boot-health` 17/17. Not a live OpenWrt VM, not `/dev/watchdog` ioctl, not QEMU. |
| **B144** | B143 / P11 | **landed (exec model, not QEMU)** — **FDT health handoff.** `handoff::encode/decode` builds `/firmware/g6b-boot-health` (`compatible=g6b,boot-health-1`, `journal-lba=8`, `journal-sectors=16`). `plant_canary` writes that DTB at LBA 44. `LinuxStub` scans the FDT for the compatible string and prints `LINUX-HEALTH-OK`; a 4-byte magic-only FDT does not. **Gates:** `bios_handoff_round_trips`; `linux_load_disk_reads_image_and_enters` (`LINUX-HEALTH-OK`); `linux_enter_sets_satp0_hartid_and_fdt` (no `LINUX-HEALTH-OK`). `g6b-boot-health` 20/20. Not a live OpenWrt VM, not a real kernel, not QEMU. |
| **B145** | B144 / P11 | **landed (host, not QEMU)** — **helper discovers the G6BH window from FDT.** `HealthHandoff::journal_offset` requires LBA≥8 and 16 sectors (8 KiB). `from_dt_root` reads `/firmware/g6b-boot-health/{compatible,journal-lba,journal-sectors}` like `/proc/device-tree`. `JournalFile::from_handoff` + CLI `--dtb`/`--dt-root`. **Gates:** `gpt_and_wrong_size_windows_are_bounds`; `proc_device_tree_files_decode`; `fdt_handoff_opens_the_declared_journal_window`. `g6b-boot-health` 23/23. Not a live OpenWrt VM, not a phandle disk, not `/dev/watchdog` ioctl, not QEMU. |
| **B146** | B145 / P11 | **landed (host, not QEMU)** — **partition volume discovery (no jump).** `g6b-boot-health::volume::scan` walks GPT/MBR via `g6b_vfs::part::read_table` and `bundle::classify`s the first 64 bytes of each partition. RISC-V `Image` is Kernel/executable; squashfs/UBI is Rootfs and `SquashfsNotExecutable`; FDT is DeviceTree; empty is Unknown. A `linux-root-riscv64` GUID does not override a squashfs payload. `--scan` is read-only and does not acknowledge. **Gates:** `gpt_image_squashfs_and_fdt_are_distinct_roles`; `squashfs_partition_is_not_a_jump_target`; `table_claim_does_not_override_squashfs_payload`; `whole_disk_image_is_a_kernel`; `empty_partition_is_unknown_not_a_kernel`; `scan_does_not_write`; `scan_path_opens_a_read_only_image`. `g6b-boot-health` 30/30. Not a filesystem walk for `/boot/Image`, not a live OpenWrt VM, not `/dev/watchdog` ioctl, not QEMU. |
| **B147** | B146 / P11 | **landed (host, not QEMU)** — **filesystem file discovery (no jump).** `volume::scan` mounts readable FAT/ext/NTFS/btrfs partitions read-only and lists `/`, `/boot`, `/efi/boot`. File content decides the role: `/boot/Image` is Kernel; a squashfs file is Rootfs/`SquashfsNotExecutable`; FDT is DeviceTree; `BOOTRISCV64.EFI` is Loader; `extlinux.conf` is Config. A FAT partition whose first bytes are not an Image is still a kernel volume when `/boot/Image` is present. `--scan` prints artifacts and does not acknowledge. **Gates:** `fat_boot_image_is_a_kernel_file`; `fat_squashfs_file_is_not_a_jump_target`; `efi_loader_is_not_a_kernel`; `fat_scan_does_not_write`. `g6b-boot-health` 34/34. Not a recursive tree walk, not a live OpenWrt VM, not `/dev/watchdog` ioctl, not QEMU. |
| **B148** | B147 / P11 | **landed (host, not QEMU)** — **`/dev/watchdog` ioctl mock (file, not hardware).** `WatchdogDevice` stores Linux watchdog state in a file and applies `WDIOC_KEEPALIVE` / `SETTIMEOUT` / `SETOPTIONS` / write-`'V'` / close. `ioctl(2)` is not issued on this Windows host; `WDIOC_KEEPALIVE` is the documented `_IOR('W', 5, int)` number. Keepalive without nowayout is not ownership; magic close disarms unless nowayout; `WDIOS_DISABLECARD` is `Nowayout`; Drop without `'V'` leaves the timer running. OpenWrt adapter prefers `dev/watchdog` over the stamp file and requires running+nowayout. CLI `--watchdog FILE`. **Gates:** `keepalive_ioctl_without_nowayout_is_not_ownership`; `magic_close_without_nowayout_disarms`; `nowayout_refuses_magic_close_and_disable`; `drop_without_magic_keeps_watchdog_running`; `settimeout_round_trips_and_zero_is_refused`; `openwrt_dev_watchdog_requires_nowayout_and_running`. `g6b-boot-health` 42/42. Not a live `/dev/watchdog`, not a guest deadline past `LinuxEnter`, not QEMU. |
| **B149** | B148 / P11 | **landed (exec model, not QEMU)** — **platform WDT survives `LinuxEnter`.** `LinuxEnter` writes `G6WD` + `mtime+WDT_TICKS` at the tail of `__linux_load` before `satp=0`/`sie=0`. The exec model compares `mtime` even when SIE is clear (`wfi` is a wait, not a halt, while armed) and prints `LINUX-WDT-FIRE`. A canary `LINUX-ENTRY-OK` is not an ack; a hang stub never prints entry-ok and still fires with `ticks=0`. Hold-without-journal does not arm. **Gates:** `linux_hang_after_enter_fires_platform_wdt_with_sie_clear`; `linux_enter_sets_satp0_hartid_and_fdt` / relocate / disk-load include `LINUX-WDT-FIRE`; `linux_load_disk_holds_without_in_progress_journal` does not. `g6b-asm` 124/124; `g6b-elf` 28/28. Not a live OpenWrt VM, not a real kernel, not a hardware WDT, not QEMU. |
| **B150** | B149 / P3 | **landed (exec model, not QEMU)** — **`timeStamp` and `deltaMode` getters.** `__ev_obj` `EVO_TIME` is `csr time` at fill; `EVO_DMODE` is `DOM_DELTA_LINE` (1) for virtio `REL_WHEEL` and 0 otherwise. `Object_Getter__double` `timeStamp` > 0; `Object_Getter__uint` `deltaMode` == 1. **Gates:** `guest_jit_timestamp_event_getter`; `guest_jit_wheel_delta_mode_is_line`. Not a full text editor, not IME, not RFB 3.8 session/auth, not QEMU. |
| **B151** | B150 / P3 | **landed (exec model, not QEMU)** — **printable US text controls.** `dtk_keymap` maps Linux EV_KEY to ASCII; backspace (`0x08`) deletes; Shift uppercases letters. `type=text` sets `F_EDITABLE`; password or text fields take the default action unless `preventDefault`. **Gates:** `guest_jit_text_types_a`; `guest_jit_password_types_b`; `guest_jit_password_backspace`; `guest_jit_password_shift_a`; `guest_jit_password_types_a` still `'a'`. Not IME, not a caret/selection editor, not QEMU. |
| **B152** | B151 / P3 | **landed (exec model, not QEMU)** — **per-field caret.** `H_CARET` is the insert index in the focused editable node. `DomtFocus` sets it to `N_TLEN`. Left/Right/Home/End move it (and skip `__web_dl` menu nav while the field is focused). Insert copies with a hole at the caret; backspace deletes the previous byte. **Gates:** `guest_jit_text_caret_insert` (`"ab"`+LEFT+C → `"acb"`); `guest_jit_text_caret_backspace` (`"ab"`+LEFT+BS → `"b"`). End-append and end-backspace still pass. Not a selection range, not IME, not QEMU. |
| **B153** | B152 / P3 | **landed (exec model, not QEMU)** — **shift-arrow selection.** `H_SEL` is the anchor (`== H_CARET` when collapsed). Shift+Left/Right/Home/End keep the anchor; a plain move collapses. Insert and backspace delete `[lo,hi)` then type/stop. `InpDrain` packs `PTR_MODS` into KQ bits 24..31 so a Shift release later in the same burst does not wipe the Left. **Gates:** `guest_jit_text_select_replace` (`"ab"`+S-LEFT+C → `"ac"`); `guest_jit_text_select_backspace` (`"ab"`+S-LEFT+BS → `"a"`). Caret insert/backspace and Shift+A still pass. Not IME, not QEMU. |
| **B154** | B153 / P4 | **landed (exec model, not QEMU)** — **guest `try_table` catch dest.** `jcode` lowers `try_table` + `catch $tag $label` (label 0 = parent, not counting the table). `throw` is a `br` to that dest; payload stays on the stack. `catch_ref`/`catch_all_ref`/`throw_ref` stay `TRAP_UNSUP`. **Gates:** `guest_jit_try_table_catch` (`WASM-JIT 7`); `guest_jit_cross_func_throw` still 777. Not handler-depth restore, not `exnref`, not QEMU. |
| **B155** | B154 / P4 | **landed (host interp, not QEMU)** — **`catch_all` does not push the throw payload.** `throw_exception` and rethrow truncate to the try height only for `catch_all`; tagged `catch` still extends the payload. **Gates:** `catch_all_does_not_push_throw_payload` (`i32.eqz` underflows after throw 99); `throw_try_table_catch_dest_returns_payload` still 7; `guest_jit_cross_func_throw` still 777. Not guest JIT vsp restore, not `exnref`, not QEMU. |
| **B156** | B155 / P4 | **landed (exec model, not QEMU)** — **guest JIT handler operand-depth restore.** `jcode` snapshots the try height (cells from `s11`, including locals). `R_EXCCLR.a` is that height; `.b` is the tag payload count (`0` for `catch_all`). `jit_h_excclr` clears `OFF_EXC`, sets `s10 = s11 + a*8`, and copies the top `b` cells onto that height. **Gates:** `catch_all_excclear_records_try_height` (`a=1,b=0`); `guest_jit_catch_all_restores_vsp` (`i32.const 1; try { i32.const 99; throw; catch_all }` returns 1 not 99); `guest_jit_cross_func_throw` still 777; `guest_jit_try_table_catch` still 7; `guest_jit_executes_shipped_cell` still runs. Not `exnref`/`throw_ref`, not continuation-owned EH, not QEMU. |
| **B157** | B156 / P4 | **landed (exec model, not QEMU)** — **guest `try_table` catch dest restores vsp.** Local `throw` inside `try_table` emits `R_EXCCLR` at the dest frame height (`label 0` = parent) then `br`. `catch_all` copies 0 payload cells; tagged `catch` still copies the tag params. **Gates:** `try_table_catch_all_excclear_records_dest_height` (`a=1,b=0`); `guest_jit_try_table_catch_all_restores_vsp` returns 1 not 99; `try_table_catch_all_does_not_keep_throw_payload` (interp); `guest_jit_try_table_catch` still 7; `guest_jit_executes_shipped_cell` still runs. Not cross-func throw into `try_table`, not `exnref`, not QEMU. |
| **B158** | B157 / P4 | **landed (exec model, not QEMU)** — **cross-function throw into single-clause `try_table`.** `R_EXCCHK` inside a one-clause table is patched to an off-fallthrough `R_EXCCLR`+`R_JMP` pad. `b` is the expected tag (`u64::MAX` = `catch_all`); a mismatch propagates. Multi-clause tables still leave `a=u32::MAX`. **Gates:** `guest_jit_cross_func_throw_try_table` (`WASM-JIT 777`); `guest_jit_cross_func_throw` still 777; `guest_jit_executes_shipped_cell` still runs. Not multi-clause dispatch, not tagged payload across `R_THROW` (`s10=s11` drops callee operands), not `exnref`, not QEMU. |
| **B159** | B158 / P4 | **landed (exec model, not QEMU)** — **one-cell tagged payload survives `R_THROW`.** `R_THROW.a` is the tag payload count; when nonzero the top wasm cell is stored in `OFF_EXCPAY` before `s10=s11`. `R_EXCCLR` reloads that cell when `OFF_EXC` was set (cross-function); a local `JMP` still copies off the wasm stack. **Gates:** `guest_jit_cross_func_throw_payload` (`WASM-JIT 7`); `guest_jit_cross_func_throw_try_table` still 777; `guest_jit_try_table_catch` still 7; `guest_jit_executes_shipped_cell` still runs. Not multi-cell payloads, not rethrow, not multi-clause dispatch, not `exnref`, not QEMU. |
| **B160** | B159 / P4 | **landed (exec model, not QEMU)** — **multi-clause `try_table` EXCCHK.** One post-call `R_EXCCHK` per executable clause. `EXCCHK_CHAIN` (bit 32 of `b`) makes a tagged miss fall through to the next check; the last clause still propagates on miss. Each clause has its own `R_EXCCLR`+`R_JMP` pad. **Gates:** `guest_jit_cross_func_throw_try_table_multi_miss` (miss `$e0` → `catch_all` 777); `guest_jit_cross_func_throw_try_table_multi_hit` (hit `$e0` returns 7, not 777); single-clause and payload tests still pass; `guest_jit_executes_shipped_cell` still runs. Not multi-cell payloads, not `exnref`, not QEMU. |
| **B161** | B160 / P4 | **landed (exec model, not QEMU)** — **multi-cell tagged payload (bound 4).** `OFF_EXCPAY` is `MAX_EXCPAY` u64 cells. `R_THROW` copies `a` cells deepest-first; cross-function `R_EXCCLR` copies `b` cells from that buffer (local `JMP` still copies off the wasm stack). **Gates:** `guest_jit_cross_func_throw_payload2` (3+4 → 7); one-cell payload, multi-clause, and `guest_jit_executes_shipped_cell` still pass. Not payloads beyond 4, not rethrow, not `exnref`, not QEMU. |
| **B162** | B161 / P4 | **landed (exec model, not QEMU)** — **`rethrow 0` from a tagged catch.** Label 0 is the current try (already consumed); search *outside* it for the next `try` catch, else escape with `R_THROW` `a=catch_nparams` so a local throw's stack payload is restashed. **Gates:** `guest_jit_rethrow_nested` (same-function outer catch returns 7); `guest_jit_rethrow_escape` (callee rethrow, caller catch returns 7); payload/multi-clause tests and `guest_jit_executes_shipped_cell` still pass. Not rethrow into `try_table`, not rethrow after the catch body consumed the payload, not `exnref`, not QEMU. |
| **B163** | B162 / P4 | **landed (exec model, not QEMU)** — **`rethrow 0` into an enclosing `try_table`.** Walks outer frames for a table dest and emits `R_EXCCLR` then `br` like a local throw. **Gates:** `guest_jit_rethrow_try_table` (inner `try`/`catch $e`/`rethrow 0` inside `try_table (catch $e 0)` returns 7); payload/multi-clause/rethrow nested+escape and `guest_jit_executes_shipped_cell` still pass. Not `exnref`/`throw_ref`, not rethrow after the catch body consumed the payload, not QEMU. |
| **B164** | B163 / P4 | **landed (exec model, not QEMU)** — **`catch_all_ref` + `throw_ref`.** Dest gets an opaque exnref (handle = `EXCTAG+1`; 0 is null). Payload stays in `OFF_EXCPAY` (one live exception; a second throw clobbers it). `R_EXNREF` MAKE stashes payload and pushes the handle; `throw_ref` pops it, sets `OFF_EXC`, and the following `R_EXCCHK` routes. Null is `TRAP_UNREACH`. `catch_ref` stays `TRAP_UNSUP` 0x500. **Gates:** `guest_jit_catch_all_ref_throw_ref` (local, payload 7); `guest_jit_cross_func_catch_all_ref_throw_ref` (callee throw into `catch_all_ref`, then `throw_ref` → 7); interp `catch_all_ref_throw_ref_returns_payload`; `guest_jit_executes_shipped_cell` still runs. Not `catch_ref`/multi-value dest, not continuation-owned EH, not QEMU. |
| **B165** | B164 / P4 | **landed (exec model, not QEMU)** — **`catch_ref` payload plus exnref dest.** Tag-matched; dest copies payload then the handle (`EXCCLR.b = nparams+1`). A miss falls through to a later `catch_all`. **Gates:** `guest_jit_catch_ref_throw_ref` (payload 7); `guest_jit_catch_ref_exnref_is_nonzero` (dest top is handle 1, not 7); `guest_jit_catch_ref_miss_falls_to_catch_all` (777); `catch_ref_excclear_copies_payload_and_handle` (`b=2`); interp `catch_ref_throw_ref_returns_payload` and `catch_ref_dest_top_is_exnref_handle`; `guest_jit_executes_shipped_cell` still runs. Not 2-result block types, not continuation-owned EH, not QEMU. |
| **B166** | B165 / P4 | **landed (exec model, not QEMU)** — **continuation-owned EH.** `PromCtx` spills/fills `__jit` `OFF_EXC`/`EXCTAG`/`EXCPAY` into the 64-byte context slot so two slots cannot alias one in-flight exception. Host `Continuation` carries `exc`/`exc_tag`/`exc_pay[4]`; teardown drops it. **Gates:** `guest_jit_promctx_isolates_exc_bank` (slot 1 EXC=0; switch-back TAG=7 PAY=99); `two_contexts_keep_independent_exceptions`; `teardown_drops_exception`; `guest_jit_ctx1_suspend_does_not_alias_slot0` and `guest_jit_executes_shipped_cell` still run. `g6b-runtime-abi` 24/24. Not `JitCall` auto-switch, not asyncify sharing a try with wasm-EH, not QEMU. |
| **B167** | B166 / P4 | **landed (exec model, not QEMU)** — **outermost user `JitCall` restores the EH bank.** Spill `OFF_EXC`/`EXCTAG`/`EXCPAY` into `OFF_EXC_NEST` when nest depth is 0; zero the live bank for the nested invoke; restore on every `jit_call_out` path that owns the nest. Nested/control `JitCall`s skip the spill. **Gates:** `guest_jit_jitcall_restores_exc_bank` (plant tag 7 / pay 99, `JitCall` `_start`, bank restored); `guest_jit_jitcall_reenters_cell_fn`; `guest_jit_pending_await_suspends_then_resumes`; `guest_jit_executes_shipped_cell` still run. Not PromCtx-switch on `JitCall`, not asyncify sharing a try with wasm-EH, not QEMU. |
| **B168** | B167 / P4 | **landed (exec model, not QEMU)** — **guest JIT fail-closed `await` inside `try`/`try_table`.** Direct `env.libwasm_await__void` / `env.await` while a `try`/`try_table` is on the control stack lowers to `TRAP_UNSUP` 0x700 (rewind is not a landing pad). **Gates:** `await_inside_try_is_a_coverage_gap` (install refuses; gap describes await-in-try); `shipped_cell_op_coverage_report` still `clean()`; `guest_jit_pending_await_suspends_then_resumes` (await outside try) and `guest_jit_executes_shipped_cell` still run. Not callee-await from a try, not host Binaryen-fork try+await, not QEMU. |
| **B169** | B168 / P4 | **landed (exec model, not QEMU)** — **callee-await from a try.** After every body is lowered, a `try`/`try_table` `call` whose callee can reach `await` (directly or via other calls) is rewritten to `TRAP_UNSUP` 0x700. **Gates:** `await_via_call_from_try_is_a_coverage_gap`; `await_inside_try_is_a_coverage_gap` still holds; `shipped_cell_op_coverage_report` still `clean()`; `guest_jit_cross_func_throw` (try calling a thrower, not an awaiter) and `guest_jit_executes_shipped_cell` still run. Not `call_indirect` to an awaiter, not host Binaryen-fork try+await, not QEMU. |
| **B170** | B169 / P4 | **landed (exec model, not QEMU)** — **`call_indirect` from a try to an await-capable table.** Table-conservative: if any funcref-table function can reach `await`, every `call_indirect` inside `try`/`try_table` becomes `TRAP_UNSUP` 0x700. **Gates:** `await_via_calli_from_try_is_a_coverage_gap`; `calli_in_try_without_awaiter_is_clean`; shipped cell still `clean()`; `guest_jit_executes_m3_cell` still runs. Not per-index table proof, not host Binaryen-fork try+await, not QEMU. |
| **B171** | B170 / P4 | **landed (host interp, not QEMU)** — **interp fail-closed direct `await` inside `try`/`try_table`.** Same rule as guest JIT 0x700: rewind is not a landing pad. Fork WAT still decodes; await outside try still rewinds. **Gates:** `await_inside_try_is_rejected`; `try_table_await_is_rejected_before_unwind`; `ui_try_await_catch_is_rejected_before_unwind`; `wrap_export_fn_reject_still_rewinds`; `libwasm_cell_start_asyncify_await_then_eh_catch`. Not interp callee-await from a try, not QEMU. |
| **B172** | B171 / P4 | **landed (host interp, not QEMU)** — **interp callee-await from a try.** Direct-`call` graph: `try { call $awaiter }` is rejected when `$awaiter` can reach `await`. Resolved `call_indirect` to an awaiter is also rejected. **Gates:** `await_via_call_from_try_is_rejected`; `await_inside_try_is_rejected`; `wrap_export_fn_reject_still_rewinds`; `libwasm_cell_start_asyncify_await_then_eh_catch`. **P4 sequential leftovers closed.** Not a call_indirect-only callee that never `call`s await, not IME, not QEMU. P5 may start. |
| **B173** | B172 / P5 | **landed (host parse, not QEMU)** — **binary-safe HTTP/1.1 response parse.** `g6b-http::outbound::parse_http1_response` copies the body as bytes (no `from_utf8_lossy`), honors `Content-Length` (short=502 truncated; extra after the length dropped), and rejects conflicting framing (`Content-Length` plus `Transfer-Encoding`, or two disagreeing lengths). `Transfer-Encoding` including chunked is refused. Close-delimited (no length) takes the remainder of a complete buffer snapshot. **Gates:** `parse_http1_preserves_binary_body`; `parse_http1_content_length_drops_extra`; `parse_http1_short_content_length_is_truncated`; `parse_http1_rejects_content_length_and_chunked`; `parse_http1_rejects_disagreeing_content_lengths`; `parse_http1_body_without_network`. Chunked decode is B174. Not idle-as-EOF (`KernelNet` `CLOSE_GRACE` still stands), not guest virtio-net packets, not live HTTP, not QEMU. |
| **B174** | B173 / P5 | **landed (host parse, not QEMU)** — **chunked HTTP/1.1 response decode.** `Transfer-Encoding: chunked` (alone) is decoded from a complete snapshot; hex sizes, chunk-ext after `;`, binary chunk data, and a last-chunk of `0`. Trailers are required to terminate (`\r\n\r\n`) and are discarded (not body, not a second `Content-Length`). `gzip, chunked` and any other coding stay refused. `Content-Length` plus chunked stays conflicting. **Gates:** `parse_http1_decodes_chunked_body`; `parse_http1_chunked_preserves_binary`; `parse_http1_chunked_joins_chunks_and_drops_trailers`; `parse_http1_chunked_truncated_is_refused`; `parse_http1_gzip_chunked_is_refused`; `parse_http1_rejects_content_length_and_chunked`. Not idle-as-EOF (`KernelNet` `CLOSE_GRACE` still stands), not partial I/O vs complete snapshot, not guest virtio-net packets, not live HTTP, not QEMU. |
| **B175** | B174 / P5 | **landed (host parse + KernelNet poll, not QEMU)** — **partial HTTP/1.1 I/O.** `parse_http1_response_partial(raw, eof)` returns `NeedMore` (framed prefix: short `Content-Length` or incomplete chunked), `NeedEof` (close-delimited; only caller EOF completes it), or `Done`. `eof` is a peer-close claim, not idle time. KernelNet finishes `Content-Length`/chunked on `Done` and applies `CLOSE_GRACE` only on `NeedEof`. **Gates:** `parse_http1_partial_headers_need_more`; `parse_http1_partial_content_length_needs_more`; `parse_http1_partial_chunked_needs_more_until_last_chunk`; `parse_http1_close_delimited_needs_eof`; `parse_http1_partial_conflicting_framing_fails_before_body`; `outbound_get_polls_a_real_socket_without_a_thread`; `outbound_get_finishes_chunked_without_idle_eof`. Not actual TCP EOF vs `WouldBlock` (`tcp_recv_bytes` still collapses both to empty), not guest virtio-net packets, not live HTTP, not QEMU. |
| **B176** | B175 / P5 | **landed (host stack + KernelNet, not QEMU)** — **TCP `WouldBlock` vs peer EOF.** `g6b-hw::TcpRecv` is `Data` / `WouldBlock` / `Eof`. `Ok(0)` is EOF; `WouldBlock`/`Interrupted` stay WouldBlock; Windows `ConnectionReset`/`ConnectionAborted` map to Eof. KernelNet passes `eof` into `parse_http1_response_partial` and dropped `CLOSE_GRACE`. Close-delimited idle is not completion. HolyC `tcp_recv` string still collapses WouldBlock and Eof to empty. **Gates:** `tcp_recv_distinguishes_wouldblock_and_eof`; `outbound_get_close_delimited_waits_for_peer_eof_not_idle`; `outbound_get_polls_a_real_socket_without_a_thread`; `outbound_get_finishes_chunked_without_idle_eof`. Not guest virtio-net RX/TX/DMA, not IPv4/ARP, not live HTTP, not QEMU. |
| **B177** | B176 / P5 | **landed (exec model, not QEMU)** — **virtio-net feature negotiation.** After DeviceID probe, guest `VioNetProbe` resets STATUS, writes ACK\|DRIVER, accepts word0 `CSUM\|MAC\|STATUS` and word1 `VERSION_1`, then FEATURES_OK readback. Extra word0 bits or missing `VERSION_1` clear FEATURES_OK (`VIRTIO-NET-HOLD`). Success prints `VIRTIO-NET-OK`. No virtqueues, no RX/TX, no packets. **Gates:** `vio_net_probe_finds_modelled_net_at_slot5` (`VIRTIO-NET 5` + `VIRTIO-NET-OK`); `kstart_probes_virtio_net_without_qemu_netdev` (`vn_hold` path present). Not guest packets, not IPv4/ARP, not live HTTP, not QEMU. |
| **B178** | B177 / P5 | **landed (exec model, not QEMU)** — **virtio-net receiveq/transmitq.** After FEATURES_OK, guest programs queue 0 (RX) and queue 1 (TX) at `__vio+NET_BASE` (0x1000; `VIO_BSS` 0x1400), `QueueNum=8`, then `DRIVER_OK`. `QueueNumMax` is 8 for q0/q1 and 0 otherwise. No `QUEUE_NOTIFY`, no packet buffers. **Gates:** `vio_net_probe_finds_modelled_net_at_slot5` still `VIRTIO-NET-OK` (queue `QueueNumMax==0` would `HOLD`); `kstart_probes_virtio_net_without_qemu_netdev`. Not packet DMA, not IPv4/ARP, not live HTTP, not QEMU. |
| **B179** | B178 / P5 | **landed (exec model, not QEMU)** — **virtio-net TX→RX loopback.** Guest posts one device-write RX buffer and one TX `virtio_net_hdr` (12) plus LE `G6LC`. RX notify records the buffer; TX notify copies into it and publishes both used rings. Guest waits on RX `used.idx` and checks the mark (`VIRTIO-NET-PKT`). **Gates:** `vio_net_probe_finds_modelled_net_at_slot5` (`VIRTIO-NET-OK` + `VIRTIO-NET-PKT`). Not Ethernet/ARP/IP, not a PHY, not live HTTP, not QEMU. |
| **B180** | B179 / P5 | **landed (exec model, not QEMU)** — **Ethernet/ARP who-has.** Guest TX is broadcast ARP for 10.0.2.2 from 10.0.2.15. Exec model answers with gateway MAC `52:54:00:12:34:02`. Guest checks ethertype 0x0806, oper=2, spa 10.0.2.2 (`VIRTIO-NET-ARP`). **Gates:** `vio_net_probe_finds_modelled_net_at_slot5`. Not ICMP/TCP, not DHCP, not QEMU, not a PHY. |
| **B181** | B180 / P5 | **landed (exec model, not QEMU)** — **IPv4 ICMP echo.** Second RX buffer; guest TX echo-request to 10.0.2.2. Exec model swaps MAC/IP, type 8→0, recomputes checksums (`VIRTIO-NET-ICMP`). **Gates:** `vio_net_probe_finds_modelled_net_at_slot5`. Not TCP/UDP/DNS/DHCP, not live HTTP, not QEMU, not a PHY. |
| **B182** | B181 / P5 | **landed (exec model, not QEMU)** — **TCP SYN/SYN-ACK.** Recycles RX desc 0; guest SYN from 10.0.2.15:12345 to 10.0.2.2:80 seq=1. Gateway replies SYN-ACK seq=1000 ack=2 flags 0x12 (`VIRTIO-NET-TCP`). No ACK, payload, retransmission, window, FIN/RST. **Gates:** `vio_net_probe_finds_modelled_net_at_slot5`. Not live HTTP, not QEMU, not a PHY. |
| **B183** | B182 / P5 | **landed (exec model, not QEMU)** — **TCP ACK completes the handshake.** Guest ACK seq=2 ack=1001 flags 0x10. Gateway replies ACK seq=1001 ack=2 (`VIRTIO-NET-ACK`). No payload, FIN/RST, retransmission. **Gates:** `vio_net_probe_finds_modelled_net_at_slot5`. Not live HTTP, not QEMU, not a PHY. |
| **B184** | B183 / P5 | **landed (exec model, not QEMU)** — **TCP HTTP GET / binary 200.** Guest PSH+ACK `GET /fw.bin HTTP/1.1` to :80. Gateway replies `HTTP/1.1 200 OK` `Content-Length: 4` body `00 ff fe 80` (`VIRTIO-NET-HTTP`). Not FIN/RST/retransmit, not KernelNet-on-virtio, not QEMU, not a PHY. **Gates:** `vio_net_probe_finds_modelled_net_at_slot5`; `net_http_reply_sees_get`. |
| **B185** | B184 / P5 | **landed (exec model, not QEMU)** — **TCP FIN/FIN-ACK.** After HTTP, guest FIN+ACK seq=42 ack=1043. Gateway replies FIN+ACK seq=1043 ack=43 (`VIRTIO-NET-FIN`). HTTP match requires IPv4 totlen>40 so leftover TX payload is not a GET. Not retransmit/RST, not KernelNet-on-virtio, not QEMU. **Gates:** `vio_net_probe_finds_modelled_net_at_slot5`. |
| **B186** | B185 / P5 | **landed (exec model, not QEMU)** — **UDP echo.** Guest UDP 10.0.2.15:12345 → 10.0.2.2:7 payload `00 ff fe 80`. Gateway swaps MAC/IP/ports and echoes (`VIRTIO-NET-UDP`). Not DNS/DHCP, not KernelNet-on-virtio, not QEMU. **Gates:** `vio_net_probe_finds_modelled_net_at_slot5`. |
| **B187** | B186 / P5 | **landed (exec model, not QEMU)** — **DNS A query.** Guest UDP query `g6lc` IN A to 10.0.2.2:53. Gateway sets QR, ancount=1, A 10.0.2.2 (`VIRTIO-NET-DNS`). Not DHCP, not a recursive resolver, not KernelNet-on-virtio, not QEMU. **Gates:** `vio_net_probe_finds_modelled_net_at_slot5`. |
| **B188** | B187 / P5 | **landed (exec model, not QEMU)** — **DHCP DORA.** Buffers enlarged to 320 B (`VIO_BSS` 0x1800). Guest DISCOVER (broadcast :67) → OFFER yiaddr 10.0.2.15; REQUEST → ACK (`VIRTIO-NET-DHCP`). Not a lease database, not KernelNet-on-virtio, not QEMU. **Gates:** `vio_net_probe_finds_modelled_net_at_slot5`. |
| **B189** | B188 / P5 | **landed (exec model, not QEMU)** — **TCP RST.** Guest SYN to 10.0.2.2:9 (not :80). Gateway replies RST+ACK flags 0x14 (`VIRTIO-NET-RST`). Not retransmit, not KernelNet-on-virtio, not QEMU. **Gates:** `vio_net_probe_finds_modelled_net_at_slot5`. |
| **B190** | B189 / P5 | **landed (exec model, not QEMU)** — **TCP SYN retransmit.** First SYN to :81 is dropped (TX used, RX buffer kept). Guest retries; second SYN gets SYN-ACK (`VIRTIO-NET-REXMIT`). Not an RTO timer, not KernelNet-on-virtio, not QEMU. **Gates:** `vio_net_probe_finds_modelled_net_at_slot5`. |
| **B191** | B190 / P5 | **landed (host packet peer, not QEMU)** — **KernelNet GET over in-memory NAT frames.** `g6b-hw::nat_http_on_wire` wraps GET in Ethernet/IPv4/TCP, answers 200 + `00 ff fe 80`, unwraps TCP payload. `KernelNet` uses this for `http://10.0.2.2/` instead of `std::net`. 127.0.0.1 tests still use host sockets. **Gates:** `nat_http_on_wire_returns_binary_body`; `outbound_get_nat_gateway_uses_packets_not_host_sockets`. Not QEMU, not external peers, not a PHY. |
| **B192** | B191 / P5 | **landed (host packet peer, not QEMU)** — **TCP reassembly.** `NatHttpReasm` stores payloads by seq; a GET split across two frames (including out-of-order) concatenates from seq 0 and then answers 200. Not RTO, not QEMU. **Gates:** `nat_http_reasm_joins_split_get_out_of_order`. |
| **B193** | B192 / P5 | **landed (host packet peer, not QEMU)** — **TCP listen handshake.** `NatTcp::listen` accepts SYN → SYN-ACK (seq 1000), ACK → established, then GET → 200. GET before SYN is refused. `nat_http_on_wire` runs this handshake. **Gates:** `nat_tcp_listen_wants_syn_then_get`; `nat_http_on_wire_returns_binary_body`; `outbound_get_nat_gateway_uses_packets_not_host_sockets`. Not a listen backlog, not QEMU, not a PHY. |
| **B194** | B193 / P5 | **landed (host packet peer, not QEMU)** — **virtio-shaped TX/RX used-idx.** `VirtioNetDma` posts one TX and one RX buffer; `notify_tx` pumps `NatTcp`. ACK is silent on RX. `nat_http_on_wire` uses this path. Not guest `__vio` rings, not QEMU. **Gates:** `virtio_net_dma_used_idx_tracks_handshake_and_get`; `outbound_get_nat_gateway_uses_packets_not_host_sockets`. |
| **B195** | B194 / P5 | **landed (host packet peer, not QEMU)** — **virtio desc/avail/used rings.** `VirtioNetDma` memory matches `NET_*` offsets: 16-byte desc (`addr,len,flags,next`), RX `DEVICE_WRITE`, avail `idx` + ring, used `{id,len}`. Notify walks avail like the exec model. Not guest `__vio`, not QEMU. **Gates:** `virtio_net_dma_used_idx_tracks_handshake_and_get` (RX WRITE + used idx 3/2). |
| **B196** | B195 / P5 | **landed (exec model, not QEMU)** — **KernelNet GET via exec-model guest rings.** `GuestVirtioNet` FEATURES_OK + q0/q1 at `NET_*`, posts RX `DEVICE_WRITE`, TX with `virtio_net_hdr`, `net_notify`. `http_get` does SYN/ACK/GET. KernelNet `10.0.2.2` calls this instead of `nat_http_on_wire`. Not kstart `__vio` BSS, not QEMU. **Gates:** `guest_virtio_net_http_get_via_exec_rings`; `outbound_get_nat_gateway_uses_packets_not_host_sockets`. |
| **B197** | B196 / P5 | **landed (exec model, not QEMU)** — **second GET on kstart `__vio`.** `GuestVirtioNet::from_kstart` keeps RAM/CSR after `VioNetProbe` (avail idx continues from `net_rx_seen`/`net_tx_seen`). `fetch` posts another SYN/GET on those rings. **Gates:** `kstart_vio_bss_second_http_get`. Not QEMU, not a PHY, not external peers. |
| **B198** | B197 / P5 | **landed (exec model, not QEMU)** — **KernelNet GET via `from_kstart`.** When the board `wants_virtio_net()`, `http://10.0.2.2` runs `analyze::kstart` then `GuestVirtioNet::from_kstart` + `fetch` (live `__vio` after `VioNetProbe`). Otherwise `http_get` on fresh rings. **Gates:** `outbound_get_nat_gateway_uses_packets_not_host_sockets`. Not QEMU, not external peers, not a PHY. |
| **B199** | B198 / P5 | **landed (host packet peer, not QEMU)** — **ICMP dest-unreach fragmentation-needed.** IPv4 DF + totlen > MTU → type 3 code 4 with next-hop MTU (RFC 1191). Encapsulated TCP sets DF. `NAT_MTU` 1500 so normal GET still 200. **Gates:** `icmp_frag_needed_when_df_and_over_mtu`. Not IP fragment reassembly, not QEMU, not a PHY. |
| **B200** | B199 / P5 | **landed (host packet peer, not QEMU)** — **IPv4 fragment reassembly.** `ip_fragment` splits a no-DF datagram (chunk multiple of 8). `IpReasm` stores payload by offset; out-of-order fragments wait for offset 0 and MF=0, then the same 200 body. Gateway refuses a lone first fragment. DF still cannot fragment. **Gates:** `ip_reasm_joins_split_get_out_of_order`. Not a reassembly timeout, not overlapping fragments, not QEMU, not a PHY. |
| **B201** | B200 / P5 | **landed (host packet peer, not QEMU)** — **KernelNet cancel/watchdog during NAT fetch.** `get` arms `10.0.2.2` only; each `poll` takes watchdog then one SYN/ACK/GET on guest rings. Cancel before poll or after SYN drops the rings and does not GET. Watchdog hold fails before packet I/O. Neighbour job is not cancelled. **Gates:** `outbound_nat_cancel_before_poll_never_sends_get`; `outbound_nat_cancel_after_syn_never_completes`; `outbound_nat_watchdog_stops_fetch_before_packet`; `outbound_nat_cancel_does_not_drop_neighbour`. Not QEMU, not a PHY, not a live WDT. |
| **B202** | B201 / P5 | **landed (host packet peer, not QEMU)** — **link-loss completion.** Cable unplug / `ip link down` marks the NIC `LinkState::Down`. KernelNet poll fails `link down` before SYN/GET/recv, drops rings and closes the socket. Does not wait for the stall deadline. **Gates:** `unplug_returns_idle_without_env_change` (link down); `outbound_nat_link_down_after_syn_never_completes`; `outbound_nat_unplug_before_poll_never_sends_get`; `outbound_get_link_down_completes_without_stall`. Not QEMU, not a PHY, not a live cable. |
| **B203** | B202 / P5 | **landed (host packet peer, not QEMU)** — **connect/DNS not in `get`.** Socket GET stores host/port; each poll tries one IPv4-literal `connect_timeout(1ms)`. IPv6 and hostnames are named refuses (`ipv6 is not implemented` / `dns: hostname … needs an async job`). `get` against a closed port returns a handle. Not a kept EINPROGRESS fd, not OS DNS, not QEMU. **Gates:** `resolve_ipv4_literal_skips_dns`; `outbound_get_arms_without_connect`; `outbound_get_hostname_needs_async_dns`; `outbound_get_polls_a_real_socket_without_a_thread`. |
| **B204** | B203 / P5 | **landed (host packet peer, not QEMU)** — **isolated NAT DNS A job.** `nat_dns_a("g6lc")` is a UDP :53 query/response on in-memory frames (A 10.0.2.2). KernelNet `http://g6lc/fw.bin` polls DNS then the NAT GET. Extra labels / `g6lc.invalid` stay fail-closed. Cancel before DNS does not GET. **Gates:** `nat_dns_a_g6lc_is_gateway`; `outbound_get_g6lc_uses_nat_dns_not_os`; `outbound_get_g6lc_cancel_before_dns_never_gets`; `outbound_get_hostname_needs_async_dns`. Not OS `getaddrinfo`, not recursive, not QEMU. |
| **B205** | B204 / P5 | **landed (host packet peer, not QEMU)** — **NAT nameserver 10.0.2.3.** DNS UDP dest is `NAT_DNS`, not the HTTP gateway. Reply src is 10.0.2.3; A is still 10.0.2.2. A :53 query to 10.0.2.2 is `not nameserver`. **Gates:** `nat_dns_a_g6lc_is_gateway` (dest/src 10.0.2.3, A 10.0.2.2); `outbound_get_g6lc_uses_nat_dns_not_os`. Not a recursive resolver, not QEMU. |
| **B206** | B205 / P5 | **landed (host packet peer, not QEMU)** — **DNS destination policy.** Resolved A is stored on the job; the HTTP hop must pass `nat_http_dst` (gateway only). Forcing dest `10.0.2.3` after DNS fails `origin mismatch` and does not GET. **Gates:** `nat_dns_a_g6lc_is_gateway` (`nat_http_dst`); `outbound_get_g6lc_refuses_nameserver_as_origin`; `outbound_get_g6lc_uses_nat_dns_not_os`. Not a Location redirect follow, not QEMU. |
| **B207** | B206 / P5 | **landed (host, not QEMU)** — **HTTP redirect origin policy.** Parse `Location` (conflicting values refused). `redirect_hop` is same-origin only; HTTPS→HTTP is `https downgrade`; `@` credentials stay refused. KernelNet 3xx applies the hop and fails `not followed` or the policy error — it does not GET the next URL. **Gates:** `redirect_hop_same_origin_only`; `outbound_get_redirect_origin_mismatch_is_not_followed`; `outbound_get_same_origin_redirect_is_not_followed`. Not an auto-follow, not QEMU. |
| **B208** | B207 / P5 | **landed (host packet peer, not QEMU)** — **TCP window.** `NAT_TCP_WINDOW` 8192 on encapsulate, SYN-ACK, and HTTP. Zero-window SYN is refused. Exec-model `net_enc_tcp` advertises the same. **Gates:** `nat_tcp_listen_wants_syn_then_get`. Not a sliding-window stack, not QEMU. |
| **B209** | B208 / P5 | **landed (host, not QEMU)** — **generational KernelNet jobs.** Four slots. Cancel frees a slot; reuse bumps generation; the old handle fails `stale generation`. Fifth in-flight GET is `job budget`. **Gates:** `outbound_nat_job_budget_and_stale_generation`. Not QEMU. **P5 sequential leftovers closed;** gate still needs external peers / `-netdev` / PHY. |
| **B210** | B209 / P6 | **landed (host, not QEMU)** — **do not advertise unimplemented CBC/RSA key transport.** ClientHello offers ECDHE-ECDSA/RSA AES-128-GCM only. ServerHello refuses a hello with no implemented suite. Fake-TLS framing stays non-secure. **Gates:** `tls_record_kind_handshake_and_alert` (no 0x003c in suite list); `server_hello_answers_web_client`. Not TLS 1.3, not entropy, not B54. |
| **B211** | B210 / P6 | **landed (host, not QEMU)** — **TLS random is not a hostname hash.** `Entropy` / `NoEntropy` / `FixtureEntropy`. `client_hello_with` fails closed without entropy. KernelNet HTTPS `get` without a fixture is `tls: no entropy`. ServerHello random is not `sha256(ClientHello)`. **Gates:** `tls_record_kind_handshake_and_alert` (random ≠ sha256(host)); `outbound_https_without_entropy_fails_closed`; `https_reports_the_handshake_instead_of_faking_crypto` (fixture). Not a CSPRNG, not virtio-rng, not B54. |
| **B212** | B211 / P6 | **landed (host, not QEMU)** — **HKDF-SHA256 (RFC 5869).** Extract (empty salt = HashLen zeros) and expand (L ≤ 255×32). **Gates:** `rfc5869_case_1`; `rfc5869_case_3_empty_salt`; `expand_refuses_overlong`. Not a TLS 1.3 handshake, not AEAD, not B54. |
| **B213** | B212 / P6 | **landed (host, not QEMU)** — **RFC 8446 HKDF-Expand-Label / Derive-Secret.** Prefix `tls13 `. Labels `c e traffic` / `e exp master` / `res master` / `resumption` refused. **Gates:** `rfc8448_early_secret_and_derived`. Not a handshake, not AEAD, not 0-RTT, not B54. |
| **B214** | B213 / P6 | **landed (host, not QEMU)** — **AES-128-GCM + TLS 1.3 traffic keys.** Seal/open, 12-byte nonce, 16-byte tag, fail-closed tag check. `tls13_nonce` XORs seq into the IV. `traffic_keys` is Expand-Label `key`/`iv`. **Gates:** `nist_gcm_case_1_empty`; `nist_gcm_case_2_one_block`; `rfc8448_handshake_write_traffic_keys`. `wrap_app` stays plaintext. Not a record layer, not B54. |
| **B215** | B214 / P6 | **landed (host, not QEMU)** — **TLS 1.3 AEAD record.** `seal_record`/`open_record`: inner `content \|\| type`, AAD = record header, nonce = IV⊕seq. Wrong seq fails the tag. `wrap_app` stays plaintext. **Gates:** `rfc8448_client_appdata_record`; `seal_open_round_trip_and_seq`; `wrap_app_stays_plaintext`. Not a handshake, not Finished, not B54. |
| **B216** | B215 / P6 | **landed (host, not QEMU)** — **transcript + Finished.** `HandshakeTranscript` concatenates handshake messages (4-byte header, 64 KiB cap). `finished_key` / `finished_mac` / `check_finished` (constant-time). **Gates:** `rfc8448_ch_sh_transcript_hash`; `rfc8448_finished_key_and_check`. Not (EC)DHE, not a full handshake, not B54. |
| **S3** | S2 | **landed** — `Param::HostName` intern-before-`step`; `HostDispatch` `attempt`/`invoke` on `ObjectKind::StoreFactory`/`Store`; `libwasm_global("pglite")` gated (not `is_browser_global`); shell BINDINGS only (nested `global("pglite")` is `undefined`; no real DOM `window.pglite`); native Promise path → `NotImplemented("async")`; `libwasm.pglite` D wrap (no `G6B_DUB_WASM`). |
| **S4a** | S3 | **landed** — `files::mount` runtime-reads `.tools/pglite-dist/` when `pglite.files`; missing dist omits paths and live `store_pglite_files=false`. `g6b.py pglite-dist` SHA-256-verifies the npm tarball. Guest `ui_file_paths` grows `/ui/pglite/*` only for `pglite.embed`. Embed without dist is an ELF/link error. Not Electric-in-`g6b-wasm`. |
| **S4b** | S4a | **landed** — native `kernel.ts` `BiosStore` facade → `/bios/store` (lang=ts may `await`); D lodash `attempt`/`invoke` still `NotImplemented("async")`. `createPgliteWasm({PGlite})` only with FileServe bytes + injected Electric client; never real DOM `window.pglite` / `window.pgliteWasm`. |
| **PR3c** | S1 | **landed** — `g6b.py store-embed --fixture FILE --out FILE` writes compact dump JSON; `hydrate_elf` / `elf://` seeds a deletable Memory copy when `persist.elf`; `g6b-elf` packs `__g6b_store_dump` when the file is present. `check()` does not probe. Independent of `pglite.embed`. |
| **S5** | S4 / PR3c | **landed** — USB **live** (`UsbLive` auto-flush G6BS on the key FileMgr); `persist.volume`; `stat`/`statAsync`/`GET …/stat`/`StoreStat`/`STAT` for a dialog that polls until `live && ready`; `INNER JOIN ON` hash-join; per-store `LISTEN`/`NOTIFY`; D `queryAsync` via B68 `execute!JSON` + `libwasm_await__void`; svelte-d `let rows = await pgliteQuery` + `{rows}` / `{st.ready}` (`JSON.stringify` onto an `id`); store **name in the path** (`memory://registry`, `usb://fat32/registry`, `memory://{uuid}`); compiled `Store.svelte` flattened into App `_start` (`memory://registry`, not `usb://`); `printG6bJs` keeps fetch+text (g6b-js does not depend on g6b-pglite). |
| **B124** | B123 | **landed — virgl composite verified on real GPU** — the M4 lane is now a byte-exact, hardware-rastered composite, not an exec-model claim. `virgl.rs` was rewritten field-for-field against virglrenderer 1.0.0 (`virgl_protocol.h`, `vrend_decode.c`): the execbuffer is 24 `VIRGL_CMD0`-framed commands (~960 B @640×480) — surface(VIRGL_OBJ_SURFACE→`RES_RT`), two `CREATE_OBJECT(SHADER)`, vertex-elements, sampler-view(**`RES_SCAN`**, the 2D scanout resource), sampler-state, blend/DSA/rasterizer + their `BIND_OBJECT`s, `BIND_SHADER`×2 (ccmd **31**, not 32=SET_TESS_STATE), `BIND_SAMPLER_STATES`/`SET_SAMPLER_VIEWS` on the fragment stage, `INLINE_WRITE` of the fullscreen strip verts, `SET_VERTEX_BUFFERS`, scissor/viewport/framebuffer, `CLEAR`, `DRAW_VBO`. **Shaders are TGSI *text*** (the `tgsi_dump` form — `vrend_create_shader` runs `tgsi_text_translate`; the binary-token wire was retired in 0.9.0), and `VIRGL_OBJ_SHADER_OFFSET` carries the *text byte length incl. NUL* for a new shader (`expected_token_count < pkt_length` → EINVAL otherwise). `reqtab` now `RESOURCE_CREATE_3D`s `RES_RT`(`Y_0_TOP`)+`RES_VBO` and `CTX_ATTACH_RESOURCE`s RES_RT/RES_VBO/**RES_SCAN**, so the composite samples the frame `VioPaint` committed — `VioVirgl` is scheduled **after** `VioPaint` (`analyze.rs`); the trailing `SET_SCANOUT(RES_RT)`+`RESOURCE_FLUSH(RES_RT)` presents the GPU texture. Latent protocol bugs fixed on the way: `VIRGL_FMT_B8G8R8X8` 6→2 (6 is B4G4R4A4), `VIRGL_SHADER_*` un-swapped to the pipe enum (**VERTEX=0, FRAGMENT=1** — the earlier "fix" was backwards; a FRAG shader typed VERTEX fails vrend with `gl_FragCoord`/`smooth on vertex inputs` errors), missing `num_so_outputs` dword, `RES_TEX`/`RES_VBO` referenced but never created/attached, `CREATE_3D` field order `target,format`, missing `Y_0_TOP`, unbound state objects, and the quad `v` coordinate flipped (`v=0` on clip-top — both surfaces are y0top, unflipped lands upside-down). `exec.rs` models multi-3D-resource tracking (`virgl_surf`/`virgl_dims`/`virgl_attached`), SVIEW→`vio_fb` sampling, `RES_RT` scanout/flush (`Smoke::virgl_scanout`/`virgl_flushes`/`virgl_src`), `TRANSFER_FROM_HOST_3D` requiring attached backing; `virgl_submit_composites_scanout_frame` asserts `virgl_out==virgl_fb` (a later DOM repaint rewrites `vio_fb`, so `virgl_src` snapshots the sampled surface at composite time). **Hardware proof (`out/virgl/vhw`):** `g6b virgl-dump` writes the byte-exact execbuf; a dlopen harness feeds it to the *real* `libvirglrenderer.so.1` on WSLg surfaceless EGL over the D3D12 gallium driver (Intel Arc — the paravirt EGL device, no `/dev/dri` needed): `submit→0`, `transfer_read(RES_RT)→0`, **307,200/307,200 px byte-exact** — the guest stream rasterizes verbatim on hardware. **Honest bounds:** QEMU `egl-headless,gl=on` still needs a host DRM render node (absent on WSL2) — the harness proves the stream on a real GPU; the end-to-end `virtio-gpu-gl-device` boot stays untested here. `SAMPLE`-form FS fails `vrend_convert_shader` on this backend; emitted `TEX …, 2D` is the accepted form. `g6b-asm` 88/88, `bios_regress` OK; the `g6b-elf` `picking_bios_ui` failure is pre-existing (gl:false spec — virgl unreachable). |
