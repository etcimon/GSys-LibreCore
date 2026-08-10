// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Profile-driven host runtime: job queue drained with submit_mode + wait_policy.
//!
//! Island engine remains single-outstanding (DONE sticky). This queue is the
//! **host** scheduling layer for frameworks — enqueue many GEMMs, drain FIFO.

use crate::{
    run_gemm_s8_stream_ex, wait_with_policy, Device, Profile, Queue, Region, RtError, SubmitMode,
    WaitPolicy,
};
use ai_tensor_abi::{Completion, Desc64, PmuSnapshot, ST_OK};
use std::collections::VecDeque;

/// One queued host job (buffers already on device or host-side refs).
#[derive(Debug, Clone)]
pub struct HostGemmJob {
    pub m: u32,
    pub n: u32,
    pub k: u32,
    pub a: Vec<i8>,
    pub b: Vec<i8>,
    pub irq: bool,
}

/// Result of one drained job.
#[derive(Debug, Clone)]
pub struct HostJobResult {
    pub ticket: u32,
    pub c: Vec<i32>,
    pub completion: Completion,
    pub tiles: u32,
    pub pmu: PmuSnapshot,
}

/// Profile-backed session: ticket allocator + pending queue + drain.
pub struct HostRuntime {
    pub profile: Profile,
    pub submit_mode: SubmitMode,
    pub wait_policy: WaitPolicy,
    queue: Queue,
    pending: VecDeque<HostGemmJob>,
    /// Max pending host jobs (defaults to CAP queue_depth * 4).
    pub max_pending: usize,
}

impl HostRuntime {
    pub fn from_profile(profile: Profile) -> Self {
        let submit_mode = profile.to_submit_mode();
        let wait_policy = profile.to_wait_policy();
        Self {
            profile,
            submit_mode,
            wait_policy,
            queue: Queue::q0(1),
            pending: VecDeque::new(),
            max_pending: 64,
        }
    }

    pub fn pending_len(&self) -> usize {
        self.pending.len()
    }

    pub fn enqueue(&mut self, job: HostGemmJob) -> Result<(), RtError> {
        if self.pending.len() >= self.max_pending {
            return Err(RtError::Msg(format!(
                "host queue full ({})",
                self.max_pending
            )));
        }
        let need_a = (job.m as usize).saturating_mul(job.k as usize);
        let need_b = (job.k as usize).saturating_mul(job.n as usize);
        if job.a.len() < need_a || job.b.len() < need_b {
            return Err(RtError::BufferOob);
        }
        self.pending.push_back(job);
        Ok(())
    }

    pub fn enqueue_gemm_s8(
        &mut self,
        m: u32,
        n: u32,
        k: u32,
        a: &[i8],
        b: &[i8],
    ) -> Result<(), RtError> {
        self.enqueue(HostGemmJob {
            m,
            n,
            k,
            a: a.to_vec(),
            b: b.to_vec(),
            irq: matches!(self.wait_policy, WaitPolicy::IrqThenPoll),
        })
    }

    /// Drain up to `limit` pending jobs (0 = all). Returns results in order.
    pub fn drain<D: Device>(
        &mut self,
        dev: &mut D,
        limit: usize,
    ) -> Result<Vec<HostJobResult>, RtError> {
        let mut out = Vec::new();
        let n = if limit == 0 {
            self.pending.len()
        } else {
            limit.min(self.pending.len())
        };
        for _ in 0..n {
            let job = self.pending.pop_front().unwrap();
            let ticket = self.queue.next_ticket();
            let mut policy = self.wait_policy;
            if job.irq {
                policy = WaitPolicy::IrqThenPoll;
            }
            // Prefer stream path (handles AccTile + accumulate).
            let (c, comp, tiles) = run_gemm_s8_stream_ex(
                dev,
                job.m,
                job.n,
                job.k,
                &job.a,
                &job.b,
                ticket,
                policy,
                self.submit_mode,
            )?;
            if comp.status != ST_OK {
                return Err(RtError::Msg(format!(
                    "host job ticket={} status={}",
                    ticket, comp.status
                )));
            }
            out.push(HostJobResult {
                ticket: comp.ticket,
                c,
                completion: comp,
                tiles,
                pmu: dev.pmu(),
            });
        }
        Ok(out)
    }

    /// Enqueue one GEMM and drain immediately (single-shot convenience).
    pub fn run_one_gemm_s8<D: Device>(
        &mut self,
        dev: &mut D,
        m: u32,
        n: u32,
        k: u32,
        a: &[i8],
        b: &[i8],
    ) -> Result<HostJobResult, RtError> {
        self.enqueue_gemm_s8(m, n, k, a, b)?;
        let mut r = self.drain(dev, 1)?;
        r.pop().ok_or_else(|| RtError::Msg("empty drain".into()))
    }
}

/// Ensure device is enabled with a wide AI-3 region (bring-up default).
pub fn prepare_device<D: Device>(dev: &mut D) -> Result<(), RtError> {
    dev.enable(true);
    dev.set_wr_cpl_en(true);
    dev.program_region(
        0,
        Region {
            base: 0x1000,
            limit: 0x1000 + (1 << 24),
            read: true,
            write: true,
        },
    )?;
    Ok(())
}

/// Submit a single latched/fetch GEMM using host runtime policies (no stream auto-tile).
pub fn submit_one_desc<D: Device>(
    dev: &mut D,
    ticket: u32,
    desc: &Desc64,
    mode: SubmitMode,
    policy: WaitPolicy,
) -> Result<Completion, RtError> {
    match mode {
        SubmitMode::Latch => dev.submit(0, ticket, desc)?,
        SubmitMode::Fetch => dev.submit_fetch(0, ticket, desc)?,
    }
    let pol = match policy {
        WaitPolicy::DmaThenClaim { claim, .. } => WaitPolicy::DmaThenClaim {
            ptr_done: desc.ptr_done,
            claim,
        },
        other => other,
    };
    wait_with_policy(dev, ticket, pol)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{MmioDevice, SimDevice};

    fn profile_sim() -> Profile {
        let mut p = Profile::default();
        p.id = "sim-v0".into();
        p.backend = "sim".into();
        p.wait_policy = "poll".into();
        p.submit_mode = "latch".into();
        p
    }

    #[test]
    fn drain_two_jobs_sim() {
        let mut rt = HostRuntime::from_profile(profile_sim());
        let mut dev = SimDevice::new();
        prepare_device(&mut dev).unwrap();
        let a = vec![1i8, 2, 3, 4];
        let b = vec![5i8, 6, 7, 8];
        rt.enqueue_gemm_s8(2, 2, 2, &a, &b).unwrap();
        rt.enqueue_gemm_s8(2, 2, 2, &a, &b).unwrap();
        assert_eq!(rt.pending_len(), 2);
        let r = rt.drain(&mut dev, 0).unwrap();
        assert_eq!(r.len(), 2);
        assert!(r.iter().all(|x| x.c == vec![19, 22, 43, 50]));
        assert_eq!(rt.pending_len(), 0);
    }

    #[test]
    fn run_one_mmio_fetch() {
        let mut p = profile_sim();
        p.submit_mode = "fetch".into();
        let mut rt = HostRuntime::from_profile(p);
        let mut dev = MmioDevice::new();
        dev.probe_caps();
        prepare_device(&mut dev).unwrap();
        let a = vec![1i8; 16];
        let b = vec![1i8; 16];
        let r = rt.run_one_gemm_s8(&mut dev, 4, 4, 4, &a, &b).unwrap();
        assert!(r.completion.is_ok());
        assert!(r.c.iter().all(|&x| x == 4));
    }
}
