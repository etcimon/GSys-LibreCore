// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Generic PCIe class-0x03 GPU catalog (AMD / NVIDIA / anyone else).
//! Not a modeset driver: only a firmware-initialized linear BAR is
//! accepted (`linear-fb` feature). AtomBIOS/DCN and GSP are refused.

use g6b_spec::BoardSpec;

use crate::{Adapter, AdapterClass, AdapterKind};

/// Catalog vendor names. Unknown ids fail closed in `HwSpec::check`.
pub const PCIE_GPU_VENDORS: &[&str] = &["amd", "nvidia"];

pub const PCI_VENDOR_AMD: u16 = 0x1002;
pub const PCI_VENDOR_NVIDIA: u16 = 0x10de;

pub fn vendor_id(name: &str) -> Option<u16> {
    match name {
        "amd" => Some(PCI_VENDOR_AMD),
        "nvidia" => Some(PCI_VENDOR_NVIDIA),
        _ => None,
    }
}

pub fn from_board(spec: &BoardSpec) -> Option<Adapter> {
    if !spec.wants_pci_scan() {
        return None;
    }
    Some(Adapter {
        id: "pcie0".into(),
        class: AdapterClass::Display,
        kind: AdapterKind::PcieGpu,
        vendor: String::new(),
        features: Vec::new(),
        transport: "pcie".into(),
        device_id: None,
        slot: None,
        mmio: spec
            .pcie_ecam()
            .map(|b| format!("{b:#x}"))
            .unwrap_or_default(),
    })
}
