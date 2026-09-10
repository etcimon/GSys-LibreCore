// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Uncore Ethernet MAC catalog (`architecture/uncore/ethernet-controller.md`).
//! On-die MAC + external PHY; not a host NIC.

use g6b_spec::BoardSpec;

use crate::{Adapter, AdapterClass, AdapterKind};

pub fn from_board(spec: &BoardSpec) -> Option<Adapter> {
    if !(spec.kernel.hw.ethernet || spec.uncore.ethernet) {
        return None;
    }
    Some(Adapter {
        id: "eth0".into(),
        class: AdapterClass::Net,
        kind: AdapterKind::Ethernet,
        vendor: "verilog-ethernet".into(),
        features: vec!["rgmii".into(), "1g".into(), "mdio".into()],
        transport: "axi".into(),
        device_id: None,
        slot: None,
        mmio: "0x30000000".into(),
    })
}
