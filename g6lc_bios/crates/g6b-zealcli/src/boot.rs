// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Next-stage selector: OpenSBI payload, EDK2, or U-Boot, on a chosen
//! volume/device.
//!
//! This is the BIOS half of the handoff contract, not a bootloader: EDK2 and
//! U-Boot are *loaders* the BIOS hands control to, so what setup can choose is
//! (a) which next stage the boot policy names and (b) which volume/device it is
//! taken from. Presence is **probed**, never assumed: a target whose loader file
//! is not on the volume is listed as absent and cannot be selected. The choice
//! is written through the settings overlay (`boot.next`, `boot.volume`), which
//! is the same path the browser-UI writes.

use crate::ports::Ports;
use crate::settings::Overlay;
use g6b_spec::BoardSpec;

/// One selectable boot target.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    /// Selector id (`opensbi`, `edk2@KEY-FAT`, `u-boot@FLASH`).
    pub id: String,
    /// `opensbi` | `edk2` | `u-boot` — the BoardSpec `kernel.params.next` value.
    pub stage: String,
    /// Volume the loader would be read from; empty for the in-image payload.
    pub volume: String,
    /// Loader file the probe looked for.
    pub file: String,
    pub present: bool,
    pub note: String,
}

/// Loader files each stage is recognized by, in probe order. These are the
/// canonical names the respective projects install.
///
/// `\EFI\BOOT\BOOTRISCV64.EFI` is the UEFI **removable-media path** (UEFI 2.10
/// §3.5.1.1), which is what makes an ESP bootable without an NVRAM entry. U-Boot
/// installs a FIT (`u-boot.itb`) and, when it boots a distro, an
/// `extlinux/extlinux.conf` or a `boot.scr` next to it — finding those is the
/// difference between "u-boot is here" and "u-boot has something to boot".
const EDK2_FILES: &[&str] = &["/EFI/BOOT/BOOTRISCV64.EFI", "/EFI/BOOT/bootriscv64.efi"];
const UBOOT_FILES: &[&str] = &[
    "/u-boot.itb",
    "/u-boot.bin",
    "/boot/u-boot.itb",
    "/boot/extlinux/extlinux.conf",
    "/extlinux/extlinux.conf",
    "/boot.scr",
    "/boot/boot.scr",
];

/// Targets this board can offer. The in-image payload is always first: it is
/// the one target that cannot go missing.
///
/// Real mounts come first in the probe, because a real ESP read with a real
/// filesystem driver is evidence, while a modelled volume is a BoardSpec claim.
pub fn targets(spec: &BoardSpec, ports: &mut Ports) -> Vec<Target> {
    let mut out = vec![Target {
        id: "opensbi".into(),
        stage: "opensbi".into(),
        volume: String::new(),
        file: String::new(),
        present: true,
        note: "this S-mode payload (setup stays in control)".into(),
    }];
    out.extend(mounted_targets(spec, ports));
    let vols = crate::fsview::drives(ports);
    for (enabled, stage, files, note) in [
        (
            spec.kernel.params.edk2,
            "edk2",
            EDK2_FILES,
            "UEFI loader (BIOS hands off; not this payload)",
        ),
        (
            spec.kernel.params.uboot,
            "u-boot",
            UBOOT_FILES,
            "U-Boot loader (BIOS hands off)",
        ),
    ] {
        if !enabled {
            continue;
        }
        if vols.is_empty() {
            out.push(Target {
                id: stage.to_string(),
                stage: stage.to_string(),
                volume: String::new(),
                file: files[0].to_string(),
                present: false,
                note: "no volume to probe".into(),
            });
            continue;
        }
        for v in &vols {
            let found = files.iter().find(|f| exists(ports, &v.id, f));
            out.push(Target {
                id: format!("{stage}@{}", v.id),
                stage: stage.to_string(),
                volume: v.id.clone(),
                file: found.unwrap_or(&files[0]).to_string(),
                present: found.is_some(),
                note: note.to_string(),
            });
        }
    }
    out
}

/// Loader targets found on **real** volumes, by reading them.
///
/// Every mountable volume is probed — mounting read-only, which is all a probe
/// needs — and an ESP is probed first because that is where a loader belongs. The
/// note carries the evidence, so a selector row can say *why* it thinks edk2 is
/// there instead of asking the operator to trust it.
fn mounted_targets(spec: &BoardSpec, live: &mut Ports) -> Vec<Target> {
    let Some(mp) = live.mounts.as_mut() else {
        return Vec::new();
    };
    // Volumes worth probing, ESPs first.
    let mut slots: Vec<crate::ports::VolumeSlot> = Vec::new();
    for d in mp.drives() {
        for v in mp.volumes(&d.id).unwrap_or_default() {
            if v.mountable {
                slots.push(v);
            }
        }
    }
    slots.sort_by_key(|v| !matches!(v.kind.as_str(), "esp" | "fat32"));
    let mut out = Vec::new();
    for slot in slots {
        // A probe mount is read-only and transient: it must not change what it
        // is looking at, and it must not hold a name an operator wanted.
        let name = format!("probe-{}-{}", slot.drive, slot.index);
        let mounted = mp.mount(&slot.drive, slot.index, &name, false).is_ok();
        if !mounted {
            continue;
        }
        for (enabled, stage, files) in [
            (spec.kernel.params.edk2, "edk2", EDK2_FILES),
            (spec.kernel.params.uboot, "u-boot", UBOOT_FILES),
        ] {
            if !enabled {
                continue;
            }
            let found = files.iter().find(|f| {
                let dir = crate::fsview::parent_of(f);
                let base = f.rsplit('/').next().unwrap_or(f);
                mp.list(&name, &dir)
                    .map(|ents| {
                        ents.iter()
                            .any(|e| !e.dir && e.name.eq_ignore_ascii_case(base))
                    })
                    .unwrap_or(false)
            });
            if let Some(file) = found {
                out.push(Target {
                    id: format!("{stage}@{}", slot.name),
                    stage: stage.to_string(),
                    volume: slot.name.clone(),
                    file: (*file).to_string(),
                    present: true,
                    note: format!(
                        "read from {}:{} ({}, {})",
                        slot.drive,
                        slot.index,
                        slot.fs,
                        if slot.label.is_empty() {
                            slot.kind.clone()
                        } else {
                            slot.label.clone()
                        }
                    ),
                });
            }
        }
        let _ = mp.umount(&name);
    }
    out
}

fn exists(ports: &Ports, volume: &str, path: &str) -> bool {
    let Some(vp) = ports.volumes.as_ref() else {
        return false;
    };
    let dir = crate::fsview::parent_of(path);
    let name = path.rsplit('/').next().unwrap_or(path);
    vp.list(volume, &dir)
        .map(|ents| {
            ents.iter()
                .any(|e| !e.dir && e.name.eq_ignore_ascii_case(name))
        })
        .unwrap_or(false)
}

/// `boot` with no argument: the selector screen.
pub fn table(spec: &BoardSpec, ports: &mut Ports) -> String {
    let mut s = format!(
        "next stage: {}   flash backend: {}\n\
         id                     stage     volume    loader                      state\n",
        spec.kernel.params.next, spec.kernel.flash.backend
    );
    for t in targets(spec, ports) {
        s.push_str(&format!(
            "{:<22} {:<9} {:<9} {:<27} {}\n",
            t.id,
            t.stage,
            if t.volume.is_empty() { "-" } else { &t.volume },
            if t.file.is_empty() { "-" } else { &t.file },
            if t.present { "present" } else { "absent" }
        ));
    }
    s.push_str("select with `boot <id>` (writes boot.next / boot.volume)\n");
    s
}

/// Select a target: refuse absent ones, otherwise write the overlay.
pub fn select(
    spec: &BoardSpec,
    ports: &mut Ports,
    overlay: &mut Overlay,
    id: &str,
) -> Result<String, String> {
    let all = targets(spec, ports);
    let t = all
        .iter()
        .find(|t| t.id.eq_ignore_ascii_case(id))
        .ok_or_else(|| {
            format!(
                "boot: unknown target `{id}`; try one of {}",
                all.iter()
                    .map(|t| t.id.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        })?;
    if !t.present {
        return Err(format!(
            "boot: `{}` is absent ({} not on {})",
            t.id,
            t.file,
            if t.volume.is_empty() {
                "any volume"
            } else {
                &t.volume
            }
        ));
    }
    let mut out = overlay.set(spec, "boot.next", &t.stage)?;
    if !t.volume.is_empty() {
        // A key-hosted loader means the image is taken from USB.
        out.push('\n');
        out.push_str(&overlay.set(spec, "boot.volume", "usb")?);
    }
    Ok(format!(
        "BOOT-SELECT {} stage={} volume={}\n{out}\n",
        t.id,
        t.stage,
        if t.volume.is_empty() { "-" } else { &t.volume }
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::MemVolumes;

    fn spec() -> BoardSpec {
        BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"barebone"}"#).unwrap()
    }

    fn ports_with_edk2() -> Ports {
        Ports::default().with_volumes(
            MemVolumes::new()
                .volume("KEY-FAT", "fat32", "key")
                .file("KEY-FAT", "/EFI/BOOT/BOOTRISCV64.EFI", vec![0u8; 2048])
                .volume("FLASH", "fat32", "flash"),
        )
    }

    #[test]
    fn payload_is_always_present_and_loaders_are_probed() {
        let spec = spec();
        let mut ports = ports_with_edk2();
        let all = targets(&spec, &mut ports);
        assert_eq!(all[0].id, "opensbi");
        assert!(all[0].present);
        let edk2_key = all.iter().find(|t| t.id == "edk2@KEY-FAT").unwrap();
        assert!(edk2_key.present, "the EFI file is on the key");
        assert!(edk2_key
            .file
            .to_ascii_uppercase()
            .ends_with("BOOTRISCV64.EFI"));
        let edk2_flash = all.iter().find(|t| t.id == "edk2@FLASH").unwrap();
        assert!(!edk2_flash.present, "nothing was installed on FLASH");
        let uboot = all.iter().find(|t| t.id == "u-boot@KEY-FAT").unwrap();
        assert!(!uboot.present);
        let t = table(&spec, &mut ports);
        assert!(t.contains("present") && t.contains("absent"), "{t}");
        assert!(t.contains("next stage: opensbi"), "{t}");
    }

    #[test]
    fn selecting_writes_the_overlay_and_absent_is_refused() {
        let spec = spec();
        let mut ports = ports_with_edk2();
        let mut o = Overlay::default();
        let out = select(&spec, &mut ports, &mut o, "edk2@KEY-FAT").unwrap();
        assert!(out.contains("BOOT-SELECT edk2@KEY-FAT"), "{out}");
        assert_eq!(o.get("boot.next"), Some("edk2"));
        assert_eq!(o.get("boot.volume"), Some("usb"));
        let err = select(&spec, &mut ports, &mut o, "edk2@FLASH").unwrap_err();
        assert!(err.contains("absent"), "{err}");
        assert!(select(&spec, &mut ports, &mut o, "grub")
            .unwrap_err()
            .contains("unknown"));
        // Back to the payload: no volume is written.
        let mut o2 = Overlay::default();
        select(&spec, &mut ports, &mut o2, "opensbi").unwrap();
        assert_eq!(o2.get("boot.next"), Some("opensbi"));
        assert_eq!(o2.get("boot.volume"), None);
    }

    #[test]
    fn no_volumes_lists_loaders_as_absent_not_missing() {
        let spec = spec();
        let mut bare = Ports::default();
        let all = targets(&spec, &mut bare);
        assert!(all.iter().any(|t| t.stage == "edk2" && !t.present));
        assert!(all
            .iter()
            .any(|t| t.stage == "u-boot" && t.note.contains("no volume")));
        assert_eq!(all.iter().filter(|t| t.present).count(), 1);
    }
}
