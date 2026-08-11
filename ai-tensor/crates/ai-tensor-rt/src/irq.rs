// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! IRQ wait abstraction for PLIC/UIO/eventfd (production RT).
//!
//! Board path (Variane): island irq_o to PLIC source ID 8. Host should:
//! 1. enable IRQ in desc (FLAG_IRQ)
//! 2. wait for interrupt (UIO/eventfd/poll sticky)
//! 3. claim DONE (clear level source) before PLIC complete
//!
//! Hostless CI uses SoftSticky / EventFdWait::soft (polls Device::irq_pending).
//! Live board uses feature linux-mmio + UioIrqWait or EventFdWait::open_linux.

use crate::{Device, RtError};

/// How the host blocks for an island IRQ.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum IrqWaitMode {
    /// Spin on Device::irq_pending (SoftIsland / sim FLAG_IRQ).
    #[default]
    SoftSticky,
    /// Linux UIO: blocking read of event count (feature linux-mmio).
    Uio,
    /// PLIC to eventfd (board driver) or hostless soft eventfd counter.
    EventFd,
}

/// PLIC source advertised by island_p3 Variane attach (PLIC ID 8).
pub const VARIANCE_PLIC_SOURCE: u32 = 8;

/// Contract description for board bring-up docs / doctor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IrqContract {
    pub plic_source: u32,
    pub mode: IrqWaitMode,
    pub clear_before_plic_complete: bool,
    pub notes: &'static str,
}

impl IrqContract {
    pub fn island_p3_variane() -> Self {
        Self {
            plic_source: VARIANCE_PLIC_SOURCE,
            mode: IrqWaitMode::SoftSticky,
            clear_before_plic_complete: true,
            notes: "irq_o to PLIC src 8; claim DONE (0x10C write 1) before PLIC complete; \
                    level re-arms if source still set",
        }
    }

    /// Same PLIC-8 contract with EventFd host wait mode advertised.
    pub fn island_p3_eventfd() -> Self {
        Self {
            mode: IrqWaitMode::EventFd,
            notes: "PLIC src 8 to eventfd (or soft eventfd in hostless CI); claim DONE before \
                    re-enable; FIFO head.irq drives level",
            ..Self::island_p3_variane()
        }
    }
}

/// Wait until dev.irq_pending() or timeout (soft model).
pub fn wait_irq_sticky<D: Device>(dev: &mut D, max_iters: u32) -> Result<(), RtError> {
    for _ in 0..max_iters {
        if dev.irq_pending() {
            return Ok(());
        }
    }
    Err(RtError::Timeout)
}

/// After IRQ: claim DONE for matching head ticket (poll may claim on SoftIsland).
pub fn claim_after_irq<D: Device>(
    dev: &mut D,
    ticket: u32,
) -> Result<ai_tensor_abi::Completion, RtError> {
    // Prefer Device::poll: SoftIsland/MmioDevice pops CPL FIFO head when ticket matches.
    // Do not claim_done first — that would drop the head before status is observed.
    for _ in 0..16 {
        if let Some(c) = dev.poll(ticket)? {
            return Ok(c);
        }
    }
    Err(RtError::Timeout)
}

/// Full soft IRQ wait: wait sticky then claim then completion.
pub fn wait_irq_then_claim<D: Device>(
    dev: &mut D,
    ticket: u32,
    max_iters: u32,
) -> Result<ai_tensor_abi::Completion, RtError> {
    wait_irq_sticky(dev, max_iters)?;
    for _ in 0..max_iters {
        if dev.irq_pending() {
            if let Some(c) = dev.poll(ticket)? {
                let _ = dev.claim_done();
                return Ok(c);
            }
        }
        if let Some(c) = dev.poll(ticket)? {
            return Ok(c);
        }
    }
    Err(RtError::Timeout)
}

/// EventFd-shaped wait then claim (hostless soft or live fd).
pub fn wait_eventfd_then_claim<D: Device>(
    dev: &mut D,
    efd: &mut EventFdWait,
    ticket: u32,
    max_iters: u32,
) -> Result<ai_tensor_abi::Completion, RtError> {
    efd.wait_for_device(dev, max_iters)?;
    claim_after_irq(dev, ticket)
}

/// Directed soak: submit FLAG_IRQ GEMM, wait soft IRQ path, verify claim.
pub fn soak_irq_wait<D: Device>(dev: &mut D) -> Result<(), RtError> {
    use crate::Region;
    use ai_tensor_abi::{Desc64, ST_OK};

    dev.enable(true);
    dev.set_wr_cpl_en(false);
    let reg = Region {
        base: 0x1000,
        limit: 0x1000 + (1 << 24),
        read: true,
        write: true,
    };
    dev.program_region(0, reg)?;
    let pa = dev.alloc(4)?;
    let pb = dev.alloc(4)?;
    let pc = dev.alloc(16)?;
    let pd = dev.alloc(8)?;
    dev.write_mem(pa, &[1, 2, 3, 4])?;
    dev.write_mem(pb, &[5, 6, 7, 8])?;
    dev.write_mem(pc, &[0u8; 16])?;
    let desc = Desc64::gemm(2, 2, 2)
        .with_ptrs(pa, pb, pc, pd)
        .with_irq(true);
    let ticket = 42u32;
    dev.submit(0, ticket, &desc)?;
    if !dev.irq_pending() {
        return Err(RtError::Msg(
            "irq soak: expected irq_pending after FLAG_IRQ submit".into(),
        ));
    }
    let c = wait_irq_then_claim(dev, ticket, 100)?;
    if c.status != ST_OK || c.ticket != ticket {
        return Err(RtError::Msg(format!("irq soak bad completion {c:?}")));
    }
    if dev.irq_pending() {
        return Err(RtError::Msg(
            "irq soak: irq still pending after claim (PLIC re-arm risk)".into(),
        ));
    }
    Ok(())
}

/// Directed soak using EventFd-shaped waiter (hostless soft counter + FIFO re-arm).
pub fn soak_eventfd_wait<D: Device>(dev: &mut D) -> Result<(), RtError> {
    use crate::Region;
    use ai_tensor_abi::{Desc64, ST_OK};

    dev.enable(true);
    dev.set_wr_cpl_en(false);
    let reg = Region {
        base: 0x1000,
        limit: 0x1000 + (1 << 24),
        read: true,
        write: true,
    };
    dev.program_region(0, reg)?;
    let pa = dev.alloc(4)?;
    let pb = dev.alloc(4)?;
    let pc = dev.alloc(16)?;
    let pd = dev.alloc(8)?;
    dev.write_mem(pa, &[1, 2, 3, 4])?;
    dev.write_mem(pb, &[5, 6, 7, 8])?;
    dev.write_mem(pc, &[0u8; 16])?;
    let desc = Desc64::gemm(2, 2, 2)
        .with_ptrs(pa, pb, pc, pd)
        .with_irq(true);
    let ticket = 77u32;
    let mut efd = EventFdWait::soft();
    efd.enable()?;
    dev.submit(0, ticket, &desc)?;
    let c = wait_eventfd_then_claim(dev, &mut efd, ticket, 100)?;
    if c.status != ST_OK || c.ticket != ticket {
        return Err(RtError::Msg(format!("eventfd soak bad completion {c:?}")));
    }
    if dev.irq_pending() {
        return Err(RtError::Msg(
            "eventfd soak: irq still pending after claim".into(),
        ));
    }
    Ok(())
}

/// Multi-finish CPL FIFO + EventFd re-arm (SoftIsland/MmioDevice only).
pub fn soak_eventfd_fifo_multi(dev: &mut crate::MmioDevice) -> Result<(), RtError> {
    use crate::Region;
    use ai_tensor_abi::Desc64;

    soak_eventfd_wait(dev)?;
    dev.enable(true);
    dev.set_wr_cpl_en(false);
    let reg = Region {
        base: 0x1000,
        limit: 0x1000 + (1 << 24),
        read: true,
        write: true,
    };
    dev.program_region(0, reg)?;
    let pa = dev.alloc(4)?;
    let pb = dev.alloc(4)?;
    let pc = dev.alloc(16)?;
    let pd = dev.alloc(8)?;
    dev.write_mem(pa, &[1, 2, 3, 4])?;
    dev.write_mem(pb, &[5, 6, 7, 8])?;
    dev.write_mem(pc, &[0u8; 16])?;
    let desc = Desc64::gemm(2, 2, 2)
        .with_ptrs(pa, pb, pc, pd)
        .with_irq(true);
    let mut efd = EventFdWait::soft();
    efd.enable()?;
    dev.submit(0, 78, &desc)?;
    efd.enable()?;
    dev.submit(0, 79, &desc)?;
    if !dev.irq_pending() {
        return Err(RtError::Msg("eventfd multi: expected head IRQ".into()));
    }
    let c78 = wait_eventfd_then_claim(dev, &mut efd, 78, 100)?;
    if c78.ticket != 78 {
        return Err(RtError::Msg(format!("eventfd multi first ticket {c78:?}")));
    }
    if !dev.irq_pending() {
        return Err(RtError::Msg(
            "eventfd multi: expected re-arm on next head.irq".into(),
        ));
    }
    let c79 = wait_eventfd_then_claim(dev, &mut efd, 79, 100)?;
    if c79.ticket != 79 {
        return Err(RtError::Msg(format!("eventfd multi second ticket {c79:?}")));
    }
    if dev.irq_pending() {
        return Err(RtError::Msg("eventfd multi: irq after empty FIFO".into()));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// EventFd waiter — hostless soft + optional Linux eventfd(2)
// ---------------------------------------------------------------------------

/// Eventfd-shaped IRQ wait: software counter always; real eventfd(2) under
/// linux-mmio when opened via EventFdWait::open_linux.
///
/// Board driver writes the fd when PLIC asserts; hostless CI auto-signals when
/// Device::irq_pending becomes true during EventFdWait::wait_for_device.
#[derive(Debug)]
pub struct EventFdWait {
    /// Software counter (always used for soft path; mirrors eventfd reads).
    pending: u64,
    #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
    linux: Option<std::fs::File>,
    #[cfg(not(all(feature = "linux-mmio", target_os = "linux")))]
    _linux: (),
}

impl Default for EventFdWait {
    fn default() -> Self {
        Self::soft()
    }
}

impl EventFdWait {
    /// Hostless / CI: no kernel fd; wait_for_device polls irq_pending.
    pub fn soft() -> Self {
        Self {
            pending: 0,
            #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
            linux: None,
            #[cfg(not(all(feature = "linux-mmio", target_os = "linux")))]
            _linux: (),
        }
    }

    /// Open a Linux eventfd (board path or local test). Requires linux-mmio.
    #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
    pub fn open_linux() -> Result<Self, RtError> {
        let fd = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC) };
        if fd < 0 {
            return Err(RtError::Msg(format!(
                "eventfd: {}",
                std::io::Error::last_os_error()
            )));
        }
        use std::os::unix::io::FromRawFd;
        let file = unsafe { std::fs::File::from_raw_fd(fd) };
        Ok(Self {
            pending: 0,
            linux: Some(file),
        })
    }

    /// Env AI_TENSOR_EVENTFD as inherited raw fd number, else open_linux.
    #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
    pub fn open_env() -> Result<Self, RtError> {
        if let Ok(s) = std::env::var("AI_TENSOR_EVENTFD") {
            let fd: i32 = s
                .parse()
                .map_err(|e| RtError::Msg(format!("AI_TENSOR_EVENTFD: {e}")))?;
            use std::os::unix::io::FromRawFd;
            let file = unsafe { std::fs::File::from_raw_fd(fd) };
            return Ok(Self {
                pending: 0,
                linux: Some(file),
            });
        }
        Self::open_linux()
    }

    /// Re-enable / arm (board may unmask; soft is a no-op).
    pub fn enable(&mut self) -> Result<(), RtError> {
        Ok(())
    }

    /// Inject a signal (test harness or userspace PLIC proxy).
    pub fn signal(&mut self, n: u64) -> Result<(), RtError> {
        if n == 0 {
            return Ok(());
        }
        self.pending = self.pending.saturating_add(n);
        #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
        if let Some(f) = self.linux.as_mut() {
            use std::io::Write;
            let buf = n.to_ne_bytes();
            f.write_all(&buf)
                .map_err(|e| RtError::Msg(format!("eventfd signal: {e}")))?;
        }
        Ok(())
    }

    /// Consume one event (soft counter or Linux eventfd read).
    pub fn wait(&mut self) -> Result<u64, RtError> {
        #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
        if let Some(f) = self.linux.as_mut() {
            use std::io::Read;
            let mut buf = [0u8; 8];
            f.read_exact(&mut buf)
                .map_err(|e| RtError::Msg(format!("eventfd wait: {e}")))?;
            return Ok(u64::from_ne_bytes(buf));
        }
        if self.pending == 0 {
            return Err(RtError::Timeout);
        }
        let n = self.pending;
        self.pending = 0;
        Ok(n)
    }

    /// Hostless bridge: if no pending soft signal, poll irq_pending and auto-signal.
    pub fn wait_for_device<D: Device>(
        &mut self,
        dev: &mut D,
        max_iters: u32,
    ) -> Result<u64, RtError> {
        #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
        if self.linux.is_some() {
            return self.wait();
        }
        for _ in 0..max_iters {
            if self.pending > 0 {
                return self.wait();
            }
            if dev.irq_pending() {
                self.signal(1)?;
                return self.wait();
            }
        }
        Err(RtError::Timeout)
    }

    pub fn is_soft(&self) -> bool {
        #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
        {
            self.linux.is_none()
        }
        #[cfg(not(all(feature = "linux-mmio", target_os = "linux")))]
        {
            true
        }
    }
}

// ---------------------------------------------------------------------------
// Linux UIO IRQ (board) — feature-gated
// ---------------------------------------------------------------------------

/// Blocking wait on a UIO device interrupt event counter.
#[cfg(all(feature = "linux-mmio", target_os = "linux"))]
pub struct UioIrqWait {
    file: std::fs::File,
    pub path: std::path::PathBuf,
}

#[cfg(all(feature = "linux-mmio", target_os = "linux"))]
impl UioIrqWait {
    pub fn open(path: &std::path::Path) -> Result<Self, RtError> {
        use std::fs::OpenOptions;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .map_err(|e| RtError::Msg(format!("uio irq open {}: {e}", path.display())))?;
        Ok(Self {
            file,
            path: path.to_path_buf(),
        })
    }

    pub fn open_env() -> Result<Self, RtError> {
        if let Ok(p) = std::env::var("AI_TENSOR_UIO") {
            return Self::open(std::path::Path::new(&p));
        }
        Self::open(std::path::Path::new("/dev/uio0"))
    }

    pub fn enable(&mut self) -> Result<(), RtError> {
        use std::io::Write;
        self.file
            .write_all(&1u32.to_ne_bytes())
            .map_err(|e| RtError::Msg(format!("uio enable: {e}")))?;
        Ok(())
    }

    pub fn wait(&mut self) -> Result<u32, RtError> {
        use std::io::Read;
        let mut buf = [0u8; 4];
        self.file
            .read_exact(&mut buf)
            .map_err(|e| RtError::Msg(format!("uio wait: {e}")))?;
        Ok(u32::from_ne_bytes(buf))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{MmioDevice, SimDevice};

    #[test]
    fn contract_plic8() {
        let c = IrqContract::island_p3_variane();
        assert_eq!(c.plic_source, 8);
        assert!(c.clear_before_plic_complete);
        let e = IrqContract::island_p3_eventfd();
        assert_eq!(e.mode, IrqWaitMode::EventFd);
    }

    #[test]
    fn soak_sim_irq() {
        let mut dev = SimDevice::new();
        soak_irq_wait(&mut dev).expect("sim irq");
    }

    #[test]
    fn soak_mmio_irq() {
        let mut dev = MmioDevice::new();
        dev.probe_caps();
        soak_irq_wait(&mut dev).expect("mmio irq");
    }

    #[test]
    fn soak_sim_eventfd() {
        let mut dev = SimDevice::new();
        soak_eventfd_wait(&mut dev).expect("sim eventfd");
    }

    #[test]
    fn soak_mmio_eventfd_fifo() {
        let mut dev = MmioDevice::new();
        dev.probe_caps();
        soak_eventfd_fifo_multi(&mut dev).expect("mmio eventfd fifo");
    }

    #[test]
    fn soft_eventfd_signal() {
        let mut e = EventFdWait::soft();
        e.signal(3).unwrap();
        assert_eq!(e.wait().unwrap(), 3);
        assert!(e.wait().is_err());
    }
}
