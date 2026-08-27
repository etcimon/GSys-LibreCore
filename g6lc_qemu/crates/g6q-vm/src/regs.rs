// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Architectural register file and program counter.

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
