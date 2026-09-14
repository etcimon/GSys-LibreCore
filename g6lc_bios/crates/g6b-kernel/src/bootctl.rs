// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use g6b_bootctl::{SlotStorage, JOURNAL_BYTES, SLOT_BYTES};
use g6b_vfs::{BlockDev, Error, Result};

pub struct JournalStorage<'a> {
    device: &'a mut dyn BlockDev,
    offset: u64,
}

impl<'a> JournalStorage<'a> {
    pub fn new(device: &'a mut dyn BlockDev, offset: u64) -> Result<Self> {
        let end = offset
            .checked_add(JOURNAL_BYTES as u64)
            .ok_or(Error::OutOfRange)?;
        if offset % SLOT_BYTES as u64 != 0 || end > device.len() {
            return Err(Error::OutOfRange);
        }
        if !device.writable() {
            return Err(Error::ReadOnly("boot journal"));
        }
        if !device.durable_flush_supported() {
            return Err(Error::Unsupported(
                "boot journal requires durable flush".into(),
            ));
        }
        Ok(Self { device, offset })
    }

    fn slot_offset(&self, slot: usize) -> Result<u64> {
        if slot >= 2 {
            return Err(Error::OutOfRange);
        }
        Ok(self.offset + slot as u64 * SLOT_BYTES as u64)
    }
}

impl SlotStorage for JournalStorage<'_> {
    type Error = Error;

    fn read_slot(&mut self, slot: usize, bytes: &mut [u8; SLOT_BYTES]) -> Result<()> {
        self.device.read_at(self.slot_offset(slot)?, bytes)
    }

    fn write_slot(&mut self, slot: usize, bytes: &[u8; SLOT_BYTES]) -> Result<()> {
        self.device.write_at(self.slot_offset(slot)?, bytes)
    }

    fn flush(&mut self) -> Result<()> {
        self.device.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_bootctl::{
        BootMode, Decision, Domain, Journal, LinuxReadiness, Prerequisites, Reason, ResetCause,
        Target,
    };
    use g6b_vfs::{FileBlock, MemBlock, SubDev};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "g6b-bootctl-{}-{}-{}.img",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let mut file = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .open(&path)
                .unwrap();
            let fixture = Self(path);
            use std::io::Write;
            file.write_all(&vec![0; 4 * SLOT_BYTES]).unwrap();
            file.sync_all().unwrap();
            fixture
        }

        fn open(&self, writable: bool) -> FileBlock {
            FileBlock::open_rw(self.0.to_str().unwrap(), writable).unwrap()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

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

    #[test]
    fn journal_requires_declared_durability_and_bounded_writable_extent() {
        let mut mem = MemBlock::zeroed(JOURNAL_BYTES);
        assert!(matches!(
            JournalStorage::new(&mut mem, 0),
            Err(Error::Unsupported(_))
        ));
        assert!(matches!(
            JournalStorage::new(&mut mem, 1),
            Err(Error::OutOfRange)
        ));
        assert!(matches!(
            JournalStorage::new(&mut mem, u64::MAX),
            Err(Error::OutOfRange)
        ));
        let fixture = Scratch::new();
        let mut ro = fixture.open(false);
        assert!(matches!(
            JournalStorage::new(&mut ro, 0),
            Err(Error::ReadOnly(_))
        ));
    }

    #[test]
    fn file_journal_survives_reopen_and_does_not_touch_neighbours() {
        let fixture = Scratch::new();
        {
            let mut disk = fixture.open(true);
            disk.write_at(0, &[0x5a; SLOT_BYTES]).unwrap();
            disk.write_at((3 * SLOT_BYTES) as u64, &[0xa5; SLOT_BYTES])
                .unwrap();
            let mut partition =
                SubDev::new(&mut disk, SLOT_BYTES as u64, JOURNAL_BYTES as u64, true).unwrap();
            let mut store = JournalStorage::new(&mut partition, 0).unwrap();
            let mut journal = Journal::initialize(&mut store, Domain::Linux).unwrap();
            let ticket = journal
                .begin(&mut store, TARGET, [4; 16], BootMode::ExplicitTrial, READY)
                .unwrap();
            journal
                .acknowledge_linux(&mut store, ticket, HEALTHY)
                .unwrap();
            journal.enable_autoboot(&mut store, &TARGET, READY).unwrap();
        }
        {
            let mut disk = fixture.open(true);
            let mut store = JournalStorage::new(&mut disk, SLOT_BYTES as u64).unwrap();
            let mut journal = Journal::load(&mut store, Domain::Linux).unwrap();
            assert_eq!(journal.decision(&TARGET, READY), Decision::Boot);
            assert!(store.write_slot(2, &[0; SLOT_BYTES]).is_err());
            journal
                .begin(&mut store, TARGET, [5; 16], BootMode::Automatic, READY)
                .unwrap();
        }
        {
            let mut disk = fixture.open(true);
            {
                let mut store = JournalStorage::new(&mut disk, SLOT_BYTES as u64).unwrap();
                let mut journal = Journal::load(&mut store, Domain::Linux).unwrap();
                journal
                    .reconcile_reset(&mut store, ResetCause::Other)
                    .unwrap();
                assert_eq!(
                    journal.decision(&TARGET, READY),
                    Decision::Stay(Reason::Unconfirmed)
                );
            }
            let mut bytes = [0; SLOT_BYTES];
            disk.read_at(0, &mut bytes).unwrap();
            assert!(bytes.iter().all(|&b| b == 0x5a));
            disk.read_at((3 * SLOT_BYTES) as u64, &mut bytes).unwrap();
            assert!(bytes.iter().all(|&b| b == 0xa5));
        }
    }
}
