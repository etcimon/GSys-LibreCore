// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Tiny arena DOM. Host objects in g6b-js will mutate this; the viewport paints it.

#![allow(missing_docs)]

mod event;
pub use event::*;

use std::collections::BTreeMap;

/// A node in the BIOS DOM.
#[derive(Debug, Clone)]
pub struct Node {
    pub name: String,
    pub id: Option<String>,
    pub text: String,
    pub children: Vec<Node>,
    pub dirty: bool,
    pub hidden: bool,
    pub attributes: BTreeMap<String, String>,
    pub event_listeners: Vec<event::Listener>,
}

impl Node {
    pub fn elem(name: &str) -> Self {
        Self {
            name: name.to_ascii_lowercase(),
            id: None,
            text: String::new(),
            children: Vec::new(),
            dirty: true,
            hidden: false,
            attributes: BTreeMap::new(),
            event_listeners: Vec::new(),
        }
    }

    pub fn text_node(text: &str) -> Self {
        Self {
            name: "#text".into(),
            id: None,
            text: text.to_string(),
            children: Vec::new(),
            dirty: true,
            hidden: false,
            attributes: BTreeMap::new(),
            event_listeners: Vec::new(),
        }
    }

    /// Depth-first find by `id` attribute.
    pub fn get_element_by_id(&mut self, id: &str) -> Option<&mut Node> {
        if self.id.as_deref() == Some(id) {
            return Some(self);
        }
        for c in &mut self.children {
            if let Some(n) = c.get_element_by_id(id) {
                return Some(n);
            }
        }
        None
    }

    /// Concatenate descendant text.
    pub fn inner_text(&self) -> String {
        if self.name == "#text" {
            return self.text.clone();
        }
        self.children.iter().map(|c| c.inner_text()).collect()
    }

    /// Replace children with a single text node (JS `innerText =`).
    pub fn set_inner_text(&mut self, t: &str) {
        if self.name == "#text" {
            if self.text != t {
                self.text = t.into();
                self.dirty = true;
            }
            return;
        }
        if (t.is_empty() && self.children.is_empty())
            || (self.children.len() == 1
                && self.children[0].name == "#text"
                && self.children[0].text == t)
        {
            return;
        }
        self.children = if t.is_empty() {
            Vec::new()
        } else {
            vec![Node::text_node(t)]
        };
        self.dirty = true;
    }

    pub fn get_attribute(&self, name: &str) -> Option<&str> {
        let name = name.to_ascii_lowercase();
        match name.as_str() {
            "id" => self.id.as_deref(),
            "hidden" => self.hidden.then(|| {
                self.attributes
                    .get("hidden")
                    .map(String::as_str)
                    .unwrap_or("")
            }),
            _ => self.attributes.get(&name).map(String::as_str),
        }
    }

    pub fn set_attribute(&mut self, name: &str, value: &str) -> Result<bool, String> {
        validate_attribute_name(name)?;
        if self.name == "#text" {
            return Err("text nodes have no attributes".into());
        }
        let name = name.to_ascii_lowercase();
        let changed = self.get_attribute(&name) != Some(value);
        if !changed {
            return Ok(false);
        }
        if name == "id" {
            self.id = Some(value.into());
        } else if name == "hidden" {
            self.hidden = true;
        }
        self.attributes.insert(name, value.into());
        self.dirty |= changed;
        Ok(changed)
    }

    pub fn remove_attribute(&mut self, name: &str) -> bool {
        let name = name.to_ascii_lowercase();
        let changed = self.get_attribute(&name).is_some();
        self.attributes.remove(&name);
        if name == "id" {
            self.id = None;
        } else if name == "hidden" {
            self.hidden = false;
        }
        self.dirty |= changed;
        changed
    }

    pub fn set_visible(&mut self, on: bool) {
        if on {
            self.remove_attribute("hidden");
        } else if !self.hidden {
            self.hidden = true;
            self.attributes.insert("hidden".into(), String::new());
            self.dirty = true;
        }
    }

    pub fn append_child(&mut self, child: Node) -> usize {
        let index = self.children.len();
        self.children.push(child);
        self.dirty = true;
        index
    }

    pub fn remove_child(&mut self, index: usize) -> Option<Node> {
        if index >= self.children.len() {
            return None;
        }
        self.dirty = true;
        Some(self.children.remove(index))
    }

    pub fn clear_dirty(&mut self) {
        self.dirty = false;
        for child in &mut self.children {
            child.clear_dirty();
        }
    }

    pub fn query_selector(&mut self, selector: &str) -> Result<Option<&mut Node>, String> {
        let selector = Selector::parse(selector)?;
        Ok(self
            .children
            .iter_mut()
            .find_map(|child| child.find_matching(&selector)))
    }

    pub fn query_selector_all(&self, selector: &str) -> Result<Vec<&Node>, String> {
        let selector = Selector::parse(selector)?;
        let mut out = Vec::new();
        for child in &self.children {
            child.collect_matching(&selector, &mut out);
        }
        Ok(out)
    }

    pub fn matches_selector(&self, selector: &str) -> Result<bool, String> {
        Ok(Selector::parse(selector)?.matches(self))
    }

    fn find_matching(&mut self, selector: &Selector) -> Option<&mut Node> {
        if selector.matches(self) {
            return Some(self);
        }
        self.children
            .iter_mut()
            .find_map(|child| child.find_matching(selector))
    }

    fn collect_matching<'a>(&'a self, selector: &Selector, out: &mut Vec<&'a Node>) {
        if selector.matches(self) {
            out.push(self);
        }
        for child in &self.children {
            child.collect_matching(selector, out);
        }
    }
}

pub fn validate_attribute_name(name: &str) -> Result<(), String> {
    if name.is_empty()
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | ':' | '.'))
    {
        Err("invalid attribute name".into())
    } else {
        Ok(())
    }
}

pub fn validate_element_name(name: &str) -> Result<(), String> {
    if !name.starts_with(|c: char| c.is_ascii_alphabetic())
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
    {
        Err("invalid element name".into())
    } else {
        Ok(())
    }
}

pub fn validate_selector(selector: &str) -> Result<(), String> {
    Selector::parse(selector).map(|_| ())
}

#[derive(Default)]
struct Selector {
    tag: Option<String>,
    ids: Vec<String>,
    classes: Vec<String>,
    attrs: Vec<(String, Option<String>)>,
}

impl Selector {
    fn parse(source: &str) -> Result<Self, String> {
        let mut rest = source.trim();
        if rest.is_empty() {
            return Err("empty selector".into());
        }
        let mut selector = Self::default();
        if let Some(tail) = rest.strip_prefix('*') {
            rest = tail;
        } else if rest.starts_with(|c: char| c.is_ascii_alphabetic()) {
            selector.tag = Some(selector_ident(&mut rest)?.to_ascii_lowercase());
        }
        while !rest.is_empty() {
            let prefix = rest.chars().next().ok_or("empty selector")?;
            rest = &rest[prefix.len_utf8()..];
            match prefix {
                '#' => selector.ids.push(selector_ident(&mut rest)?.into()),
                '.' => selector.classes.push(selector_ident(&mut rest)?.into()),
                '[' => {
                    rest = rest.trim_start();
                    let name = selector_ident(&mut rest)?.to_ascii_lowercase();
                    rest = rest.trim_start();
                    let value = if let Some(tail) = rest.strip_prefix('=') {
                        rest = tail.trim_start();
                        let value = if rest.starts_with(['\'', '"']) {
                            let quote = rest.as_bytes()[0] as char;
                            rest = &rest[1..];
                            let end = rest.find(quote).ok_or("unterminated attribute selector")?;
                            let value = rest[..end].to_string();
                            if value.contains(['\\', '\n', '\r']) {
                                return Err("unsupported attribute selector escape".into());
                            }
                            rest = &rest[end + 1..];
                            value
                        } else {
                            selector_ident(&mut rest)?.into()
                        };
                        rest = rest.trim_start();
                        Some(value)
                    } else {
                        None
                    };
                    rest = rest.strip_prefix(']').ok_or("expected ] in selector")?;
                    selector.attrs.push((name, value));
                }
                _ => {
                    return Err(
                        "unsupported selector; use a single tag/id/class/attribute compound".into(),
                    )
                }
            }
        }
        Ok(selector)
    }

    fn matches(&self, node: &Node) -> bool {
        node.name != "#text"
            && node.name != "document"
            && self
                .tag
                .as_ref()
                .map(|tag| node.name.eq_ignore_ascii_case(tag))
                .unwrap_or(true)
            && self.ids.iter().all(|id| node.id.as_ref() == Some(id))
            && self.classes.iter().all(|class| {
                node.get_attribute("class")
                    .unwrap_or("")
                    .split_ascii_whitespace()
                    .any(|c| c == class)
            })
            && self.attrs.iter().all(|(name, value)| {
                node.get_attribute(name)
                    .map(|actual| value.as_ref().map(|v| actual == v).unwrap_or(true))
                    .unwrap_or(false)
            })
    }
}

fn selector_ident<'a>(rest: &mut &'a str) -> Result<&'a str, String> {
    let end = rest
        .find(|c: char| !c.is_ascii_alphanumeric() && !matches!(c, '-' | '_'))
        .unwrap_or(rest.len());
    if end == 0 {
        return Err("expected selector identifier".into());
    }
    let value = &rest[..end];
    *rest = &rest[end..];
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mutation_locality_and_visibility() {
        let mut root = Node::elem("document");
        let mut item = Node::elem("div");
        item.set_attribute("id", "item").unwrap();
        item.set_inner_text("retained");
        root.append_child(item);
        root.append_child(Node::elem("aside"));
        root.clear_dirty();
        let item = root.get_element_by_id("item").unwrap();
        item.set_inner_text("retained");
        item.set_attribute("ID", "item").unwrap();
        item.remove_attribute("absent");
        item.set_visible(true);
        assert!(!item.dirty);
        item.set_visible(false);
        assert!(item.hidden);
        assert_eq!(item.get_attribute("hidden"), Some(""));
        assert_eq!(item.inner_text(), "retained");
        item.clear_dirty();
        item.set_visible(false);
        assert!(!item.dirty);
        item.set_visible(true);
        assert_eq!(item.inner_text(), "retained");
        assert!(!root.dirty);
        assert!(!root.children[1].dirty);
    }

    #[test]
    fn selectors_and_child_mutations_are_deterministic() {
        let mut root = Node::elem("document");
        for id in ["one", "two"] {
            let mut child = Node::elem("p");
            child.set_attribute("id", id).unwrap();
            child.set_attribute("class", "row active").unwrap();
            child.set_attribute("data-x", "a b").unwrap();
            root.append_child(child);
        }
        assert_eq!(
            root.query_selector("p.row[data-x='a b']")
                .unwrap()
                .unwrap()
                .id
                .as_deref(),
            Some("one")
        );
        assert_eq!(root.query_selector_all(".active").unwrap().len(), 2);
        assert!(root.query_selector("p > .row").is_err());
        assert!(root.query_selector("[data-x=").is_err());
        root.clear_dirty();
        assert!(root.remove_child(9).is_none());
        assert!(!root.dirty);
        assert_eq!(root.remove_child(0).unwrap().id.as_deref(), Some("one"));
        assert!(root.dirty);
        assert!(!root.children[0].dirty);
    }

    #[test]
    fn text_node_writes_and_structural_replacement() {
        let mut text = Node::text_node("old");
        text.set_inner_text("new");
        assert_eq!(text.inner_text(), "new");
        assert!(text.children.is_empty());
        let mut parent = Node::elem("p");
        let mut child = Node::elem("span");
        child.set_inner_text("same");
        parent.append_child(child);
        parent.clear_dirty();
        parent.set_inner_text("same");
        assert!(parent.dirty);
        assert_eq!(parent.children[0].name, "#text");
    }

    #[test]
    fn selectors_exclude_receiver_and_reflect_attributes() {
        let mut node = Node::elem("div");
        node.set_attribute("id", "root").unwrap();
        assert!(node.query_selector("#root").unwrap().is_none());
        assert!(node.matches_selector("div#root").unwrap());
        node.set_attribute("hidden", "false").unwrap();
        assert!(node.hidden);
        assert!(node.matches_selector("[hidden='false']").unwrap());
        node.set_visible(true);
        assert!(!node.matches_selector("[hidden]").unwrap());
        node.set_attribute("id", "new").unwrap();
        assert!(node.get_element_by_id("root").is_none());
        assert!(node.get_element_by_id("new").is_some());
        node.clear_dirty();
        assert!(node.set_attribute("bad name", "value").is_err());
        assert!(!node.dirty);
        for selector in [
            "é",
            "divé",
            "#é",
            "",
            "[]",
            "div,span",
            "[id='x'",
            "div:hover",
            "[id^=x]",
        ] {
            assert!(validate_selector(selector).is_err(), "{selector}");
        }
    }

    #[test]
    fn inner_text_set_dirties() {
        let mut root = Node::elem("div");
        root.id = Some("opp".into());
        root.set_inner_text("perf");
        assert_eq!(root.inner_text(), "perf");
        assert!(root.dirty);
    }
}
