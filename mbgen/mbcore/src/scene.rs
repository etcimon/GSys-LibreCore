//! World poses shared by the preview and the Unreal project. One micrometre
//! in, the same box out. Unreal converts micrometres to centimetres.

/// Actor-local centimetres (pre 20× scale) to micrometres. Unreal `ToCm = 0.0001`.
pub const LOCAL_CM_TO_UM: f64 = 10_000.0;
/// PCB top in actor-local centimetres (1600 µm). Not the substrate midplane.
pub const PCB_TOP_CM: f64 = 0.16;

pub fn um_from_local_cm(cm: f64) -> i64 {
    (cm * LOCAL_CM_TO_UM).round() as i64
}

use serde::Serialize;

use crate::catalog::{library_for, package, Support};
use crate::template::{role_extents, Design, Placement, Template};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, serde::Deserialize)]
pub struct Body {
    pub id: String,
    pub role: String,
    pub support: String,
    pub library: Option<String>,
    pub note: String,
    pub material: String,
    pub x_um: i64,
    pub y_um: i64,
    pub z_um: i64,
    pub sx_um: i64,
    pub sy_um: i64,
    pub sz_um: i64,
    #[serde(default)]
    pub yaw_q: u8,
}

pub fn scene(design: &Design) -> Result<Vec<Body>, crate::pack::PackError> {
    let template = design.template()?;
    let ai = package(&design.settings.package_id).map(|c| c.ai).unwrap_or(false);
    let mut bodies = vec![substrate(&template), shield(&template)];
    bodies.retain(|b| b.sx_um > 0 && b.sy_um > 0);
    for place in &design.placements {
        let port = design.ports.iter().find(|p| p.id == place.id).ok_or_else(|| {
            crate::pack::PackError { reason: format!("{} has no port", place.id) }
        })?;
        let lib = library_for(&port.role, ai);
        let (sx, sy, sz) = role_extents(&port.role, port.width_um);
        let (x, y, z) = pose(&template, place, &port.role, sx, sy, sz);
        bodies.push(Body {
            id: place.id.clone(),
            role: port.role.clone(),
            support: lib.support.as_str().into(),
            library: lib.vendor_id.map(str::to_string),
            note: lib.note.into(),
            material: material_for(&port.role, lib.support),
            x_um: x,
            y_um: y,
            z_um: z,
            sx_um: sx,
            sy_um: sy,
            sz_um: sz,
            yaw_q: place.yaw_q % 4,
        });
    }
    Ok(bodies)
}

fn substrate(t: &Template) -> Body {
    Body {
        id: "pcb".into(),
        role: "pcb".into(),
        support: Support::Board.as_str().into(),
        library: None,
        note: "FR4".into(),
        material: "solder_mask".into(),
        x_um: t.board_w_um / 2,
        y_um: t.board_d_um / 2,
        z_um: 800,
        sx_um: t.board_w_um,
        sy_um: t.board_d_um,
        sz_um: 1_600,
        yaw_q: 0,
    }
}

fn shield(t: &Template) -> Body {
    if t.window_h_um == 0 {
        return Body {
            id: "shield".into(),
            role: "shield".into(),
            support: "board".into(),
            library: None,
            note: String::new(),
            material: "metal".into(),
            x_um: 0,
            y_um: 0,
            z_um: 0,
            sx_um: 0,
            sy_um: 0,
            sz_um: 0,
            yaw_q: 0,
        };
    }
    let x = t.edges.iter().find(|e| e.id == "rear_io").map(|e| e.s_min).unwrap_or(0) + t.window_w_um / 2;
    Body {
        id: "shield".into(),
        role: "shield".into(),
        support: "board".into(),
        library: None,
        note: "Case I/O shield".into(),
        material: "metal".into(),
        x_um: x,
        y_um: t.board_d_um + 800,
        z_um: 1_600 + t.window_h_um / 2,
        sx_um: t.window_w_um,
        sy_um: 800,
        sz_um: t.window_h_um,
        yaw_q: 0,
    }
}

fn world_span(sx: i64, sy: i64, yaw_q: u8) -> (i64, i64) {
    if yaw_q % 2 == 1 {
        (sy, sx)
    } else {
        (sx, sy)
    }
}

fn pose(t: &Template, place: &Placement, role: &str, sx: i64, sy: i64, sz: i64) -> (i64, i64, i64) {
    let z = 1_600 + sz / 2;
    let (aabb_sx, aabb_sy) = world_span(sx, sy, place.yaw_q);
    if let (Some(x), Some(y)) = (place.x_um, place.y_um) {
        return (x, y, z);
    }
    let sit = &t.sit;
    let s = place.s_um;
    let cpu_y = t.board_d_um * sit.cpu_y_frac / 100;
    let slot_y = if sit.slot_y_um != 0 {
        sit.slot_y_um
    } else {
        (cpu_y - sit.cpu_body_um / 2 - aabb_sy / 2 - sit.slot_cpu_gap_um).max(aabb_sy / 2)
    };
    match role {
        "nvme_m2" | "wifi_m2" => {
            let x = (sit.nvme_rail_x_um + aabb_sx / 2).min(t.board_w_um - aabb_sx / 2).max(aabb_sx / 2);
            let y = (sit.nvme_rail_y_um + aabb_sy / 2).min(t.board_d_um - aabb_sy / 2).max(aabb_sy / 2);
            (x, y, z)
        }
        "pcie_slot" => {
            let x = (sit.slot_x_um + aabb_sx / 2).min(t.board_w_um - aabb_sx / 2).max(aabb_sx / 2);
            (x, slot_y, z)
        }
        "dimm" => (s, t.board_d_um / 2, z),
        "pcie_cem" => (s, aabb_sy / 2, z),
        _ => match place.edge.as_str() {
            "rear_io" => (s, t.board_d_um - aabb_sy / 2, z),
            "drive" => (t.board_w_um - aabb_sx / 2 - sit.drive_inset_um, s, z),
            "front" => (s, aabb_sy / 2 + sit.front_inset_um, z),
            "cpu" => (s, cpu_y, z),
            "memory" => (s, t.board_d_um / 2, z),
            "slot" => (t.board_w_um / 2, slot_y, z),
            "phy" => (s, t.board_d_um - sit.phy_inset_um, z),
            "power" => (s, sit.power_y_um.min(t.board_d_um / 2), z),
            "cem" => (s, aabb_sy / 2, z),
            "bracket" => (t.board_w_um - aabb_sx / 2, s, z),
            "island" => (s, t.board_d_um / 2, z),
            _ => (s, t.board_d_um / 2, z),
        },
    }
}

pub(crate) fn on_board(t: &Template, x: i64, y: i64, sx: i64, sy: i64, yaw_q: u8) -> bool {
    let (aabb_sx, aabb_sy) = world_span(sx, sy, yaw_q);
    let hx = aabb_sx / 2;
    let hy = aabb_sy / 2;
    x >= hx && y >= hy && x + hx <= t.board_w_um && y + hy <= t.board_d_um
}

fn material_for(role: &str, support: Support) -> String {
    if support == Support::Gap {
        return "ghost".into();
    }
    match role {
        "gbe_magjack" | "sata" | "dc_jack" | "rtc_battery" => "metal",
        "pcie_slot" | "pcie_cem" => "gold",
        "socket" | "dimm" | "sodimm" | "usb_stack" | "hdmi" | "dp" | "front_panel" | "nvme_m2" | "wifi_m2" => "plastic",
        "spi_flash" | "phy_gbe" | "crystal" | "decap" | "vtt" | "esd" | "ai_island" => "ceramic",
        _ => "plastic",
    }
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scene_bodies_serialize_yaw_q() {
        let bodies = scene(&Design::mini_itx().unwrap()).unwrap();
        let json = serde_json::to_string(&bodies).unwrap();
        assert!(json.contains("\"yaw_q\""));
        assert!(bodies.iter().all(|b| b.yaw_q <= 3));
        assert_eq!(bodies.iter().find(|b| b.id == "usb0").unwrap().yaw_q, 0);
    }

    #[test]
    fn actor_local_centimetres_become_micrometres() {
        assert_eq!(um_from_local_cm(17.0), 170_000);
        assert_eq!(um_from_local_cm(PCB_TOP_CM), 1_600);
        assert_eq!(um_from_local_cm(0.0001), 1);
    }

    #[test]
    fn mini_itx_nvme_and_slot_keep_their_sit() {
        let bodies = scene(&Design::mini_itx().unwrap()).unwrap();
        let nvme = bodies.iter().find(|b| b.id == "nvme0").unwrap();
        assert_eq!(nvme.x_um, 19_000);
        assert_eq!(nvme.y_um, 68_000);
        let slot = bodies.iter().find(|b| b.id == "slot0").unwrap();
        assert_eq!(slot.x_um, 104_500);
        assert_eq!(slot.y_um, 73_900);
        let socket = bodies.iter().find(|b| b.id == "socket").unwrap();
        assert_eq!(socket.y_um, 105_400);
    }

    fn sit_place(edge: &str, s: i64) -> Placement {
        Placement {
            id: "p".into(),
            edge: edge.into(),
            s_um: s,
            stack: 0,
            pinned: false,
            order: 0,
            yaw_q: 0,
            x_um: None,
            y_um: None,
        }
    }

    #[test]
    fn pose_reads_sit_datums_not_template_id() {
        let mut t = crate::template::mini_itx();
        t.id = "not-an-outline".into();
        t.sit.nvme_rail_x_um = 10_000;
        t.sit.nvme_rail_y_um = 12_000;
        let (x, y, z) = pose(&t, &sit_place("drive", 0), "nvme_m2", 22_000, 80_000, 4_000);
        assert_eq!((x, y, z), (21_000, 52_000, 3_600));
    }

    #[test]
    fn atx_cpu_sits_on_its_own_depth() {
        let t = crate::template::atx();
        assert_eq!(t.board_d_um, 244_000);
        assert_eq!(t.sit.cpu_y_frac, 62);
        let (_, y, _) = pose(&t, &sit_place("cpu", 100_000), "socket", 45_000, 45_000, 6_000);
        assert_eq!(y, 151_280);
    }

    #[test]
    fn pico_power_strip_uses_pico_sit() {
        let t = crate::template::pico_itx();
        let (_, y, _) = pose(&t, &sit_place("power", 50_000), "decap", 3_200, 3_200, 2_500);
        assert_eq!(y, 18_000);
        assert_eq!(t.sit.power_y_um, 18_000);
    }
}
