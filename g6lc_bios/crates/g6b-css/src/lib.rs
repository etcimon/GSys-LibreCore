// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Bounded first-party CSS: tokenize a declaration subset, order the cascade by
//! specificity, and compute a box model.
//!
//! Rewritten from the `kernel-spec/goosie` `internal/css` + `internal/renderer`
//! contract (MIT, read-only, never compiled — `AGENTS.md` prime directive 1).
//! Goosie supplies the *algorithms*: selector specificity tuples, cascade
//! ordering, and the content/padding/border/margin box. Its Go source, Goja
//! embedding, Fyne windowing and Playwright verification gate are all refused;
//! see `architecture/RENDER-VALIDATION.md` §5.
//!
//! This is **not** a web rendering engine. There is no float, flex, grid, text
//! shaping, inheritance chain, `@media`, custom property, or shorthand
//! expansion beyond what is listed in [`SUPPORTED_PROPERTIES`]. Everything else
//! fails closed rather than being silently accepted, so a feature row in
//! `fixtures/css-features.json` can never be marked landed by accident.

#![allow(missing_docs)]

pub mod inspect;
pub mod render;
pub mod render32;

// Re-export the asset/font types the modern renderer consumes so callers
// do not have to pull in extra crates just to invoke `render32`.
pub use g6b_img::{load_assets, Asset, AssetMap, RgbaImage};
pub use g6b_ttf::FontSet;

use std::collections::BTreeMap;

/// Bounded budgets. A stylesheet is a bounded transaction like every other
/// g6b lane; a hostile or generated sheet cannot exhaust the BIOS.
pub const MAX_SOURCE_BYTES: usize = 64 * 1024;
pub const MAX_RULES: usize = 512;
pub const MAX_SELECTORS_PER_RULE: usize = 32;
pub const MAX_DECLARATIONS_PER_RULE: usize = 64;

/// Longhand properties the cascade will retain. Anything else is refused by
/// [`parse`] so unimplemented styling can never look implemented.
pub const SUPPORTED_PROPERTIES: &[&str] = &[
    "display",
    "width",
    "height",
    // Width clamps. `max-width` with `margin: 0 auto` is the standard centered
    // column, so the two land together — a `max-width` that did not constrain
    // the auto-margin solve would centre nothing.
    "max-width",
    "min-width",
    "box-sizing",
    "margin-top",
    "margin-right",
    "margin-bottom",
    "margin-left",
    "padding-top",
    "padding-right",
    "padding-bottom",
    "padding-left",
    "border-top-width",
    "border-right-width",
    "border-bottom-width",
    "border-left-width",
    "border-color",
    "color",
    "background-color",
    // Out-of-flow positioning. Only `static` and `absolute` are implemented;
    // `relative`/`fixed`/`sticky` are refused by `Position::parse` rather than
    // silently degraded, because a box that quietly stays in flow is a wrong
    // pixel, not a missing feature.
    "position",
    "top",
    "right",
    "bottom",
    "left",
    // Shorthand property names (not emitted, but recognised so parse refuses
    // an unknown name rather than allowing a misspelled shorthand to slip in).
    "margin",
    "padding",
    "border",
    "visibility",
    // Alpha / modern-UI lane (render32). Every entry here is honoured by the
    // RGBA renderer — a property in this list may never silently drop paint.
    "opacity",
    "border-radius",
    "background-image",
    "object-fit",
    "font-family",
    "font-size",
    "font-weight",
    "text-align",
    // SVG presentation properties (rasterized by g6b-img on <svg> children).
    "fill",
    "fill-opacity",
    "stroke",
    "stroke-width",
    "stroke-opacity",
    // Additional shorthands expanded at parse time.
    "background",
    "font",
];

/// Every way this crate refuses input. No variant is recoverable-by-guessing:
/// the caller gets an error instead of a wrong pixel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CssError {
    SourceTooLarge(usize),
    TooManyRules,
    TooManySelectors,
    TooManyDeclarations,
    UnterminatedBlock,
    StrayBlockClose,
    EmptySelector,
    UnsupportedProperty(String),
    BadLength(String),
    /// A `position` keyword outside `static`/`absolute`.
    UnsupportedPosition(String),
    /// `position: absolute` without an explicit `width`/`height`. Shrink-to-fit
    /// needs intrinsic sizing, which this renderer does not do — falling back
    /// to the containing-block width would silently mis-place the box.
    AbsoluteNeedsSize(&'static str),
    /// A property whose value sits outside the implemented keyword set —
    /// e.g. `background-image: linear-gradient(...)` or `text-align: justify`.
    UnsupportedValue(String),
}

impl std::fmt::Display for CssError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::SourceTooLarge(n) => write!(f, "css source {n} bytes exceeds budget"),
            Self::TooManyRules => write!(f, "css rule budget exceeded"),
            Self::TooManySelectors => write!(f, "css selector budget exceeded"),
            Self::TooManyDeclarations => write!(f, "css declaration budget exceeded"),
            Self::UnterminatedBlock => write!(f, "css block is not terminated"),
            Self::StrayBlockClose => write!(f, "css has an unbalanced '}}'"),
            Self::EmptySelector => write!(f, "css rule has an empty selector"),
            Self::UnsupportedProperty(p) => write!(f, "css property {p} is not implemented"),
            Self::BadLength(v) => write!(f, "css length {v} is not a supported px/integer"),
            Self::UnsupportedPosition(p) => {
                write!(f, "css position {p} is not implemented (static|absolute)")
            }
            Self::AbsoluteNeedsSize(axis) => write!(
                f,
                "position:absolute needs an explicit {axis}; shrink-to-fit is not implemented"
            ),
            Self::UnsupportedValue(v) => write!(f, "css value {v} is not implemented"),
        }
    }
}

impl std::error::Error for CssError {}

type R<T> = Result<T, CssError>;

/// CSS specificity as the comparable `(id, class, element)` tuple.
pub type Specificity = (u32, u32, u32);

/// Cascade sort key: `(important, specificity, source_order)`, compared
/// lexicographically so `!important` outranks specificity, which outranks
/// source order.
type CascadeKey = (u32, Specificity, usize);

/// Expand a shorthand property into its longhand equivalents.
///
/// `margin` and `padding` follow CSS 1-4 value rules. `border` is split into
/// the four widths and a `border-color`; `border-style` is ignored because the
/// BIOS renderer does not yet honour style. A `border` with style `none` or
/// `hidden` sets all widths to `0`.
fn expand_shorthand(property: &str, value: &str) -> Vec<(String, String)> {
    match property {
        "margin" | "padding" => {
            let parts: Vec<&str> = value.split_whitespace().collect();
            match parts.len() {
                0 => vec![],
                1 => {
                    let v = parts[0].to_string();
                    vec![
                        (format!("{property}-top"), v.clone()),
                        (format!("{property}-right"), v.clone()),
                        (format!("{property}-bottom"), v.clone()),
                        (format!("{property}-left"), v),
                    ]
                }
                2 => {
                    let tb = parts[0].to_string();
                    let rl = parts[1].to_string();
                    vec![
                        (format!("{property}-top"), tb.clone()),
                        (format!("{property}-right"), rl.clone()),
                        (format!("{property}-bottom"), tb),
                        (format!("{property}-left"), rl),
                    ]
                }
                _ => {
                    let top = parts[0].to_string();
                    let right = parts[1].to_string();
                    let bottom = if parts.len() >= 3 {
                        parts[2].to_string()
                    } else {
                        top.clone()
                    };
                    let left = if parts.len() >= 4 {
                        parts[3].to_string()
                    } else {
                        right.clone()
                    };
                    vec![
                        (format!("{property}-top"), top),
                        (format!("{property}-right"), right),
                        (format!("{property}-bottom"), bottom),
                        (format!("{property}-left"), left),
                    ]
                }
            }
        }
        "border" => {
            let tokens: Vec<&str> = value.split_whitespace().collect();
            let mut width = None;
            let mut style = None;
            let mut color = None;
            for t in &tokens {
                let lower = t.to_ascii_lowercase();
                if lower == "none" || lower == "hidden" {
                    return vec![
                        ("border-top-width".into(), "0".into()),
                        ("border-right-width".into(), "0".into()),
                        ("border-bottom-width".into(), "0".into()),
                        ("border-left-width".into(), "0".into()),
                    ];
                }
                if lower.parse::<i32>().is_ok() || lower.ends_with("px") || lower.ends_with('%') {
                    width = Some(*t);
                } else if is_border_style_word(&lower) {
                    style = Some(lower);
                } else {
                    // Treat anything else as a colour token.
                    color = Some(*t);
                }
            }
            let w = width.unwrap_or("0");
            let mut out = vec![];
            for side in ["top", "right", "bottom", "left"] {
                out.push((format!("border-{side}-width"), w.into()));
            }
            if let Some(c) = color {
                out.push(("border-color".into(), c.into()));
            }
            // The `style` token is deliberately dropped: it affects rendering
            // semantics we do not yet implement. Keeping it would silently
            // suggest support. Return only the properties the engine honours.
            let _ = style;
            out
        }
        "background" => {
            // Recognized tokens only: `url(...)` → background-image, a parseable
            // colour → background-color. Any other *function* token
            // (`linear-gradient(...)`, `image(...)`) is surfaced as a
            // `background-image` value so `check_value` can refuse it rather
            // than dropping it inside a shorthand. Plain keywords we do not
            // implement (`center`, `no-repeat`, `cover`) are dropped — they
            // change nothing this renderer would paint.
            let mut out = Vec::new();
            for tok in value_tokens(value) {
                let lower = tok.to_ascii_lowercase();
                if lower.starts_with("url(") {
                    out.push(("background-image".into(), tok));
                } else if g6b_gr::color::parse_rgba(&lower).is_some() {
                    out.push(("background-color".into(), tok));
                } else if lower.contains('(') {
                    out.push(("background-image".into(), tok));
                }
            }
            out
        }
        "font" => {
            // `font: [weight] <size>[/<line-height>] <family-list>` — the size
            // token splits the shorthand; everything after it is the family.
            let tokens = value_tokens(value);
            let mut out = Vec::new();
            let mut family_start = None;
            for (i, tok) in tokens.iter().enumerate() {
                let lower = tok.to_ascii_lowercase();
                // Weight keywords/numbers first: a bare `400` parses as a
                // number but is a weight, not a size.
                if matches!(lower.as_str(), "bold" | "bolder" | "lighter" | "normal")
                    || lower.parse::<u32>().is_ok_and(|n| (100..=900).contains(&n))
                {
                    out.push(("font-weight".into(), lower));
                    continue;
                }
                let size_tok = lower.split('/').next().unwrap_or(&lower);
                if size_tok.ends_with("px")
                    || size_tok.ends_with("em")
                    || size_tok.ends_with('%')
                    || size_tok.parse::<f64>().is_ok()
                {
                    family_start = Some(i + 1);
                    out.push((
                        "font-size".into(),
                        tok.split('/').next().unwrap().to_string(),
                    ));
                    break;
                }
                // `italic`/`small-caps`/etc. are not implemented and are
                // dropped — they only affect shaping, which this raster
                // does not claim.
            }
            if let Some(start) = family_start {
                if let Some(pos) = value.rfind(tokens[start - 1].as_str()) {
                    let family = value[pos + tokens[start - 1].len()..].trim_start();
                    if !family.is_empty() {
                        out.push(("font-family".into(), family.to_string()));
                    }
                }
            } else if !tokens.is_empty() {
                // No size token: the whole value is a family list.
                out.push(("font-family".into(), value.trim().to_string()));
            }
            out
        }
        _ => vec![(property.into(), value.into())],
    }
}

/// Split a declaration value on whitespace that sits outside `(...)` and
/// quotes — `rgba(0, 0, 64, .74)` and `font:16px "Courier New",monospace`
/// must not be tokenized apart.
fn value_tokens(value: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let (mut depth, mut quote) = (0usize, '\0');
    for c in value.trim().chars() {
        match c {
            '(' | '[' if quote == '\0' => depth += 1,
            ')' | ']' if quote == '\0' => depth = depth.saturating_sub(1),
            '"' | '\'' => {
                if quote == c {
                    quote = '\0';
                } else if quote == '\0' {
                    quote = c;
                }
            }
            _ => {}
        }
        if c.is_whitespace() && depth == 0 && quote == '\0' {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
        } else {
            cur.push(c);
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

fn is_border_style_word(w: &str) -> bool {
    matches!(
        w,
        "solid" | "dashed" | "dotted" | "double" | "groove" | "ridge" | "inset" | "outset"
    )
}

/// One `property: value` pair, with CSS `!important` recorded because it
/// outranks specificity in the cascade.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Declaration {
    pub property: String,
    pub value: String,
    pub important: bool,
}

/// A bounded compound selector: optional element name, optional `#id`, and any
/// number of `.class`es. Descendant/child combinators are not parsed — a
/// selector containing whitespace or `>` is kept verbatim and never matches, so
/// it cannot accidentally style the wrong node.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Selector {
    pub raw: String,
    pub element: Option<String>,
    pub id: Option<String>,
    pub classes: Vec<String>,
    /// True when parsing produced a shape this matcher understands.
    pub matchable: bool,
}

impl Selector {
    /// Parse one compound selector. Unsupported shapes come back with
    /// `matchable == false` rather than as an error, so one exotic selector in
    /// a generated sheet does not reject the whole stylesheet.
    pub fn parse(raw: &str) -> Self {
        let raw = raw.trim();
        let mut sel = Selector {
            raw: raw.to_string(),
            ..Default::default()
        };
        if raw.is_empty() || raw.contains(char::is_whitespace) || raw.contains(['>', '+', '~', '['])
        {
            return sel;
        }
        if raw == "*" {
            sel.matchable = true;
            return sel;
        }
        let mut cursor = raw;
        // A leading element name runs until the first '.' or '#'.
        let head = cursor
            .find(['.', '#'])
            .map_or(cursor, |i| &cursor[..i])
            .to_string();
        if !head.is_empty() {
            if !head.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
                return sel;
            }
            sel.element = Some(head.to_ascii_lowercase());
            cursor = &cursor[head.len()..];
        }
        while !cursor.is_empty() {
            let kind = cursor.as_bytes()[0];
            let rest = &cursor[1..];
            let end = rest.find(['.', '#']).unwrap_or(rest.len());
            let name = &rest[..end];
            if name.is_empty() {
                return sel;
            }
            match kind {
                b'#' => {
                    if sel.id.is_some() {
                        return sel;
                    }
                    sel.id = Some(name.to_string());
                }
                b'.' => sel.classes.push(name.to_string()),
                _ => return sel,
            }
            cursor = &rest[end..];
        }
        sel.matchable = true;
        sel
    }

    /// CSS specificity as the comparable `(id, class, element)` tuple.
    /// Deliberately excludes inline styles and `!important`; the cascade in
    /// [`cascade`] layers those on top.
    pub fn specificity(&self) -> Specificity {
        (
            u32::from(self.id.is_some()),
            self.classes.len() as u32,
            u32::from(self.element.is_some()),
        )
    }

    /// Does this selector match `el`?
    pub fn matches(&self, el: &ElementRef) -> bool {
        if !self.matchable {
            return false;
        }
        if let Some(ref name) = self.element {
            if !name.eq_ignore_ascii_case(&el.name) {
                return false;
            }
        }
        if let Some(ref id) = self.id {
            if el.id.as_deref() != Some(id.as_str()) {
                return false;
            }
        }
        self.classes
            .iter()
            .all(|c| el.classes.iter().any(|k| k == c))
    }
}

/// One rule: a selector list plus its declaration block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    pub selectors: Vec<Selector>,
    pub declarations: Vec<Declaration>,
}

/// A parsed stylesheet. Rule order is source order, which the cascade needs.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Stylesheet {
    pub rules: Vec<Rule>,
}

/// The element facts the matcher needs. Built from a `g6b_dom::Node` so the
/// style engine never has to own or mutate the DOM.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ElementRef {
    pub name: String,
    pub id: Option<String>,
    pub classes: Vec<String>,
}

impl ElementRef {
    pub fn new(name: &str) -> Self {
        Self {
            name: name.to_ascii_lowercase(),
            id: None,
            classes: Vec::new(),
        }
    }

    /// Project a DOM node into a matcher input. `class` is split on ASCII
    /// whitespace, matching the HTML attribute definition.
    pub fn from_node(node: &g6b_dom::Node) -> Self {
        Self {
            name: node.name.to_ascii_lowercase(),
            id: node.id.clone(),
            classes: node
                .attributes
                .get("class")
                .map(|c| c.split_whitespace().map(str::to_string).collect())
                .unwrap_or_default(),
        }
    }
}

/// Strip `/* ... */` comments without letting an unterminated comment swallow
/// the rest of the sheet silently.
fn strip_comments(src: &str) -> String {
    let mut out = String::with_capacity(src.len());
    let bytes = src.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'/' && i + 1 < bytes.len() && bytes[i + 1] == b'*' {
            match src[i + 2..].find("*/") {
                Some(end) => i += 2 + end + 2,
                None => break,
            }
        } else {
            out.push(bytes[i] as char);
            i += 1;
        }
    }
    out
}

/// Validate the *value* of a property whose keyword set is enumerated.
///
/// Only `position` has one today. Length and colour values are checked later
/// (by `computed_box` / `parse_color`) because they depend on a containing
/// block and a palette that parse time does not have.
fn check_value(property: &str, value: &str) -> R<()> {
    let v = value.trim();
    match property {
        "position" => {
            Position::parse(v)?;
        }
        // `url(...)` or `none` — gradients and image-set() are paint servers
        // this renderer does not implement and must not silently drop.
        "background-image" if !v.eq_ignore_ascii_case("none") && !v.starts_with("url(") => {
            return Err(CssError::UnsupportedValue(format!("background-image {v}")));
        }
        "text-align"
            if !matches!(
                v.to_ascii_lowercase().as_str(),
                "left" | "right" | "center" | "start" | "end"
            ) =>
        {
            return Err(CssError::UnsupportedValue(format!("text-align {v}")));
        }
        "object-fit"
            if !matches!(
                v.to_ascii_lowercase().as_str(),
                "fill" | "contain" | "cover" | "none"
            ) =>
        {
            return Err(CssError::UnsupportedValue(format!("object-fit {v}")));
        }
        "font-weight"
            if !matches!(
                v.to_ascii_lowercase().as_str(),
                "normal" | "bold" | "bolder" | "lighter"
            ) && v.parse::<u32>().map_or(true, |n| !(100..=900).contains(&n)) =>
        {
            return Err(CssError::UnsupportedValue(format!("font-weight {v}")));
        }
        _ => {}
    }
    Ok(())
}

/// How [`parse_inner`] treats a property outside [`SUPPORTED_PROPERTIES`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    /// Render path: refuse the sheet. An unimplemented property must never
    /// silently vanish behind a plausible-looking layout.
    Strict,
    /// Dev path: record the property and drop the declaration, so a survey of
    /// third-party CSS yields a missing-feature list instead of one error.
    Survey,
}

/// Parse a bounded CSS subset.
///
/// Refuses, rather than ignores: an unknown property, an unterminated block, an
/// empty selector, or any budget overrun. At-rules (`@media`, `@layer`, ...) are
/// not supported and are skipped along with their block, because pretending to
/// honour them would produce a confidently wrong layout.
pub fn parse(src: &str) -> R<Stylesheet> {
    parse_inner(src, Mode::Strict).map(|(sheet, _)| sheet)
}

/// **Dev-only survey.** Parse leniently, returning the stylesheet plus the
/// sorted, de-duplicated list of properties this engine does not implement.
///
/// This is the fast path for growing `fixtures/css-features.json`: point it at
/// real-world CSS and read off what is missing. It is **never** used by the
/// BIOS render path, because a survey deliberately tolerates exactly the
/// silent-drop behaviour that [`parse`] exists to prevent.
pub fn parse_survey(src: &str) -> R<(Stylesheet, Vec<String>)> {
    parse_inner(src, Mode::Survey)
}

fn parse_inner(src: &str, mode: Mode) -> R<(Stylesheet, Vec<String>)> {
    if src.len() > MAX_SOURCE_BYTES {
        return Err(CssError::SourceTooLarge(src.len()));
    }
    let src = strip_comments(src);
    let mut sheet = Stylesheet::default();
    let mut unsupported: Vec<String> = Vec::new();
    let mut rest = src.as_str();
    while !rest.trim().is_empty() {
        let Some(open) = rest.find('{') else {
            break;
        };
        // A statement at-rule (`@import url(..);`) ends at its semicolon,
        // before any block, and is dropped whole.
        if let Some(semi) = rest[..open].find(';') {
            if rest[..semi].trim_start().starts_with('@') {
                rest = &rest[semi + 1..];
                continue;
            }
        }
        let prelude = rest[..open].trim().to_string();

        // An unsupported block at-rule must be skipped past its *matching*
        // brace. Taking the first '}' would leak the nested rules inside a
        // `@media` block into the sheet as a malformed rule.
        if prelude.starts_with('@') {
            let after = &rest[open + 1..];
            let mut depth = 1usize;
            let mut end = None;
            for (i, c) in after.char_indices() {
                match c {
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if depth == 0 {
                            end = Some(i);
                            break;
                        }
                    }
                    _ => {}
                }
            }
            let Some(end) = end else {
                return Err(CssError::UnterminatedBlock);
            };
            rest = &after[end + 1..];
            continue;
        }

        let after = &rest[open + 1..];
        let Some(close) = after.find('}') else {
            return Err(CssError::UnterminatedBlock);
        };
        let body = &after[..close];
        rest = &after[close + 1..];

        if prelude.is_empty() {
            return Err(CssError::EmptySelector);
        }
        if prelude.contains('}') {
            return Err(CssError::StrayBlockClose);
        }
        if sheet.rules.len() >= MAX_RULES {
            return Err(CssError::TooManyRules);
        }

        let parts: Vec<&str> = prelude.split(',').map(str::trim).collect();
        if parts.iter().any(|p| p.is_empty()) {
            return Err(CssError::EmptySelector);
        }
        if parts.len() > MAX_SELECTORS_PER_RULE {
            return Err(CssError::TooManySelectors);
        }
        let selectors: Vec<Selector> = parts.iter().map(|p| Selector::parse(p)).collect();

        let mut declarations = Vec::new();
        for decl in body.split(';') {
            let decl = decl.trim();
            if decl.is_empty() {
                continue;
            }
            let Some((prop, value)) = decl.split_once(':') else {
                continue;
            };
            let property = prop.trim().to_ascii_lowercase();
            let mut value = value.trim().to_string();
            let important = value.to_ascii_lowercase().ends_with("!important");
            if important {
                let cut = value.len() - "!important".len();
                value = value[..cut].trim_end().to_string();
            }
            if !SUPPORTED_PROPERTIES.contains(&property.as_str()) {
                match mode {
                    Mode::Strict => return Err(CssError::UnsupportedProperty(property)),
                    Mode::Survey => {
                        if !unsupported.contains(&property) {
                            unsupported.push(property);
                        }
                        continue;
                    }
                }
            }
            // Shorthands are expanded into longhands at parse time so the
            // cascade never has to know they existed. This also lets `parse_survey`
            // report the longhands that would be used, which is the honest
            // missing-feature list.
            let expanded = expand_shorthand(&property, &value);
            for (p, v) in expanded {
                // Some properties have an enumerated value set, and an
                // unimplemented *value* is as much a missing feature as an
                // unimplemented property. Survey therefore reports
                // `position:fixed` and drops it, exactly as it would an unknown
                // property, instead of failing the whole sheet — a real browser
                // stylesheet legitimately contains keywords this raster has no
                // layout for.
                if let Err(e) = check_value(&p, &v) {
                    match mode {
                        Mode::Strict => return Err(e),
                        Mode::Survey => {
                            let key = format!("{p}:{}", v.trim().to_ascii_lowercase());
                            if !unsupported.contains(&key) {
                                unsupported.push(key);
                            }
                            continue;
                        }
                    }
                }
                if declarations.len() >= MAX_DECLARATIONS_PER_RULE {
                    return Err(CssError::TooManyDeclarations);
                }
                declarations.push(Declaration {
                    property: p,
                    value: v,
                    important,
                });
            }
        }
        sheet.rules.push(Rule {
            selectors,
            declarations,
        });
    }
    unsupported.sort();
    Ok((sheet, unsupported))
}

/// The winning declarations for one element, keyed by longhand property.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ComputedStyle {
    values: BTreeMap<String, String>,
}

impl ComputedStyle {
    pub fn get(&self, property: &str) -> Option<&str> {
        self.values.get(property).map(String::as_str)
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }

    pub fn len(&self) -> usize {
        self.values.len()
    }
}

/// Resolve the cascade for `el`.
///
/// Ordering follows CSS, and therefore the goosie contract: `!important` beats
/// normal, then higher specificity beats lower, then later source order beats
/// earlier. Author origin only — there is no user or UA sheet in the BIOS, and
/// no inheritance pass (see the module note).
pub fn cascade(sheet: &Stylesheet, el: &ElementRef) -> ComputedStyle {
    // (important, specificity, source_order) per property; a later candidate
    // replaces the winner only when its key is strictly greater.
    let mut best: BTreeMap<String, (CascadeKey, String)> = BTreeMap::new();
    for (order, rule) in sheet.rules.iter().enumerate() {
        let Some(spec) = rule
            .selectors
            .iter()
            .filter(|s| s.matches(el))
            .map(Selector::specificity)
            .max()
        else {
            continue;
        };
        for decl in &rule.declarations {
            let key = (u32::from(decl.important), spec, order);
            let replace = match best.get(&decl.property) {
                Some((existing, _)) => key > *existing,
                None => true,
            };
            if replace {
                best.insert(decl.property.clone(), (key, decl.value.clone()));
            }
        }
    }
    ComputedStyle {
        values: best.into_iter().map(|(k, (_, v))| (k, v)).collect(),
    }
}

/// How `width`/`height` relate to padding and border.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BoxSizing {
    ContentBox,
    BorderBox,
}

/// One resolved edge quad, in whole device pixels.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Edges {
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
    pub left: i32,
}

impl Edges {
    pub fn horizontal(&self) -> i32 {
        self.left + self.right
    }

    pub fn vertical(&self) -> i32 {
        self.top + self.bottom
    }
}

/// A computed box: content size plus the three surrounding edge quads.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct BoxModel {
    pub content_width: i32,
    pub content_height: i32,
    pub padding: Edges,
    pub border: Edges,
    pub margin: Edges,
}

impl BoxModel {
    /// Border-box width: content + padding + border, excluding margin.
    pub fn border_box_width(&self) -> i32 {
        self.content_width + self.padding.horizontal() + self.border.horizontal()
    }

    pub fn border_box_height(&self) -> i32 {
        self.content_height + self.padding.vertical() + self.border.vertical()
    }

    /// Total horizontal space consumed in a block flow, margins included.
    pub fn margin_box_width(&self) -> i32 {
        self.border_box_width() + self.margin.horizontal()
    }

    pub fn margin_box_height(&self) -> i32 {
        self.border_box_height() + self.margin.vertical()
    }
}

/// Parse a length. Accepts `0`, bare integers, `<int>px`, `<int>%`, and
/// `<n>ch` (1ch = 8px; fractional `ch` is rounded to the nearest pixel).
/// `em`/`rem`/float-`px`/`pt` etc. are refused so the BIOS raster does not
/// silently truncate to a wrong pixel.
fn length(value: &str, basis: i32) -> R<i32> {
    let v = value.trim();
    if v.is_empty() || v.eq_ignore_ascii_case("auto") {
        return Ok(0);
    }
    let bad = || CssError::BadLength(v.to_string());
    if let Some(num) = v.strip_suffix('%') {
        let pct: i32 = num.trim().parse().map_err(|_| bad())?;
        return Ok(basis.saturating_mul(pct) / 100);
    }
    if let Some(num) = v.strip_suffix("ch") {
        let n: f64 = num.trim().parse().map_err(|_| bad())?;
        return Ok(((n * 8.0).round()) as i32);
    }
    let num = v.strip_suffix("px").unwrap_or(v).trim();
    num.parse::<i32>().map_err(|_| bad())
}

fn edge(style: &ComputedStyle, prefix: &str, suffix: &str, basis: i32) -> R<Edges> {
    let side = |s: &str| -> R<i32> {
        let key = format!("{prefix}-{s}{suffix}");
        match style.get(&key) {
            Some(v) => length(v, basis),
            None => Ok(0),
        }
    };
    Ok(Edges {
        top: side("top")?,
        right: side("right")?,
        bottom: side("bottom")?,
        left: side("left")?,
    })
}

/// Out-of-flow positioning scheme.
///
/// Only two of the CSS values exist here. `relative`, `fixed` and `sticky` are
/// **refused**, not degraded: each needs machinery this renderer lacks (a
/// separate offset pass, a viewport distinct from the canvas, scroll state),
/// and a box that quietly stayed in flow would be a wrong pixel rather than an
/// obviously missing feature.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Position {
    #[default]
    Static,
    /// Removed from flow; placed against the nearest positioned ancestor's
    /// padding box (or the canvas), and painted after all in-flow content.
    Absolute,
}

impl Position {
    pub fn parse(value: &str) -> R<Self> {
        let v = value.trim();
        if v.is_empty() || v.eq_ignore_ascii_case("static") {
            return Ok(Self::Static);
        }
        if v.eq_ignore_ascii_case("absolute") {
            return Ok(Self::Absolute);
        }
        Err(CssError::UnsupportedPosition(v.to_string()))
    }
}

/// Resolved `position` for a computed style.
pub fn computed_position(style: &ComputedStyle) -> R<Position> {
    match style.get("position") {
        Some(v) => Position::parse(v),
        None => Ok(Position::Static),
    }
}

/// One resolved inset, or `None` for `auto`.
fn inset(style: &ComputedStyle, name: &str, basis: i32) -> R<Option<i32>> {
    match style.get(name) {
        None => Ok(None),
        Some(v) if v.trim().is_empty() || v.eq_ignore_ascii_case("auto") => Ok(None),
        Some(v) => Ok(Some(length(v, basis)?)),
    }
}

/// Place an absolutely positioned box inside the containing block
/// `(cb_x, cb_y, cb_w, cb_h)`, returning the **margin-box** origin.
///
/// `left`/`top` win when both insets are given, matching CSS for
/// `direction: ltr`. When only the far inset is given the box is placed from
/// that edge, which is what makes a top-right overlay expressible. With
/// neither, the box lands at the containing block's origin.
pub fn absolute_origin(
    style: &ComputedStyle,
    b: &BoxModel,
    cb_x: i32,
    cb_y: i32,
    cb_w: i32,
    cb_h: i32,
) -> R<(i32, i32)> {
    let (left, right) = (inset(style, "left", cb_w)?, inset(style, "right", cb_w)?);
    let (top, bottom) = (inset(style, "top", cb_h)?, inset(style, "bottom", cb_h)?);
    let outer_w = b.margin_box_width();
    let outer_h = b.margin_box_height();
    let x = match (left, right) {
        (Some(l), _) => cb_x + l,
        (None, Some(r)) => cb_x + cb_w - r - outer_w,
        (None, None) => cb_x,
    };
    let y = match (top, bottom) {
        (Some(t), _) => cb_y + t,
        (None, Some(bm)) => cb_y + cb_h - bm - outer_h,
        (None, None) => cb_y,
    };
    Ok((x, y))
}

/// Box model for an absolutely positioned element.
///
/// Unlike a block box, `width`/`height` are **required**: shrink-to-fit needs
/// intrinsic sizing, and defaulting to the containing-block width would place
/// a right-anchored box in the wrong spot without any error.
pub fn computed_absolute_box(style: &ComputedStyle, cb_w: i32) -> R<BoxModel> {
    let has = |k: &str| {
        style
            .get(k)
            .map(|v| !v.trim().is_empty() && !v.eq_ignore_ascii_case("auto"))
            .unwrap_or(false)
    };
    if !has("width") {
        return Err(CssError::AbsoluteNeedsSize("width"));
    }
    if !has("height") {
        return Err(CssError::AbsoluteNeedsSize("height"));
    }
    computed_box(style, cb_w)
}

fn is_auto(style: &ComputedStyle, property: &str) -> bool {
    style
        .get(property)
        .is_some_and(|v| v.trim().eq_ignore_ascii_case("auto"))
}

/// Compute the box model for one element inside a `available_width` container.
///
/// `box-sizing: border-box` subtracts padding and border from the declared
/// width, clamping at zero exactly as CSS requires, rather than going negative.
pub fn computed_box(style: &ComputedStyle, available_width: i32) -> R<BoxModel> {
    let padding = edge(style, "padding", "", available_width)?;
    let border = edge(style, "border", "-width", available_width)?;
    let mut margin = edge(style, "margin", "", available_width)?;

    let sizing = match style.get("box-sizing") {
        Some(v) if v.eq_ignore_ascii_case("border-box") => BoxSizing::BorderBox,
        _ => BoxSizing::ContentBox,
    };

    // An absent or `auto` width fills the container minus the element's own
    // horizontal edges — the block-layout default.
    let declared_width = match style.get("width") {
        Some(v) if !v.eq_ignore_ascii_case("auto") => Some(length(v, available_width)?),
        _ => None,
    };
    let mut content_width = match declared_width {
        Some(w) => w,
        None => available_width - margin.horizontal() - padding.horizontal() - border.horizontal(),
    };
    if matches!(sizing, BoxSizing::BorderBox) && declared_width.is_some() {
        content_width -= padding.horizontal() + border.horizontal();
    }

    // `min-width`/`max-width` clamp the *used* width. Both are expressed
    // against the same box the `width` property is, so `border-box` sizing
    // subtracts the edges from the clamp too.
    let edges = padding.horizontal() + border.horizontal();
    let clamp = |v: &str| -> R<i32> {
        let n = length(v, available_width)?;
        Ok(if matches!(sizing, BoxSizing::BorderBox) {
            (n - edges).max(0)
        } else {
            n
        })
    };
    if let Some(v) = style.get("max-width") {
        if !v.eq_ignore_ascii_case("none") && !v.eq_ignore_ascii_case("auto") {
            content_width = content_width.min(clamp(v)?);
        }
    }
    if let Some(v) = style.get("min-width") {
        if !v.eq_ignore_ascii_case("auto") {
            content_width = content_width.max(clamp(v)?);
        }
    }

    // CSS 10.3.3: an over-constrained block with `auto` horizontal margins
    // solves for them, which is the `margin: 0 auto` centered column. Without
    // this a `max-width` box just sits flush left.
    let auto_left = is_auto(style, "margin-left");
    let auto_right = is_auto(style, "margin-right");
    if auto_left || auto_right {
        let free = (available_width - content_width.max(0) - edges).max(0);
        match (auto_left, auto_right) {
            (true, true) => {
                margin.left = free / 2;
                margin.right = free - free / 2;
            }
            (true, false) => margin.left = free,
            _ => margin.right = free,
        }
    }

    let mut content_height = match style.get("height") {
        Some(v) if !v.eq_ignore_ascii_case("auto") => length(v, 0)?,
        _ => 0,
    };
    if matches!(sizing, BoxSizing::BorderBox) && content_height > 0 {
        content_height -= padding.vertical() + border.vertical();
    }

    Ok(BoxModel {
        content_width: content_width.max(0),
        content_height: content_height.max(0),
        padding,
        border,
        margin,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_selectors_declarations_and_important() {
        let sheet = parse("#status, .row.alt { color: red; width: 40px !important; }").unwrap();
        assert_eq!(sheet.rules.len(), 1);
        let rule = &sheet.rules[0];
        assert_eq!(rule.selectors.len(), 2);
        assert_eq!(rule.selectors[0].id.as_deref(), Some("status"));
        assert_eq!(rule.selectors[1].classes, vec!["row", "alt"]);
        assert_eq!(rule.declarations[0].value, "red");
        assert!(!rule.declarations[0].important);
        assert_eq!(rule.declarations[1].value, "40px");
        assert!(rule.declarations[1].important);
    }

    #[test]
    fn specificity_orders_id_over_class_over_element() {
        let id = Selector::parse("#a").specificity();
        let class = Selector::parse(".a").specificity();
        let elem = Selector::parse("div").specificity();
        assert!(id > class && class > elem);
        assert_eq!(Selector::parse("div.a.b").specificity(), (0, 2, 1));
        assert_eq!(Selector::parse("*").specificity(), (0, 0, 0));
    }

    #[test]
    fn unsupported_shapes_never_match_instead_of_mismatching() {
        for raw in ["div span", "a > b", "ul li.x", "[data-x]"] {
            let sel = Selector::parse(raw);
            assert!(!sel.matchable, "{raw} must not be matchable");
            assert!(!sel.matches(&ElementRef::new("div")));
            assert!(!sel.matches(&ElementRef::new("span")));
        }
    }

    #[test]
    fn matching_respects_element_id_and_all_classes() {
        let mut el = ElementRef::new("DIV");
        el.id = Some("status".into());
        el.classes = vec!["row".into(), "alt".into()];

        assert!(Selector::parse("*").matches(&el));
        assert!(Selector::parse("div").matches(&el));
        assert!(Selector::parse("#status").matches(&el));
        assert!(Selector::parse("div.row").matches(&el));
        assert!(Selector::parse(".row.alt").matches(&el));
        // A class the element lacks fails the whole compound selector.
        assert!(!Selector::parse(".row.missing").matches(&el));
        assert!(!Selector::parse("span").matches(&el));
        assert!(!Selector::parse("#other").matches(&el));
    }

    #[test]
    fn cascade_prefers_important_then_specificity_then_source_order() {
        let sheet = parse(
            "div { width: 1px; } \
             .row { width: 2px; } \
             #status { width: 3px; } \
             div { height: 10px; } \
             div { height: 20px; }",
        )
        .unwrap();
        let mut el = ElementRef::new("div");
        el.id = Some("status".into());
        el.classes = vec!["row".into()];

        let style = cascade(&sheet, &el);
        assert_eq!(style.get("width"), Some("3px"), "id wins on specificity");
        assert_eq!(style.get("height"), Some("20px"), "later source order wins");

        // !important on the weakest selector still outranks an id.
        let sheet = parse("div { width: 1px !important; } #status { width: 3px; }").unwrap();
        assert_eq!(cascade(&sheet, &el).get("width"), Some("1px"));
    }

    #[test]
    fn cascade_ignores_non_matching_rules_and_yields_empty_style() {
        let sheet = parse("span { width: 5px; }").unwrap();
        let style = cascade(&sheet, &ElementRef::new("div"));
        assert!(style.is_empty());
        assert_eq!(style.get("width"), None);
    }

    #[test]
    fn content_box_and_border_box_resolve_differently() {
        let sheet = parse(
            "div { width: 100px; padding-left: 10px; padding-right: 10px; \
             border-left-width: 5px; border-right-width: 5px; }",
        )
        .unwrap();
        let style = cascade(&sheet, &ElementRef::new("div"));
        let b = computed_box(&style, 640).unwrap();
        assert_eq!(b.content_width, 100, "content-box keeps the declared width");
        assert_eq!(b.border_box_width(), 130, "100 + 20 padding + 10 border");

        let sheet = parse(
            "div { box-sizing: border-box; width: 100px; \
             padding-left: 10px; padding-right: 10px; \
             border-left-width: 5px; border-right-width: 5px; }",
        )
        .unwrap();
        let style = cascade(&sheet, &ElementRef::new("div"));
        let b = computed_box(&style, 640).unwrap();
        assert_eq!(b.content_width, 70, "border-box subtracts padding + border");
        assert_eq!(
            b.border_box_width(),
            100,
            "declared width is the border box"
        );
    }

    #[test]
    fn auto_width_fills_the_container_minus_own_edges() {
        let sheet =
            parse("div { margin-left: 8px; margin-right: 8px; padding-left: 4px; }").unwrap();
        let style = cascade(&sheet, &ElementRef::new("div"));
        let b = computed_box(&style, 640).unwrap();
        assert_eq!(b.content_width, 640 - 16 - 4);
        assert_eq!(b.margin_box_width(), 640);
    }

    #[test]
    fn percent_lengths_resolve_against_the_container() {
        let sheet = parse("div { width: 50%; }").unwrap();
        let style = cascade(&sheet, &ElementRef::new("div"));
        assert_eq!(computed_box(&style, 640).unwrap().content_width, 320);
    }

    #[test]
    fn border_box_clamps_at_zero_instead_of_going_negative() {
        let sheet = parse(
            "div { box-sizing: border-box; width: 10px; \
             padding-left: 20px; padding-right: 20px; }",
        )
        .unwrap();
        let style = cascade(&sheet, &ElementRef::new("div"));
        let b = computed_box(&style, 640).unwrap();
        assert_eq!(b.content_width, 0, "clamped, never negative");
    }

    #[test]
    fn margin_box_accounts_for_every_edge_vertically() {
        let sheet = parse(
            "div { height: 20px; padding-top: 2px; padding-bottom: 3px; \
             border-top-width: 1px; margin-top: 4px; margin-bottom: 5px; }",
        )
        .unwrap();
        let style = cascade(&sheet, &ElementRef::new("div"));
        let b = computed_box(&style, 640).unwrap();
        assert_eq!(b.border_box_height(), 20 + 5 + 1);
        assert_eq!(b.margin_box_height(), 26 + 9);
    }

    #[test]
    fn unsupported_property_is_refused_not_ignored() {
        // Accepting `float` silently would let a feature row look landed.
        assert_eq!(
            parse("div { float: left; }"),
            Err(CssError::UnsupportedProperty("float".into()))
        );
    }

    #[test]
    fn malformed_and_oversized_input_fails_closed() {
        assert_eq!(parse("div { color: red;"), Err(CssError::UnterminatedBlock));
        assert_eq!(parse(", div { color: red; }"), Err(CssError::EmptySelector));
        let big = "a".repeat(MAX_SOURCE_BYTES + 1);
        assert!(matches!(parse(&big), Err(CssError::SourceTooLarge(_))));
        let many = "div { color: red; }".repeat(MAX_RULES + 1);
        assert_eq!(parse(&many), Err(CssError::TooManyRules));
    }

    #[test]
    fn fractional_and_unknown_units_are_refused() {
        for bad in ["1.5px", "2em", "3rem", "abc", "10pt"] {
            let css = format!("div {{ width: {bad}; }}");
            let sheet = parse(&css).unwrap();
            let style = cascade(&sheet, &ElementRef::new("div"));
            assert!(
                computed_box(&style, 640).is_err(),
                "{bad} must not resolve to a silently truncated pixel"
            );
        }
    }

    #[test]
    fn at_rules_are_skipped_whole_never_half_applied() {
        // Regression: taking the first '}' left the nested rule behind and
        // pushed a malformed `} span` rule instead of `span`.
        let sheet = parse("@media screen { div { width: 5px; } } span { color: red; }").unwrap();
        assert_eq!(sheet.rules.len(), 1);
        assert_eq!(sheet.rules[0].selectors[0].element.as_deref(), Some("span"));
        assert!(cascade(&sheet, &ElementRef::new("div")).is_empty());

        // Nested at-rules, and a statement at-rule with no block.
        let sheet = parse(
            "@supports (a:b) { @media screen { div { width: 5px; } } } \
             @import url(x.css); p { color: red; }",
        )
        .unwrap();
        assert_eq!(sheet.rules.len(), 1);
        assert_eq!(sheet.rules[0].selectors[0].element.as_deref(), Some("p"));

        // An unterminated at-rule block is refused, not silently consumed.
        assert_eq!(
            parse("@media screen { div { width: 5px; }"),
            Err(CssError::UnterminatedBlock)
        );
    }

    #[test]
    fn a_stray_closing_brace_is_refused() {
        assert_eq!(
            parse("} div { color: red; }"),
            Err(CssError::StrayBlockClose)
        );
    }

    #[test]
    fn comments_are_stripped_and_an_open_comment_does_not_leak_rules() {
        let sheet = parse("div { /* c */ width: 5px; } /* trailing").unwrap();
        assert_eq!(sheet.rules.len(), 1);
        assert_eq!(sheet.rules[0].declarations[0].value, "5px");
    }

    #[test]
    fn element_ref_projects_a_dom_node_including_split_classes() {
        let mut node = g6b_dom::Node::elem("DIV");
        node.id = Some("status".into());
        node.attributes
            .insert("class".into(), "  row   alt ".into());
        let el = ElementRef::from_node(&node);
        assert_eq!(el.name, "div");
        assert_eq!(el.classes, vec!["row", "alt"]);
        assert!(Selector::parse("div#status.row.alt").matches(&el));
    }
}
