// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Post-boot lazy hw functions for JS / wasm / HolyC. Not `/bios` paths.
//! JS/wasm `await hwConfig(...)` throws [`HwError`] without exiting the listen
//! worker. HolyC always returns instantly: status getters (`HwStat` /
//! `HwListen`) snapshot now; mutators enqueue and return `HW-OK` / `HW-ERR`
//! plus `HW-STAT` without parking.

use crate::session::{Addressing, CableEvent, HwMsg, HwSession};

/// Thrown at the language await. The listen worker stays idle-listening.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HwError {
    pub message: String,
}

impl HwError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl std::fmt::Display for HwError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for HwError {}

/// HolyC `HwConfig` / JS `hwConfig` / wasm export — same table.
pub fn normalize_name(name: &str) -> String {
    let n = name.trim();
    if n.starts_with("Hw") && n.len() > 2 {
        let rest = &n[2..];
        format!("hw{rest}")
    } else {
        n.to_string()
    }
}

/// Parse `HwConfig("net0","static","192.0.2.10")` or `hwCable("inserted")`.
pub fn parse_invoke(line: &str) -> Option<(String, Vec<String>)> {
    let line = line.trim().trim_end_matches(';');
    let (name, rest) = line.split_once('(')?;
    let name = name.trim();
    if name.is_empty() {
        return None;
    }
    let inner = rest.strip_suffix(')')?.trim();
    let mut args = Vec::new();
    if !inner.is_empty() {
        for part in inner.split(',') {
            let p = part.trim().trim_matches('"').trim_matches('\'').to_string();
            args.push(p);
        }
    }
    Some((name.to_string(), args))
}

/// Dispatch a post-boot hw function. First call lazily starts the idle
/// listen worker. Errors leave `listening() == true`.
pub fn call(session: &mut HwSession, name: &str, args: &[&str]) -> Result<String, HwError> {
    session.ensure();
    let name = normalize_name(name);
    match name.as_str() {
        "hwListen" => {
            session.listen();
            Ok(session.stat_json())
        }
        "hwStat" => Ok(session.stat_json()),
        "hwWake" => {
            let _ = session.push(HwMsg::UiWake);
            let _ = session.drain_one();
            Ok(session.stat_json())
        }
        "hwCable" => {
            let ev =
                CableEvent::parse(args.first().copied().unwrap_or("")).map_err(HwError::new)?;
            let _ = session.push(HwMsg::Cable(ev));
            let _ = session.drain_one();
            Ok(session.stat_json())
        }
        "hwConfig" => {
            let id = args.first().copied().unwrap_or("net0");
            let addressing =
                Addressing::parse(args.get(1).copied().unwrap_or("nat")).map_err(HwError::new)?;
            let ip = args.get(2).copied().unwrap_or("");
            session
                .await_reconfigure(id, addressing, ip)
                .map_err(HwError::new)
        }
        "hwIfconfig" => {
            let id = args.first().copied().unwrap_or("net0");
            let cidr = args.get(1).copied().unwrap_or("");
            session.apply_ifconfig(id, cidr).map_err(HwError::new)
        }
        "hwRoute" => {
            let id = args.first().copied().unwrap_or("net0");
            let dest = args.get(1).copied().unwrap_or("default");
            let via = args.get(2).copied().unwrap_or("");
            session.apply_route(id, dest, via).map_err(HwError::new)
        }
        "hwLink" => {
            let id = args.first().copied().unwrap_or("net0");
            let state = args.get(1).copied().unwrap_or("up");
            session.apply_link(id, state).map_err(HwError::new)
        }
        "hwDns" => {
            let id = args.first().copied().unwrap_or("net0");
            let ns = args.get(1).copied().unwrap_or("");
            session.apply_dns(id, ns).map_err(HwError::new)
        }
        "hwProto" => {
            let id = args.first().copied().unwrap_or("net0");
            let proto = args.get(1).copied().unwrap_or("tcp");
            let on = args.get(2).copied().unwrap_or("on");
            session.apply_proto(id, proto, on).map_err(HwError::new)
        }
        "hwInetStat" => {
            let id = args.first().copied().unwrap_or("net0");
            Ok(session.inet_json(id))
        }
        "hwNat" => {
            let nat = args.first().copied().unwrap_or("minimal");
            session.apply_nat(nat).map_err(HwError::new)
        }
        "hwTcpListen" => {
            let id = args.first().copied().unwrap_or("net0");
            let port = parse_u16(args.get(1).copied().unwrap_or("0"))?;
            session.tcp_listen(id, port).map_err(HwError::new)
        }
        "hwTcpConnect" => {
            let id = args.first().copied().unwrap_or("net0");
            let host = args.get(1).copied().unwrap_or("127.0.0.1");
            let port = parse_u16(args.get(2).copied().unwrap_or("0"))?;
            session.tcp_connect(id, host, port).map_err(HwError::new)
        }
        "hwTcpAccept" => {
            let sock = parse_u32(args.first().copied().unwrap_or(""))?;
            session.tcp_accept(sock).map_err(HwError::new)
        }
        "hwTcpSend" => {
            let sock = parse_u32(args.first().copied().unwrap_or(""))?;
            let data = if args.len() > 1 {
                args[1..].join(",")
            } else {
                String::new()
            };
            session.tcp_send(sock, &data).map_err(HwError::new)
        }
        "hwTcpRecv" => {
            let sock = parse_u32(args.first().copied().unwrap_or(""))?;
            session.tcp_recv(sock).map_err(HwError::new)
        }
        "hwUdpBind" => {
            let id = args.first().copied().unwrap_or("net0");
            let port = parse_u16(args.get(1).copied().unwrap_or("0"))?;
            session.udp_bind(id, port).map_err(HwError::new)
        }
        "hwUdpSend" => {
            let sock = parse_u32(args.first().copied().unwrap_or(""))?;
            let host = args.get(1).copied().unwrap_or("127.0.0.1");
            let port = parse_u16(args.get(2).copied().unwrap_or("0"))?;
            let data = if args.len() > 3 {
                args[3..].join(",")
            } else {
                String::new()
            };
            session
                .udp_send(sock, host, port, &data)
                .map_err(HwError::new)
        }
        "hwUdpRecv" => {
            let sock = parse_u32(args.first().copied().unwrap_or(""))?;
            session.udp_recv(sock).map_err(HwError::new)
        }
        "hwSockClose" => {
            let sock = parse_u32(args.first().copied().unwrap_or(""))?;
            session.sock_close(sock).map_err(HwError::new)
        }
        "hwHostList" => session.host_list().map_err(HwError::new),
        "hwHostApply" => {
            let id = args.first().copied().unwrap_or("net0");
            let adapter = args.get(1).copied().unwrap_or("");
            session.host_apply(id, adapter).map_err(HwError::new)
        }
        "hwHostRevert" => session.host_revert().map_err(HwError::new),
        "hwDispStat" => Ok(session.disp().json()),
        "hwDispLink" => {
            let state = args.first().copied().unwrap_or("up");
            session.apply_disp_link(state).map_err(HwError::new)
        }
        "hwDispMode" => {
            let mode = args.first().copied().unwrap_or("");
            session.apply_disp_mode(mode).map_err(HwError::new)
        }
        "hwDispSurface" => {
            let surface = args.first().copied().unwrap_or("vga");
            session.apply_disp_surface(surface).map_err(HwError::new)
        }
        "hwGl" => {
            let mode = args.first().copied().unwrap_or("off");
            session.apply_gl(mode).map_err(HwError::new)
        }
        "hwGlList" => session.gl_list().map_err(HwError::new),
        "hwGlApply" => {
            let name = args.first().copied().unwrap_or("");
            session.gl_apply(name).map_err(HwError::new)
        }
        "hwGlRevert" => session.gl_revert().map_err(HwError::new),
        "hwUsbLs" => {
            let kind = args.first().copied().unwrap_or("key");
            session.usb_ls(kind).map_err(HwError::new)
        }
        "hwUsbKey" => {
            let op = args.first().copied().unwrap_or("present");
            session.usb_key(op).map_err(HwError::new)
        }
        "hwUsbFlash" => {
            let name = args.first().copied().unwrap_or("");
            session.usb_flash(name).map_err(HwError::new)
        }
        "hwPointer" => {
            let x: i32 = args.first().copied().unwrap_or("0").parse().unwrap_or(0);
            let y: i32 = args.get(1).copied().unwrap_or("0").parse().unwrap_or(0);
            let b: u8 = args.get(2).copied().unwrap_or("0").parse().unwrap_or(0);
            Ok(session.apply_pointer(x, y, b))
        }
        other => Err(HwError::new(format!("unknown hw function `{other}`"))),
    }
}

fn parse_u16(s: &str) -> Result<u16, HwError> {
    s.parse::<u16>()
        .map_err(|_| HwError::new(format!("port `{s}` is not a u16")))
}

fn parse_u32(s: &str) -> Result<u32, HwError> {
    s.parse::<u32>()
        .map_err(|_| HwError::new(format!("socket `{s}` is not a u32")))
}

/// HolyC / JS source line → [`call`].
pub fn eval(session: &mut HwSession, line: &str) -> Result<String, HwError> {
    let (name, args) =
        parse_invoke(line).ok_or_else(|| HwError::new("hw invoke expected Name(args)"))?;
    let args_ref: Vec<&str> = args.iter().map(String::as_str).collect();
    call(session, &name, &args_ref)
}

fn is_status_fn(name: &str) -> bool {
    matches!(
        normalize_name(name).as_str(),
        "hwStat"
            | "hwListen"
            | "hwInetStat"
            | "hwHostList"
            | "hwTcpListen"
            | "hwTcpConnect"
            | "hwTcpAccept"
            | "hwTcpRecv"
            | "hwUdpBind"
            | "hwUdpRecv"
            | "hwDispStat"
            | "hwGlList"
            | "hwUsbLs"
            | "hwUsbKey"
    )
}

fn is_hw_name(name: &str) -> bool {
    matches!(
        normalize_name(name).as_str(),
        "hwListen"
            | "hwStat"
            | "hwWake"
            | "hwCable"
            | "hwConfig"
            | "hwIfconfig"
            | "hwRoute"
            | "hwLink"
            | "hwDns"
            | "hwProto"
            | "hwInetStat"
            | "hwNat"
            | "hwTcpListen"
            | "hwTcpConnect"
            | "hwTcpAccept"
            | "hwTcpSend"
            | "hwTcpRecv"
            | "hwUdpBind"
            | "hwUdpSend"
            | "hwUdpRecv"
            | "hwSockClose"
            | "hwHostList"
            | "hwHostApply"
            | "hwHostRevert"
            | "hwDispStat"
            | "hwDispLink"
            | "hwDispMode"
            | "hwDispSurface"
            | "hwGl"
            | "hwGlList"
            | "hwGlApply"
            | "hwGlRevert"
            | "hwUsbLs"
            | "hwUsbKey"
            | "hwUsbFlash"
            | "hwPointer"
    )
}

fn holyc_ok(session: &HwSession, name: &str, body: &str) -> String {
    let mut out = String::new();
    if is_status_fn(name) {
        out.push_str("HW-STAT ");
        out.push_str(body);
        out.push('\n');
    } else {
        out.push_str("HW-OK\nHW-STAT ");
        out.push_str(&session.stat_json());
        out.push('\n');
    }
    for line in session.support_lines() {
        out.push_str(&line);
        out.push('\n');
    }
    out
}

/// HolyC lane: never parks, never throws. Errors become `HW-ERR` plus a
/// status snapshot so the caller polls `HwStat` instead of awaiting.
pub fn call_instant(session: &mut HwSession, name: &str, args: &[&str]) -> String {
    match call(session, name, args) {
        Ok(body) => holyc_ok(session, name, &body),
        Err(e) => format!("HW-ERR {}\nHW-STAT {}\n", e.message, session.stat_json()),
    }
}

/// HolyC source line → [`call_instant`].
pub fn eval_instant(session: &mut HwSession, line: &str) -> String {
    match parse_invoke(line) {
        Some((name, args)) => {
            let args_ref: Vec<&str> = args.iter().map(String::as_str).collect();
            call_instant(session, &name, &args_ref)
        }
        None => "HW-ERR hw invoke expected Name(args)\n".into(),
    }
}

pub fn is_hw_invoke(line: &str) -> bool {
    parse_invoke(line)
        .map(|(n, _)| is_hw_name(&n))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{Addressing, HwSession};
    use g6b_spec::BoardSpec;

    fn session() -> HwSession {
        HwSession::from_board(
            &BoardSpec::from_json_str(r#"{"schema_version":1,"profile":"full"}"#).unwrap(),
        )
    }

    #[test]
    fn post_boot_lazy_listen_on_first_call() {
        let mut s = session();
        assert!(!s.listening());
        let _ = eval(&mut s, "hwStat()").unwrap();
        assert!(s.listening());
        assert!(s.env_untouched());
    }

    #[test]
    fn awaited_hw_config_static_ip_vs_nat() {
        let mut s = session();
        let body = eval(&mut s, r#"hwConfig("net0","static","192.0.2.10")"#).unwrap();
        assert!(body.contains("\"addressing\":\"static\""), "{body}");
        assert!(body.contains("192.0.2.10"), "{body}");
        assert_eq!(s.device("net0").unwrap().addressing, Addressing::Static);
        let body = eval(&mut s, r#"HwConfig("net0","nat")"#).unwrap();
        assert!(body.contains("\"addressing\":\"nat\""), "{body}");
        assert_eq!(s.device("net0").unwrap().addressing, Addressing::Nat);
        assert!(s.env_untouched());
    }

    #[test]
    fn throw_during_await_does_not_exit_worker() {
        let mut s = session();
        let _ = eval(&mut s, "hwListen()").unwrap();
        let err = eval(&mut s, r#"hwConfig("net0","static","not-an-ip")"#).unwrap_err();
        assert!(err.message.contains("IPv4"), "{err}");
        assert!(s.listening());
        assert!(s.env_untouched());
        let _ = eval(&mut s, r#"hwCable("inserted")"#).unwrap();
        let _ = eval(&mut s, "hwWake()").unwrap();
        assert!(s.listening());
    }

    #[test]
    fn holyc_functions_return_instantly_with_status() {
        let mut s = session();
        let out = eval_instant(&mut s, "HwStat()");
        assert!(out.contains("HW-STAT"), "{out}");
        assert!(out.contains("VIRTIO-NET 5"), "{out}");
        assert!(out.contains("HW-NET net0"), "{out}");
        assert!(s.listening());
        let err = eval_instant(&mut s, r#"HwConfig("net0","static","not-an-ip")"#);
        assert!(err.contains("HW-ERR"), "{err}");
        assert!(err.contains("HW-STAT"), "{err}");
        assert!(s.listening());
        let ok = eval_instant(&mut s, r#"HwConfig("net0","nat")"#);
        assert!(ok.contains("HW-OK"), "{ok}");
        assert!(ok.contains("HW-STAT"), "{ok}");
        let cable = eval_instant(&mut s, r#"HwCable("inserted")"#);
        assert!(
            cable.contains("HW-OK") || cable.contains("HW-STAT"),
            "{cable}"
        );
    }

    #[test]
    fn linux_like_inet_tcp_udp_is_isolated() {
        let mut s = session();
        let body = eval(&mut s, r#"hwIfconfig("net0","192.0.2.10/24")"#).unwrap();
        assert!(body.contains("192.0.2.10"), "{body}");
        assert!(body.contains("\"prefix\":24"), "{body}");
        assert_eq!(s.device("net0").unwrap().addressing, Addressing::Static);
        let _ = eval(&mut s, r#"hwRoute("net0","default","192.0.2.1")"#).unwrap();
        let _ = eval(&mut s, r#"hwLink("net0","up")"#).unwrap();
        let _ = eval(&mut s, r#"hwDns("net0","1.1.1.1")"#).unwrap();
        let _ = eval(&mut s, r#"hwProto("net0","udp","off")"#).unwrap();
        let inet = s.device("net0").unwrap();
        assert_eq!(inet.inet.gateway, "192.0.2.1");
        assert_eq!(inet.inet.link.as_str(), "up");
        assert_eq!(inet.inet.nameservers, vec!["1.1.1.1".to_string()]);
        assert!(inet.inet.tcp.enabled);
        assert!(!inet.inet.udp.enabled);
        assert!(s.env_untouched());
        let snap = eval_instant(&mut s, r#"HwInetStat("net0")"#);
        assert!(snap.contains("HW-STAT"), "{snap}");
        assert!(snap.contains("1.1.1.1"), "{snap}");
    }

    #[test]
    fn isolated_nat_and_static_via_call() {
        let mut s = session();
        let body = eval(&mut s, r#"hwNat("isolated")"#).unwrap();
        assert!(body.contains("\"nat\":\"isolated\""), "{body}");
        assert!(body.contains(crate::NAT_LEASE), "{body}");
        let err = eval(&mut s, r#"hwIfconfig("net0","192.0.2.0/24")"#).unwrap_err();
        assert!(err.message.contains("subnet or broadcast"), "{err}");
        let body = eval(&mut s, r#"hwIfconfig("net0","192.0.2.10/24")"#).unwrap();
        assert!(body.contains("\"addressing\":\"static\""), "{body}");
        let err = eval(&mut s, r#"hwHostApply("net0","")"#).unwrap_err();
        assert!(err.message.contains("adapter name"), "{err}");
        assert!(s.env_untouched());
        let instant = eval_instant(&mut s, r#"HwNat("host")"#);
        assert!(
            instant.contains("HW-OK") || instant.contains("HW-STAT"),
            "{instant}"
        );
        assert_eq!(s.mode(), crate::session::NatMode::Host);
        assert!(s.env_untouched());
    }

    #[test]
    fn tcp_udp_call_loopback() {
        let mut s = session();
        let err = eval(&mut s, r#"hwTcpListen("net0","0")"#).unwrap_err();
        assert!(err.message.contains("isolated"), "{err}");
        let _ = eval(&mut s, r#"hwNat("isolated")"#).unwrap();
        let _ = eval(&mut s, r#"hwLink("net0","up")"#).unwrap();
        let listen = eval(&mut s, r#"hwTcpListen("net0","0")"#).unwrap();
        let lid = listen
            .split("\"sock\":")
            .nth(1)
            .unwrap()
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>();
        assert!(!lid.is_empty(), "{listen}");
        let port = s
            .socks_json()
            .split("\"local\":\"")
            .nth(1)
            .unwrap()
            .split('"')
            .next()
            .unwrap()
            .rsplit(':')
            .next()
            .unwrap()
            .to_string();
        let conn = eval(
            &mut s,
            &format!(r#"hwTcpConnect("net0","127.0.0.1","{port}")"#),
        )
        .unwrap();
        assert!(conn.contains("\"sock\":"), "{conn}");
        let mut accepted = None;
        for _ in 0..50 {
            match eval(&mut s, &format!(r#"hwTcpAccept("{lid}")"#)) {
                Ok(body) if body.contains("\"sock\":") => {
                    accepted = Some(body);
                    break;
                }
                _ => std::thread::sleep(std::time::Duration::from_millis(2)),
            }
        }
        let accept = accepted.expect("accept");
        let pid = accept
            .split("\"sock\":")
            .nth(1)
            .unwrap()
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>();
        let cid = conn
            .split("\"sock\":")
            .nth(1)
            .unwrap()
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>();
        let _ = eval(&mut s, &format!(r#"hwTcpSend("{cid}","ping")"#)).unwrap();
        let mut got = String::new();
        for _ in 0..50 {
            got = eval(&mut s, &format!(r#"hwTcpRecv("{pid}")"#)).unwrap();
            if got.contains("ping") {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert!(got.contains("ping"), "{got}");
        let bind = eval(&mut s, r#"hwUdpBind("net0","0")"#).unwrap();
        assert!(bind.contains("\"kind\":\"udp\""), "{bind}");
        let uid = bind
            .split("\"sock\":")
            .nth(1)
            .unwrap()
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>();
        let _ = eval_instant(&mut s, &format!(r#"HwSockClose("{lid}")"#));
        let _ = eval(&mut s, &format!(r#"hwSockClose("{cid}")"#)).unwrap();
        let _ = eval(&mut s, &format!(r#"hwSockClose("{pid}")"#)).unwrap();
        let _ = eval(&mut s, &format!(r#"hwSockClose("{uid}")"#)).unwrap();
        assert!(s.env_untouched());
    }

    #[test]
    fn disp_probe_vga_then_gpu_surface() {
        let mut s = session();
        assert_eq!(s.scanout(), "vga");
        let body = eval(&mut s, "hwDispStat()").unwrap();
        assert!(body.contains("\"probed\":true"), "{body}");
        assert!(body.contains("\"kind\":\"virtio-gpu\""), "{body}");
        assert_eq!(s.scanout(), "vga");
        let err = eval(&mut s, r#"hwGlApply("")"#).unwrap_err();
        assert!(err.message.contains("GPU name"), "{err}");
        let gpu = eval(&mut s, r#"hwDispSurface("gpu")"#).unwrap();
        assert!(gpu.contains("\"surface\":\"gpu\""), "{gpu}");
        assert_eq!(s.scanout(), "gpu");
        let listing = eval(&mut s, r#"hwGl("listing")"#).unwrap();
        assert!(listing.contains("\"gl\":\"listing\""), "{listing}");
        assert!(s.env_untouched());
        let instant = eval_instant(&mut s, "HwDispStat()");
        assert!(instant.contains("HW-STAT"), "{instant}");
        assert!(instant.contains("VIRTIO-GPU"), "{instant}");
    }
}
