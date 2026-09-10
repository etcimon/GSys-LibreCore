// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Uncore HDMI/DP scanout (`architecture/uncore/hdmi-display.md`).
//! On-die TMDS vs board PHY stay SoC/board IP; this file is the G6DS
//! register contract the BIOS programs.

use g6b_spec::BoardSpec;

use crate::{Adapter, AdapterClass, AdapterKind};

/// Catalog ids. `g6lc-scanout` is the BIOS MMIO seam; `hdl-util-hdmi`
/// is the uncore encoder catalog (`architecture/uncore/hdmi-display.md`).
pub const HDMI_VENDORS: &[&str] = &["g6lc-scanout", "hdl-util-hdmi"];

/// `'G6DS'` (`0x53443647`) — presence detect at the 64-byte window.
pub const G6DS_MAGIC: u32 = 0x5344_3647;
pub const G6DS_REV: u32 = 1;
pub const G6DS_OFF_MAGIC: u8 = 0x00;
pub const G6DS_OFF_REV: u8 = 0x04;
pub const G6DS_OFF_CTRL: u8 = 0x08;
pub const G6DS_OFF_FB_LO: u8 = 0x0c;
pub const G6DS_OFF_FB_HI: u8 = 0x10;
pub const G6DS_OFF_WIDTH: u8 = 0x14;
pub const G6DS_OFF_HEIGHT: u8 = 0x18;
pub const G6DS_OFF_STRIDE: u8 = 0x1c;
pub const G6DS_OFF_FORMAT: u8 = 0x20;
pub const G6DS_OFF_COMMIT: u8 = 0x24;
pub const G6DS_OFF_STATUS: u8 = 0x28;
/// X8R8G8B8 little-endian.
pub const G6DS_FORMAT_X8R8G8B8: u32 = 1;

pub fn from_board(spec: &BoardSpec) -> Option<Adapter> {
    if !(spec.uncore.hdmi || spec.wants_disp_scan()) {
        return None;
    }
    Some(Adapter {
        id: "hdmi0".into(),
        class: AdapterClass::Display,
        kind: AdapterKind::Hdmi,
        vendor: "g6lc-scanout".into(),
        features: vec!["g6ds".into()],
        transport: "mmio".into(),
        device_id: None,
        slot: None,
        mmio: spec
            .display_ctrl()
            .map(|b| format!("{b:#x}"))
            .unwrap_or_default(),
    })
}
