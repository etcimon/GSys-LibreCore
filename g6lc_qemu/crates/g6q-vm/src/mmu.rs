// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Sv39 page-table walk for the native VM.

use crate::mem::PhysMem;

/// Why a translation walk failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MmuError {
    /// SATP mode is 0 (bare), so no translation was performed.
    Bare,
    /// SATP mode is not supported.
    Unsupported,
    /// The virtual address is not canonical.
    BadVaddr,
    /// The page table pointed at a non-existent physical address.
    Access,
    /// A PTE was invalid or the permission check failed.
    PageFault,
}

impl std::fmt::Display for MmuError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MmuError::Bare => write!(f, "bare translation"),
            MmuError::Unsupported => write!(f, "unsupported SATP mode"),
            MmuError::BadVaddr => write!(f, "non-canonical virtual address"),
            MmuError::Access => write!(f, "page-table access fault"),
            MmuError::PageFault => write!(f, "page fault"),
        }
    }
}

impl std::error::Error for MmuError {}

/// Translate `vaddr` through an Sv39 page table.
///
/// If `satp` mode is `0` (bare) this immediately returns the virtual address.
/// If `satp` mode is `8` (Sv39) it walks a three-level page table and returns
/// the physical address.  Larger page sizes are supported when a valid, valid
/// leaf PTE is found at level 1 or 2.
pub fn translate(mem: &PhysMem, satp: u64, vaddr: u64) -> Result<u64, MmuError> {
    let mode = satp >> 60;
    if mode == 0 {
        return Ok(vaddr);
    }
    if mode != 8 {
        return Err(MmuError::Unsupported);
    }

    // Sv39 virtual addresses are 39 bits and sign-extended from bit 38.
    let sign = (vaddr >> 38) & 1;
    if sign != 0 && vaddr >> 39 != !0u64 {
        return Err(MmuError::BadVaddr);
    }
    if sign == 0 && vaddr >> 39 != 0 {
        return Err(MmuError::BadVaddr);
    }

    let vpn = [
        (vaddr >> 12) & 0x1ff,
        (vaddr >> 21) & 0x1ff,
        (vaddr >> 30) & 0x1ff,
    ];
    let mut a = (satp & 0x0000_00ff_ffff_ffff) << 12; // PPN field

    for level in (0..=2).rev() {
        let pte_addr = a + (vpn[level] << 3);
        let pte = match mem.read_le::<8>(pte_addr) {
            Ok(v) => v,
            Err(_) => return Err(MmuError::Access),
        };

        let v = pte & 1 != 0;
        let r = (pte >> 1) & 1 != 0;
        let w = (pte >> 2) & 1 != 0;
        let x = (pte >> 3) & 1 != 0;
        let ppn = (pte >> 10) & 0x0000_00ff_ffff_ffff; // 44 bits

        if !v || (!r && w) {
            return Err(MmuError::PageFault);
        }

        if r || w || x {
            // Leaf PTE.
            let ignore_bits = level * 9;
            let mask = (1u64 << ignore_bits) - 1;
            let aligned_ppn = ppn & !mask;
            let offset_mask = (1u64 << (12 + ignore_bits)) - 1;
            return Ok((aligned_ppn << 12) | (vaddr & offset_mask));
        }

        a = ppn << 12;
    }

    // Walked off the bottom without a leaf.
    Err(MmuError::PageFault)
}
