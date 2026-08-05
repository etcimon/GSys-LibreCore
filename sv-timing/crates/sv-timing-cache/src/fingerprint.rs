// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// pp_fingerprint and per-module crc_set (SHA-256 hex).

//! Fingerprints for cache keys (DESIGN § Cache design).

use sha2::{Digest, Sha256};

use crate::crc::FileDigest;

/// SHA-256 hex of canonical bytes.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    hex::encode(h.finalize())
}

/// Preprocess / analysis fingerprint over file list + incdirs + defines + versions.
///
/// Canonical serialization (sorted where order is not load-bearing for defines list
/// order already caller-controlled; we sort for stability):
/// ```text
/// files:\n<path>\n...
/// incdirs:\n...
/// defines:\nNAME[=VAL]\n...
/// nested:\n<path>:<crc>\n...
/// parser=<pin>\nir=<ir>\ncost=<model>\n
/// ```
pub fn pp_fingerprint(
    files: &[FileDigest],
    incdirs: &[String],
    defines: &[(String, Option<String>)],
    nested_lists: &[(String, String)],
    parser_version: &str,
    ir_version: &str,
    cost_model: &str,
) -> String {
    let mut body = String::new();
    body.push_str("files:\n");
    let mut paths: Vec<&str> = files.iter().map(|f| f.path.as_str()).collect();
    paths.sort();
    for p in paths {
        body.push_str(p);
        body.push('\n');
    }
    body.push_str("incdirs:\n");
    let mut incs: Vec<&str> = incdirs.iter().map(|s| s.as_str()).collect();
    incs.sort();
    for i in incs {
        body.push_str(i);
        body.push('\n');
    }
    body.push_str("defines:\n");
    let mut defs: Vec<String> = defines
        .iter()
        .map(|(n, v)| match v {
            Some(val) => format!("{n}={val}"),
            None => n.clone(),
        })
        .collect();
    defs.sort();
    for d in defs {
        body.push_str(&d);
        body.push('\n');
    }
    body.push_str("nested:\n");
    let mut nested: Vec<String> = nested_lists
        .iter()
        .map(|(p, c)| format!("{p}:{c}"))
        .collect();
    nested.sort();
    for n in nested {
        body.push_str(&n);
        body.push('\n');
    }
    body.push_str(&format!(
        "parser={parser_version}\nir={ir_version}\ncost={cost_model}\n"
    ));
    sha256_hex(body.as_bytes())
}

/// Per-module `crc_set` = SHA-256 of sorted `path:crc` lines for contributing files.
pub fn module_crc_set(contributing: &[(String, String)]) -> String {
    let mut lines: Vec<String> = contributing
        .iter()
        .map(|(p, c)| format!("{p}:{c}"))
        .collect();
    lines.sort();
    let body = lines.join("\n");
    sha256_hex(body.as_bytes())
}

/// Design-level cache key (all modules for a run configuration).
pub fn design_cache_key(
    pp_fingerprint: &str,
    module_filter: &[String],
    file_crcs: &[(String, String)],
) -> String {
    design_cache_key_ex(pp_fingerprint, module_filter, file_crcs, &[])
}

/// Design key with optional param-map key list (order-insensitive).
pub fn design_cache_key_ex(
    pp_fingerprint: &str,
    module_filter: &[String],
    file_crcs: &[(String, String)],
    param_map_keys: &[String],
) -> String {
    let mut body = String::new();
    body.push_str("pp=");
    body.push_str(pp_fingerprint);
    body.push_str("\nfilter:\n");
    let mut filt: Vec<&str> = module_filter.iter().map(|s| s.as_str()).collect();
    filt.sort();
    if filt.is_empty() {
        body.push_str("*\n");
    } else {
        for m in filt {
            body.push_str(m);
            body.push('\n');
        }
    }
    if !param_map_keys.is_empty() {
        body.push_str("params:\n");
        let mut pk: Vec<&str> = param_map_keys.iter().map(|s| s.as_str()).collect();
        pk.sort();
        for k in pk {
            body.push_str(k);
            body.push('\n');
        }
    }
    body.push_str("crcs:\n");
    let mut crcs: Vec<String> = file_crcs
        .iter()
        .map(|(p, c)| format!("{p}:{c}"))
        .collect();
    crcs.sort();
    for c in crcs {
        body.push_str(&c);
        body.push('\n');
    }
    sha256_hex(body.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crc::FileDigest;

    #[test]
    fn pp_fingerprint_is_path_stable_design_key_tracks_crc() {
        // pp_fingerprint is membership + defines + versions (not content CRC).
        // Content invalidation is via design_key / module crc_set (includes CRCs).
        let f1 = vec![FileDigest {
            path: "a.sv".into(),
            crc: "aaaaaaaa".into(),
            size: 1,
            mtime_ns: None,
        }];
        let f2 = vec![FileDigest {
            path: "a.sv".into(),
            crc: "bbbbbbbb".into(),
            size: 1,
            mtime_ns: None,
        }];
        let a = pp_fingerprint(&f1, &[], &[], &[], "p", "ir", "fo4");
        let b = pp_fingerprint(&f2, &[], &[], &[], "p", "ir", "fo4");
        assert_eq!(a, b, "same file list ⇒ same pp_fingerprint");
        assert_eq!(a.len(), 64);
        let k1 = design_cache_key(&a, &[], &[("a.sv".into(), "aaaaaaaa".into())]);
        let k2 = design_cache_key(&b, &[], &[("a.sv".into(), "bbbbbbbb".into())]);
        assert_ne!(k1, k2, "CRC change must change design_key");
    }

    #[test]
    fn crc_set_order_independent() {
        let a = module_crc_set(&[("b.sv".into(), "1".into()), ("a.sv".into(), "2".into())]);
        let b = module_crc_set(&[("a.sv".into(), "2".into()), ("b.sv".into(), "1".into())]);
        assert_eq!(a, b);
    }
}
