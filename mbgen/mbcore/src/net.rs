//! Pin, net, and path types. Membership is keyed by **role**, never by
//! `template.id`. Pad XY is absent until a frozen footprint exists.

use serde::{Deserialize, Serialize};

use crate::scene::scene;
use crate::template::Design;

/// Distributor LCSCs already recorded in `corev-mb/lib/interfaces.py`
/// `_KIND_DISTRIBUTOR`. Names stay empty until `mbcore/data` freeze files exist.
const LCSC_PCIE_SLOT: &str = "C426228";
const LCSC_SATA: &str = "C7500843";
const LCSC_DIMM: &str = "C5889263";
const LCSC_NVME: &str = "C52766533";
const LCSC_FRONT_PANEL: &str = "C492422";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PinKind {
    Power,
    Ground,
    Signal,
    Clock,
    Analog,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PinSide {
    Top,
    Bottom,
    Through,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PathHitKind {
    Trace,
    Via,
    Solder,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pin {
    pub id: String,
    pub part: String,
    pub index: u32,
    pub name: String,
    pub kind: PinKind,
    pub domain: String,
    pub side: PinSide,
    pub dx_um: Option<i64>,
    pub dy_um: Option<i64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum NetClass {
    Power,
    Ground,
    Signal,
    Clock,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Net {
    pub id: String,
    pub pins: Vec<String>,
    pub class: NetClass,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hit {
    pub x_um: i64,
    pub y_um: i64,
    pub layer: u8,
    pub kind: PathHitKind,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Path {
    pub net: String,
    pub hits: Vec<Hit>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum AnchorKind {
    EdgeS,
    Courtyard,
    PinPad,
    ViaHit,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Anchor {
    pub part: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pin: Option<String>,
    pub x_um: i64,
    pub y_um: i64,
    pub z_um: i64,
    pub kind: AnchorKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum NetErrorKind {
    OpenRequired,
    DomainClash,
    Courtyard,
    Unroutable,
    GapRole,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetError {
    pub kind: NetErrorKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pin: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub net: Option<String>,
    pub reason: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PinProto {
    pub number: String,
    pub name: String,
    pub dx_um: Option<i64>,
    pub dy_um: Option<i64>,
    pub side: PinSide,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PinSpec {
    Gap,
    UnnamedGrid,
    NamesOnly { lcsc: String, pins: Vec<PinProto> },
    Footprint { lcsc: String, pins: Vec<PinProto> },
    Catalog { mpn: String },
}

/// Pin spec for a role. Independent of which `Template` the design uses.
pub fn pin_spec(role: &str) -> PinSpec {
    match role {
        "usb_stack" | "esd" | "dp" | "wifi_m2" | "usb_c" => PinSpec::Gap,
        "socket" => PinSpec::UnnamedGrid,
        "hdmi" | "gbe_magjack" | "phy_gbe" | "spi_flash" | "crystal" | "decap" | "vtt" => {
            PinSpec::Catalog { mpn: String::new() }
        }
        "pcie_slot" => names_only(LCSC_PCIE_SLOT, freeze_pins("pcie_slot")),
        "pcie_cem" => names_only("", Vec::new()),
        "sata" => names_only(LCSC_SATA, freeze_pins("sata")),
        "dimm" | "sodimm" => names_only(LCSC_DIMM, freeze_pins("dimm")),
        "nvme_m2" => names_only(LCSC_NVME, freeze_pins("nvme_m2")),
        "front_panel" => names_only(LCSC_FRONT_PANEL, freeze_pins("front_panel")),
        _ => PinSpec::Gap,
    }
}

fn names_only(lcsc: &str, pins: Vec<PinProto>) -> PinSpec {
    PinSpec::NamesOnly {
        lcsc: lcsc.into(),
        pins,
    }
}

#[derive(Deserialize)]
struct FreezeFile {
    pins: Vec<FreezePin>,
}

#[derive(Deserialize)]
struct FreezePin {
    number: String,
    name: String,
}

fn freeze_pins(role: &str) -> Vec<PinProto> {
    let text = match role {
        "pcie_slot" => include_str!("../data/pcie_slot.json"),
        "sata" => include_str!("../data/sata.json"),
        "front_panel" => include_str!("../data/front_panel.json"),
        _ => return Vec::new(),
    };
    let Ok(file) = serde_json::from_str::<FreezeFile>(text) else {
        return Vec::new();
    };
    file.pins
        .into_iter()
        .map(|p| PinProto {
            number: p.number,
            name: p.name,
            dx_um: None,
            dy_um: None,
            side: PinSide::Through,
        })
        .collect()
}

/// CEM rails already tied in `interfaces.py` `_tie_pcie_slot_power`.
fn cem_rail(name: &str) -> Option<&'static str> {
    match name {
        "P12V" | "B1" | "B2" | "B3" | "A2" | "A3" => Some("P12V"),
        "P3V3" | "B8" | "A9" | "A10" => Some("P3V3"),
        "P3V3_AUX" | "B10" => Some("P3V3_AUX"),
        "GND" | "B4" | "A4" | "B7" | "A12" | "B13" | "A15" | "B16" | "B18" | "A18" => Some("GND"),
        _ => None,
    }
}

fn net_key(role: &str, name: &str) -> Option<(&'static str, NetClass)> {
    match role {
        "pcie_slot" | "pcie_cem" => cem_rail(name).map(|rail| {
            let class = if rail == "GND" {
                NetClass::Ground
            } else {
                NetClass::Power
            };
            (rail, class)
        }),
        "sata" if name == "1" => Some(("1", NetClass::Ground)),
        "sata" if name == "4" => Some(("4", NetClass::Ground)),
        "sata" if name == "7" => Some(("7", NetClass::Ground)),
        _ => None,
    }
}

/// Instantiated pins for a placed part. Empty until freeze files exist.
pub fn pins_for(part_id: &str, role: &str) -> Vec<Pin> {
    match pin_spec(role) {
        PinSpec::NamesOnly { pins, .. } | PinSpec::Footprint { pins, .. } => pins
            .iter()
            .enumerate()
            .map(|(i, proto)| pin_from_proto(part_id, i as u32, proto, role))
            .collect(),
        PinSpec::Gap | PinSpec::UnnamedGrid | PinSpec::Catalog { .. } => Vec::new(),
    }
}

fn pin_from_proto(part: &str, index: u32, proto: &PinProto, role: &str) -> Pin {
    let (kind, domain) = kind_domain(role, &proto.name);
    Pin {
        id: format!("{part}.{}", proto.number),
        part: part.into(),
        index,
        name: proto.name.clone(),
        kind,
        domain,
        side: proto.side,
        dx_um: proto.dx_um,
        dy_um: proto.dy_um,
    }
}

fn kind_domain(role: &str, name: &str) -> (PinKind, String) {
    if let Some((net, class)) = net_key(role, name) {
        let kind = match class {
            NetClass::Ground => PinKind::Ground,
            NetClass::Power => PinKind::Power,
            NetClass::Clock => PinKind::Clock,
            NetClass::Signal => PinKind::Signal,
        };
        return (kind, net.to_string());
    }
    (PinKind::Signal, name.into())
}

/// CEM / SATA names already tied in `interfaces.py`. Empty for DIMM / NVMe / FP.
pub fn contracts_for(role: &str, names: &[String]) -> Vec<String> {
    let wanted: &[&str] = match role {
        "pcie_slot" | "pcie_cem" => &["P12V", "P3V3", "P3V3_AUX", "GND"],
        "sata" => &["1", "4", "7"],
        _ => &[],
    };
    wanted
        .iter()
        .filter(|rail| {
            names.iter().any(|have| {
                have == *rail || net_key(role, have).map(|(n, _)| n) == Some(**rail)
            })
        })
        .map(|n| (*n).to_string())
        .collect()
}

/// CEM / SATA contract names only. Does not write `Design`. Empty until freeze.
pub fn auto_connect(design: &Design) -> Vec<Net> {
    connect_by_contract(
        design
            .ports
            .iter()
            .map(|p| (p.id.as_str(), p.role.as_str(), pins_for(&p.id, &p.role))),
    )
}

fn connect_by_contract<'a>(
    parts: impl IntoIterator<Item = (&'a str, &'a str, Vec<Pin>)>,
) -> Vec<Net> {
    use std::collections::BTreeMap;
    let mut pins_by_net: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut class_by_net: BTreeMap<String, NetClass> = BTreeMap::new();
    for (_part, role, pins) in parts {
        for pin in pins {
            let Some((net, class)) = net_key(role, &pin.name) else {
                continue;
            };
            pins_by_net
                .entry(net.to_string())
                .or_default()
                .push(pin.id.clone());
            class_by_net.entry(net.to_string()).or_insert(class);
        }
    }
    pins_by_net
        .into_iter()
        .map(|(id, pins)| Net {
            class: class_by_net.get(&id).copied().unwrap_or(NetClass::Signal),
            id,
            pins,
        })
        .collect()
}

/// Derived snap targets. No `ViaHit` until a path exists.
pub fn anchors(design: &Design) -> Vec<Anchor> {
    let Ok(bodies) = scene(design) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for body in &bodies {
        if body.id == "pcb" || body.id == "shield" {
            continue;
        }
        out.push(Anchor {
            part: body.id.clone(),
            pin: None,
            x_um: body.x_um,
            y_um: body.y_um,
            z_um: body.z_um,
            kind: AnchorKind::EdgeS,
        });
        let hx = body.sx_um / 2;
        let hy = body.sy_um / 2;
        for (x_um, y_um) in [
            (body.x_um - hx, body.y_um - hy),
            (body.x_um + hx, body.y_um - hy),
            (body.x_um - hx, body.y_um + hy),
            (body.x_um + hx, body.y_um + hy),
        ] {
            out.push(Anchor {
                part: body.id.clone(),
                pin: None,
                x_um,
                y_um,
                z_um: body.z_um,
                kind: AnchorKind::Courtyard,
            });
        }
        let Some(port) = design.ports.iter().find(|p| p.id == body.id) else {
            continue;
        };
        for pin in pins_for(&port.id, &port.role) {
            let (Some(dx), Some(dy)) = (pin.dx_um, pin.dy_um) else {
                continue;
            };
            out.push(Anchor {
                part: body.id.clone(),
                pin: Some(pin.id),
                x_um: body.x_um + dx,
                y_um: body.y_um + dy,
                z_um: 1_600,
                kind: AnchorKind::PinPad,
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::template::Design;

    #[test]
    fn net_error_omits_null_pin_and_net() {
        let err = NetError {
            kind: NetErrorKind::GapRole,
            pin: None,
            net: None,
            reason: "gap".into(),
        };
        let json = serde_json::to_string(&err).unwrap();
        assert!(!json.contains("\"pin\""));
        assert!(!json.contains("\"net\""));
        assert!(json.contains("\"kind\":\"GapRole\""));
    }

    fn zero_pin_roles() -> &'static [&'static str] {
        &[
            "usb_stack",
            "esd",
            "dp",
            "wifi_m2",
            "usb_c",
            "socket",
            "hdmi",
            "gbe_magjack",
            "phy_gbe",
            "spi_flash",
            "crystal",
            "decap",
            "vtt",
        ]
    }

    #[test]
    fn gap_and_unnamed_roles_have_zero_pins() {
        for role in zero_pin_roles() {
            assert!(
                pins_for("x", role).is_empty(),
                "{role} must not invent pins"
            );
        }
        assert!(matches!(pin_spec("socket"), PinSpec::UnnamedGrid));
        assert!(matches!(pin_spec("usb_stack"), PinSpec::Gap));
        assert!(matches!(pin_spec("usb_c"), PinSpec::Gap));
    }

    #[test]
    fn distributor_kinds_are_names_only_and_missing_freeze_stays_empty() {
        for role in ["pcie_slot", "sata", "dimm", "nvme_m2", "front_panel", "pcie_cem"] {
            assert!(
                matches!(pin_spec(role), PinSpec::NamesOnly { .. }),
                "{role}"
            );
        }
        assert_eq!(pins_for("slot0", "pcie_slot").len(), 164);
        assert_eq!(pins_for("sata0", "sata").len(), 9);
        assert_eq!(pins_for("fp0", "front_panel").len(), 10);
        assert!(pins_for("mem0", "dimm").is_empty());
        assert!(pins_for("nvme0", "nvme_m2").is_empty());
        assert!(pins_for("cem0", "pcie_cem").is_empty());
        match pin_spec("pcie_slot") {
            PinSpec::NamesOnly { lcsc, .. } => assert_eq!(lcsc, LCSC_PCIE_SLOT),
            _ => panic!("slot lcsc"),
        }
        match pin_spec("pcie_cem") {
            PinSpec::NamesOnly { lcsc, .. } => assert!(lcsc.is_empty(), "card-edge is not the slot MPN"),
            _ => panic!("cem"),
        }
    }

    #[test]
    fn frozen_names_have_no_pad_xy_and_match_jlc() {
        let pins = pins_for("slot0", "pcie_slot");
        assert_eq!(pins[0].name, "A1");
        assert_eq!(pins[1].name, "A2");
        assert!(pins.iter().all(|p| p.dx_um.is_none() && p.dy_um.is_none()));
        let a1 = pins.iter().find(|p| p.name == "A1").unwrap();
        assert_eq!(a1.kind, PinKind::Signal);
        assert_eq!(a1.domain, "A1");
        let a2 = pins.iter().find(|p| p.name == "A2").unwrap();
        assert_eq!(a2.kind, PinKind::Power);
        assert_eq!(a2.domain, "P12V");
        let b4 = pins.iter().find(|p| p.name == "B4").unwrap();
        assert_eq!(b4.kind, PinKind::Ground);
        assert_eq!(b4.domain, "GND");
        let fp = pins_for("fp0", "front_panel");
        assert!(fp.iter().all(|p| p.kind == PinKind::Signal));
        assert!(fp.iter().any(|p| p.name == "1"));
    }

    #[test]
    fn contracts_are_cem_and_sata_only() {
        let names = vec![
            "P12V".into(),
            "GND".into(),
            "VDD".into(),
            "1".into(),
            "4".into(),
            "A1".into(),
        ];
        assert_eq!(
            contracts_for("pcie_slot", &["A2".into(), "B4".into(), "A1".into(), "VDD".into()]),
            vec!["P12V".to_string(), "GND".to_string()]
        );
        assert_eq!(
            contracts_for("pcie_slot", &names),
            vec!["P12V".to_string(), "GND".to_string()]
        );
        assert_eq!(
            contracts_for("pcie_cem", &names),
            vec!["P12V".to_string(), "GND".to_string()]
        );
        assert_eq!(
            contracts_for("sata", &names),
            vec!["1".to_string(), "4".to_string()]
        );
        assert!(contracts_for("dimm", &names).is_empty());
        assert!(contracts_for("nvme_m2", &names).is_empty());
        assert!(contracts_for("front_panel", &names).is_empty());
        assert!(contracts_for("usb_stack", &names).is_empty());
        assert!(contracts_for("socket", &names).is_empty());
    }

    #[test]
    fn pin_membership_ignores_template_id() {
        let itx = Design::from_template("mini-itx").unwrap();
        let atx = Design::from_template("atx").unwrap();
        let slot_itx = itx.ports.iter().find(|p| p.role == "pcie_slot").unwrap();
        let slot_atx = atx.ports.iter().find(|p| p.role == "pcie_slot").unwrap();
        assert_eq!(
            pins_for(&slot_itx.id, &slot_itx.role),
            pins_for(&slot_atx.id, &slot_atx.role)
        );
        assert_eq!(
            contracts_for(&slot_itx.role, &[]),
            contracts_for(&slot_atx.role, &[])
        );
        assert_ne!(itx.template_id, atx.template_id);
    }

    #[test]
    fn usb0_anchors_are_edge_and_courtyard_without_pads() {
        let design = Design::mini_itx().unwrap();
        let marks: Vec<_> = anchors(&design)
            .into_iter()
            .filter(|a| a.part == "usb0")
            .collect();
        assert!(marks.iter().any(|a| a.kind == AnchorKind::EdgeS));
        assert_eq!(
            marks.iter().filter(|a| a.kind == AnchorKind::Courtyard).count(),
            4
        );
        assert!(marks.iter().all(|a| a.kind != AnchorKind::PinPad));
    }

    #[test]
    fn pcie_card_outline_uses_cem_role_with_empty_pins() {
        let card = Design::from_template("pcie-card").unwrap();
        assert_eq!(card.template_id, "pcie-card");
        let t = card.template().unwrap();
        assert_eq!(t.board_w_um, 167_650);
        assert_eq!(t.board_d_um, 68_900);
        assert!(t.edges.iter().any(|e| e.id == "cem"));
        let cem = card.ports.iter().find(|p| p.role == "pcie_cem").unwrap();
        assert!(pins_for(&cem.id, &cem.role).is_empty());
        assert!(card.ports.iter().all(|p| p.role != "socket"));
        assert!(card.ports.iter().all(|p| p.role != "usb_stack"));
    }

    #[test]
    fn auto_connect_ties_cem_and_sata_only_and_ignores_template_id() {
        let itx = Design::from_template("mini-itx").unwrap();
        let atx = Design::from_template("atx").unwrap();
        let nets = auto_connect(&itx);
        assert_eq!(auto_connect(&itx), auto_connect(&atx));
        let ids: Vec<_> = nets.iter().map(|n| n.id.as_str()).collect();
        assert!(ids.contains(&"P12V"));
        assert!(ids.contains(&"P3V3"));
        assert!(ids.contains(&"P3V3_AUX"));
        assert!(ids.contains(&"GND"));
        assert!(ids.contains(&"1"));
        assert!(ids.contains(&"4"));
        assert!(ids.contains(&"7"));
        let p12 = nets.iter().find(|n| n.id == "P12V").unwrap();
        assert_eq!(p12.class, NetClass::Power);
        assert!(p12.pins.iter().any(|p| p.starts_with("slot0.")));
        assert!(nets.iter().all(|n| n.id != "VDD" && n.id != "VTT" && n.id != "VBUS"));
        assert!(pins_for("usb0", "usb_stack").is_empty());
        assert!(auto_connect(&Design::from_template("pcie-card").unwrap()).is_empty());
    }

    fn pin(part: &str, name: &str, kind: PinKind) -> Pin {
        Pin {
            id: format!("{part}.{name}"),
            part: part.into(),
            index: 0,
            name: name.into(),
            kind,
            domain: name.into(),
            side: PinSide::Top,
            dx_um: None,
            dy_um: None,
        }
    }

    #[test]
    fn auto_connect_unions_cem_and_sata_contract_names_only() {
        let nets = connect_by_contract([
            (
                "slot0",
                "pcie_slot",
                vec![
                    pin("slot0", "P12V", PinKind::Power),
                    pin("slot0", "GND", PinKind::Ground),
                    pin("slot0", "A1", PinKind::Signal),
                ],
            ),
            (
                "cem0",
                "pcie_cem",
                vec![
                    pin("cem0", "P12V", PinKind::Power),
                    pin("cem0", "GND", PinKind::Ground),
                ],
            ),
            (
                "mem0",
                "dimm",
                vec![
                    pin("mem0", "GND", PinKind::Signal),
                    pin("mem0", "VDD", PinKind::Signal),
                ],
            ),
            (
                "sata0",
                "sata",
                vec![
                    pin("sata0", "1", PinKind::Ground),
                    pin("sata0", "4", PinKind::Ground),
                    pin("sata0", "A1", PinKind::Signal),
                ],
            ),
            (
                "usb0",
                "usb_stack",
                vec![pin("usb0", "VBUS", PinKind::Power)],
            ),
        ]);
        let net = |id: &str| nets.iter().find(|n| n.id == id).unwrap();
        assert_eq!(net("P12V").pins, vec!["slot0.P12V", "cem0.P12V"]);
        assert_eq!(net("P12V").class, NetClass::Power);
        assert_eq!(net("GND").pins, vec!["slot0.GND", "cem0.GND"]);
        assert_eq!(net("GND").class, NetClass::Ground);
        assert_eq!(net("1").pins, vec!["sata0.1"]);
        assert_eq!(net("4").pins, vec!["sata0.4"]);
        assert!(nets.iter().all(|n| n.id != "A1" && n.id != "VDD" && n.id != "VBUS"));
    }
}
