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
    /// Extra payload (key, mouse coordinates, etc.) as a JSON-ish string.
    pub detail: String,
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
            detail: init.detail,
        }
    }

    pub fn prevent_default(&mut self) {
        if self.cancelable {
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
}

/// Host side of listener invocation. The DOM does not own closures.
pub trait EventHost {
    fn invoke(&mut self, listener_id: u64, event: &mut Event);
}

impl Node {
    pub fn add_event_listener(&mut self, event_type: &str, capture: bool, id: u64) {
        self.event_listeners.push(Listener {
            id,
            event_type: event_type.to_ascii_lowercase(),
            capture,
        });
    }

    pub fn remove_event_listener(&mut self, id: u64) {
        self.event_listeners.retain(|l| l.id != id);
    }

    /// Dispatch `event` at the node described by `target_path`, which is a
    /// sequence of child indices from `root`. Capture phase walks root->target;
    /// bubble walks target->root. Returns `true` if the default action may run
    /// (i.e. `defaultPrevented` is false).
    pub fn dispatch_event(
        root: &mut Node,
        target_path: &[usize],
        event: &mut Event,
        host: &mut dyn EventHost,
    ) -> bool {
        let t = event.event_type.clone();

        // Capture phase: root -> target.
        for depth in 0..=target_path.len() {
            if event.propagation_stopped {
                break;
            }
            let node = node_at_path(root, &target_path[..depth]);
            event.current_target = node.id.clone();
            fire_listeners(node, &t, true, event, host);
        }

        // Bubble phase: target -> root, if the event bubbles.
        if event.bubbles && !event.propagation_stopped {
            for depth in (0..=target_path.len()).rev() {
                if event.propagation_stopped {
                    break;
                }
                let node = node_at_path(root, &target_path[..depth]);
                event.current_target = node.id.clone();
                fire_listeners(node, &t, false, event, host);
            }
        }

        !event.default_prevented
    }
}

fn fire_listeners(
    node: &mut Node,
    event_type: &str,
    capture: bool,
    event: &mut Event,
    host: &mut dyn EventHost,
) {
    // Snapshot the list so a listener removing itself does not perturb the
    // order or skip entries.
    let to_fire: Vec<u64> = node
        .event_listeners
        .iter()
        .filter(|l| l.event_type == event_type && l.capture == capture)
        .map(|l| l.id)
        .collect();
    for id in to_fire {
        if event.immediate_stopped {
            break;
        }
        host.invoke(id, event);
    }
}

fn node_at_path<'a>(root: &'a mut Node, path: &[usize]) -> &'a mut Node {
    let mut cur = root;
    for &i in path {
        if i >= cur.children.len() {
            // Fail closed: return the last valid node rather than panic.
            break;
        }
        cur = &mut cur.children[i];
    }
    cur
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
}
