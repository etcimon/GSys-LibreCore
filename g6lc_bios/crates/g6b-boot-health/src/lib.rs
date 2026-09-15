// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Linux-generic boot-health helper.
//!
//! Reads a pending G6BH attempt from a declared journal device, checks
//! configurable readiness, and acknowledges only that exact attempt.
//! It cannot select firmware slots, clear operator inhibit, or enable
//! autoboot. OpenWrt is a file-based adapter, not a ubus/procd dependency.
//! Watchdog ownership requires `nowayout`; keepalive or magic-close of a
//! disarmable watchdog is not an acknowledgement. A file-backed `/dev/watchdog`
//! mock applies Linux open/keepalive/magic-close/nowayout effects without
//! calling `ioctl(2)`. Partition scan classifies
//! RISC-V Image vs squashfs/UBI rootfs vs FDT, walks `/boot` on mountable
//! filesystems, and does not jump.

#![allow(missing_docs)]

use g6b_bootctl::{
    BootMode, Domain, FirmwareLayout, Journal, LinuxReadiness, Prerequisites, SlotStorage, Target,
    Ticket, JOURNAL_BYTES, SLOT_BYTES,
};
use g6b_vfs::{BlockDev, Error as VfsError, FileBlock};

pub mod bundle;
pub mod handoff;
pub mod openwrt;
pub mod volume;
pub mod watchdog;

pub use bundle::{classify, linux_image, validate, Bundle, ImageInfo, Kind, Refuse};
pub use handoff::{
    decode as decode_handoff, encode as encode_handoff, HandoffError, HealthHandoff,
};
pub use openwrt::OpenWrtAdapter;
pub use volume::{scan, scan_path, Artifact, Role, Volume};
pub use watchdog::{
    WatchdogDevice, WatchdogInfo, WatchdogStamp, WatchdogStatus, WdError, WdIoctl, WdReply,
    WDIOC_KEEPALIVE, WDIOF_KEEPALIVEPING, WDIOF_MAGICCLOSE, WDIOF_SETTIMEOUT, WDIOS_DISABLECARD,
    WDIOS_ENABLECARD,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HealthError {
    Storage,
    Uninitialized,
    WrongDomain,
    WrongAttempt,
    Unhealthy,
    Uncertain,
    Args,
}

impl From<g6b_bootctl::Error<VfsError>> for HealthError {
    fn from(error: g6b_bootctl::Error<VfsError>) -> Self {
        match error {
            g6b_bootctl::Error::Storage(_) => Self::Storage,
            g6b_bootctl::Error::Uninitialized | g6b_bootctl::Error::Corrupt => Self::Uninitialized,
            g6b_bootctl::Error::WrongDomain => Self::WrongDomain,
            g6b_bootctl::Error::WrongAttempt => Self::WrongAttempt,
            g6b_bootctl::Error::Unhealthy | g6b_bootctl::Error::NotReady(_) => Self::Unhealthy,
            g6b_bootctl::Error::Uncertain | g6b_bootctl::Error::Ambiguous => Self::Uncertain,
            _ => Self::Storage,
        }
    }
}

pub trait Readiness {
    fn report(&self) -> LinuxReadiness;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StaticReadiness {
    pub inner: LinuxReadiness,
}

impl Readiness for StaticReadiness {
    fn report(&self) -> LinuxReadiness {
        self.inner
    }
}

pub struct JournalFile {
    device: FileBlock,
    offset: u64,
}

impl JournalFile {
    pub fn open(path: &str, offset: u64) -> Result<Self, VfsError> {
        let device = FileBlock::open_rw(path, true)?;
        let end = offset
            .checked_add(JOURNAL_BYTES as u64)
            .ok_or(VfsError::OutOfRange)?;
        if offset % SLOT_BYTES as u64 != 0 || end > device.len() {
            return Err(VfsError::OutOfRange);
        }
        if !device.durable_flush_supported() {
            return Err(VfsError::Unsupported(
                "boot-health journal requires durable flush".into(),
            ));
        }
        Ok(Self { device, offset })
    }

    pub fn bios_window(path: &str) -> Result<Self, VfsError> {
        Self::open(path, FirmwareLayout::BIOS.journal_offset())
    }

    /// Open the journal window named by an FDT health handoff. The disk
    /// path is still explicit; the offset comes from the contract.
    pub fn from_handoff(path: &str, handoff: HealthHandoff) -> Result<Self, HealthError> {
        let offset = handoff.journal_offset().map_err(|_| HealthError::Args)?;
        Self::open(path, offset).map_err(|_| HealthError::Storage)
    }

    fn slot_offset(&self, slot: usize) -> Result<u64, VfsError> {
        if slot >= 2 {
            return Err(VfsError::OutOfRange);
        }
        Ok(self.offset + slot as u64 * SLOT_BYTES as u64)
    }
}

impl SlotStorage for JournalFile {
    type Error = VfsError;

    fn read_slot(&mut self, slot: usize, bytes: &mut [u8; SLOT_BYTES]) -> Result<(), VfsError> {
        self.device.read_at(self.slot_offset(slot)?, bytes)
    }

    fn write_slot(&mut self, slot: usize, bytes: &[u8; SLOT_BYTES]) -> Result<(), VfsError> {
        self.device.write_at(self.slot_offset(slot)?, bytes)
    }

    fn flush(&mut self) -> Result<(), VfsError> {
        self.device.flush()
    }
}

/// Acknowledge the exact in-progress Linux attempt if `readiness` is complete.
/// Does not call `enable_autoboot` and does not touch firmware slots.
pub fn acknowledge<S: SlotStorage, R: Readiness>(
    storage: &mut S,
    readiness: &R,
) -> Result<(), g6b_bootctl::Error<S::Error>> {
    let mut journal = Journal::load(storage, Domain::Linux)?;
    let ticket = journal
        .record()
        .attempt()
        .ok_or(g6b_bootctl::Error::WrongAttempt)?;
    journal.acknowledge_linux(storage, ticket, readiness.report())
}

/// Validate a RISC-V Image bundle and persist an in-progress Linux attempt.
/// Does not jump and does not enable autoboot.
pub fn prepare_attempt<S: SlotStorage>(
    storage: &mut S,
    target: Target,
    nonce: [u8; 16],
    bundle: &Bundle<'_>,
    prerequisites: Prerequisites,
) -> Result<Ticket, g6b_bootctl::Error<S::Error>> {
    validate(bundle)
        .map_err(|_| g6b_bootctl::Error::NotReady(g6b_bootctl::Reason::InvalidImage))?;
    let mut journal = Journal::load(storage, Domain::Linux)?;
    journal.begin(
        storage,
        target,
        nonce,
        BootMode::ExplicitTrial,
        prerequisites,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_bootctl::{
        BootMode, Decision, Domain, Journal, LinuxReadiness, Prerequisites, Reason, Target,
        SLOT_BYTES,
    };
    use std::io::Write;

    const TARGET: Target = Target {
        device: [1; 16],
        partition: [2; 16],
        image_digest: [3; 32],
    };
    const READY: Prerequisites = Prerequisites {
        image_verified: true,
        durable_storage: true,
        recovery_reset_available: true,
    };
    const HEALTHY: LinuxReadiness = LinuxReadiness {
        selected_root_ready: true,
        required_services_ready: true,
        watchdog_owned: true,
    };

    fn scratch() -> (std::path::PathBuf, JournalFile) {
        let path = std::env::temp_dir().join(format!(
            "g6b-health-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        file.write_all(&vec![0; 32 * 512]).unwrap();
        file.sync_all().unwrap();
        let journal = JournalFile::bios_window(path.to_str().unwrap()).unwrap();
        (path, journal)
    }

    fn commissioned(storage: &mut JournalFile) -> g6b_bootctl::Ticket {
        let mut journal = Journal::initialize(storage, Domain::Linux).unwrap();
        journal
            .begin(storage, TARGET, [4; 16], BootMode::ExplicitTrial, READY)
            .unwrap()
    }

    #[test]
    fn premature_and_wrong_attempts_do_not_confirm() {
        let (path, mut storage) = scratch();
        commissioned(&mut storage);
        let before = {
            let mut slot = [0u8; SLOT_BYTES];
            storage.read_slot(0, &mut slot).unwrap();
            slot
        };
        assert_eq!(
            acknowledge(
                &mut storage,
                &StaticReadiness {
                    inner: LinuxReadiness {
                        selected_root_ready: false,
                        ..HEALTHY
                    }
                }
            ),
            Err(g6b_bootctl::Error::Unhealthy)
        );
        let mut after = [0u8; SLOT_BYTES];
        storage.read_slot(0, &mut after).unwrap();
        assert_eq!(before, after);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn exact_attempt_confirms_without_enabling_autoboot() {
        let (path, mut storage) = scratch();
        commissioned(&mut storage);
        acknowledge(&mut storage, &StaticReadiness { inner: HEALTHY }).unwrap();
        let journal = Journal::load(&mut storage, Domain::Linux).unwrap();
        assert_eq!(journal.record().phase(), g6b_bootctl::Phase::Confirmed);
        assert_eq!(journal.record().inhibit(), Some(Reason::Provisioning));
        assert_eq!(
            journal.decision(&TARGET, READY),
            Decision::Stay(Reason::Provisioning)
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn prepare_attempt_requires_a_complete_image_bundle() {
        let (path, mut storage) = scratch();
        Journal::initialize(&mut storage, Domain::Linux).unwrap();
        let img = {
            let mut b = vec![0u8; 0x80];
            b[0x10..0x18].copy_from_slice(&0x80u64.to_le_bytes());
            b[0x30..0x38].copy_from_slice(b"RISCV\0\0\0");
            b[0x38..0x3c].copy_from_slice(b"RSC\x05");
            b
        };
        assert_eq!(
            prepare_attempt(
                &mut storage,
                TARGET,
                [4; 16],
                &Bundle {
                    image: b"hsqs",
                    initrd: Some(b"i"),
                    dtb: Some(&[0xd0, 0x0d, 0xfe, 0xed]),
                    root: Some("/dev/vda2"),
                    bootargs: Some("console=ttyS0"),
                },
                READY,
            ),
            Err(g6b_bootctl::Error::NotReady(Reason::InvalidImage))
        );
        let ticket = prepare_attempt(
            &mut storage,
            TARGET,
            [4; 16],
            &Bundle {
                image: &img,
                initrd: Some(b"i"),
                dtb: Some(&[0xd0, 0x0d, 0xfe, 0xed]),
                root: Some("/dev/vda2"),
                bootargs: Some("console=ttyS0"),
            },
            READY,
        )
        .unwrap();
        assert_eq!(ticket.domain, Domain::Linux);
        let journal = Journal::load(&mut storage, Domain::Linux).unwrap();
        assert_eq!(journal.record().phase(), g6b_bootctl::Phase::InProgress);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn idle_journal_has_no_attempt_to_ack() {
        let (path, mut storage) = scratch();
        Journal::initialize(&mut storage, Domain::Linux).unwrap();
        assert_eq!(
            acknowledge(&mut storage, &StaticReadiness { inner: HEALTHY }),
            Err(g6b_bootctl::Error::WrongAttempt)
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn openwrt_keepalive_without_nowayout_is_unhealthy() {
        let (path, mut storage) = scratch();
        commissioned(&mut storage);
        let root = std::env::temp_dir().join(format!(
            "g6b-owrt-ack-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(root.join("etc")).unwrap();
        std::fs::create_dir_all(root.join("run")).unwrap();
        std::fs::write(root.join("etc/openwrt_release"), "DISTRIB_ID='OpenWrt'\n").unwrap();
        std::fs::write(root.join("run/g6b-boot-health.services"), "ok\n").unwrap();
        std::fs::write(root.join("run/g6b-boot-health.watchdog"), "keepalive=1\n").unwrap();
        assert_eq!(
            acknowledge(&mut storage, &OpenWrtAdapter::new(&root)),
            Err(g6b_bootctl::Error::Unhealthy)
        );
        let journal = Journal::load(&mut storage, Domain::Linux).unwrap();
        assert_eq!(journal.record().phase(), g6b_bootctl::Phase::InProgress);
        let _ = std::fs::remove_dir_all(root);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn openwrt_nowayout_ack_confirms_without_autoboot() {
        let (path, mut storage) = scratch();
        commissioned(&mut storage);
        let root = std::env::temp_dir().join(format!(
            "g6b-owrt-nowayout-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(root.join("etc")).unwrap();
        std::fs::create_dir_all(root.join("run")).unwrap();
        std::fs::write(root.join("etc/openwrt_release"), "DISTRIB_ID='OpenWrt'\n").unwrap();
        std::fs::write(root.join("run/g6b-boot-health.services"), "ok\n").unwrap();
        std::fs::write(
            root.join("run/g6b-boot-health.watchdog"),
            "nowayout=1\nkeepalive=1\n",
        )
        .unwrap();
        acknowledge(&mut storage, &OpenWrtAdapter::new(&root)).unwrap();
        let journal = Journal::load(&mut storage, Domain::Linux).unwrap();
        assert_eq!(journal.record().phase(), g6b_bootctl::Phase::Confirmed);
        assert_eq!(journal.record().inhibit(), Some(Reason::Provisioning));
        assert_eq!(
            journal.decision(&TARGET, READY),
            Decision::Stay(Reason::Provisioning)
        );
        let _ = std::fs::remove_dir_all(root);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn fdt_handoff_opens_the_declared_journal_window() {
        let (path, mut storage) = scratch();
        commissioned(&mut storage);
        drop(storage);
        let dtb = encode_handoff(HealthHandoff::BIOS);
        let mut discovered =
            JournalFile::from_handoff(path.to_str().unwrap(), decode_handoff(&dtb).unwrap())
                .unwrap();
        acknowledge(&mut discovered, &StaticReadiness { inner: HEALTHY }).unwrap();
        let journal = Journal::load(&mut discovered, Domain::Linux).unwrap();
        assert_eq!(journal.record().phase(), g6b_bootctl::Phase::Confirmed);
        assert_eq!(journal.record().inhibit(), Some(Reason::Provisioning));
        assert!(matches!(
            JournalFile::from_handoff(
                path.to_str().unwrap(),
                HealthHandoff {
                    journal_lba: 0,
                    journal_sectors: 16
                }
            ),
            Err(HealthError::Args)
        ));
        let _ = std::fs::remove_file(path);
    }
}
