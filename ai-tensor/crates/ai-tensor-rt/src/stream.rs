// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Multi-tile descriptor stream on a single queue (production RT path).
//!
//! Large GEMMs exceed AccTile; the island runs one tile job at a time. This module:
//! - allocates full A/B once (zero-copy tile views via `lda`/`ldb`)
//! - reuses a scratch C tile + done word
//! - submits sequential tickets on one `qid`
//! - accumulates K-split partials into host C
//!
//! Bus micro-arch (trail store, multi-out AR) stays in RTL; software only streams descs.

use crate::{wait_with_policy, Device, Region, RtError, SubmitMode, WaitPolicy};
use ai_tensor_abi::{Completion, Desc64, FLAG_REUSE_A, FLAG_REUSE_B, ST_OK};
use ai_tensor_ir::{tile_gemm, va_blocking_tile, GemmTile};

/// One planned descriptor job in a stream (after device buffers exist).
#[derive(Debug, Clone)]
pub struct StreamJob {
    pub tile: GemmTile,
    pub ticket: u32,
    pub desc: Desc64,
}

/// Plan of tile jobs for a row-major INT8 GEMM.
#[derive(Debug, Clone)]
pub struct GemmStreamPlan {
    pub m: u32,
    pub n: u32,
    pub k: u32,
    pub qid: u8,
    pub jobs: Vec<StreamJob>,
    /// Device addresses of full A/B (after setup).
    pub ptr_a: u64,
    pub ptr_b: u64,
    /// Scratch tile C and completion word.
    pub ptr_c_tile: u64,
    pub ptr_done: u64,
}

/// Ticket allocator + queue id (multi-queue soft surface; island soak uses q0).
#[derive(Debug, Clone)]
pub struct Queue {
    pub qid: u8,
    next_ticket: u32,
}

impl Queue {
    pub fn new(qid: u8, first_ticket: u32) -> Self {
        Self {
            qid,
            next_ticket: first_ticket,
        }
    }

    pub fn q0(first_ticket: u32) -> Self {
        Self::new(0, first_ticket)
    }

    pub fn next_ticket(&mut self) -> u32 {
        let t = self.next_ticket;
        self.next_ticket = self.next_ticket.wrapping_add(1);
        t
    }

    pub fn peek_ticket(&self) -> u32 {
        self.next_ticket
    }
}

/// Build Desc64 for one AccTile of a full GEMM with strided A/B into full buffers.
///
/// A is row-major `m×k` at `ptr_a_base` with `lda = k`.
/// B is row-major `k×n` at `ptr_b_base` with `ldb = n`.
/// C tile is dense `tm×tn` i32 at `ptr_c_tile` (host accumulates).
pub fn desc_for_tile(
    tile: &GemmTile,
    full_k: u32,
    _full_n: u32,
    ptr_a_base: u64,
    ptr_b_base: u64,
    ptr_c_tile: u64,
    ptr_done: u64,
    irq: bool,
) -> Desc64 {
    // Byte offsets: A i8, B i8
    let a_off = (tile.i0 as u64) * (full_k as u64) + (tile.t0 as u64);
    let b_off = (tile.j0 as u64) * (full_k as u64) + (tile.t0 as u64);
    let mut d = Desc64::gemm(tile.tm, tile.tn, tile.tk).with_ptrs(
        ptr_a_base + a_off,
        ptr_b_base + b_off,
        ptr_c_tile,
        ptr_done,
    );
    // lda = full K so rows of A stride past the k-tile window; ldb = full N for B.
    d.ld_ab = full_k | (full_k << 16);
    if irq {
        d = d.with_irq(true);
    }
    d
}

/// Setup region + full A/B + scratch, build stream plan (does not submit).
pub fn plan_gemm_s8_stream<D: Device>(
    dev: &mut D,
    m: u32,
    n: u32,
    k: u32,
    a: &[i8],
    b: &[i8],
    queue: &mut Queue,
    irq: bool,
) -> Result<GemmStreamPlan, RtError> {
    plan_gemm_s8_stream_in(dev, m, n, k, a, b, queue, irq, false)
}

fn plan_gemm_s8_stream_in<D: Device>(
    dev: &mut D,
    m: u32,
    n: u32,
    k: u32,
    a: &[i8],
    b: &[i8],
    queue: &mut Queue,
    irq: bool,
    va_panels: bool,
) -> Result<GemmStreamPlan, RtError> {
    let need_a = (m as usize)
        .checked_mul(k as usize)
        .ok_or(RtError::BufferOob)?;
    let need_b = (k as usize)
        .checked_mul(n as usize)
        .ok_or(RtError::BufferOob)?;
    if a.len() < need_a || b.len() < need_b {
        return Err(RtError::BufferOob);
    }
    crate::numfmt::check_format(ai_tensor_abi::NumFmt::Int, dev.caps().dtype_mask)?;
    if m == 0 || n == 0 || k == 0 || k > 0xffff {
        return Err(RtError::Msg("zero dimension".into()));
    }

    let tile_geo = dev.caps().max_tile();
    // The device cap is the largest legal descriptor. Named VA panels are a
    // tighter cut used only when the caller asks: while VaTurboEn is 0 the
    // extra descriptors would not skip a fetch.
    let block = if va_panels {
        va_blocking_tile(m, n, k, tile_geo, dev.caps().macs_per_cycle)
    } else {
        tile_geo
    };
    let tiles = tile_gemm(m, n, k, block);
    if tiles.is_empty() {
        return Err(RtError::Msg("empty tile plan".into()));
    }

    dev.enable(true);
    dev.set_wr_cpl_en(true);

    let pa = dev.alloc(need_a)?;
    let pb = dev.alloc(need_b)?;
    // Scratch C for largest tile (AccTile) and one done word reused each job.
    let max_c = (block.m as usize)
        .saturating_mul(block.n as usize)
        .saturating_mul(4)
        .max(4);
    let pc = dev.alloc(max_c)?;
    let pd = dev.alloc(8)?;

    let reg = Region {
        base: 0x1000,
        limit: 0x1000 + (1 << 24),
        read: true,
        write: true,
    };
    dev.program_region(queue.qid, reg)?;

    let a_bytes: Vec<u8> = a[..need_a].iter().map(|x| *x as u8).collect();
    let b_bytes: Vec<u8> = (0..n as usize).flat_map(|j| (0..k as usize).map(move |t| b[t * n as usize + j] as u8)).collect();
    dev.write_mem(pa, &a_bytes)?;
    dev.write_mem(pb, &b_bytes)?;
    dev.write_mem(pc, &vec![0u8; max_c])?;
    dev.write_mem(pd, &[0u8; 8])?;

    let mut jobs = Vec::with_capacity(tiles.len());
    for (idx, t) in tiles.iter().enumerate() {
        let ticket = queue.next_ticket();
        let mut desc = desc_for_tile(t, k, n, pa, pb, pc, pd, irq);
        // One resident slot. The request matches the tile just before this
        // one, which is the panel the island would still be holding.
        if idx > 0 {
            let prev = &tiles[idx - 1];
            if prev.j0 == t.j0 && prev.tn == t.tn && prev.t0 == t.t0 && prev.tk == t.tk {
                desc.flags |= FLAG_REUSE_B;
            }
            if prev.i0 == t.i0 && prev.tm == t.tm && prev.t0 == t.t0 && prev.tk == t.tk {
                desc.flags |= FLAG_REUSE_A;
            }
        }
        jobs.push(StreamJob {
            tile: *t,
            ticket,
            desc,
        });
    }

    Ok(GemmStreamPlan {
        m,
        n,
        k,
        qid: queue.qid,
        jobs,
        ptr_a: pa,
        ptr_b: pb,
        ptr_c_tile: pc,
        ptr_done: pd,
    })
}

/// Submit all jobs in order, wait each, accumulate C. Returns host C + last completion + job count.
pub fn run_gemm_stream_plan<D: Device>(
    dev: &mut D,
    plan: &GemmStreamPlan,
) -> Result<(Vec<i32>, Completion, u32), RtError> {
    run_gemm_stream_plan_with_policy(dev, plan, WaitPolicy::Poll)
}

/// Stream with explicit completion wait policy (Poll / IrqThenPoll / DmaThenClaim).
pub fn run_gemm_stream_plan_with_policy<D: Device>(
    dev: &mut D,
    plan: &GemmStreamPlan,
    policy: WaitPolicy,
) -> Result<(Vec<i32>, Completion, u32), RtError> {
    run_gemm_stream_plan_ex(dev, plan, policy, SubmitMode::Latch)
}

/// Stream with wait policy + latch/fetch submit mode.
pub fn run_gemm_stream_plan_ex<D: Device>(
    dev: &mut D,
    plan: &GemmStreamPlan,
    policy: WaitPolicy,
    mode: SubmitMode,
) -> Result<(Vec<i32>, Completion, u32), RtError> {
    let mut c = vec![0i32; (plan.m as usize) * (plan.n as usize)];
    let mut last = Completion {
        ticket: plan.jobs.first().map(|j| j.ticket).unwrap_or(0),
        status: ST_OK,
    };

    for job in &plan.jobs {
        // Clear scratch C for clean partial (sim overwrites; island may accumulate).
        let tm = job.tile.tm as usize;
        let tn = job.tile.tn as usize;
        let c_bytes = tm * tn * 4;
        dev.write_mem(plan.ptr_c_tile, &vec![0u8; c_bytes])?;
        dev.write_mem(plan.ptr_done, &[0u8; 8])?;

        match mode {
            SubmitMode::Latch => dev.submit(plan.qid, job.ticket, &job.desc)?,
            SubmitMode::Fetch => dev.submit_fetch(plan.qid, job.ticket, &job.desc)?,
        }
        // Per-job policy: DmaThenClaim needs this tile's ptr_done.
        let pol = match policy {
            WaitPolicy::DmaThenClaim { claim, .. } => WaitPolicy::DmaThenClaim {
                ptr_done: plan.ptr_done,
                claim,
            },
            other => other,
        };
        let comp = wait_with_policy(dev, job.ticket, pol)?;
        last = comp;
        if last.status != ST_OK {
            return Ok((c, last, plan.jobs.len() as u32));
        }

        let mut raw = vec![0u8; c_bytes];
        dev.read_mem(plan.ptr_c_tile, &mut raw)?;
        for ii in 0..tm {
            for jj in 0..tn {
                let v = i32::from_le_bytes(
                    raw[(ii * tn + jj) * 4..(ii * tn + jj) * 4 + 4]
                        .try_into()
                        .unwrap(),
                );
                let dst = ((job.tile.i0 as usize + ii) * plan.n as usize)
                    + (job.tile.j0 as usize + jj);
                c[dst] = c[dst].wrapping_add(v);
            }
        }
    }
    Ok((c, last, plan.jobs.len() as u32))
}

/// Full GEMM via multi-tile desc stream (preferred for large / framework mats).
pub fn run_gemm_s8_stream<D: Device>(
    dev: &mut D,
    m: u32,
    n: u32,
    k: u32,
    a: &[i8],
    b: &[i8],
    ticket: u32,
) -> Result<(Vec<i32>, Completion, u32), RtError> {
    run_gemm_s8_stream_with_policy(dev, m, n, k, a, b, ticket, WaitPolicy::Poll)
}

/// Stream GEMM with wait policy (e.g. DmaThenClaim when wr_cpl_en).
pub fn run_gemm_s8_stream_with_policy<D: Device>(
    dev: &mut D,
    m: u32,
    n: u32,
    k: u32,
    a: &[i8],
    b: &[i8],
    ticket: u32,
    policy: WaitPolicy,
) -> Result<(Vec<i32>, Completion, u32), RtError> {
    run_gemm_s8_stream_ex(dev, m, n, k, a, b, ticket, policy, SubmitMode::Latch)
}

/// Stream GEMM with wait policy + latch/fetch submit.
pub fn run_gemm_s8_stream_ex<D: Device>(
    dev: &mut D,
    m: u32,
    n: u32,
    k: u32,
    a: &[i8],
    b: &[i8],
    ticket: u32,
    policy: WaitPolicy,
    mode: SubmitMode,
) -> Result<(Vec<i32>, Completion, u32), RtError> {
    let irq = matches!(policy, WaitPolicy::IrqThenPoll);
    let mut q = Queue::q0(ticket);
    let mut plan = plan_gemm_s8_stream_in(dev, m, n, k, a, b, &mut q, irq, false)?;
    if irq {
        for j in &mut plan.jobs {
            j.desc = j.desc.clone().with_irq(true);
        }
    }
    run_gemm_stream_plan_ex(dev, &plan, policy, mode)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Caps, SimDevice};
    use ai_tensor_abi::{AccTile, CapRegs};

    #[test]
    fn stream_single_tile_matches_direct() {
        let mut dev = SimDevice::new();
        let a = vec![1i8, 2, 3, 4];
        let b = vec![5i8, 6, 7, 8];
        let (c, comp, n) = run_gemm_s8_stream(&mut dev, 2, 2, 2, &a, &b, 1).unwrap();
        assert!(comp.is_ok());
        assert_eq!(n, 1);
        assert_eq!(c, vec![19, 22, 43, 50]);
    }

    #[test]
    fn stream_4x4_tile2_zero_copy() {
        let mut caps = Caps::from_cap_regs(CapRegs::island_p3_sim_default(), 64);
        caps.acc_tile = AccTile { m: 2, n: 2, k: 2 };
        let mut dev = SimDevice::with_caps(caps);
        let a = vec![1i8; 16];
        let b = vec![1i8; 16];
        let (c, comp, ntiles) = run_gemm_s8_stream(&mut dev, 4, 4, 4, &a, &b, 10).unwrap();
        assert!(comp.is_ok());
        assert_eq!(ntiles, 8);
        assert!(c.iter().all(|&x| x == 4), "{c:?}");
    }

    #[test]
    fn queue_tickets_monotonic() {
        let mut q = Queue::q0(5);
        assert_eq!(q.next_ticket(), 5);
        assert_eq!(q.next_ticket(), 6);
        assert_eq!(q.qid, 0);
    }

    #[test]
    fn desc_tile_strides() {
        let t = GemmTile {
            i0: 2,
            j0: 4,
            t0: 1,
            tm: 2,
            tn: 2,
            tk: 2,
        };
        let d = desc_for_tile(&t, 8, 16, 0x1000, 0x2000, 0x3000, 0x4000, false);
        assert_eq!(d.m, 2);
        assert_eq!(d.lda(), 8);
        assert_eq!(d.ldb(), 8);
        assert_eq!(d.ptr_a, 0x1000 + 2 * 8 + 1);
        assert_eq!(d.ptr_b, 0x2000 + 4 * 8 + 1);
    }

    #[test]
    fn a_second_m_tile_requests_resident_b_and_keeps_c() {
        let mut dev = SimDevice::new();
        let mut q = Queue::q0(1);
        let a = vec![1i8; 1025];
        let b = vec![1i8; 1];
        let plan = plan_gemm_s8_stream(&mut dev, 1025, 1, 1, &a, &b, &mut q, false).unwrap();
        assert_eq!(plan.jobs.len(), 2);
        assert_eq!(plan.jobs[0].desc.flags & (FLAG_REUSE_A | FLAG_REUSE_B), 0);
        assert_eq!(plan.jobs[1].tile.i0, 1024);
        assert_ne!(plan.jobs[1].desc.flags & FLAG_REUSE_B, 0);
        assert_eq!(plan.jobs[1].desc.flags & FLAG_REUSE_A, 0);
        let (c, comp, ntiles) = run_gemm_stream_plan(&mut dev, &plan).unwrap();
        assert!(comp.is_ok());
        assert_eq!(ntiles, 2);
        assert!(c.iter().all(|&x| x == 1), "reuse request changed C");
    }

    #[test]
    fn a_second_n_tile_requests_resident_a() {
        let mut dev = SimDevice::new();
        let mut q = Queue::q0(1);
        let a = vec![1i8; 1];
        let b = vec![1i8; 513];
        let plan = plan_gemm_s8_stream(&mut dev, 1, 513, 1, &a, &b, &mut q, false).unwrap();
        assert_eq!(plan.jobs.len(), 2);
        assert_eq!(plan.jobs[1].tile.j0, 512);
        assert_ne!(plan.jobs[1].desc.flags & FLAG_REUSE_A, 0);
        assert_eq!(plan.jobs[1].desc.flags & FLAG_REUSE_B, 0);
        let (c, comp, _) = run_gemm_stream_plan(&mut dev, &plan).unwrap();
        assert!(comp.is_ok());
        assert!(c.iter().all(|&x| x == 1));
    }

    #[test]
    fn va_panel_schedule_splits_1024x256_into_half_panels() {
        let mut dev = SimDevice::new();
        let mut q = Queue::q0(1);
        let a = vec![1i8; 1024];
        let b = vec![1i8; 256];
        let plan =
            plan_gemm_s8_stream_in(&mut dev, 1024, 256, 1, &a, &b, &mut q, false, true).unwrap();
        assert_eq!(plan.jobs.len(), 2);
        assert!(plan.jobs.iter().all(|j| j.tile.tm == 512 && j.tile.tn == 256));
        assert_ne!(plan.jobs[1].desc.flags & FLAG_REUSE_B, 0);
        let (c, comp, _) = run_gemm_stream_plan(&mut dev, &plan).unwrap();
        assert!(comp.is_ok());
        assert_eq!(c.len(), 1024 * 256);
        assert!(c.iter().all(|&x| x == 1));
    }

    #[test]
    fn a_k_split_does_not_request_reuse() {
        let mut dev = SimDevice::new();
        let mut q = Queue::q0(1);
        let a = vec![1i8; 513];
        let b = vec![1i8; 513];
        let plan = plan_gemm_s8_stream(&mut dev, 1, 1, 513, &a, &b, &mut q, false).unwrap();
        assert_eq!(plan.jobs.len(), 2);
        assert_eq!(plan.jobs[0].tile.tk, 512);
        assert_eq!(plan.jobs[1].tile.t0, 512);
        assert_eq!(plan.jobs[1].tile.tk, 1);
        assert_eq!(plan.jobs[1].desc.flags & (FLAG_REUSE_A | FLAG_REUSE_B), 0);
        let (c, comp, ntiles) = run_gemm_stream_plan(&mut dev, &plan).unwrap();
        assert!(comp.is_ok());
        assert_eq!(ntiles, 2);
        assert_eq!(c, vec![513]);
    }

    #[test]
    fn an_equal_k_split_moves_the_pointer_and_keeps_flags_clear() {
        let mut dev = SimDevice::new();
        let mut q = Queue::q0(1);
        let a = vec![1i8; 1024];
        let b = vec![1i8; 1024];
        let plan = plan_gemm_s8_stream(&mut dev, 1, 1, 1024, &a, &b, &mut q, false).unwrap();
        assert_eq!(plan.jobs.len(), 2);
        assert_eq!(plan.jobs[0].tile.tk, 512);
        assert_eq!(plan.jobs[1].tile.t0, 512);
        assert_eq!(plan.jobs[1].tile.tk, 512);
        assert_eq!(plan.jobs[0].desc.lda(), 1024);
        assert_eq!(plan.jobs[1].desc.lda(), 1024);
        assert_eq!(plan.jobs[1].desc.ldb(), 1024);
        assert_eq!(plan.jobs[1].desc.ptr_a, plan.jobs[0].desc.ptr_a + 512);
        assert_eq!(plan.jobs[1].desc.ptr_b, plan.jobs[0].desc.ptr_b + 512);
        assert_eq!(plan.jobs[1].desc.flags & (FLAG_REUSE_A | FLAG_REUSE_B), 0);
        let (c, comp, ntiles) = run_gemm_stream_plan(&mut dev, &plan).unwrap();
        assert!(comp.is_ok());
        assert_eq!(ntiles, 2);
        assert_eq!(c, vec![1024]);
    }
}
