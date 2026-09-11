// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Firmware update: HTTPS remote or USB key, **without a worker thread**.
//!
//! A BIOS has no scheduler to hide a blocking download behind, and a firmware
//! transfer must not freeze the prompt or the timer tick. So the update is an
//! explicit state machine that the shell steps: `start` arms the source, `poll`
//! performs one bounded step and returns immediately, and `apply` commits only
//! after the bytes have been shape-checked and staged. Every phase is visible
//! to the operator, and every refusal is a phase — never a silent retry.
//!
//! `Phase::Verify` checks what a BIOS can honestly check on its own: the image
//! magic and the size envelope. The cryptographic digest comes back from
//! [`FlashPort::stage`], because the record layer and hash live in the kernel
//! (`g6b-tls`), not in the CLI.

use crate::ports::{FlashPort, Ports, Progress, VolumePort};

/// Where the image comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// `https://…` — TLS only. Plain HTTP is refused for firmware.
    Https(String),
    /// `DRIVE:/path` on a mounted volume (USB key).
    Volume { volume: String, path: String },
}

impl Source {
    /// Parse `https://…` or `DRIVE:/path`. Plain `http://` is refused here, not
    /// downstream, so an operator cannot fetch firmware over a clear channel.
    pub fn parse(arg: &str) -> Result<Self, String> {
        let arg = arg.trim();
        if arg.is_empty() {
            return Err("fw: expected https://… or DRIVE:/path".into());
        }
        if let Some(rest) = arg.strip_prefix("http://") {
            return Err(format!(
                "fw: refusing plain HTTP for firmware ({rest}); use https://"
            ));
        }
        if arg.starts_with("https://") {
            return Ok(Self::Https(arg.to_string()));
        }
        match arg.split_once(':') {
            Some((vol, path)) if !vol.is_empty() => Ok(Self::Volume {
                volume: vol.to_string(),
                path: if path.is_empty() {
                    "/".into()
                } else {
                    path.into()
                },
            }),
            _ => Err(format!("fw: `{arg}` is neither https:// nor DRIVE:/path")),
        }
    }

    pub fn describe(&self) -> String {
        match self {
            Self::Https(url) => url.clone(),
            Self::Volume { volume, path } => format!("{volume}:{path}"),
        }
    }
}

/// Where the transfer is. `Fetch` is the only phase that repeats.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Fetch,
    Verify,
    Stage,
    /// Staged and digested; waiting for an explicit `fw apply`.
    Ready,
    Applied,
    Failed,
    Cancelled,
}

impl Phase {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Fetch => "fetch",
            Self::Verify => "verify",
            Self::Stage => "stage",
            Self::Ready => "ready",
            Self::Applied => "applied",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }

    pub fn done(self) -> bool {
        matches!(
            self,
            Self::Ready | Self::Applied | Self::Failed | Self::Cancelled
        )
    }
}

/// Smallest / largest firmware image the BIOS will accept. An ELF payload
/// under 1 KiB is a truncated download, and a multi-hundred-MiB body is not a
/// firmware image — both are refused before anything is staged.
pub const MIN_IMAGE_BYTES: usize = 1024;
pub const MAX_IMAGE_BYTES: usize = 64 * 1024 * 1024;

/// One in-flight update. Bounded, poll-driven, cancellable.
#[derive(Debug)]
pub struct Update {
    source: Source,
    image: String,
    phase: Phase,
    handle: Option<u32>,
    bytes: Vec<u8>,
    done: u64,
    total: u64,
    digest: String,
    polls: u32,
    log: Vec<String>,
}

/// Polls a single update may take before it fails closed. At one poll per key
/// or timer tick this is a generous ceiling, and it guarantees termination.
pub const MAX_POLLS: u32 = 100_000;

impl Update {
    /// Arm a transfer. HTTPS needs a [`NetPort`]; a volume source is read in
    /// one step (the key is local) and lands straight in `Verify`.
    pub fn start(source: Source, image: &str, ports: &mut Ports) -> Result<Self, String> {
        let mut up = Self {
            source: source.clone(),
            image: image.to_string(),
            phase: Phase::Fetch,
            handle: None,
            bytes: Vec::new(),
            done: 0,
            total: 0,
            digest: String::new(),
            polls: 0,
            log: Vec::new(),
        };
        match &source {
            Source::Https(url) => {
                let net = ports
                    .net
                    .as_mut()
                    .ok_or("fw: no network adapter compiled (kernel.hw / http.outbound)")?;
                let h = net.get(url)?;
                up.handle = Some(h);
                up.note(&format!("FW-FETCH https {url}"));
            }
            Source::Volume { volume, path } => {
                let vp = ports
                    .volumes
                    .as_ref()
                    .ok_or("fw: no volumes compiled (kernel.usb / cli.fs)")?;
                let bytes = read_volume(vp.as_ref(), volume, path)?;
                up.total = bytes.len() as u64;
                up.done = up.total;
                up.bytes = bytes;
                up.phase = Phase::Verify;
                up.note(&format!("FW-FETCH usb {volume}:{path} {} bytes", up.total));
            }
        }
        Ok(up)
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    pub fn source(&self) -> &Source {
        &self.source
    }

    pub fn digest(&self) -> &str {
        &self.digest
    }

    pub fn log(&self) -> &[String] {
        &self.log
    }

    pub fn bytes(&self) -> usize {
        self.bytes.len()
    }

    /// One bounded step. Returns immediately in every phase — this is what
    /// keeps the prompt live without a thread.
    pub fn poll(&mut self, ports: &mut Ports) -> Phase {
        if self.phase.done() {
            return self.phase;
        }
        self.polls += 1;
        if self.polls > MAX_POLLS {
            return self.fail("fw: poll budget exhausted");
        }
        match self.phase {
            Phase::Fetch => self.poll_fetch(ports),
            Phase::Verify => self.verify(),
            Phase::Stage => self.stage(ports),
            _ => self.phase,
        }
    }

    fn poll_fetch(&mut self, ports: &mut Ports) -> Phase {
        let Some(handle) = self.handle else {
            return self.fail("fw: no transfer handle");
        };
        let Some(net) = ports.net.as_mut() else {
            return self.fail("fw: network adapter went away");
        };
        match net.poll(handle) {
            Progress::Pending { done, total } => {
                self.done = done;
                self.total = total;
                Phase::Fetch
            }
            Progress::Done(body) => {
                self.total = body.len() as u64;
                self.done = self.total;
                self.bytes = body;
                self.note(&format!("FW-FETCH-OK {} bytes", self.total));
                self.phase = Phase::Verify;
                self.phase
            }
            Progress::Failed(e) => self.fail(&format!("fw: fetch failed: {e}")),
        }
    }

    /// Shape check only: what the BIOS itself can prove about the bytes.
    fn verify(&mut self) -> Phase {
        let n = self.bytes.len();
        if n < MIN_IMAGE_BYTES {
            return self.fail(&format!("fw: image is {n} bytes, under {MIN_IMAGE_BYTES}"));
        }
        if n > MAX_IMAGE_BYTES {
            return self.fail(&format!("fw: image is {n} bytes, over {MAX_IMAGE_BYTES}"));
        }
        let kind = image_kind(&self.bytes);
        if self.image == "bios" && kind != "elf" {
            return self.fail("fw: a BIOS self-update must be a RISC-V ELF (\\x7fELF)");
        }
        self.note(&format!("FW-VERIFY {kind} {n} bytes"));
        self.phase = Phase::Stage;
        self.phase
    }

    fn stage(&mut self, ports: &mut Ports) -> Phase {
        let Some(flash) = ports.flash.as_mut() else {
            return self.fail("fw: no flash backend compiled (kernel.flash / usb.flash_fat32)");
        };
        match flash.stage(&self.image, &self.bytes) {
            Ok(digest) => {
                self.digest = digest;
                self.note(&format!("FW-STAGE {} sha256={}", self.image, self.digest));
                self.phase = Phase::Ready;
                self.phase
            }
            Err(e) => self.fail(&format!("fw: stage refused: {e}")),
        }
    }

    /// Commit the staged image. Only legal from [`Phase::Ready`] — a fetch in
    /// flight is never applied.
    pub fn apply(&mut self, ports: &mut Ports) -> Result<String, String> {
        if self.phase != Phase::Ready {
            return Err(format!(
                "fw: not ready to apply (phase {})",
                self.phase.as_str()
            ));
        }
        let flash = ports
            .flash
            .as_mut()
            .ok_or("fw: no flash backend compiled")?;
        let out = flash.commit(&self.image)?;
        self.phase = Phase::Applied;
        self.note(&format!("FW-APPLY {out}"));
        Ok(out)
    }

    /// Drop an in-flight transfer. Idempotent.
    pub fn cancel(&mut self, ports: &mut Ports) {
        if let (Some(h), Some(net)) = (self.handle, ports.net.as_mut()) {
            net.cancel(h);
        }
        self.handle = None;
        if !self.phase.done() {
            self.phase = Phase::Cancelled;
            self.note("FW-CANCEL");
        }
    }

    /// One status line for the prompt and for `fw`.
    pub fn status(&self) -> String {
        let pct = if self.total > 0 {
            format!("{}%", (self.done.min(self.total) * 100 / self.total))
        } else {
            "--".into()
        };
        let mut s = format!(
            "fw {} {} {}/{} {}",
            self.phase.as_str(),
            self.source.describe(),
            self.done,
            self.total,
            pct
        );
        if !self.digest.is_empty() {
            s.push_str(&format!(" sha256={}", self.digest));
        }
        if self.phase == Phase::Ready {
            s.push_str("  (fw apply to commit)");
        }
        s
    }

    fn fail(&mut self, why: &str) -> Phase {
        self.phase = Phase::Failed;
        self.note(why);
        self.phase
    }

    fn note(&mut self, line: &str) {
        if self.log.len() < 64 {
            self.log.push(line.to_string());
        }
    }
}

fn read_volume(vp: &dyn VolumePort, volume: &str, path: &str) -> Result<Vec<u8>, String> {
    vp.read(volume, path)
}

/// Recognized firmware container by magic. Unknown magic is reported as
/// `unknown` and only accepted for non-BIOS images.
pub fn image_kind(bytes: &[u8]) -> &'static str {
    if bytes.starts_with(b"\x7fELF") {
        "elf"
    } else if bytes.starts_with(&[0x27, 0x05, 0x19, 0x56]) {
        // Linux/U-Boot uImage magic.
        "uimage"
    } else if bytes.starts_with(b"UBI#") {
        "ubi"
    } else if bytes.starts_with(b"hsqs") {
        "squashfs"
    } else {
        "unknown"
    }
}

/// Digest wrapper so callers can print a staged image the same way twice.
pub fn short_digest(digest: &str) -> String {
    digest.chars().take(16).collect()
}

/// A [`FlashPort`] that only stages in memory — the host stand-in and the
/// fixture the poll tests drive.
#[derive(Debug, Default)]
pub struct MemFlash {
    pub staged: Vec<(String, usize)>,
    pub committed: Vec<String>,
    /// Digest the kernel would have computed; set by the test/host.
    pub digest: String,
}

impl FlashPort for MemFlash {
    fn stage(&mut self, image: &str, bytes: &[u8]) -> Result<String, String> {
        self.staged.push((image.to_string(), bytes.len()));
        Ok(if self.digest.is_empty() {
            format!("{:016x}", bytes.len() as u64 * 0x9e37_79b9)
        } else {
            self.digest.clone()
        })
    }

    fn commit(&mut self, image: &str) -> Result<String, String> {
        if !self.staged.iter().any(|(i, _)| i == image) {
            return Err(format!("nothing staged for {image}"));
        }
        self.committed.push(image.to_string());
        Ok(format!("FLASH-COMMIT {image}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::{MemVolumes, NetPort};

    /// A [`NetPort`] that hands out the body over several polls — exactly the
    /// shape a real socket has, with no thread anywhere.
    #[derive(Debug)]
    struct StepNet {
        body: Vec<u8>,
        left: u32,
        opened: Vec<String>,
        cancelled: Vec<u32>,
        fail: Option<String>,
    }

    impl NetPort for StepNet {
        fn get(&mut self, url: &str) -> Result<u32, String> {
            if !url.starts_with("https://") {
                return Err("plain http refused".into());
            }
            self.opened.push(url.to_string());
            Ok(7)
        }

        fn poll(&mut self, handle: u32) -> Progress {
            assert_eq!(handle, 7);
            if let Some(e) = &self.fail {
                return Progress::Failed(e.clone());
            }
            if self.left > 0 {
                self.left -= 1;
                let total = self.body.len() as u64;
                return Progress::Pending {
                    done: total.saturating_sub(u64::from(self.left) * total / 4),
                    total,
                };
            }
            Progress::Done(self.body.clone())
        }

        fn cancel(&mut self, handle: u32) {
            self.cancelled.push(handle);
        }

        fn status(&self) -> String {
            "HW-NET up 10.0.2.15/24".into()
        }
    }

    fn elf_image(n: usize) -> Vec<u8> {
        let mut b = b"\x7fELF".to_vec();
        b.resize(n, 0x5a);
        b
    }

    fn net_ports(left: u32, body: Vec<u8>) -> Ports {
        Ports::default()
            .with_net(StepNet {
                body,
                left,
                opened: Vec::new(),
                cancelled: Vec::new(),
                fail: None,
            })
            .with_flash(MemFlash::default())
    }

    #[test]
    fn https_update_polls_to_ready_without_a_thread() {
        let mut ports = net_ports(3, elf_image(4096));
        let src = Source::parse("https://fw.gsys.dev/g6lc_bios.elf").unwrap();
        let mut up = Update::start(src, "bios", &mut ports).unwrap();
        assert_eq!(up.phase(), Phase::Fetch);
        let mut polls = 0;
        while !up.phase().done() {
            up.poll(&mut ports);
            polls += 1;
            assert!(polls < 32, "poll should converge: {}", up.status());
        }
        assert_eq!(up.phase(), Phase::Ready, "{:?}", up.log());
        assert_eq!(up.bytes(), 4096);
        assert!(polls >= 4, "pending polls must be observable: {polls}");
        assert!(!up.digest().is_empty());
        assert!(up.status().contains("fw apply"));
        let out = up.apply(&mut ports).unwrap();
        assert!(out.contains("FLASH-COMMIT bios"), "{out}");
        assert_eq!(up.phase(), Phase::Applied);
        // Applying twice is refused, not repeated.
        assert!(up.apply(&mut ports).is_err());
        assert!(up.log().iter().any(|l| l.starts_with("FW-FETCH https")));
        assert!(up.log().iter().any(|l| l.starts_with("FW-VERIFY elf")));
        assert!(up.log().iter().any(|l| l.starts_with("FW-STAGE bios")));
    }

    #[test]
    fn usb_key_update_is_local_and_one_step() {
        let vols = MemVolumes::new().volume("KEY-FAT", "fat32", "key").file(
            "KEY-FAT",
            "/fw/g6lc_bios.elf",
            elf_image(2048),
        );
        let mut ports = Ports::default()
            .with_volumes(vols)
            .with_flash(MemFlash::default());
        let src = Source::parse("KEY-FAT:/fw/g6lc_bios.elf").unwrap();
        let mut up = Update::start(src, "bios", &mut ports).unwrap();
        assert_eq!(up.phase(), Phase::Verify, "a local key needs no fetch");
        while !up.phase().done() {
            up.poll(&mut ports);
        }
        assert_eq!(up.phase(), Phase::Ready, "{:?}", up.log());
        up.apply(&mut ports).unwrap();
        assert_eq!(up.phase(), Phase::Applied);
    }

    #[test]
    fn plain_http_and_bad_images_fail_closed() {
        assert!(Source::parse("http://fw.gsys.dev/x.elf")
            .unwrap_err()
            .contains("https"));
        assert!(Source::parse("").is_err());
        assert!(Source::parse("gopher").is_err());
        // Truncated body: verify refuses before anything is staged.
        let mut ports = net_ports(0, elf_image(64));
        let mut up = Update::start(
            Source::parse("https://fw.gsys.dev/x.elf").unwrap(),
            "bios",
            &mut ports,
        )
        .unwrap();
        while !up.phase().done() {
            up.poll(&mut ports);
        }
        assert_eq!(up.phase(), Phase::Failed);
        assert!(
            up.log().iter().any(|l| l.contains("under 1024")),
            "{:?}",
            up.log()
        );
        // Right size, wrong container for a BIOS self-update.
        let mut ports = net_ports(0, vec![0x42; 4096]);
        let mut up = Update::start(
            Source::parse("https://fw.gsys.dev/x.bin").unwrap(),
            "bios",
            &mut ports,
        )
        .unwrap();
        while !up.phase().done() {
            up.poll(&mut ports);
        }
        assert_eq!(up.phase(), Phase::Failed);
        assert!(up.log().iter().any(|l| l.contains("RISC-V ELF")));
        // No adapter at all is a refusal, not a hang.
        let mut bare = Ports::default();
        assert!(Update::start(
            Source::parse("https://fw.gsys.dev/x.elf").unwrap(),
            "bios",
            &mut bare
        )
        .is_err());
    }

    #[test]
    fn cancel_stops_the_transfer_and_releases_the_socket() {
        let mut ports = net_ports(9, elf_image(4096));
        let mut up = Update::start(
            Source::parse("https://fw.gsys.dev/g6lc_bios.elf").unwrap(),
            "bios",
            &mut ports,
        )
        .unwrap();
        up.poll(&mut ports);
        assert_eq!(up.phase(), Phase::Fetch);
        up.cancel(&mut ports);
        assert_eq!(up.phase(), Phase::Cancelled);
        assert_eq!(up.poll(&mut ports), Phase::Cancelled, "cancelled stays put");
        assert!(up.apply(&mut ports).is_err());
    }

    #[test]
    fn image_magic_is_named_not_guessed() {
        assert_eq!(image_kind(b"\x7fELFrest"), "elf");
        assert_eq!(image_kind(&[0x27, 0x05, 0x19, 0x56]), "uimage");
        assert_eq!(image_kind(b"UBI#....."), "ubi");
        assert_eq!(image_kind(b"hsqs...."), "squashfs");
        assert_eq!(image_kind(b"nope"), "unknown");
        assert_eq!(short_digest("0123456789abcdef0123"), "0123456789abcdef");
    }
}
