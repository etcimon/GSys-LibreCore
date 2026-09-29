// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Hostless behavioral island: AI-3, optional ref GEMM, completion word.

use crate::{Caps, Device, Region, RtError};
use ai_tensor_abi::{
    Completion, Desc64, OP_GEMM, PmuSnapshot, ST_BAD_OP, ST_BAD_PTR, ST_BAD_QID, ST_BAD_VER,
    ST_DISABLED, ST_OK, CONTRACT_VERSION,
};
use std::collections::HashMap;

const MEM_BASE: u64 = 0x1000;
const MEM_CAP: usize = 16 * 1024 * 1024;

pub struct SimDevice {
    enabled: bool,
    wr_cpl_en: bool,
    caps: Caps,
    regions: [Option<Region>; 4],
    mem: Vec<u8>,
    next_off: usize,
    completions: HashMap<u32, Completion>,
    traces: Vec<crate::format_trace::FormatTrace>,
    last_ticket: u32,
    last_status: u16,
    irq_sticky: bool,
    pmu: PmuSnapshot,
    /// Next submit's completion beat fails after the GEMM result is stored.
    completion_bus_err: bool,
    /// Last value written to the reuse-epoch register. Not used by the dot.
    reuse_epoch: u32,
    /// Low 4 bits of `REG_VA_TURBO_LEVEL`. Not used by the dot.
    va_level_req: u32,
    /// That word, latched when a job completes. Applied nibble is 0.
    pmu_va_level: u32,
    /// Low 5 bits of `REG_VA_TURBO_RECIPE`. Not used by the dot.
    va_recipe_req: u32,
    /// That word, latched when a job completes. Applied id is 0.
    pmu_va_recipe: u32,
    /// Evidence-window claim. Cleared by epoch, level, or recipe writes.
    window_valid: bool,
    /// That bit, latched when a job completes.
    pmu_window: bool,
    /// Exact operand reuse. Off until `set_reuse_en(true)`.
    reuse: crate::reuse::OperandReuse,
    last_read_a: bool,
    last_read_b: bool,
}

impl Default for SimDevice {
    fn default() -> Self {
        Self::new()
    }
}

impl SimDevice {
    pub fn format_traces(&self) -> &[crate::format_trace::FormatTrace] {
        &self.traces
    }

    pub fn new() -> Self {
        Self::with_caps(Caps::default())
    }

    pub fn with_caps(caps: Caps) -> Self {
        // Hostless sim can exercise multi-queue AI-3 isolation even when CAP pin
        // says Queues=1 (island MMIO map limit); keep at least 4 soft regions.
        let mut caps = caps;
        if caps.queues < 4 {
            caps.queues = 4;
        }
        Self {
            enabled: false,
            wr_cpl_en: true,
            caps,
            regions: [None, None, None, None],
            mem: vec![0u8; MEM_CAP],
            next_off: 0,
            completions: HashMap::new(),
            traces: Vec::new(),
            last_ticket: 0,
            last_status: 0,
            irq_sticky: false,
            pmu: PmuSnapshot::default(),
            completion_bus_err: false,
            reuse_epoch: 0,
            va_level_req: 0,
            pmu_va_level: 0,
            va_recipe_req: 0,
            pmu_va_recipe: 0,
            window_valid: false,
            pmu_window: false,
            reuse: crate::reuse::OperandReuse::default(),
            last_read_a: true,
            last_read_b: true,
        }
    }

    pub fn reuse_epoch(&self) -> u32 {
        self.reuse_epoch
    }

    /// Request word. Bits [11:8] are the applied level and are 0.
    pub fn va_turbo_level_word(&self) -> u32 {
        ai_tensor_abi::mmio::va_turbo_level_word(self.va_level_req)
    }

    /// Sticky copy of the request word from the last completed job.
    pub fn pmu_va_turbo_level(&self) -> u32 {
        self.pmu_va_level
    }

    /// Request word. Bits [12:8] are the applied id and are 0.
    pub fn va_turbo_recipe_word(&self) -> u32 {
        ai_tensor_abi::mmio::va_turbo_recipe_word(self.va_recipe_req)
    }

    /// Sticky copy of the recipe request from the last completed job.
    pub fn pmu_va_turbo_recipe(&self) -> u32 {
        self.pmu_va_recipe
    }

    pub fn va_turbo_window(&self) -> bool {
        self.window_valid
    }

    pub fn pmu_va_turbo_window(&self) -> bool {
        self.pmu_window
    }

    /// Whether exact reuse is enabled. A plan with no skip leaves it off.
    pub fn reuse_enabled(&self) -> bool {
        self.reuse.enabled()
    }

    /// Whether the last GEMM read A from memory. A reuse hit is false.
    pub fn reuse_read_a(&self) -> bool {
        self.last_read_a
    }

    /// Whether the last GEMM read B from memory. A reuse hit is false.
    pub fn reuse_read_b(&self) -> bool {
        self.last_read_b
    }

    /// The next completion beat returns SLVERR. The stored word keeps the
    /// GEMM status. The FIFO reports `ST_ERR`.
    pub fn fail_next_completion_bus(&mut self) {
        self.completion_bus_err = true;
    }

    fn store_completion_word(&mut self, desc: &Desc64, word: u64) {
        if desc.ptr_done == 0 || !self.wr_cpl_en || !self.caps.completion_word {
            return;
        }
        let Ok(off) = self.off(desc.ptr_done) else {
            return;
        };
        if off + 8 > self.mem.len() {
            return;
        }
        self.mem[off..off + 8].copy_from_slice(&word.to_le_bytes());
    }

    fn off(&self, addr: u64) -> Result<usize, RtError> {
        if addr < MEM_BASE {
            return Err(RtError::BufferOob);
        }
        let o = (addr - MEM_BASE) as usize;
        if o >= self.mem.len() {
            return Err(RtError::BufferOob);
        }
        Ok(o)
    }

    fn check_ptr(&self, qid: u8, addr: u64, len: u64, need_r: bool, need_w: bool) -> bool {
        if addr == 0 && len == 0 {
            return true;
        }
        let Some(r) = self.regions.get(qid as usize).and_then(|x| *x) else {
            return false;
        };
        r.contains(addr, len.max(1), need_r, need_w)
    }

    fn run_job(&mut self, qid: u8, ticket: u32, d: &Desc64) -> Completion {
        if !self.enabled {
            return Completion {
                ticket,
                status: ST_DISABLED,
            };
        }
        if d.version != CONTRACT_VERSION {
            return Completion {
                ticket,
                status: ST_BAD_VER,
            };
        }
        if d.op != OP_GEMM {
            return Completion {
                ticket,
                status: ST_BAD_OP,
            };
        }
        if !self.caps.acc_tile.fits(d.m, d.n, d.k) {
            return Completion {
                ticket,
                status: ST_BAD_OP,
            };
        }
        let q = if (qid as usize) < self.regions.len() && u32::from(qid) < self.caps.queues {
            qid
        } else {
            return Completion {
                ticket,
                status: ST_BAD_QID,
            };
        };
        if crate::numfmt::check_desc_engine_acc(d, self.caps.dtype_mask, self.caps.fp_datapath, self.caps.accumulate).is_err() {
            return Completion { ticket, status: ai_tensor_abi::ST_BAD_FMT };
        }
        let layout = match crate::numfmt::Layout::from_desc(d) {
            Ok(l) => l,
            Err(_) => return Completion { ticket, status: ST_BAD_PTR },
        };
        let a_len = layout.a_bytes as u64;
        let b_len = layout.b_bytes as u64;
        let c_len = layout.c_bytes as u64;
        if !self.check_ptr(q, d.ptr_a, a_len, true, false)
            || !self.check_ptr(q, d.ptr_b, b_len, true, false)
            || !self.check_ptr(q, d.ptr_c, c_len, false, true)
        {
            return Completion {
                ticket,
                status: ST_BAD_PTR,
            };
        }
        if d.ptr_done != 0
            && self.wr_cpl_en
            && (!self.check_ptr(q, d.ptr_done, 8, false, true)
                || crate::numfmt::memory_range(d.ptr_done, MEM_BASE, 8, self.mem.len()).is_err())
        {
            return Completion {
                ticket,
                status: ST_BAD_PTR,
            };
        }

        let obs = match crate::reuse::execute(
            &mut self.reuse,
            self.reuse_epoch,
            &mut self.mem,
            MEM_BASE,
            d,
            self.caps.compute_ref,
        ) {
            Ok(obs) => obs,
            Err(_) => {
                return Completion {
                    ticket,
                    status: ST_BAD_PTR,
                };
            }
        };
        self.last_read_a = obs.read_a;
        self.last_read_b = obs.read_b;

        // Approximate bus beats for observability (not cycle-accurate RTL PMU).
        // A reuse hit contributes no beats for that operand.
        let bytes_r = (if obs.read_a { a_len } else { 0 }) + (if obs.read_b { b_len } else { 0 });
        let bytes_w = (d.m as u64) * (d.n as u64) * 4;
        let bpb = (self.caps.noc_width / 8).max(1) as u64;
        self.pmu = PmuSnapshot {
            r_beats: ((bytes_r + bpb - 1) / bpb) as u32,
            w_beats: ((bytes_w + bpb - 1) / bpb) as u32,
            cycles: (d.m.saturating_mul(d.n)).max(1), // lower bound: 1 cy/C @ full PeLanes
            gbps_x1000: 0,
        };

        if d.irq() {
            self.irq_sticky = true;
        }
        Completion {
            ticket,
            status: ST_OK,
        }
    }
}

impl Device for SimDevice {
    fn caps(&self) -> Caps {
        self.caps
    }

    fn enable(&mut self, on: bool) {
        self.enabled = on;
    }

    fn set_wr_cpl_en(&mut self, on: bool) {
        self.wr_cpl_en = on;
    }

    fn program_region(&mut self, qid: u8, region: Region) -> Result<(), RtError> {
        let i = qid as usize;
        if i >= self.regions.len() {
            return Err(RtError::BadPtr("qid"));
        }
        self.regions[i] = Some(region);
        Ok(())
    }

    fn alloc(&mut self, len: usize) -> Result<u64, RtError> {
        let align = 64;
        let pad = (align - (self.next_off % align)) % align;
        self.next_off += pad;
        if self.next_off + len > self.mem.len() {
            return Err(RtError::BufferOob);
        }
        let addr = MEM_BASE + self.next_off as u64;
        self.next_off += len;
        Ok(addr)
    }

    fn write_mem(&mut self, addr: u64, data: &[u8]) -> Result<(), RtError> {
        let o = self.off(addr)?;
        if o + data.len() > self.mem.len() {
            return Err(RtError::BufferOob);
        }
        self.mem[o..o + data.len()].copy_from_slice(data);
        Ok(())
    }

    fn read_mem(&mut self, addr: u64, out: &mut [u8]) -> Result<(), RtError> {
        let o = self.off(addr)?;
        if o + out.len() > self.mem.len() {
            return Err(RtError::BufferOob);
        }
        out.copy_from_slice(&self.mem[o..o + out.len()]);
        Ok(())
    }

    fn submit(&mut self, qid: u8, ticket: u32, desc: &Desc64) -> Result<(), RtError> {
        let gemm = self.run_job(qid, ticket, desc);
        let bus_err = self.completion_bus_err;
        self.completion_bus_err = false;
        let post = ai_tensor_abi::completion_post(ticket, gemm.status, bus_err);
        self.store_completion_word(desc, post.word);
        let fifo = Completion {
            ticket,
            status: post.fifo_status,
        };
        self.traces
            .push(crate::format_trace::FormatTrace::from_desc(desc, gemm.status));
        self.last_ticket = ticket;
        self.last_status = fifo.status;
        self.completions.insert(ticket, fifo);
        self.pmu_va_level = ai_tensor_abi::mmio::va_turbo_level_word(self.va_level_req);
        self.pmu_va_recipe = ai_tensor_abi::mmio::va_turbo_recipe_word(self.va_recipe_req);
        self.pmu_window = self.window_valid;
        Ok(())
    }

    fn poll(&mut self, ticket: u32) -> Result<Option<Completion>, RtError> {
        let c = self.completions.get(&ticket).copied();
        // Single sticky IRQ model: observing a completion is enough to drop level.
        // SoftIsland CPL FIFO uses head.irq re-arm instead (MmioDevice).
        if c.is_some() {
            self.irq_sticky = false;
        }
        Ok(c)
    }

    fn poll_completion(&mut self, ticket: u32, claim: bool) -> Result<Option<Completion>, RtError> {
        let completion = self.completions.get(&ticket).copied();
        if claim && completion.is_some() {
            self.irq_sticky = false;
        }
        Ok(completion)
    }

    fn pmu(&self) -> PmuSnapshot {
        self.pmu
    }

    fn irq_pending(&self) -> bool {
        self.irq_sticky
    }

    fn claim_done(&mut self) -> Result<(), RtError> {
        self.irq_sticky = false;
        Ok(())
    }

    fn set_reuse_epoch(&mut self, epoch: u32) -> Result<(), RtError> {
        self.reuse_epoch = epoch;
        self.window_valid = false;
        Ok(())
    }

    fn set_va_turbo_level(&mut self, level: u32) -> Result<(), RtError> {
        self.va_level_req = ai_tensor_abi::mmio::va_turbo_level_word(level);
        self.window_valid = false;
        Ok(())
    }

    fn set_va_turbo_recipe(&mut self, id: u32) -> Result<(), RtError> {
        self.va_recipe_req = ai_tensor_abi::mmio::va_turbo_recipe_word(id);
        self.window_valid = false;
        Ok(())
    }

    fn set_va_turbo_window(&mut self, valid: bool) -> Result<(), RtError> {
        self.window_valid = valid;
        Ok(())
    }

    fn set_reuse_en(&mut self, on: bool) -> Result<(), RtError> {
        self.reuse.set_enabled(on);
        Ok(())
    }

    fn reuse_enabled(&self) -> bool {
        SimDevice::reuse_enabled(self)
    }

    fn reuse_read_a(&self) -> bool {
        SimDevice::reuse_read_a(self)
    }

    fn reuse_read_b(&self) -> bool {
        SimDevice::reuse_read_b(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::run_gemm_s8;

    #[test]
    fn gemm_2x2() {
        let mut dev = SimDevice::new();
        // C = [[1,2],[3,4]] @ [[5,6],[7,8]] wait A 2x2 B 2x2
        let a = [1i8, 2, 3, 4];
        let b = [5i8, 6, 7, 8];
        let (c, comp) = run_gemm_s8(&mut dev, 2, 2, 2, &a, &b, 7).unwrap();
        assert!(comp.is_ok());
        assert_eq!(comp.ticket, 7);
        // row0: 1*5+2*7=19, 1*6+2*8=22
        // row1: 3*5+4*7=43, 3*6+4*8=50
        assert_eq!(c, vec![19, 22, 43, 50]);
        let tr = dev.format_traces();
        assert_eq!(tr.len(), 1);
        assert_eq!(tr[0].numfmt, 0);
        assert_eq!(tr[0].m, 2);
        assert_eq!(tr[0].status, ST_OK);
    }

    #[test]
    fn a_va_turbo_level_keeps_only_the_request_nibble() {
        let mut dev = SimDevice::new();
        dev.set_va_turbo_level(0x0109).unwrap();
        assert_eq!(dev.va_turbo_level_word(), 9);
        assert_eq!(ai_tensor_abi::mmio::va_turbo_level_applied(dev.va_turbo_level_word()), 0);
        let a = [1i8, 2, 3, 4];
        let b = [5i8, 6, 7, 8];
        let (c, comp) = run_gemm_s8(&mut dev, 2, 2, 2, &a, &b, 3).unwrap();
        assert!(comp.is_ok());
        assert_eq!(c, vec![19, 22, 43, 50]);
        assert_eq!(dev.pmu_va_turbo_level(), 9);
        assert_eq!(dev.pmu_va_turbo_level() >> ai_tensor_abi::mmio::VA_TURBO_LEVEL_APPLIED_SHIFT, 0);
        dev.set_va_turbo_recipe(0x0110).unwrap();
        assert_eq!(dev.va_turbo_recipe_word(), 0x10);
        assert_eq!(ai_tensor_abi::mmio::va_turbo_recipe_applied(dev.va_turbo_recipe_word()), 0);
        let (c, comp) = run_gemm_s8(&mut dev, 2, 2, 2, &a, &b, 4).unwrap();
        assert!(comp.is_ok());
        assert_eq!(c, vec![19, 22, 43, 50]);
        assert_eq!(dev.pmu_va_turbo_recipe(), 0x10);
        assert_eq!(ai_tensor_abi::mmio::va_turbo_recipe_applied(dev.pmu_va_turbo_recipe()), 0);
    }

    #[test]
    fn an_evidence_window_clears_when_the_level_changes() {
        let mut dev = SimDevice::new();
        dev.set_va_turbo_window(true).unwrap();
        assert!(dev.va_turbo_window());
        dev.set_va_turbo_level(9).unwrap();
        assert!(!dev.va_turbo_window());
        dev.set_va_turbo_window(true).unwrap();
        let (c, comp) = run_gemm_s8(&mut dev, 2, 2, 2, &[1, 2, 3, 4], &[5, 6, 7, 8], 8).unwrap();
        assert!(comp.is_ok());
        assert_eq!(c, vec![19, 22, 43, 50]);
        assert!(dev.pmu_va_turbo_window());
    }

    use crate::{Device, Region};
    use ai_tensor_abi::Desc64;

    fn resident_device() -> (SimDevice, u64, u64, u64, u64) {
        let mut dev = SimDevice::new();
        dev.enable(true);
        dev.program_region(
            0,
            Region {
                base: 0x1000,
                limit: 0x1000 + (1 << 20),
                read: true,
                write: true,
            },
        )
        .unwrap();
        let pa = dev.alloc(1).unwrap();
        let pb = dev.alloc(1).unwrap();
        let pc = dev.alloc(4).unwrap();
        let pc2 = dev.alloc(4).unwrap();
        dev.write_mem(pa, &[1]).unwrap();
        dev.write_mem(pb, &[2]).unwrap();
        (dev, pa, pb, pc, pc2)
    }

    fn dot(dev: &mut SimDevice, flags: u32, pa: u64, pb: u64, pc: u64, ticket: u32) -> (i32, Completion) {
        let mut d = Desc64::gemm(1, 1, 1).with_ptrs(pa, pb, pc, 0);
        d.flags = flags;
        dev.submit(0, ticket, &d).unwrap();
        let comp = dev.poll(ticket).unwrap().unwrap();
        let mut raw = [0u8; 4];
        dev.read_mem(pc, &mut raw).unwrap();
        (i32::from_le_bytes(raw), comp)
    }

    #[test]
    fn reuse_stays_off_until_enabled_and_a_hit_keeps_the_resident_bytes() {
        use ai_tensor_abi::FLAG_REUSE_B;
        let (mut dev, pa, pb, pc, _) = resident_device();
        let (c, comp) = dot(&mut dev, 0, pa, pb, pc, 1);
        assert!(comp.is_ok());
        assert_eq!(c, 2);
        dev.write_mem(pb, &[9]).unwrap();
        let (c, _) = dot(&mut dev, FLAG_REUSE_B, pa, pb, pc, 2);
        assert_eq!(c, 9);
        assert!(dev.reuse_read_b());

        dev.set_reuse_en(true).unwrap();
        dev.write_mem(pb, &[2]).unwrap();
        let (c, _) = dot(&mut dev, 0, pa, pb, pc, 3);
        assert_eq!(c, 2);
        assert!(dev.reuse_read_b());
        dev.write_mem(pb, &[9]).unwrap();
        let (c, _) = dot(&mut dev, FLAG_REUSE_B, pa, pb, pc, 4);
        assert_eq!(c, 2, "a hit multiplies the resident B");
        assert!(!dev.reuse_read_b());
        dev.set_reuse_epoch(1).unwrap();
        let (c, _) = dot(&mut dev, FLAG_REUSE_B, pa, pb, pc, 5);
        assert_eq!(c, 9, "a new epoch misses");
        assert!(dev.reuse_read_b());
        dev.write_mem(pb, &[4]).unwrap();
        let (c, _) = dot(&mut dev, FLAG_REUSE_B, pa, pb, pc, 6);
        assert_eq!(c, 9);
        assert!(!dev.reuse_read_b());

        let mut d = Desc64::gemm(1, 1, 1).with_ptrs(pa, pb, pc, 0);
        d.flags = FLAG_REUSE_B;
        d.ld_ab = 1 | (2 << 16);
        dev.submit(0, 7, &d).unwrap();
        assert!(dev.reuse_read_b(), "ldb is in the B key");
    }

    #[test]
    fn a_c_overlap_drops_residency_and_a_completion_beat_error_keeps_it() {
        use ai_tensor_abi::FLAG_REUSE_B;
        let (mut dev, pa, pb, pc, pc2) = resident_device();
        dev.set_reuse_en(true).unwrap();
        let (c, _) = dot(&mut dev, 0, pa, pb, pc, 1);
        assert_eq!(c, 2);
        dev.write_mem(pb, &[9]).unwrap();
        let (c, comp) = dot(&mut dev, FLAG_REUSE_B, pa, pb, pb, 2);
        assert!(comp.is_ok());
        assert!(dev.reuse_read_b(), "C on B is not a hit");
        assert_eq!(c, 9);
        dev.write_mem(pb, &[7]).unwrap();
        let (c, _) = dot(&mut dev, FLAG_REUSE_B, pa, pb, pc2, 3);
        assert_eq!(c, 7);
        assert!(dev.reuse_read_b(), "the overlap dropped B");

        dev.write_mem(pb, &[2]).unwrap();
        let (c, _) = dot(&mut dev, 0, pa, pb, pc, 4);
        assert_eq!(c, 2);
        dev.write_mem(pb, &[9]).unwrap();
        dev.fail_next_completion_bus();
        let (c, comp) = dot(&mut dev, FLAG_REUSE_B, pa, pb, pc, 5);
        assert_eq!(comp.status, ai_tensor_abi::ST_ERR);
        assert_eq!(c, 2);
        assert!(!dev.reuse_read_b());
        dev.write_mem(pb, &[4]).unwrap();
        let (c, comp) = dot(&mut dev, FLAG_REUSE_B, pa, pb, pc, 6);
        assert!(comp.is_ok());
        assert_eq!(c, 2, "the completion-beat error kept the resident B");
        assert!(!dev.reuse_read_b());
    }

    #[test]
    fn fast_mask_without_a_float_datapath_refuses_fp32() {
        use ai_tensor_abi::{NumFmt, ST_BAD_FMT};
        let mut caps = Caps::default();
        caps.dtype_mask = crate::format_trace::FAST_DTYPE_MASK;
        assert!(!caps.fp_datapath);
        let mut dev = SimDevice::with_caps(caps);
        dev.enable(true);
        let mut d = Desc64::gemm(1, 1, 1);
        d.flags = NumFmt::Fp32.into_flags(d.flags);
        dev.submit(0, 1, &d).unwrap();
        assert_eq!(dev.poll(1).unwrap().unwrap().status, ST_BAD_FMT);
        let traced = dev.format_traces();
        assert_eq!(traced.len(), 1);
        assert_eq!(traced[0].status, ST_BAD_FMT);
        assert_eq!(traced[0].numfmt, NumFmt::Fp32.abi() as u8);
    }

    #[test]
    fn bad_ptr_no_region() {
        let mut dev = SimDevice::new();
        dev.enable(true);
        let d = Desc64::gemm(1, 1, 1).with_ptrs(0x1000, 0x1000, 0x1000, 0);
        dev.submit(0, 1, &d).unwrap();
        let c = dev.poll(1).unwrap().unwrap();
        assert_eq!(c.status, ST_BAD_PTR);
    }

    #[test]
    fn reject_oversize_dims() {
        let mut dev = SimDevice::new();
        dev.enable(true);
        let big = Desc64::gemm(1025, 1, 1).with_ptrs(0x1000, 0x1000, 0x1000, 0);
        let reg = Region {
            base: 0x1000,
            limit: 0x1000 + (1 << 20),
            read: true,
            write: true,
        };
        dev.program_region(0, reg).unwrap();
        dev.submit(0, 1, &big).unwrap();
        let c = dev.poll(1).unwrap().unwrap();
        assert_eq!(c.status, ST_BAD_OP);
    }

    #[test]
    fn pmu_after_gemm() {
        let mut dev = SimDevice::new();
        let a = [1i8, 2, 3, 4];
        let b = [5i8, 6, 7, 8];
        let (_c, _) = run_gemm_s8(&mut dev, 2, 2, 2, &a, &b, 1).unwrap();
        let p = dev.pmu();
        assert!(p.r_beats > 0 || p.w_beats > 0);
        assert_eq!(p.cycles, 4); // m*n lower bound
    }

    fn tiny_gemm(dev: &mut SimDevice) -> (Desc64, u64) {
        dev.enable(true);
        dev.set_wr_cpl_en(true);
        dev.program_region(
            0,
            Region {
                base: 0x1000,
                limit: 0x1000 + (1 << 20),
                read: true,
                write: true,
            },
        )
        .unwrap();
        let pa = dev.alloc(1).unwrap();
        let pb = dev.alloc(1).unwrap();
        let pc = dev.alloc(4).unwrap();
        let pd = dev.alloc(8).unwrap();
        dev.write_mem(pa, &[1]).unwrap();
        dev.write_mem(pb, &[1]).unwrap();
        dev.write_mem(pc, &[0; 4]).unwrap();
        dev.write_mem(pd, &[0xff; 8]).unwrap();
        (Desc64::gemm(1, 1, 1).with_ptrs(pa, pb, pc, pd), pd)
    }

    #[test]
    fn a_gemm_error_is_stored_in_the_completion_word() {
        let mut dev = SimDevice::new();
        let (mut d, pd) = tiny_gemm(&mut dev);
        d.version = 0;
        dev.submit(0, 36, &d).unwrap();
        let mut raw = [0u8; 8];
        dev.read_mem(pd, &mut raw).unwrap();
        let word = ai_tensor_abi::Completion::from_u64(u64::from_le_bytes(raw));
        assert_eq!(word.ticket, 36);
        assert_eq!(word.status, ST_BAD_VER);
        assert_eq!(dev.poll(36).unwrap().unwrap().status, ST_BAD_VER);
    }

    #[test]
    fn completion_bus_error_leaves_the_gemm_word_and_fails_the_fifo() {
        use crate::policy::{wait_with_policy, WaitPolicy};
        let mut dev = SimDevice::new();
        let (d, pd) = tiny_gemm(&mut dev);
        dev.fail_next_completion_bus();
        dev.submit(0, 42, &d).unwrap();
        let mut raw = [0u8; 8];
        dev.read_mem(pd, &mut raw).unwrap();
        let word = ai_tensor_abi::Completion::from_u64(u64::from_le_bytes(raw));
        assert_eq!(word.ticket, 42);
        assert_eq!(word.status, ST_OK);
        assert_eq!(
            dev.poll(42).unwrap().unwrap().status,
            ai_tensor_abi::ST_ERR
        );
        let got = wait_with_policy(
            &mut dev,
            42,
            WaitPolicy::DmaThenClaim {
                ptr_done: pd,
                claim: true,
            },
        )
        .unwrap();
        assert_eq!(got.ticket, 42);
        assert_eq!(got.status, ai_tensor_abi::ST_ERR);
    }
}
