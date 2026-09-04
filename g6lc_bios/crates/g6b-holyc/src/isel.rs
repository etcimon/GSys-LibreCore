// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! RISC-V ISel for the HolyC subset. Rewrite of ZealOS `Compiler/Back*.ZC`
//! (x86) — not a copy. RVV encodings only when `rvv` is true (BoardSpec
//! `extensions.v=live` ∧ xlen=64).
//!
//! Assembly and machine words lower from `g6b-asm` IR (see
//! `architecture/CODEGEN.md`). This module is the HolyC-facing Target.

#![allow(missing_docs)]

/// ISel target (subset of BoardSpec ISA).
#[derive(Debug, Clone, Copy)]
pub struct Target {
    pub xlen: u32,
    pub rvv: bool,
}

impl Target {
    /// Marker printed in the payload / boot log.
    pub fn marker(self) -> &'static str {
        if self.rvv {
            "ISEL-RVV"
        } else {
            "ISEL-SCALAR"
        }
    }
}

/// RISC-V assembly for `MemCpy(dst, src, n)` (`a0,a1,a2`).
pub fn memcpy_asm(t: Target) -> String {
    g6b_asm::analyze::memcpy(t.xlen, t.rvv).to_asm()
}

/// Machine words for [`memcpy_asm`], same ABI.
pub fn memcpy_insns(t: Target) -> Vec<u32> {
    g6b_asm::analyze::memcpy(t.xlen, t.rvv)
        .to_words(0)
        .expect("memcpy labels")
        .0
}

/// SBI SRST rewrite of `KMain.ZC` `Reboot` (not port 0x64 / 0x92).
pub fn reboot_asm() -> String {
    g6b_asm::analyze::reboot().to_asm()
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_asm::encode::{A2, T0, VTYPE_E8_M1_TA_MA};

    #[test]
    fn scalar_has_lbu_not_vsetvli() {
        let t = Target {
            xlen: 64,
            rvv: false,
        };
        let s = memcpy_asm(t);
        assert!(s.contains("lbu"), "{s}");
        assert!(!s.contains("vsetvli"), "{s}");
        assert_eq!(t.marker(), "ISEL-SCALAR");
        let w = memcpy_insns(t);
        assert!(!w.contains(&g6b_asm::encode::vsetvli(T0, A2, VTYPE_E8_M1_TA_MA)));
    }

    #[test]
    fn rvv_has_vsetvli() {
        let t = Target {
            xlen: 64,
            rvv: true,
        };
        let s = memcpy_asm(t);
        assert!(s.contains("vsetvli"), "{s}");
        assert!(s.contains("vle8.v"), "{s}");
        assert!(s.contains("vse8.v"), "{s}");
        assert_eq!(t.marker(), "ISEL-RVV");
        let w = memcpy_insns(t);
        assert!(w.contains(&g6b_asm::encode::vsetvli(T0, A2, VTYPE_E8_M1_TA_MA)));
    }

    #[test]
    fn reboot_is_sbi_not_cf9() {
        let s = reboot_asm();
        assert!(s.contains("0x53525354"), "{s}");
        assert!(s.contains("SRST"), "{s}");
        assert!(!s.to_lowercase().contains("cf9"), "{s}");
    }
}
