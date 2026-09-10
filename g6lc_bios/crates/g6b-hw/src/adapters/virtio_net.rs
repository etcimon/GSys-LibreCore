// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! virtio-net (DeviceID 1, virtio spec 5.1). Guest IR `VioNetProbe` only.
//! Never QEMU `-netdev`.

use g6b_spec::BoardSpec;

use crate::{
    Adapter, AdapterClass, AdapterKind, VIRTIO_NET_DEVICE_ID, VIRTIO_NET_FEATURES, VIRTIO_NET_SLOT,
};

pub fn from_board(spec: &BoardSpec) -> Option<Adapter> {
    if !spec.wants_virtio_net() {
        return None;
    }
    Some(Adapter {
        id: "net0".into(),
        class: AdapterClass::Net,
        kind: AdapterKind::VirtioNet,
        vendor: "virtio".into(),
        features: VIRTIO_NET_FEATURES
            .iter()
            .map(|s| (*s).to_string())
            .collect(),
        transport: "virtio-mmio".into(),
        device_id: Some(VIRTIO_NET_DEVICE_ID),
        slot: Some(VIRTIO_NET_SLOT),
        mmio: String::new(),
    })
}
