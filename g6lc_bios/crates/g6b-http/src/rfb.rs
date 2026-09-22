// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! RFB 3.8 security types. None and DES VNC-auth are refused (P8).
//! TLS type 18 still requires the P6 handshake; this is not a VNC server.

#![allow(missing_docs)]

pub const VERSION: &[u8] = b"RFB 003.008\n";
pub const SEC_NONE: u8 = 1;
pub const SEC_VNC: u8 = 2;
pub const SEC_TLS: u8 = 18;

/// Server offers only TLS. `n=1`, type 18.
pub fn offer_security() -> Vec<u8> {
    vec![1, SEC_TLS]
}

pub fn select_security(typ: u8) -> Result<(), String> {
    match typ {
        SEC_NONE => Err("rfb: None auth refused".into()),
        SEC_VNC => Err("rfb: DES VNC-auth refused".into()),
        SEC_TLS => Ok(()),
        _ => Err("rfb: unknown security".into()),
    }
}

const ENC_RAW: i32 = 0;
const ENC_COPYRECT: i32 = 1;
const ENC_RRE: i32 = 2;
const ENC_HEXTILE: i32 = 5;
const ENC_TIGHT: i32 = 7;
const ENC_ZRLE: i32 = 16;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RfbPhase {
    Version,
    Security,
    Tls,
    Ready,
    Handoff,
}

/// RFB 3.8 server. No framebuffer bytes until TLS completes. Not a VNC server.
#[derive(Debug)]
pub struct RfbServer {
    pub phase: RfbPhase,
    pub w: u16,
    pub h: u16,
    pub view_only: bool,
    /// Committed-frame generation. Pixels come only from [`Self::commit_pixels`].
    pub gen: u32,
    pub damage: (u16, u16, u16, u16),
    frame: Option<Vec<u8>>,
}

impl RfbServer {
    pub fn new(w: u16, h: u16) -> Self {
        Self {
            phase: RfbPhase::Version,
            w,
            h,
            view_only: false,
            gen: 0,
            damage: (0, 0, 0, 0),
            frame: None,
        }
    }

    pub fn view_only(mut self) -> Self {
        self.view_only = true;
        self
    }

    pub fn greeting(&self) -> &'static [u8] {
        VERSION
    }

    pub fn client_version(&mut self, v: &[u8]) -> Result<Vec<u8>, String> {
        if self.phase != RfbPhase::Version {
            return Err("rfb: not waiting for version".into());
        }
        if v == b"RFB 003.003\n" {
            return Err("rfb: 3.3 refused".into());
        }
        if v != VERSION {
            return Err("rfb: version".into());
        }
        self.phase = RfbPhase::Security;
        Ok(offer_security())
    }

    pub fn client_security(&mut self, typ: u8) -> Result<(), String> {
        if self.phase != RfbPhase::Security {
            return Err("rfb: not waiting for security".into());
        }
        select_security(typ)?;
        self.phase = RfbPhase::Tls;
        Ok(())
    }

    /// RFB SecurityResult OK (0). Sent after TLS type is selected, before Ready.
    pub fn security_result(&self) -> Result<[u8; 4], String> {
        if self.phase != RfbPhase::Tls && self.phase != RfbPhase::Ready {
            return Err("rfb: security result".into());
        }
        Ok([0, 0, 0, 0])
    }

    /// Explicit after P6 TLS. Does not invent pixels.
    pub fn tls_complete(&mut self) -> Result<(), String> {
        if self.phase != RfbPhase::Tls {
            return Err("rfb: tls not pending".into());
        }
        self.phase = RfbPhase::Ready;
        Ok(())
    }

    pub fn set_encodings(&self, enc: &[i32]) -> Result<(), String> {
        if self.phase != RfbPhase::Ready {
            return Err("rfb: not authenticated".into());
        }
        if enc.is_empty() || enc.len() > 8 {
            return Err("rfb: encodings".into());
        }
        for e in enc {
            if *e == ENC_TIGHT {
                return Err("rfb: Tight encoding refused".into());
            }
            if *e == ENC_COPYRECT {
                return Err("rfb: CopyRect encoding refused".into());
            }
            if *e == ENC_RRE {
                return Err("rfb: RRE encoding refused".into());
            }
            if *e == ENC_HEXTILE {
                return Err("rfb: Hextile encoding refused".into());
            }
            if *e == ENC_ZRLE {
                return Err("rfb: ZRLE encoding refused".into());
            }
            if *e < 0 {
                return Err("rfb: file-transfer encoding refused".into());
            }
            if *e != ENC_RAW {
                return Err("rfb: encoding refused".into());
            }
        }
        Ok(())
    }

    /// Both RFB and KVM must stop before LinuxEnter. Not a pixel dump.
    pub fn terminate_for_linux(&mut self) {
        self.phase = RfbPhase::Handoff;
        self.gen = 0;
        self.frame = None;
    }

    /// ServerInit geometry after TLS. No pixel bytes.
    pub fn server_init(&self) -> Result<Vec<u8>, String> {
        if self.phase != RfbPhase::Ready {
            return Err("rfb: not authenticated".into());
        }
        let mut v = Vec::new();
        v.extend_from_slice(&self.w.to_be_bytes());
        v.extend_from_slice(&self.h.to_be_bytes());
        v.extend_from_slice(&[32, 24, 0, 1, 0, 0xff, 0, 0xff, 0, 0xff, 0, 8, 16, 0, 0, 0]);
        let name = b"g6lc-bios";
        v.extend_from_slice(&(name.len() as u32).to_be_bytes());
        v.extend_from_slice(name);
        Ok(v)
    }

    /// Bump generation. Raw pixels only if [`Self::commit_pixels`] ran.
    pub fn commit_frame(&mut self) {
        self.commit_damage(0, 0, self.w, self.h);
    }

    /// Damage metadata. No pixels unless a committed buffer exists.
    pub fn commit_damage(&mut self, x: u16, y: u16, w: u16, h: u16) {
        self.gen = self.gen.wrapping_add(1);
        self.damage = (x, y, w, h);
    }

    /// Install a committed 32bpp buffer (LE, R<<16 G<<8 B<<0). Size must match.
    pub fn commit_pixels(&mut self, px: &[u8]) -> Result<(), String> {
        let need = (self.w as usize)
            .saturating_mul(self.h as usize)
            .saturating_mul(4);
        if px.len() != need {
            return Err("rfb: pixel size".into());
        }
        self.frame = Some(px.to_vec());
        self.commit_frame();
        Ok(())
    }

    pub fn committed_pixels(&self) -> Option<&[u8]> {
        self.frame.as_deref()
    }

    /// Zero rectangles until a committed buffer exists. Then one raw rect.
    pub fn framebuffer_update(&self) -> Result<Vec<u8>, String> {
        if self.phase != RfbPhase::Ready {
            return Err("rfb: framebuffer before auth".into());
        }
        let Some(px) = &self.frame else {
            return Ok(vec![0, 0, 0, 0]);
        };
        let (x, y, rw, rh) = self.damage;
        if x >= self.w || y >= self.h || rw == 0 || rh == 0 {
            return Ok(vec![0, 0, 0, 0]);
        }
        let rw = rw.min(self.w - x);
        let rh = rh.min(self.h - y);
        let mut body = Vec::new();
        for row in 0..rh {
            let src = ((y as usize + row as usize) * self.w as usize + x as usize) * 4;
            body.extend_from_slice(&px[src..src + rw as usize * 4]);
        }
        let mut v = vec![0, 0, 0, 1];
        v.extend_from_slice(&x.to_be_bytes());
        v.extend_from_slice(&y.to_be_bytes());
        v.extend_from_slice(&rw.to_be_bytes());
        v.extend_from_slice(&rh.to_be_bytes());
        v.extend_from_slice(&0i32.to_be_bytes());
        v.extend(body);
        Ok(v)
    }

    /// Pointer (5) / key (4) refused in view-only. Clipboard (6) always refused.
    pub fn client_message(&self, msg: &[u8]) -> Result<(), String> {
        if self.phase != RfbPhase::Ready {
            return Err("rfb: not authenticated".into());
        }
        let t = *msg.first().ok_or("rfb: empty")?;
        match t {
            0 => {
                if msg.len() < 20 {
                    return Err("rfb: pixel format".into());
                }
                if msg[4] != 32 || msg[5] != 24 || msg[6] != 0 || msg[7] != 1 {
                    return Err("rfb: 32bpp true-color required".into());
                }
                if msg[8] != 0
                    || msg[9] != 0xff
                    || msg[10] != 0
                    || msg[11] != 0xff
                    || msg[12] != 0
                    || msg[13] != 0xff
                {
                    return Err("rfb: colour max".into());
                }
                if msg[14] != 16 || msg[15] != 8 || msg[16] != 0 {
                    return Err("rfb: colour shift".into());
                }
                Ok(())
            }
            1 => Err("rfb: colour map refused".into()),
            4 | 5 if self.view_only => Err("rfb: view-only".into()),
            6 => Err("rfb: clipboard refused".into()),
            3 => {
                if msg.len() < 10 {
                    Err("rfb: framebuffer request truncated".into())
                } else if msg[1] > 1 {
                    Err("rfb: incremental".into())
                } else {
                    Ok(())
                }
            }
            4 => {
                if msg.len() < 8 {
                    Err("rfb: key event truncated".into())
                } else {
                    Ok(())
                }
            }
            5 => {
                if msg.len() < 6 {
                    Err("rfb: pointer event truncated".into())
                } else {
                    Ok(())
                }
            }
            _ => Err("rfb: message refused".into()),
        }
    }
}

/// One controller lease. Local user wins. Disconnect releases keys.
/// Not a native VNC viewer and not fabricated KVM pixels.
#[derive(Debug, Default)]
pub struct KvmLease {
    pub controller: Option<String>,
    pub local: bool,
    pressed: Vec<u32>,
}

impl KvmLease {
    pub fn take(&mut self, id: &str, local: bool) -> Result<(), String> {
        if id.is_empty() {
            return Err("kvm: id".into());
        }
        if self.local && !local {
            return Err("kvm: local priority".into());
        }
        self.controller = Some(id.into());
        self.local = local;
        self.pressed.clear();
        Ok(())
    }

    pub fn control(&self, id: &str) -> Result<(), String> {
        match &self.controller {
            Some(c) if c == id => Ok(()),
            Some(_) => Err("kvm: not controller".into()),
            None => Err("kvm: no lease".into()),
        }
    }

    pub fn key_down(&mut self, id: &str, code: u32) -> Result<(), String> {
        self.control(id)?;
        if !self.pressed.contains(&code) {
            self.pressed.push(code);
        }
        Ok(())
    }

    /// Drop the lease and return held keys (must be released).
    pub fn disconnect(&mut self, id: &str) -> Result<Vec<u32>, String> {
        self.control(id)?;
        let keys = core::mem::take(&mut self.pressed);
        self.controller = None;
        self.local = false;
        Ok(keys)
    }

    pub fn quiesce(&mut self) -> Vec<u32> {
        let keys = core::mem::take(&mut self.pressed);
        self.controller = None;
        self.local = false;
        keys
    }
}

/// RFB/KVM must be idle before `LinuxEnter`.
pub fn linux_enter_blocked(rfb: &RfbServer, kvm: &KvmLease) -> Result<(), String> {
    linux_enter_ready(rfb, kvm, true)
}

/// Other harts must already be stopped (SBI HSM). Not a live kernel.
pub fn linux_enter_ready(
    rfb: &RfbServer,
    kvm: &KvmLease,
    other_harts_stopped: bool,
) -> Result<(), String> {
    if rfb.phase == RfbPhase::Ready {
        return Err("handoff: rfb live".into());
    }
    if kvm.controller.is_some() {
        return Err("handoff: kvm live".into());
    }
    if !other_harts_stopped {
        return Err("handoff: other harts live".into());
    }
    Ok(())
}

/// RFB 3.8 **client**. TLS before any framebuffer request. Not a VNC viewer.
#[derive(Debug)]
pub struct RfbClient {
    pub phase: RfbPhase,
    pub w: u16,
    pub h: u16,
    pub pixels: Option<Vec<u8>>,
}

impl Default for RfbClient {
    fn default() -> Self {
        Self::new()
    }
}

impl RfbClient {
    pub fn new() -> Self {
        Self {
            phase: RfbPhase::Version,
            w: 0,
            h: 0,
            pixels: None,
        }
    }

    pub fn hello(&self) -> &'static [u8] {
        VERSION
    }

    pub fn server_version(&mut self, v: &[u8]) -> Result<(), String> {
        if self.phase != RfbPhase::Version {
            return Err("rfb: client not in version".into());
        }
        if v == b"RFB 003.003\n" {
            return Err("rfb: 3.3 refused".into());
        }
        if v != VERSION {
            return Err("rfb: version".into());
        }
        self.phase = RfbPhase::Security;
        Ok(())
    }

    /// Select TLS (18) only. None/DES refused.
    pub fn server_security(&mut self, offer: &[u8]) -> Result<u8, String> {
        if self.phase != RfbPhase::Security {
            return Err("rfb: client not in security".into());
        }
        if offer.is_empty() {
            return Err("rfb: empty security".into());
        }
        let n = offer[0] as usize;
        let types = offer.get(1..).ok_or("rfb: security list")?;
        if types.len() < n {
            return Err("rfb: security list".into());
        }
        if !types[..n].contains(&SEC_TLS) {
            return Err("rfb: no TLS security".into());
        }
        select_security(SEC_TLS)?;
        self.phase = RfbPhase::Tls;
        Ok(SEC_TLS)
    }

    pub fn server_security_result(&self, r: &[u8]) -> Result<(), String> {
        if self.phase != RfbPhase::Tls && self.phase != RfbPhase::Ready {
            return Err("rfb: security result".into());
        }
        if r != [0, 0, 0, 0] {
            return Err("rfb: auth failed".into());
        }
        Ok(())
    }

    pub fn tls_complete(&mut self) -> Result<(), String> {
        if self.phase != RfbPhase::Tls {
            return Err("rfb: tls not pending".into());
        }
        self.phase = RfbPhase::Ready;
        Ok(())
    }

    pub fn apply_server_init(&mut self, init: &[u8]) -> Result<(), String> {
        if self.phase != RfbPhase::Ready {
            return Err("rfb: framebuffer before auth".into());
        }
        if init.len() < 4 {
            return Err("rfb: server init".into());
        }
        self.w = u16::from_be_bytes([init[0], init[1]]);
        self.h = u16::from_be_bytes([init[2], init[3]]);
        Ok(())
    }

    /// FramebufferUpdateRequest after TLS. Incremental=0, 0×0 — no pixels invented.
    pub fn framebuffer_request(&self) -> Result<Vec<u8>, String> {
        if self.phase != RfbPhase::Ready {
            return Err("rfb: framebuffer before auth".into());
        }
        Ok(vec![3, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    /// Decode a raw FramebufferUpdate into committed pixels. Not a VNC viewer.
    pub fn apply_update(&mut self, upd: &[u8]) -> Result<(), String> {
        if self.phase != RfbPhase::Ready {
            return Err("rfb: framebuffer before auth".into());
        }
        if upd.len() < 4 {
            return Err("rfb: update".into());
        }
        let n = u16::from_be_bytes([upd[2], upd[3]]) as usize;
        if n == 0 {
            self.pixels = None;
            return Ok(());
        }
        if n != 1 {
            return Err("rfb: one rect".into());
        }
        if upd.len() < 16 {
            return Err("rfb: rect".into());
        }
        let x = u16::from_be_bytes([upd[4], upd[5]]) as usize;
        let y = u16::from_be_bytes([upd[6], upd[7]]) as usize;
        let w = u16::from_be_bytes([upd[8], upd[9]]) as usize;
        let h = u16::from_be_bytes([upd[10], upd[11]]) as usize;
        let enc = i32::from_be_bytes([upd[12], upd[13], upd[14], upd[15]]);
        if enc != 0 {
            return Err("rfb: encoding refused".into());
        }
        let need = w.saturating_mul(h).saturating_mul(4);
        if upd.len() != 16 + need {
            return Err("rfb: pixel size".into());
        }
        let src = &upd[16..];
        let fw = self.w as usize;
        let fh = self.h as usize;
        let mut buf = self
            .pixels
            .clone()
            .unwrap_or_else(|| vec![0u8; fw.saturating_mul(fh).saturating_mul(4)]);
        if buf.len() != fw * fh * 4 {
            buf = vec![0u8; fw * fh * 4];
        }
        for row in 0..h {
            if y + row >= fh || x + w > fw {
                return Err("rfb: rect bounds".into());
            }
            let dst = ((y + row) * fw + x) * 4;
            let so = row * w * 4;
            buf[dst..dst + w * 4].copy_from_slice(&src[so..so + w * 4]);
        }
        self.pixels = Some(buf);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfb_refuses_none_and_des() {
        assert_eq!(VERSION, b"RFB 003.008\n");
        assert_eq!(offer_security(), vec![1, 18]);
        assert!(select_security(1).unwrap_err().contains("None"));
        assert!(select_security(2).unwrap_err().contains("DES"));
        select_security(18).unwrap();
        let mut s = RfbServer::new(8, 8);
        assert!(s
            .client_version(b"RFB 003.003\n")
            .unwrap_err()
            .contains("3.3"));
    }

    #[test]
    fn rfb_session_requires_tls_before_framebuffer() {
        let mut s = RfbServer::new(640, 480);
        assert_eq!(s.greeting(), VERSION);
        assert!(s.framebuffer_update().unwrap_err().contains("before auth"));
        let offer = s.client_version(VERSION).unwrap();
        assert_eq!(offer, vec![1, 18]);
        assert!(s.client_security(1).is_err());
        s.client_security(18).unwrap();
        assert!(s.framebuffer_update().unwrap_err().contains("before auth"));
        assert_eq!(s.security_result().unwrap(), [0, 0, 0, 0]);
        s.tls_complete().unwrap();
        assert_eq!(s.framebuffer_update().unwrap(), vec![0, 0, 0, 0]);
        assert!(s.set_encodings(&[7]).unwrap_err().contains("Tight"));
        assert!(s.set_encodings(&[1]).unwrap_err().contains("CopyRect"));
        assert!(s.set_encodings(&[2]).unwrap_err().contains("RRE"));
        assert!(s.set_encodings(&[5]).unwrap_err().contains("Hextile"));
        assert!(s.set_encodings(&[16]).unwrap_err().contains("ZRLE"));
        s.set_encodings(&[0]).unwrap();
        let mut tiny = RfbServer::new(2, 1);
        tiny.client_version(VERSION).unwrap();
        tiny.client_security(18).unwrap();
        tiny.tls_complete().unwrap();
        assert_eq!(tiny.framebuffer_update().unwrap(), vec![0, 0, 0, 0]);
        let px = [0x11u8, 0x22, 0x33, 0x00, 0x44, 0x55, 0x66, 0x00];
        tiny.commit_pixels(&px).unwrap();
        let upd = tiny.framebuffer_update().unwrap();
        assert_eq!(&upd[0..4], &[0, 0, 0, 1]);
        assert_eq!(&upd[16..], &px);
        let mut cl = RfbClient::new();
        cl.server_version(VERSION).unwrap();
        cl.server_security(&[1, 18]).unwrap();
        cl.tls_complete().unwrap();
        cl.apply_server_init(&tiny.server_init().unwrap()).unwrap();
        cl.apply_update(&upd).unwrap();
        assert_eq!(cl.pixels.as_deref(), Some(px.as_slice()));
        assert!(s.set_encodings(&[]).unwrap_err().contains("encodings"));
        assert!(s
            .set_encodings(&[0, 0, 0, 0, 0, 0, 0, 0, 0])
            .unwrap_err()
            .contains("encodings"));
        assert!(s.client_message(&[4, 1]).unwrap_err().contains("truncated"));
        s.client_message(&[4, 1, 0, 0, 0, 0, 0, 0x1c]).unwrap();
        assert!(s.client_message(&[5, 1]).unwrap_err().contains("truncated"));
        s.client_message(&[5, 1, 0, 0, 0, 0]).unwrap();
        assert!(s.client_message(&[3, 0]).unwrap_err().contains("truncated"));
        s.client_message(&[3, 0, 0, 0, 0, 0, 0, 0, 0, 0]).unwrap();
        assert!(s
            .client_message(&[3, 2, 0, 0, 0, 0, 0, 0, 0, 0])
            .unwrap_err()
            .contains("incremental"));
        s.client_message(&[3, 1, 0, 0, 0, 0, 0, 0, 0, 0]).unwrap();
    }

    #[test]
    fn rfb_client_requires_tls_before_framebuffer() {
        let mut c = RfbClient::new();
        assert_eq!(c.hello(), VERSION);
        assert!(c.framebuffer_request().unwrap_err().contains("before auth"));
        c.server_version(VERSION).unwrap();
        assert_eq!(c.server_security(&[1, 18]).unwrap(), 18);
        c.server_security_result(&[0, 0, 0, 0]).unwrap();
        assert!(c
            .server_security_result(&[1, 0, 0, 0])
            .unwrap_err()
            .contains("auth failed"));
        assert!(c.framebuffer_request().unwrap_err().contains("before auth"));
        c.tls_complete().unwrap();
        let req = c.framebuffer_request().unwrap();
        assert_eq!(req[0], 3);
        assert_eq!(&req[1..], &[0, 0, 0, 0, 0, 0, 0, 0, 0]);
        let mut none = RfbClient::new();
        none.server_version(VERSION).unwrap();
        assert!(none.server_security(&[1, 1]).unwrap_err().contains("TLS"));
    }

    #[test]
    fn rfb_view_only_and_clipboard_refused() {
        let mut s = RfbServer::new(640, 480).view_only();
        s.client_version(VERSION).unwrap();
        s.client_security(18).unwrap();
        s.tls_complete().unwrap();
        assert!(s
            .client_message(&[5, 0, 0, 0])
            .unwrap_err()
            .contains("view-only"));
        assert!(s
            .client_message(&[4, 1, 0, 0])
            .unwrap_err()
            .contains("view-only"));
        assert!(s
            .client_message(&[6, 0, 0, 0, 0, 0, 0, 0, 1, b'x'])
            .unwrap_err()
            .contains("clipboard"));
        let mut pf = [0u8; 20];
        pf[4] = 8;
        assert!(s.client_message(&pf).unwrap_err().contains("32bpp"));
        pf[4] = 32;
        pf[5] = 24;
        pf[6] = 0;
        pf[7] = 1;
        pf[9] = 0xff;
        pf[11] = 0xff;
        pf[13] = 0xff;
        pf[14] = 16;
        pf[15] = 8;
        pf[16] = 0;
        s.client_message(&pf).unwrap();
        pf[14] = 0;
        assert!(s.client_message(&pf).unwrap_err().contains("colour shift"));
        pf[14] = 16;
        pf[9] = 0;
        assert!(s.client_message(&pf).unwrap_err().contains("colour max"));
        pf[9] = 0xff;
        pf[6] = 1;
        assert!(s.client_message(&pf).unwrap_err().contains("32bpp"));
        assert!(s
            .client_message(&[1, 0])
            .unwrap_err()
            .contains("colour map"));
        let mut c = RfbClient::new();
        let mut srv = RfbServer::new(640, 480);
        c.server_version(srv.greeting()).unwrap();
        let offer = srv.client_version(c.hello()).unwrap();
        assert_eq!(c.server_security(&offer).unwrap(), 18);
        srv.client_security(18).unwrap();
        c.tls_complete().unwrap();
        srv.tls_complete().unwrap();
        assert_eq!(c.framebuffer_request().unwrap()[0], 3);
        assert_eq!(srv.framebuffer_update().unwrap(), vec![0, 0, 0, 0]);
        srv.client_message(&c.framebuffer_request().unwrap())
            .unwrap();
        let init = srv.server_init().unwrap();
        assert_eq!(&init[0..4], &[2, 128, 1, 224]);
        srv.commit_frame();
        assert_eq!(srv.gen, 1);
        assert_eq!(srv.damage, (0, 0, 640, 480));
        srv.commit_damage(8, 8, 16, 16);
        assert_eq!(srv.gen, 2);
        assert_eq!(srv.damage, (8, 8, 16, 16));
        assert_eq!(srv.framebuffer_update().unwrap(), vec![0, 0, 0, 0]);
    }

    #[test]
    fn kvm_lease_local_priority_and_disconnect_releases_keys() {
        let mut k = KvmLease::default();
        k.take("local", true).unwrap();
        assert!(k.take("remote", false).unwrap_err().contains("local"));
        k.key_down("local", 0x1c).unwrap();
        k.key_down("local", 0x1d).unwrap();
        let rel = k.disconnect("local").unwrap();
        assert_eq!(rel, vec![0x1c, 0x1d]);
        assert!(k.controller.is_none());
        k.take("remote", false).unwrap();
        assert!(k
            .key_down("other", 1)
            .unwrap_err()
            .contains("not controller"));
        k.quiesce();
        let mut s = RfbServer::new(640, 480);
        s.client_version(VERSION).unwrap();
        s.client_security(18).unwrap();
        s.tls_complete().unwrap();
        assert!(linux_enter_blocked(&s, &k)
            .unwrap_err()
            .contains("rfb live"));
        assert!(s
            .set_encodings(&[-307])
            .unwrap_err()
            .contains("file-transfer"));
        s.terminate_for_linux();
        linux_enter_blocked(&s, &k).unwrap();
        assert!(linux_enter_ready(&s, &k, false)
            .unwrap_err()
            .contains("other harts"));
        linux_enter_ready(&s, &k, true).unwrap();
        assert!(s.framebuffer_update().unwrap_err().contains("before auth"));
    }
}
