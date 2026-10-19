//! Mini-ITX is the first outline. Edges are datums. Roles name a body size
//! and which edge they belong on. A template does not name a chip package.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::pack::{pack_edge, PackError, SpanPart};
use crate::DEFAULT_GAP_UM;

/// Outline sit datums. `pose()` reads these and `Template` sizes, never `template.id`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Sit {
    /// CPU centre Y as percent of `board_d_um` (Mini-ITX 62).
    pub cpu_y_frac: i64,
    /// NVMe / Wi-Fi rail origin before half-extent.
    pub nvme_rail_x_um: i64,
    pub nvme_rail_y_um: i64,
    /// PCIe slot origin X before half-extent.
    pub slot_x_um: i64,
    /// Slot centre Y. 0 means derive from cpu_y_frac, cpu_body_um, and slot_cpu_gap_um.
    pub slot_y_um: i64,
    /// Socket courtyard used when deriving slot Y.
    pub cpu_body_um: i64,
    /// Gap between CPU courtyard and slot body.
    pub slot_cpu_gap_um: i64,
    /// PHY strip inset from the rear edge.
    pub phy_inset_um: i64,
    /// Power strip Y, clamped to board_d/2.
    pub power_y_um: i64,
    /// Drive-edge inset from the right board edge.
    pub drive_inset_um: i64,
    /// Front-edge inset from the front of the board.
    pub front_inset_um: i64,
}

/// Mini-ITX millimetres. mATX / ATX reuse this; `cpu_y_frac` scales with board depth.
pub fn motherboard_sit() -> Sit {
    Sit {
        cpu_y_frac: 62,
        nvme_rail_x_um: 8_000,
        nvme_rail_y_um: 28_000,
        slot_x_um: 60_000,
        slot_y_um: 0,
        cpu_body_um: 45_000,
        slot_cpu_gap_um: 5_000,
        phy_inset_um: 30_000,
        power_y_um: 36_000,
        drive_inset_um: 4_000,
        front_inset_um: 2_000,
    }
}

pub fn pico_sit() -> Sit {
    Sit {
        cpu_y_frac: 50,
        nvme_rail_x_um: 4_000,
        nvme_rail_y_um: 8_000,
        slot_x_um: 20_000,
        slot_y_um: 0,
        cpu_body_um: 25_000,
        slot_cpu_gap_um: 2_000,
        phy_inset_um: 12_000,
        power_y_um: 18_000,
        drive_inset_um: 2_000,
        front_inset_um: 1_000,
    }
}

pub fn card_sit() -> Sit {
    Sit {
        cpu_y_frac: 50,
        nvme_rail_x_um: 4_000,
        nvme_rail_y_um: 4_000,
        slot_x_um: 0,
        slot_y_um: 0,
        cpu_body_um: 0,
        slot_cpu_gap_um: 0,
        phy_inset_um: 8_000,
        power_y_um: 20_000,
        drive_inset_um: 0,
        front_inset_um: 0,
    }
}

/// 170 mm Mini-ITX, rear window 158.75 × 44.45 mm, one slot at 20.32 mm pitch.
pub fn mini_itx() -> Template {
    let board = 170_000;
    let window = 158_750;
    let window_origin = (board - window) / 2;
    Template {
        id: "mini-itx".into(),
        board_w_um: board,
        board_d_um: board,
        window_w_um: window,
        window_h_um: 44_450,
        slot_pitch_um: 20_320,
        slot_count: 1,
        gap_um: DEFAULT_GAP_UM,
        sit: motherboard_sit(),
        edges: vec![
            Edge {
                id: "rear_io".into(),
                s_min: window_origin,
                s_max: window_origin + window,
            },
            Edge {
                id: "drive".into(),
                s_min: 10_000,
                s_max: board - 10_000,
            },
            Edge {
                id: "front".into(),
                s_min: 10_000,
                s_max: board - 10_000,
            },
            Edge {
                id: "cpu".into(),
                s_min: 40_000,
                s_max: 130_000,
            },
            Edge {
                id: "memory".into(),
                s_min: 46_000,
                s_max: 58_000,
            },
            Edge {
                id: "slot".into(),
                s_min: 0,
                s_max: 20_320,
            },
            Edge {
                id: "phy".into(),
                s_min: 70_000,
                s_max: board - 40_000,
            },
            Edge {
                id: "power".into(),
                s_min: 100_000,
                s_max: board - 10_000,
            },
        ],
    }
}

pub fn matx() -> Template {
    pc_outline("matx", 244_000, 244_000, 4)
}

pub fn atx() -> Template {
    pc_outline("atx", 305_000, 244_000, 7)
}

pub fn pico_itx() -> Template {
    let w = 100_000;
    let d = 72_000;
    Template {
        id: "pico-itx".into(),
        board_w_um: w,
        board_d_um: d,
        window_w_um: 0,
        window_h_um: 0,
        slot_pitch_um: 20_320,
        slot_count: 0,
        gap_um: DEFAULT_GAP_UM,
        sit: pico_sit(),
        edges: vec![
            Edge { id: "rear_io".into(), s_min: 8_000, s_max: w - 8_000 },
            Edge { id: "drive".into(), s_min: 8_000, s_max: d - 8_000 },
            Edge { id: "front".into(), s_min: 8_000, s_max: w - 8_000 },
            Edge { id: "cpu".into(), s_min: 18_000, s_max: w - 18_000 },
            Edge { id: "memory".into(), s_min: 18_000, s_max: w - 18_000 },
            Edge { id: "slot".into(), s_min: 0, s_max: 0 },
            Edge { id: "phy".into(), s_min: 12_000, s_max: w - 12_000 },
            Edge { id: "power".into(), s_min: 12_000, s_max: w - 12_000 },
        ],
    }
}

fn pc_outline(id: &str, w: i64, d: i64, slots: u32) -> Template {
    let window = 158_750;
    let origin = (w - window) / 2;
    Template {
        id: id.into(),
        board_w_um: w,
        board_d_um: d,
        window_w_um: window,
        window_h_um: 44_450,
        slot_pitch_um: 20_320,
        slot_count: slots,
        gap_um: DEFAULT_GAP_UM,
        sit: motherboard_sit(),
        edges: vec![
            Edge { id: "rear_io".into(), s_min: origin, s_max: origin + window },
            Edge { id: "drive".into(), s_min: 12_000, s_max: d - 12_000 },
            Edge { id: "front".into(), s_min: 12_000, s_max: w - 12_000 },
            Edge { id: "cpu".into(), s_min: 50_000, s_max: w - 40_000 },
            Edge { id: "memory".into(), s_min: 50_000, s_max: w - 40_000 },
            Edge { id: "slot".into(), s_min: 0, s_max: slots as i64 * 20_320 },
            Edge { id: "phy".into(), s_min: 20_000, s_max: w - 20_000 },
            Edge { id: "power".into(), s_min: 20_000, s_max: w - 20_000 },
        ],
    }
}

pub fn pcie_card() -> Template {
    let w = 167_650;
    let d = 68_900;
    Template {
        id: "pcie-card".into(),
        board_w_um: w,
        board_d_um: d,
        window_w_um: 0,
        window_h_um: 0,
        slot_pitch_um: 20_320,
        slot_count: 0,
        gap_um: DEFAULT_GAP_UM,
        sit: card_sit(),
        edges: vec![
            Edge { id: "cem".into(), s_min: 0, s_max: 89_000 },
            Edge { id: "bracket".into(), s_min: 8_000, s_max: d - 8_000 },
            Edge { id: "island".into(), s_min: 20_000, s_max: w - 20_000 },
            Edge { id: "power".into(), s_min: 12_000, s_max: w - 12_000 },
        ],
    }
}

/// Outline ids the board combo may offer. Independent of pin/net/path.
pub fn outline_ids() -> &'static [&'static str] {
    &["mini-itx", "matx", "atx", "pico-itx", "pcie-card"]
}

/// Local body box (sx, sy, sz) before yaw. Width is the along-edge span at yaw 0.
pub fn role_extents(role: &str, width: i64) -> (i64, i64, i64) {
    match role {
        "socket" => (width, width, 6_000),
        "dimm" => (width, 133_000, 8_500),
        "sodimm" => (width, 68_000, 5_200),
        "usb_stack" | "hdmi" | "dp" | "gbe_magjack" | "dc_jack" => (width, 16_000, 14_000),
        "sata" => (width, 20_000, 8_000),
        "pcie_slot" => (89_000, 8_000, 11_000),
        "pcie_cem" => (89_000, 1_500, 1_600),
        "usb_c" => (width, 16_000, 10_000),
        "nvme_m2" | "wifi_m2" => (width, 80_000, 4_000),
        "ai_island" => (width, width, 3_000),
        "rtc_battery" => (width, width, 6_000),
        "spi_flash" | "phy_gbe" | "crystal" | "esd" | "vtt" | "decap" => (width, width, 2_500),
        "front_panel" => (width, 6_000, 8_000),
        _ => (width, width, 6_000),
    }
}

pub fn template_by_id(id: &str) -> Result<Template, PackError> {
    Ok(match id {
        "mini-itx" => mini_itx(),
        "matx" => matx(),
        "atx" => atx(),
        "pico-itx" => pico_itx(),
        "pcie-card" => pcie_card(),
        _ => return Err(PackError { reason: format!("unknown template {id}") }),
    })
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Template {
    pub id: String,
    pub board_w_um: i64,
    pub board_d_um: i64,
    pub window_w_um: i64,
    pub window_h_um: i64,
    pub slot_pitch_um: i64,
    pub slot_count: u32,
    pub gap_um: i64,
    #[serde(default)]
    pub sit: Sit,
    pub edges: Vec<Edge>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Edge {
    pub id: String,
    pub s_min: i64,
    pub s_max: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Role {
    pub id: &'static str,
    pub width_um: i64,
    pub edge: &'static str,
    pub stackable: bool,
}

const ROLES: &[Role] = &[
    Role { id: "usb_stack", width_um: 15_000, edge: "rear_io", stackable: true },
    Role { id: "gbe_magjack", width_um: 16_000, edge: "rear_io", stackable: false },
    Role { id: "hdmi", width_um: 15_000, edge: "rear_io", stackable: true },
    Role { id: "socket", width_um: 45_000, edge: "cpu", stackable: false },
    Role { id: "dimm", width_um: 10_000, edge: "memory", stackable: false },
    Role { id: "sata", width_um: 12_000, edge: "drive", stackable: false },
    Role { id: "front_panel", width_um: 8_000, edge: "front", stackable: false },
    Role { id: "rtc_battery", width_um: 20_000, edge: "cpu", stackable: false },
    Role { id: "pcie_slot", width_um: 20_320, edge: "slot", stackable: false },
    Role { id: "pcie_cem", width_um: 89_000, edge: "cem", stackable: false },
    Role { id: "usb_c", width_um: 12_000, edge: "rear_io", stackable: false },
    Role { id: "dc_jack", width_um: 14_000, edge: "rear_io", stackable: false },
    Role { id: "sodimm", width_um: 10_000, edge: "memory", stackable: false },
    Role { id: "spi_flash", width_um: 8_000, edge: "power", stackable: false },
    Role { id: "dp", width_um: 16_000, edge: "rear_io", stackable: true },
    Role { id: "wifi_m2", width_um: 22_000, edge: "phy", stackable: false },
    Role { id: "nvme_m2", width_um: 22_000, edge: "drive", stackable: false },
    Role { id: "ai_island", width_um: 30_000, edge: "phy", stackable: false },
    Role { id: "phy_gbe", width_um: 8_000, edge: "phy", stackable: false },
    Role { id: "crystal", width_um: 6_000, edge: "phy", stackable: false },
    Role { id: "esd", width_um: 4_000, edge: "phy", stackable: false },
    Role { id: "vtt", width_um: 8_000, edge: "power", stackable: false },
    Role { id: "decap", width_um: 3_200, edge: "power", stackable: false },
];

/// Every placeable role. Bluetooth is a UI label on `wifi_m2`, not a role.
pub fn roles() -> &'static [Role] {
    ROLES
}

pub fn role(id: &str) -> Option<Role> {
    ROLES.iter().copied().find(|r| r.id == id)
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Settings {
    pub package_id: String,
    pub gap_um: i64,
    /// Firmware witness. Does not create CSRs or MMIO.
    #[serde(default = "default_hotkey")]
    pub hotkey: String,
    #[serde(default = "default_timeout_ms")]
    pub timeout_ms: i64,
    #[serde(default = "default_product")]
    pub product: String,
}

fn default_hotkey() -> String {
    "DEL".into()
}

fn default_timeout_ms() -> i64 {
    2_000
}

fn default_product() -> String {
    "desktop".into()
}

impl Settings {
    pub fn new(package_id: impl Into<String>, gap_um: i64) -> Self {
        Self {
            package_id: package_id.into(),
            gap_um,
            hotkey: default_hotkey(),
            timeout_ms: default_timeout_ms(),
            product: default_product(),
        }
    }
}

/// Exact part a component instance resolves to. Every field comes from a
/// catalogue freeze; none is typed by hand. Empty strings mean "not frozen".
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PartRef {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub mpn: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub lcsc: String,
    /// Frozen footprint identity (pad geometry source). Empty until a
    /// `cse_get_kicad` freeze exists for this part.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub footprint: String,
}

fn is_false(b: &bool) -> bool {
    !b
}

/// A component instance: the role names the body/pin class, the optional
/// exact part refines it. `refdes` is persistent — it is assigned once and
/// survives moves, copies of *other* parts, and reloads.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Port {
    pub id: String,
    pub role: String,
    pub width_um: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refdes: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub part: Option<PartRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    /// Do-not-populate: kept in the circuit and layout, excluded from assembly.
    #[serde(default, skip_serializing_if = "is_false")]
    pub dnp: bool,
}

impl Port {
    pub fn new(id: impl Into<String>, role: impl Into<String>, width_um: i64) -> Self {
        Self { id: id.into(), role: role.into(), width_um, refdes: None, part: None, value: None, dnp: false }
    }
}

/// Which copper side a component sits on. Bottom mirrors X in pad transforms.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum Side {
    #[default]
    Top,
    Bottom,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Placement {
    pub id: String,
    pub edge: String,
    pub s_um: i64,
    pub stack: u8,
    pub pinned: bool,
    pub order: u32,
    /// Quarter-turns around the surface normal (Z). 0..=3.
    #[serde(default)]
    pub yaw_q: u8,
    /// Board-plane centre when the part was Placed. Z stays sit-on-PCB.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x_um: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub y_um: Option<i64>,
    #[serde(default)]
    pub side: Side,
}

impl Placement {
    pub fn new(id: impl Into<String>, edge: impl Into<String>, s_um: i64, pinned: bool, order: u32) -> Self {
        Self {
            id: id.into(),
            edge: edge.into(),
            s_um,
            stack: 0,
            pinned,
            order,
            yaw_q: 0,
            x_um: None,
            y_um: None,
            side: Side::Top,
        }
    }
}

/// An explicit user connection: these pin ids belong to one net. Resolution
/// checks the pins exist and are compatible; a bad connection becomes a
/// diagnostic, never a silent join.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Connection {
    pub net: String,
    pub pins: Vec<String>,
    /// `power` | `ground` | `signal` | `clock`; defaults to `signal`.
    #[serde(default = "default_signal")]
    pub class: String,
}

fn default_signal() -> String {
    "signal".into()
}

/// A circuit-recipe instance. `owns` lists the component ids the recipe
/// generated so re-expansion reuses them and deletion removes exactly them.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CircuitBlock {
    pub id: String,
    pub recipe: String,
    pub host: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub params: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub owns: Vec<String>,
}

/// Reference-designator prefix by part class. Connectors are `J`, passives by
/// kind, ICs `U`, crystals `Y`, protection diodes `D`, batteries `BT`.
pub fn refdes_prefix(role: &str) -> &'static str {
    match role {
        "decap" => "C",
        "crystal" => "Y",
        "esd" => "D",
        "rtc_battery" => "BT",
        "socket" | "spi_flash" | "phy_gbe" | "vtt" | "ai_island" => "U",
        _ => "J",
    }
}

/// Current authoring-document schema. Loaders accept documents without the
/// field (schema 1) and migrate them in memory; writers always emit it.
pub const DESIGN_SCHEMA_VERSION: u32 = 2;

fn default_schema_version() -> u32 {
    1
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Design {
    /// Schema the document was written with. Absent in v1 files.
    #[serde(default = "default_schema_version")]
    pub schema_version: u32,
    pub template_id: String,
    pub settings: Settings,
    pub ports: Vec<Port>,
    pub placements: Vec<Placement>,
    /// Next free numeric suffix per role. A deleted identity is never handed
    /// out again within a document; the counter only grows. Absent in v1
    /// files, in which case the first allocation scans existing ids.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub id_seq: BTreeMap<String, u32>,
    /// Next free reference-designator number per prefix (`C`, `J`, `U`, …).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub refdes_seq: BTreeMap<String, u32>,
    /// Explicit user connections (the intended circuit, independent of geometry).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub connections: Vec<Connection>,
    /// Pin ids deliberately left open. Everything else that is required must connect.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub no_connects: Vec<String>,
    /// Circuit-recipe instances and the components they own.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub blocks: Vec<CircuitBlock>,
}

impl Design {
    /// Persistent reference designator for `port_id`, assigning one if absent.
    pub fn assign_refdes(&mut self, port_id: &str) -> Option<String> {
        let (role, existing) = {
            let port = self.ports.iter().find(|p| p.id == port_id)?;
            (port.role.clone(), port.refdes.clone())
        };
        if let Some(r) = existing {
            return Some(r);
        }
        let prefix = refdes_prefix(&role);
        let scanned = self
            .ports
            .iter()
            .filter_map(|p| p.refdes.as_deref())
            .filter_map(|r| r.strip_prefix(prefix).and_then(|n| n.parse::<u32>().ok()))
            .map(|n| n + 1)
            .max()
            .unwrap_or(1);
        let mut next = (*self.refdes_seq.get(prefix).unwrap_or(&0)).max(scanned);
        let refdes = loop {
            let candidate = format!("{prefix}{next}");
            next += 1;
            if !self.ports.iter().any(|p| p.refdes.as_deref() == Some(candidate.as_str())) {
                break candidate;
            }
        };
        self.refdes_seq.insert(prefix.to_string(), next);
        let port = self.ports.iter_mut().find(|p| p.id == port_id)?;
        port.refdes = Some(refdes.clone());
        Some(refdes)
    }

    /// Assign refdes to every port that lacks one, in placement order so a
    /// migrated v1 document is deterministic.
    pub fn assign_all_refdes(&mut self) {
        let order: Vec<String> = {
            let mut places: Vec<&Placement> = self.placements.iter().collect();
            places.sort_by_key(|p| p.order);
            places.iter().map(|p| p.id.clone()).collect()
        };
        for id in order {
            self.assign_refdes(&id);
        }
        let orphans: Vec<String> = self.ports.iter().filter(|p| p.refdes.is_none()).map(|p| p.id.clone()).collect();
        for id in orphans {
            self.assign_refdes(&id);
        }
    }

    /// Allocate a fresh part id for `role_id`. Monotonic per role and unique
    /// across every id currently in the document, regardless of role.
    pub fn allocate_id(&mut self, role_id: &str) -> String {
        let scanned = self
            .ports
            .iter()
            .filter(|p| p.role == role_id)
            .filter_map(|p| p.id.strip_prefix(role_id).and_then(|s| s.parse::<u32>().ok()))
            .map(|n| n + 1)
            .max()
            .unwrap_or(1);
        let mut next = (*self.id_seq.get(role_id).unwrap_or(&0)).max(scanned);
        loop {
            let candidate = format!("{role_id}{next}");
            next += 1;
            if !self.ports.iter().any(|p| p.id == candidate) {
                self.id_seq.insert(role_id.to_string(), next);
                return candidate;
            }
        }
    }

    /// Bring a loaded document to the current schema. Idempotent. Parts keep
    /// their ids and geometry; missing reference designators are assigned.
    pub fn migrate(&mut self) {
        if self.schema_version < DESIGN_SCHEMA_VERSION {
            self.schema_version = DESIGN_SCHEMA_VERSION;
        }
        self.assign_all_refdes();
    }

    /// A packed Mini-ITX with the usual first parts. The slot bracket is pinned.
    pub fn mini_itx() -> Result<Self, PackError> {
        Self::from_template("mini-itx")
    }

    pub fn from_template(id: &str) -> Result<Self, PackError> {
        if id == "pcie-card" {
            return Self::pcie_card_design();
        }
        let template = template_by_id(id)?;
        let cpu = template.edges.iter().find(|e| e.id == "cpu").ok_or_else(|| PackError {
            reason: format!("{id} has no cpu edge"),
        })?;
        let small = template.board_w_um < 120_000;
        let socket_w = if small { 25_000 } else { 45_000 };
        let bat_w = if small { 12_000 } else { 20_000 };
        let socket_s = (cpu.s_min + cpu.s_max) / 2;
        let bat_s = cpu.s_max - bat_w / 2;
        let mut specs: Vec<(&str, &str, bool, i64, i64)> = vec![
            ("socket", "socket", true, socket_s, socket_w),
            ("spi0", "spi_flash", false, 0, 8_000),
            ("bat0", "rtc_battery", true, bat_s, bat_w),
            ("usb0", "usb_stack", false, 0, 15_000),
            ("lan0", "gbe_magjack", false, 0, 16_000),
            ("hdmi0", "hdmi", false, 0, 15_000),
            ("fp0", "front_panel", false, 0, 8_000),
        ];
        if small {
            specs.push(("mem0", "sodimm", false, 0, 10_000));
            specs.push(("pwr0", "dc_jack", false, 0, 14_000));
        } else {
            specs.push(("mem0", "dimm", false, 0, 10_000));
            specs.push(("usb1", "usb_stack", false, 0, 15_000));
            specs.push(("sata0", "sata", false, 0, 12_000));
            specs.push(("nvme0", "nvme_m2", false, 0, 22_000));
            if template.slot_count > 0 {
                specs.push(("slot0", "pcie_slot", true, template.slot_pitch_um / 2, template.slot_pitch_um));
            }
        }
        let mut design = Design::empty(&template.id, template.gap_um);
        for (i, (id, role_id, pinned, s, width)) in specs.iter().enumerate() {
            design.ports.push(Port::new(*id, *role_id, *width));
            design
                .placements
                .push(Placement::new(*id, role(role_id).expect("role").edge, *s, *pinned, i as u32));
        }
        design.assign_all_refdes();
        design.repack(&template)?;
        Ok(design)
    }

    /// A document with no parts on `template_id`.
    pub fn empty(template_id: &str, gap_um: i64) -> Self {
        Design {
            schema_version: DESIGN_SCHEMA_VERSION,
            template_id: template_id.to_string(),
            settings: Settings::new("cv64a6_imafdc_sv39", gap_um),
            ports: Vec::new(),
            placements: Vec::new(),
            id_seq: BTreeMap::new(),
            refdes_seq: BTreeMap::new(),
            connections: Vec::new(),
            no_connects: Vec::new(),
            blocks: Vec::new(),
        }
    }

    fn pcie_card_design() -> Result<Self, PackError> {
        let template = pcie_card();
        let cem = role("pcie_cem").expect("pcie_cem");
        let mut design = Design::empty(&template.id, template.gap_um);
        design.ports.push(Port::new("cem0", cem.id, cem.width_um));
        design.placements.push(Placement::new("cem0", cem.edge, 44_500, true, 0));
        design.assign_all_refdes();
        design.repack(&template)?;
        Ok(design)
    }

    pub fn template(&self) -> Result<Template, PackError> {
        template_by_id(&self.template_id)
    }

    pub fn repack(&mut self, template: &Template) -> Result<(), PackError> {
        let edges = template.edges.clone();
        for edge in &edges {
            let mut spans = Vec::new();
            for place in &self.placements {
                if place.edge != edge.id {
                    continue;
                }
                let port = self
                    .ports
                    .iter()
                    .find(|p| p.id == place.id)
                    .ok_or_else(|| PackError {
                        reason: format!("{} has no port", place.id),
                    })?;
                spans.push(SpanPart {
                    id: place.id.clone(),
                    order: place.order,
                    width_um: port.width_um,
                    s_um: place.s_um,
                    pinned: place.pinned,
                });
            }
            if spans.is_empty() {
                continue;
            }
            pack_edge(edge.s_min, edge.s_max, self.settings.gap_um, &mut spans)?;
            for span in spans {
                if let Some(place) = self.placements.iter_mut().find(|p| p.id == span.id) {
                    place.s_um = span.s_um;
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod settings_tests {
    use super::Settings;

    #[test]
    fn old_design_json_gets_firmware_witness_defaults() {
        let s: Settings =
            serde_json::from_str(r#"{"package_id":"cv64a6_imafdc_sv39","gap_um":1500}"#).unwrap();
        assert_eq!(s.hotkey, "DEL");
        assert_eq!(s.timeout_ms, 2_000);
        assert_eq!(s.product, "desktop");
    }
}
