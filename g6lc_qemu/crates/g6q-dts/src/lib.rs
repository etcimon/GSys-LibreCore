// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `g6q-dts` — the device tree: what software is told exists.
//!
//! The device tree is the third of the package's three inputs, and the one whose
//! disagreements with the other two are most consequential: a feature advertised here but
//! not present in the design is a **guest-visible lie**, and a feature present but not
//! advertised is invisible to the operating system
//! ([`architecture/INGEST.md`] §4).
//!
//! # Modules
//!
//! * [`tree`] — node/property model and the source parser
//! * [`facts`] — semantic extraction: what the tree claims about the hardware
//!
//! The extension-token model lives here at the crate root because it is what the
//! conformance report depends on most directly.
//!
//! # Stage
//!
//! Q1 provides parsing and extraction. Overlay merge, path mutation and blob emission
//! land with the command-line surface that needs them.
//!
//! [`architecture/INGEST.md`]: ../../../architecture/INGEST.md

#![forbid(unsafe_code)]

pub mod blob;
pub mod facts;
pub mod tree;

pub use blob::{from_blob, to_blob, BlobError};
pub use facts::{extract, DeviceFact, Facts};
pub use tree::{parse, Node, Prop};

/// Parse a device tree from a file and extract the facts the model consumes.
pub fn read_facts_file(path: &std::path::Path) -> std::io::Result<Facts> {
    let text = std::fs::read_to_string(path)?;
    Ok(extract(&parse(&text)))
}

/// The set of ISA extension tokens a device tree advertises to software.
///
/// Order is preserved because device trees are diffed by humans, but membership tests are
/// order-independent.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Extensions {
    tokens: Vec<String>,
}

impl Extensions {
    /// Build from an iterator of tokens, trimming and dropping empties.
    pub fn from_tokens<I, S>(tokens: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let mut out = Self::default();
        for t in tokens {
            out.add(t.as_ref());
        }
        out
    }

    /// Parse the comma-and-quote separated form used by a `riscv,isa-extensions`
    /// property body, e.g. `"i", "m", "a", "zacas"`.
    pub fn parse_property(body: &str) -> Self {
        Self::from_tokens(
            body.split(',')
                .map(|s| s.trim().trim_matches(['"', ';', ' ']).to_string())
                .filter(|s| !s.is_empty()),
        )
    }

    /// Whether a token is advertised.
    pub fn has(&self, token: &str) -> bool {
        self.tokens.iter().any(|t| t == token)
    }

    /// Add a token if absent. Returns whether it was added.
    pub fn add(&mut self, token: &str) -> bool {
        let token = token.trim();
        if token.is_empty() || self.has(token) {
            return false;
        }
        self.tokens.push(token.to_string());
        true
    }

    /// Remove a token. Returns whether it was present.
    pub fn remove(&mut self, token: &str) -> bool {
        let before = self.tokens.len();
        self.tokens.retain(|t| t != token);
        self.tokens.len() != before
    }

    /// Apply a `--isa-extensions` style edit list: bare tokens add, `-` prefixed remove.
    pub fn apply_edits(&mut self, spec: &str) {
        for item in spec.split(',') {
            let item = item.trim();
            if item.is_empty() {
                continue;
            }
            match item.strip_prefix('-') {
                Some(rm) => {
                    self.remove(rm);
                }
                None => {
                    self.add(item);
                }
            }
        }
    }

    /// The tokens, in order.
    pub fn tokens(&self) -> &[String] {
        &self.tokens
    }

    /// Render as a property body: `"i", "m", "a"`.
    pub fn to_property(&self) -> String {
        self.tokens
            .iter()
            .map(|t| format!("\"{t}\""))
            .collect::<Vec<_>>()
            .join(", ")
    }
}

/// Whether the tree advertises a capability that the design does not have, or vice versa.
///
/// This is the device-tree half of a conformance row: it reports the two possible
/// mismatches separately, because they have different fixes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenAgreement {
    /// Advertised and live: nothing to do.
    Agrees,
    /// Live in the design, absent from the tree — the guest will not use it.
    MissingFromTree,
    /// Advertised to the guest, not live in the design.
    NotInDesign,
    /// Neither: correctly silent.
    BothAbsent,
}

/// Compare one capability's device-tree token against the design.
pub fn check_token(ext: &Extensions, token: &str, live_in_design: bool) -> TokenAgreement {
    match (ext.has(token), live_in_design) {
        (true, true) => TokenAgreement::Agrees,
        (false, true) => TokenAgreement::MissingFromTree,
        (true, false) => TokenAgreement::NotInDesign,
        (false, false) => TokenAgreement::BothAbsent,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> Extensions {
        Extensions::parse_property(r#""i", "m", "a", "f", "d", "c", "zacas""#)
    }

    #[test]
    fn property_parsing_strips_quotes_and_whitespace() {
        let e = base();
        assert!(e.has("i"));
        assert!(e.has("zacas"));
        assert!(!e.has("v"));
        assert_eq!(e.tokens().len(), 7);
    }

    #[test]
    fn trailing_semicolon_and_empties_are_tolerated() {
        let e = Extensions::parse_property(r#""i", "m", ,"a";"#);
        assert_eq!(e.tokens(), ["i", "m", "a"]);
    }

    #[test]
    fn edits_add_and_remove() {
        let mut e = base();
        e.apply_edits("h,v,-c");
        assert!(e.has("h"));
        assert!(e.has("v"));
        assert!(!e.has("c"));
    }

    #[test]
    fn adding_a_duplicate_is_a_no_op() {
        let mut e = base();
        let n = e.tokens().len();
        assert!(!e.add("i"));
        assert_eq!(e.tokens().len(), n);
    }

    #[test]
    fn rendering_round_trips() {
        let e = base();
        let reparsed = Extensions::parse_property(&e.to_property());
        assert_eq!(e, reparsed);
    }

    #[test]
    fn agreement_distinguishes_the_two_mismatches() {
        let e = base();
        // Live and advertised.
        assert_eq!(check_token(&e, "zacas", true), TokenAgreement::Agrees);
        // Live in RTL, deliberately omitted from the tree: the guest simply will not use it.
        assert_eq!(check_token(&e, "h", true), TokenAgreement::MissingFromTree);
        // Advertised but not implemented: a guest-visible lie.
        assert_eq!(check_token(&e, "c", false), TokenAgreement::NotInDesign);
        // Correctly silent.
        assert_eq!(check_token(&e, "v", false), TokenAgreement::BothAbsent);
    }
}
