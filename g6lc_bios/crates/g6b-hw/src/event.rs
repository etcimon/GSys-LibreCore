// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `HWEvent` — BIOS UI event, same intern/dispatch path as a DOM `MouseEvent`.
//! Kernel emits these; the UI maps `event.detail` onto its own nodes.

use g6b_spec::quote_json;

use crate::session::{Addressing, CableEvent, CableState, NatMode, NatPhase};

/// Generic catch-all (`addEventListener("hw", …)`).
pub const HW_EVENT: &str = "hw";
/// Ethernet cable / link.
pub const HW_EVENT_CABLE: &str = "hwcable";
/// Net adapter announced or reconfigured.
pub const HW_EVENT_NET: &str = "hwnet";
/// Display adapter announced (virtio-gpu / HDMI).
pub const HW_EVENT_DISP: &str = "hwdisp";
/// NAT phase / mode.
pub const HW_EVENT_NAT: &str = "hwnat";
/// Isolated addressing change.
pub const HW_EVENT_CONFIG: &str = "hwconfig";
/// BIOS UI wake, equal to a device event.
pub const HW_EVENT_WAKE: &str = "hwwake";

pub fn is_hw_event_type(ty: &str) -> bool {
    matches!(
        ty,
        HW_EVENT
            | HW_EVENT_CABLE
            | HW_EVENT_NET
            | HW_EVENT_DISP
            | HW_EVENT_NAT
            | HW_EVENT_CONFIG
            | HW_EVENT_WAKE
    )
}

/// One hardware event for wasm/js, interned like a DOM `Event`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HwEvent {
    pub event_type: String,
    pub adapter: String,
    pub kind: String,
    pub phase: String,
    pub addressing: String,
    pub cable: String,
    pub detail: String,
}

impl HwEvent {
    pub fn new(
        event_type: &str,
        adapter: &str,
        kind: &str,
        phase: NatPhase,
        addressing: Addressing,
        cable: CableState,
    ) -> Self {
        let mut ev = Self {
            event_type: event_type.into(),
            adapter: adapter.into(),
            kind: kind.into(),
            phase: phase.as_str().into(),
            addressing: addressing.as_str().into(),
            cable: cable.as_str().into(),
            detail: String::new(),
        };
        ev.detail = ev.json();
        ev
    }

    pub fn cable(
        ev: CableEvent,
        adapter: &str,
        kind: &str,
        phase: NatPhase,
        addressing: Addressing,
        cable: CableState,
    ) -> Self {
        let mut e = Self::new(HW_EVENT_CABLE, adapter, kind, phase, addressing, cable);
        e.detail = format!(
            "{{\"type\":\"hwcable\",\"event\":{},\"adapter\":{},\"kind\":{},\"phase\":{},\"cable\":{}}}",
            quote_json(ev.as_str()),
            quote_json(adapter),
            quote_json(kind),
            quote_json(phase.as_str()),
            quote_json(cable.as_str())
        );
        e
    }

    pub fn nat(mode: NatMode, phase: NatPhase) -> Self {
        let mut e = Self::new(
            HW_EVENT_NAT,
            "",
            "",
            phase,
            Addressing::Nat,
            CableState::Unplugged,
        );
        e.detail = format!(
            "{{\"type\":\"hwnat\",\"nat\":{},\"phase\":{}}}",
            quote_json(mode.as_str()),
            quote_json(phase.as_str())
        );
        e
    }

    fn json(&self) -> String {
        format!(
            "{{\"type\":{},\"adapter\":{},\"kind\":{},\"phase\":{},\"addressing\":{},\"cable\":{}}}",
            quote_json(&self.event_type),
            quote_json(&self.adapter),
            quote_json(&self.kind),
            quote_json(&self.phase),
            quote_json(&self.addressing),
            quote_json(&self.cable)
        )
    }
}
