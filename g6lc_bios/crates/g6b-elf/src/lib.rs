// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Host-generated RISC-V ELF for OpenSBI `-kernel` (B9).
//!
//! Start sequence is the rewrite of `kernel-spec/ZealOS/src/Kernel/KStart64.ZC`
//! / `TempleOS/Kernel/KStart64.HC`. Words come from `g6b-asm` after
//! `analyze::payload` tags BoardSpec objects (hart, stack, stvec, UART1, memcpy).
//! No rustc riscv target and no crates.io; the image is lowered here.

#![allow(missing_docs)]

use g6b_asm::payload_memsz;
use g6b_spec::BoardSpec;

const EM_RISCV: u16 = 0x00f3;
const ET_EXEC: u16 = 2;
const PT_LOAD: u32 = 1;
/// Single address-space payload (TempleOS intent): one RWX load, stack in BSS.
const PF_RWX: u32 = 7;

/// Load address: `dram_base + text_offset` (OpenSBI next stage).
pub fn load_addr(spec: &BoardSpec) -> Result<u64, String> {
    let base = parse_hex(&spec.dram_base)?;
    let off = parse_hex(&spec.text_offset)?;
    Ok(base.wrapping_add(off))
}

/// Build an ET_EXEC RISC-V ELF (32 or 64 from BoardSpec).
pub fn build(spec: &BoardSpec) -> Result<Vec<u8>, String> {
    let entry = load_addr(spec)?;
    if spec.isa.xlen == 32 && entry > u32::MAX as u64 {
        return Err("rv32 load address does not fit in 32 bits".into());
    }
    let text = payload_text(spec);
    let (code, nharts, gr_bytes) = assemble(spec, entry, &text)?;
    match spec.isa.xlen {
        32 => pack_elf(false, entry as u32 as u64, &code, nharts, gr_bytes),
        64 => pack_elf(true, entry, &code, nharts, gr_bytes),
        x => Err(format!("unsupported xlen {x}")),
    }
}

fn payload_text(spec: &BoardSpec) -> Vec<u8> {
    let mut s = String::from_utf8(g6b_asm::analyze::kstart_msg(spec)).unwrap_or_default();
    while s.ends_with('\0') {
        s.pop();
    }
    if !s.ends_with('\n') {
        s.push('\n');
    }
    s.push_str(if spec.rvv_live() {
        "ISEL-RVV\n"
    } else {
        "ISEL-SCALAR\n"
    });
    s.push_str(&g6b_kernel::boot(spec));
    if !s.ends_with('\n') {
        s.push('\n');
    }
    let mut b = s.into_bytes();
    b.push(0);
    b
}

/// KStart64 rewrite: analyze BoardSpec → ASM IR → words. Same Module as
/// `KStart.S` plus the guest `WasmStart` lowering when `kernel.wasm.jit`.
fn payload_module(spec: &BoardSpec, msg: &[u8]) -> Result<g6b_asm::Module, String> {
    let mut module = g6b_asm::analyze::payload(spec, msg);
    if spec.kernel.wasm.enable && spec.kernel.wasm.jit {
        g6b_wasm::install_start(&mut module, spec.isa.xlen)?;
    }
    Ok(module)
}

fn assemble(spec: &BoardSpec, entry: u64, msg: &[u8]) -> Result<(Vec<u8>, u32, u64), String> {
    let module = payload_module(spec, msg)?;
    let (insns, rodata) = module.to_words(entry)?;
    let mut out = Vec::with_capacity(insns.len() * 4 + rodata.len());
    for w in insns {
        out.extend_from_slice(&w.to_le_bytes());
    }
    out.extend_from_slice(&rodata);
    Ok((out, module.n_harts(), module.extra_bss()))
}

fn pack_elf(
    is64: bool,
    entry: u64,
    payload: &[u8],
    nharts: u32,
    gr_bytes: u64,
) -> Result<Vec<u8>, String> {
    let ehsize: u16 = if is64 { 64 } else { 52 };
    let phentsize: u16 = if is64 { 56 } else { 32 };
    let phoff = u64::from(ehsize);
    let hdr_end = (u64::from(ehsize) + u64::from(phentsize)) as usize;
    let file_off = (hdr_end + 15) & !15;
    let mut file = vec![0u8; file_off + payload.len()];

    file[0] = 0x7f;
    file[1] = b'E';
    file[2] = b'L';
    file[3] = b'F';
    file[4] = if is64 { 2 } else { 1 };
    file[5] = 1; // little
    file[6] = 1;
    write_u16(&mut file, 16, ET_EXEC);
    write_u16(&mut file, 18, EM_RISCV);
    write_u32(&mut file, 20, 1);
    if is64 {
        write_u64(&mut file, 24, entry);
        write_u64(&mut file, 32, phoff);
        write_u16(&mut file, 52, ehsize);
        write_u16(&mut file, 54, phentsize);
        write_u16(&mut file, 56, 1);
    } else {
        write_u32(&mut file, 24, entry as u32);
        write_u32(&mut file, 28, phoff as u32);
        write_u16(&mut file, 40, ehsize);
        write_u16(&mut file, 42, phentsize);
        write_u16(&mut file, 44, 1);
    }

    let po = u64::from(ehsize);
    let filesz = payload.len() as u64;
    let memsz = payload_memsz(filesz, nharts, gr_bytes);
    if is64 {
        let o = po as usize;
        write_u32(&mut file, o, PT_LOAD);
        write_u32(&mut file, o + 4, PF_RWX);
        write_u64(&mut file, o + 8, file_off as u64);
        write_u64(&mut file, o + 16, entry);
        write_u64(&mut file, o + 24, entry);
        write_u64(&mut file, o + 32, filesz);
        write_u64(&mut file, o + 40, memsz);
        write_u64(&mut file, o + 48, 16);
    } else {
        let o = po as usize;
        write_u32(&mut file, o, PT_LOAD);
        write_u32(&mut file, o + 4, file_off as u32);
        write_u32(&mut file, o + 8, entry as u32);
        write_u32(&mut file, o + 12, entry as u32);
        write_u32(&mut file, o + 16, filesz as u32);
        write_u32(&mut file, o + 20, memsz as u32);
        write_u32(&mut file, o + 24, PF_RWX);
        write_u32(&mut file, o + 28, 16);
    }
    file[file_off..file_off + payload.len()].copy_from_slice(payload);
    Ok(file)
}

fn write_u16(b: &mut [u8], off: usize, v: u16) {
    b[off..off + 2].copy_from_slice(&v.to_le_bytes());
}

fn write_u32(b: &mut [u8], off: usize, v: u32) {
    b[off..off + 4].copy_from_slice(&v.to_le_bytes());
}

fn write_u64(b: &mut [u8], off: usize, v: u64) {
    b[off..off + 8].copy_from_slice(&v.to_le_bytes());
}

fn parse_hex(s: &str) -> Result<u64, String> {
    let t = s
        .trim()
        .trim_start_matches("0x")
        .trim_start_matches("0X")
        .replace('_', "");
    u64::from_str_radix(&t, 16).map_err(|e| format!("bad hex {s}: {e}"))
}

/// Host S-mode smoke: execute the payload until park/UART (QEMU stand-in).
pub fn smoke(spec: &BoardSpec) -> Result<g6b_asm::exec::Smoke, String> {
    let entry = load_addr(spec)?;
    let text = payload_text(spec);
    let module = payload_module(spec, &text)?;
    g6b_asm::exec::run_module(spec, &module, entry)
}

/// Exec-model S-mode stand-in: LDC cell on the same [`g6b_wasm::Host`] as
/// `BrowserSession`, packed into `__ui_cap` / `__scan_fb`, then guest
/// `VioPaint` TRANSFERs dirty tiles. Does not grow `start_ops`. Default
/// [`smoke`] stays the VGA glyph path so bios-regress is unchanged.
pub fn smoke_cell(spec: &BoardSpec) -> Result<g6b_asm::exec::Smoke, String> {
    let cell = g6b_kernel::guest_cell_scanout(spec)?;
    if !cell.wasm_executed {
        return Err("smoke_cell: LDC cell did not run on KernelHost".into());
    }
    let entry = load_addr(spec)?;
    let text = payload_text(spec);
    let module = payload_module(spec, &text)?;
    g6b_asm::exec::run_module_web(spec, &module, entry, 0, Some(&cell.present))
}

/// Write `g6lc_bios.elf` under `dir` (or `dir` itself if it ends in `.elf`).
pub fn write_elf(spec: &BoardSpec, path: &std::path::Path) -> Result<(), String> {
    let bytes = build(spec)?;
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
    }
    std::fs::write(path, bytes).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_asm::STACK_BYTES;

    #[test]
    fn rv64_elf_has_markers() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64,"march":"rv64imac"},"postboot":{"enable":"never"}}"#,
        )
        .unwrap();
        let elf = build(&spec).unwrap();
        assert_eq!(&elf[0..4], b"\x7fELF");
        assert_eq!(elf[4], 2);
        assert_eq!(u16::from_le_bytes([elf[18], elf[19]]), EM_RISCV);
        let s = String::from_utf8_lossy(&elf);
        assert!(s.contains("G6LC-BIOS"), "{s}");
        assert!(s.contains("HOLYC-READY"), "{s}");
        assert!(s.contains("KSTART-XLEN-64"), "{s}");
        assert!(s.contains("KSTART-STVEC"), "{s}");
        assert!(s.contains("KSTART-TIMER"), "{s}");
        assert!(s.contains("KMAIN"), "{s}");
        assert!(s.contains("ISEL-SCALAR"), "{s}");
        assert!(!s.contains("ISEL-RVV"), "{s}");
        assert!(!s.contains("EFER") && !s.contains("LAPIC"));
        assert!(s.contains("KSTART-STACKS-1"), "{s}");
        assert_eq!(load_addr(&spec).unwrap(), 0x8020_0000);
        let (filesz, memsz) = ph64(&elf);
        assert_eq!(memsz, payload_memsz(filesz, 1, g6b_asm::UART_LINE_BSS));
        assert!(memsz >= filesz + STACK_BYTES);
    }

    fn ph64(elf: &[u8]) -> (u64, u64) {
        let o = 64usize;
        let filesz = u64::from_le_bytes(elf[o + 32..o + 40].try_into().unwrap());
        let memsz = u64::from_le_bytes(elf[o + 40..o + 48].try_into().unwrap());
        (filesz, memsz)
    }

    #[test]
    fn two_hart_elf_bss_covers_per_hart_stacks() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"harts":{"count":2}}"#,
        )
        .unwrap();
        let elf = build(&spec).unwrap();
        let s = String::from_utf8_lossy(&elf);
        assert!(s.contains("KSTART-STACKS-2"), "{s}");
        let (filesz, memsz) = ph64(&elf);
        assert_eq!(memsz, payload_memsz(filesz, 2, g6b_asm::UART_LINE_BSS));
        assert!(
            memsz >= filesz + 2 * STACK_BYTES,
            "filesz={filesz} memsz={memsz}"
        );
    }

    #[test]
    fn rvv_elf_encodes_vsetvli() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64,"march":"rv64imafdcv","extensions":{"v":"live"}}}"#,
        )
        .unwrap();
        let elf = build(&spec).unwrap();
        let s = String::from_utf8_lossy(&elf);
        assert!(s.contains("ISEL-RVV"), "{s}");
        let words = g6b_asm::analyze::memcpy(64, true).to_words(0).unwrap().0;
        let needle = words[1].to_le_bytes();
        assert!(
            elf.windows(4).any(|w| w == needle),
            "missing vsetvli word {:#x}",
            words[1]
        );
    }

    #[test]
    fn proxy_elf_has_kstart_proxy() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"proxy":{"enable":true,"link":"hdmi","high_w":1920,"high_h":1080,"dpi":192,"scale_mode":"dpi"}}}"#,
        )
        .unwrap();
        let elf = build(&spec).unwrap();
        let s = String::from_utf8_lossy(&elf);
        assert!(s.contains("KSTART-TIMER"), "{s}");
        assert!(s.contains("KSTART-PROXY"), "{s}");
        assert!(s.contains("KSTART-GR"), "{s}");
        let (filesz, memsz) = ph64(&elf);
        assert_eq!(
            memsz,
            payload_memsz(
                filesz,
                spec.harts.max(1),
                g6b_asm::gr_bss_len(640, 480, 16)
                    + g6b_asm::UART_LINE_BSS
                    // `DispSel` latches the resolved output into `__vio`, so the
                    // mux allocates that block on any board with a Gr plane or
                    // display proxy. The scanout surface itself is not
                    // allocated here — no backend commits it on this fixture.
                    + g6b_asm::vio::VIO_BSS,
            )
        );
    }

    #[test]
    fn wasm_elf_embeds_g6ui_and_ui_wasm() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"wasm":{"enable":true,"jit":true}}}"#,
        )
        .unwrap();
        let elf = build(&spec).unwrap();
        let s = String::from_utf8_lossy(&elf);
        assert!(s.contains("KSTART-UI"), "{s}");
        assert!(s.contains("KSTART-WASM-JIT"), "{s}");
        assert!(s.contains("KSTART-WASM-UI"), "{s}");
        assert!(
            elf.windows(4).any(|w| w == b"\0asm"),
            "missing bios-ui.wasm in ELF"
        );
        let (filesz, memsz) = ph64(&elf);
        assert_eq!(
            memsz,
            payload_memsz(
                filesz,
                spec.harts.max(1),
                g6b_asm::UART_LINE_BSS + g6b_asm::UI_HEADER_BYTES + g6b_asm::dom::UI_DOM_BYTES,
            )
        );
    }

    #[test]
    fn wasm_jit_smoke_runs_dom_imports() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"gr":{"enable":true},"wasm":{"enable":true,"jit":true}},"postboot":{"enable":"never"}}"#,
        )
        .unwrap();
        let s = smoke(&spec).unwrap();
        assert!(s.console.contains("KSTART-WASM-UI"), "{}", s.console);
        assert!(s.dom_rows > 0, "no guest DOM rows: {}", s.console);
        assert!(s.console.contains("DOM|"), "{}", s.console);
        assert!(s.dom_pix0 != 0, "no DOM glyphs painted: {}", s.console);
        assert!(s.faults == 0, "guest faults: {}", s.faults);
        // Executed __gr_plane decodes (guest-painted DOM text included).
        let ppm = g6b_kernel::frame_ppm(&s.gr_frame).expect("executed GR16 plane");
        assert!(ppm.starts_with(b"P6\n640 480\n255\n"));
        // UART `Ui` re-dumps the live DOM store (boot paint + Ui repaint).
        assert!(
            s.console.matches("DOM| UI-BOOT").count() >= 2,
            "Ui should re-dump DOM: {}",
            s.console
        );
    }

    #[test]
    fn wasm_jit_smoke_serial_only_without_gr() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"wasm":{"enable":true,"jit":true}},"postboot":{"enable":"never"}}"#,
        )
        .unwrap();
        let s = smoke(&spec).unwrap();
        assert!(s.dom_rows > 0, "no guest DOM rows: {}", s.console);
        assert!(s.console.contains("DOM|"), "{}", s.console);
    }

    #[test]
    fn rv32_elf_class() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":32,"march":"rv32imac"}}"#,
        )
        .unwrap();
        let elf = build(&spec).unwrap();
        assert_eq!(elf[4], 1);
        assert!(String::from_utf8_lossy(&elf).contains("G6LC-BIOS"));
    }

    #[test]
    fn smoke_prints_boot_log() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64,"march":"rv64imac"},"postboot":{"enable":"never"}}"#,
        )
        .unwrap();
        let s = smoke(&spec).unwrap();
        assert!(s.console.contains("KSTART-SATP-BARE"), "{}", s.console);
        assert!(s.console.contains("KSTART-UART0"), "{}", s.console);
        assert!(s.console.contains("KSTART-TIMER"), "{}", s.console);
        assert!(s.console.contains("G6LC-BIOS"), "{}", s.console);
        assert_eq!(s.satp, 0);
        assert!(
            matches!(
                s.halt,
                g6b_asm::exec::Halt::Wfi | g6b_asm::exec::Halt::UartPoll
            ),
            "{:?}",
            s.halt
        );
    }

    #[test]
    fn smoke_cell_runs_ldc_host_not_start_ops() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let cell = g6b_kernel::guest_cell_scanout(&spec).unwrap();
        assert!(cell.wasm_executed);
        assert!(
            cell.diagnostics
                .iter()
                .any(|d| d.contains("WASM-INTERPRETER")),
            "{:?}",
            cell.diagnostics
        );
        let s = smoke_cell(&spec).unwrap();
        assert!(s.console.contains("VIRTIO-PAINT\n"), "{}", s.console);
        assert!(s.cap_nodes > 1, "compact persist from live cell DOM");
        assert_eq!(s.cap_tiles, 0);
    }

    #[test]
    fn addi_encoding() {
        use g6b_asm::encode::{addi, csrrw, ecall, A0, CSR_STVEC, T2, X0};
        assert_eq!(addi(A0, X0, 1), 0x0010_0513);
        assert_eq!(ecall(), 0x0000_0073);
        assert_eq!(csrrw(X0, CSR_STVEC, T2), 0x1053_9073);
    }
}
