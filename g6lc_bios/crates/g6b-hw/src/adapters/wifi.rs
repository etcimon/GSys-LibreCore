// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Wifi catalog (no vendor id yet — `none`). Isolated session only.

use g6b_spec::BoardSpec;

use crate::{Adapter, AdapterClass, AdapterKind};

pub fn from_board(spec: &BoardSpec) -> Option<Adapter> {
    if !spec.kernel.hw.wifi {
        return None;
    }
    Some(Adapter {
        id: "wlan0".into(),
        class: AdapterClass::Net,
        kind: AdapterKind::Wifi,
        vendor: "none".into(),
        features: Vec::new(),
        transport: String::new(),
        device_id: None,
        slot: None,
        mmio: String::new(),
    })
}
