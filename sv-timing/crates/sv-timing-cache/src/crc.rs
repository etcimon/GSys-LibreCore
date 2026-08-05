// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// CRC-32C (Castagnoli) hex digests for file content fingerprinting.

//! CRC-32C helpers. Algorithm id stored in cache meta as `crc32c`.

use std::fs;
use std::path::Path;

use crc::{Crc, CRC_32_ISCSI};
use sv_timing_core::{CoreError, CoreResult};

/// CRC algorithm label (DESIGN / meta.crc_algo).
pub const CRC_ALGO: &str = "crc32c";

/// Castagnoli polynomial (iSCSI / CRC-32C).
static CRC32C: Crc<u32> = Crc::<u32>::new(&CRC_32_ISCSI);

/// Compute CRC-32C of `bytes` as lowercase 8-digit hex.
pub fn crc32c_hex(bytes: &[u8]) -> String {
    let mut digest = CRC32C.digest();
    digest.update(bytes);
    format!("{:08x}", digest.finalize())
}

/// Read path and return CRC-32C hex.
pub fn file_crc32c_hex(path: impl AsRef<Path>) -> CoreResult<String> {
    let path = path.as_ref();
    let bytes = fs::read(path).map_err(|source| CoreError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    Ok(crc32c_hex(&bytes))
}

/// File metadata used for cache reconcile.
#[derive(Debug, Clone)]
pub struct FileDigest {
    /// Absolute or caller path string.
    pub path: String,
    /// CRC-32C hex.
    pub crc: String,
    /// Byte length.
    pub size: u64,
    /// Optional mtime nanoseconds since epoch (best-effort).
    pub mtime_ns: Option<i64>,
}

/// Digest every path (read full contents for CRC).
pub fn digest_files(paths: &[impl AsRef<Path>]) -> CoreResult<Vec<FileDigest>> {
    let mut out = Vec::with_capacity(paths.len());
    for p in paths {
        let path = p.as_ref();
        let meta = fs::metadata(path).map_err(|source| CoreError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        let bytes = fs::read(path).map_err(|source| CoreError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        let mtime_ns = meta.modified().ok().and_then(|t| {
            t.duration_since(std::time::UNIX_EPOCH)
                .ok()
                .map(|d| d.as_nanos() as i64)
        });
        out.push(FileDigest {
            path: path.display().to_string(),
            crc: crc32c_hex(&bytes),
            size: bytes.len() as u64,
            mtime_ns,
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc32c_known_empty() {
        // CRC-32C of empty buffer is 0x00000000
        assert_eq!(crc32c_hex(b""), "00000000");
    }

    #[test]
    fn crc32c_stable_on_bytes() {
        let a = crc32c_hex(b"module m; endmodule\n");
        let b = crc32c_hex(b"module m; endmodule\n");
        assert_eq!(a, b);
        assert_eq!(a.len(), 8);
        assert_ne!(a, crc32c_hex(b"module n; endmodule\n"));
    }
}
