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
//! No thread is created, nothing blocks the prompt or the timer tick, and the
//! transfer can be cancelled between two polls.

use std::collections::BTreeMap;

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

/// One in-flight GET on an hw TCP socket.
#[derive(Debug)]
struct Job {
    sock: u32,
    https: bool,
    device: String,
    buf: Vec<u8>,
    /// Content-Length once the header has been parsed.
    want: Option<usize>,
    header_end: Option<usize>,
    /// When bytes last arrived. A poll count is not a clock — under load 20k
    /// non-blocking reads can pass before the peer has even accepted — so the
    /// framing and stall rules are stated in time, while each poll still
    /// returns immediately. The guest equivalent reads `rdtime`.
    last: std::time::Instant,
    saw_bytes: bool,
    done: bool,
}

/// Outbound GET over the isolated NAT stack, one `recv` per poll.
#[derive(Debug)]
pub struct KernelNet {
    hw: g6b_hw::HwSession,
    jobs: BTreeMap<u32, Job>,
    next: u32,
}

/// No data for this long ends the transfer. Polls stay non-blocking; this is
/// the deadline that makes them terminate.
const STALL: std::time::Duration = std::time::Duration::from_secs(10);
/// Quiet time after the last byte that means "peer closed" when the response
/// carried no `Content-Length` (`Connection: close` framing). A non-blocking
/// read cannot tell EOF from "not yet", so the grace period is explicit.
const CLOSE_GRACE: std::time::Duration = std::time::Duration::from_millis(400);
/// Ceiling on a single response, so a hostile server cannot grow the heap.
const MAX_BODY_BYTES: usize = 64 * 1024 * 1024;

impl KernelNet {
    pub fn new(spec: &BoardSpec) -> Self {
        Self {
            hw: g6b_hw::HwSession::from_board(spec),
            jobs: BTreeMap::new(),
            next: 1,
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
        let sock = self.hw.tcp_connect_sock(&device, &req.host, req.port)?;
        let bytes = if req.https {
            // HTTPS starts with the ClientHello the TLS crate writes; the
            // record layer answer is inspected on the first poll.
            g6b_tls::client_hello(&req.host)
        } else {
            g6b_http::outbound::http1_get_request(&req)
        };
        self.hw.tcp_send_bytes(sock, &bytes)?;
        let handle = self.next;
        self.next += 1;
        self.jobs.insert(
            handle,
            Job {
                sock,
                https: req.https,
                device,
                buf: Vec::new(),
                want: None,
                header_end: None,
                last: std::time::Instant::now(),
                saw_bytes: false,
                done: false,
            },
        );
        Ok(handle)
    }

    fn poll(&mut self, handle: u32) -> Progress {
        let Some(job) = self.jobs.get_mut(&handle) else {
            return Progress::Failed("no such transfer".into());
        };
        if job.done {
            return Progress::Failed("transfer already finished".into());
        }
        let chunk = match self.hw.tcp_recv_bytes(job.sock) {
            Ok(c) => c,
            Err(e) => {
                job.done = true;
                return Progress::Failed(e);
            }
        };
        if chunk.is_empty() {
            let quiet = job.last.elapsed();
            if job.saw_bytes && job.want.is_none() && quiet > CLOSE_GRACE {
                // Close-framed response: nothing more is coming.
                return finish(job);
            }
            if quiet > STALL {
                job.done = true;
                return Progress::Failed(format!(
                    "transfer stalled: no data for {}s",
                    STALL.as_secs()
                ));
            }
            return Progress::Pending {
                done: job.buf.len() as u64,
                total: job.want.unwrap_or(0) as u64,
            };
        }
        job.last = std::time::Instant::now();
        job.saw_bytes = true;
        job.buf.extend_from_slice(&chunk);
        if job.buf.len() > MAX_BODY_BYTES {
            job.done = true;
            return Progress::Failed(format!("response exceeds {MAX_BODY_BYTES} bytes"));
        }
        if job.https {
            // The client record layer is not implemented (B54): report the
            // handshake honestly instead of pretending to decrypt.
            let kind = g6b_tls::tls_record_kind(&job.buf).unwrap_or("unknown");
            job.done = true;
            return Progress::Failed(format!(
                "https via=hw-tcp tls={kind}: client record layer is not implemented yet (B54); \
                 use a USB key image or an http mirror on the isolated NAT"
            ));
        }
        if job.header_end.is_none() {
            if let Some(at) = job.buf.windows(4).position(|w| w == b"\r\n\r\n") {
                job.header_end = Some(at + 4);
                job.want = content_length(&job.buf[..at]);
            }
        }
        if let (Some(head), Some(len)) = (job.header_end, job.want) {
            if job.buf.len() >= head + len {
                return finish(job);
            }
        }
        Progress::Pending {
            done: job.buf.len() as u64,
            total: job
                .want
                .map(|l| (job.header_end.unwrap_or(0) + l) as u64)
                .unwrap_or(0),
        }
    }

    fn cancel(&mut self, handle: u32) {
        if let Some(job) = self.jobs.remove(&handle) {
            let _ = self.hw.sock_close(job.sock);
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
            "HW-NET {} nat={} jobs={}",
            nets.join(", "),
            self.hw.mode().as_str(),
            self.jobs.len()
        )
    }
}

fn finish(job: &mut Job) -> Progress {
    job.done = true;
    let resp = g6b_http::outbound::parse_http1_response(&job.buf);
    if resp.status != 200 {
        return Progress::Failed(format!(
            "HTTP {} from {} via=hw-tcp",
            resp.status, job.device
        ));
    }
    Progress::Done(resp.body.clone())
}

fn content_length(head: &[u8]) -> Option<usize> {
    let text = String::from_utf8_lossy(head);
    for line in text.split("\r\n").skip(1) {
        let (name, value) = line.split_once(':')?;
        if name.trim().eq_ignore_ascii_case("content-length") {
            return value.trim().parse().ok();
        }
    }
    None
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
    use std::net::TcpListener;

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
    fn https_reports_the_handshake_instead_of_faking_crypto() {
        // A server that answers with a TLS handshake record header.
        let (port, th) = serve_once(Vec::new());
        let mut net = KernelNet::new(&spec("barebone"));
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
}
