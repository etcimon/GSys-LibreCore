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
use ai_tensor_ir::{tile_gemm, va_blocking_tile, va_turbo_applied_level, va_turbo_measurement_fits, GemmTile};

/// One planned descriptor job in a stream (after device buffers exist).
#[derive(Debug, Clone)]
pub struct StreamJob {
    pub tile: GemmTile,
    pub ticket: u32,
    pub desc: Desc64,
}

/// Exact schedule plus the level that was asked for and the level that was applied.
#[derive(Debug, Clone)]
pub struct VaTurboTestPlan {
    pub plan: GemmStreamPlan,
    pub requested_level: u32,
    pub applied_level: u32,
    /// True when a planned tile carries a skip. A one-tile job and a K-split leave it false.
    pub reuse_enabled: bool,
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
/// Software lease for the reuse epoch register.
///
/// `invalidate` advances the epoch after a writer touches A or B. Hardware
/// does not snoop that write. Bind the lease before the next test-island
/// jobs. The live stream does not.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReuseLease {
    epoch: u32,
}

impl Default for ReuseLease {
    fn default() -> Self {
        Self { epoch: 0 }
    }
}

impl ReuseLease {
    pub fn from_epoch(epoch: u32) -> Self {
        Self { epoch }
    }

    pub fn epoch(self) -> u32 {
        self.epoch
    }

    pub fn invalidate(&mut self) {
        self.epoch = self.epoch.wrapping_add(1);
    }
}

/// Store `lease` in the device epoch register.
pub fn bind_reuse_lease<D: Device>(dev: &mut D, lease: &ReuseLease) -> Result<(), RtError> {
    dev.set_reuse_epoch(lease.epoch())
}

/// Caller-owned evidence window. A mismatch clears the claim.
///
/// The device also clears its bit when the epoch, level, or recipe
/// register is written. This struct covers tensor identity, numeric
/// format, and the approval profile, which the register map cannot see.
/// A level the budget rejects cannot arm the claim. A recipe whose own
/// analytic bound does not fit that level cannot arm it either. Neither
/// one changes the product.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct EvidenceWindow {
    level: u32,
    recipe: u32,
    epoch: u32,
    identity: u64,
    format: u32,
    profile: u64,
    valid: bool,
}

impl EvidenceWindow {
    /// Arm the claim. `recipe` is a 5-bit id and `format` is a 3-bit code.
    /// Level 0 needs no measurement. A higher level needs one that fits.
    pub fn commit(
        &mut self,
        level: u32,
        recipe: u32,
        epoch: u32,
        identity: u64,
        format: u32,
        profile: u64,
        measured_ppm: Option<u32>,
        kappa_q8: Option<u32>,
        approx_param: Option<u32>,
    ) -> bool {
        if recipe > 31
            || format > 7
            || !ai_tensor_ir::va_turbo_recipe_claim_fits(
                level,
                recipe,
                measured_ppm,
                kappa_q8,
                approx_param,
            )
        {
            self.valid = false;
            return false;
        }
        self.level = level;
        self.recipe = recipe;
        self.epoch = epoch;
        self.identity = identity;
        self.format = format;
        self.profile = profile;
        self.valid = true;
        true
    }

    pub fn valid(self) -> bool {
        self.valid
    }

    /// True only while the recorded tuple still matches.
    pub fn observe(
        &mut self,
        level: u32,
        recipe: u32,
        epoch: u32,
        identity: u64,
        format: u32,
        profile: u64,
    ) -> bool {
        let same = self.valid
            && self.level == level
            && self.recipe == recipe
            && self.epoch == epoch
            && self.identity == identity
            && self.format == format
            && self.profile == profile;
        if !same {
            self.valid = false;
        }
        same
    }
}

/// Write the window bit from `window`. A cleared struct stores 0.
pub fn bind_evidence_window<D: Device>(
    dev: &mut D,
    window: &EvidenceWindow,
) -> Result<(), RtError> {
    dev.set_va_turbo_window(window.valid())
}

/// Named-panel schedule for the directed VaTurbo test island only.
///
/// The device must report [`AccTile::VA_TURBO_TEST`] and
/// [`VA_TURBO_TEST_MACS`]. The live 512-MAC package is refused. The
/// schedule enables exact reuse only when a tile asks to skip A or B.
/// A K-split leaves reuse off. The default stream does not enable it, so
/// a flag there does not change a product.
pub fn plan_gemm_s8_va_turbo_test<D: Device>(
    dev: &mut D,
    m: u32,
    n: u32,
    k: u32,
    a: &[i8],
    b: &[i8],
    queue: &mut Queue,
    irq: bool,
) -> Result<GemmStreamPlan, RtError> {
    let caps = dev.caps();
    if caps.macs_per_cycle != ai_tensor_abi::VA_TURBO_TEST_MACS
        || caps.max_tile() != ai_tensor_abi::AccTile::VA_TURBO_TEST
    {
        return Err(RtError::Msg(
            "VaTurbo test schedule requires the 8-MAC 1024x512x16 directed tile".into(),
        ));
    }
    plan_gemm_s8_va_turbo_test_level(dev, m, n, k, a, b, queue, irq, 0, None).map(|p| p.plan)
}

/// Same schedule as [`plan_gemm_s8_va_turbo_test`]. A level above 0 is refused
/// unless `measured_ppm` fits that level's budget. The applied level is still 0.
pub fn plan_gemm_s8_va_turbo_test_level<D: Device>(
    dev: &mut D,
    m: u32,
    n: u32,
    k: u32,
    a: &[i8],
    b: &[i8],
    queue: &mut Queue,
    irq: bool,
    level: u32,
    measured_ppm: Option<u32>,
) -> Result<VaTurboTestPlan, RtError> {
    let caps = dev.caps();
    if caps.macs_per_cycle != ai_tensor_abi::VA_TURBO_TEST_MACS
        || caps.max_tile() != ai_tensor_abi::AccTile::VA_TURBO_TEST
    {
        return Err(RtError::Msg(
            "VaTurbo test schedule requires the 8-MAC 1024x512x16 directed tile".into(),
        ));
    }
    if level != 0 && !va_turbo_measurement_fits(level, measured_ppm) {
        return Err(RtError::Msg(
            "VaTurbo level above 0 needs a measured ppm inside the level budget; the MAC path still applies 0".into(),
        ));
    }
    if va_turbo_applied_level(level) != 0 {
        return Err(RtError::Msg(
            "VaTurbo arithmetic level is not applied".into(),
        ));
    }
    let plan = plan_gemm_s8_stream_in(dev, m, n, k, a, b, queue, irq, true)?;
    let reuse = plan.jobs.iter().any(|job| {
        job.desc.flags & (FLAG_REUSE_A | FLAG_REUSE_B) != 0
    });
    dev.set_reuse_en(reuse)?;
    dev.set_va_turbo_level(level)?;
    Ok(VaTurboTestPlan {
        plan,
        requested_level: level,
        applied_level: 0,
        reuse_enabled: reuse,
    })
}

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

/// Product of one directed VA-Turbo schedule.
///
/// `read_a` and `read_b` are the last tile. `hit_a` and `hit_b` are true
/// when any tile skipped that operand. `reuse_enabled` is true only when a
/// planned tile carries a skip.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VaTurboTestRun {
    pub c: Vec<i32>,
    pub flags: Vec<u32>,
    pub read_a: bool,
    pub read_b: bool,
    pub hit_a: bool,
    pub hit_b: bool,
    pub reuse_enabled: bool,
}

/// Run the directed schedule on `dev`.
///
/// The live 512-MAC package is refused. Exact reuse is enabled only when a
/// planned tile can skip an operand. The applied level stays 0 because this
/// path does not store one.
pub fn execute_va_turbo_test_s8<D: Device>(
    dev: &mut D,
    m: u32,
    n: u32,
    k: u32,
    a: &[i8],
    b: &[i8],
) -> Result<VaTurboTestRun, RtError> {
    execute_va_turbo_test_s8_at(dev, m, n, k, a, b, 1)
}

/// Same as [`execute_va_turbo_test_s8`], starting the ticket sequence at `first_ticket`.
pub fn execute_va_turbo_test_s8_at<D: Device>(
    dev: &mut D,
    m: u32,
    n: u32,
    k: u32,
    a: &[i8],
    b: &[i8],
    first_ticket: u32,
) -> Result<VaTurboTestRun, RtError> {
    let mut q = Queue::q0(first_ticket);
    let plan = plan_gemm_s8_va_turbo_test(dev, m, n, k, a, b, &mut q, false)?;
    let reuse_enabled = dev.reuse_enabled();
    let flags: Vec<u32> = plan.jobs.iter().map(|job| job.desc.flags).collect();
    let mut c = vec![0i32; (m as usize).saturating_mul(n as usize)];
    let mut read_a = true;
    let mut read_b = true;
    let mut hit_a = false;
    let mut hit_b = false;
    for job in &plan.jobs {
        let tm = job.tile.tm as usize;
        let tn = job.tile.tn as usize;
        let c_bytes = tm * tn * 4;
        dev.write_mem(plan.ptr_c_tile, &vec![0u8; c_bytes])?;
        dev.write_mem(plan.ptr_done, &[0u8; 8])?;
        dev.submit(plan.qid, job.ticket, &job.desc)?;
        let comp = wait_with_policy(dev, job.ticket, WaitPolicy::Poll)?;
        if comp.status != ST_OK {
            return Err(RtError::Msg(format!(
                "directed tile status {}",
                comp.status
            )));
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
                let dst = (job.tile.i0 as usize + ii) * n as usize + (job.tile.j0 as usize + jj);
                c[dst] = c[dst].wrapping_add(v);
            }
        }
        read_a = dev.reuse_read_a();
        read_b = dev.reuse_read_b();
        hit_a |= !read_a;
        hit_b |= !read_b;
    }
    Ok(VaTurboTestRun {
        c,
        flags,
        read_a,
        read_b,
        hit_a,
        hit_b,
        reuse_enabled,
    })
}

/// True when `dev`'s capability record is the directed tile and two adjacent
/// panels can skip A or B. A K-split and a one-tile shape are false. Any
/// other capability record is false.
pub fn directed_tiles_can_skip(caps: &crate::Caps, m: u32, n: u32, k: u32) -> bool {
    use ai_tensor_abi::{AccTile, VA_TURBO_TEST_MACS};
    if caps.macs_per_cycle != VA_TURBO_TEST_MACS || caps.max_tile() != AccTile::VA_TURBO_TEST {
        return false;
    }
    if m == 0 || n == 0 || k == 0 {
        return false;
    }
    let panel = va_blocking_tile(m, n, k, caps.acc_tile, caps.macs_per_cycle);
    let tiles = tile_gemm(m, n, k, panel);
    tiles.windows(2).any(|pair| {
        let prev = &pair[0];
        let tile = &pair[1];
        (prev.j0 == tile.j0 && prev.tn == tile.tn && prev.t0 == tile.t0 && prev.tk == tile.tk)
            || (prev.i0 == tile.i0 && prev.tm == tile.tm && prev.t0 == tile.t0 && prev.tk == tile.tk)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Caps, SimDevice};
    use ai_tensor_abi::{AccTile, CapRegs, FLAG_REUSE_A, FLAG_REUSE_B, VA_TURBO_TEST_MACS};

    #[test]
    fn an_evidence_window_drops_when_the_tensor_identity_changes() {
        let measured = ai_tensor_ir::VA_TURBO_DOC_INT8_PPM;
        let mut window = EvidenceWindow::default();
        assert!(!window.commit(8, 0x10, 1, 7, 0, 1, Some(measured), None, None));
        assert!(!window.commit(9, 27, 1, 7, 0, 1, Some(measured), Some(256), None));
        let mut dev = SimDevice::new();
        bind_evidence_window(&mut dev, &window).unwrap();
        assert!(!dev.va_turbo_window());
        assert!(window.commit(9, 0x10, 1, 7, 0, 1, Some(measured), None, None));
        bind_evidence_window(&mut dev, &window).unwrap();
        assert!(dev.va_turbo_window());
        let (c, comp) = crate::run_gemm_s8(&mut dev, 2, 2, 2, &[1, 2, 3, 4], &[5, 6, 7, 8], 1)
            .unwrap();
        assert!(comp.is_ok());
        assert_eq!(c, vec![19, 22, 43, 50]);
        assert!(dev.va_turbo_window());
        assert!(window.observe(9, 0x10, 1, 7, 0, 1));
        assert!(!window.observe(9, 0x10, 1, 7, 1, 1));
        assert!(!window.valid());
        bind_evidence_window(&mut dev, &window).unwrap();
        assert!(!dev.va_turbo_window());
        assert!(window.commit(0, 0, 0, 7, 0, 4, None, None, None));
        assert!(!window.observe(0, 0, 0, 7, 0, 5));
    }

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
    fn va_turbo_test_schedule_reuses_b_and_refuses_the_live_tile() {
        let a = vec![1i8; 16 * 8];
        let b = vec![1i8; 8 * 8];
        let mut live = SimDevice::new();
        let mut q = Queue::q0(1);
        assert!(plan_gemm_s8_va_turbo_test(&mut live, 16, 8, 8, &a, &b, &mut q, false).is_err());

        let mut caps = crate::Caps::default();
        caps.macs_per_cycle = VA_TURBO_TEST_MACS;
        caps.acc_tile = AccTile::VA_TURBO_TEST;
        let mut dev = SimDevice::with_caps(caps);
        let mut q = Queue::q0(1);
        let plan = plan_gemm_s8_va_turbo_test(&mut dev, 16, 8, 8, &a, &b, &mut q, false).unwrap();
        assert_eq!(plan.jobs.len(), 2);
        assert_eq!(plan.jobs[0].tile.tm, 8);
        assert_eq!(plan.jobs[0].tile.tn, 8);
        assert_eq!(plan.jobs[1].tile.i0, 8);
        assert_eq!(plan.jobs[1].desc.flags & FLAG_REUSE_B, FLAG_REUSE_B);
        assert_eq!(plan.jobs[1].desc.flags & FLAG_REUSE_A, 0);
        assert!(dev.reuse_enabled());
        let mut lease = ReuseLease::default();
        bind_reuse_lease(&mut dev, &lease).unwrap();
        assert_eq!(dev.reuse_epoch(), 0);
        lease.invalidate();
        bind_reuse_lease(&mut dev, &lease).unwrap();
        assert_eq!(dev.reuse_epoch(), 1);
        let mut wrapped = ReuseLease::from_epoch(u32::MAX);
        wrapped.invalidate();
        assert_eq!(wrapped.epoch(), 0);
        let (c, comp, ntiles) = run_gemm_stream_plan(&mut dev, &plan).unwrap();
        assert!(comp.is_ok());
        assert_eq!(ntiles, 2);
        assert_eq!(c, vec![8i32; 16 * 8]);
        assert!(dev.reuse_read_a());
        assert!(!dev.reuse_read_b());

        // K does not fit one panel. The second tile must not request reuse,
        // and the product is the full reduction.
        let mut caps = crate::Caps::default();
        caps.macs_per_cycle = VA_TURBO_TEST_MACS;
        caps.acc_tile = AccTile::VA_TURBO_TEST;
        let mut dev = SimDevice::with_caps(caps);
        let mut q = Queue::q0(1);
        let a = vec![1i8; 8 * 16];
        let b = vec![1i8; 16 * 8];
        let plan = plan_gemm_s8_va_turbo_test(&mut dev, 8, 8, 16, &a, &b, &mut q, false).unwrap();
        assert_eq!(plan.jobs.len(), 2);
        assert_eq!(plan.jobs[1].tile.t0, 8);
        assert_eq!(plan.jobs[1].desc.flags & (FLAG_REUSE_A | FLAG_REUSE_B), 0);
        assert!(!dev.reuse_enabled());
        let (c, comp, ntiles) = run_gemm_stream_plan(&mut dev, &plan).unwrap();
        assert!(comp.is_ok());
        assert_eq!(ntiles, 2);
        assert_eq!(c, vec![16i32; 8 * 8]);
        assert!(dev.reuse_read_a());
        assert!(dev.reuse_read_b());

        // N does not fit one square panel. The second tile reuses A.
        let mut caps = crate::Caps::default();
        caps.macs_per_cycle = VA_TURBO_TEST_MACS;
        caps.acc_tile = AccTile::VA_TURBO_TEST;
        let mut dev = SimDevice::with_caps(caps);
        let mut q = Queue::q0(1);
        let a = vec![1i8; 8 * 8];
        let b = vec![1i8; 8 * 16];
        let plan = plan_gemm_s8_va_turbo_test(&mut dev, 8, 16, 8, &a, &b, &mut q, false).unwrap();
        assert_eq!(plan.jobs.len(), 2);
        assert_eq!(plan.jobs[1].tile.j0, 8);
        assert_eq!(plan.jobs[1].desc.flags & FLAG_REUSE_A, FLAG_REUSE_A);
        assert_eq!(plan.jobs[1].desc.flags & FLAG_REUSE_B, 0);
        let (c, comp, ntiles) = run_gemm_stream_plan(&mut dev, &plan).unwrap();
        assert!(comp.is_ok());
        assert_eq!(ntiles, 2);
        assert_eq!(c, vec![8i32; 8 * 16]);
        assert!(!dev.reuse_read_a());
        assert!(dev.reuse_read_b());
        assert!(dev.reuse_enabled());

        // Level 8 does not cover the documented 18,527 ppm INT8 figure.
        // Level 9 does, and the product stays the exact 8s.
        let mut caps = crate::Caps::default();
        caps.macs_per_cycle = VA_TURBO_TEST_MACS;
        caps.acc_tile = AccTile::VA_TURBO_TEST;
        let mut dev = SimDevice::with_caps(caps);
        let mut q = Queue::q0(1);
        let a = vec![1i8; 8 * 8];
        let b = vec![1i8; 8 * 8];
        let measured = ai_tensor_ir::VA_TURBO_DOC_INT8_PPM;
        assert!(plan_gemm_s8_va_turbo_test_level(
            &mut dev, 8, 8, 8, &a, &b, &mut q, false, 8, Some(measured),
        )
        .is_err());
        let mut q = Queue::q0(1);
        let planned = plan_gemm_s8_va_turbo_test_level(
            &mut dev, 8, 8, 8, &a, &b, &mut q, false, 9, Some(measured),
        )
        .unwrap();
        assert_eq!(planned.requested_level, 9);
        assert_eq!(planned.applied_level, 0);
        assert!(!planned.reuse_enabled);
        assert!(!dev.reuse_enabled());
        assert_eq!(dev.va_turbo_level_word(), 9);
        assert_eq!(ai_tensor_abi::mmio::va_turbo_level_applied(dev.va_turbo_level_word()), 0);
        assert_eq!(planned.plan.jobs.len(), 1);
        let mut caps = crate::Caps::default();
        caps.macs_per_cycle = VA_TURBO_TEST_MACS;
        caps.acc_tile = AccTile::VA_TURBO_TEST;
        let mut exact_dev = SimDevice::with_caps(caps);
        let mut exact_q = Queue::q0(1);
        let exact = plan_gemm_s8_va_turbo_test_level(
            &mut exact_dev, 8, 8, 8, &a, &b, &mut exact_q, false, 0, None,
        )
        .unwrap();
        assert_eq!(planned.plan.jobs[0].tile, exact.plan.jobs[0].tile);
        assert_eq!(planned.plan.jobs[0].desc.m, exact.plan.jobs[0].desc.m);
        assert_eq!(planned.plan.jobs[0].desc.n, exact.plan.jobs[0].desc.n);
        assert_eq!(planned.plan.jobs[0].desc.k, exact.plan.jobs[0].desc.k);
        assert_eq!(planned.plan.jobs[0].desc.flags, exact.plan.jobs[0].desc.flags);
        assert!(!exact.reuse_enabled);
        let (c, comp, ntiles) = run_gemm_stream_plan(&mut dev, &planned.plan).unwrap();
        assert!(comp.is_ok());
        assert_eq!(ntiles, 1);
        assert_eq!(c, vec![8i32; 8 * 8]);
        assert_eq!(dev.pmu_va_turbo_level(), 9);
        assert_eq!(ai_tensor_abi::mmio::va_turbo_level_applied(dev.pmu_va_turbo_level()), 0);
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

    #[test]
    fn the_soft_island_schedule_enables_reuse_only_when_a_tile_skips() {
        use crate::MmioDevice;
        let mut live = MmioDevice::new();
        let a = vec![1i8; 16 * 8];
        let b = vec![1i8; 8 * 8];
        assert!(execute_va_turbo_test_s8(&mut live, 16, 8, 8, &a, &b).is_err());

        let mut cap = ai_tensor_abi::CapRegs::island_p3_sim_default();
        cap.macs_per_cycle = VA_TURBO_TEST_MACS;
        cap.acc_tile = AccTile::VA_TURBO_TEST;
        let mut dev = MmioDevice::with_cap(cap);
        let m_split = execute_va_turbo_test_s8(&mut dev, 16, 8, 8, &a, &b).unwrap();
        assert!(m_split.reuse_enabled);
        assert_eq!(m_split.flags[1] & FLAG_REUSE_B, FLAG_REUSE_B);
        assert_eq!(m_split.flags[1] & FLAG_REUSE_A, 0);
        assert!(m_split.read_a);
        assert!(!m_split.read_b);
        assert!(m_split.hit_b);
        assert!(!m_split.hit_a);
        assert_eq!(m_split.c, vec![8i32; 16 * 8]);

        let mut dev = MmioDevice::with_cap(cap);
        let a = vec![1i8; 8 * 16];
        let b = vec![1i8; 16 * 8];
        let k_split = execute_va_turbo_test_s8(&mut dev, 8, 8, 16, &a, &b).unwrap();
        assert!(!k_split.reuse_enabled);
        assert_eq!(k_split.flags[1] & (FLAG_REUSE_A | FLAG_REUSE_B), 0);
        assert!(k_split.read_a);
        assert!(k_split.read_b);
        assert!(!k_split.hit_a);
        assert!(!k_split.hit_b);
        assert_eq!(k_split.c, vec![16i32; 8 * 8]);
    }

    #[test]
    fn the_sim_schedule_enables_reuse_only_when_a_tile_skips() {
        let mut live = SimDevice::new();
        let a = vec![1i8; 16 * 8];
        let b = vec![1i8; 8 * 8];
        assert!(execute_va_turbo_test_s8(&mut live, 16, 8, 8, &a, &b).is_err());

        let mut caps = Caps::default();
        caps.macs_per_cycle = VA_TURBO_TEST_MACS;
        caps.acc_tile = AccTile::VA_TURBO_TEST;
        let mut dev = SimDevice::with_caps(caps);
        let m_split = execute_va_turbo_test_s8(&mut dev, 16, 8, 8, &a, &b).unwrap();
        assert!(m_split.reuse_enabled);
        assert_eq!(m_split.flags[1] & FLAG_REUSE_B, FLAG_REUSE_B);
        assert!(!m_split.read_b);
        assert!(m_split.hit_b);
        assert_eq!(m_split.c, vec![8i32; 16 * 8]);

        let mut dev = SimDevice::with_caps(caps);
        let a = vec![1i8; 8 * 16];
        let b = vec![1i8; 16 * 8];
        let k_split = execute_va_turbo_test_s8(&mut dev, 8, 8, 16, &a, &b).unwrap();
        assert!(!k_split.reuse_enabled);
        assert!(k_split.read_a);
        assert!(k_split.read_b);
        assert_eq!(k_split.c, vec![16i32; 8 * 8]);
    }
}
