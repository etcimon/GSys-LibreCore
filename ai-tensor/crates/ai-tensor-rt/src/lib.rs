// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Runtime: regions, submit, wait — **sim** backend (mandatory CI).

mod sim;
mod mmio;
mod profile;
mod cosim;
mod stream;
mod policy;
mod irq;
mod depth;
mod probe;

pub use sim::SimDevice;
pub use profile::Profile;
pub use cosim::{
    builtin_goldens, check_desc_pack_golden, golden_job_json, run_builtin_suite,
    run_external_cosim_checks, try_external_cosim_job, try_external_cosim_ping, GoldenGemm,
};
pub use mmio::{probe_cap_regs, read_pmu, seed_cap_island_p3, MappedWindow, MmioBus, MmioDevice, SoftIsland};
pub use stream::{
    desc_for_tile, plan_gemm_s8_stream, run_gemm_s8_stream, run_gemm_s8_stream_ex,
    run_gemm_s8_stream_with_policy, run_gemm_stream_plan, run_gemm_stream_plan_ex,
    run_gemm_stream_plan_with_policy, GemmStreamPlan, Queue, StreamJob,
};
pub use policy::{recommend_policy, soak_multi_queue, wait_with_policy, WaitPolicy};
pub use irq::{
    claim_after_irq, soak_irq_wait, wait_irq_sticky, wait_irq_then_claim, IrqContract, IrqWaitMode,
    VARIANCE_PLIC_SOURCE,
};
pub use depth::{soak_history_poll, soak_queue_depth, soak_ticket_sequence, SubmitMode};
pub use probe::ProbeReport;

use ai_tensor_abi::{AccTile, CapRegs, Completion, Desc64, PmuSnapshot, ST_OK};
use thiserror::Error;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum RtError {
    #[error("device disabled")]
    Disabled,
    #[error("bad pointer / AI-3 region: {0}")]
    BadPtr(&'static str),
    #[error("unsupported op")]
    UnsupportedOp,
    #[error("ticket not found")]
    UnknownTicket,
    #[error("timeout waiting for completion")]
    Timeout,
    #[error("buffer OOB")]
    BufferOob,
    #[error("{0}")]
    Msg(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Caps {
    pub t2_desc: bool,
    pub completion_word: bool,
    pub wr_cpl_en: bool,
    pub op_gemm: bool,
    /// When true, sim runs a software INT8 GEMM into C (high-level torch tests).
    pub compute_ref: bool,
    /// AccTile geometry (from CAP or profile pin).
    pub acc_tile: AccTile,
    pub macs_per_cycle: u32,
    /// Fabric data width (bits); software discovery only (not CAP word today).
    pub noc_width: u32,
    pub clusters: u32,
    /// CAP queue count (island_p3 = 1; MMIO region window only for q0 today).
    pub queues: u32,
    pub queue_depth: u32,
}

impl Default for Caps {
    fn default() -> Self {
        Self::from_cap_regs(CapRegs::island_p3_sim_default(), 64)
    }
}

impl Caps {
    pub fn from_cap_regs(c: CapRegs, noc_width: u32) -> Self {
        Self {
            t2_desc: true,
            completion_word: true,
            wr_cpl_en: true,
            op_gemm: (c.dtype_mask & 1) != 0,
            compute_ref: true,
            acc_tile: c.acc_tile,
            macs_per_cycle: c.macs_per_cycle,
            noc_width,
            clusters: c.clusters,
            queues: u32::from(c.queues.max(1)),
            queue_depth: u32::from(c.queue_depth.max(1)),
        }
    }

    pub fn max_tile(&self) -> AccTile {
        self.acc_tile
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Region {
    pub base: u64,
    pub limit: u64, // exclusive
    pub read: bool,
    pub write: bool,
}

impl Region {
    pub fn contains(&self, addr: u64, len: u64, need_r: bool, need_w: bool) -> bool {
        if self.limit <= self.base || len == 0 {
            return false;
        }
        let last = addr.saturating_add(len - 1);
        if addr < self.base || last >= self.limit || last < addr {
            return false;
        }
        if need_r && !self.read {
            return false;
        }
        if need_w && !self.write {
            return false;
        }
        true
    }
}

/// Host-facing device API.
pub trait Device: Send {
    fn caps(&self) -> Caps;
    fn enable(&mut self, on: bool);
    fn set_wr_cpl_en(&mut self, on: bool);
    fn program_region(&mut self, qid: u8, region: Region) -> Result<(), RtError>;
    /// Allocate `len` bytes in device-visible memory; returns device address.
    fn alloc(&mut self, len: usize) -> Result<u64, RtError>;
    fn write_mem(&mut self, addr: u64, data: &[u8]) -> Result<(), RtError>;
    fn read_mem(&mut self, addr: u64, out: &mut [u8]) -> Result<(), RtError>;
    fn submit(&mut self, qid: u8, ticket: u32, desc: &Desc64) -> Result<(), RtError>;
    /// Submit via **DMA desc fetch**: write 64 B desc into device memory, set `desc_ptr`,
    /// doorbell with bit31. Default falls back to latch `submit` (sim).
    fn submit_fetch(&mut self, qid: u8, ticket: u32, desc: &Desc64) -> Result<(), RtError> {
        self.submit(qid, ticket, desc)
    }
    fn poll(&mut self, ticket: u32) -> Result<Option<Completion>, RtError>;
    /// Sticky last-job PMU (zeros until a GEMM completes).
    fn pmu(&self) -> PmuSnapshot {
        PmuSnapshot::default()
    }
    /// Level IRQ sticky (SoftIsland / sim FLAG_IRQ). Cleared with claim_done / DONE write.
    fn irq_pending(&self) -> bool {
        false
    }
    /// Clear DONE sticky / IRQ source (PLIC claim discipline). Default no-op.
    fn claim_done(&mut self) -> Result<(), RtError> {
        Ok(())
    }
    fn wait(&mut self, ticket: u32) -> Result<Completion, RtError> {
        // Sim is synchronous — poll once after submit is enough; loop for API shape.
        for _ in 0..10_000 {
            if let Some(c) = self.poll(ticket)? {
                return Ok(c);
            }
        }
        Err(RtError::Timeout)
    }
}

/// Convenience: submit GEMM and wait; optional software compute already in sim.
pub fn run_gemm_s8<D: Device>(
    dev: &mut D,
    m: u32,
    n: u32,
    k: u32,
    a: &[i8],
    b: &[i8],
    ticket: u32,
) -> Result<(Vec<i32>, Completion), RtError> {
    let need_a = (m as usize)
        .checked_mul(k as usize)
        .ok_or(RtError::BufferOob)?;
    let need_b = (k as usize)
        .checked_mul(n as usize)
        .ok_or(RtError::BufferOob)?;
    let need_c = (m as usize)
        .checked_mul(n as usize)
        .ok_or(RtError::BufferOob)?;
    if a.len() < need_a || b.len() < need_b {
        return Err(RtError::BufferOob);
    }

    dev.enable(true);
    dev.set_wr_cpl_en(true);

    let tile = dev.caps().max_tile();
    if !tile.fits(m, n, k) {
        return Err(RtError::Msg(format!(
            "dims {}x{}x{} exceed AccTile {}x{}x{}",
            m, n, k, tile.m, tile.n, tile.k
        )));
    }

    let pa = dev.alloc(need_a)?;
    let pb = dev.alloc(need_b)?;
    let pc = dev.alloc(need_c * 4)?; // i32 out
    let pd = dev.alloc(8)?;

    // Single wide region covering all allocs (sim returns ascending addrs from base).
    let reg = Region {
        base: 0x1000,
        limit: 0x1000 + (1 << 24),
        read: true,
        write: true,
    };
    dev.program_region(0, reg)?;

    let a_bytes: Vec<u8> = a[..need_a].iter().map(|x| *x as u8).collect();
    let b_bytes: Vec<u8> = b[..need_b].iter().map(|x| *x as u8).collect();
    dev.write_mem(pa, &a_bytes)?;
    dev.write_mem(pb, &b_bytes)?;
    dev.write_mem(pc, &vec![0u8; need_c * 4])?;
    dev.write_mem(pd, &[0u8; 8])?;

    let gemm = ai_tensor_ir::Gemm {
        m,
        n,
        k,
        dtype: ai_tensor_ir::DType::S8,
        ptr_a: pa,
        ptr_b: pb,
        ptr_c: pc,
        ptr_done: pd,
        irq: false,
    };
    let desc = gemm.lower_with_tile(tile).map_err(|e| RtError::Msg(e.to_string()))?;
    dev.submit(0, ticket, &desc)?;
    let c = dev.wait(ticket)?;
    if c.status != ST_OK {
        return Err(RtError::Msg(format!("status {}", c.status)));
    }

    let mut raw = vec![0u8; need_c * 4];
    dev.read_mem(pc, &mut raw)?;
    let mut out = Vec::with_capacity(need_c);
    for i in 0..need_c {
        let v = i32::from_le_bytes(raw[i * 4..i * 4 + 4].try_into().unwrap());
        out.push(v);
    }
    Ok((out, c))
}

/// GEMM with host-side AccTile streaming when dims exceed CAP tile.
///
/// Uses the multi-tile **desc stream** path (zero-copy A/B via `lda`/`ldb`,
/// sequential tickets on q0). Same accumulate semantics as Python auto_tile.
pub fn run_gemm_s8_auto<D: Device>(
    dev: &mut D,
    m: u32,
    n: u32,
    k: u32,
    a: &[i8],
    b: &[i8],
    ticket: u32,
) -> Result<(Vec<i32>, Completion, u32), RtError> {
    // Always use stream planner: single-tile plans collapse to one job with
    // correct strides; multi-tile reuses full A/B without host gather.
    run_gemm_s8_stream(dev, m, n, k, a, b, ticket)
}

#[cfg(test)]
mod auto_tile_tests {
    use super::*;
    use crate::SimDevice;
    use ai_tensor_abi::{AccTile, CapRegs};

    #[test]
    fn auto_tile_single_when_fits() {
        let mut dev = SimDevice::new();
        let a = vec![1i8; 16];
        let b = vec![1i8; 16];
        let (c, comp, ntiles) = run_gemm_s8_auto(&mut dev, 4, 4, 4, &a, &b, 1).unwrap();
        assert!(comp.is_ok());
        assert_eq!(ntiles, 1);
        assert!(c.iter().all(|&x| x == 4));
    }

    #[test]
    fn auto_tile_4x4_with_tile2() {
        let mut caps = Caps::from_cap_regs(CapRegs::island_p3_sim_default(), 64);
        caps.acc_tile = AccTile { m: 2, n: 2, k: 2 };
        let mut dev = SimDevice::with_caps(caps);
        let a = vec![1i8; 16];
        let b = vec![1i8; 16];
        let (c, comp, ntiles) = run_gemm_s8_auto(&mut dev, 4, 4, 4, &a, &b, 1).unwrap();
        assert!(comp.is_ok());
        assert_eq!(ntiles, 8); // 2x2x2
        assert!(c.iter().all(|&x| x == 4), "{c:?}");
    }
}
