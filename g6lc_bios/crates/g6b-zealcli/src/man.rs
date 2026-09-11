// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `man` — the printed manual, generated for **this** board.
//!
//! A generic help text in firmware is worse than none: it lists commands that
//! were compiled out and keys that no device produces. So the manual is derived
//! from the same BoardSpec the build used — compiled features decide which
//! sections exist, the keyboard section names the actual input source, the
//! settings section lists the writable rows with their accepted values, and the
//! HolyC section lists the builtins that are really registered. It is wrapped to
//! the container width so it reads the same on VGA, on the UART band, and on a
//! sheet of paper.

use g6b_holyc::HOLYC_BUILTIN_NAMES;
use g6b_spec::BoardSpec;

use crate::cmd::Command;
use crate::screen::{wrap, wrap_words};
use crate::settings::writable_table;

/// One manual section.
struct Section {
    title: &'static str,
    body: String,
}

/// Render the whole manual, or one named section (`man keys`).
pub fn manual(spec: &BoardSpec, cols: usize, topic: &str) -> String {
    let sections = sections(spec, cols);
    let topic = topic.trim().to_ascii_lowercase();
    let mut out = String::new();
    let mut hit = false;
    for s in &sections {
        if !topic.is_empty() && !s.title.to_ascii_lowercase().starts_with(&topic) {
            continue;
        }
        hit = true;
        out.push_str(s.title);
        out.push('\n');
        let width = cols.saturating_sub(4).max(20);
        for line in s.body.lines() {
            // Prose wraps on words; a pre-formatted table row (leading spaces)
            // is a layout the reader depends on, so it is cut, not reflowed.
            let rows = if line.starts_with(' ') {
                wrap(line, width)
            } else {
                wrap_words(line, width)
            };
            for row in rows {
                out.push_str("    ");
                out.push_str(&row);
                out.push('\n');
            }
        }
        out.push('\n');
    }
    if !hit {
        let names: Vec<String> = sections
            .iter()
            .map(|s| {
                s.title
                    .split_whitespace()
                    .next()
                    .unwrap_or("")
                    .to_ascii_lowercase()
            })
            .collect();
        return format!("man: no section `{topic}`; try {}\n", names.join(", "));
    }
    out
}

/// Section names for completion / diagnostics.
pub fn topics(spec: &BoardSpec) -> Vec<String> {
    sections(spec, 80)
        .iter()
        .map(|s| {
            s.title
                .split_whitespace()
                .next()
                .unwrap_or("")
                .to_ascii_lowercase()
        })
        .collect()
}

fn sections(spec: &BoardSpec, cols: usize) -> Vec<Section> {
    let cli = &spec.kernel.cli;
    let mut out = vec![Section {
        title: "NAME",
        body: format!(
            "zealcli - G6LC-BIOS setup shell for {} ({} profile, rv{} {})\n\
             The BIOS face is a {}x{} text container: output scrolls above, the \
             command prompt is the bottom row.",
            spec.product,
            spec.kernel.profile.as_str(),
            spec.isa.xlen,
            spec.isa.march,
            cli.cols,
            cli.rows
        ),
    }];

    out.push(Section {
        title: "BOOT ORDER",
        body: if spec.web_stack() {
            format!(
                "This build carries the web stack (wasm+js+dom+render+css). zealcli \
                 still comes up first — `kernel.cli.boot={}` — and `LoadUI` hands the \
                 screen to browser-ui once a GPU is announced. Until then every \
                 setting is reachable from this prompt.",
                cli.boot
            )
        } else {
            "This is a barebone build: the web stack (wasm+js+dom+render+css) is not \
             compiled. zealcli is the only face; the kernel, the HolyC band, the \
             network adapter and the USB key work without it."
                .into()
        },
    });

    out.push(Section {
        title: "KEYBOARD",
        body: {
            let mut b = format!(
                "Input source: {} (Linux KEY_* codes; a USB HID keyboard, \
                 virtio-keyboard and the UART band all decode the same way).\n\
                 Editing: printable keys insert, Backspace/Delete erase, Left/Right \
                 and Home/End move, Up/Down walk history, Esc clears the line, \
                 Enter runs it.\n\
                 Scrolling: PgUp/PgDn page the container, `scroll top` / `scroll \
                 tail` jump. While scrolled back the bottom row still holds the \
                 prompt and the row above states the range.",
                spec.keyboard_kind()
            );
            b.push('\n');
            b.push_str(if cli.mouse {
                "Pointer: optional mouse is ON — the wheel scrolls the container and a \
                 click on a scrollback row selects it. Every one of those actions has \
                 a key equivalent."
            } else {
                "Pointer: optional mouse is OFF (kernel.cli.mouse). The CLI is \
                 keyboard-complete; a pointer only ever scrolls or selects."
            });
            b
        },
    });

    let mut cmds = String::new();
    for c in Command::compiled(spec) {
        cmds.push_str(&format!("{:<26} {}\n", c.usage, c.help));
    }
    out.push(Section {
        title: "COMMANDS",
        body: cmds,
    });

    if !spec.writables().is_empty() {
        out.push(Section {
            title: "SETTINGS",
            body: format!(
                "Setup rows are a view of what was compiled; only these can be \
                 written. A write goes to an overlay and is exported as a BoardSpec \
                 patch (`save`), which the next build/boot picks up — the running \
                 image is never rewritten under you.\n{}",
                writable_table(spec)
            ),
        });
    }

    if cli.fs {
        out.push(Section {
            title: "VOLUMES",
            body: format!(
                "Storage is addressed ZealOS-style, by drive: `Drv` lists them, \
                 `cd KEY-FAT:/backup` enters one, `..` from a drive root returns to \
                 the BIOS tree. Compiled filesystems: {}. A drive that is not there \
                 is refused, never faked.",
                fs_list(spec)
            ),
        });
    }

    if cli.fw {
        out.push(Section {
            title: "FIRMWARE",
            body: format!(
                "`fw update https://…` or `fw update DRIVE:/image` arms a transfer; \
                 `fw` shows the phase; `fw apply` commits after staging; `fw cancel` \
                 drops it. Firmware is HTTPS-only over the network — plain HTTP is \
                 refused — and the phases are fetch → verify → stage → ready. \
                 Verification is the image magic and size here plus the sha256 the \
                 kernel reports on stage; compare it before applying.\n\
                 Default URL: {}\nFlash backend: {} (image {})",
                if spec.kernel.flash.url.is_empty() {
                    "(none — pass one or use a USB key)"
                } else {
                    spec.kernel.flash.url.as_str()
                },
                spec.kernel.flash.backend,
                spec.kernel.flash.image
            ),
        });
    }

    if cli.vi {
        out.push(Section {
            title: "VIEWER",
            body: "`vi FILE` opens the read-only viewer: h j k l / arrows move, 0 $ \
                   line ends, gg G buffer ends, Ctrl-F/Ctrl-B or PgUp/PgDn page, \
                   /pattern then n N search, :set number, :NN jumps, :q closes. Every \
                   editing key answers with vi's read-only refusal — this viewer \
                   cannot write, by construction."
                .into(),
        });
    }

    out.push(Section {
        title: "HOLYC",
        body: format!(
            "Any registered HolyC builtin can be called from this prompt \
             (`Print(\"hi\");`), and a bare name is invoked as `Name()`. Registered \
             now ({}):\n{}",
            HOLYC_BUILTIN_NAMES.len(),
            columns(HOLYC_BUILTIN_NAMES, cols.saturating_sub(4).max(20))
        ),
    });

    out.push(Section {
        title: "FEATURES",
        body: format!(
            "Compiled into this image:\n{}",
            columns(
                &spec
                    .compiled_features()
                    .iter()
                    .filter(|(_, v)| *v)
                    .map(|(k, _)| *k)
                    .collect::<Vec<_>>(),
                cols.saturating_sub(4).max(20)
            )
        ),
    });

    out
}

fn fs_list(spec: &BoardSpec) -> String {
    let u = &spec.kernel.usb;
    let mut v: Vec<&str> = Vec::new();
    if u.fs_fat32 {
        v.push("fat32");
    }
    if u.fs_ntfs {
        v.push("ntfs");
    }
    if u.fs_ext4 {
        v.push("ext4");
    }
    if u.fs_btrfs {
        v.push("btrfs");
    }
    if v.is_empty() {
        "none".into()
    } else {
        v.join(", ")
    }
}

/// Pack short names into `cols`-wide rows (the manual's list layout).
fn columns(names: &[&str], cols: usize) -> String {
    let width = names.iter().map(|n| n.len()).max().unwrap_or(1) + 2;
    let per = (cols / width).max(1);
    let mut s = String::new();
    for (i, n) in names.iter().enumerate() {
        s.push_str(&format!("{n:<width$}"));
        if (i + 1) % per == 0 {
            s.push('\n');
        }
    }
    if !s.ends_with('\n') {
        s.push('\n');
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(profile: &str) -> BoardSpec {
        BoardSpec::from_json_str(&format!(r#"{{"schema_version":1,"profile":"{profile}"}}"#))
            .unwrap()
    }

    /// The manual is wrapped for a container, so phrases are asserted against a
    /// whitespace-flattened copy rather than against a particular line break.
    fn flat(s: &str) -> String {
        s.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    #[test]
    fn manual_is_generated_for_this_board() {
        let s = spec("barebone");
        let m = manual(&s, 80, "");
        let f = flat(&m);
        assert!(
            f.contains("zealcli - G6LC-BIOS setup shell for barebone"),
            "{m}"
        );
        assert!(f.contains("barebone build"), "{m}");
        assert!(f.contains("usb-hid"), "the real keyboard source: {m}");
        assert!(f.contains("HTTPS-only"), "{m}");
        assert!(f.contains("read-only refusal"), "{m}");
        assert!(f.contains("kernel.params.next"), "writable rows: {m}");
        // Every line fits the container.
        assert!(m.lines().all(|l| l.chars().count() <= 80), "{m}");
        // Compiled-out slices are never advertised.
        assert!(!f.contains("hands the screen to browser-ui"), "{m}");
        for n in HOLYC_BUILTIN_NAMES {
            assert!(m.contains(n), "missing builtin {n}");
        }
    }

    #[test]
    fn web_build_documents_the_boot_order() {
        let s = spec("full");
        let m = manual(&s, 80, "");
        let f = flat(&m);
        assert!(f.contains("web stack (wasm+js+dom+render+css)"), "{m}");
        assert!(f.contains("zealcli still comes up first"), "{m}");
        assert!(f.contains("hands the screen to browser-ui"), "{m}");
        assert!(m.contains("LoadUI"), "{m}");
        assert!(m.lines().all(|l| l.chars().count() <= 80), "{m}");
    }

    #[test]
    fn sections_are_addressable_and_unknown_topics_refuse() {
        let s = spec("barebone");
        let keys = manual(&s, 80, "keyboard");
        assert!(keys.contains("KEYBOARD"), "{keys}");
        assert!(!keys.contains("COMMANDS"), "{keys}");
        let bad = manual(&s, 80, "nope");
        assert!(bad.contains("no section"), "{bad}");
        assert!(bad.contains("keyboard"), "{bad}");
        assert!(topics(&s).contains(&"firmware".to_string()));
    }

    #[test]
    fn narrow_container_still_wraps() {
        let s = spec("barebone");
        let m = manual(&s, 40, "");
        assert!(m.lines().all(|l| l.chars().count() <= 40), "{m}");
    }
}
