// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Completion wait policies + multi-queue region soak (production RT).
//!
//! Island soak often disables completion DMA (`wr_cpl_en=0`) for pure DONE claim.
//! When both DMA and PLIC/IRQ are enabled, preferred order is:
//! **completion word visible → fence → claim DONE / clear IRQ**.

use crate::{Device, Queue, Region, RtError};
use ai_tensor_abi::{Completion, Desc64, ST_BAD_PTR, ST_BAD_QID, ST_OK};

/// How software waits for a submitted ticket.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WaitPolicy {
    /// Spin on `poll(ticket)` only (default).
    Poll,
    /// Require `irq_pending` (FLAG_IRQ jobs) then poll+claim.
    IrqThenPoll,
    /// Spin on 64-bit completion word at `ptr_done`, then optional DONE claim.
    /// Use when `wr_cpl_en=1` and host trusts DMA store before claim.
    DmaThenClaim {
        ptr_done: u64,
        /// After DMA word matches ticket, call `claim_done` (PLIC source clear).
        claim: bool,
    },
    /// Claim DONE path only; ignore DMA word (island claim soak: wr_cpl_en=0).
    ClaimOnly,
}

impl Default for WaitPolicy {
    fn default() -> Self {
        Self::Poll
    }
}

/// Recommended policy from Caps + job flags.
pub fn recommend_policy(wr_cpl_en: bool, irq: bool, ptr_done: u64) -> WaitPolicy {
    if irq {
        return WaitPolicy::IrqThenPoll;
    }
    if wr_cpl_en && ptr_done != 0 {
        return WaitPolicy::DmaThenClaim {
            ptr_done,
            claim: true,
        };
    }
    WaitPolicy::Poll
}

/// Wait for `ticket` under `policy`.
pub fn wait_with_policy<D: Device>(
    dev: &mut D,
    ticket: u32,
    policy: WaitPolicy,
) -> Result<Completion, RtError> {
    match policy {
        WaitPolicy::Poll | WaitPolicy::ClaimOnly => wait_poll(dev, ticket),
        WaitPolicy::IrqThenPoll => {
            for _ in 0..10_000 {
                if dev.irq_pending() {
                    if let Some(c) = dev.poll(ticket)? {
                        // PLIC discipline: claim clears IRQ with DONE write on SoftIsland
                        let _ = dev.claim_done();
                        return Ok(c);
                    }
                }
                // Synchronous backends may complete before irq is observed if FLAG_IRQ
                // was not set — fall through to poll once.
                if let Some(c) = dev.poll(ticket)? {
                    return Ok(c);
                }
            }
            Err(RtError::Timeout)
        }
        WaitPolicy::DmaThenClaim { ptr_done, claim } => {
            for _ in 0..10_000 {
                let mut raw = [0u8; 8];
                dev.read_mem(ptr_done, &mut raw)?;
                let w = u64::from_le_bytes(raw);
                let c = Completion::from_u64(w);
                if c.ticket == ticket {
                    if claim {
                        let _ = dev.claim_done();
                    }
                    // Also drain poll so SoftIsland sticky is cleared if still set.
                    let _ = dev.poll(ticket);
                    return Ok(c);
                }
            }
            Err(RtError::Timeout)
        }
    }
}

fn wait_poll<D: Device>(dev: &mut D, ticket: u32) -> Result<Completion, RtError> {
    for _ in 0..10_000 {
        if let Some(c) = dev.poll(ticket)? {
            return Ok(c);
        }
    }
    Err(RtError::Timeout)
}

/// Multi-queue AI-3 region isolation + wait-policy soak (hostless).
///
/// Island_p3 CAP advertises **Queues=1** and the MMIO map places desc latch at
/// `0x0140`, so only q0 has a region window at `0x0120` (matches RTL). SoftIsland
/// rejects qid≥Queues with `ST_BAD_QID`. Sim keeps 4 software regions for a
/// fuller isolation check when Caps allow.
///
/// Checks: q0 OK · foreign-qid reject · (optional q1 program+OK on multi-q) ·
/// IrqThenPoll · DmaThenClaim · ClaimOnly (wr_cpl_en=0).
pub fn soak_multi_queue<D: Device>(dev: &mut D) -> Result<usize, RtError> {
    let mut checks = 0usize;
    dev.enable(true);
    dev.set_wr_cpl_en(true);

    let reg = Region {
        base: 0x1000,
        limit: 0x1000 + (1 << 24),
        read: true,
        write: true,
    };
    dev.program_region(0, reg)?;

    let need_a = 4usize;
    let need_c = 16usize;
    let pa = dev.alloc(need_a)?;
    let pb = dev.alloc(need_a)?;
    let pc = dev.alloc(need_c)?;
    let pd = dev.alloc(8)?;
    dev.write_mem(pa, &[1, 2, 3, 4])?;
    dev.write_mem(pb, &[5, 6, 7, 8])?;
    dev.write_mem(pc, &[0u8; 16])?;
    dev.write_mem(pd, &[0u8; 8])?;

    let desc = Desc64::gemm(2, 2, 2).with_ptrs(pa, pb, pc, pd);
    let nq = dev.caps().queues.max(1);

    // q0 submit OK
    let mut q0 = Queue::q0(100);
    let t0 = q0.next_ticket();
    dev.submit(0, t0, &desc)?;
    let c0 = wait_with_policy(dev, t0, WaitPolicy::Poll)?;
    if c0.status != ST_OK {
        return Err(RtError::Msg(format!("q0 expected OK got {}", c0.status)));
    }
    checks += 1;

    // Foreign qid: CAP Queues=1 → BAD_QID; multi-q sim without region → BAD_PTR
    let t1 = 101u32;
    dev.submit(1, t1, &desc)?;
    let c1 = wait_with_policy(dev, t1, WaitPolicy::Poll)?;
    if nq <= 1 {
        if c1.status != ST_BAD_QID && c1.status != ST_BAD_PTR {
            return Err(RtError::Msg(format!(
                "qid1 with Queues=1 expected BAD_QID/PTR got {}",
                c1.status
            )));
        }
    } else if c1.status != ST_BAD_PTR {
        return Err(RtError::Msg(format!(
            "q1 without region expected BAD_PTR got {}",
            c1.status
        )));
    }
    checks += 1;

    // Multi-queue isolation (sim / future Queues>1 only)
    if nq > 1 {
        match dev.program_region(1, reg) {
            Ok(()) => {
                let t2 = 102u32;
                dev.submit(1, t2, &desc)?;
                let c2 = wait_with_policy(dev, t2, WaitPolicy::Poll)?;
                if c2.status != ST_OK {
                    return Err(RtError::Msg(format!(
                        "q1 with region expected OK got {}",
                        c2.status
                    )));
                }
                checks += 1;
            }
            Err(_) => {
                // MMIO map may not expose q1 even if Caps lie — skip
            }
        }
    }

    // IRQ + IrqThenPoll on q0
    let desc_irq = desc.clone().with_irq(true);
    let t3 = 103u32;
    dev.submit(0, t3, &desc_irq)?;
    let c3 = wait_with_policy(dev, t3, WaitPolicy::IrqThenPoll)?;
    if c3.status != ST_OK {
        return Err(RtError::Msg(format!("irq wait expected OK got {}", c3.status)));
    }
    checks += 1;

    // DMA then claim: wr_cpl_en on, FLAG_IRQ off
    let t4 = 104u32;
    dev.write_mem(pd, &[0u8; 8])?;
    dev.submit(0, t4, &desc)?;
    let c4 = wait_with_policy(
        dev,
        t4,
        WaitPolicy::DmaThenClaim {
            ptr_done: pd,
            claim: true,
        },
    )?;
    if c4.status != ST_OK || c4.ticket != t4 {
        return Err(RtError::Msg(format!("dma-then-claim failed: {c4:?}")));
    }
    checks += 1;

    // Claim-only soak with wr_cpl_en=0 (island pure claim style)
    dev.set_wr_cpl_en(false);
    let t5 = 105u32;
    dev.write_mem(pd, &[0u8; 8])?;
    dev.submit(0, t5, &desc)?;
    let c5 = wait_with_policy(dev, t5, WaitPolicy::ClaimOnly)?;
    if c5.status != ST_OK {
        return Err(RtError::Msg(format!("claim-only expected OK got {}", c5.status)));
    }
    let mut raw = [0u8; 8];
    dev.read_mem(pd, &mut raw)?;
    if u64::from_le_bytes(raw) != 0 {
        return Err(RtError::Msg(
            "claim-only: expected no DMA completion word when wr_cpl_en=0".into(),
        ));
    }
    checks += 1;

    dev.set_wr_cpl_en(true);
    Ok(checks)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{MmioDevice, SimDevice};

    #[test]
    fn recommend_irq() {
        assert_eq!(
            recommend_policy(true, true, 0x1000),
            WaitPolicy::IrqThenPoll
        );
        assert!(matches!(
            recommend_policy(true, false, 0x1000),
            WaitPolicy::DmaThenClaim { .. }
        ));
        assert_eq!(recommend_policy(false, false, 0), WaitPolicy::Poll);
    }

    #[test]
    fn soak_sim() {
        let mut dev = SimDevice::new();
        let n = soak_multi_queue(&mut dev).expect("sim soak");
        // q0 + foreign + q1 + irq + dma + claim = 6
        assert!(n >= 5, "checks={n}");
    }

    #[test]
    fn soak_mmio() {
        let mut dev = MmioDevice::new();
        dev.probe_caps();
        let n = soak_multi_queue(&mut dev).expect("mmio soak");
        // Queues=1: no q1 program path → 5 checks
        assert_eq!(n, 5);
    }
}
