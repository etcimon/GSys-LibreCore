// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Hardware adapters for BIOS / host: virtio-net, SoC ethernet/wifi, display.
//!
//! Guest detection is `g6b-asm` `VioNetProbe` (virtio-mmio DeviceID 1).
//! BIOS `qemu-args` never grows `-netdev`. Linux/EDK2 virtio-net is an
//! emulator-side emit, not this crate. Vendor MACs are config-selected
//! (`architecture/uncore/ethernet-controller.md`), not linked IP.
//!
//! HTTP(S) fetch is a **kernel** abstraction (`g6b-http` / `g6b-tls`) that
//! lowers onto this crate's TCP/IP sockets. This crate does not speak TLS
//! or HTTPS.
//!
//! **Post-boot lazy state:** `HwSession` is idle until a JS/wasm/HolyC
//! function (`hwListen` / `hwConfig` / …) runs. It is not started from
//! `_start`. Live state is interned as **`platform.hw`** (HolyC-shaped),
//! never a top-level `window.hw` and never in an iframe. A listen worker
//! parks on a message queue; UI wakes and ethernet cable events are
//! equal. JS/wasm `await hwConfig` throws without exiting that worker.
//! HolyC always returns instantly. Net devices take Linux-like inet
//! (`ip addr` / `ip link` / `ip route` / TCP+UDP enable). Default
//! addressing is NAT **minimal**. Isolated NAT (`10.0.2.15/24`) and
//! real TCP/UDP sockets are opt-in; host NIC apply is explicit on a
//! **named** adapter. Display stays **VGA** until an internal probe
//! finds virtio-gpu / HDMI / a linear PCIe FB **and** that winner is
//! announced. Nothing here mutates QEMU argv.

#![allow(missing_docs)]

mod adapters;
mod call;
mod disp;
mod event;
mod host_gl;
mod host_nic;
mod inet;
mod net;
mod pkt;
mod session;
mod stack;

use g6b_spec::{parse_json, BoardSpec, Json};

pub use adapters::hdmi::{
    G6DS_FORMAT_X8R8G8B8, G6DS_MAGIC, G6DS_OFF_COMMIT, G6DS_OFF_CTRL, G6DS_OFF_FB_HI,
    G6DS_OFF_FB_LO, G6DS_OFF_FORMAT, G6DS_OFF_HEIGHT, G6DS_OFF_MAGIC, G6DS_OFF_REV,
    G6DS_OFF_STATUS, G6DS_OFF_STRIDE, G6DS_OFF_WIDTH, G6DS_REV, HDMI_VENDORS,
};
pub use adapters::pcie_gpu::{
    vendor_id as pcie_gpu_vendor_id, PCIE_GPU_VENDORS, PCI_VENDOR_AMD, PCI_VENDOR_NVIDIA,
};
pub use call::{call, call_instant, eval, eval_instant, is_hw_invoke, parse_invoke, HwError};
pub use disp::{DispCfg, DispPhase, GlMode, PresentKind};
pub use event::{
    is_hw_event_type, HwEvent, HW_EVENT, HW_EVENT_CABLE, HW_EVENT_CONFIG, HW_EVENT_DISP,
    HW_EVENT_NAT, HW_EVENT_NET, HW_EVENT_WAKE,
};
pub use host_gl::{list_gpus, list_json as gl_list_json, HostGpu};
pub use host_nic::{list_adapters, list_json, HostAdapter};
pub use inet::{
    looks_like_ipv4, parse_cidr, InetCfg, LinkState, TcpCfg, UdpCfg, NAT_DNS, NAT_GATEWAY,
    NAT_LEASE, NAT_NETWORK, NAT_PREFIX,
};
pub use net::VIRTIO_NET_FEATURES;
pub use pkt::{
    dns_gateway, encapsulate_dns_a, encapsulate_seq, encapsulate_tcp, icmp_frag_needed,
    ip_fragment, ip_is_fragment, is_nat_dns_name, is_nat_http_host, nat_dns_a, nat_http_dst,
    nat_http_on_wire, nat_http_via_dma, IpReasm, NatHttpReasm, NatTcp, VirtioNetDma, NAT_HTTP_BODY,
    NAT_MTU, NAT_TCP_WINDOW,
};
pub use session::{
    Addressing, CableEvent, CableState, DeviceCfg, HwMsg, HwPort, HwSession, NatMode, NatPhase,
    MAX_HW_QUEUE,
};
pub use stack::{resolve_ipv4, InetStack, TcpRecv};

/// virtio-net DeviceID — must match `g6b_asm::encode::VIO_DEV_NET`.
pub const VIRTIO_NET_DEVICE_ID: u32 = 1;
/// virtio-gpu DeviceID — must match `g6b_asm::encode::VIO_DEV_GPU`.
pub const VIRTIO_GPU_DEVICE_ID: u32 = 16;
/// Exec-model / probe slot for virtio-net (PLIC irq 6).
pub const VIRTIO_NET_SLOT: u64 = 5;
/// virtio-gpu exec-model slot (PLIC irq 1).
pub const VIRTIO_GPU_SLOT: u64 = 0;
/// virtio-input DeviceID — must match `g6b_asm::encode::VIO_DEV_INPUT`.
pub const VIRTIO_INPUT_DEVICE_ID: u32 = 18;

/// Ethernet MAC catalog ids (`architecture/uncore/ethernet-controller.md`).
pub const ETHERNET_VENDORS: &[&str] =
    &["verilog-ethernet", "liteeth", "corundum", "ariane-ethernet"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AdapterClass {
    Net,
    Display,
    Input,
    Usb,
}

impl AdapterClass {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Net => "net",
            Self::Display => "display",
            Self::Input => "input",
            Self::Usb => "usb",
        }
    }

    fn parse(s: &str) -> Result<Self, String> {
        match s {
            "net" => Ok(Self::Net),
            "display" => Ok(Self::Display),
            "input" => Ok(Self::Input),
            "usb" => Ok(Self::Usb),
            other => Err(format!("unknown adapter class `{other}`")),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AdapterKind {
    VirtioNet,
    Ethernet,
    Wifi,
    VirtioGpu,
    PcieGpu,
    Hdmi,
    VirtioKeyboard,
    VirtioTablet,
    UsbHid,
    UsbKey,
    UsbMsc,
}

impl AdapterKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::VirtioNet => "virtio-net",
            Self::Ethernet => "ethernet",
            Self::Wifi => "wifi",
            Self::VirtioGpu => "virtio-gpu",
            Self::PcieGpu => "pcie-gpu",
            Self::Hdmi => "hdmi",
            Self::VirtioKeyboard => "virtio-keyboard",
            Self::VirtioTablet => "virtio-tablet",
            Self::UsbHid => "usb-hid",
            Self::UsbKey => "usb-key",
            Self::UsbMsc => "usb-msc",
        }
    }

    fn parse(s: &str) -> Result<Self, String> {
        match s {
            "virtio-net" => Ok(Self::VirtioNet),
            "ethernet" => Ok(Self::Ethernet),
            "wifi" => Ok(Self::Wifi),
            "virtio-gpu" => Ok(Self::VirtioGpu),
            "pcie-gpu" => Ok(Self::PcieGpu),
            "hdmi" | "displayport" => Ok(Self::Hdmi),
            "virtio-keyboard" => Ok(Self::VirtioKeyboard),
            "virtio-tablet" | "virtio-mouse" => Ok(Self::VirtioTablet),
            "usb-hid" => Ok(Self::UsbHid),
            "usb-key" => Ok(Self::UsbKey),
            "usb-msc" | "usb-flash" => Ok(Self::UsbMsc),
            other => Err(format!("unknown adapter kind `{other}`")),
        }
    }

    fn class(self) -> AdapterClass {
        match self {
            Self::VirtioNet | Self::Ethernet | Self::Wifi => AdapterClass::Net,
            Self::VirtioGpu | Self::PcieGpu | Self::Hdmi => AdapterClass::Display,
            Self::VirtioKeyboard | Self::VirtioTablet | Self::UsbHid => AdapterClass::Input,
            Self::UsbKey | Self::UsbMsc => AdapterClass::Usb,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Adapter {
    pub id: String,
    pub class: AdapterClass,
    pub kind: AdapterKind,
    pub vendor: String,
    pub features: Vec<String>,
    pub transport: String,
    pub device_id: Option<u32>,
    pub slot: Option<u64>,
    pub mmio: String,
}

impl Adapter {
    pub fn is_net(&self) -> bool {
        self.class == AdapterClass::Net
    }

    pub fn is_display(&self) -> bool {
        self.class == AdapterClass::Display
    }

    pub fn virtio_net_ok(&self) -> bool {
        self.kind == AdapterKind::VirtioNet
            && self.device_id == Some(VIRTIO_NET_DEVICE_ID)
            && self.transport == "virtio-mmio"
    }

    pub fn virtio_gpu_ok(&self) -> bool {
        self.kind == AdapterKind::VirtioGpu
            && self.device_id == Some(VIRTIO_GPU_DEVICE_ID)
            && self.transport == "virtio-mmio"
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct HwSpec {
    pub adapters: Vec<Adapter>,
}

impl HwSpec {
    pub fn from_json_str(s: &str) -> Result<Self, String> {
        let v = parse_json(s)?;
        Self::from_json(&v)
    }

    pub fn from_json(v: &Json) -> Result<Self, String> {
        let mut spec = HwSpec::default();
        match v.get("adapters") {
            Json::Arr(items) => {
                for item in items {
                    spec.adapters.push(adapter_from_json(item)?);
                }
            }
            Json::Null => {}
            _ => return Err("hw.adapters must be an array".into()),
        }
        spec.check()?;
        Ok(spec)
    }

    /// Infer adapters from BoardSpec (desktop/full compile the virtio-net probe).
    pub fn from_board(spec: &BoardSpec) -> Self {
        HwSpec {
            adapters: adapters::from_board(spec),
        }
    }

    pub fn check(&self) -> Result<(), String> {
        for a in &self.adapters {
            if a.kind.class() != a.class {
                return Err(format!(
                    "adapter {} kind {} is not class {}",
                    a.id,
                    a.kind.as_str(),
                    a.class.as_str()
                ));
            }
            if a.kind == AdapterKind::VirtioNet && a.device_id != Some(VIRTIO_NET_DEVICE_ID) {
                return Err("virtio-net device_id must be 1".into());
            }
            if a.kind == AdapterKind::VirtioGpu && a.device_id != Some(VIRTIO_GPU_DEVICE_ID) {
                return Err("virtio-gpu device_id must be 16".into());
            }
            if matches!(
                a.kind,
                AdapterKind::VirtioKeyboard | AdapterKind::VirtioTablet
            ) && a.device_id != Some(VIRTIO_INPUT_DEVICE_ID)
            {
                return Err("virtio-input device_id must be 18".into());
            }
            if a.kind == AdapterKind::Ethernet
                && !a.vendor.is_empty()
                && a.vendor != "none"
                && !ETHERNET_VENDORS.contains(&a.vendor.as_str())
            {
                return Err(format!("unknown ethernet vendor `{}`", a.vendor));
            }
            if a.kind == AdapterKind::Wifi && a.vendor != "none" && !a.vendor.is_empty() {
                return Err(format!(
                    "wifi vendor `{}` is not catalogued (use none)",
                    a.vendor
                ));
            }
            if a.kind == AdapterKind::Hdmi
                && !a.vendor.is_empty()
                && !HDMI_VENDORS.contains(&a.vendor.as_str())
            {
                return Err(format!("unknown hdmi vendor `{}`", a.vendor));
            }
            if a.kind == AdapterKind::PcieGpu
                && !a.vendor.is_empty()
                && !PCIE_GPU_VENDORS.contains(&a.vendor.as_str())
            {
                return Err(format!("unknown pcie-gpu vendor `{}`", a.vendor));
            }
        }
        Ok(())
    }

    pub fn net(&self) -> impl Iterator<Item = &Adapter> {
        self.adapters.iter().filter(|a| a.is_net())
    }

    pub fn virtio_net(&self) -> Option<&Adapter> {
        self.adapters
            .iter()
            .find(|a| a.kind == AdapterKind::VirtioNet)
    }

    /// Prefer virtio-net, then ethernet, then wifi.
    pub fn primary_net(&self) -> Option<&Adapter> {
        self.virtio_net()
            .or_else(|| {
                self.adapters
                    .iter()
                    .find(|a| a.kind == AdapterKind::Ethernet)
            })
            .or_else(|| self.adapters.iter().find(|a| a.kind == AdapterKind::Wifi))
    }

    pub fn display(&self) -> impl Iterator<Item = &Adapter> {
        self.adapters.iter().filter(|a| a.is_display())
    }

    pub fn virtio_gpu(&self) -> Option<&Adapter> {
        self.adapters
            .iter()
            .find(|a| a.kind == AdapterKind::VirtioGpu)
    }

    /// Catalog order matches the output ladder: PCIe linear FB, HDMI, virtio-gpu.
    pub fn primary_display(&self) -> Option<&Adapter> {
        self.adapters
            .iter()
            .find(|a| a.kind == AdapterKind::PcieGpu)
            .or_else(|| self.adapters.iter().find(|a| a.kind == AdapterKind::Hdmi))
            .or_else(|| self.virtio_gpu())
    }
}

fn adapter_from_json(v: &Json) -> Result<Adapter, String> {
    let id = v
        .get("id")
        .as_str()
        .ok_or("adapter.id required")?
        .to_string();
    let kind = AdapterKind::parse(v.get("kind").as_str().unwrap_or(""))?;
    let class = if let Some(c) = v.get("class").as_str() {
        AdapterClass::parse(c)?
    } else {
        kind.class()
    };
    let mut features = Vec::new();
    if let Json::Arr(items) = v.get("features") {
        for f in items {
            if let Some(s) = f.as_str() {
                features.push(s.to_string());
            }
        }
    }
    Ok(Adapter {
        id,
        class,
        kind,
        vendor: v.get("vendor").as_str().unwrap_or("").to_string(),
        features,
        transport: v.get("transport").as_str().unwrap_or("").to_string(),
        device_id: v.get("device_id").as_u32(),
        slot: v.get("slot").as_u32().map(u64::from),
        mmio: v.get("mmio").as_str().unwrap_or("").to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_asm::encode::{VIO_DEV_GPU, VIO_DEV_INPUT, VIO_DEV_NET, VIO_NET_SLOT};

    #[test]
    fn device_ids_match_asm_ir() {
        assert_eq!(VIRTIO_NET_DEVICE_ID, VIO_DEV_NET);
        assert_eq!(VIRTIO_GPU_DEVICE_ID, VIO_DEV_GPU);
        assert_eq!(VIRTIO_INPUT_DEVICE_ID, VIO_DEV_INPUT);
        assert_eq!(VIRTIO_NET_SLOT, VIO_NET_SLOT);
    }

    #[test]
    fn fixture_and_board_compile_virtio_net() {
        let raw = include_str!("../../../fixtures/hw-desktop.json");
        let hw = HwSpec::from_json_str(raw).unwrap();
        let net = hw.virtio_net().expect("virtio-net");
        assert!(net.virtio_net_ok());
        assert_eq!(net.slot, Some(VIRTIO_NET_SLOT));
        assert!(net.features.iter().any(|f| f == "version_1"));
        assert_eq!(hw.primary_net().unwrap().id, "net0");
        let eth = hw
            .adapters
            .iter()
            .find(|a| a.kind == AdapterKind::Ethernet)
            .unwrap();
        assert_eq!(eth.vendor, "verilog-ethernet");
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        assert!(spec.wants_virtio_net());
        let from_board = HwSpec::from_board(&spec);
        assert!(from_board.virtio_net().unwrap().virtio_net_ok());
        assert!(hw.virtio_gpu().unwrap().virtio_gpu_ok());
        assert_eq!(hw.primary_display().unwrap().kind, AdapterKind::Hdmi);
    }

    #[test]
    fn unknown_display_vendors_refused() {
        let err = HwSpec::from_json_str(
            r#"{"schema_version":1,"adapters":[{"id":"hdmi0","kind":"hdmi","vendor":"sil9022"}]}"#,
        )
        .unwrap_err();
        assert!(err.contains("unknown hdmi vendor"), "{err}");
        let err = HwSpec::from_json_str(
            r#"{"schema_version":1,"adapters":[{"id":"pcie0","kind":"pcie-gpu","vendor":"intel"}]}"#,
        )
        .unwrap_err();
        assert!(err.contains("unknown pcie-gpu vendor"), "{err}");
        let ok = HwSpec::from_json_str(
            r#"{"schema_version":1,"adapters":[{"id":"pcie0","kind":"pcie-gpu","vendor":"amd","features":["linear-fb"]}]}"#,
        )
        .unwrap();
        assert_eq!(ok.primary_display().unwrap().vendor, "amd");
    }

    #[test]
    fn unknown_ethernet_vendor_refused() {
        let err = HwSpec::from_json_str(
            r#"{"schema_version":1,"adapters":[{"id":"eth0","kind":"ethernet","vendor":"intel-e1000"}]}"#,
        )
        .unwrap_err();
        assert!(err.contains("unknown ethernet vendor"), "{err}");
    }
}
