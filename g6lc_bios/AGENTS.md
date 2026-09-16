# g6lc_bios — Agent Guider (package root)

> **Scope:** Independent setup firmware. The **platform is a rewrite** of
> TempleOS / ZealOS, which are **specs** under `kernel-spec/` — not a port, not
> a vendor blob, not a Cargo dependency. Hosts (`g6lc_qemu`, `build-platform`)
> may *emit* a BoardSpec JSON; they never become crate dependencies.

| Artifact | Path | Role |
|---|---|---|
| This guider | `AGENTS.md` | Invariants + current planning state |
| Expert guider | `AGENTS-EXPERTS.md` | Whole-project mental model: crate graph, Svelte→D→wasm lanes, libwasm import ABI, the three hosts, store⇄volume seam, worked pglite/btrfs/QEMU test |
| Live todo | `AGENTS-todo.md` | Stage checklist |
| Living plan | `architecture/PLAN.md` | Rewrite-from-spec, conformity gate, B0–B52; guest browser/JIT residuals |
| Licensing | `AGENTS-licensing.md` | MIT first-party; Unlicense `kernel-spec/` |
| Architecture | `architecture/` | PLAN, ZEAL, DESIGN, CODEGEN |
| Kernel spec | `kernel-spec/` | TempleOS + ZealOS reference forks (not compiled) |
| Green commands | `python tools/g6b.py check`, then `python tools/g6b.py regress` | independence + Bun tests/build + fmt + clippy + workspace tests; separate BIOS/transport regression |

## Current planning state

**Recovery foundation (2026-09-14):** `g6b-bootctl` and `g6b-runtime-abi`
are safe, allocation-free `no_std` libraries, cross-checked with Rust 1.85.0 on
`riscv64imac-unknown-none-elf`. They provide the boot-health journal/policy and
checked service-request wire boundary. Kernel/VFS journal storage requires
explicit durability; host `FileBlock` now uses `sync_all`.
**Native callee ELF + P1 poll core (same day):** `g6b-guest` is linked as a
labelled `native-service-callee-not-bootable-firmware` RV64 image and
composed as extra RX/R PT_LOADs. The BIOS `jalr`s `native_entry` with a
256-byte ABI frame: `Capabilities` (SIE masked), IRQ `Input` enqueue,
then `Poll` with SIE restored, then `BootStatus`/`BootTrial` hold.
QEMU virt prints `NATIVE-SERVICE-OK`, `NATIVE-POLL-OK`, and
`NATIVE-BOOT-HOLD`. State lives in the frame at offset 128, not a RW
callee segment. Portable `ContextTable` owns generation-checked wasm/DOM/Asyncify
records (4 slots). Guest `__prom` has a matching 4-slot suspend table
(`PromCtx`/`P_CTX`; slot 0 aliases `P_ASUSP`). Portable `Bump` hands aligned
`Span`s over caller-owned backing (not a Rust `GlobalAlloc`). After park,
`trap_timer` `NativePoll`s the durable `__native_abi` frame (`NATIVE-TICK-POLL-OK`
once). Not autoboot/TLS.
See `architecture/KERNEL-RV.md`. `g6b-boot-health` acknowledges the exact pending Linux attempt
only when watchdog `nowayout` is armed; keepalive alone is not ownership.
UART `Lnx` requires G6BH `InProgress` (`LINUX-HOLD` otherwise). QEMU
`arm-disk` + `Lnx` → `LINUX-ENTRY-OK`. Canary FDT includes
`/firmware/g6b-boot-health`; the helper discovers that window via `--dtb`
or `--dt-root`. Partition `--scan` classifies Image vs squashfs root vs
FDT, walks `/boot` on mountable filesystems, and does not jump. A file
mock of `/dev/watchdog` applies Linux nowayout/magic-close effects
without `ioctl(2)`. `LinuxEnter` arms a platform `mtime` WDT that
still fires after `sie=0` (`LINUX-WDT-FIRE`). Live OpenWrt VM remains
open. **P2 hold:** `BootStatus`/`BootTrial` stay `NotReady` without
durable journal storage; the probe clears `AUTO_ON` and prints
`NATIVE-BOOT-HOLD`. Host picker `with_decision(Stay)` will not countdown.
Firmware A/B stubs at LBA 24/32 are protected from journal I/O. `FwStage`
writes inactive B only; `FwCommit` rewrites all 8 declared sectors
(`G6FS`/`G6FE`) with flush+readback. `FwSelect` nominates B (`G6SL`) only when the whole slot is present;
a torn B is `FW-HOLD`.
**P3 UTF-8 event getters (2026-09-15):** `Object_Getter__string` maps to
`EXT_EVGETSTR`→`LwEvGetStr` and writes a D `{len,ptr}` for `type`/`key`/`code`.
`code` is KeyboardEvent.code (`Enter`/`KeyA`), never a Linux keycode.
Exec: click → `"click"`; KEY_ENTER → `"Enter"`.
**P3 capture/bubble (same day):** geometric `DomtHit` + `DomtDispatch` parent
walk. `eventPhase`/`currentTarget`/`stopPropagation` live. Exec: child click
→ parent capture phase 1 and bubble phase 3.
**P3 multiple listeners (same day):** bounded `__dom` table (64 records).
Capture and bubble on the same parent both fire (`guest_jit_two_listeners_on_parent`).
**P3 once/passive/removal (same day):** `a5` packs capture/once/passive.
`once` tombs after fire; `passive` blocks `preventDefault`;
`remove_event_listener` tombs by cb.
**P3 Optional/float getters (same day):** `LwEvGetOpt` writes
`{value:u32, defined:u8}`; `relatedTarget` is none. `LwEvGetF` returns
`clientX` as f32 bits.
**P3 double/OptionalString/Bool/Double (2026-09-15):** `LwEvGetD` is
`fcvt.d.w`; OptionalString `{len,ptr,defined}`; OptionalBool `{u8,u8}`;
OptionalDouble `{f64,defined}`. Exec: double `clientX>=200.0`; OptionalString
`type` defined `"click"`; OptionalBool `bubbles` and OptionalDouble `clientX`.
**P3 SYN_REPORT REL/wheel/hover (same day):** `TabDrain` clamp-adds REL into
`PTR_X`/`PTR_Y`, latches `PTR_MOVE`/`PTR_WHEEL`; `PTR_HOVER` inits NONE;
`DomtPtr` dispatches mouseout/mouseover/mousemove/wheel/click. Exec: REL
mousemove; first-enter mouseover; abs+wheel no BTN.
**P3 RFB/KVM normalize (same day):** `ptr.rs` `PtrNorm` scales/clips display
px to tablet ABS, coalesces moves, preserves left press/release, one owner
while held. RFB PointerEvent and `KvmPointer` inject the same virtio eventq.
Exec: RFB click; KVM wheel. Not RFB 3.8 session/auth.
**P3 modifiers/multi-button/click-to-focus (same day):** DOM `button` is
0/1/2 (not Linux `BTN_*`); `buttons` mask; `ctrlKey`/`shiftKey`/`altKey`/
`metaKey` from `PTR_MODS`. TabDrain maps left/middle/right; RFB bits 0/1/2
match. Click `DomtFocus`es the hit node. Exec: left `button==0`; RFB right
`button==2`; shift+click `shiftKey`; click focuses the button.
**P3 host-oracle mutation/lifetime (same day):** `dispatch_event` snapshots
stamps, not live child indices. Removing the target cannot retarget a
sibling. `currentTarget`/`eventPhase` clear after dispatch.
**P3 password controls (same day):** `type=password` sets `F_PASSWORD`.
Raster paints `*` per character; stored value stays plaintext. Focused
password field: KEY_A appends `'a'` unless `preventDefault`. Not a full
editor.
**P3 timeStamp/deltaMode (same day):** `__ev_obj` stores csr `time` at fill
and `DOM_DELTA_LINE` (1) for virtio `REL_WHEEL`. `timeStamp` is a double
getter; `deltaMode` is uint. Exec: click `timeStamp>0`; wheel
`deltaMode==1`.
**P3 text controls (same day):** US EV_KEY→ASCII keymap, backspace, Shift
letters, `type=text` (`F_EDITABLE`).
**P3 caret (same day):** `H_CARET` on the focused field. Left/Right/Home/End
move it; insert/backspace apply at the caret.
**P3 selection (same day):** `H_SEL` anchor. Shift+arrows extend; insert and
backspace replace the range. KQ stores per-press mods. Not IME.
**P4 try_table catch dest (same day):** guest JIT lowers `try_table` +
`catch $tag` as a `br` to the catch label. `throw_ref`/exnref stay
unsupported. Exec: throw 7 returns 7.
**P4 catch_all payload (same day):** interp `catch_all` truncates to the
try height and does not push the thrown values.
**P4 guest vsp restore (same day):** `R_EXCCLR` sets `s10` to the try
height and copies a tagged payload (`b` cells; `0` for `catch_all`).
Exec: leftover throw 99 does not replace the outer 1.
**P4 try_table catch dest vsp (same day):** local `throw` in `try_table`
emits `R_EXCCLR` at the dest frame height then `br`. `catch_all` drops
leftover body values.
**P4 cross-func throw into try_table (same day):** a single-clause
`try_table` patches post-call `R_EXCCHK` to an `R_EXCCLR`+`R_JMP` pad.
Exec: callee throw yields 777.
**P4 tagged payload across THROW (same day):** one cell is stored in
`OFF_EXCPAY` before the frame fold; cross-function catch reloads it.
Exec: callee `i32.const 7; throw` returns 7.
**P4 multi-clause try_table EXCCHK (same day):** one post-call check per
clause; `EXCCHK_CHAIN` falls through on a tagged miss. Exec: miss `$e0`
→ `catch_all` 777; hit `$e0` returns 7.
**P4 multi-cell payload (same day):** `OFF_EXCPAY` holds up to 4 cells.
Exec: callee pushes 3 then 4; catch `i32.add` returns 7.
**P4 rethrow (same day):** `rethrow 0` skips the current try; nested JMP
or escape `R_THROW` restashes payload. Exec: nested and cross-func
rethrow return 7.
**P4 rethrow into try_table (same day):** `rethrow 0` into an enclosing
`try_table` catch dest keeps payload 7.
**P4 catch_all_ref / throw_ref (same day):** `catch_all_ref` packages the
exception as an opaque exnref (handle = tag+1; payload stays in
`OFF_EXCPAY`). `throw_ref` pops it, sets `OFF_EXC`, and the following
`R_EXCCHK` routes. Null handle is `TRAP_UNREACH`.
**P4 catch_ref (same day):** dest gets tag payload then the exnref.
Tag-matched; a miss falls through to `catch_all`. Exec: throw_ref
returns 7; dest top is handle 1; miss yields 777.
**P4 continuation-owned EH (same day):** `PromCtx` spills/fills the
`__jit` EXC/EXCTAG/EXCPAY bank per slot. Host `Continuation` carries
the same cells. Exec: slot 1 does not see slot 0's EXC; switch-back
restores tag 7 and payload 99.
**P4 JitCall EH nest (same day):** the outermost user `JitCall` spills
the live EH bank and restores it on the way out so a listener cannot
clobber the caller's `EXCPAY`. Nested/control calls skip the spill.
Exec: plant tag 7 / pay 99, `JitCall` `_start`, bank restored.
**P4 await-in-try fail-closed (same day):** a direct
`libwasm_await__void` inside `try`/`try_table` is `TRAP_UNSUP` 0x700
(rewind is not a landing pad). A `try` that `call`s a function which
can reach await is the same gap. `call_indirect` inside a try is the
same gap when any funcref-table function can reach await. Exec:
coverage gaps; `install_guest` refuses. Shipped cell stays clean.
**P4 interp await-in-try fail-closed (same day):** a direct
`libwasm_await__void` while a `try`/`try_table` is live is rejected
(rewind is not a landing pad). Fork WAT still decodes. Await outside
try still rewinds.
**P4 interp callee-await (same day):** `try { call $awaiter }` is
rejected when `$awaiter` can reach await via direct `call`. **P4
sequential leftovers are closed.** IME and RFB 3.8 stay with later
phases.
**P5 binary-safe HTTP/1 response parse (same day):**
`parse_http1_response` copies the body as bytes, honors
`Content-Length`, and rejects conflicting framing (`Content-Length`
plus `Transfer-Encoding`, or disagreeing lengths).
**P5 chunked HTTP/1 decode (same day):** `Transfer-Encoding: chunked`
(alone) is decoded; trailers are discarded; `gzip, chunked` is refused.
**P5 partial HTTP/1 I/O (same day):** `parse_http1_response_partial`
returns `NeedMore` for a framed prefix, `NeedEof` for close-delimited,
and `Done` when complete. KernelNet finishes `Content-Length`/chunked
on `Done`, not idle.
**P5 TCP EOF vs WouldBlock (same day):** `tcp_recv_bytes` returns
`TcpRecv::{Data,WouldBlock,Eof}`. Close-delimited bodies complete on
peer EOF, not idle `CLOSE_GRACE`.
**P5 virtio-net feature negotiation (same day):** guest `VioNetProbe`
accepts word0 `CSUM|MAC|STATUS` and word1 `VERSION_1`, then
`FEATURES_OK` readback (`VIRTIO-NET-OK` / `VIRTIO-NET-HOLD`).
**P5 virtio-net RX/TX queues (same day):** receiveq 0 and transmitq 1
at `__vio+0x1000`, then `DRIVER_OK`.
**P5 virtio-net loopback packet (same day):** RX/TX DMA (`VIRTIO-NET-PKT`).
**P5 Ethernet/ARP + IPv4 ICMP (same day):** ARP who-has 10.0.2.2 and ICMP
echo on the exec-model gateway (`VIRTIO-NET-ARP`, `VIRTIO-NET-ICMP`).
**P5 TCP SYN/SYN-ACK (same day):** guest SYN to 10.0.2.2:80, gateway
SYN-ACK (`VIRTIO-NET-TCP`).
**P5 TCP ACK (same day):** guest ACK seq=2 ack=1001; gateway ACK
(`VIRTIO-NET-ACK`).
**P5 TCP HTTP GET (same day):** PSH+ACK `GET /fw.bin` → 200 with binary
`00 ff fe 80` (`VIRTIO-NET-HTTP`).
**P5 TCP FIN (same day):** guest FIN+ACK seq=42; gateway FIN+ACK
(`VIRTIO-NET-FIN`).
**P5 UDP echo (same day):** UDP to 10.0.2.2:7, payload `00 ff fe 80`
echoed (`VIRTIO-NET-UDP`).
**P5 DNS A (same day):** query `g6lc` to :53 → A 10.0.2.2
(`VIRTIO-NET-DNS`).
**P5 DHCP (same day):** DISCOVER/OFFER/REQUEST/ACK, yiaddr 10.0.2.15
(`VIRTIO-NET-DHCP`). Packet buffers 320 B.
**P5 TCP RST (same day):** SYN to :9 (closed) → RST+ACK (`VIRTIO-NET-RST`).
**P5 TCP retransmit (same day):** first SYN to :81 is dropped; retry
gets SYN-ACK (`VIRTIO-NET-REXMIT`).
**P5 KernelNet NAT packets (same day):** `GET http://10.0.2.2/fw.bin`
uses in-memory Ethernet/IPv4/TCP (`nat_http_on_wire`), not `std::net`.
**P5 TCP reassembly (same day):** `NatHttpReasm` joins out-of-order GET
segments by seq, then the same 200 body.
**P5 NAT TCP listen (same day):** `NatTcp::listen` SYN→SYN-ACK, ACK,
then GET. `nat_http_on_wire` completes that handshake first.
**P5 virtio-shaped DMA (same day):** `VirtioNetDma` posts TX/RX with
avail/used idx; KernelNet `10.0.2.2` GET pumps that path.
**P5 virtio desc/avail/used (same day):** rings use 16-byte desc,
DEVICE_WRITE on RX, used `{id,len}` at `NET_*` offsets.
**P5 KernelNet on exec guest rings (same day):**
`GuestVirtioNet::http_get` programs exec-model `NET_*` rings and KernelNet
`10.0.2.2` uses that.
**P5 kstart `__vio` second GET (same day):** `GuestVirtioNet::from_kstart`
keeps RAM/CSR after `VioNetProbe` and `fetch` posts another GET on those
rings.
**P5 KernelNet from_kstart (same day):** `http://10.0.2.2` GET on a
`virtio_net` board runs kstart then `fetch` on live `__vio`.
**P5 ICMP MTU (same day):** IPv4 DF + totlen > MTU → dest-unreach
frag-needed (type 3 code 4). `NAT_MTU` 1500. Not QEMU, not a PHY.
**P5 IP reassembly (same day):** `IpReasm` joins out-of-order IPv4
fragments of a GET (MF/offset; DF refuses fragment). Gateway rejects
a lone first fragment. Not a reassembly timeout, not QEMU, not a PHY.
**P5 KernelNet cancel/watchdog (same day):** `get` only arms a
`10.0.2.2` job; each `poll` takes watchdog then one SYN/ACK/GET step.
Cancel drops the rings before GET; a neighbour job is not cancelled.
Not QEMU, not a PHY.
**P5 link-loss (same day):** cable unplug marks the NIC down. An
in-flight GET fails `link down` on the next poll (before SYN/GET/recv)
and drops rings/socket. Not a stall wait, not QEMU, not a PHY.
**P5 connect/DNS (same day):** socket `get` only arms; each `poll`
tries one IPv4-literal connect (1 ms cap). IPv6 and hostnames are
named refuses until an async DNS job. Not OS `getaddrinfo` in `get`,
not QEMU, not a PHY.
**P5 NAT DNS job (same day):** `g6lc` A query on in-memory UDP :53
→ 10.0.2.2, then the same NAT GET. `g6lc.invalid` still fails closed.
Not OS DNS, not recursive, not QEMU, not a PHY.
**P5 NAT nameserver (same day):** DNS queries go to `10.0.2.3`
(`NAT_DNS`), not the HTTP gateway. A is still `10.0.2.2`. A query
to :53 on 10.0.2.2 is `not nameserver`. Not QEMU, not a PHY.
**P5 DNS destination (same day):** the HTTP hop must use the resolved
A (`nat_http_dst`). The nameserver is not an origin. Not a redirect
follow, not QEMU, not a PHY.
**P5 redirect origin (same day):** 3xx `Location` is parsed.
`redirect_hop` allows same-origin only and refuses HTTPS downgrade
and credentials. KernelNet does not follow; it fails named.
Not QEMU, not a PHY.
**P5 TCP window (same day):** `NAT_TCP_WINDOW` 8192 on encapsulate,
SYN-ACK, and HTTP. Zero-window SYN is refused. Not QEMU.
**P5 generational jobs (same day):** four KernelNet slots; cancel
then reuse is a new generation; the old handle is `stale generation`.
Not QEMU, not a PHY.
**P5 sequential leftovers are closed.** The P5 gate still needs
external isolated peers, QEMU `-netdev`, and a PHY.
**P6 suite advertisement (same day):** ClientHello offers ECDHE-GCM
only; CBC/RSA key transport is not advertised. Framing is still
non-secure. Not a TLS 1.3 record layer, not B54.
**P6 entropy (same day):** ClientHello/ServerHello random comes from
an explicit `Entropy` fill. `NoEntropy` fails closed. Hostname and
handshake hashes are not used. KernelNet HTTPS needs a fixture or
it fails `tls: no entropy`. Not a CSPRNG, not virtio-rng, not B54.
**P6 HKDF (same day):** HKDF-SHA256 extract/expand (RFC 5869). Not a
handshake, not AEAD, not B54.
**P6 Expand-Label (same day):** RFC 8446 `HKDF-Expand-Label` /
`Derive-Secret`. 0-RTT and resumption labels refused. RFC 8448
early-secret + `derived`. Not a handshake, not AEAD, not B54.
**P6 AES-GCM (same day):** AES-128-GCM seal/open (12-byte nonce,
16-byte tag). TLS 1.3 `key`/`iv` from a traffic secret. `wrap_app`
stays plaintext. Not a record layer, not B54.
**P6 record (same day):** TLS 1.3 AEAD record `seal_record` /
`open_record` (inner type, seq nonce, header AAD). `wrap_app` is
still plaintext. Not a handshake, not B54.
**P6 transcript/Finished (same day):** handshake transcript hash
and Finished HMAC (`finished` key). RFC 8448 ClientHello+ServerHello
hash and server Finished key. Not (EC)DHE, not B54.

**Local plan review (2026-09-14):** `gr`/`display-proxy` produce legacy blue
text-plane diagnostics, not web screenshots. Their host font now covers
printable ASCII and is pixel-checked against the guest 8×8 font; repaint clears
old cells. `RENDER-VALIDATION.md` documents the new zero-RGB-tolerance gate for
every packed menu at 640×480 and 1920×1080 after guest `DlPaint`→`VioPaint`,
plus a completed-frame picker/JIT integration test. `jcode::install_guest`
enforces reachable-op coverage before installation; `JitCall` fixes positional
arguments, bounds entry/arity, and can resume and suspend again. Rewound awaits
refresh the settled value instead of returning the empty suspension-time span.
The runtime still has one suspended continuation and a bounded event/EH subset
(`architecture/WASM.md`, Guest-JIT correctness review). The larger whole-boot
test uses an explicit ≤192M instruction budget; default smoke remains 48M.
Remote g6q and QEMU-GL evidence are ongoing/deferred to the other session.

**B0–B52 plus B55–B59 host lanes landed within the stated host/guest boundaries.** Profiles `embedded`/`router` → `full` compile UART+SPI flash
up to browser-UI HTTPS and USB settings. USB FAT32 flash is always compiled;
the USB-key file manager (FAT32/NTFS/ext4) is extra. 64-bit SMT2 / multi-issue /
stream / OoO / hypervisor / RVV specs infer setup menus. HolyC kernel file
server emits generated HTML/JS/WASM over HTTP or HTTPS. HolyC-UI and browser-UI
share the menu tree. JS `fetch` and HolyC share one router. SvelteKit refused.
The OpenSBI ELF `jal`s `TimerInit` (SBI TIME + `rdtime`) before park and takes
supervisor timer irq 5 with the scause interrupt bit. Every hart sets `sp` and
`stvec` before the park split; stacks sit in BSS after the image. Display-proxy
geom is payload words; QEMU virt uses `-smp` + `virtio-gpu-device`
(`virtio-gpu-gl-device` under `proxy.gl`, `--no-gl` fallback, `--vnc`
frontend; never `-netdev`).
**B93 `g6b-hw` (landed):** post-boot lazy `HwSession`, interned as
`platform.hw` (not `window.hw`, not iframes). Isolated NAT / TCP+UDP /
named host NIC. Display stays **VGA** until an internal probe (PCIe
linear-fb → HDMI G6DS → virtio-gpu) is announced (`HW-DISP-SEL`). HTTP(S)
fetch is a **kernel** path (`HttpGet`/`HttpsGet` / `kernel_fetch` / iframe
outbound): `g6b-http` plans the URL, `g6b-tls` writes ClientHello, sockets
are hw TCP (`via=hw-tcp`). HTTPS is not in `g6b-hw`. Pointer HID and
USB-key listings live in `g6b-hw`. **`g6b-zealcli`:** VGA
ZealOS CLI (`kernel.cli.boot=auto` until GPU, then `LoadUI` → browser-ui).
Docs: `architecture/g6b-hw.md`, `architecture/g6b-zealcli.md`.
**B94–B95 (landed):** the CLI is the *minimally dependent face* — a
`kernel.cli.{rows,cols,scrollback}` container with the prompt on the bottom
row, Linux-keycode input (USB HID first, then virtio-keyboard, then UART),
optional `kernel.cli.mouse`, read-only `vi`, ZealOS drives, a generated
`man`, a settings overlay that exports a BoardSpec patch (only
`g6b_spec::menu::WRITABLE` rows), an edk2/u-boot selector with probed
presence, and a **poll-driven** firmware update (HTTPS or USB key, no worker
thread; the HTTPS record layer stays B54 and says so). Capabilities arrive as
`VolumePort`/`NetPort`/`FlashPort` from `g6b-kernel::zealcli`, so the crate
still takes only `g6b-spec` + `g6b-holyc`. The web engine is **one bundle**:
`kernel.web.enable` gates wasm+js+dom+render+css together, `profile=barebone`
excludes all of it (kernel + HolyC band + hw NIC + USB key remain), and
`cli.boot=ui` is refused while the bundle is compiled because the CLI boots
first (`CliBoot()` before `UiBoot()`, `ZEALCLI-READY` before `UI-BOOT`). The
guest paints the container itself through `dom::attach_text_face` + `CliInit`
(`KSTART-CLI`, `ZEALCLI-PAINT n`).
**B96 (landed):** that container is **interactive in the ELF**. `g6b-asm::cli`
carries `CliKey` (own `CLI_SEEN` watermark over `INP_KQ`: printable append,
backspace, Enter), `CliEnter` (bounded verb table — `clear`/`reboot`/`shutdown`
plus one per packed page; a miss is `CLI-CMD?`, never a guess), `CliSync` and a
keymap pinned to `g6b_zealcli::input` by a dev-dep test. The edit line is
`__uart_line + CLI_LINE_OFF` with the bottom row pointing at it, so a keystroke
changes the next frame; keys never paint in IRQ context (`CLI_DIRTY` + the timer
tick), while a serial line no builtin claims dispatches and paints in the trap
like `Ui`. Pages are **host-rendered** (`CLI:<name>| …` in the boot log: `help`,
`menu`, one per setup screen) — build-time text plus a live line, which is what a
guest with no interpreter can honestly offer. `wants_virtio_input` follows the
text face rather than wasm; `wants_virtio_tablet` keeps the pointer opt-in.
Three real guest bugs surfaced and were fixed with regression tests: `sp`
pointed at the **bottom** of a hart's stack slot (single-hart images pushed into
the `.rodata` `__font` tail), the mirrored font pairs `( ) [ ] { } < > / \` were
reversed (`/>` printed `\<`), and `DomPaint` never erased (a shorter row or page
left the previous text on screen). QEMU-verified on
`fixtures/g6lc64-zealcli.json` (640×480 container, no `UI-BOOT`/`WASM` in the
image; `help` on serial → `CLI-PAGE help`; `sendkey m e n u` → `/>MENU` on the
prompt row; `ret` → `CLI-PAGE menu`) and `fixtures/g6lc64-web-hd.json` (CLI
first, then browser-UI at 1920×1080) via `tools/qemu_zealcli.sh`.
**B97 (landed):** `autoboot` — the countdown boot picker, and the power-on face
where it is compiled (`kernel.cli.autoboot.{enable,timeout_ms=2000,order,bios_ui}`,
orders `live-first`/`os-first`/`payload-first`, writable from setup). Every row
names its evidence (`g6b-zealcli::detect`: RISC-V `Image` header, ISO 9660 PVD +
El Torito, `casper/vmlinuz`, `openwrt-*.manifest`, `BOOTRISCV64.EFI`, `bootmgr`);
anything unrecognized stays `unknown` and a device with no reported vendor shows
a blank, because a boot menu gets acted on. Arrows **wrap**, `1`-`9` picks, Enter
boots, Esc stays in setup, and the countdown takes **entry 0** — the unattended
path — while any navigation stops the clock. The list is discovered on the host
(`--volume ID=PATH[:role[:vendor]]` → `DirVolumes`) and packed (`CLI-AB-*`), since
the payload has no block reader; the guest half (`AutoDraw`/`AutoKey`/`AutoTick`/
`AutoPick`) is live and counts real timer ticks. QEMU, against media built from
the real OpenWrt artifacts (`tools/mkmedia.sh`, `tools/qemu_openwrt_chain.sh`): a
genuine xorriso install ISO lists as `> 1. G6LC-OPENWRT-INST [INSTALLER] QEMU
DVD-ROM`, the OpenWrt key as `OpenWrt … (1~d9340319c6) [firmware]`, the countdown
runs `20s→19s→18s`, `down/up/up` moves the marker `1→2→1→4` (wraparound), and the
picked image boots to `Linux 6.6.93 … r28739-d9340319c6` → `procd: - init -`.
**B99 (landed):** new crate **`g6b-vfs`** — real block devices, partition tables
and filesystems behind one mount table, shared by the shell, HolyC and the browser
UI (`architecture/g6b-vfs.md`). GPT (both CRC32s checked) + MBR + whole-disk
fallback; the *superblock* decides the filesystem, never the table's claim, and
every answer carries its evidence. **FAT32 read/write** including VFAT long-name
creation (`\EFI\BOOT\BOOTRISCV64.EFI` has an 11-character basename, so 8.3-only
could not repair an ESP), with both FAT copies and the FSInfo count kept in step.
**ext2/3/4 read** (extents and classic indirect) plus a narrow in-place write —
existing regular file, fits its allocated blocks, clean superblock — with the
**crc32c inode checksum** (`metadata_csum`), which is what `e2fsck` caught on the
first attempt. **NTFS read-only** (`$MFT` + fixups + run lists). The shell gets
`drives`/`mount [-w]`/`umount` and `cd`/`ls`/`cat`/`write`/`rm`/`mkdir` over
`/mnt/<name>`, `<name>:/path` or relative paths, auto read-only mount on access,
and `mount` refusing to guess between candidates; `vi` is a real editor where the
file is writable (`i a o x dd`, `:w`, `:wq`) and the read-only viewer elsewhere
*with the reason*. OS detection reads the volume. HolyC gains `Mount`/`Drives`/
`VfsLs`/`VfsCat`/`VfsWrite`/`OsDetect`, and the browser UI gets the same answers as
JSON. **Verified against the distro's own tools** (`tools/mkfs_fixtures.sh`):
`mkfs.vfat`/`mkfs.ext4`/`sfdisk` images read *and written*, `e2fsck -fn` clean,
`debugfs`/`mtools` reading our writes, `fsck.vfat` clean.
**B100 (landed):** the three carried-over guest hazards, closed with QEMU
evidence. **The virtio-blk keystroke bug was real starvation**, not a QEMU quirk: a
virtio-mmio interrupt is *level-triggered*, so completing the PLIC claim does not
lower the device's line — a `virtio-blk-device` this BIOS has no driver for
re-asserted forever and the hart never left `trap_sei`. `trap_vio_ack` now reads
`InterruptStatus` and writes `InterruptACK` on the base derived from the claimed
irq, for any unhandled source inside the virtio window (two range guards keep it
off non-virtio addresses). The new `VIRTIO-INPUT-OK slot=N irq=M` marker made the
diagnosis one line: the guest's own view was already right (`slot=6 irq=7`) with
one drive or two, so the fault was the bus. With both drives attached the marker
now moves `> 1.` → `> 2.` → `> 1.` and Enter picks. **`DomPaint` is guarded**
against the `s0..s5` tear with `PAINT_BUSY` at `__uart_line+296` — in the uart-line
block because *that block always exists*; the first attempt used `__vio` and a
board with no virtio device wrote past an absent block (the mbox `GET` test caught
it). **The picker pages** (`-- 1-6 of 10 (up/down scrolls) --`, wraparound intact).
The **EDK2/U-Boot selector reads real volumes** (mount read-only, ESPs first, offer
only what was read, name the source; U-Boot is recognized by
`extlinux.conf`/`boot.scr` as well as `u-boot.itb`), and FAT32 create records carry
the FAT epoch rather than a zero date.
**B101 (landed):** the **guest reads its own sectors** — a real virtio-blk driver in
the payload (`BlkInit`/`BlkRead`/`BlkWrite`/`BlkFlush`/`JrnLoad`/`JrnCommit`/`BlkSig`, gated by `wants_virtio_blk()` =
`uncore.storage` + a CLI/picker + the virtio transport). The requestq uses the
three-descriptor chain the spec mandates, and **the status byte decides success, not
the used ring** — a device can complete a request and report `IOERR`, and a
ring-only reader would parse the previous sector as the one it asked for. `BlkSig`
names the medium from its own bytes (`gpt` on `"EFI PART"` at LBA 1, else `mbr`,
else `raw`), because the protective `0xEE` type byte is a claim. QEMU with real
images: `VIRTIO-BLK 5` → `VIRTIO-BLK-OK` → `BLK-SIG gpt` on a real `sfdisk` disk and
`BLK-SIG mbr` on a real `mkfs.vfat` superfloppy, same ELF. Hardware found two bugs
the model had not: the used-ring poll compared against zero rather than the shadow
index (so the *second* read returned before the device answered), and the 0x1000
slot stride does not fit an `addi` immediate.
**B102 (landed):** deeper `vi` ↔ filesystem coupling, and the **sparse-file bug** it
uncovered. `blocks_of` dropped `ee_block`, so a file with a hole came back
*rearranged* (later blocks pulled into the gap) — worse than missing, because it
looks like data. The map is now logical→physical, holes read as zeros at their own
offset, uninitialized extents stay unmapped, and an in-place write past the
contiguous prefix is refused with the mapping. Checked against a file the **Linux
kernel** made sparse: byte-exact with Linux (`TAIL` at 12288, not 4096), `e2fsck`
still clean. New `EditBudget`/`EditTerms`: each driver states its write terms *before*
an edit (`fat32 rw`, `ext4 rw <=4096B in place`, `ntfs ro` naming `$LogFile`), `vi`
shows them, `:w` refuses with numbers while the buffer is still open, and every save
is **read back and compared**. CRLF, a UTF-8 BOM and a missing final newline are
preserved, because a BIOS edits files other systems wrote; a file over 256 KiB opens
read-only rather than risk truncating it.
Still open: the guest can read **sectors** but not **files** — locating
`/boot/Image` needs a filesystem in the payload (`g6b-vfs` is host Rust, not ASM
IR), so `AUTOBOOT-HANDOFF` remains staged and the picker's entries still come from
host-supplied media; ext4 allocation/journal (create and grow) and NTFS write;
attaching extra `virtio-blk-device`s stops keystrokes reaching the guest even
though GPU+keyboard probe `OK`; and `s0..s5` are outside the trap frame while
`DomPaint` uses them, so a tick landing inside a normal-context paint can tear a
frame.
**B104 (landed):** the store persists through a **real volume**, and a libwasm
`_start` drives it. `g6b_pglite::StoreVolume` is the seam: the kernel implements
it over `SharedVfs` — the *same* mount table the shell's `mount`/`cat` use — so a
dump the browser UI writes is the file the shell reads, and `attach_volume` swaps
the registry's in-memory `usb` map for the medium. `export` writes **JSON text**
to the volume (a pulled key must be readable by the OS it is plugged into;
`codec::unpack` accepts raw JSON on the way back), checks the *medium* — not the
cache — for a uuid collision before overwriting, and `import` reads the medium
first. `resolve_store_mount` maps the spec's filesystem-kind name (`fat32`/`ntfs`/
`ext4`) to the one mounted instance, refusing when two candidates exist. The UI
write side is `fetch_post`: `KernelPort::fetch_post` gated to `/bios/store` only
(the power/flash endpoints are not the UI's), `KernelHost::fetch_post` logs
`WASM-POST`/`WASM-SKIP-POST` and interns the response, and `Window.fetch_post` —
plus `fetch`, which had the same latent wrap — returns the interned *value* so the
`__Handle` dispatch boxes the response string itself (a guest holding
`I32(handle)` could never `libwasm_get__string` it, which the interpreter also
grew: `(raw, handle)` sret readback, JS-kernel parity). Tests
(`crates/g6b-kernel/src/vfs.rs`): a router-level create/insert/query → export →
fresh-registry import round-trip on a real FAT32 image; the `fetch_post` gate
refusing every non-store path; and a hand-assembled `_start` running the actual
import chain — `libwasm_global("window")` → `Object_Call_string_string__Handle`
→ `libwasm_get__string` → `set_inner_text` — onto the key. QEMU: a writable
`DISK=` on `tools/qemu_web_autoboot.sh`, `real-fat32.img` attached; the picker
offers `[payload, bios-ui]` (a non-bootable key adds no row), digit `2` picks
`bios-ui` → `AUTOBOOT-UI`, 36,212 lit pixels at 1920×1080.
**B105 (landed):** **btrfs** in `g6b-vfs` — read plus the three leaf-level
writes a BIOS may honestly perform. Superblock csum-verified, chunk map from
`sys_chunk_array` + chunk tree, root tree → FS tree + csum tree; every node is
checked (`bytenr` == the address asked, `crc32c(0, node[32..])` holds) so a
corrupt tree is reported, never parsed. Writes: in-place inside existing
extents **with the csum tree refreshed per written sector**, inline-extent
replace in the leaf (how repeated `store.json` flushes land on one path), and
create/mkdir via item insert bounded by `max_inline` and the leaf's measured
free space. Refused and named: extent allocation/backrefs, `remove`,
multi-device/RAID and zoned/extent-tree-v2/stripe-tree/metadata-uuid volumes.
`kernel.usb.fs_btrfs` compiles it; `kernel.store.persist.volume` accepts
`btrfs`; `a_store_round_trips_through_btrfs` runs the pglite export → medium →
fresh-import round trip on it. `mkfs.btrfs`/`btrfs check` are not on this host
— the fixture is hand-laid to the on-disk spec and the distro-tool check is the
named residual.
`g6b smoke` runs the S-mode payload on the host (SBI putchar/TIME + UART0 THR)
until park. Hart 0 `wfi` takes irq 5 once (IRQ_TIMER). Secondary harts WFI after
`satp`/`sp`/`stvec` with no tick. Unexpected traps print `TRAP-<scause>-<sepc>`
and park (INT_FAULT), not an `sret` loop. `uncore.plic` runs `PlicInit` (S-mode
ctx1) — sets a nonzero priority for every enabled source (QEMU resets
priorities to 0) and trap irq 9 claim/complete: UART irq 10 (QEMU virt
ns16550; `trap_uart` RX), virtio-mmio irqs 1..=8 (slot i → irq 1+i,
`trap_vio` ISR read/ack + `__vio` irq counter — QEMU-verified), and mbox
irq 3. `harts>1` runs `HartStart` (SBI HSM + IPI); trap irq 1 (SSI) `sret`s.
`loopback.enable` runs `MboxInit` (`G6MB` + irq_en at `0x10100000`); trap irq 3
services doorbell kicks (`View` → ST_RSP, `Reboot` → SBI SRST). Dual-band UART1
sets `IER.ERBFI` and waits with `WFI` (not a busy poll, never a netdev). UART
RX appends `__uart_line`; a newline matches `View`/`Reboot`/`Shutdown`/`Wakeup`
(4-char prefix or first letter). `ViewSection("name")` prints `VIEW name`.
`GrInit` writes a `GR16` header at `__gr_plane` (after stacks), a 4bpp 640×480
plane with a boot scanline, and an 8×8 `G6LC` blit; QEMU still uses
`virtio-gpu-device` (never `-netdev`; `proxy.gl` selects
`virtio-gpu-gl-device` + `egl-headless,gl=on`). `ProxyScale` runs when
`kernel.proxy.gl`.
`UiInit` publishes a `G6UI` header at `__ui_blob`; the ELF carries the UI
wasm (LDC libwasm cell when live) in `.rodata`. UART/mbox `Ui` prints `UI`.
`FileServe` echoes `\0asm` and prints `/ui/` paths; UART/mbox `File` lists
them. `GetFile` is GET `/ui/ui.wasm` (mailbox RSP `\0asm`+size; not a
netdev). Host FileServe may add `/ui/pglite/*` when `kernel.store.pglite.files`
and dist bytes are live; guest listing does so only for `pglite.embed`. Native
`kernel.ts` `pglite` is a `/bios/store` facade (shell BINDINGS only); optional
Electric `createPgliteWasm` is not assigned on the real DOM. Host `BrowserSession` runs that LDC cell and does **not** fall back
to the MVP encoder wasm. `WasmJit` is the numeric `i32.add` worker leaf when
`kernel.wasm.jit`; `WasmUi` then runs `WasmStart` (MVP straight-line `_start`
imports) against `__ui_dom` and `DomPaint` (8×8 glyphs) — a VGA/UART text
face, not the web engine. GPU-class scanout must present `BrowserSession`
Canvas32 (B90: host blit of dirty tiles into modelled `__scan_fb`; B91:
guest `VioPaint` TRANSFERs `__ui_cap` tiles when WEB_PRESENT, else
full-frame `FbExpandSel`).
UART `Ui` re-dumps the
live DOM via `DomPaint`. `VioProbe` (`Purpose::Virtio`, live when
`wants_virtio_gpu`) scans QEMU-virt virtio-mmio slots `0x10001000+0x1000*i`
(all 8 transports exist at a 0x1000 stride; `-device` attaches to the last
free bus) for DeviceID 16 and prints `VIRTIO-GPU <slot>`/`VIRTIO-GPU-NONE`;
`VioInit` then performs the virtio 1.x handshake (reset → ACK|DRIVER →
FEATURES_OK readback → DRIVER_OK), sets up controlq rings in `__vio` BSS,
completes one `GET_DISPLAY_INFO` descriptor round-trip (`VIRTIO-INFO`), and
`VioScan` drives the pixel sequence (`RESOURCE_CREATE_2D` →
`RESOURCE_ATTACH_BACKING` → `SET_SCANOUT` → band fill →
`TRANSFER_TO_HOST_2D` → `RESOURCE_FLUSH` → `VIRTIO-SCAN`) — the resource and
rects are the **`__disp`-latched output mode** (`DispSel` runs first; the
proxy default is the common case), and
`FbExpand`/`FbExpand1`/`DomPaint32` fill the X8R8G8B8
`__scan_fb` with the `Proxy::to_ppm` semantics (`fit`/`dpi` = uniform
scale, centered letterbox; `fill` = per-axis stretch) computed from `__disp`
w/h/stride at runtime — then `VioPaint` (virtio class only)
TRANSFER+FLUSHes the full frame (`VIRTIO-PAINT`) after `WasmUi`/`DomPaint`
and on the UART `Ui` re-dump, and `DispPaint` (uncore class only) commits
the same surface to the display engine. **Verified on QEMU 8.2 + OpenSBI 1.5** via
`fixtures/g6lc64-qemu.json`: QMP `screendump` is 1920×1080 with the 640×480
DOM/Gr plane ×2 centered at (320,60) — matching the host-modelled
framebuffer and the `display-proxy` PPM geometry exactly. A `display`-class
peripheral (`fixtures/g6lc64-hdmi.json`) selects the native uncore scanout:
`DispPaint` commits `__scan_fb` to the engine contract
(`architecture/uncore/hdmi-display.md`) plus a `G6FB` descriptor — the
`simple-framebuffer`-shaped BIOS→Linux handoff — and `wants_virtio_gpu`
yields to it. `qemu-args` emits `virtio-gpu-gl-device` + `egl-headless,gl=on`
under `proxy.gl` (needs a host DRM render node `/dev/dri/renderD*` —
surfaceless EGL is not software GL; `--no-gl` → 2D fallback)
and `--vnc N` exports the console for BIOS+Linux alike. On that `proxy.gl`
board `VioInit` also accepts `VIRTIO_GPU_F_VIRGL` in the word-0 driver
features, and **`VioVirgl`** — scheduled **after `VioPaint`** so the
committed `__scan_fb` frame is resident — runs the guest virgl composite
over the ctrlq: `GET_CAPSET_INFO`/`GET_CAPSET` → `CTX_CREATE`(ctx 1) →
`RESOURCE_CREATE_3D`(`RES_RT` offscreen RT `Y_0_TOP`, `RES_VBO`) →
`CTX_ATTACH_RESOURCE`(RES_RT, RES_VBO, **RES_SCAN** — the 2D scanout
resource becomes the sampled texture) → `SUBMIT_3D` carrying the
`__virgl_cmd` execbuffer → `SET_SCANOUT(RES_RT)` → `RESOURCE_FLUSH(RES_RT)`.
The execbuffer (24 `VIRGL_CMD0` commands, ~960 B, byte-exact against
virglrenderer 1.0.0 `virgl_protocol.h`/`vrend_decode.c`,
`crates/g6b-asm/src/virgl.rs`) builds and binds the full object/state set
and draws a fullscreen textured quad sampling `RES_SCAN` into `RES_RT` —
the display shows a GPU raster, not a guest copy. Shaders travel as **TGSI
text** (`tgsi_dump` form; the binary-token wire was retired in
virglrenderer 0.9.0) with `VIRGL_OBJ_SHADER_OFFSET` carrying the text byte
length incl. NUL. `SUBMIT_3D` is a three-descriptor chain (32-byte
`cmd_submit` OUT + execbuffer OUT + resp WRITE) — `vio_exec_chain` gathers
all OUT descriptors before dispatch; commands are gated on `virgl_live`
(`vio_gl` *and* the negotiated `F_VIRGL` bit, not mere device capability).
After the `__virgl_req` loop, `VioVirgl` `sw`-builds
`RESOURCE_ATTACH_BACKING`(`RES_RT`→`__virgl_out` BSS) + `TRANSFER_FROM_HOST_3D`
to pull the rendered quad back into guest RAM (`entries[0].addr` needs the
resolved `La VirglOut` BSS address, so it can't ride the static reqtab);
`Smoke::virgl_out` is the guest-RAM snapshot, `virgl_scanout`/`virgl_flushes`
record the RES_RT present. Exec-model tests
(`virgl_submit`/`_exec`/`_kill`/`_backing`) are the gate, and the stream is
**externally verified**: `g6b virgl-dump` + the opt-in
`tools/bios_regress.py --virgl-reference DIR` replay the request table through
`libvirglrenderer.so.1`, including matching Y_0_TOP resource flags and fences.
Both llvmpipe and explicit D3D12 Intel Arc produce **307,200/307,200 px byte-exact**;
reports identify the selected renderer. This supersedes the old `out/virgl/vhw`
source-orientation assumption; see `architecture/DISPLAY.md` P0. It is not an
unchanged-Linux-driver or RTL proof. QEMU needs
`-global virtio-mmio.force-legacy=false` (the default legacy v1 transport
ignores the v2 queue registers — `qemu-args` emits it) and the used-ring
poll is `1<<22` (QueueNotify is iothread-async) — with SEIE armed the
`VioInit`/`VioCmd` waits `wfi` on the used-buffer irq instead of pure spin
(bounded by the same budget plus the periodic timer). `InpInit` probes the
slots for DeviceID 18 (`virtio-keyboard-device` then
`virtio-tablet-device` under `wants_virtio_input()`; guest takes the
first slot for VGA `INP_KQ`, `TabInit` the second), posts 8 `virtio_input_event` buffers on the
eventq, and `trap_inp`→`InpDrain` pushes each `EV_KEY` into the bounded
`INP_KQ` queue (`INP` marker, buffer re-posted); UART `Keys`/`K` and the
mailbox `K` doorbell dump it via `InpPoll` (`KEY <8-hex>`; mbox answers
`RSP="KEYS"`), and `DomKey`/`DomNav` (`kernel.wasm.jit`) mirror the queue
into the DOM: `inp.last` = the newest key (`DOM| key <hex>`), `nav.sel` =
menu navigation (arrows move `sel` over `spec.menus()`, Enter opens →
`NAV <name>` serial + `open <name>` row; `NAV_SEEN` watermark scan — the
physical ring stays for the `Keys` dump). UART `Await`/`A` (jit-gated)
claims a bounded await slot (`__ui_dom` header +16, `AWAIT_SLOTS`=4 u32s —
idle/pending/resolved/rejected, `npend` count at +12) → `AWAIT pending N`
+ `await.N` row = `"pending menu"`; all four pending → `AWAIT-REJ full`
(fail closed); a resolved slot is reusable. `Throw`/`T` rejects the newest
pending slot (`AWAIT-THROW /bios/menu` → `await.N` = `"rejected menu"`) —
the thrown rejection, caught and visible in the DOM. The slot logic lives
in `WasmAwait`/`WasmThrow`/`WasmCatch` (the UART commands are thin `jal`s)
— and lowered wasm can drive the same queue: `env.await()->i32` returns
the claimed slot (-1 when full), `env.throw(i32)` rejects that slot
(-1 → newest), and `env.catch(i32)->i32` returns 1 iff the slot is
rejected, all `import_stub` entries — the shipped `bios-ui.wasm` does
exactly that for `await` (`await fetchBios("/bios/menu")` in `App.svelte`
→ `call env.await` at `_start`, resolved by the next timer tick;
QEMU-verified). `start_ops` lowers i32 locals, `drop` and single-i32
call results through a bounded s2..s5 pool. `DomAwait` resolves one slot
per call (the `Ui`/`Keys` polls loop it `AWAIT_SLOTS` times); `Throw N`
targets slot N. `DomAwait` polls
drain the ready set on the `trap_timer` tick and the `Ui`/`Keys` paths
(`AWAIT-GET /bios/menu` per slot → `resolved menu`), so `await` never
blocks DOM events. The
timer tick also flushes a dirty-watermark-gated background repaint
(`DomPaint`+`VioPaint`/`DispPaint`) — input/nav/await mutations reach the
scanout without a `Ui`. The trap frame now saves `ra`+`t0..t6`+`a0..a7`
(16 slots): a trap-time `jal` must not destroy the interrupted context —
a tick landing inside a normal-context `VioCmd` `wfi` faulted `vqc_poll`
with a clobbered `t5` before the fix (diagnosed via `stval` —
`TRAP-<scause>-<sepc>-<stval>`). `VIO_BUSY` (`__vio+0x5f0`) guards the
ctrlq: `VioCmd` holds it per transaction and `VioPaint` skips when busy,
so a trap-time repaint can never interleave mid-transaction.
**QEMU 8.2-verified** on `g6lc64-virt.json` (WSL2, stock virt, OpenSBI
fw_dynamic): monitor `sendkey` → `INP`, serial `Keys` → the exact Linux
keycodes, `Ui` → `DOM| key …` + `VIRTIO-PAINT`, QMP `screendump` =
P6 1920×1080 with guest pixels; `MBOX-NONE`/`UART1-NONE` on the absent
stock-virt devices, and `egl-headless,gl=on` correctly refuses with
`egl: no drm render node available` (WSL2 has no `/dev/dri`). Absent-device tolerance: unmapped MMIO raises scause 5/7
with `stval`; `trap_fault` recovers probe-window faults (UART1 /
loopback-mbox) so `g6lc64-virt.json` now boots on stock QEMU virt too —
`MboxInit` also readback-checks the doorbell so QEMU's `fw_cfg` at
`0x10100000` reports `MBOX-NONE` instead of swallowing `G6MB`, and the
`uart1` probe runs before `PlicInit` arms the irq (a trap-context fault on
a missing device would nested-trap and clobber `sepc`). The modeled
UART1 sits at `uart0+0x9000` — above the always-present virtio-mmio window
(QEMU virt has no second real ns16550). `g6lc64-qemu.json` is the
stock-virt-faithful spec: `loopback` off (mbox `0x10100000` is QEMU `fw_cfg`),
`dual_band.tcp` off, `postboot`/`net_expose` never; `g6lc64-virt.json`
keeps those lanes enabled — the probes degrade to `MBOX-NONE`/`UART1-NONE`
on stock virt instead of parking.

B50–B52 add bounded JS/DOM and validated i32 WASM execution, shared complete
menu rows, native-browser navigation/imports, `kernel.browser.start_menu`,
post-script Gr/proxy painting, and real numeric RV32/RV64 lowering. B55–B59
extend the host lanes: mutable per-run WASM memory and widened i32 lowering, a
bounded nonblocking JS async scheduler (`await`/throw/catch with budgets and
cancellation), transactional DOM in both Rust and the native-browser kernel,
cooperative RV32/RV64 task-switch IR with bounded scheduler/task services, a
DedicatedWorker compute protocol, and a provenance-gated LDC 1.43 libwasm
component-shell cell (Asyncify build path landed with the custom binaryen;
full Svelte semantics and the D `await`/`catch` host driver still fail closed).
The host
`BrowserSession` and served native app are executable. **B111–B112 landed a
guest-side WASM JIT** (`kernel.wasm.guest_jit`): `g6b-asm::jitr` translates a
bounded WASM subset into `__jit_code`, `fence.i`s it and `jalr`s in, and the
B112 libwasm host-ABI bridge (`g6b-asm::domt` `Lw*`/`Domt*` routines over the
`__dom`/`__dom_str`/`__dom_id` arenas) now runs the shipped ~204 KB
LDC/libwasm cell's `_start` in the exec model — 252 funcs translated, the
cell builds a 56-node `__dom` tree (47 element ids, 8 `g6b_listen` listeners
resolved id→node) that `DomtRaster` paints into `__scan_fb`. That is the
guest-DOM lane verified on the exec model, **not** the full CSS/goosie engine
and **not** QEMU-evidenced yet — `await`/`throw` stay fail-closed
(`libwasm_await_supported`=0), listeners latch `N_LEV` with `listener=0` (no
wasm-funcidx re-entry), and the VGA `start_ops` glyph face is unchanged. Read
`BROWSER.md` / `WASM.md` for supported subsets and limits; never equate a
`WASM-JIT` marker with the native-browser engine.

QEMU `--loader bios` is hypothesis, never Variane evidence.

## Prime directives

1. **Rewrite, do not port.** Read `kernel-spec/ZealOS` (prefer) or
   `kernel-spec/TempleOS`, then write first-party MIT in `crates/**`. Do not
   compile, link, or copy x86/VGA/ring-0/oracle/`/Apps` from the forks.
2. **Conformity.** Every inference from the spec forks must agree with LibreCore:
   OpenSBI M-mode, this payload S-mode, BoardSpec parameterization, PMA/PMP,
   DTS UART/PLIC/SPI/timer map, no AI-island clash at `0x40000000`, firmware-boot
   principles. When ancestor and LibreCore conflict, **LibreCore wins**.
3. **KD0.** `cargo test --workspace` succeeds with only this tree + `fixtures/`.
   `kernel-spec/` is not a crate.
4. **Generated, never typed.** XLEN, RVV, UART base, hart count, mailbox base/IRQ
   come from BoardSpec.
5. **Display is HTML+JS in the kernel**, painted on the BIOS Gr/UART viewport.
   The other KVM face is SSH+HolyC (ZealC CLI), not a replacement.
6. **No Go goja *runtime*, no Chromium, no puppeteer bus.** `kernel-spec/goja`
   is a semantic spec (like TempleOS). Never `import` it, never `go build` it.
7. **OpenSBI stays M-mode.** This package is an S-mode payload.
8. **Post-boot access is parameterized.** After Linux, immutable sections stay
   viewable and write-disabled. The OS NIC may carry gateway/web/SSH only until
   `LinuxHandoff` (`until-delegate`); then the mailbox + PLIC IRQ (`/dev/g6lc-bios`)
   is the loopback — never a netdev.
9. **ASM IR, not string literals.** Generated RISC-V (`KStart.S`, `KInts.S`,
   `MemCpy.S`, ELF words) is lowered from `g6b-asm` after an analysis pass that
   names each object's purpose and architectural home. Do not add a second
   `format!(.s)` / `Vec<u32>` encoder. See `architecture/CODEGEN.md`.

## Render debugging methodology (CSS / DOM / pixel accuracy)

Ancestor: `kernel-spec/goosie` (MIT, `1039ae6`) — the spec of record for
**rendering logic**: `internal/css` for tokenizing, selector matching and
cascade ordering; `internal/renderer` for the box model, layout passes, display
list and dirty regions. Read it, then write first-party Rust in `crates/g6b-css`
(prime directive 1). Its Go source, Goja embedding, Fyne windowing and
Playwright/Chromium verification gate are **refused** — precedence and the full
keep/refuse map are in `kernel-spec/README.md` and
`architecture/RENDER-VALIDATION.md` §5.

The **browser instance** (`createBrowserContext`) owns the `console` / `window` /
`document` singletons a UI is built on. It is engine-agnostic on purpose: the
contract is `bindings()` (an allow-listed `name -> object` map) plus
`consolePage()`, so libwasm consumes it through a single `libwasm_global` import
while plain JS and the devtools panel use it directly. Instances are isolated by
`contextId`, so an embedded frame gets its own console ring. Console shape and
the bounded-ring-that-reports-drops behaviour follow goosie's
`internal/browsercontrol/types.go`. Details: `RENDER-VALIDATION.md` §6.

**The kernel does not make UI design decisions.** It supplies raw board data
through the `platform.*` singleton (identity, ISA, topology, memory, compiled
lanes) and live hardware through `platform.hw`. Menu structure, tab layout,
hit-box geometry, and everything visible is a Svelte decision built from that
data. The kernel must not search the DOM by element id to mutate chrome — that
is the Svelte tree's job. `platform.*` is populated the same way `window.*` and
`document.*` are: resolved live from `BoardSpec` in the wasm lane, injected as
an inert JSON blob in the JS lane.

Four facilities, in the order you should reach for them:

1. **`g6b_css::parse_survey`** — *what is missing.* Point it at real-world CSS;
   it returns the stylesheet plus the sorted list of properties this engine does
   not implement, instead of refusing the sheet. Use it to grow
   `fixtures/css-features.json`. The strict `parse` still refuses the same
   input, so a survey can never widen the render path.
2. **`g6b_css::inspect::explain`** — *why is this value what it is.* A
   DevTools-shaped report: winning declaration first, every overridden candidate
   kept visible with the reason it lost (`!important` / specificity / source
   order), plus the resolved box. `to_text()` for a serial log or console,
   `to_json()` for the browser inspector. It reads the winner out of `cascade`
   itself, so the report can never disagree with the engine it describes.
3. **`createBrowserContext(...).renderConsoleInto(el)`** — *what did the UI
   report.* Paints the bounded console ring into a DOM element, i.e. the
   devtools console panel. `consolePage(since)` polls incrementally and reports
   `dropped`/`missed` rather than silently skipping.
4. **`createRenderInspector`** (`browser-ui/src/kernel.ts`) — *are we
   pixel-accurate.* `diff(el, report, tolerance)` compares an `explain` JSON
   against the host browser's `getComputedStyle` and
   `getBoundingClientRect` for the same element. Length mismatches get a
   whole-pixel tolerance; keyword mismatches never do. `describe(el)` dumps the
   host's own view.

Why the third one is legitimate where a conformance score is not: the host
browser is an **external oracle** for computed values, so a disagreement
localises a cascade or box-model bug to one property. A recognition score from
`@browserscore/supports` — or from our own engine answering its own
`supports()` — is self-reported and measures nothing;
`architecture/RENDER-VALIDATION.md` §1 has the evidence. Track A (feature
inventory) says *what to build*; track B (golden PPM diff) says *whether it is
right*. A feature row is flipped to `landed` only by track-B evidence.

Rules that have already caught bugs here:

- A property outside `SUPPORTED_PROPERTIES` is **refused**, not ignored. A
  silently dropped `float` produces a confidently wrong layout and makes a
  backlog row look landed.
- Fractional and `em`/`rem` lengths are refused, not truncated — the raster is a
  whole-pixel grid.
- An unsupported selector shape (descendant, child, attribute) parses to
  `matchable == false` so it never matches, rather than matching the wrong node.
- Unsupported at-rules are skipped past their **matching** brace. Taking the
  first `}` leaked `@media`'s nested rules into the sheet as a malformed rule.
- Never raise a tolerance budget or re-record a golden to turn a test green.

## Daily commands

```
python tools/g6b.py check
python tools/g6b.py design-compile --spec fixtures/g6lc64-virt.json --out out
python tools/g6b.py boot --spec fixtures/g6lc64-virt.json
python tools/g6b.py qemu-args --spec fixtures/g6lc64-virt.json
python tools/g6b.py holyc-serve --spec fixtures/g6lc64-virt.json --port 2222 --once
python tools/g6b.py http-serve --spec fixtures/g6lc64-virt.json --port 0 --once
python tools/g6b.py loopback --spec fixtures/g6lc64-virt.json --port 0 --once
python tools/g6b.py elf --spec fixtures/g6lc64-virt.json --out out/g6lc_bios.elf
python tools/g6b.py smoke --spec fixtures/g6lc64-virt.json
python tools/g6b.py gr --spec fixtures/g6lc64-virt.json --out out/setup.ppm
python tools/g6b.py display-proxy --spec fixtures/g6lc64-virt.json --out out/proxy.ppm
python tools/g6b.py regress
```

## libwasm / svelte-d / pglite seam (condensed — full model in `AGENTS-EXPERTS.md`)

**One parse, three lanes.** `browser-ui/compiler/parse.ts` is a *first-party*
`.svelte` parser (never `svelte/compiler`). It emits a flat `UiOp[]`
(`text|fetch|holyc|register|visible|await|pglite`), printed into three
independent lanes:

| Lane | Printer | Artifact | Toolchain |
|---|---|---|---|
| A first-party wasm | `emit-wasm.ts` | `out/bios-ui.wasm` | none (MVP encoder) |
| B libwasm D cell | `print-d.ts` → `src-d/*.d` | `out/bios-ui-libwasm.wasm` | LDC 1.43 + dub |
| C lang=ts / JS | `print-ts.ts` | src-ts splice, `jsExports`, g6b-js subset | bun |

A new capability is **a new op kind + a printer arm**, not an expression
evaluator. `pgliteMethod()` (`parse.ts:203`) is the store-verb allow-list.
Both artifacts are embedded by `g6b-asm` (`include_bytes!`, `lib.rs:532,538`),
so **browser-ui builds before the Rust build**.

**The ABI is one file.** `types.d` routes `version (G6LC_G6B)` to
`libwasm/source/libwasm/g6b_kernel.d`, which *is* the g6b import contract:
g6b-registered (`fetch`/`holyc`/`register_endpoint`/`set_inner_text`), generic
`Object_Getter__*` / `Object_Call_*__*` / `Object_VarArgCall__*`, scalar
`libwasm_add__*`/`libwasm_get__*`, refcounted handles
(`libwasm_{add,remove,copy}Object*`; handles 1–2 are never-freed roots),
`libwasm_global(name)` (returns 0 = unavailable, fail-closed), the 12
`ldexec_*` lodash imports, and the asyncify family. Undeclared ⇒ unreachable
from D. `runtimePreflight` (`compiler/ldc.ts:286`) asserts this seam so a plain
upstream libwasm checkout fails with a reason, not a link error.

**lodash is one host call.** `struct Lodash` accumulates a JSON command buffer;
`.execute!T()` ships it through `ldexec_<init>__<ret>`. `Eval("name")` is a
*host-name* reference, never JS source — the host interns by name and refuses
the rest (`LodashError::EvalRefused`); `evalTail` is rejected outright. Guest
iteratees dispatch back through `__indirect_function_table`, so no JS evaluator
exists on either side. `MAX_PARAMS=5`, which is why binds are packed as one
JSON array.

**Three hosts, deliberately unequal.** Know which one you are debugging:

1. **Rust `KernelHost`** (`g6b-kernel/src/lib.rs:3318`) — the BIOS/QEMU host.
   *Real* lodash + pglite + `platform.*`. `intern_name` (`:3199`) allows
   `window.pglite` only when `spec.kernel.store.enable`, plus
   `window.platform`; `hw` is refused as "platform.hw, not a window global".
   Chain: `Eval("window.pglite")` → `StoreFactory` → `attempt(dataDir)` →
   `Store{uuid}` → `invoke(method)` → `store_method` (`:2640`, genuinely
   implements query/exec/begin/commit/rollback/close/stat/dump/load/listen/
   notifies/export; only `sql`/`transaction` are `NotImplemented("callback")`).

   **`platform.*` singleton** carries raw board data the same way `window.*`
   and `document.*` carry DOM data — resolved live from `BoardSpec` in
   `platform_live` (`g6b-kernel/src/lib.rs`), never by id-based DOM search.
   Fields: `product`, `profile`, `schema`, `xlen`, `march`, `mmu`, `harts`,
   `cores`, `threads`, `dramBase`, `dramLen`, `textOffset`, `web`, `wasm`,
   `cli`, `store`, `workers`, `startMenu`. Scalars come back typed; there is
   no structured/menu data on `platform.*` — **menus are a UI decision and are
   built in Svelte from these facts, not carried by the kernel**. `platform.hw`
   is the live hardware tree (NAT/display/TCP/UDP), separate from board facts.
2. **Browser `kernel.ts`** (`createLibwasmHost`, `:349`) — DOM real, store is a
   `fetch` proxy to `/bios/store/*` (`newBiosStore`, `:1467`). lodash is sync and
   the store is async, so the sync path substitutes a well-formed
   `ASYNC_STORE` = `{ok:false,error:"async"}` sentinel (`:573`). Real async work
   goes through asyncify or `createPgliteWasm`.
   **`platform.*`** in the JS lane reads the same board facts from a
   `<script type="application/json" id="g6b-platform">` blob that `g6b-ui`
   injects once at build time (`platform_facts_script`). `readPlatformFacts`
   parses it; `PLATFORM_FACT_KEYS` is the shared list. The blob is inert JSON
   (not executable JS), so `g6b-html`'s `script_sources` skips it. Keys match
   `KernelHost::platform_live` exactly — the two lanes cannot disagree.
3. **Build-time verifier** (`wasm-cell.ts`) — `verifyLibwasmAbi` (signatures,
   one memory, i32 `__heap_base`) + `verifyLibwasmStartup` (`:392`, actually
   runs `_start`) + `checkCellArtifact` (`:444`).

**"stale libwasm provenance" is a hash statement, not a compiler error.**
`cellInputHash` (`:358`) covers the workspace sources, `dub.sdl`, the pinned
`ldc2-wasm.conf`, **all of libwasm + its four sub-packages + the whole carried
`runtime-v1.43.0`**, every compiler `.ts`, `kernel.ts`, `worker.ts`, and the
`ldc`/`dub` **binaries**. Any delta flips it; most often the cell was simply
never built. Diagnose in order: `runtimePreflight(tc)` empty? →
`dub.sdl` byte-matches `engineDubSdl(tc.libwasm)`? → `G6B_DUB_WASM=1 bun run build`.
The pin beats an ambient 1.43 on purpose (the hash covers the compiler binary).

**Store ⇄ volume.** `g6b-pglite` declares `StoreVolume`
(`persist.rs:171`); `g6b-kernel/src/vfs.rs` implements it over `g6b-vfs`, and
`volume` resolves as a mount name *or* a filesystem kind (`vfs.rs:538-541`).
All four **can** write; the ceilings differ. Every driver answers
`edit_budget(path)` up front (B102), so trust `Probe::summary()`, not the `rw`
request (`rw` is a *request*; the mount reports what it got):

| FS | Terms | Ceiling |
|---|---|---|
| fat32 | `fat32 rw` | creates, grows, shrinks; free clusters **counted**, not from the FSInfo hint |
| ext4 | `ext4 rw` | in-place + tail growth by block allocation; file/dir creation; sparse mid-hole writes refused |
| btrfs | `btrfs rw` | in place inside existing extents (csum tree refreshed); inline ≤2048 B; 16 MiB fixture, no host `mkfs.btrfs` |
| ntfs | `ntfs rw <=N B in place` | **resident `$DATA` only**, `can_grow: false`; non-resident/new files refused; needs a clean `$LogFile` |

**NTFS is not read-only.** `ntfs::mount(dev)` takes no `rw` parameter, which
makes it look read-only beside the other three, but B107 added a real bounded
write path. Do not infer capability from the mount signature.

So an fs-matrix store test *is* reachable, but expectations must be
**per-fs**: the store export is a JSON blob, and on NTFS it has to fit the
existing resident `$DATA` with no growth. Full detail:
`architecture/g6b-vfs.md` "Editing: the filesystem's terms".

**The cell must fit the JIT decode budget, which is size-proportional.**
`g6b_wasm::instruction_budget(code_bytes) = clamp(code_bytes, 131_072, 262_144)`.
The proportional term is an *exact* upper bound (≥1 body byte per instruction),
so below the ceiling the check cannot fire; `MAX_INSTRUCTIONS_CEIL` (the
`Vec<Instr>` fence) and `MAX_MODULE_BYTES` (1 MiB) are the operative bounds.
`BIOS_UI_CELL_BUDGET` is a `const` pre-compute over the embedded artifact — the
trusted half of the split. When the Svelte tree outgrows the JIT the failing
test is **`binary::tests::cell_budget_covers_the_embedded_bios_ui`** (reports
real numbers, demands 2× headroom), not three opaque `g6b-elf` smoke failures.
See `architecture/WASM.md`.

**`wasm-opt` is a toolchain, not a nicety, and lives beside LDC.** Stock
Binaryen cannot `--asyncify` the `try_table` LDC 1.43 emits for wasm-EH, so the
`etcimon/binaryen` `svelte-d` fork is required and a stock tool on PATH *fails*
the pass. `tools/build.py ensure_wasm_opt()` mirrors `ensure_ldc()` for any
libwasm build: `--check` → download the fork's CI binary → cmake the
`svelte-d/binaryen` submodule; a working out-of-tree fork is *adopted by copy*
into `browser-ui/toolchains/binaryen-svelte-d/`. Verified **by behaviour**
(`asyncifiesTryTable`), recorded in provenance as `asyncifyTool`
(informational — not an `inputs`/staleness trigger).

**Serial output is doubled.** Every character is written twice (SBI putchar *and*
UART0 THR). De-double before matching markers —
`sed 's/\(.\)\1/\1/g'` / `re.sub(r"(.)\1", r"\1", text)` — or every marker is a
false negative.

## Top-level build orchestrator

`build.py` / `build.ps1` / `build.sh` at the package root handle all major
build types with auto-install. The build-platform gateway (`g6b` command in
`E:\cva6\build-platform`) delegates here.

```
python tools/build.py zealcli                           # minimal g6b-zealcli VGA (cargo + smoke)
python tools/build.py browser                            # browser-ui first-party wasm lane (bun run build)
python tools/build.py libwasm                            # browser-ui + pinned LDC 1.43.0-beta1 libwasm cell
python tools/build.py full                               # zealcli + browser + libwasm (dual build)
python tools/build.py check                              # g6b.py check (independence + bun + cargo gates)
python tools/build.py zealcli --spec fixtures/g6lc64-zealcli.json
```

### Generic QEMU test command

`build.py test` is a parameterized QEMU smoke test that builds the browser
UI, builds a BIOS ELF from a selected spec, emits or reuses a filesystem
fixture image, boots the ELF under QEMU (WSL on Windows), optionally sends
keystrokes through the QEMU monitor/serial, and scans the de-duplicated
serial log for markers.

```
python tools/build.py test --spec fixtures/g6lc64-btrfs-test.json
python tools/build.py test --spec fixtures/g6lc64-btrfs-test.json --fs btrfs
python tools/build.py test --spec fixtures/g6lc64-btrfs-test.json \
    --no-emit-fs --disk out/btrfs-key.img \
    --keys "drv{ret}" --key-delay 1 --settle 15 \
    --keywords btrfs,Store,USB-FILES,SVELTE-LIVE,JS-FETCH,ZEALCLI,KSTART,G6LC-BIOS
```

Parameters:

| Flag | Default | Purpose |
|---|---|---|
| `--spec` | `fixtures/g6lc64-zealcli.json` | BoardSpec JSON |
| `--fs` | `btrfs` | Filesystem fixture: `fat32\|ext4\|ntfs\|btrfs` |
| `--libwasm` | off | Also build the LDC 1.43 libwasm cell |
| `--settle N` | 10 | QEMU settle seconds (boot + post-keystroke) |
| `--readonly` | off | Attach the disk read-only |
| `--keywords k1,k2` | btrfs,Store,USB-FILES,SVELTE-LIVE,JS-FETCH,ZEALCLI,KSTART,G6LC-BIOS | Markers to scan for |
| `--no-emit-fs` | off | Skip emitting the fixture (requires `--disk`) |
| `--disk PATH` | emitted | Use an existing disk image |
| `--keys TEXT` | none | Keystrokes after boot; `{esc}`, `{ret}`, `{spc}`, `{tab}`, `{bs}` are special |
| `--key-delay S` | 0.5 | Delay between keystrokes |

The BIOS payload writes each serial character twice (SBI putchar *and*
UART0 THR), so the log is de-doubled before scanning — same as
`tools/qemu_zealcli.sh`. A passing host-side `g6b vfs scan` only proves
image recognition; the QEMU test proves guest-side boot + store activity.

### The filesystem matrix

```
g6b vfs emit-fs --fs fat32|ext4|ntfs|btrfs [--out PATH] [--with-data]
python tools/build.py test --fs fat32 --keys "drv{ret}" --settle 15
```

One fixture entry point, `g6b_vfs::fixture_image_named(name)` over
`g6b_vfs::FIXTURE_KINDS`, so a caller does not need to know each driver's
hand-laid shape. `every_fixture_kind_probes_and_mounts_as_itself` (g6b-vfs) is
the guard that each still probes and mounts; `emit-btrfs` remains as an alias.

**Expectations are per-filesystem, and that is deliberate** — a matrix
asserting one outcome for all four would assert something false
(`the_store_matrix_insert_and_query_per_filesystem`, g6b-kernel):

| FS | Fixture | Store outcome |
|---|---|---|
| fat32 | 2 MiB, `G6LCTEST` | full round trip: insert → query → export → fresh registry imports → query |
| ext4 | 512 KiB, `g6lcroot` (+`/etc/os-release`) | same, within the guarded write path |
| btrfs | 16 MiB, `G6LCBTRFS` | same; needs 16 KiB-nodesize leaf headroom |
| **ntfs** | 128 KiB | **refused on the first `CREATE TABLE`** |

The NTFS case is the one worth knowing: with `persist.usb` armed the store
writes `/stores/<purpose>/<uuid>.g6bstore` on **every statement**, and a driver
that cannot create files cannot back a persisted store at all — so the refusal
lands earlier than "export is refused" would suggest. It must be a *named*
refusal (`volume write: …`), because an unnamed one is indistinguishable from a
broken store engine.

What the QEMU run proves is guest-side **detection and store liveness** per
filesystem (`<fs>-OK`, `USB-FILES-OK`, `Store-OK`, `SVELTE-LIVE-OK`,
`JS-FETCH-OK`). The per-fs *write* semantics above are pinned host-side by the
Rust tests — do not read a green QEMU matrix as proof that an export succeeded
inside the guest.

Auto-install: cargo (via build-platform `tools install sim` fall-through),
bun (printed instruction), pinned LDC 1.43.0-beta1 (`browser-ui/scripts/install-ldc.ts`).
The optional libwasm cell uses `G6B_DUB_WASM=1 bun run build` through the
existing `browser-ui/scripts/build.ts` path; the pinned compiler is selected
via `--compiler=<toolchain>/bin/ldc2.exe` and `cellEnv()` isolates `DC`/`DFLAGS`
so PATH's LDC 1.41 is never selected.

Navigate: plan of record `architecture/PLAN.md`; web-engine endpoint
`architecture/plan-endpoint.md` (B82–B91); keep/refuse map `architecture/ZEAL.md`;
codegen philosophy `architecture/CODEGEN.md`; display-proxy `architecture/DISPLAY.md`;
interactive UI `architecture/BROWSER-RUNTIME.md` (browser loads the LDC cell
on a UI thread; GLES2 `u_dom` onto virtio-gpu/HDMI); subset/config
`architecture/BROWSER.md`; render validation + CSS methodology
`architecture/RENDER-VALIDATION.md`; libwasm host ABI + completion plan
`architecture/LIBWASM-ABI.md`; USB `architecture/USB.md`; menus
`architecture/MENUS.md`; file server `architecture/FILE-SERVER.md`; TLS
`architecture/TLS.md`; kernel HTTP `architecture/KERNEL-API.md`; spec checkouts
`kernel-spec/README.md`.
