// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Naming conventions, mangling, unique allocation for multi-pass expand/emit.

//! Name allocation and mangling used by expand, pipeline, and emit.
//! See `architecture/AUTO-CORRECT-CORE-API.md` §3.3.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::ir::{ModuleId, SignalId};
use crate::loc::SourceLoc;

/// How to form safe SystemVerilog identifiers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MangleStyle {
    /// Prefix illegal starts; replace bad chars with `_`.
    #[default]
    SafeIdent,
}

/// Naming policy for auto-correct expansions.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NamePolicy {
    /// Prefix for tool-generated names.
    pub tool_prefix: String,
    /// Pipeline stage infix.
    pub pipe_infix: String,
    /// Split-wire infix.
    pub wire_infix: String,
    /// Expanded module infix.
    pub expand_infix: String,
    /// Emit file suffix before `.sv`.
    pub file_suffix: String,
}

impl Default for NamePolicy {
    fn default() -> Self {
        Self::default_sv_timing()
    }
}

impl NamePolicy {
    /// Default conventions: `svt_`, `_pN_`, `_w`, `__svt`.
    pub fn default_sv_timing() -> Self {
        Self {
            tool_prefix: "svt_".into(),
            pipe_infix: "_p".into(),
            wire_infix: "_w".into(),
            expand_infix: "_x".into(),
            file_suffix: "__svt".into(),
        }
    }
}

/// Origin of an allocated name (for demangle / comments).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NameOrigin {
    /// Allocated identifier.
    pub name: String,
    /// Original source locus that justified creation.
    pub origin: SourceLoc,
    /// Kind tag.
    pub kind: NameKind,
}

/// Kind of allocated name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NameKind {
    /// Signal / wire / reg.
    Signal,
    /// Module.
    Module,
    /// File path stem.
    File,
}

/// Unique name allocator for a design pass.
#[derive(Debug, Clone, Default)]
pub struct NameTable {
    /// Policy.
    pub policy: NamePolicy,
    /// Names already taken (global + per-scope keys `"scope::name"`).
    taken: BTreeSet<String>,
    /// Allocated signal origins.
    signals: BTreeMap<SignalId, NameOrigin>,
    /// Allocated module origins.
    modules: BTreeMap<ModuleId, NameOrigin>,
    /// Next signal id.
    next_signal: SignalId,
    /// Next module id.
    next_module: ModuleId,
    /// Reverse map name → id for signals (debug).
    by_name: BTreeMap<String, SignalId>,
}

impl NameTable {
    /// Empty table with default policy.
    pub fn new() -> Self {
        Self {
            policy: NamePolicy::default_sv_timing(),
            ..Default::default()
        }
    }

    /// Reserve an existing source name so allocators do not collide.
    pub fn reserve(&mut self, scope: &str, name: &str) {
        self.taken.insert(scope_key(scope, name));
        self.taken.insert(name.to_string());
    }

    /// Allocate a unique signal name in `scope` from `stem`.
    ///
    /// Pattern: `{stem}_svt_p{stage}` or `{stem}_svt_w{n}` depending on `kind_tag`.
    pub fn alloc_signal(
        &mut self,
        scope: &str,
        stem: &str,
        kind_tag: SignalNameTag,
        origin: SourceLoc,
    ) -> (SignalId, String) {
        let base = match kind_tag {
            SignalNameTag::Pipeline { stage } => format!("{stem}_svt_p{stage}"),
            SignalNameTag::SplitWire { index } => format!("{stem}_svt_w{index}"),
        };
        let name = self.unique_in_scope(scope, &mangle_identifier(&base, MangleStyle::SafeIdent));
        let id = self.next_signal;
        self.next_signal += 1;
        self.taken.insert(scope_key(scope, &name));
        self.taken.insert(name.clone());
        self.signals.insert(
            id,
            NameOrigin {
                name: name.clone(),
                origin,
                kind: NameKind::Signal,
            },
        );
        self.by_name.insert(name.clone(), id);
        (id, name)
    }

    /// Allocate a unique module name.
    pub fn alloc_module(&mut self, stem: &str, origin: SourceLoc) -> (ModuleId, String) {
        let base = format!("{stem}_svt_x");
        let name = self.unique_global(&mangle_identifier(&base, MangleStyle::SafeIdent));
        let id = self.next_module;
        self.next_module += 1;
        self.taken.insert(name.clone());
        self.modules.insert(
            id,
            NameOrigin {
                name: name.clone(),
                origin,
                kind: NameKind::Module,
            },
        );
        (id, name)
    }

    /// Allocate a logical emit file path stem (caller adds directories).
    pub fn alloc_file_stem(&mut self, stem: &str) -> String {
        let base = format!("{stem}{}", self.policy.file_suffix);
        self.unique_global(&mangle_identifier(&base, MangleStyle::SafeIdent))
    }

    /// Lookup origin for a mangled/allocated name.
    pub fn demangle_trace(&self, name: &str) -> Option<&NameOrigin> {
        self.by_name
            .get(name)
            .and_then(|id| self.signals.get(id))
            .or_else(|| self.modules.values().find(|o| o.name == name))
    }

    fn unique_in_scope(&self, scope: &str, base: &str) -> String {
        if !self.taken.contains(&scope_key(scope, base)) && !self.taken.contains(base) {
            return base.to_string();
        }
        let mut n = 0u32;
        loop {
            let cand = format!("{base}_{n}");
            if !self.taken.contains(&scope_key(scope, &cand)) && !self.taken.contains(&cand) {
                return cand;
            }
            n += 1;
        }
    }

    fn unique_global(&self, base: &str) -> String {
        if !self.taken.contains(base) {
            return base.to_string();
        }
        let mut n = 0u32;
        loop {
            let cand = format!("{base}{n}");
            if !self.taken.contains(&cand) {
                return cand;
            }
            n += 1;
        }
    }
}

/// Tag for signal naming pattern.
#[derive(Debug, Clone, Copy)]
pub enum SignalNameTag {
    /// Pipeline register stage.
    Pipeline {
        /// Stage index (1-based recommended).
        stage: u32,
    },
    /// Split intermediate wire.
    SplitWire {
        /// Wire index.
        index: u32,
    },
}

fn scope_key(scope: &str, name: &str) -> String {
    format!("{scope}::{name}")
}

/// Mangle `raw` into a legal SV identifier.
pub fn mangle_identifier(raw: &str, style: MangleStyle) -> String {
    let _ = style;
    if raw.is_empty() {
        return "_svt_empty".into();
    }
    let mut out = String::with_capacity(raw.len() + 4);
    for (i, ch) in raw.chars().enumerate() {
        let ok = ch.is_ascii_alphanumeric() || ch == '_';
        if i == 0 && ch.is_ascii_digit() {
            out.push('_');
            out.push(ch);
        } else if ok {
            out.push(ch);
        } else {
            out.push('_');
        }
    }
    if is_sv_keyword(&out) {
        out = format!("_svt_{out}");
    }
    out
}

fn is_sv_keyword(s: &str) -> bool {
    matches!(
        s,
        "module"
            | "endmodule"
            | "input"
            | "output"
            | "inout"
            | "wire"
            | "reg"
            | "logic"
            | "always"
            | "always_ff"
            | "always_comb"
            | "assign"
            | "begin"
            | "end"
            | "if"
            | "else"
            | "case"
            | "for"
            | "parameter"
            | "localparam"
            | "typedef"
            | "package"
            | "import"
            | "generate"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::loc::OriginKind;

    fn loc() -> SourceLoc {
        SourceLoc {
            file: "t.sv".into(),
            start_line: 1,
            start_col: 1,
            end_line: 1,
            end_col: 1,
            byte_start: 0,
            byte_end: 0,
            origin: OriginKind::UserFile,
        }
    }

    #[test]
    fn name_table_unique() {
        let mut nt = NameTable::new();
        nt.reserve("m", "sum_svt_p1");
        let (_, a) = nt.alloc_signal("m", "sum", SignalNameTag::Pipeline { stage: 1 }, loc());
        let (_, b) = nt.alloc_signal("m", "sum", SignalNameTag::Pipeline { stage: 1 }, loc());
        assert_ne!(a, b);
        assert!(a.starts_with("sum_svt_p1"));
    }

    #[test]
    fn mangle_keywords_and_digits() {
        assert_eq!(mangle_identifier("module", MangleStyle::SafeIdent), "_svt_module");
        assert!(mangle_identifier("1wire", MangleStyle::SafeIdent).starts_with('_'));
        assert_eq!(
            mangle_identifier("a-b", MangleStyle::SafeIdent),
            "a_b"
        );
    }

    #[test]
    fn demangle_trace_roundtrip() {
        let mut nt = NameTable::new();
        let (id, name) =
            nt.alloc_signal("m", "x", SignalNameTag::SplitWire { index: 0 }, loc());
        let o = nt.demangle_trace(&name).expect("origin");
        assert_eq!(o.name, name);
        assert!(nt.signals.contains_key(&id));
    }
}
