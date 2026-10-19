//! Role library JSON for the Unreal palette. Distinct from `packages.json`.
//! Membership is keyed by role. Bluetooth is a label on `wifi_m2`.

use serde::Serialize;

use crate::catalog::{domain_for, library_for, Support};
use crate::net::{contracts_for, pin_spec, pins_for};
use crate::template::roles;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct LibraryEntry {
    pub id: String,
    pub role: String,
    pub support: String,
    pub domain: String,
    pub edge: String,
    pub width_um: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vendor_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub license: Option<String>,
    pub note: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mpn: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lcsc: Option<String>,
    pub pin_spec: String,
    pub hatch: bool,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub labels: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub contracts: Vec<String>,
}

/// Palette rows. `ai_island` is Gap here; an AI package paints it Integrated.
pub fn library_export() -> Vec<LibraryEntry> {
    roles()
        .iter()
        .map(|role| {
            let row = library_for(role.id, false);
            let spec = pin_spec(role.id);
            let (pin_kind, mpn, lcsc) = match spec {
                crate::net::PinSpec::Gap => ("gap", None, None),
                crate::net::PinSpec::UnnamedGrid => ("unnamed_grid", None, None),
                crate::net::PinSpec::NamesOnly { lcsc, .. } => (
                    "names_only",
                    None,
                    nonempty(lcsc),
                ),
                crate::net::PinSpec::Footprint { lcsc, .. } => (
                    "footprint",
                    None,
                    nonempty(lcsc),
                ),
                crate::net::PinSpec::Catalog { mpn } => ("catalog", nonempty(mpn), None),
                crate::net::PinSpec::TwoTerminal => ("two_terminal", None, None),
            };
            let hatch = row.support == Support::Gap;
            let labels = if role.id == "wifi_m2" {
                vec!["radio: wifi".into()]
            } else {
                Vec::new()
            };
            let names: Vec<String> = pins_for(role.id, role.id).iter().map(|p| p.name.clone()).collect();
            let contracts = contracts_for(role.id, &names);
            LibraryEntry {
                id: role.id.into(),
                role: role.id.into(),
                support: row.support.as_str().into(),
                domain: domain_for(role.id).into(),
                edge: role.edge.into(),
                width_um: role.width_um,
                vendor_id: row.vendor_id.map(str::to_string),
                license: row.license.map(str::to_string),
                note: row.note.into(),
                mpn,
                lcsc,
                pin_spec: pin_kind.into(),
                hatch,
                labels,
                contracts,
            }
        })
        .collect()
}

fn nonempty(s: String) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::gesture::{preview, Gesture};
    use crate::net::pins_for;
    use crate::scene::scene;
    use crate::template::{role, Design, Port};

    #[test]
    fn usb_c_is_a_gap_absent_from_mini_itx() {
        assert!(role("usb_c").is_some());
        assert!(role("wifi_m2").is_some());
        assert!(role("bt_module").is_none());
        let design = Design::mini_itx().unwrap();
        assert!(design.ports.iter().all(|p| p.role != "usb_c"));
        assert!(design.ports.iter().all(|p| p.role != "wifi_m2"));
        assert!(pins_for("uc0", "usb_c").is_empty());
        assert!(pins_for("w0", "wifi_m2").is_empty());
    }

    #[test]
    fn library_export_hatches_usb_c_and_labels_wifi_radio() {
        let rows = library_export();
        assert!(rows.iter().all(|r| r.id != "bt_module"));
        let usb_c = rows.iter().find(|r| r.id == "usb_c").unwrap();
        assert_eq!(usb_c.support, "gap");
        assert!(usb_c.hatch);
        assert_eq!(usb_c.pin_spec, "gap");
        assert!(usb_c.mpn.is_none());
        assert!(usb_c.lcsc.is_none());
        assert!(usb_c.labels.is_empty());
        assert_eq!(usb_c.domain, "usb");
        let wifi = rows.iter().find(|r| r.id == "wifi_m2").unwrap();
        assert_eq!(wifi.support, "gap");
        assert!(wifi.hatch);
        assert_eq!(wifi.labels, vec!["radio: wifi".to_string()]);
        let slot = rows.iter().find(|r| r.id == "pcie_slot").unwrap();
        assert_eq!(slot.lcsc.as_deref(), Some("C426228"));
        assert!(!slot.hatch);
        assert!(slot.contracts.iter().any(|c| c == "P12V"));
        assert!(slot.contracts.iter().any(|c| c == "GND"));
        assert!(usb_c.contracts.is_empty());
        let cem = rows.iter().find(|r| r.id == "pcie_cem").unwrap();
        assert!(cem.lcsc.is_none());
        assert_eq!(cem.pin_spec, "names_only");
        assert!(rows.iter().any(|r| r.id == "usb_stack"));
        assert_eq!(rows.len(), crate::template::roles().len());
    }

    #[test]
    fn adding_usb_c_paints_a_hatch_and_invents_no_pins() {
        let design = Design::mini_itx().unwrap();
        let result = preview(
            &design,
            &Gesture::Add {
                role: "usb_c".into(),
            },
        );
        assert!(result.applied, "{:?}", result.reason);
        let port = result.design.ports.iter().find(|p| p.role == "usb_c").unwrap();
        assert!(pins_for(&port.id, &port.role).is_empty());
        let body = scene(&result.design)
            .unwrap()
            .into_iter()
            .find(|b| b.role == "usb_c")
            .unwrap();
        assert_eq!(body.material, "ghost");
        assert_eq!(body.support, "gap");
    }

    #[test]
    fn port_has_no_attrs_field() {
        let port = Port::new("usb0", "usb_stack", 15_000);
        let value = serde_json::to_value(&port).unwrap();
        assert!(value.get("attrs").is_none());
        // Optional component fields are omitted until set, so a v1 reader
        // sees exactly the three fields it knows.
        assert_eq!(value.as_object().unwrap().len(), 3);
    }
}
