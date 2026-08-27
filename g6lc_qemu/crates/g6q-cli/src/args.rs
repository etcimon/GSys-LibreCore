// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! A small argv parser.
//!
//! The package declares no external dependencies (`AGENTS.md` §3), so the option surface
//! described in `architecture/CLI.md` is parsed here. The grammar is deliberately plain:
//!
//! * `--flag` — a boolean;
//! * `--key value` and `--key=value` — a valued option, repeatable;
//! * a bare word — a positional;
//! * `--` — everything after is a positional, untouched.
//!
//! Unknown options are **retained rather than rejected** at this layer; each verb decides
//! what it accepts, which keeps the parser from having to know the whole surface.

use std::collections::BTreeMap;

/// Parsed command line.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Args {
    /// Positional arguments, in order. The first is normally the verb.
    pub positionals: Vec<String>,
    /// Valued options. A repeated option accumulates.
    pub options: BTreeMap<String, Vec<String>>,
    /// Boolean flags.
    pub flags: Vec<String>,
}

impl Args {
    /// Parse an argument vector, excluding the program name.
    pub fn parse<I, S>(argv: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let items: Vec<String> = argv.into_iter().map(Into::into).collect();
        let mut out = Args::default();
        let mut i = 0;
        let mut only_positional = false;

        while i < items.len() {
            let item = &items[i];
            if only_positional {
                out.positionals.push(item.clone());
                i += 1;
                continue;
            }
            if item == "--" {
                only_positional = true;
                i += 1;
                continue;
            }
            if let Some(body) = item.strip_prefix("--") {
                if let Some((k, v)) = body.split_once('=') {
                    out.options
                        .entry(k.to_string())
                        .or_default()
                        .push(v.to_string());
                    i += 1;
                    continue;
                }
                // `--key value` when the next item is not itself an option.
                match items.get(i + 1) {
                    Some(next) if !next.starts_with('-') => {
                        out.options
                            .entry(body.to_string())
                            .or_default()
                            .push(next.clone());
                        i += 2;
                    }
                    _ => {
                        out.flags.push(body.to_string());
                        i += 1;
                    }
                }
                continue;
            }
            if let Some(body) = item.strip_prefix('-') {
                if !body.is_empty() {
                    out.flags.push(body.to_string());
                    i += 1;
                    continue;
                }
            }
            out.positionals.push(item.clone());
            i += 1;
        }
        out
    }

    /// The verb, if one was given.
    pub fn verb(&self) -> Option<&str> {
        self.positionals.first().map(String::as_str)
    }

    /// Whether a flag was set. Accepts the long name without dashes.
    pub fn flag(&self, name: &str) -> bool {
        self.flags.iter().any(|f| f == name)
    }

    /// The last value given for an option.
    pub fn value(&self, name: &str) -> Option<&str> {
        self.options
            .get(name)
            .and_then(|v| v.last())
            .map(String::as_str)
    }

    /// Every value given for a repeatable option.
    pub fn values(&self, name: &str) -> &[String] {
        const EMPTY: &[String] = &[];
        self.options.get(name).map_or(EMPTY, Vec::as_slice)
    }

    /// The value for an option, or a default.
    pub fn value_or<'a>(&'a self, name: &str, default: &'a str) -> &'a str {
        self.value(name).unwrap_or(default)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verb_and_flags() {
        let a = Args::parse(["run", "--verbose", "--dry-run"]);
        assert_eq!(a.verb(), Some("run"));
        assert!(a.flag("verbose"));
        assert!(a.flag("dry-run"));
        assert!(!a.flag("quiet"));
    }

    #[test]
    fn both_valued_forms_work() {
        let a = Args::parse(["gen", "--target", "abc", "--plane=core"]);
        assert_eq!(a.value("target"), Some("abc"));
        assert_eq!(a.value("plane"), Some("core"));
    }

    #[test]
    fn repeatable_options_accumulate() {
        let a = Args::parse(["gen", "--flist", "a.f", "--flist", "b.f", "--set=ROOT=/x"]);
        assert_eq!(a.values("flist"), ["a.f", "b.f"]);
        assert_eq!(a.value("set"), Some("ROOT=/x"));
        assert_eq!(a.value("flist"), Some("b.f"), "value() returns the last");
    }

    #[test]
    fn an_option_followed_by_another_option_is_a_flag() {
        // `--check --emit model` must not swallow `--emit` as check's value.
        let a = Args::parse(["gen", "--check", "--emit", "model"]);
        assert!(a.flag("check"));
        assert_eq!(a.value("emit"), Some("model"));
    }

    #[test]
    fn double_dash_stops_option_parsing() {
        let a = Args::parse(["run", "--target", "t", "--", "--not-an-option", "x"]);
        assert_eq!(a.value("target"), Some("t"));
        assert_eq!(a.positionals, ["run", "--not-an-option", "x"]);
        assert!(!a.flag("not-an-option"));
    }

    #[test]
    fn short_flags_are_recognised() {
        let a = Args::parse(["doctor", "-v"]);
        assert!(a.flag("v"));
    }

    #[test]
    fn defaults_apply_to_absent_options() {
        let a = Args::parse(["run"]);
        assert_eq!(a.value_or("machine", "g6lc-soc"), "g6lc-soc");
        assert!(a.values("flist").is_empty());
    }

    #[test]
    fn an_empty_command_line_has_no_verb() {
        let a = Args::parse(Vec::<String>::new());
        assert_eq!(a.verb(), None);
    }
}
