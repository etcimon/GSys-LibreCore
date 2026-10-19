// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! The resolved circuit: the one snapshot that the preview guides, the
//! router, the SKiDL compiler and the simulator all consume. It is derived
//! from a `Design` and never edited directly — `nets.json` or meshes cannot
//! become a second editable circuit.
//!
//! Resolution unions three sources, in this order, and every disagreement is
//! a `Diagnostic` linked to design ids rather than a silent join or drop:
//!
//! 1. **Contract nets** — frozen distributor names already tied in
//!    `corev-mb/lib/interfaces.py` (CEM rails, SATA grounds).
//! 2. **Explicit connections** — `Design.connections`, the user's intent.
//! 3. **Recipe connections** — produced by `recipes.rs` and stored as explicit
//!    connections owned by a `CircuitBlock`.
//!
//! A pin may belong to one net. Required pins (power/ground contracts of
//! populated parts) must connect or be an explicit no-connect.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::net::{auto_connect, pins_for, NetClass, Pin, PinKind};
use crate::pack::PackError;
use crate::scene::scene;
use crate::template::{Design, PartRef, Side};

pub const CIRCUIT_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Component {
    pub id: String,
    pub refdes: String,
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub part: Option<PartRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    pub dnp: bool,
    pub side: Side,
    pub yaw_q: u8,
    pub x_um: i64,
    pub y_um: i64,
    /// `gap` | `unnamed_grid` | `names_only` | `footprint` | `catalog` | `two_terminal`
    pub pin_spec: String,
    pub pin_count: usize,
    /// Which recipe block generated this component, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_block: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CircuitNet {
    pub id: String,
    pub class: NetClass,
    pub pins: Vec<String>,
    /// `contract` | `explicit` | `recipe` — every source that contributed.
    pub origins: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Diagnostic {
    /// Stable rule id, e.g. `E-PIN-UNKNOWN`, `W-NET-NO-SOURCE`.
    pub rule: String,
    /// `error` | `warning` | `info`
    pub severity: String,
    pub stage: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub part: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pin: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub net: Option<String>,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suggestion: Option<String>,
}

/// A pin that must end up connected (or explicitly open) and why.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Obligation {
    pub pin: String,
    pub reason: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Circuit {
    pub schema_version: u32,
    pub template_id: String,
    pub package_id: String,
    pub components: Vec<Component>,
    pub pins: Vec<Pin>,
    pub nets: Vec<CircuitNet>,
    pub no_connects: Vec<String>,
    pub obligations: Vec<Obligation>,
    pub diagnostics: Vec<Diagnostic>,
}

impl Circuit {
    pub fn errors(&self) -> usize {
        self.diagnostics.iter().filter(|d| d.severity == "error").count()
    }

    pub fn warnings(&self) -> usize {
        self.diagnostics.iter().filter(|d| d.severity == "warning").count()
    }

    pub fn net_of(&self, pin_id: &str) -> Option<&CircuitNet> {
        self.nets.iter().find(|n| n.pins.iter().any(|p| p == pin_id))
    }

    pub fn pin(&self, pin_id: &str) -> Option<&Pin> {
        self.pins.iter().find(|p| p.id == pin_id)
    }
}

fn spec_name(role: &str) -> &'static str {
    match crate::net::pin_spec(role) {
        crate::net::PinSpec::Gap => "gap",
        crate::net::PinSpec::UnnamedGrid => "unnamed_grid",
        crate::net::PinSpec::NamesOnly { .. } => "names_only",
        crate::net::PinSpec::Footprint { .. } => "footprint",
        crate::net::PinSpec::Catalog { .. } => "catalog",
        crate::net::PinSpec::TwoTerminal => "two_terminal",
    }
}

fn class_of(s: &str) -> NetClass {
    match s {
        "power" => NetClass::Power,
        "ground" => NetClass::Ground,
        "clock" => NetClass::Clock,
        _ => NetClass::Signal,
    }
}

/// Roles whose power pins *supply* a rail. None of them has frozen pins yet,
/// so every rail today is honestly reported as source-less.
const SOURCE_ROLES: &[&str] = &["dc_jack", "vtt", "rtc_battery"];

fn diag(rule: &str, severity: &str, message: String) -> Diagnostic {
    Diagnostic {
        rule: rule.into(),
        severity: severity.into(),
        stage: "resolve".into(),
        part: None,
        pin: None,
        net: None,
        message,
        suggestion: None,
    }
}

/// Resolve the design into one circuit snapshot.
pub fn resolve(design: &Design) -> Result<Circuit, PackError> {
    let bodies = scene(design)?;
    let owner_of: BTreeMap<&str, &str> = design
        .blocks
        .iter()
        .flat_map(|b| b.owns.iter().map(move |o| (o.as_str(), b.id.as_str())))
        .collect();
    let mut components = Vec::new();
    let mut pins: Vec<Pin> = Vec::new();
    for place in &design.placements {
        let Some(port) = design.ports.iter().find(|p| p.id == place.id) else {
            continue;
        };
        let body = bodies.iter().find(|b| b.id == place.id);
        let part_pins = pins_for(&port.id, &port.role);
        components.push(Component {
            id: port.id.clone(),
            refdes: port.refdes.clone().unwrap_or_default(),
            role: port.role.clone(),
            part: port.part.clone(),
            value: port.value.clone(),
            dnp: port.dnp,
            side: place.side,
            yaw_q: place.yaw_q % 4,
            x_um: body.map(|b| b.x_um).unwrap_or(0),
            y_um: body.map(|b| b.y_um).unwrap_or(0),
            pin_spec: spec_name(&port.role).into(),
            pin_count: part_pins.len(),
            owner_block: owner_of.get(port.id.as_str()).map(|s| s.to_string()),
        });
        pins.extend(part_pins);
    }
    let pin_index: BTreeMap<&str, &Pin> = pins.iter().map(|p| (p.id.as_str(), p)).collect();
    let dnp: BTreeSet<&str> = components.iter().filter(|c| c.dnp).map(|c| c.id.as_str()).collect();

    let mut diagnostics = Vec::new();
    let mut nets: BTreeMap<String, CircuitNet> = BTreeMap::new();
    let mut member_of: BTreeMap<String, String> = BTreeMap::new();

    // 1. Contract nets.
    for net in auto_connect(design) {
        for pin in &net.pins {
            member_of.insert(pin.clone(), net.id.clone());
        }
        nets.insert(
            net.id.clone(),
            CircuitNet { id: net.id, class: net.class, pins: net.pins, origins: vec!["contract".into()] },
        );
    }

    // 2. Explicit (and recipe-owned) connections.
    let recipe_nets: BTreeSet<&str> = design
        .blocks
        .iter()
        .flat_map(|b| b.params.get("nets").map(|s| s.split(',').collect::<Vec<_>>()).unwrap_or_default())
        .collect();
    for conn in &design.connections {
        let class = class_of(&conn.class);
        let origin = if recipe_nets.contains(conn.net.as_str()) { "recipe" } else { "explicit" };
        let entry = nets.entry(conn.net.clone()).or_insert_with(|| CircuitNet {
            id: conn.net.clone(),
            class,
            pins: Vec::new(),
            origins: Vec::new(),
        });
        if !entry.origins.iter().any(|o| o == origin) {
            entry.origins.push(origin.into());
        }
        if entry.class != class && !entry.origins.contains(&"contract".to_string()) {
            let mut d = diag(
                "E-NET-CLASS",
                "error",
                format!("net {} declared as {:?} and {:?}", conn.net, entry.class, class),
            );
            d.net = Some(conn.net.clone());
            diagnostics.push(d);
        }
        for pin_id in &conn.pins {
            let Some(pin) = pin_index.get(pin_id.as_str()) else {
                let mut d = diag("E-PIN-UNKNOWN", "error", format!("connection to {} names a pin that does not exist", conn.net));
                d.pin = Some(pin_id.clone());
                d.net = Some(conn.net.clone());
                d.suggestion = Some("remove the connection or add the part/pin it refers to".into());
                diagnostics.push(d);
                continue;
            };
            // A contract-domain pin (P12V, GND, …) only joins its own rail.
            // This is the specific message, so it is checked before the
            // generic one-net-per-pin rule.
            let contracted = matches!(pin.kind, PinKind::Power | PinKind::Ground) && !pin.domain.is_empty();
            if contracted && pin.domain != conn.net {
                let mut d = diag(
                    "E-DOMAIN-CLASH",
                    "error",
                    format!("pin {} is a {} contact; it cannot be wired to {}", pin_id, pin.domain, conn.net),
                );
                d.pin = Some(pin_id.clone());
                d.part = Some(pin.part.clone());
                d.net = Some(conn.net.clone());
                diagnostics.push(d);
                continue;
            }
            if let Some(existing) = member_of.get(pin_id) {
                if existing != &conn.net {
                    let mut d = diag(
                        "E-PIN-MULTI-NET",
                        "error",
                        format!("pin {} is on {} and cannot also join {}", pin_id, existing, conn.net),
                    );
                    d.pin = Some(pin_id.clone());
                    d.part = Some(pin.part.clone());
                    d.net = Some(conn.net.clone());
                    diagnostics.push(d);
                }
                continue;
            }
            entry.pins.push(pin_id.clone());
            member_of.insert(pin_id.clone(), conn.net.clone());
        }
    }

    // 3. No-connects.
    let mut no_connects = Vec::new();
    for pin_id in &design.no_connects {
        if !pin_index.contains_key(pin_id.as_str()) {
            let mut d = diag("E-PIN-UNKNOWN", "error", "no-connect names a pin that does not exist".into());
            d.pin = Some(pin_id.clone());
            diagnostics.push(d);
            continue;
        }
        if let Some(net) = member_of.get(pin_id) {
            let mut d = diag("E-NC-CONNECTED", "error", format!("pin {pin_id} is marked no-connect but is on {net}"));
            d.pin = Some(pin_id.clone());
            d.net = Some(net.clone());
            diagnostics.push(d);
            continue;
        }
        no_connects.push(pin_id.clone());
    }

    // 4. Obligations: contract power/ground pins of populated parts.
    let mut obligations = Vec::new();
    for pin in &pins {
        if dnp.contains(pin.part.as_str()) {
            continue;
        }
        let required = matches!(pin.kind, PinKind::Power | PinKind::Ground) && !pin.domain.is_empty();
        if required {
            obligations.push(Obligation { pin: pin.id.clone(), reason: format!("{} contact", pin.domain) });
            if !member_of.contains_key(&pin.id) && !no_connects.contains(&pin.id) {
                let mut d = diag("E-OPEN-REQUIRED", "error", format!("{} must connect to {}", pin.id, pin.domain));
                d.pin = Some(pin.id.clone());
                d.part = Some(pin.part.clone());
                diagnostics.push(d);
            }
        }
    }
    // A two-terminal passive with a floating leg does nothing.
    for c in components.iter().filter(|c| c.pin_spec == "two_terminal" && !c.dnp) {
        let connected = pins.iter().filter(|p| p.part == c.id && member_of.contains_key(&p.id)).count();
        if connected == 1 {
            let mut d = diag("W-PASSIVE-OPEN", "warning", format!("{} ({}) has one terminal floating", c.refdes, c.id));
            d.part = Some(c.id.clone());
            d.suggestion = Some("connect the second terminal or mark it no-connect".into());
            diagnostics.push(d);
        }
    }

    // 5. Rails without a source.
    for net in nets.values() {
        if !matches!(net.class, NetClass::Power | NetClass::Ground) {
            continue;
        }
        let has_source = net.pins.iter().any(|p| {
            pin_index
                .get(p.as_str())
                .and_then(|pin| components.iter().find(|c| c.id == pin.part))
                .map(|c| SOURCE_ROLES.contains(&c.role.as_str()))
                .unwrap_or(false)
        });
        if !has_source {
            let mut d = diag(
                "W-NET-NO-SOURCE",
                "warning",
                format!("rail {} has consumers but no regulator or supply connector on it", net.id),
            );
            d.net = Some(net.id.clone());
            d.suggestion = Some("add a power-entry or regulator block that drives this rail".into());
            diagnostics.push(d);
        }
    }

    let mut nets: Vec<CircuitNet> = nets.into_values().collect();
    for n in &mut nets {
        n.pins.sort();
    }
    diagnostics.sort_by(|a, b| (&a.severity, &a.rule, &a.pin, &a.net).cmp(&(&b.severity, &b.rule, &b.pin, &b.net)));
    Ok(Circuit {
        schema_version: CIRCUIT_SCHEMA_VERSION,
        template_id: design.template_id.clone(),
        package_id: design.settings.package_id.clone(),
        components,
        pins,
        nets,
        no_connects,
        obligations,
        diagnostics,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::template::Connection;

    /// Pin id (`part.number`) of the frozen pin with this CEM *name*.
    fn slot_pin(name: &str) -> String {
        pins_for("slot0", "pcie_slot").into_iter().find(|p| p.name == name).map(|p| p.id).expect(name)
    }

    #[test]
    fn mini_itx_resolves_contract_rails_and_reports_missing_sources_honestly() {
        let c = resolve(&Design::mini_itx().unwrap()).unwrap();
        assert_eq!(c.schema_version, CIRCUIT_SCHEMA_VERSION);
        assert!(c.components.iter().all(|k| !k.refdes.is_empty()), "every component has a refdes");
        let slot = c.components.iter().find(|k| k.id == "slot0").unwrap();
        assert!(slot.refdes.starts_with('J'));
        assert_eq!(slot.pin_count, 164);
        let p12 = c.nets.iter().find(|n| n.id == "P12V").unwrap();
        assert_eq!(p12.class, NetClass::Power);
        assert_eq!(p12.origins, vec!["contract".to_string()]);
        assert!(p12.pins.iter().all(|p| p.starts_with("slot0.")));
        // Honest: no regulator exists in the design, so every rail is source-less.
        assert!(c.diagnostics.iter().any(|d| d.rule == "W-NET-NO-SOURCE" && d.net.as_deref() == Some("P12V")));
        assert_eq!(c.errors(), 0, "{:?}", c.diagnostics);
        // Every contract pin is an obligation and is satisfied by its contract net.
        let b1 = slot_pin("B1");
        assert!(c.obligations.iter().any(|o| o.pin == b1));
        assert_eq!(c.net_of(&b1).map(|n| n.id.as_str()), Some("P12V"));
        assert!(!c.diagnostics.iter().any(|d| d.rule == "E-OPEN-REQUIRED"));
    }

    #[test]
    fn explicit_connections_join_compatible_pins_and_refuse_domain_clashes() {
        let mut design = Design::mini_itx().unwrap();
        let add = crate::gesture::preview(&design, &crate::gesture::Gesture::Add { role: "decap".into() });
        design = add.design;
        let cap = design.ports.iter().find(|p| p.role == "decap").unwrap().id.clone();
        design.connections.push(Connection { net: "P3V3".into(), pins: vec![format!("{cap}.1")], class: "power".into() });
        design.connections.push(Connection { net: "GND".into(), pins: vec![format!("{cap}.2")], class: "ground".into() });
        // Illegal: a P12V contact wired onto the 3.3 V rail.
        let b1 = slot_pin("B1");
        design.connections.push(Connection { net: "P3V3".into(), pins: vec![b1.clone()], class: "power".into() });
        // Illegal: a pin that does not exist.
        design.connections.push(Connection { net: "P3V3".into(), pins: vec!["ghost0.7".into()], class: "power".into() });
        let c = resolve(&design).unwrap();
        let p3 = c.nets.iter().find(|n| n.id == "P3V3").unwrap();
        assert!(p3.pins.contains(&format!("{cap}.1")));
        assert!(!p3.pins.contains(&b1), "clash must not join");
        assert_eq!(c.net_of(&b1).map(|n| n.id.as_str()), Some("P12V"), "the contract rail keeps the pin");
        assert!(p3.origins.contains(&"contract".to_string()) && p3.origins.contains(&"explicit".to_string()));
        assert!(c.diagnostics.iter().any(|d| d.rule == "E-DOMAIN-CLASH" && d.pin.as_deref() == Some(b1.as_str())));
        assert!(c.diagnostics.iter().any(|d| d.rule == "E-PIN-UNKNOWN" && d.pin.as_deref() == Some("ghost0.7")));
        assert_eq!(c.errors(), 2);
        assert!(!c.diagnostics.iter().any(|d| d.rule == "W-PASSIVE-OPEN"));
    }

    #[test]
    fn a_pin_on_two_nets_and_a_connected_no_connect_are_errors() {
        let mut design = Design::mini_itx().unwrap();
        design = crate::gesture::preview(&design, &crate::gesture::Gesture::Add { role: "decap".into() }).design;
        let cap = design.ports.iter().find(|p| p.role == "decap").unwrap().id.clone();
        design.connections.push(Connection { net: "P3V3".into(), pins: vec![format!("{cap}.1")], class: "power".into() });
        design.connections.push(Connection { net: "P12V".into(), pins: vec![format!("{cap}.1")], class: "power".into() });
        let b1 = slot_pin("B1");
        design.no_connects.push(b1.clone());
        let c = resolve(&design).unwrap();
        assert!(c.diagnostics.iter().any(|d| d.rule == "E-PIN-MULTI-NET" && d.pin.as_deref() == Some(format!("{cap}.1").as_str())));
        assert!(c.diagnostics.iter().any(|d| d.rule == "E-NC-CONNECTED" && d.pin.as_deref() == Some(b1.as_str())));
        assert!(c.diagnostics.iter().any(|d| d.rule == "W-PASSIVE-OPEN" && d.part.as_deref() == Some(cap.as_str())));
        assert!(c.no_connects.is_empty(), "a connected pin is not accepted as NC");
    }

    #[test]
    fn dnp_parts_carry_no_obligations() {
        let mut design = Design::mini_itx().unwrap();
        design.ports.iter_mut().find(|p| p.id == "slot0").unwrap().dnp = true;
        let c = resolve(&design).unwrap();
        assert!(c.obligations.iter().all(|o| !o.pin.starts_with("slot0.")));
        assert!(c.components.iter().find(|k| k.id == "slot0").unwrap().dnp);
    }

    #[test]
    fn resolution_is_deterministic() {
        let design = Design::mini_itx().unwrap();
        let a = serde_json::to_string(&resolve(&design).unwrap()).unwrap();
        let b = serde_json::to_string(&resolve(&design).unwrap()).unwrap();
        assert_eq!(a, b);
    }
}
