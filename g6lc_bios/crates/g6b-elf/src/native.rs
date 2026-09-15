// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use g6b_asm::encode::{A0, A7, CSR_SIE, RA, SBI_PUTCHAR, SP, T0, T1, T2, T3, X0};
use g6b_asm::AUTO_ON_OFF;
use g6b_asm::{Addr, Node, Op, Purpose};
use g6b_runtime_abi::{
    Operation, Request, Response, Span, Status, BOOT_CONTEXT, CAPABILITIES_BYTES, CORE_OFFSET,
    INPUT_BYTES, IRQ_SLOW, IRQ_WATCHDOG, NATIVE_FRAME_BYTES, PAYLOAD_OFFSET, POLL_FLAG_WATCHDOG,
    POLL_REPORT_BYTES, REQUEST_BYTES, RESPONSE_BYTES, RESPONSE_OFFSET,
};
use g6b_spec::{BoardSpec, ExtStatus, Json};
use std::path::Path;

const PAGE: usize = 4096;
const LIMIT: usize = 16 * 1024 * 1024;

#[derive(Debug)]
struct Segment {
    address: u64,
    flags: u32,
    bytes: Vec<u8>,
}

#[derive(Debug)]
pub struct Image {
    entry: u64,
    segments: Vec<Segment>,
}

fn take(data: &[u8], at: usize, len: usize) -> Result<&[u8], String> {
    data.get(at..at.checked_add(len).ok_or("native extent overflow")?)
        .ok_or_else(|| "truncated native extent".into())
}

fn u16_at(data: &[u8], at: usize) -> Result<u16, String> {
    Ok(u16::from_le_bytes(take(data, at, 2)?.try_into().unwrap()))
}

fn u32_at(data: &[u8], at: usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(take(data, at, 4)?.try_into().unwrap()))
}

fn u64_at(data: &[u8], at: usize) -> Result<u64, String> {
    Ok(u64::from_le_bytes(take(data, at, 8)?.try_into().unwrap()))
}

fn read_bounded(path: &Path, limit: usize) -> Result<Vec<u8>, String> {
    use std::io::Read;
    let file = std::fs::File::open(path).map_err(|error| error.to_string())?;
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() > limit {
        return Err("native file exceeds byte limit".into());
    }
    Ok(bytes)
}

fn check_json_depth(bytes: &[u8]) -> Result<(), String> {
    let (mut depth, mut quoted, mut escaped) = (0usize, false, false);
    for &byte in bytes {
        if quoted {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                quoted = false;
            }
        } else {
            match byte {
                b'"' => quoted = true,
                b'{' | b'[' => {
                    depth += 1;
                    if depth > 16 {
                        return Err("native manifest nesting exceeds bound".into());
                    }
                }
                b'}' | b']' => {
                    depth = depth
                        .checked_sub(1)
                        .ok_or("native manifest unbalanced nesting")?
                }
                _ => {}
            }
        }
    }
    if depth != 0 || quoted {
        return Err("native manifest is incomplete".into());
    }
    Ok(())
}

fn number(json: &Json, name: &str) -> Result<u64, String> {
    match json.get(name) {
        Json::Int(value) if *value >= 0 => Ok(*value as u64),
        _ => Err(format!("invalid native manifest field {name}")),
    }
}

impl Image {
    pub fn parse(data: &[u8]) -> Result<Self, String> {
        if data.len() > LIMIT
            || take(data, 0, 7)? != b"\x7fELF\x02\x01\x01"
            || take(data, 7, 9)?.iter().any(|&b| b != 0)
        {
            return Err("native service requires bounded ELF64 LE SYSV".into());
        }
        if u16_at(data, 16)? != 2
            || u16_at(data, 18)? != 243
            || u32_at(data, 20)? != 1
            || u32_at(data, 48)? & !1 != 0
            || u16_at(data, 52)? != 64
            || u16_at(data, 54)? != 56
        {
            return Err("unsupported native ELF header or calling convention".into());
        }
        let count = usize::from(u16_at(data, 56)?);
        if count == 0 || count > 16 {
            return Err("native segment count exceeds bound".into());
        }
        let phoff = usize::try_from(u64_at(data, 32)?).map_err(|_| "native phoff overflow")?;
        take(data, phoff, count * 56)?;
        let mut segments = Vec::new();
        for index in 0..count {
            let header = take(data, phoff + index * 56, 56)?;
            let kind = u32_at(header, 0)?;
            // PT_NULL / NOTE / PHDR / GNU_STACK / RISCV_ATTRIBUTES carry no
            // loadable image. DYNAMIC/INTERP/TLS/RELRO stay refused.
            if matches!(kind, 0 | 4 | 6 | 0x6474_e551 | 0x7000_0003) {
                continue;
            }
            if kind != 1 {
                return Err("native service must have only static load segments".into());
            }
            let flags = u32_at(header, 4)?;
            let offset = u64_at(header, 8)?;
            let address = u64_at(header, 16)?;
            let size = u64_at(header, 32)?;
            let memory = u64_at(header, 40)?;
            if memory == 0 {
                continue;
            }
            if !matches!(flags, 4 | 5)
                || size != memory
                || size > LIMIT as u64
                || u64_at(header, 24)? != address
                || u64_at(header, 48)? != PAGE as u64
                || address % PAGE as u64 != 0
                || offset % PAGE as u64 != 0
            {
                return Err(
                    "native callee allows only page-aligned RX/R file-backed segments (no RW/BSS/WX)".into(),
                );
            }
            address.checked_add(size).ok_or("native address overflow")?;
            let offset = usize::try_from(offset).map_err(|_| "native file offset overflow")?;
            let bytes = take(data, offset, size as usize)?.to_vec();
            segments.push(Segment {
                address,
                flags,
                bytes,
            });
        }
        segments.sort_by_key(|segment| segment.address);
        if segments.is_empty() {
            return Err("native image has no loadable content".into());
        }
        for pair in segments.windows(2) {
            if pair[0].address + pair[0].bytes.len() as u64 > pair[1].address {
                return Err("overlapping native segments".into());
            }
        }
        let first = segments.first().unwrap();
        let last = segments.last().unwrap();
        if last.address + last.bytes.len() as u64 - first.address > LIMIT as u64 {
            return Err("native memory span exceeds bound".into());
        }
        let entry = u64_at(data, 24)?;
        if entry % 2 != 0
            || !segments.iter().any(|segment| {
                segment.flags == 5
                    && entry >= segment.address
                    && entry < segment.address + segment.bytes.len() as u64
            })
        {
            return Err("native entry is not file-backed executable code".into());
        }
        Ok(Self { entry, segments })
    }

    pub fn load_manifest(path: &Path) -> Result<Self, String> {
        let bytes = read_bounded(path, 16 * 1024)?;
        check_json_depth(&bytes)?;
        let json = g6b_spec::parse_json(
            std::str::from_utf8(&bytes).map_err(|_| "native manifest UTF-8")?,
        )?;
        if json.get("target").as_str() != Some("riscv64imac-unknown-none-elf")
            || number(&json, "abi_version")? != 1
            || number(&json, "frame_bytes")? != NATIVE_FRAME_BYTES as u64
            || json.get("role").as_str() != Some("native-service-callee-not-bootable-firmware")
        {
            return Err("native manifest ABI/target mismatch".into());
        }
        let hash = json
            .get("sha256")
            .as_str()
            .ok_or("native manifest has no digest")?;
        if hash.len() != 64
            || !hash
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err("invalid native image digest".into());
        }
        let name = format!("g6b-native-{hash}.elf");
        if json.get("image").as_str() != Some(name.as_str()) {
            return Err("native image name must match its content digest".into());
        }
        let data = read_bounded(&path.with_file_name(name), LIMIT)?;
        if data.len() > LIMIT || g6b_tls::sha256_hex(&data) != hash {
            return Err("native image extent/digest mismatch".into());
        }
        let image = Self::parse(&data)?;
        if image.entry != number(&json, "entry")?
            || image.segments[0].address != number(&json, "load_address")?
        {
            return Err("native manifest does not match ELF addresses".into());
        }
        Ok(image)
    }
}

fn marker(ops: &mut Vec<Op>, text: &str) {
    for byte in text.bytes() {
        ops.extend([
            Op::Li {
                rd: A0,
                imm: i64::from(byte),
            },
            Op::Li {
                rd: A7,
                imm: SBI_PUTCHAR,
            },
            Op::Ecall,
        ]);
    }
}

fn guest_mask() -> u32 {
    (1u32 << Operation::Capabilities as u16)
        | (1 << Operation::BootStatus as u16)
        | (1 << Operation::BootTrial as u16)
        | (1 << Operation::Poll as u16)
        | (1 << Operation::Cancel as u16)
        | (1 << Operation::Input as u16)
}

fn write_words(ops: &mut Vec<Op>, off: i32, bytes: &[u8]) {
    write_words_at(ops, SP, off, bytes);
}

fn write_words_at(ops: &mut Vec<Op>, rs: u32, off: i32, bytes: &[u8]) {
    for (index, word) in bytes.chunks_exact(4).enumerate() {
        ops.extend([
            Op::Li {
                rd: T0,
                imm: i64::from(u32::from_le_bytes(word.try_into().unwrap())),
            },
            Op::Sw {
                rs2: T0,
                rs1: rs,
                off: off + index as i32 * 4,
            },
        ]);
    }
}

fn clear_header(ops: &mut Vec<Op>) {
    for offset in (0..REQUEST_BYTES + RESPONSE_BYTES).step_by(4) {
        ops.push(Op::Sw {
            rs2: X0,
            rs1: SP,
            off: offset as i32,
        });
    }
}

fn jalr_expect(ops: &mut Vec<Op>, entry: u64, status: u32) {
    ops.extend([
        Op::Addi {
            rd: A0,
            rs: SP,
            imm: 0,
        },
        Op::La {
            rd: T0,
            addr: Addr::Abs(entry),
        },
        Op::FenceI,
        Op::Jalr {
            rd: RA,
            rs: T0,
            imm: 0,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(status),
        },
        Op::Bne {
            rs1: A0,
            rs2: T1,
            to: "native_probe_fail".into(),
        },
    ]);
}

fn issue(ops: &mut Vec<Op>, entry: u64, request: Request, payload: &[u8]) {
    issue_status(ops, entry, request, payload, 0);
}

fn issue_status(ops: &mut Vec<Op>, entry: u64, request: Request, payload: &[u8], status: u32) {
    clear_header(ops);
    write_words(ops, 0, &request.encode());
    if !payload.is_empty() {
        write_words(ops, PAYLOAD_OFFSET as i32, payload);
    }
    jalr_expect(ops, entry, status);
}

fn probe(entry: u64) -> Node {
    let mut cap = [0u8; CAPABILITIES_BYTES];
    cap[..2].copy_from_slice(&g6b_runtime_abi::ABI_VERSION.to_le_bytes());
    cap[4..8].copy_from_slice(&(REQUEST_BYTES as u32).to_le_bytes());
    cap[8..12].copy_from_slice(&(NATIVE_FRAME_BYTES as u32).to_le_bytes());
    cap[12..16].copy_from_slice(&guest_mask().to_le_bytes());
    let mut ops = vec![
        Op::Label("native_probe".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -272,
        },
        Op::Sd {
            rs2: RA,
            rs1: SP,
            off: 256,
        },
        Op::Csrrw {
            rd: T0,
            csr: CSR_SIE,
            rs: X0,
        },
        Op::Sd {
            rs2: T0,
            rs1: SP,
            off: 264,
        },
    ];
    for offset in (0..NATIVE_FRAME_BYTES).step_by(4) {
        ops.push(Op::Sw {
            rs2: X0,
            rs1: SP,
            off: offset as i32,
        });
    }
    issue(
        &mut ops,
        entry,
        Request {
            operation: Operation::Capabilities,
            request_id: 1,
            context: BOOT_CONTEXT,
            input: Span::default(),
            output: Span {
                address: PAYLOAD_OFFSET as u64,
                length: CAPABILITIES_BYTES as u64,
            },
        },
        &[],
    );
    let response = Response {
        request_id: 1,
        status: Status::Ok,
        written: CAPABILITIES_BYTES as u32,
    }
    .encode();
    let mut expected = response.to_vec();
    expected.extend_from_slice(&cap);
    for (index, word) in expected.chunks_exact(4).enumerate() {
        ops.extend([
            Op::Lw {
                rd: T0,
                rs: SP,
                off: RESPONSE_OFFSET as i32 + index as i32 * 4,
            },
            Op::Li {
                rd: T1,
                imm: i64::from(i32::from_le_bytes(word.try_into().unwrap())),
            },
            Op::Bne {
                rs1: T0,
                rs2: T1,
                to: "native_probe_fail".into(),
            },
        ]);
    }
    marker(&mut ops, "NATIVE-SERVICE-OK\n");
    let mut watchdog = [0u8; INPUT_BYTES];
    watchdog[..4].copy_from_slice(&IRQ_WATCHDOG.to_le_bytes());
    watchdog[4..8].copy_from_slice(&1u32.to_le_bytes());
    issue(
        &mut ops,
        entry,
        Request {
            operation: Operation::Input,
            request_id: 2,
            context: BOOT_CONTEXT,
            input: Span {
                address: PAYLOAD_OFFSET as u64,
                length: INPUT_BYTES as u64,
            },
            output: Span::default(),
        },
        &watchdog,
    );
    let mut slow = [0u8; INPUT_BYTES];
    slow[..4].copy_from_slice(&IRQ_SLOW.to_le_bytes());
    slow[4..8].copy_from_slice(&8u32.to_le_bytes());
    issue(
        &mut ops,
        entry,
        Request {
            operation: Operation::Input,
            request_id: 3,
            context: BOOT_CONTEXT,
            input: Span {
                address: PAYLOAD_OFFSET as u64,
                length: INPUT_BYTES as u64,
            },
            output: Span::default(),
        },
        &slow,
    );
    ops.extend([
        Op::Ld {
            rd: T0,
            rs: SP,
            off: 264,
        },
        Op::Csrrw {
            rd: X0,
            csr: CSR_SIE,
            rs: T0,
        },
    ]);
    issue(
        &mut ops,
        entry,
        Request {
            operation: Operation::Poll,
            request_id: 4,
            context: BOOT_CONTEXT,
            input: Span::default(),
            output: Span {
                address: PAYLOAD_OFFSET as u64,
                length: POLL_REPORT_BYTES as u64,
            },
        },
        &[],
    );
    ops.extend([
        Op::Lw {
            rd: T0,
            rs: SP,
            off: PAYLOAD_OFFSET as i32 + 12,
        },
        Op::Andi {
            rd: T0,
            rs: T0,
            imm: POLL_FLAG_WATCHDOG as i32,
        },
        Op::Beq {
            rs1: T0,
            rs2: X0,
            to: "native_probe_fail".into(),
        },
    ]);
    marker(&mut ops, "NATIVE-POLL-OK\n");
    issue_status(
        &mut ops,
        entry,
        Request {
            operation: Operation::BootStatus,
            request_id: 5,
            context: BOOT_CONTEXT,
            input: Span::default(),
            output: Span::default(),
        },
        &[],
        Status::NotReady as u32,
    );
    issue_status(
        &mut ops,
        entry,
        Request {
            operation: Operation::BootTrial,
            request_id: 6,
            context: BOOT_CONTEXT,
            input: Span::default(),
            output: Span::default(),
        },
        &[],
        Status::NotReady as u32,
    );
    ops.extend([
        Op::La {
            rd: T1,
            addr: Addr::UartLine,
        },
        Op::Sw {
            rs2: X0,
            rs1: T1,
            off: AUTO_ON_OFF,
        },
    ]);
    marker(&mut ops, "NATIVE-BOOT-HOLD\n");
    ops.extend([
        Op::La {
            rd: T0,
            addr: Addr::NativeAbi,
        },
        Op::Addi {
            rd: T1,
            rs: SP,
            imm: 0,
        },
        Op::Li {
            rd: T2,
            imm: (NATIVE_FRAME_BYTES / 8) as i64,
        },
        Op::Label("native_abi_copy".into()),
        Op::Ld {
            rd: T3,
            rs: T1,
            off: 0,
        },
        Op::Sd {
            rs2: T3,
            rs1: T0,
            off: 0,
        },
        Op::Addi {
            rd: T0,
            rs: T0,
            imm: 8,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 8,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: -1,
        },
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: "native_abi_copy".into(),
        },
    ]);
    ops.push(Op::Jal {
        rd: X0,
        to: "native_probe_done".into(),
    });
    ops.push(Op::Label("native_probe_fail".into()));
    marker(&mut ops, "NATIVE-SERVICE-FAIL\n");
    ops.extend([
        Op::Label("native_probe_failed_park".into()),
        Op::Wfi,
        Op::Jal {
            rd: X0,
            to: "native_probe_failed_park".into(),
        },
        Op::Label("native_probe_done".into()),
        Op::Ld {
            rd: T0,
            rs: SP,
            off: 264,
        },
        Op::Csrrw {
            rd: X0,
            csr: CSR_SIE,
            rs: T0,
        },
        Op::Ld {
            rd: RA,
            rs: SP,
            off: 256,
        },
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 272,
        },
    ]);
    Node {
        purpose: Purpose::NativeService,
        ops,
    }
}

/// `trap_timer` calls this after park. Magic-gates on the durable frame
/// copied by the boot probe; SIE stays masked (already in trap).
fn tick_poll(entry: u64) -> Node {
    const CORE_MAGIC: u32 = 0x4353_3647;
    const TICK_FLAG_OFF: i32 = (PAYLOAD_OFFSET + POLL_REPORT_BYTES) as i32;
    let request = Request {
        operation: Operation::Poll,
        request_id: 7,
        context: BOOT_CONTEXT,
        input: Span::default(),
        output: Span {
            address: PAYLOAD_OFFSET as u64,
            length: POLL_REPORT_BYTES as u64,
        },
    };
    let mut ops = vec![
        Op::Label("NativePoll".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        Op::Sd {
            rs2: RA,
            rs1: SP,
            off: 0,
        },
        Op::La {
            rd: T1,
            addr: Addr::NativeAbi,
        },
        Op::Lw {
            rd: T0,
            rs: T1,
            off: CORE_OFFSET as i32,
        },
        Op::Li {
            rd: T2,
            imm: i64::from(CORE_MAGIC),
        },
        Op::Bne {
            rs1: T0,
            rs2: T2,
            to: "native_tick_done".into(),
        },
        Op::Addi {
            rd: A0,
            rs: T1,
            imm: 0,
        },
    ];
    for offset in (0..REQUEST_BYTES + RESPONSE_BYTES).step_by(4) {
        ops.push(Op::Sw {
            rs2: X0,
            rs1: A0,
            off: offset as i32,
        });
    }
    write_words_at(&mut ops, A0, 0, &request.encode());
    ops.extend([
        Op::La {
            rd: T0,
            addr: Addr::Abs(entry),
        },
        Op::FenceI,
        Op::Jalr {
            rd: RA,
            rs: T0,
            imm: 0,
        },
        Op::Bne {
            rs1: A0,
            rs2: X0,
            to: "native_tick_done".into(),
        },
        Op::La {
            rd: T0,
            addr: Addr::NativeAbi,
        },
        Op::Lw {
            rd: T1,
            rs: T0,
            off: TICK_FLAG_OFF,
        },
        Op::Bne {
            rs1: T1,
            rs2: X0,
            to: "native_tick_done".into(),
        },
        Op::Li { rd: T1, imm: 1 },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: TICK_FLAG_OFF,
        },
    ]);
    marker(&mut ops, "NATIVE-TICK-POLL-OK\n");
    ops.extend([
        Op::Label("native_tick_done".into()),
        Op::Ld {
            rd: RA,
            rs: SP,
            off: 0,
        },
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 16,
        },
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
    ]);
    Node {
        purpose: Purpose::NativeService,
        ops,
    }
}

pub fn compose_module(
    spec: &BoardSpec,
    volumes: Option<g6b_kernel::DirVolumes>,
    image: &Image,
) -> Result<g6b_asm::Module, String> {
    let base_isa = spec.isa.march.split('_').next().unwrap_or("");
    if spec.isa.xlen != 64
        || spec.isa.c != ExtStatus::Live
        || !(base_isa.contains('g') || ['i', 'm', 'a'].iter().all(|c| base_isa.contains(*c)))
    {
        return Err("native service bootstrap requires RV64IMAC".into());
    }
    let text = super::payload_text_with(spec, Some(volumes.unwrap_or_default()));
    let mut module = super::payload_module(spec, &text)?;
    let park = module
        .nodes
        .iter()
        .position(|node| node.purpose == Purpose::Park)
        .ok_or("native service needs a boot park boundary")?;
    module.nodes.insert(park, probe(image.entry));
    let tick = module
        .nodes
        .iter()
        .position(|node| {
            node.ops
                .iter()
                .any(|op| matches!(op, Op::Label(label) if label == "NativePoll"))
        })
        .ok_or("native tick poll stub missing")?;
    module.nodes[tick] = tick_poll(image.entry);
    module.native_bytes = NATIVE_FRAME_BYTES as u64;
    Ok(module)
}

pub fn build(
    spec: &BoardSpec,
    volumes: Option<g6b_kernel::DirVolumes>,
    image: &Image,
) -> Result<Vec<u8>, String> {
    let entry = super::load_addr(spec)?;
    let module = compose_module(spec, volumes, image)?;
    let (words, rodata) = module.to_words(entry)?;
    let mut payload: Vec<u8> = words.iter().flat_map(|word| word.to_le_bytes()).collect();
    payload.extend_from_slice(&rodata);
    let memory = g6b_asm::payload_memsz(payload.len() as u64, module.n_harts(), module.extra_bss());
    let end = entry.checked_add(memory).ok_or("BIOS memory overflow")?;
    let dram_base = super::parse_hex(&spec.dram_base)?;
    let dram_end = dram_base
        .checked_add(super::parse_hex(&spec.dram_len)?)
        .ok_or("DRAM overflow")?;
    if entry < dram_base || end > dram_end || image.segments.is_empty() {
        return Err("BIOS/native image does not fit DRAM".into());
    }
    for segment in &image.segments {
        let native_end = segment
            .address
            .checked_add(segment.bytes.len() as u64)
            .ok_or("native memory overflow")?;
        if segment.address < end
            || native_end > dram_end
            || segment.address.abs_diff(entry) >= 0x7fff_0000
        {
            return Err("native service overlaps BIOS/reserved low memory or exceeds DRAM/PC-relative range".into());
        }
    }
    let legacy = super::pack_elf(true, entry, &payload, module.n_harts(), module.extra_bss())?;
    let count = 1 + image.segments.len();
    let header_end = 64 + count * 56;
    let file_offset = header_end.div_ceil(PAGE) * PAGE;
    let mut out = vec![0; file_offset];
    out[..64].copy_from_slice(&legacy[..64]);
    super::write_u16(&mut out, 56, count as u16);
    super::write_u32(&mut out, 48, 1);
    let mut put_header = |index: usize,
                          offset: usize,
                          address: u64,
                          size: usize,
                          mem: u64,
                          flags: u32,
                          align: u64| {
        let at = 64 + index * 56;
        super::write_u32(&mut out, at, 1);
        super::write_u32(&mut out, at + 4, flags);
        for (off, value) in [
            (8, offset as u64),
            (16, address),
            (24, address),
            (32, size as u64),
            (40, mem),
            (48, align),
        ] {
            super::write_u64(&mut out, at + off, value);
        }
    };
    put_header(0, file_offset, entry, payload.len(), memory, 7, 16);
    let mut next_offset = (file_offset + payload.len()).div_ceil(PAGE) * PAGE;
    for (index, segment) in image.segments.iter().enumerate() {
        put_header(
            index + 1,
            next_offset,
            segment.address,
            segment.bytes.len(),
            segment.bytes.len() as u64,
            segment.flags,
            PAGE as u64,
        );
        next_offset = (next_offset + segment.bytes.len()).div_ceil(PAGE) * PAGE;
    }
    out.extend_from_slice(&payload);
    for segment in &image.segments {
        out.resize(out.len().div_ceil(PAGE) * PAGE, 0);
        out.extend_from_slice(&segment.bytes);
    }
    Ok(out)
}

pub fn write_elf(
    spec: &BoardSpec,
    path: &Path,
    volumes: Option<g6b_kernel::DirVolumes>,
    manifest: &Path,
) -> Result<(), String> {
    let image = Image::load_manifest(manifest)?;
    let bytes = build(spec, volumes, &image)?;
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    std::fs::write(path, bytes).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(address: u64) -> Vec<u8> {
        let mut bytes = vec![0; PAGE + 4];
        bytes[..7].copy_from_slice(b"\x7fELF\x02\x01\x01");
        for (at, value) in [(16, 2), (18, 243), (52, 64), (54, 56), (56, 1)] {
            super::super::write_u16(&mut bytes, at, value);
        }
        super::super::write_u32(&mut bytes, 20, 1);
        super::super::write_u64(&mut bytes, 24, address);
        super::super::write_u64(&mut bytes, 32, 64);
        super::super::write_u32(&mut bytes, 64, 1);
        super::super::write_u32(&mut bytes, 68, 5);
        for (at, value) in [
            (72, PAGE as u64),
            (80, address),
            (88, address),
            (96, 4),
            (104, 4),
            (112, PAGE as u64),
        ] {
            super::super::write_u64(&mut bytes, at, value);
        }
        bytes[PAGE..].copy_from_slice(&[0x67, 0x80, 0, 0]);
        bytes
    }

    #[test]
    fn riscv_attribute_phdrs_are_ignored() {
        let base = image(0x8400_0000);
        let mut bytes = base.clone();
        bytes.extend_from_slice(&[0; 64]);
        super::super::write_u16(&mut bytes, 56, 2);
        let at = 64 + 56;
        super::super::write_u32(&mut bytes, at, 0x7000_0003);
        super::super::write_u32(&mut bytes, at + 4, 4);
        super::super::write_u64(&mut bytes, at + 8, 0);
        super::super::write_u64(&mut bytes, at + 32, 16);
        super::super::write_u64(&mut bytes, at + 40, 16);
        let parsed = Image::parse(&bytes).unwrap();
        assert_eq!(parsed.segments.len(), 1);
        assert_eq!(parsed.entry, 0x8400_0000);
    }

    #[test]
    fn native_import_rejects_rw_bss_and_wx_segments() {
        let mut rw = image(0x8400_0000);
        super::super::write_u32(&mut rw, 68, 6);
        assert!(Image::parse(&rw).is_err());
        let mut bss = image(0x8400_0000);
        super::super::write_u64(&mut bss, 104, 8);
        assert!(Image::parse(&bss).is_err());
        let mut wx = image(0x8400_0000);
        super::super::write_u32(&mut wx, 68, 7);
        assert!(Image::parse(&wx).is_err());
    }

    #[test]
    fn native_import_rejects_wrong_machine_writable_code_and_truncation() {
        for (at, value) in [(18, 62), (68, 7), (64, 2), (7, 3)] {
            let mut bytes = image(0x8400_0000);
            bytes[at] = value;
            assert!(Image::parse(&bytes).is_err());
        }
        let bytes = image(0x8400_0000);
        for size in [0, 6, 63, 119, PAGE, PAGE + 3] {
            assert!(Image::parse(&bytes[..size]).is_err());
        }
        let valid = Image::parse(&bytes).unwrap();
        assert_eq!(valid.entry, 0x8400_0000);
        assert_eq!(valid.segments.len(), 1);
    }

    #[test]
    fn native_composition_keeps_separate_load_segments_and_checks_dram() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64,"march":"rv64imac","extensions":{"c":"live"}},"kernel":{"cli":{"enable":false}}}"#,
        )
        .unwrap();
        let native = Image::parse(&image(0x8400_0000)).unwrap();
        let elf = build(&spec, None, &native).unwrap();
        assert_eq!(u16_at(&elf, 56).unwrap(), 2);
        assert_eq!(
            u64_at(&elf, 24).unwrap(),
            super::super::load_addr(&spec).unwrap()
        );
        assert_eq!(u64_at(&elf, 136).unwrap(), native.entry);
        assert_eq!(u32_at(&elf, 124).unwrap(), 5);
        assert_ne!(
            u64_at(&elf, 24).unwrap(),
            native.entry,
            "composed ELF entry must stay the BIOS, not the callee"
        );
        let overlapping = Image::parse(&image(super::super::load_addr(&spec).unwrap())).unwrap();
        assert!(build(&spec, None, &overlapping).is_err());
        let outside = Image::parse(&image(0xf000_0000)).unwrap();
        assert!(build(&spec, None, &outside).is_err());
    }

    fn guest_dispatch(frame: &mut [u8; NATIVE_FRAME_BYTES]) -> u32 {
        g6b_guest::native_entry(frame)
    }

    #[test]
    fn native_tick_poll_after_park_runs_once() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64,"march":"rv64imac","extensions":{"c":"live"}},"kernel":{"cli":{"enable":false}}}"#,
        )
        .unwrap();
        let native = Image::parse(&image(0x8400_0000)).unwrap();
        let module = compose_module(&spec, None, &native).unwrap();
        assert_eq!(module.native_bytes, NATIVE_FRAME_BYTES as u64);
        let entry = super::super::load_addr(&spec).unwrap();
        let smoke = g6b_asm::exec::run_module_native(
            &spec,
            &module,
            entry,
            g6b_asm::exec::NativeHook {
                entry: native.entry,
                dispatch: guest_dispatch,
            },
        )
        .unwrap();
        assert!(
            smoke.console.contains("NATIVE-SERVICE-OK"),
            "{}",
            smoke.console
        );
        assert!(
            smoke.console.contains("NATIVE-POLL-OK"),
            "{}",
            smoke.console
        );
        assert!(
            smoke.console.contains("NATIVE-BOOT-HOLD"),
            "{}",
            smoke.console
        );
        assert!(
            smoke.console.contains("NATIVE-TICK-POLL-OK"),
            "{}",
            smoke.console
        );
        assert_eq!(
            smoke.console.matches("NATIVE-TICK-POLL-OK").count(),
            1,
            "{}",
            smoke.console
        );
        assert!(smoke.ticks >= 1, "ticks={}", smoke.ticks);
        assert!(
            !smoke.console.contains("NATIVE-SERVICE-FAIL"),
            "{}",
            smoke.console
        );
    }

    #[test]
    fn manifest_nesting_is_bounded_before_json_parse() {
        assert!(check_json_depth(br#"{"a":[{"x":"[{}]"}]}"#).is_ok());
        assert!(check_json_depth(b"[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]").is_err());
        assert!(check_json_depth(b"{\"").is_err());
        assert!(check_json_depth(b"]").is_err());
    }
}
