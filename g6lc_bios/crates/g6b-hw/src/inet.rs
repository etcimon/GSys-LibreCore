// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Isolated IPv4/TCP/UDP config for a net adapter, shaped like Linux
//! `ip addr` / `ip route` / `ip link` / `/etc/resolv.conf`. Host NIC
//! programming is opt-in (`host_nic`); QEMU never gets `-netdev`.

use g6b_spec::quote_json;

/// Linux-like link state (`ip link set dev X up|down`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LinkState {
    Down,
    Up,
}

impl LinkState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Down => "down",
            Self::Up => "up",
        }
    }

    pub fn parse(s: &str) -> Result<Self, String> {
        match s {
            "up" | "UP" => Ok(Self::Up),
            "down" | "DOWN" => Ok(Self::Down),
            other => Err(format!("unknown link state `{other}`")),
        }
    }
}

/// Shadow TCP knobs (not a host stack).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TcpCfg {
    pub enabled: bool,
}

impl Default for TcpCfg {
    fn default() -> Self {
        Self { enabled: true }
    }
}

/// Shadow UDP knobs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct UdpCfg {
    pub enabled: bool,
}

impl Default for UdpCfg {
    fn default() -> Self {
        Self { enabled: true }
    }
}

/// Per-device inet4 configuration (isolated session).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InetCfg {
    pub addr: String,
    pub prefix: u8,
    pub gateway: String,
    pub nameservers: Vec<String>,
    pub mtu: u16,
    pub link: LinkState,
    pub tcp: TcpCfg,
    pub udp: UdpCfg,
}

impl Default for InetCfg {
    fn default() -> Self {
        Self {
            addr: String::new(),
            prefix: 24,
            gateway: String::new(),
            nameservers: Vec::new(),
            mtu: 1500,
            link: LinkState::Down,
            tcp: TcpCfg::default(),
            udp: UdpCfg::default(),
        }
    }
}

impl InetCfg {
    pub fn cidr(&self) -> String {
        if self.addr.is_empty() {
            String::new()
        } else {
            format!("{}/{}", self.addr, self.prefix)
        }
    }

    pub fn json(&self) -> String {
        let dns = self
            .nameservers
            .iter()
            .map(|n| quote_json(n))
            .collect::<Vec<_>>()
            .join(",");
        format!(
            "{{\"addr\":{},\"prefix\":{},\"gateway\":{},\"dns\":[{}],\"mtu\":{},\"link\":{},\"tcp\":{},\"udp\":{}}}",
            quote_json(&self.addr),
            self.prefix,
            quote_json(&self.gateway),
            dns,
            self.mtu,
            quote_json(self.link.as_str()),
            if self.tcp.enabled { "true" } else { "false" },
            if self.udp.enabled { "true" } else { "false" }
        )
    }
}

pub fn looks_like_ipv4(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    parts.len() == 4
        && parts.iter().all(|p| {
            p.parse::<u8>().is_ok() && !p.is_empty() && p.chars().all(|c| c.is_ascii_digit())
        })
}

/// Userspace NAT network (qemu slirp-shaped, no `-netdev`).
pub const NAT_NETWORK: &str = "10.0.2.0";
pub const NAT_PREFIX: u8 = 24;
pub const NAT_GATEWAY: &str = "10.0.2.2";
pub const NAT_DNS: &str = "10.0.2.3";
pub const NAT_LEASE: &str = "10.0.2.15";

pub fn prefix_mask(prefix: u8) -> String {
    let prefix = prefix.min(32);
    let m = if prefix == 0 {
        0u32
    } else {
        !0u32 << (32 - prefix)
    };
    format!(
        "{}.{}.{}.{}",
        (m >> 24) & 0xff,
        (m >> 16) & 0xff,
        (m >> 8) & 0xff,
        m & 0xff
    )
}

pub fn ipv4_u32(s: &str) -> Option<u32> {
    if !looks_like_ipv4(s) {
        return None;
    }
    let mut o = [0u8; 4];
    for (i, p) in s.split('.').enumerate() {
        o[i] = p.parse().ok()?;
    }
    Some(u32::from_be_bytes(o))
}

pub fn in_subnet(addr: &str, other: &str, prefix: u8) -> bool {
    let Some(a) = ipv4_u32(addr) else {
        return false;
    };
    let Some(b) = ipv4_u32(other) else {
        return false;
    };
    let prefix = prefix.min(32);
    let mask = if prefix == 0 {
        0
    } else {
        !0u32 << (32 - prefix)
    };
    (a & mask) == (b & mask)
}

pub fn is_network_or_broadcast(addr: &str, prefix: u8) -> bool {
    let Some(a) = ipv4_u32(addr) else {
        return true;
    };
    let prefix = prefix.min(32);
    if prefix >= 31 {
        return false;
    }
    let host = 32 - prefix;
    let hmask = (1u32 << host) - 1;
    let h = a & hmask;
    h == 0 || h == hmask
}

/// Check a static host address: IPv4, prefix, not net/broadcast.
pub fn check_static(addr: &str, prefix: u8) -> Result<(), String> {
    if !looks_like_ipv4(addr) {
        return Err("static addressing needs an IPv4 address".into());
    }
    if prefix == 0 || prefix > 32 {
        return Err("static prefix must be 1..=32".into());
    }
    if is_network_or_broadcast(addr, prefix) {
        return Err("static address must not be the subnet or broadcast".into());
    }
    Ok(())
}

/// `192.0.2.10/24` or a bare IPv4 (`/32`).
pub fn parse_cidr(s: &str) -> Result<(String, u8), String> {
    let s = s.trim();
    if let Some((addr, p)) = s.split_once('/') {
        if !looks_like_ipv4(addr) {
            return Err("cidr needs an IPv4 address".into());
        }
        let prefix: u8 = p
            .parse()
            .map_err(|_| "cidr prefix must be 0..=32".to_string())?;
        if prefix > 32 {
            return Err("cidr prefix must be 0..=32".into());
        }
        Ok((addr.to_string(), prefix))
    } else if looks_like_ipv4(s) {
        Ok((s.to_string(), 32))
    } else {
        Err("expected IPv4 or IPv4/prefix".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_linux_cidr() {
        assert_eq!(
            parse_cidr("192.0.2.10/24").unwrap(),
            ("192.0.2.10".into(), 24)
        );
        assert_eq!(parse_cidr("10.0.0.1").unwrap(), ("10.0.0.1".into(), 32));
        assert!(parse_cidr("not-an-ip").is_err());
        assert!(parse_cidr("192.0.2.10/99").is_err());
        assert_eq!(prefix_mask(24), "255.255.255.0");
        assert!(in_subnet("192.0.2.10", "192.0.2.1", 24));
        assert!(!in_subnet("192.0.2.10", "10.0.0.1", 24));
        assert!(is_network_or_broadcast("192.0.2.0", 24));
        assert!(is_network_or_broadcast("192.0.2.255", 24));
        assert!(check_static("192.0.2.10", 24).is_ok());
        assert!(check_static("192.0.2.0", 24).is_err());
    }
}
