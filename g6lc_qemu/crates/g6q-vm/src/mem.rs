// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Flat physical memory with a simple read/write byte interface.
//!
//! Q3 begins with a flat model. Address translation (Sv39) is a separate layer that
//! can be inserted without touching the interpreter, because the memory bus is an
//! interface.

/// A memory access error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemError {
    /// Access outside any installed region.
    OutOfBounds,
    /// Access crossed a region boundary or had unaligned address.
    ///
    /// This implementation does not yet model misalignment; it stops instead of silently
    /// completing a broken access.
    Misaligned,
    /// The address was invalid (e.g. a translation returned a non-physical value).
    Invalid,
}

impl std::fmt::Display for MemError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MemError::OutOfBounds => write!(f, "out of bounds"),
            MemError::Misaligned => write!(f, "misaligned"),
            MemError::Invalid => write!(f, "invalid"),
        }
    }
}

impl std::error::Error for MemError {}

/// A physical memory region.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Region {
    /// Region base.
    pub base: u64,
    /// Region length.
    pub len: u64,
    /// Backing bytes.
    pub data: Vec<u8>,
}

impl Region {
    /// Create a new region, padding with zeroes.
    pub fn new(base: u64, len: u64) -> Self {
        Self {
            base,
            len,
            data: vec![0; len as usize],
        }
    }

    /// Load a file into the region at `base`.
    pub fn from_file(base: u64, text: &[u8]) -> Self {
        let mut r = Self::new(base, text.len() as u64);
        r.data.copy_from_slice(text);
        r
    }

    fn contains(&self, addr: u64, n: usize) -> bool {
        let end = match addr.checked_add(n as u64) {
            Some(e) => e,
            None => return false,
        };
        addr >= self.base && end <= self.base.saturating_add(self.len)
    }

    fn read<const N: usize>(&self, addr: u64) -> [u8; N] {
        let off = (addr - self.base) as usize;
        let mut out = [0u8; N];
        out.copy_from_slice(&self.data[off..off + N]);
        out
    }

    fn write<const N: usize>(&mut self, addr: u64, bytes: [u8; N]) {
        let off = (addr - self.base) as usize;
        self.data[off..off + N].copy_from_slice(&bytes);
    }
}

use g6q_core::Json;

use crate::device::MmioDevice;

/// A memory-mapped device entry.
#[derive(Debug, Clone)]
pub struct Device {
    /// Device base address.
    pub base: u64,
    /// Device address length.
    pub len: u64,
    /// Device instance.
    pub kind: DeviceKind,
}

impl Device {
    /// Create a device entry.
    pub fn new(base: u64, len: u64, kind: DeviceKind) -> Self {
        Self { base, len, kind }
    }

    fn contains(&self, addr: u64, n: usize) -> bool {
        let end = match addr.checked_add(n as u64) {
            Some(e) => e,
            None => return false,
        };
        addr >= self.base && end <= self.base.saturating_add(self.len)
    }
}

/// Supported device types.
#[derive(Debug, Clone)]
pub enum DeviceKind {
    /// Core-local interruptor.
    Clint(crate::device::Clint),
    /// NS16550a transmit-only UART.
    Uart(crate::device::Uart),
    /// Platform-level interrupt controller.
    Plic(crate::device::Plic),
    /// AI-island / matrix accelerator stub.
    AiIsland(crate::device::AiIsland),
}

impl DeviceKind {
    fn load(&self, offset: u64, width: usize) -> u64 {
        match self {
            DeviceKind::Clint(c) => c.load(offset, width),
            DeviceKind::Uart(u) => u.load(offset, width),
            DeviceKind::Plic(p) => p.load(offset, width),
            DeviceKind::AiIsland(a) => a.load(offset, width),
        }
    }

    fn store(&mut self, offset: u64, width: usize, value: u64) {
        match self {
            DeviceKind::Clint(c) => c.store(offset, width, value),
            DeviceKind::Uart(u) => u.store(offset, width, value),
            DeviceKind::Plic(p) => p.store(offset, width, value),
            DeviceKind::AiIsland(a) => a.store(offset, width, value),
        }
    }

    /// Human-readable device tag for checkpoint naming.
    fn tag(&self) -> &'static str {
        match self {
            DeviceKind::Clint(_) => "clint",
            DeviceKind::Uart(_) => "uart",
            DeviceKind::Plic(_) => "plic",
            DeviceKind::AiIsland(_) => "ai-island",
        }
    }

    fn snapshot(&self) -> Vec<(String, Json)> {
        match self {
            DeviceKind::Clint(c) => c.snapshot(),
            DeviceKind::Uart(u) => u.snapshot(),
            DeviceKind::Plic(p) => p.snapshot(),
            DeviceKind::AiIsland(a) => a.snapshot(),
        }
    }

    fn restore(&mut self, state: &[(String, Json)]) {
        match self {
            DeviceKind::Clint(c) => c.restore(state),
            DeviceKind::Uart(u) => u.restore(state),
            DeviceKind::Plic(p) => p.restore(state),
            DeviceKind::AiIsland(a) => a.restore(state),
        }
    }
}

/// The physical address space.
#[derive(Debug, Clone, Default)]
pub struct PhysMem {
    regions: Vec<Region>,
    devices: Vec<Device>,
}

impl PhysMem {
    /// Empty memory.
    pub fn new() -> Self {
        Self::default()
    }

    /// Add a memory region. Regions and devices must not overlap.
    pub fn add(&mut self, r: Region) {
        for e in &self.regions {
            assert!(
                r.base >= e.base + e.len || r.base + r.len <= e.base,
                "memory regions may not overlap: {r:?} vs {e:?}"
            );
        }
        for d in &self.devices {
            assert!(
                r.base >= d.base + d.len || r.base + r.len <= d.base,
                "memory region overlaps device: {r:?} vs {d:?}"
            );
        }
        self.regions.push(r);
        self.regions.sort_by_key(|r| r.base);
    }

    /// Add a memory-mapped device.
    pub fn add_device(&mut self, d: Device) {
        for e in &self.regions {
            assert!(
                d.base >= e.base + e.len || d.base + d.len <= e.base,
                "device overlaps memory region: {d:?} vs {e:?}"
            );
        }
        for e in &self.devices {
            assert!(
                d.base >= e.base + e.len || d.base + d.len <= e.base,
                "devices may not overlap: {d:?} vs {e:?}"
            );
        }
        self.devices.push(d);
    }

    /// Borrow the CLINT, if installed.
    pub fn clint(&self) -> Option<&crate::device::Clint> {
        self.devices.iter().find_map(|d| match &d.kind {
            DeviceKind::Clint(c) => Some(c),
            _ => None,
        })
    }

    /// Borrow the CLINT mutably.
    pub fn clint_mut(&mut self) -> Option<&mut crate::device::Clint> {
        self.devices.iter_mut().find_map(|d| match &mut d.kind {
            DeviceKind::Clint(c) => Some(c),
            _ => None,
        })
    }

    /// Borrow the UART, if installed.
    pub fn uart(&self) -> Option<&crate::device::Uart> {
        self.devices.iter().find_map(|d| match &d.kind {
            DeviceKind::Uart(u) => Some(u),
            _ => None,
        })
    }

    /// Borrow the PLIC, if installed.
    pub fn plic(&self) -> Option<&crate::device::Plic> {
        self.devices.iter().find_map(|d| match &d.kind {
            DeviceKind::Plic(p) => Some(p),
            _ => None,
        })
    }

    /// Snapshot every installed device as a list of `DeviceSnapshot` records.
    pub fn device_snapshots(&self) -> Vec<g6q_diag::DeviceSnapshot> {
        self.devices
            .iter()
            .map(|d| g6q_diag::DeviceSnapshot {
                base: d.base,
                kind: d.kind.tag().to_string(),
                state: d.kind.snapshot(),
            })
            .collect()
    }

    /// Restore device state from a list of `DeviceSnapshot` records.
    ///
    /// Devices are matched by base address and kind.  The address space is assumed to already
    /// contain the same device instances (restore is normally paired with `Hart::restore`).
    pub fn restore_devices(&mut self, snapshots: &[g6q_diag::DeviceSnapshot]) {
        for snap in snapshots {
            if let Some(d) = self.devices.iter_mut().find(|d| d.base == snap.base) {
                if d.kind.tag() == snap.kind {
                    d.kind.restore(&snap.state);
                }
            }
        }
    }

    /// Borrow the PLIC mutably.
    pub fn plic_mut(&mut self) -> Option<&mut crate::device::Plic> {
        self.devices.iter_mut().find_map(|d| match &mut d.kind {
            DeviceKind::Plic(p) => Some(p),
            _ => None,
        })
    }

    /// Borrow the AI island, if installed.
    pub fn ai_island(&self) -> Option<&crate::device::AiIsland> {
        self.devices.iter().find_map(|d| match &d.kind {
            DeviceKind::AiIsland(a) => Some(a),
            _ => None,
        })
    }

    /// Borrow the AI island mutably.
    pub fn ai_island_mut(&mut self) -> Option<&mut crate::device::AiIsland> {
        self.devices.iter_mut().find_map(|d| match &mut d.kind {
            DeviceKind::AiIsland(a) => Some(a),
            _ => None,
        })
    }

    /// Total installed memory bytes.
    pub fn size(&self) -> u64 {
        self.regions.iter().map(|r| r.len).sum()
    }

    /// Snapshot every installed memory region as a list of (base, len, data).
    pub fn snapshot(&self) -> Vec<(u64, u64, Vec<u8>)> {
        self.regions
            .iter()
            .map(|r| (r.base, r.len, r.data.clone()))
            .collect()
    }

    /// Replace all installed memory regions with the given snapshot.
    ///
    /// This is only safe if the caller has also re-initialised devices; it is intended
    /// for checkpoint restore where the caller rebuilds the address space from the model.
    pub fn restore(&mut self, snapshot: &[(u64, u64, Vec<u8>)]) {
        self.regions = snapshot
            .iter()
            .map(|(base, len, data)| {
                assert_eq!(
                    data.len(),
                    *len as usize,
                    "checkpoint region length mismatch"
                );
                Region {
                    base: *base,
                    len: *len,
                    data: data.clone(),
                }
            })
            .collect();
        self.regions.sort_by_key(|r| r.base);
    }

    fn region_for(&self, addr: u64, n: usize) -> Option<&Region> {
        self.regions.iter().find(|r| r.contains(addr, n))
    }

    fn region_for_mut(&mut self, addr: u64, n: usize) -> Option<&mut Region> {
        self.regions.iter_mut().find(|r| r.contains(addr, n))
    }

    fn device_for(&self, addr: u64, n: usize) -> Option<&Device> {
        self.devices.iter().find(|d| d.contains(addr, n))
    }

    fn device_for_mut(&mut self, addr: u64, n: usize) -> Option<&mut Device> {
        self.devices.iter_mut().find(|d| d.contains(addr, n))
    }

    /// Read `N` bytes at `addr`, little-endian.
    pub fn read_le<const N: usize>(&self, addr: u64) -> Result<u64, MemError> {
        match N {
            1 | 2 | 4 | 8 => {}
            _ => return Err(MemError::Misaligned),
        }
        if addr % N as u64 != 0 {
            return Err(MemError::Misaligned);
        }
        if let Some(d) = self.device_for(addr, N) {
            return Ok(d.kind.load(addr - d.base, N));
        }
        let r = self.region_for(addr, N).ok_or(MemError::OutOfBounds)?;
        let bytes = r.read::<N>(addr);
        let mut v = 0u64;
        for (i, b) in bytes.iter().enumerate() {
            v |= (*b as u64) << (8 * i);
        }
        Ok(v)
    }

    /// Write `N` bytes at `addr`, little-endian, taking only the low `8*N` bits.
    pub fn write_le<const N: usize>(&mut self, addr: u64, val: u64) -> Result<(), MemError> {
        match N {
            1 | 2 | 4 | 8 => {}
            _ => return Err(MemError::Misaligned),
        }
        if addr % N as u64 != 0 {
            return Err(MemError::Misaligned);
        }
        if let Some(d) = self.device_for_mut(addr, N) {
            d.kind.store(addr - d.base, N, val);
            return Ok(());
        }
        let r = self.region_for_mut(addr, N).ok_or(MemError::OutOfBounds)?;
        let mut bytes = [0u8; N];
        for (i, b) in bytes.iter_mut().enumerate() {
            *b = ((val >> (8 * i)) & 0xff) as u8;
        }
        r.write(addr, bytes);
        Ok(())
    }

    /// Read `N` bytes and sign-extend them to `i64`.
    pub fn read_sext<const N: usize>(&self, addr: u64) -> Result<i64, MemError> {
        let u = self.read_le::<N>(addr)?;
        let shift = 64 - 8 * N;
        Ok(((u << shift) as i64) >> shift)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_write_round_trips_le() {
        let mut m = PhysMem::new();
        m.add(Region::new(0x8000_0000, 0x1000));
        m.write_le::<8>(0x8000_0000, 0x1122_3344_5566_7788).unwrap();
        assert_eq!(m.read_le::<1>(0x8000_0000).unwrap(), 0x88);
        assert_eq!(m.read_le::<2>(0x8000_0000).unwrap(), 0x7788);
        assert_eq!(m.read_le::<4>(0x8000_0000).unwrap(), 0x5566_7788);
        assert_eq!(m.read_le::<8>(0x8000_0000).unwrap(), 0x1122_3344_5566_7788);
    }

    #[test]
    fn sign_extend_reads() {
        let mut m = PhysMem::new();
        m.add(Region::new(0x8000_0000, 0x1000));
        m.write_le::<1>(0x8000_0000, 0xff).unwrap();
        m.write_le::<2>(0x8000_0002, 0x8000).unwrap();
        m.write_le::<4>(0x8000_0004, 0x8000_0000).unwrap();
        assert_eq!(m.read_sext::<1>(0x8000_0000).unwrap(), -1);
        assert_eq!(m.read_sext::<2>(0x8000_0002).unwrap(), -0x8000);
        assert_eq!(m.read_sext::<4>(0x8000_0004).unwrap(), -0x8000_0000);
    }

    #[test]
    fn misaligned_and_out_of_bounds_fail() {
        let mut m = PhysMem::new();
        m.add(Region::new(0x8000_0000, 0x1000));
        assert!(m.read_le::<8>(0x8000_0001).is_err());
        assert!(m.read_le::<8>(0x9000_0000).is_err());
        assert!(m.write_le::<4>(0x8000_0fff, 0).is_err()); // crosses end
    }

    #[test]
    fn overlapping_regions_are_rejected() {
        let mut m = PhysMem::new();
        m.add(Region::new(0x8000_0000, 0x1000));
        let result = std::panic::catch_unwind(|| {
            let mut m2 = m.clone();
            m2.add(Region::new(0x8000_0800, 0x1000));
        });
        assert!(result.is_err());
    }
}
