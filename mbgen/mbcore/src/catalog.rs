//! Config packages the processor window may offer, and the vendor row each
//! role asks for. A package is the unit of choice. Bits are not toggled here.
//!
//! Package facts are **not typed here**: they are a view over the generated
//! `CoreProfile`s (`profile.rs`, `mbcore/data/profiles.json`), which are read
//! from `core/include/*_config_pkg.sv`. Only qualified profiles are offered.

use std::sync::OnceLock;

use crate::pack::PackError;
use crate::profile::{profiles, CoreProfile};
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
    /// Preview-only decap-count heuristic. Not a measured current and never a
    /// production decoupling input (a rail plan comes from part requirements).
    pub core_ua: i64,
    /// The generated profile this card projects.
    pub profile: &'static CoreProfile,
}

/// Qualified profiles, as cards, in profile order.
pub fn packages() -> &'static [PackageCard] {
    static CACHE: OnceLock<Vec<PackageCard>> = OnceLock::new();
    CACHE.get_or_init(|| profiles().iter().filter(|p| p.is_qualified()).map(card).collect())
}

pub fn package(id: &str) -> Option<&'static PackageCard> {
    packages().iter().find(|p| p.id == id)
}

fn card(p: &'static CoreProfile) -> PackageCard {
    PackageCard {
        id: &p.id,
        group: &p.group,
        isa: &p.isa,
        xlen: p.xlen,
        cores: p.cores,
        threads: p.threads,
        ooo: p.ooo,
        l2: p.l2,
        l3: p.l3,
        ai: p.ai,
        axi_bits: p.axi_bits,
        core_ua: preview_decap_heuristic_ua(p),
        profile: p,
    }
}

/// Preview decap budget. Scales with what the profile has, so a profile that
/// appears on disk tomorrow gets a sensible preview without a table edit. It
/// is labelled as a heuristic everywhere it is consumed.
fn preview_decap_heuristic_ua(p: &CoreProfile) -> i64 {
    let mut ua: i64 = 250_000 * i64::from(p.cores.max(1)) * i64::from(p.threads.max(1)).min(2);
    if p.l2 {
        ua += 100_000;
    }
    if p.l3 {
        ua += 100_000;
    }
    if p.ooo {
        ua += 100_000;
    }
    if p.ai {
        ua += 1_000_000;
    }
    ua
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
        next.ports.push(Port::new("ai0", role.id, role.width_um));
        next.placements.push(Placement::new("ai0", role.edge, s, false, order));
        next.assign_refdes("ai0");
    }
    let template = next.template()?;
    next.repack(&template)?;
    Ok(next)
}
