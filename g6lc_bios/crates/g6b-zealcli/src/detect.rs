// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! What is on a volume, and what proved it.
//!
//! A boot menu that guesses is worse than no boot menu: the operator acts on it.
//! So every entry this module produces names its **evidence** — the file or the
//! header field that identified the medium — and anything unrecognized stays
//! `Unknown` instead of being labelled hopefully.
//!
//! The probes are the real on-disk contracts:
//!
//! * **RISC-V Linux Image** — `arch/riscv/include/asm/image.h`: `magic =
//!   "RISCV\0\0\0"` at 0x30 and `magic2 = "RSC\x05"` at 0x38, with `image_size`
//!   at 0x10 and the version at 0x20. An `MZ`/`PE` prefix is the EFI stub.
//! * **ISO 9660** — a primary volume descriptor at 0x8000: type 1, `CD001`,
//!   version 1, with the 32-byte volume identifier at 0x8028. El Torito is the
//!   boot record at 0x8800 whose identifier is `EL TORITO SPECIFICATION`.
//! * **Ubuntu / Debian live** — `casper/vmlinuz` (Ubuntu) or `live/vmlinuz`
//!   (Debian), with the release string in `.disk/info`.
//! * **OpenWrt** — an `openwrt-*.manifest` package list, or `etc/openwrt_release`
//!   on an extracted root.
//! * **UEFI / U-Boot** — `EFI/BOOT/BOOTRISCV64.EFI`, `u-boot.itb`, `*.itb`.

use crate::ports::{Entry, Ports, VolumePort};

/// What kind of medium a volume holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Medium {
    /// A live system that runs from the medium (recovery duty).
    Live,
    /// An installer image — an ISO with a boot record, or an installer tree.
    Installer,
    /// An installed, bootable OS.
    Os,
    /// A router/appliance firmware image (OpenWrt and friends).
    Firmware,
    /// A loader the BIOS can hand off to (UEFI application, FIT).
    Loader,
    /// A kernel image the BIOS could load once it has a block reader.
    Kernel,
    /// Nothing recognized.
    Unknown,
}

impl Medium {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Live => "live",
            Self::Installer => "installer",
            Self::Os => "os",
            Self::Firmware => "firmware",
            Self::Loader => "loader",
            Self::Kernel => "kernel",
            Self::Unknown => "unknown",
        }
    }

    /// Recovery duty: a live system or an installer is what you reach for when
    /// the installed OS is the thing that is broken.
    pub fn is_recovery(self) -> bool {
        matches!(self, Self::Live | Self::Installer)
    }

    /// Something the board could actually run.
    pub fn is_bootable(self) -> bool {
        !matches!(self, Self::Unknown)
    }
}

/// One identified medium.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    pub medium: Medium,
    /// Operator-facing name (`OpenWrt`, `Ubuntu 24.04 live`, an ISO label).
    pub name: String,
    /// The file or header field that proved it.
    pub evidence: String,
    /// Path the loader/kernel would be taken from, when there is one.
    pub path: String,
}

impl Found {
    fn new(medium: Medium, name: &str, evidence: &str, path: &str) -> Self {
        Self {
            medium,
            name: name.to_string(),
            evidence: evidence.to_string(),
            path: path.to_string(),
        }
    }

    pub fn unknown() -> Self {
        Self::new(Medium::Unknown, "unknown", "no known marker", "")
    }
}

/// ISO 9660 primary volume descriptor: 2048-byte sectors, PVD at sector 16.
/// The El Torito boot record is the next sector, so one 4 KiB window covers both.
const ISO_PVD_OFF: u64 = 16 * 2048;

/// Identify an ISO image from its primary volume descriptor.
///
/// `head` must start at [`ISO_PVD_OFF`]. Returns the volume label and whether a
/// boot record is present (`bytes` may include the boot-record sector).
pub fn iso9660(bytes: &[u8]) -> Option<(String, bool)> {
    // type 1 (primary), "CD001", version 1.
    if bytes.len() < 2048 || bytes[0] != 1 || &bytes[1..6] != b"CD001" || bytes[6] != 1 {
        return None;
    }
    let label = String::from_utf8_lossy(&bytes[40..72])
        .trim()
        .trim_end_matches('\0')
        .trim()
        .to_string();
    let bootable = bytes.len() >= 4096
        && bytes[2048] == 0
        && &bytes[2049..2054] == b"CD001"
        && String::from_utf8_lossy(&bytes[2055..2096]).contains("EL TORITO");
    Some((label, bootable))
}

/// RISC-V Linux `Image` header fields, when the magic is there.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LinuxImage {
    pub size: u64,
    pub version: u32,
    /// `MZ` + `PE\0\0`: the kernel is also a UEFI application.
    pub efi_stub: bool,
}

/// Parse a RISC-V Linux Image header (`arch/riscv/include/asm/image.h`).
pub fn linux_image(head: &[u8]) -> Option<LinuxImage> {
    if head.len() < 0x40 {
        return None;
    }
    // `magic2` is the current field; `magic` is the deprecated one still written
    // by the kernels this BIOS meets. Either is proof enough, both is better.
    let magic = &head[0x30..0x38] == b"RISCV\0\0\0";
    let magic2 = &head[0x38..0x3c] == b"RSC\x05";
    if !(magic || magic2) {
        return None;
    }
    let size = u64::from_le_bytes(head[0x10..0x18].try_into().ok()?);
    let version = u32::from_le_bytes(head[0x20..0x24].try_into().ok()?);
    let efi_stub = head.starts_with(b"MZ") && head.len() >= 0x44 && head[0x40..0x44] == *b"PE\0\0";
    Some(LinuxImage {
        size,
        version,
        efi_stub,
    })
}

/// Extract `PRETTY_NAME` (or `NAME`) from an os-release-style file.
fn os_pretty_name(body: &str) -> String {
    for key in ["PRETTY_NAME", "NAME"] {
        if let Some(v) = body.lines().find(|l| l.starts_with(key)).and_then(|l| {
            l.split_once('=')
                .map(|(_, v)| v.trim().trim_matches('"').to_string())
        }) {
            if !v.is_empty() {
                return v;
            }
        }
    }
    "Linux".to_string()
}

/// Probe one volume. `port` is the kernel's volume reader.
pub fn probe(ports: &Ports, volume: &str) -> Found {
    let Some(vp) = ports.volumes.as_ref() else {
        return Found::unknown();
    };
    probe_port(vp.as_ref(), volume)
}

/// [`probe`] against a port directly (the kernel's own probe path).
pub fn probe_port(vp: &dyn VolumePort, volume: &str) -> Found {
    let root = vp.list(volume, "/").unwrap_or_default();
    // A volume that *is* an ISO: the port hands the image out as one file, or
    // the volume itself reads as ISO 9660 at sector 16.
    if let Some(found) = iso_on(vp, volume, "/", &root) {
        return found;
    }
    // Live media.
    for (dir, kernel, distro) in [
        ("/casper", "vmlinuz", "Ubuntu"),
        ("/live", "vmlinuz", "Debian"),
    ] {
        if has_file(vp, volume, dir, kernel) {
            let name = disk_info(vp, volume).unwrap_or_else(|| format!("{distro} live"));
            return Found::new(
                Medium::Live,
                &name,
                &format!("{dir}/{kernel}"),
                &format!("{dir}/{kernel}"),
            );
        }
    }
    // OpenWrt: the package manifest names the build, so read it when present.
    if let Some(manifest) = root
        .iter()
        .find(|e| !e.dir && e.name.starts_with("openwrt-") && e.name.ends_with(".manifest"))
    {
        let name = openwrt_name(vp, volume, &manifest.name);
        return Found::new(Medium::Firmware, &name, &manifest.name, "/");
    }
    if has_file(vp, volume, "/etc", "openwrt_release") {
        return Found::new(
            Medium::Os,
            "OpenWrt",
            "/etc/openwrt_release",
            "/boot/vmlinuz",
        );
    }
    // Installed Linux: /etc/os-release names the distribution. `has_file` checks
    // the directory, then read the file itself; `read_window` is not on the
    // VolumePort trait, so `read` is the portable call and os-release is small.
    for (dir, file) in [("/etc", "os-release"), ("/usr/lib", "os-release")] {
        if has_file(vp, volume, dir, file) {
            let path = format!("{dir}/{file}");
            if let Ok(body) = vp.read(volume, &path) {
                let name = os_pretty_name(&String::from_utf8_lossy(&body));
                if !name.is_empty() {
                    return Found::new(Medium::Os, &name, &path, "/boot");
                }
            }
        }
    }
    // A kernel image the BIOS could hand off to, identified by its header.
    for cand in root.iter().filter(|e| !e.dir) {
        let looks_like_kernel = cand.name == "Image"
            || cand.name.starts_with("Image")
            || cand.name.starts_with("vmlinuz")
            || cand.name.ends_with("-kernel.bin");
        if !looks_like_kernel {
            continue;
        }
        let head = vp
            .read_window(volume, &format!("/{}", cand.name), 0, 0x80)
            .unwrap_or_default();
        if let Some(img) = linux_image(&head) {
            let name = if has_openwrt_marker(&root) {
                "OpenWrt (Linux Image)".to_string()
            } else {
                format!("Linux Image v{}", img.version)
            };
            let ev = if img.efi_stub {
                format!("{} RISCV+RSC\u{5} header, EFI stub", cand.name)
            } else {
                format!("{} RISCV+RSC\u{5} header", cand.name)
            };
            return Found::new(Medium::Kernel, &name, &ev, &format!("/{}", cand.name));
        }
    }
    // Loaders.
    for (dir, file, name) in [
        ("/EFI/BOOT", "BOOTRISCV64.EFI", "UEFI loader"),
        ("/", "u-boot.itb", "U-Boot"),
        ("/boot", "u-boot.itb", "U-Boot"),
    ] {
        if has_file(vp, volume, dir, file) {
            let path = if dir == "/" {
                format!("/{file}")
            } else {
                format!("{dir}/{file}")
            };
            return Found::new(Medium::Loader, name, &path, &path);
        }
    }
    if let Some(itb) = root.iter().find(|e| !e.dir && e.name.ends_with(".itb")) {
        return Found::new(
            Medium::Loader,
            "FIT image",
            &itb.name,
            &format!("/{}", itb.name),
        );
    }
    // Installed systems.
    if has_file(vp, volume, "/boot/grub", "grub.cfg") {
        return Found::new(Medium::Os, "Linux (GRUB)", "/boot/grub/grub.cfg", "/boot");
    }
    if has_file(vp, volume, "/", "bootmgr") || has_dir(&root, "Windows") {
        return Found::new(Medium::Os, "Windows", "/bootmgr", "/");
    }
    Found::unknown()
}

/// An `*.iso` on the volume, or the volume itself read as ISO 9660.
fn iso_on(vp: &dyn VolumePort, volume: &str, dir: &str, ents: &[Entry]) -> Option<Found> {
    // The image as a file on a key: `ubuntu-24.04-live-server-riscv64.iso`.
    for e in ents.iter().filter(|e| !e.dir) {
        let is_iso = e.name.to_ascii_lowercase().ends_with(".iso");
        if !is_iso {
            continue;
        }
        let path = if dir == "/" {
            format!("/{}", e.name)
        } else {
            format!("{dir}/{}", e.name)
        };
        let head = vp
            .read_window(volume, &path, ISO_PVD_OFF, 4096)
            .unwrap_or_default();
        if let Some((label, bootable)) = iso9660(&head) {
            let name = if label.is_empty() {
                e.name.clone()
            } else {
                label
            };
            let medium = if bootable {
                Medium::Installer
            } else {
                Medium::Unknown
            };
            let ev = if bootable {
                format!("{} ISO 9660 PVD + El Torito", e.name)
            } else {
                format!("{} ISO 9660 PVD (no boot record)", e.name)
            };
            return Some(Found::new(medium, &name, &ev, &path));
        }
    }
    // The whole volume is the ISO (a CD-ROM the port exposes as `/`).
    let head = vp
        .read_window(volume, "/", ISO_PVD_OFF, 4096)
        .unwrap_or_default();
    let (label, bootable) = iso9660(&head)?;
    let name = if label.is_empty() {
        "install ISO".to_string()
    } else {
        label
    };
    Some(Found::new(
        if bootable {
            Medium::Installer
        } else {
            Medium::Unknown
        },
        &name,
        "ISO 9660 PVD at sector 16",
        "/",
    ))
}

fn has_openwrt_marker(root: &[Entry]) -> bool {
    root.iter()
        .any(|e| e.name.starts_with("openwrt-") || e.name == "openwrt")
}

fn has_file(vp: &dyn VolumePort, volume: &str, dir: &str, name: &str) -> bool {
    vp.list(volume, dir)
        .map(|ents| {
            ents.iter()
                .any(|e| !e.dir && e.name.eq_ignore_ascii_case(name))
        })
        .unwrap_or(false)
}

fn has_dir(ents: &[Entry], name: &str) -> bool {
    ents.iter()
        .any(|e| e.dir && e.name.eq_ignore_ascii_case(name))
}

/// Ubuntu/Debian put the release string in `.disk/info`.
fn disk_info(vp: &dyn VolumePort, volume: &str) -> Option<String> {
    let bytes = vp.read_window(volume, "/.disk/info", 0, 128).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    let line = text.lines().next()?.trim();
    if line.is_empty() {
        None
    } else {
        Some(line.chars().take(48).collect())
    }
}

/// The OpenWrt manifest is a package list; its `base-files` revision is the
/// closest thing to a build identity that is actually in the file.
fn openwrt_name(vp: &dyn VolumePort, volume: &str, manifest: &str) -> String {
    let target = manifest
        .trim_start_matches("openwrt-")
        .trim_end_matches(".manifest");
    let bytes = vp
        .read_window(volume, &format!("/{manifest}"), 0, 256)
        .unwrap_or_default();
    let text = String::from_utf8_lossy(&bytes);
    let base = text
        .lines()
        .find(|l| l.starts_with("base-files"))
        .and_then(|l| l.split_whitespace().last())
        .unwrap_or("");
    if base.is_empty() {
        format!("OpenWrt {target}")
    } else {
        format!("OpenWrt {target} ({base})")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::MemVolumes;

    /// A RISC-V Linux Image header the way a kernel writes it.
    fn riscv_image(size: u64, version: u32, efi: bool) -> Vec<u8> {
        let mut b = vec![0u8; 0x80];
        if efi {
            b[0..2].copy_from_slice(b"MZ");
            b[0x40..0x44].copy_from_slice(b"PE\0\0");
        }
        b[0x10..0x18].copy_from_slice(&size.to_le_bytes());
        b[0x20..0x24].copy_from_slice(&version.to_le_bytes());
        b[0x30..0x38].copy_from_slice(b"RISCV\0\0\0");
        b[0x38..0x3c].copy_from_slice(b"RSC\x05");
        b
    }

    /// An ISO 9660 image: PVD at sector 16, El Torito boot record after it.
    fn iso_image(label: &str, bootable: bool) -> Vec<u8> {
        let mut b = vec![0u8; 18 * 2048];
        let pvd = 16 * 2048;
        b[pvd] = 1;
        b[pvd + 1..pvd + 6].copy_from_slice(b"CD001");
        b[pvd + 6] = 1;
        let mut id = [b' '; 32];
        for (i, c) in label.bytes().take(32).enumerate() {
            id[i] = c;
        }
        b[pvd + 40..pvd + 72].copy_from_slice(&id);
        if bootable {
            let br = 17 * 2048;
            b[br] = 0;
            b[br + 1..br + 6].copy_from_slice(b"CD001");
            b[br + 6] = 1;
            let ident = b"EL TORITO SPECIFICATION";
            b[br + 7..br + 7 + ident.len()].copy_from_slice(ident);
        }
        b
    }

    #[test]
    fn linux_image_header_is_read_not_guessed() {
        let img = linux_image(&riscv_image(19_764_736, 2, true)).expect("magic");
        assert_eq!(img.size, 19_764_736);
        assert_eq!(img.version, 2);
        assert!(img.efi_stub);
        // No magic, no claim.
        assert!(linux_image(&[0u8; 0x80]).is_none());
        assert!(linux_image(b"MZ").is_none());
        // `magic2` alone is enough (the deprecated field may be zero).
        let mut only2 = vec![0u8; 0x80];
        only2[0x38..0x3c].copy_from_slice(b"RSC\x05");
        assert!(linux_image(&only2).is_some());
    }

    #[test]
    fn iso_pvd_gives_the_label_and_the_boot_record() {
        let img = iso_image("Ubuntu-Server 24.04.1 LTS riscv64", true);
        let (label, bootable) = iso9660(&img[16 * 2048..]).expect("pvd");
        // The volume identifier field is 32 bytes, so a longer label is cut by
        // the format — reading 33 characters back would mean we invented one.
        assert_eq!(label, "Ubuntu-Server 24.04.1 LTS riscv6");
        assert!(bootable, "El Torito boot record");
        let plain = iso_image("DATA", false);
        let (label, bootable) = iso9660(&plain[16 * 2048..]).unwrap();
        assert_eq!(label, "DATA");
        assert!(!bootable);
        assert!(iso9660(&[0u8; 2048]).is_none());
    }

    #[test]
    fn openwrt_is_identified_by_its_manifest_and_image() {
        let vols = MemVolumes::new()
            .volume("OPENWRT", "fat32", "key")
            .file(
                "OPENWRT",
                "/openwrt-sifiveu-generic-sifive_unleashed.manifest",
                b"base-files - 1~d9340319c6\nbusybox - 1.36.1-r2\n".to_vec(),
            )
            .file("OPENWRT", "/Image", riscv_image(19_764_736, 2, true));
        let f = probe_port(&vols, "OPENWRT");
        assert_eq!(f.medium, Medium::Firmware);
        assert!(f.name.starts_with("OpenWrt sifiveu"), "{f:?}");
        assert!(f.name.contains("1~d9340319c6"), "{f:?}");
        assert!(f.evidence.ends_with(".manifest"), "{f:?}");
        // Without the manifest the Image header still identifies the kernel.
        let only_image = MemVolumes::new().volume("KERNEL", "fat32", "key").file(
            "KERNEL",
            "/Image",
            riscv_image(1024, 2, true),
        );
        let k = probe_port(&only_image, "KERNEL");
        assert_eq!(k.medium, Medium::Kernel);
        assert!(k.evidence.contains("RISCV"), "{k:?}");
        assert!(k.evidence.contains("EFI stub"), "{k:?}");
        assert_eq!(k.path, "/Image");
    }

    #[test]
    fn install_iso_live_usb_loaders_and_unknown() {
        // An ISO sitting on a key.
        let key = MemVolumes::new().volume("KEY", "fat32", "key").file(
            "KEY",
            "/ubuntu-24.04-riscv64.iso",
            iso_image("UBUNTU 24_04", true),
        );
        let iso = probe_port(&key, "KEY");
        assert_eq!(iso.medium, Medium::Installer);
        assert_eq!(iso.name, "UBUNTU 24_04");
        assert!(iso.evidence.contains("El Torito"), "{iso:?}");
        // A live USB.
        let live = MemVolumes::new()
            .volume("LIVE", "fat32", "key")
            .file("LIVE", "/casper/vmlinuz", vec![0u8; 16])
            .file(
                "LIVE",
                "/.disk/info",
                b"Ubuntu 24.04.1 LTS riscv64 (20240901)\n".to_vec(),
            );
        let l = probe_port(&live, "LIVE");
        assert_eq!(l.medium, Medium::Live);
        assert!(l.name.starts_with("Ubuntu 24.04.1"), "{l:?}");
        assert_eq!(l.evidence, "/casper/vmlinuz");
        // A UEFI loader.
        let efi = MemVolumes::new().volume("ESP", "fat32", "key").file(
            "ESP",
            "/EFI/BOOT/BOOTRISCV64.EFI",
            vec![0u8; 32],
        );
        assert_eq!(probe_port(&efi, "ESP").medium, Medium::Loader);
        // Nothing recognized stays unknown.
        let junk = MemVolumes::new().volume("JUNK", "fat32", "key").file(
            "JUNK",
            "/notes.txt",
            b"hello".to_vec(),
        );
        let u = probe_port(&junk, "JUNK");
        assert_eq!(u.medium, Medium::Unknown);
        assert!(!u.medium.is_bootable());
        assert!(Medium::Live.is_recovery() && Medium::Installer.is_recovery());
        assert!(!Medium::Os.is_recovery());
    }

    #[test]
    fn os_release_names_an_installed_linux_and_shows_in_autoboot() {
        // A btrfs (or ext4) root with `/etc/os-release` is an installed OS; the
        // boot picker should name it from `PRETTY_NAME`.
        let root = MemVolumes::new()
            .volume("ROOT", "btrfs", "key")
            .file(
                "ROOT",
                "/etc/os-release",
                b"PRETTY_NAME=\"G6LC btrfs Linux\"\nID=g6lc\n".to_vec(),
            )
            .file("ROOT", "/boot/vmlinuz", riscv_image(1024, 2, false));
        let f = probe_port(&root, "ROOT");
        assert_eq!(f.medium, Medium::Os, "{f:?}");
        assert_eq!(f.name, "G6LC btrfs Linux", "{f:?}");
        assert_eq!(f.evidence, "/etc/os-release", "{f:?}");
        // Without PRETTY_NAME, NAME is the fallback.
        let name_only = MemVolumes::new().volume("ROOT2", "ext4", "key").file(
            "ROOT2",
            "/etc/os-release",
            b"NAME=\"G6LC Linux\"\n".to_vec(),
        );
        let f2 = probe_port(&name_only, "ROOT2");
        assert_eq!(f2.name, "G6LC Linux", "{f2:?}");
    }
}
