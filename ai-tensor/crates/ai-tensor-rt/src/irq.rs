// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! IRQ wait abstraction for PLIC/UIO/eventfd (production RT).
//!
//! Board path (Variane): island `irq_o` → **PLIC source ID 8**. Host should:
//! 1. enable IRQ in desc (`FLAG_IRQ`)
//! 2. wait for interrupt (UIO/`eventfd`/poll sticky)
//! 3. **claim DONE** (clear level source) before PLIC complete
//!
//! Hostless CI uses [`SoftIrqWait`] (polls `Device::irq_pending`). Live board
//! uses feature `linux-mmio` + [`UioIrqWait`] when `/dev/uio*` is wired.

use crate::{Device, RtError};

/// How the host blocks for an island IRQ.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum IrqWaitMode {
    /// Spin on `Device::irq_pending` (SoftIsland / sim FLAG_IRQ).
    #[default]
    SoftSticky,
    /// Linux UIO: blocking read of event count (feature `linux-mmio`).
    Uio,
    /// Future: PLIC → eventfd (board driver). Same host API as UIO once fd is open.
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
            notes: "irq_o → PLIC src 8; claim DONE (0x10C write 1) before PLIC complete; \
                    level re-arms if source still set",
        }
    }
}

/// Wait until `dev.irq_pending()` or timeout (soft model).
pub fn wait_irq_sticky<D: Device>(dev: &mut D, max_iters: u32) -> Result<(), RtError> {
    for _ in 0..max_iters {
        if dev.irq_pending() {
            return Ok(());
        }
    }
    Err(RtError::Timeout)
}

/// After IRQ: claim DONE, return completion for ticket.
pub fn claim_after_irq<D: Device>(dev: &mut D, ticket: u32) -> Result<ai_tensor_abi::Completion, RtError> {
    // Preferred: claim sticky first so level IRQ drops, then read ticket/status via poll.
    let _ = dev.claim_done();
    for _ in 0..16 {
        if let Some(c) = dev.poll(ticket)? {
            return Ok(c);
        }
    }
    // SoftIsland poll may have cleared already on first claim_done — try last path
    if let Some(c) = dev.poll(ticket)? {
        return Ok(c);
    }
    Err(RtError::Timeout)
}

/// Full soft IRQ wait: wait sticky → claim → completion.
pub fn wait_irq_then_claim<D: Device>(
    dev: &mut D,
    ticket: u32,
    max_iters: u32,
) -> Result<ai_tensor_abi::Completion, RtError> {
    wait_irq_sticky(dev, max_iters)?;
    // poll also claims on MmioDevice; order: see claim_after_irq
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

/// Directed soak: submit FLAG_IRQ GEMM, wait soft IRQ path, verify claim.
pub fn soak_irq_wait<D: Device>(dev: &mut D) -> Result<(), RtError> {
    use crate::Region;
    use ai_tensor_abi::{Desc64, ST_OK};

    dev.enable(true);
    dev.set_wr_cpl_en(false); // pure claim / IRQ path like island PLIC soak
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
        // synchronous backends set sticky during submit
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

// ---------------------------------------------------------------------------
// Linux UIO IRQ (board) — feature-gated
// ---------------------------------------------------------------------------

/// Blocking wait on a UIO device's interrupt event counter.
///
/// Typical map: kernel UIO driver for PLIC/IRQ → userspace `read(uio_fd)` blocks
/// until interrupt; `write(1)` re-enables. Pair with MMIO `claim_done` first.
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

    /// Open from `AI_TENSOR_UIO` or `/dev/uio0`.
    pub fn open_env() -> Result<Self, RtError> {
        if let Ok(p) = std::env::var("AI_TENSOR_UIO") {
            return Self::open(std::path::Path::new(&p));
        }
        Self::open(std::path::Path::new("/dev/uio0"))
    }

    /// Re-enable interrupt (write 1 to UIO).
    pub fn enable(&mut self) -> Result<(), RtError> {
        use std::io::Write;
        self.file
            .write_all(&1u32.to_ne_bytes())
            .map_err(|e| RtError::Msg(format!("uio enable: {e}")))?;
        Ok(())
    }

    /// Block until UIO delivers an interrupt count (or OS error).
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
}
