// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! NTFS — **read-only**, and only as far as a BIOS needs: list a directory, read
//! a file, tell an operator that the Windows install is there.
//!
//! On-disk contract:
//!
//! * Boot sector: OEM ID `"NTFS    "` at 3, `bytes_per_sector` (11),
//!   `sectors_per_cluster` (13), `total_sectors` (40), `mft_lcn` (48),
//!   `clusters_per_mft_record` (64) — a *negative* value there means
//!   `1 << -value` **bytes** instead of clusters.
//! * An MFT record starts `"FILE"`, with `update_seq_off` (4), `update_seq_size`
//!   (6), `attrs_off` (20), `flags` (22, bit 1 = directory), `used_size` (24).
//!   Every record is "fixed up": the last two bytes of each sector hold the
//!   update-sequence number and must be replaced by the array's saved values
//!   before the record is parsed. Skipping that is how NTFS readers corrupt
//!   long records.
//! * Attributes: `type` (0), `length` (4), `non_resident` (8), `name_len` (9),
//!   `name_off` (10). Resident: `value_len` (16), `value_off` (20).
//!   Non-resident: `start_vcn` (16), `last_vcn` (24), `run_list_off` (32),
//!   `real_size` (48), with a run list of `{header nibble sizes, length, offset
//!   delta}` entries.
//! * `$FILE_NAME` (0x30) carries the name and the parent reference;
//!   `$DATA` (0x80) the contents; `$INDEX_ROOT`/`$INDEX_ALLOCATION` (0x90/0xA0)
//!   the directory index.
//!
//! Directory listing here walks the **$MFT itself** rather than the B-tree index:
//! every record names its parent, so one pass over the table answers "what is in
//! this directory" without implementing index buffers. That is slower than an
//! index walk and far simpler to get right — the correct trade for a BIOS that
//! lists a Windows volume occasionally, and it is bounded by the MFT size.

use crate::block::{le16, le32, le64, read_vec, BlockDev};
use crate::{DirEnt, Error, FileSystem, FsKind, Result, Stat};

const ATTR_FILE_NAME: u32 = 0x30;
const ATTR_DATA: u32 = 0x80;
const ATTR_END: u32 = 0xFFFF_FFFF;
const FLAG_DIR: u16 = 0x0002;
const FLAG_IN_USE: u16 = 0x0001;
const ROOT_REF: u64 = 5;
/// A BIOS lists a volume; it does not index a server. Bounded on purpose.
const MAX_RECORDS: u64 = 64 * 1024;

pub struct Ntfs<'a> {
    dev: &'a mut dyn BlockDev,
    cluster_bytes: u64,
    record_bytes: u64,
    mft_off: u64,
    /// Data runs of `$MFT` itself, so records past the first extent are reachable.
    mft_runs: Vec<(u64, u64)>,
    label: String,
    /// `$LogFile` byte offset and size, if a valid one was found.
    logfile: Option<(u64, u64)>,
    /// Whether the `$LogFile` restart area says `CleanDismount`.
    log_clean: bool,
    /// Whether the underlying device reports itself as writable.
    dev_writable: bool,
}

/// One MFT record, fixed up and parsed just enough.
#[derive(Debug, Clone)]
struct Record {
    number: u64,
    name: String,
    parent: u64,
    dir: bool,
    size: u64,
    /// Resident data, when the file is small enough to live in its record.
    resident: Option<Vec<u8>>,
    /// `(lcn, clusters)` runs and the real size, when it is not.
    runs: Vec<(u64, u64)>,
    /// The fixed-up record bytes (sector tails restored) — used for rewrite.
    buf: Vec<u8>,
    /// Byte offset of the unnamed `$DATA` attribute header in `buf`, if present.
    data_attr: Option<usize>,
    /// True when the `$DATA` attribute is resident.
    data_resident: bool,
}

impl<'a> Ntfs<'a> {
    pub fn mount(dev: &'a mut dyn BlockDev) -> Result<Self> {
        let boot = read_vec(dev, 0, 512)?;
        if &boot[3..11] != b"NTFS    " {
            return Err(Error::Corrupt("ntfs: OEM ID"));
        }
        let bps = u64::from(le16(&boot, 11));
        let spc = u64::from(boot[13]);
        if !matches!(bps, 512 | 1024 | 2048 | 4096) || spc == 0 {
            return Err(Error::Corrupt("ntfs: implausible BPB"));
        }
        let cluster_bytes = bps * spc;
        let mft_lcn = le64(&boot, 48);
        let raw = boot[64] as i8;
        let record_bytes = if raw >= 0 {
            (raw as u64) * cluster_bytes
        } else {
            1u64 << (-raw as u32)
        };
        if !(256..=65536).contains(&record_bytes) {
            return Err(Error::Corrupt("ntfs: implausible MFT record size"));
        }
        let mft_off = mft_lcn * cluster_bytes;
        let dev_writable = dev.writable();
        let mut fs = Self {
            dev,
            cluster_bytes,
            record_bytes,
            mft_off,
            mft_runs: Vec::new(),
            label: String::new(),
            logfile: None,
            log_clean: true,
            dev_writable,
        };
        // Record 0 is `$MFT`; its own runs are what let us reach the rest.
        let zero = fs.record_at(fs.mft_off, 0)?;
        fs.mft_runs = zero.runs.clone();
        // Record 3 is `$Volume`; its `$VOLUME_NAME` (0x60) is the label.
        fs.label = fs.volume_label().unwrap_or_default();
        fs.load_logfile_state();
        Ok(fs)
    }

    /// Byte offset of MFT record `n`, following `$MFT`'s own runs.
    fn record_off(&self, n: u64) -> Result<u64> {
        let want = n * self.record_bytes;
        if self.mft_runs.is_empty() {
            return Ok(self.mft_off + want);
        }
        let mut seen = 0u64;
        for (lcn, clusters) in &self.mft_runs {
            let bytes = clusters * self.cluster_bytes;
            if want < seen + bytes {
                return Ok(lcn * self.cluster_bytes + (want - seen));
            }
            seen += bytes;
        }
        Err(Error::OutOfRange)
    }

    /// Read and *fix up* a record: the update sequence must be undone before the
    /// bytes mean anything.
    fn record_at(&mut self, off: u64, number: u64) -> Result<Record> {
        let mut buf = read_vec(self.dev, off, self.record_bytes as usize)?;
        fixup_apply(&mut buf, 512)?;
        let flags = le16(&buf, 22);
        let dir = flags & FLAG_DIR != 0;
        let in_use = flags & FLAG_IN_USE != 0;
        let mut rec = Record {
            number,
            name: String::new(),
            parent: 0,
            dir,
            size: 0,
            resident: None,
            runs: Vec::new(),
            buf,
            data_attr: None,
            data_resident: true,
        };
        if !in_use {
            return Ok(rec);
        }
        let mut at = le16(&rec.buf, 20) as usize;
        while at + 8 <= rec.buf.len() {
            let ty = le32(&rec.buf, at);
            if ty == ATTR_END {
                break;
            }
            let len = le32(&rec.buf, at + 4) as usize;
            if len < 16 || at + len > rec.buf.len() {
                break;
            }
            let non_resident = rec.buf[at + 8] != 0;
            match ty {
                ATTR_FILE_NAME if !non_resident => {
                    let voff = le16(&rec.buf, at + 20) as usize;
                    let v = &rec.buf[at + voff..at + len];
                    if v.len() >= 66 {
                        let parent = le64(v, 0) & 0x0000_FFFF_FFFF_FFFF;
                        let nlen = v[64] as usize;
                        let namespace = v[65];
                        let name = utf16(&v[66..(66 + nlen * 2).min(v.len())]);
                        // Namespace 2 is the DOS 8.3 alias; prefer any other.
                        if rec.name.is_empty() || namespace != 2 {
                            rec.name = name;
                            rec.parent = parent;
                        }
                    }
                }
                ATTR_DATA if rec.buf[at + 9] == 0 => {
                    // The unnamed $DATA stream is the file.
                    rec.data_attr = Some(at);
                    rec.data_resident = !non_resident;
                    if non_resident {
                        rec.size = le64(&rec.buf, at + 48);
                        let rl = le16(&rec.buf, at + 32) as usize;
                        rec.runs = run_list(&rec.buf[at + rl..at + len]);
                    } else {
                        let vlen = le32(&rec.buf, at + 16) as usize;
                        let voff = le16(&rec.buf, at + 20) as usize;
                        if at + voff + vlen <= rec.buf.len() {
                            rec.size = vlen as u64;
                            rec.resident = Some(rec.buf[at + voff..at + voff + vlen].to_vec());
                        }
                    }
                }
                _ => {}
            }
            at += len;
        }
        Ok(rec)
    }

    fn record(&mut self, n: u64) -> Result<Record> {
        let off = self.record_off(n)?;
        self.record_at(off, n)
    }

    fn volume_label(&mut self) -> Result<String> {
        let off = self.record_off(3)?;
        let mut buf = read_vec(self.dev, off, self.record_bytes as usize)?;
        if &buf[0..4] != b"FILE" {
            return Ok(String::new());
        }
        let usa_off = le16(&buf, 4) as usize;
        let usa_count = le16(&buf, 6) as usize;
        for i in 1..usa_count {
            if usa_off + i * 2 + 2 <= buf.len() {
                let fix = [buf[usa_off + i * 2], buf[usa_off + i * 2 + 1]];
                let at = i * 512 - 2;
                if at + 2 <= buf.len() {
                    buf[at] = fix[0];
                    buf[at + 1] = fix[1];
                }
            }
        }
        let mut at = le16(&buf, 20) as usize;
        while at + 8 <= buf.len() {
            let ty = le32(&buf, at);
            if ty == ATTR_END {
                break;
            }
            let len = le32(&buf, at + 4) as usize;
            if len < 16 || at + len > buf.len() {
                break;
            }
            if ty == 0x60 && buf[at + 8] == 0 {
                let vlen = le32(&buf, at + 16) as usize;
                let voff = le16(&buf, at + 20) as usize;
                return Ok(utf16(&buf[at + voff..at + voff + vlen]));
            }
            at += len;
        }
        Ok(String::new())
    }

    /// Read `$LogFile` (record 2) and decide whether the journal is clean.
    fn load_logfile_state(&mut self) {
        if !self.dev_writable {
            self.log_clean = false;
            return;
        }
        let log = match self.record(2) {
            Ok(r) => r,
            Err(_) => {
                // No $LogFile record: a hand-built or very small image may not
                // carry one. Treat as unclean so writes are refused until one
                // is added.
                self.log_clean = false;
                return;
            }
        };
        if log.runs.is_empty() {
            self.log_clean = false;
            return;
        }
        let mut off = 0u64;
        let mut size = 0u64;
        for (lcn, clusters) in &log.runs {
            let run_size = clusters * self.cluster_bytes;
            if off == 0 {
                off = lcn * self.cluster_bytes;
            }
            size += run_size;
        }
        self.logfile = Some((off, size));
        let mut page0 = [0u8; 4096];
        let mut page1 = [0u8; 4096];
        let clean0 = self
            .dev
            .read_at(off, &mut page0)
            .ok()
            .and_then(|_| parse_restart_page(&page0))
            .map(|(_, c)| c)
            .unwrap_or(false);
        let clean1 = self
            .dev
            .read_at(off + 4096, &mut page1)
            .ok()
            .and_then(|_| parse_restart_page(&page1))
            .map(|(_, c)| c)
            .unwrap_or(false);
        self.log_clean = clean0 || clean1;
    }

    /// How many records the MFT can hold, from `$MFT`'s own data runs. Without
    /// that bound the walk would either stop at the first free record or run off
    /// into whatever follows the table.
    fn record_capacity(&self) -> u64 {
        let bytes: u64 = self
            .mft_runs
            .iter()
            .map(|(_, clusters)| clusters * self.cluster_bytes)
            .sum();
        let bytes = if bytes == 0 {
            self.dev.len().saturating_sub(self.mft_off)
        } else {
            bytes
        };
        (bytes / self.record_bytes).min(MAX_RECORDS)
    }

    /// Every named, in-use record. A record without `FILE` magic is a *free*
    /// slot — the MFT is sparse, so those are skipped, not treated as the end.
    fn walk(&mut self) -> Result<Vec<Record>> {
        let mut out = Vec::new();
        let cap = self.record_capacity();
        for n in 0..cap {
            let off = match self.record_off(n) {
                Ok(o) => o,
                Err(_) => break,
            };
            if off + self.record_bytes > self.dev.len() {
                break;
            }
            if let Ok(r) = self.record_at(off, n) {
                if !r.name.is_empty() {
                    out.push(r);
                }
            }
        }
        Ok(out)
    }

    /// The record for a path, by walking components from the root reference.
    fn resolve(&mut self, path: &str) -> Result<Record> {
        let all = self.walk()?;
        let mut parent = ROOT_REF;
        let parts = crate::split_path(path);
        if parts.is_empty() {
            let mut root = self.record(ROOT_REF)?;
            root.dir = true;
            return Ok(root);
        }
        let mut cur: Option<Record> = None;
        for (i, part) in parts.iter().enumerate() {
            let hit = all
                .iter()
                .find(|r| r.parent == parent && r.name.eq_ignore_ascii_case(part))
                .cloned()
                .ok_or_else(|| Error::NotFoundPath(path.to_string()))?;
            let last = i + 1 == parts.len();
            if !last {
                if !hit.dir {
                    return Err(Error::NotADir(part.clone()));
                }
                parent = hit.number;
            }
            cur = Some(hit);
        }
        cur.ok_or_else(|| Error::NotFoundPath(path.to_string()))
    }

    fn read_runs(&mut self, runs: &[(u64, u64)], size: u64) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        for (lcn, clusters) in runs {
            if out.len() as u64 >= size {
                break;
            }
            let want = ((size - out.len() as u64).min(clusters * self.cluster_bytes)) as usize;
            let at = lcn * self.cluster_bytes;
            if at + want as u64 > self.dev.len() {
                return Err(Error::OutOfRange);
            }
            out.extend_from_slice(&read_vec(self.dev, at, want)?);
        }
        out.truncate(size as usize);
        Ok(out)
    }

    fn fallback_budget(&mut self, path: &str) -> Result<crate::EditBudget> {
        let (exists, size) = match self.stat(path) {
            Ok(s) => (true, s.size),
            Err(Error::NotFoundPath(_)) => (false, 0),
            Err(e) => return Err(e),
        };
        Ok(crate::EditBudget::refused(
            FsKind::Ntfs,
            size,
            exists,
            "ntfs is read-only here: the $LogFile is missing, dirty, or the device is read-only",
        ))
    }

    /// Rewrite the first two restart pages of `$LogFile` to a clean state.
    /// This does not append a real transaction record; the $LogFile is simply
    /// marked clean so foreign consumers mount the volume read-only.
    fn reset_logfile(&mut self) -> Result<()> {
        let (off, size) = self.logfile.unwrap();
        let page = build_restart_page(0, size, true);
        self.dev.write_at(off, &page)?;
        self.dev.write_at(off + 4096, &page)?;
        Ok(())
    }
}

impl FileSystem for Ntfs<'_> {
    fn kind(&self) -> FsKind {
        FsKind::Ntfs
    }

    fn label(&self) -> String {
        self.label.clone()
    }

    /// Writable when the device says so and `$LogFile` is in a clean state. A
    /// dirty or missing journal is treated as read-only because this BIOS does not
    /// replay foreign log records.
    fn writable(&self) -> bool {
        self.dev_writable && self.log_clean && self.logfile.is_some()
    }

    /// Resident `$DATA` files can be overwritten in place. The $LogFile is reset to
    /// a clean state so the volume remains mountable; this is a bounded BIOS write,
    /// not a full NTFS transaction log.
    fn edit_budget(&mut self, path: &str) -> Result<crate::EditBudget> {
        if !self.writable() {
            return self.fallback_budget(path);
        }
        let (exists, size) = match self.stat(path) {
            Ok(s) => (true, s.size),
            Err(Error::NotFoundPath(_)) => (false, 0),
            Err(e) => return Err(e),
        };
        if !exists {
            // New files are not implemented in this minimal stage.
            return Ok(crate::EditBudget::refused(
                FsKind::Ntfs,
                0,
                false,
                "ntfs: creating a new file requires an MFT slot and parent index update",
            ));
        }
        // Compute the resident-capacity ceiling for this file.
        let r = self.resolve(path)?;
        if r.dir {
            return Ok(crate::EditBudget::refused(
                FsKind::Ntfs,
                size,
                true,
                "ntfs: directories cannot be edited through $DATA",
            ));
        }
        if !r.data_resident {
            return Ok(crate::EditBudget::refused(
                FsKind::Ntfs,
                size,
                true,
                "ntfs: non-resident $DATA is read-only in this BIOS",
            ));
        }
        let Some(attr) = r.data_attr else {
            return self.fallback_budget(path);
        };
        let attr_len = le32(&r.buf, attr + 4) as usize;
        let header = 24usize; // resident attribute header before the value
        let max = attr_len.saturating_sub(header) as u64;
        Ok(crate::EditBudget {
            fs: FsKind::Ntfs,
            exists: true,
            size,
            writable: true,
            max_bytes: Some(max),
            can_create: false,
            can_grow: false,
            why: Some(format!(
                "ntfs resident $DATA overwrite in place, $LogFile reset clean; <= {max}B"
            )),
        })
    }

    fn write(&mut self, path: &str, data: &[u8]) -> Result<()> {
        if !self.writable() {
            return Err(Error::ReadOnly(
                "ntfs: $LogFile missing or dirty, refusing write",
            ));
        }
        let r = self.resolve(path)?;
        if r.dir {
            return Err(Error::IsADir(path.to_string()));
        }
        let Some(attr) = r.data_attr else {
            return Err(Error::Unsupported(format!(
                "ntfs: {path} has no $DATA attribute"
            )));
        };
        if !r.data_resident {
            return Err(Error::Unsupported(format!(
                "ntfs: {path} is non-resident; only resident $DATA can be overwritten"
            )));
        }
        let attr_len = le32(&r.buf, attr + 4) as usize;
        let value_off = le16(&r.buf, attr + 20) as usize;
        let value_len_at = attr + 16;
        let value_start = attr + value_off;
        let max = attr_len.saturating_sub(value_off);
        if data.len() > max {
            return Err(Error::NoSpace);
        }
        let mut buf = r.buf;
        // Update value length, the value bytes, then zero the rest of the value slot.
        buf[value_len_at..value_len_at + 4].copy_from_slice(&(data.len() as u32).to_le_bytes());
        let end = value_start + data.len();
        let slot_end = value_start + max;
        buf[value_start..end].copy_from_slice(data);
        buf[end..slot_end].fill(0);
        // Update the record's in-use size to match the attribute's actual end.
        let used = attr + attr_len;
        if used < buf.len() - 8 {
            // Keep the 0xFFFFFFFF attribute terminator; used_size is after that.
            buf[0x18..0x1C].copy_from_slice(&(used as u32).to_le_bytes());
        }
        // Re-seal the record with the update-sequence fixup.
        fixup_install(&mut buf, 512, 1);
        let off = self.record_off(r.number)?;
        self.dev.write_at(off, &buf)?;
        // Reset $LogFile to a clean state so the volume remains mountable.
        self.reset_logfile()?;
        Ok(())
    }

    fn list(&mut self, path: &str) -> Result<Vec<DirEnt>> {
        let dir = self.resolve(path)?;
        if !dir.dir {
            return Err(Error::NotADir(path.to_string()));
        }
        let all = self.walk()?;
        let mut out: Vec<DirEnt> = all
            .iter()
            .filter(|r| r.parent == dir.number && r.number != dir.number)
            // `$MFT`, `$Volume` and friends are metadata, not the operator's files.
            .filter(|r| !r.name.starts_with('$'))
            .map(|r| DirEnt {
                name: r.name.clone(),
                dir: r.dir,
                size: r.size,
                read_only: !(self.writable() && r.data_resident),
                hidden: false,
            })
            .collect();
        out.sort_by(|a, b| (b.dir, a.name.to_lowercase()).cmp(&(a.dir, b.name.to_lowercase())));
        Ok(out)
    }

    fn stat(&mut self, path: &str) -> Result<Stat> {
        let r = self.resolve(path)?;
        Ok(Stat {
            dir: r.dir,
            size: r.size,
            read_only: !(self.writable() && r.data_resident),
        })
    }

    fn read(&mut self, path: &str) -> Result<Vec<u8>> {
        let r = self.resolve(path)?;
        if r.dir {
            return Err(Error::IsADir(path.to_string()));
        }
        if let Some(res) = r.resident {
            return Ok(res);
        }
        let runs = r.runs.clone();
        self.read_runs(&runs, r.size)
    }
}

/// Apply the NTFS update-sequence-array fixup to an in-place record buffer.
///
/// The record header at offset 0 has `usa_offset` at offset 4 and `usa_size`
/// at offset 6. The first u16 is the USN; the remaining entries hold the
/// original last-two-bytes of each 512-byte sector. The on-disk form has the
/// USN in those tails; this restores the original bytes.
fn fixup_apply(buf: &mut [u8], sector_size: usize) -> Result<()> {
    if buf.len() < 8 {
        return Err(Error::Corrupt("ntfs: record too small for fixup header"));
    }
    let usa_offset = u16::from_le_bytes([buf[4], buf[5]]) as usize;
    let usa_size = u16::from_le_bytes([buf[6], buf[7]]) as usize;
    if usa_size < 2 {
        return Err(Error::Corrupt("ntfs: USA size < 2 (no sectors)"));
    }
    let usa_bytes = usa_size * 2;
    if usa_offset + usa_bytes > buf.len() {
        return Err(Error::Corrupt("ntfs: USA extends past record"));
    }
    let sectors = usa_size - 1;
    if buf.len() < sectors * sector_size {
        return Err(Error::Corrupt(
            "ntfs: record shorter than USA-covered sectors",
        ));
    }
    let usn = [buf[usa_offset], buf[usa_offset + 1]];
    for i in 0..sectors {
        let tail_off = (i + 1) * sector_size - 2;
        if buf[tail_off] != usn[0] || buf[tail_off + 1] != usn[1] {
            return Err(Error::Corrupt("ntfs: USA mismatch (torn write?)"));
        }
        let orig = [buf[usa_offset + 2 + i * 2], buf[usa_offset + 2 + i * 2 + 1]];
        buf[tail_off] = orig[0];
        buf[tail_off + 1] = orig[1];
    }
    Ok(())
}

/// Apply the inverse fixup transform. Place the original last-two-bytes of every
/// sector into the USA, then stamp the USN into those tails. `usn` is normally 1.
fn fixup_install(buf: &mut [u8], sector_size: usize, usn: u16) {
    let usa_offset = u16::from_le_bytes([buf[4], buf[5]]) as usize;
    let usa_size = u16::from_le_bytes([buf[6], buf[7]]) as usize;
    let sectors = usa_size - 1;
    buf[usa_offset] = usn as u8;
    buf[usa_offset + 1] = (usn >> 8) as u8;
    for i in 0..sectors {
        let tail_off = (i + 1) * sector_size - 2;
        let orig = [buf[tail_off], buf[tail_off + 1]];
        buf[usa_offset + 2 + i * 2] = orig[0];
        buf[usa_offset + 2 + i * 2 + 1] = orig[1];
        buf[tail_off] = usn as u8;
        buf[tail_off + 1] = (usn >> 8) as u8;
    }
}

/// Build a 4 KiB restart page (`RSTR` magic) carrying a minimal `RESTART_AREA`
/// plus one `LOG_CLIENT_RECORD` for the NTFS client. The page is USA-fixed-up.
fn parse_restart_page(page: &[u8]) -> Option<(u64, bool)> {
    if page.len() < 4096 || &page[0..4] != b"RSTR" {
        return None;
    }
    let mut buf = page[..4096].to_vec();
    fixup_apply(&mut buf, 512).ok()?;
    let restart_offset = u16::from_le_bytes([buf[0x18], buf[0x19]]) as usize;
    if restart_offset + 0x30 > buf.len() {
        return None;
    }
    let ra = restart_offset;
    let current_lsn = u64::from_le_bytes(buf[ra..ra + 8].try_into().ok()?);
    let flags = u16::from_le_bytes([buf[ra + 14], buf[ra + 15]]);
    let clean = flags & 0x0002 != 0;
    Some((current_lsn, clean))
}

fn build_restart_page(current_lsn: u64, file_size: u64, clean: bool) -> [u8; 4096] {
    const PAGE: usize = 4096;
    const SECTOR: usize = 512;
    let mut page = [0u8; PAGE];
    page[0..4].copy_from_slice(b"RSTR");
    let sectors = PAGE / SECTOR;
    let usa_offset: u16 = 0x1E;
    let usa_count: u16 = (sectors as u16) + 1;
    page[4..6].copy_from_slice(&usa_offset.to_le_bytes());
    page[6..8].copy_from_slice(&usa_count.to_le_bytes());
    // RESTART_PAGE_HEADER at +0x08
    // 0x08 chkdsk_lsn (8) — zero.
    page[0x10..0x14].copy_from_slice(&(PAGE as u32).to_le_bytes());
    page[0x14..0x18].copy_from_slice(&(PAGE as u32).to_le_bytes());
    let restart_offset: u16 = 0x40;
    page[0x18..0x1A].copy_from_slice(&restart_offset.to_le_bytes());
    page[0x1A..0x1C].copy_from_slice(&1i16.to_le_bytes());
    page[0x1C..0x1E].copy_from_slice(&1i16.to_le_bytes());
    // RESTART_AREA at +0x40
    let ra = restart_offset as usize;
    let mut flags = 0u16;
    if clean {
        flags |= 0x0002; // FLAG_CLEAN_DISMOUNT
    }
    page[ra..ra + 8].copy_from_slice(&current_lsn.to_le_bytes());
    page[ra + 8..ra + 10].copy_from_slice(&1u16.to_le_bytes()); // log_clients
    page[ra + 10..ra + 12].copy_from_slice(&0xFFFFu16.to_le_bytes()); // free_list
    page[ra + 12..ra + 14].copy_from_slice(&0u16.to_le_bytes()); // in_use_list
    page[ra + 14..ra + 16].copy_from_slice(&flags.to_le_bytes());
    page[ra + 16..ra + 20].copy_from_slice(&50u32.to_le_bytes()); // seq_number_bits
    page[ra + 20..ra + 22].copy_from_slice(&0xA0u16.to_le_bytes()); // restart_area_length
    page[ra + 22..ra + 24].copy_from_slice(&0x30u16.to_le_bytes()); // client_array_offset
    page[ra + 24..ra + 32].copy_from_slice(&file_size.to_le_bytes());
    // 0x30 record_header_length
    page[ra + 36..ra + 38].copy_from_slice(&0x30u16.to_le_bytes());
    // 0x32 log_page_data_offset
    page[ra + 38..ra + 40].copy_from_slice(&0x40u16.to_le_bytes());
    // LOG_CLIENT_RECORD at +ra+0x30
    let cr = ra + 0x30;
    page[cr + 8..cr + 16].copy_from_slice(&current_lsn.to_le_bytes());
    page[cr + 16..cr + 18].copy_from_slice(&0xFFFFu16.to_le_bytes());
    page[cr + 18..cr + 20].copy_from_slice(&0xFFFFu16.to_le_bytes());
    page[cr + 20..cr + 22].copy_from_slice(&1u16.to_le_bytes());
    page[cr + 28..cr + 32].copy_from_slice(&8u32.to_le_bytes());
    for (i, c) in ['N', 'T', 'F', 'S'].iter().enumerate() {
        let u = *c as u16;
        page[cr + 32 + i * 2..cr + 34 + i * 2].copy_from_slice(&u.to_le_bytes());
    }
    fixup_install(&mut page, SECTOR, 1);
    page
}

/// Decode a run list: each entry is a header byte `(offset_size << 4) | len_size`,
/// then that many little-endian length bytes and *signed* offset-delta bytes.
fn run_list(b: &[u8]) -> Vec<(u64, u64)> {
    let mut out = Vec::new();
    let mut at = 0usize;
    let mut lcn: i64 = 0;
    while at < b.len() && b[at] != 0 {
        let len_size = (b[at] & 0x0F) as usize;
        let off_size = (b[at] >> 4) as usize;
        at += 1;
        if len_size == 0 || at + len_size + off_size > b.len() {
            break;
        }
        let mut length = 0u64;
        for i in 0..len_size {
            length |= u64::from(b[at + i]) << (8 * i);
        }
        at += len_size;
        if off_size == 0 {
            // A sparse run: no LCN. The BIOS reads it as absent rather than
            // pointing at cluster 0.
            at += 0;
            continue;
        }
        let mut delta = 0i64;
        for i in 0..off_size {
            delta |= i64::from(b[at + i]) << (8 * i);
        }
        // Sign-extend from the top byte of the delta.
        let sign_bit = 1i64 << (off_size * 8 - 1);
        if delta & sign_bit != 0 {
            delta -= 1i64 << (off_size * 8);
        }
        at += off_size;
        lcn += delta;
        if lcn >= 0 {
            out.push((lcn as u64, length));
        }
    }
    out
}

fn utf16(b: &[u8]) -> String {
    b.chunks_exact(2)
        .map(|p| u16::from_le_bytes([p[0], p[1]]))
        .take_while(|c| *c != 0)
        .map(|c| char::from_u32(u32::from(c)).unwrap_or('?'))
        .collect()
}

/// A hand-built NTFS volume: boot sector, an MFT with `\`, `\`, the
/// root, a directory and two files (one resident, one in a data run) - with a
/// real update-sequence fixup so the fixup path is exercised.
///
/// `pub` because the kernel's tests mount it and `g6b vfs emit-fs` writes it,
/// the same way `btrfs::fixture` is.
///
/// Capability note that the fs matrix depends on: the only **resident** file
/// here is `bootmgr` (16 bytes). The driver writes resident `\` in place
/// and never grows or creates, so a store export onto this volume is expected
/// to be a *named refusal*, not a success.
pub mod fixture {
    use super::*;
    use crate::block::MemBlock;

    /// The volume as a writable in-memory device.
    pub fn volume() -> MemBlock {
        let bps = 512usize;
        let spc = 1usize;
        let cluster = bps * spc;
        let rec = 1024usize;
        let total = 256usize;
        let mut d = vec![0u8; cluster * total];
        // Boot sector.
        d[3..11].copy_from_slice(b"NTFS    ");
        d[11..13].copy_from_slice(&(bps as u16).to_le_bytes());
        d[13] = spc as u8;
        d[40..48].copy_from_slice(&(total as u64).to_le_bytes());
        d[48..56].copy_from_slice(&16u64.to_le_bytes()); // $MFT at LCN 16
        d[64] = 0xF6; // -10 → 1 << 10 = 1024-byte records
        d[510] = 0x55;
        d[511] = 0xAA;
        let mft = 16 * cluster;

        // Build one record.
        let put_record = |d: &mut Vec<u8>,
                          n: usize,
                          flags: u16,
                          name: &str,
                          parent: u64,
                          data: Option<&[u8]>,
                          runs: Option<(u64, u64, u64)>| {
            let at = mft + n * rec;
            d[at..at + 4].copy_from_slice(b"FILE");
            // Update sequence array right after the 48-byte header.
            d[at + 4..at + 6].copy_from_slice(&48u16.to_le_bytes());
            let usa_count = (rec / 512) + 1;
            d[at + 6..at + 8].copy_from_slice(&(usa_count as u16).to_le_bytes());
            d[at + 20..at + 22].copy_from_slice(&64u16.to_le_bytes()); // attrs off
            d[at + 22..at + 24].copy_from_slice(&flags.to_le_bytes());
            let mut a = at + 64;
            // $FILE_NAME
            if !name.is_empty() {
                let units: Vec<u16> = name.encode_utf16().collect();
                let vlen = 66 + units.len() * 2;
                let alen = (24 + vlen + 7) & !7;
                d[a..a + 4].copy_from_slice(&ATTR_FILE_NAME.to_le_bytes());
                d[a + 4..a + 8].copy_from_slice(&(alen as u32).to_le_bytes());
                d[a + 16..a + 20].copy_from_slice(&(vlen as u32).to_le_bytes());
                d[a + 20..a + 22].copy_from_slice(&24u16.to_le_bytes());
                let v = a + 24;
                d[v..v + 8].copy_from_slice(&parent.to_le_bytes());
                d[v + 64] = units.len() as u8;
                d[v + 65] = 3; // Win32+DOS namespace
                for (i, u) in units.iter().enumerate() {
                    d[v + 66 + i * 2..v + 68 + i * 2].copy_from_slice(&u.to_le_bytes());
                }
                a += alen;
            }
            // $DATA
            match (data, runs) {
                (Some(body), _) => {
                    let vlen = body.len();
                    let alen = (24 + vlen + 7) & !7;
                    d[a..a + 4].copy_from_slice(&ATTR_DATA.to_le_bytes());
                    d[a + 4..a + 8].copy_from_slice(&(alen as u32).to_le_bytes());
                    d[a + 16..a + 20].copy_from_slice(&(vlen as u32).to_le_bytes());
                    d[a + 20..a + 22].copy_from_slice(&24u16.to_le_bytes());
                    d[a + 24..a + 24 + vlen].copy_from_slice(body);
                    a += alen;
                }
                (None, Some((lcn, clusters, size))) => {
                    let rl_off = 64usize;
                    let alen = 128usize;
                    d[a..a + 4].copy_from_slice(&ATTR_DATA.to_le_bytes());
                    d[a + 4..a + 8].copy_from_slice(&(alen as u32).to_le_bytes());
                    d[a + 8] = 1; // non-resident
                    d[a + 24..a + 32].copy_from_slice(&(clusters - 1).to_le_bytes()); // last vcn
                    d[a + 32..a + 34].copy_from_slice(&(rl_off as u16).to_le_bytes());
                    d[a + 48..a + 56].copy_from_slice(&size.to_le_bytes());
                    // One run: 1 length byte, 1 offset byte.
                    let r = a + rl_off;
                    d[r] = 0x11;
                    d[r + 1] = clusters as u8;
                    d[r + 2] = lcn as u8;
                    a += alen;
                }
                _ => {}
            }
            d[a..a + 4].copy_from_slice(&ATTR_END.to_le_bytes());
            d[at + 24..at + 28].copy_from_slice(&((a + 8 - at) as u32).to_le_bytes());
            // Apply the fixup the way NTFS stores it: the last two bytes of each
            // sector are saved into the array and replaced by the sequence number.
            let usn: u16 = 0x0BAD;
            d[at + 48..at + 50].copy_from_slice(&usn.to_le_bytes());
            for i in 1..usa_count {
                let end = at + i * 512 - 2;
                let saved = [d[end], d[end + 1]];
                d[at + 48 + i * 2] = saved[0];
                d[at + 48 + i * 2 + 1] = saved[1];
                d[end..end + 2].copy_from_slice(&usn.to_le_bytes());
            }
        };

        // 0 = $MFT (its own runs: 8 clusters at LCN 16), 2 = $LogFile,
        // 3 = $Volume, 5 = root.
        put_record(
            &mut d,
            0,
            FLAG_IN_USE,
            "$MFT",
            5,
            None,
            Some((16, 32, 32 * 512)),
        );
        let log_lcn = 100u64;
        let log_clusters = 128u64; // 64 KiB
        put_record(
            &mut d,
            2,
            FLAG_IN_USE,
            "$LogFile",
            5,
            None,
            Some((log_lcn, log_clusters, log_clusters * cluster as u64)),
        );
        put_record(&mut d, 3, FLAG_IN_USE, "$Volume", 5, None, None);
        put_record(&mut d, 5, FLAG_IN_USE | FLAG_DIR, ".", 5, None, None);
        // /Windows (dir), /bootmgr (resident), /Windows/notes.txt (data run).
        put_record(&mut d, 6, FLAG_IN_USE | FLAG_DIR, "Windows", 5, None, None);
        put_record(
            &mut d,
            7,
            FLAG_IN_USE,
            "bootmgr",
            5,
            Some(b"BOOTMGR-RESIDENT"),
            None,
        );
        let body = b"windows notes on a data run\n";
        put_record(
            &mut d,
            8,
            FLAG_IN_USE,
            "notes.txt",
            6,
            None,
            Some((64, 1, body.len() as u64)),
        );
        d[64 * cluster..64 * cluster + body.len()].copy_from_slice(body);
        // $LogFile starts with two identical, clean restart pages.
        let log_size = log_clusters * cluster as u64;
        let log_off = (log_lcn as usize) * cluster;
        let restart = build_restart_page(0, log_size, true);
        d[log_off..log_off + 4096].copy_from_slice(&restart);
        d[log_off + 4096..log_off + 8192].copy_from_slice(&restart);
        // $Volume label.
        let vat = mft + 3 * rec;
        let mut a = vat + 64;
        // Skip past the $FILE_NAME we wrote, then append $VOLUME_NAME (0x60).
        while le32(&d, a) != ATTR_END {
            a += le32(&d, a + 4) as usize;
        }
        let label: Vec<u16> = "WINDISK".encode_utf16().collect();
        let vlen = label.len() * 2;
        let alen = (24 + vlen + 7) & !7;
        d[a..a + 4].copy_from_slice(&0x60u32.to_le_bytes());
        d[a + 4..a + 8].copy_from_slice(&(alen as u32).to_le_bytes());
        d[a + 16..a + 20].copy_from_slice(&(vlen as u32).to_le_bytes());
        d[a + 20..a + 22].copy_from_slice(&24u16.to_le_bytes());
        for (i, u) in label.iter().enumerate() {
            d[a + 24 + i * 2..a + 26 + i * 2].copy_from_slice(&u.to_le_bytes());
        }
        d[a + alen..a + alen + 4].copy_from_slice(&ATTR_END.to_le_bytes());
        MemBlock::new(d)
    }

    /// The volume as raw bytes, for `--out` / `VfsService::add_image`.
    pub fn image() -> Vec<u8> {
        volume().into_bytes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ntfs_mounts_and_exposes_writable_resident_files() {
        let mut dev = fixture::volume();
        let fs = Ntfs::mount(&mut dev).unwrap();
        assert_eq!(fs.kind(), FsKind::Ntfs);
        assert_eq!(fs.label(), "WINDISK");
        assert!(
            fs.writable(),
            "a clean $LogFile makes resident files writable"
        );
        assert_eq!(fs.record_bytes, 1024);
        assert_eq!(fs.cluster_bytes, 512);
    }

    #[test]
    fn listing_hides_metadata_and_reads_both_data_shapes() {
        let mut dev = fixture::volume();
        let mut fs = Ntfs::mount(&mut dev).unwrap();
        let root = fs.list("/").unwrap();
        let names: Vec<&str> = root.iter().map(|e| e.name.as_str()).collect();
        assert!(names.contains(&"Windows"), "{names:?}");
        assert!(names.contains(&"bootmgr"), "{names:?}");
        assert!(
            !names.iter().any(|n| n.starts_with('$')),
            "metadata files are not the operator's: {names:?}"
        );
        assert!(root.iter().find(|e| e.name == "Windows").unwrap().dir);
        // Resident data (small file, lives in its MFT record).
        assert_eq!(fs.read("/bootmgr").unwrap(), b"BOOTMGR-RESIDENT");
        // Non-resident data through a run list, inside a subdirectory.
        let win = fs.list("/Windows").unwrap();
        assert_eq!(win.len(), 1);
        assert_eq!(win[0].name, "notes.txt");
        let text = String::from_utf8(fs.read("/Windows/notes.txt").unwrap()).unwrap();
        assert_eq!(text, "windows notes on a data run\n");
        assert_eq!(
            fs.stat("/Windows/notes.txt").unwrap().size,
            text.len() as u64
        );
        // Non-resident files are still read-only.
        let err = fs.write("/Windows/notes.txt", b"x").unwrap_err();
        assert!(err.to_string().contains("non-resident"), "{err}");
        // Resident files can be overwritten in place.
        assert_eq!(fs.edit_budget("/bootmgr").unwrap().max_bytes, Some(16));
        fs.write("/bootmgr", b"BOOTMGR-WRITTEN").unwrap();
        assert_eq!(fs.read("/bootmgr").unwrap(), b"BOOTMGR-WRITTEN");
        // The $LogFile is still clean after the write.
        let reread = Ntfs::mount(&mut dev).unwrap();
        assert!(reread.writable());
    }

    #[test]
    fn run_lists_decode_signed_deltas() {
        // Two runs: +64 then -32 (a backward jump, which real volumes do).
        let b = [0x11, 0x02, 0x40, 0x11, 0x01, 0xE0, 0x00];
        let runs = run_list(&b);
        assert_eq!(runs, vec![(64, 2), (32, 1)]);
        // A sparse run (offset size 0) is skipped, not read from cluster 0.
        let sparse = [0x01, 0x05, 0x00];
        assert!(run_list(&sparse).is_empty());
    }
}
