// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Runtime: regions, submit, wait — **sim** backend (mandatory CI).

pub mod format_trace;
pub mod numfmt;
mod sim;
mod mmio;
mod profile;
mod cosim;
mod stream;
mod policy;
mod irq;
mod depth;
mod probe;
mod host;

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
    claim_after_irq, soak_eventfd_fifo_multi, soak_eventfd_wait, soak_irq_wait,
    wait_eventfd_then_claim, wait_irq_sticky, wait_irq_then_claim, EventFdWait, IrqContract,
    IrqWaitMode, VARIANCE_PLIC_SOURCE,
};
pub use depth::{soak_history_poll, soak_queue_depth, soak_ticket_sequence, SubmitMode};
pub use probe::ProbeReport;
pub use host::{
    prepare_device, submit_one_desc, HostGemmJob, HostJobResult, HostRuntime,
};

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
    #[error("ST_BAD_FMT: unsupported or ungranted numeric format")]
    BadFmt,
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
    pub dtype_mask: u16,
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
    /// Float codes multiply only when this is set. A mask bit is not a datapath.
    /// The software reference sets it. The live sim pin does not.
    pub fp_datapath: bool,
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
            op_gemm: (c.dtype_mask & numfmt::SOFTWARE_DTYPE_MASK) != 0,
            dtype_mask: c.dtype_mask,
            compute_ref: true,
            acc_tile: c.acc_tile,
            macs_per_cycle: c.macs_per_cycle,
            noc_width,
            clusters: c.clusters,
            queues: u32::from(c.queues.max(1)),
            queue_depth: u32::from(c.queue_depth.max(1)),
            fp_datapath: false,
        }
    }

    pub fn software_reference_v2() -> Self {
        let mut caps = Self::default();
        caps.dtype_mask = numfmt::SOFTWARE_DTYPE_MASK;
        caps.fp_datapath = true;
        caps
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

pub fn run_gemm_native<D: Device>(
    dev: &mut D, m: u32, n: u32, k: u32, a: &[u8], b: &[u8],
    fmt: ai_tensor_abi::NumFmt, lda: Option<u32>, ldb: Option<u32>, ticket: u32,
) -> Result<(Vec<u8>, Completion), RtError> {
    let caps = dev.caps();
    numfmt::check_format(fmt, caps.dtype_mask)?;
    let lda = lda.unwrap_or(k);
    let ldb = ldb.unwrap_or(k);
    let layout = numfmt::Layout::new(m, n, k, fmt, lda, ldb)?;
    layout.validate(a, b)?;
    if !caps.max_tile().fits(m, n, k) {
        return Err(RtError::Msg("native GEMM exceeds AccTile; ordered FP K-splitting is not supported".into()));
    }
    let pa = dev.alloc(layout.a_bytes)?;
    let pb = dev.alloc(layout.b_bytes)?;
    let pc = dev.alloc(layout.c_bytes)?;
    let pd = dev.alloc(8)?;
    let base = pa.min(pb).min(pc).min(pd);
    let limit = [pa.checked_add(layout.a_bytes as u64), pb.checked_add(layout.b_bytes as u64),
        pc.checked_add(layout.c_bytes as u64), pd.checked_add(8)]
        .into_iter().collect::<Option<Vec<_>>>().ok_or(RtError::BufferOob)?
        .into_iter().max().ok_or(RtError::BufferOob)?;
    dev.program_region(0, Region { base, limit, read: true, write: true })?;
    dev.write_mem(pa, &a[..layout.a_bytes])?;
    dev.write_mem(pb, &b[..layout.b_bytes])?;
    dev.write_mem(pc, &vec![0; layout.c_bytes])?;
    dev.write_mem(pd, &[0; 8])?;
    let mut d = Desc64::gemm(m, n, k).with_ptrs(pa, pb, pc, pd);
    d.flags = fmt.into_flags(d.flags);
    d.ld_ab = lda | (ldb << 16);
    dev.enable(true);
    dev.set_wr_cpl_en(true);
    dev.submit(0, ticket, &d)?;
    let completion = dev.wait(ticket)?;
    if !completion.is_ok() {
        return Err(RtError::Msg(format!("status {}", completion.status)));
    }
    let mut out = vec![0; layout.c_bytes];
    dev.read_mem(pc, &mut out)?;
    Ok((out, completion))
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
    let b_bytes: Vec<u8> = (0..n as usize).flat_map(|j| (0..k as usize).map(move |t| b[t * n as usize + j] as u8)).collect();
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
    fn native_formats_sim_and_mmio() {
        use ai_tensor_abi::NumFmt;
        for (fmt, one) in [
            (NumFmt::Int, vec![1]), (NumFmt::Int4, vec![1]),
            (NumFmt::Fp8E4m3, vec![0x38]), (NumFmt::Fp8E5m2, vec![0x3c]),
            (NumFmt::Fp16, vec![0, 0x3c]), (NumFmt::Bf16, vec![0x80, 0x3f]),
            (NumFmt::Fp32, 1.0f32.to_le_bytes().to_vec()),
        ] {
            let mut sim = SimDevice::with_caps(Caps::software_reference_v2());
            let mut mmio = MmioDevice::software_reference_v2();
            let want = if matches!(fmt, NumFmt::Int | NumFmt::Int4) { 1u32 } else { 0x3f800000 };
            let (a, _) = run_gemm_native(&mut sim, 1, 1, 1, &one, &one, fmt, None, None, 1).unwrap();
            let (b, _) = run_gemm_native(&mut mmio, 1, 1, 1, &one, &one, fmt, None, None, 1).unwrap();
            assert_eq!(a, want.to_le_bytes());
            assert_eq!(a, b);
        }
    }

    #[test]
    fn native_refuses_sp24_and_ungranted() {
        use ai_tensor_abi::NumFmt;
        let mut dev = SimDevice::new();
        assert!(run_gemm_native(&mut dev, 1, 1, 1, &[1], &[1], NumFmt::Int4, None, None, 1).is_err());
        let mut caps = Caps::software_reference_v2();
        caps.dtype_mask = 0xff;
        let mut dev = SimDevice::with_caps(caps);
        assert!(run_gemm_native(&mut dev, 1, 1, 1, &[1], &[1], NumFmt::Sp24, None, None, 1).is_err());
    }

    fn rejects_before_c_write<D: Device>(dev: &mut D) {
        use ai_tensor_abi::{NumFmt, ST_BAD_FMT, ST_BAD_PTR, ST_BAD_VER};
        dev.enable(true);
        dev.set_wr_cpl_en(true);
        dev.program_region(0, Region { base: 0x1000, limit: u64::MAX, read: true, write: true }).unwrap();
        let a = dev.alloc(4).unwrap();
        let b = dev.alloc(4).unwrap();
        let c = dev.alloc(16).unwrap();
        dev.write_mem(a, &[1, 2, 3, 4]).unwrap();
        dev.write_mem(b, &[5, 7, 6, 8]).unwrap();
        dev.write_mem(c, &[0xa5; 16]).unwrap();
        let d = Desc64::gemm(2, 2, 2).with_ptrs(a, b, c, 0);
        for (idx, status) in [ST_BAD_VER, ST_BAD_FMT, ST_BAD_PTR, ST_BAD_PTR, ST_BAD_PTR].into_iter().enumerate() {
            let mut bad = d.clone();
            match idx {
                0 => bad.version = 1,
                1 => bad.flags = NumFmt::Sp24.into_flags(0),
                2 => bad.ld_ab = 1 | (2 << 16),
                3 => bad.ptr_b = u64::MAX - 1,
                _ => bad.ptr_done = 0x1000 + (1 << 24) - 4,
            }
            dev.submit(0, idx as u32 + 30, &bad).unwrap();
            assert_eq!(dev.wait(idx as u32 + 30).unwrap().status, status);
            let mut out = [0; 16];
            dev.read_mem(c, &mut out).unwrap();
            assert_eq!(out, [0xa5; 16]);
        }
    }

    #[test]
    fn invalid_descriptors_leave_c_untouched() {
        rejects_before_c_write(&mut SimDevice::with_caps(Caps::software_reference_v2()));
        rejects_before_c_write(&mut MmioDevice::software_reference_v2());
    }

    fn check_native_descriptor_modes(dev: &mut dyn Device, mask: u16) {
        use ai_tensor_abi::{NumFmt, ST_BAD_FMT};
        dev.enable(true);
        dev.program_region(0, Region { base: 0x1000, limit: u64::MAX, read: true, write: true }).unwrap();
        let a = dev.alloc(4).unwrap();
        let b = dev.alloc(4).unwrap();
        let c = dev.alloc(16).unwrap();
        dev.write_mem(a, &[0x21, 0x03, 0xed, 0x0f]).unwrap();
        dev.write_mem(b, &[0xe3, 0x01, 0x2f, 0x0d]).unwrap();
        let accepted = if mask & 2 != 0 { ST_OK } else { ST_BAD_FMT };
        let cases = [
            (1 << 12, accepted),
            (NumFmt::Int4.into_flags(0), accepted),
            (1 << 8, ST_BAD_FMT),
            (1 << 10, ST_BAD_FMT),
            (2 << 12, ST_BAD_FMT),
            (1 << 14, ST_BAD_FMT),
            (NumFmt::Sp24.into_flags(0), ST_BAD_FMT),
            (NumFmt::Fp16.into_flags(1 << 12), ST_BAD_FMT),
        ];
        for (index, (flags, status)) in cases.into_iter().enumerate() {
            dev.write_mem(c, &[0xa5; 16]).unwrap();
            let mut descriptor = Desc64::gemm(2, 2, 3).with_ptrs(a, b, c, 0);
            descriptor.flags = flags;
            let ticket = 100 + index as u32;
            dev.submit(0, ticket, &descriptor).unwrap();
            assert_eq!(dev.wait(ticket).unwrap().status, status, "mask={mask:x} flags={flags:x}");
            let mut result = [0; 16];
            dev.read_mem(c, &mut result).unwrap();
            if status == ST_OK {
                let expected: Vec<u8> = [2i32, -6, -6, 2].iter().flat_map(|v| v.to_le_bytes()).collect();
                assert_eq!(result.as_slice(), expected.as_slice());
            } else {
                assert_eq!(result, [0xa5; 16]);
            }
        }
    }

    #[test]
    fn native_descriptor_modes_reach_backend_status_and_grants() {
        for mask in [1u16, 2, 3, 0xfb] {
            let mut caps = Caps::software_reference_v2();
            caps.dtype_mask = mask;
            check_native_descriptor_modes(&mut SimDevice::with_caps(caps), mask);
            let mut cap_regs = CapRegs::island_p3_sim_default();
            cap_regs.dtype_mask = mask;
            let mut mmio = MmioDevice::new();
            *mmio.soft_island_mut() = SoftIsland::with_cap(cap_regs, 64);
            mmio.soft_island_mut().set_fp_datapath(true);
            mmio.probe_caps();
            check_native_descriptor_modes(&mut mmio, mask);
        }
    }

    #[test]
    fn native_odd_int4_and_f32_order() {
        use ai_tensor_abi::NumFmt;
        let a = [0x21, 0xf3, 0xfe, 0x08];
        let b = [0x21, 0x03, 0xff, 0x0f, 0x11, 0x01];
        let mut dev = MmioDevice::software_reference_v2();
        let (raw, _) = run_gemm_native(&mut dev, 2, 3, 3, &a, &b, NumFmt::Int4, None, None, 1).unwrap();
        let want: Vec<u8> = [14i32, -6, 6, -28, 11, -11].iter().flat_map(|v| v.to_le_bytes()).collect();
        assert_eq!(raw, want);
        let a: Vec<u8> = [16777216.0f32, 1.0, -16777216.0].iter().flat_map(|v| v.to_le_bytes()).collect();
        let b: Vec<u8> = [1.0f32; 3].iter().flat_map(|v| v.to_le_bytes()).collect();
        let (raw, _) = run_gemm_native(&mut dev, 1, 1, 3, &a, &b, NumFmt::Fp32, None, None, 2).unwrap();
        assert_eq!(raw, [0; 4]);
    }

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
