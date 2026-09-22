// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use super::*;

#[derive(Clone)]
struct Memory {
    slots: [[u8; SLOT_BYTES]; 2],
    operations: usize,
    fail_at: Option<usize>,
    partial_write: usize,
    writes: usize,
    flushes: usize,
}

impl Default for Memory {
    fn default() -> Self {
        Self {
            slots: [[0; SLOT_BYTES]; 2],
            operations: 0,
            fail_at: None,
            partial_write: 0,
            writes: 0,
            flushes: 0,
        }
    }
}

impl Memory {
    fn step(&mut self) -> Result<(), ()> {
        let op = self.operations;
        self.operations += 1;
        if self.fail_at == Some(op) {
            Err(())
        } else {
            Ok(())
        }
    }
}

impl SlotStorage for Memory {
    type Error = ();

    fn read_slot(&mut self, slot: usize, out: &mut [u8; SLOT_BYTES]) -> Result<(), ()> {
        self.step()?;
        out.copy_from_slice(&self.slots[slot]);
        Ok(())
    }

    fn write_slot(&mut self, slot: usize, bytes: &[u8; SLOT_BYTES]) -> Result<(), ()> {
        self.writes += 1;
        if self.step().is_err() {
            self.slots[slot][..self.partial_write].copy_from_slice(&bytes[..self.partial_write]);
            return Err(());
        }
        self.slots[slot].copy_from_slice(bytes);
        Ok(())
    }

    fn flush(&mut self) -> Result<(), ()> {
        self.flushes += 1;
        self.step()
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

fn setup() -> (Memory, Journal) {
    let mut mem = Memory::default();
    let journal = Journal::initialize(&mut mem, Domain::Linux).unwrap();
    (mem, journal)
}

fn commissioned() -> (Memory, Journal) {
    let (mut mem, mut journal) = setup();
    let ticket = journal
        .begin(&mut mem, TARGET, [4; 16], BootMode::ExplicitTrial, READY)
        .unwrap();
    journal
        .acknowledge_linux(&mut mem, ticket, HEALTHY)
        .unwrap();
    journal.enable_autoboot(&mut mem, &TARGET, READY).unwrap();
    (mem, journal)
}

#[test]
fn bios_firmware_layout_keeps_journal_off_ab_slots() {
    assert_eq!(FirmwareLayout::BIOS.check(), Ok(()));
    assert_eq!(FirmwareLayout::SPI.check(), Ok(()));
    assert!(FirmwareLayout::SPI.fits(FirmwareLayout::SPI_BYTES));
    assert!(!FirmwareLayout::SPI.fits(1024));
    assert!(FirmwareLayout::SPI.contains_slot(FirmwareSlot::A, 256));
    assert!(FirmwareLayout::SPI.may_stage(16_384));
    assert!(!FirmwareLayout::SPI.may_stage(256));
    assert!(FirmwareLayout::BIOS.contains_journal(8));
    assert!(FirmwareLayout::BIOS.contains_journal(23));
    assert!(!FirmwareLayout::BIOS.contains_journal(24));
    assert!(FirmwareLayout::BIOS.contains_firmware(24));
    assert!(FirmwareLayout::BIOS.contains_firmware(32));
    assert!(!FirmwareLayout::BIOS.contains_firmware(16));
    let overlap = FirmwareLayout {
        journal_lba: 8,
        journal_sectors: 16,
        slot_a_lba: 20,
        slot_b_lba: 32,
        slot_sectors: 8,
    };
    assert_eq!(overlap.check(), Err(LayoutError::Overlap));
    let low = FirmwareLayout {
        journal_lba: 0,
        journal_sectors: 16,
        slot_a_lba: 24,
        slot_b_lba: 32,
        slot_sectors: 8,
    };
    assert_eq!(low.check(), Err(LayoutError::BelowGpt));
}

#[test]
fn inactive_slot_is_the_only_stage_window() {
    let layout = FirmwareLayout::BIOS;
    assert_eq!(layout.slot_lba(FirmwareSlot::A), 24);
    assert_eq!(layout.slot_lba(FirmwareSlot::B), 32);
    assert_eq!(layout.slot_sectors, 8);
    assert_eq!(layout.slot_bytes(), 4096);
    assert!(layout.contains_slot(FirmwareLayout::RECOVERY, 24));
    assert!(layout.contains_slot(FirmwareLayout::INACTIVE, 32));
    assert!(layout.may_stage(32));
    assert!(layout.may_stage(39));
    assert!(!layout.may_stage(24));
    assert!(!layout.may_stage(8));
    assert!(!layout.may_stage(0));
    assert!(!layout.may_stage(40));
}

#[test]
fn slot_select_is_refused_while_inhibit_and_never_switches() {
    let (_, journal) = setup();
    assert_eq!(journal.record().may_select(), Err(Reason::Provisioning));
    let (_, commissioned) = commissioned();
    assert_eq!(commissioned.record().may_select(), Err(Reason::Operator));
}

#[test]
fn nominate_inactive_records_b_without_clearing_inhibit() {
    let (mut mem, mut journal) = setup();
    assert_eq!(journal.record().staged(), None);
    assert_eq!(
        journal.record().may_nominate(FirmwareSlot::A),
        Err(Reason::Operator)
    );
    journal.nominate_inactive(&mut mem).unwrap();
    assert_eq!(journal.record().staged(), Some(FirmwareSlot::B));
    assert_eq!(journal.record().inhibit(), Some(Reason::Provisioning));
    assert_eq!(
        journal.decision(&TARGET, READY),
        Decision::Stay(Reason::Provisioning)
    );
    assert_eq!(journal.record().may_select(), Err(Reason::Provisioning));
    let encoded = journal.record().encode();
    assert_eq!(encoded[20], 2);
    assert_eq!(
        Record::decode(&encoded).unwrap().staged(),
        Some(FirmwareSlot::B)
    );
}

#[test]
fn interrupted_nominate_never_clears_inhibit() {
    for operation in 0..8 {
        let (mut mem, mut journal) = setup();
        mem.fail_at = Some(mem.operations + operation);
        let _ = journal.nominate_inactive(&mut mem);
        mem.fail_at = None;
        if let Ok(reload) = Journal::load(&mut mem, Domain::Linux) {
            assert!(
                matches!(reload.decision(&TARGET, READY), Decision::Stay(_)),
                "operation {operation}: {:?}",
                reload.decision(&TARGET, READY)
            );
            assert!(
                reload.record().may_select().is_err(),
                "operation {operation}"
            );
        }
    }
    for prefix in [0, 1, 20, 32, SLOT_BYTES - 1] {
        let (mut mem, mut journal) = setup();
        mem.fail_at = Some(mem.operations + 2);
        mem.partial_write = prefix;
        let _ = journal.nominate_inactive(&mut mem);
        mem.fail_at = None;
        if let Ok(reload) = Journal::load(&mut mem, Domain::Linux) {
            assert!(matches!(reload.decision(&TARGET, READY), Decision::Stay(_)));
        }
    }
}

#[test]
fn crc32c_reference_vector() {
    assert_eq!(crc32c(b"123456789"), 0xe306_9283);
}

#[test]
fn initial_record_matches_journal_disk_plant() {
    let (mem, _) = setup();
    assert_eq!(
        &mem.slots[0][..20],
        &[
            0x47, 0x36, 0x42, 0x48, 0x01, 0x00, 0x00, 0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x01, 0x00, 0x01, 0x00
        ]
    );
    assert_eq!(&mem.slots[0][4092..], &[0xb2, 0x8b, 0xdd, 0x5e]);
}

#[test]
fn record_and_linux_generic_ticket_have_stable_wire_layout() {
    let (mut mem, mut journal) = setup();
    let ticket = journal
        .begin(&mut mem, TARGET, [4; 16], BootMode::ExplicitTrial, READY)
        .unwrap();
    let encoded = journal.record().encode();
    assert_eq!(&encoded[..8], b"G6BH\x01\0\0\x10");
    assert_eq!(&encoded[8..16], &2u64.to_le_bytes());
    assert_eq!(&encoded[16..20], &[1, 1, 1, 1]);
    assert_eq!(&encoded[80..112], &TARGET.image_digest);
    assert_eq!(Record::decode(&encoded), Ok(journal.record()));
    let bytes = ticket.encode().unwrap();
    assert_eq!(&bytes[..8], b"G6BT\x01\0\x80\0");
    assert_eq!(Ticket::decode(&bytes), Ok(ticket));
    assert_eq!(journal.record().attempt(), Some(ticket));
    assert_eq!(mem.flushes, 2);
}

#[test]
fn truncated_corrupt_and_unknown_records_are_refused() {
    let good = Record::initial(Domain::Linux).encode();
    for length in 0..SLOT_BYTES {
        assert_eq!(Record::decode(&good[..length]), Err(FormatError::Length));
    }
    for at in 0..SLOT_BYTES {
        let mut bad = good;
        bad[at] ^= 1;
        assert!(Record::decode(&bad).is_err(), "byte {at}");
    }
    for at in [21, 23, 112, 509, SLOT_BYTES - 5] {
        let mut bad = good;
        bad[at] = 1;
        seal(&mut bad);
        assert_eq!(Record::decode(&bad), Err(FormatError::Reserved));
    }
    let mut bad = good;
    bad[20] = 3;
    seal(&mut bad);
    assert_eq!(Record::decode(&bad), Err(FormatError::Fields));
    let mut bad = good;
    bad[18] = 255;
    seal(&mut bad);
    assert_eq!(Record::decode(&bad), Err(FormatError::Fields));
    bad = good;
    bad[4] = 2;
    seal(&mut bad);
    assert_eq!(Record::decode(&bad), Err(FormatError::Version));
}

#[test]
fn malformed_tickets_cannot_be_acknowledged() {
    let ticket = Ticket {
        domain: Domain::Linux,
        sequence: 7,
        nonce: [9; 16],
        target: TARGET,
    };
    let good = ticket.encode().unwrap();
    for len in 0..TICKET_BYTES {
        assert!(Ticket::decode(&good[..len]).is_err());
    }
    for at in 0..TICKET_BYTES {
        let mut bad = good;
        bad[at] ^= 1;
        assert!(Ticket::decode(&bad).is_err());
    }
    let mut bad = good;
    bad[24] = 1;
    seal(&mut bad);
    assert_eq!(Ticket::decode(&bad), Err(FormatError::Reserved));
    let mut invalid = ticket;
    invalid.nonce = [0; 16];
    assert_eq!(invalid.encode(), Err(FormatError::Fields));
}

#[test]
fn fresh_install_requires_explicit_trial_and_separate_autoboot_enable() {
    let (mut mem, mut journal) = setup();
    assert_eq!(
        journal.decision(&TARGET, READY),
        Decision::Stay(Reason::Provisioning)
    );
    assert_eq!(
        journal.begin(&mut mem, TARGET, [4; 16], BootMode::Automatic, READY),
        Err(Error::NotReady(Reason::Provisioning))
    );
    let ticket = journal
        .begin(&mut mem, TARGET, [4; 16], BootMode::ExplicitTrial, READY)
        .unwrap();
    journal
        .acknowledge_linux(&mut mem, ticket, HEALTHY)
        .unwrap();
    assert_eq!(journal.record().phase(), Phase::Confirmed);
    assert_eq!(
        journal.decision(&TARGET, READY),
        Decision::Stay(Reason::Provisioning)
    );
    journal.enable_autoboot(&mut mem, &TARGET, READY).unwrap();
    assert_eq!(journal.decision(&TARGET, READY), Decision::Boot);
}

#[test]
fn one_unconfirmed_attempt_latches_recovery_across_resets() {
    let (mut mem, mut journal) = commissioned();
    journal
        .begin(&mut mem, TARGET, [5; 16], BootMode::Automatic, READY)
        .unwrap();
    let mut restarted = Journal::load(&mut mem, Domain::Linux).unwrap();
    assert_eq!(
        restarted.decision(&TARGET, READY),
        Decision::Stay(Reason::Unconfirmed)
    );
    restarted
        .reconcile_reset(&mut mem, ResetCause::Other)
        .unwrap();
    assert_eq!(restarted.record().phase(), Phase::Failed);
    for _ in 0..3 {
        let mut again = Journal::load(&mut mem, Domain::Linux).unwrap();
        again.reconcile_reset(&mut mem, ResetCause::Other).unwrap();
        assert_eq!(
            again.decision(&TARGET, READY),
            Decision::Stay(Reason::Unconfirmed)
        );
        assert_eq!(
            again.begin(&mut mem, TARGET, [6; 16], BootMode::Automatic, READY),
            Err(Error::NotReady(Reason::Unconfirmed))
        );
    }
}

#[test]
fn retry_success_does_not_clear_the_recovery_inhibit() {
    let (mut mem, mut journal) = commissioned();
    journal.inhibit(&mut mem, Reason::InvalidImage).unwrap();
    let ticket = journal
        .begin(&mut mem, TARGET, [5; 16], BootMode::ExplicitTrial, READY)
        .unwrap();
    journal
        .acknowledge_linux(&mut mem, ticket, HEALTHY)
        .unwrap();
    assert_eq!(
        journal.decision(&TARGET, READY),
        Decision::Stay(Reason::InvalidImage)
    );
    journal.enable_autoboot(&mut mem, &TARGET, READY).unwrap();
    assert_eq!(journal.decision(&TARGET, READY), Decision::Boot);
}

#[test]
fn linux_ack_requires_exact_attempt_and_readiness_without_clearing_policy() {
    let (mut mem, mut journal) = setup();
    let ticket = journal
        .begin(&mut mem, TARGET, [4; 16], BootMode::ExplicitTrial, READY)
        .unwrap();
    let before = mem.slots;
    let mut wrong = ticket;
    wrong.sequence += 1;
    assert_eq!(
        journal.acknowledge_linux(&mut mem, wrong, HEALTHY),
        Err(Error::WrongAttempt)
    );
    wrong = ticket;
    wrong.nonce[0] ^= 1;
    assert_eq!(
        journal.acknowledge_linux(&mut mem, wrong, HEALTHY),
        Err(Error::WrongAttempt)
    );
    wrong = ticket;
    wrong.target.partition[0] ^= 1;
    assert_eq!(
        journal.acknowledge_linux(&mut mem, wrong, HEALTHY),
        Err(Error::WrongAttempt)
    );
    wrong = ticket;
    wrong.target.image_digest[0] ^= 1;
    assert_eq!(
        journal.acknowledge_linux(&mut mem, wrong, HEALTHY),
        Err(Error::WrongAttempt)
    );
    for readiness in [
        LinuxReadiness {
            selected_root_ready: false,
            ..HEALTHY
        },
        LinuxReadiness {
            required_services_ready: false,
            ..HEALTHY
        },
        LinuxReadiness {
            watchdog_owned: false,
            ..HEALTHY
        },
    ] {
        assert_eq!(
            journal.acknowledge_linux(&mut mem, ticket, readiness),
            Err(Error::Unhealthy)
        );
    }
    assert!(mem.slots == before);
    journal
        .acknowledge_linux(&mut mem, ticket, HEALTHY)
        .unwrap();
    assert_eq!(
        journal.acknowledge_linux(&mut mem, ticket, HEALTHY),
        Err(Error::WrongAttempt)
    );
    assert_eq!(journal.record().inhibit(), Some(Reason::Provisioning));
}

#[test]
fn capabilities_and_changed_images_prevent_autoboot() {
    let (mut mem, mut journal) = commissioned();
    for (prerequisites, why) in [
        (
            Prerequisites {
                image_verified: false,
                ..READY
            },
            Reason::InvalidImage,
        ),
        (
            Prerequisites {
                durable_storage: false,
                ..READY
            },
            Reason::StorageUnavailable,
        ),
        (
            Prerequisites {
                recovery_reset_available: false,
                ..READY
            },
            Reason::RecoveryUnavailable,
        ),
    ] {
        assert_eq!(
            journal.decision(&TARGET, prerequisites),
            Decision::Stay(why)
        );
        assert_eq!(
            journal.begin(
                &mut mem,
                TARGET,
                [5; 16],
                BootMode::ExplicitTrial,
                prerequisites
            ),
            Err(Error::NotReady(why))
        );
    }
    let changed = Target {
        image_digest: [9; 32],
        ..TARGET
    };
    assert_eq!(
        journal.decision(&changed, READY),
        Decision::Stay(Reason::ChangedImage)
    );
    assert_eq!(
        journal.enable_autoboot(&mut mem, &changed, READY),
        Err(Error::Unhealthy)
    );
}

#[test]
fn watchdog_and_panic_hold_even_a_previously_confirmed_install() {
    for (cause, reason) in [
        (ResetCause::Watchdog, Reason::Watchdog),
        (ResetCause::Panic, Reason::Panic),
    ] {
        let (mut mem, mut journal) = commissioned();
        journal.reconcile_reset(&mut mem, cause).unwrap();
        assert_eq!(journal.decision(&TARGET, READY), Decision::Stay(reason));
        assert_eq!(
            Journal::load(&mut mem, Domain::Linux).unwrap().record(),
            journal.record()
        );
    }
}

#[test]
fn no_automatic_reinitialization_or_cross_domain_ack() {
    let mut mem = Memory::default();
    assert!(matches!(
        Journal::load(&mut mem, Domain::Linux),
        Err(Error::Uninitialized)
    ));
    mem.slots[0][0] = 9;
    assert!(matches!(
        Journal::load(&mut mem, Domain::Linux),
        Err(Error::Corrupt)
    ));
    assert!(matches!(
        Journal::initialize(&mut mem, Domain::Linux),
        Err(Error::NotBlank)
    ));
    let mut mem = Memory::default();
    let mut firmware = Journal::initialize(&mut mem, Domain::Firmware).unwrap();
    assert!(matches!(
        Journal::load(&mut mem, Domain::Linux),
        Err(Error::WrongDomain)
    ));
    let ticket = firmware
        .begin(&mut mem, TARGET, [7; 16], BootMode::ExplicitTrial, READY)
        .unwrap();
    assert_eq!(
        firmware.acknowledge_linux(&mut mem, ticket, HEALTHY),
        Err(Error::WrongDomain)
    );
}

#[test]
fn lost_newest_attempt_cannot_resurrect_an_older_boot_permission() {
    for erase in [false, true] {
        let (mut mem, mut journal) = commissioned();
        journal
            .begin(&mut mem, TARGET, [5; 16], BootMode::Automatic, READY)
            .unwrap();
        if erase {
            mem.slots[journal.slot] = [0; SLOT_BYTES];
        } else {
            mem.slots[journal.slot][0] ^= 1;
        }
        let mut recovered = Journal::load(&mut mem, Domain::Linux).unwrap();
        assert_eq!(
            recovered.decision(&TARGET, READY),
            Decision::Stay(Reason::StorageUnavailable)
        );
        recovered
            .reconcile_reset(&mut mem, ResetCause::Other)
            .unwrap();
        let reloaded = Journal::load(&mut mem, Domain::Linux).unwrap();
        assert_eq!(
            reloaded.decision(&TARGET, READY),
            Decision::Stay(Reason::StorageUnavailable)
        );
    }
}

#[test]
fn contradictory_or_discontinuous_valid_copies_fail_closed() {
    let (mut mem, journal) = setup();
    let mut other = journal.record();
    other.inhibit = Some(Reason::Operator);
    mem.slots[1] = other.encode();
    assert!(matches!(
        Journal::load(&mut mem, Domain::Linux),
        Err(Error::Ambiguous)
    ));
    other.generation = 10;
    mem.slots[1] = other.encode();
    assert!(matches!(
        Journal::load(&mut mem, Domain::Linux),
        Err(Error::Ambiguous)
    ));
}

#[test]
fn invalid_targets_reused_nonces_and_counter_wrap_are_refused() {
    let (mut mem, mut journal) = commissioned();
    let before = mem.slots;
    let bad = Target {
        image_digest: [0; 32],
        ..TARGET
    };
    assert_eq!(
        journal.begin(&mut mem, bad, [5; 16], BootMode::ExplicitTrial, READY),
        Err(Error::InvalidTarget)
    );
    for nonce in [[0; 16], [4; 16]] {
        assert_eq!(
            journal.begin(&mut mem, TARGET, nonce, BootMode::ExplicitTrial, READY),
            Err(Error::InvalidNonce)
        );
    }
    assert!(mem.slots == before);
    let mut record = journal.record();
    record.generation = u64::MAX;
    mem.slots = [record.encode(), [0; SLOT_BYTES]];
    let mut journal = Journal::load(&mut mem, Domain::Linux).unwrap();
    assert_eq!(
        journal.begin(&mut mem, TARGET, [5; 16], BootMode::ExplicitTrial, READY),
        Err(Error::GenerationExhausted)
    );
}

#[test]
fn stale_writer_cannot_overwrite_a_new_attempt() {
    let (mut mem, mut journal) = commissioned();
    let mut stale = Journal::load(&mut mem, Domain::Linux).unwrap();
    journal
        .begin(&mut mem, TARGET, [5; 16], BootMode::Automatic, READY)
        .unwrap();
    let before = mem.slots;
    assert_eq!(stale.inhibit(&mut mem, Reason::Operator), Err(Error::Stale));
    assert!(mem.slots == before);
    assert_eq!(
        stale.decision(&TARGET, READY),
        Decision::Stay(Reason::StorageUnavailable)
    );
}

#[test]
fn every_failed_io_blocks_the_live_writer_until_reload() {
    for operation in 0..6 {
        let (mut mem, mut journal) = commissioned();
        mem.fail_at = Some(mem.operations + operation);
        assert!(
            journal
                .begin(&mut mem, TARGET, [5; 16], BootMode::Automatic, READY)
                .is_err(),
            "operation {operation}"
        );
        assert_eq!(
            journal.decision(&TARGET, READY),
            Decision::Stay(Reason::StorageUnavailable),
            "operation {operation}"
        );
        mem.fail_at = None;
        assert!(journal
            .begin(&mut mem, TARGET, [6; 16], BootMode::Automatic, READY)
            .is_err());
    }
}

#[test]
fn interrupted_begin_never_returns_a_handoff_ticket() {
    for prefix in [0, 1, 8, 32, 112, SLOT_BYTES - 1, SLOT_BYTES] {
        let (mut mem, mut journal) = commissioned();
        let before = journal.record();
        mem.fail_at = Some(mem.operations + 2);
        mem.partial_write = prefix;
        assert!(journal
            .begin(&mut mem, TARGET, [5; 16], BootMode::Automatic, READY)
            .is_err());
        mem.fail_at = None;
        let mut reload = Journal::load(&mut mem, Domain::Linux).unwrap();
        assert!(reload.record() == before || reload.record().phase() == Phase::InProgress);
        reload.reconcile_reset(&mut mem, ResetCause::Other).unwrap();
        if reload.record() != before {
            assert!(matches!(
                reload.decision(&TARGET, READY),
                Decision::Stay(Reason::Unconfirmed | Reason::StorageUnavailable)
            ));
        }
    }
}
