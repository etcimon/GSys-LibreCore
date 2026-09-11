// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `cd` into a real volume.
//!
//! Three path shapes reach the same place, because an operator arrives from three
//! habits:
//!
//! | shape | example |
//! |---|---|
//! | unix mount point | `cd /mnt/root/etc` |
//! | ZealOS drive | `cd root:/etc` |
//! | relative, once inside | `cd etc` · `cat fstab` |
//!
//! A name that is a **known but unmounted** volume is mounted on the spot, read-only
//! — walking into a directory should not require a ceremony, and read-only cannot
//! damage anything. Writing is the part that needs an explicit `mount -w`, and the
//! refusal says exactly that.

use crate::ports::{DriveInfo, Entry, MountInfo, Ports, VolumeSlot};

/// `/mnt` — where mounted volumes live in the unified path space.
pub const MNT: &str = "/mnt";

/// Where the shell currently is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Cwd {
    /// The BIOS-local in-memory tree.
    Bios(String),
    /// A mounted volume and a path inside it.
    Mount { name: String, path: String },
}

impl Cwd {
    /// What the prompt shows.
    pub fn display(&self) -> String {
        match self {
            Self::Bios(p) => format!("BIOS:{p}"),
            Self::Mount { name, path } => format!("{MNT}/{name}{}", trim_root(path)),
        }
    }
}

fn trim_root(path: &str) -> String {
    if path == "/" {
        String::new()
    } else {
        path.to_string()
    }
}

/// A parsed target: which mount (if any) and the path inside it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Bios(String),
    Mount { name: String, path: String },
}

/// Resolve `arg` against `cwd`, understanding all three path shapes.
///
/// Returns `None` when `arg` is empty.
pub fn resolve(cwd: &Cwd, arg: &str) -> Option<Target> {
    let arg = arg.trim();
    if arg.is_empty() {
        return None;
    }
    // `NAME:/path` — the ZealOS drive shape. `BIOS:` is the local tree.
    if let Some((drive, rest)) = arg.split_once(':') {
        let looks_like_drive = !drive.is_empty()
            && drive
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
        if looks_like_drive {
            let path = g6b_vfs::normalize(rest);
            return Some(if drive.eq_ignore_ascii_case("BIOS") {
                Target::Bios(path)
            } else {
                Target::Mount {
                    name: drive.to_ascii_lowercase(),
                    path,
                }
            });
        }
    }
    // `/mnt/<name>[/path]`.
    if let Some(rest) = arg.strip_prefix(MNT) {
        let parts = g6b_vfs::split_path(rest);
        return Some(match parts.split_first() {
            None => Target::Bios(MNT.to_string()),
            Some((name, tail)) => Target::Mount {
                name: name.to_ascii_lowercase(),
                path: g6b_vfs::normalize(&tail.join("/")),
            },
        });
    }
    // Absolute inside the current world.
    if arg.starts_with('/') {
        return Some(match cwd {
            Cwd::Bios(_) => Target::Bios(g6b_vfs::normalize(arg)),
            Cwd::Mount { name, .. } => Target::Mount {
                name: name.clone(),
                path: g6b_vfs::normalize(arg),
            },
        });
    }
    // Relative.
    Some(match cwd {
        Cwd::Bios(here) => Target::Bios(g6b_vfs::normalize(&format!("{here}/{arg}"))),
        Cwd::Mount { name, path } => Target::Mount {
            name: name.clone(),
            path: g6b_vfs::normalize(&format!("{path}/{arg}")),
        },
    })
}

/// Ensure `name` is mounted, mounting it read-only if it is a known volume.
///
/// The message is the audit trail: an operator must be able to see that the BIOS
/// mounted something, which volume it chose, and that it chose read-only.
pub fn ensure_mounted(
    ports: &mut Ports,
    name: &str,
) -> Result<(MountInfo, Option<String>), String> {
    let mp = ports
        .mounts
        .as_mut()
        .ok_or("no block reader in this build (kernel.cli.fs / a disk port)")?;
    if let Some(m) = mp.mounts().into_iter().find(|m| m.name == name) {
        return Ok((m, None));
    }
    // Not mounted: find a volume of that name on any drive.
    let mut candidates: Vec<VolumeSlot> = Vec::new();
    for d in mp.drives() {
        for v in mp.volumes(&d.id).unwrap_or_default() {
            if v.name == name {
                candidates.push(v);
            }
        }
    }
    let slot = candidates
        .into_iter()
        .find(|v| v.mountable)
        .ok_or_else(|| format!("no volume named `{name}` (try `drives`)"))?;
    let m = mp.mount(&slot.drive, slot.index, name, false)?;
    let note = format!(
        "mounted {} read-only from {}:{} ({}, label {}) — `mount -w {}` to write",
        m.name,
        slot.drive,
        slot.index,
        m.fs,
        if m.label.is_empty() { "-" } else { &m.label },
        m.name
    );
    Ok((m, Some(note)))
}

/// `drives` — every drive, its table, and every volume on it with what it holds.
pub fn drives_table(ports: &mut Ports) -> String {
    let Some(mp) = ports.mounts.as_mut() else {
        return "drives: no block reader in this build\n".to_string();
    };
    let drives: Vec<DriveInfo> = mp.drives();
    if drives.is_empty() {
        return "drives: no drives answered\n".to_string();
    }
    let mounted: Vec<MountInfo> = mp.mounts();
    let mut s = String::new();
    for d in &drives {
        s.push_str(&format!(
            "{:<8} {:<24} {:>10} {}\n",
            d.id,
            if d.model.is_empty() { "-" } else { &d.model },
            human(d.bytes),
            d.scheme
        ));
        for w in &d.warnings {
            s.push_str(&format!("         ! {w}\n"));
        }
        match mp.volumes(&d.id) {
            Ok(vols) if vols.is_empty() => s.push_str("         (no partitions)\n"),
            Ok(vols) => {
                for v in vols {
                    let live = mounted
                        .iter()
                        .find(|m| m.drive == v.drive && m.index == v.index);
                    let state = match live {
                        Some(m) if m.rw => "mounted rw".to_string(),
                        Some(_) => "mounted ro".to_string(),
                        None if v.mountable => "-".to_string(),
                        None => "no driver".to_string(),
                    };
                    s.push_str(&format!(
                        "  {}:{:<2} {:<12} {:<8} {:<12} {:>9} {}\n",
                        v.drive,
                        v.index,
                        v.name,
                        v.fs,
                        if v.label.is_empty() {
                            &v.kind
                        } else {
                            &v.label
                        },
                        human(v.bytes),
                        state
                    ));
                    if let Some(why) = &v.write_block {
                        s.push_str(&format!("         ro: {why}\n"));
                    }
                }
            }
            Err(e) => s.push_str(&format!("         ! {e}\n")),
        }
    }
    s
}

/// `mount` with no arguments — what is mounted right now.
pub fn mounts_table(ports: &mut Ports) -> String {
    let Some(mp) = ports.mounts.as_mut() else {
        return "mount: no block reader in this build\n".to_string();
    };
    let ms = mp.mounts();
    if ms.is_empty() {
        return "nothing is mounted (`drives` lists what could be)\n".to_string();
    }
    let mut s = String::from("mount    on              fs      mode  os\n");
    for m in ms {
        s.push_str(&format!(
            "{:<8} {:<15} {:<7} {:<5} {}\n",
            m.name,
            m.mnt(),
            m.fs,
            if m.rw { "rw" } else { "ro" },
            m.os.unwrap_or_else(|| "-".into())
        ));
        if let Some(why) = m.why_ro {
            s.push_str(&format!("         ro: {why}\n"));
        }
    }
    s
}

/// `mount [-w] <drive>[:<index>] [as <name>]`, and the "which volume?" prompt
/// when a drive has more than one candidate.
pub fn mount_cmd(ports: &mut Ports, rest: &str) -> String {
    let mut rw = false;
    let mut words: Vec<String> = Vec::new();
    for w in rest.split_whitespace() {
        match w {
            "-w" | "--rw" | "rw" => rw = true,
            "-r" | "--ro" | "ro" => rw = false,
            "as" => {}
            other => words.push(other.to_string()),
        }
    }
    if words.is_empty() {
        return mounts_table(ports);
    }
    let spec = words[0].clone();
    let want_name = words.get(1).cloned();
    let (drive, index) = match spec.split_once(':') {
        Some((d, i)) => match i.parse::<u32>() {
            Ok(n) => (d.to_string(), Some(n)),
            Err(_) => return format!("mount: `{i}` is not a partition number\n"),
        },
        None => (spec.clone(), None),
    };
    let Some(mp) = ports.mounts.as_mut() else {
        return "mount: no block reader in this build\n".to_string();
    };
    // A bare name that is already a volume name is the friendly spelling.
    let mut slots = match mp.volumes(&drive) {
        Ok(v) => v,
        Err(_) => {
            let mut found = Vec::new();
            for d in mp.drives() {
                for v in mp.volumes(&d.id).unwrap_or_default() {
                    if v.name == drive.to_ascii_lowercase() {
                        found.push(v);
                    }
                }
            }
            if found.is_empty() {
                return format!("mount: no drive or volume `{drive}` (try `drives`)\n");
            }
            found
        }
    };
    if let Some(n) = index {
        slots.retain(|v| v.index == n);
        if slots.is_empty() {
            return format!("mount: {drive} has no partition {n}\n");
        }
    }
    let usable: Vec<VolumeSlot> = slots.iter().filter(|v| v.mountable).cloned().collect();
    if usable.is_empty() {
        let mut s = format!("mount: nothing on {drive} has a driver in this BIOS:\n");
        for v in slots {
            s.push_str(&format!(
                "  {}:{} {} {} — {}\n",
                v.drive, v.index, v.name, v.fs, v.evidence
            ));
        }
        return s;
    }
    if usable.len() > 1 {
        // More than one candidate: name them and let the operator choose. A BIOS
        // guessing which partition an operator meant is how the wrong one gets
        // written to.
        let mut s = format!("mount: {drive} has {} volumes — pick one:\n", usable.len());
        for v in usable {
            s.push_str(&format!(
                "  mount {}{}:{:<2} {:<12} {:<7} {:<12} {}\n",
                if rw { "-w " } else { "" },
                v.drive,
                v.index,
                v.name,
                v.fs,
                if v.label.is_empty() {
                    &v.kind
                } else {
                    &v.label
                },
                human(v.bytes)
            ));
        }
        return s;
    }
    let slot = usable[0].clone();
    let name = want_name.unwrap_or_else(|| slot.name.clone());
    match mp.mount(&slot.drive, slot.index, &name, rw) {
        Ok(m) => {
            let mut s = format!(
                "mounted {} at {} ({}, {})\n",
                m.name,
                m.mnt(),
                m.fs,
                if m.rw { "rw" } else { "ro" }
            );
            if let Some(why) = m.why_ro {
                s.push_str(&format!("  read-only: {why}\n"));
            }
            if let Some(os) = m.os {
                s.push_str(&format!("  installed: {os}\n"));
            }
            s
        }
        Err(e) => format!("mount: {e}\n"),
    }
}

pub fn umount_cmd(ports: &mut Ports, rest: &str) -> String {
    let name = rest.trim();
    if name.is_empty() {
        return "umount: which mount? (`mount` lists them)\n".to_string();
    }
    match ports.mounts.as_mut() {
        None => "umount: no block reader in this build\n".to_string(),
        Some(mp) => match mp.umount(name) {
            Ok(()) => format!("umounted {name}\n"),
            Err(e) => format!("umount: {e}\n"),
        },
    }
}

/// `ls` output for a mounted directory.
pub fn list_rows(ents: &[Entry]) -> String {
    if ents.is_empty() {
        return "(empty)\n".to_string();
    }
    let mut s = String::new();
    for e in ents {
        s.push_str(&format!(
            "{} {:>10}  {}\n",
            if e.dir { "d" } else { "-" },
            if e.dir {
                "-".to_string()
            } else {
                e.size.to_string()
            },
            e.name
        ));
    }
    s
}

/// Bytes an operator can read at a glance.
pub fn human(bytes: u64) -> String {
    const UNITS: [(&str, u64); 4] = [("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10), ("B", 1)];
    for (suffix, scale) in UNITS {
        if bytes >= scale {
            let whole = bytes / scale;
            let frac = (bytes % scale) * 10 / scale;
            return if whole < 10 && frac > 0 {
                format!("{whole}.{frac}{suffix}")
            } else {
                format!("{whole}{suffix}")
            };
        }
    }
    "0B".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_three_path_shapes_reach_the_same_place() {
        let bios = Cwd::Bios("/".into());
        // ZealOS drive spelling.
        assert_eq!(
            resolve(&bios, "root:/etc"),
            Some(Target::Mount {
                name: "root".into(),
                path: "/etc".into()
            })
        );
        // Unix mount point.
        assert_eq!(
            resolve(&bios, "/mnt/root/etc"),
            Some(Target::Mount {
                name: "root".into(),
                path: "/etc".into()
            })
        );
        // Relative, once inside — and `..` cannot leave the mount.
        let inside = Cwd::Mount {
            name: "root".into(),
            path: "/etc".into(),
        };
        assert_eq!(
            resolve(&inside, "network"),
            Some(Target::Mount {
                name: "root".into(),
                path: "/etc/network".into()
            })
        );
        assert_eq!(
            resolve(&inside, "../boot"),
            Some(Target::Mount {
                name: "root".into(),
                path: "/boot".into()
            })
        );
        assert_eq!(
            resolve(&inside, "/../../.."),
            Some(Target::Mount {
                name: "root".into(),
                path: "/".into()
            })
        );
        // BIOS: is the local tree, and `/mnt` itself is a BIOS path.
        assert_eq!(
            resolve(&bios, "BIOS:/log"),
            Some(Target::Bios("/log".into()))
        );
        assert_eq!(resolve(&bios, "/mnt"), Some(Target::Bios("/mnt".into())));
        assert_eq!(resolve(&bios, "  "), None);
        // A relative path in the BIOS tree stays in the BIOS tree.
        assert_eq!(
            resolve(&Cwd::Bios("/log".into()), "boot.txt"),
            Some(Target::Bios("/log/boot.txt".into()))
        );
    }

    #[test]
    fn the_prompt_shows_where_you_are() {
        assert_eq!(Cwd::Bios("/".into()).display(), "BIOS:/");
        assert_eq!(
            Cwd::Mount {
                name: "root".into(),
                path: "/etc".into()
            }
            .display(),
            "/mnt/root/etc"
        );
        assert_eq!(
            Cwd::Mount {
                name: "esp".into(),
                path: "/".into()
            }
            .display(),
            "/mnt/esp"
        );
    }

    #[test]
    fn sizes_read_like_sizes() {
        assert_eq!(human(0), "0B");
        assert_eq!(human(512), "512B");
        assert_eq!(human(1536), "1.5K");
        assert_eq!(human(64 << 20), "64M");
        assert_eq!(human(3 << 30), "3G");
    }

    #[test]
    fn a_build_without_a_block_reader_says_so() {
        let mut ports = Ports::default();
        assert!(drives_table(&mut ports).contains("no block reader"));
        assert!(mounts_table(&mut ports).contains("no block reader"));
        assert!(mount_cmd(&mut ports, "disk0").contains("no block reader"));
        assert!(umount_cmd(&mut ports, "root").contains("no block reader"));
        assert!(ensure_mounted(&mut ports, "root")
            .unwrap_err()
            .contains("no block reader"));
    }
}
