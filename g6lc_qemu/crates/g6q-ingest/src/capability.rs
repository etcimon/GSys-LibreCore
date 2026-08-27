// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! The capability table: what to look for in each of the three inputs.
//!
//! The table is **data**, loaded from `data/capabilities.ini` (embedded by default,
//! overridable at run time). It lives in a file rather than in this crate because the
//! mapping is design-specific — field names, source-path fragments and device-tree
//! tokens all belong to a particular design. Burning them into the emulator would make
//! the package usable against exactly one tree and would put design constants in code,
//! which is the defect this package exists to avoid.

use std::collections::BTreeMap;

/// The default table, shipped with the package.
pub const DEFAULT_TABLE: &str = include_str!("../data/capabilities.ini");

/// Where a capability's enable bit lives in the configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigProbe {
    /// A top-level field.
    Field(String),
    /// A field of a nested struct, written `Outer.Inner`.
    Nested(String, String),
}

impl ConfigProbe {
    fn parse(spec: &str) -> Self {
        match spec.split_once('.') {
            Some((o, i)) => ConfigProbe::Nested(o.trim().into(), i.trim().into()),
            None => ConfigProbe::Field(spec.trim().into()),
        }
    }

    /// How the probe reads in a report.
    pub fn describe(&self) -> String {
        match self {
            ConfigProbe::Field(f) => f.clone(),
            ConfigProbe::Nested(o, i) => format!("{o}.{i}"),
        }
    }
}

/// How to tell whether the implementing RTL is compiled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FlistProbe {
    /// No separate compilation unit: present whenever the configuration enables it.
    ///
    /// Most extensions are intrinsic — they live in the decoder and the register file,
    /// which are always compiled. Claiming otherwise would produce false `stub` verdicts.
    Intrinsic,
    /// Present when one of `implementing` is compiled; `stubs` indicate a placeholder.
    Unit {
        /// Path fragments proving the real unit is in the build.
        implementing: Vec<String>,
        /// Path fragments indicating a placeholder instead.
        stubs: Vec<String>,
    },
}

/// One capability's probes across the three inputs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Capability {
    /// Report name.
    pub name: String,
    /// Configuration probe.
    pub config: ConfigProbe,
    /// Compilation probe.
    pub flist: FlistProbe,
    /// Device-tree extension tokens that advertise this capability.
    pub dts_tokens: Vec<String>,
    /// Device-tree node base name that advertises this capability, if any.
    pub dts_node: Option<String>,
    /// Stock-QEMU `-cpu` properties.
    ///
    /// `None` means "same as the device-tree tokens", which is true of most extensions.
    /// `Some(empty)` means the stock model cannot express it at all — and that gap is
    /// precisely what the B0 capability delta exists to report.
    pub qemu_props: Option<Vec<String>>,
}

impl Capability {
    /// The stock-QEMU properties this capability maps to.
    pub fn qemu_properties(&self) -> &[String] {
        match &self.qemu_props {
            Some(v) => v,
            None => &self.dts_tokens,
        }
    }

    /// Whether a stock model can express this capability at all.
    pub fn expressible_in_stock_qemu(&self) -> bool {
        !self.qemu_properties().is_empty()
    }
}

/// A parsed capability table.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Table {
    /// Capabilities in declaration order.
    pub entries: Vec<Capability>,
}

impl Table {
    /// The table shipped with the package.
    pub fn default_table() -> Table {
        parse(DEFAULT_TABLE)
    }

    /// Look up by name.
    pub fn get(&self, name: &str) -> Option<&Capability> {
        self.entries.iter().find(|c| c.name == name)
    }

    /// Number of capabilities.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether the table is empty.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// Parse a capability table.
///
/// Unknown keys are ignored rather than rejected, so a table written for a newer version
/// of the tool still loads. A section with no `config` key is skipped: without an enable
/// bit there is nothing to compare the other two inputs against.
pub fn parse(text: &str) -> Table {
    let mut table = Table::default();
    let mut name: Option<String> = None;
    let mut fields: BTreeMap<String, String> = BTreeMap::new();

    let flush =
        |name: &mut Option<String>, fields: &mut BTreeMap<String, String>, table: &mut Table| {
            let Some(n) = name.take() else {
                fields.clear();
                return;
            };
            let Some(cfg) = fields.get("config") else {
                fields.clear();
                return;
            };
            let implementing = list(fields.get("impl").map(String::as_str), ';');
            let stubs = list(fields.get("stub").map(String::as_str), ';');
            let flist = if implementing.is_empty() {
                FlistProbe::Intrinsic
            } else {
                FlistProbe::Unit {
                    implementing,
                    stubs,
                }
            };
            table.entries.push(Capability {
                name: n,
                config: ConfigProbe::parse(cfg),
                flist,
                dts_tokens: list(fields.get("dts").map(String::as_str), ','),
                dts_node: fields.get("node").map(|s| s.trim().to_string()),
                // A bare `-` means "not expressible", which is distinct from
                // "unspecified": the first is a fact worth reporting, the second falls
                // back to the device-tree tokens.
                qemu_props: fields.get("qemu").map(|s| {
                    if s.trim() == "-" {
                        Vec::new()
                    } else {
                        list(Some(s.as_str()), ',')
                    }
                }),
            });
            fields.clear();
        };

    for raw in text.lines() {
        let line = raw.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        if let Some(section) = line.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
            flush(&mut name, &mut fields, &mut table);
            name = Some(section.trim().to_string());
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            fields.insert(k.trim().to_lowercase(), v.trim().to_string());
        }
    }
    flush(&mut name, &mut fields, &mut table);
    table
}

/// Split a separated list, tolerating both `,` and `;` and dropping empties.
fn list(value: Option<&str>, sep: char) -> Vec<String> {
    value
        .unwrap_or("")
        .split([sep, ',', ';'])
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_default_table_loads_and_is_substantial() {
        let t = Table::default_table();
        assert!(t.len() > 20, "only {} capabilities", t.len());
        assert!(t.get("vector").is_some());
        assert!(t.get("hypervisor").is_some());
        assert!(t.get("matrix-accelerator").is_some());
    }

    #[test]
    fn a_capability_with_no_impl_is_intrinsic() {
        // Most extensions live in always-compiled logic. Treating them as separately
        // compiled units would produce a stub verdict for every one of them.
        let t = Table::default_table();
        assert_eq!(t.get("cas-atomics").unwrap().flist, FlistProbe::Intrinsic);
    }

    #[test]
    fn a_separately_compiled_unit_records_both_impl_and_stub_evidence() {
        let t = Table::default_table();
        match &t.get("vector").unwrap().flist {
            FlistProbe::Unit {
                implementing,
                stubs,
            } => {
                assert!(!implementing.is_empty());
                assert!(
                    !stubs.is_empty(),
                    "the stub marker is what makes `stub` detectable"
                );
            }
            other => panic!("expected a compiled unit, got {other:?}"),
        }
    }

    #[test]
    fn nested_configuration_probes_parse() {
        let t = Table::default_table();
        assert_eq!(
            t.get("matrix-accelerator").unwrap().config,
            ConfigProbe::Nested("AiCfg".into(), "MatrixEn".into())
        );
    }

    #[test]
    fn device_tree_tokens_and_nodes_parse() {
        let t = Table::default_table();
        let v = t.get("vector").unwrap();
        assert!(v.dts_tokens.contains(&"v".to_string()));
        assert!(v.dts_tokens.contains(&"zve64d".to_string()));
        let ai = t.get("matrix-accelerator").unwrap();
        assert_eq!(ai.dts_node.as_deref(), Some("ai-matrix"));
    }

    #[test]
    fn a_section_without_a_config_key_is_skipped() {
        // Nothing to compare the other inputs against.
        let t = parse("[broken]\ndts = x\n[good]\nconfig = A\n");
        assert!(t.get("broken").is_none());
        assert!(t.get("good").is_some());
    }

    #[test]
    fn comments_and_unknown_keys_are_tolerated() {
        let t = parse("# lead\n[a]\nconfig = A  # trailing\nfuture_key = whatever\n");
        assert_eq!(t.len(), 1);
        assert_eq!(t.get("a").unwrap().config, ConfigProbe::Field("A".into()));
    }

    #[test]
    fn parsing_is_deterministic() {
        assert_eq!(Table::default_table(), Table::default_table());
    }
}
