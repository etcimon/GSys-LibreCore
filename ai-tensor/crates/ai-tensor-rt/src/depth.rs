// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Single-queue depth soak + submit mode (latch vs DMA desc fetch).
//!
//! Island is a **single-engine** with one DONE sticky: software may post up to
//! `CAP.queue_depth` tickets **sequentially** (submit → wait → next). Concurrent
//! multi-outstanding jobs are not supported until the RTL grows a completion FIFO.

use crate::{Device, Queue, Region, RtError};
use ai_tensor_abi::{Completion, Desc64, ST_OK};

/// How the host rings the doorbell for a job.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SubmitMode {
    /// Write 64 B into desc latch MMIO (bit31=0).
    #[default]
    Latch,
    /// Write desc to DRAM + `desc_ptr` + doorbell FETCH (bit31=1).
    Fetch,
}

impl SubmitMode {
    pub fn from_str_loose(s: &str) -> Self {
        match s.to_ascii_lowercase().as_str() {
            "fetch" | "dma" | "dma_fetch" => Self::Fetch,
            _ => Self::Latch,
        }
    }
}

fn submit_mode<D: Device>(
    dev: &mut D,
    qid: u8,
    ticket: u32,
    desc: &Desc64,
    mode: SubmitMode,
) -> Result<(), RtError> {
    match mode {
        SubmitMode::Latch => dev.submit(qid, ticket, desc),
        SubmitMode::Fetch => dev.submit_fetch(qid, ticket, desc),
    }
}

/// Run `depth` sequential GEMMs on q0 (or `caps.queue_depth` if `depth==0`).
///
/// Returns number of successful jobs.
pub fn soak_queue_depth<D: Device>(
    dev: &mut D,
    mode: SubmitMode,
    depth: u32,
) -> Result<u32, RtError> {
    let cap_depth = dev.caps().queue_depth.max(1);
    let n = if depth == 0 {
        cap_depth
    } else {
        depth.min(cap_depth.max(depth)) // allow explicit depth even if CAP says 4
    };
    // Prefer at least 1; allow host to request more than CAP for sim stress
    let n = n.max(1).min(16);

    dev.enable(true);
    dev.set_wr_cpl_en(true);
    let reg = Region {
        base: 0x1000,
        limit: 0x1000 + (1 << 24),
        read: true,
        write: true,
    };
    dev.program_region(0, reg)?;

    let mut q = Queue::q0(200);
    let mut ok = 0u32;
    for i in 0..n {
        let pa = dev.alloc(4)?;
        let pb = dev.alloc(4)?;
        let pc = dev.alloc(16)?;
        let pd = dev.alloc(8)?;
        // Vary pattern slightly per job
        let a0 = (1 + i as i8).wrapping_mul(1);
        dev.write_mem(pa, &[a0 as u8, 2, 3, 4])?;
        dev.write_mem(pb, &[5, 6, 7, 8])?;
        dev.write_mem(pc, &[0u8; 16])?;
        dev.write_mem(pd, &[0u8; 8])?;
        let desc = Desc64::gemm(2, 2, 2).with_ptrs(pa, pb, pc, pd);
        let ticket = q.next_ticket();
        submit_mode(dev, 0, ticket, &desc, mode)?;
        let c = dev.wait(ticket)?;
        if c.status != ST_OK {
            return Err(RtError::Msg(format!(
                "depth job {i} ticket={ticket} status={}",
                c.status
            )));
        }
        // Spot-check c00 = a0*5 + 2*7
        let mut raw = [0u8; 4];
        dev.read_mem(pc, &mut raw)?;
        let c00 = i32::from_le_bytes(raw);
        let exp = (a0 as i32) * 5 + 2 * 7;
        if c00 != exp {
            return Err(RtError::Msg(format!(
                "depth job {i} c00={c00} exp={exp}"
            )));
        }
        ok += 1;
    }
    Ok(ok)
}

/// Fire `n` sequential jobs **without claim between submits**, then claim each
/// CPL FIFO head in order (oldest-first). Matches `g6lc_ai_cpl_fifo` semantics:
/// DONE sticky = !empty; claim pops head.
pub fn soak_history_poll<D: Device>(dev: &mut D, n: u32) -> Result<u32, RtError> {
    let n = n.max(1).min(8);
    dev.enable(true);
    dev.set_wr_cpl_en(true);
    let reg = Region {
        base: 0x1000,
        limit: 0x1000 + (1 << 24),
        read: true,
        write: true,
    };
    dev.program_region(0, reg)?;
    let mut tickets = Vec::new();
    let mut q = Queue::q0(400);
    for _ in 0..n {
        let pa = dev.alloc(4)?;
        let pb = dev.alloc(4)?;
        let pc = dev.alloc(16)?;
        let pd = dev.alloc(8)?;
        dev.write_mem(pa, &[1, 2, 3, 4])?;
        dev.write_mem(pb, &[5, 6, 7, 8])?;
        dev.write_mem(pc, &[0u8; 16])?;
        let desc = Desc64::gemm(2, 2, 2).with_ptrs(pa, pb, pc, pd);
        let t = q.next_ticket();
        // No intermediate claim — completions queue in CPL FIFO
        dev.submit(0, t, &desc)?;
        tickets.push(t);
    }
    // Claim/poll FIFO head in order (oldest first)
    let mut ok = 0u32;
    for t in tickets {
        match dev.poll(t)? {
            Some(c) if c.status == ST_OK && c.ticket == t => ok += 1,
            Some(c) => {
                return Err(RtError::Msg(format!(
                    "CPL FIFO head expected ticket={t} got {c:?}"
                )));
            }
            None => {
                return Err(RtError::Msg(format!("CPL FIFO miss ticket={t}")));
            }
        }
    }
    Ok(ok)
}

/// N sequential tickets without checking C (latency of submit path only).
pub fn soak_ticket_sequence<D: Device>(dev: &mut D, n: u32) -> Result<Vec<Completion>, RtError> {
    let mut out = Vec::new();
    dev.enable(true);
    dev.set_wr_cpl_en(true);
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
    let desc = Desc64::gemm(2, 2, 2).with_ptrs(pa, pb, pc, pd);
    let mut q = Queue::q0(300);
    for _ in 0..n.max(1).min(32) {
        dev.write_mem(pc, &[0u8; 16])?;
        let t = q.next_ticket();
        dev.submit(0, t, &desc)?;
        out.push(dev.wait(t)?);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{MmioDevice, SimDevice};

    #[test]
    fn depth_latch_sim() {
        let mut dev = SimDevice::new();
        let n = soak_queue_depth(&mut dev, SubmitMode::Latch, 4).unwrap();
        assert_eq!(n, 4);
    }

    #[test]
    fn depth_fetch_mmio() {
        let mut dev = MmioDevice::new();
        dev.probe_caps();
        let n = soak_queue_depth(&mut dev, SubmitMode::Fetch, 3).unwrap();
        assert_eq!(n, 3);
    }

    #[test]
    fn ticket_seq() {
        let mut dev = SimDevice::new();
        let v = soak_ticket_sequence(&mut dev, 5).unwrap();
        assert_eq!(v.len(), 5);
        assert!(v.iter().all(|c| c.is_ok()));
    }

    #[test]
    fn history_poll_sim() {
        let mut dev = SimDevice::new();
        let n = soak_history_poll(&mut dev, 4).unwrap();
        assert_eq!(n, 4);
    }

    #[test]
    fn history_poll_mmio() {
        let mut dev = MmioDevice::new();
        dev.probe_caps();
        let n = soak_history_poll(&mut dev, 4).unwrap();
        assert_eq!(n, 4);
    }
}
