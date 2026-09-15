// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! RISC-V encodings used by IR lowering. No x86.

#![allow(missing_docs)]

pub const X0: u32 = 0;
pub const RA: u32 = 1;
pub const SP: u32 = 2;
pub const TP: u32 = 4;
pub const T0: u32 = 5;
pub const T1: u32 = 6;
pub const T2: u32 = 7;
pub const S0: u32 = 8;
pub const S1: u32 = 9;
pub const A0: u32 = 10;
pub const A1: u32 = 11;
pub const A2: u32 = 12;
pub const A3: u32 = 13;
pub const A4: u32 = 14;
pub const A5: u32 = 15;
pub const A6: u32 = 16;
pub const A7: u32 = 17;
pub const S2: u32 = 18;
pub const S3: u32 = 19;
pub const S4: u32 = 20;
pub const S5: u32 = 21;
pub const S6: u32 = 22;
pub const S7: u32 = 23;
pub const S8: u32 = 24;
pub const S9: u32 = 25;
pub const S10: u32 = 26;
pub const S11: u32 = 27;
pub const T3: u32 = 28;
pub const T4: u32 = 29;
pub const T5: u32 = 30;
pub const T6: u32 = 31;

pub const CSR_SSTATUS: u32 = 0x100;
pub const CSR_SIE: u32 = 0x104;
pub const CSR_STVEC: u32 = 0x105;
/// Supervisor address-translation (`satp`). Bare = 0 (Priv ch. 4).
pub const CSR_SATP: u32 = 0x180;
pub const CSR_SEPC: u32 = 0x141;
pub const CSR_SCAUSE: u32 = 0x142;
/// Supervisor trap value (`stval`) — fault address on access faults.
pub const CSR_STVAL: u32 = 0x143;
/// Unprivileged `time` CSR (`rdtime`). S-mode; OpenSBI may trap-and-emulate.
pub const CSR_TIME: u32 = 0xC01;
pub const SRET: u32 = 0x1020_0073;
/// `sie` / `sstatus` bits: supervisor timer + global SIE (Priv spec ch. 3).
/// `sie` supervisor software interrupt (SSI / SBI IPI wake).
pub const SIE_SSIE: i64 = 1 << 1;
pub const SIE_STIE: i64 = 1 << 5;
/// `sie` supervisor external interrupt (PLIC / SEI, Priv ch. 3).
pub const SIE_SEIE: i64 = 1 << 9;
pub const SSTATUS_SIE: i64 = 1 << 1;
/// QEMU virt / SiFive PLIC. S-mode context for hart `h` is `2*h + 1`:
/// enable block `+0x2000 + ctx*0x80`, claim/threshold page `+0x200000 +
/// ctx*0x1000` (ctx1 = hart0 shown for reference).
pub const PLIC_BASE: u64 = 0x0c00_0000;
pub const PLIC_ENABLE_BASE: u64 = PLIC_BASE + 0x2000;
pub const PLIC_CTXT_BASE: u64 = PLIC_BASE + 0x20_0000;
pub const PLIC_ENABLE_S0: u64 = PLIC_ENABLE_BASE + 0x80;
pub const PLIC_THRESH_S0: u64 = PLIC_CTXT_BASE + 0x1000;
pub const PLIC_CLAIM_S0: u64 = PLIC_CTXT_BASE + 0x1004;
/// QEMU virt ns16550 UART0 PLIC line — `interrupts = <0x0a>` in the
/// machine DTB (not COM1, and *not* irq 1: that is virtio-mmio slot 0).
pub const UART_IRQ: i64 = 10;
/// ns16550 IER received-data bit (`ERBFI`).
pub const UART_IER_RX: i64 = 1;
/// ns16550 LSR data-ready bit.
pub const UART_LSR_DR: i64 = 1;
/// Sideband mailbox (not a netdev). Matches generated `g6lc_bios_mbox.h`.
pub const MBOX_MAGIC: u32 = 0x4736_4d42;
pub const MBOX_OFF_DOORBELL: u64 = 0x00;
pub const MBOX_OFF_LENGTH: u64 = 0x04;
pub const MBOX_OFF_STATUS: u64 = 0x08;
pub const MBOX_OFF_IRQ_EN: u64 = 0x0c;
pub const MBOX_OFF_CMD: u64 = 0x10;
pub const MBOX_OFF_RSP: u64 = 0x110;
pub const MBOX_CMD_BYTES: u64 = 0x100;
pub const MBOX_RSP_BYTES: u64 = 0x100;
pub const MBOX_ST_BUSY: u32 = 0x1;
pub const MBOX_ST_RSP: u32 = 0x2;
pub const MBOX_ST_DELEG: u32 = 0x4;
/// Linux `write()` doorbell kick (not the `G6MB` identity word).
pub const MBOX_KICK: u32 = 1;
/// Little-endian `VIEW` / `WAKE` / `UI` / `FILE` / `KEYS` response words.
pub const MBOX_RSP_VIEW: u32 = 0x5745_4956;
pub const MBOX_RSP_WAKE: u32 = 0x454b_4157;
pub const MBOX_RSP_UI: u32 = 0x000a_4955;
pub const MBOX_RSP_FILE: u32 = 0x454c_4946;
pub const MBOX_RSP_KEYS: u32 = 0x5359_454b;
/// SysGrInit plane magic `GR16` (640×480×16; not VGA).
pub const GR16_MAGIC: u32 = 0x3631_5247;
/// Guest UI blob ident at `__ui_blob` (`G6UI`).
pub const UI_MAGIC: u32 = 0x4955_3647;
/// WASM module magic `\0asm` (little-endian), echoed at G6UI+24 after FileServe.
pub const WASM_MAGIC: u32 = 0x6d73_6100;
/// Packed 4bpp colour-1 word for the boot scanline.
pub const GR_FILL_WORD: u32 = 0x1111_1111;
/// QEMU virt virtio-mmio transports: 8 slots at `0x10001000 + 0x200*i`.
/// Register offsets: +0x00 MagicValue `0x74726976` ("virt"), +0x04 Version,
/// +0x08 DeviceID (16 = GPU). Probed read-only; virtqueues/scanout are open.
pub const VIO_MMIO_BASE: u64 = 0x1000_1000;
/// QEMU virt instantiates all 8 virtio-mmio transports at a 0x1000 stride
/// (each region is 0x200 wide; the gaps are unmapped and fault on access).
pub const VIO_MMIO_STEP: u64 = 0x1000;
pub const VIO_MMIO_SLOTS: i64 = 8;
pub const VIO_MAGIC: u32 = 0x7472_6976;
pub const VIO_DEV_GPU: u32 = 16;
/// virtio-net device id (virtio spec 5.1). Guest `VioNetProbe` enumerates it.
/// BIOS `qemu-args` never attaches `virtio-net-device` / `-netdev`.
pub const VIO_DEV_NET: u32 = 1;
/// Exec-model virtio-mmio slot for virtio-net (irq 1+slot = 6). Slots 0–3
/// are GPU / keyboard / mailbox-gap / tablet; slot 4 would collide irq 5.
pub const VIO_NET_SLOT: u64 = 5;
/// virtio-input device id (virtio spec 5.8) — `virtio-keyboard-device` /
/// `virtio-tablet-device` attach to their own virtio-mmio slot.
pub const VIO_DEV_INPUT: u32 = 18;
/// virtio-blk device id (virtio spec 5.2). `BlkProbe` enumerates it; this is how
/// the payload reads sectors *itself* instead of being handed bytes by a host.
pub const VIO_DEV_BLK: u32 = 2;
/// Exec-model virtio-mmio slot for the modelled block device (irq 1+slot = 7).
/// Slots 0–3 are GPU / keyboard / mailbox-gap / tablet and slot 5 is virtio-net.
pub const VIO_BLK_SLOT: u64 = 6;
/// `virtio_blk_req.type` — `VIRTIO_BLK_T_IN` is a read *from* the device.
pub const VIO_BLK_T_IN: i64 = 0;
/// `VIRTIO_BLK_T_OUT` — write *to* the device. Guest data is device-readable.
pub const VIO_BLK_T_OUT: i64 = 1;
/// `VIRTIO_BLK_T_FLUSH` — durable flush; requires `VIRTIO_BLK_F_FLUSH`.
pub const VIO_BLK_T_FLUSH: i64 = 4;
/// Feature bit 9 (`VIRTIO_BLK_F_FLUSH`) in device-features word 0.
pub const VIO_BLK_F_FLUSH: u32 = 1 << 9;
/// `virtio_blk_req.status` — `VIRTIO_BLK_S_OK`.
pub const VIO_BLK_S_OK: i64 = 0;
/// `VIRTIO_BLK_S_IOERR`.
pub const VIO_BLK_S_IOERR: u8 = 1;
/// The unit every virtio-blk request is quoted in: virtio spec 5.2.4 fixes it at
/// 512 bytes regardless of the device's own block size.
pub const VIO_BLK_SECTOR: i64 = 512;
/// virtio-mmio register offsets (modern interface; `Version` = 2).
pub const VIO_REG_FEATURES: i32 = 0x10;
pub const VIO_REG_FEATURES_SEL: i32 = 0x14;
pub const VIO_REG_DRV_FEATURES: i32 = 0x20;
pub const VIO_REG_DRV_FEATURES_SEL: i32 = 0x24;
pub const VIO_REG_QUEUE_SEL: i32 = 0x30;
pub const VIO_REG_QUEUE_NUM_MAX: i32 = 0x34;
pub const VIO_REG_QUEUE_NUM: i32 = 0x38;
pub const VIO_REG_QUEUE_READY: i32 = 0x44;
pub const VIO_REG_QUEUE_NOTIFY: i32 = 0x50;
pub const VIO_REG_ISR_STATUS: i32 = 0x60;
pub const VIO_REG_ISR_ACK: i32 = 0x64;
pub const VIO_REG_STATUS: i32 = 0x70;
pub const VIO_REG_QUEUE_DESC: i32 = 0x80;
pub const VIO_REG_QUEUE_AVAIL: i32 = 0x90;
pub const VIO_REG_QUEUE_USED: i32 = 0xa0;
/// virtio status bits (STATUS register).
pub const VIO_ST_ACK: i32 = 1;
pub const VIO_ST_DRIVER: i32 = 2;
pub const VIO_ST_DRIVER_OK: i32 = 4;
pub const VIO_ST_FEATURES_OK: i32 = 8;
/// `VIRTIO_F_VERSION_1` — bit 32 of the feature space = bit 0 of word 1.
pub const VIO_F_VERSION_1: u32 = 1;
/// virtio-gpu ctrlq commands (`ctrl_hdr.type`; virtio spec 5.7.6).
pub const VIO_GPU_GET_DISPLAY_INFO: u32 = 0x0100;
pub const VIO_GPU_RESOURCE_CREATE_2D: u32 = 0x0101;
pub const VIO_GPU_SET_SCANOUT: u32 = 0x0103;
pub const VIO_GPU_RESOURCE_FLUSH: u32 = 0x0104;
pub const VIO_GPU_TRANSFER_TO_HOST_2D: u32 = 0x0105;
pub const VIO_GPU_RESOURCE_ATTACH_BACKING: u32 = 0x0106;
/// `VIRTIO_GPU_CMD_GET_CAPSET_INFO` — enumerate a capability set
/// (`capset_index`); answered by `RESP_OK_CAPSET_INFO`.
pub const VIO_GPU_GET_CAPSET_INFO: u32 = 0x0108;
/// `VIRTIO_GPU_CMD_GET_CAPSET` — fetch `capset_id`/`capset_version` data.
pub const VIO_GPU_GET_CAPSET: u32 = 0x0109;
/// 3D commands — present only when the device offers `VIRTIO_GPU_F_VIRGL`.
/// `VIRTIO_GPU_CMD_CTX_CREATE` (ctx_id + debug_name in the ctrl_hdr).
pub const VIO_GPU_CTX_CREATE: u32 = 0x0200;
/// `VIRTIO_GPU_CMD_CTX_ATTACH_RESOURCE` — bind `resource_id` to `ctx_id`.
pub const VIO_GPU_CTX_ATTACH_RESOURCE: u32 = 0x0202;
/// `VIRTIO_GPU_CMD_RESOURCE_CREATE_3D` — target/format/bind + 3D extent.
pub const VIO_GPU_RESOURCE_CREATE_3D: u32 = 0x0204;
/// `VIRTIO_GPU_CMD_TRANSFER_TO_HOST_3D` — guest→host on a 3D resource.
pub const VIO_GPU_TRANSFER_TO_HOST_3D: u32 = 0x0205;
/// `VIRTIO_GPU_CMD_TRANSFER_FROM_HOST_3D` — host→guest on a 3D resource.
pub const VIO_GPU_TRANSFER_FROM_HOST_3D: u32 = 0x0206;
/// `VIRTIO_GPU_CMD_SUBMIT_3D` — the execbuffer: `virtio_gpu_cmd_submit`
/// (32B) followed by `size` bytes of virgl command stream in the OUT
/// descriptors. `size` counts bytes; `virgl_renderer_submit_cmd` gets `size/4`
/// dwords.
pub const VIO_GPU_SUBMIT_3D: u32 = 0x0207;
/// virtio-gpu response types (`resp_hdr.type`).
pub const VIO_GPU_RESP_OK_NODATA: u32 = 0x1100;
pub const VIO_GPU_RESP_OK_DISPLAY_INFO: u32 = 0x1101;
/// `VIRTIO_GPU_RESP_OK_CAPSET_INFO` — carries id/max_version/max_size.
pub const VIO_GPU_RESP_OK_CAPSET_INFO: u32 = 0x1102;
/// `VIRTIO_GPU_RESP_OK_CAPSET` — carries the capset blob.
pub const VIO_GPU_RESP_OK_CAPSET: u32 = 0x1103;
pub const VIO_GPU_RESP_ERR_UNSPEC: u32 = 0x1200;
/// `VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY`.
pub const VIO_GPU_RESP_ERR_OUT_OF_MEMORY: u32 = 0x1201;
/// `VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID`.
pub const VIO_GPU_RESP_ERR_INVALID_RESOURCE_ID: u32 = 0x1203;
/// `VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID`.
pub const VIO_GPU_RESP_ERR_INVALID_CONTEXT_ID: u32 = 0x1204;
/// `VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER` (e.g. a malformed execbuffer).
pub const VIO_GPU_RESP_ERR_INVALID_PARAMETER: u32 = 0x1205;
/// virtio-gpu feature bits in the **low** 32-bit word (`FEATURES_SEL=0`).
/// `VIRTIO_GPU_F_VIRGL` — the device runs a virgl/GLES renderer for
/// `SUBMIT_3D`; `VIRTIO_GPU_F_CONTEXT_INIT` — `CTX_CREATE` carries an
/// `context_init` mask; `VIRTIO_GPU_F_RESOURCE_BLOB` — blob resources.
pub const VIO_GPU_F_VIRGL: u32 = 1 << 0;
pub const VIO_GPU_F_RESOURCE_BLOB: u32 = 1 << 3;
pub const VIO_GPU_F_CONTEXT_INIT: u32 = 1 << 4;
/// `VIRTIO_GPU_CAPSET_VIRGL` / `_VIRGL2` — the virgl capability-set ids
/// `GET_CAPSET_INFO` indexes 0/1 map to on a virgl device.
pub const VIO_GPU_CAPSET_VIRGL: u32 = 1;
pub const VIO_GPU_CAPSET_VIRGL2: u32 = 2;
/// virgl execbuffer command header: `cmd_id | (obj_type << 8) | (len << 16)`
/// where `len` is the **body** dword count (excluding this header — the
/// decoder advances `len + 1` and reads body fields at `buf[1..]`;
/// `virgl_protocol.h` `VIRGL_CMD0`, `vrend_decode.c` submit loop). The
/// `ctx_id`/`ring` ride the `virtio_gpu_cmd_submit` header, not the stream.
pub const fn virgl_cmd0(cmd: u32, obj: u32, size: u32) -> u32 {
    (cmd & 0xff) | ((obj & 0xff) << 8) | ((size & 0xffff) << 16)
}
/// virgl object types (`virgl_object_type`) used by `CREATE_OBJECT`/
/// `BIND_OBJECT`.
pub const VIRGL_OBJ_BLEND: u32 = 1;
pub const VIRGL_OBJ_RASTERIZER: u32 = 2;
pub const VIRGL_OBJ_DSA: u32 = 3;
pub const VIRGL_OBJ_SHADER: u32 = 4;
pub const VIRGL_OBJ_VERTEX_ELEMENTS: u32 = 5;
pub const VIRGL_OBJ_SAMPLER_VIEW: u32 = 6;
pub const VIRGL_OBJ_SAMPLER_STATE: u32 = 7;
pub const VIRGL_OBJ_SURFACE: u32 = 8;
/// virgl command ids (`virgl_ccmd`) used by the bounded quad stream.
pub const VIRGL_CCMD_NOP: u32 = 0;
pub const VIRGL_CCMD_CREATE_OBJECT: u32 = 1;
pub const VIRGL_CCMD_BIND_OBJECT: u32 = 2;
pub const VIRGL_CCMD_DESTROY_OBJECT: u32 = 3;
pub const VIRGL_CCMD_SET_VIEWPORT_STATE: u32 = 4;
pub const VIRGL_CCMD_SET_FRAMEBUFFER_STATE: u32 = 5;
pub const VIRGL_CCMD_SET_VERTEX_BUFFERS: u32 = 6;
pub const VIRGL_CCMD_CLEAR: u32 = 7;
pub const VIRGL_CCMD_DRAW_VBO: u32 = 8;
pub const VIRGL_CCMD_RESOURCE_INLINE_WRITE: u32 = 9;
pub const VIRGL_CCMD_SET_SAMPLER_VIEWS: u32 = 10;
pub const VIRGL_CCMD_SET_SCISSOR_STATE: u32 = 15;
pub const VIRGL_CCMD_BIND_SAMPLER_STATES: u32 = 18;
pub const VIRGL_CCMD_BIND_SHADER: u32 = 31;
/// Pipe shader stages (`pipe_shader_type`) for `CREATE_OBJECT(SHADER)`/
/// `BIND_SHADER`: `PIPE_SHADER_VERTEX`/`PIPE_SHADER_FRAGMENT` — the wire
/// values are the mesa enum verbatim (`p_defines.h`: VERTEX=0,
/// FRAGMENT=1); a stage byte ≥ `PIPE_SHADER_TYPES` is rejected by
/// `vrend_decode_ctx` outright.
pub const VIRGL_SHADER_VERTEX: u32 = 0;
pub const VIRGL_SHADER_FRAGMENT: u32 = 1;
/// `PIPE_PRIM_*` draw modes for `DRAW_VBO`.
pub const VIRGL_PRIM_TRIANGLES: u32 = 4;
pub const VIRGL_PRIM_TRIANGLE_STRIP: u32 = 5;
/// `virtio_input_event` field values: `type` (Linux `EV_*`).
/// `InpDrain` queues `EV_KEY` into `__vio`'s bounded key queue (VGA
/// `DomNav`); `EV_ABS`/`EV_REL` are WebFeed (svelte-d pointer) and the
/// guest `TabDrain` pointer lane. `EV_SYN`/`SYN_REPORT` is a batch
/// delimiter — `TabDrain` no-ops it because the used-ring walk already
/// latches the whole packet before `DomtPtr`. The statusq (queue 1) is
/// unused — the guest is a passive consumer.
pub const VIO_INP_EV_SYN: u32 = 0;
/// Linux `EV_KEY`.
pub const VIO_INP_EV_KEY: u32 = 1;
/// Linux `EV_REL` — virtio-mouse deltas (`REL_X`/`REL_Y`/`REL_WHEEL`).
pub const VIO_INP_EV_REL: u32 = 2;
/// Linux `EV_ABS` — virtio-tablet axes (`ABS_X`/`ABS_Y`, 0..=`VIO_ABS_MAX`).
pub const VIO_INP_EV_ABS: u32 = 3;
/// Linux `SYN_REPORT` — end of one input packet (`code` of `EV_SYN`).
pub const VIO_SYN_REPORT: u32 = 0;
/// Device-configuration window — virtio-mmio `VIRTIO_MMIO_CONFIG` offset.
/// The virtio-input `virtio_input_config` view is `select@0, subsel@1,
/// size@2, data@8`: write `select`/`subsel`, read `size`/`data`.
pub const VIO_REG_CONFIG: i32 = 0x100;
/// `VIRTIO_INPUT_CFG_EV_BITS` — selects the per-event-type capability
/// bitmap; `subsel` is the `EV_*` type and `size != 0` means it is reported.
pub const VIO_INP_CFG_EV_BITS: u32 = 0x11;
/// `scause` exception codes for MMIO access faults — `trap_fault` treats
/// these inside a bounded probe window as "device absent" and resumes.
pub const SCAUSE_LOAD_ACCESS: u32 = 5;
/// Store/AMO access fault (Priv ch3 table).
pub const SCAUSE_STORE_ACCESS: u32 = 7;
/// `VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM` — X8R8G8B8 little-endian words.
pub const VIO_GPU_FMT_B8G8R8X8: u32 = 2;
/// Controlq depth (descriptors) and descriptor flag bits.
pub const VIO_QUEUE_NUM: i64 = 8;
pub const VIO_DESC_NEXT: u32 = 1;
pub const VIO_DESC_WRITE: u32 = 2;
/// Little-endian 4-char UART/HolyC command prefixes.
pub const CMD_VIEW: u32 = 0x7765_6956; // "View"
pub const CMD_REBO: u32 = 0x6f62_6552; // "Rebo"
pub const CMD_SHUT: u32 = 0x7475_6853; // "Shut"
pub const CMD_WAKE: u32 = 0x656b_6157; // "Wake"
pub const CMD_UI: u32 = 0x0000_6955; // "Ui\0\0"
pub const CMD_FILE: u32 = 0x656c_6946; // "File"
pub const CMD_GET: u32 = 0x0074_6547; // "Get\0"
/// `Blk` — read LBA 0/1 and report what the medium is, from the guest's own
/// virtio-blk driver rather than from a host-rendered page.
pub const CMD_BLK: u32 = u32::from_le_bytes(*b"Blk\n");
/// `Jrn` — load/commit the G6BH journal window (LBA 8), not a Linux boot.
pub const CMD_JRN: u32 = u32::from_le_bytes(*b"Jrn\n");
/// `Fws` — stage the inactive firmware slot (B). Not a slot switch, not autoboot.
pub const CMD_FWS: u32 = u32::from_le_bytes(*b"Fws\n");
/// `Lnx` — `LinuxLoadDisk` of the canary Image at LBA 40. Not autoboot.
pub const CMD_LNX: u32 = u32::from_le_bytes(*b"Lnx\n");
pub const CMD_KEYS: u32 = 0x7379_654b; // "Keys" — dump the virtio-input key queue
pub const CMD_AWAI: u32 = 0x6961_7741; // "Awai" — Await: claim a bounded pending slot
pub const CMD_THRO: u32 = 0x6f72_6854; // "Thro" — Throw: reject the newest pending await
/// SBI TIME extension id (`'TIME'`).
pub const SBI_TIME_EID: i64 = 0x5449_4d45;
/// QEMU virt / OpenSBI default timebase (Hz). Interval = TIMEBASE / fps.
pub const TIMEBASE_HZ: u64 = 10_000_000;
pub const VTYPE_E8_M1_TA_MA: u32 = 0xC0;
/// SBI `sbi_console_putchar` extension id (legacy).
pub const SBI_PUTCHAR: i64 = 1;
/// SBI SRST extension id (`'SRST'`).
pub const SBI_SRST_EID: i64 = 0x5352_5354;
/// SBI HSM extension id (`'HSM'`).
pub const SBI_HSM_EID: i64 = 0x0048_534d;
/// SBI IPI extension id (`'sPI'`).
pub const SBI_IPI_EID: i64 = 0x0073_5049;

pub fn lui(rd: u32, imm20: u32) -> u32 {
    (imm20 << 12) | (rd << 7) | 0x37
}

pub fn auipc(rd: u32, imm20: u32) -> u32 {
    (imm20 << 12) | (rd << 7) | 0x17
}

/// I/S-type immediates are 12-bit signed — trap silently-truncated offsets
/// (a `0x1000` step once encoded as `addi rd,rs,0` → an infinite rescan).
#[inline]
fn check_imm12(imm: i32) -> u32 {
    assert!(
        (-2048..=2047).contains(&imm),
        "imm12 out of range: {imm} (use li+add / la)"
    );
    (imm as u32) & 0xfff
}

pub fn addi(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (rd << 7) | 0x13
}

pub fn andi(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (0x7 << 12) | (rd << 7) | 0x13
}

pub fn lbu(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (0x4 << 12) | (rd << 7) | 0x03
}

pub fn lw(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x03
}

pub fn ld(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (0x3 << 12) | (rd << 7) | 0x03
}

pub fn sb(rs2: u32, rs1: u32, imm: i32) -> u32 {
    let imm = check_imm12(imm);
    ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | ((imm & 0x1f) << 7) | 0x23
}

pub fn sw(rs2: u32, rs1: u32, imm: i32) -> u32 {
    let imm = (imm as u32) & 0xfff;
    ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (0x2 << 12) | ((imm & 0x1f) << 7) | 0x23
}

pub fn sd(rs2: u32, rs1: u32, imm: i32) -> u32 {
    let imm = check_imm12(imm);
    ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (0x3 << 12) | ((imm & 0x1f) << 7) | 0x23
}

pub fn srli(rd: u32, rs1: u32, shamt: u32) -> u32 {
    (shamt << 20) | (rs1 << 15) | (0x5 << 12) | (rd << 7) | 0x13
}

pub fn slli(rd: u32, rs1: u32, shamt: u32) -> u32 {
    (shamt << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x13
}

pub fn add(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33
}

/// RV32M/RV64M `mul`.
pub fn mul(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (0x01 << 25) | (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33
}

/// RV32M/RV64M `divu` — unsigned divide, funct3=0b101.
pub fn divu(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (0x01 << 25) | (rs2 << 20) | (rs1 << 15) | (0x5 << 12) | (rd << 7) | 0x33
}

pub fn xor(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (rs2 << 20) | (rs1 << 15) | (0x4 << 12) | (rd << 7) | 0x33
}

/// `and rd, rs1, rs2` — register AND (JIT word building / wasm `i32.and`).
pub fn and_(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (rs2 << 20) | (rs1 << 15) | (0x7 << 12) | (rd << 7) | 0x33
}

/// `or rd, rs1, rs2`.
pub fn or_(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (rs2 << 20) | (rs1 << 15) | (0x6 << 12) | (rd << 7) | 0x33
}

/// `sll rd, rs1, rs2`.
pub fn sll(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (rs2 << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x33
}

/// `srl rd, rs1, rs2`.
pub fn srl(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (rs2 << 20) | (rs1 << 15) | (0x5 << 12) | (rd << 7) | 0x33
}

/// `sra rd, rs1, rs2` — arithmetic register shift.
pub fn sra(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (0x20 << 25) | (rs2 << 20) | (rs1 << 15) | (0x5 << 12) | (rd << 7) | 0x33
}

/// `slt rd, rs1, rs2` — signed compare (wasm `i32.lt_s` etc.).
pub fn slt(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (rs2 << 20) | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x33
}

/// `slti rd, rs1, imm`.
pub fn slti(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x13
}

/// `sltiu rd, rs1, imm` — `sltiu rd, rs, 1` is `seqz`.
pub fn sltiu(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (0x3 << 12) | (rd << 7) | 0x13
}

/// `srai rd, rs1, shamt` — arithmetic immediate shift (imm = 0x400|shamt).
pub fn srai(rd: u32, rs1: u32, shamt: u32) -> u32 {
    (((0x400 | (shamt & 0x3f)) & 0xfff) << 20) | (rs1 << 15) | (0x5 << 12) | (rd << 7) | 0x13
}

/// `div rd, rs1, rs2` — signed divide (M ext).
pub fn div(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (0x01 << 25) | (rs2 << 20) | (rs1 << 15) | (0x4 << 12) | (rd << 7) | 0x33
}

/// `rem rd, rs1, rs2` — signed remainder (M ext).
pub fn rem(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (0x01 << 25) | (rs2 << 20) | (rs1 << 15) | (0x6 << 12) | (rd << 7) | 0x33
}

/// `remu rd, rs1, rs2` — unsigned remainder (M ext).
pub fn remu(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (0x01 << 25) | (rs2 << 20) | (rs1 << 15) | (0x7 << 12) | (rd << 7) | 0x33
}

/// `blt rs1, rs2, off` — signed less-than branch (funct3 = 0b100).
pub fn blt(rs1: u32, rs2: u32, imm: i32) -> u32 {
    beq(rs1, rs2, imm) | (0x4 << 12)
}

/// `bge rs1, rs2, off` — signed greater-or-equal branch.
pub fn bge(rs1: u32, rs2: u32, imm: i32) -> u32 {
    beq(rs1, rs2, imm) | (0x5 << 12)
}

/// `bltu rs1, rs2, off` — unsigned less-than branch.
pub fn bltu(rs1: u32, rs2: u32, imm: i32) -> u32 {
    beq(rs1, rs2, imm) | (0x6 << 12)
}

/// `bgeu rs1, rs2, off` — unsigned greater-or-equal branch.
pub fn bgeu(rs1: u32, rs2: u32, imm: i32) -> u32 {
    beq(rs1, rs2, imm) | (0x7 << 12)
}

/// `lb rd, off(rs1)` — sign-extended byte load.
pub fn lb(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (rd << 7) | 0x03
}

/// `lh rd, off(rs1)` — sign-extended halfword load.
pub fn lh(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x03
}

/// `lhu rd, off(rs1)` — zero-extended halfword load.
pub fn lhu(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (0x5 << 12) | (rd << 7) | 0x03
}

/// `lwu rd, off(rs1)` — zero-extended word load (RV64 only).
pub fn lwu(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (0x6 << 12) | (rd << 7) | 0x03
}

/// `sh rs2, off(rs1)` — halfword store.
pub fn sh(rs2: u32, rs1: u32, imm: i32) -> u32 {
    let imm = (imm as u32) & 0xfff;
    ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (0x1 << 12) | ((imm & 0x1f) << 7) | 0x23
}

/// `fence.i` — instruction-fetch fence; required between guest codegen into
/// `__jit_code` and jumping to it (icache coherence, Priv "Zifencei").
pub fn fence_i() -> u32 {
    0x0000_100f
}

// ---- RV64 word ops (opcode OP-32 / OP-IMM-32): canonical sign-extended
// 32-bit results — what the guest JIT emits for wasm i32 ops on xlen=64.

fn op32(rd: u32, rs1: u32, rs2: u32, f3: u32, f7: u32) -> u32 {
    (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x3b
}

/// `addw rd, rs1, rs2` — 32-bit add, sign-extended result.
pub fn addw(rd: u32, rs1: u32, rs2: u32) -> u32 {
    op32(rd, rs1, rs2, 0, 0)
}

/// `subw rd, rs1, rs2`.
pub fn subw(rd: u32, rs1: u32, rs2: u32) -> u32 {
    op32(rd, rs1, rs2, 0, 0x20)
}

/// `mulw rd, rs1, rs2`.
pub fn mulw(rd: u32, rs1: u32, rs2: u32) -> u32 {
    op32(rd, rs1, rs2, 0, 1)
}

/// `sllw rd, rs1, rs2`.
pub fn sllw(rd: u32, rs1: u32, rs2: u32) -> u32 {
    op32(rd, rs1, rs2, 1, 0)
}

/// `srlw rd, rs1, rs2`.
pub fn srlw(rd: u32, rs1: u32, rs2: u32) -> u32 {
    op32(rd, rs1, rs2, 5, 0)
}

/// `sraw rd, rs1, rs2`.
pub fn sraw(rd: u32, rs1: u32, rs2: u32) -> u32 {
    op32(rd, rs1, rs2, 5, 0x20)
}

/// `divw rd, rs1, rs2`.
pub fn divw(rd: u32, rs1: u32, rs2: u32) -> u32 {
    op32(rd, rs1, rs2, 4, 1)
}

/// `divuw rd, rs1, rs2`.
pub fn divuw(rd: u32, rs1: u32, rs2: u32) -> u32 {
    op32(rd, rs1, rs2, 5, 1)
}

/// `remw rd, rs1, rs2`.
pub fn remw(rd: u32, rs1: u32, rs2: u32) -> u32 {
    op32(rd, rs1, rs2, 6, 1)
}

/// `remuw rd, rs1, rs2`.
pub fn remuw(rd: u32, rs1: u32, rs2: u32) -> u32 {
    op32(rd, rs1, rs2, 7, 1)
}

/// `addiw rd, rs1, imm`.
pub fn addiw(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (rd << 7) | 0x1b
}

/// `slliw rd, rs1, shamt` (5-bit shamt).
pub fn slliw(rd: u32, rs1: u32, shamt: u32) -> u32 {
    ((shamt & 0x1f) << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x1b
}

/// `srliw rd, rs1, shamt` (5-bit shamt).
pub fn srliw(rd: u32, rs1: u32, shamt: u32) -> u32 {
    ((shamt & 0x1f) << 20) | (rs1 << 15) | (0x5 << 12) | (rd << 7) | 0x1b
}

/// `sraiw rd, rs1, shamt` (imm = 0x400|shamt).
pub fn sraiw(rd: u32, rs1: u32, shamt: u32) -> u32 {
    (((0x400 | (shamt & 0x1f)) & 0xfff) << 20) | (rs1 << 15) | (0x5 << 12) | (rd << 7) | 0x1b
}

pub fn sub(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (0x20 << 25) | (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33
}

/// Scalar-FP R-type (opcode `0x53`, OP-FP): `funct7 rs2 rs1 funct3 rd 1010011`.
/// One encoder covers the whole f32/f64 surface — `fadd.s` (f7=0x00),
/// `fle.s` (f7=0x50,f3=0), `fcvt.s.wu` (f7=0x68,rs2=1), `fmv.w.x`
/// (f7=0x78,rs2=0,f3=0), etc.
pub fn fpr(funct7: u32, rs2: u32, rs1: u32, funct3: u32, rd: u32) -> u32 {
    ((funct7 & 0x7f) << 25)
        | ((rs2 & 0x1f) << 20)
        | ((rs1 & 0x1f) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1f) << 7)
        | 0x53
}

/// `sltu rd, rs1, rs2` — R-type, funct3=0b011.
pub fn sltu(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (rs2 << 20) | (rs1 << 15) | (0x3 << 12) | (rd << 7) | 0x33
}

pub fn beq(rs1: u32, rs2: u32, imm: i32) -> u32 {
    let imm = imm as u32;
    (((imm >> 12) & 1) << 31)
        | (((imm >> 5) & 0x3f) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (((imm >> 1) & 0xf) << 8)
        | (((imm >> 11) & 1) << 7)
        | 0x63
}

pub fn bne(rs1: u32, rs2: u32, imm: i32) -> u32 {
    beq(rs1, rs2, imm) | (1 << 12)
}

pub fn jal(rd: u32, imm: i32) -> u32 {
    let imm = imm as u32;
    (((imm >> 20) & 1) << 31)
        | (((imm >> 1) & 0x3ff) << 21)
        | (((imm >> 11) & 1) << 20)
        | (((imm >> 12) & 0xff) << 12)
        | (rd << 7)
        | 0x6f
}

pub fn jalr(rd: u32, rs1: u32, imm: i32) -> u32 {
    (((imm as u32) & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x67
}

pub fn csrrw(rd: u32, csr: u32, rs1: u32) -> u32 {
    (csr << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x73
}

pub fn csrrs(rd: u32, csr: u32, rs1: u32) -> u32 {
    (csr << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x73
}

pub fn csrrc(rd: u32, csr: u32, rs1: u32) -> u32 {
    (csr << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x73
}

pub fn ecall() -> u32 {
    0x0000_0073
}

pub fn wfi() -> u32 {
    0x1050_0073
}

pub fn sfence_vma() -> u32 {
    0x1200_0073
}

pub fn vsetvli(rd: u32, rs1: u32, vtype: u32) -> u32 {
    (vtype << 20) | (rs1 << 15) | (0x7 << 12) | (rd << 7) | 0x57
}

pub fn vle8(vd: u32, rs1: u32) -> u32 {
    (1 << 25) | (rs1 << 15) | (vd << 7) | 0x07
}

pub fn vse8(vs3: u32, rs1: u32) -> u32 {
    (1 << 25) | (rs1 << 15) | (vs3 << 7) | 0x27
}

pub fn hi_lo(addr: u64) -> (u32, i32) {
    let lo = (addr & 0xfff) as i32;
    let lo = if lo >= 0x800 { lo - 0x1000 } else { lo };
    let hi = ((addr.wrapping_add(0x800)) >> 12) as u32;
    (hi, lo)
}

pub fn fits12(imm: i64) -> bool {
    (-2048..=2047).contains(&imm)
}

pub fn li_nwords(imm: i64) -> usize {
    if fits12(imm) {
        1
    } else {
        2
    }
}

pub fn li_words(rd: u32, imm: i64) -> Vec<u32> {
    if fits12(imm) {
        vec![addi(rd, X0, imm as i32)]
    } else {
        let (hi, lo) = hi_lo(imm as u64);
        vec![lui(rd, hi), addi(rd, rd, lo)]
    }
}

pub fn reg_name(r: u32) -> &'static str {
    match r {
        0 => "zero",
        1 => "ra",
        2 => "sp",
        3 => "gp",
        4 => "tp",
        5 => "t0",
        6 => "t1",
        7 => "t2",
        8 => "s0",
        9 => "s1",
        10 => "a0",
        11 => "a1",
        12 => "a2",
        13 => "a3",
        14 => "a4",
        15 => "a5",
        16 => "a6",
        17 => "a7",
        18 => "s2",
        19 => "s3",
        20 => "s4",
        21 => "s5",
        22 => "s6",
        23 => "s7",
        24 => "s8",
        25 => "s9",
        26 => "s10",
        27 => "s11",
        28 => "t3",
        29 => "t4",
        30 => "t5",
        31 => "t6",
        _ => "x?",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addi_a0_x0_1() {
        assert_eq!(addi(A0, X0, 1), 0x0010_0513);
        assert_eq!(ecall(), 0x0000_0073);
        assert_eq!(csrrw(X0, CSR_STVEC, T2), 0x1053_9073);
    }

    #[test]
    fn cmd_words_are_le_ascii() {
        assert_eq!(CMD_VIEW, u32::from_le_bytes(*b"View"));
        assert_eq!(CMD_REBO, u32::from_le_bytes(*b"Rebo"));
        assert_eq!(CMD_SHUT, u32::from_le_bytes(*b"Shut"));
        assert_eq!(CMD_WAKE, u32::from_le_bytes(*b"Wake"));
        assert_eq!(CMD_UI, u32::from_le_bytes(*b"Ui\0\0"));
        assert_eq!(CMD_FILE, u32::from_le_bytes(*b"File"));
        assert_eq!(CMD_GET, u32::from_le_bytes(*b"Get\0"));
        assert_eq!(CMD_KEYS, u32::from_le_bytes(*b"Keys"));
        assert_eq!(CMD_AWAI, u32::from_le_bytes(*b"Awai"));
        assert_eq!(CMD_THRO, u32::from_le_bytes(*b"Thro"));
        assert_eq!(MBOX_RSP_UI, u32::from_le_bytes(*b"UI\n\0"));
        assert_eq!(MBOX_RSP_FILE, u32::from_le_bytes(*b"FILE"));
        assert_eq!(WASM_MAGIC, u32::from_le_bytes(*b"\0asm"));
    }

    #[test]
    fn li_sbi_srst_is_two_words() {
        assert_eq!(li_nwords(SBI_SRST_EID), 2);
        assert_eq!(li_nwords(SBI_PUTCHAR), 1);
        let w = li_words(A7, SBI_SRST_EID);
        assert_eq!(w.len(), 2);
    }

    #[test]
    fn srli_scause_interrupt_bit_rv64() {
        // srli t2, t0, 63 — isolate scause[63] (Priv ch3 interrupt bit).
        assert_eq!(srli(T2, T0, 63), 0x03f2_d393);
        assert_eq!(CSR_TIME, 0xC01);
    }
}
