// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Opt-in host NIC programming (Windows netsh / Linux `ip`). Never QEMU
//! `-netdev`. Refuses an empty adapter name so the default route NIC is not
//! guessed.

use std::process::Command;

use g6b_spec::quote_json;

use crate::inet::{looks_like_ipv4, InetCfg};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostAdapter {
    pub name: String,
    pub status: String,
    pub mac: String,
}

impl HostAdapter {
    pub fn json(&self) -> String {
        format!(
            "{{\"name\":{},\"status\":{},\"mac\":{}}}",
            quote_json(&self.name),
            quote_json(&self.status),
            quote_json(&self.mac)
        )
    }
}

/// List host adapters. Empty list is OK (CI / locked-down hosts).
pub fn list_adapters() -> Result<Vec<HostAdapter>, String> {
    if cfg!(windows) {
        list_windows()
    } else {
        list_unix()
    }
}

pub fn list_json() -> Result<String, String> {
    let items: Vec<String> = list_adapters()?.iter().map(HostAdapter::json).collect();
    Ok(format!(
        "{{\"ok\":true,\"adapters\":[{}],\"env_untouched\":true}}",
        items.join(",")
    ))
}

/// Program a **named** host adapter with the isolated inet config.
/// `adapter` must be explicit (Loopback, a vEthernet switch, …).
pub fn apply_static(adapter: &str, inet: &InetCfg) -> Result<String, String> {
    let adapter = adapter.trim();
    if adapter.is_empty() {
        return Err("host apply needs an adapter name (refusing to guess the default NIC)".into());
    }
    if !looks_like_ipv4(&inet.addr) {
        return Err("host apply needs a static IPv4 address".into());
    }
    let mask = crate::inet::prefix_mask(inet.prefix);
    if cfg!(windows) {
        netsh_set_address(adapter, &inet.addr, &mask, &inet.gateway)?;
        if let Some(dns) = inet.nameservers.first() {
            let _ = netsh_set_dns(adapter, dns);
        }
    } else {
        ip_addr_replace(adapter, &inet.addr, inet.prefix, &inet.gateway)?;
    }
    Ok(format!(
        "{{\"ok\":true,\"applied\":true,\"adapter\":{},\"addr\":{},\"prefix\":{},\"env_untouched\":false}}",
        quote_json(adapter),
        quote_json(&inet.addr),
        inet.prefix
    ))
}

/// Restore DHCP on a named adapter.
pub fn revert(adapter: &str) -> Result<String, String> {
    let adapter = adapter.trim();
    if adapter.is_empty() {
        return Err("host revert needs an adapter name".into());
    }
    if cfg!(windows) {
        run_ok(
            "netsh",
            &[
                "interface",
                "ip",
                "set",
                "address",
                &format!("name={adapter}"),
                "dhcp",
            ],
        )?;
    } else {
        run_ok("ip", &["addr", "flush", "dev", adapter])?;
    }
    Ok(format!(
        "{{\"ok\":true,\"reverted\":true,\"adapter\":{},\"env_untouched\":true}}",
        quote_json(adapter)
    ))
}

fn list_windows() -> Result<Vec<HostAdapter>, String> {
    let out = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            "Get-NetAdapter | ForEach-Object { $_.Name + '|' + $_.Status + '|' + $_.MacAddress }",
        ])
        .output()
        .map_err(|e| format!("Get-NetAdapter: {e}"))?;
    if !out.status.success() {
        return Ok(Vec::new());
    }
    Ok(parse_adapter_lines(&String::from_utf8_lossy(&out.stdout)))
}

fn list_unix() -> Result<Vec<HostAdapter>, String> {
    let out = Command::new("ip")
        .args(["-o", "link", "show"])
        .output()
        .map_err(|e| format!("ip link: {e}"))?;
    if !out.status.success() {
        return Ok(Vec::new());
    }
    let mut v = Vec::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let name = line
            .split(':')
            .nth(1)
            .map(|s| s.split_whitespace().next().unwrap_or(""))
            .unwrap_or("");
        if name.is_empty() || name == "lo" {
            continue;
        }
        v.push(HostAdapter {
            name: name.into(),
            status: if line.contains("UP") {
                "Up".into()
            } else {
                "Down".into()
            },
            mac: String::new(),
        });
    }
    Ok(v)
}

fn parse_adapter_lines(text: &str) -> Vec<HostAdapter> {
    let mut v = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let mut p = line.split('|');
        let name = p.next().unwrap_or("").trim();
        if name.is_empty() {
            continue;
        }
        v.push(HostAdapter {
            name: name.into(),
            status: p.next().unwrap_or("").trim().into(),
            mac: p.next().unwrap_or("").trim().into(),
        });
    }
    v
}

fn netsh_set_address(adapter: &str, addr: &str, mask: &str, gw: &str) -> Result<(), String> {
    let name = format!("name={adapter}");
    let mut args = vec![
        "interface",
        "ip",
        "set",
        "address",
        name.as_str(),
        "static",
        addr,
        mask,
    ];
    if looks_like_ipv4(gw) {
        args.push(gw);
    }
    run_ok("netsh", &args)
}

fn netsh_set_dns(adapter: &str, dns: &str) -> Result<(), String> {
    run_ok(
        "netsh",
        &[
            "interface",
            "ip",
            "set",
            "dns",
            &format!("name={adapter}"),
            "static",
            dns,
        ],
    )
}

fn ip_addr_replace(adapter: &str, addr: &str, prefix: u8, gw: &str) -> Result<(), String> {
    run_ok(
        "ip",
        &[
            "addr",
            "replace",
            &format!("{addr}/{prefix}"),
            "dev",
            adapter,
        ],
    )?;
    if looks_like_ipv4(gw) {
        let _ = run_ok(
            "ip",
            &["route", "replace", "default", "via", gw, "dev", adapter],
        );
    }
    Ok(())
}

fn run_ok(bin: &str, args: &[&str]) -> Result<(), String> {
    let out = Command::new(bin)
        .args(args)
        .output()
        .map_err(|e| format!("{bin} spawn: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{bin} {}: {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_refuses_empty_adapter() {
        let inet = InetCfg {
            addr: "192.0.2.10".into(),
            prefix: 24,
            ..InetCfg::default()
        };
        let err = apply_static("", &inet).unwrap_err();
        assert!(err.contains("adapter name"), "{err}");
        let err = revert("").unwrap_err();
        assert!(err.contains("adapter name"), "{err}");
    }

    #[test]
    fn parses_adapter_table() {
        let v = parse_adapter_lines("Ethernet|Up|AA-BB\nLoopback Pseudo-Interface 1|Up|\n");
        assert_eq!(v.len(), 2);
        assert_eq!(v[0].name, "Ethernet");
        assert_eq!(v[1].name, "Loopback Pseudo-Interface 1");
    }
}
