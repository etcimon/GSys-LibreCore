// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Block devices: the one place bytes come from.
//!
//! Everything above this file — partition tables, filesystems, the mount table —
//! sees only [`BlockDev`]. That is what lets the same FAT32 or ext4 driver serve
//! a host image file on a workstation, a USB mass-storage LUN behind the guest's
//! (still to come) driver, and an in-memory image in a test.
//!
//! Writability is a property of the *device*, not a wish of the caller: a
//! read-only device refuses a write here, before a filesystem driver has a
//! chance to half-apply one.

use crate::{Error, Result};

/// Sector size every partition table and superblock offset is quoted in.
pub const SECTOR: u64 = 512;

/// A byte-addressable device. Offsets and lengths are bytes; drivers align their
/// own access, because a filesystem's natural unit (cluster, block, MFT record)
/// is not the device's.
pub trait BlockDev {
    /// Total size in bytes.
    fn len(&self) -> u64;

    fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Fill `buf` from `off`. Short reads are an error: a filesystem driver that
    /// silently sees zeros invents structure that is not there.
    fn read_at(&mut self, off: u64, buf: &mut [u8]) -> Result<()>;

    /// True when [`write_at`](Self::write_at) can succeed.
    fn writable(&self) -> bool {
        false
    }

    fn write_at(&mut self, off: u64, buf: &[u8]) -> Result<()> {
        let _ = (off, buf);
        Err(Error::ReadOnly("device"))
    }

    /// Push cached writes to the medium.
    fn flush(&mut self) -> Result<()> {
        Ok(())
    }

    /// Whole sectors, for partition-table arithmetic.
    fn sectors(&self) -> u64 {
        self.len() / SECTOR
    }
}

/// Read a fixed-size array at `off`.
pub fn read_array<const N: usize>(dev: &mut dyn BlockDev, off: u64) -> Result<[u8; N]> {
    let mut b = [0u8; N];
    dev.read_at(off, &mut b)?;
    Ok(b)
}

/// Read `len` bytes at `off`.
pub fn read_vec(dev: &mut dyn BlockDev, off: u64, len: usize) -> Result<Vec<u8>> {
    let mut b = vec![0u8; len];
    dev.read_at(off, &mut b)?;
    Ok(b)
}

pub fn le16(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([b[at], b[at + 1]])
}

pub fn le32(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

pub fn le64(b: &[u8], at: usize) -> u64 {
    let mut v = [0u8; 8];
    v.copy_from_slice(&b[at..at + 8]);
    u64::from_le_bytes(v)
}

/// An in-memory device — the test substrate, and how a small image gets handed
/// around without a filesystem under it.
#[derive(Debug, Clone)]
pub struct MemBlock {
    bytes: Vec<u8>,
    rw: bool,
}

impl MemBlock {
    pub fn new(bytes: Vec<u8>) -> Self {
        Self { bytes, rw: true }
    }

    pub fn read_only(bytes: Vec<u8>) -> Self {
        Self { bytes, rw: false }
    }

    pub fn zeroed(len: usize) -> Self {
        Self::new(vec![0u8; len])
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }
}

impl BlockDev for MemBlock {
    fn len(&self) -> u64 {
        self.bytes.len() as u64
    }

    fn read_at(&mut self, off: u64, buf: &mut [u8]) -> Result<()> {
        let start = usize::try_from(off).map_err(|_| Error::OutOfRange)?;
        let end = start.checked_add(buf.len()).ok_or(Error::OutOfRange)?;
        if end > self.bytes.len() {
            return Err(Error::OutOfRange);
        }
        buf.copy_from_slice(&self.bytes[start..end]);
        Ok(())
    }

    fn writable(&self) -> bool {
        self.rw
    }

    fn write_at(&mut self, off: u64, buf: &[u8]) -> Result<()> {
        if !self.rw {
            return Err(Error::ReadOnly("device"));
        }
        let start = usize::try_from(off).map_err(|_| Error::OutOfRange)?;
        let end = start.checked_add(buf.len()).ok_or(Error::OutOfRange)?;
        if end > self.bytes.len() {
            return Err(Error::OutOfRange);
        }
        self.bytes[start..end].copy_from_slice(buf);
        Ok(())
    }
}

/// A window onto another device — how a partition becomes a device in its own
/// right, so a filesystem driver never has to know it is not alone on the disk.
pub struct SubDev<'a> {
    inner: &'a mut dyn BlockDev,
    start: u64,
    len: u64,
    rw: bool,
}

impl<'a> SubDev<'a> {
    pub fn new(inner: &'a mut dyn BlockDev, start: u64, len: u64, rw: bool) -> Result<Self> {
        let end = start.checked_add(len).ok_or(Error::OutOfRange)?;
        if end > inner.len() {
            return Err(Error::OutOfRange);
        }
        let rw = rw && inner.writable();
        Ok(Self {
            inner,
            start,
            len,
            rw,
        })
    }

    fn map(&self, off: u64, n: usize) -> Result<u64> {
        let n = n as u64;
        let end = off.checked_add(n).ok_or(Error::OutOfRange)?;
        if end > self.len {
            return Err(Error::OutOfRange);
        }
        Ok(self.start + off)
    }
}

impl BlockDev for SubDev<'_> {
    fn len(&self) -> u64 {
        self.len
    }

    fn read_at(&mut self, off: u64, buf: &mut [u8]) -> Result<()> {
        let at = self.map(off, buf.len())?;
        self.inner.read_at(at, buf)
    }

    fn writable(&self) -> bool {
        self.rw
    }

    fn write_at(&mut self, off: u64, buf: &[u8]) -> Result<()> {
        if !self.rw {
            return Err(Error::ReadOnly("partition"));
        }
        let at = self.map(off, buf.len())?;
        self.inner.write_at(at, buf)
    }

    fn flush(&mut self) -> Result<()> {
        self.inner.flush()
    }
}

/// A device backed by a host file: an image, or a raw disk the OS lets us open.
///
/// This is the workstation and QEMU-harness path. The guest gets the same
/// drivers over its own transport once it has one.
pub struct FileBlock {
    file: std::fs::File,
    len: u64,
    rw: bool,
    path: String,
}

impl FileBlock {
    /// Open read-only.
    pub fn open(path: &str) -> Result<Self> {
        Self::open_rw(path, false)
    }

    /// Open, asking for write access. Falling back to read-only silently would
    /// let an operator believe an edit was saved, so a refused `rw` is an error.
    pub fn open_rw(path: &str, rw: bool) -> Result<Self> {
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(rw)
            .open(path)
            .map_err(|e| Error::Io(format!("{path}: {e}")))?;
        let len = file
            .metadata()
            .map_err(|e| Error::Io(format!("{path}: {e}")))?
            .len();
        Ok(Self {
            file,
            len,
            rw,
            path: path.to_string(),
        })
    }

    pub fn path(&self) -> &str {
        &self.path
    }
}

impl BlockDev for FileBlock {
    fn len(&self) -> u64 {
        self.len
    }

    fn read_at(&mut self, off: u64, buf: &mut [u8]) -> Result<()> {
        use std::io::{Read, Seek, SeekFrom};
        if off.saturating_add(buf.len() as u64) > self.len {
            return Err(Error::OutOfRange);
        }
        self.file
            .seek(SeekFrom::Start(off))
            .map_err(|e| Error::Io(format!("{}: {e}", self.path)))?;
        let mut done = 0;
        while done < buf.len() {
            match self.file.read(&mut buf[done..]) {
                Ok(0) => return Err(Error::OutOfRange),
                Ok(n) => done += n,
                Err(e) => return Err(Error::Io(format!("{}: {e}", self.path))),
            }
        }
        Ok(())
    }

    fn writable(&self) -> bool {
        self.rw
    }

    fn write_at(&mut self, off: u64, buf: &[u8]) -> Result<()> {
        use std::io::{Seek, SeekFrom, Write};
        if !self.rw {
            return Err(Error::ReadOnly("device"));
        }
        if off.saturating_add(buf.len() as u64) > self.len {
            return Err(Error::OutOfRange);
        }
        self.file
            .seek(SeekFrom::Start(off))
            .map_err(|e| Error::Io(format!("{}: {e}", self.path)))?;
        self.file
            .write_all(buf)
            .map_err(|e| Error::Io(format!("{}: {e}", self.path)))
    }

    fn flush(&mut self) -> Result<()> {
        use std::io::Write;
        self.file
            .flush()
            .map_err(|e| Error::Io(format!("{}: {e}", self.path)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mem_block_reads_writes_and_refuses_past_the_end() {
        let mut d = MemBlock::zeroed(1024);
        assert!(d.writable());
        d.write_at(512, b"hello").unwrap();
        let got = read_vec(&mut d, 512, 5).unwrap();
        assert_eq!(&got, b"hello");
        // A short read is an error, not zeros.
        assert!(matches!(read_vec(&mut d, 1020, 8), Err(Error::OutOfRange)));
        assert!(matches!(d.write_at(1024, b"x"), Err(Error::OutOfRange)));
        assert_eq!(d.sectors(), 2);
        let mut ro = MemBlock::read_only(vec![0u8; 512]);
        assert!(!ro.writable());
        assert!(matches!(ro.write_at(0, b"x"), Err(Error::ReadOnly(_))));
    }

    #[test]
    fn subdev_is_a_partition_that_cannot_see_its_neighbours() {
        let mut disk = MemBlock::zeroed(4096);
        disk.write_at(2048, b"partition-two").unwrap();
        {
            let mut p = SubDev::new(&mut disk, 2048, 1024, true).unwrap();
            assert_eq!(p.len(), 1024);
            assert_eq!(&read_vec(&mut p, 0, 13).unwrap(), b"partition-two");
            // Reads past the window fail rather than leaking the next partition.
            assert!(matches!(read_vec(&mut p, 1020, 8), Err(Error::OutOfRange)));
            p.write_at(0, b"OVERWRITTEN__").unwrap();
        }
        assert_eq!(&read_vec(&mut disk, 2048, 13).unwrap(), b"OVERWRITTEN__");
        // A read-only disk cannot be re-opened writable through a window.
        let mut ro = MemBlock::read_only(vec![0u8; 4096]);
        let p = SubDev::new(&mut ro, 0, 512, true).unwrap();
        assert!(
            !p.writable(),
            "rw cannot be conjured from a read-only device"
        );
    }
}
