// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! In-process NAT peer at 10.0.2.2. Frames are Ethernet/IPv4/TCP in memory.
//! Not `std::net`, not QEMU `-netdev`, not a PHY.

use crate::inet::{NAT_DNS, NAT_GATEWAY};

/// Isolated NAT nameserver (`10.0.2.3`). HTTP origin stays `NAT_GATEWAY`.
const NAT_DNS_IP: [u8; 4] = [10, 0, 2, 3];
const NAT_GW_IP: [u8; 4] = [10, 0, 2, 2];

/// Same 4-byte body as the exec-model `VIRTIO-NET-HTTP` gate.
pub const NAT_HTTP_BODY: [u8; 4] = [0x00, 0xff, 0xfe, 0x80];
/// Isolated NAT MTU. Oversize + DF → ICMP dest-unreach frag-needed (type 3 code 4).
pub const NAT_MTU: u16 = 1500;
/// Advertised TCP window. Zero-window SYN is refused.
pub const NAT_TCP_WINDOW: u16 = 8192;
const IP_MF: u16 = 0x2000;
const IP_DF: u16 = 0x4000;
const IP_OFFMASK: u16 = 0x1fff;

const ETH: usize = 14;
const IP: usize = 20;
const TCP: usize = 20;
const L4: usize = ETH + IP + TCP;

/// Wrap an HTTP request in one Ethernet/IPv4/TCP PSH+ACK frame, run it
/// through the modelled gateway, and return the TCP payload (HTTP bytes).
/// Completes a SYN/SYN-ACK/ACK handshake first (listen leftover).
pub fn nat_http_on_wire(http_req: &[u8]) -> Result<Vec<u8>, String> {
    if http_req.len() < 4 || &http_req[..4] != b"GET " {
        return Err("nat packet: not GET".into());
    }
    nat_http_via_dma(http_req)
}

/// Virtio-net receiveq/transmitq in a host buffer. Layout matches
/// `g6b-asm` `NET_*` (desc 16 B, avail idx, used `{id,len}`). Not guest
/// `__vio`, not QEMU.
const VNET_RX_DESC: usize = 0x000;
const VNET_RX_AVAIL: usize = 0x080;
const VNET_RX_USED: usize = 0x0c0;
const VNET_TX_DESC: usize = 0x140;
const VNET_TX_AVAIL: usize = 0x1c0;
const VNET_TX_USED: usize = 0x200;
const VNET_RXBUF: usize = 0x280;
const VNET_TXBUF: usize = 0x3c0;
const VNET_BUF: usize = 320;
const VNET_DESC_WRITE: u16 = 2;

pub struct VirtioNetDma {
    tcp: NatTcp,
    mem: Vec<u8>,
    tx_seen: u16,
    rx_posted: u16,
    last_rx_len: u32,
    pub tx_avail: u16,
    pub tx_used: u16,
    pub rx_avail: u16,
    pub rx_used: u16,
}

impl VirtioNetDma {
    pub fn listen() -> Self {
        Self {
            tcp: NatTcp::listen(),
            mem: vec![0u8; VNET_TXBUF + VNET_BUF],
            tx_seen: 0,
            rx_posted: 0,
            last_rx_len: 0,
            tx_avail: 0,
            tx_used: 0,
            rx_avail: 0,
            rx_used: 0,
        }
    }

    pub fn post_rx(&mut self) {
        let slot = self.rx_posted % 2;
        write_desc(
            &mut self.mem,
            VNET_RX_DESC + slot as usize * 16,
            VNET_RXBUF as u64,
            VNET_BUF as u32,
            VNET_DESC_WRITE,
        );
        let idx = avail_idx(&self.mem, VNET_RX_AVAIL);
        write_u16(
            &mut self.mem,
            VNET_RX_AVAIL + 4 + (idx % 2) as usize * 2,
            slot,
        );
        write_u16(&mut self.mem, VNET_RX_AVAIL + 2, idx.wrapping_add(1));
        self.rx_posted = self.rx_posted.wrapping_add(1);
        self.rx_avail = avail_idx(&self.mem, VNET_RX_AVAIL);
    }

    pub fn post_tx(&mut self, frame: &[u8]) {
        let n = frame.len().min(VNET_BUF);
        self.mem[VNET_TXBUF..VNET_TXBUF + n].copy_from_slice(&frame[..n]);
        write_desc(&mut self.mem, VNET_TX_DESC, VNET_TXBUF as u64, n as u32, 0);
        let idx = avail_idx(&self.mem, VNET_TX_AVAIL);
        write_u16(&mut self.mem, VNET_TX_AVAIL + 4 + (idx % 2) as usize * 2, 0);
        write_u16(&mut self.mem, VNET_TX_AVAIL + 2, idx.wrapping_add(1));
        self.tx_avail = avail_idx(&self.mem, VNET_TX_AVAIL);
    }

    pub fn notify_tx(&mut self) -> Result<(), String> {
        let tx_idx = avail_idx(&self.mem, VNET_TX_AVAIL);
        while self.tx_seen != tx_idx {
            let head = avail_head(&self.mem, VNET_TX_AVAIL, self.tx_seen);
            let (addr, len, _) = read_desc(&self.mem, VNET_TX_DESC + head as usize * 16);
            let off = addr as usize;
            let n = len as usize;
            if off + n > self.mem.len() {
                return Err("virtio-net dma: TX desc".into());
            }
            let frame = self.mem[off..off + n].to_vec();
            if let Some(f) = self.tcp.push(&frame)? {
                let rx_idx = avail_idx(&self.mem, VNET_RX_AVAIL);
                if self.rx_used == rx_idx {
                    return Err("virtio-net dma: no RX buffer".into());
                }
                let rh = avail_head(&self.mem, VNET_RX_AVAIL, self.rx_used);
                let (raddr, rlen, flags) = read_desc(&self.mem, VNET_RX_DESC + rh as usize * 16);
                if flags & VNET_DESC_WRITE == 0 {
                    return Err("virtio-net dma: RX not WRITE".into());
                }
                let copy = f.len().min(rlen as usize);
                let roff = raddr as usize;
                self.mem[roff..roff + copy].copy_from_slice(&f[..copy]);
                self.last_rx_len = copy as u32;
                publish_used(&mut self.mem, VNET_RX_USED, self.rx_used, rh, copy as u32);
                self.rx_used = self.rx_used.wrapping_add(1);
            }
            publish_used(&mut self.mem, VNET_TX_USED, self.tx_seen, head, n as u32);
            self.tx_seen = self.tx_seen.wrapping_add(1);
        }
        self.tx_used = used_idx(&self.mem, VNET_TX_USED);
        self.rx_used = used_idx(&self.mem, VNET_RX_USED);
        Ok(())
    }

    pub fn rx_take(&mut self) -> Option<Vec<u8>> {
        if self.last_rx_len == 0 {
            return None;
        }
        let n = self.last_rx_len as usize;
        self.last_rx_len = 0;
        Some(self.mem[VNET_RXBUF..VNET_RXBUF + n].to_vec())
    }
}

fn write_u16(mem: &mut [u8], off: usize, v: u16) {
    mem[off..off + 2].copy_from_slice(&v.to_le_bytes());
}

fn read_u16(mem: &[u8], off: usize) -> u16 {
    u16::from_le_bytes(mem[off..off + 2].try_into().unwrap())
}

fn write_u32(mem: &mut [u8], off: usize, v: u32) {
    mem[off..off + 4].copy_from_slice(&v.to_le_bytes());
}

fn write_u64(mem: &mut [u8], off: usize, v: u64) {
    mem[off..off + 8].copy_from_slice(&v.to_le_bytes());
}

fn read_u32(mem: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(mem[off..off + 4].try_into().unwrap())
}

fn read_u64(mem: &[u8], off: usize) -> u64 {
    u64::from_le_bytes(mem[off..off + 8].try_into().unwrap())
}

fn write_desc(mem: &mut [u8], off: usize, addr: u64, len: u32, flags: u16) {
    write_u64(mem, off, addr);
    write_u32(mem, off + 8, len);
    write_u16(mem, off + 12, flags);
    write_u16(mem, off + 14, 0);
}

fn read_desc(mem: &[u8], off: usize) -> (u64, u32, u16) {
    (
        read_u64(mem, off),
        read_u32(mem, off + 8),
        read_u16(mem, off + 12),
    )
}

fn avail_idx(mem: &[u8], off: usize) -> u16 {
    read_u16(mem, off + 2)
}

fn used_idx(mem: &[u8], off: usize) -> u16 {
    read_u16(mem, off + 2)
}

fn avail_head(mem: &[u8], off: usize, seen: u16) -> u16 {
    read_u16(mem, off + 4 + (seen % 2) as usize * 2)
}

fn publish_used(mem: &mut [u8], off: usize, idx: u16, head: u16, len: u32) {
    let slot = (idx % 2) as usize;
    write_u32(mem, off + 4 + slot * 8, u32::from(head));
    write_u32(mem, off + 8 + slot * 8, len);
    write_u16(mem, off + 2, idx.wrapping_add(1));
}

pub fn nat_http_via_dma(http_req: &[u8]) -> Result<Vec<u8>, String> {
    let mut v = VirtioNetDma::listen();
    v.post_rx();
    v.post_tx(&encapsulate_tcp(&[], 1, 0, 0x02));
    v.notify_tx()?;
    let synack = v.rx_take().ok_or("virtio-net dma: no SYN-ACK")?;
    if synack.len() < L4 || synack[47] != 0x12 {
        return Err("virtio-net dma: SYN-ACK flags".into());
    }
    let ack_n = u32::from_be_bytes(synack[42..46].try_into().unwrap());
    v.post_tx(&encapsulate_tcp(&[], 2, ack_n, 0x10));
    v.notify_tx()?;
    v.post_rx();
    v.post_tx(&encapsulate_tcp(http_req, 2, ack_n, 0x18));
    v.notify_tx()?;
    let rx = v.rx_take().ok_or("virtio-net dma: no HTTP")?;
    if rx.len() < L4 {
        return Err("virtio-net dma: short reply".into());
    }
    Ok(rx[L4..].to_vec())
}

/// Modelled TCP listener on 10.0.2.2:80. SYN → SYN-ACK, ACK → established,
/// then GET → HTTP 200. Not a real listen backlog, not QEMU.
pub struct NatTcp {
    state: u8,
}

impl NatTcp {
    pub fn listen() -> Self {
        Self { state: 0 }
    }

    pub fn push(&mut self, frame: &[u8]) -> Result<Option<Vec<u8>>, String> {
        if frame.len() < L4 || frame[23] != 6 || frame[37] != 80 {
            return Err("nat tcp: not TCP :80".into());
        }
        let flags = frame[47];
        match self.state {
            0 => {
                if flags != 0x02 {
                    return Err("nat tcp: listen wants SYN".into());
                }
                if tcp_window(frame) == 0 {
                    return Err("nat tcp: zero window".into());
                }
                let seq = u32::from_be_bytes(frame[38..42].try_into().unwrap());
                self.state = 1;
                Ok(Some(syn_ack(frame, seq.wrapping_add(1))))
            }
            1 => {
                if flags & 0x10 == 0 {
                    return Err("nat tcp: want ACK".into());
                }
                self.state = 2;
                Ok(None)
            }
            2 => {
                if frame.len() < L4 + 4 || &frame[L4..L4 + 4] != b"GET " {
                    return Err("nat tcp: established wants GET".into());
                }
                Ok(Some(gateway(frame)?))
            }
            _ => Err("nat tcp: closed".into()),
        }
    }
}

fn syn_ack(tx: &[u8], ack: u32) -> Vec<u8> {
    let mut rx = vec![0u8; L4];
    rx[..ETH].copy_from_slice(&tx[..ETH]);
    rx.swap(0, 6);
    rx.swap(1, 7);
    rx.swap(2, 8);
    rx.swap(3, 9);
    rx.swap(4, 10);
    rx.swap(5, 11);
    rx[12] = 0x08;
    rx[13] = 0x00;
    rx[14] = 0x45;
    let tot = (IP + TCP) as u16;
    rx[16] = (tot >> 8) as u8;
    rx[17] = tot as u8;
    rx[22] = 64;
    rx[23] = 6;
    rx[26..30].copy_from_slice(&[10, 0, 2, 2]);
    rx[30..34].copy_from_slice(&[10, 0, 2, 15]);
    rx[34] = 0;
    rx[35] = 80;
    rx[36] = 0x30;
    rx[37] = 0x39;
    rx[38..42].copy_from_slice(&1000u32.to_be_bytes());
    rx[42..46].copy_from_slice(&ack.to_be_bytes());
    rx[46] = 0x50;
    rx[47] = 0x12;
    set_tcp_window(&mut rx, NAT_TCP_WINDOW);
    rx
}

fn tcp_window(frame: &[u8]) -> u16 {
    if frame.len() < 50 {
        0
    } else {
        u16::from_be_bytes([frame[48], frame[49]])
    }
}

fn set_tcp_window(frame: &mut [u8], w: u16) {
    if frame.len() >= 50 {
        frame[48] = (w >> 8) as u8;
        frame[49] = w as u8;
    }
}

/// Collect TCP payloads by sequence. A reply is produced only when a
/// contiguous GET from seq 0 includes `\r\n\r\n`. Out-of-order segments
/// wait. Not an RTO, not QEMU.
#[derive(Default)]
pub struct NatHttpReasm {
    parts: std::collections::BTreeMap<u32, Vec<u8>>,
}

impl NatHttpReasm {
    pub fn push_frame(&mut self, frame: &[u8]) -> Result<Option<Vec<u8>>, String> {
        if frame.len() < L4 || frame[23] != 6 || frame[37] != 80 {
            return Err("nat reasm: not TCP :80".into());
        }
        let seq = u32::from_be_bytes(frame[38..42].try_into().unwrap());
        self.parts.insert(seq, frame[L4..].to_vec());
        let mut acc = Vec::new();
        let mut expect = 0u32;
        loop {
            let Some(p) = self.parts.get(&expect) else {
                break;
            };
            acc.extend_from_slice(p);
            expect = expect.wrapping_add(p.len() as u32);
        }
        if acc.windows(4).any(|w| w == b"\r\n\r\n") && acc.starts_with(b"GET ") {
            let rx = gateway(&encapsulate_seq(&acc, 0))?;
            return Ok(Some(rx[L4..].to_vec()));
        }
        Ok(None)
    }
}

/// Ethernet/IPv4/TCP frame with an explicit sequence number (PSH+ACK).
pub fn encapsulate_seq(payload: &[u8], seq: u32) -> Vec<u8> {
    encapsulate_tcp(payload, seq, 0, 0x18)
}

pub fn encapsulate_tcp(payload: &[u8], seq: u32, ack: u32, flags: u8) -> Vec<u8> {
    let mut f = vec![0u8; L4 + payload.len()];
    f[0..6].fill(0x52);
    f[6..12].fill(0x52);
    f[12] = 0x08;
    f[13] = 0x00;
    f[14] = 0x45;
    let tot = (IP + TCP + payload.len()) as u16;
    f[16] = (tot >> 8) as u8;
    f[17] = tot as u8;
    f[20] = 0x40; // DF
    f[22] = 64;
    f[23] = 6;
    f[30..34].copy_from_slice(&[10, 0, 2, 2]);
    f[34] = 0x30;
    f[35] = 0x39;
    f[37] = 80;
    f[38..42].copy_from_slice(&seq.to_be_bytes());
    f[42..46].copy_from_slice(&ack.to_be_bytes());
    f[46] = 0x50;
    f[47] = flags;
    set_tcp_window(&mut f, NAT_TCP_WINDOW);
    f[L4..].copy_from_slice(payload);
    f
}

fn ip_id(frame: &[u8]) -> u16 {
    u16::from_be_bytes([frame[18], frame[19]])
}

fn ip_off(frame: &[u8]) -> u16 {
    u16::from_be_bytes([frame[20], frame[21]])
}

/// MF or a nonzero fragment offset. First-fragment-only GET is not a datagram.
pub fn ip_is_fragment(frame: &[u8]) -> bool {
    if frame.len() < ETH + IP {
        return false;
    }
    let fo = ip_off(frame);
    fo & IP_MF != 0 || fo & IP_OFFMASK != 0
}

/// Split IPv4 payload into `chunk`-byte fragments (`chunk` multiple of 8).
/// DF is a hard refuse (B199 ICMP path). Not overlapping fragments, not QEMU.
pub fn ip_fragment(frame: &[u8], chunk: usize) -> Result<Vec<Vec<u8>>, String> {
    if frame.len() < ETH + IP {
        return Err("ip frag: short".into());
    }
    if ip_off(frame) & IP_DF != 0 {
        return Err("ip frag: DF".into());
    }
    if chunk == 0 || chunk % 8 != 0 {
        return Err("ip frag: chunk".into());
    }
    let payload = &frame[ETH + IP..];
    if payload.is_empty() {
        return Err("ip frag: empty".into());
    }
    if payload.len() <= chunk {
        return Ok(vec![frame.to_vec()]);
    }
    let mut id = ip_id(frame);
    if id == 0 {
        id = 1;
    }
    let mut out = Vec::new();
    let mut off = 0usize;
    while off < payload.len() {
        let n = chunk.min(payload.len() - off);
        let last = off + n >= payload.len();
        let mut f = frame[..ETH + IP].to_vec();
        f.extend_from_slice(&payload[off..off + n]);
        let tot = (IP + n) as u16;
        f[16] = (tot >> 8) as u8;
        f[17] = tot as u8;
        f[18] = (id >> 8) as u8;
        f[19] = id as u8;
        let units = (off / 8) as u16;
        let flags = if last { 0 } else { IP_MF } | units;
        f[20] = (flags >> 8) as u8;
        f[21] = flags as u8;
        out.push(f);
        off += n;
    }
    Ok(out)
}

/// Collect IPv4 fragments by offset. A datagram is produced only when
/// offset 0 and the last (MF=0) fragment cover a contiguous payload.
/// Out-of-order waits. Not a reassembly timeout, not overlapping, not QEMU.
#[derive(Default)]
pub struct IpReasm {
    id: u16,
    parts: std::collections::BTreeMap<u16, Vec<u8>>,
    last_end: Option<usize>,
    hdr: Vec<u8>,
}

impl IpReasm {
    pub fn push_frame(&mut self, frame: &[u8]) -> Result<Option<Vec<u8>>, String> {
        if frame.len() < ETH + IP || frame[14] != 0x45 {
            return Err("ip reasm: not IPv4".into());
        }
        let payload = frame[ETH + IP..].to_vec();
        if payload.is_empty() {
            return Err("ip reasm: empty".into());
        }
        let id = ip_id(frame);
        let fo = ip_off(frame);
        let off = fo & IP_OFFMASK;
        let mf = fo & IP_MF != 0;
        if self.parts.is_empty() {
            self.id = id;
        } else if id != self.id {
            return Err("ip reasm: id".into());
        }
        if off == 0 {
            self.hdr = frame[..ETH + IP].to_vec();
        }
        let plen = payload.len();
        self.parts.insert(off, payload);
        if !mf {
            let end = (off as usize) * 8 + plen;
            if let Some(prev) = self.last_end {
                if prev != end {
                    return Err("ip reasm: last".into());
                }
            }
            self.last_end = Some(end);
        }
        self.try_join()
    }

    fn try_join(&self) -> Result<Option<Vec<u8>>, String> {
        let Some(total) = self.last_end else {
            return Ok(None);
        };
        if self.hdr.len() < ETH + IP {
            return Ok(None);
        }
        let mut acc = Vec::new();
        let mut expect = 0u16;
        loop {
            let Some(p) = self.parts.get(&expect) else {
                break;
            };
            acc.extend_from_slice(p);
            if p.len() % 8 != 0 {
                break;
            }
            let step = (p.len() / 8) as u16;
            if step == 0 {
                return Err("ip reasm: empty".into());
            }
            expect = expect.wrapping_add(step);
        }
        if acc.len() != total {
            return Ok(None);
        }
        let mut out = self.hdr.clone();
        let tot = (IP + acc.len()) as u16;
        out[16] = (tot >> 8) as u8;
        out[17] = tot as u8;
        out[20] = 0;
        out[21] = 0;
        out.extend_from_slice(&acc);
        Ok(Some(out))
    }
}

/// ICMP dest-unreach fragmentation-needed when IPv4 totlen > `mtu` and DF is set.
pub fn icmp_frag_needed(tx: &[u8], mtu: u16) -> Option<Vec<u8>> {
    if tx.len() < ETH + IP {
        return None;
    }
    let tot = u16::from_be_bytes([tx[16], tx[17]]);
    if tot <= mtu || tx[20] & 0x40 == 0 {
        return None;
    }
    let orig = (IP + 8).min(tx.len() - ETH);
    let mut rx = vec![0u8; ETH + IP + 8 + orig];
    rx[..ETH].copy_from_slice(&tx[..ETH]);
    rx.swap(0, 6);
    rx.swap(1, 7);
    rx.swap(2, 8);
    rx.swap(3, 9);
    rx.swap(4, 10);
    rx.swap(5, 11);
    rx[12] = 0x08;
    rx[13] = 0x00;
    rx[14] = 0x45;
    let ipt = (IP + 8 + orig) as u16;
    rx[16] = (ipt >> 8) as u8;
    rx[17] = ipt as u8;
    rx[22] = 64;
    rx[23] = 1;
    rx[26..30].copy_from_slice(&[10, 0, 2, 2]);
    rx[30..34].copy_from_slice(&[10, 0, 2, 15]);
    rx[ETH + IP] = 3;
    rx[ETH + IP + 1] = 4;
    rx[ETH + IP + 6] = (mtu >> 8) as u8;
    rx[ETH + IP + 7] = mtu as u8;
    rx[ETH + IP + 8..].copy_from_slice(&tx[ETH..ETH + orig]);
    Some(rx)
}

fn gateway(tx: &[u8]) -> Result<Vec<u8>, String> {
    if let Some(icmp) = icmp_frag_needed(tx, NAT_MTU) {
        return Ok(icmp);
    }
    if ip_is_fragment(tx) {
        return Err("nat packet: fragment".into());
    }
    if tx.len() < L4 + 4 || tx[23] != 6 || tx[37] != 80 {
        return Err("nat packet: not TCP :80".into());
    }
    if &tx[L4..L4 + 4] != b"GET " {
        return Err("nat packet: not GET".into());
    }
    let http = b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n";
    let mut rx = vec![0u8; L4 + http.len() + NAT_HTTP_BODY.len()];
    rx[..ETH].copy_from_slice(&tx[..ETH]);
    rx.swap(0, 6);
    rx.swap(1, 7);
    rx.swap(2, 8);
    rx.swap(3, 9);
    rx.swap(4, 10);
    rx.swap(5, 11);
    rx[12] = 0x08;
    rx[13] = 0x00;
    rx[14] = 0x45;
    let tot = (IP + TCP + http.len() + NAT_HTTP_BODY.len()) as u16;
    rx[16] = (tot >> 8) as u8;
    rx[17] = tot as u8;
    rx[22] = 64;
    rx[23] = 6;
    rx[26..30].copy_from_slice(&[10, 0, 2, 2]);
    rx[30..34].copy_from_slice(&[10, 0, 2, 15]);
    rx[34] = 0;
    rx[35] = 80;
    rx[36] = 0x30;
    rx[37] = 0x39;
    rx[46] = 0x50;
    rx[47] = 0x18;
    set_tcp_window(&mut rx, NAT_TCP_WINDOW);
    rx[L4..L4 + http.len()].copy_from_slice(http);
    rx[L4 + http.len()..].copy_from_slice(&NAT_HTTP_BODY);
    Ok(rx)
}

pub fn is_nat_http_host(host: &str, port: u16) -> bool {
    host == NAT_GATEWAY && port == 80
}

/// Next-hop IPv4 for a NAT HTTP GET. The nameserver is not an origin.
pub fn nat_http_dst(ip: [u8; 4]) -> Result<(), String> {
    if ip == NAT_GW_IP {
        Ok(())
    } else {
        Err(format!("dns: origin mismatch {ip:?}"))
    }
}

/// Isolated NAT name from the exec-model DNS A (`g6lc` → 10.0.2.2).
pub fn is_nat_dns_name(host: &str) -> bool {
    host.strip_suffix('.')
        .unwrap_or(host)
        .eq_ignore_ascii_case("g6lc")
}

const UDP: usize = 8;
const DN: usize = ETH + IP + UDP;

/// UDP DNS A query to `NAT_DNS` :53. One label only. Not OS DNS.
pub fn encapsulate_dns_a(name: &str) -> Result<Vec<u8>, String> {
    let labels = name.strip_suffix('.').unwrap_or(name);
    if labels.is_empty()
        || labels.len() > 63
        || labels.contains('.')
        || !labels
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err("dns: name".into());
    }
    let q = 1 + labels.len() + 1 + 4;
    let mut f = vec![0u8; DN + 12 + q];
    f[12] = 0x08;
    f[13] = 0x00;
    f[14] = 0x45;
    let tot = (IP + UDP + 12 + q) as u16;
    f[16] = (tot >> 8) as u8;
    f[17] = tot as u8;
    f[22] = 64;
    f[23] = 17;
    f[26..30].copy_from_slice(&[10, 0, 2, 15]);
    f[30..34].copy_from_slice(&NAT_DNS_IP);
    f[34] = 0x30;
    f[35] = 0x39;
    f[37] = 53;
    let ulen = (UDP + 12 + q) as u16;
    f[38] = (ulen >> 8) as u8;
    f[39] = ulen as u8;
    f[DN + 4] = 0x01;
    f[DN + 7] = 1;
    f[DN + 12] = labels.len() as u8;
    f[DN + 13..DN + 13 + labels.len()].copy_from_slice(labels.as_bytes());
    let end = DN + 13 + labels.len();
    f[end] = 0;
    f[end + 2] = 1;
    f[end + 4] = 1;
    Ok(f)
}

/// Answer an isolated NAT A query on `NAT_DNS`. Only `g6lc` → gateway. Not recursive.
pub fn dns_gateway(tx: &[u8]) -> Result<Vec<u8>, String> {
    if tx.len() < DN + 18 || tx[23] != 17 || tx[37] != 53 {
        return Err("dns: not UDP :53".into());
    }
    if tx[30..34] != NAT_DNS_IP {
        return Err(format!("dns: not nameserver {NAT_DNS}"));
    }
    let mut i = DN + 12;
    let n = tx[i] as usize;
    i += 1;
    if i + n + 5 > tx.len() {
        return Err("dns: qname".into());
    }
    let name = std::str::from_utf8(&tx[i..i + n]).map_err(|_| "dns: qname")?;
    i += n;
    if tx[i] != 0 {
        return Err("dns: extra labels".into());
    }
    if !is_nat_dns_name(name) {
        return Err(format!("dns: nxdomain {name}"));
    }
    let mut rx = tx.to_vec();
    rx.swap(0, 6);
    rx.swap(1, 7);
    rx.swap(2, 8);
    rx.swap(3, 9);
    rx.swap(4, 10);
    rx.swap(5, 11);
    rx[26..30].copy_from_slice(&NAT_DNS_IP);
    rx[30..34].copy_from_slice(&[10, 0, 2, 15]);
    rx[34] = 0;
    rx[35] = 53;
    rx[36] = 0x30;
    rx[37] = 0x39;
    rx[DN + 2] = 0x81;
    rx[DN + 3] = 0x80;
    rx[DN + 7] = 1;
    rx[DN + 9] = 1;
    rx.extend_from_slice(&[
        0xc0,
        0x0c,
        0x00,
        0x01,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x3c,
        0x00,
        0x04,
        NAT_GW_IP[0],
        NAT_GW_IP[1],
        NAT_GW_IP[2],
        NAT_GW_IP[3],
    ]);
    let tot = (rx.len() - ETH) as u16;
    rx[16] = (tot >> 8) as u8;
    rx[17] = tot as u8;
    let ulen = (rx.len() - ETH - IP) as u16;
    rx[38] = (ulen >> 8) as u8;
    rx[39] = ulen as u8;
    Ok(rx)
}

/// Isolated NAT A lookup. Not `getaddrinfo`.
pub fn nat_dns_a(name: &str) -> Result<[u8; 4], String> {
    let q = encapsulate_dns_a(name)?;
    let rx = dns_gateway(&q)?;
    if rx[DN + 2] & 0x80 == 0 {
        return Err("dns: not a response".into());
    }
    let n = rx.len();
    if n < 4 {
        return Err("dns: short A".into());
    }
    Ok([rx[n - 4], rx[n - 3], rx[n - 2], rx[n - 1]])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nat_http_on_wire_returns_binary_body() {
        let req = b"GET /fw.bin HTTP/1.1\r\nHost: 10.0.2.2\r\n\r\n";
        let resp = nat_http_on_wire(req).unwrap();
        assert!(
            resp.starts_with(b"HTTP/1.1 200 OK"),
            "{}",
            String::from_utf8_lossy(&resp)
        );
        assert_eq!(&resp[resp.len() - 4..], &NAT_HTTP_BODY);
    }

    #[test]
    fn nat_http_reasm_joins_split_get_out_of_order() {
        let req = b"GET /fw.bin HTTP/1.1\r\nHost: 10.0.2.2\r\n\r\n";
        let mid = 12;
        let a = encapsulate_seq(&req[..mid], 0);
        let b = encapsulate_seq(&req[mid..], mid as u32);
        let mut r = NatHttpReasm::default();
        assert!(r.push_frame(&b).unwrap().is_none(), "gap at seq 0");
        let resp = r.push_frame(&a).unwrap().expect("contiguous GET");
        assert_eq!(&resp[resp.len() - 4..], &NAT_HTTP_BODY);
    }

    #[test]
    fn nat_tcp_listen_wants_syn_then_get() {
        let mut t = NatTcp::listen();
        assert!(t.push(&encapsulate_tcp(b"GET ", 0, 0, 0x18)).is_err());
        let synack = t
            .push(&encapsulate_tcp(&[], 1, 0, 0x02))
            .unwrap()
            .expect("SYN-ACK");
        assert_eq!(synack[47], 0x12);
        assert_eq!(tcp_window(&synack), NAT_TCP_WINDOW);
        let mut z = encapsulate_tcp(&[], 1, 0, 0x02);
        set_tcp_window(&mut z, 0);
        assert!(NatTcp::listen()
            .push(&z)
            .unwrap_err()
            .contains("zero window"));
        assert!(t.push(&encapsulate_tcp(&[], 2, 2, 0x10)).unwrap().is_none());
        let req = b"GET /fw.bin HTTP/1.1\r\nHost: 10.0.2.2\r\n\r\n";
        let resp = t
            .push(&encapsulate_tcp(req, 2, 1001, 0x18))
            .unwrap()
            .expect("HTTP");
        assert_eq!(&resp[resp.len() - 4..], &NAT_HTTP_BODY);
    }

    #[test]
    fn virtio_net_dma_used_idx_tracks_handshake_and_get() {
        let mut v = VirtioNetDma::listen();
        v.post_rx();
        v.post_tx(&encapsulate_tcp(&[], 1, 0, 0x02));
        v.notify_tx().unwrap();
        assert_eq!((v.tx_used, v.rx_used), (1, 1));
        let synack = v.rx_take().unwrap();
        assert_eq!(synack[47], 0x12);
        let ack_n = u32::from_be_bytes(synack[42..46].try_into().unwrap());
        v.post_tx(&encapsulate_tcp(&[], 2, ack_n, 0x10));
        v.notify_tx().unwrap();
        assert_eq!((v.tx_used, v.rx_used), (2, 1), "ACK is silent on RX");
        let req = b"GET /fw.bin HTTP/1.1\r\nHost: 10.0.2.2\r\n\r\n";
        v.post_rx();
        v.post_tx(&encapsulate_tcp(req, 2, ack_n, 0x18));
        v.notify_tx().unwrap();
        assert_eq!((v.tx_used, v.rx_used), (3, 2));
        let http = v.rx_take().unwrap();
        assert_eq!(&http[http.len() - 4..], &NAT_HTTP_BODY);
        assert_eq!(
            read_u16(&v.mem, VNET_RX_DESC + 12),
            VNET_DESC_WRITE,
            "RX desc DEVICE_WRITE"
        );
        assert_eq!(used_idx(&v.mem, VNET_TX_USED), 3);
        assert_eq!(used_idx(&v.mem, VNET_RX_USED), 2);
    }

    #[test]
    fn icmp_frag_needed_when_df_and_over_mtu() {
        let req = b"GET /fw.bin HTTP/1.1\r\nHost: 10.0.2.2\r\n\r\n";
        let mut f = encapsulate_tcp(req, 0, 0, 0x18);
        let tot = u16::from_be_bytes([f[16], f[17]]);
        assert!(tot > 40, "GET IP totlen {tot}");
        let icmp = icmp_frag_needed(&f, 40).expect("DF oversize");
        assert_eq!(icmp[ETH + IP], 3);
        assert_eq!(icmp[ETH + IP + 1], 4);
        assert_eq!(
            u16::from_be_bytes([icmp[ETH + IP + 6], icmp[ETH + IP + 7]]),
            40
        );
        f[20] = 0;
        assert!(icmp_frag_needed(&f, 40).is_none(), "no DF, no ICMP");
        assert!(
            icmp_frag_needed(&encapsulate_tcp(req, 0, 0, 0x18), NAT_MTU).is_none(),
            "under NAT_MTU"
        );
    }

    #[test]
    fn ip_reasm_joins_split_get_out_of_order() {
        let req = b"GET /fw.bin HTTP/1.1\r\nHost: 10.0.2.2\r\n\r\n";
        let mut full = encapsulate_tcp(req, 0, 0, 0x18);
        full[20] = 0;
        let frags = ip_fragment(&full, 24).unwrap();
        assert!(frags.len() >= 2, "need a split datagram");
        assert!(ip_is_fragment(&frags[0]), "first keeps MF");
        assert!(
            gateway(&frags[0]).is_err(),
            "first fragment is not a GET datagram"
        );
        assert!(ip_fragment(&encapsulate_tcp(req, 0, 0, 0x18), 24).is_err());
        let mut r = IpReasm::default();
        for (i, f) in frags.iter().enumerate().rev() {
            let got = r.push_frame(f).unwrap();
            if i > 0 {
                assert!(got.is_none(), "gap until offset 0");
            } else {
                let assembled = got.expect("contiguous datagram");
                assert!(!ip_is_fragment(&assembled));
                let resp = gateway(&assembled).unwrap();
                assert_eq!(&resp[resp.len() - 4..], &NAT_HTTP_BODY);
            }
        }
    }

    #[test]
    fn nat_dns_a_g6lc_is_gateway() {
        assert_eq!(NAT_DNS, "10.0.2.3");
        assert!(is_nat_dns_name("g6lc"));
        assert!(is_nat_dns_name("g6lc."));
        assert!(!is_nat_dns_name("g6lc.invalid"));
        assert_eq!(nat_dns_a("g6lc").unwrap(), NAT_GW_IP);
        assert!(nat_dns_a("g6lc.invalid").is_err());
        let q = encapsulate_dns_a("g6lc").unwrap();
        assert_eq!(&q[30..34], &NAT_DNS_IP);
        let rx = dns_gateway(&q).unwrap();
        assert_eq!(&rx[26..30], &NAT_DNS_IP);
        assert_eq!(rx[DN + 2], 0x81);
        assert_eq!(rx[DN + 9], 1);
        assert_eq!(&rx[rx.len() - 4..], &NAT_GW_IP);
        let mut to_gw = q;
        to_gw[30..34].copy_from_slice(&NAT_GW_IP);
        assert!(
            dns_gateway(&to_gw).unwrap_err().contains("nameserver"),
            "HTTP gateway is not the nameserver"
        );
        assert!(nat_http_dst(NAT_GW_IP).is_ok());
        assert!(nat_http_dst(NAT_DNS_IP).unwrap_err().contains("origin"));
    }
}
