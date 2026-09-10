// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! One file per catalog adapter (virtio / uncore). `from_board` is the
//! BoardSpec compile of those standards — not linked IP.

use g6b_spec::BoardSpec;

use crate::Adapter;

pub mod ethernet;
pub mod hdmi;
pub mod pcie_gpu;
pub mod usb;
pub mod virtio_gpu;
pub mod virtio_input;
pub mod virtio_net;
pub mod wifi;

/// Collect adapters the board actually asked for.
pub fn from_board(spec: &BoardSpec) -> Vec<Adapter> {
    let mut out = Vec::new();
    if let Some(a) = virtio_net::from_board(spec) {
        out.push(a);
    }
    if let Some(a) = ethernet::from_board(spec) {
        out.push(a);
    }
    if let Some(a) = wifi::from_board(spec) {
        out.push(a);
    }
    if let Some(a) = pcie_gpu::from_board(spec) {
        out.push(a);
    }
    if let Some(a) = virtio_gpu::from_board(spec) {
        out.push(a);
    }
    if let Some(a) = hdmi::from_board(spec) {
        out.push(a);
    }
    if let Some(a) = virtio_input::keyboard_from_board(spec) {
        out.push(a);
    }
    if let Some(a) = virtio_input::tablet_from_board(spec) {
        out.push(a);
    }
    if let Some(a) = usb::flash_from_board(spec) {
        out.push(a);
    }
    if let Some(a) = usb::key_from_board(spec) {
        out.push(a);
    }
    if let Some(a) = usb::hid_from_board(spec) {
        out.push(a);
    }
    out
}
