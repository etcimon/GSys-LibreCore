//! Deterministic PBR maps. The Unreal materials sample these. Nothing here is
//! a photo of a board; the variation is what makes the shader read as FR4,
//! brushed metal, plastic, and gold fingers.
//!
//! Each shaded slot is a color map, a data map (R roughness, G metallic,
//! B height), and a tangent-space normal derived from that height.

use image::{ImageBuffer, Rgb};
use mbcore::{scene, Design};

struct PartRect {
    cx: f32,
    cy: f32,
    hx: f32,
    hy: f32,
    role: String,
}

struct BoardMap {
    w_mm: f32,
    d_mm: f32,
    tw: u32,
    th: u32,
    parts: Vec<PartRect>,
}

fn map_size(w_mm: f32, d_mm: f32) -> (u32, u32) {
    const MAX: u32 = 512;
    if (w_mm - d_mm).abs() < 1.0 {
        return (MAX, MAX);
    }
    if w_mm >= d_mm {
        let h = ((d_mm / w_mm) * MAX as f32).round() as u32;
        (MAX, h.clamp(64, MAX))
    } else {
        let w = ((w_mm / d_mm) * MAX as f32).round() as u32;
        (w.clamp(64, MAX), MAX)
    }
}

impl BoardMap {
    fn from_design(design: &Design) -> Result<Self, String> {
        let template = design.template().map_err(|e| e.reason)?;
        let w_mm = template.board_w_um as f32 / 1000.0;
        let d_mm = template.board_d_um as f32 / 1000.0;
        let (tw, th) = map_size(w_mm, d_mm);
        let bodies = scene(design).map_err(|e| e.reason)?;
        let parts = bodies
            .into_iter()
            .filter(|b| b.id != "pcb" && b.id != "shield")
            .map(|b| PartRect {
                cx: b.x_um as f32 / 1000.0,
                cy: b.y_um as f32 / 1000.0,
                hx: b.sx_um as f32 / 2000.0,
                hy: b.sy_um as f32 / 2000.0,
                role: b.role,
            })
            .collect();
        Ok(Self { w_mm, d_mm, tw, th, parts })
    }

    fn mm(&self, x: u32, y: u32) -> (f32, f32) {
        (x as f32 * self.w_mm / self.tw as f32, y as f32 * self.d_mm / self.th as f32)
    }
}

struct Texel {
    color: [u8; 3],
    height: u8,
    rough: u8,
    metal: u8,
}

#[cfg_attr(not(test), allow(dead_code))]
pub fn write_set(dir: &std::path::Path) -> Result<(), String> {
    let design = Design::mini_itx().map_err(|e| e.reason)?;
    write_set_for(dir, &design)
}

pub fn write_solder_for(dir: &std::path::Path, design: &Design) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let map = BoardMap::from_design(design)?;
    write_triplet(
        dir,
        "T_SolderMask",
        "T_SolderData",
        "T_SolderNormal",
        map.tw,
        map.th,
        |x, y| solder(x, y, &map),
    )
}

pub fn write_set_for(dir: &std::path::Path, design: &Design) -> Result<(), String> {
    write_solder_for(dir, design)?;
    write_triplet(dir, "T_Metal", "T_MetalData", "T_MetalNormal", 256, 256, brushed)?;
    write_triplet(dir, "T_Plastic", "T_PlasticData", "T_PlasticNormal", 128, 128, plastic)?;
    write_triplet(dir, "T_Gold", "T_GoldData", "T_GoldNormal", 256, 256, gold)?;
    write_triplet(dir, "T_Ceramic", "T_CeramicData", "T_CeramicNormal", 128, 128, ceramic)?;
    save(dir, "T_Ghost", ghost())?;
    save(dir, "T_Cavity", ImageBuffer::from_fn(16, 16, |_, _| Rgb([14, 14, 16])))?;
    save(dir, "T_LedGreen", ImageBuffer::from_fn(8, 8, |_, _| Rgb([36, 190, 64])))?;
    save(dir, "T_LedAmber", ImageBuffer::from_fn(8, 8, |_, _| Rgb([220, 140, 28])))?;
    save(dir, "T_PinGold", ImageBuffer::from_fn(8, 8, |_, _| Rgb([212, 168, 52])))?;
    Ok(())
}

fn write_triplet<F>(
    dir: &std::path::Path,
    color_name: &str,
    data_name: &str,
    normal_name: &str,
    w: u32,
    h: u32,
    texel: F,
) -> Result<(), String>
where
    F: Fn(u32, u32) -> Texel,
{
    let mut samples = Vec::with_capacity((w * h) as usize);
    for y in 0..h {
        for x in 0..w {
            samples.push(texel(x, y));
        }
    }
    let (color, data, normal) = finish(w, h, &samples);
    save(dir, color_name, color)?;
    save(dir, data_name, data)?;
    save(dir, normal_name, normal)?;
    Ok(())
}

fn save(dir: &std::path::Path, name: &str, img: ImageBuffer<Rgb<u8>, Vec<u8>>) -> Result<(), String> {
    img.save(dir.join(format!("{name}.png"))).map_err(|e| e.to_string())
}

fn finish(w: u32, h: u32, samples: &[Texel]) -> (ImageBuffer<Rgb<u8>, Vec<u8>>, ImageBuffer<Rgb<u8>, Vec<u8>>, ImageBuffer<Rgb<u8>, Vec<u8>>) {
    let at = |x: u32, y: u32| &samples[(y * w + x) as usize];
    let color = ImageBuffer::from_fn(w, h, |x, y| Rgb(at(x, y).color));
    let data = ImageBuffer::from_fn(w, h, |x, y| {
        let s = at(x, y);
        Rgb([s.rough, s.metal, s.height])
    });
    let normal = ImageBuffer::from_fn(w, h, |x, y| {
        let h0 = at(x, y).height as i16;
        let hx = at((x + 1) % w, y).height as i16;
        let hy = at(x, (y + 1) % h).height as i16;
        let dx = (hx - h0).clamp(-40, 40);
        let dy = (hy - h0).clamp(-40, 40);
        Rgb([(128 + dx) as u8, (128 + dy) as u8, 196])
    });
    (color, data, normal)
}

fn solder(x: u32, y: u32, map: &BoardMap) -> Texel {
    if board_silk(x, y, map) {
        return Texel { color: [232, 230, 214], height: 214, rough: 188, metal: 0 };
    }
    if let Some(land) = footprint(x, y, map) {
        return land;
    }
    let n = noise(x, y);
    let (mmx, mmy) = map.mm(x, y);
    let px = (x % 32) as i32 - 16;
    let py = (y % 32) as i32 - 16;
    let cell = x / 32 + y / 32;
    let pad = px * px + py * py < 5 * 5 && cell % 6 == 0;
    let edge = mmx.min(mmy).min(map.w_mm - mmx).min(map.d_mm - mmy);
    let stitch = (3.5..4.8).contains(&edge) && (x + y) % 11 < 3;
    let slot = map.parts.iter().find(|p| p.role == "pcie_slot");
    let dimm = map.parts.iter().find(|p| p.role == "dimm");
    let hbus = slot
        .map(|s| (mmy - s.cy).abs() < 1.3 && mmx > 20.0 && mmx < map.w_mm - 25.0 && y % 3 != 1)
        .unwrap_or(false);
    let vbus = dimm
        .map(|d| (mmx - d.cx).abs() < 1.1 && mmy > 18.0 && mmy < map.d_mm - 15.0 && x % 3 != 1)
        .unwrap_or(false);
    if stitch {
        return Texel { color: [28, 30, 26], height: 60, rough: 80, metal: 200 };
    }
    if pad {
        return Texel { color: [196, 150 + n / 20, 52], height: 188, rough: 48, metal: 255 };
    }
    if hbus || vbus {
        return Texel { color: [32, 124, 62], height: 164, rough: 100, metal: 0 };
    }
    let lift = n / 14;
    Texel {
        color: [16 + lift / 2, 92 + lift, 46 + lift / 3],
        height: 128 + n / 18,
        rough: 145 + n / 12,
        metal: 0,
    }
}

fn silk_text(role: &str) -> Option<&'static [u8]> {
    match role {
        "socket" => Some(b"CPU"),
        "dimm" => Some(b"DIMM"),
        "sodimm" => Some(b"SODIMM"),
        "pcie_slot" => Some(b"PCIE"),
        "pcie_cem" => Some(b"CEM"),
        "nvme_m2" => Some(b"NVME"),
        "wifi_m2" => Some(b"WIFI"),
        "usb_stack" => Some(b"USB"),
        "gbe_magjack" | "lan" => Some(b"LAN"),
        "hdmi" => Some(b"HDMI"),
        "dp" => Some(b"DP"),
        "dc_jack" => Some(b"DC"),
        "sata" => Some(b"SATA"),
        "rtc_battery" | "coin_cell" => Some(b"BAT"),
        _ => None,
    }
}

/// White courtyards and a board-edge line. Texture x tracks board +X and
/// texture y tracks board +Y across the 512 map.
fn board_silk(x: u32, y: u32, map: &BoardMap) -> bool {
    let (mmx, mmy) = map.mm(x, y);
    let edge = mmx.min(mmy).min(map.w_mm - mmx).min(map.d_mm - mmy);
    if (2.0..3.2).contains(&edge) {
        return true;
    }
    for p in &map.parts {
        if let Some(text) = silk_text(&p.role) {
            if silk_label(mmx, mmy, p.cx - p.hx, p.cy + p.hy + 6.0, text) {
                return true;
            }
        }
        if (p.role == "rtc_battery" || p.role == "coin_cell") && silk_plus(mmx, mmy, p.cx + 11.4, p.cy - 7.4) {
            return true;
        }
        if silk_text(&p.role).is_none() {
            continue;
        }
        let left = p.cx - p.hx - 1.6;
        let right = p.cx + p.hx + 1.6;
        let low = p.cy - p.hy - 1.6;
        let high = p.cy + p.hy + 1.6;
        let on_x = (mmx - left).abs() < 0.7 || (mmx - right).abs() < 0.7;
        let on_y = (mmy - low).abs() < 0.7 || (mmy - high).abs() < 0.7;
        let in_x = mmx >= left && mmx <= right;
        let in_y = mmy >= low && mmy <= high;
        if (on_x && in_y) || (on_y && in_x) {
            return true;
        }
    }
    false
}

fn mask_texel(n: u8) -> Texel {
    let lift = n / 14;
    Texel {
        color: [16 + lift / 2, 92 + lift, 46 + lift / 3],
        height: 128 + n / 18,
        rough: 145 + n / 12,
        metal: 0,
    }
}

fn land_texel(n: u8) -> Texel {
    Texel { color: [196, 150 + n / 20, 52], height: 180, rough: 46, metal: 255 }
}

/// Inside a courtyard the repeating stamp stops. The socket gets an LGA grid,
/// and the DIMM and slot keep a contact row on the camera side.
/// 5x7 labels. `top_y` is the rear edge of the text, in millimetres, so the
/// tops of the letters point toward the rear of the board.
fn silk_plus(mmx: f32, mmy: f32, cx: f32, cy: f32) -> bool {
    let dx = (mmx - cx).abs();
    let dy = (mmy - cy).abs();
    (dx < 0.35 && dy < 1.5) || (dy < 0.35 && dx < 1.5)
}

fn silk_label(mmx: f32, mmy: f32, origin_x: f32, top_y: f32, text: &[u8]) -> bool {
    let pitch = 0.72_f32;
    let local_x = mmx - origin_x;
    if local_x < 0.0 {
        return false;
    }
    let col_f = local_x / pitch;
    let slot = (col_f / 6.0) as usize;
    if slot >= text.len() {
        return false;
    }
    // Board +X is the left side of the product shot, so the first letter sits
    // at the high-x end of the label.
    let glyph_i = text.len() - 1 - slot;
    let col = col_f as usize % 6;
    if col >= 5 {
        return false;
    }
    let row_f = (top_y - mmy) / pitch;
    if !(0.0..7.0).contains(&row_f) {
        return false;
    }
    let rows = glyph_rows(text[glyph_i]);
    // Column 0 is the high bit in the glyph, and board +X runs away from the
    // camera, so the low bit is the left side of the letter in the shot.
    rows[row_f as usize] & (1 << col) != 0
}

fn glyph_rows(ch: u8) -> [u8; 7] {
    match ch {
        b'A' => [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        b'B' => [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110],
        b'C' => [0b01111, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b01111],
        b'D' => [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110],
        b'E' => [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111],
        b'H' => [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        b'I' => [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111],
        b'L' => [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111],
        b'N' => [0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001],
        b'M' => [0b10001, 0b11011, 0b10101, 0b10001, 0b10001, 0b10001, 0b10001],
        b'P' => [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000],
        b'S' => [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110],
        b'T' => [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100],
        b'U' => [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        b'V' => [0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b01010, 0b00100],
        b'W' => [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b01010, 0b01010],
        b'F' => [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000],
        b'O' => [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        _ => [0; 7],
    }
}

fn mm_cycle(mm: f32, origin: f32, pitch: f32) -> f32 {
    let t = (mm - origin) / pitch;
    t - t.floor()
}

fn footprint(x: u32, y: u32, map: &BoardMap) -> Option<Texel> {
    let (mmx, mmy) = map.mm(x, y);
    let n = noise(x, y);
    for p in &map.parts {
        let within = (mmx - p.cx).abs() < p.hx + 1.0 && (mmy - p.cy).abs() < p.hy + 1.0;
        if !within {
            continue;
        }
        let texel_mm = (map.w_mm / map.tw as f32).max(map.d_mm / map.th as f32);
        let pad = (0.35_f32).max(texel_mm * 1.15).min(0.7);
        return Some(match p.role.as_str() {
            "socket" => {
                let gx = mm_cycle(mmx, p.cx - p.hx, 1.0);
                let gy = mm_cycle(mmy, p.cy - p.hy, 1.0);
                if gx < pad && gy < pad { land_texel(n) } else { mask_texel(n) }
            }
            "dimm" => {
                let along = mm_cycle(mmy, p.cy - p.hy, 1.0);
                let contact = (mmx - (p.cx - p.hx)).abs() < 0.45_f32.max(texel_mm) && along < pad;
                if contact { land_texel(n) } else { mask_texel(n) }
            }
            "pcie_slot" => {
                let along = mm_cycle(mmx, p.cx - p.hx, 1.0);
                let contact = (mmy - (p.cy - p.hy)).abs() < 0.4_f32.max(texel_mm) && along < pad;
                if contact { land_texel(n) } else { mask_texel(n) }
            }
            _ => mask_texel(n),
        });
    }
    None
}

fn brushed(x: u32, y: u32) -> Texel {
    let n = noise(x, y) as u16;
    let brush: u16 = if y % 3 == 0 { 16 } else { 0 };
    let scratch: u16 = if (y + x / 11) % 31 == 0 { 48 } else { 0 };
    let v = 178u16.saturating_add(n / 18).saturating_sub(brush + scratch).min(255) as u8;
    Texel {
        color: [v, v, v.saturating_add(3)],
        height: 150u16.saturating_sub(scratch / 2 + brush / 3).min(255) as u8,
        rough: (78 + scratch.min(40) + n / 16).min(255) as u8,
        metal: 255,
    }
}

fn plastic(x: u32, y: u32) -> Texel {
    let n = noise(x, y);
    let seam = if y % 48 < 2 { 24u16 } else { 0 };
    let v = (82u16 + (n as u16) / 9).saturating_sub(seam).min(130) as u8;
    Texel {
        color: [v.saturating_sub(3), v, v.saturating_add(4)],
        height: (138u16 + (n as u16) / 12).saturating_sub(seam).min(255) as u8,
        rough: 112 + n / 8,
        metal: 0,
    }
}

fn gold(x: u32, y: u32) -> Texel {
    let n = noise(x, y);
    let along = x % 10;
    if along < 6 {
        let edge = along == 0 || along == 5;
        Texel {
            color: [186 + n / 22, 146 + n / 28, 46],
            height: if edge { 148 } else { 186 },
            rough: if edge { 96 } else { 40 + n / 24 },
            metal: 255,
        }
    } else {
        Texel { color: [20, 64, 36], height: 96, rough: 168, metal: 0 }
    }
}

fn ceramic(x: u32, y: u32) -> Texel {
    let n = noise(x, y);
    let pin = (x < 18 || x >= 110) && (y % 7) < 4;
    let mark = (40..90).contains(&x) && (52..68).contains(&y);
    if pin {
        let v = 166 + n / 16;
        return Texel { color: [v, v, v.saturating_sub(6)], height: 104, rough: 62, metal: 255 };
    }
    if mark {
        return Texel { color: [118, 110, 96], height: 132, rough: 184, metal: 0 };
    }
    let j = n / 18;
    Texel { color: [176 + j, 168 + j, 148 + j / 2], height: 152, rough: 170, metal: 0 }
}

fn ghost() -> ImageBuffer<Rgb<u8>, Vec<u8>> {
    ImageBuffer::from_fn(128, 128, |x, y| {
        if (x + y) % 12 < 3 {
            Rgb([220, 96, 48])
        } else {
            Rgb([48, 28, 28])
        }
    })
}

fn noise(x: u32, y: u32) -> u8 {
    let n = x.wrapping_mul(374761393).wrapping_add(y.wrapping_mul(668265263));
    (n.rotate_left(13) >> 24) as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn solder_mask_has_pads_and_mask() {
        let map = BoardMap::from_design(&Design::mini_itx().unwrap()).unwrap();
        assert_eq!((map.tw, map.th), (512, 512));
        let mut samples = Vec::with_capacity((map.tw * map.th) as usize);
        for y in 0..map.th {
            for x in 0..map.tw {
                samples.push(solder(x, y, &map));
            }
        }
        let gold = samples.iter().filter(|s| s.metal == 255 && s.color[0] > 160).count();
        let mask = samples.iter().filter(|s| s.metal == 0 && s.color[1] > s.color[0]).count();
        assert!(gold > 2_000, "gold pads {gold}");
        assert!(mask > 100_000, "solder mask {mask}");
        assert_eq!(samples[(16 * 512 + 16) as usize].metal, 255);
        assert_eq!(samples[(20 * 512 + 8) as usize].metal, 0);
        let silk = samples[(317 * 512 + 184) as usize].color;
        assert!(silk[0] > 200, "socket courtyard {silk:?}");
    }

    #[test]
    fn pico_and_card_maps_keep_square_millimetres() {
        let pico = BoardMap::from_design(&Design::from_template("pico-itx").unwrap()).unwrap();
        assert_eq!((pico.tw, pico.th), (512, 369));
        let dx = pico.w_mm / pico.tw as f32;
        let dy = pico.d_mm / pico.th as f32;
        assert!((dx - dy).abs() < 0.05, "pico mm/px {dx} {dy}");
        let card = BoardMap::from_design(&Design::from_template("pcie-card").unwrap()).unwrap();
        assert_eq!((card.tw, card.th), (512, 210));
        let cx = card.w_mm / card.tw as f32;
        let cy = card.d_mm / card.th as f32;
        assert!((cx - cy).abs() < 0.05, "card mm/px {cx} {cy}");
    }

    #[test]
    fn atx_solder_maps_write_to_disk() {
        let dir = std::env::temp_dir().join("mbgen-atx-solder");
        let design = Design::from_template("atx").unwrap();
        write_solder_for(&dir, &design).unwrap();
        let img = image::open(dir.join("T_SolderMask.png")).unwrap();
        assert_eq!(img.width(), 512);
        assert_eq!(img.height(), 410);
    }

    #[test]
    fn atx_solder_map_uses_atx_depth() {
        let design = Design::from_template("atx").unwrap();
        let map = BoardMap::from_design(&design).unwrap();
        assert!((map.w_mm - 305.0).abs() < 0.1);
        assert!((map.d_mm - 244.0).abs() < 0.1);
        let socket = map.parts.iter().find(|p| p.role == "socket").unwrap();
        assert!((socket.cy - 151.28).abs() < 1.0);
        assert_eq!((map.tw, map.th), (512, 410));
        let mut hits = Vec::new();
        'rows: for y in 0..map.th {
            let (_, mmy) = map.mm(0, y);
            if (mmy - socket.cy).abs() > socket.hy - 1.0 {
                continue;
            }
            for x in 0..map.tw {
                let (mmx, _) = map.mm(x, y);
                if (mmx - socket.cx).abs() > socket.hx - 2.0 {
                    continue;
                }
                if let Some(tex) = footprint(x, y, &map) {
                    if tex.metal == 255 {
                        hits.push(mmx);
                    }
                }
            }
            if hits.len() > 8 {
                break 'rows;
            }
            hits.clear();
        }
        let mut unique = Vec::new();
        for h in hits {
            if unique.last().map(|p| h - p > 0.6).unwrap_or(true) {
                unique.push(h);
            }
        }
        assert!(unique.len() > 8, "atx socket lands {}", unique.len());
        let pitch = unique[1] - unique[0];
        assert!((pitch - 1.0).abs() < 0.4, "atx socket land pitch {pitch}");
    }

    #[test]
    fn project_textures_follow_the_generator() {
        let dir = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../mbsim/MbgenSim/Content/Textures");
        write_set(&dir).unwrap();
        for name in ["T_SolderMask.png", "T_SolderData.png", "T_SolderNormal.png", "T_MetalNormal.png", "T_GoldData.png", "T_Ceramic.png", "T_Ghost.png"] {
            assert!(dir.join(name).is_file(), "{name}");
        }
    }
}
