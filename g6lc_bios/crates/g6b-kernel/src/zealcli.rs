// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Wiring the CLI to the kernel's own adapters.
//!
//! `g6b-zealcli` deliberately knows nothing about `g6b-hw`, TLS or flash, so the
//! kernel — which owns all three — implements the CLI's poll-shaped ports here.
//! That keeps the boot order honest: the CLI comes up with whatever ports exist,
//! a missing capability is a refusal at the prompt, and the web engine is not
//! involved at any point.
//!
//! The HTTPS transfer is **poll-driven on purpose**. `get` plans the URL
//! (`g6b-http`), opens an isolated-NAT hw TCP socket (`g6b-hw`) and writes the
//! request; each `poll` performs exactly one non-blocking `recv` and returns.
//! The `10.0.2.2` packet path is the same shape: `get` only arms the job,
//! each `poll` takes watchdog then one SYN/ACK/GET step. No thread is created,
//! nothing blocks the prompt or the timer tick, and the transfer can be
//! cancelled between two polls.

use std::fmt;

use g6b_tls::{CertStore, Entropy, FixtureEntropy, VirtioRng};

use g6b_spec::BoardSpec;
use g6b_zealcli::{
    Entry, FlashPort, NetPort, Ports, Progress, Session as ZealCli, VolumeInfo, VolumePort,
};

/// Volumes from the compiled BoardSpec via `g6b-fs`.
#[derive(Debug, Clone)]
pub struct KernelVolumes {
    spec: BoardSpec,
}

impl KernelVolumes {
    pub fn new(spec: &BoardSpec) -> Self {
        Self { spec: spec.clone() }
    }

    fn fs_of(&self, volume: &str) -> Option<g6b_fs::FsKind> {
        g6b_fs::volumes(&self.spec)
            .into_iter()
            .find(|v| v.label == volume)
            .map(|v| v.fs)
    }
}

impl VolumePort for KernelVolumes {
    fn volumes(&self) -> Vec<VolumeInfo> {
        g6b_fs::volumes(&self.spec)
            .into_iter()
            .map(|v| VolumeInfo {
                id: v.label.clone(),
                label: v.label,
                fs: v.fs.as_str().into(),
                role: v.role.into(),
                // The modelled volume is a BoardSpec fact, not a device that
                // answered an inquiry — so it reports no vendor rather than a
                // plausible one.
                vendor: String::new(),
            })
            .collect()
    }

    fn list(&self, volume: &str, path: &str) -> Result<Vec<Entry>, String> {
        let fs = self
            .fs_of(volume)
            .ok_or_else(|| format!("no volume {volume}"))?;
        let flash = g6b_fs::volumes(&self.spec)
            .into_iter()
            .any(|v| v.label == volume && v.role == "flash");
        // The firmware stick lists images; a key lists its tree.
        let ents = if flash {
            if path == "/" {
                g6b_fs::flash_images(&self.spec)
            } else {
                Vec::new()
            }
        } else {
            g6b_fs::list_key(&self.spec, path, Some(fs))
        };
        Ok(ents
            .into_iter()
            .map(|e| Entry {
                name: e.name,
                dir: e.is_dir,
                size: e.size,
            })
            .collect())
    }

    fn read(&self, volume: &str, path: &str) -> Result<Vec<u8>, String> {
        let ents = self.list(volume, &g6b_zealcli::fsview::parent_of(path))?;
        let name = path.rsplit('/').next().unwrap_or(path);
        let ent = ents
            .iter()
            .find(|e| !e.dir && e.name == name)
            .ok_or_else(|| format!("no file {volume}:{path}"))?;
        // The BIOS has no block driver on the host side: a listed image is
        // reported with its real size and a shaped body, and anything else is
        // refused rather than invented.
        if ent.name.ends_with(".elf") {
            let mut b = b"\x7fELF".to_vec();
            b.resize(ent.size.min(1 << 20) as usize, 0);
            return Ok(b);
        }
        if ent.name.ends_with(".json") {
            return Ok(b"{}\n".to_vec());
        }
        Err(format!(
            "{volume}:{path} is {} bytes of device media; the host session has no block reader",
            ent.size
        ))
    }
}

/// A session whose volumes are real host media ([`DirVolumes`]) instead of the
/// BoardSpec's modelled ones. Net and flash stay the kernel's.
pub fn session_with_volumes(spec: &BoardSpec, vols: DirVolumes) -> ZealCli {
    let mut p = ports(spec);
    p = p.with_volumes(vols);
    ZealCli::with_ports(spec, p)
}

/// Media the operator (or the QEMU harness) actually attached, each mapped to a
/// real host path: a directory is a mounted volume, a file is an image the BIOS
/// reads windows out of (`--volume ID=PATH[:role[:vendor]]`).
///
/// This is what makes the boot picker honest on a workstation: the entries come
/// from probing the same bytes QEMU is given, not from a table of hopes.
#[derive(Debug, Clone, Default)]
pub struct DirVolumes {
    vols: Vec<(VolumeInfo, std::path::PathBuf)>,
}

impl DirVolumes {
    pub fn new() -> Self {
        Self::default()
    }

    /// Declare `id` at `path`. A directory lists as a volume; a file is an
    /// image, exposed as the volume's own `/` so an ISO reads at sector 16.
    pub fn mount(
        mut self,
        id: &str,
        path: impl Into<std::path::PathBuf>,
        role: &str,
        vendor: &str,
    ) -> Self {
        let path = path.into();
        let fs = if path.is_dir() { "host-dir" } else { "image" };
        self.vols.push((
            VolumeInfo {
                id: id.into(),
                label: id.into(),
                fs: fs.into(),
                role: role.into(),
                vendor: vendor.into(),
            },
            path,
        ));
        self
    }

    /// `ID=PATH[:role[:vendor]]`, the CLI spelling. Windows drive letters are
    /// handled: only a `:` after the first two characters separates fields.
    pub fn parse_mount(&mut self, arg: &str) -> Result<(), String> {
        let (id, rest) = arg
            .split_once('=')
            .ok_or_else(|| format!("--volume wants ID=PATH[:role[:vendor]], got `{arg}`"))?;
        let mut fields: Vec<&str> = Vec::new();
        let mut start = 0usize;
        for (i, ch) in rest.char_indices() {
            if ch == ':' && i > 1 {
                fields.push(&rest[start..i]);
                start = i + 1;
            }
        }
        fields.push(&rest[start..]);
        let path = fields[0];
        let role = fields.get(1).copied().unwrap_or("key");
        let vendor = fields.get(2).copied().unwrap_or("");
        if !std::path::Path::new(path).exists() {
            return Err(format!("--volume {id}: {path} does not exist"));
        }
        *self = std::mem::take(self).mount(id, path, role, vendor);
        Ok(())
    }

    fn path_of(&self, volume: &str) -> Option<&std::path::PathBuf> {
        self.vols
            .iter()
            .find(|(v, _)| v.id == volume)
            .map(|(_, p)| p)
    }

    /// Resolve a volume-relative path, refusing anything that escapes the mount.
    fn resolve(&self, volume: &str, path: &str) -> Result<std::path::PathBuf, String> {
        let base = self
            .path_of(volume)
            .ok_or_else(|| format!("no volume {volume}"))?;
        if base.is_file() {
            // An image: only the volume root addresses it.
            let listed_name = base.file_name().and_then(|name| name.to_str());
            return if matches!(path, "" | "/")
                || listed_name.is_some_and(|name| path == name || path == format!("/{name}"))
            {
                Ok(base.clone())
            } else {
                Err(format!(
                    "{volume} is an image; `{path}` is not a path in it"
                ))
            };
        }
        let mut out = base.clone();
        for part in path.split('/') {
            match part {
                "" | "." => {}
                // A boot menu must never be a path-traversal primitive.
                ".." => return Err("path escapes the volume".into()),
                s => out.push(s),
            }
        }
        Ok(out)
    }
}

impl VolumePort for DirVolumes {
    fn volumes(&self) -> Vec<VolumeInfo> {
        self.vols.iter().map(|(v, _)| v.clone()).collect()
    }

    fn list(&self, volume: &str, path: &str) -> Result<Vec<Entry>, String> {
        let dir = self.resolve(volume, path)?;
        if dir.is_file() {
            // The image itself is the only entry of an image volume.
            let size = dir.metadata().map(|m| m.len()).unwrap_or(0);
            let name = dir
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| volume.to_string());
            return Ok(vec![Entry {
                name,
                dir: false,
                size,
            }]);
        }
        let rd = std::fs::read_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        let mut out = Vec::new();
        for ent in rd.flatten() {
            let meta = match ent.metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };
            out.push(Entry {
                name: ent.file_name().to_string_lossy().into_owned(),
                dir: meta.is_dir(),
                size: meta.len(),
            });
        }
        out.sort_by(|a, b| (b.dir, &a.name).cmp(&(a.dir, &b.name)));
        Ok(out)
    }

    fn read(&self, volume: &str, path: &str) -> Result<Vec<u8>, String> {
        // Whole-file reads are bounded: media probing uses `read_window`, and a
        // multi-gigabyte ISO must not be pulled into memory by accident.
        const MAX: u64 = 8 << 20;
        let file = self.resolve(volume, path)?;
        let len = file.metadata().map(|m| m.len()).unwrap_or(0);
        if len > MAX {
            return Err(format!(
                "{} is {len} bytes; read a window instead of the whole image",
                file.display()
            ));
        }
        std::fs::read(&file).map_err(|e| format!("{}: {e}", file.display()))
    }

    fn read_window(
        &self,
        volume: &str,
        path: &str,
        off: u64,
        len: usize,
    ) -> Result<Vec<u8>, String> {
        use std::io::{Read, Seek, SeekFrom};
        let file = self.resolve(volume, path)?;
        let mut f = std::fs::File::open(&file).map_err(|e| format!("{}: {e}", file.display()))?;
        f.seek(SeekFrom::Start(off))
            .map_err(|e| format!("{}: {e}", file.display()))?;
        let mut buf = vec![0u8; len];
        let mut used = 0;
        while used < len {
            match f.read(&mut buf[used..]) {
                Ok(0) => break,
                Ok(n) => used += n,
                Err(e) => return Err(format!("{}: {e}", file.display())),
            }
        }
        buf.truncate(used);
        Ok(buf)
    }
}

/// One in-flight GET on an hw TCP socket, or the in-process NAT packet peer.
struct Job {
    sock: Option<u32>,
    https: bool,
    from_host: String,
    from_port: u16,
    device: String,
    buf: Vec<u8>,
    /// HTTP bytes waiting to be parsed (after the GET step).
    pkt: Option<Vec<u8>>,
    /// Armed NAT GET; rings are created on the first poll, not in `get`.
    nat_req: Option<Vec<u8>>,
    nat: Option<NatJob>,
    /// When bytes last arrived. A poll count is not a clock — under load 20k
    /// non-blocking reads can pass before the peer has even accepted — so the
    /// framing and stall rules are stated in time, while each poll still
    /// returns immediately. The guest equivalent reads `rdtime`.
    last: std::time::Instant,
    done: bool,
    /// Socket GET: connect on poll, not in `get`. IPv4 literal only.
    conn: Option<(String, u16)>,
    tx: Option<Vec<u8>>,
    /// Isolated NAT DNS A (`g6lc`) before the packet GET.
    dns: Option<String>,
    /// Next-hop IPv4 after DNS (or the literal NAT origin). HTTP must match.
    dst: Option<[u8; 4]>,
}

/// Guest virtio-net rings for one NAT GET. Dropped on cancel.
struct NatJob {
    net: g6b_asm::exec::GuestVirtioNet,
    req: Vec<u8>,
    step: u8,
    ack_n: u32,
}

impl fmt::Debug for Job {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Job")
            .field("sock", &self.sock)
            .field("https", &self.https)
            .field("from_host", &self.from_host)
            .field("from_port", &self.from_port)
            .field("device", &self.device)
            .field("buf", &self.buf.len())
            .field("pkt", &self.pkt.as_ref().map(Vec::len))
            .field("nat_req", &self.nat_req.as_ref().map(Vec::len))
            .field("nat_step", &self.nat.as_ref().map(|n| n.step))
            .field("conn", &self.conn)
            .field("tx", &self.tx.as_ref().map(Vec::len))
            .field("dns", &self.dns)
            .field("dst", &self.dst)
            .field("done", &self.done)
            .finish()
    }
}

const JOB_SLOTS: usize = 4;

/// Outbound GET over the isolated NAT stack, one `recv` (or one handshake
/// step) per poll. Watchdog is taken before that I/O.
#[derive(Debug)]
pub struct KernelNet {
    hw: g6b_hw::HwSession,
    slots: [Option<Job>; JOB_SLOTS],
    gen: [u32; JOB_SLOTS],
    wdt_hits: u32,
    wdt_hold: bool,
    /// `None` fails closed. Hostname hash is not entropy.
    tls_rng: Option<TlsEntropyKind>,
    /// 1-RTT PSK tickets. 0-RTT is not stored.
    tls_sessions: g6b_tls::SessionCache,
    /// Empty / missing store fails closed for `verify_https_peer`.
    trust: Option<CertStore>,
}

#[derive(Clone, Debug)]
enum TlsEntropyKind {
    Fixture(FixtureEntropy),
    Virtio(VirtioRng),
}

impl Entropy for TlsEntropyKind {
    fn fill(&mut self, buf: &mut [u8]) -> Result<(), String> {
        match self {
            Self::Fixture(e) => e.fill(buf),
            Self::Virtio(e) => e.fill(buf),
        }
    }
}

/// No data for this long ends the transfer. Polls stay non-blocking; this is
/// the deadline that makes them terminate. Close-delimited bodies complete
/// on peer EOF (`TcpRecv::Eof`), not on idle time.
const STALL: std::time::Duration = std::time::Duration::from_secs(10);
/// Ceiling on a single response, so a hostile server cannot grow the heap.
const MAX_BODY_BYTES: usize = 64 * 1024 * 1024;

impl KernelNet {
    pub fn new(spec: &BoardSpec) -> Self {
        Self {
            hw: g6b_hw::HwSession::from_board(spec),
            slots: [None, None, None, None],
            gen: [0; JOB_SLOTS],
            wdt_hits: 0,
            wdt_hold: false,
            tls_rng: None,
            tls_sessions: g6b_tls::SessionCache::default(),
            trust: None,
        }
    }

    fn use_test_entropy(&mut self) {
        self.tls_rng = Some(TlsEntropyKind::Fixture(FixtureEntropy::TEST));
    }

    fn use_virtio_rng(&mut self, bytes: Vec<u8>) {
        self.tls_rng = Some(TlsEntropyKind::Virtio(VirtioRng::from_device(bytes)));
    }

    fn use_virtio_rng_extracted(&mut self, bytes: &[u8]) -> Result<(), String> {
        self.tls_rng = Some(TlsEntropyKind::Virtio(VirtioRng::from_device_extracted(
            bytes,
        )?));
        Ok(())
    }

    /// Isolated-NAT OCSP POST bytes. HTTPS and public hosts fail closed.
    fn ocsp_http_plan(url: &str, serial: &[u8]) -> Result<Vec<u8>, String> {
        let u = g6b_http::ocsp_plan(url)?;
        Ok(g6b_http::ocsp_http_post(
            &u,
            &g6b_tls::ocsp_request_for_serial(serial),
        ))
    }

    fn attach_trust(&mut self, store: CertStore) {
        self.trust = Some(store);
    }

    fn verify_https_peer(
        &self,
        host: &str,
        pem: &[u8],
        clock: &dyn g6b_tls::Clock,
    ) -> Result<(), String> {
        let store = self.trust.as_ref().ok_or("tls: no trust store")?;
        let chain = g6b_tls::parse_cert_chain(pem)?;
        store.verify_chain(&chain, host, clock)
    }

    fn remember_ticket(&mut self, ticket: g6b_tls::Ticket) {
        self.tls_sessions.store(ticket);
    }

    /// After a 1-RTT handshake, install NewSessionTicket for this host.
    fn install_server_ticket(
        &mut self,
        host: &str,
        nst: &[u8],
        res_master: &[u8; 32],
        pk: &[u8; 32],
    ) -> Result<(), String> {
        self.tls_sessions.install_nst(host, nst, res_master, pk)
    }

    fn pack(slot: usize, gen: u32) -> u32 {
        (gen << 8) | slot as u32
    }

    fn unpack(handle: u32) -> (usize, u32) {
        ((handle & 0xff) as usize, handle >> 8)
    }

    fn job(&self, handle: u32) -> Option<&Job> {
        let (slot, gen) = Self::unpack(handle);
        if slot >= JOB_SLOTS || gen == 0 || self.gen[slot] != gen {
            return None;
        }
        self.slots[slot].as_ref()
    }

    fn job_mut(&mut self, handle: u32) -> Option<&mut Job> {
        let (slot, gen) = Self::unpack(handle);
        if slot >= JOB_SLOTS || gen == 0 || self.gen[slot] != gen {
            return None;
        }
        self.slots[slot].as_mut()
    }

    fn alloc(&mut self, job: Job) -> Result<u32, String> {
        for slot in 0..JOB_SLOTS {
            if self.slots[slot].is_none() {
                let mut g = self.gen[slot].saturating_add(1);
                if g == 0 {
                    g = 1;
                }
                self.gen[slot] = g;
                self.slots[slot] = Some(job);
                return Ok(Self::pack(slot, g));
            }
        }
        Err("job budget".into())
    }

    fn job_count(&self) -> usize {
        self.slots.iter().filter(|s| s.is_some()).count()
    }

    /// Test seam: next `poll` fails before packet/socket I/O.
    fn hold_watchdog(&mut self) {
        self.wdt_hold = true;
    }

    fn drop_link(&mut self) {
        let id = self.hw.primary_net_id();
        let _ = self.hw.apply_link(&id, "down");
    }

    fn unplug(&mut self) {
        let _ = self
            .hw
            .push(g6b_hw::HwMsg::Cable(g6b_hw::CableEvent::Removed));
        let _ = self.hw.drain_one();
    }

    fn force_dst(&mut self, handle: u32, ip: [u8; 4]) {
        if let Some(job) = self.job_mut(handle) {
            job.dst = Some(ip);
        }
    }

    fn link_down(&self, id: &str) -> bool {
        self.hw
            .device(id)
            .map(|d| d.inet.link != g6b_hw::LinkState::Up)
            .unwrap_or(true)
    }

    fn open_nat(&self, req: Vec<u8>) -> Result<NatJob, String> {
        let net = match self.hw.board() {
            Some(spec) if spec.wants_virtio_net() => {
                let m = g6b_asm::analyze::kstart(spec);
                g6b_asm::exec::GuestVirtioNet::from_kstart(spec, &m, 0x8020_0000)?.1
            }
            _ => g6b_asm::exec::GuestVirtioNet::new()?,
        };
        Ok(NatJob {
            net,
            req,
            step: 0,
            ack_n: 0,
        })
    }

    /// One SYN / ACK / GET. `true` means the handshake is still open.
    fn step_nat(job: &mut Job) -> Result<bool, String> {
        let Some(nat) = job.nat.as_mut() else {
            return Ok(false);
        };
        match nat.step {
            0 => {
                nat.ack_n = nat.net.handshake_syn()?;
                nat.step = 1;
                Ok(true)
            }
            1 => {
                nat.net.handshake_ack(nat.ack_n)?;
                nat.step = 2;
                Ok(true)
            }
            2 => {
                let http = nat.net.handshake_get(&nat.req, nat.ack_n)?;
                job.nat = None;
                job.pkt = Some(http);
                Ok(false)
            }
            _ => Err("nat handshake".into()),
        }
    }

    /// Isolated NAT + link up — the same preparation the kernel fetch does.
    fn prepare(&mut self) -> Result<String, String> {
        if !self
            .hw
            .spec
            .adapters
            .iter()
            .any(|a| a.class == g6b_hw::AdapterClass::Net)
        {
            return Err(
                "no network adapter in this build (kernel.hw.virtio_net / ethernet)".into(),
            );
        }
        self.hw.ensure();
        if self.hw.mode() == g6b_hw::NatMode::Minimal {
            self.hw.apply_nat("isolated")?;
        }
        let id = self.hw.primary_net_id();
        let link_down = self
            .hw
            .device(&id)
            .map(|d| d.inet.link != g6b_hw::LinkState::Up)
            .unwrap_or(true);
        if link_down {
            self.hw.apply_link(&id, "up")?;
        }
        Ok(id)
    }
}

impl NetPort for KernelNet {
    fn get(&mut self, url: &str) -> Result<u32, String> {
        let req = g6b_http::outbound::plan(url)?;
        let device = self.prepare()?;
        let bytes = if req.https {
            let rng = self.tls_rng.as_mut().ok_or("tls: no entropy")?;
            if let Some(t) = self.tls_sessions.lookup(&req.host).cloned() {
                let mut rnd = [0u8; 32];
                rng.fill(&mut rnd)?;
                let ch = g6b_tls::client_hello_tls13_psk(&rnd, &t.pk, &req.host, &t)?;
                let mut rec = vec![0x16, 0x03, 0x03];
                rec.extend_from_slice(&(ch.len() as u16).to_be_bytes());
                rec.extend(ch);
                rec
            } else {
                // TLS 1.2 ECDHE-GCM hello (supported_versions 1.2). Avoids schoolbook
                // X25519 on the first GET; 1.3 is used once a ticket/pk exists.
                g6b_tls::client_hello_with(&req.host, rng)?
            }
        } else {
            g6b_http::outbound::http1_get_request(&req)
        };
        if !req.https && g6b_hw::is_nat_http_host(&req.host, req.port) {
            return self.alloc(Job {
                sock: None,
                https: false,
                from_host: req.host.clone(),
                from_port: req.port,
                device,
                buf: Vec::new(),
                pkt: None,
                nat_req: Some(bytes),
                nat: None,
                last: std::time::Instant::now(),
                done: false,
                conn: None,
                tx: None,
                dns: None,
                dst: Some([10, 0, 2, 2]),
            });
        }
        if !req.https && g6b_hw::is_nat_dns_name(&req.host) && req.port == 80 {
            return self.alloc(Job {
                sock: None,
                https: false,
                from_host: req.host.clone(),
                from_port: req.port,
                device,
                buf: Vec::new(),
                pkt: None,
                nat_req: Some(bytes),
                nat: None,
                last: std::time::Instant::now(),
                done: false,
                conn: None,
                tx: None,
                dns: Some(req.host),
                dst: None,
            });
        }
        self.alloc(Job {
            sock: None,
            https: req.https,
            from_host: req.host.clone(),
            from_port: req.port,
            device,
            buf: Vec::new(),
            pkt: None,
            nat_req: None,
            nat: None,
            last: std::time::Instant::now(),
            done: false,
            conn: Some((req.host, req.port)),
            tx: Some(bytes),
            dns: None,
            dst: None,
        })
    }

    fn poll(&mut self, handle: u32) -> Progress {
        let (slot, gen) = Self::unpack(handle);
        if slot < JOB_SLOTS && gen != 0 && self.gen[slot] != gen {
            return Progress::Failed("stale generation".into());
        }
        match self.job(handle) {
            None => return Progress::Failed("no such transfer".into()),
            Some(job) if job.done => {
                return Progress::Failed("transfer already finished".into());
            }
            Some(_) => {}
        }
        self.wdt_hits = self.wdt_hits.wrapping_add(1);
        if self.wdt_hold {
            if let Some(job) = self.job_mut(handle) {
                job.done = true;
            }
            return Progress::Failed("watchdog: fetch stopped".into());
        }
        let device = self
            .job(handle)
            .map(|j| j.device.clone())
            .unwrap_or_default();
        if self.link_down(&device) {
            let sock = if let Some(job) = self.job_mut(handle) {
                job.done = true;
                job.nat = None;
                job.nat_req = None;
                job.pkt = None;
                job.conn = None;
                job.tx = None;
                job.dns = None;
                job.dst = None;
                job.sock.take()
            } else {
                None
            };
            if let Some(s) = sock {
                let _ = self.hw.sock_close(s);
            }
            return Progress::Failed("link down".into());
        }
        let need_dns = self.job(handle).map(|j| j.dns.is_some()).unwrap_or(false);
        if need_dns {
            let name = self
                .job_mut(handle)
                .and_then(|j| j.dns.take())
                .expect("dns");
            match g6b_hw::nat_dns_a(&name) {
                Ok(ip) => {
                    if let Some(j) = self.job_mut(handle) {
                        j.dst = Some(ip);
                    }
                    return Progress::Pending { done: 0, total: 0 };
                }
                Err(e) => {
                    if let Some(j) = self.job_mut(handle) {
                        j.done = true;
                    }
                    return Progress::Failed(e);
                }
            }
        }
        if let Some(ip) = self.job(handle).and_then(|j| j.dst) {
            if let Err(e) = g6b_hw::nat_http_dst(ip) {
                if let Some(j) = self.job_mut(handle) {
                    j.done = true;
                }
                return Progress::Failed(e);
            }
        }
        let need_conn = self
            .job(handle)
            .map(|j| j.sock.is_none() && j.conn.is_some())
            .unwrap_or(false);
        if need_conn {
            let (device, host, port) = {
                let j = self.job(handle).expect("conn job");
                let (h, p) = j.conn.clone().expect("conn");
                (j.device.clone(), h, p)
            };
            match self.hw.tcp_try_connect_sock(&device, &host, port) {
                Ok(None) => {
                    return Progress::Pending { done: 0, total: 0 };
                }
                Ok(Some(sock)) => {
                    if let Some(j) = self.job_mut(handle) {
                        j.sock = Some(sock);
                        j.conn = None;
                    }
                }
                Err(e) => {
                    if let Some(j) = self.job_mut(handle) {
                        j.done = true;
                    }
                    return Progress::Failed(e);
                }
            }
        }
        let send = self
            .job(handle)
            .and_then(|j| match (j.sock, j.tx.as_ref()) {
                (Some(s), Some(t)) if !t.is_empty() => Some((s, t.clone())),
                _ => None,
            });
        if let Some((sock, tx)) = send {
            match self.hw.tcp_send_bytes(sock, &tx) {
                Ok(n) if n >= tx.len() => {
                    if let Some(j) = self.job_mut(handle) {
                        j.tx = None;
                    }
                    return Progress::Pending { done: 0, total: 0 };
                }
                Ok(n) => {
                    if let Some(j) = self.job_mut(handle) {
                        if let Some(rest) = j.tx.as_mut() {
                            rest.drain(..n.min(rest.len()));
                        }
                    }
                    return Progress::Pending { done: 0, total: 0 };
                }
                Err(e) => {
                    if let Some(j) = self.job_mut(handle) {
                        j.done = true;
                    }
                    return Progress::Failed(e);
                }
            }
        }
        let need_arm = self
            .job(handle)
            .map(|j| j.nat_req.is_some() && j.nat.is_none())
            .unwrap_or(false);
        if need_arm {
            let req = self
                .job_mut(handle)
                .and_then(|j| j.nat_req.take())
                .expect("nat_req");
            match self.open_nat(req) {
                Ok(nat) => {
                    if let Some(j) = self.job_mut(handle) {
                        j.nat = Some(nat);
                    }
                }
                Err(e) => {
                    if let Some(j) = self.job_mut(handle) {
                        j.done = true;
                    }
                    return Progress::Failed(e);
                }
            }
        }
        {
            let Some(job) = self.job_mut(handle) else {
                return Progress::Failed("no such transfer".into());
            };
            match Self::step_nat(job) {
                Ok(true) => {
                    return Progress::Pending {
                        done: job.buf.len() as u64,
                        total: 0,
                    };
                }
                Ok(false) => {}
                Err(e) => {
                    job.done = true;
                    return Progress::Failed(e);
                }
            }
        }
        let pkt = self.job_mut(handle).and_then(|j| j.pkt.take());
        let sock = self.job(handle).and_then(|j| j.sock);
        let (chunk, eof) = if let Some(pkt) = pkt {
            (pkt, true)
        } else if let Some(sock) = sock {
            match self.hw.tcp_recv_bytes(sock) {
                Ok(g6b_hw::TcpRecv::Data(c)) => (c, false),
                Ok(g6b_hw::TcpRecv::WouldBlock) => (Vec::new(), false),
                Ok(g6b_hw::TcpRecv::Eof) => (Vec::new(), true),
                Err(e) => {
                    if let Some(j) = self.job_mut(handle) {
                        j.done = true;
                    }
                    return Progress::Failed(e);
                }
            }
        } else {
            if let Some(j) = self.job_mut(handle) {
                j.done = true;
            }
            return Progress::Failed("no packet and no socket".into());
        };
        let Some(job) = self.job_mut(handle) else {
            return Progress::Failed("no such transfer".into());
        };
        if !chunk.is_empty() {
            job.last = std::time::Instant::now();
            job.buf.extend_from_slice(&chunk);
            if job.buf.len() > MAX_BODY_BYTES {
                job.done = true;
                return Progress::Failed(format!("response exceeds {MAX_BODY_BYTES} bytes"));
            }
        }
        if job.https {
            if job.buf.is_empty() {
                if eof || job.last.elapsed() > STALL {
                    job.done = true;
                    return Progress::Failed(format!(
                        "transfer stalled: no data for {}s",
                        STALL.as_secs()
                    ));
                }
                return Progress::Pending { done: 0, total: 0 };
            }
            // The client record layer is not implemented (B54): report the
            // handshake honestly instead of pretending to decrypt.
            let kind = g6b_tls::tls_record_kind(&job.buf).unwrap_or("unknown");
            job.done = true;
            return Progress::Failed(format!(
                "https via=hw-tcp tls={kind}: client record layer is not implemented yet (B54); \
                 use a USB key image or an http mirror on the isolated NAT"
            ));
        }
        match g6b_http::outbound::parse_http1_response_partial(&job.buf, eof) {
            g6b_http::outbound::Http1Parse::Done(resp) => finish_resp(job, resp),
            g6b_http::outbound::Http1Parse::NeedMore | g6b_http::outbound::Http1Parse::NeedEof => {
                if job.last.elapsed() > STALL {
                    job.done = true;
                    return Progress::Failed(format!(
                        "transfer stalled: no data for {}s",
                        STALL.as_secs()
                    ));
                }
                Progress::Pending {
                    done: job.buf.len() as u64,
                    total: 0,
                }
            }
        }
    }

    fn cancel(&mut self, handle: u32) {
        let (slot, gen) = Self::unpack(handle);
        if slot >= JOB_SLOTS || gen == 0 || self.gen[slot] != gen {
            return;
        }
        if let Some(job) = self.slots[slot].take() {
            if let Some(sock) = job.sock {
                let _ = self.hw.sock_close(sock);
            }
        }
    }

    fn status(&self) -> String {
        let nets: Vec<String> = self
            .hw
            .spec
            .adapters
            .iter()
            .filter(|a| a.class == g6b_hw::AdapterClass::Net)
            .map(|a| format!("{} {}", a.id, a.kind.as_str()))
            .collect();
        if nets.is_empty() {
            return "HW-NET none (no adapter compiled)".into();
        }
        format!(
            "HW-NET {} nat={} jobs={} wdt={}",
            nets.join(", "),
            self.hw.mode().as_str(),
            self.job_count(),
            self.wdt_hits
        )
    }
}

fn finish_resp(job: &mut Job, resp: g6b_http::Response) -> Progress {
    job.done = true;
    if g6b_http::outbound::is_redirect(resp.status) {
        let loc = resp
            .headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("location"))
            .map(|(_, v)| v.as_str())
            .unwrap_or("");
        let from = g6b_http::outbound::OutboundReq {
            https: job.https,
            host: job.from_host.clone(),
            port: job.from_port,
            path: "/".into(),
        };
        return match g6b_http::outbound::redirect_hop(&from, loc) {
            Ok(next) => Progress::Failed(format!(
                "redirect: not followed {}://{}:{}{}",
                if next.https { "https" } else { "http" },
                next.host,
                next.port,
                next.path
            )),
            Err(e) => Progress::Failed(e),
        };
    }
    if resp.status != 200 {
        return Progress::Failed(format!(
            "HTTP {} from {} via=hw-tcp",
            resp.status, job.device
        ));
    }
    Progress::Done(resp.body)
}

/// Firmware sink. `stage` digests with the kernel's SHA-256 (`g6b-tls`) so the
/// operator can compare before committing; `commit` reports the backend the
/// BoardSpec named.
#[derive(Debug, Clone)]
pub struct KernelFlash {
    spec: BoardSpec,
    staged: Option<(String, String, usize)>,
}

impl KernelFlash {
    pub fn new(spec: &BoardSpec) -> Self {
        Self {
            spec: spec.clone(),
            staged: None,
        }
    }

    /// The staged `(image, sha256, bytes)`, if any.
    pub fn staged(&self) -> Option<&(String, String, usize)> {
        self.staged.as_ref()
    }
}

impl FlashPort for KernelFlash {
    fn stage(&mut self, image: &str, bytes: &[u8]) -> Result<String, String> {
        if !self.spec.kernel.flash.enable && !self.spec.kernel.usb.flash_fat32 {
            return Err("no flash backend compiled (kernel.flash / kernel.usb.flash_fat32)".into());
        }
        if image == "bios" && !self.spec.kernel.flash.self_update {
            return Err("kernel.flash.self_update is off; a BIOS self-update is refused".into());
        }
        let digest = g6b_tls::sha256_hex(bytes);
        self.staged = Some((image.to_string(), digest.clone(), bytes.len()));
        Ok(digest)
    }

    fn commit(&mut self, image: &str) -> Result<String, String> {
        let (staged, digest, len) = self
            .staged
            .clone()
            .ok_or_else(|| format!("nothing staged for {image}"))?;
        if staged != image {
            return Err(format!("staged image is {staged}, not {image}"));
        }
        Ok(format!(
            "FLASH-COMMIT {image} via={} bytes={len} sha256={digest}",
            self.spec.kernel.flash.backend
        ))
    }
}

/// The ports this board's compiled features justify. A capability that was
/// excluded is simply absent, and the CLI says so at the prompt.
pub fn ports(spec: &BoardSpec) -> Ports {
    let mut p = Ports::default();
    if spec.kernel.cli.fs && spec.kernel.usb.enable {
        p = p.with_volumes(KernelVolumes::new(spec));
    }
    if spec.kernel.hw.enable && spec.kernel.http.enable && spec.kernel.http.outbound {
        p = p.with_net(KernelNet::new(spec));
    }
    if spec.kernel.cli.fw && (spec.kernel.flash.enable || spec.kernel.usb.flash_fat32) {
        p = p.with_flash(KernelFlash::new(spec));
    }
    p
}

/// A CLI session wired to this board's adapters. This is the face that comes up
/// **before** the web engine on any build that carries both.
pub fn session(spec: &BoardSpec) -> ZealCli {
    ZealCli::with_ports(spec, ports(spec))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_image_volume_reads_the_filename_it_lists() {
        let dir = std::env::temp_dir().join(format!(
            "g6b-image-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&dir).unwrap();
        let image = dir.join("Image");
        let mut bytes = vec![0u8; 128];
        bytes[0x38..0x3c].copy_from_slice(b"RSC\x05");
        std::fs::write(&image, &bytes).unwrap();
        let volumes = DirVolumes::new().mount("LINUX", &image, "key", "test transport");
        let found = g6b_zealcli::detect::probe_port(&volumes, "LINUX");
        std::fs::remove_file(&image).unwrap();
        std::fs::remove_dir(&dir).unwrap();
        assert_eq!(found.medium, g6b_zealcli::Medium::Kernel);
    }

    use std::io::{Read, Write};
    use std::net::{Shutdown, TcpListener};

    fn spec(profile: &str) -> BoardSpec {
        BoardSpec::from_json_str(&format!(r#"{{"schema_version":1,"profile":"{profile}"}}"#))
            .unwrap()
    }

    /// One-shot HTTP server that answers with a Content-Length body.
    fn serve_once(body: Vec<u8>) -> (u16, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let head = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(head.as_bytes());
                let _ = stream.write_all(&body);
                let _ = stream.flush();
            }
        });
        (port, handle)
    }

    fn serve_redirect(location: &'static str) -> (u16, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let head = format!(
                    "HTTP/1.1 302 Found\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                );
                let _ = stream.write_all(head.as_bytes());
                let _ = stream.flush();
            }
        });
        (port, handle)
    }

    #[test]
    fn barebone_ports_are_volumes_net_and_flash() {
        let s = spec("barebone");
        let p = ports(&s);
        let dbg = format!("{p:?}");
        assert!(dbg.contains("volumes: true"), "{dbg}");
        assert!(dbg.contains("net: true"), "{dbg}");
        assert!(dbg.contains("flash: true"), "{dbg}");
        // Turning a capability off removes the port instead of faking it.
        let no_fw = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","kernel":{"cli":{"fw":false,"fs":false}}}"#,
        )
        .unwrap();
        let dbg = format!("{:?}", ports(&no_fw));
        assert!(
            dbg.contains("volumes: false") && dbg.contains("flash: false"),
            "{dbg}"
        );
    }

    #[test]
    fn kernel_volumes_come_from_the_compiled_board() {
        let s = spec("barebone");
        let v = KernelVolumes::new(&s);
        let vols = v.volumes();
        assert!(vols.iter().any(|v| v.role == "flash"), "{vols:?}");
        assert!(vols.iter().any(|v| v.role == "key"), "{vols:?}");
        let flash = vols.iter().find(|v| v.role == "flash").unwrap();
        let imgs = v.list(&flash.id, "/").unwrap();
        assert!(imgs.iter().any(|e| e.name == "g6lc_bios.elf"), "{imgs:?}");
        let elf = v.read(&flash.id, "/g6lc_bios.elf").unwrap();
        assert!(elf.starts_with(b"\x7fELF"));
        assert!(v.read(&flash.id, "/nope.elf").is_err());
        assert!(v.list("GHOST", "/").is_err());
    }

    #[test]
    fn https_and_usb_are_the_two_firmware_paths_in_the_cli() {
        let s = spec("barebone");
        let mut cli = session(&s);
        assert!(cli.eval("net").1.contains("HW-NET"), "adapter status");
        let drv = cli.eval("drv").1;
        assert!(drv.contains("FLASH:"), "{drv}");
        // The USB image path runs end to end through the kernel ports.
        let out = cli.eval("fw update FLASH:/g6lc_bios.elf").1;
        assert!(out.contains("fw "), "{out}");
        let run = cli.eval("fw run").1;
        assert!(run.contains("fw ready"), "{run}");
        assert!(
            run.contains("sha256="),
            "the kernel digests what it staged: {run}"
        );
        let applied = cli.eval("fw apply").1;
        assert!(
            applied.contains("FLASH-COMMIT bios via=spi-nor"),
            "{applied}"
        );
        // Plain HTTP for firmware is refused before a socket is opened.
        assert!(cli
            .eval("fw update http://example/x.elf")
            .1
            .contains("refusing plain HTTP"));
    }

    #[test]
    fn outbound_get_polls_a_real_socket_without_a_thread() {
        let body = vec![0x5au8; 4096];
        let (port, th) = serve_once(body.clone());
        let mut net = KernelNet::new(&spec("barebone"));
        let handle = net
            .get(&format!("http://127.0.0.1:{port}/fw.bin"))
            .expect("connect");
        let mut pending = 0;
        let got = loop {
            match net.poll(handle) {
                Progress::Pending { .. } => {
                    pending += 1;
                    assert!(pending < 5_000_000, "poll must converge");
                }
                Progress::Done(b) => break b,
                Progress::Failed(e) => panic!("fetch failed: {e}"),
            }
        };
        assert!(pending > 0, "a real socket is not ready on the first poll");
        assert_eq!(got, body);
        assert!(net.status().contains("nat=isolated"), "{}", net.status());
        net.cancel(handle);
        let _ = th.join();
    }

    #[test]
    fn outbound_get_nat_gateway_uses_packets_not_host_sockets() {
        let mut net = KernelNet::new(&spec("barebone"));
        let handle = net.get("http://10.0.2.2/fw.bin").expect("nat get");
        let mut pending = 0;
        let got = loop {
            match net.poll(handle) {
                Progress::Pending { .. } => {
                    pending += 1;
                    assert!(pending < 8, "packet peer completes without a socket wait");
                }
                Progress::Done(b) => break b,
                Progress::Failed(e) => panic!("nat fetch failed: {e}"),
            }
        };
        assert_eq!(got, g6b_hw::NAT_HTTP_BODY);
        net.cancel(handle);
    }

    fn spec_pkt() -> BoardSpec {
        BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","kernel":{"hw":{"enable":true,"virtio_net":false,"ethernet":true}}}"#,
        )
        .unwrap()
    }

    #[test]
    fn outbound_nat_cancel_before_poll_never_sends_get() {
        let mut net = KernelNet::new(&spec("barebone"));
        let handle = net.get("http://10.0.2.2/fw.bin").expect("armed");
        assert!(net.status().contains("jobs=1"), "{}", net.status());
        assert!(net.status().contains("wdt=0"), "{}", net.status());
        net.cancel(handle);
        assert!(net.status().contains("jobs=0"), "{}", net.status());
        match net.poll(handle) {
            Progress::Failed(_) => {}
            other => panic!("cancelled before poll must not complete: {other:?}"),
        }
    }

    #[test]
    fn outbound_nat_cancel_after_syn_never_completes() {
        let mut net = KernelNet::new(&spec_pkt());
        let handle = net.get("http://10.0.2.2/fw.bin").expect("armed");
        match net.poll(handle) {
            Progress::Pending { .. } => {}
            other => panic!("SYN step is pending: {other:?}"),
        }
        assert!(net.status().contains("wdt=1"), "{}", net.status());
        net.cancel(handle);
        match net.poll(handle) {
            Progress::Failed(_) => {}
            Progress::Done(_) => panic!("cancelled after SYN must not GET"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn outbound_nat_watchdog_stops_fetch_before_packet() {
        let mut net = KernelNet::new(&spec_pkt());
        let handle = net.get("http://10.0.2.2/fw.bin").expect("armed");
        net.hold_watchdog();
        match net.poll(handle) {
            Progress::Failed(e) => assert!(e.contains("watchdog"), "{e}"),
            other => panic!("watchdog must run before packet: {other:?}"),
        }
        assert!(net.status().contains("wdt=1"), "{}", net.status());
    }

    #[test]
    fn outbound_nat_cancel_does_not_drop_neighbour() {
        let mut net = KernelNet::new(&spec_pkt());
        let a = net.get("http://10.0.2.2/fw.bin").expect("a");
        let b = net.get("http://10.0.2.2/fw.bin").expect("b");
        net.cancel(a);
        let mut pending = 0;
        let got = loop {
            match net.poll(b) {
                Progress::Pending { .. } => {
                    pending += 1;
                    assert!(pending < 8);
                }
                Progress::Done(body) => break body,
                Progress::Failed(e) => panic!("neighbour failed: {e}"),
            }
        };
        assert_eq!(got, g6b_hw::NAT_HTTP_BODY);
    }

    #[test]
    fn outbound_nat_link_down_after_syn_never_completes() {
        let mut net = KernelNet::new(&spec_pkt());
        let handle = net.get("http://10.0.2.2/fw.bin").expect("armed");
        match net.poll(handle) {
            Progress::Pending { .. } => {}
            other => panic!("SYN step is pending: {other:?}"),
        }
        net.drop_link();
        match net.poll(handle) {
            Progress::Failed(e) => assert!(e.contains("link down"), "{e}"),
            Progress::Done(_) => panic!("link down after SYN must not GET"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn outbound_nat_unplug_before_poll_never_sends_get() {
        let mut net = KernelNet::new(&spec_pkt());
        let handle = net.get("http://10.0.2.2/fw.bin").expect("armed");
        net.unplug();
        match net.poll(handle) {
            Progress::Failed(e) => assert!(e.contains("link down"), "{e}"),
            other => panic!("unplug must complete the job: {other:?}"),
        }
    }

    #[test]
    fn outbound_get_link_down_completes_without_stall() {
        let body = b"G6LC".to_vec();
        let (tx, rx) = std::sync::mpsc::channel();
        let (port, th) = serve_close_delimited(body, rx);
        let mut net = KernelNet::new(&spec("barebone"));
        let handle = net
            .get(&format!("http://127.0.0.1:{port}/fw.bin"))
            .expect("connect");
        let mut pending = 0;
        loop {
            match net.poll(handle) {
                Progress::Pending { .. } => {
                    pending += 1;
                    if pending > 8 {
                        break;
                    }
                }
                Progress::Done(_) => panic!("must not finish before link down"),
                Progress::Failed(e) => panic!("fetch failed before link down: {e}"),
            }
        }
        net.drop_link();
        match net.poll(handle) {
            Progress::Failed(e) => assert!(e.contains("link down"), "{e}"),
            other => panic!("link down must not wait for stall: {other:?}"),
        }
        let _ = tx.send(());
        let _ = th.join();
    }

    #[test]
    fn outbound_get_arms_without_connect() {
        let mut net = KernelNet::new(&spec("barebone"));
        let t0 = std::time::Instant::now();
        let handle = net
            .get("http://127.0.0.1:1/fw.bin")
            .expect("get must not wait for connect");
        assert!(
            t0.elapsed() < std::time::Duration::from_millis(500),
            "get blocked on connect: {:?}",
            t0.elapsed()
        );
        assert!(net.status().contains("jobs=1"), "{}", net.status());
        match net.poll(handle) {
            Progress::Pending { .. } | Progress::Failed(_) => {}
            Progress::Done(_) => panic!("nothing listening on :1"),
        }
    }

    #[test]
    fn outbound_get_hostname_needs_async_dns() {
        let mut net = KernelNet::new(&spec("barebone"));
        let handle = net
            .get("http://g6lc.invalid/fw.bin")
            .expect("get must not block on DNS");
        match net.poll(handle) {
            Progress::Failed(e) => assert!(e.contains("dns"), "{e}"),
            other => panic!("hostname is not an IPv4 literal: {other:?}"),
        }
    }

    #[test]
    fn outbound_get_g6lc_uses_nat_dns_not_os() {
        let mut net = KernelNet::new(&spec_pkt());
        let handle = net.get("http://g6lc/fw.bin").expect("armed");
        match net.poll(handle) {
            Progress::Pending { .. } => {}
            other => panic!("DNS step is pending: {other:?}"),
        }
        let mut pending = 1;
        let got = loop {
            match net.poll(handle) {
                Progress::Pending { .. } => {
                    pending += 1;
                    assert!(pending < 8);
                }
                Progress::Done(body) => break body,
                Progress::Failed(e) => panic!("nat dns fetch failed: {e}"),
            }
        };
        assert_eq!(got, g6b_hw::NAT_HTTP_BODY);
    }

    #[test]
    fn outbound_get_g6lc_cancel_before_dns_never_gets() {
        let mut net = KernelNet::new(&spec_pkt());
        let handle = net.get("http://g6lc/fw.bin").expect("armed");
        net.cancel(handle);
        match net.poll(handle) {
            Progress::Failed(_) => {}
            other => panic!("cancelled DNS job must not GET: {other:?}"),
        }
    }

    #[test]
    fn outbound_get_g6lc_refuses_nameserver_as_origin() {
        let mut net = KernelNet::new(&spec_pkt());
        let handle = net.get("http://g6lc/fw.bin").expect("armed");
        match net.poll(handle) {
            Progress::Pending { .. } => {}
            other => panic!("DNS step is pending: {other:?}"),
        }
        net.force_dst(handle, [10, 0, 2, 3]);
        match net.poll(handle) {
            Progress::Failed(e) => assert!(e.contains("origin"), "{e}"),
            Progress::Done(_) => panic!("nameserver is not an HTTP origin"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn outbound_nat_job_budget_and_stale_generation() {
        let mut net = KernelNet::new(&spec_pkt());
        let mut hs = Vec::new();
        for _ in 0..4 {
            hs.push(net.get("http://10.0.2.2/fw.bin").expect("slot"));
        }
        assert!(
            net.get("http://10.0.2.2/fw.bin")
                .unwrap_err()
                .contains("budget"),
            "four in-flight jobs"
        );
        net.cancel(hs[0]);
        let n = net.get("http://10.0.2.2/fw.bin").expect("reuse");
        match net.poll(hs[0]) {
            Progress::Failed(e) => assert!(e.contains("stale"), "{e}"),
            other => panic!("cancelled generation must not complete: {other:?}"),
        }
        match net.poll(n) {
            Progress::Pending { .. } => {}
            other => panic!("new generation is live: {other:?}"),
        }
    }

    #[test]
    fn outbound_get_redirect_origin_mismatch_is_not_followed() {
        let (port, th) = serve_redirect("http://evil.example/x");
        let mut net = KernelNet::new(&spec("barebone"));
        let handle = net
            .get(&format!("http://127.0.0.1:{port}/fw.bin"))
            .expect("armed");
        let mut steps = 0;
        loop {
            match net.poll(handle) {
                Progress::Pending { .. } => {
                    steps += 1;
                    assert!(steps < 5_000_000);
                }
                Progress::Failed(e) => {
                    assert!(e.contains("origin"), "{e}");
                    break;
                }
                Progress::Done(_) => panic!("cross-origin redirect must not complete"),
            }
        }
        let _ = th.join();
    }

    #[test]
    fn outbound_get_same_origin_redirect_is_not_followed() {
        let (port, th) = serve_redirect("/other.bin");
        let mut net = KernelNet::new(&spec("barebone"));
        let handle = net
            .get(&format!("http://127.0.0.1:{port}/fw.bin"))
            .expect("armed");
        let mut steps = 0;
        loop {
            match net.poll(handle) {
                Progress::Pending { .. } => {
                    steps += 1;
                    assert!(steps < 5_000_000);
                }
                Progress::Failed(e) => {
                    assert!(e.contains("not followed"), "{e}");
                    break;
                }
                Progress::Done(_) => panic!("redirect must not auto-follow"),
            }
        }
        let _ = th.join();
    }

    fn serve_once_chunked(body: Vec<u8>) -> (u16, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let mut wire = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/octet-stream\r\n\r\n".to_vec();
                wire.extend_from_slice(format!("{:x}\r\n", body.len()).as_bytes());
                wire.extend_from_slice(&body);
                wire.extend_from_slice(b"\r\n0\r\n\r\n");
                let _ = stream.write_all(&wire);
                let _ = stream.flush();
            }
        });
        (port, handle)
    }

    #[test]
    fn outbound_get_finishes_chunked_without_idle_eof() {
        let body = vec![0x00, 0xff, 0xfe, 0x80];
        let (port, th) = serve_once_chunked(body.clone());
        let mut net = KernelNet::new(&spec("barebone"));
        let handle = net
            .get(&format!("http://127.0.0.1:{port}/fw.bin"))
            .expect("connect");
        let mut pending = 0;
        let got = loop {
            match net.poll(handle) {
                Progress::Pending { .. } => {
                    pending += 1;
                    assert!(pending < 5_000_000, "poll must converge");
                }
                Progress::Done(b) => break b,
                Progress::Failed(e) => panic!("fetch failed: {e}"),
            }
        };
        assert_eq!(got, body);
        net.cancel(handle);
        let _ = th.join();
    }

    fn serve_close_delimited(
        body: Vec<u8>,
        release: std::sync::mpsc::Receiver<()>,
    ) -> (u16, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let head = b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n";
                let _ = stream.write_all(head);
                let _ = stream.write_all(&body);
                let _ = stream.flush();
                let _ = release.recv();
                let _ = stream.shutdown(Shutdown::Write);
            }
        });
        (port, handle)
    }

    #[test]
    fn outbound_get_close_delimited_waits_for_peer_eof_not_idle() {
        let body = b"G6LC".to_vec();
        let (tx, rx) = std::sync::mpsc::channel();
        let (port, th) = serve_close_delimited(body.clone(), rx);
        let mut net = KernelNet::new(&spec("barebone"));
        let handle = net
            .get(&format!("http://127.0.0.1:{port}/fw.bin"))
            .expect("connect");
        let mut pending = 0;
        loop {
            match net.poll(handle) {
                Progress::Pending { done, .. } if done > 0 => break,
                Progress::Pending { .. } => {
                    pending += 1;
                    assert!(pending < 5_000_000, "headers must arrive");
                }
                Progress::Done(_) => panic!("close-delimited must not finish before EOF"),
                Progress::Failed(e) => panic!("fetch failed: {e}"),
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
        match net.poll(handle) {
            Progress::Pending { .. } => {}
            Progress::Done(_) => panic!("500ms idle is not peer close"),
            Progress::Failed(e) => panic!("fetch failed during idle: {e}"),
        }
        tx.send(()).unwrap();
        let mut after = 0;
        let got = loop {
            match net.poll(handle) {
                Progress::Pending { .. } => {
                    after += 1;
                    assert!(after < 5_000_000, "EOF must complete the body");
                }
                Progress::Done(b) => break b,
                Progress::Failed(e) => panic!("fetch failed after EOF: {e}"),
            }
        };
        assert_eq!(got, body);
        net.cancel(handle);
        let _ = th.join();
    }

    #[test]
    fn https_reports_the_handshake_instead_of_faking_crypto() {
        // A server that answers with a TLS handshake record header.
        let (port, th) = serve_once(Vec::new());
        let mut net = KernelNet::new(&spec("barebone"));
        net.use_test_entropy();
        let handle = net
            .get(&format!("https://127.0.0.1:{port}/fw.elf"))
            .unwrap();
        let mut steps = 0;
        loop {
            match net.poll(handle) {
                Progress::Pending { .. } => {
                    steps += 1;
                    assert!(steps < 5_000_000);
                }
                Progress::Done(_) => panic!("the client record layer is not implemented"),
                Progress::Failed(e) => {
                    assert!(e.contains("https via=hw-tcp"), "{e}");
                    assert!(e.contains("B54"), "{e}");
                    assert!(!e.to_ascii_lowercase().contains("openssl"), "{e}");
                    break;
                }
            }
        }
        let _ = th.join();
    }

    #[test]
    fn outbound_https_reuses_psk_ticket() {
        let mut net = KernelNet::new(&spec("barebone"));
        net.use_test_entropy();
        let rm = [0x5au8; 32];
        let t = g6b_tls::issue_ticket("127.0.0.1", &rm, &[0, 0], b"t1", &[9u8; 32]).unwrap();
        net.remember_ticket(t);
        let handle = net.get("https://127.0.0.1/fw.elf").expect("armed");
        let hello = net.job(handle).and_then(|j| j.tx.clone()).expect("hello");
        assert!(
            hello.windows(2).any(|w| w == [0x00, 0x29]),
            "resumed ClientHello carries pre_shared_key"
        );
        assert!(
            !hello.windows(2).any(|w| w == [0x00, 0x2a]),
            "0-RTT still refused"
        );
        let handle2 = net.get("https://127.0.0.1/fw.elf").expect("second");
        let hello2 = net.job(handle2).and_then(|j| j.tx.clone()).expect("hello2");
        assert!(hello2.windows(2).any(|w| w == [0x00, 0x29]));
        let mut nst = vec![0x04, 0x00, 0x00, 0x11];
        nst.extend_from_slice(&0x1eu32.to_be_bytes());
        nst.extend_from_slice(&0u32.to_be_bytes());
        nst.push(2);
        nst.extend_from_slice(&[0, 0]);
        nst.extend_from_slice(&[0, 2, 0xcc, 0xdd]);
        nst.extend_from_slice(&[0, 0]);
        net.install_server_ticket("10.0.2.2", &nst, &[0x5au8; 32], &[9u8; 32])
            .unwrap();
        let h3 = net.get("https://10.0.2.2/fw.elf").expect("nst host");
        let hello3 = net.job(h3).and_then(|j| j.tx.clone()).expect("hello3");
        assert!(hello3.windows(2).any(|w| w == [0x00, 0x29]));
    }

    #[test]
    fn outbound_https_without_entropy_fails_closed() {
        let mut net = KernelNet::new(&spec("barebone"));
        let err = net.get("https://127.0.0.1/fw.elf").unwrap_err();
        assert!(err.contains("entropy"), "{err}");
    }

    #[test]
    fn flash_refuses_a_self_update_that_was_not_compiled() {
        let no_self = BoardSpec::from_json_str(
            r#"{"schema_version":1,"profile":"barebone","kernel":{"flash":{"enable":true,"self_update":false}}}"#,
        )
        .unwrap();
        let mut f = KernelFlash::new(&no_self);
        let err = f.stage("bios", &[0u8; 2048]).unwrap_err();
        assert!(err.contains("self_update"), "{err}");
        assert!(f.commit("bios").is_err());
        let mut ok = KernelFlash::new(&spec("barebone"));
        let digest = ok.stage("bios", b"\x7fELF").unwrap();
        assert_eq!(digest.len(), 64, "sha256 hex");
        assert!(ok
            .commit("openwrt")
            .unwrap_err()
            .contains("staged image is bios"));
        assert!(ok.commit("bios").unwrap().contains(&digest));
    }

    #[test]
    fn virtio_rng_entropy_and_empty_trust_fail_closed() {
        let mut net = KernelNet::new(&spec("barebone"));
        assert!(net
            .get("https://127.0.0.1/fw.elf")
            .unwrap_err()
            .contains("entropy"));
        net.use_virtio_rng(vec![]);
        assert!(net
            .get("https://localhost/fw.elf")
            .unwrap_err()
            .contains("virtio-rng"));
        net.use_virtio_rng((0u8..64).collect());
        assert!(net.get("https://localhost/fw.elf").is_ok());
        let pem = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../kernel-spec/botan/test_data/tls_13_rfc8448/server_certificate.pem"
        ));
        assert!(net
            .verify_https_peer(
                "rsa",
                pem.as_bytes(),
                &g6b_tls::FixtureClock {
                    unix: 1_483_228_800
                }
            )
            .unwrap_err()
            .contains("trust"));
        let mut store = CertStore::default();
        store
            .add_root(g6b_tls::parse_cert(pem.as_bytes()).unwrap())
            .unwrap();
        net.attach_trust(store);
        net.verify_https_peer(
            "rsa",
            pem.as_bytes(),
            &g6b_tls::FixtureClock {
                unix: 1_483_228_800,
            },
        )
        .unwrap();
        assert!(net
            .verify_https_peer(
                "server",
                pem.as_bytes(),
                &g6b_tls::FixtureClock {
                    unix: 1_483_228_800
                }
            )
            .unwrap_err()
            .contains("name"));
        assert!(KernelNet::ocsp_http_plan("https://10.0.2.2/ocsp", &[2])
            .unwrap_err()
            .contains("chicken-egg"));
        assert!(KernelNet::ocsp_http_plan("http://example.com/ocsp", &[2])
            .unwrap_err()
            .contains("isolated"));
        let post = KernelNet::ocsp_http_plan("http://10.0.2.2/ocsp", &[2]).unwrap();
        assert!(post.starts_with(b"POST /ocsp HTTP/1.1"));
        let mut whitened = KernelNet::new(&spec("barebone"));
        let seed: Vec<u8> = (0u8..32).collect();
        whitened.use_virtio_rng_extracted(&seed).unwrap();
        assert!(whitened.get("https://localhost/fw.elf").is_ok());
    }
}
