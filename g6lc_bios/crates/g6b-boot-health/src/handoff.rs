// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! FDT health-handoff contract for the Linux helper.
//!
//! `/firmware/g6b-boot-health` carries the G6BH journal window. This is the
//! documented firmware/FDT interface; it is not sysfs and not a live kernel.

use g6b_bootctl::{FirmwareLayout, JOURNAL_BYTES};
use std::path::Path;

const FDT_MAGIC: u32 = 0xd00d_feed;
const FDT_BEGIN_NODE: u32 = 0x1;
const FDT_END_NODE: u32 = 0x2;
const FDT_PROP: u32 = 0x3;
const FDT_END: u32 = 0x9;
const FDT_HEADER: usize = 40;
const FDT_VERSION: u32 = 17;
const FDT_LAST_COMP: u32 = 16;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HealthHandoff {
    pub journal_lba: u32,
    pub journal_sectors: u32,
}

impl HealthHandoff {
    pub const BIOS: Self = Self {
        journal_lba: FirmwareLayout::BIOS.journal_lba as u32,
        journal_sectors: FirmwareLayout::BIOS.journal_sectors as u32,
    };

    /// Byte offset of the G6BH window. LBA must sit past GPT; size must be
    /// the helper's two 4 KiB slots.
    pub fn journal_offset(self) -> Result<u64, HandoffError> {
        if self.journal_lba < 8 {
            return Err(HandoffError::Bounds);
        }
        let bytes = u64::from(self.journal_sectors).saturating_mul(512);
        if bytes != JOURNAL_BYTES as u64 {
            return Err(HandoffError::Bounds);
        }
        Ok(u64::from(self.journal_lba).saturating_mul(512))
    }

    /// Linux `/proc/device-tree` (or a test tree) property files.
    pub fn from_dt_root(root: &Path) -> Result<Self, HandoffError> {
        let node = root.join("firmware").join("g6b-boot-health");
        let compat = std::fs::read(node.join("compatible")).map_err(|_| HandoffError::Missing)?;
        if !compat.starts_with(b"g6b,boot-health-1") {
            return Err(HandoffError::Missing);
        }
        Ok(Self {
            journal_lba: read_be_u32(&node.join("journal-lba"))?,
            journal_sectors: read_be_u32(&node.join("journal-sectors"))?,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HandoffError {
    Magic,
    Truncated,
    Missing,
    Bounds,
}

pub fn encode(h: HealthHandoff) -> Vec<u8> {
    let mut strings = Vec::new();
    let mut intern = |s: &str| -> u32 {
        let off = strings.len() as u32;
        strings.extend_from_slice(s.as_bytes());
        strings.push(0);
        off
    };
    let off_compat = intern("compatible");
    let off_lba = intern("journal-lba");
    let off_sec = intern("journal-sectors");

    let mut st = Vec::new();
    begin_node(&mut st, "");
    begin_node(&mut st, "firmware");
    begin_node(&mut st, "g6b-boot-health");
    prop(&mut st, off_compat, b"g6b,boot-health-1\0");
    prop_u32(&mut st, off_lba, h.journal_lba);
    prop_u32(&mut st, off_sec, h.journal_sectors);
    end_node(&mut st);
    end_node(&mut st);
    end_node(&mut st);
    put_be(&mut st, FDT_END);

    while strings.len() % 4 != 0 {
        strings.push(0);
    }

    let rsv = 16usize;
    let off_rsv = FDT_HEADER;
    let off_struct = off_rsv + rsv;
    let off_strings = off_struct + st.len();
    let total = off_strings + strings.len();

    let mut out = vec![0u8; total];
    put_be_at(&mut out, 0, FDT_MAGIC);
    put_be_at(&mut out, 4, total as u32);
    put_be_at(&mut out, 8, off_struct as u32);
    put_be_at(&mut out, 12, off_strings as u32);
    put_be_at(&mut out, 16, off_rsv as u32);
    put_be_at(&mut out, 20, FDT_VERSION);
    put_be_at(&mut out, 24, FDT_LAST_COMP);
    put_be_at(&mut out, 32, strings.len() as u32);
    put_be_at(&mut out, 36, st.len() as u32);
    out[off_struct..off_struct + st.len()].copy_from_slice(&st);
    out[off_strings..off_strings + strings.len()].copy_from_slice(&strings);
    out
}

pub fn decode(dtb: &[u8]) -> Result<HealthHandoff, HandoffError> {
    if dtb.len() < 4 || be_u32(dtb, 0)? != FDT_MAGIC {
        return Err(HandoffError::Magic);
    }
    if dtb.len() < FDT_HEADER {
        return Err(HandoffError::Truncated);
    }
    let total = be_u32(dtb, 4)? as usize;
    let off_struct = be_u32(dtb, 8)? as usize;
    let off_strings = be_u32(dtb, 12)? as usize;
    let size_strings = be_u32(dtb, 32)? as usize;
    let size_struct = be_u32(dtb, 36)? as usize;
    if total > dtb.len()
        || off_struct
            .checked_add(size_struct)
            .ok_or(HandoffError::Truncated)?
            > dtb.len()
        || off_strings
            .checked_add(size_strings)
            .ok_or(HandoffError::Truncated)?
            > dtb.len()
    {
        return Err(HandoffError::Truncated);
    }
    let st = &dtb[off_struct..off_struct + size_struct];
    let strs = &dtb[off_strings..off_strings + size_strings];
    let mut i = 0usize;
    let mut lba = None;
    let mut sec = None;
    let mut health = false;
    while i + 4 <= st.len() {
        let tok = be_u32(st, i)?;
        i += 4;
        match tok {
            FDT_BEGIN_NODE => {
                let name = cstr(st, i)?;
                if name == "g6b-boot-health" {
                    health = true;
                }
                i = align4(i + name.len() + 1);
            }
            FDT_END_NODE => {
                health = false;
            }
            FDT_PROP => {
                if i + 8 > st.len() {
                    return Err(HandoffError::Truncated);
                }
                let len = be_u32(st, i)? as usize;
                let nameoff = be_u32(st, i + 4)? as usize;
                i += 8;
                if i + len > st.len() {
                    return Err(HandoffError::Truncated);
                }
                let name = cstr(strs, nameoff)?;
                let data = &st[i..i + len];
                i = align4(i + len);
                if health && name == "journal-lba" && data.len() == 4 {
                    lba = Some(u32::from_be_bytes(data.try_into().unwrap()));
                }
                if health && name == "journal-sectors" && data.len() == 4 {
                    sec = Some(u32::from_be_bytes(data.try_into().unwrap()));
                }
            }
            FDT_END => break,
            _ => return Err(HandoffError::Truncated),
        }
    }
    match (lba, sec) {
        (Some(journal_lba), Some(journal_sectors)) => Ok(HealthHandoff {
            journal_lba,
            journal_sectors,
        }),
        _ => Err(HandoffError::Missing),
    }
}

fn begin_node(st: &mut Vec<u8>, name: &str) {
    put_be(st, FDT_BEGIN_NODE);
    st.extend_from_slice(name.as_bytes());
    st.push(0);
    while st.len() % 4 != 0 {
        st.push(0);
    }
}

fn end_node(st: &mut Vec<u8>) {
    put_be(st, FDT_END_NODE);
}

fn prop(st: &mut Vec<u8>, nameoff: u32, data: &[u8]) {
    put_be(st, FDT_PROP);
    put_be(st, data.len() as u32);
    put_be(st, nameoff);
    st.extend_from_slice(data);
    while st.len() % 4 != 0 {
        st.push(0);
    }
}

fn prop_u32(st: &mut Vec<u8>, nameoff: u32, value: u32) {
    prop(st, nameoff, &value.to_be_bytes());
}

fn put_be(buf: &mut Vec<u8>, v: u32) {
    buf.extend_from_slice(&v.to_be_bytes());
}

fn put_be_at(buf: &mut [u8], off: usize, v: u32) {
    buf[off..off + 4].copy_from_slice(&v.to_be_bytes());
}

fn be_u32(buf: &[u8], off: usize) -> Result<u32, HandoffError> {
    buf.get(off..off + 4)
        .and_then(|b| b.try_into().ok())
        .map(u32::from_be_bytes)
        .ok_or(HandoffError::Truncated)
}

fn cstr(buf: &[u8], off: usize) -> Result<&str, HandoffError> {
    let rest = buf.get(off..).ok_or(HandoffError::Truncated)?;
    let n = rest
        .iter()
        .position(|&b| b == 0)
        .ok_or(HandoffError::Truncated)?;
    std::str::from_utf8(&rest[..n]).map_err(|_| HandoffError::Truncated)
}

fn align4(n: usize) -> usize {
    (n + 3) & !3
}

fn read_be_u32(path: &Path) -> Result<u32, HandoffError> {
    let bytes = std::fs::read(path).map_err(|_| HandoffError::Missing)?;
    bytes
        .get(..4)
        .and_then(|b| b.try_into().ok())
        .map(u32::from_be_bytes)
        .ok_or(HandoffError::Truncated)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bios_handoff_round_trips() {
        let dtb = encode(HealthHandoff::BIOS);
        assert!(dtb.len() <= 0x400);
        assert_eq!(&dtb[..4], &[0xd0, 0x0d, 0xfe, 0xed]);
        assert_eq!(decode(&dtb), Ok(HealthHandoff::BIOS));
        assert_eq!(HealthHandoff::BIOS.journal_lba, 8);
        assert_eq!(HealthHandoff::BIOS.journal_sectors, 16);
        assert_eq!(HealthHandoff::BIOS.journal_offset(), Ok(4096));
    }

    #[test]
    fn gpt_and_wrong_size_windows_are_bounds() {
        assert_eq!(
            HealthHandoff {
                journal_lba: 0,
                journal_sectors: 16
            }
            .journal_offset(),
            Err(HandoffError::Bounds)
        );
        assert_eq!(
            HealthHandoff {
                journal_lba: 8,
                journal_sectors: 8
            }
            .journal_offset(),
            Err(HandoffError::Bounds)
        );
    }

    #[test]
    fn proc_device_tree_files_decode() {
        let root = std::env::temp_dir().join(format!(
            "g6b-dt-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let node = root.join("firmware").join("g6b-boot-health");
        std::fs::create_dir_all(&node).unwrap();
        std::fs::write(node.join("compatible"), b"g6b,boot-health-1\0").unwrap();
        std::fs::write(node.join("journal-lba"), 8u32.to_be_bytes()).unwrap();
        std::fs::write(node.join("journal-sectors"), 16u32.to_be_bytes()).unwrap();
        assert_eq!(HealthHandoff::from_dt_root(&root), Ok(HealthHandoff::BIOS));
        std::fs::write(node.join("compatible"), b"acme,other\0").unwrap();
        assert_eq!(
            HealthHandoff::from_dt_root(&root),
            Err(HandoffError::Missing)
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn truncated_or_wrong_magic_is_refused() {
        assert_eq!(decode(&[0xd0, 0x0d, 0xfe]), Err(HandoffError::Magic));
        let mut dtb = encode(HealthHandoff::BIOS);
        dtb[0] ^= 1;
        assert_eq!(decode(&dtb), Err(HandoffError::Magic));
        dtb = encode(HealthHandoff::BIOS);
        dtb.truncate(20);
        assert_eq!(decode(&dtb), Err(HandoffError::Truncated));
    }

    #[test]
    fn missing_health_node_is_refused() {
        let mut dtb = encode(HealthHandoff::BIOS);
        let needle = b"g6b-boot-health";
        if let Some(at) = dtb.windows(needle.len()).position(|w| w == needle) {
            dtb[at] = b'x';
        }
        assert_eq!(decode(&dtb), Err(HandoffError::Missing));
    }
}
