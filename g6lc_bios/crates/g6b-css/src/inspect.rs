// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Render debugging: a DevTools-shaped explanation of *why* a computed value
//! is what it is, plus a box-model report.
//!
//! Modelled on the browser DevTools "Styles"/"Computed" panes — winning
//! declaration first, overridden candidates listed with the reason they lost —
//! and on `kernel-spec/goosie`'s `internal/css` cascade ordering, which this
//! crate rewrote (see `lib.rs` module note). Nothing here is part of the BIOS
//! render path: it is a build-time and browser-console developer facility.
//!
//! Why this exists: the slow part of growing a style engine is not writing the
//! layout, it is answering "which rule won, and why is this box 3px wide".
//! [`explain`] answers both in one call so a wrong pixel becomes a wrong
//! *declaration*, which is a fixable thing.

use crate::{cascade, computed_box, BoxModel, ElementRef, Specificity, Stylesheet};

/// Why a candidate declaration did not win.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// This declaration supplies the computed value.
    Won,
    /// An `!important` declaration outranked it.
    LostToImportant,
    /// A more specific selector outranked it.
    LostToSpecificity,
    /// Equal specificity; a later rule in source order outranked it.
    LostToSourceOrder,
}

impl Outcome {
    /// Short label for the text dump.
    pub fn label(&self) -> &'static str {
        match self {
            Self::Won => "won",
            Self::LostToImportant => "lost: !important",
            Self::LostToSpecificity => "lost: specificity",
            Self::LostToSourceOrder => "lost: source order",
        }
    }
}

/// One declaration that was considered for a property.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    /// The matching selector text, as authored.
    pub selector: String,
    pub value: String,
    pub important: bool,
    pub specificity: Specificity,
    /// Index of the rule in source order.
    pub source_order: usize,
    pub outcome: Outcome,
}

/// Every candidate for one property, winner first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PropertyTrace {
    pub property: String,
    /// The computed value, i.e. the winning candidate's value.
    pub value: String,
    pub candidates: Vec<Candidate>,
}

/// A full inspection of one element.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StyleReport {
    /// `div#status.row` — the element as a selector, for log correlation.
    pub element: String,
    /// Selectors that matched, with their specificity and source order.
    pub matched: Vec<(String, Specificity, usize)>,
    /// One trace per computed property, sorted by property name.
    pub properties: Vec<PropertyTrace>,
    /// The resolved box, or the error text if a length was refused.
    pub box_model: Result<BoxModel, String>,
}

fn describe(el: &ElementRef) -> String {
    let mut s = el.name.clone();
    if let Some(ref id) = el.id {
        s.push('#');
        s.push_str(id);
    }
    for c in &el.classes {
        s.push('.');
        s.push_str(c);
    }
    s
}

/// Explain the cascade and box model for `el` inside an `available_width`
/// container.
///
/// The winner is taken from [`cascade`] itself rather than recomputed, so this
/// report can never disagree with the engine it is describing — a debugger that
/// lies about the thing it debugs is worse than no debugger.
pub fn explain(sheet: &Stylesheet, el: &ElementRef, available_width: i32) -> StyleReport {
    let winners = cascade(sheet, el);

    let mut matched = Vec::new();
    for (order, rule) in sheet.rules.iter().enumerate() {
        for sel in rule.selectors.iter().filter(|s| s.matches(el)) {
            matched.push((sel.raw.clone(), sel.specificity(), order));
        }
    }

    // Collect every candidate per property, then classify against the winner.
    let mut traces: Vec<PropertyTrace> = Vec::new();
    for (order, rule) in sheet.rules.iter().enumerate() {
        let Some((sel_text, spec)) = rule
            .selectors
            .iter()
            .filter(|s| s.matches(el))
            .map(|s| (s.raw.clone(), s.specificity()))
            .max_by_key(|(_, spec)| *spec)
        else {
            continue;
        };
        for decl in &rule.declarations {
            let cand = Candidate {
                selector: sel_text.clone(),
                value: decl.value.clone(),
                important: decl.important,
                specificity: spec,
                source_order: order,
                outcome: Outcome::Won, // classified below
            };
            match traces.iter_mut().find(|t| t.property == decl.property) {
                Some(t) => t.candidates.push(cand),
                None => traces.push(PropertyTrace {
                    property: decl.property.clone(),
                    value: String::new(),
                    candidates: vec![cand],
                }),
            }
        }
    }

    for trace in &mut traces {
        let computed = winners.get(&trace.property).unwrap_or("").to_string();
        trace.value = computed.clone();
        // The winner is the highest (important, specificity, source_order)
        // candidate whose value is the computed one.
        let win_key = trace
            .candidates
            .iter()
            .filter(|c| c.value == computed)
            .map(|c| (u32::from(c.important), c.specificity, c.source_order))
            .max();
        for cand in &mut trace.candidates {
            let key = (
                u32::from(cand.important),
                cand.specificity,
                cand.source_order,
            );
            cand.outcome = match win_key {
                Some(w) if key == w => Outcome::Won,
                Some(w) if w.0 > key.0 => Outcome::LostToImportant,
                Some(w) if w.1 > key.1 => Outcome::LostToSpecificity,
                _ => Outcome::LostToSourceOrder,
            };
        }
        // Winner first, then strongest-to-weakest, matching DevTools ordering.
        trace.candidates.sort_by(|a, b| {
            let key = |c: &Candidate| {
                (
                    c.outcome != Outcome::Won,
                    std::cmp::Reverse((u32::from(c.important), c.specificity, c.source_order)),
                )
            };
            key(a).cmp(&key(b))
        });
    }
    traces.sort_by(|a, b| a.property.cmp(&b.property));

    StyleReport {
        element: describe(el),
        matched,
        properties: traces,
        box_model: computed_box(&winners, available_width).map_err(|e| e.to_string()),
    }
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

impl StyleReport {
    /// DevTools-shaped text dump for a serial log or a console.
    ///
    /// Overridden declarations are kept visible rather than discarded — the
    /// reason a value lost is the actionable part when a pixel is wrong.
    pub fn to_text(&self) -> String {
        let mut out = String::new();
        out.push_str(&self.element);
        out.push('\n');

        out.push_str("  matched: ");
        if self.matched.is_empty() {
            out.push_str("(none)");
        } else {
            let list: Vec<String> = self
                .matched
                .iter()
                .map(|(sel, sp, ord)| format!("{sel} ({},{},{}) @{ord}", sp.0, sp.1, sp.2))
                .collect();
            out.push_str(&list.join(", "));
        }
        out.push('\n');

        for trace in &self.properties {
            out.push_str(&format!("  {}: {}\n", trace.property, trace.value));
            for c in &trace.candidates {
                out.push_str(&format!(
                    "    {} {:<20} {:<10} ({},{},{}) @{}{}  {}\n",
                    if c.outcome == Outcome::Won { "*" } else { "-" },
                    c.selector,
                    c.value,
                    c.specificity.0,
                    c.specificity.1,
                    c.specificity.2,
                    c.source_order,
                    if c.important { " !" } else { "  " },
                    c.outcome.label(),
                ));
            }
        }

        match &self.box_model {
            Ok(b) => {
                out.push_str(&format!(
                    "  box: content {}x{}  padding {},{},{},{}  border {},{},{},{}  margin {},{},{},{}\n",
                    b.content_width, b.content_height,
                    b.padding.top, b.padding.right, b.padding.bottom, b.padding.left,
                    b.border.top, b.border.right, b.border.bottom, b.border.left,
                    b.margin.top, b.margin.right, b.margin.bottom, b.margin.left,
                ));
                out.push_str(&format!(
                    "       border-box {}x{}  margin-box {}x{}\n",
                    b.border_box_width(),
                    b.border_box_height(),
                    b.margin_box_width(),
                    b.margin_box_height(),
                ));
            }
            Err(e) => out.push_str(&format!("  box: REFUSED ({e})\n")),
        }
        out
    }

    /// Machine-readable form, for the browser-side inspector to diff against
    /// `getComputedStyle`. Hand-rolled because KD0 forbids crates.io deps.
    pub fn to_json(&self) -> String {
        let props: Vec<String> = self
            .properties
            .iter()
            .map(|t| {
                let cands: Vec<String> = t
                    .candidates
                    .iter()
                    .map(|c| {
                        format!(
                            r#"{{"selector":"{}","value":"{}","important":{},"specificity":[{},{},{}],"order":{},"outcome":"{}"}}"#,
                            json_escape(&c.selector),
                            json_escape(&c.value),
                            c.important,
                            c.specificity.0,
                            c.specificity.1,
                            c.specificity.2,
                            c.source_order,
                            c.outcome.label(),
                        )
                    })
                    .collect();
                format!(
                    r#"{{"property":"{}","value":"{}","candidates":[{}]}}"#,
                    json_escape(&t.property),
                    json_escape(&t.value),
                    cands.join(",")
                )
            })
            .collect();

        let boxes = match &self.box_model {
            Ok(b) => format!(
                r#"{{"contentWidth":{},"contentHeight":{},"borderBoxWidth":{},"borderBoxHeight":{},"marginBoxWidth":{},"marginBoxHeight":{},"padding":[{},{},{},{}],"border":[{},{},{},{}],"margin":[{},{},{},{}]}}"#,
                b.content_width,
                b.content_height,
                b.border_box_width(),
                b.border_box_height(),
                b.margin_box_width(),
                b.margin_box_height(),
                b.padding.top,
                b.padding.right,
                b.padding.bottom,
                b.padding.left,
                b.border.top,
                b.border.right,
                b.border.bottom,
                b.border.left,
                b.margin.top,
                b.margin.right,
                b.margin.bottom,
                b.margin.left,
            ),
            Err(e) => format!(r#"{{"refused":"{}"}}"#, json_escape(e)),
        };

        format!(
            r#"{{"element":"{}","properties":[{}],"box":{}}}"#,
            json_escape(&self.element),
            props.join(","),
            boxes
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{parse, parse_survey};

    fn el() -> ElementRef {
        let mut el = ElementRef::new("div");
        el.id = Some("status".into());
        el.classes = vec!["row".into()];
        el
    }

    #[test]
    fn explain_names_the_winner_and_why_each_loser_lost() {
        let sheet =
            parse("div { width: 1px; } .row { width: 2px; } #status { width: 3px; }").unwrap();
        let report = explain(&sheet, &el(), 640);

        let width = report
            .properties
            .iter()
            .find(|t| t.property == "width")
            .expect("width trace");
        assert_eq!(width.value, "3px");
        assert_eq!(width.candidates.len(), 3);
        // Winner first.
        assert_eq!(width.candidates[0].selector, "#status");
        assert_eq!(width.candidates[0].outcome, Outcome::Won);
        for c in &width.candidates[1..] {
            assert_eq!(c.outcome, Outcome::LostToSpecificity, "{}", c.selector);
        }
    }

    #[test]
    fn explain_distinguishes_important_from_specificity_and_source_order() {
        let sheet = parse("div { width: 1px !important; } #status { width: 3px; }").unwrap();
        let width = &explain(&sheet, &el(), 640).properties[0];
        assert_eq!(width.value, "1px");
        let loser = width
            .candidates
            .iter()
            .find(|c| c.selector == "#status")
            .unwrap();
        assert_eq!(loser.outcome, Outcome::LostToImportant);

        let sheet = parse("div { height: 1px; } div { height: 2px; }").unwrap();
        let height = &explain(&sheet, &el(), 640).properties[0];
        assert_eq!(height.value, "2px");
        let loser = height
            .candidates
            .iter()
            .find(|c| c.source_order == 0)
            .unwrap();
        assert_eq!(loser.outcome, Outcome::LostToSourceOrder);
    }

    #[test]
    fn explain_agrees_with_the_engine_it_describes() {
        // The report must never disagree with cascade(); that is the whole
        // point of reading the winner out of the engine.
        let sheet = parse(
            "div { width: 1px; } .row { width: 2px !important; } \
             #status { width: 3px; } div { height: 7px; }",
        )
        .unwrap();
        let el = el();
        let style = crate::cascade(&sheet, &el);
        let report = explain(&sheet, &el, 640);
        for trace in &report.properties {
            assert_eq!(
                Some(trace.value.as_str()),
                style.get(&trace.property),
                "{} disagrees with cascade()",
                trace.property
            );
        }
    }

    #[test]
    fn explain_reports_matched_selectors_and_no_match() {
        let sheet = parse("span { width: 1px; }").unwrap();
        let report = explain(&sheet, &el(), 640);
        assert!(report.matched.is_empty());
        assert!(report.properties.is_empty());
        assert_eq!(report.element, "div#status.row");
    }

    #[test]
    fn text_dump_is_devtools_shaped_and_keeps_overridden_rules_visible() {
        let sheet = parse("div { width: 1px; } #status { width: 3px; }").unwrap();
        let text = explain(&sheet, &el(), 640).to_text();
        assert!(text.starts_with("div#status.row\n"));
        assert!(text.contains("matched: div (0,0,1) @0, #status (1,0,0) @1"));
        assert!(text.contains("width: 3px"));
        assert!(text.contains("* #status"), "winner marked with *");
        assert!(text.contains("- div"), "loser stays visible");
        assert!(text.contains("lost: specificity"));
        assert!(text.contains("border-box"));
    }

    #[test]
    fn a_refused_length_is_reported_not_hidden() {
        let sheet = parse("div { width: 2em; }").unwrap();
        let report = explain(&sheet, &el(), 640);
        assert!(report.box_model.is_err());
        assert!(report.to_text().contains("box: REFUSED"));
        assert!(report.to_json().contains("\"refused\""));
    }

    #[test]
    fn json_is_well_formed_and_escapes_hostile_values() {
        let sheet = parse("div { width: 3px; }").unwrap();
        let json = explain(&sheet, &el(), 640).to_json();
        assert!(json.starts_with('{') && json.ends_with('}'));
        assert!(json.contains(r#""element":"div#status.row""#));
        assert!(json.contains(r#""outcome":"won""#));
        assert!(json.contains(r#""borderBoxWidth":3"#));
        // Quotes and backslashes in a value cannot break out of the string.
        assert_eq!(json_escape(r#"a"b\c"#), r#"a\"b\\c"#);
        assert_eq!(json_escape("a\nb"), "a\\nb");
    }

    #[test]
    fn survey_lists_missing_features_instead_of_refusing_the_sheet() {
        // The fast loop for growing fixtures/css-features.json.
        let (sheet, missing) = parse_survey(
            "div { width: 10px; float: left; display: flex; gap: 4px; float: right; }",
        )
        .unwrap();
        // `gap` landed with flexbox; `float` is still refused.
        assert_eq!(missing, vec!["float"], "sorted and de-duplicated");
        // Supported declarations still land, so layout can be inspected.
        let style = crate::cascade(&sheet, &ElementRef::new("div"));
        assert_eq!(style.get("width"), Some("10px"));
        assert_eq!(style.get("display"), Some("flex"));
        // The strict render path still refuses the same sheet.
        assert!(parse("div { float: left; }").is_err());
    }
}
