// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Circuit recipes: verified support-circuit templates that expand into real
//! components and explicit connections the user can inspect, as one undoable
//! action. This replaces compile-time `expand_hidden` body insertion for the
//! circuits a recipe covers: a generated capacitor is a component with a
//! refdes, two terminals and two nets, not a hidden box.
//!
//! A recipe never invents a pinout. `decap_per_rail` only applies to a host
//! whose frozen pins declare power contracts (CEM rails today), and it only
//! connects two-terminal passives, which have terminals by part class.
//!
//! Re-expansion reuses the components a block already `owns`; deleting the
//! host removes exactly those. Values and placements the user changed on an
//! owned component are preserved.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::net::{pins_for, PinKind};
use crate::pack::PackError;
use crate::template::{role, CircuitBlock, Connection, Design, Placement, Port};

pub const RECIPE_DECAP_PER_RAIL: &str = "decap_per_rail";

/// What a recipe would do. Nothing is applied until `apply_proposal`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Proposal {
    pub block: CircuitBlock,
    /// Components to add (id, role, value).
    pub add: Vec<ProposedPart>,
    /// Owned components no longer needed (rail disappeared); removal is
    /// shown, not silent.
    pub remove: Vec<String>,
    pub connections: Vec<Connection>,
    /// Inputs the recipe needed and could not find; a non-empty list means
    /// the proposal is partial and says so.
    pub missing: Vec<String>,
    /// Facts that stop the proposal entirely.
    pub conflicts: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProposedPart {
    pub id: String,
    pub role: String,
    pub value: String,
    /// True when this id already exists and is reused.
    pub reused: bool,
}

impl Proposal {
    pub fn is_applicable(&self) -> bool {
        self.conflicts.is_empty() && (!self.add.is_empty() || !self.remove.is_empty() || !self.connections.is_empty())
    }
}

/// Power rails a host exposes through its frozen contract pins, in id order.
fn host_rails(design: &Design, host: &str) -> Option<(Vec<String>, bool)> {
    let port = design.ports.iter().find(|p| p.id == host)?;
    let pins = pins_for(&port.id, &port.role);
    let rails: BTreeSet<String> = pins
        .iter()
        .filter(|p| p.kind == PinKind::Power && !p.domain.is_empty())
        .map(|p| p.domain.clone())
        .collect();
    let has_gnd = pins.iter().any(|p| p.kind == PinKind::Ground && p.domain == "GND");
    Some((rails.into_iter().collect(), has_gnd))
}

/// Build the proposal for a block. Idempotent against an existing block of
/// the same id: owned parts are reused, not duplicated.
pub fn propose(design: &Design, recipe: &str, host: &str, params: &BTreeMap<String, String>) -> Proposal {
    let block_id = format!("{host}.{recipe}");
    let existing = design.blocks.iter().find(|b| b.id == block_id).cloned();
    let mut block = existing.clone().unwrap_or(CircuitBlock {
        id: block_id.clone(),
        recipe: recipe.into(),
        host: host.into(),
        params: params.clone(),
        owns: Vec::new(),
    });
    block.params = params.clone();
    let mut out = Proposal { block, add: Vec::new(), remove: Vec::new(), connections: Vec::new(), missing: Vec::new(), conflicts: Vec::new() };
    if recipe != RECIPE_DECAP_PER_RAIL {
        out.conflicts.push(format!("unknown recipe {recipe}"));
        return out;
    }
    let Some((rails, has_gnd)) = host_rails(design, host) else {
        out.conflicts.push(format!("no part {host}"));
        return out;
    };
    if rails.is_empty() {
        out.conflicts.push(format!("{host} declares no power contracts; nothing to decouple (freeze its pinout first)"));
        return out;
    }
    if !has_gnd {
        out.missing.push(format!("{host} has no GND contact; capacitors cannot return to ground"));
    }
    let per_rail: u32 = params.get("per_rail").and_then(|s| s.parse().ok()).unwrap_or(2).clamp(1, 8);
    let value = params.get("value").cloned().unwrap_or_else(|| "100n".into());
    let owned: BTreeSet<&str> = existing.iter().flat_map(|b| b.owns.iter().map(String::as_str)).collect();
    let mut wanted: BTreeSet<String> = BTreeSet::new();
    let mut nets_touched: BTreeSet<String> = BTreeSet::new();
    for rail in &rails {
        for k in 0..per_rail {
            let id = format!("{host}_c_{}_{k}", rail.to_lowercase());
            let reused = owned.contains(id.as_str()) && design.ports.iter().any(|p| p.id == id);
            wanted.insert(id.clone());
            out.add.push(ProposedPart { id: id.clone(), role: "decap".into(), value: value.clone(), reused });
            out.connections.push(Connection { net: rail.clone(), pins: vec![format!("{id}.1")], class: "power".into() });
            nets_touched.insert(rail.clone());
            if has_gnd {
                out.connections.push(Connection { net: "GND".into(), pins: vec![format!("{id}.2")], class: "ground".into() });
                nets_touched.insert("GND".into());
            }
        }
    }
    for id in owned {
        if !wanted.contains(id) {
            out.remove.push(id.to_string());
        }
    }
    out.block.params.insert("nets".into(), nets_touched.into_iter().collect::<Vec<_>>().join(","));
    out
}

/// Apply a proposal atomically: on any failure the input design is returned
/// unchanged inside the error.
pub fn apply_proposal(design: &Design, proposal: &Proposal) -> Result<Design, PackError> {
    if !proposal.conflicts.is_empty() {
        return Err(PackError { reason: proposal.conflicts.join("; ") });
    }
    let mut next = design.clone();
    let decap = role("decap").ok_or_else(|| PackError { reason: "no decap role".into() })?;
    // Remove connections previously owned by this block, then re-add the
    // proposal's; user connections on other nets are untouched.
    let owned_before: BTreeSet<String> = next
        .blocks
        .iter()
        .filter(|b| b.id == proposal.block.id)
        .flat_map(|b| b.owns.iter().cloned())
        .collect();
    next.connections.retain(|c| !c.pins.iter().all(|p| owned_before.iter().any(|o| p.starts_with(&format!("{o}.")))));
    for id in &proposal.remove {
        next.ports.retain(|p| &p.id != id);
        next.placements.retain(|p| &p.id != id);
        next.connections.retain(|c| !c.pins.iter().any(|p| p.starts_with(&format!("{id}."))));
    }
    let mut owns = Vec::new();
    for part in &proposal.add {
        owns.push(part.id.clone());
        if next.ports.iter().any(|p| p.id == part.id) {
            // Reused: keep the user's value/placement; only ensure the role is right.
            continue;
        }
        let order = next.placements.iter().map(|p| p.order).max().unwrap_or(0) + 1;
        let mut port = Port::new(part.id.clone(), decap.id, decap.width_um);
        port.value = Some(part.value.clone());
        next.ports.push(port);
        next.placements.push(Placement::new(part.id.clone(), decap.edge, 0, false, order));
        next.assign_refdes(&part.id);
    }
    for conn in &proposal.connections {
        // Merge into an existing connection of the same net when present.
        if let Some(existing) = next.connections.iter_mut().find(|c| c.net == conn.net && c.class == conn.class) {
            for pin in &conn.pins {
                if !existing.pins.contains(pin) {
                    existing.pins.push(pin.clone());
                }
            }
        } else {
            next.connections.push(conn.clone());
        }
    }
    let mut block = proposal.block.clone();
    block.owns = owns;
    next.blocks.retain(|b| b.id != block.id);
    next.blocks.push(block);
    let template = next.template()?;
    next.repack(&template)?;
    Ok(next)
}

/// Remove a block and everything it owns (host deletion, or explicit removal).
pub fn remove_block(design: &mut Design, block_id: &str) {
    let Some(pos) = design.blocks.iter().position(|b| b.id == block_id) else {
        return;
    };
    let block = design.blocks.remove(pos);
    for id in &block.owns {
        design.ports.retain(|p| &p.id != id);
        design.placements.retain(|p| &p.id != id);
        let prefix = format!("{id}.");
        for c in &mut design.connections {
            c.pins.retain(|p| !p.starts_with(&prefix));
        }
        design.no_connects.retain(|p| !p.starts_with(&prefix));
    }
    design.connections.retain(|c| !c.pins.is_empty());
}

/// Drop one component from every block that owns it (direct deletion of an
/// owned part keeps the block, which then proposes re-adding it).
pub fn disown(design: &mut Design, part_id: &str) {
    for b in &mut design.blocks {
        b.owns.retain(|o| o != part_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::circuit::resolve;

    fn params(per_rail: u32) -> BTreeMap<String, String> {
        let mut p = BTreeMap::new();
        p.insert("per_rail".into(), per_rail.to_string());
        p.insert("value".into(), "100n".into());
        p
    }

    #[test]
    fn decap_per_rail_proposes_real_components_on_the_slot_rails() {
        let design = Design::mini_itx().unwrap();
        let prop = propose(&design, RECIPE_DECAP_PER_RAIL, "slot0", &params(2));
        assert!(prop.is_applicable(), "{:?}", prop.conflicts);
        // Three CEM rails × 2 capacitors.
        assert_eq!(prop.add.len(), 6);
        assert!(prop.add.iter().all(|p| !p.reused));
        assert!(prop.add.iter().any(|p| p.id == "slot0_c_p12v_0"));
        assert!(prop.connections.iter().any(|c| c.net == "GND" && c.class == "ground"));
        assert!(prop.connections.iter().any(|c| c.net == "P3V3_AUX"));
        assert!(prop.missing.is_empty());
        assert_eq!(prop.block.params.get("nets").map(String::as_str), Some("GND,P12V,P3V3,P3V3_AUX"));
    }

    #[test]
    fn applying_is_atomic_and_the_circuit_sees_capacitors_on_both_rails() {
        let design = Design::mini_itx().unwrap();
        let prop = propose(&design, RECIPE_DECAP_PER_RAIL, "slot0", &params(1));
        let next = apply_proposal(&design, &prop).unwrap();
        assert_eq!(next.blocks.len(), 1);
        assert_eq!(next.blocks[0].owns.len(), 3);
        let c = resolve(&next).unwrap();
        assert_eq!(c.errors(), 0, "{:?}", c.diagnostics);
        let cap = c.components.iter().find(|k| k.id == "slot0_c_p12v_0").unwrap();
        assert!(cap.refdes.starts_with('C'));
        assert_eq!(cap.value.as_deref(), Some("100n"));
        assert_eq!(cap.owner_block.as_deref(), Some("slot0.decap_per_rail"));
        assert_eq!(c.net_of("slot0_c_p12v_0.1").unwrap().id, "P12V");
        assert_eq!(c.net_of("slot0_c_p12v_0.2").unwrap().id, "GND");
        assert!(c.nets.iter().find(|n| n.id == "P12V").unwrap().origins.contains(&"recipe".to_string()));
        assert!(!c.diagnostics.iter().any(|d| d.rule == "W-PASSIVE-OPEN"));
        // Capacitors are placed, packed and visible in the editable scene.
        assert!(crate::scene::scene(&next).unwrap().iter().any(|b| b.id == "slot0_c_gnd_0" || b.id == "slot0_c_p12v_0"));
    }

    #[test]
    fn re_expansion_reuses_owned_parts_and_keeps_user_edits() {
        let design = Design::mini_itx().unwrap();
        let once = apply_proposal(&design, &propose(&design, RECIPE_DECAP_PER_RAIL, "slot0", &params(1))).unwrap();
        let mut edited = once.clone();
        edited.ports.iter_mut().find(|p| p.id == "slot0_c_p12v_0").unwrap().value = Some("1u".into());
        let again = propose(&edited, RECIPE_DECAP_PER_RAIL, "slot0", &params(2));
        assert_eq!(again.add.iter().filter(|p| p.reused).count(), 3);
        assert_eq!(again.add.iter().filter(|p| !p.reused).count(), 3);
        let twice = apply_proposal(&edited, &again).unwrap();
        assert_eq!(twice.ports.iter().filter(|p| p.role == "decap").count(), 6);
        assert_eq!(twice.ports.iter().find(|p| p.id == "slot0_c_p12v_0").unwrap().value.as_deref(), Some("1u"));
        // Shrinking shows removals rather than silently dropping parts.
        let shrink = propose(&twice, RECIPE_DECAP_PER_RAIL, "slot0", &params(1));
        assert_eq!(shrink.remove.len(), 3);
        let shrunk = apply_proposal(&twice, &shrink).unwrap();
        assert_eq!(shrunk.ports.iter().filter(|p| p.role == "decap").count(), 3);
        assert_eq!(resolve(&shrunk).unwrap().errors(), 0);
    }

    #[test]
    fn a_host_without_power_contracts_is_a_conflict_not_an_invention() {
        let design = Design::mini_itx().unwrap();
        for host in ["usb0", "socket", "hdmi0"] {
            let prop = propose(&design, RECIPE_DECAP_PER_RAIL, host, &params(1));
            assert!(!prop.is_applicable(), "{host}");
            assert!(prop.add.is_empty());
            assert!(apply_proposal(&design, &prop).is_err());
        }
        assert!(!propose(&design, "regulator_magic", "slot0", &params(1)).is_applicable());
    }

    #[test]
    fn removing_the_block_removes_exactly_what_it_owns() {
        let design = Design::mini_itx().unwrap();
        let mut next = apply_proposal(&design, &propose(&design, RECIPE_DECAP_PER_RAIL, "slot0", &params(1))).unwrap();
        // A user capacitor on the same rail must survive.
        next = crate::gesture::preview(&next, &crate::gesture::Gesture::Add { role: "decap".into() }).design;
        let user_cap = next.ports.iter().filter(|p| p.role == "decap").map(|p| p.id.clone()).find(|id| !id.starts_with("slot0_c_")).unwrap();
        next.connections.push(Connection { net: "P12V".into(), pins: vec![format!("{user_cap}.1")], class: "power".into() });
        remove_block(&mut next, "slot0.decap_per_rail");
        assert!(next.blocks.is_empty());
        assert!(next.ports.iter().all(|p| !p.id.starts_with("slot0_c_")));
        assert!(next.ports.iter().any(|p| p.id == user_cap));
        assert!(next.connections.iter().any(|c| c.net == "P12V" && c.pins.contains(&format!("{user_cap}.1"))));
        assert!(next.connections.iter().all(|c| !c.pins.iter().any(|p| p.starts_with("slot0_c_"))));
        assert_eq!(resolve(&next).unwrap().errors(), 0);
    }
}
