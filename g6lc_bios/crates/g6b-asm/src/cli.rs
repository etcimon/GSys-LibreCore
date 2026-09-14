// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! The guest half of `g6b-zealcli`: a live edit line and a page-switching
//! container, painted by `DomPaint`.
//!
//! What the guest can honestly do is bounded, and this module is exactly that
//! boundary. It **cannot** run the host shell (no interpreter, no allocator, no
//! filesystem), so it does not pretend to: the *pages* an operator can reach are
//! rendered on the host at build time and packed into the payload (`CLI| …` for
//! the boot container, `CLI:<name>| …` for each page), while the *edit line* and
//! the dispatch that switches pages are real guest code. That is the same
//! division a shipping BIOS makes — setup screens are build-time data, the input
//! loop is firmware — and it keeps one source of truth for the text: whatever
//! `g6b_kernel::boot` rendered is what the screen shows.
//!
//! Input arrives as Linux `KEY_*` codes from `INP_KQ` (virtio-input / USB HID)
//! and, on a headless board, as a line on the UART band. Both edit the same
//! buffer at `__uart_line + CLI_LINE_OFF`, which the container's bottom row
//! points at — so a keystroke changes the next frame without republishing rows.
//! Painting never happens in IRQ context: `CliKey` bumps `CLI_DIRTY` and the
//! timer tick repaints when the watermark moved.

use g6b_spec::BoardSpec;

use crate::encode::{
    A0, A1, A6, A7, RA, SBI_PUTCHAR, SBI_SRST_EID, SP, T0, T1, T2, T3, T4, T5, T6, X0,
};
use crate::vio::CLI_SEEN_OFF;
use crate::{
    Addr, Node, Op, Purpose, CLI_DIRTY_OFF, CLI_LINE_CAP, CLI_LINE_LEN_OFF, CLI_LINE_OFF,
    CLI_PAINTED_OFF, CLI_PROMPT_LEN_OFF,
};

/// ZealOS `CmdLinePrompt` — the prefix the edit line starts with.
pub const PROMPT: &str = "/>";

/// Rows a page may carry (the container is at most `DOM_ROWS` tall anyway).
pub const MAX_PAGE_ROWS: usize = 24;
/// Pages the payload may carry, `help`-style screens included.
pub const MAX_PAGES: usize = 8;
/// Bytes of a command name the dispatch compares (padded, NUL-terminated).
pub const CMD_NAME_BYTES: usize = 12;

/// What a dispatched command does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Show page `n`.
    Page(usize),
    /// Empty the container (prompt only).
    Clear,
    /// SBI system reset (`reboot`) / shutdown.
    Reboot,
    Shutdown,
    Disk,
    List,
}

/// One entry of the guest dispatch table.
#[derive(Debug, Clone)]
pub struct Command {
    pub name: String,
    pub action: Action,
}

/// One packed page: a name (empty for the boot container) and its rows.
#[derive(Debug, Clone)]
pub struct Page {
    pub name: String,
    pub rows: Vec<String>,
}

/// The countdown boot picker as the guest can carry it.
///
/// The *list* is discovered on the host — probing media needs a block reader the
/// guest does not have — so the rows arrive packed, each in a selected and an
/// unselected spelling. What is real guest code is the part that has to be:
/// arrows with wraparound, the countdown, Enter, and Esc.
#[derive(Debug, Clone, Default)]
pub struct AutoBootPage {
    /// Header per whole second remaining, index 0 = "expired/stopped".
    pub headers: Vec<String>,
    /// `(id, unselected row, selected row)` in policy order.
    pub entries: Vec<(String, String, String)>,
    pub footer: String,
    /// Timer ticks the countdown lasts (0 = wait for the operator).
    pub ticks: u32,
    /// Ticks per second, for the header digit.
    pub ticks_per_sec: u32,
}

impl AutoBootPage {
    pub fn live(&self) -> bool {
        !self.entries.is_empty()
    }
}

/// Parse the autoboot tags out of the boot log.
///
/// `CLI-AB-HEAD| <secs> <text>`, `CLI-AB-ENTRY| <id> <text>`,
/// `CLI-AB-FOOT| <text>`, `CLI-AB-TICKS| <ticks> <ticks_per_sec>`.
pub fn autoboot_from_log(msg: Option<&[u8]>) -> AutoBootPage {
    let mut page = AutoBootPage::default();
    let Some(msg) = msg else {
        return page;
    };
    for line in String::from_utf8_lossy(msg).lines() {
        if let Some(rest) = line.strip_prefix("CLI-AB-HEAD| ") {
            let (secs, text) = rest.split_once(' ').unwrap_or((rest, ""));
            let at: usize = secs.parse().unwrap_or(0);
            if at > 64 {
                continue;
            }
            while page.headers.len() <= at {
                page.headers.push(String::new());
            }
            page.headers[at] = ascii_row(text);
        } else if let Some(rest) = line.strip_prefix("CLI-AB-ENTRY| ") {
            let (id, text) = rest.split_once(' ').unwrap_or((rest, ""));
            if page.entries.len() >= MAX_PAGE_ROWS || id.is_empty() {
                continue;
            }
            let text = ascii_row(text);
            page.entries.push((
                id.to_string(),
                ascii_row(&format!("  {text}")),
                ascii_row(&format!("> {text}")),
            ));
        } else if let Some(rest) = line.strip_prefix("CLI-AB-FOOT| ") {
            page.footer = ascii_row(rest);
        } else if let Some(rest) = line.strip_prefix("CLI-AB-TICKS| ") {
            let mut it = rest.split_whitespace();
            page.ticks = it.next().and_then(|v| v.parse().ok()).unwrap_or(0);
            page.ticks_per_sec = it.next().and_then(|v| v.parse().ok()).unwrap_or(1).max(1);
        }
    }
    page
}

/// ASCII a Linux keycode types with shift released.
///
/// The guest decodes the same alphabet as the host CLI
/// (`g6b_zealcli::input::from_linux_keycode`); a `g6b-zealcli` test pins the two
/// against each other, because two keymaps that disagree is a bug an operator
/// meets one key at a time. 0 = "no character" (modifiers, arrows, function
/// keys) — those are handled as commands, not text.
pub fn keycode_ascii(code: u8) -> u8 {
    const ROW_DIGITS: &[u8] = b"1234567890-=";
    const ROW_Q: &[u8] = b"qwertyuiop[]";
    const ROW_A: &[u8] = b"asdfghjkl;'`";
    const ROW_Z: &[u8] = b"\\zxcvbnm,./";
    match code {
        // KEY_1..KEY_EQUAL (2..=13)
        2..=13 => ROW_DIGITS[(code - 2) as usize],
        // KEY_Q..KEY_RIGHTBRACE (16..=27)
        16..=27 => ROW_Q[(code - 16) as usize],
        // KEY_A..KEY_GRAVE (30..=41)
        30..=41 => ROW_A[(code - 30) as usize],
        // KEY_BACKSLASH..KEY_SLASH (43..=53)
        43..=53 => ROW_Z[(code - 43) as usize],
        // KEY_SPACE
        57 => b' ',
        _ => 0,
    }
}

/// The 128-byte keymap the guest indexes by keycode.
pub fn keymap_bytes() -> Vec<u8> {
    (0u8..128).map(keycode_ascii).collect()
}

/// Container rows the host rendered (`CLI| <row>` in the boot log).
///
/// Falling back to the container header keeps the label linkable on the listing
/// / exec-model path, which has no boot log.
pub fn rows_from_log(spec: &BoardSpec, msg: Option<&[u8]>) -> Vec<String> {
    let Some(msg) = msg else {
        return vec![format!(
            "G6LC-BIOS zealcli - {} {}x{}",
            spec.product, spec.kernel.cli.cols, spec.kernel.cli.rows
        )];
    };
    let mut rows = tagged_rows(msg, "CLI| ");
    // The host frame's bottom row *is* the prompt; the guest owns that row as a
    // live edit line, so packing it as static text would show it twice.
    if rows.last().is_some_and(|r| r.trim_end() == PROMPT) {
        rows.pop();
    }
    if rows.is_empty() {
        vec![format!("G6LC-BIOS zealcli - {}", spec.product)]
    } else {
        rows
    }
}

/// Pages the host packed (`CLI:<name>| <row>`), in first-seen order.
pub fn pages_from_log(msg: Option<&[u8]>) -> Vec<Page> {
    let Some(msg) = msg else {
        return Vec::new();
    };
    let text = String::from_utf8_lossy(msg);
    let mut pages: Vec<Page> = Vec::new();
    for line in text.lines() {
        let Some(rest) = line.strip_prefix("CLI:") else {
            continue;
        };
        let Some((name, row)) = rest.split_once("| ") else {
            continue;
        };
        let name = name.trim().to_ascii_lowercase();
        if name.is_empty() || name.len() >= CMD_NAME_BYTES {
            continue;
        }
        let row = ascii_row(row);
        let room_for_a_page = pages.len() < MAX_PAGES;
        match pages.iter_mut().find(|p| p.name == name) {
            Some(p) if p.rows.len() < MAX_PAGE_ROWS => p.rows.push(row),
            Some(_) => {}
            None if room_for_a_page => pages.push(Page {
                name,
                rows: vec![row],
            }),
            None => {}
        }
    }
    pages
}

fn tagged_rows(msg: &[u8], tag: &str) -> Vec<String> {
    String::from_utf8_lossy(msg)
        .lines()
        .filter_map(|l| l.strip_prefix(tag))
        .map(ascii_row)
        .filter(|r| !r.is_empty())
        .take(MAX_PAGE_ROWS)
        .collect()
}

/// The 8×8 glyph face is ASCII; anything else becomes `?` here rather than a
/// box glyph the operator has to guess at.
fn ascii_row(row: &str) -> String {
    row.chars()
        .map(|c| {
            if c.is_ascii_graphic() || c == ' ' {
                c
            } else {
                '?'
            }
        })
        .take(crate::dom::DOM_TEXT_MAX as usize)
        .collect::<String>()
        .trim_end()
        .to_string()
}

/// The dispatch table for this payload: the always-there verbs plus one entry
/// per packed page.
pub fn commands(pages: &[Page]) -> Vec<Command> {
    let mut out = vec![
        Command {
            name: "clear".into(),
            action: Action::Clear,
        },
        Command {
            name: "reboot".into(),
            action: Action::Reboot,
        },
        Command {
            name: "shutdown".into(),
            action: Action::Shutdown,
        },
    ];
    out.extend([
        Command {
            name: "cd disk0".into(),
            action: Action::Disk,
        },
        Command {
            name: "disk0:".into(),
            action: Action::Disk,
        },
        Command {
            name: "ls".into(),
            action: Action::List,
        },
        Command {
            name: "dir".into(),
            action: Action::List,
        },
    ]);
    for (i, p) in pages.iter().enumerate() {
        out.push(Command {
            name: p.name.clone(),
            action: Action::Page(i),
        });
    }
    out
}

/// Guest nodes for the CLI face. `boot_log` carries the host-rendered rows.
pub fn nodes(spec: &BoardSpec, boot_log: Option<&[u8]>) -> Vec<Node> {
    let rows = rows_from_log(spec, boot_log);
    let pages = pages_from_log(boot_log);
    let auto = autoboot_from_log(boot_log);
    // One layout for every node: the publisher and the data block must agree on
    // each row's offset, and computing it twice from different inputs is how a
    // row ends up pointing at the middle of the name table.
    let l = layout(&rows, &pages, &auto);
    let mut out = vec![
        init_node(spec, &l, rows.len(), &auto),
        key_node(spec, &auto),
        enter_node(spec, &pages, &l),
        data_node(&rows, &pages, &l),
    ];
    // The picker's code is compiled when the board compiled the picker, not when
    // this build happened to detect media: the timer tick calls `AutoTick`
    // unconditionally, so the label has to exist. With no entries `CliInit`
    // never arms it and every entry point returns immediately.
    if spec.kernel.cli.autoboot.enable {
        out.push(auto_node(spec, &l, &auto));
    }
    out
}

fn ld_x(xlen: u32, rd: u32, rs: u32, off: i32) -> Op {
    if xlen == 32 {
        Op::Lw { rd, rs, off }
    } else {
        Op::Ld { rd, rs, off }
    }
}

fn st_x(xlen: u32, rs2: u32, rs1: u32, off: i32) -> Op {
    if xlen == 32 {
        Op::Sw { rs2, rs1, off }
    } else {
        Op::Sd { rs2, rs1, off }
    }
}

fn putc(ch: u8) -> Vec<Op> {
    vec![
        Op::Li {
            rd: A0,
            imm: i64::from(ch),
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
    ]
}

fn puts(ops: &mut Vec<Op>, s: &str) {
    for b in s.bytes() {
        ops.extend(putc(b));
    }
}

fn ret() -> Op {
    Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    }
}

/// Byte offset of page `i`'s row `r` inside the packed data block.
struct Layout {
    /// `(offset, len)` per boot-container row.
    rows: Vec<(usize, usize)>,
    /// `(offset, len)` per page row, by page.
    pages: Vec<Vec<(usize, usize)>>,
    /// Offset of the command-name table.
    names: usize,
    /// Offset of the keymap.
    keymap: usize,
    /// Autoboot: header per second remaining.
    auto_heads: Vec<(usize, usize)>,
    /// Autoboot: `(unselected, selected)` per entry.
    auto_rows: Vec<((usize, usize), (usize, usize))>,
    /// Autoboot: the footer.
    auto_foot: (usize, usize),
    /// Packed bytes.
    bytes: Vec<u8>,
}

fn layout(rows: &[String], pages: &[Page], auto: &AutoBootPage) -> Layout {
    let mut bytes: Vec<u8> = Vec::new();
    let push = |b: &[u8], bytes: &mut Vec<u8>| -> (usize, usize) {
        let at = bytes.len();
        bytes.extend_from_slice(b);
        while bytes.len() % 4 != 0 {
            bytes.push(0);
        }
        (at, b.len())
    };
    let row_slots: Vec<(usize, usize)> = rows
        .iter()
        .map(|r| push(r.as_bytes(), &mut bytes))
        .collect();
    let page_slots: Vec<Vec<(usize, usize)>> = pages
        .iter()
        .map(|p| {
            p.rows
                .iter()
                .map(|r| push(r.as_bytes(), &mut bytes))
                .collect()
        })
        .collect();
    // Command names, fixed stride so the compare loop is a shift.
    let names = bytes.len();
    for c in commands(pages) {
        let mut name = c.name.clone().into_bytes();
        name.truncate(CMD_NAME_BYTES - 1);
        name.resize(CMD_NAME_BYTES, 0);
        bytes.extend_from_slice(&name);
    }
    let keymap = bytes.len();
    bytes.extend_from_slice(&keymap_bytes());
    while bytes.len() % 4 != 0 {
        bytes.push(0);
    }
    // Autoboot rows: one header per second, two spellings per entry, a footer.
    let auto_heads: Vec<(usize, usize)> = auto
        .headers
        .iter()
        .map(|h| push(h.as_bytes(), &mut bytes))
        .collect();
    let auto_rows: Vec<((usize, usize), (usize, usize))> = auto
        .entries
        .iter()
        .map(|(_, plain, sel)| {
            (
                push(plain.as_bytes(), &mut bytes),
                push(sel.as_bytes(), &mut bytes),
            )
        })
        .collect();
    let auto_foot = push(auto.footer.as_bytes(), &mut bytes);
    Layout {
        rows: row_slots,
        pages: page_slots,
        names,
        keymap,
        auto_heads,
        auto_rows,
        auto_foot,
        bytes,
    }
}

/// `cli_data` — rows, command names and the keymap as payload words.
fn data_node(rows: &[String], pages: &[Page], l: &Layout) -> Node {
    let mut ops = vec![
        Op::Comment(format!(
            "cli_data — {} container row(s), {} page(s), {CMD_NAME_BYTES}B command names, \
             128B keymap",
            rows.len(),
            pages.len()
        )),
        Op::Label("cli_data".into()),
    ];
    for w in l.bytes.chunks(4) {
        ops.push(Op::Word(u32::from_le_bytes([w[0], w[1], w[2], w[3]])));
    }
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// Publish `n` rows starting at row 0 from `slots`, then the prompt row.
fn publish_rows(xlen: u32, slots: &[(usize, usize)], ops: &mut Vec<Op>) {
    let hdr = crate::dom::DOM_HDR;
    for (i, (off, len)) in slots.iter().enumerate() {
        let base = hdr + (i as i32) * 32;
        ops.extend([
            Op::La {
                rd: T1,
                addr: Addr::Label("cli_data".into()),
            },
            Op::Li {
                rd: T2,
                imm: *off as i64,
            },
            Op::Add {
                rd: T1,
                rs1: T1,
                rs2: T2,
            },
            st_x(xlen, T1, T0, base + 8),
            Op::Li {
                rd: T2,
                imm: *len as i64,
            },
            Op::Sw {
                rs2: T2,
                rs1: T0,
                off: base + 20,
            },
            Op::Li {
                rd: T2,
                imm: crate::dom::DOM_F_VISIBLE | crate::dom::DOM_F_TEXT,
            },
            Op::Sw {
                rs2: T2,
                rs1: T0,
                off: base + 24,
            },
        ]);
    }
}

/// Point row `n` at the live edit line and set the row count to `n+1`.
fn publish_prompt(xlen: u32, at: usize, ops: &mut Vec<Op>) {
    let base = crate::dom::DOM_HDR + (at as i32) * 32;
    ops.extend([
        Op::La {
            rd: T1,
            addr: Addr::UartLine,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: CLI_LINE_OFF,
        },
        st_x(xlen, T1, T0, base + 8),
        // text_len tracks the live length, so the paint follows the typing.
        Op::La {
            rd: T2,
            addr: Addr::UartLine,
        },
        Op::Lw {
            rd: T3,
            rs: T2,
            off: CLI_LINE_LEN_OFF,
        },
        Op::Sw {
            rs2: T3,
            rs1: T0,
            off: base + 20,
        },
        Op::Li {
            rd: T3,
            imm: crate::dom::DOM_F_VISIBLE | crate::dom::DOM_F_TEXT,
        },
        Op::Sw {
            rs2: T3,
            rs1: T0,
            off: base + 24,
        },
        Op::Li {
            rd: T1,
            imm: (at + 1) as i64,
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 0,
        },
    ]);
}

/// `CliInit` — seed the edit line, publish the boot container, paint it.
fn init_node(spec: &BoardSpec, l: &Layout, nrows: usize, auto: &AutoBootPage) -> Node {
    let xlen = spec.isa.xlen;
    let mut ops = vec![
        Op::Comment(format!(
            "CliInit — {nrows} container row(s) + live prompt row → __ui_dom → DomPaint"
        )),
        Op::Glob("CliInit".into()),
        Op::Label("CliInit".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        st_x(xlen, RA, SP, 8),
        // Edit line = the prompt prefix; length and prefix length recorded so
        // backspace knows where the typed text begins.
        Op::La {
            rd: T4,
            addr: Addr::UartLine,
        },
    ];
    for (i, b) in PROMPT.bytes().enumerate() {
        ops.extend([
            Op::Li {
                rd: T1,
                imm: i64::from(b),
            },
            Op::Sb {
                rs2: T1,
                rs1: T4,
                off: CLI_LINE_OFF + i as i32,
            },
        ]);
    }
    ops.extend([
        Op::Li {
            rd: T1,
            imm: PROMPT.len() as i64,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: CLI_LINE_LEN_OFF,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: CLI_PROMPT_LEN_OFF,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: CLI_DIRTY_OFF,
        },
        Op::Sw {
            rs2: X0,
            rs1: T4,
            off: CLI_PAINTED_OFF,
        },
        Op::La {
            rd: T0,
            addr: Addr::UiDom,
        },
    ]);
    publish_rows(xlen, &l.rows, &mut ops);
    publish_prompt(xlen, l.rows.len(), &mut ops);
    // Claim the plane. `CliInit` is also the "back to setup" path, so Esc out of
    // the picker and an entry that returns both take the screen back from the
    // browser face.
    ops.extend([Op::La {
        rd: T4,
        addr: Addr::UartLine,
    }]);
    // A web→CLI transition invalidates the packed scene's ownership latches:
    // `WEB_STAMPED` so `WebBlit` re-blits if the browser face is picked again,
    // and the `__ui_cap` WEB flag so `VioPaint` stops taking `vp_web` against
    // a stale tile table and paints the container's frame instead. The clear
    // only runs when the web face actually owned the plane — a cold `CliInit`
    // at power-on (or an exec-model pre-filled `__ui_cap`, B91) must not
    // disturb either latch.
    ops.extend([
        Op::Lw {
            rd: T1,
            rs: T4,
            off: crate::FACE_OWNER_OFF,
        },
        Op::Li {
            rd: T2,
            imm: crate::FACE_WEB,
        },
        Op::Bne {
            rs1: T1,
            rs2: T2,
            to: "cinit_keep_pk".into(),
        },
        Op::Sw {
            rs2: X0,
            rs1: T4,
            off: crate::WEB_STAMPED_OFF,
        },
    ]);
    if spec.wants_virtio_gpu() || spec.wants_disp_scan() {
        ops.extend([
            Op::La {
                rd: T6,
                addr: Addr::UiCap,
            },
            Op::Sw {
                rs2: X0,
                rs1: T6,
                off: crate::vio::UI_CAP_OFF_FLAGS,
            },
        ]);
    }
    ops.extend([
        Op::Label("cinit_keep_pk".into()),
        Op::Sw {
            rs2: X0,
            rs1: T4,
            off: crate::FACE_OWNER_OFF,
        },
    ]);
    if spec.wants_virtio_gpu() || spec.wants_disp_scan() || spec.wants_pci_scan() {
        ops.extend([
            Op::La {
                rd: T0,
                addr: Addr::VioBss,
            },
            Op::Sw {
                rs2: X0,
                rs1: T0,
                off: crate::vio::DISP_SEL_SURFACE,
            },
        ]);
    }
    puts(&mut ops, &format!("ZEALCLI-PAINT {}\n", l.rows.len() + 1));
    if spec.kernel.cli.autoboot.enable && auto.live() {
        puts(&mut ops, "AUTO-ARM?\n");
        // The picker is the *first* face on a board that compiled it: at
        // power-on the operator gets the boot menu, and the prompt is what Esc
        // (or a taken entry that comes back) leads to. `CliInit` is also the
        // "back to the prompt" path, so it only arms the picker once.
        ops.extend([
            Op::La {
                rd: T4,
                addr: Addr::UartLine,
            },
            Op::Lw {
                rd: T1,
                rs: T4,
                off: crate::AUTO_DONE_OFF,
            },
            Op::Bne {
                rs1: T1,
                rs2: X0,
                to: "cinit_skip_done".into(),
            },
            Op::Lw {
                rd: T2,
                rs: T4,
                off: crate::AUTO_ON_OFF,
            },
            Op::Bne {
                rs1: T2,
                rs2: X0,
                to: "cinit_skip_on".into(),
            },
            Op::Sw {
                rs2: X0,
                rs1: T4,
                off: crate::AUTO_SEL_OFF,
            },
            Op::Li {
                rd: T1,
                imm: i64::from(auto.ticks),
            },
            Op::Sw {
                rs2: T1,
                rs1: T4,
                off: crate::AUTO_TICKS_OFF,
            },
            Op::Li {
                rd: T1,
                imm: i64::from(auto.headers.len().saturating_sub(1) as u32),
            },
            Op::Sw {
                rs2: T1,
                rs1: T4,
                off: crate::AUTO_SECS_OFF,
            },
        ]);
        puts(
            &mut ops,
            &format!(
                "AUTOBOOT-READY {} entr(ies) countdown={} ticks\n",
                auto.entries.len(),
                auto.ticks
            ),
        );
        ops.extend([
            Op::Jal {
                rd: RA,
                to: "AutoDraw".into(),
            },
            Op::La {
                rd: T4,
                addr: Addr::UartLine,
            },
            Op::Li { rd: T1, imm: 1 },
            Op::Sw {
                rs2: T1,
                rs1: T4,
                off: crate::AUTO_ON_OFF,
            },
            ld_x(xlen, RA, SP, 8),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: 16,
            },
            ret(),
        ]);
        ops.push(Op::Label("cinit_skip_done".into()));
        puts(&mut ops, "AUTO-SKIP done\n");
        ops.push(Op::Jal {
            rd: X0,
            to: "cinit_no_auto".into(),
        });
        ops.push(Op::Label("cinit_skip_on".into()));
        puts(&mut ops, "AUTO-SKIP on\n");
        ops.push(Op::Label("cinit_no_auto".into()));
    }
    ops.extend([
        Op::Jal {
            rd: RA,
            to: "DomPaint".into(),
        },
        ld_x(xlen, RA, SP, 8),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 16,
        },
        ret(),
    ]);
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// `CliKey` — consume `INP_KQ` entries past the `CLI_SEEN` watermark and edit
/// the line: printable keycodes append, backspace shrinks, Enter dispatches.
///
/// Leaf discipline: t-regs plus the trap-saved a-regs only, because this runs
/// from `trap_inp`. It never paints — it bumps `CLI_DIRTY` and lets the timer
/// tick flush a frame, the same split `DomKey`/`DomNav` use.
fn key_node(spec: &BoardSpec, _auto: &AutoBootPage) -> Node {
    let xlen = spec.isa.xlen;
    let mut ops = vec![
        Op::Comment("CliKey — INP_KQ → edit line (printable/backspace/Enter)".into()),
        Op::Glob("CliKey".into()),
        Op::Label("CliKey".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        st_x(xlen, RA, SP, 8),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        Op::La {
            rd: T4,
            addr: Addr::UartLine,
        },
        Op::Label("ckey_next".into()),
        // seen == head → nothing new.
        Op::Lw {
            rd: T0,
            rs: T5,
            off: CLI_SEEN_OFF,
        },
        Op::Lw {
            rd: T1,
            rs: T5,
            off: crate::vio::INP_KQ_HEAD,
        },
        Op::Beq {
            rs1: T0,
            rs2: T1,
            to: "ckey_done".into(),
        },
        // entry = KQ[seen & 15]; seen++ (non-destructive: `Keys` still dumps).
        Op::Andi {
            rd: T2,
            rs: T0,
            imm: 15,
        },
        Op::Slli {
            rd: T2,
            rs: T2,
            shamt: 2,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: crate::vio::INP_KQ_OFF,
        },
        Op::Add {
            rd: T2,
            rs1: T2,
            rs2: T5,
        },
        Op::Lw {
            rd: T3,
            rs: T2,
            off: 0,
        },
        Op::Addi {
            rd: T0,
            rs: T0,
            imm: 1,
        },
        Op::Sw {
            rs2: T0,
            rs1: T5,
            off: CLI_SEEN_OFF,
        },
        // value = entry & 0xff (1 = press); code = entry >> 8.
        Op::Andi {
            rd: T1,
            rs: T3,
            imm: 1,
        },
        Op::Beq {
            rs1: T1,
            rs2: X0,
            to: "ckey_next".into(),
        },
        Op::Srli {
            rd: T6,
            rs: T3,
            shamt: 8,
        },
    ];
    if spec.kernel.cli.autoboot.enable {
        // While the picker owns the screen the key is *its* key: navigation and
        // the decision are the picker's, not the edit line's.
        ops.extend([
            Op::Comment("autoboot owns the screen → AutoKey(a1 = keycode)".into()),
            Op::Lw {
                rd: T1,
                rs: T4,
                off: crate::AUTO_ON_OFF,
            },
            Op::Beq {
                rs1: T1,
                rs2: X0,
                to: "ckey_edit".into(),
            },
            Op::Addi {
                rd: A1,
                rs: T6,
                imm: 0,
            },
            Op::Jal {
                rd: RA,
                to: "AutoKey".into(),
            },
            // AutoKey may have painted; reload the bases it does not own.
            Op::La {
                rd: T5,
                addr: Addr::VioBss,
            },
            Op::La {
                rd: T4,
                addr: Addr::UartLine,
            },
            Op::Jal {
                rd: X0,
                to: "ckey_next".into(),
            },
        ]);
    }
    ops.extend([
        Op::Label("ckey_edit".into()),
        // Enter → dispatch the line.
        Op::Li {
            rd: T1,
            imm: crate::vio::VIO_KEY_ENTER,
        },
        Op::Beq {
            rs1: T6,
            rs2: T1,
            to: "ckey_enter".into(),
        },
        // Backspace (KEY_BACKSPACE = 14) → drop one typed byte.
        Op::Li { rd: T1, imm: 14 },
        Op::Beq {
            rs1: T6,
            rs2: T1,
            to: "ckey_back".into(),
        },
        // Printable? keymap[code] (codes >= 128 are not in the table).
        Op::Li { rd: T1, imm: 128 },
        Op::Sub {
            rd: T2,
            rs1: T6,
            rs2: T1,
        },
        Op::Srli {
            rd: T2,
            rs: T2,
            shamt: crate::dom::signbit(xlen),
        },
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "ckey_next".into(),
        },
        Op::La {
            rd: T2,
            addr: Addr::Label("cli_keymap".into()),
        },
        Op::Add {
            rd: T2,
            rs1: T2,
            rs2: T6,
        },
        Op::Lbu {
            rd: T2,
            rs: T2,
            off: 0,
        },
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "ckey_next".into(),
        },
        // Room left? len < CLI_LINE_CAP.
        Op::Lw {
            rd: T1,
            rs: T4,
            off: CLI_LINE_LEN_OFF,
        },
        Op::Li {
            rd: T3,
            imm: i64::from(CLI_LINE_CAP),
        },
        Op::Sub {
            rd: T3,
            rs1: T1,
            rs2: T3,
        },
        Op::Srli {
            rd: T3,
            rs: T3,
            shamt: crate::dom::signbit(xlen),
        },
        Op::Beq {
            rs1: T3,
            rs2: X0,
            to: "ckey_next".into(),
        },
        // line[len] = ch; len++.
        Op::Add {
            rd: T3,
            rs1: T4,
            rs2: T1,
        },
        Op::Sb {
            rs2: T2,
            rs1: T3,
            off: CLI_LINE_OFF,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: CLI_LINE_LEN_OFF,
        },
        Op::Jal {
            rd: X0,
            to: "ckey_dirty".into(),
        },
        Op::Label("ckey_back".into()),
        Op::Lw {
            rd: T1,
            rs: T4,
            off: CLI_LINE_LEN_OFF,
        },
        Op::Lw {
            rd: T2,
            rs: T4,
            off: CLI_PROMPT_LEN_OFF,
        },
        Op::Beq {
            rs1: T1,
            rs2: T2,
            to: "ckey_next".into(),
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: -1,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: CLI_LINE_LEN_OFF,
        },
        Op::Jal {
            rd: X0,
            to: "ckey_dirty".into(),
        },
        Op::Label("ckey_enter".into()),
        Op::Jal {
            rd: RA,
            to: "CliEnter".into(),
        },
        // CliEnter may have moved the row table; reload our bases.
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        Op::La {
            rd: T4,
            addr: Addr::UartLine,
        },
        Op::Label("ckey_dirty".into()),
        Op::Lw {
            rd: T1,
            rs: T4,
            off: CLI_DIRTY_OFF,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: CLI_DIRTY_OFF,
        },
        Op::Jal {
            rd: X0,
            to: "ckey_next".into(),
        },
        Op::Label("ckey_done".into()),
        ld_x(xlen, RA, SP, 8),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 16,
        },
        ret(),
    ]);
    ops.push(Op::Comment(
        "cli_keymap — Linux keycode → ASCII (shift released); 0 = not text".into(),
    ));
    ops.push(Op::Label("cli_keymap".into()));
    for w in keymap_bytes().chunks(4) {
        ops.push(Op::Word(u32::from_le_bytes([w[0], w[1], w[2], w[3]])));
    }
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// `CliEnter` — compare the typed word against the command table, act, then
/// reset the line to the prompt.
///
/// A miss is *reported*, not guessed at: `CLI-CMD? <line>` on serial and the
/// container is left as it was.
fn enter_node(spec: &BoardSpec, pages: &[Page], l: &Layout) -> Node {
    let xlen = spec.isa.xlen;
    let cmds = commands(pages);
    let mut ops = vec![
        Op::Comment(format!(
            "CliEnter — dispatch one line over {} command(s): {}",
            cmds.len(),
            cmds.iter()
                .map(|c| c.name.as_str())
                .collect::<Vec<_>>()
                .join(" ")
        )),
        Op::Glob("CliEnter".into()),
        Op::Label("CliEnter".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        st_x(xlen, RA, SP, 8),
        Op::La {
            rd: T4,
            addr: Addr::UartLine,
        },
    ];
    puts(&mut ops, "CLI-CMD ");
    // Echo the typed text (bounded by the live length) so the serial log shows
    // exactly what the container dispatched.
    ops.extend([
        Op::Lw {
            rd: T5,
            rs: T4,
            off: CLI_LINE_LEN_OFF,
        },
        Op::Lw {
            rd: T6,
            rs: T4,
            off: CLI_PROMPT_LEN_OFF,
        },
        Op::Label("cent_echo".into()),
        Op::Beq {
            rs1: T6,
            rs2: T5,
            to: "cent_echo_done".into(),
        },
        Op::Add {
            rd: T0,
            rs1: T4,
            rs2: T6,
        },
        Op::Lbu {
            rd: A0,
            rs: T0,
            off: CLI_LINE_OFF,
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
        Op::Addi {
            rd: T6,
            rs: T6,
            imm: 1,
        },
        Op::Jal {
            rd: X0,
            to: "cent_echo".into(),
        },
        Op::Label("cent_echo_done".into()),
    ]);
    ops.extend(putc(b'\n'));
    // Compare the typed text against each name; first match wins.
    for (i, c) in cmds.iter().enumerate() {
        let hit = format!("cent_hit{i}");
        let miss = format!("cent_miss{i}");
        ops.push(Op::Comment(format!("  `{}`", c.name)));
        // Length must match exactly, then every byte.
        ops.extend([
            Op::Lw {
                rd: T5,
                rs: T4,
                off: CLI_LINE_LEN_OFF,
            },
            Op::Lw {
                rd: T6,
                rs: T4,
                off: CLI_PROMPT_LEN_OFF,
            },
            Op::Sub {
                rd: T5,
                rs1: T5,
                rs2: T6,
            },
            Op::Li {
                rd: T0,
                imm: c.name.len() as i64,
            },
            Op::Bne {
                rs1: T5,
                rs2: T0,
                to: miss.clone(),
            },
        ]);
        for (j, b) in c.name.bytes().enumerate() {
            ops.extend([
                Op::Lw {
                    rd: T6,
                    rs: T4,
                    off: CLI_PROMPT_LEN_OFF,
                },
                Op::Add {
                    rd: T0,
                    rs1: T4,
                    rs2: T6,
                },
                Op::Lbu {
                    rd: T1,
                    rs: T0,
                    off: CLI_LINE_OFF + j as i32,
                },
                Op::Li {
                    rd: T2,
                    imm: i64::from(b),
                },
                Op::Bne {
                    rs1: T1,
                    rs2: T2,
                    to: miss.clone(),
                },
            ]);
        }
        ops.push(Op::Jal {
            rd: X0,
            to: hit.clone(),
        });
        ops.push(Op::Label(miss));
    }
    // No match.
    puts(&mut ops, "CLI-CMD?\n");
    ops.push(Op::Jal {
        rd: X0,
        to: "cent_reset".into(),
    });
    // Actions.
    for (i, c) in cmds.iter().enumerate() {
        ops.push(Op::Label(format!("cent_hit{i}")));
        match c.action {
            Action::Disk | Action::List => {
                if spec.wants_virtio_blk() && spec.kernel.cli.fs {
                    ops.extend([
                        Op::Jal {
                            rd: RA,
                            to: "BlkSig".into(),
                        },
                        Op::La {
                            rd: T4,
                            addr: Addr::VioBss,
                        },
                        Op::Li {
                            rd: T0,
                            imm: crate::vio::BLK_BASE,
                        },
                        Op::Add {
                            rd: T4,
                            rs1: T4,
                            rs2: T0,
                        },
                        Op::Lw {
                            rd: T1,
                            rs: T4,
                            off: crate::vio::BLK_SIG,
                        },
                        Op::Li { rd: T2, imm: 1 },
                        Op::Bne {
                            rs1: T1,
                            rs2: T2,
                            to: format!("cent_disk_bad{i}"),
                        },
                        Op::La {
                            rd: T4,
                            addr: Addr::UartLine,
                        },
                    ]);
                    if c.action == Action::Disk {
                        for (j, byte) in b"disk0:/>".iter().enumerate() {
                            ops.extend([
                                Op::Li {
                                    rd: T1,
                                    imm: i64::from(*byte),
                                },
                                Op::Sb {
                                    rs2: T1,
                                    rs1: T4,
                                    off: CLI_LINE_OFF + j as i32,
                                },
                            ]);
                        }
                        ops.extend([
                            Op::Li { rd: T1, imm: 8 },
                            Op::Sw {
                                rs2: T1,
                                rs1: T4,
                                off: CLI_PROMPT_LEN_OFF,
                            },
                            Op::Sw {
                                rs2: T1,
                                rs1: T4,
                                off: CLI_LINE_LEN_OFF,
                            },
                            Op::Sw {
                                rs2: T1,
                                rs1: T4,
                                off: crate::CLI_VOLUME_OFF,
                            },
                            Op::La {
                                rd: T0,
                                addr: Addr::UiDom,
                            },
                        ]);
                        publish_prompt(xlen, 0, &mut ops);
                        puts(&mut ops, "CLI-CWD disk0:/ (probed FAT32)\n");
                    } else {
                        ops.extend([
                            Op::Lw {
                                rd: T1,
                                rs: T4,
                                off: crate::CLI_VOLUME_OFF,
                            },
                            Op::Beq {
                                rs1: T1,
                                rs2: X0,
                                to: format!("cent_disk_bad{i}"),
                            },
                            Op::La {
                                rd: T0,
                                addr: Addr::UiDom,
                            },
                        ]);
                        for row in 0..16 {
                            ops.push(Op::Sw {
                                rs2: X0,
                                rs1: T0,
                                off: crate::dom::DOM_HDR + row * 32 + 24,
                            });
                        }
                        publish_prompt(xlen, 16, &mut ops);
                        ops.push(Op::Jal {
                            rd: RA,
                            to: "FatList".into(),
                        });
                    }
                    ops.extend([
                        Op::Jal {
                            rd: X0,
                            to: "cent_reset".into(),
                        },
                        Op::Label(format!("cent_disk_bad{i}")),
                    ]);
                }
                puts(&mut ops, "CLI-FS unavailable: cd disk0 requires a probed FAT32 superfloppy; ls is bounded to its first root sector\n");
                ops.push(Op::Jal {
                    rd: X0,
                    to: "cent_reset".into(),
                });
            }
            Action::Reboot | Action::Shutdown => {
                let reset = if c.action == Action::Reboot { 1 } else { 0 };
                puts(
                    &mut ops,
                    if reset == 1 {
                        "CLI-REBOOT\n"
                    } else {
                        "CLI-SHUTDOWN\n"
                    },
                );
                ops.extend([
                    Op::Li { rd: A0, imm: reset },
                    Op::Li { rd: A1, imm: 0 },
                    Op::Li { rd: A6, imm: 0 },
                    Op::Li {
                        rd: A7,
                        imm: SBI_SRST_EID,
                    },
                    Op::Ecall,
                    Op::Jal {
                        rd: X0,
                        to: "cent_reset".into(),
                    },
                ]);
            }
            Action::Clear => {
                // Prompt only: the row count drops to one and the prompt row
                // moves to index 0.
                ops.push(Op::La {
                    rd: T0,
                    addr: Addr::UiDom,
                });
                publish_prompt(xlen, 0, &mut ops);
                puts(&mut ops, "CLI-CLEAR\n");
                ops.push(Op::Jal {
                    rd: X0,
                    to: "cent_reset".into(),
                });
            }
            Action::Page(p) => {
                ops.push(Op::La {
                    rd: T0,
                    addr: Addr::UiDom,
                });
                let slots = l.pages.get(p).cloned().unwrap_or_default();
                publish_rows(xlen, &slots, &mut ops);
                publish_prompt(xlen, slots.len(), &mut ops);
                puts(&mut ops, &format!("CLI-PAGE {}\n", c.name));
                ops.push(Op::Jal {
                    rd: X0,
                    to: "cent_reset".into(),
                });
            }
        }
    }
    // Reset the edit line to the prompt prefix and mark the frame dirty.
    ops.extend([
        Op::Label("cent_reset".into()),
        Op::La {
            rd: T4,
            addr: Addr::UartLine,
        },
        Op::Lw {
            rd: T1,
            rs: T4,
            off: CLI_PROMPT_LEN_OFF,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: CLI_LINE_LEN_OFF,
        },
        Op::Lw {
            rd: T1,
            rs: T4,
            off: CLI_DIRTY_OFF,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: CLI_DIRTY_OFF,
        },
        ld_x(xlen, RA, SP, 8),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 16,
        },
        ret(),
    ]);
    let _ = (l.names, l.keymap);
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// The dirty-watermark repaint the timer tick runs: paint only when an edit
/// happened, so a key never paints from IRQ context and an idle tick costs two
/// loads. The caller appends its scanout commits and then
/// [`TICK_CLEAN`] as a label, so a clean tick skips those too.
pub fn tick_ops(autoboot: bool) -> Vec<Op> {
    let mut ops = Vec::new();
    if autoboot {
        // The countdown is the tick's job: one call, and it returns immediately
        // unless the picker is up with a live clock.
        ops.push(Op::Jal {
            rd: RA,
            to: "AutoTick".into(),
        });
    }
    ops.extend([
        Op::Comment("zealcli: repaint when CLI_DIRTY moved past CLI_PAINTED".into()),
        Op::La {
            rd: T0,
            addr: Addr::UartLine,
        },
        Op::Lw {
            rd: T1,
            rs: T0,
            off: CLI_DIRTY_OFF,
        },
        Op::Lw {
            rd: T2,
            rs: T0,
            off: CLI_PAINTED_OFF,
        },
        Op::Beq {
            rs1: T1,
            rs2: T2,
            to: TICK_CLEAN.into(),
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: CLI_PAINTED_OFF,
        },
        // The prompt row's text_len must follow the live length before the blit.
        Op::Jal {
            rd: RA,
            to: "CliSync".into(),
        },
        Op::Jal {
            rd: RA,
            to: "DomPaint".into(),
        },
    ]);
    ops
}

/// Label the tick's skip-if-clean branch targets. The caller must define it
/// after its scanout commits.
pub const TICK_CLEAN: &str = "cli_tick_clean";

/// Stash the UART line length before the band dispatcher zeroes it, so an
/// unmatched line can still be handed to the container. `rs` is the register
/// already holding `__uart_line`.
pub fn stash_uart_len_ops(rs: u32) -> Vec<Op> {
    vec![
        Op::Comment("zealcli: keep the line length the band is about to clear".into()),
        Op::Lw {
            rd: T3,
            rs,
            off: crate::UART_LINE_CAP as i32,
        },
        Op::Sw {
            rs2: T3,
            rs1: rs,
            off: crate::CLI_UART_LEN_OFF,
        },
    ]
}

/// A UART line no band command claimed: copy it into the edit line, dispatch,
/// and paint. This is the headless face — the same container, typed over serial.
///
/// Unlike a keystroke this paints inside the trap, exactly like the existing
/// `Ui` band command: the operator typed a command on the console and the answer
/// is the next frame, not the next tick. `commits` is the scanout chain the tick
/// would run (`VioPaint` / `DispPaint` / `PciPaint`).
pub fn uart_line_ops(commits: Vec<Op>) -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("zealcli: unmatched band line → edit line → CliEnter".into()),
        Op::Label("cli_uart_line".into()),
        Op::La {
            rd: T4,
            addr: Addr::UartLine,
        },
        Op::Lw {
            rd: T5,
            rs: T4,
            off: crate::CLI_UART_LEN_OFF,
        },
        Op::Lw {
            rd: T6,
            rs: T4,
            off: CLI_PROMPT_LEN_OFF,
        },
        // len = prompt_len (start of the typed text); t0 = source index.
        Op::Sw {
            rs2: T6,
            rs1: T4,
            off: CLI_LINE_LEN_OFF,
        },
        Op::Li { rd: T0, imm: 0 },
        Op::Label("culine_copy".into()),
        Op::Beq {
            rs1: T0,
            rs2: T5,
            to: "culine_run".into(),
        },
        // Bounded by the edit-line capacity, like every other write here.
        Op::Lw {
            rd: T1,
            rs: T4,
            off: CLI_LINE_LEN_OFF,
        },
        Op::Li {
            rd: T2,
            imm: i64::from(CLI_LINE_CAP),
        },
        Op::Beq {
            rs1: T1,
            rs2: T2,
            to: "culine_run".into(),
        },
        Op::Add {
            rd: T2,
            rs1: T4,
            rs2: T0,
        },
        Op::Lbu {
            rd: T2,
            rs: T2,
            off: 0,
        },
        Op::Add {
            rd: T3,
            rs1: T4,
            rs2: T1,
        },
        Op::Sb {
            rs2: T2,
            rs1: T3,
            off: CLI_LINE_OFF,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: CLI_LINE_LEN_OFF,
        },
        Op::Addi {
            rd: T0,
            rs: T0,
            imm: 1,
        },
        Op::Jal {
            rd: X0,
            to: "culine_copy".into(),
        },
        Op::Label("culine_run".into()),
        Op::Jal {
            rd: RA,
            to: "CliEnter".into(),
        },
        Op::Jal {
            rd: RA,
            to: "CliSync".into(),
        },
        Op::Jal {
            rd: RA,
            to: "DomPaint".into(),
        },
    ];
    ops.extend(commits);
    // The frame is on the screen, so the tick has nothing left to flush.
    ops.extend([
        Op::La {
            rd: T0,
            addr: Addr::UartLine,
        },
        Op::Lw {
            rd: T1,
            rs: T0,
            off: CLI_DIRTY_OFF,
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: CLI_PAINTED_OFF,
        },
        Op::Jal {
            rd: X0,
            to: "trap_done".into(),
        },
    ]);
    ops
}

/// `AutoDraw` / `AutoKey` / `AutoTick` — the guest half of the boot picker.
///
/// `AutoDraw` republishes the frame from `AUTO_SEL` / `AUTO_SECS`: the header for
/// the digit an operator would read, one row per entry in its selected or
/// unselected spelling, then the footer. Republishing beats mutating the packed
/// text — the rows stay read-only data and the paint path is unchanged.
///
/// `AutoKey` is called from `CliKey` while the picker owns the screen: up/down
/// wrap (the top entry goes to the bottom), a digit picks directly, Enter takes
/// the selection, Esc drops back to the prompt. **Any navigation stops the
/// countdown** — someone is at the keyboard, so the machine stops deciding.
///
/// `AutoTick` is called from the timer tick: it counts ticks, republishes only
/// when the second changes, and on expiry takes **entry 0** — the policy's
/// answer, not whatever happens to be selected.
fn auto_node(spec: &BoardSpec, l: &Layout, auto: &AutoBootPage) -> Node {
    let xlen = spec.isa.xlen;
    let n = auto.entries.len() as i64;
    let mut ops = vec![
        Op::Comment(format!(
            "AutoDraw/AutoKey/AutoTick — {} entr(ies), {} tick countdown ({} ticks/s), \
             order={}",
            n,
            auto.ticks,
            auto.ticks_per_sec,
            spec.boot_order().as_str()
        )),
        Op::Glob("AutoDraw".into()),
        Op::Label("AutoDraw".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        st_x(xlen, RA, SP, 8),
        Op::La {
            rd: T0,
            addr: Addr::UiDom,
        },
        Op::La {
            rd: T4,
            addr: Addr::UartLine,
        },
    ];
    // Row 0: the header for the seconds left (clamped to what was packed).
    let heads = l.auto_heads.len();
    ops.extend([
        Op::Lw {
            rd: T5,
            rs: T4,
            off: crate::AUTO_SECS_OFF,
        },
        Op::Li {
            rd: T6,
            imm: heads.saturating_sub(1) as i64,
        },
        Op::Sub {
            rd: T1,
            rs1: T6,
            rs2: T5,
        },
        Op::Srli {
            rd: T1,
            rs: T1,
            shamt: crate::dom::signbit(xlen),
        },
        Op::Beq {
            rs1: T1,
            rs2: X0,
            to: "adraw_head".into(),
        },
        Op::Addi {
            rd: T5,
            rs: T6,
            imm: 0,
        },
        Op::Label("adraw_head".into()),
    ]);
    // A packed header per second: pick by index with a compare chain (bounded by
    // the countdown, so at most `timeout/1000 + 1` arms).
    for (secs, (off, len)) in l.auto_heads.iter().enumerate() {
        let next = format!("adraw_h{secs}");
        ops.extend([
            Op::Li {
                rd: T6,
                imm: secs as i64,
            },
            Op::Bne {
                rs1: T5,
                rs2: T6,
                to: next.clone(),
            },
        ]);
        ops.extend(publish_one(xlen, 0, *off, *len));
        ops.push(Op::Jal {
            rd: X0,
            to: "adraw_rows".into(),
        });
        ops.push(Op::Label(next));
    }
    ops.push(Op::Label("adraw_rows".into()));
    // One row per entry: selected spelling for `AUTO_SEL`, plain otherwise.
    for (i, (plain, sel)) in l.auto_rows.iter().enumerate() {
        let plain_lbl = format!("adraw_plain{i}");
        let done = format!("adraw_row{i}");
        ops.extend([
            Op::Lw {
                rd: T5,
                rs: T4,
                off: crate::AUTO_SEL_OFF,
            },
            Op::Li {
                rd: T6,
                imm: i as i64,
            },
            Op::Bne {
                rs1: T5,
                rs2: T6,
                to: plain_lbl.clone(),
            },
        ]);
        ops.extend(publish_one(xlen, i + 1, sel.0, sel.1));
        ops.push(Op::Jal {
            rd: X0,
            to: done.clone(),
        });
        ops.push(Op::Label(plain_lbl));
        ops.extend(publish_one(xlen, i + 1, plain.0, plain.1));
        ops.push(Op::Label(done));
    }
    // Footer, then the row count.
    let foot_row = l.auto_rows.len() + 1;
    ops.extend(publish_one(xlen, foot_row, l.auto_foot.0, l.auto_foot.1));
    ops.extend([
        Op::Li {
            rd: T1,
            imm: (foot_row + 1) as i64,
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: 0,
        },
        Op::Jal {
            rd: RA,
            to: "DomPaint".into(),
        },
        // DomPaint only reached the 4bpp plane; the scanout commit is the
        // tick's job and it runs only when CLI_DIRTY moved past CLI_PAINTED.
        // Without this a moved cursor or a countdown digit never leaves
        // `__scan_fb` — the DOM row said `> 2.` while the screen still showed 1.
        Op::La {
            rd: T1,
            addr: Addr::UartLine,
        },
        Op::Lw {
            rd: T2,
            rs: T1,
            off: CLI_DIRTY_OFF,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: 1,
        },
        Op::Sw {
            rs2: T2,
            rs1: T1,
            off: CLI_DIRTY_OFF,
        },
        ld_x(xlen, RA, SP, 8),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 16,
        },
        ret(),
    ]);

    // ---- AutoKey ----------------------------------------------------------
    ops.extend([
        Op::Comment("AutoKey — a1 = keycode; arrows wrap, Enter picks, Esc cancels".into()),
        Op::Glob("AutoKey".into()),
        Op::Label("AutoKey".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        st_x(xlen, RA, SP, 8),
        Op::La {
            rd: T4,
            addr: Addr::UartLine,
        },
        // Esc (KEY_ESC = 1): back to the prompt.
        Op::Li { rd: T0, imm: 1 },
        Op::Beq {
            rs1: A1,
            rs2: T0,
            to: "akey_cancel".into(),
        },
        // Enter (28): take the selection.
        Op::Li { rd: T0, imm: 28 },
        Op::Beq {
            rs1: A1,
            rs2: T0,
            to: "akey_pick".into(),
        },
        // Up (103) / Down (108): wrap, and stop the countdown.
        Op::Li { rd: T0, imm: 103 },
        Op::Beq {
            rs1: A1,
            rs2: T0,
            to: "akey_up".into(),
        },
        Op::Li { rd: T0, imm: 108 },
        Op::Beq {
            rs1: A1,
            rs2: T0,
            to: "akey_down".into(),
        },
        // A **digit** selects an entry directly, which is what the footer promises
        // ("1-9 pick"). The guest never implemented it: the digits fell through to
        // "unhandled" while the screen advertised them, so an operator pressing `3`
        // got the default entry on Enter. A face that offers a key must honour it.
        //
        // `KEY_1..KEY_9` are Linux keycodes 2..=10, so the entry index is
        // `code - 2`. The comparison is *unsigned*, which is also what rejects
        // everything below `KEY_1`: `1 - 2` wraps to a huge number instead of going
        // negative. `KEY_0` (11 → index 9) is excluded by the same bound.
        Op::Addi {
            rd: T1,
            rs: A1,
            imm: -2,
        },
        Op::Li {
            rd: T0,
            imm: n.min(9),
        },
        Op::Sltu {
            rd: T2,
            rs1: T1,
            rs2: T0,
        },
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "akey_done".into(),
        },
        // A deliberate keypress stops the countdown, exactly as an arrow does.
        Op::Sw {
            rs2: X0,
            rs1: T4,
            off: crate::AUTO_TICKS_OFF,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: crate::AUTO_SEL_OFF,
        },
        Op::Jal {
            rd: X0,
            to: "akey_redraw".into(),
        },
        Op::Label("akey_up".into()),
        Op::Sw {
            rs2: X0,
            rs1: T4,
            off: crate::AUTO_TICKS_OFF,
        },
        Op::Lw {
            rd: T1,
            rs: T4,
            off: crate::AUTO_SEL_OFF,
        },
        // sel == 0 ? n-1 : sel-1  — the wraparound the operator expects.
        Op::Bne {
            rs1: T1,
            rs2: X0,
            to: "akey_up1".into(),
        },
        Op::Li { rd: T1, imm: n },
        Op::Label("akey_up1".into()),
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: -1,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: crate::AUTO_SEL_OFF,
        },
        Op::Jal {
            rd: X0,
            to: "akey_redraw".into(),
        },
        Op::Label("akey_down".into()),
        Op::Sw {
            rs2: X0,
            rs1: T4,
            off: crate::AUTO_TICKS_OFF,
        },
        Op::Lw {
            rd: T1,
            rs: T4,
            off: crate::AUTO_SEL_OFF,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        Op::Li { rd: T0, imm: n },
        Op::Bne {
            rs1: T1,
            rs2: T0,
            to: "akey_down1".into(),
        },
        Op::Li { rd: T1, imm: 0 },
        Op::Label("akey_down1".into()),
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: crate::AUTO_SEL_OFF,
        },
        Op::Label("akey_redraw".into()),
        Op::Jal {
            rd: RA,
            to: "AutoDraw".into(),
        },
        Op::Jal {
            rd: X0,
            to: "akey_done".into(),
        },
        Op::Label("akey_cancel".into()),
    ]);
    puts(&mut ops, "AUTOBOOT-CANCEL\n");
    ops.extend([
        Op::Sw {
            rs2: X0,
            rs1: T4,
            off: crate::AUTO_ON_OFF,
        },
        Op::Sw {
            rs2: X0,
            rs1: T4,
            off: crate::AUTO_TICKS_OFF,
        },
        // The question was answered; the prompt must not ask it again.
        Op::Li { rd: T1, imm: 1 },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: crate::AUTO_DONE_OFF,
        },
        Op::Jal {
            rd: RA,
            to: "CliInit".into(),
        },
        Op::Jal {
            rd: X0,
            to: "akey_done".into(),
        },
        Op::Label("akey_pick".into()),
        Op::Jal {
            rd: RA,
            to: "AutoPick".into(),
        },
        Op::Label("akey_done".into()),
        ld_x(xlen, RA, SP, 8),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 16,
        },
        ret(),
    ]);

    // ---- AutoPick ---------------------------------------------------------
    // The handoff the payload can honestly perform: name the entry, read the
    // medium itself when a block driver is compiled, and say which stage is
    // still staged. `BlkSig` names the medium from its own bytes; `FatRead`/
    // `Ext4Read` then read the file a superfloppy reader can reach. Loading a
    // payload *image* by name and jumping to it is the remaining stage.
    ops.extend([
        Op::Comment("AutoPick — announce the taken entry; BIOS UI hands over, others park".into()),
        Op::Glob("AutoPick".into()),
        Op::Label("AutoPick".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        st_x(xlen, RA, SP, 8),
        Op::La {
            rd: T4,
            addr: Addr::UartLine,
        },
        Op::Sw {
            rs2: X0,
            rs1: T4,
            off: crate::AUTO_ON_OFF,
        },
        Op::Sw {
            rs2: X0,
            rs1: T4,
            off: crate::AUTO_TICKS_OFF,
        },
        Op::Li { rd: T1, imm: 1 },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: crate::AUTO_DONE_OFF,
        },
        Op::Lw {
            rd: T5,
            rs: T4,
            off: crate::AUTO_SEL_OFF,
        },
    ]);
    for (i, (id, _, _)) in auto.entries.iter().enumerate() {
        let next = format!("apick_n{i}");
        ops.extend([
            Op::Li {
                rd: T6,
                imm: i as i64,
            },
            Op::Bne {
                rs1: T5,
                rs2: T6,
                to: next.clone(),
            },
        ]);
        puts(&mut ops, &format!("AUTOBOOT-PICK {id}\n"));
        if id == "bios-ui" && spec.kernel.wasm.enable {
            // Hand the plane over first: from here keys are the browser's and the
            // timer tick paints its DOM, which is what `WasmUi` is about to fill.
            ops.extend([
                Op::La {
                    rd: T4,
                    addr: Addr::UartLine,
                },
                Op::Li {
                    rd: T5,
                    imm: crate::FACE_WEB,
                },
                Op::Sw {
                    rs2: T5,
                    rs1: T4,
                    off: crate::FACE_OWNER_OFF,
                },
            ]);
            if spec.wants_virtio_gpu() || spec.wants_disp_scan() || spec.wants_pci_scan() {
                ops.extend([
                    Op::La {
                        rd: T0,
                        addr: Addr::VioBss,
                    },
                    Op::Li {
                        rd: T1,
                        imm: spec.default_surface().code() as i64,
                    },
                    Op::Sw {
                        rs2: T1,
                        rs1: T0,
                        off: crate::vio::DISP_SEL_SURFACE,
                    },
                ]);
            }
            puts(&mut ops, "AUTOBOOT-UI browser face owns the plane\n");
            ops.extend([
                Op::La {
                    rd: T4,
                    addr: Addr::UiDom,
                },
                Op::Sw {
                    rs2: X0,
                    rs1: T4,
                    off: 0,
                },
            ]);
            if spec.kernel.wasm.guest_jit {
                // The packed scene is the browser face's canvas: `WebPaint`
                // replays `__web_dl` (or the `__web_pk` pixels) and stamps
                // `__ui_cap` (a0=1); `WasmUi`'s row-table paint is the
                // no-pack fallback.
                ops.push(Op::Jal {
                    rd: RA,
                    to: "WebPaint".into(),
                });
                ops.push(Op::Bne {
                    rs1: A0,
                    rs2: X0,
                    to: "apick_nowasm".into(),
                });
            }
            ops.push(Op::Jal {
                rd: RA,
                to: "WasmUi".into(),
            });
            if spec.kernel.wasm.guest_jit {
                ops.push(Op::Label("apick_nowasm".into()));
            }
            if spec.kernel.wasm.guest_jit {
                // The styled `__dom` tree was populated by the shipped cell at
                // boot (JitRun) and may already have painted once — consuming
                // its dirty watermark while the picker still owned the plane.
                // Force the header dirty so the face-gated timer tick re-lays
                // out and re-rasters it onto the surface the picker vacated.
                ops.extend([
                    Op::La {
                        rd: T4,
                        addr: Addr::DomT,
                    },
                    Op::Li { rd: T5, imm: 1 },
                    Op::Sw {
                        rs2: T5,
                        rs1: T4,
                        off: crate::domt::H_DIRTY,
                    },
                ]);
            }
        } else if id == "payload" {
            ops.push(Op::Jal {
                rd: RA,
                to: "CliInit".into(),
            });
        } else if spec.wants_virtio_blk() {
            // A medium the guest can read itself now: name what it is, and let
            // the filesystem readers report the file they can reach. What is
            // still staged is loading a payload *image* by name — the actual
            // kernel handoff — so the line says read, not boot.
            ops.extend([
                Op::Jal {
                    rd: RA,
                    to: "BlkSig".into(),
                },
                Op::Jal {
                    rd: RA,
                    to: "FatRead".into(),
                },
                Op::Jal {
                    rd: RA,
                    to: "Ext4Read".into(),
                },
            ]);
            puts(
                &mut ops,
                "AUTOBOOT-HANDOFF medium read; payload image load staged (B98)\n",
            );
        } else {
            // A medium on a volume with no compiled reader: the next stage is
            // named, and the reason it is not entered here is named too.
            puts(
                &mut ops,
                "AUTOBOOT-HANDOFF no block reader in this payload yet (B98)\n",
            );
        }
        ops.push(Op::Jal {
            rd: X0,
            to: "apick_done".into(),
        });
        ops.push(Op::Label(next));
    }
    ops.extend([
        Op::Label("apick_done".into()),
        ld_x(xlen, RA, SP, 8),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 16,
        },
        ret(),
    ]);

    // ---- AutoTick ---------------------------------------------------------
    ops.extend([
        Op::Comment("AutoTick — count ticks, redraw on a second change, expire to entry 0".into()),
        Op::Glob("AutoTick".into()),
        Op::Label("AutoTick".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        st_x(xlen, RA, SP, 8),
        Op::La {
            rd: T4,
            addr: Addr::UartLine,
        },
        Op::Lw {
            rd: T0,
            rs: T4,
            off: crate::AUTO_ON_OFF,
        },
        Op::Beq {
            rs1: T0,
            rs2: X0,
            to: "atick_done".into(),
        },
        Op::Lw {
            rd: T1,
            rs: T4,
            off: crate::AUTO_TICKS_OFF,
        },
        Op::Beq {
            rs1: T1,
            rs2: X0,
            to: "atick_done".into(),
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: -1,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: crate::AUTO_TICKS_OFF,
        },
        Op::Beq {
            rs1: T1,
            rs2: X0,
            to: "atick_expire".into(),
        },
        // secs = ticks / ticks_per_sec, rounded up so "1s" is shown until 0.
        Op::Li {
            rd: T2,
            imm: i64::from(auto.ticks_per_sec.max(1)),
        },
        Op::Addi {
            rd: T3,
            rs: T2,
            imm: -1,
        },
        Op::Add {
            rd: T3,
            rs1: T1,
            rs2: T3,
        },
        Op::Divu {
            rd: T3,
            rs1: T3,
            rs2: T2,
        },
        Op::Lw {
            rd: T5,
            rs: T4,
            off: crate::AUTO_SECS_OFF,
        },
        Op::Beq {
            rs1: T3,
            rs2: T5,
            to: "atick_done".into(),
        },
        Op::Sw {
            rs2: T3,
            rs1: T4,
            off: crate::AUTO_SECS_OFF,
        },
        Op::Jal {
            rd: RA,
            to: "AutoDraw".into(),
        },
        Op::Jal {
            rd: X0,
            to: "atick_done".into(),
        },
        Op::Label("atick_expire".into()),
        // Expiry takes entry 0, not the selection.
        Op::Sw {
            rs2: X0,
            rs1: T4,
            off: crate::AUTO_SEL_OFF,
        },
        Op::Sw {
            rs2: X0,
            rs1: T4,
            off: crate::AUTO_SECS_OFF,
        },
        Op::Jal {
            rd: RA,
            to: "AutoDraw".into(),
        },
        Op::Jal {
            rd: RA,
            to: "AutoPick".into(),
        },
        Op::Label("atick_done".into()),
        ld_x(xlen, RA, SP, 8),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 16,
        },
        ret(),
    ]);
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// Point `__ui_dom` row `at` (T0 = table) at packed text.
fn publish_one(xlen: u32, at: usize, off: usize, len: usize) -> Vec<Op> {
    let base = crate::dom::DOM_HDR + (at as i32) * 32;
    vec![
        Op::La {
            rd: T1,
            addr: Addr::Label("cli_data".into()),
        },
        Op::Li {
            rd: T2,
            imm: off as i64,
        },
        Op::Add {
            rd: T1,
            rs1: T1,
            rs2: T2,
        },
        st_x(xlen, T1, T0, base + 8),
        Op::Li {
            rd: T2,
            imm: len as i64,
        },
        Op::Sw {
            rs2: T2,
            rs1: T0,
            off: base + 20,
        },
        Op::Li {
            rd: T2,
            imm: crate::dom::DOM_F_VISIBLE | crate::dom::DOM_F_TEXT,
        },
        Op::Sw {
            rs2: T2,
            rs1: T0,
            off: base + 24,
        },
    ]
}

/// `CliSync` — copy the live edit-line length into the last published row, so
/// the painter shows what has been typed without republishing the table.
pub fn sync_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let _ = xlen;
    Node {
        purpose: Purpose::UiDom,
        ops: vec![
            Op::Comment("CliSync — prompt row text_len = live edit-line length".into()),
            Op::Glob("CliSync".into()),
            Op::Label("CliSync".into()),
            Op::La {
                rd: T0,
                addr: Addr::UiDom,
            },
            Op::Lw {
                rd: T1,
                rs: T0,
                off: 0,
            },
            Op::Beq {
                rs1: T1,
                rs2: X0,
                to: "csync_done".into(),
            },
            // row = count - 1 (the prompt is always last).
            Op::Addi {
                rd: T1,
                rs: T1,
                imm: -1,
            },
            Op::Slli {
                rd: T1,
                rs: T1,
                shamt: 5,
            },
            Op::Add {
                rd: T1,
                rs1: T0,
                rs2: T1,
            },
            Op::Addi {
                rd: T1,
                rs: T1,
                imm: crate::dom::DOM_HDR,
            },
            Op::La {
                rd: T2,
                addr: Addr::UartLine,
            },
            Op::Lw {
                rd: T3,
                rs: T2,
                off: CLI_LINE_LEN_OFF,
            },
            Op::Sw {
                rs2: T3,
                rs1: T1,
                off: 20,
            },
            Op::Label("csync_done".into()),
            ret(),
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_init_schedules_a_scanout_commit() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let auto = AutoBootPage::default();
        let layout = layout(&[], &[], &auto);
        let node = init_node(&spec, &layout, 0, &auto);
        assert!(node.ops.iter().any(
            |op| matches!(op, Op::Sw { rs2, off, .. } if *off == CLI_DIRTY_OFF && *rs2 != X0)
        ));
    }

    #[test]
    fn picker_is_armed_only_after_initial_draw() {
        let mut spec =
            BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        spec.kernel.cli.autoboot.enable = true;
        let auto = AutoBootPage {
            headers: vec!["AUTOBOOT".into()],
            entries: vec![("bios-ui".into(), "BIOS UI".into(), "> BIOS UI".into())],
            footer: "pick one".into(),
            ticks: 0,
            ticks_per_sec: 0,
        };
        let layout = layout(&[], &[], &auto);
        let node = init_node(&spec, &layout, 0, &auto);
        let draw = node
            .ops
            .iter()
            .position(|op| matches!(op, Op::Jal { to, .. } if to == "AutoDraw"))
            .unwrap();
        let arm = node.ops.iter().position(|op| matches!(op, Op::Sw { off, rs2, .. } if *off == crate::AUTO_ON_OFF && *rs2 != X0)).unwrap();
        assert!(
            draw < arm,
            "input must not observe a partially initialized picker"
        );
    }

    #[test]
    fn auto_draw_schedules_a_scanout_commit() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let auto = AutoBootPage {
            headers: vec!["AUTOBOOT".into()],
            entries: vec![
                ("a".into(), "  1. A".into(), "> 1. A".into()),
                ("b".into(), "  2. B".into(), "> 2. B".into()),
            ],
            footer: "pick one".into(),
            ticks: 0,
            ticks_per_sec: 0,
        };
        let layout = layout(&[], &[], &auto);
        let node = auto_node(&spec, &layout, &auto);
        // AutoDraw paints the plane but the commit is the tick's; without a
        // dirty bump the moved cursor (or countdown digit) never leaves __scan_fb.
        assert!(node.ops.iter().any(
            |op| matches!(op, Op::Sw { rs2, off, .. } if *off == CLI_DIRTY_OFF && *rs2 != X0)
        ));
    }

    fn spec() -> BoardSpec {
        BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"barebone","isa":{"xlen":64}}"#)
            .unwrap()
    }

    #[test]
    fn keymap_covers_the_typing_keys_only() {
        assert_eq!(keycode_ascii(30), b'a');
        assert_eq!(keycode_ascii(16), b'q');
        assert_eq!(keycode_ascii(2), b'1');
        assert_eq!(keycode_ascii(57), b' ');
        assert_eq!(keycode_ascii(53), b'/');
        assert_eq!(keycode_ascii(12), b'-');
        // Modifiers, arrows, function keys and Enter are commands, not text.
        for code in [1u8, 14, 28, 42, 54, 59, 103, 108, 111] {
            assert_eq!(keycode_ascii(code), 0, "keycode {code} is not text");
        }
        assert_eq!(keymap_bytes().len(), 128);
    }

    #[test]
    fn pages_and_rows_come_from_the_boot_log() {
        let log = b"G6LC-BIOS\nCLI| banner row\nCLI| second\nCLI:help| help one\n\
                    CLI:help| help two\nCLI:menu| menu one\nnoise\n\0";
        let rows = rows_from_log(&spec(), Some(log));
        assert_eq!(rows, ["banner row", "second"]);
        let pages = pages_from_log(Some(log));
        assert_eq!(pages.len(), 2);
        assert_eq!(pages[0].name, "help");
        assert_eq!(pages[0].rows, ["help one", "help two"]);
        assert_eq!(pages[1].name, "menu");
        // Commands: the fixed verbs plus one per page.
        let cmds = commands(&pages);
        assert!(cmds.iter().any(|c| c.name == "clear"));
        assert!(cmds.iter().any(|c| c.name == "reboot"));
        assert!(cmds.iter().any(|c| c.name == "shutdown"));
        assert_eq!(
            cmds.iter()
                .filter(|c| matches!(c.action, Action::Page(_)))
                .count(),
            2
        );
        // No log (listing path) still yields a linkable container.
        assert_eq!(rows_from_log(&spec(), None).len(), 1);
        assert!(pages_from_log(None).is_empty());
    }

    #[test]
    fn pages_are_bounded() {
        let mut log = String::from("G6LC-BIOS\n");
        for p in 0..(MAX_PAGES + 4) {
            for r in 0..(MAX_PAGE_ROWS + 4) {
                log.push_str(&format!("CLI:p{p}| row {r}\n"));
            }
        }
        let pages = pages_from_log(Some(log.as_bytes()));
        assert_eq!(pages.len(), MAX_PAGES);
        assert!(pages.iter().all(|p| p.rows.len() == MAX_PAGE_ROWS));
        // A name that cannot fit the fixed-stride table is dropped, not cut.
        let long = format!("CLI:{}| row\n", "x".repeat(CMD_NAME_BYTES + 1));
        assert!(pages_from_log(Some(long.as_bytes())).is_empty());
    }

    #[test]
    fn nodes_define_every_label_the_face_calls() {
        let log = b"CLI| banner\nCLI:help| help row\n\0";
        let ns = nodes(&spec(), Some(log));
        let asm = ns
            .iter()
            .flat_map(|n| n.ops.iter())
            .fold(String::new(), |mut acc, op| {
                acc.push_str(&format!("{op:?}\n"));
                acc
            });
        for label in ["CliInit", "CliKey", "CliEnter", "cli_keymap", "cli_data"] {
            assert!(asm.contains(label), "missing {label}");
        }
        // Serial markers are per-byte `putc` ops, so the dispatch table is
        // checked through the node comment that lists it.
        assert!(asm.contains("CliEnter — dispatch one line"), "{asm}");
        assert!(asm.contains("help"), "the packed page is a verb: {asm}");
        // Every branch target the nodes name must be defined by them.
        let defined: Vec<String> = ns
            .iter()
            .flat_map(|n| n.ops.iter())
            .filter_map(|op| match op {
                Op::Label(l) => Some(l.clone()),
                _ => None,
            })
            .collect();
        for op in ns.iter().flat_map(|n| n.ops.iter()) {
            let to = match op {
                Op::Jal { to, .. } | Op::Beq { to, .. } | Op::Bne { to, .. } => to.clone(),
                _ => continue,
            };
            // `DomPaint` / `CliSync` live in their own nodes.
            if matches!(to.as_str(), "DomPaint" | "CliSync") {
                continue;
            }
            assert!(defined.contains(&to), "undefined branch target {to}");
        }
    }
}
