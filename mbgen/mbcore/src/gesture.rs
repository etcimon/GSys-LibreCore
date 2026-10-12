//! Gestures propose a design. `preview` keeps the previous design when the
//! proposal does not pack. `AutoConnect` does not write nets onto `Design`.

use serde::{Deserialize, Serialize};

use crate::catalog::apply_package;
use crate::net::anchors;
use crate::pack::PackError;
use crate::template::{role, role_extents, template_by_id, Design, Placement, Port};

/// Snap radius for `Place`, in micrometres.
pub const SNAP_UM: i64 = 500;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Gesture {
    Add { role: String },
    Nudge { id: String, delta_um: i64 },
    Drag { id: String, s_um: i64 },
    Copy { id: String },
    Place { id: String, x_um: i64, y_um: i64 },
    Turn { id: String },
    Delete { id: String },
    SetProperty { id: String, key: String, value: String },
    AutoConnect { id: String },
    SetOutline { template_id: String },
    #[serde(other)]
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreviewResult {
    pub design: Design,
    pub applied: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

pub fn preview(design: &Design, gesture: &Gesture) -> PreviewResult {
    if matches!(gesture, Gesture::Unknown) {
        return reject(design, "unknown gesture".into());
    }
    let mut next = design.clone();
    let proposal = match gesture {
        Gesture::Add { role: role_id } => add(&mut next, role_id),
        Gesture::Nudge { id, delta_um } => move_to(&mut next, id, |s| s + delta_um),
        Gesture::Drag { id, s_um } => move_to(&mut next, id, |_| *s_um),
        Gesture::Copy { id } => copy(&mut next, id),
        Gesture::Place { id, x_um, y_um } => place(&mut next, id, *x_um, *y_um),
        Gesture::Turn { id } => turn(&mut next, id),
        Gesture::Delete { id } => delete(&mut next, id),
        Gesture::SetProperty { id, key, value } => set_property(&mut next, id, key, value),
        Gesture::AutoConnect { id } => auto_connect_ok(&next, id),
        Gesture::SetOutline { template_id } => set_outline(&mut next, template_id),
        Gesture::Unknown => unreachable!(),
    };
    if let Err(err) = proposal {
        return reject(design, err.reason);
    }
    match next.template().and_then(|template| next.repack(&template)) {
        Ok(()) => PreviewResult {
            design: next,
            applied: true,
            reason: None,
        },
        Err(err) => reject(design, err.reason),
    }
}

fn reject(design: &Design, reason: String) -> PreviewResult {
    PreviewResult {
        design: design.clone(),
        applied: false,
        reason: Some(reason),
    }
}

fn add(design: &mut Design, role_id: &str) -> Result<(), PackError> {
    let role = role(role_id).ok_or_else(|| PackError {
        reason: format!("unknown role {role_id}"),
    })?;
    let n = design.ports.iter().filter(|p| p.role == role.id).count() + 1;
    let id = format!("{}{n}", role.id);
    let order = design.placements.iter().map(|p| p.order).max().unwrap_or(0) + 1;
    design.ports.push(Port {
        id: id.clone(),
        role: role.id.into(),
        width_um: role.width_um,
    });
    design.placements.push(Placement {
        id,
        edge: role.edge.into(),
        s_um: 0,
        stack: 0,
        pinned: false,
        order,
        yaw_q: 0,
        x_um: None,
        y_um: None,
    });
    Ok(())
}

fn move_to(design: &mut Design, id: &str, s_of: impl FnOnce(i64) -> i64) -> Result<(), PackError> {
    let place = design
        .placements
        .iter_mut()
        .find(|p| p.id == id)
        .ok_or_else(|| PackError {
            reason: format!("no part {id}"),
        })?;
    place.s_um = s_of(place.s_um);
    place.pinned = true;
    Ok(())
}

fn copy(design: &mut Design, id: &str) -> Result<(), PackError> {
    let port = design
        .ports
        .iter()
        .find(|p| p.id == id)
        .ok_or_else(|| PackError {
            reason: format!("no part {id}"),
        })?
        .clone();
    let place = design
        .placements
        .iter()
        .find(|p| p.id == id)
        .ok_or_else(|| PackError {
            reason: format!("no part {id}"),
        })?
        .clone();
    let n = design.ports.iter().filter(|p| p.role == port.role).count() + 1;
    let new_id = format!("{}{n}", port.role);
    let order = place.order + 1;
    for later in &mut design.placements {
        if later.order >= order {
            later.order += 1;
        }
    }
    design.ports.push(Port {
        id: new_id.clone(),
        role: port.role,
        width_um: port.width_um,
    });
    design.placements.push(Placement {
        id: new_id,
        edge: place.edge,
        s_um: 0,
        stack: place.stack,
        pinned: false,
        order,
        yaw_q: place.yaw_q,
        x_um: None,
        y_um: None,
    });
    Ok(())
}

fn delete(design: &mut Design, id: &str) -> Result<(), PackError> {
    let port_i = design
        .ports
        .iter()
        .position(|p| p.id == id)
        .ok_or_else(|| PackError {
            reason: format!("no part {id}"),
        })?;
    let place_i = design
        .placements
        .iter()
        .position(|p| p.id == id)
        .ok_or_else(|| PackError {
            reason: format!("no part {id}"),
        })?;
    design.ports.remove(port_i);
    design.placements.remove(place_i);
    Ok(())
}

fn place(design: &mut Design, id: &str, x_um: i64, y_um: i64) -> Result<(), PackError> {
    if !design.placements.iter().any(|p| p.id == id) {
        return Err(PackError {
            reason: format!("no part {id}"),
        });
    }
    let (x, y) = snap_xy(design, x_um, y_um);
    let template = design.template()?;
    let port = design
        .ports
        .iter()
        .find(|p| p.id == id)
        .ok_or_else(|| PackError {
            reason: format!("no part {id}"),
        })?;
    let (sx, sy, _) = role_extents(&port.role, port.width_um);
    let yaw = design
        .placements
        .iter()
        .find(|p| p.id == id)
        .map(|p| p.yaw_q)
        .unwrap_or(0);
    if !crate::scene::on_board(&template, x, y, sx, sy, yaw) {
        return Err(PackError {
            reason: format!("{id} leaves the board"),
        });
    }
    let place = design
        .placements
        .iter_mut()
        .find(|p| p.id == id)
        .expect("part");
    place.s_um = s_from_xy(&place.edge, x, y);
    place.x_um = Some(x);
    place.y_um = Some(y);
    place.pinned = true;
    Ok(())
}

fn turn(design: &mut Design, id: &str) -> Result<(), PackError> {
    let template = design.template()?;
    let port = design
        .ports
        .iter()
        .find(|p| p.id == id)
        .ok_or_else(|| PackError {
            reason: format!("no part {id}"),
        })?
        .clone();
    let (sx, sy, sz) = role_extents(&port.role, port.width_um);
    let bodies = crate::scene::scene(design)?;
    let body = bodies.iter().find(|b| b.id == id).ok_or_else(|| PackError {
        reason: format!("no part {id}"),
    })?;
    let place = design
        .placements
        .iter_mut()
        .find(|p| p.id == id)
        .ok_or_else(|| PackError {
            reason: format!("no part {id}"),
        })?;
    if place.x_um.is_none() || place.y_um.is_none() {
        place.x_um = Some(body.x_um);
        place.y_um = Some(body.y_um);
    }
    place.yaw_q = (place.yaw_q + 1) % 4;
    place.pinned = true;
    let x = place.x_um.unwrap();
    let y = place.y_um.unwrap();
    if !crate::scene::on_board(&template, x, y, sx, sy, place.yaw_q) {
        return Err(PackError {
            reason: format!("{id} leaves the board"),
        });
    }
    let _ = sz;
    Ok(())
}

fn snap_xy(design: &Design, x_um: i64, y_um: i64) -> (i64, i64) {
    let limit = SNAP_UM.saturating_mul(SNAP_UM);
    let mut best: Option<(i64, i64, i64)> = None;
    for anchor in anchors(design) {
        let dx = anchor.x_um - x_um;
        let dy = anchor.y_um - y_um;
        let d2 = dx.saturating_mul(dx).saturating_add(dy.saturating_mul(dy));
        if d2 > limit {
            continue;
        }
        let closer = best.map(|(bd, _, _)| d2 < bd).unwrap_or(true);
        if closer {
            best = Some((d2, anchor.x_um, anchor.y_um));
        }
    }
    best.map(|(_, x, y)| (x, y)).unwrap_or((x_um, y_um))
}

fn s_from_xy(edge: &str, x_um: i64, y_um: i64) -> i64 {
    match edge {
        "drive" | "bracket" | "slot" => y_um,
        _ => x_um,
    }
}

fn set_property(design: &mut Design, id: &str, key: &str, value: &str) -> Result<(), PackError> {
    if !design.ports.iter().any(|p| p.id == id) {
        return Err(PackError {
            reason: format!("no part {id}"),
        });
    }
    match key {
        "package_id" => {
            *design = apply_package(design, value)?;
            Ok(())
        }
        "interface" => {
            let role = design
                .ports
                .iter()
                .find(|p| p.id == id)
                .map(|p| p.role.clone())
                .expect("part");
            if value == role {
                Ok(())
            } else {
                Err(PackError {
                    reason: format!("interface {value} is not declared for {id}"),
                })
            }
        }
        "hotkey" => {
            let v = value.trim();
            if v.is_empty() || v.len() > 16 {
                return Err(PackError {
                    reason: "hotkey must be 1 to 16 characters".into(),
                });
            }
            design.settings.hotkey = v.to_string();
            Ok(())
        }
        "timeout_ms" => {
            let n: i64 = value.parse().map_err(|_| PackError {
                reason: format!("timeout_ms {value} is not an integer"),
            })?;
            if !(0..=60_000).contains(&n) {
                return Err(PackError {
                    reason: "timeout_ms must be 0 to 60000".into(),
                });
            }
            design.settings.timeout_ms = n;
            Ok(())
        }
        "product" => {
            let v = value.trim();
            if v.is_empty() || v.len() > 32 {
                return Err(PackError {
                    reason: "product must be 1 to 32 characters".into(),
                });
            }
            design.settings.product = v.to_string();
            Ok(())
        }
        "domain" | "radio" | "support" => Err(PackError {
            reason: format!("{key} is not writable"),
        }),
        _ => Err(PackError {
            reason: format!("unknown property {key}"),
        }),
    }
}

fn auto_connect_ok(design: &Design, id: &str) -> Result<(), PackError> {
    if !design.ports.iter().any(|p| p.id == id) {
        return Err(PackError {
            reason: format!("no part {id}"),
        });
    }
    Ok(())
}

fn set_outline(design: &mut Design, template_id: &str) -> Result<(), PackError> {
    let template = template_by_id(template_id)?;
    if design.template_id == template.id {
        return Ok(());
    }
    design.template_id = template.id.clone();
    design.settings.gap_um = template.gap_um;
    let has_edge = |id: &str| template.edges.iter().any(|e| e.id == id);
    let mut ports = Vec::new();
    let mut placements = Vec::new();
    for place in &design.placements {
        let Some(port) = design.ports.iter().find(|p| p.id == place.id) else {
            continue;
        };
        let mut edge = place.edge.clone();
        if !has_edge(&edge) {
            let Some(r) = role(&port.role) else {
                continue;
            };
            if !has_edge(r.edge) {
                continue;
            }
            edge = r.edge.into();
        }
        ports.push(port.clone());
        placements.push(Placement {
            edge,
            s_um: 0,
            pinned: false,
            x_um: None,
            y_um: None,
            ..place.clone()
        });
    }
    if ports.is_empty() {
        *design = Design::from_template(template_id)?;
        return Ok(());
    }
    design.ports = ports;
    design.placements = placements;
    let stock = Design::from_template(template_id)?;
    for port in stock.ports {
        if design.ports.iter().any(|p| p.id == port.id || p.role == port.role) {
            continue;
        }
        let Some(place) = stock.placements.iter().find(|pl| pl.id == port.id).cloned() else {
            continue;
        };
        design.ports.push(port);
        design.placements.push(place);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::compile;
    use crate::net::{auto_connect, pins_for};
    use crate::pack::Interval;
    use crate::scene::scene;

    #[test]
    fn mini_itx_preview_packs_rear_jacks_inside_the_window() {
        let design = Design::mini_itx().unwrap();
        let template = design.template().unwrap();
        let rear = template.edges.iter().find(|e| e.id == "rear_io").unwrap();
        for id in ["usb0", "usb1", "lan0", "hdmi0"] {
            let place = design.placements.iter().find(|p| p.id == id).unwrap();
            let port = design.ports.iter().find(|p| p.id == id).unwrap();
            let iv = Interval::from_center(place.s_um, port.width_um);
            assert!(iv.start >= rear.s_min && iv.end <= rear.s_max, "{id}");
            assert!(!place.pinned);
        }
        let slot = design.placements.iter().find(|p| p.id == "slot0").unwrap();
        assert!(slot.pinned);
    }

    #[test]
    fn a_nudge_off_the_window_keeps_the_previous_design() {
        let design = Design::mini_itx().unwrap();
        let result = preview(
            &design,
            &Gesture::Nudge {
                id: "hdmi0".into(),
                delta_um: 500_000,
            },
        );
        assert!(!result.applied);
        assert_eq!(result.design, design);
        assert!(result.reason.unwrap().contains("outside"));
    }

    #[test]
    fn a_one_millimetre_nudge_pins_the_jack_and_keeps_it_legal() {
        let design = Design::mini_itx().unwrap();
        let before = design.placements.iter().find(|p| p.id == "usb0").unwrap().s_um;
        let result = preview(
            &design,
            &Gesture::Nudge {
                id: "usb0".into(),
                delta_um: 1_000,
            },
        );
        assert!(result.applied, "{:?}", result.reason);
        let usb = result.design.placements.iter().find(|p| p.id == "usb0").unwrap();
        assert!(usb.pinned);
        assert_eq!(usb.s_um, before + 1_000);
    }

    #[test]
    fn copy_adds_a_jack_and_a_rejected_copy_does_not_grow_the_board() {
        let design = Design::mini_itx().unwrap();
        let copied = preview(&design, &Gesture::Copy { id: "lan0".into() });
        assert!(copied.applied, "{:?}", copied.reason);
        assert_eq!(
            copied.design.ports.iter().filter(|p| p.role == "gbe_magjack").count(),
            2
        );
        let mut current = copied.design;
        loop {
            let next = preview(&current, &Gesture::Copy { id: "lan0".into() });
            if !next.applied {
                assert_eq!(next.design.ports.len(), current.ports.len());
                break;
            }
            current = next.design;
        }
    }

    #[test]
    fn delete_hdmi0_keeps_the_rear_pack_legal() {
        let design = Design::mini_itx().unwrap();
        let result = preview(&design, &Gesture::Delete { id: "hdmi0".into() });
        assert!(result.applied, "{:?}", result.reason);
        assert!(result.design.ports.iter().all(|p| p.id != "hdmi0"));
        let template = result.design.template().unwrap();
        let rear = template.edges.iter().find(|e| e.id == "rear_io").unwrap();
        for id in ["usb0", "usb1", "lan0"] {
            let place = result.design.placements.iter().find(|p| p.id == id).unwrap();
            let port = result.design.ports.iter().find(|p| p.id == id).unwrap();
            let iv = Interval::from_center(place.s_um, port.width_um);
            assert!(iv.start >= rear.s_min && iv.end <= rear.s_max, "{id}");
        }
    }

    #[test]
    fn delete_usb0_does_not_invent_esd_usb0_on_compile() {
        let design = Design::mini_itx().unwrap();
        let result = preview(&design, &Gesture::Delete { id: "usb0".into() });
        assert!(result.applied, "{:?}", result.reason);
        let bundle = compile(&result.design).unwrap();
        let ports = bundle.design["ports"].as_array().unwrap();
        assert!(ports.iter().all(|p| p["id"] != "esd_usb0"));
        assert!(ports.iter().any(|p| p["id"] == "esd_usb1"));
        assert!(ports.iter().all(|p| p["id"] != "usb0"));
    }

    #[test]
    fn delete_socket_keeps_the_pack_and_zero_socket_pins() {
        let design = Design::mini_itx().unwrap();
        let result = preview(&design, &Gesture::Delete { id: "socket".into() });
        assert!(result.applied, "{:?}", result.reason);
        assert!(result.design.ports.iter().all(|p| p.role != "socket"));
        assert!(pins_for("socket", "socket").is_empty());
        let bodies = scene(&result.design).unwrap();
        assert!(bodies.iter().all(|b| b.role != "socket"));
        compile(&result.design).unwrap();
    }

    #[test]
    fn place_pinning_usb0_reflows_unpinned_hdmi0() {
        let design = Design::mini_itx().unwrap();
        let before = design.placements.iter().find(|p| p.id == "hdmi0").unwrap().s_um;
        let usb = scene(&design).unwrap().into_iter().find(|b| b.id == "usb0").unwrap();
        let result = preview(
            &design,
            &Gesture::Place {
                id: "usb0".into(),
                x_um: 100_000,
                y_um: usb.y_um,
            },
        );
        assert!(result.applied, "{:?}", result.reason);
        let usb = result.design.placements.iter().find(|p| p.id == "usb0").unwrap();
        assert!(usb.pinned);
        assert_eq!(usb.s_um, 100_000);
        let hdmi = result.design.placements.iter().find(|p| p.id == "hdmi0").unwrap();
        assert!(!hdmi.pinned);
        assert_ne!(hdmi.s_um, before);
    }

    #[test]
    fn place_snaps_within_five_hundred_micrometres() {
        let design = Design::mini_itx().unwrap();
        let usb = scene(&design).unwrap().into_iter().find(|b| b.id == "usb0").unwrap();
        let result = preview(
            &design,
            &Gesture::Place {
                id: "usb0".into(),
                x_um: usb.x_um + 200,
                y_um: usb.y_um,
            },
        );
        assert!(result.applied, "{:?}", result.reason);
        let placed = result.design.placements.iter().find(|p| p.id == "usb0").unwrap();
        assert!(placed.pinned);
        assert_eq!(placed.s_um, usb.x_um);
    }

    #[test]
    fn place_keeps_both_board_plane_axes() {
        let design = Design::mini_itx().unwrap();
        let usb = scene(&design).unwrap().into_iter().find(|b| b.id == "usb0").unwrap();
        let y = usb.y_um - 8_000;
        let result = preview(
            &design,
            &Gesture::Place {
                id: "usb0".into(),
                x_um: usb.x_um,
                y_um: y,
            },
        );
        assert!(result.applied, "{:?}", result.reason);
        let place = result.design.placements.iter().find(|p| p.id == "usb0").unwrap();
        assert_eq!(place.x_um, Some(usb.x_um));
        assert_eq!(place.y_um, Some(y));
        let body = scene(&result.design).unwrap().into_iter().find(|b| b.id == "usb0").unwrap();
        assert_eq!(body.x_um, usb.x_um);
        assert_eq!(body.y_um, y);
        assert_eq!(body.z_um, usb.z_um);
    }

    #[test]
    fn turn_rotates_a_quarter_turn_around_z() {
        let design = Design::mini_itx().unwrap();
        let result = preview(&design, &Gesture::Turn { id: "usb0".into() });
        assert!(result.applied, "{:?}", result.reason);
        let place = result.design.placements.iter().find(|p| p.id == "usb0").unwrap();
        assert_eq!(place.yaw_q, 1);
        assert!(place.pinned);
        let body = scene(&result.design).unwrap().into_iter().find(|b| b.id == "usb0").unwrap();
        assert_eq!(body.yaw_q, 1);
        assert_eq!(body.z_um, scene(&design).unwrap().into_iter().find(|b| b.id == "usb0").unwrap().z_um);
    }

    #[test]
    fn an_illegal_place_keeps_the_previous_design() {
        let design = Design::mini_itx().unwrap();
        let result = preview(
            &design,
            &Gesture::Place {
                id: "usb0".into(),
                x_um: 500_000,
                y_um: 500_000,
            },
        );
        assert!(!result.applied);
        assert_eq!(result.design, design);
    }

    #[test]
    fn set_property_on_usb0_and_socket_cannot_add_pins() {
        let design = Design::mini_itx().unwrap();
        for id in ["usb0", "socket"] {
            let result = preview(
                &design,
                &Gesture::SetProperty {
                    id: id.into(),
                    key: "package_id".into(),
                    value: "g6lc64_ai".into(),
                },
            );
            assert!(result.applied, "{id} {:?}", result.reason);
            let port = result.design.ports.iter().find(|p| p.id == id).unwrap();
            assert!(pins_for(&port.id, &port.role).is_empty(), "{id}");
        }
    }

    #[test]
    fn unknown_package_id_keeps_the_previous_design() {
        let design = Design::mini_itx().unwrap();
        let result = preview(
            &design,
            &Gesture::SetProperty {
                id: "socket".into(),
                key: "package_id".into(),
                value: "not-a-package".into(),
            },
        );
        assert!(!result.applied);
        assert_eq!(result.design, design);
        assert!(result.reason.unwrap().contains("unknown package"));
        assert!(pins_for("socket", "socket").is_empty());
    }

    #[test]
    fn interface_combo_is_the_role_only() {
        let design = Design::mini_itx().unwrap();
        let same = preview(
            &design,
            &Gesture::SetProperty {
                id: "usb0".into(),
                key: "interface".into(),
                value: "usb_stack".into(),
            },
        );
        assert!(same.applied, "{:?}", same.reason);
        assert!(pins_for("usb0", "usb_stack").is_empty());
        let other = preview(
            &design,
            &Gesture::SetProperty {
                id: "usb0".into(),
                key: "interface".into(),
                value: "hdmi".into(),
            },
        );
        assert!(!other.applied);
        assert_eq!(other.design, design);
    }

    #[test]
    fn domain_and_radio_are_not_writable() {
        let design = Design::mini_itx().unwrap();
        for key in ["domain", "radio", "support"] {
            let result = preview(
                &design,
                &Gesture::SetProperty {
                    id: "usb0".into(),
                    key: key.into(),
                    value: "wifi".into(),
                },
            );
            assert!(!result.applied, "{key}");
            assert_eq!(result.design, design);
            assert!(result.reason.unwrap().contains("not writable"));
        }
    }

    #[test]
    fn firmware_witness_fields_do_not_invent_csrs() {
        let design = Design::mini_itx().unwrap();
        assert_eq!(design.settings.hotkey, "DEL");
        assert_eq!(design.settings.timeout_ms, 2_000);
        assert_eq!(design.settings.product, "desktop");
        let hot = preview(
            &design,
            &Gesture::SetProperty {
                id: "socket".into(),
                key: "hotkey".into(),
                value: "F2".into(),
            },
        );
        assert!(hot.applied, "{:?}", hot.reason);
        assert_eq!(hot.design.settings.hotkey, "F2");
        assert!(pins_for("socket", "socket").is_empty());
        let time = preview(
            &hot.design,
            &Gesture::SetProperty {
                id: "socket".into(),
                key: "timeout_ms".into(),
                value: "5000".into(),
            },
        );
        assert!(time.applied, "{:?}", time.reason);
        assert_eq!(time.design.settings.timeout_ms, 5_000);
        let prod = preview(
            &time.design,
            &Gesture::SetProperty {
                id: "socket".into(),
                key: "product".into(),
                value: "workstation".into(),
            },
        );
        assert!(prod.applied, "{:?}", prod.reason);
        let bundle = compile(&prod.design).unwrap();
        assert_eq!(bundle.firmware["entry"]["hotkey"], "F2");
        assert_eq!(bundle.firmware["entry"]["timeout_ms"], 5_000);
        assert_eq!(bundle.firmware["product"], "workstation");
        assert_eq!(bundle.firmware["memory"]["dram_base"], "0x80000000");
        assert!(bundle.firmware["peripherals"]
            .as_array()
            .unwrap()
            .iter()
            .all(|p| p["base"] == ""));
        let bad = preview(
            &design,
            &Gesture::SetProperty {
                id: "socket".into(),
                key: "timeout_ms".into(),
                value: "-1".into(),
            },
        );
        assert!(!bad.applied);
        assert_eq!(bad.design, design);
    }

    #[test]
    fn unknown_gesture_keeps_the_previous_design() {
        let design = Design::mini_itx().unwrap();
        let gesture: Gesture = serde_json::from_str(r#"{"op":"teleport"}"#).unwrap();
        assert_eq!(gesture, Gesture::Unknown);
        let result = preview(&design, &gesture);
        assert!(!result.applied);
        assert_eq!(result.design, design);
        assert_eq!(result.reason.as_deref(), Some("unknown gesture"));
    }

    #[test]
    fn set_outline_to_atx_keeps_usb_and_grows_the_board() {
        let design = Design::mini_itx().unwrap();
        let result = preview(
            &design,
            &Gesture::SetOutline {
                template_id: "atx".into(),
            },
        );
        assert!(result.applied, "{:?}", result.reason);
        assert_eq!(result.design.template_id, "atx");
        assert_eq!(result.design.template().unwrap().board_w_um, 305_000);
        assert!(result.design.ports.iter().any(|p| p.id == "usb0"));
        assert!(result.design.ports.iter().any(|p| p.role == "pcie_slot"));
        assert_eq!(crate::pins_for("slot0", "pcie_slot").len(), 164);
    }

    #[test]
    fn set_outline_to_pcie_card_uses_cem_and_drops_the_socket() {
        let design = Design::mini_itx().unwrap();
        let result = preview(
            &design,
            &Gesture::SetOutline {
                template_id: "pcie-card".into(),
            },
        );
        assert!(result.applied, "{:?}", result.reason);
        assert_eq!(result.design.template_id, "pcie-card");
        assert!(result.design.ports.iter().any(|p| p.role == "pcie_cem"));
        assert!(result.design.ports.iter().all(|p| p.role != "socket"));
        assert!(result.design.ports.iter().all(|p| p.role != "usb_stack"));
        assert!(crate::pins_for("usb0", "usb_stack").is_empty());
    }

    #[test]
    fn set_outline_unknown_keeps_the_previous_design() {
        let design = Design::mini_itx().unwrap();
        let result = preview(
            &design,
            &Gesture::SetOutline {
                template_id: "virt-ai-pcie".into(),
            },
        );
        assert!(!result.applied);
        assert_eq!(result.design, design);
    }

    #[test]
    fn auto_connect_does_not_write_nets_on_the_design() {
        let design = Design::mini_itx().unwrap();
        let result = preview(
            &design,
            &Gesture::AutoConnect {
                id: "slot0".into(),
            },
        );
        assert!(result.applied, "{:?}", result.reason);
        assert_eq!(result.design, design);
        assert!(auto_connect(&result.design).iter().any(|n| n.id == "P12V"));
    }
}
