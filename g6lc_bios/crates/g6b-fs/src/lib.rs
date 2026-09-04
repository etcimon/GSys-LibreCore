// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! USB volume listing for BIOS flash and the USB-key file manager.
//!
//! Flashing is **always FAT32** (firmware `.bin`/`.img`/`.elf`). The USB-key
//! file manager (when `kernel.usb.key`) also browses NTFS and ext4. Host tests
//! use a canned tree; this is not a Linux VFS and not a netdev.

#![allow(missing_docs)]

use g6b_spec::BoardSpec;

/// On-disk family the BIOS will mount on a USB MSC key / stick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FsKind {
    Fat32,
    Ntfs,
    Ext4,
}

impl FsKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Fat32 => "fat32",
            Self::Ntfs => "ntfs",
            Self::Ext4 => "ext4",
        }
    }

    pub fn parse(s: &str) -> Result<Self, String> {
        Ok(match s {
            "fat32" | "fat" | "vfat" => Self::Fat32,
            "ntfs" => Self::Ntfs,
            "ext4" | "ext3" | "ext2" => Self::Ext4,
            other => return Err(format!("unknown fs `{other}`; use fat32, ntfs, or ext4")),
        })
    }
}

/// One directory entry on a USB volume.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirEnt {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub fs: FsKind,
}

/// A mounted USB volume.
#[derive(Debug, Clone)]
pub struct Volume {
    pub label: String,
    pub fs: FsKind,
    /// `flash` (FAT32 firmware stick) or `key` (file manager).
    pub role: &'static str,
}

/// Volumes the compiled BoardSpec actually exposes.
pub fn volumes(spec: &BoardSpec) -> Vec<Volume> {
    let u = &spec.kernel.usb;
    let mut v = Vec::new();
    if !u.enable {
        return v;
    }
    if u.flash_fat32 {
        v.push(Volume {
            label: "FLASH".into(),
            fs: FsKind::Fat32,
            role: "flash",
        });
    }
    if u.key {
        if u.fs_fat32 {
            v.push(Volume {
                label: "KEY-FAT".into(),
                fs: FsKind::Fat32,
                role: "key",
            });
        }
        if u.fs_ntfs {
            v.push(Volume {
                label: "KEY-NTFS".into(),
                fs: FsKind::Ntfs,
                role: "key",
            });
        }
        if u.fs_ext4 {
            v.push(Volume {
                label: "KEY-EXT4".into(),
                fs: FsKind::Ext4,
                role: "key",
            });
        }
    }
    v
}

/// Firmware images on the FAT32 flash stick (not the key file manager).
pub fn flash_images(spec: &BoardSpec) -> Vec<DirEnt> {
    if !spec.kernel.usb.enable || !spec.kernel.usb.flash_fat32 {
        return Vec::new();
    }
    vec![
        DirEnt {
            name: "openwrt.bin".into(),
            is_dir: false,
            size: 8_388_608,
            fs: FsKind::Fat32,
        },
        DirEnt {
            name: "g6lc_bios.elf".into(),
            is_dir: false,
            size: 262_144,
            fs: FsKind::Fat32,
        },
        DirEnt {
            name: "linux.img".into(),
            is_dir: false,
            size: 16_777_216,
            fs: FsKind::Fat32,
        },
    ]
}

/// USB-key file manager listing. `fs` none ⇒ all enabled key filesystems.
pub fn list_key(spec: &BoardSpec, path: &str, fs: Option<FsKind>) -> Vec<DirEnt> {
    if !spec.kernel.usb.enable || !spec.kernel.usb.key {
        return Vec::new();
    }
    let path = if path.is_empty() { "/" } else { path };
    let allowed = |k: FsKind| match k {
        FsKind::Fat32 => spec.kernel.usb.fs_fat32,
        FsKind::Ntfs => spec.kernel.usb.fs_ntfs,
        FsKind::Ext4 => spec.kernel.usb.fs_ext4,
    };
    let kinds: Vec<FsKind> = match fs {
        Some(k) if allowed(k) => vec![k],
        Some(_) => Vec::new(),
        None => {
            let mut k = Vec::new();
            if spec.kernel.usb.fs_fat32 {
                k.push(FsKind::Fat32);
            }
            if spec.kernel.usb.fs_ntfs {
                k.push(FsKind::Ntfs);
            }
            if spec.kernel.usb.fs_ext4 {
                k.push(FsKind::Ext4);
            }
            k
        }
    };
    let mut out = Vec::new();
    for k in kinds {
        out.extend(canned_key(k, path));
    }
    out
}

fn canned_key(fs: FsKind, path: &str) -> Vec<DirEnt> {
    let p = path.trim_end_matches('/');
    let p = if p.is_empty() { "/" } else { p };
    match (fs, p) {
        (FsKind::Fat32, "/") => vec![
            DirEnt {
                name: "settings.json".into(),
                is_dir: false,
                size: 1024,
                fs,
            },
            DirEnt {
                name: "backup".into(),
                is_dir: true,
                size: 0,
                fs,
            },
        ],
        (FsKind::Fat32, "/backup") => vec![DirEnt {
            name: "settings.bak".into(),
            is_dir: false,
            size: 1024,
            fs,
        }],
        (FsKind::Ntfs, "/") => vec![
            DirEnt {
                name: "Windows".into(),
                is_dir: true,
                size: 0,
                fs,
            },
            DirEnt {
                name: "bios-settings.json".into(),
                is_dir: false,
                size: 2048,
                fs,
            },
        ],
        (FsKind::Ext4, "/") => vec![
            DirEnt {
                name: "home".into(),
                is_dir: true,
                size: 0,
                fs,
            },
            DirEnt {
                name: "etc".into(),
                is_dir: true,
                size: 0,
                fs,
            },
        ],
        (FsKind::Ext4, "/home") => vec![DirEnt {
            name: "config.json".into(),
            is_dir: false,
            size: 512,
            fs,
        }],
        _ => Vec::new(),
    }
}

fn ent_json(e: &DirEnt) -> String {
    format!(
        "{{\"name\":\"{}\",\"dir\":{},\"size\":{},\"fs\":\"{}\"}}",
        e.name,
        if e.is_dir { "true" } else { "false" },
        e.size,
        e.fs.as_str()
    )
}

/// JSON array of directory entries.
pub fn ents_json(ents: &[DirEnt]) -> String {
    let parts: Vec<String> = ents.iter().map(ent_json).collect();
    format!("[{}]", parts.join(","))
}

/// JSON array of volumes.
pub fn volumes_json(spec: &BoardSpec) -> String {
    let parts: Vec<String> = volumes(spec)
        .iter()
        .map(|v| {
            format!(
                "{{\"label\":\"{}\",\"fs\":\"{}\",\"role\":\"{}\"}}",
                v.label,
                v.fs.as_str(),
                v.role
            )
        })
        .collect();
    format!("[{}]", parts.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flash_fat32_always_on_default_usb() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1}"#).unwrap();
        assert!(spec.kernel.usb.enable && spec.kernel.usb.flash_fat32);
        let imgs = flash_images(&spec);
        assert!(imgs.iter().any(|e| e.name == "openwrt.bin"));
        assert!(imgs.iter().all(|e| e.fs == FsKind::Fat32));
    }

    #[test]
    fn key_manager_lists_ntfs_and_ext4() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        assert!(spec.kernel.usb.key && spec.kernel.usb.fs_ntfs && spec.kernel.usb.fs_ext4);
        let nt = list_key(&spec, "/", Some(FsKind::Ntfs));
        assert!(nt.iter().any(|e| e.name == "bios-settings.json"));
        let ex = list_key(&spec, "/home", Some(FsKind::Ext4));
        assert!(ex.iter().any(|e| e.name == "config.json"));
    }
}
