// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Bounded bump allocator for the `no_std` native service core.
//!
//! Workspace `unsafe_code = forbid`, so this is not a Rust `GlobalAlloc`.
//! Callers own the backing bytes; the bump hands out aligned [`Span`]s
//! (offset + length) and fails closed on OOM or a bad align. No free
//! except [`Bump::reset`]. Not DMA, not W^X, not QEMU.

use crate::{Error, Span};

/// Default alignment for native ABI words.
pub const HEAP_ALIGN: usize = 8;

/// Cursor over a caller-owned arena.
#[derive(Clone, Copy, Debug)]
pub struct Bump {
    cap: usize,
    used: usize,
}

impl Bump {
    /// `cap` is the backing length in bytes. Offsets start at 0.
    pub const fn new(cap: usize) -> Self {
        Self { cap, used: 0 }
    }

    pub const fn cap(&self) -> usize {
        self.cap
    }

    pub const fn used(&self) -> usize {
        self.used
    }

    /// Allocate `size` bytes at `align` (power of two). `size == 0` returns
    /// a zero-length span at the current aligned cursor and does not move it
    /// past `cap`.
    pub fn alloc(&mut self, size: usize, align: usize) -> Result<Span, Error> {
        if align == 0 || !align.is_power_of_two() {
            return Err(Error::Bounds);
        }
        let mask = align - 1;
        let aligned = self.used.checked_add(mask).ok_or(Error::Overflow)? & !mask;
        let end = aligned.checked_add(size).ok_or(Error::Overflow)?;
        if end > self.cap {
            return Err(Error::Overflow);
        }
        self.used = end;
        Ok(Span {
            address: aligned as u64,
            length: size as u64,
        })
    }

    /// [`HEAP_ALIGN`] convenience.
    pub fn alloc_word(&mut self, size: usize) -> Result<Span, Error> {
        self.alloc(size, HEAP_ALIGN)
    }

    /// Drop every allocation. Does not scrub the backing store.
    pub fn reset(&mut self) {
        self.used = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::POLL_REPORT_BYTES;

    #[test]
    fn sequential_word_allocs_are_aligned_and_disjoint() {
        let mut b = Bump::new(64);
        let a = b.alloc_word(1).unwrap();
        let c = b.alloc_word(8).unwrap();
        assert_eq!(a.address, 0);
        assert_eq!(a.length, 1);
        assert_eq!(c.address, 8);
        assert_eq!(c.length, 8);
        assert!(a.end().unwrap() <= c.address);
        assert_eq!(b.used(), 16);
    }

    #[test]
    fn oom_is_fail_closed() {
        let mut b = Bump::new(16);
        let _ = b.alloc(16, 1).unwrap();
        let used = b.used();
        assert_eq!(b.alloc(1, 1), Err(Error::Overflow));
        assert_eq!(b.used(), used);
    }

    #[test]
    fn bad_align_is_bounds() {
        let mut b = Bump::new(32);
        assert_eq!(b.alloc(4, 0), Err(Error::Bounds));
        assert_eq!(b.alloc(4, 3), Err(Error::Bounds));
        assert_eq!(b.used(), 0);
    }

    #[test]
    fn reset_reuses_the_arena() {
        let mut b = Bump::new(32);
        let _ = b.alloc(16, 8).unwrap();
        b.reset();
        assert_eq!(b.used(), 0);
        assert_eq!(b.alloc(16, 8).unwrap().address, 0);
    }

    #[test]
    fn two_bumps_do_not_share_a_cursor() {
        let mut a = Bump::new(32);
        let mut c = Bump::new(32);
        let _ = a.alloc(24, 8).unwrap();
        let s = c.alloc(8, 8).unwrap();
        assert_eq!(s.address, 0);
        assert_eq!(a.used(), 24);
        assert_eq!(c.used(), 8);
    }

    #[test]
    fn poll_report_fits() {
        let mut b = Bump::new(64);
        let s = b.alloc_word(POLL_REPORT_BYTES).unwrap();
        assert_eq!(s.length, POLL_REPORT_BYTES as u64);
        assert_eq!(s.address % HEAP_ALIGN as u64, 0);
    }

    #[test]
    fn overflow_add_is_fail_closed() {
        let mut b = Bump::new(usize::MAX);
        b.used = usize::MAX - 3;
        assert_eq!(b.alloc(8, 8), Err(Error::Overflow));
    }

    #[test]
    fn zero_size_does_not_consume_capacity() {
        let mut b = Bump::new(16);
        let z = b.alloc(0, HEAP_ALIGN).unwrap();
        assert_eq!(
            z,
            Span {
                address: 0,
                length: 0
            }
        );
        assert_eq!(b.used(), 0);
        assert_eq!(b.alloc_word(8).unwrap().address, 0);
    }

    #[test]
    fn sequential_spans_do_not_overlap() {
        let mut b = Bump::new(64);
        let a = b.alloc_word(8).unwrap();
        let c = b.alloc_word(8).unwrap();
        assert_eq!(a.overlaps(c), Ok(false));
        assert_eq!(c.overlaps(a), Ok(false));
    }

    #[test]
    fn caller_owned_backing_is_indexed_by_span() {
        let mut mem = [0u8; 64];
        let mut b = Bump::new(mem.len());
        let report = b.alloc_word(POLL_REPORT_BYTES).unwrap();
        let extra = b.alloc_word(8).unwrap();
        let r0 = report.address as usize;
        let r1 = r0 + report.length as usize;
        let e0 = extra.address as usize;
        let e1 = e0 + extra.length as usize;
        mem[r0..r1].copy_from_slice(&[1; POLL_REPORT_BYTES]);
        mem[e0..e1].copy_from_slice(&[2; 8]);
        assert_eq!(&mem[0..POLL_REPORT_BYTES], &[1; POLL_REPORT_BYTES]);
        assert_eq!(&mem[POLL_REPORT_BYTES..POLL_REPORT_BYTES + 8], &[2; 8]);
        assert!(mem[POLL_REPORT_BYTES + 8..].iter().all(|&b| b == 0));
    }
}
