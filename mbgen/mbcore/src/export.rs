//! Compile a legal preview into the backend bundle. Hidden parts are packed
//! with the same edge packer. Gap roles stay out of the firmware peripheral list.

use serde_json::{json, Value};

use crate::catalog::{domain_for, library_for, package, Support};
use crate::pack::PackError;
use crate::route::route;
use crate::scene::scene;
use crate::template::{role, Design, Placement, Port};

#[derive(Clone, Debug)]
pub struct Bundle {
    pub design: Value,
    pub platform: Value,
    pub firmware: Value,
    pub netlist: String,
    pub skidl_py: String,
    pub scene: Value,
    pub nets: Value,
    pub paths: Value,
    pub errors: Value,
}

pub fn compile(design: &Design) -> Result<Bundle, PackError> {
    let card = package(&design.settings.package_id).ok_or_else(|| PackError {
        reason: format!("unknown package {}", design.settings.package_id),
    })?;
    let mut built = design.clone();
    expand_hidden(&mut built)?;
    let bodies = scene(&built)?;
    let mut interfaces = Vec::new();
    let mut phys = Vec::new();
    let mut gaps = Vec::new();
    let mut requests: Vec<Value> = Vec::new();
    let mut peripherals = Vec::new();
    for port in &built.ports {
        let lib = library_for(&port.role, card.ai);
        interfaces.push(json!({
            "id": port.id,
            "domain": domain_for(&port.role),
            "kind": port.role,
            "count": 1,
            "controller": lib.vendor_id,
        }));
        phys.push(json!({
            "ref": port.id,
            "interface": port.role,
            "status": match lib.support {
                Support::Gap => "planned",
                Support::Listed => "documented",
                _ => "selected",
            },
            "mcp": { "tool": "jlc_search", "query": query(&port.role) },
        }));
        if lib.support == Support::Gap {
            gaps.push(json!({
                "role": port.role,
                "id": port.id,
                "defer": true,
                "note": lib.note,
            }));
        }
        if let Some(vendor) = lib.vendor_id {
            if !requests.iter().any(|r| r["id"] == vendor) {
                requests.push(json!({
                    "id": vendor,
                    "license": lib.license,
                    "enable": lib.support == Support::Integrated,
                    "note": lib.note,
                }));
            }
        }
        if matches!(lib.support, Support::Board | Support::Integrated | Support::Listed)
            && matches!(port.role.as_str(), "spi_flash" | "gbe_magjack" | "hdmi" | "sata" | "pcie_slot" | "nvme_m2" | "dimm" | "sodimm")
        {
            peripherals.push(json!({
                "id": port.id,
                "class": port.role,
                "model": lib.vendor_id.unwrap_or(""),
                "base": "",
            }));
        }
    }
    let routed = route(&built)?;
    let scene_json = serde_json::to_value(&bodies).map_err(|e| PackError { reason: e.to_string() })?;
    let design_json = serde_json::to_value(&built).map_err(|e| PackError { reason: e.to_string() })?;
    let nets_json = serde_json::to_value(&routed.nets).map_err(|e| PackError { reason: e.to_string() })?;
    let paths_json = serde_json::to_value(&routed.paths).map_err(|e| PackError { reason: e.to_string() })?;
    let errors_json = serde_json::to_value(&routed.errors).map_err(|e| PackError { reason: e.to_string() })?;
    let platform = json!({
        "boardid": built.template_id,
        "name": built.template_id,
        "vendor": "mbgen",
        "status": "custom",
        "class": "custom",
        "skidl": "custom",
        "core": {
            "config": card.id,
            "xlen": card.xlen,
            "extensions": isa_letters(card.isa),
            "isaString": card.isa,
            // Topology and provenance read from the config package, so `mb ingest`
            // can refuse a board whose numbers no longer match core/include.
            "harts": { "count": card.profile.harts, "cores": card.cores, "threads": card.threads },
            "source": { "path": card.profile.source.path, "sha256": card.profile.source.sha256 },
        },
        "apu": {
            "axiDataWidth": card.axi_bits,
            "noc": "axi4",
            "socket": { "enabled": true, "type": "lga" },
            "controllers": requests,
        },
        "interfaces": interfaces,
        "phys": phys,
        "gaps": gaps,
    });
    let firmware = json!({
        "schema_version": 1,
        "product": built.settings.product,
        "isa": isa_json(card),
        "memory": { "dram_base": "0x80000000", "dram_len": "0x40000000", "text_offset": "0x200000" },
        "harts": { "count": card.profile.harts, "cores": card.cores, "threads": card.threads },
        "source": { "config": card.id, "path": card.profile.source.path, "sha256": card.profile.source.sha256 },
        "entry": { "hotkey": built.settings.hotkey, "timeout_ms": built.settings.timeout_ms },
        "core": { "ooo": card.ooo },
        "connectors": { "uncore": ["uart", "spi"] },
        "peripherals": peripherals,
    });
    Ok(Bundle {
        design: design_json,
        platform,
        firmware,
        netlist: netlist(&built),
        skidl_py: skidl_py(&built),
        scene: scene_json,
        nets: nets_json,
        paths: paths_json,
        errors: errors_json,
    })
}

fn expand_hidden(design: &mut Design) -> Result<(), PackError> {
    let lans: Vec<_> = design.ports.iter().filter(|p| p.role == "gbe_magjack").map(|p| p.id.clone()).collect();
    let usbs: Vec<_> = design.ports.iter().filter(|p| p.role == "usb_stack").map(|p| p.id.clone()).collect();
    let mems = design.ports.iter().filter(|p| p.role == "dimm" || p.role == "sodimm").count();
    for id in lans {
        push(design, &format!("phy_{id}"), "phy_gbe")?;
        push(design, &format!("xtal_{id}"), "crystal")?;
    }
    for id in usbs {
        push(design, &format!("esd_{id}"), "esd")?;
    }
    if mems > 0 {
        push(design, "vtt0", "vtt")?;
    }
    let card = package(&design.settings.package_id);
    let ua = card.map(|c| c.core_ua).unwrap_or(250_000);
    let caps = ((ua + 99_999) / 100_000).clamp(2, 8);
    for i in 0..caps {
        push(design, &format!("c{i}"), "decap")?;
    }
    let template = design.template()?;
    design.repack(&template)
}

fn push(design: &mut Design, id: &str, role_id: &str) -> Result<(), PackError> {
    if design.ports.iter().any(|p| p.id == id) {
        return Ok(());
    }
    let role = role(role_id).ok_or_else(|| PackError { reason: format!("unknown role {role_id}") })?;
    let order = design.placements.iter().map(|p| p.order).max().unwrap_or(0) + 1;
    design.ports.push(Port { id: id.into(), role: role.id.into(), width_um: role.width_um });
    design.placements.push(Placement {
        id: id.into(),
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

/// Single-letter extension tokens after the `rv32`/`rv64` base.
fn isa_letters(isa: &str) -> Vec<String> {
    let body = isa.strip_prefix("rv64").or_else(|| isa.strip_prefix("rv32")).unwrap_or(isa);
    body.chars().filter(|c| c.is_ascii_alphabetic()).map(|c| c.to_string()).collect()
}

fn isa_json(card: &crate::catalog::PackageCard) -> Value {
    let body = card.isa.strip_prefix("rv64").or_else(|| card.isa.strip_prefix("rv32")).unwrap_or(card.isa);
    let mut extensions = serde_json::Map::new();
    for letter in body.chars().filter(|c| c.is_ascii_alphabetic()) {
        extensions.insert(letter.to_string(), json!("live"));
    }
    let mut isa = json!({
        "xlen": card.xlen,
        "march": card.isa,
        "extensions": extensions,
    });
    if let Some(mmu) = card.id.split('_').find(|part| matches!(*part, "sv32" | "sv39" | "sv48")) {
        isa["mmu"] = json!(mmu);
    }
    isa
}

fn query(role: &str) -> &'static str {
    match role {
        "usb_stack" => "stacked USB 3.0 type-A receptacle",
        "usb_c" => "USB Type-C receptacle",
        "gbe_magjack" => "1G RJ45 magjack",
        "hdmi" => "HDMI receptacle",
        "dp" => "DisplayPort receptacle",
        "dimm" => "DDR4 DIMM socket 288",
        "sodimm" => "DDR4 SODIMM socket",
        "sata" => "SATA 7-pin right angle",
        "nvme_m2" => "M.2 key M 2280 connector",
        "wifi_m2" => "M.2 key E 2230 connector",
        "rtc_battery" => "CR2032 battery holder",
        "spi_flash" => "WSON-8 SPI NOR flash",
        "dc_jack" => "DC barrel jack 5.5mm",
        "front_panel" => "2.54mm 2x5 pin header",
        "pcie_slot" => "PCIe x16 slot",
        "pcie_cem" => "PCIe card-edge CEM",
        _ => "electronic component",
    }
}

fn netlist(design: &Design) -> String {
    let mut out = String::from("(netlist\n");
    for (i, port) in design.ports.iter().enumerate() {
        out.push_str(&format!("  (comp (ref U{}) (value {}) (id {}))\n", i + 1, port.role, port.id));
    }
    out.push_str("  (net (name GND)\n");
    for (i, _) in design.ports.iter().enumerate() {
        out.push_str(&format!("    (node (ref U{}) (pin GND))\n", i + 1));
    }
    out.push_str("  )\n)\n");
    out
}

fn skidl_py(design: &Design) -> String {
    let mut out = String::from(
        "# Generated by mbgen. Parts and nets only. Footprints come from a pcbparts refresh.\nfrom skidl import Net, Part\n\ngnd = Net('GND')\nvdd = Net('VDD')\n",
    );
    for port in &design.ports {
        let lib = library_for(&port.role, false);
        out.push_str(&format!(
            "{id} = Part('Device', '{role}')  # {note}\n{id}['GND'] += gnd\n",
            id = port.id.replace('-', "_"),
            role = port.role,
            note = lib.note,
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::{apply_package, packages};
    use crate::scene::scene;
    use crate::template::Design;

    #[test]
    fn every_outline_packs() {
        for id in ["mini-itx", "matx", "atx", "pico-itx", "pcie-card"] {
            Design::from_template(id).unwrap_or_else(|e| panic!("{id}: {}", e.reason));
        }
    }

    #[test]
    fn compile_lists_libraries_and_defers_usb() {
        let design = Design::mini_itx().unwrap();
        let bundle = compile(&design).unwrap();
        let ids: Vec<_> = bundle.platform["apu"]["controllers"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["id"].as_str().unwrap().to_string())
            .collect();
        assert!(ids.contains(&"verilog-ethernet".into()));
        assert!(ids.contains(&"hdmi".into()));
        assert!(ids.contains(&"litedram".into()));
        assert!(ids.contains(&"verilog-pcie".into()));
        let gaps = bundle.platform["gaps"].as_array().unwrap();
        assert!(gaps.iter().any(|g| g["role"] == "usb_stack" && g["defer"] == true));
        let peripherals = bundle.firmware["peripherals"].as_array().unwrap();
        assert!(peripherals.iter().all(|p| p["class"] != "usb_stack"));
        assert!(peripherals.iter().any(|p| p["class"] == "spi_flash"));
        assert!(peripherals.iter().any(|p| p["class"] == "gbe_magjack" && p["model"] == "verilog-ethernet" && p["base"] == ""));
        assert!(peripherals.iter().any(|p| p["class"] == "hdmi"));
        assert!(peripherals.iter().any(|p| p["class"] == "sata"));
        assert!(peripherals.iter().any(|p| p["class"] == "pcie_slot" && p["base"] == ""));
        assert!(peripherals.iter().any(|p| p["class"] == "dimm" && p["model"] == "litedram" && p["base"] == ""));
        assert!(peripherals.iter().any(|p| p["class"] == "nvme_m2" && p["model"] == "verilog-pcie" && p["base"] == ""));
        assert!(bundle.errors.as_array().unwrap().is_empty());
        assert_eq!(bundle.firmware["entry"]["hotkey"], "DEL");
        assert_eq!(bundle.firmware["entry"]["timeout_ms"], 2000);
        assert_eq!(bundle.firmware["product"], "desktop");
        assert_eq!(bundle.firmware["isa"]["xlen"], 64);
        // The ISA string is read from the config package, not typed here.
        let baseline = crate::profile::profile("cv64a6_imafdc_sv39").unwrap();
        assert_eq!(bundle.firmware["isa"]["march"], baseline.isa);
        for letter in ["i", "m", "a", "f", "d", "c"] {
            assert!(baseline.isa.contains(letter), "{} lacks {letter}", baseline.isa);
        }
        assert_eq!(bundle.firmware["isa"]["mmu"], "sv39");
        assert_eq!(bundle.firmware["isa"]["extensions"]["d"], "live");
        let ooo = compile(&apply_package(&design, "g6lc64_ooo_int").unwrap()).unwrap();
        assert_eq!(ooo.firmware["isa"]["march"], crate::profile::profile("g6lc64_ooo_int").unwrap().isa);
        assert!(ooo.firmware["isa"].get("mmu").is_none());
        assert_eq!(ooo.firmware["core"]["ooo"], true);
        assert!(bundle.skidl_py.contains("Net('GND')"));
        assert!(bundle.scene.as_array().unwrap().iter().any(|b| b["id"] == "pcb"));
    }

    #[test]
    fn exported_hart_count_is_the_config_package_topology_with_provenance() {
        // The literal table used to say ooo_server = 4 harts; the RTL has 4 x 2.
        let design = apply_package(&Design::mini_itx().unwrap(), "g6lc64_ooo_server").unwrap();
        let bundle = compile(&design).unwrap();
        let p = crate::profile::profile("g6lc64_ooo_server").unwrap();
        assert_eq!((p.cores, p.threads), (4, 2));
        assert_eq!(bundle.firmware["harts"]["count"], 8);
        assert_eq!(bundle.firmware["harts"]["cores"], 4);
        assert_eq!(bundle.firmware["harts"]["threads"], 2);
        assert_eq!(bundle.platform["core"]["harts"]["count"], 8);
        assert_eq!(bundle.platform["core"]["config"], "g6lc64_ooo_server");
        assert_eq!(bundle.platform["core"]["source"]["path"], "core/include/g6lc64_ooo_server_config_pkg.sv");
        assert_eq!(bundle.platform["core"]["source"]["sha256"].as_str().unwrap().len(), 64);
        assert_eq!(bundle.firmware["source"]["sha256"], bundle.platform["core"]["source"]["sha256"]);
        assert_eq!(bundle.platform["core"]["isaString"], p.isa);
    }

    #[test]
    fn only_qualified_profiles_are_offered_and_an_unknown_one_is_refused() {
        assert!(packages().iter().all(|c| c.profile.is_qualified()));
        assert!(packages().len() >= 15);
        assert!(apply_package(&Design::mini_itx().unwrap(), "g6lc64_not_a_profile").is_err());
    }

    #[test]
    fn an_ai_package_adds_an_island_and_a_baseline_package_leaves_it_a_gap() {
        let design = Design::mini_itx().unwrap();
        let with_ai = apply_package(&design, "g6lc64_ai").unwrap();
        assert!(with_ai.ports.iter().any(|p| p.role == "ai_island"));
        let back = apply_package(&with_ai, "cv64a6_imafdc_sv39").unwrap();
        assert!(back.ports.iter().any(|p| p.role == "ai_island"));
        let bundle = compile(&back).unwrap();
        assert!(bundle.platform["gaps"].as_array().unwrap().iter().any(|g| g["role"] == "ai_island"));
    }

    fn xy_overlap(a: &crate::scene::Body, b: &crate::scene::Body) -> bool {
        let ax0 = a.x_um - a.sx_um / 2;
        let ax1 = a.x_um + a.sx_um / 2;
        let ay0 = a.y_um - a.sy_um / 2;
        let ay1 = a.y_um + a.sy_um / 2;
        let bx0 = b.x_um - b.sx_um / 2;
        let bx1 = b.x_um + b.sx_um / 2;
        let by0 = b.y_um - b.sy_um / 2;
        let by1 = b.y_um + b.sy_um / 2;
        ax0 < bx1 && bx0 < ax1 && ay0 < by1 && by0 < ay1
    }

    #[test]
    fn mini_itx_parts_sit_on_the_board_without_overlap() {
        let design = Design::mini_itx().unwrap();
        let bundle = compile(&design).unwrap();
        let bodies: Vec<crate::scene::Body> = serde_json::from_value(bundle.scene).unwrap();
        let board = bodies.iter().find(|b| b.id == "pcb").unwrap();
        for b in &bodies {
            if b.id == "pcb" || b.id == "shield" {
                continue;
            }
            assert!(b.x_um - b.sx_um / 2 >= 0, "{} hangs off -x", b.id);
            assert!(b.x_um + b.sx_um / 2 <= board.sx_um, "{} hangs off +x", b.id);
            assert!(b.y_um - b.sy_um / 2 >= 0, "{} hangs off -y", b.id);
            assert!(b.y_um + b.sy_um / 2 <= board.sy_um, "{} hangs off +y", b.id);
            assert_eq!(b.z_um, 1_600 + b.sz_um / 2, "{} does not sit on the pcb", b.id);
        }
        for (i, a) in bodies.iter().enumerate() {
            if a.id == "pcb" || a.id == "shield" {
                continue;
            }
            for b in bodies.iter().skip(i + 1) {
                if b.id == "pcb" || b.id == "shield" {
                    continue;
                }
                assert!(!xy_overlap(a, b), "{} overlaps {}", a.id, b.id);
            }
        }
        let dimm = bodies.iter().find(|b| b.id == "mem0").unwrap();
        assert_eq!(dimm.sz_um, 8_500);
        assert_eq!(dimm.sy_um, 133_000);
        let slot = bodies.iter().find(|b| b.id == "slot0").unwrap();
        assert_eq!(slot.sy_um, 8_000);
        assert_eq!(slot.sz_um, 11_000);
        let nvme = bodies.iter().find(|b| b.id == "nvme0").unwrap();
        assert_eq!(nvme.sx_um, 22_000);
        assert_eq!(nvme.sy_um, 80_000);
    }

    #[test]
    fn the_editable_scene_has_no_hidden_parts_until_compile() {
        let design = Design::mini_itx().unwrap();
        let preview = scene(&design).unwrap();
        let bundle = compile(&design).unwrap();
        let compiled = bundle.scene.as_array().unwrap();
        assert!(compiled.len() > preview.len());
        assert!(preview.iter().all(|b| b.role != "phy_gbe" && b.role != "decap"));
        assert!(compiled.iter().any(|b| b["role"] == "phy_gbe"));
        assert!(compiled.iter().any(|b| b["role"] == "decap"));
    }
}
