// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Model-driven page-table walk for the native VM.
//!
//! The walk is parameterised by the MMU geometry in [`Mmu`]: SATP mode value,
//! virtual/physical address widths, page-table levels, and bits per VPN level. This
//! keeps the B3 native VM honest to the model instead of hard-coding Sv39.

use crate::mem::PhysMem;

/// Why a translation walk failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MmuError {
    /// SATP mode is 0 (bare), so no translation was performed.
    Bare,
    /// SATP mode is not supported by this MMU geometry.
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

/// MMU geometry: the page-table walk parameters derived from the model.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Mmu {
    /// SATP mode field for this scheme (0 = bare, 1 = sv32, 8 = sv39, 9 = sv48).
    pub satp_mode: u64,
    /// Virtual address width in bits.
    pub vaddr_bits: u8,
    /// Physical address width in bits.
    pub paddr_bits: u8,
    /// Page-table levels.
    pub levels: u8,
    /// Bits per VPN level.
    pub vpn_bits: u8,
    /// Page offset bits (always 12 for the base RISC-V schemes).
    pub page_bits: u8,
    /// PTE size in bytes: 4 for XLEN=32 (Sv32), 8 for XLEN=64 (Sv39/Sv48).
    pub pte_bytes: u8,
}

impl Default for Mmu {
    /// Default to bare translation (no MMU).
    fn default() -> Self {
        Self {
            satp_mode: 0,
            vaddr_bits: 0,
            paddr_bits: 0,
            levels: 0,
            vpn_bits: 0,
            page_bits: 12,
            pte_bytes: 4,
        }
    }
}

impl Mmu {
    /// Build an MMU from the model's `Isa` fields.
    pub fn from_isa(isa: &g6q_core::model::Isa) -> Self {
        if isa.page_table_levels == 0 {
            Self::default()
        } else {
            Self {
                satp_mode: isa.satp_mode as u64,
                vaddr_bits: isa.vaddr_bits,
                paddr_bits: isa.paddr_bits,
                levels: isa.page_table_levels,
                vpn_bits: isa.vpn_bits,
                page_bits: 12,
                pte_bytes: if isa.xlen == 32 { 4 } else { 8 },
            }
        }
    }

    /// A 64-bit Sv39 MMU, useful for tests that do not want to build a model.
    pub fn sv39() -> Self {
        Self {
            satp_mode: 8,
            vaddr_bits: 39,
            paddr_bits: 56,
            levels: 3,
            vpn_bits: 9,
            page_bits: 12,
            pte_bytes: 8,
        }
    }

    /// A 64-bit Sv48 MMU.
    pub fn sv48() -> Self {
        Self {
            satp_mode: 9,
            vaddr_bits: 48,
            paddr_bits: 56,
            levels: 4,
            vpn_bits: 9,
            page_bits: 12,
            pte_bytes: 8,
        }
    }

    /// A 32-bit Sv32 MMU.
    pub fn sv32() -> Self {
        Self {
            satp_mode: 1,
            vaddr_bits: 32,
            paddr_bits: 34,
            levels: 2,
            vpn_bits: 10,
            page_bits: 12,
            pte_bytes: 4,
        }
    }

    /// Whether the address is canonical for this mode.
    fn canonical(&self, vaddr: u64) -> bool {
        if self.vaddr_bits == 0 {
            return true;
        }
        let sign = (vaddr >> (self.vaddr_bits - 1)) & 1;
        let high = vaddr >> self.vaddr_bits;
        if sign != 0 {
            high == !0u64
        } else {
            high == 0
        }
    }
}

/// Translate `vaddr` through a page table described by `mmu` and `satp`.
///
/// If `satp` mode is `0` (bare) this immediately returns the virtual address.
/// Otherwise the mode must match `mmu.satp_mode`; the function then walks the
/// configured number of levels with the configured `vpn_bits` and `page_bits`.
///
/// The implementation is valid for Sv32, Sv39, and Sv48; larger page sizes are
/// supported when a valid leaf PTE is found at an inner level.
pub fn translate(mem: &PhysMem, mmu: &Mmu, satp: u64, vaddr: u64) -> Result<u64, MmuError> {
    // RV32 satp has a single mode bit at bit 31 and a 22-bit PPN;
    // RV64 satp has a 4-bit mode at bits 63:60 and a 44-bit PPN.
    let (mode, ppn_mask) = if mmu.vaddr_bits <= 32 {
        (satp >> 31, (1u64 << 22) - 1)
    } else {
        (satp >> 60, (1u64 << 44) - 1)
    };
    if mode == 0 {
        return Ok(vaddr);
    }
    if mode != mmu.satp_mode {
        return Err(MmuError::Unsupported);
    }
    if mmu.levels == 0 || mmu.vpn_bits == 0 {
        return Err(MmuError::Unsupported);
    }
    if !mmu.canonical(vaddr) {
        return Err(MmuError::BadVaddr);
    }

    let mut a = (satp & ppn_mask) << 12;

    for level in (0..mmu.levels).rev() {
        let vpn =
            ((vaddr >> mmu.page_bits) >> (level * mmu.vpn_bits)) & ((1u64 << mmu.vpn_bits) - 1);
        let pte_addr = a + (vpn * mmu.pte_bytes as u64);
        let pte = match mmu.pte_bytes {
            4 => match mem.read_le::<4>(pte_addr) {
                Ok(v) => v,
                Err(_) => return Err(MmuError::Access),
            },
            8 => match mem.read_le::<8>(pte_addr) {
                Ok(v) => v,
                Err(_) => return Err(MmuError::Access),
            },
            _ => return Err(MmuError::Unsupported),
        };

        let v = pte & 1 != 0;
        let r = (pte >> 1) & 1 != 0;
        let w = (pte >> 2) & 1 != 0;
        let x = (pte >> 3) & 1 != 0;
        let ppn = (pte >> 10) & ((1u64 << 44) - 1);

        if !v || (!r && w) {
            return Err(MmuError::PageFault);
        }

        if r || w || x {
            // Leaf PTE: the PPN is aligned to the page size at this level.
            let ignore_bits = level * mmu.vpn_bits;
            let mask = (1u64 << ignore_bits) - 1;
            let aligned_ppn = ppn & !mask;
            let offset_mask = (1u64 << (mmu.page_bits + ignore_bits)) - 1;
            let paddr = (aligned_ppn << mmu.page_bits) | (vaddr & offset_mask);
            // Mask to the physical address width.
            let paddr_mask = if mmu.paddr_bits == 0 || mmu.paddr_bits >= 64 {
                !0u64
            } else {
                (1u64 << mmu.paddr_bits) - 1
            };
            return Ok(paddr & paddr_mask);
        }

        a = ppn << mmu.page_bits;
    }

    // Walked off the bottom without a leaf.
    Err(MmuError::PageFault)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mem::{PhysMem, Region};

    fn sv39_pte(ppn: u64, flags: u64) -> u64 {
        (ppn << 10) | flags
    }

    fn sv32_pte(ppn: u64, flags: u64) -> u64 {
        (ppn << 10) | flags
    }

    fn sv48_pte(ppn: u64, flags: u64) -> u64 {
        (ppn << 10) | flags
    }

    #[test]
    fn bare_mode_returns_virtual_address() {
        let m = Mmu::default();
        let mem = PhysMem::new();
        assert_eq!(translate(&mem, &m, 0, 0x1234).unwrap(), 0x1234);
    }

    #[test]
    fn sv39_one_gigabyte_page_maps_vaddr_to_paddr() {
        let m = Mmu::sv39();
        let mut mem = PhysMem::new();
        // Page table at 0x9000_0000. PTE 0 maps VPN 0 -> a 1 GiB leaf at paddr 0x8000_0000.
        let ppn = 0x8000_0000u64 >> 12; // 0x80000
        let pte = sv39_pte(ppn, 0xF);
        let pt_base = 0x9000_0000u64;
        let pt_ppn = pt_base >> 12;
        mem.add(Region::new(pt_base, 0x1000));
        mem.write_le::<8>(pt_base, pte).unwrap();

        let satp = (8u64 << 60) | pt_ppn;
        let vaddr = 0x0u64; // VPN0 = 0, offset 0
        assert_eq!(translate(&mem, &m, satp, vaddr).unwrap(), 0x8000_0000);
    }

    #[test]
    fn non_canonical_address_is_rejected() {
        let m = Mmu::sv39();
        let mut mem = PhysMem::new();
        mem.add(Region::new(0x9000_0000, 0x1000));
        mem.write_le::<8>(0x9000_0000, sv39_pte(0x80000, 0xF))
            .unwrap();
        let satp = (8u64 << 60) | (0x9000_0000u64 >> 12);
        // bit 38 set but bits 39..63 not all ones
        assert!(matches!(
            translate(&mem, &m, satp, 0x4000_0000_0000_0000),
            Err(MmuError::BadVaddr)
        ));
    }

    #[test]
    fn mismatching_satp_mode_is_unsupported() {
        let m = Mmu::sv39();
        let mem = PhysMem::new();
        assert!(matches!(
            translate(&mem, &m, 9u64 << 60, 0),
            Err(MmuError::Unsupported)
        ));
    }

    #[test]
    fn sv32_four_kilobyte_page_maps_vaddr_to_paddr() {
        let m = Mmu::sv32();
        let mut mem = PhysMem::new();
        mem.add(Region::new(0x9000_0000, 0x2000));
        // Level-1 table at 0x9000_0000, level-0 table at 0x9000_1000.
        let pt_ppn = 0x9000_0000u64 >> 12;
        let l0_ppn = 0x9000_1000u64 >> 12;
        mem.write_le::<4>(0x9000_0000, sv32_pte(l0_ppn, 0x1))
            .unwrap();
        let ppn = 0x8000_0000u64 >> 12;
        mem.write_le::<4>(0x9000_1000, sv32_pte(ppn, 0xF)).unwrap();
        let satp = (1u64 << 31) | pt_ppn; // Sv32 satp is ppn in the low 22 bits.
        let vaddr = 0x0u64;
        assert_eq!(translate(&mem, &m, satp, vaddr).unwrap(), 0x8000_0000);
    }

    #[test]
    fn sv32_four_megabyte_leaf_maps_vaddr_to_paddr() {
        let m = Mmu::sv32();
        let mut mem = PhysMem::new();
        mem.add(Region::new(0x9000_0000, 0x1000));
        let pt_ppn = 0x9000_0000u64 >> 12;
        let ppn = 0x8000_0000u64 >> 12;
        // vaddr 0x1234 is inside the first 4 MiB megapage (VPN[1] == 0).
        mem.write_le::<4>(0x9000_0000, sv32_pte(ppn, 0xF)).unwrap();
        let satp = (1u64 << 31) | pt_ppn;
        let vaddr = 0x1234u64;
        assert_eq!(
            translate(&mem, &m, satp, vaddr).unwrap(),
            0x8000_0000 + 0x1234
        );
    }

    #[test]
    fn sv39_two_megabyte_leaf_maps_vaddr_to_paddr() {
        let m = Mmu::sv39();
        let mut mem = PhysMem::new();
        mem.add(Region::new(0x9000_0000, 0x2000));
        // Root at 0x9000_0000, level-1 leaf table at 0x9000_1000.
        let pt_ppn = 0x9000_0000u64 >> 12;
        let l1_ppn = 0x9000_1000u64 >> 12;
        mem.write_le::<8>(0x9000_0000, sv39_pte(l1_ppn, 0x1))
            .unwrap();
        let ppn = 0x8000_0000u64 >> 12;
        mem.write_le::<8>(0x9000_1000, sv39_pte(ppn, 0xF)).unwrap();
        let satp = (8u64 << 60) | pt_ppn;
        let vaddr = 0x0u64;
        assert_eq!(translate(&mem, &m, satp, vaddr).unwrap(), 0x8000_0000);
    }

    #[test]
    fn sv48_four_kilobyte_page_maps_vaddr_to_paddr() {
        let m = Mmu::sv48();
        let mut mem = PhysMem::new();
        mem.add(Region::new(0x9000_0000, 0x4000));
        // Root -> l2 -> l1 -> l0, then a 4 KiB leaf.
        let pt_ppn = 0x9000_0000u64 >> 12;
        let l2_ppn = 0x9000_1000u64 >> 12;
        let l1_ppn = 0x9000_2000u64 >> 12;
        let l0_ppn = 0x9000_3000u64 >> 12;
        mem.write_le::<8>(0x9000_0000, sv48_pte(l2_ppn, 0x1))
            .unwrap();
        mem.write_le::<8>(0x9000_1000, sv48_pte(l1_ppn, 0x1))
            .unwrap();
        mem.write_le::<8>(0x9000_2000, sv48_pte(l0_ppn, 0x1))
            .unwrap();
        let ppn = 0x8000_0000u64 >> 12;
        mem.write_le::<8>(0x9000_3000, sv48_pte(ppn, 0xF)).unwrap();
        let satp = (9u64 << 60) | pt_ppn;
        let vaddr = 0x0u64;
        assert_eq!(translate(&mem, &m, satp, vaddr).unwrap(), 0x8000_0000);
    }

    #[test]
    fn sv48_one_gigabyte_leaf_maps_vaddr_to_paddr() {
        let m = Mmu::sv48();
        let mut mem = PhysMem::new();
        mem.add(Region::new(0x9000_0000, 0x2000));
        // Root -> l2, then a 1 GiB leaf.
        let pt_ppn = 0x9000_0000u64 >> 12;
        let l2_ppn = 0x9000_1000u64 >> 12;
        mem.write_le::<8>(0x9000_0000, sv48_pte(l2_ppn, 0x1))
            .unwrap();
        let ppn = 0x8000_0000u64 >> 12;
        mem.write_le::<8>(0x9000_1000, sv48_pte(ppn, 0xF)).unwrap();
        let satp = (9u64 << 60) | pt_ppn;
        let vaddr = 0x0u64;
        assert_eq!(translate(&mem, &m, satp, vaddr).unwrap(), 0x8000_0000);
    }

    #[test]
    fn sv48_two_megabyte_leaf_maps_vaddr_to_paddr() {
        let m = Mmu::sv48();
        let mut mem = PhysMem::new();
        mem.add(Region::new(0x9000_0000, 0x3000));
        // Root -> l2 -> l1 leaf.
        let pt_ppn = 0x9000_0000u64 >> 12;
        let l2_ppn = 0x9000_1000u64 >> 12;
        let l1_ppn = 0x9000_2000u64 >> 12;
        mem.write_le::<8>(0x9000_0000, sv48_pte(l2_ppn, 0x1))
            .unwrap();
        mem.write_le::<8>(0x9000_1000, sv48_pte(l1_ppn, 0x1))
            .unwrap();
        let ppn = 0x8000_0000u64 >> 12;
        mem.write_le::<8>(0x9000_2000, sv48_pte(ppn, 0xF)).unwrap();
        let satp = (9u64 << 60) | pt_ppn;
        let vaddr = 0x1234u64;
        assert_eq!(
            translate(&mem, &m, satp, vaddr).unwrap(),
            0x8000_0000 + 0x1234
        );
    }

    #[test]
    fn sv48_non_canonical_address_is_rejected() {
        let m = Mmu::sv48();
        let mut mem = PhysMem::new();
        mem.add(Region::new(0x9000_0000, 0x1000));
        mem.write_le::<8>(0x9000_0000, sv48_pte(0x80000, 0xF))
            .unwrap();
        let satp = (9u64 << 60) | (0x9000_0000u64 >> 12);
        // bit 47 set but bits 48..63 not all ones
        assert!(matches!(
            translate(&mem, &m, satp, 0x0000_8000_0000_0000),
            Err(MmuError::BadVaddr)
        ));
    }
}
