// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Tiny arena DOM. Host objects in g6b-js will mutate this; the viewport paints it.

#![allow(missing_docs)]

/// A node in the BIOS DOM.
#[derive(Debug, Clone)]
pub struct Node {
    pub name: String,
    pub id: Option<String>,
    pub text: String,
    pub children: Vec<Node>,
    pub dirty: bool,
}

impl Node {
    pub fn elem(name: &str) -> Self {
        Self {
            name: name.to_string(),
            id: None,
            text: String::new(),
            children: Vec::new(),
            dirty: true,
        }
    }

    pub fn text_node(text: &str) -> Self {
        Self {
            name: "#text".into(),
            id: None,
            text: text.to_string(),
            children: Vec::new(),
            dirty: true,
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
        self.children = vec![Node::text_node(t)];
        self.dirty = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inner_text_set_dirties() {
        let mut root = Node::elem("div");
        root.id = Some("opp".into());
        root.set_inner_text("perf");
        assert_eq!(root.inner_text(), "perf");
        assert!(root.dirty);
    }
}
