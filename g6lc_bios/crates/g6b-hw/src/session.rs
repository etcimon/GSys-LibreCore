// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Isolated adapter session + the message queue that accompanies a listen
//! worker. UI wakes and ethernet cable events share that queue. The worker
//! idles (blocked) until a message. Default NAT is **minimal**. Host NIC
//! programming is opt-in (`HwHostApply`); QEMU argv never grows `-netdev`.

use std::collections::{BTreeMap, VecDeque};

use g6b_spec::{quote_json, BoardSpec};

use crate::disp::{DispCfg, DispPhase, GlMode, PresentKind};
use crate::event::{
    HwEvent, HW_EVENT, HW_EVENT_CONFIG, HW_EVENT_DISP, HW_EVENT_NET, HW_EVENT_WAKE,
};
use crate::host_gl;
use crate::host_nic;
use crate::inet::{
    check_static, in_subnet, looks_like_ipv4, parse_cidr, InetCfg, LinkState, NAT_DNS, NAT_GATEWAY,
    NAT_LEASE, NAT_PREFIX,
};
use crate::stack::InetStack;
use crate::{Adapter, AdapterKind, HwSpec};

/// Bounded queue that accompanies one listen worker.
pub const MAX_HW_QUEUE: usize = 16;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NatMode {
    /// Default. Status only; no sockets, no host NIC.
    Minimal,
    /// Userspace NAT (10.0.2.0/24 slirp-shaped) via host sockets. No QEMU `-netdev`.
    Isolated,
    /// Isolated NAT plus opt-in host NIC programming (`HwHostApply`).
    Host,
}

impl NatMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Minimal => "minimal",
            Self::Isolated => "isolated",
            Self::Host => "host",
        }
    }

    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "minimal" => Ok(Self::Minimal),
            "isolated" => Ok(Self::Isolated),
            "host" | "full" => Ok(Self::Host),
            other => Err(format!("unknown nat mode `{other}`")),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NatPhase {
    Idle,
    Discover,
    Offer,
    Ack,
    Established,
    Failed,
}

impl NatPhase {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Discover => "discover",
            Self::Offer => "offer",
            Self::Ack => "ack",
            Self::Established => "established",
            Self::Failed => "failed",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CableState {
    Unplugged,
    Plugged,
}

impl CableState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unplugged => "unplugged",
            Self::Plugged => "plugged",
        }
    }
}

/// Per-adapter addressing in the isolated session (not the OS NIC).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Addressing {
    Nat,
    Static,
}

impl Addressing {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Nat => "nat",
            Self::Static => "static",
        }
    }

    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "nat" | "NAT" => Ok(Self::Nat),
            "static" | "Static" => Ok(Self::Static),
            other => Err(format!("unknown addressing `{other}`")),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceCfg {
    pub addressing: Addressing,
    pub ip: String,
    /// Linux-like inet4/TCP/UDP shadow (not the host NIC).
    pub inet: InetCfg,
}

impl Default for DeviceCfg {
    fn default() -> Self {
        Self {
            addressing: Addressing::Nat,
            ip: String::new(),
            inet: InetCfg::default(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CableEvent {
    Inserted,
    Removed,
    LinkUp,
    LinkDown,
}

impl CableEvent {
    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "inserted" => Ok(Self::Inserted),
            "removed" => Ok(Self::Removed),
            "up" | "link-up" => Ok(Self::LinkUp),
            "down" | "link-down" => Ok(Self::LinkDown),
            other => Err(format!("unknown cable event `{other}`")),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Inserted => "inserted",
            Self::Removed => "removed",
            Self::LinkUp => "up",
            Self::LinkDown => "down",
        }
    }
}

/// One wake for the listen worker. Device and BIOS UI are equal sources.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HwMsg {
    Cable(CableEvent),
    UiWake,
    Config {
        nat: NatMode,
    },
    /// Async device reconfigure (static IP vs NAT). Result fills an await slot.
    Reconfigure {
        id: String,
        addressing: Addressing,
        ip: String,
        token: u32,
    },
}

impl HwMsg {
    pub fn source(&self) -> &'static str {
        match self {
            Self::Cable(_) => "device",
            Self::UiWake | Self::Config { .. } | Self::Reconfigure { .. } => "ui",
        }
    }
}

/// Isolated hardware session. `env_untouched` stays true until host apply.
#[derive(Debug)]
pub struct HwSession {
    pub spec: HwSpec,
    mode: NatMode,
    phase: NatPhase,
    cable: CableState,
    listening: bool,
    env_untouched: bool,
    queue: VecDeque<HwMsg>,
    last_src: &'static str,
    dropped: u32,
    devices: BTreeMap<String, DeviceCfg>,
    awaits: BTreeMap<u32, Option<String>>,
    next_await: u32,
    /// Kernel has emitted HW-NET / HW-DISP / VIRTIO-NET lines.
    announced: bool,
    events: VecDeque<HwEvent>,
    /// Live scanout surface name (`vga` / `gpu`). Stays VGA until probe + announce.
    scanout: String,
    disp: DispCfg,
    stack: InetStack,
    host_adapter: String,
    host_gl_adapter: String,
    board: Option<BoardSpec>,
    pointer_x: i32,
    pointer_y: i32,
    pointer_buttons: u8,
}

impl HwSession {
    pub fn from_hw(spec: HwSpec) -> Self {
        let mut devices = BTreeMap::new();
        for a in spec.net() {
            devices.insert(a.id.clone(), DeviceCfg::default());
        }
        Self {
            spec,
            mode: NatMode::Minimal,
            phase: NatPhase::Idle,
            cable: CableState::Unplugged,
            listening: false,
            env_untouched: true,
            queue: VecDeque::new(),
            last_src: "idle",
            dropped: 0,
            devices,
            awaits: BTreeMap::new(),
            next_await: 1,
            announced: false,
            events: VecDeque::new(),
            scanout: "vga".into(),
            disp: DispCfg::default(),
            stack: InetStack::default(),
            host_adapter: String::new(),
            host_gl_adapter: String::new(),
            board: None,
            pointer_x: 0,
            pointer_y: 0,
            pointer_buttons: 0,
        }
    }

    pub fn from_board(spec: &BoardSpec) -> Self {
        let mut s = Self::from_hw(HwSpec::from_board(spec));
        s.board = Some(spec.clone());
        if spec.kernel.proxy.enable {
            s.disp.w = spec.kernel.proxy.high_w.max(640);
            s.disp.h = spec.kernel.proxy.high_h.max(480);
            s.disp.hz = if spec.kernel.proxy.fps == 0 {
                60
            } else {
                spec.kernel.proxy.fps
            };
        }
        s
    }

    /// Arm the listen worker. Idles until a queue message. Not `_start`.
    /// Internally probes display adapters; scanout stays VGA until announce.
    pub fn listen(&mut self) {
        self.listening = true;
        self.phase = NatPhase::Idle;
        self.last_src = "idle";
        self.probe_display();
    }

    pub fn listening(&self) -> bool {
        self.listening
    }

    pub fn idle(&self) -> bool {
        self.listening && self.queue.is_empty() && self.phase == NatPhase::Idle
    }

    pub fn env_untouched(&self) -> bool {
        self.env_untouched
    }

    pub fn host_adapter(&self) -> &str {
        &self.host_adapter
    }

    pub fn socks_json(&self) -> String {
        self.stack.json()
    }

    pub fn disp(&self) -> &DispCfg {
        &self.disp
    }

    pub fn display_ready(&self) -> bool {
        self.disp.probed && self.disp.present.is_accelerated()
    }

    /// Surface the kernel should switch to after announce. VGA until present.
    pub fn probed_surface(&self) -> &'static str {
        if self.display_ready() {
            "gpu"
        } else {
            "vga"
        }
    }

    fn refresh_env(&mut self) {
        self.env_untouched = self.host_adapter.is_empty() && self.host_gl_adapter.is_empty();
    }

    /// Internal probe: PCIe linear-fb > HDMI G6DS > virtio-gpu > VGA.
    /// Does not change the live scanout (VGA until announce).
    pub fn probe_display(&mut self) {
        if self.disp.probed {
            return;
        }
        self.disp.probed = true;
        self.disp.phase = DispPhase::Probe;
        let adapters: Vec<Adapter> = self.spec.display().cloned().collect();
        let pcie = adapters.iter().find(|a| a.kind == AdapterKind::PcieGpu);
        let hdmi = adapters.iter().find(|a| a.kind == AdapterKind::Hdmi);
        let vio = adapters.iter().find(|a| a.kind == AdapterKind::VirtioGpu);
        if let Some(a) = pcie {
            self.disp.vendor = a.vendor.clone();
            if a.features.iter().any(|f| f == "linear-fb") {
                self.set_disp_winner(a, PresentKind::PciLinear);
                return;
            }
            self.disp.phase = DispPhase::Demoted;
        }
        if let Some(a) = hdmi {
            self.set_disp_winner(a, PresentKind::G6ds);
            return;
        }
        if let Some(a) = vio {
            self.set_disp_winner(a, PresentKind::Virtio2d);
            return;
        }
        if self.disp.phase != DispPhase::Demoted {
            self.disp.phase = DispPhase::None;
        }
        self.disp.present = PresentKind::None;
        self.disp.winner_id = "vga0".into();
        self.disp.winner_kind = "vga".into();
        self.disp.link = LinkState::Down;
    }

    fn set_disp_winner(&mut self, a: &Adapter, present: PresentKind) {
        self.disp.winner_id = a.id.clone();
        self.disp.winner_kind = a.kind.as_str().into();
        self.disp.vendor = a.vendor.clone();
        self.disp.present = present;
        self.disp.phase = DispPhase::Present;
        self.disp.link = LinkState::Up;
        if a.kind == AdapterKind::PcieGpu {
            if let Some(id) = crate::pcie_gpu_vendor_id(&a.vendor) {
                self.disp.pci_id = format!("{id:04x}");
            }
        }
    }

    pub fn apply_disp_link(&mut self, state: &str) -> Result<String, String> {
        self.probe_display();
        let link = LinkState::parse(state)?;
        if !self.display_ready() && link == LinkState::Up {
            return Err("no accelerated display to bring up".into());
        }
        self.disp.link = link;
        Ok(self.disp.json())
    }

    pub fn apply_disp_mode(&mut self, mode: &str) -> Result<String, String> {
        self.probe_display();
        let mode = mode.trim();
        let (wh, hz) = mode.split_once('@').unwrap_or((mode, ""));
        let (w, h) = wh.split_once('x').ok_or("mode needs WxH or WxH@Hz")?;
        let w: u32 = w.parse().map_err(|_| "mode width")?;
        let h: u32 = h.parse().map_err(|_| "mode height")?;
        if w < 640 || h < 480 || w > 7680 || h > 4320 {
            return Err("mode out of 640x480..=7680x4320".into());
        }
        self.disp.w = w;
        self.disp.h = h;
        if !hz.is_empty() {
            let hz: u32 = hz.parse().map_err(|_| "mode hz")?;
            if !matches!(hz, 30 | 60 | 100 | 120 | 144) {
                return Err("mode hz must be 30/60/100/120/144".into());
            }
            self.disp.hz = hz;
        }
        Ok(self.disp.json())
    }

    pub fn apply_disp_surface(&mut self, surface: &str) -> Result<String, String> {
        self.probe_display();
        match surface {
            "vga" => {
                self.disp.surface = "vga".into();
                self.scanout = "vga".into();
            }
            "gpu" => {
                if !self.display_ready() {
                    return Err("gpu surface needs a probed accelerated output".into());
                }
                self.disp.surface = "gpu".into();
                self.scanout = "gpu".into();
            }
            other => return Err(format!("surface `{other}` must be vga or gpu")),
        }
        Ok(self.disp.json())
    }

    pub fn apply_gl(&mut self, mode: &str) -> Result<String, String> {
        self.probe_display();
        let gl = GlMode::parse(mode)?;
        if gl == GlMode::Host && self.host_gl_adapter.is_empty() {
            return Err("gl=host needs HwGlApply on a named GPU".into());
        }
        if gl != GlMode::Off && !self.display_ready() {
            return Err("gl needs a probed accelerated output".into());
        }
        self.disp.gl = gl;
        if gl == GlMode::Host {
            self.disp.present = PresentKind::HostGl;
        }
        Ok(self.disp.json())
    }

    pub fn gl_list(&self) -> Result<String, String> {
        host_gl::list_json()
    }

    pub fn gl_apply(&mut self, name: &str) -> Result<String, String> {
        self.probe_display();
        if !self.display_ready() {
            return Err("gl apply needs a probed accelerated output".into());
        }
        let out = host_gl::apply(name)?;
        self.host_gl_adapter = name.trim().into();
        self.disp.gl = GlMode::Host;
        self.disp.present = PresentKind::HostGl;
        self.refresh_env();
        Ok(out)
    }

    pub fn gl_revert(&mut self) -> Result<String, String> {
        let name = self.host_gl_adapter.clone();
        if name.is_empty() {
            return Err("no host GPU applied".into());
        }
        let out = host_gl::revert(&name)?;
        self.host_gl_adapter.clear();
        self.disp.gl = GlMode::Listing;
        if self.disp.winner_kind == "hdmi" {
            self.disp.present = PresentKind::G6ds;
        } else if self.disp.winner_kind == "pcie-gpu" {
            self.disp.present = PresentKind::PciLinear;
        } else if self.disp.winner_kind == "virtio-gpu" {
            self.disp.present = PresentKind::Virtio2d;
        }
        self.refresh_env();
        Ok(out)
    }

    pub fn mode(&self) -> NatMode {
        self.mode
    }

    pub fn phase(&self) -> NatPhase {
        self.phase
    }

    pub fn cable(&self) -> CableState {
        self.cable
    }

    pub fn queued(&self) -> usize {
        self.queue.len()
    }

    /// Enqueue a device or UI message. Equal: both wake the idle worker.
    /// Returns true if the listen worker should be woken from blocked.
    pub fn push(&mut self, msg: HwMsg) -> bool {
        if self.queue.len() >= MAX_HW_QUEUE {
            self.dropped = self.dropped.saturating_add(1);
            return false;
        }
        let wake = self.idle();
        self.queue.push_back(msg);
        wake || self.listening
    }

    /// Worker tick: one message, or none if idle.
    pub fn drain_one(&mut self) -> Option<HwMsg> {
        let msg = self.queue.pop_front()?;
        self.last_src = msg.source();
        match &msg {
            HwMsg::Cable(ev) => {
                self.apply_cable(*ev);
                let (id, kind) = self.primary_net_id_kind();
                self.push_event(HwEvent::cable(
                    *ev,
                    &id,
                    &kind,
                    self.phase,
                    self.primary_addressing(),
                    self.cable,
                ));
            }
            HwMsg::UiWake => {
                self.apply_ui_wake();
                self.push_event(HwEvent::new(
                    HW_EVENT_WAKE,
                    "",
                    "",
                    self.phase,
                    self.primary_addressing(),
                    self.cable,
                ));
            }
            HwMsg::Config { nat } => {
                self.mode = *nat;
                self.push_event(HwEvent::nat(self.mode, self.phase));
            }
            HwMsg::Reconfigure {
                id,
                addressing,
                ip,
                token,
            } => {
                let out = match self.apply_reconfigure(id, *addressing, ip) {
                    Ok(v) => v,
                    Err(e) => format!("err:{e}"),
                };
                self.awaits.insert(*token, Some(out));
                let kind = self
                    .spec
                    .adapters
                    .iter()
                    .find(|a| a.id == *id)
                    .map(|a| a.kind.as_str().to_string())
                    .unwrap_or_default();
                self.push_event(HwEvent::new(
                    HW_EVENT_CONFIG,
                    id,
                    &kind,
                    self.phase,
                    *addressing,
                    self.cable,
                ));
            }
        }
        Some(msg)
    }

    pub fn drain_n(&mut self, n: usize) -> usize {
        let mut k = 0;
        while k < n && self.drain_one().is_some() {
            k += 1;
        }
        k
    }

    fn apply_cable(&mut self, ev: CableEvent) {
        match ev {
            CableEvent::Inserted | CableEvent::LinkUp => {
                self.cable = CableState::Plugged;
                if self.listening {
                    self.phase = NatPhase::Discover;
                }
                let ids: Vec<String> = self.spec.net().map(|a| a.id.clone()).collect();
                for id in ids {
                    if let Ok(cfg) = self.net_cfg_mut(&id) {
                        cfg.inet.link = LinkState::Up;
                    }
                    self.maybe_assign_nat(&id);
                }
            }
            CableEvent::Removed | CableEvent::LinkDown => {
                self.cable = CableState::Unplugged;
                self.phase = NatPhase::Idle;
            }
        }
    }

    fn apply_ui_wake(&mut self) {
        if self.cable == CableState::Plugged {
            self.advance_nat();
        }
    }

    fn advance_nat(&mut self) {
        self.phase = match self.phase {
            NatPhase::Idle | NatPhase::Failed => NatPhase::Discover,
            NatPhase::Discover => NatPhase::Offer,
            NatPhase::Offer => NatPhase::Ack,
            NatPhase::Ack | NatPhase::Established => NatPhase::Established,
        };
    }

    pub fn apply_settings(&mut self, nat: &str) -> Result<(), String> {
        self.mode = NatMode::parse(nat)?;
        if matches!(self.mode, NatMode::Isolated | NatMode::Host) {
            let ids: Vec<String> = self.spec.net().map(|a| a.id.clone()).collect();
            for id in ids {
                self.maybe_assign_nat(&id);
            }
        }
        Ok(())
    }

    pub fn device(&self, id: &str) -> Option<&DeviceCfg> {
        self.devices.get(id)
    }

    fn net_cfg_mut(&mut self, id: &str) -> Result<&mut DeviceCfg, String> {
        self.devices
            .get_mut(id)
            .ok_or_else(|| "unknown adapter".into())
    }

    /// `ip addr add CIDR dev ID` (isolated). Sets static addressing.
    pub fn apply_ifconfig(&mut self, id: &str, cidr: &str) -> Result<String, String> {
        let (addr, prefix) = parse_cidr(cidr)?;
        check_static(&addr, prefix)?;
        let cfg = self.net_cfg_mut(id)?;
        cfg.addressing = Addressing::Static;
        cfg.ip = addr.clone();
        cfg.inet.addr = addr;
        cfg.inet.prefix = prefix;
        if !cfg.inet.gateway.is_empty() && !in_subnet(&cfg.inet.addr, &cfg.inet.gateway, prefix) {
            cfg.inet.gateway.clear();
        }
        Ok(self.inet_json(id))
    }

    /// `ip route add default via GW` (isolated).
    pub fn apply_route(&mut self, id: &str, dest: &str, via: &str) -> Result<String, String> {
        if dest != "default" && dest != "0.0.0.0/0" {
            return Err("only default route is modelled".into());
        }
        if !looks_like_ipv4(via) {
            return Err("gateway needs an IPv4 address".into());
        }
        let cfg = self.net_cfg_mut(id)?;
        if !cfg.inet.addr.is_empty() && !in_subnet(&cfg.inet.addr, via, cfg.inet.prefix) {
            return Err("gateway is not in the interface subnet".into());
        }
        cfg.inet.gateway = via.into();
        Ok(self.inet_json(id))
    }

    /// `ip link set dev ID up|down`.
    pub fn apply_link(&mut self, id: &str, state: &str) -> Result<String, String> {
        let link = LinkState::parse(state)?;
        {
            let cfg = self.net_cfg_mut(id)?;
            cfg.inet.link = link;
        }
        if link == LinkState::Up {
            self.maybe_assign_nat(id);
        }
        Ok(self.inet_json(id))
    }

    /// `/etc/resolv.conf` nameserver (replace with one IPv4).
    pub fn apply_dns(&mut self, id: &str, ns: &str) -> Result<String, String> {
        if !looks_like_ipv4(ns) {
            return Err("nameserver needs an IPv4 address".into());
        }
        let cfg = self.net_cfg_mut(id)?;
        cfg.inet.nameservers = vec![ns.into()];
        Ok(self.inet_json(id))
    }

    /// Enable/disable the isolated TCP or UDP stack on the device.
    pub fn apply_proto(&mut self, id: &str, proto: &str, on: &str) -> Result<String, String> {
        let enable = match on {
            "on" | "up" | "1" | "true" => true,
            "off" | "down" | "0" | "false" => false,
            other => return Err(format!("proto enable `{other}` unknown")),
        };
        let cfg = self.net_cfg_mut(id)?;
        match proto {
            "tcp" | "TCP" => cfg.inet.tcp.enabled = enable,
            "udp" | "UDP" => cfg.inet.udp.enabled = enable,
            other => return Err(format!("unknown proto `{other}`")),
        }
        Ok(self.inet_json(id))
    }

    pub fn inet_json(&self, id: &str) -> String {
        let cfg = self.devices.get(id).cloned().unwrap_or_default();
        format!(
            "{{\"ready\":true,\"ok\":true,\"id\":{},\"addressing\":{},\"ip\":{},\"inet\":{},\"nat\":{},\"host_adapter\":{},\"socks\":{},\"listening\":{},\"env_untouched\":{}}}",
            quote_json(id),
            quote_json(cfg.addressing.as_str()),
            quote_json(&cfg.ip),
            cfg.inet.json(),
            quote_json(self.mode.as_str()),
            quote_json(&self.host_adapter),
            self.stack.json(),
            if self.listening { "true" } else { "false" },
            if self.env_untouched { "true" } else { "false" }
        )
    }

    fn maybe_assign_nat(&mut self, id: &str) {
        if !matches!(self.mode, NatMode::Isolated | NatMode::Host) {
            return;
        }
        let Some(cfg) = self.devices.get_mut(id) else {
            return;
        };
        if cfg.addressing != Addressing::Nat {
            return;
        }
        cfg.ip = NAT_LEASE.into();
        cfg.inet.addr = NAT_LEASE.into();
        cfg.inet.prefix = NAT_PREFIX;
        cfg.inet.gateway = NAT_GATEWAY.into();
        if cfg.inet.nameservers.is_empty() {
            cfg.inet.nameservers.push(NAT_DNS.into());
        }
        self.phase = NatPhase::Established;
    }

    fn bind_host(&self, id: &str) -> String {
        self.devices
            .get(id)
            .map(|c| {
                if c.addressing == Addressing::Static && looks_like_ipv4(&c.inet.addr) {
                    c.inet.addr.clone()
                } else {
                    "0.0.0.0".into()
                }
            })
            .unwrap_or_else(|| "0.0.0.0".into())
    }

    fn require_up(&self, id: &str, proto: &str) -> Result<(), String> {
        let cfg = self.devices.get(id).ok_or("unknown adapter")?;
        if cfg.inet.link != LinkState::Up {
            return Err("link is down".into());
        }
        match proto {
            "tcp" if !cfg.inet.tcp.enabled => Err("tcp disabled on device".into()),
            "udp" if !cfg.inet.udp.enabled => Err("udp disabled on device".into()),
            _ => Ok(()),
        }
    }

    fn require_stack(&self, id: &str, proto: &str) -> Result<(), String> {
        if self.mode == NatMode::Minimal {
            return Err("tcp/udp needs nat=isolated or nat=host".into());
        }
        self.require_up(id, proto)
    }

    pub fn apply_nat(&mut self, nat: &str) -> Result<String, String> {
        self.apply_settings(nat)?;
        self.push_event(HwEvent::nat(self.mode, self.phase));
        Ok(self.stat_json())
    }

    pub fn tcp_listen(&mut self, id: &str, port: u16) -> Result<String, String> {
        self.require_stack(id, "tcp")?;
        let bind = self.bind_host(id);
        let sock = self.stack.tcp_listen(id, &bind, port)?;
        Ok(format!(
            "{{\"ok\":true,\"sock\":{},\"kind\":\"tcp-listen\",\"socks\":{}}}",
            sock,
            self.stack.json()
        ))
    }

    pub fn tcp_connect(&mut self, id: &str, host: &str, port: u16) -> Result<String, String> {
        let sock = self.tcp_connect_sock(id, host, port)?;
        Ok(format!(
            "{{\"ok\":true,\"sock\":{},\"kind\":\"tcp\",\"socks\":{}}}",
            sock,
            self.stack.json()
        ))
    }

    /// Kernel fetch path: connect and return the socket id (not JSON).
    pub fn tcp_connect_sock(&mut self, id: &str, host: &str, port: u16) -> Result<u32, String> {
        self.require_stack(id, "tcp")?;
        self.stack.tcp_connect(id, host, port)
    }

    pub fn tcp_send_bytes(&mut self, sock: u32, data: &[u8]) -> Result<usize, String> {
        self.stack.tcp_send_bytes(sock, data)
    }

    pub fn tcp_recv_bytes(&mut self, sock: u32) -> Result<Vec<u8>, String> {
        self.stack.tcp_recv_bytes(sock)
    }

    pub fn apply_pointer(&mut self, x: i32, y: i32, buttons: u8) -> String {
        self.pointer_x = x;
        self.pointer_y = y;
        self.pointer_buttons = buttons;
        format!("{{\"ok\":true,\"x\":{x},\"y\":{y},\"buttons\":{buttons}}}")
    }

    pub fn pointer(&self) -> (i32, i32, u8) {
        (self.pointer_x, self.pointer_y, self.pointer_buttons)
    }

    pub fn usb_ls(&self, kind: &str) -> Result<String, String> {
        let spec = self.board.as_ref().ok_or("usb needs a board session")?;
        if !spec.kernel.usb.enable {
            return Err("usb disabled".into());
        }
        match kind {
            "flash" => {
                let ents = g6b_fs::flash_images(spec);
                Ok(format!(
                    "{{\"ok\":true,\"role\":\"flash\",\"n\":{},\"names\":[{}]}}",
                    ents.len(),
                    ents.iter()
                        .map(|e| g6b_spec::quote_json(&e.name))
                        .collect::<Vec<_>>()
                        .join(",")
                ))
            }
            "key" | "fat" | "fat32" | "ntfs" | "ext4" | "" => {
                let fs = match kind {
                    "ntfs" => Some(g6b_fs::FsKind::Ntfs),
                    "ext4" => Some(g6b_fs::FsKind::Ext4),
                    "fat" | "fat32" => Some(g6b_fs::FsKind::Fat32),
                    _ => None,
                };
                let ents = g6b_fs::list_key(spec, "/", fs);
                Ok(format!(
                    "{{\"ok\":true,\"role\":\"key\",\"n\":{},\"names\":[{}]}}",
                    ents.len(),
                    ents.iter()
                        .map(|e| g6b_spec::quote_json(&e.name))
                        .collect::<Vec<_>>()
                        .join(",")
                ))
            }
            other => Err(format!("usb ls `{other}` unknown")),
        }
    }

    pub fn usb_key(&self, op: &str) -> Result<String, String> {
        let spec = self.board.as_ref().ok_or("usb needs a board session")?;
        let present = spec.kernel.usb.enable && spec.kernel.usb.key;
        match op {
            "present" | "" => Ok(format!("{{\"ok\":true,\"present\":{present}}}")),
            other => Err(format!("usb key `{other}` unknown")),
        }
    }

    pub fn usb_flash(&self, name: &str) -> Result<String, String> {
        let spec = self.board.as_ref().ok_or("usb needs a board session")?;
        if !spec.kernel.usb.enable || !spec.kernel.usb.flash_fat32 {
            return Err("usb flash disabled".into());
        }
        let name = if name.is_empty() { "openwrt.bin" } else { name };
        let ok = g6b_fs::flash_images(spec).iter().any(|e| e.name == name);
        if ok {
            Ok(format!(
                "{{\"ok\":true,\"flashed\":true,\"name\":{}}}",
                g6b_spec::quote_json(name)
            ))
        } else {
            Err(format!("no such flash image `{name}`"))
        }
    }

    pub fn primary_net_id(&self) -> String {
        self.spec
            .primary_net()
            .map(|a| a.id.clone())
            .unwrap_or_else(|| "net0".into())
    }

    pub fn tcp_accept(&mut self, sock: u32) -> Result<String, String> {
        let id = self.stack.tcp_accept(sock)?;
        Ok(format!(
            "{{\"ok\":true,\"sock\":{},\"kind\":\"tcp\",\"socks\":{}}}",
            id,
            self.stack.json()
        ))
    }

    pub fn tcp_send(&mut self, sock: u32, data: &str) -> Result<String, String> {
        let n = self.stack.tcp_send(sock, data)?;
        Ok(format!("{{\"ok\":true,\"n\":{n}}}"))
    }

    pub fn tcp_recv(&mut self, sock: u32) -> Result<String, String> {
        let data = self.stack.tcp_recv(sock)?;
        Ok(format!("{{\"ok\":true,\"data\":{}}}", quote_json(&data)))
    }

    pub fn udp_bind(&mut self, id: &str, port: u16) -> Result<String, String> {
        self.require_stack(id, "udp")?;
        let bind = self.bind_host(id);
        let sock = self.stack.udp_bind(id, &bind, port)?;
        Ok(format!(
            "{{\"ok\":true,\"sock\":{},\"kind\":\"udp\",\"socks\":{}}}",
            sock,
            self.stack.json()
        ))
    }

    pub fn udp_send(
        &mut self,
        sock: u32,
        host: &str,
        port: u16,
        data: &str,
    ) -> Result<String, String> {
        let n = self.stack.udp_send(sock, host, port, data)?;
        Ok(format!("{{\"ok\":true,\"n\":{n}}}"))
    }

    pub fn udp_recv(&mut self, sock: u32) -> Result<String, String> {
        let data = self.stack.udp_recv(sock)?;
        Ok(format!("{{\"ok\":true,\"data\":{}}}", quote_json(&data)))
    }

    pub fn sock_close(&mut self, sock: u32) -> Result<String, String> {
        self.stack.close(sock)?;
        Ok("{\"ok\":true,\"closed\":true}".into())
    }

    pub fn host_list(&self) -> Result<String, String> {
        host_nic::list_json()
    }

    /// Program a named host adapter. Sets `env_untouched` false on success.
    pub fn host_apply(&mut self, id: &str, adapter: &str) -> Result<String, String> {
        if self.mode != NatMode::Host
            && self.devices.get(id).map(|c| c.addressing) != Some(Addressing::Static)
        {
            return Err("host apply needs nat=host or a static address".into());
        }
        let inet = self.devices.get(id).ok_or("unknown adapter")?.inet.clone();
        if inet.addr.is_empty() {
            return Err("host apply needs ifconfig/static first".into());
        }
        let out = host_nic::apply_static(adapter, &inet)?;
        self.host_adapter = adapter.trim().into();
        self.mode = NatMode::Host;
        self.refresh_env();
        Ok(out)
    }

    pub fn host_revert(&mut self) -> Result<String, String> {
        let adapter = self.host_adapter.clone();
        if adapter.is_empty() {
            return Err("no host adapter applied".into());
        }
        let out = host_nic::revert(&adapter)?;
        self.host_adapter.clear();
        self.refresh_env();
        Ok(out)
    }

    /// First post-boot use: start the idle listen worker. Not `_start`.
    pub fn ensure(&mut self) {
        if !self.listening {
            self.listen();
        }
    }

    /// Isolated reconfigure. Never programs a real NIC. Err is thrown at the
    /// JS/wasm/HolyC await; the listen worker stays up.
    pub fn apply_reconfigure(
        &mut self,
        id: &str,
        addressing: Addressing,
        ip: &str,
    ) -> Result<String, String> {
        if !self.devices.contains_key(id) {
            return Err("unknown adapter".into());
        }
        if addressing == Addressing::Static && !looks_like_ipv4(ip) {
            return Err("static addressing needs an IPv4 address".into());
        }
        let mut cfg = self.devices.get(id).cloned().unwrap_or_default();
        cfg.addressing = addressing;
        cfg.ip = if addressing == Addressing::Static {
            ip.to_string()
        } else {
            String::new()
        };
        cfg.inet.addr = cfg.ip.clone();
        if addressing == Addressing::Static {
            let prefix = if cfg.inet.prefix == 0 {
                24
            } else {
                cfg.inet.prefix
            };
            check_static(&cfg.ip, prefix)?;
            cfg.inet.prefix = prefix;
        }
        self.devices.insert(id.to_string(), cfg.clone());
        if addressing == Addressing::Nat {
            if self.mode == NatMode::Minimal {
                self.mode = NatMode::Isolated;
            }
            self.maybe_assign_nat(id);
        }
        let cfg = self.devices.get(id).cloned().unwrap_or(cfg);
        Ok(format!(
            "{{\"ready\":true,\"ok\":true,\"id\":{},\"addressing\":{},\"ip\":{},\"nat\":{},\"listening\":{},\"env_untouched\":{}}}",
            quote_json(id),
            quote_json(cfg.addressing.as_str()),
            quote_json(&cfg.ip),
            quote_json(self.mode.as_str()),
            if self.listening { "true" } else { "false" },
            if self.env_untouched { "true" } else { "false" }
        ))
    }

    /// Enqueue a reconfigure and drain it on the listen worker. Await value
    /// or throw; worker is not exited.
    pub fn await_reconfigure(
        &mut self,
        id: &str,
        addressing: Addressing,
        ip: &str,
    ) -> Result<String, String> {
        self.ensure();
        let token = self.next_await;
        self.next_await = self.next_await.saturating_add(1);
        self.awaits.insert(token, None);
        let _ = self.push(HwMsg::Reconfigure {
            id: id.into(),
            addressing,
            ip: ip.into(),
            token,
        });
        let _ = self.drain_one();
        match self.take_await(token) {
            Some(v) if v.starts_with("err:") => Err(v.trim_start_matches("err:").into()),
            Some(v) => Ok(v),
            None => Err("hw await missing".into()),
        }
    }

    pub fn take_await(&mut self, token: u32) -> Option<String> {
        self.awaits.remove(&token).flatten()
    }

    pub fn peek_await(&self, token: u32) -> Option<&Option<String>> {
        self.awaits.get(&token)
    }

    pub fn status_line(&self) -> String {
        format!(
            "hw nat={} phase={} cable={} src={} q={} env={}",
            self.mode.as_str(),
            self.phase.as_str(),
            self.cable.as_str(),
            self.last_src,
            self.queue.len(),
            if self.env_untouched {
                "untouched"
            } else {
                "host"
            }
        )
    }

    pub fn stat_json(&self) -> String {
        let adapters: Vec<String> = self
            .spec
            .net()
            .map(|a| {
                let cfg = self.devices.get(&a.id).cloned().unwrap_or_default();
                format!(
                    "{{\"id\":{},\"kind\":{},\"addressing\":{},\"ip\":{},\"inet\":{}}}",
                    quote_json(&a.id),
                    quote_json(a.kind.as_str()),
                    quote_json(cfg.addressing.as_str()),
                    quote_json(&cfg.ip),
                    cfg.inet.json()
                )
            })
            .collect();
        format!(
            "{{\"ready\":true,\"listening\":{},\"idle\":{},\"nat\":{},\"phase\":{},\"cable\":{},\"src\":{},\"queued\":{},\"dropped\":{},\"line\":{},\"env_untouched\":{},\"host_adapter\":{},\"socks\":{},\"display\":{},\"adapters\":[{}]}}",
            if self.listening { "true" } else { "false" },
            if self.idle() { "true" } else { "false" },
            quote_json(self.mode.as_str()),
            quote_json(self.phase.as_str()),
            quote_json(self.cable.as_str()),
            quote_json(self.last_src),
            self.queue.len(),
            self.dropped,
            quote_json(&self.status_line()),
            if self.env_untouched { "true" } else { "false" },
            quote_json(&self.host_adapter),
            self.stack.json(),
            self.disp.json(),
            adapters.join(",")
        )
    }

    /// True when a net adapter is in the isolated catalog.
    pub fn has_net(&self) -> bool {
        self.spec.net().next().is_some()
    }

    /// True when a display adapter is in the catalog (not yet probed).
    pub fn has_display(&self) -> bool {
        self.spec.display().next().is_some()
    }

    pub fn support_announced(&self) -> bool {
        self.announced
    }

    pub fn scanout(&self) -> &str {
        &self.scanout
    }

    pub fn set_scanout(&mut self, surface: &str) {
        if surface == "vga" || surface == "gpu" {
            self.scanout = surface.into();
            self.disp.surface = surface.into();
        }
    }

    pub fn mark_announced(&mut self) {
        if self.announced {
            return;
        }
        self.announced = true;
        self.emit_support_events();
    }

    fn primary_net_id_kind(&self) -> (String, String) {
        self.spec
            .primary_net()
            .map(|a| (a.id.clone(), a.kind.as_str().to_string()))
            .unwrap_or_default()
    }

    fn primary_addressing(&self) -> Addressing {
        self.spec
            .primary_net()
            .and_then(|a| self.devices.get(&a.id))
            .map(|c| c.addressing)
            .unwrap_or(Addressing::Nat)
    }

    fn push_event(&mut self, ev: HwEvent) {
        if self.events.len() >= MAX_HW_QUEUE {
            self.dropped = self.dropped.saturating_add(1);
            return;
        }
        self.events.push_back(ev);
    }

    /// Drain HWEvents for the BIOS UI (wasm/js), like a batch of MouseEvents.
    pub fn take_events(&mut self) -> Vec<HwEvent> {
        self.events.drain(..).collect()
    }

    fn emit_support_events(&mut self) {
        let nets: Vec<(String, String, Addressing)> = self
            .spec
            .net()
            .map(|a| {
                let addressing = self
                    .devices
                    .get(&a.id)
                    .map(|c| c.addressing)
                    .unwrap_or(Addressing::Nat);
                (a.id.clone(), a.kind.as_str().to_string(), addressing)
            })
            .collect();
        let displays: Vec<(String, String)> = self
            .spec
            .adapters
            .iter()
            .filter(|a| a.class == crate::AdapterClass::Display)
            .map(|a| (a.id.clone(), a.kind.as_str().to_string()))
            .collect();
        let phase = self.phase;
        let cable = self.cable;
        let addressing = self.primary_addressing();
        let mode = self.mode;
        for (id, kind, addr) in nets {
            self.push_event(HwEvent::new(HW_EVENT_NET, &id, &kind, phase, addr, cable));
        }
        for (id, kind) in displays {
            self.push_event(HwEvent::new(
                HW_EVENT_DISP,
                &id,
                &kind,
                phase,
                Addressing::Nat,
                cable,
            ));
        }
        self.push_event(HwEvent::new(HW_EVENT, "", "", phase, addressing, cable));
        self.push_event(HwEvent::nat(mode, phase));
    }

    /// Lines the kernel emits so display / net support is visible.
    /// Does not mutate QEMU argv or the OS NIC.
    pub fn support_lines(&self) -> Vec<String> {
        let mut lines = Vec::new();
        match self.spec.virtio_net() {
            Some(net) => {
                let slot = net.slot.unwrap_or(crate::VIRTIO_NET_SLOT);
                lines.push(format!("VIRTIO-NET {slot}"));
            }
            None => lines.push("VIRTIO-NET-NONE".into()),
        }
        for a in self.spec.net() {
            let mut line = format!("HW-NET {} {}", a.id, a.kind.as_str());
            if let Some(slot) = a.slot {
                line.push_str(&format!(" slot={slot}"));
            }
            lines.push(line);
        }
        match self.spec.virtio_gpu() {
            Some(gpu) => {
                let slot = gpu.slot.unwrap_or(crate::VIRTIO_GPU_SLOT);
                lines.push(format!("VIRTIO-GPU {slot}"));
            }
            None => lines.push("VIRTIO-GPU-NONE".into()),
        }
        for a in self.spec.display() {
            lines.push(format!("HW-DISP {} {}", a.id, a.kind.as_str()));
        }
        if self.disp.probed {
            let has_pcie = self
                .spec
                .adapters
                .iter()
                .any(|a| a.kind == AdapterKind::PcieGpu);
            if self.disp.present == PresentKind::PciLinear {
                lines.push(format!(
                    "PCI-GPU {} {}",
                    self.disp.winner_id, self.disp.vendor
                ));
            } else if has_pcie {
                lines.push("PCI-GPU-DEMOTED".into());
            } else {
                lines.push("PCI-GPU-NONE".into());
            }
            lines.push(format!(
                "HW-DISP-SEL {} {} {}",
                self.disp.winner_kind,
                self.disp.winner_id,
                self.disp.present.as_str()
            ));
            lines.push(format!("HW-DISP-SURFACE {}", self.scanout));
        }
        lines.push(format!(
            "HW-NAT {} {}",
            self.mode.as_str(),
            self.phase.as_str()
        ));
        lines
    }

    pub fn catalog_json(&self) -> String {
        let n = self
            .spec
            .adapters
            .iter()
            .filter(|a| a.kind == AdapterKind::VirtioNet)
            .count();
        format!(
            "{{\"listening\":{},\"virtio_net\":{},\"nat\":{},\"env_untouched\":{}}}",
            if self.listening { "true" } else { "false" },
            n,
            quote_json(self.mode.as_str()),
            if self.env_untouched { "true" } else { "false" }
        )
    }
}

/// Live `/bios/hw*` face. Router stays `Clone` and does not own the session.
pub trait HwPort {
    fn handle(&mut self, method: &str, path: &str, body: &[u8]) -> Result<(u16, String), String>;
}

impl HwPort for HwSession {
    fn handle(&mut self, method: &str, path: &str, body: &[u8]) -> Result<(u16, String), String> {
        let method = method.to_ascii_uppercase();
        let path = path.split(['?', '#']).next().unwrap_or(path);
        let path = path.trim_end_matches('/');
        match (method.as_str(), path) {
            ("GET", "/bios/hw") => Ok((200, self.catalog_json())),
            ("GET", "/bios/hw/stat") => Ok((200, self.stat_json())),
            ("POST", "/bios/hw") => {
                let nat = json_str(body, "nat").unwrap_or("minimal");
                self.apply_settings(nat)?;
                let _ = self.push(HwMsg::Config { nat: self.mode });
                Ok((200, self.stat_json()))
            }
            ("POST", "/bios/hw/wake") => {
                let _ = self.push(HwMsg::UiWake);
                let _ = self.drain_one();
                Ok((200, self.stat_json()))
            }
            ("POST", "/bios/hw/cable") => {
                let ev = CableEvent::parse(json_str(body, "event").unwrap_or(""))?;
                let _ = self.push(HwMsg::Cable(ev));
                let _ = self.drain_one();
                Ok((200, self.stat_json()))
            }
            ("POST", "/bios/hw/config") => {
                let id = json_str(body, "id").unwrap_or("net0");
                let addressing = Addressing::parse(json_str(body, "addressing").unwrap_or("nat"))?;
                let ip = json_str(body, "ip").unwrap_or("");
                match self.await_reconfigure(id, addressing, ip) {
                    Ok(body) => Ok((200, body)),
                    Err(e) => Ok((
                        400,
                        format!(
                            "{{\"ready\":true,\"ok\":false,\"error\":{},\"listening\":true,\"env_untouched\":true}}",
                            quote_json(&e)
                        ),
                    )),
                }
            }
            (m, path) if m == "GET" && path.starts_with("/bios/hw/await/") => {
                let tok: u32 = path.rsplit('/').next().unwrap_or("0").parse().unwrap_or(0);
                match self.peek_await(tok) {
                    Some(Some(v)) => Ok((200, v.clone())),
                    Some(None) => Ok((202, "{\"ready\":false}".into())),
                    None => Ok((404, "{\"error\":\"no such await\"}".into())),
                }
            }
            _ => Ok((404, "{\"error\":\"not found\"}".into())),
        }
    }
}

fn json_str<'a>(body: &'a [u8], key: &str) -> Option<&'a str> {
    let text = std::str::from_utf8(body).ok()?;
    let pat = format!("\"{key}\"");
    let rest = text.split_once(&pat)?.1;
    let rest = rest.trim_start_matches(|c: char| c != '"');
    if !rest.starts_with('"') {
        return None;
    }
    rest[1..].split_once('"').map(|(s, _)| s)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::disp::{GlMode, PresentKind};
    use g6b_spec::BoardSpec;

    fn full() -> HwSession {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut s = HwSession::from_board(&spec);
        s.listen();
        s
    }

    fn json_u32(body: &str, key: &str) -> u32 {
        let pat = format!("\"{key}\":");
        body.split(&pat)
            .nth(1)
            .unwrap()
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>()
            .parse()
            .unwrap()
    }

    #[test]
    fn default_is_minimal_idle_and_does_not_touch_env() {
        let s = full();
        assert!(s.idle());
        assert_eq!(s.mode(), NatMode::Minimal);
        assert!(s.env_untouched());
        assert!(s.status_line().contains("env=untouched"));
    }

    #[test]
    fn ui_wake_and_cable_share_the_queue() {
        let mut s = full();
        assert!(s.push(HwMsg::Cable(CableEvent::Inserted)));
        assert!(s.push(HwMsg::UiWake));
        assert_eq!(s.queued(), 2);
        let a = s.drain_one().unwrap();
        assert_eq!(a.source(), "device");
        assert_eq!(s.cable(), CableState::Plugged);
        assert_eq!(s.phase(), NatPhase::Discover);
        let b = s.drain_one().unwrap();
        assert_eq!(b.source(), "ui");
        assert_eq!(s.phase(), NatPhase::Offer);
        assert!(s.env_untouched());
    }

    #[test]
    fn unplug_returns_idle_without_env_change() {
        let mut s = full();
        let _ = s.push(HwMsg::Cable(CableEvent::LinkUp));
        let _ = s.drain_one();
        let _ = s.push(HwMsg::Cable(CableEvent::Removed));
        let _ = s.drain_one();
        assert_eq!(s.phase(), NatPhase::Idle);
        assert_eq!(s.cable(), CableState::Unplugged);
        assert!(s.env_untouched());
    }

    #[test]
    fn full_nat_is_host_mode() {
        let mut s = full();
        s.apply_settings("full").unwrap();
        assert_eq!(s.mode(), NatMode::Host);
        assert_eq!(s.device("net0").unwrap().ip, crate::NAT_LEASE);
        assert!(s.env_untouched(), "host apply is a separate named step");
        s.apply_settings("isolated").unwrap();
        assert_eq!(s.mode(), NatMode::Isolated);
        s.apply_settings("minimal").unwrap();
        assert_eq!(s.mode(), NatMode::Minimal);
    }

    #[test]
    fn queue_is_bounded() {
        let mut s = full();
        for _ in 0..MAX_HW_QUEUE + 4 {
            let _ = s.push(HwMsg::UiWake);
        }
        assert_eq!(s.queued(), MAX_HW_QUEUE);
        assert!(s.dropped >= 4);
    }

    #[test]
    fn awaited_reconfigure_static_ip_vs_nat() {
        let mut s = full();
        let (st, body) = s
            .handle(
                "POST",
                "/bios/hw/config",
                br#"{"id":"net0","addressing":"static","ip":"192.0.2.10"}"#,
            )
            .unwrap();
        assert_eq!(st, 200, "{body}");
        assert!(body.contains("\"ready\":true"), "{body}");
        assert!(body.contains("\"ok\":true"), "{body}");
        assert!(body.contains("\"addressing\":\"static\""), "{body}");
        assert!(body.contains("192.0.2.10"), "{body}");
        assert!(body.contains("\"env_untouched\":true"), "{body}");
        assert_eq!(s.device("net0").unwrap().addressing, Addressing::Static);
        let (st, body) = s
            .handle(
                "POST",
                "/bios/hw/config",
                br#"{"id":"net0","addressing":"nat"}"#,
            )
            .unwrap();
        assert_eq!(st, 200, "{body}");
        assert!(body.contains("\"addressing\":\"nat\""), "{body}");
        assert_eq!(s.device("net0").unwrap().addressing, Addressing::Nat);
        assert_eq!(s.device("net0").unwrap().ip, crate::NAT_LEASE);
        assert_eq!(s.mode(), NatMode::Isolated);
        assert!(s.env_untouched());
        let (st, err) = s
            .handle(
                "POST",
                "/bios/hw/config",
                br#"{"id":"net0","addressing":"static","ip":"not-an-ip"}"#,
            )
            .unwrap();
        assert_eq!(st, 400, "{err}");
        assert!(err.contains("\"ok\":false"), "{err}");
        assert!(s.listening(), "throw must not exit the listen worker");
        assert_eq!(s.device("net0").unwrap().addressing, Addressing::Nat);
    }

    #[test]
    fn lazy_until_post_boot_ensure() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut s = HwSession::from_board(&spec);
        assert!(!s.listening());
        assert!(!s.support_announced());
        s.ensure();
        assert!(s.listening());
        assert!(s.idle());
    }

    #[test]
    fn support_lines_name_net_and_display() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let s = HwSession::from_board(&spec);
        let lines = s.support_lines().join("\n");
        assert!(s.has_net(), "{lines}");
        assert!(lines.contains("VIRTIO-NET 5"), "{lines}");
        assert!(lines.contains("HW-NET net0 virtio-net"), "{lines}");
        if s.has_display() {
            assert!(lines.contains("HW-DISP"), "{lines}");
        }
        assert!(lines.contains("HW-NAT minimal"), "{lines}");
    }

    #[test]
    fn drain_emits_hw_events_for_the_ui() {
        let mut s = full();
        s.mark_announced();
        let evs = s.take_events();
        assert!(evs.iter().any(|e| e.event_type == "hwnet"), "{evs:?}");
        assert!(evs.iter().any(|e| e.event_type == "hw"), "{evs:?}");
        let _ = s.push(HwMsg::Cable(CableEvent::Inserted));
        let _ = s.drain_one();
        let evs = s.take_events();
        assert!(evs.iter().any(|e| e.event_type == "hwcable"), "{evs:?}");
        assert!(s.env_untouched());
    }

    #[test]
    fn isolated_nat_assigns_slirp_lease() {
        let mut s = full();
        let body = s.apply_nat("isolated").unwrap();
        assert!(body.contains("\"nat\":\"isolated\""), "{body}");
        let cfg = s.device("net0").unwrap();
        assert_eq!(cfg.ip, crate::NAT_LEASE);
        assert_eq!(cfg.inet.gateway, crate::NAT_GATEWAY);
        assert_eq!(cfg.inet.nameservers, vec![crate::NAT_DNS.to_string()]);
        assert_eq!(s.phase(), NatPhase::Established);
        assert!(s.env_untouched());
    }

    #[test]
    fn static_rejects_network_and_broadcast() {
        let mut s = full();
        let err = s.apply_ifconfig("net0", "192.0.2.0/24").unwrap_err();
        assert!(err.contains("subnet or broadcast"), "{err}");
        let err = s.apply_ifconfig("net0", "192.0.2.255/24").unwrap_err();
        assert!(err.contains("subnet or broadcast"), "{err}");
        s.apply_ifconfig("net0", "192.0.2.10/24").unwrap();
        let err = s.apply_route("net0", "default", "10.0.0.1").unwrap_err();
        assert!(err.contains("subnet"), "{err}");
    }

    #[test]
    fn tcp_udp_loopback_via_session() {
        let mut s = full();
        let err = s.tcp_listen("net0", 0).unwrap_err();
        assert!(err.contains("isolated"), "{err}");
        s.apply_nat("isolated").unwrap();
        let err = s.tcp_listen("net0", 0).unwrap_err();
        assert!(err.contains("link is down"), "{err}");
        s.apply_link("net0", "up").unwrap();
        let listen = s.tcp_listen("net0", 0).unwrap();
        let lid = json_u32(&listen, "sock");
        let port: u16 = s.stack.meta[&lid]
            .local
            .rsplit(':')
            .next()
            .unwrap()
            .parse()
            .unwrap();
        let conn = s.tcp_connect("net0", "127.0.0.1", port).unwrap();
        let cid = json_u32(&conn, "sock");
        let mut peer = None;
        for _ in 0..50 {
            if let Ok(body) = s.tcp_accept(lid) {
                peer = Some(json_u32(&body, "sock"));
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let pid = peer.expect("accept");
        let n = s.tcp_send(cid, "hello").unwrap();
        assert!(n.contains("\"n\":"), "{n}");
        let mut got = String::new();
        for _ in 0..50 {
            got = s.tcp_recv(pid).unwrap();
            if got.contains("hello") {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert!(got.contains("hello"), "{got}");
        let ub = s.udp_bind("net0", 0).unwrap();
        assert!(ub.contains("\"kind\":\"udp\""), "{ub}");
        s.sock_close(lid).unwrap();
        s.sock_close(cid).unwrap();
        s.sock_close(pid).unwrap();
        assert!(s.env_untouched());
    }

    #[test]
    fn display_stays_vga_until_probe_and_announce() {
        let spec = BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap();
        let mut s = HwSession::from_board(&spec);
        assert_eq!(s.scanout(), "vga");
        assert!(!s.disp().probed);
        assert!(!s.display_ready());
        assert_eq!(s.probed_surface(), "vga");
        s.listen();
        assert!(s.disp().probed);
        assert!(s.display_ready(), "{:?}", s.disp());
        assert_eq!(s.disp().present, PresentKind::Virtio2d);
        assert_eq!(s.disp().winner_kind, "virtio-gpu");
        assert_eq!(s.scanout(), "vga", "probe must not switch scanout");
        assert_eq!(s.probed_surface(), "gpu");
        let lines = s.support_lines().join("\n");
        assert!(lines.contains("VIRTIO-GPU 0"), "{lines}");
        assert!(lines.contains("HW-DISP-SEL virtio-gpu"), "{lines}");
        assert!(lines.contains("HW-DISP-SURFACE vga"), "{lines}");
        s.set_scanout("gpu");
        assert_eq!(s.scanout(), "gpu");
        assert_eq!(s.disp().surface, "gpu");
    }

    #[test]
    fn hdmi_outranks_virtio_gpu_and_pcie_without_linear_fb_is_demoted() {
        let hw = HwSpec::from_json_str(
            r#"{"adapters":[
                {"id":"pcie0","kind":"pcie-gpu","vendor":"nvidia"},
                {"id":"gpu0","kind":"virtio-gpu","device_id":16,"transport":"virtio-mmio"},
                {"id":"hdmi0","kind":"hdmi","vendor":"g6lc-scanout","features":["g6ds"]}
            ]}"#,
        )
        .unwrap();
        let mut s = HwSession::from_hw(hw);
        s.listen();
        assert_eq!(s.disp().winner_kind, "hdmi");
        assert_eq!(s.disp().present, PresentKind::G6ds);
        assert_eq!(s.scanout(), "vga");
        let lines = s.support_lines().join("\n");
        assert!(lines.contains("PCI-GPU-DEMOTED"), "{lines}");
        assert!(lines.contains("HW-DISP-SEL hdmi hdmi0 g6ds"), "{lines}");
    }

    #[test]
    fn pcie_linear_fb_wins_and_gl_host_needs_a_name() {
        let hw = HwSpec::from_json_str(
            r#"{"adapters":[{"id":"pcie0","kind":"pcie-gpu","vendor":"amd","features":["linear-fb"]}]}"#,
        )
        .unwrap();
        let mut s = HwSession::from_hw(hw);
        s.listen();
        assert_eq!(s.disp().present, PresentKind::PciLinear);
        assert_eq!(s.disp().vendor, "amd");
        assert_eq!(s.probed_surface(), "gpu");
        let err = s.gl_apply("").unwrap_err();
        assert!(err.contains("GPU name"), "{err}");
        assert!(s.env_untouched());
        let body = s.gl_apply("AMD Radeon").unwrap();
        assert!(body.contains("\"applied\":true"), "{body}");
        assert!(!s.env_untouched());
        assert_eq!(s.disp().gl, GlMode::Host);
        s.gl_revert().unwrap();
        assert!(s.env_untouched());
        let err = s.apply_gl("host").unwrap_err();
        assert!(err.contains("HwGlApply"), "{err}");
        s.apply_gl("listing").unwrap();
        assert_eq!(s.disp().gl, GlMode::Listing);
        s.apply_disp_surface("gpu").unwrap();
        assert_eq!(s.scanout(), "gpu");
        s.apply_disp_mode("1920x1080@60").unwrap();
        assert_eq!(s.disp().w, 1920);
        assert_eq!(s.disp().h, 1080);
    }

    #[test]
    fn usb_key_and_pointer_are_hw_not_cli() {
        let mut s = full();
        let flash = s.usb_ls("flash").unwrap();
        assert!(flash.contains("openwrt.bin"), "{flash}");
        let key = s.usb_key("present").unwrap();
        assert!(key.contains("present"), "{key}");
        s.apply_pointer(12, 34, 1);
        assert_eq!(s.pointer(), (12, 34, 1));
        let err = HwSession::from_hw(HwSpec::default())
            .usb_ls("flash")
            .unwrap_err();
        assert!(err.contains("board session"), "{err}");
    }

    #[test]
    fn host_apply_refuses_empty_adapter_name() {
        let mut s = full();
        s.apply_nat("host").unwrap();
        s.apply_ifconfig("net0", "192.0.2.10/24").unwrap();
        let err = s.host_apply("net0", "").unwrap_err();
        assert!(err.contains("adapter name"), "{err}");
        assert!(s.env_untouched());
        assert!(s.host_adapter().is_empty());
        let err = s.host_apply("net0", "   ").unwrap_err();
        assert!(err.contains("adapter name"), "{err}");
        assert!(s.env_untouched());
    }
}
