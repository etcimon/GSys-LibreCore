// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! ZealOS-shaped filesystem exploration.
//!
//! ZealOS addresses storage as named drives (`C:/Home`), not as one mounted
//! tree, and that maps cleanly onto what a BIOS actually has: a handful of
//! volumes that come and go. So a path is either BIOS-local (`/config`) or
//! `DRIVE:/path` on a volume the kernel lent through [`VolumePort`]. A drive
//! that is not there is a plain refusal — the CLI never invents a listing.

use crate::ports::{Entry, Ports, VolumeInfo};

/// Where a path points.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Location {
    /// The BIOS-local in-memory tree (`/config`, `/keys`, `/boot-policy`).
    Bios(String),
    /// A volume path (`KEY-FAT:/backup`) on a BoardSpec-modelled volume.
    Volume { volume: String, path: String },
    /// A path on a **real mounted filesystem** (`/mnt/root/etc`, `root:/etc`) —
    /// a partition this build actually read with a driver.
    Mount { name: String, path: String },
}

impl Location {
    /// Parse a CLI argument against a current location.
    ///
    /// `is_mount` decides the ambiguity between a modelled volume name and a real
    /// mount name for the `NAME:/path` spelling; `/mnt/<name>/…` is unambiguous.
    pub fn resolve_with(cwd: &Location, arg: &str, is_mount: &dyn Fn(&str) -> bool) -> Self {
        let arg = arg.trim();
        // `/mnt/<name>[/path]` is always a real mount.
        if let Some(rest) = arg.strip_prefix(crate::mounts::MNT) {
            if rest.is_empty() || rest.starts_with('/') {
                let parts: Vec<&str> = rest.split('/').filter(|s| !s.is_empty()).collect();
                return match parts.split_first() {
                    None => Self::Bios(crate::mounts::MNT.to_string()),
                    Some((name, tail)) => Self::Mount {
                        name: name.to_ascii_lowercase(),
                        path: normalize(&tail.join("/")),
                    },
                };
            }
        }
        if let Some((vol, rest)) = split_drive(arg) {
            let path = normalize(if rest.is_empty() { "/" } else { rest });
            return if is_mount(&vol.to_ascii_lowercase()) {
                Self::Mount {
                    name: vol.to_ascii_lowercase(),
                    path,
                }
            } else {
                Self::Volume {
                    volume: vol.to_string(),
                    path,
                }
            };
        }
        if arg.is_empty() {
            return cwd.clone();
        }
        match cwd {
            Self::Bios(dir) => Self::Bios(join(dir, arg)),
            Self::Volume { volume, path } => Self::Volume {
                volume: volume.clone(),
                path: join(path, arg),
            },
            Self::Mount { name, path } => Self::Mount {
                name: name.clone(),
                path: join(path, arg),
            },
        }
    }

    /// [`resolve_with`](Self::resolve_with) with no mount table — the modelled
    /// volumes only.
    pub fn resolve(cwd: &Location, arg: &str) -> Self {
        Self::resolve_with(cwd, arg, &|_| false)
    }

    /// `KEY-FAT:/backup`, `/mnt/root/etc` or `/config` — what the prompt shows.
    pub fn display(&self) -> String {
        match self {
            Self::Bios(p) => p.clone(),
            Self::Volume { volume, path } => format!("{volume}:{path}"),
            Self::Mount { name, path } => {
                let tail = if path == "/" { "" } else { path.as_str() };
                format!("{}/{name}{tail}", crate::mounts::MNT)
            }
        }
    }

    pub fn path(&self) -> &str {
        match self {
            Self::Bios(p) => p,
            Self::Volume { path, .. } => path,
            Self::Mount { path, .. } => path,
        }
    }

    /// One level up. A volume or mount root goes back to the BIOS tree, the way
    /// ejecting a drive does.
    pub fn parent(&self) -> Self {
        match self {
            Self::Bios(p) => Self::Bios(parent_of(p)),
            Self::Volume { volume, path } if path != "/" => Self::Volume {
                volume: volume.clone(),
                path: parent_of(path),
            },
            Self::Mount { name, path } if path != "/" => Self::Mount {
                name: name.clone(),
                path: parent_of(path),
            },
            Self::Volume { .. } | Self::Mount { .. } => Self::Bios("/".into()),
        }
    }
}

fn split_drive(arg: &str) -> Option<(&str, &str)> {
    let (head, rest) = arg.split_once(':')?;
    let ok = !head.is_empty()
        && head
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    ok.then_some((head, rest))
}

fn join(dir: &str, arg: &str) -> String {
    if arg.starts_with('/') {
        normalize(arg)
    } else if dir == "/" {
        normalize(&format!("/{arg}"))
    } else {
        normalize(&format!("{dir}/{arg}"))
    }
}

/// Collapse `.`/`..` and duplicate separators. Never escapes the root.
pub fn normalize(p: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    for part in p.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            s => out.push(s),
        }
    }
    if out.is_empty() {
        "/".into()
    } else {
        format!("/{}", out.join("/"))
    }
}

/// Parent directory of a path.
pub fn parent_of(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rsplit_once('/') {
        Some(("", _)) | None => "/".into(),
        Some((p, _)) => p.to_string(),
    }
}

/// `Drv` — the volumes actually present.
pub fn drives(ports: &Ports) -> Vec<VolumeInfo> {
    ports
        .volumes
        .as_ref()
        .map(|v| v.volumes())
        .unwrap_or_default()
}

/// Read-only disk rows for the Devices page. Size is omitted: a volume port
/// does not report capacity. Bootable means a loader file was listed, not guessed.
pub fn disk_json(ports: &Ports) -> String {
    let mut body = String::from("{\"disks\":[");
    for (i, v) in drives(ports).iter().enumerate() {
        if i > 0 {
            body.push(',');
        }
        let proof = boot_proof(ports, &v.id);
        body.push_str("{\"name\":");
        body.push_str(&g6b_spec::quote_json(&v.id));
        body.push_str(",\"fs\":");
        body.push_str(&g6b_spec::quote_json(&v.fs));
        body.push_str(",\"size\":\"\",\"bootable\":");
        body.push_str(if proof.is_some() { "true" } else { "false" });
        body.push_str(",\"proof\":");
        body.push_str(&g6b_spec::quote_json(
            proof.as_deref().unwrap_or("no loader read"),
        ));
        body.push('}');
    }
    body.push_str("]}");
    body
}

fn boot_proof(ports: &Ports, id: &str) -> Option<String> {
    let vp = ports.volumes.as_ref()?;
    let ents = vp.list(id, "/EFI/BOOT").ok()?;
    let hit = ents
        .iter()
        .find(|e| !e.dir && e.name.eq_ignore_ascii_case("BOOTRISCV64.EFI"))?;
    Some(format!("/EFI/BOOT/{} {}B", hit.name, hit.size))
}

/// `Drv` listing as text, ZealOS-shaped (`DRIVE:  fs  role`).
pub fn drives_text(ports: &Ports) -> String {
    let vols = drives(ports);
    if vols.is_empty() {
        return "no volumes (kernel.usb / kernel.cli.fs not compiled, or no key inserted)\n".into();
    }
    let mut s = String::from("drive     fs      role\n");
    for v in vols {
        s.push_str(&format!(
            "{:<9} {:<7} {}\n",
            format!("{}:", v.id),
            v.fs,
            v.role
        ));
    }
    s
}

/// One directory listing, formatted the way `Dir` prints it.
pub fn list_text(ports: &Ports, loc: &Location) -> Result<String, String> {
    let Location::Volume { volume, path } = loc else {
        return Err("Dir: not a volume path".into());
    };
    let vp = ports
        .volumes
        .as_ref()
        .ok_or("Dir: no volumes compiled (kernel.usb / kernel.cli.fs)")?;
    let ents = vp.list(volume, path)?;
    Ok(ents_text(volume, path, &ents))
}

/// Format entries with a trailing header, so a listing is self-describing.
pub fn ents_text(volume: &str, path: &str, ents: &[Entry]) -> String {
    if ents.is_empty() {
        return format!("({volume}:{path} is empty)\n");
    }
    let mut s = format!("{volume}:{path}\n");
    for e in ents {
        if e.dir {
            s.push_str(&format!("  {:<28} <DIR>\n", e.name));
        } else {
            s.push_str(&format!("  {:<28} {:>10}\n", e.name, e.size));
        }
    }
    s.push_str(&format!(
        "  {} file(s), {} dir(s)\n",
        ents.iter().filter(|e| !e.dir).count(),
        ents.iter().filter(|e| e.dir).count()
    ));
    s
}

/// Read a volume file as text for `Type` / the read-only viewer. Binary bodies
/// are reported, not dumped as mojibake.
pub fn read_text(ports: &Ports, loc: &Location) -> Result<String, String> {
    let Location::Volume { volume, path } = loc else {
        return Err("Type: not a volume path".into());
    };
    let vp = ports
        .volumes
        .as_ref()
        .ok_or("Type: no volumes compiled (kernel.usb / kernel.cli.fs)")?;
    let bytes = vp.read(volume, path)?;
    match String::from_utf8(bytes.clone()) {
        // Text is UTF-8 without control characters other than the layout ones.
        // A firmware image passes the UTF-8 test often enough that "valid
        // UTF-8" alone would print an image as mojibake.
        Ok(s)
            if !s
                .chars()
                .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t')) =>
        {
            Ok(s)
        }
        _ => Err(format!(
            "{volume}:{path} is binary ({} bytes, {}); use `fw update {volume}:{path}` for images",
            bytes.len(),
            crate::fw::image_kind(&bytes)
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::MemVolumes;

    fn ports() -> Ports {
        Ports::default().with_volumes(
            MemVolumes::new()
                .volume("KEY-FAT", "fat32", "key")
                .volume("FLASH", "fat32", "flash")
                .file("KEY-FAT", "/settings.json", b"{}".to_vec())
                .file("KEY-FAT", "/backup/settings.bak", b"{\"a\":1}".to_vec())
                .file("FLASH", "/g6lc_bios.elf", b"\x7fELFxx".to_vec()),
        )
    }

    #[test]
    fn drives_are_zeal_shaped_and_absent_is_a_refusal() {
        let p = ports();
        let t = drives_text(&p);
        assert!(t.contains("KEY-FAT:"), "{t}");
        assert!(t.contains("FLASH:"), "{t}");
        let bare = Ports::default();
        assert!(drives_text(&bare).contains("no volumes"));
        assert!(list_text(
            &bare,
            &Location::Volume {
                volume: "KEY-FAT".into(),
                path: "/".into()
            }
        )
        .is_err());
    }

    #[test]
    fn disk_json_names_the_loader_it_actually_listed() {
        let p = Ports::default().with_volumes(
            MemVolumes::new()
                .volume("KEY-FAT", "fat32", "key")
                .volume("DATA", "ext4", "key")
                .file("KEY-FAT", "/EFI/BOOT/BOOTRISCV64.EFI", vec![0; 64])
                .file("DATA", "/etc/os-release", b"NAME=x\n".to_vec()),
        );
        let json = disk_json(&p);
        assert!(json.contains("\"name\":\"KEY-FAT\""));
        assert!(json.contains("\"fs\":\"fat32\""));
        assert!(json.contains("\"bootable\":true"));
        assert!(json.contains("BOOTRISCV64.EFI 64B"), "{json}");
        assert!(json.contains("\"name\":\"DATA\""));
        assert!(json.contains("\"bootable\":false"));
        assert!(json.contains("no loader read"));
        assert!(json.contains("\"size\":\"\""));
    }

    #[test]
    fn paths_switch_between_the_bios_tree_and_a_drive() {
        let cwd = Location::Bios("/".into());
        let key = Location::resolve(&cwd, "KEY-FAT:/backup");
        assert_eq!(key.display(), "KEY-FAT:/backup");
        // Relative moves stay on the drive.
        let up = Location::resolve(&key, "..");
        assert_eq!(up.display(), "KEY-FAT:/");
        assert_eq!(key.parent().display(), "KEY-FAT:/");
        // …and leaving the drive root returns to the BIOS tree.
        assert_eq!(
            Location::Volume {
                volume: "KEY-FAT".into(),
                path: "/".into()
            }
            .parent(),
            Location::Bios("/".into())
        );
        assert_eq!(Location::resolve(&key, "/keys").display(), "KEY-FAT:/keys");
        assert_eq!(Location::resolve(&cwd, "config").display(), "/config");
        assert_eq!(normalize("/a/../b//c/."), "/b/c");
        assert_eq!(normalize("/.."), "/");
    }

    #[test]
    fn listing_and_reading_a_key() {
        let p = ports();
        let root = Location::resolve(&Location::Bios("/".into()), "KEY-FAT:/");
        let t = list_text(&p, &root).unwrap();
        assert!(t.contains("settings.json"), "{t}");
        assert!(t.contains("backup") && t.contains("<DIR>"), "{t}");
        assert!(t.contains("1 file(s), 1 dir(s)"), "{t}");
        let f = Location::resolve(&root, "settings.json");
        assert_eq!(read_text(&p, &f).unwrap(), "{}");
        // A firmware image is not text and says so.
        let img = Location::resolve(&Location::Bios("/".into()), "FLASH:/g6lc_bios.elf");
        let err = read_text(&p, &img).unwrap_err();
        assert!(err.contains("binary") && err.contains("elf"), "{err}");
        // A missing drive is an error, not an empty listing.
        let ghost = Location::resolve(&Location::Bios("/".into()), "NOPE:/");
        assert!(list_text(&p, &ghost).is_err());
    }
}
