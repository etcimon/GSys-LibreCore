// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Isolated display config. VGA is the live surface until an internal
//! probe finds an accelerated output **and** the kernel announces it.
//! Not a DRM/KMS driver: no AMD AtomBIOS/DCN, no NVIDIA GSP, no libGL.

use g6b_spec::quote_json;

use crate::inet::LinkState;

/// GLES2 path. Default off (CPU raster only). `listing` is the shader
/// contract in `g6b-gr::gl`; `host` needs a named `HwGlApply`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GlMode {
    Off,
    Listing,
    Host,
}

impl GlMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Listing => "listing",
            Self::Host => "host",
        }
    }

    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "off" | "none" => Ok(Self::Off),
            "listing" | "gles2" | "on" => Ok(Self::Listing),
            "host" => Ok(Self::Host),
            other => Err(format!("unknown gl mode `{other}`")),
        }
    }
}

/// Where dirty Canvas32 tiles go. Chosen by the display probe, not by vendor.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PresentKind {
    /// VGA / not probed / demoted.
    None,
    /// virtio-gpu CREATE/ATTACH/SCANOUT/TRANSFER/FLUSH.
    Virtio2d,
    /// Uncore G6DS MMIO (`architecture/uncore/hdmi-display.md`).
    G6ds,
    /// PCIe class 0x03 with a firmware-initialized linear BAR.
    PciLinear,
    /// Named host GPU (opt-in `HwGlApply`).
    HostGl,
}

impl PresentKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Virtio2d => "virtio-2d",
            Self::G6ds => "g6ds",
            Self::PciLinear => "pci-linear",
            Self::HostGl => "host-gl",
        }
    }

    pub fn is_accelerated(self) -> bool {
        !matches!(self, Self::None)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DispPhase {
    Idle,
    Probe,
    Present,
    Demoted,
    None,
}

impl DispPhase {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Probe => "probe",
            Self::Present => "present",
            Self::Demoted => "demoted",
            Self::None => "none",
        }
    }
}

/// Per-session display shadow. Scanout stays VGA until probe + announce.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DispCfg {
    pub surface: String,
    pub link: LinkState,
    pub w: u32,
    pub h: u32,
    pub hz: u32,
    pub gl: GlMode,
    pub present: PresentKind,
    pub winner_id: String,
    pub winner_kind: String,
    pub vendor: String,
    pub pci_id: String,
    pub probed: bool,
    pub phase: DispPhase,
}

impl Default for DispCfg {
    fn default() -> Self {
        Self {
            surface: "vga".into(),
            link: LinkState::Down,
            w: 640,
            h: 480,
            hz: 60,
            gl: GlMode::Off,
            present: PresentKind::None,
            winner_id: "vga0".into(),
            winner_kind: "vga".into(),
            vendor: String::new(),
            pci_id: String::new(),
            probed: false,
            phase: DispPhase::Idle,
        }
    }
}

impl DispCfg {
    pub fn json(&self) -> String {
        format!(
            "{{\"probed\":{},\"phase\":{},\"surface\":{},\"id\":{},\"kind\":{},\"vendor\":{},\"pci_id\":{},\"present\":{},\"gl\":{},\"link\":{},\"w\":{},\"h\":{},\"hz\":{}}}",
            if self.probed { "true" } else { "false" },
            quote_json(self.phase.as_str()),
            quote_json(&self.surface),
            quote_json(&self.winner_id),
            quote_json(&self.winner_kind),
            quote_json(&self.vendor),
            quote_json(&self.pci_id),
            quote_json(self.present.as_str()),
            quote_json(self.gl.as_str()),
            quote_json(self.link.as_str()),
            self.w,
            self.h,
            self.hz
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_vga_unprobed() {
        let d = DispCfg::default();
        assert!(!d.probed);
        assert_eq!(d.surface, "vga");
        assert_eq!(d.present, PresentKind::None);
        assert_eq!(d.gl, GlMode::Off);
        assert_eq!(GlMode::parse("listing").unwrap(), GlMode::Listing);
        assert!(GlMode::parse("opengl").is_err());
    }
}
