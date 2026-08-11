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
    last_ticket: u32,
    last_status: u16,
    irq_sticky: bool,
    pmu: PmuSnapshot,
}

impl Default for SimDevice {
    fn default() -> Self {
        Self::new()
    }
}

impl SimDevice {
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
            last_ticket: 0,
            last_status: 0,
            irq_sticky: false,
            pmu: PmuSnapshot::default(),
        }
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

    fn execute_gemm_s8(&mut self, d: &Desc64) -> Result<(), RtError> {
        let m = d.m as usize;
        let n = d.n as usize;
        let k = d.k as usize;
        let lda = d.lda() as usize;
        let ldb = d.ldb() as usize;
        if lda < k || ldb < n {
            return Err(RtError::BadPtr("ld"));
        }
        let a_bytes = m.saturating_mul(lda);
        let b_bytes = k.saturating_mul(ldb);
        let c_bytes = m.saturating_mul(n).saturating_mul(4);
        if !self.check_ptr(0, d.ptr_a, a_bytes as u64, true, false)
            || !self.check_ptr(0, d.ptr_b, b_bytes as u64, true, false)
            || !self.check_ptr(0, d.ptr_c, c_bytes as u64, false, true)
        {
            return Err(RtError::BadPtr("gemm buf"));
        }
        if !self.caps.compute_ref {
            return Ok(());
        }
        let oa = self.off(d.ptr_a)?;
        let ob = self.off(d.ptr_b)?;
        let oc = self.off(d.ptr_c)?;
        for i in 0..m {
            for j in 0..n {
                let mut acc: i32 = 0;
                for t in 0..k {
                    let av = self.mem[oa + i * lda + t] as i8 as i32;
                    let bv = self.mem[ob + t * ldb + j] as i8 as i32;
                    acc += av * bv;
                }
                let out_i = oc + (i * n + j) * 4;
                self.mem[out_i..out_i + 4].copy_from_slice(&acc.to_le_bytes());
            }
        }
        Ok(())
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
        let m = d.m as u64;
        let n = d.n as u64;
        let k = d.k as u64;
        let a_len = m * d.lda() as u64;
        let b_len = k * d.ldb() as u64;
        let c_len = m * n * 4;
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
            && !self.check_ptr(q, d.ptr_done, 8, false, true)
        {
            return Completion {
                ticket,
                status: ST_BAD_PTR,
            };
        }

        if let Err(_) = self.execute_gemm_s8(d) {
            return Completion {
                ticket,
                status: ST_BAD_PTR,
            };
        }

        // Approximate bus beats for observability (not cycle-accurate RTL PMU).
        let bytes_r = (d.m as u64) * (d.lda() as u64) + (d.k as u64) * (d.ldb() as u64);
        let bytes_w = (d.m as u64) * (d.n as u64) * 4;
        let bpb = (self.caps.noc_width / 8).max(1) as u64;
        self.pmu = PmuSnapshot {
            r_beats: ((bytes_r + bpb - 1) / bpb) as u32,
            w_beats: ((bytes_w + bpb - 1) / bpb) as u32,
            cycles: (d.m.saturating_mul(d.n)).max(1), // lower bound: 1 cy/C @ full PeLanes
            gbps_x1000: 0,
        };

        let c = Completion {
            ticket,
            status: ST_OK,
        };
        if d.ptr_done != 0 && self.wr_cpl_en && self.caps.completion_word {
            if let Ok(off) = self.off(d.ptr_done) {
                let w = Completion::make(ticket, ST_OK);
                self.mem[off..off + 8].copy_from_slice(&w.to_le_bytes());
            }
        }
        if d.irq() {
            self.irq_sticky = true;
        }
        c
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
        let c = self.run_job(qid, ticket, desc);
        self.last_ticket = ticket;
        self.last_status = c.status;
        self.completions.insert(ticket, c);
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
        let big = Desc64::gemm(257, 1, 1).with_ptrs(0x1000, 0x1000, 0x1000, 0);
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
}
