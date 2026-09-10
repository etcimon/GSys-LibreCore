// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! virtio-gpu (DeviceID 16). Scanout geometry is BoardSpec; this crate
//! never changes QEMU argv.

use g6b_spec::BoardSpec;

use crate::{Adapter, AdapterClass, AdapterKind, VIRTIO_GPU_DEVICE_ID};

pub fn from_board(spec: &BoardSpec) -> Option<Adapter> {
    if !spec.wants_virtio_gpu() {
        return None;
    }
    Some(Adapter {
        id: "gpu0".into(),
        class: AdapterClass::Display,
        kind: AdapterKind::VirtioGpu,
        vendor: "virtio".into(),
        features: vec!["version_1".into()],
        transport: "virtio-mmio".into(),
        device_id: Some(VIRTIO_GPU_DEVICE_ID),
        slot: Some(crate::VIRTIO_GPU_SLOT),
        mmio: String::new(),
    })
}
