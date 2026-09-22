// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Minimal HTML5 DOM event model: Event, EventTarget, capture/bubble propagation.
//!
//! The host (g6b-js, libwasm, or the BIOS input loop) owns the actual callback
//! closures and is responsible for mapping `listener_id` to an invocation. This
//! keeps `g6b-dom` generic and lets `Node` remain `Clone`.

#![allow(missing_docs)]

use crate::Node;

/// An event as it travels through the DOM tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    pub event_type: String,
    /// `id` of the target node, if it has one.
    pub target: Option<String>,
    /// `id` of the node whose listeners are currently running.
    pub current_target: Option<String>,
    pub bubbles: bool,
    pub cancelable: bool,
    pub default_prevented: bool,
    pub propagation_stopped: bool,
    pub immediate_stopped: bool,
    pub composed: bool,
    /// DOM `eventPhase`: 0 none, 1 capturing, 2 at-target, 3 bubbling.
    pub event_phase: u8,
    /// Set while a `passive` listener runs; `prevent_default` is then a no-op.
    pub in_passive_listener: bool,
    /// Extra payload (key, mouse coordinates, etc.) as a JSON-ish string.
    pub detail: String,
    /// Pointer client coordinates (CSS pixels), 0 for non-pointer events.
    pub client_x: i32,
    pub client_y: i32,
}

/// Initializer for `Event`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventInit {
    pub bubbles: bool,
    pub cancelable: bool,
    pub composed: bool,
    pub detail: String,
}

impl Default for EventInit {
    fn default() -> Self {
        Self {
            bubbles: true,
            cancelable: true,
            composed: true,
            detail: String::new(),
        }
    }
}

impl Event {
    pub const NONE: u8 = 0;
    pub const CAPTURING_PHASE: u8 = 1;
    pub const AT_TARGET: u8 = 2;
    pub const BUBBLING_PHASE: u8 = 3;

    pub fn new(event_type: &str, init: EventInit) -> Self {
        Self {
            event_type: event_type.to_ascii_lowercase(),
            target: None,
            current_target: None,
            bubbles: init.bubbles,
            cancelable: init.cancelable,
            default_prevented: false,
            propagation_stopped: false,
            immediate_stopped: false,
            composed: init.composed,
            event_phase: Self::NONE,
            in_passive_listener: false,
            detail: init.detail,
            client_x: 0,
            client_y: 0,
        }
    }

    pub fn prevent_default(&mut self) {
        if self.cancelable && !self.in_passive_listener {
            self.default_prevented = true;
        }
    }

    pub fn stop_propagation(&mut self) {
        self.propagation_stopped = true;
    }

    pub fn stop_immediate_propagation(&mut self) {
        self.immediate_stopped = true;
        self.propagation_stopped = true;
    }
}

/// A listener registered on a node.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Listener {
    pub id: u64,
    pub event_type: String,
    pub capture: bool,
    pub once: bool,
    pub passive: bool,
}

/// Host side of listener invocation. The DOM does not own closures.
pub trait EventHost {
    fn invoke(&mut self, listener_id: u64, event: &mut Event);
    /// Same as [`invoke`], with the tree so a listener may mutate it.
    /// Default forwards to [`invoke`].
    fn invoke_in_tree(&mut self, listener_id: u64, event: &mut Event, _root: &mut Node) {
        self.invoke(listener_id, event);
    }
}

impl Node {
    pub fn add_event_listener(&mut self, event_type: &str, capture: bool, id: u64) {
        self.add_event_listener_flags(event_type, capture, false, false, id);
    }

    pub fn add_event_listener_flags(
        &mut self,
        event_type: &str,
        capture: bool,
        once: bool,
        passive: bool,
        id: u64,
    ) {
        self.event_listeners.push(Listener {
            id,
            event_type: event_type.to_ascii_lowercase(),
            capture,
            once,
            passive,
        });
    }

    pub fn remove_event_listener(&mut self, id: u64) {
        self.event_listeners.retain(|l| l.id != id);
    }

    /// Dispatch `event` at the node described by `target_path`, which is a
    /// sequence of child indices from `root` **at dispatch start**. The path
    /// is snapshotted as node stamps so a listener that removes/reorders
    /// children cannot retarget later phases onto a sibling. A stamp that
    /// disappears is skipped. `currentTarget`/`eventPhase` are cleared on
    /// the way out (they are transient). Returns `true` if the default
    /// action may run (`defaultPrevented` is false).
    pub fn dispatch_event(
        root: &mut Node,
        target_path: &[usize],
        event: &mut Event,
        host: &mut dyn EventHost,
    ) -> bool {
        let t = event.event_type.clone();
        let stamps = snapshot_stamps(root, target_path);
        let target_i = stamps.len().saturating_sub(1);

        // Capture: root → parent of target (exclude the target).
        event.event_phase = Event::CAPTURING_PHASE;
        for &stamp in stamps.iter().take(target_i) {
            if event.propagation_stopped {
                break;
            }
            fire_listeners(root, stamp, &t, true, event, host);
        }

        // At-target: capture then non-capture listeners, even when
        // `bubbles=false`. Skipping this was the previous oracle defect.
        if !event.propagation_stopped {
            if let Some(&stamp) = stamps.last() {
                event.event_phase = Event::AT_TARGET;
                fire_listeners(root, stamp, &t, true, event, host);
                fire_listeners(root, stamp, &t, false, event, host);
            }
        }

        // Bubble: parent of target → root (exclude the target).
        if event.bubbles && !event.propagation_stopped {
            event.event_phase = Event::BUBBLING_PHASE;
            for &stamp in stamps.iter().take(target_i).rev() {
                if event.propagation_stopped {
                    break;
                }
                fire_listeners(root, stamp, &t, false, event, host);
            }
        }
        event.event_phase = Event::NONE;
        event.current_target = None;

        !event.default_prevented
    }
}

fn snapshot_stamps(root: &Node, path: &[usize]) -> Vec<u64> {
    let mut out = vec![root.stamp];
    let mut cur = root;
    for &i in path {
        if i >= cur.children.len() {
            break;
        }
        cur = &cur.children[i];
        out.push(cur.stamp);
    }
    out
}

fn find_stamp(node: &mut Node, stamp: u64) -> Option<&mut Node> {
    if node.stamp == stamp {
        return Some(node);
    }
    for child in &mut node.children {
        if let Some(found) = find_stamp(child, stamp) {
            return Some(found);
        }
    }
    None
}

fn fire_listeners(
    root: &mut Node,
    stamp: u64,
    event_type: &str,
    capture: bool,
    event: &mut Event,
    host: &mut dyn EventHost,
) {
    let Some(node) = find_stamp(root, stamp) else {
        return;
    };
    // Snapshot the list so a listener removing itself does not perturb the
    // order or skip entries.
    let to_fire: Vec<(u64, bool, bool)> = node
        .event_listeners
        .iter()
        .filter(|l| l.event_type == event_type && l.capture == capture)
        .map(|l| (l.id, l.once, l.passive))
        .collect();
    let mut fired_once: Vec<u64> = Vec::new();
    for (id, once, passive) in to_fire {
        if event.immediate_stopped {
            break;
        }
        let Some(node) = find_stamp(root, stamp) else {
            break;
        };
        event.current_target = node.id.clone();
        event.in_passive_listener = passive;
        host.invoke_in_tree(id, event, root);
        event.in_passive_listener = false;
        if once {
            fired_once.push(id);
        }
    }
    if !fired_once.is_empty() {
        if let Some(node) = find_stamp(root, stamp) {
            node.event_listeners.retain(|l| !fired_once.contains(&l.id));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestHost {
        pub log: Vec<(u64, String, String)>,
        pub stop_on: Option<u64>,
        pub prevent_on: Option<u64>,
    }

    impl TestHost {
        fn new() -> Self {
            Self {
                log: Vec::new(),
                stop_on: None,
                prevent_on: None,
            }
        }
    }

    impl EventHost for TestHost {
        fn invoke(&mut self, listener_id: u64, event: &mut Event) {
            self.log.push((
                listener_id,
                event.current_target.clone().unwrap_or_default(),
                event.event_type.clone(),
            ));
            if self.stop_on == Some(listener_id) {
                event.stop_propagation();
            }
            if self.prevent_on == Some(listener_id) {
                event.prevent_default();
            }
        }
    }

    fn make_tree() -> Node {
        let mut root = Node::elem("div");
        root.id = Some("root".into());
        let mut child = Node::elem("p");
        child.id = Some("p".into());
        root.children.push(child);
        root
    }

    #[test]
    fn capture_then_bubble_order() {
        let mut root = make_tree();
        root.add_event_listener("click", true, 1); // root capture
        root.add_event_listener("click", false, 2); // root bubble
        let p = root.get_element_by_id("p").unwrap();
        p.add_event_listener("click", true, 3); // p capture
        p.add_event_listener("click", false, 4); // p bubble

        let mut event = Event::new("click", EventInit::default());
        let mut host = TestHost::new();
        assert!(Node::dispatch_event(&mut root, &[0], &mut event, &mut host));
        assert_eq!(
            host.log,
            vec![
                (1, "root".into(), "click".into()),
                (3, "p".into(), "click".into()),
                (4, "p".into(), "click".into()),
                (2, "root".into(), "click".into()),
            ]
        );
    }

    #[test]
    fn stop_propagation_stops_bubble() {
        let mut root = make_tree();
        root.add_event_listener("click", false, 1);
        let p = root.get_element_by_id("p").unwrap();
        p.add_event_listener("click", false, 2);

        let mut event = Event::new("click", EventInit::default());
        let mut host = TestHost::new();
        host.stop_on = Some(2);
        assert!(Node::dispatch_event(&mut root, &[0], &mut event, &mut host));
        assert_eq!(host.log, vec![(2, "p".into(), "click".into())]);
    }

    #[test]
    fn prevent_default_is_returned() {
        let mut root = make_tree();
        let p = root.get_element_by_id("p").unwrap();
        p.add_event_listener("click", false, 1);

        let mut event = Event::new("click", EventInit::default());
        let mut host = TestHost::new();
        host.prevent_on = Some(1);
        assert!(!Node::dispatch_event(
            &mut root,
            &[0],
            &mut event,
            &mut host
        ));
    }

    /// Non-bubbling events still invoke non-capture listeners on the target.
    #[test]
    fn non_bubbling_fires_target_noncapture() {
        let mut root = make_tree();
        root.add_event_listener("click", true, 1);
        root.add_event_listener("click", false, 2);
        let p = root.get_element_by_id("p").unwrap();
        p.add_event_listener("click", false, 3);

        let mut event = Event::new(
            "click",
            EventInit {
                bubbles: false,
                cancelable: true,
                composed: true,
                detail: String::new(),
            },
        );
        let mut host = TestHost::new();
        assert!(Node::dispatch_event(&mut root, &[0], &mut event, &mut host));
        assert_eq!(
            host.log,
            vec![
                (1, "root".into(), "click".into()),
                (3, "p".into(), "click".into()),
            ]
        );
    }

    #[test]
    fn once_listener_fires_only_once() {
        let mut root = make_tree();
        let p = root.get_element_by_id("p").unwrap();
        p.add_event_listener_flags("click", false, true, false, 1);

        let mut host = TestHost::new();
        let mut event = Event::new("click", EventInit::default());
        assert!(Node::dispatch_event(&mut root, &[0], &mut event, &mut host));
        assert_eq!(host.log.len(), 1);
        host.log.clear();
        let mut event = Event::new("click", EventInit::default());
        assert!(Node::dispatch_event(&mut root, &[0], &mut event, &mut host));
        assert!(host.log.is_empty());
    }

    #[test]
    fn passive_listener_cannot_prevent_default() {
        let mut root = make_tree();
        let p = root.get_element_by_id("p").unwrap();
        p.add_event_listener_flags("click", false, false, true, 1);

        let mut event = Event::new("click", EventInit::default());
        let mut host = TestHost::new();
        host.prevent_on = Some(1);
        assert!(Node::dispatch_event(&mut root, &[0], &mut event, &mut host));
        assert!(!event.default_prevented);
    }

    #[test]
    fn current_target_and_phase_clear_after_dispatch() {
        let mut root = make_tree();
        let p = root.get_element_by_id("p").unwrap();
        p.add_event_listener("click", false, 1);
        let mut event = Event::new("click", EventInit::default());
        let mut host = TestHost::new();
        assert!(Node::dispatch_event(&mut root, &[0], &mut event, &mut host));
        assert!(event.current_target.is_none());
        assert_eq!(event.event_phase, Event::NONE);
    }

    /// Removing the target during parent capture must not retarget at-target
    /// onto the sibling that slid into index 0.
    #[test]
    fn mutation_does_not_retarget_sibling() {
        let mut root = Node::elem("div");
        root.id = Some("root".into());
        let mut p = Node::elem("p");
        p.id = Some("p".into());
        p.add_event_listener("click", false, 2);
        let mut q = Node::elem("q");
        q.id = Some("q".into());
        q.add_event_listener("click", false, 3);
        root.append_child(p);
        root.append_child(q);
        root.add_event_listener("click", true, 1);
        root.add_event_listener("click", false, 4);

        struct RemoveHost {
            log: Vec<(u64, String)>,
        }
        impl EventHost for RemoveHost {
            fn invoke(&mut self, listener_id: u64, event: &mut Event) {
                self.log.push((
                    listener_id,
                    event.current_target.clone().unwrap_or_default(),
                ));
            }
            fn invoke_in_tree(&mut self, listener_id: u64, event: &mut Event, root: &mut Node) {
                self.invoke(listener_id, event);
                if listener_id == 1 {
                    root.remove_child(0);
                }
            }
        }

        let mut event = Event::new("click", EventInit::default());
        let mut host = RemoveHost { log: Vec::new() };
        assert!(Node::dispatch_event(&mut root, &[0], &mut event, &mut host));
        assert_eq!(
            host.log,
            vec![(1, "root".into()), (4, "root".into())],
            "p is gone; q must not inherit p's at-target: {:?}",
            host.log
        );
        assert!(root.get_element_by_id("p").is_none());
        assert!(root.get_element_by_id("q").is_some());
        assert!(event.current_target.is_none());
    }
}
