// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Architectural register files and program counter.

/// 32 general-purpose registers, with `x0` hard-wired to zero.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Regs {
    /// `x1`..`x31`. `x0` is not stored; it is always returned as 0.
    x: [u64; 31],
    /// Program counter.
    pub pc: u64,
}

impl Regs {
    /// Create a register file with all X registers zero and `pc` at the given address.
    pub fn new(pc: u64) -> Self {
        Self { x: [0; 31], pc }
    }

    /// Read a register. `x0` is always 0.
    pub fn get(&self, i: u8) -> u64 {
        if i == 0 {
            0
        } else {
            self.x[(i - 1) as usize]
        }
    }

    /// Write a register. Writes to `x0` are discarded.
    pub fn set(&mut self, i: u8, v: u64) {
        if i != 0 {
            self.x[(i - 1) as usize] = v;
        }
    }

    /// The zero register really is zero, and later writes do not corrupt it.
    #[cfg(test)]
    pub fn assert_x0(&self) {
        assert_eq!(self.get(0), 0);
    }

    /// Program counter of the next sequential instruction.
    pub fn next_pc(&self) -> u64 {
        self.pc.wrapping_add(4)
    }
}

/// 32 floating-point registers, each FLEN = 64 bits.
///
/// Single-precision values are stored NaN-boxed in the lower 32 bits with the
/// upper 32 bits set to all ones, matching the RISC-V convention for FLEN > 32.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Fregs {
    f: [u64; 32],
}

impl Fregs {
    /// Create an FP register file with all registers set to the canonical
    /// 64-bit quiet-NaN bit pattern.
    pub fn new() -> Self {
        Self {
            f: [0xffff_ffff_7fc0_0000; 32],
        }
    }

    /// Read a raw 64-bit FPR value.
    pub fn get(&self, i: u8) -> u64 {
        self.f[i as usize]
    }

    /// Write a raw 64-bit FPR value.
    pub fn set(&mut self, i: u8, v: u64) {
        self.f[i as usize] = v;
    }

    /// Read the lower 32 bits, treating an un-NaN-boxed value as the
    /// canonical 32-bit quiet NaN.
    pub fn get_s(&self, i: u8) -> u32 {
        let v = self.get(i);
        if v >> 32 == 0xffff_ffff {
            v as u32
        } else {
            0x7fc0_0000
        }
    }

    /// Write a 32-bit value, NaN-boxed into a 64-bit FPR.
    pub fn set_s(&mut self, i: u8, v: u32) {
        self.set(i, 0xffff_ffff_0000_0000 | (v as u64));
    }

    /// Read the lower 32 bits as raw bits without NaN-boxing checks.
    pub fn get_s_raw(&self, i: u8) -> u32 {
        self.get(i) as u32
    }
}

#[cfg(test)]
impl Fregs {
    /// Convenience: unpack a 32-bit register as `f32`.
    pub fn get_f32(&self, i: u8) -> f32 {
        f32::from_bits(self.get_s(i))
    }

    /// Convenience: pack an `f32` into a 32-bit register.
    pub fn set_f32(&mut self, i: u8, v: f32) {
        self.set_s(i, v.to_bits());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn x0_is_always_zero() {
        let mut r = Regs::new(0x8000_0000);
        r.set(0, 42);
        assert_eq!(r.get(0), 0);
    }

    #[test]
    fn other_registers_hold_values() {
        let mut r = Regs::new(0);
        r.set(1, 1);
        r.set(31, 0xdead_beef);
        assert_eq!(r.get(1), 1);
        assert_eq!(r.get(31), 0xdead_beef);
    }

    #[test]
    fn clone_is_independent() {
        let mut a = Regs::new(0);
        a.set(1, 1);
        let b = a.clone();
        a.set(1, 2);
        assert_eq!(b.get(1), 1);
    }
}
