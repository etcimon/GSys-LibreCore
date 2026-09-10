// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use crate::error::StoreError;
use g6b_spec::store_purpose_ok;
use std::fmt;

/// RFC 4122 UUID, display lowercase 8-4-4-4-12. Nil is refused as an instance id.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct StoreUuid(pub [u8; 16]);

impl StoreUuid {
    pub fn parse(s: &str) -> Result<Self, StoreError> {
        let s = s.trim();
        let mut hex = String::with_capacity(32);
        for (i, c) in s.chars().enumerate() {
            if c == '-' {
                if !matches!(i, 8 | 13 | 18 | 23) {
                    return Err(StoreError::syntax("uuid"));
                }
                continue;
            }
            if !c.is_ascii_hexdigit() {
                return Err(StoreError::syntax("uuid"));
            }
            hex.push(c.to_ascii_lowercase());
        }
        if hex.len() != 32 {
            return Err(StoreError::syntax("uuid"));
        }
        let mut out = [0u8; 16];
        for i in 0..16 {
            out[i] = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16)
                .map_err(|_| StoreError::syntax("uuid"))?;
        }
        let id = Self(out);
        if id.is_nil() {
            return Err(StoreError::syntax("uuid nil"));
        }
        Ok(id)
    }

    pub fn is_nil(self) -> bool {
        self.0.iter().all(|&b| b == 0)
    }

    pub fn hyphenated(self) -> String {
        let b = self.0;
        format!(
            "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12],
            b[13], b[14], b[15]
        )
    }
}

impl fmt::Display for StoreUuid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.hyphenated())
    }
}

impl fmt::Debug for StoreUuid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.hyphenated())
    }
}

/// Allow-listed short name. BIOS UI asks for this, not a uuid.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Purpose(pub String);

impl Purpose {
    pub fn parse(s: &str) -> Result<Self, StoreError> {
        if store_purpose_ok(s) {
            Ok(Self(s.to_string()))
        } else {
            Err(StoreError::CapDenied)
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Purpose {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// Parsed `dataDir` / StoreOpen argument.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DataDir {
    Purpose(Purpose),
    Uuid(StoreUuid),
    Elf(Purpose),
    Usb { volume: String, rel: String },
}

impl DataDir {
    pub fn parse(s: &str) -> Result<Self, StoreError> {
        let s = s.trim();
        if s.is_empty() {
            return Purpose::parse("registry").map(Self::Purpose);
        }
        let lower = s.to_ascii_lowercase();
        if lower.starts_with("idb://")
            || lower.starts_with("file://")
            || lower.starts_with("http://")
            || lower.starts_with("https://")
        {
            return Err(StoreError::CapDenied);
        }
        if let Some(rest) = s.strip_prefix("memory://") {
            return parse_path_name(rest);
        }
        if let Some(rest) = s.strip_prefix("elf://") {
            let name = if rest.is_empty() { "registry" } else { rest };
            return Purpose::parse(name).map(Self::Elf);
        }
        if let Some(rest) = s.strip_prefix("usb://") {
            let (volume, rel) = match rest.split_once('/') {
                Some((v, r)) => (v.to_string(), r.to_string()),
                None => (rest.to_string(), String::new()),
            };
            if volume.is_empty() {
                return Err(StoreError::syntax("usb dataDir"));
            }
            return Ok(Self::Usb { volume, rel });
        }
        if s.contains('-') && StoreUuid::parse(s).is_ok() {
            return StoreUuid::parse(s).map(Self::Uuid);
        }
        Purpose::parse(s).map(Self::Purpose)
    }
}

/// Name in the path after `memory://` / as a USB rel: purpose, uuid, or empty → registry.
fn parse_path_name(s: &str) -> Result<DataDir, StoreError> {
    let s = s.trim();
    if s.is_empty() {
        return Purpose::parse("registry").map(DataDir::Purpose);
    }
    if s.contains('-') {
        if let Ok(u) = StoreUuid::parse(s) {
            return Ok(DataDir::Uuid(u));
        }
    }
    Purpose::parse(s).map(DataDir::Purpose)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn data_dir_names_the_store_in_the_path() {
        let registry = Purpose::parse("registry").unwrap();
        assert_eq!(
            DataDir::parse("memory://registry").unwrap(),
            DataDir::Purpose(registry.clone())
        );
        assert_eq!(
            DataDir::parse("memory://").unwrap(),
            DataDir::Purpose(registry.clone())
        );
        assert_eq!(
            DataDir::parse("usb://fat32/registry").unwrap(),
            DataDir::Usb {
                volume: "fat32".into(),
                rel: "registry".into(),
            }
        );
        let u = "00000000-0000-4000-8000-000000000001";
        match DataDir::parse(&format!("memory://{u}")).unwrap() {
            DataDir::Uuid(id) => assert_eq!(id.hyphenated(), u),
            other => panic!("{other:?}"),
        }
        match DataDir::parse(&format!("usb://ntfs/{u}")).unwrap() {
            DataDir::Usb { volume, rel } => {
                assert_eq!(volume, "ntfs");
                assert_eq!(rel, u);
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(DataDir::parse("elf://").unwrap(), DataDir::Elf(registry));
    }
}
