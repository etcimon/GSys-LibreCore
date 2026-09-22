// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Discover whether a file set is a loadable RISC-V Linux bundle.
//!
//! A squashfs/UBI/rootfs is not executable. The first supported jump target is
//! a validated RISC-V `Image` plus explicit initrd, FDT, root device and
//! bootargs. This module does not load or jump.

use core::fmt;

const FDT_MAGIC: [u8; 4] = [0xd0, 0x0d, 0xfe, 0xed];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    RiscvImage,
    Squashfs,
    Ubi,
    Fdt,
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ImageInfo {
    pub size: u64,
    pub version: u32,
    pub efi_stub: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refuse {
    MissingImage,
    TruncatedImage,
    SquashfsNotExecutable,
    UbiNotExecutable,
    MissingInitrd,
    MissingDtb,
    MissingRoot,
    MissingBootargs,
    DtbNotFdt,
}

impl fmt::Display for Refuse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::MissingImage => "no RISC-V Image header",
            Self::TruncatedImage => "Image size larger than the file",
            Self::SquashfsNotExecutable => "squashfs is a rootfs, not a kernel",
            Self::UbiNotExecutable => "UBI volume is not a kernel",
            Self::MissingInitrd => "initrd not supplied",
            Self::MissingDtb => "DTB not supplied",
            Self::MissingRoot => "root device not supplied",
            Self::MissingBootargs => "bootargs not supplied",
            Self::DtbNotFdt => "DTB is not an FDT",
        })
    }
}

pub struct Bundle<'a> {
    pub image: &'a [u8],
    pub initrd: Option<&'a [u8]>,
    pub dtb: Option<&'a [u8]>,
    pub root: Option<&'a str>,
    pub bootargs: Option<&'a str>,
}

pub fn classify(bytes: &[u8]) -> Kind {
    if linux_image(bytes).is_some() {
        Kind::RiscvImage
    } else if bytes.starts_with(b"hsqs") {
        Kind::Squashfs
    } else if bytes.starts_with(b"UBI#") {
        Kind::Ubi
    } else if bytes.starts_with(&FDT_MAGIC) {
        Kind::Fdt
    } else {
        Kind::Unknown
    }
}

/// RISC-V Linux `Image` (`arch/riscv/include/asm/image.h`).
pub fn linux_image(head: &[u8]) -> Option<ImageInfo> {
    if head.len() < 0x40 {
        return None;
    }
    let magic = &head[0x30..0x38] == b"RISCV\0\0\0";
    let magic2 = &head[0x38..0x3c] == b"RSC\x05";
    if !(magic || magic2) {
        return None;
    }
    Some(ImageInfo {
        size: u64::from_le_bytes(head[0x10..0x18].try_into().ok()?),
        version: u32::from_le_bytes(head[0x20..0x24].try_into().ok()?),
        efi_stub: head.starts_with(b"MZ") && head.len() >= 0x44 && head[0x40..0x44] == *b"PE\0\0",
    })
}

/// Accept only a complete RISC-V Image bundle. Does not load Linux.
pub fn validate(bundle: &Bundle<'_>) -> Result<ImageInfo, Refuse> {
    match classify(bundle.image) {
        Kind::Squashfs => return Err(Refuse::SquashfsNotExecutable),
        Kind::Ubi => return Err(Refuse::UbiNotExecutable),
        Kind::RiscvImage => {}
        Kind::Fdt | Kind::Unknown => return Err(Refuse::MissingImage),
    }
    let info = linux_image(bundle.image).ok_or(Refuse::MissingImage)?;
    if info.size == 0 || info.size > bundle.image.len() as u64 {
        return Err(Refuse::TruncatedImage);
    }
    if bundle.initrd.is_none() || bundle.initrd.is_some_and(|b| b.is_empty()) {
        return Err(Refuse::MissingInitrd);
    }
    match bundle.dtb {
        None | Some([]) => return Err(Refuse::MissingDtb),
        Some(dtb) if !dtb.starts_with(&FDT_MAGIC) => return Err(Refuse::DtbNotFdt),
        Some(_) => {}
    }
    if bundle.root.is_none_or(|s| s.is_empty()) {
        return Err(Refuse::MissingRoot);
    }
    if bundle.bootargs.is_none_or(|s| s.is_empty()) {
        return Err(Refuse::MissingBootargs);
    }
    Ok(info)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(size: u64) -> Vec<u8> {
        let mut b = vec![0u8; 0x80];
        b[0x10..0x18].copy_from_slice(&size.to_le_bytes());
        b[0x20..0x24].copy_from_slice(&2u32.to_le_bytes());
        b[0x30..0x38].copy_from_slice(b"RISCV\0\0\0");
        b[0x38..0x3c].copy_from_slice(b"RSC\x05");
        b
    }

    fn ok_bundle(img: &[u8]) -> Bundle<'_> {
        Bundle {
            image: img,
            initrd: Some(b"initrd"),
            dtb: Some(&[0xd0, 0x0d, 0xfe, 0xed, 0, 0, 0, 0]),
            root: Some("/dev/vda2"),
            bootargs: Some("console=ttyS0"),
        }
    }

    #[test]
    fn squashfs_and_ubi_are_not_kernels() {
        assert_eq!(classify(b"hsqs...."), Kind::Squashfs);
        assert_eq!(
            validate(&ok_bundle(b"hsqs....")),
            Err(Refuse::SquashfsNotExecutable)
        );
        assert_eq!(
            validate(&ok_bundle(b"UBI#....")),
            Err(Refuse::UbiNotExecutable)
        );
    }

    #[test]
    fn complete_riscv_image_bundle_is_accepted() {
        let img = image(0x80);
        let info = validate(&ok_bundle(&img)).unwrap();
        assert_eq!(info.size, 0x80);
        assert_eq!(info.version, 2);
    }

    #[test]
    fn truncated_and_missing_pieces_are_named() {
        let img = image(0x1000);
        assert_eq!(validate(&ok_bundle(&img)), Err(Refuse::TruncatedImage));
        let img = image(0x80);
        let mut b = ok_bundle(&img);
        b.initrd = None;
        assert_eq!(validate(&b), Err(Refuse::MissingInitrd));
        b = ok_bundle(&img);
        b.dtb = Some(b"not-fdt");
        assert_eq!(validate(&b), Err(Refuse::DtbNotFdt));
        b = ok_bundle(&img);
        b.root = Some("");
        assert_eq!(validate(&b), Err(Refuse::MissingRoot));
        b = ok_bundle(&img);
        b.bootargs = None;
        assert_eq!(validate(&b), Err(Refuse::MissingBootargs));
        assert_eq!(
            validate(&Bundle {
                image: &[0; 64],
                initrd: Some(b"x"),
                dtb: Some(&[0xd0, 0x0d, 0xfe, 0xed]),
                root: Some("/dev/vda2"),
                bootargs: Some("console=ttyS0"),
            }),
            Err(Refuse::MissingImage)
        );
    }
}
