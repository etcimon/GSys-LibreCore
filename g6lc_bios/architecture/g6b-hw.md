# g6b-hw — hardware adapters (virtio-net, SoC uncore, TCP/IP)

**Status:** landed (B93). Green remains `python tools/g6b.py check`. BIOS
QEMU argv still never `-netdev`.

`g6b-hw` is the adapter catalog that would otherwise be a pile of
corev_apu / corev-mb **drivers**: virtio-net (virtual), vendor ethernet
MAC, wifi (catalog), virtio-gpu, HDMI scanout. It does **not** link
QEMU, OpenSSL, or uncore RTL.

## Layers

| Layer | What |
|---|---|
| Config | `fixtures/hw-desktop.json` or `HwSpec::from_board(BoardSpec)` |
| Guest IR | `g6b-asm` `VioNetProbe` — virtio-mmio DeviceID **1**, slot 5 in the exec model |
| Host adapter | OS sockets for isolated NAT / TCP / UDP. HTTP(S) fetch is a kernel path. |
| g6lc_qemu | already emits `virtio-net-pci`/`virtio-net-device` when *its* `netdev_user`/`netdev_hub` is set. BIOS `qemu-args` does not. |

`kernel.hw.enable` + `kernel.hw.virtio_net` (on appliance/desktop/full)
arm the guest probe. That is **not** permission to attach a NIC to the
BIOS QEMU machine.

## Post-boot lazy session

`HwSession` is idle until a JS/wasm/HolyC function runs. It is **not**
started from `_start`. HolyC `HwStat` / `HwListen` / `HwConfig` /
`HwCable` / `HwWake` **return instantly** (`HW-STAT` snapshot, or
`HW-OK`/`HW-ERR` plus status). JS/wasm may `await hwConfig` and throw
without exiting the listen worker.

The first function **announces** adapters through the kernel
(`VIRTIO-NET 5`, `HW-NET`, `HW-DISP`) and emits `HWEvent` values on the
same intern/dispatch path as a DOM `MouseEvent` (`hwnet`, `hwdisp`,
`hwcable`, …). Live state is interned as **`platform.hw`** (HolyC-shaped:
`HwStat` / `HwIfconfig` / …), chained like `window.document`. It is
**not** `window.hw` and is **not** interned in iframe sessions. Svelte
polls `platform.hw.net` / `platform.hw.display`; the kernel does not
write the DOM by id. Net devices take Linux-like inet (addr/prefix,
gateway, DNS, link up/down, TCP+UDP enable) in the isolated session.

## NAT, static IP, TCP/UDP, host NIC

Default `NatMode` is **minimal** (status only). Opt-in:

| Mode | What |
|---|---|
| `minimal` | Default. No sockets, no host NIC. `env_untouched` stays true. |
| `isolated` | Userspace NAT `10.0.2.15/24`, gateway `10.0.2.2`, DNS `10.0.2.3` (slirp-shaped). Real TCP/UDP via host `std::net`. Not QEMU `-netdev`. |
| `host` / `full` | Isolated NAT plus opt-in host NIC programming. |

Static addressing (`HwIfconfig` / `HwConfig(...,"static",ip)`) rejects the subnet and broadcast addresses; a default route must sit in the interface subnet. `HwConfig(...,"nat")` promotes minimal → isolated and assigns the NAT lease.

TCP/UDP (`HwTcpListen` / `HwTcpConnect` / `HwTcpAccept` / `HwTcpSend` / `HwTcpRecv` / `HwUdpBind` / `HwUdpSend` / `HwUdpRecv` / `HwSockClose`) require `nat=isolated|host` and link up. Recv is non-blocking so HolyC stays instant. Budget is 16 sockets.

Host NIC apply is explicit on a **named** adapter (`HwHostList` / `HwHostApply("net0","vEthernet")` / `HwHostRevert`). An empty name is refused so the default-route NIC is never guessed. `env_untouched` becomes false only after a successful apply. Windows uses `netsh`; Unix uses `ip addr`.

Chaining: `platform.hw.natMode("isolated")`, `platform.hw.net.tcp.listen(0)`, `platform.hw.hostApply("Loopback")`. Getter `platform.hw.nat` stays the mode string.

When net support is announced and `kernel.http.outbound` is on, iframe
tabs may load remote `http(s):` (including a retry of stored locations).
Display **stays VGA** until `g6b-hw` internally probes the catalog
(PCIe linear-fb → HDMI G6DS → virtio-gpu) **and** the kernel announces
the winner (`HW-DISP-SEL`). Only then does scanout switch to the GPU
surface. Neither step mutates QEMU argv.

## Display adapters (VGA default)

| kind | file | present backend |
|---|---|---|
| `virtio-gpu` | `adapters/virtio_gpu.rs` | `virtio-2d` TRANSFER/FLUSH |
| `hdmi` | `adapters/hdmi.rs` | `g6ds` MMIO (`G6DS` magic, rev 1) |
| `pcie-gpu` | `adapters/pcie_gpu.rs` | `pci-linear` only with `linear-fb`; else `PCI-GPU-DEMOTED` |

Vendors fail closed: HDMI `g6lc-scanout` / `hdl-util-hdmi`; PCIe `amd` /
`nvidia`. Empty PCIe vendor is generic class `0x03`. No AtomBIOS/DCN, no
GSP, no BAR assignment, no libGL.

`HwDispStat` / `HwDispLink` / `HwDispMode` / `HwDispSurface` / `HwGl` /
`HwGlList` / `HwGlApply` / `HwGlRevert` are HolyC-instant. `HwGlApply`
needs a **named** host GPU. GLES2 listing stays in `g6b-gr::gl`; this
crate only chooses the destination. Default `gl=off`.

## virtio-net

- DeviceID `1` (`g6b_asm::encode::VIO_DEV_NET`)
- Features in the config: `csum`, `mac`, `status`, `version_1`
- Exec model sits on virtio-mmio **slot 5** (PLIC irq 6) so it does not
  collide with GPU (0), keyboard (1), mailbox irq 3 (slot 2), tablet (3),
  or timer irq 5 (slot 4)
- Console: `VIRTIO-NET 5` or `VIRTIO-NET-NONE`

## Vendor ethernet / wifi

Catalog ids match `architecture/uncore/ethernet-controller.md`:
`verilog-ethernet`, `liteeth`, `corundum`, `ariane-ethernet`. Unknown
vendors fail closed. Wifi has no catalog id yet (`vendor: none`).

## Fetch is not in this crate

HTTP(S) GET is a **kernel** abstraction. Callers:

| Face | Entry |
|---|---|
| HolyC | `HttpGet` / `HttpsGet` via `holyc_request` |
| JS / svelte-d | `fetch("http(s)://…")` → `kernel_fetch` |
| iframe | `HostNeed::RemoteHtml` when `kernel.http.outbound` |

```
plan (g6b-http)  →  hw TCP connect/send/recv
                      ├─ http:  HTTP/1.1 GET bytes
                      └─ https: g6b-tls ClientHello  (501 fingerprint until B54)
diagnostics: KERNEL-FETCH http|https host:port via=hw-tcp sock=N
```

This crate never speaks HTTPS. Isolated NAT + link-up are prepared by the
kernel for that GET; `env_untouched` stays true. Production record crypto
remains B54.

## USB key and pointer

Mouse/tablet and USB-key listings moved **into this crate** so VGA
`g6b-zealcli` stays mouse-less and hw-free. Catalog: `virtio-keyboard`,
`virtio-tablet` (DeviceID 18), `usb-hid`, `usb-key`, `usb-msc`. HolyC
`UsbLs`/`UsbKey`/`UsbFlash` is intercepted by the kernel onto
`HwUsbLs`/`HwUsbKey`/`HwUsbFlash`. `HwPointer(x,y,buttons)` is the
pointer path; zealcli never calls it.

## Refusals

- BIOS `qemu-args` `-netdev` / `virtio-net-device`
- Linking OpenSSL, Botan, libcurl, rustls
- Path deps on `g6lc_qemu`, `corev_apu`, `corev-mb`
