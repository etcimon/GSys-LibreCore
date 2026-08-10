// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Capability-driven MMIO path for ai_island (M5).
//!
//! - [`MmioBus`]: abstract 32-bit register access at island-relative offsets
//! - [`SoftIsland`]: hostless register + memory model (doorbell executes GEMM)
//! - [`MmioDevice`]: [`Device`] that programs AI-3 / desc / doorbell only via MMIO
//!
//! Real UIO/`/dev/mem` mapping is feature `linux-mmio` (see [`linux`] module).

use crate::{Caps, Device, Region, RtError};
use ai_tensor_abi::{
    mmio, CapRegs, Completion, Desc64, PmuSnapshot, ST_BAD_OP, ST_BAD_PTR, ST_BAD_QID, ST_BAD_VER,
    ST_DISABLED, ST_OK, ST_ERR, CONTRACT_VERSION, DESC_BYTES, OP_GEMM,
};
use std::collections::VecDeque;

const MEM_BASE: u64 = 0x1000;
const MEM_CAP: usize = 16 * 1024 * 1024;
const NUM_QUEUES: usize = 4;

/// 32-bit island register bus (offsets are absolute within the 4 KiB window).
pub trait MmioBus {
    fn read32(&mut self, off: u16) -> u32;
    fn write32(&mut self, off: u16, val: u32);
}

/// Probe CAP window through any bus (11 words from 0x00).
pub fn probe_cap_regs(bus: &mut dyn MmioBus) -> CapRegs {
    let mut w = [0u32; 11];
    for i in 0..11 {
        w[i] = bus.read32((i as u16) * 4);
    }
    CapRegs::from_words(&w).unwrap_or_else(CapRegs::island_p3_sim_default)
}

pub fn read_pmu(bus: &mut dyn MmioBus) -> PmuSnapshot {
    PmuSnapshot::from_words(
        bus.read32(mmio::PMU_R_BEATS),
        bus.read32(mmio::PMU_W_BEATS),
        bus.read32(mmio::PMU_CYCLES),
        bus.read32(mmio::PMU_GBPS_X1000),
    )
}

/// Hostless island: CAP/CTL/regions/desc/doorbell + private DRAM for buffers.
pub struct SoftIsland {
    // CAP (fixed at construct)
    cap: CapRegs,
    noc_width: u32,
    // CTL
    enable: bool,
    wr_cpl_en: bool,
    // status
    busy: bool,
    last_status: u16,
    // doorbell sticky state
    done_sticky: bool,
    irq_sticky: bool,
    done_ticket: u32,
    done_status: u16,
    db_qid: u8,
    db_ticket: u32,
    desc_ptr: u64,
    desc_words: [u32; 16],
    // regions: base, limit, perm (bit0 R, bit1 W) — committed on perm write
    base: [u64; NUM_QUEUES],
    limit: [u64; NUM_QUEUES],
    perm: [u8; NUM_QUEUES],
    region_live: [bool; NUM_QUEUES],
    // PMU
    pmu: PmuSnapshot,
    // memory
    mem: Vec<u8>,
    next_off: usize,
    // last completion for Device::poll convenience
    last_comp: Option<Completion>,
    /// Software completion history (CAP.queue_depth). Models a future HW FIFO so
    /// sequential tickets remain pollable after DONE sticky advances.
    comp_history: VecDeque<Completion>,
}

impl Default for SoftIsland {
    fn default() -> Self {
        Self::new()
    }
}

impl SoftIsland {
    pub fn new() -> Self {
        Self::with_cap(CapRegs::island_p3_sim_default(), 64)
    }

    pub fn with_cap(cap: CapRegs, noc_width: u32) -> Self {
        Self {
            cap,
            noc_width,
            enable: false,
            wr_cpl_en: true,
            busy: false,
            last_status: 0,
            done_sticky: false,
            irq_sticky: false,
            done_ticket: 0,
            done_status: 0,
            db_qid: 0,
            db_ticket: 0,
            desc_ptr: 0,
            desc_words: [0; 16],
            base: [0; NUM_QUEUES],
            limit: [0; NUM_QUEUES],
            perm: [0; NUM_QUEUES],
            region_live: [false; NUM_QUEUES],
            pmu: PmuSnapshot::default(),
            mem: vec![0u8; MEM_CAP],
            next_off: 0,
            last_comp: None,
            comp_history: VecDeque::new(),
        }
    }

    pub fn caps_from_cap(&self) -> Caps {
        let mut c = Caps::from_cap_regs(self.cap, self.noc_width);
        c.wr_cpl_en = self.wr_cpl_en;
        c.compute_ref = true;
        c
    }

    fn history_cap(&self) -> usize {
        self.cap.queue_depth.max(1) as usize
    }

    fn push_history(&mut self, c: Completion) {
        self.comp_history.push_back(c);
        let cap = self.history_cap().max(4);
        while self.comp_history.len() > cap {
            self.comp_history.pop_front();
        }
    }

    /// Find a past completion by ticket (does not clear DONE sticky).
    pub fn history_lookup(&self, ticket: u32) -> Option<Completion> {
        self.comp_history.iter().rev().find(|c| c.ticket == ticket).copied()
    }

    fn cap_word(&self, word_idx: u16) -> u32 {
        // Mirror g6lc_ai_cap_window packing
        match word_idx {
            0 => u32::from(self.cap.version),
            1 => self.cap.clusters,
            2 => self.cap.macs_per_cycle,
            3 => self.cap.clock_khz,
            4 => self.cap.sram_bytes,
            5 => {
                // log2 pack: rebuild from AccTile (assume power-of-two)
                let lm = self.cap.acc_tile.m.trailing_zeros();
                let ln = self.cap.acc_tile.n.trailing_zeros();
                let lk = self.cap.acc_tile.k.trailing_zeros();
                lm | (ln << 4) | (lk << 8)
            }
            6 => u32::from(self.cap.dram_nameplate_gbps)
                | (u32::from(self.cap.dram_meas_milli_gbps) << 16),
            7 => u32::from(self.cap.queues) | (u32::from(self.cap.queue_depth) << 16),
            8 => 0,
            9 => 0,
            10 => u32::from(self.cap.dtype_mask),
            _ => 0,
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

    fn region_ok(&self, qid: u8, addr: u64, len: u64, need_r: bool, need_w: bool) -> bool {
        let i = qid as usize;
        if i >= NUM_QUEUES || !self.region_live[i] {
            return false;
        }
        let r = Region {
            base: self.base[i],
            limit: self.limit[i],
            read: self.perm[i] & 1 != 0,
            write: self.perm[i] & 2 != 0,
        };
        r.contains(addr, len.max(1), need_r, need_w)
    }

    fn execute_desc(&mut self, qid: u8, ticket: u32) {
        let mut bytes = [0u8; DESC_BYTES];
        for i in 0..16 {
            bytes[i * 4..i * 4 + 4].copy_from_slice(&self.desc_words[i].to_le_bytes());
        }
        let d = match Desc64::unpack(&bytes) {
            Ok(x) => x,
            Err(_) => {
                self.complete(ticket, ST_ERR, false);
                return;
            }
        };

        if !self.enable {
            self.complete(ticket, ST_DISABLED, false);
            return;
        }
        // Island map: region windows 0x0120+q*0x20 collide with desc @0x0140 for q≥1
        // when Queues=1 (live CAP). Reject foreign qids early.
        let nq = self.cap.queues.max(1) as u8;
        if qid >= nq {
            self.complete(ticket, ST_BAD_QID, false);
            return;
        }
        if d.version != CONTRACT_VERSION {
            self.complete(ticket, ST_BAD_VER, false);
            return;
        }
        if d.op != OP_GEMM {
            self.complete(ticket, ST_BAD_OP, false);
            return;
        }
        if !self.cap.acc_tile.fits(d.m, d.n, d.k) {
            self.complete(ticket, ST_BAD_OP, false);
            return;
        }

        let m = d.m as u64;
        let n = d.n as u64;
        let k = d.k as u64;
        let a_len = m * d.lda() as u64;
        let b_len = k * d.ldb() as u64;
        let c_len = m * n * 4;
        if !self.region_ok(qid, d.ptr_a, a_len, true, false)
            || !self.region_ok(qid, d.ptr_b, b_len, true, false)
            || !self.region_ok(qid, d.ptr_c, c_len, false, true)
        {
            self.complete(ticket, ST_BAD_PTR, false);
            return;
        }
        if d.ptr_done != 0
            && self.wr_cpl_en
            && !self.region_ok(qid, d.ptr_done, 8, false, true)
        {
            self.complete(ticket, ST_BAD_PTR, false);
            return;
        }

        if let Err(_) = self.run_gemm_ref(&d) {
            self.complete(ticket, ST_BAD_PTR, false);
            return;
        }

        // PMU estimate
        let bytes_r = a_len + b_len;
        let bytes_w = c_len;
        let bpb = (self.noc_width / 8).max(1) as u64;
        self.pmu = PmuSnapshot {
            r_beats: ((bytes_r + bpb - 1) / bpb) as u32,
            w_beats: ((bytes_w + bpb - 1) / bpb) as u32,
            cycles: d.m.saturating_mul(d.n).max(1),
            gbps_x1000: 0,
        };
        // Reflect measured milli into CAP high half for probe
        self.cap.dram_meas_milli_gbps = 0;

        if d.ptr_done != 0 && self.wr_cpl_en {
            if let Ok(off) = self.off(d.ptr_done) {
                let w = Completion::make(ticket, ST_OK);
                self.mem[off..off + 8].copy_from_slice(&w.to_le_bytes());
            }
        }
        self.complete(ticket, ST_OK, d.irq());
    }

    fn run_gemm_ref(&mut self, d: &Desc64) -> Result<(), RtError> {
        let m = d.m as usize;
        let n = d.n as usize;
        let k = d.k as usize;
        let lda = d.lda() as usize;
        let ldb = d.ldb() as usize;
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

    fn complete(&mut self, ticket: u32, status: u16, irq: bool) {
        // FIFO push (oldest-first head); matches g6lc_ai_cpl_fifo
        let c = Completion { ticket, status };
        self.push_history(c);
        self.last_comp = Some(c);
        self.last_status = status;
        self.busy = false;
        self.refresh_done_head(irq);
    }

    /// After push/pop: expose FIFO head on DONE/TICKET/DSTATUS and IRQ.
    fn refresh_done_head(&mut self, new_irq: bool) {
        if let Some(front) = self.comp_history.front().copied() {
            self.done_sticky = true;
            self.done_ticket = front.ticket;
            self.done_status = front.status;
            // Level IRQ if head requested IRQ, or any pending with sticky flag
            if new_irq {
                self.irq_sticky = true;
            }
            // Head-driven: if no entry left with irq intent, clear after pop path
        } else {
            self.done_sticky = false;
            self.irq_sticky = false;
        }
    }

    fn claim_pop(&mut self) {
        let _ = self.comp_history.pop_front();
        // Recompute irq from remaining: SoftIsland stores only last irq sticky;
        // clear IRQ on claim like RTL head pop (host re-sees if next head has FLAG_IRQ).
        self.irq_sticky = false;
        self.refresh_done_head(false);
        // Restore irq if we tracked per-entry — SoftIsland uses coarse sticky:
        // re-set if any remaining completion was from IRQ jobs (approximate: keep false
        // until next IRQ complete; matches single-job smokes and sequential claim).
    }

    fn doorbell(&mut self, val: u32) {
        self.db_qid = (val & 0xff) as u8;
        self.db_ticket = (val >> 8) & 0x007f_ffff;
        let fetch = (val >> 31) & 1 != 0;
        if fetch {
            // DMA fetch from desc_ptr into latch then submit
            if self.desc_ptr == 0 {
                self.complete(self.db_ticket, ST_ERR, false);
                return;
            }
            if let Ok(off) = self.off(self.desc_ptr) {
                if off + DESC_BYTES <= self.mem.len() {
                    for i in 0..16 {
                        let b = &self.mem[off + i * 4..off + i * 4 + 4];
                        self.desc_words[i] = u32::from_le_bytes(b.try_into().unwrap());
                    }
                    self.execute_desc(self.db_qid, self.db_ticket);
                    return;
                }
            }
            self.complete(self.db_ticket, ST_ERR, false);
            return;
        }
        self.execute_desc(self.db_qid, self.db_ticket);
    }
}

impl MmioBus for SoftIsland {
    fn read32(&mut self, off: u16) -> u32 {
        if off < 0x100 {
            return self.cap_word(off / 4);
        }
        match off {
            0x0100 => u32::from(self.enable) | (u32::from(self.wr_cpl_en) << 1),
            0x0104 => {
                (u32::from(self.last_status) << 16)
                    | u32::from(self.busy)
            }
            0x0108 => (self.db_ticket << 8) | u32::from(self.db_qid),
            0x010C => u32::from(self.done_sticky),
            0x0110 => self.done_ticket,
            0x0114 => u32::from(self.done_status),
            0x0118 => self.desc_ptr as u32,
            0x011C => (self.desc_ptr >> 32) as u32,
            0x0180 => self.pmu.r_beats,
            0x0184 => self.pmu.w_beats,
            0x0188 => self.pmu.cycles,
            0x018C => self.pmu.gbps_x1000,
            o if (0x0140..0x0180).contains(&o) => self.desc_words[((o - 0x0140) / 4) as usize],
            o if (0x0120..0x0140).contains(&o) => {
                let q = ((o - 0x0120) / 0x20) as usize;
                let slot = ((o - 0x0120) % 0x20) / 4;
                if q >= NUM_QUEUES {
                    return 0;
                }
                match slot {
                    0 => self.base[q] as u32,
                    1 => (self.base[q] >> 32) as u32,
                    2 => self.limit[q] as u32,
                    3 => (self.limit[q] >> 32) as u32,
                    4 => u32::from(self.perm[q]),
                    _ => 0,
                }
            }
            _ => 0,
        }
    }

    fn write32(&mut self, off: u16, val: u32) {
        match off {
            0x0100 => {
                self.enable = val & 1 != 0;
                self.wr_cpl_en = (val >> 1) & 1 != 0;
            }
            0x0108 => self.doorbell(val),
            0x010C => {
                if val & 1 != 0 {
                    // Claim / pop CPL FIFO head (g6lc_ai_cpl_fifo)
                    self.claim_pop();
                }
            }
            0x0118 => {
                self.desc_ptr = (self.desc_ptr & !0xffff_ffff) | u64::from(val);
            }
            0x011C => {
                self.desc_ptr = (self.desc_ptr & 0xffff_ffff) | (u64::from(val) << 32);
            }
            o if (0x0140..0x0180).contains(&o) => {
                self.desc_words[((o - 0x0140) / 4) as usize] = val;
            }
            o if (0x0120..0x0140).contains(&o) => {
                let q = ((o - 0x0120) / 0x20) as usize;
                let slot = ((o - 0x0120) % 0x20) / 4;
                if q >= NUM_QUEUES {
                    return;
                }
                match slot {
                    0 => {
                        self.base[q] = (self.base[q] & !0xffff_ffff) | u64::from(val);
                    }
                    1 => {
                        self.base[q] = (self.base[q] & 0xffff_ffff) | (u64::from(val) << 32);
                    }
                    2 => {
                        self.limit[q] = (self.limit[q] & !0xffff_ffff) | u64::from(val);
                    }
                    3 => {
                        self.limit[q] = (self.limit[q] & 0xffff_ffff) | (u64::from(val) << 32);
                    }
                    4 => {
                        self.perm[q] = (val & 3) as u8;
                        self.region_live[q] = true; // commit on perm write
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
}

/// Device API over island MMIO protocol (uses SoftIsland as bus + memory).
pub struct MmioDevice {
    island: SoftIsland,
    cached_caps: Caps,
}

impl Default for MmioDevice {
    fn default() -> Self {
        Self::new()
    }
}

impl MmioDevice {
    pub fn new() -> Self {
        let island = SoftIsland::new();
        let cached_caps = island.caps_from_cap();
        Self {
            island,
            cached_caps,
        }
    }

    /// Re-probe CAP through MMIO (as a real backend would after map).
    pub fn probe_caps(&mut self) -> Caps {
        let cap = probe_cap_regs(&mut self.island);
        let noc = self.island.noc_width;
        let mut c = Caps::from_cap_regs(cap, noc);
        // wr_cpl from CTL after enable is separate; default true until CTL written
        c.wr_cpl_en = self.island.wr_cpl_en;
        c.compute_ref = true;
        self.cached_caps = c;
        c
    }

    pub fn soft_island_mut(&mut self) -> &mut SoftIsland {
        &mut self.island
    }
}

impl Device for MmioDevice {
    fn caps(&self) -> Caps {
        self.cached_caps
    }

    fn enable(&mut self, on: bool) {
        let mut v = self.island.read32(mmio::CTL);
        if on {
            v |= mmio::CTL_ENABLE;
        } else {
            v &= !mmio::CTL_ENABLE;
        }
        self.island.write32(mmio::CTL, v);
    }

    fn set_wr_cpl_en(&mut self, on: bool) {
        let mut v = self.island.read32(mmio::CTL);
        if on {
            v |= mmio::CTL_WR_CPL_EN;
        } else {
            v &= !mmio::CTL_WR_CPL_EN;
        }
        self.island.write32(mmio::CTL, v);
        self.cached_caps.wr_cpl_en = on;
    }

    fn program_region(&mut self, qid: u8, region: Region) -> Result<(), RtError> {
        if qid as usize >= NUM_QUEUES {
            return Err(RtError::BadPtr("qid"));
        }
        // Live map: only q0 fits before desc latch @0x0140 (Queues=1).
        let nq = self.cached_caps.queues.max(1);
        if u32::from(qid) >= nq {
            return Err(RtError::BadPtr("qid exceeds CAP.queues / MMIO map"));
        }
        let base_off = mmio::REG0 + u16::from(qid) * 0x20;
        self.island
            .write32(base_off, region.base as u32);
        self.island
            .write32(base_off + 4, (region.base >> 32) as u32);
        self.island
            .write32(base_off + 8, region.limit as u32);
        self.island
            .write32(base_off + 12, (region.limit >> 32) as u32);
        let mut perm = 0u32;
        if region.read {
            perm |= 1;
        }
        if region.write {
            perm |= 2;
        }
        // commit
        self.island.write32(base_off + 16, perm);
        Ok(())
    }

    fn alloc(&mut self, len: usize) -> Result<u64, RtError> {
        let align = 64;
        let pad = (align - (self.island.next_off % align)) % align;
        self.island.next_off += pad;
        if self.island.next_off + len > self.island.mem.len() {
            return Err(RtError::BufferOob);
        }
        let addr = MEM_BASE + self.island.next_off as u64;
        self.island.next_off += len;
        Ok(addr)
    }

    fn write_mem(&mut self, addr: u64, data: &[u8]) -> Result<(), RtError> {
        let o = self.island.off(addr)?;
        if o + data.len() > self.island.mem.len() {
            return Err(RtError::BufferOob);
        }
        self.island.mem[o..o + data.len()].copy_from_slice(data);
        Ok(())
    }

    fn read_mem(&mut self, addr: u64, out: &mut [u8]) -> Result<(), RtError> {
        let o = self.island.off(addr)?;
        if o + out.len() > self.island.mem.len() {
            return Err(RtError::BufferOob);
        }
        out.copy_from_slice(&self.island.mem[o..o + out.len()]);
        Ok(())
    }

    fn submit(&mut self, qid: u8, ticket: u32, desc: &Desc64) -> Result<(), RtError> {
        // Latch 64 B descriptor at 0x140
        let b = desc.pack();
        for i in 0..16 {
            let w = u32::from_le_bytes(b[i * 4..i * 4 + 4].try_into().unwrap());
            self.island.write32(mmio::DESC + (i as u16) * 4, w);
        }
        // Doorbell: ticket[30:8] | qid[7:0], bit31=0 latch path
        let db = (ticket & 0x00ff_ffff) << 8 | u32::from(qid);
        self.island.write32(mmio::DOORBELL, db);
        Ok(())
    }

    fn submit_fetch(&mut self, qid: u8, ticket: u32, desc: &Desc64) -> Result<(), RtError> {
        // Place packed desc in device memory, program desc_ptr, doorbell FETCH.
        let packed = desc.pack();
        let addr = self.alloc(DESC_BYTES)?;
        self.write_mem(addr, &packed)?;
        self.island
            .write32(mmio::DESC_PTR_LO, addr as u32);
        self.island
            .write32(mmio::DESC_PTR_HI, (addr >> 32) as u32);
        let db = ((ticket & 0x007f_ffff) << 8) | u32::from(qid) | mmio::DOORBELL_FETCH;
        self.island.write32(mmio::DOORBELL, db);
        Ok(())
    }

    fn poll(&mut self, ticket: u32) -> Result<Option<Completion>, RtError> {
        let done = self.island.read32(mmio::DONE) & 1 != 0;
        if done {
            let t = self.island.read32(mmio::TICKET);
            let st = (self.island.read32(mmio::DSTATUS) & 0xffff) as u16;
            if t == ticket {
                // SW clears done sticky after claim (PLIC-like discipline)
                self.island.write32(mmio::DONE, 1);
                return Ok(Some(Completion {
                    ticket: t,
                    status: st,
                }));
            }
            // Sticky is a different ticket — fall through to history
            if let Some(c) = self.island.last_comp {
                if c.ticket == ticket {
                    return Ok(Some(c));
                }
            }
        }
        // Completion history: sequential tickets remain pollable after sticky moves on
        Ok(self.island.history_lookup(ticket))
    }

    fn pmu(&self) -> PmuSnapshot {
        self.island.pmu
    }

    fn irq_pending(&self) -> bool {
        self.island.irq_sticky
    }

    fn claim_done(&mut self) -> Result<(), RtError> {
        // Pop CPL FIFO head (DONE write bit0)
        self.island.write32(mmio::DONE, 1);
        Ok(())
    }

    fn wait(&mut self, ticket: u32) -> Result<Completion, RtError> {
        // SoftIsland is synchronous on doorbell — one poll after submit is enough
        for _ in 0..16 {
            if let Some(c) = self.poll(ticket)? {
                return Ok(c);
            }
        }
        Err(RtError::Timeout)
    }
}


// ---------------------------------------------------------------------------
// Mapped register window (file-backed always; UIO on Linux with feature)
// ---------------------------------------------------------------------------

/// 4 KiB (or larger) volatile register window as `MmioBus`.
///
/// - **File-backed:** portable CI / bring-up without hardware.
/// - **Linux UIO/`/dev/mem`:** feature `linux-mmio` + `MappedWindow::open_linux`.
pub struct MappedWindow {
    map: MemMap,
    len: usize,
}

enum MemMap {
    Vec(Vec<u8>),
    #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
    Mmap {
        ptr: *mut u8,
        len: usize,
    },
}

// Safety: exclusive owner of the mapping
unsafe impl Send for MappedWindow {}

impl MappedWindow {
    pub const ISLAND_WINDOW: usize = 4096;

    /// Portable zeroed window (tests / soft bring-up).
    pub fn zeros(len: usize) -> Self {
        let len = len.max(Self::ISLAND_WINDOW);
        Self {
            map: MemMap::Vec(vec![0u8; len]),
            len,
        }
    }

    /// File-backed window (create/truncate `path` to `len` bytes).
    pub fn open_file(path: &std::path::Path, len: usize) -> Result<Self, RtError> {
        use std::fs::OpenOptions;
        use std::io::{Read, Seek, SeekFrom, Write};
        let len = len.max(Self::ISLAND_WINDOW);
        let mut f = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)
            .map_err(|e| RtError::Msg(format!("open_file: {e}")))?;
        f.set_len(len as u64)
            .map_err(|e| RtError::Msg(format!("set_len: {e}")))?;
        let mut buf = vec![0u8; len];
        f.seek(SeekFrom::Start(0))
            .map_err(|e| RtError::Msg(format!("seek: {e}")))?;
        // ensure zeros
        f.write_all(&buf)
            .map_err(|e| RtError::Msg(format!("write: {e}")))?;
        f.seek(SeekFrom::Start(0))
            .map_err(|e| RtError::Msg(format!("seek2: {e}")))?;
        let _ = f.read(&mut buf);
        Ok(Self {
            map: MemMap::Vec(buf),
            len,
        })
    }

    /// Linux: try UIO then optional `/dev/mem` (requires privileges).
    ///
    /// Env:
    /// - `AI_TENSOR_UIO` — path to UIO device (default `/dev/uio0`)
    /// - `AI_TENSOR_MMIO_BASE` — phys base for `/dev/mem` (e.g. `0x40000000`)
    #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
    pub fn open_linux() -> Result<Self, RtError> {
        if let Ok(p) = std::env::var("AI_TENSOR_UIO") {
            return Self::open_uio(std::path::Path::new(&p));
        }
        if std::path::Path::new("/dev/uio0").exists() {
            if let Ok(w) = Self::open_uio(std::path::Path::new("/dev/uio0")) {
                return Ok(w);
            }
        }
        if let Ok(base) = std::env::var("AI_TENSOR_MMIO_BASE") {
            let base = u64::from_str_radix(base.trim_start_matches("0x"), 16)
                .or_else(|_| base.parse::<u64>())
                .map_err(|e| RtError::Msg(format!("bad AI_TENSOR_MMIO_BASE: {e}")))?;
            return Self::open_dev_mem(base, Self::ISLAND_WINDOW);
        }
        Err(RtError::Msg(
            "linux-mmio: set AI_TENSOR_UIO or AI_TENSOR_MMIO_BASE, or provide /dev/uio0".into(),
        ))
    }

    #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
    pub fn open_uio(path: &std::path::Path) -> Result<Self, RtError> {
        use std::fs::OpenOptions;
        use std::os::unix::io::AsRawFd;
        let f = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .map_err(|e| RtError::Msg(format!("uio open {}: {e}", path.display())))?;
        let len = Self::ISLAND_WINDOW;
        let ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                f.as_raw_fd(),
                0,
            )
        };
        if ptr == libc::MAP_FAILED {
            return Err(RtError::Msg(format!(
                "mmap uio failed: {}",
                std::io::Error::last_os_error()
            )));
        }
        // leak fd intentionally while map lives — hold File in a box via forget path:
        // keep fd open by leaking the File
        std::mem::forget(f);
        Ok(Self {
            map: MemMap::Mmap {
                ptr: ptr as *mut u8,
                len,
            },
            len,
        })
    }

    #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
    pub fn open_dev_mem(phys: u64, len: usize) -> Result<Self, RtError> {
        use std::fs::OpenOptions;
        use std::os::unix::io::AsRawFd;
        let f = OpenOptions::new()
            .read(true)
            .write(true)
            .open("/dev/mem")
            .map_err(|e| RtError::Msg(format!("/dev/mem open: {e}")))?;
        let ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                f.as_raw_fd(),
                phys as i64,
            )
        };
        if ptr == libc::MAP_FAILED {
            return Err(RtError::Msg(format!(
                "mmap /dev/mem: {}",
                std::io::Error::last_os_error()
            )));
        }
        std::mem::forget(f);
        Ok(Self {
            map: MemMap::Mmap {
                ptr: ptr as *mut u8,
                len,
            },
            len,
        })
    }

    fn slice(&self) -> &[u8] {
        match &self.map {
            MemMap::Vec(v) => v,
            #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
            MemMap::Mmap { ptr, len } => unsafe { std::slice::from_raw_parts(*ptr, *len) },
        }
    }

    fn slice_mut(&mut self) -> &mut [u8] {
        match &mut self.map {
            MemMap::Vec(v) => v,
            #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
            MemMap::Mmap { ptr, len } => unsafe { std::slice::from_raw_parts_mut(*ptr, *len) },
        }
    }

    pub fn len(&self) -> usize {
        self.len
    }
}

impl Drop for MappedWindow {
    fn drop(&mut self) {
        #[cfg(all(feature = "linux-mmio", target_os = "linux"))]
        if let MemMap::Mmap { ptr, len } = self.map {
            unsafe {
                libc::munmap(ptr as *mut libc::c_void, len);
            }
        }
    }
}

impl MmioBus for MappedWindow {
    fn read32(&mut self, off: u16) -> u32 {
        let o = off as usize;
        if o + 4 > self.len {
            return 0;
        }
        let s = self.slice();
        u32::from_le_bytes(s[o..o + 4].try_into().unwrap())
    }

    fn write32(&mut self, off: u16, val: u32) {
        let o = off as usize;
        if o + 4 > self.len {
            return;
        }
        let s = self.slice_mut();
        s[o..o + 4].copy_from_slice(&val.to_le_bytes());
    }
}

/// Seed a MappedWindow CAP region with island_p3 defaults (file-backed bring-up).
pub fn seed_cap_island_p3(bus: &mut dyn MmioBus) {
    let c = CapRegs::island_p3_sim_default();
    let acc = 8u32 | (8 << 4) | (8 << 8);
    bus.write32(0x00, u32::from(c.version));
    bus.write32(0x04, c.clusters);
    bus.write32(0x08, c.macs_per_cycle);
    bus.write32(0x0c, c.clock_khz);
    bus.write32(0x10, c.sram_bytes);
    bus.write32(0x14, acc);
    bus.write32(0x18, u32::from(c.dram_nameplate_gbps));
    bus.write32(0x1c, u32::from(c.queues) | (u32::from(c.queue_depth) << 16));
    bus.write32(0x28, u32::from(c.dtype_mask));
}


#[cfg(test)]
mod tests {
    use super::*;
    use ai_tensor_abi::AccTile;
    use crate::run_gemm_s8;

    #[test]
    fn cap_probe_acc_tile_256() {
        let mut dev = MmioDevice::new();
        let c = dev.probe_caps();
        assert_eq!(c.acc_tile, AccTile::ISLAND_P3_DEFAULT);
        assert_eq!(c.macs_per_cycle, 256);
        assert_eq!(c.noc_width, 64);
    }

    #[test]
    fn mmio_gemm_2x2() {
        let mut dev = MmioDevice::new();
        dev.probe_caps();
        let a = [1i8, 2, 3, 4];
        let b = [5i8, 6, 7, 8];
        let (c, comp) = run_gemm_s8(&mut dev, 2, 2, 2, &a, &b, 42).unwrap();
        assert!(comp.is_ok());
        assert_eq!(comp.ticket, 42);
        assert_eq!(c, vec![19, 22, 43, 50]);
        let p = dev.pmu();
        assert!(p.cycles >= 4);
        assert!(p.r_beats > 0);
    }

    #[test]
    fn mmio_fetch_doorbell() {
        let mut dev = MmioDevice::new();
        dev.probe_caps();
        dev.enable(true);
        dev.set_wr_cpl_en(true);
        let reg = Region {
            base: 0x1000,
            limit: 0x1000 + (1 << 20),
            read: true,
            write: true,
        };
        dev.program_region(0, reg).unwrap();
        let desc_addr = dev.alloc(64).unwrap();
        // Write A/B/C/done at fixed slots by alloc
        let pa = dev.alloc(4).unwrap();
        let pbb = dev.alloc(4).unwrap();
        let pc = dev.alloc(16).unwrap();
        let pd = dev.alloc(8).unwrap();
        // rebuild desc with real ptrs
        let d = Desc64::gemm(2, 2, 2).with_ptrs(pa, pbb, pc, pd);
        let pb = d.pack();
        dev.write_mem(desc_addr, &pb).unwrap();
        dev.write_mem(pa, &[1, 2, 3, 4]).unwrap();
        dev.write_mem(pbb, &[5, 6, 7, 8]).unwrap();
        // desc_ptr + doorbell fetch
        dev.island.write32(mmio::DESC_PTR_LO, desc_addr as u32);
        dev.island
            .write32(mmio::DESC_PTR_HI, (desc_addr >> 32) as u32);
        let db = (99u32 << 8) | (1u32 << 31); // ticket 99, fetch
        dev.island.write32(mmio::DOORBELL, db);
        let c = dev.poll(99).unwrap().unwrap();
        assert!(c.is_ok());
        let mut raw = [0u8; 16];
        dev.read_mem(pc, &mut raw).unwrap();
        let c00 = i32::from_le_bytes(raw[0..4].try_into().unwrap());
        assert_eq!(c00, 19);
    }

    #[test]
    fn disabled_returns_status() {
        let mut dev = MmioDevice::new();
        // no enable
        let d = Desc64::gemm(1, 1, 1).with_ptrs(0x1000, 0x1000, 0x1000, 0);
        let reg = Region {
            base: 0x1000,
            limit: 0x2000,
            read: true,
            write: true,
        };
        dev.program_region(0, reg).unwrap();
        dev.submit(0, 1, &d).unwrap();
        let c = dev.poll(1).unwrap().unwrap();
        assert_eq!(c.status, ST_DISABLED);
    }

    #[test]
    fn irq_sticky_on_flag() {
        let mut dev = MmioDevice::new();
        dev.probe_caps();
        dev.enable(true);
        let reg = Region {
            base: 0x1000,
            limit: 0x1000 + (1 << 20),
            read: true,
            write: true,
        };
        dev.program_region(0, reg).unwrap();
        let pa = dev.alloc(1).unwrap();
        let pb = dev.alloc(1).unwrap();
        let pc = dev.alloc(4).unwrap();
        let pd = dev.alloc(8).unwrap();
        let d = Desc64::gemm(1, 1, 1)
            .with_ptrs(pa, pb, pc, pd)
            .with_irq(true);
        dev.write_mem(pa, &[2]).unwrap();
        dev.write_mem(pb, &[3]).unwrap();
        dev.submit(0, 5, &d).unwrap();
        assert!(dev.irq_pending());
        let c = dev.poll(5).unwrap().unwrap();
        assert!(c.is_ok());
        assert!(!dev.irq_pending());
    }

    #[test]
    fn mapped_window_cap_seed() {
        let mut w = MappedWindow::zeros(4096);
        seed_cap_island_p3(&mut w);
        let cap = probe_cap_regs(&mut w);
        assert_eq!(cap.macs_per_cycle, 256);
        assert_eq!(cap.acc_tile.m, 256);
    }
}
