// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Authenticated management jobs. Replaces canned POST `/bios/flash` success.
//! P6 sessions/CSRF; P7 generations/scopes; P10 capsule MAC; P12 recovery latch.

#![allow(missing_docs)]

use std::collections::BTreeMap;

use g6b_spec::parse_json;
use g6b_tls::{
    parse_cert_chain, pbkdf2_hmac_sha256, sha256, sha256_hex, CertStore, Entropy, FixtureClock,
    FixtureEntropy,
};

use crate::rfb::KvmLease;
use crate::{Request, Response};

const SCOPE_VIEW: u32 = 1;
const SCOPE_BOOT: u32 = 2;
const SCOPE_UPDATE: u32 = 4;
const SCOPE_TRUST: u32 = 8;
const SCOPE_KVM: u32 = 16;
const ALL_SCOPES: u32 = SCOPE_VIEW | SCOPE_BOOT | SCOPE_UPDATE | SCOPE_TRUST | SCOPE_KVM;
const LOGIN_BUDGET: u32 = 5;
const PBKDF2_ROUNDS: u32 = 8;
const MAX_SESSIONS: usize = 8;
const SID_COOKIE: &str = "__Host-g6b_sid";

/// Canonical firmware capsule. TLS carries bytes; HMAC authenticates them.
/// Detached RSA-PSS is optional; ELF ident is required before apply.
#[derive(Clone, Debug)]
pub struct Capsule {
    pub board: String,
    pub arch: String,
    pub version: String,
    pub length: u64,
    pub digest: [u8; 32],
    pub entry: u64,
    pub key_id: String,
}

/// RISC-V 64-bit little-endian ELF ident. Not a full loader.
pub fn check_image_elf(image: &[u8]) -> Result<(), String> {
    if image.len() < 64 {
        return Err("capsule: elf short".into());
    }
    if image[0..4] != *b"\x7fELF" {
        return Err("capsule: magic".into());
    }
    if image[4] != 2 {
        return Err("capsule: class".into());
    }
    if image[5] != 1 {
        return Err("capsule: data".into());
    }
    if image[6] != 1 {
        return Err("capsule: ident version".into());
    }
    if image[7] != 0 && image[7] != 3 {
        return Err("capsule: osabi".into());
    }
    let machine = u16::from_le_bytes([image[18], image[19]]);
    if machine != 0x00f3 {
        return Err("capsule: machine".into());
    }
    let etype = u16::from_le_bytes([image[16], image[17]]);
    if etype != 2 {
        return Err("capsule: e_type".into());
    }
    let ehsize = u16::from_le_bytes([image[52], image[53]]);
    if ehsize != 64 {
        return Err("capsule: ehsize".into());
    }
    let ever = u32::from_le_bytes([image[20], image[21], image[22], image[23]]);
    if ever != 1 {
        return Err("capsule: e_version".into());
    }
    let phentsize = u16::from_le_bytes([image[54], image[55]]);
    if phentsize != 56 {
        return Err("capsule: phentsize".into());
    }
    let phnum = u16::from_le_bytes([image[56], image[57]]);
    if phnum == 0 || phnum > 4 {
        return Err("capsule: phnum".into());
    }
    let entry = u64::from_le_bytes([
        image[24], image[25], image[26], image[27], image[28], image[29], image[30], image[31],
    ]);
    if entry == 0 || entry % 4 != 0 {
        return Err("capsule: e_entry".into());
    }
    let phoff = u64::from_le_bytes([
        image[32], image[33], image[34], image[35], image[36], image[37], image[38], image[39],
    ]);
    if phoff != 64 {
        return Err("capsule: phoff".into());
    }
    let ph_end = 64usize.saturating_add(56);
    if image.len() < ph_end {
        return Err("capsule: phdr".into());
    }
    let ptype = u32::from_le_bytes([image[64], image[65], image[66], image[67]]);
    if ptype != 1 {
        return Err("capsule: pt_load".into());
    }
    let pflags = u32::from_le_bytes([image[68], image[69], image[70], image[71]]);
    if pflags & 0x3 == 0x3 {
        return Err("capsule: wx".into());
    }
    let palign = u64::from_le_bytes([
        image[112], image[113], image[114], image[115], image[116], image[117], image[118],
        image[119],
    ]);
    if palign != 4 && palign != 8 && palign != 4096 {
        return Err("capsule: p_align".into());
    }
    let vaddr = u64::from_le_bytes([
        image[80], image[81], image[82], image[83], image[84], image[85], image[86], image[87],
    ]);
    if vaddr == 0 || vaddr % 4 != 0 {
        return Err("capsule: p_vaddr".into());
    }
    let paddr = u64::from_le_bytes([
        image[88], image[89], image[90], image[91], image[92], image[93], image[94], image[95],
    ]);
    if paddr != 0 && paddr != vaddr {
        return Err("capsule: p_paddr".into());
    }
    let filesz = u64::from_le_bytes([
        image[96], image[97], image[98], image[99], image[100], image[101], image[102], image[103],
    ]);
    let memsz = u64::from_le_bytes([
        image[104], image[105], image[106], image[107], image[108], image[109], image[110],
        image[111],
    ]);
    if filesz == 0 || memsz == 0 || filesz > memsz {
        return Err("capsule: p_filesz".into());
    }
    let poff = u64::from_le_bytes([
        image[72], image[73], image[74], image[75], image[76], image[77], image[78], image[79],
    ]);
    if poff < 120 {
        return Err("capsule: p_offset".into());
    }
    if poff.checked_add(filesz).is_none() || vaddr.checked_add(memsz).is_none() {
        return Err("capsule: overflow".into());
    }
    if entry < vaddr || entry >= vaddr.saturating_add(memsz) {
        return Err("capsule: e_entry range".into());
    }
    Ok(())
}

/// Strict version order for replay/downgrade refuse. `1.2` > `1.1` > `1`.
pub fn version_newer(next: &str, last: &str) -> bool {
    if next == last {
        return false;
    }
    let parse = |s: &str| -> Vec<u32> {
        s.split('.')
            .map(|p| p.parse::<u32>().unwrap_or(0))
            .collect()
    };
    let a = parse(next);
    let b = parse(last);
    let n = a.len().max(b.len());
    for i in 0..n {
        let x = a.get(i).copied().unwrap_or(0);
        let y = b.get(i).copied().unwrap_or(0);
        if x != y {
            return x > y;
        }
    }
    false
}

/// Recovery policy. Login/refresh cannot clear a latch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecoveryState {
    Eligible,
    Latched,
    Unconfirmed,
    InProgress,
    Confirmed,
}

impl RecoveryState {
    pub fn blocks_autoboot(self) -> bool {
        matches!(
            self,
            RecoveryState::Latched | RecoveryState::Unconfirmed | RecoveryState::InProgress
        )
    }

    /// Apply is blocked only by operator inhibit / unconfirmed power-loss.
    pub fn blocks_apply(self) -> bool {
        matches!(self, RecoveryState::Latched | RecoveryState::Unconfirmed)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            RecoveryState::Eligible => "eligible",
            RecoveryState::Latched => "latched",
            RecoveryState::Unconfirmed => "unconfirmed",
            RecoveryState::InProgress => "in-progress",
            RecoveryState::Confirmed => "confirmed",
        }
    }
}

impl Capsule {
    pub fn for_image(board: &str, arch: &str, version: &str, image: &[u8], key_id: &str) -> Self {
        Self {
            board: board.into(),
            arch: arch.into(),
            version: version.into(),
            length: image.len() as u64,
            digest: sha256(image),
            entry: 0x8000_0000,
            key_id: key_id.into(),
        }
    }

    fn canonical(&self) -> Vec<u8> {
        let mut v = Vec::new();
        v.extend(self.board.as_bytes());
        v.push(0);
        v.extend(self.arch.as_bytes());
        v.push(0);
        v.extend(self.version.as_bytes());
        v.push(0);
        v.extend_from_slice(&self.length.to_be_bytes());
        v.extend_from_slice(&self.digest);
        v.extend_from_slice(&self.entry.to_be_bytes());
        v.extend(self.key_id.as_bytes());
        v
    }

    pub fn mac(&self, key: &[u8]) -> [u8; 32] {
        g6b_tls::hmac_sha256(key, &self.canonical())
    }

    pub fn verify(&self, key: &[u8], mac: &[u8; 32], image: &[u8]) -> Result<(), String> {
        if self.length != image.len() as u64 {
            return Err("capsule: length".into());
        }
        if self.digest != sha256(image) {
            return Err("capsule: digest".into());
        }
        let got = self.mac(key);
        let mut d = 0u8;
        for i in 0..32 {
            d |= got[i] ^ mac[i];
        }
        if d != 0 {
            Err("capsule: mac".into())
        } else {
            Ok(())
        }
    }

    /// Detached RSA-PSS SHA-256 over the canonical manifest. HMAC still required.
    pub fn verify_pss(&self, pubk: &g6b_tls::RsaPub, sig: &[u8]) -> Result<(), String> {
        if sig.is_empty() {
            return Err("capsule: pss".into());
        }
        if g6b_tls::rsa_pss_sha256_verify(pubk, &self.canonical(), sig) {
            Ok(())
        } else {
            Err("capsule: pss".into())
        }
    }
}

struct Session {
    csrf: String,
    reauth: String,
    scopes: u32,
    expires: u64,
}

struct UpdateJob {
    id: u32,
    gen: u32,
    digest: String,
    phase: &'static str,
}

/// Live management table. No default password.
pub struct Mgmt {
    rng: FixtureEntropy,
    clock: FixtureClock,
    salt: [u8; 16],
    pass_dk: Option<Vec<u8>>,
    fw_key: [u8; 32],
    board: String,
    arch: String,
    sessions: BTreeMap<String, Session>,
    login_fails: u32,
    disco_gen: u32,
    targets: Vec<(String, String)>,
    job: Option<UpdateJob>,
    next_job: u32,
    recovery: RecoveryState,
    last_applied: Option<String>,
    ui_down: bool,
    autoboot: bool,
    trust: CertStore,
    kvm: KvmLease,
    kvm_gen: u32,
    kvm_px: usize,
    kvm_sha: String,
}

impl Mgmt {
    pub fn new(board: &str, arch: &str) -> Self {
        let mut rng = FixtureEntropy::TEST;
        let mut salt = [0u8; 16];
        let mut fw_key = [0u8; 32];
        let _ = rng.fill(&mut salt);
        let _ = rng.fill(&mut fw_key);
        Self {
            rng,
            clock: FixtureClock {
                unix: 1_700_000_000,
            },
            salt,
            pass_dk: None,
            fw_key,
            board: board.into(),
            arch: arch.into(),
            sessions: BTreeMap::new(),
            login_fails: 0,
            disco_gen: 1,
            targets: vec![
                ("vol0".into(), "volume".into()),
                ("bios-ui".into(), "bios".into()),
            ],
            job: None,
            next_job: 1,
            recovery: RecoveryState::Eligible,
            last_applied: None,
            ui_down: false,
            autoboot: false,
            trust: CertStore::default(),
            kvm: KvmLease::default(),
            kvm_gen: 0,
            kvm_px: 0,
            kvm_sha: String::new(),
        }
    }

    pub fn fw_key(&self) -> &[u8; 32] {
        &self.fw_key
    }

    pub fn latch_recovery(&mut self) {
        self.recovery = RecoveryState::Latched;
        self.autoboot = false;
    }

    /// Ambiguous power loss is Unconfirmed, not invented image corruption.
    pub fn power_loss_unconfirmed(&mut self) {
        self.recovery = RecoveryState::Unconfirmed;
        self.autoboot = false;
    }

    pub fn fail_ui(&mut self) {
        self.ui_down = true;
    }

    pub fn unplug(&mut self, id: &str) {
        self.targets.retain(|(i, _)| i != id);
        self.disco_gen = self.disco_gen.wrapping_add(1);
        if self.disco_gen == 0 {
            self.disco_gen = 1;
        }
    }

    /// Never publish `0.0.0.0` as a client URL.
    pub fn advertise_url(host: &str, port: u16) -> String {
        let h = if host.is_empty()
            || host == "*"
            || host == "0.0.0.0"
            || host == "::"
            || host == "[::]"
        {
            "10.0.2.15"
        } else {
            host
        };
        format!("https://{h}:{port}")
    }

    pub fn handle(&mut self, req: &Request) -> Option<Response> {
        if req.path.contains("password=") || req.path.contains("token=") {
            return Some(err(403, "secret in url"));
        }
        let path = req.path.split('?').next().unwrap_or(req.path.as_str());
        let m = req.method.to_ascii_uppercase();
        if let Err(e) = cors_ok(req) {
            return Some(e);
        }
        if m == "OPTIONS" {
            return Some(err(403, "cors"));
        }
        if m == "GET" && post_only(path) {
            return Some(err(405, "mutating get"));
        }
        if matches!(m.as_str(), "TRACE" | "CONNECT" | "TRACK" | "HEAD") {
            return Some(err(405, "method"));
        }
        if matches!(m.as_str(), "PUT" | "PATCH" | "DELETE") && path.starts_with("/bios/") {
            return Some(err(405, "method"));
        }
        if m == "POST" && path.starts_with("/bios/") {
            if let Some(ct) = header(req, "content-type") {
                if !ct.to_ascii_lowercase().contains("json") && path != "/bios/trust/root" {
                    return Some(err(415, "content-type"));
                }
            }
        }
        match (m.as_str(), path) {
            ("POST", "/bios/provision") => Some(self.provision(req)),
            ("POST", "/bios/login") => Some(self.login(req)),
            ("POST", "/bios/logout") => Some(self.logout(req)),
            ("GET", "/bios/boot/targets") => Some(self.boot_targets(req)),
            ("POST", "/bios/boot/select") => Some(self.boot_select(req)),
            ("POST", "/bios/update/start") => Some(self.update_start(req)),
            ("GET", "/bios/update/status") => Some(self.update_status(req)),
            ("POST", "/bios/update/cancel") => Some(self.update_cancel(req)),
            ("POST", "/bios/update/apply") => Some(self.update_apply(req)),
            ("POST", "/bios/flash") | ("POST", "/bios/update") => Some(self.flash_refused()),
            ("GET", "/bios/recovery") => Some(self.recovery_get(req)),
            ("POST", "/bios/recovery/retry-once") => Some(self.retry_once(req)),
            ("POST", "/bios/autoboot") => Some(self.autoboot_set(req)),
            ("GET", "/bios/trust") => Some(self.trust_get(req)),
            ("POST", "/bios/trust/root") => Some(self.trust_root(req)),
            ("GET", "/bios/kvm") => Some(self.kvm_get(req)),
            ("POST", "/bios/kvm/lease") => Some(self.kvm_lease(req)),
            ("POST", "/bios/kvm/release") => Some(self.kvm_release(req)),
            ("POST", "/bios/health/ack") => Some(self.health_ack(req)),
            ("GET", "/bios/recovery.html") => Some(self.recovery_html(req)),
            ("POST", "/bios/recovery/clear") => Some(err(403, "cannot clear recovery")),
            _ => None,
        }
    }

    pub fn advance_unix(&mut self, secs: u64) {
        self.clock.unix = self.clock.unix.saturating_add(secs);
    }

    fn provision(&mut self, req: &Request) -> Response {
        if self.pass_dk.is_some() {
            return err(409, "already provisioned");
        }
        let pass = json_str(req, "password").unwrap_or_default();
        if pass.len() < 8 || pass.len() > 128 || pass.bytes().any(|b| b < 32) || pass != pass.trim()
        {
            return err(400, "password refused");
        }
        match pbkdf2_hmac_sha256(pass.as_bytes(), &self.salt, PBKDF2_ROUNDS, 32) {
            Ok(dk) => {
                self.pass_dk = Some(dk);
                json_ok("{\"ok\":true,\"provisioned\":true}")
            }
            Err(e) => err(500, &e),
        }
    }

    fn login(&mut self, req: &Request) -> Response {
        if self.login_fails >= LOGIN_BUDGET {
            return err(429, "rate limit");
        }
        let dk = match &self.pass_dk {
            Some(v) => v.clone(),
            None => return err(503, "not provisioned"),
        };
        let pass = json_str(req, "password").unwrap_or_default();
        let got = match pbkdf2_hmac_sha256(pass.as_bytes(), &self.salt, PBKDF2_ROUNDS, 32) {
            Ok(v) => v,
            Err(e) => return err(500, &e),
        };
        let mut d = 0u8;
        for (a, b) in dk.iter().zip(got.iter()) {
            d |= a ^ b;
        }
        if d != 0 || dk.len() != got.len() {
            self.login_fails = self.login_fails.saturating_add(1);
            return err(401, "auth");
        }
        self.login_fails = 0;
        if self.sessions.len() >= MAX_SESSIONS {
            return err(429, "session budget");
        }
        let sid = self.token();
        let csrf = self.token();
        let reauth = self.token();
        let now = self.clock.unix.saturating_add(3600);
        self.sessions.insert(
            sid.clone(),
            Session {
                csrf: csrf.clone(),
                reauth: reauth.clone(),
                scopes: ALL_SCOPES,
                expires: now,
            },
        );
        let mut r = json_ok(&format!(
            "{{\"ok\":true,\"csrf\":\"{csrf}\",\"reauth\":\"{reauth}\",\"scopes\":{ALL_SCOPES}}}"
        ));
        r.headers.push((
            "set-cookie".into(),
            format!("{SID_COOKIE}={sid}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=3600"),
        ));
        r
    }

    fn logout(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_VIEW, true) {
            return e;
        }
        if let Some(sid) = cookie(req, SID_COOKIE) {
            self.sessions.remove(sid);
        }
        let mut r = json_ok("{\"ok\":true}");
        r.headers.push((
            "set-cookie".into(),
            format!("{SID_COOKIE}=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0"),
        ));
        r
    }

    fn boot_targets(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_VIEW, false) {
            return e;
        }
        let list: Vec<String> = self
            .targets
            .iter()
            .map(|(id, kind)| format!("{{\"id\":\"{id}\",\"kind\":\"{kind}\"}}"))
            .collect();
        json_ok(&format!(
            "{{\"generation\":{},\"targets\":[{}]}}",
            self.disco_gen,
            list.join(",")
        ))
    }

    fn boot_select(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_BOOT, true) {
            return e;
        }
        let id = json_str(req, "id").unwrap_or_default();
        let gen = json_u32(req, "generation").unwrap_or(0);
        if gen != self.disco_gen {
            return err(409, "stale generation");
        }
        if !self.targets.iter().any(|(i, _)| i == &id) {
            return err(404, "no such target");
        }
        json_ok(&format!(
            "{{\"ok\":true,\"selected\":\"{id}\",\"generation\":{gen}}}"
        ))
    }

    fn update_start(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_UPDATE, true) {
            return e;
        }
        let digest = json_str(req, "digest").unwrap_or_default();
        if digest.len() != 64 {
            return err(400, "digest");
        }
        let id = self.next_job;
        self.next_job = self.next_job.saturating_add(1);
        self.job = Some(UpdateJob {
            id,
            gen: self.disco_gen,
            digest: digest.clone(),
            phase: "staged",
        });
        json_ok(&format!(
            "{{\"ok\":true,\"job\":{id},\"generation\":{},\"phase\":\"staged\"}}",
            self.disco_gen
        ))
    }

    fn update_status(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_VIEW, false) {
            return e;
        }
        match &self.job {
            Some(j) => json_ok(&format!(
                "{{\"job\":{},\"generation\":{},\"phase\":\"{}\",\"digest\":\"{}\"}}",
                j.id, j.gen, j.phase, j.digest
            )),
            None => json_ok("{\"job\":null}"),
        }
    }

    fn update_cancel(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_UPDATE, true) {
            return e;
        }
        if let Some(j) = self.job.as_mut() {
            if j.phase == "applied" {
                return err(409, "already applied");
            }
            j.phase = "cancelled";
            return json_ok("{\"ok\":true,\"phase\":\"cancelled\"}");
        }
        err(404, "no job")
    }

    fn update_apply(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_UPDATE, true) {
            return e;
        }
        if self.recovery.blocks_apply() {
            return err(409, "recovery latched");
        }
        if let Some(b) = json_str(req, "board") {
            if b != self.board {
                return err(400, "board");
            }
        }
        if let Some(a) = json_str(req, "arch") {
            if a != self.arch {
                return err(400, "arch");
            }
        }
        let digest = json_str(req, "digest").unwrap_or_default();
        let gen = json_u32(req, "generation").unwrap_or(0);
        let j = match self.job.as_mut() {
            Some(j) => j,
            None => return err(404, "no job"),
        };
        if j.phase != "staged" {
            return err(409, "not staged");
        }
        if gen != j.gen || digest != j.digest {
            return err(409, "stale apply");
        }
        if json_str(req, "slot").as_deref() == Some("A") {
            return err(400, "slot A protected");
        }
        if let Some(ver) = json_str(req, "version") {
            if let Some(last) = &self.last_applied {
                if !version_newer(&ver, last) {
                    return err(409, "replay");
                }
            }
            self.last_applied = Some(ver);
        }
        j.phase = "applied";
        if !self.recovery.blocks_apply() {
            self.recovery = RecoveryState::InProgress;
        }
        json_ok(&format!(
            "{{\"ok\":true,\"phase\":\"applied\",\"slot\":\"B\",\"digest\":\"{digest}\"}}"
        ))
    }

    fn flash_refused(&self) -> Response {
        err(401, "canned flash apply is disabled; use /bios/update/*")
    }

    fn recovery_get(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_VIEW, false) {
            return e;
        }
        json_ok(&format!(
            "{{\"latched\":{},\"state\":\"{}\",\"autoboot\":{},\"ui_down\":{}}}",
            if self.recovery.blocks_autoboot() {
                "true"
            } else {
                "false"
            },
            self.recovery.as_str(),
            if self.autoboot { "true" } else { "false" },
            if self.ui_down { "true" } else { "false" }
        ))
    }

    fn retry_once(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_BOOT, true) {
            return e;
        }
        if !self.recovery.blocks_autoboot() {
            return err(409, "not latched");
        }
        json_ok(&format!(
            "{{\"ok\":true,\"retry\":\"once\",\"latched\":true,\"state\":\"{}\",\"autoboot\":false}}",
            self.recovery.as_str()
        ))
    }

    fn autoboot_set(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_BOOT, true) {
            return e;
        }
        let enable = json_bool(req, "enable").unwrap_or(false);
        if enable && self.recovery.blocks_autoboot() {
            return err(409, "recovery latched");
        }
        self.autoboot = enable;
        json_ok(&format!(
            "{{\"ok\":true,\"autoboot\":{}}}",
            if self.autoboot { "true" } else { "false" }
        ))
    }

    fn trust_get(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_VIEW, false) {
            return e;
        }
        let names: Vec<String> = self
            .trust
            .roots()
            .iter()
            .map(|c| format!("\"{}\"", c.cn.replace('"', "")))
            .collect();
        json_ok(&format!(
            "{{\"roots\":[{}],\"count\":{}}}",
            names.join(","),
            self.trust.len()
        ))
    }

    fn trust_root(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_TRUST, true) {
            return e;
        }
        let pem = if req.body.windows(10).any(|w| w == b"-----BEGIN") {
            req.body.clone()
        } else {
            json_str(req, "pem").unwrap_or_default().into_bytes()
        };
        let chain = match parse_cert_chain(&pem) {
            Ok(c) if !c.is_empty() => c,
            Ok(_) => return err(400, "empty chain"),
            Err(e) => return err(400, &e),
        };
        let mut added = 0u32;
        for c in chain {
            if c.is_ca || c.issuer_der == c.subject_der {
                if let Err(e) = self.trust.add_root(c) {
                    return err(400, &e);
                }
                added += 1;
            }
        }
        if added == 0 {
            return err(400, "no trust anchor");
        }
        json_ok(&format!("{{\"ok\":true,\"roots\":{}}}", self.trust.len()))
    }

    /// Committed KVM pixels only. Unauthenticated callers never see them.
    pub fn commit_kvm_pixels(&mut self, px: &[u8]) {
        self.kvm_gen = self.kvm_gen.wrapping_add(1);
        self.kvm_px = px.len();
        self.kvm_sha = g6b_tls::sha256_hex(px);
    }

    fn kvm_get(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_VIEW, false) {
            return e;
        }
        let ctl = self.kvm.controller.clone().unwrap_or_default();
        let remote = if ctl.is_empty() { "false" } else { "true" };
        json_ok(&format!(
            "{{\"ok\":true,\"view\":true,\"controller\":\"{ctl}\",\"remote\":{remote},\"pixels\":{},\"gen\":{},\"sha256\":\"{}\"}}",
            self.kvm_px, self.kvm_gen, self.kvm_sha
        ))
    }

    fn kvm_lease(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_KVM, true) {
            return e;
        }
        let sid = cookie(req, SID_COOKIE).unwrap_or("");
        let local = json_bool(req, "local").unwrap_or(false);
        match self.kvm.take(sid, local) {
            Ok(()) => json_ok("{\"ok\":true,\"control\":true}"),
            Err(e) => err(409, &e),
        }
    }

    fn health_ack(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_BOOT, true) {
            return e;
        }
        if self.recovery == RecoveryState::Latched {
            return err(409, "recovery latched");
        }
        let digest = json_str(req, "digest").unwrap_or_default();
        let j = match &self.job {
            Some(j) if j.phase == "applied" => j,
            _ => return err(409, "no trial"),
        };
        if digest != j.digest {
            return err(409, "stale ack");
        }
        let gen = json_u32(req, "generation").unwrap_or(0);
        if gen != j.gen {
            return err(409, "stale ack");
        }
        self.recovery = RecoveryState::Confirmed;
        self.autoboot = false;
        json_ok("{\"ok\":true,\"state\":\"confirmed\",\"autoboot\":false}")
    }

    fn recovery_html(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_VIEW, false) {
            return e;
        }
        let body = format!(
            "<!doctype html><html><body><h1>recovery</h1><p>state {}</p></body></html>",
            self.recovery.as_str()
        );
        Response::file(200, "text/html; charset=utf-8", body.into_bytes())
    }

    fn kvm_release(&mut self, req: &Request) -> Response {
        if let Err(e) = self.require(req, SCOPE_KVM, true) {
            return e;
        }
        let sid = cookie(req, SID_COOKIE).unwrap_or("");
        match self.kvm.disconnect(sid) {
            Ok(keys) => json_ok(&format!("{{\"ok\":true,\"released\":{}}}", keys.len())),
            Err(e) => err(409, &e),
        }
    }

    fn require(&self, req: &Request, scope: u32, csrf: bool) -> Result<(), Response> {
        let sid = match cookie(req, SID_COOKIE) {
            Some(s) => s,
            None => return Err(err(401, "no session")),
        };
        let s = match self.sessions.get(sid) {
            Some(s) => s,
            None => return Err(err(401, "no session")),
        };
        let now = self.clock.unix;
        if now > s.expires {
            return Err(err(401, "expired"));
        }
        if s.scopes & scope == 0 {
            return Err(err(403, "scope"));
        }
        if csrf {
            let tok = header(req, "x-csrf-token").unwrap_or("");
            if tok != s.csrf {
                return Err(err(403, "csrf"));
            }
            let ra = header(req, "x-reauth").unwrap_or("");
            if ra != s.reauth {
                return Err(err(403, "reauth"));
            }
        }
        Ok(())
    }

    fn token(&mut self) -> String {
        let mut b = [0u8; 16];
        let _ = self.rng.fill(&mut b);
        sha256_hex(&b)[..32].to_string()
    }
}

fn json_ok(body: &str) -> Response {
    Response::json(200, body)
}

fn err(status: u16, msg: &str) -> Response {
    Response::json(status, &format!("{{\"error\":\"{msg}\"}}"))
}

fn json_str<'a>(req: &'a Request, k: &str) -> Option<String> {
    let s = std::str::from_utf8(&req.body).ok()?;
    parse_json(s).ok()?.get(k).as_str().map(str::to_string)
}

fn json_u32(req: &Request, k: &str) -> Option<u32> {
    let s = std::str::from_utf8(&req.body).ok()?;
    parse_json(s).ok()?.get(k).as_u32()
}

fn json_bool(req: &Request, k: &str) -> Option<bool> {
    let s = std::str::from_utf8(&req.body).ok()?;
    parse_json(s).ok()?.get(k).as_bool()
}

fn post_only(path: &str) -> bool {
    matches!(
        path,
        "/bios/provision"
            | "/bios/login"
            | "/bios/logout"
            | "/bios/boot/select"
            | "/bios/update/start"
            | "/bios/update/cancel"
            | "/bios/update/apply"
            | "/bios/flash"
            | "/bios/update"
            | "/bios/recovery/retry-once"
            | "/bios/autoboot"
            | "/bios/trust/root"
            | "/bios/kvm/lease"
            | "/bios/kvm/release"
            | "/bios/health/ack"
            | "/bios/recovery/clear"
    )
}

fn cors_ok(req: &Request) -> Result<(), Response> {
    let origin = match header(req, "origin") {
        None => return Ok(()),
        Some(o) => o,
    };
    if origin == "*" || origin.eq_ignore_ascii_case("null") {
        return Err(err(403, "cors"));
    }
    if origin.starts_with("https://127.0.0.1")
        || origin.starts_with("https://localhost")
        || origin.starts_with("https://10.0.2.15")
    {
        Ok(())
    } else {
        Err(err(403, "cors"))
    }
}

fn header<'a>(req: &'a Request, name: &str) -> Option<&'a str> {
    req.headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.as_str())
}

fn cookie<'a>(req: &'a Request, name: &str) -> Option<&'a str> {
    let c = header(req, "cookie")?;
    for part in c.split(';') {
        let part = part.trim();
        if let Some((n, v)) = part.split_once('=') {
            if n == name {
                if v.bytes().any(|b| b < 33 || b > 126) {
                    return None;
                }
                return Some(v);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(method: &str, path: &str, body: &str, cookie: &str, csrf: &str) -> Request {
        let mut headers = Vec::new();
        if !cookie.is_empty() {
            headers.push(("cookie".into(), cookie.into()));
        }
        if !csrf.is_empty() {
            if let Some((c, r)) = csrf.split_once(':') {
                headers.push(("x-csrf-token".into(), c.into()));
                headers.push(("x-reauth".into(), r.into()));
            } else {
                headers.push(("x-csrf-token".into(), csrf.into()));
            }
        }
        Request {
            method: method.into(),
            path: path.into(),
            version: crate::Version::Http11,
            headers,
            body: body.as_bytes().to_vec(),
        }
    }

    fn login_ok(m: &mut Mgmt) -> (String, String) {
        m.provision(&req(
            "POST",
            "/bios/provision",
            "{\"password\":\"correct-horse\"}",
            "",
            "",
        ));
        let r = m
            .handle(&req(
                "POST",
                "/bios/login",
                "{\"password\":\"correct-horse\"}",
                "",
                "",
            ))
            .unwrap();
        assert_eq!(r.status, 200, "{}", r.body_str());
        let set = r
            .headers
            .iter()
            .find(|(k, _)| k == "set-cookie")
            .map(|(_, v)| v.as_str())
            .unwrap();
        assert!(set.contains("HttpOnly"));
        assert!(set.contains("Secure"));
        assert!(set.contains("SameSite=Strict"));
        assert!(set.contains("Max-Age=3600"));
        assert!(set.contains("__Host-g6b_sid="));
        assert!(!set.to_ascii_lowercase().contains("domain="));
        let sid = set
            .split("__Host-g6b_sid=")
            .nth(1)
            .unwrap()
            .split(';')
            .next()
            .unwrap();
        let csrf = parse_json(&r.body_str())
            .unwrap()
            .get("csrf")
            .as_str()
            .unwrap()
            .to_string();
        let reauth = parse_json(&r.body_str())
            .unwrap()
            .get("reauth")
            .as_str()
            .unwrap()
            .to_string();
        (format!("{SID_COOKIE}={sid}"), format!("{csrf}:{reauth}"))
    }

    #[test]
    fn canned_flash_post_is_disabled() {
        let mut m = Mgmt::new("g6lc64", "riscv64");
        let r = m.handle(&req("POST", "/bios/flash", "{}", "", "")).unwrap();
        assert_eq!(r.status, 401);
        assert!(r.body_str().contains("canned"));
    }

    #[test]
    fn login_needs_provision_and_csrf_on_jobs() {
        let mut m = Mgmt::new("g6lc64", "riscv64");
        let r = m
            .handle(&req(
                "POST",
                "/bios/login",
                "{\"password\":\"correct-horse\"}",
                "",
                "",
            ))
            .unwrap();
        assert_eq!(r.status, 503);
        let p = m
            .handle(&req(
                "POST",
                "/bios/provision",
                "{\"password\":\"correct-horse\"}",
                "",
                "",
            ))
            .unwrap();
        assert_eq!(p.status, 200);
        for _ in 0..5 {
            let f = m
                .handle(&req(
                    "POST",
                    "/bios/login",
                    "{\"password\":\"wrong-wrong\"}",
                    "",
                    "",
                ))
                .unwrap();
            assert_eq!(f.status, 401);
        }
        let locked = m
            .handle(&req(
                "POST",
                "/bios/login",
                "{\"password\":\"correct-horse\"}",
                "",
                "",
            ))
            .unwrap();
        assert_eq!(locked.status, 429);
        let mut m = Mgmt::new("g6lc64", "riscv64");
        let badpw = m
            .handle(&req(
                "POST",
                "/bios/provision",
                "{\"password\":\"pass\tword12\"}",
                "",
                "",
            ))
            .unwrap();
        assert_eq!(badpw.status, 400);
        let sp = m
            .handle(&req(
                "POST",
                "/bios/provision",
                "{\"password\":\" correct-horse\"}",
                "",
                "",
            ))
            .unwrap();
        assert_eq!(sp.status, 400);
        let (ck, csrf) = login_ok(&mut m);
        let r = m
            .handle(&req("GET", "/bios/boot/targets", "", &ck, ""))
            .unwrap();
        assert_eq!(r.status, 200);
        assert!(r.body_str().contains("\"generation\":1"));
        let r = m
            .handle(&req(
                "POST",
                "/bios/boot/select",
                "{\"id\":\"vol0\",\"generation\":1}",
                &ck,
                "",
            ))
            .unwrap();
        assert_eq!(r.status, 403, "csrf required");
        let r = m
            .handle(&req(
                "POST",
                "/bios/boot/select",
                "{\"id\":\"vol0\",\"generation\":1}",
                &ck,
                &csrf,
            ))
            .unwrap();
        assert_eq!(r.status, 200);
        m.unplug("vol0");
        let r = m
            .handle(&req(
                "POST",
                "/bios/boot/select",
                "{\"id\":\"vol0\",\"generation\":1}",
                &ck,
                &csrf,
            ))
            .unwrap();
        assert_eq!(r.status, 409);
        assert!(r.body_str().contains("stale"));
    }

    #[test]
    fn update_apply_binds_digest_and_recovery_latch() {
        let mut m = Mgmt::new("g6lc64", "riscv64");
        let (ck, csrf) = login_ok(&mut m);
        let img = b"\x7fELFcapsule-bytes";
        let cap = Capsule::for_image("g6lc64", "riscv64", "1", img, "fw0");
        let mac = cap.mac(m.fw_key());
        cap.verify(m.fw_key(), &mac, img).unwrap();
        let digest = sha256_hex(img);
        let start = m
            .handle(&req(
                "POST",
                "/bios/update/start",
                &format!("{{\"digest\":\"{digest}\"}}"),
                &ck,
                &csrf,
            ))
            .unwrap();
        assert_eq!(start.status, 200);
        m.latch_recovery();
        let apply = m
            .handle(&req(
                "POST",
                "/bios/update/apply",
                &format!("{{\"digest\":\"{digest}\",\"generation\":1}}"),
                &ck,
                &csrf,
            ))
            .unwrap();
        assert_eq!(apply.status, 409);
        assert!(apply.body_str().contains("recovery"));
        let retry = m
            .handle(&req("POST", "/bios/recovery/retry-once", "{}", &ck, &csrf))
            .unwrap();
        assert_eq!(retry.status, 200);
        assert!(retry.body_str().contains("\"latched\":true"));
        let auto = m
            .handle(&req(
                "POST",
                "/bios/autoboot",
                "{\"enable\":true}",
                &ck,
                &csrf,
            ))
            .unwrap();
        assert_eq!(auto.status, 409);
        let cancel = m
            .handle(&req("POST", "/bios/update/cancel", "{}", &ck, &csrf))
            .unwrap();
        assert_eq!(cancel.status, 200);
    }

    #[test]
    fn wrong_password_is_rate_limited() {
        let mut m = Mgmt::new("g6lc64", "riscv64");
        let (ck, csrf) = login_ok(&mut m);
        m.handle(&req("POST", "/bios/logout", "{}", &ck, &csrf));
        for _ in 0..5 {
            let r = m
                .handle(&req(
                    "POST",
                    "/bios/login",
                    "{\"password\":\"wrong-wrong\"}",
                    "",
                    "",
                ))
                .unwrap();
            assert_eq!(r.status, 401);
        }
        let r = m
            .handle(&req(
                "POST",
                "/bios/login",
                "{\"password\":\"correct-horse\"}",
                "",
                "",
            ))
            .unwrap();
        assert_eq!(r.status, 429);
    }

    #[test]
    fn trust_root_needs_csrf_and_pins_rfc8448() {
        let mut m = Mgmt::new("g6lc64", "riscv64");
        let pem = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../kernel-spec/botan/test_data/tls_13_rfc8448/server_certificate.pem"
        ));
        let r = m
            .handle(&req("POST", "/bios/trust/root", pem, "", ""))
            .unwrap();
        assert_eq!(r.status, 401);
        let (ck, csrf) = login_ok(&mut m);
        let r = m
            .handle(&req("POST", "/bios/trust/root", pem, &ck, ""))
            .unwrap();
        assert_eq!(r.status, 403);
        let r = m
            .handle(&req("POST", "/bios/trust/root", pem, &ck, &csrf))
            .unwrap();
        assert_eq!(r.status, 200, "{}", r.body_str());
        assert!(r.body_str().contains("\"roots\":1"));
        let g = m.handle(&req("GET", "/bios/trust", "", &ck, "")).unwrap();
        assert_eq!(g.status, 200);
        assert!(g.body_str().contains("rsa"), "{}", g.body_str());
    }

    #[test]
    fn cors_mutating_get_and_advertise() {
        let mut m = Mgmt::new("g6lc64", "riscv64");
        let mut hostile = req("GET", "/bios/trust", "", "", "");
        hostile
            .headers
            .push(("origin".into(), "https://evil.example".into()));
        let r = m.handle(&hostile).unwrap();
        assert_eq!(r.status, 403);
        assert!(r.body_str().contains("cors"));
        let mut star = req("GET", "/bios/trust", "", "", "");
        star.headers.push(("origin".into(), "*".into()));
        assert_eq!(m.handle(&star).unwrap().status, 403);
        let r = m.handle(&req("GET", "/bios/login", "", "", "")).unwrap();
        assert_eq!(r.status, 405);
        assert!(r.body_str().contains("mutating get"));
        assert_eq!(Mgmt::advertise_url("0.0.0.0", 443), "https://10.0.2.15:443");
        assert_eq!(Mgmt::advertise_url("::", 443), "https://10.0.2.15:443");
        let secret = m
            .handle(&req("GET", "/bios/trust?password=x", "", "", ""))
            .unwrap();
        assert_eq!(secret.status, 403);
        assert_eq!(
            m.handle(&req("TRACE", "/bios/trust", "", "", ""))
                .unwrap()
                .status,
            405
        );
        assert_eq!(
            m.handle(&req("PUT", "/bios/recovery", "{}", "", ""))
                .unwrap()
                .status,
            405
        );
        assert_eq!(
            m.handle(&req("HEAD", "/bios/trust", "", "", ""))
                .unwrap()
                .status,
            405
        );
        let mut plain = req("POST", "/bios/login", "{\"password\":\"x\"}", "", "");
        plain
            .headers
            .push(("content-type".into(), "text/plain".into()));
        assert_eq!(m.handle(&plain).unwrap().status, 415);
        assert_eq!(
            Mgmt::advertise_url("127.0.0.1", 443),
            "https://127.0.0.1:443"
        );
        let mut ok = req("GET", "/bios/trust", "", "", "");
        ok.headers
            .push(("origin".into(), "https://10.0.2.15".into()));
        assert_eq!(m.handle(&ok).unwrap().status, 401);
        let spaced = req("GET", "/bios/trust", "", "__Host-g6b_sid=abc def", "");
        assert_eq!(m.handle(&spaced).unwrap().status, 401);
    }

    #[test]
    fn kvm_lease_needs_scope_and_releases_keys() {
        let mut m = Mgmt::new("g6lc64", "riscv64");
        let r = m.handle(&req("GET", "/bios/kvm", "", "", "")).unwrap();
        assert_eq!(r.status, 401);
        let (ck, csrf) = login_ok(&mut m);
        let v = m.handle(&req("GET", "/bios/kvm", "", &ck, "")).unwrap();
        assert_eq!(v.status, 200);
        assert!(v.body_str().contains("\"pixels\":0"));
        m.commit_kvm_pixels(&[0x11, 0x22, 0x33, 0x00]);
        let v2 = m.handle(&req("GET", "/bios/kvm", "", &ck, "")).unwrap();
        assert!(v2.body_str().contains("\"pixels\":4"));
        assert!(v2.body_str().contains("\"gen\":1"));
        assert!(!v2.body_str().contains("\"sha256\":\"\""));
        let unauth = m.handle(&req("GET", "/bios/kvm", "", "", "")).unwrap();
        assert_eq!(unauth.status, 401);
        assert!(!unauth.body_str().contains("pixels\":4"));
        let g = m
            .handle(&req("GET", "/bios/kvm/lease", "", &ck, &csrf))
            .unwrap();
        assert_eq!(g.status, 405);
        let lease = m
            .handle(&req(
                "POST",
                "/bios/kvm/lease",
                "{\"local\":true}",
                &ck,
                &csrf,
            ))
            .unwrap();
        assert_eq!(lease.status, 200, "{}", lease.body_str());
        let rel = m
            .handle(&req("POST", "/bios/kvm/release", "{}", &ck, &csrf))
            .unwrap();
        assert_eq!(rel.status, 200);
        assert!(rel.body_str().contains("released"));
    }

    #[test]
    fn recovery_unconfirmed_elf_replay_and_ui_isolation() {
        assert!(version_newer("1.2", "1.1"));
        assert!(!version_newer("1.1", "1.1"));
        assert!(!version_newer("1.0", "1.1"));
        let mut elf = vec![0u8; 120];
        elf[0..4].copy_from_slice(b"\x7fELF");
        elf[4] = 2;
        elf[5] = 1;
        elf[6] = 1;
        elf[16] = 2;
        elf[17] = 0;
        elf[18] = 0xf3;
        elf[19] = 0x00;
        elf[52] = 64;
        elf[53] = 0;
        elf[20] = 1;
        elf[54] = 56;
        elf[55] = 0;
        elf[56] = 1;
        elf[57] = 0;
        elf[24] = 0x00;
        elf[25] = 0x00;
        elf[26] = 0x00;
        elf[27] = 0x80;
        elf[32] = 64;
        elf[64] = 1;
        elf[68] = 5;
        elf[112] = 8;
        elf[80] = 0x00;
        elf[81] = 0x00;
        elf[82] = 0x00;
        elf[83] = 0x80;
        elf[96] = 16;
        elf[104] = 16;
        elf[72] = 120;
        check_image_elf(&elf).unwrap();
        let mut ov = elf.clone();
        ov[96..104].copy_from_slice(&u64::MAX.to_le_bytes());
        ov[104..112].copy_from_slice(&u64::MAX.to_le_bytes());
        assert!(check_image_elf(&ov).unwrap_err().contains("overflow"));
        let mut er = elf.clone();
        er[24] = 16;
        er[25] = 0;
        er[26] = 0;
        er[27] = 0;
        assert!(check_image_elf(&er).unwrap_err().contains("e_entry range"));
        let mut lowoff = elf.clone();
        lowoff[72] = 64;
        assert!(check_image_elf(&lowoff).unwrap_err().contains("p_offset"));
        let mut bigf = elf.clone();
        bigf[96] = 32;
        assert!(check_image_elf(&bigf).unwrap_err().contains("p_filesz"));
        let mut nov = elf.clone();
        nov[80] = 0;
        nov[81] = 0;
        nov[82] = 0;
        nov[83] = 0;
        assert!(check_image_elf(&nov).unwrap_err().contains("p_vaddr"));
        let mut same_pa = elf.clone();
        same_pa[88..96].copy_from_slice(&elf[80..88]);
        check_image_elf(&same_pa).unwrap();
        let mut bad_pa = elf.clone();
        bad_pa[88] = 1;
        assert!(check_image_elf(&bad_pa).unwrap_err().contains("p_paddr"));
        let mut badal = elf.clone();
        badal[112] = 3;
        assert!(check_image_elf(&badal).unwrap_err().contains("p_align"));
        let mut wx = elf.clone();
        wx[68] = 7;
        assert!(check_image_elf(&wx).unwrap_err().contains("wx"));
        let mut noload = elf.clone();
        noload[64] = 4;
        assert!(check_image_elf(&noload).unwrap_err().contains("pt_load"));
        let mut noent = elf.clone();
        noent[24] = 0;
        noent[25] = 0;
        noent[26] = 0;
        noent[27] = 0;
        assert!(check_image_elf(&noent).unwrap_err().contains("e_entry"));
        let mut noph = elf.clone();
        noph[56] = 0;
        assert!(check_image_elf(&noph).unwrap_err().contains("phnum"));
        let mut many = elf.clone();
        many[56] = 5;
        assert!(check_image_elf(&many).unwrap_err().contains("phnum"));
        assert!(check_image_elf(b"\x7fELFshort")
            .unwrap_err()
            .contains("elf"));
        let mut dynelf = elf.clone();
        dynelf[16] = 3;
        assert!(check_image_elf(&dynelf).unwrap_err().contains("e_type"));
        let mut x86 = elf.clone();
        x86[18] = 0x3e;
        assert!(check_image_elf(&x86).unwrap_err().contains("machine"));
        let mut m = Mgmt::new("g6lc64", "riscv64");
        m.power_loss_unconfirmed();
        let (ck, csrf) = login_ok(&mut m);
        let rec = m
            .handle(&req("GET", "/bios/recovery", "", &ck, ""))
            .unwrap();
        assert_eq!(rec.status, 200);
        assert!(rec.body_str().contains("unconfirmed"));
        m.fail_ui();
        let rec2 = m
            .handle(&req("GET", "/bios/recovery", "", &ck, ""))
            .unwrap();
        assert!(rec2.body_str().contains("\"ui_down\":true"));
        let st = m
            .handle(&req("GET", "/bios/update/status", "", &ck, ""))
            .unwrap();
        assert_eq!(st.status, 200);
        let auto = m
            .handle(&req(
                "POST",
                "/bios/autoboot",
                "{\"enable\":true}",
                &ck,
                &csrf,
            ))
            .unwrap();
        assert_eq!(auto.status, 409);
        let mut m2 = Mgmt::new("g6lc64", "riscv64");
        let (ck2, csrf2) = login_ok(&mut m2);
        let img = b"\x7fELFcapsule-bytes";
        let digest = sha256_hex(img);
        m2.handle(&req(
            "POST",
            "/bios/update/start",
            &format!("{{\"digest\":\"{digest}\"}}"),
            &ck2,
            &csrf2,
        ));
        let a1 = m2
            .handle(&req(
                "POST",
                "/bios/update/apply",
                &format!("{{\"digest\":\"{digest}\",\"generation\":1,\"version\":\"1\"}}"),
                &ck2,
                &csrf2,
            ))
            .unwrap();
        assert_eq!(a1.status, 200, "{}", a1.body_str());
        m2.handle(&req(
            "POST",
            "/bios/update/start",
            &format!("{{\"digest\":\"{digest}\"}}"),
            &ck2,
            &csrf2,
        ));
        let replay = m2
            .handle(&req(
                "POST",
                "/bios/update/apply",
                &format!("{{\"digest\":\"{digest}\",\"generation\":1,\"version\":\"1\"}}"),
                &ck2,
                &csrf2,
            ))
            .unwrap();
        assert_eq!(replay.status, 409);
        assert!(replay.body_str().contains("replay"));
        let cap = Capsule::for_image("g6lc64", "riscv64", "1", b"\x7fELFcapsule-bytes", "fw0");
        let dummy = g6b_tls::RsaPub {
            n: vec![1],
            e: vec![1],
        };
        assert!(cap.verify_pss(&dummy, &[]).unwrap_err().contains("pss"));
        assert!(cap
            .verify_pss(&dummy, &[1, 2, 3])
            .unwrap_err()
            .contains("pss"));
    }

    #[test]
    fn reauth_slot_a_second_session_and_credentials_survive_apply() {
        let mut m = Mgmt::new("g6lc64", "riscv64");
        let (ck, csrf) = login_ok(&mut m);
        let only_csrf = csrf.split(':').next().unwrap();
        let img = b"\x7fELFcapsule-bytes";
        let digest = sha256_hex(img);
        m.handle(&req(
            "POST",
            "/bios/update/start",
            &format!("{{\"digest\":\"{digest}\"}}"),
            &ck,
            &csrf,
        ));
        let no_re = m
            .handle(&req(
                "POST",
                "/bios/update/apply",
                &format!("{{\"digest\":\"{digest}\",\"generation\":1}}"),
                &ck,
                only_csrf,
            ))
            .unwrap();
        assert_eq!(no_re.status, 403);
        assert!(no_re.body_str().contains("reauth"));
        let slot_a = m
            .handle(&req(
                "POST",
                "/bios/update/apply",
                &format!("{{\"digest\":\"{digest}\",\"generation\":1,\"slot\":\"A\"}}"),
                &ck,
                &csrf,
            ))
            .unwrap();
        assert_eq!(slot_a.status, 400);
        assert!(slot_a.body_str().contains("slot A"));
        let ok = m
            .handle(&req(
                "POST",
                "/bios/update/apply",
                &format!("{{\"digest\":\"{digest}\",\"generation\":1,\"slot\":\"B\"}}"),
                &ck,
                &csrf,
            ))
            .unwrap();
        assert_eq!(ok.status, 200, "{}", ok.body_str());
        assert!(ok.body_str().contains("\"slot\":\"B\""));
        m.latch_recovery();
        m.unplug("vol0");
        let recu = m
            .handle(&req("GET", "/bios/recovery", "", &ck, ""))
            .unwrap();
        assert!(recu.body_str().contains("latched"));
        let (ck2, _) = login_ok(&mut m);
        assert_ne!(ck, ck2, "pass_dk survives apply; second session");
        let r1 = m
            .handle(&req("GET", "/bios/recovery", "", &ck, ""))
            .unwrap();
        let r2 = m
            .handle(&req("GET", "/bios/recovery", "", &ck2, ""))
            .unwrap();
        assert!(r1.body_str().contains("latched"));
        assert!(r2.body_str().contains("latched"));
        let kvm = m.handle(&req("GET", "/bios/kvm", "", &ck2, "")).unwrap();
        assert!(kvm.body_str().contains("\"remote\":false"));
    }

    #[test]
    fn session_expiry_health_ack_and_recovery_html() {
        let mut m = Mgmt::new("g6lc64", "riscv64");
        let (ck, csrf) = login_ok(&mut m);
        let bad = m
            .handle(&req(
                "POST",
                "/bios/login",
                "{\"password\":\"wrong-wrong\"}",
                "",
                "",
            ))
            .unwrap();
        assert_eq!(bad.status, 401);
        assert!(!bad.body_str().contains("wrong-wrong"));
        let html = m
            .handle(&req("GET", "/bios/recovery.html", "", &ck, ""))
            .unwrap();
        assert_eq!(html.status, 200);
        assert!(html.body_str().contains("recovery"));
        assert!(!html.body_str().contains("correct-horse"));
        let img = b"\x7fELFcapsule-bytes";
        let digest = sha256_hex(img);
        m.handle(&req(
            "POST",
            "/bios/update/start",
            &format!("{{\"digest\":\"{digest}\"}}"),
            &ck,
            &csrf,
        ));
        m.handle(&req(
            "POST",
            "/bios/update/apply",
            &format!("{{\"digest\":\"{digest}\",\"generation\":1}}"),
            &ck,
            &csrf,
        ));
        let rec = m
            .handle(&req("GET", "/bios/recovery", "", &ck, ""))
            .unwrap();
        assert!(rec.body_str().contains("in-progress"));
        let auto = m
            .handle(&req(
                "POST",
                "/bios/autoboot",
                "{\"enable\":true}",
                &ck,
                &csrf,
            ))
            .unwrap();
        assert_eq!(auto.status, 409);
        let ack = m
            .handle(&req(
                "POST",
                "/bios/health/ack",
                &format!("{{\"digest\":\"{digest}\",\"generation\":1}}"),
                &ck,
                &csrf,
            ))
            .unwrap();
        assert_eq!(ack.status, 200, "{}", ack.body_str());
        assert!(ack.body_str().contains("confirmed"));
        assert!(ack.body_str().contains("\"autoboot\":false"));
        let retry = m
            .handle(&req("POST", "/bios/recovery/retry-once", "{}", &ck, &csrf))
            .unwrap();
        assert_eq!(retry.status, 409);
        m.latch_recovery();
        let stale_gen = m
            .handle(&req(
                "POST",
                "/bios/health/ack",
                &format!("{{\"digest\":\"{digest}\",\"generation\":9}}"),
                &ck,
                &csrf,
            ))
            .unwrap();
        assert_eq!(stale_gen.status, 409);
        let ack2 = m
            .handle(&req(
                "POST",
                "/bios/health/ack",
                &format!("{{\"digest\":\"{digest}\",\"generation\":1}}"),
                &ck,
                &csrf,
            ))
            .unwrap();
        assert_eq!(ack2.status, 409);
        m.advance_unix(4000);
        let exp = m.handle(&req("GET", "/bios/trust", "", &ck, "")).unwrap();
        assert_eq!(exp.status, 401);
        assert!(exp.body_str().contains("expired"));
        let mut m3 = Mgmt::new("g6lc64", "riscv64");
        let (ck3, csrf3) = login_ok(&mut m3);
        m3.latch_recovery();
        let clr = m3
            .handle(&req("POST", "/bios/recovery/clear", "{}", &ck3, &csrf3))
            .unwrap();
        assert_eq!(clr.status, 403);
        assert!(clr.body_str().contains("cannot clear"));
        let still = m3
            .handle(&req("GET", "/bios/recovery", "", &ck3, ""))
            .unwrap();
        assert!(still.body_str().contains("latched"));
        let lo = m3
            .handle(&req("POST", "/bios/logout", "{}", &ck3, &csrf3))
            .unwrap();
        let set = lo
            .headers
            .iter()
            .find(|(k, _)| k == "set-cookie")
            .map(|(_, v)| v.as_str())
            .unwrap();
        assert!(set.contains("Max-Age=0"));
        let gone = m3.handle(&req("GET", "/bios/trust", "", &ck3, "")).unwrap();
        assert_eq!(gone.status, 401);
    }
}
