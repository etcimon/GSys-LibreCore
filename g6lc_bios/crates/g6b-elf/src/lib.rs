// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Host-generated RISC-V ELF for OpenSBI `-kernel` (B9).
//!
//! Start sequence is the rewrite of `kernel-spec/ZealOS/src/Kernel/KStart64.ZC`
//! / `TempleOS/Kernel/KStart64.HC`. Words come from `g6b-asm` after
//! `analyze::payload` tags BoardSpec objects (hart, stack, stvec, UART1, memcpy).
//! No rustc riscv target and no crates.io; the image is lowered here.

#![allow(missing_docs)]

pub mod native;

use g6b_asm::payload_memsz;
use g6b_http::files::{load_pglite_dist, MAX_PGLITE_EMBED_BYTES};
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
    build_with_volumes(spec, None)
}

/// [`build`] with media attached: the boot picker packed into the image lists
/// what these volumes actually hold, probed at build time because the guest has
/// no block reader to probe with.
pub fn build_with_volumes(
    spec: &BoardSpec,
    volumes: Option<g6b_kernel::DirVolumes>,
) -> Result<Vec<u8>, String> {
    let entry = load_addr(spec)?;
    if spec.isa.xlen == 32 && entry > u32::MAX as u64 {
        return Err("rv32 load address does not fit in 32 bits".into());
    }
    let text = payload_text_with(spec, Some(volumes.unwrap_or_default()));
    let (code, nharts, gr_bytes) = assemble(spec, entry, &text)?;
    match spec.isa.xlen {
        32 => pack_elf(false, entry as u32 as u64, &code, nharts, gr_bytes),
        64 => pack_elf(true, entry, &code, nharts, gr_bytes),
        x => Err(format!("unsupported xlen {x}")),
    }
}

fn payload_text(spec: &BoardSpec) -> Vec<u8> {
    payload_text_with(spec, None)
}

fn payload_text_with(spec: &BoardSpec, volumes: Option<g6b_kernel::DirVolumes>) -> Vec<u8> {
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
    s.push_str(&g6b_kernel::boot_with_volumes(spec, volumes));
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
    if spec.kernel.wasm.guest_jit {
        // Host-side predecode → `__jit_in`; the guest `JitRun` translates and
        // executes it. Bounds errors are fatal here, never silently dropped.
        g6b_wasm::install_guest(&mut module, &g6b_wasm::jcode_cell_bytes(spec))?;
        // The host-rendered `BrowserSession` scene → `__web_pk`; `WebBlit`
        // decodes it into the latched scanout. `None` leaves `__web_pk`
        // aliased onto `boot_log` (non-magic) so `WebBlit` falls through to
        // the text-face paths.
        if let Some(pk) = g6b_kernel::web_pk_pack(spec)? {
            module.web_pk = pk;
        }
        // The same scene as a display list → `__web_dl`; `WebPaint` replays
        // it (`DlPaint`) and keeps `WebBlit` as the pixel fallback when the
        // list is absent. `None` aliases `__web_dl` onto `boot_log` — the
        // non-magic word sends `DlPaint` to `a0=0`.
        if let Some(dl) = g6b_kernel::dl_pack(spec)? {
            module.web_dl = dl;
        }
        // The `{url → body}` fetch table → `__kget`; `KernelGet`/`LwFetch`
        // resolve `env.fetch` against it. `None` aliases `__kget` onto
        // `boot_log` (non-magic) so `KernelGet` resolves no entry.
        if let Some(kg) = g6b_kernel::kget_pack(spec)? {
            module.kget = kg;
        }
    }
    if spec.kernel.store.pglite_embed {
        let dist = load_pglite_dist().ok_or_else(|| {
            "kernel.store.pglite.embed needs extracted dist (python tools/g6b.py pglite-dist)"
                .to_string()
        })?;
        if dist.embed_len() > MAX_PGLITE_EMBED_BYTES {
            return Err(format!(
                "pglite embed {} exceeds {MAX_PGLITE_EMBED_BYTES} bytes",
                dist.embed_len()
            ));
        }
        module.pglite_wasm = dist.wasm;
        module.pglite_initdb = dist.initdb;
        module.pglite_data = dist.data;
    }
    if spec.kernel.store.persist_elf {
        match g6b_pglite::read_host_dump_bytes() {
            Some(bytes) => {
                if bytes.len() as u32 > spec.kernel.store.max_result_bytes {
                    return Err(format!(
                        "store dump {} exceeds max_result_bytes {}",
                        bytes.len(),
                        spec.kernel.store.max_result_bytes
                    ));
                }
                module.store_dump = bytes;
            }
            None if g6b_pglite::dump_path_explicit().is_some() => {
                return Err(
                    "kernel.store.persist.elf: G6B_STORE_DUMP missing (python tools/g6b.py store-embed)"
                        .into(),
                );
            }
            None => {}
        }
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

/// Exec-model S-mode stand-in: svelte-d LDC cell on the same
/// [`g6b_wasm::Host`] as `BrowserSession` (DOM, CSS, GLES2 `u_dom`, events,
/// throw/await), packed into `__ui_cap` / `__scan_fb`, then guest `VioPaint`
/// TRANSFERs dirty tiles. Does not grow `start_ops`. Default [`smoke`] stays
/// the VGA glyph path so bios-regress is unchanged.
pub fn smoke_cell(spec: &BoardSpec) -> Result<g6b_asm::exec::Smoke, String> {
    smoke_cell_drive(spec, &[])
}

/// Like [`smoke_cell`] after BIOS-UI actions on the persistent svelte-d
/// session (click / key / hover / JS await). Still does not grow `start_ops`.
pub fn smoke_cell_drive(
    spec: &BoardSpec,
    actions: &[g6b_kernel::GuestCellAction<'_>],
) -> Result<g6b_asm::exec::Smoke, String> {
    let mut live = g6b_kernel::GuestCellLive::open(spec)?;
    live.apply(actions)?;
    let entry = load_addr(spec)?;
    let text = payload_text(spec);
    let module = payload_module(spec, &text)?;
    g6b_asm::exec::run_module_web_feed(spec, &module, entry, 0, &mut live)
}

/// Write `g6lc_bios.elf` under `dir` (or `dir` itself if it ends in `.elf`).
pub fn write_elf(spec: &BoardSpec, path: &std::path::Path) -> Result<(), String> {
    write_elf_with_volumes(spec, path, None)
}

/// [`write_elf`] with attached media declared.
pub fn write_elf_with_volumes(
    spec: &BoardSpec,
    path: &std::path::Path,
    volumes: Option<g6b_kernel::DirVolumes>,
) -> Result<(), String> {
    let bytes = build_with_volumes(spec, volumes)?;
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
    fn picking_bios_ui_replaces_the_picker_rows() {
        let spec =
            BoardSpec::from_json_str(include_str!("../../../fixtures/g6lc64-web-autoboot.json"))
                .unwrap();
        let output = spec.default_output();
        let text = payload_text_with(&spec, Some(g6b_kernel::DirVolumes::new()));
        let module = payload_module(&spec, &text).unwrap();
        let entry = load_addr(&spec).unwrap();
        let smoke =
            g6b_asm::exec::run_module_with_limit(&spec, &module, entry, 192_000_000).unwrap();
        eprintln!(
            "halt={:?} steps={} faults={}",
            smoke.halt, smoke.steps, smoke.faults
        );
        let (_, after_pick) = smoke
            .console
            .split_once("AUTOBOOT-PICK bios-ui")
            .expect("BIOS UI selected");
        assert!(
            !after_pick.contains("DOM| AUTOBOOT"),
            "picker repainted after handoff"
        );
        assert!(after_pick.contains("WEBDL "), "web scene replayed");
        assert!(
            !after_pick.contains("WEBPK "),
            "display-list fallback was used"
        );
        assert_ne!(
            smoke.halt,
            g6b_asm::exec::Halt::Limit,
            "incomplete web frame at {:#x}",
            smoke.pc
        );
        assert_eq!(smoke.faults, 0);
        assert!(!after_pick.contains("WASM-JIT-TRAP"));
        assert!(after_pick.contains("WASM-JIT "), "guest entry completed");
        assert!(smoke.domt_live > 56, "guest fetched and built field rows");
        let mut session = g6b_kernel::BrowserSession::new(&spec).unwrap();
        session.select_menu(&spec.kernel.start_menu).unwrap();
        let expected = session
            .paint_css_at(output.w, output.h)
            .unwrap()
            .canvas
            .to_x8r8([0x10, 0x16, 0x20]);
        assert_eq!(smoke.vio_fb.len(), expected.len());
        let first = smoke
            .vio_fb
            .chunks_exact(4)
            .zip(expected.chunks_exact(4))
            .position(|(a, b)| a[..3] != b[..3]);
        assert!(
            first.is_none(),
            "handoff frame differs from host at {:?}",
            first.map(|p| (p % output.w as usize, p / output.w as usize))
        );
        assert_eq!(smoke.cap_tiles, 0);
    }

    #[test]
    fn emitted_picker_only_offers_declared_media() {
        let spec =
            BoardSpec::from_json_str(include_str!("../../../fixtures/g6lc64-web-autoboot.json"))
                .unwrap();
        let elf = build(&spec).unwrap();
        let text = String::from_utf8_lossy(&elf);
        let entries: Vec<_> = text
            .lines()
            .filter_map(|line| line.strip_prefix("CLI-AB-ENTRY| "))
            .map(|line| line.split_whitespace().next().unwrap())
            .collect();
        assert_eq!(entries, ["payload", "bios-ui"]);
    }

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
        assert_eq!(
            memsz,
            payload_memsz(
                filesz,
                1,
                g6b_asm::UART_LINE_BSS + g6b_asm::linux::LOAD_BYTES
            )
        );
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
        assert_eq!(
            memsz,
            payload_memsz(
                filesz,
                2,
                g6b_asm::UART_LINE_BSS + g6b_asm::linux::LOAD_BYTES
            )
        );
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
        // A plane plus the default CLI face means the guest carries the text
        // row store and `DomPaint` — the zealcli container is what gets painted
        // when no web engine is compiled.
        assert!(s.contains("KSTART-CLI"), "{s}");
        assert!(g6b_asm::analyze::wants_cli_face(&spec));
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
                    + g6b_asm::vio::VIO_BSS
                    // Bounded text row table for the CLI container.
                    + g6b_asm::dom::UI_DOM_BYTES
                    + g6b_asm::linux::LOAD_BYTES,
            )
        );
    }

    #[test]
    fn barebone_elf_paints_the_cli_container_and_carries_no_web_stack() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","isa":{"xlen":64}}"#,
        )
        .unwrap();
        let elf = build(&spec).unwrap();
        let s = String::from_utf8_lossy(&elf);
        assert!(s.contains("KSTART-CLI"), "{s}");
        assert!(
            s.contains("ZEALCLI-READY"),
            "the boot log carries the face: {s}"
        );
        assert!(s.contains("CLI| "), "and the container rows: {s}");
        // The engine is absent, all of it.
        for absent in ["KSTART-WASM-JIT", "KSTART-WASM-UI", "KSTART-DOM", "UI-BOOT"] {
            assert!(
                !s.contains(absent),
                "{absent} must not be in a barebone image"
            );
        }
        assert!(
            !elf.windows(4).any(|w| w == b"\0asm"),
            "no wasm module belongs in a barebone image"
        );
        // The guest still paints: the row table is allocated and DomPaint runs.
        let smoked = smoke(&spec).unwrap();
        assert!(
            smoked.console.contains("ZEALCLI-PAINT"),
            "CliInit should publish rows: {}",
            smoked.console
        );
        assert!(
            smoked.console.contains("DOM| G6LC-BIOS zealcli"),
            "DomPaint should blit the container: {}",
            smoked.console
        );
        assert!(smoked.dom_rows > 0, "rows published: {}", smoked.console);
        assert!(
            smoked.dom_pix0 != 0,
            "container glyphs painted into the plane: {}",
            smoked.console
        );
        assert_eq!(smoked.faults, 0, "{}", smoked.console);
    }

    /// The guest container is **interactive**: keys edit the line, Enter
    /// dispatches, an unknown verb is reported, and a page switch repaints.
    ///
    /// Both input bands are exercised: the virtio-input burst types `a` and
    /// presses Enter, and the UART band (a headless board's console) sends
    /// `nosuchcmd`, `clear` and `help`.
    #[test]
    fn barebone_guest_container_dispatches_typed_lines() {
        // The boot picker owns the screen at power-on, so this build turns it
        // off to test the prompt itself; `autoboot_picker_owns_the_boot_screen`
        // covers the other half.
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","isa":{"xlen":64},"kernel":{"cli":{"autoboot":{"enable":false}}}}"#,
        )
        .unwrap();
        let s = smoke(&spec).unwrap();
        let c = &s.console;
        // Keyboard: the canned burst is `a`, arrow, Enter.
        assert!(c.contains("CLI-CMD a\n"), "keyboard reached the line: {c}");
        // Unknown verbs fail closed, they are not guessed at.
        assert!(c.contains("CLI-CMD?"), "{c}");
        assert!(c.contains("CLI-CMD nosuchcmd\n"), "{c}");
        // `clear` empties the container, `help` switches to the packed page.
        assert!(c.contains("CLI-CLEAR"), "{c}");
        assert!(c.contains("CLI-PAGE help"), "{c}");
        // The page is real text the host rendered from the command table.
        assert!(
            c.contains("DOM| help/Help/?") || c.contains("DOM| zealcli - 80x25"),
            "the help page should be painted: {c}"
        );
        assert!(s.dom_rows > 1, "page rows published: {}", s.dom_rows);
        assert_eq!(s.faults, 0, "{c}");
        // A reboot verb exists but the run must not have taken it.
        assert!(!c.contains("CLI-REBOOT"), "{c}");
    }

    /// The boot picker is the power-on face, and it is *live* in the guest:
    /// the canned key burst (`a`, arrow-down, Enter) must wrap the selection and
    /// take an entry, and the countdown must be armed from the compiled timeout.
    #[test]
    fn autoboot_picker_owns_the_boot_screen_and_answers_keys() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","isa":{"xlen":64}}"#,
        )
        .unwrap();
        let s = smoke(&spec).unwrap();
        let c = &s.console;
        // The picker is armed with the compiled countdown, in timer ticks.
        assert!(c.contains("AUTOBOOT-READY"), "{c}");
        let ready = c
            .lines()
            .find(|l| l.starts_with("AUTOBOOT-READY"))
            .unwrap_or_default();
        assert!(ready.contains("countdown=120 ticks"), "2s at 60/s: {ready}");
        // Its frame is what the screen shows first.
        let first = c
            .lines()
            .find_map(|l| l.strip_prefix("DOM| "))
            .expect("the picker painted");
        assert!(first.starts_with("AUTOBOOT"), "{first}");
        assert!(first.contains("order=live-first"), "{first}");
        assert!(
            c.contains("DOM| > 1. Setup (this payload)"),
            "the selection marker is painted: {c}"
        );
        // Enter in the burst took the selection.
        assert!(c.contains("AUTOBOOT-PICK payload"), "{c}");
        // …and the payload entry drops to the prompt, exactly once.
        assert_eq!(c.matches("AUTOBOOT-READY").count(), 1, "asked once: {c}");
        assert!(c.contains("CLI| ") || c.contains("DOM| />"), "{c}");
        assert_eq!(s.faults, 0, "{c}");
    }

    /// Rows of the **last** frame the guest painted: the console dumps every
    /// row of a frame consecutively (`DOM| …`), so the final run of those lines
    /// is what is on the screen when the run parks.
    fn last_frame_rows(console: &str) -> Vec<String> {
        let mut frames: Vec<Vec<String>> = Vec::new();
        for line in console.lines() {
            match line.strip_prefix("DOM| ") {
                Some(row) => {
                    if frames.last().is_none() {
                        frames.push(Vec::new());
                    }
                    frames.last_mut().unwrap().push(row.to_string());
                }
                None => {
                    if frames.last().is_some_and(|f| !f.is_empty()) {
                        frames.push(Vec::new());
                    }
                }
            }
        }
        frames.retain(|f| !f.is_empty());
        frames.pop().unwrap_or_default()
    }

    /// Assert the plane holds `row`'s glyphs at container row `at`.
    fn assert_row_glyphs(plane: &[u8], at: usize, row: &str) {
        let stride = g6b_asm::gr_stride(640, 16) as usize;
        let hdr = g6b_asm::GR_HEADER_BYTES as usize;
        let y0 = g6b_asm::dom::DOM_Y0 as usize + at * 8;
        for (col, ch) in row.bytes().enumerate() {
            let glyph = g6b_asm::font::FONT8X8[g6b_asm::font::glyph_index(ch)];
            for (gy, bits) in glyph.iter().enumerate() {
                let off = hdr + (y0 + gy) * stride + col * 4;
                let word = u32::from_le_bytes(plane[off..off + 4].try_into().unwrap());
                assert_eq!(
                    word,
                    g6b_asm::font::pack_row_4bpp(*bits, 0xF, 0),
                    "row {at} cell {col} ({:?}) glyph row {gy}",
                    ch as char
                );
            }
        }
    }

    /// `sp` is the **top** of the hart's stack slot, so the first push cannot
    /// land in the image.
    ///
    /// This was a live corruption: with `sp` set to the *bottom* of the slot, a
    /// single-hart image pushed straight into the tail of `.rodata` — the
    /// `__font` glyph table — and every glyph with a high index (`l` onwards)
    /// painted garbage. Long mixed-case text is what exposes it, so the guard is
    /// a full-lowercase row painted glyph-exact.
    #[test]
    fn hart_stack_top_does_not_clobber_the_rodata_font() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","isa":{"xlen":64},"harts":{"count":1}}"#,
        )
        .unwrap();
        let row = "mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm";
        // The band sequence ends on `help`, so the long lowercase row is packed
        // as that page: the final painted frame is the one under test.
        let log = format!("G6LC-BIOS\nCLI| banner\nCLI:help| {row}\n\0");
        let module = g6b_asm::analyze::payload(&spec, log.as_bytes());
        let s = g6b_asm::exec::run_module(&spec, &module, load_addr(&spec).unwrap()).unwrap();
        let frame = last_frame_rows(&s.console);
        assert_eq!(
            frame.first().map(String::as_str),
            Some(row),
            "{}",
            s.console
        );
        assert_row_glyphs(&s.gr_frame, 0, row);
    }

    /// The container is not just "some ink on the plane": every cell of the
    /// first row must be the exact glyph for that character, at the exact
    /// 4bpp word the font packs. This is what "VGA is the output" means.
    #[test]
    fn barebone_guest_paints_the_container_glyph_exact() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","isa":{"xlen":64}}"#,
        )
        .unwrap();
        let s = smoke(&spec).unwrap();
        let plane = &s.gr_frame;
        assert!(!plane.is_empty(), "no GR16 plane: {}", s.console);
        // The boot picker paints first; the container banner follows it once the
        // picker has had its answer.
        let first = s
            .console
            .lines()
            .find_map(|l| l.strip_prefix("DOM| "))
            .expect("DomPaint should have dumped a frame");
        assert!(first.starts_with("AUTOBOOT"), "{first}");
        assert!(
            s.console.contains("DOM| G6LC-BIOS zealcli"),
            "the container is painted after the picker: {}",
            s.console
        );
        // …and every row of whatever frame is on the screen when the run parks
        // must be glyph-exact, mixed case and punctuation included.
        let frame = last_frame_rows(&s.console);
        assert!(!frame.is_empty(), "no painted frame: {}", s.console);
        for (at, row) in frame.iter().enumerate() {
            assert_row_glyphs(plane, at, row);
        }
    }

    #[test]
    fn persist_elf_without_dump_still_links() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"store":{"persist":{"elf":true}}}}"#,
        )
        .unwrap();
        if g6b_pglite::dump_path_explicit().is_some() {
            return;
        }
        build(&spec).unwrap();
    }

    #[test]
    fn pglite_embed_without_dist_is_a_link_error() {
        let spec = BoardSpec::from_json_str(
            r#"{"schema_version":1,"kernel":{"store":{"pglite":{"embed":true}}}}"#,
        )
        .unwrap();
        match g6b_http::files::load_pglite_dist() {
            None => {
                let err = build(&spec).unwrap_err();
                assert!(err.contains("pglite-dist"), "{err}");
            }
            Some(d) => {
                let elf = build(&spec).unwrap();
                assert!(
                    elf.len() >= d.embed_len(),
                    "embed should pack dist bytes into the ELF"
                );
            }
        }
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
                g6b_asm::UART_LINE_BSS
                    + g6b_asm::UI_HEADER_BYTES
                    + g6b_asm::dom::UI_DOM_BYTES
                    + g6b_asm::linux::LOAD_BYTES,
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
        assert!(cell.fetch_bios);
        assert!(cell.window_interned);
        assert!(cell.gl_presented);
        assert!(
            cell.diagnostics
                .iter()
                .any(|d| d.contains("WASM-INTERPRETER")),
            "{:?}",
            cell.diagnostics
        );
        let s = smoke_cell(&spec).unwrap();
        assert!(s.console.contains("VIRTIO-PAINT\n"), "{}", s.console);
        let paints = s.console.matches("VIRTIO-PAINT\n").count();
        assert!(
            paints >= 2,
            "UART Ui must re-inject svelte-d tiles, not only boot SKIP: paints={paints} {}",
            s.console
        );
        assert!(s.cap_nodes > 1, "compact persist from live cell DOM");
        assert_eq!(s.cap_tiles, 0);
    }

    #[test]
    fn smoke_cell_arrow_right_still_vio_paints() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let s = smoke_cell_drive(&spec, &[g6b_kernel::GuestCellAction::Key("ArrowRight")]).unwrap();
        assert!(s.console.contains("VIRTIO-PAINT\n"), "{}", s.console);
        assert!(s.cap_nodes > 1);
        assert_eq!(s.cap_tiles, 0);
    }

    #[test]
    fn smoke_cell_mbox_ui_paints_svelte_d() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut live = g6b_kernel::GuestCellLive::open(&spec).unwrap();
        let entry = load_addr(&spec).unwrap();
        let text = payload_text(&spec);
        let module = payload_module(&spec, &text).unwrap();
        let s = g6b_asm::exec::run_module_web_feed_kick(&spec, &module, entry, 0, b'U', &mut live)
            .unwrap();
        assert_eq!(
            s.mbox_rsp,
            g6b_asm::encode::MBOX_RSP_UI,
            "mailbox Ui RSP {:#x}",
            s.mbox_rsp
        );
        assert!(
            s.console.contains("VIRTIO-PAINT\n"),
            "mailbox Ui must pack svelte-d: {}",
            s.console
        );
        assert!(
            s.console.contains("UI\n") || s.console.contains("UI"),
            "mailbox Ui shares UART dump: {}",
            s.console
        );
    }

    #[test]
    fn addi_encoding() {
        use g6b_asm::encode::{addi, csrrw, ecall, A0, CSR_STVEC, T2, X0};
        assert_eq!(addi(A0, X0, 1), 0x0010_0513);
        assert_eq!(ecall(), 0x0000_0073);
        assert_eq!(csrrw(X0, CSR_STVEC, T2), 0x1053_9073);
    }
}
