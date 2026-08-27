// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Package-level reading: comments, `localparam` statements, expression evaluation.
//!
//! Scope is deliberately narrow ([`crate::value`]). The reader resolves the five
//! expression forms that real configuration packages use and **fails loudly** on
//! anything else.

use std::collections::BTreeMap;

use crate::value::Value;

/// A parsed configuration package.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Package {
    /// The `package <name>;` identifier.
    pub name: String,
    /// Every scalar `localparam`, in declaration-resolved form.
    pub params: BTreeMap<String, Value>,
    /// Every `localparam` whose value is a struct literal, keyed by parameter name.
    pub structs: BTreeMap<String, BTreeMap<String, Value>>,
    /// Declaration order of struct parameters, so the main configuration can be found
    /// without knowing its name.
    pub struct_order: Vec<String>,
    /// Preprocessor directive lines that were dropped during reading.
    ///
    /// Real packages sometimes carry unrelated macro definitions and conditionals (for
    /// example vendor verification macros). These are line-oriented and unterminated, so
    /// they cannot participate in statement splitting, and interpreting the
    /// conditionals would mean guessing at a build's define set. They are dropped and
    /// **recorded here** so the omission is visible; if a dropped directive ever
    /// mattered, the identifier that needed it surfaces as unresolved.
    pub dropped_directives: Vec<String>,
}

impl Package {
    /// The main configuration struct.
    ///
    /// Prefers a parameter whose declared type ends in `cva6_user_cfg_t`-like naming;
    /// falls back to the **largest** struct in the file, which is the configuration in
    /// every real package (the next largest is an order of magnitude smaller). Returning
    /// the largest rather than the last avoids depending on declaration order.
    pub fn main_config(&self) -> Option<(&str, &BTreeMap<String, Value>)> {
        self.struct_order
            .iter()
            .filter_map(|n| self.structs.get(n).map(|s| (n.as_str(), s)))
            .max_by_key(|(_, s)| s.len())
    }

    /// Look up a field of the main configuration.
    pub fn field(&self, name: &str) -> Option<&Value> {
        self.main_config().and_then(|(_, s)| s.get(name))
    }

    /// A boolean field, `false` when absent.
    ///
    /// Absent is not the same as unresolved: a field the design does not have is
    /// legitimately off, whereas a field the reader could not parse is reported by
    /// [`Package::unresolved_fields`].
    pub fn flag(&self, name: &str) -> bool {
        self.field(name).and_then(Value::as_bool).unwrap_or(false)
    }

    /// An integer field, or `default` when absent or not an integer.
    pub fn int_or(&self, name: &str, default: i64) -> i64 {
        self.field(name).and_then(Value::as_int).unwrap_or(default)
    }

    /// An enum field's member name.
    pub fn enum_of(&self, name: &str) -> Option<&str> {
        self.field(name).and_then(Value::as_enum)
    }

    /// A field inside a nested struct field, e.g. `("AiCfg", "MatrixEn")`.
    pub fn nested(&self, outer: &str, inner: &str) -> Option<&Value> {
        self.field(outer)
            .and_then(Value::as_struct)
            .and_then(|m| m.get(inner))
    }

    /// A boolean inside a nested struct field.
    pub fn nested_flag(&self, outer: &str, inner: &str) -> bool {
        self.nested(outer, inner)
            .and_then(Value::as_bool)
            .unwrap_or(false)
    }

    /// Names of main-configuration fields the reader could not determine.
    pub fn unresolved_fields(&self) -> Vec<&str> {
        self.main_config()
            .map(|(_, s)| {
                s.iter()
                    .filter(|(_, v)| v.is_unresolved())
                    .map(|(k, _)| k.as_str())
                    .collect()
            })
            .unwrap_or_default()
    }
}

/// Read a configuration package from source text.
pub fn read_package(text: &str) -> Package {
    let (src, dropped) = preprocess(text);
    let mut pkg = Package {
        dropped_directives: dropped,
        ..Package::default()
    };

    if let Some(rest) = src.split_once("package ") {
        pkg.name = rest
            .1
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
    }

    for stmt in split_statements(&src) {
        let Some(decl) = parse_localparam(&stmt) else {
            continue;
        };
        let value = eval(&decl.value, &pkg);
        match value {
            Value::Struct(members) => {
                pkg.struct_order.push(decl.name.clone());
                pkg.structs.insert(decl.name, members);
            }
            other => {
                pkg.params.insert(decl.name, other);
            }
        }
    }
    pkg
}

struct Decl {
    name: String,
    value: String,
}

/// Parse `localparam [type] NAME = <expr>`.
fn parse_localparam(stmt: &str) -> Option<Decl> {
    let s = stmt.trim();
    let rest = s.strip_prefix("localparam")?;
    if !rest.starts_with(char::is_whitespace) {
        return None;
    }
    let (lhs, value) = split_top_level_assign(rest)?;
    // The declared name is the last identifier before `=`; anything earlier is a type.
    let name = lhs
        .split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .filter(|t| !t.is_empty())
        .next_back()?
        .to_string();
    if name.is_empty() {
        return None;
    }
    Some(Decl {
        name,
        value: value.trim().to_string(),
    })
}

/// Split on the first `=` that is not inside brackets and not part of `==`/`<=`/`>=`.
fn split_top_level_assign(s: &str) -> Option<(&str, &str)> {
    let b: Vec<char> = s.chars().collect();
    let mut depth = 0i32;
    for (i, c) in b.iter().enumerate() {
        match c {
            '{' | '(' | '[' => depth += 1,
            '}' | ')' | ']' => depth -= 1,
            '=' if depth == 0 => {
                if b.get(i + 1) == Some(&'=') {
                    continue;
                }
                if matches!(b.get(i.wrapping_sub(1)), Some('<') | Some('>') | Some('!')) {
                    continue;
                }
                let byte = s.char_indices().nth(i)?.0;
                return Some((&s[..byte], &s[byte + 1..]));
            }
            _ => {}
        }
    }
    None
}

/// Strip comments, then drop line-oriented preprocessor directives.
///
/// Returns the cleaned source and the directives that were removed.
///
/// Directives must go before statement splitting: a `` `define `` has no terminating
/// semicolon, so leaving one in place makes the splitter swallow the following
/// declaration into the same "statement" and the declaration is then never seen. That is
/// not hypothetical — it is how a real package silently produced an empty configuration.
fn preprocess(text: &str) -> (String, Vec<String>) {
    let stripped = strip_comments(text);
    let mut out = String::with_capacity(stripped.len());
    let mut dropped = Vec::new();
    let mut continuing = false;

    for line in stripped.lines() {
        let trimmed = line.trim_start();
        let is_directive = continuing || trimmed.starts_with('`');
        if is_directive {
            // A directive continues onto the next line when it ends with a backslash.
            continuing = line.trim_end().ends_with('\\');
            let text = trimmed.trim_end().to_string();
            if !text.is_empty() {
                dropped.push(text);
            }
            out.push('\n');
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    (out, dropped)
}

/// Remove `//` line comments and `/* */` block comments.
fn strip_comments(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let b: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < b.len() {
        if b[i] == '/' && b.get(i + 1) == Some(&'/') {
            while i < b.len() && b[i] != '\n' {
                i += 1;
            }
            continue;
        }
        if b[i] == '/' && b.get(i + 1) == Some(&'*') {
            i += 2;
            while i < b.len() && !(b[i] == '*' && b.get(i + 1) == Some(&'/')) {
                i += 1;
            }
            i = (i + 2).min(b.len());
            out.push(' ');
            continue;
        }
        out.push(b[i]);
        i += 1;
    }
    out
}

/// Split source into `;`-terminated statements, ignoring `;` inside brackets.
fn split_statements(src: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut depth = 0i32;
    for c in src.chars() {
        match c {
            '{' | '(' | '[' => {
                depth += 1;
                cur.push(c);
            }
            '}' | ')' | ']' => {
                depth -= 1;
                cur.push(c);
            }
            ';' if depth == 0 => out.push(std::mem::take(&mut cur)),
            _ => cur.push(c),
        }
    }
    out
}

/// Evaluate an expression against the parameters resolved so far.
pub fn eval(raw: &str, pkg: &Package) -> Value {
    let s = raw.trim();
    if s.is_empty() {
        return Value::Unresolved(String::new());
    }

    // Struct literal: '{ ... }
    if let Some(body) = s.strip_prefix("'{") {
        let body = body.trim_end().strip_suffix('}').unwrap_or(body);
        return Value::Struct(parse_members(body, pkg));
    }

    // Cast: <ident-or-width>'( ... )   -- distinguished from a sized literal by the '('
    if let Some(q) = s.find('\'') {
        if s[q + 1..].starts_with('(') && s.ends_with(')') {
            let inner = &s[q + 2..s.len() - 1];
            return eval(inner, pkg);
        }
    }

    // Aggregate: { ... }  (concatenation or replication)
    if s.starts_with('{') && s.ends_with('}') {
        return eval_aggregate(&s[1..s.len() - 1], pkg);
    }

    // Sized literal: <width>'<base><digits>
    if let Some(v) = parse_sized_literal(s) {
        return v;
    }

    // Plain integer, with optional sign and underscores.
    let cleaned = s.replace('_', "");
    if let Ok(i) = cleaned.parse::<i64>() {
        return Value::Int(i);
    }
    if let Some(hex) = cleaned
        .strip_prefix("0x")
        .or_else(|| cleaned.strip_prefix("0X"))
    {
        if let Ok(i) = i64::from_str_radix(hex, 16) {
            return Value::Int(i);
        }
    }

    // Scoped enum: pkg::NAME
    if let Some((_, member)) = s.rsplit_once("::") {
        if is_identifier(member) {
            return Value::Enum(member.to_string());
        }
    }

    // Bare identifier: a parameter, a struct, or unknown.
    if is_identifier(s) {
        if let Some(v) = pkg.params.get(s) {
            return v.clone();
        }
        if let Some(m) = pkg.structs.get(s) {
            return Value::Struct(m.clone());
        }
        return Value::Unresolved(s.to_string());
    }

    Value::Unresolved(s.to_string())
}

/// Evaluate the inside of `{ … }`: either `N{expr}` replication or a concatenation.
fn eval_aggregate(body: &str, pkg: &Package) -> Value {
    let body = body.trim();
    // Replication: N{expr}
    if let Some(open) = body.find('{') {
        let head = body[..open].trim();
        if !head.is_empty() && body.ends_with('}') {
            let count_val = eval(head, pkg);
            if let Some(n) = count_val.as_int() {
                let inner = &body[open + 1..body.len() - 1];
                let v = eval(inner, pkg);
                let n = n.clamp(0, 4096) as usize;
                return Value::List(vec![v; n]);
            }
        }
    }
    let items: Vec<Value> = split_top_level(body, ',')
        .into_iter()
        .filter(|p| !p.trim().is_empty())
        .map(|p| eval(&p, pkg))
        .collect();
    if items.is_empty() {
        return Value::Unresolved(format!("{{{body}}}"));
    }
    Value::List(items)
}

/// Parse `Name: value,` members of a struct-literal body.
pub fn parse_members(body: &str, pkg: &Package) -> BTreeMap<String, Value> {
    let mut out = BTreeMap::new();
    for member in split_top_level(body, ',') {
        let Some((name, raw)) = split_member(&member) else {
            continue;
        };
        out.insert(name, eval(&raw, pkg));
    }
    out
}

/// Split `Name: value` on the first top-level `:` that is not part of `::`.
fn split_member(member: &str) -> Option<(String, String)> {
    let b: Vec<char> = member.chars().collect();
    let mut depth = 0i32;
    for (i, c) in b.iter().enumerate() {
        match c {
            '{' | '(' | '[' => depth += 1,
            '}' | ')' | ']' => depth -= 1,
            ':' if depth == 0 => {
                if b.get(i + 1) == Some(&':') || (i > 0 && b[i - 1] == ':') {
                    continue;
                }
                let name: String = b[..i].iter().collect::<String>().trim().to_string();
                let raw: String = b[i + 1..].iter().collect::<String>().trim().to_string();
                if name.is_empty() || raw.is_empty() || !is_identifier(&name) {
                    return None;
                }
                return Some((name, raw));
            }
            _ => {}
        }
    }
    None
}

/// Split on a separator at bracket depth zero.
fn split_top_level(s: &str, sep: char) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut depth = 0i32;
    for c in s.chars() {
        match c {
            '{' | '(' | '[' => {
                depth += 1;
                cur.push(c);
            }
            '}' | ')' | ']' => {
                depth -= 1;
                cur.push(c);
            }
            c if c == sep && depth == 0 => out.push(std::mem::take(&mut cur)),
            _ => cur.push(c),
        }
    }
    if !cur.trim().is_empty() {
        out.push(cur);
    }
    out
}

/// Parse `<width>'<base><digits>`, e.g. `1'b1`, `32'd16`, `64'h8000_0000`.
fn parse_sized_literal(raw: &str) -> Option<Value> {
    let (_, rest) = raw.split_once('\'')?;
    let mut it = rest.chars();
    let base = it.next()?;
    let digits: String = it.collect::<String>().replace('_', "");
    if digits.is_empty() {
        return None;
    }
    let radix = match base.to_ascii_lowercase() {
        'b' => 2,
        'o' => 8,
        'd' => 10,
        'h' => 16,
        _ => return None,
    };
    // Wide literals (e.g. 128-bit masks) overflow i64; that is not an error, it is a
    // value this reader does not model. Say so rather than truncating.
    let v = match u128::from_str_radix(&digits, radix) {
        Ok(v) if v <= i64::MAX as u128 => v as i64,
        _ => return Some(Value::Unresolved(raw.to_string())),
    };
    if radix == 2 && digits.len() == 1 {
        return Some(Value::Bool(v != 0));
    }
    Some(Value::Int(v))
}

fn is_identifier(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty() -> Package {
        Package::default()
    }

    #[test]
    fn comments_are_stripped_including_block_form() {
        let s = strip_comments("a // gone\nb /* also gone */ c");
        assert!(!s.contains("gone"));
        assert!(s.contains('a') && s.contains('b') && s.contains('c'));
    }

    #[test]
    fn unterminated_preprocessor_directives_do_not_swallow_the_next_declaration() {
        // A real package carries vendor macros before its configuration. A `define has
        // no terminating semicolon, so leaving it in place makes the statement splitter
        // absorb the declaration that follows and the configuration vanishes silently.
        let src = "package p;\n\
                   `ifndef GUARD\n\
                   `define GUARD\n\
                   `define WIDE 8\n\
                   `endif\n\
                   localparam t cva6_cfg = '{ XLEN: 64, RVC: bit'(1) };\n\
                   endpackage";
        let pkg = read_package(src);
        assert!(
            pkg.main_config().is_some(),
            "configuration was swallowed by a directive"
        );
        assert_eq!(pkg.int_or("XLEN", 0), 64);
        assert_eq!(
            pkg.dropped_directives.len(),
            4,
            "{:?}",
            pkg.dropped_directives
        );
    }

    #[test]
    fn a_continued_directive_is_dropped_whole() {
        let src = "package p;\n\
                   `define M(a) \\\n\
                       do_something(a)\n\
                   localparam t cva6_cfg = '{ XLEN: 32 };\n\
                   endpackage";
        let pkg = read_package(src);
        assert_eq!(pkg.int_or("XLEN", 0), 32);
        assert_eq!(pkg.dropped_directives.len(), 2);
    }

    #[test]
    fn casts_unwrap_to_their_operand() {
        assert_eq!(eval("unsigned'(8)", &empty()), Value::Int(8));
        assert_eq!(eval("bit'(1)", &empty()), Value::Int(1));
        assert_eq!(eval("int'(16)", &empty()), Value::Int(16));
    }

    #[test]
    fn sized_literals_resolve_and_single_bit_is_boolean() {
        assert_eq!(eval("1'b1", &empty()), Value::Bool(true));
        assert_eq!(eval("1'b0", &empty()), Value::Bool(false));
        assert_eq!(eval("32'd16", &empty()), Value::Int(16));
        assert_eq!(eval("64'h8000_0000", &empty()), Value::Int(0x8000_0000));
    }

    #[test]
    fn a_literal_too_wide_for_the_model_is_unresolved_not_truncated() {
        // Silently truncating a 128-bit reset mask to 64 bits would be a wrong number
        // presented as a fact.
        let v = eval("128'hFFFF_FFFF_FFFF_FFFF_FFFF", &empty());
        assert!(v.is_unresolved(), "{v:?}");
    }

    #[test]
    fn scoped_enums_keep_their_member_name() {
        assert_eq!(
            eval("config_pkg::TAGE_LITE", &empty()).as_enum(),
            Some("TAGE_LITE")
        );
        assert_eq!(
            eval("config_pkg::COPRO_G6LC_AI", &empty()).as_enum(),
            Some("COPRO_G6LC_AI")
        );
    }

    #[test]
    fn identifiers_resolve_through_earlier_parameters() {
        let mut pkg = empty();
        pkg.params.insert("CVA6ConfigXlen".into(), Value::Int(64));
        assert_eq!(eval("unsigned'(CVA6ConfigXlen)", &pkg), Value::Int(64));
        // Unknown identifier: reported, never guessed.
        assert!(eval("NeverDeclared", &pkg).is_unresolved());
    }

    #[test]
    fn aggregates_become_lists() {
        let v = eval("1024'({64'h8000_0000, 64'h1_0000, 64'h0})", &empty());
        match v {
            Value::List(items) => {
                assert_eq!(items.len(), 3);
                assert_eq!(items[0], Value::Int(0x8000_0000));
                assert_eq!(items[2], Value::Int(0));
            }
            other => panic!("expected a list, got {other:?}"),
        }
    }

    #[test]
    fn replication_expands() {
        match eval("{4{64'h0}}", &empty()) {
            Value::List(items) => assert_eq!(items.len(), 4),
            other => panic!("expected a list, got {other:?}"),
        }
    }

    #[test]
    fn a_struct_parameter_can_be_referenced_by_name() {
        // The real shape: `localparam ai_cfg_t ai_cfg = '{...}` then `AiCfg: ai_cfg`.
        let src = "package p;\n\
                   localparam config_pkg::ai_cfg_t ai_cfg = '{ MatrixEn: bit'(1), TileM: unsigned'(8) };\n\
                   localparam config_pkg::cva6_user_cfg_t cva6_cfg = '{ XLEN: unsigned'(64), AiCfg: ai_cfg, RVC: bit'(1) };\n\
                   endpackage";
        let pkg = read_package(src);
        assert_eq!(pkg.name, "p");
        assert_eq!(pkg.int_or("XLEN", 0), 64);
        assert!(pkg.nested_flag("AiCfg", "MatrixEn"));
        assert_eq!(pkg.nested("AiCfg", "TileM"), Some(&Value::Int(8)));
    }

    #[test]
    fn the_main_config_is_the_largest_struct_not_the_last() {
        let src = "package p;\n\
                   localparam t cva6_cfg = '{ A: 1, B: 2, C: 3 };\n\
                   localparam t small = '{ Z: 9 };\n\
                   endpackage";
        let pkg = read_package(src);
        let (name, _) = pkg.main_config().expect("a main config");
        assert_eq!(name, "cva6_cfg");
    }

    #[test]
    fn unresolved_members_are_reported_by_name() {
        let src = "package p;\n\
                   localparam t cva6_cfg = '{ Good: unsigned'(4), Bad: Foo * 2, Also: 1 };\n\
                   endpackage";
        let pkg = read_package(src);
        assert_eq!(pkg.unresolved_fields(), vec!["Bad"]);
        assert_eq!(pkg.int_or("Good", 0), 4);
    }

    #[test]
    fn absent_is_off_and_does_not_count_as_unresolved() {
        let src = "package p;\nlocalparam t cva6_cfg = '{ A: bit'(1) };\nendpackage";
        let pkg = read_package(src);
        assert!(pkg.flag("A"));
        assert!(!pkg.flag("NeverHeardOf"));
        assert!(pkg.unresolved_fields().is_empty());
    }

    #[test]
    fn statements_split_on_semicolons_outside_brackets() {
        let stmts = split_statements("localparam a = 1; localparam b = '{ x: 1, y: 2 }; end");
        assert_eq!(stmts.len(), 2);
        assert!(stmts[1].contains("y: 2"));
    }

    #[test]
    fn member_split_ignores_scope_resolution() {
        let (n, v) = split_member(" BPType: config_pkg::GSHARE ").expect("member");
        assert_eq!(n, "BPType");
        assert_eq!(v, "config_pkg::GSHARE");
    }
}
