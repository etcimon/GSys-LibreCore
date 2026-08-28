// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Path-based device-tree mutation.
//!
//! Supports the `--dts-set` and `--dts-del` command-line surface: set a string
//! property at `chosen/bootargs` (or any path), or remove a node or property.
//!
//! Paths are `/`-separated. An initial `/` is ignored. The last component is the
//! property to set or delete; intermediate components are nodes, created if
//! missing.  Deleting a leaf with children deletes the child node; otherwise the
//! property is removed.

use crate::tree::{Node, Prop};

/// Why a mutation could not be applied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MutateError {
    /// The path string was empty.
    EmptyPath,
    /// A path component was empty.
    EmptyComponent,
    /// A `set` value was empty and the property would be lost.
    EmptyValue,
    /// A `set` value could not be parsed as a string or cell list.
    BadValue,
}

impl std::fmt::Display for MutateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MutateError::EmptyPath => write!(f, "path is empty"),
            MutateError::EmptyComponent => write!(f, "path has an empty component"),
            MutateError::EmptyValue => write!(f, "set value is empty"),
            MutateError::BadValue => write!(f, "set value is not a string or cell list"),
        }
    }
}

impl std::error::Error for MutateError {}

fn split_path(path: &str) -> Result<Vec<&str>, MutateError> {
    let path = path.trim();
    if path.is_empty() {
        return Err(MutateError::EmptyPath);
    }
    let path = path.strip_prefix('/').unwrap_or(path);
    let parts: Vec<&str> = path
        .split('/')
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .collect();
    if parts.is_empty() {
        return Err(MutateError::EmptyPath);
    }
    if parts.iter().any(|p| p.is_empty()) {
        return Err(MutateError::EmptyComponent);
    }
    Ok(parts)
}

fn unquote(value: &str) -> String {
    let v = value.trim();
    if v.len() >= 2
        && ((v.starts_with('"') && v.ends_with('"')) || (v.starts_with('\'') && v.ends_with('\'')))
    {
        return v[1..v.len() - 1].to_string();
    }
    v.to_string()
}

fn find_or_create_child<'a>(node: &'a mut Node, name: &str) -> &'a mut Node {
    let pos = node
        .children
        .iter()
        .position(|c| c.name == name)
        .unwrap_or_else(|| {
            node.children.push(Node {
                name: name.to_string(),
                ..Node::default()
            });
            node.children.len() - 1
        });
    &mut node.children[pos]
}

/// Set a property at `path`, creating any missing intermediate nodes.
///
/// Values are interpreted as follows:
/// * `<0x0 0x8000_0000>` → a cell list (numeric).
/// * `"foo"` or `foo` → a single string (matching outer quotes are stripped).
pub fn set(root: &mut Node, path: &str, value: &str) -> Result<(), MutateError> {
    let parts = split_path(path)?;
    if value.is_empty() {
        return Err(MutateError::EmptyValue);
    }
    let mut node = root;
    for part in &parts[..parts.len() - 1] {
        node = find_or_create_child(node, part);
    }
    let prop = parts.last().unwrap();
    node.props.insert(prop.to_string(), parse_value(value)?);
    Ok(())
}

fn parse_value(value: &str) -> Result<Prop, MutateError> {
    let v = value.trim();
    if let Some(inner) = v.strip_prefix('<').and_then(|s| s.strip_suffix('>')) {
        let mut cells = Vec::new();
        for tok in inner.split_whitespace() {
            if tok.is_empty() {
                continue;
            }
            let t = tok.trim_end_matches(',');
            let n = if let Some(hex) = t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) {
                u64::from_str_radix(&hex.replace('_', ""), 16)
            } else {
                t.replace('_', "").parse::<u64>()
            }
            .map_err(|_| MutateError::BadValue)?;
            cells.push(n);
        }
        return Ok(Prop::Cells(cells));
    }
    let s = unquote(v);
    if s.is_empty() {
        return Err(MutateError::EmptyValue);
    }
    Ok(Prop::Strings(vec![s]))
}

/// Merge `overlay` into `base`, creating or overwriting nodes and properties.
///
/// This is a simple structural merge: overlay root children are merged recursively into
/// the corresponding base nodes, and overlay properties overwrite base properties.  It
/// does not resolve phandle references or labels; overlays that rely on those must be
/// pre-processed or use explicit numeric phandles.
pub fn merge(base: &mut Node, overlay: &Node) {
    for (name, prop) in &overlay.props {
        base.props.insert(name.clone(), prop.clone());
    }
    for overlay_child in &overlay.children {
        if let Some(pos) = base
            .children
            .iter()
            .position(|c| c.name == overlay_child.name)
        {
            let base_child = &mut base.children[pos];
            merge(base_child, overlay_child);
        } else {
            base.children.push(overlay_child.clone());
        }
    }
}

/// Remove the node or property at `path`.
pub fn del(root: &mut Node, path: &str) -> Result<bool, MutateError> {
    let parts = split_path(path)?;
    let mut node = root;
    for part in &parts[..parts.len() - 1] {
        let Some(next) = node.children.iter_mut().find(|c| c.name == *part) else {
            return Ok(false);
        };
        node = next;
    }
    let leaf = parts.last().unwrap();
    if let Some(pos) = node.children.iter().position(|c| c.name == *leaf) {
        node.children.remove(pos);
        return Ok(true);
    }
    Ok(node.props.remove(*leaf).is_some())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree::parse;

    #[test]
    fn set_creates_missing_nodes_and_sets_string_property() {
        let mut root = parse("/ { chosen { }; };");
        set(&mut root, "chosen/bootargs", "console=ttyS0").unwrap();
        let chosen = root.child("chosen").unwrap();
        assert_eq!(
            chosen.prop("bootargs").and_then(|p| p.first_string()),
            Some("console=ttyS0")
        );
    }

    #[test]
    fn set_overwrites_existing_property() {
        let mut root = parse("/ { chosen { bootargs = \"old\"; }; };");
        set(&mut root, "/chosen/bootargs", "new").unwrap();
        let chosen = root.child("chosen").unwrap();
        assert_eq!(
            chosen.prop("bootargs").and_then(|p| p.first_string()),
            Some("new")
        );
    }

    #[test]
    fn set_strips_matching_quotes() {
        let mut root = parse("/ { };");
        set(&mut root, "chosen/bootargs", "\"console=ttyS0\"").unwrap();
        let chosen = root.child("chosen").unwrap();
        assert_eq!(
            chosen.prop("bootargs").and_then(|p| p.first_string()),
            Some("console=ttyS0")
        );
    }

    #[test]
    fn set_parses_cell_lists() {
        let mut root = parse("/ { cpus { }; };");
        set(&mut root, "cpus/timebase-frequency", "<10000000>").unwrap();
        let cpus = root.child("cpus").unwrap();
        assert_eq!(
            cpus.prop("timebase-frequency").and_then(|p| p.cells()),
            Some(&[10_000_000][..])
        );
    }

    #[test]
    fn set_cell_list_supports_hex_and_underscores() {
        let mut root = parse("/ { memory@0 { }; };");
        set(
            &mut root,
            "memory@0/reg",
            "<0x0 0x8000_0000 0x0 0x1000_0000>",
        )
        .unwrap();
        let mem = root.child("memory@0").unwrap();
        assert_eq!(
            mem.prop("reg").and_then(|p| p.cells()),
            Some(&[0, 0x8000_0000, 0, 0x1000_0000][..])
        );
    }

    #[test]
    fn del_removes_child_node() {
        let mut root = parse("/ { soc { clint@0 { }; }; };");
        assert!(del(&mut root, "soc/clint@0").unwrap());
        assert!(!root
            .child("soc")
            .unwrap()
            .children
            .iter()
            .any(|c| c.name == "clint@0"));
    }

    #[test]
    fn del_removes_property() {
        let mut root = parse("/ { chosen { bootargs = \"x\"; }; };");
        assert!(del(&mut root, "chosen/bootargs").unwrap());
        assert!(!root.child("chosen").unwrap().has("bootargs"));
    }

    #[test]
    fn del_missing_path_returns_false() {
        let mut root = parse("/ { };");
        assert!(!del(&mut root, "chosen/bootargs").unwrap());
    }

    #[test]
    fn merge_overlay_adds_and_overwrites_nodes_and_properties() {
        let mut base = parse("/ { chosen { bootargs = \"old\"; }; soc { uart { }; }; };");
        let overlay =
            parse("/ { chosen { stdout-path = \"/soc/uart\"; }; soc { clint@0 { }; }; };");
        merge(&mut base, &overlay);
        let chosen = base.child("chosen").unwrap();
        assert_eq!(
            chosen.prop("bootargs").and_then(|p| p.first_string()),
            Some("old")
        );
        assert_eq!(
            chosen.prop("stdout-path").and_then(|p| p.first_string()),
            Some("/soc/uart")
        );
        assert!(base.child("soc").unwrap().child("clint@0").is_some());
    }
}
