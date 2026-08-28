// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Control and status register bank.
//!
//! Q3 implements the M-mode and S-mode CSRs required for an SBI payload:
//! mstatus, misa, mie, mip, mtvec, mepc, mcause, mtval, mscratch, satp,
//! mtime/mtimecmp, mvendorid, marchid, mimpid, mhartid.

use crate::mem::PhysMem;

/// A CSR access error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CsrError {
    /// CSR address does not exist.
    Invalid,
    /// CSR is read-only and a write was attempted.
    ReadOnly,
    /// CSR is not implemented at this stage.
    Unimplemented,
}

impl std::fmt::Display for CsrError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CsrError::Invalid => write!(f, "invalid CSR"),
            CsrError::ReadOnly => write!(f, "read-only CSR"),
            CsrError::Unimplemented => write!(f, "unimplemented CSR"),
        }
    }
}

impl std::error::Error for CsrError {}

/// MIP/MIE interrupt-pending / enable bits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u64)]
pub enum IrqBit {
    /// Software interrupt.
    Mswi = 1 << 3,
    /// Timer interrupt.
    Mtimer = 1 << 7,
    /// External interrupt.
    Mexternal = 1 << 11,
    /// S-mode software.
    Sswi = 1 << 1,
    /// S-mode timer.
    Stimer = 1 << 5,
    /// S-mode external.
    Sexternal = 1 << 9,
}

/// Bits that appear in `sstatus` (subset of `mstatus`).
const SSTATUS_MASK: u64 =
    (1u64 << 1) | (1u64 << 5) | (1u64 << 8) | (1u64 << 18) | (1u64 << 19) | (1u64 << 63);

/// S-mode interrupt bits in `mie`/`mip`/`mideleg`.
const S_IRQ_MASK: u64 = (1u64 << 1) | (1u64 << 5) | (1u64 << 9);

/// A privileged-mode CSR bank.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Csr {
    /// Current privilege mode (0=U, 1=S, 3=M). Kept separate from mstatus.MPP.
    pub mode: u8,
    /// Hart ID.
    pub hartid: u64,
    /// ISA register (read-only for our purposes).
    pub misa: u64,
    /// Machine status.
    pub mstatus: u64,
    /// Machine interrupt enable.
    pub mie: u64,
    /// Machine interrupt pending.
    pub mip: u64,
    /// Machine exception delegation.
    pub medeleg: u64,
    /// Machine interrupt delegation.
    pub mideleg: u64,
    /// Machine trap vector.
    pub mtvec: u64,
    /// Machine exception program counter.
    pub mepc: u64,
    /// Machine trap cause.
    pub mcause: u64,
    /// Machine trap value.
    pub mtval: u64,
    /// Machine scratch.
    pub mscratch: u64,
    /// Supervisor trap vector.
    pub stvec: u64,
    /// Supervisor exception program counter.
    pub sepc: u64,
    /// Supervisor trap cause.
    pub scause: u64,
    /// Supervisor trap value.
    pub stval: u64,
    /// Supervisor scratch.
    pub sscratch: u64,
    /// Supervisor address translation.
    pub satp: u64,
    /// Floating-point accrued exception flags.
    pub fflags: u64,
    /// Floating-point dynamic rounding mode.
    pub frm: u64,
    /// Wall-clock time (lower half).
    pub mtime: u64,
    /// Wall-clock time (upper half).
    pub mtimeh: u64,
    /// Timer compare.
    pub mtimecmp: u64,
    /// Vendor ID.
    pub mvendorid: u64,
    /// Architecture ID.
    pub marchid: u64,
    /// Implementation ID.
    pub mimpid: u64,
}

impl Csr {
    /// Snapshot the entire bank as a stable (name, value) list.
    pub fn to_pairs(&self) -> Vec<(&'static str, u64)> {
        vec![
            ("mode", self.mode as u64),
            ("hartid", self.hartid),
            ("misa", self.misa),
            ("mstatus", self.mstatus),
            ("mie", self.mie),
            ("mip", self.mip),
            ("medeleg", self.medeleg),
            ("mideleg", self.mideleg),
            ("mtvec", self.mtvec),
            ("mepc", self.mepc),
            ("mcause", self.mcause),
            ("mtval", self.mtval),
            ("mscratch", self.mscratch),
            ("stvec", self.stvec),
            ("sepc", self.sepc),
            ("scause", self.scause),
            ("stval", self.stval),
            ("sscratch", self.sscratch),
            ("satp", self.satp),
            ("fflags", self.fflags),
            ("frm", self.frm),
            ("mtime", self.mtime),
            ("mtimeh", self.mtimeh),
            ("mtimecmp", self.mtimecmp),
            ("mvendorid", self.mvendorid),
            ("marchid", self.marchid),
            ("mimpid", self.mimpid),
        ]
    }

    /// Restore the bank from a (name, value) list.  Unknown names are ignored.
    pub fn from_pairs(&mut self, pairs: &[(String, u64)]) {
        for (name, value) in pairs {
            match name.as_str() {
                "mode" => self.mode = *value as u8,
                "hartid" => self.hartid = *value,
                "misa" => self.misa = *value,
                "mstatus" => self.mstatus = *value,
                "mie" => self.mie = *value,
                "mip" => self.mip = *value,
                "medeleg" => self.medeleg = *value,
                "mideleg" => self.mideleg = *value,
                "mtvec" => self.mtvec = *value,
                "mepc" => self.mepc = *value,
                "mcause" => self.mcause = *value,
                "mtval" => self.mtval = *value,
                "mscratch" => self.mscratch = *value,
                "stvec" => self.stvec = *value,
                "sepc" => self.sepc = *value,
                "scause" => self.scause = *value,
                "stval" => self.stval = *value,
                "sscratch" => self.sscratch = *value,
                "satp" => self.satp = *value,
                "fflags" => self.fflags = *value,
                "frm" => self.frm = *value,
                "mtime" => self.mtime = *value,
                "mtimeh" => self.mtimeh = *value,
                "mtimecmp" => self.mtimecmp = *value,
                "mvendorid" => self.mvendorid = *value,
                "marchid" => self.marchid = *value,
                "mimpid" => self.mimpid = *value,
                _ => {}
            }
        }
    }

    /// Create a bank for hart `hartid` with a fixed ISA string.
    pub fn new(hartid: u64) -> Self {
        Self {
            hartid,
            mode: 3,
            // RV64IMAFDC with supervisor/user (MXL=2 at bit 63, A=0, C=2, D=3,
            // F=5, I=8, M=12, S=18, U=20).  Only F is implemented this pass.
            misa: (2u64 << 62)
                | (1 << 0)
                | (1 << 2)
                | (1 << 5)
                | (1 << 8)
                | (1 << 12)
                | (1 << 18)
                | (1 << 20),
            // FS = Dirty, MPP = M, SD = 1 (derived from dirty FS).
            mstatus: (1u64 << 63) | (3u64 << 13) | (3u64 << 11),
            mvendorid: 0,
            marchid: 0,
            mimpid: 0,
            ..Self::default()
        }
    }

    /// Read a CSR by address.
    pub fn read(&self, addr: u16) -> Result<u64, CsrError> {
        match addr {
            0xF11 => Ok(self.mvendorid),
            0xF12 => Ok(self.marchid),
            0xF13 => Ok(self.mimpid),
            0xF14 => Ok(self.hartid),
            0xF15 => Ok(0), // mconfigptr
            0x301 => Ok(self.misa),
            0x300 => Ok(self.mstatus),
            0x304 => Ok(self.mie),
            0x344 => Ok(self.mip),
            0x302 => Ok(self.medeleg),
            0x303 => Ok(self.mideleg),
            0x305 => Ok(self.mtvec),
            0x341 => Ok(self.mepc),
            0x342 => Ok(self.mcause),
            0x343 => Ok(self.mtval),
            0x340 => Ok(self.mscratch),
            0x100 => Ok(self.mstatus & SSTATUS_MASK),
            0x104 => Ok(self.mie & self.mideleg & S_IRQ_MASK),
            0x144 => Ok(self.mip & self.mideleg & S_IRQ_MASK),
            0x105 => Ok(self.stvec),
            0x141 => Ok(self.sepc),
            0x142 => Ok(self.scause),
            0x143 => Ok(self.stval),
            0x140 => Ok(self.sscratch),
            0x180 => Ok(self.satp),
            0x001 => Ok(self.fflags),
            0x002 => Ok(self.frm),
            0x003 => Ok((self.frm << 5) | self.fflags),
            0x701 => Ok(self.mtime),
            0x741 => Ok(self.mtimecmp),
            0xB81 => Ok(self.mtimeh),
            _ => Err(CsrError::Unimplemented),
        }
    }

    /// Compose the 32-bit `fcsr` value from `frm` and `fflags`.
    pub fn fcsr(&self) -> u64 {
        (self.frm << 5) | self.fflags
    }

    /// Write a CSR by address.
    pub fn write(&mut self, addr: u16, val: u64) -> Result<(), CsrError> {
        match addr {
            0x300 => {
                // SD (bit 63) is read-only; it is set when FS (13:14) is dirty.
                let fs = (val >> 13) & 3;
                let sd = if fs == 3 { 1u64 << 63 } else { 0 };
                self.mstatus = (val & !(1u64 << 63)) | sd;
                Ok(())
            }
            0x304 => {
                self.mie = val;
                Ok(())
            }
            0x344 => {
                self.mip = val;
                Ok(())
            }
            0x302 => {
                self.medeleg = val;
                Ok(())
            }
            0x303 => {
                self.mideleg = val;
                Ok(())
            }
            0x305 => {
                self.mtvec = val;
                Ok(())
            }
            0x341 => {
                self.mepc = val;
                Ok(())
            }
            0x342 => {
                self.mcause = val;
                Ok(())
            }
            0x343 => {
                self.mtval = val;
                Ok(())
            }
            0x340 => {
                self.mscratch = val;
                Ok(())
            }
            0x100 => {
                let mstatus = (self.mstatus & !SSTATUS_MASK) | (val & SSTATUS_MASK);
                let fs = (mstatus >> 13) & 3;
                let sd = if fs == 3 { 1u64 << 63 } else { 0 };
                self.mstatus = (mstatus & !(1u64 << 63)) | sd;
                Ok(())
            }
            0x104 => {
                let mask = self.mideleg & S_IRQ_MASK;
                self.mie = (self.mie & !mask) | (val & mask);
                Ok(())
            }
            0x144 => {
                // SSIP (bit 1) is writable when delegated; other sip bits are read-only.
                let mask = self.mideleg & (1u64 << 1);
                self.mip = (self.mip & !mask) | (val & mask);
                Ok(())
            }
            0x105 => {
                self.stvec = val;
                Ok(())
            }
            0x141 => {
                self.sepc = val;
                Ok(())
            }
            0x142 => {
                self.scause = val;
                Ok(())
            }
            0x143 => {
                self.stval = val;
                Ok(())
            }
            0x140 => {
                self.sscratch = val;
                Ok(())
            }
            0x180 => {
                self.satp = val;
                Ok(())
            }
            0x001 => {
                self.fflags = val & 0x1f;
                Ok(())
            }
            0x002 => {
                self.frm = val & 0x07;
                Ok(())
            }
            0x003 => {
                self.fflags = val & 0x1f;
                self.frm = (val >> 5) & 0x07;
                Ok(())
            }
            0x701 => {
                self.mtime = val;
                Ok(())
            }
            0x741 => {
                self.mtimecmp = val;
                Ok(())
            }
            0xB81 => {
                self.mtimeh = val;
                Ok(())
            }
            0xF11 | 0xF12 | 0xF13 | 0xF14 | 0xF15 | 0x301 => Err(CsrError::ReadOnly),
            _ => Err(CsrError::Unimplemented),
        }
    }

    /// Read a CSR and set bits from `mask`.
    pub fn read_set(&mut self, addr: u16, mask: u64) -> Result<u64, CsrError> {
        let old = self.read(addr)?;
        self.write(addr, old | mask)?;
        Ok(old)
    }

    /// Read a CSR and clear bits from `mask`.
    pub fn read_clear(&mut self, addr: u16, mask: u64) -> Result<u64, CsrError> {
        let old = self.read(addr)?;
        self.write(addr, old & !mask)?;
        Ok(old)
    }

    /// Current privilege mode (0=U,1=S,3=M). Stored independently of mstatus.MPP.
    pub fn mode(&self) -> u8 {
        self.mode
    }

    /// Set current privilege mode; the caller updates mstatus.MPP/SPP if a trap changed it.
    pub fn set_mode(&mut self, mode: u8) {
        self.mode = mode & 0x3;
    }

    /// Advance wall-clock time from the memory map (CLINT). Not directly called in tests.
    pub fn tick(&mut self, _mem: &mut PhysMem) {
        self.mtime = self.mtime.wrapping_add(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_only_csrs_reject_writes() {
        let mut c = Csr::new(0);
        assert!(c.write(0x301, 0).is_err());
        assert!(c.read(0x301).is_ok());
    }

    #[test]
    fn read_set_and_clear_are_wmask_ops() {
        let mut c = Csr::new(0);
        assert_eq!(c.read_set(0x300, 0b11).unwrap() & 0b11, 0);
        assert_eq!(c.read(0x300).unwrap() & 0b11, 0b11);
        assert_eq!(c.read_clear(0x300, 0b10).unwrap() & 0b11, 0b11);
        assert_eq!(c.read(0x300).unwrap() & 0b11, 0b01);
    }

    #[test]
    fn mpp_is_privilege_mode() {
        let mut c = Csr::new(0);
        c.set_mode(3);
        assert_eq!(c.mode(), 3);
        c.set_mode(1);
        assert_eq!(c.mode(), 1);
    }
}
