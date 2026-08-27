// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Memory-mapped devices for the g6lc-soc faithful profile.
//!
//! Q3 starts with CLINT (timers and MSIP) and a minimal NS16550a-like UART
//! (transmit-only for console output). PLIC is a later increment.

/// A memory-mapped device.
pub trait MmioDevice: std::fmt::Debug {
    /// Load a value of `width` bytes (1, 2, 4 or 8) at `offset` from the device base.
    fn load(&self, offset: u64, width: usize) -> u64;
    /// Store `value` (low `width*8` bits) at `offset`.
    fn store(&mut self, offset: u64, width: usize, value: u64);
    /// Claims the highest-priority pending interrupt for target `i` (PLIC-style), or `None`.
    fn claim(&mut self, _target: u32) -> Option<u32> {
        None
    }
    /// Completes an interrupt for target `i` (PLIC-style).
    fn complete(&mut self, _target: u32, _irq: u32) {}
}

/// Core-local interruptor.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Clint {
    /// Machine-mode software interrupt pending for each hart.
    pub msip: Vec<u64>,
    /// Time compare for each hart.
    pub mtimecmp: Vec<u64>,
    /// Free-running wall-clock time.
    pub mtime: u64,
    /// Number of harts.
    pub harts: usize,
}

impl Clint {
    /// Create a CLINT for `harts` harts.
    pub fn new(harts: usize) -> Self {
        Self {
            msip: vec![0; harts],
            mtimecmp: vec![u64::MAX; harts],
            mtime: 0,
            harts,
        }
    }

    /// Advance `mtime`.
    pub fn tick(&mut self) {
        self.mtime = self.mtime.wrapping_add(1);
    }

    /// True if hart `i` has a pending timer interrupt.
    pub fn timer_pending(&self, i: usize) -> bool {
        i < self.harts && self.mtime >= self.mtimecmp[i]
    }

    fn hart_addr(&self, offset: u64) -> Option<usize> {
        // MSIP: 0x0000, 4 bytes per hart
        // MTIMECMP: 0x4000, 8 bytes per hart
        // MTIME: 0xbff8
        if offset < 0x4000 {
            let i = (offset / 4) as usize;
            if i < self.harts {
                return Some(i);
            }
        } else if offset < 0xbff8 {
            let i = ((offset - 0x4000) / 8) as usize;
            if i < self.harts {
                return Some(i);
            }
        }
        None
    }
}

impl MmioDevice for Clint {
    fn load(&self, offset: u64, width: usize) -> u64 {
        if offset == 0xbff8 && (width == 4 || width == 8) {
            self.mtime
        } else if offset == 0xbff0 && (width == 4 || width == 8) {
            self.mtime >> 32
        } else if let Some(i) = self.hart_addr(offset) {
            if offset < 0x4000 && width == 4 {
                self.msip[i]
            } else {
                self.mtimecmp[i]
            }
        } else {
            0
        }
    }

    fn store(&mut self, offset: u64, width: usize, value: u64) {
        if offset == 0xbff8 && (width == 4 || width == 8) {
            self.mtime = (self.mtime & !0xffff_ffff) | (value & 0xffff_ffff);
        } else if offset == 0xbff0 && (width == 4 || width == 8) {
            self.mtime = (self.mtime & 0xffff_ffff) | (value << 32);
        } else if let Some(i) = self.hart_addr(offset) {
            if offset < 0x4000 && width == 4 {
                self.msip[i] = value & 1;
            } else {
                self.mtimecmp[i] = value;
            }
        }
    }
}

/// Transmit-only NS16550a-ish UART.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Uart {
    /// Console bytes emitted by the guest.
    pub output: Vec<u8>,
    /// THR (offset 0) holds the last byte written, or 0.
    pub thr: u8,
    /// LSR: bit 5 (THRE) and bit 6 (TEMT) set.
    pub lsr: u8,
}

impl Uart {
    /// Create a fresh UART.
    pub fn new() -> Self {
        Self {
            lsr: 0x60,
            ..Self::default()
        }
    }
}

impl MmioDevice for Uart {
    fn load(&self, offset: u64, width: usize) -> u64 {
        if width != 1 && width != 4 {
            return 0;
        }
        match offset {
            0x0 => self.thr as u64,
            0x5 => self.lsr as u64,
            _ => 0,
        }
    }

    fn store(&mut self, offset: u64, width: usize, value: u64) {
        if (width == 1 || width == 4) && offset == 0x0 {
            self.thr = (value & 0xff) as u8;
            self.output.push(self.thr);
        }
    }
}

/// Platform-level interrupt controller (simplified 30/16 geometry).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Plic {
    /// Number of interrupt sources.
    pub num_sources: u32,
    /// Number of interrupt targets (contexts).
    pub num_targets: u32,
    /// Priority per source.
    pub priority: Vec<u32>,
    /// Pending bit mask.
    pub pending: u32,
    /// Enable bit mask per target.
    pub enable: Vec<u32>,
    /// Priority threshold per target.
    pub threshold: Vec<u32>,
    /// Last claimed interrupt per target.
    pub claim: Vec<u32>,
    /// Sources currently claimed but not completed (per target).
    pub claimed: Vec<u32>,
}

impl Plic {
    /// Create a PLIC with the given number of sources and targets.
    pub fn new(num_sources: u32, num_targets: u32) -> Self {
        Self {
            num_sources,
            num_targets,
            priority: vec![0; num_sources as usize + 1],
            pending: 0,
            enable: vec![0; num_targets as usize],
            threshold: vec![0; num_targets as usize],
            claim: vec![0; num_targets as usize],
            claimed: vec![0; num_targets as usize],
        }
    }
}

impl MmioDevice for Plic {
    fn load(&self, offset: u64, width: usize) -> u64 {
        if width != 4 {
            return 0;
        }
        if offset == 0x0200_0004 {
            // claim/complete for target 0
            self.claim[0] as u64
        } else if (0x0..0x1000).contains(&offset) {
            let i = (offset / 4) as usize;
            if i < self.priority.len() {
                self.priority[i] as u64
            } else {
                0
            }
        } else {
            0
        }
    }

    fn store(&mut self, offset: u64, width: usize, value: u64) {
        if width != 4 {
            return;
        }
        if (0x0..0x1000).contains(&offset) {
            let i = (offset / 4) as usize;
            if i < self.priority.len() {
                self.priority[i] = (value & 0xff) as u32;
            }
        } else if offset == 0x0200_0004 {
            self.claim[0] = 0;
        }
    }

    fn claim(&mut self, target: u32) -> Option<u32> {
        if target as usize >= self.num_targets as usize {
            return None;
        }
        let mask = self.enable[target as usize] & self.pending & !self.claimed[target as usize];
        if mask == 0 {
            return None;
        }
        // Return lowest set source id as a placeholder.
        let irq = mask.trailing_zeros();
        if irq > self.num_sources {
            return None;
        }
        self.claim[target as usize] = irq;
        self.claimed[target as usize] |= 1u32 << irq;
        Some(irq)
    }

    fn complete(&mut self, target: u32, irq: u32) {
        if (target as usize) < self.num_targets as usize {
            self.pending &= !(1u32 << irq);
            self.claimed[target as usize] &= !(1u32 << irq);
            self.claim[target as usize] = 0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clint_mtimecmp_and_msip() {
        let mut c = Clint::new(2);
        c.store(0x0, 4, 1);
        c.store(0x4000, 8, 0x1234);
        assert_eq!(c.load(0x0, 4), 1);
        assert_eq!(c.load(0x4000, 8), 0x1234);
        assert_eq!(c.load(0x4008, 8), u64::MAX);
    }

    #[test]
    fn uart_transmits_bytes() {
        let mut u = Uart::new();
        u.store(0x0, 1, b'X' as u64);
        assert_eq!(u.output, vec![b'X']);
        assert_eq!(u.load(0x5, 1), 0x60);
    }

    #[test]
    fn plic_claims_highest_enabled_pending() {
        let mut p = Plic::new(30, 16);
        p.priority[5] = 1;
        p.enable[0] = 1 << 5;
        p.pending = 1 << 5;
        assert_eq!(p.claim(0), Some(5));
        assert_eq!(p.claim(0), None);
        p.complete(0, 5);
        assert_eq!(p.pending & (1 << 5), 0);
    }
}
