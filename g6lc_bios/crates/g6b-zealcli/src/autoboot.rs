// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `autoboot` — the countdown boot picker.
//!
//! What an operator needs at power-on: a short list of what is actually
//! attached, arrow keys with wraparound, Enter to take one, Esc to stay in
//! setup, and a countdown that picks the first entry if nobody is watching. The
//! list is **discovered** ([`crate::detect`]) and every row carries its evidence,
//! because a boot menu that guesses gets acted on.
//!
//! Ordering is policy, and the policy is compiled in
//! (`kernel.cli.autoboot.order`, writable from setup):
//!
//! | order | first |
//! |---|---|
//! | `live-first` | recovery media — a live USB or an installer ISO, which is what you reach for when the installed OS is the broken thing |
//! | `os-first` | an installed, working OS; recovery stays reachable below it |
//! | `payload-first` | this payload — stay in setup |
//!
//! The BIOS UI is offered as the **last** entry when the web stack is compiled,
//! so a build without it never advertises a face it does not have.

use g6b_bootctl::{Decision, Reason};
use g6b_spec::{BoardSpec, BootOrder};

use crate::detect::{self, Found, Medium};
use crate::input::Key;
use crate::ports::Ports;
use crate::screen::truncate;

/// What an entry does when it is taken.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    /// Hand off to a medium on a volume.
    Volume,
    /// Stay in this payload (setup).
    Payload,
    /// Load the browser-UI face.
    BiosUi,
}

/// One row of the picker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// Selector id (`openwrt@FLASH`, `payload`, `bios-ui`).
    pub id: String,
    /// Operator-facing name — the detected medium, or the face.
    pub name: String,
    /// Device the entry lives on: the reported vendor, else the volume label.
    pub device: String,
    /// Volume id, empty for the payload / BIOS UI.
    pub volume: String,
    pub medium: Medium,
    pub target: Target,
    /// What proved this entry.
    pub evidence: String,
    /// Next-stage name to latch (`opensbi`, `edk2`, `u-boot`, `linux`).
    pub stage: String,
}

impl Entry {
    /// One row, `cols` wide: `> 2. OpenWrt 24.10  [firmware]  SanDisk Ultra`.
    pub fn row(&self, index: usize, selected: bool, cols: usize) -> String {
        let mark = if selected { '>' } else { ' ' };
        let device = if self.device.is_empty() {
            String::new()
        } else {
            format!("  {}", self.device)
        };
        truncate(
            &format!(
                "{mark} {}. {:<28} [{}]{}",
                index + 1,
                self.name,
                self.medium.as_str(),
                device
            ),
            cols,
        )
    }
}

/// Priority for the compiled order. Lower sorts first.
fn rank(order: BootOrder, e: &Entry) -> u8 {
    match (order, e.target, e.medium) {
        // Setup first: everything else keeps its relative order below it.
        (BootOrder::PayloadFirst, Target::Payload, _) => 0,
        (_, Target::BiosUi, _) => 250,
        // Setup is the fallback under the other orders — it ranks by *target*,
        // not by medium, or it would sort as an installed OS and jump the queue.
        (_, Target::Payload, _) => 100,
        (BootOrder::LiveFirst, _, Medium::Live) => 1,
        (BootOrder::LiveFirst, _, Medium::Installer) => 2,
        (BootOrder::LiveFirst, _, Medium::Os) => 3,
        (BootOrder::LiveFirst, _, Medium::Firmware) => 4,
        (BootOrder::OsFirst, _, Medium::Os) => 1,
        (BootOrder::OsFirst, _, Medium::Firmware) => 2,
        (BootOrder::OsFirst, _, Medium::Live) => 3,
        (BootOrder::OsFirst, _, Medium::Installer) => 4,
        (_, _, Medium::Loader) => 5,
        (_, _, Medium::Kernel) => 6,
        (_, _, Medium::Unknown) => 200,
        (_, _, _) => 8,
    }
}

/// Discover the entries this board can offer, in policy order.
pub fn entries(spec: &BoardSpec, ports: &Ports) -> Vec<Entry> {
    let order = spec.boot_order();
    let mut out: Vec<Entry> = Vec::new();
    for v in crate::fsview::drives(ports) {
        let found = detect::probe(ports, &v.id);
        if !found.medium.is_bootable() {
            continue;
        }
        out.push(Entry {
            id: format!("{}@{}", medium_id(&found), v.id),
            name: found.name.clone(),
            device: v.vendor_or_label().to_string(),
            volume: v.id.clone(),
            medium: found.medium,
            target: Target::Volume,
            evidence: found.evidence.clone(),
            stage: stage_for(&found),
        });
    }
    out.push(Entry {
        id: "payload".into(),
        name: "Setup (this payload)".into(),
        device: String::new(),
        volume: String::new(),
        medium: Medium::Os,
        target: Target::Payload,
        evidence: "the running S-mode payload".into(),
        stage: "opensbi".into(),
    });
    if spec.autoboot_offers_bios_ui() {
        out.push(Entry {
            id: "bios-ui".into(),
            name: "BIOS UI (browser)".into(),
            device: String::new(),
            volume: String::new(),
            medium: Medium::Os,
            target: Target::BiosUi,
            evidence: "web stack compiled".into(),
            stage: "opensbi".into(),
        });
    }
    // Stable sort: equal ranks keep discovery order, which is the volume order.
    out.sort_by_key(|e| rank(order, e));
    out
}

fn medium_id(f: &Found) -> &'static str {
    match f.medium {
        Medium::Live => "live",
        Medium::Installer => "install",
        Medium::Os => "os",
        Medium::Firmware => "firmware",
        Medium::Loader => "loader",
        Medium::Kernel => "kernel",
        Medium::Unknown => "unknown",
    }
}

/// Next stage a medium hands off to. A loader is its own stage; a kernel or an
/// installed system is `linux`.
fn stage_for(f: &Found) -> String {
    match f.medium {
        Medium::Loader if f.evidence.contains("EFI") => "edk2".into(),
        Medium::Loader => "u-boot".into(),
        Medium::Live | Medium::Installer | Medium::Os | Medium::Kernel | Medium::Firmware => {
            "linux".into()
        }
        Medium::Unknown => "opensbi".into(),
    }
}

/// What the session should do after a key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pick {
    /// Still counting down / still choosing.
    Waiting,
    /// Esc: stay in the command prompt.
    Cancelled,
    /// This entry was taken (by Enter or by the countdown).
    Taken(Entry),
}

/// The picker: a list, a selection, and a clock.
#[derive(Debug, Clone)]
pub struct AutoBoot {
    entries: Vec<Entry>,
    sel: usize,
    /// Milliseconds left, `None` when the countdown is off or has been stopped.
    left: Option<u32>,
    /// Compiled countdown, for the header.
    timeout_ms: u32,
    order: BootOrder,
    done: Option<Pick>,
    /// Recovery inhibit: unattended countdown must not run.
    hold: Option<Reason>,
}

impl AutoBoot {
    /// Arm the picker for this board.
    pub fn new(spec: &BoardSpec, ports: &Ports) -> Self {
        let timeout_ms = spec.kernel.cli.autoboot.timeout_ms;
        Self {
            entries: entries(spec, ports),
            sel: 0,
            left: (timeout_ms > 0).then_some(timeout_ms),
            timeout_ms,
            order: spec.boot_order(),
            done: None,
            hold: None,
        }
    }

    /// Arm or hold the picker from a boot-control decision.
    /// `Stay` inhibits unattended countdown; missing/corrupt journals must
    /// pass `Stay`, not `new()`, if recovery is required to precede AUTO_ON.
    pub fn with_decision(spec: &BoardSpec, ports: &Ports, decision: Decision) -> Self {
        let mut this = Self::new(spec, ports);
        if let Decision::Stay(reason) = decision {
            this.hold = Some(reason);
            this.left = None;
        }
        this
    }

    /// Unattended countdown is live only when health storage allowed Boot.
    pub fn unattended_armed(&self) -> bool {
        self.hold.is_none() && self.left.is_some()
    }

    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    pub fn selected(&self) -> Option<&Entry> {
        self.entries.get(self.sel)
    }

    /// Milliseconds left, or `None` once the countdown stopped.
    pub fn left_ms(&self) -> Option<u32> {
        self.left
    }

    /// True once Enter, Esc or the countdown decided.
    pub fn finished(&self) -> bool {
        self.done.is_some()
    }

    /// A key. Any navigation **stops the countdown**: someone is at the keyboard,
    /// so the machine must not take the decision out of their hands.
    pub fn key(&mut self, k: Key) -> Pick {
        if let Some(done) = &self.done {
            return done.clone();
        }
        match k {
            Key::Up | Key::Char('k') => {
                self.left = None;
                self.step(-1);
            }
            Key::Down | Key::Char('j') => {
                self.left = None;
                self.step(1);
            }
            Key::Home => {
                self.left = None;
                self.sel = 0;
            }
            Key::End => {
                self.left = None;
                self.sel = self.entries.len().saturating_sub(1);
            }
            Key::Enter => return self.take(),
            Key::Esc => {
                self.done = Some(Pick::Cancelled);
                return Pick::Cancelled;
            }
            // A digit picks directly — muscle memory from every BIOS.
            Key::Char(c) if c.is_ascii_digit() => {
                self.left = None;
                let n = (c as u8 - b'0') as usize;
                if n >= 1 && n <= self.entries.len() {
                    self.sel = n - 1;
                }
            }
            _ => {}
        }
        Pick::Waiting
    }

    /// Wraparound: the top entry goes to the bottom and back.
    fn step(&mut self, delta: i32) {
        let n = self.entries.len();
        if n == 0 {
            return;
        }
        let cur = self.sel as i32;
        let next = (cur + delta).rem_euclid(n as i32);
        self.sel = next as usize;
    }

    fn take(&mut self) -> Pick {
        let pick = match self.entries.get(self.sel) {
            Some(e) => Pick::Taken(e.clone()),
            None => Pick::Cancelled,
        };
        self.done = Some(pick.clone());
        pick
    }

    /// Advance the countdown by `ms`. Returns [`Pick::Taken`] with the **first**
    /// entry when it expires — the first, not the selected one, because the
    /// countdown is the *unattended* path and the first entry is the policy's
    /// answer.
    pub fn tick(&mut self, ms: u32) -> Pick {
        if let Some(done) = &self.done {
            return done.clone();
        }
        let Some(left) = self.left else {
            return Pick::Waiting;
        };
        let left = left.saturating_sub(ms);
        self.left = Some(left);
        if left > 0 {
            return Pick::Waiting;
        }
        self.left = None;
        self.sel = 0;
        self.take()
    }

    /// The frame: header, entries, footer. Exactly `rows` lines.
    pub fn render(&self, cols: usize, rows: usize) -> Vec<String> {
        let mut out = Vec::with_capacity(rows);
        out.push(truncate(
            &format!(
                "AUTOBOOT  order={}  {}",
                self.order.as_str(),
                match self.left {
                    Some(ms) => format!(
                        "booting first entry in {}.{}s",
                        ms / 1000,
                        (ms % 1000) / 100
                    ),
                    None if self.hold.is_some() =>
                        "HOLD recovery (unattended boot inhibited)".into(),
                    None if self.done.is_some() => "picked".into(),
                    None if self.timeout_ms == 0 => "no countdown (waiting for you)".into(),
                    None => "countdown stopped".into(),
                }
            ),
            cols,
        ));
        if self.entries.is_empty() {
            out.push(truncate("  (nothing bootable was detected)", cols));
        }
        let body = rows.saturating_sub(3).max(1);
        // Keep the selection in view when the list is longer than the container,
        // and say that the list continues — an operator must not have to guess
        // whether entry 12 exists on a screen that stops at 9.
        let more = self.entries.len() > body;
        let body = if more {
            body.saturating_sub(1).max(1)
        } else {
            body
        };
        let top = if self.sel >= body {
            self.sel + 1 - body
        } else {
            0
        };
        for (i, e) in self.entries.iter().enumerate().skip(top).take(body) {
            out.push(e.row(i, i == self.sel, cols));
        }
        if more {
            let shown = (top + body).min(self.entries.len());
            out.push(truncate(
                &format!(
                    "  -- {}-{} of {} (up/down scrolls) --",
                    top + 1,
                    shown,
                    self.entries.len()
                ),
                cols,
            ));
        }
        if let Some(e) = self.selected() {
            out.push(truncate(&format!("  {} <- {}", e.id, e.evidence), cols));
        }
        out.push(truncate(
            "  up/down wrap, 1-9 pick, Enter boots, Esc stays in setup",
            cols,
        ));
        while out.len() < rows {
            out.insert(out.len() - 1, String::new());
        }
        out.truncate(rows);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::MemVolumes;

    fn spec(order: &str, ui: bool, timeout: u32) -> BoardSpec {
        let profile = if ui { "full" } else { "barebone" };
        BoardSpec::from_json_str(&format!(
            r#"{{"schema_version":1,"profile":"{profile}","kernel":{{"cli":{{"autoboot":{{"order":"{order}","timeout_ms":{timeout},"bios_ui":{ui}}}}}}}}}"#
        ))
        .unwrap()
    }

    fn riscv_image() -> Vec<u8> {
        let mut b = vec![0u8; 0x80];
        b[0..2].copy_from_slice(b"MZ");
        b[0x40..0x44].copy_from_slice(b"PE\0\0");
        b[0x30..0x38].copy_from_slice(b"RISCV\0\0\0");
        b[0x38..0x3c].copy_from_slice(b"RSC\x05");
        b
    }

    fn iso(label: &str) -> Vec<u8> {
        let mut b = vec![0u8; 18 * 2048];
        let pvd = 16 * 2048;
        b[pvd] = 1;
        b[pvd + 1..pvd + 6].copy_from_slice(b"CD001");
        b[pvd + 6] = 1;
        let mut id = [b' '; 32];
        for (i, c) in label.bytes().take(32).enumerate() {
            id[i] = c;
        }
        b[pvd + 40..pvd + 72].copy_from_slice(&id);
        let br = 17 * 2048;
        b[br + 1..br + 6].copy_from_slice(b"CD001");
        b[br + 6] = 1;
        b[br + 7..br + 30].copy_from_slice(b"EL TORITO SPECIFICATION");
        b
    }

    /// A board with three media: an OpenWrt firmware stick, an installer ISO on
    /// a key, and an installed Linux.
    fn ports() -> Ports {
        Ports::default().with_volumes(
            MemVolumes::new()
                .volume_vendor("FLASH", "fat32", "flash", "SanDisk Ultra Fit")
                .file(
                    "FLASH",
                    "/openwrt-sifiveu-generic-sifive_unleashed.manifest",
                    b"base-files - 1~d9340319c6\n".to_vec(),
                )
                .file("FLASH", "/Image", riscv_image())
                .volume_vendor("KEY", "fat32", "key", "Kingston DataTraveler")
                .file(
                    "KEY",
                    "/ubuntu-24.04-riscv64.iso",
                    iso("UBUNTU 24_04 RISCV64"),
                )
                .volume_vendor("DISK", "ext4", "key", "Samsung SSD 870")
                .file("DISK", "/boot/grub/grub.cfg", b"menuentry\n".to_vec()),
        )
    }

    #[test]
    fn live_first_puts_recovery_media_on_top() {
        let ab = AutoBoot::new(&spec("live-first", false, 2000), &ports());
        let ids: Vec<&str> = ab.entries().iter().map(|e| e.id.as_str()).collect();
        // Installer ISO (recovery) before the installed OS and the firmware.
        assert_eq!(ids.first(), Some(&"install@KEY"), "{ids:?}");
        assert!(
            ids.iter().position(|i| *i == "os@DISK")
                < ids.iter().position(|i| *i == "firmware@FLASH"),
            "{ids:?}"
        );
        assert_eq!(
            ids.last(),
            Some(&"payload"),
            "setup is the fallback: {ids:?}"
        );
        // The rows carry the device the medium was found on.
        let first = &ab.entries()[0];
        assert_eq!(first.name, "UBUNTU 24_04 RISCV64");
        assert_eq!(first.device, "Kingston DataTraveler");
        assert_eq!(first.stage, "linux");
        assert!(first.evidence.contains("El Torito"), "{first:?}");
    }

    #[test]
    fn os_first_and_payload_first_reorder_the_same_list() {
        let os = AutoBoot::new(&spec("os-first", false, 2000), &ports());
        assert_eq!(os.entries()[0].id, "os@DISK");
        let payload = AutoBoot::new(&spec("payload-first", false, 2000), &ports());
        assert_eq!(payload.entries()[0].id, "payload");
        // Every order offers the same set, just in a different sequence.
        let mut a: Vec<String> = os.entries().iter().map(|e| e.id.clone()).collect();
        let mut b: Vec<String> = payload.entries().iter().map(|e| e.id.clone()).collect();
        a.sort();
        b.sort();
        assert_eq!(a, b);
    }

    #[test]
    fn bios_ui_is_last_and_only_when_compiled() {
        let with_ui = AutoBoot::new(&spec("live-first", true, 2000), &ports());
        assert_eq!(with_ui.entries().last().unwrap().id, "bios-ui");
        let bare = AutoBoot::new(&spec("live-first", false, 2000), &ports());
        assert!(!bare.entries().iter().any(|e| e.id == "bios-ui"));
    }

    #[test]
    fn arrows_wrap_around_and_enter_takes_the_selection() {
        let mut ab = AutoBoot::new(&spec("live-first", false, 2000), &ports());
        let n = ab.entries().len();
        assert!(n >= 4);
        assert_eq!(ab.selected().unwrap().id, "install@KEY");
        // Up from the top wraps to the bottom…
        ab.key(Key::Up);
        assert_eq!(ab.selected().unwrap().id, "payload");
        // …and down from the bottom wraps to the top.
        ab.key(Key::Down);
        assert_eq!(ab.selected().unwrap().id, "install@KEY");
        ab.key(Key::Down);
        let second = ab.selected().unwrap().id.clone();
        assert_ne!(second, "install@KEY");
        // A digit picks directly.
        ab.key(Key::Char('1'));
        assert_eq!(ab.selected().unwrap().id, "install@KEY");
        // Enter takes it, and the picker is done.
        match ab.key(Key::Enter) {
            Pick::Taken(e) => assert_eq!(e.id, "install@KEY"),
            other => panic!("{other:?}"),
        }
        assert!(ab.finished());
        // Keys after the decision do not change it.
        assert!(matches!(ab.key(Key::Down), Pick::Taken(_)));
    }

    #[test]
    fn esc_stays_in_setup_and_navigation_stops_the_clock() {
        let mut ab = AutoBoot::new(&spec("live-first", false, 2000), &ports());
        assert_eq!(ab.left_ms(), Some(2000));
        ab.key(Key::Down);
        assert_eq!(
            ab.left_ms(),
            None,
            "someone is typing: stop deciding for them"
        );
        assert_eq!(ab.tick(5000), Pick::Waiting, "a stopped clock never fires");
        assert_eq!(ab.key(Key::Esc), Pick::Cancelled);
        assert!(ab.finished());
    }

    #[test]
    fn stay_decision_inhibits_unattended_countdown() {
        let stay = AutoBoot::with_decision(
            &spec("live-first", false, 2000),
            &ports(),
            Decision::Stay(Reason::Provisioning),
        );
        assert!(!stay.unattended_armed());
        assert_eq!(stay.left_ms(), None);
        assert!(stay
            .render(80, 8)
            .iter()
            .any(|line| line.contains("HOLD recovery")));
        let mut ticking = stay.clone();
        assert_eq!(ticking.tick(5000), Pick::Waiting);
        assert!(!ticking.finished());

        let boot =
            AutoBoot::with_decision(&spec("live-first", false, 2000), &ports(), Decision::Boot);
        assert!(boot.unattended_armed());
        assert_eq!(boot.left_ms(), Some(2000));
    }

    #[test]
    fn the_countdown_takes_the_first_entry_not_the_selected_one() {
        let mut ab = AutoBoot::new(&spec("live-first", false, 2000), &ports());
        assert_eq!(ab.tick(1000), Pick::Waiting);
        assert_eq!(ab.left_ms(), Some(1000));
        match ab.tick(1000) {
            Pick::Taken(e) => assert_eq!(e.id, "install@KEY"),
            other => panic!("{other:?}"),
        }
        assert!(ab.finished());
        // `timeout_ms = 0` waits for the operator, forever.
        let mut wait = AutoBoot::new(&spec("live-first", false, 0), &ports());
        assert_eq!(wait.left_ms(), None);
        assert_eq!(wait.tick(60_000), Pick::Waiting);
        assert!(!wait.finished());
    }

    #[test]
    fn the_frame_is_fixed_geometry_and_shows_evidence() {
        let ab = AutoBoot::new(&spec("live-first", true, 2000), &ports());
        let frame = ab.render(80, 25);
        assert_eq!(frame.len(), 25);
        assert!(frame.iter().all(|l| l.chars().count() <= 80));
        assert!(frame[0].contains("AUTOBOOT"), "{:?}", frame[0]);
        assert!(frame[0].contains("order=live-first"), "{:?}", frame[0]);
        assert!(
            frame[0].contains("booting first entry in 2"),
            "{:?}",
            frame[0]
        );
        assert!(
            frame[1].starts_with("> 1."),
            "selection marker: {:?}",
            frame[1]
        );
        assert!(frame[1].contains("[installer]"), "{:?}", frame[1]);
        assert!(frame[1].contains("Kingston"), "the device: {:?}", frame[1]);
        let joined = frame.join("\n");
        assert!(joined.contains("El Torito"), "evidence on screen: {joined}");
        assert!(joined.contains("Esc stays in setup"), "{joined}");
        assert!(joined.contains("BIOS UI"), "{joined}");
        // A narrow container still fits.
        let narrow = ab.render(40, 12);
        assert_eq!(narrow.len(), 12);
        assert!(narrow.iter().all(|l| l.chars().count() <= 40));
    }

    /// A list longer than the container scrolls, and says so. Wraparound still
    /// works across the paging boundary, which is the case that breaks if paging
    /// and selection disagree.
    #[test]
    fn a_long_list_pages_and_says_how_much_is_hidden() {
        let mut vols = MemVolumes::new();
        for i in 0..9 {
            let id = format!("KEY{i}");
            vols = vols.volume_vendor(&id, "fat32", "key", "Generic USB").file(
                &id,
                "/Image",
                riscv_image(),
            );
        }
        let ports = Ports::default().with_volumes(vols);
        let mut ab = AutoBoot::new(&spec("live-first", false, 0), &ports);
        assert!(ab.entries().len() >= 10, "{} entries", ab.entries().len());
        // A short container: the frame must still be exactly `rows` lines, show
        // the marker, and report the range.
        let frame = ab.render(80, 8);
        assert_eq!(frame.len(), 8);
        let joined = frame.join("\n");
        assert!(joined.contains(" of "), "the range is shown: {joined}");
        assert!(
            frame.iter().any(|l| l.starts_with("> 1.")),
            "the selection is visible: {frame:?}"
        );
        // Scroll to the end: the window follows the selection.
        for _ in 0..ab.entries().len() - 1 {
            ab.key(Key::Down);
        }
        let last = ab.selected().unwrap().id.clone();
        let frame = ab.render(80, 8);
        assert!(
            frame.iter().any(|l| l.contains(&last[..5])),
            "the last entry is in view: {frame:?}"
        );
        assert_eq!(frame.len(), 8);
        // One more wraps to the top, and the window comes back with it.
        ab.key(Key::Down);
        assert_eq!(ab.selected().unwrap().id, ab.entries()[0].id);
        let frame = ab.render(80, 8);
        assert!(frame.iter().any(|l| l.starts_with("> 1.")), "{frame:?}");
    }

    #[test]
    fn nothing_attached_still_offers_setup() {
        let ab = AutoBoot::new(&spec("live-first", false, 2000), &Ports::default());
        assert_eq!(ab.entries().len(), 1);
        assert_eq!(ab.entries()[0].id, "payload");
        let frame = ab.render(80, 10);
        assert!(frame.join("\n").contains("Setup"), "{frame:?}");
    }
}
