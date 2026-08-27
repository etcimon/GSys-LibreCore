// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Flattened device tree: binary serialisation and parsing.
//!
//! Writing the binary form here removes the external `dtc` dependency. That matters more
//! than it sounds: a device tree is one of the three inputs, the tool must be able to
//! hand one to an emulator, and requiring a separate compiler on every host would make
//! the package's "works standalone" claim conditional on someone else's toolchain.
//!
//! The format is the Devicetree Specification's flattened form (version 17), all fields
//! big-endian: a header, a memory-reservation block, a structure block of tokens, and a
//! string block holding property names.
//!
//! Both directions are implemented so the writer can be round-trip tested against the
//! reader rather than against a golden blob nobody can check by eye.

use std::collections::BTreeMap;

use crate::tree::{Node, Prop};

const MAGIC: u32 = 0xd00d_feed;
const VERSION: u32 = 17;
const LAST_COMP_VERSION: u32 = 16;

const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_NOP: u32 = 4;
const FDT_END: u32 = 9;

/// Why a blob could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BlobError {
    /// The magic number is wrong: this is not a flattened device tree.
    BadMagic(u32),
    /// The version is newer than this reader understands.
    UnsupportedVersion(u32),
    /// The blob ended in the middle of a structure.
    Truncated,
    /// An unrecognised structure token.
    BadToken(u32),
}

impl std::fmt::Display for BlobError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BlobError::BadMagic(m) => write!(f, "not a device tree blob (magic {m:#010x})"),
            BlobError::UnsupportedVersion(v) => write!(f, "unsupported blob version {v}"),
            BlobError::Truncated => write!(f, "blob is truncated"),
            BlobError::BadToken(t) => write!(f, "unrecognised structure token {t:#x}"),
        }
    }
}

impl std::error::Error for BlobError {}

/// How a property's value is laid out in the binary form.
///
/// The source form distinguishes strings from cells syntactically; the binary form does
/// not, so the writer must choose an encoding and the reader must guess one back. The
/// guess is conservative: bytes that look like a printable, null-terminated string list
/// are read as strings, a whole number of 4-byte words as cells, and anything else is
/// kept verbatim.
fn encode_prop(prop: &Prop) -> Vec<u8> {
    match prop {
        Prop::Flag => Vec::new(),
        Prop::Strings(items) => {
            let mut v = Vec::new();
            for s in items {
                v.extend_from_slice(s.as_bytes());
                v.push(0);
            }
            v
        }
        Prop::Cells(cells) => {
            let mut v = Vec::new();
            for c in cells {
                v.extend_from_slice(&(*c as u32).to_be_bytes());
            }
            v
        }
        Prop::Other(text) => {
            let mut v = text.as_bytes().to_vec();
            v.push(0);
            v
        }
    }
}

fn decode_prop(bytes: &[u8]) -> Prop {
    if bytes.is_empty() {
        return Prop::Flag;
    }
    let printable_strings = bytes.last() == Some(&0)
        && bytes[..bytes.len() - 1]
            .iter()
            .all(|b| *b == 0 || (0x20..0x7f).contains(b));
    if printable_strings {
        let items: Vec<String> = bytes[..bytes.len() - 1]
            .split(|b| *b == 0)
            .map(|s| String::from_utf8_lossy(s).to_string())
            .collect();
        if items.iter().all(|s| !s.is_empty()) {
            return Prop::Strings(items);
        }
    }
    if bytes.len() % 4 == 0 {
        let cells = bytes
            .chunks_exact(4)
            .map(|c| u32::from_be_bytes([c[0], c[1], c[2], c[3]]) as u64)
            .collect();
        return Prop::Cells(cells);
    }
    Prop::Other(
        String::from_utf8_lossy(bytes)
            .trim_end_matches('\0')
            .to_string(),
    )
}

fn pad4(v: &mut Vec<u8>) {
    while v.len() % 4 != 0 {
        v.push(0);
    }
}

/// String-block builder that de-duplicates property names.
#[derive(Default)]
struct Strings {
    bytes: Vec<u8>,
    offsets: BTreeMap<String, u32>,
}

impl Strings {
    fn intern(&mut self, name: &str) -> u32 {
        if let Some(off) = self.offsets.get(name) {
            return *off;
        }
        let off = self.bytes.len() as u32;
        self.bytes.extend_from_slice(name.as_bytes());
        self.bytes.push(0);
        self.offsets.insert(name.to_string(), off);
        off
    }
}

/// Serialise a tree to its flattened binary form.
///
/// `boot_cpuid` goes in the header; `reservations` are `(address, size)` pairs of memory
/// the operating system must not use.
pub fn to_blob(root: &Node, boot_cpuid: u32, reservations: &[(u64, u64)]) -> Vec<u8> {
    let mut strings = Strings::default();
    let mut structure: Vec<u8> = Vec::new();
    write_node(root, &mut structure, &mut strings, true);
    structure.extend_from_slice(&FDT_END.to_be_bytes());

    let mut rsv: Vec<u8> = Vec::new();
    for (addr, size) in reservations {
        rsv.extend_from_slice(&addr.to_be_bytes());
        rsv.extend_from_slice(&size.to_be_bytes());
    }
    rsv.extend_from_slice(&0u64.to_be_bytes());
    rsv.extend_from_slice(&0u64.to_be_bytes());

    const HEADER: usize = 40;
    let off_rsv = HEADER;
    let off_struct = off_rsv + rsv.len();
    let off_strings = off_struct + structure.len();
    let total = off_strings + strings.bytes.len();

    let mut out = Vec::with_capacity(total);
    for word in [
        MAGIC,
        total as u32,
        off_struct as u32,
        off_strings as u32,
        off_rsv as u32,
        VERSION,
        LAST_COMP_VERSION,
        boot_cpuid,
        strings.bytes.len() as u32,
        structure.len() as u32,
    ] {
        out.extend_from_slice(&word.to_be_bytes());
    }
    out.extend_from_slice(&rsv);
    out.extend_from_slice(&structure);
    out.extend_from_slice(&strings.bytes);
    out
}

fn write_node(node: &Node, out: &mut Vec<u8>, strings: &mut Strings, is_root: bool) {
    out.extend_from_slice(&FDT_BEGIN_NODE.to_be_bytes());
    // The root node's name is empty in the binary form.
    let name = if is_root { "" } else { node.name.as_str() };
    out.extend_from_slice(name.as_bytes());
    out.push(0);
    pad4(out);

    for (key, prop) in &node.props {
        let value = encode_prop(prop);
        let nameoff = strings.intern(key);
        out.extend_from_slice(&FDT_PROP.to_be_bytes());
        out.extend_from_slice(&(value.len() as u32).to_be_bytes());
        out.extend_from_slice(&nameoff.to_be_bytes());
        out.extend_from_slice(&value);
        pad4(out);
    }
    for child in &node.children {
        write_node(child, out, strings, false);
    }
    out.extend_from_slice(&FDT_END_NODE.to_be_bytes());
}

/// Parse a flattened binary tree back into nodes.
pub fn from_blob(bytes: &[u8]) -> Result<Node, BlobError> {
    let word = |off: usize| -> Result<u32, BlobError> {
        bytes
            .get(off..off + 4)
            .map(|c| u32::from_be_bytes([c[0], c[1], c[2], c[3]]))
            .ok_or(BlobError::Truncated)
    };
    let magic = word(0)?;
    if magic != MAGIC {
        return Err(BlobError::BadMagic(magic));
    }
    let off_struct = word(8)? as usize;
    let off_strings = word(12)? as usize;
    let version = word(20)?;
    if version > VERSION {
        return Err(BlobError::UnsupportedVersion(version));
    }
    let size_struct = word(36)? as usize;

    let structure = bytes
        .get(off_struct..off_struct + size_struct)
        .ok_or(BlobError::Truncated)?;
    let strings = bytes.get(off_strings..).ok_or(BlobError::Truncated)?;

    let mut pos = 0usize;
    let mut stack: Vec<Node> = Vec::new();
    let mut root: Option<Node> = None;

    while pos + 4 <= structure.len() {
        let token = u32::from_be_bytes([
            structure[pos],
            structure[pos + 1],
            structure[pos + 2],
            structure[pos + 3],
        ]);
        pos += 4;
        match token {
            FDT_NOP => {}
            FDT_END => break,
            FDT_BEGIN_NODE => {
                let start = pos;
                while pos < structure.len() && structure[pos] != 0 {
                    pos += 1;
                }
                let name = String::from_utf8_lossy(&structure[start..pos]).to_string();
                pos = (pos + 1).div_ceil(4) * 4;
                stack.push(Node {
                    name: if name.is_empty() { "/".into() } else { name },
                    ..Node::default()
                });
            }
            FDT_END_NODE => {
                let done = stack.pop().ok_or(BlobError::Truncated)?;
                match stack.last_mut() {
                    Some(parent) => parent.children.push(done),
                    None => root = Some(done),
                }
            }
            FDT_PROP => {
                let len = u32::from_be_bytes([
                    structure[pos],
                    structure[pos + 1],
                    structure[pos + 2],
                    structure[pos + 3],
                ]) as usize;
                let nameoff = u32::from_be_bytes([
                    structure[pos + 4],
                    structure[pos + 5],
                    structure[pos + 6],
                    structure[pos + 7],
                ]) as usize;
                pos += 8;
                let value = structure.get(pos..pos + len).ok_or(BlobError::Truncated)?;
                pos = (pos + len).div_ceil(4) * 4;

                let name_end = strings[nameoff..]
                    .iter()
                    .position(|b| *b == 0)
                    .ok_or(BlobError::Truncated)?;
                let name =
                    String::from_utf8_lossy(&strings[nameoff..nameoff + name_end]).to_string();
                if let Some(node) = stack.last_mut() {
                    node.props.insert(name, decode_prop(value));
                }
            }
            other => return Err(BlobError::BadToken(other)),
        }
    }
    root.ok_or(BlobError::Truncated)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree::parse;

    const SRC: &str = r#"
/dts-v1/;
/ {
  #address-cells = <2>;
  #size-cells = <2>;
  compatible = "vendor,board", "generic";
  cpus {
    cpu@0 {
      device_type = "cpu";
      reg = <0>;
      riscv,isa-extensions = "i", "m", "a", "zacas";
      mmu-type = "riscv,sv39";
      tlb-split;
    };
  };
  memory@80000000 { reg = <0x0 0x80000000 0x0 0x40000000>; };
};
"#;

    #[test]
    fn the_header_is_well_formed() {
        let blob = to_blob(&parse(SRC), 0, &[]);
        assert_eq!(u32::from_be_bytes(blob[0..4].try_into().unwrap()), MAGIC);
        let total = u32::from_be_bytes(blob[4..8].try_into().unwrap()) as usize;
        assert_eq!(total, blob.len(), "declared total size must match the blob");
        assert_eq!(
            u32::from_be_bytes(blob[20..24].try_into().unwrap()),
            VERSION
        );
    }

    #[test]
    fn a_tree_round_trips_through_the_binary_form() {
        let original = parse(SRC);
        let back = from_blob(&to_blob(&original, 0, &[])).expect("parses");

        let cpu = back
            .child("cpus")
            .and_then(|c| c.child("cpu@0"))
            .expect("cpu node survived");
        assert_eq!(
            cpu.prop("riscv,isa-extensions").unwrap().strings().unwrap(),
            ["i", "m", "a", "zacas"]
        );
        // The case that would break a naive encoder: a vendor-prefixed single string.
        assert_eq!(
            cpu.prop("mmu-type").unwrap().first_string(),
            Some("riscv,sv39")
        );
        assert_eq!(cpu.prop("tlb-split"), Some(&Prop::Flag));
        assert_eq!(
            back.child("memory@80000000")
                .unwrap()
                .prop("reg")
                .unwrap()
                .cells(),
            Some(&[0u64, 0x8000_0000, 0, 0x4000_0000][..])
        );
        assert_eq!(
            back.prop("compatible").unwrap().strings().unwrap(),
            ["vendor,board", "generic"]
        );
    }

    #[test]
    fn serialisation_is_deterministic() {
        let root = parse(SRC);
        assert_eq!(to_blob(&root, 0, &[]), to_blob(&root, 0, &[]));
    }

    #[test]
    fn property_names_are_interned_once() {
        // `reg` appears twice in the source; the string block must hold one copy.
        let blob = to_blob(&parse(SRC), 0, &[]);
        let off_strings = u32::from_be_bytes(blob[12..16].try_into().unwrap()) as usize;
        let strings = &blob[off_strings..];
        let count = strings.split(|b| *b == 0).filter(|s| s == b"reg").count();
        assert_eq!(count, 1, "property names must be de-duplicated");
    }

    #[test]
    fn memory_reservations_are_written_and_terminated() {
        let blob = to_blob(&parse(SRC), 0, &[(0x8000_0000, 0x1000)]);
        let off_rsv = u32::from_be_bytes(blob[16..20].try_into().unwrap()) as usize;
        let addr = u64::from_be_bytes(blob[off_rsv..off_rsv + 8].try_into().unwrap());
        let size = u64::from_be_bytes(blob[off_rsv + 8..off_rsv + 16].try_into().unwrap());
        assert_eq!((addr, size), (0x8000_0000, 0x1000));
        let term = u64::from_be_bytes(blob[off_rsv + 16..off_rsv + 24].try_into().unwrap());
        assert_eq!(term, 0, "the reservation list must be zero-terminated");
    }

    #[test]
    fn boot_cpuid_is_carried() {
        let blob = to_blob(&parse(SRC), 3, &[]);
        assert_eq!(u32::from_be_bytes(blob[28..32].try_into().unwrap()), 3);
    }

    #[test]
    fn a_non_blob_is_rejected_rather_than_misread() {
        let err = from_blob(b"not a device tree at all").unwrap_err();
        assert!(matches!(err, BlobError::BadMagic(_)), "{err}");
    }

    #[test]
    fn a_truncated_blob_is_rejected() {
        let blob = to_blob(&parse(SRC), 0, &[]);
        let err = from_blob(&blob[..20]).unwrap_err();
        assert!(
            matches!(err, BlobError::Truncated | BlobError::BadMagic(_)),
            "{err}"
        );
    }
}
