// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

#![no_std]
#![forbid(unsafe_code)]
#![allow(missing_docs)]

pub const VERSION: u16 = 1;
pub const SLOT_BYTES: usize = 4096;
pub const JOURNAL_BYTES: usize = 2 * SLOT_BYTES;
pub const TICKET_BYTES: usize = 128;
const RECORD_MAGIC: &[u8; 4] = b"G6BH";
const TICKET_MAGIC: &[u8; 4] = b"G6BT";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Domain {
    Linux = 1,
    Firmware = 2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Phase {
    Idle = 0,
    InProgress = 1,
    Confirmed = 2,
    Failed = 3,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Reason {
    Provisioning = 1,
    Operator = 2,
    InvalidImage = 3,
    Unconfirmed = 4,
    Watchdog = 5,
    Panic = 6,
    ChangedImage = 7,
    StorageUnavailable = 8,
    RecoveryUnavailable = 9,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResetCause {
    Other,
    Watchdog,
    Panic,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BootMode {
    Automatic,
    ExplicitTrial,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    Boot,
    Stay(Reason),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FormatError {
    Length,
    Magic,
    Version,
    Checksum,
    Reserved,
    Fields,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error<E> {
    Storage(E),
    Uninitialized,
    Corrupt,
    Ambiguous,
    NotBlank,
    WrongDomain,
    InvalidTarget,
    InvalidNonce,
    NotReady(Reason),
    AlreadyInProgress,
    WrongAttempt,
    Unhealthy,
    Stale,
    Uncertain,
    GenerationExhausted,
    Readback,
}

pub trait SlotStorage {
    type Error;
    fn read_slot(&mut self, slot: usize, bytes: &mut [u8; SLOT_BYTES]) -> Result<(), Self::Error>;
    fn write_slot(&mut self, slot: usize, bytes: &[u8; SLOT_BYTES]) -> Result<(), Self::Error>;
    fn flush(&mut self) -> Result<(), Self::Error>;
}

/// On-disk recovery layout. Journal and firmware A/B sit past the GPT
/// headers and outside any OS filesystem. Ordinary `BlkWrite` may only
/// touch the journal window; firmware slots are selector/recovery images
/// and are not updated by journal I/O.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FirmwareLayout {
    pub journal_lba: u64,
    pub journal_sectors: u64,
    pub slot_a_lba: u64,
    pub slot_b_lba: u64,
    pub slot_sectors: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LayoutError {
    Overlap,
    BelowGpt,
    Empty,
}

impl FirmwareLayout {
    /// BIOS virtio-blk recovery disk: LBA 8 journal (16 sectors), LBA 24/32
    /// firmware A/B stubs (8 sectors each). Not a full SPI image.
    pub const BIOS: Self = Self {
        journal_lba: 8,
        journal_sectors: 16,
        slot_a_lba: 24,
        slot_b_lba: 32,
        slot_sectors: 8,
    };

    pub fn check(self) -> Result<(), LayoutError> {
        if self.journal_sectors == 0 || self.slot_sectors == 0 {
            return Err(LayoutError::Empty);
        }
        if self.journal_lba < 8 {
            return Err(LayoutError::BelowGpt);
        }
        let j0 = self.journal_lba;
        let j1 = self.journal_lba.saturating_add(self.journal_sectors);
        let a0 = self.slot_a_lba;
        let a1 = self.slot_a_lba.saturating_add(self.slot_sectors);
        let b0 = self.slot_b_lba;
        let b1 = self.slot_b_lba.saturating_add(self.slot_sectors);
        if ranges_overlap(j0, j1, a0, a1)
            || ranges_overlap(j0, j1, b0, b1)
            || ranges_overlap(a0, a1, b0, b1)
        {
            return Err(LayoutError::Overlap);
        }
        Ok(())
    }

    pub const fn journal_offset(self) -> u64 {
        self.journal_lba * 512
    }

    pub const fn slot_a_offset(self) -> u64 {
        self.slot_a_lba * 512
    }

    pub const fn slot_b_offset(self) -> u64 {
        self.slot_b_lba * 512
    }

    /// Declared firmware-slot size in bytes (8 sectors × 512 on `BIOS`).
    /// Not a SPI capacity.
    pub const fn slot_bytes(self) -> u64 {
        self.slot_sectors.saturating_mul(512)
    }

    pub fn contains_journal(self, lba: u64) -> bool {
        lba >= self.journal_lba && lba < self.journal_lba.saturating_add(self.journal_sectors)
    }

    pub fn contains_firmware(self, lba: u64) -> bool {
        self.contains_slot(FirmwareSlot::A, lba) || self.contains_slot(FirmwareSlot::B, lba)
    }

    /// Selector/recovery image. Ordinary updates never write this slot.
    pub const RECOVERY: FirmwareSlot = FirmwareSlot::A;
    /// Inactive slot that `FwStage` may rewrite. Not a slot switch.
    pub const INACTIVE: FirmwareSlot = FirmwareSlot::B;

    pub const fn slot_lba(self, slot: FirmwareSlot) -> u64 {
        match slot {
            FirmwareSlot::A => self.slot_a_lba,
            FirmwareSlot::B => self.slot_b_lba,
        }
    }

    pub fn contains_slot(self, slot: FirmwareSlot, lba: u64) -> bool {
        let base = self.slot_lba(slot);
        lba >= base && lba < base.saturating_add(self.slot_sectors)
    }

    /// Stage writes land only in the inactive slot. Recovery, journal, and
    /// GPT/MBR are refused.
    pub fn may_stage(self, lba: u64) -> bool {
        self.contains_slot(Self::INACTIVE, lba)
    }
}

/// Firmware A/B identity. A is recovery; B is the only stage target.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum FirmwareSlot {
    A = 0,
    B = 1,
}

fn ranges_overlap(a0: u64, a1: u64, b0: u64, b1: u64) -> bool {
    a0 < b1 && b0 < a1
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Target {
    pub device: [u8; 16],
    pub partition: [u8; 16],
    pub image_digest: [u8; 32],
}

impl Target {
    pub fn valid(&self) -> bool {
        !zero(&self.device) && !zero(&self.partition) && !zero(&self.image_digest)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Prerequisites {
    pub image_verified: bool,
    pub durable_storage: bool,
    pub recovery_reset_available: bool,
}

impl Prerequisites {
    fn refusal(self) -> Option<Reason> {
        if !self.image_verified {
            Some(Reason::InvalidImage)
        } else if !self.durable_storage {
            Some(Reason::StorageUnavailable)
        } else if !self.recovery_reset_available {
            Some(Reason::RecoveryUnavailable)
        } else {
            None
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LinuxReadiness {
    pub selected_root_ready: bool,
    pub required_services_ready: bool,
    pub watchdog_owned: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ticket {
    pub domain: Domain,
    pub sequence: u64,
    pub nonce: [u8; 16],
    pub target: Target,
}

impl Ticket {
    fn valid(&self) -> bool {
        self.sequence != 0 && !zero(&self.nonce) && self.target.valid()
    }

    pub fn encode(&self) -> Result<[u8; TICKET_BYTES], FormatError> {
        if !self.valid() {
            return Err(FormatError::Fields);
        }
        let mut bytes = [0; TICKET_BYTES];
        header(&mut bytes, TICKET_MAGIC);
        bytes[8..16].copy_from_slice(&self.sequence.to_le_bytes());
        bytes[16] = self.domain as u8;
        put_identity(&mut bytes, self);
        seal(&mut bytes);
        Ok(bytes)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, FormatError> {
        check_header(bytes, TICKET_MAGIC, TICKET_BYTES)?;
        if !zero(&bytes[17..32]) || !zero(&bytes[112..TICKET_BYTES - 4]) {
            return Err(FormatError::Reserved);
        }
        let ticket = identity(bytes, domain(bytes[16])?, u64_at(bytes, 8));
        ticket.valid().then_some(ticket).ok_or(FormatError::Fields)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Record {
    generation: u64,
    domain: Domain,
    phase: Phase,
    inhibit: Option<Reason>,
    attempt: Option<Ticket>,
    /// Nominated firmware slot. None = no stage. Does not clear inhibit.
    staged: Option<FirmwareSlot>,
}

impl Record {
    fn initial(domain: Domain) -> Self {
        Self {
            generation: 1,
            domain,
            phase: Phase::Idle,
            inhibit: Some(Reason::Provisioning),
            attempt: None,
            staged: None,
        }
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn domain(&self) -> Domain {
        self.domain
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    pub fn inhibit(&self) -> Option<Reason> {
        self.inhibit
    }

    pub fn attempt(&self) -> Option<Ticket> {
        self.attempt
    }

    pub fn staged(self) -> Option<FirmwareSlot> {
        self.staged
    }

    /// Nominate the inactive slot as staged. Recovery A is refused. Inhibit
    /// is unchanged — this is not a boot.
    pub fn may_nominate(self, slot: FirmwareSlot) -> Result<(), Reason> {
        if slot != FirmwareSlot::B {
            return Err(Reason::Operator);
        }
        Ok(())
    }

    /// Booting a nominated slot is refused while inhibit is live, and still
    /// `Operator` when blank so this increment cannot autoboot.
    pub fn may_select(self) -> Result<(), Reason> {
        Err(self.inhibit.unwrap_or(Reason::Operator))
    }

    fn valid(&self) -> bool {
        self.generation != 0
            && match self.attempt {
                None => self.phase == Phase::Idle && self.inhibit.is_some(),
                Some(ticket) => {
                    ticket.valid()
                        && ticket.domain == self.domain
                        && ticket.sequence <= self.generation
                        && self.phase != Phase::Idle
                        && (self.phase != Phase::Failed || self.inhibit.is_some())
                }
            }
    }

    pub fn encode(&self) -> [u8; SLOT_BYTES] {
        let mut bytes = [0; SLOT_BYTES];
        header(&mut bytes, RECORD_MAGIC);
        bytes[8..16].copy_from_slice(&self.generation.to_le_bytes());
        bytes[16] = self.domain as u8;
        bytes[17] = self.phase as u8;
        bytes[18] = self.inhibit.map_or(0, |r| r as u8);
        bytes[20] = match self.staged {
            None => 0,
            Some(FirmwareSlot::A) => 1,
            Some(FirmwareSlot::B) => 2,
        };
        if let Some(ticket) = self.attempt {
            bytes[19] = 1;
            bytes[24..32].copy_from_slice(&ticket.sequence.to_le_bytes());
            put_identity(&mut bytes, &ticket);
        }
        seal(&mut bytes);
        bytes
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, FormatError> {
        check_header(bytes, RECORD_MAGIC, SLOT_BYTES)?;
        if !zero(&bytes[21..24]) || !zero(&bytes[112..SLOT_BYTES - 4]) {
            return Err(FormatError::Reserved);
        }
        let staged = match bytes[20] {
            0 => None,
            1 => Some(FirmwareSlot::A),
            2 => Some(FirmwareSlot::B),
            _ => return Err(FormatError::Fields),
        };
        let domain = domain(bytes[16])?;
        let phase = match bytes[17] {
            0 => Phase::Idle,
            1 => Phase::InProgress,
            2 => Phase::Confirmed,
            3 => Phase::Failed,
            _ => return Err(FormatError::Fields),
        };
        let inhibit = reason(bytes[18])?;
        let attempt = match bytes[19] {
            0 if zero(&bytes[24..112]) => None,
            1 => Some(identity(bytes, domain, u64_at(bytes, 24))),
            _ => return Err(FormatError::Fields),
        };
        let record = Self {
            generation: u64_at(bytes, 8),
            domain,
            phase,
            inhibit,
            attempt,
            staged,
        };
        record.valid().then_some(record).ok_or(FormatError::Fields)
    }
}

#[derive(Debug)]
pub struct Journal {
    record: Record,
    slot: usize,
    uncertain: bool,
    degraded: bool,
}

impl Journal {
    pub fn load<S: SlotStorage>(
        storage: &mut S,
        expected: Domain,
    ) -> Result<Self, Error<S::Error>> {
        let mut bytes = [0; SLOT_BYTES];
        let mut records = [None, None];
        let mut empty = [false; 2];
        let mut blank = true;
        for (slot, record) in records.iter_mut().enumerate() {
            storage
                .read_slot(slot, &mut bytes)
                .map_err(Error::Storage)?;
            empty[slot] = zero(&bytes);
            blank &= empty[slot];
            *record = Record::decode(&bytes).ok();
            if record.is_some_and(|r| r.domain != expected) {
                return Err(Error::WrongDomain);
            }
        }
        let (record, slot) = match records {
            [None, None] => {
                return Err(if blank {
                    Error::Uninitialized
                } else {
                    Error::Corrupt
                })
            }
            [Some(r), None] => (r, 0),
            [None, Some(r)] => (r, 1),
            [Some(a), Some(b)] if a.generation == b.generation && a == b => (a, 0),
            [Some(a), Some(b)] if a.generation.abs_diff(b.generation) == 1 => {
                if a.generation > b.generation {
                    (a, 0)
                } else {
                    (b, 1)
                }
            }
            _ => return Err(Error::Ambiguous),
        };
        let degraded = records[1 - slot].is_none()
            && !(record == Record::initial(expected) && empty[1 - slot]);
        Ok(Self {
            record,
            slot,
            uncertain: false,
            degraded,
        })
    }

    pub fn initialize<S: SlotStorage>(
        storage: &mut S,
        domain: Domain,
    ) -> Result<Self, Error<S::Error>> {
        let mut bytes = [0; SLOT_BYTES];
        for slot in 0..2 {
            storage
                .read_slot(slot, &mut bytes)
                .map_err(Error::Storage)?;
            if !zero(&bytes) {
                return Err(Error::NotBlank);
            }
        }
        let record = Record::initial(domain);
        storage
            .write_slot(0, &record.encode())
            .map_err(Error::Storage)?;
        storage.flush().map_err(Error::Storage)?;
        let journal = Self::load(storage, domain)?;
        if journal.record != record {
            return Err(Error::Readback);
        }
        Ok(journal)
    }

    pub fn record(&self) -> Record {
        self.record
    }

    pub fn decision(&self, target: &Target, prerequisites: Prerequisites) -> Decision {
        if self.uncertain || self.degraded {
            return Decision::Stay(Reason::StorageUnavailable);
        }
        if let Some(reason) = self.record.inhibit {
            return Decision::Stay(reason);
        }
        if self.record.phase != Phase::Confirmed {
            return Decision::Stay(Reason::Unconfirmed);
        }
        if !target.valid() || self.record.attempt.map(|t| t.target) != Some(*target) {
            return Decision::Stay(Reason::ChangedImage);
        }
        prerequisites
            .refusal()
            .map_or(Decision::Boot, Decision::Stay)
    }

    pub fn begin<S: SlotStorage>(
        &mut self,
        storage: &mut S,
        target: Target,
        nonce: [u8; 16],
        mode: BootMode,
        prerequisites: Prerequisites,
    ) -> Result<Ticket, Error<S::Error>> {
        if !target.valid() {
            return Err(Error::InvalidTarget);
        }
        if zero(&nonce) || self.record.attempt.is_some_and(|t| t.nonce == nonce) {
            return Err(Error::InvalidNonce);
        }
        if let Some(reason) = prerequisites.refusal() {
            return Err(Error::NotReady(reason));
        }
        if self.record.phase == Phase::InProgress {
            return Err(Error::AlreadyInProgress);
        }
        if mode == BootMode::Automatic {
            if let Decision::Stay(reason) = self.decision(&target, prerequisites) {
                return Err(Error::NotReady(reason));
            }
        }
        let sequence = self.next_generation()?;
        let ticket = Ticket {
            domain: self.record.domain,
            sequence,
            nonce,
            target,
        };
        let mut record = self.record;
        record.phase = Phase::InProgress;
        record.attempt = Some(ticket);
        self.persist(storage, record)?;
        Ok(ticket)
    }

    pub fn acknowledge_linux<S: SlotStorage>(
        &mut self,
        storage: &mut S,
        ticket: Ticket,
        readiness: LinuxReadiness,
    ) -> Result<(), Error<S::Error>> {
        if self.record.domain != Domain::Linux || ticket.domain != Domain::Linux {
            return Err(Error::WrongDomain);
        }
        if self.record.phase != Phase::InProgress || self.record.attempt != Some(ticket) {
            return Err(Error::WrongAttempt);
        }
        if self.degraded
            || !readiness.selected_root_ready
            || !readiness.required_services_ready
            || !readiness.watchdog_owned
        {
            return Err(Error::Unhealthy);
        }
        let mut record = self.record;
        record.phase = Phase::Confirmed;
        self.persist(storage, record)
    }

    pub fn inhibit<S: SlotStorage>(
        &mut self,
        storage: &mut S,
        reason: Reason,
    ) -> Result<(), Error<S::Error>> {
        let mut record = self.record;
        record.inhibit = Some(reason);
        if record.attempt.is_some() && reason != Reason::Operator {
            record.phase = Phase::Failed;
        }
        self.persist(storage, record)
    }

    pub fn reconcile_reset<S: SlotStorage>(
        &mut self,
        storage: &mut S,
        cause: ResetCause,
    ) -> Result<(), Error<S::Error>> {
        let reason = match cause {
            ResetCause::Watchdog => Some(Reason::Watchdog),
            ResetCause::Panic => Some(Reason::Panic),
            ResetCause::Other if self.record.phase == Phase::InProgress => {
                Some(Reason::Unconfirmed)
            }
            ResetCause::Other if self.degraded => Some(Reason::StorageUnavailable),
            ResetCause::Other => None,
        };
        if let Some(reason) = reason {
            self.inhibit(storage, reason)?;
        }
        Ok(())
    }

    /// Record that inactive B is staged. Does not clear inhibit or arm autoboot.
    pub fn nominate_inactive<S: SlotStorage>(
        &mut self,
        storage: &mut S,
    ) -> Result<(), Error<S::Error>> {
        self.record
            .may_nominate(FirmwareSlot::B)
            .map_err(Error::NotReady)?;
        let mut record = self.record;
        record.staged = Some(FirmwareSlot::B);
        self.persist(storage, record)
    }

    pub fn enable_autoboot<S: SlotStorage>(
        &mut self,
        storage: &mut S,
        target: &Target,
        prerequisites: Prerequisites,
    ) -> Result<(), Error<S::Error>> {
        if let Some(reason) = prerequisites.refusal() {
            return Err(Error::NotReady(reason));
        }
        if self.degraded
            || self.record.phase != Phase::Confirmed
            || self.record.attempt.map(|t| t.target) != Some(*target)
        {
            return Err(Error::Unhealthy);
        }
        let mut record = self.record;
        record.inhibit = None;
        self.persist(storage, record)
    }

    fn next_generation<E>(&self) -> Result<u64, Error<E>> {
        if self.uncertain {
            return Err(Error::Uncertain);
        }
        self.record
            .generation
            .checked_add(1)
            .ok_or(Error::GenerationExhausted)
    }

    fn persist<S: SlotStorage>(
        &mut self,
        storage: &mut S,
        mut next: Record,
    ) -> Result<(), Error<S::Error>> {
        next.generation = self.next_generation()?;
        self.uncertain = true;
        let current = Self::load(storage, self.record.domain)?;
        if current.record != self.record
            || current.slot != self.slot
            || current.degraded != self.degraded
        {
            return Err(Error::Stale);
        }
        let slot = 1 - self.slot;
        storage
            .write_slot(slot, &next.encode())
            .map_err(Error::Storage)?;
        storage.flush().map_err(Error::Storage)?;
        let check = Self::load(storage, self.record.domain)?;
        if check.record != next || check.slot != slot || check.degraded {
            return Err(Error::Readback);
        }
        self.record = next;
        self.slot = slot;
        self.uncertain = false;
        self.degraded = false;
        Ok(())
    }
}

fn zero(bytes: &[u8]) -> bool {
    bytes.iter().all(|&b| b == 0)
}

fn domain(value: u8) -> Result<Domain, FormatError> {
    match value {
        1 => Ok(Domain::Linux),
        2 => Ok(Domain::Firmware),
        _ => Err(FormatError::Fields),
    }
}

fn reason(value: u8) -> Result<Option<Reason>, FormatError> {
    Ok(match value {
        0 => None,
        1 => Some(Reason::Provisioning),
        2 => Some(Reason::Operator),
        3 => Some(Reason::InvalidImage),
        4 => Some(Reason::Unconfirmed),
        5 => Some(Reason::Watchdog),
        6 => Some(Reason::Panic),
        7 => Some(Reason::ChangedImage),
        8 => Some(Reason::StorageUnavailable),
        9 => Some(Reason::RecoveryUnavailable),
        _ => return Err(FormatError::Fields),
    })
}

fn u64_at(bytes: &[u8], off: usize) -> u64 {
    u64::from_le_bytes(bytes[off..off + 8].try_into().unwrap())
}

fn identity(bytes: &[u8], domain: Domain, sequence: u64) -> Ticket {
    Ticket {
        domain,
        sequence,
        nonce: bytes[32..48].try_into().unwrap(),
        target: Target {
            device: bytes[48..64].try_into().unwrap(),
            partition: bytes[64..80].try_into().unwrap(),
            image_digest: bytes[80..112].try_into().unwrap(),
        },
    }
}

fn put_identity(bytes: &mut [u8], ticket: &Ticket) {
    bytes[32..48].copy_from_slice(&ticket.nonce);
    bytes[48..64].copy_from_slice(&ticket.target.device);
    bytes[64..80].copy_from_slice(&ticket.target.partition);
    bytes[80..112].copy_from_slice(&ticket.target.image_digest);
}

fn header(bytes: &mut [u8], magic: &[u8; 4]) {
    let len = bytes.len() as u16;
    bytes[..4].copy_from_slice(magic);
    bytes[4..6].copy_from_slice(&VERSION.to_le_bytes());
    bytes[6..8].copy_from_slice(&len.to_le_bytes());
}

fn check_header(bytes: &[u8], magic: &[u8; 4], size: usize) -> Result<(), FormatError> {
    if bytes.len() != size {
        return Err(FormatError::Length);
    }
    if bytes[..4] != magic[..] {
        return Err(FormatError::Magic);
    }
    if u16::from_le_bytes(bytes[4..6].try_into().unwrap()) != VERSION {
        return Err(FormatError::Version);
    }
    if u16::from_le_bytes(bytes[6..8].try_into().unwrap()) as usize != size {
        return Err(FormatError::Length);
    }
    if crc32c(&bytes[..size - 4]) != u32::from_le_bytes(bytes[size - 4..].try_into().unwrap()) {
        return Err(FormatError::Checksum);
    }
    Ok(())
}

fn seal(bytes: &mut [u8]) {
    let end = bytes.len() - 4;
    let crc = crc32c(&bytes[..end]);
    bytes[end..].copy_from_slice(&crc.to_le_bytes());
}

fn crc32c(bytes: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &byte in bytes {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0x82f6_3b78 & 0u32.wrapping_sub(crc & 1));
        }
    }
    !crc
}

#[cfg(test)]
mod tests;
