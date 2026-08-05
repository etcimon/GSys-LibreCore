// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// CRC-32C + SQLite cache for timing IR (partial rebuild). No CST blobs.

#![deny(missing_docs)]
#![forbid(unsafe_code)]

//! # sv-timing-cache
//!
//! IR-only SQLite cache keyed by CRC-32C file digests and `pp_fingerprint`.
//! See `architecture/DESIGN.md` § Cache design.
//!
//! - **Design hit** → skip parse/lower entirely.
//! - **Miss** → full reparse of the contributing file set, then store modules + design.

pub mod analyze_cache;
pub mod crc;
pub mod fingerprint;
pub mod pathkey;
pub mod store;

pub use analyze_cache::{analyze_with_cache, CachedAnalyzeOutput};
pub use pathkey::{CanonPath, PathIndex};
pub use crc::{crc32c_hex, digest_files, file_crc32c_hex, FileDigest, CRC_ALGO};
pub use fingerprint::{design_cache_key, module_crc_set, pp_fingerprint, sha256_hex};
pub use store::{
    compute_design_key, compute_pp_fingerprint, crc_set_for_file, CacheConfig, CacheCounts,
    CacheStats, ModuleIrBlob, TimingCache, CACHE_SCHEMA_VERSION,
};
pub use sv_timing_core::IR_VERSION;

/// Report which IR version this cache expects.
pub fn expected_ir_version() -> &'static str {
    IR_VERSION
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ir_version_nonzero() {
        assert!(!expected_ir_version().is_empty());
    }
}
