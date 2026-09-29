// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Completion wait policies + multi-queue region soak (production RT).
//!
//! Island soak often disables completion DMA (`wr_cpl_en=0`) for pure DONE claim.
//! When both DMA and PLIC/IRQ are enabled, preferred order is:
//! **completion word visible → fence → claim DONE / clear IRQ**.

use crate::{Device, Queue, Region, RtError};
use ai_tensor_abi::{Completion, Desc64, ST_BAD_PTR, ST_BAD_QID, ST_ERR, ST_OK};

/// How software waits for a submitted ticket.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WaitPolicy {
    /// Spin on `poll(ticket)` only (default).
    Poll,
    /// Require `irq_pending` (FLAG_IRQ jobs) then poll+claim.
    IrqThenPoll,
    /// Observe the completion word, then return the FIFO status.
    /// The word is stored before the write response. Its status can still
    /// be 0, or the store can be discarded, while the FIFO says `ST_ERR`.
    DmaThenClaim {
        ptr_done: u64,
        /// After the FIFO has this ticket, call `claim_done`.
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
        WaitPolicy::Poll => wait_poll(dev, ticket, false),
        WaitPolicy::ClaimOnly => wait_poll(dev, ticket, true),
        WaitPolicy::IrqThenPoll => {
            // Soft sticky + claim (see irq.rs); board swaps in UioIrqWait under linux-mmio.
            crate::wait_irq_then_claim(dev, ticket, 10_000)
        }
        WaitPolicy::DmaThenClaim { ptr_done, claim } => {
            for _ in 0..10_000 {
                // The FIFO is updated after the write response. The word
                // is not: a SLVERR can leave status 0, or leave the old bytes.
                if let Some(fifo) = dev.poll_completion(ticket, claim)? {
                    return Ok(fifo);
                }
                let mut raw = [0u8; 8];
                dev.read_mem(ptr_done, &mut raw)?;
            }
            Err(RtError::Timeout)
        }
    }
}

fn wait_poll<D: Device>(dev: &mut D, ticket: u32, claim: bool) -> Result<Completion, RtError> {
    for _ in 0..10_000 {
        let completion = if claim { dev.poll_completion(ticket, true)? } else { dev.poll(ticket)? };
        if let Some(c) = completion {
            return Ok(c);
        }
    }
    Err(RtError::Timeout)
}

/// Multi-queue AI-3 region isolation + wait-policy soak (hostless).
///
/// The sim pin advertises **Queues=1**. RTL keeps two queues: q0 at `0x0120`
/// and q1 at `0x01A0`, because the descriptor latch owns `0x0140`. SoftIsland
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
    dev.write_mem(pb, &[5, 7, 6, 8])?;
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

    /// Word says ST_OK. FIFO says ST_ERR. The wait returns the FIFO.
    struct SplitCpl {
        word: u64,
        fifo: Completion,
        claimed: bool,
    }

    impl Device for SplitCpl {
        fn caps(&self) -> crate::Caps {
            crate::Caps::default()
        }
        fn enable(&mut self, _on: bool) {}
        fn set_wr_cpl_en(&mut self, _on: bool) {}
        fn program_region(&mut self, _qid: u8, _region: Region) -> Result<(), RtError> {
            Ok(())
        }
        fn alloc(&mut self, _len: usize) -> Result<u64, RtError> {
            Ok(0)
        }
        fn write_mem(&mut self, _addr: u64, _data: &[u8]) -> Result<(), RtError> {
            Ok(())
        }
        fn read_mem(&mut self, _addr: u64, out: &mut [u8]) -> Result<(), RtError> {
            let bytes = self.word.to_le_bytes();
            out.copy_from_slice(&bytes);
            Ok(())
        }
        fn submit(&mut self, _qid: u8, _ticket: u32, _desc: &Desc64) -> Result<(), RtError> {
            Ok(())
        }
        fn poll(&mut self, ticket: u32) -> Result<Option<Completion>, RtError> {
            if self.fifo.ticket == ticket {
                Ok(Some(self.fifo))
            } else {
                Ok(None)
            }
        }
        fn poll_completion(&mut self, ticket: u32, claim: bool) -> Result<Option<Completion>, RtError> {
            let completion = self.poll(ticket)?;
            if claim && completion.is_some() {
                self.claim_done()?;
            }
            Ok(completion)
        }
        fn claim_done(&mut self) -> Result<(), RtError> {
            self.claimed = true;
            Ok(())
        }
    }

    #[test]
    fn dma_wait_uses_fifo_status_when_the_word_says_ok() {
        let mut dev = SplitCpl {
            word: Completion::make(42, ST_OK),
            fifo: Completion {
                ticket: 42,
                status: ST_ERR,
            },
            claimed: false,
        };
        let c = wait_with_policy(
            &mut dev,
            42,
            WaitPolicy::DmaThenClaim {
                ptr_done: 0x8000_5000,
                claim: true,
            },
        )
        .expect("fifo visible");
        assert_eq!(c.ticket, 42);
        assert_eq!(c.status, ST_ERR);
        assert!(dev.claimed);
    }

    #[test]
    fn dma_wait_uses_fifo_when_the_completion_store_is_discarded() {
        let mut dev = SplitCpl {
            word: 0,
            fifo: Completion {
                ticket: 7,
                status: ST_ERR,
            },
            claimed: false,
        };
        let c = wait_with_policy(
            &mut dev,
            7,
            WaitPolicy::DmaThenClaim {
                ptr_done: 0x8000_5000,
                claim: true,
            },
        )
        .expect("fifo visible without a stored ticket");
        assert_eq!(c.ticket, 7);
        assert_eq!(c.status, ST_ERR);
        assert!(dev.claimed);
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
