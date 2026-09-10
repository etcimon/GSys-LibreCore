// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! virtio-input (DeviceID 18): keyboard + tablet/mouse. Catalog only;
//! QEMU argv still emitted by the kernel when `wants_virtio_input()`.

use g6b_spec::BoardSpec;

use crate::{Adapter, AdapterClass, AdapterKind, VIRTIO_INPUT_DEVICE_ID};

pub fn keyboard_from_board(spec: &BoardSpec) -> Option<Adapter> {
    if !spec.wants_virtio_input() {
        return None;
    }
    Some(Adapter {
        id: "kbd0".into(),
        class: AdapterClass::Input,
        kind: AdapterKind::VirtioKeyboard,
        vendor: "virtio".into(),
        features: vec!["version_1".into()],
        transport: "virtio-mmio".into(),
        device_id: Some(VIRTIO_INPUT_DEVICE_ID),
        slot: Some(1),
        mmio: String::new(),
    })
}

pub fn tablet_from_board(spec: &BoardSpec) -> Option<Adapter> {
    if !spec.wants_virtio_input() {
        return None;
    }
    Some(Adapter {
        id: "mouse0".into(),
        class: AdapterClass::Input,
        kind: AdapterKind::VirtioTablet,
        vendor: "virtio".into(),
        features: vec!["version_1".into(), "abs".into()],
        transport: "virtio-mmio".into(),
        device_id: Some(VIRTIO_INPUT_DEVICE_ID),
        slot: Some(3),
        mmio: String::new(),
    })
}
