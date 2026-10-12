//! Config packages the processor window may offer, and the vendor row each
//! role asks for. A package is the unit of choice. Bits are not toggled here.

use crate::pack::PackError;
use crate::template::{role, Design, Placement, Port};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PackageCard {
    pub id: &'static str,
    pub group: &'static str,
    pub isa: &'static str,
    pub xlen: u32,
    pub cores: u32,
    pub threads: u32,
    pub ooo: bool,
    pub l2: bool,
    pub l3: bool,
    pub ai: bool,
    pub axi_bits: u32,
    pub core_ua: i64,
}

pub fn packages() -> &'static [PackageCard] {
    &PACKAGES
}

pub fn package(id: &str) -> Option<&'static PackageCard> {
    PACKAGES.iter().find(|p| p.id == id)
}

const PACKAGES: &[PackageCard] = &[
    card("cv64a6_imafdc_sv39", "baseline", "rv64imafdc", 64, 1, 1, false, false, false, false, 64, 250_000),
    card("g6lc64_ai", "ai", "rv64imafdc", 64, 1, 1, false, false, false, true, 64, 2_000_000),
    card("g6lc64_smt2_ai", "ai", "rv64imafdc", 64, 1, 2, false, false, false, true, 64, 2_000_000),
    card("g6lc64_smt2", "smt", "rv64imafdc", 64, 1, 2, false, true, false, false, 64, 400_000),
    card("g6lc64_smt2_l3", "smt", "rv64imafdc", 64, 1, 2, false, true, true, false, 64, 500_000),
    card("g6lc64_ooo_int", "ooo", "rv64imac", 64, 1, 1, true, true, false, false, 64, 400_000),
    card("g6lc64_ooo_int2", "ooo", "rv64imac", 64, 2, 1, true, true, false, false, 64, 700_000),
    card("g6lc64_ooo_int2_l3", "ooo", "rv64imac", 64, 2, 1, true, true, true, false, 64, 800_000),
    card("g6lc64_smt2_ooo_int", "ooo", "rv64imac", 64, 1, 2, true, true, false, false, 64, 500_000),
    card("g6lc64_ooo_server", "ooo", "rv64imac", 64, 4, 1, true, true, true, false, 64, 1_200_000),
    card("g6lc64_stream8", "stream", "rv64imafdc", 64, 1, 1, false, true, false, false, 128, 400_000),
    card("g6lc64_stream8_l3", "stream", "rv64imafdc", 64, 1, 1, false, true, true, false, 128, 500_000),
    card("g6lc64_server_math", "server", "rv64imafdc", 64, 1, 1, false, true, false, false, 64, 400_000),
    card("g6lc64_server_math_l3", "server", "rv64imafdc", 64, 1, 1, false, true, true, false, 64, 500_000),
    card("g6lc64_server_math_v", "server", "rv64imafdcv", 64, 1, 1, false, true, false, false, 64, 600_000),
];

const fn card(
    id: &'static str,
    group: &'static str,
    isa: &'static str,
    xlen: u32,
    cores: u32,
    threads: u32,
    ooo: bool,
    l2: bool,
    l3: bool,
    ai: bool,
    axi_bits: u32,
    core_ua: i64,
) -> PackageCard {
    PackageCard { id, group, isa, xlen, cores, threads, ooo, l2, l3, ai, axi_bits, core_ua }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Support {
    Board,
    Integrated,
    Listed,
    Gap,
}

impl Support {
    pub fn as_str(self) -> &'static str {
        match self {
            Support::Board => "board",
            Support::Integrated => "integrated",
            Support::Listed => "listed",
            Support::Gap => "gap",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LibraryRow {
    pub role: String,
    pub support: Support,
    pub vendor_id: Option<&'static str>,
    pub license: Option<&'static str>,
    pub note: &'static str,
}

/// Read-only domain string for the property sheet and `platform.json`.
pub fn domain_for(role_id: &str) -> &'static str {
    match role_id {
        "dimm" | "sodimm" | "vtt" => "memory",
        "gbe_magjack" | "phy_gbe" => "network",
        "pcie_slot" | "pcie_cem" | "nvme_m2" | "wifi_m2" => "interconnect",
        "sata" | "spi_flash" => "storage",
        "hdmi" | "dp" => "display",
        "usb_stack" | "esd" | "usb_c" => "usb",
        _ => "peripheral",
    }
}

pub fn library_for(role_id: &str, ai: bool) -> LibraryRow {
    let row = |support, vendor_id, license, note| LibraryRow {
        role: role_id.into(),
        support,
        vendor_id,
        license,
        note,
    };
    match role_id {
        "gbe_magjack" | "phy_gbe" => row(Support::Listed, Some("verilog-ethernet"), Some("MIT"), "MAC on-die; jack is a board PHY"),
        "hdmi" => row(Support::Listed, Some("hdmi"), Some("MIT"), "TMDS encoder is catalogued, not yet in a flist"),
        "dimm" | "sodimm" | "vtt" => row(Support::Listed, Some("litedram"), Some("BSD-2-Clause"), "DRAM controller is vendored"),
        "sata" => row(Support::Listed, Some("litesata"), Some("BSD-2-Clause"), "SATA controller is catalogued"),
        "pcie_slot" | "nvme_m2" => row(Support::Listed, Some("verilog-pcie"), Some("MIT"), "NVMe rides the PCIe root; it is not its own controller"),
        "pcie_cem" => row(Support::Listed, Some("verilog-pcie"), Some("MIT"), "Card-edge CEM; freeze is not the slot MPN"),
        "usb_c" => row(Support::Gap, None, None, "USB-C host controller is not in the vendor catalog"),
        "ai_island" if ai => row(Support::Integrated, None, None, "Island is in this config package"),
        "ai_island" => row(Support::Gap, None, None, "This package has no AI island"),
        "usb_stack" | "esd" => row(Support::Gap, None, None, "USB host controller is not in the vendor catalog"),
        "dp" => row(Support::Gap, None, None, "DisplayPort converter is not in the vendor catalog"),
        "wifi_m2" => row(Support::Gap, None, None, "Wi-Fi module controller is not in the vendor catalog"),
        "socket" | "spi_flash" | "rtc_battery" | "front_panel" | "dc_jack" | "crystal" | "decap" => {
            row(Support::Board, None, None, "Board part or an on-die block already in corev_apu")
        }
        _ => row(Support::Board, None, None, "Board part"),
    }
}

/// Swap the config package. An AI package gains an island body. Any other
/// package keeps that body and the view paints it as a gap.
pub fn apply_package(design: &Design, package_id: &str) -> Result<Design, PackError> {
    let card = package(package_id).ok_or_else(|| PackError {
        reason: format!("unknown package {package_id}"),
    })?;
    let mut next = design.clone();
    next.settings.package_id = card.id.into();
    if card.ai && !next.ports.iter().any(|p| p.role == "ai_island") {
        let role = role("ai_island").unwrap();
        let order = next.placements.iter().map(|p| p.order).max().unwrap_or(0) + 1;
        let cpu = next.template()?.edges.into_iter().find(|e| e.id == "cpu");
        let s = cpu.map(|e| (e.s_min + e.s_max) / 2).unwrap_or(0);
        next.ports.push(Port {
            id: "ai0".into(),
            role: role.id.into(),
            width_um: role.width_um,
        });
        next.placements.push(Placement {
            id: "ai0".into(),
            edge: role.edge.into(),
            s_um: s,
            stack: 0,
            pinned: false,
            order,
            yaw_q: 0,
            x_um: None,
            y_um: None,
        });
    }
    let template = next.template()?;
    next.repack(&template)?;
    Ok(next)
}
