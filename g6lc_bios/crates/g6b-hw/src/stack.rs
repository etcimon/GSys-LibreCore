// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Isolated TCP/UDP sockets for a net adapter. Bind/connect uses the host
//! stack as WAN (userspace NAT) — never QEMU `-netdev`. Recv is non-blocking
//! so HolyC stays instant.

use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::time::Duration;

use g6b_spec::quote_json;

const MAX_SOCKS: usize = 16;
const MAX_IO: usize = 4096;

/// Non-blocking TCP read. `WouldBlock` is not peer close.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TcpRecv {
    Data(Vec<u8>),
    WouldBlock,
    Eof,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SockKind {
    TcpListen,
    Tcp,
    Udp,
}

impl SockKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::TcpListen => "tcp-listen",
            Self::Tcp => "tcp",
            Self::Udp => "udp",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SockMeta {
    pub id: u32,
    pub kind: SockKind,
    pub local: String,
    pub peer: String,
    pub device: String,
}

/// Live sockets owned by one [`crate::HwSession`].
#[derive(Debug, Default)]
pub struct InetStack {
    next: u32,
    pub meta: BTreeMap<u32, SockMeta>,
    tcp_listen: BTreeMap<u32, TcpListener>,
    tcp: BTreeMap<u32, TcpStream>,
    udp: BTreeMap<u32, UdpSocket>,
}

impl InetStack {
    pub fn json(&self) -> String {
        let items: Vec<String> = self
            .meta
            .values()
            .map(|m| {
                format!(
                    "{{\"id\":{},\"kind\":{},\"local\":{},\"peer\":{},\"dev\":{}}}",
                    m.id,
                    quote_json(m.kind.as_str()),
                    quote_json(&m.local),
                    quote_json(&m.peer),
                    quote_json(&m.device)
                )
            })
            .collect();
        format!("[{}]", items.join(","))
    }

    fn alloc(&mut self, meta: SockMeta) -> Result<u32, String> {
        if self.meta.len() >= MAX_SOCKS {
            return Err("socket budget exceeded".into());
        }
        let id = if meta.id == 0 {
            self.next = self.next.max(1);
            let id = self.next;
            self.next = self.next.saturating_add(1);
            id
        } else {
            meta.id
        };
        let mut m = meta;
        m.id = id;
        self.meta.insert(id, m);
        Ok(id)
    }

    pub fn tcp_listen(&mut self, device: &str, bind: &str, port: u16) -> Result<u32, String> {
        let addr = parse_bind(bind, port)?;
        let listener = TcpListener::bind(addr).map_err(|e| format!("tcp listen: {e}"))?;
        listener
            .set_nonblocking(true)
            .map_err(|e| format!("tcp listen nonblock: {e}"))?;
        let local = listener
            .local_addr()
            .map(|a| a.to_string())
            .unwrap_or_default();
        let id = self.alloc(SockMeta {
            id: 0,
            kind: SockKind::TcpListen,
            local,
            peer: String::new(),
            device: device.into(),
        })?;
        self.tcp_listen.insert(id, listener);
        Ok(id)
    }

    pub fn tcp_accept(&mut self, listen_id: u32) -> Result<u32, String> {
        let listener = self
            .tcp_listen
            .get(&listen_id)
            .ok_or("tcp accept: not a listen socket")?;
        match listener.accept() {
            Ok((stream, peer)) => {
                stream
                    .set_nonblocking(true)
                    .map_err(|e| format!("tcp accept nonblock: {e}"))?;
                let local = stream
                    .local_addr()
                    .map(|a| a.to_string())
                    .unwrap_or_default();
                let device = self
                    .meta
                    .get(&listen_id)
                    .map(|m| m.device.clone())
                    .unwrap_or_default();
                let id = self.alloc(SockMeta {
                    id: 0,
                    kind: SockKind::Tcp,
                    local,
                    peer: peer.to_string(),
                    device,
                })?;
                self.tcp.insert(id, stream);
                Ok(id)
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                Err("tcp accept: wouldblock".into())
            }
            Err(e) => Err(format!("tcp accept: {e}")),
        }
    }

    pub fn tcp_connect(&mut self, device: &str, host: &str, port: u16) -> Result<u32, String> {
        for _ in 0..50 {
            if let Some(id) = self.tcp_try_connect(device, host, port)? {
                return Ok(id);
            }
        }
        Err("tcp connect: wouldblock".into())
    }

    /// One bounded connect attempt. IPv4 literals only; no OS DNS, no IPv6.
    /// `None` is in-progress (poll again). Not a kept EINPROGRESS fd — std
    /// drops a timed-out connect — so each poll may SYN again.
    pub fn tcp_try_connect(
        &mut self,
        device: &str,
        host: &str,
        port: u16,
    ) -> Result<Option<u32>, String> {
        let addr = resolve_ipv4(host, port)?;
        match TcpStream::connect_timeout(&addr, Duration::from_millis(1)) {
            Ok(stream) => {
                stream
                    .set_nonblocking(true)
                    .map_err(|e| format!("tcp connect nonblock: {e}"))?;
                let local = stream
                    .local_addr()
                    .map(|a| a.to_string())
                    .unwrap_or_default();
                let id = self.alloc(SockMeta {
                    id: 0,
                    kind: SockKind::Tcp,
                    local,
                    peer: addr.to_string(),
                    device: device.into(),
                })?;
                self.tcp.insert(id, stream);
                Ok(Some(id))
            }
            Err(e)
                if e.kind() == std::io::ErrorKind::TimedOut
                    || e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::Interrupted =>
            {
                Ok(None)
            }
            Err(e) => Err(format!("tcp connect: {e}")),
        }
    }

    pub fn tcp_send(&mut self, id: u32, data: &str) -> Result<usize, String> {
        self.tcp_send_bytes(id, data.as_bytes())
    }

    pub fn tcp_send_bytes(&mut self, id: u32, data: &[u8]) -> Result<usize, String> {
        let s = self.tcp.get_mut(&id).ok_or("tcp send: no such socket")?;
        match s.write(data) {
            Ok(n) => Ok(n),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => Ok(0),
            Err(e) => Err(format!("tcp send: {e}")),
        }
    }

    pub fn tcp_recv(&mut self, id: u32) -> Result<String, String> {
        match self.tcp_recv_bytes(id)? {
            TcpRecv::Data(b) => Ok(String::from_utf8_lossy(&b).into_owned()),
            TcpRecv::WouldBlock | TcpRecv::Eof => Ok(String::new()),
        }
    }

    pub fn tcp_recv_bytes(&mut self, id: u32) -> Result<TcpRecv, String> {
        let s = self.tcp.get_mut(&id).ok_or("tcp recv: no such socket")?;
        let mut buf = [0u8; MAX_IO];
        match s.read(&mut buf) {
            Ok(0) => Ok(TcpRecv::Eof),
            Ok(n) => Ok(TcpRecv::Data(buf[..n].to_vec())),
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::Interrupted =>
            {
                Ok(TcpRecv::WouldBlock)
            }
            Err(e)
                if e.kind() == std::io::ErrorKind::ConnectionReset
                    || e.kind() == std::io::ErrorKind::ConnectionAborted
                    || e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                Ok(TcpRecv::Eof)
            }
            Err(e) => Err(format!("tcp recv: {e}")),
        }
    }

    pub fn udp_bind(&mut self, device: &str, bind: &str, port: u16) -> Result<u32, String> {
        let addr = parse_bind(bind, port)?;
        let sock = UdpSocket::bind(addr).map_err(|e| format!("udp bind: {e}"))?;
        sock.set_nonblocking(true)
            .map_err(|e| format!("udp bind nonblock: {e}"))?;
        let local = sock.local_addr().map(|a| a.to_string()).unwrap_or_default();
        let id = self.alloc(SockMeta {
            id: 0,
            kind: SockKind::Udp,
            local,
            peer: String::new(),
            device: device.into(),
        })?;
        self.udp.insert(id, sock);
        Ok(id)
    }

    pub fn udp_send(
        &mut self,
        id: u32,
        host: &str,
        port: u16,
        data: &str,
    ) -> Result<usize, String> {
        let addr = resolve_ipv4(host, port)?;
        let s = self.udp.get_mut(&id).ok_or("udp send: no such socket")?;
        match s.send_to(data.as_bytes(), addr) {
            Ok(n) => {
                if let Some(m) = self.meta.get_mut(&id) {
                    m.peer = addr.to_string();
                }
                Ok(n)
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => Ok(0),
            Err(e) => Err(format!("udp send: {e}")),
        }
    }

    pub fn udp_recv(&mut self, id: u32) -> Result<String, String> {
        let s = self.udp.get_mut(&id).ok_or("udp recv: no such socket")?;
        let mut buf = [0u8; MAX_IO];
        match s.recv_from(&mut buf) {
            Ok((n, peer)) => {
                if let Some(m) = self.meta.get_mut(&id) {
                    m.peer = peer.to_string();
                }
                Ok(String::from_utf8_lossy(&buf[..n]).into_owned())
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => Ok(String::new()),
            Err(e) => Err(format!("udp recv: {e}")),
        }
    }

    pub fn close(&mut self, id: u32) -> Result<(), String> {
        self.meta.remove(&id).ok_or("close: no such socket")?;
        if let Some(s) = self.tcp.remove(&id) {
            let _ = s.shutdown(Shutdown::Both);
        }
        self.tcp_listen.remove(&id);
        self.udp.remove(&id);
        Ok(())
    }
}

fn parse_bind(host: &str, port: u16) -> Result<SocketAddr, String> {
    let host = if host.is_empty() || host == "*" || host == "0.0.0.0" {
        "0.0.0.0"
    } else {
        host
    };
    format!("{host}:{port}")
        .parse()
        .map_err(|e| format!("bad bind {host}:{port}: {e}"))
}

/// IPv4 literals only. Hostnames need an async DNS job; IPv6 is refused.
pub fn resolve_ipv4(host: &str, port: u16) -> Result<SocketAddr, String> {
    if host.contains(':') {
        return Err("ipv6 is not implemented".into());
    }
    let ip: Ipv4Addr = host
        .parse()
        .map_err(|_| format!("dns: hostname {host} needs an async job (IPv4 literal only)"))?;
    Ok(SocketAddr::from((ip, port)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_ipv4_literal_skips_dns() {
        let a = resolve_ipv4("127.0.0.1", 80).unwrap();
        assert_eq!(a, SocketAddr::from((Ipv4Addr::LOCALHOST, 80)));
        assert!(
            resolve_ipv4("::1", 80).unwrap_err().contains("ipv6"),
            "IPv6 is a named refuse"
        );
        let e = resolve_ipv4("example.com", 80).unwrap_err();
        assert!(e.contains("dns"), "{e}");
    }

    #[test]
    fn tcp_listen_connect_send_recv_localhost() {
        let mut a = InetStack::default();
        let lid = a.tcp_listen("net0", "127.0.0.1", 0).unwrap();
        let port: u16 = a.meta[&lid]
            .local
            .rsplit(':')
            .next()
            .unwrap()
            .parse()
            .unwrap();
        let mut b = InetStack::default();
        let cid = b.tcp_connect("net0", "127.0.0.1", port).unwrap();
        let mut peer = None;
        for _ in 0..50 {
            if let Ok(id) = a.tcp_accept(lid) {
                peer = Some(id);
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let pid = peer.expect("accept");
        assert!(b.tcp_send(cid, "hello").unwrap() >= 5);
        let mut got = String::new();
        for _ in 0..50 {
            got = a.tcp_recv(pid).unwrap();
            if !got.is_empty() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert_eq!(got, "hello");
        a.close(lid).unwrap();
        b.close(cid).unwrap();
    }

    #[test]
    fn tcp_recv_distinguishes_wouldblock_and_eof() {
        let mut server = InetStack::default();
        let lid = server.tcp_listen("net0", "127.0.0.1", 0).unwrap();
        let port: u16 = server.meta[&lid]
            .local
            .rsplit(':')
            .next()
            .unwrap()
            .parse()
            .unwrap();
        let mut client = InetStack::default();
        let cid = client.tcp_connect("net0", "127.0.0.1", port).unwrap();
        let mut peer = None;
        for _ in 0..50 {
            if let Ok(id) = server.tcp_accept(lid) {
                peer = Some(id);
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        let pid = peer.expect("accept");
        assert_eq!(
            server.tcp_recv_bytes(pid).unwrap(),
            TcpRecv::WouldBlock,
            "connected with no payload is not EOF"
        );
        assert!(client.tcp_send(cid, "ping").unwrap() >= 4);
        let mut data = None;
        for _ in 0..50 {
            match server.tcp_recv_bytes(pid).unwrap() {
                TcpRecv::Data(b) if !b.is_empty() => {
                    data = Some(b);
                    break;
                }
                TcpRecv::WouldBlock => {
                    std::thread::sleep(std::time::Duration::from_millis(2));
                }
                other => panic!("unexpected while waiting for payload: {other:?}"),
            }
        }
        assert_eq!(data.unwrap(), b"ping");
        client.close(cid).unwrap();
        let mut saw_eof = false;
        for _ in 0..50 {
            match server.tcp_recv_bytes(pid).unwrap() {
                TcpRecv::Eof => {
                    saw_eof = true;
                    break;
                }
                TcpRecv::WouldBlock => {
                    std::thread::sleep(std::time::Duration::from_millis(2));
                }
                TcpRecv::Data(b) => panic!("payload after close: {b:?}"),
            }
        }
        assert!(saw_eof, "peer close is Eof, not WouldBlock");
        server.close(lid).unwrap();
        server.close(pid).unwrap();
    }

    #[test]
    fn udp_loopback_send_recv() {
        let mut a = InetStack::default();
        let mut b = InetStack::default();
        let aid = a.udp_bind("net0", "127.0.0.1", 0).unwrap();
        let port: u16 = a.meta[&aid]
            .local
            .rsplit(':')
            .next()
            .unwrap()
            .parse()
            .unwrap();
        let bid = b.udp_bind("net0", "127.0.0.1", 0).unwrap();
        assert!(b.udp_send(bid, "127.0.0.1", port, "ping").unwrap() >= 4);
        let mut got = String::new();
        for _ in 0..50 {
            got = a.udp_recv(aid).unwrap();
            if !got.is_empty() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert_eq!(got, "ping");
        a.close(aid).unwrap();
        b.close(bid).unwrap();
    }
}
