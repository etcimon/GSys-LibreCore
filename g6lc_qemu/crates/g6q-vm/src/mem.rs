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

/// The physical address space.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PhysMem {
    regions: Vec<Region>,
}

impl PhysMem {
    /// Empty memory.
    pub fn new() -> Self {
        Self::default()
    }

    /// Add a region. Regions must not overlap.
    pub fn add(&mut self, r: Region) {
        // A physical memory with overlapping regions is ambiguous; assert at insertion.
        for e in &self.regions {
            assert!(
                r.base >= e.base + e.len || r.base + r.len <= e.base,
                "memory regions may not overlap: {r:?} vs {e:?}"
            );
        }
        self.regions.push(r);
        self.regions.sort_by_key(|r| r.base);
    }

    /// Total installed bytes.
    pub fn size(&self) -> u64 {
        self.regions.iter().map(|r| r.len).sum()
    }

    fn region_for(&self, addr: u64, n: usize) -> Option<&Region> {
        self.regions.iter().find(|r| r.contains(addr, n))
    }

    fn region_for_mut(&mut self, addr: u64, n: usize) -> Option<&mut Region> {
        self.regions.iter_mut().find(|r| r.contains(addr, n))
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
