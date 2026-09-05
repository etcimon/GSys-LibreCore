// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Goja-shaped ES5 subset: AOT `document.getElementById(id).innerText = "…"`.
//!
//! Host objects live on [`g6b_dom::Node`]. No Go runtime, no live eval in B0.

#![allow(missing_docs)]

use g6b_dom::Node;
use std::collections::BTreeMap;

mod r#async;
pub use r#async::{
    compile_async, compile_async_with_limits, AsyncCompileError, AsyncEvent, AsyncFailure,
    AsyncLimit, AsyncLimits, AsyncProgram, AsyncScheduler, AsyncSpawnError, AsyncTick, AsyncTrap,
    CompletionStatus, JsException, JsExceptionKind, RequestToken, TaskId,
};

/// Bytecode op against the BIOS DOM.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    /// `document.getElementById(id).innerText = value`
    SetInnerText {
        id: String,
        value: String,
    },
    /// `console.log(value)` — WebIDL Console (live).
    Log {
        value: String,
    },
    /// `document.getElementById(id).getContext("webgl"|"opengl")`
    GetContext {
        id: String,
        kind: String,
    },
    /// `fetch("/bios/...")` — proxied to the kernel HTTP router.
    Fetch {
        method: String,
        url: String,
    },
    /// `kernel.register("/bios/custom")` — JS endpoint, same table as HolyC.
    RegisterEndpoint {
        method: String,
        path: String,
    },
    /// `kernel.holyc("UsbLs(\"fat32\")")` — HolyC REPL line (browser-ui jsExports).
    HolycEval {
        line: String,
    },
    SetAttribute {
        id: String,
        name: String,
        value: String,
    },
    RemoveAttribute {
        id: String,
        name: String,
    },
    SetVisible {
        id: String,
        on: bool,
    },
    AppendChild {
        id: String,
        tag: String,
    },
    AppendText {
        id: String,
        value: String,
    },
    RemoveChild {
        id: String,
        child_id: String,
    },
    QuerySelector {
        selector: String,
        mutation: Mutation,
    },
    DomTransaction {
        program: DomProgram,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mutation {
    SetInnerText { value: String },
    SetAttribute { name: String, value: String },
    RemoveAttribute { name: String },
    SetVisible { on: bool },
    AppendChild { tag: String },
    AppendText { value: String },
    RemoveChild { child_id: String },
}

const DOM_NODE_LIMIT: usize = 4096;
const DOM_DEPTH_LIMIT: usize = 64;
const DOM_BYTE_LIMIT: usize = 4_194_304;
const DOM_STEP_LIMIT: usize = 16_384;
const DOM_WORK_LIMIT: usize = 1_048_576;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DomProgram {
    steps: Vec<DomStep>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Target {
    Id(String),
    Selector(String),
    Handle(usize),
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum DomStep {
    Create {
        handle: usize,
        name: String,
        text: bool,
    },
    Lookup {
        handle: usize,
        target: Target,
    },
    Mutate {
        target: Target,
        mutation: Mutation,
    },
    Append {
        parent: Target,
        child: usize,
    },
    Remove {
        parent: Target,
        child: usize,
    },
}

impl Target {
    fn size(&self) -> usize {
        match self {
            Self::Id(value) | Self::Selector(value) => value.len(),
            Self::Handle(_) => 8,
        }
    }
}

impl DomStep {
    fn size(&self) -> usize {
        16 + match self {
            Self::Create { name, .. } => name.len(),
            Self::Lookup { target, .. } => target.size(),
            Self::Mutate { target, mutation } => target.size() + mutation_size(mutation),
            Self::Append { parent, .. } | Self::Remove { parent, .. } => parent.size(),
        }
    }
}

fn mutation_size(mutation: &Mutation) -> usize {
    match mutation {
        Mutation::SetInnerText { value } | Mutation::AppendText { value } => value.len(),
        Mutation::SetAttribute { name, value } => name.len() + value.len(),
        Mutation::RemoveAttribute { name } => name.len(),
        Mutation::SetVisible { .. } => 1,
        Mutation::AppendChild { tag } => tag.len(),
        Mutation::RemoveChild { child_id } => child_id.len(),
    }
}

fn dom_step(op: &Op) -> Option<DomStep> {
    let (id, mutation) = match op {
        Op::SetInnerText { id, value } => (
            id,
            Mutation::SetInnerText {
                value: value.clone(),
            },
        ),
        Op::SetAttribute { id, name, value } => (
            id,
            Mutation::SetAttribute {
                name: name.clone(),
                value: value.clone(),
            },
        ),
        Op::RemoveAttribute { id, name } => (id, Mutation::RemoveAttribute { name: name.clone() }),
        Op::SetVisible { id, on } => (id, Mutation::SetVisible { on: *on }),
        Op::AppendChild { id, tag } => (id, Mutation::AppendChild { tag: tag.clone() }),
        Op::AppendText { id, value } => (
            id,
            Mutation::AppendText {
                value: value.clone(),
            },
        ),
        Op::RemoveChild { id, child_id } => (
            id,
            Mutation::RemoveChild {
                child_id: child_id.clone(),
            },
        ),
        Op::QuerySelector { selector, mutation } => {
            return Some(DomStep::Mutate {
                target: Target::Selector(selector.clone()),
                mutation: mutation.clone(),
            })
        }
        _ => return None,
    };
    Some(DomStep::Mutate {
        target: Target::Id(id.clone()),
        mutation,
    })
}

struct ArenaNode {
    data: Node,
    parent: Option<usize>,
    children: Vec<usize>,
}

struct DomArena {
    nodes: Vec<ArenaNode>,
    handles: Vec<Option<usize>>,
    bytes: usize,
    work: usize,
}

fn node_bytes(node: &Node) -> usize {
    node.name.len()
        + node.text.len()
        + node.id.as_ref().map_or(0, String::len)
        + node
            .attributes
            .iter()
            .map(|(name, value)| name.len() + value.len())
            .sum::<usize>()
}

fn check_dom(
    node: &Node,
    depth: usize,
    count: &mut usize,
    bytes: &mut usize,
) -> Result<(), String> {
    if depth > DOM_DEPTH_LIMIT {
        return Err("DOM depth budget exceeded".into());
    }
    *count += 1;
    if *count > DOM_NODE_LIMIT {
        return Err("DOM node budget exceeded".into());
    }
    *bytes = bytes.saturating_add(node_bytes(node));
    if *bytes > DOM_BYTE_LIMIT {
        return Err("DOM byte budget exceeded".into());
    }
    for child in &node.children {
        check_dom(child, depth + 1, count, bytes)?;
    }
    Ok(())
}

impl DomArena {
    fn import(&mut self, mut node: Node, parent: Option<usize>) -> usize {
        let children = std::mem::take(&mut node.children);
        let id = self.nodes.len();
        self.nodes.push(ArenaNode {
            data: node,
            parent,
            children: Vec::new(),
        });
        for child in children {
            let child_id = self.import(child, Some(id));
            self.nodes[id].children.push(child_id);
        }
        id
    }

    fn spend(&mut self, cost: usize) -> Result<(), String> {
        self.work = self
            .work
            .checked_sub(cost)
            .ok_or("DOM work budget exceeded")?;
        Ok(())
    }

    fn allocate(&mut self, node: Node) -> Result<usize, String> {
        if self.nodes.len() >= DOM_NODE_LIMIT {
            return Err("DOM node budget exceeded".into());
        }
        self.bytes += node_bytes(&node);
        if self.bytes > DOM_BYTE_LIMIT {
            return Err("DOM byte budget exceeded".into());
        }
        Ok(self.import(node, None))
    }

    fn handle(&self, handle: usize) -> Result<usize, String> {
        self.handles
            .get(handle)
            .copied()
            .flatten()
            .ok_or_else(|| "null or invalid DOM handle".into())
    }

    fn bind(&mut self, handle: usize, node: Option<usize>) -> Result<(), String> {
        if handle != self.handles.len() || handle >= DOM_NODE_LIMIT {
            return Err("invalid DOM handle sequence".into());
        }
        self.handles.push(node);
        Ok(())
    }

    fn lookup(&mut self, target: &Target) -> Result<Option<usize>, String> {
        if let Target::Handle(handle) = target {
            return self.handle(*handle).map(Some);
        }
        let mut stack = match target {
            Target::Selector(selector) => {
                g6b_dom::validate_selector(selector)?;
                self.nodes[0]
                    .children
                    .iter()
                    .rev()
                    .copied()
                    .collect::<Vec<_>>()
            }
            _ => vec![0],
        };
        while let Some(id) = stack.pop() {
            self.spend(1 + target.size())?;
            let node = &self.nodes[id];
            let found = match target {
                Target::Id(value) => {
                    !value.is_empty()
                        && node.data.name != "#text"
                        && node.data.id.as_ref() == Some(value)
                }
                Target::Selector(value) => node.data.matches_selector(value)?,
                Target::Handle(_) => false,
            };
            if found {
                return Ok(Some(id));
            }
            stack.extend(node.children.iter().rev().copied());
        }
        Ok(None)
    }

    fn resolve(&mut self, target: &Target) -> Result<usize, String> {
        self.lookup(target)?
            .ok_or_else(|| format!("null DOM target {target:?}"))
    }

    fn detach(&mut self, child: usize) -> Result<(), String> {
        if let Some(parent) = self.nodes[child].parent {
            self.spend(self.nodes[parent].children.len())?;
            self.nodes[child].parent = None;
            self.nodes[parent].children.retain(|&id| id != child);
            self.nodes[parent].data.dirty = true;
        }
        Ok(())
    }

    fn append(&mut self, parent: usize, child: usize) -> Result<(), String> {
        if self.nodes[parent].data.name == "#text" || child == 0 {
            return Err("invalid DOM parent or document child".into());
        }
        let mut ancestor = Some(parent);
        let mut depth = 0;
        while let Some(id) = ancestor {
            self.spend(1)?;
            if id == child {
                return Err("DOM hierarchy cycle".into());
            }
            depth += 1;
            ancestor = self.nodes[id].parent;
        }
        let mut stack = vec![(child, depth)];
        while let Some((id, depth)) = stack.pop() {
            self.spend(1)?;
            if depth > DOM_DEPTH_LIMIT {
                return Err("DOM depth budget exceeded".into());
            }
            stack.extend(self.nodes[id].children.iter().map(|&id| (id, depth + 1)));
        }
        self.detach(child)?;
        self.nodes[parent].children.push(child);
        self.nodes[parent].data.dirty = true;
        self.nodes[child].parent = Some(parent);
        Ok(())
    }

    fn remove(&mut self, parent: usize, child: usize) -> Result<(), String> {
        if self.nodes[child].parent != Some(parent) {
            return Err("removeChild target is not a direct child".into());
        }
        self.detach(child)?;
        Ok(())
    }

    fn mutate(&mut self, id: usize, mutation: &Mutation) -> Result<(), String> {
        self.spend(1 + self.nodes[id].data.attributes.len() * 2)?;
        let old_bytes = node_bytes(&self.nodes[id].data);
        if self.nodes[id].data.name == "#text"
            && matches!(
                mutation,
                Mutation::SetAttribute { .. }
                    | Mutation::RemoveAttribute { .. }
                    | Mutation::SetVisible { .. }
            )
        {
            return Err("text nodes have no element attributes".into());
        }
        match mutation {
            Mutation::SetInnerText { value } if self.nodes[id].data.name != "#text" => {
                self.spend(self.nodes[id].children.len())?;
                let children = &self.nodes[id].children;
                let unchanged = if value.is_empty() {
                    children.is_empty()
                } else {
                    children.len() == 1
                        && self.nodes[children[0]].data.name == "#text"
                        && self.nodes[children[0]].data.text == *value
                };
                let dirty = self.nodes[id].data.dirty;
                let text_dirty = !unchanged
                    || children
                        .first()
                        .is_some_and(|&id| self.nodes[id].data.dirty);
                for child in std::mem::take(&mut self.nodes[id].children) {
                    self.nodes[child].parent = None;
                }
                if !value.is_empty() {
                    let mut node = Node::text_node(value);
                    node.dirty = text_dirty;
                    let text = self.allocate(node)?;
                    self.append(id, text)?;
                }
                self.nodes[id].data.dirty = dirty || !unchanged;
            }
            Mutation::AppendChild { tag } => {
                g6b_dom::validate_element_name(tag)?;
                let child = self.allocate(Node::elem(tag))?;
                self.append(id, child)?;
            }
            Mutation::AppendText { value } => {
                let child = self.allocate(Node::text_node(value))?;
                self.append(id, child)?;
            }
            Mutation::RemoveChild { child_id } => {
                let child = self.resolve(&Target::Id(child_id.clone()))?;
                self.remove(id, child)?;
            }
            _ => apply_mutation(&mut self.nodes[id].data, mutation)?,
        }
        self.bytes = self.bytes - old_bytes + node_bytes(&self.nodes[id].data);
        if self.bytes > DOM_BYTE_LIMIT {
            return Err("DOM byte budget exceeded".into());
        }
        Ok(())
    }

    fn export(&self, id: usize) -> Node {
        let mut node = self.nodes[id].data.clone();
        node.children = self.nodes[id]
            .children
            .iter()
            .map(|&id| self.export(id))
            .collect();
        node
    }
}

fn run_dom(program: &DomProgram, dom: &mut Node) -> Result<(), String> {
    if program.steps.len() > DOM_STEP_LIMIT {
        return Err("DOM step budget exceeded".into());
    }
    let mut size = 0usize;
    for step in &program.steps {
        size = size.saturating_add(step.size());
        if size > DOM_BYTE_LIMIT {
            return Err("DOM program byte budget exceeded".into());
        }
    }
    let mut count = 0;
    let mut bytes = 0;
    check_dom(dom, 0, &mut count, &mut bytes)?;
    let mut arena = DomArena {
        nodes: Vec::new(),
        handles: Vec::new(),
        bytes,
        work: DOM_WORK_LIMIT,
    };
    arena.import(dom.clone(), None);
    for step in &program.steps {
        arena.spend(1)?;
        match step {
            DomStep::Create { handle, name, text } => {
                let node = if *text {
                    Node::text_node(name)
                } else {
                    g6b_dom::validate_element_name(name)?;
                    Node::elem(name)
                };
                let id = arena.allocate(node)?;
                arena.bind(*handle, Some(id))?;
            }
            DomStep::Lookup { handle, target } => {
                let id = arena.lookup(target)?;
                arena.bind(*handle, id)?;
            }
            DomStep::Mutate { target, mutation } => {
                let id = arena.resolve(target)?;
                arena.mutate(id, mutation)?;
            }
            DomStep::Append { parent, child } => {
                let parent = arena.resolve(parent)?;
                let child = arena.handle(*child)?;
                arena.append(parent, child)?;
            }
            DomStep::Remove { parent, child } => {
                let parent = arena.resolve(parent)?;
                let child = arena.handle(*child)?;
                arena.remove(parent, child)?;
            }
        }
    }
    *dom = arena.export(0);
    Ok(())
}

/// Compile a tiny JS subset to [`Op`]s.
pub fn compile(src: &str) -> Result<Vec<Op>, String> {
    let tokens = tokenize(src)?;
    Parser {
        tokens,
        pos: 0,
        bindings: BTreeMap::new(),
        binding_bytes: 0,
        dom_program: DomProgram::default(),
        dom_bytes: 0,
        handles: 0,
    }
    .program()
}

/// Run AOT ops against a DOM tree.
pub fn run(ops: &[Op], dom: &mut Node) -> Result<(), String> {
    for op in ops {
        match op {
            Op::DomTransaction { program } => run_dom(program, dom)?,
            Op::SetInnerText { id, value } => {
                let n = dom
                    .get_element_by_id(id)
                    .ok_or_else(|| format!("no element id={id}"))?;
                n.set_inner_text(value);
            }
            Op::SetAttribute { id, name, value } => {
                element(dom, id)?.set_attribute(name, value)?;
            }
            Op::RemoveAttribute { id, name } => {
                g6b_dom::validate_attribute_name(name)?;
                element(dom, id)?.remove_attribute(name);
            }
            Op::SetVisible { id, on } => element(dom, id)?.set_visible(*on),
            Op::AppendChild { id, tag } => {
                g6b_dom::validate_element_name(tag)?;
                element(dom, id)?.append_child(Node::elem(tag));
            }
            Op::AppendText { id, value } => {
                element(dom, id)?.append_child(Node::text_node(value));
            }
            Op::RemoveChild { id, child_id } => remove_child(dom, id, child_id)?,
            Op::QuerySelector { selector, mutation } => {
                if let Mutation::RemoveChild { child_id } = mutation {
                    let child_path = find_id_path(dom, child_id)
                        .ok_or_else(|| format!("no element id={child_id}"))?;
                    let parent_path = find_selector_path(dom, selector)?
                        .ok_or_else(|| format!("no element selector={selector}"))?;
                    if child_path.len() != parent_path.len() + 1
                        || !child_path.starts_with(&parent_path)
                    {
                        return Err("removeChild target is not a direct child".into());
                    }
                    let index = *child_path.last().ok_or("cannot remove root")?;
                    node_at_path(dom, &parent_path).remove_child(index);
                } else {
                    let node = dom
                        .query_selector(selector)?
                        .ok_or_else(|| format!("no element selector={selector}"))?;
                    apply_mutation(node, mutation)?;
                }
            }
            Op::Log { .. } => {}
            Op::GetContext { id, kind } => {
                validate_context(kind)?;
                let n = dom
                    .get_element_by_id(id)
                    .ok_or_else(|| format!("no element id={id}"))?;
                n.set_inner_text(&format!("GL-ADAPTER {kind}"));
            }
            Op::Fetch { .. } | Op::RegisterEndpoint { .. } | Op::HolycEval { .. } => {}
        }
    }
    Ok(())
}

fn op_size(op: &Op) -> usize {
    match op {
        Op::DomTransaction { program } => program.steps.iter().map(DomStep::size).sum(),
        Op::SetInnerText { id, value } | Op::AppendText { id, value } => id.len() + value.len(),
        Op::Log { value } => value.len(),
        Op::GetContext { id, kind } => id.len() + kind.len(),
        Op::Fetch { method, url } => method.len() + url.len(),
        Op::RegisterEndpoint { method, path } => method.len() + path.len(),
        Op::HolycEval { line } => line.len(),
        Op::SetAttribute { id, name, value } => id.len() + name.len() + value.len(),
        Op::RemoveAttribute { id, name } => id.len() + name.len(),
        Op::SetVisible { id, .. } => id.len(),
        Op::AppendChild { id, tag } => id.len() + tag.len(),
        Op::RemoveChild { id, child_id } => id.len() + child_id.len(),
        Op::QuerySelector { selector, mutation } => {
            selector.len()
                + match mutation {
                    Mutation::SetInnerText { value } | Mutation::AppendText { value } => {
                        value.len()
                    }
                    Mutation::SetAttribute { name, value } => name.len() + value.len(),
                    Mutation::RemoveAttribute { name } => name.len(),
                    Mutation::SetVisible { .. } => 1,
                    Mutation::AppendChild { tag } => tag.len(),
                    Mutation::RemoveChild { child_id } => child_id.len(),
                }
        }
    }
}

fn element<'a>(dom: &'a mut Node, id: &str) -> Result<&'a mut Node, String> {
    dom.get_element_by_id(id)
        .ok_or_else(|| format!("no element id={id}"))
}

fn apply_mutation(node: &mut Node, mutation: &Mutation) -> Result<(), String> {
    match mutation {
        Mutation::SetInnerText { value } => node.set_inner_text(value),
        Mutation::SetAttribute { name, value } => {
            node.set_attribute(name, value)?;
        }
        Mutation::RemoveAttribute { name } => {
            g6b_dom::validate_attribute_name(name)?;
            node.remove_attribute(name);
        }
        Mutation::SetVisible { on } => node.set_visible(*on),
        Mutation::AppendChild { tag } => {
            g6b_dom::validate_element_name(tag)?;
            node.append_child(Node::elem(tag));
        }
        Mutation::AppendText { value } => {
            node.append_child(Node::text_node(value));
        }
        Mutation::RemoveChild { .. } => return Err("removeChild requires document lookup".into()),
    }
    Ok(())
}

fn find_path(node: &Node, predicate: &impl Fn(&Node) -> bool) -> Option<Vec<usize>> {
    if predicate(node) {
        return Some(Vec::new());
    }
    for (index, child) in node.children.iter().enumerate() {
        if let Some(mut path) = find_path(child, predicate) {
            path.insert(0, index);
            return Some(path);
        }
    }
    None
}

fn find_id_path(dom: &Node, id: &str) -> Option<Vec<usize>> {
    find_path(dom, &|node| node.id.as_deref() == Some(id))
}

fn find_selector_path(dom: &Node, selector: &str) -> Result<Option<Vec<usize>>, String> {
    g6b_dom::validate_selector(selector)?;
    for (index, child) in dom.children.iter().enumerate() {
        if let Some(mut path) = find_path(child, &|node| {
            node.matches_selector(selector).unwrap_or(false)
        }) {
            path.insert(0, index);
            return Ok(Some(path));
        }
    }
    Ok(None)
}

fn node_at_path<'a>(dom: &'a mut Node, path: &[usize]) -> &'a mut Node {
    let mut node = dom;
    for &index in path {
        node = &mut node.children[index];
    }
    node
}

fn remove_child(dom: &mut Node, id: &str, child_id: &str) -> Result<(), String> {
    let parent = find_id_path(dom, id).ok_or_else(|| format!("no element id={id}"))?;
    let child = find_id_path(dom, child_id).ok_or_else(|| format!("no element id={child_id}"))?;
    if child.len() != parent.len() + 1 || !child.starts_with(&parent) {
        return Err("removeChild target is not a direct child".into());
    }
    let index = *child.last().ok_or("cannot remove root")?;
    node_at_path(dom, &parent).remove_child(index);
    Ok(())
}

fn validate_context(kind: &str) -> Result<(), String> {
    if matches!(kind, "webgl" | "opengl") {
        Ok(())
    } else {
        Err(format!("unsupported context {kind}"))
    }
}

fn http_method(value: String) -> Result<String, String> {
    if value.is_empty()
        || !value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
    {
        return Err("invalid HTTP method".into());
    }
    let upper = value.to_ascii_uppercase();
    if matches!(upper.as_str(), "CONNECT" | "TRACE" | "TRACK") {
        return Err("forbidden HTTP method".into());
    }
    if matches!(
        upper.as_str(),
        "DELETE" | "GET" | "HEAD" | "OPTIONS" | "POST" | "PUT"
    ) {
        Ok(upper)
    } else {
        Ok(value)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum TokenKind {
    Ident(String),
    Text(String),
    Punct(char),
    End,
}

#[derive(Debug)]
struct Token {
    kind: TokenKind,
    offset: usize,
    line_before: bool,
}

fn line_end(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}')
}

fn js_space(c: char) -> bool {
    line_end(c)
        || matches!(
            c,
            '\t' | '\u{b}' | '\u{c}' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
                ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}'
        )
}

fn tokenize(source: &str) -> Result<Vec<Token>, String> {
    if source.len() > 1_048_576 {
        return Err("JS source limit exceeded".into());
    }
    let mut rest = source;
    let mut tokens = Vec::new();
    let mut newline = false;
    while let Some(c) = rest.chars().next() {
        if js_space(c) {
            newline |= line_end(c);
            rest = &rest[c.len_utf8()..];
            continue;
        }
        if let Some(tail) = rest.strip_prefix("//") {
            rest = &tail[tail.find(line_end).unwrap_or(tail.len())..];
            continue;
        }
        if let Some(tail) = rest.strip_prefix("/*") {
            let end = tail.find("*/").ok_or_else(|| {
                format!("unterminated comment at byte {}", source.len() - rest.len())
            })?;
            newline |= tail[..end].chars().any(line_end);
            rest = &tail[end + 2..];
            continue;
        }
        let offset = source.len() - rest.len();
        let kind = if matches!(c, '\'' | '"') {
            TokenKind::Text(string_literal(&mut rest).map_err(|e| format!("{e} at byte {offset}"))?)
        } else if c.is_ascii_alphabetic() || matches!(c, '_' | '$') {
            let end = rest
                .find(|c: char| !c.is_ascii_alphanumeric() && !matches!(c, '_' | '$'))
                .unwrap_or(rest.len());
            let value = rest[..end].to_string();
            rest = &rest[end..];
            TokenKind::Ident(value)
        } else if ".(){};,=+!:".contains(c) {
            rest = &rest[c.len_utf8()..];
            TokenKind::Punct(c)
        } else {
            return Err(format!("unsupported token {c:?} at byte {offset}"));
        };
        tokens.push(Token {
            kind,
            offset,
            line_before: newline,
        });
        newline = false;
        if tokens.len() > 65_536 {
            return Err("JS token limit exceeded".into());
        }
    }
    tokens.push(Token {
        kind: TokenKind::End,
        offset: source.len(),
        line_before: newline,
    });
    Ok(tokens)
}

fn hex_escape(rest: &mut &str, count: usize) -> Result<u32, String> {
    let digits = rest.get(..count).ok_or("incomplete hex escape")?;
    if !digits.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("invalid hex escape".into());
    }
    let value = u32::from_str_radix(digits, 16).map_err(|_| "invalid hex escape")?;
    *rest = &rest[count..];
    Ok(value)
}

fn string_literal(rest: &mut &str) -> Result<String, String> {
    let quote = rest.chars().next().ok_or("expected quote")?;
    *rest = &rest[1..];
    let mut out = String::new();
    while let Some(c) = rest.chars().next() {
        *rest = &rest[c.len_utf8()..];
        if c == quote {
            return Ok(out);
        }
        if line_end(c) {
            return Err("unescaped line terminator in string".into());
        }
        if c != '\\' {
            out.push(c);
            continue;
        }
        let escape = rest.chars().next().ok_or("unterminated escape")?;
        *rest = &rest[escape.len_utf8()..];
        match escape {
            '\'' | '"' | '\\' | '/' => out.push(escape),
            'b' => out.push('\u{8}'),
            'f' => out.push('\u{c}'),
            'n' => out.push('\n'),
            'r' => out.push('\r'),
            't' => out.push('\t'),
            'v' => out.push('\u{b}'),
            '0' if !rest.starts_with(|c: char| c.is_ascii_digit()) => out.push('\0'),
            '\r' => {
                if let Some(tail) = rest.strip_prefix('\n') {
                    *rest = tail;
                }
            }
            '\n' | '\u{2028}' | '\u{2029}' => {}
            'x' => out.push(char::from_u32(hex_escape(rest, 2)?).ok_or("invalid scalar")?),
            'u' => {
                let mut value = hex_escape(rest, 4)?;
                if (0xd800..=0xdbff).contains(&value) {
                    *rest = rest.strip_prefix("\\u").ok_or("unpaired high surrogate")?;
                    let low = hex_escape(rest, 4)?;
                    if !(0xdc00..=0xdfff).contains(&low) {
                        return Err("unpaired high surrogate".into());
                    }
                    value = 0x10000 + ((value - 0xd800) << 10) + low - 0xdc00;
                }
                out.push(char::from_u32(value).ok_or("unpaired surrogate")?);
            }
            _ => return Err("unsupported string escape".into()),
        }
    }
    Err("unterminated string".into())
}

#[derive(Clone)]
enum Value {
    Text(String),
    Bool(bool),
    Handle(usize),
}

impl Value {
    fn string(self) -> Result<String, String> {
        match self {
            Self::Text(s) => Ok(s),
            Self::Bool(b) => Ok(b.to_string()),
            Self::Handle(_) => Err("node coercion is outside the AOT subset".into()),
        }
    }

    fn size(&self) -> usize {
        match self {
            Self::Text(s) => s.len(),
            Self::Bool(_) => 1,
            Self::Handle(_) => 8,
        }
    }

    fn truthy(&self) -> Result<bool, String> {
        match self {
            Self::Text(s) => Ok(!s.is_empty()),
            Self::Bool(b) => Ok(*b),
            Self::Handle(_) => Err("node coercion is outside the AOT subset".into()),
        }
    }
}

struct Parser {
    tokens: Vec<Token>,
    pos: usize,
    bindings: BTreeMap<String, Value>,
    binding_bytes: usize,
    dom_program: DomProgram,
    dom_bytes: usize,
    handles: usize,
}

impl Parser {
    fn error(&self, message: &str) -> String {
        format!("{message} at byte {}", self.tokens[self.pos].offset)
    }

    fn peek(&self) -> &TokenKind {
        &self.tokens[self.pos].kind
    }

    fn punct(&mut self, c: char) -> bool {
        if self.peek() == &TokenKind::Punct(c) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn expect(&mut self, c: char) -> Result<(), String> {
        if self.punct(c) {
            Ok(())
        } else {
            Err(self.error(&format!("expected {c}")))
        }
    }

    fn ident(&mut self) -> Result<String, String> {
        if let TokenKind::Ident(value) = self.peek().clone() {
            self.pos += 1;
            Ok(value)
        } else {
            Err(self.error("expected identifier"))
        }
    }

    fn named(&mut self, name: &str) -> Result<(), String> {
        if self.ident()? == name {
            Ok(())
        } else {
            Err(self.error(&format!("expected {name}")))
        }
    }

    fn bind(&mut self, name: String, value: Value) -> Result<(), String> {
        let old = self
            .bindings
            .get(&name)
            .map(|value| name.len() + value.size())
            .unwrap_or(0);
        let bytes = self.binding_bytes - old + name.len() + value.size();
        if bytes > 4_194_304 {
            return Err(self.error("constant binding budget exceeded"));
        }
        self.binding_bytes = bytes;
        self.bindings.insert(name, value);
        Ok(())
    }

    fn push_step(&mut self, step: DomStep) -> Result<(), String> {
        self.dom_bytes += step.size();
        if self.dom_bytes > DOM_BYTE_LIMIT {
            return Err(self.error("DOM program byte budget exceeded"));
        }
        if self.dom_program.steps.len() >= DOM_STEP_LIMIT {
            return Err(self.error("DOM step budget exceeded"));
        }
        self.dom_program.steps.push(step);
        Ok(())
    }

    fn node_value(&mut self, depth: usize) -> Result<Value, String> {
        self.expect('.')?;
        let method = self.ident()?;
        self.expect('(')?;
        let value = match self.expression(depth + 1)? {
            Value::Text(value) => value,
            _ => return Err(self.error("node expression requires a string")),
        };
        self.expect(')')?;
        let handle = self.handles;
        if handle >= DOM_NODE_LIMIT {
            return Err(self.error("DOM handle budget exceeded"));
        }
        let step = match method.as_str() {
            "createElement" => {
                g6b_dom::validate_element_name(&value)?;
                DomStep::Create {
                    handle,
                    name: value,
                    text: false,
                }
            }
            "createTextNode" => DomStep::Create {
                handle,
                name: value,
                text: true,
            },
            "getElementById" => DomStep::Lookup {
                handle,
                target: Target::Id(value),
            },
            "querySelector" => {
                g6b_dom::validate_selector(&value)?;
                DomStep::Lookup {
                    handle,
                    target: Target::Selector(value),
                }
            }
            _ => return Err(self.error("unsupported node expression")),
        };
        self.handles += 1;
        self.push_step(step)?;
        Ok(Value::Handle(handle))
    }

    fn program(mut self) -> Result<Vec<Op>, String> {
        let mut ops = Vec::new();
        let mut output_bytes = 0;
        let mut host_effects = false;
        while self.peek() != &TokenKind::End {
            if self.punct(';') {
                continue;
            }
            let first = self.ident()?;
            if first == "var" {
                loop {
                    let name = self.ident()?;
                    if reserved(&name) {
                        return Err(self.error("reserved binding name"));
                    }
                    self.expect('=')?;
                    let value = self.expression(0)?;
                    self.bind(name, value)?;
                    if !self.punct(',') {
                        break;
                    }
                }
            } else if self.punct('=') {
                if !self.bindings.contains_key(&first) {
                    return Err(self.error("assignment requires a declared binding"));
                }
                let value = self.expression(0)?;
                self.bind(first, value)?;
            } else {
                let op = self.statement(&first)?;
                output_bytes += op_size(&op);
                if output_bytes > 4_194_304 {
                    return Err(self.error("AOT output budget exceeded"));
                }
                if let Op::DomTransaction { program } = op {
                    for step in program.steps {
                        self.push_step(step)?;
                    }
                } else {
                    if let Some(step) = dom_step(&op) {
                        self.push_step(step)?;
                    } else {
                        host_effects = true;
                    }
                    ops.push(op);
                }
            }
            if self.punct(';') || self.peek() == &TokenKind::End {
                continue;
            }
            if self.tokens[self.pos].line_before && matches!(self.peek(), TokenKind::Ident(_)) {
                continue;
            }
            return Err(self.error("expected statement separator"));
        }
        if self.handles != 0 {
            if host_effects {
                return Err(self.error("local DOM handles cannot be mixed with host effects"));
            }
            Ok(vec![Op::DomTransaction {
                program: self.dom_program,
            }])
        } else {
            Ok(ops)
        }
    }

    fn expression(&mut self, depth: usize) -> Result<Value, String> {
        let mut value = self.primary(depth)?;
        while self.punct('+') {
            let rhs = self.primary(depth)?;
            if !matches!(value, Value::Text(_)) && !matches!(rhs, Value::Text(_)) {
                return Err(self.error("numeric addition is outside the AOT subset"));
            }
            let mut text = value.string()?;
            let tail = rhs.string()?;
            if text.len().saturating_add(tail.len()) > 1_048_576 {
                return Err(self.error("constant string limit exceeded"));
            }
            text.push_str(&tail);
            value = Value::Text(text);
        }
        Ok(value)
    }

    fn primary(&mut self, depth: usize) -> Result<Value, String> {
        if depth >= 64 {
            return Err(self.error("expression nesting limit exceeded"));
        }
        if self.punct('!') {
            return Ok(Value::Bool(!self.primary(depth + 1)?.truthy()?));
        }
        if self.punct('(') {
            let value = self.expression(depth + 1)?;
            self.expect(')')?;
            return Ok(value);
        }
        match self.peek().clone() {
            TokenKind::Text(s) => {
                self.pos += 1;
                Ok(Value::Text(s))
            }
            TokenKind::Ident(name) => {
                self.pos += 1;
                match name.as_str() {
                    "true" => Ok(Value::Bool(true)),
                    "false" => Ok(Value::Bool(false)),
                    "document" => self.node_value(depth),
                    _ => self
                        .bindings
                        .get(&name)
                        .cloned()
                        .ok_or_else(|| self.error("unknown constant binding")),
                }
            }
            _ => Err(self.error("expected string/boolean expression")),
        }
    }

    fn text(&mut self) -> Result<String, String> {
        match self.expression(0)? {
            Value::Text(s) => Ok(s),
            _ => Err(self.error("expected string expression")),
        }
    }

    fn statement(&mut self, first: &str) -> Result<Op, String> {
        match first {
            "console" => {
                self.expect('.')?;
                self.named("log")?;
                self.expect('(')?;
                let value = self.expression(0)?.string()?;
                self.expect(')')?;
                Ok(Op::Log { value })
            }
            "fetch" => {
                self.expect('(')?;
                let url = self.text()?;
                let mut method = "GET".to_string();
                if self.punct(',') {
                    self.expect('{')?;
                    let mut seen = false;
                    if !self.punct('}') {
                        loop {
                            let key = match self.peek().clone() {
                                TokenKind::Text(key) | TokenKind::Ident(key) => {
                                    self.pos += 1;
                                    key
                                }
                                _ => return Err(self.error("expected fetch option name")),
                            };
                            if key != "method" || seen {
                                return Err(self.error("unsupported or duplicate fetch option"));
                            }
                            seen = true;
                            self.expect(':')?;
                            method = http_method(self.text()?)?;
                            if self.punct('}') {
                                break;
                            }
                            self.expect(',')?;
                            if self.punct('}') {
                                break;
                            }
                        }
                    }
                }
                self.expect(')')?;
                Ok(Op::Fetch { method, url })
            }
            "kernel" => {
                self.expect('.')?;
                let member = self.ident()?;
                self.expect('(')?;
                let value = self.text()?;
                let op = match member.as_str() {
                    "holyc" => Op::HolycEval { line: value },
                    "register" => {
                        let method = if self.punct(',') {
                            http_method(self.text()?)?
                        } else {
                            "GET".into()
                        };
                        Op::RegisterEndpoint {
                            method,
                            path: value,
                        }
                    }
                    _ => return Err(self.error("unsupported kernel method")),
                };
                self.expect(')')?;
                Ok(op)
            }
            "document" => self.dom_statement(),
            _ => match self.bindings.get(first) {
                Some(Value::Handle(handle)) => self.dom_member(Target::Handle(*handle)),
                _ => Err(self.error("unsupported statement")),
            },
        }
    }

    fn dom_statement(&mut self) -> Result<Op, String> {
        self.expect('.')?;
        let lookup = self.ident()?;
        if !matches!(lookup.as_str(), "getElementById" | "querySelector") {
            return Err(self.error("unsupported document lookup"));
        }
        self.expect('(')?;
        let target = self.text()?;
        self.expect(')')?;
        let target = if lookup == "querySelector" {
            g6b_dom::validate_selector(&target)?;
            Target::Selector(target)
        } else {
            Target::Id(target)
        };
        self.dom_member(target)
    }

    fn dom_member(&mut self, target: Target) -> Result<Op, String> {
        self.expect('.')?;
        let member = self.ident()?;
        if member == "getContext" {
            let Target::Id(id) = target else {
                return Err(self.error("getContext requires id lookup"));
            };
            self.expect('(')?;
            let kind = self.text()?;
            validate_context(&kind)?;
            self.expect(')')?;
            return Ok(Op::GetContext { id, kind });
        }
        let mutation = match member.as_str() {
            "innerText" | "textContent" => {
                self.expect('=')?;
                Mutation::SetInnerText {
                    value: self.expression(0)?.string()?,
                }
            }
            "hidden" => {
                self.expect('=')?;
                let on = match self.expression(0)? {
                    Value::Bool(hidden) => !hidden,
                    _ => return Err(self.error("hidden requires boolean expression")),
                };
                Mutation::SetVisible { on }
            }
            "setAttribute" => {
                self.expect('(')?;
                let name = self.text()?;
                g6b_dom::validate_attribute_name(&name)?;
                self.expect(',')?;
                let value = self.expression(0)?.string()?;
                self.expect(')')?;
                Mutation::SetAttribute { name, value }
            }
            "removeAttribute" => {
                self.expect('(')?;
                let name = self.text()?;
                g6b_dom::validate_attribute_name(&name)?;
                self.expect(')')?;
                Mutation::RemoveAttribute { name }
            }
            "appendChild" | "removeChild" => {
                self.expect('(')?;
                let inline = !matches!(target, Target::Handle(_))
                    && self.peek() == &TokenKind::Ident("document".into())
                    && matches!(self.tokens.get(self.pos + 2).map(|token| &token.kind),
                        Some(TokenKind::Ident(factory)) if
                        (member == "appendChild" && matches!(factory.as_str(), "createElement" | "createTextNode"))
                        || (member == "removeChild" && factory == "getElementById"));
                if !inline {
                    let child = match self.expression(0)? {
                        Value::Handle(handle) => handle,
                        _ => return Err(self.error("child operation requires a node handle")),
                    };
                    self.expect(')')?;
                    let step = if member == "appendChild" {
                        DomStep::Append {
                            parent: target,
                            child,
                        }
                    } else {
                        DomStep::Remove {
                            parent: target,
                            child,
                        }
                    };
                    return Ok(Op::DomTransaction {
                        program: DomProgram { steps: vec![step] },
                    });
                }
                self.named("document")?;
                self.expect('.')?;
                let factory = self.ident()?;
                self.expect('(')?;
                let value = self.text()?;
                self.expect(')')?;
                self.expect(')')?;
                match factory.as_str() {
                    "createElement" => {
                        g6b_dom::validate_element_name(&value)?;
                        Mutation::AppendChild { tag: value }
                    }
                    "createTextNode" => Mutation::AppendText { value },
                    "getElementById" => Mutation::RemoveChild { child_id: value },
                    _ => return Err(self.error("unsupported child expression")),
                }
            }
            _ => return Err(self.error("unsupported DOM member")),
        };
        let id = match target {
            Target::Selector(selector) => return Ok(Op::QuerySelector { selector, mutation }),
            Target::Handle(_) => {
                return Ok(Op::DomTransaction {
                    program: DomProgram {
                        steps: vec![DomStep::Mutate { target, mutation }],
                    },
                })
            }
            Target::Id(id) => id,
        };
        Ok(match mutation {
            Mutation::SetInnerText { value } => Op::SetInnerText { id, value },
            Mutation::SetAttribute { name, value } => Op::SetAttribute { id, name, value },
            Mutation::RemoveAttribute { name } => Op::RemoveAttribute { id, name },
            Mutation::SetVisible { on } => Op::SetVisible { id, on },
            Mutation::AppendChild { tag } => Op::AppendChild { id, tag },
            Mutation::AppendText { value } => Op::AppendText { id, value },
            Mutation::RemoveChild { child_id } => Op::RemoveChild { id, child_id },
        })
    }
}

fn reserved(name: &str) -> bool {
    matches!(
        name,
        "document"
            | "console"
            | "kernel"
            | "fetch"
            | "true"
            | "false"
            | "null"
            | "undefined"
            | "NaN"
            | "Infinity"
            | "break"
            | "case"
            | "catch"
            | "continue"
            | "debugger"
            | "default"
            | "delete"
            | "do"
            | "else"
            | "finally"
            | "for"
            | "function"
            | "if"
            | "in"
            | "instanceof"
            | "new"
            | "return"
            | "switch"
            | "this"
            | "throw"
            | "try"
            | "typeof"
            | "var"
            | "void"
            | "while"
            | "with"
            | "class"
            | "const"
            | "enum"
            | "export"
            | "extends"
            | "import"
            | "super"
            | "implements"
            | "interface"
            | "let"
            | "package"
            | "private"
            | "protected"
            | "public"
            | "static"
            | "yield"
            | "eval"
            | "arguments"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn handle_dom() -> Node {
        let mut dom = Node::elem("document");
        for id in ["parent", "other"] {
            let mut node = Node::elem("div");
            node.set_attribute("id", id).unwrap();
            dom.append_child(node);
        }
        dom.clear_dirty();
        dom
    }

    #[test]
    fn local_nodes_build_a_detached_subtree_in_one_operation() {
        let mut dom = handle_dom();
        let ops = compile(
            r#"
            var tag = 'SPAN', node = document.createElement(tag), alias = node;
            node.setAttribute('id', 'created');
            alias.setAttribute('class', 'row active');
            node.textContent = 'hello ' + true;
            var tail = document.createTextNode('!');
            node.appendChild(tail);
            document.getElementById('parent').appendChild(node);
            alias.setAttribute('data-state', 'mounted');
        "#,
        )
        .unwrap();
        assert_eq!(ops.len(), 1);
        run(&ops, &mut dom).unwrap();
        let node = dom.get_element_by_id("created").unwrap();
        assert_eq!(node.name, "span");
        assert_eq!(node.inner_text(), "hello true!");
        assert_eq!(node.get_attribute("data-state"), Some("mounted"));
        assert!(node.matches_selector("span.row.active").unwrap());
        assert!(!dom.dirty);
        assert!(dom.children[0].dirty);
        assert!(!dom.children[1].dirty);
        assert!(compile("node.textContent = 'leaked';").is_err());
    }

    #[test]
    fn local_handles_survive_moves_id_changes_and_text_replacement() {
        let mut dom = handle_dom();
        let ops = compile(
            r#"
            var parent = document.getElementById('parent');
            var other = document.querySelector('#other');
            var child = document.createElement('p'), alias = child;
            child.setAttribute('id', 'before');
            parent.appendChild(child);
            var captured = document.getElementById('before');
            captured.setAttribute('id', 'after');
            other.appendChild(child);
            alias.textContent = 'kept';
            other.removeChild(captured);
            captured.textContent = 'detached';
            parent.appendChild(alias);
            parent.textContent = 'replacement';
            child.textContent = 'retained handle';
            other.appendChild(child);
        "#,
        )
        .unwrap();
        run(&ops, &mut dom).unwrap();
        assert_eq!(dom.children[0].inner_text(), "replacement");
        assert_eq!(dom.children[1].inner_text(), "retained handle");
        assert_eq!(dom.children[1].children.len(), 1);
        assert_eq!(dom.children[1].children[0].id.as_deref(), Some("after"));
    }

    #[test]
    fn handle_lookup_is_a_snapshot_and_detached_nodes_are_not_queryable() {
        let mut dom = handle_dom();
        let ops = compile(
            r#"
            var node = document.createElement('p');
            node.setAttribute('id', 'late');
            var missing = document.getElementById('late');
            document.getElementById('parent').appendChild(node);
            missing.textContent = 'must not re-resolve';
        "#,
        )
        .unwrap();
        let before = format!("{dom:?}");
        assert!(run(&ops, &mut dom).unwrap_err().contains("null"));
        assert_eq!(format!("{dom:?}"), before);
        let ops = compile("var missing = document.querySelector('.absent');").unwrap();
        run(&ops, &mut dom).unwrap();
        assert_eq!(format!("{dom:?}"), before);
    }

    #[test]
    fn handle_transaction_errors_preserve_tree_and_dirty_flags() {
        for tail in [
            "node.appendChild(parent);",
            "node.appendChild(node);",
            "other.removeChild(node);",
            "var text = document.createTextNode('x'); text.appendChild(node);",
            "var text = document.createTextNode('x'); text.setAttribute('id', 'bad');",
            "var text = document.createTextNode('x'); text.removeAttribute('id');",
            "var text = document.createTextNode('x'); text.hidden=true;",
            "document.getElementById('absent').textContent = 'bad';",
        ] {
            let mut dom = handle_dom();
            let before = format!("{dom:?}");
            let source = format!(
                r#"
                var parent = document.getElementById('parent');
                var other = document.getElementById('other');
                var node = document.createElement('span');
                parent.appendChild(node);
                parent.setAttribute('class', 'changed');
                {tail}
            "#
            );
            let ops = compile(&source).unwrap();
            assert!(run(&ops, &mut dom).is_err(), "{tail}");
            assert_eq!(format!("{dom:?}"), before, "{tail}");
        }
    }

    #[test]
    fn handle_scripts_refuse_host_effects_and_dynamic_coercions() {
        for source in [
            "var n=document.createElement('p'); console.log('x');",
            "fetch('/bios/menu'); var n=document.createElement('p');",
            "var n=document.createElement('p'); kernel.holyc('x');",
            "var n=document.createElement('p'); document.getElementById('x').getContext('webgl');",
            "var n=document.createElement('p'); n.textContent=n;",
            "var n=document.createElement('p'); var value='node=' + n;",
            "var n=document.createElement('p'); var value=!n;",
            "var n=document.createElement('p'); n.appendChild('not a node');",
            "var n=document.createElement('p'); n.innerHTML='unsafe';",
            "var n=document.createElement('bad name');",
            "var n=document.createElement('p'); n.setAttribute('bad name', 'x');",
            "var n=document.createElement('p'); n.setAttribute('id', 'x') trailing;",
        ] {
            assert!(compile(source).is_err(), "{source}");
        }
    }

    #[test]
    fn handle_transactions_enforce_node_depth_and_byte_budgets() {
        let mut boundary = handle_dom();
        let source = format!(
            "var p=document.getElementById('parent');{}",
            "var n=document.createElement('p'); p.appendChild(n); p=n;".repeat(63)
        );
        run(&compile(&source).unwrap(), &mut boundary).unwrap();
        let source = "var n=document.getElementById('parent');".repeat(4096);
        run(&compile(&source).unwrap(), &mut boundary).unwrap();
        let mut dom = handle_dom();
        let before = format!("{dom:?}");
        let mut source = "var p=document.getElementById('parent');".to_string();
        for _ in 0..65 {
            source.push_str("var n=document.createElement('p'); p.appendChild(n); p=n;");
        }
        let ops = compile(&source).unwrap();
        assert!(run(&ops, &mut dom).unwrap_err().contains("depth"));
        assert_eq!(format!("{dom:?}"), before);
        let source = "var n=document.createElement('p');".repeat(4097);
        assert!(compile(&source).unwrap_err().contains("handle"));
        let ops = compile("var n=document.createElement('p');").unwrap();
        for _ in 0..4096 {
            dom.append_child(Node::elem("p"));
        }
        dom.clear_dirty();
        let before = format!("{dom:?}");
        assert!(run(&ops, &mut dom).unwrap_err().contains("node"));
        assert_eq!(format!("{dom:?}"), before);
        let mut dom = handle_dom();
        dom.children[0].text = "x".repeat(4_194_304);
        let before = format!("{dom:?}");
        assert!(run(&ops, &mut dom).unwrap_err().contains("byte"));
        assert_eq!(format!("{dom:?}"), before);
    }

    #[test]
    fn local_text_writes_preserve_identity_without_dirtying_noops() {
        let mut dom = handle_dom();
        dom.children[0].set_inner_text("same");
        dom.clear_dirty();
        let ops = compile(
            r#"
            var p=document.getElementById('parent');
            p.textContent='same';
            p.setAttribute('id', 'parent');
            p.removeAttribute('missing');
            p.hidden=false;
        "#,
        )
        .unwrap();
        run(&ops, &mut dom).unwrap();
        assert!(!dom.children[0].dirty);
        assert!(!dom.children[0].children[0].dirty);
        assert!(!dom.dirty);
        let ops = compile(
            r#"
            var p=document.getElementById('parent');
            var t=document.createTextNode('same');
            p.textContent='';
            p.appendChild(t);
            p.textContent='same';
            t.textContent='detached';
            p.appendChild(t);
        "#,
        )
        .unwrap();
        run(&ops, &mut dom).unwrap();
        assert_eq!(dom.children[0].inner_text(), "samedetached");
        assert_eq!(dom.children[0].children.len(), 2);
    }

    #[test]
    fn append_moves_existing_children_and_rebinding_keeps_aliases() {
        let mut dom = handle_dom();
        let ops = compile(
            r#"
            var p=document.getElementById('parent');
            var a=document.createElement('span'), old=a;
            a.setAttribute('id', 'duplicate');
            p.appendChild(a);
            var b=document.createElement('span');
            b.setAttribute('id', 'duplicate');
            p.appendChild(b);
            var first=document.getElementById('duplicate');
            p.appendChild(a);
            first.textContent='first identity';
            a=document.createElement('i');
            a.textContent='new binding';
            p.appendChild(a);
            old.setAttribute('data-old', 'yes');
        "#,
        )
        .unwrap();
        for op in ops {
            run(&[op], &mut dom).unwrap();
        }
        let children = &dom.children[0].children;
        assert_eq!(children.len(), 3);
        assert_eq!(children[0].inner_text(), "");
        assert_eq!(children[1].inner_text(), "first identity");
        assert_eq!(children[1].get_attribute("data-old"), Some("yes"));
        assert_eq!(children[2].inner_text(), "new binding");
    }

    #[test]
    fn transaction_rollback_does_not_undo_preceding_operations() {
        let mut dom = handle_dom();
        let mut ops = compile("document.getElementById('other').textContent='earlier';").unwrap();
        ops.extend(
            compile(
                r#"
            var p=document.getElementById('parent');
            p.textContent='rolled back';
            p.appendChild(p);
        "#,
            )
            .unwrap(),
        );
        assert!(run(&ops, &mut dom).is_err());
        assert_eq!(dom.children[1].inner_text(), "earlier");
        assert!(dom.children[0].children.is_empty());
        assert!(!dom.children[0].dirty);
    }

    #[test]
    fn handle_growth_and_traversal_exhaustion_are_atomic() {
        let mut boundary = handle_dom();
        let source = format!(
            "var p=document.getElementById('parent');{}",
            "p.appendChild(document.createTextNode('x'));".repeat(4093)
        );
        run(&compile(&source).unwrap(), &mut boundary).unwrap();
        assert_eq!(boundary.children[0].children.len(), 4093);
        let mut dom = handle_dom();
        let before = format!("{dom:?}");
        let ops = compile(&format!(
            "var p=document.getElementById('parent');{}",
            "p.appendChild(document.createTextNode('x'));".repeat(4095)
        ))
        .unwrap();
        assert!(run(&ops, &mut dom).unwrap_err().contains("node"));
        assert_eq!(format!("{dom:?}"), before);
        let mut large = "var x='1234567890123456';".to_string();
        large.push_str(&"x=x+x;".repeat(16));
        large.push_str("var p=document.getElementById('parent'); p.setAttribute('data-x', x); p.textContent=x;");
        let ops = compile(&large).unwrap();
        dom.children[1].text = "x".repeat(2_097_152);
        let before = format!("{dom:?}");
        assert!(run(&ops, &mut dom).unwrap_err().contains("byte"));
        assert_eq!(format!("{dom:?}"), before);
        let mut dom = handle_dom();
        for _ in 0..512 {
            dom.children[0].append_child(Node::elem("span"));
        }
        dom.clear_dirty();
        let before = format!("{dom:?}");
        let source = "var missing=document.querySelector('.absent');".repeat(1024);
        let ops = compile(&source).unwrap();
        assert!(run(&ops, &mut dom).unwrap_err().contains("work"));
        assert_eq!(format!("{dom:?}"), before);
    }

    #[test]
    fn handle_compilation_bounds_nested_factories_and_expanded_steps() {
        let nested = format!(
            "var n={} 'p' {};",
            "document.createElement(".repeat(65),
            ")".repeat(65)
        );
        assert!(compile(&nested).unwrap_err().contains("nesting"));
        let source = format!(
            "var n=document.createElement('p');{}",
            "n.hidden=true;".repeat(11000)
        );
        assert!(compile(&source).unwrap_err().contains("token"));
        let mut source = "var x='1234567890123456';".to_string();
        source.push_str(&"x=x+x;".repeat(16));
        source.push_str("var n=document.createElement('p'); n.textContent=x; n.textContent=x; n.textContent=x; n.textContent=x;");
        assert!(compile(&source).unwrap_err().contains("output budget"));
    }

    #[test]
    fn strings_comments_escapes_and_boundaries() {
        let ops = compile(r#"/* lead */ console /* gap */ . log ("https://host/a/*b*/;é\u00e9\uD834\uDD1E"); // tail
            console.log('quote\' slash\\\n');"#).unwrap();
        assert_eq!(
            ops[0],
            Op::Log {
                value: "https://host/a/*b*/;éé\u{1d11e}".into()
            }
        );
        assert_eq!(
            ops[1],
            Op::Log {
                value: "quote' slash\\\n".into()
            }
        );
        for source in [
            "console.log('x'",
            "fetch('/bios/x'",
            "kernel.register('/x',)",
            "/* open",
            "con/*x*/sole.log('x');",
            "console.log('x')console.log('y')",
            "console.log('x\ny')",
            r#"console.log('\uD800')"#,
            r#"console.log('\xQ0')"#,
            "document.getElementById('x').innerTextExtra='x';",
            "console.log('x');Ω",
            "document.getElementById('x').innerHTML='<b>x</b>';",
        ] {
            assert!(compile(source).is_err(), "{source}");
        }
    }

    #[test]
    fn compile_local_bindings_and_strict_fetch_options() {
        let ops = compile(r#"var base = "/bios/", name = "files"; name = name + "/fat32"; fetch(base + name, {method: "post"}); console.log((base + name));"#).unwrap();
        assert_eq!(
            ops[0],
            Op::Fetch {
                method: "POST".into(),
                url: "/bios/files/fat32".into()
            }
        );
        assert_eq!(
            ops[1],
            Op::Log {
                value: "/bios/files/fat32".into()
            }
        );
        assert!(compile("console.log(base);").is_err());
        for source in [
            "fetch('/x', {body:'lost'})",
            "fetch('/x', {method:'GET', method:'POST'})",
            "fetch('/x', {method:'CONNECT'})",
            "fetch('/x', {method:'bad method'})",
            "fetch('/x', 'POST')",
            "var fetch = 'bad';",
            "var x = 'a'; x += 'b';",
            "var x = missing;",
        ] {
            assert!(compile(source).is_err(), "{source}");
        }
    }

    #[test]
    fn dom_ops_preserve_hidden_children_and_siblings() {
        let mut dom = Node::elem("document");
        let mut target = Node::elem("div");
        target.set_attribute("id", "target").unwrap();
        target.set_inner_text("saved");
        dom.append_child(target);
        dom.append_child(Node::elem("aside"));
        dom.clear_dirty();
        let ops = compile(r#"var off = true; document.getElementById('target').hidden = off; document.querySelector('#target').setAttribute('class', 'active'); document.querySelector('div.active').removeAttribute('missing');"#).unwrap();
        for op in ops {
            run(&[op], &mut dom).unwrap();
        }
        let target = dom.get_element_by_id("target").unwrap();
        assert!(target.hidden);
        assert_eq!(target.inner_text(), "saved");
        run(
            &compile("document.getElementById('target').hidden = false;").unwrap(),
            &mut dom,
        )
        .unwrap();
        assert!(!dom.get_element_by_id("target").unwrap().hidden);
        assert!(!dom.dirty);
        assert!(!dom.children[1].dirty);
    }

    #[test]
    fn create_append_remove_and_missing_targets() {
        let mut dom = Node::elem("document");
        let mut parent = Node::elem("div");
        parent.set_attribute("id", "parent").unwrap();
        dom.append_child(parent);
        let ops = compile(r#"document.getElementById('parent').appendChild(document.createElement('span')); document.querySelector('span').setAttribute('id', 'child'); document.getElementById('child').textContent = 'created';"#).unwrap();
        run(&ops, &mut dom).unwrap();
        assert_eq!(
            dom.get_element_by_id("child").unwrap().inner_text(),
            "created"
        );
        let ops = compile(
            "document.getElementById('parent').removeChild(document.getElementById('child'));",
        )
        .unwrap();
        run(&ops, &mut dom).unwrap();
        assert!(dom.get_element_by_id("child").is_none());
        assert!(run(&ops, &mut dom).is_err());
        assert!(compile("document.querySelector('p > span').hidden = true;").is_err());
    }

    #[test]
    fn separators_literal_coercion_and_atomic_compile_failure() {
        let ops = compile(
            "var ready = !false\r\nconsole.log('ready=' + ready)\u{2028}console.log(!!'x')",
        )
        .unwrap();
        assert_eq!(
            ops,
            vec![
                Op::Log {
                    value: "ready=true".into()
                },
                Op::Log {
                    value: "true".into()
                }
            ]
        );
        assert_eq!(
            compile("console.log('a\\\r\nb');").unwrap(),
            vec![Op::Log { value: "ab".into() }]
        );
        for source in [
            "console.log('a'); fetch('/x', {method:'GET'",
            "document.getElementById('x').getContext('webgl'",
            "document.getElementById('x').getContext('2d')",
            "console.log('a')/* no newline */console.log('b')",
            "console.log('a')\n('b')",
            "console.log('a')\n.log('b')",
            "var a='x'; console.log(a + true + false); a = new Thing();",
            "var a = true + false;",
            "var a = document.getElementById('x').textContent;",
            "var a = 'x'; a = 'y'; console.log(a); @",
        ] {
            assert!(compile(source).is_err(), "{source}");
        }
        assert_eq!(http_method("patch".into()).unwrap(), "patch");
        assert_eq!(http_method("put".into()).unwrap(), "PUT");
    }

    #[test]
    fn resource_limits_fail_closed() {
        let nested = format!("console.log({}'x'{});", "(".repeat(65), ")".repeat(65));
        assert!(compile(&nested).is_err());
        let mut source = "var x='1234567890123456';".to_string();
        for _ in 0..16 {
            source.push_str("x=x+x;");
        }
        source.push_str(
            "console.log(x);console.log(x);console.log(x);console.log(x);console.log(x);",
        );
        assert!(compile(&source).unwrap_err().contains("output budget"));
        let mut source = "var x='1234567890123456';".to_string();
        for _ in 0..16 {
            source.push_str("x=x+x;");
        }
        source.push_str("var a=x,b=x,c=x,d=x;");
        assert!(compile(&source).unwrap_err().contains("binding budget"));
    }

    #[test]
    fn remove_child_uses_document_identity_and_is_local() {
        let mut dom = Node::elem("document");
        let mut first = Node::elem("p");
        first.set_attribute("id", "duplicate").unwrap();
        dom.append_child(first.clone());
        let mut parent = Node::elem("div");
        parent.set_attribute("id", "parent").unwrap();
        parent.append_child(first);
        dom.append_child(parent);
        dom.clear_dirty();
        let ops = compile(
            "document.querySelector('#parent').removeChild(document.getElementById('duplicate'));",
        )
        .unwrap();
        assert!(run(&ops, &mut dom).is_err());
        assert!(!dom.dirty);
        assert!(!dom.children[1].dirty);
        assert_eq!(dom.children[1].children.len(), 1);
        run(
            &compile(
                "document.getElementById('parent').appendChild(document.createTextNode('tail'));",
            )
            .unwrap(),
            &mut dom,
        )
        .unwrap();
        assert_eq!(dom.children[1].inner_text(), "tail");
        assert!(!dom.dirty);
        assert!(dom.children[1].dirty);
    }

    #[test]
    fn short_unicode_token_streams_never_panic() {
        let alphabet = [
            "é", "'", "\"", "\\", "/", "*", ";", "(", ")", "\n", "a", "\u{2028}",
        ];
        for a in alphabet {
            for b in alphabet {
                for c in alphabet {
                    let _ = compile(&format!("{a}{b}{c}"));
                }
            }
        }
    }

    #[test]
    fn sets_status() {
        let mut dom = Node::elem("body");
        let mut st = Node::elem("p");
        st.id = Some("status".into());
        st.set_inner_text("boot");
        dom.children.push(st);
        let ops = compile(r#"document.getElementById("status").innerText = "UI-BOOT";"#).unwrap();
        run(&ops, &mut dom).unwrap();
        assert_eq!(
            dom.get_element_by_id("status").unwrap().inner_text(),
            "UI-BOOT"
        );
        assert_eq!(g6b_webidl::status("Document"), g6b_webidl::Status::Live);
        let f = compile(r#"fetch("/bios/clocks");"#).unwrap();
        assert!(matches!(&f[0], Op::Fetch { url, .. } if url == "/bios/clocks"));
        let h = compile(r#"kernel.holyc("UsbLs(\"fat32\")");"#).unwrap();
        assert!(matches!(&h[0], Op::HolycEval { line } if line == "UsbLs(\"fat32\")"));
    }
}
